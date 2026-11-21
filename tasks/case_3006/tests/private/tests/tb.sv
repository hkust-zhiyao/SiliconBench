`timescale 1ns/1ps

module tb;
  logic        clk_i = 1'b0;
  logic        rst_ni = 1'b0;
  logic        flush_i = 1'b0;

  logic        data_req_o;
  logic        data_gnt_i = 1'b0;
  logic        data_rvalid_i = 1'b0;
  logic        data_err_i = 1'b0;
  logic        data_err_pmp_i = 1'b0;

  logic [31:0] data_addr_o;
  logic        data_we_o;
  logic [ 3:0] data_be_o;
  logic [31:0] data_wdata_o;
  logic [31:0] data_rdata_i = '0;

  logic        data_we_ex_i = 1'b0;
  logic [ 1:0] data_type_ex_i = '0;
  logic [31:0] data_wdata_ex_i = '0;
  logic [ 1:0] data_reg_offset_ex_i = '0;
  logic        data_load_event_ex_i = 1'b0;
  logic [ 1:0] data_sign_ext_ex_i = '0;

  logic [31:0] data_rdata_ex_o;
  logic        data_req_ex_i = 1'b0;
  logic [31:0] operand_a_ex_i = '0;
  logic [31:0] operand_b_ex_i = '0;
  logic        addr_useincr_ex_i = 1'b0;

  logic        data_misaligned_ex_i = 1'b0;
  logic        data_misaligned_o;

  logic [ 5:0] data_atop_ex_i = '0;
  logic [ 5:0] data_atop_o;

  logic        load_err_o;
  logic        store_err_o;

  logic        p_elw_start_o;
  logic        p_elw_finish_o;

  logic        lsu_ready_ex_o;
  logic        lsu_ready_wb_o;
  logic        busy_o;

  logic [ 7:0] mpu_region_in = '0;
  logic [ 7:0] mpu_region_out;
  logic [ 7:0] hart_dbg_in = '0;
  logic [ 7:0] hart_dbg_out;

  top dut (.*);

  always #5 clk_i = ~clk_i;

  task automatic fail(input string msg);
    $display("TB_FAIL: %s at t=%0t", msg, $time);
    $finish(1);
  endtask

  task automatic step();
    @(posedge clk_i);
    #1;
  endtask

  int seed = 1;

  initial begin
    if (!$value$plusargs("SEED=%d", seed)) seed = 1;
    rst_ni = 1'b0;
    repeat (3) step();
    if (data_req_o !== 1'b0 || busy_o !== 1'b0 || load_err_o !== 1'b0 || store_err_o !== 1'b0)
      fail("Reset state mismatch");
    rst_ni = 1'b1;
    step();

    // -----------------------------------------------------------------------
    // Phase 1: OBI REGISTERED stability when data_gnt_i=0 & cv.elw start/finish
    // -----------------------------------------------------------------------
    data_req_ex_i        = 1'b1;
    data_we_ex_i         = 1'b0;
    data_type_ex_i       = 2'b00;
    operand_a_ex_i       = 32'h1000_0040;
    operand_b_ex_i       = 32'h0000_0008;
    addr_useincr_ex_i    = 1'b1;
    data_load_event_ex_i = 1'b1;
    data_atop_ex_i       = 6'h15;
    data_gnt_i           = 1'b0;
    #1;
    if (data_req_o !== 1'b1 || data_addr_o !== 32'h1000_0048 || lsu_ready_ex_o !== 1'b1 || p_elw_start_o !== 1'b1)
      fail("Initial cv.elw request/start mismatch");
    step();

    // Now data_obi_i is in REGISTERED state (since data_gnt_i was 0). Change EX inputs!
    data_req_ex_i        = 1'b0;
    data_load_event_ex_i = 1'b0;
    operand_a_ex_i       = 32'hDEAD_BEE0;
    data_type_ex_i       = 2'b10;
    data_wdata_ex_i      = 32'hCAFE_BABE;
    data_we_ex_i         = 1'b1;
    data_atop_ex_i       = 6'h2A;
    #1;
    if (data_req_o !== 1'b1 || data_addr_o !== 32'h1000_0048 || data_we_o !== 1'b0 ||
        data_be_o !== 4'b1111 || data_atop_o !== 6'h15)
      fail("OBI REGISTERED state failed to hold address/we/be/atop stable while ungranted");
    if (p_elw_start_o !== 1'b0)
      fail("p_elw_start_o must only pulse when EX request is accepted into OBI");

    // Grant the held OBI request
    data_gnt_i = 1'b1;
    step();
    data_gnt_i = 1'b0;

    // Return rvalid with data 0xCAFE_1234
    data_rvalid_i = 1'b1;
    data_rdata_i  = 32'hCAFE_1234;
    data_err_i    = 1'b0;
    #1;
    if (data_rdata_ex_o !== 32'hCAFE_1234 || p_elw_finish_o !== 1'b1 || load_err_o !== 1'b0)
      fail("cv.elw load completion or rdata mismatch");
    step();
    data_rvalid_i = 1'b0;

    // -----------------------------------------------------------------------
    // Phase 2: Bus error on load/store & rdata_q preservation on faulted load
    // -----------------------------------------------------------------------
    data_req_ex_i     = 1'b1;
    data_we_ex_i      = 1'b0;
    operand_a_ex_i    = 32'h2000_0000;
    addr_useincr_ex_i = 1'b0;
    data_gnt_i        = 1'b1;
    step();
    data_req_ex_i = 1'b0;
    data_gnt_i    = 1'b0;

    // Return bus error on load: load_err_o=1, and rdata_q must remain 0xCAFE_1234!
    data_rvalid_i = 1'b1;
    data_rdata_i  = 32'hBAD0_BAD0;
    data_err_i    = 1'b1;
    #1;
    if (load_err_o !== 1'b1 || store_err_o !== 1'b0)
      fail("Expected load_err_o=1 on OBI read bus error");
    step();
    data_rvalid_i = 1'b0;
    data_err_i    = 1'b0;
    #1;
    if (data_rdata_ex_o !== 32'hCAFE_1234)
      fail($sformatf("Faulted load corrupted held rdata_q: got %h exp CAFE1234", data_rdata_ex_o));

    // -----------------------------------------------------------------------
    // Phase 3: Split-misaligned PMP error on first half suppresses second half
    // -----------------------------------------------------------------------
    data_req_ex_i        = 1'b1;
    data_we_ex_i         = 1'b1;
    data_type_ex_i       = 2'b00;
    operand_a_ex_i       = 32'h3000_0002; // misaligned word
    data_wdata_ex_i      = 32'h1122_3344;
    data_misaligned_ex_i = 1'b0;
    data_err_pmp_i       = 1'b1;
    data_gnt_i           = 1'b1;
    #1;
    if (data_misaligned_o !== 1'b1 || store_err_o !== 1'b1 || lsu_ready_ex_o !== 1'b1)
      fail("First half of misaligned store with PMP fault must assert data_misaligned_o, store_err_o, and lsu_ready_ex_o");
    step();

    // Pipeline presents second half (data_misaligned_ex_i = 1): must NOT issue OBI request!
    data_err_pmp_i       = 1'b0;
    data_misaligned_ex_i = 1'b1;
    operand_a_ex_i       = 32'h3000_0006;
    #1;
    if (data_req_o !== 1'b0 || lsu_ready_ex_o !== 1'b1)
      fail("Second half of PMP-faulted misaligned transfer must suppress data_req_o while asserting lsu_ready_ex_o");
    step();
    data_req_ex_i        = 1'b0;
    data_misaligned_ex_i = 1'b0;
    data_we_ex_i         = 1'b0;
    data_gnt_i           = 1'b0;

    // -----------------------------------------------------------------------
    // Phase 4: Synchronous flush_i draining of in-flight OBI response
    // -----------------------------------------------------------------------
    // Check flush_i=1 forces lsu_ready_ex_o=0 even when data_req_ex_i=0
    flush_i       = 1'b1;
    data_req_ex_i = 1'b0;
    #1;
    if (data_req_o !== 1'b0 || lsu_ready_ex_o !== 1'b0)
      fail("flush_i must immediately force lsu_ready_ex_o=0 and data_req_o=0");
    flush_i = 1'b0;
    step();

    // Issue a store to 0x4000_0000, granted
    data_req_ex_i  = 1'b1;
    data_we_ex_i   = 1'b1;
    operand_a_ex_i = 32'h4000_0000;
    data_gnt_i     = 1'b1;
    step();
    data_we_ex_i   = 1'b0;

    // Assert flush_i while transaction is in flight and another request is attempted
    flush_i        = 1'b1;
    data_req_ex_i  = 1'b1;
    operand_a_ex_i = 32'h4000_0004;
    #1;
    if (data_req_o !== 1'b0 || lsu_ready_ex_o !== 1'b0)
      fail("flush_i must immediately block data_req_o and lsu_ready_ex_o");
    step();
    flush_i       = 1'b0;
    data_req_ex_i = 1'b0;
    data_gnt_i    = 1'b0;

    // Issue a post-flush halfword load to 0x4000_000A (offset 2'b10, zero-extended)
    // while the flushed transaction is still in flight. Allow either immediate pipelined
    // acceptance or conservative acceptance after the flushed response drains, provided
    // OBI request initiation (data_req_o) and EX acceptance (lsu_ready_ex_o) stay coherent.
    data_req_ex_i      = 1'b1;
    data_we_ex_i       = 1'b0;
    data_type_ex_i     = 2'b01;
    data_sign_ext_ex_i = 2'b00;
    operand_a_ex_i     = 32'h4000_000A;
    data_gnt_i         = 1'b1;
    #1;
    if (data_req_o !== lsu_ready_ex_o)
      fail("Post-flush OBI request initiation (data_req_o) and EX handshake (lsu_ready_ex_o) are inconsistent while flushed transaction is in flight");
    if (lsu_ready_ex_o === 1'b1) begin
      // Pipelined acceptance while flushed request is still in flight
      step();
      data_req_ex_i = 1'b0;
      data_gnt_i    = 1'b0;

      // First rvalid is for the flushed request (with error=1 and garbage data): must be ignored!
      data_rvalid_i = 1'b1;
      data_rdata_i  = 32'hDEAD_DEAD;
      data_err_i    = 1'b1;
      #1;
      if (load_err_o !== 1'b0 || store_err_o !== 1'b0 || lsu_ready_wb_o !== 1'b0)
        fail("Flushed in-flight response must not assert load_err_o, store_err_o, or lsu_ready_wb_o for post-flush load");
      step();
    end else begin
      // Conservative wait: drain flushed response first while EX holds request
      data_rvalid_i = 1'b1;
      data_rdata_i  = 32'hDEAD_DEAD;
      data_err_i    = 1'b1;
      #1;
      if (load_err_o !== 1'b0 || store_err_o !== 1'b0)
        fail("Flushed in-flight response must not assert load_err_o or store_err_o");
      if (lsu_ready_ex_o !== 1'b1) begin
        step();
        data_rvalid_i = 1'b0;
        data_err_i    = 1'b0;
        #1;
        if (data_req_o !== 1'b1 || lsu_ready_ex_o !== 1'b1)
          fail("Post-flush request was not accepted after flushed response drained");
      end
      step();
      data_req_ex_i = 1'b0;
      data_gnt_i    = 1'b0;
    end

    // Second rvalid is for the live post-flush halfword load (0x5566_7788 -> upper halfword 0x0000_5566)
    data_rvalid_i = 1'b1;
    data_rdata_i  = 32'h5566_7788;
    data_err_i    = 1'b0;
    #1;
    if (lsu_ready_wb_o !== 1'b1 || data_rdata_ex_o !== 32'h0000_5566 || load_err_o !== 1'b0)
      fail("Live post-flush load response failed");
    step();
    data_rvalid_i  = 1'b0;
    data_type_ex_i = 2'b00;
    if (busy_o !== 1'b0)
      fail("Expected busy_o=0 after all responses drained");

    for (int k = 0; k < 16; k++) begin
      mpu_region_in = 8'((seed * 23 + k * 41) & 8'hff);
      hart_dbg_in   = 8'((seed * 67 + k * 89) & 8'hff);
      #1;
      if (mpu_region_out !== mpu_region_in || hart_dbg_out !== hart_dbg_in)
        fail("Transparent channel mismatch");
    end

    $display("TB_PASS seed=%0d", seed);
    $finish(0);
  end
endmodule
