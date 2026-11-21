// Testbench for OpenTitan Entropy Complex Command Subsystem (ot_entropy_cmd_top)

// Copyright lowRISC contributors (OpenTitan project).
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Description: CSRNG command staging module.
//
`include "prim_assert.sv"

module ref_csrng_cmd_stage import csrng_pkg::*; (
  input logic                        clk_i,
  input logic                        rst_ni,
  // Command input.
  input logic                        cs_enable_i,
  input logic                        cmd_stage_vld_i,
  input logic [InstIdWidth-1:0]      cmd_stage_shid_i,
  input logic [CmdBusWidth-1:0]      cmd_stage_bus_i,
  output logic                       cmd_stage_rdy_o,
  // Command checking interface.
  input logic                        reseed_cnt_reached_i,
  output logic                       reseed_cnt_alert_o,
  output logic                       invalid_cmd_seq_alert_o,
  output logic                       invalid_acmd_alert_o,
  // Generate abort request signals.
  input logic                        gen_abort_req_i,
  output logic                       gen_abort_invalid_o,
  // Command to arbiter.
  output logic                       cmd_arb_req_o,
  output logic                       cmd_arb_sop_o,
  output logic                       cmd_arb_mop_o,
  output logic                       cmd_arb_eop_o,
  input logic                        cmd_arb_gnt_i,
  output logic [CmdBusWidth-1:0]     cmd_arb_bus_o,
  // Ack from core.
  input logic                        cmd_ack_i,
  input csrng_cmd_sts_e              cmd_ack_sts_i,
  // Ack to app i/f.
  output logic                       cmd_stage_ack_o,
  output csrng_cmd_sts_e             cmd_stage_ack_sts_o,
  // Genbits from core.
  input logic                        genbits_vld_i,
  input logic [127:0]                genbits_bus_i,
  input logic                        genbits_fips_i,
  // Genbits to app i/f.
  output logic                       genbits_vld_o,
  input logic                        genbits_rdy_i,
  output logic [127:0]               genbits_bus_o,
  output logic                       genbits_fips_o,
  // Error indication.
  output logic [2:0]                 cmd_stage_sfifo_cmd_err_o,
  output logic [2:0]                 cmd_stage_sfifo_genbits_err_o,
  output logic                       cmd_gen_cnt_err_o,
  output logic                       cmd_stage_sm_err_o
);

  // Genbits parameters.
  localparam int GenBitsFifoWidth = 1 + BlkLen;
  localparam int GenBitsFifoDepth = 1;

  // Command FIFO.
  logic      [CmdBusWidth-1:0] sfifo_cmd_rdata;
  logic     [CmdFifoDepthLg:0] sfifo_cmd_depth;
  logic                        sfifo_cmd_wvld;
  logic                        sfifo_cmd_wrdy;
  logic      [CmdBusWidth-1:0] sfifo_cmd_wdata;
  logic                        sfifo_cmd_rrdy;
  logic                  [2:0] sfifo_cmd_err;
  logic                        sfifo_cmd_rvld;

  // Genbits FIFO.
  logic                        sfifo_genbits_clr;
  logic [GenBitsFifoWidth-1:0] sfifo_genbits_rdata;
  logic                        sfifo_genbits_wvld;
  logic                        sfifo_genbits_wrdy;
  logic [GenBitsFifoWidth-1:0] sfifo_genbits_wdata;
  logic                        sfifo_genbits_rrdy;
  logic                  [2:0] sfifo_genbits_err;
  logic                        sfifo_genbits_rvld;

  // Command signals.
  logic                  [3:0] cmd_len;
  logic                        cmd_fifo_zero;
  logic                        cmd_fifo_pop;
  logic                        cmd_len_dec;
  logic                        cmd_gen_cnt_dec;
  logic                        cmd_gen_1st_req;
  logic                        cmd_gen_inc_req;
  logic                        cmd_gen_cnt_last;
  logic                        cmd_final_ack;
  logic                        cmd_err_ack;
  logic                        cmd_gen_abort_req;
  logic                        cmd_gen_abort_ack;
  logic  [GenBitsCtrWidth-1:0] cmd_gen_cnt;
  csrng_cmd_sts_e              err_sts;
  logic                        reseed_cnt_exceeded;
  logic                        invalid_cmd_seq;
  logic                        invalid_acmd;
  logic                  [2:0] acmd;
  logic                        local_escalate;

  // Flops.
  logic           cmd_ack_q, cmd_ack_d;
  csrng_cmd_sts_e cmd_ack_sts_q, cmd_ack_sts_d;
  logic     [3:0] cmd_len_q, cmd_len_d;
  logic           cmd_gen_flag_q, cmd_gen_flag_d;
  logic           instantiated_d, instantiated_q;
  logic           gen_ongoing_q, gen_ongoing_d;
  logic           gen_abort_pending_q, gen_abort_pending_d;
  logic           gen_abort_inflight_q, gen_abort_inflight_d;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      cmd_ack_q            <= '0;
      cmd_ack_sts_q        <= CMD_STS_SUCCESS;
      cmd_len_q            <= '0;
      cmd_gen_flag_q       <= '0;
      instantiated_q       <= '0;
      gen_ongoing_q        <= '0;
      gen_abort_pending_q  <= '0;
      gen_abort_inflight_q <= '0;
    end else begin
      cmd_ack_q            <= cmd_ack_d;
      cmd_ack_sts_q        <= cmd_ack_sts_d;
      cmd_len_q            <= cmd_len_d;
      cmd_gen_flag_q       <= cmd_gen_flag_d;
      instantiated_q       <= instantiated_d;
      gen_ongoing_q        <= gen_ongoing_d;
      gen_abort_pending_q  <= gen_abort_pending_d;
      gen_abort_inflight_q <= gen_abort_inflight_d;
    end
  end

  assign cmd_stage_sfifo_cmd_err_o = sfifo_cmd_err;
  assign cmd_stage_sfifo_genbits_err_o = sfifo_genbits_err;

  //---------------------------------------------------------
  // Capture the transfer length of data behind the command.
  //---------------------------------------------------------

  prim_fifo_sync #(
    .Width(CmdBusWidth),
    .Pass(0),
    .Depth(CmdFifoDepth),
    .OutputZeroIfEmpty(1'b0)
  ) u_prim_fifo_cmd (
    .clk_i   (clk_i),
    .rst_ni  (rst_ni),
    .clr_i   (!cs_enable_i),
    .wvalid_i(sfifo_cmd_wvld),
    .wready_o(sfifo_cmd_wrdy),
    .wdata_i (sfifo_cmd_wdata),
    .rvalid_o(sfifo_cmd_rvld),
    .rready_i(sfifo_cmd_rrdy),
    .rdata_o (sfifo_cmd_rdata),
    .full_o  (),
    .depth_o (sfifo_cmd_depth),
    .err_o   ()
  );

  assign sfifo_cmd_wdata = cmd_stage_bus_i;

  assign sfifo_cmd_wvld = cs_enable_i && cmd_stage_rdy_o && cmd_stage_vld_i;

  assign sfifo_cmd_rrdy = cs_enable_i && cmd_fifo_pop;

  assign cmd_arb_bus_o =
        // pad,glast,id,f,clen,cmd
        cmd_gen_abort_req ? {15'b0,1'b0,cmd_stage_shid_i,12'(UNI)} :
        cmd_gen_inc_req   ? {15'b0,cmd_gen_cnt_last,cmd_stage_shid_i,12'(GEN)} :
        cmd_gen_1st_req   ? {15'b0,cmd_gen_cnt_last,cmd_stage_shid_i,sfifo_cmd_rdata[11:0]} :
        cmd_arb_mop_o     ? sfifo_cmd_rdata :
        '0;

  assign cmd_stage_rdy_o = sfifo_cmd_wrdy;

  assign sfifo_cmd_err =
         {( sfifo_cmd_wvld && !sfifo_cmd_wrdy),
          ( sfifo_cmd_rrdy && !sfifo_cmd_rvld),
          (!sfifo_cmd_wrdy && !sfifo_cmd_rvld)};


  // State machine controls.
  assign cmd_fifo_zero = (sfifo_cmd_depth == '0);
  assign cmd_len = sfifo_cmd_rdata[7:4];

  // Capture the length of csrng command.
  assign cmd_len_d =
         (!cs_enable_i) ? '0 :
         cmd_arb_sop_o ? cmd_len :
         cmd_len_dec ? (cmd_len_q-1) :
         cmd_len_q;

  // Capture the application command type.
  assign acmd = sfifo_cmd_rdata[2:0];

  // For gen commands, capture information from the original command for use later.
  assign cmd_gen_flag_d =
         (!cs_enable_i) ? '0 :
         cmd_gen_1st_req ? (acmd == GEN) :
         cmd_gen_flag_q;

  // SEC_CM: GEN_CMD.CTR.REDUN
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      cmd_gen_cnt <= {GenBitsCtrWidth{1'b1}};
    end else if (!cs_enable_i) begin
      cmd_gen_cnt <= {GenBitsCtrWidth{1'b1}};
    end else if (cmd_gen_1st_req) begin
      cmd_gen_cnt <= sfifo_cmd_rdata[12 +: GenBitsCtrWidth];
    end else if (cmd_gen_cnt_dec) begin
      cmd_gen_cnt <= cmd_gen_cnt - GenBitsCtrWidth'(1);
    end
  end
  assign cmd_gen_cnt_err_o = 1'b0;

  // For naming consistency.
  assign local_escalate = cmd_gen_cnt_err_o;

  //---------------------------------------------------------
  // state machine to process command
  //---------------------------------------------------------
  // Encoding generated with:
  // $ ./util/design/sparse-fsm-encode.py -d 3 -m 11 -n 8 \
  //     -s 170131814 --language=sv
  //
  // Hamming distance histogram:
  //
  //  0: --
  //  1: --
  //  2: --
  //  3: |||||||||||| (21.82%)
  //  4: |||||||||||||||||||| (36.36%)
  //  5: ||||||||||||||||| (30.91%)
  //  6: ||||| (9.09%)
  //  7: | (1.82%)
  //  8: --
  //
  // Minimum Hamming distance: 3
  // Maximum Hamming distance: 7
  // Minimum Hamming weight: 1
  // Maximum Hamming weight: 6
  //
  localparam int StateWidth = 8;
  typedef enum logic [StateWidth-1:0] {
    Idle      = 8'b11110101, // idle
    Flush     = 8'b01011011, // flush command FIFO and start over
    ArbGnt    = 8'b00011100, // general arbiter request
    SendSOP   = 8'b00000001, // send sop (start of packet)
    SendMOP   = 8'b01010110, // send mop (middle of packet)
    GenCmdChk = 8'b10001101, // gen cmd check
    CmdAck    = 8'b11000000, // wait for command ack
    GenReq    = 8'b10010011, // process gen requests
    GenArbGnt = 8'b11101110, // generate subsequent arb request
    GenSOP    = 8'b10111010, // generate subsequent request
    Error     = 8'b01100111  // illegal state reached and hang
  } state_e;

  // SEC_CM: CMD_STAGE.FSM.SPARSE
  state_e state_d, state_q;
  `PRIM_FLOP_SPARSE_FSM(u_state_regs, state_d, state_q, state_e, Idle)

  // Tracks if there is an ongoing GEN command.
  // While gen_ongoing_d is high GEN commands can be aborted, otherwise they are invalid.
  assign gen_ongoing_d =
         (!cs_enable_i)   ? 1'b0 :
         (state_q == GenSOP && cmd_gen_abort_req) ? 1'b0 :
         (cmd_gen_1st_req && (acmd == GEN)) ? 1'b1 :
         cmd_gen_cnt_last ? 1'b0 :
         gen_ongoing_q;

  // Latch an accepted GEN abort request until it is dispatched.
  // To avoid race conditions we latch the abort request until it is safe to send an UNI command.
  assign gen_abort_pending_d =
         (!cs_enable_i) ? 1'b0 :
         (state_q == GenSOP && cmd_gen_abort_req) ? 1'b0 :
         (gen_abort_req_i && gen_ongoing_d) ? 1'b1 :
         gen_abort_pending_q;

  // Mark the request that carries the abort, from dispatch until its ack is consumed.
  assign gen_abort_inflight_d =
         (!cs_enable_i) ? 1'b0 :
         (state_q == CmdAck && cmd_ack_i && gen_abort_inflight_q) ? 1'b0 :
         (state_q == GenSOP && cmd_gen_abort_req) ? 1'b1 :
         gen_abort_inflight_q;

  // An abort request is only meaningful while a GEN command is ongoing for this app,
  // otherwise trigger an alert.
  assign gen_abort_invalid_o = cs_enable_i && gen_abort_req_i && !gen_ongoing_d;

  always_comb begin
    state_d = state_q;
    cmd_fifo_pop = 1'b0;
    cmd_len_dec = 1'b0;
    cmd_gen_cnt_dec = 1'b0;
    cmd_gen_1st_req = 1'b0;
    cmd_gen_inc_req = 1'b0;
    cmd_gen_abort_req = 1'b0;
    cmd_gen_abort_ack = 1'b0;
    cmd_gen_cnt_last = 1'b0;
    cmd_final_ack = 1'b0;
    cmd_arb_req_o = 1'b0;
    cmd_arb_sop_o = 1'b0;
    cmd_arb_mop_o = 1'b0;
    cmd_arb_eop_o = 1'b0;
    cmd_stage_sm_err_o = 1'b0;
    cmd_err_ack = 1'b0;
    reseed_cnt_exceeded = 1'b0;
    invalid_cmd_seq = 1'b0;
    invalid_acmd = 1'b0;
    instantiated_d = instantiated_q;

    if (state_q == Error) begin
      // In case we are in the Error state we must ignore the local escalate and enable signals.
      cmd_stage_sm_err_o = 1'b1;
    end else if (local_escalate) begin
      // In case local escalate is high we must transition to the error state.
      state_d = Error;
    end else if (!cs_enable_i && state_q inside {Idle, Flush, ArbGnt, SendSOP, SendMOP, GenCmdChk,
                                                 CmdAck, GenReq, GenArbGnt, GenSOP}) begin
      // In case the module is disabled and we are in a legal state we must go into idle state.
      state_d = Idle;
      instantiated_d = 1'b0;
    end else begin
      // Otherwise do the state machine as normal.
      unique case (state_q)
        Idle: begin
          // Because of the if statement above we won't leave idle if enable is low.
          if (!cmd_fifo_zero) begin
            if (acmd == INS) begin
              if (!instantiated_q) begin
                state_d = ArbGnt;
                instantiated_d = 1'b1;
              end
              if (instantiated_q) begin
                cmd_err_ack = 1'b1;
                invalid_cmd_seq = 1'b1;
                state_d = Idle;
              end
            end else if (acmd == RES) begin
              if (instantiated_q) begin
                state_d = ArbGnt;
              end
              if (!instantiated_q) begin
                cmd_err_ack = 1'b1;
                invalid_cmd_seq = 1'b1;
                state_d = Idle;
              end
            end else if (acmd == GEN) begin
              if (instantiated_q) begin
                // If the issued command is GEN and the reseed count has already been reached,
                // send an ack with an error status response.
                if ((acmd == GEN) && reseed_cnt_reached_i) begin
                  cmd_err_ack = 1'b1;
                  reseed_cnt_exceeded = 1'b1;
                  state_d = Idle;
                end else begin
                  state_d = ArbGnt;
                end
              end
              if (!instantiated_q) begin
                cmd_err_ack = 1'b1;
                invalid_cmd_seq = 1'b1;
                state_d = Idle;
              end
            end else if (acmd == UPD) begin
              if (instantiated_q) begin
                state_d = ArbGnt;
              end
              if (!instantiated_q) begin
                cmd_err_ack = 1'b1;
                invalid_cmd_seq = 1'b1;
                state_d = Idle;
              end
            end else if (acmd == UNI) begin
              // Set the instantiation to zero.
              instantiated_d = 1'b0;
              state_d = ArbGnt;
            end else begin
              // Command was not supported.
              cmd_err_ack = 1'b1;
              invalid_acmd = 1'b1;
              state_d = Idle;
            end
            // If we received an invalid command, pop it from the FIFO. Afterwards, absorb any
            // additional data belonging to the same invalid command and empty the FIFO.
            if (cmd_err_ack) begin
              cmd_fifo_pop = 1'b1;
              state_d = Flush;
            end
          end
        end
        Flush: begin
          // Keep popping the FIFO until it's empty and we're not getting new command input.
          // The decision whether a command is invalid is taken based on the command header but
          // EDN might continue and send additional data belonging to the same command. We have
          // to absorb the full invalid command before we can continue.
          cmd_fifo_pop = sfifo_cmd_rvld;
          if (!sfifo_cmd_rvld && !cmd_stage_vld_i) begin
            state_d = Idle;
          end
        end
        ArbGnt: begin
          cmd_arb_req_o = 1'b1;
          if (cmd_arb_gnt_i) begin
            state_d = SendSOP;
          end
        end
        SendSOP: begin
          cmd_gen_1st_req = 1'b1;
          cmd_arb_sop_o = 1'b1;
          cmd_fifo_pop = 1'b1;
          if (sfifo_cmd_rdata[12 +: GenBitsCtrWidth] == GenBitsCtrWidth'(1)) begin
            cmd_gen_cnt_last = 1'b1;
          end
          if (cmd_len == '0) begin
            cmd_arb_eop_o = 1'b1;
            state_d = GenCmdChk;
          end else begin
            state_d = SendMOP;
          end
        end
        SendMOP: begin
          if (!cmd_fifo_zero) begin
            cmd_fifo_pop = 1'b1;
            cmd_len_dec = 1'b1;
            if (cmd_len_q == 4'h1) begin
              cmd_arb_mop_o = 1'b1;
              cmd_arb_eop_o = 1'b1;
              state_d = GenCmdChk;
            end else begin
              cmd_arb_mop_o = 1'b1;
            end
          end
        end
        GenCmdChk: begin
          if (cmd_gen_flag_q) begin
            cmd_gen_cnt_dec = 1'b1;
          end
          state_d = CmdAck;
        end
        CmdAck: begin
          if (cmd_ack_i) begin
            // The state database has successfully been updated.
            // In case of Generate commands, we get the generated bits one clock cycle before
            // receiving the ACK from the state database (from csrng_ctr_drbg_gen).
            if (gen_abort_inflight_q) begin
              // Acknowledge the aborted GEN command.
              instantiated_d = 1'b0;
              cmd_gen_abort_ack = 1'b1;
              state_d = Idle;
            end else begin
              state_d = GenReq;
            end
          end
        end
        GenReq: begin
          // Flag set if a gen request.
          if (cmd_gen_flag_q) begin
            if (gen_abort_pending_q) begin
              // GEN abort doesn't produce genbits so no need to wait for sfifo_genbits_wrdy.
              state_d = GenArbGnt;
            end else if (sfifo_genbits_wrdy) begin
              // Must stall if genbits fifo is not clear.
              if (cmd_gen_cnt == '0) begin
                cmd_final_ack = 1'b1;
                state_d = Idle;
              end else begin
                // Issue a subsequent gen request.
                state_d = GenArbGnt;
              end
            end
          end else begin
            // Ack for the non-gen request case.
            cmd_final_ack = 1'b1;
            state_d = Idle;
          end
        end
        GenArbGnt: begin
          cmd_arb_req_o = 1'b1;
          if (cmd_arb_gnt_i) begin
            state_d = GenSOP;
          end
        end
        GenSOP: begin
          cmd_arb_sop_o = 1'b1;
          cmd_arb_eop_o = 1'b1;
          state_d = GenCmdChk;
          if (gen_abort_pending_q) begin
            // Abort this instance instead of requesting another block.
            cmd_gen_abort_req = 1'b1;
          end else begin
            cmd_gen_inc_req = 1'b1;
            // Check for final genbits beat.
            if (cmd_gen_cnt == GenBitsCtrWidth'(1)) begin
              cmd_gen_cnt_last = 1'b1;
            end
          end
        end
        // Error: The error state is now covered by the if statement above.
        default: begin
          state_d = Error;
          cmd_stage_sm_err_o = 1'b1;
        end
      endcase // unique case (state_q)
    end
  end

  //---------------------------------------------------------
  // Genbits FIFO.
  //---------------------------------------------------------

  assign sfifo_genbits_rrdy = genbits_vld_o && genbits_rdy_i;

  logic genbits_vld_q;
  assign sfifo_genbits_wrdy = !genbits_vld_q;
  assign sfifo_genbits_rvld = genbits_vld_q;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      genbits_vld_q <= 1'b0;
    end else if (sfifo_genbits_clr) begin
      genbits_vld_q <= 1'b0;
    end else if (sfifo_genbits_wvld && !genbits_vld_q) begin
      genbits_vld_q <= 1'b1;
    end else if (sfifo_genbits_rrdy && genbits_vld_q) begin
      genbits_vld_q <= 1'b0;
    end
  end
  always_ff @(posedge clk_i) begin
    if (sfifo_genbits_wvld && !genbits_vld_q) begin
      sfifo_genbits_rdata <= sfifo_genbits_wdata;
    end
  end

  // Clear u_prim_fifo_genbits when CSRNG is disabled or on a GEN abort.
  assign sfifo_genbits_clr = !cs_enable_i || cmd_gen_abort_ack;

  assign sfifo_genbits_wdata = {genbits_fips_i,genbits_bus_i};

  assign sfifo_genbits_wvld = cs_enable_i && genbits_vld_i;

  assign genbits_vld_o = cs_enable_i && sfifo_genbits_rvld;
  assign {genbits_fips_o, genbits_bus_o} = sfifo_genbits_rdata;

  assign sfifo_genbits_err =
         {( sfifo_genbits_wvld && !sfifo_genbits_wrdy),
          ( sfifo_genbits_rrdy && !sfifo_genbits_rvld),
          (!sfifo_genbits_wrdy && !sfifo_genbits_rvld)};

  // We're only allowed to request more bits if the genbits FIFO has indeed space.
  // An abort request never produces another block, so it is exempt from this requirement.
  `ASSERT(CsrngCmdStageGenbitsFifoFull_A,
      (state_q == GenSOP) && !gen_abort_pending_q |-> sfifo_genbits_wrdy)

  // Pushes to the genbits FIFO outside of the GenCmdChk and CmdAck states or while handling a
  // command other than Generate are not allowed.
  `ASSERT(CsrngCmdStageGenbitsFifoPushExpected_A,
      sfifo_genbits_wvld |-> state_q inside {GenCmdChk, CmdAck} && cmd_gen_flag_q)

  //---------------------------------------------------------
  // Ack logic.
  //---------------------------------------------------------

  assign cmd_ack_d =
         (!cs_enable_i) ? '0 :
         cmd_final_ack || cmd_err_ack || cmd_gen_abort_ack;

  assign cmd_stage_ack_o = cmd_ack_q;

  assign err_sts = reseed_cnt_exceeded ? CMD_STS_RESEED_CNT_EXCEEDED :
                   invalid_cmd_seq     ? CMD_STS_INVALID_CMD_SEQ     :
                   invalid_acmd        ? CMD_STS_INVALID_ACMD        : CMD_STS_INVALID_ACMD;

  assign cmd_ack_sts_d =
         (!cs_enable_i) ? CMD_STS_SUCCESS :
         cmd_err_ack ? err_sts :
         cmd_gen_abort_ack ? CMD_STS_GEN_ABORTED :
         cmd_final_ack ? cmd_ack_sts_i :
         cmd_ack_sts_q;

  assign cmd_stage_ack_sts_o = cmd_ack_sts_q;

  assign reseed_cnt_alert_o = reseed_cnt_exceeded;
  assign invalid_cmd_seq_alert_o = invalid_cmd_seq;
  assign invalid_acmd_alert_o = invalid_acmd;

  // Make sure that the state machine has a stable error state. This means that after the error
  // state is entered it will not exit it unless a reset signal is received.
  `ASSERT(CsrngCmdStageErrorStStable_A, state_q == Error |=> $stable(state_q))
  // If in error state, the error output must be high.
  `ASSERT(CsrngCmdStageErrorOutput_A,   state_q == Error |-> cmd_stage_sm_err_o)

endmodule

// Copyright lowRISC contributors (OpenTitan project).
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Description: edn csrng application request state machine module
//
//   does hardware-based csrng app interface command requests

`include "prim_assert.sv"

module ref_edn_main_sm import edn_pkg::*;
(
  input logic                   clk_i,
  input logic                   rst_ni,

  input logic                   edn_enable_i,
  input logic                   boot_req_mode_i,
  input logic                   auto_req_mode_i,
  input logic                   sw_cmd_req_load_i,
  output logic                  sw_cmd_mode_o,
  output logic                  boot_wr_ins_cmd_o,
  output logic                  boot_send_ins_cmd_o,
  output logic                  boot_wr_gen_cmd_o,
  output logic                  boot_wr_uni_cmd_o,
  output logic                  accept_sw_cmds_pulse_o,
  output logic                  main_sm_done_pulse_o,
  input logic                   csrng_cmd_ack_i,
  output logic                  capt_gencmd_fifo_cnt_o,
  output logic                  send_gencmd_o,
  input logic                   max_reqs_cnt_zero_i,
  output logic                  capt_rescmd_fifo_cnt_o,
  output logic                  send_rescmd_o,
  input logic                   cmd_sent_i,
  output logic                  auto_req_mode_busy_o,
  output logic [StateWidth-1:0] main_sm_state_o,
  input logic                   csrng_ack_err_i,
  output logic                  reject_csrng_entropy_o,
  input logic                   local_escalate_i,
  output logic                  main_sm_err_o
);

  state_e state_d, state_q;

  `PRIM_FLOP_SPARSE_FSM(u_state_regs, state_d, state_q, state_e, Idle)

  assign main_sm_state_o = state_q;

  always_comb begin
    state_d                = state_q;
    boot_wr_ins_cmd_o      = 1'b0;
    boot_send_ins_cmd_o    = 1'b0;
    boot_wr_gen_cmd_o      = 1'b0;
    boot_wr_uni_cmd_o      = 1'b0;
    accept_sw_cmds_pulse_o = 1'b0;
    auto_req_mode_busy_o   = 1'b0;
    capt_gencmd_fifo_cnt_o = 1'b0;
    send_gencmd_o          = 1'b0;
    capt_rescmd_fifo_cnt_o = 1'b0;
    send_rescmd_o          = 1'b0;
    main_sm_done_pulse_o   = 1'b0;
    main_sm_err_o          = 1'b0;
    reject_csrng_entropy_o = 1'b0;
    sw_cmd_mode_o         = 1'b0;
    unique case (state_q)
      Idle: begin
        if (boot_req_mode_i && edn_enable_i) begin
          state_d = BootLoadIns;
        end else if (auto_req_mode_i && edn_enable_i) begin
          accept_sw_cmds_pulse_o = 1'b1;
          sw_cmd_mode_o = 1'b1;
          state_d = AutoLoadIns;
        end else if (edn_enable_i) begin
          main_sm_done_pulse_o = 1'b1;
          accept_sw_cmds_pulse_o = 1'b1;
          sw_cmd_mode_o = 1'b1;
          state_d = SWPortMode;
        end
      end
      BootLoadIns: begin
        boot_wr_ins_cmd_o = 1'b1;
        boot_send_ins_cmd_o = 1'b1;
        state_d = BootInsAckWait;
      end
      BootInsAckWait: begin
        boot_send_ins_cmd_o = 1'b1;
        if (csrng_cmd_ack_i) begin
          state_d = BootLoadGen;
        end
      end
      BootLoadGen: begin
        boot_wr_gen_cmd_o = 1'b1;
        state_d = BootGenAckWait;
      end
      BootGenAckWait: begin
        if (csrng_cmd_ack_i) begin
          state_d = BootPulse;
        end
      end
      BootPulse: begin
        state_d = BootDone;
      end
      BootDone: begin
        if (!boot_req_mode_i) begin
          state_d = BootLoadUni;
        end
      end
      BootLoadUni: begin
        boot_wr_uni_cmd_o = 1'b1;
        state_d = BootUniAckWait;
      end
      BootUniAckWait: begin
        if (csrng_cmd_ack_i) begin
          main_sm_done_pulse_o = 1'b1;
          state_d = Idle;
        end
      end
      //-----------------------------------
      AutoLoadIns: begin
        sw_cmd_mode_o = 1'b1;
        if (sw_cmd_req_load_i) begin
          state_d = AutoFirstAckWait;
        end
      end
      AutoFirstAckWait: begin
        sw_cmd_mode_o = 1'b1;
        if (csrng_cmd_ack_i) begin
          state_d = AutoDispatch;
        end
      end
      AutoAckWait: begin
        auto_req_mode_busy_o = 1'b1;
        if (csrng_cmd_ack_i) begin
          state_d = AutoDispatch;
        end
      end
      AutoDispatch: begin
        auto_req_mode_busy_o = 1'b1;
        if (!auto_req_mode_i) begin
          main_sm_done_pulse_o = 1'b1;
          state_d = Idle;
        end else begin
          if (max_reqs_cnt_zero_i) begin
            state_d = AutoCaptReseedCnt;
          end else begin
            state_d = AutoCaptGenCnt;
          end
        end
      end
      AutoCaptGenCnt: begin
        auto_req_mode_busy_o = 1'b1;
        capt_gencmd_fifo_cnt_o = 1'b1;
        state_d = AutoSendGenCmd;
      end
      AutoSendGenCmd: begin
        auto_req_mode_busy_o = 1'b1;
        send_gencmd_o = 1'b1;
        if (cmd_sent_i) begin
          state_d = AutoAckWait;
        end
      end
      AutoCaptReseedCnt: begin
        auto_req_mode_busy_o = 1'b1;
        capt_rescmd_fifo_cnt_o = 1'b1;
        state_d = AutoSendReseedCmd;
      end
      AutoSendReseedCmd: begin
        auto_req_mode_busy_o = 1'b1;
        send_rescmd_o = 1'b1;
        if (cmd_sent_i) begin
          state_d = AutoAckWait;
        end
      end
      SWPortMode: begin
        sw_cmd_mode_o = 1'b1;
      end
      RejectCsrngEntropy: begin
        reject_csrng_entropy_o = 1'b1;
      end
      Error: begin
        main_sm_err_o = 1'b1;
      end
      default: begin
        state_d = Error;
        main_sm_err_o = 1'b1;
      end
    endcase

    if (local_escalate_i || csrng_ack_err_i) begin
      // Either move into RejectCsrngEntropy or Error but don't move out of Error as it's terminal.
      state_d = local_escalate_i ? Error :
                state_q == Error ? Error : RejectCsrngEntropy;
      // Tie off outputs, except for main_sm_err_o, auto_req_mode_busy_o, boot_send_ins_cmd_o,
      // sw_cmd_mode_o and reject_csrng_entropy_o.
      boot_wr_ins_cmd_o      = 1'b0;
      boot_wr_gen_cmd_o      = 1'b0;
      boot_wr_uni_cmd_o      = 1'b0;
      accept_sw_cmds_pulse_o = 1'b0;
      capt_gencmd_fifo_cnt_o = 1'b0;
      send_gencmd_o          = 1'b0;
      capt_rescmd_fifo_cnt_o = 1'b0;
      send_rescmd_o          = 1'b0;
      main_sm_done_pulse_o   = 1'b0;
    end else if (!edn_enable_i && state_q inside {BootLoadIns, BootInsAckWait, BootLoadGen,
                                                  BootGenAckWait, BootLoadUni, BootUniAckWait,
                                                  BootPulse, BootDone,
                                                  AutoLoadIns, AutoFirstAckWait, AutoAckWait,
                                                  AutoDispatch, AutoCaptGenCnt, AutoSendGenCmd,
                                                  AutoCaptReseedCnt, AutoSendReseedCmd,
                                                  SWPortMode, RejectCsrngEntropy
                                                 }) begin
      // Only go to idle if the state is legal and not Idle or Error.
      // Even when disabled, illegal states must result in a transition to Error.
      state_d = Idle;
      // Tie off outputs, except for main_sm_err_o.
      boot_wr_ins_cmd_o      = 1'b0;
      boot_send_ins_cmd_o    = 1'b0;
      boot_wr_gen_cmd_o      = 1'b0;
      boot_wr_uni_cmd_o      = 1'b0;
      accept_sw_cmds_pulse_o = 1'b0;
      auto_req_mode_busy_o   = 1'b0;
      capt_gencmd_fifo_cnt_o = 1'b0;
      send_gencmd_o          = 1'b0;
      capt_rescmd_fifo_cnt_o = 1'b0;
      send_rescmd_o          = 1'b0;
      sw_cmd_mode_o          = 1'b0;
      reject_csrng_entropy_o = 1'b0;
      main_sm_done_pulse_o   = 1'b1;
    end
  end

  // The `local_escalate_i` includes `main_sm_err_o`.
  // The following assertion ensures the Error state is stable until reset.
  // With `FpvSecCm` prefix, this assertion will added to weekly FPV sec_cm regression.
  `ASSERT(FpvSecCmErrorStEscalate_A, state_q == Error |-> local_escalate_i)

  // This assertion does not have `FpvSecCm` prefix because the sec_cm FPV environment will
  // blackbox the `prim_sparse_fsm` `state_q` output.
  `ASSERT(ErrorStStable_A, state_q == Error |=> $stable(state_q))
endmodule

// Copyright lowRISC contributors (OpenTitan project).
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Description: interface between a req/ack interface and a fifo
//

`include "prim_assert.sv"

module ref_edn_ack_sm (
  input logic                clk_i,
  input logic                rst_ni,

  input logic                enable_i,
  input logic                req_i,
  output logic               ack_o,
  input logic                local_escalate_i,
  input logic                fifo_not_empty_i,
  output logic               fifo_pop_o,
  output logic               fifo_clr_o,
  output logic               ack_sm_err_o
);

  // Encoding generated with:
  // $ ./util/design/sparse-fsm-encode.py -d 3 -m 4 -n 6 \
  //      -s 2299232677 --language=sv
  //
  // Hamming distance histogram:
  //
  //  0: --
  //  1: --
  //  2: --
  //  3: |||||||||||||||||||| (50.00%)
  //  4: ||||||||||||| (33.33%)
  //  5: |||||| (16.67%)
  //  6: --
  //
  // Minimum Hamming distance: 3
  // Maximum Hamming distance: 5
  // Minimum Hamming weight: 1
  // Maximum Hamming weight: 4
  //
  localparam int StateWidth = 9;
  typedef enum logic [StateWidth-1:0] {
    Disabled      = 9'b100110010, // Disabled
    EndPointClear = 9'b110001110, // Clear out end point before beginning
    Idle          = 9'b001011100, // idle (hamming distance = 3)
    DataWait      = 9'b011101011, // wait for data to return
    AckPls        = 9'b000100101, // signal ack to endpoint
    Error         = 9'b111010001  // illegal state reached and hang
  } state_e;
  state_e state_d, state_q;

  `PRIM_FLOP_SPARSE_FSM(u_state_regs, state_d, state_q, state_e, Disabled)

  always_comb begin
    state_d      = state_q;
    ack_o        = 1'b0;
    fifo_clr_o   = 1'b0;
    fifo_pop_o   = 1'b0;
    ack_sm_err_o = 1'b0;
    unique case (state_q)
      Disabled: begin
        if (enable_i) begin
          state_d = EndPointClear;
          fifo_clr_o = 1'b1;
        end
      end
      EndPointClear: begin
        state_d = Idle;
      end
      Idle: begin
        if (req_i) begin
          if (fifo_not_empty_i) begin
            fifo_pop_o = 1'b1;
            state_d = AckPls;
          end else begin
            state_d = DataWait;
          end
        end
      end
      DataWait: begin
        if (fifo_not_empty_i) begin
          state_d = AckPls;
        end
      end
      AckPls: begin
        ack_o = 1'b1;
        state_d = Idle;
      end
      Error: begin
        ack_sm_err_o = 1'b1;
      end
      default: begin
        ack_sm_err_o = 1'b1;
        state_d = Error;
      end
    endcase // unique case (state_q)

    // If local escalation is seen, transition directly to
    // error state.
    if (local_escalate_i) begin
      state_d = Error;
      // Tie off outputs, except for ack_sm_err_o.
      ack_o      = 1'b0;
      fifo_clr_o = 1'b0;
      fifo_pop_o = 1'b0;
    end else if (!enable_i && state_q inside {EndPointClear, Idle, DataWait, AckPls}) begin
      // Only disable if state is legal and not Disabled or Error.
      // Even when disabled, illegal states must result in a transition to Error.
      state_d = Disabled;
      // Tie off all outputs, except for ack_sm_err_o.
      ack_o        = 1'b0;
      fifo_pop_o   = 1'b0;
      fifo_clr_o   = 1'b0;
    end
  end

  // The `local_escalate_i` includes `ack_sm_err_o`.
  // The following assertion ensures the Error state is stable until reset.
  // With `FpvSecCm` prefix, this assertion will added to weekly FPV sec_cm regression.
  `ASSERT(FpvSecCmErrorStEscalate_A, state_q == Error |-> local_escalate_i)

  // This assertion does not have `FpvSecCm` prefix because the sec_cm FPV environment will
  // blackbox the `prim_sparse_fsm` `state_q` output.
  `ASSERT(AckSmErrorStStable_A,   state_q == Error |=> $stable(state_q))

endmodule

// Copyright lowRISC contributors (OpenTitan project).
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// OpenTitan Entropy Complex Command Staging, Auto-Request & Endpoint Ack Top (`ot_entropy_cmd_top`)

module ref_ot_entropy_cmd_top
  import csrng_pkg::*;
  import edn_pkg::*;
(
  input  logic                          clk_i,
  input  logic                          rst_ni,
  input  logic                          cs_enable_i,
  input  logic                          edn_enable_i,
  input  logic                          boot_req_mode_i,
  input  logic                          auto_req_mode_i,
  input  logic                          sw_cmd_req_load_i,
  input  logic                          max_reqs_cnt_zero_i,
  input  logic                          csrng_ack_err_i,
  input  logic                          local_escalate_i,
  output logic                          sw_cmd_mode_o,
  output logic                          boot_wr_ins_cmd_o,
  output logic                          boot_send_ins_cmd_o,
  output logic                          boot_wr_gen_cmd_o,
  output logic                          boot_wr_uni_cmd_o,
  output logic                          accept_sw_cmds_pulse_o,
  output logic                          main_sm_done_pulse_o,
  output logic                          capt_gencmd_fifo_cnt_o,
  output logic                          send_gencmd_o,
  output logic                          capt_rescmd_fifo_cnt_o,
  output logic                          send_rescmd_o,
  output logic                          auto_req_mode_busy_o,
  output logic [edn_pkg::StateWidth-1:0] edn_main_sm_state_o,
  output logic                          reject_csrng_entropy_o,
  output logic                          edn_main_sm_err_o,
  input  logic                          cmd_stage_vld_i,
  input  logic [InstIdWidth-1:0]        cmd_stage_shid_i,
  input  logic [CmdBusWidth-1:0]        cmd_stage_bus_i,
  output logic                          cmd_stage_rdy_o,
  input  logic                          reseed_cnt_reached_i,
  output logic                          reseed_cnt_alert_o,
  output logic                          invalid_cmd_seq_alert_o,
  output logic                          invalid_acmd_alert_o,
  input  logic                          gen_abort_req_i,
  output logic                          gen_abort_invalid_o,
  output logic                          cmd_arb_req_o,
  output logic                          cmd_arb_sop_o,
  output logic                          cmd_arb_mop_o,
  output logic                          cmd_arb_eop_o,
  output logic [CmdBusWidth-1:0]        cmd_arb_bus_o,
  input  logic                          cmd_entropy_avail_i,
  output logic                          cmd_entropy_req_o,
  output logic                          core_cmd_vld_o,
  input  logic                          core_cmd_rdy_i,
  output logic                          clr_adata_packer_o,
  input  logic                          cmd_complete_i,
  output logic [MainSmStateWidth-1:0]   csrng_main_sm_state_o,
  output logic                          csrng_main_sm_err_o,
  input  logic                          cmd_ack_i,
  input  csrng_cmd_sts_e                cmd_ack_sts_i,
  output logic                          cmd_stage_ack_o,
  output csrng_cmd_sts_e                cmd_stage_ack_sts_o,
  input  logic                          genbits_vld_i,
  input  logic [127:0]                  genbits_bus_i,
  input  logic                          genbits_fips_i,
  output logic                          genbits_vld_o,
  output logic [127:0]                  genbits_bus_o,
  output logic                          genbits_fips_o,
  input  logic                          ep_req_i,
  output logic                          ep_ack_o,
  output logic                          ep_fifo_clr_o,
  output logic                          ep_ack_sm_err_o,
  output logic [2:0]                    cmd_stage_sfifo_cmd_err_o,
  output logic [2:0]                    cmd_stage_sfifo_genbits_err_o,
  output logic                          cmd_gen_cnt_err_o,
  output logic                          cmd_stage_sm_err_o
);

  logic cmd_arb_gnt;
  logic ep_fifo_pop;
  logic cmd_sent;

  assign cmd_sent = cmd_stage_vld_i & cmd_stage_rdy_o;

  ref_edn_main_sm u_edn_main_sm (
    .clk_i                 (clk_i),
    .rst_ni                (rst_ni),
    .edn_enable_i          (edn_enable_i),
    .boot_req_mode_i       (boot_req_mode_i),
    .auto_req_mode_i       (auto_req_mode_i),
    .sw_cmd_req_load_i     (sw_cmd_req_load_i),
    .sw_cmd_mode_o         (sw_cmd_mode_o),
    .boot_wr_ins_cmd_o     (boot_wr_ins_cmd_o),
    .boot_send_ins_cmd_o   (boot_send_ins_cmd_o),
    .boot_wr_gen_cmd_o     (boot_wr_gen_cmd_o),
    .boot_wr_uni_cmd_o     (boot_wr_uni_cmd_o),
    .accept_sw_cmds_pulse_o(accept_sw_cmds_pulse_o),
    .main_sm_done_pulse_o  (main_sm_done_pulse_o),
    .csrng_cmd_ack_i       (cmd_stage_ack_o),
    .capt_gencmd_fifo_cnt_o(capt_gencmd_fifo_cnt_o),
    .send_gencmd_o         (send_gencmd_o),
    .max_reqs_cnt_zero_i   (max_reqs_cnt_zero_i),
    .capt_rescmd_fifo_cnt_o(capt_rescmd_fifo_cnt_o),
    .send_rescmd_o         (send_rescmd_o),
    .cmd_sent_i            (cmd_sent),
    .auto_req_mode_busy_o  (auto_req_mode_busy_o),
    .main_sm_state_o       (edn_main_sm_state_o),
    .csrng_ack_err_i       (csrng_ack_err_i | (cmd_stage_ack_o & (cmd_stage_ack_sts_o != CMD_STS_SUCCESS))),
    .reject_csrng_entropy_o(reject_csrng_entropy_o),
    .local_escalate_i      (local_escalate_i),
    .main_sm_err_o         (edn_main_sm_err_o)
  );

  ref_csrng_cmd_stage u_cmd_stage (
    .clk_i                        (clk_i),
    .rst_ni                       (rst_ni),
    .cs_enable_i                  (cs_enable_i),
    .cmd_stage_vld_i              (cmd_stage_vld_i),
    .cmd_stage_shid_i             (cmd_stage_shid_i),
    .cmd_stage_bus_i              (cmd_stage_bus_i),
    .cmd_stage_rdy_o              (cmd_stage_rdy_o),
    .reseed_cnt_reached_i         (reseed_cnt_reached_i),
    .reseed_cnt_alert_o           (reseed_cnt_alert_o),
    .invalid_cmd_seq_alert_o      (invalid_cmd_seq_alert_o),
    .invalid_acmd_alert_o         (invalid_acmd_alert_o),
    .gen_abort_req_i              (gen_abort_req_i),
    .gen_abort_invalid_o          (gen_abort_invalid_o),
    .cmd_arb_req_o                (cmd_arb_req_o),
    .cmd_arb_sop_o                (cmd_arb_sop_o),
    .cmd_arb_mop_o                (cmd_arb_mop_o),
    .cmd_arb_eop_o                (cmd_arb_eop_o),
    .cmd_arb_gnt_i                (cmd_arb_gnt),
    .cmd_arb_bus_o                (cmd_arb_bus_o),
    .cmd_ack_i                    (cmd_ack_i),
    .cmd_ack_sts_i                (cmd_ack_sts_i),
    .cmd_stage_ack_o              (cmd_stage_ack_o),
    .cmd_stage_ack_sts_o          (cmd_stage_ack_sts_o),
    .genbits_vld_i                (genbits_vld_i & ~reject_csrng_entropy_o),
    .genbits_bus_i                (genbits_bus_i),
    .genbits_fips_i               (genbits_fips_i),
    .genbits_vld_o                (genbits_vld_o),
    .genbits_rdy_i                (ep_fifo_pop),
    .genbits_bus_o                (genbits_bus_o),
    .genbits_fips_o               (genbits_fips_o),
    .cmd_stage_sfifo_cmd_err_o    (cmd_stage_sfifo_cmd_err_o),
    .cmd_stage_sfifo_genbits_err_o(cmd_stage_sfifo_genbits_err_o),
    .cmd_gen_cnt_err_o            (cmd_gen_cnt_err_o),
    .cmd_stage_sm_err_o           (cmd_stage_sm_err_o)
  );

  csrng_main_sm u_csrng_main_sm (
    .clk_i              (clk_i),
    .rst_ni             (rst_ni),
    .enable_i           (cs_enable_i),
    .acmd_avail_i       (cmd_arb_req_o),
    .acmd_accept_o      (cmd_arb_gnt),
    .acmd_i             (acmd_e'(cmd_arb_bus_o[2:0])),
    .acmd_eop_i         (cmd_arb_eop_o),
    .flag0_i            (cmd_arb_bus_o[8]),
    .cmd_entropy_req_o  (cmd_entropy_req_o),
    .cmd_entropy_avail_i(cmd_entropy_avail_i),
    .cmd_vld_o          (core_cmd_vld_o),
    .cmd_rdy_i          (core_cmd_rdy_i),
    .clr_adata_packer_o (clr_adata_packer_o),
    .cmd_complete_i     (cmd_complete_i),
    .local_escalate_i   (local_escalate_i | cmd_stage_sm_err_o | cmd_gen_cnt_err_o),
    .main_sm_state_o    (csrng_main_sm_state_o),
    .main_sm_err_o      (csrng_main_sm_err_o)
  );

  ref_edn_ack_sm u_edn_ack_sm (
    .clk_i           (clk_i),
    .rst_ni          (rst_ni),
    .enable_i        (edn_enable_i),
    .req_i           (ep_req_i),
    .ack_o           (ep_ack_o),
    .local_escalate_i(local_escalate_i | edn_main_sm_err_o),
    .fifo_not_empty_i(genbits_vld_o),
    .fifo_pop_o      (ep_fifo_pop),
    .fifo_clr_o      (ep_fifo_clr_o),
    .ack_sm_err_o    (ep_ack_sm_err_o)
  );

endmodule

module tb;
  import csrng_pkg::*;
  import edn_pkg::*;

  logic                          clk_i;
  logic                          rst_ni;
  logic                          cs_enable_i;
  logic                          edn_enable_i;
  logic                          boot_req_mode_i;
  logic                          auto_req_mode_i;
  logic                          sw_cmd_req_load_i;
  logic                          max_reqs_cnt_zero_i;
  logic                          csrng_ack_err_i;
  logic                          local_escalate_i;
  logic                          cmd_stage_vld_i;
  logic [InstIdWidth-1:0]        cmd_stage_shid_i;
  logic [CmdBusWidth-1:0]        cmd_stage_bus_i;
  logic                          reseed_cnt_reached_i;
  logic                          gen_abort_req_i;
  logic                          cmd_entropy_avail_i;
  logic                          core_cmd_rdy_i;
  logic                          cmd_complete_i;
  logic                          cmd_ack_i;
  csrng_cmd_sts_e                cmd_ack_sts_i;
  logic                          genbits_vld_i;
  logic [127:0]                  genbits_bus_i;
  logic                          genbits_fips_i;
  logic                          ep_req_i;

  // DUT vs Ref outputs
  logic                          dut_sw_cmd_mode_o, ref_sw_cmd_mode_o;
  logic                          dut_boot_wr_ins_cmd_o, ref_boot_wr_ins_cmd_o;
  logic                          dut_boot_send_ins_cmd_o, ref_boot_send_ins_cmd_o;
  logic                          dut_boot_wr_gen_cmd_o, ref_boot_wr_gen_cmd_o;
  logic                          dut_boot_wr_uni_cmd_o, ref_boot_wr_uni_cmd_o;
  logic                          dut_accept_sw_cmds_pulse_o, ref_accept_sw_cmds_pulse_o;
  logic                          dut_main_sm_done_pulse_o, ref_main_sm_done_pulse_o;
  logic                          dut_capt_gencmd_fifo_cnt_o, ref_capt_gencmd_fifo_cnt_o;
  logic                          dut_send_gencmd_o, ref_send_gencmd_o;
  logic                          dut_capt_rescmd_fifo_cnt_o, ref_capt_rescmd_fifo_cnt_o;
  logic                          dut_send_rescmd_o, ref_send_rescmd_o;
  logic                          dut_auto_req_mode_busy_o, ref_auto_req_mode_busy_o;
  logic [edn_pkg::StateWidth-1:0] dut_edn_main_sm_state_o, ref_edn_main_sm_state_o;
  logic                          dut_reject_csrng_entropy_o, ref_reject_csrng_entropy_o;
  logic                          dut_edn_main_sm_err_o, ref_edn_main_sm_err_o;
  logic                          dut_cmd_stage_rdy_o, ref_cmd_stage_rdy_o;
  logic                          dut_reseed_cnt_alert_o, ref_reseed_cnt_alert_o;
  logic                          dut_invalid_cmd_seq_alert_o, ref_invalid_cmd_seq_alert_o;
  logic                          dut_invalid_acmd_alert_o, ref_invalid_acmd_alert_o;
  logic                          dut_gen_abort_invalid_o, ref_gen_abort_invalid_o;
  logic                          dut_cmd_arb_req_o, ref_cmd_arb_req_o;
  logic                          dut_cmd_arb_sop_o, ref_cmd_arb_sop_o;
  logic                          dut_cmd_arb_mop_o, ref_cmd_arb_mop_o;
  logic                          dut_cmd_arb_eop_o, ref_cmd_arb_eop_o;
  logic [CmdBusWidth-1:0]        dut_cmd_arb_bus_o, ref_cmd_arb_bus_o;
  logic                          dut_cmd_entropy_req_o, ref_cmd_entropy_req_o;
  logic                          dut_core_cmd_vld_o, ref_core_cmd_vld_o;
  logic                          dut_clr_adata_packer_o, ref_clr_adata_packer_o;
  logic [MainSmStateWidth-1:0]   dut_csrng_main_sm_state_o, ref_csrng_main_sm_state_o;
  logic                          dut_csrng_main_sm_err_o, ref_csrng_main_sm_err_o;
  logic                          dut_cmd_stage_ack_o, ref_cmd_stage_ack_o;
  csrng_cmd_sts_e                dut_cmd_stage_ack_sts_o, ref_cmd_stage_ack_sts_o;
  logic                          dut_genbits_vld_o, ref_genbits_vld_o;
  logic [127:0]                  dut_genbits_bus_o, ref_genbits_bus_o;
  logic                          dut_genbits_fips_o, ref_genbits_fips_o;
  logic                          dut_ep_ack_o, ref_ep_ack_o;
  logic                          dut_ep_fifo_clr_o, ref_ep_fifo_clr_o;
  logic                          dut_ep_ack_sm_err_o, ref_ep_ack_sm_err_o;
  logic [2:0]                    dut_cmd_stage_sfifo_cmd_err_o, ref_cmd_stage_sfifo_cmd_err_o;
  logic [2:0]                    dut_cmd_stage_sfifo_genbits_err_o, ref_cmd_stage_sfifo_genbits_err_o;
  logic                          dut_cmd_gen_cnt_err_o, ref_cmd_gen_cnt_err_o;
  logic                          dut_cmd_stage_sm_err_o, ref_cmd_stage_sm_err_o;

  ot_entropy_cmd_top dut (
    .clk_i                        (clk_i),
    .rst_ni                       (rst_ni),
    .cs_enable_i                  (cs_enable_i),
    .edn_enable_i                 (edn_enable_i),
    .boot_req_mode_i              (boot_req_mode_i),
    .auto_req_mode_i              (auto_req_mode_i),
    .sw_cmd_req_load_i            (sw_cmd_req_load_i),
    .max_reqs_cnt_zero_i          (max_reqs_cnt_zero_i),
    .csrng_ack_err_i              (csrng_ack_err_i),
    .local_escalate_i             (local_escalate_i),
    .sw_cmd_mode_o                (dut_sw_cmd_mode_o),
    .boot_wr_ins_cmd_o            (dut_boot_wr_ins_cmd_o),
    .boot_send_ins_cmd_o          (dut_boot_send_ins_cmd_o),
    .boot_wr_gen_cmd_o            (dut_boot_wr_gen_cmd_o),
    .boot_wr_uni_cmd_o            (dut_boot_wr_uni_cmd_o),
    .accept_sw_cmds_pulse_o       (dut_accept_sw_cmds_pulse_o),
    .main_sm_done_pulse_o         (dut_main_sm_done_pulse_o),
    .capt_gencmd_fifo_cnt_o       (dut_capt_gencmd_fifo_cnt_o),
    .send_gencmd_o                (dut_send_gencmd_o),
    .capt_rescmd_fifo_cnt_o       (dut_capt_rescmd_fifo_cnt_o),
    .send_rescmd_o                (dut_send_rescmd_o),
    .auto_req_mode_busy_o         (dut_auto_req_mode_busy_o),
    .edn_main_sm_state_o          (dut_edn_main_sm_state_o),
    .reject_csrng_entropy_o       (dut_reject_csrng_entropy_o),
    .edn_main_sm_err_o            (dut_edn_main_sm_err_o),
    .cmd_stage_vld_i              (cmd_stage_vld_i),
    .cmd_stage_shid_i             (cmd_stage_shid_i),
    .cmd_stage_bus_i              (cmd_stage_bus_i),
    .cmd_stage_rdy_o              (dut_cmd_stage_rdy_o),
    .reseed_cnt_reached_i         (reseed_cnt_reached_i),
    .reseed_cnt_alert_o           (dut_reseed_cnt_alert_o),
    .invalid_cmd_seq_alert_o      (dut_invalid_cmd_seq_alert_o),
    .invalid_acmd_alert_o         (dut_invalid_acmd_alert_o),
    .gen_abort_req_i              (gen_abort_req_i),
    .gen_abort_invalid_o          (dut_gen_abort_invalid_o),
    .cmd_arb_req_o                (dut_cmd_arb_req_o),
    .cmd_arb_sop_o                (dut_cmd_arb_sop_o),
    .cmd_arb_mop_o                (dut_cmd_arb_mop_o),
    .cmd_arb_eop_o                (dut_cmd_arb_eop_o),
    .cmd_arb_bus_o                (dut_cmd_arb_bus_o),
    .cmd_entropy_avail_i          (cmd_entropy_avail_i),
    .cmd_entropy_req_o            (dut_cmd_entropy_req_o),
    .core_cmd_vld_o               (dut_core_cmd_vld_o),
    .core_cmd_rdy_i               (core_cmd_rdy_i),
    .clr_adata_packer_o           (dut_clr_adata_packer_o),
    .cmd_complete_i               (cmd_complete_i),
    .csrng_main_sm_state_o        (dut_csrng_main_sm_state_o),
    .csrng_main_sm_err_o          (dut_csrng_main_sm_err_o),
    .cmd_ack_i                    (cmd_ack_i),
    .cmd_ack_sts_i                (cmd_ack_sts_i),
    .cmd_stage_ack_o              (dut_cmd_stage_ack_o),
    .cmd_stage_ack_sts_o          (dut_cmd_stage_ack_sts_o),
    .genbits_vld_i                (genbits_vld_i),
    .genbits_bus_i                (genbits_bus_i),
    .genbits_fips_i               (genbits_fips_i),
    .genbits_vld_o                (dut_genbits_vld_o),
    .genbits_bus_o                (dut_genbits_bus_o),
    .genbits_fips_o               (dut_genbits_fips_o),
    .ep_req_i                     (ep_req_i),
    .ep_ack_o                     (dut_ep_ack_o),
    .ep_fifo_clr_o                (dut_ep_fifo_clr_o),
    .ep_ack_sm_err_o              (dut_ep_ack_sm_err_o),
    .cmd_stage_sfifo_cmd_err_o    (dut_cmd_stage_sfifo_cmd_err_o),
    .cmd_stage_sfifo_genbits_err_o(dut_cmd_stage_sfifo_genbits_err_o),
    .cmd_gen_cnt_err_o            (dut_cmd_gen_cnt_err_o),
    .cmd_stage_sm_err_o           (dut_cmd_stage_sm_err_o)
  );

  ref_ot_entropy_cmd_top u_ref (
    .clk_i                        (clk_i),
    .rst_ni                       (rst_ni),
    .cs_enable_i                  (cs_enable_i),
    .edn_enable_i                 (edn_enable_i),
    .boot_req_mode_i              (boot_req_mode_i),
    .auto_req_mode_i              (auto_req_mode_i),
    .sw_cmd_req_load_i            (sw_cmd_req_load_i),
    .max_reqs_cnt_zero_i          (max_reqs_cnt_zero_i),
    .csrng_ack_err_i              (csrng_ack_err_i),
    .local_escalate_i             (local_escalate_i),
    .sw_cmd_mode_o                (ref_sw_cmd_mode_o),
    .boot_wr_ins_cmd_o            (ref_boot_wr_ins_cmd_o),
    .boot_send_ins_cmd_o          (ref_boot_send_ins_cmd_o),
    .boot_wr_gen_cmd_o            (ref_boot_wr_gen_cmd_o),
    .boot_wr_uni_cmd_o            (ref_boot_wr_uni_cmd_o),
    .accept_sw_cmds_pulse_o       (ref_accept_sw_cmds_pulse_o),
    .main_sm_done_pulse_o         (ref_main_sm_done_pulse_o),
    .capt_gencmd_fifo_cnt_o       (ref_capt_gencmd_fifo_cnt_o),
    .send_gencmd_o                (ref_send_gencmd_o),
    .capt_rescmd_fifo_cnt_o       (ref_capt_rescmd_fifo_cnt_o),
    .send_rescmd_o                (ref_send_rescmd_o),
    .auto_req_mode_busy_o         (ref_auto_req_mode_busy_o),
    .edn_main_sm_state_o          (ref_edn_main_sm_state_o),
    .reject_csrng_entropy_o       (ref_reject_csrng_entropy_o),
    .edn_main_sm_err_o            (ref_edn_main_sm_err_o),
    .cmd_stage_vld_i              (cmd_stage_vld_i),
    .cmd_stage_shid_i             (cmd_stage_shid_i),
    .cmd_stage_bus_i              (cmd_stage_bus_i),
    .cmd_stage_rdy_o              (ref_cmd_stage_rdy_o),
    .reseed_cnt_reached_i         (reseed_cnt_reached_i),
    .reseed_cnt_alert_o           (ref_reseed_cnt_alert_o),
    .invalid_cmd_seq_alert_o      (ref_invalid_cmd_seq_alert_o),
    .invalid_acmd_alert_o         (ref_invalid_acmd_alert_o),
    .gen_abort_req_i              (gen_abort_req_i),
    .gen_abort_invalid_o          (ref_gen_abort_invalid_o),
    .cmd_arb_req_o                (ref_cmd_arb_req_o),
    .cmd_arb_sop_o                (ref_cmd_arb_sop_o),
    .cmd_arb_mop_o                (ref_cmd_arb_mop_o),
    .cmd_arb_eop_o                (ref_cmd_arb_eop_o),
    .cmd_arb_bus_o                (ref_cmd_arb_bus_o),
    .cmd_entropy_avail_i          (cmd_entropy_avail_i),
    .cmd_entropy_req_o            (ref_cmd_entropy_req_o),
    .core_cmd_vld_o               (ref_core_cmd_vld_o),
    .core_cmd_rdy_i               (core_cmd_rdy_i),
    .clr_adata_packer_o           (ref_clr_adata_packer_o),
    .cmd_complete_i               (cmd_complete_i),
    .csrng_main_sm_state_o        (ref_csrng_main_sm_state_o),
    .csrng_main_sm_err_o          (ref_csrng_main_sm_err_o),
    .cmd_ack_i                    (cmd_ack_i),
    .cmd_ack_sts_i                (cmd_ack_sts_i),
    .cmd_stage_ack_o              (ref_cmd_stage_ack_o),
    .cmd_stage_ack_sts_o          (ref_cmd_stage_ack_sts_o),
    .genbits_vld_i                (genbits_vld_i),
    .genbits_bus_i                (genbits_bus_i),
    .genbits_fips_i               (genbits_fips_i),
    .genbits_vld_o                (ref_genbits_vld_o),
    .genbits_bus_o                (ref_genbits_bus_o),
    .genbits_fips_o               (ref_genbits_fips_o),
    .ep_req_i                     (ep_req_i),
    .ep_ack_o                     (ref_ep_ack_o),
    .ep_fifo_clr_o                (ref_ep_fifo_clr_o),
    .ep_ack_sm_err_o              (ref_ep_ack_sm_err_o),
    .cmd_stage_sfifo_cmd_err_o    (ref_cmd_stage_sfifo_cmd_err_o),
    .cmd_stage_sfifo_genbits_err_o(ref_cmd_stage_sfifo_genbits_err_o),
    .cmd_gen_cnt_err_o            (ref_cmd_gen_cnt_err_o),
    .cmd_stage_sm_err_o           (ref_cmd_stage_sm_err_o)
  );

  int err_cnt = 0;
  int cyc_cnt = 0;
  int dut_ep_ack_cnt = 0;

  initial clk_i = 1'b0;
  always #5 clk_i = ~clk_i;

  task automatic check_all(input bit count_ack = 1'b0);
    if (count_ack && dut_ep_ack_o === 1'b1) begin
      dut_ep_ack_cnt++;
    end
    if (dut_sw_cmd_mode_o                 !== ref_sw_cmd_mode_o                 ||
        dut_boot_wr_ins_cmd_o             !== ref_boot_wr_ins_cmd_o             ||
        dut_boot_send_ins_cmd_o           !== ref_boot_send_ins_cmd_o           ||
        dut_boot_wr_gen_cmd_o             !== ref_boot_wr_gen_cmd_o             ||
        dut_boot_wr_uni_cmd_o             !== ref_boot_wr_uni_cmd_o             ||
        dut_accept_sw_cmds_pulse_o        !== ref_accept_sw_cmds_pulse_o        ||
        dut_main_sm_done_pulse_o          !== ref_main_sm_done_pulse_o          ||
        dut_capt_gencmd_fifo_cnt_o        !== ref_capt_gencmd_fifo_cnt_o        ||
        dut_send_gencmd_o                 !== ref_send_gencmd_o                 ||
        dut_capt_rescmd_fifo_cnt_o        !== ref_capt_rescmd_fifo_cnt_o        ||
        dut_send_rescmd_o                 !== ref_send_rescmd_o                 ||
        dut_auto_req_mode_busy_o          !== ref_auto_req_mode_busy_o          ||
        dut_edn_main_sm_state_o           !== ref_edn_main_sm_state_o           ||
        dut_reject_csrng_entropy_o        !== ref_reject_csrng_entropy_o        ||
        dut_edn_main_sm_err_o             !== ref_edn_main_sm_err_o             ||
        dut_cmd_stage_rdy_o               !== ref_cmd_stage_rdy_o               ||
        dut_reseed_cnt_alert_o            !== ref_reseed_cnt_alert_o            ||
        dut_invalid_cmd_seq_alert_o       !== ref_invalid_cmd_seq_alert_o       ||
        dut_invalid_acmd_alert_o          !== ref_invalid_acmd_alert_o          ||
        dut_gen_abort_invalid_o           !== ref_gen_abort_invalid_o           ||
        dut_cmd_arb_req_o                 !== ref_cmd_arb_req_o                 ||
        dut_cmd_arb_sop_o                 !== ref_cmd_arb_sop_o                 ||
        dut_cmd_arb_mop_o                 !== ref_cmd_arb_mop_o                 ||
        dut_cmd_arb_eop_o                 !== ref_cmd_arb_eop_o                 ||
        dut_cmd_arb_bus_o                 !== ref_cmd_arb_bus_o                 ||
        dut_cmd_entropy_req_o             !== ref_cmd_entropy_req_o             ||
        dut_core_cmd_vld_o                !== ref_core_cmd_vld_o                ||
        dut_clr_adata_packer_o            !== ref_clr_adata_packer_o            ||
        dut_csrng_main_sm_state_o         !== ref_csrng_main_sm_state_o         ||
        dut_csrng_main_sm_err_o           !== ref_csrng_main_sm_err_o           ||
        dut_cmd_stage_ack_o               !== ref_cmd_stage_ack_o               ||
        dut_cmd_stage_ack_sts_o           !== ref_cmd_stage_ack_sts_o           ||
        dut_genbits_vld_o                 !== ref_genbits_vld_o                 ||
        (ref_genbits_vld_o && (dut_genbits_bus_o !== ref_genbits_bus_o || dut_genbits_fips_o !== ref_genbits_fips_o)) ||
        (dut_ep_ack_o !== 1'b0 && dut_ep_ack_o !== 1'b1)                  ||
        (!(ep_req_i || ref_ep_ack_o) && dut_ep_ack_o !== 1'b0)            ||
        dut_ep_fifo_clr_o                 !== ref_ep_fifo_clr_o                 ||
        dut_ep_ack_sm_err_o               !== ref_ep_ack_sm_err_o               ||
        dut_cmd_stage_sfifo_cmd_err_o     !== ref_cmd_stage_sfifo_cmd_err_o     ||
        dut_cmd_stage_sfifo_genbits_err_o !== ref_cmd_stage_sfifo_genbits_err_o ||
        (dut_cmd_gen_cnt_err_o !== 1'b0 && dut_cmd_gen_cnt_err_o !== 1'b1) ||
        dut_cmd_stage_sm_err_o            !== ref_cmd_stage_sm_err_o) begin
      if (err_cnt < 20) begin
        $display("MISMATCH cyc=%0d edn_st=%h/%h done=%b/%b uni=%b/%b ack=%b/%b sts=%0d/%0d gb_vld=%b/%b ep_ack=%b/%b",
                 cyc_cnt, dut_edn_main_sm_state_o, ref_edn_main_sm_state_o,
                 dut_main_sm_done_pulse_o, ref_main_sm_done_pulse_o,
                 dut_boot_wr_uni_cmd_o, ref_boot_wr_uni_cmd_o,
                 dut_cmd_stage_ack_o, ref_cmd_stage_ack_o,
                 dut_cmd_stage_ack_sts_o, ref_cmd_stage_ack_sts_o,
                 dut_genbits_vld_o, ref_genbits_vld_o,
                 dut_ep_ack_o, ref_ep_ack_o);
      end
      err_cnt++;
    end
  endtask

  task automatic step();
    #1;
    if (rst_ni) check_all(1'b0);
    @(posedge clk_i);
    #1;
    cyc_cnt++;
    if (rst_ni) check_all(1'b1);
  endtask

  task automatic reset_all();
    rst_ni               = 1'b0;
    cs_enable_i          = 1'b0;
    edn_enable_i         = 1'b0;
    boot_req_mode_i      = 1'b0;
    auto_req_mode_i      = 1'b0;
    sw_cmd_req_load_i    = 1'b0;
    max_reqs_cnt_zero_i  = 1'b0;
    csrng_ack_err_i      = 1'b0;
    local_escalate_i     = 1'b0;
    cmd_stage_vld_i      = 1'b0;
    cmd_stage_shid_i     = 4'd2;
    cmd_stage_bus_i      = '0;
    reseed_cnt_reached_i = 1'b0;
    gen_abort_req_i      = 1'b0;
    cmd_entropy_avail_i  = 1'b1;
    core_cmd_rdy_i       = 1'b1;
    cmd_complete_i       = 1'b1;
    cmd_ack_i            = 1'b0;
    cmd_ack_sts_i        = CMD_STS_SUCCESS;
    genbits_vld_i        = 1'b0;
    genbits_bus_i        = '0;
    genbits_fips_i       = 1'b0;
    ep_req_i             = 1'b0;
    step();
    step();
    rst_ni = 1'b1;
    step();
  endtask

  function automatic logic [31:0] make_cmd(input acmd_e acmd, input logic [3:0] clen, input logic [3:0] flag0, input logic [11:0] glen);
    return {8'h00, glen, flag0, clen, 1'b0, acmd};
  endfunction

  initial begin
    reset_all();

    // ----------------------------------------------------------------------
    // Test 1: EDN Boot Mode (BootLoadIns -> BootLoadGen -> BootDone -> BootLoadUni -> Idle)
    // and CSRNG INS + 2-beat GEN + Endpoint Ack consumption
    // ----------------------------------------------------------------------
    cs_enable_i     = 1'b1;
    edn_enable_i    = 1'b1;
    boot_req_mode_i = 1'b1;
    step(); // BootLoadIns
    // Send INS command (clen=0, flag0=0, glen=0)
    cmd_stage_vld_i = 1'b1;
    cmd_stage_bus_i = make_cmd(INS, 4'd0, 4'd0, 12'd0);
    step();
    cmd_stage_vld_i = 1'b0;
    repeat (6) step();
    // Acknowledge INS
    cmd_ack_i     = 1'b1;
    cmd_ack_sts_i = CMD_STS_SUCCESS;
    step();
    cmd_ack_i     = 1'b0;
    step(); // cmd_stage_ack_o pulses -> BootLoadGen
    step(); // BootGenAckWait

    // Send GEN command with glen=2
    cmd_stage_vld_i = 1'b1;
    cmd_stage_bus_i = make_cmd(GEN, 4'd0, 4'd0, 12'd2);
    step();
    cmd_stage_vld_i = 1'b0;
    repeat (6) step();
    // Beat 1 of GEN: push genbits then ack
    genbits_vld_i  = 1'b1;
    genbits_fips_i = 1'b1;
    genbits_bus_i  = 128'hCAFEBABE_00000001_DEADBEEF_11111111;
    step();
    genbits_vld_i  = 1'b0;
    cmd_ack_i      = 1'b1;
    step();
    cmd_ack_i      = 1'b0;
    repeat (3) step();
    // Endpoint requests beat 1 from genbits FIFO!
    dut_ep_ack_cnt = 0;
    ep_req_i = 1'b1;
    step(); // Idle -> AckPls (or DataWait), pops genbits FIFO!
    step(); // AckPls -> Idle
    ep_req_i = 1'b0;
    if (dut_ep_ack_cnt != 1) begin
      $display("FAIL: expected 1 endpoint ack on beat 1, got %0d", dut_ep_ack_cnt);
      err_cnt++;
    end
    repeat (6) step();

    // Beat 2 of GEN: push genbits then ack (final beat -> cmd_stage_ack_o pulses!)
    genbits_vld_i  = 1'b1;
    genbits_fips_i = 1'b0;
    genbits_bus_i  = 128'hCAFEBABE_00000002_DEADBEEF_22222222;
    step();
    genbits_vld_i  = 1'b0;
    cmd_ack_i      = 1'b1;
    step();
    cmd_ack_i      = 1'b0;
    repeat (4) step();
    // Endpoint consumes beat 2
    dut_ep_ack_cnt = 0;
    ep_req_i = 1'b1;
    repeat (2) step();
    ep_req_i = 1'b0;
    if (dut_ep_ack_cnt != 1) begin
      $display("FAIL: expected 1 endpoint ack on beat 2, got %0d", dut_ep_ack_cnt);
      err_cnt++;
    end
    repeat (2) step();

    // Exit boot_req_mode_i -> must transition BootDone -> BootLoadUni -> BootUniAckWait -> Idle
    boot_req_mode_i = 1'b0;
    step(); // BootLoadUni (boot_wr_uni_cmd_o == 1)
    step(); // BootUniAckWait
    cmd_stage_vld_i = 1'b1;
    cmd_stage_bus_i = make_cmd(UNI, 4'd0, 4'd0, 12'd0);
    step();
    cmd_stage_vld_i = 1'b0;
    repeat (6) step();
    cmd_ack_i = 1'b1;
    step();
    cmd_ack_i = 1'b0;
    repeat (3) step();

    // ----------------------------------------------------------------------
    // Test 2: GEN Abort during multi-beat GEN + re-instantiate (INS)
    // Verifies:
    //  1) gen_abort_req_i during ongoing GEN dispatches UNI in GenSOP
    //  2) When CmdAck completes for abort, instantiated_q is cleared to 0 AND sfifo_genbits_clr clears stale genbits
    //  3) Subsequent INS command succeeds instead of failing with CMD_STS_INVALID_CMD_SEQ
    // ----------------------------------------------------------------------
    // First instantiate (with 1 additional data word clen=1, flag0=1)
    cmd_stage_vld_i = 1'b1;
    cmd_stage_bus_i = make_cmd(INS, 4'd1, 4'd1, 12'd0);
    step();
    cmd_stage_bus_i = 32'hA5A5_5A5A;
    step();
    cmd_stage_vld_i = 1'b0;
    repeat (8) step();
    cmd_ack_i = 1'b1;
    step();
    cmd_ack_i = 1'b0;
    repeat (3) step();

    // Start 3-beat GEN command
    cmd_stage_vld_i = 1'b1;
    cmd_stage_bus_i = make_cmd(GEN, 4'd0, 4'd0, 12'd3);
    step();
    cmd_stage_vld_i = 1'b0;
    repeat (6) step();
    // Beat 1 of GEN arrives and sits in genbits FIFO (unconsumed)
    genbits_vld_i  = 1'b1;
    genbits_fips_i = 1'b1;
    genbits_bus_i  = 128'h12345678_9ABCDEF0_13579BDF_2468ACE0;
    step();
    genbits_vld_i  = 1'b0;
    // Assert gen_abort_req_i while GEN is ongoing!
    gen_abort_req_i = 1'b1;
    step();
    gen_abort_req_i = 1'b0;
    // Complete beat 1 ack -> enters GenReq -> sees gen_abort_pending_q -> GenArbGnt -> GenSOP (sends UNI) -> CmdAck
    cmd_ack_i = 1'b1;
    step();
    cmd_ack_i = 1'b0;
    repeat (6) step();
    // Acknowledge the abort UNI command
    cmd_ack_i = 1'b1;
    step();
    cmd_ack_i = 1'b0;
    repeat (3) step();
    if (dut_genbits_vld_o !== 1'b0) begin
      $display("FAIL: genbits FIFO was not cleared on GEN abort ack");
      err_cnt++;
    end

    // Now issue a fresh INS command; since GEN abort uninstantiated the instance, INS must succeed!
    cmd_stage_vld_i = 1'b1;
    cmd_stage_bus_i = make_cmd(INS, 4'd0, 4'd1, 12'd0);
    step();
    cmd_stage_vld_i = 1'b0;
    repeat (6) step();
    cmd_ack_i = 1'b1;
    step();
    cmd_ack_i = 1'b0;
    repeat (3) step();

    // ----------------------------------------------------------------------
    // Test 3: Invalid command sequence, Reseed count exceeded, Invalid ACMD,
    // Spurious gen_abort_invalid_o, and EDN Auto Mode + Disable Done Pulse
    // ----------------------------------------------------------------------
    // Issue duplicate INS while already instantiated -> invalid_cmd_seq_alert_o + Flush
    cmd_stage_vld_i = 1'b1;
    cmd_stage_bus_i = make_cmd(INS, 4'd0, 4'd0, 12'd0);
    step();
    cmd_stage_vld_i = 1'b0;
    repeat (4) step();

    // Reset csrng_ack_err state on EDN and test Auto Request Mode
    edn_enable_i = 1'b0;
    step();
    edn_enable_i      = 1'b1;
    auto_req_mode_i   = 1'b1;
    step(); // Idle -> AutoLoadIns
    sw_cmd_req_load_i = 1'b1;
    step(); // AutoFirstAckWait
    sw_cmd_req_load_i = 1'b0;
    // Issue RES command to trigger csrng_cmd_ack_o
    cmd_stage_vld_i = 1'b1;
    cmd_stage_bus_i = make_cmd(RES, 4'd0, 4'd1, 12'd0);
    step();
    cmd_stage_vld_i = 1'b0;
    repeat (6) step();
    cmd_ack_i = 1'b1;
    step();
    cmd_ack_i = 1'b0;
    repeat (2) step(); // AutoDispatch -> AutoCaptGenCnt -> AutoSendGenCmd
    // Deassert edn_enable_i while in AutoSendGenCmd -> must pulse main_sm_done_pulse_o!
    edn_enable_i = 1'b0;
    step();
    edn_enable_i    = 1'b1;
    auto_req_mode_i = 1'b0;
    step(); // Idle -> SWPortMode

    // Test GEN when reseed_cnt_reached_i == 1 -> CMD_STS_RESEED_CNT_EXCEEDED + RejectCsrngEntropy
    reseed_cnt_reached_i = 1'b1;
    cmd_stage_vld_i      = 1'b1;
    cmd_stage_bus_i      = make_cmd(GEN, 4'd0, 4'd0, 12'd1);
    step();
    cmd_stage_vld_i      = 1'b0;
    repeat (4) step();
    reseed_cnt_reached_i = 1'b0;

    // Test spurious gen_abort_req_i when no GEN is ongoing -> gen_abort_invalid_o
    gen_abort_req_i = 1'b1;
    step();
    gen_abort_req_i = 1'b0;
    step();

    // Test invalid ACMD (3'h7)
    cmd_stage_vld_i = 1'b1;
    cmd_stage_bus_i = make_cmd(acmd_e'(3'h7), 4'd0, 4'd0, 12'd0);
    step();
    cmd_stage_vld_i = 1'b0;
    repeat (4) step();

    // Test local_escalate_i -> Error states
    local_escalate_i = 1'b1;
    step();
    step();

    if (err_cnt == 0) begin
      $display("PASS: All ot_entropy_cmd_top verification checks succeeded (%0d cycles).", cyc_cnt);
      $finish;
    end else begin
      $display("FAIL: %0d mismatches detected.", err_cnt);
      $fatal(1, "Verification failed");
    end
  end
endmodule
