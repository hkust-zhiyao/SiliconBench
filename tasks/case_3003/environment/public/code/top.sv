module top (
  input  logic        clk_i,
  input  logic        rst_ni,
  input  logic        flush_i,

  // Upstream request stream
  input  logic [31:0] req_addr,
  input  logic        req_we,
  input  logic [ 3:0] req_be,
  input  logic [31:0] req_wdata,
  input  logic [ 5:0] req_atop,
  input  logic        req_valid,
  output logic        req_ready,

  // Upstream response stream
  output logic [31:0] resp_rdata,
  output logic        resp_err,
  output logic        resp_valid,
  input  logic        resp_ready,

  // Downstream OBI interface
  output logic        obi_req,
  input  logic        obi_gnt,
  output logic [31:0] obi_addr,
  output logic        obi_we,
  output logic [ 3:0] obi_be,
  output logic [31:0] obi_wdata,
  output logic [ 5:0] obi_atop,
  input  logic [31:0] obi_rdata,
  input  logic        obi_rvalid,
  input  logic        obi_err,

  // Transparent zero-cut status/region channels
  input  logic [ 7:0] pmp_in,
  output logic [ 7:0] pmp_out,
  input  logic [ 7:0] dbg_in,
  output logic [ 7:0] dbg_out
);

  typedef struct packed {
    logic [31:0] addr;
    logic        we;
    logic [ 3:0] be;
    logic [31:0] wdata;
    logic [ 5:0] atop;
  } mem_req_t;

  typedef struct packed {
    logic [31:0] rdata;
    logic        err;
  } mem_resp_t;

  mem_req_t  req_s, mem_req;
  mem_resp_t resp_s, mem_resp;
  logic      mem_req_valid, mem_req_ready, mem_resp_valid;

  assign req_s = '{
    addr:  req_addr,
    we:    req_we,
    be:    req_be,
    wdata: req_wdata,
    atop:  req_atop
  };

  assign resp_rdata = resp_s.rdata;
  assign resp_err   = resp_s.err;

  stream_to_mem #(
    .mem_req_t  ( mem_req_t  ),
    .mem_resp_t ( mem_resp_t ),
    .BufDepth   ( 32'd4      )
  ) u_stream_to_mem (
    .clk_i            ( clk_i          ),
    .rst_ni           ( rst_ni         ),
    .flush_i          ( flush_i        ),
    .req_i            ( req_s          ),
    .req_valid_i      ( req_valid      ),
    .req_ready_o      ( req_ready      ),
    .resp_o           ( resp_s         ),
    .resp_valid_o     ( resp_valid     ),
    .resp_ready_i     ( resp_ready     ),
    .mem_req_o        ( mem_req        ),
    .mem_req_valid_o  ( mem_req_valid  ),
    .mem_req_ready_i  ( mem_req_ready  ),
    .mem_resp_i       ( mem_resp       ),
    .mem_resp_valid_i ( mem_resp_valid )
  );

  cv32e40p_obi_interface #(
    .TRANS_STABLE ( 0 )
  ) u_obi_interface (
    .clk           ( clk_i          ),
    .rst_n         ( rst_ni         ),
    .trans_valid_i ( mem_req_valid  ),
    .trans_ready_o ( mem_req_ready  ),
    .trans_addr_i  ( mem_req.addr   ),
    .trans_we_i    ( mem_req.we     ),
    .trans_be_i    ( mem_req.be     ),
    .trans_wdata_i ( mem_req.wdata  ),
    .trans_atop_i  ( mem_req.atop   ),
    .resp_valid_o  ( mem_resp_valid ),
    .resp_rdata_o  ( mem_resp.rdata ),
    .resp_err_o    ( mem_resp.err   ),
    .obi_req_o     ( obi_req        ),
    .obi_gnt_i     ( obi_gnt        ),
    .obi_addr_o    ( obi_addr       ),
    .obi_we_o      ( obi_we         ),
    .obi_be_o      ( obi_be         ),
    .obi_wdata_o   ( obi_wdata      ),
    .obi_atop_o    ( obi_atop       ),
    .obi_rdata_i   ( obi_rdata      ),
    .obi_rvalid_i  ( obi_rvalid     ),
    .obi_err_i     ( obi_err        )
  );

  spill_register #(
    .T      ( logic [7:0] ),
    .Bypass ( 1'b1        )
  ) u_pmp_bypass (
    .clk_i   ( clk_i   ),
    .rst_ni  ( rst_ni  ),
    .valid_i ( 1'b1    ),
    .ready_o (         ),
    .data_i  ( pmp_in  ),
    .valid_o (         ),
    .ready_i ( 1'b1    ),
    .data_o  ( pmp_out )
  );

  spill_register #(
    .T      ( logic [7:0] ),
    .Bypass ( 1'b1        )
  ) u_dbg_bypass (
    .clk_i   ( clk_i   ),
    .rst_ni  ( rst_ni  ),
    .valid_i ( 1'b1    ),
    .ready_o (         ),
    .data_i  ( dbg_in  ),
    .valid_o (         ),
    .ready_i ( 1'b1    ),
    .data_o  ( dbg_out )
  );

endmodule
