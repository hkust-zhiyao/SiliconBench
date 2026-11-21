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

module VX_split_join import VX_gpu_pkg::*; #(
    parameter `STRING INSTANCE_ID = "",
    parameter OUT_REG = 0
) (
    input  wire                           clk,
    input  wire                           reset,
    input  wire                           split_valid,
    input  wire                           sjoin_valid,
    input  wire [NW_WIDTH-1:0]            wid,
    input  split_t                        split,
    input  join_t                         sjoin,
    input  wire [NW_WIDTH-1:0]            stack_wid,
    output wire                           join_valid,
    output wire                           join_is_dvg,
    output wire                           join_is_else,
    output wire [NW_WIDTH-1:0]            join_wid,
    output wire [`VX_CFG_NUM_THREADS-1:0] join_tmask,
    output wire [PC_BITS-1:0]             join_pc,
    output wire [DV_STACK_SIZEW-1:0]      stack_ptr
);
    `UNUSED_SPARAM (INSTANCE_ID)

    if (NT_BITS != 0) begin : g_reconv
        wire [`VX_CFG_NUM_WARPS-1:0][DV_STACK_SIZEW-1:0] sp_vec;
        wire [`VX_CFG_NUM_THREADS-1:0] saved_mask;
        wire [PC_BITS-1:0]             saved_pc;
        wire                           phase_bit;

        wire do_push = split_valid && split.is_dvg;
        wire has_dvg = (sjoin.stack_ptr != sp_vec[wid]);
        wire do_pop  = sjoin_valid && has_dvg;

        VX_ipdom_stack #(
            .WIDTH (`VX_CFG_NUM_THREADS + PC_BITS),
            .DEPTH (DV_STACK_SIZE)
        ) u_stack (
            .clk    (clk),
            .reset  (reset),
            .wid    (wid),
            .d_val  ({split.then_tmask | split.else_tmask, split.next_pc}),
            .rd_ptr (sjoin.stack_ptr),
            .push   (do_push),
            .pop    (do_pop),
            .q_val  ({saved_mask, saved_pc}),
            .q_idx  (phase_bit),
            .wr_ptr (sp_vec),
            `UNUSED_PIN (empty),
            `UNUSED_PIN (full)
        );

        logic [`VX_CFG_NUM_THREADS-1:0] next_tmask;
        logic                           next_is_else;
        always @(*) begin
            if (phase_bit) begin
                next_tmask   = saved_mask;
                next_is_else = 1'b0;
            end else begin
                next_tmask   = saved_mask & ~sjoin.tmask;
                next_is_else = 1'b1;
            end
        end

        if (OUT_REG != 0) begin : g_out_q
            reg                           jv_q, jdvg_q, jelse_q;
            reg [NW_WIDTH-1:0]            jwid_q;
            reg [`VX_CFG_NUM_THREADS-1:0] jtmask_q;
            reg [PC_BITS-1:0]             jpc_q;
            always @(posedge clk) begin
                if (reset) begin
                    jv_q <= 1'b0;
                end else begin
                    jv_q <= sjoin_valid;
                end
                jwid_q   <= wid;
                jdvg_q   <= has_dvg;
                jelse_q  <= next_is_else;
                jtmask_q <= next_tmask;
                jpc_q    <= saved_pc;
            end
            assign join_valid   = jv_q;
            assign join_wid     = jwid_q;
            assign join_is_dvg  = jdvg_q;
            assign join_is_else = jelse_q;
            assign join_tmask   = jtmask_q;
            assign join_pc      = jpc_q;
        end else begin : g_out_comb
            `UNUSED_VAR ({clk, reset})
            assign join_valid   = sjoin_valid;
            assign join_wid     = wid;
            assign join_is_dvg  = has_dvg;
            assign join_is_else = next_is_else;
            assign join_tmask   = next_tmask;
            assign join_pc      = saved_pc;
        end

        assign stack_ptr = sp_vec[stack_wid];
    end else begin : g_scalar
        `UNUSED_VAR ({clk, reset, split, sjoin, stack_wid, split_valid})
        assign join_valid   = sjoin_valid;
        assign join_wid     = wid;
        assign join_is_dvg  = 1'b0;
        assign join_is_else = 1'b0;
        assign join_tmask   = 1'b1;
        assign join_pc      = '0;
        assign stack_ptr    = '0;
    end

endmodule
