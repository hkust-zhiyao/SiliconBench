module dcache_axi_axi
(
     input           clk_i
    ,input           rst_i
    ,input           inport_valid_i
    ,input           inport_write_i
    ,input  [ 31:0]  inport_addr_i
    ,input  [  3:0]  inport_id_i
    ,input  [  7:0]  inport_len_i
    ,input  [  1:0]  inport_burst_i
    ,input  [ 31:0]  inport_wdata_i
    ,input  [  3:0]  inport_wstrb_i
    ,input           inport_bready_i
    ,input           inport_rready_i
    ,input           outport_awready_i
    ,input           outport_wready_i
    ,input           outport_bvalid_i
    ,input  [  1:0]  outport_bresp_i
    ,input  [  3:0]  outport_bid_i
    ,input           outport_arready_i
    ,input           outport_rvalid_i
    ,input  [ 31:0]  outport_rdata_i
    ,input  [  1:0]  outport_rresp_i
    ,input  [  3:0]  outport_rid_i
    ,input           outport_rlast_i

    ,output          inport_accept_o
    ,output          inport_bvalid_o
    ,output [  1:0]  inport_bresp_o
    ,output [  3:0]  inport_bid_o
    ,output          inport_rvalid_o
    ,output [ 31:0]  inport_rdata_o
    ,output [  1:0]  inport_rresp_o
    ,output [  3:0]  inport_rid_o
    ,output          inport_rlast_o
    ,output          outport_awvalid_o
    ,output [ 31:0]  outport_awaddr_o
    ,output [  3:0]  outport_awid_o
    ,output [  7:0]  outport_awlen_o
    ,output [  1:0]  outport_awburst_o
    ,output          outport_wvalid_o
    ,output [ 31:0]  outport_wdata_o
    ,output [  3:0]  outport_wstrb_o
    ,output          outport_wlast_o
    ,output          outport_bready_o
    ,output          outport_arvalid_o
    ,output [ 31:0]  outport_araddr_o
    ,output [  3:0]  outport_arid_o
    ,output [  7:0]  outport_arlen_o
    ,output [  1:0]  outport_arburst_o
    ,output          outport_rready_o
);

// Decoupled AW & W skid registers + remaining-beat tracker for multi-beat bursts
reg        aw_pend_q;
reg [31:0] aw_addr_q;
reg [ 3:0] aw_id_q;
reg [ 7:0] aw_len_q;
reg [ 1:0] aw_burst_q;

reg        w_pend_q;
reg [31:0] w_data_q;
reg [ 3:0] w_strb_q;
reg        w_last_q;

reg [ 7:0] w_rem_q;

wire can_start_wr_w = (w_rem_q == 8'd0) && !aw_pend_q && !w_pend_q && inport_valid_i && inport_write_i;
wire can_cont_wr_w  = (w_rem_q != 8'd0) && !w_pend_q && inport_valid_i && inport_write_i;
wire wr_beat_take_w = can_start_wr_w || can_cont_wr_w;
wire wr_beat_last_w = can_start_wr_w ? (inport_len_i == 8'd0) : (w_rem_q == 8'd1);

wire can_start_rd_w = (w_rem_q == 8'd0) && !aw_pend_q && !w_pend_q && inport_valid_i && !inport_write_i;

always @(posedge clk_i or posedge rst_i) begin
    if (rst_i) begin
        aw_pend_q  <= 1'b0;
        aw_addr_q  <= 32'b0;
        aw_id_q    <= 4'b0;
        aw_len_q   <= 8'b0;
        aw_burst_q <= 2'b01;
        w_pend_q   <= 1'b0;
        w_data_q   <= 32'b0;
        w_strb_q   <= 4'b0;
        w_last_q   <= 1'b0;
        w_rem_q    <= 8'b0;
    end else begin
        if (aw_pend_q) begin
            if (outport_awready_i)
                aw_pend_q <= 1'b0;
        end else if (can_start_wr_w && !outport_awready_i) begin
            aw_pend_q  <= 1'b1;
            aw_addr_q  <= inport_addr_i;
            aw_id_q    <= inport_id_i;
            aw_len_q   <= inport_len_i;
            aw_burst_q <= inport_burst_i;
        end

        if (w_pend_q) begin
            if (outport_wready_i)
                w_pend_q <= 1'b0;
        end else if (wr_beat_take_w && !outport_wready_i) begin
            w_pend_q <= 1'b1;
            w_data_q <= inport_wdata_i;
            w_strb_q <= inport_wstrb_i;
            w_last_q <= wr_beat_last_w;
        end

        if (can_start_wr_w)
            w_rem_q <= inport_len_i;
        else if (can_cont_wr_w)
            w_rem_q <= w_rem_q - 8'd1;
    end
end

assign outport_awvalid_o = aw_pend_q ? 1'b1       : can_start_wr_w;
assign outport_awaddr_o  = aw_pend_q ? aw_addr_q  : inport_addr_i;
assign outport_awid_o    = aw_pend_q ? aw_id_q    : inport_id_i;
assign outport_awlen_o   = aw_pend_q ? aw_len_q   : inport_len_i;
assign outport_awburst_o = aw_pend_q ? aw_burst_q : inport_burst_i;

assign outport_wvalid_o  = w_pend_q  ? 1'b1       : wr_beat_take_w;
assign outport_wdata_o   = w_pend_q  ? w_data_q   : inport_wdata_i;
assign outport_wstrb_o   = w_pend_q  ? w_strb_q   : inport_wstrb_i;
assign outport_wlast_o   = w_pend_q  ? w_last_q   : wr_beat_last_w;

assign inport_bvalid_o   = outport_bvalid_i;
assign inport_bresp_o    = outport_bresp_i;
assign inport_bid_o      = outport_bid_i;
assign outport_bready_o  = inport_bready_i;

assign outport_arvalid_o = can_start_rd_w;
assign outport_araddr_o  = inport_addr_i;
assign outport_arid_o    = inport_id_i;
assign outport_arlen_o   = inport_len_i;
assign outport_arburst_o = inport_burst_i;
assign outport_rready_o  = inport_rready_i;

assign inport_rvalid_o   = outport_rvalid_i;
assign inport_rdata_o    = outport_rdata_i;
assign inport_rresp_o    = outport_rresp_i;
assign inport_rid_o      = outport_rid_i;
assign inport_rlast_o    = outport_rlast_i;

assign inport_accept_o   = wr_beat_take_w || (can_start_rd_w && outport_arready_i);

endmodule
