// Copyright lowRISC contributors (OpenTitan project).
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

`include "prim_assert.sv"

module otbn_start_stop_control
  import otbn_pkg::*;
  import prim_mubi_pkg::*;
#(
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
  logic first_wipe_round;

  logic esc_request, rma_request, should_lock_d, should_lock_q, stop;
  assign esc_request      = mubi4_test_true_loose(escalate_en_i);
  assign rma_request      = mubi4_test_true_strict(rma_req_i);
  assign stop             = esc_request | rma_request | secure_wipe_req_i;
  assign should_lock_d    = should_lock_q | esc_request | rma_request;
  assign first_wipe_round = mubi4_test_false_strict(wipe_after_urnd_refresh_q);

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
          state_d                   = OtbnStartStopSecureWipeWdrUrnd;
          wipe_after_urnd_refresh_d = MuBi4True;
        end else if (urnd_reseed_ack_i) begin
          urnd_advance_o = 1'b1;
          state_d        = OtbnStartStopSecureWipeWdrUrnd;
        end
      end
      OtbnStartStopStateHalt: begin
        state_reset_o = 1'b1;

        if (stop && !rma_request) begin
          state_d = OtbnStartStopStateLocked;
        end else if (start_i || rma_request) begin
          ispr_init_o          = 1'b1;
          insn_cnt_clear_int_o = 1'b1;
          if (rma_request) begin
            secure_wipe_running_d     = 1'b1;
            state_d                   = OtbnStartStopSecureWipeWdrUrnd;
            wipe_after_urnd_refresh_d = MuBi4True;
          end else begin
            urnd_reseed_req_o = ~SecSkipUrndReseedAtStart;
            state_d           = OtbnStartStopStateUrndRefresh;
          end
        end
      end
      OtbnStartStopStateUrndRefresh: begin
        urnd_reseed_req_o = ~skip_reseed_q;
        if (!first_wipe_round) begin
          allow_secure_wipe     = 1'b1;
          expect_secure_wipe    = 1'b1;
          secure_wipe_running_d = 1'b1;
          if (urnd_reseed_ack_i) begin
            state_d = OtbnStartStopSecureWipeWdrUrnd;
          end
        end else if (stop) begin
          state_d = OtbnStartStopStateLocked;
        end else if (urnd_reseed_ack_i || skip_reseed_q) begin
          state_d = OtbnStartStopStateRunning;
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
      OtbnStartStopSecureWipeWdrUrnd: begin
        urnd_advance_o        = 1'b1;
        addr_cnt_inc          = (addr_cnt_q != 6'b100000);
        sec_wipe_wdr_o        = (addr_cnt_q != 6'b100000);
        sec_wipe_wdr_urnd_o   = (addr_cnt_q != 6'b100000);
        allow_secure_wipe     = 1'b1;
        expect_secure_wipe    = 1'b1;
        secure_wipe_running_d = 1'b1;

        if (addr_cnt_q == 6'b100000) begin
          state_d = OtbnStartStopSecureWipeAccModBaseUrnd;
        end
      end
      OtbnStartStopSecureWipeAccModBaseUrnd: begin
        urnd_advance_o        = 1'b1;
        addr_cnt_inc          = (addr_cnt_q != 6'b011111);
        allow_secure_wipe     = 1'b1;
        expect_secure_wipe    = 1'b1;
        secure_wipe_running_d = 1'b1;
        sec_wipe_mac_urnd_o   = (addr_cnt_q == 6'b000000);
        sec_wipe_mod_urnd_o   = (addr_cnt_q == 6'b000001);
        sec_wipe_base_o       = (addr_cnt_q > 6'b000001);
        sec_wipe_base_urnd_o  = (addr_cnt_q > 6'b000001);
        if (addr_cnt_q == 6'b011111) begin
          state_d = OtbnStartStopSecureWipeExtIsprsUrnd;
        end
      end
      OtbnStartStopSecureWipeExtIsprsUrnd: begin
        urnd_advance_o               = 1'b1;
        addr_cnt_inc                 = (addr_cnt_q != 6'b011111);
        allow_secure_wipe            = 1'b1;
        expect_secure_wipe           = 1'b1;
        secure_wipe_running_d        = 1'b1;
        sec_wipe_kmac_data_s0_urnd_o = (addr_cnt_q == 6'b000000);
        sec_wipe_kmac_data_s1_urnd_o = (addr_cnt_q == 6'b000001);
        sec_wipe_mai_res_s0_urnd_o   = (addr_cnt_q == 6'b000010);
        sec_wipe_mai_res_s1_urnd_o   = (addr_cnt_q == 6'b000011);
        sec_wipe_mai_in0_s0_urnd_o   = (addr_cnt_q == 6'b000100);
        sec_wipe_mai_in0_s1_urnd_o   = (addr_cnt_q == 6'b000101);
        sec_wipe_mai_in1_s0_urnd_o   = (addr_cnt_q == 6'b000110);
        sec_wipe_mai_in1_s1_urnd_o   = (addr_cnt_q == 6'b000111);
        if (addr_cnt_q == 6'b011111) begin
          state_d = OtbnStartStopSecureWipeAllZero;
        end
      end
      OtbnStartStopSecureWipeAllZero: begin
        sec_wipe_zero_o    = 1'b1;
        allow_secure_wipe  = 1'b1;
        expect_secure_wipe = 1'b1;

        if (first_wipe_round) begin
          state_d                   = OtbnStartStopStateUrndRefresh;
          secure_wipe_running_d     = 1'b1;
          wipe_after_urnd_refresh_d = MuBi4True;
        end else begin
          state_d               = OtbnStartStopSecureWipeComplete;
          secure_wipe_running_d = 1'b0;
          secure_wipe_ack_o     = 1'b1;
        end
      end
      OtbnStartStopSecureWipeComplete: begin
        urnd_advance_o            = 1'b1;
        rma_ack_d                 = rma_req_i;
        state_d                   = should_lock_d ? OtbnStartStopStateLocked : OtbnStartStopStateHalt;
        wipe_after_urnd_refresh_d = MuBi4False;
      end
      OtbnStartStopStateLocked: begin
      end
      default: begin
        state_error_d = 1'b1;
        rma_ack_d     = MuBi4False;
        state_d       = OtbnStartStopStateLocked;
      end
    endcase

    if (urnd_reseed_ack_i &&
        !(state_q inside {OtbnStartStopStateInitial, OtbnStartStopStateUrndRefresh})) begin
      spurious_urnd_ack_error = 1'b1;
      state_d                 = OtbnStartStopStateLocked;
    end

    if (mubi4_test_invalid(escalate_en_i)) begin
      mubi_err_d = 1'b1;
      state_d    = OtbnStartStopStateLocked;
    end
    if (mubi4_test_invalid(wipe_after_urnd_refresh_q)) begin
      wipe_after_urnd_refresh_d = MuBi4False;
      mubi_err_d                = 1'b1;
      state_d                   = OtbnStartStopStateLocked;
    end
    if (mubi4_test_invalid(rma_ack_q)) begin
      rma_ack_d  = MuBi4False;
      mubi_err_d = 1'b1;
      state_d    = OtbnStartStopStateLocked;
    end
  end

  assign init_sec_wipe_done_d = (state_q == OtbnStartStopSecureWipeComplete) | init_sec_wipe_done_q;

  assign controller_start_o =
    ((state_q == OtbnStartStopStateUrndRefresh) & (urnd_reseed_ack_i | skip_reseed_q) &
      first_wipe_round);

  assign done_o = ((state_q == OtbnStartStopSecureWipeComplete && init_sec_wipe_done_q) ||
                   (stop && (state_q == OtbnStartStopStateUrndRefresh) && first_wipe_round) ||
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

  assign sec_wipe_addr_o = addr_cnt_q[4:0];
  `ASSERT(NoSecWipeAbove32Bit_A, addr_cnt_q[5] |-> (!sec_wipe_wdr_o && !sec_wipe_mac_urnd_o))

  assign spurious_secure_wipe_req = secure_wipe_req_i & ~allow_secure_wipe;
  assign dropped_secure_wipe_req  = expect_secure_wipe & init_sec_wipe_done_d & ~secure_wipe_req_i;
  assign secure_wipe_error_d      = spurious_secure_wipe_req | dropped_secure_wipe_req;

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

  assign urnd_reseed_err_d = spurious_urnd_ack_error | urnd_reseed_err_q;
  assign urnd_reseed_err_o = urnd_reseed_err_d;

  assign urnd_must_advance_o = !urnd_control_allowed && urnd_advance_o;

  assign fatal_error_o = urnd_reseed_err_o | state_error_d | secure_wipe_error_q | mubi_err_q;

  assign rma_ack_o             = rma_ack_q;
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
