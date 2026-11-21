// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps

module tb #(parameter int SEED = 101);
   import veer_types::*;

   logic                        clk;
   logic                        rst_l;
   logic                        scan_mode;
   logic                        clk_override;
   logic                        ifu_bus_clk_en;

   logic                        ifu_fb_consume1, ifu_fb_consume2;
   logic                        exu_flush_final;
   logic [31:1]                 exu_flush_path_final;
   logic                        exu_flush_upper_e2;
   logic                        dec_tlu_flush_err_wb;
   logic                        dec_tlu_flush_noredir_wb;
   logic                        dec_tlu_dbg_halted;
   logic                        dec_tlu_pmu_fw_halted;
   logic [31:0]                 dec_tlu_mrac_ff;
   logic                        dec_tlu_fence_i_wb;
   logic                        dec_tlu_flush_leak_one_wb;
   logic                        dec_tlu_bpred_disable;
   logic                        dec_tlu_core_ecc_disable;
   logic                        dec_tlu_flush_lower_wb;

   logic                        exu_i0_br_ret_e4, exu_i1_br_ret_e4;
   logic                        exu_i0_br_call_e4, exu_i1_br_call_e4;
   predict_pkt_t                exu_mp_pkt;
   logic [`RV_BHT_GHR_RANGE]    exu_mp_eghr;
   br_tlu_pkt_t                 dec_tlu_br0_wb_pkt, dec_tlu_br1_wb_pkt;
   rets_pkt_t                   exu_rets_e1_pkt, exu_rets_e4_pkt;

   logic [16:6]                 ifu_icache_error_index;
   logic                        ifu_icache_error_val;
   logic                        ifu_icache_sb_error_val;
   cache_debug_pkt_t            dec_tlu_ic_diag_pkt;

   logic                        dma_iccm_req;
   logic                        dma_iccm_stall_any;
   logic [31:0]                 dma_mem_addr;
   logic [2:0]                  dma_mem_sz;
   logic                        dma_mem_write;
   logic [63:0]                 dma_mem_wdata;
   logic                        iccm_dma_ecc_error;
   logic                        iccm_dma_rvalid;
   logic [63:0]                 iccm_dma_rdata;
   logic                        iccm_ready;
   logic                        iccm_dma_sb_error;

   logic                        ifu_axi_awvalid, ifu_axi_awready;
   logic [`RV_IFU_BUS_TAG-1:0]  ifu_axi_awid;
   logic [31:0]                 ifu_axi_awaddr;
   logic [3:0]                  ifu_axi_awregion;
   logic [7:0]                  ifu_axi_awlen;
   logic [2:0]                  ifu_axi_awsize;
   logic [1:0]                  ifu_axi_awburst;
   logic                        ifu_axi_awlock;
   logic [3:0]                  ifu_axi_awcache;
   logic [2:0]                  ifu_axi_awprot;
   logic [3:0]                  ifu_axi_awqos;
   logic                        ifu_axi_wvalid, ifu_axi_wready;
   logic [63:0]                 ifu_axi_wdata;
   logic [7:0]                  ifu_axi_wstrb;
   logic                        ifu_axi_wlast;
   logic                        ifu_axi_bvalid, ifu_axi_bready;
   logic [1:0]                  ifu_axi_bresp;
   logic [`RV_IFU_BUS_TAG-1:0]  ifu_axi_bid;
   logic                        ifu_axi_arvalid, ifu_axi_arready;
   logic [`RV_IFU_BUS_TAG-1:0]  ifu_axi_arid;
   logic [31:0]                 ifu_axi_araddr;
   logic [3:0]                  ifu_axi_arregion;
   logic [7:0]                  ifu_axi_arlen;
   logic [2:0]                  ifu_axi_arsize;
   logic [1:0]                  ifu_axi_arburst;
   logic                        ifu_axi_arlock;
   logic [3:0]                  ifu_axi_arcache;
   logic [2:0]                  ifu_axi_arprot;
   logic [3:0]                  ifu_axi_arqos;
   logic                        ifu_axi_rvalid, ifu_axi_rready;
   logic [`RV_IFU_BUS_TAG-1:0]  ifu_axi_rid;
   logic [63:0]                 ifu_axi_rdata;
   logic [1:0]                  ifu_axi_rresp;
   logic                        ifu_axi_rlast;

   logic [31:2]                 ic_rw_addr;
   logic [3:0]                  ic_wr_en;
   logic                        ic_rd_en;
   logic [67:0]                 ic_wr_data;
   logic [135:0]                ic_rd_data;
   logic [20:0]                 ictag_debug_rd_data;
   logic [33:0]                 ic_debug_wr_data, ifu_ic_debug_rd_data;
   logic [127:0]                ic_premux_data;
   logic                        ic_sel_premux_data;
   logic [15:2]                 ic_debug_addr;
   logic                        ic_debug_rd_en, ic_debug_wr_en, ic_debug_tag_array;
   logic [3:0]                  ic_debug_way, ic_tag_valid;
   logic [3:0]                  ic_rd_hit;
   logic                        ic_tag_perr;
   logic [`RV_ICCM_BITS-1:2]    iccm_rw_addr;
   logic                        iccm_wren, iccm_rden;
   logic [77:0]                 iccm_wr_data;
   logic [2:0]                  iccm_wr_size;
   logic [155:0]                iccm_rd_data;

   logic [31:1]                 ifc_fetch_addr_f1, ifc_fetch_addr_f2;
   logic                        ifc_fetch_req_f1, ifc_fetch_req_f2;
   logic                        ic_hit_f2, ic_crit_wd_rdy;
   logic [7:0]                  ic_access_fault_f2;
   logic                        ic_rd_parity_final_err;
   logic                        iccm_rd_ecc_single_err;
   logic [7:0]                  iccm_rd_ecc_double_err;
   logic [7:0]                  ic_fetch_val_f2;
   logic [127:0]                ic_data_f2;
   icache_err_pkt_t             ic_error_f2;
   logic                        ifu_icache_fetch_f2;
   logic                        ifu_miss_state_idle, ifu_ic_mb_empty;
   logic                        ic_dma_active, ic_write_stall;
   logic                        ifu_bp_kill_next_f2;
   logic [31:1]                 ifu_bp_btb_target_f2;
   logic [7:1]                  ifu_bp_inst_mask_f2;
   logic [`RV_BHT_GHR_RANGE]    ifu_bp_fghr_f2;
   logic [7:0]                  ifu_bp_way_f2, ifu_bp_ret_f2, ifu_bp_hist1_f2, ifu_bp_hist0_f2;
   logic [11:0]                 ifu_bp_poffset_f2;
   logic [7:0]                  ifu_bp_pc4_f2, ifu_bp_valid_f2;
   logic                        ifu_pmu_fetch_stall;
   logic                        ifu_pmu_ic_miss, ifu_pmu_ic_hit, ifu_pmu_bus_error, ifu_pmu_bus_busy, ifu_pmu_bus_trxn;
   logic                        ifu_ic_debug_rd_data_valid;

   veer_ifu_bp_mem_top dut (.*);

   initial begin
      clk = 1'b0;
      forever #5 clk = ~clk;
   end

   task automatic fail(input string msg);
      $display("FAIL: %s", msg);
      $finish(1);
   endtask

   task automatic step_clk();
      @(posedge clk);
      #1;
   endtask

   task automatic reset_all();
      rst_l = 1'b0;
      scan_mode = 1'b0;
      clk_override = 1'b0;
      ifu_bus_clk_en = 1'b1;
      ifu_fb_consume1 = 1'b0;
      ifu_fb_consume2 = 1'b0;
      exu_flush_final = 1'b0;
      exu_flush_path_final = '0;
      exu_flush_upper_e2 = 1'b0;
      dec_tlu_flush_err_wb = 1'b0;
      dec_tlu_flush_noredir_wb = 1'b0;
      dec_tlu_dbg_halted = 1'b0;
      dec_tlu_pmu_fw_halted = 1'b0;
      dec_tlu_mrac_ff = 32'h5555_5555; // all 16 regions cacheable (even bits = 1, odd bits = 0)
      dec_tlu_fence_i_wb = 1'b0;
      dec_tlu_flush_leak_one_wb = 1'b0;
      dec_tlu_bpred_disable = 1'b0;
      dec_tlu_core_ecc_disable = 1'b0;
      dec_tlu_flush_lower_wb = 1'b0;
      exu_i0_br_ret_e4 = 1'b0; exu_i1_br_ret_e4 = 1'b0;
      exu_i0_br_call_e4 = 1'b0; exu_i1_br_call_e4 = 1'b0;
      exu_mp_pkt = '0;
      exu_mp_eghr = '0;
      dec_tlu_br0_wb_pkt = '0;
      dec_tlu_br1_wb_pkt = '0;
      exu_rets_e1_pkt = '0;
      exu_rets_e4_pkt = '0;
      ifu_icache_error_index = '0;
      ifu_icache_error_val = 1'b0;
      ifu_icache_sb_error_val = 1'b0;
      dec_tlu_ic_diag_pkt = '0;
      dma_iccm_req = 1'b0;
      dma_iccm_stall_any = 1'b0;
      dma_mem_addr = '0;
      dma_mem_sz = '0;
      dma_mem_write = 1'b0;
      dma_mem_wdata = '0;
      ifu_axi_awready = 1'b1;
      ifu_axi_wready = 1'b1;
      ifu_axi_bvalid = 1'b0;
      ifu_axi_bresp = '0;
      ifu_axi_bid = '0;
      ifu_axi_arready = 1'b1;
      ifu_axi_rvalid = 1'b0;
      ifu_axi_rid = '0;
      ifu_axi_rdata = '0;
      ifu_axi_rresp = '0;
      ifu_axi_rlast = 1'b0;
      ic_rd_data = {4{2'b00, 32'h0000_0013}};
      ictag_debug_rd_data = '0;
      ic_rd_hit = 4'b0001;
      ic_tag_perr = 1'b0;
      iccm_rd_data = '0;

      repeat (5) step_clk();
      rst_l = 1'b1;
      repeat (3) step_clk();
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
      int timeout;
      int ar_beats;
      logic [31:1] pc_call, pc_ret, pc_cross_prev, pc_cross_cur;
      logic [8:0] tag_call, tag_ret, tag_cross;

      reset_all();

      // =========================================================================
      // Phase 1: BTB/BHT/RAS Call Push, Ret Pop Target, FG-Crossing 4B Branch, and BHT Write Priority
      // =========================================================================
      begin
         // 1A: Train BTB with a CALL at PC = 32'h8000_0100 (index = idx_call_w, bank = 2'b00, pc4=1, boffset=0, pcall=1, toffset=12'h040)
         pc_call = 31'h4000_0080; // byte addr 0x8000_0100
         tag_call = tag_call_w;
         ifu_fb_consume1 = 1'b1;
         exu_flush_final = 1'b1;
         exu_flush_path_final = 31'h4000_0000;
         step_clk();

         exu_flush_final = 1'b0;
         exu_mp_pkt = '0;
         exu_mp_pkt.misp    = 1'b1;
         exu_mp_pkt.ataken  = 1'b1;
         exu_mp_pkt.pcall   = 1'b1;
         exu_mp_pkt.pc4     = 1'b1;
         exu_mp_pkt.boffset = 1'b0;
         exu_mp_pkt.way     = 1'b0;
         exu_mp_pkt.index   = idx_call_w;
         exu_mp_pkt.bank    = 2'b00;
         exu_mp_pkt.btag    = tag_call;
         exu_mp_pkt.toffset = 12'h040;
         step_clk();

         // Also train BTB with a RET at PC = 32'h8000_0180 (index = idx_ret_w, bank = 2'b00, way = 1, pc4=0, boffset=0, pret=1)
         pc_ret = 31'h4000_00c0; // byte addr 0x8000_0180
         tag_ret = tag_ret_w;
         exu_mp_pkt = '0;
         exu_mp_pkt.misp    = 1'b1;
         exu_mp_pkt.ataken  = 1'b1;
         exu_mp_pkt.pret    = 1'b1;
         exu_mp_pkt.pc4     = 1'b0;
         exu_mp_pkt.boffset = 1'b0;
         exu_mp_pkt.way     = 1'b1;
         exu_mp_pkt.index   = idx_ret_w;
         exu_mp_pkt.bank    = 2'b00;
         exu_mp_pkt.btag    = tag_ret;
         exu_mp_pkt.toffset = 12'h010;
         step_clk(); // BTB writes RET entry!

         exu_mp_pkt = '0;
         exu_flush_final = 1'b1;
         exu_flush_path_final = pc_call; // redirect F1 to pc_call (0x8000_0100) after BTB write completed!
         step_clk(); // F1 is clocked into F2 at pc_call!

         exu_flush_final = 1'b0;
         #1;
         if (!ifu_bp_kill_next_f2 || ifu_bp_btb_target_f2 !== 31'h4000_00c0 || ic_access_fault_f2 !== 8'h00) begin
            $display("CALL BTB hit: kill=%b target=%h fault=%h", ifu_bp_kill_next_f2, ifu_bp_btb_target_f2, ic_access_fault_f2);
            fail("BTB CALL hit or target calculation failed");
         end
         step_clk(); // RAS latches pc_call + 4 (31'h4000_0082) on this posedge!

         // Now flush to pc_ret (0x8000_0180) and verify RET pops RAS (31'h4000_0082)!
         exu_flush_final = 1'b1;
         exu_flush_path_final = pc_ret;
         step_clk(); // F1 at pc_ret clocked into F2

         exu_flush_final = 1'b0;
         #1;
         if (!ifu_bp_kill_next_f2 || ifu_bp_btb_target_f2 !== 31'h4000_0082 || ifu_bp_ret_f2[0] !== 1'b1) begin
            $display("RET BTB hit: kill=%b target=%h (exp 40000082) ret_f2=%b", ifu_bp_kill_next_f2, ifu_bp_btb_target_f2, ifu_bp_ret_f2);
            fail("BTB RET did not select return address stack (RAS) top target");
         end
         step_clk();

         // 1B: Fetch-group crossing 4B branch (btb_sel_f2[0]=1 && btb_rd_pc4_f2=1 uses ifc_fetch_adder_prior[31:4]!)
         pc_cross_prev = 31'h4000_0207; // byte addr 0x8000_040e (prior fetch group 0x8000_0400)
         pc_cross_cur  = 31'h4000_0240; // byte addr 0x8000_0480 (current fetch group 0x8000_0480)
         tag_cross = tag_cross_w;
         exu_flush_final = 1'b0;
         exu_mp_pkt = '0;
         exu_mp_pkt.misp    = 1'b1;
         exu_mp_pkt.ataken  = 1'b1;
         exu_mp_pkt.pja     = 1'b1;
         exu_mp_pkt.pc4     = 1'b1;
         exu_mp_pkt.boffset = 1'b1; // pc4=1 & boffset=1 -> pc4 ^ boffset = 0 -> lane 0 (btb_sel_f2[0])!
         exu_mp_pkt.way     = 1'b0;
         exu_mp_pkt.index   = idx_cross_w;
         exu_mp_pkt.bank    = 2'b00;
         exu_mp_pkt.btag    = tag_cross;
         exu_mp_pkt.toffset = 12'h020;
         step_clk(); // BTB writes cross entry!

         exu_mp_pkt = '0;
         exu_flush_final = 1'b1;
         exu_flush_path_final = pc_cross_prev;
         step_clk(); // F1 at pc_cross_prev clocked into F2

         exu_flush_final = 1'b0;
         step_clk(); // F2 at pc_cross_prev latches ifc_fetch_adder_prior!

         exu_flush_final = 1'b1;
         exu_flush_path_final = pc_cross_cur;
         step_clk(); // F1 at pc_cross_cur clocked into F2

         exu_flush_final = 1'b0;
         #1;
         // Target must use prior fetch group {0x8000_040, 3'b111} + 12'h020 = 31'h4000_0207 + 31'h020 = 31'h4000_0227!
         if (!ifu_bp_kill_next_f2 || ifu_bp_btb_target_f2 !== 31'h4000_0227) begin
            $display("FG crossing target=%h (exp 40000227)", ifu_bp_btb_target_f2);
            fail("Fetch-group crossing 4B branch target calculation failed in ifu_bp_ctl");
         end
         step_clk();

         // 1C: Simultaneous BHT write priority (dec_tlu_br0_wb_pkt > dec_tlu_br1_wb_pkt > exu_mp_pkt)
         // AND single exu_mp_pkt BHT write on another bank (bank 2'b10)
         exu_flush_final = 1'b1;
         exu_flush_path_final = 31'h4000_0000;
         exu_mp_pkt = '0;
         exu_mp_pkt.misp   = 1'b1;
         exu_mp_pkt.hist   = 2'b00; // lowest priority
         exu_mp_pkt.index  = 2'b00;
         exu_mp_pkt.bank   = 2'b01;
         exu_mp_eghr       = 5'b00000;
         dec_tlu_br1_wb_pkt = '0;
         dec_tlu_br1_wb_pkt.valid  = 1'b1;
         dec_tlu_br1_wb_pkt.hist   = 2'b01; // middle priority
         dec_tlu_br1_wb_pkt.index  = 2'b00;
         dec_tlu_br1_wb_pkt.bank   = 2'b01;
         dec_tlu_br1_wb_pkt.middle = 1'b0;
         dec_tlu_br1_wb_pkt.fghr   = 5'b00000;
         dec_tlu_br0_wb_pkt = '0;
         dec_tlu_br0_wb_pkt.valid  = 1'b1;
         dec_tlu_br0_wb_pkt.hist   = 2'b11; // highest priority!
         dec_tlu_br0_wb_pkt.index  = 2'b00;
         dec_tlu_br0_wb_pkt.bank   = 2'b01;
         dec_tlu_br0_wb_pkt.middle = 1'b0;
         dec_tlu_br0_wb_pkt.fghr   = 5'b00000;
         step_clk();

         // Now write only exu_mp_pkt to bank 2'b10 (lane 4) with hist=2'b10
         dec_tlu_br0_wb_pkt = '0;
         dec_tlu_br1_wb_pkt = '0;
         exu_mp_pkt = '0;
         exu_mp_pkt.misp   = 1'b1;
         exu_mp_pkt.hist   = 2'b10;
         exu_mp_pkt.index  = 2'b00;
         exu_mp_pkt.bank   = 2'b10;
         exu_mp_eghr       = 5'b00000;
         step_clk();

         exu_mp_pkt = '0;
         exu_flush_final = 1'b1;
         exu_flush_path_final = 31'h4000_0000; // index 2'b00
         step_clk(); // F1 clocked into F2

         exu_flush_final = 1'b0;
         #1;
         if ({ifu_bp_hist1_f2[2], ifu_bp_hist0_f2[2]} !== 2'b11 || {ifu_bp_hist1_f2[4], ifu_bp_hist0_f2[4]} !== 2'b10) begin
            $display("BHT lane2=%b%b (exp 11), lane4=%b%b (exp 10)", ifu_bp_hist1_f2[2], ifu_bp_hist0_f2[2], ifu_bp_hist1_f2[4], ifu_bp_hist0_f2[4]);
            fail("Simultaneous BHT write priority (br0 > br1 > mp) or individual BHT write failed in ifu_bp_ctl");
         end
         step_clk();
      end

      // =========================================================================
      // Phase 2: MRAC Uncacheable vs Cacheable Miss (2 beats vs 8 beats) & Critical-Word Bypass
      // =========================================================================
      begin
         // 2A: Uncacheable miss (region 0x9, set even bit 18 = 0, odd bit 19 = 1) -> issues 2 AXI AR beats!
         dec_tlu_mrac_ff[18] = 1'b0; // region 9 uncacheable
         dec_tlu_mrac_ff[19] = 1'b1; // region 9 side-effect bit set to 1 to catch wrong bit indexing
         ic_rd_hit = 4'b0000;        // force cache miss
         exu_flush_final = 1'b1;
         exu_flush_path_final = 31'h4800_0000; // byte addr 0x9000_0000 (region 9)
         step_clk(); // F1 clocked into F2

         exu_flush_final = 1'b0;
         step_clk(); // F2 miss triggers miss_state!

         ar_beats = 0;
         timeout = 0;
         while (ar_beats < 2 && timeout < 30) begin
            @(negedge clk);
            if (ifu_axi_arvalid && ifu_axi_arready) ar_beats++;
            step_clk();
            timeout++;
         end
         if (ar_beats != 2) fail("Uncacheable I-Cache miss did not issue 2 AXI read beats");
         repeat (2) step_clk();
         if (ifu_axi_arvalid) fail("Uncacheable I-Cache miss issued more than 2 AXI read beats");

         // Return the 2 critical-word beats (tags 0 and 1) and verify ic_crit_wd_rdy asserts and miss returns to idle!
         ifu_axi_rvalid = 1'b1;
         ifu_axi_rid    = 3'd0;
         ifu_axi_rdata  = 64'h1111_2222_3333_4444;
         ifu_axi_rresp  = 2'b00;
         step_clk();

         ifu_axi_rid    = 3'd1;
         ifu_axi_rdata  = 64'h5555_6666_7777_8888;
         step_clk();

         ifu_axi_rvalid = 1'b0;
         timeout = 0;
         while (!ic_crit_wd_rdy && timeout < 10) begin
            step_clk();
            timeout++;
         end
         if (!ic_crit_wd_rdy) fail("ic_crit_wd_rdy never asserted after both critical-word beats returned");
         timeout = 0;
         while (!ifu_miss_state_idle && timeout < 20) begin
            step_clk();
            timeout++;
         end
         if (!ifu_miss_state_idle) fail("Uncacheable miss did not return to ifu_miss_state_idle after 2 beats");
      end

      // =========================================================================
      // Phase 3: ICCM Region Out-of-Range Access Fault & Single-Bit ECC Correction State Machine
      // =========================================================================
      begin
         // 3A: Fetch in ICCM region 0xe but outside [0xee000000, 0xee07ffff], e.g. 0xee08_0000 -> ic_access_fault_f2 = 8'hff!
         ic_rd_hit = 4'b0001;
         exu_flush_final = 1'b1;
         exu_flush_path_final = 31'h7704_0000; // byte addr 0xee08_0000 (in region 0xe, outside 512KB ICCM)
         step_clk(); // F1 clocked into F2

         exu_flush_final = 1'b0;
         #1;
         if (ic_access_fault_f2 !== 8'hff) begin
            $display("ic_access_fault_f2=%h (exp ff)", ic_access_fault_f2);
            fail("ICCM region out-of-range fetch did not assert ic_access_fault_f2=8'hff");
         end
         step_clk();

         // 3B-1: Non-error flush during ECC_WFF (dec_tlu_flush_err_wb = 0) must return to ERR_IDLE without asserting iccm_wren
         ifu_icache_sb_error_val = 1'b1;
         step_clk();
         ifu_icache_sb_error_val = 1'b0;
         step_clk(); // perr_state enters ECC_WFF

         dec_tlu_flush_err_wb = 1'b0;
         exu_flush_final = 1'b1;
         exu_flush_path_final = 31'h4000_0000;
         step_clk(); // perr_state transitions ECC_WFF -> ERR_IDLE

         exu_flush_final = 1'b0;
         #1;
         if (ic_dma_active || iccm_wren) begin
            fail("Non-error flush in ECC_WFF wrongly entered ECC_CORR");
         end
         step_clk();

         // 3B-2: Error flush during ECC_WFF (dec_tlu_flush_err_wb = 1) must transition ECC_WFF -> ECC_CORR and assert ic_dma_active & iccm_wren
         ifu_icache_sb_error_val = 1'b1;
         step_clk();
         ifu_icache_sb_error_val = 1'b0;
         step_clk(); // perr_state enters ECC_WFF

         dec_tlu_flush_err_wb = 1'b1;
         exu_flush_final = 1'b1;
         exu_flush_path_final = 31'h4000_0000;
         step_clk(); // perr_state transitions ECC_WFF -> ECC_CORR!

         dec_tlu_flush_err_wb = 1'b0;
         exu_flush_final = 1'b0;
         #1;
         if (!ic_dma_active || !iccm_wren) begin
            $display("ECC_CORR: ic_dma_active=%b iccm_wren=%b", ic_dma_active, iccm_wren);
            fail("Single-bit ICCM ECC correction state (ECC_CORR) did not assert ic_dma_active and iccm_wren");
         end
         step_clk();
      end

      $display("PASS veer_ifu_bp_mem_top seed=%0d", SEED);
      $finish(0);
   end

endmodule
