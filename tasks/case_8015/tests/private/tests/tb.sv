`timescale 1ns/1ps
`include "common_defines.vh"
module tb;
  import el2_pkg::*;

  logic        clk_i = 1'b0;
  always #5 clk_i = ~clk_i;

  logic        rst_ni;
  logic        dec_csr_wen_r_mod;
  logic [11:0] dec_csr_wraddr_r;
  logic [31:0] dec_csr_wrdata_r;
  logic [11:0] dec_csr_rdaddr_d;
  logic        csr_pmpcfg;
  logic        csr_pmpaddr0;
  logic        csr_pmpaddr16;
  logic        csr_pmpaddr32;
  logic        csr_pmpaddr48;
  logic        mseccfg_rlb;
  logic        mseccfg_mmwp;
  logic        mseccfg_mml;
  logic        priv_mode_ns;
  logic        priv_mode_eff;
  logic [31:0] dec_pmp_rddata_d;
  logic        dec_pmp_read_d;

  logic [31:0] pmp_chan_addr_0;
  logic [31:0] pmp_chan_addr_1;
  logic [31:0] pmp_chan_addr_2;
  logic [2:0]  pmp_chan_type_0;
  logic [2:0]  pmp_chan_type_1;
  logic [2:0]  pmp_chan_type_2;
  logic        pmp_chan_err_0;
  logic        pmp_chan_err_1;
  logic        pmp_chan_err_2;

  logic [7:0]  fault_in;
  logic [7:0]  fault_out;
  logic [7:0]  trace_in;
  logic [7:0]  trace_out;

  top dut (
    .clk_i             ( clk_i             ),
    .rst_ni            ( rst_ni            ),
    .dec_csr_wen_r_mod ( dec_csr_wen_r_mod ),
    .dec_csr_wraddr_r  ( dec_csr_wraddr_r  ),
    .dec_csr_wrdata_r  ( dec_csr_wrdata_r  ),
    .dec_csr_rdaddr_d  ( dec_csr_rdaddr_d  ),
    .csr_pmpcfg        ( csr_pmpcfg        ),
    .csr_pmpaddr0      ( csr_pmpaddr0      ),
    .csr_pmpaddr16     ( csr_pmpaddr16     ),
    .csr_pmpaddr32     ( csr_pmpaddr32     ),
    .csr_pmpaddr48     ( csr_pmpaddr48     ),
    .mseccfg_rlb       ( mseccfg_rlb       ),
    .mseccfg_mmwp      ( mseccfg_mmwp      ),
    .mseccfg_mml       ( mseccfg_mml       ),
    .priv_mode_ns      ( priv_mode_ns      ),
    .priv_mode_eff     ( priv_mode_eff     ),
    .dec_pmp_rddata_d  ( dec_pmp_rddata_d  ),
    .dec_pmp_read_d    ( dec_pmp_read_d    ),
    .pmp_chan_addr_0   ( pmp_chan_addr_0   ),
    .pmp_chan_addr_1   ( pmp_chan_addr_1   ),
    .pmp_chan_addr_2   ( pmp_chan_addr_2   ),
    .pmp_chan_type_0   ( pmp_chan_type_0   ),
    .pmp_chan_type_1   ( pmp_chan_type_1   ),
    .pmp_chan_type_2   ( pmp_chan_type_2   ),
    .pmp_chan_err_0    ( pmp_chan_err_0    ),
    .pmp_chan_err_1    ( pmp_chan_err_1    ),
    .pmp_chan_err_2    ( pmp_chan_err_2    ),
    .fault_in          ( fault_in          ),
    .fault_out         ( fault_out         ),
    .trace_in          ( trace_in          ),
    .trace_out         ( trace_out         )
  );

  task automatic step_clk();
    @(posedge clk_i);
    #1;
  endtask

  task automatic reset_dut();
    rst_ni            = 1'b0;
    dec_csr_wen_r_mod = 1'b0;
    dec_csr_wraddr_r  = 12'h0;
    dec_csr_wrdata_r  = 32'h0;
    dec_csr_rdaddr_d  = 12'h0;
    csr_pmpcfg        = 1'b0;
    csr_pmpaddr0      = 1'b0;
    csr_pmpaddr16     = 1'b0;
    csr_pmpaddr32     = 1'b0;
    csr_pmpaddr48     = 1'b0;
    mseccfg_rlb       = 1'b0;
    mseccfg_mmwp      = 1'b0;
    mseccfg_mml       = 1'b0;
    priv_mode_ns      = 1'b0;
    priv_mode_eff     = 1'b0;
    pmp_chan_addr_0   = 32'h0;
    pmp_chan_addr_1   = 32'h0;
    pmp_chan_addr_2   = 32'h0;
    pmp_chan_type_0   = 3'b000;
    pmp_chan_type_1   = 3'b000;
    pmp_chan_type_2   = 3'b000;
    fault_in          = 8'h3C;
    trace_in          = 8'hC3;
    repeat (3) @(posedge clk_i);
    #1;
    rst_ni = 1'b1;
    #1;
  endtask

  task automatic write_csr(input logic [11:0] addr, input logic [31:0] wdata);
    dec_csr_wen_r_mod = 1'b1;
    dec_csr_wraddr_r  = addr;
    dec_csr_wrdata_r  = wdata;
    step_clk();
    dec_csr_wen_r_mod = 1'b0;
    dec_csr_wraddr_r  = 12'h0;
    dec_csr_wrdata_r  = 32'h0;
  endtask

  task automatic read_pmpcfg(input logic [3:0] group, output logic [31:0] rdata);
    csr_pmpcfg       = 1'b1;
    csr_pmpaddr0     = 1'b0;
    dec_csr_rdaddr_d = {8'h3a, group};
    #1;
    if (!dec_pmp_read_d) $fatal(1, "TB_FAIL: dec_pmp_read_d low on pmpcfg read");
    rdata = dec_pmp_rddata_d;
    csr_pmpcfg = 1'b0;
  endtask

  task automatic read_pmpaddr(input logic [3:0] idx, output logic [31:0] rdata);
    csr_pmpcfg       = 1'b0;
    csr_pmpaddr0     = 1'b1;
    dec_csr_rdaddr_d = {8'h3b, idx};
    #1;
    if (!dec_pmp_read_d) $fatal(1, "TB_FAIL: dec_pmp_read_d low on pmpaddr read");
    rdata = dec_pmp_rddata_d;
    csr_pmpaddr0 = 1'b0;
  endtask

  int seed = 1;
  int checks = 0;
  logic [31:0] rd;

  initial begin
    if (!$value$plusargs("SEED=%d", seed)) seed = 1;

    // -----------------------------------------------------------------------
    // Phase 1: Transparent channels & WARL masking (MML=0 vs MML=1)
    // -----------------------------------------------------------------------
    reset_dut();
    if (fault_out !== 8'h3C || trace_out !== 8'hC3)
      $fatal(1, "TB_FAIL: transparent sideband channel mismatch");

    // With MML=0, write pmpcfg0:
    // entry 0: 8'b011_01_010 (reserved[6:5]=2'b11, mode=TOR(2'b01), X=0, W=1, R=0)
    //   -> reserved[6:5] must be masked to 00, and since MML=0 and R=0, W must be masked to 0 -> 8'b0000_1000 (8'h08)
    // entry 1: 8'b010_11_111 (reserved[6:5]=2'b10, mode=NAPOT(2'b11), X=1, W=1, R=1) -> 8'h1F
    write_csr(12'h3a0, 32'h0000_1F6A);
    read_pmpcfg(4'h0, rd);
    if (rd[7:0] !== 8'h08 || rd[15:8] !== 8'h1F)
      $fatal(1, "TB_FAIL: P1 MML=0 WARL masking failed (got %h, exp 00001f08)", rd);
    checks++;

    // -----------------------------------------------------------------------
    // Phase 2: TOR Neighbor Lock & RLB Override
    // -----------------------------------------------------------------------
    reset_dut();
    // Program pmpaddr0 = 32'h0000_0400 (byte addr 0x1000)
    // Program pmpaddr1 = 32'h0000_0800 (byte addr 0x2000)
    // Program pmpaddr2 = 32'hC000_0C00 (top bits [31:30] must be WARL 2'b00 -> 32'h0000_0C00)
    write_csr(12'h3b0, 32'h0000_0400);
    write_csr(12'h3b1, 32'h0000_0800);
    write_csr(12'h3b2, 32'hC000_0C00);
    read_pmpaddr(4'h2, rd);
    if (rd !== 32'h0000_0C00)
      $fatal(1, "TB_FAIL: P2 pmpaddr[31:30] WARL zeroing failed (got %h)", rd);

    // Lock entry 1 in TOR mode: pmpcfg[1] = {lock=1, 2'b00, mode=TOR(2'b01), X=0, W=0, R=1} = 8'h89
    // Entry 0 unlocked OFF: pmpcfg[0] = 8'h00
    write_csr(12'h3a0, 32'h0000_8900);
    read_pmpcfg(4'h0, rd);
    if (rd[15:8] !== 8'h89)
      $fatal(1, "TB_FAIL: P2 pmpcfg[1] write failed (got %h)", rd);

    // Now entry 1 is locked TOR with RLB=0:
    // - Writing pmpcfg[1] must be ignored!
    // - Writing pmpaddr[1] must be ignored!
    // - Writing pmpaddr[0] MUST ALSO BE IGNORED because entry 1 is locked TOR!
    write_csr(12'h3a0, 32'h0000_001F); // entry 0 -> 8'h1F (allowed), entry 1 -> 8'h00 (blocked!)
    write_csr(12'h3b0, 32'h0000_0555); // blocked by locked TOR entry 1!
    write_csr(12'h3b1, 32'h0000_0999); // blocked by locked entry 1!
    read_pmpcfg(4'h0, rd);
    if (rd[7:0] !== 8'h1F || rd[15:8] !== 8'h89)
      $fatal(1, "TB_FAIL: P2 locked pmpcfg[1] was overwritten or pmpcfg[0] blocked (got %h)", rd);
    read_pmpaddr(4'h0, rd);
    if (rd !== 32'h0000_0400)
      $fatal(1, "TB_FAIL: P2 TOR neighbor pmpaddr[0] was modified while entry 1 locked TOR (got %h)", rd);
    read_pmpaddr(4'h1, rd);
    if (rd !== 32'h0000_0800)
      $fatal(1, "TB_FAIL: P2 locked pmpaddr[1] was modified (got %h)", rd);
    checks++;

    // Enable mseccfg.RLB = 1: now locked entry 1 and pmpaddr[0] can be modified!
    mseccfg_rlb = 1'b1;
    write_csr(12'h3b0, 32'h0000_0500);
    read_pmpaddr(4'h0, rd);
    if (rd !== 32'h0000_0500)
      $fatal(1, "TB_FAIL: P2 RLB=1 failed to allow writing pmpaddr[0] (got %h)", rd);
    checks++;

    // -----------------------------------------------------------------------
    // Phase 3: TOR (entry 0 vs entry r>0), NAPOT Granule Mask, & Priority Order
    // -----------------------------------------------------------------------
    reset_dut();
    // Configure:
    // Entry 0: TOR [0x0000_0000, 0x0000_1000) -> pmpaddr0 = 32'h0000_0400, pmpcfg[0] = {L=0, TOR(01), X=0, W=0, R=1} = 8'h09 (READ only)
    // Entry 1: TOR [0x0000_1000, 0x0000_2000) -> pmpaddr1 = 32'h0000_0800, pmpcfg[1] = {L=1, TOR(01), X=0, W=0, R=1} = 8'h89 (locked READ only)
    // Entry 2: NAPOT [0x0000_1000, 0x0000_3000) -> wait: NAPOT 8KB at 0x0000_2000:
    //   base = 0x0000_2000 (word 0x800), size = 4KB (0x1000 bytes -> 1024 words -> mask bits [9:0] = 10'h1ff):
    //   pmpaddr2 = 32'h0000_0800 | 32'h0000_01FF = 32'h0000_09FF (covers [0x2000, 0x3000))
    //   pmpcfg[2] = {L=1, NAPOT(11), X=1, W=1, R=1} = 8'h9F
    // Entry 3: NAPOT overlapping [0x0000_0000, 0x0000_4000) -> pmpaddr3 = 32'h0000_07FF (16KB), pmpcfg[3] = 8'h9F (RWX)
    write_csr(12'h3b0, 32'h0000_0400);
    write_csr(12'h3b1, 32'h0000_0800);
    write_csr(12'h3b2, 32'h0000_09FF);
    write_csr(12'h3b3, 32'h0000_07FF);
    write_csr(12'h3a0, 32'h9F9F_8909);

    // Check in User Mode (priv_mode_ns=1, priv_mode_eff=1) with MML=0:
    priv_mode_ns  = 1'b1;
    priv_mode_eff = 1'b1;
    // Chan 0: addr 0x0000_0FFC (inside entry 0 TOR [0, 0x1000) AND entry 3 NAPOT [0, 0x4000))
    // Entry 0 has higher priority than Entry 3! Entry 0 only allows READ (R=1, W=0).
    // So WRITE on Chan 0 must FAULT (err=1), while READ on Chan 0 must PASS (err=0)!
    pmp_chan_addr_0 = 32'h0000_0FFC;
    pmp_chan_type_0 = 3'b010; // WRITE
    pmp_chan_addr_1 = 32'h0000_0FFC;
    pmp_chan_type_1 = 3'b001; // READ
    // Chan 2: addr 0x0000_2ABC (inside entry 2 NAPOT [0x2000, 0x3000) with RWX=111) -> WRITE must PASS (err=0)!
    pmp_chan_addr_2 = 32'h0000_2ABC;
    pmp_chan_type_2 = 3'b010; // WRITE
    #1;
    if (pmp_chan_err_0 !== 1'b1 || pmp_chan_err_1 !== 1'b0 || pmp_chan_err_2 !== 1'b0)
      $fatal(1, "TB_FAIL: P3 priority/TOR/NAPOT check failed (err0=%b err1=%b err2=%b, exp 1,0,0)",
             pmp_chan_err_0, pmp_chan_err_1, pmp_chan_err_2);
    checks++;

    // Check Machine Mode (priv_mode_ns=0, priv_mode_eff=0) with MML=0:
    // Entry 0 has L=0, so M-mode WRITE to 0x0000_0FFC succeeds (err=0) despite W=0!
    // Entry 1 has L=1 (R=1, W=0), so M-mode WRITE to 0x0000_1000 (lower bound of TOR entry 1) FAULTS (err=1)!
    // Unmatched address 0x0000_5000 in M-mode with MMWP=0 succeeds (err=0), but with MMWP=1 FAULTS (err=1)!
    priv_mode_ns    = 1'b0;
    priv_mode_eff   = 1'b0;
    pmp_chan_addr_0 = 32'h0000_0FFC;
    pmp_chan_type_0 = 3'b010; // WRITE to unlocked entry 0
    pmp_chan_addr_1 = 32'h0000_1000;
    pmp_chan_type_1 = 3'b010; // WRITE to locked entry 1
    pmp_chan_addr_2 = 32'h0000_5000; // Unmatched
    pmp_chan_type_2 = 3'b001; // READ
    mseccfg_mmwp    = 1'b0;
    #1;
    if (pmp_chan_err_0 !== 1'b0 || pmp_chan_err_1 !== 1'b1 || pmp_chan_err_2 !== 1'b0)
      $fatal(1, "TB_FAIL: P3 M-mode lock/TOR boundary check failed (err0=%b err1=%b err2=%b, exp 0,1,0)",
             pmp_chan_err_0, pmp_chan_err_1, pmp_chan_err_2);
    mseccfg_mmwp = 1'b1;
    #1;
    if (pmp_chan_err_2 !== 1'b1)
      $fatal(1, "TB_FAIL: P3 mseccfg.MMWP=1 failed to deny unmatched M-mode access");
    checks++;

    // -----------------------------------------------------------------------
    // Phase 4: Smepmp (mseccfg.MML=1) Rule Creation Guard & Shared Regions
    // -----------------------------------------------------------------------
    reset_dut();
    mseccfg_mml = 1'b1;
    mseccfg_rlb = 1'b0;
    // When MML=1 and RLB=0, attempting to write pmpcfg with L=1, X=1, R=1, W=0 (8'h8D, M-mode-only executable)
    // or L=1, R=0, W=1, X=1 (8'h8E, locked shared executable) must be blocked by pmp_locked_wr_en!
    // Meanwhile, writing L=0, R=0, W=1, X=0 (8'h1A, NA4 shared M-RW/U-R) or L=1, R=1, W=1, X=1 (8'h97, NA4 shared RO) is allowed!
    write_csr(12'h3b0, 32'h0000_1000); // NA4 at 0x4000
    write_csr(12'h3b1, 32'h0000_2000); // NA4 at 0x8000
    write_csr(12'h3b2, 32'h0000_3000); // NA4 at 0xC000
    write_csr(12'h3b3, 32'h0000_4000); // NA4 at 0x10000
    write_csr(12'h3a0, {8'h97, 8'h1A, 8'h8E, 8'h8D});
    read_pmpcfg(4'h0, rd);
    if (rd[7:0] !== 8'h00 || rd[15:8] !== 8'h00 || rd[23:16] !== 8'h1A || rd[31:24] !== 8'h97)
      $fatal(1, "TB_FAIL: P4 MML=1 RLB=0 pmp_locked_wr_en guard or (R=0,W=1) WARL failed (got %h, exp 971a0000)", rd);
    checks++;

    // Now set RLB=1 to allow installing locked MML rules:
    // Entry 0 (0x4000): L=1, NA4(10), X=1, W=1, R=0 (8'h96 -> {L,X}=2'b11: M-mode R/X, U-mode X only)
    // Entry 1 (0x8000): L=0, NA4(10), X=0, W=1, R=0 (8'h12 -> {L,X}=2'b00: M-mode R/W, U-mode R only)
    // Entry 2 (0xC000): L=0, NA4(10), X=0, W=1, R=1 (8'h13 -> U-mode R/W, M-mode DENIED because L=0 in MML!)
    // Entry 3 (0x10000): L=1, NA4(10), X=1, W=1, R=1 (8'h97 -> Shared RO: M/U READ only, WRITE/EXEC denied!)
    mseccfg_rlb = 1'b1;
    write_csr(12'h3a0, {8'h97, 8'h13, 8'h12, 8'h96});

    // Test in M-mode (priv_mode_ns=0, priv_mode_eff=0):
    priv_mode_ns  = 1'b0;
    priv_mode_eff = 1'b0;
    // Chan 0: Entry 0 (0x4000) READ -> allowed (err=0); WRITE -> denied (err=1)
    // Chan 1: Entry 2 (0xC000, L=0 R=1 W=1) READ in M-mode -> DENIED (err=1) under MML=1!
    // Chan 2: Unmatched address (0x20000) EXEC in M-mode -> DENIED (err=1) under MML=1!
    pmp_chan_addr_0 = 32'h0000_4000;
    pmp_chan_type_0 = 3'b001; // READ
    pmp_chan_addr_1 = 32'h0000_C000;
    pmp_chan_type_1 = 3'b001; // READ on U-mode-only region in M-mode
    pmp_chan_addr_2 = 32'h0002_0000;
    pmp_chan_type_2 = 3'b100; // Unmatched EXEC in M-mode
    #1;
    if (pmp_chan_err_0 !== 1'b0 || pmp_chan_err_1 !== 1'b1 || pmp_chan_err_2 !== 1'b1)
      $fatal(1, "TB_FAIL: P4 MML=1 M-mode check failed (err0=%b err1=%b err2=%b, exp 0,1,1)",
             pmp_chan_err_0, pmp_chan_err_1, pmp_chan_err_2);

    // Test Entry 3 (0x10000, L=1 R=1 W=1 X=1 Shared RO): READ allowed (err=0), WRITE denied (err=1), EXEC denied (err=1)
    pmp_chan_addr_0 = 32'h0001_0000;
    pmp_chan_type_0 = 3'b001; // READ
    pmp_chan_addr_1 = 32'h0001_0000;
    pmp_chan_type_1 = 3'b010; // WRITE
    pmp_chan_addr_2 = 32'h0001_0000;
    pmp_chan_type_2 = 3'b100; // EXEC
    #1;
    if (pmp_chan_err_0 !== 1'b0 || pmp_chan_err_1 !== 1'b1 || pmp_chan_err_2 !== 1'b1)
      $fatal(1, "TB_FAIL: P4 MML=1 (R=1,W=1,X=1,L=1) shared RO check failed (err0=%b err1=%b err2=%b, exp 0,1,1)",
             pmp_chan_err_0, pmp_chan_err_1, pmp_chan_err_2);

    // Test MPRV privilege split (priv_mode_ns=0 (M-mode for EXEC), priv_mode_eff=1 (U-mode for READ/WRITE)):
    // First configure Entry 2 (0xC000) to L=1, NA4(10), X=1, W=0, R=0 (8'h94 -> M-mode X only, U-mode DENIED):
    write_csr(12'h3a0, {8'h97, 8'h94, 8'h12, 8'h96});
    // Under MPRV (priv_mode_ns=0, priv_mode_eff=1):
    // - Chan 0: Entry 2 (0xC000) EXEC uses priv_mode_ns=0 (M-mode) -> ALLOWED (err=0)! (If EXEC used priv_mode_eff=1, it would fault!)
    // - Chan 1: Entry 0 (0x4000) READ uses priv_mode_eff=1 (U-mode) -> DENIED (err=1)!
    // - Chan 2: Entry 1 (0x8000) WRITE uses priv_mode_eff=1 (U-mode) -> DENIED (err=1)!
    priv_mode_ns    = 1'b0;
    priv_mode_eff   = 1'b1;
    pmp_chan_addr_0 = 32'h0000_C000;
    pmp_chan_type_0 = 3'b100; // EXEC (M-mode via priv_mode_ns=0)
    pmp_chan_addr_1 = 32'h0000_4000;
    pmp_chan_type_1 = 3'b001; // READ (U-mode via MPRV)
    pmp_chan_addr_2 = 32'h0000_8000;
    pmp_chan_type_2 = 3'b010; // WRITE (U-mode via MPRV)
    #1;
    if (pmp_chan_err_0 !== 1'b0 || pmp_chan_err_1 !== 1'b1 || pmp_chan_err_2 !== 1'b1)
      $fatal(1, "TB_FAIL: P4 MPRV priv_mode_ns vs priv_mode_eff check failed (err0=%b err1=%b err2=%b, exp 0,1,1)",
             pmp_chan_err_0, pmp_chan_err_1, pmp_chan_err_2);
    checks++;

    $display("TB_PASS seed=%0d checks=%0d", seed, checks);
    $finish;
  end
endmodule
