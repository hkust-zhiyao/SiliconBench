//======================================================================
//
// sha512_masked_w_mem.sv
// -------------------
// Masked W message-schedule memory for the SHA-512 core with immediate
// masked handshake block capture and per-round share refreshing.
//
// Author: Joachim Strombergson
// Copyright (c) 2014 Secworks Sweden AB
// All rights reserved.
//
// Redistribution and use in source and binary forms, with or
// without modification, are permitted provided that the following
// conditions are met:
//
// 1. Redistributions of source code must retain the above copyright
//    notice, this list of conditions and the following disclaimer.
//
// 2. Redistributions in binary form must reproduce the above copyright
//    notice, this list of conditions and the following disclaimer in
//    the documentation and/or other materials provided with the
//    distribution.
//
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
// "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
// LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS
// FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE
// COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT,
// INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING,
// BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
// LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
// CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT,
// STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
// ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF
// ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
//
//======================================================================

module sha512_masked_w_mem
                    import sha512_masked_defines_pkg::*;
                    (
                    input wire            clk,
                    input wire            reset_n,
                    input wire            zeroize,

                    input wire [1023 : 0] block_msg,
                    input wire [1023 : 0] rw_masking_rnd,
                    input wire [4 : 0]    entropy,

                    input wire            capture_cmd,
                    input wire            init_cmd,
                    input wire            next_cmd,
                    output wire masked_reg_t  w_val
                   );

  //----------------------------------------------------------------
  // Registers including update variables and write enable.
  //----------------------------------------------------------------
  masked_reg_t w_mem [0 : 15];
  masked_reg_t w_mem_new [0 : 15];
  reg          w_mem_we;

  reg [6 : 0] w_ctr_reg;
  reg [6 : 0] w_ctr_new;
  reg         w_ctr_we;

  //----------------------------------------------------------------
  // Wires.
  //----------------------------------------------------------------
  masked_reg_t w_tmp;
  masked_reg_t w_new;

  assign w_val = w_tmp;

  //----------------------------------------------------------------
  // reg_update
  //----------------------------------------------------------------
  always @ (posedge clk or negedge reset_n)
    begin : reg_update
      integer ii;

      if (!reset_n) begin
        for (ii = 0; ii < 16; ii = ii + 1)
          w_mem[ii] <= {64'h0, 64'h0};

        w_ctr_reg <= 7'h0;
      end
      else begin
        if (zeroize) begin
          for (ii = 0; ii < 16; ii = ii + 1)
            w_mem[ii] <= {64'h0, 64'h0};

          w_ctr_reg <= 7'h0;
        end
        else begin
          if (w_mem_we) begin
            for (ii = 0; ii < 16; ii = ii + 1)
              w_mem[ii] <= w_mem_new[ii];
          end

          if (w_ctr_we)
            w_ctr_reg <= w_ctr_new;
        end
      end
    end // reg_update

  //----------------------------------------------------------------
  // select_w
  //----------------------------------------------------------------
  always @*
    begin : select_w
      if (w_ctr_reg < 7'd16)
        w_tmp = w_mem[w_ctr_reg[3 : 0]];
      else
        w_tmp = w_new;
    end // select_w

  //----------------------------------------------------------------
  // w_new_logic & per-round share refresh
  //----------------------------------------------------------------
  masked_reg_t w_0;
  masked_reg_t w_1;
  masked_reg_t w_9;
  masked_reg_t w_14;
  masked_reg_t d0;
  masked_reg_t d1;

  masked_reg_t w_0_b2a;
  masked_reg_t w_9_b2a;
  masked_reg_t d0_b2a;
  masked_reg_t d1_b2a;

  always @*
    begin : w_mem_update_logic
      integer k;
      logic [63:0] msg_word;
      logic [63:0] rnd_word;

      for (k = 0; k < 16; k = k + 1)
        w_mem_new[k] = {64'h0, 64'h0};
      w_mem_we = 1'b0;
      msg_word = 64'h0;
      rnd_word = 64'h0;

      w_0  = w_mem[0];
      w_1  = w_mem[1];
      w_9  = w_mem[9];
      w_14 = w_mem[14];

      d0 = {ROT1(w_1.masked), ROT1(w_1.random)};
      d1 = {ROT14(w_14.masked), ROT14(w_14.random)};

      w_0_b2a = B2A_conv(w_0, entropy[0]);
      d0_b2a  = B2A_conv(d0,  entropy[1]);
      w_9_b2a = B2A_conv(w_9, entropy[2]);
      d1_b2a  = B2A_conv(d1,  entropy[3]);

      w_new = A2B_conv(masked_sum(w_0_b2a, masked_sum(d0_b2a, masked_sum(w_9_b2a, d1_b2a))), entropy[4]);

      if (capture_cmd) begin
        for (k = 0; k < 16; k = k + 1) begin
          msg_word = block_msg[(15 - k) * 64 +: 64];
          rnd_word = rw_masking_rnd[(15 - k) * 64 +: 64];
          w_mem_new[k] = {msg_word ^ rnd_word, rnd_word};
        end
        w_mem_we = 1'b1;
      end
      else if (init_cmd) begin
        for (k = 0; k < 16; k = k + 1) begin
          rnd_word = rw_masking_rnd[(15 - k) * 64 +: 64];
          w_mem_new[k] = refresh_masked(w_mem[k], rnd_word);
        end
        w_mem_we = 1'b1;
      end
      else if (next_cmd) begin
        if (w_ctr_reg < 7'd16) begin
          for (k = 0; k < 16; k = k + 1) begin
            rnd_word = rw_masking_rnd[(15 - k) * 64 +: 64];
            w_mem_new[k] = refresh_masked(w_mem[k], rnd_word);
          end
        end
        else begin
          for (k = 0; k < 15; k = k + 1) begin
            rnd_word = rw_masking_rnd[(15 - k) * 64 +: 64];
            w_mem_new[k] = refresh_masked(w_mem[k + 1], rnd_word);
          end
          w_mem_new[15] = refresh_masked(w_new, rw_masking_rnd[63 : 0]);
        end
        w_mem_we = 1'b1;
      end
    end // w_mem_update_logic

  //----------------------------------------------------------------
  // w_ctr
  //----------------------------------------------------------------
  always @*
    begin : w_ctr
      w_ctr_new = 7'h0;
      w_ctr_we  = 1'h0;

      if (capture_cmd || init_cmd) begin
        w_ctr_new = 7'h00;
        w_ctr_we  = 1'h1;
      end
      else if (next_cmd) begin
        w_ctr_new = w_ctr_reg + 7'h01;
        w_ctr_we  = 1'h1;
      end
    end // w_ctr

endmodule
