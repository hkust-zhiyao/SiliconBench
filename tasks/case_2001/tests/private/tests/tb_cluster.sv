`timescale 1ns/1ps
module tb_cluster;
  bit clk_i = 0;
  always #5 clk_i = ~clk_i;

  logic         rst_ni = 0;
  logic         req_i = 0;
  logic         branch_i = 0;
  logic [31:0]  addr_i = 0;
  logic         ready_i = 0;
  logic         cheriot_force_uc_i = 0;
  wire          valid_o;
  wire  [31:0]  rdata_o;
  wire  [31:0]  addr_o;
  wire          err_o;
  wire          err_plus2_o;
  wire          busy_o;

  logic [3:0]   host_req_i = 0;
  logic [3:0]   host_we_i = 0;
  logic [3:0]   host_mirror_i = 0;
  logic [7:0]   host_addr_i = 0;
  logic [127:0] host_wdata_i = 0;
  logic [15:0]  host_be_i = 0;
  logic         host_fault_i = 0;
  wire  [127:0] cluster_xor_rdata_o;

  ibex_prefetch_sram_cluster dut (
    .clk_i               ( clk_i               ),
    .rst_ni              ( rst_ni              ),
    .req_i               ( req_i               ),
    .branch_i            ( branch_i            ),
    .addr_i              ( addr_i              ),
    .ready_i             ( ready_i             ),
    .cheriot_force_uc_i  ( cheriot_force_uc_i  ),
    .valid_o             ( valid_o             ),
    .rdata_o             ( rdata_o             ),
    .addr_o              ( addr_o              ),
    .err_o               ( err_o               ),
    .err_plus2_o         ( err_plus2_o         ),
    .busy_o              ( busy_o              ),
    .host_req_i          ( host_req_i          ),
    .host_we_i           ( host_we_i           ),
    .host_mirror_i       ( host_mirror_i       ),
    .host_addr_i         ( host_addr_i         ),
    .host_wdata_i        ( host_wdata_i        ),
    .host_be_i           ( host_be_i           ),
    .host_fault_i        ( host_fault_i        ),
    .cluster_xor_rdata_o ( cluster_xor_rdata_o )
  );

  // Cycle-accurate golden model of the four 256x128 clusters and their output registers
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

  task automatic step_host_check(
    input [3:0]   t_req,
    input [3:0]   t_we,
    input [3:0]   t_mirror,
    input [7:0]   t_addr,
    input [127:0] t_wdata,
    input [15:0]  t_be,
    input string  tag
  );
    logic [127:0] next_dout [4];
    logic [127:0] eff_wdata;
    logic [15:0]  eff_be;
    logic [127:0] exp_rdata_o;
    integer c;
    begin
      req_i         = 1'b0;
      branch_i      = 1'b0;
      ready_i       = 1'b0;
      host_req_i    = t_req;
      host_we_i     = t_we;
      host_mirror_i = t_mirror;
      host_addr_i   = t_addr;
      host_wdata_i  = t_wdata;
      host_be_i     = t_be;
      host_fault_i  = 1'b0;

      for (c = 0; c < 4; c = c + 1) begin
        next_dout[c] = ref_dout[c];
        if (t_req[c]) begin
          if (t_we[c]) begin
            eff_wdata = t_mirror[c] ? {ref_dout[c][63:0], t_wdata[63:0]} : t_wdata;
            eff_be    = t_mirror[c] ? {t_be[15:8] | t_be[7:0], t_be[7:0] & t_be[15:8]} : t_be;
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
      if (tag != "init_parallel_write" && cluster_xor_rdata_o !== exp_rdata_o) begin
        $fatal(1, "FAIL [%s] addr=%0h req=%b we=%b mirror=%b be=%04h got=%032h exp=%032h",
               tag, t_addr, t_req, t_we, t_mirror, t_be, cluster_xor_rdata_o, exp_rdata_o);
      end
    end
  endtask

  integer seed = 101;
  integer k, iter;
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

    // 1. Parallel write of identical pattern across all 4 clusters and parallel read cancellation
    step_host_check(4'b1111, 4'b1111, 4'b0000, 8'h10, patA, 16'hffff, "init_parallel_write");
    step_host_check(4'b1111, 4'b0000, 4'b0000, 8'h10, 128'h0, 16'h0000, "init_parallel_read");

    // 2. Per-cluster distinct write, readback, and full low-to-high mirror write (host_be_i = 16'hffff)
    for (k = 0; k < 4; k = k + 1) begin
      logic [127:0] wval;
      wval = patB ^ ({4{32'(k + 1)}} * 32'h11111111);
      step_host_check(4'b0001 << k, 4'b0001 << k, 4'b0000,      8'h10 + k[7:0], wval,     16'hffff, "cluster_full_write");
      step_host_check(4'b0001 << k, 4'b0000,      4'b0000,      8'h10 + k[7:0], 128'h0,   16'h0000, "cluster_read_before_mirror");
      step_host_check(4'b0001 << k, 4'b0001 << k, 4'b0001 << k, 8'h10 + k[7:0], patC ^ k, 16'hffff, "cluster_full_mirror_write");
      step_host_check(4'b0001 << k, 4'b0000,      4'b0000,      8'h10 + k[7:0], 128'h0,   16'h0000, "cluster_read_after_full_mirror");
    end

    // 3. Non-destructive high-only selective mirror write (host_be_i = 16'h00a5)
    for (k = 0; k < 4; k = k + 1) begin
      logic [7:0] a_src, a_dst;
      a_src = 8'h20 + k[7:0];
      a_dst = 8'h30 + k[7:0];
      step_host_check(4'b0001 << k, 4'b0001 << k, 4'b0000,      a_src, patC ^ (128'(k) << 8),  16'hffff, "sel_mirror_init_src");
      step_host_check(4'b0001 << k, 4'b0001 << k, 4'b0000,      a_dst, patD ^ (128'(k) << 16), 16'hffff, "sel_mirror_init_dst");
      step_host_check(4'b0001 << k, 4'b0000,      4'b0000,      a_src, 128'h0,                 16'h0000, "sel_mirror_latch_src");
      step_host_check(4'b0001 << k, 4'b0001 << k, 4'b0001 << k, a_dst, ~patD,                  16'h00a5, "sel_mirror_high_only_write");
      step_host_check(4'b0001 << k, 4'b0000,      4'b0000,      a_dst, 128'h0,                 16'h0000, "sel_mirror_high_only_verify");
    end

    // 4. Split-mask mirror write (host_be_i = 16'h3c5a)
    for (k = 0; k < 4; k = k + 1) begin
      logic [7:0] addr_s;
      addr_s = 8'h40 + k[7:0];
      step_host_check(4'b0001 << k, 4'b0001 << k, 4'b0000,      addr_s, patA ^ patD ^ k, 16'hffff, "split_mirror_init");
      step_host_check(4'b0001 << k, 4'b0000,      4'b0000,      addr_s, 128'h0,          16'h0000, "split_mirror_read");
      step_host_check(4'b0001 << k, 4'b0001 << k, 4'b0001 << k, addr_s, patB ^ k,        16'h3c5a, "split_mirror_write");
      step_host_check(4'b0001 << k, 4'b0000,      4'b0000,      addr_s, 128'h0,          16'h0000, "split_mirror_verify");
    end

    // 5. Randomized multi-cluster stress across 8 addresses (0x50..0x57)
    for (k = 0; k < 8; k = k + 1) begin
      rng = next_rng(rng);
      step_host_check(4'b1111, 4'b1111, 4'b0000, 8'h50 + k[7:0],
                      {rng, rng ^ 32'hdeadbeef, ~rng, rng ^ 32'h12345678}, 16'hffff, "rand_pool_init");
    end
    step_host_check(4'b1111, 4'b0000, 4'b0000, 8'h50, 128'h0, 16'h0000, "rand_pool_prime_dout");

    for (iter = 0; iter < 64; iter = iter + 1) begin
      logic [3:0]   r_req, r_we, r_mir;
      logic [7:0]   r_addr;
      logic [127:0] r_wdata;
      logic [15:0]  r_be;
      rng    = next_rng(rng);
      r_req  = (rng[3:0] == 4'b0000) ? 4'b0101 : rng[3:0];
      r_we   = rng[7:4];
      r_mir  = rng[11:8];
      r_addr = 8'h50 + {5'd0, rng[14:12]};
      r_be   = rng[31:16];
      rng    = next_rng(rng);
      r_wdata[63:0]   = {rng, rng ^ 32'ha5a5a5a5};
      rng    = next_rng(rng);
      r_wdata[127:64] = {rng, rng ^ 32'h5a5a5a5a};

      step_host_check(r_req, r_we, r_mir, r_addr, r_wdata, r_be, "rand_stress_op");
      step_host_check(4'b1111, 4'b0000, 4'b0000, r_addr, 128'h0, 16'h0000, "rand_stress_readback");
    end

    // 6. End-to-end instruction fetch from SRAM cluster after mirror relay & fault injection
    begin
      logic [127:0] line0;
      // Write a 128-bit line into bank 1, addr 8'h02 (byte addr 0x1020..0x102f):
      // low 64 bits hold two 32-bit uncompressed instructions: 0x1122_3333 and 0x4455_6673
      line0 = {64'h0, 32'h4455_6673, 32'h1122_3333};
      step_host_check(4'b0010, 4'b0010, 4'b0000, 8'h02, line0, 16'hffff, "fetch_line_write");
      // Read bank 1, addr 8'h02 to latch low 64 bits into bank_rdata[1][63:0]
      step_host_check(4'b0010, 4'b0000, 4'b0000, 8'h02, 128'h0, 16'h0000, "fetch_line_latch");
      // Mirror-relay low 64 bits into high 64 bits of bank 1, addr 8'h02 (bytes 0x1028..0x102f)
      // while write-protecting low 64 bits via host_be_i = 16'h00ff
      step_host_check(4'b0010, 4'b0010, 4'b0010, 8'h02, 128'hdeadbeef_deadbeef, 16'h00ff, "fetch_line_mirror");

      // Now branch prefetch buffer to 0x0000_1028 (bank 1, addr 8'h02, lane 2 -> mirrored 0x1122_3333)
      host_req_i = 4'b0000;
      host_we_i  = 4'b0000;
      req_i      = 1'b1;
      branch_i   = 1'b1;
      addr_i     = 32'h0000_1028;
      ready_i    = 1'b0;
      @(negedge clk_i);
      branch_i   = 1'b0;
      @(negedge clk_i);
      if (valid_o !== 1'b1 || addr_o !== 32'h0000_1028 || rdata_o !== 32'h1122_3333 || err_o !== 1'b0) begin
        $fatal(1, "FAIL [fetch_mirrored_word0] valid=%b addr=%h rdata=%h err=%b",
               valid_o, addr_o, rdata_o, err_o);
      end
      // Consume 0x1028 and check 0x102c (lane 3 -> mirrored 0x4455_6673)
      ready_i = 1'b1;
      @(negedge clk_i);
      ready_i = 1'b0;
      if (valid_o !== 1'b1 || addr_o !== 32'h0000_102c || rdata_o !== 32'h4455_6673 || err_o !== 1'b0) begin
        $fatal(1, "FAIL [fetch_mirrored_word1] valid=%b addr=%h rdata=%h err=%b",
               valid_o, addr_o, rdata_o, err_o);
      end

      // Branch to out-of-range unaligned address 0x0000_4002 (instr_addr[31:14] != 0 -> instr_err = 1)
      branch_i = 1'b1;
      addr_i   = 32'h0000_4002;
      ready_i  = 1'b0;
      @(negedge clk_i);
      branch_i = 1'b0;
      req_i    = 1'b0;
      @(negedge clk_i);
      if (valid_o !== 1'b1 || addr_o !== 32'h0000_4002 || err_o !== 1'b1 || err_plus2_o !== 1'b0) begin
        $fatal(1, "FAIL [fetch_unaligned_fault] valid=%b addr=%h err=%b err_plus2=%b",
               valid_o, addr_o, err_o, err_plus2_o);
      end
    end

    $display("PASS ibex_prefetch_sram_cluster");
    $finish;
  end
endmodule
