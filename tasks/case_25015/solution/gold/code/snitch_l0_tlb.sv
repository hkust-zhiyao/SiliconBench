// Copyright 2020 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

`include "common_cells/registers.svh"
// Author: Florian Zaruba <zarubaf@iis.ee.ethz.ch>

// MMU w/ L0 TLB
module snitch_l0_tlb import snitch_pkg::*; #(
  parameter int unsigned NrEntries = 1,
  parameter type         pa_t      = logic,
  parameter type         l0_pte_t  = logic
) (
  input  logic clk_i,
  input  logic rst_i,
  /// Invalidate all TLB entries.
  input  logic flush_i,
  /// Request side.
  /// Privilege level of the access.
  input  priv_lvl_t priv_lvl_i,
  /// Translation request valid.
  input  logic valid_i,
  /// Translation request was accepted.
  output logic ready_o,
  /// Address to translate.
  input  va_t  va_i,
  /// Translation request is a read.
  input  logic read_i,
  /// Translation request is a write.
  input  logic write_i,
  /// Translation request is for instr a fetch/execute
  input  logic execute_i,
  /// Translation caused a page fault.
  output logic page_fault_o,
  /// Translated physical Address
  output pa_t  pa_o,

  /// Refill side (to L1 TLB)
  output logic valid_o,
  input  logic ready_i,
  /// Virtual address to be refilled
  output va_t  va_o,
  /// Page table entry from refill
  input  l0_pte_t pte_i,
  /// Translation is 4 mega.
  input  logic is_4mega_i
);

  typedef struct packed {
    va_t  va;
    logic is_4mega;
  } tag_t;

  tag_t [NrEntries-1:0] tag_d, tag_q;
  logic [NrEntries-1:0] is_4mega_exp;
  logic is_4mega;
  logic [NrEntries-1:0] tag_valid_d, tag_valid_q;
  logic [$clog2(NrEntries+1)-1:0] evict_d, evict_q;

  l0_pte_t [NrEntries-1:0] pte_q, pte_d;
  l0_pte_t pte;

  `FFAR(tag_valid_q, tag_valid_d, '0, clk_i, rst_i)
  `FFAR(tag_q, tag_d, '0, clk_i, rst_i)
  `FFAR(pte_q, pte_d, '0, clk_i, rst_i)

  logic [NrEntries-1:0] hit;
  logic miss_d, miss_q;
  logic refill_d, refill_q;

  `FFAR(miss_q, miss_d, '0, clk_i, rst_i)
  `FFAR(refill_q, refill_d, '0, clk_i, rst_i)

  for (genvar i = 0; i < NrEntries; i++) begin : gen_tag_cmp
    assign hit[i] = tag_valid_q[i]
      & (va_i.vpn1 == tag_q[i].va.vpn1 & (tag_q[i].is_4mega | (va_i.vpn0 == tag_q[i].va.vpn0)));
    assign is_4mega_exp[i] = tag_q[i].is_4mega & hit[i];
  end
  assign is_4mega = |is_4mega_exp;

  localparam int unsigned L0PteSize = $bits(l0_pte_t);
  /* verilator lint_off ALWCOMBORDER */
  always_comb begin
    pte = '0;
    for (int i = 0; i < NrEntries; i++) pte |= (pte_q[i] & {{L0PteSize}{hit[i]}});
  end
  /* verilator lint_on ALWCOMBORDER */

  assign ready_o = |hit;

  logic access_allowed;
  assign access_allowed = (pte.flags.x & execute_i | ~execute_i)
                        & (pte.flags.w & write_i | ~write_i)
                        & (pte.flags.r & read_i | ~read_i)
                        &  pte.flags.a
                        & (pte.flags.d & write_i | ~write_i)
                        & (pte.flags.u & (priv_lvl_i == PrivLvlU) | (priv_lvl_i == PrivLvlS))
                        & (~pte.flags.u & (priv_lvl_i == PrivLvlS) | (priv_lvl_i == PrivLvlU));

  assign page_fault_o = ~access_allowed;

  assign pa_o = {pte.pa.ppn1, (pte.pa.ppn0 & {10{~is_4mega}}) | (va_i.vpn0 & {10{is_4mega}})};

  assign miss_d = valid_i & ~(|hit);
  assign valid_o = miss_q & refill_q;
  assign va_o = va_i;

  always_comb begin
    refill_d = 1'b1;
    if (valid_o && ready_i) refill_d = 1'b0;
  end

  always_comb begin
    tag_valid_d = tag_valid_q;
    tag_d = tag_q;
    pte_d = pte_q;

    if (valid_o && ready_i) begin
      pte_d[evict_q] = pte_i;
      tag_d[evict_q].va = va_i;
      tag_d[evict_q].is_4mega = is_4mega_i;
      tag_valid_d[evict_q] = 1'b1;
    end

    if (flush_i) tag_valid_d = '0;
  end

  if (NrEntries > 1) begin : gen_evict_counter
    `FFAR(evict_q, evict_d, '0, clk_i, rst_i)
    always_comb begin
      evict_d = evict_q;
      if (valid_o && ready_i) begin
        if (evict_q == NrEntries - 1) evict_d = '0;
        else evict_d = evict_q + 1'b1;
      end
    end
  end else begin : gen_no_evict_counter
    assign evict_q = '0;
    assign evict_d = '0;
  end

endmodule
