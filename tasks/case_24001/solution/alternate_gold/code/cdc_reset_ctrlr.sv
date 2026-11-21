//-----------------------------------------------------------------------------
// Title : CDC Clear Signaling Synchronization (Alternate Reference)
// Copyright (C) 2021 ETH Zurich, University of Bologna
// SPDX-License-Identifier: SHL-0.51
//-----------------------------------------------------------------------------

module cdc_reset_ctrlr
  import cdc_reset_ctrlr_pkg::*;
 #(
  parameter int unsigned SYNC_STAGES = 2,
  parameter logic        CLEAR_ON_ASYNC_RESET = 1'b1
)(
  input  logic a_clk_i,
  input  logic a_rst_ni,
  input  logic a_clear_i,
  output logic a_clear_o,
  input  logic a_clear_ack_i,
  output logic a_isolate_o,
  input  logic a_isolate_ack_i,
  input  logic b_clk_i,
  input  logic b_rst_ni,
  input  logic b_clear_i,
  output logic b_clear_o,
  input  logic b_clear_ack_i,
  output logic b_isolate_o,
  input  logic b_isolate_ack_i
);

  (* dont_touch = "true" *) logic             async_a2b_req, async_b2a_ack;
  (* dont_touch = "true" *) clear_seq_phase_e async_a2b_next_phase;
  (* dont_touch = "true" *) logic             async_b2a_req, async_a2b_ack;
  (* dont_touch = "true" *) clear_seq_phase_e async_b2a_next_phase;

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
    .async_next_phase_o ( async_a2b_next_phase ),
    .async_req_o        ( async_a2b_req        ),
    .async_ack_i        ( async_b2a_ack        ),
    .async_next_phase_i ( async_b2a_next_phase ),
    .async_req_i        ( async_b2a_req        ),
    .async_ack_o        ( async_a2b_ack        )
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
    .async_next_phase_o ( async_b2a_next_phase ),
    .async_req_o        ( async_b2a_req        ),
    .async_ack_i        ( async_a2b_ack        ),
    .async_next_phase_i ( async_a2b_next_phase ),
    .async_req_i        ( async_a2b_req        ),
    .async_ack_o        ( async_b2a_ack        )
  );
endmodule


module cdc_reset_ctrlr_half
  import cdc_reset_ctrlr_pkg::*;
#(
  parameter int unsigned SYNC_STAGES = 2,
  parameter logic        CLEAR_ON_ASYNC_RESET = 1'b1
)(
  input  logic             clk_i,
  input  logic             rst_ni,
  input  logic             clear_i,
  output logic             isolate_o,
  input  logic             isolate_ack_i,
  output logic             clear_o,
  input  logic             clear_ack_i,
  output clear_seq_phase_e async_next_phase_o,
  output logic             async_req_o,
  input  logic             async_ack_i,
  input  clear_seq_phase_e async_next_phase_i,
  input  logic             async_req_i,
  output logic             async_ack_o
);

  typedef enum logic [3:0] {
    IDLE,
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
  logic             rst_resync_q, rst_resync_d;
  logic             queued_clear_q, queued_clear_d;
  logic             iso_latched_q, clr_latched_q;

  clear_seq_phase_e initiator_clear_seq_phase;
  logic             initiator_phase_transition_req;
  logic             initiator_phase_transition_ack;
  logic             initiator_isolate_out;
  logic             initiator_clear_out;

  wire local_iso_done = isolate_o && (isolate_ack_i || iso_latched_q);
  wire local_clr_done = clear_o   && (clear_ack_i   || clr_latched_q);

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      iso_latched_q <= 1'b0;
      clr_latched_q <= 1'b0;
    end else begin
      iso_latched_q <= isolate_o ? (iso_latched_q | isolate_ack_i) : 1'b0;
      clr_latched_q <= clear_o   ? (clr_latched_q | clear_ack_i)   : 1'b0;
    end
  end

  always_comb begin
    initiator_state_d              = initiator_state_q;
    rst_resync_d                   = rst_resync_q;
    queued_clear_d                 = queued_clear_q;
    initiator_phase_transition_req = 1'b0;
    initiator_isolate_out          = 1'b0;
    initiator_clear_out            = 1'b0;
    initiator_clear_seq_phase      = CLEAR_PHASE_IDLE;

    if (clear_i && (initiator_state_q == POST_CLEAR || initiator_state_q == FINISHED)) begin
      queued_clear_d = 1'b1;
    end

    case (initiator_state_q)
      IDLE: begin
        if (clear_i || queued_clear_q) begin
          initiator_state_d = ISOLATE;
          queued_clear_d    = 1'b0;
        end
      end

      ISOLATE: begin
        initiator_phase_transition_req = 1'b1;
        initiator_clear_seq_phase      = CLEAR_PHASE_ISOLATE;
        initiator_isolate_out          = 1'b1;
        if (rst_resync_q) begin
          if (initiator_phase_transition_ack) begin
            rst_resync_d = 1'b0;
          end
        end else begin
          if (initiator_phase_transition_ack && local_iso_done) begin
            initiator_state_d = CLEAR;
          end else if (initiator_phase_transition_ack) begin
            initiator_state_d = WAIT_ISOLATE_ACK;
          end else if (local_iso_done) begin
            initiator_state_d = WAIT_ISOLATE_PHASE_ACK;
          end
        end
      end

      WAIT_ISOLATE_ACK: begin
        initiator_isolate_out     = 1'b1;
        initiator_clear_seq_phase = CLEAR_PHASE_ISOLATE;
        if (local_iso_done) begin
          initiator_state_d = CLEAR;
        end
      end

      WAIT_ISOLATE_PHASE_ACK: begin
        initiator_phase_transition_req = 1'b1;
        initiator_clear_seq_phase      = CLEAR_PHASE_ISOLATE;
        initiator_isolate_out          = 1'b1;
        if (initiator_phase_transition_ack) begin
          initiator_state_d = CLEAR;
        end
      end

      CLEAR: begin
        queued_clear_d                 = 1'b0;
        initiator_isolate_out          = 1'b1;
        initiator_clear_out            = 1'b1;
        initiator_phase_transition_req = 1'b1;
        initiator_clear_seq_phase      = CLEAR_PHASE_CLEAR;
        if (initiator_phase_transition_ack && local_clr_done) begin
          initiator_state_d = POST_CLEAR;
        end else if (initiator_phase_transition_ack) begin
          initiator_state_d = WAIT_CLEAR_ACK;
        end else if (local_clr_done) begin
          initiator_state_d = WAIT_CLEAR_PHASE_ACK;
        end
      end

      WAIT_CLEAR_ACK: begin
        initiator_isolate_out     = 1'b1;
        initiator_clear_out       = 1'b1;
        initiator_clear_seq_phase = CLEAR_PHASE_CLEAR;
        if (local_clr_done) begin
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
        initiator_phase_transition_req = 1'b1;
        initiator_clear_seq_phase      = CLEAR_PHASE_POST_CLEAR;
        if (initiator_phase_transition_ack) begin
          initiator_state_d = FINISHED;
        end
      end

      FINISHED: begin
        initiator_isolate_out          = 1'b1;
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
      initiator_state_q <= CLEAR_ON_ASYNC_RESET ? ISOLATE : IDLE;
      rst_resync_q      <= CLEAR_ON_ASYNC_RESET;
      queued_clear_q    <= 1'b0;
    end else begin
      initiator_state_q <= initiator_state_d;
      rst_resync_q      <= rst_resync_d;
      queued_clear_q    <= queued_clear_d;
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

  clear_seq_phase_e rx_hold_phase_q;
  clear_seq_phase_e receiver_next_phase;
  logic             receiver_phase_req, receiver_phase_ack;
  logic             receiver_isolate_out, receiver_clear_out;

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
      rx_hold_phase_q <= CLEAR_PHASE_IDLE;
    end else if (receiver_phase_req && receiver_phase_ack) begin
      rx_hold_phase_q <= receiver_next_phase;
    end
  end

  clear_seq_phase_e active_rx_phase;
  assign active_rx_phase = receiver_phase_req ? receiver_next_phase : rx_hold_phase_q;

  always_comb begin
    receiver_isolate_out = (active_rx_phase != CLEAR_PHASE_IDLE);
    receiver_clear_out   = (active_rx_phase == CLEAR_PHASE_CLEAR) && iso_latched_q;
    receiver_phase_ack   = 1'b0;
    if (receiver_phase_req) begin
      unique case (receiver_next_phase)
        CLEAR_PHASE_IDLE:       receiver_phase_ack = 1'b1;
        CLEAR_PHASE_ISOLATE:    receiver_phase_ack = local_iso_done;
        CLEAR_PHASE_CLEAR:      receiver_phase_ack = iso_latched_q && local_clr_done;
        CLEAR_PHASE_POST_CLEAR: receiver_phase_ack = 1'b1;
        default:                receiver_phase_ack = 1'b0;
      endcase
    end
  end

  assign clear_o   = initiator_clear_out   || receiver_clear_out;
  assign isolate_o = initiator_isolate_out || receiver_isolate_out;

endmodule : cdc_reset_ctrlr_half
