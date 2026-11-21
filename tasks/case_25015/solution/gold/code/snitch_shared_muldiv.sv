// Copyright 2020 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

/// Shared Multiply/Divide (RV32M) with pipelined multiplier, aligned serial divider,
/// and non-blocking illegal-opcode error retirement.
`include "common_cells/registers.svh"

module snitch_shared_muldiv #(
  parameter int unsigned IdWidth   = 5,
  parameter int unsigned DataWidth = 32,
  parameter type         data_t    = logic [DataWidth-1:0]
) (
  input  logic                clk_i,
  input  logic                rst_ni,
  input  logic [31:0]         acc_qaddr_i,
  input  logic [IdWidth-1:0]  acc_qid_i,
  input  logic [31:0]         acc_qdata_op_i,
  input  data_t               acc_qdata_arga_i,
  input  data_t               acc_qdata_argb_i,
  input  data_t               acc_qdata_argc_i,
  input  logic                acc_qvalid_i,
  output logic                acc_qready_o,
  output data_t               acc_pdata_o,
  output logic [IdWidth-1:0]  acc_pid_o,
  output logic                acc_perror_o,
  output logic                acc_pvalid_o,
  input  logic                acc_pready_i
);
  typedef struct packed {
    logic               error;
    logic [31:0]        result;
    logic [IdWidth-1:0] id;
  } result_t;

  logic div_valid_op, div_ready_op;
  logic mul_valid_op, mul_ready_op;
  logic err_valid_op, err_ready_op;

  logic mul_valid, mul_ready;
  logic div_valid, div_ready;
  logic err_valid_q, err_ready;
  logic [IdWidth-1:0] err_id_q;

  result_t div_res, mul_res, err_res, oup;

  assign err_ready_op = ~err_valid_q | err_ready;

  always_comb begin
    mul_valid_op = 1'b0;
    div_valid_op = 1'b0;
    err_valid_op = 1'b0;
    acc_qready_o = 1'b0;
    unique casez (acc_qdata_op_i)
      riscv_instr::MUL, riscv_instr::MULH, riscv_instr::MULHSU, riscv_instr::MULHU: begin
        mul_valid_op = acc_qvalid_i;
        acc_qready_o = mul_ready_op;
      end
      riscv_instr::DIV, riscv_instr::DIVU, riscv_instr::REM, riscv_instr::REMU: begin
        div_valid_op = acc_qvalid_i;
        acc_qready_o = div_ready_op;
      end
      default: begin
        err_valid_op = acc_qvalid_i;
        acc_qready_o = err_ready_op;
      end
    endcase
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      err_valid_q <= 1'b0;
      err_id_q    <= '0;
    end else begin
      if (err_valid_op && err_ready_op) begin
        err_valid_q <= 1'b1;
        err_id_q    <= acc_qid_i;
      end else if (err_valid_q && err_ready) begin
        err_valid_q <= 1'b0;
      end
    end
  end

  assign mul_res.error = 1'b0;
  assign div_res.error = 1'b0;
  assign err_res       = '{error: 1'b1, result: 32'b0, id: err_id_q};

  snitch_shared_muldiv_multiplier #(
    .Width   ( 32      ),
    .IdWidth ( IdWidth )
  ) i_multiplier (
    .clk_i       ( clk_i                  ),
    .rst_ni      ( rst_ni                 ),
    .id_i        ( acc_qid_i              ),
    .operator_i  ( acc_qdata_op_i         ),
    .operand_a_i ( acc_qdata_arga_i[31:0] ),
    .operand_b_i ( acc_qdata_argb_i[31:0] ),
    .valid_i     ( mul_valid_op           ),
    .ready_o     ( mul_ready_op           ),
    .result_o    ( mul_res.result         ),
    .valid_o     ( mul_valid              ),
    .ready_i     ( mul_ready              ),
    .id_o        ( mul_res.id             )
  );

  snitch_shared_muldiv_serdiv #(
    .WIDTH   ( 32      ),
    .IdWidth ( IdWidth )
  ) i_div (
    .clk_i      ( clk_i                  ),
    .rst_ni     ( rst_ni                 ),
    .id_i       ( acc_qid_i              ),
    .operator_i ( acc_qdata_op_i         ),
    .op_a_i     ( acc_qdata_arga_i[31:0] ),
    .op_b_i     ( acc_qdata_argb_i[31:0] ),
    .in_vld_i   ( div_valid_op           ),
    .in_rdy_o   ( div_ready_op           ),
    .out_vld_o  ( div_valid              ),
    .out_rdy_i  ( div_ready              ),
    .id_o       ( div_res.id             ),
    .res_o      ( div_res.result         )
  );

  stream_arbiter #(
    .DATA_T ( result_t ),
    .N_INP  ( 3        )
  ) i_stream_arbiter (
    .clk_i       ( clk_i                              ),
    .rst_ni      ( rst_ni                             ),
    .inp_data_i  ( {err_res, div_res, mul_res}        ),
    .inp_valid_i ( {err_valid_q, div_valid, mul_valid}),
    .inp_ready_o ( {err_ready, div_ready, mul_ready}  ),
    .oup_data_o  ( oup                                ),
    .oup_valid_o ( acc_pvalid_o                       ),
    .oup_ready_i ( acc_pready_i                       )
  );

  assign acc_pdata_o  = data_t'(oup.result);
  assign acc_pid_o    = oup.id;
  assign acc_perror_o = oup.error;
endmodule

module snitch_shared_muldiv_multiplier #(
  parameter int unsigned Width   = 32,
  parameter int unsigned IdWidth = 5
) (
  input  logic               clk_i,
  input  logic               rst_ni,
  input  logic [IdWidth-1:0] id_i,
  input  logic [31:0]        operator_i,
  input  logic [Width-1:0]   operand_a_i,
  input  logic [Width-1:0]   operand_b_i,
  input  logic               valid_i,
  output logic               ready_o,
  output logic [Width-1:0]   result_o,
  output logic               valid_o,
  input  logic               ready_i,
  output logic [IdWidth-1:0] id_o
);
  logic sign_a, sign_b, select_upper_d;

  always_comb begin
    sign_a = 1'b0;
    sign_b = 1'b0;
    select_upper_d = 1'b0;
    unique casez (operator_i)
      riscv_instr::MULH: begin
        sign_a = 1'b1;
        sign_b = 1'b1;
        select_upper_d = 1'b1;
      end
      riscv_instr::MULHU: begin
        select_upper_d = 1'b1;
      end
      riscv_instr::MULHSU: begin
        sign_a = 1'b1;
        select_upper_d = 1'b1;
      end
      default: begin
        select_upper_d = 1'b0;
      end
    endcase
  end

  // 2-stage partial-product pipeline (17x17 partial multipliers in Stage 1, final sum in Stage 2)
  logic signed [16:0] a_lo, a_hi, b_lo, b_hi;
  assign a_lo = {1'b0, operand_a_i[15:0]};
  assign a_hi = {operand_a_i[31] & sign_a, operand_a_i[31:16]};
  assign b_lo = {1'b0, operand_b_i[15:0]};
  assign b_hi = {operand_b_i[31] & sign_b, operand_b_i[31:16]};

  logic signed [33:0] pp_ll_d, pp_lh_d, pp_hl_d, pp_hh_d;
  assign pp_ll_d = a_lo * b_lo;
  assign pp_lh_d = a_lo * b_hi;
  assign pp_hl_d = a_hi * b_lo;
  assign pp_hh_d = a_hi * b_hi;

  logic s1_valid_q, s2_valid_q;
  logic s1_ready, s2_ready;
  logic s1_upper_q, s2_upper_q;
  logic [IdWidth-1:0] s1_id_q, s2_id_q;
  logic signed [33:0] pp_ll_q, pp_lh_q, pp_hl_q, pp_hh_q;
  logic [63:0] s2_prod_d, s2_prod_q;

  assign s2_ready = ~s2_valid_q | ready_i;
  assign s1_ready = ~s1_valid_q | s2_ready;
  assign ready_o  = s1_ready;

  logic signed [34:0] mid_sum;
  assign mid_sum   = $signed(pp_lh_q) + $signed(pp_hl_q);
  assign s2_prod_d = {pp_hh_q[31:0], 32'b0}
                   + {{13{mid_sum[34]}}, mid_sum, 16'b0}
                   + {32'b0, pp_ll_q[31:0]};

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      s1_valid_q <= 1'b0;
      s1_upper_q <= 1'b0;
      s1_id_q    <= '0;
      pp_ll_q    <= '0;
      pp_lh_q    <= '0;
      pp_hl_q    <= '0;
      pp_hh_q    <= '0;
      s2_valid_q <= 1'b0;
      s2_upper_q <= 1'b0;
      s2_id_q    <= '0;
      s2_prod_q  <= '0;
    end else begin
      if (valid_i && s1_ready) begin
        s1_valid_q <= 1'b1;
        s1_upper_q <= select_upper_d;
        s1_id_q    <= id_i;
        pp_ll_q    <= pp_ll_d;
        pp_lh_q    <= pp_lh_d;
        pp_hl_q    <= pp_hl_d;
        pp_hh_q    <= pp_hh_d;
      end else if (s1_valid_q && s2_ready) begin
        s1_valid_q <= 1'b0;
      end

      if (s1_valid_q && s2_ready) begin
        s2_valid_q <= 1'b1;
        s2_upper_q <= s1_upper_q;
        s2_id_q    <= s1_id_q;
        s2_prod_q  <= s2_prod_d;
      end else if (s2_valid_q && ready_i) begin
        s2_valid_q <= 1'b0;
      end
    end
  end

  assign result_o = s2_upper_q ? s2_prod_q[63:32] : s2_prod_q[31:0];
  assign id_o     = s2_id_q;
  assign valid_o  = s2_valid_q;
endmodule

module snitch_shared_muldiv_serdiv #(
  parameter int unsigned WIDTH   = 32,
  parameter int unsigned IdWidth = 5
) (
  input  logic               clk_i,
  input  logic               rst_ni,
  input  logic [IdWidth-1:0] id_i,
  input  logic [31:0]        operator_i,
  input  logic [WIDTH-1:0]   op_a_i,
  input  logic [WIDTH-1:0]   op_b_i,
  input  logic               in_vld_i,
  output logic               in_rdy_o,
  output logic               out_vld_o,
  input  logic               out_rdy_i,
  output logic [IdWidth-1:0] id_o,
  output logic [WIDTH-1:0]   res_o
);

  logic signed_op, rem;
  always_comb begin
    signed_op = 1'b0;
    rem       = 1'b0;
    unique casez (operator_i)
      riscv_instr::DIV:  begin signed_op = 1'b1; end
      riscv_instr::DIVU: begin end
      riscv_instr::REM:  begin signed_op = 1'b1; rem = 1'b1; end
      riscv_instr::REMU: begin rem = 1'b1; end
      default: ;
    endcase
  end

  typedef enum logic [1:0] {
    IDLE,
    ALIGN,
    DIVIDE,
    FINISH
  } state_e;
  state_e state_d, state_q;

  logic [WIDTH-1:0] lzc_a_input, lzc_b_input;
  logic [$clog2(WIDTH)-1:0] lzc_a_result, lzc_b_result;
  logic lzc_a_no_one, lzc_b_no_one;

  assign lzc_a_input = (signed_op & op_a_i[WIDTH-1]) ? {~op_a_i[WIDTH-2:0], 1'b0} : op_a_i;
  assign lzc_b_input = (signed_op & op_b_i[WIDTH-1]) ? ~op_b_i : op_b_i;

  lzc #(.MODE(1), .WIDTH(WIDTH)) i_lzc_a (
    .in_i   ( lzc_a_input  ),
    .cnt_o  ( lzc_a_result ),
    .empty_o( lzc_a_no_one )
  );

  lzc #(.MODE(1), .WIDTH(WIDTH)) i_lzc_b (
    .in_i   ( lzc_b_input  ),
    .cnt_o  ( lzc_b_result ),
    .empty_o( lzc_b_no_one )
  );

  // Stage-0 latched operands & LZC outputs (IDLE -> ALIGN)
  logic [WIDTH-1:0] s0_op_a_q, s0_op_b_q;
  logic s0_signed_q, s0_rem_q, s0_b_empty_q;
  logic [$clog2(WIDTH+1)-1:0] s0_shift_a_q;
  logic [$clog2(WIDTH)-1:0]   s0_lzc_b_q;

  logic [WIDTH-1:0] res_q, res_d, op_a_q, op_a_d, op_b_q, op_b_d;
  logic op_a_sign, op_b_sign, op_b_zero, op_b_zero_q, op_b_zero_d;
  logic [IdWidth-1:0] id_q, id_d;
  logic rem_sel_d, rem_sel_q, comp_inv_d, comp_inv_q, res_inv_d, res_inv_q;
  logic [WIDTH-1:0] add_mux, add_out, add_tmp, b_mux, out_mux, op_b_shifted;
  logic [$clog2(WIDTH+1)-1:0] cnt_q, cnt_d;
  logic [$clog2(WIDTH+1):0]   div_shift;
  logic cnt_zero, a_reg_en, b_reg_en, res_reg_en, ab_comp, pm_sel, load_en;
  logic div_res_zero_d, div_res_zero_q;

  assign op_b_zero    = (s0_op_b_q == '0);
  assign op_a_sign    = s0_op_a_q[WIDTH-1];
  assign op_b_sign    = s0_op_b_q[WIDTH-1];
  assign div_shift    = s0_b_empty_q ? ($clog2(WIDTH+1)+1)'(WIDTH)
                                     : ($clog2(WIDTH+1)+1)'(s0_lzc_b_q) - ($clog2(WIDTH+1)+1)'(s0_shift_a_q);
  assign op_b_shifted = s0_op_b_q <<< $unsigned(div_shift[$clog2(WIDTH+1)-1:0]);
  assign div_res_zero_d = load_en ? ($signed(div_shift) < 0) : div_res_zero_q;

  assign pm_sel  = load_en & ~(s0_signed_q & (op_a_sign ^ op_b_sign));
  assign add_mux = load_en ? s0_op_a_q : op_b_q;
  assign b_mux   = load_en ? op_b_shifted : {comp_inv_q, op_b_q[WIDTH-1:1]};
  assign out_mux = rem_sel_q ? op_a_q : res_q;
  assign res_o   = res_inv_q ? -$signed(out_mux) : out_mux;
  assign ab_comp = ((op_a_q == op_b_q) | ((op_a_q > op_b_q) ^ comp_inv_q)) & ((|op_a_q) | op_b_zero_q);
  assign add_tmp = load_en ? '0 : op_a_q;
  assign add_out = pm_sel ? (add_tmp + add_mux) : (add_tmp - $signed(add_mux));

  assign cnt_zero = (cnt_q == '0);
  assign cnt_d    = load_en ? div_shift[$clog2(WIDTH+1)-1:0] : (~cnt_zero ? (cnt_q - 1'b1) : cnt_q);

  always_comb begin
    state_d    = state_q;
    in_rdy_o   = 1'b0;
    out_vld_o  = 1'b0;
    load_en    = 1'b0;
    a_reg_en   = 1'b0;
    b_reg_en   = 1'b0;
    res_reg_en = 1'b0;
    unique case (state_q)
      IDLE: begin
        in_rdy_o = 1'b1;
        if (in_vld_i) state_d = ALIGN;
      end
      ALIGN: begin
        a_reg_en = 1'b1;
        b_reg_en = 1'b1;
        load_en  = 1'b1;
        state_d  = DIVIDE;
      end
      DIVIDE: begin
        if (!div_res_zero_q) begin
          a_reg_en   = ab_comp;
          b_reg_en   = 1'b1;
          res_reg_en = 1'b1;
        end
        if (div_res_zero_q) begin
          out_vld_o = 1'b1;
          state_d   = out_rdy_i ? IDLE : FINISH;
        end else if (cnt_zero) begin
          state_d = FINISH;
        end
      end
      FINISH: begin
        out_vld_o = 1'b1;
        if (out_rdy_i) state_d = IDLE;
      end
      default: state_d = IDLE;
    endcase
  end

  assign rem_sel_d   = load_en ? s0_rem_q : rem_sel_q;
  assign comp_inv_d  = load_en ? (s0_signed_q & op_b_sign) : comp_inv_q;
  assign op_b_zero_d = load_en ? op_b_zero : op_b_zero_q;
  assign res_inv_d   = load_en ? ((~op_b_zero | s0_rem_q) & s0_signed_q & (op_a_sign ^ op_b_sign)) : res_inv_q;
  assign id_d        = (state_q == IDLE && in_vld_i) ? id_i : id_q;
  assign id_o        = id_q;
  assign op_a_d      = a_reg_en ? add_out : op_a_q;
  assign op_b_d      = b_reg_en ? b_mux : op_b_q;
  assign res_d       = load_en ? '0 : (res_reg_en ? {res_q[WIDTH-2:0], ab_comp} : res_q);

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      state_q        <= IDLE;
      s0_op_a_q      <= '0;
      s0_op_b_q      <= '0;
      s0_signed_q    <= 1'b0;
      s0_rem_q       <= 1'b0;
      s0_b_empty_q   <= 1'b0;
      s0_shift_a_q   <= '0;
      s0_lzc_b_q     <= '0;
      op_a_q         <= '0;
      op_b_q         <= '0;
      res_q          <= '0;
      cnt_q          <= '0;
      id_q           <= '0;
      rem_sel_q      <= 1'b0;
      comp_inv_q     <= 1'b0;
      res_inv_q      <= 1'b0;
      op_b_zero_q    <= 1'b0;
      div_res_zero_q <= 1'b0;
    end else begin
      state_q <= state_d;
      if (state_q == IDLE && in_vld_i) begin
        s0_op_a_q    <= op_a_i;
        s0_op_b_q    <= op_b_i;
        s0_signed_q  <= signed_op;
        s0_rem_q     <= rem;
        s0_b_empty_q <= lzc_b_no_one;
        s0_shift_a_q <= lzc_a_no_one ? ($clog2(WIDTH+1))'(WIDTH) : ($clog2(WIDTH+1))'(lzc_a_result);
        s0_lzc_b_q   <= lzc_b_result;
      end
      op_a_q         <= op_a_d;
      op_b_q         <= op_b_d;
      res_q          <= res_d;
      cnt_q          <= cnt_d;
      id_q           <= id_d;
      rem_sel_q      <= rem_sel_d;
      comp_inv_q     <= comp_inv_d;
      res_inv_q      <= res_inv_d;
      op_b_zero_q    <= op_b_zero_d;
      div_res_zero_q <= div_res_zero_d;
    end
  end

endmodule
