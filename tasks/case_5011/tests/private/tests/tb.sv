`timescale 1ns/1ps
module tb;
  import ariane_pkg::*;

  logic        clk_i = 0;
  logic        rst_ni = 0;
  logic        flush_i = 0;
  logic [31:0] fe_addr_i = 0;
  logic [31:0] fe_instr_i = 0;
  logic        fe_bp_valid_i = 0;
  logic [31:0] fe_bp_addr_i = 0;
  logic [ 2:0] fe_bp_cf_i = 0;
  logic        fe_ex_valid_i = 0;
  logic [31:0] fe_ex_cause_i = 0;
  logic        fe_valid_i = 0;
  logic        fe_ready_o;
  logic        issue_ack_i = 0;
  logic        issue_valid_o;
  logic [31:0] issue_pc_o;
  logic [ 3:0] issue_fu_o;
  logic [ 7:0] issue_op_o;
  logic [ 4:0] issue_rs1_o;
  logic [ 4:0] issue_rs2_o;
  logic [ 4:0] issue_rd_o;
  logic [31:0] issue_result_o;
  logic        issue_ex_valid_o;
  logic        issue_is_comp_o;
  logic        issue_is_macro_o;
  logic        issue_is_last_macro_o;
  logic        issue_is_double_rd_o;
  logic        issue_is_zcmt_o;
  logic        is_ctrl_flow_o;
  logic [25:0] jvt_base_i = 26'h0001000;
  logic [ 5:0] jvt_mode_i = 6'h0;
  logic        dcache_gnt_i = 0;
  logic        dcache_rvalid_i = 0;
  logic [31:0] dcache_rdata_i = 0;
  logic        dcache_req_o;
  logic [ 9:0] dcache_idx_o;
  logic [21:0] dcache_tag_o;
  logic        dcache_kill_o;

  always #5 clk_i = ~clk_i;

  id_decode_top dut (.*);

  int seed = 101;
  int fail_cnt = 0;

  task automatic fail(input string msg);
    $display("FAIL: %s (t=%0t)", msg, $time);
    fail_cnt++;
  endtask

  task automatic step();
    @(posedge clk_i);
    #1;
  endtask

  initial begin
    void'($value$plusargs("seed=%d", seed));
    rst_ni = 0;
    flush_i = 0;
    fe_valid_i = 0;
    fe_addr_i = 32'h8000_0000;
    fe_instr_i = 32'h0000_0013;
    issue_ack_i = 0;
    dcache_gnt_i = 1;
    dcache_rvalid_i = 0;
    dcache_rdata_i = 0;

    repeat (4) step();
    rst_ni = 1;
    step();

    // -----------------------------------------------------------------------
    // T1: Invalid fetch entry (`fe_valid_i = 0`) holding stale ZCMT / ZCMP
    //     encodings while `issue_ack_i = 1` must NOT trigger `dcache_req_o`
    //     or advance macro_decoder out of IDLE.
    // -----------------------------------------------------------------------
    fe_valid_i  = 0;
    fe_instr_i  = 32'h0000_a082; // cm.jalt 32
    issue_ack_i = 1;
    #1;
    if (dcache_req_o !== 1'b0) fail("T1a: spurious dcache_req_o when fe_valid_i=0 on Zcmt encoding");
    step();
    fe_instr_i  = 32'h0000_aca2; // cm.mvsa01 s1, s0
    issue_ack_i = 1;
    step();
    issue_ack_i = 0;

    // -----------------------------------------------------------------------
    // T2: `cm.mvsa01 s1, s0` (`16'haca2`) starting from empty issue_q (`issue_valid_o=0`)
    //     Should emit exactly 2 micro-ops:
    //       uop0: addi x9, x10, 0 (macro=1, last=0, double_rd=1)
    //       uop1: addi x8, x11, 0 (macro=1, last=1, double_rd=1)
    // -----------------------------------------------------------------------
    fe_valid_i  = 1;
    fe_addr_i   = 32'h8000_0100 + ((seed & 8'hFF) << 2);
    fe_instr_i  = 32'h0000_aca2;
    issue_ack_i = 0;
    #1;
    if (fe_ready_o !== 1'b0) fail("T2a: fe_ready_o must be 0 on first cycle of cm.mvsa01");
    step(); // uop0 latched into issue_q
    if (issue_valid_o !== 1'b1 || issue_rs1_o !== 5'd10 || issue_rd_o !== 5'd9 ||
        issue_result_o !== 32'h0 || issue_is_macro_o !== 1'b1 ||
        issue_is_last_macro_o !== 1'b0 || issue_is_double_rd_o !== 1'b1) begin
      fail($sformatf("T2b: uop0 mismatch vld=%b rs1=%0d rd=%0d imm=%h macro=%b last=%b dbl=%b",
        issue_valid_o, issue_rs1_o, issue_rd_o, issue_result_o, issue_is_macro_o, issue_is_last_macro_o, issue_is_double_rd_o));
    end
    // Hold issue_ack_i = 0 for 1 stall cycle: uop0 must stay in issue_q, fe_ready_o must stay 0
    if (fe_ready_o !== 1'b0) fail("T2c: fe_ready_o must stay 0 while issue_ack_i=0 in MOVE");
    step();
    if (issue_valid_o !== 1'b1 || issue_rd_o !== 5'd9 || issue_is_last_macro_o !== 1'b0) begin
      fail("T2d: uop0 did not hold under issue_ack_i=0 backpressure");
    end
    // Now assert issue_ack_i = 1 to consume uop0 and latch uop1 into issue_q; fe_ready_o must assert 1!
    issue_ack_i = 1;
    #1;
    if (fe_ready_o !== 1'b1) fail("T2e: fe_ready_o must assert 1 when last micro-op of cm.mvsa01 is accepted");
    step();
    fe_valid_i  = 0;
    fe_instr_i  = 32'h0000_0013;
    issue_ack_i = 0;
    #1;
    if (issue_valid_o !== 1'b1 || issue_rs1_o !== 5'd11 || issue_rd_o !== 5'd8 ||
        issue_result_o !== 32'h0 || issue_is_macro_o !== 1'b1 ||
        issue_is_last_macro_o !== 1'b1 || issue_is_double_rd_o !== 1'b1) begin
      fail($sformatf("T2f: uop1 mismatch vld=%b rs1=%0d rd=%0d imm=%h macro=%b last=%b dbl=%b",
        issue_valid_o, issue_rs1_o, issue_rd_o, issue_result_o, issue_is_macro_o, issue_is_last_macro_o, issue_is_double_rd_o));
    end
    issue_ack_i = 1;
    step();
    issue_ack_i = 0;
    if (issue_valid_o !== 1'b0) fail("T2g: issue_valid_o must clear after uop1 ack");

    // -----------------------------------------------------------------------
    // T3: `cm.mva01s s2, s3` (`16'ha96e`: OpC2=2'b10, [15:10]=6'b101011,
    //     r1s=3'b010 (x18), [6:5]=2'b11, r2s=3'b011 (x19))
    //     Should emit:
    //       uop0: addi x10, x18, 0 (macro=1, last=0, double_rd=1)
    //       uop1: addi x11, x19, 0 (macro=1, last=1, double_rd=1)
    // -----------------------------------------------------------------------
    fe_valid_i  = 1;
    fe_addr_i   = 32'h8000_0200;
    fe_instr_i  = 32'h0000_ad6e;
    issue_ack_i = 0;
    step(); // latches uop0
    if (issue_valid_o !== 1'b1 || issue_rs1_o !== 5'd18 || issue_rd_o !== 5'd10 ||
        issue_is_macro_o !== 1'b1 || issue_is_last_macro_o !== 1'b0 || issue_is_double_rd_o !== 1'b1) begin
      fail($sformatf("T3a: cm.mva01s uop0 mismatch rs1=%0d rd=%0d", issue_rs1_o, issue_rd_o));
    end
    issue_ack_i = 1;
    #1;
    if (fe_ready_o !== 1'b1) fail("T3b: cm.mva01s fe_ready_o must be 1 on uop1 acceptance");
    step();
    fe_valid_i  = 0;
    issue_ack_i = 1;
    if (issue_valid_o !== 1'b1 || issue_rs1_o !== 5'd19 || issue_rd_o !== 5'd11 ||
        issue_is_macro_o !== 1'b1 || issue_is_last_macro_o !== 1'b1 || issue_is_double_rd_o !== 1'b1) begin
      fail($sformatf("T3c: cm.mva01s uop1 mismatch rs1=%0d rd=%0d last=%b", issue_rs1_o, issue_rd_o, issue_is_last_macro_o));
    end
    step();
    issue_ack_i = 0;

    // -----------------------------------------------------------------------
    // T4: `cm.push {ra, s0-s2}, -32` (`16'hb876`: [15:8]=8'b10111000,
    //     rlist=4'b0111 (4 regs: x18, x9, x8, x1), spimm=2'b01 (stack_adj=32))
    //     With intermittent backpressure (`issue_ack_i = 0` on odd cycles):
    //       uop0: sw x18, -4(x2)  (imm=32'hFFFF_FFFC, last=0)
    //       uop1: sw x9,  -8(x2)  (imm=32'hFFFF_FFF8, last=0)
    //       uop2: sw x8,  -12(x2) (imm=32'hFFFF_FFF4, last=0)
    //       uop3: sw x1,  -16(x2) (imm=32'hFFFF_FFF0, last=0)
    //       uop4: addi x2, x2, -32 (imm=32'hFFFF_FFE0, last=1)
    // -----------------------------------------------------------------------
    begin
      automatic int exp_rs2[4] = '{18, 9, 8, 1};
      automatic logic [31:0] exp_off[4] = '{32'hFFFF_FFFC, 32'hFFFF_FFF8, 32'hFFFF_FFF4, 32'hFFFF_FFF0};
      fe_valid_i  = 1;
      fe_addr_i   = 32'h8000_0300;
      fe_instr_i  = 32'h0000_b876;
      issue_ack_i = 0;
      step(); // uop0 latched into issue_q
      for (int k = 0; k < 4; k++) begin
        if (issue_valid_o !== 1'b1 || issue_fu_o !== STORE || issue_rs1_o !== 5'd2 ||
            issue_rs2_o !== 5'(exp_rs2[k]) || issue_result_o !== exp_off[k] ||
            issue_is_macro_o !== 1'b1 || issue_is_last_macro_o !== 1'b0) begin
          fail($sformatf("T4_store[%0d]: vld=%b fu=%0d rs1=%0d rs2=%0d imm=%h last=%b",
            k, issue_valid_o, issue_fu_o, issue_rs1_o, issue_rs2_o, issue_result_o, issue_is_last_macro_o));
        end
        // 1 cycle stall with issue_ack_i = 0
        issue_ack_i = 0;
        #1;
        if (fe_ready_o !== 1'b0) fail($sformatf("T4_stall[%0d]: fe_ready_o should be 0", k));
        step();
        if (issue_rs2_o !== 5'(exp_rs2[k]) || issue_result_o !== exp_off[k]) begin
          fail($sformatf("T4_hold[%0d]: store uop mutated during stall", k));
        end
        // Acknowledge uop[k] -> latches uop[k+1]
        issue_ack_i = 1;
        #1;
        if (k < 3 && fe_ready_o !== 1'b0) fail($sformatf("T4_rdy[%0d]: fe_ready_o asserted early", k));
        if (k == 3 && fe_ready_o !== 1'b1) fail("T4_rdy[3]: fe_ready_o should assert when PUSH_ADDI is accepted");
        step();
      end
      fe_valid_i  = 0;
      issue_ack_i = 1;
      if (issue_valid_o !== 1'b1 || issue_rs1_o !== 5'd2 || issue_rd_o !== 5'd2 ||
          issue_result_o !== 32'hFFFF_FFE0 || issue_is_macro_o !== 1'b1 || issue_is_last_macro_o !== 1'b1) begin
        fail($sformatf("T4_addi: vld=%b rs1=%0d rd=%0d imm=%h last=%b",
          issue_valid_o, issue_rs1_o, issue_rd_o, issue_result_o, issue_is_last_macro_o));
      end
      step();
      issue_ack_i = 0;
    end

    // -----------------------------------------------------------------------
    // T5: Mid-expansion `flush_i` during 12-register `cm.push {ra, s0-s11}, -64`
    //     (`16'hb8f2`: rlist=15 -> 12 regs, spimm=0 -> stack_adj=64), followed
    //     immediately by `cm.popretz {ra, s0}, +16` (`16'hbc52`: [15:8]=8'b10111100,
    //     rlist=5 -> 2 regs: x8, x1, spimm=0 -> stack_adj=16).
    // -----------------------------------------------------------------------
    fe_valid_i  = 1;
    fe_addr_i   = 32'h8000_0400;
    fe_instr_i  = 32'h0000_b8f2;
    issue_ack_i = 0;
    step(); // uop0 (sw x27, -4(sp)) latched, macro_decoder enters PUSH_POP_INSTR_2
    if (issue_valid_o !== 1'b1 || issue_rs2_o !== 5'd27 || issue_result_o !== 32'hFFFF_FFFC) begin
      fail($sformatf("T5a: rlist=15 uop0 mismatch rs2=%0d imm=%h", issue_rs2_o, issue_result_o));
    end
    issue_ack_i = 1;
    step(); // uop1 (sw x26, -8(sp)) latched, macro_decoder enters INIT
    if (issue_valid_o !== 1'b1 || issue_rs2_o !== 5'd26 || issue_result_o !== 32'hFFFF_FFF8) begin
      fail($sformatf("T5b: rlist=15 uop1 mismatch rs2=%0d imm=%h", issue_rs2_o, issue_result_o));
    end
    // Now assert flush_i = 1 while macro_decoder is mid-sequence in INIT!
    flush_i     = 1;
    issue_ack_i = 0;
    #1;
    if (fe_ready_o !== 1'b0) fail("T5c: fe_ready_o must be 0 when flush_i=1");
    step();
    flush_i    = 0;
    fe_valid_i = 0;
    if (issue_valid_o !== 1'b0) fail("T5d: issue_valid_o must be 0 after flush_i");
    step();

    // Now feed `cm.popretz {ra, s0}, +16` (`16'hbc52`):
    //   uop0: lw x8, 12(x2)
    //   uop1: lw x1, 8(x2)
    //   uop2: lui x10, 0
    //   uop3: addi x10, x10, 0
    //   uop4: addi x2, x2, 16
    //   uop5: jalr x0, x1, 0 (last=1, is_ctrl_flow=1)
    fe_valid_i  = 1;
    fe_addr_i   = 32'h8000_0500;
    fe_instr_i  = 32'h0000_bc52;
    issue_ack_i = 1;
    step(); // uop0: lw x8, 12(x2)
    if (issue_valid_o !== 1'b1 || issue_fu_o !== LOAD || issue_rs1_o !== 5'd2 ||
        issue_rd_o !== 5'd8 || issue_result_o !== 32'd12 || issue_is_last_macro_o !== 1'b0) begin
      fail($sformatf("T5e: popretz uop0 mismatch fu=%0d rd=%0d imm=%0d", issue_fu_o, issue_rd_o, issue_result_o));
    end
    step(); // uop1: lw x1, 8(x2)
    if (issue_valid_o !== 1'b1 || issue_fu_o !== LOAD || issue_rs1_o !== 5'd2 ||
        issue_rd_o !== 5'd1 || issue_result_o !== 32'd8 || issue_is_last_macro_o !== 1'b0) begin
      fail($sformatf("T5f: popretz uop1 mismatch fu=%0d rd=%0d imm=%0d", issue_fu_o, issue_rd_o, issue_result_o));
    end
    step(); // uop2: lui x10, 0
    if (issue_valid_o !== 1'b1 || issue_rd_o !== 5'd10 || issue_result_o !== 32'd0 || issue_is_last_macro_o !== 1'b0) begin
      fail($sformatf("T5g: popretz uop2 (lui a0,0) mismatch rd=%0d imm=%0d", issue_rd_o, issue_result_o));
    end
    step(); // uop3: addi x10, x10, 0
    if (issue_valid_o !== 1'b1 || issue_rs1_o !== 5'd10 || issue_rd_o !== 5'd10 || issue_result_o !== 32'd0 || issue_is_last_macro_o !== 1'b0) begin
      fail($sformatf("T5h: popretz uop3 (addi a0,a0,0) mismatch rs1=%0d rd=%0d", issue_rs1_o, issue_rd_o));
    end
    #1;
    if (fe_ready_o !== 1'b0) fail("T5i: fe_ready_o must still be 0 during PUSH_ADDI of popretz");
    step(); // uop4: addi x2, x2, 16
    if (issue_valid_o !== 1'b1 || issue_rs1_o !== 5'd2 || issue_rd_o !== 5'd2 || issue_result_o !== 32'd16 || issue_is_last_macro_o !== 1'b0) begin
      fail($sformatf("T5j: popretz uop4 (addi sp,sp,16) mismatch rs1=%0d rd=%0d imm=%0d last=%b",
        issue_rs1_o, issue_rd_o, issue_result_o, issue_is_last_macro_o));
    end
    #1;
    if (fe_ready_o !== 1'b1) fail("T5k: fe_ready_o must assert 1 when final ret of popretz is accepted");
    step(); // uop5: jalr x0, x1, 0
    fe_valid_i  = 0;
    if (issue_valid_o !== 1'b1 || issue_rs1_o !== 5'd1 || issue_rd_o !== 5'd0 ||
        issue_is_macro_o !== 1'b1 || issue_is_last_macro_o !== 1'b1 || is_ctrl_flow_o !== 1'b1) begin
      fail($sformatf("T5l: popretz uop5 (ret) mismatch rs1=%0d rd=%0d last=%b cf=%b",
        issue_rs1_o, issue_rd_o, issue_is_last_macro_o, is_ctrl_flow_o));
    end
    step();
    issue_ack_i = 0;

    // -----------------------------------------------------------------------
    // T6: Zcmt `cm.jalt 40` (`16'ha0a2`: index=40 >= 32 -> rd=x1) with multi-cycle
    //     D-Cache latency (`dcache_rvalid_i = 0` for 2 cycles in TABLE_JUMP),
    //     followed by `cm.jt 12` (`16'ha032`: index=12 < 32 -> rd=x0) killed mid-lookup
    //     by `flush_i = 1`!
    // -----------------------------------------------------------------------
    jvt_base_i      = 26'h0002_005; // base << 6 = 32'h0008_0140
    fe_valid_i      = 1;
    fe_addr_i       = 32'h8000_1000;
    fe_instr_i      = 32'h0000_a0a2; // index = 40 -> + 160 (0xA0) -> table_addr = 32'h0008_01E0
    dcache_rvalid_i = 0;
    issue_ack_i     = 0;
    #1;
    if (dcache_req_o !== 1'b1 || {dcache_tag_o, dcache_idx_o} !== 32'h0008_01E0 || fe_ready_o !== 1'b0) begin
      fail($sformatf("T6a: cm.jalt IDLE req=%b addr=%h rdy=%b", dcache_req_o, {dcache_tag_o, dcache_idx_o}, fe_ready_o));
    end
    step(); // now in TABLE_JUMP, dcache_rvalid_i = 0
    if (issue_valid_o !== 1'b0 || fe_ready_o !== 1'b0 || dcache_req_o !== 1'b0) begin
      fail($sformatf("T6b: cm.jalt TABLE_JUMP wait0 vld=%b rdy=%b req=%b", issue_valid_o, fe_ready_o, dcache_req_o));
    end
    step(); // 2nd wait cycle in TABLE_JUMP with dcache_rvalid_i = 0
    if (issue_valid_o !== 1'b0 || fe_ready_o !== 1'b0) begin
      fail($sformatf("T6c: cm.jalt TABLE_JUMP wait1 vld=%b rdy=%b", issue_valid_o, fe_ready_o));
    end
    // Now return D-Cache data with bit 0 set (`32'h8000_2469` -> target `32'h8000_2468`, offset = `32'h0000_1468`)
    dcache_rvalid_i = 1;
    dcache_rdata_i  = 32'h8000_2469;
    #1;
    if (fe_ready_o !== 1'b1) fail("T6d: fe_ready_o must assert 1 when dcache_rvalid_i=1 in TABLE_JUMP");
    step();
    dcache_rvalid_i = 0;
    fe_valid_i      = 0;
    if (issue_valid_o !== 1'b1 || issue_rd_o !== 5'd1 || issue_result_o !== 32'h0000_1468 ||
        issue_is_zcmt_o !== 1'b1 || is_ctrl_flow_o !== 1'b1) begin
      fail($sformatf("T6e: cm.jalt issue mismatch vld=%b rd=%0d res=%h zcmt=%b cf=%b",
        issue_valid_o, issue_rd_o, issue_result_o, issue_is_zcmt_o, is_ctrl_flow_o));
    end
    issue_ack_i = 1;
    step();
    issue_ack_i = 0;

    // Now start `cm.jt 12` (`16'ha032`), enter TABLE_JUMP, and assert `flush_i = 1` before `dcache_rvalid_i`!
    fe_valid_i      = 1;
    fe_addr_i       = 32'h8000_2000;
    fe_instr_i      = 32'h0000_a032; // index = 12 -> + 48 (0x30) -> table_addr = 32'h0008_0170
    dcache_rvalid_i = 0;
    #1;
    if (dcache_req_o !== 1'b1 || {dcache_tag_o, dcache_idx_o} !== 32'h0008_0170) begin
      fail("T6f: cm.jt IDLE request mismatch");
    end
    step(); // now in TABLE_JUMP
    flush_i = 1;
    #1;
    if (dcache_kill_o !== 1'b1 || fe_ready_o !== 1'b0) begin
      fail($sformatf("T6g: flush_i in TABLE_JUMP must assert dcache_kill_o=1 and fe_ready_o=0 (got kill=%b rdy=%b)",
        dcache_kill_o, fe_ready_o));
    end
    step();
    flush_i    = 0;
    fe_valid_i = 1;
    fe_addr_i  = 32'h8000_3000;
    fe_instr_i = 32'h0050_0113; // addi x2, x0, 5 (normal 32-bit instruction after flush)
    #1;
    if (fe_ready_o !== 1'b1) fail("T6h: post-flush normal instruction must see fe_ready_o=1 immediately");
    step();
    fe_valid_i = 0;
    if (issue_valid_o !== 1'b1 || issue_rd_o !== 5'd2 || issue_result_o !== 32'd5 || issue_is_zcmt_o !== 1'b0) begin
      fail("T6i: post-flush normal instruction failed to decode cleanly");
    end

    if (fail_cnt == 0) begin
      $display("PASS: all ID/Zcmp/Zcmt checks passed (seed=%0d)", seed);
      $finish;
    end else begin
      $display("FAIL: %0d checks failed", fail_cnt);
      $fatal(1, "tb failed");
    end
  end
endmodule
