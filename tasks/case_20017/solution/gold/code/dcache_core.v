module dcache_core
(
     input           clk_i
    ,input           rst_i
    ,input  [ 31:0]  mem_addr_i
    ,input  [ 31:0]  mem_data_wr_i
    ,input           mem_rd_i
    ,input  [  3:0]  mem_wr_i
    ,input           mem_cacheable_i
    ,input  [ 10:0]  mem_req_tag_i
    ,input           mem_invalidate_i
    ,input           mem_writeback_i
    ,input           mem_flush_i
    ,input           outport_accept_i
    ,input           outport_ack_i
    ,input           outport_error_i
    ,input  [ 31:0]  outport_read_data_i

    ,output [ 31:0]  mem_data_rd_o
    ,output          mem_accept_o
    ,output          mem_ack_o
    ,output          mem_error_o
    ,output [ 10:0]  mem_resp_tag_o
    ,output [  3:0]  outport_wr_o
    ,output          outport_rd_o
    ,output [  7:0]  outport_len_o
    ,output [ 31:0]  outport_addr_o
    ,output [ 31:0]  outport_write_data_o
);

localparam S_RESET        = 4'd0;
localparam S_IDLE         = 4'd1;
localparam S_LOOKUP_REQ   = 4'd2;
localparam S_LOOKUP_WAIT  = 4'd3;
localparam S_CHECK        = 4'd4;
localparam S_WRITE_COMMIT = 4'd5;
localparam S_INVAL_COMMIT = 4'd6;
localparam S_EVICT_READ   = 4'd7;
localparam S_EVICT_SEND   = 4'd8;
localparam S_EVICT_WAIT   = 4'd9;
localparam S_REFILL       = 4'd10;
localparam S_FLUSH_REQ    = 4'd11;
localparam S_FLUSH_WAIT   = 4'd12;
localparam S_FLUSH_CHECK  = 4'd13;

reg [ 3:0] state_q;
reg [31:0] req_addr_q;
reg [31:0] req_wdata_q;
reg [ 3:0] req_wr_q;
reg        req_rd_q;
reg [10:0] req_tag_q;
reg        req_inval_q;
reg        req_wb_q;
reg        req_flush_q;

reg [ 7:0] flush_addr_q;
reg [255:0] lru_q;
reg        sel_way_q;
reg [18:0] evict_tag_q;
reg [ 7:0] evict_idx_q;
reg [ 3:0] rd_idx_q;
reg [ 2:0] beat_q;
reg [31:0] evict_buf_q [0:7];
reg        pmem_rd_cmd_q;
reg [31:0] refill_word_q;
reg        err_acc_q;

reg        ack_q;
reg [31:0] rdata_q;
reg [10:0] resp_tag_q;
reg        err_q;

wire       in_req_valid_w = mem_rd_i || (|mem_wr_i) || mem_invalidate_i || mem_writeback_i || mem_flush_i;
wire [7:0] req_idx_w      = req_addr_q[12:5];
wire [18:0] req_tag_cmp_w = req_addr_q[31:13];

wire [20:0] tag0_out_w, tag1_out_w;
wire [31:0] data0_out_w, data1_out_w;

wire        tag0_val_w = tag0_out_w[20];
wire        tag0_dit_w = tag0_out_w[19];
wire [18:0] tag0_adr_w = tag0_out_w[18:0];
wire        tag1_val_w = tag1_out_w[20];
wire        tag1_dit_w = tag1_out_w[19];
wire [18:0] tag1_adr_w = tag1_out_w[18:0];

wire tag0_hit_w = tag0_val_w && (tag0_adr_w == req_tag_cmp_w);
wire tag1_hit_w = tag1_val_w && (tag1_adr_w == req_tag_cmp_w);
wire hit_any_w  = tag0_hit_w || tag1_hit_w;

wire vic_way_w   = !tag0_val_w ? 1'b0 : (!tag1_val_w ? 1'b1 : lru_q[req_idx_w]);
wire vic_dirty_w = vic_way_w ? (tag1_val_w && tag1_dit_w) : (tag0_val_w && tag0_dit_w);

// Tag SRAM control
wire [7:0] tag_raddr_w = (state_q == S_FLUSH_REQ || state_q == S_FLUSH_WAIT) ? flush_addr_q : req_idx_w;
wire [7:0] tag_waddr_w = (state_q == S_RESET || req_flush_q) ? flush_addr_q : req_idx_w;

reg        tag0_wr_r, tag1_wr_r;
reg [20:0] tag_wdata_r;

always @* begin
    tag0_wr_r   = 1'b0;
    tag1_wr_r   = 1'b0;
    tag_wdata_r = 21'b0;
    if (state_q == S_RESET) begin
        tag0_wr_r   = 1'b1;
        tag1_wr_r   = 1'b1;
        tag_wdata_r = 21'b0;
    end else if (state_q == S_WRITE_COMMIT) begin
        tag0_wr_r   = ~sel_way_q;
        tag1_wr_r   =  sel_way_q;
        tag_wdata_r = {1'b1, 1'b1, req_tag_cmp_w};
    end else if (state_q == S_INVAL_COMMIT) begin
        tag0_wr_r   = ~sel_way_q;
        tag1_wr_r   =  sel_way_q;
        tag_wdata_r = 21'b0;
    end else if (state_q == S_REFILL && outport_ack_i && (beat_q == 3'd7) && req_rd_q) begin
        tag0_wr_r   = ~sel_way_q;
        tag1_wr_r   =  sel_way_q;
        tag_wdata_r = {1'b1, 1'b0, req_tag_cmp_w};
    end else if (state_q == S_EVICT_WAIT && outport_ack_i) begin
        tag0_wr_r   = ~sel_way_q;
        tag1_wr_r   =  sel_way_q;
        tag_wdata_r = req_wb_q ? {1'b1, 1'b0, req_tag_cmp_w} : 21'b0;
    end else if (state_q == S_FLUSH_CHECK && !(tag0_val_w && tag0_dit_w) && !(tag1_val_w && tag1_dit_w)) begin
        tag0_wr_r   = 1'b1;
        tag1_wr_r   = 1'b1;
        tag_wdata_r = 21'b0;
    end
end

dcache_core_tag_ram u_tag0 (
    .clk0_i(clk_i), .rst0_i(rst_i), .clk1_i(clk_i), .rst1_i(rst_i),
    .addr0_i(tag_raddr_w), .data0_o(tag0_out_w),
    .addr1_i(tag_waddr_w), .data1_i(tag_wdata_r), .wr1_i(tag0_wr_r)
);

dcache_core_tag_ram u_tag1 (
    .clk0_i(clk_i), .rst0_i(rst_i), .clk1_i(clk_i), .rst1_i(rst_i),
    .addr0_i(tag_raddr_w), .data0_o(tag1_out_w),
    .addr1_i(tag_waddr_w), .data1_i(tag_wdata_r), .wr1_i(tag1_wr_r)
);

// Data SRAM control
wire [10:0] data_raddr_w = (state_q == S_EVICT_READ) ? {evict_idx_q, rd_idx_q[2:0]} : req_addr_q[12:2];
wire [10:0] data_waddr_w = (state_q == S_REFILL)     ? {req_idx_w, beat_q}          : req_addr_q[12:2];
wire [31:0] data_wdata_w = (state_q == S_REFILL)     ? outport_read_data_i          : req_wdata_q;
wire [ 3:0] data0_wr_w   = (state_q == S_REFILL && outport_ack_i && !sel_way_q) ? 4'hF :
                           (state_q == S_WRITE_COMMIT && !sel_way_q)            ? req_wr_q : 4'b0;
wire [ 3:0] data1_wr_w   = (state_q == S_REFILL && outport_ack_i &&  sel_way_q) ? 4'hF :
                           (state_q == S_WRITE_COMMIT &&  sel_way_q)            ? req_wr_q : 4'b0;

dcache_core_data_ram u_data0 (
    .clk0_i(clk_i), .rst0_i(rst_i), .clk1_i(clk_i), .rst1_i(rst_i),
    .addr0_i(data_raddr_w), .data0_i(32'b0), .wr0_i(4'b0), .data0_o(data0_out_w),
    .addr1_i(data_waddr_w), .data1_i(data_wdata_w), .wr1_i(data0_wr_w), .data1_o()
);

dcache_core_data_ram u_data1 (
    .clk0_i(clk_i), .rst0_i(rst_i), .clk1_i(clk_i), .rst1_i(rst_i),
    .addr0_i(data_raddr_w), .data0_i(32'b0), .wr0_i(4'b0), .data0_o(data1_out_w),
    .addr1_i(data_waddr_w), .data1_i(data_wdata_w), .wr1_i(data1_wr_w), .data1_o()
);
integer k;
always @(posedge clk_i or posedge rst_i) begin
    if (rst_i) begin
        state_q       <= S_RESET;
        req_addr_q    <= 32'b0;
        req_wdata_q   <= 32'b0;
        req_wr_q      <= 4'b0;
        req_rd_q      <= 1'b0;
        req_tag_q     <= 11'b0;
        req_inval_q   <= 1'b0;
        req_wb_q      <= 1'b0;
        req_flush_q   <= 1'b0;
        flush_addr_q  <= 8'b0;
        lru_q         <= 256'b0;
        sel_way_q     <= 1'b0;
        evict_tag_q   <= 19'b0;
        evict_idx_q   <= 8'b0;
        rd_idx_q      <= 4'b0;
        beat_q        <= 3'b0;
        for (k = 0; k < 8; k = k + 1)
            evict_buf_q[k] <= 32'b0;
        pmem_rd_cmd_q <= 1'b0;
        refill_word_q <= 32'b0;
        err_acc_q     <= 1'b0;
        ack_q         <= 1'b0;
        rdata_q       <= 32'b0;
        resp_tag_q    <= 11'b0;
        err_q         <= 1'b0;
    end else begin
        ack_q <= 1'b0;
        case (state_q)
            S_RESET: begin
                if (flush_addr_q == 8'hFF) begin
                    flush_addr_q <= 8'd0;
                    state_q      <= S_IDLE;
                end else begin
                    flush_addr_q <= flush_addr_q + 8'd1;
                end
            end

            S_IDLE: begin
                if (in_req_valid_w) begin
                    req_addr_q  <= mem_addr_i;
                    req_wdata_q <= mem_data_wr_i;
                    req_wr_q    <= mem_wr_i;
                    req_rd_q    <= mem_rd_i;
                    req_tag_q   <= mem_req_tag_i;
                    req_inval_q <= mem_invalidate_i;
                    req_wb_q    <= mem_writeback_i;
                    req_flush_q <= mem_flush_i;
                    err_acc_q   <= 1'b0;
                    if (mem_flush_i) begin
                        flush_addr_q <= 8'd0;
                        state_q      <= S_FLUSH_REQ;
                    end else begin
                        state_q      <= S_LOOKUP_REQ;
                    end
                end
            end

            S_LOOKUP_REQ:  state_q <= S_LOOKUP_WAIT;
            S_LOOKUP_WAIT: state_q <= S_CHECK;

            S_CHECK: begin
                if (req_inval_q) begin
                    if (hit_any_w) begin
                        sel_way_q <= tag1_hit_w;
                        state_q   <= S_INVAL_COMMIT;
                    end else begin
                        ack_q      <= 1'b1;
                        resp_tag_q <= req_tag_q;
                        err_q      <= 1'b0;
                        state_q    <= S_IDLE;
                    end
                end else if (req_wb_q) begin
                    if ((tag0_hit_w && tag0_dit_w) || (tag1_hit_w && tag1_dit_w)) begin
                        sel_way_q   <= tag1_hit_w;
                        evict_tag_q <= req_tag_cmp_w;
                        evict_idx_q <= req_idx_w;
                        rd_idx_q    <= 4'd0;
                        state_q     <= S_EVICT_READ;
                    end else begin
                        ack_q      <= 1'b1;
                        resp_tag_q <= req_tag_q;
                        err_q      <= 1'b0;
                        state_q    <= S_IDLE;
                    end
                end else if (hit_any_w) begin
                    if (req_rd_q) begin
                        lru_q      <= tag1_hit_w ? (lru_q & ~(256'd1 << req_idx_w)) : (lru_q | (256'd1 << req_idx_w));
                        rdata_q    <= tag1_hit_w ? data1_out_w : data0_out_w;
                        resp_tag_q <= req_tag_q;
                        err_q      <= 1'b0;
                        ack_q      <= 1'b1;
                        state_q    <= S_IDLE;
                    end else begin
                        sel_way_q  <= tag1_hit_w;
                        state_q    <= S_WRITE_COMMIT;
                    end
                end else begin
                    sel_way_q   <= vic_way_w;
                    evict_tag_q <= vic_way_w ? tag1_adr_w : tag0_adr_w;
                    evict_idx_q <= req_idx_w;
                    if (vic_dirty_w) begin
                        rd_idx_q <= 4'd0;
                        state_q  <= S_EVICT_READ;
                    end else begin
                        pmem_rd_cmd_q <= 1'b1;
                        beat_q        <= 3'd0;
                        state_q       <= S_REFILL;
                    end
                end
            end

            S_WRITE_COMMIT: begin
                lru_q      <= sel_way_q ? (lru_q & ~(256'd1 << req_idx_w)) : (lru_q | (256'd1 << req_idx_w));
                resp_tag_q <= req_tag_q;
                err_q      <= err_acc_q;
                ack_q      <= 1'b1;
                state_q    <= S_IDLE;
            end

            S_INVAL_COMMIT: begin
                resp_tag_q <= req_tag_q;
                err_q      <= 1'b0;
                ack_q      <= 1'b1;
                state_q    <= S_IDLE;
            end

            S_EVICT_READ: begin
                if (rd_idx_q >= 4'd2)
                    evict_buf_q[rd_idx_q[2:0] - 3'd2] <= sel_way_q ? data1_out_w : data0_out_w;
                if (rd_idx_q == 4'd9) begin
                    beat_q  <= 3'd0;
                    state_q <= S_EVICT_SEND;
                end else begin
                    rd_idx_q <= rd_idx_q + 4'd1;
                end
            end

            S_EVICT_SEND: begin
                if (outport_accept_i) begin
                    if (beat_q == 3'd7)
                        state_q <= S_EVICT_WAIT;
                    else
                        beat_q  <= beat_q + 3'd1;
                end
            end

            S_EVICT_WAIT: begin
                if (outport_ack_i) begin
                    if (outport_error_i)
                        err_acc_q <= 1'b1;
                    if (req_wb_q) begin
                        resp_tag_q <= req_tag_q;
                        err_q      <= err_acc_q | outport_error_i;
                        ack_q      <= 1'b1;
                        state_q    <= S_IDLE;
                    end else if (req_flush_q) begin
                        state_q    <= S_FLUSH_REQ;
                    end else begin
                        pmem_rd_cmd_q <= 1'b1;
                        beat_q        <= 3'd0;
                        state_q       <= S_REFILL;
                    end
                end
            end

            S_REFILL: begin
                if (pmem_rd_cmd_q && outport_accept_i)
                    pmem_rd_cmd_q <= 1'b0;
                if (outport_ack_i) begin
                    if (outport_error_i)
                        err_acc_q <= 1'b1;
                    if (beat_q == req_addr_q[4:2])
                        refill_word_q <= outport_read_data_i;
                    if (beat_q == 3'd7) begin
                        if (req_rd_q) begin
                            lru_q      <= sel_way_q ? (lru_q & ~(256'd1 << req_idx_w)) : (lru_q | (256'd1 << req_idx_w));
                            rdata_q    <= (req_addr_q[4:2] == 3'd7) ? outport_read_data_i : refill_word_q;
                            resp_tag_q <= req_tag_q;
                            err_q      <= err_acc_q | outport_error_i;
                            ack_q      <= 1'b1;
                            state_q    <= S_IDLE;
                        end else begin
                            state_q    <= S_WRITE_COMMIT;
                        end
                    end else begin
                        beat_q <= beat_q + 3'd1;
                    end
                end
            end

            S_FLUSH_REQ:  state_q <= S_FLUSH_WAIT;
            S_FLUSH_WAIT: state_q <= S_FLUSH_CHECK;

            S_FLUSH_CHECK: begin
                if (tag0_val_w && tag0_dit_w) begin
                    sel_way_q   <= 1'b0;
                    evict_tag_q <= tag0_adr_w;
                    evict_idx_q <= flush_addr_q;
                    rd_idx_q    <= 4'd0;
                    state_q     <= S_EVICT_READ;
                end else if (tag1_val_w && tag1_dit_w) begin
                    sel_way_q   <= 1'b1;
                    evict_tag_q <= tag1_adr_w;
                    evict_idx_q <= flush_addr_q;
                    rd_idx_q    <= 4'd0;
                    state_q     <= S_EVICT_READ;
                end else if (flush_addr_q == 8'hFF) begin
                    flush_addr_q <= 8'd0;
                    resp_tag_q   <= req_tag_q;
                    err_q        <= err_acc_q;
                    ack_q        <= 1'b1;
                    state_q      <= S_IDLE;
                end else begin
                    flush_addr_q <= flush_addr_q + 8'd1;
                    state_q      <= S_FLUSH_REQ;
                end
            end

            default: state_q <= S_IDLE;
        endcase
    end
end

assign mem_accept_o         = (state_q == S_IDLE);
assign mem_ack_o            = ack_q;
assign mem_data_rd_o        = rdata_q;
assign mem_resp_tag_o       = resp_tag_q;
assign mem_error_o          = err_q;

assign outport_wr_o         = (state_q == S_EVICT_SEND) ? 4'hF : 4'b0;
assign outport_rd_o         = (state_q == S_REFILL) && pmem_rd_cmd_q;
assign outport_len_o        = ((state_q == S_REFILL && pmem_rd_cmd_q) || (state_q == S_EVICT_SEND && beat_q == 3'd0)) ? 8'd7 : 8'd0;
assign outport_addr_o       = (state_q == S_EVICT_SEND) ? {evict_tag_q, evict_idx_q, beat_q, 2'b00} : {req_addr_q[31:5], 5'b0};
assign outport_write_data_o = evict_buf_q[beat_q];

endmodule
