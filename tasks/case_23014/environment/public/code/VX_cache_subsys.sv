// Copyright © 2019-2023
// Licensed under the Apache License, Version 2.0.

`include "VX_cache_define.vh"

module VX_cache_subsys import VX_gpu_pkg::*; (
    input  wire                                 clk,
    input  wire                                 reset,

    // 2-port 64-bit Core Request / Response Slave Ports
    input  wire [1:0]                           core_req_valid,
    output wire [1:0]                           core_req_ready,
    input  wire [1:0]                           core_req_rw,
    input  wire [1:0][24:0]                     core_req_addr,
    input  wire [1:0][63:0]                     core_req_data,
    input  wire [1:0][7:0]                      core_req_byteen,
    input  wire [1:0][`UP(MEM_ATTR_WIDTH)-1:0]  core_req_attr,
    input  wire [1:0][5:0]                      core_req_tag,

    output wire [1:0]                           core_rsp_valid,
    input  wire [1:0]                           core_rsp_ready,
    output wire [1:0][63:0]                     core_rsp_data,
    output wire [1:0][5:0]                      core_rsp_tag,

    // 128-bit Sectored Memory Master Port
    output wire                                 mem_req_valid,
    input  wire                                 mem_req_ready,
    output wire                                 mem_req_rw,
    output wire [23:0]                          mem_req_addr,
    output wire [127:0]                         mem_req_data,
    output wire [15:0]                          mem_req_byteen,
    output wire [`UP(MEM_ATTR_WIDTH)-1:0]       mem_req_attr,
    output wire [2:0]                           mem_req_tag,

    input  wire                                 mem_rsp_valid,
    output wire                                 mem_rsp_ready,
    input  wire [127:0]                         mem_rsp_data,
    input  wire [2:0]                           mem_rsp_tag
);
    localparam NUM_REQS      = 2;
    localparam MEM_PORTS     = 1;
    localparam CACHE_SIZE    = 16384; // 16 KB total (8 KB / bank)
    localparam LINE_SIZE     = 32;    // 32B line (4 x 64-bit word slices)
    localparam NUM_BANKS     = 2;     // 2 interleaved cache banks
    localparam NUM_WAYS      = 4;     // 4-way set-associative (64 sets / bank)
    localparam WORD_SIZE     = 8;     // 64-bit word slice
    localparam SECTOR_SIZE   = 16;    // 16B (128-bit) sector (2 sectors / line)
    localparam MSHR_SIZE     = 4;
    localparam CORE_TAG_W    = UUID_WIDTH + 6;
    localparam MEM_BUS_TAG_W = `CACHE_MEM_TAG_WIDTH(MSHR_SIZE, NUM_BANKS, MEM_PORTS, UUID_WIDTH);

    VX_mem_bus_if #(
        .DATA_SIZE (WORD_SIZE),
        .TAG_WIDTH (CORE_TAG_W)
    ) core_bus_if[NUM_REQS]();

    VX_mem_bus_if #(
        .DATA_SIZE (SECTOR_SIZE),
        .TAG_WIDTH (MEM_BUS_TAG_W)
    ) mem_bus_if[MEM_PORTS]();

    for (genvar r = 0; r < NUM_REQS; ++r) begin : g_core_bind
        assign core_bus_if[r].req_valid       = core_req_valid[r];
        assign core_req_ready[r]              = core_bus_if[r].req_ready;
        assign core_bus_if[r].req_data.rw     = core_req_rw[r];
        assign core_bus_if[r].req_data.addr   = core_req_addr[r];
        assign core_bus_if[r].req_data.data   = core_req_data[r];
        assign core_bus_if[r].req_data.byteen = core_req_byteen[r];
        assign core_bus_if[r].req_data.attr   = core_req_attr[r];
        assign core_bus_if[r].req_data.tag    = {UUID_WIDTH'(0), core_req_tag[r]};

        assign core_rsp_valid[r]              = core_bus_if[r].rsp_valid;
        assign core_bus_if[r].rsp_ready       = core_rsp_ready[r];
        assign core_rsp_data[r]               = core_bus_if[r].rsp_data.data;
        assign core_rsp_tag[r]                = core_bus_if[r].rsp_data.tag.value;
    end

    assign mem_req_valid                  = mem_bus_if[0].req_valid;
    assign mem_bus_if[0].req_ready        = mem_req_ready;
    assign mem_req_rw                     = mem_bus_if[0].req_data.rw;
    assign mem_req_addr                   = mem_bus_if[0].req_data.addr;
    assign mem_req_data                   = mem_bus_if[0].req_data.data;
    assign mem_req_byteen                 = mem_bus_if[0].req_data.byteen;
    assign mem_req_attr                   = mem_bus_if[0].req_data.attr;
    assign mem_req_tag                    = mem_bus_if[0].req_data.tag.value;

    assign mem_bus_if[0].rsp_valid        = mem_rsp_valid;
    assign mem_rsp_ready                  = mem_bus_if[0].rsp_ready;
    assign mem_bus_if[0].rsp_data.data    = mem_rsp_data;
    assign mem_bus_if[0].rsp_data.tag     = {UUID_WIDTH'(0), mem_rsp_tag};

    VX_cache #(
        .INSTANCE_ID  ("l1d"),
        .NUM_REQS     (NUM_REQS),
        .MEM_PORTS    (MEM_PORTS),
        .CACHE_SIZE   (CACHE_SIZE),
        .LINE_SIZE    (LINE_SIZE),
        .NUM_BANKS    (NUM_BANKS),
        .NUM_WAYS     (NUM_WAYS),
        .WORD_SIZE    (WORD_SIZE),
        .SECTOR_SIZE  (SECTOR_SIZE),
        .CRSQ_SIZE    (2),
        .MSHR_SIZE    (MSHR_SIZE),
        .MRSQ_SIZE    (2),
        .MREQ_SIZE    (2),
        .LATENCY      (2),
        .WRITE_ENABLE (1),
        .WRITEBACK    (0),
        .DIRTY_BYTES  (0),
        .REPL_POLICY  (`CS_REPL_PLRU),
        .TAG_WIDTH    (CORE_TAG_W),
        .CORE_OUT_BUF (2),
        .MEM_OUT_BUF  (2),
        .IS_LLC       (0),
        .AMO_ENABLE   (1)
    ) u_cache (
        .clk         (clk),
        .reset       (reset),
        .core_bus_if (core_bus_if),
        .mem_bus_if  (mem_bus_if)
    );

endmodule
