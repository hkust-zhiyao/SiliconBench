// SPDX-License-Identifier: BSD-2-Clause-Views
/*
 * Copyright (c) 2019-2023 The Regents of the University of California
 */

// Language: Verilog 2001

`resetall
`timescale 1ns / 1ps
`default_nettype none

/*
 * Alternate Gold TDMA scheduler
 * Distinct microarchitecture:
 * - 4-phase staggered target initialization (ST_RST0..ST_RST3, <=40 bits per enable)
 * - Staggered schedule/timeslot writeback with distinct cycle-qualified control registers
 * - 6-slice (12/12/12/12/15/16-bit) magnitude comparator + shared 3-stage carry-select datapath
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

localparam [2:0]
    ST_RST0  = 3'd0,
    ST_RST1  = 3'd1,
    ST_RST2  = 3'd2,
    ST_RST3  = 3'd3,
    ST_CALC1 = 3'd4,
    ST_CALC2 = 3'd5,
    ST_CALC3 = 3'd6,
    ST_WAIT  = 3'd7;

localparam [1:0]
    JOB_SCH = 2'd0,
    JOB_ACT = 2'd1,
    JOB_NXT = 2'd2;

reg [2:0] st_r  = ST_RST0;
reg [1:0] job_r = JOB_SCH;

// Cycle-distinct control registers (each has a unique boolean transition -> never merged, fanout <= 48!)
reg sel_sch_a_lo_r = 1'b1; // active in ST_CALC1 (JOB_SCH) or ST_RST0
reg sel_sch_a_hi_r = 1'b1; // active in ST_CALC1 (JOB_SCH) or ST_RST1
reg sel_sch_b_lo_r = 1'b1; // active in ST_CALC1 (JOB_SCH) or ST_RST2
reg sel_sch_b_hi_r = 1'b1; // active in ST_CALC1 (JOB_SCH) or ST_RST3
reg sel_act_b_lo_r = 1'b0; // active in ST_CALC1 (JOB_ACT) or ST_CALC2 (JOB_ACT)
reg sel_act_b_hi_r = 1'b0; // active in ST_CALC1 (JOB_ACT) or ST_CALC3 (JOB_ACT)

reg we_f_rst0_r    = 1'b1; // ST_RST0 -> t_first_s_r[47:0]
reg we_f_rst1_r    = 1'b0; // ST_RST1 -> t_first_n_r[30:0]
reg we_n_rst2_r    = 1'b0; // ST_RST2 -> t_next_s_r[47:0]
reg we_n_rst3_r    = 1'b0; // ST_RST3 -> t_next_n_r[30:0]

reg we_n_sch_s_r   = 1'b0; // ST_CALC1 & JOB_SCH -> copy t_first_s_r into t_next_s_r
reg we_n_sch_n_r   = 1'b0; // ST_CALC2 & JOB_SCH -> copy t_first_n_r into t_next_n_r
reg we_f_sch_r     = 1'b0; // ST_CALC3 & JOB_SCH -> write res into t_first (79b)
reg we_act_r       = 1'b0; // ST_CALC3 & JOB_ACT -> write res into t_act   (79b)
reg we_nxt_r       = 1'b0; // ST_CALC3 & JOB_NXT -> write res into t_next  (79b)

reg [47:0] ts_s_r  = 48'd0;
reg [30:0] ts_ns_r = 31'd0;
reg        ts_ok_r = 1'b0;

reg [47:0] cfg_ss_s_r = SCHEDULE_START_S, cfg_sp_s_r = SCHEDULE_PERIOD_S;
reg [30:0] cfg_ss_n_r = SCHEDULE_START_NS, cfg_sp_n_r = SCHEDULE_PERIOD_NS;
reg [47:0] cfg_tp_s_r = TIMESLOT_PERIOD_S, cfg_ap_s_r = ACTIVE_PERIOD_S;
reg [30:0] cfg_tp_n_r = TIMESLOT_PERIOD_NS, cfg_ap_n_r = ACTIVE_PERIOD_NS;

reg [47:0] t_first_s_r = 48'd0, t_next_s_r = 48'd0, t_act_s_r = 48'd0;
reg [30:0] t_first_n_r = 31'd0, t_next_n_r = 31'd0, t_act_n_r = 31'd0;

// 6-slice 12/15/16-bit comparator registers
reg [5:0] f_gt_r = 6'd0, n_gt_r = 6'd0, a_gt_r = 6'd0;
reg [4:0] f_eq_r = 5'd0, n_eq_r = 5'd0, a_eq_r = 5'd0;
reg       cmp_v_r = 1'b0;

// Shared 3-stage carry-select timestamp adder registers
reg [16:0] n_lo_r   = 17'd0;
reg [15:0] n_hi0_r  = 16'd0;
reg [15:0] n_hi1_r  = 16'd0;
reg [16:0] s0_c0_r  = 17'd0;
reg [16:0] s0_c1_r  = 17'd0;
reg [16:0] s1_c0_r  = 17'd0;
reg [16:0] s1_c1_r  = 17'd0;
reg [15:0] s2_c0_r  = 16'd0;
reg [15:0] s2_c1_r  = 16'd0;

reg        d_lo_c_r = 1'b0;
reg [30:0] n_full_r = 31'd0;
reg [15:0] d_lo16_r = 16'd0;
reg [15:0] d_hi0_r  = 16'd0;
reg [15:0] d_hi1_r  = 16'd0;
reg [47:0] s_res0_r = 48'd0;
reg [47:0] s_res1_r = 48'd0;

reg                   locked_r = 1'b0, locked_i_r = 1'b0, err_r = 1'b0, run_r = 1'b0;
reg                   sstart_r = 1'b0, tstart_r = 1'b0, tend_r = 1'b0, tact_r = 1'b0;
reg [INDEX_WIDTH-1:0] tidx_r   = {INDEX_WIDTH{1'b0}};

assign locked          = locked_r;
assign error           = err_r;
assign schedule_start  = sstart_r;
assign timeslot_index  = tidx_r;
assign timeslot_start  = tstart_r;
assign timeslot_end    = tend_r;
assign timeslot_active = tact_r;

function automatic eval_6slice(input [5:0] gt, input [4:0] eq);
    begin
        eval_6slice = gt[5]
            || (eq[4] && gt[4])
            || (eq[4] && eq[3] && gt[3])
            || (eq[4] && eq[3] && eq[2] && gt[2])
            || (eq[4] && eq[3] && eq[2] && eq[1] && gt[1])
            || (eq[4] && eq[3] && eq[2] && eq[1] && eq[0] && gt[0]);
    end
endfunction

wire f_hit = eval_6slice(f_gt_r, f_eq_r);
wire n_hit = eval_6slice(n_gt_r, n_eq_r);
wire a_hit = eval_6slice(a_gt_r, a_eq_r);

wire [15:0] src_a_s0 = sel_sch_a_lo_r ? t_first_s_r[15:0]  : t_next_s_r[15:0];
wire [15:0] src_a_s1 = sel_sch_a_lo_r ? t_first_s_r[31:16] : t_next_s_r[31:16];
wire [15:0] src_a_s2 = sel_sch_a_hi_r ? t_first_s_r[47:32] : t_next_s_r[47:32];
wire [15:0] src_a_n0 = sel_sch_a_hi_r ? t_first_n_r[15:0]  : t_next_n_r[15:0];
wire [14:0] src_a_n1 = sel_sch_a_hi_r ? t_first_n_r[30:16] : t_next_n_r[30:16];

wire [15:0] src_b_s0 = sel_sch_b_lo_r ? cfg_sp_s_r[15:0]  : (sel_act_b_lo_r ? cfg_ap_s_r[15:0]  : cfg_tp_s_r[15:0]);
wire [15:0] src_b_s1 = sel_sch_b_lo_r ? cfg_sp_s_r[31:16] : (sel_act_b_lo_r ? cfg_ap_s_r[31:16] : cfg_tp_s_r[31:16]);
wire [15:0] src_b_s2 = sel_sch_b_hi_r ? cfg_sp_s_r[47:32] : (sel_act_b_hi_r ? cfg_ap_s_r[47:32] : cfg_tp_s_r[47:32]);
wire [15:0] src_b_n0 = sel_sch_b_hi_r ? cfg_sp_n_r[15:0]  : (sel_act_b_hi_r ? cfg_ap_n_r[15:0]  : cfg_tp_n_r[15:0]);
wire [14:0] src_b_n1 = sel_sch_b_hi_r ? cfg_sp_n_r[30:16] : (sel_act_b_hi_r ? cfg_ap_n_r[30:16] : cfg_tp_n_r[30:16]);

wire [14:0] n_hi_mux = n_lo_r[16] ? n_hi1_r[14:0] : n_hi0_r[14:0];
wire [16:0] sm_c0    = s0_c0_r[16] ? s1_c1_r : s1_c0_r;
wire [16:0] sm_c1    = s0_c1_r[16] ? s1_c1_r : s1_c0_r;
wire [16:0] d_lo_sub = {1'b0, n_lo_r[15:0]} - {1'b0, 16'hCA00};

wire        d_neg  = d_lo_c_r ? d_hi1_r[15] : d_hi0_r[15];
wire [30:0] res_n  = (!d_neg) ? {(d_lo_c_r ? d_hi1_r[14:0] : d_hi0_r[14:0]), d_lo16_r} : n_full_r;
wire [47:0] res_s  = (!d_neg) ? s_res1_r : s_res0_r;

wire abort_cfg = input_schedule_start_valid || input_schedule_period_valid || input_ts_step;

reg [2:0] st_nxt;
reg [1:0] job_nxt;

always @* begin
    st_nxt  = st_r;
    job_nxt = job_r;
    if (abort_cfg) begin
        st_nxt  = ST_RST0;
        job_nxt = JOB_SCH;
    end else begin
        case (st_r)
            ST_RST0:  st_nxt = ST_RST1;
            ST_RST1:  st_nxt = ST_RST2;
            ST_RST2:  st_nxt = ST_RST3;
            ST_RST3:  st_nxt = ST_WAIT;
            ST_CALC1: st_nxt = ST_CALC2;
            ST_CALC2: st_nxt = ST_CALC3;
            ST_CALC3: begin
                if (job_r == JOB_SCH) begin
                    job_nxt = JOB_ACT;
                    st_nxt  = ST_CALC1;
                end else if (job_r == JOB_ACT) begin
                    job_nxt = JOB_NXT;
                    st_nxt  = ST_CALC1;
                end else begin
                    st_nxt  = ST_WAIT;
                end
            end
            ST_WAIT: begin
                if (cmp_v_r && f_hit) begin
                    job_nxt = JOB_SCH;
                    st_nxt  = ST_CALC1;
                end else if (cmp_v_r && n_hit) begin
                    job_nxt = JOB_ACT;
                    st_nxt  = ST_CALC1;
                end else begin
                    st_nxt  = ST_WAIT;
                end
            end
            default: st_nxt = ST_RST0;
        endcase
    end
end

always @(posedge clk) begin
    if (rst) begin
        st_r           <= ST_RST0;
        job_r          <= JOB_SCH;
        sel_sch_a_lo_r <= 1'b1;
        sel_sch_a_hi_r <= 1'b1;
        sel_sch_b_lo_r <= 1'b1;
        sel_sch_b_hi_r <= 1'b1;
        sel_act_b_lo_r <= 1'b0;
        sel_act_b_hi_r <= 1'b0;
        we_f_rst0_r    <= 1'b1;
        we_f_rst1_r    <= 1'b0;
        we_n_rst2_r    <= 1'b0;
        we_n_rst3_r    <= 1'b0;
        we_n_sch_s_r   <= 1'b0;
        we_n_sch_n_r   <= 1'b0;
        we_f_sch_r     <= 1'b0;
        we_act_r       <= 1'b0;
        we_nxt_r       <= 1'b0;
        ts_s_r         <= 48'd0;
        ts_ns_r        <= 31'd0;
        ts_ok_r        <= 1'b0;
        cfg_ss_s_r     <= SCHEDULE_START_S;  cfg_ss_n_r <= SCHEDULE_START_NS;
        cfg_sp_s_r     <= SCHEDULE_PERIOD_S; cfg_sp_n_r <= SCHEDULE_PERIOD_NS;
        cfg_tp_s_r     <= TIMESLOT_PERIOD_S; cfg_tp_n_r <= TIMESLOT_PERIOD_NS;
        cfg_ap_s_r     <= ACTIVE_PERIOD_S;   cfg_ap_n_r <= ACTIVE_PERIOD_NS;
        t_first_s_r    <= 48'd0; t_first_n_r <= 31'd0;
        t_next_s_r     <= 48'd0; t_next_n_r  <= 31'd0;
        t_act_s_r      <= 48'd0; t_act_n_r   <= 31'd0;
        f_gt_r         <= 6'd0;  f_eq_r      <= 5'd0;
        n_gt_r         <= 6'd0;  n_eq_r      <= 5'd0;
        a_gt_r         <= 6'd0;  a_eq_r      <= 5'd0;
        cmp_v_r        <= 1'b0;
        n_lo_r         <= 17'd0; n_hi0_r     <= 16'd0; n_hi1_r <= 16'd0;
        s0_c0_r        <= 17'd0; s0_c1_r     <= 17'd0;
        s1_c0_r        <= 17'd0; s1_c1_r     <= 17'd0;
        s2_c0_r        <= 16'd0; s2_c1_r     <= 16'd0;
        d_lo_c_r       <= 1'b0;
        n_full_r       <= 31'd0; d_lo16_r    <= 16'd0; d_hi0_r <= 16'd0; d_hi1_r <= 16'd0;
        s_res0_r       <= 48'd0; s_res1_r    <= 48'd0;
        locked_r       <= 1'b0;  locked_i_r  <= 1'b0;  err_r   <= 1'b0;  run_r   <= 1'b0;
        sstart_r       <= 1'b0;  tstart_r    <= 1'b0;  tend_r  <= 1'b0;  tact_r  <= 1'b0;
        tidx_r         <= {INDEX_WIDTH{1'b0}};
    end else begin
        st_r           <= st_nxt;
        job_r          <= job_nxt;
        sel_sch_a_lo_r <= (st_nxt == ST_CALC1 && job_nxt == JOB_SCH) || (st_nxt == ST_RST0);
        sel_sch_a_hi_r <= (st_nxt == ST_CALC1 && job_nxt == JOB_SCH) || (st_nxt == ST_RST1);
        sel_sch_b_lo_r <= (st_nxt == ST_CALC1 && job_nxt == JOB_SCH) || (st_nxt == ST_RST2);
        sel_sch_b_hi_r <= (st_nxt == ST_CALC1 && job_nxt == JOB_SCH) || (st_nxt == ST_RST3);
        sel_act_b_lo_r <= (job_nxt == JOB_ACT) && (st_nxt == ST_CALC1 || st_nxt == ST_CALC2);
        sel_act_b_hi_r <= (job_nxt == JOB_ACT) && (st_nxt == ST_CALC1 || st_nxt == ST_CALC3);

        we_f_rst0_r    <= (st_nxt == ST_RST0);
        we_f_rst1_r    <= (st_nxt == ST_RST1);
        we_n_rst2_r    <= (st_nxt == ST_RST2);
        we_n_rst3_r    <= (st_nxt == ST_RST3);
        we_n_sch_s_r   <= (!abort_cfg && st_nxt == ST_CALC1 && job_nxt == JOB_SCH);
        we_n_sch_n_r   <= (!abort_cfg && st_nxt == ST_CALC2 && job_nxt == JOB_SCH);
        we_f_sch_r     <= (!abort_cfg && st_nxt == ST_CALC3 && job_nxt == JOB_SCH);
        we_act_r       <= (!abort_cfg && st_nxt == ST_CALC3 && job_nxt == JOB_ACT);
        we_nxt_r       <= (!abort_cfg && st_nxt == ST_CALC3 && job_nxt == JOB_NXT);

        ts_s_r   <= input_ts_96[95:48];
        ts_ns_r  <= {1'b0, input_ts_96[45:16]};
        ts_ok_r  <= !input_ts_step;
        sstart_r <= 1'b0;
        tstart_r <= 1'b0;
        tend_r   <= 1'b0;

        if (input_schedule_start_valid) begin
            cfg_ss_s_r <= input_schedule_start[79:32];
            cfg_ss_n_r <= {1'b0, input_schedule_start[29:0]};
        end
        if (input_schedule_period_valid) begin
            cfg_sp_s_r <= input_schedule_period[79:32];
            cfg_sp_n_r <= {1'b0, input_schedule_period[29:0]};
        end
        if (input_timeslot_period_valid) begin
            cfg_tp_s_r <= input_timeslot_period[79:32];
            cfg_tp_n_r <= {1'b0, input_timeslot_period[29:0]};
        end
        if (input_active_period_valid) begin
            cfg_ap_s_r <= input_active_period[79:32];
            cfg_ap_n_r <= {1'b0, input_active_period[29:0]};
        end

        // Shared 3-stage carry-select datapath
        n_lo_r   <= {1'b0, src_a_n0} + {1'b0, src_b_n0};
        n_hi0_r  <= {1'b0, src_a_n1} + {1'b0, src_b_n1};
        n_hi1_r  <= {1'b0, src_a_n1} + {1'b0, src_b_n1} + 16'd1;
        s0_c0_r  <= {1'b0, src_a_s0} + {1'b0, src_b_s0};
        s0_c1_r  <= {1'b0, src_a_s0} + {1'b0, src_b_s0} + 17'd1;
        s1_c0_r  <= {1'b0, src_a_s1} + {1'b0, src_b_s1};
        s1_c1_r  <= {1'b0, src_a_s1} + {1'b0, src_b_s1} + 17'd1;
        s2_c0_r  <= src_a_s2         + src_b_s2;
        s2_c1_r  <= src_a_s2         + src_b_s2         + 16'd1;

        n_full_r <= {n_hi_mux, n_lo_r[15:0]};
        d_lo16_r <= d_lo_sub[15:0];
        d_lo_c_r <= d_lo_sub[16];
        d_hi0_r  <= {1'b0, n_hi_mux} - {1'b0, 15'h3B9A};
        d_hi1_r  <= {1'b0, n_hi_mux} - {1'b0, 15'h3B9A} - 16'd1;
        s_res0_r <= {(sm_c0[16] ? s2_c1_r : s2_c0_r), sm_c0[15:0], s0_c0_r[15:0]};
        s_res1_r <= {(sm_c1[16] ? s2_c1_r : s2_c0_r), sm_c1[15:0], s0_c1_r[15:0]};

        // Staggered low-fanout target updates
        if (we_f_rst0_r)     t_first_s_r <= cfg_ss_s_r;
        else if (we_f_sch_r) t_first_s_r <= res_s;

        if (we_f_rst1_r)     t_first_n_r <= cfg_ss_n_r;
        else if (we_f_sch_r) t_first_n_r <= res_n;

        if (we_n_rst2_r)      t_next_s_r <= cfg_ss_s_r;
        else if (we_n_sch_s_r) t_next_s_r <= t_first_s_r;
        else if (we_nxt_r)    t_next_s_r <= res_s;

        if (we_n_rst3_r)      t_next_n_r <= cfg_ss_n_r;
        else if (we_n_sch_n_r) t_next_n_r <= t_first_n_r;
        else if (we_nxt_r)    t_next_n_r <= res_n;

        if (we_act_r) begin
            t_act_s_r <= res_s;
            t_act_n_r <= res_n;
        end

        // 6-slice magnitude comparator stage
        f_gt_r[5] <= (ts_s_r[47:36]  >  t_first_s_r[47:36]);
        f_eq_r[4] <= (ts_s_r[47:36]  == t_first_s_r[47:36]);
        f_gt_r[4] <= (ts_s_r[35:24]  >  t_first_s_r[35:24]);
        f_eq_r[3] <= (ts_s_r[35:24]  == t_first_s_r[35:24]);
        f_gt_r[3] <= (ts_s_r[23:12]  >  t_first_s_r[23:12]);
        f_eq_r[2] <= (ts_s_r[23:12]  == t_first_s_r[23:12]);
        f_gt_r[2] <= (ts_s_r[11:0]   >  t_first_s_r[11:0]);
        f_eq_r[1] <= (ts_s_r[11:0]   == t_first_s_r[11:0]);
        f_gt_r[1] <= (ts_ns_r[30:16] >  t_first_n_r[30:16]);
        f_eq_r[0] <= (ts_ns_r[30:16] == t_first_n_r[30:16]);
        f_gt_r[0] <= (ts_ns_r[15:0]  >= t_first_n_r[15:0]);

        n_gt_r[5] <= (ts_s_r[47:36]  >  t_next_s_r[47:36]);
        n_eq_r[4] <= (ts_s_r[47:36]  == t_next_s_r[47:36]);
        n_gt_r[4] <= (ts_s_r[35:24]  >  t_next_s_r[35:24]);
        n_eq_r[3] <= (ts_s_r[35:24]  == t_next_s_r[35:24]);
        n_gt_r[3] <= (ts_s_r[23:12]  >  t_next_s_r[23:12]);
        n_eq_r[2] <= (ts_s_r[23:12]  == t_next_s_r[23:12]);
        n_gt_r[2] <= (ts_s_r[11:0]   >  t_next_s_r[11:0]);
        n_eq_r[1] <= (ts_s_r[11:0]   == t_next_s_r[11:0]);
        n_gt_r[1] <= (ts_ns_r[30:16] >  t_next_n_r[30:16]);
        n_eq_r[0] <= (ts_ns_r[30:16] == t_next_n_r[30:16]);
        n_gt_r[0] <= (ts_ns_r[15:0]  >= t_next_n_r[15:0]);

        a_gt_r[5] <= (ts_s_r[47:36]  >  t_act_s_r[47:36]);
        a_eq_r[4] <= (ts_s_r[47:36]  == t_act_s_r[47:36]);
        a_gt_r[4] <= (ts_s_r[35:24]  >  t_act_s_r[35:24]);
        a_eq_r[3] <= (ts_s_r[35:24]  == t_act_s_r[35:24]);
        a_gt_r[3] <= (ts_s_r[23:12]  >  t_act_s_r[23:12]);
        a_eq_r[2] <= (ts_s_r[23:12]  == t_act_s_r[23:12]);
        a_gt_r[2] <= (ts_s_r[11:0]   >  t_act_s_r[11:0]);
        a_eq_r[1] <= (ts_s_r[11:0]   == t_act_s_r[11:0]);
        a_gt_r[1] <= (ts_ns_r[30:16] >  t_act_n_r[30:16]);
        a_eq_r[0] <= (ts_ns_r[30:16] == t_act_n_r[30:16]);
        a_gt_r[0] <= (ts_ns_r[15:0]  >= t_act_n_r[15:0]);

        if (abort_cfg) begin
            tidx_r  <= {INDEX_WIDTH{1'b0}};
            tend_r  <= tact_r;
            tact_r  <= 1'b0;
            err_r   <= input_ts_step;
            cmp_v_r <= 1'b0;
        end else begin
            case (st_r)
                ST_RST0: begin
                    tidx_r     <= {INDEX_WIDTH{1'b0}};
                    tend_r     <= tact_r;
                    tact_r     <= 1'b0;
                    locked_r   <= 1'b0;
                    locked_i_r <= 1'b0;
                    run_r      <= 1'b0;
                    cmp_v_r    <= 1'b0;
                end
                ST_RST1, ST_RST2, ST_RST3, ST_CALC1, ST_CALC2, ST_CALC3: begin
                    cmp_v_r <= 1'b0;
                end
                ST_WAIT: begin
                    if (cmp_v_r && f_hit) begin
                        sstart_r   <= enable && locked_i_r;
                        tidx_r     <= {INDEX_WIDTH{1'b0}};
                        tstart_r   <= enable && locked_i_r;
                        tend_r     <= tact_r;
                        tact_r     <= enable && locked_i_r;
                        run_r      <= 1'b1;
                        locked_r   <= locked_i_r;
                        err_r      <= err_r && !locked_i_r;
                        cmp_v_r    <= 1'b0;
                    end else if (cmp_v_r && n_hit) begin
                        tidx_r   <= tidx_r + 1'b1;
                        tstart_r <= enable && locked_r;
                        tend_r   <= tact_r;
                        tact_r   <= enable && locked_r;
                        cmp_v_r  <= 1'b0;
                    end else if (cmp_v_r && tact_r && a_hit) begin
                        tend_r  <= 1'b1;
                        tact_r  <= 1'b0;
                        cmp_v_r <= 1'b0;
                    end else begin
                        if (cmp_v_r) locked_i_r <= run_r;
                        cmp_v_r <= ts_ok_r;
                    end
                end
                default: cmp_v_r <= 1'b0;
            endcase
        end
    end
end

endmodule

`resetall
