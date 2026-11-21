// Copyright 2020 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

/// Alternate L1 lookup: 1-cycle FF valid-array invalidation + 2-entry output skid FIFO.
module snitch_icache_lookup #(
    parameter snitch_icache_pkg::config_t CFG = '0,
    parameter type sram_cfg_data_t  = logic,
    parameter type sram_cfg_tag_t   = logic
)(
    input  logic clk_i,
    input  logic rst_ni,

    input  logic flush_valid_i,
    output logic flush_ready_o,
    input  logic [CFG.NR_FETCH_PORTS-1:0] flush_ports_i,

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

    `ifndef SYNTHESIS
    initial assert(CFG != '0);
    `endif

    logic [CFG.COUNT_ALIGN-1:0] ram_addr;
    logic [CFG.SET_COUNT-1:0]   ram_enable;
    logic [CFG.LINE_WIDTH-1:0]  ram_wdata, ram_rdata [CFG.SET_COUNT];
    logic [CFG.TAG_WIDTH+1:0]   ram_wtag,  ram_rtag  [CFG.SET_COUNT];
    logic                       ram_write;
    logic                       ram_write_q;

    // 1-cycle bulk-clearable FF tag-valid bitmask per way
    logic [CFG.SET_COUNT-1:0][CFG.LINE_COUNT-1:0] line_vld_q;
    logic [CFG.SET_COUNT-1:0]                     rd_way_vld_q;

    typedef struct packed {
        logic [CFG.FETCH_AW-1:0]     addr;
        logic [CFG.ID_WIDTH_REQ-1:0] id;
        logic [CFG.SET_ALIGN-1:0]    cset;
        logic                        hit;
        logic [CFG.LINE_WIDTH-1:0]   data;
        logic                        error;
    } skid_entry_t;

    skid_entry_t skid_q [2];
    logic [1:0]  skid_vld_q;
    skid_entry_t sram_rsp;

    logic                        s1_vld_q;
    logic [CFG.FETCH_AW-1:0]     s1_addr_q;
    logic [CFG.ID_WIDTH_REQ-1:0] s1_id_q;

    wire [1:0] occupancy = {1'b0, skid_vld_q[0]} + {1'b0, skid_vld_q[1]} + {1'b0, s1_vld_q};
    wire can_read = !flush_valid_i && (occupancy < 2'd2);

    always_comb begin
        write_ready_o = 1'b0;
        in_ready_o    = 1'b0;
        ram_addr      = CFG.COUNT_ALIGN'(in_addr_i >> CFG.LINE_ALIGN);
        ram_wdata     = write_data_i;
        ram_wtag      = {1'b1, write_error_i, write_tag_i};
        ram_enable    = '0;
        ram_write     = 1'b0;

        if (!flush_valid_i) begin
            if (write_valid_i) begin
                ram_addr      = write_addr_i;
                ram_enable    = CFG.SET_COUNT > 1 ? CFG.SET_COUNT'(1 << write_set_i) : 1'b1;
                ram_write     = 1'b1;
                write_ready_o = 1'b1;
            end else if (can_read) begin
                ram_enable = in_valid_i ? '1 : '0;
                in_ready_o = 1'b1;
            end
        end
    end

    assign flush_ready_o = 1'b1;

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            line_vld_q   <= '0;
            rd_way_vld_q <= '0;
            ram_write_q  <= 1'b0;
            s1_vld_q     <= 1'b0;
            s1_addr_q    <= '0;
            s1_id_q      <= '0;
        end else begin
            ram_write_q <= ram_write;
            if (flush_valid_i) begin
                line_vld_q   <= '0;
                rd_way_vld_q <= '0;
                s1_vld_q     <= 1'b0;
            end else begin
                if (write_valid_i && write_ready_o) begin
                    line_vld_q[write_set_i][write_addr_i] <= 1'b1;
                end
                if (in_valid_i && in_ready_o && !flush_ports_i[in_id_i >> 1]) begin
                    s1_vld_q  <= 1'b1;
                    s1_addr_q <= in_addr_i;
                    s1_id_q   <= in_id_i;
                    for (int w = 0; w < CFG.SET_COUNT; w++) begin
                        rd_way_vld_q[w] <= line_vld_q[w][ram_addr];
                    end
                end else begin
                    s1_vld_q <= 1'b0;
                end
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
            .clk_i   ( clk_i           ),
            .rst_ni  ( rst_ni          ),
            .impl_i  ( sram_cfg_tag_i  ),
            .impl_o  (                 ),
            .req_i   ( ram_enable[i]   ),
            .we_i    ( ram_write       ),
            .addr_i  ( ram_addr        ),
            .wdata_i ( ram_wtag        ),
            .be_i    ( '1              ),
            .rdata_o ( ram_rtag[i]     )
        );

        tc_sram_impl #(
            .NumWords  ( CFG.LINE_COUNT  ),
            .DataWidth ( CFG.LINE_WIDTH  ),
            .ByteWidth ( 8               ),
            .NumPorts  ( 1               ),
            .Latency   ( 1               ),
            .impl_in_t ( sram_cfg_data_t )
        ) i_data (
            .clk_i   ( clk_i           ),
            .rst_ni  ( rst_ni          ),
            .impl_i  ( sram_cfg_data_i ),
            .impl_o  (                 ),
            .req_i   ( ram_enable[i]   ),
            .we_i    ( ram_write       ),
            .addr_i  ( ram_addr        ),
            .wdata_i ( ram_wdata       ),
            .be_i    ( '1              ),
            .rdata_o ( ram_rdata[i]    )
        );
    end

    logic [CFG.TAG_WIDTH-1:0] req_tag;
    logic [CFG.SET_COUNT-1:0] way_hit;

    always_comb begin
        automatic logic [CFG.SET_COUNT-1:0] way_err;
        req_tag = CFG.TAG_WIDTH'(s1_addr_q >> (CFG.LINE_ALIGN + CFG.COUNT_ALIGN));
        for (int i = 0; i < CFG.SET_COUNT; i++) begin
            way_hit[i] = rd_way_vld_q[i] && ram_rtag[i][CFG.TAG_WIDTH+1] &&
                         (ram_rtag[i][CFG.TAG_WIDTH-1:0] == req_tag);
            way_err[i] = ram_rtag[i][CFG.TAG_WIDTH] && way_hit[i];
        end
        sram_rsp.addr  = s1_addr_q;
        sram_rsp.id    = s1_id_q;
        sram_rsp.hit   = (|way_hit) & ~ram_write_q & ~flush_valid_i;
        sram_rsp.error = (|way_err) & ~flush_valid_i;
        sram_rsp.data  = '0;
        for (int w = 0; w < CFG.SET_COUNT; w++) begin
            if (way_hit[w]) sram_rsp.data |= ram_rdata[w];
        end
    end

    lzc #(.WIDTH(CFG.SET_COUNT)) i_lzc_way (
        .in_i    ( way_hit       ),
        .cnt_o   ( sram_rsp.cset ),
        .empty_o (               )
    );

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            skid_vld_q    <= 2'b00;
            skid_q[0]     <= '0;
            skid_q[1]     <= '0;
        end else begin
            automatic skid_entry_t tmp_q [2];
            automatic logic [1:0]  tmp_v;
            automatic int          cnt;
            tmp_q[0] = '0;
            tmp_q[1] = '0;
            tmp_v    = 2'b00;
            cnt      = 0;

            for (int k = 0; k < 2; k++) begin
                if (skid_vld_q[k]) begin
                    automatic logic drop_head = (k == 0) && out_ready_i;
                    automatic logic drop_port = flush_ports_i[skid_q[k].id >> 1];
                    if (!drop_head && !drop_port) begin
                        tmp_q[cnt] = skid_q[k];
                        if (flush_valid_i) begin
                            tmp_q[cnt].hit   = 1'b0;
                            tmp_q[cnt].error = 1'b0;
                        end
                        tmp_v[cnt] = 1'b1;
                        cnt++;
                    end
                end
            end

            if (s1_vld_q && !flush_ports_i[s1_id_q >> 1]) begin
                tmp_q[cnt] = sram_rsp;
                tmp_v[cnt] = 1'b1;
            end

            skid_q[0]  <= tmp_q[0];
            skid_q[1]  <= tmp_q[1];
            skid_vld_q <= tmp_v;
        end
    end

    wire head_flushed = flush_ports_i[skid_q[0].id >> 1];
    assign out_addr_o  = skid_q[0].addr;
    assign out_id_o    = skid_q[0].id;
    assign out_set_o   = skid_q[0].cset;
    assign out_hit_o   = skid_q[0].hit & ~flush_valid_i;
    assign out_data_o  = skid_q[0].data;
    assign out_error_o = skid_q[0].error & ~flush_valid_i;
    assign out_valid_o = skid_vld_q[0] & ~head_flushed;

endmodule
