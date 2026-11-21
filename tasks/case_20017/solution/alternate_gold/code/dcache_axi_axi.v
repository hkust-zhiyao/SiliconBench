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

// Registered output slice AXI4 master bridge (zero combinational ready->accept feedthrough)
reg        aw_v_q, w_v_q, ar_v_q;
reg [31:0] ax_addr_q;
reg [ 3:0] ax_id_q;
reg [ 7:0] ax_len_q;
reg [ 1:0] ax_burst_q;
reg [31:0] w_dat_q;
reg [ 3:0] w_stb_q;
reg        w_lst_q;
reg [ 7:0] beats_left_q;

wire aw_free_w = !aw_v_q || outport_awready_i;
wire w_free_w  = !w_v_q  || outport_wready_i;
wire ar_free_w = !ar_v_q || outport_arready_i;

wire take_new_wr_w  = inport_valid_i &&  inport_write_i && (beats_left_q == 8'd0) && !ar_v_q && aw_free_w && w_free_w;
wire take_next_wr_w = inport_valid_i &&  inport_write_i && (beats_left_q != 8'd0) && w_free_w;
wire take_new_rd_w  = inport_valid_i && !inport_write_i && (beats_left_q == 8'd0) && !aw_v_q && !w_v_q && ar_free_w;

always @(posedge clk_i or posedge rst_i) begin
    if (rst_i) begin
        aw_v_q       <= 1'b0;
        w_v_q        <= 1'b0;
        ar_v_q       <= 1'b0;
        ax_addr_q    <= 32'b0;
        ax_id_q      <= 4'b0;
        ax_len_q     <= 8'b0;
        ax_burst_q   <= 2'b01;
        w_dat_q      <= 32'b0;
        w_stb_q      <= 4'b0;
        w_lst_q      <= 1'b0;
        beats_left_q <= 8'b0;
    end else begin
        if (take_new_wr_w) begin
            aw_v_q       <= 1'b1;
            ax_addr_q    <= inport_addr_i;
            ax_id_q      <= inport_id_i;
            ax_len_q     <= inport_len_i;
            ax_burst_q   <= inport_burst_i;
            w_v_q        <= 1'b1;
            w_dat_q      <= inport_wdata_i;
            w_stb_q      <= inport_wstrb_i;
            w_lst_q      <= (inport_len_i == 8'd0);
            beats_left_q <= inport_len_i;
        end else begin
            if (aw_v_q && outport_awready_i)
                aw_v_q <= 1'b0;

            if (take_next_wr_w) begin
                w_v_q        <= 1'b1;
                w_dat_q      <= inport_wdata_i;
                w_stb_q      <= inport_wstrb_i;
                w_lst_q      <= (beats_left_q == 8'd1);
                beats_left_q <= beats_left_q - 8'd1;
            end else if (w_v_q && outport_wready_i) begin
                w_v_q <= 1'b0;
            end

            if (take_new_rd_w) begin
                ar_v_q     <= 1'b1;
                ax_addr_q  <= inport_addr_i;
                ax_id_q    <= inport_id_i;
                ax_len_q   <= inport_len_i;
                ax_burst_q <= inport_burst_i;
            end else if (ar_v_q && outport_arready_i) begin
                ar_v_q <= 1'b0;
            end
        end
    end
end

assign inport_accept_o   = take_new_wr_w | take_next_wr_w | take_new_rd_w;

assign outport_awvalid_o = aw_v_q;
assign outport_awaddr_o  = ax_addr_q;
assign outport_awid_o    = ax_id_q;
assign outport_awlen_o   = ax_len_q;
assign outport_awburst_o = ax_burst_q;

assign outport_wvalid_o  = w_v_q;
assign outport_wdata_o   = w_dat_q;
assign outport_wstrb_o   = w_stb_q;
assign outport_wlast_o   = w_lst_q;
assign outport_bready_o  = inport_bready_i;

assign outport_arvalid_o = ar_v_q;
assign outport_araddr_o  = ax_addr_q;
assign outport_arid_o    = ax_id_q;
assign outport_arlen_o   = ax_len_q;
assign outport_arburst_o = ax_burst_q;
assign outport_rready_o  = inport_rready_i;

assign inport_bvalid_o   = outport_bvalid_i;
assign inport_bresp_o    = outport_bresp_i;
assign inport_bid_o      = outport_bid_i;
assign inport_rvalid_o   = outport_rvalid_i;
assign inport_rdata_o    = outport_rdata_i;
assign inport_rresp_o    = outport_rresp_i;
assign inport_rid_o      = outport_rid_i;
assign inport_rlast_o    = outport_rlast_i;

endmodule
