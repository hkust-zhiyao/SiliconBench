// Copyright 2021 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// Author: Matteo Perotti <mperotti@iis.ee.ethz.ch>
// Description:
// Alternate architecture for Ara's 64-bit SIMD Serial Divider:
// Hardware LZC-driven active-subword scheduler with pre-staged 64-bit
// sign/zero-extended operand registers ahead of serdiv and byte-strobe
// masked result accumulation.

module simd_div import ara_pkg::*; import rvv_pkg::*; #(
    // CVA6 configuration
    parameter  config_pkg::cva6_cfg_t CVA6Cfg = cva6_config_pkg::cva6_cfg,
    // Dependant parameters. DO NOT CHANGE!
    localparam int  unsigned DataWidth = $bits(elen_t),
    localparam int  unsigned StrbWidth = DataWidth/8,
    localparam type          strb_t    = logic [DataWidth/8-1:0]
  ) (
    input  logic    clk_i,
    input  logic    rst_ni,
    input  elen_t   operand_a_i,
    input  elen_t   operand_b_i,
    input  strb_t   mask_i,
    input  ara_op_e op_i,
    input  strb_t   be_i,
    input  vew_e    vew_i,
    output elen_t   result_o,
    output strb_t   mask_o,
    input  logic    valid_i,
    output logic    ready_o,
    input  logic    ready_i,
    output logic    valid_o
  );

  typedef enum logic [1:0] {
    Q_IDLE,
    Q_EXEC_REQ,
    Q_EXEC_COLLECT,
    Q_DRAIN
  } sched_state_e;

  sched_state_e sched_d, sched_q;

  elen_t      buf_opa_d,   buf_opa_q;
  elen_t      buf_opb_d,   buf_opb_q;
  elen_t      stage_opa_d, stage_opa_q;
  elen_t      stage_opb_d, stage_opb_q;
  vew_e       vew_d,       vew_q;
  logic [1:0] opcode_d,    opcode_q;
  logic       signed_op_d, signed_op_q;
  strb_t      mask_d,      mask_q;
  elen_t      acc_res_d,   acc_res_q;

  logic [7:0] pending_vec_d, pending_vec_q;
  logic [2:0] active_slot_d, active_slot_q;

  assign result_o = acc_res_q;
  assign mask_o   = mask_q;

  // Compress byte-enable into subword validity bitmap
  function automatic logic [7:0] build_slot_vec(input strb_t be, input vew_e vew);
    unique case (vew)
      EW8    : build_slot_vec = be;
      EW16   : build_slot_vec = {4'b0, be[6], be[4], be[2], be[0]};
      EW32   : build_slot_vec = {6'b0, be[4], be[0]};
      default: build_slot_vec = {7'b0, be[0]};
    endcase
  endfunction

  // Extract and sign/zero-extend subword `slot` from 64-bit word `src`
  function automatic elen_t extend_subword(
    input elen_t      src,
    input logic [2:0] slot,
    input vew_e       vew,
    input logic       is_sgn
  );
    unique case (vew)
      EW8: begin
        automatic logic [7:0] v8 = src[slot * 8 +: 8];
        extend_subword = {{56{is_sgn & v8[7]}}, v8};
      end
      EW16: begin
        automatic logic [15:0] v16 = src[slot[1:0] * 16 +: 16];
        extend_subword = {{48{is_sgn & v16[15]}}, v16};
      end
      EW32: begin
        automatic logic [31:0] v32 = src[slot[0] * 32 +: 32];
        extend_subword = {{32{is_sgn & v32[31]}}, v32};
      end
      default: begin
        extend_subword = src;
      end
    endcase
  endfunction

  // Byte write-enable strobe for writing subword `slot` at width `vew`
  function automatic strb_t slot_byte_strobe(input logic [2:0] slot, input vew_e vew);
    unique case (vew)
      EW8    : slot_byte_strobe = 8'h01 << slot;
      EW16   : slot_byte_strobe = 8'h03 << {slot[1:0], 1'b0};
      EW32   : slot_byte_strobe = 8'h0F << {slot[0],   2'b00};
      default: slot_byte_strobe = 8'hFF;
    endcase
  endfunction

  // Hardware trailing-zero counters (common_cells lzc MODE=0) for O(1) active-slot jump
  logic [7:0] init_slot_vec;
  logic [2:0] init_tzc_idx, next_tzc_idx;
  logic       init_vec_empty, next_vec_empty;

  assign init_slot_vec = build_slot_vec(be_i, vew_i);

  lzc #(
    .WIDTH(8),
    .MODE (0)
  ) i_lzc_init (
    .in_i   (init_slot_vec ),
    .cnt_o  (init_tzc_idx  ),
    .empty_o(init_vec_empty)
  );

  lzc #(
    .WIDTH(8),
    .MODE (0)
  ) i_lzc_next (
    .in_i   (pending_vec_q ),
    .cnt_o  (next_tzc_idx  ),
    .empty_o(next_vec_empty)
  );

  logic  serdiv_in_vld, serdiv_in_rdy, serdiv_out_vld, serdiv_out_rdy;
  elen_t serdiv_res;

  always_comb begin : p_sched
    automatic logic  in_is_sgn;
    automatic strb_t wr_be;
    automatic elen_t aligned_res;

    sched_d          = sched_q;
    ready_o          = 1'b0;
    valid_o          = 1'b0;
    serdiv_in_vld    = 1'b0;
    serdiv_out_rdy   = 1'b0;

    buf_opa_d     = buf_opa_q;
    buf_opb_d     = buf_opb_q;
    stage_opa_d   = stage_opa_q;
    stage_opb_d   = stage_opb_q;
    vew_d         = vew_q;
    opcode_d      = opcode_q;
    signed_op_d   = signed_op_q;
    mask_d        = mask_q;
    acc_res_d     = acc_res_q;
    pending_vec_d = pending_vec_q;
    active_slot_d = active_slot_q;

    in_is_sgn   = (op_i inside {VDIV, VREM});
    wr_be       = slot_byte_strobe(active_slot_q, vew_q);
    aligned_res = '0;
    unique case (vew_q)
      EW8    : aligned_res = {8{serdiv_res[ 7:0]}};
      EW16   : aligned_res = {4{serdiv_res[15:0]}};
      EW32   : aligned_res = {2{serdiv_res[31:0]}};
      default: aligned_res = serdiv_res;
    endcase

    unique case (sched_q)
      Q_IDLE: begin
        ready_o = 1'b1;
        if (valid_i) begin
          mask_d    = mask_i;
          vew_d     = vew_i;
          acc_res_d = '0;
          if (init_vec_empty) begin
            pending_vec_d = '0;
            sched_d       = Q_DRAIN;
          end else begin
            buf_opa_d   = operand_a_i;
            buf_opb_d   = operand_b_i;
            signed_op_d = in_is_sgn;
            unique case (op_i)
              VDIVU  : opcode_d = 2'b00;
              VDIV   : opcode_d = 2'b01;
              VREMU  : opcode_d = 2'b10;
              VREM   : opcode_d = 2'b11;
              default: opcode_d = 2'b00;
            endcase
            stage_opa_d   = extend_subword(operand_a_i, init_tzc_idx, vew_i, in_is_sgn);
            stage_opb_d   = extend_subword(operand_b_i, init_tzc_idx, vew_i, in_is_sgn);
            active_slot_d = init_tzc_idx;
            pending_vec_d = init_slot_vec & ~(8'h01 << init_tzc_idx);
            sched_d       = Q_EXEC_REQ;
          end
        end
      end

      Q_EXEC_REQ: begin
        serdiv_in_vld = 1'b1;
        if (serdiv_in_rdy) begin
          sched_d = Q_EXEC_COLLECT;
        end
      end

      Q_EXEC_COLLECT: begin
        serdiv_out_rdy = 1'b1;
        if (serdiv_out_vld) begin
          for (int b = 0; b < 8; b++) begin
            if (wr_be[b]) begin
              acc_res_d[8*b +: 8] = aligned_res[8*b +: 8];
            end
          end

          if (next_vec_empty) begin
            sched_d = Q_DRAIN;
          end else begin
            // Overlap pre-staging of next active subword while serdiv returns to IDLE
            stage_opa_d   = extend_subword(buf_opa_q, next_tzc_idx, vew_q, signed_op_q);
            stage_opb_d   = extend_subword(buf_opb_q, next_tzc_idx, vew_q, signed_op_q);
            active_slot_d = next_tzc_idx;
            pending_vec_d = pending_vec_q & ~(8'h01 << next_tzc_idx);
            sched_d       = Q_EXEC_REQ;
          end
        end
      end

      Q_DRAIN: begin
        valid_o = 1'b1;
        if (ready_i) begin
          sched_d = Q_IDLE;
        end
      end

      default: sched_d = Q_IDLE;
    endcase
  end

  serdiv #(
    .CVA6Cfg         (CVA6Cfg),
    .WIDTH           (ELEN   ),
    .STABLE_HANDSHAKE(1      )
  ) i_serdiv (
    .clk_i    (clk_i            ),
    .rst_ni   (rst_ni           ),
    .id_i     ('0               ),
    .op_a_i   (stage_opa_q      ),
    .op_b_i   (stage_opb_q      ),
    .opcode_i (opcode_q         ),
    .in_vld_i (serdiv_in_vld    ),
    .in_rdy_o (serdiv_in_rdy    ),
    .flush_i  (1'b0             ),
    .out_vld_o(serdiv_out_vld   ),
    .out_rdy_i(serdiv_out_rdy   ),
    .id_o     (/* unconnected */),
    .res_o    (serdiv_res       )
  );

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      sched_q       <= Q_IDLE;
      buf_opa_q     <= '0;
      buf_opb_q     <= '0;
      stage_opa_q   <= '0;
      stage_opb_q   <= '0;
      vew_q         <= EW8;
      opcode_q      <= 2'b01;
      signed_op_q   <= 1'b1;
      mask_q        <= '0;
      acc_res_q     <= '0;
      pending_vec_q <= '0;
      active_slot_q <= '0;
    end else begin
      sched_q       <= sched_d;
      buf_opa_q     <= buf_opa_d;
      buf_opb_q     <= buf_opb_d;
      stage_opa_q   <= stage_opa_d;
      stage_opb_q   <= stage_opb_d;
      vew_q         <= vew_d;
      opcode_q      <= opcode_d;
      signed_op_q   <= signed_op_d;
      mask_q        <= mask_d;
      acc_res_q     <= acc_res_d;
      pending_vec_q <= pending_vec_d;
      active_slot_q <= active_slot_d;
    end
  end

endmodule : simd_div
