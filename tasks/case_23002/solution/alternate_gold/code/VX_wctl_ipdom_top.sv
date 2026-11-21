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

// Read-only pin-level integration & synthesis wrapper coupling VX_wctl_unit + VX_split_join + VX_ipdom_stack
module VX_wctl_ipdom_top import VX_gpu_pkg::*; #(
    parameter NUM_LANES = `VX_CFG_NUM_SFU_LANES
) (
    input  wire                             clk,
    input  wire                             reset,

    // SFU execute interface
    input  wire                             exe_valid,
    input  sfu_execute_t                    exe_data,
    output wire                             exe_ready,

    // Async barrier event bus
    input  wire                             txbar_valid,
    input  txbar_t                          txbar_data,
    output wire                             txbar_ready,

    // Scheduler status / barrier phase feedback
    input  wire [`VX_CFG_NUM_WARPS-1:0]     warp_pending_alm_empty,
    input  wire                             lsu_sched_drained,
    input  wire                             bar_phase_in,

    // SFU result writeback interface
    output wire                             res_valid,
    output sfu_result_t                     res_data,
    input  wire                             res_ready,

    // Emitted warp control commands
    output wire                             wspawn_valid,
    output wire                             tmc_valid,
    output wire                             split_valid,
    output wire                             sjoin_valid,
    output wire                             bar_valid,
    output wire                             wsync_valid,
    output wire [NW_WIDTH-1:0]              wctl_wid,
    output tmc_t                            tmc_out,
    output wspawn_t                         wspawn_out,
    output split_t                          split_out,
    output join_t                           sjoin_out,
    output barrier_t                        bar_out,
    output wire [BAR_ADDR_W-1:0]            bar_addr_out,
    output wire [DV_STACK_SIZEW-1:0]        dvstack_ptr_mon,

    // Closed-loop VX_split_join + VX_ipdom_stack reconvergence outputs
    output wire                             join_valid,
    output wire                             join_is_dvg,
    output wire                             join_is_else,
    output wire [NW_WIDTH-1:0]              join_wid,
    output wire [`VX_CFG_NUM_THREADS-1:0]   join_tmask,
    output wire [PC_BITS-1:0]               join_pc
);
    VX_execute_if #(.data_t(sfu_execute_t)) execute_if();
    VX_txbar_bus_if                         txbar_bus_if();
    VX_warp_ctl_if                          warp_ctl_if();
    VX_result_if  #(.data_t(sfu_result_t))  result_if();

    assign execute_if.valid = exe_valid;
    assign execute_if.data  = exe_data;
    assign exe_ready        = execute_if.ready;

    assign txbar_bus_if.valid = txbar_valid;
    assign txbar_bus_if.data  = txbar_data;
    assign txbar_ready        = txbar_bus_if.ready;

    assign warp_ctl_if.warp_pending_alm_empty = warp_pending_alm_empty;
    assign warp_ctl_if.lsu_sched_drained      = lsu_sched_drained;
    assign warp_ctl_if.bar_phase              = bar_phase_in;

    assign res_valid       = result_if.valid;
    assign res_data        = result_if.data;
    assign result_if.ready = res_ready;

    VX_wctl_unit #(
        .INSTANCE_ID ("wctl"),
        .NUM_LANES   (NUM_LANES)
    ) wctl_unit (
        .clk          (clk),
        .reset        (reset),
        .execute_if   (execute_if),
        .txbar_bus_if (txbar_bus_if),
        .warp_ctl_if  (warp_ctl_if),
        .result_if    (result_if)
    );

    VX_split_join #(
        .INSTANCE_ID ("split_join"),
        .OUT_REG     (0)
    ) split_join (
        .clk         (clk),
        .reset       (reset),
        .split_valid (warp_ctl_if.split_valid),
        .sjoin_valid (warp_ctl_if.sjoin_valid),
        .wid         (warp_ctl_if.wid),
        .split       (warp_ctl_if.split),
        .sjoin       (warp_ctl_if.sjoin),
        .stack_wid   (warp_ctl_if.dvstack_wid),
        .join_valid  (join_valid),
        .join_is_dvg (join_is_dvg),
        .join_is_else(join_is_else),
        .join_wid    (join_wid),
        .join_tmask  (join_tmask),
        .join_pc     (join_pc),
        .stack_ptr   (warp_ctl_if.dvstack_ptr)
    );

    assign wspawn_valid    = warp_ctl_if.wspawn_valid;
    assign tmc_valid       = warp_ctl_if.tmc_valid;
    assign split_valid     = warp_ctl_if.split_valid;
    assign sjoin_valid     = warp_ctl_if.sjoin_valid;
    assign bar_valid       = warp_ctl_if.bar_valid;
    assign wsync_valid     = warp_ctl_if.wsync_valid;
    assign wctl_wid        = warp_ctl_if.wid;
    assign tmc_out         = warp_ctl_if.tmc;
    assign wspawn_out      = warp_ctl_if.wspawn;
    assign split_out       = warp_ctl_if.split;
    assign sjoin_out       = warp_ctl_if.sjoin;
    assign bar_out         = warp_ctl_if.bar;
    assign bar_addr_out    = warp_ctl_if.bar_addr;
    assign dvstack_ptr_mon = warp_ctl_if.dvstack_ptr;

endmodule
