// Copyright © 2019-2023
// Licensed under the Apache License, Version 2.0.

`include "VX_cache_define.vh"

module plru_decoder import VX_gpu_pkg::*; #(
    parameter NUM_WAYS      = 1,
    parameter WAY_IDX_BITS  = $clog2(NUM_WAYS),
    parameter WAY_IDX_WIDTH = `UP(WAY_IDX_BITS)
) (
    input wire [WAY_IDX_WIDTH-1:0]    way_idx,
    output wire [`UP(NUM_WAYS-1)-1:0] lru_data,
    output wire [`UP(NUM_WAYS-1)-1:0] lru_mask
);
    if (NUM_WAYS > 1) begin : g_dec
        wire [`UP(NUM_WAYS-1)-1:0] data;
        wire [`UP(NUM_WAYS-1)-1:0] mask;
        for (genvar i = 0; i < NUM_WAYS-1; ++i) begin : g_i
            if (i == 0) begin : g_i_0
                assign mask[i] = 1'b1;
            end else if (i % 2 == 1) begin : g_i_odd
                assign mask[i] = mask[(i-1)/2] & ~way_idx[WAY_IDX_BITS-$clog2(i+2)+1];
            end else begin : g_i_even
                assign mask[i] = mask[(i-2)/2] & way_idx[WAY_IDX_BITS-$clog2(i+2)+1];
            end
            assign data[i] = ~way_idx[WAY_IDX_BITS-$clog2(i+2)];
        end
        assign lru_data = data;
        assign lru_mask = mask;
    end else begin : g_no_dec
        `UNUSED_VAR (way_idx)
        assign lru_data = '0;
        assign lru_mask = '0;
    end
endmodule

module plru_encoder #(
    parameter NUM_WAYS      = 1,
    parameter WAY_IDX_BITS  = $clog2(NUM_WAYS),
    parameter WAY_IDX_WIDTH = `UP(WAY_IDX_BITS)
) (
    input wire [`UP(NUM_WAYS-1)-1:0] lru_in,
    output wire [WAY_IDX_WIDTH-1:0] way_idx
);
    if (NUM_WAYS > 1) begin : g_enc
        wire [WAY_IDX_BITS-1:0] tmp;
        for (genvar i = 0; i < WAY_IDX_BITS; ++i) begin : g_i
            if (i == 0) begin : g_i_0
                assign tmp[WAY_IDX_WIDTH-1] = lru_in[0];
            end else begin : g_i_n
                VX_mux #(
                    .N (2**i)
                ) mux (
                    .data_in  (lru_in[((2**i)-1)+:(2**i)]),
                    .sel_in   (tmp[WAY_IDX_BITS-1-:i]),
                    .data_out (tmp[WAY_IDX_BITS-1-i])
                );
            end
        end
        assign way_idx = tmp;
    end else begin : g_no_enc
        `UNUSED_VAR (lru_in)
        assign way_idx = '0;
    end
endmodule

module VX_cache_repl #(
    parameter CACHE_SIZE = 1024,
    parameter LINE_SIZE  = 64,
    parameter NUM_BANKS  = 1,
    parameter NUM_WAYS   = 1,
    parameter REPL_POLICY = `CS_REPL_FIFO
) (
    input wire clk,
    input wire reset,
    input wire stall,
    input wire init,
    input wire lookup_valid,
    input wire lookup_hit,
    input wire [`CS_LINE_SEL_BITS-1:0] lookup_line,
    input wire [`CS_WAY_SEL_WIDTH-1:0] lookup_way,
    input wire repl_valid,
    input wire [`CS_LINE_SEL_BITS-1:0] repl_line,
    input wire [`CS_LINE_SEL_BITS-1:0] repl_line_n,
    output wire [`CS_WAY_SEL_WIDTH-1:0] repl_way
);
    localparam WAY_SEL_WIDTH = `CS_WAY_SEL_WIDTH;
    localparam NUM_SETS      = `CS_LINES_PER_BANK;

    if (NUM_WAYS > 1) begin : g_enable
        if (REPL_POLICY == `CS_REPL_PLRU) begin : g_plru
            localparam LRU_WIDTH = `UP(NUM_WAYS-1);

            reg [LRU_WIDTH-1:0] plru_arr [0:NUM_SETS-1];
            reg [LRU_WIDTH-1:0] plru_rdata_r;

            wire hit_upd = lookup_valid && lookup_hit;
            wire [LRU_WIDTH-1:0] hit_wdata, hit_wmask;
            wire [LRU_WIDTH-1:0] fill_wdata, fill_wmask;
            wire [WAY_SEL_WIDTH-1:0] victim_way_w;

            plru_decoder #(.NUM_WAYS(NUM_WAYS)) u_hit_dec (
                .way_idx  (lookup_way),
                .lru_data (hit_wdata),
                .lru_mask (hit_wmask)
            );

            plru_encoder #(.NUM_WAYS(NUM_WAYS)) u_plru_enc (
                .lru_in  (plru_rdata_r),
                .way_idx (victim_way_w)
            );

            plru_decoder #(.NUM_WAYS(NUM_WAYS)) u_fill_dec (
                .way_idx  (victim_way_w),
                .lru_data (fill_wdata),
                .lru_mask (fill_wmask)
            );

            // Compute next PLRU vector for any set accounting for init, hit_upd, and repl_valid
            wire [LRU_WIDTH-1:0] cur_hit_set  = plru_arr[lookup_line];
            wire [LRU_WIDTH-1:0] cur_fill_set = plru_arr[repl_line];
            wire [LRU_WIDTH-1:0] cur_next_set = plru_arr[repl_line_n];

            wire [LRU_WIDTH-1:0] after_hit_for_fill = (hit_upd && (lookup_line == repl_line))
                ? ((cur_fill_set & ~hit_wmask) | (hit_wdata & hit_wmask))
                : cur_fill_set;
            wire [LRU_WIDTH-1:0] nxt_fill_val = (after_hit_for_fill & ~fill_wmask) | (fill_wdata & fill_wmask);
            wire [LRU_WIDTH-1:0] nxt_hit_val  = (cur_hit_set & ~hit_wmask) | (hit_wdata & hit_wmask);

            reg [LRU_WIDTH-1:0] rdata_next;
            always @(*) begin
                rdata_next = cur_next_set;
                if (hit_upd && (lookup_line == repl_line_n))
                    rdata_next = (rdata_next & ~hit_wmask) | (hit_wdata & hit_wmask);
                if (repl_valid && (repl_line == repl_line_n))
                    rdata_next = (rdata_next & ~fill_wmask) | (fill_wdata & fill_wmask);
                if (init && (repl_line == repl_line_n))
                    rdata_next = '0;
            end

            always @(posedge clk) begin
                if (reset) begin
                    for (int s = 0; s < NUM_SETS; ++s)
                        plru_arr[s] <= '0;
                    plru_rdata_r <= '0;
                end else begin
                    if (hit_upd)
                        plru_arr[lookup_line] <= nxt_hit_val;
                    if (repl_valid)
                        plru_arr[repl_line] <= nxt_fill_val;
                    if (init)
                        plru_arr[repl_line] <= '0;
                    if (~stall)
                        plru_rdata_r <= rdata_next;
                end
            end

            assign repl_way = victim_way_w;

        end else begin : g_other
            `UNUSED_VAR ({clk, reset, stall, init, lookup_valid, lookup_hit, lookup_line, lookup_way, repl_valid, repl_line, repl_line_n})
            assign repl_way = '0;
        end
    end else begin : g_disable
        `UNUSED_VAR ({clk, reset, stall, init, lookup_valid, lookup_hit, lookup_line, lookup_way, repl_valid, repl_line, repl_line_n})
        assign repl_way = 1'b0;
    end

endmodule
