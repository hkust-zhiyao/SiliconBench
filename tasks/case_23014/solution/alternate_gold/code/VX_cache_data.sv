// Copyright © 2019-2023
// Licensed under the Apache License, Version 2.0.

`include "VX_cache_define.vh"

module VX_cache_data import VX_gpu_pkg::*; #(
    parameter CACHE_SIZE        = 1024,
    parameter LINE_SIZE         = 16,
    parameter NUM_BANKS         = 1,
    parameter NUM_WAYS          = 1,
    parameter WORD_SIZE         = 1,
    parameter SECTOR_SIZE       = LINE_SIZE,
    parameter WRITE_ENABLE      = 1,
    parameter WRITEBACK         = 0,
    parameter DIRTY_BYTES       = 0
) (
    input wire                          clk,
    input wire                          reset,
    input wire                          init,
    input wire                          fill,
    input wire                          flush,
    input wire                          read,
    input wire                          write,
    input wire [`CS_LINE_SEL_BITS-1:0]  line_idx,
    input wire [`CS_WAY_SEL_WIDTH-1:0]  evict_way,
    input wire [NUM_WAYS-1:0]           tag_matches,
    input wire [`CS_WORDS_PER_LINE-1:0][`CS_WORD_WIDTH-1:0] fill_data,
    input wire [`CS_WORD_WIDTH-1:0]     write_word,
    input wire [WORD_SIZE-1:0]          write_byteen,
    input wire [`UP(`CS_WORD_SEL_BITS)-1:0] word_idx,
    input wire [`UP(`CS_SECTOR_SEL_BITS)-1:0] sector_idx,
    input wire [`CS_WAY_SEL_WIDTH-1:0]  way_idx_r,
    output wire [`CS_LINE_WIDTH-1:0]    read_data,
    output wire [LINE_SIZE-1:0]         evict_byteen
);
    `UNUSED_VAR ({reset, init, flush, way_idx_r})
    `UNUSED_PARAM ({CACHE_SIZE, LINE_SIZE, NUM_BANKS, NUM_WAYS, WORD_SIZE, SECTOR_SIZE, WRITE_ENABLE, WRITEBACK, DIRTY_BYTES})

    // Direct 4-way OR-encoded way select without generic encoder submodule
    wire [1:0] hit_way_b = { (tag_matches[2] | tag_matches[3]), (tag_matches[1] | tag_matches[3]) };
    wire       any_hit   = |tag_matches;
    wire [1:0] sel_way   = fill ? evict_way[1:0] : hit_way_b;
    wire [7:0] row_addr  = {sel_way, line_idx[5:0]};

    assign evict_byteen = '1;

    function automatic [63:0] expand_be64(input [7:0] be);
        expand_be64 = {
            {8{be[7]}}, {8{be[6]}}, {8{be[5]}}, {8{be[4]}},
            {8{be[3]}}, {8{be[2]}}, {8{be[1]}}, {8{be[0]}}
        };
    endfunction

    wire [63:0] wr_bm64 = expand_be64(write_byteen);

    wire [3:0] w_hit_en = {
        (word_idx == 2'd3), (word_idx == 2'd2),
        (word_idx == 2'd1), (word_idx == 2'd0)
    };
    wire [3:0] f_sec_en = {
        (sector_idx == 1'b1), (sector_idx == 1'b1),
        (sector_idx == 1'b0), (sector_idx == 1'b0)
    };

    wire [3:0] do_wr = ({4{fill}} & f_sec_en) | ({4{write && any_hit}} & w_hit_en);
    wire [3:0] do_rd = ({4{read}} & w_hit_en) & ~do_wr;
    wire [3:0] do_en = do_wr | do_rd;

    wire [63:0] bm_sel  = fill ? 64'hFFFF_FFFF_FFFF_FFFF : wr_bm64;
    wire [63:0] din_0   = fill ? fill_data[0] : write_word;
    wire [63:0] din_1   = fill ? fill_data[1] : write_word;
    wire [63:0] din_2   = fill ? fill_data[2] : write_word;
    wire [63:0] din_3   = fill ? fill_data[3] : write_word;

    wire [3:0][63:0] dout_slices;

    RM_IHPSG13_1P_256x64_c2_bm_bist u_data_slice_0 (
        .A_CLK(clk), .A_MEN(do_en[0]), .A_WEN(do_wr[0]), .A_REN(do_rd[0]),
        .A_ADDR(row_addr), .A_DIN(din_0), .A_DLY(1'b1), .A_DOUT(dout_slices[0]), .A_BM(bm_sel),
        .A_BIST_CLK(1'b0), .A_BIST_EN(1'b0), .A_BIST_MEN(1'b0), .A_BIST_WEN(1'b0), .A_BIST_REN(1'b0),
        .A_BIST_ADDR(8'd0), .A_BIST_DIN(64'd0), .A_BIST_BM(64'd0)
    );
    RM_IHPSG13_1P_256x64_c2_bm_bist u_data_slice_1 (
        .A_CLK(clk), .A_MEN(do_en[1]), .A_WEN(do_wr[1]), .A_REN(do_rd[1]),
        .A_ADDR(row_addr), .A_DIN(din_1), .A_DLY(1'b1), .A_DOUT(dout_slices[1]), .A_BM(bm_sel),
        .A_BIST_CLK(1'b0), .A_BIST_EN(1'b0), .A_BIST_MEN(1'b0), .A_BIST_WEN(1'b0), .A_BIST_REN(1'b0),
        .A_BIST_ADDR(8'd0), .A_BIST_DIN(64'd0), .A_BIST_BM(64'd0)
    );
    RM_IHPSG13_1P_256x64_c2_bm_bist u_data_slice_2 (
        .A_CLK(clk), .A_MEN(do_en[2]), .A_WEN(do_wr[2]), .A_REN(do_rd[2]),
        .A_ADDR(row_addr), .A_DIN(din_2), .A_DLY(1'b1), .A_DOUT(dout_slices[2]), .A_BM(bm_sel),
        .A_BIST_CLK(1'b0), .A_BIST_EN(1'b0), .A_BIST_MEN(1'b0), .A_BIST_WEN(1'b0), .A_BIST_REN(1'b0),
        .A_BIST_ADDR(8'd0), .A_BIST_DIN(64'd0), .A_BIST_BM(64'd0)
    );
    RM_IHPSG13_1P_256x64_c2_bm_bist u_data_slice_3 (
        .A_CLK(clk), .A_MEN(do_en[3]), .A_WEN(do_wr[3]), .A_REN(do_rd[3]),
        .A_ADDR(row_addr), .A_DIN(din_3), .A_DLY(1'b1), .A_DOUT(dout_slices[3]), .A_BM(bm_sel),
        .A_BIST_CLK(1'b0), .A_BIST_EN(1'b0), .A_BIST_MEN(1'b0), .A_BIST_WEN(1'b0), .A_BIST_REN(1'b0),
        .A_BIST_ADDR(8'd0), .A_BIST_DIN(64'd0), .A_BIST_BM(64'd0)
    );

    assign read_data = dout_slices;

endmodule
