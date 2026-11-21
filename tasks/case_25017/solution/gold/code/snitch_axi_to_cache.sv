// Copyright 2021 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

`include "common_cells/registers.svh"

/// Convert from AXI to Cache requests and reconstruct response beats on the way back.
module snitch_axi_to_cache #(
  parameter int unsigned MaxTrans           = 32'd0,
  parameter type         req_t              = logic,
  parameter type         resp_t             = logic,
  parameter snitch_icache_pkg::config_t CFG = '0
)(
  input  logic                         clk_i,
  input  logic                         rst_ni,
  output logic [CFG.FETCH_AW-1:0]      req_addr_o,
  output logic [CFG.ID_WIDTH_REQ-1:0]  req_id_o,
  output logic                         req_valid_o,
  input  logic                         req_ready_i,
  input  logic [CFG.LINE_WIDTH-1:0]    rsp_data_i,
  input  logic                         rsp_error_i,
  input  logic [CFG.ID_WIDTH_RESP-1:0] rsp_id_i,
  input  logic                         rsp_valid_i,
  output logic                         rsp_ready_o,
  input  req_t                         slv_req_i,
  output resp_t                        slv_rsp_o
);

  import cf_math_pkg::idx_width;

  localparam int unsigned WordOffset = idx_width(CFG.LINE_WIDTH/CFG.FETCH_DW);
  localparam int unsigned ShiftBits  = (CFG.LINE_WIDTH > CFG.FETCH_DW) ?
                                       $clog2(CFG.LINE_WIDTH/CFG.FETCH_DW) : 0;

  typedef logic [WordOffset-1:0]       offset_t;
  typedef logic [CFG.ID_WIDTH_REQ-1:0] id_t;
  typedef struct packed {
    logic [CFG.FETCH_AW-1:0]     addr;
    logic [CFG.ID_WIDTH_REQ-1:0] id;
    axi_pkg::len_t               len;
    axi_pkg::burst_t             burst;
  } chan_t;

  chan_t         ax_d, ax_q, ax_o;
  offset_t       ar_offset;
  axi_pkg::len_t ar_len;
  logic          cnt_alloc_req, cnt_alloc_gnt;

  id_t           rsp_id;
  logic          r_cnt_req, r_cnt_gnt;
  logic          r_cnt_len_dec, r_cnt_offset_inc;
  offset_t       r_cnt_offset, r_offset;
  axi_pkg::len_t r_cnt_len;

  assign slv_rsp_o.aw_ready = 1'b0;
  assign slv_rsp_o.w_ready  = 1'b0;
  assign slv_rsp_o.b_valid  = 1'b0;
  assign slv_rsp_o.b        = '0;

  assign ar_offset = slv_req_i.ar.addr[$clog2(CFG.FETCH_DW/8)+:WordOffset];
  always_comb begin
    if (CFG.LINE_WIDTH > CFG.FETCH_DW) begin
      automatic logic [10:0] total_beats = 11'(slv_req_i.ar.len) + 11'(ar_offset);
      ar_len = axi_pkg::len_t'(total_beats >> ShiftBits);
    end else begin
      ar_len = slv_req_i.ar.len;
    end
  end

  axi_burst_splitter_table #(
    .MaxTrans ( MaxTrans         ),
    .IdWidth  ( CFG.ID_WIDTH_REQ ),
    .offset_t ( offset_t         )
  ) i_axi_burst_splitter_table (
    .clk_i,
    .rst_ni,
    .alloc_id_i       ( slv_req_i.ar.id  ),
    .alloc_len_i      ( slv_req_i.ar.len ),
    .alloc_offset_i   ( ar_offset        ),
    .alloc_req_i      ( cnt_alloc_req    ),
    .alloc_gnt_o      ( cnt_alloc_gnt    ),
    .cnt_id_i         ( rsp_id           ),
    .cnt_len_o        ( r_cnt_len        ),
    .cnt_offset_o     ( r_cnt_offset     ),
    .cnt_set_err_i    ( 1'b0             ),
    .cnt_err_o        (                  ),
    .cnt_len_dec_i    ( r_cnt_len_dec    ),
    .cnt_offset_inc_i ( r_cnt_offset_inc ),
    .cnt_req_i        ( r_cnt_req        ),
    .cnt_gnt_o        ( r_cnt_gnt        )
  );

  assign req_addr_o = ax_o.addr;
  assign req_id_o   = ax_o.id;

  typedef enum logic {Idle, Busy} ar_state_e;
  ar_state_e ar_state_d, ar_state_q;
  always_comb begin
    cnt_alloc_req      = 1'b0;
    ax_d               = ax_q;
    ar_state_d         = ar_state_q;
    ax_o               = '0;
    req_valid_o        = 1'b0;
    slv_rsp_o.ar_ready = 1'b0;
    unique case (ar_state_q)
      Idle: begin
        if (slv_req_i.ar_valid && cnt_alloc_gnt) begin
          if (ar_len == '0) begin
            ax_o.addr   = (slv_req_i.ar.addr >> CFG.LINE_ALIGN) << CFG.LINE_ALIGN;
            ax_o.id     = slv_req_i.ar.id;
            ax_o.len    = ar_len;
            req_valid_o = 1'b1;
            if (req_ready_i) begin
              cnt_alloc_req      = 1'b1;
              slv_rsp_o.ar_ready = 1'b1;
            end
          end else begin
            ax_d.addr          = (slv_req_i.ar.addr >> CFG.LINE_ALIGN) << CFG.LINE_ALIGN;
            ax_d.id            = slv_req_i.ar.id;
            ax_d.len           = ar_len;
            ax_d.burst         = slv_req_i.ar.burst;
            cnt_alloc_req      = 1'b1;
            slv_rsp_o.ar_ready = 1'b1;
            ax_o               = ax_d;
            ax_o.len           = '0;
            req_valid_o        = 1'b1;
            if (req_ready_i) begin
              ax_d.len--;
              if (ax_d.burst == axi_pkg::BURST_INCR) begin
                ax_d.addr += CFG.LINE_WIDTH/8;
              end
            end
            ar_state_d = Busy;
          end
        end
      end
      Busy: begin
        ax_o        = ax_q;
        ax_o.len    = '0;
        req_valid_o = 1'b1;
        if (req_ready_i) begin
          if (ax_q.len == '0) begin
            ar_state_d = Idle;
          end else begin
            ax_d.len--;
            if (ax_q.burst == axi_pkg::BURST_INCR) begin
              ax_d.addr += CFG.LINE_WIDTH/8;
            end
          end
        end
      end
      default: ;
    endcase
  end

  `FF(ax_q, ax_d, '0, clk_i, rst_ni)
  `FF(ar_state_q, ar_state_d, Idle, clk_i, rst_ni)
  typedef struct packed {
    logic [CFG.LINE_WIDTH-1:0]    data;
    logic                         error;
    logic [CFG.ID_WIDTH_RESP-1:0] id;
  } rsp_in_t;

  logic rsp_valid_q, rsp_ready_q;
  rsp_in_t rsp_in_d, rsp_in_q;

  assign rsp_in_d.data  = rsp_data_i;
  assign rsp_in_d.error = rsp_error_i;
  assign rsp_in_d.id    = rsp_id_i;

  spill_register #(
    .T      ( rsp_in_t ),
    .Bypass ( 1'b0     )
  ) i_cut_rsp_in (
    .clk_i   ( clk_i       ),
    .rst_ni  ( rst_ni      ),
    .valid_i ( rsp_valid_i ),
    .ready_o ( rsp_ready_o ),
    .data_i  ( rsp_in_d    ),
    .valid_o ( rsp_valid_q ),
    .ready_i ( rsp_ready_q ),
    .data_o  ( rsp_in_q    )
  );

  logic rsp_valid, rsp_ready;
  logic rsp_id_onehot, rsp_id_empty;
  logic [CFG.ID_WIDTH_RESP-1:0] rsp_id_mask, rsp_id_masked;

  assign rsp_ready_q   = (rsp_id_onehot | rsp_id_empty) & rsp_ready;
  assign rsp_valid     = rsp_valid_q;
  assign rsp_id_masked = rsp_in_q.id & ~rsp_id_mask;

  lzc #(
    .WIDTH ( CFG.ID_WIDTH_RESP ),
    .MODE  ( 0                 )
  ) i_lzc (
    .in_i    ( rsp_id_masked ),
    .cnt_o   ( rsp_id        ),
    .empty_o ( rsp_id_empty  )
  );

  cc_onehot #(
    .Width ( CFG.ID_WIDTH_RESP )
  ) i_onehot (
    .d_i         ( rsp_id_masked ),
    .is_onehot_o ( rsp_id_onehot )
  );

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      rsp_id_mask <= '0;
    end else begin
      if (rsp_valid && rsp_ready) begin
        rsp_id_mask <= rsp_id_mask | (1 << rsp_id);
      end
      if (rsp_valid_q && rsp_ready_q) begin
        rsp_id_mask <= '0;
      end
    end
  end

  logic [CFG.FETCH_DW-1:0] r_data;
  assign r_offset = (CFG.LINE_WIDTH > CFG.FETCH_DW) ? r_cnt_offset : '1;
  assign r_data   = (CFG.LINE_WIDTH > CFG.FETCH_DW) ?
                    (rsp_in_q.data >> (r_offset * CFG.FETCH_DW)) : rsp_in_q.data;

  always_comb begin
    r_cnt_len_dec     = 1'b0;
    r_cnt_offset_inc  = 1'b0;
    r_cnt_req         = 1'b0;
    rsp_ready         = 1'b0;
    slv_rsp_o.r       = '0;
    slv_rsp_o.r.id    = rsp_id;
    slv_rsp_o.r.data  = r_data;
    slv_rsp_o.r.resp  = rsp_in_q.error ? axi_pkg::RESP_SLVERR : axi_pkg::RESP_OKAY;
    slv_rsp_o.r.user  = '0;
    slv_rsp_o.r.last  = 1'b0;
    slv_rsp_o.r_valid = 1'b0;

    if (rsp_valid) begin
      if (rsp_id_empty) begin
        rsp_ready = 1'b1;
      end else begin
        r_cnt_req = 1'b1;
        if (r_cnt_gnt) begin
          automatic logic beat_last = (r_cnt_len == 8'd0);
          slv_rsp_o.r.last  = beat_last;
          slv_rsp_o.r_valid = 1'b1;
          if (slv_req_i.r_ready) begin
            r_cnt_len_dec    = 1'b1;
            r_cnt_offset_inc = 1'b1;
            if (r_offset == '1 || beat_last) begin
              rsp_ready = 1'b1;
            end
          end
        end
      end
    end
  end

endmodule


module axi_burst_splitter_table #(
  parameter int unsigned MaxTrans = 0,
  parameter int unsigned IdWidth  = 0,
  parameter type         offset_t = logic,
  parameter type         id_t     = logic [IdWidth-1:0]
) (
  input  logic          clk_i,
  input  logic          rst_ni,
  input  id_t           alloc_id_i,
  input  axi_pkg::len_t alloc_len_i,
  input  offset_t       alloc_offset_i,
  input  logic          alloc_req_i,
  output logic          alloc_gnt_o,
  input  id_t           cnt_id_i,
  output axi_pkg::len_t cnt_len_o,
  output offset_t       cnt_offset_o,
  input  logic          cnt_set_err_i,
  output logic          cnt_err_o,
  input  logic          cnt_len_dec_i,
  input  logic          cnt_offset_inc_i,
  input  logic          cnt_req_i,
  output logic          cnt_gnt_o
);
  localparam int unsigned CntIdxWidth = (MaxTrans > 1) ? $clog2(MaxTrans) : 32'd1;

  typedef logic [CntIdxWidth-1:0]         cnt_idx_t;
  typedef logic [$bits(axi_pkg::len_t):0] cnt_t;

  cnt_idx_t            cnt_free_idx, cnt_r_idx;
  logic [MaxTrans-1:0] cnt_len_dec, cnt_offset_inc, cnt_free, cnt_set, err_d, err_q;
  cnt_t                cnt_len_inp;
  cnt_t [MaxTrans-1:0] cnt_len_oup;
  offset_t             cnt_offset_inp;
  offset_t [MaxTrans-1:0] cnt_offset_oup;

  for (genvar i = 0; i < MaxTrans; i++) begin : gen_cnt
    counter #(
      .WIDTH ( $bits(cnt_t) )
    ) i_cnt_len (
      .clk_i,
      .rst_ni,
      .clear_i    ( 1'b0           ),
      .en_i       ( cnt_len_dec[i] ),
      .load_i     ( cnt_set[i]     ),
      .down_i     ( 1'b1           ),
      .d_i        ( cnt_len_inp    ),
      .q_o        ( cnt_len_oup[i] ),
      .overflow_o (                )
    );
    counter #(
      .WIDTH ( $bits(offset_t) )
    ) i_cnt_offset (
      .clk_i,
      .rst_ni,
      .clear_i    ( 1'b0              ),
      .en_i       ( cnt_offset_inc[i] ),
      .load_i     ( cnt_set[i]        ),
      .down_i     ( 1'b0              ),
      .d_i        ( cnt_offset_inp    ),
      .q_o        ( cnt_offset_oup[i] ),
      .overflow_o (                   )
    );
    assign cnt_free[i] = (cnt_len_oup[i] == '0);
  end
  assign cnt_len_inp    = {1'b0, alloc_len_i} + 1;
  assign cnt_offset_inp = alloc_offset_i;

  lzc #(
    .WIDTH ( MaxTrans ),
    .MODE  ( 1'b0     )
  ) i_lzc (
    .in_i    ( cnt_free     ),
    .cnt_o   ( cnt_free_idx ),
    .empty_o (              )
  );

  logic idq_inp_req, idq_inp_gnt;
  logic idq_oup_gnt, idq_oup_valid, idq_oup_pop;
  id_queue #(
    .ID_WIDTH ( $bits(id_t) ),
    .CAPACITY ( MaxTrans    ),
    .FULL_BW  ( 1'b1        ),
    .data_t   ( cnt_idx_t   )
  ) i_idq (
    .clk_i,
    .rst_ni,
    .inp_id_i         ( alloc_id_i    ),
    .inp_data_i       ( cnt_free_idx  ),
    .inp_req_i        ( idq_inp_req   ),
    .inp_gnt_o        ( idq_inp_gnt   ),
    .exists_data_i    ( '0            ),
    .exists_mask_i    ( '0            ),
    .exists_req_i     ( 1'b0          ),
    .exists_o         (               ),
    .exists_gnt_o     (               ),
    .oup_id_i         ( cnt_id_i      ),
    .oup_pop_i        ( idq_oup_pop   ),
    .oup_req_i        ( cnt_req_i     ),
    .oup_data_o       ( cnt_r_idx     ),
    .oup_data_valid_o ( idq_oup_valid ),
    .oup_gnt_o        ( idq_oup_gnt   )
  );
  logic [8:0] read_len;
  assign idq_inp_req  = alloc_req_i & alloc_gnt_o;
  assign alloc_gnt_o  = idq_inp_gnt & |(cnt_free);
  assign cnt_gnt_o    = idq_oup_gnt & idq_oup_valid;
  assign read_len     = cnt_len_oup[cnt_r_idx] - 1;
  assign cnt_len_o    = read_len[7:0];
  assign cnt_offset_o = cnt_offset_oup[cnt_r_idx];
  assign idq_oup_pop  = cnt_req_i & cnt_gnt_o & cnt_len_dec_i & (cnt_len_o == 8'd0);

  always_comb begin
    cnt_len_dec            = '0;
    cnt_len_dec[cnt_r_idx] = cnt_req_i & cnt_gnt_o & cnt_len_dec_i;
  end
  always_comb begin
    cnt_offset_inc            = '0;
    cnt_offset_inc[cnt_r_idx] = cnt_req_i & cnt_gnt_o & cnt_offset_inc_i;
  end
  always_comb begin
    cnt_set               = '0;
    cnt_set[cnt_free_idx] = alloc_req_i & alloc_gnt_o;
  end
  always_comb begin
    err_d     = err_q;
    cnt_err_o = err_q[cnt_r_idx];
    if (cnt_req_i && cnt_gnt_o && cnt_set_err_i) begin
      err_d[cnt_r_idx] = 1'b1;
      cnt_err_o        = 1'b1;
    end
    if (alloc_req_i && alloc_gnt_o) begin
      err_d[cnt_free_idx] = 1'b0;
    end
  end

  `FF(err_q, err_d, '0, clk_i, rst_ni)

endmodule
