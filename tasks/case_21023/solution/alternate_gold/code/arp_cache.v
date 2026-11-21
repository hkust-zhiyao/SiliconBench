/*
 * Alternate Gold: Circular-queue ARP cache with explicit clear FSM and write-through bypass
 */
`resetall
`timescale 1ns / 1ps
`default_nettype none

module arp_cache #(
    parameter CACHE_ADDR_WIDTH = 9
)
(
    input  wire        clk,
    input  wire        rst,

    input  wire        query_request_valid,
    output wire        query_request_ready,
    input  wire [31:0] query_request_ip,

    output wire        query_response_valid,
    input  wire        query_response_ready,
    output wire        query_response_error,
    output wire [47:0] query_response_mac,

    input  wire        write_request_valid,
    output wire        write_request_ready,
    input  wire [31:0] write_request_ip,
    input  wire [47:0] write_request_mac,

    input  wire        clear_cache
);

wire [31:0] q_hash_full;
wire [31:0] w_hash_full;

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
    .state_out(q_hash_full)
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
    .state_out(w_hash_full)
);

reg valid_tbl [(2**CACHE_ADDR_WIDTH)-1:0];
reg [31:0] ip_tbl [(2**CACHE_ADDR_WIDTH)-1:0];
reg [47:0] mac_tbl [(2**CACHE_ADDR_WIDTH)-1:0];

reg clr_active_r;
reg [CACHE_ADDR_WIDTH-1:0] clr_idx_r;

reg pend_wr_v_r;
reg [CACHE_ADDR_WIDTH-1:0] pend_wr_idx_r;
reg [31:0] pend_wr_ip_r;
reg [47:0] pend_wr_mac_r;

reg [31:0] q_fifo_ip [0:1];
reg [CACHE_ADDR_WIDTH-1:0] q_fifo_idx [0:1];
reg [1:0] q_wptr_r, q_rptr_r;

reg q_ready_r, w_ready_r;
reg resp_v_r, resp_err_r;
reg [47:0] resp_mac_r;

wire [1:0] q_used = q_wptr_r - q_rptr_r;
wire q_empty = (q_wptr_r == q_rptr_r);
wire resp_free = !resp_v_r || query_response_ready;

assign query_request_ready  = q_ready_r && !clear_cache;
assign write_request_ready  = w_ready_r && !clear_cache;
assign query_response_valid = resp_v_r;
assign query_response_error = resp_err_r;
assign query_response_mac   = resp_mac_r;

wire [31:0] head_ip = q_fifo_ip[q_rptr_r[0]];
wire [CACHE_ADDR_WIDTH-1:0] head_idx = q_fifo_idx[q_rptr_r[0]];

wire pop_q  = !q_empty && resp_free;
wire push_q = query_request_valid && query_request_ready;
wire [1:0] next_q_used = q_used + (push_q ? 2'd1 : 2'd0) - (pop_q ? 2'd1 : 2'd0);

wire next_clr_active = clear_cache ? 1'b1 :
                       clr_active_r ? ((clr_idx_r + 1'b1) != {CACHE_ADDR_WIDTH{1'b0}}) : 1'b0;

always @(posedge clk) begin
    if (rst) begin
        clr_active_r <= 1'b1;
        clr_idx_r <= {CACHE_ADDR_WIDTH{1'b0}};
        pend_wr_v_r <= 1'b0;
        pend_wr_idx_r <= {CACHE_ADDR_WIDTH{1'b0}};
        pend_wr_ip_r <= 32'd0;
        pend_wr_mac_r <= 48'd0;
        q_wptr_r <= 2'd0;
        q_rptr_r <= 2'd0;
        q_fifo_ip[0] <= 32'd0;
        q_fifo_ip[1] <= 32'd0;
        q_fifo_idx[0] <= {CACHE_ADDR_WIDTH{1'b0}};
        q_fifo_idx[1] <= {CACHE_ADDR_WIDTH{1'b0}};
        q_ready_r <= 1'b0;
        w_ready_r <= 1'b0;
        resp_v_r <= 1'b0;
        resp_err_r <= 1'b0;
        resp_mac_r <= 48'd0;
    end else begin
        if (query_response_ready) begin
            resp_v_r <= 1'b0;
        end

        if (pop_q) begin
            q_rptr_r <= q_rptr_r + 2'd1;
            resp_v_r <= 1'b1;
            if (clear_cache || clr_active_r) begin
                resp_err_r <= 1'b1;
                resp_mac_r <= 48'd0;
            end else if (pend_wr_v_r && (pend_wr_idx_r == head_idx)) begin
                if (pend_wr_ip_r == head_ip) begin
                    resp_err_r <= 1'b0;
                    resp_mac_r <= pend_wr_mac_r;
                end else begin
                    resp_err_r <= 1'b1;
                    resp_mac_r <= 48'd0;
                end
            end else if (valid_tbl[head_idx] && (ip_tbl[head_idx] == head_ip)) begin
                resp_err_r <= 1'b0;
                resp_mac_r <= mac_tbl[head_idx];
            end else begin
                resp_err_r <= 1'b1;
                resp_mac_r <= 48'd0;
            end
        end

        if (push_q) begin
            q_fifo_ip[q_wptr_r[0]]  <= query_request_ip;
            q_fifo_idx[q_wptr_r[0]] <= q_hash_full[CACHE_ADDR_WIDTH-1:0];
            q_wptr_r <= q_wptr_r + 2'd1;
        end

        if (clear_cache) begin
            clr_active_r <= 1'b1;
            clr_idx_r <= {CACHE_ADDR_WIDTH{1'b0}};
            pend_wr_v_r <= 1'b0;
        end else if (clr_active_r) begin
            valid_tbl[clr_idx_r] <= 1'b0;
            clr_idx_r <= clr_idx_r + 1'b1;
            clr_active_r <= ((clr_idx_r + 1'b1) != {CACHE_ADDR_WIDTH{1'b0}});
            pend_wr_v_r <= 1'b0;
        end else begin
            if (pend_wr_v_r) begin
                valid_tbl[pend_wr_idx_r] <= 1'b1;
                ip_tbl[pend_wr_idx_r]    <= pend_wr_ip_r;
                mac_tbl[pend_wr_idx_r]   <= pend_wr_mac_r;
                pend_wr_v_r <= 1'b0;
            end
            if (write_request_valid && write_request_ready) begin
                pend_wr_v_r   <= 1'b1;
                pend_wr_idx_r <= w_hash_full[CACHE_ADDR_WIDTH-1:0];
                pend_wr_ip_r  <= write_request_ip;
                pend_wr_mac_r <= write_request_mac;
            end
        end

        q_ready_r <= (next_q_used < 2'd2) && !next_clr_active;
        w_ready_r <= !next_clr_active;
    end
end

endmodule

`resetall
