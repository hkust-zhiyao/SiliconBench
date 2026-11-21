// Copyright lowRISC contributors (OpenTitan project).
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

`include "prim_assert.sv"

// Assumes a tagged capability load always arrives downstream as exactly two consecutive,
// uninterrupted 32-bit responses from a single, in-order requester.
module ibex_trvk #(
  // The number of outstanding transaction the IP supports
  parameter int unsigned NumOutstanding     = 32'd4,
  // The width of the meta memory byte address space used to store the revocation bits
  parameter int unsigned RevBitmapAddrWidth = 32'd11,
  // The base byte address of the meta SRAM holding the revocation bitmap
  parameter int unsigned RevBitmapBaseAddr  = 32'h0000_0000,
  // Enable ECC checking on the revocation bitmap memory port
  parameter bit          MemECC             = 1'b1
)(
  input  logic clk_i,
  input  logic rst_ni,

  // Synchronous pipeline flush
  input  logic flush_i,

  // The base address of the (heap) memory where to be revocable capabilities point to
  input  logic [31:0] heap_base_addr_i,

  // Upstream port
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

  // Downstream port
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
  output logic revbm_data_intg_error_o,
  output logic revbm_device_error_o
);

  import ibex_cheriot_pkg::*;

  localparam int unsigned RevBitmapWordAddrWidth = RevBitmapAddrWidth - 32'd2;

  typedef logic [RevBitmapWordAddrWidth-1:0] revbm_addr_t;

  typedef struct packed {
    exp_t    exponent;
    cbound_t base;
    otype_t  otype;
    cperms_t cperms;
  } cap_meta_t;

  typedef struct packed {
    logic [31:0] data;
    logic [6:0]  intg;
    logic        tag;
    logic        err;
  } ds_rsp_t;

  logic align_fork_valid;
  logic align_fork_ready;

  logic misalign_flag_out;
  logic misalign_flag_out_valid;
  logic misalign_flag_out_ready;

  logic [31:0] ptr_storage_q;
  logic        ptr_storage_valid_q;
  logic        ptr_storage_enable;

  ds_rsp_t downstream_rsp_in;
  ds_rsp_t downstream_rsp_out;
  logic    downstream_rsp_out_valid;
  logic    downstream_rsp_out_ready;
  logic    downstream_rsp_wready;
  logic    unused_downstream_rsp_wready;
  logic    unused_flush_i;

  cap_meta_t    cap_meta;
  logic         unused_cap_meta;
  logic         is_sealing_cap;
  logic [32:0]  cap_base_33;
  logic         unused_cap_base_33;
  logic [31:0]  cap_base;
  cbound_t      addr_mid;
  cap_cor_t     cap_correction;
  logic         unused_cap_correction;

  logic [31:0] revbm_cap_addr;
  logic [31:0] revbm_bit_addr;
  logic [ 4:0] revbm_bit_select;
  revbm_addr_t revbm_addr;
  logic        revbm_out_of_range;

  logic revbm_req_required;
  logic revbm_rsp_ready;
  logic revbm_outstanding_q;
  logic revbm_revoked;

  logic [1:0] revbm_rsp_data_intg_error;

  assign unused_flush_i = flush_i;

  stream_fork #(
    .N_OUP(32'd2)
  ) u_stream_fork_us2ds (
    .clk_i,
    .rst_ni,
    .valid_i(upstream_req_i),
    .ready_o(upstream_gnt_o),
    .valid_o({align_fork_valid, downstream_req_o}),
    .ready_i({align_fork_ready, downstream_gnt_i})
  );

  stream_join_dynamic #(
    .N_INP(32'd2)
  ) u_stream_join_dynamic_ds2us (
    .inp_valid_i({revbm_rvalid_i,     downstream_rsp_out_valid}),
    .inp_ready_o({revbm_rsp_ready,    downstream_rsp_out_ready}),
    .sel_i      ({revbm_req_required, 1'b1                    }),
    .oup_valid_o(upstream_rvalid_o),
    .oup_ready_i(upstream_rready_i)
  );

  assign downstream_we_o         = upstream_we_i;
  assign downstream_be_o         = upstream_be_i;
  assign downstream_addr_o       = upstream_addr_i;
  assign downstream_wdata_o      = upstream_wdata_i;
  assign downstream_wdata_intg_o = upstream_wdata_intg_i;
  assign upstream_rdata_o        = downstream_rsp_out.data;
  assign upstream_rdata_intg_o   = downstream_rsp_out.intg;
  assign upstream_err_o          = downstream_rsp_out.err;

  assign downstream_tag_o = upstream_tag_i;
  assign upstream_tag_o   = (revbm_rvalid_i ? !revbm_revoked : 1'b1) & downstream_rsp_out.tag;

  prim_fifo_sync #(
    .Width(32'd1),
    .Pass(1'b0),
    .Depth(NumOutstanding),
    .NeverClears(1'b0),
    .Secure(1'b0)
  ) u_prim_fifo_sync_align (
    .clk_i,
    .rst_ni,
    .clr_i   (1'b0),
    .wvalid_i(align_fork_valid),
    .wready_o(align_fork_ready),
    .wdata_i (upstream_addr_i[2]),
    .rvalid_o(misalign_flag_out_valid),
    .rready_i(misalign_flag_out_ready),
    .rdata_o (misalign_flag_out),
    .full_o  (),
    .depth_o (),
    .err_o   ()
  );

  assign misalign_flag_out_ready = upstream_rvalid_o;

  assign ptr_storage_enable = downstream_rsp_out.tag && !misalign_flag_out &&
                              misalign_flag_out_valid;

  always_ff @(posedge clk_i or negedge rst_ni) begin : proc_pointer_store
    if(!rst_ni) begin
      ptr_storage_q <= '0;
    end else begin
      if (misalign_flag_out_ready && ptr_storage_enable) begin
        ptr_storage_q <= downstream_rsp_out.data;
      end
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin : proc_pointer_valid_store
    if(!rst_ni) begin
      ptr_storage_valid_q <= 1'b0;
    end else begin
      if (misalign_flag_out_ready) begin
        ptr_storage_valid_q <= ptr_storage_enable;
      end
    end
  end

  assign downstream_rsp_in = '{
    data: downstream_rdata_i,
    intg: downstream_rdata_intg_i,
    tag:  downstream_tag_i,
    err:  downstream_err_i
  };

  prim_fifo_sync #(
    .Width($bits(ds_rsp_t)),
    .Pass(1'b1),
    .Depth(NumOutstanding),
    .NeverClears(1'b0),
    .Secure(1'b0)
  ) u_prim_fifo_ds_rsp_store (
    .clk_i,
    .rst_ni,
    .clr_i   (1'b0),
    .wvalid_i(downstream_rvalid_i),
    .wready_o(downstream_rsp_wready),
    .wdata_i (downstream_rsp_in),
    .rvalid_o(downstream_rsp_out_valid),
    .rready_i(downstream_rsp_out_ready),
    .rdata_o (downstream_rsp_out),
    .full_o  (),
    .depth_o (),
    .err_o   ()
  );

  assign cap_meta = '{
    base:     downstream_rsp_out.data[8:0],
    exponent: cheriot_expand_exp(downstream_rsp_out.data[21:18]),
    otype:    downstream_rsp_out.data[24:22],
    cperms:   downstream_rsp_out.data[30:25]
  };

  assign unused_cap_meta = ^{cap_meta.otype, cap_meta.cperms[5]};
  assign is_sealing_cap  = cheriot_is_sealing_cap(cap_meta.cperms);
  assign addr_mid        = cbound_t'(ptr_storage_q >> cap_meta.exponent);
  assign cap_correction  = cheriot_compute_corrections('0, cap_meta.base, addr_mid);
  assign cap_base_33     = cheriot_expand_bound33(cap_meta.base,
                                                  cheriot_get_base_correction(cap_correction),
                                                  cap_meta.exponent, ptr_storage_q);
  assign unused_cap_correction = ^cap_correction;
  assign {unused_cap_base_33, cap_base} = cap_base_33;

  assign revbm_cap_addr     = cap_base - heap_base_addr_i;
  assign revbm_bit_addr     = revbm_cap_addr >> $clog2(64/8);
  assign revbm_addr         = revbm_bit_addr[RevBitmapWordAddrWidth+$clog2(32)-1:$clog2(32)];
  assign revbm_bit_select   = revbm_bit_addr[$clog2(32)-1:0];
  assign revbm_out_of_range = |(revbm_bit_addr[31:RevBitmapWordAddrWidth+$clog2(32)]);

  assign revbm_req_required = !is_sealing_cap          &&
                              ptr_storage_valid_q      &&
                              downstream_rsp_out.tag   &&
                              downstream_rsp_out_valid &&
                              misalign_flag_out        &&
                              misalign_flag_out_valid  &&
                              !revbm_out_of_range;

  assign revbm_req_o  = revbm_req_required && !revbm_outstanding_q;
  assign revbm_addr_o = RevBitmapBaseAddr +
                        {{32 - RevBitmapWordAddrWidth - 2{1'b0}}, revbm_addr, 2'b00};

  assign revbm_revoked = revbm_rdata_i[revbm_bit_select] || revbm_err_i ||
                         (|revbm_rsp_data_intg_error);

  assign revbm_device_error_o = revbm_rvalid_i && revbm_err_i;

  if (MemECC) begin : gen_revbm_intg_check
    prim_secded_inv_39_32_dec u_prim_secded_inv_39_32_dec_bm_rsp_data (
      .data_i    ({revbm_rdata_intg_i, revbm_rdata_i}),
      .data_o    (),
      .syndrome_o(),
      .err_o     (revbm_rsp_data_intg_error)
    );
    assign revbm_data_intg_error_o = revbm_rvalid_i && (|revbm_rsp_data_intg_error);
  end else begin : gen_no_revbm_intg_check
    logic unused_revbm_rdata_intg;
    assign unused_revbm_rdata_intg   = ^revbm_rdata_intg_i;
    assign revbm_rsp_data_intg_error = 2'b00;
    assign revbm_data_intg_error_o   = 1'b0;
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin : proc_rev_req_store
    if(!rst_ni) begin
      revbm_outstanding_q <= 1'b0;
    end else begin
      if (revbm_rvalid_i && revbm_rsp_ready) begin
        revbm_outstanding_q <= 1'b0;
      end else if (revbm_req_o && revbm_gnt_i) begin
        revbm_outstanding_q <= 1'b1;
      end
    end
  end

  assign unused_downstream_rsp_wready = downstream_rsp_wready;

endmodule
