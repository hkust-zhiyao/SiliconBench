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
//
//======================================================================
//
// hmac_drbg.sv
// ------
// HMAC384-drbg top-level wrapper with 384 bit data access.
//
// Based on section 10.1.2. of NIST SP 800-90A, Rev 1 and
// section 3.1/3.2 of RFC 6979.
//======================================================================

module hmac_drbg
#(
  parameter                  REG_SIZE        = 384,
  parameter                  LFSR_LENGTH     = 192,
  parameter [REG_SIZE-1 : 0] HMAC_DRBG_PRIME = 384'hFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFC7634D81F4372DDF581A0DB248B0A77AECEC196ACCC52973
)
(
  // Clock and reset.
  input wire                        clk,
  input wire                        reset_n,
  input wire                        zeroize,

  // Control
  input wire                        init_cmd,
  input wire                        next_cmd,
  output wire                       ready,
  output wire                       valid,

  // Data
  input wire   [LFSR_LENGTH-1 : 0]  lfsr_seed,
  input wire   [REG_SIZE-1 : 0]     entropy,
  input wire   [REG_SIZE-1 : 0]     nonce,

  output wire  [REG_SIZE-1  : 0]    drbg
);

  //----------------------------------------------------------------
  // Internal constant and parameter definitions.
  //----------------------------------------------------------------
  localparam [REG_SIZE-1 : 0] V_init = 384'h010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101010101;
  localparam [REG_SIZE-1 : 0] K_init = 384'h000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000;

  localparam [(((1024-REG_SIZE)-1)-12)-1 : 0] ZERO_PAD_V = '0;
  localparam [11 : 0] V_SIZE = {1'b0, 11'd1024 + 11'(REG_SIZE)};

  /* STATES */
  localparam [4 : 0] IDLE_ST        = 5'd0;
  localparam [4 : 0] INIT_ST        = 5'd1;
  localparam [4 : 0] NEXT_ST        = 5'd2;
  localparam [4 : 0] K10_ST         = 5'd3;
  localparam [4 : 0] K11_ST         = 5'd4;
  localparam [4 : 0] V1_ST          = 5'd5;
  localparam [4 : 0] K2_INIT_ST     = 5'd6;
  localparam [4 : 0] K20_ST         = 5'd7;
  localparam [4 : 0] K21_ST         = 5'd8;
  localparam [4 : 0] V2_ST          = 5'd9;
  localparam [4 : 0] T_ST           = 5'd10;
  localparam [4 : 0] CHCK_ST        = 5'd11;
  localparam [4 : 0] K3_ST          = 5'd12;
  localparam [4 : 0] V3_ST          = 5'd13;
  localparam [4 : 0] DONE_ST        = 5'd14;

  //----------------------------------------------------------------
  // Registers including update variables and write enable.
  //----------------------------------------------------------------
  reg [4:0]               drbg_st_reg;
  reg [4:0]               drbg_next_st;
  reg [4:0]               drbg_st_reg_last;

  reg                     ready_reg;
  reg                     valid_reg;
  reg [REG_SIZE-1 : 0]    drbg_reg;
  reg                     first_round;
  reg                     HMAC_tag_valid_last;
  reg                     HMAC_tag_valid_edge;

  reg [REG_SIZE-1:0]      K_reg;
  reg [REG_SIZE-1:0]      V_reg;
  reg [REG_SIZE-1:0]      entropy_reg;
  reg [REG_SIZE-1:0]      nonce_reg;
  reg [LFSR_LENGTH-1:0]   lfsr_seed_reg;
  reg                     instantiated_reg;

  logic                   accept_init_cmd;
  logic                   accept_next_cmd;

  //----------------------------------------------------------------
  // Register/Wires for HMAC-384 module instantiation.
  //----------------------------------------------------------------
  reg                     HMAC_init;
  reg                     HMAC_next;
  reg                     HMAC_last;
  reg  [1023:0]           HMAC_block;
  reg  [REG_SIZE-1:0]     HMAC_key;
  logic [511:0]           HMAC512_key;

  wire                    HMAC_ready;
  wire                    HMAC_tag_valid;
  logic [REG_SIZE-1:0]    HMAC_tag;
  logic [511:0]           HMAC512_tag;

  logic                   failure_check;

  //----------------------------------------------------------------
  // Command qualification
  //----------------------------------------------------------------
  always_comb begin
    accept_init_cmd = (drbg_st_reg == IDLE_ST) && HMAC_ready && !zeroize && (init_cmd && !next_cmd);
    accept_next_cmd = (drbg_st_reg == IDLE_ST) && HMAC_ready && !zeroize && (!init_cmd && next_cmd) && instantiated_reg;
  end

  always_ff @(posedge clk or negedge reset_n) begin : seed_snapshot_update
    if (!reset_n) begin
      entropy_reg      <= '0;
      nonce_reg        <= '0;
      lfsr_seed_reg    <= '0;
      instantiated_reg <= 1'b0;
    end
    else if (zeroize) begin
      entropy_reg      <= '0;
      nonce_reg        <= '0;
      lfsr_seed_reg    <= '0;
      instantiated_reg <= 1'b0;
    end
    else begin
      if (accept_init_cmd) begin
        entropy_reg      <= entropy;
        nonce_reg        <= nonce;
        lfsr_seed_reg    <= lfsr_seed;
        instantiated_reg <= 1'b1;
      end
      else if (accept_next_cmd) begin
        lfsr_seed_reg    <= lfsr_seed;
      end
    end
  end

  //----------------------------------------------------------------
  // HMAC module instantiation.
  //----------------------------------------------------------------
  hmac_core HMAC_K (
    .clk(clk),
    .reset_n(reset_n),
    .zeroize(zeroize),
    .init_cmd(HMAC_init),
    .next_cmd(HMAC_next),
    .last_cmd(HMAC_last),
    .mode_cmd(1'b0),
    .lfsr_seed(zeroize ? '0 : lfsr_seed_reg),
    .key(HMAC512_key),
    .block_msg(HMAC_block),
    .ready(HMAC_ready),
    .tag(HMAC512_tag),
    .tag_valid(HMAC_tag_valid)
  );

  //----------------------------------------------------------------
  // reg_update
  //----------------------------------------------------------------
  always_comb begin
    HMAC512_key = {HMAC_key, 128'b0};
    HMAC_tag    = HMAC512_tag[511 : 128];
  end

  always_comb begin : edge_detector
    first_round         = (drbg_st_reg == drbg_st_reg_last) ? 1'b0 : 1'b1;
    HMAC_tag_valid_edge = HMAC_tag_valid & (!HMAC_tag_valid_last);
  end

  always_ff @(posedge clk or negedge reset_n) begin
    if (!reset_n)
      HMAC_tag_valid_last <= '0;
    else if (zeroize)
      HMAC_tag_valid_last <= '0;
    else
      HMAC_tag_valid_last <= HMAC_tag_valid;
  end

  always_ff @(posedge clk or negedge reset_n) begin : valid_drbg_regs_updates
    if (!reset_n) begin
      ready_reg <= 1'b0;
      valid_reg <= 1'b0;
      drbg_reg  <= '0;
    end
    else if (zeroize) begin
      ready_reg <= 1'b0;
      valid_reg <= 1'b0;
      drbg_reg  <= '0;
    end
    else begin
      unique case (drbg_st_reg)
        IDLE_ST: begin
          if (accept_init_cmd || accept_next_cmd) begin
            ready_reg <= 1'b0;
            valid_reg <= 1'b0;
            drbg_reg  <= '0;
          end
          else begin
            ready_reg <= HMAC_ready;
          end
        end

        DONE_ST: begin
          drbg_reg  <= HMAC_tag;
          valid_reg <= HMAC_tag_valid;
          ready_reg <= HMAC_ready;
        end

        default: begin
          ready_reg <= 1'b0;
          valid_reg <= 1'b0;
          drbg_reg  <= '0;
        end
      endcase
    end
  end

  always_ff @(posedge clk or negedge reset_n) begin : hmac_command_update
    if (!reset_n) begin
      HMAC_init <= 1'b0;
      HMAC_next <= 1'b0;
      HMAC_last <= 1'b0;
    end
    else if (zeroize) begin
      HMAC_init <= 1'b0;
      HMAC_next <= 1'b0;
      HMAC_last <= 1'b0;
    end
    else begin
      HMAC_init <= 1'b0;
      HMAC_next <= 1'b0;
      HMAC_last <= 1'b0;
      if (first_round) begin
        unique case (drbg_st_reg)
          K10_ST:       HMAC_init <= 1'b1;
          K11_ST: begin HMAC_next <= 1'b1; HMAC_last <= 1'b1; end
          V1_ST:  begin HMAC_init <= 1'b1; HMAC_last <= 1'b1; end
          K20_ST:       HMAC_init <= 1'b1;
          K21_ST: begin HMAC_next <= 1'b1; HMAC_last <= 1'b1; end
          V2_ST:  begin HMAC_init <= 1'b1; HMAC_last <= 1'b1; end
          T_ST:   begin HMAC_init <= 1'b1; HMAC_last <= 1'b1; end
          K3_ST:  begin HMAC_init <= 1'b1; HMAC_last <= 1'b1; end
          V3_ST:  begin HMAC_init <= 1'b1; HMAC_last <= 1'b1; end
          default: begin
            HMAC_init <= 1'b0;
            HMAC_next <= 1'b0;
            HMAC_last <= 1'b0;
          end
        endcase
      end
    end
  end

  always_ff @(posedge clk or negedge reset_n) begin : hmac_inputs_update
    if (!reset_n) begin
      K_reg <= '0;
      V_reg <= '0;
    end
    else if (zeroize) begin
      K_reg <= '0;
      V_reg <= '0;
    end
    else begin
      if (first_round) begin
        unique case (drbg_st_reg)
          INIT_ST: begin
            K_reg <= K_init;
            V_reg <= V_init;
          end
          V1_ST:   K_reg <= HMAC_tag;
          K20_ST:  V_reg <= HMAC_tag;
          V2_ST:   K_reg <= HMAC_tag;
          T_ST:    V_reg <= HMAC_tag;
          V3_ST:   K_reg <= HMAC_tag;
          CHCK_ST: V_reg <= HMAC_tag;
          default: begin
            K_reg <= K_reg;
            V_reg <= V_reg;
          end
        endcase
      end
    end
  end

  always_comb begin : hmac_block_update
    HMAC_key = K_reg;
    unique case (drbg_st_reg)
      K10_ST:  HMAC_block = {V_reg, 8'h0, entropy_reg, nonce_reg[REG_SIZE-1:136]};
      K11_ST:  HMAC_block = {nonce_reg[135:0], 1'h1, 875'b0, 12'h888};
      V1_ST:   HMAC_block = {V_reg, 1'h1, ZERO_PAD_V, V_SIZE};
      K20_ST:  HMAC_block = {V_reg, 8'h1, entropy_reg, nonce_reg[REG_SIZE-1:136]};
      K21_ST:  HMAC_block = {nonce_reg[135:0], 1'h1, 875'b0, 12'h888};
      V2_ST:   HMAC_block = {V_reg, 1'h1, ZERO_PAD_V, V_SIZE};
      T_ST:    HMAC_block = {V_reg, 1'h1, ZERO_PAD_V, V_SIZE};
      K3_ST:   HMAC_block = {V_reg, 8'h0, 1'h1, 619'b0, 12'h588};
      V3_ST:   HMAC_block = {V_reg, 1'h1, ZERO_PAD_V, V_SIZE};
      default: HMAC_block = '0;
    endcase
  end

  always_ff @(posedge clk or negedge reset_n) begin : state_update
    if (!reset_n)
      drbg_st_reg <= IDLE_ST;
    else if (zeroize)
      drbg_st_reg <= IDLE_ST;
    else
      drbg_st_reg <= drbg_next_st;
  end

  always_ff @(posedge clk or negedge reset_n) begin : ff_state_update
    if (!reset_n)
      drbg_st_reg_last <= IDLE_ST;
    else if (zeroize)
      drbg_st_reg_last <= IDLE_ST;
    else
      drbg_st_reg_last <= drbg_st_reg;
  end

  //----------------------------------------------------------------
  // FSM_flow
  //----------------------------------------------------------------
  always_comb begin : state_logic
    unique case (drbg_st_reg)
      IDLE_ST: begin
        if (accept_init_cmd)
          drbg_next_st = INIT_ST;
        else if (accept_next_cmd)
          drbg_next_st = NEXT_ST;
        else
          drbg_next_st = IDLE_ST;
      end

      INIT_ST:    drbg_next_st = K10_ST;
      NEXT_ST:    drbg_next_st = K3_ST;
      K10_ST:     drbg_next_st = HMAC_tag_valid_edge ? K11_ST     : K10_ST;
      K11_ST:     drbg_next_st = HMAC_tag_valid_edge ? V1_ST      : K11_ST;
      V1_ST:      drbg_next_st = HMAC_tag_valid_edge ? K2_INIT_ST : V1_ST;
      K2_INIT_ST: drbg_next_st = K20_ST;
      K20_ST:     drbg_next_st = HMAC_tag_valid_edge ? K21_ST     : K20_ST;
      K21_ST:     drbg_next_st = HMAC_tag_valid_edge ? V2_ST      : K21_ST;
      V2_ST:      drbg_next_st = HMAC_tag_valid_edge ? T_ST       : V2_ST;
      T_ST:       drbg_next_st = HMAC_tag_valid_edge ? CHCK_ST    : T_ST;

      CHCK_ST: begin
        if (failure_check)
          drbg_next_st = K3_ST;
        else
          drbg_next_st = DONE_ST;
      end

      K3_ST:      drbg_next_st = HMAC_tag_valid_edge ? V3_ST : K3_ST;
      V3_ST:      drbg_next_st = HMAC_tag_valid_edge ? T_ST  : V3_ST;
      DONE_ST:    drbg_next_st = IDLE_ST;
      default:    drbg_next_st = IDLE_ST;
    endcase
  end

  always_comb failure_check = (HMAC_tag == '0) || (HMAC_tag >= HMAC_DRBG_PRIME);

  //----------------------------------------------------------------
  // Concurrent connectivity for ports etc.
  //----------------------------------------------------------------
  assign ready = ready_reg;
  assign valid = valid_reg;
  assign drbg  = drbg_reg;

endmodule
