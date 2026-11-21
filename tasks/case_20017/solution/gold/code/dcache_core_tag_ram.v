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

wire [63:0] sram_dout_w;
wire [7:0]  sram_addr_w = wr1_i ? addr1_i : addr0_i;
wire [63:0] sram_din_w  = {43'b0, data1_i};
wire [63:0] sram_bm_w   = wr1_i ? {43'b0, 21'h1F_FFFF} : 64'b0;

RM_IHPSG13_1P_256x64_c2_bm_bist u_tag_sram (
    .A_CLK       (clk0_i),
    .A_MEN       (1'b1),
    .A_WEN       (wr1_i),
    .A_REN       (~wr1_i),
    .A_ADDR      (sram_addr_w),
    .A_DIN       (sram_din_w),
    .A_DLY       (1'b1),
    .A_DOUT      (sram_dout_w),
    .A_BM        (sram_bm_w),
    .A_BIST_CLK  (1'b0),
    .A_BIST_EN   (1'b0),
    .A_BIST_MEN  (1'b0),
    .A_BIST_WEN  (1'b0),
    .A_BIST_REN  (1'b0),
    .A_BIST_ADDR (8'b0),
    .A_BIST_DIN  (64'b0),
    .A_BIST_BM   (64'b0)
);

reg [20:0] data0_q;
always @(posedge clk0_i or posedge rst0_i) begin
    if (rst0_i)
        data0_q <= 21'b0;
    else
        data0_q <= sram_dout_w[20:0];
end

assign data0_o = data0_q;

endmodule
