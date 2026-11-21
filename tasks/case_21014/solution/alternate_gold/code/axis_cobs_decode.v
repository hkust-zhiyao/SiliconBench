/*
 * Copyright (c) 2016-2018 Alex Forencich
 * SPDX-License-Identifier: MIT
 */

`resetall
`timescale 1ns / 1ps
`default_nettype none

module axis_cobs_decode
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
    DEC_SYNC = 2'd0,
    DEC_BODY = 2'd1,
    DEC_CODE = 2'd2;

reg [1:0] fsm_q = DEC_SYNC, fsm_d;
reg [7:0] rem_q = 8'd0, rem_d;
reg       no_zero_q = 1'b0, no_zero_d;

reg [7:0] hold_byte_q = 8'd0, hold_byte_d;
reg       hold_err_q  = 1'b0, hold_err_d;
reg       hold_vld_q  = 1'b0, hold_vld_d;

// 2-entry circular FIFO output stage
reg [7:0] out_q_data [0:1];
reg       out_q_last [0:1];
reg       out_q_user [0:1];
reg       out_wptr = 1'b0;
reg       out_rptr = 1'b0;
reg [1:0] out_cnt  = 2'd0;

reg [7:0] emit_data;
reg       emit_vld;
reg       emit_last;
reg       emit_user;

wire out_pop = m_axis_tvalid && m_axis_tready;
wire [1:0] cnt_after_pop = out_cnt - {1'b0, out_pop};
reg  sink_rdy_q = 1'b0;
wire can_push_next = (cnt_after_pop + {1'b0, (emit_vld && sink_rdy_q)}) <= 2'd1;

reg s_rdy_q = 1'b0, s_rdy_d;
assign s_axis_tready = s_rdy_q;

assign m_axis_tvalid = (out_cnt != 2'd0);
assign m_axis_tdata  = out_q_data[out_rptr];
assign m_axis_tlast  = out_q_last[out_rptr];
assign m_axis_tuser  = out_q_user[out_rptr];

always @(posedge clk) begin
    if (rst) begin
        out_wptr   <= 1'b0;
        out_rptr   <= 1'b0;
        out_cnt    <= 2'd0;
        sink_rdy_q <= 1'b0;
        out_q_data[0] <= 8'd0; out_q_data[1] <= 8'd0;
        out_q_last[0] <= 1'b0; out_q_last[1] <= 1'b0;
        out_q_user[0] <= 1'b0; out_q_user[1] <= 1'b0;
    end else begin
        sink_rdy_q <= can_push_next;
        if (emit_vld && sink_rdy_q) begin
            out_q_data[out_wptr] <= emit_data;
            out_q_last[out_wptr] <= emit_last;
            out_q_user[out_wptr] <= emit_user;
            out_wptr <= ~out_wptr;
        end
        if (out_pop) begin
            out_rptr <= ~out_rptr;
        end
        case ({(emit_vld && sink_rdy_q), out_pop})
            2'b10: out_cnt <= out_cnt + 2'd1;
            2'b01: out_cnt <= out_cnt - 2'd1;
            default: out_cnt <= out_cnt;
        endcase
    end
end

always @* begin
    fsm_d       = DEC_SYNC;
    rem_d       = rem_q;
    no_zero_d   = no_zero_q;
    hold_byte_d = hold_byte_q;
    hold_err_d  = hold_err_q;
    hold_vld_d  = hold_vld_q;

    emit_data   = 8'd0;
    emit_vld    = 1'b0;
    emit_last   = 1'b0;
    emit_user   = 1'b0;
    s_rdy_d     = 1'b0;

    case (fsm_q)
        DEC_SYNC: begin
            emit_data  = hold_vld_q ? hold_byte_q : 8'd0;
            emit_vld   = hold_vld_q;
            emit_last  = hold_vld_q;
            emit_user  = hold_vld_q ? hold_err_q : 1'b0;
            hold_vld_d = hold_vld_q && !sink_rdy_q;
            if (!hold_vld_d) begin
                hold_byte_d = 8'd0;
                hold_err_d  = 1'b0;
            end
            s_rdy_d = can_push_next || !hold_vld_q;

            if (s_axis_tready && s_axis_tvalid) begin
                if (s_axis_tdata != 8'd0) begin
                    if (s_axis_tlast) begin
                        hold_byte_d = 8'd0;
                        hold_err_d  = 1'b1;
                        hold_vld_d  = 1'b1;
                        s_rdy_d     = can_push_next;
                        fsm_d       = DEC_SYNC;
                    end else begin
                        rem_d     = s_axis_tdata - 8'd1;
                        no_zero_d = (s_axis_tdata == 8'd255);
                        s_rdy_d   = can_push_next;
                        fsm_d     = (s_axis_tdata == 8'd1) ? DEC_CODE : DEC_BODY;
                    end
                end else if (s_axis_tlast && s_axis_tuser) begin
                    hold_byte_d = 8'd0;
                    hold_err_d  = 1'b1;
                    hold_vld_d  = 1'b1;
                    s_rdy_d     = can_push_next;
                    fsm_d       = DEC_SYNC;
                end else begin
                    s_rdy_d = can_push_next || !hold_vld_d;
                    fsm_d   = DEC_SYNC;
                end
            end else begin
                fsm_d = DEC_SYNC;
            end
        end

        DEC_BODY: begin
            s_rdy_d = can_push_next;
            if (s_axis_tready && s_axis_tvalid) begin
                emit_data   = hold_vld_q ? hold_byte_q : 8'd0;
                emit_vld    = hold_vld_q;
                emit_user   = hold_vld_q ? hold_err_q : 1'b0;
                hold_byte_d = s_axis_tdata;
                hold_err_d  = 1'b0;
                hold_vld_d  = 1'b1;
                rem_d       = rem_q - 8'd1;

                if (s_axis_tdata == 8'd0) begin
                    hold_byte_d = 8'd0;
                    hold_vld_d  = 1'b0;
                    emit_vld    = 1'b1;
                    emit_user   = 1'b1;
                    emit_last   = 1'b1;
                    s_rdy_d     = can_push_next;
                    fsm_d       = DEC_SYNC;
                end else if (s_axis_tlast) begin
                    if (rem_q == 8'd1 && !s_axis_tuser) begin
                        s_rdy_d = can_push_next;
                        fsm_d   = DEC_SYNC;
                    end else begin
                        hold_byte_d = 8'd0;
                        hold_vld_d  = 1'b0;
                        emit_vld    = 1'b1;
                        emit_user   = 1'b1;
                        emit_last   = 1'b1;
                        s_rdy_d     = can_push_next;
                        fsm_d       = DEC_SYNC;
                    end
                end else begin
                    s_rdy_d = can_push_next;
                    fsm_d   = (rem_q == 8'd1) ? DEC_CODE : DEC_BODY;
                end
            end else begin
                fsm_d = DEC_BODY;
            end
        end

        DEC_CODE: begin
            s_rdy_d = can_push_next;
            if (s_axis_tready && s_axis_tvalid) begin
                emit_data   = hold_vld_q ? hold_byte_q : 8'd0;
                emit_vld    = hold_vld_q;
                emit_user   = hold_vld_q ? hold_err_q : 1'b0;
                hold_byte_d = 8'd0;
                hold_err_d  = 1'b0;
                hold_vld_d  = !no_zero_q;

                if (s_axis_tdata == 8'd0) begin
                    hold_vld_d = 1'b0;
                    if (!hold_vld_q) begin
                        emit_data = 8'd0;
                        emit_vld  = 1'b1;
                        emit_user = 1'b1;
                    end else begin
                        emit_user = s_axis_tuser;
                    end
                    emit_last = 1'b1;
                    s_rdy_d   = can_push_next;
                    fsm_d     = DEC_SYNC;
                end else if (s_axis_tlast) begin
                    if (s_axis_tdata == 8'd1 && !s_axis_tuser && !no_zero_q) begin
                        s_rdy_d = can_push_next;
                        fsm_d   = DEC_SYNC;
                    end else begin
                        hold_vld_d = 1'b0;
                        emit_vld   = 1'b1;
                        emit_user  = 1'b1;
                        emit_last  = 1'b1;
                        s_rdy_d    = can_push_next;
                        fsm_d      = DEC_SYNC;
                    end
                end else begin
                    rem_d     = s_axis_tdata - 8'd1;
                    no_zero_d = (s_axis_tdata == 8'd255);
                    s_rdy_d   = can_push_next;
                    fsm_d     = (s_axis_tdata == 8'd1) ? DEC_CODE : DEC_BODY;
                end
            end else begin
                fsm_d = DEC_CODE;
            end
        end

        default: fsm_d = DEC_SYNC;
    endcase
end

always @(posedge clk) begin
    if (rst) begin
        fsm_q       <= DEC_SYNC;
        rem_q       <= 8'd0;
        no_zero_q   <= 1'b0;
        hold_byte_q <= 8'd0;
        hold_err_q  <= 1'b0;
        hold_vld_q  <= 1'b0;
        s_rdy_q     <= 1'b0;
    end else begin
        fsm_q       <= fsm_d;
        rem_q       <= rem_d;
        no_zero_q   <= no_zero_d;
        hold_byte_q <= hold_byte_d;
        hold_err_q  <= hold_err_d;
        hold_vld_q  <= hold_vld_d;
        s_rdy_q     <= s_rdy_d;
    end
end

endmodule

`resetall
