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
    `UNUSED_PARAM ({WRITEBACK, DIRTY_BYTES})

    localparam WAY_SEL_BITS    = `CS_WAY_SEL_BITS;
    localparam DATA_RAM_DEPTH  = `CS_LINES_PER_BANK * NUM_WAYS;
    localparam DATA_ADDR_WIDTH = `LOG2UP(DATA_RAM_DEPTH);

    wire [`CS_WAY_SEL_WIDTH-1:0] hit_way;
    VX_onehot_encoder #(
        .N (NUM_WAYS)
    ) hit_way_enc (
        .data_in  (tag_matches),
        .data_out (hit_way),
        `UNUSED_PIN (valid_out)
    );

    wire hit_any = (| tag_matches);
    wire [`CS_WAY_SEL_WIDTH-1:0] way_sel = fill ? evict_way : hit_way;
    wire [DATA_ADDR_WIDTH-1:0] data_addr = DATA_ADDR_WIDTH'({way_sel[WAY_SEL_BITS-1:0], line_idx});
    wire [7:0] sram_addr = 8'(data_addr);

    assign evict_byteen = '1;

    wire [3:0]         slice_men;
    wire [3:0]         slice_wen;
    wire [3:0]         slice_ren;
    wire [3:0][63:0]   slice_din;
    wire [3:0][63:0]   slice_bm;
    wire [3:0][63:0]   line_rdata;

    for (genvar s = 0; s < 4; ++s) begin : g_slice_ctrl
        localparam SLICE_SECTOR = s / `CS_WORDS_PER_SECTOR;
        wire word_en     = (word_idx == s[1:0]);
        wire fill_sec_en = (sector_idx == `UP(`CS_SECTOR_SEL_BITS)'(SLICE_SECTOR));

        wire s_rd = read;
        wire s_wr = WRITE_ENABLE ? ((fill && fill_sec_en) || (write && hit_any && word_en))
                                 : (fill && fill_sec_en);
        wire [7:0] s_be = fill ? 8'hFF : write_byteen;

        assign slice_wen[s] = s_wr;
        assign slice_ren[s] = s_rd && !s_wr;
        assign slice_men[s] = 1'b1;
        assign slice_din[s] = fill ? fill_data[s] : write_word;
        assign slice_bm[s]  = {56'd0, s_be};
    end

    RM_IHPSG13_1P_256x64_c2_bm_bist u_data_slice_0 (
        .A_CLK(clk), .A_MEN(slice_men[0]), .A_WEN(slice_wen[0]), .A_REN(slice_ren[0]),
        .A_ADDR(sram_addr), .A_DIN(slice_din[0]), .A_DLY(1'b1), .A_DOUT(line_rdata[0]), .A_BM(slice_bm[0]),
        .A_BIST_CLK(1'b0), .A_BIST_EN(1'b0), .A_BIST_MEN(1'b0), .A_BIST_WEN(1'b0), .A_BIST_REN(1'b0),
        .A_BIST_ADDR(8'd0), .A_BIST_DIN(64'd0), .A_BIST_BM(64'd0)
    );
    RM_IHPSG13_1P_256x64_c2_bm_bist u_data_slice_1 (
        .A_CLK(clk), .A_MEN(slice_men[1]), .A_WEN(slice_wen[1]), .A_REN(slice_ren[1]),
        .A_ADDR(sram_addr), .A_DIN(slice_din[1]), .A_DLY(1'b1), .A_DOUT(line_rdata[1]), .A_BM(slice_bm[1]),
        .A_BIST_CLK(1'b0), .A_BIST_EN(1'b0), .A_BIST_MEN(1'b0), .A_BIST_WEN(1'b0), .A_BIST_REN(1'b0),
        .A_BIST_ADDR(8'd0), .A_BIST_DIN(64'd0), .A_BIST_BM(64'd0)
    );
    RM_IHPSG13_1P_256x64_c2_bm_bist u_data_slice_2 (
        .A_CLK(clk), .A_MEN(slice_men[2]), .A_WEN(slice_wen[2]), .A_REN(slice_ren[2]),
        .A_ADDR(sram_addr), .A_DIN(slice_din[2]), .A_DLY(1'b1), .A_DOUT(line_rdata[2]), .A_BM(slice_bm[2]),
        .A_BIST_CLK(1'b0), .A_BIST_EN(1'b0), .A_BIST_MEN(1'b0), .A_BIST_WEN(1'b0), .A_BIST_REN(1'b0),
        .A_BIST_ADDR(8'd0), .A_BIST_DIN(64'd0), .A_BIST_BM(64'd0)
    );
    RM_IHPSG13_1P_256x64_c2_bm_bist u_data_slice_3 (
        .A_CLK(clk), .A_MEN(slice_men[3]), .A_WEN(slice_wen[3]), .A_REN(slice_ren[3]),
        .A_ADDR(sram_addr), .A_DIN(slice_din[3]), .A_DLY(1'b1), .A_DOUT(line_rdata[3]), .A_BM(slice_bm[3]),
        .A_BIST_CLK(1'b0), .A_BIST_EN(1'b0), .A_BIST_MEN(1'b0), .A_BIST_WEN(1'b0), .A_BIST_REN(1'b0),
        .A_BIST_ADDR(8'd0), .A_BIST_DIN(64'd0), .A_BIST_BM(64'd0)
    );

    assign read_data = line_rdata;

endmodule
