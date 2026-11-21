//======================================================================
//
// sha512_masked_core.sv (Alternate Gold)
//
// Structurally distinct architecture:
// - 8-cycle sponge pre-seed FSM
// - Dual separate 64-bit share arrays (h_chain_m / h_chain_r)
// - 1-AND factored Boyar-Palta Ch/Maj + 64-bit gamma complement-add A2B
// - Modulo-16 circular W schedule ring
//======================================================================

module sha512_masked_core
                  import sha512_masked_defines_pkg::*;
                  (
                   input wire            clk,
                   input wire            reset_n,
                   input wire            zeroize,

                   input wire            init_cmd,
                   input wire            next_cmd,
                   input wire [1 : 0]    mode,

                   input wire [191 : 0]  entropy,
                   input wire [1023 : 0] block_msg,

                   output wire           ready,
                   output wire [511 : 0] digest,
                   output wire           digest_valid
                  );

  typedef enum logic [1:0] {
    ST_IDLE   = 2'd0,
    ST_SEED   = 2'd1,
    ST_COMP   = 2'd2,
    ST_FINISH = 2'd3
  } fsm_e;

  fsm_e              fsm_q;
  logic [2:0]        seed_cnt_q;
  logic [6:0]        rnd_idx_q;
  logic              is_first_blk_q;
  logic              has_chain_q;
  logic [1:0]        latched_mode_q;
  logic              ready_q;
  logic              digest_valid_q;

  logic [23:0][63:0] sponge_q;
  logic [31:0][63:0] fresh_lanes;

  // Preserved architectural working-state shares.
  masked_reg_t a_reg, b_reg, c_reg, d_reg, e_reg, f_reg, g_reg, h_reg;

  // Dual separate data/mask arrays for chaining digest.
  logic [63:0] h_chain_m [0:7];
  logic [63:0] h_chain_r [0:7];

  wire [63:0] k_const;
  wire [63:0] iv0, iv1, iv2, iv3, iv4, iv5, iv6, iv7;
  logic [63:0] iv_arr [0:7];

  logic          w_latch, w_reseed, w_step;
  logic [1023:0] w_remask_bus;
  masked_reg_t   w_curr;

  always_comb begin
    for (int i = 0; i < 24; i++) begin
      fresh_lanes[i] = sponge_q[i] ^ derive_lane_mask(entropy, i);
    end
    for (int i = 24; i < 32; i++) begin
      fresh_lanes[i] = rol64(sponge_q[i - 24], 11) ^
                       rol64(sponge_q[i - 16], 33) ^
                       rol64(sponge_q[i - 8],  51) ^
                       derive_lane_mask(entropy, i);
    end
  end

  assign w_remask_bus = {
    fresh_lanes[8],  fresh_lanes[9],  fresh_lanes[10], fresh_lanes[11],
    fresh_lanes[12], fresh_lanes[13], fresh_lanes[14], fresh_lanes[15],
    fresh_lanes[16], fresh_lanes[17], fresh_lanes[18], fresh_lanes[19],
    fresh_lanes[20], fresh_lanes[21], fresh_lanes[22], fresh_lanes[23]
  };

  sha512_k_constants u_k_rom (
    .addr  (rnd_idx_q),
    .K_val (k_const)
  );

  sha512_h_constants u_iv_rom (
    .mode (latched_mode_q),
    .H0   (iv0),
    .H1   (iv1),
    .H2   (iv2),
    .H3   (iv3),
    .H4   (iv4),
    .H5   (iv5),
    .H6   (iv6),
    .H7   (iv7)
  );

  always_comb begin
    iv_arr[0] = iv0;
    iv_arr[1] = iv1;
    iv_arr[2] = iv2;
    iv_arr[3] = iv3;
    iv_arr[4] = iv4;
    iv_arr[5] = iv5;
    iv_arr[6] = iv6;
    iv_arr[7] = iv7;
  end

  sha512_masked_w_mem w_mem_inst (
    .clk            (clk),
    .reset_n        (reset_n),
    .zeroize        (zeroize),
    .block_msg      (block_msg),
    .rw_masking_rnd (w_remask_bus),
    .gamma_a2b      (fresh_lanes[24]),
    .q_b2a          (fresh_lanes[25][3:0]),
    .latch_block    (w_latch),
    .init_cmd       (w_reseed),
    .next_cmd       (w_step),
    .w_val          (w_curr)
  );

  // Round compression datapath
  masked_reg_t a_next_val, e_next_val;
  always_comb begin
    masked_reg_t s1_e, s0_a, ch_s, maj_s, k_s;
    masked_reg_t h_a, s1_a, ch_a, k_a, w_a, t1_a;
    masked_reg_t s0_a2, maj_a, t2_a, d_a;
    logic [7:0]  qb;

    qb = fresh_lanes[25][11:4];

    s1_e = '{masked: sigma1(e_reg.masked), random: sigma1(e_reg.random)};
    s0_a = '{masked: sigma0(a_reg.masked), random: sigma0(a_reg.random)};

    ch_s  = masked_ch_factored(e_reg, f_reg, g_reg, fresh_lanes[26], fresh_lanes[27]);
    maj_s = masked_maj_factored(a_reg, b_reg, c_reg, fresh_lanes[28], fresh_lanes[29], fresh_lanes[30]);
    k_s   = '{masked: k_const ^ fresh_lanes[31], random: fresh_lanes[31]};

    h_a   = B2A_conv(h_reg,  qb[0]);
    s1_a  = B2A_conv(s1_e,   qb[1]);
    ch_a  = B2A_conv(ch_s,   qb[2]);
    k_a   = B2A_conv(k_s,    qb[3]);
    w_a   = B2A_conv(w_curr, qb[4]);

    t1_a  = masked_sum(masked_sum(h_a, s1_a), masked_sum(ch_a, masked_sum(k_a, w_a)));

    s0_a2 = B2A_conv(s0_a,   qb[5]);
    maj_a = B2A_conv(maj_s,  qb[6]);
    t2_a  = masked_sum(s0_a2, maj_a);

    d_a   = B2A_conv(d_reg,  qb[7]);

    a_next_val = remask_pair(a2b_gamma64(masked_sum(t1_a, t2_a), fresh_lanes[24] ^ fresh_lanes[26]), fresh_lanes[0]);
    e_next_val = remask_pair(a2b_gamma64(masked_sum(d_a,  t1_a), fresh_lanes[24] ^ fresh_lanes[28]), fresh_lanes[4]);
  end

  // Masked chaining digest accumulation
  masked_reg_t chain_sum_out [0:7];
  always_comb begin
    masked_reg_t ws [0:7];
    masked_reg_t hc, ha, sa;
    ws[0] = a_reg; ws[1] = b_reg; ws[2] = c_reg; ws[3] = d_reg;
    ws[4] = e_reg; ws[5] = f_reg; ws[6] = g_reg; ws[7] = h_reg;

    for (int k = 0; k < 8; k++) begin
      hc = '{masked: h_chain_m[k], random: h_chain_r[k]};
      ha = B2A_conv(hc,    fresh_lanes[25][16 + 2 * k]);
      sa = B2A_conv(ws[k], fresh_lanes[25][17 + 2 * k]);
      chain_sum_out[k] = remask_pair(
        a2b_gamma64(masked_sum(ha, sa), fresh_lanes[16 + k]),
        fresh_lanes[k]
      );
    end
  end

  wire accept_init = (fsm_q == ST_IDLE) && ready_q && init_cmd && !next_cmd && !zeroize;
  wire accept_next = (fsm_q == ST_IDLE) && ready_q && !init_cmd && next_cmd && has_chain_q && !zeroize;

  assign w_latch  = accept_init || accept_next;
  assign w_reseed = (fsm_q == ST_SEED) && (seed_cnt_q == 3'd7) && !zeroize;
  assign w_step   = (fsm_q == ST_COMP) && !zeroize;

  always_ff @(posedge clk or negedge reset_n) begin
    if (!reset_n) begin
      fsm_q          <= ST_IDLE;
      seed_cnt_q     <= 3'd0;
      rnd_idx_q      <= 7'd0;
      is_first_blk_q <= 1'b0;
      has_chain_q    <= 1'b0;
      latched_mode_q <= 2'd0;
      ready_q        <= 1'b1;
      digest_valid_q <= 1'b0;
      sponge_q       <= '0;
      a_reg <= '0; b_reg <= '0; c_reg <= '0; d_reg <= '0;
      e_reg <= '0; f_reg <= '0; g_reg <= '0; h_reg <= '0;
      for (int k = 0; k < 8; k++) begin
        h_chain_m[k] <= 64'h0;
        h_chain_r[k] <= 64'h0;
      end
    end
    else if (zeroize) begin
      fsm_q          <= ST_IDLE;
      seed_cnt_q     <= 3'd0;
      rnd_idx_q      <= 7'd0;
      is_first_blk_q <= 1'b0;
      has_chain_q    <= 1'b0;
      latched_mode_q <= 2'd0;
      ready_q        <= 1'b1;
      digest_valid_q <= 1'b0;
      sponge_q       <= '0;
      a_reg <= '0; b_reg <= '0; c_reg <= '0; d_reg <= '0;
      e_reg <= '0; f_reg <= '0; g_reg <= '0; h_reg <= '0;
      for (int k = 0; k < 8; k++) begin
        h_chain_m[k] <= 64'h0;
        h_chain_r[k] <= 64'h0;
      end
    end
    else begin
      unique case (fsm_q)
        ST_IDLE: begin
          if (accept_init || accept_next) begin
            fsm_q          <= ST_SEED;
            seed_cnt_q     <= 3'd0;
            ready_q        <= 1'b0;
            digest_valid_q <= 1'b0;
            is_first_blk_q <= accept_init;
            if (accept_init)
              latched_mode_q <= mode;
          end
        end

        ST_SEED: begin
          sponge_q[3 * seed_cnt_q]     <= sponge_q[3 * seed_cnt_q]     ^ entropy[63:0];
          sponge_q[3 * seed_cnt_q + 1] <= sponge_q[3 * seed_cnt_q + 1] ^ entropy[127:64];
          sponge_q[3 * seed_cnt_q + 2] <= sponge_q[3 * seed_cnt_q + 2] ^ entropy[191:128];

          if (seed_cnt_q == 3'd7) begin
            fsm_q     <= ST_COMP;
            rnd_idx_q <= 7'd0;
            if (is_first_blk_q) begin
              for (int k = 0; k < 8; k++) begin
                h_chain_m[k] <= iv_arr[k] ^ fresh_lanes[16 + k];
                h_chain_r[k] <= fresh_lanes[16 + k];
              end
              a_reg <= '{masked: iv_arr[0] ^ fresh_lanes[0], random: fresh_lanes[0]};
              b_reg <= '{masked: iv_arr[1] ^ fresh_lanes[1], random: fresh_lanes[1]};
              c_reg <= '{masked: iv_arr[2] ^ fresh_lanes[2], random: fresh_lanes[2]};
              d_reg <= '{masked: iv_arr[3] ^ fresh_lanes[3], random: fresh_lanes[3]};
              e_reg <= '{masked: iv_arr[4] ^ fresh_lanes[4], random: fresh_lanes[4]};
              f_reg <= '{masked: iv_arr[5] ^ fresh_lanes[5], random: fresh_lanes[5]};
              g_reg <= '{masked: iv_arr[6] ^ fresh_lanes[6], random: fresh_lanes[6]};
              h_reg <= '{masked: iv_arr[7] ^ fresh_lanes[7], random: fresh_lanes[7]};
            end
            else begin
              a_reg <= '{masked: h_chain_m[0] ^ fresh_lanes[0], random: h_chain_r[0] ^ fresh_lanes[0]};
              b_reg <= '{masked: h_chain_m[1] ^ fresh_lanes[1], random: h_chain_r[1] ^ fresh_lanes[1]};
              c_reg <= '{masked: h_chain_m[2] ^ fresh_lanes[2], random: h_chain_r[2] ^ fresh_lanes[2]};
              d_reg <= '{masked: h_chain_m[3] ^ fresh_lanes[3], random: h_chain_r[3] ^ fresh_lanes[3]};
              e_reg <= '{masked: h_chain_m[4] ^ fresh_lanes[4], random: h_chain_r[4] ^ fresh_lanes[4]};
              f_reg <= '{masked: h_chain_m[5] ^ fresh_lanes[5], random: h_chain_r[5] ^ fresh_lanes[5]};
              g_reg <= '{masked: h_chain_m[6] ^ fresh_lanes[6], random: h_chain_r[6] ^ fresh_lanes[6]};
              h_reg <= '{masked: h_chain_m[7] ^ fresh_lanes[7], random: h_chain_r[7] ^ fresh_lanes[7]};
            end
          end
          else begin
            seed_cnt_q <= seed_cnt_q + 3'd1;
          end
        end

        ST_COMP: begin
          for (int k = 0; k < 24; k++) begin
            sponge_q[k] <= rol64(sponge_q[(k + 5) % 24], 13) ^ derive_lane_mask(entropy, k + 2);
          end
          a_reg <= a_next_val;
          b_reg <= remask_pair(a_reg, fresh_lanes[1]);
          c_reg <= remask_pair(b_reg, fresh_lanes[2]);
          d_reg <= remask_pair(c_reg, fresh_lanes[3]);
          e_reg <= e_next_val;
          f_reg <= remask_pair(e_reg, fresh_lanes[5]);
          g_reg <= remask_pair(f_reg, fresh_lanes[6]);
          h_reg <= remask_pair(g_reg, fresh_lanes[7]);

          if (rnd_idx_q == 7'd79) begin
            fsm_q <= ST_FINISH;
          end
          else begin
            rnd_idx_q <= rnd_idx_q + 7'd1;
          end
        end

        ST_FINISH: begin
          for (int k = 0; k < 24; k++) begin
            sponge_q[k] <= rol64(sponge_q[(k + 7) % 24], 21) ^ derive_lane_mask(entropy, k + 4);
          end
          for (int k = 0; k < 8; k++) begin
            h_chain_m[k] <= chain_sum_out[k].masked;
            h_chain_r[k] <= chain_sum_out[k].random;
          end
          has_chain_q    <= 1'b1;
          ready_q        <= 1'b1;
          digest_valid_q <= 1'b1;
          fsm_q          <= ST_IDLE;
        end

        default: fsm_q <= ST_IDLE;
      endcase
    end
  end

  logic [511:0] gated_digest;
  always_comb begin
    logic [63:0] dw [0:7];
    for (int k = 0; k < 8; k++) begin
      dw[k] = ({64{digest_valid_q}} & h_chain_m[k]) ^
              ({64{digest_valid_q}} & h_chain_r[k]);
    end
    if (!digest_valid_q) begin
      gated_digest = 512'h0;
    end
    else begin
      unique case (latched_mode_q)
        2'h0:    gated_digest = {dw[0], dw[1], dw[2], dw[3][63:32], 288'h0};
        2'h1:    gated_digest = {dw[0], dw[1], dw[2], dw[3], 256'h0};
        2'h2:    gated_digest = {dw[0], dw[1], dw[2], dw[3], dw[4], dw[5], 128'h0};
        default: gated_digest = {dw[0], dw[1], dw[2], dw[3], dw[4], dw[5], dw[6], dw[7]};
      endcase
    end
  end

  assign ready        = ready_q;
  assign digest_valid = digest_valid_q;
  assign digest       = gated_digest;

endmodule
