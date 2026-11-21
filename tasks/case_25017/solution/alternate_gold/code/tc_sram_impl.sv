// Copyright 2020 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// IHP SG13G2 hard-macro wrapper for 256-word Tag (<=64b) and Wide Data (128b / 256b) SRAM cuts.

module tc_sram_impl #(
  parameter int unsigned NumWords   = 256,
  parameter int unsigned DataWidth  = 64,
  parameter int unsigned ByteWidth  = 8,
  parameter int unsigned NumPorts   = 1,
  parameter int unsigned Latency    = 1,
  parameter type         impl_in_t  = logic,
  parameter type         impl_out_t = logic,
  parameter int unsigned AddrWidth  = (NumWords > 32'd1) ? $clog2(NumWords) : 32'd1,
  parameter int unsigned BeWidth    = (DataWidth + ByteWidth - 32'd1) / ByteWidth
) (
  input  logic                                clk_i,
  input  logic                                rst_ni,
  input  impl_in_t                            impl_i,
  output impl_out_t                           impl_o,
  input  logic  [NumPorts-1:0]                req_i,
  input  logic  [NumPorts-1:0]                we_i,
  input  logic  [NumPorts-1:0][AddrWidth-1:0] addr_i,
  input  logic  [NumPorts-1:0][DataWidth-1:0] wdata_i,
  input  logic  [NumPorts-1:0][BeWidth-1:0]   be_i,
  output logic  [NumPorts-1:0][DataWidth-1:0] rdata_o
);

  wire _unused_ok = &{1'b0, rst_ni, impl_i};
  assign impl_o = '0;

  wire men = req_i[0];
  wire wen = req_i[0] & we_i[0];
  wire ren = req_i[0] & ~we_i[0];

  if (DataWidth <= 64) begin : gen_tag_macro
    logic [63:0] din_pad, dout_raw, bit_mask;

    always_comb begin
      din_pad  = 64'h0;
      bit_mask = 64'h0;
      din_pad[DataWidth-1:0] = wdata_i[0];
      for (int b = 0; b < DataWidth; b++) begin
        bit_mask[b] = be_i[0][b / ByteWidth];
      end
    end

    RM_IHPSG13_1P_256x64_c2_bm_bist u_sram (
      .A_CLK       ( clk_i     ),
      .A_MEN       ( men       ),
      .A_WEN       ( wen       ),
      .A_REN       ( ren       ),
      .A_ADDR      ( addr_i[0] ),
      .A_DIN       ( din_pad   ),
      .A_DLY       ( 1'b1      ),
      .A_DOUT      ( dout_raw  ),
      .A_BM        ( bit_mask  ),
      .A_BIST_CLK  ( 1'b0      ),
      .A_BIST_EN   ( 1'b0      ),
      .A_BIST_MEN  ( 1'b0      ),
      .A_BIST_WEN  ( 1'b0      ),
      .A_BIST_REN  ( 1'b0      ),
      .A_BIST_ADDR ( 8'h00     ),
      .A_BIST_DIN  ( 64'h0     ),
      .A_BIST_BM   ( 64'h0     )
    );

    assign rdata_o[0] = dout_raw[DataWidth-1:0];

  end else begin : gen_data_macros
    localparam int unsigned NumBanks = DataWidth / 64;
    logic [NumBanks-1:0][63:0] dout_bank;
    logic [NumBanks-1:0][63:0] mask_bank;

    always_comb begin
      for (int k = 0; k < NumBanks; k++) begin
        for (int b = 0; b < 64; b++) begin
          mask_bank[k][b] = be_i[0][(k * 64 + b) / ByteWidth];
        end
      end
    end

    for (genvar k = 0; k < NumBanks; k++) begin : g_bank
      RM_IHPSG13_1P_256x64_c2_bm_bist u_sram (
        .A_CLK       ( clk_i                      ),
        .A_MEN       ( men                        ),
        .A_WEN       ( wen                        ),
        .A_REN       ( ren                        ),
        .A_ADDR      ( addr_i[0]                  ),
        .A_DIN       ( wdata_i[0][k*64 +: 64]     ),
        .A_DLY       ( 1'b1                       ),
        .A_DOUT      ( dout_bank[k]               ),
        .A_BM        ( mask_bank[k]               ),
        .A_BIST_CLK  ( 1'b0                       ),
        .A_BIST_EN   ( 1'b0                       ),
        .A_BIST_MEN  ( 1'b0                       ),
        .A_BIST_WEN  ( 1'b0                       ),
        .A_BIST_REN  ( 1'b0                       ),
        .A_BIST_ADDR ( 8'h00                      ),
        .A_BIST_DIN  ( 64'h0                      ),
        .A_BIST_BM   ( 64'h0                      )
      );
      assign rdata_o[0][k*64 +: 64] = dout_bank[k];
    end
  end

endmodule
