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
    localparam SEC      = `CS_SECTORS_PER_LINE;
    localparam NUM_SETS = `CS_LINES_PER_BANK;
    `UNUSED_VAR ({read, write, evict_way})
    `UNUSED_PARAM (WRITEBACK)

    assign evict_dirty      = 1'b0;
    assign evict_dirty_mask = '0;
    assign evict_tag        = '0;

    wire [SEC-1:0] sec_oh = SEC'(1) << sector_idx;

    wire [NUM_WAYS-1:0]                       line_write;
    wire [NUM_WAYS-1:0][`CS_TAG_SEL_BITS-1:0] line_wdata;
    wire [NUM_WAYS-1:0][`CS_TAG_SEL_BITS-1:0] tag_rdata;

    // Explicit flop-based sector-valid array with cycle-accurate look-ahead read
    reg  [NUM_WAYS-1:0][SEC-1:0] valid_table_r [0:NUM_SETS-1];
    reg  [NUM_WAYS-1:0][SEC-1:0] valid_q_r;
    wire [NUM_WAYS-1:0][SEC-1:0] valid_next_cur;

    for (genvar i = 0; i < NUM_WAYS; ++i) begin : g_way
        wire do_fill = fill && fill_way_oh[i];

        assign line_write[i] = do_fill;
        assign line_wdata[i] = line_tag;

        reg                        byp_vld_r;
        reg [`CS_TAG_SEL_BITS-1:0] byp_tag_r;
        reg [`CS_LINE_SEL_BITS-1:0] byp_set_r;
        always @(posedge clk) begin
            if (reset) begin
                byp_vld_r <= 1'b0;
            end else if (~stall) begin
                byp_vld_r <= do_fill;
                byp_tag_r <= line_tag;
                byp_set_r <= line_idx;
            end
        end

        wire use_byp   = byp_vld_r && (line_idx == byp_set_r);
        wire eq_byp    = (line_tag == byp_tag_r);
        wire eq_sram   = (line_tag == tag_rdata[i]);
        wire tag_match = use_byp ? eq_byp : eq_sram;

        wire [SEC-1:0] cur_v = valid_q_r[i];
        wire raw_hit         = cur_v[sector_idx] && tag_match;
        wire do_inval        = (AMO_ENABLE != 0) && invalidate && raw_hit;
        wire is_refill       = do_fill && tag_match && (| cur_v);

        assign valid_next_cur[i] = (init || flush) ? {SEC{1'b0}}
                                 : (do_fill        ? (is_refill ? (cur_v | sec_oh) : sec_oh)
                                 : (do_inval       ? (cur_v & ~sec_oh)
                                                   : cur_v));

        assign tag_matches[i]  = raw_hit;
        assign line_present[i] = tag_match && (| cur_v);
    end

    wire any_v_upd = init || flush || fill || ((AMO_ENABLE != 0) && invalidate && (| tag_matches));

    always @(posedge clk) begin
        if (reset) begin
            valid_q_r <= '0;
        end else begin
            if (any_v_upd)
                valid_table_r[line_idx] <= valid_next_cur;
            if (~stall) begin
                valid_q_r <= (any_v_upd && (line_idx == line_idx_n))
                    ? valid_next_cur
                    : valid_table_r[line_idx_n];
            end
        end
    end

    wire        sram_wen  = fill;
    wire        sram_ren  = ~fill && ~stall;
    wire        sram_men  = sram_wen || sram_ren;
    wire [7:0]  sram_addr = {2'b00, fill ? line_idx : line_idx_n};
    wire [63:0] sram_bm   = {
        {16{line_write[3]}}, {16{line_write[2]}},
        {16{line_write[1]}}, {16{line_write[0]}}
    };

    RM_IHPSG13_1P_256x64_c2_bm_bist u_tag_sram (
        .A_CLK       (clk),
        .A_MEN       (sram_men),
        .A_WEN       (sram_wen),
        .A_REN       (sram_ren),
        .A_ADDR      (sram_addr),
        .A_DIN       (line_wdata),
        .A_DLY       (1'b1),
        .A_DOUT      (tag_rdata),
        .A_BM        (sram_bm),
        .A_BIST_CLK  (1'b0),
        .A_BIST_EN   (1'b0),
        .A_BIST_MEN  (1'b0),
        .A_BIST_WEN  (1'b0),
        .A_BIST_REN  (1'b0),
        .A_BIST_ADDR (8'd0),
        .A_BIST_DIN  (64'd0),
        .A_BIST_BM   (64'd0)
    );

endmodule
