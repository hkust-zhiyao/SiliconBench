// Testbench for OpenTitan OTBN Start/Stop, Loop & Call Stack Subsystem (ot_otbn_ctrl_top)

// Copyright lowRISC contributors (OpenTitan project).
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

/**
 * State machine to handle actions that occur around the start and stop of OTBN.
 *
 * This receives the start signals from the top-level and passes them on to the
 * controller to begin execution when pre-start actions have finished.
 *
 * pre-start actions:
 *  - Seed LFSR for URND
 *
 * post-stop actions:
 *  - Internal Secure Wipe
 *    -Delete WDRs
 *    -Delete Base registers
 *    -Delete Accumulator
 *    -Delete Modulus
 *    -Delete Accelerator ISPRs
 *    -Reset stack
 */

`include "prim_assert.sv"

module ref_otbn_start_stop_control
  import otbn_pkg::*;
  import prim_mubi_pkg::*;
#(
  // Skip URND re-seed at the start of the operation. Useful for SCA only.
  parameter bit SecSkipUrndReseedAtStart = 1'b0
) (
  input  logic clk_i,
  input  logic rst_ni,

  input  logic   start_i,
  input  mubi4_t escalate_en_i,
  input  mubi4_t rma_req_i,
  output mubi4_t rma_ack_o,

  output logic controller_start_o,

  output logic urnd_reseed_req_o,
  input  logic urnd_reseed_ack_i,
  output logic urnd_reseed_err_o,
  // The urnd advance signal controls whether the URND PRNG should advance its state in this cycle.
  // This can be over-steered by SW using the URND control feature / CSR. However, during secure
  // wipes we must ensure that this control logic is disabled / the PRNG is always advanced. This
  // is controlled via the must advance signal.
  output logic urnd_advance_o,
  output logic urnd_must_advance_o,

  input   logic secure_wipe_req_i,
  output  logic secure_wipe_ack_o,
  output  logic secure_wipe_running_o,
  output  logic done_o,

  output logic       sec_wipe_wdr_o,
  output logic       sec_wipe_wdr_urnd_o,
  output logic       sec_wipe_base_o,
  output logic       sec_wipe_base_urnd_o,
  output logic [4:0] sec_wipe_addr_o,

  output logic sec_wipe_mac_urnd_o,
  output logic sec_wipe_mod_urnd_o,
  output logic sec_wipe_zero_o,

  output logic sec_wipe_mai_in0_s0_urnd_o,
  output logic sec_wipe_mai_in0_s1_urnd_o,
  output logic sec_wipe_mai_in1_s0_urnd_o,
  output logic sec_wipe_mai_in1_s1_urnd_o,
  output logic sec_wipe_mai_res_s0_urnd_o,
  output logic sec_wipe_mai_res_s1_urnd_o,

  output logic sec_wipe_kmac_data_s0_urnd_o,
  output logic sec_wipe_kmac_data_s1_urnd_o,

  output logic ispr_init_o,
  output logic state_reset_o,
  output logic insn_cnt_clear_int_o,
  output logic fatal_error_o
);

  // Create a lint error to reduce the risk of accidentally enabling this feature.
  `ASSERT_STATIC_LINT_ERROR(OtbnSecSkipUrndReseedAtStartNonDefault, SecSkipUrndReseedAtStart == 0)

  otbn_start_stop_state_e state_q, state_d;
  logic init_sec_wipe_done_q, init_sec_wipe_done_d;
  mubi4_t wipe_after_urnd_refresh_q, wipe_after_urnd_refresh_d;
  mubi4_t rma_ack_d, rma_ack_q;
  logic state_error_q, state_error_d;
  logic mubi_err_q, mubi_err_d;
  logic urnd_reseed_err_q, urnd_reseed_err_d;
  logic urnd_control_allowed;
  logic secure_wipe_error_q, secure_wipe_error_d;
  logic secure_wipe_running_q, secure_wipe_running_d;
  logic skip_reseed_q;

  logic addr_cnt_inc;
  logic [5:0] addr_cnt_q, addr_cnt_d;

  logic spurious_urnd_ack_error;
  logic spurious_secure_wipe_req, dropped_secure_wipe_req;

  // There are three ways in which the start/stop controller can be told to stop.
  // 1. secure_wipe_req_i comes from the controller (which means "I've run some instructions and
  //    I've hit an ECALL or error").
  // 2. escalate_en_i can be asserted (which means "Someone else has told us to stop immediately").
  // 3. rma_req_i can be asserted (which means "Lifecycle wants to transition to the RMA state").
  // If running, all three can be true at once.
  //
  // An escalation signal as well as RMA requests get latched into should_lock. We'll then go
  // through the secure wipe process (unless we weren't running any instructions in case of an
  // escalation). We'll see the should_lock_q signal when done and go into the local locked
  // state. If necessary, the RMA request is acknowledged upon secure wipe completion.

  // SEC_CM: CONTROLLER.FSM.GLOBAL_ESC
  logic esc_request, rma_request, should_lock_d, should_lock_q, stop;
  assign esc_request   = mubi4_test_true_loose(escalate_en_i);
  assign rma_request   = mubi4_test_true_strict(rma_req_i);
  assign stop          = esc_request | rma_request | secure_wipe_req_i;
  assign should_lock_d = should_lock_q | esc_request | rma_request;

  // Only if SecSkipUrndReseedAtStart is set, the controller start pulse is sent
  // one cycle after leaving the Halt state.
  if (SecSkipUrndReseedAtStart) begin: gen_skip_reseed
    logic skip_reseed_d;

    assign skip_reseed_d = ((state_q == OtbnStartStopStateHalt) & start_i & ~stop);

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        skip_reseed_q <= 1'b0;
      end else begin
        skip_reseed_q <= skip_reseed_d;
      end
    end
  end else begin: gen_reseed
    assign skip_reseed_q = 1'b0;
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      should_lock_q <= 1'b0;
    end else begin
      should_lock_q <= should_lock_d;
    end
  end

  prim_mubi4_sender #(
    .AsyncOn(1'b1),
    .EnSecBuf(1'b1),
    .ResetValue(prim_mubi_pkg::MuBi4False)
  ) u_prim_mubi4_sender_rma_ack (
    .clk_i,
    .rst_ni,
    .mubi_i(rma_ack_d),
    .mubi_o(rma_ack_q)
  );

  logic allow_secure_wipe, expect_secure_wipe;

  // SEC_CM: START_STOP_CTRL.FSM.SPARSE
  `PRIM_FLOP_SPARSE_FSM(u_state_regs, state_d, state_q,
      otbn_start_stop_state_e, OtbnStartStopStateInitial)

  always_comb begin
    urnd_reseed_req_o            = 1'b0;
    urnd_advance_o               = 1'b0;
    urnd_control_allowed         = 1'b0;
    state_d                      = state_q;
    ispr_init_o                  = 1'b0;
    state_reset_o                = 1'b0;
    insn_cnt_clear_int_o         = 1'b0;
    sec_wipe_wdr_o               = 1'b0;
    sec_wipe_wdr_urnd_o          = 1'b0;
    sec_wipe_base_o              = 1'b0;
    sec_wipe_base_urnd_o         = 1'b0;
    sec_wipe_mac_urnd_o          = 1'b0;
    sec_wipe_mod_urnd_o          = 1'b0;
    sec_wipe_zero_o              = 1'b0;
    sec_wipe_kmac_data_s0_urnd_o = 1'b0;
    sec_wipe_kmac_data_s1_urnd_o = 1'b0;
    sec_wipe_mai_in0_s0_urnd_o   = 1'b0;
    sec_wipe_mai_in0_s1_urnd_o   = 1'b0;
    sec_wipe_mai_in1_s0_urnd_o   = 1'b0;
    sec_wipe_mai_in1_s1_urnd_o   = 1'b0;
    sec_wipe_mai_res_s0_urnd_o   = 1'b0;
    sec_wipe_mai_res_s1_urnd_o   = 1'b0;
    addr_cnt_inc                 = 1'b0;
    secure_wipe_ack_o            = 1'b0;
    secure_wipe_running_d        = 1'b0;
    state_error_d                = state_error_q;
    allow_secure_wipe            = 1'b0;
    expect_secure_wipe           = 1'b0;
    spurious_urnd_ack_error      = 1'b0;
    wipe_after_urnd_refresh_d    = wipe_after_urnd_refresh_q;
    rma_ack_d                    = rma_ack_q;
    mubi_err_d                   = mubi_err_q;

    unique case (state_q)
      OtbnStartStopStateInitial: begin
        secure_wipe_running_d = 1'b1;
        urnd_reseed_req_o     = 1'b1;
        if (rma_request) begin
          // If we get an RMA request before the URND got reseeded, proceed with the initial secure
          // wipe, as the entropy complex may not be able to provide entropy at this point.
          state_d = OtbnStartStopSecureWipeWdrUrnd;
          // As we don't reseed URND, there's no point in doing two rounds of wiping, so we pretend
          // that the first round is already the second round.
          wipe_after_urnd_refresh_d = MuBi4True;
        end else if (urnd_reseed_ack_i) begin
          urnd_advance_o = 1'b1;
          state_d        = OtbnStartStopSecureWipeWdrUrnd;
        end
      end
      OtbnStartStopStateHalt: begin
        // Keep start_reset_o asserted whilst in this state. We want to keep this signal early so do
        // not want to factor further logic into it.
        state_reset_o = 1'b1;

        if (stop && !rma_request) begin
          state_d = OtbnStartStopStateLocked;
        end else if (start_i || rma_request) begin
          ispr_init_o          = 1'b1;
          insn_cnt_clear_int_o = 1'b1;
          if (rma_request) begin
            // Do not reseed URND before secure wipe for RMA, as the entropy complex may not be able
            // to provide entropy at this point.
            secure_wipe_running_d = 1'b1;
            state_d               = OtbnStartStopSecureWipeWdrUrnd;
            // As we don't reseed URND, there's no point in doing two rounds of wiping, so we
            // pretend that the first round is already the second round.
            wipe_after_urnd_refresh_d = MuBi4True;
          end else begin // start_i
            urnd_reseed_req_o = ~SecSkipUrndReseedAtStart;
            state_d           = OtbnStartStopStateUrndRefresh;
          end
        end
      end
      OtbnStartStopStateUrndRefresh: begin
        urnd_reseed_req_o = ~skip_reseed_q;
        if (stop) begin
          if (mubi4_test_false_strict(wipe_after_urnd_refresh_q)) begin
            // We are told to stop and don't have to wipe after the current URND refresh is ack'd,
            // so we lock immediately.
            state_d = OtbnStartStopStateLocked;
          end else begin
            // We are told to stop but should wipe after the current URND refresh is ack'd, so we
            // wait for the ACK and then do a secure wipe.
            allow_secure_wipe     = 1'b1;
            expect_secure_wipe    = 1'b1;
            secure_wipe_running_d = 1'b1;
            if (urnd_reseed_ack_i) begin
              state_d = OtbnStartStopSecureWipeWdrUrnd;
            end
          end
        end else begin
          if (mubi4_test_false_strict(wipe_after_urnd_refresh_q)) begin
            // We are not stopping and we don't have to wipe after the current URND refresh is
            // ack'd, so we wait for the ACK and then start executing.
            if (urnd_reseed_ack_i || skip_reseed_q) begin
              state_d = OtbnStartStopStateRunning;
            end
          end else begin
            // We are not stopping but should wipe after the current URND refresh is ack'd, so we
            // wait for the ACK and then do a secure wipe.
            allow_secure_wipe     = 1'b1;
            expect_secure_wipe    = 1'b1;
            secure_wipe_running_d = 1'b1;
            if (urnd_reseed_ack_i) begin
              state_d = OtbnStartStopSecureWipeWdrUrnd;
            end
          end
        end
      end
      OtbnStartStopStateRunning: begin
        urnd_advance_o       = 1'b1;
        urnd_control_allowed = 1'b1;
        allow_secure_wipe    = 1'b1;

        if (stop) begin
          secure_wipe_running_d = 1'b1;
          state_d               = OtbnStartStopSecureWipeWdrUrnd;
        end
      end
      // SEC_CM: DATA_REG_SW.SEC_WIPE
      // Writing random numbers to the wide data registers.
       OtbnStartStopSecureWipeWdrUrnd: begin
        urnd_advance_o        = 1'b1;
        addr_cnt_inc          = 1'b1;
        sec_wipe_wdr_o        = 1'b1;
        sec_wipe_wdr_urnd_o   = 1'b1;
        allow_secure_wipe     = 1'b1;
        expect_secure_wipe    = 1'b1;
        secure_wipe_running_d = 1'b1;

        // Count one extra cycle when wiping the WDR, because the wipe signals to the WDR
        // (`sec_wipe_wdr_o` and `sec_wipe_wdr_urnd_o`) are flopped once but the wipe signals to the
        // ACC register, which is wiped directly after the last WDR, are not.  If we would not count
        // this extra cycle, the last WDR and the ACC register would be wiped simultaneously and
        // thus with the same random value.
        if (addr_cnt_q == 6'b100000) begin
          // Reset `addr_cnt` on the transition out of this state.
          addr_cnt_inc = 1'b0;
          // The following two signals are flopped once before they reach the FSM, so clear them one
          // cycle early here.
          sec_wipe_wdr_o      = 1'b0;
          sec_wipe_wdr_urnd_o = 1'b0;
          state_d = OtbnStartStopSecureWipeAccModBaseUrnd;
        end
      end
      // Writing random numbers to the accumulator, modulus and the base registers.
      // addr_cnt_q wraps around to 0 when first moving to this state, and we need to
      // supress writes to the zero register and the call stack.
       OtbnStartStopSecureWipeAccModBaseUrnd: begin
        urnd_advance_o        = 1'b1;
        addr_cnt_inc          = 1'b1;
        allow_secure_wipe     = 1'b1;
        expect_secure_wipe    = 1'b1;
        secure_wipe_running_d = 1'b1;
        // The first two clock cycles are used to clear the internal MAC state (including the
        // accumulator) and the modulus by overwriting it with random data.
        sec_wipe_mac_urnd_o   = (addr_cnt_q == 6'b000000);
        sec_wipe_mod_urnd_o   = (addr_cnt_q == 6'b000001);
        // Suppress writes to the zero register and the call stack.
        sec_wipe_base_o       = (addr_cnt_q > 6'b000001);
        sec_wipe_base_urnd_o  = (addr_cnt_q > 6'b000001);
        if (addr_cnt_q == 6'b011111) begin
          // Reset `addr_cnt` on the transition out of this state.
          addr_cnt_inc = 1'b0;
          state_d = OtbnStartStopSecureWipeExtIsprsUrnd;
        end
      end
      // Writing random numbers to external ISPRs
      OtbnStartStopSecureWipeExtIsprsUrnd: begin
        urnd_advance_o        = 1'b1;
        addr_cnt_inc          = 1'b1;
        allow_secure_wipe     = 1'b1;
        expect_secure_wipe    = 1'b1;
        secure_wipe_running_d = 1'b1;
        // reset registers in sequence
        sec_wipe_kmac_data_s0_urnd_o = (addr_cnt_q == 6'b000000);
        sec_wipe_kmac_data_s1_urnd_o = (addr_cnt_q == 6'b000001);
        sec_wipe_mai_res_s0_urnd_o   = (addr_cnt_q == 6'b000010);
        sec_wipe_mai_res_s1_urnd_o   = (addr_cnt_q == 6'b000011);
        sec_wipe_mai_in0_s0_urnd_o   = (addr_cnt_q == 6'b000100);
        sec_wipe_mai_in0_s1_urnd_o   = (addr_cnt_q == 6'b000101);
        sec_wipe_mai_in1_s0_urnd_o   = (addr_cnt_q == 6'b000110);
        sec_wipe_mai_in1_s1_urnd_o   = (addr_cnt_q == 6'b000111);
        // We let this phase run for 32 cycles to allow future accelerator registers
        // to be cleared in this stage without the need to adapt the DV model of OTBN.
        if (addr_cnt_q == 6'b011111) begin
          // Reset `addr_cnt` on the transition out of this state.
          addr_cnt_inc = 1'b0;
          state_d = OtbnStartStopSecureWipeAllZero;
        end
      end
      // Writing zeros to the CSRs and reset the stack. The other registers are intentionally not
      // overwritten with zero.
       OtbnStartStopSecureWipeAllZero: begin
        sec_wipe_zero_o    = 1'b1;
        allow_secure_wipe  = 1'b1;
        expect_secure_wipe = 1'b1;

        // Leave this state after a single cycle, which is sufficient to reset the CSRs and the
        // stack.
        if (mubi4_test_false_strict(wipe_after_urnd_refresh_q)) begin
          // This is the first round of wiping with random numbers, refresh URND and do a second
          // round.
          state_d = OtbnStartStopStateUrndRefresh;
          secure_wipe_running_d     = 1'b1;
          wipe_after_urnd_refresh_d = MuBi4True;
        end else begin
          // This is the second round of wiping with random numbers, so the secure wipe is
          // complete.
          state_d = OtbnStartStopSecureWipeComplete;
          secure_wipe_running_d = 1'b0;
          secure_wipe_ack_o     = 1'b1;
        end
      end
      OtbnStartStopSecureWipeComplete: begin
        urnd_advance_o = 1'b1;
        rma_ack_d = rma_req_i;
        state_d = should_lock_d ? OtbnStartStopStateLocked : OtbnStartStopStateHalt;
        wipe_after_urnd_refresh_d = MuBi4False;
      end
      OtbnStartStopStateLocked: begin
        // SEC_CM: START_STOP_CTRL.FSM.GLOBAL_ESC
        // SEC_CM: START_STOP_CTRL.FSM.LOCAL_ESC
        //
        // Terminal state. This is either accessed by glitching state_q (and going through the
        // default case below) or by getting an escalation signal
      end
      default: begin
        // We should never get here. If we do (e.g. via a malicious glitch), error out immediately.
        state_error_d = 1'b1;
        rma_ack_d = MuBi4False;
        state_d = OtbnStartStopStateLocked;
      end
    endcase

    if (urnd_reseed_ack_i &&
        !(state_q inside {OtbnStartStopStateInitial, OtbnStartStopStateUrndRefresh})) begin
      // We should never receive an ACK from URND when we're not refreshing the URND. Signal an
      // error if we see a stray ACK and lock the FSM.
      spurious_urnd_ack_error = 1'b1;
      state_d                 = OtbnStartStopStateLocked;
    end

    // If the MuBi signals take on invalid values, something bad is happening. Put them back to
    // a safe value (if possible) and signal an error. The only exception is rma_req_i. This LC
    // signal may experience staggered transitions due to CDCs leading to invalid values. In
    // accordance with the spec, invalid values of non-escalation LC signals must be treated as
    // OFF. rma_ack_d/q is driven by rma_req_i but only at the end of the secure wipe. By that
    // time rma_req_i has for sure stabilized.
    if (mubi4_test_invalid(escalate_en_i)) begin
      mubi_err_d = 1'b1;
      state_d = OtbnStartStopStateLocked;
    end
    if (mubi4_test_invalid(wipe_after_urnd_refresh_q)) begin
      wipe_after_urnd_refresh_d = MuBi4False;
      mubi_err_d = 1'b1;
      state_d = OtbnStartStopStateLocked;
    end
    if (mubi4_test_invalid(rma_ack_q)) begin
      rma_ack_d = MuBi4False;
      mubi_err_d = 1'b1;
      state_d = OtbnStartStopStateLocked;
    end
  end

  // Latch initial secure wipe done.
  assign init_sec_wipe_done_d = (state_q == OtbnStartStopSecureWipeComplete) ? 1'b1 : // set
                                init_sec_wipe_done_q; // keep

  // Logic separate from main FSM code to avoid false combinational loop warning from verilator
  assign controller_start_o =
    // The controller start pulse is fired when finishing the initial URND reseed.
    ((state_q == OtbnStartStopStateUrndRefresh) & (urnd_reseed_ack_i | skip_reseed_q) &
      mubi4_test_false_strict(wipe_after_urnd_refresh_q));

  assign done_o = ((state_q == OtbnStartStopSecureWipeComplete && init_sec_wipe_done_q) ||
                   (stop && (state_q == OtbnStartStopStateUrndRefresh) &&
                    mubi4_test_false_strict(wipe_after_urnd_refresh_q)) ||
                   (spurious_urnd_ack_error && !(state_q inside {OtbnStartStopStateHalt,
                                                                 OtbnStartStopStateLocked}) &&
                    init_sec_wipe_done_q) || (mubi_err_d && !mubi_err_q));

  assign addr_cnt_d = addr_cnt_inc ? (addr_cnt_q + 6'd1) : 6'd0;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      addr_cnt_q            <= 6'd0;
      init_sec_wipe_done_q  <= 1'b0;
      secure_wipe_running_q <= 1'b1;
    end else begin
      addr_cnt_q            <= addr_cnt_d;
      init_sec_wipe_done_q  <= init_sec_wipe_done_d;
      secure_wipe_running_q <= secure_wipe_running_d;
    end
  end

  prim_mubi4_sender #(
    .AsyncOn(1),
    .ResetValue(MuBi4False)
  ) u_wipe_after_urnd_refresh_flop (
    .clk_i,
    .rst_ni,
    .mubi_i(wipe_after_urnd_refresh_d),
    .mubi_o(wipe_after_urnd_refresh_q)
  );

  // Clip the secure wipe address to [0..31].  This is safe because the wipe enable signals are
  // never set when the counter exceeds 5 bit, which we assert below.
  assign sec_wipe_addr_o = addr_cnt_q[4:0];
  `ASSERT(NoSecWipeAbove32Bit_A, addr_cnt_q[5] |-> (!sec_wipe_wdr_o && !sec_wipe_mac_urnd_o))

  // SEC_CM: START_STOP_CTRL.STATE.CONSISTENCY
  // A check for spurious or dropped secure wipe requests.
  // We only expect to start a secure wipe when running.
  assign spurious_secure_wipe_req = secure_wipe_req_i & ~allow_secure_wipe;
  // Once we've started a secure wipe, the controller should not drop the request until we tell it
  // we're done. This does not apply for the *initial* secure wipe, though, which is controlled by
  // this module rather than the controller.
  assign dropped_secure_wipe_req  = expect_secure_wipe & init_sec_wipe_done_d & ~secure_wipe_req_i;

  // Delay the "glitch req/ack" error signal by a cycle. Otherwise, you end up with a combinatorial
  // loop through the escalation signal that our fatal_error_o causes otbn_core to pass to the
  // controller.
  assign secure_wipe_error_d = spurious_secure_wipe_req | dropped_secure_wipe_req;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_error_q       <= 1'b0;
      mubi_err_q          <= 1'b0;
      secure_wipe_error_q <= 1'b0;
      urnd_reseed_err_q   <= 1'b0;
    end else begin
      state_error_q       <= state_error_d;
      mubi_err_q          <= mubi_err_d;
      secure_wipe_error_q <= secure_wipe_error_d;
      urnd_reseed_err_q   <= urnd_reseed_err_d;
    end
  end

  assign urnd_reseed_err_d = spurious_urnd_ack_error ? 1'b1 // set
                                                     : urnd_reseed_err_q; // hold
  assign urnd_reseed_err_o = urnd_reseed_err_d;

  // Enforce that URND is advanced when URND control is not allowed, i.e., during a secure wipe.
  assign urnd_must_advance_o = !urnd_control_allowed && urnd_advance_o;

  assign fatal_error_o = urnd_reseed_err_o | state_error_d | secure_wipe_error_q | mubi_err_q;

  assign rma_ack_o = rma_ack_q;

  assign secure_wipe_running_o = secure_wipe_running_q;

  `ASSERT(StartStopStateValid_A,
      state_q inside {OtbnStartStopStateInitial,
                      OtbnStartStopStateHalt,
                      OtbnStartStopStateUrndRefresh,
                      OtbnStartStopStateRunning,
                      OtbnStartStopSecureWipeWdrUrnd,
                      OtbnStartStopSecureWipeAccModBaseUrnd,
                      OtbnStartStopSecureWipeExtIsprsUrnd,
                      OtbnStartStopSecureWipeAllZero,
                      OtbnStartStopSecureWipeComplete,
                      OtbnStartStopStateLocked})

  `ASSERT(StartSecureWipeImpliesRunning_A,
          $rose(secure_wipe_req_i) |-> (state_q == OtbnStartStopStateRunning))

endmodule

// Copyright lowRISC contributors (OpenTitan project).
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

/**
 * Simple stack parameterised on width and depth
 *
 * When a push and pop occur in the same cycle the pop is ordered before the push (so top_data_o
 * reflects what was on top of the stack, which is retrieved by the pop, the push then immediately
 * replaces this with a new piece of data). Internal checking is performed for full & empty
 * conditions so a push on full/pop on empty is allowable, though meaningless. For a push on full
 * the data will be dropped, for a pop no empty there is no valid data to pop. The exception is
 * a combined push & pop on full, here the top is popped off and replaced with what is pushed, no
 * data is dropped.
 *
 * The read and write pointers and read and write signals are exposed as `stack_rd_idx_i,
 * `stack_wr_idx_o`, `stack_write_o` and `stack_read_o`. `next_top_data_o` and `next_top_valid_o`
 * provide the top_data_o and top_valid_o output that will be seen in the following cycle if
 * `commit_i` is set. This is to enable users to extend the stack in case where it's not a simple
 * matter of adding extra data bits (e.g. where this is a prim_count instance per stack entry).
 */
module ref_otbn_stack
  import otbn_pkg::*;
#(
  parameter int unsigned StackWidth = 32,
  parameter int unsigned StackDepth = 4,

  localparam int unsigned StackDepthW = prim_util_pkg::vbits(StackDepth)
) (
  input clk_i,
  input rst_ni,

  output logic                  full_o,      // Stack is full

  output logic                  cnt_err_o,   // Stack counters are wrong

  input logic                   clear_i,     // Clear all data

  input  logic                  push_i,      // Push the data
  input  logic [StackWidth-1:0] push_data_i, // Data to push

  input  logic                  pop_i,       // Pop top of the stack
  output logic [StackWidth-1:0] top_data_o,  // Data on top of the stack
  output logic                  top_valid_o, // Stack is non empty (`top_data_o` is valid)

  input  logic                  commit_i,    // Commit the push/pop action. If commit is not
                                             // asserted push/pop will not take effect, though
                                             // next_top_data_o and next_top_valid_o will still
                                             // indicate the next stack state if the action did
                                             // occur.

  output logic [StackDepthW-1:0] stack_wr_idx_o,
  output logic                   stack_write_o,
  output logic [StackDepthW-1:0] stack_rd_idx_o,
  output logic                   stack_read_o,

  output logic [StackWidth-1:0]  next_top_data_o,
  output logic                   next_top_valid_o
);
  logic [StackWidth-1:0]  stack_storage [StackDepth];
  logic [StackDepthW:0]   stack_wr_ptr;
  logic [StackDepthW-1:0] stack_rd_idx, stack_wr_idx;
  logic [StackDepthW:0]   next_stack_wr_ptr;
  logic [StackDepthW-1:0] next_stack_rd_idx;
  logic                   cnt_err, cnt_err_d, cnt_err_q;

  logic stack_empty;
  logic stack_full;

  logic stack_write;
  logic stack_read;

  logic stack_wr_ptr_commit;

  assign stack_empty = stack_wr_ptr == '0;
  assign stack_full  = stack_wr_ptr == StackDepth[StackDepthW:0];

  assign stack_write = push_i & (~full_o | pop_i);
  assign stack_read  = top_valid_o & pop_i;

  assign stack_rd_idx = stack_wr_ptr[StackDepthW-1:0] - 1'b1;
  assign stack_wr_idx = pop_i ? stack_rd_idx : stack_wr_ptr[StackDepthW-1:0];

  assign stack_wr_ptr_commit = clear_i | commit_i;

  // SEC_CM: STACK_WR_PTR.CTR.REDUN
  prim_count #(
    .Width        (StackDepthW+1)
  ) u_stack_wr_ptr (
    .clk_i,
    .rst_ni,
    .clr_i              (clear_i),
    .set_i              (1'b0),
    .set_cnt_i          ('0),
    .incr_en_i          (stack_write),
    .decr_en_i          (stack_read),
    .step_i             ((StackDepthW+1)'(1'b1)),
    .commit_i           (stack_wr_ptr_commit),
    .cnt_o              (stack_wr_ptr),
    .cnt_after_commit_o (next_stack_wr_ptr),
    .err_o              (cnt_err)
  );

  assign cnt_err_d = cnt_err_q | cnt_err;

  prim_flop #(
    .Width(1),
    .ResetValue('0)
  ) u_cnt_err_flop (
    .clk_i,
    .rst_ni,

    .d_i(cnt_err_d),
    .q_o(cnt_err_q)
  );

  assign cnt_err_o = cnt_err_d;

  always_ff @(posedge clk_i) begin
    if (stack_write & commit_i) begin
      stack_storage[stack_wr_idx] <= push_data_i;
    end
  end


  assign full_o      = stack_full;
  assign top_data_o  = stack_storage[stack_rd_idx];
  assign top_valid_o = ~stack_empty;

  assign stack_wr_idx_o = stack_wr_idx;
  assign stack_rd_idx_o = stack_rd_idx;
  assign stack_write_o  = stack_write;
  assign stack_read_o   = stack_read;

  assign next_stack_rd_idx = next_stack_wr_ptr[StackDepthW-1:0] - 1'b1;

  assign next_top_data_o = stack_write ? push_data_i : stack_storage[next_stack_rd_idx];
  assign next_top_valid_o = next_stack_wr_ptr != '0;

endmodule

// Copyright lowRISC contributors (OpenTitan project).
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

`include "prim_assert.sv"

module ref_otbn_loop_controller
  import otbn_pkg::*;
#(
  parameter int ImemAddrWidth = 12
) (
  input clk_i,
  input rst_ni,

  input state_reset_i,

  input                     insn_valid_i,
  input [ImemAddrWidth-1:0] insn_addr_i,
  input [ImemAddrWidth-1:0] next_insn_addr_i,

  input                     loop_start_req_i,
  input                     loop_start_commit_i,
  input [11:0]              loop_bodysize_i,
  input [31:0]              loop_iterations_i,
  input [ImemAddrWidth-1:0] loop_end_addr_predec_i,

  output                     loop_jump_o,
  output [ImemAddrWidth-1:0] loop_jump_addr_o,

  output sw_err_o,
  output hw_err_o,
  output predec_err_o,

  output                     prefetch_loop_active_o,
  output [31:0]              prefetch_loop_iterations_o,
  output [ImemAddrWidth:0]   prefetch_loop_end_addr_o,
  output [ImemAddrWidth-1:0] prefetch_loop_jump_addr_o,

  input jump_or_branch_i,
  input otbn_stall_i
);
  // The ISA has a fixed 12 bits for loop_bodysize. The maximum possible address for the end of a
  // loop is the maximum address in Imem (2^ImemAddrWidth - 4) plus loop_bodysize instructions
  // (which take 4 * (2^12 - 1) bytes), plus 4 extra bytes. This simplifies to
  //
  //    (1 << ImemAddrWidth) + (1 << 14) - 4
  //
  // which is strictly less than (1 << (max(ImemAddrWidth, 14) + 1)), so can be represented with
  // max(ImemAddrWidth, 14) + 1 bits.
  localparam int unsigned LoopEndAddrWidth = 1 + (ImemAddrWidth < 14 ? 14 : ImemAddrWidth);

  typedef struct packed {
    logic [ImemAddrWidth-1:0] loop_start;
    logic [ImemAddrWidth:0]   loop_end;
    logic [6:0]               loop_addrs_intg;
  } loop_addr_info_t;

  typedef struct packed {
    loop_addr_info_t          loop_addr_info;
    logic [31:0]              loop_iterations;
  } loop_info_t;

  loop_info_t current_loop;
  logic       current_loop_valid;

  logic        at_current_loop_end_insn;
  logic        current_loop_finish;
  logic        current_loop_counter_dec;
  logic [38:0] current_loop_addrs_padded_intg_unbuf, current_loop_addrs_padded_intg_buf;
  logic [1:0]  current_loop_intg_err;

  loop_info_t                  new_loop;
  logic [LoopEndAddrWidth-1:0] new_loop_end_addr_full;
  logic [ImemAddrWidth:0]      new_loop_end_addr_imem;
  logic [31:0]                 new_loop_addrs_padded_no_intg;
  logic [38:0]                 new_loop_addrs_padded_intg;

  loop_addr_info_t             next_loop_addr_info;
  logic                        next_loop_valid;
  logic loop_stack_push_req;
  logic loop_stack_full;
  logic loop_stack_pop;
  logic loop_stack_commit;

  logic loop_iteration_err;
  logic loop_branch_err;
  logic loop_stack_overflow_err;
  logic loop_at_end_err;
  logic loop_stack_cnt_err;

  localparam int unsigned StackDepthW = prim_util_pkg::vbits(LoopStackDepth);
  logic [StackDepthW-1:0] loop_stack_wr_idx;
  logic                   loop_stack_write;
  logic [StackDepthW-1:0] loop_stack_rd_idx;

  logic [31:0]               loop_counters [LoopStackDepth];
  logic [LoopStackDepth-1:0] loop_counter_err, loop_counter_err_d, loop_counter_err_q;

  // The loop controller maintains a loop stack. The top of the loop stack is the innermost loop and
  // is valid when current_loop_valid is set. The loop controller tracks the current address vs the
  // current loop end address. When the current loop is active and the end address is reached a jump
  // is performed (via loop_jump_o) back to the top of the loop if iterations of the loop remain.
  // When a new loop is started it is pushed to the loop stack. When the current loop ends it is
  // popped off the loop stack with the loop below it becoming the current loop if the loop stack
  // isn't empty.

  // Determine end address of incoming loop from LOOP/LOOPI instruction (valid on loop_start_req_i
  // and specified by the current instruction address and loop_bodysize_i).
  //
  // Note that both of the static casts increase the size of their terms because LoopEndAddrWidth >
  // max(14, ImemAddrWidth).
  assign new_loop_end_addr_full = LoopEndAddrWidth'(insn_addr_i) +
                                  LoopEndAddrWidth'({loop_bodysize_i, 2'b00}) + 'd4;

  // Truncate the full address to get an Imem address.
  assign new_loop_end_addr_imem[ImemAddrWidth-1:0] = new_loop_end_addr_full[ImemAddrWidth-1:0];

  // If the end address calculation overflowed ImemAddrWidth, set top bit of stored end address to
  // indicate this.
  assign new_loop_end_addr_imem[ImemAddrWidth] =
      |new_loop_end_addr_full[LoopEndAddrWidth-1:ImemAddrWidth];

  assign new_loop_addrs_padded_no_intg = {{(32 - (ImemAddrWidth * 2) - 1){1'b0}},
                                          next_insn_addr_i,
                                          new_loop_end_addr_imem};

  prim_secded_inv_39_32_enc u_new_loop_addrs_intg_enc (
    .data_i(new_loop_addrs_padded_no_intg),
    .data_o(new_loop_addrs_padded_intg)
  );

  logic unused_new_loop_addrs_padded_intg;
  assign unused_new_loop_addrs_padded_intg = ^new_loop_addrs_padded_intg[31:0];

  assign new_loop = '{
    loop_addr_info : '{
        loop_start:      next_insn_addr_i,
        loop_end:        new_loop_end_addr_imem,
        loop_addrs_intg: new_loop_addrs_padded_intg[38:32]
    },
    loop_iterations: loop_iterations_i
  };

  // `loop_end` has one more bit than Imem width; this is set when the end address calculation
  // overflows. When this is the case the end instruction is never reached.
  assign at_current_loop_end_insn =
      current_loop_valid & (current_loop.loop_addr_info.loop_end == {1'b0, insn_addr_i}) &
      insn_valid_i;

  // The iteration decrement happens at loop end. So when execution reaches the end instruction of
  // the current loop with 1 iteration that is the end of the final iteration and the current loop
  // finishes.
  assign current_loop_finish = at_current_loop_end_insn & (current_loop.loop_iterations == 1)
    & ~otbn_stall_i;

  // Jump to top of current loop when execution reaches the end instruction of the current loop it
  // isn't finished.
  assign loop_jump_o      = at_current_loop_end_insn & ~current_loop_finish;
  assign loop_jump_addr_o = current_loop.loop_addr_info.loop_start;

  assign loop_iteration_err      = (loop_iterations_i == '0) & loop_start_req_i;
  assign loop_branch_err         = at_current_loop_end_insn & jump_or_branch_i;
  assign loop_stack_overflow_err = loop_stack_push_req & loop_stack_full;
  assign loop_at_end_err         = at_current_loop_end_insn & loop_start_req_i;

  assign sw_err_o = loop_iteration_err      |
                    loop_branch_err         |
                    loop_stack_overflow_err |
                    loop_at_end_err;

  // Decrement current loop counter when execution reaches the end instruction
  assign current_loop_counter_dec = ~state_reset_i & ~otbn_stall_i & at_current_loop_end_insn;

  // Push current loop to the loop stack when a new loop starts (LOOP instruction executed).
  // loop_stack_push_req indicates a push is requested, loop_stack_commit must also be asserted
  // (when the loop start is committed) for it to take effect.
  assign loop_stack_push_req = loop_start_req_i;

  // The OTBN controller must not commit a loop request if it sees a loop error.
  `ASSERT(NoStartCommitIfLoopErr, loop_start_req_i && loop_start_commit_i |-> !sw_err_o)

  // Pop from the loop stack when the current loop finishes. Stack internally checks to see if it's
  // empty when asked to pop so no need to factor that in here.
  assign loop_stack_pop = current_loop_finish;

  // Pops always commit, pushes only commit if the loop start is committing. The commit from a loop
  // start takes priority otherwise when we get an push and pop request at the same time, which
  // triggers a software error, we can commit whilst requesting push and pop which we should never
  // do.
  assign loop_stack_commit = loop_stack_push_req ? loop_start_commit_i : loop_stack_pop;

  ref_otbn_stack #(
    .StackWidth($bits(loop_addr_info_t)),
    .StackDepth(LoopStackDepth)
  ) loop_info_stack (
    .clk_i,
    .rst_ni,

    .full_o(loop_stack_full),

    .cnt_err_o(loop_stack_cnt_err),

    .clear_i(state_reset_i),

    .push_data_i(new_loop.loop_addr_info),
    .push_i     (loop_stack_push_req),

    .pop_i      (loop_stack_pop),
    .top_data_o (current_loop.loop_addr_info),
    .top_valid_o(current_loop_valid),

    .commit_i(loop_stack_commit),

    .stack_wr_idx_o(loop_stack_wr_idx),
    .stack_write_o (loop_stack_write),
    .stack_rd_idx_o(loop_stack_rd_idx),
    .stack_read_o  (),

    .next_top_data_o(next_loop_addr_info),
    .next_top_valid_o(next_loop_valid)
  );

  for(genvar i_count = 0; i_count < LoopStackDepth; i_count = i_count + 1) begin : g_loop_counters
    logic loop_count_set;
    logic loop_count_dec;

    assign loop_count_set = loop_stack_write & (loop_stack_wr_idx == i_count) & loop_stack_commit;
    assign loop_count_dec = current_loop_counter_dec & (loop_stack_rd_idx == i_count);

    //SEC_CM: LOOP_STACK.CTR.REDUN
    prim_count #(
      .Width(32),
      .ResetValue({32{1'b1}})
    ) u_loop_count (
      .clk_i,
      .rst_ni,
      .clr_i             (state_reset_i),
      .set_i             (loop_count_set),
      .set_cnt_i         (new_loop.loop_iterations),
      .incr_en_i         (1'b0),
      .decr_en_i         (loop_count_dec), // count down
      .step_i            (32'd1),
      .commit_i          (1'b1),
      .cnt_o             (loop_counters[i_count]),
      .cnt_after_commit_o(),
      .err_o             (loop_counter_err[i_count])
    );

    assign loop_counter_err_d[i_count] = loop_counter_err_q[i_count] | loop_counter_err[i_count];

    // Cannot clear and set prim_count in the same cycle
    `ASSERT(NoLoopCountClrAndSet_A, !(state_reset_i & loop_count_set))
  end

  prim_flop #(
    .Width(LoopStackDepth),
    .ResetValue('0)
  ) u_loop_counter_err_flop (
    .clk_i,
    .rst_ni,

    .d_i(loop_counter_err_d),
    .q_o(loop_counter_err_q)
  );

  assign current_loop.loop_iterations = loop_counters[loop_stack_rd_idx];

  assign current_loop_addrs_padded_intg_unbuf =
    {current_loop.loop_addr_info.loop_addrs_intg,
     {(32 - (ImemAddrWidth * 2) - 1){1'b0}},
     current_loop.loop_addr_info.loop_start,
     current_loop.loop_addr_info.loop_end};

  prim_buf #(
    .Width(39)
  ) u_current_loop_addrs_padded_intg_buf (
    .in_i (current_loop_addrs_padded_intg_unbuf),
    .out_o(current_loop_addrs_padded_intg_buf)
  );

  //SEC_CM: LOOP_STACK.ADDR.INTEGRITY
  prim_secded_inv_39_32_dec u_loop_addrs_intg_dec (
    .data_i     (current_loop_addrs_padded_intg_buf),
    .data_o     (),
    .syndrome_o (),
    .err_o      (current_loop_intg_err)
  );

  assign hw_err_o = (|loop_counter_err_d) |
                    loop_stack_cnt_err    |
                    ((|current_loop_intg_err) & current_loop_valid);

  assign predec_err_o =
    (loop_end_addr_predec_i != new_loop_end_addr_full[ImemAddrWidth-1:0]) & loop_start_req_i;

  // Forward info about loop state for next cycle to prefetch stage
  assign prefetch_loop_active_o = next_loop_valid;

  // Iterations for the current loop on the next cycle depend upon a number of factors
  // - If the loop stack is being popped the next counter on the stack provides the new iterations
  // - If the current loop iterations are being decremented new iterations are the decremented value
  // - If a new loop is starting it's iterations are the new iterations
  // - Otherwise next loop iterations is just the current loop iterations
  logic [31:0] current_loop_iterations_dec;
  logic [StackDepthW-1:0] loop_stack_rd_idx_dec;
  assign current_loop_iterations_dec = current_loop.loop_iterations - 32'd1;
  assign loop_stack_rd_idx_dec = loop_stack_rd_idx - 1'b1;
  assign prefetch_loop_iterations_o =
    loop_stack_pop           ? loop_counters[loop_stack_rd_idx_dec] :
    current_loop_counter_dec ? current_loop_iterations_dec          :
    loop_stack_write         ? new_loop.loop_iterations             :
                               current_loop.loop_iterations;

  logic unused_next_loop_addr_info_intg;
  assign unused_next_loop_addr_info_intg = ^next_loop_addr_info.loop_addrs_intg;

  assign prefetch_loop_end_addr_o  = next_loop_addr_info.loop_end;
  assign prefetch_loop_jump_addr_o = next_loop_addr_info.loop_start;

  // Check that an instruction that tries to cause a stack push and pop at the same time will be
  // reported as a SW error.
  `ASSERT(LoopStackPushAndPopCausesErr, loop_stack_push_req && loop_stack_pop |-> sw_err_o)
  `ASSERT(LoopStackPushAndPopNeverCommits,
    loop_stack_push_req && loop_stack_pop |-> ~loop_stack_commit)

  // The stack counter shouldn't get decremented at the same time as we write to the top of the loop
  // stack. This can only happen on a combined push and pop, which will cause a SW error (so the
  // contents of the stack will no longer matter any more).
  `ASSERT(NoLoopWriteIfCounterDec, current_loop_counter_dec |-> (!loop_stack_write | sw_err_o))
endmodule

// Copyright lowRISC contributors (OpenTitan project).
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// OpenTitan OTBN Start/Stop Secure Wipe, Loop Stack & Call Stack Subsystem Top (`ot_otbn_ctrl_top`)

module ref_ot_otbn_ctrl_top
  import otbn_pkg::*;
  import prim_mubi_pkg::*;
#(
  parameter int ImemAddrWidth  = 12,
  parameter int CallStackWidth = 32,
  parameter int CallStackDepth = 8
) (
  input  logic                      clk_i,
  input  logic                      rst_ni,
  input  logic                      start_i,
  input  mubi4_t                    escalate_en_i,
  input  mubi4_t                    rma_req_i,
  output mubi4_t                    rma_ack_o,
  output logic                      controller_start_o,
  output logic                      urnd_reseed_req_o,
  input  logic                      urnd_reseed_ack_i,
  output logic                      urnd_reseed_err_o,
  output logic                      urnd_advance_o,
  output logic                      urnd_must_advance_o,
  input  logic                      secure_wipe_req_i,
  output logic                      secure_wipe_ack_o,
  output logic                      secure_wipe_running_o,
  output logic                      done_o,
  output logic                      sec_wipe_wdr_o,
  output logic                      sec_wipe_wdr_urnd_o,
  output logic                      sec_wipe_base_o,
  output logic                      sec_wipe_base_urnd_o,
  output logic [4:0]                sec_wipe_addr_o,
  output logic                      sec_wipe_mac_urnd_o,
  output logic                      sec_wipe_mod_urnd_o,
  output logic                      sec_wipe_zero_o,
  output logic                      ispr_init_o,
  output logic                      state_reset_o,
  output logic                      insn_cnt_clear_int_o,
  output logic                      start_stop_fatal_error_o,
  input  logic                      insn_valid_i,
  input  logic [ImemAddrWidth-1:0]  insn_addr_i,
  input  logic [ImemAddrWidth-1:0]  next_insn_addr_i,
  input  logic                      loop_start_req_i,
  input  logic                      loop_start_commit_i,
  input  logic [11:0]               loop_bodysize_i,
  input  logic [31:0]               loop_iterations_i,
  input  logic [ImemAddrWidth-1:0]  loop_end_addr_predec_i,
  output logic                      loop_jump_o,
  output logic [ImemAddrWidth-1:0]  loop_jump_addr_o,
  output logic                      loop_sw_err_o,
  output logic                      loop_hw_err_o,
  output logic                      loop_predec_err_o,
  output logic                      prefetch_loop_active_o,
  output logic [31:0]               prefetch_loop_iterations_o,
  output logic [ImemAddrWidth:0]    prefetch_loop_end_addr_o,
  output logic [ImemAddrWidth-1:0]  prefetch_loop_jump_addr_o,
  input  logic                      jump_or_branch_i,
  input  logic                      otbn_stall_i,
  input  logic                      call_stack_push_i,
  input  logic [CallStackWidth-1:0] call_stack_push_data_i,
  input  logic                      call_stack_pop_i,
  input  logic                      call_stack_commit_i,
  output logic                      call_stack_full_o,
  output logic                      call_stack_cnt_err_o,
  output logic [CallStackWidth-1:0] call_stack_top_data_o,
  output logic                      call_stack_top_valid_o,
  output logic [CallStackWidth-1:0] call_stack_next_top_data_o,
  output logic                      call_stack_next_top_valid_o
);

  logic state_reset;
  logic sec_wipe_zero;
  assign state_reset_o   = state_reset;
  assign sec_wipe_zero_o = sec_wipe_zero;

  ref_otbn_start_stop_control u_start_stop (
    .clk_i                       (clk_i),
    .rst_ni                      (rst_ni),
    .start_i                     (start_i),
    .escalate_en_i               (escalate_en_i),
    .rma_req_i                   (rma_req_i),
    .rma_ack_o                   (rma_ack_o),
    .controller_start_o          (controller_start_o),
    .urnd_reseed_req_o           (urnd_reseed_req_o),
    .urnd_reseed_ack_i           (urnd_reseed_ack_i),
    .urnd_reseed_err_o           (urnd_reseed_err_o),
    .urnd_advance_o              (urnd_advance_o),
    .urnd_must_advance_o         (urnd_must_advance_o),
    .secure_wipe_req_i           (secure_wipe_req_i),
    .secure_wipe_ack_o           (secure_wipe_ack_o),
    .secure_wipe_running_o       (secure_wipe_running_o),
    .done_o                      (done_o),
    .sec_wipe_wdr_o              (sec_wipe_wdr_o),
    .sec_wipe_wdr_urnd_o         (sec_wipe_wdr_urnd_o),
    .sec_wipe_base_o             (sec_wipe_base_o),
    .sec_wipe_base_urnd_o        (sec_wipe_base_urnd_o),
    .sec_wipe_addr_o             (sec_wipe_addr_o),
    .sec_wipe_mac_urnd_o         (sec_wipe_mac_urnd_o),
    .sec_wipe_mod_urnd_o         (sec_wipe_mod_urnd_o),
    .sec_wipe_zero_o             (sec_wipe_zero),
    .sec_wipe_mai_in0_s0_urnd_o  (),
    .sec_wipe_mai_in0_s1_urnd_o  (),
    .sec_wipe_mai_in1_s0_urnd_o  (),
    .sec_wipe_mai_in1_s1_urnd_o  (),
    .sec_wipe_mai_res_s0_urnd_o  (),
    .sec_wipe_mai_res_s1_urnd_o  (),
    .sec_wipe_kmac_data_s0_urnd_o(),
    .sec_wipe_kmac_data_s1_urnd_o(),
    .ispr_init_o                 (ispr_init_o),
    .state_reset_o               (state_reset),
    .insn_cnt_clear_int_o        (insn_cnt_clear_int_o),
    .fatal_error_o               (start_stop_fatal_error_o)
  );

  ref_otbn_loop_controller #(
    .ImemAddrWidth(ImemAddrWidth)
  ) u_loop_ctrl (
    .clk_i                     (clk_i),
    .rst_ni                    (rst_ni),
    .state_reset_i             (state_reset | sec_wipe_zero),
    .insn_valid_i              (insn_valid_i),
    .insn_addr_i               (insn_addr_i),
    .next_insn_addr_i          (next_insn_addr_i),
    .loop_start_req_i          (loop_start_req_i),
    .loop_start_commit_i       (loop_start_commit_i),
    .loop_bodysize_i           (loop_bodysize_i),
    .loop_iterations_i         (loop_iterations_i),
    .loop_end_addr_predec_i    (loop_end_addr_predec_i),
    .loop_jump_o               (loop_jump_o),
    .loop_jump_addr_o          (loop_jump_addr_o),
    .sw_err_o                  (loop_sw_err_o),
    .hw_err_o                  (loop_hw_err_o),
    .predec_err_o              (loop_predec_err_o),
    .prefetch_loop_active_o    (prefetch_loop_active_o),
    .prefetch_loop_iterations_o(prefetch_loop_iterations_o),
    .prefetch_loop_end_addr_o  (prefetch_loop_end_addr_o),
    .prefetch_loop_jump_addr_o (prefetch_loop_jump_addr_o),
    .jump_or_branch_i          (jump_or_branch_i),
    .otbn_stall_i              (otbn_stall_i)
  );

  ref_otbn_stack #(
    .StackWidth(CallStackWidth),
    .StackDepth(CallStackDepth)
  ) u_call_stack (
    .clk_i           (clk_i),
    .rst_ni          (rst_ni),
    .full_o          (call_stack_full_o),
    .cnt_err_o       (call_stack_cnt_err_o),
    .clear_i         (state_reset | sec_wipe_zero),
    .push_i          (call_stack_push_i),
    .push_data_i     (call_stack_push_data_i),
    .pop_i           (call_stack_pop_i),
    .top_data_o      (call_stack_top_data_o),
    .top_valid_o     (call_stack_top_valid_o),
    .commit_i        (call_stack_commit_i),
    .stack_wr_idx_o  (),
    .stack_write_o   (),
    .stack_rd_idx_o  (),
    .stack_read_o    (),
    .next_top_data_o (call_stack_next_top_data_o),
    .next_top_valid_o(call_stack_next_top_valid_o)
  );

endmodule


module tb;
  import otbn_pkg::*;
  import prim_mubi_pkg::*;

  localparam int ImemAddrWidth  = 12;
  localparam int CallStackWidth = 32;
  localparam int CallStackDepth = 8;

  logic                      clk_i;
  logic                      rst_ni;
  logic                      start_i;
  mubi4_t                    escalate_en_i;
  mubi4_t                    rma_req_i;
  logic                      urnd_reseed_ack_i;
  logic                      secure_wipe_req_i;
  logic                      insn_valid_i;
  logic [ImemAddrWidth-1:0]  insn_addr_i;
  logic [ImemAddrWidth-1:0]  next_insn_addr_i;
  logic                      loop_start_req_i;
  logic                      loop_start_commit_i;
  logic [11:0]               loop_bodysize_i;
  logic [31:0]               loop_iterations_i;
  logic [ImemAddrWidth-1:0]  loop_end_addr_predec_i;
  logic                      jump_or_branch_i;
  logic                      otbn_stall_i;
  logic                      call_stack_push_i;
  logic [CallStackWidth-1:0] call_stack_push_data_i;
  logic                      call_stack_pop_i;
  logic                      call_stack_commit_i;

  // DUT vs Ref outputs
  mubi4_t                    dut_rma_ack_o, ref_rma_ack_o;
  logic                      dut_controller_start_o, ref_controller_start_o;
  logic                      dut_urnd_reseed_req_o, ref_urnd_reseed_req_o;
  logic                      dut_urnd_reseed_err_o, ref_urnd_reseed_err_o;
  logic                      dut_urnd_advance_o, ref_urnd_advance_o;
  logic                      dut_urnd_must_advance_o, ref_urnd_must_advance_o;
  logic                      dut_secure_wipe_ack_o, ref_secure_wipe_ack_o;
  logic                      dut_secure_wipe_running_o, ref_secure_wipe_running_o;
  logic                      dut_done_o, ref_done_o;
  logic                      dut_sec_wipe_wdr_o, ref_sec_wipe_wdr_o;
  logic                      dut_sec_wipe_wdr_urnd_o, ref_sec_wipe_wdr_urnd_o;
  logic                      dut_sec_wipe_base_o, ref_sec_wipe_base_o;
  logic                      dut_sec_wipe_base_urnd_o, ref_sec_wipe_base_urnd_o;
  logic [4:0]                dut_sec_wipe_addr_o, ref_sec_wipe_addr_o;
  logic                      dut_sec_wipe_mac_urnd_o, ref_sec_wipe_mac_urnd_o;
  logic                      dut_sec_wipe_mod_urnd_o, ref_sec_wipe_mod_urnd_o;
  logic                      dut_sec_wipe_zero_o, ref_sec_wipe_zero_o;
  logic                      dut_ispr_init_o, ref_ispr_init_o;
  logic                      dut_state_reset_o, ref_state_reset_o;
  logic                      dut_insn_cnt_clear_int_o, ref_insn_cnt_clear_int_o;
  logic                      dut_start_stop_fatal_error_o, ref_start_stop_fatal_error_o;
  logic                      dut_loop_jump_o, ref_loop_jump_o;
  logic [ImemAddrWidth-1:0]  dut_loop_jump_addr_o, ref_loop_jump_addr_o;
  logic                      dut_loop_sw_err_o, ref_loop_sw_err_o;
  logic                      dut_loop_hw_err_o, ref_loop_hw_err_o;
  logic                      dut_loop_predec_err_o, ref_loop_predec_err_o;
  logic                      dut_prefetch_loop_active_o, ref_prefetch_loop_active_o;
  logic [31:0]               dut_prefetch_loop_iterations_o, ref_prefetch_loop_iterations_o;
  logic [ImemAddrWidth:0]    dut_prefetch_loop_end_addr_o, ref_prefetch_loop_end_addr_o;
  logic [ImemAddrWidth-1:0]  dut_prefetch_loop_jump_addr_o, ref_prefetch_loop_jump_addr_o;
  logic                      dut_call_stack_full_o, ref_call_stack_full_o;
  logic                      dut_call_stack_cnt_err_o, ref_call_stack_cnt_err_o;
  logic [CallStackWidth-1:0] dut_call_stack_top_data_o, ref_call_stack_top_data_o;
  logic                      dut_call_stack_top_valid_o, ref_call_stack_top_valid_o;
  logic [CallStackWidth-1:0] dut_call_stack_next_top_data_o, ref_call_stack_next_top_data_o;
  logic                      dut_call_stack_next_top_valid_o, ref_call_stack_next_top_valid_o;

  ot_otbn_ctrl_top #(
    .ImemAddrWidth (ImemAddrWidth),
    .CallStackWidth(CallStackWidth),
    .CallStackDepth(CallStackDepth)
  ) dut (
    .clk_i                     (clk_i),
    .rst_ni                    (rst_ni),
    .start_i                   (start_i),
    .escalate_en_i             (escalate_en_i),
    .rma_req_i                 (rma_req_i),
    .rma_ack_o                 (dut_rma_ack_o),
    .controller_start_o        (dut_controller_start_o),
    .urnd_reseed_req_o         (dut_urnd_reseed_req_o),
    .urnd_reseed_ack_i         (urnd_reseed_ack_i),
    .urnd_reseed_err_o         (dut_urnd_reseed_err_o),
    .urnd_advance_o            (dut_urnd_advance_o),
    .urnd_must_advance_o       (dut_urnd_must_advance_o),
    .secure_wipe_req_i         (secure_wipe_req_i),
    .secure_wipe_ack_o         (dut_secure_wipe_ack_o),
    .secure_wipe_running_o     (dut_secure_wipe_running_o),
    .done_o                    (dut_done_o),
    .sec_wipe_wdr_o            (dut_sec_wipe_wdr_o),
    .sec_wipe_wdr_urnd_o       (dut_sec_wipe_wdr_urnd_o),
    .sec_wipe_base_o           (dut_sec_wipe_base_o),
    .sec_wipe_base_urnd_o      (dut_sec_wipe_base_urnd_o),
    .sec_wipe_addr_o           (dut_sec_wipe_addr_o),
    .sec_wipe_mac_urnd_o       (dut_sec_wipe_mac_urnd_o),
    .sec_wipe_mod_urnd_o       (dut_sec_wipe_mod_urnd_o),
    .sec_wipe_zero_o           (dut_sec_wipe_zero_o),
    .ispr_init_o               (dut_ispr_init_o),
    .state_reset_o             (dut_state_reset_o),
    .insn_cnt_clear_int_o      (dut_insn_cnt_clear_int_o),
    .start_stop_fatal_error_o  (dut_start_stop_fatal_error_o),
    .insn_valid_i              (insn_valid_i),
    .insn_addr_i               (insn_addr_i),
    .next_insn_addr_i          (next_insn_addr_i),
    .loop_start_req_i          (loop_start_req_i),
    .loop_start_commit_i       (loop_start_commit_i),
    .loop_bodysize_i           (loop_bodysize_i),
    .loop_iterations_i         (loop_iterations_i),
    .loop_end_addr_predec_i    (loop_end_addr_predec_i),
    .loop_jump_o               (dut_loop_jump_o),
    .loop_jump_addr_o          (dut_loop_jump_addr_o),
    .loop_sw_err_o             (dut_loop_sw_err_o),
    .loop_hw_err_o             (dut_loop_hw_err_o),
    .loop_predec_err_o         (dut_loop_predec_err_o),
    .prefetch_loop_active_o    (dut_prefetch_loop_active_o),
    .prefetch_loop_iterations_o(dut_prefetch_loop_iterations_o),
    .prefetch_loop_end_addr_o  (dut_prefetch_loop_end_addr_o),
    .prefetch_loop_jump_addr_o (dut_prefetch_loop_jump_addr_o),
    .jump_or_branch_i          (jump_or_branch_i),
    .otbn_stall_i              (otbn_stall_i),
    .call_stack_push_i         (call_stack_push_i),
    .call_stack_push_data_i    (call_stack_push_data_i),
    .call_stack_pop_i          (call_stack_pop_i),
    .call_stack_commit_i       (call_stack_commit_i),
    .call_stack_full_o         (dut_call_stack_full_o),
    .call_stack_cnt_err_o      (dut_call_stack_cnt_err_o),
    .call_stack_top_data_o     (dut_call_stack_top_data_o),
    .call_stack_top_valid_o    (dut_call_stack_top_valid_o),
    .call_stack_next_top_data_o(dut_call_stack_next_top_data_o),
    .call_stack_next_top_valid_o(dut_call_stack_next_top_valid_o)
  );

  ref_ot_otbn_ctrl_top #(
    .ImemAddrWidth (ImemAddrWidth),
    .CallStackWidth(CallStackWidth),
    .CallStackDepth(CallStackDepth)
  ) u_ref (
    .clk_i                     (clk_i),
    .rst_ni                    (rst_ni),
    .start_i                   (start_i),
    .escalate_en_i             (escalate_en_i),
    .rma_req_i                 (rma_req_i),
    .rma_ack_o                 (ref_rma_ack_o),
    .controller_start_o        (ref_controller_start_o),
    .urnd_reseed_req_o         (ref_urnd_reseed_req_o),
    .urnd_reseed_ack_i         (urnd_reseed_ack_i),
    .urnd_reseed_err_o         (ref_urnd_reseed_err_o),
    .urnd_advance_o            (ref_urnd_advance_o),
    .urnd_must_advance_o       (ref_urnd_must_advance_o),
    .secure_wipe_req_i         (secure_wipe_req_i),
    .secure_wipe_ack_o         (ref_secure_wipe_ack_o),
    .secure_wipe_running_o     (ref_secure_wipe_running_o),
    .done_o                    (ref_done_o),
    .sec_wipe_wdr_o            (ref_sec_wipe_wdr_o),
    .sec_wipe_wdr_urnd_o       (ref_sec_wipe_wdr_urnd_o),
    .sec_wipe_base_o           (ref_sec_wipe_base_o),
    .sec_wipe_base_urnd_o      (ref_sec_wipe_base_urnd_o),
    .sec_wipe_addr_o           (ref_sec_wipe_addr_o),
    .sec_wipe_mac_urnd_o       (ref_sec_wipe_mac_urnd_o),
    .sec_wipe_mod_urnd_o       (ref_sec_wipe_mod_urnd_o),
    .sec_wipe_zero_o           (ref_sec_wipe_zero_o),
    .ispr_init_o               (ref_ispr_init_o),
    .state_reset_o             (ref_state_reset_o),
    .insn_cnt_clear_int_o      (ref_insn_cnt_clear_int_o),
    .start_stop_fatal_error_o  (ref_start_stop_fatal_error_o),
    .insn_valid_i              (insn_valid_i),
    .insn_addr_i               (insn_addr_i),
    .next_insn_addr_i          (next_insn_addr_i),
    .loop_start_req_i          (loop_start_req_i),
    .loop_start_commit_i       (loop_start_commit_i),
    .loop_bodysize_i           (loop_bodysize_i),
    .loop_iterations_i         (loop_iterations_i),
    .loop_end_addr_predec_i    (loop_end_addr_predec_i),
    .loop_jump_o               (ref_loop_jump_o),
    .loop_jump_addr_o          (ref_loop_jump_addr_o),
    .loop_sw_err_o             (ref_loop_sw_err_o),
    .loop_hw_err_o             (ref_loop_hw_err_o),
    .loop_predec_err_o         (ref_loop_predec_err_o),
    .prefetch_loop_active_o    (ref_prefetch_loop_active_o),
    .prefetch_loop_iterations_o(ref_prefetch_loop_iterations_o),
    .prefetch_loop_end_addr_o  (ref_prefetch_loop_end_addr_o),
    .prefetch_loop_jump_addr_o (ref_prefetch_loop_jump_addr_o),
    .jump_or_branch_i          (jump_or_branch_i),
    .otbn_stall_i              (otbn_stall_i),
    .call_stack_push_i         (call_stack_push_i),
    .call_stack_push_data_i    (call_stack_push_data_i),
    .call_stack_pop_i          (call_stack_pop_i),
    .call_stack_commit_i       (call_stack_commit_i),
    .call_stack_full_o         (ref_call_stack_full_o),
    .call_stack_cnt_err_o      (ref_call_stack_cnt_err_o),
    .call_stack_top_data_o     (ref_call_stack_top_data_o),
    .call_stack_top_valid_o    (ref_call_stack_top_valid_o),
    .call_stack_next_top_data_o(ref_call_stack_next_top_data_o),
    .call_stack_next_top_valid_o(ref_call_stack_next_top_valid_o)
  );

  int err_cnt = 0;
  int cyc_cnt = 0;

  initial clk_i = 1'b0;
  always #5 clk_i = ~clk_i;

  task automatic check_all();
    if (dut_rma_ack_o                  !== ref_rma_ack_o                  ||
        dut_controller_start_o         !== ref_controller_start_o         ||
        dut_urnd_reseed_req_o          !== ref_urnd_reseed_req_o          ||
        dut_urnd_reseed_err_o          !== ref_urnd_reseed_err_o          ||
        dut_urnd_advance_o             !== ref_urnd_advance_o             ||
        dut_urnd_must_advance_o        !== ref_urnd_must_advance_o        ||
        dut_secure_wipe_ack_o          !== ref_secure_wipe_ack_o          ||
        dut_secure_wipe_running_o      !== ref_secure_wipe_running_o      ||
        dut_done_o                     !== ref_done_o                     ||
        dut_sec_wipe_wdr_o             !== ref_sec_wipe_wdr_o             ||
        dut_sec_wipe_wdr_urnd_o        !== ref_sec_wipe_wdr_urnd_o        ||
        dut_sec_wipe_base_o            !== ref_sec_wipe_base_o            ||
        dut_sec_wipe_base_urnd_o       !== ref_sec_wipe_base_urnd_o       ||
        dut_sec_wipe_addr_o            !== ref_sec_wipe_addr_o            ||
        dut_sec_wipe_mac_urnd_o        !== ref_sec_wipe_mac_urnd_o        ||
        dut_sec_wipe_mod_urnd_o        !== ref_sec_wipe_mod_urnd_o        ||
        dut_sec_wipe_zero_o            !== ref_sec_wipe_zero_o            ||
        dut_ispr_init_o                !== ref_ispr_init_o                ||
        dut_state_reset_o              !== ref_state_reset_o              ||
        dut_insn_cnt_clear_int_o       !== ref_insn_cnt_clear_int_o       ||
        dut_start_stop_fatal_error_o   !== ref_start_stop_fatal_error_o   ||
        dut_loop_jump_o                !== ref_loop_jump_o                ||
        (ref_loop_jump_o && (dut_loop_jump_addr_o !== ref_loop_jump_addr_o)) ||
        dut_loop_sw_err_o              !== ref_loop_sw_err_o              ||
        dut_loop_hw_err_o              !== ref_loop_hw_err_o              ||
        dut_loop_predec_err_o          !== ref_loop_predec_err_o          ||
        dut_prefetch_loop_active_o     !== ref_prefetch_loop_active_o     ||
        (ref_prefetch_loop_active_o && (dut_prefetch_loop_iterations_o !== ref_prefetch_loop_iterations_o ||
                                        dut_prefetch_loop_end_addr_o   !== ref_prefetch_loop_end_addr_o   ||
                                        dut_prefetch_loop_jump_addr_o  !== ref_prefetch_loop_jump_addr_o)) ||
        dut_call_stack_full_o          !== ref_call_stack_full_o          ||
        dut_call_stack_cnt_err_o       !== ref_call_stack_cnt_err_o       ||
        dut_call_stack_top_valid_o     !== ref_call_stack_top_valid_o     ||
        (ref_call_stack_top_valid_o && (dut_call_stack_top_data_o !== ref_call_stack_top_data_o)) ||
        dut_call_stack_next_top_valid_o !== ref_call_stack_next_top_valid_o ||
        (ref_call_stack_next_top_valid_o && (dut_call_stack_next_top_data_o !== ref_call_stack_next_top_data_o))) begin
      if (err_cnt < 20) begin
        $display("MISMATCH cyc=%0d wipe_run=%b/%b wipe_ack=%b/%b rma_ack=%h/%h ljmp=%b/%b sw_err=%b/%b pre_act=%b/%b pre_it=%0d/%0d cs_vld=%b/%b cs_top=%h/%h",
                 cyc_cnt, dut_secure_wipe_running_o, ref_secure_wipe_running_o,
                 dut_secure_wipe_ack_o, ref_secure_wipe_ack_o,
                 dut_rma_ack_o, ref_rma_ack_o,
                 dut_loop_jump_o, ref_loop_jump_o,
                 dut_loop_sw_err_o, ref_loop_sw_err_o,
                 dut_prefetch_loop_active_o, ref_prefetch_loop_active_o,
                 dut_prefetch_loop_iterations_o, ref_prefetch_loop_iterations_o,
                 dut_call_stack_top_valid_o, ref_call_stack_top_valid_o,
                 dut_call_stack_top_data_o, ref_call_stack_top_data_o);
      end
      err_cnt++;
    end
  endtask

  task automatic step();
    #1;
    if (rst_ni) check_all();
    @(posedge clk_i);
    #1;
    cyc_cnt++;
    if (rst_ni) check_all();
  endtask

  task automatic reset_all();
    rst_ni                 = 1'b0;
    start_i                = 1'b0;
    escalate_en_i          = MuBi4False;
    rma_req_i              = MuBi4False;
    urnd_reseed_ack_i      = 1'b0;
    secure_wipe_req_i      = 1'b0;
    insn_valid_i           = 1'b0;
    insn_addr_i            = '0;
    next_insn_addr_i       = '0;
    loop_start_req_i       = 1'b0;
    loop_start_commit_i    = 1'b0;
    loop_bodysize_i        = '0;
    loop_iterations_i      = '0;
    loop_end_addr_predec_i = '0;
    jump_or_branch_i       = 1'b0;
    otbn_stall_i           = 1'b0;
    call_stack_push_i      = 1'b0;
    call_stack_push_data_i = '0;
    call_stack_pop_i       = 1'b0;
    call_stack_commit_i    = 1'b0;
    @(posedge clk_i);
    @(posedge clk_i);
    rst_ni = 1'b1;
    step();
  endtask

  initial begin
    reset_all();

    // ----------------------------------------------------------------------
    // Test 1: Initial two-round secure wipe -> Halt -> Start -> Running
    // ----------------------------------------------------------------------
    // Wait 2 cycles in Initial, then ack URND reseed
    step();
    urnd_reseed_ack_i = 1'b1;
    step();
    urnd_reseed_ack_i = 1'b0;
    // Wait until urnd_reseed_req_o asserts for the 2nd round of wiping
    for (int w = 0; w < 250 && !ref_urnd_reseed_req_o; w++) begin
      step();
    end
    step();
    urnd_reseed_ack_i = 1'b1;
    step();
    urnd_reseed_ack_i = 1'b0;
    // Wait until initial secure wipe completes (secure_wipe_running_o == 0)
    for (int w = 0; w < 250 && ref_secure_wipe_running_o; w++) begin
      step();
    end
    step();
    // Start OTBN execution
    start_i = 1'b1;
    step();
    start_i = 1'b0;
    step();
    urnd_reseed_ack_i = 1'b1;
    step();
    urnd_reseed_ack_i = 1'b0;
    step();

    // ----------------------------------------------------------------------
    // Test 2: Call Stack full-depth push, simultaneous push+pop on full/partial,
    // non-committed preview, and pop to empty
    // ----------------------------------------------------------------------
    for (int i = 0; i < CallStackDepth; i++) begin
      call_stack_push_i      = 1'b1;
      call_stack_push_data_i = 32'hA000_0100 + i * 4;
      call_stack_commit_i    = 1'b1;
      step();
    end
    call_stack_push_i   = 1'b0;
    call_stack_commit_i = 1'b0;
    step();
    // Simultaneous push+pop when full (must replace top element without dropping!)
    call_stack_push_i      = 1'b1;
    call_stack_pop_i       = 1'b1;
    call_stack_push_data_i = 32'hCAFE_BEEF;
    call_stack_commit_i    = 1'b1;
    step();
    call_stack_push_i   = 1'b0;
    call_stack_pop_i    = 1'b0;
    call_stack_commit_i = 1'b0;
    step();
    // Preview pop without commit
    call_stack_pop_i    = 1'b1;
    call_stack_commit_i = 1'b0;
    step();
    // Commit pop
    call_stack_commit_i = 1'b1;
    step();
    call_stack_pop_i    = 1'b0;
    call_stack_commit_i = 1'b0;
    step();
    // Simultaneous push+pop when not full
    call_stack_push_i      = 1'b1;
    call_stack_pop_i       = 1'b1;
    call_stack_push_data_i = 32'h1234_5678;
    call_stack_commit_i    = 1'b1;
    step();
    call_stack_push_i   = 1'b0;
    call_stack_pop_i    = 1'b0;
    call_stack_commit_i = 1'b0;
    // Pop all remaining entries
    for (int i = 0; i < CallStackDepth; i++) begin
      call_stack_pop_i    = 1'b1;
      call_stack_commit_i = 1'b1;
      step();
    end
    call_stack_pop_i    = 1'b0;
    call_stack_commit_i = 1'b0;
    step();

    // ----------------------------------------------------------------------
    // Test 3: Nested Loop Controller Execution & Boundary Error Conditions
    // ----------------------------------------------------------------------
    // Push Outer Loop (start=0x014, bodysize=3 -> end = 0x010 + 12 + 4 = 0x020, iterations=2)
    insn_valid_i           = 1'b1;
    insn_addr_i            = 12'h010;
    next_insn_addr_i       = 12'h014;
    loop_start_req_i       = 1'b1;
    loop_start_commit_i    = 1'b1;
    loop_bodysize_i        = 12'd3;
    loop_iterations_i      = 32'd2;
    loop_end_addr_predec_i = 12'h020;
    step();
    loop_start_req_i    = 1'b0;
    loop_start_commit_i = 1'b0;

    // Push Inner Loop at 0x014 (start=0x018, bodysize=1 -> end = 0x014 + 4 + 4 = 0x01C, iterations=2)
    insn_addr_i            = 12'h014;
    next_insn_addr_i       = 12'h018;
    loop_start_req_i       = 1'b1;
    loop_start_commit_i    = 1'b1;
    loop_bodysize_i        = 12'd1;
    loop_iterations_i      = 32'd2;
    loop_end_addr_predec_i = 12'h01C;
    step();
    loop_start_req_i    = 1'b0;
    loop_start_commit_i = 1'b0;

    // Execute Inner Loop iter 1 at 0x01C (jumps back to 0x018, decrements inner to 1)
    insn_addr_i      = 12'h01C;
    next_insn_addr_i = 12'h018;
    step();

    // Finish Inner Loop iter 2 cleanly at 0x01C -> pops Inner Loop, restores Outer Loop (iterations=2, end=0x020)!
    insn_addr_i      = 12'h01C;
    next_insn_addr_i = 12'h020;
    step();

    // Reach Outer Loop iter 1 end at 0x020 -> jumps to 0x014, decrements Outer Loop to 1
    insn_addr_i      = 12'h020;
    next_insn_addr_i = 12'h014;
    step();

    // Test loop_at_end_err when stack is NOT full (depth=1 at 0x020)
    otbn_stall_i           = 1'b1;
    loop_start_req_i       = 1'b1;
    loop_start_commit_i    = 1'b0;
    loop_bodysize_i        = 12'd1;
    loop_iterations_i      = 32'd2;
    loop_end_addr_predec_i = 12'h028;
    step();
    loop_start_req_i = 1'b0;
    // Test jump_or_branch_i at loop end (loop_branch_err) and predec_err_o and zero iterations
    jump_or_branch_i = 1'b1;
    otbn_stall_i     = 1'b1;
    step();
    jump_or_branch_i = 1'b0;
    otbn_stall_i     = 1'b0;
    // Finish Outer Loop iter 2 at 0x020 -> pops Outer Loop, stack now empty!
    step();

    // Test zero-iteration loop_iteration_err and predec_err_o
    insn_addr_i            = 12'h030;
    next_insn_addr_i       = 12'h034;
    loop_start_req_i       = 1'b1;
    loop_start_commit_i    = 1'b0;
    loop_bodysize_i        = 12'd2;
    loop_iterations_i      = 32'd0;
    loop_end_addr_predec_i = 12'h040;
    step();
    loop_start_req_i = 1'b0;
    step();

    // Push 8 nested loops to fill the loop stack and test overflow on the 9th
    for (int l = 0; l < 8; l++) begin
      insn_addr_i            = 12'(l * 16 + 4);
      next_insn_addr_i       = 12'(l * 16 + 8);
      loop_start_req_i       = 1'b1;
      loop_start_commit_i    = 1'b1;
      loop_bodysize_i        = 12'd1;
      loop_iterations_i      = 32'(l + 2);
      loop_end_addr_predec_i = 12'(l * 16 + 12);
      step();
    end
    // 9th push when full -> loop_stack_overflow_err (commit=0)
    loop_start_req_i    = 1'b1;
    loop_start_commit_i = 1'b0;
    step();
    loop_start_req_i = 1'b0;
    // Now at the end of the 8th nested loop (addr = 7*16 + 12 = 124 = 12'h07C), first decrement it from 9 down to 1:
    insn_addr_i      = 12'h07C;
    next_insn_addr_i = 12'h078;
    repeat (8) step();
    // Now the 8th nested loop has 1 iteration left (at 12'h07C, current_loop_finish == 1):
    // Test illegal loop_start_req_i at loop end with loop_start_commit_i = 0!
    // Must assert loop_sw_err_o (loop_at_end_err) AND must NOT commit push/pop (stack stays full)!
    loop_start_req_i       = 1'b1;
    loop_start_commit_i    = 1'b0;
    loop_bodysize_i        = 12'd1;
    loop_iterations_i      = 32'd2;
    loop_end_addr_predec_i = 12'h084;
    step();
    loop_start_req_i = 1'b0;
    insn_valid_i     = 1'b0;
    step();

    // ----------------------------------------------------------------------
    // Test 4: Runtime Secure Wipe -> Halt -> RMA Request Secure Wipe ->rma_ack_o
    // ----------------------------------------------------------------------
    secure_wipe_req_i = 1'b1;
    step();
    for (int w = 0; w < 250 && !ref_urnd_reseed_req_o; w++) begin
      step();
    end
    step();
    urnd_reseed_ack_i = 1'b1;
    step();
    urnd_reseed_ack_i = 1'b0;
    for (int w = 0; w < 250 && !ref_secure_wipe_ack_o; w++) begin
      step();
    end
    secure_wipe_req_i = 1'b0;
    step();
    step();

    // Now in Halt: assert rma_req_i = MuBi4True -> must wipe and set rma_ack_o = MuBi4True!
    rma_req_i = MuBi4True;
    step();
    for (int w = 0; w < 250 && ref_secure_wipe_running_o; w++) begin
      step();
    end
    repeat (3) step();
    if (dut_rma_ack_o !== MuBi4True) begin
      $display("FAIL: rma_ack_o did not assert MuBi4True after RMA wipe");
      err_cnt++;
    end

    if (err_cnt == 0) begin
      $display("PASS: All ot_otbn_ctrl_top verification checks succeeded (%0d cycles).", cyc_cnt);
      $finish;
    end else begin
      $display("FAIL: %0d mismatches detected.", err_cnt);
      $fatal(1, "Verification failed");
    end
  end
endmodule
