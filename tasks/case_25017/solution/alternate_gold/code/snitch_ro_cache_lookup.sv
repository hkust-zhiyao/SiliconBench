// Copyright 2020 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

/// Cache lookup with internal range-invalidation FSM and 2-slot circular output FIFO (alt_gold_1).
module snitch_ro_cache_lookup #(
    parameter snitch_icache_pkg::config_t CFG = '0,
    parameter type sram_cfg_data_t  = logic,
    parameter type sram_cfg_tag_t   = logic
)(
    input  logic clk_i,
    input  logic rst_ni,

    input  logic flush_valid_i,
    output logic flush_ready_o,
    output logic busy_o,

    input  logic                        inv_req_i,
    input  logic [CFG.COUNT_ALIGN-1:0]  inv_start_i,
    input  logic [CFG.COUNT_ALIGN:0]    inv_cnt_i,
    output logic                        inv_gnt_o,

    input  logic [CFG.FETCH_AW-1:0]     in_addr_i,
    input  logic [CFG.ID_WIDTH_REQ-1:0] in_id_i,
    input  logic                        in_valid_i,
    output logic                        in_ready_o,

    output logic [CFG.FETCH_AW-1:0]     out_addr_o,
    output logic [CFG.ID_WIDTH_REQ-1:0] out_id_o,
    output logic [CFG.SET_ALIGN-1:0]    out_set_o,
    output logic                        out_hit_o,
    output logic [CFG.LINE_WIDTH-1:0]   out_data_o,
    output logic                        out_error_o,
    output logic                        out_valid_o,
    input  logic                        out_ready_i,

    input  logic [CFG.COUNT_ALIGN-1:0]  write_addr_i,
    input  logic [CFG.SET_ALIGN-1:0]    write_set_i,
    input  logic [CFG.LINE_WIDTH-1:0]   write_data_i,
    input  logic [CFG.TAG_WIDTH-1:0]    write_tag_i,
    input  logic                        write_error_i,
    input  logic                        write_valid_i,
    output logic                        write_ready_o,

    input  sram_cfg_data_t  sram_cfg_data_i,
    input  sram_cfg_tag_t   sram_cfg_tag_i
);

    logic [CFG.COUNT_ALIGN-1:0] ram_addr;
    logic [CFG.SET_COUNT-1:0]   ram_enable;
    logic [CFG.LINE_WIDTH-1:0]  ram_wdata, ram_rdata [CFG.SET_COUNT];
    logic [CFG.TAG_WIDTH+1:0]   ram_wtag,  ram_rtag  [CFG.SET_COUNT];
    logic                       ram_write, ram_write_q;
    logic [CFG.COUNT_ALIGN:0]   init_count_q;

    logic                       inv_active_q;
    logic [CFG.COUNT_ALIGN-1:0] inv_idx_q;
    logic [CFG.COUNT_ALIGN:0]   inv_rem_q;

    typedef struct packed {
        logic [CFG.FETCH_AW-1:0]     addr;
        logic [CFG.ID_WIDTH_REQ-1:0] id;
        logic [CFG.SET_ALIGN-1:0]    cset;
        logic                        hit;
        logic [CFG.LINE_WIDTH-1:0]   data;
        logic                        error;
    } rsp_entry_t;

    rsp_entry_t slot_q [0:1];
    rsp_entry_t sram_rsp_d;
    logic       wptr_q, rptr_q;
    logic [1:0] occ_q;
    logic       sram_vld_q;
    logic [CFG.FETCH_AW-1:0]     addr_q;
    logic [CFG.ID_WIDTH_REQ-1:0] id_q;

    wire init_running = (init_count_q != $unsigned(CFG.LINE_COUNT));
    wire pipe_empty   = !sram_vld_q && (occ_q == 2'd0);
    wire can_push_lookup = (occ_q == 2'd0) || ((occ_q == 2'd1) && (!sram_vld_q || out_ready_i));

    assign busy_o        = init_running || inv_active_q;
    assign flush_ready_o = !init_running && !inv_active_q && pipe_empty;
    assign inv_gnt_o     = !init_running && !inv_active_q && pipe_empty;

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            init_count_q <= '0;
            inv_active_q <= 1'b0;
            inv_idx_q    <= '0;
            inv_rem_q    <= '0;
        end else begin
            if (init_running) begin
                init_count_q <= init_count_q + 1'b1;
            end else if (flush_valid_i && flush_ready_o) begin
                init_count_q <= '0;
            end

            if (!inv_active_q) begin
                if (inv_req_i && inv_gnt_o && (inv_cnt_i != '0)) begin
                    inv_active_q <= 1'b1;
                    inv_idx_q    <= inv_start_i;
                    inv_rem_q    <= inv_cnt_i;
                end
            end else begin
                if (inv_rem_q <= (CFG.COUNT_ALIGN+1)'(1)) begin
                    inv_active_q <= 1'b0;
                    inv_rem_q    <= '0;
                end else begin
                    inv_idx_q <= inv_idx_q + 1'b1;
                    inv_rem_q <= inv_rem_q - 1'b1;
                end
            end
        end
    end

    always_comb begin : p_portmux
        write_ready_o = 1'b0;
        in_ready_o    = 1'b0;
        ram_addr      = in_addr_i >> CFG.LINE_ALIGN;
        ram_wdata     = write_data_i;
        ram_wtag      = {~write_error_i, 1'b0, write_tag_i};
        ram_enable    = '0;
        ram_write     = 1'b0;

        if (init_running) begin
            ram_addr   = init_count_q[CFG.COUNT_ALIGN-1:0];
            ram_enable = '1;
            ram_write  = 1'b1;
            ram_wdata  = '0;
            ram_wtag   = '0;
        end else if (inv_active_q) begin
            ram_addr   = inv_idx_q;
            ram_enable = '1;
            ram_write  = 1'b1;
            ram_wdata  = '0;
            ram_wtag   = '0;
        end else if (write_valid_i) begin
            ram_addr      = write_addr_i;
            ram_enable    = CFG.SET_COUNT > 1 ? $unsigned(1 << write_set_i) : 1'b1;
            ram_write     = 1'b1;
            write_ready_o = 1'b1;
        end else if (!flush_valid_i && !inv_req_i && can_push_lookup) begin
            ram_enable = in_valid_i ? '1 : '0;
            in_ready_o = 1'b1;
        end
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            ram_write_q <= 1'b0;
            sram_vld_q  <= 1'b0;
            addr_q      <= '0;
            id_q        <= '0;
        end else begin
            ram_write_q <= ram_write;
            sram_vld_q  <= in_valid_i && in_ready_o;
            if (in_valid_i && in_ready_o) begin
                addr_q <= in_addr_i;
                id_q   <= in_id_i;
            end
        end
    end

    for (genvar i = 0; i < CFG.SET_COUNT; i++) begin : g_sets
        tc_sram_impl #(
            .NumWords  ( CFG.LINE_COUNT  ),
            .DataWidth ( CFG.TAG_WIDTH+2 ),
            .ByteWidth ( 8               ),
            .NumPorts  ( 1               ),
            .Latency   ( 1               ),
            .impl_in_t ( sram_cfg_tag_t  )
        ) i_tag (
            .clk_i   ( clk_i         ),
            .rst_ni  ( rst_ni        ),
            .impl_i  ( sram_cfg_tag_i),
            .impl_o  (               ),
            .req_i   ( ram_enable[i] ),
            .we_i    ( ram_write     ),
            .addr_i  ( ram_addr      ),
            .wdata_i ( ram_wtag      ),
            .be_i    ( '1            ),
            .rdata_o ( ram_rtag[i]   )
        );

        tc_sram_impl #(
            .NumWords  ( CFG.LINE_COUNT  ),
            .DataWidth ( CFG.LINE_WIDTH  ),
            .ByteWidth ( 8               ),
            .NumPorts  ( 1               ),
            .Latency   ( 1               ),
            .impl_in_t ( sram_cfg_data_t )
        ) i_data (
            .clk_i   ( clk_i          ),
            .rst_ni  ( rst_ni         ),
            .impl_i  ( sram_cfg_data_i),
            .impl_o  (                ),
            .req_i   ( ram_enable[i]  ),
            .we_i    ( ram_write      ),
            .addr_i  ( ram_addr       ),
            .wdata_i ( ram_wdata      ),
            .be_i    ( '1             ),
            .rdata_o ( ram_rdata[i]   )
        );
    end

    logic [CFG.TAG_WIDTH-1:0] required_tag;
    logic [CFG.SET_COUNT-1:0] line_hit;

    always_comb begin
        automatic logic [CFG.SET_COUNT-1:0] errors;
        required_tag = addr_q >> (CFG.LINE_ALIGN + CFG.COUNT_ALIGN);
        for (int i = 0; i < CFG.SET_COUNT; i++) begin
            line_hit[i] = ram_rtag[i][CFG.TAG_WIDTH+1] &&
                          (ram_rtag[i][CFG.TAG_WIDTH-1:0] == required_tag);
            errors[i]   = ram_rtag[i][CFG.TAG_WIDTH] && line_hit[i];
        end
        sram_rsp_d.addr  = addr_q;
        sram_rsp_d.id    = id_q;
        sram_rsp_d.hit   = (|line_hit) & ~ram_write_q;
        sram_rsp_d.error = |errors;
        for (int b = 0; b < CFG.LINE_WIDTH; b++) begin
            automatic logic [CFG.SET_COUNT-1:0] masked;
            for (int w = 0; w < CFG.SET_COUNT; w++)
                masked[w] = ram_rdata[w][b] & line_hit[w];
            sram_rsp_d.data[b] = |masked;
        end
    end

    lzc #(.WIDTH(CFG.SET_COUNT)) i_lzc (
        .in_i    ( line_hit        ),
        .cnt_o   ( sram_rsp_d.cset ),
        .empty_o (                 )
    );

    wire do_push = sram_vld_q;
    wire do_pop  = (occ_q != 2'd0) && out_ready_i;

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            slot_q[0] <= '0;
            slot_q[1] <= '0;
            wptr_q    <= 1'b0;
            rptr_q    <= 1'b0;
            occ_q     <= 2'd0;
        end else begin
            if (do_push) begin
                slot_q[wptr_q] <= sram_rsp_d;
                wptr_q         <= ~wptr_q;
            end
            if (do_pop) begin
                rptr_q <= ~rptr_q;
            end
            occ_q <= occ_q + 2'(do_push) - 2'(do_pop);
        end
    end

    assign out_valid_o = (occ_q != 2'd0);
    assign out_addr_o  = slot_q[rptr_q].addr;
    assign out_id_o    = slot_q[rptr_q].id;
    assign out_set_o   = slot_q[rptr_q].cset;
    assign out_hit_o   = slot_q[rptr_q].hit;
    assign out_data_o  = slot_q[rptr_q].data;
    assign out_error_o = slot_q[rptr_q].error;

endmodule
