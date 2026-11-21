// Copyright 2018 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51

module cv32e41p_int_controller
  import cv32e41p_pkg::*;
#(
    parameter PULP_SECURE = 0
) (
    input logic clk,
    input logic rst_n,

    // External interrupt lines
    input logic [31:0] irq_i,
    input logic        irq_sec_i,

    // To cv32e41p_controller
    output logic       irq_req_ctrl_o,
    output logic       irq_sec_ctrl_o,
    output logic [4:0] irq_id_ctrl_o,
    output logic       irq_wu_ctrl_o,

    // To/from cv32e41p_cs_registers
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

  always_ff @(posedge clk, negedge rst_n) begin
    if (rst_n == 1'b0) begin
      irq_q     <= '0;
      irq_sec_q <= 1'b0;
    end else begin
      irq_q     <= irq_i & IRQ_MASK;
      irq_sec_q <= irq_sec_i;
    end
  end

  assign mip_o          = irq_q;
  assign irq_local_qual = irq_q & mie_bypass_i;

  // Mask wakeup with IRQ_MASK so reserved interrupt bits cannot spuriously wake the core
  assign irq_wu_ctrl_o  = |(irq_i & mie_bypass_i & IRQ_MASK);

  generate
    if (PULP_SECURE) begin : gen_pulp_secure
      assign global_irq_enable = ((u_ie_i || irq_sec_q) && current_priv_lvl_i == PRIV_LVL_U) ||
                                 (m_ie_i && current_priv_lvl_i == PRIV_LVL_M);
    end else begin : gen_no_pulp_secure
      assign global_irq_enable = m_ie_i;
    end
  endgenerate

  assign irq_req_ctrl_o = (|irq_local_qual) && global_irq_enable;

  // Tree-structured priority encoder matching CV32E41P priority order
  logic       hi_any, hi_top8;
  logic [4:0] hi_id, std_id;

  assign hi_top8 = |irq_local_qual[31:24];
  assign hi_any  = |irq_local_qual[31:16];

  always_comb begin
    if (hi_top8) begin
      if      (irq_local_qual[31]) hi_id = 5'd31;
      else if (irq_local_qual[30]) hi_id = 5'd30;
      else if (irq_local_qual[29]) hi_id = 5'd29;
      else if (irq_local_qual[28]) hi_id = 5'd28;
      else if (irq_local_qual[27]) hi_id = 5'd27;
      else if (irq_local_qual[26]) hi_id = 5'd26;
      else if (irq_local_qual[25]) hi_id = 5'd25;
      else                         hi_id = 5'd24;
    end else begin
      if      (irq_local_qual[23]) hi_id = 5'd23;
      else if (irq_local_qual[22]) hi_id = 5'd22;
      else if (irq_local_qual[21]) hi_id = 5'd21;
      else if (irq_local_qual[20]) hi_id = 5'd20;
      else if (irq_local_qual[19]) hi_id = 5'd19;
      else if (irq_local_qual[18]) hi_id = 5'd18;
      else if (irq_local_qual[17]) hi_id = 5'd17;
      else                         hi_id = 5'd16;
    end

    if      (irq_local_qual[CSR_MEIX_BIT]) std_id = CSR_MEIX_BIT[4:0];
    else if (irq_local_qual[CSR_MSIX_BIT]) std_id = CSR_MSIX_BIT[4:0];
    else if (irq_local_qual[CSR_MTIX_BIT]) std_id = CSR_MTIX_BIT[4:0];
    else                                   std_id = 5'd0;

    irq_id_ctrl_o = hi_any ? hi_id : std_id;
  end

  assign irq_sec_ctrl_o = irq_sec_q;

endmodule
