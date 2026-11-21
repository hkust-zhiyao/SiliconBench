// Copyright 2021 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

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
  typedef enum index_t {
    Cache  = 1,
    Bypass = 0
  } index_e;

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
    LINE_WIDTH:         LineWidth,
    LINE_COUNT:         LineCount,
    SET_COUNT:          SetCount,
    PENDING_COUNT:      PendingCount,
    FETCH_AW:           AxiAddrWidth,
    FETCH_DW:           AxiDataWidth,
    FILL_AW:            AxiAddrWidth,
    FILL_DW:            AxiDataWidth,
    EARLY_LATCH:        0,
    BUFFER_LOOKUP:      1,
    GUARANTEE_ORDERING: 1,
    FETCH_ALIGN:        $clog2(AxiDataWidth/8),
    FILL_ALIGN:         $clog2(AxiDataWidth/8),
    LINE_ALIGN:         $clog2(LineWidth/8),
    COUNT_ALIGN:        cf_math_pkg::idx_width(LineCount),
    SET_ALIGN:          cf_math_pkg::idx_width(SetCount),
    TAG_WIDTH:          AxiAddrWidth - $clog2(LineWidth/8) - $clog2(LineCount) + 1,
    ID_WIDTH_REQ:       AxiIdWidth,
    ID_WIDTH_RESP:      2**AxiIdWidth,
    PENDING_IW:         $clog2(PendingCount),
    default:            0
  };

  slv_req_t  slv_req_in;
  slv_rsp_t  slv_rsp_out;
  axi_req_t  [1:0] demux_req;
  axi_resp_t [1:0] demux_rsp;
  axi_req_t  refill_req;
  axi_resp_t refill_rsp;
  index_t    slv_aw_select;
  index_t    slv_ar_select;

  // Coherence & drain tracking
  logic ar_in_progress_q, aw_in_progress_q;
  logic [7:0] wr_inflight_q, cache_ar_inflight_q, refill_inflight_q;
  logic lookup_init_busy, lookup_flush_valid, lookup_flush_ready;

  typedef struct packed {
    logic [CFG.COUNT_ALIGN-1:0] start_idx;
    logic [CFG.COUNT_ALIGN:0]   line_cnt;
  } inval_cmd_t;

  inval_cmd_t inval_push_cmd, inval_pop_cmd;
  logic inval_fifo_full, inval_fifo_empty, inval_fifo_push, inval_fifo_pop;
  logic inval_sweeping_q, inval_valid, inval_ready;
  logic [CFG.COUNT_ALIGN-1:0] inval_idx_q;
  logic [CFG.COUNT_ALIGN:0]   inval_rem_q;

  // Address region check for AR burst [ar.addr, ar_last_addr]
  logic ar_in_region;
  always_comb begin
    automatic logic [AxiAddrWidth:0] ar_bytes =
        ((AxiAddrWidth+1)'(axi_slv_req_i.ar.len) + 1'b1) << axi_slv_req_i.ar.size;
    automatic logic [AxiAddrWidth:0] ar_end_ext =
        (AxiAddrWidth+1)'(axi_slv_req_i.ar.addr) + ar_bytes - 1'b1;
    automatic logic ar_ovf = ar_end_ext[AxiAddrWidth];
    automatic addr_t ar_last = ar_end_ext[AxiAddrWidth-1:0];
    ar_in_region = 1'b0;
    for (int r = 0; r < NrAddrRules; r++) begin
      if ((start_addr_i[r] < end_addr_i[r]) && !ar_ovf &&
          (axi_slv_req_i.ar.addr >= start_addr_i[r]) &&
          (ar_last < end_addr_i[r])) begin
        ar_in_region = 1'b1;
      end
    end
  end

  assign slv_aw_select = Bypass;
  always_comb begin
    slv_ar_select = Bypass;
    if (enable_i && ar_in_region &&
        !axi_slv_req_i.ar.lock &&
        (axi_slv_req_i.ar.burst == axi_pkg::BURST_INCR) &&
        ((axi_slv_req_i.ar.len == 8'd0) || (axi_slv_req_i.ar.size == $clog2(AxiDataWidth/8)))) begin
      slv_ar_select = Cache;
    end
  end

  // AW cache-line overlap calculation
  logic aw_overlaps_cache;
  always_comb begin
    automatic logic [AxiAddrWidth:0] aw_bytes =
        ((AxiAddrWidth+1)'(axi_slv_req_i.aw.len) + 1'b1) << axi_slv_req_i.aw.size;
    automatic addr_t aw_lo;
    automatic logic [AxiAddrWidth:0] aw_hi_ext;
    automatic addr_t aw_hi;
    automatic logic [AxiAddrWidth-CFG.LINE_ALIGN:0] first_ln, last_ln, span_ln;
    if (axi_slv_req_i.aw.burst == axi_pkg::BURST_FIXED) begin
      aw_lo     = axi_slv_req_i.aw.addr;
      aw_hi_ext = (AxiAddrWidth+1)'(aw_lo) + ((AxiAddrWidth+1)'(1) << axi_slv_req_i.aw.size) - 1'b1;
    end else if (axi_slv_req_i.aw.burst == axi_pkg::BURST_WRAP) begin
      automatic addr_t wmask = aw_bytes[AxiAddrWidth-1:0] - 1'b1;
      aw_lo     = axi_slv_req_i.aw.addr & ~wmask;
      aw_hi_ext = (AxiAddrWidth+1)'(aw_lo) + aw_bytes - 1'b1;
    end else begin
      aw_lo     = axi_slv_req_i.aw.addr;
      aw_hi_ext = (AxiAddrWidth+1)'(aw_lo) + aw_bytes - 1'b1;
    end
    aw_hi = aw_hi_ext[AxiAddrWidth] ? '1 : aw_hi_ext[AxiAddrWidth-1:0];

    aw_overlaps_cache = 1'b0;
    for (int r = 0; r < NrAddrRules; r++) begin
      if ((start_addr_i[r] < end_addr_i[r]) &&
          (aw_lo < end_addr_i[r]) && (aw_hi >= start_addr_i[r])) begin
        aw_overlaps_cache = 1'b1;
      end
    end

    first_ln = aw_lo >> CFG.LINE_ALIGN;
    last_ln  = aw_hi >> CFG.LINE_ALIGN;
    span_ln  = last_ln - first_ln + 1'b1;
    inval_push_cmd.start_idx = first_ln[CFG.COUNT_ALIGN-1:0];
    inval_push_cmd.line_cnt  = (span_ln > $unsigned(LineCount)) ?
                               (CFG.COUNT_ALIGN+1)'(LineCount) : span_ln[CFG.COUNT_ALIGN:0];
  end
  // Gate new AR/AW cleanly without ever dropping a locked valid inside axi_demux
  logic block_ar, block_aw;
  assign block_aw = !aw_in_progress_q &&
                    (flush_valid_i || lookup_init_busy || (aw_overlaps_cache && inval_fifo_full));
  assign block_ar = !ar_in_progress_q &&
                    (flush_valid_i || lookup_init_busy ||
                     (axi_slv_req_i.aw_valid && !block_aw) ||
                     (wr_inflight_q != '0) || !inval_fifo_empty || inval_sweeping_q);

  always_comb begin
    slv_req_in    = axi_slv_req_i;
    axi_slv_rsp_o = slv_rsp_out;
    if (block_aw) begin
      slv_req_in.aw_valid    = 1'b0;
      axi_slv_rsp_o.aw_ready = 1'b0;
    end
    if (block_ar) begin
      slv_req_in.ar_valid    = 1'b0;
      axi_slv_rsp_o.ar_ready = 1'b0;
    end
  end

  wire aw_hs       = slv_req_in.aw_valid && slv_rsp_out.aw_ready;
  wire b_hs        = slv_rsp_out.b_valid && slv_req_in.b_ready;
  wire ar_hs       = slv_req_in.ar_valid && slv_rsp_out.ar_ready;
  wire cache_ar_hs = demux_req[Cache].ar_valid && demux_rsp[Cache].ar_ready;
  wire cache_r_end = demux_rsp[Cache].r_valid && demux_req[Cache].r_ready && demux_rsp[Cache].r.last;

  logic                         handler_req_valid, handler_req_ready;
  logic [CFG.FETCH_AW-1:0]      handler_req_addr;
  logic [CFG.PENDING_IW-1:0]    handler_req_id;
  logic [CFG.LINE_WIDTH-1:0]    handler_rsp_data;
  logic                         handler_rsp_error;
  logic [CFG.PENDING_IW-1:0]    handler_rsp_id;
  logic                         handler_rsp_valid, handler_rsp_ready;

  wire refill_ar_hs = handler_req_valid && handler_req_ready;
  wire refill_r_end = handler_rsp_valid && handler_rsp_ready;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      ar_in_progress_q    <= 1'b0;
      aw_in_progress_q    <= 1'b0;
      wr_inflight_q       <= '0;
      cache_ar_inflight_q <= '0;
      refill_inflight_q   <= '0;
    end else begin
      if (ar_hs) ar_in_progress_q <= 1'b0;
      else if (slv_req_in.ar_valid) ar_in_progress_q <= 1'b1;

      if (aw_hs) aw_in_progress_q <= 1'b0;
      else if (slv_req_in.aw_valid) aw_in_progress_q <= 1'b1;

      wr_inflight_q       <= wr_inflight_q + 8'(aw_hs) - 8'(b_hs);
      cache_ar_inflight_q <= cache_ar_inflight_q + 8'(cache_ar_hs) - 8'(cache_r_end);
      refill_inflight_q   <= refill_inflight_q + 8'(refill_ar_hs) - 8'(refill_r_end);
    end
  end

  assign inval_fifo_push = aw_hs && aw_overlaps_cache;

  fifo_v3 #(
    .DEPTH ( MaxTrans    ),
    .dtype ( inval_cmd_t )
  ) i_inval_fifo (
    .clk_i      ( clk_i            ),
    .rst_ni     ( rst_ni           ),
    .flush_i    ( 1'b0             ),
    .testmode_i ( 1'b0             ),
    .full_o     ( inval_fifo_full  ),
    .empty_o    ( inval_fifo_empty ),
    .usage_o    (                  ),
    .data_i     ( inval_push_cmd   ),
    .push_i     ( inval_fifo_push  ),
    .data_o     ( inval_pop_cmd    ),
    .pop_i      ( inval_fifo_pop   )
  );

  wire cache_quiescent = (wr_inflight_q == '0) &&
                         (cache_ar_inflight_q == '0) &&
                         (refill_inflight_q == '0);

  assign inval_fifo_pop = !inval_sweeping_q && !inval_fifo_empty && cache_quiescent && !lookup_init_busy;
  assign inval_valid    = inval_sweeping_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      inval_sweeping_q <= 1'b0;
      inval_idx_q      <= '0;
      inval_rem_q      <= '0;
    end else if (inval_fifo_pop) begin
      inval_sweeping_q <= 1'b1;
      inval_idx_q      <= inval_pop_cmd.start_idx;
      inval_rem_q      <= inval_pop_cmd.line_cnt;
    end else if (inval_sweeping_q && inval_ready) begin
      if (inval_rem_q <= (CFG.COUNT_ALIGN+1)'(1)) begin
        inval_sweeping_q <= 1'b0;
        inval_rem_q      <= '0;
      end else begin
        inval_idx_q <= inval_idx_q + 1'b1;
        inval_rem_q <= inval_rem_q - 1'b1;
      end
    end
  end

  wire flush_can_fire = !ar_in_progress_q && !aw_in_progress_q &&
                        cache_quiescent && inval_fifo_empty && !inval_sweeping_q;
  assign lookup_flush_valid = flush_valid_i && flush_can_fire;
  assign flush_ready_o      = flush_can_fire && lookup_flush_ready;

  axi_demux #(
    .AxiIdWidth  ( AxiIdWidth    ),
    .aw_chan_t   ( axi_aw_chan_t ),
    .w_chan_t    ( axi_w_chan_t  ),
    .b_chan_t    ( axi_b_chan_t  ),
    .ar_chan_t   ( axi_ar_chan_t ),
    .r_chan_t    ( axi_r_chan_t  ),
    .axi_req_t   ( axi_req_t     ),
    .axi_resp_t  ( axi_resp_t    ),
    .NoMstPorts  ( NoMstPorts    ),
    .MaxTrans    ( MaxTrans      ),
    .AxiLookBits ( AxiIdWidth    ),
    .SpillAw     ( 1'b0          ),
    .SpillW      ( 1'b0          ),
    .SpillB      ( 1'b0          ),
    .SpillAr     ( 1'b0          ),
    .SpillR      ( 1'b0          )
  ) i_axi_demux (
    .clk_i,
    .rst_ni,
    .test_i          ( 1'b0          ),
    .slv_req_i       ( slv_req_in    ),
    .slv_aw_select_i ( slv_aw_select ),
    .slv_ar_select_i ( slv_ar_select ),
    .slv_resp_o      ( slv_rsp_out   ),
    .mst_reqs_o      ( demux_req     ),
    .mst_resps_i     ( demux_rsp     )
  );

  logic [CFG.FETCH_AW-1:0]      in_addr, lookup_addr;
  logic [CFG.ID_WIDTH_REQ-1:0]  in_id, lookup_id;
  logic                         in_valid, in_ready;
  logic [CFG.LINE_WIDTH-1:0]    in_rsp_data, lookup_data, write_data;
  logic                         in_rsp_error, lookup_error, write_error;
  logic [CFG.ID_WIDTH_RESP-1:0] in_rsp_id;
  logic                         in_rsp_valid, in_rsp_ready;
  logic [CFG.SET_ALIGN-1:0]     lookup_set, write_set;
  logic                         lookup_hit, lookup_valid, lookup_ready;
  logic [CFG.COUNT_ALIGN-1:0]   write_addr;
  logic [CFG.TAG_WIDTH-1:0]     write_tag;
  logic                         write_valid, write_ready;

  snitch_axi_to_cache #(
    .MaxTrans ( MaxTrans   ),
    .req_t    ( axi_req_t  ),
    .resp_t   ( axi_resp_t ),
    .CFG      ( CFG        )
  ) i_axi_to_cache (
    .clk_i,
    .rst_ni,
    .req_addr_o  ( in_addr          ),
    .req_id_o    ( in_id            ),
    .req_valid_o ( in_valid         ),
    .req_ready_i ( in_ready         ),
    .rsp_data_i  ( in_rsp_data      ),
    .rsp_error_i ( in_rsp_error     ),
    .rsp_id_i    ( in_rsp_id        ),
    .rsp_valid_i ( in_rsp_valid     ),
    .rsp_ready_o ( in_rsp_ready     ),
    .slv_req_i   ( demux_req[Cache] ),
    .slv_rsp_o   ( demux_rsp[Cache] )
  );

  snitch_ro_cache_lookup #(
    .CFG             ( CFG             ),
    .sram_cfg_tag_t  ( sram_cfg_tag_t  ),
    .sram_cfg_data_t ( sram_cfg_data_t )
  ) i_lookup (
    .clk_i,
    .rst_ni,
    .flush_valid_i ( lookup_flush_valid ),
    .flush_ready_o ( lookup_flush_ready ),
    .init_busy_o   ( lookup_init_busy   ),
    .inval_valid_i ( inval_valid        ),
    .inval_addr_i  ( inval_idx_q        ),
    .inval_ready_o ( inval_ready        ),
    .in_addr_i     ( in_addr            ),
    .in_id_i       ( in_id              ),
    .in_valid_i    ( in_valid           ),
    .in_ready_o    ( in_ready           ),
    .out_addr_o    ( lookup_addr        ),
    .out_id_o      ( lookup_id          ),
    .out_set_o     ( lookup_set         ),
    .out_hit_o     ( lookup_hit         ),
    .out_data_o    ( lookup_data        ),
    .out_error_o   ( lookup_error       ),
    .out_valid_o   ( lookup_valid       ),
    .out_ready_i   ( lookup_ready       ),
    .write_addr_i  ( write_addr         ),
    .write_set_i   ( write_set          ),
    .write_data_i  ( write_data         ),
    .write_tag_i   ( write_tag          ),
    .write_error_i ( write_error        ),
    .write_valid_i ( write_valid        ),
    .write_ready_o ( write_ready        ),
    .sram_cfg_tag_i,
    .sram_cfg_data_i
  );

  snitch_icache_handler #(CFG) i_handler (
    .clk_i,
    .rst_ni,
    .in_req_addr_i   ( lookup_addr       ),
    .in_req_id_i     ( lookup_id         ),
    .in_req_set_i    ( lookup_set        ),
    .in_req_hit_i    ( lookup_hit        ),
    .in_req_data_i   ( lookup_data       ),
    .in_req_error_i  ( lookup_error      ),
    .in_req_valid_i  ( lookup_valid      ),
    .in_req_ready_o  ( lookup_ready      ),
    .in_rsp_data_o   ( in_rsp_data       ),
    .in_rsp_error_o  ( in_rsp_error      ),
    .in_rsp_id_o     ( in_rsp_id         ),
    .in_rsp_valid_o  ( in_rsp_valid      ),
    .in_rsp_ready_i  ( in_rsp_ready      ),
    .write_addr_o    ( write_addr        ),
    .write_set_o     ( write_set         ),
    .write_data_o    ( write_data        ),
    .write_tag_o     ( write_tag         ),
    .write_error_o   ( write_error       ),
    .write_valid_o   ( write_valid       ),
    .write_ready_i   ( write_ready       ),
    .out_req_addr_o  ( handler_req_addr  ),
    .out_req_id_o    ( handler_req_id    ),
    .out_req_valid_o ( handler_req_valid ),
    .out_req_ready_i ( handler_req_ready ),
    .out_rsp_data_i  ( handler_rsp_data  ),
    .out_rsp_error_i ( handler_rsp_error ),
    .out_rsp_id_i    ( handler_rsp_id    ),
    .out_rsp_valid_i ( handler_rsp_valid ),
    .out_rsp_ready_o ( handler_rsp_ready )
  );

  snitch_ro_cache_refill #(
    .CFG       ( CFG        ),
    .axi_req_t ( axi_req_t  ),
    .axi_rsp_t ( axi_resp_t )
  ) i_refill (
    .clk_i,
    .rst_ni,
    .in_req_addr_i   ( handler_req_addr  ),
    .in_req_id_i     ( handler_req_id    ),
    .in_req_bypass_i ( 1'b0              ),
    .in_req_valid_i  ( handler_req_valid ),
    .in_req_ready_o  ( handler_req_ready ),
    .in_rsp_data_o   ( handler_rsp_data  ),
    .in_rsp_error_o  ( handler_rsp_error ),
    .in_rsp_id_o     ( handler_rsp_id    ),
    .in_rsp_bypass_o (                   ),
    .in_rsp_valid_o  ( handler_rsp_valid ),
    .in_rsp_ready_i  ( handler_rsp_ready ),
    .axi_req_o       ( refill_req        ),
    .axi_rsp_i       ( refill_rsp        )
  );

  axi_mux #(
    .SlvAxiIDWidth ( AxiIdWidth        ),
    .slv_aw_chan_t ( axi_aw_chan_t     ),
    .mst_aw_chan_t ( axi_mst_aw_chan_t ),
    .w_chan_t      ( axi_w_chan_t      ),
    .slv_b_chan_t  ( axi_b_chan_t      ),
    .mst_b_chan_t  ( axi_mst_b_chan_t  ),
    .slv_ar_chan_t ( axi_ar_chan_t     ),
    .mst_ar_chan_t ( axi_mst_ar_chan_t ),
    .slv_r_chan_t  ( axi_r_chan_t      ),
    .mst_r_chan_t  ( axi_mst_r_chan_t  ),
    .slv_req_t     ( axi_req_t         ),
    .slv_resp_t    ( axi_resp_t        ),
    .mst_req_t     ( axi_mst_req_t     ),
    .mst_resp_t    ( axi_mst_resp_t    ),
    .NoSlvPorts    ( NoMstPorts        ),
    .MaxWTrans     ( MaxTrans          ),
    .FallThrough   ( 1'b1              ),
    .SpillAw       ( 1'b0              ),
    .SpillW        ( 1'b0              ),
    .SpillB        ( 1'b0              ),
    .SpillAr       ( 1'b0              ),
    .SpillR        ( 1'b0              )
  ) i_axi_mux (
    .clk_i,
    .rst_ni,
    .test_i      ( 1'b0                            ),
    .slv_reqs_i  ( {refill_req, demux_req[Bypass]} ),
    .slv_resps_o ( {refill_rsp, demux_rsp[Bypass]} ),
    .mst_req_o   ( axi_mst_req_o                   ),
    .mst_resp_i  ( axi_mst_rsp_i                   )
  );

endmodule
