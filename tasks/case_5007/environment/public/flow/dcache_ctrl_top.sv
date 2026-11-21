module dcache_ctrl_top import ariane_pkg::*; import std_cache_pkg::*; (
  input  logic         clk_i,
  input  logic         rst_ni,
  input  logic         flush_i,
  input  logic         bypass_i,
  output logic         busy_o,
  input  logic [11:0]  req_index_i,
  input  logic [43:0]  req_tag_i,
  input  logic [63:0]  req_wdata_i,
  input  logic         req_valid_i,
  input  logic         req_we_i,
  input  logic [ 7:0]  req_be_i,
  input  logic [ 1:0]  req_size_i,
  input  logic [ 1:0]  req_id_i,
  input  logic         req_kill_i,
  input  logic         req_tag_valid_i,
  output logic         rsp_gnt_o,
  output logic         rsp_rvalid_o,
  output logic [ 1:0]  rsp_rid_o,
  output logic [63:0]  rsp_rdata_o,
  input  logic [ 1:0][43:0] sram_tag_i,
  input  logic [ 1:0][127:0] sram_data_i,
  input  logic [ 1:0]  sram_valid_i,
  input  logic [ 1:0]  sram_dirty_i,
  input  logic [ 1:0]  other_req_i,
  input  logic [11:0]  other_addr_i,
  input  logic [43:0]  other_tag_i,
  output logic [ 1:0]  sram_req_o,
  output logic [11:0]  sram_addr_o,
  output logic         sram_we_o,
  output logic [43:0]  sram_wtag_o,
  output logic [127:0] sram_wdata_o,
  output logic [15:0]  sram_be_data_o,
  output logic [ 1:0]  sram_be_vldrty_o,
  output logic [ 1:0]  arb_gnt_o,
  output logic         miss_valid_o,
  output logic         miss_bypass_o,
  output logic [63:0]  miss_addr_o,
  output logic [63:0]  miss_wdata_o,
  output logic         miss_we_o,
  output logic [ 7:0]  miss_be_o,
  output logic [ 1:0]  miss_size_o,
  input  logic         miss_gnt_i,
  input  logic         active_serving_i,
  input  logic [63:0]  critical_word_i,
  input  logic         critical_word_valid_i,
  input  logic         bypass_gnt_i,
  input  logic         bypass_valid_i,
  input  logic [63:0]  bypass_data_i,
  output logic [55:0]  mshr_addr_o,
  input  logic         mshr_addr_matches_i,
  input  logic         mshr_index_matches_i
);
  function automatic config_pkg::cva6_cfg_t make_cfg();
    config_pkg::cva6_cfg_t c;
    c = '0;
    c.XLEN = 64; c.IS_XLEN64 = 1; c.PLEN = 56;
    c.AxiDataWidth = 64; c.AxiAddrWidth = 64; c.AxiIdWidth = 4;
    c.DCACHE_SET_ASSOC = 2; c.DCACHE_SET_ASSOC_WIDTH = 1;
    c.DCACHE_INDEX_WIDTH = 12; c.DCACHE_TAG_WIDTH = 44;
    c.DCACHE_LINE_WIDTH = 128; c.DCACHE_OFFSET_WIDTH = 4;
    c.DCACHE_NUM_WORDS = 256; c.DcacheIdWidth = 2;
    c.NrCachedRegionRules = 1;
    c.CachedRegionAddrBase[0] = 64'h8000_0000;
    c.CachedRegionLength[0]   = 64'h1000_0000;
    return c;
  endfunction
  localparam config_pkg::cva6_cfg_t Cfg = make_cfg();
  typedef struct packed { logic [43:0] tag; logic [127:0] data; logic valid; logic dirty; } cache_line_t;
  typedef struct packed { logic [5:0] tag; logic [15:0] data; logic [1:0] vldrty; } cl_be_t;
  typedef struct packed { logic [11:0] address_index; logic [43:0] address_tag; logic [63:0] data_wdata; logic [7:0] data_wuser; logic data_req; logic data_we; logic [7:0] data_be; logic [1:0] data_size; logic [1:0] data_id; logic kill_req; logic tag_valid; logic [7:0] cbo_op; } dcache_req_i_t;
  typedef struct packed { logic data_gnt; logic data_rvalid; logic [1:0] data_rid; logic [63:0] data_rdata; logic data_error; logic [7:0] data_ruser; } dcache_req_o_t;

  dcache_req_i_t req_p;
  dcache_req_o_t rsp_p;
  miss_req_t     miss_req;
  cache_line_t [1:0] rdata_ram, rdata_arb, wdata_ports;
  cl_be_t      [1:0] be_ports;
  logic        [1:0][1:0] req_ports;
  logic        [1:0][11:0] addr_ports;
  logic        [1:0][43:0] tag_ports;
  logic        [1:0] we_ports, gnt_ports, hit_way;
  cache_line_t wdata_ram;
  cl_be_t      be_ram;

  assign req_p = '{
    address_index: req_index_i, address_tag: req_tag_i, data_wdata: req_wdata_i,
    data_wuser: '0, data_req: req_valid_i, data_we: req_we_i, data_be: req_be_i,
    data_size: req_size_i, data_id: req_id_i, kill_req: req_kill_i,
    tag_valid: req_tag_valid_i, cbo_op: '0
  };
  assign rsp_gnt_o    = rsp_p.data_gnt;
  assign rsp_rvalid_o = rsp_p.data_rvalid;
  assign rsp_rid_o    = rsp_p.data_rid;
  assign rsp_rdata_o  = rsp_p.data_rdata;

  for (genvar w = 0; w < 2; w++) begin : gen_ram_in
    assign rdata_ram[w] = '{tag: sram_tag_i[w], data: sram_data_i[w], valid: sram_valid_i[w], dirty: sram_dirty_i[w]};
  end

  assign req_ports[0]   = other_req_i;
  assign addr_ports[0]  = other_addr_i;
  assign tag_ports[0]   = other_tag_i;
  assign wdata_ports[0] = '0;
  assign we_ports[0]    = 1'b0;
  assign be_ports[0]    = '0;

  cache_ctrl #(
    .CVA6Cfg(Cfg), .cache_line_t(cache_line_t), .cl_be_t(cl_be_t),
    .dcache_req_i_t(dcache_req_i_t), .dcache_req_o_t(dcache_req_o_t)
  ) u_ctrl (
    .clk_i, .rst_ni, .flush_i, .bypass_i, .busy_o,
    .req_port_i(req_p), .req_port_o(rsp_p),
    .req_o(req_ports[1]), .addr_o(addr_ports[1]), .gnt_i(gnt_ports[1]),
    .data_o(wdata_ports[1]), .be_o(be_ports[1]), .tag_o(tag_ports[1]),
    .data_i(rdata_arb), .we_o(we_ports[1]), .hit_way_i(hit_way),
    .miss_req_o(miss_req), .miss_gnt_i, .active_serving_i,
    .critical_word_i, .critical_word_valid_i,
    .bypass_gnt_i, .bypass_valid_i, .bypass_data_i,
    .mshr_addr_o, .mshr_addr_matches_i, .mshr_index_matches_i
  );

  tag_cmp #(
    .CVA6Cfg(Cfg), .NR_PORTS(2), .ADDR_WIDTH(12),
    .l_data_t(cache_line_t), .l_be_t(cl_be_t)
  ) u_tag_cmp (
    .clk_i, .rst_ni,
    .req_i(req_ports), .gnt_o(gnt_ports), .addr_i(addr_ports),
    .wdata_i(wdata_ports), .we_i(we_ports), .be_i(be_ports),
    .rdata_o(rdata_arb), .tag_i(tag_ports), .hit_way_o(hit_way),
    .req_o(sram_req_o), .addr_o(sram_addr_o), .wdata_o(wdata_ram),
    .we_o(sram_we_o), .be_o(be_ram), .rdata_i(rdata_ram)
  );

  assign arb_gnt_o        = gnt_ports;
  assign sram_wtag_o      = wdata_ram.tag;
  assign sram_wdata_o     = wdata_ram.data;
  assign sram_be_data_o   = be_ram.data;
  assign sram_be_vldrty_o = be_ram.vldrty;

  assign miss_valid_o  = miss_req.valid;
  assign miss_bypass_o = miss_req.bypass;
  assign miss_addr_o   = miss_req.addr;
  assign miss_wdata_o  = miss_req.wdata;
  assign miss_we_o     = miss_req.we;
  assign miss_be_o     = miss_req.be;
  assign miss_size_o   = miss_req.size;
endmodule
