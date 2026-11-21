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

// Alternate FSM with on-the-fly store-miss refill byte-merge and genvar MRU array
localparam C_BOOT       = 4'd0;
localparam C_READY      = 4'd1;
localparam C_RD_SRAM1   = 4'd2;
localparam C_RD_SRAM2   = 4'd3;
localparam C_DECIDE     = 4'd4;
localparam C_STORE_HIT  = 4'd5;
localparam C_INVAL_HIT  = 4'd6;
localparam C_WB_FETCH   = 4'd7;
localparam C_WB_BURST   = 4'd8;
localparam C_WB_BRESP   = 4'd9;
localparam C_LINE_FILL  = 4'd10;
localparam C_SWP_SRAM1  = 4'd11;
localparam C_SWP_SRAM2  = 4'd12;
localparam C_SWP_DECIDE = 4'd13;

reg [ 3:0] fsm_q;
reg [31:0] cmd_addr_q, cmd_wdata_q;
reg [ 3:0] cmd_wstrb_q;
reg        cmd_is_rd_q, cmd_is_inv_q, cmd_is_wb_q, cmd_is_fl_q;
reg [10:0] cmd_id_q;

reg [ 7:0] swp_set_q;
reg        way_pick_q;
reg [18:0] wb_tag_q;
reg [ 7:0] wb_set_q;
reg [ 3:0] sram_cnt_q;
reg [ 2:0] axi_cnt_q;
reg [31:0] line_staging_q [0:7];
reg        ar_issue_q;
reg [31:0] crit_word_q;
reg        sticky_err_q;

reg        resp_v_q, resp_err_q;
reg [31:0] resp_dat_q;
reg [10:0] resp_id_q;

// Per-set MRU tracker generated per set
reg        mru_upd_v_q;
reg [ 7:0] mru_upd_set_q;
reg        mru_upd_way_q;
wire [255:0] mru_vec_w;

genvar s;
generate
    for (s = 0; s < 256; s = s + 1) begin : g_mru
        reg mru_bit_q;
        always @(posedge clk_i or posedge rst_i) begin
            if (rst_i)
                mru_bit_q <= 1'b1;
            else if (mru_upd_v_q && (mru_upd_set_q == s[7:0]))
                mru_bit_q <= mru_upd_way_q;
        end
        assign mru_vec_w[s] = mru_bit_q;
    end
endgenerate

wire        has_cmd_w  = mem_rd_i || (|mem_wr_i) || mem_invalidate_i || mem_writeback_i || mem_flush_i;
wire [ 7:0] set_idx_w  = cmd_addr_q[12:5];
wire [18:0] tag_cmp_w  = cmd_addr_q[31:13];

wire [20:0] t0_rd_w, t1_rd_w;
wire [31:0] d0_rd_w, d1_rd_w;

wire        w0_v_w   = t0_rd_w[20];
wire        w0_d_w   = t0_rd_w[19];
wire [18:0] w0_t_w   = t0_rd_w[18:0];
wire        w1_v_w   = t1_rd_w[20];
wire        w1_d_w   = t1_rd_w[19];
wire [18:0] w1_t_w   = t1_rd_w[18:0];

wire w0_match_w = w0_v_w && (w0_t_w == tag_cmp_w);
wire w1_match_w = w1_v_w && (w1_t_w == tag_cmp_w);
wire any_hit_w  = w0_match_w || w1_match_w;

wire mru_cur_w  = (mru_upd_v_q && (mru_upd_set_q == set_idx_w)) ? mru_upd_way_q : mru_vec_w[set_idx_w];
wire repl_way_w = !w0_v_w ? 1'b0 : (!w1_v_w ? 1'b1 : ~mru_cur_w);
wire repl_dit_w = repl_way_w ? (w1_v_w && w1_d_w) : (w0_v_w && w0_d_w);

wire [7:0] t_rd_idx_w = (fsm_q == C_SWP_SRAM1 || fsm_q == C_SWP_SRAM2) ? swp_set_q : set_idx_w;
wire [7:0] t_wr_idx_w = (fsm_q == C_BOOT || cmd_is_fl_q)               ? swp_set_q : set_idx_w;

reg        t0_we_r, t1_we_r;
reg [20:0] t_wdat_r;

always @* begin
    t0_we_r  = 1'b0;
    t1_we_r  = 1'b0;
    t_wdat_r = 21'b0;
    if (fsm_q == C_BOOT) begin
        t0_we_r  = 1'b1;
        t1_we_r  = 1'b1;
        t_wdat_r = 21'b0;
    end else if (fsm_q == C_STORE_HIT) begin
        t0_we_r  = ~way_pick_q;
        t1_we_r  =  way_pick_q;
        t_wdat_r = {1'b1, 1'b1, tag_cmp_w};
    end else if (fsm_q == C_INVAL_HIT) begin
        t0_we_r  = ~way_pick_q;
        t1_we_r  =  way_pick_q;
        t_wdat_r = 21'b0;
    end else if (fsm_q == C_LINE_FILL && outport_ack_i && (axi_cnt_q == 3'd7)) begin
        t0_we_r  = ~way_pick_q;
        t1_we_r  =  way_pick_q;
        t_wdat_r = {1'b1, (|cmd_wstrb_q), tag_cmp_w};
    end else if (fsm_q == C_WB_BRESP && outport_ack_i) begin
        t0_we_r  = ~way_pick_q;
        t1_we_r  =  way_pick_q;
        t_wdat_r = cmd_is_wb_q ? {1'b1, 1'b0, tag_cmp_w} : 21'b0;
    end else if (fsm_q == C_SWP_DECIDE && !(w0_v_w && w0_d_w) && !(w1_v_w && w1_d_w)) begin
        t0_we_r  = 1'b1;
        t1_we_r  = 1'b1;
        t_wdat_r = 21'b0;
    end
end

dcache_core_tag_ram u_tag0 (
    .clk0_i(clk_i), .rst0_i(rst_i), .clk1_i(clk_i), .rst1_i(rst_i),
    .addr0_i(t_rd_idx_w), .data0_o(t0_rd_w),
    .addr1_i(t_wr_idx_w), .data1_i(t_wdat_r), .wr1_i(t0_we_r)
);

dcache_core_tag_ram u_tag1 (
    .clk0_i(clk_i), .rst0_i(rst_i), .clk1_i(clk_i), .rst1_i(rst_i),
    .addr0_i(t_rd_idx_w), .data0_o(t1_rd_w),
    .addr1_i(t_wr_idx_w), .data1_i(t_wdat_r), .wr1_i(t1_we_r)
);

// On-the-fly store-miss byte merge during AXI refill
wire        merge_beat_w = (|cmd_wstrb_q) && (axi_cnt_q == cmd_addr_q[4:2]);
wire [31:0] fill_merged_w = {
    (merge_beat_w && cmd_wstrb_q[3]) ? cmd_wdata_q[31:24] : outport_read_data_i[31:24],
    (merge_beat_w && cmd_wstrb_q[2]) ? cmd_wdata_q[23:16] : outport_read_data_i[23:16],
    (merge_beat_w && cmd_wstrb_q[1]) ? cmd_wdata_q[15: 8] : outport_read_data_i[15: 8],
    (merge_beat_w && cmd_wstrb_q[0]) ? cmd_wdata_q[ 7: 0] : outport_read_data_i[ 7: 0]
};

wire [10:0] d_rd_adr_w = (fsm_q == C_WB_FETCH)  ? {wb_set_q, sram_cnt_q[2:0]} : cmd_addr_q[12:2];
wire [10:0] d_wr_adr_w = (fsm_q == C_LINE_FILL) ? {set_idx_w, axi_cnt_q}      : cmd_addr_q[12:2];
wire [31:0] d_wdat_w   = (fsm_q == C_LINE_FILL) ? fill_merged_w               : cmd_wdata_q;
wire [ 3:0] d0_we_w    = (fsm_q == C_LINE_FILL && outport_ack_i && !way_pick_q) ? 4'hF :
                         (fsm_q == C_STORE_HIT && !way_pick_q)                  ? cmd_wstrb_q : 4'b0;
wire [ 3:0] d1_we_w    = (fsm_q == C_LINE_FILL && outport_ack_i &&  way_pick_q) ? 4'hF :
                         (fsm_q == C_STORE_HIT &&  way_pick_q)                  ? cmd_wstrb_q : 4'b0;

dcache_core_data_ram u_data0 (
    .clk0_i(clk_i), .rst0_i(rst_i), .clk1_i(clk_i), .rst1_i(rst_i),
    .addr0_i(d_rd_adr_w), .data0_i(32'b0), .wr0_i(4'b0), .data0_o(d0_rd_w),
    .addr1_i(d_wr_adr_w), .data1_i(d_wdat_w), .wr1_i(d0_we_w), .data1_o()
);

dcache_core_data_ram u_data1 (
    .clk0_i(clk_i), .rst0_i(rst_i), .clk1_i(clk_i), .rst1_i(rst_i),
    .addr0_i(d_rd_adr_w), .data0_i(32'b0), .wr0_i(4'b0), .data0_o(d1_rd_w),
    .addr1_i(d_wr_adr_w), .data1_i(d_wdat_w), .wr1_i(d1_we_w), .data1_o()
);

integer j;
always @(posedge clk_i or posedge rst_i) begin
    if (rst_i) begin
        fsm_q         <= C_BOOT;
        cmd_addr_q    <= 32'b0;
        cmd_wdata_q   <= 32'b0;
        cmd_wstrb_q   <= 4'b0;
        cmd_is_rd_q   <= 1'b0;
        cmd_is_inv_q  <= 1'b0;
        cmd_is_wb_q   <= 1'b0;
        cmd_is_fl_q   <= 1'b0;
        cmd_id_q      <= 11'b0;
        swp_set_q     <= 8'b0;
        way_pick_q    <= 1'b0;
        wb_tag_q      <= 19'b0;
        wb_set_q      <= 8'b0;
        sram_cnt_q    <= 4'b0;
        axi_cnt_q     <= 3'b0;
        for (j = 0; j < 8; j = j + 1)
            line_staging_q[j] <= 32'b0;
        ar_issue_q    <= 1'b0;
        crit_word_q   <= 32'b0;
        sticky_err_q  <= 1'b0;
        resp_v_q      <= 1'b0;
        resp_err_q    <= 1'b0;
        resp_dat_q    <= 32'b0;
        resp_id_q     <= 11'b0;
        mru_upd_v_q   <= 1'b0;
        mru_upd_set_q <= 8'b0;
        mru_upd_way_q <= 1'b0;
    end else begin
        resp_v_q    <= 1'b0;
        mru_upd_v_q <= 1'b0;
        case (fsm_q)
            C_BOOT: begin
                if (swp_set_q == 8'hFF) begin
                    swp_set_q <= 8'd0;
                    fsm_q     <= C_READY;
                end else begin
                    swp_set_q <= swp_set_q + 8'd1;
                end
            end

            C_READY: begin
                if (has_cmd_w) begin
                    cmd_addr_q   <= mem_addr_i;
                    cmd_wdata_q  <= mem_data_wr_i;
                    cmd_wstrb_q  <= mem_wr_i;
                    cmd_is_rd_q  <= mem_rd_i;
                    cmd_is_inv_q <= mem_invalidate_i;
                    cmd_is_wb_q  <= mem_writeback_i;
                    cmd_is_fl_q  <= mem_flush_i;
                    cmd_id_q     <= mem_req_tag_i;
                    sticky_err_q <= 1'b0;
                    if (mem_flush_i) begin
                        swp_set_q <= 8'd0;
                        fsm_q     <= C_SWP_SRAM1;
                    end else begin
                        fsm_q     <= C_RD_SRAM1;
                    end
                end
            end

            C_RD_SRAM1: fsm_q <= C_RD_SRAM2;
            C_RD_SRAM2: fsm_q <= C_DECIDE;

            C_DECIDE: begin
                if (cmd_is_inv_q) begin
                    if (any_hit_w) begin
                        way_pick_q <= w1_match_w;
                        fsm_q      <= C_INVAL_HIT;
                    end else begin
                        resp_v_q   <= 1'b1;
                        resp_id_q  <= cmd_id_q;
                        resp_err_q <= 1'b0;
                        fsm_q      <= C_READY;
                    end
                end else if (cmd_is_wb_q) begin
                    if ((w0_match_w && w0_d_w) || (w1_match_w && w1_d_w)) begin
                        way_pick_q <= w1_match_w;
                        wb_tag_q   <= tag_cmp_w;
                        wb_set_q   <= set_idx_w;
                        sram_cnt_q <= 4'd0;
                        fsm_q      <= C_WB_FETCH;
                    end else begin
                        resp_v_q   <= 1'b1;
                        resp_id_q  <= cmd_id_q;
                        resp_err_q <= 1'b0;
                        fsm_q      <= C_READY;
                    end
                end else if (any_hit_w) begin
                    if (cmd_is_rd_q) begin
                        mru_upd_v_q   <= 1'b1;
                        mru_upd_set_q <= set_idx_w;
                        mru_upd_way_q <= w1_match_w;
                        resp_dat_q    <= w1_match_w ? d1_rd_w : d0_rd_w;
                        resp_id_q     <= cmd_id_q;
                        resp_err_q    <= 1'b0;
                        resp_v_q      <= 1'b1;
                        fsm_q         <= C_READY;
                    end else begin
                        way_pick_q <= w1_match_w;
                        fsm_q      <= C_STORE_HIT;
                    end
                end else begin
                    way_pick_q <= repl_way_w;
                    wb_tag_q   <= repl_way_w ? w1_t_w : w0_t_w;
                    wb_set_q   <= set_idx_w;
                    if (repl_dit_w) begin
                        sram_cnt_q <= 4'd0;
                        fsm_q      <= C_WB_FETCH;
                    end else begin
                        ar_issue_q <= 1'b1;
                        axi_cnt_q  <= 3'd0;
                        fsm_q      <= C_LINE_FILL;
                    end
                end
            end

            C_STORE_HIT: begin
                mru_upd_v_q   <= 1'b1;
                mru_upd_set_q <= set_idx_w;
                mru_upd_way_q <= way_pick_q;
                resp_id_q     <= cmd_id_q;
                resp_err_q    <= 1'b0;
                resp_v_q      <= 1'b1;
                fsm_q         <= C_READY;
            end

            C_INVAL_HIT: begin
                resp_id_q  <= cmd_id_q;
                resp_err_q <= 1'b0;
                resp_v_q   <= 1'b1;
                fsm_q      <= C_READY;
            end

            C_WB_FETCH: begin
                if (sram_cnt_q >= 4'd2)
                    line_staging_q[sram_cnt_q[2:0] - 3'd2] <= way_pick_q ? d1_rd_w : d0_rd_w;
                if (sram_cnt_q == 4'd9) begin
                    axi_cnt_q <= 3'd0;
                    fsm_q     <= C_WB_BURST;
                end else begin
                    sram_cnt_q <= sram_cnt_q + 4'd1;
                end
            end

            C_WB_BURST: begin
                if (outport_accept_i) begin
                    if (axi_cnt_q == 3'd7)
                        fsm_q     <= C_WB_BRESP;
                    else
                        axi_cnt_q <= axi_cnt_q + 3'd1;
                end
            end

            C_WB_BRESP: begin
                if (outport_ack_i) begin
                    if (outport_error_i)
                        sticky_err_q <= 1'b1;
                    if (cmd_is_wb_q) begin
                        resp_id_q  <= cmd_id_q;
                        resp_err_q <= sticky_err_q | outport_error_i;
                        resp_v_q   <= 1'b1;
                        fsm_q      <= C_READY;
                    end else if (cmd_is_fl_q) begin
                        fsm_q      <= C_SWP_SRAM1;
                    end else begin
                        ar_issue_q <= 1'b1;
                        axi_cnt_q  <= 3'd0;
                        fsm_q      <= C_LINE_FILL;
                    end
                end
            end

            C_LINE_FILL: begin
                if (ar_issue_q && outport_accept_i)
                    ar_issue_q <= 1'b0;
                if (outport_ack_i) begin
                    if (outport_error_i)
                        sticky_err_q <= 1'b1;
                    if (axi_cnt_q == cmd_addr_q[4:2])
                        crit_word_q <= outport_read_data_i;
                    if (axi_cnt_q == 3'd7) begin
                        mru_upd_v_q   <= 1'b1;
                        mru_upd_set_q <= set_idx_w;
                        mru_upd_way_q <= way_pick_q;
                        resp_dat_q    <= (cmd_addr_q[4:2] == 3'd7) ? outport_read_data_i : crit_word_q;
                        resp_id_q     <= cmd_id_q;
                        resp_err_q    <= sticky_err_q | outport_error_i;
                        resp_v_q      <= 1'b1;
                        fsm_q         <= C_READY;
                    end else begin
                        axi_cnt_q <= axi_cnt_q + 3'd1;
                    end
                end
            end

            C_SWP_SRAM1: fsm_q <= C_SWP_SRAM2;
            C_SWP_SRAM2: fsm_q <= C_SWP_DECIDE;

            C_SWP_DECIDE: begin
                if (w0_v_w && w0_d_w) begin
                    way_pick_q <= 1'b0;
                    wb_tag_q   <= w0_t_w;
                    wb_set_q   <= swp_set_q;
                    sram_cnt_q <= 4'd0;
                    fsm_q      <= C_WB_FETCH;
                end else if (w1_v_w && w1_d_w) begin
                    way_pick_q <= 1'b1;
                    wb_tag_q   <= w1_t_w;
                    wb_set_q   <= swp_set_q;
                    sram_cnt_q <= 4'd0;
                    fsm_q      <= C_WB_FETCH;
                end else if (swp_set_q == 8'hFF) begin
                    swp_set_q  <= 8'd0;
                    resp_id_q  <= cmd_id_q;
                    resp_err_q <= sticky_err_q;
                    resp_v_q   <= 1'b1;
                    fsm_q      <= C_READY;
                end else begin
                    swp_set_q  <= swp_set_q + 8'd1;
                    fsm_q      <= C_SWP_SRAM1;
                end
            end

            default: fsm_q <= C_READY;
        endcase
    end
end

assign mem_accept_o         = (fsm_q == C_READY);
assign mem_ack_o            = resp_v_q;
assign mem_data_rd_o        = resp_dat_q;
assign mem_resp_tag_o       = resp_id_q;
assign mem_error_o          = resp_err_q;

assign outport_wr_o         = (fsm_q == C_WB_BURST) ? 4'hF : 4'b0;
assign outport_rd_o         = (fsm_q == C_LINE_FILL) && ar_issue_q;
assign outport_len_o        = ((fsm_q == C_LINE_FILL && ar_issue_q) || (fsm_q == C_WB_BURST && axi_cnt_q == 3'd0)) ? 8'd7 : 8'd0;
assign outport_addr_o       = (fsm_q == C_WB_BURST) ? {wb_tag_q, wb_set_q, axi_cnt_q, 2'b00} : {cmd_addr_q[31:5], 5'b0};
assign outport_write_data_o = line_staging_q[axi_cnt_q];

endmodule
