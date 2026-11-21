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
  `include "common_cells/registers.svh"
  localparam int unsigned PatternWidth = unsigned'($bits(pattern_t));
  localparam int unsigned RespCntWidth = Cfg.IndexLength + 32'd1;

  logic         busy_d, busy_q, switch_busy;
  logic         eoc_d, eoc_q;
  typedef enum logic [3:0] {
    WZEROUP, RZEROUP, WONEUP, RONEDOWN, WZERODOWN, RZERODOWN, BISTEND
  } bist_e;
  bist_e                           bist_d,      bist_q;
  logic                            update_bist;
  logic                            clear_cnt,   en_cnt, load_cnt, down_cnt, overflow_cnt;
  logic [Cfg.IndexLength-1:0]      data_cnt;
  logic [Cfg.SetAssociativity-1:0] bist_res_d,  bist_res_q;
  logic                            load_bist_res;
  logic [RespCntWidth-1:0]         resp_cnt_d,  resp_cnt_q;
  logic                            load_resp_cnt;

  assign bist_res_o = bist_res_q;

  always_comb begin
    busy_d        = busy_q;
    switch_busy   = 1'b0;
    bist_d        = bist_q;
    update_bist   = 1'b0;
    ready_o       = 1'b0;
    req_o         = 1'b0;
    we_o          = 1'b0;
    eoc_d         = eoc_q;
    clear_cnt     = 1'b0;
    en_cnt        = 1'b0;
    load_cnt      = 1'b0;
    data_cnt      = '0;
    down_cnt      = 1'b0;
    pattern_o     = pattern_t'{default: '0};
    bist_res_d    = bist_res_q;
    load_bist_res = 1'b0;
    resp_cnt_d    = resp_cnt_q;
    load_resp_cnt = 1'b0;

    if (busy_q) begin
      case (bist_q)
        WZEROUP: begin
          if (overflow_cnt) begin
            clear_cnt     = 1'b1;
            resp_cnt_d    = '0;
            load_resp_cnt = 1'b1;
            bist_d        = RZEROUP;
            update_bist   = 1'b1;
          end else begin
            req_o  = 1'b1;
            we_o   = 1'b1;
            en_cnt = 1'b1;
          end
        end

        RZEROUP: begin
          if (bist_res_valid_i) begin
            bist_res_d    = bist_res_q | ~bist_res_i;
            load_bist_res = 1'b1;
            resp_cnt_d    = resp_cnt_q + RespCntWidth'(1);
            load_resp_cnt = 1'b1;
          end
          if (overflow_cnt) begin
            if (resp_cnt_q[Cfg.IndexLength] && !bist_res_valid_i) begin
              clear_cnt     = 1'b1;
              resp_cnt_d    = '0;
              load_resp_cnt = 1'b1;
              bist_d        = WONEUP;
              update_bist   = 1'b1;
            end
          end else begin
            req_o  = 1'b1;
            en_cnt = 1'b1;
          end
        end

        WONEUP: begin
          if (overflow_cnt) begin
            load_cnt      = 1'b1;
            data_cnt      = '1;
            resp_cnt_d    = '0;
            load_resp_cnt = 1'b1;
            bist_d        = RONEDOWN;
            update_bist   = 1'b1;
          end else begin
            req_o     = 1'b1;
            we_o      = 1'b1;
            pattern_o = {PatternWidth{1'b1}};
            en_cnt    = 1'b1;
          end
        end

        RONEDOWN: begin
          pattern_o = {PatternWidth{1'b1}};
          if (bist_res_valid_i) begin
            bist_res_d    = bist_res_q | ~bist_res_i;
            load_bist_res = 1'b1;
            resp_cnt_d    = resp_cnt_q + RespCntWidth'(1);
            load_resp_cnt = 1'b1;
          end
          if (overflow_cnt) begin
            if (resp_cnt_q[Cfg.IndexLength] && !bist_res_valid_i) begin
              load_cnt      = 1'b1;
              data_cnt      = '1;
              resp_cnt_d    = '0;
              load_resp_cnt = 1'b1;
              bist_d        = WZERODOWN;
              update_bist   = 1'b1;
            end
          end else begin
            req_o    = 1'b1;
            en_cnt   = 1'b1;
            down_cnt = 1'b1;
          end
        end

        WZERODOWN: begin
          if (overflow_cnt) begin
            load_cnt      = 1'b1;
            data_cnt      = '1;
            resp_cnt_d    = '0;
            load_resp_cnt = 1'b1;
            bist_d        = RZERODOWN;
            update_bist   = 1'b1;
          end else begin
            req_o    = 1'b1;
            we_o     = 1'b1;
            en_cnt   = 1'b1;
            down_cnt = 1'b1;
          end
        end

        RZERODOWN: begin
          if (bist_res_valid_i) begin
            bist_res_d    = bist_res_q | ~bist_res_i;
            load_bist_res = 1'b1;
            resp_cnt_d    = resp_cnt_q + RespCntWidth'(1);
            load_resp_cnt = 1'b1;
          end
          if (overflow_cnt) begin
            if (resp_cnt_q[Cfg.IndexLength] && !bist_res_valid_i) begin
              clear_cnt     = 1'b1;
              resp_cnt_d    = '0;
              load_resp_cnt = 1'b1;
              bist_d        = BISTEND;
              update_bist   = 1'b1;
            end
          end else begin
            req_o    = 1'b1;
            en_cnt   = 1'b1;
            down_cnt = 1'b1;
          end
        end

        BISTEND: begin
          bist_d      = WZEROUP;
          update_bist = 1'b1;
          eoc_d       = 1'b1;
          busy_d      = 1'b0;
          switch_busy = 1'b1;
        end
        default: ;
      endcase
    end else begin
      ready_o = 1'b1;
      if (valid_i) begin
        busy_d        = 1'b1;
        switch_busy   = 1'b1;
        clear_cnt     = 1'b1;
        eoc_d         = 1'b0;
        bist_res_d    = '0;
        load_bist_res = 1'b1;
        resp_cnt_d    = '0;
        load_resp_cnt = 1'b1;
      end
    end
  end

  counter #(
    .WIDTH     ( Cfg.IndexLength )
  ) i_index_cnt (
    .clk_i     (        clk_i ),
    .rst_ni    (       rst_ni ),
    .clear_i   (    clear_cnt ),
    .en_i      (       en_cnt ),
    .load_i    (     load_cnt ),
    .down_i    (     down_cnt ),
    .d_i       (     data_cnt ),
    .q_o       (      index_o ),
    .overflow_o( overflow_cnt )
  );

  `FFLARN(busy_q,     busy_d,     switch_busy,   '0,      clk_i, rst_ni)
  `FFLARN(eoc_q,      eoc_d,      1'b1,          '0,      clk_i, rst_ni)
  `FFLARN(bist_q,     bist_d,     update_bist,   WZEROUP, clk_i, rst_ni)
  `FFLARN(bist_res_q, bist_res_d, load_bist_res, '0,      clk_i, rst_ni)
  `FFLARN(resp_cnt_q, resp_cnt_d, load_resp_cnt, '0,      clk_i, rst_ni)

  assign eoc_o = eoc_q;
endmodule
