// ================================================================
// NVDLA Open Source Project
//
// Copyright(c) 2016 - 2017 NVIDIA Corporation.  Licensed under the
// NVDLA Open Hardware License; Check "LICENSE" which comes with
// this distribution for more information.
// ================================================================

// File Name: NV_DW_lsd.v

module NV_DW_lsd (a, dec, enc);
  parameter a_width = 8;
  parameter b_width = a_width-1;
  localparam enc_width = ((a_width>16)?((a_width>64)?((a_width>128)?8:7):((a_width>32)?6:5)):((a_width>4)?((a_width>8)?4:3):((a_width>2)?2:1)));
  input     [a_width-1:0] a;
  output    [a_width-1:0] dec;
  output [enc_width-1:0] enc;

  reg [enc_width-1:0] enc_r;
  integer k;
  always @(*) begin
    enc_r = a_width - 1;
    for (k = 0; k <= a_width - 2; k = k + 1) begin
      if (a[k+1] != a[k]) begin
        enc_r = a_width - k - 2;
      end
    end
  end

  assign enc = enc_r;
  assign dec = ({{b_width{1'b0}}, 1'b1} << (b_width - enc_r));
endmodule
