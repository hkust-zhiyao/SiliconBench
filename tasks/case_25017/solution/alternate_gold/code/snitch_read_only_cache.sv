// Copyright 2021 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

/// Wide-line AXI4 Read-Only Cache with lookup-delegated range invalidation (alt_gold_1).
module snitch_read_only_cache #(
  parameter int unsigned LineWidth    = -1,
  parameter int unsigned LineCount    = -1,
  parameter int unsigned SetCount     = 1,
  parameter int unsigned AxiAddrWidth = 0,
  parameter int unsigned AxiDataWidth = 0,
  parameter int unsigned AxiIdWidth   = 0,
  parameter int unsigned AxiUserWidth = 0,
  parameter int unsigned MaxTrans     = 0,
  parameter int unsigned NrAddrRules  = 1,
  parameter type slv_req_t = logic,
  parameter type slv_rsp_t = logic,
  parameter type mst_req_t = logic,
  parameter type mst_rsp_t = logic,
  parameter type sram_cfg_data_t  = logic,
  parameter type sram_cfg_tag_t   = logic
) (
  input  logic                                     clk_i,
  input  logic                                     rst_ni,
  input  logic                                     enable_i,
  input  logic                                     flush_valid_i,
  output logic                                     flush_ready_o,
  input  logic [NrAddrRules-1:0][AxiAddrWidth-1:0] start_addr_i,
  input  logic [NrAddrRules-1:0][AxiAddrWidth-1:0] end_addr_i,
  input  slv_req_t                                 axi_slv_req_i,
  output slv_rsp_t                                 axi_slv_rsp_o,
  output mst_req_t                                 axi_mst_req_o,
  input  mst_rsp_t                                 axi_mst_rsp_i,
  input  sram_cfg_data_t                           sram_cfg_data_i,
  input  sram_cfg_tag_t                            sram_cfg_tag_i
);

  `include "axi/typedef.svh"
  `include "common_cells/registers.svh"
  import cf_math_pkg::idx_width;

  localparam int unsigned NoMstPorts = 2;
  typedef logic [idx_width(NoMstPorts)-1:0] index_t;
  typedef enum index_t { Cache = 1, Bypass = 0 } index_e;

  typedef logic [AxiIdWidth-1:0]     id_t;
  typedef logic [AxiIdWidth:0]       mst_id_t;
  typedef logic [AxiAddrWidth-1:0]   addr_t;
  typedef logic [AxiDataWidth-1:0]   data_t;
  typedef logic [AxiDataWidth/8-1:0] strb_t;
  typedef logic [AxiUserWidth-1:0]   user_t;

  `AXI_TYPEDEF_ALL(axi, addr_t, id_t, data_t, strb_t, user_t)
  `AXI_TYPEDEF_ALL(axi_mst, addr_t, mst_id_t, data_t, strb_t, user_t)

  localparam int unsigned PendingCount = MaxTrans;
  localparam snitch_icache_pkg::config_t CFG = '{
    LINE_WIDTH: LineWidth, LINE_COUNT: LineCount, SET_COUNT: SetCount,
    PENDING_COUNT: PendingCount, FETCH_AW: AxiAddrWidth, FETCH_DW: AxiDataWidth,
    FILL_AW: AxiAddrWidth, FILL_DW: AxiDataWidth, EARLY_LATCH: 0,
    BUFFER_LOOKUP: 1, GUARANTEE_ORDERING: 1,
    FETCH_ALIGN: $clog2(AxiDataWidth/8), FILL_ALIGN: $clog2(AxiDataWidth/8),
    LINE_ALIGN: $clog2(LineWidth/8), COUNT_ALIGN: cf_math_pkg::idx_width(LineCount),
    SET_ALIGN: cf_math_pkg::idx_width(SetCount),
    TAG_WIDTH: AxiAddrWidth - $clog2(LineWidth/8) - $clog2(LineCount) + 1,
    ID_WIDTH_REQ: AxiIdWidth, ID_WIDTH_RESP: 2**AxiIdWidth,
    PENDING_IW: $clog2(PendingCount), default: 0
  };

  slv_req_t  slv_req_gated;
  slv_rsp_t  slv_rsp_raw;
  axi_req_t  [1:0] demux_req;
  axi_resp_t [1:0] demux_rsp;
  axi_req_t  refill_req;
  axi_resp_t refill_rsp;
  index_t    slv_aw_select, slv_ar_select;

  logic ar_locked_q, aw_locked_q;
  logic [7:0] open_wr_q, open_cr_q, open_rf_q;
  logic lookup_busy, lookup_fl_valid, lookup_fl_ready;

  typedef struct packed {
    logic [CFG.COUNT_ALIGN-1:0] base_set;
    logic [CFG.COUNT_ALIGN:0]   num_sets;
  } wr_inv_t;

  wr_inv_t inv_in, inv_out;
  logic inv_q_full, inv_q_empty, inv_q_push, inv_q_pop;
  logic inv_req_to_lookup, inv_gnt_from_lookup;

  logic ar_fits_rule;
  always_comb begin
    automatic logic [AxiAddrWidth:0] span =
        ((AxiAddrWidth+1)'(axi_slv_req_i.ar.len) + 1'b1) << axi_slv_req_i.ar.size;
    automatic logic [AxiAddrWidth:0] top = (AxiAddrWidth+1)'(axi_slv_req_i.ar.addr) + span - 1'b1;
    ar_fits_rule = 1'b0;
    for (int r = 0; r < NrAddrRules; r++) begin
      if ((start_addr_i[r] < end_addr_i[r]) && !top[AxiAddrWidth] &&
          (axi_slv_req_i.ar.addr >= start_addr_i[r]) &&
          (top[AxiAddrWidth-1:0] < end_addr_i[r])) begin
        ar_fits_rule = 1'b1;
      end
    end
  end

  assign slv_aw_select = Bypass;
  assign slv_ar_select = (enable_i && ar_fits_rule && !axi_slv_req_i.ar.lock &&
                          (axi_slv_req_i.ar.burst == axi_pkg::BURST_INCR) &&
                          ((axi_slv_req_i.ar.len == 8'd0) ||
                           (axi_slv_req_i.ar.size == $clog2(AxiDataWidth/8)))) ? Cache : Bypass;

  logic aw_hits_rule;
  always_comb begin
    automatic logic [AxiAddrWidth:0] wbytes =
        ((AxiAddrWidth+1)'(axi_slv_req_i.aw.len) + 1'b1) << axi_slv_req_i.aw.size;
    automatic addr_t wlo;
    automatic logic [AxiAddrWidth:0] whi_ext;
    automatic addr_t whi;
    automatic logic [AxiAddrWidth-CFG.LINE_ALIGN:0] l0, l1, nl;
    if (axi_slv_req_i.aw.burst == axi_pkg::BURST_FIXED) begin
      wlo     = axi_slv_req_i.aw.addr;
      whi_ext = (AxiAddrWidth+1)'(wlo) + ((AxiAddrWidth+1)'(1) << axi_slv_req_i.aw.size) - 1'b1;
    end else if (axi_slv_req_i.aw.burst == axi_pkg::BURST_WRAP) begin
      automatic addr_t wmask = wbytes[AxiAddrWidth-1:0] - 1'b1;
      wlo     = axi_slv_req_i.aw.addr & ~wmask;
      whi_ext = (AxiAddrWidth+1)'(wlo) + wbytes - 1'b1;
    end else begin
      wlo     = axi_slv_req_i.aw.addr;
      whi_ext = (AxiAddrWidth+1)'(wlo) + wbytes - 1'b1;
    end
    whi = whi_ext[AxiAddrWidth] ? '1 : whi_ext[AxiAddrWidth-1:0];
    aw_hits_rule = 1'b0;
    for (int r = 0; r < NrAddrRules; r++) begin
      if ((start_addr_i[r] < end_addr_i[r]) && (wlo < end_addr_i[r]) && (whi >= start_addr_i[r]))
        aw_hits_rule = 1'b1;
    end
    l0 = wlo >> CFG.LINE_ALIGN;
    l1 = whi >> CFG.LINE_ALIGN;
    nl = l1 - l0 + 1'b1;
    inv_in.base_set = l0[CFG.COUNT_ALIGN-1:0];
    inv_in.num_sets = (nl > $unsigned(LineCount)) ? (CFG.COUNT_ALIGN+1)'(LineCount) : nl[CFG.COUNT_ALIGN:0];
  end
  wire gate_aw = !aw_locked_q && (flush_valid_i || lookup_busy || (aw_hits_rule && inv_q_full));
  wire gate_ar = !ar_locked_q && (flush_valid_i || lookup_busy ||
                                  (axi_slv_req_i.aw_valid && !gate_aw) ||
                                  (open_wr_q != '0) || !inv_q_empty);

  always_comb begin
    slv_req_gated = axi_slv_req_i;
    axi_slv_rsp_o = slv_rsp_raw;
    if (gate_aw) begin slv_req_gated.aw_valid = 1'b0; axi_slv_rsp_o.aw_ready = 1'b0; end
    if (gate_ar) begin slv_req_gated.ar_valid = 1'b0; axi_slv_rsp_o.ar_ready = 1'b0; end
  end

  logic                         handler_req_valid, handler_req_ready, handler_rsp_valid, handler_rsp_ready, handler_rsp_error;
  logic [CFG.FETCH_AW-1:0]      handler_req_addr;
  logic [CFG.PENDING_IW-1:0]    handler_req_id, handler_rsp_id;
  logic [CFG.LINE_WIDTH-1:0]    handler_rsp_data;

  wire ev_aw = slv_req_gated.aw_valid && slv_rsp_raw.aw_ready;
  wire ev_b  = slv_rsp_raw.b_valid && slv_req_gated.b_ready;
  wire ev_ar = slv_req_gated.ar_valid && slv_rsp_raw.ar_ready;
  wire ev_ca = demux_req[Cache].ar_valid && demux_rsp[Cache].ar_ready;
  wire ev_cr = demux_rsp[Cache].r_valid && demux_req[Cache].r_ready && demux_rsp[Cache].r.last;
  wire ev_ra = handler_req_valid && handler_req_ready;
  wire ev_rr = handler_rsp_valid && handler_rsp_ready;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      ar_locked_q <= 1'b0; aw_locked_q <= 1'b0;
      open_wr_q <= '0; open_cr_q <= '0; open_rf_q <= '0;
    end else begin
      if (ev_ar) ar_locked_q <= 1'b0; else if (slv_req_gated.ar_valid) ar_locked_q <= 1'b1;
      if (ev_aw) aw_locked_q <= 1'b0; else if (slv_req_gated.aw_valid) aw_locked_q <= 1'b1;
      open_wr_q <= open_wr_q + 8'(ev_aw) - 8'(ev_b);
      open_cr_q <= open_cr_q + 8'(ev_ca) - 8'(ev_cr);
      open_rf_q <= open_rf_q + 8'(ev_ra) - 8'(ev_rr);
    end
  end

  assign inv_q_push = ev_aw && aw_hits_rule;
  fifo_v3 #(.DEPTH(MaxTrans), .dtype(wr_inv_t)) i_wr_inv_q (
    .clk_i, .rst_ni, .flush_i(1'b0), .testmode_i(1'b0),
    .full_o(inv_q_full), .empty_o(inv_q_empty), .usage_o(),
    .data_i(inv_in), .push_i(inv_q_push), .data_o(inv_out), .pop_i(inv_q_pop)
  );

  wire all_drained = (open_wr_q == '0) && (open_cr_q == '0) && (open_rf_q == '0);
  assign inv_req_to_lookup = !inv_q_empty && all_drained;
  assign inv_q_pop         = inv_req_to_lookup && inv_gnt_from_lookup;

  wire flush_ready_gate = !ar_locked_q && !aw_locked_q && all_drained && inv_q_empty;
  assign lookup_fl_valid = flush_valid_i && flush_ready_gate;
  assign flush_ready_o   = flush_ready_gate && lookup_fl_ready;

  axi_demux #(
    .AxiIdWidth(AxiIdWidth), .aw_chan_t(axi_aw_chan_t), .w_chan_t(axi_w_chan_t),
    .b_chan_t(axi_b_chan_t), .ar_chan_t(axi_ar_chan_t), .r_chan_t(axi_r_chan_t),
    .axi_req_t(axi_req_t), .axi_resp_t(axi_resp_t), .NoMstPorts(NoMstPorts),
    .MaxTrans(MaxTrans), .AxiLookBits(AxiIdWidth),
    .SpillAw(1'b0), .SpillW(1'b0), .SpillB(1'b0), .SpillAr(1'b0), .SpillR(1'b0)
  ) i_axi_demux (
    .clk_i, .rst_ni, .test_i(1'b0),
    .slv_req_i(slv_req_gated), .slv_aw_select_i(slv_aw_select), .slv_ar_select_i(slv_ar_select),
    .slv_resp_o(slv_rsp_raw), .mst_reqs_o(demux_req), .mst_resps_i(demux_rsp)
  );

  logic [CFG.FETCH_AW-1:0]      in_addr, lookup_addr;
  logic [CFG.ID_WIDTH_REQ-1:0]  in_id, lookup_id;
  logic                         in_valid, in_ready, in_rsp_error, in_rsp_valid, in_rsp_ready;
  logic [CFG.LINE_WIDTH-1:0]    in_rsp_data, lookup_data, write_data;
  logic [CFG.ID_WIDTH_RESP-1:0] in_rsp_id;
  logic [CFG.SET_ALIGN-1:0]     lookup_set, write_set;
  logic                         lookup_hit, lookup_error, lookup_valid, lookup_ready;
  logic [CFG.COUNT_ALIGN-1:0]   write_addr;
  logic [CFG.TAG_WIDTH-1:0]     write_tag;
  logic                         write_error, write_valid, write_ready;

  snitch_axi_to_cache #(.MaxTrans(MaxTrans), .req_t(axi_req_t), .resp_t(axi_resp_t), .CFG(CFG)) i_axi_to_cache (
    .clk_i, .rst_ni, .req_addr_o(in_addr), .req_id_o(in_id), .req_valid_o(in_valid), .req_ready_i(in_ready),
    .rsp_data_i(in_rsp_data), .rsp_error_i(in_rsp_error), .rsp_id_i(in_rsp_id),
    .rsp_valid_i(in_rsp_valid), .rsp_ready_o(in_rsp_ready),
    .slv_req_i(demux_req[Cache]), .slv_rsp_o(demux_rsp[Cache])
  );

  snitch_ro_cache_lookup #(.CFG(CFG), .sram_cfg_tag_t(sram_cfg_tag_t), .sram_cfg_data_t(sram_cfg_data_t)) i_lookup (
    .clk_i, .rst_ni,
    .flush_valid_i(lookup_fl_valid), .flush_ready_o(lookup_fl_ready), .busy_o(lookup_busy),
    .inv_req_i(inv_req_to_lookup), .inv_start_i(inv_out.base_set), .inv_cnt_i(inv_out.num_sets), .inv_gnt_o(inv_gnt_from_lookup),
    .in_addr_i(in_addr), .in_id_i(in_id), .in_valid_i(in_valid), .in_ready_o(in_ready),
    .out_addr_o(lookup_addr), .out_id_o(lookup_id), .out_set_o(lookup_set), .out_hit_o(lookup_hit),
    .out_data_o(lookup_data), .out_error_o(lookup_error), .out_valid_o(lookup_valid), .out_ready_i(lookup_ready),
    .write_addr_i(write_addr), .write_set_i(write_set), .write_data_i(write_data), .write_tag_i(write_tag),
    .write_error_i(write_error), .write_valid_i(write_valid), .write_ready_o(write_ready),
    .sram_cfg_tag_i, .sram_cfg_data_i
  );

  snitch_icache_handler #(CFG) i_handler (
    .clk_i, .rst_ni,
    .in_req_addr_i(lookup_addr), .in_req_id_i(lookup_id), .in_req_set_i(lookup_set), .in_req_hit_i(lookup_hit),
    .in_req_data_i(lookup_data), .in_req_error_i(lookup_error), .in_req_valid_i(lookup_valid), .in_req_ready_o(lookup_ready),
    .in_rsp_data_o(in_rsp_data), .in_rsp_error_o(in_rsp_error), .in_rsp_id_o(in_rsp_id), .in_rsp_valid_o(in_rsp_valid), .in_rsp_ready_i(in_rsp_ready),
    .write_addr_o(write_addr), .write_set_o(write_set), .write_data_o(write_data), .write_tag_o(write_tag),
    .write_error_o(write_error), .write_valid_o(write_valid), .write_ready_i(write_ready),
    .out_req_addr_o(handler_req_addr), .out_req_id_o(handler_req_id), .out_req_valid_o(handler_req_valid), .out_req_ready_i(handler_req_ready),
    .out_rsp_data_i(handler_rsp_data), .out_rsp_error_i(handler_rsp_error), .out_rsp_id_i(handler_rsp_id), .out_rsp_valid_i(handler_rsp_valid), .out_rsp_ready_o(handler_rsp_ready)
  );

  snitch_ro_cache_refill #(.CFG(CFG), .axi_req_t(axi_req_t), .axi_rsp_t(axi_resp_t)) i_refill (
    .clk_i, .rst_ni,
    .in_req_addr_i(handler_req_addr), .in_req_id_i(handler_req_id), .in_req_bypass_i(1'b0),
    .in_req_valid_i(handler_req_valid), .in_req_ready_o(handler_req_ready),
    .in_rsp_data_o(handler_rsp_data), .in_rsp_error_o(handler_rsp_error), .in_rsp_id_o(handler_rsp_id),
    .in_rsp_bypass_o(), .in_rsp_valid_o(handler_rsp_valid), .in_rsp_ready_i(handler_rsp_ready),
    .axi_req_o(refill_req), .axi_rsp_i(refill_rsp)
  );

  axi_mux #(
    .SlvAxiIDWidth(AxiIdWidth), .slv_aw_chan_t(axi_aw_chan_t), .mst_aw_chan_t(axi_mst_aw_chan_t),
    .w_chan_t(axi_w_chan_t), .slv_b_chan_t(axi_b_chan_t), .mst_b_chan_t(axi_mst_b_chan_t),
    .slv_ar_chan_t(axi_ar_chan_t), .mst_ar_chan_t(axi_mst_ar_chan_t),
    .slv_r_chan_t(axi_r_chan_t), .mst_r_chan_t(axi_mst_r_chan_t),
    .slv_req_t(axi_req_t), .slv_resp_t(axi_resp_t), .mst_req_t(axi_mst_req_t), .mst_resp_t(axi_mst_resp_t),
    .NoSlvPorts(NoMstPorts), .MaxWTrans(MaxTrans), .FallThrough(1'b1),
    .SpillAw(1'b0), .SpillW(1'b0), .SpillB(1'b0), .SpillAr(1'b0), .SpillR(1'b0)
  ) i_axi_mux (
    .clk_i, .rst_ni, .test_i(1'b0),
    .slv_reqs_i({refill_req, demux_req[Bypass]}), .slv_resps_o({refill_rsp, demux_rsp[Bypass]}),
    .mst_req_o(axi_mst_req_o), .mst_resp_i(axi_mst_rsp_i)
  );

endmodule
