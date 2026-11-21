`timescale 1ns/1ps
/* verilator lint_off WIDTHEXPAND */
/* verilator lint_off WIDTHTRUNC */

module tb;
   logic        clk_i = 1'b0;
   always #5 clk_i = ~clk_i;

   int unsigned seed = 101;

   logic        rst_ni             = 1'b0;
   logic        bus_clk_en         = 1'b1;
   logic        dec_tlu_force_halt = 1'b0;

   logic        m_axi_awvalid = 1'b0;
   wire         m_axi_awready;
   logic [0:0]  m_axi_awid    = 1'b0;
   logic [31:0] m_axi_awaddr  = 32'h0;
   logic [2:0]  m_axi_awsize  = 3'b011;
   logic [2:0]  m_axi_awprot  = 3'b000;

   logic        m_axi_wvalid  = 1'b0;
   wire         m_axi_wready;
   logic [63:0] m_axi_wdata   = 64'h0;
   logic [7:0]  m_axi_wstrb   = 8'hff;
   logic        m_axi_wlast   = 1'b1;

   wire         m_axi_bvalid;
   logic        m_axi_bready  = 1'b1;
   wire  [1:0]  m_axi_bresp;
   wire  [0:0]  m_axi_bid;

   logic        m_axi_arvalid = 1'b0;
   wire         m_axi_arready;
   logic [0:0]  m_axi_arid    = 1'b0;
   logic [31:0] m_axi_araddr  = 32'h0;
   logic [2:0]  m_axi_arsize  = 3'b011;
   logic [2:0]  m_axi_arprot  = 3'b000;

   wire         m_axi_rvalid;
   logic        m_axi_rready  = 1'b1;
   wire  [0:0]  m_axi_rid;
   wire  [63:0] m_axi_rdata;
   wire  [1:0]  m_axi_rresp;
   wire         m_axi_rlast;

   wire         s_axi_awvalid;
   logic        s_axi_awready = 1'b1;
   wire  [0:0]  s_axi_awid;
   wire  [31:0] s_axi_awaddr;
   wire  [2:0]  s_axi_awsize;
   wire  [2:0]  s_axi_awprot;
   wire  [7:0]  s_axi_awlen;
   wire  [1:0]  s_axi_awburst;

   wire         s_axi_wvalid;
   logic        s_axi_wready  = 1'b1;
   wire  [63:0] s_axi_wdata;
   wire  [7:0]  s_axi_wstrb;
   wire         s_axi_wlast;

   logic        s_axi_bvalid  = 1'b0;
   wire         s_axi_bready;
   logic [1:0]  s_axi_bresp   = 2'b00;
   logic [0:0]  s_axi_bid     = 1'b0;

   wire         s_axi_arvalid;
   logic        s_axi_arready = 1'b1;
   wire  [0:0]  s_axi_arid;
   wire  [31:0] s_axi_araddr;
   wire  [2:0]  s_axi_arsize;
   wire  [2:0]  s_axi_arprot;
   wire  [7:0]  s_axi_arlen;
   wire  [1:0]  s_axi_arburst;

   logic        s_axi_rvalid  = 1'b0;
   wire         s_axi_rready;
   logic [0:0]  s_axi_rid     = 1'b0;
   logic [63:0] s_axi_rdata   = 64'h0;
   logic [1:0]  s_axi_rresp   = 2'b00;

   logic [7:0]  qos_in        = 8'h0;
   wire  [7:0]  qos_out;
   logic [7:0]  region_in     = 8'h0;
   wire  [7:0]  region_out;

   top u_top (.*);

   // Simple downstream memory & error responder for s_axi_*
   logic [63:0] mem [0:255];
   logic        inject_rresp_err = 1'b0;
   logic        pend_rd          = 1'b0;
   logic [31:0] pend_raddr       = 32'h0;

   always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
         s_axi_bvalid <= 1'b0;
         s_axi_bresp  <= 2'b00;
         s_axi_rvalid <= 1'b0;
         s_axi_rdata  <= 64'h0;
         s_axi_rresp  <= 2'b00;
         pend_rd      <= 1'b0;
         pend_raddr   <= 32'h0;
      end else begin
         if (s_axi_bvalid && s_axi_bready) begin
            s_axi_bvalid <= 1'b0;
         end
         if (s_axi_awvalid && s_axi_awready && s_axi_wvalid && s_axi_wready) begin
            logic [7:0] idx;
            idx = s_axi_awaddr[10:3];
            for (int b = 0; b < 8; b++) begin
               if (s_axi_wstrb[b]) mem[idx][b*8 +: 8] <= s_axi_wdata[b*8 +: 8];
            end
            s_axi_bvalid <= 1'b1;
            s_axi_bresp  <= 2'b00;
         end

         if (s_axi_rvalid && s_axi_rready) begin
            s_axi_rvalid <= 1'b0;
         end
         if (s_axi_arvalid && s_axi_arready) begin
            pend_rd    <= 1'b1;
            pend_raddr <= s_axi_araddr;
         end else if (pend_rd && bus_clk_en) begin
            pend_rd      <= 1'b0;
            s_axi_rvalid <= 1'b1;
            s_axi_rdata  <= mem[pend_raddr[10:3]];
            s_axi_rresp  <= inject_rresp_err ? 2'b10 : 2'b00;
         end
      end
   end

   // Protocol monitor: whenever u_top.ahb_hresp && u_top.ahb_hready on a bus_clk_en edge,
   // the preceding bus_clk_en edge must have had ahb_hresp == 1 && ahb_hready == 0!
   logic prev_hresp  = 1'b0;
   logic prev_hready = 1'b1;
   always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
         prev_hresp  <= 1'b0;
         prev_hready <= 1'b1;
      end else if (bus_clk_en) begin
         if (u_top.ahb_hresp && u_top.ahb_hready) begin
            if (!(prev_hresp && !prev_hready)) begin
               $display("TB_FAIL: AHB 2-cycle error protocol violated: hresp=1 hready=1 not preceded by hresp=1 hready=0");
               $finish(1);
            end
         end
         prev_hresp  <= u_top.ahb_hresp;
         prev_hready <= u_top.ahb_hready;
      end
   end

   task automatic do_axi_write(
      input logic [31:0] addr,
      input logic [2:0]  sz,
      input logic [63:0] data,
      input logic [7:0]  strb,
      output logic [1:0] bresp_out
   );
      int tries = 0;
      @(negedge clk_i);
      m_axi_awvalid = 1'b1;
      m_axi_awaddr  = addr;
      m_axi_awsize  = sz;
      m_axi_wvalid  = 1'b1;
      m_axi_wdata   = data;
      m_axi_wstrb   = strb;
      m_axi_wlast   = 1'b1;
      while (!(m_axi_awready && m_axi_wready)) begin
         @(posedge clk_i);
         @(negedge clk_i);
         tries++;
         if (tries > 200) begin
            $display("TB_FAIL: timeout waiting for m_axi_awready/wready");
            $finish(1);
         end
      end
      @(posedge clk_i);
      @(negedge clk_i);
      m_axi_awvalid = 1'b0;
      m_axi_wvalid  = 1'b0;

      tries = 0;
      while (!m_axi_bvalid) begin
         @(posedge clk_i);
         #1;
         tries++;
         if (tries > 200) begin
            $display("TB_FAIL: timeout waiting for m_axi_bvalid");
            $finish(1);
         end
      end
      bresp_out = m_axi_bresp;
      @(posedge clk_i);
   endtask

   task automatic do_axi_read(
      input  logic [31:0] addr,
      input  logic [2:0]  sz,
      output logic [63:0] rdata_out,
      output logic [1:0]  rresp_out
   );
      int tries = 0;
      @(negedge clk_i);
      m_axi_arvalid = 1'b1;
      m_axi_araddr  = addr;
      m_axi_arsize  = sz;
      while (!m_axi_arready) begin
         @(posedge clk_i);
         @(negedge clk_i);
         tries++;
         if (tries > 200) begin
            $display("TB_FAIL: timeout waiting for m_axi_arready");
            $finish(1);
         end
      end
      @(posedge clk_i);
      @(negedge clk_i);
      m_axi_arvalid = 1'b0;

      tries = 0;
      while (!m_axi_rvalid) begin
         @(posedge clk_i);
         #1;
         tries++;
         if (tries > 200) begin
            $display("TB_FAIL: timeout waiting for m_axi_rvalid");
            $finish(1);
         end
      end
      rdata_out = m_axi_rdata;
      rresp_out = m_axi_rresp;
      @(posedge clk_i);
   endtask

   initial begin
      logic [1:0]  bresp, rresp;
      logic [63:0] rdata;

      if (!$value$plusargs("SEED=%d", seed)) seed = 101;
      for (int i = 0; i < 256; i++) mem[i] = 64'h0;

      rst_ni = 1'b0;
      repeat (4) @(negedge clk_i);
      rst_ni = 1'b1;
      repeat (2) @(negedge clk_i);

      // -----------------------------------------------------------------------
      // Test 1: Transparent channels qos_in -> qos_out and region_in -> region_out
      // -----------------------------------------------------------------------
      for (int i = 0; i < 8; i++) begin
         @(negedge clk_i);
         qos_in    = 8'h13 * (i + 1);
         region_in = 8'h29 * (i + 1);
         #1;
         if (qos_out !== qos_in || region_out !== region_in) begin
            $display("TB_FAIL: transparent channel mismatch");
            $finish(1);
         end
      end

      // -----------------------------------------------------------------------
      // Test 2: DCCM (0xf004_0000) and ICCM (0xee00_0000) aligned & byte-masked writes/reads
      // -----------------------------------------------------------------------
      // 64-bit aligned write & read in DCCM
      do_axi_write(32'hf004_0010, 3'b011, 64'hdead_beef_cafe_babe, 8'hff, bresp);
      if (bresp !== 2'b00) begin
         $display("TB_FAIL: expected OKAY bresp on DCCM 64b write, got %b", bresp);
         $finish(1);
      end
      do_axi_read(32'hf004_0010, 3'b011, rdata, rresp);
      if (rresp !== 2'b00 || rdata !== 64'hdead_beef_cafe_babe) begin
         $display("TB_FAIL: DCCM 64b read mismatch got %h rresp=%b", rdata, rresp);
         $finish(1);
      end

      // Upper 32-bit word write (wstrb = 8'hf0) & read in DCCM
      do_axi_write(32'hf004_0010, 3'b011, 64'h1122_3344_5566_7788, 8'hf0, bresp);
      if (bresp !== 2'b00) begin
         $display("TB_FAIL: expected OKAY bresp on DCCM upper-word write, got %b", bresp);
         $finish(1);
      end
      do_axi_read(32'hf004_0010, 3'b011, rdata, rresp);
      if (rresp !== 2'b00 || rdata !== 64'h1122_3344_cafe_babe) begin
         $display("TB_FAIL: DCCM upper-word read mismatch got %h rresp=%b", rdata, rresp);
         $finish(1);
      end

      // ICCM (0xee00_0020) 32-bit word write (wstrb = 8'h0f) & read
      do_axi_write(32'hee00_0020, 3'b011, 64'h0000_0000_a5a5_5a5a, 8'h0f, bresp);
      if (bresp !== 2'b00) begin
         $display("TB_FAIL: expected OKAY bresp on ICCM word write, got %b", bresp);
         $finish(1);
      end
      do_axi_read(32'hee00_0020, 3'b010, rdata, rresp);
      if (rresp !== 2'b00 || rdata[31:0] !== 32'ha5a5_5a5a) begin
         $display("TB_FAIL: ICCM word read mismatch got %h rresp=%b", rdata, rresp);
         $finish(1);
      end

      // -----------------------------------------------------------------------
      // Test 3: Address/Size error detection in ahb_to_axi4 -> 2-cycle AHB HRESP
      // -> SLVERR (2'b10) propagated back by axi4_to_ahb!
      // -----------------------------------------------------------------------
      // 3a: Out-of-range read (0x1000_0000 is outside DCCM and ICCM) -> must return rresp = 2'b10
      // and must NOT issue s_axi_arvalid!
      do_axi_read(32'h1000_0000, 3'b011, rdata, rresp);
      if (rresp !== 2'b10) begin
         $display("TB_FAIL: expected SLVERR (2'b10) on out-of-range read, got %b", rresp);
         $finish(1);
      end

      // 3b: Sub-word write to DCCM (16-bit write wstrb=8'h03) -> illegal size for DCCM write -> bresp = 2'b10!
      do_axi_write(32'hf004_0010, 3'b011, 64'hffff_ffff_ffff_ffff, 8'h03, bresp);
      if (bresp !== 2'b10) begin
         $display("TB_FAIL: expected SLVERR (2'b10) on sub-word DCCM write, got %b", bresp);
         $finish(1);
      end

      // 3c: Downstream AXI read error (s_axi_rresp = 2'b10) -> ahb_to_axi4 buf_read_error -> 2-cycle HRESP -> m_axi_rresp = 2'b10!
      inject_rresp_err = 1'b1;
      do_axi_read(32'hf004_0010, 3'b011, rdata, rresp);
      inject_rresp_err = 1'b0;
      if (rresp !== 2'b10) begin
         $display("TB_FAIL: expected SLVERR (2'b10) on downstream s_axi_rresp error, got %b", rresp);
         $finish(1);
      end

      // -----------------------------------------------------------------------
      // Test 4: dec_tlu_force_halt cancellation across bus_clk_en = 0
      // -----------------------------------------------------------------------
      // First accept Write 1 (moves into active bridge command phase) and immediately accept
      // Write 2 into the write buffer while Write 1 is still active.
      // Then freeze bus_clk_en=0, pulse dec_tlu_force_halt=1 for 1 core cycle, and verify via
      // top-level AXI ports that on the next bus_clk_en==1 edge both the active transaction and
      // buffered write are cleared (m_axi_awready/wready/arready all return high, no spurious
      // m_axi_bvalid is emitted, and 0xf004_0018 remains 0).
      @(negedge clk_i);
      bus_clk_en    = 1'b1;
      m_axi_awvalid = 1'b1;
      m_axi_awaddr  = 32'hf004_0010;
      m_axi_awsize  = 3'b011;
      m_axi_wvalid  = 1'b1;
      m_axi_wdata   = 64'hbad1_bad1_bad1_bad1;
      m_axi_wstrb   = 8'hff;
      @(posedge clk_i); // Write 1 accepted into wrbuf
      @(negedge clk_i);
      m_axi_awaddr  = 32'hf004_0018;
      m_axi_wdata   = 64'hbad2_bad2_bad2_bad2;
      @(posedge clk_i); // Write 1 moves to active bridge command phase AND Write 2 is accepted into wrbuf!
      @(negedge clk_i);
      m_axi_awvalid = 1'b0;
      m_axi_wvalid  = 1'b0;
      bus_clk_en    = 1'b0; // freeze bus clock!
      #1;
      if (m_axi_awready !== 1'b0 || m_axi_wready !== 1'b0 || m_axi_arready !== 1'b0) begin
         $display("TB_FAIL: expected m_axi_awready/wready/arready all 0 while bridge busy before force_halt (got %b %b %b)",
                  m_axi_awready, m_axi_wready, m_axi_arready);
         $finish(1);
      end
      dec_tlu_force_halt = 1'b1; // pulse force_halt for 1 core cycle while bus_clk_en == 0!
      @(posedge clk_i);
      @(negedge clk_i);
      dec_tlu_force_halt = 1'b0;
      @(posedge clk_i);
      @(negedge clk_i);
      bus_clk_en = 1'b1; // re-enable bus clock for 1 cycle -> both active state and write buffer must clear on this posedge!
      @(posedge clk_i);
      #1;
      if (m_axi_awready !== 1'b1 || m_axi_wready !== 1'b1 || m_axi_arready !== 1'b1 || m_axi_bvalid !== 1'b0) begin
         $display("TB_FAIL: dec_tlu_force_halt did not return axi4_to_ahb to idle on first bus_clk_en edge (awready=%b wready=%b arready=%b bvalid=%b)",
                  m_axi_awready, m_axi_wready, m_axi_arready, m_axi_bvalid);
         $finish(1);
      end
      for (int c = 0; c < 5; c++) begin
         @(posedge clk_i);
         #1;
         if (m_axi_bvalid !== 1'b0) begin
            $display("TB_FAIL: unexpected m_axi_bvalid after force_halt cancellation");
            $finish(1);
         end
      end

      // Verify cancelled Write 2 (0xf004_0018) never modified memory and bridge is operational
      do_axi_read(32'hf004_0018, 3'b011, rdata, rresp);
      if (rresp !== 2'b00 || rdata !== 64'h0) begin
         $display("TB_FAIL: cancelled write modified 0xf004_0018: rresp=%b rdata=%h", rresp, rdata);
         $finish(1);
      end
      do_axi_write(32'hf004_0030, 3'b011, 64'h0123_4567_89ab_cdef, 8'hff, bresp);
      do_axi_read(32'hf004_0030, 3'b011, rdata, rresp);
      if (bresp !== 2'b00 || rresp !== 2'b00 || rdata !== 64'h0123_4567_89ab_cdef) begin
         $display("TB_FAIL: post-force_halt write/read failed bresp=%b rresp=%b rdata=%h", bresp, rresp, rdata);
         $finish(1);
      end

      // -----------------------------------------------------------------------
      // Test 5: Randomized DCCM/ICCM/error traffic under varying bus_clk_en
      // -----------------------------------------------------------------------
      for (int iter = 0; iter < 24; iter++) begin
         int unsigned rv = $urandom(seed + iter * 37);
         logic [31:0] addr;
         logic [63:0] wdat;
         addr = (rv[0] ? 32'hf004_0000 : 32'hee00_0000) + {24'h0, rv[7:3], 3'b000};
         wdat = {rv, ~rv};
         do_axi_write(addr, 3'b011, wdat, 8'hff, bresp);
         if (bresp !== 2'b00) begin
            $display("TB_FAIL: random write failed at iter=%0d addr=%h bresp=%b", iter, addr, bresp);
            $finish(1);
         end
         do_axi_read(addr, 3'b011, rdata, rresp);
         if (rresp !== 2'b00 || rdata !== wdat) begin
            $display("TB_FAIL: random read mismatch at iter=%0d addr=%h got=%h exp=%h rresp=%b",
                     iter, addr, rdata, wdat, rresp);
            $finish(1);
         end
      end

      $display("TB_PASS");
      $finish(0);
   end
endmodule
