`timescale 1ns/1ps

module tb #(
  parameter int SEED = 101
);
  import ibex_pkg::*;
  import ibex_cheriot_pkg::*;

  logic                     clk_i;
  logic                     rst_ni;
  ibex_mubi_t               cheriot_enable_i;
  logic                     debug_mode_i;

  pmp_cfg_t                 csr_pmp_cfg_i     [4];
  logic [PMP_ADDR_MSB:0]    csr_pmp_addr_i    [4];
  pmp_mseccfg_t             csr_pmp_mseccfg_i;
  priv_lvl_e                priv_mode_if_i;
  priv_lvl_e                priv_mode_lsu_i;
  logic [PMP_ADDR_MSB:0]    pmp_req_addr_if_i;
  logic                     pmp_req_err_if_o;
  logic                     pmp_req_err_dside_o;

  logic                     data_req_o;
  logic                     data_gnt_i;
  logic                     data_rvalid_i;
  logic                     data_bus_err_i;
  logic [31:0]              data_addr_o;
  logic                     data_we_o;
  logic [3:0]               data_be_o;
  logic [38:0]              data_wdata_o;
  logic                     data_tag_o;
  logic [38:0]              data_rdata_i;
  logic                     data_tag_i;

  logic                     lsu_req_i;
  logic                     lsu_we_i;
  logic                     lsu_is_cap_i;
  logic                     lsu_cheriot_err_i;
  logic [1:0]               lsu_type_i;
  logic [31:0]              lsu_wdata_i;
  cap_t                     lsu_wcap_i;
  cap_clrperm_t             lsu_lc_clrperm_i;
  logic                     lsu_sign_ext_i;
  logic [31:0]              base_addr_ex_i;

  logic                     addr_incr_req_o;
  logic [31:0]              addr_last_o;
  logic                     lsu_req_done_o;
  logic                     lsu_resp_valid_o;
  logic                     load_err_o;
  logic                     load_resp_intg_err_o;
  logic                     store_err_o;
  logic                     store_resp_intg_err_o;
  logic                     lsu_err_is_cheriot_o;
  logic                     lsu_busy_o;
  logic                     perf_load_o;
  logic                     perf_store_o;

  logic                     en_wb_i;
  wb_instr_type_e           instr_type_wb_i;
  logic [31:0]              pc_id_i;
  logic                     instr_is_compressed_id_i;
  logic                     instr_perf_count_id_i;
  logic                     instr_is_cheriot_i;
  logic                     cheriot_load_i;
  logic                     cheriot_store_i;
  logic [4:0]               rf_waddr_id_i;
  logic [31:0]              rf_wdata_id_i;
  logic                     rf_we_id_i;
  logic                     cheriot_rf_we_i;
  logic [31:0]              cheriot_rf_wdata_i;
  cap_t                     cheriot_rf_wcap_i;
  logic                     dummy_instr_id_i;

  logic                     ready_wb_o;
  logic                     rf_write_wb_o;
  logic                     outstanding_load_wb_o;
  logic                     outstanding_store_wb_o;
  logic [31:0]              pc_wb_o;
  logic                     perf_instr_ret_wb_o;
  logic                     perf_instr_ret_compressed_wb_o;
  logic                     perf_instr_ret_wb_spec_o;
  logic                     perf_instr_ret_compressed_wb_spec_o;
  logic [31:0]              rf_wdata_fwd_wb_o;
  cap_t                     rf_wcap_fwd_wb_o;
  logic [4:0]               rf_waddr_wb_o;
  logic [31:0]              rf_wdata_wb_o;
  cap_t                     rf_wcap_wb_o;
  logic                     rf_we_wb_o;
  logic                     dummy_instr_wb_o;
  logic                     instr_done_wb_o;

  // Helper SECDED encoder
  function automatic logic [38:0] secded_enc(input logic [31:0] d);
    logic [38:0] o;
    o = 39'(d);
    o[32] = ^(o & 39'h002606BD25);
    o[33] = ^(o & 39'h00DEBA8050);
    o[34] = ^(o & 39'h00413D89AA);
    o[35] = ^(o & 39'h0031234ED1);
    o[36] = ^(o & 39'h00C2C1323B);
    o[37] = ^(o & 39'h002DCC624C);
    o[38] = ^(o & 39'h0098505586);
    o ^= 39'h2A00000000;
    return o;
  endfunction

  ibex_lsu_wb_pmp_top dut (.*);

  initial begin
    clk_i = 1'b0;
    forever #2.5 clk_i = ~clk_i;
  end

  task automatic fail_msg(input string msg);
    $display("TB_FAIL: %s (time=%0t)", msg, $time);
    $finish(1);
  endtask

  task automatic reset_dut();
    rst_ni                   = 1'b0;
    cheriot_enable_i         = IbexMuBiOn;
    debug_mode_i             = 1'b0;
    for (int i = 0; i < 4; i++) begin
      csr_pmp_cfg_i[i]  = '{lock: 1'b0, mode: PMP_MODE_OFF, exec: 1'b0, write: 1'b0, read: 1'b0};
      csr_pmp_addr_i[i] = 34'h0;
    end
    csr_pmp_mseccfg_i        = '{rlb: 1'b0, mmwp: 1'b0, mml: 1'b0};
    priv_mode_if_i           = PRIV_LVL_M;
    priv_mode_lsu_i          = PRIV_LVL_M;
    pmp_req_addr_if_i        = 34'h0;
    data_gnt_i               = 1'b0;
    data_rvalid_i            = 1'b0;
    data_bus_err_i           = 1'b0;
    data_rdata_i             = secded_enc(32'h0);
    data_tag_i               = 1'b0;
    lsu_req_i                = 1'b0;
    lsu_we_i                 = 1'b0;
    lsu_is_cap_i            = 1'b0;
    lsu_cheriot_err_i        = 1'b0;
    lsu_type_i               = 2'b00;
    lsu_wdata_i              = 32'h0;
    lsu_wcap_i               = NULL_CAP;
    lsu_lc_clrperm_i         = 4'b0000;
    lsu_sign_ext_i           = 1'b0;
    base_addr_ex_i           = 32'h0;
    en_wb_i                  = 1'b0;
    instr_type_wb_i          = WB_INSTR_OTHER;
    pc_id_i                  = 32'h0;
    instr_is_compressed_id_i = 1'b0;
    instr_perf_count_id_i    = 1'b1;
    instr_is_cheriot_i       = 1'b0;
    cheriot_load_i           = 1'b0;
    cheriot_store_i          = 1'b0;
    rf_waddr_id_i            = 5'h0;
    rf_wdata_id_i            = 32'h0;
    rf_we_id_i               = 1'b0;
    cheriot_rf_we_i          = 1'b0;
    cheriot_rf_wdata_i       = 32'h0;
    cheriot_rf_wcap_i        = NULL_CAP;
    dummy_instr_id_i         = 1'b0;
    repeat (4) @(posedge clk_i);
    rst_ni = 1'b1;
    @(posedge clk_i);
  endtask

  initial begin
    cap_t test_cap;
    logic [32:0] cap_msw_mem;
    int unsigned rng;
    rng = SEED ^ 32'h9E37_79B9;

    reset_dut();

    // =========================================================================
    // Test 1: Smepmp (mml, mmwp), TOR inverted bounds, and Debug-Mode bypass
    // =========================================================================
    // 1A: Smepmp mml=1, unmatched M-mode EXEC must fault, while unmatched M-mode READ succeeds (when mmwp=0)
    csr_pmp_mseccfg_i = '{rlb: 1'b0, mmwp: 1'b0, mml: 1'b1};
    priv_mode_if_i    = PRIV_LVL_M;
    priv_mode_lsu_i   = PRIV_LVL_M;
    pmp_req_addr_if_i = 34'h0_0001_0000;
    base_addr_ex_i    = 32'h0001_0000;
    lsu_we_i          = 1'b0;
    #1;
    if (pmp_req_err_if_o !== 1'b1)
      fail_msg("Smepmp mml=1 unmatched M-mode EXEC did not fault");
    if (pmp_req_err_dside_o !== 1'b0)
      fail_msg("Smepmp mml=1 mmwp=0 unmatched M-mode READ unexpectedly faulted");

    // 1B: Debug mode bypass in [32'h1A110000, 32'h1A110FFF]
    debug_mode_i      = 1'b1;
    pmp_req_addr_if_i = 34'h0_1A11_0800;
    #1;
    if (pmp_req_err_if_o !== 1'b0)
      fail_msg("Debug mode access inside DmBaseAddr range was blocked by PMP");
    debug_mode_i      = 1'b0;
    #1;
    if (pmp_req_err_if_o !== 1'b1)
      fail_msg("Non-debug access to DmBaseAddr with mml=1 unmatched EXEC did not fault");

    // 1C: Smepmp shared region R=0, W=1, {lock, exec} = 2'b00 -> Read/Write in M, Read-only in U
    csr_pmp_cfg_i[0]  = '{lock: 1'b0, mode: PMP_MODE_NAPOT, exec: 1'b0, write: 1'b1, read: 1'b0};
    csr_pmp_addr_i[0] = 34'h0_2000_0000 | 34'h0_0000_07FC; // 4KB NAPOT at 0x2000_0000 (byte address with bits [10:2] = 1)
    base_addr_ex_i    = 32'h2000_0100;
    priv_mode_lsu_i   = PRIV_LVL_M;
    lsu_we_i          = 1'b1;
    #1;
    if (pmp_req_err_dside_o !== 1'b0)
      fail_msg("Smepmp shared region 2'b00 M-mode write faulted");
    priv_mode_lsu_i   = PRIV_LVL_U;
    lsu_we_i          = 1'b0;
    #1;
    if (pmp_req_err_dside_o !== 1'b0)
      fail_msg("Smepmp shared region 2'b00 U-mode read faulted");
    lsu_we_i          = 1'b1;
    #1;
    if (pmp_req_err_dside_o !== 1'b1)
      fail_msg("Smepmp shared region 2'b00 U-mode write was illegally allowed");

    // 1D: Non-shared region under mml=1: R=1, W=1, X=0, L=0 -> U-mode allowed, M-mode denied!
    csr_pmp_cfg_i[0]  = '{lock: 1'b0, mode: PMP_MODE_NAPOT, exec: 1'b0, write: 1'b1, read: 1'b1};
    priv_mode_lsu_i   = PRIV_LVL_M;
    lsu_we_i          = 1'b0;
    #1;
    if (pmp_req_err_dside_o !== 1'b1)
      fail_msg("Smepmp non-shared unlocked region failed to deny M-mode access");
    priv_mode_lsu_i   = PRIV_LVL_U;
    #1;
    if (pmp_req_err_dside_o !== 1'b0)
      fail_msg("Smepmp non-shared unlocked region failed to allow U-mode access");

    // 1E: TOR inverted bounds (csr_pmp_addr_i[1] < csr_pmp_addr_i[0]) must NEVER match
    csr_pmp_mseccfg_i = '{rlb: 1'b0, mmwp: 1'b0, mml: 1'b0};
    csr_pmp_cfg_i[0]  = '{lock: 1'b0, mode: PMP_MODE_OFF, exec: 1'b0, write: 1'b0, read: 1'b0};
    csr_pmp_addr_i[0] = 34'h0_4000_0000;
    csr_pmp_cfg_i[1]  = '{lock: 1'b1, mode: PMP_MODE_TOR, exec: 1'b0, write: 1'b0, read: 1'b0};
    csr_pmp_addr_i[1] = 34'h0_3000_0000; // top < start!
    priv_mode_lsu_i   = PRIV_LVL_M;
    base_addr_ex_i    = 32'h5000_0000;
    #1;
    if (pmp_req_err_dside_o !== 1'b0)
      fail_msg("TOR region with inverted bounds (pmpaddr[1] < pmpaddr[0]) falsely matched");
    csr_pmp_cfg_i[0]  = '{lock: 1'b0, mode: PMP_MODE_OFF, exec: 1'b0, write: 1'b0, read: 1'b0};
    csr_pmp_cfg_i[1]  = '{lock: 1'b0, mode: PMP_MODE_OFF, exec: 1'b0, write: 1'b0, read: 1'b0};

    // =========================================================================
    // Test 2: Misaligned word store & load across word boundary (offsets 01, 10, 11)
    // =========================================================================
    @(posedge clk_i);
    #1;
    base_addr_ex_i  = 32'h0000_1001; // offset 2'b01
    lsu_type_i      = 2'b00;         // word
    lsu_we_i        = 1'b1;
    lsu_wdata_i     = 32'hA1B2_C3D4;
    lsu_req_i       = 1'b1;
    data_gnt_i      = 1'b1;
    #1;
    if (data_req_o !== 1'b1 || data_addr_o !== 32'h0000_1000 || data_be_o !== 4'b1110 || data_wdata_o !== secded_enc(32'hB2C3_D4A1))
      fail_msg($sformatf("Misaligned word store beat 1 signals incorrect: req=%b addr=%h be=%b wdata=%h", data_req_o, data_addr_o, data_be_o, data_wdata_o));
    @(posedge clk_i);
    #1;
    // Now in WAIT_RVALID_MIS: second beat request asserted with addr_incr_req_o=1
    if (data_req_o !== 1'b1 || addr_incr_req_o !== 1'b1 || data_addr_o !== 32'h0000_1004 || data_be_o !== 4'b0001)
      fail_msg($sformatf("Misaligned word store beat 2 signals incorrect: be=%b addr=%h", data_be_o, data_addr_o));
    data_rvalid_i   = 1'b1;
    data_gnt_i      = 1'b1;
    #1;
    if (lsu_req_done_o !== 1'b1)
      fail_msg("lsu_req_done_o not asserted on second beat grant+rvalid1");
    @(posedge clk_i);
    #1;
    lsu_req_i       = 1'b0;
    data_gnt_i      = 1'b0;
    data_rvalid_i   = 1'b1;
    #1;
    if (lsu_resp_valid_o !== 1'b1 || store_err_o !== 1'b0)
      fail_msg("Misaligned word store failed to complete on second rvalid");
    @(posedge clk_i);
    #1;
    data_rvalid_i   = 1'b0;

    // =========================================================================
    // Test 3: Misaligned first-beat fault vs second-beat fault addr_last_o retention
    // =========================================================================
    // 3A: First beat faults with bus error while second beat is granted in WAIT_RVALID_MIS
    @(posedge clk_i);
    #1;
    base_addr_ex_i  = 32'h0000_2002; // unaligned address
    lsu_type_i      = 2'b00;
    lsu_we_i        = 1'b0;
    lsu_req_i       = 1'b1;
    data_gnt_i      = 1'b1;
    @(posedge clk_i);
    #1;
    // In WAIT_RVALID_MIS: beat 1 returns with data_bus_err_i = 1 while beat 2 gets data_gnt_i = 1
    data_rvalid_i   = 1'b1;
    data_bus_err_i  = 1'b1;
    data_gnt_i      = 1'b1;
    @(posedge clk_i);
    #1;
    lsu_req_i       = 1'b0;
    data_gnt_i      = 1'b0;
    data_bus_err_i  = 1'b0;
    data_rvalid_i   = 1'b1;
    #1;
    if (load_err_o !== 1'b1 || addr_last_o !== 32'h0000_2002)
      fail_msg($sformatf("Test 3A: First-beat bus error in WAIT_RVALID_MIS overwrote addr_last_o=%h (expected 00002002)", addr_last_o));
    @(posedge clk_i);
    #1;
    data_rvalid_i   = 1'b0;

    // 3B: First beat faults with bus error when second beat is NOT yet granted (goes to WAIT_GNT)
    @(posedge clk_i);
    #1;
    base_addr_ex_i  = 32'h0000_3003;
    lsu_type_i      = 2'b01; // halfword at offset 2'b11 -> split!
    lsu_we_i        = 1'b0;
    lsu_req_i       = 1'b1;
    data_gnt_i      = 1'b1;
    @(posedge clk_i);
    #1;
    // In WAIT_RVALID_MIS: beat 1 returns with data_bus_err_i = 1 while data_gnt_i = 0 -> transitions to WAIT_GNT
    data_rvalid_i   = 1'b1;
    data_bus_err_i  = 1'b1;
    data_gnt_i      = 1'b0;
    @(posedge clk_i);
    #1;
    // Now in WAIT_GNT: grant beat 2
    data_rvalid_i   = 1'b0;
    data_bus_err_i  = 1'b0;
    data_gnt_i      = 1'b1;
    @(posedge clk_i);
    #1;
    lsu_req_i       = 1'b0;
    data_gnt_i      = 1'b0;
    data_rvalid_i   = 1'b1;
    #1;
    if (load_err_o !== 1'b1 || addr_last_o !== 32'h0000_3003)
      fail_msg($sformatf("Test 3B: First-beat bus error via WAIT_GNT overwrote addr_last_o=%h (expected 00003003)", addr_last_o));
    @(posedge clk_i);
    #1;
    data_rvalid_i   = 1'b0;

    // 3C: First beat succeeds, second beat faults -> addr_last_o MUST update to 32'h0000_4004
    @(posedge clk_i);
    #1;
    base_addr_ex_i  = 32'h0000_4002;
    lsu_type_i      = 2'b00;
    lsu_we_i        = 1'b0;
    lsu_req_i       = 1'b1;
    data_gnt_i      = 1'b1;
    @(posedge clk_i);
    #1;
    // Beat 1 succeeds, beat 2 granted
    data_rvalid_i   = 1'b1;
    data_bus_err_i  = 1'b0;
    data_gnt_i      = 1'b1;
    @(posedge clk_i);
    #1;
    lsu_req_i       = 1'b0;
    data_gnt_i      = 1'b0;
    data_rvalid_i   = 1'b1;
    data_bus_err_i  = 1'b1; // Beat 2 faults!
    #1;
    if (load_err_o !== 1'b1 || addr_last_o !== 32'h0000_4004)
      fail_msg($sformatf("Test 3C: Second-beat fault did not update addr_last_o=%h (expected 00004004)", addr_last_o));
    @(posedge clk_i);
    #1;
    data_rvalid_i   = 1'b0;
    data_bus_err_i  = 1'b0;

    // =========================================================================
    // Test 4 & 5: CHERIoT 64-bit Capability Load + Writeback Stage Completion & Fault Gating
    // =========================================================================
    test_cap = '{
      cap_cor: 2'b00,
      valid:   1'b1,
      rsvd:    1'b0,
      cperms:  6'b111111,
      otype:   3'b000,
      cexp:    4'd0,
      top:     9'h180,
      base:    9'h000
    };
    cap_msw_mem = cheriot_cap_to_mem(test_cap);

    // 4A: Valid CHERIoT capability load through LSU + Writeback Stage
    @(posedge clk_i);
    #1;
    base_addr_ex_i     = 32'h0000_8000;
    lsu_is_cap_i       = 1'b1;
    lsu_we_i           = 1'b0;
    lsu_req_i          = 1'b1;
    data_gnt_i         = 1'b1;
    en_wb_i            = 1'b1;
    instr_type_wb_i    = WB_INSTR_OTHER;
    instr_is_cheriot_i = 1'b1;
    cheriot_load_i     = 1'b1;
    cheriot_store_i    = 1'b0;
    rf_waddr_id_i      = 5'd7;
    instr_perf_count_id_i = 1'b1;
    @(posedge clk_i);
    #1;
    en_wb_i            = 1'b0;
    // Now in CTX_WAIT_GNT2 and WB has the CHERIoT load pending!
    #1;
    if (ready_wb_o !== 1'b0 || outstanding_load_wb_o !== 1'b1 || instr_done_wb_o !== 1'b0)
      fail_msg("Test 4A: Writeback stage did not stall for pending CHERIoT capability load");
    // Grant beat 2 and return beat 1 (LSW)
    data_gnt_i         = 1'b1;
    data_rvalid_i      = 1'b1;
    data_rdata_i       = secded_enc(32'h0000_8040);
    data_tag_i         = 1'b1;
    @(posedge clk_i);
    #1;
    lsu_req_i          = 1'b0;
    lsu_is_cap_i       = 1'b0;
    data_gnt_i         = 1'b0;
    // Return beat 2 (MSW)
    data_rvalid_i      = 1'b1;
    data_rdata_i       = secded_enc(cap_msw_mem[31:0]);
    data_tag_i         = cap_msw_mem[32];
    #1;
    if (lsu_resp_valid_o !== 1'b1 || rf_we_wb_o !== 1'b1 || rf_wcap_wb_o.valid !== 1'b1 ||
        rf_wdata_wb_o !== 32'h0000_8040 || perf_instr_ret_wb_o !== 1'b1 || ready_wb_o !== 1'b1)
      fail_msg("Test 4A: Valid CHERIoT capability load failed to write back or retire in WB");
    @(posedge clk_i);
    #1;
    data_rvalid_i      = 1'b0;

    // 4B: CHERIoT capability load with first-beat (LSW) bus error -> must fault, suppress rf_we_wb_o, rf_wcap_wb_o = NULL_CAP, and suppress perf_instr_ret_wb_o!
    @(posedge clk_i);
    #1;
    base_addr_ex_i     = 32'h0000_8010;
    lsu_is_cap_i       = 1'b1;
    lsu_we_i           = 1'b0;
    lsu_req_i          = 1'b1;
    data_gnt_i         = 1'b1;
    en_wb_i            = 1'b1;
    instr_type_wb_i    = WB_INSTR_OTHER;
    instr_is_cheriot_i = 1'b1;
    cheriot_load_i     = 1'b1;
    rf_waddr_id_i      = 5'd8;
    @(posedge clk_i);
    #1;
    en_wb_i            = 1'b0;
    // Beat 1 returns with data_bus_err_i = 1
    data_gnt_i         = 1'b1;
    data_rvalid_i      = 1'b1;
    data_bus_err_i     = 1'b1;
    data_rdata_i       = secded_enc(32'h0000_8040);
    data_tag_i         = 1'b1;
    @(posedge clk_i);
    #1;
    lsu_req_i          = 1'b0;
    lsu_is_cap_i       = 1'b0;
    data_gnt_i         = 1'b0;
    data_bus_err_i     = 1'b0;
    data_rvalid_i      = 1'b1;
    data_rdata_i       = secded_enc(cap_msw_mem[31:0]);
    data_tag_i         = cap_msw_mem[32];
    #1;
    if (load_err_o !== 1'b1 || rf_we_wb_o !== 1'b0 || rf_wcap_wb_o.valid !== 1'b0 || perf_instr_ret_wb_o !== 1'b0)
      fail_msg("Test 4B: CHERIoT capability load with LSW bus error failed to invalidate capability or suppress retire");
    @(posedge clk_i);
    #1;
    data_rvalid_i      = 1'b0;

    // 4C: CHERIoT capability load with second-beat (MSW) SECDED integrity error -> must assert load_resp_intg_err_o, rf_we_wb_o=0, lsu_rcap_o=NULL_CAP, perf_instr_ret_wb_o=0
    @(posedge clk_i);
    #1;
    base_addr_ex_i     = 32'h0000_8020;
    lsu_is_cap_i       = 1'b1;
    lsu_we_i           = 1'b0;
    lsu_req_i          = 1'b1;
    data_gnt_i         = 1'b1;
    en_wb_i            = 1'b1;
    instr_type_wb_i    = WB_INSTR_OTHER;
    instr_is_cheriot_i = 1'b1;
    cheriot_load_i     = 1'b1;
    rf_waddr_id_i      = 5'd9;
    @(posedge clk_i);
    #1;
    en_wb_i            = 1'b0;
    data_gnt_i         = 1'b1;
    data_rvalid_i      = 1'b1;
    data_rdata_i       = secded_enc(32'h0000_8040);
    data_tag_i         = 1'b1;
    @(posedge clk_i);
    #1;
    lsu_req_i          = 1'b0;
    lsu_is_cap_i       = 1'b0;
    data_gnt_i         = 1'b0;
    data_rvalid_i      = 1'b1;
    // Flip bit 0 to inject SECDED error on MSW!
    data_rdata_i       = secded_enc(cap_msw_mem[31:0]) ^ 39'h1;
    data_tag_i         = cap_msw_mem[32];
    #1;
    if (load_resp_intg_err_o !== 1'b1 || rf_we_wb_o !== 1'b0 || dut.lsu_rcap.valid !== 1'b0 || perf_instr_ret_wb_o !== 1'b0)
      fail_msg("Test 4C: CHERIoT capability load with MSW SECDED error failed to clear lsu_rcap or suppress WB retire");
    @(posedge clk_i);
    #1;
    data_rvalid_i      = 1'b0;
    cheriot_load_i     = 1'b0;
    instr_is_cheriot_i = 1'b0;

    // =========================================================================
    // Test 6: Seed-driven randomized load/store sequence
    // =========================================================================
    for (int iter = 0; iter < 16; iter++) begin
      logic [31:0] rval;
      rng = (rng * 32'h0808_8405) + 32'd1;
      rval = rng ^ (32'(iter) << 12);
      @(posedge clk_i);
      #1;
      base_addr_ex_i  = {16'h0001, rval[15:2], 2'b00};
      lsu_type_i      = 2'b00;
      lsu_we_i        = iter[0];
      lsu_wdata_i     = rval;
      lsu_req_i       = 1'b1;
      data_gnt_i      = 1'b1;
      en_wb_i         = 1'b1;
      instr_type_wb_i = iter[0] ? WB_INSTR_STORE : WB_INSTR_LOAD;
      rf_waddr_id_i   = 5'(iter + 1);
      @(posedge clk_i);
      #1;
      lsu_req_i       = 1'b0;
      data_gnt_i      = 1'b0;
      en_wb_i         = 1'b0;
      data_rvalid_i   = 1'b1;
      data_rdata_i    = secded_enc(rval ^ 32'h5A5A_5A5A);
      #1;
      if (lsu_resp_valid_o !== 1'b1 || perf_instr_ret_wb_o !== 1'b1)
        fail_msg($sformatf("Randomized iter %0d failed", iter));
      if (!iter[0] && (rf_we_wb_o !== 1'b1 || rf_wdata_wb_o !== (rval ^ 32'h5A5A_5A5A)))
        fail_msg($sformatf("Randomized load iter %0d data mismatch", iter));
      @(posedge clk_i);
      #1;
      data_rvalid_i   = 1'b0;
    end

    $display("PASS ibex_lsu_wb_pmp_top seed=%0d", SEED);
    $finish(0);
  end

endmodule
