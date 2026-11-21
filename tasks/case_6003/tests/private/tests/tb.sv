// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps

module tb #(parameter int SEED = 101);

   logic                        clk;
   logic                        rst_l;
   logic                        scan_mode;
   logic                        bus_clk_en;
   logic                        dma_bus_clk_en;
   logic                        clk_override;

   // 1. Core LSU AXI4 Master -> AHB-Lite Master Bridge (axi4_to_ahb)
   logic                        lsu_axi_awvalid;
   logic                        lsu_axi_awready;
   logic [`RV_LSU_BUS_TAG-1:0]  lsu_axi_awid;
   logic [31:0]                 lsu_axi_awaddr;
   logic [2:0]                  lsu_axi_awsize;
   logic [2:0]                  lsu_axi_awprot;

   logic                        lsu_axi_wvalid;
   logic                        lsu_axi_wready;
   logic [63:0]                 lsu_axi_wdata;
   logic [7:0]                  lsu_axi_wstrb;
   logic                        lsu_axi_wlast;

   logic                        lsu_axi_bvalid;
   logic                        lsu_axi_bready;
   logic [1:0]                  lsu_axi_bresp;
   logic [`RV_LSU_BUS_TAG-1:0]  lsu_axi_bid;

   logic                        lsu_axi_arvalid;
   logic                        lsu_axi_arready;
   logic [`RV_LSU_BUS_TAG-1:0]  lsu_axi_arid;
   logic [31:0]                 lsu_axi_araddr;
   logic [2:0]                  lsu_axi_arsize;
   logic [2:0]                  lsu_axi_arprot;

   logic                        lsu_axi_rvalid;
   logic                        lsu_axi_rready;
   logic [`RV_LSU_BUS_TAG-1:0]  lsu_axi_rid;
   logic [63:0]                 lsu_axi_rdata;
   logic [1:0]                  lsu_axi_rresp;
   logic                        lsu_axi_rlast;

   logic [31:0]                 lsu_ahb_haddr;
   logic [2:0]                  lsu_ahb_hburst;
   logic                        lsu_ahb_hmastlock;
   logic [3:0]                  lsu_ahb_hprot;
   logic [2:0]                  lsu_ahb_hsize;
   logic [1:0]                  lsu_ahb_htrans;
   logic                        lsu_ahb_hwrite;
   logic [63:0]                 lsu_ahb_hwdata;
   logic [63:0]                 lsu_ahb_hrdata;
   logic                        lsu_ahb_hready;
   logic                        lsu_ahb_hresp;

   // 2. External AHB-Lite Slave -> AXI4 Gasket (ahb_to_axi4) -> DMA Controller (dma_ctrl)
   logic [31:0]                 dma_ahb_haddr;
   logic [2:0]                  dma_ahb_hburst;
   logic                        dma_ahb_hmastlock;
   logic [3:0]                  dma_ahb_hprot;
   logic [2:0]                  dma_ahb_hsize;
   logic [1:0]                  dma_ahb_htrans;
   logic                        dma_ahb_hwrite;
   logic [63:0]                 dma_ahb_hwdata;
   logic                        dma_ahb_hsel;
   logic                        dma_ahb_hreadyin;
   logic [63:0]                 dma_ahb_hrdata;
   logic                        dma_ahb_hreadyout;
   logic                        dma_ahb_hresp;

   logic                        ext_dma_axi_sel;
   logic                        ext_dma_axi_awvalid;
   logic                        ext_dma_axi_awready;
   logic [`RV_DMA_BUS_TAG-1:0]  ext_dma_axi_awid;
   logic [31:0]                 ext_dma_axi_awaddr;
   logic [2:0]                  ext_dma_axi_awsize;
   logic [2:0]                  ext_dma_axi_awprot;
   logic [7:0]                  ext_dma_axi_awlen;
   logic [1:0]                  ext_dma_axi_awburst;
   logic                        ext_dma_axi_wvalid;
   logic                        ext_dma_axi_wready;
   logic [63:0]                 ext_dma_axi_wdata;
   logic [7:0]                  ext_dma_axi_wstrb;
   logic                        ext_dma_axi_wlast;
   logic                        ext_dma_axi_bvalid;
   logic                        ext_dma_axi_bready;
   logic [1:0]                  ext_dma_axi_bresp;
   logic [`RV_DMA_BUS_TAG-1:0]  ext_dma_axi_bid;
   logic                        ext_dma_axi_arvalid;
   logic                        ext_dma_axi_arready;
   logic [`RV_DMA_BUS_TAG-1:0]  ext_dma_axi_arid;
   logic [31:0]                 ext_dma_axi_araddr;
   logic [2:0]                  ext_dma_axi_arsize;
   logic [2:0]                  ext_dma_axi_arprot;
   logic [7:0]                  ext_dma_axi_arlen;
   logic [1:0]                  ext_dma_axi_arburst;
   logic                        ext_dma_axi_rvalid;
   logic                        ext_dma_axi_rready;
   logic [`RV_DMA_BUS_TAG-1:0]  ext_dma_axi_rid;
   logic [63:0]                 ext_dma_axi_rdata;
   logic [1:0]                  ext_dma_axi_rresp;
   logic                        ext_dma_axi_rlast;

   // Debug interface to DMA Controller
   logic [31:0]                 dbg_cmd_addr;
   logic [31:0]                 dbg_cmd_wrdata;
   logic                        dbg_cmd_valid;
   logic                        dbg_cmd_write;
   logic [1:0]                  dbg_cmd_type;
   logic [1:0]                  dbg_cmd_size;
   logic                        dbg_dma_bubble;
   logic                        dma_dbg_ready;
   logic                        dma_dbg_cmd_done;
   logic                        dma_dbg_cmd_fail;
   logic [31:0]                 dma_dbg_rddata;

   // Core DCCM / ICCM interface from DMA Controller
   logic                        dma_dccm_req;
   logic                        dma_iccm_req;
   logic [31:0]                 dma_mem_addr;
   logic [2:0]                  dma_mem_sz;
   logic                        dma_mem_write;
   logic [63:0]                 dma_mem_wdata;
   logic                        dccm_dma_rvalid;
   logic                        dccm_dma_ecc_error;
   logic [63:0]                 dccm_dma_rdata;
   logic                        iccm_dma_rvalid;
   logic                        iccm_dma_ecc_error;
   logic [63:0]                 iccm_dma_rdata;
   logic                        dma_dccm_stall_any;
   logic                        dma_iccm_stall_any;
   logic                        dccm_ready;
   logic                        iccm_ready;
   logic                        dec_tlu_stall_dma;
   logic [2:0]                  dec_tlu_dma_qos_prty;
   logic                        dma_mem_dccm_req;
   logic                        dma_slv_algn_err;

   logic [7:0]                  qos_in;
   logic [7:0]                  qos_out;
   logic [7:0]                  region_in;
   logic [7:0]                  region_out;

   veer_bus_dma_top dut (.*);

   initial begin
      clk = 1'b0;
      forever #5 clk = ~clk;
   end

   task automatic fail(input string msg);
      $display("FAIL: %s", msg);
      $finish(1);
   endtask

   task automatic reset_all();
      rst_l = 1'b0;
      scan_mode = 1'b0;
      bus_clk_en = 1'b1;
      dma_bus_clk_en = 1'b1;
      clk_override = 1'b0;
      lsu_axi_awvalid = 1'b0;
      lsu_axi_awid = '0;
      lsu_axi_awaddr = '0;
      lsu_axi_awsize = '0;
      lsu_axi_awprot = '0;
      lsu_axi_wvalid = 1'b0;
      lsu_axi_wdata = '0;
      lsu_axi_wstrb = '0;
      lsu_axi_wlast = 1'b1;
      lsu_axi_bready = 1'b1;
      lsu_axi_arvalid = 1'b0;
      lsu_axi_arid = '0;
      lsu_axi_araddr = '0;
      lsu_axi_arsize = '0;
      lsu_axi_arprot = '0;
      lsu_axi_rready = 1'b1;
      lsu_ahb_hrdata = '0;
      lsu_ahb_hready = 1'b1;
      lsu_ahb_hresp = 1'b0;

      dma_ahb_haddr = '0;
      dma_ahb_hburst = '0;
      dma_ahb_hmastlock = 1'b0;
      dma_ahb_hprot = 4'b0011;
      dma_ahb_hsize = '0;
      dma_ahb_htrans = 2'b00;
      dma_ahb_hwrite = 1'b0;
      dma_ahb_hwdata = '0;
      dma_ahb_hsel = 1'b0;
      dma_ahb_hreadyin = 1'b1;

      ext_dma_axi_sel = 1'b0;
      ext_dma_axi_awvalid = 1'b0;
      ext_dma_axi_awid = '0;
      ext_dma_axi_awaddr = '0;
      ext_dma_axi_awsize = '0;
      ext_dma_axi_awprot = '0;
      ext_dma_axi_awlen = '0;
      ext_dma_axi_awburst = 2'b01;
      ext_dma_axi_wvalid = 1'b0;
      ext_dma_axi_wdata = '0;
      ext_dma_axi_wstrb = '0;
      ext_dma_axi_wlast = 1'b1;
      ext_dma_axi_bready = 1'b1;
      ext_dma_axi_arvalid = 1'b0;
      ext_dma_axi_arid = '0;
      ext_dma_axi_araddr = '0;
      ext_dma_axi_arsize = '0;
      ext_dma_axi_arprot = '0;
      ext_dma_axi_arlen = '0;
      ext_dma_axi_arburst = 2'b01;
      ext_dma_axi_rready = 1'b1;

      dbg_cmd_addr = '0;
      dbg_cmd_wrdata = '0;
      dbg_cmd_valid = 1'b0;
      dbg_cmd_write = 1'b0;
      dbg_cmd_type = 2'b00;
      dbg_cmd_size = 2'b00;
      dbg_dma_bubble = 1'b0;

      dccm_dma_rvalid = 1'b0;
      dccm_dma_ecc_error = 1'b0;
      dccm_dma_rdata = '0;
      iccm_dma_rvalid = 1'b0;
      iccm_dma_ecc_error = 1'b0;
      iccm_dma_rdata = '0;
      dccm_ready = 1'b1;
      iccm_ready = 1'b1;
      dec_tlu_stall_dma = 1'b0;
      dec_tlu_dma_qos_prty = 3'd3;
      qos_in = 8'h5a;
      region_in = 8'ha5;

      repeat (5) @(posedge clk);
      rst_l = 1'b1;
      repeat (2) @(posedge clk);
   endtask

   logic        inject_dccm_ecc_err;
   logic        inject_iccm_ecc_err;
   logic [63:0] mem_dccm_last_wdata;
   logic [31:0] mem_dccm_last_addr;
   logic [2:0]  mem_dccm_last_sz;
   int          dccm_req_seen;
   int          iccm_req_seen;
   logic [7:0]  req_is_write_hist;
   int          req_hist_cnt;

   logic        pipe_dccm_rd_q1, pipe_dccm_rd_q2;
   logic [31:0] pipe_dccm_addr_q1, pipe_dccm_addr_q2;
   logic        pipe_iccm_rd_q1;
   logic [31:0] pipe_iccm_addr_q1;

   always_ff @(posedge clk or negedge rst_l) begin
      if (!rst_l) begin
         pipe_dccm_rd_q1   <= 1'b0;
         pipe_dccm_rd_q2   <= 1'b0;
         pipe_dccm_addr_q1 <= '0;
         pipe_dccm_addr_q2 <= '0;
         pipe_iccm_rd_q1   <= 1'b0;
         pipe_iccm_addr_q1 <= '0;
         dccm_dma_rvalid   <= 1'b0;
         dccm_dma_ecc_error<= 1'b0;
         dccm_dma_rdata    <= '0;
         iccm_dma_rvalid   <= 1'b0;
         iccm_dma_ecc_error<= 1'b0;
         iccm_dma_rdata    <= '0;
         mem_dccm_last_wdata <= '0;
         mem_dccm_last_addr  <= '0;
         mem_dccm_last_sz    <= '0;
         dccm_req_seen     <= 0;
         iccm_req_seen     <= 0;
         req_is_write_hist <= '0;
         req_hist_cnt      <= 0;
      end else begin
         if (dma_dccm_req || dma_iccm_req) begin
            req_is_write_hist[req_hist_cnt & 7] <= dma_mem_write;
            req_hist_cnt <= req_hist_cnt + 1;
         end
         if (dma_dccm_req) begin
            dccm_req_seen <= dccm_req_seen + 1;
            if (dma_mem_write) begin
               mem_dccm_last_wdata <= dma_mem_wdata;
               mem_dccm_last_addr  <= dma_mem_addr;
               mem_dccm_last_sz    <= dma_mem_sz;
            end
         end
         if (dma_iccm_req) begin
            iccm_req_seen <= iccm_req_seen + 1;
         end

         pipe_dccm_rd_q1   <= dma_dccm_req & ~dma_mem_write;
         pipe_dccm_addr_q1 <= dma_mem_addr;
         pipe_dccm_rd_q2   <= pipe_dccm_rd_q1;
         pipe_dccm_addr_q2 <= pipe_dccm_addr_q1;

         dccm_dma_rvalid    <= pipe_dccm_rd_q2;
         dccm_dma_ecc_error <= pipe_dccm_rd_q2 & inject_dccm_ecc_err;
         dccm_dma_rdata     <= {pipe_dccm_addr_q2 ^ 32'hCAFE_0000, pipe_dccm_addr_q2 ^ 32'hBEEF_0000};

         pipe_iccm_rd_q1   <= dma_iccm_req & ~dma_mem_write;
         pipe_iccm_addr_q1 <= dma_mem_addr;

         iccm_dma_rvalid    <= pipe_iccm_rd_q1;
         iccm_dma_ecc_error <= pipe_iccm_rd_q1 & inject_iccm_ecc_err;
         iccm_dma_rdata     <= {pipe_iccm_addr_q1 ^ 32'h1CC0_0000, pipe_iccm_addr_q1 ^ 32'h2CC0_0000};
      end
   end

   initial begin
      int unsigned rng;
      int ahb_beats;
      logic [2:0] seen_offsets [0:7];
      logic [2:0] seen_sizes   [0:7];
      int timeout;

      rng = SEED;
      inject_dccm_ecc_err = 1'b0;
      inject_iccm_ecc_err = 1'b0;
      reset_all();

      // Check transparent sideband channels
      for (int k = 0; k < 16; k++) begin
         qos_in = 8'(k * 17 + SEED);
         region_in = 8'(255 - k * 13);
         #1;
         if (qos_out !== qos_in || region_out !== region_in)
            fail("Transparent sideband channel mismatch");
      end

      // =========================================================================
      // Phase 1: LSU AXI4-to-AHB-Lite Master Bridge (axi4_to_ahb)
      // 1A: Aligned sub-dword 64-bit writes (8'h03 -> addr 0, 8'h0c -> addr 2, 8'h30 -> addr 4, 8'hc0 -> addr 6, 8'hf0 -> addr 4)
      // =========================================================================
      begin
         byte unsigned sub_strbs [0:4] = '{8'h03, 8'h0c, 8'h30, 8'hc0, 8'hf0};
         logic [2:0]   exp_off   [0:4] = '{3'h0,  3'h2,  3'h4,  3'h6,  3'h4};
         logic [2:0]   exp_sz    [0:4] = '{3'h1,  3'h1,  3'h1,  3'h1,  3'h2};
         for (int idx = 0; idx < 5; idx++) begin
            @(negedge clk);
            lsu_axi_awvalid = 1'b1;
            lsu_axi_awid    = 4'(idx + 1);
            lsu_axi_awaddr  = 32'hc058_1000;
            lsu_axi_awsize  = 3'b011;
            lsu_axi_wvalid  = 1'b1;
            lsu_axi_wdata   = 64'hdead_beef_cafe_babe;
            lsu_axi_wstrb   = sub_strbs[idx];
            @(posedge clk);
            while (!(lsu_axi_awready && lsu_axi_wready)) @(posedge clk);
            @(negedge clk);
            lsu_axi_awvalid = 1'b0;
            lsu_axi_wvalid  = 1'b0;

            ahb_beats = 0;
            timeout = 0;
            while (!lsu_axi_bvalid && timeout < 40) begin
               #1;
               if (lsu_ahb_htrans == 2'b10 && lsu_ahb_hready && lsu_ahb_hwrite) begin
                  seen_offsets[ahb_beats] = lsu_ahb_haddr[2:0];
                  seen_sizes[ahb_beats]   = lsu_ahb_hsize;
                  ahb_beats++;
               end
               @(posedge clk);
               timeout++;
            end
            if (!lsu_axi_bvalid) fail("Timeout waiting for lsu_axi_bvalid on aligned sub-dword write");
            if (ahb_beats != 1 || seen_offsets[0] !== exp_off[idx] || seen_sizes[0] !== exp_sz[idx]) begin
               $display("idx=%0d strb=%h beats=%0d off=%0d(exp %0d) sz=%0d(exp %0d)",
                        idx, sub_strbs[idx], ahb_beats, seen_offsets[0], exp_off[idx], seen_sizes[0], exp_sz[idx]);
               fail("Aligned 64-bit sub-word write decomposition mismatch in axi4_to_ahb");
            end
            @(posedge clk);
         end
      end

      // 1B: Unaligned/sparse 64-bit write byte walking (wstrb = 8'b0001_0101 = 8'h15 -> bytes 0, 2, 4 only!)
      begin
         @(negedge clk);
         lsu_axi_awvalid = 1'b1;
         lsu_axi_awid    = 4'h7;
         lsu_axi_awaddr  = 32'hc058_2000;
         lsu_axi_awsize  = 3'b011;
         lsu_axi_wvalid  = 1'b1;
         lsu_axi_wdata   = 64'h8877_6655_4433_2211;
         lsu_axi_wstrb   = 8'h15;
         ahb_beats = 0;
         #1;
         if (lsu_ahb_htrans == 2'b10 && lsu_ahb_hready && lsu_ahb_hwrite) begin
            seen_offsets[ahb_beats] = lsu_ahb_haddr[2:0];
            seen_sizes[ahb_beats]   = lsu_ahb_hsize;
            ahb_beats++;
         end
         @(posedge clk);
         @(negedge clk);
         lsu_axi_awvalid = 1'b0;
         lsu_axi_wvalid  = 1'b0;

         timeout = 0;
         while (!lsu_axi_bvalid && timeout < 40) begin
            #1;
            if (lsu_ahb_htrans == 2'b10 && lsu_ahb_hready && lsu_ahb_hwrite) begin
               seen_offsets[ahb_beats] = lsu_ahb_haddr[2:0];
               seen_sizes[ahb_beats]   = lsu_ahb_hsize;
               ahb_beats++;
            end
            @(posedge clk);
            timeout++;
         end
         if (!lsu_axi_bvalid) fail("Timeout waiting for sparse 64-bit write completion");
         if (ahb_beats != 3 || seen_offsets[0] !== 3'd0 || seen_offsets[1] !== 3'd2 || seen_offsets[2] !== 3'd4 ||
             seen_sizes[0] !== 3'd0 || seen_sizes[1] !== 3'd0 || seen_sizes[2] !== 3'd0) begin
            $display("Sparse write beats=%0d offsets=%0d,%0d,%0d sizes=%0d,%0d,%0d",
                     ahb_beats, seen_offsets[0], seen_offsets[1], seen_offsets[2], seen_sizes[0], seen_sizes[1], seen_sizes[1]);
            fail("Sparse 64-bit write byte-walking mismatch in axi4_to_ahb");
         end
         @(posedge clk);
      end

      // 1C: Streaming read with AHB error on first beat & last_bus_addr replication on read error
      begin
         @(negedge clk);
         lsu_axi_awvalid = 1'b1;
         lsu_axi_awid    = 4'h2;
         lsu_axi_awaddr  = 32'hc058_3450;
         lsu_axi_awsize  = 3'b011;
         lsu_axi_wvalid  = 1'b1;
         lsu_axi_wdata   = 64'h1122_3344_5566_7788;
         lsu_axi_wstrb   = 8'hff;
         @(posedge clk);
         @(negedge clk);
         lsu_axi_awvalid = 1'b0;
         lsu_axi_wvalid  = 1'b0;
         while (!lsu_axi_bvalid) @(posedge clk);
         @(posedge clk);

         @(negedge clk);
         lsu_axi_arvalid = 1'b1;
         lsu_axi_arid    = 4'h9;
         lsu_axi_araddr  = 32'hc058_4000;
         lsu_axi_arsize  = 3'b011;
         @(posedge clk); // IDLE -> CMD_RD (accepted beat 1, ahb_htrans=10 on bus)
         @(negedge clk);
         lsu_axi_arid    = 4'ha;
         lsu_axi_araddr  = 32'hc058_4008;
         lsu_ahb_hresp   = 1'b1; // AHB slave signals error on beat 1 data phase
         @(posedge clk); // CMD_RD -> STREAM_RD (accepted beat 2; hresp_q latches 1)
         @(negedge clk);
         lsu_axi_arvalid = 1'b0;
         lsu_ahb_hresp   = 1'b0;
         lsu_ahb_hrdata  = 64'h9999_8888_7777_6666;
         @(posedge clk); // STREAM_RD -> STREAM_ERR_RD (slvbuf_error latches 1; ahb_htrans=00 so STREAM_ERR_RD re-issues beat 2)
         @(posedge clk); // STREAM_ERR_RD cycle 2 (ahb_htrans_q=10, ahb_hready_q=1 -> slave_valid_pre=1)
         #1;
         if (!lsu_axi_rvalid || !lsu_axi_rresp[1] || lsu_axi_rid !== 4'h9 || lsu_axi_rdata !== {2{32'hc058_3450}}) begin
            $display("Stream err beat1: rvalid=%b rresp=%b rid=%h rdata=%h", lsu_axi_rvalid, lsu_axi_rresp, lsu_axi_rid, lsu_axi_rdata);
            fail("Streaming read error response or last_bus_addr rdata mismatch");
         end
         @(negedge clk);
         lsu_ahb_hrdata  = 64'hfeed_face_1234_5678;
         @(posedge clk); // STREAM_ERR_RD -> DATA_RD
         @(posedge clk); // DATA_RD -> DONE
         #1;
         if (!lsu_axi_rvalid || lsu_axi_rresp !== 2'b00 || lsu_axi_rid !== 4'ha || lsu_axi_rdata !== 64'hfeed_face_1234_5678) begin
            $display("Stream beat2: rvalid=%b rresp=%b rid=%h rdata=%h", lsu_axi_rvalid, lsu_axi_rresp, lsu_axi_rid, lsu_axi_rdata);
            fail("Second beat after STREAM_ERR_RD failed");
         end
         @(posedge clk);
      end

      // =========================================================================
      // Phase 2: DMA AHB-Lite-to-AXI4 Slave Gasket (ahb_to_axi4) & DMA Controller (dma_ctrl)
      // 2A: Two-cycle AHB error protocol for out-of-range, unaligned word/dword, and bad size
      // =========================================================================
      begin
         automatic logic [31:0] bad_addrs [0:3] = '{32'h1000_0000, 32'hf004_0012, 32'hf004_0014, 32'hee00_0010};
         automatic logic [2:0]  bad_sizes [0:3] = '{3'h2,          3'h2,          3'h3,          3'h1};
         automatic logic        bad_wr    [0:3] = '{1'b0,          1'b1,          1'b1,          1'b0};

         for (int b = 0; b < 4; b++) begin
            @(negedge clk);
            dma_ahb_hsel     = 1'b1;
            dma_ahb_htrans   = 2'b10;
            dma_ahb_haddr    = bad_addrs[b];
            dma_ahb_hsize    = bad_sizes[b];
            dma_ahb_hwrite   = bad_wr[b];
            dma_ahb_hreadyin = 1'b1;
            @(posedge clk);
            @(negedge clk);
            dma_ahb_hsel     = 1'b0;
            dma_ahb_htrans   = 2'b00;
            dma_ahb_hwdata   = 64'hdead_beef_0000_0000;
            #1;
            if (dma_ahb_hresp !== 1'b1 || dma_ahb_hreadyout !== 1'b0) begin
               $display("case %0d cycle 1: hresp=%b hreadyout=%b", b, dma_ahb_hresp, dma_ahb_hreadyout);
               fail("AHB error cycle 1 must have hresp=1 and hreadyout=0");
            end
            dma_ahb_hreadyin = dma_ahb_hreadyout;
            @(posedge clk);
            #1;
            if (dma_ahb_hresp !== 1'b1 || dma_ahb_hreadyout !== 1'b1) begin
               $display("case %0d cycle 2: hresp=%b hreadyout=%b", b, dma_ahb_hresp, dma_ahb_hreadyout);
               fail("AHB error cycle 2 must have hresp=1 and hreadyout=1");
            end
            dma_ahb_hreadyin = dma_ahb_hreadyout;
            @(posedge clk);
            #1;
            if (dma_ahb_hresp !== 1'b0 || dma_ahb_hreadyout !== 1'b1)
               fail("AHB error did not clear after cycle 2");
         end
      end

      // 2B: Valid AHB 32-bit write to upper word of 64-bit DCCM address (addr[2]=1, wstrb=8'hf0 normalization)
      begin
         int prev_seen = dccm_req_seen;
         @(negedge clk);
         dma_ahb_hsel     = 1'b1;
         dma_ahb_htrans   = 2'b10;
         dma_ahb_haddr    = 32'hf004_0104;
         dma_ahb_hsize    = 3'h2;
         dma_ahb_hwrite   = 1'b1;
         dma_ahb_hreadyin = 1'b1;
         @(posedge clk);
         @(negedge clk);
         dma_ahb_hsel     = 1'b0;
         dma_ahb_htrans   = 2'b00;
         dma_ahb_hwdata   = 64'hfeed_babe_1234_5678;

         timeout = 0;
         while (dccm_req_seen == prev_seen && timeout < 30) begin
            @(posedge clk);
            timeout++;
         end
         if (dccm_req_seen == prev_seen) fail("DMA DCCM write request never issued");
         @(posedge clk);
         if (mem_dccm_last_addr !== 32'hf004_0104 || mem_dccm_last_sz !== 3'h2) begin
            $display("DMA write addr=%h sz=%0d", mem_dccm_last_addr, mem_dccm_last_sz);
            fail("DMA 8'hf0 upper-word write address/size normalization failed");
         end
         repeat (4) @(posedge clk);
      end

      // 2C: DMA Read with Core ECC error -> 2-cycle AHB error response, followed by clean read
      begin
         inject_dccm_ecc_err = 1'b1;
         @(negedge clk);
         dma_ahb_hsel     = 1'b1;
         dma_ahb_htrans   = 2'b10;
         dma_ahb_haddr    = 32'hf004_0200;
         dma_ahb_hsize    = 3'h3;
         dma_ahb_hwrite   = 1'b0;
         dma_ahb_hreadyin = 1'b1;
         @(posedge clk);
         @(negedge clk);
         dma_ahb_hsel     = 1'b0;
         dma_ahb_htrans   = 2'b00;

         timeout = 0;
         while (!dma_ahb_hresp && timeout < 40) begin
            dma_ahb_hreadyin = dma_ahb_hreadyout;
            @(posedge clk);
            #1;
            timeout++;
         end
         if (!dma_ahb_hresp || dma_ahb_hreadyout !== 1'b0)
            fail("DMA read ECC error did not trigger cycle-1 AHB error (hresp=1, hreadyout=0)");
         dma_ahb_hreadyin = dma_ahb_hreadyout;
         @(posedge clk);
         #1;
         if (dma_ahb_hresp !== 1'b1 || dma_ahb_hreadyout !== 1'b1)
            fail("DMA read ECC error did not trigger cycle-2 AHB error (hresp=1, hreadyout=1)");
         dma_ahb_hreadyin = dma_ahb_hreadyout;
         inject_dccm_ecc_err = 1'b0;
         @(posedge clk);
      end

      // 2D: QoS NACK counter & stall hold test
      begin
         dccm_ready = 1'b0;
         dec_tlu_dma_qos_prty = 3'd3;
         @(negedge clk);
         dma_ahb_hsel     = 1'b1;
         dma_ahb_htrans   = 2'b10;
         dma_ahb_haddr    = 32'hf004_0300;
         dma_ahb_hsize    = 3'h3;
         dma_ahb_hwrite   = 1'b0;
         dma_ahb_hreadyin = 1'b1;
         @(posedge clk);
         @(negedge clk);
         dma_ahb_hsel     = 1'b0;
         dma_ahb_htrans   = 2'b00;

         timeout = 0;
         while (!dma_dccm_stall_any && timeout < 30) begin
            dma_ahb_hreadyin = dma_ahb_hreadyout;
            @(posedge clk);
            #1;
            timeout++;
         end
         if (!dma_dccm_stall_any) fail("dma_dccm_stall_any never asserted when dccm_ready=0");
         for (int hold_c = 0; hold_c < 2; hold_c++) begin
            @(posedge clk);
            #1;
            if (!dma_dccm_stall_any) fail("dma_dccm_stall_any dropped prematurely while dccm_ready=0");
         end
         dccm_ready = 1'b1;
         while (!dma_ahb_hreadyout) begin
            dma_ahb_hreadyin = dma_ahb_hreadyout;
            @(posedge clk);
            #1;
         end
         dma_ahb_hreadyin = 1'b1;
         if (dma_ahb_hrdata !== {32'hf004_0300 ^ 32'hCAFE_0000, 32'hf004_0300 ^ 32'hBEEF_0000})
            fail("DMA read data mismatch after stall release");
         @(posedge clk);
      end

      // 2E: Abstract Debug Memory Read (upper word addr[2]=1 halfword extraction)
      begin
         repeat (4) @(posedge clk);
         @(negedge clk);
         dbg_dma_bubble = 1'b1;
         while (!dma_dbg_ready) @(posedge clk);
         @(negedge clk);
         dbg_cmd_valid  = 1'b1;
         dbg_cmd_write  = 1'b0;
         dbg_cmd_type   = 2'b10;
         dbg_cmd_size   = 2'b01; // halfword
         dbg_cmd_addr   = 32'hf004_0406; // upper 32-bit word (bit 2 = 1), upper halfword (bit 1 = 1)
         @(posedge clk);
         @(negedge clk);
         dbg_cmd_valid  = 1'b0;
         dbg_dma_bubble = 1'b0;

         timeout = 0;
         while (!dma_dbg_cmd_done && timeout < 30) begin
            @(posedge clk);
            #1;
            timeout++;
         end
         if (!dma_dbg_cmd_done || dma_dbg_cmd_fail)
            fail("Debug memory read command failed");
         if (dma_dbg_rddata !== ({16'h0, (32'hf004_0406 ^ 32'hCAFE_0000) >> 16})) begin
            $display("dbg_rddata=%h exp=%h", dma_dbg_rddata, ({16'h0, (32'hf004_0406 ^ 32'hCAFE_0000) >> 16}));
            fail("Debug upper-word halfword read extraction mismatch");
         end
         @(posedge clk);
      end

      // 2F: Direct AXI4 DMA ingress (ext_dma_axi_sel=1):
      //     (1) Unaligned write byte strobe (size=3'h3, wstrb=8'h3f) -> DECERR (2'b11) and dma_slv_algn_err=1
      //     (2) Simultaneous wrbuf & rdbuf occupancy -> alternating priority (one write, one read)
      begin
         repeat (3) @(posedge clk);
         @(negedge clk);
         ext_dma_axi_sel     = 1'b1;
         ext_dma_axi_awvalid = 1'b1;
         ext_dma_axi_awid    = 1'b1;
         ext_dma_axi_awaddr  = 32'hf004_0500;
         ext_dma_axi_awsize  = 3'h3;
         ext_dma_axi_wvalid  = 1'b1;
         ext_dma_axi_wdata   = 64'hdead_beef_cafe_babe;
         ext_dma_axi_wstrb   = 8'h3f; // illegal strobe for 8B write!
         @(posedge clk);
         @(negedge clk);
         ext_dma_axi_awvalid = 1'b0;
         ext_dma_axi_wvalid  = 1'b0;

         timeout = 0;
         while (!ext_dma_axi_bvalid && timeout < 30) begin
            @(posedge clk);
            #1;
            timeout++;
         end
         if (!ext_dma_axi_bvalid || ext_dma_axi_bresp !== 2'b10 || !dma_slv_algn_err) begin
            $display("bvalid=%b bresp=%b algn_err=%b", ext_dma_axi_bvalid, ext_dma_axi_bresp, dma_slv_algn_err);
            fail("Illegal 8B wstrb did not return SLVERR (2'b10) with dma_slv_algn_err=1");
         end
         @(posedge clk);

         // Now test alternating priority when both wrbuf and rdbuf are valid simultaneously:
         // Drive continuous back-to-back AXI writes and reads over 4 cycles:
         req_hist_cnt = 0;
         @(negedge clk);
         ext_dma_axi_awvalid = 1'b1;
         ext_dma_axi_awaddr  = 32'hf004_0600;
         ext_dma_axi_awsize  = 3'h3;
         ext_dma_axi_wvalid  = 1'b1;
         ext_dma_axi_wdata   = 64'h1234_5678_9abc_def0;
         ext_dma_axi_wstrb   = 8'hff;
         ext_dma_axi_arvalid = 1'b1;
         ext_dma_axi_araddr  = 32'hf004_0608;
         ext_dma_axi_arsize  = 3'h3;
         repeat (4) @(posedge clk);
         @(negedge clk);
         ext_dma_axi_awvalid = 1'b0;
         ext_dma_axi_wvalid  = 1'b0;
         ext_dma_axi_arvalid = 1'b0;

         timeout = 0;
         while (req_hist_cnt < 3 && timeout < 30) begin
            @(posedge clk);
            #1;
            timeout++;
         end
         if (req_hist_cnt < 3 || (req_is_write_hist[2:0] === 3'b111) || (req_is_write_hist[2:0] === 3'b000)) begin
            $display("req_is_write_hist=%b", req_is_write_hist[3:0]);
            fail("DMA wrbuf/rdbuf priority did not alternate under continuous simultaneous demand");
         end
         repeat (6) @(posedge clk);
      end

      $display("PASS veer_bus_dma_top seed=%0d", SEED);
      $finish(0);
   end

endmodule
