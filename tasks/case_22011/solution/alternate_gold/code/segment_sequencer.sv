// Copyright 2024 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// Alternate Architecture: Lockstep 1-in-flight micro-op engine with incremental
// base/field address and register accumulators plus common_cells counter.

module segment_sequencer import ara_pkg::*; import rvv_pkg::*; #(
    parameter bit  SegSupport = 1'b0,
    parameter type ara_req_t  = logic,
    parameter type ara_resp_t = logic
  ) (
    input  logic      clk_i,
    input  logic      rst_ni,
    input  logic      ara_idle_i,
    input  logic      is_segment_mem_op_i,
    input  logic      illegal_insn_i,
    input  logic      is_vload_i,
    output logic      seg_mem_op_end_o,
    input  logic      load_complete_i,
    output logic      load_complete_o,
    input  logic      store_complete_i,
    output logic      store_complete_o,
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
      S_PASS,
      S_STAGE_UOP,
      S_WAIT_UOP_ACK,
      S_WAIT_BACKEND_IDLE,
      S_SEND_FINAL_RESP
    } seq_state_e;

    seq_state_e         state_d, state_q;
    ara_req_t           saved_req_d, saved_req_q;
    ara_resp_t          final_resp_d, final_resp_q;
    logic               is_load_d, is_load_q;
    elen_t              elem_step_d, elem_step_q;
    elen_t              elem_base_addr_d, elem_base_addr_q;
    elen_t              cur_field_addr_d, cur_field_addr_q;
    logic [4:0]         cur_vd_d, cur_vd_q;
    logic [4:0]         cur_vs1_d, cur_vs1_q;
    logic [VStartW-1:0] cur_elem_d, cur_elem_q;

    logic               field_cnt_clear;
    logic               field_cnt_en;
    logic [2:0]         field_cnt_q;

    counter #(
      .WIDTH           (3),
      .STICKY_OVERFLOW (1'b0)
    ) i_field_counter (
      .clk_i      (clk_i),
      .rst_ni     (rst_ni),
      .clear_i    (field_cnt_clear),
      .en_i       (field_cnt_en),
      .load_i     (1'b0),
      .down_i     (1'b0),
      .d_i        (3'd0),
      .q_o        (field_cnt_q),
      .overflow_o ()
    );

    always_comb begin
      automatic logic [1:0] init_eew  = ara_req_i.vtype.vsew[1:0];
      automatic elen_t      init_step = (ara_req_i.op == VLE || ara_req_i.op == VSE)
        ? ((elen_t'(ara_req_i.nf) + elen_t'(1)) << init_eew)
        : ara_req_i.stride;
      automatic elen_t      init_addr = ara_req_i.scalar_op + (elen_t'(ara_req_i.vstart) * init_step);
      automatic logic [4:0] reg_delta = saved_req_q.emul[2]
        ? 5'd1
        : (5'd1 << saved_req_q.emul[1:0]);
      automatic elen_t      field_bytes = elen_t'(1) << saved_req_q.vtype.vsew[1:0];
      automatic ara_req_t   staged_uop;

      state_d          = state_q;
      saved_req_d      = saved_req_q;
      final_resp_d     = final_resp_q;
      is_load_d        = is_load_q;
      elem_step_d      = elem_step_q;
      elem_base_addr_d = elem_base_addr_q;
      cur_field_addr_d = cur_field_addr_q;
      cur_vd_d         = cur_vd_q;
      cur_vs1_d        = cur_vs1_q;
      cur_elem_d       = cur_elem_q;

      field_cnt_clear  = 1'b0;
      field_cnt_en     = 1'b0;

      ara_req_o        = ara_req_i;
      ara_req_valid_o  = ara_req_valid_i;
      ara_resp_o       = ara_resp_i;
      ara_resp_valid_o = ara_resp_valid_i;
      load_complete_o  = 1'b0;
      store_complete_o = 1'b0;
      seg_mem_op_end_o = 1'b0;

      staged_uop                  = saved_req_q;
      staged_uop.op               = is_load_q ? VLSE : VSSE;
      staged_uop.stride           = '0;
      staged_uop.scalar_op        = cur_field_addr_q;
      staged_uop.vstart           = cur_elem_q;
      staged_uop.vl               = cur_elem_q + {{(VStartW-1){1'b0}}, 1'b1};
      staged_uop.vd               = cur_vd_q;
      staged_uop.vs1              = cur_vs1_q;
      staged_uop.nf               = 3'd0;
      staged_uop.fault_only_first = 1'b0;
      staged_uop.token            = ara_req_i.token;

      unique case (state_q)
        S_PASS: begin
          load_complete_o  = is_segment_mem_op_i ? 1'b0 : load_complete_i;
          store_complete_o = is_segment_mem_op_i ? 1'b0 : store_complete_i;
          ara_resp_valid_o = is_segment_mem_op_i ? 1'b0 : ara_resp_valid_i;

          if (is_segment_mem_op_i && ara_req_valid_i && !illegal_insn_i) begin
            ara_req_valid_o  = 1'b0;

            saved_req_d      = ara_req_i;
            is_load_d        = is_vload_i;
            final_resp_d     = '0;
            elem_step_d      = init_step;
            elem_base_addr_d = init_addr;
            cur_field_addr_d = init_addr;
            cur_vd_d         = ara_req_i.vd;
            cur_vs1_d        = ara_req_i.vs1;
            cur_elem_d       = ara_req_i.vstart;
            field_cnt_clear  = 1'b1;
            state_d          = S_STAGE_UOP;
          end
        end

        S_STAGE_UOP: begin
          ara_req_o        = staged_uop;
          ara_req_valid_o  = 1'b1;
          ara_resp_valid_o = 1'b0;

          if (ara_req_ready_i) begin
            state_d = S_WAIT_UOP_ACK;
          end
        end

        S_WAIT_UOP_ACK: begin
          ara_req_valid_o  = 1'b0;
          ara_resp_valid_o = 1'b0;

          if (ara_resp_valid_i) begin
            if (ara_resp_i.exception.valid) begin
              final_resp_d                  = ara_resp_i;
              final_resp_d.exception_vstart = cur_elem_q;
              if (saved_req_q.fault_only_first &&
                  (ara_resp_i.exception.cause != riscv::ILLEGAL_INSTR) &&
                  (cur_elem_q != '0)) begin
                final_resp_d.fof_exception = 1'b1;
              end else begin
                final_resp_d.fof_exception = 1'b0;
              end
              state_d = S_WAIT_BACKEND_IDLE;
            end else if ((field_cnt_q == saved_req_q.nf) &&
                         ((cur_elem_q + {{(VStartW-1){1'b0}}, 1'b1}) == saved_req_q.vl)) begin
              final_resp_d = ara_resp_i;
              state_d      = S_WAIT_BACKEND_IDLE;
            end else if (field_cnt_q == saved_req_q.nf) begin
              field_cnt_clear  = 1'b1;
              cur_elem_d       = cur_elem_q + {{(VStartW-1){1'b0}}, 1'b1};
              elem_base_addr_d = elem_base_addr_q + elem_step_q;
              cur_field_addr_d = elem_base_addr_q + elem_step_q;
              cur_vd_d         = saved_req_q.vd;
              cur_vs1_d        = saved_req_q.vs1;
              state_d          = S_STAGE_UOP;
            end else begin
              field_cnt_en     = 1'b1;
              cur_field_addr_d = cur_field_addr_q + field_bytes;
              cur_vd_d         = cur_vd_q  + reg_delta;
              cur_vs1_d        = cur_vs1_q + reg_delta;
              state_d          = S_STAGE_UOP;
            end
          end
        end

        S_WAIT_BACKEND_IDLE: begin
          ara_req_valid_o  = 1'b0;
          ara_resp_valid_o = 1'b0;

          if (ara_idle_i && ara_req_ready_i) begin
            state_d = S_SEND_FINAL_RESP;
          end
        end

        S_SEND_FINAL_RESP: begin
          ara_req_valid_o  = 1'b0;
          ara_resp_o       = final_resp_q;
          ara_resp_valid_o = 1'b1;
          seg_mem_op_end_o = 1'b1;

          if (is_segment_mem_op_i) begin
            load_complete_o  = is_load_q;
            store_complete_o = ~is_load_q;
            state_d          = S_PASS;
          end
        end

        default: begin
          state_d = S_PASS;
        end
      endcase
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin
      if (!rst_ni) begin
        state_q          <= S_PASS;
        saved_req_q      <= '0;
        final_resp_q     <= '0;
        is_load_q        <= 1'b0;
        elem_step_q      <= '0;
        elem_base_addr_q <= '0;
        cur_field_addr_q <= '0;
        cur_vd_q         <= '0;
        cur_vs1_q        <= '0;
        cur_elem_q       <= '0;
      end else begin
        state_q          <= state_d;
        saved_req_q      <= saved_req_d;
        final_resp_q     <= final_resp_d;
        is_load_q        <= is_load_d;
        elem_step_q      <= elem_step_d;
        elem_base_addr_q <= elem_base_addr_d;
        cur_field_addr_q <= cur_field_addr_d;
        cur_vd_q         <= cur_vd_d;
        cur_vs1_q        <= cur_vs1_d;
        cur_elem_q       <= cur_elem_d;
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
