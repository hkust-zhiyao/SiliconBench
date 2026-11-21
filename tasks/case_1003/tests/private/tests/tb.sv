`include "prim_assert.sv"

module tb;
  import kmac_pkg::*;
  import sha3_pkg::L128;
  import sha3_pkg::L224;
  import sha3_pkg::L256;
  import sha3_pkg::L384;
  import sha3_pkg::L512;
  import sha3_pkg::Sha3;
  import sha3_pkg::Shake;
  import sha3_pkg::CShake;

  localparam int OutWidth = 32;
  localparam bit EnMasking = 1'b0;
  localparam int Share = 1;
  localparam int MsgDepth = 2;
  localparam int MsgDepthW = $clog2(MsgDepth+1);

  logic clk_i;
  logic rst_ni;

  sha3_pkg::sha3_mode_e       cfg_mode_i;
  sha3_pkg::keccak_strength_e cfg_strength_i;
  logic                       kmac_en_i;
  logic                       cfg_sideload_i;
  logic [47:0]                cfg_prefix_6B_i;
  logic                       cfg_en_unsupported_modestrength_i;
  logic                       entropy_ready_pulse_i;

  kmac_cmd_e                  sw_cmd_i;
  kmac_cmd_e                  sw_cmd_o;
  logic                       app_active_i;
  prim_mubi_pkg::mubi4_t      sha3_absorbed_i;
  prim_mubi_pkg::mubi4_t      sha3_stopped_i;
  logic                       sha3_stop_error_i;
  logic                       keccak_done_i;
  lc_ctrl_pkg::lc_tx_t        lc_escalate_en_i;
  logic                       err_processed_i;
  prim_mubi_pkg::mubi4_t      clear_after_error_i;

  logic                       fifo_valid_i;
  logic [OutWidth-1:0]        fifo_data_i [Share];
  logic [OutWidth-1:0]        fifo_strb_i;
  logic                       fifo_ready_o;
  logic                       fifo_bypass_i;

  logic                       msg_valid_o;
  logic [OutWidth-1:0]        msg_data_o [Share];
  logic [OutWidth/8-1:0]      msg_strb_o;
  logic                       msg_ready_i;

  logic                       fifo_empty_o;
  logic                       fifo_full_o;
  logic [MsgDepthW-1:0]       fifo_depth_o;
  logic                       flush_done_o;

  kmac_pkg::err_t             errchk_error_o;
  kmac_pkg::err_t             msgfifo_error_o;
  logic                       sparse_fsm_error_o;

  kmac_msg_err_top #(
    .OutWidth (OutWidth),
    .EnMasking(EnMasking),
    .MsgDepth (MsgDepth)
  ) dut (
    .clk_i                            (clk_i),
    .rst_ni                           (rst_ni),
    .cfg_mode_i                       (cfg_mode_i),
    .cfg_strength_i                   (cfg_strength_i),
    .kmac_en_i                        (kmac_en_i),
    .cfg_sideload_i                   (cfg_sideload_i),
    .cfg_prefix_6B_i                  (cfg_prefix_6B_i),
    .cfg_en_unsupported_modestrength_i(cfg_en_unsupported_modestrength_i),
    .entropy_ready_pulse_i            (entropy_ready_pulse_i),
    .sw_cmd_i                         (sw_cmd_i),
    .sw_cmd_o                         (sw_cmd_o),
    .app_active_i                     (app_active_i),
    .sha3_absorbed_i                  (sha3_absorbed_i),
    .sha3_stopped_i                   (sha3_stopped_i),
    .sha3_stop_error_i                (sha3_stop_error_i),
    .keccak_done_i                    (keccak_done_i),
    .lc_escalate_en_i                 (lc_escalate_en_i),
    .err_processed_i                  (err_processed_i),
    .clear_after_error_i              (clear_after_error_i),
    .fifo_valid_i                     (fifo_valid_i),
    .fifo_data_i                      (fifo_data_i),
    .fifo_strb_i                      (fifo_strb_i),
    .fifo_ready_o                     (fifo_ready_o),
    .fifo_bypass_i                    (fifo_bypass_i),
    .msg_valid_o                      (msg_valid_o),
    .msg_data_o                       (msg_data_o),
    .msg_strb_o                       (msg_strb_o),
    .msg_ready_i                      (msg_ready_i),
    .fifo_empty_o                     (fifo_empty_o),
    .fifo_full_o                      (fifo_full_o),
    .fifo_depth_o                     (fifo_depth_o),
    .flush_done_o                     (flush_done_o),
    .errchk_error_o                   (errchk_error_o),
    .msgfifo_error_o                  (msgfifo_error_o),
    .sparse_fsm_error_o               (sparse_fsm_error_o)
  );

  initial clk_i = 1'b0;
  always #5 clk_i = ~clk_i;

  task automatic fail(input string msg);
    $display("FAIL: %s at t=%0t", msg, $time);
    $finish(1);
  endtask

  task automatic clear_inputs();
    cfg_mode_i                        = CShake;
    cfg_strength_i                    = L256;
    kmac_en_i                         = 1'b1;
    cfg_sideload_i                    = 1'b0;
    cfg_prefix_6B_i                   = EncodedStringKMAC;
    cfg_en_unsupported_modestrength_i = 1'b0;
    entropy_ready_pulse_i             = 1'b0;
    sw_cmd_i                          = CmdNone;
    app_active_i                      = 1'b0;
    sha3_absorbed_i                   = prim_mubi_pkg::MuBi4False;
    sha3_stopped_i                    = prim_mubi_pkg::MuBi4False;
    sha3_stop_error_i                 = 1'b0;
    keccak_done_i                     = 1'b0;
    lc_escalate_en_i                  = lc_ctrl_pkg::Off;
    err_processed_i                   = 1'b0;
    clear_after_error_i               = prim_mubi_pkg::MuBi4False;
    fifo_valid_i                      = 1'b0;
    fifo_data_i[0]                    = '0;
    fifo_strb_i                       = '0;
    fifo_bypass_i                     = 1'b0;
    msg_ready_i                       = 1'b0;
  endtask

  int seed = 1;

  initial begin
    void'($value$plusargs("seed=%d", seed));
    rst_ni = 1'b0;
    clear_inputs();
    repeat (4) @(posedge clk_i);
    @(negedge clk_i);
    rst_ni = 1'b1;

    // -------------------------------------------------------------------------
    // Phase 1: kmac_errchk command gating when app_active_i or block_swcmd is high
    // -------------------------------------------------------------------------
    // 1a: In StIdle, if app_active_i == 1 and sw_cmd_i == CmdStart, sw_cmd_o must be CmdNone
    app_active_i = 1'b1;
    sw_cmd_i = CmdStart;
    @(negedge clk_i);
    if (sw_cmd_o !== CmdNone)
      fail("Phase 1a: sw_cmd_o must be CmdNone when app_active_i blocks CmdStart in StIdle");
    app_active_i = 1'b0;

    // 1b: Prefix check in StIdle -> StMsgFeed when kmac_en_i == 1 and cfg_prefix_6B_i != EncodedStringKMAC
    cfg_prefix_6B_i = 48'h1234_5678_9abc;
    sw_cmd_i = CmdStart;
    #1;
    if (!errchk_error_o.valid || errchk_error_o.code !== ErrIncorrectFunctionName)
      fail("Phase 1b: ErrIncorrectFunctionName not reported on mismatched cfg_prefix_6B_i");
    cfg_prefix_6B_i = EncodedStringKMAC;
    #1;
    if (errchk_error_o.valid)
      fail("Phase 1b: unexpected error with valid EncodedStringKMAC");

    // 1c: Accept valid CmdStart -> StMsgFeed, then test blocked command resets sw_cmd_o to CmdNone!
    @(negedge clk_i); // StIdle -> StMsgFeed, sw_cmd_o <= CmdStart
    if (sw_cmd_o !== CmdStart)
      fail("Phase 1c: valid CmdStart was not latched into sw_cmd_o");
    // Now in StMsgFeed, issue an illegal command (e.g. CmdManualRun -> err_swsequence=1, block_swcmd=1)
    // On the very next clock edge, sw_cmd_o MUST clear to CmdNone instead of holding CmdStart!
    sw_cmd_i = CmdManualRun;
    #1;
    if (!errchk_error_o.valid || errchk_error_o.code !== ErrSwCmdSequence)
      fail("Phase 1c: ErrSwCmdSequence not flagged for CmdManualRun in StMsgFeed");
    @(negedge clk_i);
    if (sw_cmd_o !== CmdNone)
      fail("Phase 1c: sw_cmd_o held previous CmdStart instead of clearing to CmdNone when block_swcmd=1");

    // 1d: Sideload save/restore error blocking (cfg_sideload_i && CmdStop in StMsgFeed)
    cfg_sideload_i = 1'b1;
    sw_cmd_i = CmdStop;
    #1;
    if (!errchk_error_o.valid || errchk_error_o.code !== ErrSwSaveRestoreSideload)
      fail("Phase 1d: ErrSwSaveRestoreSideload not reported on CmdStop with cfg_sideload_i=1");
    @(negedge clk_i);
    if (sw_cmd_o !== CmdNone)
      fail("Phase 1d: sw_cmd_o must be CmdNone when err_sideload blocks CmdStop");
    cfg_sideload_i = 1'b0;
    sw_cmd_i = CmdNone;
    @(negedge clk_i);

    // -------------------------------------------------------------------------
    // Phase 2: Byte-granular packing (non-zero leading byte offset + simultaneous ack_in & ack_out)
    // -------------------------------------------------------------------------
    // Push 2 bytes at upper byte lanes [23:8] (mask 32'h00ff_ff00): should right-align to [15:0]
    fifo_valid_i = 1'b1;
    fifo_data_i[0] = 32'h00b2_a100;
    fifo_strb_i = 32'h00ff_ff00;
    if (!fifo_ready_o) fail("Phase 2a: fifo_ready_o not high in FlushIdle");
    @(negedge clk_i); // pos_b_q = 2 bytes ({b2, a1})

    // Push 2 bytes at upper byte lanes [31:16] (mask 32'hffff_0000): pos_b_with_in = 4 bytes -> 1 full word {d4, c3, b2, a1} (pos_b_q == 4 <= OutB, so ready_o == 1 AND valid_o == 1!)
    fifo_data_i[0] = 32'hd4c3_0000;
    fifo_strb_i = 32'hffff_0000;
    @(negedge clk_i); // now pos_b_q = 4 bytes; packer valid_o = 1 AND ready_o = 1!
    // Simultaneously push 3 bytes (mask 32'h00ff_ffff, data 32'h0033_2211) while packer drains into msgfifo (ack_in && ack_out = 2'b11)!
    fifo_data_i[0] = 32'h0033_2211;
    fifo_strb_i = 32'h00ff_ffff;
    @(negedge clk_i); // word 1 ({d4, c3, b2, a1}) pushed into u_msgfifo; pos_b_q = 4 + 3 - 4 = 3 bytes ({33, 22, 11})!
    // Now push 2 bytes ({44, e5} at lanes [23:8], mask 32'h00ff_ff00): pos_b_with_in = 3 + 2 = 5 bytes -> word 2 ({e5, 33, 22, 11}) + 1 byte remnant {44}!
    fifo_data_i[0] = 32'h0044_e500;
    fifo_strb_i = 32'h00ff_ff00;
    @(negedge clk_i);
    fifo_valid_i = 1'b0;
    fifo_strb_i = '0;
    @(negedge clk_i); // word 2 ({e5, 33, 22, 11}) pushed into u_msgfifo; pos_b_q = 1 byte ({44})!

    // Read word 1 from msg_valid_o
    if (!msg_valid_o || msg_data_o[0] !== 32'hd4c3_b2a1 || msg_strb_o !== 4'b1111)
      fail($sformatf("Phase 2b: word 1 mismatch got data=%h strb=%b", msg_data_o[0], msg_strb_o));
    msg_ready_i = 1'b1;
    @(negedge clk_i);
    #1;
    // Read word 2 from msg_valid_o
    if (!msg_valid_o || msg_data_o[0] !== 32'he533_2211 || msg_strb_o !== 4'b1111)
      fail($sformatf("Phase 2c: word 2 mismatch got data=%h strb=%b", msg_data_o[0], msg_strb_o));
    @(negedge clk_i);
    msg_ready_i = 1'b0;

    // -------------------------------------------------------------------------
    // Phase 3: Flush sequence & blocking incoming writes during flush / FlushClear
    // -------------------------------------------------------------------------
    // Issue CmdProcess to trigger flush_req (1 pulse cycle)
    sw_cmd_i = CmdProcess;
    @(negedge clk_i); // sw_cmd_o <= CmdProcess (flush_i = 1)
    sw_cmd_i = CmdNone;
    #1;
    // During flush_i == 1, fifo_ready_o MUST be 0!
    fifo_valid_i = 1'b1;
    fifo_data_i[0] = 32'hdead_beef;
    fifo_strb_i = 32'hffff_ffff;
    #1;
    if (fifo_ready_o !== 1'b0)
      fail("Phase 3a: fifo_ready_o must be 0 when flush_i is asserted");

    @(negedge clk_i); // flush_st == FlushPacker, packer in FlushSend
    #1;
    if (fifo_ready_o !== 1'b0)
      fail("Phase 3b: fifo_ready_o must remain 0 in FlushPacker/FlushSend");
    @(negedge clk_i); // remnant byte 0x44 flushed into u_msgfifo; packer pos_b_q == 0 -> flush_done_o = 1
    @(negedge clk_i); // flush_st == FlushFifo
    #1;
    if (fifo_ready_o !== 1'b0)
      fail("Phase 3c: fifo_ready_o must remain 0 in FlushFifo");

    // Drain the flushed partial word (1 byte: 0x0000_0044, strb 4'b0001)
    if (!msg_valid_o || msg_data_o[0][7:0] !== 8'h44 || msg_strb_o !== 4'b0001)
      fail($sformatf("Phase 3d: flushed remnant mismatch got data=%h strb=%b", msg_data_o[0], msg_strb_o));
    msg_ready_i = 1'b1;
    @(negedge clk_i); // u_msgfifo empties
    msg_ready_i = 1'b0;
    #1;
    if (flush_done_o !== 1'b1)
      fail("Phase 3e: flush_done_o did not assert when FlushFifo observed fifo_empty_o");
    @(negedge clk_i); // flush_st == FlushClear
    #1;
    if (fifo_ready_o !== 1'b0)
      fail("Phase 3f: fifo_ready_o must remain 0 in FlushClear before clear_i");
    fifo_valid_i = 1'b0;

    // Complete absorption and issue CmdDone to clear flush_st back to FlushIdle
    sha3_absorbed_i = prim_mubi_pkg::MuBi4True;
    @(negedge clk_i);
    sha3_absorbed_i = prim_mubi_pkg::MuBi4False;
    sw_cmd_i = CmdDone;
    @(negedge clk_i); // sw_cmd_o <= CmdDone -> clear_fifo = MuBi4True
    sw_cmd_i = CmdNone;
    @(negedge clk_i);
    #1;
    if (fifo_ready_o !== 1'b1 || !fifo_empty_o)
      fail("Phase 3g: msgfifo did not return to FlushIdle with fifo_ready_o=1 after CmdDone");

    // Verify that packer mask was cleared on flush_done so next partial write is clean
    sw_cmd_i = CmdStart;
    @(negedge clk_i);
    sw_cmd_i = CmdNone;
    fifo_valid_i = 1'b1;
    fifo_data_i[0] = 32'h0000_007a;
    fifo_strb_i = 32'h0000_00ff;
    @(negedge clk_i);
    fifo_valid_i = 1'b0;
    sw_cmd_i = CmdProcess;
    @(negedge clk_i);
    sw_cmd_i = CmdNone;
    repeat (3) @(negedge clk_i);
    if (!msg_valid_o || msg_strb_o !== 4'b0001 || msg_data_o[0][7:0] !== 8'h7a)
      fail($sformatf("Phase 3h: stale mask/data after prior flush: data=%h strb=%b", msg_data_o[0], msg_strb_o));

    // -------------------------------------------------------------------------
    // Phase 4: Mid-flush recovery via clear_after_error_i from FlushFifo
    // -------------------------------------------------------------------------
    // While msgfifo is still in FlushFifo (msg_valid_o == 1, not yet drained), assert clear_after_error_i!
    clear_after_error_i = prim_mubi_pkg::MuBi4True;
    @(negedge clk_i);
    clear_after_error_i = prim_mubi_pkg::MuBi4False;
    #1;
    if (!fifo_empty_o || fifo_ready_o !== 1'b1)
      fail("Phase 4a: clear_after_error_i did not reset msgfifo and flush_st from FlushFifo to FlushIdle");

    // -------------------------------------------------------------------------
    // Phase 5: Bypass mode flush forwarding
    // -------------------------------------------------------------------------
    fifo_bypass_i = 1'b1;
    sw_cmd_i = CmdStart;
    @(negedge clk_i);
    sw_cmd_i = CmdProcess;
    @(negedge clk_i); // sw_cmd_o == CmdProcess -> flush_req == 1
    #1;
    if (flush_done_o !== 1'b1)
      fail("Phase 5: bypass mode did not forward flush_i to flush_done_o");
    sw_cmd_i = CmdNone;
    fifo_bypass_i = 1'b0;
    clear_after_error_i = prim_mubi_pkg::MuBi4True;
    @(negedge clk_i);
    clear_after_error_i = prim_mubi_pkg::MuBi4False;
    @(negedge clk_i);

    // -------------------------------------------------------------------------
    // Phase 6: StStateWrite app_active_i preemption and lifecycle escalation
    // -------------------------------------------------------------------------
    sw_cmd_i = CmdStateWrite;
    @(negedge clk_i); // StIdle -> StStateWrite, sw_cmd_o == CmdStateWrite
    app_active_i = 1'b1;
    sw_cmd_i = CmdContinue;
    @(negedge clk_i); // app_active_i preempts StStateWrite -> StIdle, sw_cmd_o must be CmdNone!
    if (sw_cmd_o !== CmdNone)
      fail("Phase 6a: app_active_i in StStateWrite must force sw_cmd_o to CmdNone");
    app_active_i = 1'b0;
    sw_cmd_i = CmdNone;
    @(negedge clk_i);

    // Lifecycle escalation -> StTerminalError, sticky against clear_after_error_i
    lc_escalate_en_i = lc_ctrl_pkg::On;
    sw_cmd_i = CmdStart;
    @(negedge clk_i);
    #1;
    if (!sparse_fsm_error_o || sw_cmd_o !== CmdNone)
      fail("Phase 6b: lc_escalate_en_i must enter StTerminalError, assert sparse_fsm_error_o, and force sw_cmd_o=CmdNone");
    lc_escalate_en_i = lc_ctrl_pkg::Off;
    clear_after_error_i = prim_mubi_pkg::MuBi4True;
    @(negedge clk_i);
    #1;
    if (!sparse_fsm_error_o)
      fail("Phase 6c: StTerminalError must not exit on clear_after_error_i");

    $display("PASS_CASE_1003 seed=%0d", seed);
    $finish(0);
  end
endmodule
