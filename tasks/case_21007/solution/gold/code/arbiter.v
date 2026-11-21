/*

Copyright (c) 2014-2021 Alex Forencich

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
 * Arbiter module with optional 4-bit QoS priority, per-level round-robin,
 * and starvation-bounded ageing promotion
 */
module arbiter #
(
    parameter PORTS = 4,
    // select round robin arbitration
    parameter ARB_TYPE_ROUND_ROBIN = 0,
    // blocking arbiter enable
    parameter ARB_BLOCK = 0,
    // block on acknowledge assert when nonzero, request deassert when 0
    parameter ARB_BLOCK_ACK = 1,
    // LSB priority selection
    parameter ARB_LSB_HIGH_PRIORITY = 0,
    // enable 4-bit QoS-aware arbitration
    parameter QOS_ENABLE = 0,
    // starvation-bounded ageing limit (0 disables ageing promotion)
    parameter AGEING_LIMIT = 0
)
(
    input  wire                     clk,
    input  wire                     rst,

    input  wire [PORTS-1:0]         request,
    input  wire [PORTS-1:0]         acknowledge,
    input  wire [PORTS*4-1:0]       qos,
    input  wire [PORTS-1:0]         pending,

    output wire [PORTS-1:0]         grant,
    output wire                     grant_valid,
    output wire [$clog2(PORTS)-1:0] grant_encoded
);

reg [PORTS-1:0] grant_reg = 0, grant_next;
reg grant_valid_reg = 0, grant_valid_next;
reg [$clog2(PORTS)-1:0] grant_encoded_reg = 0, grant_encoded_next;

assign grant_valid = grant_valid_reg;
assign grant = grant_reg;
assign grant_encoded = grant_encoded_reg;

reg [PORTS-1:0] mask_reg = 0, mask_next;
reg [16*PORTS-1:0] qos_mask_reg = 0, qos_mask_next;
reg [PORTS*32-1:0] age_reg = 0, age_next;

reg [PORTS*4-1:0] eff_qos;
reg [3:0] max_qos;
reg [PORTS-1:0] eff_request;
reg [PORTS-1:0] active_mask;

integer p;

always @* begin
    eff_qos = {PORTS*4{1'b0}};
    max_qos = 4'd0;
    for (p = 0; p < PORTS; p = p + 1) begin
        if (QOS_ENABLE && (AGEING_LIMIT > 0) && (age_reg[p*32 +: 32] >= AGEING_LIMIT)) begin
            eff_qos[p*4 +: 4] = 4'hF;
        end else if (QOS_ENABLE) begin
            eff_qos[p*4 +: 4] = qos[p*4 +: 4];
        end else begin
            eff_qos[p*4 +: 4] = 4'd0;
        end

        if (request[p] && (eff_qos[p*4 +: 4] > max_qos)) begin
            max_qos = eff_qos[p*4 +: 4];
        end
    end

    for (p = 0; p < PORTS; p = p + 1) begin
        if (QOS_ENABLE) begin
            eff_request[p] = request[p] && (eff_qos[p*4 +: 4] == max_qos);
        end else begin
            eff_request[p] = request[p];
        end
    end

    if (QOS_ENABLE) begin
        active_mask = qos_mask_reg[max_qos*PORTS +: PORTS];
    end else begin
        active_mask = mask_reg;
    end
end

wire request_valid;
wire [$clog2(PORTS)-1:0] request_index;
wire [PORTS-1:0] request_mask;

priority_encoder #(
    .WIDTH(PORTS),
    .LSB_HIGH_PRIORITY(ARB_LSB_HIGH_PRIORITY)
)
priority_encoder_inst (
    .input_unencoded(eff_request),
    .output_valid(request_valid),
    .output_encoded(request_index),
    .output_unencoded(request_mask)
);

wire masked_request_valid;
wire [$clog2(PORTS)-1:0] masked_request_index;
wire [PORTS-1:0] masked_request_mask;

priority_encoder #(
    .WIDTH(PORTS),
    .LSB_HIGH_PRIORITY(ARB_LSB_HIGH_PRIORITY)
)
priority_encoder_masked (
    .input_unencoded(eff_request & active_mask),
    .output_valid(masked_request_valid),
    .output_encoded(masked_request_index),
    .output_unencoded(masked_request_mask)
);

reg [PORTS-1:0] next_rr_mask;

always @* begin
    grant_next = 0;
    grant_valid_next = 0;
    grant_encoded_next = 0;
    mask_next = mask_reg;
    qos_mask_next = qos_mask_reg;
    age_next = age_reg;
    next_rr_mask = {PORTS{1'b0}};

    if (QOS_ENABLE) begin
        for (p = 0; p < PORTS; p = p + 1) begin
            if (!pending[p]) begin
                age_next[p*32 +: 32] = 32'd0;
            end
        end
    end

    if (ARB_BLOCK && !ARB_BLOCK_ACK && (grant_reg & request)) begin
        // granted request still asserted; hold it
        grant_valid_next = grant_valid_reg;
        grant_next = grant_reg;
        grant_encoded_next = grant_encoded_reg;
    end else if (ARB_BLOCK && ARB_BLOCK_ACK && grant_valid && !(grant_reg & acknowledge)) begin
        // granted request not yet acknowledged; hold it
        grant_valid_next = grant_valid_reg;
        grant_next = grant_reg;
        grant_encoded_next = grant_encoded_reg;
    end else if (request_valid) begin
        if (ARB_TYPE_ROUND_ROBIN) begin
            if (masked_request_valid) begin
                grant_valid_next = 1'b1;
                grant_next = masked_request_mask;
                grant_encoded_next = masked_request_index;
                if (ARB_LSB_HIGH_PRIORITY) begin
                    next_rr_mask = {PORTS{1'b1}} << (masked_request_index + 1);
                end else begin
                    next_rr_mask = {PORTS{1'b1}} >> (PORTS - masked_request_index);
                end
            end else begin
                grant_valid_next = 1'b1;
                grant_next = request_mask;
                grant_encoded_next = request_index;
                if (ARB_LSB_HIGH_PRIORITY) begin
                    next_rr_mask = {PORTS{1'b1}} << (request_index + 1);
                end else begin
                    next_rr_mask = {PORTS{1'b1}} >> (PORTS - request_index);
                end
            end
            if (QOS_ENABLE) begin
                qos_mask_next[max_qos*PORTS +: PORTS] = next_rr_mask;
            end else begin
                mask_next = next_rr_mask;
            end
        end else begin
            grant_valid_next = 1'b1;
            grant_next = request_mask;
            grant_encoded_next = request_index;
        end

        if (QOS_ENABLE) begin
            for (p = 0; p < PORTS; p = p + 1) begin
                if (!pending[p] || grant_next[p]) begin
                    age_next[p*32 +: 32] = 32'd0;
                end else if (request[p]) begin
                    if ((AGEING_LIMIT > 0) && (age_reg[p*32 +: 32] < AGEING_LIMIT)) begin
                        age_next[p*32 +: 32] = age_reg[p*32 +: 32] + 32'd1;
                    end
                end
            end
        end
    end
end

always @(posedge clk) begin
    if (rst) begin
        grant_reg <= 0;
        grant_valid_reg <= 0;
        grant_encoded_reg <= 0;
        mask_reg <= 0;
        qos_mask_reg <= 0;
        age_reg <= 0;
    end else begin
        grant_reg <= grant_next;
        grant_valid_reg <= grant_valid_next;
        grant_encoded_reg <= grant_encoded_next;
        mask_reg <= mask_next;
        qos_mask_reg <= qos_mask_next;
        age_reg <= age_next;
    end
end

endmodule

`resetall
