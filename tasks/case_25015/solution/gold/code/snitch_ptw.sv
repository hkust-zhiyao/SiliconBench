// Copyright 2020 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Author: Florian Zaruba <zarubaf@iis.ee.ethz.ch>

`include "common_cells/registers.svh"
`include "common_cells/assertions.svh"

/// Page table walker (PTW) for RISC-V Sv32 address translation.
module snitch_ptw import snitch_pkg::*; #(
  parameter int unsigned AddrWidth = 64,
  parameter int unsigned DataWidth = 64,
  parameter type dreq_t = logic,
  parameter type drsp_t = logic,
  parameter type pa_t = logic,
  parameter type l0_pte_t = logic,
  parameter type pte_sv32_t = logic,
  parameter int unsigned PPNSize = AddrWidth - PAGE_SHIFT
) (
  input  logic                clk_i,
  input  logic                rst_ni,
  input  logic [PPNSize-1:0]  ppn_i,
  input  logic                valid_i,
  output logic                ready_o,
  input  va_t                 va_i,
  output l0_pte_t             pte_o,
  output logic                is_4mega_o,
  output dreq_t               data_req_o,
  input  drsp_t               data_rsp_i
);

  localparam int unsigned PTESize = AddrWidth > 34 ? 8 : 4;
  localparam int unsigned PTEAddrOffset = $clog2(PTESize);

  typedef enum logic [1:0] {
    Idle,
    LookupPTE,
    WaitPTE,
    ReturnPTE
  } state_e;
  state_e state_q, state_d;

  logic [1:0] lvl_d, lvl_q;

  `FFARN(state_q, state_d, Idle, clk_i, rst_ni)

  pte_sv32_t pte;
  l0_pte_t pte_d, pte_q;
  logic pte_ld;
  logic is_4mega_d, is_4mega_q;

  assign pte = pte_sv32_t'(data_rsp_i.p.data[$size(pte_sv32_t)-1:0]);
  `FFLARN(pte_q, pte_d, pte_ld, '0, clk_i, rst_ni)
  `FFARN(is_4mega_q, is_4mega_d, 1'b0, clk_i, rst_ni)
  `FFARN(lvl_q, lvl_d, '0, clk_i, rst_ni)

  assign pte_o = pte_q;
  assign is_4mega_o = is_4mega_q;

  always_comb begin
    automatic logic [PAGE_SHIFT-1:0] page_table_index;
    data_req_o.q.amo = reqrsp_pkg::AMONone;
    data_req_o.q.data = '0;
    data_req_o.q.write = 1'b0;
    data_req_o.q.strb = '0;

    lvl_d = lvl_q;
    state_d = state_q;

    page_table_index = $unsigned({va_i.vpn1, {{PTEAddrOffset}{1'b0}}});
    data_req_o.q.addr = $unsigned({ppn_i, page_table_index});
    data_req_o.q.size = $clog2(DataWidth/8);
    data_req_o.q_valid = 1'b0;
    data_req_o.p_ready = 1'b1;

    ready_o = 1'b0;
    pte_ld  = 1'b0;
    pte_d.pa = pte.pa;
    pte_d.flags = '{
      d: pte.d,
      a: pte.a,
      u: pte.u,
      x: pte.x,
      w: pte.w,
      r: pte.r
    };
    is_4mega_d = is_4mega_q;

    unique case (state_q)
      Idle: begin
        lvl_d = '0;
        data_req_o.q_valid = valid_i;
        if (valid_i && data_rsp_i.q_ready) begin
          state_d = WaitPTE;
        end
      end

      LookupPTE: begin
        if (lvl_q < 2'd2) begin
          data_req_o.q_valid = 1'b1;
          page_table_index = $unsigned({va_i.vpn0, {{PTEAddrOffset}{1'b0}}});
          data_req_o.q.addr = $unsigned({pte_q.pa, page_table_index});
          if (data_rsp_i.q_ready) state_d = WaitPTE;
        end else begin
          pte_d = pte_q;
          pte_d.flags = '0;
          pte_ld = 1'b1;
          is_4mega_d = 1'b0;
          state_d = ReturnPTE;
        end
      end

      WaitPTE: begin
        if (data_rsp_i.p_valid) begin
          pte_ld = 1'b1;
          is_4mega_d = 1'b0;
          lvl_d = lvl_q + 2'd1;
          if (data_rsp_i.p.error || pte.v == 1'b0 || (pte.r == 1'b0 && pte.w == 1'b1)) begin
            pte_d.flags = '0;
            is_4mega_d = 1'b0;
            state_d = ReturnPTE;
          end else if (pte.r == 1'b1 || pte.x == 1'b1) begin
            if (lvl_q < 2'd1) begin
              if (pte_d.pa.ppn0 != '0) begin
                pte_d.flags = '0;
                is_4mega_d = 1'b0;
              end else begin
                is_4mega_d = 1'b1;
              end
            end
            state_d = ReturnPTE;
          end else begin
            state_d = LookupPTE;
          end
        end
      end

      ReturnPTE: begin
        ready_o = 1'b1;
        state_d = Idle;
      end

      default: state_d = Idle;
    endcase
  end

endmodule
