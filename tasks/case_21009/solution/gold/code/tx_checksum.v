// SPDX-License-Identifier: BSD-2-Clause-Views
/*
 * Copyright (c) 2019-2023 The Regents of the University of California
 */

// Language: Verilog 2001

`resetall
`timescale 1ns / 1ps
`default_nettype none

/*
 * Transmit checksum offload module
 */
module tx_checksum #
(
    parameter DATA_WIDTH = 256,
    parameter KEEP_WIDTH = (DATA_WIDTH/8),
    parameter ID_ENABLE = 0,
    parameter ID_WIDTH = 8,
    parameter DEST_ENABLE = 0,
    parameter DEST_WIDTH = 8,
    parameter USER_ENABLE = 1,
    parameter USER_WIDTH = 1,
    parameter USE_INIT_VALUE = 0,
    parameter DATA_FIFO_DEPTH = 4096,
    parameter CHECKSUM_FIFO_DEPTH = 64
)
(
    input  wire                   clk,
    input  wire                   rst,

    input  wire [DATA_WIDTH-1:0]  s_axis_tdata,
    input  wire [KEEP_WIDTH-1:0]  s_axis_tkeep,
    input  wire                   s_axis_tvalid,
    output wire                   s_axis_tready,
    input  wire                   s_axis_tlast,
    input  wire [ID_WIDTH-1:0]    s_axis_tid,
    input  wire [DEST_WIDTH-1:0]  s_axis_tdest,
    input  wire [USER_WIDTH-1:0]  s_axis_tuser,

    output wire [DATA_WIDTH-1:0]  m_axis_tdata,
    output wire [KEEP_WIDTH-1:0]  m_axis_tkeep,
    output wire                   m_axis_tvalid,
    input  wire                   m_axis_tready,
    output wire                   m_axis_tlast,
    output wire [ID_WIDTH-1:0]    m_axis_tid,
    output wire [DEST_WIDTH-1:0]  m_axis_tdest,
    output wire [USER_WIDTH-1:0]  m_axis_tuser,

    input  wire                   s_axis_cmd_csum_enable,
    input  wire [7:0]             s_axis_cmd_csum_start,
    input  wire [7:0]             s_axis_cmd_csum_offset,
    input  wire [15:0]            s_axis_cmd_csum_init,
    input  wire                   s_axis_cmd_valid,
    output wire                   s_axis_cmd_ready
);

localparam LEVELS = $clog2(DATA_WIDTH/8);
localparam FINAL_SUM_W = 16 + LEVELS - 1;
localparam CSUM_FIFO_KEEP_W = ((16 + 8 + 1) + 7) / 8;

reg transfer_in_reg = 1'b0;

reg        cmd_odd_reg    = 1'b0;
reg        cmd_enable_reg = 1'b0;
reg [7:0]  cmd_offset_reg = 8'd0;
reg [15:0] cmd_init_reg   = 16'd0;

reg [15:0] csum_in_csum_reg   = 16'd0;
reg [7:0]  csum_in_offset_reg = 8'd0;
reg        csum_in_enable_reg = 1'b0;
reg        csum_in_valid_reg  = 1'b0;
wire       csum_in_ready;

wire [15:0] csum_out_csum;
wire [7:0]  csum_out_offset;
wire        csum_out_enable;
wire        csum_out_valid;
reg         csum_out_ready = 1'b0;

reg [KEEP_WIDTH-1:0] mask_reg         = {KEEP_WIDTH{1'b0}};
reg                  first_cycle_reg  = 1'b0;
reg [7:0]            input_offset_reg = 8'd0;
reg [DATA_WIDTH-1:0] s_axis_tdata_masked;

reg                  frame_reg       = 1'b0, frame_next;
reg [15:0]           csum_reg        = 16'd0, csum_next;
reg [7:0]            csum_offset_reg = 8'd0, csum_offset_next;
reg                  csum_enable_reg = 1'b0, csum_enable_next;
reg                  csum_split_reg  = 1'b0, csum_split_next;
reg [KEEP_WIDTH-1:0] hi_mask_reg     = {KEEP_WIDTH{1'b0}}, hi_mask_next;
reg [KEEP_WIDTH-1:0] lo_mask_reg     = {KEEP_WIDTH{1'b0}}, lo_mask_next;

reg [DATA_WIDTH-1:0] sum_reg [LEVELS-2:0];
reg [LEVELS-2:0]     sum_valid_reg      = {LEVELS-1{1'b0}};
reg [LEVELS-2:0]     sum_odd_reg        = {LEVELS-1{1'b0}};
reg [LEVELS-2:0]     sum_last_reg       = {LEVELS-1{1'b0}};
reg [LEVELS-2:0]     sum_enable_reg     = {LEVELS-1{1'b0}};
reg [7:0]            sum_offset_reg [LEVELS-2:0];
reg [15:0]           sum_init_reg   [LEVELS-2:0];
reg [LEVELS-2:0]     sum_init_valid_reg = {LEVELS-1{1'b0}};

reg [29:0] sum_acc_reg     = 30'd0;
reg [29:0] fold_acc_reg    = 30'd0;
reg        fold_valid_reg  = 1'b0;
reg        fold_odd_reg    = 1'b0;
reg        fold_enable_reg = 1'b0;
reg [7:0]  fold_offset_reg = 8'd0;

reg  [DATA_WIDTH-1:0] m_axis_tdata_int;
reg  [KEEP_WIDTH-1:0] m_axis_tkeep_int;
reg                   m_axis_tvalid_int;
reg                   m_axis_tready_int_reg = 1'b0;
reg                   m_axis_tlast_int;
reg  [ID_WIDTH-1:0]   m_axis_tid_int;
reg  [DEST_WIDTH-1:0] m_axis_tdest_int;
reg  [USER_WIDTH-1:0] m_axis_tuser_int;
wire                  m_axis_tready_int_early;

wire                  data_in_axis_tvalid;
wire                  data_in_axis_tready;

wire [DATA_WIDTH-1:0] data_out_axis_tdata;
wire [KEEP_WIDTH-1:0] data_out_axis_tkeep;
wire                  data_out_axis_tvalid;
reg                   data_out_axis_tready;
wire                  data_out_axis_tlast;
wire [ID_WIDTH-1:0]   data_out_axis_tid;
wire [DEST_WIDTH-1:0] data_out_axis_tdest;
wire [USER_WIDTH-1:0] data_out_axis_tuser;

wire pipe_ready = !csum_in_valid_reg || csum_in_ready;

assign s_axis_tready     = data_in_axis_tready && pipe_ready && transfer_in_reg;
assign s_axis_cmd_ready  = pipe_ready && !transfer_in_reg;
assign data_in_axis_tvalid = s_axis_tvalid && pipe_ready && transfer_in_reg;

axis_fifo #(
    .DEPTH(DATA_FIFO_DEPTH),
    .DATA_WIDTH(DATA_WIDTH),
    .KEEP_ENABLE(1),
    .KEEP_WIDTH(KEEP_WIDTH),
    .LAST_ENABLE(1),
    .ID_ENABLE(ID_ENABLE),
    .ID_WIDTH(ID_WIDTH),
    .DEST_ENABLE(DEST_ENABLE),
    .DEST_WIDTH(DEST_WIDTH),
    .USER_ENABLE(USER_ENABLE),
    .USER_WIDTH(USER_WIDTH),
    .FRAME_FIFO(0)
)
data_fifo (
    .clk(clk),
    .rst(rst),
    .s_axis_tdata(s_axis_tdata),
    .s_axis_tkeep(s_axis_tkeep),
    .s_axis_tvalid(data_in_axis_tvalid),
    .s_axis_tready(data_in_axis_tready),
    .s_axis_tlast(s_axis_tlast),
    .s_axis_tid(s_axis_tid),
    .s_axis_tdest(s_axis_tdest),
    .s_axis_tuser(s_axis_tuser),
    .m_axis_tdata(data_out_axis_tdata),
    .m_axis_tkeep(data_out_axis_tkeep),
    .m_axis_tvalid(data_out_axis_tvalid),
    .m_axis_tready(data_out_axis_tready),
    .m_axis_tlast(data_out_axis_tlast),
    .m_axis_tid(data_out_axis_tid),
    .m_axis_tdest(data_out_axis_tdest),
    .m_axis_tuser(data_out_axis_tuser),
    .pause_req(1'b0),
    .pause_ack(),
    .status_depth(),
    .status_depth_commit(),
    .status_overflow(),
    .status_bad_frame(),
    .status_good_frame()
);

axis_fifo #(
    .DEPTH(CHECKSUM_FIFO_DEPTH),
    .DATA_WIDTH(16+8+1),
    .KEEP_ENABLE(0),
    .KEEP_WIDTH(CSUM_FIFO_KEEP_W),
    .LAST_ENABLE(0),
    .ID_ENABLE(0),
    .DEST_ENABLE(0),
    .USER_ENABLE(0),
    .FRAME_FIFO(0)
)
csum_fifo (
    .clk(clk),
    .rst(rst),
    .s_axis_tdata({csum_in_csum_reg, csum_in_offset_reg, csum_in_enable_reg}),
    .s_axis_tkeep({CSUM_FIFO_KEEP_W{1'b0}}),
    .s_axis_tvalid(csum_in_valid_reg),
    .s_axis_tready(csum_in_ready),
    .s_axis_tlast(1'b0),
    .s_axis_tid(8'd0),
    .s_axis_tdest(8'd0),
    .s_axis_tuser(1'b0),
    .m_axis_tdata({csum_out_csum, csum_out_offset, csum_out_enable}),
    .m_axis_tkeep(),
    .m_axis_tvalid(csum_out_valid),
    .m_axis_tready(csum_out_ready),
    .m_axis_tlast(),
    .m_axis_tid(),
    .m_axis_tdest(),
    .m_axis_tuser(),
    .pause_req(1'b0),
    .pause_ack(),
    .status_depth(),
    .status_depth_commit(),
    .status_overflow(),
    .status_bad_frame(),
    .status_good_frame()
);

integer j;
always @* begin
    for (j = 0; j < KEEP_WIDTH; j = j + 1) begin
        s_axis_tdata_masked[j*8 +: 8] = (s_axis_tkeep[j] && mask_reg[j]) ? s_axis_tdata[j*8 +: 8] : 8'd0;
    end
end

integer i;
always @(posedge clk) begin
    if (rst) begin
        transfer_in_reg       <= 1'b0;
        cmd_odd_reg           <= 1'b0;
        cmd_enable_reg        <= 1'b0;
        cmd_offset_reg        <= 8'd0;
        cmd_init_reg          <= 16'd0;
        mask_reg              <= {KEEP_WIDTH{1'b0}};
        first_cycle_reg       <= 1'b0;
        input_offset_reg      <= 8'd0;
        sum_valid_reg[0]      <= 1'b0;
        sum_odd_reg[0]        <= 1'b0;
        sum_last_reg[0]       <= 1'b0;
        sum_enable_reg[0]     <= 1'b0;
        sum_offset_reg[0]     <= 8'd0;
        sum_init_reg[0]       <= 16'd0;
        sum_init_valid_reg[0] <= 1'b0;
        for (i = 0; i < DATA_WIDTH/32; i = i + 1) begin
            sum_reg[0][i*17 +: 17] <= 17'd0;
        end
    end else begin
        if (pipe_ready) begin
            sum_valid_reg[0] <= 1'b0;

            if (s_axis_tvalid && s_axis_tready) begin
                for (i = 0; i < DATA_WIDTH/32; i = i + 1) begin
                    sum_reg[0][i*17 +: 17] <= {1'b0, s_axis_tdata_masked[(4*i+0)*8 +: 8], s_axis_tdata_masked[(4*i+1)*8 +: 8]} +
                                              {1'b0, s_axis_tdata_masked[(4*i+2)*8 +: 8], s_axis_tdata_masked[(4*i+3)*8 +: 8]};
                end
                sum_valid_reg[0]      <= 1'b1;
                sum_odd_reg[0]        <= cmd_odd_reg;
                sum_last_reg[0]       <= s_axis_tlast;
                sum_enable_reg[0]     <= cmd_enable_reg;
                sum_offset_reg[0]     <= cmd_offset_reg;
                sum_init_reg[0]       <= cmd_init_reg;
                sum_init_valid_reg[0] <= first_cycle_reg;

                first_cycle_reg <= 1'b0;

                if (s_axis_tlast) begin
                    transfer_in_reg <= 1'b0;
                end

                if (input_offset_reg > 8'd0) begin
                    if (input_offset_reg >= KEEP_WIDTH) begin
                        mask_reg         <= {KEEP_WIDTH{1'b0}};
                        input_offset_reg <= input_offset_reg - KEEP_WIDTH[7:0];
                    end else begin
                        mask_reg         <= {KEEP_WIDTH{1'b1}} << input_offset_reg;
                        input_offset_reg <= 8'd0;
                    end
                end else begin
                    mask_reg <= {KEEP_WIDTH{1'b1}};
                end
            end
        end

        if (s_axis_cmd_valid && s_axis_cmd_ready) begin
            transfer_in_reg <= 1'b1;
            cmd_odd_reg     <= s_axis_cmd_csum_start[0];
            cmd_enable_reg  <= s_axis_cmd_csum_enable;
            cmd_offset_reg  <= s_axis_cmd_csum_offset;
            cmd_init_reg    <= s_axis_cmd_csum_init;
            first_cycle_reg <= 1'b1;

            if (s_axis_cmd_csum_start >= KEEP_WIDTH) begin
                mask_reg         <= {KEEP_WIDTH{1'b0}};
                input_offset_reg <= s_axis_cmd_csum_start - KEEP_WIDTH[7:0];
            end else begin
                mask_reg         <= {KEEP_WIDTH{1'b1}} << s_axis_cmd_csum_start;
                input_offset_reg <= 8'd0;
            end
        end
    end
end

generate
    genvar l;
    for (l = 1; l < LEVELS-1; l = l + 1) begin : gen_tree
        always @(posedge clk) begin
            if (rst) begin
                sum_valid_reg[l]      <= 1'b0;
                sum_odd_reg[l]        <= 1'b0;
                sum_last_reg[l]       <= 1'b0;
                sum_enable_reg[l]     <= 1'b0;
                sum_offset_reg[l]     <= 8'd0;
                sum_init_reg[l]       <= 16'd0;
                sum_init_valid_reg[l] <= 1'b0;
                for (i = 0; i < (DATA_WIDTH/32)/(1 << l); i = i + 1) begin
                    sum_reg[l][i*(17+l) +: (17+l)] <= {(17+l){1'b0}};
                end
            end else if (pipe_ready) begin
                sum_valid_reg[l] <= 1'b0;
                if (sum_valid_reg[l-1]) begin
                    for (i = 0; i < (DATA_WIDTH/32)/(1 << l); i = i + 1) begin
                        sum_reg[l][i*(17+l) +: (17+l)] <= sum_reg[l-1][(i*2+0)*(17+l-1) +: (17+l-1)] +
                                                          sum_reg[l-1][(i*2+1)*(17+l-1) +: (17+l-1)];
                    end
                    sum_valid_reg[l]      <= 1'b1;
                    sum_odd_reg[l]        <= sum_odd_reg[l-1];
                    sum_last_reg[l]       <= sum_last_reg[l-1];
                    sum_enable_reg[l]     <= sum_enable_reg[l-1];
                    sum_offset_reg[l]     <= sum_offset_reg[l-1];
                    sum_init_reg[l]       <= sum_init_reg[l-1];
                    sum_init_valid_reg[l] <= sum_init_valid_reg[l-1];
                end
            end
        end
    end
endgenerate

wire [29:0] acc_base = (sum_init_valid_reg[LEVELS-2] && (USE_INIT_VALUE != 0)) ? {14'd0, sum_init_reg[LEVELS-2]} : sum_acc_reg;
wire [29:0] next_acc = acc_base + {{(30-FINAL_SUM_W){1'b0}}, sum_reg[LEVELS-2][FINAL_SUM_W-1:0]};

wire [16:0] fold_s1   = {1'b0, fold_acc_reg[15:0]} + {3'd0, fold_acc_reg[29:16]};
wire [15:0] fold_c16  = fold_s1[15:0] + {15'd0, fold_s1[16]};
wire [15:0] fold_inv  = ~fold_c16;

always @(posedge clk) begin
    if (rst) begin
        sum_acc_reg        <= 30'd0;
        fold_acc_reg       <= 30'd0;
        fold_valid_reg     <= 1'b0;
        fold_odd_reg       <= 1'b0;
        fold_enable_reg    <= 1'b0;
        fold_offset_reg    <= 8'd0;
        csum_in_csum_reg   <= 16'd0;
        csum_in_offset_reg <= 8'd0;
        csum_in_enable_reg <= 1'b0;
        csum_in_valid_reg  <= 1'b0;
    end else begin
        if (csum_in_valid_reg && csum_in_ready) begin
            csum_in_valid_reg <= 1'b0;
        end

        if (pipe_ready) begin
            fold_valid_reg <= 1'b0;

            if (sum_valid_reg[LEVELS-2]) begin
                if (sum_last_reg[LEVELS-2]) begin
                    fold_acc_reg    <= next_acc;
                    fold_valid_reg  <= 1'b1;
                    fold_odd_reg    <= sum_odd_reg[LEVELS-2];
                    fold_enable_reg <= sum_enable_reg[LEVELS-2];
                    fold_offset_reg <= sum_offset_reg[LEVELS-2];
                    sum_acc_reg     <= 30'd0;
                end else begin
                    sum_acc_reg <= next_acc;
                end
            end

            if (fold_valid_reg) begin
                csum_in_csum_reg   <= fold_odd_reg ? {fold_inv[7:0], fold_inv[15:8]} : fold_inv;
                csum_in_offset_reg <= fold_offset_reg;
                csum_in_enable_reg <= fold_enable_reg;
                csum_in_valid_reg  <= 1'b1;
            end
        end
    end
end

// Registered one-hot byte-lane checksum insertion
integer b;
always @* begin
    data_out_axis_tready = m_axis_tready_int_reg && frame_reg;
    csum_out_ready       = 1'b0;

    frame_next       = frame_reg;
    csum_next        = csum_reg;
    csum_offset_next = csum_offset_reg;
    csum_enable_next = csum_enable_reg;
    csum_split_next  = csum_split_reg;
    hi_mask_next     = hi_mask_reg;
    lo_mask_next     = lo_mask_reg;

    for (b = 0; b < KEEP_WIDTH; b = b + 1) begin
        if (hi_mask_reg[b]) begin
            m_axis_tdata_int[b*8 +: 8] = csum_reg[15:8];
        end else if (lo_mask_reg[b]) begin
            m_axis_tdata_int[b*8 +: 8] = csum_reg[7:0];
        end else begin
            m_axis_tdata_int[b*8 +: 8] = data_out_axis_tdata[b*8 +: 8];
        end
    end
    m_axis_tkeep_int  = data_out_axis_tkeep;
    m_axis_tvalid_int = data_out_axis_tvalid && data_out_axis_tready;
    m_axis_tlast_int  = data_out_axis_tlast;
    m_axis_tid_int    = data_out_axis_tid;
    m_axis_tdest_int  = data_out_axis_tdest;
    m_axis_tuser_int  = data_out_axis_tuser;

    if (frame_reg) begin
        if (data_out_axis_tvalid && data_out_axis_tready) begin
            if (data_out_axis_tlast) begin
                frame_next       = 1'b0;
                csum_enable_next = 1'b0;
                csum_split_next  = 1'b0;
                hi_mask_next     = {KEEP_WIDTH{1'b0}};
                lo_mask_next     = {KEEP_WIDTH{1'b0}};
            end else if (csum_enable_reg) begin
                if (|hi_mask_reg) begin
                    hi_mask_next = {KEEP_WIDTH{1'b0}};
                    if (csum_split_reg) begin
                        lo_mask_next    = {{(KEEP_WIDTH-1){1'b0}}, 1'b1};
                        csum_split_next = 1'b0;
                    end else begin
                        lo_mask_next     = {KEEP_WIDTH{1'b0}};
                        csum_enable_next = 1'b0;
                    end
                end else if (|lo_mask_reg) begin
                    hi_mask_next     = {KEEP_WIDTH{1'b0}};
                    lo_mask_next     = {KEEP_WIDTH{1'b0}};
                    csum_enable_next = 1'b0;
                end else if (csum_offset_reg >= KEEP_WIDTH) begin
                    csum_offset_next = csum_offset_reg - KEEP_WIDTH[7:0];
                end else if (csum_offset_reg == (KEEP_WIDTH - 1)) begin
                    hi_mask_next    = {{(KEEP_WIDTH-1){1'b0}}, 1'b1} << (KEEP_WIDTH - 1);
                    lo_mask_next    = {KEEP_WIDTH{1'b0}};
                    csum_split_next = 1'b1;
                end else begin
                    hi_mask_next    = ({{(KEEP_WIDTH-1){1'b0}}, 1'b1} << csum_offset_reg);
                    lo_mask_next    = ({{(KEEP_WIDTH-1){1'b0}}, 1'b1} << (csum_offset_reg + 8'd1));
                    csum_split_next = 1'b0;
                end
            end
        end
    end else begin
        frame_next       = 1'b0;
        csum_out_ready   = 1'b1;
        csum_next        = csum_out_csum;
        csum_offset_next = csum_out_offset;
        csum_enable_next = csum_out_enable;
        csum_split_next  = 1'b0;
        hi_mask_next     = {KEEP_WIDTH{1'b0}};
        lo_mask_next     = {KEEP_WIDTH{1'b0}};
        if (csum_out_valid) begin
            frame_next = 1'b1;
            if (csum_out_enable) begin
                if (csum_out_offset >= KEEP_WIDTH) begin
                    csum_offset_next = csum_out_offset - KEEP_WIDTH[7:0];
                end else if (csum_out_offset == (KEEP_WIDTH - 1)) begin
                    hi_mask_next    = {{(KEEP_WIDTH-1){1'b0}}, 1'b1} << (KEEP_WIDTH - 1);
                    csum_split_next = 1'b1;
                end else begin
                    hi_mask_next    = ({{(KEEP_WIDTH-1){1'b0}}, 1'b1} << csum_out_offset);
                    lo_mask_next    = ({{(KEEP_WIDTH-1){1'b0}}, 1'b1} << (csum_out_offset + 8'd1));
                end
            end
        end
    end
end

always @(posedge clk) begin
    if (rst) begin
        frame_reg       <= 1'b0;
        csum_reg        <= 16'd0;
        csum_offset_reg <= 8'd0;
        csum_enable_reg <= 1'b0;
        csum_split_reg  <= 1'b0;
        hi_mask_reg     <= {KEEP_WIDTH{1'b0}};
        lo_mask_reg     <= {KEEP_WIDTH{1'b0}};
    end else begin
        frame_reg       <= frame_next;
        csum_reg        <= csum_next;
        csum_offset_reg <= csum_offset_next;
        csum_enable_reg <= csum_enable_next;
        csum_split_reg  <= csum_split_next;
        hi_mask_reg     <= hi_mask_next;
        lo_mask_reg     <= lo_mask_next;
    end
end

// Output skid buffer
reg [DATA_WIDTH-1:0] m_axis_tdata_reg  = {DATA_WIDTH{1'b0}};
reg [KEEP_WIDTH-1:0] m_axis_tkeep_reg  = {KEEP_WIDTH{1'b0}};
reg                  m_axis_tvalid_reg = 1'b0, m_axis_tvalid_next;
reg                  m_axis_tlast_reg  = 1'b0;
reg [ID_WIDTH-1:0]   m_axis_tid_reg    = {ID_WIDTH{1'b0}};
reg [DEST_WIDTH-1:0] m_axis_tdest_reg  = {DEST_WIDTH{1'b0}};
reg [USER_WIDTH-1:0] m_axis_tuser_reg  = {USER_WIDTH{1'b0}};

reg [DATA_WIDTH-1:0] temp_m_axis_tdata_reg  = {DATA_WIDTH{1'b0}};
reg [KEEP_WIDTH-1:0] temp_m_axis_tkeep_reg  = {KEEP_WIDTH{1'b0}};
reg                  temp_m_axis_tvalid_reg = 1'b0, temp_m_axis_tvalid_next;
reg                  temp_m_axis_tlast_reg  = 1'b0;
reg [ID_WIDTH-1:0]   temp_m_axis_tid_reg    = {ID_WIDTH{1'b0}};
reg [DEST_WIDTH-1:0] temp_m_axis_tdest_reg  = {DEST_WIDTH{1'b0}};
reg [USER_WIDTH-1:0] temp_m_axis_tuser_reg  = {USER_WIDTH{1'b0}};

reg store_axis_int_to_output;
reg store_axis_int_to_temp;
reg store_axis_temp_to_output;

assign m_axis_tdata  = m_axis_tdata_reg;
assign m_axis_tkeep  = m_axis_tkeep_reg;
assign m_axis_tvalid = m_axis_tvalid_reg;
assign m_axis_tlast  = m_axis_tlast_reg;
assign m_axis_tid    = ID_ENABLE   ? m_axis_tid_reg   : {ID_WIDTH{1'b0}};
assign m_axis_tdest  = DEST_ENABLE ? m_axis_tdest_reg : {DEST_WIDTH{1'b0}};
assign m_axis_tuser  = USER_ENABLE ? m_axis_tuser_reg : {USER_WIDTH{1'b0}};

assign m_axis_tready_int_early = m_axis_tready || (!temp_m_axis_tvalid_reg && !m_axis_tvalid_reg);

always @* begin
    m_axis_tvalid_next      = m_axis_tvalid_reg;
    temp_m_axis_tvalid_next = temp_m_axis_tvalid_reg;

    store_axis_int_to_output  = 1'b0;
    store_axis_int_to_temp    = 1'b0;
    store_axis_temp_to_output = 1'b0;

    if (m_axis_tready_int_reg) begin
        if (m_axis_tready || !m_axis_tvalid_reg) begin
            m_axis_tvalid_next       = m_axis_tvalid_int;
            store_axis_int_to_output = 1'b1;
        end else begin
            temp_m_axis_tvalid_next = m_axis_tvalid_int;
            store_axis_int_to_temp  = 1'b1;
        end
    end else if (m_axis_tready) begin
        m_axis_tvalid_next        = temp_m_axis_tvalid_reg;
        temp_m_axis_tvalid_next   = 1'b0;
        store_axis_temp_to_output = 1'b1;
    end
end

always @(posedge clk) begin
    if (rst) begin
        m_axis_tvalid_reg      <= 1'b0;
        m_axis_tready_int_reg  <= 1'b0;
        temp_m_axis_tvalid_reg <= 1'b0;
        m_axis_tdata_reg       <= {DATA_WIDTH{1'b0}};
        m_axis_tkeep_reg       <= {KEEP_WIDTH{1'b0}};
        m_axis_tlast_reg       <= 1'b0;
        m_axis_tid_reg         <= {ID_WIDTH{1'b0}};
        m_axis_tdest_reg       <= {DEST_WIDTH{1'b0}};
        m_axis_tuser_reg       <= {USER_WIDTH{1'b0}};
        temp_m_axis_tdata_reg  <= {DATA_WIDTH{1'b0}};
        temp_m_axis_tkeep_reg  <= {KEEP_WIDTH{1'b0}};
        temp_m_axis_tlast_reg  <= 1'b0;
        temp_m_axis_tid_reg    <= {ID_WIDTH{1'b0}};
        temp_m_axis_tdest_reg  <= {DEST_WIDTH{1'b0}};
        temp_m_axis_tuser_reg  <= {USER_WIDTH{1'b0}};
    end else begin
        m_axis_tvalid_reg      <= m_axis_tvalid_next;
        m_axis_tready_int_reg  <= m_axis_tready_int_early;
        temp_m_axis_tvalid_reg <= temp_m_axis_tvalid_next;

        if (store_axis_int_to_output) begin
            m_axis_tdata_reg <= m_axis_tdata_int;
            m_axis_tkeep_reg <= m_axis_tkeep_int;
            m_axis_tlast_reg <= m_axis_tlast_int;
            m_axis_tid_reg   <= m_axis_tid_int;
            m_axis_tdest_reg <= m_axis_tdest_int;
            m_axis_tuser_reg <= m_axis_tuser_int;
        end else if (store_axis_temp_to_output) begin
            m_axis_tdata_reg <= temp_m_axis_tdata_reg;
            m_axis_tkeep_reg <= temp_m_axis_tkeep_reg;
            m_axis_tlast_reg <= temp_m_axis_tlast_reg;
            m_axis_tid_reg   <= temp_m_axis_tid_reg;
            m_axis_tdest_reg <= temp_m_axis_tdest_reg;
            m_axis_tuser_reg <= temp_m_axis_tuser_reg;
        end

        if (store_axis_int_to_temp) begin
            temp_m_axis_tdata_reg <= m_axis_tdata_int;
            temp_m_axis_tkeep_reg <= m_axis_tkeep_int;
            temp_m_axis_tlast_reg <= m_axis_tlast_int;
            temp_m_axis_tid_reg   <= m_axis_tid_int;
            temp_m_axis_tdest_reg <= m_axis_tdest_int;
            temp_m_axis_tuser_reg <= m_axis_tuser_int;
        end
    end
end

endmodule

`resetall
