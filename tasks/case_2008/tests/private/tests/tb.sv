`timescale 1ns/1ps

module tb #(
  parameter int SEED = 101
);
  import ibex_pkg::*;
  import ibex_cheriot_pkg::*;
  import prim_secded_pkg::*;

  localparam int unsigned TagSizeECC  = IC_TAG_SIZE + 6;
  localparam int unsigned BusSizeECC  = BUS_SIZE + 7;
  localparam int unsigned LineSizeECC = BusSizeECC * IC_LINE_BEATS;

  logic                         clk_i;
  logic                         rst_ni;

  ibex_mubi_t                   cheriot_enable_i;
  logic [31:0]                  boot_addr_i;
  logic                         req_i;
  logic                         debug_mode_i;

  logic                         instr_req_o;
  logic [31:0]                  instr_addr_o;
  logic                         instr_gnt_i;
  logic                         instr_rvalid_i;
  logic [38:0]                  instr_rdata_i;
  logic                         instr_bus_err_i;
  logic                         instr_intg_err_o;

  logic [IC_NUM_WAYS-1:0]       ic_tag_req_o;
  logic                         ic_tag_write_o;
  logic [IC_INDEX_W-1:0]        ic_tag_addr_o;
  logic [TagSizeECC-1:0]        ic_tag_wdata_o;
  logic [TagSizeECC-1:0]        ic_tag_rdata_i [IC_NUM_WAYS];
  logic [IC_NUM_WAYS-1:0]       ic_data_req_o;
  logic                         ic_data_write_o;
  logic [IC_INDEX_W-1:0]        ic_data_addr_o;
  logic [LineSizeECC-1:0]       ic_data_wdata_o;
  logic [LineSizeECC-1:0]       ic_data_rdata_i [IC_NUM_WAYS];
  logic                         ic_scr_key_valid_i;
  logic                         ic_scr_key_req_o;

  logic                         instr_valid_id_o;
  logic                         instr_new_id_o;
  logic [31:0]                  instr_rdata_id_o;
  logic [31:0]                  instr_rdata_alu_id_o;
  logic [15:0]                  instr_rdata_c_id_o;
  logic                         instr_is_compressed_id_o;
  instr_exp_e                   instr_gets_expanded_id_o;
  logic [15:0]                  instr_expanded_id_o;
  logic                         instr_bp_taken_o;
  logic                         instr_fetch_err_o;
  logic                         instr_fetch_err_plus2_o;
  logic                         illegal_c_insn_id_o;
  logic                         instr_fetch_cheriot_acc_vio_o;
  logic                         instr_fetch_cheriot_bound_vio_o;
  logic                         dummy_instr_id_o;
  logic [31:0]                  pc_if_o;
  logic [31:0]                  pc_id_o;
  logic                         pmp_err_if_i;
  logic                         pmp_err_if_plus2_i;

  logic                         instr_valid_clear_i;
  logic                         pc_set_i;
  pc_sel_e                      pc_mux_i;
  logic                         nt_branch_mispredict_i;
  logic [31:0]                  nt_branch_addr_i;
  exc_pc_sel_e                  exc_pc_mux_i;
  exc_cause_t                   exc_cause;
  logic                         dummy_instr_en_i;
  logic [2:0]                   dummy_instr_mask_i;
  logic                         dummy_instr_seed_en_i;
  logic [31:0]                  dummy_instr_seed_i;
  logic                         icache_enable_i;
  logic                         icache_inval_i;
  logic                         icache_ecc_error_o;

  logic [31:0]                  branch_target_ex_i;
  logic [31:0]                  csr_mepc_i;
  logic [31:0]                  csr_depc_i;
  logic [31:0]                  csr_mtvec_i;
  logic                         csr_mtvec_init_o;
  logic                         id_in_ready_i;
  logic                         pc_mismatch_alert_o;
  logic                         if_busy_o;
  decoded_cap_t                 pcc_cap_i;

  logic [7:0]                   scr_mon_in;
  logic [7:0]                   scr_mon_out;
  logic [7:0]                   pmp_mon_in;
  logic [7:0]                   pmp_mon_out;

  ibex_icache_if_subsys_top dut (.*);

  // Helper SECDED encoder for 39-bit memory words
  logic [31:0] enc_in;
  logic [38:0] enc_out;
  prim_secded_inv_39_32_enc u_tb_enc (
    .data_i(enc_in),
    .data_o(enc_out)
  );

  function automatic logic [38:0] encode_word(input logic [31:0] w);
    logic [38:0] d;
    d = 39'(w);
    d[32] = ^(d & 39'h002606BD25);
    d[33] = ^(d & 39'h00DEBA8050);
    d[34] = ^(d & 39'h00413D89AA);
    d[35] = ^(d & 39'h0031234ED1);
    d[36] = ^(d & 39'h00C2C1323B);
    d[37] = ^(d & 39'h002DCC624C);
    d[38] = ^(d & 39'h0098505586);
    d ^= 39'h2A00000000;
    return d;
  endfunction

  // Synchronous 2-way Tag & Data SRAM model
  logic [TagSizeECC-1:0]  tag_sram  [IC_NUM_WAYS][1 << IC_INDEX_W];
  logic [LineSizeECC-1:0] data_sram [IC_NUM_WAYS][1 << IC_INDEX_W];
  int unsigned            inval_writes_seen;
  bit                     corrupt_data_ecc_on_hit;
  logic [TagSizeECC-1:0]  valid_tag_way0_2100;

  always_comb begin
    logic [21:0]             t_in;
    logic [27:0]             t_out;
    logic [TagSizeECC-1:0]   t_wdata;
    logic [TagSizeECC-1:0]   t_tweak;
    logic [IC_INDEX_W-1:0]   idx;
    idx   = 8'h20;
    t_in  = {{22-IC_TAG_SIZE{1'b0}}, 1'b1, 32'h0000_2100 >> (IC_INDEX_HI + 1)};
    t_out[21:0] = t_in;
    t_out[22] = ^(t_out[21:0] & 22'h0303E3);
    t_out[23] = ^(t_out[21:0] & 22'h1C780E);
    t_out[24] = ^(t_out[21:0] & 22'h29A6D1);
    t_out[25] = ^(t_out[21:0] & 22'h165B64);
    t_out[26] = ^(t_out[21:0] & 22'h35AD9A);
    t_out[27] = ^(t_out[21:0] & 22'h3A9555);
    t_out[27:22] ^= 6'h15;
    t_wdata = {t_out[27:22], t_out[IC_TAG_SIZE-1:0]};
    t_tweak = '0;
    for (int i = 0; i < IC_LINE_BEATS; i++) begin
      t_tweak |= (TagSizeECC'({idx}) << (i * (IC_INDEX_W + IC_TAG_ECC_SIZE)));
    end
    valid_tag_way0_2100 = t_wdata ^ t_tweak;
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      inval_writes_seen       <= 0;
      corrupt_data_ecc_on_hit <= 1'b0;
      for (int w = 0; w < IC_NUM_WAYS; w++) begin
        for (int idx = 0; idx < (1 << IC_INDEX_W); idx++) begin
          tag_sram[w][idx]  <= '0;
          data_sram[w][idx] <= '0; // Uninitialized data RAM (invalid ECC until written!)
        end
        ic_tag_rdata_i[w]  <= '0;
        ic_data_rdata_i[w] <= '0;
      end
    end else begin
      for (int w = 0; w < IC_NUM_WAYS; w++) begin
        if (ic_tag_req_o[w]) begin
          if (ic_tag_write_o) begin
            tag_sram[w][ic_tag_addr_o] <= ic_tag_wdata_o;
            if (w == 0) inval_writes_seen <= inval_writes_seen + 1;
          end else begin
            ic_tag_rdata_i[w] <= tag_sram[w][ic_tag_addr_o];
          end
        end
        if (ic_data_req_o[w]) begin
          if (ic_data_write_o) begin
            data_sram[w][ic_data_addr_o] <= ic_data_wdata_o;
          end else begin
            ic_data_rdata_i[w] <= data_sram[w][ic_data_addr_o] ^
                                  (corrupt_data_ecc_on_hit ? LineSizeECC'(1) : '0);
          end
        end
      end
    end
  end

  initial begin
    clk_i = 1'b0;
    forever #2.5 clk_i = ~clk_i;
  end

  task automatic fail_msg(input string msg);
    $display("TB_FAIL: %s (time=%0t)", msg, $time);
    $finish(1);
  endtask

  task automatic reset_dut();
    rst_ni                 = 1'b0;
    cheriot_enable_i       = IbexMuBiOff;
    boot_addr_i            = 32'h0000_1000;
    req_i                  = 1'b0;
    debug_mode_i           = 1'b0;
    instr_gnt_i            = 1'b0;
    instr_rvalid_i         = 1'b0;
    instr_rdata_i          = encode_word(32'h0000_0013);
    instr_bus_err_i        = 1'b0;
    ic_scr_key_valid_i     = 1'b0;
    pmp_err_if_i           = 1'b0;
    pmp_err_if_plus2_i     = 1'b0;
    instr_valid_clear_i    = 1'b0;
    pc_set_i               = 1'b0;
    pc_mux_i               = PC_BOOT;
    nt_branch_mispredict_i = 1'b0;
    nt_branch_addr_i       = 32'h0;
    exc_pc_mux_i           = EXC_PC_EXC;
    exc_cause              = ExcCauseInsnAddrMisa;
    dummy_instr_en_i       = 1'b0;
    dummy_instr_mask_i     = 3'b000;
    dummy_instr_seed_en_i  = 1'b0;
    dummy_instr_seed_i     = 32'h0;
    icache_enable_i        = 1'b1;
    icache_inval_i         = 1'b0;
    branch_target_ex_i     = 32'h0;
    csr_mepc_i             = 32'h0;
    csr_depc_i             = 32'h0;
    csr_mtvec_i            = 32'h0000_8000;
    id_in_ready_i          = 1'b1;
    pcc_cap_i              = ROOT_DECODED_CAP_TX;
    scr_mon_in             = 8'hA5 ^ SEED[7:0];
    pmp_mon_in             = 8'h5A ^ SEED[7:0];
    repeat (4) @(posedge clk_i);
    #1;
    rst_ni = 1'b1;
  endtask

  initial begin
    int timeout;
    reset_dut();

    // =========================================================================
    // Test 1: Out-of-Reset Scramble Key Request & Mid-Sweep Invalidation Restart (mutant_01, 02)
    // =========================================================================
    if (scr_mon_out !== scr_mon_in || pmp_mon_out !== pmp_mon_in)
      fail_msg("Test 0: Monitoring channel combinational feedthrough mismatch");

    // Immediately out of reset with ic_scr_key_valid_i = 0, ic_scr_key_req_o must be 1!
    if (ic_scr_key_req_o !== 1'b1)
      fail_msg("Test 1A: ic_scr_key_req_o was not asserted in OUT_OF_RESET when ic_scr_key_valid_i == 0");

    @(posedge clk_i);
    #1;
    // Now in AWAIT_SCRAMBLE_KEY: supply key
    ic_scr_key_valid_i = 1'b1;
    repeat (6) @(posedge clk_i);
    #1;
    // Mid-sweep: pulse icache_inval_i = 1 while dropping ic_scr_key_valid_i = 0!
    icache_inval_i     = 1'b1;
    ic_scr_key_valid_i = 1'b0;
    #1;
    if (ic_scr_key_req_o !== 1'b1)
      fail_msg("Test 1B: Mid-sweep icache_inval_i did not assert ic_scr_key_req_o");
    @(posedge clk_i);
    #1;
    icache_inval_i     = 1'b0;
    // Verify tag writes stop while awaiting new scramble key
    if (ic_tag_write_o !== 1'b0)
      fail_msg("Test 1B: Mid-sweep icache_inval_i did not return to AWAIT_SCRAMBLE_KEY");

    // Supply scramble key and wait for full invalidation sweep to finish (if_busy_o -> 0)
    ic_scr_key_valid_i = 1'b1;
    timeout = 0;
    while (if_busy_o === 1'b1 && timeout < 300) begin
      @(posedge clk_i);
      #1;
      timeout++;
    end
    if (if_busy_o !== 1'b0)
      fail_msg("Test 1C: ICache invalidation sweep did not complete");

    // =========================================================================
    // Test 2: Cache Miss Allocation (No Spurious Data ECC Error), Cache Hit with Tweak Infection,
    //         and Data ECC Error Recovery on Hit (mutant_03, 04, 05)
    // =========================================================================
    begin
      logic [31:0] q_addr [64];
      int          q_head, q_tail;
      bit          saw_2104_fill;
      bit          saw_2104_hit;
      bit          saw_ecc_err;
      bit          saw_2104_refill;

      q_head        = 0;
      q_tail        = 0;
      saw_2104_fill = 1'b0;
      instr_gnt_i        = 1'b1;
      branch_target_ex_i = 32'h0000_2100; // Non-zero cache index 8'h20 (exercises non-zero tag & data tweaks!)
      pc_mux_i           = PC_JUMP;

      for (int c = 0; c < 10; c++) begin
        logic [31:0] req_addr_sampled;
        bit          do_rvalid;
        pc_set_i  = (c == 0) ? 1'b1 : 1'b0;
        req_i     = (c == 0) ? 1'b1 : 1'b0;
        do_rvalid = (q_head < q_tail);
        if (do_rvalid) begin
          instr_rvalid_i = 1'b1;
          unique case (q_addr[q_head])
            32'h0000_2100: instr_rdata_i = encode_word(32'h0010_0093);
            32'h0000_2104: instr_rdata_i = encode_word(32'h0020_0113);
            default:       instr_rdata_i = encode_word(32'h0000_0013);
          endcase
        end else begin
          instr_rvalid_i = 1'b0;
        end
        #1;
        req_addr_sampled = instr_addr_o;
        if (icache_ecc_error_o !== 1'b0)
          fail_msg("Test 2A: Spurious icache_ecc_error_o on cache miss to uninitialized data RAM");
        if (instr_valid_id_o && pc_id_o == 32'h0000_2104 && instr_rdata_id_o == 32'h0020_0113)
          saw_2104_fill = 1'b1;
        if (do_rvalid) q_head++;
        if (instr_req_o && instr_gnt_i) begin
          q_addr[q_tail] = req_addr_sampled;
          q_tail++;
        end
        @(posedge clk_i);
        #1;
      end
      instr_rvalid_i = 1'b0;
      instr_gnt_i    = 1'b0;
      if (!saw_2104_fill || if_busy_o !== 1'b0)
        fail_msg("Test 2A: Initial miss fill of line 0x2100 did not complete cleanly");

      // 2B: Branch back to 0x2100 with req_i = 1 for 1 cycle and instr_gnt_i = 0:
      // Now line 0x2100 is allocated in ICache! Both 0x2100 (0x0010_0093) and 0x2104 (0x0020_0113)
      // MUST be served from the ICache hit while instr_gnt_i = 0!
      saw_2104_hit       = 1'b0;
      req_i              = 1'b1;
      branch_target_ex_i = 32'h0000_2100;
      pc_mux_i           = PC_JUMP;
      pc_set_i           = 1'b1;
      instr_gnt_i        = 1'b0;
      instr_rvalid_i     = 1'b0;
      @(posedge clk_i);
      #1;
      pc_set_i           = 1'b0;
      req_i              = 1'b0;
      for (int c = 0; c < 6; c++) begin
        if (icache_ecc_error_o === 1'b1)
          fail_msg("Test 2B: Unexpected icache_ecc_error_o on valid cache hit (check tag/data tweak infection)");
        if (instr_valid_id_o && pc_id_o == 32'h0000_2104 && instr_rdata_id_o == 32'h0020_0113)
          saw_2104_hit = 1'b1;
        @(posedge clk_i);
        #1;
      end
      if (!saw_2104_hit)
        fail_msg($sformatf("Test 2B: Cache hit at 0x2104 failed: valid=%b pc=%h rdata=%h", instr_valid_id_o, pc_id_o, instr_rdata_id_o));
      // Now grant and complete the 1 held speculative request from 2B so the fill buffer frees up cleanly!
      instr_gnt_i = 1'b1;
      @(posedge clk_i);
      #1;
      instr_gnt_i    = 1'b0;
      instr_rvalid_i = 1'b1;
      instr_rdata_i  = encode_word(32'h0010_0093);
      @(posedge clk_i);
      #1;
      instr_rvalid_i = 1'b0;
      instr_valid_clear_i = 1'b1;
      @(posedge clk_i);
      #1;
      instr_valid_clear_i = 1'b0;

      // 2C: Corrupt 1 bit in data_sram at index 8'h20 across all ways, then branch to 0x2100
      // and serve external memory with 32'h0050_0293 at 0x2104:
      // ICache must detect the data ECC error on hit (`icache_ecc_error_o == 1`), suppress the cached 0x0020_0113,
      // and refill 32'h0050_0293 from external memory!
      for (int w = 0; w < IC_NUM_WAYS; w++) begin
        data_sram[w][(32'h0000_2100 >> IC_LINE_W) & ((1 << IC_INDEX_W) - 1)][0] ^= 1'b1;
      end
      saw_ecc_err             = 1'b0;
      saw_2104_refill         = 1'b0;
      q_head                  = 0;
      q_tail                  = 0;
      instr_gnt_i             = 1'b1;
      branch_target_ex_i      = 32'h0000_2100;
      pc_mux_i                = PC_JUMP;
      for (int c = 0; c < 12; c++) begin
        logic [31:0] req_addr_sampled;
        bit          do_rvalid;
        pc_set_i  = (c == 0) ? 1'b1 : 1'b0;
        req_i     = (c == 0) ? 1'b1 : 1'b0;
        do_rvalid = (q_head < q_tail);
        if (do_rvalid) begin
          instr_rvalid_i = 1'b1;
          instr_rdata_i  = encode_word(32'h0050_0293);
        end else begin
          instr_rvalid_i = 1'b0;
        end
        #1;
        req_addr_sampled = instr_addr_o;
        if (icache_ecc_error_o === 1'b1) saw_ecc_err = 1'b1;
        if (c > 0 && instr_valid_id_o && pc_id_o == 32'h0000_2104) begin
          saw_2104_refill = 1'b1;
          if (instr_rdata_id_o !== 32'h0050_0293)
            fail_msg($sformatf("Test 2C: Corrupted cache hit was not suppressed on data ECC error: got %h", instr_rdata_id_o));
        end
        if (do_rvalid) q_head++;
        if (instr_req_o && instr_gnt_i) begin
          q_addr[q_tail] = req_addr_sampled;
          q_tail++;
        end
        @(posedge clk_i);
        #1;
      end
      instr_rvalid_i          = 1'b0;
      instr_gnt_i             = 1'b0;
      corrupt_data_ecc_on_hit = 1'b0;
      if (!saw_ecc_err || !saw_2104_refill)
        fail_msg($sformatf("Test 2C: Data ECC corruption on hitting line failed: saw_ecc_err=%b saw_2104_refill=%b", saw_ecc_err, saw_2104_refill));
    end

    // =========================================================================
    // Test 3: Unaligned 32-Bit Skid Buffer Second-Half Error Attribution (mutant_06)
    // =========================================================================
    req_i              = 1'b1;
    icache_enable_i    = 1'b0;
    branch_target_ex_i = 32'h0000_3002; // Unaligned 32-bit instruction spanning 0x3000 and 0x3004
    pc_mux_i           = PC_JUMP;
    pc_set_i           = 1'b1;
    instr_gnt_i        = 1'b1;
    @(posedge clk_i);
    #1;
    pc_set_i           = 1'b0;
    req_i              = 1'b0; // Only allocate 1 fill buffer for line 0x3000!
    // Beat 0 (0x3000): clean response with upper 16 bits = 16'h0013 (uncompressed opcode[1:0]==2'b11)
    instr_rvalid_i     = 1'b1;
    instr_bus_err_i    = 1'b0;
    instr_rdata_i      = encode_word(32'h0013_0000);
    @(posedge clk_i);
    #1;
    // Beat 1 (0x3004): bus error!
    instr_bus_err_i    = 1'b1;
    instr_rdata_i      = encode_word(32'h0000_0000);
    @(posedge clk_i);
    #1;
    instr_rvalid_i     = 1'b0;
    instr_bus_err_i    = 1'b0;
    instr_gnt_i        = 1'b0;
    if (instr_valid_id_o !== 1'b1 || instr_fetch_err_o !== 1'b1 || instr_fetch_err_plus2_o !== 1'b1)
      fail_msg($sformatf("Test 3: Unaligned second-half fault failed: valid=%b err=%b err_plus2=%b",
                         instr_valid_id_o, instr_fetch_err_o, instr_fetch_err_plus2_o));

    // =========================================================================
    // Test 4: Memory 39-Bit SECDED Integrity Error & Mispredict Squash (mutant_07, 08)
    // =========================================================================
    req_i              = 1'b1;
    branch_target_ex_i = 32'h0000_4000;
    pc_mux_i           = PC_JUMP;
    pc_set_i           = 1'b1;
    instr_gnt_i        = 1'b1;
    @(posedge clk_i);
    #1;
    pc_set_i           = 1'b0;
    req_i              = 1'b0;
    // Return beat 0 with 1-bit SECDED corruption (`^ 39'h1`) and instr_bus_err_i = 0
    instr_rvalid_i     = 1'b1;
    instr_rdata_i      = encode_word(32'h0010_0093) ^ 39'h1;
    #1;
    if (instr_intg_err_o !== 1'b1)
      fail_msg("Test 4A: 39-bit SECDED corruption did not assert instr_intg_err_o");
    @(posedge clk_i);
    #1;
    if (instr_valid_id_o !== 1'b1 || instr_fetch_err_o !== 1'b1)
      fail_msg("Test 4A: Memory SECDED integrity error did not propagate to instr_fetch_err_o");
    // Return beat 1 of line 0x4000 so the fill buffer completes all 2 external requests!
    instr_rdata_i      = encode_word(32'h0000_0013);
    @(posedge clk_i);
    #1;
    instr_rvalid_i     = 1'b0;
    instr_gnt_i        = 1'b0;

    // 4B: Branch mispredict squash (`nt_branch_mispredict_i = 1`)
    // First start a fetch at 0x4040 (2 beats) and hold id_in_ready_i = 0 on beat 1 so fetch_valid_raw is high,
    // then assert nt_branch_mispredict_i = 1!
    req_i               = 1'b1;
    branch_target_ex_i  = 32'h0000_4040;
    pc_mux_i            = PC_JUMP;
    pc_set_i            = 1'b1;
    instr_gnt_i         = 1'b1;
    instr_valid_clear_i = 1'b1;
    @(posedge clk_i);
    #1;
    pc_set_i               = 1'b0;
    req_i                  = 1'b0;
    instr_valid_clear_i    = 1'b0;
    nt_branch_mispredict_i = 1'b1;
    nt_branch_addr_i       = 32'h0000_4080;
    instr_rvalid_i         = 1'b1;
    instr_rdata_i          = encode_word(32'h0020_0113);
    @(posedge clk_i);
    #1;
    nt_branch_mispredict_i = 1'b0;
    if (instr_valid_id_o !== 1'b0)
      fail_msg("Test 4B: nt_branch_mispredict_i failed to squash simultaneous fetch_valid");
    // Drain the second beat of 0x4040 and the 1 speculative beat of 0x4080
    instr_rdata_i          = encode_word(32'h0000_0013);
    @(posedge clk_i);
    #1;
    @(posedge clk_i);
    #1;
    instr_rvalid_i         = 1'b0;
    instr_gnt_i            = 1'b0;

    // =========================================================================
    // Test 5: Zcmp Atomic Stack-Pointer Adjustment & Exception Flush (mutant_09, 10)
    // =========================================================================
    // Place cm.popretz {ra, s0}, 16 (16'hBC52) in the UPPER halfword of 0x5000 (32'hBC52_0001)
    // and jump directly to 0x5002!
    req_i              = 1'b1;
    branch_target_ex_i = 32'h0000_5002;
    pc_mux_i           = PC_JUMP;
    pc_set_i           = 1'b1;
    instr_gnt_i        = 1'b1;
    @(posedge clk_i);
    #1;
    pc_set_i           = 1'b0;
    req_i              = 1'b0;
    // Feed 32'hBC52_0001 at 0x5000 (upper halfword = 16'hBC52 at 0x5002!)
    instr_rvalid_i     = 1'b1;
    instr_rdata_i      = encode_word(32'hBC52_0001);
    @(posedge clk_i);
    #1;
    // Step 0 (load s0): INSTR_EXPANDED (and skid buffer latches 16'hBC52!)
    if (instr_valid_id_o !== 1'b1 || instr_gets_expanded_id_o !== INSTR_EXPANDED)
      fail_msg("Test 5A: cm.popretz step 0 did not output INSTR_EXPANDED");
    // Return beat 1 of 0x5000 so the fill buffer completes its external beats
    instr_rdata_i      = encode_word(32'h0000_0013);
    @(posedge clk_i);
    #1;
    instr_rvalid_i     = 1'b0;
    instr_gnt_i        = 1'b0;
    // Step 1 (load ra): INSTR_EXPANDED (served from skid_complete_instr!)
    if (instr_valid_id_o !== 1'b1 || instr_gets_expanded_id_o !== INSTR_EXPANDED)
      fail_msg("Test 5A: cm.popretz step 1 did not output INSTR_EXPANDED");
    @(posedge clk_i);
    #1;
    // Step 2 (CmPopIncrSp): INSTR_EXPANDED_COMMIT! (kills mutant_09!)
    if (instr_valid_id_o !== 1'b1 || instr_gets_expanded_id_o !== INSTR_EXPANDED_COMMIT)
      fail_msg($sformatf("Test 5B: cm.popretz step 2 (SP increment) did not output INSTR_EXPANDED_COMMIT (got %0d)", instr_gets_expanded_id_o));

    // Complete remaining 2 steps of cm.popretz (CmPopZeroA0 and CmPopRetRa) so skid buffer drains cleanly!
    @(posedge clk_i);
    #1;
    @(posedge clk_i);
    #1;

    // Now start a second Zcmp instruction (cm.push {ra, s0}, -16 = 16'hB852 in upper halfword of 0x5080)
    // and trigger exception redirect (`pc_set_i = 1, pc_mux_i = PC_EXC`) on step 0 while in CmPushStoreReg!
    req_i              = 1'b1;
    branch_target_ex_i = 32'h0000_5082;
    pc_mux_i           = PC_JUMP;
    pc_set_i           = 1'b1;
    instr_gnt_i        = 1'b1;
    @(posedge clk_i);
    #1;
    pc_set_i           = 1'b0;
    req_i              = 1'b0;
    instr_rvalid_i     = 1'b1;
    instr_rdata_i      = encode_word(32'hB852_0001);
    @(posedge clk_i);
    #1;
    // Now cm_state_q is in CmPushStoreReg (rlist=4)! Trigger PC_EXC redirect while returning beat 1 of 0x5080!
    req_i              = 1'b1;
    pc_mux_i           = PC_EXC;
    exc_pc_mux_i       = EXC_PC_EXC;
    pc_set_i           = 1'b1;
    instr_rvalid_i     = 1'b1;
    instr_rdata_i      = encode_word(32'h0000_0013);
    instr_gnt_i        = 1'b1;
    @(posedge clk_i);
    #1;
    pc_set_i           = 1'b0;
    req_i              = 1'b0;
    instr_gnt_i        = 1'b0;
    // Feed cm.pop {ra}, +16 (16'hBA42) at exception vector (0x8000):
    // If cm_state_q flushed to CmIdle, step 0 of cm.pop {ra} outputs lw ra, 12(sp) (opcode[6:0]==7'h03)!
    // If cm_state_q did NOT flush (remained in CmPushStoreReg), it outputs sw ra, -8(sp) (opcode[6:0]==7'h23)! (kills mutant_10!)
    instr_rvalid_i     = 1'b1;
    instr_rdata_i      = encode_word(32'h0001_BA42);
    @(posedge clk_i);
    #1;
    instr_rvalid_i     = 1'b0;
    if (instr_valid_id_o !== 1'b1 || instr_gets_expanded_id_o !== INSTR_EXPANDED || instr_rdata_id_o[6:0] !== 7'h03)
      fail_msg($sformatf("Test 5C: Exception redirect failed to flush Zcmp expansion FSM (rdata=%h exp=%0d)", instr_rdata_id_o, instr_gets_expanded_id_o));

    $display("PASS ibex_icache_if_subsys_top seed=%0d", SEED);
    $finish(0);
  end

endmodule
