// Copyright 2020 Silicon Labs, Inc.
// Solderpad License, Version 2.0

module cv32e40p_obi_interface #(
    parameter TRANS_STABLE = 0
) (
    input logic clk,
    input logic rst_n,

    input  logic        trans_valid_i,
    output logic        trans_ready_o,
    input  logic [31:0] trans_addr_i,
    input  logic        trans_we_i,
    input  logic [ 3:0] trans_be_i,
    input  logic [31:0] trans_wdata_i,
    input  logic [ 5:0] trans_atop_i,

    output logic        resp_valid_o,
    output logic [31:0] resp_rdata_o,
    output logic        resp_err_o,

    output logic        obi_req_o,
    input  logic        obi_gnt_i,
    output logic [31:0] obi_addr_o,
    output logic        obi_we_o,
    output logic [ 3:0] obi_be_o,
    output logic [31:0] obi_wdata_o,
    output logic [ 5:0] obi_atop_o,
    input  logic [31:0] obi_rdata_i,
    input  logic        obi_rvalid_i,
    input  logic        obi_err_i
);

  logic is_reg_q;

  assign resp_valid_o = obi_rvalid_i;
  assign resp_rdata_o = obi_rdata_i;
  assign resp_err_o   = obi_err_i;

  generate
    if (TRANS_STABLE) begin : gen_trans_stable
      assign obi_req_o     = trans_valid_i;
      assign obi_addr_o    = trans_addr_i;
      assign obi_we_o      = trans_we_i;
      assign obi_be_o      = trans_be_i;
      assign obi_wdata_o   = trans_wdata_i;
      assign obi_atop_o    = trans_atop_i;
      assign trans_ready_o = obi_gnt_i;
      assign is_reg_q      = 1'b0;
    end else begin : gen_no_trans_stable
      logic [31:0] hold_addr_q;
      logic        hold_we_q;
      logic [ 3:0] hold_be_q;
      logic [31:0] hold_wdata_q;
      logic [ 5:0] hold_atop_q;

      assign obi_req_o     = is_reg_q ? 1'b1         : trans_valid_i;
      assign obi_addr_o    = is_reg_q ? hold_addr_q  : trans_addr_i;
      assign obi_we_o      = is_reg_q ? hold_we_q    : trans_we_i;
      assign obi_be_o      = is_reg_q ? hold_be_q    : trans_be_i;
      assign obi_wdata_o   = is_reg_q ? hold_wdata_q : trans_wdata_i;
      assign obi_atop_o    = is_reg_q ? hold_atop_q  : trans_atop_i;
      assign trans_ready_o = ~is_reg_q;

      always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
          is_reg_q     <= 1'b0;
          hold_addr_q  <= 32'b0;
          hold_we_q    <= 1'b0;
          hold_be_q    <= 4'b0;
          hold_wdata_q <= 32'b0;
          hold_atop_q  <= 6'b0;
        end else if (!is_reg_q) begin
          if (trans_valid_i && !obi_gnt_i) begin
            is_reg_q     <= 1'b1;
            hold_addr_q  <= trans_addr_i;
            hold_we_q    <= trans_we_i;
            hold_be_q    <= trans_be_i;
            hold_wdata_q <= trans_wdata_i;
            hold_atop_q  <= trans_atop_i;
          end
        end else if (obi_gnt_i) begin
          is_reg_q <= 1'b0;
        end
      end
    end
  endgenerate

endmodule
