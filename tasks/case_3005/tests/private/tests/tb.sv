`timescale 1ns/1ps

module tb;
  logic        clk_i = 1'b0;
  logic        rst_ni = 1'b0;
  logic        flush_i = 1'b0;

  logic [31:0] hwlp_start_data = '0;
  logic [31:0] hwlp_end_data = '0;
  logic [31:0] hwlp_cnt_data = '0;
  logic [ 2:0] hwlp_we = '0;
  logic        hwlp_regid = 1'b0;
  logic        hwlp_valid = 1'b0;
  logic [ 1:0] hwlp_dec_cnt = '0;
  logic [31:0] hwlp_start_addr0;
  logic [31:0] hwlp_start_addr1;
  logic [31:0] hwlp_end_addr0;
  logic [31:0] hwlp_end_addr1;
  logic [31:0] hwlp_counter0;
  logic [31:0] hwlp_counter1;

  logic        apu_enable = 1'b0;
  logic [ 1:0] apu_lat = '0;
  logic [ 5:0] apu_waddr_in = '0;
  logic [ 5:0] apu_waddr_out;
  logic        apu_multicycle;
  logic        apu_singlecycle;
  logic        apu_rvalid_wb;
  logic        apu_active;
  logic        apu_stall;
  logic        is_decoding = 1'b1;
  logic [ 5:0] read_reg0 = '0;
  logic [ 5:0] read_reg1 = '0;
  logic [ 5:0] read_reg2 = '0;
  logic [ 2:0] read_regs_valid = '0;
  logic        read_dep;
  logic        read_dep_for_jalr;
  logic [ 5:0] write_reg0 = '0;
  logic [ 5:0] write_reg1 = '0;
  logic [ 1:0] write_regs_valid = '0;
  logic        write_dep;
  logic        perf_type;
  logic        perf_cont;
  logic        apu_req;
  logic        apu_gnt = 1'b0;
  logic        apu_rvalid = 1'b0;

  logic [ 7:0] fpu_rm_in = '0;
  logic [ 7:0] fpu_rm_out;
  logic [ 7:0] hart_ctrl_in = '0;
  logic [ 7:0] hart_ctrl_out;

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
    if (hwlp_start_addr0 !== 32'h0 || hwlp_end_addr0 !== 32'h0 || hwlp_counter0 !== 32'h0 ||
        hwlp_start_addr1 !== 32'h0 || hwlp_end_addr1 !== 32'h0 || hwlp_counter1 !== 32'h0 ||
        apu_active !== 1'b0 || apu_req !== 1'b0)
      fail("Reset state mismatch");
    rst_ni = 1'b1;
    step();

    // -----------------------------------------------------------------------
    // Phase 1: HWLoop valid_i gating on start/end/counter & halfword alignment
    // -----------------------------------------------------------------------
    hwlp_valid      = 1'b0;
    hwlp_we         = 3'b111;
    hwlp_regid      = 1'b0;
    hwlp_start_data = 32'h0001_0007;
    hwlp_end_data   = 32'h0001_0023;
    hwlp_cnt_data   = 32'd9;
    step();
    if (hwlp_start_addr0 !== 32'h0 || hwlp_end_addr0 !== 32'h0 || hwlp_counter0 !== 32'h0)
      fail("Stalled hwlp_we (valid_i=0) must not write start/end/counter registers");

    // Valid write with halfword-aligned compressed addresses (bit 1 = 1, bit 0 = 1 -> masked to bit 0 = 0)
    hwlp_valid      = 1'b1;
    hwlp_we         = 3'b111;
    hwlp_regid      = 1'b0;
    hwlp_start_data = 32'h0001_0003; // expect 0x0001_0002
    hwlp_end_data   = 32'h0001_0017; // expect 0x0001_0016
    hwlp_cnt_data   = 32'd3;
    step();
    hwlp_we    = 3'b000;
    hwlp_valid = 1'b0;
    if (hwlp_start_addr0 !== 32'h0001_0002 || hwlp_end_addr0 !== 32'h0001_0016 || hwlp_counter0 !== 32'd3)
      fail($sformatf("Halfword loop0 setup mismatch: start=%h end=%h cnt=%0d", hwlp_start_addr0, hwlp_end_addr0, hwlp_counter0));

    // Setup outer loop 1
    hwlp_valid      = 1'b1;
    hwlp_we         = 3'b111;
    hwlp_regid      = 1'b1;
    hwlp_start_data = 32'h0001_0002;
    hwlp_end_data   = 32'h0001_0016;
    hwlp_cnt_data   = 32'd2;
    step();
    hwlp_we = 3'b000;
    if (hwlp_start_addr1 !== 32'h0001_0002 || hwlp_end_addr1 !== 32'h0001_0016 || hwlp_counter1 !== 32'd2)
      fail("Outer loop1 setup mismatch");

    // -----------------------------------------------------------------------
    // Phase 2: Nested simultaneous end-of-loop (hwlp_dec_cnt == 2'b11) & zero saturation
    // -----------------------------------------------------------------------
    // Pass 1: cnt0=3, cnt1=2, dec=2'b11 -> inner loop0 > 1 so only cnt0 decrements to 2, cnt1 stays 2
    hwlp_valid   = 1'b1;
    hwlp_dec_cnt = 2'b11;
    step();
    if (hwlp_counter0 !== 32'd2 || hwlp_counter1 !== 32'd2)
      fail($sformatf("Nested dec pass 1 mismatch: cnt0=%0d (exp 2) cnt1=%0d (exp 2)", hwlp_counter0, hwlp_counter1));

    // Pass 2: cnt0=2, cnt1=2, dec=2'b11 -> inner loop0 > 1 so only cnt0 decrements to 1, cnt1 stays 2
    step();
    if (hwlp_counter0 !== 32'd1 || hwlp_counter1 !== 32'd2)
      fail($sformatf("Nested dec pass 2 mismatch: cnt0=%0d (exp 1) cnt1=%0d (exp 2)", hwlp_counter0, hwlp_counter1));

    // Pass 3: cnt0=1, cnt1=2, dec=2'b11 -> inner loop0 <= 1 so BOTH decrement: cnt0->0, cnt1->1
    step();
    if (hwlp_counter0 !== 32'd0 || hwlp_counter1 !== 32'd1)
      fail($sformatf("Nested dec pass 3 mismatch: cnt0=%0d (exp 0) cnt1=%0d (exp 1)", hwlp_counter0, hwlp_counter1));

    // Pass 4: cnt0=0, cnt1=1, dec=2'b11 -> cnt0 saturates at 0, cnt1 decrements to 0
    step();
    if (hwlp_counter0 !== 32'd0 || hwlp_counter1 !== 32'd0)
      fail($sformatf("Nested dec pass 4 / zero saturation mismatch: cnt0=%0d cnt1=%0d", hwlp_counter0, hwlp_counter1));

    // Pass 5: cnt0=0, cnt1=0, dec=2'b11 -> both saturate at 0
    step();
    if (hwlp_counter0 !== 32'd0 || hwlp_counter1 !== 32'd0)
      fail("Zero counter underflowed on hwlp_dec_cnt=2'b11");
    hwlp_dec_cnt = 2'b00;
    hwlp_valid   = 1'b0;
    step();

    // -----------------------------------------------------------------------
    // Phase 3: APU Dispatcher ungranted request must not overwrite active apu_lat
    // -----------------------------------------------------------------------
    // Issue a 3-cycle request (apu_lat=2'h3) to waddr=6'd5, granted immediately
    apu_enable   = 1'b1;
    apu_lat      = 2'h3;
    apu_waddr_in = 6'd5;
    apu_gnt      = 1'b1;
    apu_rvalid   = 1'b0;
    step();
    if (apu_active !== 1'b1 || apu_multicycle !== 1'b1)
      fail("Expected active multicycle (apu_lat=3) after granted request");

    // Next cycle: issue an ungranted 1-cycle request (apu_lat=2'h0, apu_gnt=0) while first (lat=3) is active:
    // stored apu_lat driving apu_multicycle_o MUST NOT be overwritten!
    apu_enable   = 1'b1;
    apu_lat      = 2'h0;
    apu_waddr_in = 6'd6;
    apu_gnt      = 1'b0;
    step();
    if (apu_active !== 1'b1 || apu_multicycle !== 1'b1)
      fail("Ungranted request while active_o=1 overwrote stored apu_lat / apu_multicycle_o");

    apu_enable = 1'b0;
    apu_gnt    = 1'b0;
    apu_rvalid = 1'b1;
    #1;
    if (apu_rvalid_wb !== 1'b1 || apu_waddr_out !== 6'd5 || apu_multicycle !== 1'b1)
      fail("Expected 3-cycle request to return on waddr 5 with apu_multicycle=1");
    step();
    apu_rvalid = 1'b0;

    // Now issue a 2-cycle request (apu_lat=2'h2) to waddr=6'd10, granted
    apu_enable   = 1'b1;
    apu_lat      = 2'h2;
    apu_waddr_in = 6'd10;
    apu_gnt      = 1'b1;
    step();
    if (apu_active !== 1'b1 || apu_multicycle !== 1'b0)
      fail("Expected active 2-cycle request (apu_multicycle=0)");

    // While waddr=10 (lat=2) is in flight, present another lat=2 request to waddr=11 with apu_gnt=0,
    // and check that two-slot retirement preserves the younger slot when the older slot returns
    apu_enable   = 1'b1;
    apu_lat      = 2'h2;
    apu_waddr_in = 6'd11;
    apu_gnt      = 1'b1;
    step();
    // Now both waiting (waddr=10, older) and inflight (waddr=11, younger) are valid!
    apu_enable = 1'b0;
    apu_gnt    = 1'b0;
    if (apu_stall !== 1'b1)
      fail("Expected stall_full=1 when two multicycle APU requests are in flight");

    // First rvalid retires older waiting slot (waddr=10); younger inflight slot (waddr=11) must remain active!
    apu_rvalid = 1'b1;
    #1;
    if (apu_rvalid_wb !== 1'b1 || apu_waddr_out !== 6'd10)
      fail($sformatf("Expected older slot waddr=10 on first rvalid, got wb=%b waddr=%0d", apu_rvalid_wb, apu_waddr_out));
    step();
    if (apu_active !== 1'b1)
      fail("Younger slot waddr=11 must remain active after older waiting slot retires");

    // Second rvalid retires younger slot (waddr=11)
    #1;
    if (apu_rvalid_wb !== 1'b1 || apu_waddr_out !== 6'd11)
      fail($sformatf("Expected younger slot waddr=11 on second rvalid, got wb=%b waddr=%0d", apu_rvalid_wb, apu_waddr_out));
    step();
    apu_rvalid = 1'b0;
    if (apu_active !== 1'b0)
      fail("Expected apu_active=0 after both slots retired");

    // -----------------------------------------------------------------------
    // Phase 4: Synchronous flush_i draining of in-flight APU slots + post-flush new request
    // -----------------------------------------------------------------------
    // Issue slot A (waddr=6'd18, lat=2), granted
    apu_enable   = 1'b1;
    apu_lat      = 2'h2;
    apu_waddr_in = 6'd18;
    apu_gnt      = 1'b1;
    step();

    // Assert flush_i while slot A is in flight and a new request (waddr=6'd19) is attempted
    flush_i      = 1'b1;
    apu_enable   = 1'b1;
    apu_waddr_in = 6'd19;
    apu_gnt      = 1'b1;
    #1;
    if (apu_req !== 1'b0 || apu_rvalid_wb !== 1'b0)
      fail("flush_i must immediately suppress apu_req and apu_rvalid_wb");
    step();
    flush_i    = 1'b0;
    apu_enable = 1'b0;
    apu_gnt    = 1'b0;

    // Slot A (waddr=18) is still draining in flight (`apu_active=1`), but killed: dependencies must be 0!
    read_reg0        = 6'd18;
    read_regs_valid  = 3'b001;
    write_reg0       = 6'd18;
    write_regs_valid = 2'b01;
    #1;
    if (apu_active !== 1'b1)
      fail("Flushed in-flight APU slot must keep apu_active=1 until its response returns");
    if (read_dep !== 1'b0 || read_dep_for_jalr !== 1'b0 || write_dep !== 1'b0)
      fail("Flushed in-flight APU slot must not report register read/write dependencies");

    // Issue a new post-flush request B (waddr=6'd22, lat=2) while flushed slot A is still draining!
    apu_enable   = 1'b1;
    apu_lat      = 2'h2;
    apu_waddr_in = 6'd22;
    apu_gnt      = 1'b1;
    step();
    apu_enable = 1'b0;
    apu_gnt    = 1'b0;

    // Now waiting=18 (killed), inflight=22 (live). Dependencies on 22 must be 1, on 18 must be 0!
    read_reg0       = 6'd18;
    read_reg1       = 6'd22;
    read_regs_valid = 3'b010;
    #1;
    if (read_dep !== 1'b1)
      fail("Live post-flush slot (waddr=22) must report read_dep=1");
    read_regs_valid = 3'b001;
    #1;
    if (read_dep !== 1'b0)
      fail("Killed waiting slot (waddr=18) must not report read_dep=1");

    // First rvalid drains killed waiting slot A (waddr=18): apu_rvalid_wb MUST be 0!
    apu_rvalid = 1'b1;
    #1;
    if (apu_rvalid_wb !== 1'b0)
      fail("Draining killed slot A must not assert apu_rvalid_wb");
    step();

    // Second rvalid retires live slot B (waddr=22): apu_rvalid_wb MUST be 1 and waddr_out=22!
    #1;
    if (apu_rvalid_wb !== 1'b1 || apu_waddr_out !== 6'd22)
      fail($sformatf("Live post-flush slot B failed to write back: wb=%b waddr=%0d", apu_rvalid_wb, apu_waddr_out));
    step();
    apu_rvalid = 1'b0;

    // Transparent channels check
    for (int k = 0; k < 16; k++) begin
      fpu_rm_in    = 8'((seed * 19 + k * 37) & 8'hff);
      hart_ctrl_in = 8'((seed * 53 + k * 71) & 8'hff);
      #1;
      if (fpu_rm_out !== fpu_rm_in || hart_ctrl_out !== hart_ctrl_in)
        fail("Transparent feedthrough channel mismatch");
    end

    $display("TB_PASS seed=%0d", seed);
    $finish(0);
  end
endmodule
