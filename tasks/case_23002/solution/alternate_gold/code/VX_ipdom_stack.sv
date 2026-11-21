// Copyright © 2019-2023
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

`include "VX_define.vh"

module VX_ipdom_stack import VX_gpu_pkg::*; #(
    parameter WIDTH = 1,
    parameter DEPTH = 1,
    parameter ADDRW = `LOG2UP(DEPTH)
) (
    input  wire                                     clk,
    input  wire                                     reset,
    input  wire [NW_WIDTH-1:0]                      wid,
    input  wire [WIDTH-1:0]                         d_val,
    input  wire [ADDRW-1:0]                         rd_ptr,
    input  wire                                     push,
    input  wire                                     pop,
    output wire [WIDTH-1:0]                         q_val,
    output wire                                     q_idx,
    output wire [`VX_CFG_NUM_WARPS-1:0][ADDRW-1:0]  wr_ptr,
    output wire                                     empty,
    output wire                                     full
);
    reg [WIDTH-1:0] slot_payload [`VX_CFG_NUM_WARPS-1:0][DEPTH-1:0];
    reg             slot_phase   [`VX_CFG_NUM_WARPS-1:0][DEPTH-1:0];
    reg [ADDRW-1:0] sp_reg       [`VX_CFG_NUM_WARPS-1:0];
    reg             is_empty_r   [`VX_CFG_NUM_WARPS-1:0];
    reg             is_full_r    [`VX_CFG_NUM_WARPS-1:0];

    wire cur_phase             = slot_phase[wid][rd_ptr];
    wire [WIDTH-1:0] cur_entry = slot_payload[wid][rd_ptr];

    assign q_idx = cur_phase;
    assign q_val = cur_entry;

    for (genvar w = 0; w < `VX_CFG_NUM_WARPS; ++w) begin : g_warp_sp
        assign wr_ptr[w] = sp_reg[w];

        always @(posedge clk) begin
            if (reset) begin
                sp_reg[w]     <= '0;
                is_empty_r[w] <= 1'b1;
                is_full_r[w]  <= 1'b0;
            end else if (push && (wid == NW_WIDTH'(w))) begin
                slot_payload[w][sp_reg[w]] <= d_val;
                slot_phase[w][sp_reg[w]]   <= 1'b0;
                sp_reg[w]                  <= sp_reg[w] + ADDRW'(1);
                is_empty_r[w]              <= 1'b0;
                is_full_r[w]               <= (sp_reg[w] == ADDRW'(DEPTH - 1));
            end else if (pop && (wid == NW_WIDTH'(w))) begin
                if (!cur_phase) begin
                    slot_phase[w][rd_ptr] <= 1'b1;
                    sp_reg[w]             <= rd_ptr + ADDRW'(1);
                    is_empty_r[w]         <= 1'b0;
                    is_full_r[w]          <= (rd_ptr == ADDRW'(DEPTH - 1));
                end else begin
                    sp_reg[w]             <= rd_ptr;
                    is_empty_r[w]         <= (rd_ptr == '0);
                    is_full_r[w]          <= 1'b0;
                end
            end
        end
    end

    assign empty = is_empty_r[wid];
    assign full  = is_full_r[wid];

endmodule
