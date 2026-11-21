// SPDX-License-Identifier: BSD-2-Clause-Views
/*
 * Copyright (c) 2019-2023 The Regents of the University of California
 */

// Language: Verilog 2001

`resetall
`timescale 1ns / 1ps
`default_nettype none

/*
 * TDMA Transmit scheduler control module (Alternate Gold: 4-entry start event FIFO + bubble-collapsing AXI-Lite read pipeline)
 */
module tx_scheduler_ctrl_tdma #
(
    parameter AXIL_DATA_WIDTH = 32,
    parameter AXIL_ADDR_WIDTH = 16,
    parameter AXIL_STRB_WIDTH = (AXIL_DATA_WIDTH/8),
    parameter TDMA_INDEX_WIDTH = 6,
    parameter QUEUE_INDEX_WIDTH = 6,
    parameter PIPELINE = 2
)
(
    input  wire                          clk,
    input  wire                          rst,

    output wire [QUEUE_INDEX_WIDTH-1:0]  m_axis_sched_ctrl_queue,
    output wire                          m_axis_sched_ctrl_enable,
    output wire                          m_axis_sched_ctrl_valid,
    input  wire                          m_axis_sched_ctrl_ready,

    input  wire [AXIL_ADDR_WIDTH-1:0]    s_axil_awaddr,
    input  wire [2:0]                    s_axil_awprot,
    input  wire                          s_axil_awvalid,
    output wire                          s_axil_awready,
    input  wire [AXIL_DATA_WIDTH-1:0]    s_axil_wdata,
    input  wire [AXIL_STRB_WIDTH-1:0]    s_axil_wstrb,
    input  wire                          s_axil_wvalid,
    output wire                          s_axil_wready,
    output wire [1:0]                    s_axil_bresp,
    output wire                          s_axil_bvalid,
    input  wire                          s_axil_bready,
    input  wire [AXIL_ADDR_WIDTH-1:0]    s_axil_araddr,
    input  wire [2:0]                    s_axil_arprot,
    input  wire                          s_axil_arvalid,
    output wire                          s_axil_arready,
    output wire [AXIL_DATA_WIDTH-1:0]    s_axil_rdata,
    output wire [1:0]                    s_axil_rresp,
    output wire                          s_axil_rvalid,
    input  wire                          s_axil_rready,

    input  wire                          tdma_schedule_start,
    input  wire [TDMA_INDEX_WIDTH-1:0]   tdma_timeslot_index,
    input  wire                          tdma_timeslot_start,
    input  wire                          tdma_timeslot_end,
    input  wire                          tdma_timeslot_active
);

parameter WORD_WIDTH = AXIL_STRB_WIDTH;
parameter WORD_SIZE = AXIL_DATA_WIDTH/WORD_WIDTH;
parameter QUEUE_COUNT = 2**QUEUE_INDEX_WIDTH;
parameter QUEUE_RAM_BE_WIDTH = (2**TDMA_INDEX_WIDTH+WORD_SIZE-1)/WORD_SIZE;
parameter QUEUE_RAM_WIDTH = QUEUE_RAM_BE_WIDTH*WORD_SIZE;
parameter ADDR_SHIFT = QUEUE_RAM_BE_WIDTH > AXIL_STRB_WIDTH ? $clog2(QUEUE_RAM_BE_WIDTH) : $clog2(AXIL_STRB_WIDTH);
parameter SEGMENT_SHIFT = $clog2(AXIL_STRB_WIDTH);
parameter SEGMENT_AW = QUEUE_RAM_BE_WIDTH > AXIL_STRB_WIDTH ? $clog2(QUEUE_RAM_BE_WIDTH) - $clog2(AXIL_STRB_WIDTH) : 0;
parameter SEGMENT_COUNT = 2**SEGMENT_AW;
localparam SEG_SHIFT_W = (SEGMENT_AW > 0) ? SEGMENT_AW : 1;

localparam [2:0]
    ST_BOOT      = 3'd0,
    ST_SCAN      = 3'd1,
    ST_IDLE_SLOT = 3'd2,
    ST_EMIT_TS0  = 3'd3,
    ST_EMIT_TSN  = 3'd4,
    ST_IDLE_END  = 3'd5,
    ST_EMIT_STOP = 3'd6;

reg [2:0] st_r = ST_BOOT, st_n;

reg set_dirty;
reg clr_dirty;
reg dirty_r = 1'b0;

reg [QUEUE_INDEX_WIDTH-1:0] ctrl_q_r  = {QUEUE_INDEX_WIDTH{1'b0}}, ctrl_q_n;
reg                         ctrl_en_r = 1'b0, ctrl_en_n;
reg                         ctrl_v_r  = 1'b0, ctrl_v_n;

// 4-entry start-event FIFO + pending stop flag
reg [TDMA_INDEX_WIDTH-1:0] ev_idx_fifo [0:3];
reg [2:0]                  ev_wr_ptr_r = 3'd0;
reg [2:0]                  ev_rd_ptr_r = 3'd0;
reg                        pop_start_ev;
wire                       has_start_ev   = (ev_wr_ptr_r != ev_rd_ptr_r);
wire [TDMA_INDEX_WIDTH-1:0] head_start_idx = ev_idx_fifo[ev_rd_ptr_r[1:0]];

reg                        pend_stop_r = 1'b0;
reg                        pop_stop_ev;

reg [TDMA_INDEX_WIDTH-1:0] scan_slot_r = {TDMA_INDEX_WIDTH{1'b0}}, scan_slot_n;
reg [QUEUE_INDEX_WIDTH-1:0] scan_q_r   = {QUEUE_INDEX_WIDTH{1'b0}}, scan_q_n;

reg [QUEUE_RAM_WIDTH-1:0] queue_ram [QUEUE_COUNT-1:0];

reg [QUEUE_INDEX_WIDTH-1:0] ts0_list [QUEUE_COUNT-1:0];
reg [QUEUE_INDEX_WIDTH:0]   ts0_wr_r = 0, ts0_wr_n;
reg [QUEUE_INDEX_WIDTH:0]   ts0_rd_r = 0, ts0_rd_n;
reg                         ts0_we;

reg [QUEUE_INDEX_WIDTH-1:0] tsn_list [QUEUE_COUNT-1:0];
reg [QUEUE_INDEX_WIDTH:0]   tsn_wr_r = 0, tsn_wr_n;
reg [QUEUE_INDEX_WIDTH:0]   tsn_rd_r = 0, tsn_rd_n;
reg                         tsn_we;

reg [QUEUE_INDEX_WIDTH-1:0] stp_list [QUEUE_COUNT-1:0];
reg [QUEUE_INDEX_WIDTH:0]   stp_wr_r = 0, stp_wr_n;
reg [QUEUE_INDEX_WIDTH:0]   stp_rd_r = 0, stp_rd_n;
reg [QUEUE_INDEX_WIDTH-1:0] stp_wdata;
reg                         stp_we;

assign m_axis_sched_ctrl_queue  = ctrl_q_r;
assign m_axis_sched_ctrl_enable = ctrl_en_r;
assign m_axis_sched_ctrl_valid  = ctrl_v_r;

integer k, m;
initial begin
    for (k = 0; k < 2**QUEUE_INDEX_WIDTH; k = k + 2**(QUEUE_INDEX_WIDTH/2)) begin
        for (m = k; m < k + 2**(QUEUE_INDEX_WIDTH/2); m = m + 1) begin
            queue_ram[m] = {QUEUE_RAM_WIDTH{1'b0}};
        end
    end
end

always @* begin
    st_n         = st_r;
    clr_dirty    = 1'b0;
    pop_start_ev = 1'b0;
    pop_stop_ev  = 1'b0;

    scan_slot_n  = scan_slot_r;
    scan_q_n     = scan_q_r;

    ts0_wr_n     = ts0_wr_r;
    ts0_rd_n     = ts0_rd_r;
    ts0_we       = 1'b0;

    tsn_wr_n     = tsn_wr_r;
    tsn_rd_n     = tsn_rd_r;
    tsn_we       = 1'b0;

    stp_wr_n     = stp_wr_r;
    stp_rd_n     = stp_rd_r;
    stp_wdata    = {QUEUE_INDEX_WIDTH{1'b0}};
    stp_we       = 1'b0;

    ctrl_q_n     = ctrl_q_r;
    ctrl_en_n    = ctrl_en_r;
    ctrl_v_n     = ctrl_v_r && !m_axis_sched_ctrl_ready;

    case (st_r)
        ST_BOOT: begin
            ts0_wr_n    = 0;
            ts0_rd_n    = 0;
            tsn_wr_n    = 0;
            tsn_rd_n    = 0;
            stp_wr_n    = 0;
            stp_rd_n    = 0;
            scan_q_n    = 0;
            scan_slot_n = 0;
            clr_dirty   = 1'b1;
            st_n        = ST_SCAN;
        end
        ST_SCAN: begin
            if (queue_ram[scan_q_r][0]) begin
                ts0_we   = 1'b1;
                ts0_wr_n = ts0_wr_r + 1'b1;
            end
            if (queue_ram[scan_q_r][scan_slot_r]) begin
                tsn_we   = 1'b1;
                tsn_wr_n = tsn_wr_r + 1'b1;
            end
            scan_q_n = scan_q_r + 1'b1;
            if (scan_q_r + 1 == QUEUE_COUNT) begin
                st_n = ST_IDLE_SLOT;
            end else begin
                st_n = ST_SCAN;
            end
        end
        ST_IDLE_SLOT: begin
            stp_wr_n = 0;
            stp_rd_n = 0;
            if (has_start_ev) begin
                if (!dirty_r && head_start_idx == 0) begin
                    pop_start_ev = 1'b1;
                    scan_slot_n  = {{(TDMA_INDEX_WIDTH-1){1'b0}}, 1'b1};
                    st_n         = (ts0_wr_r == 0) ? ST_IDLE_END : ST_EMIT_TS0;
                end else if (!dirty_r && head_start_idx == scan_slot_r) begin
                    pop_start_ev = 1'b1;
                    scan_slot_n  = head_start_idx + 1'b1;
                    st_n         = (tsn_wr_r == 0) ? ST_IDLE_END : ST_EMIT_TSN;
                end else begin
                    ts0_wr_n    = 0;
                    ts0_rd_n    = 0;
                    tsn_wr_n    = 0;
                    tsn_rd_n    = 0;
                    scan_q_n    = 0;
                    clr_dirty   = 1'b1;
                    scan_slot_n = head_start_idx;
                    st_n        = ST_SCAN;
                end
            end
        end
        ST_EMIT_TS0: begin
            if (!ctrl_v_r || m_axis_sched_ctrl_ready) begin
                ctrl_q_n  = ts0_list[ts0_rd_r[QUEUE_INDEX_WIDTH-1:0]];
                ctrl_en_n = 1'b1;
                ctrl_v_n  = 1'b1;
                stp_wdata = ts0_list[ts0_rd_r[QUEUE_INDEX_WIDTH-1:0]];
                stp_we    = 1'b1;
                stp_wr_n  = stp_wr_r + 1'b1;
                ts0_rd_n  = ts0_rd_r + 1'b1;
                if (ts0_rd_r + 1'b1 == ts0_wr_r) begin
                    stp_rd_n = 0;
                    st_n     = ST_IDLE_END;
                end
            end
        end
        ST_EMIT_TSN: begin
            if (!ctrl_v_r || m_axis_sched_ctrl_ready) begin
                ctrl_q_n  = tsn_list[tsn_rd_r[QUEUE_INDEX_WIDTH-1:0]];
                ctrl_en_n = 1'b1;
                ctrl_v_n  = 1'b1;
                stp_wdata = tsn_list[tsn_rd_r[QUEUE_INDEX_WIDTH-1:0]];
                stp_we    = 1'b1;
                stp_wr_n  = stp_wr_r + 1'b1;
                tsn_rd_n  = tsn_rd_r + 1'b1;
                if (tsn_rd_r + 1'b1 == tsn_wr_r) begin
                    stp_rd_n = 0;
                    st_n     = ST_IDLE_END;
                end
            end
        end
        ST_IDLE_END: begin
            if (pend_stop_r) begin
                pop_stop_ev = 1'b1;
                if (stp_wr_r == 0) begin
                    ts0_wr_n  = 0;
                    ts0_rd_n  = 0;
                    tsn_wr_n  = 0;
                    tsn_rd_n  = 0;
                    scan_q_n  = 0;
                    clr_dirty = 1'b1;
                    st_n      = ST_SCAN;
                end else begin
                    st_n = ST_EMIT_STOP;
                end
            end
        end
        ST_EMIT_STOP: begin
            if (!ctrl_v_r || m_axis_sched_ctrl_ready) begin
                ctrl_q_n  = stp_list[stp_rd_r[QUEUE_INDEX_WIDTH-1:0]];
                ctrl_en_n = 1'b0;
                ctrl_v_n  = 1'b1;
                stp_rd_n  = stp_rd_r + 1'b1;
                if (stp_rd_r + 1'b1 == stp_wr_r) begin
                    ts0_wr_n  = 0;
                    ts0_rd_n  = 0;
                    tsn_wr_n  = 0;
                    tsn_rd_n  = 0;
                    scan_q_n  = 0;
                    clr_dirty = 1'b1;
                    st_n      = ST_SCAN;
                end
            end
        end
        default: begin
            st_n = ST_BOOT;
        end
    endcase
end

always @(posedge clk) begin
    if (rst) begin
        st_r        <= ST_BOOT;
        dirty_r     <= 1'b0;
        ev_wr_ptr_r <= 3'd0;
        ev_rd_ptr_r <= 3'd0;
        for (k = 0; k < 4; k = k + 1) begin
            ev_idx_fifo[k] <= {TDMA_INDEX_WIDTH{1'b0}};
        end
        pend_stop_r <= 1'b0;
        scan_slot_r <= {TDMA_INDEX_WIDTH{1'b0}};
        scan_q_r    <= {QUEUE_INDEX_WIDTH{1'b0}};
        ts0_wr_r    <= 0;
        ts0_rd_r    <= 0;
        tsn_wr_r    <= 0;
        tsn_rd_r    <= 0;
        stp_wr_r    <= 0;
        stp_rd_r    <= 0;
        ctrl_q_r    <= {QUEUE_INDEX_WIDTH{1'b0}};
        ctrl_en_r   <= 1'b0;
        ctrl_v_r    <= 1'b0;
    end else begin
        st_r        <= st_n;
        dirty_r     <= (dirty_r && !clr_dirty) || set_dirty;
        scan_slot_r <= scan_slot_n;
        scan_q_r    <= scan_q_n;
        ts0_wr_r    <= ts0_wr_n;
        ts0_rd_r    <= ts0_rd_n;
        tsn_wr_r    <= tsn_wr_n;
        tsn_rd_r    <= tsn_rd_n;
        stp_wr_r    <= stp_wr_n;
        stp_rd_r    <= stp_rd_n;
        ctrl_q_r    <= ctrl_q_n;
        ctrl_en_r   <= ctrl_en_n;
        ctrl_v_r    <= ctrl_v_n;

        if (pop_start_ev) begin
            ev_rd_ptr_r <= ev_rd_ptr_r + 3'd1;
        end
        if (tdma_timeslot_start) begin
            if ((ev_wr_ptr_r - (pop_start_ev ? (ev_rd_ptr_r + 3'd1) : ev_rd_ptr_r)) == 3'd4) begin
                // If 4-entry FIFO is full under extreme stall, advance oldest to retain latest start
                ev_rd_ptr_r <= (pop_start_ev ? (ev_rd_ptr_r + 3'd1) : ev_rd_ptr_r) + 3'd1;
            end
            ev_idx_fifo[ev_wr_ptr_r[1:0]] <= tdma_timeslot_index;
            ev_wr_ptr_r <= ev_wr_ptr_r + 3'd1;
        end

        if (tdma_timeslot_end) begin
            pend_stop_r <= 1'b1;
        end else if (pop_stop_ev) begin
            pend_stop_r <= 1'b0;
        end

        if (ts0_we) ts0_list[ts0_wr_r[QUEUE_INDEX_WIDTH-1:0]] <= scan_q_r;
        if (tsn_we) tsn_list[tsn_wr_r[QUEUE_INDEX_WIDTH-1:0]] <= scan_q_r;
        if (stp_we) stp_list[stp_wr_r[QUEUE_INDEX_WIDTH-1:0]] <= stp_wdata;
    end
end

// Bubble-collapsing AXI4-Lite interface across PIPELINE >= 2 stages
reg                       axil_last_rd_r = 1'b0, axil_last_rd_n;
reg                       awready_r = 1'b0, awready_n;
reg                       wready_r  = 1'b0, wready_n;
reg                       bvalid_r  = 1'b0, bvalid_n;
reg                       arready_r = 1'b0, arready_n;
reg [AXIL_DATA_WIDTH-1:0] rdata_r   = {AXIL_DATA_WIDTH{1'b0}};
reg                       rvalid_r  = 1'b0;

reg [QUEUE_RAM_WIDTH-1:0] rd_data_pipe_r  [PIPELINE-1:0];
reg [SEG_SHIFT_W-1:0]     rd_shift_pipe_r [PIPELINE-1:0];
reg [PIPELINE-1:0]        rd_valid_pipe_r = {PIPELINE{1'b0}};
reg [PIPELINE:0]          rd_stage_rdy;

assign s_axil_awready = awready_r;
assign s_axil_wready  = wready_r;
assign s_axil_bresp   = 2'b00;
assign s_axil_bvalid  = bvalid_r;
assign s_axil_arready = arready_r;
assign s_axil_rdata   = rdata_r;
assign s_axil_rresp   = 2'b00;
assign s_axil_rvalid  = rvalid_r;

reg [QUEUE_INDEX_WIDTH-1:0]  axil_ptr;
reg                          axil_wr_en;
reg [QUEUE_RAM_WIDTH-1:0]    axil_wr_data;
reg [QUEUE_RAM_BE_WIDTH-1:0] axil_wr_be;
reg                          axil_rd_en;
reg                          wr_ok, rd_ok;

integer stg;
always @* begin
    rd_stage_rdy[PIPELINE] = !rvalid_r || s_axil_rready;
    for (stg = PIPELINE - 1; stg >= 0; stg = stg - 1) begin
        rd_stage_rdy[stg] = !rd_valid_pipe_r[stg] || rd_stage_rdy[stg + 1];
    end

    axil_wr_en   = 1'b0;
    axil_rd_en   = 1'b0;
    axil_ptr     = {QUEUE_INDEX_WIDTH{1'b0}};
    axil_wr_data = {SEGMENT_COUNT{s_axil_wdata}};
    if (SEGMENT_COUNT > 1) begin
        axil_wr_be = s_axil_wstrb << (((s_axil_awaddr >> SEGMENT_SHIFT) & {SEG_SHIFT_W{1'b1}}) * AXIL_STRB_WIDTH);
    end else begin
        axil_wr_be = s_axil_wstrb;
    end

    set_dirty      = 1'b0;
    axil_last_rd_n = axil_last_rd_r;
    awready_n      = 1'b0;
    wready_n       = 1'b0;
    bvalid_n       = bvalid_r && !s_axil_bready;
    arready_n      = 1'b0;

    wr_ok = s_axil_awvalid && s_axil_wvalid && (!bvalid_r || s_axil_bready) && (!awready_r && !wready_r);
    rd_ok = s_axil_arvalid && rd_stage_rdy[0] && (!arready_r);

    if (wr_ok && (!rd_ok || axil_last_rd_r)) begin
        axil_last_rd_n = 1'b0;
        awready_n      = 1'b1;
        wready_n       = 1'b1;
        bvalid_n       = 1'b1;
        set_dirty      = 1'b1;
        axil_wr_en     = 1'b1;
        axil_ptr       = s_axil_awaddr >> ADDR_SHIFT;
    end else if (rd_ok) begin
        axil_last_rd_n = 1'b1;
        arready_n      = 1'b1;
        axil_rd_en     = 1'b1;
        axil_ptr       = s_axil_araddr >> ADDR_SHIFT;
    end
end

always @(posedge clk) begin
    if (rst) begin
        axil_last_rd_r  <= 1'b0;
        awready_r       <= 1'b0;
        wready_r        <= 1'b0;
        bvalid_r        <= 1'b0;
        arready_r       <= 1'b0;
        rdata_r         <= {AXIL_DATA_WIDTH{1'b0}};
        rvalid_r        <= 1'b0;
        rd_valid_pipe_r <= {PIPELINE{1'b0}};
        for (stg = 0; stg < PIPELINE; stg = stg + 1) begin
            rd_data_pipe_r[stg]  <= {QUEUE_RAM_WIDTH{1'b0}};
            rd_shift_pipe_r[stg] <= {SEG_SHIFT_W{1'b0}};
        end
    end else begin
        axil_last_rd_r <= axil_last_rd_n;
        awready_r      <= awready_n;
        wready_r       <= wready_n;
        bvalid_r       <= bvalid_n;
        arready_r      <= arready_n;

        if (rd_stage_rdy[PIPELINE]) begin
            rvalid_r <= rd_valid_pipe_r[PIPELINE-1];
            if (rd_valid_pipe_r[PIPELINE-1]) begin
                if (SEGMENT_COUNT > 1) begin
                    rdata_r <= rd_data_pipe_r[PIPELINE-1] >> (rd_shift_pipe_r[PIPELINE-1] * AXIL_DATA_WIDTH);
                end else begin
                    rdata_r <= rd_data_pipe_r[PIPELINE-1];
                end
            end
        end

        for (stg = PIPELINE - 1; stg > 0; stg = stg - 1) begin
            if (rd_stage_rdy[stg]) begin
                rd_valid_pipe_r[stg] <= rd_valid_pipe_r[stg-1];
                rd_data_pipe_r[stg]  <= rd_data_pipe_r[stg-1];
                rd_shift_pipe_r[stg] <= rd_shift_pipe_r[stg-1];
            end
        end

        if (rd_stage_rdy[0]) begin
            rd_valid_pipe_r[0] <= axil_rd_en;
            if (axil_rd_en) begin
                rd_data_pipe_r[0] <= queue_ram[axil_ptr];
                if (SEGMENT_COUNT > 1) begin
                    rd_shift_pipe_r[0] <= (s_axil_araddr >> SEGMENT_SHIFT) & {SEG_SHIFT_W{1'b1}};
                end else begin
                    rd_shift_pipe_r[0] <= {SEG_SHIFT_W{1'b0}};
                end
            end
        end

        if (axil_wr_en) begin
            for (k = 0; k < QUEUE_RAM_BE_WIDTH; k = k + 1) begin
                if (axil_wr_be[k]) begin
                    queue_ram[axil_ptr][WORD_SIZE*k +: WORD_SIZE] <= axil_wr_data[WORD_SIZE*k +: WORD_SIZE];
                end
            end
        end
    end
end

endmodule

`resetall
