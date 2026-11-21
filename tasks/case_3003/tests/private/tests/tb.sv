`timescale 1ns/1ps
module tb;
  logic        clk_i = 1'b0;
  always #5 clk_i = ~clk_i;

  logic        rst_ni;
  logic        flush_i;
  logic [31:0] req_addr;
  logic        req_we;
  logic [ 3:0] req_be;
  logic [31:0] req_wdata;
  logic [ 5:0] req_atop;
  logic        req_valid;
  logic        req_ready;

  logic [31:0] resp_rdata;
  logic        resp_err;
  logic        resp_valid;
  logic        resp_ready;

  logic        obi_req;
  logic        obi_gnt;
  logic [31:0] obi_addr;
  logic        obi_we;
  logic [ 3:0] obi_be;
  logic [31:0] obi_wdata;
  logic [ 5:0] obi_atop;
  logic [31:0] obi_rdata;
  logic        obi_rvalid;
  logic        obi_err;

  logic [ 7:0] pmp_in;
  logic [ 7:0] pmp_out;
  logic [ 7:0] dbg_in;
  logic [ 7:0] dbg_out;

  top dut (
    .clk_i      ( clk_i      ),
    .rst_ni     ( rst_ni     ),
    .flush_i    ( flush_i    ),
    .req_addr   ( req_addr   ),
    .req_we     ( req_we     ),
    .req_be     ( req_be     ),
    .req_wdata  ( req_wdata  ),
    .req_atop   ( req_atop   ),
    .req_valid  ( req_valid  ),
    .req_ready  ( req_ready  ),
    .resp_rdata ( resp_rdata ),
    .resp_err   ( resp_err   ),
    .resp_valid ( resp_valid ),
    .resp_ready ( resp_ready ),
    .obi_req    ( obi_req    ),
    .obi_gnt    ( obi_gnt    ),
    .obi_addr   ( obi_addr   ),
    .obi_we     ( obi_we     ),
    .obi_be     ( obi_be     ),
    .obi_wdata  ( obi_wdata  ),
    .obi_atop   ( obi_atop   ),
    .obi_rdata  ( obi_rdata  ),
    .obi_rvalid ( obi_rvalid ),
    .obi_err    ( obi_err    ),
    .pmp_in     ( pmp_in     ),
    .pmp_out    ( pmp_out    ),
    .dbg_in     ( dbg_in     ),
    .dbg_out    ( dbg_out    )
  );

  // OBI protocol stability monitor
  logic        wait_gnt_q;
  logic [31:0] held_addr_q;
  logic        held_we_q;
  logic [ 3:0] held_be_q;
  logic [31:0] held_wdata_q;
  logic [ 5:0] held_atop_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      wait_gnt_q   <= 1'b0;
      held_addr_q  <= 32'h0;
      held_we_q    <= 1'b0;
      held_be_q    <= 4'h0;
      held_wdata_q <= 32'h0;
      held_atop_q  <= 6'h0;
    end else begin
      if (wait_gnt_q) begin
        if (!obi_req)
          $fatal(1, "TB_FAIL: obi_req retracted before grant");
        if (obi_addr !== held_addr_q || obi_we !== held_we_q || obi_be !== held_be_q ||
            obi_wdata !== held_wdata_q || obi_atop !== held_atop_q) begin
          $fatal(1, "TB_FAIL: OBI address-phase changed while waiting for grant (got addr=%h we=%b be=%h wdata=%h atop=%h, exp addr=%h we=%b be=%h wdata=%h atop=%h)",
                 obi_addr, obi_we, obi_be, obi_wdata, obi_atop,
                 held_addr_q, held_we_q, held_be_q, held_wdata_q, held_atop_q);
        end
      end
      wait_gnt_q <= obi_req && !obi_gnt;
      if (obi_req && !obi_gnt) begin
        held_addr_q  <= obi_addr;
        held_we_q    <= obi_we;
        held_be_q    <= obi_be;
        held_wdata_q <= obi_wdata;
        held_atop_q  <= obi_atop;
      end
    end
  end

  task automatic reset_dut();
    rst_ni     = 1'b0;
    flush_i    = 1'b0;
    req_addr   = 32'h0;
    req_we     = 1'b0;
    req_be     = 4'h0;
    req_wdata  = 32'h0;
    req_atop   = 6'h0;
    req_valid  = 1'b0;
    resp_ready = 1'b0;
    obi_gnt    = 1'b0;
    obi_rdata  = 32'h0;
    obi_rvalid = 1'b0;
    obi_err    = 1'b0;
    pmp_in     = 8'hA5;
    dbg_in     = 8'h5A;
    repeat (3) @(posedge clk_i);
    #1;
    rst_ni = 1'b1;
    #1;
  endtask

  task automatic step_clk();
    @(posedge clk_i);
    #1;
  endtask

  int seed = 101;
  int checks = 0;

  initial begin
    if (!$value$plusargs("SEED=%d", seed)) seed = 101;

    // -----------------------------------------------------------------------
    // Phase 1: OBI REGISTERED stability (we, be, atop, addr, wdata) & obi_err
    // -----------------------------------------------------------------------
    reset_dut();
    if (pmp_out !== 8'hA5 || dbg_out !== 8'h5A)
      $fatal(1, "TB_FAIL: transparent channels mismatch");

    req_valid = 1'b1;
    req_addr  = 32'h1000_2000;
    req_we    = 1'b1;
    req_be    = 4'b1010;
    req_wdata = 32'hCAFE_BABE;
    req_atop  = 6'b10_1101;
    obi_gnt   = 1'b0; // force REGISTERED state in cv32e40p_obi_interface
    #1;
    if (!req_ready || !obi_req || obi_addr !== 32'h1000_2000 || !obi_we || obi_be !== 4'b1010 || obi_atop !== 6'b10_1101)
      $fatal(1, "TB_FAIL: Phase 1 initial transparent OBI request mismatch");
    step_clk(); // Accepted by stream_to_mem & latched in OBI REGISTERED state

    // Now change upstream request inputs while OBI is still waiting for grant!
    req_valid = 1'b1;
    req_addr  = 32'hDEAD_BEEF;
    req_we    = 1'b0;
    req_be    = 4'b0101;
    req_wdata = 32'h1234_5678;
    req_atop  = 6'b01_0010;
    #1;
    if (req_ready)
      $fatal(1, "TB_FAIL: req_ready must be 0 while OBI is in REGISTERED state");
    if (!obi_req || obi_addr !== 32'h1000_2000 || obi_we !== 1'b1 || obi_be !== 4'b1010 ||
        obi_wdata !== 32'hCAFE_BABE || obi_atop !== 6'b10_1101) begin
      $fatal(1, "TB_FAIL: Phase 1 OBI REGISTERED state failed to hold addr/we/be/wdata/atop");
    end
    checks++;

    // Grant the registered OBI request
    obi_gnt   = 1'b1;
    req_valid = 1'b0;
    #1;
    step_clk();
    obi_gnt = 1'b0;

    // Return response with obi_err = 1
    obi_rvalid = 1'b1;
    obi_rdata  = 32'hFEED_FACE;
    obi_err    = 1'b1;
    resp_ready = 1'b1;
    #1;
    if (!resp_valid || resp_rdata !== 32'hFEED_FACE || resp_err !== 1'b1)
      $fatal(1, "TB_FAIL: Phase 1 fall-through response or resp_err mismatch (valid=%b rdata=%h err=%b)",
             resp_valid, resp_rdata, resp_err);
    step_clk();
    obi_rvalid = 1'b0;
    obi_err    = 1'b0;
    checks++;

    // -----------------------------------------------------------------------
    // Phase 2: Partial FIFO + In-flight Flush, Stale Drain, and New Requests
    // -----------------------------------------------------------------------
    reset_dut();
    // Issue 3 requests (R0, R1, R2) with obi_gnt=1, resp_ready=0
    obi_gnt    = 1'b1;
    resp_ready = 1'b0;
    for (int i = 0; i < 3; i++) begin
      req_valid = 1'b1;
      req_addr  = 32'h2000 + (i * 4);
      req_we    = 1'b0;
      req_be    = 4'hF;
      req_wdata = 32'h0;
      req_atop  = 6'h0;
      #1;
      if (!req_ready) $fatal(1, "TB_FAIL: P2 req_ready low on req %0d", i);
      step_clk();
    end
    req_valid = 1'b0;

    // Return R0 into i_resp_buf (buffered, since resp_ready=0)
    obi_rvalid = 1'b1;
    obi_rdata  = 32'hAAAA_0000;
    obi_err    = 1'b0;
    #1;
    step_clk();
    obi_rvalid = 1'b0;
    #1;
    // Now i_resp_buf has 1 item (R0), and 2 items (R1, R2) are in flight on OBI (total cnt_q = 3).
    if (!resp_valid || resp_rdata !== 32'hAAAA_0000)
      $fatal(1, "TB_FAIL: P2 expected buffered R0 at head");

    // Assert flush_i = 1 while R1 returns on the SAME cycle (obi_rvalid = 1)!
    // On this cycle:
    // - req_ready, mem_req_valid_o (obi_req), and resp_valid must all be 0!
    // - R0 in i_resp_buf is flushed!
    // - R1 arriving on obi_rvalid=1 is discarded immediately!
    // - Only R2 (1 item) remains in flight on OBI after this edge (cnt_q=1, drop_cnt_q=1)!
    flush_i    = 1'b1;
    req_valid  = 1'b1;
    req_addr   = 32'h9999_0000;
    obi_rvalid = 1'b1;
    obi_rdata  = 32'hAAAA_0001; // R1 returning on flush cycle
    resp_ready = 1'b1;
    #1;
    if (req_ready || obi_req || resp_valid) begin
      $fatal(1, "TB_FAIL: P2 flush_i failed to gate req_ready(%b), obi_req(%b), or resp_valid(%b)",
             req_ready, obi_req, resp_valid);
    end
    step_clk();
    flush_i    = 1'b0;
    req_valid  = 1'b0;
    obi_rvalid = 1'b0;
    #1;
    if (resp_valid)
      $fatal(1, "TB_FAIL: P2 resp_valid remained high after flush_i");
    checks++;

    // Now R2 is still in flight (drop_cnt_q == 1, cnt_q == 1).
    // Issue a NEW valid request N0 on the same cycle that stale R2 returns!
    req_valid  = 1'b1;
    req_addr   = 32'h3000_0000;
    obi_gnt    = 1'b1;
    obi_rvalid = 1'b1;
    obi_rdata  = 32'hAAAA_0002; // stale R2! Must be dropped, NOT delivered!
    resp_ready = 1'b1;
    #1;
    if (!req_ready)
      $fatal(1, "TB_FAIL: P2 expected req_ready=1 for N0");
    if (resp_valid)
      $fatal(1, "TB_FAIL: P2 stale R2 leaked to resp_valid on fall-through!");
    step_clk();
    req_valid  = 1'b0;
    obi_rvalid = 1'b0;
    #1;
    if (resp_valid)
      $fatal(1, "TB_FAIL: P2 stale R2 was pushed into i_resp_buf!");
    checks++;

    // Now return the response for N0: must be delivered cleanly!
    obi_rvalid = 1'b1;
    obi_rdata  = 32'hBBBB_0000;
    obi_err    = 1'b0;
    resp_ready = 1'b0; // buffer N0 in i_resp_buf
    #1;
    step_clk();
    obi_rvalid = 1'b0;
    #1;
    if (!resp_valid || resp_rdata !== 32'hBBBB_0000)
      $fatal(1, "TB_FAIL: P2 valid response N0 was dropped or corrupted (valid=%b rdata=%h)",
             resp_valid, resp_rdata);
    resp_ready = 1'b1;
    step_clk();
    checks++;

    // -----------------------------------------------------------------------
    // Phase 3: Full FIFO (4 items buffered, 0 in flight) Flush & Full Capacity Recovery
    // -----------------------------------------------------------------------
    // Fill all 4 slots of i_resp_buf (issue 4 requests and return all 4 responses while resp_ready=0)
    resp_ready = 1'b0;
    obi_gnt    = 1'b1;
    for (int i = 0; i < 4; i++) begin
      req_valid  = 1'b1;
      req_addr   = 32'h4000 + (i * 4);
      obi_rvalid = 1'b1;
      obi_rdata  = 32'h4000_0000 + i;
      #1;
      if (!req_ready) $fatal(1, "TB_FAIL: P3 req_ready low at i=%0d", i);
      step_clk();
    end
    req_valid  = 1'b0;
    obi_rvalid = 1'b0;
    #1;
    // Now i_resp_buf is completely FULL (4 items: 0 in flight on OBI, cnt_q == 4).
    // Assert flush_i = 1!
    // If an implementation uses truncated 2-bit usage_o without checking full (!buf_ready),
    // it will miscalculate fifo_occupancy as 0 instead of 4, setting bus_inflight = 4 - 0 = 4!
    flush_i = 1'b1;
    #1;
    step_clk();
    flush_i = 1'b0;
    #1;

    // Now all 4 buffered items were flushed and 0 items are in flight on OBI!
    // Therefore, we MUST be able to issue 4 new requests immediately without any response returning,
    // AND the very next response returning from OBI MUST NOT be dropped!
    for (int i = 0; i < 4; i++) begin
      req_valid = 1'b1;
      req_addr  = 32'h5000 + (i * 4);
      obi_gnt   = 1'b1;
      #1;
      if (!req_ready)
        $fatal(1, "TB_FAIL: P3 capacity lost after full-FIFO flush at i=%0d (cnt_q not reset to 0)", i);
      step_clk();
    end
    req_valid = 1'b0;
    #1;
    if (req_ready)
      $fatal(1, "TB_FAIL: P3 req_ready should be 0 when 4 requests are in flight");

    // Return all 4 responses and verify none are dropped!
    resp_ready = 1'b1;
    for (int i = 0; i < 4; i++) begin
      obi_rvalid = 1'b1;
      obi_rdata  = 32'h5000_0000 + i;
      #1;
      if (!resp_valid || resp_rdata !== (32'h5000_0000 + i))
        $fatal(1, "TB_FAIL: P3 post-full-flush response %0d was dropped or corrupted", i);
      step_clk();
    end
    obi_rvalid = 1'b0;
    checks++;

    $display("TB_PASS seed=%0d checks=%0d", seed, checks);
    $finish;
  end
endmodule
