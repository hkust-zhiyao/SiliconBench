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
  localparam addr_t       LineBytes      = addr_t'(1) << LineOffset;

  addr_t         this_line_address;
  addr_t         next_line_address;
  addr_t         bytes_on_line;
  addr_t         wrap_bytes;
  logic          is_intra_line_wrap;
  axi_pkg::len_t beats_on_line;
  logic                      rule_valid;
  logic [RuleIndexWidth-1:0] rule_index;

  rule_t [Cfg.SetAssociativity:0] addr_map;
  always_comb begin : proc_assign_addr_map
    addr_t tmp_addr;
    tmp_addr = spm_rule_i.start_addr;
    addr_map = '0;
    addr_map[0].start_addr = cached_rule_i.start_addr;
    addr_map[0].end_addr   = cached_rule_i.end_addr;
    for (int unsigned i = 32'd1; i <= Cfg.SetAssociativity; i++) begin
      addr_map[i].idx        = i;
      addr_map[i].start_addr = tmp_addr;
      addr_map[i].end_addr   = tmp_addr + (Cfg.BlockSize / 32'd8) * Cfg.NumBlocks * Cfg.NumLines;
      tmp_addr               = tmp_addr + (Cfg.BlockSize / 32'd8) * Cfg.NumBlocks * Cfg.NumLines;
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

    this_line_address  = addr_t'(curr_chan_i.addr[LineOffset+:(AxiCfg.AddrWidthFull-LineOffset)]
                             << LineOffset);
    next_line_address  = this_line_address + LineBytes;
    bytes_on_line      = next_line_address - curr_chan_i.addr;
    beats_on_line      = axi_pkg::len_t'((bytes_on_line - 1) >> curr_chan_i.size) + 1;
    wrap_bytes         = (addr_t'(curr_chan_i.len) + addr_t'(1)) << curr_chan_i.size;
    is_intra_line_wrap = (curr_chan_i.burst == axi_pkg::BURST_WRAP) && (wrap_bytes <= LineBytes);

    if (rule_valid) begin
      if (rule_index != '0) begin
        desc_o.spm     = 1'b1;
        desc_o.way_ind = indi_t'(1 << (rule_index - 1));
      end
    end else begin
      desc_o.spm     = 1'b1;
      desc_o.way_ind = indi_t'(1 << 0);
      desc_o.x_resp  = axi_pkg::RESP_SLVERR;
    end

    if (((beats_on_line - 1) < curr_chan_i.len) &&
        !(curr_chan_i.burst == axi_pkg::BURST_FIXED) &&
        !is_intra_line_wrap) begin
      next_chan_o.addr = next_line_address;
      next_chan_o.len  = curr_chan_i.len - beats_on_line;
      desc_o.a_x_len   = beats_on_line - 1;
      desc_o.x_last    = 1'b0;
    end else begin
      next_chan_o.addr = addr_t'(0);
      next_chan_o.len  = axi_pkg::len_t'(0);
      desc_o.a_x_len   = curr_chan_i.len;
      desc_o.x_last    = 1'b1;
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
