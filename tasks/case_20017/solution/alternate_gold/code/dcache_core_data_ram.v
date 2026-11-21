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

// Low-order doubleword-interleaved 4-bank hard-SRAM array (bank = addr[2:1], row = addr[10:3])
wire        we_any_w   = |wr1_i;
wire [31:0] byte_msk_w = {{8{wr1_i[3]}}, {8{wr1_i[2]}}, {8{wr1_i[1]}}, {8{wr1_i[0]}}};
wire [63:0] full_bm_w  = addr1_i[0] ? {byte_msk_w, 32'b0} : {32'b0, byte_msk_w};
wire [63:0] full_din_w = {data1_i, data1_i};

wire [63:0] b_dout_w [0:3];
reg  [ 1:0] sel_bank_d1_q;
reg         sel_word_d1_q;
reg  [31:0] rd_word_q;

always @(posedge clk0_i or posedge rst0_i) begin
    if (rst0_i) begin
        sel_bank_d1_q <= 2'b00;
        sel_word_d1_q <= 1'b0;
        rd_word_q     <= 32'b0;
    end else begin
        sel_bank_d1_q <= addr0_i[2:1];
        sel_word_d1_q <= addr0_i[0];
        rd_word_q     <= sel_word_d1_q ? b_dout_w[sel_bank_d1_q][63:32] : b_dout_w[sel_bank_d1_q][31:0];
    end
end

genvar g;
generate
    for (g = 0; g < 4; g = g + 1) begin : g_interleaved_bank
        wire       wr_hit_w = we_any_w && (addr1_i[2:1] == g[1:0]);
        wire       rd_hit_w = (~wr_hit_w) && (addr0_i[2:1] == g[1:0]);
        wire [7:0] row_w    = wr_hit_w ? addr1_i[10:3] : addr0_i[10:3];

        RM_IHPSG13_1P_256x64_c2_bm_bist i_bank_macro (
            .A_CLK       (clk0_i),
            .A_MEN       (wr_hit_w | rd_hit_w),
            .A_WEN       (wr_hit_w),
            .A_REN       (rd_hit_w),
            .A_ADDR      (row_w),
            .A_DIN       (full_din_w),
            .A_DLY       (1'b1),
            .A_DOUT      (b_dout_w[g]),
            .A_BM        (wr_hit_w ? full_bm_w : 64'b0),
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

assign data0_o = rd_word_q;
assign data1_o = 32'b0;

endmodule
