// SPDX-License-Identifier: BSD-2-Clause-Views
/*
 * Copyright (c) 2019-2023 The Regents of the University of California
 */

// Language: Verilog 2001

`resetall
`timescale 1ns / 1ps
`default_nettype none

/*
 * TDMA Transmit scheduler control module
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
    STATE_IDLE       = 3'd0,
    STATE_FILL_START = 3'd1,
    STATE_WAIT_START = 3'd2,
    STATE_START_0    = 3'd3,
    STATE_START_N    = 3'd4,
    STATE_WAIT_STOP  = 3'd5,
    STATE_STOP       = 3'd6;

reg [2:0] state_reg = STATE_IDLE, state_next;

reg read_eligible;
reg write_eligible;

reg set_inconsistent;
reg clear_inconsistent;
reg inconsistent_reg = 1'b0;

reg last_read_reg = 1'b0, last_read_next;

reg [QUEUE_INDEX_WIDTH-1:0] m_axis_sched_ctrl_queue_reg  = {QUEUE_INDEX_WIDTH{1'b0}}, m_axis_sched_ctrl_queue_next;
reg                         m_axis_sched_ctrl_enable_reg = 1'b0, m_axis_sched_ctrl_enable_next;
reg                         m_axis_sched_ctrl_valid_reg  = 1'b0, m_axis_sched_ctrl_valid_next;

reg                       s_axil_awready_reg = 1'b0, s_axil_awready_next;
reg                       s_axil_wready_reg  = 1'b0, s_axil_wready_next;
reg                       s_axil_bvalid_reg  = 1'b0, s_axil_bvalid_next;
reg                       s_axil_arready_reg = 1'b0, s_axil_arready_next;
reg [AXIL_DATA_WIDTH-1:0] s_axil_rdata_reg   = {AXIL_DATA_WIDTH{1'b0}};
reg                       s_axil_rvalid_reg  = 1'b0;

reg [QUEUE_RAM_WIDTH-1:0]    queue_ram [QUEUE_COUNT-1:0];
reg [QUEUE_INDEX_WIDTH-1:0]  queue_ram_axil_ptr;
reg                          queue_ram_axil_wr_en;
reg [QUEUE_RAM_WIDTH-1:0]    queue_ram_axil_wr_data;
reg [QUEUE_RAM_BE_WIDTH-1:0] queue_ram_axil_wr_be;
reg                          queue_ram_axil_rd_en;

reg [QUEUE_RAM_WIDTH-1:0] queue_ram_read_data_pipeline_reg  [PIPELINE-1:0];
reg [SEG_SHIFT_W-1:0]     queue_ram_read_data_shift_pipeline_reg [PIPELINE-1:0];
reg [PIPELINE-1:0]        queue_ram_read_data_valid_pipeline_reg = {PIPELINE{1'b0}};

reg [QUEUE_INDEX_WIDTH-1:0] queue_ram_ptr_reg = {QUEUE_INDEX_WIDTH{1'b0}}, queue_ram_ptr_next;

reg [QUEUE_INDEX_WIDTH-1:0] start_queue_ts_0_ram [QUEUE_COUNT-1:0];
reg [QUEUE_INDEX_WIDTH:0]   start_queue_ts_0_wr_ptr_reg = {QUEUE_INDEX_WIDTH+1{1'b0}}, start_queue_ts_0_wr_ptr_next;
reg [QUEUE_INDEX_WIDTH:0]   start_queue_ts_0_rd_ptr_reg = {QUEUE_INDEX_WIDTH+1{1'b0}}, start_queue_ts_0_rd_ptr_next;
reg [QUEUE_INDEX_WIDTH-1:0] start_queue_ts_0_wr_data;
reg                         start_queue_ts_0_wr_en;

reg [QUEUE_INDEX_WIDTH-1:0] start_queue_ts_n_ram [QUEUE_COUNT-1:0];
reg [QUEUE_INDEX_WIDTH:0]   start_queue_ts_n_wr_ptr_reg = {QUEUE_INDEX_WIDTH+1{1'b0}}, start_queue_ts_n_wr_ptr_next;
reg [QUEUE_INDEX_WIDTH:0]   start_queue_ts_n_rd_ptr_reg = {QUEUE_INDEX_WIDTH+1{1'b0}}, start_queue_ts_n_rd_ptr_next;
reg [QUEUE_INDEX_WIDTH-1:0] start_queue_ts_n_wr_data;
reg                         start_queue_ts_n_wr_en;

reg [QUEUE_INDEX_WIDTH-1:0] stop_queue_ram [QUEUE_COUNT-1:0];
reg [QUEUE_INDEX_WIDTH:0]   stop_queue_wr_ptr_reg = {QUEUE_INDEX_WIDTH+1{1'b0}}, stop_queue_wr_ptr_next;
reg [QUEUE_INDEX_WIDTH:0]   stop_queue_rd_ptr_reg = {QUEUE_INDEX_WIDTH+1{1'b0}}, stop_queue_rd_ptr_next;
reg [QUEUE_INDEX_WIDTH-1:0] stop_queue_wr_data;
reg                         stop_queue_wr_en;

reg                        got_start_reg   = 1'b0, got_start_next;
reg [TDMA_INDEX_WIDTH-1:0] start_index_reg = {TDMA_INDEX_WIDTH{1'b0}}, start_index_next;
reg [TDMA_INDEX_WIDTH-1:0] cur_index_reg   = {TDMA_INDEX_WIDTH{1'b0}}, cur_index_next;
reg                        got_stop_reg    = 1'b0, got_stop_next;

assign m_axis_sched_ctrl_queue  = m_axis_sched_ctrl_queue_reg;
assign m_axis_sched_ctrl_enable = m_axis_sched_ctrl_enable_reg;
assign m_axis_sched_ctrl_valid  = m_axis_sched_ctrl_valid_reg;

assign s_axil_awready = s_axil_awready_reg;
assign s_axil_wready  = s_axil_wready_reg;
assign s_axil_bresp   = 2'b00;
assign s_axil_bvalid  = s_axil_bvalid_reg;
assign s_axil_arready = s_axil_arready_reg;
assign s_axil_rdata   = s_axil_rdata_reg;
assign s_axil_rresp   = 2'b00;
assign s_axil_rvalid  = s_axil_rvalid_reg;

integer i, j;

initial begin
    for (i = 0; i < 2**QUEUE_INDEX_WIDTH; i = i + 2**(QUEUE_INDEX_WIDTH/2)) begin
        for (j = i; j < i + 2**(QUEUE_INDEX_WIDTH/2); j = j + 1) begin
            queue_ram[j] = {QUEUE_RAM_WIDTH{1'b0}};
        end
    end
end

always @* begin
    state_next = state_reg;

    clear_inconsistent = 1'b0;

    start_queue_ts_0_wr_data = queue_ram_ptr_reg;
    start_queue_ts_n_wr_data = queue_ram_ptr_reg;
    start_queue_ts_0_wr_en   = 1'b0;
    start_queue_ts_n_wr_en   = 1'b0;
    stop_queue_wr_data       = {QUEUE_INDEX_WIDTH{1'b0}};
    stop_queue_wr_en         = 1'b0;

    got_start_next   = got_start_reg;
    start_index_next = start_index_reg;
    cur_index_next   = cur_index_reg;
    got_stop_next    = got_stop_reg;

    start_queue_ts_0_wr_ptr_next = start_queue_ts_0_wr_ptr_reg;
    start_queue_ts_0_rd_ptr_next = start_queue_ts_0_rd_ptr_reg;
    start_queue_ts_n_wr_ptr_next = start_queue_ts_n_wr_ptr_reg;
    start_queue_ts_n_rd_ptr_next = start_queue_ts_n_rd_ptr_reg;
    stop_queue_wr_ptr_next       = stop_queue_wr_ptr_reg;
    stop_queue_rd_ptr_next       = stop_queue_rd_ptr_reg;

    queue_ram_ptr_next = queue_ram_ptr_reg;

    m_axis_sched_ctrl_queue_next  = m_axis_sched_ctrl_queue_reg;
    m_axis_sched_ctrl_enable_next = m_axis_sched_ctrl_enable_reg;
    m_axis_sched_ctrl_valid_next  = m_axis_sched_ctrl_valid_reg && !m_axis_sched_ctrl_ready;

    case (state_reg)
        STATE_IDLE: begin
            start_queue_ts_0_rd_ptr_next = 0;
            start_queue_ts_0_wr_ptr_next = 0;
            start_queue_ts_n_rd_ptr_next = 0;
            start_queue_ts_n_wr_ptr_next = 0;
            stop_queue_rd_ptr_next       = 0;
            stop_queue_wr_ptr_next       = 0;
            queue_ram_ptr_next           = 0;
            cur_index_next               = 0;
            clear_inconsistent           = 1'b1;
            state_next                   = STATE_FILL_START;
        end
        STATE_FILL_START: begin
            start_queue_ts_0_wr_data = queue_ram_ptr_reg;
            if (queue_ram[queue_ram_ptr_reg][0]) begin
                start_queue_ts_0_wr_en       = 1'b1;
                start_queue_ts_0_wr_ptr_next = start_queue_ts_0_wr_ptr_reg + 1'b1;
            end

            start_queue_ts_n_wr_data = queue_ram_ptr_reg;
            if (queue_ram[queue_ram_ptr_reg][cur_index_reg]) begin
                start_queue_ts_n_wr_en       = 1'b1;
                start_queue_ts_n_wr_ptr_next = start_queue_ts_n_wr_ptr_reg + 1'b1;
            end

            queue_ram_ptr_next = queue_ram_ptr_reg + 1'b1;
            if (queue_ram_ptr_reg + 1 == QUEUE_COUNT) begin
                state_next = STATE_WAIT_START;
            end else begin
                state_next = STATE_FILL_START;
            end
        end
        STATE_WAIT_START: begin
            stop_queue_rd_ptr_next = 0;
            stop_queue_wr_ptr_next = 0;
            if (got_start_reg) begin
                if (!inconsistent_reg && start_index_reg == 0) begin
                    got_start_next = 1'b0;
                    cur_index_next = {{(TDMA_INDEX_WIDTH-1){1'b0}}, 1'b1};
                    if (start_queue_ts_0_wr_ptr_reg == 0) begin
                        state_next = STATE_WAIT_STOP;
                    end else begin
                        state_next = STATE_START_0;
                    end
                end else if (!inconsistent_reg && start_index_reg == cur_index_reg) begin
                    got_start_next = 1'b0;
                    cur_index_next = start_index_reg + 1'b1;
                    if (start_queue_ts_n_wr_ptr_reg == 0) begin
                        state_next = STATE_WAIT_STOP;
                    end else begin
                        state_next = STATE_START_N;
                    end
                end else begin
                    start_queue_ts_0_rd_ptr_next = 0;
                    start_queue_ts_0_wr_ptr_next = 0;
                    start_queue_ts_n_rd_ptr_next = 0;
                    start_queue_ts_n_wr_ptr_next = 0;
                    queue_ram_ptr_next           = 0;
                    clear_inconsistent           = 1'b1;
                    cur_index_next               = start_index_reg;
                    state_next                   = STATE_FILL_START;
                end
            end else begin
                state_next = STATE_WAIT_START;
            end
        end
        STATE_START_0: begin
            if (!m_axis_sched_ctrl_valid_reg || m_axis_sched_ctrl_ready) begin
                m_axis_sched_ctrl_queue_next  = start_queue_ts_0_ram[start_queue_ts_0_rd_ptr_reg[QUEUE_INDEX_WIDTH-1:0]];
                m_axis_sched_ctrl_enable_next = 1'b1;
                m_axis_sched_ctrl_valid_next  = 1'b1;

                stop_queue_wr_data           = start_queue_ts_0_ram[start_queue_ts_0_rd_ptr_reg[QUEUE_INDEX_WIDTH-1:0]];
                start_queue_ts_0_rd_ptr_next = start_queue_ts_0_rd_ptr_reg + 1'b1;
                stop_queue_wr_en             = 1'b1;
                stop_queue_wr_ptr_next       = stop_queue_wr_ptr_reg + 1'b1;

                if (start_queue_ts_0_rd_ptr_reg + 1'b1 == start_queue_ts_0_wr_ptr_reg) begin
                    stop_queue_rd_ptr_next = 0;
                    state_next             = STATE_WAIT_STOP;
                end else begin
                    state_next = STATE_START_0;
                end
            end
        end
        STATE_START_N: begin
            if (!m_axis_sched_ctrl_valid_reg || m_axis_sched_ctrl_ready) begin
                m_axis_sched_ctrl_queue_next  = start_queue_ts_n_ram[start_queue_ts_n_rd_ptr_reg[QUEUE_INDEX_WIDTH-1:0]];
                m_axis_sched_ctrl_enable_next = 1'b1;
                m_axis_sched_ctrl_valid_next  = 1'b1;

                stop_queue_wr_data           = start_queue_ts_n_ram[start_queue_ts_n_rd_ptr_reg[QUEUE_INDEX_WIDTH-1:0]];
                start_queue_ts_n_rd_ptr_next = start_queue_ts_n_rd_ptr_reg + 1'b1;
                stop_queue_wr_en             = 1'b1;
                stop_queue_wr_ptr_next       = stop_queue_wr_ptr_reg + 1'b1;

                if (start_queue_ts_n_rd_ptr_reg + 1'b1 == start_queue_ts_n_wr_ptr_reg) begin
                    stop_queue_rd_ptr_next = 0;
                    state_next             = STATE_WAIT_STOP;
                end else begin
                    state_next = STATE_START_N;
                end
            end
        end
        STATE_WAIT_STOP: begin
            if (got_stop_reg) begin
                got_stop_next = 1'b0;
                if (stop_queue_wr_ptr_reg == 0) begin
                    start_queue_ts_0_rd_ptr_next = 0;
                    start_queue_ts_0_wr_ptr_next = 0;
                    start_queue_ts_n_rd_ptr_next = 0;
                    start_queue_ts_n_wr_ptr_next = 0;
                    queue_ram_ptr_next           = 0;
                    clear_inconsistent           = 1'b1;
                    state_next                   = STATE_FILL_START;
                end else begin
                    state_next = STATE_STOP;
                end
            end else begin
                state_next = STATE_WAIT_STOP;
            end
        end
        STATE_STOP: begin
            if (!m_axis_sched_ctrl_valid_reg || m_axis_sched_ctrl_ready) begin
                m_axis_sched_ctrl_queue_next  = stop_queue_ram[stop_queue_rd_ptr_reg[QUEUE_INDEX_WIDTH-1:0]];
                m_axis_sched_ctrl_enable_next = 1'b0;
                m_axis_sched_ctrl_valid_next  = 1'b1;

                stop_queue_rd_ptr_next = stop_queue_rd_ptr_reg + 1'b1;
                if (stop_queue_rd_ptr_reg + 1'b1 == stop_queue_wr_ptr_reg) begin
                    start_queue_ts_0_rd_ptr_next = 0;
                    start_queue_ts_0_wr_ptr_next = 0;
                    start_queue_ts_n_rd_ptr_next = 0;
                    start_queue_ts_n_wr_ptr_next = 0;
                    queue_ram_ptr_next           = 0;
                    clear_inconsistent           = 1'b1;
                    state_next                   = STATE_FILL_START;
                end else begin
                    state_next = STATE_STOP;
                end
            end
        end
        default: begin
            state_next = STATE_IDLE;
        end
    endcase

    // Unconditionally capture incoming start/stop pulses (including on drain-exit beats!)
    if (tdma_timeslot_start) begin
        got_start_next   = 1'b1;
        start_index_next = tdma_timeslot_index;
    end
    if (tdma_timeslot_end) begin
        got_stop_next = 1'b1;
    end
end

always @(posedge clk) begin
    if (rst) begin
        state_reg                    <= STATE_IDLE;
        inconsistent_reg             <= 1'b0;
        got_start_reg                <= 1'b0;
        start_index_reg              <= {TDMA_INDEX_WIDTH{1'b0}};
        cur_index_reg                <= {TDMA_INDEX_WIDTH{1'b0}};
        got_stop_reg                 <= 1'b0;
        start_queue_ts_0_wr_ptr_reg  <= 0;
        start_queue_ts_0_rd_ptr_reg  <= 0;
        start_queue_ts_n_wr_ptr_reg  <= 0;
        start_queue_ts_n_rd_ptr_reg  <= 0;
        stop_queue_wr_ptr_reg        <= 0;
        stop_queue_rd_ptr_reg        <= 0;
        queue_ram_ptr_reg            <= 0;
        m_axis_sched_ctrl_queue_reg  <= 0;
        m_axis_sched_ctrl_enable_reg <= 1'b0;
        m_axis_sched_ctrl_valid_reg  <= 1'b0;
    end else begin
        state_reg                    <= state_next;
        got_start_reg                <= got_start_next;
        start_index_reg              <= start_index_next;
        cur_index_reg                <= cur_index_next;
        got_stop_reg                 <= got_stop_next;
        start_queue_ts_0_wr_ptr_reg  <= start_queue_ts_0_wr_ptr_next;
        start_queue_ts_0_rd_ptr_reg  <= start_queue_ts_0_rd_ptr_next;
        start_queue_ts_n_wr_ptr_reg  <= start_queue_ts_n_wr_ptr_next;
        start_queue_ts_n_rd_ptr_reg  <= start_queue_ts_n_rd_ptr_next;
        stop_queue_wr_ptr_reg        <= stop_queue_wr_ptr_next;
        stop_queue_rd_ptr_reg        <= stop_queue_rd_ptr_next;
        queue_ram_ptr_reg            <= queue_ram_ptr_next;
        m_axis_sched_ctrl_queue_reg  <= m_axis_sched_ctrl_queue_next;
        m_axis_sched_ctrl_enable_reg <= m_axis_sched_ctrl_enable_next;
        m_axis_sched_ctrl_valid_reg  <= m_axis_sched_ctrl_valid_next;
        inconsistent_reg             <= (inconsistent_reg && !clear_inconsistent) || set_inconsistent;

        if (start_queue_ts_0_wr_en) begin
            start_queue_ts_0_ram[start_queue_ts_0_wr_ptr_reg[QUEUE_INDEX_WIDTH-1:0]] <= start_queue_ts_0_wr_data;
        end
        if (start_queue_ts_n_wr_en) begin
            start_queue_ts_n_ram[start_queue_ts_n_wr_ptr_reg[QUEUE_INDEX_WIDTH-1:0]] <= start_queue_ts_n_wr_data;
        end
        if (stop_queue_wr_en) begin
            stop_queue_ram[stop_queue_wr_ptr_reg[QUEUE_INDEX_WIDTH-1:0]] <= stop_queue_wr_data;
        end
    end
end

// Lockstep stall-free AXI-Lite read/write interface supporting arbitrary PIPELINE >= 2
wire axil_rd_pipe_ready = !s_axil_rvalid_reg || s_axil_rready;

always @* begin
    queue_ram_axil_wr_en   = 1'b0;
    queue_ram_axil_rd_en   = 1'b0;
    queue_ram_axil_ptr     = {QUEUE_INDEX_WIDTH{1'b0}};
    queue_ram_axil_wr_data = {SEGMENT_COUNT{s_axil_wdata}};
    if (SEGMENT_COUNT > 1) begin
        queue_ram_axil_wr_be = s_axil_wstrb << (((s_axil_awaddr >> SEGMENT_SHIFT) & {SEG_SHIFT_W{1'b1}}) * AXIL_STRB_WIDTH);
    end else begin
        queue_ram_axil_wr_be = s_axil_wstrb;
    end

    set_inconsistent    = 1'b0;
    last_read_next      = last_read_reg;
    s_axil_awready_next = 1'b0;
    s_axil_wready_next  = 1'b0;
    s_axil_bvalid_next  = s_axil_bvalid_reg && !s_axil_bready;
    s_axil_arready_next = 1'b0;

    write_eligible = s_axil_awvalid && s_axil_wvalid && (!s_axil_bvalid || s_axil_bready) && (!s_axil_awready && !s_axil_wready);
    read_eligible  = s_axil_arvalid && axil_rd_pipe_ready && (!s_axil_arready);

    if (write_eligible && (!read_eligible || last_read_reg)) begin
        last_read_next       = 1'b0;
        s_axil_awready_next  = 1'b1;
        s_axil_wready_next   = 1'b1;
        s_axil_bvalid_next   = 1'b1;
        set_inconsistent     = 1'b1;
        queue_ram_axil_wr_en = 1'b1;
        queue_ram_axil_ptr   = s_axil_awaddr >> ADDR_SHIFT;
    end else if (read_eligible) begin
        last_read_next       = 1'b1;
        s_axil_arready_next  = 1'b1;
        queue_ram_axil_rd_en = 1'b1;
        queue_ram_axil_ptr   = s_axil_araddr >> ADDR_SHIFT;
    end
end

integer p;
always @(posedge clk) begin
    if (rst) begin
        last_read_reg                          <= 1'b0;
        s_axil_awready_reg                     <= 1'b0;
        s_axil_wready_reg                      <= 1'b0;
        s_axil_bvalid_reg                      <= 1'b0;
        s_axil_arready_reg                     <= 1'b0;
        s_axil_rdata_reg                       <= {AXIL_DATA_WIDTH{1'b0}};
        s_axil_rvalid_reg                      <= 1'b0;
        queue_ram_read_data_valid_pipeline_reg <= {PIPELINE{1'b0}};
        for (p = 0; p < PIPELINE; p = p + 1) begin
            queue_ram_read_data_pipeline_reg[p]       <= {QUEUE_RAM_WIDTH{1'b0}};
            queue_ram_read_data_shift_pipeline_reg[p] <= {SEG_SHIFT_W{1'b0}};
        end
    end else begin
        last_read_reg      <= last_read_next;
        s_axil_awready_reg <= s_axil_awready_next;
        s_axil_wready_reg  <= s_axil_wready_next;
        s_axil_bvalid_reg  <= s_axil_bvalid_next;
        s_axil_arready_reg <= s_axil_arready_next;

        if (axil_rd_pipe_ready) begin
            if (SEGMENT_COUNT > 1) begin
                s_axil_rdata_reg <= queue_ram_read_data_pipeline_reg[PIPELINE-1] >> (queue_ram_read_data_shift_pipeline_reg[PIPELINE-1] * AXIL_DATA_WIDTH);
            end else begin
                s_axil_rdata_reg <= queue_ram_read_data_pipeline_reg[PIPELINE-1];
            end
            s_axil_rvalid_reg <= queue_ram_read_data_valid_pipeline_reg[PIPELINE-1];

            for (p = PIPELINE - 1; p > 0; p = p - 1) begin
                queue_ram_read_data_pipeline_reg[p]       <= queue_ram_read_data_pipeline_reg[p-1];
                queue_ram_read_data_shift_pipeline_reg[p] <= queue_ram_read_data_shift_pipeline_reg[p-1];
                queue_ram_read_data_valid_pipeline_reg[p] <= queue_ram_read_data_valid_pipeline_reg[p-1];
            end
            queue_ram_read_data_valid_pipeline_reg[0] <= 1'b0;

            if (queue_ram_axil_rd_en) begin
                queue_ram_read_data_pipeline_reg[0] <= queue_ram[queue_ram_axil_ptr];
                if (SEGMENT_COUNT > 1) begin
                    queue_ram_read_data_shift_pipeline_reg[0] <= (s_axil_araddr >> SEGMENT_SHIFT) & {SEG_SHIFT_W{1'b1}};
                end else begin
                    queue_ram_read_data_shift_pipeline_reg[0] <= {SEG_SHIFT_W{1'b0}};
                end
                queue_ram_read_data_valid_pipeline_reg[0] <= 1'b1;
            end
        end

        if (queue_ram_axil_wr_en) begin
            for (i = 0; i < QUEUE_RAM_BE_WIDTH; i = i + 1) begin
                if (queue_ram_axil_wr_be[i]) begin
                    queue_ram[queue_ram_axil_ptr][WORD_SIZE*i +: WORD_SIZE] <= queue_ram_axil_wr_data[WORD_SIZE*i +: WORD_SIZE];
                end
            end
        end
    end
end

endmodule

`resetall
