// Copyright 2025 OpenHW Group
// SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1

module wt_axi_subsys_top
  import ariane_pkg::*;
  import wt_cache_pkg::*;
(
  input  logic         clk_i,
  input  logic         rst_ni,
  input  logic         icache_data_req_i,
  output logic         icache_data_ack_o,
  input  logic         icache_rtype_i,
  input  logic [ 31:0] icache_paddr_i,
  input  logic         icache_nc_i,
  input  logic [  1:0] icache_tid_i,
  output logic         icache_rtrn_vld_o,
  output logic         icache_rtrn_rtype_o,
  output logic [127:0] icache_rtrn_data_o,
  output logic [  1:0] icache_rtrn_tid_o,
  input  logic         dcache_data_req_i,
  output logic         dcache_data_ack_o,
  input  logic [  1:0] dcache_rtype_i,
  input  logic [  2:0] dcache_size_i,
  input  logic [ 31:0] dcache_paddr_i,
  input  logic [ 63:0] dcache_wdata_i,
  input  logic         dcache_nc_i,
  input  logic [  1:0] dcache_tid_i,
  input  logic [  3:0] dcache_amo_op_i,
  output logic         dcache_rtrn_vld_o,
  output logic [  1:0] dcache_rtrn_rtype_o,
  output logic [127:0] dcache_rtrn_data_o,
  output logic [  1:0] dcache_rtrn_tid_o,
  output logic [  9:0] dcache_rtrn_inv_idx_o,
  output logic         dcache_rtrn_inv_all_o,
  input  logic         mbe_i,
  input  logic [ 63:0] inval_addr_i,
  input  logic         inval_valid_i,
  output logic         inval_ready_o,
  output logic         aw_valid_o,
  input  logic         aw_ready_i,
  output logic [  3:0] aw_id_o,
  output logic [ 31:0] aw_addr_o,
  output logic [  7:0] aw_len_o,
  output logic [  2:0] aw_size_o,
  output logic         aw_lock_o,
  output logic [  5:0] aw_atop_o,
  output logic         w_valid_o,
  input  logic         w_ready_i,
  output logic [ 63:0] w_data_o,
  output logic [  7:0] w_strb_o,
  output logic         w_last_o,
  input  logic         b_valid_i,
  output logic         b_ready_o,
  input  logic [  3:0] b_id_i,
  input  logic [  1:0] b_resp_i,
  output logic         ar_valid_o,
  input  logic         ar_ready_i,
  output logic [  3:0] ar_id_o,
  output logic [ 31:0] ar_addr_o,
  output logic [  7:0] ar_len_o,
  output logic [  2:0] ar_size_o,
  output logic         ar_lock_o,
  input  logic         r_valid_i,
  output logic         r_ready_o,
  input  logic [  3:0] r_id_i,
  input  logic [ 63:0] r_data_i,
  input  logic [  1:0] r_resp_i,
  input  logic         r_last_i
);
  function automatic config_pkg::cva6_cfg_t make_cfg();
    config_pkg::cva6_cfg_t c;
    c = '0;
    c.XLEN = 64;
    c.IS_XLEN32 = 0;
    c.IS_XLEN64 = 1;
    c.VLEN = 32;
    c.PLEN = 32;
    c.RVA = 1;
    c.AxiAddrWidth = 32;
    c.AxiDataWidth = 64;
    c.AxiIdWidth = 4;
    c.AxiUserWidth = 1;
    c.MEM_TID_WIDTH = 2;
    c.DCACHE_MAX_TX = 2;
    c.ICACHE_LINE_WIDTH = 128;
    c.ICACHE_USER_LINE_WIDTH = 2;
    c.DCACHE_LINE_WIDTH = 128;
    c.DCACHE_USER_LINE_WIDTH = 2;
    c.DCACHE_INDEX_WIDTH = 10;
    c.DCACHE_SET_ASSOC = 4;
    c.DCACHE_SET_ASSOC_WIDTH = 2;
    return c;
  endfunction
  localparam config_pkg::cva6_cfg_t Cfg = make_cfg();

  typedef struct packed {
    logic [9:0] idx;
    logic [1:0] way;
    logic       vld;
    logic       all;
  } dcache_inval_s_t;

  typedef struct packed {
    logic rtype;
    logic [31:0]               paddr;
    logic                      nc;
    logic [ 1:0]               tid;
  } icache_req_s_t;

  typedef struct packed {
    wt_cache_pkg::icache_in_t rtype;
    logic [127:0]             data;
    logic [  1:0]             user;
    dcache_inval_s_t          inv;
    logic [  1:0]             tid;
  } icache_rtrn_s_t;

  typedef struct packed {
    wt_cache_pkg::dcache_out_t rtype;
    logic [ 2:0]               size;
    logic [31:0]               paddr;
    logic [63:0]               data;
    logic                      user;
    logic                      nc;
    logic [ 1:0]               tid;
    ariane_pkg::amo_t          amo_op;
  } dcache_req_s_t;

  typedef struct packed {
    wt_cache_pkg::dcache_in_t rtype;
    logic [127:0]             data;
    logic [  1:0]             user;
    dcache_inval_s_t          inv;
    logic [  1:0]             tid;
  } dcache_rtrn_s_t;

  typedef struct packed {
    logic [ 3:0] id;
    logic [31:0] addr;
    logic [ 7:0] len;
    logic [ 2:0] size;
    logic [ 1:0] burst;
    logic        lock;
    logic [ 3:0] cache;
    logic [ 2:0] prot;
    logic [ 3:0] qos;
    logic [ 3:0] region;
    logic [ 5:0] atop;
    logic        user;
  } aw_chan_s_t;

  typedef struct packed {
    logic [63:0] data;
    logic [ 7:0] strb;
    logic        last;
    logic        user;
  } w_chan_s_t;

  typedef struct packed {
    logic [ 3:0] id;
    logic [31:0] addr;
    logic [ 7:0] len;
    logic [ 2:0] size;
    logic [ 1:0] burst;
    logic        lock;
    logic [ 3:0] cache;
    logic [ 2:0] prot;
    logic [ 3:0] qos;
    logic [ 3:0] region;
    logic        user;
  } ar_chan_s_t;

  typedef struct packed {
    logic [ 3:0] id;
    logic [ 1:0] resp;
    logic        user;
  } b_chan_s_t;

  typedef struct packed {
    logic [ 3:0] id;
    logic [63:0] data;
    logic [ 1:0] resp;
    logic        last;
    logic        user;
  } r_chan_s_t;

  typedef struct packed {
    aw_chan_s_t aw;
    logic       aw_valid;
    w_chan_s_t  w;
    logic       w_valid;
    logic       b_ready;
    ar_chan_s_t ar;
    logic       ar_valid;
    logic       r_ready;
  } axi_req_s_t;

  typedef struct packed {
    logic      aw_ready;
    logic      ar_ready;
    logic      w_ready;
    logic      b_valid;
    b_chan_s_t b;
    logic      r_valid;
    r_chan_s_t r;
  } axi_rsp_s_t;

  icache_req_s_t  ic_req;
  icache_rtrn_s_t ic_rtrn;
  dcache_req_s_t  dc_req;
  dcache_rtrn_s_t dc_rtrn;
  axi_req_s_t     axi_req;
  axi_rsp_s_t     axi_rsp;

  assign ic_req = '{
    rtype: logic'(icache_rtype_i),
    paddr: icache_paddr_i,
    nc:    icache_nc_i,
    tid:   icache_tid_i
  };

  assign dc_req = '{
    rtype:  wt_cache_pkg::dcache_out_t'(dcache_rtype_i),
    size:   dcache_size_i,
    paddr:  dcache_paddr_i,
    data:   dcache_wdata_i,
    user:   1'b0,
    nc:     dcache_nc_i,
    tid:    dcache_tid_i,
    amo_op: ariane_pkg::amo_t'(dcache_amo_op_i)
  };

  assign axi_rsp = '{
    aw_ready: aw_ready_i,
    ar_ready: ar_ready_i,
    w_ready:  w_ready_i,
    b_valid:  b_valid_i,
    b:        '{id: b_id_i, resp: b_resp_i, user: 1'b0},
    r_valid:  r_valid_i,
    r:        '{id: r_id_i, data: r_data_i, resp: r_resp_i, last: r_last_i, user: 1'b0}
  };

  wt_axi_adapter #(
    .CVA6Cfg       (Cfg),
    .ReqFifoDepth  (2),
    .MetaFifoDepth (2),
    .axi_req_t     (axi_req_s_t),
    .axi_rsp_t     (axi_rsp_s_t),
    .dcache_req_t  (dcache_req_s_t),
    .dcache_rtrn_t (dcache_rtrn_s_t),
    .dcache_inval_t(dcache_inval_s_t),
    .icache_req_t  (icache_req_s_t),
    .icache_rtrn_t (icache_rtrn_s_t)
  ) u_dut (
    .clk_i            (clk_i),
    .rst_ni           (rst_ni),
    .icache_data_req_i(icache_data_req_i),
    .icache_data_ack_o(icache_data_ack_o),
    .icache_data_i    (ic_req),
    .icache_rtrn_vld_o(icache_rtrn_vld_o),
    .icache_rtrn_o    (ic_rtrn),
    .dcache_data_req_i(dcache_data_req_i),
    .dcache_data_ack_o(dcache_data_ack_o),
    .dcache_data_i    (dc_req),
    .dcache_rtrn_vld_o(dcache_rtrn_vld_o),
    .dcache_rtrn_o    (dc_rtrn),
    .axi_req_o        (axi_req),
    .axi_resp_i       (axi_rsp),
    .mbe_i            (mbe_i),
    .inval_addr_i     (inval_addr_i),
    .inval_valid_i    (inval_valid_i),
    .inval_ready_o    (inval_ready_o)
  );

  assign icache_rtrn_rtype_o   = ic_rtrn.rtype;
  assign icache_rtrn_data_o    = ic_rtrn.data;
  assign icache_rtrn_tid_o     = ic_rtrn.tid;

  assign dcache_rtrn_rtype_o   = dc_rtrn.rtype;
  assign dcache_rtrn_data_o    = dc_rtrn.data;
  assign dcache_rtrn_tid_o     = dc_rtrn.tid;
  assign dcache_rtrn_inv_idx_o = dc_rtrn.inv.idx;
  assign dcache_rtrn_inv_all_o = dc_rtrn.inv.all;

  assign aw_valid_o = axi_req.aw_valid;
  assign aw_id_o    = axi_req.aw.id;
  assign aw_addr_o  = axi_req.aw.addr;
  assign aw_len_o   = axi_req.aw.len;
  assign aw_size_o  = axi_req.aw.size;
  assign aw_lock_o  = axi_req.aw.lock;
  assign aw_atop_o  = axi_req.aw.atop;

  assign w_valid_o  = axi_req.w_valid;
  assign w_data_o   = axi_req.w.data;
  assign w_strb_o   = axi_req.w.strb;
  assign w_last_o   = axi_req.w.last;

  assign b_ready_o  = axi_req.b_ready;

  assign ar_valid_o = axi_req.ar_valid;
  assign ar_id_o    = axi_req.ar.id;
  assign ar_addr_o  = axi_req.ar.addr;
  assign ar_len_o   = axi_req.ar.len;
  assign ar_size_o  = axi_req.ar.size;
  assign ar_lock_o  = axi_req.ar.lock;

  assign r_ready_o  = axi_req.r_ready;
endmodule
