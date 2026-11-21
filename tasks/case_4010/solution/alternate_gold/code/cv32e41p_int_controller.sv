// Copyright 2018 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51

module cv32e41p_int_controller
  import cv32e41p_pkg::*;
#(
    parameter PULP_SECURE = 0
) (
    input logic clk,
    input logic rst_n,

    input logic [31:0] irq_i,
    input logic        irq_sec_i,

    output logic       irq_req_ctrl_o,
    output logic       irq_sec_ctrl_o,
    output logic [4:0] irq_id_ctrl_o,
    output logic       irq_wu_ctrl_o,

    input  logic     [31:0] mie_bypass_i,
    output logic     [31:0] mip_o,
    input  logic            m_ie_i,
    input  logic            u_ie_i,
    input  PrivLvl_t        current_priv_lvl_i
);

  logic        global_irq_enable;
  logic [31:0] irq_local_qual;
  logic [31:0] irq_q;
  logic        irq_sec_q;

  always_ff @(posedge clk or negedge rst_n) begin
    if (~rst_n) begin
      irq_q     <= 32'h0;
      irq_sec_q <= 1'b0;
    end else begin
      irq_q     <= irq_i & IRQ_MASK;
      irq_sec_q <= irq_sec_i;
    end
  end

  assign mip_o          = irq_q;
  assign irq_local_qual = irq_q & mie_bypass_i;
  assign irq_wu_ctrl_o  = |(irq_i & mie_bypass_i & IRQ_MASK);

  generate
    if (PULP_SECURE) begin : gen_pulp_secure
      assign global_irq_enable = ((current_priv_lvl_i == PRIV_LVL_U) & (u_ie_i | irq_sec_q)) |
                                 ((current_priv_lvl_i == PRIV_LVL_M) & m_ie_i);
    end else begin : gen_no_pulp_secure
      assign global_irq_enable = m_ie_i;
    end
  endgenerate

  assign irq_req_ctrl_o = (|irq_local_qual) & global_irq_enable;
  assign irq_sec_ctrl_o = irq_sec_q;

  // 4-nibble hierarchical priority encoder for fast [31:16] + standard [11,3,7]
  logic [3:0] q_vld;
  logic [3:0][1:0] q_idx;

  for (genvar g = 0; g < 4; g++) begin : gen_fast_nibbles
    logic [3:0] nib;
    assign nib      = irq_local_qual[16 + 4*g +: 4];
    assign q_vld[g] = |nib;
    assign q_idx[g] = nib[3] ? 2'd3 : (nib[2] ? 2'd2 : (nib[1] ? 2'd1 : 2'd0));
  end

  always_comb begin
    if (q_vld[3])      irq_id_ctrl_o = {3'b111, q_idx[3]};
    else if (q_vld[2]) irq_id_ctrl_o = {3'b110, q_idx[2]};
    else if (q_vld[1]) irq_id_ctrl_o = {3'b101, q_idx[1]};
    else if (q_vld[0]) irq_id_ctrl_o = {3'b100, q_idx[0]};
    else if (irq_local_qual[CSR_MEIX_BIT]) irq_id_ctrl_o = CSR_MEIX_BIT[4:0];
    else if (irq_local_qual[CSR_MSIX_BIT]) irq_id_ctrl_o = CSR_MSIX_BIT[4:0];
    else if (irq_local_qual[CSR_MTIX_BIT]) irq_id_ctrl_o = CSR_MTIX_BIT[4:0];
    else                                   irq_id_ctrl_o = 5'd0;
  end

endmodule
