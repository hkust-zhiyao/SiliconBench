// Copyright 2022 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

module axi_llc_burst_cutter #(
  parameter axi_llc_pkg::llc_cfg_t     Cfg    = axi_llc_pkg::llc_cfg_t'{default: '0},
  parameter axi_llc_pkg::llc_axi_cfg_t AxiCfg = axi_llc_pkg::llc_axi_cfg_t'{default: '0},
  parameter type                       chan_t = logic,
  parameter bit                        Write  = 1'b0,
  parameter type                       desc_t = logic,
  parameter type                       rule_t = axi_pkg::xbar_rule_64_t
) (
  input  logic  clk_i,
  input  logic  rst_ni,
  input  chan_t curr_chan_i,
  output chan_t next_chan_o,
  output desc_t desc_o,
  input  rule_t cached_rule_i,
  input  rule_t spm_rule_i
);

  typedef logic [AxiCfg.AddrWidthFull-1:0] addr_t;
  typedef logic [Cfg.SetAssociativity-1:0] indi_t;

  localparam int unsigned LineOffset     = Cfg.ByteOffsetLength + Cfg.BlockOffsetLength;
  localparam int unsigned RuleIndexWidth = cf_math_pkg::idx_width(Cfg.SetAssociativity + 32'd1);
  localparam int unsigned WayBytes       = (Cfg.BlockSize / 32'd8) * Cfg.NumBlocks * Cfg.NumLines;
  localparam int unsigned LineByteSpan   = (Cfg.BlockSize / 32'd8) * Cfg.NumBlocks;

  addr_t         this_line_address;
  addr_t         next_line_address;
  addr_t         bytes_on_line;
  axi_pkg::len_t beats_on_line;
  logic                      rule_valid;
  logic [RuleIndexWidth-1:0] rule_index;

  function automatic logic stays_on_single_line(
    input axi_pkg::burst_t bst,
    input axi_pkg::len_t   rem_len,
    input axi_pkg::size_t  beat_sz,
    input axi_pkg::len_t   line_beats
  );
    int unsigned total_span;
    total_span = (int'(rem_len) + 1) * int'(axi_pkg::num_bytes(beat_sz));
    unique case (bst)
      axi_pkg::BURST_FIXED: return 1'b1;
      axi_pkg::BURST_WRAP:  return (total_span <= LineByteSpan) || ((line_beats - 8'd1) >= rem_len);
      default:              return ((line_beats - 8'd1) >= rem_len);
    endcase
  endfunction

  rule_t [Cfg.SetAssociativity:0] addr_map;
  always_comb begin : proc_assign_addr_map
    addr_map               = '0;
    addr_map[0].start_addr = cached_rule_i.start_addr;
    addr_map[0].end_addr   = cached_rule_i.end_addr;
    for (int unsigned w = 32'd0; w < Cfg.SetAssociativity; w++) begin
      addr_map[w + 1].idx        = w + 1;
      addr_map[w + 1].start_addr = spm_rule_i.start_addr + addr_t'(w * WayBytes);
      addr_map[w + 1].end_addr   = spm_rule_i.start_addr + addr_t'((w + 1) * WayBytes);
    end
  end

  always_comb begin : proc_cutter
    next_chan_o = curr_chan_i;
    desc_o      = desc_t'{
      a_x_id:    curr_chan_i.id,
      a_x_addr:  curr_chan_i.addr,
      a_x_size:  curr_chan_i.size,
      a_x_burst: curr_chan_i.burst,
      a_x_lock:  curr_chan_i.lock,
      a_x_prot:  curr_chan_i.prot,
      a_x_cache: curr_chan_i.cache,
      x_resp:    axi_pkg::RESP_OKAY,
      rw:        Write,
      default: '0
    };

    this_line_address = {curr_chan_i.addr[AxiCfg.AddrWidthFull-1:LineOffset], {LineOffset{1'b0}}};
    next_line_address = this_line_address + addr_t'(LineByteSpan);
    bytes_on_line     = next_line_address - curr_chan_i.addr;
    beats_on_line     = axi_pkg::len_t'((bytes_on_line - addr_t'(1)) >> curr_chan_i.size) + 8'd1;

    if (!rule_valid) begin
      desc_o.spm     = 1'b1;
      desc_o.way_ind = indi_t'(1);
      desc_o.x_resp  = axi_pkg::RESP_SLVERR;
    end else if (rule_index != '0) begin
      desc_o.spm     = 1'b1;
      desc_o.way_ind = indi_t'(1) << (rule_index - 1'b1);
    end

    if (stays_on_single_line(curr_chan_i.burst, curr_chan_i.len, curr_chan_i.size, beats_on_line)) begin
      next_chan_o.addr = '0;
      next_chan_o.len  = '0;
      desc_o.a_x_len   = curr_chan_i.len;
      desc_o.x_last    = 1'b1;
    end else begin
      next_chan_o.addr = next_line_address;
      next_chan_o.len  = curr_chan_i.len - beats_on_line;
      desc_o.a_x_len   = beats_on_line - 8'd1;
      desc_o.x_last    = 1'b0;
    end
  end

  addr_decode #(
    .NoIndices ( Cfg.SetAssociativity + 32'd1 ),
    .NoRules   ( Cfg.SetAssociativity + 32'd1 ),
    .addr_t    ( addr_t                       ),
    .rule_t    ( rule_t                       )
  ) i_burst_cutter_decode (
    .addr_i           ( curr_chan_i.addr ),
    .addr_map_i       ( addr_map         ),
    .idx_o            ( rule_index       ),
    .dec_valid_o      ( rule_valid       ),
    .dec_error_o      (                  ),
    .en_default_idx_i ( 1'b0             ),
    .default_idx_i    ( '0               )
  );
endmodule
