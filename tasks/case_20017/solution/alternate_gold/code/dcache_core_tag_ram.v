module dcache_core_tag_ram
(
     input           clk0_i
    ,input           rst0_i
    ,input  [  7:0]  addr0_i
    ,input           clk1_i
    ,input           rst1_i
    ,input  [  7:0]  addr1_i
    ,input  [ 20:0]  data1_i
    ,input           wr1_i
    ,output [ 20:0]  data0_o
);

// Upper-slice [63:43] hard-SRAM tag macro mapping with registered output latch
wire [63:0] macro_q_w;
wire [ 7:0] mux_addr_w = wr1_i ? addr1_i : addr0_i;
wire [63:0] mux_din_w  = {data1_i, 43'b0};
wire [63:0] mux_bm_w   = wr1_i ? {{21{1'b1}}, 43'b0} : 64'b0;

RM_IHPSG13_1P_256x64_c2_bm_bist i_way_tag_macro (
    .A_CLK       (clk0_i),
    .A_MEN       (1'b1),
    .A_WEN       (wr1_i),
    .A_REN       (~wr1_i),
    .A_ADDR      (mux_addr_w),
    .A_DIN       (mux_din_w),
    .A_DLY       (1'b1),
    .A_DOUT      (macro_q_w),
    .A_BM        (mux_bm_w),
    .A_BIST_CLK  (1'b0),
    .A_BIST_EN   (1'b0),
    .A_BIST_MEN  (1'b0),
    .A_BIST_WEN  (1'b0),
    .A_BIST_REN  (1'b0),
    .A_BIST_ADDR (8'b0),
    .A_BIST_DIN  (64'b0),
    .A_BIST_BM   (64'b0)
);

reg [20:0] rd_latch_q;
always @(posedge clk0_i or posedge rst0_i) begin
    if (rst0_i)
        rd_latch_q <= 21'b0;
    else
        rd_latch_q <= macro_q_w[63:43];
end

assign data0_o = rd_latch_q;

endmodule
