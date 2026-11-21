/*

Copyright (c) 2014-2018 Alex Forencich

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.

*/

// Language: Verilog 2001

`resetall
`timescale 1ns / 1ps
`default_nettype none

/*
 * ARP cache
 */
module arp_cache #(
    parameter CACHE_ADDR_WIDTH = 9
)
(
    input  wire        clk,
    input  wire        rst,

    /*
     * Cache query
     */
    input  wire        query_request_valid,
    output wire        query_request_ready,
    input  wire [31:0] query_request_ip,

    output wire        query_response_valid,
    input  wire        query_response_ready,
    output wire        query_response_error,
    output wire [47:0] query_response_mac,

    /*
     * Cache write
     */
    input  wire        write_request_valid,
    output wire        write_request_ready,
    input  wire [31:0] write_request_ip,
    input  wire [47:0] write_request_mac,

    /*
     * Configuration
     */
    input  wire        clear_cache
);

reg mem_write = 1'b0;
reg store_query = 1'b0;
reg store_write = 1'b0;
reg latch_response = 1'b0;

reg query_ip_valid_reg = 1'b0, query_ip_valid_next;
reg [31:0] query_ip_reg = 32'd0;
reg write_ip_valid_reg = 1'b0, write_ip_valid_next;
reg [31:0] write_ip_reg = 32'd0;
reg [47:0] write_mac_reg = 48'd0;
reg clear_cache_reg = 1'b0, clear_cache_next;

reg [CACHE_ADDR_WIDTH-1:0] wr_ptr_reg = {CACHE_ADDR_WIDTH{1'b0}}, wr_ptr_next;
reg [CACHE_ADDR_WIDTH-1:0] rd_ptr_reg = {CACHE_ADDR_WIDTH{1'b0}}, rd_ptr_next;

reg valid_mem[(2**CACHE_ADDR_WIDTH)-1:0];
reg [31:0] ip_addr_mem[(2**CACHE_ADDR_WIDTH)-1:0];
reg [47:0] mac_addr_mem[(2**CACHE_ADDR_WIDTH)-1:0];

reg query_request_ready_reg = 1'b0, query_request_ready_next;

reg query_response_valid_reg = 1'b0, query_response_valid_next;
reg query_response_error_reg = 1'b0, query_response_error_next;
reg [47:0] query_response_mac_reg = 48'd0, query_response_mac_next;

reg write_request_ready_reg = 1'b0, write_request_ready_next;

wire [31:0] query_request_hash;
wire [31:0] write_request_hash;

assign query_request_ready = query_request_ready_reg && !clear_cache;

assign query_response_valid = query_response_valid_reg;
assign query_response_error = query_response_error_reg;
assign query_response_mac = query_response_mac_reg;

assign write_request_ready = write_request_ready_reg && !clear_cache;

lfsr #(
    .LFSR_WIDTH(32),
    .LFSR_POLY(32'h4c11db7),
    .LFSR_CONFIG("GALOIS"),
    .LFSR_FEED_FORWARD(0),
    .REVERSE(1),
    .DATA_WIDTH(32),
    .STYLE("AUTO")
)
rd_hash (
    .data_in(query_request_ip),
    .state_in(32'hffffffff),
    .data_out(),
    .state_out(query_request_hash)
);

lfsr #(
    .LFSR_WIDTH(32),
    .LFSR_POLY(32'h4c11db7),
    .LFSR_CONFIG("GALOIS"),
    .LFSR_FEED_FORWARD(0),
    .REVERSE(1),
    .DATA_WIDTH(32),
    .STYLE("AUTO")
)
wr_hash (
    .data_in(write_request_ip),
    .state_in(32'hffffffff),
    .data_out(),
    .state_out(write_request_hash)
);

reg skid_query_valid_reg = 1'b0, skid_query_valid_next;
reg [31:0] skid_query_ip_reg = 32'd0;
reg [CACHE_ADDR_WIDTH-1:0] skid_rd_ptr_reg = {CACHE_ADDR_WIDTH{1'b0}};
reg store_skid_query = 1'b0;
reg pop_skid_to_stage1 = 1'b0;

wire stage2_can_accept = !query_response_valid_reg || query_response_ready;
wire stage1_will_be_free = !query_ip_valid_reg || stage2_can_accept;

integer i;

initial begin
    for (i = 0; i < 2**CACHE_ADDR_WIDTH; i = i + 1) begin
        valid_mem[i] = 1'b0;
        ip_addr_mem[i] = 32'd0;
        mac_addr_mem[i] = 48'd0;
    end
end

always @* begin
    mem_write = 1'b0;
    store_query = 1'b0;
    store_write = 1'b0;
    store_skid_query = 1'b0;
    pop_skid_to_stage1 = 1'b0;
    latch_response = 1'b0;

    wr_ptr_next = wr_ptr_reg;
    rd_ptr_next = rd_ptr_reg;

    clear_cache_next = clear_cache_reg | clear_cache;

    query_ip_valid_next = query_ip_valid_reg;
    skid_query_valid_next = skid_query_valid_reg;

    query_response_valid_next = query_response_valid_reg && !query_response_ready;
    query_response_error_next = query_response_error_reg;
    query_response_mac_next = query_response_mac_reg;

    if (query_ip_valid_reg && stage2_can_accept) begin
        query_response_valid_next = 1'b1;
        query_ip_valid_next = 1'b0;
        latch_response = 1'b1;
        if (clear_cache || clear_cache_reg) begin
            query_response_error_next = 1'b1;
            query_response_mac_next = 48'd0;
        end else if (write_ip_valid_reg && (wr_ptr_reg == rd_ptr_reg)) begin
            if (write_ip_reg == query_ip_reg) begin
                query_response_error_next = 1'b0;
                query_response_mac_next = write_mac_reg;
            end else begin
                query_response_error_next = 1'b1;
                query_response_mac_next = 48'd0;
            end
        end else if (valid_mem[rd_ptr_reg] && (ip_addr_mem[rd_ptr_reg] == query_ip_reg)) begin
            query_response_error_next = 1'b0;
            query_response_mac_next = mac_addr_mem[rd_ptr_reg];
        end else begin
            query_response_error_next = 1'b1;
            query_response_mac_next = 48'd0;
        end
    end

    if (skid_query_valid_reg && stage1_will_be_free) begin
        pop_skid_to_stage1 = 1'b1;
        skid_query_valid_next = 1'b0;
        query_ip_valid_next = 1'b1;
        rd_ptr_next = skid_rd_ptr_reg;
    end else if (query_request_valid && query_request_ready) begin
        if (stage1_will_be_free) begin
            store_query = 1'b1;
            query_ip_valid_next = 1'b1;
            rd_ptr_next = query_request_hash[CACHE_ADDR_WIDTH-1:0];
        end else begin
            store_skid_query = 1'b1;
            skid_query_valid_next = 1'b1;
        end
    end

    write_ip_valid_next = write_ip_valid_reg;

    if (clear_cache) begin
        clear_cache_next = 1'b1;
        wr_ptr_next = {CACHE_ADDR_WIDTH{1'b0}};
        write_ip_valid_next = 1'b0;
    end else if (clear_cache_reg) begin
        wr_ptr_next = wr_ptr_reg + 1'b1;
        clear_cache_next = (wr_ptr_next != {CACHE_ADDR_WIDTH{1'b0}});
        mem_write = 1'b1;
        write_ip_valid_next = 1'b0;
    end else begin
        if (write_ip_valid_reg) begin
            write_ip_valid_next = 1'b0;
            mem_write = 1'b1;
        end

        if (write_request_valid && write_request_ready) begin
            store_write = 1'b1;
            write_ip_valid_next = 1'b1;
            wr_ptr_next = write_request_hash[CACHE_ADDR_WIDTH-1:0];
        end
    end

    query_request_ready_next = !skid_query_valid_next && !clear_cache_next;
    write_request_ready_next = !clear_cache_next;
end

always @(posedge clk) begin
    if (rst) begin
        query_ip_valid_reg <= 1'b0;
        skid_query_valid_reg <= 1'b0;
        query_request_ready_reg <= 1'b0;
        query_response_valid_reg <= 1'b0;
        query_response_error_reg <= 1'b0;
        query_response_mac_reg <= 48'd0;
        write_ip_valid_reg <= 1'b0;
        write_request_ready_reg <= 1'b0;
        clear_cache_reg <= 1'b1;
        wr_ptr_reg <= {CACHE_ADDR_WIDTH{1'b0}};
        rd_ptr_reg <= {CACHE_ADDR_WIDTH{1'b0}};
        query_ip_reg <= 32'd0;
        skid_query_ip_reg <= 32'd0;
        skid_rd_ptr_reg <= {CACHE_ADDR_WIDTH{1'b0}};
        write_ip_reg <= 32'd0;
        write_mac_reg <= 48'd0;
    end else begin
        query_ip_valid_reg <= query_ip_valid_next;
        skid_query_valid_reg <= skid_query_valid_next;
        query_request_ready_reg <= query_request_ready_next;
        query_response_valid_reg <= query_response_valid_next;
        write_ip_valid_reg <= write_ip_valid_next;
        write_request_ready_reg <= write_request_ready_next;
        clear_cache_reg <= clear_cache_next;
        wr_ptr_reg <= wr_ptr_next;
        rd_ptr_reg <= rd_ptr_next;

        if (latch_response) begin
            query_response_error_reg <= query_response_error_next;
            query_response_mac_reg <= query_response_mac_next;
        end

        if (pop_skid_to_stage1) begin
            query_ip_reg <= skid_query_ip_reg;
        end else if (store_query) begin
            query_ip_reg <= query_request_ip;
        end

        if (store_skid_query) begin
            skid_query_ip_reg <= query_request_ip;
            skid_rd_ptr_reg <= query_request_hash[CACHE_ADDR_WIDTH-1:0];
        end

        if (store_write) begin
            write_ip_reg <= write_request_ip;
            write_mac_reg <= write_request_mac;
        end

        if (mem_write) begin
            valid_mem[wr_ptr_reg] <= !clear_cache_reg;
            ip_addr_mem[wr_ptr_reg] <= write_ip_reg;
            mac_addr_mem[wr_ptr_reg] <= write_mac_reg;
        end
    end
end

endmodule

`resetall
