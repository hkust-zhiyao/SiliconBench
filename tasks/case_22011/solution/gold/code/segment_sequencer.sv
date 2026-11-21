// Copyright 2024 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// Author: Matteo Perotti <mperotti@iis.ee.ethz.ch>
// Description: Decompose RVV 1.0 unit-stride and strided segment memory
// operations into ordered per-(element, field) VLSU micro-operations.

module segment_sequencer import ara_pkg::*; import rvv_pkg::*; #(
    parameter bit  SegSupport = 1'b0,
    parameter type ara_req_t  = logic,
    parameter type ara_resp_t = logic
  ) (
    // Clock and reset
    input  logic      clk_i,
    input  logic      rst_ni,
    input  logic      ara_idle_i,
    // Enable the segment sequencer?
    input  logic      is_segment_mem_op_i,
    input  logic      illegal_insn_i,
    input  logic      is_vload_i,
    output logic      seg_mem_op_end_o,
    input  logic      load_complete_i,
    output logic      load_complete_o,
    input  logic      store_complete_i,
    output logic      store_complete_o,
    // Ara frontend - backend info and handshakes
    input  ara_req_t  ara_req_i,
    output ara_req_t  ara_req_o,
    input  logic      ara_req_valid_i,
    output logic      ara_req_valid_o,
    input  logic      ara_req_ready_i,
    input  ara_resp_t ara_resp_i,
    output ara_resp_t ara_resp_o,
    input  logic      ara_resp_valid_i,
    output logic      ara_resp_valid_o
  );

  if (SegSupport == SegSupportEnable) begin : gen_segment_support

    localparam int unsigned VStartW = $bits(ara_req_i.vstart);

    typedef enum logic [2:0] {
      IDLE,
      STREAM_UOPS,
      WAIT_LAST_RESP,
      DRAIN_WAIT_IDLE,
      COMMIT_RESP
    } state_e;

    state_e              state_d, state_q;
    ara_req_t            req_d, req_q;
    ara_resp_t           ara_resp_d, ara_resp_q;
    logic                is_vload_d, is_vload_q;
    logic [2:0]          field_d, field_q;
    logic [VStartW-1:0]  elem_d, elem_q;
    logic [VStartW-1:0]  inflight_elem_d, inflight_elem_q;

    function automatic ara_req_t build_uop(
      input ara_req_t           base_req,
      input logic               is_load_op,
      input logic [VStartW-1:0] elem_idx,
      input logic [2:0]         field_idx,
      input logic               live_token
    );
      ara_req_t   uop;
      logic [4:0] reg_step;
      logic [1:0] mem_eew;

      uop      = base_req;
      mem_eew  = base_req.vtype.vsew[1:0];
      reg_step = base_req.emul[2] ? {2'b00, field_idx} : ({2'b00, field_idx} << base_req.emul[1:0]);

      uop.vl               = elem_idx + {{(VStartW-1){1'b0}}, 1'b1};
      uop.vstart           = elem_idx;
      uop.vd               = base_req.vd  + reg_step;
      uop.vs1              = base_req.vs1 + reg_step;
      uop.nf               = 3'd0;
      uop.fault_only_first = 1'b0;
      uop.scalar_op        = base_req.scalar_op + (elen_t'(field_idx) << mem_eew);
      uop.token            = live_token;

      if (base_req.op == VLE || base_req.op == VSE) begin
        uop.op     = is_load_op ? VLSE : VSSE;
        uop.stride = (elen_t'(base_req.nf) + elen_t'(1)) << mem_eew;
      end

      return uop;
    endfunction

    function automatic ara_resp_t format_uop_resp(
      input ara_resp_t          raw_resp,
      input logic               is_fof,
      input logic [VStartW-1:0] fault_elem
    );
      ara_resp_t res;
      res = raw_resp;
      if (raw_resp.exception.valid) begin
        res.exception_vstart = fault_elem;
        if (is_fof && (raw_resp.exception.cause != riscv::ILLEGAL_INSTR) && (fault_elem != '0)) begin
          res.fof_exception = 1'b1;
        end else begin
          res.fof_exception = 1'b0;
        end
      end
      return res;
    endfunction

    always_comb begin
      state_d          = state_q;
      req_d            = req_q;
      ara_resp_d       = ara_resp_q;
      is_vload_d       = is_vload_q;
      field_d          = field_q;
      elem_d           = elem_q;
      inflight_elem_d  = inflight_elem_q;

      // Default pass-through for non-segment operations
      ara_req_o        = ara_req_i;
      ara_req_valid_o  = ara_req_valid_i;
      ara_resp_o       = ara_resp_i;
      ara_resp_valid_o = ara_resp_valid_i;
      load_complete_o  = 1'b0;
      store_complete_o = 1'b0;
      seg_mem_op_end_o = 1'b0;

      unique case (state_q)
        IDLE: begin
          load_complete_o  = is_segment_mem_op_i ? 1'b0 : load_complete_i;
          store_complete_o = is_segment_mem_op_i ? 1'b0 : store_complete_i;
          ara_resp_valid_o = is_segment_mem_op_i ? 1'b0 : ara_resp_valid_i;

          if (is_segment_mem_op_i && ara_req_valid_i && !illegal_insn_i) begin
            ara_req_o        = build_uop(ara_req_i, is_vload_i, ara_req_i.vstart, 3'd0, ara_req_i.token);
            ara_req_valid_o  = 1'b1;

            if (ara_req_ready_i) begin
              req_d           = ara_req_i;
              is_vload_d      = is_vload_i;
              ara_resp_d      = '0;
              inflight_elem_d = ara_req_i.vstart;
              elem_d          = ara_req_i.vstart;
              // Segment instructions always have nf >= 1, so field 1 of vstart is next
              field_d         = 3'd1;
              state_d         = STREAM_UOPS;
            end
          end
        end

        STREAM_UOPS: begin
          ara_req_o        = build_uop(req_q, is_vload_q, elem_q, field_q, ara_req_i.token);
          ara_req_valid_o  = 1'b1;
          ara_resp_valid_o = 1'b0;

          if (ara_resp_valid_i && (ara_resp_i.exception.valid || ara_resp_i.fof_exception)) begin
            // Fault on the in-flight micro-op: cancel staging any further micro-ops
            ara_req_valid_o = 1'b0;
            ara_resp_d      = format_uop_resp(ara_resp_i, req_q.fault_only_first, inflight_elem_q);
            state_d         = DRAIN_WAIT_IDLE;
          end else if (ara_req_ready_i) begin
            // Current micro-op (elem_q, field_q) is being latched into ara_req_o FF
            inflight_elem_d = elem_q;
            if ((field_q == req_q.nf) && ((elem_q + {{(VStartW-1){1'b0}}, 1'b1}) == req_q.vl)) begin
              state_d = WAIT_LAST_RESP;
            end else if (field_q == req_q.nf) begin
              field_d = 3'd0;
              elem_d  = elem_q + {{(VStartW-1){1'b0}}, 1'b1};
            end else begin
              field_d = field_q + 3'd1;
            end
          end
        end

        WAIT_LAST_RESP: begin
          ara_req_valid_o  = 1'b0;
          ara_resp_valid_o = 1'b0;

          if (ara_resp_valid_i) begin
            ara_resp_d = format_uop_resp(ara_resp_i, req_q.fault_only_first, inflight_elem_q);
            state_d    = DRAIN_WAIT_IDLE;
          end
        end

        DRAIN_WAIT_IDLE: begin
          ara_req_valid_o  = 1'b0;
          ara_resp_valid_o = 1'b0;

          if (ara_idle_i && ara_req_ready_i) begin
            state_d = COMMIT_RESP;
          end
        end

        COMMIT_RESP: begin
          ara_req_valid_o  = 1'b0;
          ara_resp_o       = ara_resp_q;
          ara_resp_valid_o = 1'b1;
          seg_mem_op_end_o = 1'b1;

          if (is_segment_mem_op_i) begin
            load_complete_o  = is_vload_q;
            store_complete_o = ~is_vload_q;
            state_d          = IDLE;
          end
        end

        default: begin
          state_d = IDLE;
        end
      endcase
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q         <= IDLE;
        req_q           <= '0;
        ara_resp_q      <= '0;
        is_vload_q      <= 1'b0;
        field_q         <= '0;
        elem_q          <= '0;
        inflight_elem_q <= '0;
      end else begin
        state_q         <= state_d;
        req_q           <= req_d;
        ara_resp_q      <= ara_resp_d;
        is_vload_q      <= is_vload_d;
        field_q         <= field_d;
        elem_q          <= elem_d;
        inflight_elem_q <= inflight_elem_d;
      end
    end

  end else begin : gen_no_segment_support
    assign seg_mem_op_end_o = 1'b0;
    assign load_complete_o  = load_complete_i;
    assign store_complete_o = store_complete_i;
    assign ara_req_o        = ara_req_i;
    assign ara_req_valid_o  = ara_req_valid_i;
    assign ara_resp_o       = ara_resp_i;
    assign ara_resp_valid_o = ara_resp_valid_i;
  end

endmodule
