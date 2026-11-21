module ibex_trvk_bridge_top #(
  parameter int unsigned NumOutstanding     = 32'd4,
  parameter int unsigned RevBitmapAddrWidth = 32'd11,
  parameter int unsigned RevBitmapBaseAddr  = 32'h0000_0000,
  parameter bit          MemECC             = 1'b1
) (
  input  logic        clk_i,
  input  logic        rst_ni,
  input  logic        flush_i,
  input  logic [31:0] heap_base_addr_i,

  // Upstream OBI port
  input  logic        upstream_req_i,
  output logic        upstream_gnt_o,
  output logic        upstream_rvalid_o,
  input  logic        upstream_rready_i,
  input  logic        upstream_we_i,
  input  logic [3:0]  upstream_be_i,
  input  logic [31:0] upstream_addr_i,
  input  logic [31:0] upstream_wdata_i,
  input  logic [6:0]  upstream_wdata_intg_i,
  output logic [31:0] upstream_rdata_o,
  output logic [6:0]  upstream_rdata_intg_o,
  output logic        upstream_err_o,
  input  logic        upstream_tag_i,
  output logic        upstream_tag_o,

  // Downstream OBI port
  output logic        downstream_req_o,
  input  logic        downstream_gnt_i,
  input  logic        downstream_rvalid_i,
  output logic        downstream_we_o,
  output logic [3:0]  downstream_be_o,
  output logic [31:0] downstream_addr_o,
  output logic [31:0] downstream_wdata_o,
  output logic [6:0]  downstream_wdata_intg_o,
  input  logic [31:0] downstream_rdata_i,
  input  logic [6:0]  downstream_rdata_intg_i,
  input  logic        downstream_err_i,
  output logic        downstream_tag_o,
  input  logic        downstream_tag_i,

  // Revocation bitmap memory port
  output logic        revbm_req_o,
  input  logic        revbm_gnt_i,
  input  logic        revbm_rvalid_i,
  output logic [31:0] revbm_addr_o,
  input  logic [31:0] revbm_rdata_i,
  input  logic [6:0]  revbm_rdata_intg_i,
  input  logic        revbm_err_i,

  // Error signals
  output logic        revbm_data_intg_error_o,
  output logic        revbm_device_error_o,

  // Zero-cut transparent alert & trace channels
  input  logic [7:0]  alert_in,
  output logic [7:0]  alert_out,
  input  logic [7:0]  trace_in,
  output logic [7:0]  trace_out
);
  assign alert_out = alert_in;
  assign trace_out = trace_in;

  ibex_trvk #(
    .NumOutstanding     ( NumOutstanding     ),
    .RevBitmapAddrWidth ( RevBitmapAddrWidth ),
    .RevBitmapBaseAddr  ( RevBitmapBaseAddr  ),
    .MemECC             ( MemECC             )
  ) u_trvk (
    .clk_i,
    .rst_ni,
    .flush_i,
    .heap_base_addr_i,
    .upstream_req_i,
    .upstream_gnt_o,
    .upstream_rvalid_o,
    .upstream_rready_i,
    .upstream_we_i,
    .upstream_be_i,
    .upstream_addr_i,
    .upstream_wdata_i,
    .upstream_wdata_intg_i,
    .upstream_rdata_o,
    .upstream_rdata_intg_o,
    .upstream_err_o,
    .upstream_tag_i,
    .upstream_tag_o,
    .downstream_req_o,
    .downstream_gnt_i,
    .downstream_rvalid_i,
    .downstream_we_o,
    .downstream_be_o,
    .downstream_addr_o,
    .downstream_wdata_o,
    .downstream_wdata_intg_o,
    .downstream_rdata_i,
    .downstream_rdata_intg_i,
    .downstream_err_i,
    .downstream_tag_o,
    .downstream_tag_i,
    .revbm_req_o,
    .revbm_gnt_i,
    .revbm_rvalid_i,
    .revbm_addr_o,
    .revbm_rdata_i,
    .revbm_rdata_intg_i,
    .revbm_err_i,
    .revbm_data_intg_error_o,
    .revbm_device_error_o
  );
endmodule
