// Copyright © 2019-2023
// Licensed under the Apache License, Version 2.0.

`include "VX_cache_define.vh"

module VX_cache_repl import VX_gpu_pkg::*; #(
    parameter CACHE_SIZE  = 1024,
    parameter LINE_SIZE   = 64,
    parameter NUM_BANKS   = 1,
    parameter NUM_WAYS    = 1,
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
    localparam LRU_WIDTH     = `UP(NUM_WAYS-1);

    if (NUM_WAYS == 4 && REPL_POLICY == `CS_REPL_PLRU) begin : g_plru4
        wire [2:0] ram_rdata;
        wire       hit_now = lookup_valid && lookup_hit;

        // 1-entry skid register when a fill (st0) and hit (st1) contend for the single LUTRAM write port
        reg                          def_hit_vld_r;
        reg [`CS_LINE_SEL_BITS-1:0]  def_hit_line_r;
        reg [1:0]                    def_hit_way_r;

        always @(posedge clk) begin
            if (reset || init) begin
                def_hit_vld_r <= 1'b0;
            end else if (repl_valid && hit_now) begin
                def_hit_vld_r  <= (lookup_line != repl_line);
                def_hit_line_r <= lookup_line;
                def_hit_way_r  <= lookup_way;
            end else if (!repl_valid && !hit_now && def_hit_vld_r) begin
                def_hit_vld_r  <= 1'b0;
            end
        end

        // Same-set 1-cycle RDW bypass held across pipeline stalls
        wire       rdw_vld_r;
        wire [2:0] rdw_dat_r, rdw_msk_r;
        wire [`CS_LINE_SEL_BITS-1:0] rdw_set_r;

        wire [2:0] eff_lru = (rdw_vld_r && (repl_line == rdw_set_r))
            ? ((ram_rdata & ~rdw_msk_r) | (rdw_dat_r & rdw_msk_r))
            : ram_rdata;

        wire v_b1 = eff_lru[0];
        wire v_b0 = v_b1 ? eff_lru[2] : eff_lru[1];
        wire [1:0] victim_w = {v_b1, v_b0};
        assign repl_way = victim_w;

        function automatic [5:0] encode_4way_upd(input [1:0] w);
            logic [2:0] d, m;
            m[0] = 1'b1;
            m[1] = ~w[1];
            m[2] =  w[1];
            d[0] = ~w[1];
            d[1] = ~w[0];
            d[2] = ~w[0];
            return {d, m};
        endfunction

        wire use_fill = repl_valid;
        wire use_hit  = !repl_valid && hit_now;
        wire use_def  = !repl_valid && !hit_now && def_hit_vld_r;

        wire [5:0] fill_dm = encode_4way_upd(victim_w);
        wire [5:0] hit_dm  = encode_4way_upd(lookup_way);
        wire [5:0] def_dm  = encode_4way_upd(def_hit_way_r);

        wire write_en = init || use_fill || use_hit || use_def;
        wire [`CS_LINE_SEL_BITS-1:0] waddr_mux = (init || use_fill) ? repl_line
                                               : (use_hit           ? lookup_line : def_hit_line_r);
        wire [2:0] wdata_mux = init ? 3'b000
                             : (use_fill ? ((hit_now && (lookup_line == repl_line))
                                            ? ((hit_dm[5:3] & hit_dm[2:0] & ~fill_dm[2:0]) | (fill_dm[5:3] & fill_dm[2:0]))
                                            : fill_dm[5:3])
                             : (use_hit ? hit_dm[5:3] : def_dm[5:3]));
        wire [2:0] wmask_mux = init ? 3'b111
                             : (use_fill ? ((hit_now && (lookup_line == repl_line))
                                            ? (hit_dm[2:0] | fill_dm[2:0])
                                            : fill_dm[2:0])
                             : (use_hit ? hit_dm[2:0] : def_dm[2:0]));

        `BUFFER_EX(rdw_vld_r, write_en, ~stall, 1, 1);
        `BUFFER_EX(rdw_dat_r, wdata_mux, ~stall, 3, 1);
        `BUFFER_EX(rdw_msk_r, wmask_mux, ~stall, 3, 1);
        `BUFFER_EX(rdw_set_r, waddr_mux, ~stall, `CS_LINE_SEL_BITS, 1);

        VX_dp_ram #(
            .DATAW    (3),
            .SIZE     (`CS_LINES_PER_BANK),
            .WRENW    (3),
            .OUT_REG  (1),
            .LUTRAM   (1),
            .RDW_MODE ("R")
        ) plru_store (
            .clk   (clk),
            .reset (reset),
            .read  (~stall),
            .write (write_en),
            .wren  (wmask_mux),
            .waddr (waddr_mux),
            .raddr (repl_line_n),
            .wdata (wdata_mux),
            .rdata (ram_rdata)
        );
    end else begin : g_fallback
        `UNUSED_VAR ({clk, reset, stall, init, lookup_valid, lookup_hit, lookup_line, lookup_way, repl_valid, repl_line, repl_line_n})
        assign repl_way = '0;
    end

endmodule
