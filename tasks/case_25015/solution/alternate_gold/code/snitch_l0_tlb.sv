// Copyright 2020 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

`include "common_cells/registers.svh"

module snitch_l0_tlb import snitch_pkg::*; #(
  parameter int unsigned NrEntries = 1,
  parameter type         pa_t      = logic,
  parameter type         l0_pte_t  = logic
) (
  input  logic      clk_i,
  input  logic      rst_i,
  input  logic      flush_i,
  input  priv_lvl_t priv_lvl_i,
  input  logic      valid_i,
  output logic      ready_o,
  input  va_t       va_i,
  input  logic      read_i,
  input  logic      write_i,
  input  logic      execute_i,
  output logic      page_fault_o,
  output pa_t       pa_o,
  output logic      valid_o,
  input  logic      ready_i,
  output va_t       va_o,
  input  l0_pte_t   pte_i,
  input  logic      is_4mega_i
);

  typedef struct packed {
    va_t  va;
    logic is_4mega;
  } tag_t;

  tag_t [NrEntries-1:0]    tag_d, tag_q;
  l0_pte_t [NrEntries-1:0] pte_d, pte_q;
  logic [NrEntries-1:0]    tag_valid_d, tag_valid_q;
  logic [NrEntries-1:0]    hit, hit_4m;
  l0_pte_t                 pte_sel;
  logic                    is_4mega;
  logic                    miss_d, miss_q, refill_d, refill_q;
  localparam int unsigned  PtrW = (NrEntries > 1) ? $clog2(NrEntries) : 1;
  logic [PtrW-1:0]         rr_ptr_d, rr_ptr_q;

  `FFAR(tag_valid_q, tag_valid_d, '0, clk_i, rst_i)
  `FFAR(tag_q, tag_d, '0, clk_i, rst_i)
  `FFAR(pte_q, pte_d, '0, clk_i, rst_i)
  `FFAR(miss_q, miss_d, 1'b0, clk_i, rst_i)
  `FFAR(refill_q, refill_d, 1'b0, clk_i, rst_i)

  for (genvar k = 0; k < NrEntries; k++) begin : g_match
    assign hit[k] = tag_valid_q[k] && (va_i.vpn1 == tag_q[k].va.vpn1)
                  && (tag_q[k].is_4mega || (va_i.vpn0 == tag_q[k].va.vpn0));
    assign hit_4m[k] = hit[k] && tag_q[k].is_4mega;
  end

  assign ready_o  = |hit;
  assign is_4mega = |hit_4m;

  always_comb begin
    pte_sel = '0;
    for (int k = 0; k < NrEntries; k++) begin
      if (hit[k]) pte_sel |= pte_q[k];
    end
  end

  logic perm_ok;
  always_comb begin
    perm_ok = pte_sel.flags.a;
    if (execute_i && !pte_sel.flags.x) perm_ok = 1'b0;
    if (read_i    && !pte_sel.flags.r) perm_ok = 1'b0;
    if (write_i   && !(pte_sel.flags.w && pte_sel.flags.d)) perm_ok = 1'b0;
    if (priv_lvl_i == PrivLvlU) begin
      if (!pte_sel.flags.u) perm_ok = 1'b0;
    end else if (priv_lvl_i == PrivLvlS) begin
      if (pte_sel.flags.u) perm_ok = 1'b0;
    end else begin
      perm_ok = 1'b0;
    end
  end

  assign page_fault_o = ~perm_ok;
  assign pa_o         = {pte_sel.pa.ppn1, is_4mega ? va_i.vpn0 : pte_sel.pa.ppn0};

  assign miss_d   = valid_i && !ready_o;
  assign valid_o  = miss_q && refill_q;
  assign va_o     = va_i;
  assign refill_d = !(valid_o && ready_i);

  always_comb begin
    tag_valid_d = tag_valid_q;
    tag_d       = tag_q;
    pte_d       = pte_q;
    if (valid_o && ready_i) begin
      pte_d[rr_ptr_q]       = pte_i;
      tag_d[rr_ptr_q].va    = va_i;
      tag_d[rr_ptr_q].is_4mega = is_4mega_i;
      tag_valid_d[rr_ptr_q] = 1'b1;
    end
    if (flush_i) tag_valid_d = '0;
  end

  if (NrEntries > 1) begin : g_rr
    `FFAR(rr_ptr_q, rr_ptr_d, '0, clk_i, rst_i)
    assign rr_ptr_d = (valid_o && ready_i)
                    ? ((rr_ptr_q == PtrW'(NrEntries - 1)) ? '0 : (rr_ptr_q + 1'b1))
                    : rr_ptr_q;
  end else begin : g_single
    assign rr_ptr_q = '0;
    assign rr_ptr_d = '0;
  end

endmodule
