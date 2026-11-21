// SPDX-License-Identifier: BSD-3-Clause
// BlackParrot D-Cache 256x128 dual-cut closely-coupled data bank wrapper (2x RM_IHPSG13_1P_256x64_c2_bm_bist)
`define BP_IHP13_SRAM_256x64_TIEOFF \
  .A_BIST_CLK   (  1'b0 ), \
  .A_BIST_ADDR  (  8'd0 ), \
  .A_BIST_DIN   ( 64'd0 ), \
  .A_BIST_BM    ( 64'd0 ), \
  .A_BIST_MEN   (  1'b0 ), \
  .A_BIST_WEN   (  1'b0 ), \
  .A_BIST_REN   (  1'b0 ), \
  .A_BIST_EN    (  1'b0 ), \
  .A_DLY        (  1'b0 )

module bp_sram_256x128 (
  input  logic         clk_i,
  input  logic         rst_ni,
  input  logic         req_i,
  input  logic         we_i,
  input  logic [7:0]   addr_i,
  input  logic [127:0] wdata_i,
  input  logic [15:0]  be_i,
  output logic [127:0] rdata_o
);
  // Assemble bit mask
  logic [0:0][127:0] bm;
  for (genvar p = 0; p < 1; ++p) begin : gen_bm_ports
    for (genvar b = 0; b < 128; ++b) begin : gen_bm_bits
      assign bm[p][b] = be_i[b / 8];
    end
  end

  if (1) begin : gen_256x128xBx1
    logic [1:0][63:0] wdata64, rdata64, bm64;
    assign rdata_o = rdata64;
    assign wdata64 = wdata_i;
    assign bm64    = bm;

    RM_IHPSG13_1P_256x64_c2_bm_bist i_cut_high (
      .A_CLK  ( clk_i      ),
      .A_ADDR ( addr_i     ),
      .A_BM   ( bm64[1]    ),
      .A_MEN  ( req_i      ),
      .A_WEN  ( we_i       ),
      .A_REN  ( ~we_i      ),
      .A_DIN  ( wdata64[1] ),
      .A_DOUT ( rdata64[1] ),
      `BP_IHP13_SRAM_256x64_TIEOFF
    );

    RM_IHPSG13_1P_256x64_c2_bm_bist i_cut_low (
      .A_CLK  ( clk_i      ),
      .A_ADDR ( addr_i     ),
      .A_BM   ( bm64[0]    ),
      .A_MEN  ( req_i      ),
      .A_WEN  ( we_i       ),
      .A_REN  ( ~we_i      ),
      .A_DIN  ( wdata64[0] ),
      .A_DOUT ( rdata64[0] ),
      `BP_IHP13_SRAM_256x64_TIEOFF
    );
  end
endmodule
