// Copyright lowRISC contributors (OpenTitan project).
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// OpenTitan HMAC Core + SHA-256 Padding Subsystem Wrapper

`include "prim_assert.sv"

module ot_hmac_pad_top import prim_sha2_pkg::*; (
  input  logic          clk_i,
  input  logic          rst_ni,

  input  logic [1023:0] secret_key_i,
  input  logic          hmac_en_i,
  input  digest_mode_e  digest_size_i,
  input  key_length_e   key_length_i,
  input  logic          sha_en_i,

  input  logic          reg_hash_start_i,
  input  logic          reg_hash_stop_i,
  input  logic          reg_hash_continue_i,
  input  logic          reg_hash_process_i,
  input  logic          abort_i,
  input  logic          sha_hash_done_i,

  input  logic [63:0]   message_length_i,

  input  logic          fifo_rvalid_i,
  input  sha_fifo32_t   fifo_rdata_i,
  output logic          fifo_rready_o,

  output logic          fifo_wsel_o,
  output logic          fifo_wvalid_o,
  output logic [3:0]    fifo_wdata_sel_o,
  input  logic          fifo_wready_i,

  output logic          shaf_rvalid_o,
  output sha_word64_t   shaf_rdata_o,
  input  logic          shaf_rready_i,

  output logic          sha_hash_start_o,
  output logic          sha_hash_continue_o,
  output logic          sha_hash_process_o,
  output logic          hash_done_o,
  output logic [63:0]   sha_message_length_o,
  output logic          msg_feed_complete_o,
  output logic          idle_o
);

  logic        sha_rvalid;
  sha_fifo32_t sha_rdata;
  logic        pad_fifo_rready;
  sha_fifo64_t pad_fifo_rdata;

  hmac_core u_hmac_core (
    .clk_i,
    .rst_ni,
    .secret_key_i,
    .hmac_en_i,
    .digest_size_i,
    .key_length_i,
    .reg_hash_start_i,
    .reg_hash_stop_i,
    .reg_hash_continue_i,
    .reg_hash_process_i,
    .abort_i,
    .hash_done_o,
    .sha_hash_start_o,
    .sha_hash_continue_o,
    .sha_hash_process_o,
    .sha_hash_done_i,
    .sha_rvalid_o        (sha_rvalid),
    .sha_rdata_o         (sha_rdata),
    .sha_rready_i        (pad_fifo_rready),
    .fifo_rvalid_i,
    .fifo_rdata_i,
    .fifo_rready_o,
    .fifo_wsel_o,
    .fifo_wvalid_o,
    .fifo_wdata_sel_o,
    .fifo_wready_i,
    .message_length_i,
    .sha_message_length_o,
    .idle_o
  );

  assign pad_fifo_rdata.data = {32'b0, sha_rdata.data};
  assign pad_fifo_rdata.mask = {4'hF,  sha_rdata.mask};

  prim_sha2_pad #(
    .MultimodeEn(1'b0)
  ) u_sha2_pad (
    .clk_i,
    .rst_ni,
    .fifo_rvalid_i       (sha_rvalid),
    .fifo_rdata_i        (pad_fifo_rdata),
    .fifo_rready_o       (pad_fifo_rready),
    .shaf_rvalid_o,
    .shaf_rdata_o,
    .shaf_rready_i,
    .sha_en_i,
    .hash_start_i        (sha_hash_start_o),
    .hash_stop_i         (reg_hash_stop_i),
    .hash_continue_i     (sha_hash_continue_o),
    .digest_mode_i       (digest_size_i),
    .hash_process_i      (sha_hash_process_o),
    .hash_done_i         (sha_hash_done_i),
    .message_length_i    ({64'b0, sha_message_length_o}),
    .msg_feed_complete_o
  );

endmodule
