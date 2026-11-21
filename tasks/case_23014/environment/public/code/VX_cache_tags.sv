// Copyright © 2019-2023
// Licensed under the Apache License, Version 2.0.

`include "VX_cache_define.vh"

module VX_cache_tags import VX_gpu_pkg::*; #(
    parameter CACHE_SIZE    = 1024,
    parameter LINE_SIZE     = 16,
    parameter NUM_BANKS     = 1,
    parameter NUM_WAYS      = 1,
    parameter WORD_SIZE     = 1,
    parameter SECTOR_SIZE   = LINE_SIZE,
    parameter WRITEBACK     = 0,
    parameter AMO_ENABLE    = 0
) (
    input wire                          clk,
    input wire                          reset,
    input wire                          stall,
    input wire                          init,
    input wire                          flush,
    input wire                          fill,
    input wire                          read,
    input wire                          write,
    input wire                          invalidate,
    input wire [`CS_LINE_SEL_BITS-1:0]  line_idx,
    input wire [`CS_LINE_SEL_BITS-1:0]  line_idx_n,
    input wire [`CS_TAG_SEL_BITS-1:0]   line_tag,
    input wire [`UP(`CS_SECTOR_SEL_BITS)-1:0] sector_idx,
    input wire [`CS_WAY_SEL_WIDTH-1:0]  evict_way,
    input wire [NUM_WAYS-1:0]           fill_way_oh,
    output wire [NUM_WAYS-1:0]          tag_matches,
    output wire [NUM_WAYS-1:0]          line_present,
    output wire                         evict_dirty,
    output wire [`CS_SECTORS_PER_LINE-1:0] evict_dirty_mask,
    output wire [`CS_TAG_SEL_BITS-1:0]  evict_tag
);
    localparam SEC = `CS_SECTORS_PER_LINE;
    `UNUSED_VAR ({read, write, evict_way})
    `UNUSED_PARAM (WRITEBACK)

    assign evict_dirty      = 1'b0;
    assign evict_dirty_mask = '0;
    assign evict_tag        = '0;

    wire [SEC-1:0] sec_oh = SEC'(1) << sector_idx;

    wire [NUM_WAYS-1:0]                       line_write;
    wire [NUM_WAYS-1:0][`CS_TAG_SEL_BITS-1:0] line_wdata;
    wire [NUM_WAYS-1:0][`CS_TAG_SEL_BITS-1:0] tag_rdata;

    wire [NUM_WAYS-1:0][SEC-1:0] valid_wren;
    wire [NUM_WAYS-1:0][SEC-1:0] valid_wdata;
    wire [NUM_WAYS-1:0][SEC-1:0] valid_rdata;

    for (genvar i = 0; i < NUM_WAYS; ++i) begin : g_way_decode
        wire do_init  = init;
        wire do_fill  = fill && ((NUM_WAYS == 1) || fill_way_oh[i]);
        wire do_flush = flush;

        assign line_write[i] = do_fill;
        assign line_wdata[i] = line_tag;

        wire rdw_fill_raw;
        wire [SEC-1:0] rdw_sec_oh;
        wire [`CS_TAG_SEL_BITS-1:0]  rdw_tag;
        wire [`CS_LINE_SEL_BITS-1:0] rdw_set;
        wire rdw_refill;
        `BUFFER_EX(rdw_fill_raw, do_fill, ~stall, 1, 1);
        `BUFFER_EX(rdw_sec_oh, sec_oh, ~stall, $bits(rdw_sec_oh), 1);
        `BUFFER_EX(rdw_tag, line_tag, ~stall, $bits(rdw_tag), 1);
        `BUFFER_EX(rdw_set, line_idx, ~stall, $bits(rdw_set), 1);
        wire way_filled = rdw_fill_raw && (line_idx == rdw_set);

        wire [`CS_TAG_SEL_BITS-1:0] read_tag_w = way_filled ? rdw_tag : tag_rdata[i];
        wire tag_eq = (line_tag == read_tag_w);

        wire [SEC-1:0] read_valid_w = way_filled
            ? (rdw_refill ? (valid_rdata[i] | rdw_sec_oh) : rdw_sec_oh)
            : valid_rdata[i];

        wire raw_hit  = read_valid_w[sector_idx] && tag_eq;
        wire do_inval = (AMO_ENABLE != 0) && invalidate && raw_hit;

        wire fill_refill = do_fill && tag_eq && (| read_valid_w);
        `BUFFER_EX(rdw_refill, do_fill && fill_refill, ~stall, 1, 1);

        wire [SEC-1:0] vset_oh = do_fill ? sec_oh : {SEC{1'b0}};
        wire [SEC-1:0] vclr_oh = ((do_init || do_flush)     ? {SEC{1'b1}} : {SEC{1'b0}})
                               | ((do_fill && ~fill_refill) ? ~sec_oh     : {SEC{1'b0}})
                               | (do_inval                  ? sec_oh      : {SEC{1'b0}});

        assign valid_wren[i]  = vset_oh | vclr_oh;
        assign valid_wdata[i] = vset_oh;

        assign tag_matches[i]  = raw_hit;
        assign line_present[i] = tag_eq && (| read_valid_w);
    end

    wire [7:0]  tag_sram_addr = {2'b00, fill ? line_idx : line_idx_n};
    wire [63:0] tag_sram_din  = line_wdata;
    wire [63:0] tag_sram_bm   = {60'd0, line_write};

    RM_IHPSG13_1P_256x64_c2_bm_bist u_tag_sram (
        .A_CLK       (clk),
        .A_MEN       (1'b1),
        .A_WEN       (fill),
        .A_REN       (~fill && ~stall),
        .A_ADDR      (tag_sram_addr),
        .A_DIN       (tag_sram_din),
        .A_DLY       (1'b1),
        .A_DOUT      (tag_rdata),
        .A_BM        (tag_sram_bm),
        .A_BIST_CLK  (1'b0),
        .A_BIST_EN   (1'b0),
        .A_BIST_MEN  (1'b0),
        .A_BIST_WEN  (1'b0),
        .A_BIST_REN  (1'b0),
        .A_BIST_ADDR (8'd0),
        .A_BIST_DIN  (64'd0),
        .A_BIST_BM   (64'd0)
    );

    VX_dp_ram #(
        .DATAW    (NUM_WAYS * SEC),
        .WRENW    (NUM_WAYS * SEC),
        .SIZE     (`CS_LINES_PER_BANK),
        .OUT_REG  (1),
        .LUTRAM   (1),
        .RDW_MODE ("R")
    ) valid_store (
        .clk   (clk),
        .reset (reset),
        .read  (~stall),
        .write (| valid_wren),
        .wren  (valid_wren),
        .waddr (line_idx),
        .raddr (line_idx_n),
        .wdata (valid_wdata),
        .rdata (valid_rdata)
    );

endmodule
