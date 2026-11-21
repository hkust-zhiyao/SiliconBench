`timescale 1ns/1ps
module tb #(
   parameter int SEED = 101
);
   import el2_pkg::*;
`include "el2_param.vh";

   logic                                   clk = 1'b0;
   logic                                   rst_l = 1'b0;
   logic                                   scan_mode = 1'b0;

   logic                                   ic_hit_f;
   logic                                   ifu_ic_mb_empty;
   logic                                   dec_tlu_flush_noredir_wb;
   logic                                   exu_flush_final;
   logic [31:1]                            exu_flush_path_final;
   logic                                   ifu_bp_hit_taken_f;
   logic [31:1]                            ifu_bp_btb_target_f;
   logic                                   ic_dma_active;
   logic                                   ic_write_stall;
   logic                                   dma_iccm_stall_any;
   logic [31:0]                            dec_tlu_mrac_ff;

   logic                                   ifu_async_error_start;
   logic [1:0]                             iccm_rd_ecc_double_err;
   logic [1:0]                             ic_access_fault_f;
   logic [1:0]                             ic_access_fault_type_f;
   logic                                   dec_i0_decode_d;
   logic [31:0]                            ifu_fetch_data_f;
   logic [1:0]                             ic_fetch_val_f;

   logic [pt.BHT_GHR_SIZE-1:0]             ifu_bp_fghr_f;
   logic [11:0]                            ifu_bp_poffset_f;
   logic [1:0][$clog2(pt.BTB_SIZE)-1:0]    ifu_bp_fa_index_f;
   logic [1:0]                             ifu_bp_hist0_f;
   logic [1:0]                             ifu_bp_hist1_f;
   logic [1:0]                             ifu_bp_pc4_f;
   logic [1:0]                             ifu_bp_way_f;
   logic [1:0]                             ifu_bp_valid_f;
   logic [1:0]                             ifu_bp_ret_f;

   logic                                   dbg_cmd_valid;
   logic                                   dbg_cmd_write;
   logic [1:0]                             dbg_cmd_type;
   logic [31:0]                            dbg_cmd_addr;

   logic [31:1]                            ifc_fetch_addr_f;
   logic [31:1]                            ifc_fetch_addr_bf;
   logic                                   ifc_fetch_req_f;
   logic                                   ifu_pmu_fetch_stall;
   logic                                   ifc_fetch_uncacheable_bf;
   logic                                   ifc_fetch_req_bf;
   logic                                   ifc_fetch_req_bf_raw;
   logic                                   ifc_iccm_access_bf;
   logic                                   ifc_region_acc_fault_bf;
   logic                                   ifc_dma_access_ok;

   logic                                   ifu_fb_consume1;
   logic                                   ifu_fb_consume2;
   logic                                   ifu_i0_valid;
   logic                                   ifu_pmu_instr_aligned;
   logic [15:0]                            ifu_i0_cinst;

   logic                                   dec_ib0_valid_d;
   logic                                   dec_debug_valid_d;
   logic [31:0]                            dec_i0_instr_d;
   logic [31:1]                            dec_i0_pc_d;
   logic                                   dec_i0_pc4_d;
   el2_br_pkt_t                            dec_i0_brp;
   logic [pt.BTB_ADDR_HI:pt.BTB_ADDR_LO]   dec_i0_bp_index;
   logic [pt.BHT_GHR_SIZE-1:0]             dec_i0_bp_fghr;
   logic [pt.BTB_BTAG_SIZE-1:0]            dec_i0_bp_btag;
   logic [$clog2(pt.BTB_SIZE)-1:0]         dec_i0_bp_fa_index;
   logic                                   dec_i0_icaf_d;
   logic                                   dec_i0_icaf_second_d;
   logic [1:0]                             dec_i0_icaf_type_d;
   logic                                   dec_i0_dbecc_d;
   logic                                   dec_debug_wdata_rs1_d;
   logic                                   dec_debug_fence_d;

   always #5 clk = ~clk;

   el2_ifu_ib_top dut (.*);

   task automatic clear_inputs();
      ic_hit_f                 = 1'b0;
      ifu_ic_mb_empty          = 1'b1;
      dec_tlu_flush_noredir_wb = 1'b0;
      exu_flush_final          = 1'b0;
      exu_flush_path_final     = 31'h0;
      ifu_bp_hit_taken_f       = 1'b0;
      ifu_bp_btb_target_f      = 31'h0;
      ic_dma_active            = 1'b0;
      ic_write_stall           = 1'b0;
      dma_iccm_stall_any       = 1'b0;
      dec_tlu_mrac_ff          = 32'h5555_5555;
      ifu_async_error_start    = 1'b0;
      iccm_rd_ecc_double_err   = 2'b00;
      ic_access_fault_f        = 2'b00;
      ic_access_fault_type_f   = 2'b00;
      dec_i0_decode_d          = 1'b0;
      ifu_fetch_data_f         = 32'h0000_0013;
      ic_fetch_val_f           = 2'b00;
      ifu_bp_fghr_f            = '0;
      ifu_bp_poffset_f         = '0;
      ifu_bp_fa_index_f        = '0;
      ifu_bp_hist0_f           = '0;
      ifu_bp_hist1_f           = '0;
      ifu_bp_pc4_f             = '0;
      ifu_bp_way_f             = '0;
      ifu_bp_valid_f           = '0;
      ifu_bp_ret_f             = '0;
      dbg_cmd_valid            = 1'b0;
      dbg_cmd_write            = 1'b0;
      dbg_cmd_type             = 2'b00;
      dbg_cmd_addr             = 32'h0;
   endtask

   task automatic do_flush(input logic [31:1] target_pc);
      @(negedge clk);
      if (!ifc_fetch_req_bf_raw) begin
         // Leaving IDLE state first
         exu_flush_final          = 1'b1;
         exu_flush_path_final     = target_pc;
         dec_tlu_flush_noredir_wb = 1'b0;
         ic_hit_f                 = 1'b0;
         ic_fetch_val_f           = 2'b00;
         dec_i0_decode_d          = 1'b0;
         @(posedge clk);
         @(negedge clk);
      end
      exu_flush_final          = 1'b1;
      exu_flush_path_final     = target_pc;
      dec_tlu_flush_noredir_wb = 1'b0;
      ic_hit_f                 = 1'b0;
      ic_fetch_val_f           = 2'b00;
      dec_i0_decode_d          = 1'b0;
      #1;
      if (ifc_fetch_addr_bf !== target_pc || ifc_fetch_req_bf !== 1'b1) begin
         $display("FAIL: flush redirect addr_bf=%h req_bf=%b expected %h", ifc_fetch_addr_bf, ifc_fetch_req_bf, target_pc);
         $fatal(1);
      end
      @(posedge clk);
      @(negedge clk);
      exu_flush_final = 1'b0;
   endtask

   // RVC c.addi x1, 1 => 16'h0085 -> expands to addi x1, x1, 1 (32'h00108093)
   // RVC c.nop        => 16'h0001 -> expands to addi x0, x0, 0 (32'h00000013)
   localparam logic [15:0] C_NOP     = 16'h0001;
   localparam logic [31:0] EXP_C_NOP = 32'h0000_0013;
   localparam logic [15:0] C_ADDI_X1 = 16'h0085;
   localparam logic [31:0] EXP_ADDI1 = 32'h0010_8093;
   localparam logic [31:0] RVI_ADD1  = 32'h0020_81b3; // add x3, x1, x2
   localparam logic [31:0] RVI_SUB2  = 32'h4041_8233; // sub x4, x3, x4

   initial begin
      clear_inputs();
      rst_l = 1'b0;
      repeat (3) @(posedge clk);
      @(negedge clk);
      rst_l = 1'b1;
      @(posedge clk);

      // ------------------------------------------------------------------
      // Phase 1: Flush startup, 3-buffer mass balance, BTB target redirect, DMA stall
      // ------------------------------------------------------------------
      do_flush(31'h0000_0100);
      // Now in FETCH state: ifc_fetch_req_f == 1, ifc_fetch_addr_f == 31'h0000_0100
      #1;
      if (ifc_fetch_req_f !== 1'b1 || ifc_fetch_addr_f !== 31'h0000_0100) begin
         $display("FAIL: post-flush fetch_req_f=%b addr_f=%h", ifc_fetch_req_f, ifc_fetch_addr_f);
         $fatal(1);
      end

      // Test BTB taken branch target selection while hitting fetch 0
      ic_hit_f            = 1'b1;
      ic_fetch_val_f      = 2'b11;
      ifu_fetch_data_f    = {C_ADDI_X1, C_NOP}; // lower=C_NOP, upper=C_ADDI_X1
      ifu_bp_hit_taken_f  = 1'b1;
      ifu_bp_btb_target_f = 31'h0000_0200;
      #1;
      if (ifc_fetch_addr_bf !== 31'h0000_0200 || ifc_fetch_req_bf !== 1'b1) begin
         $display("FAIL: BTB target redirect addr_bf=%h req_bf=%b", ifc_fetch_addr_bf, ifc_fetch_req_bf);
         $fatal(1);
      end
      @(posedge clk);

      // Cycle 2: buffer 0 filled (f0val=2'b11), fetch 1 at 31'h0000_0200
      @(negedge clk);
      ifu_bp_hit_taken_f = 1'b0;
      ic_hit_f           = 1'b1;
      ic_fetch_val_f     = 2'b11;
      ifu_fetch_data_f   = RVI_ADD1;
      #1;
      if (ifc_fetch_addr_f !== 31'h0000_0200 || ifc_fetch_req_bf !== 1'b1) begin
         $display("FAIL: fetch 1 addr_f=%h req_bf=%b", ifc_fetch_addr_f, ifc_fetch_req_bf);
         $fatal(1);
      end
      // Check DMA stall blocks ifc_fetch_req_bf
      ic_dma_active = 1'b1;
      #1;
      if (ifc_fetch_req_bf !== 1'b0) begin
         $display("FAIL: ic_dma_active did not gate ifc_fetch_req_bf");
         $fatal(1);
      end
      ic_dma_active = 1'b0;
      #1;
      if (ifc_fetch_req_bf !== 1'b1) begin
         $display("FAIL: ifc_fetch_req_bf did not recover when ic_dma_active cleared");
         $fatal(1);
      end
      @(posedge clk);

      // Cycle 3: buffers 0 and 1 filled; fetch 2 hits and fills buffer 2 -> fb_full_f_ns = 1
      @(negedge clk);
      ic_hit_f         = 1'b1;
      ic_fetch_val_f   = 2'b11;
      ifu_fetch_data_f = RVI_SUB2;
      dec_i0_decode_d  = 1'b0; // stalled decode!
      #1;
      // With 2 buffers full and 3rd hitting now and 0 consumed, fb_full_f_ns == 1 -> ifc_fetch_req_bf must be 0!
      if (ifc_fetch_req_bf !== 1'b0) begin
         $display("FAIL: expected ifc_fetch_req_bf=0 when 3rd buffer fills with 0 consumed");
         $fatal(1);
      end

      // ------------------------------------------------------------------
      // Phase 2: Multi-cycle stall lock, compressed instruction expansion, and upper-halfword PC+2
      // ------------------------------------------------------------------
      // While dec_i0_decode_d == 0, output must hold C_NOP expanded (EXP_C_NOP) at PC 31'h0000_0100, pc4=0
      if (dec_ib0_valid_d !== 1'b1 || dec_i0_instr_d !== EXP_C_NOP || dec_i0_pc_d !== 31'h0000_0100 || dec_i0_pc4_d !== 1'b0) begin
         $display("FAIL: initial aligned C_NOP mismatch valid=%b instr=%h pc=%h pc4=%b", dec_ib0_valid_d, dec_i0_instr_d, dec_i0_pc_d, dec_i0_pc4_d);
         $fatal(1);
      end
      @(posedge clk);

      // Stay stalled for 2 more cycles: output must remain locked
      @(negedge clk);
      ic_hit_f       = 1'b0;
      ic_fetch_val_f = 2'b00;
      repeat (2) begin
         #1;
         if (dec_ib0_valid_d !== 1'b1 || dec_i0_instr_d !== EXP_C_NOP || dec_i0_pc_d !== 31'h0000_0100 || dec_i0_pc4_d !== 1'b0) begin
            $display("FAIL: stall lock broken on C_NOP");
            $fatal(1);
         end
         @(posedge clk);
         @(negedge clk);
      end

      // Consume C_NOP (2B): advances to upper halfword of buffer 0 (C_ADDI_X1 at PC 31'h0000_0101)
      dec_i0_decode_d = 1'b1;
      #1;
      if (ifu_fb_consume1 !== 1'b0 || ifu_fb_consume2 !== 1'b0 || ifu_pmu_instr_aligned !== 1'b1) begin
         $display("FAIL: consuming lower 2B of 4B buffer should not consume buffer");
         $fatal(1);
      end
      @(posedge clk);

      @(negedge clk);
      dec_i0_decode_d = 1'b1;
      #1;
      if (dec_ib0_valid_d !== 1'b1 || dec_i0_instr_d !== EXP_ADDI1 || dec_i0_pc_d !== 31'h0000_0101 || dec_i0_pc4_d !== 1'b0 || ifu_fb_consume1 !== 1'b1) begin
         $display("FAIL: upper halfword C_ADDI_X1 mismatch valid=%b instr=%h pc=%h pc4=%b consume1=%b",
                  dec_ib0_valid_d, dec_i0_instr_d, dec_i0_pc_d, dec_i0_pc4_d, ifu_fb_consume1);
         $fatal(1);
      end
      // Also because buffer 0 is being consumed (ifu_fb_consume1 == 1), ifc_fetch_req_bf must assert even though fb_full_f was 1!
      if (ifc_fetch_req_bf !== 1'b1) begin
         $display("FAIL: ifc_fetch_req_bf should assert when fb_full_f=1 and ifu_fb_consume1=1");
         $fatal(1);
      end
      @(posedge clk);

      // Now buffer 1 (RVI_ADD1 at 31'h0000_0200) is at f0, buffer 2 (RVI_SUB2) is at f1
      @(negedge clk);
      #1;
      if (dec_ib0_valid_d !== 1'b1 || dec_i0_instr_d !== RVI_ADD1 || dec_i0_pc_d !== 31'h0000_0200 || dec_i0_pc4_d !== 1'b1 || ifu_fb_consume1 !== 1'b1) begin
         $display("FAIL: RVI_ADD1 mismatch valid=%b instr=%h pc=%h pc4=%b", dec_ib0_valid_d, dec_i0_instr_d, dec_i0_pc_d, dec_i0_pc4_d);
         $fatal(1);
      end
      @(posedge clk);

      // ------------------------------------------------------------------
      // Phase 3: Split 32-bit instruction spanning f0 upper 2B and f1 lower 2B
      // Case A: f1 has 2 valid halfwords (f1val=2'b11) -> f1_shift_2B must shift f1 by 2B
      // ------------------------------------------------------------------
      do_flush(31'h0000_0300);
      // Fetch 0: lower=C_NOP (2B), upper=RVI_ADD1[15:0] (lower half of split 4B inst)
      @(negedge clk);
      ic_hit_f         = 1'b1;
      ic_fetch_val_f   = 2'b11;
      ifu_fetch_data_f = {RVI_ADD1[15:0], C_NOP};
      dec_i0_decode_d  = 1'b0;
      @(posedge clk);

      // Fetch 1: lower=RVI_ADD1[31:16] (upper half of split 4B inst), upper=C_ADDI_X1 (2B)
      @(negedge clk);
      ic_hit_f         = 1'b1;
      ic_fetch_val_f   = 2'b11;
      ifu_fetch_data_f = {C_ADDI_X1, RVI_ADD1[31:16]};
      dec_i0_decode_d  = 1'b1; // consume C_NOP at 31'h0000_0300
      @(posedge clk);

      // Now f0 has 1 halfword left (RVI_ADD1[15:0] at 31'h0000_0301) and f1 has {C_ADDI_X1, RVI_ADD1[31:16]} (f1val=2'b11)
      @(negedge clk);
      ic_hit_f        = 1'b0;
      ic_fetch_val_f  = 2'b00;
      dec_i0_decode_d = 1'b1;
      #1;
      if (dec_ib0_valid_d !== 1'b1 || dec_i0_instr_d !== RVI_ADD1 || dec_i0_pc_d !== 31'h0000_0301 || dec_i0_pc4_d !== 1'b1 ||
          ifu_fb_consume1 !== 1'b1 || ifu_fb_consume2 !== 1'b0) begin
         $display("FAIL: split 4B (f1val=11) mismatch valid=%b instr=%h pc=%h pc4=%b c1=%b c2=%b",
                  dec_ib0_valid_d, dec_i0_instr_d, dec_i0_pc_d, dec_i0_pc4_d, ifu_fb_consume1, ifu_fb_consume2);
         $fatal(1);
      end
      @(posedge clk);

      // Next cycle must present C_ADDI_X1 from upper halfword of old f1 at PC 31'h0000_0303!
      @(negedge clk);
      dec_i0_decode_d = 1'b1;
      #1;
      if (dec_ib0_valid_d !== 1'b1 || dec_i0_instr_d !== EXP_ADDI1 || dec_i0_pc_d !== 31'h0000_0303 || dec_i0_pc4_d !== 1'b0) begin
         $display("FAIL: post-split f1_shift_2B upper halfword mismatch valid=%b instr=%h pc=%h expected %h at 303",
                  dec_ib0_valid_d, dec_i0_instr_d, dec_i0_pc_d, EXP_ADDI1);
         $fatal(1);
      end
      @(posedge clk);

      // ------------------------------------------------------------------
      // Phase 4: Split 32-bit instruction with f1val=2'b01 (ifu_fb_consume2=1)
      // simultaneous with new fetch hit + second-halfword fault/ECC attribution
      // ------------------------------------------------------------------
      do_flush(31'h0000_0400);
      // Fetch 0: 1 valid halfword (ic_fetch_val_f=2'b01) containing RVI_SUB2[15:0], no fault, ictype=2'b01
      @(negedge clk);
      ic_hit_f               = 1'b1;
      ic_fetch_val_f         = 2'b01;
      ifu_fetch_data_f       = {16'h0000, RVI_SUB2[15:0]};
      ic_access_fault_f      = 2'b00;
      ic_access_fault_type_f = 2'b01;
      dec_i0_decode_d        = 1'b0;
      @(posedge clk);

      // Fetch 1: 1 valid halfword (ic_fetch_val_f=2'b01) containing RVI_SUB2[31:16], access fault on halfword 0, ictype=2'b10
      @(negedge clk);
      ic_hit_f               = 1'b1;
      ic_fetch_val_f         = 2'b01;
      ifu_fetch_data_f       = {16'h0000, RVI_SUB2[31:16]};
      ic_access_fault_f      = 2'b01;
      ic_access_fault_type_f = 2'b10;
      dec_i0_decode_d        = 1'b0;
      @(posedge clk);

      // Now f0val=2'b01, f1val=2'b01; also let Fetch 2 hit on the same cycle we consume both f0 and f1!
      @(negedge clk);
      ic_hit_f               = 1'b1;
      ic_fetch_val_f         = 2'b11;
      ifu_fetch_data_f       = RVI_ADD1;
      ic_access_fault_f      = 2'b00;
      ic_access_fault_type_f = 2'b00;
      dec_i0_decode_d        = 1'b1;
      #1;
      if (dec_ib0_valid_d !== 1'b1 || dec_i0_instr_d !== RVI_SUB2 ||
          dec_i0_icaf_d !== 1'b1 || dec_i0_icaf_second_d !== 1'b1 || dec_i0_icaf_type_d !== 2'b10 ||
          ifu_fb_consume2 !== 1'b1 || ifu_fb_consume1 !== 1'b0) begin
         $display("FAIL: split 4B consume2 / second-half icaf mismatch valid=%b instr=%h icaf=%b icaf2=%b type=%b c1=%b c2=%b",
                  dec_ib0_valid_d, dec_i0_instr_d, dec_i0_icaf_d, dec_i0_icaf_second_d, dec_i0_icaf_type_d, ifu_fb_consume1, ifu_fb_consume2);
         $fatal(1);
      end
      // Verify ifc_fetch_req_bf is 1 (since 2 buffers are consumed while 1 hits, net occupancy drops from 2 to 1)
      if (ifc_fetch_req_bf !== 1'b1) begin
         $display("FAIL: ifc_fetch_req_bf should be 1 during consume2 + hit");
         $fatal(1);
      end
      @(posedge clk);

      // Verify mass-balance after consume2 + hit: only 1 buffer (f0) is now occupied, so 2 more fetches can hit before full!
      @(negedge clk);
      dec_i0_decode_d  = 1'b0;
      ic_hit_f         = 1'b1;
      ic_fetch_val_f   = 2'b11;
      ifu_fetch_data_f = RVI_SUB2;
      #1;
      // 1 buffer occupied + 1 hitting now = 2 buffers occupied next cycle -> not full yet!
      if (ifc_fetch_req_bf !== 1'b1) begin
         $display("FAIL: mass balance corrupted after consume2 + hit (ifc_fetch_req_bf=%b)", ifc_fetch_req_bf);
         $fatal(1);
      end
      @(posedge clk);

      // Test second-halfword double-bit ECC error on a 4B instruction in f0
      do_flush(31'h0000_0500);
      @(negedge clk);
      ic_hit_f               = 1'b1;
      ic_fetch_val_f         = 2'b11;
      ifu_fetch_data_f       = RVI_ADD1;
      iccm_rd_ecc_double_err = 2'b10; // double-bit ECC error on upper halfword only
      dec_i0_decode_d        = 1'b0;
      @(posedge clk);
      @(negedge clk);
      ic_hit_f               = 1'b0;
      ic_fetch_val_f         = 2'b00;
      iccm_rd_ecc_double_err = 2'b00;
      #1;
      if (dec_ib0_valid_d !== 1'b1 || dec_i0_dbecc_d !== 1'b1 || dec_i0_icaf_second_d !== 1'b1) begin
         $display("FAIL: second-halfword dbecc mismatch dbecc=%b icaf2=%b", dec_i0_dbecc_d, dec_i0_icaf_second_d);
         $fatal(1);
      end
      @(posedge clk);

      // ------------------------------------------------------------------
      // Phase 5: Asynchronous error stall lock and flush recovery
      // ------------------------------------------------------------------
      do_flush(31'h0000_0600);
      @(negedge clk);
      ic_hit_f              = 1'b1;
      ic_fetch_val_f        = 2'b11;
      ifu_fetch_data_f      = {C_ADDI_X1, C_NOP};
      ifu_async_error_start = 1'b1;
      dec_i0_decode_d       = 1'b0;
      @(posedge clk);

      @(negedge clk);
      ic_hit_f              = 1'b0;
      ic_fetch_val_f        = 2'b00;
      ifu_async_error_start = 1'b0;
      dec_i0_decode_d       = 1'b1; // try to shift while error_stall is latched
      #1;
      if (ifu_pmu_instr_aligned !== 1'b0 || dec_i0_instr_d !== EXP_C_NOP) begin
         $display("FAIL: error_stall did not block alignment shift");
         $fatal(1);
      end
      @(posedge clk);
      @(negedge clk);
      #1;
      if (dec_i0_instr_d !== EXP_C_NOP) begin
         $display("FAIL: queue shifted despite error_stall");
         $fatal(1);
      end

      // Flush must clear error_stall so subsequent instructions align and shift normally
      do_flush(31'h0000_0680);
      @(negedge clk);
      ic_hit_f         = 1'b1;
      ic_fetch_val_f   = 2'b11;
      ifu_fetch_data_f = {C_ADDI_X1, C_NOP};
      dec_i0_decode_d  = 1'b0;
      @(posedge clk);
      @(negedge clk);
      ic_hit_f        = 1'b0;
      ic_fetch_val_f  = 2'b00;
      dec_i0_decode_d = 1'b1;
      #1;
      if (ifu_pmu_instr_aligned !== 1'b1) begin
         $display("FAIL: error_stall was not cleared by exu_flush_final");
         $fatal(1);
      end
      @(posedge clk);

      // ------------------------------------------------------------------
      // Phase 6: Halted debug command injection in el2_dec_ib_ctl
      // ------------------------------------------------------------------
      @(negedge clk);
      dec_i0_decode_d = 1'b0;
      // 1) GPR read x5
      dbg_cmd_valid = 1'b1;
      dbg_cmd_write = 1'b0;
      dbg_cmd_type  = 2'h0;
      dbg_cmd_addr  = 32'd5;
      #1;
      if (dec_debug_valid_d !== 1'b1 || dec_ib0_valid_d !== 1'b1 || dec_debug_wdata_rs1_d !== 1'b0 ||
          dec_debug_fence_d !== 1'b0 || dec_i0_instr_d !== {12'b0, 5'd5, 15'b110000000110011}) begin
         $display("FAIL: debug GPR read mismatch instr=%h", dec_i0_instr_d);
         $fatal(1);
      end
      // 2) GPR write x9
      dbg_cmd_write = 1'b1;
      dbg_cmd_type  = 2'h0;
      dbg_cmd_addr  = 32'd9;
      #1;
      if (dec_debug_valid_d !== 1'b1 || dec_debug_wdata_rs1_d !== 1'b1 ||
          dec_debug_fence_d !== 1'b0 || dec_i0_instr_d !== {20'b00000000000000000110, 5'd9, 7'b0110011}) begin
         $display("FAIL: debug GPR write mismatch instr=%h", dec_i0_instr_d);
         $fatal(1);
      end
      // 3) CSR read 0x300
      dbg_cmd_write = 1'b0;
      dbg_cmd_type  = 2'h1;
      dbg_cmd_addr  = 32'h300;
      #1;
      if (dec_debug_valid_d !== 1'b1 || dec_debug_wdata_rs1_d !== 1'b0 ||
          dec_debug_fence_d !== 1'b0 || dec_i0_instr_d !== {12'h300, 20'b00000010000001110011}) begin
         $display("FAIL: debug CSR read mismatch instr=%h", dec_i0_instr_d);
         $fatal(1);
      end
      // 4) CSR write 0x7c0 (not fence)
      dbg_cmd_write = 1'b1;
      dbg_cmd_type  = 2'h1;
      dbg_cmd_addr  = 32'h7c0;
      #1;
      if (dec_debug_valid_d !== 1'b1 || dec_debug_wdata_rs1_d !== 1'b1 ||
          dec_debug_fence_d !== 1'b0 || dec_i0_instr_d !== {12'h7c0, 20'b00000001000001110011}) begin
         $display("FAIL: debug CSR write 0x7c0 mismatch instr=%h fence=%b", dec_i0_instr_d, dec_debug_fence_d);
         $fatal(1);
      end
      // 5) CSR write 0x7c4 (debug fence)
      dbg_cmd_addr  = 32'h7c4;
      #1;
      if (dec_debug_valid_d !== 1'b1 || dec_debug_wdata_rs1_d !== 1'b1 ||
          dec_debug_fence_d !== 1'b1 || dec_i0_instr_d !== {12'h7c4, 20'b00000001000001110011}) begin
         $display("FAIL: debug CSR fence 0x7c4 mismatch instr=%h fence=%b", dec_i0_instr_d, dec_debug_fence_d);
         $fatal(1);
      end
      // 6) Abstract memory command (dbg_cmd_type == 2'h2) must be ignored
      dbg_cmd_type  = 2'h2;
      #1;
      if (dec_debug_valid_d !== 1'b0 || dec_debug_wdata_rs1_d !== 1'b0 || dec_debug_fence_d !== 1'b0) begin
         $display("FAIL: dbg_cmd_type=2 should be ignored");
         $fatal(1);
      end
      dbg_cmd_valid = 1'b0;

      // ------------------------------------------------------------------
      // Phase 7: Seeded randomized instruction stream verification
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

         for (int cyc = 0; cyc < 120; cyc++) begin
            @(negedge clk);
            rng = (rng * 32'd1664525) + 32'd1013904223;
            dec_i0_decode_d = 1'b0;
            #1;
            dec_i0_decode_d = dec_ib0_valid_d & rng[0];
            #1;
            if (dec_ib0_valid_d) begin
               if (exp_instr_q.size() == 0) begin
                  $display("FAIL: unexpected dec_ib0_valid_d at cyc=%0d", cyc);
                  $fatal(1);
               end
               if (dec_i0_instr_d !== exp_instr_q[0] || dec_i0_pc_d !== exp_pc_q[0] || dec_i0_pc4_d !== exp_pc4_q[0]) begin
                  $display("FAIL: stream mismatch at cyc=%0d got instr=%h pc=%h pc4=%b exp instr=%h pc=%h pc4=%b",
                           cyc, dec_i0_instr_d, dec_i0_pc_d, dec_i0_pc4_d, exp_instr_q[0], exp_pc_q[0], exp_pc4_q[0]);
                  $fatal(1);
               end
               if (dec_i0_decode_d) begin
                  void'(exp_instr_q.pop_front());
                  void'(exp_pc_q.pop_front());
                  void'(exp_pc4_q.pop_front());
               end
            end

            // Update buffer occupancy from consume signals
            if (ifu_fb_consume1) fb_occ -= 1;
            if (ifu_fb_consume2) fb_occ -= 2;

            // Offer a new 32-bit fetch word if fewer than 3 buffers are occupied and rng[1] is set
            if (fb_occ < 3 && ifc_fetch_req_f && rng[1]) begin
               ic_hit_f       = 1'b1;
               ic_fetch_val_f = 2'b11;
               if (pending_split) begin
                  // Complete pending split 32-bit instruction in lower halfword, put C_NOP or C_ADDI_X1 in upper halfword
                  logic [15:0] hi_part;
                  hi_part = rng[2] ? 16'h0101 : 16'h4041;
                  ifu_fetch_data_f = { (rng[3] ? C_ADDI_X1 : C_NOP), hi_part };
                  exp_instr_q.push_back({hi_part, pending_lo});
                  exp_pc_q.push_back(pending_pc);
                  exp_pc4_q.push_back(1'b1);
                  exp_instr_q.push_back(rng[3] ? EXP_ADDI1 : EXP_C_NOP);
                  exp_pc_q.push_back(ifc_fetch_addr_f + 31'd1);
                  exp_pc4_q.push_back(1'b0);
                  pending_split = 1'b0;
               end else begin
                  case (rng[5:4])
                     2'b00: begin
                        // One 32-bit instruction
                        ifu_fetch_data_f = RVI_ADD1;
                        exp_instr_q.push_back(RVI_ADD1);
                        exp_pc_q.push_back(ifc_fetch_addr_f);
                        exp_pc4_q.push_back(1'b1);
                     end
                     2'b01: begin
                        // Two 16-bit compressed instructions
                        ifu_fetch_data_f = {C_ADDI_X1, C_NOP};
                        exp_instr_q.push_back(EXP_C_NOP);
                        exp_pc_q.push_back(ifc_fetch_addr_f);
                        exp_pc4_q.push_back(1'b0);
                        exp_instr_q.push_back(EXP_ADDI1);
                        exp_pc_q.push_back(ifc_fetch_addr_f + 31'd1);
                        exp_pc4_q.push_back(1'b0);
                     end
                     default: begin
                        // Lower 16-bit compressed + upper 16-bit start of split 32-bit instruction
                        ifu_fetch_data_f = {RVI_SUB2[15:0], C_NOP};
                        exp_instr_q.push_back(EXP_C_NOP);
                        exp_pc_q.push_back(ifc_fetch_addr_f);
                        exp_pc4_q.push_back(1'b0);
                        pending_split = 1'b1;
                        pending_lo    = RVI_SUB2[15:0];
                        pending_pc    = ifc_fetch_addr_f + 31'd1;
                     end
                  endcase
               end
               fb_occ += 1;
            end else begin
               ic_hit_f       = 1'b0;
               ic_fetch_val_f = 2'b00;
            end

            @(posedge clk);
         end
      end

      $display("PASS el2_ifu_ib_top seed=%0d", SEED);
      $finish;
   end
endmodule
