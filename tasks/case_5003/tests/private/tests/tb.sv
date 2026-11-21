module tb;
  import ariane_pkg::*;

  function automatic config_pkg::cva6_cfg_t make_cfg();
    config_pkg::cva6_cfg_t c;
    c = '0;
    c.XLEN = 64;
    c.IS_XLEN64 = 1;
    c.VLEN = 64;
    c.PLEN = 56;
    c.GPLEN = 41;
    c.PPNW = 44;
    c.GPPNW = 29;
    c.PtLevels = 3;
    c.VpnLen = 27;
    c.SV = 39;
    c.SVX = 41;
    c.ASID_WIDTH = 16;
    c.VMID_WIDTH = 14;
    c.InstrTlbEntries = 4;
    c.DataTlbEntries = 4;
    c.UseSharedTlb = 1;
    c.SharedTlbDepth = 4;
    c.DCACHE_INDEX_WIDTH = 12;
    c.DCACHE_TAG_WIDTH = 44;
    c.XLEN_ALIGN_BYTES = 3;
    c.MmuPresent = 1;
    c.SvnapotEn = 1;
    c.RVH = 1;
    c.TvalEn = 1;
    c.NrPMPEntries = 0;
    return c;
  endfunction

  localparam config_pkg::cva6_cfg_t Cfg = make_cfg();
  localparam int unsigned HYP_EXT = 1;

  typedef struct packed {
    logic        valid;
    logic [63:0] cause;
    logic [63:0] tval;
    logic [63:0] tval2;
    logic [31:0] tinst;
    logic        gva;
    logic        timing;
  } exception_t;

  typedef struct packed {
    logic             fetch_valid;
    logic [55:0]      fetch_paddr;
    exception_t       fetch_exception;
  } icache_areq_t;

  typedef struct packed {
    logic             fetch_req;
    logic [63:0]      fetch_vaddr;
  } icache_arsp_t;

  typedef struct packed {
    logic [11:0] address_index;
    logic [43:0] address_tag;
    logic [63:0] data_wdata;
    logic [7:0]  data_wuser;
    logic        data_req;
    logic        data_we;
    logic [7:0]  data_be;
    logic [1:0]  data_size;
    logic [1:0]  data_id;
    logic        kill_req;
    logic        tag_valid;
    logic [7:0]  cbo_op;
  } dcache_req_i_t;

  typedef struct packed {
    logic        data_gnt;
    logic        data_rvalid;
    logic [1:0]  data_rid;
    logic [63:0] data_rdata;
    logic        data_error;
    logic [7:0]  data_ruser;
  } dcache_req_o_t;

  localparam type pte_cva6_t = struct packed {
    logic        n;
    logic [8:0]  reserved;
    logic [43:0] ppn;
    logic [1:0]  rsw;
    logic        d;
    logic        a;
    logic        g;
    logic        u;
    logic        x;
    logic        w;
    logic        r;
    logic        v;
  };

  localparam type tlb_update_cva6_t = struct packed {
    logic                  valid;
    logic                  is_napot_64k;
    logic [1:0][HYP_EXT:0] is_page;
    logic [26:0]           vpn;
    logic [15:0]           asid;
    logic [13:0]           vmid;
    logic [HYP_EXT*2:0]    v_st_enbl;
    pte_cva6_t             content;
    pte_cva6_t             g_content;
  };

  logic clk = 0;
  logic rst_ni = 0;
  always #5 clk = ~clk;

  // Standalone L1 TLB for direct PLRU + unconditional refill test
  logic             u_tlb_flush = 0;
  tlb_update_cva6_t u_tlb_update;
  logic             u_tlb_lu_access = 0;
  logic [15:0]      u_tlb_lu_asid = 16'h0001;
  logic [13:0]      u_tlb_lu_vmid = 14'h0001;
  logic [63:0]      u_tlb_lu_vaddr = '0;
  pte_cva6_t        u_tlb_content;
  logic [1:0]       u_tlb_is_page;
  logic             u_tlb_hit;

  cva6_tlb #(
      .CVA6Cfg          (Cfg),
      .pte_cva6_t       (pte_cva6_t),
      .tlb_update_cva6_t(tlb_update_cva6_t),
      .TLB_ENTRIES      (4),
      .HYP_EXT          (HYP_EXT)
  ) i_unit_tlb (
      .clk_i                 (clk),
      .rst_ni                (rst_ni),
      .flush_i               (u_tlb_flush),
      .flush_vvma_i          (1'b0),
      .flush_gvma_i          (1'b0),
      .s_st_enbl_i           (1'b1),
      .g_st_enbl_i           (1'b0),
      .v_i                   (1'b0),
      .update_i              (u_tlb_update),
      .lu_access_i           (u_tlb_lu_access),
      .lu_asid_i             (u_tlb_lu_asid),
      .lu_vmid_i             (u_tlb_lu_vmid),
      .lu_vaddr_i            (u_tlb_lu_vaddr),
      .lu_gpaddr_o           (),
      .lu_content_o          (u_tlb_content),
      .lu_g_content_o        (),
      .asid_to_be_flushed_i  ('0),
      .vmid_to_be_flushed_i  ('0),
      .vaddr_to_be_flushed_i ('0),
      .gpaddr_to_be_flushed_i('0),
      .lu_is_page_o          (u_tlb_is_page),
      .lu_hit_o              (u_tlb_hit)
  );

  // Full CVA6 MMU subsystem instance
  logic        mmu_flush = 0;
  logic        enable_translation = 1;
  logic        enable_g_translation = 0;
  logic        en_ld_st_translation = 1;
  logic        en_ld_st_g_translation = 0;
  icache_arsp_t icache_areq_i;
  icache_areq_t icache_areq_o;
  exception_t  misaligned_ex;
  logic        lsu_req = 0;
  logic [63:0] lsu_vaddr = '0;
  logic [31:0] lsu_tinst = '0;
  logic        lsu_is_store = 0;
  logic        lsu_dtlb_hit;
  logic [43:0] lsu_dtlb_ppn;
  logic        lsu_valid;
  logic [55:0] lsu_paddr;
  exception_t  lsu_exception;
  riscv::priv_lvl_t priv_lvl = riscv::PRIV_LVL_S;
  riscv::priv_lvl_t ld_st_priv_lvl = riscv::PRIV_LVL_S;
  logic        v_mode = 0;
  logic        ld_st_v_mode = 0;
  logic [43:0] satp_ppn = 44'h00001;
  logic [43:0] vsatp_ppn = 44'h00002;
  logic [43:0] hgatp_ppn = 44'h00003;
  logic [15:0] asid = 16'h0001;
  logic [15:0] vs_asid = 16'h0002;
  logic [13:0] vmid = 14'h0001;
  logic        flush_tlb = 0;
  logic        shared_tlb_flush_busy;
  logic        itlb_miss, dtlb_miss;
  dcache_req_o_t ptw_dcache_i;
  dcache_req_i_t ptw_dcache_o;
  riscv::pmpcfg_t [0:0] pmpcfg = '0;
  logic [0:0][53:0] pmpaddr = '0;

  cva6_mmu #(
      .CVA6Cfg       (Cfg),
      .icache_areq_t (icache_areq_t),
      .icache_arsp_t (icache_arsp_t),
      .icache_dreq_t (logic),
      .icache_drsp_t (logic),
      .dcache_req_i_t(dcache_req_i_t),
      .dcache_req_o_t(dcache_req_o_t),
      .exception_t   (exception_t),
      .HYP_EXT       (HYP_EXT)
  ) dut_mmu (
      .clk_i                    (clk),
      .rst_ni                   (rst_ni),
      .flush_i                  (mmu_flush),
      .enable_translation_i     (enable_translation),
      .enable_g_translation_i   (enable_g_translation),
      .en_ld_st_translation_i   (en_ld_st_translation),
      .en_ld_st_g_translation_i (en_ld_st_g_translation),
      .icache_areq_i            (icache_areq_i),
      .icache_areq_o            (icache_areq_o),
      .misaligned_ex_i          (misaligned_ex),
      .lsu_req_i                (lsu_req),
      .lsu_vaddr_i              (lsu_vaddr),
      .lsu_tinst_i              (lsu_tinst),
      .lsu_is_store_i           (lsu_is_store),
      .csr_hs_ld_st_inst_o      (),
      .lsu_dtlb_hit_o           (lsu_dtlb_hit),
      .lsu_dtlb_ppn_o           (lsu_dtlb_ppn),
      .lsu_valid_o              (lsu_valid),
      .lsu_paddr_o              (lsu_paddr),
      .lsu_vaddr_o              (),
      .lsu_is_store_o           (),
      .lsu_hlvx_inst_o          (),
      .lsu_exception_o          (lsu_exception),
      .priv_lvl_i               (priv_lvl),
      .v_i                      (v_mode),
      .ld_st_priv_lvl_i         (ld_st_priv_lvl),
      .ld_st_v_i                (ld_st_v_mode),
      .sum_i                    (1'b1),
      .vs_sum_i                 (1'b1),
      .mxr_i                    (1'b1),
      .vmxr_i                   (1'b1),
      .mbe_i                    (1'b0),
      .hlvx_inst_i              (1'b0),
      .hs_ld_st_inst_i          (1'b0),
      .satp_ppn_i               (satp_ppn),
      .vsatp_ppn_i              (vsatp_ppn),
      .hgatp_ppn_i              (hgatp_ppn),
      .asid_i                   (asid),
      .vs_asid_i                (vs_asid),
      .asid_to_be_flushed_i     ('0),
      .vmid_i                   (vmid),
      .vmid_to_be_flushed_i     ('0),
      .vaddr_to_be_flushed_i    ('0),
      .gpaddr_to_be_flushed_i   ('0),
      .flush_tlb_i              (flush_tlb),
      .flush_tlb_vvma_i         (1'b0),
      .flush_tlb_gvma_i         (1'b0),
      .shared_tlb_flush_busy_o  (shared_tlb_flush_busy),
      .itlb_miss_o              (itlb_miss),
      .dtlb_miss_o              (dtlb_miss),
      .req_port_i               (ptw_dcache_i),
      .req_port_o               (ptw_dcache_o),
      .pmpcfg_i                 (pmpcfg),
      .pmpaddr_i                (pmpaddr)
  );

  // Page table responder for PTW driven strictly by external dcache port handshakes and addresses:
  // - Root page table (level 0, address_tag == satp_ppn/vsatp_ppn) -> non-leaf pointer PTE with PPN = 44'h00010
  // - Level-1 page table (address_tag == 44'h00010) -> non-leaf pointer PTE with PPN = 44'h00011
  // - Level-2 leaf page table (address_tag == 44'h00011 or mock_leaf_now) -> mock_leaf_pte
  pte_cva6_t mock_leaf_pte;
  logic      ptw_gnt_en = 1;
  logic      ptw_req_pending_q;
  logic      ptw_leaf_rvalid_q;

  assign ptw_dcache_i.data_gnt   = ptw_dcache_o.data_req & ptw_gnt_en;
  assign ptw_dcache_i.data_rid   = '0;
  assign ptw_dcache_i.data_error = 1'b0;
  assign ptw_dcache_i.data_ruser = '0;

  logic mock_leaf_now = 0;

  always_ff @(posedge clk or negedge rst_ni) begin
    if (!rst_ni) begin
      ptw_req_pending_q        <= 1'b0;
      ptw_leaf_rvalid_q        <= 1'b0;
      ptw_dcache_i.data_rvalid <= 1'b0;
      ptw_dcache_i.data_rdata  <= '0;
    end else begin
      ptw_dcache_i.data_rvalid <= 1'b0;
      ptw_leaf_rvalid_q        <= 1'b0;
      if (ptw_req_pending_q && ptw_dcache_o.tag_valid && !ptw_dcache_o.kill_req) begin
        ptw_dcache_i.data_rvalid <= 1'b1;
        if (mock_leaf_now || ptw_dcache_o.address_tag == 44'h00011) begin
          ptw_dcache_i.data_rdata <= mock_leaf_pte;
          ptw_leaf_rvalid_q       <= 1'b1;
        end else begin
          // Non-leaf pointer PTE (v=1, r=0, w=0, x=0) determined by external table base PPN
          pte_cva6_t ptr_pte;
          ptr_pte     = '0;
          ptr_pte.v   = 1'b1;
          ptr_pte.ppn = (ptw_dcache_o.address_tag == 44'h00010) ? 44'h00011 : 44'h00010;
          ptw_dcache_i.data_rdata <= ptr_pte;
        end
      end
      if (ptw_dcache_o.data_req && ptw_dcache_i.data_gnt) begin
        ptw_req_pending_q <= 1'b1;
      end else begin
        ptw_req_pending_q <= 1'b0;
      end
    end
  end

  task automatic tick;
    @(negedge clk);
    #1;
  endtask

  initial begin
    u_tlb_update = '0;
    icache_areq_i = '0;
    misaligned_ex = '0;
    mock_leaf_pte = '0;

    tick();
    rst_ni = 1;
    tick();

    // =========================================================================
    // TEST 1: cva6_tlb unconditional refill installation when lu_hit_o == 1
    //         and PLRU tree update on refill across 4 ways
    // =========================================================================
    for (int w = 0; w < 4; w++) begin
      u_tlb_update          = '0;
      u_tlb_update.valid    = 1'b1;
      u_tlb_update.vpn      = 27'h00100 + w;
      u_tlb_update.asid     = 16'h0001;
      u_tlb_update.vmid     = 14'h0001;
      u_tlb_update.v_st_enbl = 3'b001;
      u_tlb_update.content.v = 1'b1;
      u_tlb_update.content.r = 1'b1;
      u_tlb_update.content.w = 1'b1;
      u_tlb_update.content.x = 1'b1;
      u_tlb_update.content.a = 1'b1;
      u_tlb_update.content.d = 1'b1;
      u_tlb_update.content.ppn = 44'h02000 + w;
      u_tlb_lu_vaddr        = {25'b0, 27'(27'h00100 + w), 12'h000};
      u_tlb_lu_access       = 1'b1;
      tick();
    end
    u_tlb_update = '0;
    tick();

    // Verify all 4 VPNs hit in i_unit_tlb
    for (int w = 0; w < 4; w++) begin
      u_tlb_lu_vaddr  = {25'b0, 27'(27'h00100 + w), 12'h000};
      u_tlb_lu_access = 1'b1;
      #1;
      if (!u_tlb_hit || u_tlb_content.ppn !== (44'h02000 + w)) begin
        $fatal(1, "TEST 1: cva6_tlb failed to retain way %0d (hit=%b ppn=%h)", w, u_tlb_hit, u_tlb_content.ppn);
      end
      tick();
    end
    u_tlb_lu_access = 1'b0;

    // =========================================================================
    // TEST 2: PTW flush_i in IDLE must not activate PTW (ptw_active_o) or pulse miss,
    //         and flush_i on leaf PTE lookup completion cycle must suppress shared_tlb_update_o.valid
    // =========================================================================
    mmu_flush = 1'b1;
    tick();
    mmu_flush = 1'b0;
    if (dut_mmu.i_ptw.ptw_active_o !== 1'b0) begin
      $fatal(1, "TEST 2: cva6_ptw asserted ptw_active_o after flush_i in IDLE!");
    end

    // Start a DTLB miss walk and flush it on the cycle immediately after the level-2 leaf PTE rvalid handshake
    mock_leaf_pte     = '0;
    mock_leaf_pte.v   = 1'b1;
    mock_leaf_pte.r   = 1'b1;
    mock_leaf_pte.w   = 1'b1;
    mock_leaf_pte.x   = 1'b1;
    mock_leaf_pte.a   = 1'b1;
    mock_leaf_pte.d   = 1'b1;
    mock_leaf_pte.ppn = 44'h09999;

    lsu_req   = 1'b1;
    lsu_vaddr = 64'h0000_0000_0005_0000;
    // Wait until external memory responder drives data_rvalid for the level-2 leaf PTE, then advance 1 cycle
    // to the leaf PTE evaluation/completion cycle
    begin
      int guard = 0;
      while (!ptw_leaf_rvalid_q) begin
        tick();
        guard++;
        if (guard > 40) $fatal(1, "TEST 2: timeout waiting for level-2 leaf PTE rvalid");
      end
      tick();
    end
    // Assert mmu_flush = 1 on this exact leaf completion cycle!
    lsu_req   = 1'b0;
    mmu_flush = 1'b1;
    #1;
    if (dut_mmu.i_ptw.shared_tlb_update_o.valid !== 1'b0) begin
      $fatal(1, "TEST 2: cva6_ptw asserted shared_tlb_update_o.valid while flush_i == 1!");
    end
    tick();
    mmu_flush = 1'b0;
    repeat (4) tick();

    // =========================================================================
    // TEST 3: 64KiB Svnapot installation at subpage 3 (vaddr[15:12] = 4'h3)
    //         followed by lookup at subpage 4'hA in Shared TLB + ITLB progress
    //         while DTLB is hitting!
    // =========================================================================
    mock_leaf_pte     = '0;
    mock_leaf_pte.v   = 1'b1;
    mock_leaf_pte.r   = 1'b1;
    mock_leaf_pte.w   = 1'b1;
    mock_leaf_pte.x   = 1'b1;
    mock_leaf_pte.a   = 1'b1;
    mock_leaf_pte.d   = 1'b1;
    mock_leaf_pte.n   = 1'b1; // 64KiB Svnapot!
    mock_leaf_pte.ppn = 44'h0ABCD8; // ppn[3:0] == 4'b1000 as required by Svnapot

    // Walk via DTLB for VA = 0x0000_0000_0012_3000 (subpage 3 of 64KiB block 0x0012_0000)
    lsu_req   = 1'b1;
    lsu_vaddr = 64'h0000_0000_0012_3000;
    begin
      int guard = 0;
      while (!lsu_dtlb_hit) begin
        tick();
        guard++;
        if (guard > 60) $fatal(1, "TEST 3: timeout waiting for Svnapot DTLB hit");
      end
    end
    if (lsu_dtlb_ppn !== 44'h0ABCD3) begin
      $fatal(1, "TEST 3: Svnapot DTLB PPN mismatch for subpage 3: got %h expected 0abcd3", lsu_dtlb_ppn);
    end
    tick();

    // Now keep lsu_req = 1 at 0x0000_0000_0012_3000 (so DTLB HITS every cycle: dtlb_access_i=1, dtlb_hit_i=1!),
    // AND simultaneously request ITLB at subpage 4'hA of the SAME 64KiB Svnapot region: VA = 0x0000_0000_0012_A000!
    // Because ITLB has not cached this region yet, ITLB misses and queries cva6_shared_tlb:
    // (a) cva6_shared_tlb must NOT be blocked by the concurrent DTLB hit!
    // (b) cva6_shared_tlb must index the SAME set for subpage 4'hA as subpage 4'h3 and HIT in cva6_shared_tlb without starting a PTW walk!
    icache_areq_i.fetch_req   = 1'b1;
    icache_areq_i.fetch_vaddr = 64'h0000_0000_0012_A000;
    tick();
    // On this cycle (1 cycle after ITLB miss lookup), cva6_shared_tlb should hit and update i_itlb, without pulsing itlb_miss!
    if (itlb_miss) begin
      $fatal(1, "TEST 3: Svnapot subpage 4'hA missed in cva6_shared_tlb (NAPOT set-index aliasing bug)!");
    end
    tick();
    if (!icache_areq_o.fetch_valid || icache_areq_o.fetch_paddr !== 56'h0ABCD_A000) begin
      $fatal(1, "TEST 3: ITLB failed to hit/translate Svnapot subpage 4'hA while DTLB was hitting: valid=%b paddr=%h", icache_areq_o.fetch_valid, icache_areq_o.fetch_paddr);
    end
    icache_areq_i.fetch_req = 1'b0;
    lsu_req = 1'b0;
    tick();

    // =========================================================================
    // TEST 4: PTW stage-enable preservation in cva6_shared_tlb when DTLB (with
    //         different v_st_enbl) accesses cva6_shared_tlb during an ITLB walk
    // =========================================================================
    // Set ITLB mode: v_mode = 0, enable_translation = 1, enable_g_translation = 0 (v_st_enbl[1] = 3'b001)
    // Set DTLB mode: ld_st_v_mode = 1, en_ld_st_translation = 1, en_ld_st_g_translation = 0 (v_st_enbl[0] = 3'b101)
    v_mode       = 1'b0;
    ld_st_v_mode = 1'b1;
    mock_leaf_pte     = '0;
    mock_leaf_pte.v   = 1'b1;
    mock_leaf_pte.r   = 1'b1;
    mock_leaf_pte.w   = 1'b1;
    mock_leaf_pte.x   = 1'b1;
    mock_leaf_pte.a   = 1'b1;
    mock_leaf_pte.d   = 1'b1;
    mock_leaf_pte.ppn = 44'h077770;

    // Trigger an ITLB miss at VA = 0x0000_0000_0024_0000
    icache_areq_i.fetch_req   = 1'b1;
    icache_areq_i.fetch_vaddr = 64'h0000_0000_0024_0000;
    tick(); // ITLB misses, shared_tlb_access_d = 1, i_req_d = 1
    tick(); // shared_tlb misses, PTW starts walk (shared_tlb_miss = 1)
    // While PTW is walking for ITLB, drop icache_areq_i and issue a DTLB miss so i_req_q changes to 0!
    icache_areq_i.fetch_req = 1'b0;
    lsu_req   = 1'b1;
    lsu_vaddr = 64'h0000_0000_0038_0000;
    tick();
    lsu_req   = 1'b0;
    // Wait for PTW to finish the ITLB walk and return to IDLE
    begin
      int guard = 0;
      while (dut_mmu.i_ptw.ptw_active_o) begin
        tick();
        guard++;
        if (guard > 60) $fatal(1, "TEST 4: timeout waiting for ITLB PTW walk to complete");
      end
    end
    tick();
    // Now re-assert icache_areq_i.fetch_req for VA = 0x0000_0000_0024_0000:
    // It must HIT in cva6_shared_tlb (because v_st_enbl was saved as 3'b001 for ITLB, not overwritten with 3'b101 from DTLB!)
    icache_areq_i.fetch_req   = 1'b1;
    icache_areq_i.fetch_vaddr = 64'h0000_0000_0024_0000;
    tick();
    if (itlb_miss) begin
      $fatal(1, "TEST 4: ITLB lookup missed in cva6_shared_tlb after ITLB PTW walk (v_st_enbl overwritten by DTLB lookup during walk)!");
    end
    tick();
    if (!icache_areq_o.fetch_valid || icache_areq_o.fetch_paddr !== 56'h07777_0000) begin
      $fatal(1, "TEST 4: ITLB translation failed after shared_tlb hit: valid=%b paddr=%h", icache_areq_o.fetch_valid, icache_areq_o.fetch_paddr);
    end
    icache_areq_i.fetch_req = 1'b0;
    ld_st_v_mode = 1'b0;
    tick();

    //RANDOM_TESTS_HERE

    $display("PASS MMU Sv39+Svnapot tests");
    $finish;
  end
endmodule
