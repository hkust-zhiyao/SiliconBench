// Copyright 2022 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

module axi_llc_write_unit #(
  parameter axi_llc_pkg::llc_cfg_t     Cfg       = axi_llc_pkg::llc_cfg_t'{default: '0},
  parameter axi_llc_pkg::llc_axi_cfg_t AxiCfg    = axi_llc_pkg::llc_axi_cfg_t'{default: '0},
  parameter type                       desc_t    = logic,
  parameter type                       way_inp_t = logic,
  parameter type                       lock_t    = logic,
  parameter type                       w_chan_t  = logic,
  parameter type                       b_chan_t  = logic
) (
  input  logic     clk_i,
  input  logic     rst_ni,
  input  logic     test_i,
  input  desc_t    desc_i,
  input  logic     desc_valid_i,
  output logic     desc_ready_o,
  input  w_chan_t  w_chan_slv_i,
  input  logic     w_chan_valid_i,
  output logic     w_chan_ready_o,
  output b_chan_t  b_chan_slv_o,
  output logic     b_chan_valid_o,
  input  logic     b_chan_ready_i,
  output way_inp_t way_inp_o,
  output logic     way_inp_valid_o,
  input  logic     way_inp_ready_i,
  output lock_t    w_unlock_o,
  output logic     w_unlock_req_o,
  input  logic     w_unlock_gnt_i
);
  `include "common_cells/registers.svh"
  typedef logic [AxiCfg.AddrWidthFull-1:0] addr_t;
  typedef logic [AxiCfg.DataWidthFull-1:0] data_t;

  desc_t   desc_d,      desc_q;
  addr_t   wrap_mask_d, wrap_mask_q;
  addr_t   next_lin_addr;
  logic    busy_d,      busy_q;
  logic    load_desc,   load_busy;

  w_chan_t w_chan;
  logic    w_valid, w_ready;
  data_t   w_masked_data;
  b_chan_t b_chan;
  logic    b_valid, b_ready;

  stream_fifo #(
    .FALL_THROUGH ( 1'b0                          ),
    .DEPTH        ( axi_llc_pkg::WChanBufferDepth ),
    .T            ( w_chan_t                      )
  ) i_w_stream_fifo (
    .clk_i, .rst_ni, .flush_i(1'b0), .testmode_i(test_i), .usage_o(),
    .data_i(w_chan_slv_i), .valid_i(w_chan_valid_i), .ready_o(w_chan_ready_o),
    .data_o(w_chan), .valid_o(w_valid), .ready_i(w_ready)
  );

  for (genvar b = 0; b < (AxiCfg.DataWidthFull / 32'd8); b++) begin : gen_wmask
    assign w_masked_data[8*b +: 8] = w_chan.data[8*b +: 8] & {8{w_chan.strb[b]}};
  end

  assign way_inp_o = '{
    cache_unit: axi_llc_pkg::WChanUnit,
    way_ind:    desc_q.way_ind,
    line_addr:  desc_q.a_x_addr[(Cfg.ByteOffsetLength + Cfg.BlockOffsetLength) +: Cfg.IndexLength],
    blk_offset: desc_q.a_x_addr[ Cfg.ByteOffsetLength +: Cfg.BlockOffsetLength],
    we:         1'b1,
    data:       w_masked_data,
    strb:       w_chan.strb
  };

  assign w_unlock_o = '{
    index:   desc_q.a_x_addr[(Cfg.ByteOffsetLength + Cfg.BlockOffsetLength) +: Cfg.IndexLength],
    way_ind: desc_q.way_ind
  };

  function void load_new_desc ();
    desc_ready_o = 1'b1;
    if (desc_valid_i) begin
      desc_d      = desc_i;
      wrap_mask_d = ((addr_t'(desc_i.a_x_len) + addr_t'(1)) << desc_i.a_x_size) - addr_t'(1);
      load_desc   = 1'b1;
      busy_d      = 1'b1;
      load_busy   = 1'b1;
    end
  endfunction : load_new_desc

  always_comb begin
    desc_d          = desc_q;
    wrap_mask_d     = wrap_mask_q;
    load_desc       = 1'b0;
    busy_d          = busy_q;
    load_busy       = 1'b0;
    desc_ready_o    = 1'b0;
    w_ready         = 1'b0;
    way_inp_valid_o = 1'b0;
    w_unlock_req_o  = 1'b0;
    b_valid         = 1'b0;
    next_lin_addr   = axi_pkg::aligned_addr(desc_q.a_x_addr + axi_pkg::num_bytes(desc_q.a_x_size), desc_q.a_x_size);

    if (busy_q) begin
      if (b_ready && w_unlock_gnt_i) begin
        if (desc_q.x_resp != axi_pkg::RESP_SLVERR) begin
          way_inp_valid_o = w_valid;
          w_ready         = way_inp_ready_i;
        end else begin
          w_ready         = 1'b1;
        end
        if (w_valid && w_ready) begin
          if (desc_q.a_x_len == '0) begin
            if (desc_q.x_last) b_valid = 1'b1;
            busy_d         = 1'b0;
            load_busy      = 1'b1;
            w_unlock_req_o = 1'b1;
            load_new_desc();
          end else begin
            load_desc      = 1'b1;
            desc_d.a_x_len = desc_q.a_x_len - axi_pkg::len_t'(1);
            if (desc_q.a_x_burst == axi_pkg::BURST_WRAP) begin
              desc_d.a_x_addr = (desc_q.a_x_addr & ~wrap_mask_q) | (next_lin_addr & wrap_mask_q);
            end else if (desc_q.a_x_burst != axi_pkg::BURST_FIXED) begin
              desc_d.a_x_addr = next_lin_addr;
            end
          end
        end
      end
    end else begin
      load_new_desc();
    end
  end

  assign b_chan = '{id: desc_q.a_x_id, resp: desc_q.x_resp, default: '0};

  spill_register #(.T(b_chan_t), .Bypass(1'b0)) i_spill_register_b (
    .clk_i, .rst_ni,
    .valid_i(b_valid), .ready_o(b_ready), .data_i(b_chan),
    .valid_o(b_chan_valid_o), .ready_i(b_chan_ready_i), .data_o(b_chan_slv_o)
  );

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      desc_q      <= '0;
      wrap_mask_q <= '0;
      busy_q      <= 1'b0;
    end else begin
      if (load_desc) begin
        desc_q      <= desc_d;
        wrap_mask_q <= wrap_mask_d;
      end
      if (load_busy) busy_q <= busy_d;
    end
  end
endmodule
