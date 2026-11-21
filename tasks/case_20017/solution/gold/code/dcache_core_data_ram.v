module dcache_core_data_ram
(
     input           clk0_i
    ,input           rst0_i
    ,input  [ 10:0]  addr0_i
    ,input  [ 31:0]  data0_i
    ,input  [  3:0]  wr0_i
    ,input           clk1_i
    ,input           rst1_i
    ,input  [ 10:0]  addr1_i
    ,input  [ 31:0]  data1_i
    ,input  [  3:0]  wr1_i
    ,output [ 31:0]  data0_o
    ,output [ 31:0]  data1_o
);

wire        wr_any_w = (|wr1_i);
wire [31:0] bm32_w   = {{8{wr1_i[3]}}, {8{wr1_i[2]}}, {8{wr1_i[1]}}, {8{wr1_i[0]}}};
wire [63:0] bm64_w   = addr1_i[0] ? {bm32_w, 32'b0} : {32'b0, bm32_w};
wire [63:0] din64_w  = {data1_i, data1_i};

wire [63:0] bank_dout_w [0:3];
reg  [1:0]  rd_bank_q;
reg         rd_hi_q;
reg  [31:0] data0_q;

always @(posedge clk0_i or posedge rst0_i) begin
    if (rst0_i) begin
        rd_bank_q <= 2'b00;
        rd_hi_q   <= 1'b0;
        data0_q   <= 32'b0;
    end else begin
        rd_bank_q <= addr0_i[10:9];
        rd_hi_q   <= addr0_i[0];
        data0_q   <= rd_hi_q ? bank_dout_w[rd_bank_q][63:32] : bank_dout_w[rd_bank_q][31:0];
    end
end

genvar b;
generate
    for (b = 0; b < 4; b = b + 1) begin : gen_bank
        wire       b_wr_w   = wr_any_w && (addr1_i[10:9] == b[1:0]);
        wire       b_rd_w   = (~b_wr_w) && (addr0_i[10:9] == b[1:0]);
        wire [7:0] b_addr_w = b_wr_w ? addr1_i[8:1] : addr0_i[8:1];

        RM_IHPSG13_1P_256x64_c2_bm_bist u_data_sram (
            .A_CLK       (clk0_i),
            .A_MEN       (b_wr_w | b_rd_w),
            .A_WEN       (b_wr_w),
            .A_REN       (b_rd_w),
            .A_ADDR      (b_addr_w),
            .A_DIN       (din64_w),
            .A_DLY       (1'b1),
            .A_DOUT      (bank_dout_w[b]),
            .A_BM        (b_wr_w ? bm64_w : 64'b0),
            .A_BIST_CLK  (1'b0),
            .A_BIST_EN   (1'b0),
            .A_BIST_MEN  (1'b0),
            .A_BIST_WEN  (1'b0),
            .A_BIST_REN  (1'b0),
            .A_BIST_ADDR (8'b0),
            .A_BIST_DIN  (64'b0),
            .A_BIST_BM   (64'b0)
        );
    end
endgenerate

assign data0_o = data0_q;
assign data1_o = 32'b0;

endmodule
