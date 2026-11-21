// Copyright 2022 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

module axi_llc_miss_counters #(
  parameter axi_llc_pkg::llc_cfg_t Cfg = axi_llc_pkg::llc_cfg_t'{default: '0},
  parameter type cnt_t  = logic,
  parameter int unsigned AxiIdLookupBits = 32'd0
) (
  input  logic clk_i,
  input  logic rst_ni,
  input  cnt_t cnt_up_i,
  input  cnt_t cnt_down_i,
  output logic to_miss_o,
  output logic stall_o
);
  localparam int unsigned NoCounters = 32'd1 << AxiIdLookupBits;
  localparam int unsigned IdW        = $bits(cnt_up_i.id);
  localparam int unsigned McntW      = axi_llc_pkg::MissCntWidth + 32'd1;
  localparam int unsigned WcntW      = axi_llc_pkg::MissCntMaxWWidth + 32'd1;
  localparam logic [McntW-1:0] MaxM  = McntW'(1) << axi_llc_pkg::MissCntWidth;
  localparam logic [WcntW-1:0] MaxW  = WcntW'(1) << axi_llc_pkg::MissCntMaxWWidth;

  logic [NoCounters-1:0][McntW-1:0] mcnt_q, mcnt_d;
  logic [WcntW-1:0]                 wcnt_q, wcnt_d;
  logic [NoCounters-1:0]            up_sel, dn_sel, m_full;
  logic                             w_full;

  for (genvar g = 0; unsigned'(g) < NoCounters; g++) begin : gen_sel
    if (AxiIdLookupBits == 32'd0) begin : gen_b0
      assign up_sel[g] = 1'b1;
      assign dn_sel[g] = 1'b1;
    end else if (AxiIdLookupBits >= IdW) begin : gen_bfull
      assign up_sel[g] = (unsigned'(cnt_up_i.id) == unsigned'(g));
      assign dn_sel[g] = (unsigned'(cnt_down_i.id) == unsigned'(g));
    end else begin : gen_bpart
      assign up_sel[g] = (cnt_up_i.id[AxiIdLookupBits-1:0] == AxiIdLookupBits'(g));
      assign dn_sel[g] = (cnt_down_i.id[AxiIdLookupBits-1:0] == AxiIdLookupBits'(g));
    end
    assign m_full[g] = (mcnt_q[g] == MaxM);
  end

  assign w_full  = (wcnt_q == MaxW);
  assign stall_o = (|m_full) || w_full;

  always_comb begin
    mcnt_d    = mcnt_q;
    wcnt_d    = wcnt_q;
    to_miss_o = 1'b0;

    for (int unsigned k = 0; k < NoCounters; k++) begin
      logic do_up, do_dn;
      do_up = up_sel[k] && cnt_up_i.valid;
      do_dn = dn_sel[k] && cnt_down_i.valid;
      if (do_up && !do_dn && (mcnt_q[k] < MaxM)) begin
        mcnt_d[k] = mcnt_q[k] + McntW'(1);
      end else if (!do_up && do_dn && (mcnt_q[k] != '0)) begin
        mcnt_d[k] = mcnt_q[k] - McntW'(1);
      end
      if (up_sel[k]) begin
        to_miss_o = (mcnt_q[k] != '0) || (cnt_up_i.rw && (wcnt_q != '0));
      end
    end

    if ((cnt_up_i.valid && cnt_up_i.rw) && !(cnt_down_i.valid && cnt_down_i.rw)) begin
      if (wcnt_q < MaxW) wcnt_d = wcnt_q + WcntW'(1);
    end else if (!(cnt_up_i.valid && cnt_up_i.rw) && (cnt_down_i.valid && cnt_down_i.rw)) begin
      if (wcnt_q != '0) wcnt_d = wcnt_q - WcntW'(1);
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      mcnt_q <= '0;
      wcnt_q <= '0;
    end else begin
      mcnt_q <= mcnt_d;
      wcnt_q <= wcnt_d;
    end
  end
endmodule
