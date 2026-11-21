module icache_axi_top import ariane_pkg::*; import wt_cache_pkg::*; (
  input  logic         clk_i,
  input  logic         rst_ni,
  input  logic         flush_i,
  input  logic         en_i,
  output logic         miss_o,
  input  logic         areq_valid_i,
  input  logic [33:0]  areq_paddr_i,
  input  logic         areq_ex_valid_i,
  output logic         areq_req_o,
  output logic [31:0]  areq_vaddr_o,
  input  logic         dreq_req_i,
  input  logic         dreq_kill_s1_i,
  input  logic         dreq_kill_s2_i,
  input  logic         dreq_spec_i,
  input  logic [31:0]  dreq_vaddr_i,
  output logic         dreq_ready_o,
  output logic         dreq_valid_o,
  output logic [31:0]  dreq_data_o,
  output logic [31:0]  dreq_vaddr_o,
  output logic         dreq_ex_valid_o,
  output logic         ar_valid_o,
  input  logic         ar_ready_i,
  output logic [33:0]  ar_addr_o,
  output logic [ 0:0]  ar_len_o,
  output logic [ 2:0]  ar_size_o,
  output logic [ 1:0]  ar_id_o,
  input  logic         r_valid_i,
  output logic         r_ready_o,
  input  logic [63:0]  r_data_i,
  input  logic         r_last_i,
  input  logic [ 1:0]  r_id_i,
  input  logic [ 1:0]  r_resp_i,
  input  logic         wr_req_i,
  output logic         wr_gnt_o,
  input  logic [33:0]  wr_addr_i,
  input  logic [ 1:0][63:0] wr_data_i,
  input  logic [ 1:0][ 7:0] wr_be_i,
  input  logic [ 0:0]  wr_blen_i,
  input  logic [ 2:0]  wr_size_i,
  input  logic [ 1:0]  wr_id_i,
  input  logic         wr_lock_i,
  input  logic [ 5:0]  wr_atop_i,
  input  logic         wr_rdy_i,
  output logic         wr_valid_o,
  output logic [ 1:0]  wr_id_o,
  output logic         wr_exokay_o,
  output logic         aw_valid_o,
  input  logic         aw_ready_i,
  output logic [33:0]  aw_addr_o,
  output logic [ 0:0]  aw_len_o,
  output logic [ 2:0]  aw_size_o,
  output logic [ 1:0]  aw_id_o,
  output logic         aw_lock_o,
  output logic [ 5:0]  aw_atop_o,
  output logic         w_valid_o,
  input  logic         w_ready_i,
  output logic [63:0]  w_data_o,
  output logic [ 7:0]  w_strb_o,
  output logic         w_last_o,
  input  logic         b_valid_i,
  output logic         b_ready_o,
  input  logic [ 1:0]  b_id_i,
  input  logic [ 1:0]  b_resp_i
);
  function automatic config_pkg::cva6_cfg_t make_cfg();
    config_pkg::cva6_cfg_t c;
    c = '0;
    c.XLEN = 32; c.IS_XLEN32 = 1; c.VLEN = 32; c.PLEN = 34;
    c.FETCH_WIDTH = 32; c.FETCH_ALIGN_BITS = 2; c.FETCH_USER_WIDTH = 32; c.FETCH_USER_EN = 0;
    c.ICACHE_SET_ASSOC = 2; c.ICACHE_SET_ASSOC_WIDTH = 1;
    c.ICACHE_INDEX_WIDTH = 5; c.ICACHE_TAG_WIDTH = 29;
    c.ICACHE_LINE_WIDTH = 128; c.ICACHE_USER_LINE_WIDTH = 128;
    c.DCACHE_LINE_WIDTH = 128;
    c.MEM_TID_WIDTH = 2;
    c.AxiAddrWidth = 34; c.AxiDataWidth = 64; c.AxiIdWidth = 2; c.AxiUserWidth = 1;
    c.AxiBurstWriteEn = 1; c.NOCType = config_pkg::NOC_TYPE_AXI4_ATOP;
    c.NonIdemPotenceEn = 1;
    c.NrCachedRegionRules = 1;
    c.CachedRegionAddrBase[0] = 64'h8000_0000;
    c.CachedRegionLength[0]   = 64'h1000_0000;
    c.NrNonIdempotentRules = 1;
    c.NonIdempotentAddrBase[0] = 64'h8800_0000;
    c.NonIdempotentLength[0]   = 64'h0100_0000;
    return c;
  endfunction
  localparam config_pkg::cva6_cfg_t Cfg = make_cfg();

  typedef struct packed { logic [31:0] cause; logic [31:0] tval; logic [33:0] tval2; logic [31:0] tinst; logic gva; logic valid; logic timing; } ex_s_t;
  typedef struct packed { logic fetch_valid; logic [33:0] fetch_paddr; ex_s_t fetch_exception; } icache_areq_s_t;
  typedef struct packed { logic fetch_req; logic [31:0] fetch_vaddr; } icache_arsp_s_t;
  typedef struct packed { logic req; logic kill_s1; logic kill_s2; logic spec; logic [31:0] vaddr; } icache_dreq_s_t;
  typedef struct packed { logic ready; logic valid; logic [31:0] data; logic [31:0] user; logic [31:0] vaddr; ex_s_t ex; } icache_drsp_s_t;
  typedef struct packed { logic vld; logic all; logic [4:0] idx; logic [0:0] way; } icache_inval_s_t;
  typedef struct packed { logic [0:0] way; logic [33:0] paddr; logic nc; logic [1:0] tid; } icache_req_s_t;
  typedef struct packed { wt_cache_pkg::icache_in_t rtype; logic [127:0] data; logic [127:0] user; icache_inval_s_t inv; logic [1:0] tid; } icache_rtrn_s_t;

  typedef struct packed { logic [33:0] addr; logic [2:0] size; logic [0:0] len; logic [1:0] id; logic [1:0] burst; logic [2:0] prot; logic [3:0] region; logic lock; logic [3:0] cache; logic [3:0] qos; logic [5:0] atop; logic user; } aw_chan_t;
  typedef struct packed { logic [63:0] data; logic [7:0] strb; logic last; logic user; } w_chan_t;
  typedef struct packed { logic [1:0] id; logic [1:0] resp; } b_chan_t;
  typedef struct packed { logic [33:0] addr; logic [2:0] size; logic [0:0] len; logic [1:0] id; logic [1:0] burst; logic [2:0] prot; logic [3:0] region; logic lock; logic [3:0] cache; logic [3:0] qos; logic user; } ar_chan_t;
  typedef struct packed { logic [63:0] data; logic last; logic [1:0] id; logic [1:0] resp; logic user; } r_chan_t;
  typedef struct packed { aw_chan_t aw; logic aw_valid; w_chan_t w; logic w_valid; logic b_ready; ar_chan_t ar; logic ar_valid; logic r_ready; } axi_req_s_t;
  typedef struct packed { logic aw_ready; logic w_ready; b_chan_t b; logic b_valid; logic ar_ready; r_chan_t r; logic r_valid; } axi_rsp_s_t;

  icache_areq_s_t areq_i_s;
  icache_arsp_s_t areq_o_s;
  icache_dreq_s_t dreq_i_s;
  icache_drsp_s_t dreq_o_s;
  axi_req_s_t ic_axi_req, wr_axi_req;
  axi_rsp_s_t ic_axi_rsp, wr_axi_rsp;

  assign areq_i_s = '{fetch_valid: areq_valid_i, fetch_paddr: areq_paddr_i, fetch_exception: '{cause: '0, tval: '0, tval2: '0, tinst: '0, gva: 1'b0, valid: areq_ex_valid_i, timing: 1'b0}};
  assign areq_req_o   = areq_o_s.fetch_req;
  assign areq_vaddr_o = areq_o_s.fetch_vaddr;

  assign dreq_i_s = '{req: dreq_req_i, kill_s1: dreq_kill_s1_i, kill_s2: dreq_kill_s2_i, spec: dreq_spec_i, vaddr: dreq_vaddr_i};
  assign dreq_ready_o    = dreq_o_s.ready;
  assign dreq_valid_o    = dreq_o_s.valid;
  assign dreq_data_o     = dreq_o_s.data;
  assign dreq_vaddr_o    = dreq_o_s.vaddr;
  assign dreq_ex_valid_o = dreq_o_s.ex.valid;

  assign ic_axi_rsp = '{aw_ready: 1'b0, w_ready: 1'b0, b: '0, b_valid: 1'b0, ar_ready: ar_ready_i, r: '{data: r_data_i, last: r_last_i, id: r_id_i, resp: r_resp_i, user: 1'b0}, r_valid: r_valid_i};
  assign ar_valid_o = ic_axi_req.ar_valid;
  assign ar_addr_o  = ic_axi_req.ar.addr;
  assign ar_len_o   = ic_axi_req.ar.len;
  assign ar_size_o  = ic_axi_req.ar.size;
  assign ar_id_o    = ic_axi_req.ar.id;
  assign r_ready_o  = ic_axi_req.r_ready;

  cva6_icache_axi_wrapper #(
    .CVA6Cfg(Cfg), .icache_areq_t(icache_areq_s_t), .icache_arsp_t(icache_arsp_s_t),
    .icache_dreq_t(icache_dreq_s_t), .icache_drsp_t(icache_drsp_s_t),
    .icache_req_t(icache_req_s_t), .icache_rtrn_t(icache_rtrn_s_t),
    .axi_req_t(axi_req_s_t), .axi_rsp_t(axi_rsp_s_t)
  ) u_icache_wrap (
    .clk_i, .rst_ni, .priv_lvl_i(riscv::PRIV_LVL_M),
    .flush_i, .en_i, .miss_o,
    .areq_i(areq_i_s), .areq_o(areq_o_s),
    .dreq_i(dreq_i_s), .dreq_o(dreq_o_s),
    .axi_req_o(ic_axi_req), .axi_resp_i(ic_axi_rsp)
  );

  assign wr_axi_rsp = '{aw_ready: aw_ready_i, w_ready: w_ready_i, b: '{id: b_id_i, resp: b_resp_i}, b_valid: b_valid_i, ar_ready: 1'b0, r: '0, r_valid: 1'b0};
  axi_shim #(
    .CVA6Cfg(Cfg), .AxiNumWords(2), .axi_req_t(axi_req_s_t), .axi_rsp_t(axi_rsp_s_t)
  ) u_wr_shim (
    .clk_i, .rst_ni,
    .rd_req_i(1'b0), .rd_gnt_o(), .rd_addr_i('0), .rd_blen_i('0), .rd_size_i('0), .rd_id_i('0), .rd_lock_i(1'b0), .rd_rdy_i(1'b0),
    .rd_last_o(), .rd_valid_o(), .rd_data_o(), .rd_user_o(), .rd_id_o(), .rd_exokay_o(),
    .wr_req_i, .wr_gnt_o, .wr_addr_i, .wr_data_i, .wr_user_i('0), .wr_be_i, .wr_blen_i, .wr_size_i, .wr_id_i, .wr_lock_i, .wr_atop_i, .wr_rdy_i,
    .wr_valid_o, .wr_id_o, .wr_exokay_o,
    .axi_req_o(wr_axi_req), .axi_resp_i(wr_axi_rsp)
  );

  assign aw_valid_o = wr_axi_req.aw_valid;
  assign aw_addr_o  = wr_axi_req.aw.addr;
  assign aw_len_o   = wr_axi_req.aw.len;
  assign aw_size_o  = wr_axi_req.aw.size;
  assign aw_id_o    = wr_axi_req.aw.id;
  assign aw_lock_o  = wr_axi_req.aw.lock;
  assign aw_atop_o  = wr_axi_req.aw.atop;
  assign w_valid_o  = wr_axi_req.w_valid;
  assign w_data_o   = wr_axi_req.w.data;
  assign w_strb_o   = wr_axi_req.w.strb;
  assign w_last_o   = wr_axi_req.w.last;
  assign b_ready_o  = wr_axi_req.b_ready;
endmodule
