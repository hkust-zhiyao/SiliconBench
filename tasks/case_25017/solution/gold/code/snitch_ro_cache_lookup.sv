// Copyright 2020 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

// Fabian Schuiki <fschuiki@iis.ee.ethz.ch>

/// An actual cache lookup with registered SRAM readout and targeted line invalidation.
module snitch_ro_cache_lookup #(
    parameter snitch_icache_pkg::config_t CFG = '0,
    parameter type sram_cfg_data_t  = logic,
    parameter type sram_cfg_tag_t   = logic
)(
    input  logic clk_i,
    input  logic rst_ni,

    input  logic flush_valid_i,
    output logic flush_ready_o,
    output logic init_busy_o,

    input  logic                        inval_valid_i,
    input  logic [CFG.COUNT_ALIGN-1:0]  inval_addr_i,
    output logic                        inval_ready_o,

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
    logic [CFG.COUNT_ALIGN:0]   init_count_q;
    logic                       init_busy;

    typedef struct packed {
        logic [CFG.FETCH_AW-1:0]     addr;
        logic [CFG.ID_WIDTH_REQ-1:0] id;
        logic [CFG.SET_ALIGN-1:0]    cset;
        logic                        hit;
        logic [CFG.LINE_WIDTH-1:0]   data;
        logic                        error;
    } out_buffer_t;

    out_buffer_t data_d, data_q;
    logic        buffer_ready;
    logic        buffer_valid;
    logic        valid_q;
    logic [CFG.FETCH_AW-1:0]     addr_q;
    logic [CFG.ID_WIDTH_REQ-1:0] id_q;

    assign init_busy     = (init_count_q != $unsigned(CFG.LINE_COUNT));
    assign init_busy_o   = init_busy;
    assign flush_ready_o = !init_busy && !valid_q && !buffer_valid;

    always_comb begin : p_portmux
        write_ready_o = 1'b0;
        inval_ready_o = 1'b0;
        in_ready_o    = 1'b0;

        ram_addr   = in_addr_i >> CFG.LINE_ALIGN;
        ram_wdata  = write_data_i;
        ram_wtag   = {1'b1, 1'b0, write_tag_i};
        ram_enable = '0;
        ram_write  = 1'b0;

        if (init_busy) begin
            ram_addr   = init_count_q[CFG.COUNT_ALIGN-1:0];
            ram_enable = '1;
            ram_write  = 1'b1;
            ram_wdata  = '0;
            ram_wtag   = '0;
        end else if (inval_valid_i) begin
            ram_addr      = inval_addr_i;
            ram_enable    = '1;
            ram_write     = 1'b1;
            ram_wdata     = '0;
            ram_wtag      = '0;
            inval_ready_o = 1'b1;
        end else if (write_valid_i) begin
            write_ready_o = 1'b1;
            if (!write_error_i) begin
                ram_addr   = write_addr_i;
                ram_enable = CFG.SET_COUNT > 1 ? $unsigned(1 << write_set_i) : 1'b1;
                ram_write  = 1'b1;
            end
        end else if (!flush_valid_i && buffer_ready && (!valid_q || out_ready_i)) begin
            ram_enable = in_valid_i ? '1 : '0;
            in_ready_o = 1'b1;
        end
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            init_count_q <= '0;
        end else if (init_busy) begin
            init_count_q <= init_count_q + 1'b1;
        end else if (flush_valid_i && flush_ready_o) begin
            init_count_q <= '0;
        end
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            ram_write_q <= 1'b0;
            valid_q     <= 1'b0;
            addr_q      <= '0;
            id_q        <= '0;
        end else begin
            ram_write_q <= ram_write;
            valid_q     <= in_valid_i && in_ready_o;
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
        data_d.addr  = addr_q;
        data_d.id    = id_q;
        data_d.hit   = (|line_hit) & ~ram_write_q;
        data_d.error = |errors;
    end

    always_comb begin
        for (int i = 0; i < CFG.LINE_WIDTH; i++) begin
            automatic logic [CFG.SET_COUNT-1:0] masked;
            for (int j = 0; j < CFG.SET_COUNT; j++)
                masked[j] = ram_rdata[j][i] & line_hit[j];
            data_d.data[i] = |masked;
        end
    end

    lzc #(.WIDTH(CFG.SET_COUNT)) i_lzc (
        .in_i    ( line_hit    ),
        .cnt_o   ( data_d.cset ),
        .empty_o (             )
    );

    spill_register #(
        .T      ( out_buffer_t ),
        .Bypass ( 1'b0         )
    ) i_rsp_buffer (
        .clk_i   ( clk_i        ),
        .rst_ni  ( rst_ni       ),
        .valid_i ( valid_q      ),
        .ready_o ( buffer_ready ),
        .data_i  ( data_d       ),
        .valid_o ( buffer_valid ),
        .ready_i ( out_ready_i  ),
        .data_o  ( data_q       )
    );

    assign out_addr_o  = data_q.addr;
    assign out_id_o    = data_q.id;
    assign out_set_o   = data_q.cset;
    assign out_hit_o   = data_q.hit;
    assign out_data_o  = data_q.data;
    assign out_error_o = data_q.error;
    assign out_valid_o = buffer_valid;

endmodule
