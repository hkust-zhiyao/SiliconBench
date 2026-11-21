`timescale 1ns/1ps

module tb;
  import cv32e40p_pkg::*;

  logic        clk_i = 1'b0;
  logic        rst_ni = 1'b0;
  logic        scan_cg_en_i = 1'b0;
  logic        cluster_mode_i = 1'b0;

  logic        fetch_enable_i = 1'b0;
  logic        fetch_enable_o;
  logic        clk_gated_o;
  logic        core_sleep_o;

  logic        if_busy_i = 1'b0;
  logic        ctrl_busy_i = 1'b0;
  logic        lsu_busy_i = 1'b0;
  logic        apu_busy_i = 1'b0;

  logic        pulp_clock_en_i = 1'b0;
  logic        p_elw_start_i = 1'b0;
  logic        p_elw_finish_i = 1'b0;
  logic        debug_p_elw_no_sleep_i = 1'b0;
  logic        wake_from_ctrl_i = 1'b0;

  logic [31:0] irq_i = '0;
  logic        irq_sec_i = 1'b0;
  logic [31:0] mie_bypass_i = '0;
  logic [31:0] mip_o;
  logic        m_ie_i = 1'b0;
  logic        u_ie_i = 1'b0;
  logic [ 1:0] current_priv_lvl_i = PRIV_LVL_M;

  logic        irq_req_ctrl_o;
  logic        irq_sec_ctrl_o;
  logic [ 4:0] irq_id_ctrl_o;
  logic        irq_wu_ctrl_o;

  logic [ 7:0] clint_timer_in = '0;
  logic [ 7:0] clint_timer_out;
  logic [ 7:0] eu_event_in = '0;
  logic [ 7:0] eu_event_out;

  top dut (.*);

  always #5 clk_i = ~clk_i;

  int gated_edges = 0;
  always @(posedge clk_gated_o) begin
    gated_edges <= gated_edges + 1;
  end

  task automatic fail(input string msg);
    $display("TB_FAIL: %s at t=%0t", msg, $time);
    $finish(1);
  endtask

  task automatic step();
    @(posedge clk_i);
    #1;
  endtask

  int seed = 1;
  int edges_before;

  initial begin
    if (!$value$plusargs("SEED=%d", seed)) seed = 1;
    rst_ni = 1'b0;
    repeat (3) step();
    if (fetch_enable_o !== 1'b0 || core_sleep_o !== 1'b0 || mip_o !== 32'h0 ||
        irq_req_ctrl_o !== 1'b0 || irq_sec_ctrl_o !== 1'b0 || irq_id_ctrl_o !== 5'd0 ||
        irq_wu_ctrl_o !== 1'b0)
      fail("Reset output state mismatch");
    rst_ni = 1'b1;
    step();

    // -----------------------------------------------------------------------
    // Phase 1: Interrupt Controller IRQ_MASK wake-up, registered irq_sec, priority & idle ID
    // -----------------------------------------------------------------------
    // Reserved IRQ bits (outside IRQ_MASK = 32'hFFFF0888) must NOT trigger irq_wu_ctrl_o
    irq_i        = ~IRQ_MASK;
    mie_bypass_i = 32'hFFFF_FFFF;
    m_ie_i       = 1'b1;
    #1;
    if (irq_wu_ctrl_o !== 1'b0)
      fail("Reserved IRQ bits outside IRQ_MASK must not assert irq_wu_ctrl_o");
    step();
    if (mip_o !== 32'h0 || irq_req_ctrl_o !== 1'b0 || irq_id_ctrl_o !== 5'd0)
      fail("Reserved IRQ bits must not latch into mip_o or assert irq_req_ctrl_o / non-zero irq_id_ctrl_o");

    // Valid IRQ bit (e.g. MEI=11 and MSI=3 and custom 16)
    irq_i        = (32'h1 << 16) | (32'h1 << 11) | (32'h1 << 3) | (32'h1 << 7);
    mie_bypass_i = 32'hFFFF_FFFF;
    #1;
    if (irq_wu_ctrl_o !== 1'b1)
      fail("Valid enabled IRQ bit must combinational-assert irq_wu_ctrl_o");
    step();
    if (mip_o !== ((32'h1 << 16) | (32'h1 << 11) | (32'h1 << 3) | (32'h1 << 7)))
      fail("mip_o did not latch valid IRQ bits");
    if (irq_req_ctrl_o !== 1'b1 || irq_id_ctrl_o !== 5'd16)
      fail($sformatf("Expected priority irq_id=16, got req=%b id=%0d", irq_req_ctrl_o, irq_id_ctrl_o));

    // Check priority order when bit 16 is masked: MEI(11) > MSI(3) > MTI(7)
    mie_bypass_i = (32'h1 << 11) | (32'h1 << 3) | (32'h1 << 7);
    #1;
    if (irq_id_ctrl_o !== 5'd11)
      fail("Priority MEI(11) > MSI(3) failed");
    mie_bypass_i = (32'h1 << 3) | (32'h1 << 7);
    #1;
    if (irq_id_ctrl_o !== 5'd3)
      fail("Priority MSI(3) > MTI(7) failed");
    mie_bypass_i = (32'h1 << 7);
    #1;
    if (irq_id_ctrl_o !== 5'd7)
      fail("Priority MTI(7) failed");
    mie_bypass_i = 32'h0;
    #1;
    if (irq_req_ctrl_o !== 1'b0 || irq_id_ctrl_o !== 5'd0)
      fail("When mie_bypass_i=0, irq_req_ctrl_o and irq_id_ctrl_o must be 0");

    // Check PULP_SECURE U-mode qualification uses registered irq_sec_q (aligned with irq_sec_ctrl_o)
    current_priv_lvl_i = PRIV_LVL_U;
    u_ie_i             = 1'b0;
    m_ie_i             = 1'b1;
    mie_bypass_i       = (32'h1 << 11);
    irq_i              = (32'h1 << 11);
    irq_sec_i          = 1'b0;
    step();
    // Now irq_q[11]=1 and irq_sec_q=0 (irq_sec_ctrl_o=0).
    // Toggle unregistered irq_sec_i=1 BEFORE clock edge: irq_req_ctrl_o must still be 0 because irq_sec_ctrl_o is 0!
    irq_sec_i = 1'b1;
    #1;
    if (irq_sec_ctrl_o !== 1'b0 || irq_req_ctrl_o !== 1'b0)
      fail("Unregistered irq_sec_i=1 must not assert irq_req_ctrl_o while registered irq_sec_ctrl_o is 0");
    // After clock edge, irq_sec_q=1 (irq_sec_ctrl_o=1). Drop unregistered irq_sec_i=0: irq_req_ctrl_o must stay 1!
    step();
    irq_sec_i = 1'b0;
    #1;
    if (irq_sec_ctrl_o !== 1'b1 || irq_req_ctrl_o !== 1'b1)
      fail("Registered irq_sec_ctrl_o=1 must keep irq_req_ctrl_o=1 in PRIV_LVL_U even when irq_sec_i drops");

    // Clean up IRQ inputs
    irq_i              = 32'h0;
    mie_bypass_i       = 32'h0;
    current_priv_lvl_i = PRIV_LVL_M;
    step();

    // -----------------------------------------------------------------------
    // Phase 2: Standard WFI mode (cluster_mode_i = 0) sleep, wake, and debug override
    // -----------------------------------------------------------------------
    cluster_mode_i = 1'b0;
    if_busy_i      = 1'b1;
    fetch_enable_i = 1'b1;
    step();
    fetch_enable_i = 1'b0;
    if (fetch_enable_o !== 1'b1 || core_sleep_o !== 1'b0)
      fail("Expected fetch_enable_o=1 and core_sleep_o=0 when core is busy in WFI mode");

    // Enter WFI idle (all busy=0, no wake): on next cycle core_busy_q=0 -> core_sleep_o=1 and clock gated
    if_busy_i   = 1'b0;
    ctrl_busy_i = 1'b0;
    lsu_busy_i  = 1'b0;
    apu_busy_i  = 1'b0;
    step();
    if (core_sleep_o !== 1'b1)
      fail("Expected core_sleep_o=1 in WFI mode when all busy=0 and wake=0");
    edges_before = gated_edges;
    step();
    if (gated_edges != edges_before)
      fail("clk_gated_o must remain gated while sleeping in WFI mode");

    // debug_p_elw_no_sleep_i=1 in WFI mode must suppress sleep and enable clock
    debug_p_elw_no_sleep_i = 1'b1;
    #1;
    if (core_sleep_o !== 1'b0)
      fail("debug_p_elw_no_sleep_i=1 must deassert core_sleep_o in WFI mode");
    edges_before = gated_edges;
    step();
    if (gated_edges == edges_before)
      fail("debug_p_elw_no_sleep_i=1 must enable clk_gated_o in WFI mode");
    debug_p_elw_no_sleep_i = 1'b0;
    #1;
    if (core_sleep_o !== 1'b1)
      fail("core_sleep_o must reassert when debug_p_elw_no_sleep_i drops and core is still idle");

    // Wake via valid IRQ wake-up (irq_wu_ctrl_o)
    irq_i        = (32'h1 << 7);
    mie_bypass_i = (32'h1 << 7);
    #1;
    if (irq_wu_ctrl_o !== 1'b1 || core_sleep_o !== 1'b0)
      fail("irq_wu_ctrl_o=1 must immediately deassert core_sleep_o in WFI mode");
    edges_before = gated_edges;
    step();
    if (gated_edges == edges_before)
      fail("irq_wu_ctrl_o=1 must enable clk_gated_o to clock the core");
    irq_i        = 32'h0;
    mie_bypass_i = 32'h0;
    step();

    // -----------------------------------------------------------------------
    // Phase 3: Cluster mode (cluster_mode_i = 1) p.elw lifecycle, lsu_busy_i, and finish priority
    // -----------------------------------------------------------------------
    cluster_mode_i  = 1'b1;
    pulp_clock_en_i = 1'b0;
    step();
    // When no p.elw is active in cluster mode, core_busy_d=1 so after 1 cycle core_busy_q=1 and core_sleep_o=0
    step();
    if (core_sleep_o !== 1'b0)
      fail("Expected core_sleep_o=0 in cluster mode when p.elw is not active");

    // Start p.elw while lsu_busy_i=1: lsu_busy_i must keep core_busy_q=1 on the next cycle so core_sleep_o stays 0!
    p_elw_start_i = 1'b1;
    lsu_busy_i    = 1'b1;
    step();
    p_elw_start_i = 1'b0;
    if (core_sleep_o !== 1'b0)
      fail("lsu_busy_i=1 during p.elw must keep core_busy_q=1 and prevent core_sleep_o from asserting early");

    // Now lsu_busy_i drops while p.elw is still active -> next cycle core_busy_q=0 -> core_sleep_o=1!
    lsu_busy_i = 1'b0;
    step();
    if (core_sleep_o !== 1'b1)
      fail("Expected core_sleep_o=1 in cluster mode once if/lsu/apu_busy drop during active p.elw");
    edges_before = gated_edges;
    step();
    if (gated_edges != edges_before)
      fail("clk_gated_o must be gated during cluster p.elw sleep when pulp_clock_en_i=0 and wake=0");

    // Wake signal in cluster p.elw sleep must immediately deassert core_sleep_o and enable clk_gated_o
    wake_from_ctrl_i = 1'b1;
    #1;
    if (core_sleep_o !== 1'b0)
      fail("wake_from_ctrl_i=1 must deassert core_sleep_o during cluster p.elw sleep");
    edges_before = gated_edges;
    step();
    if (gated_edges == edges_before)
      fail("wake_from_ctrl_i=1 must enable clk_gated_o during cluster p.elw sleep");
    wake_from_ctrl_i = 1'b0;

    // Finish p.elw (even if p_elw_start_i is simultaneously high, p_elw_finish_i must win)
    p_elw_start_i  = 1'b1;
    p_elw_finish_i = 1'b1;
    #1;
    if (core_sleep_o !== 1'b0)
      fail("p_elw_finish_i=1 must immediately clear p_elw_busy_d and core_sleep_o even if p_elw_start_i=1");
    step();
    p_elw_start_i  = 1'b0;
    p_elw_finish_i = 1'b0;
    step();
    if (core_sleep_o !== 1'b0)
      fail("core_sleep_o must remain 0 after p.elw finishes");

    // Transparent channels check
    for (int k = 0; k < 16; k++) begin
      clint_timer_in = 8'((seed * 23 + k * 41) & 8'hff);
      eu_event_in    = 8'((seed * 61 + k * 83) & 8'hff);
      #1;
      if (clint_timer_out !== clint_timer_in || eu_event_out !== eu_event_in)
        fail("Transparent feedthrough channel mismatch");
    end

    $display("TB_PASS seed=%0d", seed);
    $finish(0);
  end
endmodule
