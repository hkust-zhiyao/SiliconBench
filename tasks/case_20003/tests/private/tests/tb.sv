`timescale 1ns/1ps
`include "biriscv_defs.v"

module tb;
    reg clk;
    reg rst;
    int seed;

    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end

    // =====================================================================
    // Part A: Direct unit harness on biriscv_npc (GSHARE=1, BHT=1 vs BHT=0)
    // =====================================================================
    reg         u_inv, u_breq, u_btaken, u_bntaken, u_bcall, u_bret, u_bjmp, u_pc_acc;
    reg  [31:0] u_bsrc, u_bpc, u_pc_f;
    wire [31:0] u_next_pc_gsh, u_next_pc_nobht;
    wire [ 1:0] u_next_tkn_gsh, u_next_tkn_nobht;

    biriscv_npc #(
        .SUPPORT_BRANCH_PREDICTION(1),
        .NUM_BTB_ENTRIES(16), .NUM_BTB_ENTRIES_W(4),
        .NUM_BHT_ENTRIES(64), .NUM_BHT_ENTRIES_W(6),
        .RAS_ENABLE(1), .GSHARE_ENABLE(1), .BHT_ENABLE(1),
        .NUM_RAS_ENTRIES(8), .NUM_RAS_ENTRIES_W(3)
    ) u_npc_gsh (
        .clk_i(clk), .rst_i(rst), .invalidate_i(u_inv),
        .branch_request_i(u_breq), .branch_is_taken_i(u_btaken), .branch_is_not_taken_i(u_bntaken),
        .branch_source_i(u_bsrc), .branch_is_call_i(u_bcall), .branch_is_ret_i(u_bret), .branch_is_jmp_i(u_bjmp),
        .branch_pc_i(u_bpc), .pc_f_i(u_pc_f), .pc_accept_i(u_pc_acc),
        .next_pc_f_o(u_next_pc_gsh), .next_taken_f_o(u_next_tkn_gsh)
    );

    biriscv_npc #(
        .SUPPORT_BRANCH_PREDICTION(1),
        .NUM_BTB_ENTRIES(16), .NUM_BTB_ENTRIES_W(4),
        .NUM_BHT_ENTRIES(64), .NUM_BHT_ENTRIES_W(6),
        .RAS_ENABLE(1), .GSHARE_ENABLE(0), .BHT_ENABLE(0),
        .NUM_RAS_ENTRIES(8), .NUM_RAS_ENTRIES_W(3)
    ) u_npc_nobht (
        .clk_i(clk), .rst_i(rst), .invalidate_i(u_inv),
        .branch_request_i(u_breq), .branch_is_taken_i(u_btaken), .branch_is_not_taken_i(u_bntaken),
        .branch_source_i(u_bsrc), .branch_is_call_i(u_bcall), .branch_is_ret_i(u_bret), .branch_is_jmp_i(u_bjmp),
        .branch_pc_i(u_bpc), .pc_f_i(u_pc_f), .pc_accept_i(u_pc_acc),
        .next_pc_f_o(u_next_pc_nobht), .next_taken_f_o(u_next_tkn_nobht)
    );

    // =====================================================================
    // Part B: Direct unit harness on biriscv_fetch (SUPPORT_MMU=1 and 0)
    // =====================================================================
    reg         f_acc, ic_acc, ic_val, ic_err, ic_pf, f_inv, f_breq;
    reg  [63:0] ic_inst;
    reg  [31:0] f_bpc, f_npc;
    reg  [ 1:0] f_bpriv, f_ntkn;

    wire        m1_fval, m1_fferr, m1_ffpf, m1_ic_rd, m1_ic_fl, m1_ic_inv, m1_pc_acc;
    wire [63:0] m1_finstr;
    wire [ 1:0] m1_fpred, m1_ic_priv;
    wire [31:0] m1_fpc, m1_ic_pc, m1_pc_f;

    wire        m0_fval, m0_fferr, m0_ffpf, m0_ic_rd, m0_ic_fl, m0_ic_inv, m0_pc_acc;
    wire [63:0] m0_finstr;
    wire [ 1:0] m0_fpred, m0_ic_priv;
    wire [31:0] m0_fpc, m0_ic_pc, m0_pc_f;

    biriscv_fetch #(.SUPPORT_MMU(1)) u_fetch_mmu1 (
        .clk_i(clk), .rst_i(rst),
        .fetch_accept_i(f_acc), .icache_accept_i(ic_acc), .icache_valid_i(ic_val),
        .icache_error_i(ic_err), .icache_inst_i(ic_inst), .icache_page_fault_i(ic_pf),
        .fetch_invalidate_i(f_inv), .branch_request_i(f_breq), .branch_pc_i(f_bpc), .branch_priv_i(f_bpriv),
        .next_pc_f_i(f_npc), .next_taken_f_i(f_ntkn),
        .fetch_valid_o(m1_fval), .fetch_instr_o(m1_finstr), .fetch_pred_branch_o(m1_fpred),
        .fetch_fault_fetch_o(m1_fferr), .fetch_fault_page_o(m1_ffpf), .fetch_pc_o(m1_fpc),
        .icache_rd_o(m1_ic_rd), .icache_flush_o(m1_ic_fl), .icache_invalidate_o(m1_ic_inv),
        .icache_pc_o(m1_ic_pc), .icache_priv_o(m1_ic_priv), .pc_f_o(m1_pc_f), .pc_accept_o(m1_pc_acc)
    );

    biriscv_fetch #(.SUPPORT_MMU(0)) u_fetch_mmu0 (
        .clk_i(clk), .rst_i(rst),
        .fetch_accept_i(f_acc), .icache_accept_i(ic_acc), .icache_valid_i(ic_val),
        .icache_error_i(ic_err), .icache_inst_i(ic_inst), .icache_page_fault_i(ic_pf),
        .fetch_invalidate_i(f_inv), .branch_request_i(f_breq), .branch_pc_i(f_bpc), .branch_priv_i(f_bpriv),
        .next_pc_f_i(f_npc), .next_taken_f_i(f_ntkn),
        .fetch_valid_o(m0_fval), .fetch_instr_o(m0_finstr), .fetch_pred_branch_o(m0_fpred),
        .fetch_fault_fetch_o(m0_fferr), .fetch_fault_page_o(m0_ffpf), .fetch_pc_o(m0_fpc),
        .icache_rd_o(m0_ic_rd), .icache_flush_o(m0_ic_fl), .icache_invalidate_o(m0_ic_inv),
        .icache_pc_o(m0_ic_pc), .icache_priv_o(m0_ic_priv), .pc_f_o(m0_pc_f), .pc_accept_o(m0_pc_acc)
    );

    // =====================================================================
    // Part C: Full end-to-end biriscv_frontend integration harness
    // =====================================================================
    reg         fe_ic_acc, fe_ic_val, fe_ic_err, fe_ic_pf;
    reg  [63:0] fe_ic_inst;
    reg         fe_f0_acc, fe_f1_acc, fe_finv;
    reg         fe_breq, fe_bi_req, fe_bi_tkn, fe_bi_ntkn, fe_bi_call, fe_bi_ret, fe_bi_jmp;
    reg  [31:0] fe_bpc, fe_bi_src, fe_bi_pc;
    reg  [ 1:0] fe_bpriv;

    wire        fe_ic_rd, fe_ic_fl, fe_ic_inv;
    wire [31:0] fe_ic_pc;
    wire [ 1:0] fe_ic_priv;
    wire        fe_f0_val, fe_f1_val;
    wire [31:0] fe_f0_ins, fe_f1_ins, fe_f0_pc, fe_f1_pc;

    biriscv_frontend #(
        .SUPPORT_BRANCH_PREDICTION(1),
        .SUPPORT_MULDIV(1),
        .SUPPORT_MMU(1),
        .EXTRA_DECODE_STAGE(0),
        .NUM_BTB_ENTRIES(32), .NUM_BTB_ENTRIES_W(5),
        .NUM_BHT_ENTRIES(64), .NUM_BHT_ENTRIES_W(6),
        .RAS_ENABLE(1), .GSHARE_ENABLE(1), .BHT_ENABLE(1),
        .NUM_RAS_ENTRIES(8), .NUM_RAS_ENTRIES_W(3)
    ) u_fe (
        .clk_i(clk), .rst_i(rst),
        .icache_accept_i(fe_ic_acc), .icache_valid_i(fe_ic_val), .icache_error_i(fe_ic_err),
        .icache_inst_i(fe_ic_inst), .icache_page_fault_i(fe_ic_pf),
        .fetch0_accept_i(fe_f0_acc), .fetch1_accept_i(fe_f1_acc),
        .fetch_invalidate_i(fe_finv),
        .branch_request_i(fe_breq), .branch_pc_i(fe_bpc), .branch_priv_i(fe_bpriv),
        .branch_info_request_i(fe_bi_req), .branch_info_is_taken_i(fe_bi_tkn),
        .branch_info_is_not_taken_i(fe_bi_ntkn), .branch_info_source_i(fe_bi_src),
        .branch_info_is_call_i(fe_bi_call), .branch_info_is_ret_i(fe_bi_ret),
        .branch_info_is_jmp_i(fe_bi_jmp), .branch_info_pc_i(fe_bi_pc),
        .icache_rd_o(fe_ic_rd), .icache_flush_o(fe_ic_fl), .icache_invalidate_o(fe_ic_inv),
        .icache_pc_o(fe_ic_pc), .icache_priv_o(fe_ic_priv),
        .fetch0_valid_o(fe_f0_val), .fetch0_instr_o(fe_f0_ins), .fetch0_pc_o(fe_f0_pc),
        .fetch0_fault_fetch_o(), .fetch0_fault_page_o(),
        .fetch0_instr_exec_o(), .fetch0_instr_lsu_o(), .fetch0_instr_branch_o(),
        .fetch0_instr_mul_o(), .fetch0_instr_div_o(), .fetch0_instr_csr_o(),
        .fetch0_instr_rd_valid_o(), .fetch0_instr_invalid_o(),
        .fetch1_valid_o(fe_f1_val), .fetch1_instr_o(fe_f1_ins), .fetch1_pc_o(fe_f1_pc),
        .fetch1_fault_fetch_o(), .fetch1_fault_page_o(),
        .fetch1_instr_exec_o(), .fetch1_instr_lsu_o(), .fetch1_instr_branch_o(),
        .fetch1_instr_mul_o(), .fetch1_instr_div_o(), .fetch1_instr_csr_o(),
        .fetch1_instr_rd_valid_o(), .fetch1_instr_invalid_o()
    );

    task automatic clear_all();
        u_inv = 0; u_breq = 0; u_btaken = 0; u_bntaken = 0;
        u_bcall = 0; u_bret = 0; u_bjmp = 0; u_pc_acc = 0;
        u_bsrc = 0; u_bpc = 0; u_pc_f = 32'h8000_0000;

        f_acc = 1; ic_acc = 1; ic_val = 0; ic_err = 0; ic_pf = 0;
        f_inv = 0; f_breq = 0; ic_inst = 64'h0; f_bpc = 0;
        f_npc = 32'h0; f_bpriv = `PRIV_MACHINE; f_ntkn = 2'b00;

        fe_ic_acc = 1; fe_ic_val = 0; fe_ic_err = 0; fe_ic_pf = 0;
        fe_ic_inst = 64'h0; fe_f0_acc = 0; fe_f1_acc = 0; fe_finv = 0;
        fe_breq = 0; fe_bi_req = 0; fe_bi_tkn = 0; fe_bi_ntkn = 0;
        fe_bi_call = 0; fe_bi_ret = 0; fe_bi_jmp = 0;
        fe_bpc = 0; fe_bi_src = 0; fe_bi_pc = 0; fe_bpriv = `PRIV_MACHINE;
    endtask

    task automatic do_reset();
        rst = 1;
        clear_all();
        @(posedge clk); #1;
        @(posedge clk); #1;
        rst = 0;
        #1;
    endtask

    // Warm up the 16-bit right-shift LFSR (0x0001 -> 0xB400 >> 10) using high-address dummy jmps
    // so subsequent BTB allocations distribute across distinct entries even with stock biriscv_npc_lfsr.
    task automatic warmup_lfsr();
        for (int k = 0; k < 11; k++) begin
            u_breq = 1; u_btaken = 1; u_bjmp = 1;
            u_bsrc = 32'hF800_0000 + (k * 32'd8);
            u_bpc  = 32'hF900_0000 + (k * 32'd8);
            fe_bi_req = 1; fe_bi_tkn = 1; fe_bi_jmp = 1;
            fe_bi_src = 32'hF800_0000 + (k * 32'd8);
            fe_bi_pc  = 32'hF900_0000 + (k * 32'd8);
            @(posedge clk); #1;
        end
        clear_all();
    endtask

    initial begin
        if (!$value$plusargs("seed=%d", seed)) seed = 101;
        do_reset();

        // -----------------------------------------------------------------
        // Test 1: Cold RAS push (when ras_stack_q holds RAS_INVALID=32'h1!)
        //         + JALR call (btb_is_call=1, btb_is_jmp=0, even with BHT_ENABLE=0!)
        //         + Upper-slot call push address ((pc|4)+4, NOT pc+4!) & next_taken_f_o == 2'b10
        // -----------------------------------------------------------------
        // 1a: Cold BTB false-hit check at 0x0: after reset, pc_f_i == 32'h0 MUST NOT hit BTB!
        u_pc_f = 32'h0000_0000; #1;
        if (u_next_tkn_gsh !== 2'b00 || u_next_pc_gsh !== 32'h0000_0008) begin
            $display("FAIL Test1a: False BTB hit at PC=0 after reset! tkn=%b npc=%h", u_next_tkn_gsh, u_next_pc_gsh);
            $finish(1);
        end
        warmup_lfsr();

        // 1b: Learn indirect JALR call at upper slot 0x1004 -> target 0x2000 (call=1, jmp=0!)
        //     and RET at lower slot 0x2008 -> target 0x1008 (ret=1, jmp=0)
        //     and indirect JALR call at lower slot 0x1010 -> target 0x2200 (call=1, jmp=0!)
        u_breq = 1; u_btaken = 1; u_bcall = 1; u_bjmp = 0; u_bsrc = 32'h1004; u_bpc = 32'h2000;
        @(posedge clk); #1; clear_all();
        u_breq = 1; u_btaken = 1; u_bret  = 1; u_bjmp = 0; u_bsrc = 32'h2008; u_bpc = 32'h1008;
        @(posedge clk); #1; clear_all();

        // Now fetch parcel 0x1000 (containing upper-slot JALR call at 0x1004)!
        u_pc_f = 32'h1000; u_pc_acc = 1; #1;
        if (u_next_pc_gsh !== 32'h2000 || u_next_tkn_gsh !== 2'b10 ||
            u_next_pc_nobht !== 32'h2000 || u_next_tkn_nobht !== 2'b10) begin
            $display("FAIL Test1b: Upper-slot JALR call prediction wrong: gsh=(%h,%b) nobht=(%h,%b)",
                     u_next_pc_gsh, u_next_tkn_gsh, u_next_pc_nobht, u_next_tkn_nobht);
            $finish(1);
        end
        @(posedge clk); #1; clear_all(); // Speculative RAS MUST have pushed 0x1004 + 4 = 0x1008!

        // Now fetch parcel 0x2008 (RET)! Must predict 0x1008 (NOT 0x1004 and NOT blocked by RAS_INVALID!)
        u_pc_f = 32'h2008; u_pc_acc = 1; #1;
        if (u_next_pc_gsh !== 32'h1008 || u_next_tkn_gsh !== 2'b01) begin
            $display("FAIL Test1c: Cold RAS failed to push 0x1008 on upper-slot call! got npc=%h tkn=%b",
                     u_next_pc_gsh, u_next_tkn_gsh);
            $finish(1);
        end
        @(posedge clk); #1; clear_all();

        // 1d: Lower-slot indirect JALR call (call=1, jmp=0) at 0x1010 -> 0x2200 must predict taken even with BHT_ENABLE=0!
        u_breq = 1; u_btaken = 1; u_bcall = 1; u_bjmp = 0; u_bsrc = 32'h1010; u_bpc = 32'h2200;
        @(posedge clk); #1; clear_all();
        u_pc_f = 32'h1010; u_pc_acc = 0; #1;
        if (u_next_pc_nobht !== 32'h2200 || u_next_tkn_nobht !== 2'b01) begin
            $display("FAIL Test1d: Lower-slot JALR call failed to predict taken with BHT_ENABLE=0! nobht=(%h,%b)",
                     u_next_pc_nobht, u_next_tkn_nobht);
            $finish(1);
        end

        // -----------------------------------------------------------------
        // Test 2: Nested RAS coherence across predicted outer CALL + wrong-path speculative RAS corruption
        //         + conditional-branch misprediction rollback + mispredicted inner CALL!
        // -----------------------------------------------------------------
        do_reset();
        warmup_lfsr();
        // Train outer CALL A (0x3000 -> 0x4000) and outer RET A (0x4020) and inner RET B (0x5010)
        u_breq = 1; u_btaken = 1; u_bcall = 1; u_bjmp = 1; u_bsrc = 32'h3000; u_bpc = 32'h4000;
        @(posedge clk); #1; clear_all();
        u_breq = 1; u_btaken = 1; u_bret  = 1; u_bjmp = 0; u_bsrc = 32'h4020; u_bpc = 32'h3004;
        @(posedge clk); #1; clear_all();
        u_breq = 1; u_btaken = 1; u_bret  = 1; u_bjmp = 0; u_bsrc = 32'h5010; u_bpc = 32'h4014;
        @(posedge clk); #1; clear_all();
        // Also train a bogus wrong-path CALL W (0x4008 -> 0x9000)
        u_breq = 1; u_btaken = 1; u_bcall = 1; u_bjmp = 1; u_bsrc = 32'h4008; u_bpc = 32'h9000;
        @(posedge clk); #1; clear_all();
        u_breq = 1; u_btaken = 1; u_bret  = 1; u_bjmp = 0; u_bsrc = 32'h9004; u_bpc = 32'h400C;
        @(posedge clk); #1; clear_all();

        // Step 2a: Speculatively fetch & predict outer CALL A at 0x3000 (pushes 0x3004)
        u_pc_f = 32'h3000; u_pc_acc = 1;
        @(posedge clk); #1; clear_all();
        // Outer CALL A resolves in E1 as CORRECTLY PREDICTED (branch_request_i = 0, branch_is_taken_i = 1, branch_is_call_i = 1)!
        u_breq = 0; u_btaken = 1; u_bcall = 1; u_bjmp = 1; u_bsrc = 32'h3000; u_bpc = 32'h4000;
        @(posedge clk); #1; clear_all();

        // Step 2b: Speculative fetch goes down wrong path: pops RET at 0x4020 AND pushes bogus CALL W at 0x4008 (overwriting slot [1] with 0x400C!)
        u_pc_f = 32'h4020; u_pc_acc = 1;
        @(posedge clk); #1; clear_all();
        u_pc_f = 32'h4008; u_pc_acc = 1;
        @(posedge clk); #1; clear_all();

        // Step 2c: Conditional branch at 0x4000 mispredicts (branch_request_i=1, call=0, ret=0, jmp=0 -> target 0x4010)!
        // MUST roll back BOTH ras_index_q AND ras_stack_q[1] back to 0x3004!
        u_breq = 1; u_btaken = 1; u_bcall = 0; u_bret = 0; u_bjmp = 0; u_bsrc = 32'h4000; u_bpc = 32'h4010;
        @(posedge clk); #1; clear_all();

        // Step 2d: Inner CALL B at 0x4010 (unseen before) mispredicts -> target 0x5000 (pushes 0x4014 at depth 2, preserving 0x3004 at depth 1!)
        u_breq = 1; u_btaken = 1; u_bcall = 1; u_bjmp = 1; u_bsrc = 32'h4010; u_bpc = 32'h5000;
        @(posedge clk); #1; clear_all();

        // Step 2e: Fetch inner RET B at 0x5010 -> MUST predict 0x4014!
        u_pc_f = 32'h5010; u_pc_acc = 1; #1;
        if (u_next_pc_gsh !== 32'h4014 || u_next_tkn_gsh !== 2'b01) begin
            $display("FAIL Test2e: Inner RET after mispredicted nested CALL wrong: got %h (expected 0x4014)", u_next_pc_gsh);
            $finish(1);
        end
        @(posedge clk); #1; clear_all();
        // Inner RET B resolves accurately
        u_breq = 0; u_btaken = 1; u_bret = 1; u_bsrc = 32'h5010; u_bpc = 32'h4014;
        @(posedge clk); #1; clear_all();

        // Step 2f: Fetch outer RET A at 0x4020 -> MUST predict 0x3004 (NOT overwritten 0x400C or RAS_INVALID)!
        u_pc_f = 32'h4020; u_pc_acc = 1; #1;
        if (u_next_pc_gsh !== 32'h3004 || u_next_tkn_gsh !== 2'b01) begin
            $display("FAIL Test2f: Outer RET corrupted by wrong-path RAS / missed real RAS update: got %h (expected 0x3004)", u_next_pc_gsh);
            $finish(1);
        end
        @(posedge clk); #1; clear_all();

        // -----------------------------------------------------------------
        // Test 3: Dual-parcel 64-bit BTB evaluation:
        //   3a) Lower slot (0x6000) is a conditional branch trained NOT-TAKEN, while upper slot (0x6004) is a taken JAL -> 0x7000!
        //   3b) Mid-parcel entry (pc_f_i == 0x6004, pc_f_i[2] == 1) when 0x6000 is trained TAKEN -> MUST ignore 0x6000 and evaluate ONLY 0x6004!
        //   3c) invalidate_i clears BTB entries!
        // -----------------------------------------------------------------
        do_reset();
        warmup_lfsr();
        // Allocate 0x6000 as conditional branch (target 0x6800) and 0x6004 as unconditional JAL -> 0x7000,
        // then train GShare BHT counter down to 0 (not-taken) at steady-state GHR=0!
        u_breq = 1; u_btaken = 1; u_bsrc = 32'h6000; u_bpc = 32'h6800;
        @(posedge clk); #1; clear_all();
        u_breq = 1; u_btaken = 1; u_bjmp = 1; u_bsrc = 32'h6004; u_bpc = 32'h7000;
        @(posedge clk); #1; clear_all();
        repeat (10) begin
            u_breq = 1; u_bntaken = 1; u_bsrc = 32'h6000; u_bpc = 32'h6004;
            @(posedge clk); #1; clear_all();
        end

        // 3a: Fetch aligned parcel 0x6000 -> Slot 0 (0x6000) predicts NOT taken, so Slot 1 (0x6004) MUST predict TAKEN -> 0x7000 (2'b10)!
        u_pc_f = 32'h6000; #1;
        if (u_next_pc_gsh !== 32'h7000 || u_next_tkn_gsh !== 2'b10) begin
            $display("FAIL Test3a: Skipped upper BTB entry when lower BTB conditional branch predicted not-taken! npc=%h tkn=%b",
                     u_next_pc_gsh, u_next_tkn_gsh);
            $finish(1);
        end

        // 3b: Now allocate unconditional jump at 0x6200 -> 0x6900, and fallthrough at 0x6204 (not in BTB).
        //     Enter parcel at mid-parcel PC = 0x6204 (pc_f_i[2] == 1)! MUST ignore Slot 0 (0x6200) and predict fallthrough 0x6208 (2'b00)!
        u_breq = 1; u_btaken = 1; u_bjmp = 1; u_bsrc = 32'h6200; u_bpc = 32'h6900;
        @(posedge clk); #1; clear_all();
        u_pc_f = 32'h6204; #1;
        if (u_next_pc_gsh !== 32'h6208 || u_next_tkn_gsh !== 2'b00) begin
            $display("FAIL Test3b: Mid-parcel fetch (pc[2]==1) falsely triggered Slot 0 BTB entry! npc=%h tkn=%b",
                     u_next_pc_gsh, u_next_tkn_gsh);
            $finish(1);
        end

        // 3c: Pulse invalidate_i -> BTB entries MUST clear!
        u_inv = 1; @(posedge clk); #1; clear_all();
        u_pc_f = 32'h6000; #1;
        if (u_next_pc_gsh !== 32'h6008 || u_next_tkn_gsh !== 2'b00) begin
            $display("FAIL Test3c: invalidate_i did not clear BTB! npc=%h tkn=%b", u_next_pc_gsh, u_next_tkn_gsh);
            $finish(1);
        end

        // -----------------------------------------------------------------
        // Test 4: biriscv_fetch unit protocol tests:
        //   4a) SUPPORT_MMU=1 privilege tracking, single fetch (no double-fetch / no dropped first target parcel!)
        //   4b) pc_accept_o strictly equals (icache_rd_o && icache_accept_i)
        //   4c) Multi-cycle skid retention across 3 cycles of fetch_accept_i==0 + immediate skid clear on branch_request_i
        //   4d) In-flight wrong-path ICache response dropped on redirect while subsequent target response is delivered
        //   4e) fetch_invalidate_i retained across icache_accept_i==0 until icache_flush_o handshakes
        // -----------------------------------------------------------------
        do_reset();
        // 4a: Redirect to 0x8000_0000 with PRIV_USER (2'd0)
        f_breq = 1; f_bpc = 32'h8000_0000; f_bpriv = `PRIV_USER; f_npc = 32'h8000_0008;
        #1;
        if (m1_ic_rd || m1_pc_acc || m1_fval) begin
            $display("FAIL Test4a_0: Asserted icache_rd / pc_accept / fetch_valid during branch_request_i!");
            $finish(1);
        end
        @(posedge clk); #1;
        f_breq = 0; f_npc = 32'h8000_0008;
        // Hold icache_accept_i = 0 for 1 cycle -> pc_accept_o MUST be 0!
        ic_acc = 0; #1;
        if (m1_pc_acc !== 1'b0 || m1_ic_priv !== `PRIV_USER || m0_ic_priv !== `PRIV_MACHINE) begin
            $display("FAIL Test4b: pc_accept_o=%b when icache_accept_i=0, or priv wrong m1=%b m0=%b",
                     m1_pc_acc, m1_ic_priv, m0_ic_priv);
            $finish(1);
        end
        @(posedge clk); #1;
        // Now icache_accept_i = 1 -> issues 0x8000_0000 ONCE!
        ic_acc = 1; #1;
        if (!m1_ic_rd || !m1_pc_acc || m1_ic_pc !== 32'h8000_0000) begin
            $display("FAIL Test4a_1: Expected post-redirect icache_rd at 0x8000_0000! rd=%b acc=%b pc=%h",
                     m1_ic_rd, m1_pc_acc, m1_ic_pc);
            $finish(1);
        end
        @(posedge clk); #1;
        // Next cycle: ICache returns 0x8000_0000 AND next request MUST be 0x8000_0008 (never double-fetch 0x8000_0000 or drop response!)
        ic_val = 1; ic_inst = 64'hBBBB_AAAA_1111_2222; f_npc = 32'h8000_0010;
        // Hold fetch_accept_i = 0 for 3 cycles to test multi-cycle skid retention!
        f_acc = 0; #1;
        if (!m1_fval || m1_fpc !== 32'h8000_0000 || m1_finstr !== 64'hBBBB_AAAA_1111_2222) begin
            $display("FAIL Test4a_2: Dropped first post-redirect ICache response in SUPPORT_MMU=1! fval=%b fpc=%h", m1_fval, m1_fpc);
            $finish(1);
        end
        @(posedge clk); #1;
        ic_val = 0; ic_inst = 64'h0;
        // Stall cycle 2 (f_acc still 0) -> skid MUST still hold!
        @(posedge clk); #1;
        if (!m1_fval || m1_fpc !== 32'h8000_0000 || m1_finstr !== 64'hBBBB_AAAA_1111_2222) begin
            $display("FAIL Test4c_1: Skid buffer lost parcel across multi-cycle fetch_accept_i=0! fval=%b fpc=%h", m1_fval, m1_fpc);
            $finish(1);
        end
        // Release f_acc = 1 -> delivers skidded 0x8000_0000 AND issues 0x8000_0008 (same cycle or next cycle)!
        f_acc = 1; #1;
        if (!m1_fval || m1_fpc !== 32'h8000_0000) begin
            $display("FAIL Test4c_2: Post-skid release mismatch: fval=%b fpc=%h", m1_fval, m1_fpc);
            $finish(1);
        end
        begin : blk_test4c_issue
            reg issued_4c_early;
            issued_4c_early = (m1_ic_rd === 1'b1 && m1_ic_pc === 32'h8000_0008);
            @(posedge clk); #1;
            if (!issued_4c_early) begin
                if (!m1_ic_rd || m1_ic_pc !== 32'h8000_0008) begin
                    $display("FAIL Test4c_2: Post-skid next-cycle issue mismatch: rd=%b ic_pc=%h", m1_ic_rd, m1_ic_pc);
                    $finish(1);
                end
                @(posedge clk); #1;
            end
        end
        // Now 0x8000_0008 is in-flight in ICache (ic_val = 0)! Trigger redirect to 0x9000_0000 while also testing skid flush!
        f_breq = 1; f_bpc = 32'h9000_0000; f_bpriv = `PRIV_SUPER;
        @(posedge clk); #1;
        f_breq = 0; f_npc = 32'h9000_0008;
        // Stale response for 0x8000_0008 arrives 1 cycle later -> MUST be dropped (m1_fval == 0)!
        @(posedge clk); #1;
        ic_val = 1; ic_inst = 64'hDEAD_DEAD_DEAD_DEAD; #1;
        if (m1_fval !== 1'b0) begin
            $display("FAIL Test4d_1: Failed to drop stale in-flight ICache response after redirect!");
            $finish(1);
        end
        begin : blk_test4d_issue
            reg issued_4d_early;
            issued_4d_early = (m1_ic_rd === 1'b1 && ic_acc === 1'b1 && m1_ic_pc === 32'h9000_0000 && m1_ic_priv === `PRIV_SUPER);
            @(posedge clk); #1;
            ic_val = 0; #1;
            if (!issued_4d_early) begin
                // Drain-first implementation issues 0x9000_0000 on the cycle after stale response drain
                if (!m1_ic_rd || m1_ic_pc !== 32'h9000_0000 || m1_ic_priv !== `PRIV_SUPER) begin
                    $display("FAIL Test4d_2: Post-drain redirect issue wrong: rd=%b pc=%h priv=%b", m1_ic_rd, m1_ic_pc, m1_ic_priv);
                    $finish(1);
                end
                @(posedge clk); #1;
            end else if (m1_ic_rd && m1_ic_pc === 32'h9000_0000) begin
                $display("FAIL Test4d_2: Duplicate issue of 0x9000_0000 after already handshaking!");
                $finish(1);
            end
        end
        ic_val = 1; ic_inst = 64'hCAFE_BABE_0000_9000;
        // Put into skid (f_acc = 0), then redirect to 0xA000_0000 -> skid MUST clear immediately!
        f_acc = 0;
        @(posedge clk); #1;
        ic_val = 0;
        if (!m1_fval) begin $display("FAIL Test4d_3: Expected skid valid"); $finish(1); end
        f_breq = 1; f_bpc = 32'hA000_0000; #1;
        if (m1_fval !== 1'b0) begin $display("FAIL Test4d_4: Skid leaked during branch_request_i!"); $finish(1); end
        @(posedge clk); #1;
        f_breq = 0; f_acc = 1; #1;
        if (m1_fval !== 1'b0) begin $display("FAIL Test4d_5: Stale skid survived branch_request_i!"); $finish(1); end

        // 4e: Pulse fetch_invalidate_i for 1 cycle while icache_accept_i = 0 -> MUST retain icache_flush_o until icache_accept_i = 1!
        ic_acc = 0; f_inv = 1;
        @(posedge clk); #1;
        f_inv = 0; #1;
        if (m1_ic_fl !== 1'b1) begin
            $display("FAIL Test4e_1: Dropped fetch_invalidate_i when icache_accept_i == 0!");
            $finish(1);
        end
        @(posedge clk); #1;
        ic_acc = 1; #1;
        if (m1_ic_fl !== 1'b1) begin
            $display("FAIL Test4e_2: icache_flush_o dropped before handshake!");
            $finish(1);
        end
        @(posedge clk); #1;
        if (m1_ic_fl !== 1'b0) begin
            $display("FAIL Test4e_3: icache_flush_o did not clear after handshake!");
            $finish(1);
        end

        // -----------------------------------------------------------------
        // Test 5: End-to-end biriscv_frontend closed-loop execution trace
        //   Simulates a real program with:
        //   - Aligned & upper-slot JAL/JALR nested calls & returns
        //   - Not-taken lower conditional branch + taken upper call in same 64b parcel
        //   - Random ICache wait states (0..3 cycles) & decode accept backpressure
        // -----------------------------------------------------------------
        do_reset();
        warmup_lfsr();
        // Train predictor inside u_fe:
        //   0x1000: BEQ (not-taken, counter trained to 0)
        //   0x1004: JAL ra, 0x2004 (upper-slot call to mid-parcel entry 0x2004! Pushes 0x1008)
        //   0x2004: JAL ra, 0x3000 (upper-slot nested call! Pushes 0x2008)
        //   0x3000: RET (lower-slot return -> 0x2008! Upper slot 0x3004 MUST be masked off in fetch_fifo!)
        //   0x2008: RET (lower-slot return -> 0x1008!)
        fe_bi_req = 1; fe_bi_tkn = 1; fe_bi_src = 32'h1000; fe_bi_pc = 32'h1800; @(posedge clk); #1; clear_all();
        fe_bi_req = 1; fe_bi_tkn = 1; fe_bi_call = 1; fe_bi_jmp = 1; fe_bi_src = 32'h1004; fe_bi_pc = 32'h2004; @(posedge clk); #1; clear_all();
        fe_bi_req = 1; fe_bi_tkn = 1; fe_bi_call = 1; fe_bi_jmp = 1; fe_bi_src = 32'h2004; fe_bi_pc = 32'h3000; @(posedge clk); #1; clear_all();
        fe_bi_req = 1; fe_bi_tkn = 1; fe_bi_ret  = 1; fe_bi_src = 32'h3000; fe_bi_pc = 32'h2008; @(posedge clk); #1; clear_all();
        fe_bi_req = 1; fe_bi_tkn = 1; fe_bi_ret  = 1; fe_bi_src = 32'h2008; fe_bi_pc = 32'h1008; @(posedge clk); #1; clear_all();
        repeat (10) begin
            fe_bi_req = 1; fe_bi_ntkn = 1; fe_bi_src = 32'h1000; fe_bi_pc = 32'h1004; @(posedge clk); #1; clear_all();
        end

        // Redirect frontend to 0x1000 and watch ZERO-MISPREDICTION speculative parcel stream!
        fe_breq = 1; fe_bpc = 32'h1000; fe_bpriv = `PRIV_MACHINE;
        @(posedge clk); #1; clear_all();

        begin
            logic [31:0] expected_ic_pcs [0:4];
            int rd_idx = 0;
            int resp_cnt = 0;
            logic pend_req = 0;
            logic [31:0] pend_addr = 0;
            int wait_cyc = 0;

            expected_ic_pcs[0] = 32'h1000; // Slot0(1000)=NT, Slot1(1004)=CALL 2004 (pushes 1008)
            expected_ic_pcs[1] = 32'h2000; // Mid-parcel 2004=CALL 3000 (pushes 2008)
            expected_ic_pcs[2] = 32'h3000; // Slot0(3000)=RET -> 2008 (kills Slot1 3004!)
            expected_ic_pcs[3] = 32'h2008; // Slot0(2008)=RET -> 1008 (kills Slot1 200C!)
            expected_ic_pcs[4] = 32'h1008; // Fallthrough after outer call!

            fe_f0_acc = 1; fe_f1_acc = 1;

            for (int cyc = 0; cyc < 60 && resp_cnt < 5; cyc++) begin
                int r = $urandom(seed + cyc);
                fe_ic_acc = ((r & 3) != 0); // randomized ICache accept backpressure!
                fe_ic_val = 0;
                if (pend_req) begin
                    if (wait_cyc == 0) begin
                        fe_ic_val  = 1;
                        fe_ic_inst = {pend_addr + 32'd4, pend_addr};
                        pend_req   = 0;
                        resp_cnt++;
                    end else begin
                        wait_cyc--;
                    end
                end
                #1;
                if (fe_ic_rd && fe_ic_acc) begin
                    if (rd_idx < 5 && fe_ic_pc !== expected_ic_pcs[rd_idx]) begin
                        $display("FAIL Test5: Frontend speculative fetch PC[%0d] = %h, expected %h!",
                                 rd_idx, fe_ic_pc, expected_ic_pcs[rd_idx]);
                        $finish(1);
                    end
                    pend_req  = 1;
                    pend_addr = fe_ic_pc;
                    wait_cyc  = (r >> 4) & 2; // 0..2 cycles latency
                    rd_idx++;
                end
                // Verify Slot1 masking on lower-slot RET at 0x3000 and 0x2008!
                if (fe_f0_val && (fe_f0_pc == 32'h3000 || fe_f0_pc == 32'h2008)) begin
                    if (fe_f1_val !== 1'b0) begin
                        $display("FAIL Test5b: Lower-slot RET at %h failed to mask fetch1_valid_o!", fe_f0_pc);
                        $finish(1);
                    end
                end
                // Verify Slot1 validity on upper-slot CALL at 0x1000..0x1004!
                if (fe_f0_val && fe_f0_pc == 32'h1000) begin
                    if (fe_f1_val !== 1'b1 || fe_f1_pc !== 32'h1004) begin
                        $display("FAIL Test5c: Upper-slot CALL at 0x1004 erroneously masked in fetch_fifo! f1_val=%b", fe_f1_val);
                        $finish(1);
                    end
                end
                @(posedge clk); #1;
            end

            if (resp_cnt < 5) begin
                $display("FAIL Test5d: Frontend hung before completing 5-parcel nested call/return trace! resp_cnt=%0d rd_idx=%0d",
                         resp_cnt, rd_idx);
                $finish(1);
            end
        end

        $display("PASS seed=%0d", seed);
        $finish(0);
    end
endmodule
