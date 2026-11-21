// Copyright 2022 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

module axi_llc_read_unit #(
  parameter axi_llc_pkg::llc_cfg_t     Cfg       = axi_llc_pkg::llc_cfg_t'{default: 0},
  parameter axi_llc_pkg::llc_axi_cfg_t AxiCfg    = axi_llc_pkg::llc_axi_cfg_t'{default: '0},
  parameter type                       desc_t    = logic,
  parameter type                       way_inp_t = logic,
  parameter type                       way_oup_t = logic,
  parameter type                       lock_t    = logic,
  parameter type                       r_chan_t  = logic
) (
  input  logic     clk_i,
  input  logic     rst_ni,
  input  logic     test_i,
  input  desc_t    desc_i,
  input  logic     desc_valid_i,
  output logic     desc_ready_o,
  output r_chan_t  r_chan_slv_o,
  output logic     r_chan_valid_o,
  input  logic     r_chan_ready_i,
  output way_inp_t way_inp_o,
  output logic     way_inp_valid_o,
  input  logic     way_inp_ready_i,
  input  way_oup_t way_out_i,
  input  logic     way_out_valid_i,
  output logic     way_out_ready_o,
  output lock_t    r_unlock_o,
  output logic     r_unlock_req_o,
  input  logic     r_unlock_gnt_i
);
  `include "common_cells/registers.svh"
  typedef logic [AxiCfg.SlvPortIdWidth-1:0] id_t;
  typedef logic [AxiCfg.DataWidthFull-1:0]  data_t;
  typedef logic [AxiCfg.AddrWidthFull-1:0]  addr_t;

  typedef struct packed {
    id_t            id;
    axi_pkg::resp_t resp;
    logic           last;
  } r_meta_t;

  desc_t         desc_d,     desc_q;
  axi_pkg::len_t orig_len_d, orig_len_q;
  logic          load_desc,  load_orig_len;
  logic          busy_d,     busy_q;
  logic          load_busy;

  r_chan_t r_fifo_inp;
  logic    r_fifo_push, r_fifo_full, r_fifo_empty, r_fifo_pop;

  r_meta_t meta_fifo_inp, meta_fifo_outp;
  logic    meta_fifo_full, meta_fifo_push, meta_fifo_empty, meta_fifo_pop;

  function automatic addr_t step_read_addr(
    input addr_t           cur_addr,
    input axi_pkg::size_t  beat_sz,
    input axi_pkg::burst_t bst,
    input axi_pkg::len_t   init_len
  );
    addr_t aligned_next, wrap_msk;
    aligned_next = axi_pkg::aligned_addr(cur_addr + axi_pkg::num_bytes(beat_sz), beat_sz);
    wrap_msk     = ((addr_t'(init_len) + addr_t'(1)) << beat_sz) - addr_t'(1);
    unique case (bst)
      axi_pkg::BURST_FIXED: return cur_addr;
      axi_pkg::BURST_WRAP:  return (cur_addr & ~wrap_msk) | (aligned_next & wrap_msk);
      default:              return aligned_next;
    endcase
  endfunction

  assign way_inp_o = '{
    cache_unit: axi_llc_pkg::RChanUnit,
    way_ind:    desc_q.way_ind,
    line_addr:  desc_q.a_x_addr[(Cfg.ByteOffsetLength + Cfg.BlockOffsetLength)+:Cfg.IndexLength],
    blk_offset: desc_q.a_x_addr[ Cfg.ByteOffsetLength +: Cfg.BlockOffsetLength],
    default: '0
  };

  assign r_unlock_o = '{
    index:   desc_q.a_x_addr[(Cfg.ByteOffsetLength + Cfg.BlockOffsetLength)+:Cfg.IndexLength],
    way_ind: desc_q.way_ind
  };

  always_comb begin
    desc_d          = desc_q;
    orig_len_d      = orig_len_q;
    load_desc       = 1'b0;
    load_orig_len   = 1'b0;
    busy_d          = busy_q;
    load_busy       = 1'b0;
    way_inp_valid_o = 1'b0;
    desc_ready_o    = 1'b0;
    r_unlock_req_o  = 1'b0;

    if (busy_q) begin
      if (!meta_fifo_full && r_unlock_gnt_i) begin
        way_inp_valid_o = 1'b1;
        if (way_inp_ready_i) begin
          if (desc_q.a_x_len == '0) begin
            busy_d         = 1'b0;
            load_busy      = 1'b1;
            r_unlock_req_o = 1'b1;
            desc_ready_o   = 1'b1;
            if (desc_valid_i) begin
              desc_d        = desc_i;
              orig_len_d    = desc_i.a_x_len;
              load_desc     = 1'b1;
              load_orig_len = 1'b1;
              busy_d        = 1'b1;
            end
          end else begin
            desc_d.a_x_addr = step_read_addr(desc_q.a_x_addr, desc_q.a_x_size, desc_q.a_x_burst, orig_len_q);
            desc_d.a_x_len  = desc_q.a_x_len - axi_pkg::len_t'(1);
            load_desc       = 1'b1;
          end
        end
      end
    end else begin
      desc_ready_o = 1'b1;
      if (desc_valid_i) begin
        desc_d        = desc_i;
        orig_len_d    = desc_i.a_x_len;
        load_desc     = 1'b1;
        load_orig_len = 1'b1;
        busy_d        = 1'b1;
        load_busy     = 1'b1;
      end
    end
  end

  assign meta_fifo_inp = '{
    id:   desc_q.a_x_id,
    resp: desc_q.x_resp,
    last: (desc_q.x_last & (desc_q.a_x_len == '0))
  };
  assign meta_fifo_push  = way_inp_valid_o & way_inp_ready_i;
  assign meta_fifo_pop   = r_fifo_push;
  assign r_fifo_push     = way_out_valid_i & way_out_ready_o;
  assign way_out_ready_o = ~r_fifo_full    & ~meta_fifo_empty;
  assign r_chan_valid_o  = ~r_fifo_empty;
  assign r_fifo_pop      = r_chan_ready_i  & ~r_fifo_empty;

  assign r_fifo_inp = r_chan_t'{
    id:   meta_fifo_outp.id,
    data: (meta_fifo_outp.resp inside {axi_pkg::RESP_OKAY}) ?
              way_out_i.data : data_t'(axi_llc_pkg::AxiLlcVersion),
    resp: meta_fifo_outp.resp,
    last: meta_fifo_outp.last,
    default: '0
  };

  fifo_v3 #(
    .FALL_THROUGH ( 1'b0     ),
    .DEPTH        ( 32'd12   ),
    .dtype        ( r_meta_t )
  ) i_r_meta_fifo (
    .clk_i, .rst_ni,
    .flush_i    ( '0              ),
    .testmode_i ( test_i          ),
    .full_o     ( meta_fifo_full  ),
    .empty_o    ( meta_fifo_empty ),
    .usage_o    (                 ),
    .data_i     ( meta_fifo_inp   ),
    .push_i     ( meta_fifo_push  ),
    .data_o     ( meta_fifo_outp  ),
    .pop_i      ( meta_fifo_pop   )
  );
  fifo_v3 #(
    .FALL_THROUGH ( 1'b0          ),
    .DEPTH        ( Cfg.NumBlocks ),
    .dtype        ( r_chan_t      )
  ) i_r_fifo (
    .clk_i, .rst_ni,
    .flush_i    ( '0           ),
    .testmode_i ( test_i       ),
    .full_o     ( r_fifo_full  ),
    .empty_o    ( r_fifo_empty ),
    .usage_o    (              ),
    .data_i     ( r_fifo_inp   ),
    .push_i     ( r_fifo_push  ),
    .data_o     ( r_chan_slv_o ),
    .pop_i      ( r_fifo_pop   )
  );

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      desc_q     <= '0;
      orig_len_q <= '0;
      busy_q     <= 1'b0;
    end else begin
      if (load_desc)     desc_q     <= desc_d;
      if (load_orig_len) orig_len_q <= orig_len_d;
      if (load_busy)     busy_q     <= busy_d;
    end
  end
endmodule
