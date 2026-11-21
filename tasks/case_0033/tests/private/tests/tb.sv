`include "bsg_manycore_defines.svh"

module tb;
  import bsg_manycore_pkg::*;
  import bsg_manycore_addr_pkg::*;
  import bsg_vanilla_pkg::*;

  localparam int data_width_lp = 32;
  localparam int addr_width_lp = 28;
  localparam int x_cord_width_lp = 7;
  localparam int y_cord_width_lp = 7;
  localparam int pod_x_cord_width_lp = 3;
  localparam int pod_y_cord_width_lp = 4;
  localparam int num_tiles_x_lp = 16;
  localparam int num_tiles_y_lp = 8;
  localparam int vcache_size_lp = 512;
  localparam int vcache_block_size_in_words_lp = 8;
  localparam int vcache_sets_lp = 64;
  localparam int ipoly_hashing_lp = 1;
  localparam int icache_entries_lp = 1024;
  localparam int icache_tag_width_lp = 12;
  localparam int icache_block_size_in_words_lp = 4;
  localparam int dmem_size_lp = 1024;
  localparam int fifo_els_lp = 2;
  localparam int rev_fifo_els_lp = 3;
  localparam int credit_counter_width_lp = `BSG_WIDTH(32);

  localparam int x_subcord_width_lp = `BSG_SAFE_CLOG2(num_tiles_x_lp);
  localparam int y_subcord_width_lp = `BSG_SAFE_CLOG2(num_tiles_y_lp);
  localparam int dmem_addr_width_lp = `BSG_SAFE_CLOG2(dmem_size_lp);
  localparam int data_mask_width_lp = (data_width_lp >> 3);
  localparam int reg_addr_width_lp = RV32_reg_addr_width_gp;

  `declare_bsg_manycore_link_sif_s(addr_width_lp, data_width_lp, x_cord_width_lp, y_cord_width_lp);
  `declare_bsg_manycore_packet_s(addr_width_lp, data_width_lp, x_cord_width_lp, y_cord_width_lp);

  logic clk_i;
  logic reset_i;

  bsg_manycore_link_sif_s link_sif_i;
  bsg_manycore_link_sif_s link_sif_o;

  logic [x_subcord_width_lp-1:0] my_x_i;
  logic [y_subcord_width_lp-1:0] my_y_i;
  logic [pod_x_cord_width_lp-1:0] pod_x_i;
  logic [pod_y_cord_width_lp-1:0] pod_y_i;
  logic [pod_x_cord_width_lp-1:0] cfg_pod_x_i;
  logic [pod_y_cord_width_lp-1:0] cfg_pod_y_i;
  logic [x_subcord_width_lp-1:0] tgo_x_i;
  logic [y_subcord_width_lp-1:0] tgo_y_i;

  decode_s exe_decode_i;
  logic [data_width_lp-1:0] exe_rs1_i;
  logic [data_width_lp-1:0] exe_rs2_i;
  logic [reg_addr_width_lp-1:0] exe_rd_i;
  logic [RV32_Iimm_width_gp-1:0] mem_offset_i;
  logic [data_width_lp-1:0] pc_plus4_i;
  logic icache_miss_i;
  logic stall_all_i;
  logic flush_i;

  logic dmem_v_o;
  logic dmem_w_o;
  logic [dmem_addr_width_lp-1:0] dmem_addr_o;
  logic [data_width_lp-1:0] dmem_data_o;
  logic [data_mask_width_lp-1:0] dmem_mask_o;
  logic reserve_o;
  logic [1:0] byte_sel_o;

  logic in_v_o;
  logic [data_width_lp-1:0] in_data_o;
  logic [data_mask_width_lp-1:0] in_mask_o;
  logic [addr_width_lp-1:0] in_addr_o;
  logic in_we_o;
  bsg_manycore_load_info_s in_load_info_o;
  logic [x_cord_width_lp-1:0] in_src_x_cord_o;
  logic [y_cord_width_lp-1:0] in_src_y_cord_o;
  logic in_yumi_i;

  logic [data_width_lp-1:0] returning_data_i;
  logic returning_v_i;

  logic remote_req_credit_o;
  logic ifetch_v_o;
  logic [data_width_lp-1:0] ifetch_instr_o;
  logic [reg_addr_width_lp-1:0] float_remote_load_resp_rd_o;
  logic [data_width_lp-1:0] float_remote_load_resp_data_o;
  logic float_remote_load_resp_v_o;
  logic float_remote_load_resp_force_o;
  logic float_remote_load_resp_yumi_i;
  logic [reg_addr_width_lp-1:0] int_remote_load_resp_rd_o;
  logic [data_width_lp-1:0] int_remote_load_resp_data_o;
  logic int_remote_load_resp_v_o;
  logic int_remote_load_resp_force_o;
  logic int_remote_load_resp_yumi_i;
  logic invalid_eva_access_o;
  logic returned_credit_v_r_o;
  logic [bsg_manycore_reg_id_width_gp-1:0] returned_credit_reg_id_r_o;
  logic [credit_counter_width_lp-1:0] out_credits_used_o;

  bsg_manycore_tile_mem_if dut (
    .clk_i(clk_i)
    ,.reset_i(reset_i)
    ,.link_sif_i(link_sif_i)
    ,.link_sif_o(link_sif_o)
    ,.my_x_i(my_x_i)
    ,.my_y_i(my_y_i)
    ,.pod_x_i(pod_x_i)
    ,.pod_y_i(pod_y_i)
    ,.cfg_pod_x_i(cfg_pod_x_i)
    ,.cfg_pod_y_i(cfg_pod_y_i)
    ,.tgo_x_i(tgo_x_i)
    ,.tgo_y_i(tgo_y_i)
    ,.exe_decode_i(exe_decode_i)
    ,.exe_rs1_i(exe_rs1_i)
    ,.exe_rs2_i(exe_rs2_i)
    ,.exe_rd_i(exe_rd_i)
    ,.mem_offset_i(mem_offset_i)
    ,.pc_plus4_i(pc_plus4_i)
    ,.icache_miss_i(icache_miss_i)
    ,.stall_all_i(stall_all_i)
    ,.flush_i(flush_i)
    ,.dmem_v_o(dmem_v_o)
    ,.dmem_w_o(dmem_w_o)
    ,.dmem_addr_o(dmem_addr_o)
    ,.dmem_data_o(dmem_data_o)
    ,.dmem_mask_o(dmem_mask_o)
    ,.reserve_o(reserve_o)
    ,.byte_sel_o(byte_sel_o)
    ,.in_v_o(in_v_o)
    ,.in_data_o(in_data_o)
    ,.in_mask_o(in_mask_o)
    ,.in_addr_o(in_addr_o)
    ,.in_we_o(in_we_o)
    ,.in_load_info_o(in_load_info_o)
    ,.in_src_x_cord_o(in_src_x_cord_o)
    ,.in_src_y_cord_o(in_src_y_cord_o)
    ,.in_yumi_i(in_yumi_i)
    ,.returning_data_i(returning_data_i)
    ,.returning_v_i(returning_v_i)
    ,.remote_req_credit_o(remote_req_credit_o)
    ,.ifetch_v_o(ifetch_v_o)
    ,.ifetch_instr_o(ifetch_instr_o)
    ,.float_remote_load_resp_rd_o(float_remote_load_resp_rd_o)
    ,.float_remote_load_resp_data_o(float_remote_load_resp_data_o)
    ,.float_remote_load_resp_v_o(float_remote_load_resp_v_o)
    ,.float_remote_load_resp_force_o(float_remote_load_resp_force_o)
    ,.float_remote_load_resp_yumi_i(float_remote_load_resp_yumi_i)
    ,.int_remote_load_resp_rd_o(int_remote_load_resp_rd_o)
    ,.int_remote_load_resp_data_o(int_remote_load_resp_data_o)
    ,.int_remote_load_resp_v_o(int_remote_load_resp_v_o)
    ,.int_remote_load_resp_force_o(int_remote_load_resp_force_o)
    ,.int_remote_load_resp_yumi_i(int_remote_load_resp_yumi_i)
    ,.invalid_eva_access_o(invalid_eva_access_o)
    ,.returned_credit_v_r_o(returned_credit_v_r_o)
    ,.returned_credit_reg_id_r_o(returned_credit_reg_id_r_o)
    ,.out_credits_used_o(out_credits_used_o)
  );

  initial clk_i = 1'b0;
  always #5 clk_i = ~clk_i;

  task automatic fail(input string msg);
    $display("FAIL: %s at t=%0t", msg, $time);
    $finish(1);
  endtask

  task automatic clear_inputs();
    link_sif_i = '0;
    link_sif_i.fwd.ready_and_rev = 1'b1;
    link_sif_i.rev.ready_and_rev = 1'b1;
    my_x_i = 4'd3;
    my_y_i = 3'd2;
    pod_x_i = 3'd1;
    pod_y_i = 4'd2;
    cfg_pod_x_i = 3'd1;
    cfg_pod_y_i = 4'd2;
    tgo_x_i = 4'd1;
    tgo_y_i = 3'd1;
    exe_decode_i = '0;
    exe_rs1_i = '0;
    exe_rs2_i = '0;
    exe_rd_i = '0;
    mem_offset_i = '0;
    pc_plus4_i = '0;
    icache_miss_i = 1'b0;
    stall_all_i = 1'b0;
    flush_i = 1'b0;
    in_yumi_i = 1'b0;
    returning_data_i = '0;
    returning_v_i = 1'b0;
    float_remote_load_resp_yumi_i = 1'b0;
    int_remote_load_resp_yumi_i = 1'b0;
  endtask

  int seed = 1;
  bsg_manycore_packet_s exp_pkt;
  bsg_manycore_packet_s obs_pkt;
  bsg_manycore_packet_s req1, req2;
  bsg_manycore_return_packet_s r_pkt;

  initial begin
    void'($value$plusargs("seed=%d", seed));
    reset_i = 1'b1;
    clear_inputs();
    repeat (4) @(posedge clk_i);
    @(negedge clk_i);
    reset_i = 1'b0;

    // -------------------------------------------------------------------------
    // Phase 1: LSU positive/negative offset carry/borrow across 12-bit boundary
    // -------------------------------------------------------------------------
    // 1a: Local DMEM positive carry into bit 12: 0x0000_0ff8 + 0x008 = 0x0000_1000 (remote tile-group/invalid, not local DMEM!)
    exe_decode_i = '0;
    exe_decode_i.is_load_op = 1'b1;
    exe_rs1_i = 32'h0000_0ff8;
    mem_offset_i = 12'h008;
    #1;
    if (dmem_v_o !== 1'b0) fail("Phase 1a: 0x0ff8 + 0x008 = 0x1000 should not be local DMEM");

    // 1b: Local DMEM negative borrow from bit 12: 0x0000_1004 + (-8 = 12'hff8) = 0x0000_0ffc (IS local DMEM!)
    exe_rs1_i = 32'h0000_1004;
    mem_offset_i = 12'hff8;
    #1;
    if (dmem_v_o !== 1'b1 || dmem_addr_o !== 10'h3ff) fail("Phase 1b: 0x1004 - 8 = 0x0ffc must map to local DMEM addr 0x3ff");

    // 1c: Multi-bit borrow across upper bits: 0x8001_0000 + (-4 = 12'hffc) = 0x8000_fffc (DRAM address)
    exe_rs1_i = 32'h8001_0000;
    mem_offset_i = 12'hffc;
    exe_rd_i = 5'd9;
    #1;
    obs_pkt = link_sif_o.fwd.data;
    if (!link_sif_o.fwd.v || invalid_eva_access_o) fail("Phase 1c: valid DRAM load failed");
    if (obs_pkt.addr[2:0] !== 3'b111 || obs_pkt.addr[15:3] !== 13'h003f) fail("Phase 1c: multi-bit borrow on DRAM EVA failed");

    // -------------------------------------------------------------------------
    // Phase 2: LSU icache_miss_i & is_uncached_op precedence
    // -------------------------------------------------------------------------
    // 2a: icache_miss_i asserted while exe_decode_i has store/lr/amo bits and local-DMEM rs1+offset
    exe_decode_i = '0;
    exe_decode_i.is_store_op = 1'b1;
    exe_decode_i.is_lr_op = 1'b1;
    exe_decode_i.is_amo_op = 1'b1;
    exe_decode_i.is_uncached_op = 1'b1;
    exe_rs1_i = 32'h0000_0020;
    mem_offset_i = 12'h004;
    cfg_pod_x_i = 3'd5;
    cfg_pod_y_i = 4'd7;
    pc_plus4_i = 32'h0000_0400; // pc = 0x0000_03fc -> DRAM 0x8000_03fc (low 20 bits upper == 0)
    icache_miss_i = 1'b1;
    #1;
    obs_pkt = link_sif_o.fwd.data;
    if (dmem_v_o !== 1'b0 || dmem_w_o !== 1'b0 || reserve_o !== 1'b0)
      fail("Phase 2a: icache_miss_i must suppress dmem_v_o, dmem_w_o, and reserve_o");
    if (!link_sif_o.fwd.v || obs_pkt.op_v2 !== e_remote_load || obs_pkt.payload.load_info_s.load_info.icache_fetch !== 1'b1)
      fail("Phase 2a: icache_miss_i must emit e_remote_load with icache_fetch=1");
    if (obs_pkt.addr[2:0] !== 3'b111 || obs_pkt.x_cord[x_cord_width_lp-1 -: pod_x_cord_width_lp] !== pod_x_i)
      fail("Phase 2a: icache_miss_i address/pod_x_i routing incorrect");
    cfg_pod_x_i = pod_x_i;
    cfg_pod_y_i = pod_y_i;
    icache_miss_i = 1'b0;

    // 2b: is_uncached_op with address[31:12] == 0 must NOT assert dmem_v_o
    exe_decode_i = '0;
    exe_decode_i.is_load_op = 1'b1;
    exe_decode_i.is_uncached_op = 1'b1;
    exe_rs1_i = 32'h0000_0100;
    mem_offset_i = 12'h000;
    #1;
    obs_pkt = link_sif_o.fwd.data;
    if (dmem_v_o !== 1'b0 || !link_sif_o.fwd.v || obs_pkt.op_v2 !== e_remote_uncached_load)
      fail("Phase 2b: uncached op in low address range must route to network, not local DMEM");
    exe_decode_i = '0;
    @(negedge clk_i);

    // -------------------------------------------------------------------------
    // Phase 3: network_tx stall-lock across multi-cycle link backpressure
    // -------------------------------------------------------------------------
    link_sif_i.fwd.ready_and_rev = 1'b0; // stall outgoing link
    exe_decode_i = '0;
    exe_decode_i.is_store_op = 1'b1;
    exe_decode_i.is_byte_op = 1'b1;
    exe_rs1_i = 32'h8000_2001;
    exe_rs2_i = 32'h0000_00a5;
    mem_offset_i = 12'h000;
    #1;
    if (!link_sif_o.fwd.v || remote_req_credit_o !== 1'b0)
      fail("Phase 3a: initial stalled request must assert link_sif_o.fwd.v with credit=0");
    exp_pkt = link_sif_o.fwd.data;

    // Clock edge 1: latches stalled packet into network_tx
    @(negedge clk_i);
    // Perturb EXE inputs to a different load and even an invalid EVA while stalled
    exe_decode_i = '0;
    exe_decode_i.is_load_op = 1'b1;
    exe_rs1_i = 32'h0000_4000; // invalid EVA!
    exe_rs2_i = 32'hdead_beef;
    tgo_x_i = 4'd9;
    cfg_pod_x_i = 3'd5;
    #1;
    if (!link_sif_o.fwd.v || link_sif_o.fwd.data !== exp_pkt)
      fail("Phase 3b: stalled outgoing packet changed when EXE inputs changed");
    if (remote_req_credit_o !== 1'b0 || invalid_eva_access_o !== 1'b0)
      fail("Phase 3b: credit or invalid_eva_access_o asserted while held packet stalled");

    //Even if ready_and_rev goes high while held_v_r is high, remote_req_credit_o must stay 0 on that cycle
    link_sif_i.fwd.ready_and_rev = 1'b1;
    #1;
    if (remote_req_credit_o !== 1'b0)
      fail("Phase 3c: remote_req_credit_o must remain 0 on the cycle the held packet drains");
    if (!link_sif_o.fwd.v || link_sif_o.fwd.data !== exp_pkt)
      fail("Phase 3c: held packet corrupted on drain cycle");

    // Next posedge drains held packet
    @(negedge clk_i);
    exe_decode_i = '0;
    #1;
    if (link_sif_o.fwd.v !== 1'b0 || remote_req_credit_o !== 1'b1)
      fail("Phase 3d: held packet did not clear after acceptance");

    // -------------------------------------------------------------------------
    // Phase 4: flush_i cancellation of live and stall-locked requests
    // -------------------------------------------------------------------------
    link_sif_i.fwd.ready_and_rev = 1'b0;
    exe_decode_i.is_load_op = 1'b1;
    exe_rs1_i = 32'h8000_3000;
    exe_rd_i = 5'd12;
    #1;
    if (!link_sif_o.fwd.v) fail("Phase 4a: live request not valid before flush");
    flush_i = 1'b1;
    #1;
    if (link_sif_o.fwd.v !== 1'b0) fail("Phase 4a: flush_i did not immediately suppress live out_v_o");
    // Also check invalid_eva_access_o is suppressed by flush_i
    exe_rs1_i = 32'h0000_5000; // invalid EVA
    #1;
    if (invalid_eva_access_o !== 1'b0) fail("Phase 4b: flush_i did not suppress invalid_eva_access_o");

    // Latch a stalled request with flush_i=0, then abort it mid-stall with flush_i=1
    flush_i = 1'b0;
    exe_rs1_i = 32'h8000_3000;
    @(negedge clk_i); // now held_v_r == 1
    exe_decode_i = '0;
    #1;
    if (!link_sif_o.fwd.v) fail("Phase 4c: request not held");
    flush_i = 1'b1;
    #1;
    if (link_sif_o.fwd.v !== 1'b0) fail("Phase 4c: flush_i did not immediately suppress held out_v_o");
    @(negedge clk_i);
    flush_i = 1'b0;
    link_sif_i.fwd.ready_and_rev = 1'b1;
    #1;
    if (link_sif_o.fwd.v !== 1'b0 || out_credits_used_o !== 6'd1)
      fail("Phase 4d: flushed held request was not cleared or corrupted out_credits_used_o");

    // Return the credit from Phase 3
    r_pkt = '0;
    r_pkt.pkt_type = e_return_credit;
    r_pkt.x_cord = {pod_x_i, my_x_i};
    r_pkt.y_cord = {pod_y_i, my_y_i};
    link_sif_i.rev.v = 1'b1;
    link_sif_i.rev.data = r_pkt;
    @(negedge clk_i);
    link_sif_i.rev.v = 1'b0;
    @(negedge clk_i);
    if (out_credits_used_o !== 6'd0) fail("Phase 4e: credit return did not restore out_credits_used_o to 0");

    // -------------------------------------------------------------------------
    // Phase 5: network_tx returned_yumi_o guard & response routing
    // -------------------------------------------------------------------------
    int_remote_load_resp_yumi_i = 1'b1;
    float_remote_load_resp_yumi_i = 1'b1;
    @(negedge clk_i);
    int_remote_load_resp_yumi_i = 1'b0;
    float_remote_load_resp_yumi_i = 1'b0;
    // Now enqueue an int_wb return packet; if returned_yumi_o was asserted when returned_v_i==0, FIFO pointers would be corrupted
    r_pkt = '0;
    r_pkt.pkt_type = e_return_int_wb;
    r_pkt.data = 32'h1122_3344;
    r_pkt.reg_id = 5'd7;
    r_pkt.x_cord = {pod_x_i, my_x_i};
    r_pkt.y_cord = {pod_y_i, my_y_i};
    link_sif_i.rev.v = 1'b1;
    link_sif_i.rev.data = r_pkt;
    @(negedge clk_i);
    link_sif_i.rev.v = 1'b0;
    #1;
    if (!int_remote_load_resp_v_o || int_remote_load_resp_data_o !== 32'h1122_3344 || int_remote_load_resp_rd_o !== 5'd7)
      fail("Phase 5: int_remote_load_resp not presented properly after idle yumi assertion");
    int_remote_load_resp_yumi_i = 1'b1;
    @(negedge clk_i);
    int_remote_load_resp_yumi_i = 1'b0;

    // -------------------------------------------------------------------------
    // Phase 6: bsg_manycore_endpoint_standard pending-response lock, same-cycle
    // handoff, spurious returning_v_i suppression, and amoswap lock preservation
    // -------------------------------------------------------------------------
    // 6a: Spurious returning_v_i when idle must NOT emit a return packet
    returning_v_i = 1'b1;
    returning_data_i = 32'hbad0_0bad;
    #1;
    if (link_sif_o.rev.v !== 1'b0)
      fail("Phase 6a: spurious returning_v_i when no request is pending must be ignored");
    @(negedge clk_i);
    returning_v_i = 1'b0;

    // 6b: Enqueue two back-to-back incoming load requests from different sources into endpoint
    req1 = '0;
    req1.addr = 28'h000_0010;
    req1.op_v2 = e_remote_load;
    req1.reg_id.reg_id = 5'd3;
    req1.src_x_cord = 7'h11;
    req1.src_y_cord = 7'h22;
    req1.x_cord = {pod_x_i, my_x_i};
    req1.y_cord = {pod_y_i, my_y_i};

    req2 = '0;
    req2.addr = 28'h000_0020;
    req2.op_v2 = e_remote_load;
    req2.reg_id.reg_id = 5'd19;
    req2.src_x_cord = 7'h33;
    req2.src_y_cord = 7'h44;
    req2.x_cord = {pod_x_i, my_x_i};
    req2.y_cord = {pod_y_i, my_y_i};

    link_sif_i.fwd.v = 1'b1;
    link_sif_i.fwd.data = req1;
    @(negedge clk_i);
    link_sif_i.fwd.data = req2;
    @(negedge clk_i);
    link_sif_i.fwd.v = 1'b0;

    // Accept req1 on in_v_o && in_yumi_i, but delay returning_v_i by 3 cycles while keeping in_yumi_i=1!
    if (!in_v_o || in_addr_o !== 28'h000_0010) fail("Phase 6b: req1 not presented at in_v_o");
    in_yumi_i = 1'b1;
    @(negedge clk_i); // req1 accepted at this posedge; resp_pending_r becomes 1
    #1;
    // While returning_v_i == 0, in_v_o MUST be 0 so req2 cannot overwrite return_info_r!
    if (in_v_o !== 1'b0)
      fail("Phase 6b: in_v_o remained high while req1 response is still pending");
    @(negedge clk_i);
    #1;
    if (in_v_o !== 1'b0)
      fail("Phase 6b: in_v_o asserted on second wait cycle before returning_v_i");

    // 6c: Assert returning_v_i = 1 while in_yumi_i = 1: must emit req1 response AND accept req2 on the SAME cycle!
    returning_v_i = 1'b1;
    returning_data_i = 32'hca11_ab1e;
    #1;
    if (!link_sif_o.rev.v) fail("Phase 6c: req1 response not driven on link_sif_o.rev.v");
    r_pkt = link_sif_o.rev.data;
    if (r_pkt.x_cord !== 7'h11 || r_pkt.y_cord !== 7'h22 || r_pkt.reg_id !== 5'd3 || r_pkt.data !== 32'hca11_ab1e)
      fail("Phase 6c: req1 return_info_r was overwritten or corrupted");
    if (in_v_o !== 1'b1 || in_addr_o !== 28'h000_0020)
      fail("Phase 6c: same-cycle handoff failed to present req2 on in_v_o when returning_v_i asserted");

    @(negedge clk_i); // req1 response sent AND req2 accepted on this posedge!
    in_yumi_i = 1'b0;
    returning_v_i = 1'b0;
    @(negedge clk_i); // wait 1 cycle before returning req2 data
    returning_v_i = 1'b1;
    returning_data_i = 32'h5ec0_4d02;
    #1;
    r_pkt = link_sif_o.rev.data;
    if (!link_sif_o.rev.v || r_pkt.x_cord !== 7'h33 || r_pkt.y_cord !== 7'h44 || r_pkt.reg_id !== 5'd19 || r_pkt.data !== 32'h5ec0_4d02)
      fail("Phase 6c: req2 response metadata or data mismatch");
    @(negedge clk_i);
    returning_v_i = 1'b0;

    // 6d: e_remote_amoswap lock preservation across multi-cycle gap
    req1 = '0;
    req1.op_v2 = e_remote_amoswap;
    req1.payload.data = 32'h0000_0001; // set lock to 1, old lock is 0
    req1.reg_id.reg_id = 5'd4;
    req1.src_x_cord = 7'h05;
    req1.src_y_cord = 7'h06;
    link_sif_i.fwd.v = 1'b1;
    link_sif_i.fwd.data = req1;
    @(negedge clk_i); // enqueued into endpoint fwd fifo
    link_sif_i.fwd.v = 1'b0;
    @(negedge clk_i); // dequeued by amoswap; lock_v_r=1, lock_return_r=0, lock_r=1
    #1;
    r_pkt = link_sif_o.rev.data;
    if (!link_sif_o.rev.v || r_pkt.data !== 32'd0 || r_pkt.reg_id !== 5'd4)
      fail("Phase 6d: first amoswap(1) must return previous lock value 0");
    repeat (3) @(negedge clk_i); // wait 3 idle cycles; lock_r is 1
    req1.payload.data = 32'h0000_0000; // swap 0 into lock, should return previous lock value 1
    req1.reg_id.reg_id = 5'd8;
    link_sif_i.fwd.v = 1'b1;
    link_sif_i.fwd.data = req1;
    @(negedge clk_i);
    link_sif_i.fwd.v = 1'b0;
    @(negedge clk_i);
    #1;
    r_pkt = link_sif_o.rev.data;
    if (!link_sif_o.rev.v || r_pkt.data !== 32'd1 || r_pkt.reg_id !== 5'd8)
      fail("Phase 6d: second amoswap(0) must return previous lock value 1");
    @(negedge clk_i);

    // -------------------------------------------------------------------------
    // Phase 7: Seeded random stress of LSU + network_tx + endpoint
    // -------------------------------------------------------------------------
    for (int iter = 0; iter < 60; iter++) begin
      int unsigned rnd = $urandom(seed + iter * 19 + 7);
      exe_decode_i = '0;
      exe_decode_i.is_load_op = 1'b1;
      exe_decode_i.is_byte_op = (rnd[1:0] == 2'd1);
      exe_decode_i.is_hex_op  = (rnd[1:0] == 2'd2);
      exe_rs1_i = {1'b1, rnd[30:0]}; // DRAM range
      mem_offset_i = rnd[15:4];
      exe_rd_i = rnd[20:16];
      link_sif_i.fwd.ready_and_rev = rnd[2];
      @(negedge clk_i);
      if (!link_sif_i.fwd.ready_and_rev) begin
        exp_pkt = link_sif_o.fwd.data;
        exe_rs1_i = ~exe_rs1_i;
        mem_offset_i = ~mem_offset_i;
        #1;
        if (!link_sif_o.fwd.v || link_sif_o.fwd.data !== exp_pkt)
          fail("Phase 7: random stall-lock check failed");
        link_sif_i.fwd.ready_and_rev = 1'b1;
        @(negedge clk_i);
      end
      exe_decode_i = '0;
      // Return credit to keep counter clean
      r_pkt = '0;
      r_pkt.pkt_type = e_return_credit;
      r_pkt.x_cord = {pod_x_i, my_x_i};
      r_pkt.y_cord = {pod_y_i, my_y_i};
      link_sif_i.rev.v = 1'b1;
      link_sif_i.rev.data = r_pkt;
      @(negedge clk_i);
      link_sif_i.rev.v = 1'b0;
      @(negedge clk_i);
    end

    $display("PASS_CASE_0033 seed=%0d", seed);
    $finish(0);
  end
endmodule
