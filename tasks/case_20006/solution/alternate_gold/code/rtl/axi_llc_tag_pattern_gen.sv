// Copyright 2022 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

module axi_llc_tag_pattern_gen #(
  parameter axi_llc_pkg::llc_cfg_t Cfg = axi_llc_pkg::llc_cfg_t'{default: '0},
  parameter type pattern_t = logic,
  parameter type way_ind_t = logic,
  parameter type index_t   = logic
) (
  input  logic     clk_i,
  input  logic     rst_ni,
  input  logic     valid_i,
  output logic     ready_o,
  output index_t   index_o,
  output pattern_t pattern_o,
  output logic     req_o,
  output logic     we_o,
  input  way_ind_t bist_res_i,
  input  logic     bist_res_valid_i,
  output way_ind_t bist_res_o,
  output logic     eoc_o
);
  localparam int unsigned PatW = unsigned'($bits(pattern_t));
  localparam int unsigned NumL = 32'd1 << Cfg.IndexLength;

  typedef enum logic [2:0] {
    ST_IDLE, ST_WZ_UP, ST_RZ_UP, ST_WO_UP, ST_RO_DN, ST_WZ_DN, ST_RZ_DN, ST_DONE
  } st_e;

  st_e                             st_q, st_d;
  logic [Cfg.IndexLength:0]        req_step_q, req_step_d;
  logic [7:0]                      inflight_q, inflight_d;
  logic [Cfg.SetAssociativity-1:0] fail_q, fail_d;
  logic                            eoc_q, eoc_d;
  logic                            issue_rd;

  assign bist_res_o = fail_q;
  assign eoc_o      = eoc_q;

  always_comb begin
    st_d       = st_q;
    req_step_d = req_step_q;
    inflight_d = inflight_q;
    fail_d     = fail_q;
    eoc_d      = eoc_q;
    issue_rd   = 1'b0;
    ready_o    = 1'b0;
    req_o      = 1'b0;
    we_o       = 1'b0;
    index_o    = '0;
    pattern_o  = pattern_t'{default: '0};

    case (st_q)
      ST_IDLE: begin
        ready_o = 1'b1;
        if (valid_i) begin
          st_d       = ST_WZ_UP;
          req_step_d = '0;
          inflight_d = 8'd0;
          fail_d     = '0;
          eoc_d      = 1'b0;
        end
      end

      ST_WZ_UP: begin
        if (req_step_q == NumL[Cfg.IndexLength:0]) begin
          st_d       = ST_RZ_UP;
          req_step_d = '0;
          inflight_d = 8'd0;
        end else begin
          req_o      = 1'b1;
          we_o       = 1'b1;
          index_o    = req_step_q[Cfg.IndexLength-1:0];
          req_step_d = req_step_q + 1'b1;
        end
      end

      ST_RZ_UP: begin
        issue_rd = (req_step_q < NumL[Cfg.IndexLength:0]);
        if (issue_rd) begin
          req_o      = 1'b1;
          index_o    = req_step_q[Cfg.IndexLength-1:0];
          req_step_d = req_step_q + 1'b1;
        end
        if (bist_res_valid_i) begin
          fail_d = fail_q | ~bist_res_i;
        end
        inflight_d = inflight_q + {7'd0, issue_rd} - {7'd0, bist_res_valid_i};
        if (!issue_rd && (inflight_q == 8'd0) && !bist_res_valid_i) begin
          st_d       = ST_WO_UP;
          req_step_d = '0;
        end
      end

      ST_WO_UP: begin
        pattern_o = {PatW{1'b1}};
        if (req_step_q == NumL[Cfg.IndexLength:0]) begin
          st_d       = ST_RO_DN;
          req_step_d = '0;
          inflight_d = 8'd0;
        end else begin
          req_o      = 1'b1;
          we_o       = 1'b1;
          index_o    = req_step_q[Cfg.IndexLength-1:0];
          req_step_d = req_step_q + 1'b1;
        end
      end

      ST_RO_DN: begin
        pattern_o = {PatW{1'b1}};
        issue_rd  = (req_step_q < NumL[Cfg.IndexLength:0]);
        if (issue_rd) begin
          req_o      = 1'b1;
          index_o    = ~req_step_q[Cfg.IndexLength-1:0];
          req_step_d = req_step_q + 1'b1;
        end
        if (bist_res_valid_i) begin
          fail_d = fail_q | ~bist_res_i;
        end
        inflight_d = inflight_q + {7'd0, issue_rd} - {7'd0, bist_res_valid_i};
        if (!issue_rd && (inflight_q == 8'd0) && !bist_res_valid_i) begin
          st_d       = ST_WZ_DN;
          req_step_d = '0;
        end
      end

      ST_WZ_DN: begin
        if (req_step_q == NumL[Cfg.IndexLength:0]) begin
          st_d       = ST_RZ_DN;
          req_step_d = '0;
          inflight_d = 8'd0;
        end else begin
          req_o      = 1'b1;
          we_o       = 1'b1;
          index_o    = ~req_step_q[Cfg.IndexLength-1:0];
          req_step_d = req_step_q + 1'b1;
        end
      end

      ST_RZ_DN: begin
        issue_rd = (req_step_q < NumL[Cfg.IndexLength:0]);
        if (issue_rd) begin
          req_o      = 1'b1;
          index_o    = ~req_step_q[Cfg.IndexLength-1:0];
          req_step_d = req_step_q + 1'b1;
        end
        if (bist_res_valid_i) begin
          fail_d = fail_q | ~bist_res_i;
        end
        inflight_d = inflight_q + {7'd0, issue_rd} - {7'd0, bist_res_valid_i};
        if (!issue_rd && (inflight_q == 8'd0) && !bist_res_valid_i) begin
          st_d       = ST_DONE;
          req_step_d = '0;
        end
      end

      ST_DONE: begin
        eoc_d = 1'b1;
        st_d  = ST_IDLE;
      end
      default: st_d = ST_IDLE;
    endcase
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      st_q       <= ST_IDLE;
      req_step_q <= '0;
      inflight_q <= '0;
      fail_q     <= '0;
      eoc_q      <= 1'b0;
    end else begin
      st_q       <= st_d;
      req_step_q <= req_step_d;
      inflight_q <= inflight_d;
      fail_q     <= fail_d;
      eoc_q      <= eoc_d;
    end
  end
endmodule
