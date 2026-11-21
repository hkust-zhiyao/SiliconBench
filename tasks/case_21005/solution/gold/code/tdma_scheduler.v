// SPDX-License-Identifier: BSD-2-Clause-Views
/*
 * Copyright (c) 2019-2023 The Regents of the University of California
 */

// Language: Verilog 2001

`resetall
`timescale 1ns / 1ps
`default_nettype none

/*
 * TDMA scheduler module
 * 16-bit carry-select timestamp datapath & 5-slice registered comparator for 1.50 ns Nangate45 closure
 */
module tdma_scheduler #
(
    parameter INDEX_WIDTH = 8,
    parameter SCHEDULE_START_S = 48'h0,
    parameter SCHEDULE_START_NS = 30'h0,
    parameter SCHEDULE_PERIOD_S = 48'd0,
    parameter SCHEDULE_PERIOD_NS = 30'd1000000,
    parameter TIMESLOT_PERIOD_S = 48'd0,
    parameter TIMESLOT_PERIOD_NS = 30'd100000,
    parameter ACTIVE_PERIOD_S = 48'd0,
    parameter ACTIVE_PERIOD_NS = 30'd100000
)
(
    input  wire                   clk,
    input  wire                   rst,

    input  wire [95:0]            input_ts_96,
    input  wire                   input_ts_step,

    input  wire                   enable,
    input  wire [79:0]            input_schedule_start,
    input  wire                   input_schedule_start_valid,
    input  wire [79:0]            input_schedule_period,
    input  wire                   input_schedule_period_valid,
    input  wire [79:0]            input_timeslot_period,
    input  wire                   input_timeslot_period_valid,
    input  wire [79:0]            input_active_period,
    input  wire                   input_active_period_valid,

    output wire                   locked,
    output wire                   error,

    output wire                   schedule_start,
    output wire [INDEX_WIDTH-1:0] timeslot_index,
    output wire                   timeslot_start,
    output wire                   timeslot_end,
    output wire                   timeslot_active
);

localparam [3:0]
    STATE_IDLE       = 4'd0,
    STATE_UPD_SCH_1  = 4'd1,
    STATE_UPD_SCH_2  = 4'd2,
    STATE_UPD_SCH_3  = 4'd3,
    STATE_UPD_ACT_1  = 4'd4,
    STATE_UPD_ACT_2  = 4'd5,
    STATE_UPD_ACT_3  = 4'd6,
    STATE_UPD_NXT_1  = 4'd7,
    STATE_UPD_NXT_2  = 4'd8,
    STATE_UPD_NXT_3  = 4'd9,
    STATE_WAIT       = 4'd10;

localparam [15:0] NS_ROLL_LO = 16'hCA00; // 1_000_000_000 = 31'h3B9A_CA00
localparam [14:0] NS_ROLL_HI = 15'h3B9A;

reg [3:0]  state_reg = STATE_IDLE, state_next;

reg [47:0] time_s_reg  = 48'd0;
reg [30:0] time_ns_reg = 31'd0;
reg        time_valid_reg = 1'b0;

reg [47:0] first_slot_s_reg  = 48'd0, first_slot_s_next;
reg [30:0] first_slot_ns_reg = 31'd0, first_slot_ns_next;

reg [47:0] next_slot_s_reg  = 48'd0, next_slot_s_next;
reg [30:0] next_slot_ns_reg = 31'd0, next_slot_ns_next;

reg [47:0] active_end_s_reg  = 48'd0, active_end_s_next;
reg [30:0] active_end_ns_reg = 31'd0, active_end_ns_next;

reg [47:0] schedule_start_s_reg  = SCHEDULE_START_S;
reg [30:0] schedule_start_ns_reg = SCHEDULE_START_NS;

reg [47:0] schedule_period_s_reg  = SCHEDULE_PERIOD_S;
reg [30:0] schedule_period_ns_reg = SCHEDULE_PERIOD_NS;

reg [47:0] timeslot_period_s_reg  = TIMESLOT_PERIOD_S;
reg [30:0] timeslot_period_ns_reg = TIMESLOT_PERIOD_NS;

reg [47:0] active_period_s_reg  = ACTIVE_PERIOD_S;
reg [30:0] active_period_ns_reg = ACTIVE_PERIOD_NS;

// Stage 1: 16-bit carry-select partial sums
reg [16:0] add_ns_lo_r  = 17'd0;
reg [15:0] add_ns_hi0_r = 16'd0;
reg [15:0] add_ns_hi1_r = 16'd0;
reg [16:0] add_s0_lo_r  = 17'd0;
reg [16:0] add_s1_lo_r  = 17'd0;
reg [16:0] add_s_mid0_r = 17'd0;
reg [16:0] add_s_mid1_r = 17'd0;
reg [15:0] add_s_hi0_r  = 16'd0;
reg [15:0] add_s_hi1_r  = 16'd0;

// Stage 2: carry-resolved sum & 16-bit rollover subtraction
reg [30:0] ns_sum_r   = 31'd0;
reg [16:0] ovf_lo_r   = 17'd0;
reg [15:0] ovf_hi0_r  = 16'd0;
reg [15:0] ovf_hi1_r  = 16'd0;
reg [47:0] s_sum_c0_r = 48'd0;
reg [47:0] s_sum_c1_r = 48'd0;

// Stage 2 comparator registers (5 x 16-bit slices -> combined in Stage 3)
reg [4:0] first_gt_r = 5'd0;
reg [3:0] first_eq_r = 4'd0;
reg [4:0] next_gt_r  = 5'd0;
reg [3:0] next_eq_r  = 4'd0;
reg [4:0] act_gt_r   = 5'd0;
reg [3:0] act_eq_r   = 4'd0;
reg       cmp_valid_reg = 1'b0;

reg locked_reg           = 1'b0, locked_next;
reg locked_int_reg       = 1'b0, locked_int_next;
reg error_reg            = 1'b0, error_next;
reg schedule_running_reg = 1'b0, schedule_running_next;

reg                   schedule_start_reg  = 1'b0, schedule_start_next;
reg [INDEX_WIDTH-1:0] timeslot_index_reg  = {INDEX_WIDTH{1'b0}}, timeslot_index_next;
reg                   timeslot_start_reg  = 1'b0, timeslot_start_next;
reg                   timeslot_end_reg    = 1'b0, timeslot_end_next;
reg                   timeslot_active_reg = 1'b0, timeslot_active_next;

assign locked          = locked_reg;
assign error           = error_reg;
assign schedule_start  = schedule_start_reg;
assign timeslot_index  = timeslot_index_reg;
assign timeslot_start  = timeslot_start_reg;
assign timeslot_end    = timeslot_end_reg;
assign timeslot_active = timeslot_active_reg;

function automatic combine_5slice_ge(
    input [4:0] gt,
    input [3:0] eq
);
    begin
        combine_5slice_ge = gt[4]
            || (eq[3] && gt[3])
            || (eq[3] && eq[2] && gt[2])
            || (eq[3] && eq[2] && eq[1] && gt[1])
            || (eq[3] && eq[2] && eq[1] && eq[0] && gt[0]);
    end
endfunction

wire first_ge = combine_5slice_ge(first_gt_r, first_eq_r);
wire next_ge  = combine_5slice_ge(next_gt_r,  next_eq_r);
wire act_ge   = combine_5slice_ge(act_gt_r,   act_eq_r);

wire [14:0] ns_hi_sel  = add_ns_lo_r[16] ? add_ns_hi1_r[14:0] : add_ns_hi0_r[14:0];
wire [16:0] c0_mid_sel = add_s0_lo_r[16] ? add_s_mid1_r : add_s_mid0_r;
wire [16:0] c1_mid_sel = add_s1_lo_r[16] ? add_s_mid1_r : add_s_mid0_r;

wire        ovf_neg     = ovf_lo_r[16] ? ovf_hi1_r[15] : ovf_hi0_r[15];
wire [30:0] ns_resolved = (!ovf_neg) ? {(ovf_lo_r[16] ? ovf_hi1_r[14:0] : ovf_hi0_r[14:0]), ovf_lo_r[15:0]} : ns_sum_r;
wire [47:0] s_resolved  = (!ovf_neg) ? s_sum_c1_r : s_sum_c0_r;

reg [47:0] op_a_s, op_b_s;
reg [30:0] op_a_ns, op_b_ns;
reg        cmp_flush;

always @* begin
    state_next = STATE_IDLE;

    first_slot_s_next  = first_slot_s_reg;
    first_slot_ns_next = first_slot_ns_reg;
    next_slot_s_next   = next_slot_s_reg;
    next_slot_ns_next  = next_slot_ns_reg;
    active_end_s_next  = active_end_s_reg;
    active_end_ns_next = active_end_ns_reg;

    op_a_s  = first_slot_s_reg;
    op_a_ns = first_slot_ns_reg;
    op_b_s  = schedule_period_s_reg;
    op_b_ns = schedule_period_ns_reg;

    locked_next           = locked_reg;
    locked_int_next       = locked_int_reg;
    error_next            = error_reg;
    schedule_running_next = schedule_running_reg;

    schedule_start_next  = 1'b0;
    timeslot_index_next  = timeslot_index_reg;
    timeslot_start_next  = 1'b0;
    timeslot_end_next    = 1'b0;
    timeslot_active_next = timeslot_active_reg;
    cmp_flush            = 1'b0;

    if (input_schedule_start_valid || input_schedule_period_valid || input_ts_step) begin
        timeslot_index_next  = {INDEX_WIDTH{1'b0}};
        timeslot_start_next  = 1'b0;
        timeslot_end_next    = timeslot_active_reg;
        timeslot_active_next = 1'b0;
        error_next           = input_ts_step;
        state_next           = STATE_IDLE;
        cmp_flush            = 1'b1;
    end else begin
        case (state_reg)
            STATE_IDLE: begin
                first_slot_s_next     = schedule_start_s_reg;
                first_slot_ns_next    = schedule_start_ns_reg;
                next_slot_s_next      = schedule_start_s_reg;
                next_slot_ns_next     = schedule_start_ns_reg;
                timeslot_index_next   = {INDEX_WIDTH{1'b0}};
                timeslot_start_next   = 1'b0;
                timeslot_end_next     = timeslot_active_reg;
                timeslot_active_next  = 1'b0;
                locked_next           = 1'b0;
                locked_int_next       = 1'b0;
                schedule_running_next = 1'b0;
                state_next            = STATE_WAIT;
                cmp_flush             = 1'b1;
            end
            STATE_UPD_SCH_1: begin
                op_a_s     = first_slot_s_reg;
                op_a_ns    = first_slot_ns_reg;
                op_b_s     = schedule_period_s_reg;
                op_b_ns    = schedule_period_ns_reg;
                state_next = STATE_UPD_SCH_2;
                cmp_flush  = 1'b1;
            end
            STATE_UPD_SCH_2: begin
                state_next = STATE_UPD_SCH_3;
                cmp_flush  = 1'b1;
            end
            STATE_UPD_SCH_3: begin
                first_slot_s_next  = s_resolved;
                first_slot_ns_next = ns_resolved;
                next_slot_s_next   = first_slot_s_reg;
                next_slot_ns_next  = first_slot_ns_reg;
                state_next         = STATE_UPD_ACT_1;
                cmp_flush          = 1'b1;
            end
            STATE_UPD_ACT_1: begin
                op_a_s     = next_slot_s_reg;
                op_a_ns    = next_slot_ns_reg;
                op_b_s     = active_period_s_reg;
                op_b_ns    = active_period_ns_reg;
                state_next = STATE_UPD_ACT_2;
                cmp_flush  = 1'b1;
            end
            STATE_UPD_ACT_2: begin
                state_next = STATE_UPD_ACT_3;
                cmp_flush  = 1'b1;
            end
            STATE_UPD_ACT_3: begin
                active_end_s_next  = s_resolved;
                active_end_ns_next = ns_resolved;
                op_a_s             = next_slot_s_reg;
                op_a_ns            = next_slot_ns_reg;
                op_b_s             = timeslot_period_s_reg;
                op_b_ns            = timeslot_period_ns_reg;
                state_next         = STATE_UPD_NXT_2;
                cmp_flush          = 1'b1;
            end
            STATE_UPD_NXT_1: begin
                op_a_s     = next_slot_s_reg;
                op_a_ns    = next_slot_ns_reg;
                op_b_s     = timeslot_period_s_reg;
                op_b_ns    = timeslot_period_ns_reg;
                state_next = STATE_UPD_NXT_2;
                cmp_flush  = 1'b1;
            end
            STATE_UPD_NXT_2: begin
                state_next = STATE_UPD_NXT_3;
                cmp_flush  = 1'b1;
            end
            STATE_UPD_NXT_3: begin
                next_slot_s_next  = s_resolved;
                next_slot_ns_next = ns_resolved;
                state_next        = STATE_WAIT;
                cmp_flush         = 1'b1;
            end
            STATE_WAIT: begin
                if (cmp_valid_reg && first_ge) begin
                    schedule_start_next   = enable && locked_int_reg;
                    timeslot_index_next   = {INDEX_WIDTH{1'b0}};
                    timeslot_start_next   = enable && locked_int_reg;
                    timeslot_end_next     = timeslot_active_reg;
                    timeslot_active_next  = enable && locked_int_reg;
                    schedule_running_next = 1'b1;
                    locked_next           = locked_int_reg;
                    error_next            = error_reg && !locked_int_reg;
                    state_next            = STATE_UPD_SCH_1;
                    cmp_flush             = 1'b1;
                end else if (cmp_valid_reg && next_ge) begin
                    timeslot_index_next  = timeslot_index_reg + 1'b1;
                    timeslot_start_next  = enable && locked_reg;
                    timeslot_end_next    = timeslot_active_reg;
                    timeslot_active_next = enable && locked_reg;
                    state_next           = STATE_UPD_ACT_1;
                    cmp_flush            = 1'b1;
                end else if (cmp_valid_reg && timeslot_active_reg && act_ge) begin
                    timeslot_end_next    = 1'b1;
                    timeslot_active_next = 1'b0;
                    state_next           = STATE_WAIT;
                    cmp_flush            = 1'b1;
                end else begin
                    if (cmp_valid_reg) begin
                        locked_int_next = schedule_running_reg;
                    end
                    state_next = STATE_WAIT;
                end
            end
            default: begin
                state_next = STATE_IDLE;
                cmp_flush  = 1'b1;
            end
        endcase
    end
end

always @(posedge clk) begin
    if (rst) begin
        state_reg              <= STATE_IDLE;
        time_s_reg             <= 48'd0;
        time_ns_reg            <= 31'd0;
        time_valid_reg         <= 1'b0;
        first_slot_s_reg       <= 48'd0;
        first_slot_ns_reg      <= 31'd0;
        next_slot_s_reg        <= 48'd0;
        next_slot_ns_reg       <= 31'd0;
        active_end_s_reg       <= 48'd0;
        active_end_ns_reg      <= 31'd0;
        schedule_start_s_reg   <= SCHEDULE_START_S;
        schedule_start_ns_reg  <= SCHEDULE_START_NS;
        schedule_period_s_reg  <= SCHEDULE_PERIOD_S;
        schedule_period_ns_reg <= SCHEDULE_PERIOD_NS;
        timeslot_period_s_reg  <= TIMESLOT_PERIOD_S;
        timeslot_period_ns_reg <= TIMESLOT_PERIOD_NS;
        active_period_s_reg    <= ACTIVE_PERIOD_S;
        active_period_ns_reg   <= ACTIVE_PERIOD_NS;
        add_ns_lo_r            <= 17'd0;
        add_ns_hi0_r           <= 16'd0;
        add_ns_hi1_r           <= 16'd0;
        add_s0_lo_r            <= 17'd0;
        add_s1_lo_r            <= 17'd0;
        add_s_mid0_r           <= 17'd0;
        add_s_mid1_r           <= 17'd0;
        add_s_hi0_r            <= 16'd0;
        add_s_hi1_r            <= 16'd0;
        ns_sum_r               <= 31'd0;
        ovf_lo_r               <= 17'd0;
        ovf_hi0_r              <= 16'd0;
        ovf_hi1_r              <= 16'd0;
        s_sum_c0_r             <= 48'd0;
        s_sum_c1_r             <= 48'd0;
        first_gt_r             <= 5'd0;
        first_eq_r             <= 4'd0;
        next_gt_r              <= 5'd0;
        next_eq_r              <= 4'd0;
        act_gt_r               <= 5'd0;
        act_eq_r               <= 4'd0;
        cmp_valid_reg          <= 1'b0;
        locked_reg             <= 1'b0;
        locked_int_reg         <= 1'b0;
        error_reg              <= 1'b0;
        schedule_running_reg   <= 1'b0;
        schedule_start_reg     <= 1'b0;
        timeslot_index_reg     <= {INDEX_WIDTH{1'b0}};
        timeslot_start_reg     <= 1'b0;
        timeslot_end_reg       <= 1'b0;
        timeslot_active_reg    <= 1'b0;
    end else begin
        state_reg      <= state_next;
        time_s_reg     <= input_ts_96[95:48];
        time_ns_reg    <= {1'b0, input_ts_96[45:16]};
        time_valid_reg <= !input_ts_step;

        if (input_schedule_start_valid) begin
            schedule_start_s_reg  <= input_schedule_start[79:32];
            schedule_start_ns_reg <= {1'b0, input_schedule_start[29:0]};
        end
        if (input_schedule_period_valid) begin
            schedule_period_s_reg  <= input_schedule_period[79:32];
            schedule_period_ns_reg <= {1'b0, input_schedule_period[29:0]};
        end
        if (input_timeslot_period_valid) begin
            timeslot_period_s_reg  <= input_timeslot_period[79:32];
            timeslot_period_ns_reg <= {1'b0, input_timeslot_period[29:0]};
        end
        if (input_active_period_valid) begin
            active_period_s_reg  <= input_active_period[79:32];
            active_period_ns_reg <= {1'b0, input_active_period[29:0]};
        end

        first_slot_s_reg  <= first_slot_s_next;
        first_slot_ns_reg <= first_slot_ns_next;
        next_slot_s_reg   <= next_slot_s_next;
        next_slot_ns_reg  <= next_slot_ns_next;
        active_end_s_reg  <= active_end_s_next;
        active_end_ns_reg <= active_end_ns_next;

        // Stage 1 16-bit chunked additions
        add_ns_lo_r  <= {1'b0, op_a_ns[15:0]}  + {1'b0, op_b_ns[15:0]};
        add_ns_hi0_r <= {1'b0, op_a_ns[30:16]} + {1'b0, op_b_ns[30:16]};
        add_ns_hi1_r <= {1'b0, op_a_ns[30:16]} + {1'b0, op_b_ns[30:16]} + 16'd1;
        add_s0_lo_r  <= {1'b0, op_a_s[15:0]}   + {1'b0, op_b_s[15:0]};
        add_s1_lo_r  <= {1'b0, op_a_s[15:0]}   + {1'b0, op_b_s[15:0]}   + 17'd1;
        add_s_mid0_r <= {1'b0, op_a_s[31:16]}  + {1'b0, op_b_s[31:16]};
        add_s_mid1_r <= {1'b0, op_a_s[31:16]}  + {1'b0, op_b_s[31:16]}  + 17'd1;
        add_s_hi0_r  <= op_a_s[47:32]          + op_b_s[47:32];
        add_s_hi1_r  <= op_a_s[47:32]          + op_b_s[47:32]          + 16'd1;

        // Stage 2 carry resolution & 16-bit chunked rollover subtraction
        ns_sum_r   <= {ns_hi_sel, add_ns_lo_r[15:0]};
        ovf_lo_r   <= {1'b0, add_ns_lo_r[15:0]} - {1'b0, NS_ROLL_LO};
        ovf_hi0_r  <= {1'b0, ns_hi_sel}         - {1'b0, NS_ROLL_HI};
        ovf_hi1_r  <= {1'b0, ns_hi_sel}         - {1'b0, NS_ROLL_HI} - 16'd1;
        s_sum_c0_r <= {(c0_mid_sel[16] ? add_s_hi1_r : add_s_hi0_r), c0_mid_sel[15:0], add_s0_lo_r[15:0]};
        s_sum_c1_r <= {(c1_mid_sel[16] ? add_s_hi1_r : add_s_hi0_r), c1_mid_sel[15:0], add_s1_lo_r[15:0]};

        if (cmp_flush) begin
            cmp_valid_reg <= 1'b0;
            first_gt_r    <= 5'd0;
            first_eq_r    <= 4'd0;
            next_gt_r     <= 5'd0;
            next_eq_r     <= 4'd0;
            act_gt_r      <= 5'd0;
            act_eq_r      <= 4'd0;
        end else begin
            cmp_valid_reg <= time_valid_reg && (state_reg == STATE_WAIT);

            first_gt_r[4] <= (time_s_reg[47:32]  >  first_slot_s_reg[47:32]);
            first_eq_r[3] <= (time_s_reg[47:32]  == first_slot_s_reg[47:32]);
            first_gt_r[3] <= (time_s_reg[31:16]  >  first_slot_s_reg[31:16]);
            first_eq_r[2] <= (time_s_reg[31:16]  == first_slot_s_reg[31:16]);
            first_gt_r[2] <= (time_s_reg[15:0]   >  first_slot_s_reg[15:0]);
            first_eq_r[1] <= (time_s_reg[15:0]   == first_slot_s_reg[15:0]);
            first_gt_r[1] <= (time_ns_reg[30:16] >  first_slot_ns_reg[30:16]);
            first_eq_r[0] <= (time_ns_reg[30:16] == first_slot_ns_reg[30:16]);
            first_gt_r[0] <= (time_ns_reg[15:0]  >= first_slot_ns_reg[15:0]);

            next_gt_r[4]  <= (time_s_reg[47:32]  >  next_slot_s_reg[47:32]);
            next_eq_r[3]  <= (time_s_reg[47:32]  == next_slot_s_reg[47:32]);
            next_gt_r[3]  <= (time_s_reg[31:16]  >  next_slot_s_reg[31:16]);
            next_eq_r[2]  <= (time_s_reg[31:16]  == next_slot_s_reg[31:16]);
            next_gt_r[2]  <= (time_s_reg[15:0]   >  next_slot_s_reg[15:0]);
            next_eq_r[1]  <= (time_s_reg[15:0]   == next_slot_s_reg[15:0]);
            next_gt_r[1]  <= (time_ns_reg[30:16] >  next_slot_ns_reg[30:16]);
            next_eq_r[0]  <= (time_ns_reg[30:16] == next_slot_ns_reg[30:16]);
            next_gt_r[0]  <= (time_ns_reg[15:0]  >= next_slot_ns_reg[15:0]);

            act_gt_r[4]   <= (time_s_reg[47:32]  >  active_end_s_reg[47:32]);
            act_eq_r[3]   <= (time_s_reg[47:32]  == active_end_s_reg[47:32]);
            act_gt_r[3]   <= (time_s_reg[31:16]  >  active_end_s_reg[31:16]);
            act_eq_r[2]   <= (time_s_reg[31:16]  == active_end_s_reg[31:16]);
            act_gt_r[2]   <= (time_s_reg[15:0]   >  active_end_s_reg[15:0]);
            act_eq_r[1]   <= (time_s_reg[15:0]   == active_end_s_reg[15:0]);
            act_gt_r[1]   <= (time_ns_reg[30:16] >  active_end_ns_reg[30:16]);
            act_eq_r[0]   <= (time_ns_reg[30:16] == active_end_ns_reg[30:16]);
            act_gt_r[0]   <= (time_ns_reg[15:0]  >= active_end_ns_reg[15:0]);
        end

        locked_reg           <= locked_next;
        locked_int_reg       <= locked_int_next;
        error_reg            <= error_next;
        schedule_running_reg <= schedule_running_next;

        schedule_start_reg  <= schedule_start_next;
        timeslot_index_reg  <= timeslot_index_next;
        timeslot_start_reg  <= timeslot_start_next;
        timeslot_end_reg    <= timeslot_end_next;
        timeslot_active_reg <= timeslot_active_next;
    end
end

endmodule

`resetall
