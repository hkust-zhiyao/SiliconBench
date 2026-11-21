// Copyright 2020 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

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
    logic               err;
    logic [31:0]        result;
    logic [IdWidth-1:0] id;
  } result_t;

  logic div_valid_op, div_ready_op;
  logic mul_valid_op, mul_ready_op;
  logic mul_is_err;
  logic mul_valid, mul_ready;
  logic div_valid, div_ready;
  result_t div_pkt, mul_pkt, oup;

  always_comb begin
    mul_valid_op = 1'b0;
    div_valid_op = 1'b0;
    mul_is_err   = 1'b0;
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
        // Route unsupported instructions through multiplier pipeline tagged with err=1
        mul_valid_op = acc_qvalid_i;
        mul_is_err   = 1'b1;
        acc_qready_o = mul_ready_op;
      end
    endcase
  end

  assign div_pkt.err = 1'b0;

  snitch_shared_muldiv_multiplier #(
    .Width   ( 32      ),
    .IdWidth ( IdWidth )
  ) i_multiplier (
    .clk_i       ( clk_i                  ),
    .rst_ni      ( rst_ni                 ),
    .id_i        ( acc_qid_i              ),
    .err_i       ( mul_is_err             ),
    .operator_i  ( acc_qdata_op_i         ),
    .operand_a_i ( acc_qdata_arga_i[31:0] ),
    .operand_b_i ( acc_qdata_argb_i[31:0] ),
    .valid_i     ( mul_valid_op           ),
    .ready_o     ( mul_ready_op           ),
    .result_o    ( mul_pkt.result         ),
    .err_o       ( mul_pkt.err            ),
    .valid_o     ( mul_valid              ),
    .ready_i     ( mul_ready              ),
    .id_o        ( mul_pkt.id             )
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
    .id_o       ( div_pkt.id             ),
    .res_o      ( div_pkt.result         )
  );

  stream_arbiter #(
    .DATA_T ( result_t ),
    .N_INP  ( 2        )
  ) i_stream_arbiter (
    .clk_i       ( clk_i                  ),
    .rst_ni      ( rst_ni                 ),
    .inp_data_i  ( {div_pkt, mul_pkt}     ),
    .inp_valid_i ( {div_valid, mul_valid} ),
    .inp_ready_o ( {div_ready, mul_ready} ),
    .oup_data_o  ( oup                    ),
    .oup_valid_o ( acc_pvalid_o           ),
    .oup_ready_i ( acc_pready_i           )
  );

  assign acc_pdata_o  = oup.err ? '0 : data_t'(oup.result);
  assign acc_pid_o    = oup.id;
  assign acc_perror_o = oup.err;
endmodule

module snitch_shared_muldiv_multiplier #(
  parameter int unsigned Width   = 32,
  parameter int unsigned IdWidth = 5
) (
  input  logic               clk_i,
  input  logic               rst_ni,
  input  logic [IdWidth-1:0] id_i,
  input  logic               err_i,
  input  logic [31:0]        operator_i,
  input  logic [Width-1:0]   operand_a_i,
  input  logic [Width-1:0]   operand_b_i,
  input  logic               valid_i,
  output logic               ready_o,
  output logic [Width-1:0]   result_o,
  output logic               err_o,
  output logic               valid_o,
  input  logic               ready_i,
  output logic [IdWidth-1:0] id_o
);
  logic sign_a, sign_b, upper_d;
  always_comb begin
    sign_a  = 1'b0;
    sign_b  = 1'b0;
    upper_d = 1'b0;
    unique casez (operator_i)
      riscv_instr::MULH:   begin sign_a = 1'b1; sign_b = 1'b1; upper_d = 1'b1; end
      riscv_instr::MULHU:  begin upper_d = 1'b1; end
      riscv_instr::MULHSU: begin sign_a = 1'b1; upper_d = 1'b1; end
      default:             begin upper_d = 1'b0; end
    endcase
  end

  // Radix-256 byte-sliced partial products: 33-bit signed multiplicand x four 9-bit slices
  logic signed [32:0] ma;
  logic signed [8:0]  b0, b1, b2, b3;
  assign ma = {operand_a_i[31] & sign_a, operand_a_i};
  assign b0 = {1'b0, operand_b_i[7:0]};
  assign b1 = {1'b0, operand_b_i[15:8]};
  assign b2 = {1'b0, operand_b_i[23:16]};
  assign b3 = {operand_b_i[31] & sign_b, operand_b_i[31:24]};

  logic signed [41:0] p0_d, p1_d, p2_d, p3_d;
  assign p0_d = ma * b0;
  assign p1_d = ma * b1;
  assign p2_d = ma * b2;
  assign p3_d = ma * b3;

  logic st1_v_q, st2_v_q, st1_rdy, st2_rdy;
  logic st1_up_q, st2_up_q, st1_err_q, st2_err_q;
  logic [IdWidth-1:0] st1_id_q, st2_id_q;
  logic signed [41:0] p0_q, p1_q, p2_q, p3_q;
  logic [63:0] sum64_d, sum64_q;

  assign st2_rdy = ~st2_v_q || ready_i;
  assign st1_rdy = ~st1_v_q || st2_rdy;
  assign ready_o = st1_rdy;

  assign sum64_d = {{22{p0_q[41]}}, p0_q}
                 + ({{14{p1_q[41]}}, p1_q, 8'b0})
                 + ({{6{p2_q[41]}},  p2_q, 16'b0})
                 + ({p3_q[39:0], 24'b0});

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      st1_v_q <= 1'b0; st1_up_q <= 1'b0; st1_err_q <= 1'b0; st1_id_q <= '0;
      p0_q <= '0; p1_q <= '0; p2_q <= '0; p3_q <= '0;
      st2_v_q <= 1'b0; st2_up_q <= 1'b0; st2_err_q <= 1'b0; st2_id_q <= '0;
      sum64_q <= '0;
    end else begin
      if (valid_i && st1_rdy) begin
        st1_v_q   <= 1'b1;
        st1_up_q  <= upper_d;
        st1_err_q <= err_i;
        st1_id_q  <= id_i;
        p0_q      <= err_i ? '0 : p0_d;
        p1_q      <= err_i ? '0 : p1_d;
        p2_q      <= err_i ? '0 : p2_d;
        p3_q      <= err_i ? '0 : p3_d;
      end else if (st1_v_q && st2_rdy) begin
        st1_v_q <= 1'b0;
      end

      if (st1_v_q && st2_rdy) begin
        st2_v_q   <= 1'b1;
        st2_up_q  <= st1_up_q;
        st2_err_q <= st1_err_q;
        st2_id_q  <= st1_id_q;
        sum64_q   <= st1_err_q ? '0 : sum64_d;
      end else if (st2_v_q && ready_i) begin
        st2_v_q <= 1'b0;
      end
    end
  end

  assign result_o = st2_err_q ? '0 : (st2_up_q ? sum64_q[63:32] : sum64_q[31:0]);
  assign err_o    = st2_err_q;
  assign id_o     = st2_id_q;
  assign valid_o  = st2_v_q;
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

  logic is_signed, is_rem;
  always_comb begin
    is_signed = 1'b0;
    is_rem    = 1'b0;
    unique casez (operator_i)
      riscv_instr::DIV:  begin is_signed = 1'b1; end
      riscv_instr::DIVU: begin end
      riscv_instr::REM:  begin is_signed = 1'b1; is_rem = 1'b1; end
      riscv_instr::REMU: begin is_rem = 1'b1; end
      default: ;
    endcase
  end

  typedef enum logic [1:0] {
    ST_IDLE,
    ST_PREP,
    ST_ITER,
    ST_DONE
  } div_state_e;

  div_state_e st_q;
  logic [IdWidth-1:0] id_q;
  logic               rem_q, neg_quo_q, neg_rem_q, div_zero_q, sgn_ovf_q;
  logic [WIDTH-1:0]   raw_a_q, raw_b_q;
  logic               raw_sgn_q;
  logic [WIDTH-1:0]   mag_a_q, mag_b_q, quo_q;
  logic [WIDTH:0]     part_rem_q;
  logic [$clog2(WIDTH)-1:0] bit_idx_q;
  logic [WIDTH-1:0]   final_res_q;

  assign in_rdy_o  = (st_q == ST_IDLE);
  assign out_vld_o = (st_q == ST_DONE);
  assign id_o      = id_q;
  assign res_o     = final_res_q;

  logic [WIDTH:0] shifted_rem;
  logic [WIDTH:0] trial_sub;
  logic           sub_ge;
  logic [WIDTH-1:0] next_quo;
  logic [WIDTH:0]   next_rem;

  assign shifted_rem = {part_rem_q[WIDTH-1:0], mag_a_q[WIDTH-1]};
  assign trial_sub   = shifted_rem - {1'b0, mag_b_q};
  assign sub_ge      = !trial_sub[WIDTH];
  assign next_quo    = {quo_q[WIDTH-2:0], sub_ge};
  assign next_rem    = sub_ge ? trial_sub : shifted_rem;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      st_q        <= ST_IDLE;
      id_q        <= '0;
      rem_q       <= 1'b0;
      neg_quo_q   <= 1'b0;
      neg_rem_q   <= 1'b0;
      div_zero_q  <= 1'b0;
      sgn_ovf_q   <= 1'b0;
      raw_a_q     <= '0;
      raw_b_q     <= '0;
      raw_sgn_q   <= 1'b0;
      mag_a_q     <= '0;
      mag_b_q     <= '0;
      quo_q       <= '0;
      part_rem_q  <= '0;
      bit_idx_q   <= '0;
      final_res_q <= '0;
    end else begin
      unique case (st_q)
        ST_IDLE: begin
          if (in_vld_i) begin
            id_q      <= id_i;
            rem_q     <= is_rem;
            raw_sgn_q <= is_signed;
            raw_a_q   <= op_a_i;
            raw_b_q   <= op_b_i;
            st_q      <= ST_PREP;
          end
        end

        ST_PREP: begin
          div_zero_q <= (raw_b_q == '0);
          sgn_ovf_q  <= raw_sgn_q && (raw_a_q == {1'b1, {(WIDTH-1){1'b0}}}) && (raw_b_q == '1);
          neg_quo_q  <= raw_sgn_q && (raw_a_q[WIDTH-1] ^ raw_b_q[WIDTH-1]);
          neg_rem_q  <= raw_sgn_q && raw_a_q[WIDTH-1];
          mag_a_q    <= (raw_sgn_q && raw_a_q[WIDTH-1]) ? (~raw_a_q + 1'b1) : raw_a_q;
          mag_b_q    <= (raw_sgn_q && raw_b_q[WIDTH-1]) ? (~raw_b_q + 1'b1) : raw_b_q;
          quo_q      <= '0;
          part_rem_q <= '0;
          bit_idx_q  <= ($clog2(WIDTH))'(WIDTH - 1);
          if (raw_b_q == '0) begin
            final_res_q <= rem_q ? raw_a_q : '1;
            st_q        <= ST_DONE;
          end else if (raw_sgn_q && (raw_a_q == {1'b1, {(WIDTH-1){1'b0}}}) && (raw_b_q == '1)) begin
            final_res_q <= rem_q ? '0 : raw_a_q;
            st_q        <= ST_DONE;
          end else begin
            st_q <= ST_ITER;
          end
        end

        ST_ITER: begin
          mag_a_q    <= {mag_a_q[WIDTH-2:0], 1'b0};
          quo_q      <= next_quo;
          part_rem_q <= next_rem;
          if (bit_idx_q == '0) begin
            if (rem_q) begin
              final_res_q <= neg_rem_q ? (~next_rem[WIDTH-1:0] + 1'b1) : next_rem[WIDTH-1:0];
            end else begin
              final_res_q <= neg_quo_q ? (~next_quo + 1'b1) : next_quo;
            end
            st_q <= ST_DONE;
          end else begin
            bit_idx_q <= bit_idx_q - 1'b1;
          end
        end

        ST_DONE: begin
          if (out_rdy_i) begin
            st_q <= ST_IDLE;
          end
        end

        default: st_q <= ST_IDLE;
      endcase
    end
  end
endmodule
