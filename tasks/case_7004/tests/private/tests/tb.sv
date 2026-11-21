`timescale 1ns/1ps
module tb #(parameter int SEED = 101);
   import eh2_pkg::*;
`include "eh2_param.vh";

   logic                           clk = 1'b0, clk_override = 1'b0, rst_l = 1'b0, scan_mode = 1'b0;
   eh2_lsu_pkt_t                   lsu_pkt_dc1_pre, lsu_pkt_dc1, lsu_pkt_dc2, lsu_pkt_dc3, lsu_pkt_dc4, lsu_pkt_dc5;
   logic                           core_ldst_dual_dc1, ldst_dual_dc2, ldst_dual_dc3, ldst_dual_dc4, ldst_dual_dc5;
   logic                           addr_in_dccm_region_dc1, addr_in_dccm_dc1, addr_in_dccm_dc2, addr_in_dccm_dc3, addr_in_dccm_dc4, addr_in_dccm_dc5;
   logic                           addr_in_pic_dc1, addr_in_pic_dc2, addr_in_pic_dc3, addr_in_pic_dc5;
   logic                           lsu_cmpen_dc2, store_stbuf_reqvld_dc5, lsu_commit_dc5, lsu_sc_success_dc5;
   logic                           lsu_raw_fwd_lo_dc5, lsu_raw_fwd_hi_dc5, lsu_double_ecc_error_dc5;
   logic                           single_ecc_error_hi_dc4, single_ecc_error_lo_dc4, single_ecc_error_hi_dc5, single_ecc_error_lo_dc5;
   logic                           dec_tlu_core_ecc_disable, misaligned_fault_dc3, access_fault_dc3;
   logic                           dma_pic_wen, dma_dccm_wen, dma_dccm_spec_wen, dma_dccm_spec_req, dma_mem_write;
   logic [2:0]                     dma_mem_sz, dma_mem_tag_dc3;
   logic [pt.XLEN-1:0]             dma_mem_addr, dma_dccm_wdata_lo, dma_dccm_wdata_hi;
   logic [(pt.XLEN*2)-1:0]         dma_mem_wdata;
   logic [pt.XLEN-1:0]             lsu_addr_dc1, lsu_addr_dc2, lsu_addr_dc3, lsu_addr_dc4, lsu_addr_dc5;
   logic [pt.XLEN-1:0]             end_addr_dc1, end_addr_dc2, end_addr_dc3, end_addr_dc4, end_addr_dc5;
   logic [pt.XLEN-1:0]             store_data_dc3, picm_rd_data;
   logic [pt.DCCM_FDATA_WIDTH-1:0] dccm_rd_data_lo, dccm_rd_data_hi;

   logic [pt.DCCM_FDATA_WIDTH-1:0] dccm_wr_data_hi, dccm_wr_data_lo;
   logic [pt.DCCM_DATA_WIDTH-1:0]  dccm_datafn_hi_dc5, dccm_datafn_lo_dc5;
   logic                           stbuf_reqvld_any, stbuf_reqvld_flushed_any, lsu_stbuf_commit_any;
   logic [pt.LSU_SB_BITS-1:0]      stbuf_addr_any;
   logic [pt.DCCM_DATA_WIDTH-1:0]  stbuf_data_any;
   logic [pt.NUM_THREADS-1:0]      lsu_stbuf_empty_any, lsu_stbuf_full_any;
   logic                           single_ecc_error_hi_dc3, single_ecc_error_lo_dc3, lsu_single_ecc_error_dc3, lsu_double_ecc_error_dc3;
   logic                           ld_single_ecc_error_dc3, ld_single_ecc_error_dc5, ld_single_ecc_error_dc5_ff, ld_single_ecc_error_lo_dc5_ff, ld_single_ecc_error_hi_dc5_ff;
   logic [pt.DCCM_DATA_WIDTH-1:0]  lsu_dccm_data_dc3, lsu_dccm_data_corr_dc3;
   logic [pt.XLEN-1:0]             amo_data_dc3, picm_mask_data_dc3, picm_rd_data_dc3;
   logic                           lsu_dccm_rden_dc3, dccm_dma_rvalid, dccm_dma_ecc_error;
   logic [2:0]                     dccm_dma_rtag;
   logic [(pt.XLEN*2)-1:0]         dccm_dma_rdata;
   logic                           dccm_wren, dccm_rden, picm_wren_notdma, picm_wren, picm_rden, picm_mken, picm_rd_thr, picm_fwd_en_dc2;
   logic [pt.DCCM_BITS-1:0]        dccm_wr_addr_lo, dccm_wr_addr_hi, dccm_rd_addr_lo, dccm_rd_addr_hi;
   logic [pt.XLEN-1:0]             picm_rdaddr, picm_wraddr, picm_wr_data, picm_fwd_data_dc2;
   logic [pt.DCCM_DATA_WIDTH-1:0]  stbuf_fwddata_hi_dc3, stbuf_fwddata_lo_dc3;
   logic [pt.DCCM_BYTE_WIDTH-1:0]  stbuf_fwdbyteen_hi_dc3, stbuf_fwdbyteen_lo_dc3;

   always #5 clk = ~clk;
   eh2_lsu_subsys_top dut (.*);

   function automatic logic [6:0] calc_ecc(input logic [31:0] d);
      logic [5:0] e;
      e[0] = d[0]^d[1]^d[3]^d[4]^d[6]^d[8]^d[10]^d[11]^d[13]^d[15]^d[17]^d[19]^d[21]^d[23]^d[25]^d[26]^d[28]^d[30];
      e[1] = d[0]^d[2]^d[3]^d[5]^d[6]^d[9]^d[10]^d[12]^d[13]^d[16]^d[17]^d[20]^d[21]^d[24]^d[25]^d[27]^d[28]^d[31];
      e[2] = d[1]^d[2]^d[3]^d[7]^d[8]^d[9]^d[10]^d[14]^d[15]^d[16]^d[17]^d[22]^d[23]^d[24]^d[25]^d[29]^d[30]^d[31];
      e[3] = d[4]^d[5]^d[6]^d[7]^d[8]^d[9]^d[10]^d[18]^d[19]^d[20]^d[21]^d[22]^d[23]^d[24]^d[25];
      e[4] = d[11]^d[12]^d[13]^d[14]^d[15]^d[16]^d[17]^d[18]^d[19]^d[20]^d[21]^d[22]^d[23]^d[24]^d[25];
      e[5] = d[26]^d[27]^d[28]^d[29]^d[30]^d[31];
      return {(^d)^(^e), e};
   endfunction

   task automatic clear_all();
      lsu_pkt_dc1_pre = '0; lsu_pkt_dc1 = '0; lsu_pkt_dc2 = '0; lsu_pkt_dc3 = '0; lsu_pkt_dc4 = '0; lsu_pkt_dc5 = '0;
      core_ldst_dual_dc1 = 0; ldst_dual_dc2 = 0; ldst_dual_dc3 = 0; ldst_dual_dc4 = 0; ldst_dual_dc5 = 0;
      addr_in_dccm_region_dc1 = 0; addr_in_dccm_dc1 = 0; addr_in_dccm_dc2 = 0; addr_in_dccm_dc3 = 0; addr_in_dccm_dc4 = 0; addr_in_dccm_dc5 = 0;
      addr_in_pic_dc1 = 0; addr_in_pic_dc2 = 0; addr_in_pic_dc3 = 0; addr_in_pic_dc5 = 0;
      lsu_cmpen_dc2 = 0; store_stbuf_reqvld_dc5 = 0; lsu_commit_dc5 = 0; lsu_sc_success_dc5 = 0;
      lsu_raw_fwd_lo_dc5 = 0; lsu_raw_fwd_hi_dc5 = 0; lsu_double_ecc_error_dc5 = 0;
      single_ecc_error_hi_dc4 = 0; single_ecc_error_lo_dc4 = 0; single_ecc_error_hi_dc5 = 0; single_ecc_error_lo_dc5 = 0;
      dec_tlu_core_ecc_disable = 0; misaligned_fault_dc3 = 0; access_fault_dc3 = 0;
      dma_pic_wen = 0; dma_dccm_wen = 0; dma_dccm_spec_wen = 0; dma_dccm_spec_req = 0; dma_mem_write = 0;
      dma_mem_sz = 0; dma_mem_tag_dc3 = 0; dma_mem_addr = 0; dma_mem_wdata = 0; dma_dccm_wdata_lo = 0; dma_dccm_wdata_hi = 0;
      lsu_addr_dc1 = 0; lsu_addr_dc2 = 0; lsu_addr_dc3 = 0; lsu_addr_dc4 = 0; lsu_addr_dc5 = 0;
      end_addr_dc1 = 0; end_addr_dc2 = 0; end_addr_dc3 = 0; end_addr_dc4 = 0; end_addr_dc5 = 0;
      store_data_dc3 = 0; picm_rd_data = 0;
      dccm_rd_data_lo = {calc_ecc(32'h0), 32'h0}; dccm_rd_data_hi = {calc_ecc(32'h0), 32'h0};
   endtask

   initial begin
      clear_all();
      rst_l = 1'b0;
      repeat (3) @(posedge clk);
      @(negedge clk); rst_l = 1'b1;

      // 1. Signed AMOMIN.W / AMOMAX.W (same-sign negative & positive) + SC.W amo_data_dc3
      dccm_rd_data_lo = {calc_ecc(32'h8000_0005), 32'h8000_0005};
      lsu_pkt_dc1_pre.valid = 1; lsu_pkt_dc1_pre.load = 1; addr_in_dccm_region_dc1 = 1;
      @(posedge clk); @(negedge clk);
      lsu_pkt_dc2.valid = 1; addr_in_dccm_dc2 = 1;
      @(posedge clk); @(negedge clk);
      lsu_pkt_dc3.valid = 1; lsu_pkt_dc3.atomic = 1; lsu_pkt_dc3.atomic_instr = 5'd16; // AMOMIN.W
      store_data_dc3 = 32'hFFFF_FFF0; addr_in_dccm_dc3 = 1;
      #1; if (amo_data_dc3 !== 32'h8000_0005) $fatal(1, "AMOMIN.W neg fail: %h", amo_data_dc3);
      lsu_pkt_dc3.atomic_instr = 5'd20; // AMOMAX.W
      #1; if (amo_data_dc3 !== 32'hFFFF_FFF0) $fatal(1, "AMOMAX.W neg fail: %h", amo_data_dc3);
      lsu_pkt_dc3.sc = 1; lsu_pkt_dc3.atomic_instr = 5'd3; store_data_dc3 = 32'hCAFE_BABE;
      #1; if (amo_data_dc3 !== 32'hCAFE_BABE) $fatal(1, "SC.W amo_data_dc3 fail: %h", amo_data_dc3);

      // 2. Odd-offset sub-word store merge + SC.W fail restore in DC5
      clear_all();
      dccm_rd_data_lo = {calc_ecc(32'h1122_3344), 32'h1122_3344};
      lsu_pkt_dc1_pre.valid = 1; lsu_pkt_dc1_pre.load = 1; addr_in_dccm_region_dc1 = 1;
      @(posedge clk); @(negedge clk);
      lsu_pkt_dc2.valid = 1; addr_in_dccm_dc2 = 1;
      @(posedge clk); @(negedge clk);
      lsu_pkt_dc3 = '0; lsu_pkt_dc3.valid = 1; lsu_pkt_dc3.store = 1; lsu_pkt_dc3.by = 1;
      addr_in_dccm_dc3 = 1; lsu_addr_dc3 = 32'h101; end_addr_dc3 = 32'h101; store_data_dc3 = 32'h0000_00AA;
      @(posedge clk); @(negedge clk);
      lsu_pkt_dc4 = lsu_pkt_dc3; addr_in_dccm_dc4 = 1; lsu_addr_dc4 = 32'h101; end_addr_dc4 = 32'h101;
      // Also test SC.W entering DC3 now
      lsu_pkt_dc3 = '0; lsu_pkt_dc3.valid = 1; lsu_pkt_dc3.atomic = 1; lsu_pkt_dc3.sc = 1; lsu_pkt_dc3.store = 1; lsu_pkt_dc3.word = 1;
      lsu_pkt_dc3.atomic_instr = 5'd3; addr_in_dccm_dc3 = 1; lsu_addr_dc3 = 32'h104; end_addr_dc3 = 32'h104; store_data_dc3 = 32'hDEAD_C0DE;
      @(posedge clk); @(negedge clk);
      lsu_pkt_dc5 = lsu_pkt_dc4; addr_in_dccm_dc5 = 1; lsu_addr_dc5 = 32'h101; end_addr_dc5 = 32'h101;
      store_stbuf_reqvld_dc5 = 1; lsu_commit_dc5 = 1;
      #1; if (dccm_datafn_lo_dc5 !== 32'h1122_AA44) $fatal(1, "Odd byte merge fail: %h", dccm_datafn_lo_dc5);
      lsu_pkt_dc4 = lsu_pkt_dc3; addr_in_dccm_dc4 = 1; lsu_addr_dc4 = 32'h104; end_addr_dc4 = 32'h104;
      @(posedge clk); @(negedge clk);
      // Verify stbuf partial word allocation seeded background bytes (mutant_11)
      store_stbuf_reqvld_dc5 = 0; lsu_commit_dc5 = 0;
      lsu_pkt_dc5 = lsu_pkt_dc4; addr_in_dccm_dc5 = 1; lsu_addr_dc5 = 32'h104; end_addr_dc5 = 32'h104; lsu_sc_success_dc5 = 0;
      #1;
      if (stbuf_data_any !== 32'h1122_AA44) $fatal(1, "Stbuf partial alloc background fail: %h", stbuf_data_any);
      if (dccm_datafn_lo_dc5 !== 32'h1122_3344) $fatal(1, "SC.W fail restore mismatch: %h", dccm_datafn_lo_dc5);

      // 3. Coalescing into draining entry blocked (mutant_10) & disable_ecc_check_lo_dc2 on stbuf commit bypass (mutant_09)
      // Right now stbuf entry 0 (addr 0x100) is valid and draining (lsu_stbuf_commit_any=1 because rden_dc1=0).
      // Present a DC2 store to 0x100 and a DC5 store to 0x100 simultaneously!
      lsu_pkt_dc1_pre = '0;
      lsu_pkt_dc2 = '0; lsu_pkt_dc2.valid = 1; lsu_pkt_dc2.store = 1; lsu_pkt_dc2.by = 1; addr_in_dccm_dc2 = 1; lsu_addr_dc2 = 32'h100; end_addr_dc2 = 32'h100;
      lsu_pkt_dc5 = '0; lsu_pkt_dc5.valid = 1; lsu_pkt_dc5.store = 1; lsu_pkt_dc5.word = 1; addr_in_dccm_dc5 = 1; lsu_addr_dc5 = 32'h100; end_addr_dc5 = 32'h100;
      store_stbuf_reqvld_dc5 = 1; lsu_commit_dc5 = 1;
      // Put a single-bit ECC error on dccm_rd_data_lo so if disable_ecc_check_lo_dc3 fails next cycle, single_ecc_error_lo_dc3 will fire!
      dccm_rd_data_lo = {calc_ecc(32'h5566_7788), 32'h5566_7788 ^ 32'h1};
      @(posedge clk); @(negedge clk);
      store_stbuf_reqvld_dc5 = 0; lsu_commit_dc5 = 0; lsu_pkt_dc2 = '0;
      lsu_pkt_dc3 = '0; lsu_pkt_dc3.valid = 1; lsu_pkt_dc3.store = 1; lsu_pkt_dc3.by = 1; addr_in_dccm_dc3 = 1; lsu_addr_dc3 = 32'h100; end_addr_dc3 = 32'h100;
      #1;
      if (stbuf_reqvld_any !== 1'b1) $fatal(1, "Coalesced into draining entry (lost new entry)");
      if (single_ecc_error_lo_dc3 !== 1'b0) $fatal(1, "disable_ecc_check_lo_dc2 failed to mask ECC error");

      // 4. DMA kill in DC2 blocks stbuf_reqvld_any in the same cycle (mutant_12)
      // Hold off drain by asserting lsu_dccm_rden_dc1 to same bank, while DC2 DMA store hits 0x100
      lsu_pkt_dc1_pre.valid = 1; lsu_pkt_dc1_pre.load = 1; addr_in_dccm_region_dc1 = 1; lsu_addr_dc1 = 32'h100; end_addr_dc1 = 32'h100;
      lsu_pkt_dc2 = '0; lsu_pkt_dc2.valid = 1; lsu_pkt_dc2.dma = 1; lsu_pkt_dc2.store = 1; addr_in_dccm_dc2 = 1; lsu_addr_dc2 = 32'h100; end_addr_dc2 = 32'h100;
      #1;
      if (stbuf_reqvld_any !== 1'b0) $fatal(1, "stbuf_reqvld_any not blocked during stbuf_dma_kill_en");
      @(posedge clk); @(negedge clk);
      clear_all(); @(posedge clk); @(negedge clk);

      // 5. Upper-bank ECC error gating (mutant_05), RAW fwd suppression (mutant_07), DMA kill_ecc_corr_lo_dc5 (mutant_06), and hi-bank scrub replication (mutant_04)
      dccm_rd_data_lo = {calc_ecc(32'hA0A0_A0A0), 32'hA0A0_A0A0};
      dccm_rd_data_hi = {calc_ecc(32'hB0B0_B0B0), 32'hB0B0_B0B0 ^ 32'h1}; // 1-bit error on hi bank
      lsu_pkt_dc1_pre.valid = 1; lsu_pkt_dc1_pre.load = 1; addr_in_dccm_region_dc1 = 1;
      @(posedge clk); @(negedge clk);
      lsu_pkt_dc2.valid = 1; lsu_pkt_dc2.load = 1; addr_in_dccm_dc2 = 1; ldst_dual_dc2 = 1;
      @(posedge clk); @(negedge clk);
      // In DC3: single-bank DMA load (ldst_dual_dc3=0, dma=1) -> single_ecc_error_hi_dc3 must be 0!
      lsu_pkt_dc3.valid = 1; lsu_pkt_dc3.load = 1; lsu_pkt_dc3.dma = 1; addr_in_dccm_dc3 = 1;
      lsu_addr_dc3 = 32'h200; end_addr_dc3 = 32'h200; ldst_dual_dc3 = 0;
      #1; if (single_ecc_error_hi_dc3 !== 1'b0) $fatal(1, "Upper bank ECC error not gated by ldst_dual_dc3");
      // Dual-bank load with misaligned_fault_dc3=1 -> single_ecc_error_hi_dc3 must be 0!
      lsu_addr_dc3 = 32'h203; end_addr_dc3 = 32'h204; ldst_dual_dc3 = 1; misaligned_fault_dc3 = 1;
      #1; if (single_ecc_error_hi_dc3 !== 1'b0) $fatal(1, "Upper bank ECC error not gated by fault");
      misaligned_fault_dc3 = 0;
      #1; if (single_ecc_error_hi_dc3 !== 1'b1) $fatal(1, "Expected upper bank ECC error when dual and no fault");
      @(posedge clk); @(negedge clk);
      lsu_pkt_dc4 = lsu_pkt_dc3; ldst_dual_dc4 = 1; single_ecc_error_hi_dc4 = 1; addr_in_dccm_dc4 = 1; lsu_addr_dc4 = 32'h203; end_addr_dc4 = 32'h204;
      @(posedge clk); @(negedge clk);
      // In DC5: test RAW forwarding suppression on lo bank & scrub replication on hi bank
      lsu_pkt_dc3 = '0; lsu_pkt_dc4 = '0;
      lsu_pkt_dc5.valid = 1; lsu_pkt_dc5.load = 1; lsu_commit_dc5 = 1; addr_in_dccm_dc5 = 1; lsu_addr_dc5 = 32'h203; end_addr_dc5 = 32'h204;
      single_ecc_error_lo_dc5 = 1; lsu_raw_fwd_lo_dc5 = 1; single_ecc_error_hi_dc5 = 0;
      #1; if (ld_single_ecc_error_dc5 !== 1'b0) $fatal(1, "RAW fwd failed to suppress ld_single_ecc_error_lo_dc5");
      // Test younger DMA store in DC3 kills lo scrub
      lsu_raw_fwd_lo_dc5 = 0;
      lsu_pkt_dc3.valid = 1; lsu_pkt_dc3.store = 1; lsu_pkt_dc3.dma = 1; addr_in_dccm_dc3 = 1; lsu_addr_dc3 = 32'h200; end_addr_dc3 = 32'h200;
      @(posedge clk); @(negedge clk);
      #1; if (ld_single_ecc_error_lo_dc5_ff !== 1'b0) $fatal(1, "DC3 DMA store failed to kill lo ECC scrub");
      // Now trigger hi-bank scrub and check dccm_wr_data_lo replication (mutant_04)
      lsu_pkt_dc3 = '0; single_ecc_error_lo_dc5 = 0; single_ecc_error_hi_dc5 = 1;
      @(posedge clk); @(negedge clk);
      clear_all();
      #1; if (ld_single_ecc_error_hi_dc5_ff !== 1'b1 || dccm_wr_data_lo[31:0] !== 32'hB0B0_B0B0)
         $fatal(1, "Hi-bank ECC scrub port replication failed: %h", dccm_wr_data_lo[31:0]);
      @(posedge clk); @(negedge clk);

      // 6. Youngest-first DC3 > DC4 > DC5 > stbuf load byte forwarding priority (wf5)
      // First put a word store into stbuf at 0x300 with data 0x1111_1111 (hold drain with rden_dc1)
      lsu_pkt_dc1_pre.valid = 1; lsu_pkt_dc1_pre.load = 1; addr_in_dccm_region_dc1 = 1; lsu_addr_dc1 = 32'h300; end_addr_dc1 = 32'h300;
      lsu_pkt_dc3.valid = 1; lsu_pkt_dc3.store = 1; lsu_pkt_dc3.word = 1; addr_in_dccm_dc3 = 1; lsu_addr_dc3 = 32'h300; end_addr_dc3 = 32'h300; store_data_dc3 = 32'h1111_1111;
      @(posedge clk); @(negedge clk);
      lsu_pkt_dc4 = lsu_pkt_dc3; addr_in_dccm_dc4 = 1; lsu_addr_dc4 = 32'h300; end_addr_dc4 = 32'h300;
      lsu_pkt_dc3.by = 1; lsu_pkt_dc3.word = 0; lsu_addr_dc3 = 32'h300; store_data_dc3 = 32'h0000_0055; // older -> will be in DC5
      @(posedge clk); @(negedge clk);
      lsu_pkt_dc5 = lsu_pkt_dc4; addr_in_dccm_dc5 = 1; lsu_addr_dc5 = 32'h300; end_addr_dc5 = 32'h300; store_stbuf_reqvld_dc5 = 1; lsu_commit_dc5 = 1;
      lsu_pkt_dc4 = lsu_pkt_dc3; addr_in_dccm_dc4 = 1; lsu_addr_dc4 = 32'h300; end_addr_dc4 = 32'h300;
      lsu_pkt_dc3.half = 1; lsu_pkt_dc3.by = 0; lsu_addr_dc3 = 32'h300; store_data_dc3 = 32'h0000_4444; // will be in DC4
      @(posedge clk); @(negedge clk);
      // Now stbuf has 0x1111_1111, DC5 has byte[0]=0x55, DC4 has half[1:0]=0x4444, and put DC3 byte[0]=0x33!
      lsu_pkt_dc5 = lsu_pkt_dc4; addr_in_dccm_dc5 = 1; lsu_addr_dc5 = 32'h300; end_addr_dc5 = 32'h300; store_stbuf_reqvld_dc5 = 0; lsu_commit_dc5 = 0;
      lsu_pkt_dc4 = lsu_pkt_dc3; addr_in_dccm_dc4 = 1; lsu_addr_dc4 = 32'h300; end_addr_dc4 = 32'h300;
      lsu_pkt_dc3 = '0; lsu_pkt_dc3.valid = 1; lsu_pkt_dc3.store = 1; lsu_pkt_dc3.by = 1; addr_in_dccm_dc3 = 1; lsu_addr_dc3 = 32'h300; end_addr_dc3 = 32'h300; store_data_dc3 = 32'h0000_0033;
      lsu_pkt_dc2 = '0; lsu_pkt_dc2.valid = 1; lsu_pkt_dc2.load = 1; lsu_pkt_dc2.word = 1; addr_in_dccm_dc2 = 1; lsu_cmpen_dc2 = 1; lsu_addr_dc2 = 32'h300; end_addr_dc2 = 32'h300;
      @(posedge clk); @(negedge clk);
      #1;
      // Expected forwarded bytes: byte 0 from DC3 (0x33), byte 1 from DC4 (0x44), bytes 3:2 from stbuf (0x1111)
      if (stbuf_fwdbyteen_lo_dc3 !== 4'b1111 || stbuf_fwddata_lo_dc3 !== 32'h1111_4433)
         $fatal(1, "Youngest-first forwarding failed: en=%b data=%h", stbuf_fwdbyteen_lo_dc3, stbuf_fwddata_lo_dc3);

      $display("PASS eh2_lsu_subsys_top seed=%0d", SEED);
      $finish;
   end
endmodule
