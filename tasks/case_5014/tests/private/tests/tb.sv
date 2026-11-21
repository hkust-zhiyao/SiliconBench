`timescale 1ns/1ps
module tb;
  import ariane_pkg::*;
  import wt_cache_pkg::*;

  logic         clk_i = 0;
  logic         rst_ni = 0;
  logic         icache_data_req_i = 0;
  logic         icache_data_ack_o;
  logic         icache_rtype_i = 0;
  logic [ 31:0] icache_paddr_i = 0;
  logic         icache_nc_i = 0;
  logic [  1:0] icache_tid_i = 0;
  logic         icache_rtrn_vld_o;
  logic         icache_rtrn_rtype_o;
  logic [127:0] icache_rtrn_data_o;
  logic [  1:0] icache_rtrn_tid_o;
  logic         dcache_data_req_i = 0;
  logic         dcache_data_ack_o;
  logic [  1:0] dcache_rtype_i = 0;
  logic [  2:0] dcache_size_i = 0;
  logic [ 31:0] dcache_paddr_i = 0;
  logic [ 63:0] dcache_wdata_i = 0;
  logic         dcache_nc_i = 0;
  logic [  1:0] dcache_tid_i = 0;
  logic [  3:0] dcache_amo_op_i = 0;
  logic         dcache_rtrn_vld_o;
  logic [  1:0] dcache_rtrn_rtype_o;
  logic [127:0] dcache_rtrn_data_o;
  logic [  1:0] dcache_rtrn_tid_o;
  logic [  9:0] dcache_rtrn_inv_idx_o;
  logic         dcache_rtrn_inv_all_o;
  logic         mbe_i = 0;
  logic [ 63:0] inval_addr_i = 0;
  logic         inval_valid_i = 0;
  logic         inval_ready_o;
  logic         aw_valid_o;
  logic         aw_ready_i = 0;
  logic [  3:0] aw_id_o;
  logic [ 31:0] aw_addr_o;
  logic [  7:0] aw_len_o;
  logic [  2:0] aw_size_o;
  logic         aw_lock_o;
  logic [  5:0] aw_atop_o;
  logic         w_valid_o;
  logic         w_ready_i = 0;
  logic [ 63:0] w_data_o;
  logic [  7:0] w_strb_o;
  logic         w_last_o;
  logic         b_valid_i = 0;
  logic         b_ready_o;
  logic [  3:0] b_id_i = 0;
  logic [  1:0] b_resp_i = 0;
  logic         ar_valid_o;
  logic         ar_ready_i = 0;
  logic [  3:0] ar_id_o;
  logic [ 31:0] ar_addr_o;
  logic [  7:0] ar_len_o;
  logic [  2:0] ar_size_o;
  logic         ar_lock_o;
  logic         r_valid_i = 0;
  logic         r_ready_o;
  logic [  3:0] r_id_i = 0;
  logic [ 63:0] r_data_i = 0;
  logic [  1:0] r_resp_i = 0;
  logic         r_last_i = 0;

  always #5 clk_i = ~clk_i;

  wt_axi_subsys_top dut (.*);

  int seed = 101;
  int fail_cnt = 0;

  task automatic fail(input string msg);
    $display("FAIL: %s (t=%0t)", msg, $time);
    fail_cnt++;
  endtask

  task automatic step();
    @(posedge clk_i);
    #1;
  endtask

  initial begin
    void'($value$plusargs("seed=%d", seed));
    rst_ni = 0;
    repeat (4) step();
    rst_ni = 1;
    step();

    // -----------------------------------------------------------------------
    // T1: I-Cache 2-Beat Cacheline Fill (`icache_nc_i = 0`) with `ar_ready_i = 0`
    //     on the initial cycle (`READ_HOLD` stability check):
    // -----------------------------------------------------------------------
    ar_ready_i        = 1'b0;
    icache_data_req_i = 1'b1;
    icache_paddr_i    = 32'h8000_0100;
    icache_nc_i       = 1'b0;
    icache_tid_i      = 2'd2;
    #1;
    if (icache_data_ack_o !== 1'b1) fail("T1a: icache_data_ack_o not asserted");
    step(); // now in icache_data_fifo, axi_shim sees rd_req_i=1, ar_ready_i=0 -> enters READ_HOLD
    icache_data_req_i = 1'b0;
    if (ar_valid_o !== 1'b1 || ar_addr_o !== 32'h8000_0100 || ar_len_o !== 8'd1 || ar_id_o !== 4'd0) begin
      fail($sformatf("T1b: initial AR mismatch vld=%b addr=%h len=%0d id=%0d", ar_valid_o, ar_addr_o, ar_len_o, ar_id_o));
    end
    step(); // now in READ_HOLD while ar_ready_i is still 0: ar_valid_o and ar_addr_o MUST remain stable!
    if (ar_valid_o !== 1'b1 || ar_addr_o !== 32'h8000_0100 || ar_len_o !== 8'd1) begin
      fail($sformatf("T1c: READ_HOLD dropped ar_valid_o=%b or ar_addr_o=%h", ar_valid_o, ar_addr_o));
    end
    ar_ready_i = 1'b1;
    step(); // AR accepted
    ar_ready_i = 1'b0;
    // Return 2 R beats for I-Cache (`r_id_i = 0`):
    r_valid_i = 1'b1;
    r_id_i    = 4'd0;
    r_data_i  = 64'h1111_2222_3333_4444;
    r_last_i  = 1'b0;
    step();
    if (icache_rtrn_vld_o !== 1'b0) fail("T1d: icache_rtrn_vld_o asserted on beat 0");
    r_data_i  = 64'h5555_6666_7777_8888;
    r_last_i  = 1'b1;
    step();
    r_valid_i = 1'b0;
    r_last_i  = 1'b0;
    if (icache_rtrn_vld_o !== 1'b1 || icache_rtrn_tid_o !== 2'd2 ||
        icache_rtrn_data_o !== 128'h5555_6666_7777_8888_1111_2222_3333_4444) begin
      fail($sformatf("T1e: icache return mismatch vld=%b tid=%0d data=%h",
        icache_rtrn_vld_o, icache_rtrn_tid_o, icache_rtrn_data_o));
    end
    step();

    // -----------------------------------------------------------------------
    // T2: D-Cache Store Request (`DCACHE_STORE_REQ`) with Decoupled AW (`aw_ready_i = 1`)
    //     and Delayed W (`w_ready_i = 0` -> `WRITE_WAIT`):
    //     Verify `w_valid_o = 1`, `w_last_o = 1`, `w_data_o`, `w_strb_o` remain stable in `WRITE_WAIT`!
    // -----------------------------------------------------------------------
    aw_ready_i        = 1'b1;
    w_ready_i         = 1'b0;
    dcache_data_req_i = 1'b1;
    dcache_rtype_i    = wt_cache_pkg::DCACHE_STORE_REQ;
    dcache_size_i     = 3'b010; // 32-bit word store
    dcache_paddr_i    = 32'h8000_0204; // upper 32-bit half of 64-bit AXI bus (`paddr[2:0] = 3'b100`)
    dcache_wdata_i    = 64'hCAFE_BABE_1234_5678;
    dcache_tid_i      = 2'd1;
    step(); // pushed into dcache_data_fifo; AW accepted (`aw_ready_i=1`), W stalled (`w_ready_i=0`) -> enters WRITE_WAIT
    dcache_data_req_i = 1'b0;
    if (aw_valid_o !== 1'b1 || w_valid_o !== 1'b1 || w_last_o !== 1'b1 || w_strb_o !== 8'hF0) begin
      fail($sformatf("T2a: initial store AW/W mismatch aw_vld=%b w_vld=%b w_last=%b strb=%h",
        aw_valid_o, w_valid_o, w_last_o, w_strb_o));
    end
    step(); // now in WRITE_WAIT with aw_ready_i = 1, w_ready_i = 0
    aw_ready_i = 1'b0;
    if (aw_valid_o !== 1'b0 || w_valid_o !== 1'b1 || w_last_o !== 1'b1 ||
        w_data_o !== 64'hCAFE_BABE_1234_5678 || w_strb_o !== 8'hF0) begin
      fail($sformatf("T2b: WRITE_WAIT corrupted W channel aw_vld=%b w_vld=%b w_last=%b data=%h strb=%h",
        aw_valid_o, w_valid_o, w_last_o, w_data_o, w_strb_o));
    end
    w_ready_i = 1'b1;
    step(); // W accepted -> popped from dcache_data_fifo and pushed into wr_dcache_id FIFO
    w_ready_i = 1'b0;
    // Return B response (`b_id_i = 4'b0001`):
    b_valid_i = 1'b1;
    b_id_i    = 4'b0001;
    b_resp_i  = axi_pkg::RESP_OKAY;
    step();
    b_valid_i = 1'b0;
    if (dcache_rtrn_vld_o !== 1'b1 || dcache_rtrn_rtype_o !== wt_cache_pkg::DCACHE_STORE_ACK ||
        dcache_rtrn_tid_o !== 2'd1) begin
      fail($sformatf("T2c: DCACHE_STORE_ACK mismatch vld=%b rtype=%0d tid=%0d",
        dcache_rtrn_vld_o, dcache_rtrn_rtype_o, dcache_rtrn_tid_o));
    end
    step();

    // -----------------------------------------------------------------------
    // T3: 32-bit Atomic Operations (`DCACHE_ATOMIC_REQ`, `size = 3'b010`) at
    //     Upper 32-bit Word Offset (`paddr[2:0] = 3'b100`) & Coincidental External
    //     Invalidation (`inval_valid_i = 1`):
    //     - Verify 32-bit `AMO_ADD` (`mbe_i = 1` big-endian ATOP) replicates lower 32b
    //       `dcache_wdata_i[31:0]` onto `w_data_o[63:32]` (`{2{dcache_wdata_i[31:0]}}`)!
    //     - Verify when `inval_valid_i = 1` coincides with the atomic grant cycle,
    //       BOTH the external invalidation (`idx = inval_addr_i[9:0]`) AND the
    //       atomic self-invalidation (`idx = dcache_paddr_i[9:0]`) are emitted on
    //       consecutive cycles without dropping the self-invalidation!
    // -----------------------------------------------------------------------
    aw_ready_i        = 1'b1;
    w_ready_i         = 1'b1;
    mbe_i             = 1'b1;
    dcache_data_req_i = 1'b1;
    dcache_rtype_i    = wt_cache_pkg::DCACHE_ATOMIC_REQ;
    dcache_size_i     = 3'b010; // 32-bit AMO (`AMO_ADDW`)
    dcache_paddr_i    = 32'h8000_0184; // idx = 10'h184, upper 32b word (`paddr[2:0] = 3'b100`)
    dcache_wdata_i    = 64'h0000_0000_ABCD_EF01; // upper 32 bits are 0, lower 32 bits hold operand!
    dcache_tid_i      = 2'd3;
    dcache_amo_op_i   = AMO_ADD;
    step(); // now at head of dcache_data_fifo, granted on this cycle!
    dcache_data_req_i = 1'b0;
    // Assert external invalidation (`inval_valid_i = 1`, `inval_addr_i = 64'h0050`) on the exact grant cycle!
    inval_valid_i     = 1'b1;
    inval_addr_i      = 64'h0000_0000_0000_0050;
    #1;
    if (aw_valid_o !== 1'b1 || w_valid_o !== 1'b1 || w_strb_o !== 8'hF0 ||
        w_data_o !== 64'hABCD_EF01_ABCD_EF01 ||
        aw_atop_o !== {axi_pkg::ATOP_ATOMICLOAD, axi_pkg::ATOP_BIG_END, axi_pkg::ATOP_ADD}) begin
      fail($sformatf("T3a: 32b AMO_ADD w_data=%h strb=%h atop=%b", w_data_o, w_strb_o, aw_atop_o));
    end
    step(); // Cycle after grant: external invalidation (idx = 10'h050) should appear on dcache_rtrn_o!
    inval_valid_i = 1'b0;
    mbe_i         = 1'b0;
    if (dcache_rtrn_vld_o !== 1'b1 || dcache_rtrn_rtype_o !== wt_cache_pkg::DCACHE_INV_REQ ||
        dcache_rtrn_inv_all_o !== 1'b1 || dcache_rtrn_inv_idx_o !== 10'h050) begin
      fail($sformatf("T3b: external invalidation mismatch vld=%b rtype=%0d idx=%h",
        dcache_rtrn_vld_o, dcache_rtrn_rtype_o, dcache_rtrn_inv_idx_o));
    end
    step(); // Next cycle: buffered atomic self-invalidation (idx = 10'h184) MUST appear on dcache_rtrn_o!
    if (dcache_rtrn_vld_o !== 1'b1 || dcache_rtrn_rtype_o !== wt_cache_pkg::DCACHE_INV_REQ ||
        dcache_rtrn_inv_all_o !== 1'b1 || dcache_rtrn_inv_idx_o !== 10'h184) begin
      fail($sformatf("T3c: buffered atomic self-invalidation dropped! vld=%b rtype=%0d idx=%h",
        dcache_rtrn_vld_o, dcache_rtrn_rtype_o, dcache_rtrn_inv_idx_o));
    end
    // Return R beat (`r_id_i = 4'b0011`) and B beat (`b_id_i = 4'b0011`) for AMO_ADD:
    r_valid_i = 1'b1;
    r_id_i    = 4'b0011;
    r_data_i  = 64'h9988_7766_0000_0000;
    r_last_i  = 1'b1;
    b_valid_i = 1'b1;
    b_id_i    = 4'b0011;
    b_resp_i  = axi_pkg::RESP_OKAY;
    step();
    r_valid_i = 1'b0;
    r_last_i  = 1'b0;
    b_valid_i = 1'b0;
    if (dcache_rtrn_vld_o !== 1'b1 || dcache_rtrn_rtype_o !== wt_cache_pkg::DCACHE_ATOMIC_ACK ||
        dcache_rtrn_tid_o !== 2'd3 || dcache_rtrn_data_o[63:0] !== 64'h9988_7766_0000_0000) begin
      fail($sformatf("T3d: AMO_ADD return mismatch vld=%b rtype=%0d tid=%0d data=%h",
        dcache_rtrn_vld_o, dcache_rtrn_rtype_o, dcache_rtrn_tid_o, dcache_rtrn_data_o[63:0]));
    end
    step();

    // -----------------------------------------------------------------------
    // T4: 32-bit `AMO_AND` Bitwise Inversion (`~{2{dcache_wdata_i[31:0]}}`) & `AMO_SC`
    //     `RESP_EXOKAY` Status Encoding
    // -----------------------------------------------------------------------
    dcache_data_req_i = 1'b1;
    dcache_rtype_i    = wt_cache_pkg::DCACHE_ATOMIC_REQ;
    dcache_size_i     = 3'b010;
    dcache_paddr_i    = 32'h8000_0284;
    dcache_wdata_i    = 64'h0000_0000_0F0F_00FF;
    dcache_tid_i      = 2'd0;
    dcache_amo_op_i   = AMO_AND;
    step();
    dcache_data_req_i = 1'b0;
    #1;
    if (w_data_o !== 64'hF0F0_FF00_F0F0_FF00) begin
      fail($sformatf("T4a: 32b AMO_AND inverted w_data=%h (exp f0f0ff00f0f0ff00)", w_data_o));
    end
    step();
    r_valid_i = 1'b1;
    r_id_i    = 4'b0011;
    r_data_i  = 64'h1234_5678_0000_0000;
    r_last_i  = 1'b1;
    b_valid_i = 1'b1;
    b_id_i    = 4'b0011;
    step();
    r_valid_i = 1'b0;
    r_last_i  = 1'b0;
    b_valid_i = 1'b0;
    step();

    // Now test `AMO_SC` with `RESP_EXOKAY` (success -> 0 at byte offset 4 -> bit 32) vs `RESP_OKAY` (failure -> 1 at bit 32):
    dcache_data_req_i = 1'b1;
    dcache_rtype_i    = wt_cache_pkg::DCACHE_ATOMIC_REQ;
    dcache_size_i     = 3'b010;
    dcache_paddr_i    = 32'h8000_0284; // offset 4 (`amo_off_q = 4` -> bit 32)
    dcache_wdata_i    = 64'h0000_0000_1122_3344;
    dcache_tid_i      = 2'd2;
    dcache_amo_op_i   = AMO_SC;
    step();
    dcache_data_req_i = 1'b0;
    step(); // self-invalidation cycle
    b_valid_i = 1'b1;
    b_id_i    = 4'b0011;
    b_resp_i  = axi_pkg::RESP_OKAY; // SC failed -> bit 32 must be 1!
    step();
    b_valid_i = 1'b0;
    if (dcache_rtrn_vld_o !== 1'b1 || dcache_rtrn_rtype_o !== wt_cache_pkg::DCACHE_ATOMIC_ACK ||
        dcache_rtrn_data_o[32] !== 1'b1) begin
      fail($sformatf("T4b: AMO_SC failure encoding mismatch vld=%b bit32=%b", dcache_rtrn_vld_o, dcache_rtrn_data_o[32]));
    end
    step();

    if (fail_cnt == 0) begin
      $display("PASS: all WT-AXI adapter/shim/FIFO checks passed (seed=%0d)", seed);
      $finish;
    end else begin
      $display("FAIL: %0d checks failed", fail_cnt);
      $fatal(1, "tb failed");
    end
  end
endmodule
