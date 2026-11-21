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

module VX_wctl_unit import VX_gpu_pkg::*; #(
    parameter `STRING INSTANCE_ID = "",
    parameter NUM_LANES = 1
) (
    input wire              clk,
    input wire              reset,

    // Inputs
    VX_execute_if.slave     execute_if,
    VX_txbar_bus_if.slave   txbar_bus_if,

    // Outputs
    VX_warp_ctl_if.master   warp_ctl_if,
    VX_result_if.master     result_if
);
    `UNUSED_SPARAM (INSTANCE_ID)
    localparam LANE_BITS  = `CLOG2(NUM_LANES);
    localparam PID_BITS   = `CLOG2(`VX_CFG_NUM_THREADS / NUM_LANES);
    localparam WCTL_WIDTH = $bits(tmc_t) + $bits(wspawn_t) + $bits(split_t) + $bits(join_t) + $bits(barrier_t);
    localparam CNT_W      = `CLOG2(`VX_CFG_NUM_THREADS + 1);

    `UNUSED_VAR (execute_if.data.rs3_data)

    function automatic [CNT_W-1:0] count_active_bits(input logic [`VX_CFG_NUM_THREADS-1:0] m);
        logic [CNT_W-1:0] acc;
        begin
            acc = '0;
            for (integer k = 0; k < `VX_CFG_NUM_THREADS; ++k) begin
                acc = acc + CNT_W'(m[k]);
            end
            count_active_bits = acc;
        end
    endfunction

    logic [`UP(LANE_BITS)-1:0] active_last_lane;
    always @(*) begin
        active_last_lane = '0;
        for (integer l = 0; l < NUM_LANES; ++l) begin
            if (execute_if.data.header.tmask[l]) begin
                active_last_lane = `UP(LANE_BITS)'(l);
            end
        end
    end

    wire [`VX_CFG_XLEN-1:0] scalar_rs1 = execute_if.data.rs1_data[active_last_lane];
    wire [`VX_CFG_XLEN-1:0] scalar_rs2 = execute_if.data.rs2_data[active_last_lane];

    wire [NUM_LANES-1:0] lane_cond;
    for (genvar i = 0; i < NUM_LANES; ++i) begin : g_cond
        assign lane_cond[i] = execute_if.data.rs1_data[i][0] ^ execute_if.data.op_args.wctl.is_cond_neg;
    end

    wire [NUM_LANES-1:0] pkt_then = lane_cond & execute_if.data.header.tmask;
    wire [NUM_LANES-1:0] pkt_else = ~lane_cond & execute_if.data.header.tmask;

    wire wsync_stall = execute_if.valid
                    && (execute_if.data.op_type == INST_SFU_WSYNC)
                    && !warp_ctl_if.warp_pending_alm_empty[execute_if.data.header.wid];
    wire bar_stall   = execute_if.valid
                    && (execute_if.data.op_type == INST_SFU_BAR)
                    && !warp_ctl_if.lsu_sched_drained;

    wire rsp_ready_in;
    assign execute_if.ready = rsp_ready_in && !wsync_stall && !bar_stall;
    wire pkt_accept         = execute_if.valid && execute_if.ready;
    wire eop_commit         = pkt_accept && execute_if.data.header.eop;

    logic [`VX_CFG_NUM_THREADS-1:0] full_then_mask;
    logic [`VX_CFG_NUM_THREADS-1:0] full_else_mask;

    if (PID_BITS != 0) begin : g_multi_pkt
        reg [`VX_CFG_NUM_THREADS-1:0] saved_then [`VX_CFG_NUM_WARPS-1:0];
        reg [`VX_CFG_NUM_THREADS-1:0] saved_else [`VX_CFG_NUM_WARPS-1:0];

        always @(*) begin
            full_then_mask = execute_if.data.header.sop ? '0 : saved_then[execute_if.data.header.wid];
            full_else_mask = execute_if.data.header.sop ? '0 : saved_else[execute_if.data.header.wid];
            full_then_mask[execute_if.data.header.pid * NUM_LANES +: NUM_LANES] = pkt_then;
            full_else_mask[execute_if.data.header.pid * NUM_LANES +: NUM_LANES] = pkt_else;
        end

        always @(posedge clk) begin
            if (reset) begin
                for (integer w = 0; w < `VX_CFG_NUM_WARPS; ++w) begin
                    saved_then[w] <= '0;
                    saved_else[w] <= '0;
                end
            end else if (pkt_accept) begin
                saved_then[execute_if.data.header.wid] <= full_then_mask;
                saved_else[execute_if.data.header.wid] <= full_else_mask;
            end
        end
    end else begin : g_single_pkt
        assign full_then_mask = pkt_then;
        assign full_else_mask = pkt_else;
    end

    wire any_then = (|full_then_mask);
    wire any_else = (|full_else_mask);

    wire op_is_tmc    = (execute_if.data.op_type == INST_SFU_TMC);
    wire op_is_wspawn = (execute_if.data.op_type == INST_SFU_WSPAWN);
    wire op_is_split  = (execute_if.data.op_type == INST_SFU_SPLIT);
    wire op_is_join   = (execute_if.data.op_type == INST_SFU_JOIN);
    wire op_is_bar    = (execute_if.data.op_type == INST_SFU_BAR);
    wire op_is_pred   = (execute_if.data.op_type == INST_SFU_PRED);
    wire op_is_wsync  = (execute_if.data.op_type == INST_SFU_WSYNC);

    tmc_t     tmc_n;
    wspawn_t  wspawn_n;
    split_t   split_n;
    join_t    sjoin_n;
    barrier_t bar_n;

    assign tmc_n.tmask = op_is_pred
                       ? (any_then ? full_then_mask : scalar_rs2[`VX_CFG_NUM_THREADS-1:0])
                       : scalar_rs1[`VX_CFG_NUM_THREADS-1:0];

    wire [CNT_W-1:0] cnt_then = count_active_bits(full_then_mask);
    wire [CNT_W-1:0] cnt_else = count_active_bits(full_else_mask);
    wire prefer_then          = (cnt_then <= cnt_else);

    assign split_n.is_dvg     = any_then && any_else;
    assign split_n.then_tmask = prefer_then ? full_then_mask : full_else_mask;
    assign split_n.else_tmask = prefer_then ? full_else_mask : full_then_mask;
    assign split_n.next_pc    = execute_if.data.header.PC + from_fullPC(`VX_CFG_XLEN'(4));

    assign sjoin_n.tmask     = full_then_mask | full_else_mask;
    assign sjoin_n.stack_ptr = scalar_rs1[DV_STACK_SIZEW-1:0];

    for (genvar w = 0; w < `VX_CFG_NUM_WARPS; ++w) begin : g_wspawn
        assign wspawn_n.wmask[w] = (w < scalar_rs1[NW_BITS:0]) && (w != execute_if.data.header.wid);
    end
    assign wspawn_n.pc = from_fullPC(scalar_rs2);

    wire [BAR_ADDR_W-1:0] bar_addr_calc;
    `CONCAT(bar_addr_calc, scalar_rs1[NW_BITS-1:0], scalar_rs1[BAR_ID_SHIFT +: NB_BITS], NW_BITS, NB_BITS)

    wire bar_cmd_en = eop_commit && op_is_bar;
    wire tx_expect  = bar_cmd_en && execute_if.data.op_args.wctl.is_bar_arrive && scalar_rs2[31];

    assign bar_n.id        = scalar_rs1[BAR_ID_SHIFT +: NB_BITS];
    assign bar_n.is_event  = (txbar_bus_if.valid && ~bar_cmd_en) || tx_expect;
    assign bar_n.is_sync   = execute_if.data.op_args.wctl.is_sync_bar;
    assign bar_n.is_global = bar_cmd_en && scalar_rs1[31];
    assign bar_n.is_arrive = (execute_if.data.op_args.wctl.is_bar_arrive && ~scalar_rs2[31]) || execute_if.data.op_args.wctl.is_sync_bar;
    assign bar_n.phase     = tx_expect ? 1'b1 : (bar_cmd_en ? scalar_rs2[0] : ~txbar_bus_if.data.is_done);
    assign bar_n.size_m1   = scalar_rs2[BAR_SIZE_W-1:0] - BAR_SIZE_W'(1);

    assign txbar_bus_if.ready      = ~bar_cmd_en;
    assign warp_ctl_if.dvstack_wid = execute_if.data.header.wid;
    assign warp_ctl_if.bar_addr    = bar_cmd_en ? bar_addr_calc : txbar_bus_if.data.addr;

    VX_pipe_register #(
        .DATAW  (6 + NW_WIDTH + WCTL_WIDTH),
        .RESETW (1)
    ) out_pipe (
        .clk      (clk),
        .reset    (reset),
        .enable   (1'b1),
        .data_in  ({
            eop_commit && (op_is_tmc || op_is_pred),
            eop_commit && op_is_wspawn,
            eop_commit && op_is_split,
            eop_commit && op_is_join,
            bar_cmd_en || txbar_bus_if.valid,
            eop_commit && op_is_wsync,
            execute_if.data.header.wid,
            tmc_n,
            wspawn_n,
            split_n,
            sjoin_n,
            bar_n
        }),
        .data_out ({
            warp_ctl_if.tmc_valid,
            warp_ctl_if.wspawn_valid,
            warp_ctl_if.split_valid,
            warp_ctl_if.sjoin_valid,
            warp_ctl_if.bar_valid,
            warp_ctl_if.wsync_valid,
            warp_ctl_if.wid,
            warp_ctl_if.tmc,
            warp_ctl_if.wspawn,
            warp_ctl_if.split,
            warp_ctl_if.sjoin,
            warp_ctl_if.bar
        })
    );

    wire bypass_split_push = warp_ctl_if.split_valid
                          && warp_ctl_if.split.is_dvg
                          && (warp_ctl_if.wid == execute_if.data.header.wid);
    wire [DV_STACK_SIZEW-1:0] stack_ptr_fwd = warp_ctl_if.dvstack_ptr + DV_STACK_SIZEW'(bypass_split_push);

    wire [DV_STACK_SIZEW-1:0] rsp_stack_ptr;
    wire rsp_is_bar_arrive = op_is_bar && execute_if.data.op_args.wctl.is_bar_arrive;
    wire rsp_bar_sel;
    wire rsp_bar_phase;

    VX_elastic_buffer #(
        .DATAW ($bits(sfu_header_t) + DV_STACK_SIZEW + 1 + 1),
        .SIZE  (2)
    ) rsp_fifo (
        .clk       (clk),
        .reset     (reset),
        .valid_in  (execute_if.valid && !wsync_stall && !bar_stall),
        .ready_in  (rsp_ready_in),
        .data_in   ({execute_if.data.header, stack_ptr_fwd, warp_ctl_if.bar_phase, rsp_is_bar_arrive}),
        .data_out  ({result_if.data.header,  rsp_stack_ptr, rsp_bar_phase,         rsp_bar_sel}),
        .valid_out (result_if.valid),
        .ready_out (result_if.ready)
    );

    for (genvar i = 0; i < NUM_LANES; ++i) begin : g_res_lanes
        assign result_if.data.data[i] = rsp_bar_sel ? `VX_CFG_XLEN'(rsp_bar_phase) : `VX_CFG_XLEN'(rsp_stack_ptr);
    end

endmodule
