/*
 * Copyright (c) 2016-2018 Alex Forencich
 * SPDX-License-Identifier: MIT
 */

`resetall
`timescale 1ns / 1ps
`default_nettype none

module axis_cobs_encode #
(
    parameter APPEND_ZERO = 1
)
(
    input  wire        clk,
    input  wire        rst,

    input  wire [7:0]  s_axis_tdata,
    input  wire        s_axis_tvalid,
    output wire        s_axis_tready,
    input  wire        s_axis_tlast,
    input  wire        s_axis_tuser,

    output wire [7:0]  m_axis_tdata,
    output wire        m_axis_tvalid,
    input  wire        m_axis_tready,
    output wire        m_axis_tlast,
    output wire        m_axis_tuser
);

localparam [1:0]
    IN_START = 2'd0,
    IN_RUN   = 2'd1,
    IN_TAIL0 = 2'd2,
    IN_DELIM = 2'd3;

localparam [0:0]
    OUT_CODE = 1'd0,
    OUT_DATA = 1'd1;

reg [1:0] in_fsm_q  = IN_START, in_fsm_d;
reg [0:0] out_fsm_q = OUT_CODE, out_fsm_d;
reg [7:0] run_cnt_q = 8'd0, run_cnt_d;
reg [7:0] seg_rem_q = 8'd0, seg_rem_d;
reg       bad_frm_q = 1'b0, bad_frm_d;
reg       in_accept_en;

reg  [7:0] cf_in_data;
reg        cf_in_vld;
reg        cf_in_last;
reg        cf_in_user;
wire       cf_in_rdy;
wire [7:0] cf_out_data;
wire       cf_out_vld;
wire       cf_out_last;
wire       cf_out_user;
reg        cf_out_rdy;

reg  [7:0] df_in_data;
reg        df_in_vld;
reg        df_in_last;
wire       df_in_rdy;
wire [7:0] df_out_data;
wire       df_out_vld;
wire       df_out_last;
reg        df_out_rdy;

assign s_axis_tready = cf_in_rdy && df_in_rdy && in_accept_en;

axis_fifo #(
    .DEPTH(256), .DATA_WIDTH(8), .KEEP_ENABLE(0), .LAST_ENABLE(1),
    .ID_ENABLE(0), .DEST_ENABLE(0), .USER_ENABLE(1), .USER_WIDTH(1), .FRAME_FIFO(0)
) u_code_fifo (
    .clk(clk), .rst(rst),
    .s_axis_tdata(cf_in_data), .s_axis_tkeep(1'b0), .s_axis_tvalid(cf_in_vld),
    .s_axis_tready(cf_in_rdy), .s_axis_tlast(cf_in_last),
    .s_axis_tid(8'd0), .s_axis_tdest(8'd0), .s_axis_tuser(cf_in_user),
    .m_axis_tdata(cf_out_data), .m_axis_tkeep(), .m_axis_tvalid(cf_out_vld),
    .m_axis_tready(cf_out_rdy), .m_axis_tlast(cf_out_last),
    .m_axis_tid(), .m_axis_tdest(), .m_axis_tuser(cf_out_user),
    .pause_req(1'b0), .pause_ack(),
    .status_depth(), .status_depth_commit(), .status_overflow(), .status_bad_frame(), .status_good_frame()
);

axis_fifo #(
    .DEPTH(256), .DATA_WIDTH(8), .KEEP_ENABLE(0), .LAST_ENABLE(1),
    .ID_ENABLE(0), .DEST_ENABLE(0), .USER_ENABLE(0), .FRAME_FIFO(0)
) u_data_fifo (
    .clk(clk), .rst(rst),
    .s_axis_tdata(df_in_data), .s_axis_tkeep(1'b0), .s_axis_tvalid(df_in_vld),
    .s_axis_tready(df_in_rdy), .s_axis_tlast(df_in_last),
    .s_axis_tid(8'd0), .s_axis_tdest(8'd0), .s_axis_tuser(1'b0),
    .m_axis_tdata(df_out_data), .m_axis_tkeep(), .m_axis_tvalid(df_out_vld),
    .m_axis_tready(df_out_rdy), .m_axis_tlast(df_out_last),
    .m_axis_tid(), .m_axis_tdest(), .m_axis_tuser(),
    .pause_req(1'b0), .pause_ack(),
    .status_depth(), .status_depth_commit(), .status_overflow(), .status_bad_frame(), .status_good_frame()
);

// 2-entry circular FIFO output buffer
reg [7:0] oq_data [0:1];
reg       oq_last [0:1];
reg       oq_user [0:1];
reg       oq_wptr = 1'b0;
reg       oq_rptr = 1'b0;
reg [1:0] oq_cnt  = 2'd0;
reg       oq_rdy_q = 1'b0;

reg [7:0] push_data;
reg       push_vld;
reg       push_last;
reg       push_user;

wire oq_pop = m_axis_tvalid && m_axis_tready;
wire [1:0] oq_after_pop = oq_cnt - {1'b0, oq_pop};
wire oq_can_push = (oq_after_pop + {1'b0, (push_vld && oq_rdy_q)}) <= 2'd1;

assign m_axis_tvalid = (oq_cnt != 2'd0);
assign m_axis_tdata  = oq_data[oq_rptr];
assign m_axis_tlast  = oq_last[oq_rptr];
assign m_axis_tuser  = oq_user[oq_rptr];

always @(posedge clk) begin
    if (rst) begin
        oq_wptr  <= 1'b0;
        oq_rptr  <= 1'b0;
        oq_cnt   <= 2'd0;
        oq_rdy_q <= 1'b0;
        oq_data[0] <= 8'd0; oq_data[1] <= 8'd0;
        oq_last[0] <= 1'b0; oq_last[1] <= 1'b0;
        oq_user[0] <= 1'b0; oq_user[1] <= 1'b0;
    end else begin
        oq_rdy_q <= oq_can_push;
        if (push_vld && oq_rdy_q) begin
            oq_data[oq_wptr] <= push_data;
            oq_last[oq_wptr] <= push_last;
            oq_user[oq_wptr] <= push_user;
            oq_wptr <= ~oq_wptr;
        end
        if (oq_pop) oq_rptr <= ~oq_rptr;
        case ({(push_vld && oq_rdy_q), oq_pop})
            2'b10: oq_cnt <= oq_cnt + 2'd1;
            2'b01: oq_cnt <= oq_cnt - 2'd1;
            default: oq_cnt <= oq_cnt;
        endcase
    end
end

always @* begin
    in_fsm_d     = IN_START;
    run_cnt_d    = run_cnt_q;
    bad_frm_d    = bad_frm_q;
    in_accept_en = 1'b0;

    cf_in_data = 8'd0;
    cf_in_vld  = 1'b0;
    cf_in_last = 1'b0;
    cf_in_user = 1'b0;
    df_in_data = 8'd0;
    df_in_vld  = 1'b0;
    df_in_last = 1'b0;

    case (in_fsm_q)
        IN_START: begin
            in_accept_en = 1'b1;
            bad_frm_d    = 1'b0;
            if (s_axis_tready && s_axis_tvalid) begin
                if (s_axis_tdata == 8'd0 || (s_axis_tlast && s_axis_tuser)) begin
                    cf_in_data = 8'd1;
                    cf_in_vld  = 1'b1;
                    if (s_axis_tlast) begin
                        bad_frm_d = s_axis_tuser;
                        in_fsm_d  = IN_TAIL0;
                    end else begin
                        in_fsm_d  = IN_START;
                    end
                end else begin
                    run_cnt_d  = 8'd2;
                    df_in_data = s_axis_tdata;
                    df_in_vld  = 1'b1;
                    if (s_axis_tlast) begin
                        cf_in_data = 8'd2;
                        cf_in_vld  = 1'b1;
                        if (APPEND_ZERO) begin
                            in_fsm_d = IN_DELIM;
                        end else begin
                            df_in_last = 1'b1;
                            in_fsm_d   = IN_START;
                        end
                    end else begin
                        in_fsm_d = IN_RUN;
                    end
                end
            end else begin
                in_fsm_d = IN_START;
            end
        end

        IN_RUN: begin
            in_accept_en = 1'b1;
            bad_frm_d    = 1'b0;
            if (s_axis_tready && s_axis_tvalid) begin
                if (s_axis_tdata == 8'd0 || (s_axis_tlast && s_axis_tuser)) begin
                    cf_in_data = run_cnt_q;
                    cf_in_vld  = 1'b1;
                    if (s_axis_tlast) begin
                        bad_frm_d = s_axis_tuser;
                        in_fsm_d  = IN_TAIL0;
                    end else begin
                        in_fsm_d  = IN_START;
                    end
                end else begin
                    df_in_data = s_axis_tdata;
                    df_in_vld  = 1'b1;
                    if (s_axis_tlast) begin
                        cf_in_data = run_cnt_q + 8'd1;
                        cf_in_vld  = 1'b1;
                        run_cnt_d  = 8'd1;
                        if (APPEND_ZERO) begin
                            in_fsm_d = IN_DELIM;
                        end else begin
                            df_in_last = 1'b1;
                            in_fsm_d   = IN_START;
                        end
                    end else if (run_cnt_q == 8'd254) begin
                        cf_in_data = 8'd255;
                        cf_in_vld  = 1'b1;
                        run_cnt_d  = 8'd1;
                        in_fsm_d   = IN_RUN;
                    end else begin
                        run_cnt_d = run_cnt_q + 8'd1;
                        in_fsm_d  = IN_RUN;
                    end
                end
            end else begin
                in_fsm_d = IN_RUN;
            end
        end

        IN_TAIL0: begin
            in_accept_en = 1'b0;
            if (cf_in_rdy) begin
                cf_in_data = bad_frm_q ? 8'd2 : 8'd1;
                cf_in_user = bad_frm_q;
                cf_in_vld  = 1'b1;
                if (APPEND_ZERO) begin
                    in_fsm_d = IN_DELIM;
                end else begin
                    cf_in_last = 1'b1;
                    bad_frm_d  = 1'b0;
                    in_fsm_d   = IN_START;
                end
            end else begin
                in_fsm_d = IN_TAIL0;
            end
        end

        IN_DELIM: begin
            in_accept_en = 1'b0;
            if (cf_in_rdy) begin
                cf_in_data = 8'd0;
                cf_in_last = 1'b1;
                cf_in_user = bad_frm_q;
                cf_in_vld  = 1'b1;
                bad_frm_d  = 1'b0;
                in_fsm_d   = IN_START;
            end else begin
                in_fsm_d = IN_DELIM;
            end
        end
        default: in_fsm_d = IN_START;
    endcase
end

always @* begin
    out_fsm_d  = OUT_CODE;
    seg_rem_d  = seg_rem_q;
    push_data  = 8'd0;
    push_vld   = 1'b0;
    push_last  = 1'b0;
    push_user  = 1'b0;
    cf_out_rdy = 1'b0;
    df_out_rdy = 1'b0;

    case (out_fsm_q)
        OUT_CODE: begin
            if (oq_rdy_q && cf_out_vld) begin
                push_data  = cf_out_data;
                push_last  = cf_out_last;
                push_user  = cf_out_user && cf_out_last;
                push_vld   = 1'b1;
                cf_out_rdy = 1'b1;
                seg_rem_d  = cf_out_data - 8'd1;
                if (cf_out_data == 8'd0 || cf_out_data == 8'd1 || cf_out_user) begin
                    out_fsm_d = OUT_CODE;
                end else begin
                    out_fsm_d = OUT_DATA;
                end
            end else begin
                out_fsm_d = OUT_CODE;
            end
        end

        OUT_DATA: begin
            if (oq_rdy_q && df_out_vld) begin
                push_data  = df_out_data;
                push_last  = df_out_last;
                push_vld   = 1'b1;
                df_out_rdy = 1'b1;
                seg_rem_d  = seg_rem_q - 8'd1;
                if (seg_rem_q == 8'd1) begin
                    out_fsm_d = OUT_CODE;
                end else begin
                    out_fsm_d = OUT_DATA;
                end
            end else begin
                out_fsm_d = OUT_DATA;
            end
        end
        default: out_fsm_d = OUT_CODE;
    endcase
end

always @(posedge clk) begin
    if (rst) begin
        in_fsm_q  <= IN_START;
        out_fsm_q <= OUT_CODE;
        run_cnt_q <= 8'd0;
        seg_rem_q <= 8'd0;
        bad_frm_q <= 1'b0;
    end else begin
        in_fsm_q  <= in_fsm_d;
        out_fsm_q <= out_fsm_d;
        run_cnt_q <= run_cnt_d;
        seg_rem_q <= seg_rem_d;
        bad_frm_q <= bad_frm_d;
    end
end

endmodule

`resetall
