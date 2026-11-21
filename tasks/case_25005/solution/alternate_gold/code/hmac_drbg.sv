// SPDX-License-Identifier: Apache-2.0
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

module hmac_drbg
#(
  parameter                  REG_SIZE        = 384,
  parameter                  LFSR_LENGTH     = 192,
  parameter [REG_SIZE-1 : 0] HMAC_DRBG_PRIME = 384'hFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFC7634D81F4372DDF581A0DB248B0A77AECEC196ACCC52973
)
(
  input wire                        clk,
  input wire                        reset_n,
  input wire                        zeroize,

  input wire                        init_cmd,
  input wire                        next_cmd,
  output wire                       ready,
  output wire                       valid,

  input wire   [LFSR_LENGTH-1 : 0]  lfsr_seed,
  input wire   [REG_SIZE-1 : 0]     entropy,
  input wire   [REG_SIZE-1 : 0]     nonce,

  output wire  [REG_SIZE-1  : 0]    drbg
);

  localparam [REG_SIZE-1 : 0] V_INIT_CONST = {48{8'h01}};
  localparam [REG_SIZE-1 : 0] K_INIT_CONST = '0;
  localparam [(((1024-REG_SIZE)-1)-12)-1 : 0] PAD_ZEROS_V = '0;
  localparam [11 : 0] V_MSG_BITS = {1'b0, 11'd1024 + 11'(REG_SIZE)};

  typedef enum logic [4:0] {
    ST_IDLE    = 5'd0,
    ST_INIT    = 5'd1,
    ST_NEXT    = 5'd2,
    ST_K10     = 5'd3,
    ST_K11     = 5'd4,
    ST_V1      = 5'd5,
    ST_K2_PREP = 5'd6,
    ST_K20     = 5'd7,
    ST_K21     = 5'd8,
    ST_V2      = 5'd9,
    ST_CAND    = 5'd10,
    ST_CHECK   = 5'd11,
    ST_K3      = 5'd12,
    ST_V3      = 5'd13,
    ST_FINISH  = 5'd14
  } drbg_fsm_e;

  typedef struct packed {
    logic [REG_SIZE-1:0]    k_state;
    logic [REG_SIZE-1:0]    v_state;
    logic [REG_SIZE-1:0]    ent_buf;
    logic [REG_SIZE-1:0]    nonce_buf;
    logic [LFSR_LENGTH-1:0] seed_buf;
    logic                   is_seeded;
  } drbg_ctx_t;

  drbg_fsm_e            fsm_q, fsm_d, fsm_prev_q;
  drbg_ctx_t            ctx_q;

  logic                 ready_q;
  logic                 valid_q;
  logic [REG_SIZE-1:0]  drbg_q;

  logic                 state_entered;
  logic                 tag_vld_prev_q;
  logic                 tag_vld_rise;

  logic                 core_init_q;
  logic                 core_next_q;
  logic                 core_last_q;
  logic [1023:0]        core_block;
  logic [511:0]         core_key_padded;
  logic                 core_ready;
  logic                 core_tag_valid;
  logic [511:0]         core_tag_full;
  logic [REG_SIZE-1:0]  cand_tag;

  logic                 start_instantiate;
  logic                 start_generate;
  logic                 candidate_valid_scalar;

  assign core_key_padded        = {ctx_q.k_state, 128'b0};
  assign cand_tag               = core_tag_full[511:128];
  assign state_entered          = (fsm_q != fsm_prev_q);
  assign tag_vld_rise           = core_tag_valid && !tag_vld_prev_q;
  assign candidate_valid_scalar = (|cand_tag) && (cand_tag < HMAC_DRBG_PRIME);

  assign start_instantiate = (fsm_q == ST_IDLE) && core_ready && !zeroize && (init_cmd && !next_cmd);
  assign start_generate    = (fsm_q == ST_IDLE) && core_ready && !zeroize && (!init_cmd && next_cmd) && ctx_q.is_seeded;

  hmac_core HMAC_K (
    .clk       (clk),
    .reset_n   (reset_n),
    .zeroize   (zeroize),
    .init_cmd  (core_init_q),
    .next_cmd  (core_next_q),
    .last_cmd  (core_last_q),
    .mode_cmd  (1'b0),
    .lfsr_seed (zeroize ? '0 : ctx_q.seed_buf),
    .key       (core_key_padded),
    .block_msg (core_block),
    .ready     (core_ready),
    .tag       (core_tag_full),
    .tag_valid (core_tag_valid)
  );

  always_ff @(posedge clk or negedge reset_n) begin
    if (!reset_n) begin
      fsm_q          <= ST_IDLE;
      fsm_prev_q     <= ST_IDLE;
      tag_vld_prev_q <= 1'b0;
      ready_q        <= 1'b0;
      valid_q        <= 1'b0;
      drbg_q         <= '0;
      core_init_q    <= 1'b0;
      core_next_q    <= 1'b0;
      core_last_q    <= 1'b0;
      ctx_q          <= '0;
    end
    else if (zeroize) begin
      fsm_q          <= ST_IDLE;
      fsm_prev_q     <= ST_IDLE;
      tag_vld_prev_q <= 1'b0;
      ready_q        <= 1'b0;
      valid_q        <= 1'b0;
      drbg_q         <= '0;
      core_init_q    <= 1'b0;
      core_next_q    <= 1'b0;
      core_last_q    <= 1'b0;
      ctx_q          <= '0;
    end
    else begin
      fsm_q          <= fsm_d;
      fsm_prev_q     <= fsm_q;
      tag_vld_prev_q <= core_tag_valid;

      if (start_instantiate) begin
        ctx_q.ent_buf   <= entropy;
        ctx_q.nonce_buf <= nonce;
        ctx_q.seed_buf  <= lfsr_seed;
        ctx_q.is_seeded <= 1'b1;
      end
      else if (start_generate) begin
        ctx_q.seed_buf  <= lfsr_seed;
      end

      if (state_entered) begin
        unique case (fsm_q)
          ST_INIT: begin
            ctx_q.k_state <= K_INIT_CONST;
            ctx_q.v_state <= V_INIT_CONST;
          end
          ST_V1,
          ST_V2,
          ST_V3:    ctx_q.k_state <= cand_tag;
          ST_K20,
          ST_CAND,
          ST_CHECK: ctx_q.v_state <= cand_tag;
          default: ;
        endcase
      end

      core_init_q <= 1'b0;
      core_next_q <= 1'b0;
      core_last_q <= 1'b0;
      if (state_entered) begin
        unique case (fsm_q)
          ST_K10,
          ST_K20:  core_init_q <= 1'b1;
          ST_K11,
          ST_K21:  begin core_next_q <= 1'b1; core_last_q <= 1'b1; end
          ST_V1,
          ST_V2,
          ST_CAND,
          ST_K3,
          ST_V3:   begin core_init_q <= 1'b1; core_last_q <= 1'b1; end
          default: ;
        endcase
      end

      unique case (fsm_q)
        ST_IDLE: begin
          if (start_instantiate || start_generate) begin
            ready_q <= 1'b0;
            valid_q <= 1'b0;
            drbg_q  <= '0;
          end
          else begin
            ready_q <= core_ready;
          end
        end
        ST_FINISH: begin
          drbg_q  <= cand_tag;
          valid_q <= core_tag_valid;
          ready_q <= core_ready;
        end
        default: begin
          ready_q <= 1'b0;
          valid_q <= 1'b0;
          drbg_q  <= '0;
        end
      endcase
    end
  end

  always_comb begin
    unique case (fsm_q)
      ST_K10:  core_block = {ctx_q.v_state, 8'h00, ctx_q.ent_buf, ctx_q.nonce_buf[REG_SIZE-1:136]};
      ST_K11:  core_block = {ctx_q.nonce_buf[135:0], 1'b1, 875'b0, 12'h888};
      ST_K20:  core_block = {ctx_q.v_state, 8'h01, ctx_q.ent_buf, ctx_q.nonce_buf[REG_SIZE-1:136]};
      ST_K21:  core_block = {ctx_q.nonce_buf[135:0], 1'b1, 875'b0, 12'h888};
      ST_K3:   core_block = {ctx_q.v_state, 8'h00, 1'b1, 619'b0, 12'h588};
      ST_V1,
      ST_V2,
      ST_CAND,
      ST_V3:   core_block = {ctx_q.v_state, 1'b1, PAD_ZEROS_V, V_MSG_BITS};
      default: core_block = '0;
    endcase
  end

  always_comb begin
    unique case (fsm_q)
      ST_IDLE:    fsm_d = start_instantiate ? ST_INIT : (start_generate ? ST_NEXT : ST_IDLE);
      ST_INIT:    fsm_d = ST_K10;
      ST_NEXT:    fsm_d = ST_K3;
      ST_K10:     fsm_d = tag_vld_rise ? ST_K11     : ST_K10;
      ST_K11:     fsm_d = tag_vld_rise ? ST_V1      : ST_K11;
      ST_V1:      fsm_d = tag_vld_rise ? ST_K2_PREP : ST_V1;
      ST_K2_PREP: fsm_d = ST_K20;
      ST_K20:     fsm_d = tag_vld_rise ? ST_K21     : ST_K20;
      ST_K21:     fsm_d = tag_vld_rise ? ST_V2      : ST_K21;
      ST_V2:      fsm_d = tag_vld_rise ? ST_CAND    : ST_V2;
      ST_CAND:    fsm_d = tag_vld_rise ? ST_CHECK   : ST_CAND;
      ST_CHECK:   fsm_d = candidate_valid_scalar ? ST_FINISH : ST_K3;
      ST_K3:      fsm_d = tag_vld_rise ? ST_V3      : ST_K3;
      ST_V3:      fsm_d = tag_vld_rise ? ST_CAND    : ST_V3;
      ST_FINISH:  fsm_d = ST_IDLE;
      default:    fsm_d = ST_IDLE;
    endcase
  end

  assign ready = ready_q;
  assign valid = valid_q;
  assign drbg  = drbg_q;

endmodule
