// Copyright lowRISC contributors (OpenTitan project).
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// HMAC Core implementation

`include "prim_assert.sv"

module hmac_core import prim_sha2_pkg::*; (
  input clk_i,
  input rst_ni,

  input [1023:0]      secret_key_i,
  input               hmac_en_i,
  input digest_mode_e digest_size_i,
  input key_length_e  key_length_i,

  input        reg_hash_start_i,
  input        reg_hash_stop_i,
  input        reg_hash_continue_i,
  input        reg_hash_process_i,
  input        abort_i,
  output logic hash_done_o,
  output logic sha_hash_start_o,
  output logic sha_hash_continue_o,
  output logic sha_hash_process_o,
  input        sha_hash_done_i,

  output logic        sha_rvalid_o,
  output sha_fifo32_t sha_rdata_o,
  input               sha_rready_i,

  input               fifo_rvalid_i,
  input  sha_fifo32_t fifo_rdata_i,
  output logic        fifo_rready_o,

  output logic       fifo_wsel_o,
  output logic       fifo_wvalid_o,
  output logic [3:0] fifo_wdata_sel_o,
  input              fifo_wready_i,

  input  [63:0] message_length_i,
  output [63:0] sha_message_length_o,

  output logic idle_o
);

  localparam int unsigned BlockSizeSHA256     = 512;
  localparam int unsigned BlockSizeSHA512     = 1024;
  localparam int unsigned BlockSizeBitsSHA256 = $clog2(BlockSizeSHA256);
  localparam int unsigned BlockSizeBitsSHA512 = $clog2(BlockSizeSHA512);
  localparam int unsigned HashWordBitsSHA256  = $clog2($bits(sha_word32_t));
  localparam bit [63:0] BlockSizeSHA256in64   = 64'(BlockSizeSHA256);
  localparam bit [63:0] BlockSizeSHA512in64   = 64'(BlockSizeSHA512);

  logic hash_start, hash_continue, hash_process, hmac_hash_done;
  logic [63:0] txcount, txcount_d;
  logic [4:0]  pad_index_512;
  logic [3:0]  pad_index_256;
  logic clr_txcount, load_txcount, inc_txcount;
  logic hmac_sha_rvalid;
  logic idle_d, idle_q;
  logic reg_hash_stop_d, reg_hash_stop_q;

  typedef enum logic [1:0] { SelIPad, SelOPad, SelFifo } sel_rdata_t;
  sel_rdata_t sel_rdata;
  typedef enum logic { SelIPadMsg, SelOPadMsg } sel_msglen_t;
  sel_msglen_t sel_msglen;
  typedef enum logic { Inner, Outer } round_t;
  logic update_round;
  round_t round_q, round_d;
  typedef enum logic [2:0] { StIdle, StIPad, StMsg, StPushToMsgFifo, StWaitResp, StOPad, StDone } st_e;
  st_e st_q, st_d;

  logic clr_fifo_wdata_sel;
  logic txcnt_eq_blksz;
  logic reg_hash_process_flag;

  assign sha_hash_start_o    = (hmac_en_i) ? hash_start    : reg_hash_start_i;
  assign sha_hash_continue_o = (hmac_en_i) ? hash_continue : reg_hash_continue_i;
  assign sha_hash_process_o  = (hmac_en_i) ? reg_hash_process_i | hash_process : reg_hash_process_i;
  assign hash_done_o         = (hmac_en_i) ? hmac_hash_done                    : sha_hash_done_i;

  assign pad_index_512 = txcount[BlockSizeBitsSHA512-1:HashWordBitsSHA256];
  assign pad_index_256 = txcount[BlockSizeBitsSHA256-1:HashWordBitsSHA256];

  logic [4:0]  pad_idx;
  logic [31:0] key_word_sel, key_word_masked, pad_word;
  logic        key_word_valid;
  assign pad_idx = (digest_size_i == SHA2_256) ? {1'b0, pad_index_256} : pad_index_512;

  always_comb begin
    key_word_sel = '0;
    for (int w = 0; w < 32; w++) begin
      if (pad_idx == 5'(w)) begin
        key_word_sel = secret_key_i[1023 - 32*w -: 32];
      end
    end
    unique case (key_length_i)
      Key_128:  key_word_valid = (pad_idx[4:2] == 3'b000);
      Key_256:  key_word_valid = (pad_idx[4:3] == 2'b00);
      Key_384:  key_word_valid = (pad_idx[4] == 1'b0) && (pad_idx[3:2] != 2'b11);
      Key_512:  key_word_valid = (pad_idx[4] == 1'b0);
      Key_1024: key_word_valid = (digest_size_i == SHA2_384) || (digest_size_i == SHA2_512);
      default:  key_word_valid = 1'b0;
    endcase
    key_word_masked = key_word_valid ? key_word_sel : 32'h0;
    pad_word        = key_word_masked ^ {4{(sel_rdata == SelIPad) ? 8'h36 : 8'h5c}};
  end

  assign fifo_rready_o = (hmac_en_i) ? (st_q == StMsg) & sha_rready_i : sha_rready_i;
  assign sha_rvalid_o  = (!hmac_en_i) ? fifo_rvalid_i : hmac_sha_rvalid;
  assign sha_rdata_o =
    (!hmac_en_i) ? fifo_rdata_i :
    ((sel_rdata == SelIPad || sel_rdata == SelOPad) &&
     (digest_size_i == SHA2_256 || digest_size_i == SHA2_384 || digest_size_i == SHA2_512))
                 ? '{data: pad_word, mask: '1} :
                 fifo_rdata_i;

  logic [63:0] sha_msg_len;
  always_comb begin : assign_sha_message_length
    sha_msg_len = '0;
    if (!hmac_en_i) begin
      sha_msg_len = message_length_i;
    end else if (sel_msglen == SelIPadMsg) begin
      if (digest_size_i == SHA2_256) begin
        sha_msg_len = {message_length_i[63:9] + 55'd1, message_length_i[8:0]};
      end else if ((digest_size_i == SHA2_384) || (digest_size_i == SHA2_512)) begin
        sha_msg_len = {message_length_i[63:10] + 54'd1, message_length_i[9:0]};
      end else begin
        sha_msg_len = '0;
      end
    end else begin
      if (digest_size_i == SHA2_256) begin
        sha_msg_len = BlockSizeSHA256in64 + 64'd256;
      end else if (digest_size_i == SHA2_384) begin
        sha_msg_len = BlockSizeSHA512in64 + 64'd384;
      end else begin
        sha_msg_len = BlockSizeSHA512in64 + 64'd512;
      end
    end
  end

  assign sha_message_length_o = sha_msg_len;

  always_comb begin
    txcnt_eq_blksz = '0;
    unique case (digest_size_i)
      SHA2_256: txcnt_eq_blksz = (txcount[BlockSizeBitsSHA256-1:0] == '0) && (txcount != '0);
      SHA2_384: txcnt_eq_blksz = (txcount[BlockSizeBitsSHA512-1:0] == '0) && (txcount != '0);
      SHA2_512: txcnt_eq_blksz = (txcount[BlockSizeBitsSHA512-1:0] == '0) && (txcount != '0);
      default: ;
    endcase
  end

  assign inc_txcount = sha_rready_i && sha_rvalid_o;

  always_comb begin
    txcount_d = txcount;
    if (clr_txcount) begin
      txcount_d = '0;
    end else if (load_txcount) begin
      txcount_d = message_length_i;
    end else if (inc_txcount) begin
      txcount_d[63:5] = txcount[63:5] + 59'd1;
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) txcount <= '0;
    else         txcount <= txcount_d;
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      reg_hash_process_flag <= 1'b0;
    end else if (reg_hash_process_i) begin
      reg_hash_process_flag <= 1'b1;
    end else if (hmac_hash_done || reg_hash_start_i || reg_hash_continue_i || abort_i) begin
      reg_hash_process_flag <= 1'b0;
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      round_q <= Inner;
    end else if (update_round) begin
      round_q <= round_d;
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      fifo_wdata_sel_o <= '0;
    end else if (clr_fifo_wdata_sel) begin
      fifo_wdata_sel_o <= '0;
    end else if (fifo_wsel_o && fifo_wvalid_o && fifo_wready_i) begin
      fifo_wdata_sel_o <= fifo_wdata_sel_o + 1'b1;
    end
  end

  assign sel_msglen = (round_q == Inner) ? SelIPadMsg : SelOPadMsg;

  always_ff @(posedge clk_i or negedge rst_ni) begin : state_ff
    if (!rst_ni) st_q <= StIdle;
    else         st_q <= st_d;
  end

  logic txcnt_ge_target;
  always_comb begin
    if (round_q == Outer) begin
      if (digest_size_i == SHA2_256) begin
        txcnt_ge_target = (txcount[63:5] >= 59'd8);
      end else if (digest_size_i == SHA2_384) begin
        txcnt_ge_target = (txcount[63:5] >= 59'd12);
      end else begin
        txcnt_ge_target = (txcount[63:5] >= 59'd16);
      end
    end else begin
      txcnt_ge_target = (txcount >= message_length_i);
    end
  end

  always_comb begin : next_state
    hmac_hash_done     = 1'b0;
    hmac_sha_rvalid    = 1'b0;
    clr_txcount        = 1'b0;
    load_txcount       = 1'b0;
    update_round       = 1'b0;
    round_d            = Inner;
    fifo_wsel_o        = 1'b0;
    fifo_wvalid_o      = 1'b0;
    clr_fifo_wdata_sel = 1'b1;
    sel_rdata          = SelFifo;
    hash_start         = 1'b0;
    hash_continue      = 1'b0;
    hash_process       = 1'b0;
    st_d               = st_q;

    unique case (st_q)
      StIdle: begin
        update_round = 1'b1;
        round_d      = Inner;
        if (hmac_en_i && reg_hash_start_i) begin
          st_d        = StIPad;
          clr_txcount = 1'b1;
          hash_start  = 1'b1;
        end else if (hmac_en_i && reg_hash_continue_i) begin
          st_d          = StMsg;
          load_txcount  = 1'b1;
          hash_continue = 1'b1;
        end else begin
          st_d = StIdle;
        end
      end

      StIPad: begin
        sel_rdata = SelIPad;
        if (txcnt_eq_blksz) begin
          st_d            = StMsg;
          clr_txcount     = 1'b1;
          hmac_sha_rvalid = 1'b0;
        end else begin
          st_d            = StIPad;
          hmac_sha_rvalid = 1'b1;
        end
      end

      StMsg: begin
        sel_rdata   = SelFifo;
        fifo_wsel_o = (round_q == Outer);
        if ((((round_q == Inner) && reg_hash_process_flag) || (round_q == Outer)) && txcnt_ge_target) begin
          st_d            = StWaitResp;
          hmac_sha_rvalid = 1'b0;
          hash_process    = (round_q == Outer);
        end else if (txcnt_eq_blksz && txcnt_ge_target && reg_hash_stop_q && (round_q == Inner)) begin
          st_d            = StWaitResp;
          hmac_sha_rvalid = 1'b0;
        end else begin
          st_d            = StMsg;
          hmac_sha_rvalid = fifo_rvalid_i;
        end
      end

      StWaitResp: begin
        hmac_sha_rvalid = 1'b0;
        if (sha_hash_done_i) begin
          if (round_q == Outer) begin
            st_d = StDone;
          end else if (reg_hash_stop_q) begin
            st_d = StDone;
          end else begin
            st_d = StPushToMsgFifo;
          end
        end else begin
          st_d = StWaitResp;
        end
      end

      StPushToMsgFifo: begin
        hmac_sha_rvalid    = 1'b0;
        fifo_wsel_o        = 1'b1;
        fifo_wvalid_o      = 1'b1;
        clr_fifo_wdata_sel = 1'b0;
        if (fifo_wready_i && (((fifo_wdata_sel_o == 4'd7)  && (digest_size_i == SHA2_256)) ||
                              ((fifo_wdata_sel_o == 4'd15) && (digest_size_i == SHA2_512)) ||
                              ((fifo_wdata_sel_o == 4'd11) && (digest_size_i == SHA2_384)))) begin
          st_d         = StOPad;
          clr_txcount  = 1'b1;
          update_round = 1'b1;
          round_d      = Outer;
          hash_start   = 1'b1;
        end else begin
          st_d = StPushToMsgFifo;
        end
      end

      StOPad: begin
        sel_rdata   = SelOPad;
        fifo_wsel_o = 1'b1;
        if (txcnt_eq_blksz) begin
          st_d            = StMsg;
          clr_txcount     = 1'b1;
          hmac_sha_rvalid = 1'b0;
        end else begin
          st_d            = StOPad;
          hmac_sha_rvalid = 1'b1;
        end
      end

      StDone: begin
        st_d           = StIdle;
        hmac_hash_done = 1'b1;
      end

      default: begin
        st_d = StIdle;
      end
    endcase

    if (abort_i) begin
      hmac_hash_done = 1'b0;
      st_d           = StIdle;
    end
  end

  assign reg_hash_stop_d = (abort_i == 1'b1)                                    ? 1'b0 :
                           (reg_hash_stop_i == 1'b1)                            ? 1'b1 :
                           (sha_hash_done_i == 1'b1 && reg_hash_stop_q == 1'b1) ? 1'b0 :
                                                                                  reg_hash_stop_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) reg_hash_stop_q <= 1'b0;
    else         reg_hash_stop_q <= reg_hash_stop_d;
  end

  assign idle_d = (reg_hash_start_i || reg_hash_continue_i) ? 1'b0 :
                  (st_q == StIdle)                          ? 1'b1 :
                  (txcnt_eq_blksz && reg_hash_stop_d)       ? 1'b1 :
                                                              idle_q;
  assign idle_o = idle_d;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) idle_q <= 1'b1;
    else         idle_q <= idle_d;
  end

  `ASSERT(ValidSelRdata_A, hmac_en_i |-> sel_rdata inside {SelIPad, SelOPad, SelFifo})
  `ASSERT(ValidDigestSize_A, (hmac_en_i && (sel_msglen == SelOPadMsg)) |->
      digest_size_i inside {SHA2_256, SHA2_384, SHA2_512})
  `ASSERT(NoProcessOnAbort_A, abort_i |-> !reg_hash_process_i)

endmodule
