// Copyright 2020 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

/// Cache tag/data SRAM lookup with timing-isolated, per-port flush-safe output register.
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
    logic [CFG.COUNT_ALIGN:0]   init_count_q;

    typedef struct packed {
        logic [CFG.FETCH_AW-1:0]     addr;
        logic [CFG.ID_WIDTH_REQ-1:0] id;
        logic [CFG.SET_ALIGN-1:0]    cset;
        logic                        hit;
        logic [CFG.LINE_WIDTH-1:0]   data;
        logic                        error;
    } lookup_pipe_t;

    lookup_pipe_t pipe_d, pipe_q;
    logic         pipe_valid_q;
    logic         valid_q;
    logic [CFG.FETCH_AW-1:0]     addr_q;
    logic [CFG.ID_WIDTH_REQ-1:0] id_q;

    // Issue SRAM read only when neither SRAM output stage nor output register is occupied,
    // completely decoupling forward/backward timing paths and guaranteeing zero overwrite on stall.
    wire can_issue_read = !flush_valid_i && !valid_q && !pipe_valid_q;

    always_comb begin : p_portmux
        write_ready_o = 1'b0;
        in_ready_o    = 1'b0;

        ram_addr      = CFG.COUNT_ALIGN'(in_addr_i >> CFG.LINE_ALIGN);
        ram_wdata     = write_data_i;
        ram_wtag      = {1'b1, write_error_i, write_tag_i};
        ram_enable    = '0;
        ram_write     = 1'b0;

        if (init_count_q != $unsigned(CFG.LINE_COUNT)) begin
            ram_addr   = init_count_q[CFG.COUNT_ALIGN-1:0];
            ram_enable = '1;
            ram_write  = 1'b1;
            ram_wdata  = '0;
            ram_wtag   = '0;
        end else if (flush_valid_i) begin
            ram_enable = '0;
        end else if (write_valid_i) begin
            ram_addr      = write_addr_i;
            ram_enable    = CFG.SET_COUNT > 1 ? CFG.SET_COUNT'(1 << write_set_i) : 1'b1;
            ram_write     = 1'b1;
            write_ready_o = 1'b1;
        end else if (can_issue_read) begin
            ram_enable = in_valid_i ? '1 : '0;
            in_ready_o = 1'b1;
        end
    end

    assign flush_ready_o = 1'b1;

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            init_count_q <= '0;
        end else if (flush_valid_i) begin
            init_count_q <= '0;
        end else if (init_count_q != $unsigned(CFG.LINE_COUNT)) begin
            init_count_q <= init_count_q + 1'b1;
        end
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            ram_write_q <= 1'b0;
        end else begin
            ram_write_q <= ram_write;
        end
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            valid_q <= 1'b0;
            addr_q  <= '0;
            id_q    <= '0;
        end else if (in_valid_i && in_ready_o && !flush_ports_i[in_id_i >> 1]) begin
            valid_q <= 1'b1;
            addr_q  <= in_addr_i;
            id_q    <= in_id_i;
        end else begin
            valid_q <= 1'b0;
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

    logic [CFG.TAG_WIDTH-1:0] required_tag;
    logic [CFG.SET_COUNT-1:0] line_hit;

    always_comb begin
        automatic logic [CFG.SET_COUNT-1:0] errors;
        required_tag = CFG.TAG_WIDTH'(addr_q >> (CFG.LINE_ALIGN + CFG.COUNT_ALIGN));
        for (int i = 0; i < CFG.SET_COUNT; i++) begin
            line_hit[i] = ram_rtag[i][CFG.TAG_WIDTH+1] &&
                          (ram_rtag[i][CFG.TAG_WIDTH-1:0] == required_tag);
            errors[i]   = ram_rtag[i][CFG.TAG_WIDTH] && line_hit[i];
        end
        pipe_d.addr  = addr_q;
        pipe_d.id    = id_q;
        pipe_d.hit   = (|line_hit) & ~ram_write_q & ~flush_valid_i;
        pipe_d.error = (|errors) & ~flush_valid_i;
    end

    always_comb begin
        for (int i = 0; i < CFG.LINE_WIDTH; i++) begin
            automatic logic [CFG.SET_COUNT-1:0] masked;
            for (int j = 0; j < CFG.SET_COUNT; j++)
                masked[j] = ram_rdata[j][i] & line_hit[j];
            pipe_d.data[i] = |masked;
        end
    end

    lzc #(.WIDTH(CFG.SET_COUNT)) i_lzc (
        .in_i    ( line_hit    ),
        .cnt_o   ( pipe_d.cset ),
        .empty_o (             )
    );

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            pipe_valid_q <= 1'b0;
            pipe_q       <= '0;
        end else begin
            if (valid_q && !flush_ports_i[id_q >> 1]) begin
                pipe_valid_q <= 1'b1;
                pipe_q       <= pipe_d;
            end else if (pipe_valid_q) begin
                if (flush_ports_i[pipe_q.id >> 1] || out_ready_i) begin
                    pipe_valid_q <= 1'b0;
                end else if (flush_valid_i) begin
                    // Shared L1 was invalidated while another port's lookup was stalled;
                    // downgrade hit to miss so it re-fetches post-flush memory!
                    pipe_q.hit   <= 1'b0;
                    pipe_q.error <= 1'b0;
                end
            end
        end
    end

    wire pipe_port_flushed = flush_ports_i[pipe_q.id >> 1];
    assign out_addr_o  = pipe_q.addr;
    assign out_id_o    = pipe_q.id;
    assign out_set_o   = pipe_q.cset;
    assign out_hit_o   = pipe_q.hit & ~flush_valid_i;
    assign out_data_o  = pipe_q.data;
    assign out_error_o = pipe_q.error & ~flush_valid_i;
    assign out_valid_o = pipe_valid_q & ~pipe_port_flushed;

endmodule
