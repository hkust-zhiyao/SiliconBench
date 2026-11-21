`timescale 1ns/1ps
module tb #(
   parameter int SEED = 101
);
   import eh2_pkg::*;
`include "eh2_param.vh";

   logic                                   clk = 1'b0;
   logic                                   rst_l = 1'b0;
   logic                                   scan_mode = 1'b0;

   logic                                   tid;
   logic                                   ifc_select_tid_f1;
   logic                                   dec_i0_tid_d;
   logic                                   dec_i1_tid_d;

   logic                                   ic_hit_f2;
   logic                                   ic_crit_wd_rdy;
   logic                                   ifu_ic_mb_empty;
   logic                                   dec_tlu_flush_noredir_wb;
   logic                                   dec_tlu_flush_mp_wb;
   logic                                   dec_tlu_flush_lower_wb;
   logic                                   exu_flush_final;
   logic [pt.XLEN-1:1]                     exu_flush_path_final;
   logic [pt.XLEN-1:1]                     dec_tlu_flush_path_wb;
   logic                                   exu_flush_final_early;
   logic [pt.XLEN-1:1]                     exu_flush_path_final_early;
   logic                                   ifu_bp_kill_next_f2;
   logic [pt.XLEN-1:1]                     ifu_bp_btb_target_f2;
   logic                                   ic_dma_active;
   logic                                   ic_write_stall;
   logic                                   dma_iccm_stall_any;
   logic [pt.XLEN-1:0]                     dec_tlu_mrac_ff;

   logic                                   dec_i1_cancel_e1;
   logic                                   ifu_async_error_start;
   logic [3:0]                             iccm_rd_ecc_double_err;
   logic [3:0]                             ic_access_fault_f2;
   logic [1:0]                             ic_access_fault_type_f2;
   logic                                   dec_i0_decode_d;
   logic                                   dec_i1_decode_d;
   logic [63:0]                            ifu_fetch_data_f2;
   logic [3:0]                             ic_fetch_val_f2;

   logic [pt.BHT_GHR_SIZE-1:0]             ifu_bp_fghr_f2;
   logic [pt.BTB_TOFFSET_SIZE-1:0]         ifu_bp_poffset_f2;
   logic [3:0][$clog2(pt.BTB_SIZE)-1:0]    ifu_bp_fa_index_f2;
   logic [3:0]                             ifu_bp_hist0_f2;
   logic [3:0]                             ifu_bp_hist1_f2;
   logic [3:0]                             ifu_bp_pc4_f2;
   logic [3:0]                             ifu_bp_way_f2;
   logic [3:0]                             ifu_bp_valid_f2;
   logic [3:0]                             ifu_bp_ret_f2;

   logic                                   dbg_cmd_valid;
   logic                                   dbg_cmd_tid;
   logic                                   dbg_cmd_write;
   logic [1:0]                             dbg_cmd_type;
   logic [pt.XLEN-1:0]                     dbg_cmd_addr;

   logic                                   fetch_uncacheable_f1;
   logic [pt.XLEN-1:1]                     fetch_addr_f1;
   logic [pt.XLEN-1:1]                     fetch_addr_bf;
   logic [pt.XLEN-1:1]                     fetch_addr_f2;
   logic [pt.BTB_ADDR_HI:pt.BTB_ADDR_LO]   fetch_btb_rd_addr_f1;
   logic [pt.BTB_ADDR_HI:pt.BTB_ADDR_LO]   fetch_btb_rd_addr_p1_f1;
   logic                                   fetch_req_bf;
   logic                                   fetch_req_f1;
   logic                                   fetch_req_f1_raw;
   logic                                   fetch_req_f2;
   logic                                   pmu_fetch_stall;
   logic                                   iccm_access_f1;
   logic                                   region_acc_fault_f1;
   logic                                   dma_access_ok;
   logic                                   ready;

   logic                                   ifu_fb_consume1;
   logic                                   ifu_fb_consume2;
   logic                                   ifu_i0_valid;
   logic                                   ifu_i1_valid;
   logic [1:0]                             pmu_instr_aligned;
   logic                                   pmu_align_stall;

   logic                                   ib3_valid_d;
   logic                                   ib2_valid_d;
   logic                                   ib1_valid_d;
   logic                                   ib0_valid_d;
   logic                                   ib0_valid_in;
   logic                                   ib0_lsu_in;
   logic                                   ib0_mul_in;
   logic                                   ib0_i0_only_in;

   logic [31:0]                            i0_instr_d;
   logic [31:0]                            i1_instr_d;
   logic [pt.XLEN-1:1]                     i0_pc_d;
   logic [pt.XLEN-1:1]                     i1_pc_d;
   logic                                   i0_pc4_d;
   logic                                   i1_pc4_d;
   eh2_br_pkt_t                            i0_br_p;
   eh2_br_pkt_t                            i1_br_p;
   logic [pt.BTB_ADDR_HI:pt.BTB_ADDR_LO]   i0_bp_index;
   logic [pt.BHT_GHR_SIZE-1:0]             i0_bp_fghr;
   logic [pt.BTB_BTAG_SIZE-1:0]            i0_bp_btag;
   logic [pt.BTB_TOFFSET_SIZE-1:0]         i0_bp_toffset;
   logic [pt.BTB_ADDR_HI:pt.BTB_ADDR_LO]   i1_bp_index;
   logic [pt.BHT_GHR_SIZE-1:0]             i1_bp_fghr;
   logic [pt.BTB_BTAG_SIZE-1:0]            i1_bp_btag;
   logic [pt.BTB_TOFFSET_SIZE-1:0]         i1_bp_toffset;
   logic [$clog2(pt.BTB_SIZE)-1:0]         i0_bp_fa_index;
   logic                                   i0_icaf_d;
   logic                                   i1_icaf_d;
   logic                                   i0_icaf_second_d;
   logic [1:0]                             i0_icaf_type_d;
   logic                                   i0_dbecc_d;
   logic                                   i1_dbecc_d;
   logic                                   debug_wdata_rs1_d;
   logic                                   debug_fence_d;
   logic                                   i0_debug_valid_d;
   logic [15:0]                            i0_cinst_d;
   logic [15:0]                            i1_cinst_d;
   eh2_predecode_pkt_t                     i0_predecode;
   eh2_predecode_pkt_t                     i1_predecode;

   always #5 clk = ~clk;

   eh2_ifu_ib_top dut (.*);

   localparam logic [15:0] C_NOP     = 16'h0001;
   localparam logic [31:0] EXP_C_NOP = 32'h0000_0013;
   localparam logic [15:0] C_ADDI_X1 = 16'h0085;
   localparam logic [31:0] EXP_ADDI1 = 32'h0010_8093;
   localparam logic [31:0] RVI_ADD1  = 32'h0020_81b3;
   localparam logic [31:0] RVI_SUB2  = 32'h4041_8233;
   localparam logic [31:0] RVI_XOR3  = 32'h0041_c2b3;

   task automatic clear_inputs();
      tid                        = 1'b0;
      ifc_select_tid_f1          = 1'b0;
      dec_i0_tid_d               = 1'b0;
      dec_i1_tid_d               = 1'b0;
      ic_hit_f2                  = 1'b0;
      ic_crit_wd_rdy             = 1'b0;
      ifu_ic_mb_empty            = 1'b1;
      dec_tlu_flush_noredir_wb   = 1'b0;
      dec_tlu_flush_mp_wb        = 1'b0;
      dec_tlu_flush_lower_wb     = 1'b0;
      exu_flush_final            = 1'b0;
      exu_flush_path_final       = 31'h0;
      dec_tlu_flush_path_wb      = 31'h0;
      exu_flush_final_early      = 1'b0;
      exu_flush_path_final_early = 31'h0;
      ifu_bp_kill_next_f2        = 1'b0;
      ifu_bp_btb_target_f2       = 31'h0;
      ic_dma_active              = 1'b0;
      ic_write_stall             = 1'b0;
      dma_iccm_stall_any         = 1'b0;
      dec_tlu_mrac_ff            = 32'h5555_5555;
      dec_i1_cancel_e1           = 1'b0;
      ifu_async_error_start      = 1'b0;
      iccm_rd_ecc_double_err     = 4'b0000;
      ic_access_fault_f2         = 4'b0000;
      ic_access_fault_type_f2    = 2'b00;
      dec_i0_decode_d            = 1'b0;
      dec_i1_decode_d            = 1'b0;
      ifu_fetch_data_f2          = 64'h0000_0013_0000_0013;
      ic_fetch_val_f2            = 4'b0000;
      ifu_bp_fghr_f2             = '0;
      ifu_bp_poffset_f2          = '0;
      ifu_bp_fa_index_f2         = '0;
      ifu_bp_hist0_f2            = '0;
      ifu_bp_hist1_f2            = '0;
      ifu_bp_pc4_f2              = '0;
      ifu_bp_way_f2              = '0;
      ifu_bp_valid_f2            = '0;
      ifu_bp_ret_f2              = '0;
      dbg_cmd_valid              = 1'b0;
      dbg_cmd_tid                = 1'b0;
      dbg_cmd_write              = 1'b0;
      dbg_cmd_type               = 2'b00;
      dbg_cmd_addr               = 32'h0;
   endtask

   task automatic do_flush(input logic [31:1] target_pc);
      @(negedge clk);
      exu_flush_final          = 1'b1;
      exu_flush_path_final     = target_pc;
      dec_tlu_flush_noredir_wb = 1'b0;
      ic_hit_f2                = 1'b0;
      ic_fetch_val_f2          = 4'b0000;
      dec_i0_decode_d          = 1'b0;
      dec_i1_decode_d          = 1'b0;
      #1;
      if (!fetch_req_f1) begin
         @(posedge clk);
         @(negedge clk);
         #1;
      end
      if (fetch_addr_f1 !== target_pc || fetch_req_f1 !== 1'b1) begin
         $display("FAIL: flush redirect addr_f1=%h req_f1=%b expected %h", fetch_addr_f1, fetch_req_f1, target_pc);
         $fatal(1);
      end
      @(posedge clk);
      @(negedge clk);
      exu_flush_final = 1'b0;
      ic_hit_f2       = 1'b1;
      #1;
      if (fetch_req_f2 !== 1'b1 || fetch_addr_f2 !== target_pc) begin
         $display("FAIL: post-flush f2 req_f2=%b addr_f2=%h expected %h", fetch_req_f2, fetch_addr_f2, target_pc);
         $fatal(1);
      end
   endtask

   initial begin
      clear_inputs();
      rst_l = 1'b0;
      repeat (3) @(posedge clk);
      @(negedge clk);
      rst_l = 1'b1;
      @(posedge clk);

      // ------------------------------------------------------------------
      // Phase 1: Flush startup, 4-buffer mass balance, BTB target redirect, DMA stall
      // ------------------------------------------------------------------
      do_flush(31'h0000_0100);
      ic_hit_f2            = 1'b1;
      ic_fetch_val_f2      = 4'b1111;
      ifu_fetch_data_f2    = {RVI_ADD1, C_ADDI_X1, C_NOP};
      ifu_bp_kill_next_f2  = 1'b1;
      ifu_bp_btb_target_f2 = 31'h0000_0200;
      #1;
      if (fetch_addr_bf !== 31'h0000_0200 || fetch_req_f1 !== 1'b0) begin
         $display("FAIL: BTB target redirect addr_bf=%h req_f1=%b", fetch_addr_bf, fetch_req_f1);
         $fatal(1);
      end
      @(posedge clk);

      // Next cycle: f1 is at 31'h0000_0200; check DMA stall blocks fetch_req_f1
      @(negedge clk);
      ifu_bp_kill_next_f2 = 1'b0;
      ic_hit_f2           = 1'b1;
      ic_fetch_val_f2     = 4'b0000;
      #1;
      if (fetch_addr_f1 !== 31'h0000_0200 || fetch_req_f1 !== 1'b1) begin
         $display("FAIL: post-BTB f1 addr_f1=%h req_f1=%b", fetch_addr_f1, fetch_req_f1);
         $fatal(1);
      end
      ic_dma_active = 1'b1;
      #1;
      if (fetch_req_f1 !== 1'b0) begin
         $display("FAIL: ic_dma_active did not gate fetch_req_f1");
         $fatal(1);
      end
      ic_dma_active = 1'b0;
      #1;
      if (fetch_req_f1 !== 1'b1) begin
         $display("FAIL: fetch_req_f1 did not recover after ic_dma_active cleared");
         $fatal(1);
      end

      // ------------------------------------------------------------------
      // Phase 2: Fill IB (4 entries) and fill all 4 IFU fetch buffers (fb_full_f1),
      // verify fetch_req_f1=0 when full, and verify fetch_req_f1=1 when fb_consume1/2 frees space!
      // ------------------------------------------------------------------
      do_flush(31'h0000_0200);
      // Beat 0 at 31'h200: 4 compressed instructions (C_NOP, C_ADDI_X1, C_NOP, C_ADDI_X1)
      // Cycle A: Beat 0 hits -> goes into f0
      ic_hit_f2         = 1'b1;
      ic_fetch_val_f2   = 4'b1111;
      ifu_fetch_data_f2 = {C_ADDI_X1, C_NOP, C_ADDI_X1, C_NOP};
      dec_i0_decode_d   = 1'b0;
      dec_i1_decode_d   = 1'b0;
      @(posedge clk);

      // Cycle B: Beat 1 hits -> f0 shifts 4B into IB0/IB1, Beat 1 goes into f1
      @(negedge clk);
      ic_hit_f2         = 1'b1;
      ic_fetch_val_f2   = 4'b1111;
      ifu_fetch_data_f2 = {RVI_SUB2, RVI_ADD1};
      @(posedge clk);

      // Cycle C: Beat 2 hits -> f0 finishes shifting into IB2/IB3 (consume_fb0=1 -> fb_consume1=1!),
      // so IB0..IB3 are now FULL (ib3_valid_d=1, ib2_valid_d=1).
      @(negedge clk);
      ic_hit_f2         = 1'b1;
      ic_fetch_val_f2   = 4'b1111;
      ifu_fetch_data_f2 = {RVI_XOR3, RVI_ADD1};
      #1;
      if (ifu_fb_consume1 !== 1'b1) begin
         $display("FAIL: expected ifu_fb_consume1=1 when f0 empties into IB2/IB3");
         $fatal(1);
      end
      @(posedge clk);

      // Now IB0..IB3 are full, and IFU has 2 beats (f0, f1) occupied.
      // Let 2 more beats hit (Cycle D and Cycle E) to fill all 4 IFU fetch buffers (f0, f1, f2, f3)!
      @(negedge clk);
      #1;
      if (ib3_valid_d !== 1'b1 || ib2_valid_d !== 1'b1 || ib1_valid_d !== 1'b1 || ib0_valid_d !== 1'b1) begin
         $display("FAIL: expected IB0..IB3 all valid");
         $fatal(1);
      end
      ic_hit_f2         = 1'b1;
      ic_fetch_val_f2   = 4'b1111;
      ifu_fetch_data_f2 = {RVI_SUB2, RVI_XOR3};
      @(posedge clk);

      @(negedge clk);
      ic_hit_f2         = 1'b1;
      ic_fetch_val_f2   = 4'b1111;
      ifu_fetch_data_f2 = {RVI_ADD1, RVI_SUB2};
      @(posedge clk);

      // Now all 4 fetch buffers (f0..f3) are full (fb_full_f1 == 1), and IB is stalled!
      @(negedge clk);
      ic_hit_f2       = 1'b1;
      ic_fetch_val_f2 = 4'b0000;
      #1;
      if (fetch_req_f1 !== 1'b0 || pmu_fetch_stall !== 1'b1) begin
         $display("FAIL: expected fetch_req_f1=0 and pmu_fetch_stall=1 when fb_full_f1=1 (got req_f1=%b stall=%b)",
                  fetch_req_f1, pmu_fetch_stall);
         $fatal(1);
      end

      // Now drain 2 instructions from IB (shift2) so IB2/IB3 become free next cycle, allowing f0 (which has two 4B instructions) to shift 8B and assert ifu_fb_consume1=1 while fb_full_f1==1!
      dec_i0_decode_d = 1'b1;
      dec_i1_decode_d = 1'b1;
      @(posedge clk);

      @(negedge clk);
      dec_i0_decode_d = 1'b0;
      dec_i1_decode_d = 1'b0;
      #1;
      if (ifu_fb_consume1 !== 1'b1 || fetch_req_f1 !== 1'b1 || pmu_fetch_stall !== 1'b0) begin
         $display("FAIL: expected ifu_fb_consume1=1 and fetch_req_f1=1 when consuming from full fetch buffer (c1=%b req_f1=%b stall=%b)",
                  ifu_fb_consume1, fetch_req_f1, pmu_fetch_stall);
         $fatal(1);
      end
      @(posedge clk);

      // ------------------------------------------------------------------
      // Phase 3: Test dec_i1_cancel_e1 rollback using ibsave / bpsave after shift2
      // ------------------------------------------------------------------
      do_flush(31'h0000_0300);
      // Beat 0 at 31'h300: 4 compressed instructions:
      //   [0] C_NOP     at 31'h300
      //   [1] C_ADDI_X1 at 31'h301
      //   [2] C_ADDI_X1 at 31'h302
      //   [3] C_NOP     at 31'h303
      ic_hit_f2         = 1'b1;
      ic_fetch_val_f2   = 4'b1111;
      ifu_fetch_data_f2 = {C_NOP, C_ADDI_X1, C_ADDI_X1, C_NOP};
      ifu_bp_fghr_f2    = 7'h5a;
      ifu_bp_poffset_f2 = 12'h345;
      @(posedge clk);

      // Cycle 1: aligner puts [0] into IB0, [1] into IB1
      @(negedge clk);
      ic_hit_f2       = 1'b1;
      ic_fetch_val_f2 = 4'b0000;
      @(posedge clk);

      // Cycle 2: aligner puts [2] into IB2, [3] into IB3
      @(negedge clk);
      @(posedge clk);

      // Cycle 3: IB0..IB3 hold [0], [1], [2], [3]. Decode both i0 and i1 (shift2 = 1)!
      // ibsaveff captures ib1 ([1] = EXP_ADDI1 at 31'h301), and IB0/IB1 become [2] (31'h302) and [3] (31'h303)
      @(negedge clk);
      #1;
      if (ib0_valid_d !== 1'b1 || i0_pc_d !== 31'h300 || ib1_valid_d !== 1'b1 || i1_pc_d !== 31'h301 ||
          ib2_valid_d !== 1'b1 || ib3_valid_d !== 1'b1) begin
         $display("FAIL: pre-shift2 IB state mismatch");
         $fatal(1);
      end
      dec_i0_decode_d = 1'b1;
      dec_i1_decode_d = 1'b1;
      @(posedge clk);

      // Cycle 4: Now IB0=[2] (31'h302), IB1=[3] (31'h303), ibval=4'b0011.
      // Assert dec_i1_cancel_e1 = 1 (with shift0 = 1) to cancel i1 from E1 and restore [1] (31'h301) from ibsave into IB0,
      // while pushing [2] (31'h302) into IB1 and [3] (31'h303) into IB2 (ibval becomes 4'b0111)!
      @(negedge clk);
      dec_i0_decode_d  = 1'b0;
      dec_i1_decode_d  = 1'b0;
      dec_i1_cancel_e1 = 1'b1;
      #1;
      if (i0_pc_d !== 31'h302 || i1_pc_d !== 31'h303) begin
         $display("FAIL: post-shift2 IB0/IB1 PC mismatch got %h %h", i0_pc_d, i1_pc_d);
         $fatal(1);
      end
      @(posedge clk);

      @(negedge clk);
      dec_i1_cancel_e1 = 1'b0;
      #1;
      if (ib0_valid_d !== 1'b1 ||ib1_valid_d !== 1'b1 || ib2_valid_d !== 1'b1 || ib3_valid_d !== 1'b0 ||
          i0_instr_d !== EXP_ADDI1 || i0_pc_d !== 31'h301 || i0_bp_fghr !== 7'h5a || i0_bp_toffset !== 12'h345 ||
          i1_instr_d !== EXP_ADDI1 || i1_pc_d !== 31'h302) begin
         $display("FAIL: dec_i1_cancel_e1 rollback failed: ibval=%b%b%b%b i0=%h@%h (fghr=%h toff=%h) i1=%h@%h",
                  ib3_valid_d, ib2_valid_d, ib1_valid_d, ib0_valid_d,
                  i0_instr_d, i0_pc_d, i0_bp_fghr, i0_bp_toffset, i1_instr_d, i1_pc_d);
         $fatal(1);
      end
      @(posedge clk);

      // ------------------------------------------------------------------
      // Phase 4: Cross-beat f1_shift_2B, f1_shift_4B, f1_shift_6B & dual-buffer consume2
      // ------------------------------------------------------------------
      // 4A: f0val=4'b0001 (1 halfword) + f1val=4'b1111 (4 halfwords), shift_8B (two 4B instructions) -> f1_shift_6B!
      do_flush(31'h0000_0400);
      ic_hit_f2         = 1'b1;
      ic_fetch_val_f2   = 4'b0001; // 1 halfword: RVI_ADD1[15:0] at 31'h400
      ifu_fetch_data_f2 = {48'h0, RVI_ADD1[15:0]};
      @(posedge clk);

      @(negedge clk);
      ic_hit_f2         = 1'b1;
      ic_fetch_val_f2   = 4'b1111; // 4 halfwords at 31'h404: [0]=RVI_ADD1[31:16], [1:2]=RVI_SUB2, [3]=C_ADDI_X1 (at 31'h407)
      ifu_fetch_data_f2 = {C_ADDI_X1, RVI_SUB2, RVI_ADD1[31:16]};
      @(posedge clk);

      // At this cycle, f0 has 1 halfword, f1 has 4 halfwords -> aligner dual-issues RVI_ADD1 (4B) + RVI_SUB2 (4B) -> shift_8B = 1!
      // This triggers f1_shift_6B = 1, leaving 1 halfword (C_ADDI_X1 at 31'h407) in the new f0!
      @(negedge clk);
      ic_hit_f2       = 1'b1;
      ic_fetch_val_f2 = 4'b0000;
      #1;
      if (ifu_i0_valid !== 1'b1 || ifu_i1_valid !== 1'b1 || pmu_instr_aligned !== 2'b11 ||
          ifu_fb_consume1 !== 1'b1 || ifu_fb_consume2 !== 1'b0) begin
         $display("FAIL: 4A shift_8B (f1_shift_6B) align mismatch");
         $fatal(1);
      end
      @(posedge clk);

      // Next cycle, new f0 has C_ADDI_X1 at PC=31'h407, which aligns into IB2!
      @(negedge clk);
      #1;
      if (ib0_valid_d !== 1'b1 || i0_instr_d !== RVI_ADD1 || i0_pc_d !== 31'h400 ||
          ib1_valid_d !== 1'b1 || i1_instr_d !== RVI_SUB2 || i1_pc_d !== 31'h405) begin
         $display("FAIL: 4A IB0/IB1 mismatch got i0=%h@%h i1=%h@%h", i0_instr_d, i0_pc_d, i1_instr_d, i1_pc_d);
         $fatal(1);
      end
      dec_i0_decode_d = 1'b1;
      dec_i1_decode_d = 1'b1;
      @(posedge clk);

      @(negedge clk);
      dec_i0_decode_d = 1'b0;
      dec_i1_decode_d = 1'b0;
      #1;
      if (ib0_valid_d !== 1'b1 || i0_instr_d !== EXP_ADDI1 || i0_pc_d !== 31'h407) begin
         $display("FAIL: 4A f1_shift_6B remaining halfword mismatch got valid=%b instr=%h pc=%h expected %h@407",
                  ib0_valid_d, i0_instr_d, i0_pc_d, EXP_ADDI1);
         $fatal(1);
      end
      @(posedge clk);

      // 4B: f0val=4'b0011 (2 halfwords) + f1val=4'b1111 (4 halfwords), shift_8B (two 4B instructions) -> f1_shift_4B!
      do_flush(31'h0000_0500);
      ic_hit_f2         = 1'b1;
      ic_fetch_val_f2   = 4'b0011; // 2 halfwords: RVI_ADD1 (4B) at 31'h500
      ifu_fetch_data_f2 = {32'h0, RVI_ADD1};
      @(posedge clk);

      @(negedge clk);
      ic_hit_f2         = 1'b1;
      ic_fetch_val_f2   = 4'b1111; // 4 halfwords at 31'h504: [0:1]=RVI_SUB2 (4B), [2]=C_ADDI_X1 (at 31'h506), [3]=C_NOP
      ifu_fetch_data_f2 = {C_NOP, C_ADDI_X1, RVI_SUB2};
      @(posedge clk);

      // Wait: if f0 has 2 halfwords (RVI_ADD1), on Cycle 1 before f1 arrives, RVI_ADD1 is already a complete 4B instruction in f0!
      // So RVI_ADD1 will align on Cycle 1 unless IB is full!
      // Instead, to have f0val=4'b0011 and f1val=4'b1111 simultaneously for shift_8B, make f0=[0]=C_NOP (consumed first) or hold IB full!
      // Or even simpler: f0val=4'b0001 (1 halfword: RVI_ADD1[15:0]) + f1val=4'b1111 ([0]=RVI_ADD1[31:16], [1]=C_NOP, [2]=C_ADDI_X1, [3]=C_NOP) -> i0=RVI_ADD1 (4B), i1=C_NOP (2B) -> shift_6B = 1 with f0val=4'b0001 -> f1_shift_4B = 1!
      do_flush(31'h0000_0500);
      ic_hit_f2         = 1'b1;
      ic_fetch_val_f2   = 4'b0001; // 1 halfword: RVI_ADD1[15:0] at 31'h500
      ifu_fetch_data_f2 = {48'h0, RVI_ADD1[15:0]};
      @(posedge clk);

      @(negedge clk);
      ic_hit_f2         = 1'b1;
      ic_fetch_val_f2   = 4'b1111; // [0]=RVI_ADD1[31:16], [1]=C_NOP (at 31'h505), [2]=C_ADDI_X1 (at 31'h506), [3]=C_NOP
      ifu_fetch_data_f2 = {C_NOP, C_ADDI_X1, C_NOP, RVI_ADD1[31:16]};
      @(posedge clk);

      // Now f0val=4'b0001, f1val=4'b1111 -> i0=RVI_ADD1 (4B), i1=C_NOP (2B) -> shift_6B=1 -> f1_shift_4B=1!
      @(negedge clk);
      ic_hit_f2       = 1'b1;
      ic_fetch_val_f2 = 4'b0000;
      #1;
      if (pmu_instr_aligned !== 2'b11 || ifu_fb_consume1 !== 1'b1) begin
         $display("FAIL: 4B shift_6B (f1_shift_4B) align mismatch");
         $fatal(1);
      end
      @(posedge clk);

      @(negedge clk);
      dec_i0_decode_d = 1'b1;
      dec_i1_decode_d = 1'b1;
      @(posedge clk);

      @(negedge clk);
      dec_i0_decode_d = 1'b0;
      dec_i1_decode_d = 1'b0;
      #1;
      if (ib0_valid_d !== 1'b1 || i0_instr_d !== EXP_ADDI1 || i0_pc_d !== 31'h506) begin
         $display("FAIL: 4B f1_shift_4B remaining halfword mismatch got instr=%h pc=%h expected %h@506",
                  i0_instr_d, i0_pc_d, EXP_ADDI1);
         $fatal(1);
      end
      @(posedge clk);

      // 4C: Dual-buffer consumption (ifu_fb_consume2 = 1) simultaneously with a new hitting fetch
      // AND split 32-bit instruction fault / ECC attribution!
      do_flush(31'h0000_0600);
      // Beat 0: 1 valid halfword (4'b0001) with RVI_SUB2[15:0], no fault, ictype=2'b01
      ic_hit_f2               = 1'b1;
      ic_fetch_val_f2         = 4'b0001;
      ifu_fetch_data_f2       = {48'h0, RVI_SUB2[15:0]};
      ic_access_fault_f2      = 4'b0000;
      ic_access_fault_type_f2 = 2'b01;
      @(posedge clk);

      // Beat 1: 1 valid halfword (4'b0001) with RVI_SUB2[31:16], fault on halfword 0, ictype=2'b10
      @(negedge clk);
      ic_hit_f2               = 1'b1;
      ic_fetch_val_f2         = 4'b0001;
      ifu_fetch_data_f2       = {48'h0, RVI_SUB2[31:16]};
      ic_access_fault_f2      = 4'b0001;
      ic_access_fault_type_f2 = 2'b10;
      @(posedge clk);

      // Cycle where f0 and f1 are both consumed (ifu_fb_consume2 = 1) while Beat 2 hits!
      @(negedge clk);
      ic_hit_f2               = 1'b1;
      ic_fetch_val_f2         = 4'b1111;
      ifu_fetch_data_f2       = {RVI_XOR3, RVI_ADD1};
      ic_access_fault_f2      = 4'b0000;
      ic_access_fault_type_f2 = 2'b00;
      #1;
      if (ifu_fb_consume2 !== 1'b1 || ifu_fb_consume1 !== 1'b0) begin
         $display("FAIL: 4C expected ifu_fb_consume2=1 got c1=%b c2=%b", ifu_fb_consume1, ifu_fb_consume2);
         $fatal(1);
      end
      @(posedge clk);

      @(negedge clk);
      ic_hit_f2         = 1'b1;
      ic_fetch_val_f2   = 4'b1111;
      ifu_fetch_data_f2 = {RVI_ADD1, RVI_SUB2};
      #1;
      if (ib0_valid_d !== 1'b1 || i0_instr_d !== RVI_SUB2 || i0_pc_d !== 31'h600 ||
          i0_icaf_d !== 1'b1 || i0_icaf_second_d !== 1'b1 || i0_icaf_type_d !== 2'b10) begin
         $display("FAIL: 4C split fault attribution mismatch v=%b instr=%h icaf=%b icaf2=%b type=%b",
                  ib0_valid_d, i0_instr_d, i0_icaf_d, i0_icaf_second_d, i0_icaf_type_d);
         $fatal(1);
      end
      @(posedge clk);
      @(negedge clk);
      ic_hit_f2         = 1'b1;
      ic_fetch_val_f2   = 4'b1111;
      ifu_fetch_data_f2 = {RVI_SUB2, RVI_XOR3};
      @(posedge clk);
      @(negedge clk);
      ic_hit_f2       = 1'b1;
      ic_fetch_val_f2 = 4'b0000;
      #1;
      // After 2 occupied -> consume2 + 1 hit (net 1) -> 1 hit (net 2) -> 1 hit (net 3), buffer is NOT full yet (fetch_req_f1 == 1)!
      if (fetch_req_f1 !== 1'b1 || pmu_fetch_stall !== 1'b0) begin
         $display("FAIL: 4C mass balance corrupted after consume2 + winning fetch (req_f1=%b stall=%b)",
                  fetch_req_f1, pmu_fetch_stall);
         $fatal(1);
      end
      @(posedge clk);

      // 4D: Faulting i1 suppression (when i1 has icaf or dbecc, i1_valid must be 0 so only i0 issues!)
      do_flush(31'h0000_0680);
      ic_hit_f2          = 1'b1;
      ic_fetch_val_f2    = 4'b1111;
      ifu_fetch_data_f2  = {RVI_SUB2, C_ADDI_X1, C_NOP}; // i0=C_NOP (2B), i1=C_ADDI_X1 (2B at halfword 1)
      ic_access_fault_f2 = 4'b0010; // fault on halfword 1 (i1)
      @(posedge clk);

      @(negedge clk);
      ic_hit_f2          = 1'b1;
      ic_fetch_val_f2    = 4'b0000;
      ic_access_fault_f2 = 4'b0000;
      #1;
      if (ifu_i0_valid !== 1'b1 || ifu_i1_valid !== 1'b0 || pmu_instr_aligned !== 2'b01) begin
         $display("FAIL: 4D faulting i1 was not suppressed: i0_v=%b i1_v=%b aligned=%b",
                  ifu_i0_valid, ifu_i1_valid, pmu_instr_aligned);
         $fatal(1);
      end
      @(posedge clk);

      // ------------------------------------------------------------------
      // Phase 5: Asynchronous error stall lock and flush recovery
      // ------------------------------------------------------------------
      do_flush(31'h0000_0700);
      ic_hit_f2             = 1'b1;
      ic_fetch_val_f2       = 4'b1111;
      ifu_fetch_data_f2     = {RVI_SUB2, RVI_ADD1};
      ifu_async_error_start = 1'b1;
      @(posedge clk);

      @(negedge clk);
      ic_hit_f2             = 1'b1;
      ic_fetch_val_f2       = 4'b0000;
      ifu_async_error_start = 1'b0;
      #1;
      if (pmu_instr_aligned !== 2'b00 || ib0_valid_d !== 1'b0) begin
         $display("FAIL: error_stall did not block aligner shift (aligned=%b ib0=%b)", pmu_instr_aligned, ib0_valid_d);
         $fatal(1);
      end
      @(posedge clk);

      // Flush clears error_stall
      do_flush(31'h0000_0740);
      ic_hit_f2         = 1'b1;
      ic_fetch_val_f2   = 4'b1111;
      ifu_fetch_data_f2 = {RVI_SUB2, RVI_ADD1};
      @(posedge clk);
      @(negedge clk);
      ic_hit_f2       = 1'b1;
      ic_fetch_val_f2 = 4'b0000;
      #1;
      if (pmu_instr_aligned !== 2'b11) begin
         $display("FAIL: error_stall not cleared by flush");
         $fatal(1);
      end
      @(posedge clk);

      // ------------------------------------------------------------------
      // Phase 6: Halted debug command injection in eh2_dec_ib_ctl
      // ------------------------------------------------------------------
      @(negedge clk);
      exu_flush_final          = 1'b1;
      dec_tlu_flush_noredir_wb = 1'b1; // halt fetch and flush aligner
      @(posedge clk);
      @(negedge clk);
      exu_flush_final          = 1'b0;
      dec_tlu_flush_noredir_wb = 1'b0;
      @(posedge clk); // flush_final=1 clears ibval on this posedge
      @(negedge clk);

      // 1) GPR read x5
      dbg_cmd_valid = 1'b1;
      dbg_cmd_tid   = 1'b0;
      dbg_cmd_write = 1'b0;
      dbg_cmd_type  = 2'h0;
      dbg_cmd_addr  = 32'd5;
      @(posedge clk);
      @(negedge clk);
      dbg_cmd_valid = 1'b0;
      #1;
      if (i0_debug_valid_d !== 1'b1 || ib0_valid_d !== 1'b1 || debug_wdata_rs1_d !== 1'b0 ||
          debug_fence_d !== 1'b0 || i0_instr_d !== {12'b0, 5'd5, 15'b110000000110011} ||
          i0_predecode.legal1 !== 1'b1 || i0_predecode.i0_only !== 1'b1) begin
         $display("FAIL: debug GPR read mismatch v=%b ib0=%b instr=%h rs1=%b fence=%b leg1=%b i0only=%b",
                  i0_debug_valid_d, ib0_valid_d, i0_instr_d, debug_wdata_rs1_d, debug_fence_d, i0_predecode.legal1, i0_predecode.i0_only);
         $fatal(1);
      end
      dec_i0_decode_d = 1'b1;
      @(posedge clk);

      // 2) GPR write x9
      @(negedge clk);
      dec_i0_decode_d = 1'b0;
      dbg_cmd_valid   = 1'b1;
      dbg_cmd_write   = 1'b1;
      dbg_cmd_type    = 2'h0;
      dbg_cmd_addr    = 32'd9;
      @(posedge clk);
      @(negedge clk);
      dbg_cmd_valid = 1'b0;
      #1;
      if (i0_debug_valid_d !== 1'b1 || ib0_valid_d !== 1'b1 || debug_wdata_rs1_d !== 1'b1 ||
          debug_fence_d !== 1'b0 || i0_instr_d !== {20'b00000000000000000110, 5'd9, 7'b0110011}) begin
         $display("FAIL: debug GPR write mismatch instr=%h", i0_instr_d);
         $fatal(1);
      end
      dec_i0_decode_d = 1'b1;
      @(posedge clk);

      // 3) CSR write 0x7c4 (debug fence)
      @(negedge clk);
      dec_i0_decode_d = 1'b0;
      dbg_cmd_valid   = 1'b1;
      dbg_cmd_write   = 1'b1;
      dbg_cmd_type    = 2'h1;
      dbg_cmd_addr    = 32'h7c4;
      @(posedge clk);
      @(negedge clk);
      dbg_cmd_valid = 1'b0;
      #1;
      if (i0_debug_valid_d !== 1'b1 || ib0_valid_d !== 1'b1 || debug_wdata_rs1_d !== 1'b1 ||
          debug_fence_d !== 1'b1 || i0_instr_d !== {12'h7c4, 20'b00000001000001110011}) begin
         $display("FAIL: debug CSR fence 0x7c4 mismatch instr=%h fence=%b", i0_instr_d, debug_fence_d);
         $fatal(1);
      end
      dec_i0_decode_d = 1'b1;
      @(posedge clk);
      @(negedge clk);
      dec_i0_decode_d = 1'b0;

      // ------------------------------------------------------------------
      // Phase 7: Seeded randomized dual-issue instruction stream verification
      // ------------------------------------------------------------------
      begin
         int unsigned rng;
         logic [31:0] exp_instr_q[$];
         logic [31:1] exp_pc_q[$];
         logic        exp_pc4_q[$];
         logic        pending_split;
         logic [15:0] pending_lo;
         logic [31:1] pending_pc;
         int          fb_occ;

         rng = SEED ^ 32'h9e37_79b9;
         do_flush(31'h0000_1000);
         exp_instr_q.delete();
         exp_pc_q.delete();
         exp_pc4_q.delete();
         pending_split = 1'b0;
         fb_occ        = 0;

         for (int cyc = 0; cyc < 160; cyc++) begin
            @(negedge clk);
            rng = (rng * 32'd1664525) + 32'd1013904223;
            dec_i0_decode_d = 1'b0;
            dec_i1_decode_d = 1'b0;
            #1;
            dec_i0_decode_d = ib0_valid_d & rng[0];
            dec_i1_decode_d = dec_i0_decode_d & ib1_valid_d & rng[1];
            #1;
            if (ib0_valid_d) begin
               if (exp_instr_q.size() == 0) begin
                  $display("FAIL: unexpected ib0_valid_d at cyc=%0d", cyc);
                  $fatal(1);
               end
               if (i0_instr_d !== exp_instr_q[0] || i0_pc_d !== exp_pc_q[0] || i0_pc4_d !== exp_pc4_q[0]) begin
                  $display("FAIL: i0 stream mismatch at cyc=%0d got instr=%h pc=%h pc4=%b exp instr=%h pc=%h pc4=%b",
                           cyc, i0_instr_d, i0_pc_d, i0_pc4_d, exp_instr_q[0], exp_pc_q[0], exp_pc4_q[0]);
                  $fatal(1);
               end
            end
            if (ib1_valid_d) begin
               if (exp_instr_q.size() < 2) begin
                  $display("FAIL: unexpected ib1_valid_d at cyc=%0d", cyc);
                  $fatal(1);
               end
               if (i1_instr_d !== exp_instr_q[1] || i1_pc_d !== exp_pc_q[1] || i1_pc4_d !== exp_pc4_q[1]) begin
                  $display("FAIL: i1 stream mismatch at cyc=%0d got instr=%h pc=%h pc4=%b exp instr=%h pc=%h pc4=%b",
                           cyc, i1_instr_d, i1_pc_d, i1_pc4_d, exp_instr_q[1], exp_pc_q[1], exp_pc4_q[1]);
                  $fatal(1);
               end
            end

            if (dec_i0_decode_d) begin
               void'(exp_instr_q.pop_front());
               void'(exp_pc_q.pop_front());
               void'(exp_pc4_q.pop_front());
            end
            if (dec_i1_decode_d) begin
               void'(exp_instr_q.pop_front());
               void'(exp_pc_q.pop_front());
               void'(exp_pc4_q.pop_front());
            end

            if (ifu_fb_consume1) fb_occ -= 1;
            if (ifu_fb_consume2) fb_occ -= 2;

            if (fb_occ < 4 && fetch_req_f2 && rng[2]) begin
               ic_hit_f2       = 1'b1;
               ic_fetch_val_f2 = 4'b1111;
               if (pending_split) begin
                  logic [15:0] hi_part;
                  hi_part = rng[3] ? RVI_SUB2[31:16] : RVI_ADD1[31:16];
                  ifu_fetch_data_f2 = { RVI_XOR3, (rng[4] ? C_ADDI_X1 : C_NOP), hi_part };
                  exp_instr_q.push_back({hi_part, pending_lo});
                  exp_pc_q.push_back(pending_pc);
                  exp_pc4_q.push_back(1'b1);
                  exp_instr_q.push_back(rng[4] ? EXP_ADDI1 : EXP_C_NOP);
                  exp_pc_q.push_back(fetch_addr_f2 + 31'd1);
                  exp_pc4_q.push_back(1'b0);
                  exp_instr_q.push_back(RVI_XOR3);
                  exp_pc_q.push_back(fetch_addr_f2 + 31'd2);
                  exp_pc4_q.push_back(1'b1);
                  pending_split = 1'b0;
               end else begin
                  case (rng[6:5])
                     2'b00: begin
                        ifu_fetch_data_f2 = {RVI_SUB2, RVI_ADD1};
                        exp_instr_q.push_back(RVI_ADD1);
                        exp_pc_q.push_back(fetch_addr_f2);
                        exp_pc4_q.push_back(1'b1);
                        exp_instr_q.push_back(RVI_SUB2);
                        exp_pc_q.push_back(fetch_addr_f2 + 31'd2);
                        exp_pc4_q.push_back(1'b1);
                     end
                     2'b01: begin
                        ifu_fetch_data_f2 = {C_ADDI_X1, C_NOP, C_ADDI_X1, C_NOP};
                        exp_instr_q.push_back(EXP_C_NOP);
                        exp_pc_q.push_back(fetch_addr_f2);
                        exp_pc4_q.push_back(1'b0);
                        exp_instr_q.push_back(EXP_ADDI1);
                        exp_pc_q.push_back(fetch_addr_f2 + 31'd1);
                        exp_pc4_q.push_back(1'b0);
                        exp_instr_q.push_back(EXP_C_NOP);
                        exp_pc_q.push_back(fetch_addr_f2 + 31'd2);
                        exp_pc4_q.push_back(1'b0);
                        exp_instr_q.push_back(EXP_ADDI1);
                        exp_pc_q.push_back(fetch_addr_f2 + 31'd3);
                        exp_pc4_q.push_back(1'b0);
                     end
                     default: begin
                        ifu_fetch_data_f2 = {RVI_SUB2[15:0], RVI_ADD1, C_NOP};
                        exp_instr_q.push_back(EXP_C_NOP);
                        exp_pc_q.push_back(fetch_addr_f2);
                        exp_pc4_q.push_back(1'b0);
                        exp_instr_q.push_back(RVI_ADD1);
                        exp_pc_q.push_back(fetch_addr_f2 + 31'd1);
                        exp_pc4_q.push_back(1'b1);
                        pending_split = 1'b1;
                        pending_lo    = RVI_SUB2[15:0];
                        pending_pc    = fetch_addr_f2 + 31'd3;
                     end
                  endcase
               end
               fb_occ += 1;
            end else begin
               ic_hit_f2       = 1'b0;
               ic_fetch_val_f2 = 4'b0000;
            end

            @(posedge clk);
         end
      end

      $display("PASS eh2_ifu_ib_top seed=%0d", SEED);
      $finish;
   end
endmodule
