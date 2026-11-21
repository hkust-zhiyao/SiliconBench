/*
 * Copyright (c) 2015-2018 Alex Forencich
 * SPDX-License-Identifier: MIT
 */

`resetall
`timescale 1ns / 1ps
`default_nettype none

module axis_frame_length_adjust #
(
    parameter DATA_WIDTH = 8,
    parameter KEEP_ENABLE = (DATA_WIDTH>8),
    parameter KEEP_WIDTH = ((DATA_WIDTH+7)/8),
    parameter ID_ENABLE = 0,
    parameter ID_WIDTH = 8,
    parameter DEST_ENABLE = 0,
    parameter DEST_WIDTH = 8,
    parameter USER_ENABLE = 1,
    parameter USER_WIDTH = 1
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

    output wire                   status_valid,
    input  wire                   status_ready,
    output wire                   status_frame_pad,
    output wire                   status_frame_truncate,
    output wire [15:0]            status_frame_length,
    output wire [15:0]            status_frame_original_length,

    input  wire [15:0]            length_min,
    input  wire [15:0]            length_max
);

localparam DATA_WORD_WIDTH = DATA_WIDTH / KEEP_WIDTH;

localparam [1:0]
    FL_IDLE  = 2'd0,
    FL_BODY  = 2'd1,
    FL_PAD   = 2'd2,
    FL_DRAIN = 2'd3;

reg [1:0]  fsm_q = FL_IDLE, fsm_d;
reg [15:0] byte_acc_q = 16'd0, byte_acc_d;
reg [15:0] rem_min_q  = 16'd0, rem_min_d;
reg [15:0] rem_max_q  = 16'd0, rem_max_d;
reg [15:0] lat_min_q  = 16'd0, lat_min_d;
reg [15:0] lat_max_q  = 16'd0, lat_max_d;
reg [15:0] lat_orig_q = 16'd0, lat_orig_d;

reg [DATA_WIDTH-1:0] hold_data_q = {DATA_WIDTH{1'b0}};
reg [KEEP_WIDTH-1:0] hold_keep_q = {KEEP_WIDTH{1'b0}};
reg [ID_WIDTH-1:0]   hold_id_q   = {ID_WIDTH{1'b0}};
reg [DEST_WIDTH-1:0] hold_dest_q = {DEST_WIDTH{1'b0}};
reg [USER_WIDTH-1:0] hold_user_q = {USER_WIDTH{1'b0}};
reg                  latch_word;
reg                  latch_meta;

// 2-entry circular FIFO for m_axis_*
reg [DATA_WIDTH-1:0] dq_data [0:1];
reg [KEEP_WIDTH-1:0] dq_keep [0:1];
reg                  dq_last [0:1];
reg [ID_WIDTH-1:0]   dq_id   [0:1];
reg [DEST_WIDTH-1:0] dq_dest [0:1];
reg [USER_WIDTH-1:0] dq_user [0:1];
reg                  dq_wptr = 1'b0, dq_rptr = 1'b0;
reg [1:0]            dq_cnt  = 2'd0;
reg                  dq_rdy_q = 1'b0;

reg [DATA_WIDTH-1:0] d_push_data;
reg [KEEP_WIDTH-1:0] d_push_keep;
reg                  d_push_vld;
reg                  d_push_last;
reg [ID_WIDTH-1:0]   d_push_id;
reg [DEST_WIDTH-1:0] d_push_dest;
reg [USER_WIDTH-1:0] d_push_user;

wire dq_pop = m_axis_tvalid && m_axis_tready;
wire [1:0] dq_after_pop = dq_cnt - {1'b0, dq_pop};
wire dq_can_push = (dq_after_pop + {1'b0, (d_push_vld && dq_rdy_q)}) <= 2'd1;

assign m_axis_tvalid = (dq_cnt != 2'd0);
assign m_axis_tdata  = dq_data[dq_rptr];
assign m_axis_tkeep  = KEEP_ENABLE ? dq_keep[dq_rptr] : {KEEP_WIDTH{1'b1}};
assign m_axis_tlast  = dq_last[dq_rptr];
assign m_axis_tid    = ID_ENABLE   ? dq_id[dq_rptr]   : {ID_WIDTH{1'b0}};
assign m_axis_tdest  = DEST_ENABLE ? dq_dest[dq_rptr] : {DEST_WIDTH{1'b0}};
assign m_axis_tuser  = USER_ENABLE ? dq_user[dq_rptr] : {USER_WIDTH{1'b0}};

// 2-entry circular FIFO for status_*
reg        sq_pad  [0:1];
reg        sq_trnc [0:1];
reg [15:0] sq_len  [0:1];
reg [15:0] sq_olen [0:1];
reg        sq_wptr = 1'b0, sq_rptr = 1'b0;
reg [1:0]  sq_cnt  = 2'd0;
reg        sq_rdy_q = 1'b0;

reg        s_push_vld;
reg        s_push_pad;
reg        s_push_trnc;
reg [15:0] s_push_len;
reg [15:0] s_push_olen;

wire sq_pop = status_valid && status_ready;
wire [1:0] sq_after_pop = sq_cnt - {1'b0, sq_pop};
wire sq_can_push = (sq_after_pop + {1'b0, (s_push_vld && sq_rdy_q)}) <= 2'd1;

assign status_valid                 = (sq_cnt != 2'd0);
assign status_frame_pad             = sq_pad[sq_rptr];
assign status_frame_truncate        = sq_trnc[sq_rptr];
assign status_frame_length          = sq_len[sq_rptr];
assign status_frame_original_length = sq_olen[sq_rptr];

reg s_rdy_q = 1'b0, s_rdy_d;
assign s_axis_tready = s_rdy_q;

always @(posedge clk) begin
    if (rst) begin
        dq_wptr <= 1'b0; dq_rptr <= 1'b0; dq_cnt <= 2'd0; dq_rdy_q <= 1'b0;
        dq_data[0] <= {DATA_WIDTH{1'b0}}; dq_data[1] <= {DATA_WIDTH{1'b0}};
        dq_keep[0] <= {KEEP_WIDTH{1'b0}}; dq_keep[1] <= {KEEP_WIDTH{1'b0}};
        dq_last[0] <= 1'b0; dq_last[1] <= 1'b0;
        dq_id[0]   <= {ID_WIDTH{1'b0}};   dq_id[1]   <= {ID_WIDTH{1'b0}};
        dq_dest[0] <= {DEST_WIDTH{1'b0}}; dq_dest[1] <= {DEST_WIDTH{1'b0}};
        dq_user[0] <= {USER_WIDTH{1'b0}}; dq_user[1] <= {USER_WIDTH{1'b0}};

        sq_wptr <= 1'b0; sq_rptr <= 1'b0; sq_cnt <= 2'd0; sq_rdy_q <= 1'b0;
        sq_pad[0]  <= 1'b0; sq_pad[1]  <= 1'b0;
        sq_trnc[0] <= 1'b0; sq_trnc[1] <= 1'b0;
        sq_len[0]  <= 16'd0; sq_len[1]  <= 16'd0;
        sq_olen[0] <= 16'd0; sq_olen[1] <= 16'd0;
    end else begin
        dq_rdy_q <= dq_can_push;
        if (d_push_vld && dq_rdy_q) begin
            dq_data[dq_wptr] <= d_push_data;
            dq_keep[dq_wptr] <= d_push_keep;
            dq_last[dq_wptr] <= d_push_last;
            dq_id[dq_wptr]   <= d_push_id;
            dq_dest[dq_wptr] <= d_push_dest;
            dq_user[dq_wptr] <= d_push_user;
            dq_wptr <= ~dq_wptr;
        end
        if (dq_pop) dq_rptr <= ~dq_rptr;
        case ({(d_push_vld && dq_rdy_q), dq_pop})
            2'b10: dq_cnt <= dq_cnt + 2'd1;
            2'b01: dq_cnt <= dq_cnt - 2'd1;
            default: dq_cnt <= dq_cnt;
        endcase

        sq_rdy_q <= sq_can_push;
        if (s_push_vld && sq_rdy_q) begin
            sq_pad[sq_wptr]  <= s_push_pad;
            sq_trnc[sq_wptr] <= s_push_trnc;
            sq_len[sq_wptr]  <= s_push_len;
            sq_olen[sq_wptr] <= s_push_olen;
            sq_wptr <= ~sq_wptr;
        end
        if (sq_pop) sq_rptr <= ~sq_rptr;
        case ({(s_push_vld && sq_rdy_q), sq_pop})
            2'b10: sq_cnt <= sq_cnt + 2'd1;
            2'b01: sq_cnt <= sq_cnt - 2'd1;
            default: sq_cnt <= sq_cnt;
        endcase
    end
end

wire [KEEP_WIDTH-1:0] keep_eff = KEEP_ENABLE ? s_axis_tkeep : {KEEP_WIDTH{1'b1}};
reg  [DATA_WIDTH-1:0] data_clean;
reg  [15:0]           beat_lanes;
integer k;

always @* begin
    fsm_d      = FL_IDLE;
    latch_word = 1'b0;
    latch_meta = 1'b0;
    byte_acc_d = byte_acc_q;
    rem_min_d  = rem_min_q;
    rem_max_d  = rem_max_q;
    lat_min_d  = lat_min_q;
    lat_max_d  = lat_max_q;
    lat_orig_d = lat_orig_q;

    d_push_data = {DATA_WIDTH{1'b0}};
    d_push_keep = {KEEP_WIDTH{1'b0}};
    d_push_vld  = 1'b0;
    d_push_last = 1'b0;
    d_push_id   = {ID_WIDTH{1'b0}};
    d_push_dest = {DEST_WIDTH{1'b0}};
    d_push_user = {USER_WIDTH{1'b0}};

    s_push_vld  = 1'b0;
    s_push_pad  = 1'b0;
    s_push_trnc = 1'b0;
    s_push_len  = 16'd0;
    s_push_olen = 16'd0;

    s_rdy_d = 1'b0;
    k = 0;

    data_clean = s_axis_tdata;
    if (KEEP_ENABLE) begin
        for (k = 0; k < KEEP_WIDTH; k = k + 1) begin
            data_clean[k*DATA_WORD_WIDTH +: DATA_WORD_WIDTH] = keep_eff[k] ? s_axis_tdata[k*DATA_WORD_WIDTH +: DATA_WORD_WIDTH] : {DATA_WORD_WIDTH{1'b0}};
        end
    end

    beat_lanes = 16'd0;
    for (k = 0; k <= KEEP_WIDTH; k = k + 1) begin
        if (keep_eff == (({KEEP_WIDTH{1'b1}}) >> (KEEP_WIDTH - k))) begin
            beat_lanes = k[15:0];
        end
    end

    case (fsm_q)
        FL_IDLE: begin
            s_rdy_d   = dq_can_push && sq_can_push;
            rem_min_d = length_min;
            rem_max_d = length_max;
            lat_min_d = length_min;
            lat_max_d = length_max;

            if (s_axis_tready && s_axis_tvalid) begin
                d_push_data = data_clean;
                d_push_keep = keep_eff;
                d_push_vld  = 1'b1;
                d_push_last = s_axis_tlast;
                d_push_id   = s_axis_tid;
                d_push_dest = s_axis_tdest;
                d_push_user = s_axis_tuser;

                byte_acc_d = KEEP_WIDTH[15:0];
                rem_min_d  = (length_min > KEEP_WIDTH) ? (length_min - KEEP_WIDTH) : 16'd0;
                rem_max_d  = (length_max > KEEP_WIDTH) ? (length_max - KEEP_WIDTH) : 16'd0;

                if (length_max <= beat_lanes) begin
                    d_push_keep = ({KEEP_WIDTH{1'b1}}) >> (KEEP_WIDTH - length_max);
                    if (KEEP_ENABLE) begin
                        for (k = 0; k < KEEP_WIDTH; k = k + 1) begin
                            d_push_data[k*DATA_WORD_WIDTH +: DATA_WORD_WIDTH] = d_push_keep[k] ? data_clean[k*DATA_WORD_WIDTH +: DATA_WORD_WIDTH] : {DATA_WORD_WIDTH{1'b0}};
                        end
                    end
                    if (s_axis_tlast) begin
                        s_push_vld  = 1'b1;
                        s_push_pad  = 1'b0;
                        s_push_trnc = (beat_lanes > length_max);
                        s_push_len  = length_max;
                        s_push_olen = beat_lanes;
                        s_rdy_d     = dq_can_push && sq_can_push;
                        byte_acc_d  = 16'd0;
                        fsm_d       = FL_IDLE;
                    end else begin
                        d_push_vld = 1'b0;
                        latch_word = 1'b1;
                        latch_meta = 1'b1;
                        s_rdy_d    = dq_can_push && sq_can_push;
                        fsm_d      = FL_DRAIN;
                    end
                end else if (s_axis_tlast) begin
                    lat_orig_d = beat_lanes;
                    if (length_min > beat_lanes) begin
                        if (length_min > KEEP_WIDTH) begin
                            s_rdy_d     = 1'b0;
                            d_push_keep = {KEEP_WIDTH{1'b1}};
                            d_push_last = 1'b0;
                            d_push_user = {USER_WIDTH{1'b0}};
                            latch_meta  = 1'b1;
                            fsm_d       = FL_PAD;
                        end else begin
                            d_push_keep = ({KEEP_WIDTH{1'b1}}) >> (KEEP_WIDTH - length_min);
                            s_push_vld  = 1'b1;
                            s_push_pad  = 1'b1;
                            s_push_trnc = 1'b0;
                            s_push_len  = length_min;
                            s_push_olen = beat_lanes;
                            s_rdy_d     = dq_can_push && sq_can_push;
                            byte_acc_d  = 16'd0;
                            fsm_d       = FL_IDLE;
                        end
                    end else begin
                        s_push_vld  = 1'b1;
                        s_push_pad  = 1'b0;
                        s_push_trnc = 1'b0;
                        s_push_len  = beat_lanes;
                        s_push_olen = beat_lanes;
                        s_rdy_d     = dq_can_push && sq_can_push;
                        byte_acc_d  = 16'd0;
                        fsm_d       = FL_IDLE;
                    end
                end else begin
                    s_rdy_d = dq_can_push && sq_can_push;
                    fsm_d   = FL_BODY;
                end
            end else begin
                fsm_d = FL_IDLE;
            end
        end

        FL_BODY: begin
            s_rdy_d = dq_can_push && sq_can_push;
            if (s_axis_tready && s_axis_tvalid) begin
                d_push_data = data_clean;
                d_push_keep = keep_eff;
                d_push_vld  = 1'b1;
                d_push_last = s_axis_tlast;
                d_push_id   = s_axis_tid;
                d_push_dest = s_axis_tdest;
                d_push_user = s_axis_tuser;

                byte_acc_d = byte_acc_q + KEEP_WIDTH;
                rem_min_d  = (rem_min_q > KEEP_WIDTH) ? (rem_min_q - KEEP_WIDTH) : 16'd0;
                rem_max_d  = (rem_max_q > KEEP_WIDTH) ? (rem_max_q - KEEP_WIDTH) : 16'd0;

                if (rem_max_q <= beat_lanes) begin
                    d_push_keep = ({KEEP_WIDTH{1'b1}}) >> (KEEP_WIDTH - rem_max_q);
                    if (KEEP_ENABLE) begin
                        for (k = 0; k < KEEP_WIDTH; k = k + 1) begin
                            d_push_data[k*DATA_WORD_WIDTH +: DATA_WORD_WIDTH] = d_push_keep[k] ? data_clean[k*DATA_WORD_WIDTH +: DATA_WORD_WIDTH] : {DATA_WORD_WIDTH{1'b0}};
                        end
                    end
                    if (s_axis_tlast) begin
                        s_push_vld  = 1'b1;
                        s_push_pad  = 1'b0;
                        s_push_trnc = (beat_lanes > rem_max_q);
                        s_push_len  = lat_max_q;
                        s_push_olen = byte_acc_q + beat_lanes;
                        s_rdy_d     = dq_can_push && sq_can_push;
                        byte_acc_d  = 16'd0;
                        fsm_d       = FL_IDLE;
                    end else begin
                        d_push_vld = 1'b0;
                        latch_word = 1'b1;
                        latch_meta = 1'b1;
                        s_rdy_d    = dq_can_push && sq_can_push;
                        fsm_d      = FL_DRAIN;
                    end
                end else if (s_axis_tlast) begin
                    lat_orig_d = byte_acc_q + beat_lanes;
                    if (rem_min_q > beat_lanes) begin
                        if (rem_min_q > KEEP_WIDTH) begin
                            s_rdy_d     = 1'b0;
                            d_push_keep = {KEEP_WIDTH{1'b1}};
                            d_push_last = 1'b0;
                            d_push_user = {USER_WIDTH{1'b0}};
                            latch_meta  = 1'b1;
                            fsm_d       = FL_PAD;
                        end else begin
                            d_push_keep = ({KEEP_WIDTH{1'b1}}) >> (KEEP_WIDTH - rem_min_q);
                            s_push_vld  = 1'b1;
                            s_push_pad  = 1'b1;
                            s_push_trnc = 1'b0;
                            s_push_len  = lat_min_q;
                            s_push_olen = byte_acc_q + beat_lanes;
                            s_rdy_d     = dq_can_push && sq_can_push;
                            byte_acc_d  = 16'd0;
                            fsm_d       = FL_IDLE;
                        end
                    end else begin
                        s_push_vld  = 1'b1;
                        s_push_pad  = 1'b0;
                        s_push_trnc = 1'b0;
                        s_push_len  = byte_acc_q + beat_lanes;
                        s_push_olen = byte_acc_q + beat_lanes;
                        s_rdy_d     = dq_can_push && sq_can_push;
                        byte_acc_d  = 16'd0;
                        fsm_d       = FL_IDLE;
                    end
                end else begin
                    s_rdy_d = dq_can_push && sq_can_push;
                    fsm_d   = FL_BODY;
                end
            end else begin
                fsm_d = FL_BODY;
            end
        end

        FL_PAD: begin
            s_rdy_d     = 1'b0;
            d_push_data = {DATA_WIDTH{1'b0}};
            d_push_keep = {KEEP_WIDTH{1'b1}};
            d_push_id   = hold_id_q;
            d_push_dest = hold_dest_q;
            d_push_user = {USER_WIDTH{1'b0}};

            if (rem_min_q <= KEEP_WIDTH) begin
                if (dq_rdy_q && sq_rdy_q) begin
                    d_push_vld  = 1'b1;
                    d_push_keep = ({KEEP_WIDTH{1'b1}}) >> (KEEP_WIDTH - rem_min_q);
                    d_push_last = 1'b1;
                    d_push_user = hold_user_q;
                    s_push_vld  = 1'b1;
                    s_push_pad  = 1'b1;
                    s_push_trnc = 1'b0;
                    s_push_len  = lat_min_q;
                    s_push_olen = lat_orig_q;
                    s_rdy_d     = dq_can_push && sq_can_push;
                    byte_acc_d  = 16'd0;
                    rem_min_d   = length_min;
                    rem_max_d   = length_max;
                    fsm_d       = FL_IDLE;
                end else begin
                    fsm_d = FL_PAD;
                end
            end else begin
                if (dq_rdy_q) begin
                    d_push_vld  = 1'b1;
                    d_push_last = 1'b0;
                    byte_acc_d  = byte_acc_q + KEEP_WIDTH;
                    rem_min_d   = rem_min_q - KEEP_WIDTH;
                    rem_max_d   = (rem_max_q > KEEP_WIDTH) ? (rem_max_q - KEEP_WIDTH) : 16'd0;
                    fsm_d       = FL_PAD;
                end else begin
                    fsm_d = FL_PAD;
                end
            end
        end

        FL_DRAIN: begin
            s_rdy_d = dq_can_push && sq_can_push;
            if (s_axis_tready && s_axis_tvalid) begin
                byte_acc_d = byte_acc_q + KEEP_WIDTH;
                if (s_axis_tlast) begin
                    d_push_data = hold_data_q;
                    d_push_keep = hold_keep_q;
                    d_push_vld  = 1'b1;
                    d_push_last = 1'b1;
                    d_push_id   = hold_id_q;
                    d_push_dest = hold_dest_q;
                    d_push_user = hold_user_q | s_axis_tuser;

                    s_push_vld  = 1'b1;
                    s_push_pad  = 1'b0;
                    s_push_trnc = 1'b1;
                    s_push_len  = lat_max_q;
                    s_push_olen = byte_acc_q + beat_lanes;
                    s_rdy_d     = dq_can_push && sq_can_push;
                    byte_acc_d  = 16'd0;
                    rem_min_d   = length_min;
                    rem_max_d   = length_max;
                    fsm_d       = FL_IDLE;
                end else begin
                    fsm_d = FL_DRAIN;
                end
            end else begin
                fsm_d = FL_DRAIN;
            end
        end

        default: fsm_d = FL_IDLE;
    endcase
end

always @(posedge clk) begin
    if (rst) begin
        fsm_q       <= FL_IDLE;
        byte_acc_q  <= 16'd0;
        rem_min_q   <= 16'd0;
        rem_max_q   <= 16'd0;
        lat_min_q   <= 16'd0;
        lat_max_q   <= 16'd0;
        lat_orig_q  <= 16'd0;
        s_rdy_q     <= 1'b0;
        hold_data_q <= {DATA_WIDTH{1'b0}};
        hold_keep_q <= {KEEP_WIDTH{1'b0}};
        hold_id_q   <= {ID_WIDTH{1'b0}};
        hold_dest_q <= {DEST_WIDTH{1'b0}};
        hold_user_q <= {USER_WIDTH{1'b0}};
    end else begin
        fsm_q      <= fsm_d;
        byte_acc_q <= byte_acc_d;
        rem_min_q  <= rem_min_d;
        rem_max_q  <= rem_max_d;
        lat_min_q  <= lat_min_d;
        lat_max_q  <= lat_max_d;
        lat_orig_q <= lat_orig_d;
        s_rdy_q    <= s_rdy_d;
        if (latch_word) begin
            hold_data_q <= d_push_data;
            hold_keep_q <= d_push_keep;
        end
        if (latch_meta) begin
            hold_id_q   <= s_axis_tid;
            hold_dest_q <= s_axis_tdest;
            hold_user_q <= s_axis_tuser;
        end
    end
end

endmodule

`resetall
