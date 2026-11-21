//======================================================================
//
// sha512_masked_w_mem.sv (Alternate Gold: Modulo-16 Circular Ring Schedule)
//
// Uses circular pointer indexing instead of shifting all 16 words, while
// refreshing all 16 share pairs every round.
//======================================================================

module sha512_masked_w_mem
                    import sha512_masked_defines_pkg::*;
                    (
                    input wire            clk,
                    input wire            reset_n,
                    input wire            zeroize,

                    input wire [1023 : 0] block_msg,
                    input wire [1023 : 0] rw_masking_rnd,
                    input wire [63 : 0]   gamma_a2b,
                    input wire [3 : 0]    q_b2a,

                    input wire            latch_block,
                    input wire            init_cmd,
                    input wire            next_cmd,
                    output wire masked_reg_t  w_val
                   );

  masked_reg_t w_mem [0 : 15];
  reg [6 : 0]  w_ctr_reg;

  logic [3 : 0] idx_p;
  logic [3 : 0] idx_p1;
  logic [3 : 0] idx_p9;
  logic [3 : 0] idx_p14;

  masked_reg_t w_0, w_1, w_9, w_14;
  masked_reg_t d0, d1;
  masked_reg_t w_0_b2a, d0_b2a, w_9_b2a, d1_b2a;
  masked_reg_t w_new;

  assign idx_p   = w_ctr_reg[3 : 0];
  assign idx_p1  = w_ctr_reg[3 : 0] + 4'd1;
  assign idx_p9  = w_ctr_reg[3 : 0] + 4'd9;
  assign idx_p14 = w_ctr_reg[3 : 0] + 4'd14;

  always_comb begin
    w_0  = w_mem[idx_p];
    w_1  = w_mem[idx_p1];
    w_9  = w_mem[idx_p9];
    w_14 = w_mem[idx_p14];

    d0 = '{masked: ROT1(w_1.masked),   random: ROT1(w_1.random)};
    d1 = '{masked: ROT14(w_14.masked), random: ROT14(w_14.random)};

    w_0_b2a = B2A_conv(w_0, q_b2a[0]);
    d0_b2a  = B2A_conv(d0,  q_b2a[1]);
    w_9_b2a = B2A_conv(w_9, q_b2a[2]);
    d1_b2a  = B2A_conv(d1,  q_b2a[3]);

    w_new = a2b_gamma64(
      masked_sum(masked_sum(w_0_b2a, d0_b2a), masked_sum(w_9_b2a, d1_b2a)),
      gamma_a2b
    );
  end

  assign w_val = (w_ctr_reg < 7'd16) ? w_mem[idx_p] : w_new;

  always_ff @(posedge clk or negedge reset_n) begin
    if (!reset_n) begin
      for (int i = 0; i < 16; i++)
        w_mem[i] <= '{masked: 64'h0, random: 64'h0};
      w_ctr_reg <= 7'd0;
    end
    else if (zeroize) begin
      for (int i = 0; i < 16; i++)
        w_mem[i] <= '{masked: 64'h0, random: 64'h0};
      w_ctr_reg <= 7'd0;
    end
    else if (latch_block) begin
      for (int i = 0; i < 16; i++) begin
        w_mem[i] <= '{
          masked: block_msg[(15 - i) * 64 +: 64] ^ rw_masking_rnd[(15 - i) * 64 +: 64],
          random: rw_masking_rnd[(15 - i) * 64 +: 64]
        };
      end
      w_ctr_reg <= 7'd0;
    end
    else if (init_cmd) begin
      for (int i = 0; i < 16; i++) begin
        w_mem[i] <= remask_pair(w_mem[i], rw_masking_rnd[(15 - i) * 64 +: 64]);
      end
      w_ctr_reg <= 7'd0;
    end
    else if (next_cmd) begin
      for (int i = 0; i < 16; i++) begin
        if ((w_ctr_reg >= 7'd16) && (i[3:0] == idx_p))
          w_mem[i] <= remask_pair(w_new, rw_masking_rnd[(15 - i) * 64 +: 64]);
        else
          w_mem[i] <= remask_pair(w_mem[i], rw_masking_rnd[(15 - i) * 64 +: 64]);
      end
      w_ctr_reg <= w_ctr_reg + 7'd1;
    end
  end

endmodule
