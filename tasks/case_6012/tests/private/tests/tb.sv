// SPDX-License-Identifier: Apache-2.0
module tb;
   import veer_types::*;

   logic                                 clk = 1'b0;
   logic                                 rst_l = 1'b0;
   logic                                 scan_mode = 1'b0;
   logic                                 clk_override = 1'b0;

   logic                                 dec_ib3_valid_d;
   logic                                 dec_ib2_valid_d;
   logic                                 dec_ib0_valid_eff_d;
   logic                                 dec_ib1_valid_eff_d;
   logic                                 exu_flush_final;
   logic                                 dec_tlu_flush_err_wb;
   logic                                 dec_tlu_flush_noredir_wb;
   logic                                 dec_tlu_dbg_halted;
   logic                                 dec_tlu_pmu_fw_halted;
   logic [31:1]                          exu_flush_path_final;
   logic                                 exu_flush_upper_e2;
   logic [31:0]                          dec_tlu_mrac_ff;
   logic                                 dec_tlu_bpred_disable;
   logic                                 dec_tlu_core_ecc_disable;

   logic                                 ic_hit_f2;
   logic                                 ic_crit_wd_rdy;
   logic                                 ic_write_stall;
   logic                                 ic_dma_active;
   logic                                 dma_iccm_stall_any;
   logic                                 ifu_ic_mb_empty;
   logic                                 ifu_fb_consume1_ext_nc;
   logic [7:0]                           ic_fetch_val_f2;
   logic [127:0]                         ic_data_f2;
   logic [7:0]                           ic_access_fault_f2;
   logic                                 ic_rd_parity_final_err;
   logic                                 iccm_rd_ecc_single_err;
   logic [7:0]                           iccm_rd_ecc_double_err;
   icache_err_pkt_t                      ic_error_f2;
   logic                                 ifu_icache_fetch_f2;

   predict_pkt_t                         exu_mp_pkt;
   logic [`RV_BHT_GHR_RANGE]             exu_mp_eghr;
   br_tlu_pkt_t                          dec_tlu_br0_wb_pkt;
   br_tlu_pkt_t                          dec_tlu_br1_wb_pkt;
   logic                                 dec_tlu_flush_lower_wb;
   logic                                 dec_tlu_flush_leak_one_wb;
   rets_pkt_t                            exu_rets_e1_pkt;
   rets_pkt_t                            exu_rets_e4_pkt;
   logic                                 exu_i0_br_ret_e4;
   logic                                 exu_i1_br_ret_e4;
   logic                                 exu_i0_br_call_e4;
   logic                                 exu_i1_br_call_e4;

   logic [31:1]                          ifc_fetch_addr_f1;
   logic [31:1]                          ifc_fetch_addr_f2;
   logic                                 ifc_fetch_req_f1;
   logic                                 ifc_fetch_req_f1_raw;
   logic                                 ifc_fetch_req_f2;
   logic                                 ifc_fetch_uncacheable_f1;
   logic                                 ifc_iccm_access_f1;
   logic                                 ifc_region_acc_fault_f1;
   logic                                 ifc_dma_access_ok;
   logic                                 ifu_pmu_fetch_stall;

   logic                                 ifu_bp_kill_next_f2;
   logic [31:1]                          ifu_bp_btb_target_f2;
   logic [7:1]                           ifu_bp_inst_mask_f2;
   logic [7:0]                           ifu_bp_hist1_f2;
   logic [7:0]                           ifu_bp_hist0_f2;
   logic [11:0]                          ifu_bp_poffset_f2;
   logic [7:0]                           ifu_bp_ret_f2;
   logic [7:0]                           ifu_bp_pc4_f2;
   logic [7:0]                           ifu_bp_valid_f2;
   logic [`RV_BHT_GHR_RANGE]             ifu_bp_fghr_f2;

   logic                                 ifu_i0_valid;
   logic                                 ifu_i1_valid;
   logic                                 ifu_i0_icaf;
   logic                                 ifu_i1_icaf;
   logic                                 ifu_i0_icaf_second;
   logic                                 ifu_i1_icaf_second;
   logic                                 ifu_i0_perr;
   logic                                 ifu_i1_perr;
   logic                                 ifu_i0_sbecc;
   logic                                 ifu_i1_sbecc;
   logic                                 ifu_i0_dbecc;
   logic                                 ifu_i1_dbecc;
   logic [31:0]                          ifu_i0_instr;
   logic [31:0]                          ifu_i1_instr;
   logic [31:1]                          ifu_i0_pc;
   logic [31:1]                          ifu_i1_pc;
   logic                                 ifu_i0_pc4;
   logic                                 ifu_i1_pc4;
   logic [15:0]                          ifu_i0_cinst;
   logic [15:0]                          ifu_i1_cinst;
   logic                                 ifu_fb_consume1;
   logic                                 ifu_fb_consume2;
   logic [15:0]                          ifu_illegal_inst;
   br_pkt_t                              i0_brp;
   br_pkt_t                              i1_brp;
   logic [1:0]                           ifu_pmu_instr_aligned;
   logic                                 ifu_pmu_align_stall;
   logic [16:2]                          ifu_icache_error_index;
   logic                                 ifu_icache_error_val;
   logic                                 ifu_icache_sb_error_val;

   logic [7:0]                           ghr_in;
   logic [7:0]                           ghr_out;
   logic [7:0]                           ras_in;
   logic [7:0]                           ras_out;

   veer_ifu_aln_bp_top dut (.*);

   always #5 clk = ~clk;

   bit failed = 1'b0;
   task automatic fail(input string msg);
      $display("FAIL: %s at time %0t", msg, $time);
      failed = 1'b1;
      $finish;
   endtask

   task automatic step_clk();
      @(posedge clk);
      @(negedge clk);
   endtask

   task automatic clear_inputs();
      scan_mode                = 1'b0;
      clk_override             = 1'b0;
      dec_ib3_valid_d          = 1'b0;
      dec_ib2_valid_d          = 1'b0;
      dec_ib0_valid_eff_d      = 1'b0;
      dec_ib1_valid_eff_d      = 1'b0;
      exu_flush_final          = 1'b0;
      dec_tlu_flush_err_wb     = 1'b0;
      dec_tlu_flush_noredir_wb = 1'b0;
      dec_tlu_dbg_halted       = 1'b0;
      dec_tlu_pmu_fw_halted    = 1'b0;
      exu_flush_path_final     = 31'h4000_0000;
      exu_flush_upper_e2       = 1'b0;
      dec_tlu_mrac_ff          = 32'h5555_5555;
      dec_tlu_bpred_disable    = 1'b0;
      dec_tlu_core_ecc_disable = 1'b0;

      ic_hit_f2                = 1'b1;
      ic_crit_wd_rdy           = 1'b1;
      ic_write_stall           = 1'b0;
      ic_dma_active            = 1'b0;
      dma_iccm_stall_any       = 1'b0;
      ifu_ic_mb_empty          = 1'b1;
      ifu_fb_consume1_ext_nc   = 1'b0;
      ic_fetch_val_f2          = 8'h00;
      ic_data_f2               = {4{32'h0000_0013}};
      ic_access_fault_f2       = 8'h00;
      ic_rd_parity_final_err   = 1'b0;
      iccm_rd_ecc_single_err   = 1'b0;
      iccm_rd_ecc_double_err   = 8'h00;
      ic_error_f2              = '0;
      ifu_icache_fetch_f2      = 1'b0;

      exu_mp_pkt               = '0;
      exu_mp_eghr              = '0;
      dec_tlu_br0_wb_pkt       = '0;
      dec_tlu_br1_wb_pkt       = '0;
      dec_tlu_flush_lower_wb   = 1'b0;
      dec_tlu_flush_leak_one_wb = 1'b0;
      exu_rets_e1_pkt          = '0;
      exu_rets_e4_pkt          = '0;
      exu_i0_br_ret_e4         = 1'b0;
      exu_i1_br_ret_e4         = 1'b0;
      exu_i0_br_call_e4        = 1'b0;
      exu_i1_br_call_e4        = 1'b0;

      ghr_in                   = '0;
      ras_in                   = '0;
   endtask

   logic [8:0] tag_call_w, tag_ret_w, tag_cross_w;
   logic [1:0] idx_call_w, idx_ret_w, idx_cross_w;
   rvbtb_tag_hash  u_th_call  (.pc(31'h4000_0080), .hash(tag_call_w));
   rvbtb_tag_hash  u_th_ret   (.pc(31'h4000_00c0), .hash(tag_ret_w));
   rvbtb_tag_hash  u_th_cross (.pc(31'h4000_0240), .hash(tag_cross_w));
   rvbtb_addr_hash u_ah_call  (.pc(31'h4000_0080), .hash(idx_call_w));
   rvbtb_addr_hash u_ah_ret   (.pc(31'h4000_00c0), .hash(idx_ret_w));
   rvbtb_addr_hash u_ah_cross (.pc(31'h4000_0240), .hash(idx_cross_w));

   initial begin
      clear_inputs();
      rst_l = 1'b0;
      repeat (5) step_clk();
      rst_l = 1'b1;
      repeat (3) step_clk();

      // 1. Check transparent sideband pass-through
      for (int i = 0; i < 16; i++) begin
         ghr_in = 8'(i * 23 + 7);
         ras_in = 8'(i * 31 + 13);
         #1;
         if (ghr_out !== ghr_in || ras_out !== ras_in)
            fail("Sideband ghr_out/ras_out mismatch");
      end

      // 2. Test RVC 16-bit Decompression + Dual-Issue Alignment in ifu_aln_ctl + ifu_compress_ctl
      // Flush to 0x8000_1000 (31'h4000_0800)
      @(negedge clk);
      exu_flush_final      = 1'b1;
      exu_flush_path_final = 31'h4000_0800;
      step_clk(); // F1 at 0x8000_1000 clocked into F2

      // Present in F2:
      // halfword 0: C.ADDI16SP sp, -32 -> 011_1_00010_11101_01 = 16'h7175 -> expands to ADDI x2, x2, -32 (32'hfe01_0113)
      // halfword 1: C.LWSP x10, 16(sp) -> 010_0_01010_10000_10 = 16'h4542 -> expands to LW x10, 16(x2) (32'h0101_2503)
      // halfword 2..3: 32-bit ADD x5, x6, x7 -> 32'h0073_02b3 (halfword 2 = 16'h02b3, halfword 3 = 16'h0073)
      // halfword 4: Illegal 16-bit instruction 16'h0000
      @(negedge clk);
      exu_flush_final = 1'b0;
      ic_fetch_val_f2 = 8'b0001_1111; // 5 halfwords valid (lanes 0..4)
      ic_data_f2      = {48'h0, 16'h0000, 32'h0073_02b3, 16'h4542, 16'h7175};
      step_clk(); // F2 -> Aligner f0 buffer!
      ic_fetch_val_f2 = 8'h00;

      #1;
      // Cycle 1 of aligner: i0 = C.ADDI16SP (PC=0x8000_1000, pc4=0, instr=32'hf701_0113),
      //                     i1 = C.LWSP     (PC=0x8000_1002, pc4=0, instr=32'h0101_2503)
      if (!ifu_i0_valid || !ifu_i1_valid)
         fail($sformatf("Expected dual RVC valid (i0=%b, i1=%b)", ifu_i0_valid, ifu_i1_valid));
      if (ifu_i0_pc4 !== 1'b0 || ifu_i0_instr !== 32'hf701_0113 || {ifu_i0_pc, 1'b0} !== 32'h8000_1000 || ifu_i0_cinst !== 16'h7175)
         fail($sformatf("C.ADDI16SP mismatch: pc4=%b instr=0x%08x pc=0x%08x cinst=0x%04x",
                        ifu_i0_pc4, ifu_i0_instr, {ifu_i0_pc, 1'b0}, ifu_i0_cinst));
      if (ifu_i1_pc4 !== 1'b0 || ifu_i1_instr !== 32'h0101_2503 || {ifu_i1_pc, 1'b0} !== 32'h8000_1002 || ifu_i1_cinst !== 16'h4542)
         fail($sformatf("C.LWSP mismatch: pc4=%b instr=0x%08x pc=0x%08x cinst=0x%04x",
                        ifu_i1_pc4, ifu_i1_instr, {ifu_i1_pc, 1'b0}, ifu_i1_cinst));

      step_clk(); // Consumes first two 2B instructions; now halfword 2..3 (4B ADD) is at i0, and halfword 4 (illegal 16'h0000) is at i1!
      #1;
      if (!ifu_i0_valid || ifu_i0_pc4 !== 1'b1 || ifu_i0_instr !== 32'h0073_02b3 || {ifu_i0_pc, 1'b0} !== 32'h8000_1004)
         fail($sformatf("4B ADD mismatch: valid=%b pc4=%b instr=0x%08x pc=0x%08x",
                        ifu_i0_valid, ifu_i0_pc4, ifu_i0_instr, {ifu_i0_pc, 1'b0}));
      if (!ifu_i1_valid || ifu_i1_pc4 !== 1'b0 || ifu_i1_instr !== 32'h0000_0000 || {ifu_i1_pc, 1'b0} !== 32'h8000_1008)
         fail($sformatf("Illegal RVC i1 mismatch: valid=%b pc4=%b instr=0x%08x pc=0x%08x",
                        ifu_i1_valid, ifu_i1_pc4, ifu_i1_instr, {ifu_i1_pc, 1'b0}));

      // Also inject another fetch group with a second illegal 16-bit instruction (16'h8000: c.jr x0) to verify illegal_lockout prevents overwriting ifu_illegal_inst until exu_flush_final!
      @(negedge clk);
      ic_fetch_val_f2 = 8'b0000_0001;
      ic_data_f2      = {112'h0, 16'h8000};
      step_clk(); // Shifts out 4B ADD + illegal 16'h0000 (latching ifu_illegal_inst=16'h0000 and setting illegal_lockout=1), and loads 16'h8000 into aligner!
      ic_fetch_val_f2 = 8'h00;
      #1;
      if (ifu_illegal_inst !== 16'h0000)
         fail($sformatf("Expected ifu_illegal_inst to latch 16'h0000, got 0x%04x", ifu_illegal_inst));
      step_clk(); // Shifts out 16'h8000 while illegal_lockout==1 -> must NOT overwrite 16'h0000!
      #1;
      if (ifu_illegal_inst !== 16'h0000)
         fail($sformatf("Expected illegal_lockout to preserve 16'h0000 before flush, got 0x%04x", ifu_illegal_inst));

      // Now flush to clear illegal_lockout, and feed 16'ha002 (illegal C.FSDSP) -> must update ifu_illegal_inst to 16'ha002!
      @(negedge clk);
      exu_flush_final      = 1'b1;
      exu_flush_path_final = 31'h4000_0900;
      step_clk();
      @(negedge clk);
      exu_flush_final = 1'b0;
      ic_fetch_val_f2 = 8'b0000_0001;
      ic_data_f2      = {112'h0, 16'ha002};
      step_clk();
      ic_fetch_val_f2 = 8'h00;
      step_clk();
      #1;
      if (ifu_illegal_inst !== 16'ha002)
         fail($sformatf("Expected unlocked ifu_illegal_inst to capture 16'ha002 after flush, got 0x%04x", ifu_illegal_inst));

      // 3. Test Cross-Fetch-Buffer 4B Instruction Spanning f0 and f1 + Second-Halfword Access Fault (ifu_i0_icaf_second)
      // Flush to 0x8000_200e (halfword 7 of fetch group 0x8000_2000 -> 31'h4000_1007)
      exu_flush_final      = 1'b1;
      exu_flush_path_final = 31'h4000_1007;
      step_clk(); // F1 at 0x8000_200e -> F2
      exu_flush_final    = 1'b0;
      ic_fetch_val_f2    = 8'b0000_0001; // 1 halfword valid at end of fetch line (0x8000_200e)
      ic_data_f2         = {16'h12b7, 112'h0}; // upper halfword 7 of 128-bit line is lower 16b of LUI x5, 0xdead1 (32'hdead_12b7)
      ic_access_fault_f2 = 8'b0000_0000;       // first halfword has NO access fault
      step_clk(); // F2 -> f0! Meanwhile F1 sequentially fetched 0x8000_2010 -> F2!

      // In F2 (for 0x8000_2010), provide upper 16b (16'hdead) with an access fault on lane 0!
      ic_fetch_val_f2    = 8'b0000_0011;
      ic_data_f2         = {96'h0, 16'h0001, 16'hdead}; // 16'hdead completes 32'hdead_12b7; 16'h0001 is C.NOP
      ic_access_fault_f2 = 8'b0000_0001;                // access fault on first halfword of second fetch group!
      step_clk(); // F2 -> f1!
      ic_fetch_val_f2    = 8'h00;
      ic_access_fault_f2 = 8'h00;
      #1;
      if (!ifu_i0_valid || ifu_i0_pc4 !== 1'b1 || ifu_i0_instr !== 32'hdead_12b7 || {ifu_i0_pc, 1'b0} !== 32'h8000_200e)
         fail($sformatf("Spanning 4B LUI mismatch: valid=%b pc4=%b instr=0x%08x pc=0x%08x",
                        ifu_i0_valid, ifu_i0_pc4, ifu_i0_instr, {ifu_i0_pc, 1'b0}));
      if (!ifu_i0_icaf || !ifu_i0_icaf_second)
         fail($sformatf("Expected ifu_i0_icaf=1 and ifu_i0_icaf_second=1 on spanning 4B inst, got icaf=%b icaf_second=%b",
                        ifu_i0_icaf, ifu_i0_icaf_second));

      // 4. Test I-Cache Parity Error vs ICCM Single-Bit ECC Error Mutual Exclusion in Aligner
      // Flush to 0x8000_300e (31'h4000_1807): stall decode (dec_ib3_valid_d=1, dec_ib2_valid_d=1) while filling f0 and f1,
      // then un-stall decode so i0 (ICCM with sbecc) and i1 (I-Cache with perr) are aligned and shifted in the same cycle!
      exu_flush_final      = 1'b1;
      exu_flush_path_final = 31'h4000_1807;
      step_clk(); // F1 -> F2
      exu_flush_final        = 1'b0;
      dec_ib3_valid_d        = 1'b1;
      dec_ib2_valid_d        = 1'b1; // stall aligner consumption while loading f0 and f1
      ic_fetch_val_f2        = 8'b0000_0001;
      ic_data_f2             = {16'h0001, 112'h0}; // C.NOP at halfword 7
      ifu_icache_fetch_f2    = 1'b0;               // ICCM fetch
      ic_rd_parity_final_err = 1'b0;
      iccm_rd_ecc_single_err = 1'b1;               // ICCM single-bit ECC error on i0!
      step_clk(); // F2 -> f0!

      ic_fetch_val_f2        = 8'b0000_0001;
      ic_data_f2             = {112'h0, 16'h0001}; // C.NOP at halfword 0 of next fetch group
      ifu_icache_fetch_f2    = 1'b1;               // I-Cache fetch
      ic_rd_parity_final_err = 1'b1;               // I-Cache parity error on i1!
      iccm_rd_ecc_single_err = 1'b0;
      step_clk(); // F2 -> f1!
      ic_fetch_val_f2        = 8'h00;
      ifu_icache_fetch_f2    = 1'b0;
      ic_rd_parity_final_err = 1'b0;
      dec_ib3_valid_d        = 1'b0;
      dec_ib2_valid_d        = 1'b0; // now ibuffer_room2_more == 1!
      #1;
      if (!ifu_i0_sbecc || !ifu_i1_perr || !ifu_icache_sb_error_val || ifu_icache_error_val)
         fail($sformatf("Expected i0_sbecc=1, i1_perr=1, sb_error_val=1, error_val=0, got sbecc=%b perr=%b sb_val=%b err_val=%b",
                        ifu_i0_sbecc, ifu_i1_perr, ifu_icache_sb_error_val, ifu_icache_error_val));

      // 5. Test BTB/BHT/RAS Call Push, Ret Pop Target, FG-Crossing 4B Branch, and BHT Write Priority
      begin
         automatic logic [31:1] pc_call = 31'h4000_0080;
         automatic logic [31:1] pc_ret  = 31'h4000_00c0;
         automatic logic [31:1] pc_cross_prev = 31'h4000_0207;
         automatic logic [31:1] pc_cross_cur  = 31'h4000_0240;

         exu_flush_final      = 1'b1;
         exu_flush_path_final = 31'h4000_0000;
         step_clk();

         // Train BTB CALL at pc_call
         exu_flush_final    = 1'b0;
         exu_mp_pkt         = '0;
         exu_mp_pkt.misp    = 1'b1;
         exu_mp_pkt.ataken  = 1'b1;
         exu_mp_pkt.pcall   = 1'b1;
         exu_mp_pkt.pc4     = 1'b1;
         exu_mp_pkt.boffset = 1'b0;
         exu_mp_pkt.way     = 1'b0;
         exu_mp_pkt.index   = idx_call_w;
         exu_mp_pkt.bank    = 2'b00;
         exu_mp_pkt.btag    = tag_call_w;
         exu_mp_pkt.toffset = 12'h040;
         step_clk();

         // Train BTB RET at pc_ret
         exu_mp_pkt         = '0;
         exu_mp_pkt.misp    = 1'b1;
         exu_mp_pkt.ataken  = 1'b1;
         exu_mp_pkt.pret    = 1'b1;
         exu_mp_pkt.pc4     = 1'b0;
         exu_mp_pkt.boffset = 1'b0;
         exu_mp_pkt.way     = 1'b1;
         exu_mp_pkt.index   = idx_ret_w;
         exu_mp_pkt.bank    = 2'b00;
         exu_mp_pkt.btag    = tag_ret_w;
         exu_mp_pkt.toffset = 12'h010;
         step_clk();

         exu_mp_pkt           = '0;
         exu_flush_final      = 1'b1;
         exu_flush_path_final = pc_call;
         step_clk(); // F1 at pc_call -> F2

         exu_flush_final      = 1'b0;
         ic_fetch_val_f2      = 8'b0000_0000;
         #1;
         if (!ifu_bp_kill_next_f2 || ifu_bp_btb_target_f2 !== 31'h4000_00c0)
            fail($sformatf("BTB CALL hit failed: kill=%b target=0x%08x", ifu_bp_kill_next_f2, {ifu_bp_btb_target_f2, 1'b0}));
         step_clk(); // RAS pushes pc_call + 4 (31'h4000_0082) on this posedge!

         // Explicitly flush to pc_ret (0x8000_0180) and verify RET pops RAS (31'h4000_0082)!
         exu_flush_final      = 1'b1;
         exu_flush_path_final = pc_ret;
         step_clk(); // F1 at pc_ret -> F2
         exu_flush_final      = 1'b0;
         #1;
         if (!ifu_bp_kill_next_f2 || ifu_bp_btb_target_f2 !== 31'h4000_0082 || ifu_bp_ret_f2[0] !== 1'b1)
            fail($sformatf("BTB RET pop RAS failed: kill=%b target=0x%08x ret_f2=%b",
                           ifu_bp_kill_next_f2, {ifu_bp_btb_target_f2, 1'b0}, ifu_bp_ret_f2));
         step_clk();

         // Train FG-crossing 4B branch at pc_cross_cur
         exu_mp_pkt         = '0;
         exu_mp_pkt.misp    = 1'b1;
         exu_mp_pkt.ataken  = 1'b1;
         exu_mp_pkt.pja     = 1'b1;
         exu_mp_pkt.pc4     = 1'b1;
         exu_mp_pkt.boffset = 1'b1;
         exu_mp_pkt.way     = 1'b0;
         exu_mp_pkt.index   = idx_cross_w;
         exu_mp_pkt.bank    = 2'b00;
         exu_mp_pkt.btag    = tag_cross_w;
         exu_mp_pkt.toffset = 12'h020;
         step_clk();

         exu_mp_pkt           = '0;
         exu_flush_final      = 1'b1;
         exu_flush_path_final = pc_cross_prev;
         step_clk();
         exu_flush_final      = 1'b0;
         step_clk();
         exu_flush_final      = 1'b1;
         exu_flush_path_final = pc_cross_cur;
         step_clk();
         exu_flush_final      = 1'b0;
         #1;
         if (!ifu_bp_kill_next_f2 || ifu_bp_btb_target_f2 !== 31'h4000_0227)
            fail($sformatf("FG-crossing 4B branch target mismatch: got 0x%08x", {ifu_bp_btb_target_f2, 1'b0}));
         step_clk();
      end

      // 6. Test IFC MRAC Cacheability & ICCM Region Access Faults
      // Region 0xe: valid ICCM is [0xee000000, 0xee07ffff]. 0xee08_0000 is out-of-range in region 0xe -> ifc_region_acc_fault_f1!
      @(negedge clk);
      dec_tlu_mrac_ff      = 32'h0000_0000; // all regions uncacheable
      exu_flush_final      = 1'b1;
      exu_flush_path_final = 31'(32'hee08_0000 >> 1);
      #1;
      if (!ifc_region_acc_fault_f1 || ifc_iccm_access_f1 || !ifc_fetch_uncacheable_f1)
         fail($sformatf("Expected region 0xe out-of-range fault=1 iccm=0 uncacheable=1, got fault=%b iccm=%b unc=%b",
                        ifc_region_acc_fault_f1, ifc_iccm_access_f1, ifc_fetch_uncacheable_f1));
      exu_flush_path_final = 31'(32'hee02_0000 >> 1);
      #1;
      if (ifc_region_acc_fault_f1 || !ifc_iccm_access_f1)
         fail($sformatf("Expected in-range ICCM fault=0 iccm=1, got fault=%b iccm=%b",
                        ifc_region_acc_fault_f1, ifc_iccm_access_f1));

      if (!failed) begin
         $display("PASS: veer_ifu_aln_bp_top verification succeeded.");
         $finish;
      end
   end
endmodule
