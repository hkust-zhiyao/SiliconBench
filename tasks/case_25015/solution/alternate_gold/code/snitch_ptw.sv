// Copyright 2020 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

`include "common_cells/registers.svh"
`include "common_cells/assertions.svh"

module snitch_ptw import snitch_pkg::*; #(
  parameter int unsigned AddrWidth  = 64,
  parameter int unsigned DataWidth  = 64,
  parameter type         dreq_t     = logic,
  parameter type         drsp_t     = logic,
  parameter type         pa_t       = logic,
  parameter type         l0_pte_t   = logic,
  parameter type         pte_sv32_t = logic,
  parameter int unsigned PPNSize    = AddrWidth - PAGE_SHIFT
) (
  input  logic               clk_i,
  input  logic               rst_ni,
  input  logic [PPNSize-1:0] ppn_i,
  input  logic               valid_i,
  output logic               ready_o,
  input  va_t                va_i,
  output l0_pte_t            pte_o,
  output logic               is_4mega_o,
  output dreq_t              data_req_o,
  input  drsp_t              data_rsp_i
);

  localparam int unsigned PTESize       = AddrWidth > 34 ? 8 : 4;
  localparam int unsigned PTEAddrOffset = $clog2(PTESize);

  typedef enum logic [1:0] {
    ST_IDLE,
    ST_WAIT_L1,
    ST_REQ_L0,
    ST_DONE
  } ptw_state_e;

  ptw_state_e st_q, st_d;
  logic       at_l0_q, at_l0_d;
  l0_pte_t    pte_q, pte_d;
  logic       super_q, super_d;
  pte_sv32_t  mem_pte;

  assign mem_pte    = pte_sv32_t'(data_rsp_i.p.data[$size(pte_sv32_t)-1:0]);
  assign pte_o      = pte_q;
  assign is_4mega_o = super_q;

  always_comb begin
    automatic logic [PAGE_SHIFT-1:0] idx_bits;
    st_d       = st_q;
    at_l0_d    = at_l0_q;
    pte_d      = pte_q;
    super_d    = super_q;
    ready_o    = 1'b0;

    data_req_o.q.amo   = reqrsp_pkg::AMONone;
    data_req_o.q.data  = '0;
    data_req_o.q.write = 1'b0;
    data_req_o.q.strb  = '0;
    data_req_o.q.size  = $clog2(DataWidth/8);
    idx_bits           = $unsigned({va_i.vpn1, {{PTEAddrOffset}{1'b0}}});
    data_req_o.q.addr  = $unsigned({ppn_i, idx_bits});
    data_req_o.q_valid = 1'b0;
    data_req_o.p_ready = 1'b1;

    unique case (st_q)
      ST_IDLE: begin
        at_l0_d = 1'b0;
        data_req_o.q_valid = valid_i;
        if (valid_i && data_rsp_i.q_ready) begin
          st_d = ST_WAIT_L1;
        end
      end

      ST_REQ_L0: begin
        data_req_o.q_valid = 1'b1;
        idx_bits           = $unsigned({va_i.vpn0, {{PTEAddrOffset}{1'b0}}});
        data_req_o.q.addr  = $unsigned({pte_q.pa, idx_bits});
        if (data_rsp_i.q_ready) begin
          st_d = ST_WAIT_L1;
        end
      end

      ST_WAIT_L1: begin
        if (data_rsp_i.p_valid) begin
          pte_d.pa    = mem_pte.pa;
          pte_d.flags = '{d: mem_pte.d, a: mem_pte.a, u: mem_pte.u, x: mem_pte.x, w: mem_pte.w, r: mem_pte.r};
          super_d     = 1'b0;

          if (data_rsp_i.p.error || !mem_pte.v || (!mem_pte.r && mem_pte.w)) begin
            pte_d.flags = '0;
            super_d     = 1'b0;
            st_d        = ST_DONE;
          end else if (mem_pte.r || mem_pte.x) begin
            if (!at_l0_q) begin
              if (mem_pte.pa.ppn0 != '0) begin
                pte_d.flags = '0;
                super_d     = 1'b0;
              end else begin
                super_d     = 1'b1;
              end
            end
            st_d = ST_DONE;
          end else begin
            // Non-leaf pointer: allowed at L1 (!at_l0_q), fault at L0 (at_l0_q)
            if (!at_l0_q) begin
              at_l0_d = 1'b1;
              st_d    = ST_REQ_L0;
            end else begin
              pte_d.flags = '0;
              super_d     = 1'b0;
              st_d        = ST_DONE;
            end
          end
        end
      end

      ST_DONE: begin
        ready_o = 1'b1;
        st_d    = ST_IDLE;
      end

      default: st_d = ST_IDLE;
    endcase
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      st_q    <= ST_IDLE;
      at_l0_q <= 1'b0;
      pte_q   <= '0;
      super_q <= 1'b0;
    end else begin
      st_q    <= st_d;
      at_l0_q <= at_l0_d;
      pte_q   <= pte_d;
      super_q <= super_d;
    end
  end

endmodule
