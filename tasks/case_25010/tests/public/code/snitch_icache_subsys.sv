// Copyright 2020 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// Top-level ASIC physical wrapper for the 2-port, 2-way, 256-line Snitch ICache
// mapped to 6x RM_IHPSG13_1P_256x64_c2_bm_bist hard SRAM macros (2 Tag + 4 Data).

module snitch_icache_subsys (
  input  logic        clk_i,
  input  logic        rst_ni,

  input  logic        enable_prefetching_i,
  input  logic [1:0]  flush_valid_i,
  output logic [1:0]  flush_ready_o,

  input  logic [31:0] inst_addr_0_i,
  input  logic [31:0] inst_addr_1_i,
  output logic [31:0] inst_data_0_o,
  output logic [31:0] inst_data_1_o,
  input  logic [1:0]  inst_cacheable_i,
  input  logic [1:0]  inst_valid_i,
  output logic [1:0]  inst_ready_o,
  output logic [1:0]  inst_error_o,

  output logic [31:0] axi_ar_addr_o,
  output logic [7:0]  axi_ar_len_o,
  output logic [2:0]  axi_ar_size_o,
  output logic [1:0]  axi_ar_burst_o,
  output logic [3:0]  axi_ar_cache_o,
  output logic        axi_ar_valid_o,
  input  logic        axi_ar_ready_i,

  input  logic [63:0] axi_r_data_i,
  input  logic [1:0]  axi_r_resp_i,
  input  logic        axi_r_last_i,
  input  logic        axi_r_valid_i,
  output logic        axi_r_ready_o
);

  typedef struct packed {
    logic [1:0]  id;
    logic [31:0] addr;
    logic [7:0]  len;
    logic [2:0]  size;
    logic [1:0]  burst;
    logic        lock;
    logic [3:0]  cache;
    logic [2:0]  prot;
    logic [3:0]  qos;
    logic [3:0]  region;
    logic        user;
  } icache_ar_chan_t;

  typedef struct packed {
    logic [1:0]  id;
    logic [31:0] addr;
    logic [7:0]  len;
    logic [2:0]  size;
    logic [1:0]  burst;
    logic        lock;
    logic [3:0]  cache;
    logic [2:0]  prot;
    logic [3:0]  qos;
    logic [3:0]  region;
    logic [5:0]  atop;
    logic        user;
  } icache_aw_chan_t;

  typedef struct packed {
    logic [63:0] data;
    logic [7:0]  strb;
    logic        last;
    logic        user;
  } icache_w_chan_t;

  typedef struct packed {
    logic [1:0] id;
    logic [1:0] resp;
    logic       user;
  } icache_b_chan_t;

  typedef struct packed {
    logic [1:0]  id;
    logic [63:0] data;
    logic [1:0]  resp;
    logic        last;
    logic        user;
  } icache_r_chan_t;

  typedef struct packed {
    icache_aw_chan_t aw;
    logic            aw_valid;
    icache_w_chan_t  w;
    logic            w_valid;
    logic            b_ready;
    icache_ar_chan_t ar;
    logic            ar_valid;
    logic            r_ready;
  } icache_axi_req_t;

  typedef struct packed {
    logic           aw_ready;
    logic           ar_ready;
    logic           w_ready;
    logic           b_valid;
    icache_b_chan_t b;
    logic           r_valid;
    icache_r_chan_t r;
  } icache_axi_rsp_t;

  icache_axi_req_t axi_req;
  icache_axi_rsp_t axi_rsp;
  snitch_icache_pkg::icache_events_t [1:0] icache_events_unused;
  logic [1:0][31:0] inst_addr_bus;
  logic [1:0][31:0] inst_data_bus;

  assign inst_addr_bus[0] = inst_addr_0_i;
  assign inst_addr_bus[1] = inst_addr_1_i;
  assign inst_data_0_o    = inst_data_bus[0];
  assign inst_data_1_o    = inst_data_bus[1];

  always_comb begin
    axi_rsp          = '0;
    axi_rsp.ar_ready = axi_ar_ready_i;
    axi_rsp.r_valid  = axi_r_valid_i;
    axi_rsp.r.data   = axi_r_data_i;
    axi_rsp.r.resp   = axi_r_resp_i;
    axi_rsp.r.last   = axi_r_last_i;
  end

  assign axi_ar_addr_o  = axi_req.ar.addr;
  assign axi_ar_len_o   = axi_req.ar.len;
  assign axi_ar_size_o  = axi_req.ar.size;
  assign axi_ar_burst_o = axi_req.ar.burst;
  assign axi_ar_cache_o = axi_req.ar.cache;
  assign axi_ar_valid_o = axi_req.ar_valid;
  assign axi_r_ready_o  = axi_req.r_ready;

  snitch_icache #(
    .NR_FETCH_PORTS     ( 2                ),
    .L0_LINE_COUNT      ( 2                ),
    .LINE_WIDTH         ( 128              ),
    .LINE_COUNT         ( 256              ),
    .SET_COUNT          ( 2                ),
    .FETCH_AW           ( 32               ),
    .FETCH_DW           ( 32               ),
    .FILL_AW            ( 32               ),
    .FILL_DW            ( 64               ),
    .EARLY_LATCH        ( 1'b0             ),
    .L0_EARLY_TAG_WIDTH ( 8                ),
    .ISO_CROSSING       ( 1'b0             ),
    .sram_cfg_data_t    ( logic            ),
    .sram_cfg_tag_t     ( logic            ),
    .axi_req_t          ( icache_axi_req_t ),
    .axi_rsp_t          ( icache_axi_rsp_t )
  ) u_icache (
    .clk_i                ( clk_i                ),
    .clk_d2_i             ( clk_i                ),
    .rst_ni               ( rst_ni               ),
    .enable_prefetching_i ( enable_prefetching_i ),
    .icache_events_o      ( icache_events_unused ),
    .flush_valid_i        ( flush_valid_i        ),
    .flush_ready_o        ( flush_ready_o        ),
    .inst_addr_i          ( inst_addr_bus        ),
    .inst_data_o          ( inst_data_bus        ),
    .inst_cacheable_i     ( inst_cacheable_i     ),
    .inst_valid_i         ( inst_valid_i         ),
    .inst_ready_o         ( inst_ready_o         ),
    .inst_error_o         ( inst_error_o         ),
    .sram_cfg_data_i      ( 1'b0                 ),
    .sram_cfg_tag_i       ( 1'b0                 ),
    .axi_req_o            ( axi_req              ),
    .axi_rsp_i            ( axi_rsp              )
  );

endmodule
