// Copyright 2021 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// Author: Matteo Perotti <mperotti@iis.ee.ethz.ch>
// Description:
// Ara's Serial Divider, operating on elements 64-bit wide.
// Optimized with active-subword bitmask priority fast-skip, zero-cycle inactive
// subword bypass, single-cycle all-masked beat completion, registered 64-bit
// operand preparation ahead of serdiv, and direct subword demux writeback.

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

  ///////////////////
  //  Definitions  //
  ///////////////////

  typedef enum logic [2:0] {
    DIV_IDLE,
    DIV_PREP,
    DIV_ISSUE,
    DIV_WAIT,
    DIV_DONE
  } div_state_e;

  typedef union packed {
    logic [0:0][63:0] w64;
    logic [1:0][31:0] w32;
    logic [3:0][15:0] w16;
    logic [7:0][ 7:0] w8;
  } operand_t;

  div_state_e state_d, state_q;

  operand_t   opa_d, opa_q, opb_d, opb_q;
  elen_t      div_opa_d, div_opa_q, div_opb_d, div_opb_q;
  vew_e       vew_d, vew_q;
  logic [1:0] serdiv_op_d, serdiv_op_q;
  logic       is_signed_d, is_signed_q;
  strb_t      mask_d, mask_q;
  operand_t   result_d, result_q;

  // Remaining active subword bitmap and current active subword index
  logic [7:0] rem_mask_d, rem_mask_q;
  logic [2:0] cur_idx_d, cur_idx_q;

  assign result_o = result_q;
  assign mask_o   = mask_q;

  // Extract per-subword active bitmap from lane byte-enable strobe be_i
  function automatic logic [7:0] extract_active_mask(input strb_t be, input vew_e vew);
    unique case (vew)
      EW8    : extract_active_mask = be;
      EW16   : extract_active_mask = {4'b0000, be[6], be[4], be[2], be[0]};
      EW32   : extract_active_mask = {6'b000000, be[4], be[0]};
      default: extract_active_mask = {7'b0000000, be[0]};
    endcase
  endfunction

  // LSB-first priority encoder over 8-bit active subword bitmap
  function automatic logic [2:0] find_first_active(input logic [7:0] active_mask);
    find_first_active = 3'd0;
    for (int i = 7; i >= 0; i--) begin
      if (active_mask[i]) begin
        find_first_active = i[2:0];
      end
    end
  endfunction

  // Encode ara_op_e into serdiv 2-bit opcode once on handshake
  function automatic logic [1:0] encode_serdiv_op(input ara_op_e op);
    unique case (op)
      VDIVU  : encode_serdiv_op = 2'b00;
      VDIV   : encode_serdiv_op = 2'b01;
      VREMU  : encode_serdiv_op = 2'b10;
      VREM   : encode_serdiv_op = 2'b11;
      default: encode_serdiv_op = 2'b00;
    endcase
  endfunction

  // Select and sign/zero-extend subword `idx` from registered 64-bit word
  function automatic elen_t select_subword(
    input operand_t   op_word,
    input logic [2:0] idx,
    input vew_e       vew,
    input logic       sgn
  );
    unique case (vew)
      EW8: begin
        automatic logic [7:0] b8 = op_word.w8[idx[2:0]];
        select_subword = {{56{sgn & b8[7]}}, b8};
      end
      EW16: begin
        automatic logic [15:0] b16 = op_word.w16[idx[1:0]];
        select_subword = {{48{sgn & b16[15]}}, b16};
      end
      EW32: begin
        automatic logic [31:0] b32 = op_word.w32[idx[0:0]];
        select_subword = {{32{sgn & b32[31]}}, b32};
      end
      default: begin
        select_subword = op_word.w64[0];
      end
    endcase
  endfunction

  // Serial Divider interface signals
  logic     serdiv_in_valid_d, serdiv_in_valid_q, serdiv_in_ready;
  logic     serdiv_out_valid, serdiv_out_ready;
  operand_t serdiv_result;

  ///////////////////////////
  //  Control & Fast-Skip  //
  ///////////////////////////

  logic [7:0] init_active_mask;
  logic [2:0] next_active_idx;
  logic       load_next_subword;

  assign init_active_mask = extract_active_mask(be_i, vew_i);
  assign next_active_idx  = find_first_active(rem_mask_q);

  always_comb begin : p_ctrl
    automatic logic in_signed;
    in_signed = (op_i inside {VDIV, VREM});

    state_d           = state_q;
    ready_o           = 1'b0;
    valid_o           = 1'b0;
    serdiv_in_valid_d = serdiv_in_valid_q;
    serdiv_out_ready  = 1'b0;
    load_next_subword = 1'b0;

    opa_d       = opa_q;
    opb_d       = opb_q;
    div_opa_d   = div_opa_q;
    div_opb_d   = div_opb_q;
    vew_d       = vew_q;
    serdiv_op_d = serdiv_op_q;
    is_signed_d = is_signed_q;
    mask_d      = mask_q;
    result_d    = result_q;
    rem_mask_d  = rem_mask_q;
    cur_idx_d   = cur_idx_q;

    unique case (state_q)
      DIV_IDLE: begin
        ready_o = 1'b1;
        if (valid_i) begin
          opa_d       = operand_a_i;
          opb_d       = operand_b_i;
          mask_d      = mask_i;
          vew_d       = vew_i;
          serdiv_op_d = encode_serdiv_op(op_i);
          is_signed_d = in_signed;
          result_d    = '0;
          rem_mask_d  = init_active_mask;
          if (init_active_mask == 8'h00) begin
            // All subwords in this 64-bit beat are masked off: bypass serdiv in 1 cycle
            state_d = DIV_DONE;
          end else begin
            // Isolate input beat capture from subword muxing and sign-extension fanout
            state_d = DIV_PREP;
          end
        end
      end

      DIV_PREP: begin
        load_next_subword = 1'b1;
        serdiv_in_valid_d = 1'b1;
        state_d           = DIV_ISSUE;
      end

      DIV_ISSUE: begin
        if (serdiv_in_ready) begin
          serdiv_in_valid_d = 1'b0;
          state_d           = DIV_WAIT;
        end
      end

      DIV_WAIT: begin
        serdiv_out_ready = 1'b1;
        if (serdiv_out_valid) begin
          // Direct subword-indexed result writeback without sequential shifting
          unique case (vew_q)
            EW8    : result_d.w8 [cur_idx_q[2:0]] = serdiv_result.w8 [0];
            EW16   : result_d.w16[cur_idx_q[1:0]] = serdiv_result.w16[0];
            EW32   : result_d.w32[cur_idx_q[0:0]] = serdiv_result.w32[0];
            default: result_d.w64[0]              = serdiv_result.w64[0];
          endcase

          if (rem_mask_q == 8'h00) begin
            state_d = DIV_DONE;
          end else begin
            // Pre-stage next active subword into 64-bit registers while serdiv returns to IDLE
            load_next_subword = 1'b1;
            serdiv_in_valid_d = 1'b1;
            state_d           = DIV_ISSUE;
          end
        end
      end

      DIV_DONE: begin
        valid_o = 1'b1;
        if (ready_i) begin
          state_d = DIV_IDLE;
        end
      end

      default: state_d = DIV_IDLE;
    endcase

    if (load_next_subword) begin
      div_opa_d  = select_subword(opa_q, next_active_idx, vew_q, is_signed_q);
      div_opb_d  = select_subword(opb_q, next_active_idx, vew_q, is_signed_q);
      cur_idx_d  = next_active_idx;
      rem_mask_d = rem_mask_q & ~(8'h01 << next_active_idx);
    end
  end

  // Serial divider core fed directly by registered 64-bit operands
  serdiv #(
    .CVA6Cfg         (CVA6Cfg),
    .WIDTH           (ELEN   ),
    .STABLE_HANDSHAKE(1      )
  ) i_serdiv (
    .clk_i    (clk_i            ),
    .rst_ni   (rst_ni           ),
    .id_i     ('0               ),
    .op_a_i   (div_opa_q        ),
    .op_b_i   (div_opb_q        ),
    .opcode_i (serdiv_op_q      ),
    .in_vld_i (serdiv_in_valid_q),
    .in_rdy_o (serdiv_in_ready  ),
    .flush_i  (1'b0             ),
    .out_vld_o(serdiv_out_valid ),
    .out_rdy_i(serdiv_out_ready ),
    .id_o     (/* unconnected */),
    .res_o    (serdiv_result    )
  );

  //////////////////////////////
  //  Sequential assignments  //
  //////////////////////////////

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q           <= DIV_IDLE;
      serdiv_in_valid_q <= 1'b0;
      opa_q             <= '0;
      opb_q             <= '0;
      div_opa_q         <= '0;
      div_opb_q         <= '0;
      vew_q             <= EW8;
      serdiv_op_q       <= 2'b01;
      is_signed_q       <= 1'b1;
      mask_q            <= '0;
      result_q          <= '0;
      rem_mask_q        <= '0;
      cur_idx_q         <= '0;
    end else begin
      state_q           <= state_d;
      serdiv_in_valid_q <= serdiv_in_valid_d;
      opa_q             <= opa_d;
      opb_q       <= opb_d;
      div_opa_q   <= div_opa_d;
      div_opb_q   <= div_opb_d;
      vew_q       <= vew_d;
      serdiv_op_q <= serdiv_op_d;
      is_signed_q <= is_signed_d;
      mask_q      <= mask_d;
      result_q    <= result_d;
      rem_mask_q  <= rem_mask_d;
      cur_idx_q   <= cur_idx_d;
    end
  end

endmodule : simd_div
