`timescale 1ns/1ps
`include "common_defines.vh"
module tb;
  import el2_pkg::*;

  logic        clk_i = 1'b0;
  always #5 clk_i = ~clk_i;

  logic        rst_ni;
  logic        clk_override;
  logic [31:0] lsu_ld_data_r;
  logic [31:0] lsu_ld_data_corr_r;
  logic        lsu_single_ecc_error_r;
  logic        lsu_double_ecc_error_r;
  logic [31:0] lsu_ld_data_m;
  logic        lsu_single_ecc_error_m;
  logic        lsu_double_ecc_error_m;
  logic        flush_m_up;
  logic        flush_r;
  logic [31:0] exu_lsu_rs1_d;
  logic [31:0] exu_lsu_rs2_d;
  el2_lsu_pkt_t lsu_p;
  logic        dec_lsu_valid_raw_d;
  logic [11:0] dec_lsu_offset_d;
  logic [31:0] picm_mask_data_m;
  logic [31:0] bus_read_data_m;
  logic [31:0] dec_tlu_mrac_ff;
  logic        dma_dccm_req;
  logic [31:0] dma_mem_addr;
  logic [2:0]  dma_mem_sz;
  logic        dma_mem_write;
  logic [63:0] dma_mem_wdata;
  logic        lsu_pmp_error_start;
  logic        lsu_pmp_error_end;
  el2_trigger_pkt_t [3:0] trigger_pkt;

  logic [31:0] lsu_result_m;
  logic [31:0] lsu_result_corr_r;
  logic [31:0] lsu_addr_d, lsu_addr_m, lsu_addr_r;
  logic [31:0] end_addr_d, end_addr_m, end_addr_r;
  logic [31:0] store_data_m;
  logic        lsu_exc_m;
  logic        is_sideeffects_m;
  logic        lsu_commit_r;
  logic        lsu_single_ecc_error_incr;
  logic [39:0] lsu_error_pkt_r_bits;
  el2_lsu_error_pkt_t lsu_error_pkt_r;
  assign lsu_error_pkt_r = el2_lsu_error_pkt_t'(lsu_error_pkt_r_bits);
  logic [30:0] lsu_fir_addr;
  logic [1:0]  lsu_fir_error;
  logic        addr_in_dccm_d, addr_in_dccm_m, addr_in_dccm_r;
  logic        addr_in_pic_d, addr_in_pic_m, addr_in_pic_r;
  logic        addr_external_m;
  logic [3:0]  lsu_trigger_match_m;
  logic [7:0]  pmu_in, pmu_out, fir_in, fir_out;

  top dut (
    .clk_i                     ( clk_i                     ),
    .rst_ni                    ( rst_ni                    ),
    .clk_override              ( clk_override              ),
    .lsu_ld_data_r             ( lsu_ld_data_r             ),
    .lsu_ld_data_corr_r        ( lsu_ld_data_corr_r        ),
    .lsu_single_ecc_error_r    ( lsu_single_ecc_error_r    ),
    .lsu_double_ecc_error_r    ( lsu_double_ecc_error_r    ),
    .lsu_ld_data_m             ( lsu_ld_data_m             ),
    .lsu_single_ecc_error_m    ( lsu_single_ecc_error_m    ),
    .lsu_double_ecc_error_m    ( lsu_double_ecc_error_m    ),
    .flush_m_up                ( flush_m_up                ),
    .flush_r                   ( flush_r                   ),
    .exu_lsu_rs1_d             ( exu_lsu_rs1_d             ),
    .exu_lsu_rs2_d             ( exu_lsu_rs2_d             ),
    .lsu_pkt_bits              ( 14'(lsu_p)                ),
    .dec_lsu_valid_raw_d       ( dec_lsu_valid_raw_d       ),
    .dec_lsu_offset_d          ( dec_lsu_offset_d          ),
    .picm_mask_data_m          ( picm_mask_data_m          ),
    .bus_read_data_m           ( bus_read_data_m           ),
    .dec_tlu_mrac_ff           ( dec_tlu_mrac_ff           ),
    .dma_dccm_req              ( dma_dccm_req              ),
    .dma_mem_addr              ( dma_mem_addr              ),
    .dma_mem_sz                ( dma_mem_sz                ),
    .dma_mem_write             ( dma_mem_write             ),
    .dma_mem_wdata             ( dma_mem_wdata             ),
    .lsu_pmp_error_start       ( lsu_pmp_error_start       ),
    .lsu_pmp_error_end         ( lsu_pmp_error_end         ),
    .trigger_pkt_0             ( 38'(trigger_pkt[0])       ),
    .trigger_pkt_1             ( 38'(trigger_pkt[1])       ),
    .trigger_pkt_2             ( 38'(trigger_pkt[2])       ),
    .trigger_pkt_3             ( 38'(trigger_pkt[3])       ),
    .lsu_result_m              ( lsu_result_m              ),
    .lsu_result_corr_r         ( lsu_result_corr_r         ),
    .lsu_addr_d                ( lsu_addr_d                ),
    .lsu_addr_m                ( lsu_addr_m                ),
    .lsu_addr_r                ( lsu_addr_r                ),
    .end_addr_d                ( end_addr_d                ),
    .end_addr_m                ( end_addr_m                ),
    .end_addr_r                ( end_addr_r                ),
    .store_data_m              ( store_data_m              ),
    .lsu_exc_m                 ( lsu_exc_m                 ),
    .is_sideeffects_m          ( is_sideeffects_m          ),
    .lsu_commit_r              ( lsu_commit_r              ),
    .lsu_single_ecc_error_incr ( lsu_single_ecc_error_incr ),
    .lsu_error_pkt_r_bits      ( lsu_error_pkt_r_bits      ),
    .lsu_fir_addr              ( lsu_fir_addr              ),
    .lsu_fir_error             ( lsu_fir_error             ),
    .addr_in_dccm_d            ( addr_in_dccm_d            ),
    .addr_in_dccm_m            ( addr_in_dccm_m            ),
    .addr_in_dccm_r            ( addr_in_dccm_r            ),
    .addr_in_pic_d             ( addr_in_pic_d             ),
    .addr_in_pic_m             ( addr_in_pic_m             ),
    .addr_in_pic_r             ( addr_in_pic_r             ),
    .addr_external_m           ( addr_external_m           ),
    .lsu_trigger_match_m       ( lsu_trigger_match_m       ),
    .pmu_in                    ( pmu_in                    ),
    .pmu_out                   ( pmu_out                   ),
    .fir_in                    ( fir_in                    ),
    .fir_out                   ( fir_out                   )
  );

  task automatic step_clk();
    @(posedge clk_i);
    #1;
  endtask

  task automatic reset_dut();
    rst_ni                 = 1'b0;
    clk_override           = 1'b0;
    lsu_ld_data_r          = 32'h0;
    lsu_ld_data_corr_r     = 32'h0;
    lsu_single_ecc_error_r = 1'b0;
    lsu_double_ecc_error_r = 1'b0;
    lsu_ld_data_m          = 32'h0;
    lsu_single_ecc_error_m = 1'b0;
    lsu_double_ecc_error_m = 1'b0;
    flush_m_up             = 1'b0;
    flush_r                = 1'b0;
    exu_lsu_rs1_d          = 32'h0;
    exu_lsu_rs2_d          = 32'h0;
    lsu_p                  = '0;
    dec_lsu_valid_raw_d    = 1'b0;
    dec_lsu_offset_d       = 12'h0;
    picm_mask_data_m       = 32'hFFFF_FFFF;
    bus_read_data_m        = 32'h0;
    dec_tlu_mrac_ff        = 32'h0;
    dma_dccm_req           = 1'b0;
    dma_mem_addr           = 32'h0;
    dma_mem_sz             = 3'b0;
    dma_mem_write          = 1'b0;
    dma_mem_wdata          = 64'h0;
    lsu_pmp_error_start    = 1'b0;
    lsu_pmp_error_end      = 1'b0;
    trigger_pkt            = '0;
    pmu_in                 = 8'h5C;
    fir_in                 = 8'hA3;
    repeat (3) @(posedge clk_i);
    #1;
    rst_ni = 1'b1;
    #1;
  endtask

  int seed = 1;
  int checks = 0;

  initial begin
    if (!$value$plusargs("SEED=%d", seed)) seed = 1;

    // -----------------------------------------------------------------------
    // Phase 1: Transparent channels & Region Classification + Fault Priority
    // -----------------------------------------------------------------------
    reset_dut();
    if (pmu_out !== 8'h5C || fir_out !== 8'hA3)
      $fatal(1, "TB_FAIL: transparent sideband channel mismatch");

    // 1a: Region predication fault (mscause = 4'h5):
    // Base rs1_d in DCCM region 0xf (0xF000_0010), offset -32 (12'hFE0) -> start_addr_d = 0xEFFF_FFF0 (region 0xe!)
    dec_lsu_valid_raw_d = 1'b1;
    exu_lsu_rs1_d       = 32'hF000_0010;
    dec_lsu_offset_d    = 12'hFE0;
    lsu_p               = '0;
    lsu_p.valid         = 1'b1;
    lsu_p.load          = 1'b1;
    lsu_p.word          = 1'b1;
    #1;
    step_clk(); // Now in M-stage
    dec_lsu_valid_raw_d = 1'b0;
    lsu_p               = '0;
    if (!lsu_exc_m)
      $fatal(1, "TB_FAIL: P1 expected lsu_exc_m=1 on region predication fault");
    step_clk(); // Now in R-stage
    if (!lsu_error_pkt_r.exc_valid || !lsu_error_pkt_r.exc_type || lsu_error_pkt_r.mscause !== 4'h5 || lsu_error_pkt_r.addr !== 32'hEFFF_FFF0)
      $fatal(1, "TB_FAIL: P1 regpred fault packet mismatch (vld=%b type=%b mscause=%h addr=%h)",
             lsu_error_pkt_r.exc_valid, lsu_error_pkt_r.exc_type, lsu_error_pkt_r.mscause, lsu_error_pkt_r.addr);
    checks++;

    // 1b: PIC non-word access fault (mscause = 4'h6) vs PMP error (mscause = 4'h3) priority:
    // Halfword load at PIC address 0xF00C_0000:
    // First without PMP error -> mscause = 4'h6
    dec_lsu_valid_raw_d = 1'b1;
    exu_lsu_rs1_d       = 32'hF00C_0000;
    dec_lsu_offset_d    = 12'h000;
    lsu_p               = '0;
    lsu_p.valid         = 1'b1;
    lsu_p.load          = 1'b1;
    lsu_p.half          = 1'b1;
    #1;
    if (!addr_in_pic_d || addr_in_dccm_d)
      $fatal(1, "TB_FAIL: P1 expected addr_in_pic_d=1");
    step_clk(); // M-stage
    // In D-stage now test same access WITH lsu_pmp_error_start=1 -> mpu_access_fault_d (4'h3) has higher priority than picm (4'h6)!
    lsu_pmp_error_start = 1'b1;
    step_clk(); // R-stage for first (4'h6), M-stage for second (4'h3)
    dec_lsu_valid_raw_d = 1'b0;
    lsu_p               = '0;
    lsu_pmp_error_start = 1'b0;
    if (!lsu_error_pkt_r.exc_valid || lsu_error_pkt_r.mscause !== 4'h6)
      $fatal(1, "TB_FAIL: P1 expected mscause=4'h6 for PIC halfword access, got %h", lsu_error_pkt_r.mscause);
    step_clk(); // R-stage for second (4'h3)
    if (!lsu_error_pkt_r.exc_valid || lsu_error_pkt_r.mscause !== 4'h3)
      $fatal(1, "TB_FAIL: P1 expected mscause=4'h3 when PMP error & PIC fault both active, got %h", lsu_error_pkt_r.mscause);
    checks++;

    // 1c: Misaligned fault priority over access fault, and region-cross (4'h2) vs side-effect misaligned (4'h1):
    // Enable side-effects on region 0x1 (csr_idx = {4'h1, 1'b1} = 5'd3 -> dec_tlu_mrac_ff[3] = 1'b1)
    dec_tlu_mrac_ff     = 32'h0000_0008;
    dec_lsu_valid_raw_d = 1'b1;
    exu_lsu_rs1_d       = 32'h1000_0002; // unaligned word in region 0x1
    dec_lsu_offset_d    = 12'h000;
    lsu_p               = '0;
    lsu_p.valid         = 1'b1;
    lsu_p.store         = 1'b1;
    lsu_p.word          = 1'b1;
    lsu_pmp_error_start = 1'b1; // Also trigger access fault! Misaligned must win (exc_type=0, mscause=4'h1)!
    step_clk(); // M-stage
    if (!is_sideeffects_m || !lsu_exc_m)
      $fatal(1, "TB_FAIL: P1 expected is_sideeffects_m=1 and lsu_exc_m=1");
    // Next in D-stage: region-cross misaligned word at 0x1FFF_FFFE (crosses 0x1 -> 0x2) in side-effect region 0x1
    // Both regcross_misaligned_fault_d (4'h2) and sideeffect_misaligned_fault_d (4'h1) are active; regcross (4'h2) must win!
    exu_lsu_rs1_d       = 32'h1FFF_FFFE;
    lsu_pmp_error_start = 1'b0;
    step_clk(); // R-stage for first (4'h1), M-stage for second (4'h2)
    dec_lsu_valid_raw_d = 1'b0;
    lsu_p               = '0;
    if (!lsu_error_pkt_r.exc_valid || lsu_error_pkt_r.exc_type !== 1'b0 || lsu_error_pkt_r.inst_type !== 1'b1 || lsu_error_pkt_r.mscause !== 4'h1)
      $fatal(1, "TB_FAIL: P1 sideeffect misaligned fault packet mismatch (vld=%b type=%b inst=%b mscause=%h)",
             lsu_error_pkt_r.exc_valid, lsu_error_pkt_r.exc_type, lsu_error_pkt_r.inst_type, lsu_error_pkt_r.mscause);
    step_clk(); // R-stage for second (4'h2)
    if (!lsu_error_pkt_r.exc_valid || lsu_error_pkt_r.exc_type !== 1'b0 || lsu_error_pkt_r.mscause !== 4'h2)
      $fatal(1, "TB_FAIL: P1 regcross misaligned fault packet mismatch (vld=%b type=%b mscause=%h)",
             lsu_error_pkt_r.exc_valid, lsu_error_pkt_r.exc_type, lsu_error_pkt_r.mscause);
    checks++;

    // -----------------------------------------------------------------------
    // Phase 2: Fast-Interrupt (fast_int) Flush Immunity & lsu_fir_error Encoding
    // -----------------------------------------------------------------------
    reset_dut();
    // 2a: fast_int in D-stage when flush_m_up=1 must NOT be killed in D-stage!
    // Test fir_dccm_access_error (start_addr in 0xf region but outside DCCM: 0xF005_0000 -> lsu_fir_error = 2'b10)
    dec_lsu_valid_raw_d = 1'b1;
    exu_lsu_rs1_d       = 32'hF005_0000;
    lsu_p               = '0;
    lsu_p.valid         = 1'b1;
    lsu_p.load          = 1'b1;
    lsu_p.word          = 1'b1;
    lsu_p.fast_int      = 1'b1;
    flush_m_up          = 1'b1; // flush_m_up high in D-stage! fast_int must survive D->M!
    step_clk(); // M-stage
    flush_m_up          = 1'b0;
    // In D-stage now issue fast_int outside DCCM region (0x1000_0000 -> fir_nondccm_access_error -> 2'b11)
    exu_lsu_rs1_d       = 32'h1000_0000;
    step_clk(); // R-stage for first (2'b10), M-stage for second (2'b11)
    if (lsu_fir_error !== 2'b10 || lsu_error_pkt_r.exc_valid !== 1'b0)
      $fatal(1, "TB_FAIL: P2 expected lsu_fir_error=2'b10 and exc_valid=0 on fast_int dccm error (got fir=%b exc=%b)",
             lsu_fir_error, lsu_error_pkt_r.exc_valid);
    // In D-stage now issue valid DCCM fast_int (0xF004_0100) that will get double ECC error in M-stage -> 2'b01
    exu_lsu_rs1_d       = 32'hF004_0100;
    step_clk(); // R-stage for second (2'b11), M-stage for third
    dec_lsu_valid_raw_d = 1'b0;
    lsu_p               = '0;
    if (lsu_fir_error !== 2'b11)
      $fatal(1, "TB_FAIL: P2 expected lsu_fir_error=2'b11 on fast_int nondccm error, got %b", lsu_fir_error);
    lsu_double_ecc_error_m = 1'b1;
    step_clk(); // R-stage for third (2'b01)
    lsu_double_ecc_error_m = 1'b0;
    lsu_ld_data_corr_r     = 32'hABCD_EF02;
    #1;
    if (lsu_fir_error !== 2'b01 || lsu_fir_addr !== 31'h55E6_F781)
      $fatal(1, "TB_FAIL: P2 expected lsu_fir_error=2'b01 and lsu_fir_addr=55e6f781 (got fir=%b addr=%h)",
             lsu_fir_error, lsu_fir_addr);
    checks++;

    // -----------------------------------------------------------------------
    // Phase 3: Bypass Forwarding, Sign/Zero Load Extension, PIC Mask, & Hardware Triggers
    // -----------------------------------------------------------------------
    reset_dut();
    // Configure Trigger 0: store data match (select=1, store=1, m=1, match=0 exact) on 32'h0000_BEEF
    trigger_pkt[0].m       = 1'b1;
    trigger_pkt[0].store   = 1'b1;
    trigger_pkt[0].select  = 1'b1;
    trigger_pkt[0].match   = 1'b0;
    trigger_pkt[0].tdata2  = 32'h0000_BEEF;

    // Configure Trigger 1: load address prefix mask match (select=0, load=1, m=1, match=1 masken)
    // tdata2 = 32'hF004_02FF (bottom 0s after bit 8: mask bits [31:9], match against 0xF004_02xx)
    trigger_pkt[1].m       = 1'b1;
    trigger_pkt[1].load    = 1'b1;
    trigger_pkt[1].select  = 1'b0;
    trigger_pkt[1].match   = 1'b1;
    trigger_pkt[1].tdata2  = 32'hF004_02FF;

    // Issue halfword store to DCCM 0xF004_0200 with exu_lsu_rs2_d = 32'hDEAD_BEEF:
    // Because it is a halfword store (lsu_pkt_m.half=1, word=0), el2_lsu_trigger must zero upper 16 bits [31:16],
    // producing store_data_trigger_m = 32'h0000_BEEF, which matches Trigger 0 (tdata2 = 32'h0000_BEEF)!
    dec_lsu_valid_raw_d = 1'b1;
    exu_lsu_rs1_d       = 32'hF004_0200;
    exu_lsu_rs2_d       = 32'hDEAD_BEEF;
    lsu_p               = '0;
    lsu_p.valid         = 1'b1;
    lsu_p.store         = 1'b1;
    lsu_p.half          = 1'b1;
    step_clk(); // Now halfword store is in M-stage!
    #1;
    if (lsu_trigger_match_m !== 4'b0001)
      $fatal(1, "TB_FAIL: P3 expected Trigger 0 to match size-masked halfword store data (got %b)", lsu_trigger_match_m);

    // Now issue a signed byte load in D-stage that uses load_ldst_bypass_d=1 from M-stage lsu_result_m!
    // Set M-stage lsu_ld_data_m to 32'hF004_0284 and make M-stage packet look like a word load?
    // Wait: currently M-stage has the halfword store. Let's put a signed byte load into M-stage first!
    exu_lsu_rs1_d = 32'hF004_0210;
    lsu_p         = '0;
    lsu_p.valid   = 1'b1;
    lsu_p.load    = 1'b1;
    lsu_p.by      = 1'b1;
    lsu_p.unsign  = 1'b0;
    step_clk(); // Signed byte load is now in M-stage at 0xF004_0210!
    lsu_ld_data_m = 32'h0000_0080; // signed byte 0x80 -> sign-extended lsu_result_m = 32'hFFFF_FF80!
    // In D-stage, issue a store with store_data_bypass_d=1 (captures lsu_result_m = 32'hFFFF_FF80 into store_data_pre_m)
    exu_lsu_rs1_d             = 32'hF00C_0004; // PIC word store
    lsu_p                     = '0;
    lsu_p.valid               = 1'b1;
    lsu_p.store               = 1'b1;
    lsu_p.word                = 1'b1;
    lsu_p.store_data_bypass_d = 1'b1;
    #1;
    if (lsu_result_m !== 32'hFFFF_FF80 || lsu_trigger_match_m !== 4'b0010)
      $fatal(1, "TB_FAIL: P3 signed byte lsu_result_m (%h) or Trigger 1 load match (%b) failed",
             lsu_result_m, lsu_trigger_match_m);
    step_clk(); // PIC word store is now in M-stage; signed byte load is in R-stage!
    dec_lsu_valid_raw_d    = 1'b0;
    lsu_p                  = '0;
    picm_mask_data_m       = 32'h0000_000F; // PIC mask in M-stage!
    lsu_ld_data_corr_r     = 32'h0000_0080;
    lsu_single_ecc_error_r = 1'b1;
    #1;
    // In M-stage: addr_in_pic_m=1, so store_data_m = picm_mask_data_m & store_data_pre_m = 32'h0000_000F & 32'hFFFF_FF80 = 32'h0000_0000!
    // Wait: let's set picm_mask_data_m = 32'h00FF_00FF -> 32'h00FF_00FF & 32'hFFFF_FF80 = 32'h00FF_0080!
    picm_mask_data_m = 32'h00FF_00FF;
    #1;
    if (store_data_m !== 32'h00FF_0080 || lsu_result_corr_r !== 32'hFFFF_FF80 || !lsu_commit_r || !lsu_single_ecc_error_incr)
      $fatal(1, "TB_FAIL: P3 PIC store mask (%h), R-stage corr (%h), commit (%b), or single_ecc_incr (%b) failed",
             store_data_m, lsu_result_corr_r, lsu_commit_r, lsu_single_ecc_error_incr);
    checks++;

    // -----------------------------------------------------------------------
    // Phase 4: DMA Write-Data Shift, DMA Trigger/Fault Suppression, & Flush Immunity
    // -----------------------------------------------------------------------
    reset_dut();
    trigger_pkt[0].m      = 1'b1;
    trigger_pkt[0].store  = 1'b1;
    trigger_pkt[0].select = 1'b0;
    trigger_pkt[0].match  = 1'b0;
    trigger_pkt[0].tdata2 = 32'hF004_0003;

    // Issue DMA byte write at unaligned address 0xF004_0003 with 64-bit data 64'h11223344_55667788:
    // Shifted right by {3'd3, 3'b000} = 24 bits -> lower 32 bits = 32'h4455_6677!
    dma_dccm_req        = 1'b1;
    dma_mem_addr        = 32'hF004_0003;
    dma_mem_sz          = 3'b010; // word size (unaligned at 0x3, but DMA must NOT fault!)
    dma_mem_write       = 1'b1;
    dma_mem_wdata       = 64'h11223344_55667788;
    lsu_pmp_error_start = 1'b1;   // DMA must ignore PMP/misaligned faults!
    flush_m_up          = 1'b1;   // DMA must NOT be flushed by flush_m_up!
    step_clk(); // DMA in M-stage
    dma_dccm_req        = 1'b0;
    lsu_pmp_error_start = 1'b0;
    #1;
    if (store_data_m !== 32'h2233_4455 || lsu_exc_m !== 1'b0 || lsu_trigger_match_m !== 4'b0000)
      $fatal(1, "TB_FAIL: P4 DMA shift (%h), exc suppression (%b), or trigger suppression (%b) failed",
             store_data_m, lsu_exc_m, lsu_trigger_match_m);
    step_clk(); // DMA in R-stage
    flush_m_up = 1'b0;
    lsu_single_ecc_error_r = 1'b1;
    #1;
    // DMA in R-stage must NOT assert lsu_commit_r, NOT assert lsu_error_pkt_r, but MUST assert lsu_single_ecc_error_incr on single ECC error!
    if (lsu_commit_r !== 1'b0 || lsu_error_pkt_r.exc_valid !== 1'b0 || lsu_error_pkt_r.single_ecc_error !== 1'b0 || lsu_single_ecc_error_incr !== 1'b1)
      $fatal(1, "TB_FAIL: P4 DMA R-stage commit/error/ecc_incr mismatch (commit=%b exc=%b secc=%b incr=%b)",
             lsu_commit_r, lsu_error_pkt_r.exc_valid, lsu_error_pkt_r.single_ecc_error, lsu_single_ecc_error_incr);
    checks++;

    $display("TB_PASS seed=%0d checks=%0d", seed, checks);
    $finish;
  end
endmodule
