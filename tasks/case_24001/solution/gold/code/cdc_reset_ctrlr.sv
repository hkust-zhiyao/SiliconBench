//-----------------------------------------------------------------------------
// Title : CDC Clear Signaling Synchronization
// -----------------------------------------------------------------------------
// Copyright (C) 2021 ETH Zurich, University of Bologna
// SPDX-License-Identifier: SHL-0.51
// -----------------------------------------------------------------------------

module cdc_reset_ctrlr
  import cdc_reset_ctrlr_pkg::*;
 #(
  parameter int unsigned SYNC_STAGES = 2,
  parameter logic        CLEAR_ON_ASYNC_RESET = 1'b1
)(
  // Side A (both sides are symmetric)
  input  logic a_clk_i,
  input  logic a_rst_ni,
  input  logic a_clear_i,
  output logic a_clear_o,
  input  logic a_clear_ack_i,
  output logic a_isolate_o,
  input  logic a_isolate_ack_i,
  // Side B (both sides are symmetric)
  input  logic b_clk_i,
  input  logic b_rst_ni,
  input  logic b_clear_i,
  output logic b_clear_o,
  input  logic b_clear_ack_i,
  output logic b_isolate_o,
  input  logic b_isolate_ack_i
);

  (* dont_touch = "true" *)
  logic             async_a2b_req, async_b2a_ack;
  (* dont_touch = "true" *)
  clear_seq_phase_e async_a2b_next_phase;
  (* dont_touch = "true" *)
  logic             async_b2a_req, async_a2b_ack;
  (* dont_touch = "true" *)
  clear_seq_phase_e async_b2a_next_phase;

  cdc_reset_ctrlr_half #(
    .SYNC_STAGES          ( SYNC_STAGES          ),
    .CLEAR_ON_ASYNC_RESET ( CLEAR_ON_ASYNC_RESET )
  ) i_cdc_reset_ctrlr_half_a (
    .clk_i              ( a_clk_i              ),
    .rst_ni             ( a_rst_ni             ),
    .clear_i            ( a_clear_i            ),
    .clear_o            ( a_clear_o            ),
    .clear_ack_i        ( a_clear_ack_i        ),
    .isolate_o          ( a_isolate_o          ),
    .isolate_ack_i      ( a_isolate_ack_i      ),
    (* async *) .async_next_phase_o ( async_a2b_next_phase ),
    (* async *) .async_req_o        ( async_a2b_req        ),
    (* async *) .async_ack_i        ( async_b2a_ack        ),
    (* async *) .async_next_phase_i ( async_b2a_next_phase ),
    (* async *) .async_req_i        ( async_b2a_req        ),
    (* async *) .async_ack_o        ( async_a2b_ack        )
  );

  cdc_reset_ctrlr_half #(
    .SYNC_STAGES          ( SYNC_STAGES          ),
    .CLEAR_ON_ASYNC_RESET ( CLEAR_ON_ASYNC_RESET )
  ) i_cdc_reset_ctrlr_half_b (
    .clk_i              ( b_clk_i              ),
    .rst_ni             ( b_rst_ni             ),
    .clear_i            ( b_clear_i            ),
    .clear_o            ( b_clear_o            ),
    .clear_ack_i        ( b_clear_ack_i        ),
    .isolate_o          ( b_isolate_o          ),
    .isolate_ack_i      ( b_isolate_ack_i      ),
    (* async *) .async_next_phase_o ( async_b2a_next_phase ),
    (* async *) .async_req_o        ( async_b2a_req        ),
    (* async *) .async_ack_i        ( async_a2b_ack        ),
    (* async *) .async_next_phase_i ( async_a2b_next_phase ),
    (* async *) .async_req_i        ( async_a2b_req        ),
    (* async *) .async_ack_o        ( async_b2a_ack        )
  );
endmodule


module cdc_reset_ctrlr_half
  import cdc_reset_ctrlr_pkg::*;
#(
  parameter int unsigned SYNC_STAGES = 2,
  parameter logic        CLEAR_ON_ASYNC_RESET = 1'b1
)(
  // Synchronous side
  input  logic             clk_i,
  input  logic             rst_ni,
  input  logic             clear_i,
  output logic             isolate_o,
  input  logic             isolate_ack_i,
  output logic             clear_o,
  input  logic             clear_ack_i,
  // Asynchronous clear sequence handshaking
  output clear_seq_phase_e async_next_phase_o,
  output logic             async_req_o,
  input  logic             async_ack_i,
  input  clear_seq_phase_e async_next_phase_i,
  input  logic             async_req_i,
  output logic             async_ack_o
);

  typedef enum logic [3:0] {
    IDLE,
    RESET_ISOLATE,
    ISOLATE,
    WAIT_ISOLATE_PHASE_ACK,
    WAIT_ISOLATE_ACK,
    CLEAR,
    WAIT_CLEAR_PHASE_ACK,
    WAIT_CLEAR_ACK,
    POST_CLEAR,
    FINISHED
  } initiator_state_e;

  initiator_state_e initiator_state_d, initiator_state_q;

  clear_seq_phase_e initiator_clear_seq_phase;
  logic             initiator_phase_transition_req;
  logic             initiator_phase_transition_ack;
  logic             initiator_isolate_out;
  logic             initiator_clear_out;

  logic iso_ack_seen_q;
  logic clr_ack_seen_q;
  logic pending_clear_q;
  logic eff_iso_ack;
  logic eff_clr_ack;

  assign eff_iso_ack = isolate_o && (isolate_ack_i || iso_ack_seen_q);
  assign eff_clr_ack = clear_o   && (clear_ack_i   || clr_ack_seen_q);

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      iso_ack_seen_q <= 1'b0;
      clr_ack_seen_q <= 1'b0;
    end else begin
      if (!isolate_o) begin
        iso_ack_seen_q <= 1'b0;
      end else if (isolate_ack_i) begin
        iso_ack_seen_q <= 1'b1;
      end

      if (!clear_o) begin
        clr_ack_seen_q <= 1'b0;
      end else if (clear_ack_i) begin
        clr_ack_seen_q <= 1'b1;
      end
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      pending_clear_q <= 1'b0;
    end else begin
      if (initiator_state_q == CLEAR ||
          (initiator_state_q == IDLE && (clear_i || pending_clear_q))) begin
        pending_clear_q <= 1'b0;
      end else if (clear_i &&
                   (initiator_state_q == POST_CLEAR || initiator_state_q == FINISHED)) begin
        pending_clear_q <= 1'b1;
      end
    end
  end

  always_comb begin
    initiator_state_d              = initiator_state_q;
    initiator_phase_transition_req = 1'b0;
    initiator_isolate_out          = 1'b0;
    initiator_clear_out            = 1'b0;
    initiator_clear_seq_phase      = CLEAR_PHASE_IDLE;

    case (initiator_state_q)
      IDLE: begin
        if (clear_i || pending_clear_q) begin
          initiator_state_d = ISOLATE;
        end
      end

      // Drain any pre-reset in-flight or stale 4-phase ACK while asserting
      // RESET_MSG (CLEAR_PHASE_ISOLATE), then run a clean full ISOLATE phase
      // so the peer is guaranteed isolated and acknowledged before CLEAR.
      RESET_ISOLATE: begin
        initiator_phase_transition_req = 1'b1;
        initiator_clear_seq_phase      = CLEAR_PHASE_ISOLATE;
        initiator_isolate_out          = 1'b1;
        initiator_clear_out            = 1'b0;
        if (initiator_phase_transition_ack) begin
          initiator_state_d = ISOLATE;
        end
      end

      ISOLATE: begin
        initiator_phase_transition_req = 1'b1;
        initiator_clear_seq_phase      = CLEAR_PHASE_ISOLATE;
        initiator_isolate_out          = 1'b1;
        initiator_clear_out            = 1'b0;
        if (initiator_phase_transition_ack && eff_iso_ack) begin
          initiator_state_d = CLEAR;
        end else if (initiator_phase_transition_ack) begin
          initiator_state_d = WAIT_ISOLATE_ACK;
        end else if (eff_iso_ack) begin
          initiator_state_d = WAIT_ISOLATE_PHASE_ACK;
        end
      end

      WAIT_ISOLATE_ACK: begin
        initiator_isolate_out     = 1'b1;
        initiator_clear_out       = 1'b0;
        initiator_clear_seq_phase = CLEAR_PHASE_ISOLATE;
        if (eff_iso_ack) begin
          initiator_state_d = CLEAR;
        end
      end

      WAIT_ISOLATE_PHASE_ACK: begin
        initiator_phase_transition_req = 1'b1;
        initiator_clear_seq_phase      = CLEAR_PHASE_ISOLATE;
        initiator_isolate_out          = 1'b1;
        initiator_clear_out            = 1'b0;
        if (initiator_phase_transition_ack) begin
          initiator_state_d = CLEAR;
        end
      end

      CLEAR: begin
        initiator_isolate_out          = 1'b1;
        initiator_clear_out            = 1'b1;
        initiator_phase_transition_req = 1'b1;
        initiator_clear_seq_phase      = CLEAR_PHASE_CLEAR;
        if (initiator_phase_transition_ack && eff_clr_ack) begin
          initiator_state_d = POST_CLEAR;
        end else if (initiator_phase_transition_ack) begin
          initiator_state_d = WAIT_CLEAR_ACK;
        end else if (eff_clr_ack) begin
          initiator_state_d = WAIT_CLEAR_PHASE_ACK;
        end
      end

      WAIT_CLEAR_ACK: begin
        initiator_isolate_out     = 1'b1;
        initiator_clear_out       = 1'b1;
        initiator_clear_seq_phase = CLEAR_PHASE_CLEAR;
        if (eff_clr_ack) begin
          initiator_state_d = POST_CLEAR;
        end
      end

      WAIT_CLEAR_PHASE_ACK: begin
        initiator_phase_transition_req = 1'b1;
        initiator_clear_seq_phase      = CLEAR_PHASE_CLEAR;
        initiator_isolate_out          = 1'b1;
        initiator_clear_out            = 1'b1;
        if (initiator_phase_transition_ack) begin
          initiator_state_d = POST_CLEAR;
        end
      end

      POST_CLEAR: begin
        initiator_isolate_out          = 1'b1;
        initiator_clear_out            = 1'b0;
        initiator_phase_transition_req = 1'b1;
        initiator_clear_seq_phase      = CLEAR_PHASE_POST_CLEAR;
        if (initiator_phase_transition_ack) begin
          initiator_state_d = FINISHED;
        end
      end

      FINISHED: begin
        initiator_isolate_out          = 1'b1;
        initiator_clear_out            = 1'b0;
        initiator_phase_transition_req = 1'b1;
        initiator_clear_seq_phase      = CLEAR_PHASE_IDLE;
        if (initiator_phase_transition_ack) begin
          initiator_state_d = IDLE;
        end
      end

      default: begin
        initiator_state_d = ISOLATE;
      end
    endcase
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      if (CLEAR_ON_ASYNC_RESET) begin
        initiator_state_q <= RESET_ISOLATE;
      end else begin
        initiator_state_q <= IDLE;
      end
    end else begin
      initiator_state_q <= initiator_state_d;
    end
  end

  cdc_4phase_src #(
    .T              ( clear_seq_phase_e    ),
    .SYNC_STAGES    ( SYNC_STAGES          ),
    .DECOUPLED      ( 1'b0                 ),
    .SEND_RESET_MSG ( CLEAR_ON_ASYNC_RESET ),
    .RESET_MSG      ( CLEAR_PHASE_ISOLATE  )
  ) i_state_transition_cdc_src (
    .clk_i,
    .rst_ni,
    .data_i       ( initiator_clear_seq_phase      ),
    .valid_i      ( initiator_phase_transition_req ),
    .ready_o      ( initiator_phase_transition_ack ),
    .async_req_o,
    .async_ack_i,
    .async_data_o ( async_next_phase_o             )
  );

  //---------------------- Receiver Side ----------------------
  clear_seq_phase_e receiver_phase_q;
  clear_seq_phase_e receiver_next_phase;
  logic             receiver_phase_req, receiver_phase_ack;
  logic             receiver_isolate_out;
  logic             receiver_clear_out;

  cdc_4phase_dst #(
    .T           ( clear_seq_phase_e ),
    .SYNC_STAGES ( SYNC_STAGES       ),
    .DECOUPLED   ( 1'b0              )
  ) i_state_transition_cdc_dst (
    .clk_i,
    .rst_ni,
    .data_o       ( receiver_next_phase ),
    .valid_o      ( receiver_phase_req  ),
    .ready_i      ( receiver_phase_ack  ),
    .async_req_i,
    .async_ack_o,
    .async_data_i ( async_next_phase_i  )
  );

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      receiver_phase_q <= CLEAR_PHASE_IDLE;
    end else if (receiver_phase_req && receiver_phase_ack) begin
      receiver_phase_q <= receiver_next_phase;
    end
  end

  always_comb begin
    receiver_isolate_out = 1'b0;
    receiver_clear_out   = 1'b0;
    receiver_phase_ack   = 1'b0;

    if (receiver_phase_req) begin
      case (receiver_next_phase)
        CLEAR_PHASE_IDLE: begin
          receiver_clear_out   = 1'b0;
          receiver_isolate_out = 1'b0;
          receiver_phase_ack   = 1'b1;
        end

        CLEAR_PHASE_ISOLATE: begin
          receiver_clear_out   = 1'b0;
          receiver_isolate_out = 1'b1;
          receiver_phase_ack   = eff_iso_ack;
        end

        CLEAR_PHASE_CLEAR: begin
          receiver_isolate_out = 1'b1;
          if (iso_ack_seen_q) begin
            receiver_clear_out = 1'b1;
            receiver_phase_ack = eff_clr_ack;
          end else begin
            receiver_clear_out = 1'b0;
            receiver_phase_ack = 1'b0;
          end
        end

        CLEAR_PHASE_POST_CLEAR: begin
          receiver_clear_out   = 1'b0;
          receiver_isolate_out = 1'b1;
          receiver_phase_ack   = 1'b1;
        end

        default: begin
          receiver_clear_out   = 1'b0;
          receiver_isolate_out = 1'b0;
          receiver_phase_ack   = 1'b0;
        end
      endcase
    end else begin
      case (receiver_phase_q)
        CLEAR_PHASE_IDLE: begin
          receiver_clear_out   = 1'b0;
          receiver_isolate_out = 1'b0;
        end

        CLEAR_PHASE_ISOLATE: begin
          receiver_clear_out   = 1'b0;
          receiver_isolate_out = 1'b1;
        end

        CLEAR_PHASE_CLEAR: begin
          receiver_isolate_out = 1'b1;
          receiver_clear_out   = iso_ack_seen_q;
        end

        CLEAR_PHASE_POST_CLEAR: begin
          receiver_clear_out   = 1'b0;
          receiver_isolate_out = 1'b1;
        end

        default: begin
          receiver_clear_out   = 1'b0;
          receiver_isolate_out = 1'b0;
        end
      endcase
    end
  end

  assign clear_o   = initiator_clear_out   || receiver_clear_out;
  assign isolate_o = initiator_isolate_out || receiver_isolate_out;

endmodule : cdc_reset_ctrlr_half
