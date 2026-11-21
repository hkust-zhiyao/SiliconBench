//======================================================================
//
// doe_key_mem.sv (Alternate Reference Implementation)
// ---------------------------------------------------
// SystemVerilog key-schedule storage with immediate combinational and
// synchronous zeroize sanitization across all 15 round keys.
//
//======================================================================

module doe_key_mem(
                   input  wire           clk,
                   input  wire           reset_n,
                   input  wire           zeroize,

                   input  wire [255 : 0] key,
                   input  wire           keylen,
                   input  wire           init_cmd,

                   input  wire [3 : 0]   round,
                   output wire [127 : 0] round_key,
                   output wire           ready,

                   output wire [31 : 0]  sboxw,
                   input  wire [31 : 0]  new_sboxw
                  );

  localparam logic       KEY_MODE_128 = 1'b0;
  localparam logic       KEY_MODE_256 = 1'b1;
  localparam logic [3:0] ROUNDS_128   = 4'd10;
  localparam logic [3:0] ROUNDS_256   = 4'd14;

  typedef enum logic [2:0] {
    KS_IDLE     = 3'd0,
    KS_INIT     = 3'd1,
    KS_EXPAND   = 3'd2,
    KS_COMPLETE = 3'd3
  } ks_state_e;

  logic [127:0] key_mem [14:0];
  logic [127:0] prev_key0_reg;
  logic [127:0] prev_key1_reg;
  logic [7:0]   rcon_reg;
  logic [3:0]   round_ctr_reg;
  ks_state_e    key_mem_ctrl_reg;
  logic         ready_reg;

  logic [127:0] next_rk_val;
  logic         next_rk_we;
  logic [127:0] next_pk0_val;
  logic         next_pk0_we;
  logic [127:0] next_pk1_val;
  logic         next_pk1_we;
  logic         rcon_init_req;
  logic         rcon_step_req;
  logic         do_expand_step;

  // Combinational output masking during zeroize and out-of-range round index
  assign ready     = ready_reg;
  assign sboxw     = zeroize ? 32'h0 : prev_key1_reg[31:0];
  assign round_key = (zeroize || (round > ROUNDS_256)) ? 128'h0 : key_mem[round];

  always_comb begin
    logic [31:0] w0, w1, w2, w3, w4, w5, w6, w7;
    logic [31:0] rot_sub, trw, k0, k1, k2, k3;

    {w0, w1, w2, w3} = prev_key0_reg;
    {w4, w5, w6, w7} = prev_key1_reg;
    rot_sub          = {new_sboxw[23:0], new_sboxw[31:24]};
    trw              = rot_sub ^ {rcon_reg, 24'h0};

    next_rk_val   = 128'h0;
    next_rk_we    = 1'b0;
    next_pk0_val  = 128'h0;
    next_pk0_we   = 1'b0;
    next_pk1_val  = 128'h0;
    next_pk1_we   = 1'b0;
    rcon_init_req = 1'b1;
    rcon_step_req = 1'b0;

    if (do_expand_step && !zeroize) begin
      rcon_init_req = 1'b0;
      next_rk_we    = 1'b1;
      if (keylen == KEY_MODE_128) begin
        if (round_ctr_reg == 4'd0) begin
          next_rk_val   = key[255:128];
          next_pk1_val  = key[255:128];
          next_pk1_we   = 1'b1;
          rcon_step_req = 1'b1;
        end else begin
          k0            = w4 ^ trw;
          k1            = w5 ^ k0;
          k2            = w6 ^ k1;
          k3            = w7 ^ k2;
          next_rk_val   = {k0, k1, k2, k3};
          next_pk1_val  = {k0, k1, k2, k3};
          next_pk1_we   = 1'b1;
          rcon_step_req = 1'b1;
        end
      end else begin
        if (round_ctr_reg == 4'd0) begin
          next_rk_val  = key[255:128];
          next_pk0_val = key[255:128];
          next_pk0_we  = 1'b1;
        end else if (round_ctr_reg == 4'd1) begin
          next_rk_val   = key[127:0];
          next_pk1_val  = key[127:0];
          next_pk1_we   = 1'b1;
          rcon_step_req = 1'b1;
        end else begin
          if (!round_ctr_reg[0]) begin
            k0 = w0 ^ trw;
          end else begin
            k0            = w0 ^ new_sboxw;
            rcon_step_req = 1'b1;
          end
          k1           = w1 ^ k0;
          k2           = w2 ^ k1;
          k3           = w3 ^ k2;
          next_rk_val  = {k0, k1, k2, k3};
          next_pk1_val = {k0, k1, k2, k3};
          next_pk1_we  = 1'b1;
          next_pk0_val = prev_key1_reg;
          next_pk0_we  = 1'b1;
        end
      end
    end
  end

  logic [3:0] target_rounds;
  assign target_rounds  = (keylen == KEY_MODE_128) ? ROUNDS_128 : ROUNDS_256;
  assign do_expand_step = (key_mem_ctrl_reg == KS_EXPAND);

  always_ff @(posedge clk or negedge reset_n) begin
    if (!reset_n) begin
      for (int idx = 0; idx <= 14; idx++) begin
        key_mem[idx] <= 128'h0;
      end
      prev_key0_reg    <= 128'h0;
      prev_key1_reg    <= 128'h0;
      rcon_reg         <= 8'h00;
      round_ctr_reg    <= 4'h0;
      ready_reg        <= 1'b0;
      key_mem_ctrl_reg <= KS_IDLE;
    end else if (zeroize) begin
      for (int idx = 0; idx <= 14; idx++) begin
        key_mem[idx] <= 128'h0;
      end
      prev_key0_reg    <= 128'h0;
      prev_key1_reg    <= 128'h0;
      rcon_reg         <= 8'h00;
      round_ctr_reg    <= 4'h0;
      ready_reg        <= 1'b0;
      key_mem_ctrl_reg <= KS_IDLE;
    end else begin
      if (rcon_init_req) begin
        rcon_reg <= 8'h8d;
      end else if (rcon_step_req) begin
        rcon_reg <= {rcon_reg[6:0], 1'b0} ^ (8'h1b & {8{rcon_reg[7]}});
      end

      if (next_rk_we && (round_ctr_reg <= ROUNDS_256)) begin
        key_mem[round_ctr_reg] <= next_rk_val;
      end
      if (next_pk0_we) begin
        prev_key0_reg <= next_pk0_val;
      end
      if (next_pk1_we) begin
        prev_key1_reg <= next_pk1_val;
      end

      case (key_mem_ctrl_reg)
        KS_IDLE: begin
          if (init_cmd) begin
            ready_reg        <= 1'b0;
            key_mem_ctrl_reg <= KS_INIT;
          end
        end
        KS_INIT: begin
          round_ctr_reg    <= 4'd0;
          key_mem_ctrl_reg <= KS_EXPAND;
        end
        KS_EXPAND: begin
          round_ctr_reg <= round_ctr_reg + 4'd1;
          if (round_ctr_reg == target_rounds) begin
            key_mem_ctrl_reg <= KS_COMPLETE;
          end
        end
        KS_COMPLETE: begin
          ready_reg        <= 1'b1;
          key_mem_ctrl_reg <= KS_IDLE;
        end
        default: begin
          ready_reg        <= 1'b0;
          round_ctr_reg    <= 4'd0;
          key_mem_ctrl_reg <= KS_IDLE;
        end
      endcase
    end
  end

endmodule
