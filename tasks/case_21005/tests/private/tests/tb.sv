`timescale 1ns / 1ps

module tb #(
    parameter integer SEED = 101
);
    integer errs = 0;
    integer rng;

    reg clk = 1'b0;
    always #2 clk = ~clk;

    initial begin
        #6_000_000;
        $display("FAIL: tb watchdog timeout!");
        $finish;
    end

    // =========================================================================
    // 1. Standalone tdma_scheduler (INDEX_WIDTH = 8)
    // =========================================================================
    reg         rst_tdma = 1'b0;
    reg  [95:0] ts96 = 96'd0;
    reg         ts_step = 1'b0;
    reg         tdma_en = 1'b1;
    reg  [79:0] in_sstart = 80'd0, in_sper = 80'd0, in_tper = 80'd0, in_aper = 80'd0;
    reg         in_sstart_v = 1'b0, in_sper_v = 1'b0, in_tper_v = 1'b0, in_aper_v = 1'b0;

    wire        tdma_locked, tdma_error, tdma_sstart, tdma_tstart, tdma_tend, tdma_tact;
    wire [7:0]  tdma_tidx;

    tdma_scheduler #(
        .INDEX_WIDTH(8),
        .SCHEDULE_START_S(48'd0),
        .SCHEDULE_START_NS(30'd1000),
        .SCHEDULE_PERIOD_S(48'd0),
        .SCHEDULE_PERIOD_NS(30'd2000),
        .TIMESLOT_PERIOD_S(48'd0),
        .TIMESLOT_PERIOD_NS(30'd800),
        .ACTIVE_PERIOD_S(48'd0),
        .ACTIVE_PERIOD_NS(30'd400)
    ) u_tdma (
        .clk(clk), .rst(rst_tdma),
        .input_ts_96(ts96), .input_ts_step(ts_step),
        .enable(tdma_en),
        .input_schedule_start(in_sstart), .input_schedule_start_valid(in_sstart_v),
        .input_schedule_period(in_sper), .input_schedule_period_valid(in_sper_v),
        .input_timeslot_period(in_tper), .input_timeslot_period_valid(in_tper_v),
        .input_active_period(in_aper), .input_active_period_valid(in_aper_v),
        .locked(tdma_locked), .error(tdma_error),
        .schedule_start(tdma_sstart), .timeslot_index(tdma_tidx),
        .timeslot_start(tdma_tstart), .timeslot_end(tdma_tend), .timeslot_active(tdma_tact)
    );

    task automatic set_ts(input [47:0] s, input [29:0] ns);
        begin
            ts96 = {s, 2'b00, ns, 16'd0};
        end
    endtask

    // =========================================================================
    // 2. Standalone tx_scheduler_ctrl_tdma (TDMA_INDEX_WIDTH=6, PIPELINE=4 -> SEGMENT_COUNT=2)
    // =========================================================================
    reg         rst_ctrl = 1'b0;
    wire [3:0]  ctrl_m_q;
    wire        ctrl_m_en, ctrl_m_v;
    reg         ctrl_m_rdy_drv = 1'b1;
    integer     ctrl_stall_cnt = 0;
    wire        ctrl_m_rdy = ctrl_m_rdy_drv && (ctrl_stall_cnt == 0);

    reg  [15:0] c_awaddr = 16'd0, c_araddr = 16'd0;
    reg         c_awvalid = 1'b0, c_wvalid = 1'b0, c_bready = 1'b1, c_arvalid = 1'b0;
    reg  [31:0] c_wdata = 32'd0;
    reg  [3:0]  c_wstrb = 4'hF;
    wire        c_awready, c_wready, c_bvalid, c_arready, c_rvalid;
    wire [1:0]  c_bresp, c_rresp;
    wire [31:0] c_rdata;
    reg         c_rready = 1'b1;

    reg         c_tdma_sstart = 1'b0, c_tdma_tstart = 1'b0, c_tdma_tend = 1'b0, c_tdma_tact = 1'b0;
    reg  [5:0]  c_tdma_tidx = 6'd0;

    tx_scheduler_ctrl_tdma #(
        .AXIL_DATA_WIDTH(32),
        .AXIL_ADDR_WIDTH(16),
        .TDMA_INDEX_WIDTH(6),
        .QUEUE_INDEX_WIDTH(4),
        .PIPELINE(4)
    ) u_ctrl (
        .clk(clk), .rst(rst_ctrl),
        .m_axis_sched_ctrl_queue(ctrl_m_q),
        .m_axis_sched_ctrl_enable(ctrl_m_en),
        .m_axis_sched_ctrl_valid(ctrl_m_v),
        .m_axis_sched_ctrl_ready(ctrl_m_rdy),
        .s_axil_awaddr(c_awaddr), .s_axil_awprot(3'd0), .s_axil_awvalid(c_awvalid), .s_axil_awready(c_awready),
        .s_axil_wdata(c_wdata), .s_axil_wstrb(c_wstrb), .s_axil_wvalid(c_wvalid), .s_axil_wready(c_wready),
        .s_axil_bresp(c_bresp), .s_axil_bvalid(c_bvalid), .s_axil_bready(c_bready),
        .s_axil_araddr(c_araddr), .s_axil_arprot(3'd0), .s_axil_arvalid(c_arvalid), .s_axil_arready(c_arready),
        .s_axil_rdata(c_rdata), .s_axil_rresp(c_rresp), .s_axil_rvalid(c_rvalid), .s_axil_rready(c_rready),
        .tdma_schedule_start(c_tdma_sstart), .tdma_timeslot_index(c_tdma_tidx),
        .tdma_timeslot_start(c_tdma_tstart), .tdma_timeslot_end(c_tdma_tend), .tdma_timeslot_active(c_tdma_tact)
    );

    reg [3:0]  ctrl_ev_q  [0:127];
    reg        ctrl_ev_en [0:127];
    integer    ctrl_ev_wr = 0, ctrl_ev_rd = 0;
    reg [31:0] rd_cap     [0:31];
    integer    rd_cap_wr = 0, rd_cap_rd = 0;

    always @(posedge clk) begin
        if (rst_ctrl) begin
            ctrl_ev_wr <= 0;
            rd_cap_wr  <= 0;
        end else begin
            if (ctrl_m_v && ctrl_m_rdy) begin
                ctrl_ev_q[ctrl_ev_wr]  <= ctrl_m_q;
                ctrl_ev_en[ctrl_ev_wr] <= ctrl_m_en;
                ctrl_ev_wr <= ctrl_ev_wr + 1;
            end
            if (c_rvalid && c_rready) begin
                rd_cap[rd_cap_wr] <= c_rdata;
                rd_cap_wr <= rd_cap_wr + 1;
            end
        end
    end

    task automatic ctrl_axil_write(input [15:0] addr, input [31:0] data, input [3:0] strb);
        reg aw_done, w_done, b_done;
        integer wd;
        begin
            aw_done = 1'b0; w_done = 1'b0; b_done = 1'b0; wd = 0;
            @(negedge clk);
            c_awaddr = addr; c_wdata = data; c_wstrb = strb;
            c_awvalid = 1'b1; c_wvalid = 1'b1;
            while (!(aw_done && w_done && b_done) && wd < 200) begin
                @(posedge clk);
                if (c_awvalid && c_awready) aw_done = 1'b1;
                if (c_wvalid  && c_wready)  w_done  = 1'b1;
                if (c_bvalid  && c_bready)  b_done  = 1'b1;
                @(negedge clk);
                if (aw_done) c_awvalid = 1'b0;
                if (w_done)  c_wvalid  = 1'b0;
                wd = wd + 1;
            end
            if (wd >= 200) begin $display("FAIL: ctrl_axil_write timeout!"); errs = errs + 1; end
        end
    endtask

    task automatic ctrl_axil_issue_ar(input [15:0] addr);
        integer wd;
        begin
            wd = 0;
            @(negedge clk);
            c_araddr  = addr;
            c_arvalid = 1'b1;
            @(posedge clk);
            while (!c_arready && wd < 200) begin @(posedge clk); wd = wd + 1; end
            if (wd >= 200) begin $display("FAIL: ctrl_axil_issue_ar timeout!"); errs = errs + 1; end
            @(negedge clk);
            c_arvalid = 1'b0;
        end
    endtask

    // =========================================================================
    // 3. End-to-End Coupled Chain: tdma_scheduler -> tx_scheduler_ctrl_tdma -> tx_scheduler_rr
    // =========================================================================
    reg         rst_e2e = 1'b0;
    reg  [95:0] e2e_ts96 = 96'd0;
    wire        e2e_locked, e2e_sstart, e2e_tstart, e2e_tend, e2e_tact;
    wire [3:0]  e2e_tidx;
    wire [3:0]  e2e_sc_q;
    wire        e2e_sc_en, e2e_sc_v, e2e_sc_rdy;

    wire [3:0]  rr_req_q;
    wire [7:0]  rr_req_tag;
    wire        rr_req_v;
    reg         rr_req_rdy = 1'b1;

    reg  [15:0] rr_st_len = 16'd0;
    reg  [7:0]  rr_st_tag = 8'd0;
    reg         rr_st_v   = 1'b0;

    reg  [3:0]  rr_db_q = 4'd0;
    reg         rr_db_v = 1'b0;

    reg  [15:0] ec_awaddr = 16'd0;
    reg         ec_awvalid = 1'b0, ec_wvalid = 1'b0;
    reg  [31:0] ec_wdata = 32'd0;
    wire        ec_awready, ec_wready, ec_bvalid;

    reg  [15:0] er_awaddr = 16'd0, er_araddr = 16'd0;
    reg         er_awvalid = 1'b0, er_wvalid = 1'b0, er_arvalid = 1'b0;
    reg  [31:0] er_wdata = 32'd0;
    reg  [3:0]  er_wstrb = 4'hF;
    wire        er_awready, er_wready, er_bvalid, er_arready, er_rvalid;
    wire [31:0] er_rdata;
    wire        rr_active;
    reg         rr_en = 1'b1;

    tdma_scheduler #(
        .INDEX_WIDTH(4),
        .SCHEDULE_START_S(48'd0),
        .SCHEDULE_START_NS(30'd500),
        .SCHEDULE_PERIOD_S(48'd0),
        .SCHEDULE_PERIOD_NS(30'd1600),
        .TIMESLOT_PERIOD_S(48'd0),
        .TIMESLOT_PERIOD_NS(30'd800),
        .ACTIVE_PERIOD_S(48'd0),
        .ACTIVE_PERIOD_NS(30'd400)
    ) u_e2e_tdma (
        .clk(clk), .rst(rst_e2e),
        .input_ts_96(e2e_ts96), .input_ts_step(1'b0),
        .enable(1'b1),
        .input_schedule_start(80'd0), .input_schedule_start_valid(1'b0),
        .input_schedule_period(80'd0), .input_schedule_period_valid(1'b0),
        .input_timeslot_period(80'd0), .input_timeslot_period_valid(1'b0),
        .input_active_period(80'd0), .input_active_period_valid(1'b0),
        .locked(e2e_locked), .error(),
        .schedule_start(e2e_sstart), .timeslot_index(e2e_tidx),
        .timeslot_start(e2e_tstart), .timeslot_end(e2e_tend), .timeslot_active(e2e_tact)
    );

    tx_scheduler_ctrl_tdma #(
        .AXIL_DATA_WIDTH(32),
        .AXIL_ADDR_WIDTH(16),
        .TDMA_INDEX_WIDTH(4),
        .QUEUE_INDEX_WIDTH(4),
        .PIPELINE(3)
    ) u_e2e_ctrl (
        .clk(clk), .rst(rst_e2e),
        .m_axis_sched_ctrl_queue(e2e_sc_q),
        .m_axis_sched_ctrl_enable(e2e_sc_en),
        .m_axis_sched_ctrl_valid(e2e_sc_v),
        .m_axis_sched_ctrl_ready(e2e_sc_rdy),
        .s_axil_awaddr(ec_awaddr), .s_axil_awprot(3'd0), .s_axil_awvalid(ec_awvalid), .s_axil_awready(ec_awready),
        .s_axil_wdata(ec_wdata), .s_axil_wstrb(4'hF), .s_axil_wvalid(ec_wvalid), .s_axil_wready(ec_wready),
        .s_axil_bresp(), .s_axil_bvalid(ec_bvalid), .s_axil_bready(1'b1),
        .s_axil_araddr(16'd0), .s_axil_arprot(3'd0), .s_axil_arvalid(1'b0), .s_axil_arready(),
        .s_axil_rdata(), .s_axil_rresp(), .s_axil_rvalid(), .s_axil_rready(1'b1),
        .tdma_schedule_start(e2e_sstart), .tdma_timeslot_index(e2e_tidx),
        .tdma_timeslot_start(e2e_tstart), .tdma_timeslot_end(e2e_tend), .tdma_timeslot_active(e2e_tact)
    );

    tx_scheduler_rr #(
        .AXIL_DATA_WIDTH(32),
        .AXIL_ADDR_WIDTH(16),
        .LEN_WIDTH(16),
        .REQ_TAG_WIDTH(8),
        .OP_TABLE_SIZE(8),
        .QUEUE_INDEX_WIDTH(4),
        .PIPELINE(3),
        .SCHED_CTRL_ENABLE(1)
    ) u_e2e_rr (
        .clk(clk), .rst(rst_e2e),
        .m_axis_tx_req_queue(rr_req_q),
        .m_axis_tx_req_tag(rr_req_tag),
        .m_axis_tx_req_valid(rr_req_v),
        .m_axis_tx_req_ready(rr_req_rdy),
        .s_axis_tx_req_status_len(rr_st_len),
        .s_axis_tx_req_status_tag(rr_st_tag),
        .s_axis_tx_req_status_valid(rr_st_v),
        .s_axis_doorbell_queue(rr_db_q),
        .s_axis_doorbell_valid(rr_db_v),
        .s_axis_sched_ctrl_queue(e2e_sc_q),
        .s_axis_sched_ctrl_enable(e2e_sc_en),
        .s_axis_sched_ctrl_valid(e2e_sc_v),
        .s_axis_sched_ctrl_ready(e2e_sc_rdy),
        .s_axil_awaddr(er_awaddr), .s_axil_awprot(3'd0), .s_axil_awvalid(er_awvalid), .s_axil_awready(er_awready),
        .s_axil_wdata(er_wdata), .s_axil_wstrb(er_wstrb), .s_axil_wvalid(er_wvalid), .s_axil_wready(er_wready),
        .s_axil_bresp(), .s_axil_bvalid(er_bvalid), .s_axil_bready(1'b1),
        .s_axil_araddr(er_araddr), .s_axil_arprot(3'd0), .s_axil_arvalid(er_arvalid), .s_axil_arready(er_arready),
        .s_axil_rdata(er_rdata), .s_axil_rresp(), .s_axil_rvalid(er_rvalid), .s_axil_rready(1'b1),
        .enable(rr_en), .active(rr_active)
    );

    task automatic ec_write(input [3:0] q, input [31:0] mask);
        reg aw_d, w_d, b_d;
        integer wd;
        begin
            aw_d = 1'b0; w_d = 1'b0; b_d = 1'b0; wd = 0;
            @(negedge clk);
            ec_awaddr = {10'd0, q, 2'b00}; ec_wdata = mask;
            ec_awvalid = 1'b1; ec_wvalid = 1'b1;
            while (!(aw_d && w_d && b_d) && wd < 200) begin
                @(posedge clk);
                if (ec_awvalid && ec_awready) aw_d = 1'b1;
                if (ec_wvalid  && ec_wready)  w_d  = 1'b1;
                if (ec_bvalid)                b_d  = 1'b1;
                @(negedge clk);
                if (aw_d) ec_awvalid = 1'b0;
                if (w_d)  ec_wvalid  = 1'b0;
                wd = wd + 1;
            end
            if (wd >= 200) begin $display("FAIL: ec_write timeout!"); errs = errs + 1; end
        end
    endtask

    task automatic rr_write(input [3:0] q, input [31:0] data);
        reg aw_d, w_d, b_d;
        integer wd;
        begin
            aw_d = 1'b0; w_d = 1'b0; b_d = 1'b0; wd = 0;
            @(negedge clk);
            er_awaddr = {10'd0, q, 2'b00}; er_wdata = data; er_wstrb = 4'hF;
            er_awvalid = 1'b1; er_wvalid = 1'b1;
            while (!(aw_d && w_d && b_d) && wd < 200) begin
                @(posedge clk);
                if (er_awvalid && er_awready) aw_d = 1'b1;
                if (er_wvalid  && er_wready)  w_d  = 1'b1;
                if (er_bvalid)                b_d  = 1'b1;
                @(negedge clk);
                if (aw_d) er_awvalid = 1'b0;
                if (w_d)  er_wvalid  = 1'b0;
                wd = wd + 1;
            end
            if (wd >= 200) begin $display("FAIL: rr_write timeout!"); errs = errs + 1; end
        end
    endtask

    reg start_ctrl_stall = 1'b0;
    always @(negedge clk) begin
        if (start_ctrl_stall)
            ctrl_stall_cnt <= 14;
        else if (ctrl_stall_cnt > 0)
            ctrl_stall_cnt <= ctrl_stall_cnt - 1;
    end

    integer i, cyc, saw_tstart, saw_tend;
    reg [7:0] cap_tag;
    initial begin
        rng = SEED;
        // Realistic power-on reset pulse (0 -> 1 -> 0)
        rst_tdma = 1'b0; rst_ctrl = 1'b0; rst_e2e = 1'b0;
        @(negedge clk);
        rst_tdma = 1'b1; rst_ctrl = 1'b1; rst_e2e = 1'b1;
        repeat (5) @(negedge clk);
        rst_tdma = 1'b0; rst_ctrl = 1'b0; rst_e2e = 1'b0;
        repeat (4) @(negedge clk);

        // =====================================================================
        // TEST 1: tdma_scheduler exact inclusive >= boundary, <=3-cycle latency & 10^9 rollover
        // =====================================================================
        // Step 1a: Pre-start (0s, 999ns) -> no lock, no start
        set_ts(48'd0, 30'd999);
        repeat (5) @(negedge clk);
        if (tdma_locked || tdma_tstart || tdma_tact) begin
            $display("FAIL [T1a]: premature trigger before 1000ns!");
            errs = errs + 1;
        end

        // Step 1b: Hold at exact first schedule_start (0s, 1000ns) -> acquires schedule_running, then 2999ns -> locked_int=1
        set_ts(48'd0, 30'd1000);
        repeat (12) @(negedge clk);
        set_ts(48'd0, 30'd2999);
        repeat (16) @(negedge clk);
        if (tdma_tstart || tdma_sstart) begin
            $display("FAIL [T1b]: premature trigger at 2999ns!");
            errs = errs + 1;
        end

        // Step 1c: Step to EXACT second schedule boundary (0s, 3000ns) and HOLD constant!
        // Must assert schedule_start & timeslot_start(idx=0) within <= 3 cycles!
        saw_tstart = 0;
        @(negedge clk);
        set_ts(48'd0, 30'd3000);
        for (cyc = 1; cyc <= 3; cyc = cyc + 1) begin
            @(posedge clk); #1;
            if (tdma_tstart && saw_tstart == 0) begin
                saw_tstart = cyc;
                if (!tdma_sstart || !tdma_locked || tdma_tidx !== 8'd0 || !tdma_tact) begin
                    $display("FAIL [T1c]: bad signals on exact 3000ns start (sstart=%b lock=%b idx=%0d act=%b)",
                             tdma_sstart, tdma_locked, tdma_tidx, tdma_tact);
                    errs = errs + 1;
                end
            end
        end
        if (saw_tstart == 0 || saw_tstart > 3) begin
            $display("FAIL [T1c]: exact >= boundary 3000ns did not fire within <=3 cycles (saw=%0d)!", saw_tstart);
            errs = errs + 1;
        end
        repeat (10) @(negedge clk); // allow slot target advance

        // Step 1d: Step to EXACT active_end boundary (0s, 3400ns) and HOLD constant!
        saw_tend = 0;
        set_ts(48'd0, 30'd3399);
        repeat (10) @(negedge clk);
        if (!tdma_tact) begin
            $display("FAIL [T1d]: timeslot_active dropped early at 3399ns!");
            errs = errs + 1;
        end
        set_ts(48'd0, 30'd3400);
        for (cyc = 1; cyc <= 3; cyc = cyc + 1) begin
            @(posedge clk); #1;
            if (tdma_tend && saw_tend == 0) saw_tend = cyc;
        end
        if (saw_tend == 0 || saw_tend > 3 || tdma_tact) begin
            $display("FAIL [T1d]: exact >= active_end 3400ns failed (saw=%0d act=%b)!", saw_tend, tdma_tact);
            errs = errs + 1;
        end

        // Step 1e: Step to EXACT next_slot boundary (0s, 3800ns) and HOLD constant!
        saw_tstart = 0;
        @(negedge clk);
        set_ts(48'd0, 30'd3800);
        for (cyc = 1; cyc <= 3; cyc = cyc + 1) begin
            @(posedge clk); #1;
            if (tdma_tstart && saw_tstart == 0) begin
                saw_tstart = cyc;
                if (tdma_tidx !== 8'd1 || !tdma_tact) begin
                    $display("FAIL [T1e]: expected slot 1 active on 3800ns, got idx=%0d act=%b", tdma_tidx, tdma_tact);
                    errs = errs + 1;
                end
            end
        end
        if (saw_tstart == 0 || saw_tstart > 3) begin
            $display("FAIL [T1e]: exact >= next_slot 3800ns failed (saw=%0d)!", saw_tstart);
            errs = errs + 1;
        end

        // Step 1f: 1_000_000_000 ns rollover + 48-bit carry across 0x0001_FFFF_FFFF -> 0x0002_0000_0000!
        @(negedge clk);
        in_sstart = {48'h0001_FFFF_FFFF, 2'b00, 30'd999_999_400}; in_sstart_v = 1'b1;
        in_sper   = {48'd0,              2'b00, 30'd1000};        in_sper_v   = 1'b1;
        in_tper   = {48'd0,              2'b00, 30'd500};         in_tper_v   = 1'b1;
        in_aper   = {48'd0,              2'b00, 30'd250};         in_aper_v   = 1'b1;
        @(negedge clk);
        in_sstart_v = 1'b0; in_sper_v = 1'b0; in_tper_v = 1'b0; in_aper_v = 1'b0;

        set_ts(48'h0001_FFFF_FFFF, 30'd999_999_400);
        repeat (12) @(negedge clk);
        set_ts(48'h0002_0000_0000, 30'd399);
        repeat (14) @(negedge clk);
        if (tdma_sstart || tdma_tstart) begin
            $display("FAIL [T1f]: rollover fired early at 399ns!");
            errs = errs + 1;
        end
        saw_tstart = 0;
        set_ts(48'h0002_0000_0000, 30'd400);
        for (cyc = 1; cyc <= 3; cyc = cyc + 1) begin
            @(posedge clk); #1;
            if (tdma_sstart && tdma_tstart && saw_tstart == 0) saw_tstart = cyc;
        end
        if (saw_tstart == 0 || saw_tstart > 3) begin
            $display("FAIL [T1f]: 10^9 ns + 48b carry rollover failed at exact (0x2_0000_0000, 400ns) (saw=%0d)!", saw_tstart);
            errs = errs + 1;
        end

        // Step 1g: input_ts_step error assertion & clean recovery
        @(negedge clk);
        ts_step = 1'b1;
        @(negedge clk);
        ts_step = 1'b0;
        repeat (2) @(negedge clk);
        if (!tdma_error || tdma_locked || tdma_tact) begin
            $display("FAIL [T1g]: input_ts_step did not assert error / drop lock!");
            errs = errs + 1;
        end

        // =====================================================================
        // TEST 2: tx_scheduler_ctrl_tdma (PIPELINE=4, SEGMENT_COUNT=2)
        // =====================================================================
        // Clear all 16 queues (each queue is 8 bytes = 2 segments at addr q*8 + 0 and q*8 + 4)
        for (i = 0; i < 16; i = i + 1) begin
            ctrl_axil_write(i[15:0] * 16'd8 + 16'd0, 32'h0000_0000, 4'hF);
            ctrl_axil_write(i[15:0] * 16'd8 + 16'd4, 32'h0000_0000, 4'hF);
        end
        // Program slot 0 -> queues {1, 4, 9, 13}; slot 1 -> queues {2, 9, 14}; slot 35 (seg 1 bit 3) -> queues {5, 11}
        ctrl_axil_write(1  * 8 + 0, 32'h0000_0001, 4'hF);
        ctrl_axil_write(2  * 8 + 0, 32'h0000_0002, 4'hF);
        ctrl_axil_write(4  * 8 + 0, 32'h0000_0001, 4'hF);
        ctrl_axil_write(5  * 8 + 4, 32'h0000_0008, 4'hF); // slot 35
        ctrl_axil_write(9  * 8 + 0, 32'h0000_0003, 4'hF); // slots 0 and 1
        ctrl_axil_write(11 * 8 + 4, 32'h0000_0008, 4'hF); // slot 35
        ctrl_axil_write(13 * 8 + 0, 32'h0000_0001, 4'hF);
        ctrl_axil_write(14 * 8 + 0, 32'h0000_0002, 4'hF);

        // Test 2a: PIPELINE=4 AXI4-Lite read pipeline under s_axil_rready=0 backpressure
        // (supports both lockstep-stalling and bubble-collapsing pipelines without losing in-flight reads!)
        @(negedge clk);
        c_rready = 1'b0;
        ctrl_axil_issue_ar(1  * 8 + 0); // exp 0x0000_0001 (in-flight 1)
        ctrl_axil_issue_ar(5  * 8 + 4); // exp 0x0000_0008 (in-flight 2, seg 1)
        // Present AR #3 while c_rready=0 for 8 cycles; reassert c_rready=1 before requiring AR #3 completion
        @(negedge clk);
        c_araddr  = 9 * 8 + 0;          // exp 0x0000_0003
        c_arvalid = 1'b1;
        begin : blk_2a_ar3
            reg ar3_done;
            ar3_done = 1'b0;
            for (cyc = 0; cyc < 8; cyc = cyc + 1) begin
                @(posedge clk);
                if (c_arvalid && c_arready) ar3_done = 1'b1;
                @(negedge clk);
                if (ar3_done) c_arvalid = 1'b0;
            end
            c_rready = 1'b1;
            cyc = 0;
            while (!ar3_done && cyc < 200) begin
                @(posedge clk);
                if (c_arvalid && c_arready) ar3_done = 1'b1;
                @(negedge clk);
                if (ar3_done) c_arvalid = 1'b0;
                cyc = cyc + 1;
            end
        end
        ctrl_axil_issue_ar(11 * 8 + 4); // exp 0x0000_0008 (seg 1)
        ctrl_axil_issue_ar(14 * 8 + 0); // exp 0x0000_0002
        cyc = 0; while ((rd_cap_wr - rd_cap_rd) < 5 && cyc < 300) begin @(negedge clk); cyc = cyc + 1; end
        if (cyc >= 300 || rd_cap[rd_cap_rd+0] !== 32'h1 || rd_cap[rd_cap_rd+1] !== 32'h8 ||
            rd_cap[rd_cap_rd+2] !== 32'h3 || rd_cap[rd_cap_rd+3] !== 32'h8 ||
            rd_cap[rd_cap_rd+4] !== 32'h2) begin
            $display("FAIL [T2a]: PIPELINE=4 AXI-Lite stalled reads corrupted: %h %h %h %h %h",
                     rd_cap[rd_cap_rd+0], rd_cap[rd_cap_rd+1], rd_cap[rd_cap_rd+2], rd_cap[rd_cap_rd+3], rd_cap[rd_cap_rd+4]);
            errs = errs + 1;
        end
        rd_cap_rd = rd_cap_rd + 5;

        // Wait for initial scan after AXI-Lite writes
        repeat (25) @(negedge clk);

        // Test 2b: Overlapping tdma_timeslot_end AND next tdma_timeslot_start(idx=1) while STATE_START_0 is stalled by m_axis_sched_ctrl_ready=0!
        start_ctrl_stall = 1'b1;
        @(negedge clk);
        start_ctrl_stall = 1'b0;
        c_tdma_tidx = 6'd0; c_tdma_tstart = 1'b1; c_tdma_sstart = 1'b1;
        @(negedge clk);
        c_tdma_tstart = 1'b0; c_tdma_sstart = 1'b0;
        while (ctrl_stall_cnt > 0) @(negedge clk);
        cyc = 0; while ((ctrl_ev_wr - ctrl_ev_rd) < 4 && cyc < 300) begin @(negedge clk); cyc = cyc + 1; end
        @(negedge clk); c_tdma_tend = 1'b1;
        @(negedge clk); c_tdma_tend = 1'b0;
        cyc = 0; while ((ctrl_ev_wr - ctrl_ev_rd) < 8 && cyc < 300) begin @(negedge clk); cyc = cyc + 1; end
        if (cyc >= 300) begin $display("FAIL [T2b-init]: slot 0 warmup timeout!"); errs = errs + 1; end
        ctrl_ev_rd = ctrl_ev_wr;
        repeat (22) @(negedge clk); // ST_SCAN completes for slot 0 & slot 1!

        // NOW consistent! Fire slot 0 while ctrl_m_rdy=0, and while STATE_START_0 is stalled mid-burst, fire tdma_timeslot_end AND tdma_timeslot_start(idx=1)!
        start_ctrl_stall = 1'b1;
        @(negedge clk);
        start_ctrl_stall = 1'b0;
        c_tdma_tidx = 6'd0; c_tdma_tstart = 1'b1;
        @(negedge clk);
        c_tdma_tstart = 1'b0;
        repeat (4) @(negedge clk); // inside stalled STATE_START_0!
        c_tdma_tend = 1'b1;
        @(negedge clk);
        c_tdma_tend = 1'b0;
        repeat (2) @(negedge clk); // still stalled in STATE_START_0!
        c_tdma_tidx = 6'd1; c_tdma_tstart = 1'b1;
        @(negedge clk);
        c_tdma_tstart = 1'b0;

        // Expect: 4 enables for slot 0 ({1,4,9,13}), 4 disables for slot 0 ({1,4,9,13}), THEN 3 enables for slot 1 ({2,9,14}) = 11 events!
        cyc = 0; while ((ctrl_ev_wr - ctrl_ev_rd) < 11 && cyc < 400) begin @(negedge clk); cyc = cyc + 1; end
        if (cyc >= 400) begin
            $display("FAIL [T2b]: timeout waiting for 11 events (got %0d)!", ctrl_ev_wr - ctrl_ev_rd);
            errs = errs + 1;
        end else begin
            for (i = 0; i < 4; i = i + 1) begin
                if (ctrl_ev_en[ctrl_ev_rd + i] !== 1'b1) errs = errs + 1;
                if (ctrl_ev_en[ctrl_ev_rd + 4 + i] !== 1'b0) errs = errs + 1;
            end
            if (ctrl_ev_q[ctrl_ev_rd+8] !== 4'd2 || ctrl_ev_q[ctrl_ev_rd+9] !== 4'd9 || ctrl_ev_q[ctrl_ev_rd+10] !== 4'd14 ||
                !ctrl_ev_en[ctrl_ev_rd+8] || !ctrl_ev_en[ctrl_ev_rd+9] || !ctrl_ev_en[ctrl_ev_rd+10]) begin
                $display("FAIL [T2b]: overlapping timeslot_start(1) during stalled START_0 dropped or corrupted!");
                errs = errs + 1;
            end
        end
        ctrl_ev_rd = ctrl_ev_wr;

        // End slot 1, and simultaneously trigger non-sequential slot 35 (segment 1) + live AXI-Lite write rescan!
        ctrl_axil_write(7 * 8 + 4, 32'h0000_0008, 4'hF); // add queue 7 to slot 35 (sets inconsistent!)
        @(negedge clk);
        c_tdma_tend = 1'b1; c_tdma_tidx = 6'd35; c_tdma_tstart = 1'b1;
        @(negedge clk);
        c_tdma_tend = 1'b0; c_tdma_tstart = 1'b0;
        // Expect: 3 disables for slot 1 ({2,9,14}) + 3 enables for slot 35 ({5,7,11}) = 6 events!
        cyc = 0; while ((ctrl_ev_wr - ctrl_ev_rd) < 6 && cyc < 400) begin @(negedge clk); cyc = cyc + 1; end
        if (cyc >= 400 || ctrl_ev_q[ctrl_ev_rd+3] !== 4'd5 || ctrl_ev_q[ctrl_ev_rd+4] !== 4'd7 || ctrl_ev_q[ctrl_ev_rd+5] !== 4'd11 ||
            !ctrl_ev_en[ctrl_ev_rd+3] || !ctrl_ev_en[ctrl_ev_rd+4] || !ctrl_ev_en[ctrl_ev_rd+5]) begin
            $display("FAIL [T2c]: inconsistent rescan + slot 35 enables failed: got %0d,%0d,%0d (cnt=%0d)",
                     ctrl_ev_q[ctrl_ev_rd+3], ctrl_ev_q[ctrl_ev_rd+4], ctrl_ev_q[ctrl_ev_rd+5], ctrl_ev_wr - ctrl_ev_rd);
            errs = errs + 1;
        end
        ctrl_ev_rd = ctrl_ev_wr;

        // =====================================================================
        // TEST 3: End-to-End Coupled Chain & tx_scheduler_rr Completion Gating
        // =====================================================================
        repeat (30) @(negedge clk); // ensure u_e2e_rr internal init is complete

        // 3a. Disabled-queue completion gating: q2 has global_enable=1 & enabled=1 initially, issues TX req,
        // then software disables q2 (wdata=0x02: enabled=0, global_enable=1) BEFORE status completion (len!=0) arrives!
        rr_req_rdy = 1'b0;
        rr_write(4'd2, 32'h0000_0003); // enabled=1, global_enable=1
        @(negedge clk);
        rr_db_q = 4'd2; rr_db_v = 1'b1;
        @(negedge clk);
        rr_db_v = 1'b0;
        cyc = 0; while (!rr_req_v && cyc < 200) begin @(posedge clk); cyc = cyc + 1; end
        if (cyc >= 200 || rr_req_q !== 4'd2) begin
            $display("FAIL [T3a]: expected req for q2, got %0d", rr_req_q);
            errs = errs + 1;
        end
        cap_tag = rr_req_tag;
        // Disable q2 while only 1 op (cap_tag) is allocated, then accept cap_tag and let RR pop & deschedule q2!
        rr_write(4'd2, 32'h0000_0002);
        @(negedge clk);
        rr_req_rdy = 1'b1;
        repeat (12) @(negedge clk);
        // Pause op_req (rr_en=0) so an illegal reschedule on op_complete cannot silently pop & clear scheduled!
        rr_en = 1'b0;
        @(negedge clk);
        // Complete in-flight op with remaining work (len=64 != 0)! Must NOT reschedule disabled q2!
        rr_st_tag = cap_tag; rr_st_len = 16'd64; rr_st_v = 1'b1;
        @(negedge clk);
        rr_st_v = 1'b0;
        repeat (12) @(negedge clk);
        if (rr_active !== 1'b0) begin
            $display("FAIL [T3a]: disabled queue q2 illegally incremented active_queue_count (rr_active=1) on op_complete!");
            errs = errs + 1;
        end
        er_araddr = 16'd8; er_arvalid = 1'b1;
        cyc = 0; while (!(er_arvalid && er_arready) && cyc < 100) begin @(posedge clk); cyc = cyc + 1; end
        @(negedge clk); er_arvalid = 1'b0;
        cyc = 0; while (!er_rvalid && cyc < 100) begin @(posedge clk); cyc = cyc + 1; end
        if (cyc >= 100 || er_rdata[24] !== 1'b0) begin
            $display("FAIL [T3a]: disabled queue q2 was illegally marked scheduled (rdata=0x%08x) on op_complete!", er_rdata);
            errs = errs + 1;
        end
        @(negedge clk);
        rr_en = 1'b1;
        repeat (12) @(negedge clk);
        rr_write(4'd2, 32'h0000_0000);
        repeat (8) @(negedge clk);

        // 3b. Stored global_enable=1 completion rescheduling when sched_enable=0!
        // Configure q5 with enabled=1, global_enable=1 (0x03). Hold rr_req_rdy=1, issue 1st req,
        // then temporarily clear enabled->re-enable with global_enable=1 while active=0? Wait:
        // How does a queue become unscheduled while an op is in-flight?
        // Temporarily close gate: set q5 to enabled=1, global_enable=0 (0x01) + sched_enable=0 so RR deschedules q5,
        // THEN write q5 to enabled=1, global_enable=1 (0x03) while q_active==0 (because doorbell was consumed? Wait: q_active stays 1 until op_complete(len=0)!).
        // Let's trace: if q5 has enabled=1, global_enable=0, and TDMA slot 0 opens sched_enable=1:
        // 1) Ring doorbell on q5 while slot 0 is active -> q5 schedules and emits req1 (tag=cap_tag).
        // 2) TDMA slot 0 ends -> sched_enable becomes 0 -> RR pops q5 and DESCHEDULES q5 (q_scheduled becomes 0, q_active is still 1!).
        // 3) Now write q6 (a DIFFERENT queue!) via AXI-Lite with wdata=0x00 so write_data_pipeline_reg[PIPELINE-1][1] is 0!
        //    Wait: for q5 to have global_enable=1 and q_scheduled=0:
        //    First complete req1 with len=0 so q_active becomes 0! Wait: if req1 is still in-flight?
        //    Even simpler! Look:
        //    Step i: q5 has enabled=0, global_enable=1 (`rr_write(5, 0x02)` -> active=0, scheduled=0).
        //    Wait: get req1 in-flight FIRST (`rr_write(5, 0x03)` -> doorbell -> req1 emitted!).
        //    Step ii: `rr_write(5, 0x00)` -> RR pops q5 and deschedules q5 (`q_scheduled=0`)!
        //    Step iii: Complete a dummy op or clear q5 active? No! If we write `rr_write(5, 0x02)`? No, `q_active` is still 1 so `rr_write(5, 0x03)` would schedule it in `op_axil_write` UNLESS `write_strobe[0]`... wait: what if `q_active == 0` when `rr_write(5, 0x03)` runs?!
        //    HOW CAN `q_active == 0` WHILE `req1` IS IN-FLIGHT?!
        //    LOOK AT `tx_scheduler_rr`!
        //    1) `rr_write(5, 0x03)` (enabled=1, global_enable=1). Doorbell q5 -> `req1` (tagA) emitted!
        //    2) Doorbell q5 AGAIN or let `req2` (tagB) also be emitted (`OP_TABLE_SIZE=8`)!
        //    3) Complete `req1` (tagA) with `len = 0`! `op_complete` for tagA sets `queue_ram_write_data[6] = 1'b0` (`q_active = 0`!)!!
        //    4) Next cycle, RR pops q5 -> sees `q_active == 0` -> DESCHEDULES q5 (`q_scheduled = 0`)!!
        //    5) Flush `write_data_pipeline_reg` with `rr_write(6, 32'h0000_0000)` (`write_data_pipeline_reg[*][1] == 0`!)!
        //    6) NOW `req2` (tagB) completes with `len = 128` (`len != 0`) while `q5` has `enabled=1, global_enable=1, sched_enable=0, q_active=0, q_scheduled=0`!!
        //       Baseline checks `write_data_pipeline_reg[PIPELINE-1][1]` (which is `0`!) instead of `queue_ram_read_data_global_enable` (`1`!), so baseline FAILS to reschedule `q5`, whereas Gold/Alt-Gold checks `global_enable` (`1`) and IMMEDIATELY reschedules `q5`!!
        rr_write(4'd5, 32'h0000_0003); // enabled=1, global_enable=1, sched_enable=0
        @(negedge clk); rr_db_q = 4'd5; rr_db_v = 1'b1;
        @(negedge clk); rr_db_v = 1'b0;
        // Capture two consecutive TX requests (tagA and tagB) for q5
        cyc = 0; while (!rr_req_v && cyc < 200) begin @(posedge clk); cyc = cyc + 1; end
        cap_tag = rr_req_tag; // tagA
        @(posedge clk);
        cyc = 0; while (!rr_req_v && cyc < 200) begin @(posedge clk); cyc = cyc + 1; end
        begin : blk_3b
            reg [7:0] tag_b;
            integer got_resched;
            tag_b = rr_req_tag;
            @(negedge clk);
            rr_req_rdy = 1'b0; // pause further reqs while tagA completes with len=0
            rr_st_tag = cap_tag; rr_st_len = 16'd0; rr_st_v = 1'b1;
            @(negedge clk);
            rr_st_v = 1'b0;
            repeat (8) @(negedge clk);
            rr_req_rdy = 1'b1; // allow RR to pop & deschedule q5 (since q_active==0 now), draining any already-registered req
            repeat (12) @(negedge clk);
            rr_write(4'd6, 32'h0000_0000); // ensure write_data_pipeline_reg[*][1] == 0!
            repeat (8) @(negedge clk);

            // Now complete tagB with len=128 != 0! q5 MUST reschedule via stored global_enable=1!
            @(negedge clk);
            rr_st_tag = tag_b; rr_st_len = 16'd128; rr_st_v = 1'b1;
            @(negedge clk);
            rr_st_v = 1'b0;

            got_resched = 0;
            for (cyc = 0; cyc < 20; cyc = cyc + 1) begin
                @(posedge clk);
                if (rr_req_v && rr_req_q === 4'd5) got_resched = 1;
            end
            if (!got_resched) begin
                $display("FAIL [T3b]: q5 with global_enable=1 & sched_enable=0 failed to reschedule on op_complete(len>0)!");
                errs = errs + 1;
            end
            // Cleanly finish q5 with len=0
            @(negedge clk);
            rr_st_tag = rr_req_tag; rr_st_len = 16'd0; rr_st_v = 1'b1;
            @(negedge clk);
            rr_st_v = 1'b0;
            repeat (12) @(negedge clk);
        end

        // 3c. End-to-end PTP -> TDMA -> Gate -> RR flow on q8 (enabled=1, global_enable=0, mapped to TDMA slot 0)
        ec_write(4'd8, 32'h0000_0001); // map q8 to TDMA slot 0
        rr_write(4'd8, 32'h0000_0001); // enabled=1, global_enable=0
        repeat (22) @(negedge clk);
        @(negedge clk); rr_db_q = 4'd8; rr_db_v = 1'b1;
        @(negedge clk); rr_db_v = 1'b0;
        repeat (10) @(posedge clk) begin
            if (rr_req_v && rr_req_q === 4'd8) begin
                $display("FAIL [T3c]: q8 scheduled before TDMA timeslot 0 opened!");
                errs = errs + 1;
            end
        end
        // Lock e2e_tdma across 500ns -> 2100ns!
        @(negedge clk); e2e_ts96 = {48'd0, 2'b00, 30'd500, 16'd0};
        repeat (18) @(negedge clk);
        e2e_ts96 = {48'd0, 2'b00, 30'd2100, 16'd0};
        saw_tstart = 0;
        for (cyc = 0; cyc < 60; cyc = cyc + 1) begin
            @(posedge clk);
            if (rr_req_v && rr_req_q === 4'd8) saw_tstart = 1;
        end
        if (!saw_tstart) begin
            $display("FAIL [T3c]: end-to-end PTP->TDMA->Ctrl->RR failed to schedule q8 on slot 0!");
            errs = errs + 1;
        end

        if (errs == 0)
            $display("PASS seed=%0d", SEED);
        else
            $display("FAIL seed=%0d errs=%0d", SEED, errs);
        $finish;
    end
endmodule
