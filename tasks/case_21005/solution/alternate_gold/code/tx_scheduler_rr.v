// SPDX-License-Identifier: BSD-2-Clause-Views
/*
 * Copyright (c) 2019-2023 The Regents of the University of California
 */

// Language: Verilog 2001

`resetall
`timescale 1ns / 1ps
`default_nettype none

/*
 * Transmit scheduler (round-robin) - Alternate Gold with dedicated completion/gate sideband pipelines
 */
module tx_scheduler_rr #
(
    parameter AXIL_DATA_WIDTH = 32,
    parameter AXIL_ADDR_WIDTH = 16,
    parameter AXIL_STRB_WIDTH = (AXIL_DATA_WIDTH/8),
    parameter LEN_WIDTH = 16,
    parameter REQ_TAG_WIDTH = 8,
    parameter OP_TABLE_SIZE = 16,
    parameter QUEUE_INDEX_WIDTH = 6,
    parameter PIPELINE = 2,
    parameter SCHED_CTRL_ENABLE = 0
)
(
    input  wire                          clk,
    input  wire                          rst,

    output wire [QUEUE_INDEX_WIDTH-1:0]  m_axis_tx_req_queue,
    output wire [REQ_TAG_WIDTH-1:0]      m_axis_tx_req_tag,
    output wire                          m_axis_tx_req_valid,
    input  wire                          m_axis_tx_req_ready,

    input  wire [LEN_WIDTH-1:0]          s_axis_tx_req_status_len,
    input  wire [REQ_TAG_WIDTH-1:0]      s_axis_tx_req_status_tag,
    input  wire                          s_axis_tx_req_status_valid,

    input  wire [QUEUE_INDEX_WIDTH-1:0]  s_axis_doorbell_queue,
    input  wire                          s_axis_doorbell_valid,

    input  wire [QUEUE_INDEX_WIDTH-1:0]  s_axis_sched_ctrl_queue,
    input  wire                          s_axis_sched_ctrl_enable,
    input  wire                          s_axis_sched_ctrl_valid,
    output wire                          s_axis_sched_ctrl_ready,

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

    input  wire                          enable,
    output wire                          active
);

parameter QUEUE_COUNT = 2**QUEUE_INDEX_WIDTH;
parameter CL_OP_TABLE_SIZE = $clog2(OP_TABLE_SIZE);
parameter QUEUE_RAM_BE_WIDTH = 2;
parameter QUEUE_RAM_WIDTH = QUEUE_RAM_BE_WIDTH*8;

reg op_axil_write_pipe_hazard;
reg op_axil_read_pipe_hazard;
reg op_doorbell_pipe_hazard;
reg op_req_pipe_hazard;
reg op_complete_pipe_hazard;
reg op_ctrl_pipe_hazard;
reg op_internal_pipe_hazard;
reg stage_active;

reg [PIPELINE-1:0] op_axil_write_pipe_reg = {PIPELINE{1'b0}}, op_axil_write_pipe_next;
reg [PIPELINE-1:0] op_axil_read_pipe_reg  = {PIPELINE{1'b0}}, op_axil_read_pipe_next;
reg [PIPELINE-1:0] op_doorbell_pipe_reg   = {PIPELINE{1'b0}}, op_doorbell_pipe_next;
reg [PIPELINE-1:0] op_req_pipe_reg        = {PIPELINE{1'b0}}, op_req_pipe_next;
reg [PIPELINE-1:0] op_complete_pipe_reg   = {PIPELINE{1'b0}}, op_complete_pipe_next;
reg [PIPELINE-1:0] op_ctrl_pipe_reg       = {PIPELINE{1'b0}}, op_ctrl_pipe_next;
reg [PIPELINE-1:0] op_internal_pipe_reg   = {PIPELINE{1'b0}}, op_internal_pipe_next;

// Dedicated sideband vectors for completion-remaining-work and TDMA gate-enable
reg [PIPELINE-1:0] comp_more_pipe_reg = {PIPELINE{1'b0}}, comp_more_pipe_next;
reg [PIPELINE-1:0] gate_en_pipe_reg   = {PIPELINE{1'b0}}, gate_en_pipe_next;

reg [QUEUE_INDEX_WIDTH-1:0] queue_ram_addr_pipeline_reg[PIPELINE-1:0], queue_ram_addr_pipeline_next[PIPELINE-1:0];
reg [AXIL_DATA_WIDTH-1:0]   write_data_pipeline_reg[PIPELINE-1:0], write_data_pipeline_next[PIPELINE-1:0];
reg [AXIL_STRB_WIDTH-1:0]   write_strobe_pipeline_reg[PIPELINE-1:0], write_strobe_pipeline_next[PIPELINE-1:0];
reg [CL_OP_TABLE_SIZE-1:0]  op_index_pipeline_reg[PIPELINE-1:0], op_index_pipeline_next[PIPELINE-1:0];

reg [QUEUE_INDEX_WIDTH-1:0] m_axis_tx_req_queue_reg = {QUEUE_INDEX_WIDTH{1'b0}}, m_axis_tx_req_queue_next;
reg [REQ_TAG_WIDTH-1:0]     m_axis_tx_req_tag_reg   = {REQ_TAG_WIDTH{1'b0}}, m_axis_tx_req_tag_next;
reg                         m_axis_tx_req_valid_reg = 1'b0, m_axis_tx_req_valid_next;

reg s_axis_sched_ctrl_ready_reg = 1'b0, s_axis_sched_ctrl_ready_next;

reg                       s_axil_awready_reg = 1'b0, s_axil_awready_next;
reg                       s_axil_wready_reg  = 1'b0, s_axil_wready_next;
reg                       s_axil_bvalid_reg  = 1'b0, s_axil_bvalid_next;
reg                       s_axil_arready_reg = 1'b0, s_axil_arready_next;
reg [AXIL_DATA_WIDTH-1:0] s_axil_rdata_reg   = 0, s_axil_rdata_next;
reg                       s_axil_rvalid_reg  = 1'b0, s_axil_rvalid_next;

reg [QUEUE_RAM_WIDTH-1:0]    queue_ram[QUEUE_COUNT-1:0];
reg [QUEUE_INDEX_WIDTH-1:0]  queue_ram_read_ptr;
reg [QUEUE_INDEX_WIDTH-1:0]  queue_ram_write_ptr;
reg [QUEUE_RAM_WIDTH-1:0]    queue_ram_write_data;
reg                          queue_ram_wr_en;
reg [QUEUE_RAM_BE_WIDTH-1:0] queue_ram_be;
reg [QUEUE_RAM_WIDTH-1:0]    queue_ram_read_data_reg = 0;
reg [QUEUE_RAM_WIDTH-1:0]    queue_ram_read_data_pipeline_reg[PIPELINE-1:1];

wire                        q_enabled       = queue_ram_read_data_pipeline_reg[PIPELINE-1][0];
wire                        q_global_enable = queue_ram_read_data_pipeline_reg[PIPELINE-1][1];
wire                        q_sched_enable  = queue_ram_read_data_pipeline_reg[PIPELINE-1][2];
wire                        q_active        = queue_ram_read_data_pipeline_reg[PIPELINE-1][6];
wire                        q_scheduled     = queue_ram_read_data_pipeline_reg[PIPELINE-1][7];
wire [CL_OP_TABLE_SIZE-1:0] q_tail_idx      = queue_ram_read_data_pipeline_reg[PIPELINE-1][15:8];

wire q_gate_open     = (!SCHED_CTRL_ENABLE) || q_global_enable || q_sched_enable;
wire q_can_schedule  = q_enabled && q_gate_open && !q_scheduled;

reg [OP_TABLE_SIZE-1:0]     op_table_active = 0;
reg [QUEUE_INDEX_WIDTH-1:0] op_table_queue[OP_TABLE_SIZE-1:0];
reg                         op_table_doorbell[OP_TABLE_SIZE-1:0];
reg                         op_table_is_head[OP_TABLE_SIZE-1:0];
reg [CL_OP_TABLE_SIZE-1:0]  op_table_next_index[OP_TABLE_SIZE-1:0];
reg [CL_OP_TABLE_SIZE-1:0]  op_table_prev_index[OP_TABLE_SIZE-1:0];
wire [CL_OP_TABLE_SIZE-1:0] op_table_start_ptr;
wire                        op_table_start_ptr_valid;
reg [QUEUE_INDEX_WIDTH-1:0] op_table_start_queue;
reg                         op_table_start_en;
reg [CL_OP_TABLE_SIZE-1:0]  op_table_doorbell_ptr;
reg                         op_table_doorbell_en;
reg [CL_OP_TABLE_SIZE-1:0]  op_table_release_ptr;
reg                         op_table_release_en;
reg [CL_OP_TABLE_SIZE-1:0]  op_table_update_next_ptr;
reg [CL_OP_TABLE_SIZE-1:0]  op_table_update_next_index;
reg                         op_table_update_next_en;
reg [CL_OP_TABLE_SIZE-1:0]  op_table_update_prev_ptr;
reg [CL_OP_TABLE_SIZE-1:0]  op_table_update_prev_index;
reg                         op_table_update_prev_is_head;
reg                         op_table_update_prev_en;

reg [CL_OP_TABLE_SIZE:0] finish_fifo_wr_ptr_reg = 0, finish_fifo_wr_ptr_next;
reg [CL_OP_TABLE_SIZE:0] finish_fifo_rd_ptr_reg = 0, finish_fifo_rd_ptr_next;
reg [REQ_TAG_WIDTH-1:0]  finish_fifo_tag[(2**CL_OP_TABLE_SIZE)-1:0];
reg                      finish_fifo_status[(2**CL_OP_TABLE_SIZE)-1:0];
reg                      finish_fifo_we;
reg [REQ_TAG_WIDTH-1:0]  finish_fifo_wr_tag;
reg                      finish_fifo_wr_status;

reg [CL_OP_TABLE_SIZE-1:0] finish_ptr_reg    = 0, finish_ptr_next;
reg                        finish_status_reg = 1'b0, finish_status_next;
reg                        finish_valid_reg  = 1'b0, finish_valid_next;

reg                         init_reg       = 1'b0, init_next;
reg [QUEUE_INDEX_WIDTH-1:0] init_index_reg = 0, init_index_next;
reg [QUEUE_INDEX_WIDTH:0]   active_queue_count_reg = 0, active_queue_count_next;

assign m_axis_tx_req_queue     = m_axis_tx_req_queue_reg;
assign m_axis_tx_req_tag       = m_axis_tx_req_tag_reg;
assign m_axis_tx_req_valid     = m_axis_tx_req_valid_reg;
assign s_axis_sched_ctrl_ready = s_axis_sched_ctrl_ready_reg;

assign s_axil_awready = s_axil_awready_reg;
assign s_axil_wready  = s_axil_wready_reg;
assign s_axil_bresp   = 2'b00;
assign s_axil_bvalid  = s_axil_bvalid_reg;
assign s_axil_arready = s_axil_arready_reg;
assign s_axil_rdata   = s_axil_rdata_reg;
assign s_axil_rresp   = 2'b00;
assign s_axil_rvalid  = s_axil_rvalid_reg;
assign active         = active_queue_count_reg != 0;

wire [QUEUE_INDEX_WIDTH-1:0] s_axil_awaddr_queue = s_axil_awaddr >> 2;
wire [QUEUE_INDEX_WIDTH-1:0] s_axil_araddr_queue = s_axil_araddr >> 2;
wire queue_tail_active = op_table_active[q_tail_idx] && (op_table_queue[q_tail_idx] == queue_ram_addr_pipeline_reg[PIPELINE-1]);

wire [QUEUE_INDEX_WIDTH-1:0] axis_doorbell_fifo_queue;
wire                         axis_doorbell_fifo_valid;
reg                          axis_doorbell_fifo_ready;

axis_fifo #(
    .DEPTH(256),
    .DATA_WIDTH(QUEUE_INDEX_WIDTH),
    .KEEP_ENABLE(0),
    .KEEP_WIDTH(1),
    .LAST_ENABLE(0),
    .ID_ENABLE(0),
    .DEST_ENABLE(0),
    .USER_ENABLE(0),
    .FRAME_FIFO(0)
)
doorbell_fifo (
    .clk(clk),
    .rst(rst),
    .s_axis_tdata(s_axis_doorbell_queue),
    .s_axis_tkeep(0),
    .s_axis_tvalid(s_axis_doorbell_valid),
    .s_axis_tready(),
    .s_axis_tlast(0),
    .s_axis_tid(0),
    .s_axis_tdest(0),
    .s_axis_tuser(0),
    .m_axis_tdata(axis_doorbell_fifo_queue),
    .m_axis_tkeep(),
    .m_axis_tvalid(axis_doorbell_fifo_valid),
    .m_axis_tready(axis_doorbell_fifo_ready),
    .m_axis_tlast(),
    .m_axis_tid(),
    .m_axis_tdest(),
    .m_axis_tuser(),
    .status_overflow(),
    .status_bad_frame(),
    .status_good_frame()
);

reg  [QUEUE_INDEX_WIDTH-1:0] axis_scheduler_fifo_in_queue;
reg                          axis_scheduler_fifo_in_valid;
wire                         axis_scheduler_fifo_in_ready;
wire [QUEUE_INDEX_WIDTH-1:0] axis_scheduler_fifo_out_queue;
wire                         axis_scheduler_fifo_out_valid;
reg                          axis_scheduler_fifo_out_ready;

axis_fifo #(
    .DEPTH(2**QUEUE_INDEX_WIDTH),
    .DATA_WIDTH(QUEUE_INDEX_WIDTH),
    .KEEP_ENABLE(0),
    .KEEP_WIDTH(1),
    .LAST_ENABLE(0),
    .ID_ENABLE(0),
    .DEST_ENABLE(0),
    .USER_ENABLE(0),
    .FRAME_FIFO(0)
)
rr_fifo (
    .clk(clk),
    .rst(rst),
    .s_axis_tdata(axis_scheduler_fifo_in_queue),
    .s_axis_tkeep(0),
    .s_axis_tvalid(axis_scheduler_fifo_in_valid),
    .s_axis_tready(axis_scheduler_fifo_in_ready),
    .s_axis_tlast(0),
    .s_axis_tid(0),
    .s_axis_tdest(0),
    .s_axis_tuser(0),
    .m_axis_tdata(axis_scheduler_fifo_out_queue),
    .m_axis_tkeep(),
    .m_axis_tvalid(axis_scheduler_fifo_out_valid),
    .m_axis_tready(axis_scheduler_fifo_out_ready),
    .m_axis_tlast(),
    .m_axis_tid(),
    .m_axis_tdest(),
    .m_axis_tuser(),
    .status_overflow(),
    .status_bad_frame(),
    .status_good_frame()
);

priority_encoder #(
    .WIDTH(OP_TABLE_SIZE),
    .LSB_HIGH_PRIORITY(1)
)
op_table_start_enc_inst (
    .input_unencoded(~op_table_active),
    .output_valid(op_table_start_ptr_valid),
    .output_encoded(op_table_start_ptr),
    .output_unencoded()
);

integer i, j;
initial begin
    for (i = 0; i < 2**QUEUE_INDEX_WIDTH; i = i + 2**(QUEUE_INDEX_WIDTH/2)) begin
        for (j = i; j < i + 2**(QUEUE_INDEX_WIDTH/2); j = j + 1) begin
            queue_ram[j] = 0;
        end
    end
    for (i = 0; i < OP_TABLE_SIZE; i = i + 1) begin
        op_table_queue[i]      = 0;
        op_table_next_index[i] = 0;
        op_table_prev_index[i] = 0;
        op_table_doorbell[i]   = 0;
        op_table_is_head[i]    = 0;
    end
end

always @* begin
    op_axil_write_pipe_next = {op_axil_write_pipe_reg, 1'b0};
    op_axil_read_pipe_next  = {op_axil_read_pipe_reg,  1'b0};
    op_doorbell_pipe_next   = {op_doorbell_pipe_reg,   1'b0};
    op_req_pipe_next        = {op_req_pipe_reg,        1'b0};
    op_complete_pipe_next   = {op_complete_pipe_reg,   1'b0};
    op_ctrl_pipe_next       = {op_ctrl_pipe_reg,       1'b0};
    op_internal_pipe_next   = {op_internal_pipe_reg,   1'b0};
    comp_more_pipe_next     = {comp_more_pipe_reg,     1'b0};
    gate_en_pipe_next       = {gate_en_pipe_reg,       1'b0};

    queue_ram_addr_pipeline_next[0] = 0;
    write_data_pipeline_next[0]     = 0;
    write_strobe_pipeline_next[0]   = 0;
    op_index_pipeline_next[0]       = 0;
    for (j = 1; j < PIPELINE; j = j + 1) begin
        queue_ram_addr_pipeline_next[j] = queue_ram_addr_pipeline_reg[j-1];
        write_data_pipeline_next[j]     = write_data_pipeline_reg[j-1];
        write_strobe_pipeline_next[j]   = write_strobe_pipeline_reg[j-1];
        op_index_pipeline_next[j]       = op_index_pipeline_reg[j-1];
    end

    m_axis_tx_req_queue_next     = m_axis_tx_req_queue_reg;
    m_axis_tx_req_tag_next       = m_axis_tx_req_tag_reg;
    m_axis_tx_req_valid_next     = m_axis_tx_req_valid_reg && !m_axis_tx_req_ready;
    s_axis_sched_ctrl_ready_next = 1'b0;

    s_axil_awready_next = 1'b0;
    s_axil_wready_next  = 1'b0;
    s_axil_bvalid_next  = s_axil_bvalid_reg && !s_axil_bready;
    s_axil_arready_next = 1'b0;
    s_axil_rdata_next   = s_axil_rdata_reg;
    s_axil_rvalid_next  = s_axil_rvalid_reg && !s_axil_rready;

    queue_ram_read_ptr   = 0;
    queue_ram_write_ptr  = queue_ram_addr_pipeline_reg[PIPELINE-1];
    queue_ram_write_data = queue_ram_read_data_pipeline_reg[PIPELINE-1];
    queue_ram_wr_en      = 1'b0;
    queue_ram_be         = 0;

    op_table_start_queue         = queue_ram_addr_pipeline_reg[PIPELINE-1];
    op_table_start_en            = 1'b0;
    op_table_doorbell_ptr        = q_tail_idx;
    op_table_doorbell_en         = 1'b0;
    op_table_release_ptr         = op_index_pipeline_reg[PIPELINE-1];
    op_table_release_en          = 1'b0;
    op_table_update_next_ptr     = q_tail_idx;
    op_table_update_next_index   = op_index_pipeline_reg[PIPELINE-1];
    op_table_update_next_en      = 1'b0;
    op_table_update_prev_ptr     = op_index_pipeline_reg[PIPELINE-1];
    op_table_update_prev_index   = q_tail_idx;
    op_table_update_prev_is_head = !(queue_tail_active && op_index_pipeline_reg[PIPELINE-1] != q_tail_idx);
    op_table_update_prev_en      = 1'b0;

    finish_fifo_rd_ptr_next = finish_fifo_rd_ptr_reg;
    finish_fifo_wr_ptr_next = finish_fifo_wr_ptr_reg;
    finish_fifo_we          = 1'b0;
    finish_fifo_wr_tag      = s_axis_tx_req_status_tag;
    finish_fifo_wr_status   = s_axis_tx_req_status_len != 0;

    finish_ptr_next    = finish_ptr_reg;
    finish_status_next = finish_status_reg;
    finish_valid_next  = finish_valid_reg;

    init_next               = init_reg;
    init_index_next         = init_index_reg;
    active_queue_count_next = active_queue_count_reg;

    axis_doorbell_fifo_ready      = 1'b0;
    axis_scheduler_fifo_in_queue  = queue_ram_addr_pipeline_reg[PIPELINE-1];
    axis_scheduler_fifo_in_valid  = 1'b0;
    axis_scheduler_fifo_out_ready = 1'b0;

    op_axil_write_pipe_hazard = 1'b0;
    op_axil_read_pipe_hazard  = 1'b0;
    op_doorbell_pipe_hazard   = 1'b0;
    op_req_pipe_hazard        = 1'b0;
    op_complete_pipe_hazard   = 1'b0;
    op_ctrl_pipe_hazard       = 1'b0;
    op_internal_pipe_hazard   = 1'b0;
    stage_active              = 1'b0;

    for (j = 0; j < PIPELINE; j = j + 1) begin
        stage_active = op_axil_write_pipe_reg[j] || op_axil_read_pipe_reg[j] || op_doorbell_pipe_reg[j] ||
                       op_req_pipe_reg[j] || op_complete_pipe_reg[j] || op_ctrl_pipe_reg[j] || op_internal_pipe_reg[j];
        op_axil_write_pipe_hazard = op_axil_write_pipe_hazard || (stage_active && queue_ram_addr_pipeline_reg[j] == s_axil_awaddr_queue);
        op_axil_read_pipe_hazard  = op_axil_read_pipe_hazard  || (stage_active && queue_ram_addr_pipeline_reg[j] == s_axil_araddr_queue);
        op_doorbell_pipe_hazard   = op_doorbell_pipe_hazard   || (stage_active && queue_ram_addr_pipeline_reg[j] == axis_doorbell_fifo_queue);
        op_req_pipe_hazard        = op_req_pipe_hazard        || (stage_active && queue_ram_addr_pipeline_reg[j] == axis_scheduler_fifo_out_queue);
        op_complete_pipe_hazard   = op_complete_pipe_hazard   || (stage_active && queue_ram_addr_pipeline_reg[j] == op_table_queue[finish_ptr_reg]);
        op_ctrl_pipe_hazard       = op_ctrl_pipe_hazard       || (stage_active && queue_ram_addr_pipeline_reg[j] == s_axis_sched_ctrl_queue);
        op_internal_pipe_hazard   = op_internal_pipe_hazard   || (stage_active && queue_ram_addr_pipeline_reg[j] == init_index_reg);
    end

    // Stage 0 arbitrated request intake
    if (!init_reg && !op_internal_pipe_hazard) begin
        op_internal_pipe_next[0]        = 1'b1;
        init_index_next                 = init_index_reg + 1'b1;
        queue_ram_read_ptr              = init_index_reg;
        queue_ram_addr_pipeline_next[0] = init_index_reg;
        if (init_index_reg == {QUEUE_INDEX_WIDTH{1'b1}}) begin
            init_next = 1'b1;
        end
    end else if (s_axil_awvalid && s_axil_wvalid && (!s_axil_bvalid || s_axil_bready) && !op_axil_write_pipe_reg && !op_axil_write_pipe_hazard) begin
        op_axil_write_pipe_next[0]      = 1'b1;
        s_axil_awready_next             = 1'b1;
        s_axil_wready_next              = 1'b1;
        write_data_pipeline_next[0]     = s_axil_wdata;
        write_strobe_pipeline_next[0]   = s_axil_wstrb;
        queue_ram_read_ptr              = s_axil_awaddr_queue;
        queue_ram_addr_pipeline_next[0] = s_axil_awaddr_queue;
    end else if (s_axil_arvalid && (!s_axil_rvalid || s_axil_rready) && !op_axil_read_pipe_reg && !op_axil_read_pipe_hazard) begin
        op_axil_read_pipe_next[0]       = 1'b1;
        s_axil_arready_next             = 1'b1;
        queue_ram_read_ptr              = s_axil_araddr_queue;
        queue_ram_addr_pipeline_next[0] = s_axil_araddr_queue;
    end else if (axis_doorbell_fifo_valid && !op_doorbell_pipe_hazard) begin
        op_doorbell_pipe_next[0]        = 1'b1;
        axis_doorbell_fifo_ready        = 1'b1;
        queue_ram_read_ptr              = axis_doorbell_fifo_queue;
        queue_ram_addr_pipeline_next[0] = axis_doorbell_fifo_queue;
    end else if (finish_valid_reg && !op_complete_pipe_reg[0] && !op_complete_pipe_hazard) begin
        op_complete_pipe_next[0]        = 1'b1;
        comp_more_pipe_next[0]          = finish_status_reg || op_table_doorbell[finish_ptr_reg];
        op_index_pipeline_next[0]       = finish_ptr_reg;
        finish_valid_next               = 1'b0;
        queue_ram_read_ptr              = op_table_queue[finish_ptr_reg];
        queue_ram_addr_pipeline_next[0] = op_table_queue[finish_ptr_reg];
    end else if (SCHED_CTRL_ENABLE && s_axis_sched_ctrl_valid && !op_ctrl_pipe_reg[0] && !op_ctrl_pipe_hazard) begin
        op_ctrl_pipe_next[0]            = 1'b1;
        s_axis_sched_ctrl_ready_next    = 1'b1;
        gate_en_pipe_next[0]            = s_axis_sched_ctrl_enable;
        queue_ram_read_ptr              = s_axis_sched_ctrl_queue;
        queue_ram_addr_pipeline_next[0] = s_axis_sched_ctrl_queue;
    end else if (enable && op_table_start_ptr_valid && axis_scheduler_fifo_out_valid && (!m_axis_tx_req_valid || m_axis_tx_req_ready) && !op_req_pipe_reg && !op_req_pipe_hazard) begin
        op_req_pipe_next[0]             = 1'b1;
        op_table_start_en               = 1'b1;
        op_table_start_queue            = axis_scheduler_fifo_out_queue;
        op_index_pipeline_next[0]       = op_table_start_ptr;
        axis_scheduler_fifo_out_ready   = 1'b1;
        queue_ram_read_ptr              = axis_scheduler_fifo_out_queue;
        queue_ram_addr_pipeline_next[0] = axis_scheduler_fifo_out_queue;
    end

    // Stage PIPELINE-1 writeback & scheduling decision
    if (op_internal_pipe_reg[PIPELINE-1]) begin
        queue_ram_write_ptr  = queue_ram_addr_pipeline_reg[PIPELINE-1];
        queue_ram_write_data = {QUEUE_RAM_WIDTH{1'b0}};
        queue_ram_be         = {QUEUE_RAM_BE_WIDTH{1'b1}};
        queue_ram_wr_en      = 1'b1;
    end else if (op_doorbell_pipe_reg[PIPELINE-1]) begin
        queue_ram_write_ptr     = queue_ram_addr_pipeline_reg[PIPELINE-1];
        queue_ram_write_data[6] = 1'b1;
        queue_ram_be[0]         = 1'b1;
        queue_ram_wr_en         = 1'b1;

        if (q_can_schedule) begin
            queue_ram_write_data[7]      = 1'b1;
            axis_scheduler_fifo_in_queue = queue_ram_addr_pipeline_reg[PIPELINE-1];
            axis_scheduler_fifo_in_valid = 1'b1;
            active_queue_count_next      = active_queue_count_reg + 1'b1;
        end
        if (queue_tail_active) begin
            op_table_doorbell_ptr = q_tail_idx;
            op_table_doorbell_en  = 1'b1;
        end
    end else if (op_req_pipe_reg[PIPELINE-1]) begin
        m_axis_tx_req_queue_next     = queue_ram_addr_pipeline_reg[PIPELINE-1];
        m_axis_tx_req_tag_next       = op_index_pipeline_reg[PIPELINE-1];
        axis_scheduler_fifo_in_queue = queue_ram_addr_pipeline_reg[PIPELINE-1];

        queue_ram_write_ptr        = queue_ram_addr_pipeline_reg[PIPELINE-1];
        queue_ram_write_data[15:8] = op_index_pipeline_reg[PIPELINE-1];
        queue_ram_be[0]            = 1'b1;
        queue_ram_wr_en            = 1'b1;

        op_table_update_prev_ptr     = op_index_pipeline_reg[PIPELINE-1];
        op_table_update_prev_index   = q_tail_idx;
        op_table_update_prev_is_head = !(queue_tail_active && op_index_pipeline_reg[PIPELINE-1] != q_tail_idx);
        op_table_update_next_ptr     = q_tail_idx;
        op_table_update_next_index   = op_index_pipeline_reg[PIPELINE-1];

        if (q_enabled && q_gate_open && q_active && q_scheduled) begin
            m_axis_tx_req_valid_next     = 1'b1;
            axis_scheduler_fifo_in_valid = 1'b1;
            queue_ram_write_data[7]      = 1'b1;
            queue_ram_be[1]              = 1'b1;
            op_table_update_prev_en      = 1'b1;
            op_table_update_next_en      = queue_tail_active && (op_index_pipeline_reg[PIPELINE-1] != q_tail_idx);
        end else begin
            op_table_release_ptr    = op_index_pipeline_reg[PIPELINE-1];
            op_table_release_en     = 1'b1;
            queue_ram_write_data[7] = 1'b0;
            if (q_scheduled) begin
                active_queue_count_next = active_queue_count_reg - 1'b1;
            end
        end
    end else if (op_complete_pipe_reg[PIPELINE-1]) begin
        queue_ram_write_ptr = queue_ram_addr_pipeline_reg[PIPELINE-1];
        queue_ram_be[0]     = 1'b1;
        queue_ram_wr_en     = 1'b1;

        op_table_update_prev_ptr     = op_table_next_index[op_index_pipeline_reg[PIPELINE-1]];
        op_table_update_prev_index   = op_table_prev_index[op_index_pipeline_reg[PIPELINE-1]];
        op_table_update_prev_is_head = op_table_is_head[op_index_pipeline_reg[PIPELINE-1]];
        op_table_update_prev_en      = op_index_pipeline_reg[PIPELINE-1] != q_tail_idx;

        op_table_update_next_ptr   = op_table_prev_index[op_index_pipeline_reg[PIPELINE-1]];
        op_table_update_next_index = op_table_next_index[op_index_pipeline_reg[PIPELINE-1]];
        op_table_update_next_en    = !op_table_is_head[op_index_pipeline_reg[PIPELINE-1]];

        op_table_doorbell_ptr = op_table_prev_index[op_index_pipeline_reg[PIPELINE-1]];
        op_table_doorbell_en  = !op_table_is_head[op_index_pipeline_reg[PIPELINE-1]] && op_table_doorbell[op_index_pipeline_reg[PIPELINE-1]];

        op_table_release_ptr = op_index_pipeline_reg[PIPELINE-1];
        op_table_release_en  = 1'b1;

        if (comp_more_pipe_reg[PIPELINE-1]) begin
            queue_ram_write_data[6] = 1'b1;
            if (q_can_schedule) begin
                queue_ram_write_data[7]      = 1'b1;
                axis_scheduler_fifo_in_queue = queue_ram_addr_pipeline_reg[PIPELINE-1];
                axis_scheduler_fifo_in_valid = 1'b1;
                active_queue_count_next      = active_queue_count_reg + 1'b1;
            end
        end else begin
            queue_ram_write_data[6] = 1'b0;
        end
    end else if (SCHED_CTRL_ENABLE && op_ctrl_pipe_reg[PIPELINE-1]) begin
        queue_ram_write_ptr     = queue_ram_addr_pipeline_reg[PIPELINE-1];
        queue_ram_wr_en         = 1'b1;
        queue_ram_write_data[2] = gate_en_pipe_reg[PIPELINE-1];
        queue_ram_be[0]         = 1'b1;

        if (q_enabled && q_active && (q_global_enable || gate_en_pipe_reg[PIPELINE-1]) && !q_scheduled) begin
            queue_ram_write_data[7]      = 1'b1;
            axis_scheduler_fifo_in_queue = queue_ram_addr_pipeline_reg[PIPELINE-1];
            axis_scheduler_fifo_in_valid = 1'b1;
            active_queue_count_next      = active_queue_count_reg + 1'b1;
        end
    end else if (op_axil_write_pipe_reg[PIPELINE-1]) begin
        s_axil_bvalid_next      = 1'b1;
        queue_ram_write_ptr     = queue_ram_addr_pipeline_reg[PIPELINE-1];
        queue_ram_wr_en         = 1'b1;
        queue_ram_write_data[0] = write_data_pipeline_reg[PIPELINE-1][0];
        queue_ram_write_data[1] = write_data_pipeline_reg[PIPELINE-1][1];
        queue_ram_be[0]         = write_strobe_pipeline_reg[PIPELINE-1][0];

        if ((write_strobe_pipeline_reg[PIPELINE-1][0] ? write_data_pipeline_reg[PIPELINE-1][0] : q_enabled) &&
            q_active &&
            (!SCHED_CTRL_ENABLE || (write_strobe_pipeline_reg[PIPELINE-1][0] ? write_data_pipeline_reg[PIPELINE-1][1] : q_global_enable) || q_sched_enable) &&
            !q_scheduled) begin
            queue_ram_write_data[7]      = 1'b1;
            axis_scheduler_fifo_in_queue = queue_ram_addr_pipeline_reg[PIPELINE-1];
            axis_scheduler_fifo_in_valid = 1'b1;
            active_queue_count_next      = active_queue_count_reg + 1'b1;
        end
    end else if (op_axil_read_pipe_reg[PIPELINE-1]) begin
        s_axil_rvalid_next    = 1'b1;
        s_axil_rdata_next     = 0;
        s_axil_rdata_next[0]  = q_enabled;
        if (SCHED_CTRL_ENABLE) begin
            s_axil_rdata_next[1] = q_global_enable;
            s_axil_rdata_next[2] = q_sched_enable;
        end
        s_axil_rdata_next[16] = q_active;
        s_axil_rdata_next[24] = q_scheduled;
    end

    if (s_axis_tx_req_status_valid) begin
        finish_fifo_we          = 1'b1;
        finish_fifo_wr_tag      = s_axis_tx_req_status_tag;
        finish_fifo_wr_status   = s_axis_tx_req_status_len != 0;
        finish_fifo_wr_ptr_next = finish_fifo_wr_ptr_reg + 1'b1;
    end

    if (!finish_valid_reg && finish_fifo_wr_ptr_reg != finish_fifo_rd_ptr_reg) begin
        finish_ptr_next         = finish_fifo_tag[finish_fifo_rd_ptr_reg[CL_OP_TABLE_SIZE-1:0]];
        finish_status_next      = finish_fifo_status[finish_fifo_rd_ptr_reg[CL_OP_TABLE_SIZE-1:0]];
        finish_valid_next       = 1'b1;
        finish_fifo_rd_ptr_next = finish_fifo_rd_ptr_reg + 1'b1;
    end
end

always @(posedge clk) begin
    if (rst) begin
        op_axil_write_pipe_reg      <= {PIPELINE{1'b0}};
        op_axil_read_pipe_reg       <= {PIPELINE{1'b0}};
        op_doorbell_pipe_reg        <= {PIPELINE{1'b0}};
        op_req_pipe_reg             <= {PIPELINE{1'b0}};
        op_complete_pipe_reg        <= {PIPELINE{1'b0}};
        op_ctrl_pipe_reg            <= {PIPELINE{1'b0}};
        op_internal_pipe_reg        <= {PIPELINE{1'b0}};
        comp_more_pipe_reg          <= {PIPELINE{1'b0}};
        gate_en_pipe_reg            <= {PIPELINE{1'b0}};
        finish_fifo_rd_ptr_reg      <= {CL_OP_TABLE_SIZE+1{1'b0}};
        finish_fifo_wr_ptr_reg      <= {CL_OP_TABLE_SIZE+1{1'b0}};
        finish_valid_reg            <= 1'b0;
        finish_ptr_reg              <= {CL_OP_TABLE_SIZE{1'b0}};
        finish_status_reg           <= 1'b0;
        m_axis_tx_req_valid_reg     <= 1'b0;
        m_axis_tx_req_queue_reg     <= {QUEUE_INDEX_WIDTH{1'b0}};
        m_axis_tx_req_tag_reg       <= {REQ_TAG_WIDTH{1'b0}};
        s_axis_sched_ctrl_ready_reg <= 1'b0;
        s_axil_awready_reg          <= 1'b0;
        s_axil_wready_reg           <= 1'b0;
        s_axil_bvalid_reg           <= 1'b0;
        s_axil_arready_reg          <= 1'b0;
        s_axil_rvalid_reg           <= 1'b0;
        s_axil_rdata_reg            <= {AXIL_DATA_WIDTH{1'b0}};
        init_reg                    <= 1'b0;
        init_index_reg              <= 0;
        active_queue_count_reg      <= 0;
        op_table_active             <= 0;
        queue_ram_read_data_reg     <= {QUEUE_RAM_WIDTH{1'b0}};
        for (i = 0; i < PIPELINE; i = i + 1) begin
            queue_ram_addr_pipeline_reg[i] <= {QUEUE_INDEX_WIDTH{1'b0}};
            write_data_pipeline_reg[i]     <= {AXIL_DATA_WIDTH{1'b0}};
            write_strobe_pipeline_reg[i]   <= {AXIL_STRB_WIDTH{1'b0}};
            op_index_pipeline_reg[i]       <= {CL_OP_TABLE_SIZE{1'b0}};
        end
        for (i = 1; i < PIPELINE; i = i + 1) begin
            queue_ram_read_data_pipeline_reg[i] <= {QUEUE_RAM_WIDTH{1'b0}};
        end
    end else begin
        op_axil_write_pipe_reg      <= op_axil_write_pipe_next;
        op_axil_read_pipe_reg       <= op_axil_read_pipe_next;
        op_doorbell_pipe_reg        <= op_doorbell_pipe_next;
        op_req_pipe_reg             <= op_req_pipe_next;
        op_complete_pipe_reg        <= op_complete_pipe_next;
        op_ctrl_pipe_reg            <= op_ctrl_pipe_next;
        op_internal_pipe_reg        <= op_internal_pipe_next;
        comp_more_pipe_reg          <= comp_more_pipe_next;
        gate_en_pipe_reg            <= gate_en_pipe_next;
        finish_fifo_rd_ptr_reg      <= finish_fifo_rd_ptr_next;
        finish_fifo_wr_ptr_reg      <= finish_fifo_wr_ptr_next;
        finish_valid_reg            <= finish_valid_next;
        finish_ptr_reg              <= finish_ptr_next;
        finish_status_reg           <= finish_status_next;
        m_axis_tx_req_valid_reg     <= m_axis_tx_req_valid_next;
        m_axis_tx_req_queue_reg     <= m_axis_tx_req_queue_next;
        m_axis_tx_req_tag_reg       <= m_axis_tx_req_tag_next;
        s_axis_sched_ctrl_ready_reg <= s_axis_sched_ctrl_ready_next;
        s_axil_awready_reg          <= s_axil_awready_next;
        s_axil_wready_reg           <= s_axil_wready_next;
        s_axil_bvalid_reg           <= s_axil_bvalid_next;
        s_axil_arready_reg          <= s_axil_arready_next;
        s_axil_rvalid_reg           <= s_axil_rvalid_next;
        s_axil_rdata_reg            <= s_axil_rdata_next;
        init_reg                    <= init_next;
        init_index_reg              <= init_index_next;
        active_queue_count_reg      <= active_queue_count_next;

        for (i = 0; i < PIPELINE; i = i + 1) begin
            queue_ram_addr_pipeline_reg[i] <= queue_ram_addr_pipeline_next[i];
            write_data_pipeline_reg[i]     <= write_data_pipeline_next[i];
            write_strobe_pipeline_reg[i]   <= write_strobe_pipeline_next[i];
            op_index_pipeline_reg[i]       <= op_index_pipeline_next[i];
        end

        if (op_table_start_en) begin
            op_table_active[op_table_start_ptr] <= 1'b1;
        end
        if (op_table_release_en) begin
            op_table_active[op_table_release_ptr] <= 1'b0;
        end

        queue_ram_read_data_reg <= queue_ram[queue_ram_read_ptr];
        queue_ram_read_data_pipeline_reg[1] <= queue_ram_read_data_reg;
        for (i = 2; i < PIPELINE; i = i + 1) begin
            queue_ram_read_data_pipeline_reg[i] <= queue_ram_read_data_pipeline_reg[i-1];
        end
    end

    if (queue_ram_wr_en) begin
        for (i = 0; i < QUEUE_RAM_BE_WIDTH; i = i + 1) begin
            if (queue_ram_be[i]) begin
                queue_ram[queue_ram_write_ptr][i*8 +: 8] <= queue_ram_write_data[i*8 +: 8];
            end
        end
    end

    if (op_table_start_en) begin
        op_table_queue[op_table_start_ptr]    <= op_table_start_queue;
        op_table_doorbell[op_table_start_ptr] <= 1'b0;
    end
    if (op_table_doorbell_en) begin
        op_table_doorbell[op_table_doorbell_ptr] <= 1'b1;
    end
    if (op_table_update_next_en) begin
        op_table_next_index[op_table_update_next_ptr] <= op_table_update_next_index;
    end
    if (op_table_update_prev_en) begin
        op_table_prev_index[op_table_update_prev_ptr] <= op_table_update_prev_index;
        op_table_is_head[op_table_update_prev_ptr]    <= op_table_update_prev_is_head;
    end

    if (finish_fifo_we) begin
        finish_fifo_tag[finish_fifo_wr_ptr_reg[CL_OP_TABLE_SIZE-1:0]]    <= finish_fifo_wr_tag;
        finish_fifo_status[finish_fifo_wr_ptr_reg[CL_OP_TABLE_SIZE-1:0]] <= finish_fifo_wr_status;
    end
end

endmodule

`resetall
