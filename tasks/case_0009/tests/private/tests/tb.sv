`timescale 1ns/1ps
module tb;
  import hwpe_ctrl_package::*;

  localparam int unsigned NB_LOOPS  = 3;
  localparam int unsigned NB_REG    = 3;
  localparam int unsigned NB_RO_REG = 4;

  logic clk = 1'b0;
  always #5 clk = ~clk;

  logic rst_ni = 1'b0;
  logic s_clr = 1'b0, u_clr = 1'b0;
  ctrl_uloop_t cs, cu;
  flags_uloop_t fs, fu;
  uloop_code_t prog;
  logic [NB_RO_REG-1:0][31:0] regs;

  hwpe_ctrl_uloop #(
    .NB_LOOPS  ( NB_LOOPS  ),
    .NB_REG    ( NB_REG    ),
    .NB_RO_REG ( NB_RO_REG ),
    .SHADOWED  ( 1         )
  ) dut_s (
    .clk_i            ( clk    ),
    .rst_ni           ( rst_ni ),
    .test_mode_i      ( 1'b0   ),
    .clear_i          ( s_clr  ),
    .ctrl_i           ( cs     ),
    .flags_o          ( fs     ),
    .uloop_code_i     ( prog   ),
    .registers_read_i ( regs   )
  );

  hwpe_ctrl_uloop #(
    .NB_LOOPS  ( NB_LOOPS  ),
    .NB_REG    ( NB_REG    ),
    .NB_RO_REG ( NB_RO_REG ),
    .SHADOWED  ( 0         )
  ) dut_u (
    .clk_i            ( clk    ),
    .rst_ni           ( rst_ni ),
    .test_mode_i      ( 1'b0   ),
    .clear_i          ( u_clr  ),
    .ctrl_i           ( cu     ),
    .flags_o          ( fu     ),
    .uloop_code_i     ( prog   ),
    .registers_read_i ( regs   )
  );

  int seed, r0, r1, r2, total_steps;
  int step0, step1, step2, mv_const;
  logic [31:0] rnd;

  int s_i0, s_i1, s_i2, s_o0, s_o1, s_o2, s_events, s_phase;
  int u_i0, u_i1, u_i2, u_o0, u_o1, u_o2, u_events, u_phase;

  task automatic tick;
    @(negedge clk);
    #1;
  endtask

  function automatic logic next_rnd_bit();
    rnd = rnd ^ (rnd << 13);
    rnd = rnd ^ (rnd >> 17);
    rnd = rnd ^ (rnd << 5);
    return rnd[0];
  endfunction

  task automatic reset_s_model;
    s_i0 = 0; s_i1 = 0; s_i2 = 0;
    s_o0 = 0; s_o1 = 0; s_o2 = 0;
    s_events = 0;
  endtask

  task automatic reset_u_model;
    u_i0 = 0; u_i1 = 0; u_i2 = 0;
    u_o0 = 0; u_o1 = 0; u_o2 = 0;
    u_events = 0;
  endtask

  task automatic step_model(
    inout int i0, inout int i1, inout int i2,
    inout int o0, inout int o1, inout int o2,
    output int exp_loop,
    output logic [2:0] exp_upd
  );
    if (i0 < r0 - 1) begin
      exp_loop = 0;
      exp_upd  = 3'b001;
      i0++;
      o0 += step0;
      o1 += step1;
    end else if (i1 < r1 - 1) begin
      exp_loop = 1;
      exp_upd  = 3'b011;
      i0 = 0;
      i1++;
      o0 += step2;
      o1  = mv_const;
      o2 += step0;
    end else if (i2 < r2 - 1) begin
      exp_loop = 2;
      exp_upd  = 3'b111;
      i0 = 0;
      i1 = 0;
      i2++;
      o2 += step1;
      o0  = o2;
    end else begin
      $fatal(1, "Model stepped past final iteration");
    end
  endtask

  task automatic check_s_clear(input string label);
    if (fs.valid !== 1'b0 || fs.done !== 1'b0 || fs.ready !== 1'b0 ||
        fs.loop !== '0 || fs.offs[0] !== '0 || fs.offs[1] !== '0 || fs.offs[2] !== '0 ||
        fs.idx[0] !== '0 || fs.idx[1] !== '0 || fs.idx[2] !== '0 ||
        fs.idx_update[2:0] !== 3'b000) begin
      $fatal(1, "SHADOWED=1 %s failed to clear state: valid=%b done=%b ready=%b loop=%0d offs={%0d,%0d,%0d} idx={%0d,%0d,%0d} upd=%b",
             label, fs.valid, fs.done, fs.ready, fs.loop,
             fs.offs[0], fs.offs[1], fs.offs[2],
             fs.idx[0], fs.idx[1], fs.idx[2], fs.idx_update[2:0]);
    end
  endtask

  task automatic check_u_clear(input string label);
    if (fu.valid !== 1'b0 || fu.done !== 1'b0 ||
        fu.loop !== '0 || fu.offs[0] !== '0 || fu.offs[1] !== '0 || fu.offs[2] !== '0 ||
        fu.idx[0] !== '0 || fu.idx[1] !== '0 || fu.idx[2] !== '0 ||
        fu.idx_update[2:0] !== 3'b000) begin
      $fatal(1, "SHADOWED=0 %s failed to clear state: valid=%b done=%b loop=%0d offs={%0d,%0d,%0d} idx={%0d,%0d,%0d} upd=%b",
             label, fu.valid, fu.done, fu.loop,
             fu.offs[0], fu.offs[1], fu.offs[2],
             fu.idx[0], fu.idx[1], fu.idx[2], fu.idx_update[2:0]);
    end
  endtask

  task automatic check_s_result;
    int exp_loop;
    logic [2:0] exp_upd;
    if (fs.done) begin
      if (s_events != total_steps ||
          s_i0 != r0 - 1 || s_i1 != r1 - 1 || s_i2 != r2 - 1 ||
          fs.idx[0] !== s_i0[11:0] || fs.idx[1] !== s_i1[11:0] || fs.idx[2] !== s_i2[11:0] ||
          fs.offs[0] !== s_o0 || fs.offs[1] !== s_o1 || fs.offs[2] !== s_o2 ||
          fs.idx_update[2:0] !== 3'b000) begin
        $fatal(1, "SHADOWED=1 completion mismatch at event=%0d/%0d: got idx={%0d,%0d,%0d} offs={%0d,%0d,%0d} upd=%b, expected idx={%0d,%0d,%0d} offs={%0d,%0d,%0d}",
               s_events, total_steps,
               fs.idx[0], fs.idx[1], fs.idx[2], fs.offs[0], fs.offs[1], fs.offs[2], fs.idx_update[2:0],
               s_i0, s_i1, s_i2, s_o0, s_o1, s_o2);
      end
      s_phase = 4;
    end else begin
      if (s_events >= total_steps)
        $fatal(1, "SHADOWED=1 unexpected extra non-done result at event=%0d", s_events);
      step_model(s_i0, s_i1, s_i2, s_o0, s_o1, s_o2, exp_loop, exp_upd);
      if (fs.loop !== exp_loop[2:0]) begin
        $fatal(1, "SHADOWED=1 loop mismatch phase=%0d event=%0d: got loop=%0d expected=%0d",
               s_phase, s_events, fs.loop, exp_loop);
      end
      if (fs.idx[0] !== s_i0[11:0] || fs.idx[1] !== s_i1[11:0] || fs.idx[2] !== s_i2[11:0] ||
          fs.offs[0] !== s_o0 || fs.offs[1] !== s_o1 || fs.offs[2] !== s_o2 ||
          fs.idx_update[2:0] !== exp_upd) begin
        $fatal(1, "SHADOWED=1 content mismatch phase=%0d event=%0d: got idx={%0d,%0d,%0d} offs={%0d,%0d,%0d} upd=%b, expected idx={%0d,%0d,%0d} offs={%0d,%0d,%0d} upd=%b",
               s_phase, s_events,
               fs.idx[0], fs.idx[1], fs.idx[2], fs.offs[0], fs.offs[1], fs.offs[2], fs.idx_update[2:0],
               s_i0, s_i1, s_i2, s_o0, s_o1, s_o2, exp_upd);
      end
      s_events++;
    end
  endtask

  task automatic check_u_result;
    int exp_loop;
    logic [2:0] exp_upd;
    if (fu.done) begin
      $fatal(1, "SHADOWED=0 asserted done simultaneously with iteration valid at event=%0d", u_events);
    end
    if (u_events >= total_steps) begin
      $fatal(1, "SHADOWED=0 unexpected extra valid result at event=%0d", u_events);
    end
    step_model(u_i0, u_i1, u_i2, u_o0, u_o1, u_o2, exp_loop, exp_upd);
    if (fu.loop !== exp_loop[2:0]) begin
      $fatal(1, "SHADOWED=0 loop mismatch phase=%0d event=%0d: got loop=%0d expected=%0d",
             u_phase, u_events, fu.loop, exp_loop);
    end
    if (fu.idx[0] !== u_i0[11:0] || fu.idx[1] !== u_i1[11:0] || fu.idx[2] !== u_i2[11:0] ||
        fu.offs[0] !== u_o0 || fu.offs[1] !== u_o1 || fu.offs[2] !== u_o2 ||
        fu.idx_update[2:0] !== exp_upd) begin
      $fatal(1, "SHADOWED=0 content mismatch phase=%0d event=%0d: got idx={%0d,%0d,%0d} offs={%0d,%0d,%0d} upd=%b, expected idx={%0d,%0d,%0d} offs={%0d,%0d,%0d} upd=%b",
             u_phase, u_events,
             fu.idx[0], fu.idx[1], fu.idx[2], fu.offs[0], fu.offs[1], fu.offs[2], fu.idx_update[2:0],
             u_i0, u_i1, u_i2, u_o0, u_o1, u_o2, exp_upd);
    end
    u_events++;
  endtask

  initial begin
    int cycles;
    if (!$value$plusargs("seed=%d", seed)) seed = 101;
    rnd = (seed == 0) ? 32'h13579bdf : seed;

    r0 = 2 + (seed % 2);
    r1 = 2 + ((seed / 2) % 2);
    r2 = 2;
    total_steps = (r0 * r1 * r2) - 1;

    step0    = 3 + (seed % 5);
    step1    = 11 + (seed % 7);
    step2    = 101 + (seed % 13);
    mv_const = 17 + (seed % 9);

    cs = '0;
    cu = '0;
    prog = '0;
    regs = '0;

    regs[0] = step0;
    regs[1] = step1;
    regs[2] = step2;
    regs[3] = mv_const;

    prog.range[0] = r0[11:0];
    prog.range[1] = r1[11:0];
    prog.range[2] = r2[11:0];

    // Loop 0: 2 ops at addr 0..1 (reg0 += ro0; reg1 += ro1)
    prog.loops[0].uloop_addr = 5'd0;
    prog.loops[0].nb_ops     = 4'd2;
    prog.code[0] = '{op_sel: 1'b1, a: 5'd0, b: 5'd3};
    prog.code[1] = '{op_sel: 1'b1, a: 5'd1, b: 5'd4};

    // Loop 1: 3 ops at addr 2..4 (reg0 += ro2; reg1 = ro3; reg2 += ro0)
    prog.loops[1].uloop_addr = 5'd2;
    prog.loops[1].nb_ops     = 4'd3;
    prog.code[2] = '{op_sel: 1'b1, a: 5'd0, b: 5'd5};
    prog.code[3] = '{op_sel: 1'b0, a: 5'd1, b: 5'd6};
    prog.code[4] = '{op_sel: 1'b1, a: 5'd2, b: 5'd3};

    // Loop 2: 2 ops at addr 5..6 (reg2 += ro1; reg0 = reg2)
    prog.loops[2].uloop_addr = 5'd5;
    prog.loops[2].nb_ops     = 4'd2;
    prog.code[5] = '{op_sel: 1'b1, a: 5'd2, b: 5'd4};
    prog.code[6] = '{op_sel: 1'b0, a: 5'd0, b: 5'd2};

    #2;
    tick();
    rst_ni = 1'b1;
    check_s_clear("post_reset");
    check_u_clear("post_reset");

    // ------------------------------------------------------------
    // Part 1: Directed mid-body ready stall & mid-body clear check
    // ------------------------------------------------------------
    reset_s_model();
    reset_u_model();
    cs.ready = 1'b1;
    cu.ready = 1'b1;

    // Advance 1 op of Loop 0 (curr_op: 0 -> 1, busy_sticky=1) in both SHADOWED=1 and SHADOWED=0
    cu.enable = 1'b1;
    tick();
    if (fs.valid) check_s_result();
    if (fu.valid) check_u_result();
    if (fs.ready)
      $fatal(1, "Premature ready after op 0 of 2-op Loop 0");

    // Stall for 2 cycles on curr_op == 1 (where busy_int == 0!)
    cs.ready  = 1'b0;
    cu.enable = 1'b0;
    tick();
    if (fs.valid) check_s_result();
    if (fu.valid) check_u_result();
    if (fs.ready)
      $fatal(1, "Premature ready during cycle 1 of mid-body stall on final op");
    tick();
    if (fs.valid) check_s_result();
    if (fu.valid) check_u_result();
    if (fs.ready)
      $fatal(1, "Premature ready during cycle 2 of mid-body stall on final op");

    // Resume execution for 1 cycle to complete op 1 of Loop 0
    cs.ready  = 1'b1;
    cu.enable = 1'b1;
    tick();
    // On this cycle: SHADOWED=0 must pulse fu.valid=1; SHADOWED=1 latches shadow_flags_wr on next edge
    if (!fu.valid)
      $fatal(1, "SHADOWED=0 failed to assert valid after resuming stalled final op");
    check_u_result();
    cu.enable = 1'b0;

    // Wait 1 cycle for SHADOWED=1 to latch flags_int into shadow_flags_wr
    cs.ready = 1'b0;
    tick();
    if (!fs.ready || fs.valid)
      $fatal(1, "SHADOWED=1 failed to assert ready after resumed final op");

    // Consume first SHADOWED=1 result
    cs.enable = 1'b1;
    tick();
    cs.enable = 1'b0;
    if (!fs.valid)
      $fatal(1, "SHADOWED=1 failed to assert valid on ctrl_i.enable");
    check_s_result();

    // Clear both instances with ctrl_i.clear before randomized multi-phase stress
    cs.clear = 1'b1;
    cu.clear = 1'b1;
    tick();
    cs.clear = 1'b0;
    cu.clear = 1'b0;
    check_s_clear("directed_ctrl_clear");
    check_u_clear("directed_ctrl_clear");

    // ------------------------------------------------------------
    // Part 2: Randomized multi-phase stress on SHADOWED=1 and SHADOWED=0
    // ------------------------------------------------------------
    reset_s_model();
    reset_u_model();
    s_phase = 0;
    u_phase = 0;

    for (cycles = 0; cycles < 3000 && (s_phase < 4 || u_phase < 3); cycles++) begin
      void'(next_rnd_bit());

      // Drive SHADOWED=1 (dut_s)
      if (s_phase < 4) begin
        cs.ready  = (rnd[1:0] != 2'b00);
        cs.enable = fs.ready && (rnd[4:2] == 3'b000);
      end else begin
        cs.ready  = 1'b0;
        cs.enable = 1'b0;
      end

      // Drive SHADOWED=0 (dut_u)
      cu.ready = 1'b1;
      if (u_phase < 3) begin
        cu.enable = (rnd[7:6] != 2'b00);
      end else begin
        cu.enable = 1'b0;
      end

      tick();

      // Check SHADOWED=1 valid outputs
      if (fs.valid) begin
        check_s_result();
      end

      // Check SHADOWED=0 valid outputs
      if (fu.valid) begin
        check_u_result();
      end

      // SHADOWED=1 phase transitions (testing ctrl_i.clear, clear_i, mid-body clear, and full completion)
      if (s_phase == 0 && s_events == r0 && fs.ready) begin
        // Result is pending in shadow_flags_wr right after Loop 1 (out_loop=1); test ctrl_i.clear
        cs.enable = 1'b0;
        cs.clear  = 1'b1;
        tick();
        cs.clear  = 1'b0;
        check_s_clear("phase0_ctrl_clear");
        if (fu.valid) check_u_result();
        reset_s_model();
        s_phase = 1;
      end else if (s_phase == 1 && s_events == (r0 * r1) && fs.ready) begin
        // Result is pending in shadow_flags_wr right after Loop 2 (out_loop=2); test external clear_i
        cs.enable = 1'b0;
        s_clr     = 1'b1;
        tick();
        s_clr     = 1'b0;
        check_s_clear("phase1_ext_clear");
        if (fu.valid) check_u_result();
        reset_s_model();
        s_phase = 2;
      end else if (s_phase == 2 && s_events == 1 && !fs.ready && !fs.valid) begin
        // Step 1 cycle into next loop body and clear mid-body via ctrl_i.clear
        cs.ready  = 1'b1;
        cs.enable = 1'b0;
        tick();
        if (fu.valid) check_u_result();
        cs.ready  = 1'b0;
        cs.enable = 1'b0;
        cs.clear  = 1'b1;
        tick();
        cs.clear  = 1'b0;
        check_s_clear("phase2_midbody_ctrl_clear");
        if (fu.valid) check_u_result();
        reset_s_model();
        s_phase = 3;
      end

      // SHADOWED=0 phase transitions (testing ctrl_i.clear, clear_i, and full completion to fu.done)
      if (u_phase == 0 && u_events == r0) begin
        cu.enable = 1'b0;
        cu.clear  = 1'b1;
        tick();
        cu.clear  = 1'b0;
        check_u_clear("u_phase0_ctrl_clear");
        if (fs.valid) check_s_result();
        reset_u_model();
        u_phase = 1;
      end else if (u_phase == 1 && u_events == (r0 * r1)) begin
        cu.enable = 1'b0;
        u_clr     = 1'b1;
        tick();
        u_clr     = 1'b0;
        check_u_clear("u_phase1_ext_clear");
        if (fs.valid) check_s_result();
        reset_u_model();
        u_phase = 2;
      end else if (u_phase == 2 && u_events == total_steps && fu.done) begin
        if (fu.idx[0] !== u_i0[11:0] || fu.idx[1] !== u_i1[11:0] || fu.idx[2] !== u_i2[11:0] ||
            fu.offs[0] !== u_o0 || fu.offs[1] !== u_o1 || fu.offs[2] !== u_o2) begin
          $fatal(1, "SHADOWED=0 final done state mismatch");
        end
        cu.enable = 1'b0;
        u_clr     = 1'b1;
        tick();
        u_clr     = 1'b0;
        check_u_clear("u_phase2_done_clear");
        if (fs.valid) check_s_result();
        u_phase = 3;
      end
    end

    if (s_phase != 4 || s_events != total_steps)
      $fatal(1, "SHADOWED=1 timeout: s_phase=%0d s_events=%0d/%0d cycles=%0d", s_phase, s_events, total_steps, cycles);
    if (u_phase != 3 || u_events != total_steps)
      $fatal(1, "SHADOWED=0 timeout: u_phase=%0d u_events=%0d/%0d cycles=%0d", u_phase, u_events, total_steps, cycles);

    $display("PASS seed=%0d s_events=%0d u_events=%0d cycles=%0d", seed, s_events, u_events, cycles);
    $finish;
  end

endmodule
