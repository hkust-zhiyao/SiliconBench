//======================================================================
//
// sha512_masked_core.sv
// -------------
// Side-channel hardened boolean/arithmetic masked SHA-512 family core.
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

module sha512_masked_core
                  import sha512_masked_defines_pkg::*;
                  (
                   // Clock and reset.
                   input wire            clk,
                   input wire            reset_n,
                   input wire            zeroize,
                   // Control.
                   input wire            init_cmd,
                   input wire            next_cmd,
                   input wire [1 : 0]    mode,

                   // Data port.
                   input wire [191 : 0]  entropy,
                   input wire [1023 : 0] block_msg,

                   output wire           ready,
                   output wire [511 : 0] digest,
                   output wire           digest_valid
                  );

  //----------------------------------------------------------------
  // Internal constant and parameter definitions.
  //----------------------------------------------------------------
  localparam [6:0] SHA512_ROUNDS = 7'd79;
  localparam [6:0] SHA512_RNDs   = 7'd8;

  localparam [1:0] CTRL_IDLE   = 2'h0;
  localparam [1:0] CTRL_RND    = 2'h1;
  localparam [1:0] CTRL_ROUNDS = 2'h2;
  localparam [1:0] CTRL_DONE   = 2'h3;

  localparam [1:0] MODE_SHA512_224 = 2'h0;
  localparam [1:0] MODE_SHA512_256 = 2'h1;
  localparam [1:0] MODE_SHA384     = 2'h2;
  localparam [1:0] MODE_SHA512     = 2'h3;

  //----------------------------------------------------------------
  // Registers and mask pool.
  //----------------------------------------------------------------
  logic               masking_init;
  logic               masking_update;
  logic [23:0][63:0]  masking_rnd;
  logic [27:0][63:0]  cur_rnd;
  logic [7:0][63:0]   rh_masking_rnd;
  logic [1023:0]      rw_masking_rnd;
  logic [4:0]         w_q_rnd;
  logic [9:0]         q_masking_rnd;
  logic [23:0]        q_done_rnd;

  logic init_reg_set;
  logic init_reg_reset;
  logic init_reg;

  logic       mode_we;
  logic [1:0] mode_reg;

  logic chain_valid_set;
  logic chain_valid_reg;

  masked_reg_t a_reg;
  masked_reg_t a_new;
  masked_reg_t b_reg;
  masked_reg_t b_new;
  masked_reg_t c_reg;
  masked_reg_t c_new;
  masked_reg_t d_reg;
  masked_reg_t d_new;
  masked_reg_t e_reg;
  masked_reg_t e_new;
  masked_reg_t f_reg;
  masked_reg_t f_new;
  masked_reg_t g_reg;
  masked_reg_t g_new;
  masked_reg_t h_reg;
  masked_reg_t h_new;
  reg          a_h_we;

  // Masked two-share chaining state (never stored in plaintext).
  masked_reg_t H_reg [0 : 7];
  masked_reg_t H_new [0 : 7];
  reg          H_we;

  reg [6 : 0]  round_ctr_reg;
  reg [6 : 0]  round_ctr_new;
  reg          round_ctr_we;
  reg          round_ctr_inc;
  reg          round_ctr_rst;

  reg          ready_reg;
  reg          ready_new;
  reg          ready_we;

  reg          digest_valid_reg;
  reg          digest_valid_new;
  reg          digest_valid_we;

  reg [1 : 0]  sha512_ctrl_reg;
  reg [1 : 0]  sha512_ctrl_new;
  reg          sha512_ctrl_we;

  reg [6 : 0]  rnd_ctr_reg;
  reg [6 : 0]  rnd_ctr_new;
  reg          rnd_ctr_we;
  reg          rnd_ctr_inc;
  reg          rnd_ctr_rst;

  //----------------------------------------------------------------
  // Wires.
  //----------------------------------------------------------------
  reg digest_init;
  reg digest_update;

  reg state_init;
  reg state_update;

  reg first_block;

  masked_reg_t t1_b2a;
  masked_reg_t t2_b2a;
  masked_reg_t a_new_a2b;
  masked_reg_t e_new_a2b;

  wire [63 : 0] k_data;

  reg           w_capture;
  reg           w_init;
  reg           w_next;
  masked_reg_t  w_data;

  wire [63 : 0] H0_0;
  wire [63 : 0] H0_1;
  wire [63 : 0] H0_2;
  wire [63 : 0] H0_3;
  wire [63 : 0] H0_4;
  wire [63 : 0] H0_5;
  wire [63 : 0] H0_6;
  wire [63 : 0] H0_7;

  logic [511 : 0] digest_out;

  //----------------------------------------------------------------
  // Dynamic combinational mask derivation (zero-cycle entropy injection
  // combined with persistent 1536-bit evolving mask pool).
  //----------------------------------------------------------------
  always @*
    begin : cur_rnd_gen
      integer m;
      for (m = 0; m < 24; m = m + 1) begin
        cur_rnd[m] = masking_rnd[m] ^ expand_entropy_word(entropy, m);
      end
      for (m = 24; m < 28; m = m + 1) begin
        cur_rnd[m] = rot64(masking_rnd[m - 24], 17) ^
                     rot64(masking_rnd[m - 16], 43) ^
                     rot64(masking_rnd[m - 8],  55) ^
                     expand_entropy_word(entropy, m);
      end
    end

  genvar i;
  generate
    for (i = 0; i < 8; i = i + 1) begin : rh_masking_assign
      assign rh_masking_rnd[i] = cur_rnd[i];
    end
  endgenerate

  assign rw_masking_rnd = {cur_rnd[08], cur_rnd[09], cur_rnd[10], cur_rnd[11],
                           cur_rnd[12], cur_rnd[13], cur_rnd[14], cur_rnd[15],
                           cur_rnd[16], cur_rnd[17], cur_rnd[18], cur_rnd[19],
                           cur_rnd[20], cur_rnd[21], cur_rnd[22], cur_rnd[23]};

  assign w_q_rnd       = cur_rnd[24][4:0]  ^ entropy[4:0];
  assign q_masking_rnd = cur_rnd[25][9:0]  ^ entropy[14:5];
  assign q_done_rnd    = cur_rnd[26][23:0] ^ entropy[38:15];

  //----------------------------------------------------------------
  // Module instantiations.
  //----------------------------------------------------------------
  sha512_k_constants k_constants_inst(
      .addr(round_ctr_reg),
      .K_val(k_data)
      );

  sha512_h_constants h_constants_inst(
      .mode(mode_reg),
      .H0(H0_0),
      .H1(H0_1),
      .H2(H0_2),
      .H3(H0_3),
      .H4(H0_4),
      .H5(H0_5),
      .H6(H0_6),
      .H7(H0_7)
      );

  sha512_masked_w_mem w_mem_inst(
      .clk(clk),
      .reset_n(reset_n),
      .zeroize(zeroize),

      .block_msg(block_msg),
      .rw_masking_rnd(rw_masking_rnd),
      .entropy(w_q_rnd),

      .capture_cmd(w_capture),
      .init_cmd(w_init),
      .next_cmd(w_next),
      .w_val(w_data)
      );

  //----------------------------------------------------------------
  // Concurrent connectivity & gated mode-truncated digest output.
  //----------------------------------------------------------------
  assign ready        = ready_reg;
  assign digest       = digest_out;
  assign digest_valid = digest_valid_reg;

  always @*
    begin : digest_output_mux
      integer k;
      logic [63:0] d_word [0:7];

      for (k = 0; k < 8; k = k + 1) begin
        // Gate both shares with digest_valid_reg prior to XOR so no internal net
        // unmasks H_reg while digest_valid_reg == 0.
        d_word[k] = ({64{digest_valid_reg}} & H_reg[k].masked) ^
                    ({64{digest_valid_reg}} & H_reg[k].random);
      end

      if (!digest_valid_reg) begin
        digest_out = 512'h0;
      end
      else begin
        unique case (mode_reg)
          MODE_SHA512_224: digest_out = {d_word[0], d_word[1], d_word[2], d_word[3][63:32], 288'h0};
          MODE_SHA512_256: digest_out = {d_word[0], d_word[1], d_word[2], d_word[3], 256'h0};
          MODE_SHA384:     digest_out = {d_word[0], d_word[1], d_word[2], d_word[3],
                                         d_word[4], d_word[5], 128'h0};
          default:         digest_out = {d_word[0], d_word[1], d_word[2], d_word[3],
                                         d_word[4], d_word[5], d_word[6], d_word[7]};
        endcase
      end
    end

  //----------------------------------------------------------------
  // reg_update
  //----------------------------------------------------------------
  always @ (posedge clk or negedge reset_n)
    begin : reg_update
      integer k;
      if (!reset_n)
        begin
          a_reg               <= {64'h0, 64'h0};
          b_reg               <= {64'h0, 64'h0};
          c_reg               <= {64'h0, 64'h0};
          d_reg               <= {64'h0, 64'h0};
          e_reg               <= {64'h0, 64'h0};
          f_reg               <= {64'h0, 64'h0};
          g_reg               <= {64'h0, 64'h0};
          h_reg               <= {64'h0, 64'h0};
          for (k = 0; k < 8; k = k + 1)
            H_reg[k]          <= {64'h0, 64'h0};
          ready_reg           <= 1'b1;
          digest_valid_reg    <= 1'b0;
          round_ctr_reg       <= 7'h0;
          rnd_ctr_reg         <= 7'h0;
          sha512_ctrl_reg     <= CTRL_IDLE;
          masking_rnd         <= '0;
          mode_reg            <= 2'h0;
          chain_valid_reg     <= 1'b0;
        end
      else if (zeroize)
        begin
          a_reg               <= {64'h0, 64'h0};
          b_reg               <= {64'h0, 64'h0};
          c_reg               <= {64'h0, 64'h0};
          d_reg               <= {64'h0, 64'h0};
          e_reg               <= {64'h0, 64'h0};
          f_reg               <= {64'h0, 64'h0};
          g_reg               <= {64'h0, 64'h0};
          h_reg               <= {64'h0, 64'h0};
          for (k = 0; k < 8; k = k + 1)
            H_reg[k]          <= {64'h0, 64'h0};
          ready_reg           <= 1'b1;
          digest_valid_reg    <= 1'b0;
          round_ctr_reg       <= 7'h0;
          rnd_ctr_reg         <= 7'h0;
          sha512_ctrl_reg     <= CTRL_IDLE;
          masking_rnd         <= '0;
          mode_reg            <= 2'h0;
          chain_valid_reg     <= 1'b0;
        end
      else
        begin
          if (a_h_we)
            begin
              a_reg <= a_new;
              b_reg <= b_new;
              c_reg <= c_new;
              d_reg <= d_new;
              e_reg <= e_new;
              f_reg <= f_new;
              g_reg <= g_new;
              h_reg <= h_new;
            end

          if (H_we)
            begin
              for (k = 0; k < 8; k = k + 1)
                H_reg[k] <= H_new[k];
            end

          if (round_ctr_we)
            round_ctr_reg <= round_ctr_new;

          if (rnd_ctr_we)
            rnd_ctr_reg <= rnd_ctr_new;

          if (ready_we)
            ready_reg <= ready_new;

          if (digest_valid_we)
            digest_valid_reg <= digest_valid_new;

          if (sha512_ctrl_we)
            sha512_ctrl_reg <= sha512_ctrl_new;

          if (mode_we)
            mode_reg <= mode;

          if (chain_valid_set)
            chain_valid_reg <= 1'b1;

          if (masking_init && (rnd_ctr_reg < SHA512_RNDs)) begin
            masking_rnd[3 * rnd_ctr_reg[2 : 0]]     <= masking_rnd[3 * rnd_ctr_reg[2 : 0]]     ^ entropy[63  :   0];
            masking_rnd[3 * rnd_ctr_reg[2 : 0] + 1] <= masking_rnd[3 * rnd_ctr_reg[2 : 0] + 1] ^ entropy[127 :  64];
            masking_rnd[3 * rnd_ctr_reg[2 : 0] + 2] <= masking_rnd[3 * rnd_ctr_reg[2 : 0] + 2] ^ entropy[191 : 128];
          end
          else if (masking_update) begin
            for (k = 0; k < 24; k = k + 1) begin
              masking_rnd[k] <= rot64(masking_rnd[(k + 3) % 24], 9) ^
                                expand_entropy_word(entropy, k + 1);
            end
          end
        end
    end // reg_update

  always @ (posedge clk or negedge reset_n)
    begin : init_reg_update
      if (!reset_n)
        init_reg <= 1'b0;
      else if (zeroize)
        init_reg <= 1'b0;
      else if (init_reg_set)
        init_reg <= 1'b1;
      else if (init_reg_reset)
        init_reg <= 1'b0;
    end // init_reg_update

  //----------------------------------------------------------------
  // digest_logic: Masked chaining state initialization and addition.
  //----------------------------------------------------------------
  always @*
    begin : digest_logic
      integer k;
      masked_reg_t st_arr [0:7];
      masked_reg_t h_b2a;
      masked_reg_t s_b2a;
      masked_reg_t sum_a2b;
      logic [63:0] h_init_const [0:7];

      st_arr[0] = a_reg;
      st_arr[1] = b_reg;
      st_arr[2] = c_reg;
      st_arr[3] = d_reg;
      st_arr[4] = e_reg;
      st_arr[5] = f_reg;
      st_arr[6] = g_reg;
      st_arr[7] = h_reg;

      h_init_const[0] = H0_0;
      h_init_const[1] = H0_1;
      h_init_const[2] = H0_2;
      h_init_const[3] = H0_3;
      h_init_const[4] = H0_4;
      h_init_const[5] = H0_5;
      h_init_const[6] = H0_6;
      h_init_const[7] = H0_7;

      for (k = 0; k < 8; k = k + 1)
        H_new[k] = {64'h0, 64'h0};
      H_we    = 1'b0;
      h_b2a   = {64'h0, 64'h0};
      s_b2a   = {64'h0, 64'h0};
      sum_a2b = {64'h0, 64'h0};

      if (digest_init)
        begin
          for (k = 0; k < 8; k = k + 1) begin
            H_new[k] = {h_init_const[k] ^ cur_rnd[16 + k], cur_rnd[16 + k]};
          end
          H_we = 1'b1;
        end
      else if (digest_update)
        begin
          for (k = 0; k < 8; k = k + 1) begin
            h_b2a   = B2A_conv(H_reg[k],  q_done_rnd[3 * k]);
            s_b2a   = B2A_conv(st_arr[k], q_done_rnd[3 * k + 1]);
            sum_a2b = A2B_conv(masked_sum(h_b2a, s_b2a), q_done_rnd[3 * k + 2]);
            H_new[k] = refresh_masked(sum_a2b, rh_masking_rnd[k]);
          end
          H_we = 1'b1;
        end
    end // digest_logic

  //----------------------------------------------------------------
  // t1_logic
  //----------------------------------------------------------------
  always @*
    begin : t1_logic
      masked_reg_t sum1;
      masked_reg_t ch;
      masked_reg_t k_data_s;

      masked_reg_t h_reg_b2a;
      masked_reg_t sum1_b2a;
      masked_reg_t ch_b2a;
      masked_reg_t k_data_b2a;
      masked_reg_t w_data_b2a;

      sum1 = {sigma1(e_reg.masked), sigma1(e_reg.random)};
      ch   = masked_ch_fresh(e_reg, f_reg, g_reg, cur_rnd[24]);

      k_data_s   = {k_data ^ cur_rnd[26], cur_rnd[26]};
      h_reg_b2a  = B2A_conv(h_reg,    q_masking_rnd[0]);
      sum1_b2a   = B2A_conv(sum1,     q_masking_rnd[1]);
      ch_b2a     = B2A_conv(ch,       q_masking_rnd[2]);
      k_data_b2a = B2A_conv(k_data_s, q_masking_rnd[3]);
      w_data_b2a = B2A_conv(w_data,   q_masking_rnd[4]);

      t1_b2a = masked_sum(h_reg_b2a, masked_sum(sum1_b2a, masked_sum(ch_b2a, masked_sum(k_data_b2a, w_data_b2a))));
    end // t1_logic

  //----------------------------------------------------------------
  // t2_logic
  //----------------------------------------------------------------
  always @*
    begin : t2_logic
      masked_reg_t sum0;
      masked_reg_t maj;

      masked_reg_t sum0_b2a;
      masked_reg_t maj_b2a;

      sum0 = {sigma0(a_reg.masked), sigma0(a_reg.random)};
      maj  = masked_maj_fresh(a_reg, b_reg, c_reg, cur_rnd[25]);

      sum0_b2a = B2A_conv(sum0, q_masking_rnd[5]);
      maj_b2a  = B2A_conv(maj,  q_masking_rnd[6]);

      t2_b2a = masked_sum(sum0_b2a, maj_b2a);
    end // t2_logic

  //----------------------------------------------------------------
  // A2B_logic
  //----------------------------------------------------------------
  always @*
    begin : A2B_logic
      masked_reg_t d_reg_b2a;

      d_reg_b2a = B2A_conv(d_reg, q_masking_rnd[7]);

      a_new_a2b = A2B_conv(masked_sum(t1_b2a, t2_b2a),    q_masking_rnd[8]);
      e_new_a2b = A2B_conv(masked_sum(d_reg_b2a, t1_b2a), q_masking_rnd[9]);
    end // A2B_logic

  //----------------------------------------------------------------
  // state_logic: Per-round refresh across all 8 working registers.
  //----------------------------------------------------------------
  always @*
    begin : state_logic
      a_new  = {64'h0, 64'h0};
      b_new  = {64'h0, 64'h0};
      c_new  = {64'h0, 64'h0};
      d_new  = {64'h0, 64'h0};
      e_new  = {64'h0, 64'h0};
      f_new  = {64'h0, 64'h0};
      g_new  = {64'h0, 64'h0};
      h_new  = {64'h0, 64'h0};
      a_h_we = 1'b0;

      if (state_init)
        begin
          if (first_block)
            begin
              a_new  = {H0_0 ^ rh_masking_rnd[0], rh_masking_rnd[0]};
              b_new  = {H0_1 ^ rh_masking_rnd[1], rh_masking_rnd[1]};
              c_new  = {H0_2 ^ rh_masking_rnd[2], rh_masking_rnd[2]};
              d_new  = {H0_3 ^ rh_masking_rnd[3], rh_masking_rnd[3]};
              e_new  = {H0_4 ^ rh_masking_rnd[4], rh_masking_rnd[4]};
              f_new  = {H0_5 ^ rh_masking_rnd[5], rh_masking_rnd[5]};
              g_new  = {H0_6 ^ rh_masking_rnd[6], rh_masking_rnd[6]};
              h_new  = {H0_7 ^ rh_masking_rnd[7], rh_masking_rnd[7]};
              a_h_we = 1'b1;
            end
          else
            begin
              a_new  = refresh_masked(H_reg[0], rh_masking_rnd[0]);
              b_new  = refresh_masked(H_reg[1], rh_masking_rnd[1]);
              c_new  = refresh_masked(H_reg[2], rh_masking_rnd[2]);
              d_new  = refresh_masked(H_reg[3], rh_masking_rnd[3]);
              e_new  = refresh_masked(H_reg[4], rh_masking_rnd[4]);
              f_new  = refresh_masked(H_reg[5], rh_masking_rnd[5]);
              g_new  = refresh_masked(H_reg[6], rh_masking_rnd[6]);
              h_new  = refresh_masked(H_reg[7], rh_masking_rnd[7]);
              a_h_we = 1'b1;
            end
        end
      else if (state_update)
        begin
          a_new  = refresh_masked(a_new_a2b, rh_masking_rnd[0]);
          b_new  = refresh_masked(a_reg,     rh_masking_rnd[1]);
          c_new  = refresh_masked(b_reg,     rh_masking_rnd[2]);
          d_new  = refresh_masked(c_reg,     rh_masking_rnd[3]);
          e_new  = refresh_masked(e_new_a2b, rh_masking_rnd[4]);
          f_new  = refresh_masked(e_reg,     rh_masking_rnd[5]);
          g_new  = refresh_masked(f_reg,     rh_masking_rnd[6]);
          h_new  = refresh_masked(g_reg,     rh_masking_rnd[7]);
          a_h_we = 1'b1;
        end
    end // state_logic

  //----------------------------------------------------------------
  // round_ctr
  //----------------------------------------------------------------
  always @*
    begin : round_ctr
      round_ctr_new = '0;
      round_ctr_we  = 1'b0;

      if (round_ctr_rst)
        begin
          round_ctr_new = '0;
          round_ctr_we  = 1'b1;
        end
      else if (round_ctr_inc)
        begin
          round_ctr_new = round_ctr_reg + 1'b1;
          round_ctr_we  = 1'b1;
        end
    end // round_ctr

  //----------------------------------------------------------------
  // rnd_ctr
  //----------------------------------------------------------------
  always @*
    begin : rnd_ctr
      rnd_ctr_new = '0;
      rnd_ctr_we  = 1'b0;

      if (rnd_ctr_rst)
        begin
          rnd_ctr_new = '0;
          rnd_ctr_we  = 1'b1;
        end
      else if (rnd_ctr_inc)
        begin
          rnd_ctr_new = rnd_ctr_reg + 1'b1;
          rnd_ctr_we  = 1'b1;
        end
    end // rnd_ctr

  //----------------------------------------------------------------
  // masking_random control
  //----------------------------------------------------------------
  always @*
    begin : masking_random
      masking_init   = rnd_ctr_inc;
      masking_update = round_ctr_inc | digest_update;
    end // masking_random

  //----------------------------------------------------------------
  // sha512_ctrl_fsm
  //----------------------------------------------------------------
  always @*
    begin : sha512_ctrl_fsm
      logic valid_init_cmd;
      logic valid_next_cmd;

      digest_init      = 1'b0;
      digest_update    = 1'b0;
      state_init       = 1'b0;
      state_update     = 1'b0;
      first_block      = 1'b0;
      w_capture        = 1'b0;
      w_init           = 1'b0;
      w_next           = 1'b0;
      round_ctr_inc    = 1'b0;
      round_ctr_rst    = 1'b0;
      digest_valid_new = 1'b0;
      digest_valid_we  = 1'b0;
      ready_new        = 1'b0;
      ready_we         = 1'b0;
      sha512_ctrl_new  = CTRL_IDLE;
      sha512_ctrl_we   = 1'b0;
      rnd_ctr_inc      = 1'b0;
      rnd_ctr_rst      = 1'b0;
      init_reg_set     = 1'b0;
      init_reg_reset   = 1'b0;
      mode_we          = 1'b0;
      chain_valid_set  = 1'b0;

      valid_init_cmd = init_cmd && !next_cmd;
      valid_next_cmd = !init_cmd && next_cmd && chain_valid_reg;

      unique case (sha512_ctrl_reg)
        CTRL_IDLE:
          begin
            if (valid_init_cmd || valid_next_cmd)
              begin
                w_capture        = 1'b1;
                ready_new        = 1'b0;
                ready_we         = 1'b1;
                digest_valid_new = 1'b0;
                digest_valid_we  = 1'b1;
                rnd_ctr_rst      = 1'b1;
                sha512_ctrl_new  = CTRL_RND;
                sha512_ctrl_we   = 1'b1;
                if (valid_init_cmd) begin
                  init_reg_set   = 1'b1;
                  mode_we        = 1'b1;
                end
                else begin
                  init_reg_reset = 1'b1;
                end
              end
          end

        CTRL_RND:
          begin
            rnd_ctr_inc = 1'b1;

            if (rnd_ctr_reg == SHA512_RNDs)
              begin
                w_init          = 1'b1;
                state_init      = 1'b1;
                round_ctr_rst   = 1'b1;
                sha512_ctrl_new = CTRL_ROUNDS;
                sha512_ctrl_we  = 1'b1;
                init_reg_reset  = 1'b1;

                if (init_reg)
                  begin
                    digest_init = 1'b1;
                    first_block = 1'b1;
                  end
              end
          end

        CTRL_ROUNDS:
          begin
            w_next        = 1'b1;
            state_update  = 1'b1;
            round_ctr_inc = 1'b1;

            if (round_ctr_reg == SHA512_ROUNDS)
              begin
                sha512_ctrl_new = CTRL_DONE;
                sha512_ctrl_we  = 1'b1;
              end
          end

        CTRL_DONE:
          begin
            ready_new        = 1'b1;
            ready_we         = 1'b1;
            digest_update    = 1'b1;
            digest_valid_new = 1'b1;
            digest_valid_we  = 1'b1;
            chain_valid_set  = 1'b1;
            sha512_ctrl_new  = CTRL_IDLE;
            sha512_ctrl_we   = 1'b1;
          end

        default:
          begin
            sha512_ctrl_new = CTRL_IDLE;
            sha512_ctrl_we  = 1'b1;
          end
      endcase
    end // sha512_ctrl_fsm

endmodule
