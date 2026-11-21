// Copyright © 2019-2023
// Licensed under the Apache License, Version 2.0.

`include "VX_define.vh"

module VX_lmem_subsys import VX_gpu_pkg::*; (
    input  wire                                                 clk,
    input  wire                                                 reset,

    // 2-lane 64-bit SIMD LSU Slave Port
    input  wire                                                 lsu_req_valid,
    output wire                                                 lsu_req_ready,
    input  wire [`VX_CFG_NUM_LSU_LANES-1:0]                     lsu_req_mask,
    input  wire                                                 lsu_req_rw,
    input  wire [`VX_CFG_NUM_LSU_LANES-1:0][15:0]               lsu_req_addr,
    input  wire [`VX_CFG_NUM_LSU_LANES-1:0][63:0]               lsu_req_data,
    input  wire [`VX_CFG_NUM_LSU_LANES-1:0][7:0]                lsu_req_byteen,
    input  wire [`VX_CFG_NUM_LSU_LANES-1:0][MEM_ATTR_WIDTH-1:0] lsu_req_user,
    input  wire [LSU_TAG_WIDTH-1:0]                             lsu_req_tag,

    output wire                                                 lsu_rsp_valid,
    input  wire                                                 lsu_rsp_ready,
    output wire [`VX_CFG_NUM_LSU_LANES-1:0]                     lsu_rsp_mask,
    output wire [`VX_CFG_NUM_LSU_LANES-1:0][63:0]               lsu_rsp_data,
    output wire [LSU_TAG_WIDTH-1:0]                             lsu_rsp_tag,

    // 2-lane 64-bit Global Memory Master Port (from VX_lmem_switch)
    output wire                                                 global_req_valid,
    input  wire                                                 global_req_ready,
    output wire [`VX_CFG_NUM_LSU_LANES-1:0]                     global_req_mask,
    output wire                                                 global_req_rw,
    output wire [`VX_CFG_NUM_LSU_LANES-1:0][15:0]               global_req_addr,
    output wire [`VX_CFG_NUM_LSU_LANES-1:0][63:0]               global_req_data,
    output wire [`VX_CFG_NUM_LSU_LANES-1:0][7:0]                global_req_byteen,
    output wire [`VX_CFG_NUM_LSU_LANES-1:0][MEM_ATTR_WIDTH-1:0] global_req_user,
    output wire [LSU_TAG_WIDTH-1:0]                             global_req_tag,

    input  wire                                                 global_rsp_valid,
    output wire                                                 global_rsp_ready,
    input  wire [`VX_CFG_NUM_LSU_LANES-1:0]                     global_rsp_mask,
    input  wire [`VX_CFG_NUM_LSU_LANES-1:0][63:0]               global_rsp_data,
    input  wire [LSU_TAG_WIDTH-1:0]                             global_rsp_tag,

    // Wide-Line (8 x 64-bit) DMA Staging & Burst Port
    input  wire                                                 dma_stage_we,
    input  wire [2:0]                                           dma_stage_bank,
    input  wire [63:0]                                          dma_stage_wdata,
    input  wire [7:0]                                           dma_stage_byteen,

    input  wire                                                 dma_req_valid,
    output wire                                                 dma_req_ready,
    input  wire                                                 dma_req_rw,
    input  wire [7:0]                                           dma_req_addr,
    input  wire [3:0]                                           dma_req_tag,

    output wire                                                 dma_rsp_valid,
    input  wire                                                 dma_rsp_ready,
    output wire [3:0]                                           dma_rsp_tag,
    input  wire [2:0]                                           dma_rsp_bank_sel,
    output wire [63:0]                                          dma_rsp_rdata
);
    localparam LMEM_ADDR_WIDTH   = `VX_CFG_LMEM_LOG_SIZE - `CLOG2(LSU_WORD_SIZE); // 11
    localparam DMA_DATA_SIZE     = `VX_CFG_LMEM_NUM_BANKS * LSU_WORD_SIZE;        // 64 bytes (512 bits)
    localparam DMA_BUS_TAG_WIDTH = UUID_WIDTH + 4;

    VX_lsu_mem_if #(
        .NUM_LANES (`VX_CFG_NUM_LSU_LANES),
        .DATA_SIZE (LSU_WORD_SIZE),
        .TAG_WIDTH (LSU_TAG_WIDTH)
    ) lsu_in_if();

    VX_lsu_mem_if #(
        .NUM_LANES (`VX_CFG_NUM_LSU_LANES),
        .DATA_SIZE (LSU_WORD_SIZE),
        .TAG_WIDTH (LSU_TAG_WIDTH)
    ) global_out_if();

    VX_lsu_mem_if #(
        .NUM_LANES (`VX_CFG_NUM_LSU_LANES),
        .DATA_SIZE (LSU_WORD_SIZE),
        .TAG_WIDTH (LSU_TAG_WIDTH)
    ) local_out_if();

    for (genvar gl = 0; gl < `VX_CFG_NUM_LSU_LANES; ++gl) begin : g_addr_ext
        assign lsu_in_if.req_data.addr[gl] = LSU_ADDR_WIDTH'(lsu_req_addr[gl]);
        assign global_req_addr[gl]         = global_out_if.req_data.addr[gl][15:0];
    end
    assign lsu_in_if.req_valid       = lsu_req_valid;
    assign lsu_req_ready             = lsu_in_if.req_ready;
    assign lsu_in_if.req_data.mask   = lsu_req_mask;
    assign lsu_in_if.req_data.rw     = lsu_req_rw;
    assign lsu_in_if.req_data.data   = lsu_req_data;
    assign lsu_in_if.req_data.byteen = lsu_req_byteen;
    assign lsu_in_if.req_data.user   = lsu_req_user;
    assign lsu_in_if.req_data.tag    = lsu_req_tag;

    assign lsu_rsp_valid             = lsu_in_if.rsp_valid;
    assign lsu_in_if.rsp_ready       = lsu_rsp_ready;
    assign lsu_rsp_mask              = lsu_in_if.rsp_data.mask;
    assign lsu_rsp_data              = lsu_in_if.rsp_data.data;
    assign lsu_rsp_tag               = lsu_in_if.rsp_data.tag;

    assign global_req_valid             = global_out_if.req_valid;
    assign global_out_if.req_ready      = global_req_ready;
    assign global_req_mask              = global_out_if.req_data.mask;
    assign global_req_rw                = global_out_if.req_data.rw;
    assign global_req_data              = global_out_if.req_data.data;
    assign global_req_byteen            = global_out_if.req_data.byteen;
    assign global_req_user              = global_out_if.req_data.user;
    assign global_req_tag               = global_out_if.req_data.tag;

    assign global_out_if.rsp_valid      = global_rsp_valid;
    assign global_rsp_ready             = global_out_if.rsp_ready;
    assign global_out_if.rsp_data.mask  = global_rsp_mask;
    assign global_out_if.rsp_data.data  = global_rsp_data;
    assign global_out_if.rsp_data.tag   = global_rsp_tag;

    VX_lmem_switch #(
        .GLOBAL_OUT_BUF (1),
        .LOCAL_OUT_BUF  (1),
        .RSP_OUT_BUF    (1),
        .ARBITER        ("P")
    ) u_lmem_switch (
        .clk           (clk),
        .reset         (reset),
        .lsu_in_if     (lsu_in_if),
        .global_out_if (global_out_if),
        .local_out_if  (local_out_if)
    );

    VX_mem_bus_if #(
        .DATA_SIZE (LSU_WORD_SIZE),
        .TAG_WIDTH (LSU_TAG_WIDTH)
    ) lmem_adapt_if[`VX_CFG_NUM_LSU_LANES]();

    VX_lsu_adapter #(
        .NUM_LANES    (`VX_CFG_NUM_LSU_LANES),
        .DATA_SIZE    (LSU_WORD_SIZE),
        .TAG_WIDTH    (LSU_TAG_WIDTH),
        .TAG_SEL_BITS (LSU_TAG_WIDTH - UUID_WIDTH),
        .ARBITER      ("P"),
        .REQ_OUT_BUF  (3),
        .RSP_OUT_BUF  (0)
    ) u_lmem_adapter (
        .clk        (clk),
        .reset      (reset),
        .lsu_mem_if (local_out_if),
        .mem_bus_if (lmem_adapt_if)
    );

    // 8-bank wide-line (512-bit) DMA staging buffer -> lmem_dma_if
    reg [7:0][63:0] dma_wr_buf_r;
    reg [7:0][7:0]  dma_wr_be_r;
    always @(posedge clk) begin
        if (reset) begin
            dma_wr_be_r <= '0;
        end else if (dma_stage_we) begin
            dma_wr_be_r[dma_stage_bank] <= dma_stage_byteen;
        end
        if (dma_stage_we) begin
            dma_wr_buf_r[dma_stage_bank] <= dma_stage_wdata;
        end
    end

    VX_mem_bus_if #(
        .DATA_SIZE  (DMA_DATA_SIZE),
        .TAG_WIDTH  (DMA_BUS_TAG_WIDTH),
        .ATTR_WIDTH (1),
        .ADDR_WIDTH (8)
    ) lmem_dma_if();

    assign lmem_dma_if.req_valid       = dma_req_valid;
    assign dma_req_ready               = lmem_dma_if.req_ready;
    assign lmem_dma_if.req_data.rw     = dma_req_rw;
    assign lmem_dma_if.req_data.addr   = dma_req_addr;
    assign lmem_dma_if.req_data.data   = dma_wr_buf_r;
    assign lmem_dma_if.req_data.byteen = dma_wr_be_r;
    assign lmem_dma_if.req_data.attr   = 1'b0;
    assign lmem_dma_if.req_data.tag    = {UUID_WIDTH'(0), dma_req_tag};

    assign dma_rsp_valid         = lmem_dma_if.rsp_valid;
    assign lmem_dma_if.rsp_ready = dma_rsp_ready;
    assign dma_rsp_tag           = lmem_dma_if.rsp_data.tag.value;
    assign dma_rsp_rdata         = lmem_dma_if.rsp_data.data[dma_rsp_bank_sel * 64 +: 64];

    VX_local_mem #(
        .INSTANCE_ID   ("lmem"),
        .SIZE          (1 << `VX_CFG_LMEM_LOG_SIZE),
        .NUM_REQS      (`VX_CFG_NUM_LSU_LANES),
        .NUM_BANKS     (`VX_CFG_LMEM_NUM_BANKS),
        .WORD_SIZE     (LSU_WORD_SIZE),
        .ADDR_WIDTH    (LMEM_ADDR_WIDTH),
        .TAG_WIDTH     (LSU_TAG_WIDTH),
        .DMA_ENABLE    (1),
        .DMA_TAG_WIDTH (DMA_BUS_TAG_WIDTH),
        .AMO_ENABLE    (1),
        .OUT_BUF       (3)
    ) u_local_mem (
        .clk        (clk),
        .reset      (reset),
        .lsu_bus_if (lmem_adapt_if),
        .dma_bus_if (lmem_dma_if)
    );

endmodule
