`timescale 1ns/1ps
module tb;
  bit clk_i = 0;
  always #5 clk_i = ~clk_i;

  logic         rst_ni      = 0;
  logic [3:0]   req_i       = 0;
  logic [3:0]   we_i        = 0;
  logic [3:0]   relay_i     = 0;
  logic [1:0]   swap_mode_i = 0;
  logic [7:0]   addr_i      = 0;
  logic [127:0] wdata_i     = 0;
  logic [15:0]  be_i        = 0;
  wire  [127:0] rdata_o;

  banked dut (
    .clk_i       ( clk_i       ),
    .rst_ni      ( rst_ni      ),
    .req_i       ( req_i       ),
    .we_i        ( we_i        ),
    .relay_i     ( relay_i     ),
    .swap_mode_i ( swap_mode_i ),
    .addr_i      ( addr_i      ),
    .wdata_i     ( wdata_i     ),
    .be_i        ( be_i        ),
    .rdata_o     ( rdata_o     )
  );

  logic [127:0] ref_mem  [4][256];
  logic [127:0] ref_dout [4];

  function automatic [127:0] apply_be128(
    input [127:0] old_val,
    input [127:0] new_val,
    input [15:0]  be_mask
  );
    logic [127:0] res;
    integer b;
    begin
      res = old_val;
      for (b = 0; b < 16; b = b + 1) begin
        if (be_mask[b]) res[b*8 +: 8] = new_val[b*8 +: 8];
      end
      return res;
    end
  endfunction

  task automatic step_and_check(
    input [3:0]   t_req,
    input [3:0]   t_we,
    input [3:0]   t_relay,
    input [1:0]   t_swap,
    input [7:0]   t_addr,
    input [127:0] t_wdata,
    input [15:0]  t_be,
    input string  tag
  );
    logic [127:0] next_dout [4];
    logic [63:0]  low_perm;
    logic [63:0]  rel_hi;
    logic [7:0]   low_be_p;
    logic [127:0] eff_wdata;
    logic [15:0]  eff_be;
    logic [127:0] exp_rdata_o;
    integer c;
    begin
      req_i       = t_req;
      we_i        = t_we;
      relay_i     = t_relay;
      swap_mode_i = t_swap;
      addr_i      = t_addr;
      wdata_i     = t_wdata;
      be_i        = t_be;

      low_be_p = t_swap[0] ? {
        t_be[4], t_be[5], t_be[6], t_be[7],
        t_be[0], t_be[1], t_be[2], t_be[3]
      } : t_be[7:0];
      for (c = 0; c < 4; c = c + 1) begin
        next_dout[c] = ref_dout[c];
        if (t_req[c]) begin
          if (t_we[c]) begin
            low_perm  = t_swap[0] ? {
              ref_dout[c][39:32], ref_dout[c][47:40], ref_dout[c][55:48], ref_dout[c][63:56],
              ref_dout[c][7:0],   ref_dout[c][15:8],  ref_dout[c][23:16], ref_dout[c][31:24]
            } : ref_dout[c][63:0];
            rel_hi    = t_swap[1] ? (low_perm ^ t_wdata[127:64]) : low_perm;
            eff_wdata = t_relay[c] ? {rel_hi, t_wdata[63:0]} : t_wdata;
            eff_be    = t_relay[c] ? {t_be[15:8] | low_be_p, t_be[7:0] & t_be[15:8]} : t_be;
            ref_mem[c][t_addr] = apply_be128(ref_mem[c][t_addr], eff_wdata, eff_be);
          end else begin
            next_dout[c] = ref_mem[c][t_addr];
          end
        end
      end

      @(negedge clk_i);
      for (c = 0; c < 4; c = c + 1) begin
        ref_dout[c] = next_dout[c];
      end
      exp_rdata_o = ref_dout[0] ^ ref_dout[1] ^ ref_dout[2] ^ ref_dout[3];
      if (tag != "init_parallel_write" && rdata_o !== exp_rdata_o) begin
        $fatal(1, "FAIL [%s] addr=%0h req=%b we=%b relay=%b swap=%b be=%04h got=%032h exp=%032h",
               tag, t_addr, t_req, t_we, t_relay, t_swap, t_be, rdata_o, exp_rdata_o);
      end
    end
  endtask

  integer seed = 101;
  integer k, m, iter;
  logic [127:0] patA, patB, patC, patD;
  logic [31:0]  rng;

  function automatic [31:0] next_rng(input [31:0] s);
    begin
      next_rng = (s * 32'h0019660d) + 32'h3c6ef35f;
    end
  endfunction

  initial begin
    if (!$value$plusargs("SEED=%d", seed)) seed = 101;
    rng  = seed ^ 32'h9e3779b9;
    patA = 128'hfedcba98_76543210_12345678_9abcdef0 ^ {4{rng}};
    rng  = next_rng(rng);
    patB = 128'h01234567_89abcdef_88776655_44332211 ^ {4{rng}};
    rng  = next_rng(rng);
    patC = 128'ha5a5f0f0_5a5a0f0f_c3c33c3c_96966969 ^ {4{rng}};
    rng  = next_rng(rng);
    patD = 128'h13579bdf_2468ace0_f0e1d2c3_b4a59687 ^ {4{rng}};

    for (k = 0; k < 4; k = k + 1) begin
      ref_dout[k] = '0;
    end

    @(negedge clk_i);
    rst_ni = 1;

    step_and_check(4'b1111, 4'b1111, 4'b0000, 2'b00, 8'h10, patA, 16'hffff, "init_parallel_write");
    step_and_check(4'b1111, 4'b0000, 4'b0000, 2'b00, 8'h10, 128'h0, 16'h0000, "init_parallel_read");

    for (k = 0; k < 4; k = k + 1) begin
      for (m = 0; m < 4; m = m + 1) begin
        logic [7:0] a_src, a_dst;
        a_src = 8'h10 + {4'd0, k[1:0], m[1:0]};
        a_dst = 8'h30 + {4'd0, k[1:0], m[1:0]};
        step_and_check(4'b0001 << k, 4'b0001 << k, 4'b0000, 2'b00, a_src, patB ^ (128'(k*4 + m) << 8), 16'hffff, "dir_init_src");
        step_and_check(4'b0001 << k, 4'b0001 << k, 4'b0000, 2'b00, a_dst, patC ^ (128'(k*4 + m) << 16), 16'hffff, "dir_init_dst");
        step_and_check(4'b0001 << k, 4'b0000,      4'b0000, 2'b00, a_src, 128'h0, 16'h0000, "dir_latch_src");
        step_and_check(4'b0001 << k, 4'b0001 << k, 4'b0001 << k, m[1:0], a_src, patD ^ m, 16'hffff, "dir_full_relay");
        step_and_check(4'b0001 << k, 4'b0000,      4'b0000,      2'b00,  a_src, 128'h0,   16'h0000, "dir_read_full_relay");
        step_and_check(4'b0001 << k, 4'b0000,      4'b0000,      2'b00,  a_src, 128'h0,   16'h0000, "dir_relatch_src");
        step_and_check(4'b0001 << k, 4'b0001 << k, 4'b0001 << k, m[1:0], a_dst, ~patA,    16'h3c96, "dir_partial_relay");
        step_and_check(4'b0001 << k, 4'b0000,      4'b0000,      2'b00,  a_dst, 128'h0,   16'h0000, "dir_read_partial_relay");
      end
    end

    for (k = 0; k < 8; k = k + 1) begin
      rng = next_rng(rng);
      step_and_check(4'b1111, 4'b1111, 4'b0000, 2'b00, 8'h50 + k[7:0],
                     {rng, rng ^ 32'hdeadbeef, ~rng, rng ^ 32'h12345678}, 16'hffff, "rand_pool_init");
    end
    step_and_check(4'b1111, 4'b0000, 4'b0000, 2'b00, 8'h50, 128'h0, 16'h0000, "rand_pool_prime_dout");

    for (iter = 0; iter < 64; iter = iter + 1) begin
      logic [3:0]   r_req, r_we, r_rel;
      logic [1:0]   r_swp;
      logic [7:0]   r_addr;
      logic [127:0] r_wdata;
      logic [15:0]  r_be;
      rng    = next_rng(rng);
      r_req  = (rng[3:0] == 4'b0000) ? 4'b0101 : rng[3:0];
      r_we   = rng[7:4];
      r_rel  = rng[11:8];
      r_addr = 8'h50 + {5'd0, rng[14:12]};
      r_swp  = rng[15:14];
      r_be   = rng[31:16];
      rng    = next_rng(rng);
      r_wdata[63:0]   = {rng, rng ^ 32'ha5a5a5a5};
      rng    = next_rng(rng);
      r_wdata[127:64] = {rng, rng ^ 32'h5a5a5a5a};

      step_and_check(r_req, r_we, r_rel, r_swp, r_addr, r_wdata, r_be, "rand_stress_op");
      step_and_check(4'b1111, 4'b0000, 4'b0000, 2'b00, r_addr, 128'h0, 16'h0000, "rand_stress_readback");
    end

    $display("PASS four SRAM clusters");
    $finish;
  end
endmodule
