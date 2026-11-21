`timescale 1ns / 1ps

module tb_gl;
    integer errs = 0;
    reg clk = 1'b0;
    always #2 clk = ~clk;

    initial begin
        #2_000_000;
        $display("FAIL: tb_gl watchdog timeout!");
        $finish;
    end

    reg         rst = 1'b0;
    reg         mon_en = 1'b0;
    reg  [95:0] ts96 = 96'd0;
    reg         req_rdy = 1'b1;

    reg  [15:0] st_len = 16'd0;
    reg  [7:0]  st_tag = 8'd0;
    reg         st_v   = 1'b0;
    reg  [2:0]  db_q   = 3'd0;
    reg         db_v   = 1'b0;

    reg  [15:0] c_awaddr = 16'd0;
    reg         c_awvalid = 1'b0, c_wvalid = 1'b0;
    reg  [31:0] c_wdata = 32'd0;

    reg  [15:0] r_awaddr = 16'd0;
    reg         r_awvalid = 1'b0, r_wvalid = 1'b0;
    reg  [31:0] r_wdata = 32'd0;

    // RTL chain wires
    wire        locked_rtl, err_rtl, sstart_rtl, tstart_rtl, tend_rtl, tact_rtl;
    wire [2:0]  tidx_rtl;
    wire [2:0]  sc_q_rtl;
    wire        sc_en_rtl, sc_v_rtl, sc_rdy_rtl;
    wire        c_awr_rtl, c_wr_rtl, c_bv_rtl;
    wire        r_awr_rtl, r_wr_rtl, r_bv_rtl;
    wire [2:0]  req_q_rtl;
    wire [7:0]  req_tag_rtl;
    wire        req_v_rtl, act_rtl;

    // Gate-level chain wires
    wire        locked_gl, err_gl, sstart_gl, tstart_gl, tend_gl, tact_gl;
    wire [2:0]  tidx_gl;
    wire [2:0]  sc_q_gl;
    wire        sc_en_gl, sc_v_gl, sc_rdy_gl;
    wire        c_awr_gl, c_wr_gl, c_bv_gl;
    wire        r_awr_gl, r_wr_gl, r_bv_gl;
    wire [2:0]  req_q_gl;
    wire [7:0]  req_tag_gl;
    wire        req_v_gl, act_gl;

    tdma_scheduler #(
        .INDEX_WIDTH(3), .SCHEDULE_START_S(48'd0), .SCHEDULE_START_NS(30'd400),
        .SCHEDULE_PERIOD_S(48'd0), .SCHEDULE_PERIOD_NS(30'd1200),
        .TIMESLOT_PERIOD_S(48'd0), .TIMESLOT_PERIOD_NS(30'd600),
        .ACTIVE_PERIOD_S(48'd0), .ACTIVE_PERIOD_NS(30'd300)
    ) u_tdma_rtl (
        .clk(clk), .rst(rst), .input_ts_96(ts96), .input_ts_step(1'b0), .enable(1'b1),
        .input_schedule_start(80'd0), .input_schedule_start_valid(1'b0),
        .input_schedule_period(80'd0), .input_schedule_period_valid(1'b0),
        .input_timeslot_period(80'd0), .input_timeslot_period_valid(1'b0),
        .input_active_period(80'd0), .input_active_period_valid(1'b0),
        .locked(locked_rtl), .error(err_rtl), .schedule_start(sstart_rtl),
        .timeslot_index(tidx_rtl), .timeslot_start(tstart_rtl), .timeslot_end(tend_rtl), .timeslot_active(tact_rtl)
    );

    tdma_scheduler_gl u_tdma_gl (
        .clk(clk), .rst(rst), .input_ts_96(ts96), .input_ts_step(1'b0), .enable(1'b1),
        .input_schedule_start(80'd0), .input_schedule_start_valid(1'b0),
        .input_schedule_period(80'd0), .input_schedule_period_valid(1'b0),
        .input_timeslot_period(80'd0), .input_timeslot_period_valid(1'b0),
        .input_active_period(80'd0), .input_active_period_valid(1'b0),
        .locked(locked_gl), .error(err_gl), .schedule_start(sstart_gl),
        .timeslot_index(tidx_gl), .timeslot_start(tstart_gl), .timeslot_end(tend_gl), .timeslot_active(tact_gl)
    );

    tx_scheduler_ctrl_tdma #(
        .AXIL_DATA_WIDTH(32), .AXIL_ADDR_WIDTH(16), .TDMA_INDEX_WIDTH(3), .QUEUE_INDEX_WIDTH(3), .PIPELINE(3)
    ) u_ctrl_rtl (
        .clk(clk), .rst(rst),
        .m_axis_sched_ctrl_queue(sc_q_rtl), .m_axis_sched_ctrl_enable(sc_en_rtl),
        .m_axis_sched_ctrl_valid(sc_v_rtl), .m_axis_sched_ctrl_ready(sc_rdy_rtl),
        .s_axil_awaddr(c_awaddr), .s_axil_awprot(3'd0), .s_axil_awvalid(c_awvalid), .s_axil_awready(c_awr_rtl),
        .s_axil_wdata(c_wdata), .s_axil_wstrb(4'hF), .s_axil_wvalid(c_wvalid), .s_axil_wready(c_wr_rtl),
        .s_axil_bresp(), .s_axil_bvalid(c_bv_rtl), .s_axil_bready(1'b1),
        .s_axil_araddr(16'd0), .s_axil_arprot(3'd0), .s_axil_arvalid(1'b0), .s_axil_arready(),
        .s_axil_rdata(), .s_axil_rresp(), .s_axil_rvalid(), .s_axil_rready(1'b1),
        .tdma_schedule_start(sstart_rtl), .tdma_timeslot_index(tidx_rtl),
        .tdma_timeslot_start(tstart_rtl), .tdma_timeslot_end(tend_rtl), .tdma_timeslot_active(tact_rtl)
    );

    tx_scheduler_ctrl_tdma_gl u_ctrl_gl (
        .clk(clk), .rst(rst),
        .m_axis_sched_ctrl_queue(sc_q_gl), .m_axis_sched_ctrl_enable(sc_en_gl),
        .m_axis_sched_ctrl_valid(sc_v_gl), .m_axis_sched_ctrl_ready(sc_rdy_gl),
        .s_axil_awaddr(c_awaddr), .s_axil_awprot(3'd0), .s_axil_awvalid(c_awvalid), .s_axil_awready(c_awr_gl),
        .s_axil_wdata(c_wdata), .s_axil_wstrb(4'hF), .s_axil_wvalid(c_wvalid), .s_axil_wready(c_wr_gl),
        .s_axil_bresp(), .s_axil_bvalid(c_bv_gl), .s_axil_bready(1'b1),
        .s_axil_araddr(16'd0), .s_axil_arprot(3'd0), .s_axil_arvalid(1'b0), .s_axil_arready(),
        .s_axil_rdata(), .s_axil_rresp(), .s_axil_rvalid(), .s_axil_rready(1'b1),
        .tdma_schedule_start(sstart_gl), .tdma_timeslot_index(tidx_gl),
        .tdma_timeslot_start(tstart_gl), .tdma_timeslot_end(tend_gl), .tdma_timeslot_active(tact_gl)
    );

    tx_scheduler_rr #(
        .AXIL_DATA_WIDTH(32), .AXIL_ADDR_WIDTH(16), .LEN_WIDTH(16), .REQ_TAG_WIDTH(8),
        .OP_TABLE_SIZE(8), .QUEUE_INDEX_WIDTH(3), .PIPELINE(3), .SCHED_CTRL_ENABLE(1)
    ) u_rr_rtl (
        .clk(clk), .rst(rst),
        .m_axis_tx_req_queue(req_q_rtl), .m_axis_tx_req_tag(req_tag_rtl),
        .m_axis_tx_req_valid(req_v_rtl), .m_axis_tx_req_ready(req_rdy),
        .s_axis_tx_req_status_len(st_len), .s_axis_tx_req_status_tag(st_tag), .s_axis_tx_req_status_valid(st_v),
        .s_axis_doorbell_queue(db_q), .s_axis_doorbell_valid(db_v),
        .s_axis_sched_ctrl_queue(sc_q_rtl), .s_axis_sched_ctrl_enable(sc_en_rtl),
        .s_axis_sched_ctrl_valid(sc_v_rtl), .s_axis_sched_ctrl_ready(sc_rdy_rtl),
        .s_axil_awaddr(r_awaddr), .s_axil_awprot(3'd0), .s_axil_awvalid(r_awvalid), .s_axil_awready(r_awr_rtl),
        .s_axil_wdata(r_wdata), .s_axil_wstrb(4'hF), .s_axil_wvalid(r_wvalid), .s_axil_wready(r_wr_rtl),
        .s_axil_bresp(), .s_axil_bvalid(r_bv_rtl), .s_axil_bready(1'b1),
        .s_axil_araddr(16'd0), .s_axil_arprot(3'd0), .s_axil_arvalid(1'b0), .s_axil_arready(),
        .s_axil_rdata(), .s_axil_rresp(), .s_axil_rvalid(), .s_axil_rready(1'b1),
        .enable(1'b1), .active(act_rtl)
    );

    tx_scheduler_rr_gl u_rr_gl (
        .clk(clk), .rst(rst),
        .m_axis_tx_req_queue(req_q_gl), .m_axis_tx_req_tag(req_tag_gl),
        .m_axis_tx_req_valid(req_v_gl), .m_axis_tx_req_ready(req_rdy),
        .s_axis_tx_req_status_len(st_len), .s_axis_tx_req_status_tag(st_tag), .s_axis_tx_req_status_valid(st_v),
        .s_axis_doorbell_queue(db_q), .s_axis_doorbell_valid(db_v),
        .s_axis_sched_ctrl_queue(sc_q_gl), .s_axis_sched_ctrl_enable(sc_en_gl),
        .s_axis_sched_ctrl_valid(sc_v_gl), .s_axis_sched_ctrl_ready(sc_rdy_gl),
        .s_axil_awaddr(r_awaddr), .s_axil_awprot(3'd0), .s_axil_awvalid(r_awvalid), .s_axil_awready(r_awr_gl),
        .s_axil_wdata(r_wdata), .s_axil_wstrb(4'hF), .s_axil_wvalid(r_wvalid), .s_axil_wready(r_wr_gl),
        .s_axil_bresp(), .s_axil_bvalid(r_bv_gl), .s_axil_bready(1'b1),
        .s_axil_araddr(16'd0), .s_axil_arprot(3'd0), .s_axil_arvalid(1'b0), .s_axil_arready(),
        .s_axil_rdata(), .s_axil_rresp(), .s_axil_rvalid(), .s_axil_rready(1'b1),
        .enable(1'b1), .active(act_gl)
    );

    always @(posedge clk) begin
        if (mon_en && !rst) begin
            if (^locked_gl === 1'bx || ^tstart_gl === 1'bx || ^tend_gl === 1'bx || ^tact_gl === 1'bx ||
                ^sc_v_gl === 1'bx || ^req_v_gl === 1'bx || ^act_gl === 1'bx) begin
                $display("FAIL: GL control X detected at t=%0t (%b %b %b %b %b %b %b)!",
                         $time, locked_gl, tstart_gl, tend_gl, tact_gl, sc_v_gl, req_v_gl, act_gl);
                errs <= errs + 1;
            end
            if (locked_gl !== locked_rtl || tstart_gl !== tstart_rtl || tend_gl !== tend_rtl ||
                sc_v_gl !== sc_v_rtl || req_v_gl !== req_v_rtl || act_gl !== act_rtl) begin
                $display("FAIL: GL/RTL control parity mismatch at t=%0t!", $time);
                errs <= errs + 1;
            end
            if (req_v_rtl && (^req_q_gl === 1'bx || ^req_tag_gl === 1'bx || req_q_gl !== req_q_rtl || req_tag_gl !== req_tag_rtl)) begin
                $display("FAIL: GL/RTL tx_req payload mismatch (%0d/%0d tag %0h/%0h)!", req_q_gl, req_q_rtl, req_tag_gl, req_tag_rtl);
                errs <= errs + 1;
            end
        end
    end

    integer q;
    reg [7:0] t0;
    initial begin
        rst = 1'b0;
        @(negedge clk);
        rst = 1'b1;
        repeat (5) @(negedge clk);
        rst = 1'b0;
        repeat (16) @(negedge clk); // allow u_rr internal 8-queue init

        // Initialize all 8 entries of u_ctrl queue_ram via AXI-Lite so GL memory is 100% deterministic
        for (q = 0; q < 8; q = q + 1) begin
            @(negedge clk);
            c_awaddr = {11'd0, q[2:0], 2'b00};
            c_wdata  = (q == 1 || q == 3) ? 32'h0000_0001 : 32'h0000_0000;
            c_awvalid = 1'b1; c_wvalid = 1'b1;
            while (!c_awr_rtl) @(posedge clk);
            @(negedge clk);
            c_awvalid = 1'b0; c_wvalid = 1'b0;
            repeat (2) @(negedge clk);
        end
        // Enable q1 (TDMA gated) and q4 (global_enable) in u_rr
        @(negedge clk); r_awaddr = 16'd4;  r_wdata = 32'h0000_0001; r_awvalid = 1'b1; r_wvalid = 1'b1;
        while (!r_awr_rtl) @(posedge clk);
        @(negedge clk); r_awvalid = 1'b0; r_wvalid = 1'b0; repeat (2) @(negedge clk);

        @(negedge clk); r_awaddr = 16'd16; r_wdata = 32'h0000_0003; r_awvalid = 1'b1; r_wvalid = 1'b1;
        while (!r_awr_rtl) @(posedge clk);
        @(negedge clk); r_awvalid = 1'b0; r_wvalid = 1'b0;
        repeat (14) @(negedge clk);
        mon_en = 1'b1;

        // Ring multiple doorbells on q4 while op in-flight (exercises op_table_doorbell[op_tail_index]!)
        @(negedge clk); db_q = 3'd4; db_v = 1'b1;
        @(negedge clk); db_v = 1'b0;
        while (!req_v_rtl) @(posedge clk);
        t0 = req_tag_rtl;
        @(negedge clk); db_q = 3'd4; db_v = 1'b1;
        @(negedge clk); db_v = 1'b0;
        repeat (6) @(negedge clk);
        @(negedge clk); st_tag = t0; st_len = 16'd0; st_v = 1'b1;
        @(negedge clk); st_v = 1'b0;

        // Ring doorbell on q1 and step PTP timestamps across TDMA lock & slot 0
        @(negedge clk); db_q = 3'd1; db_v = 1'b1;
        @(negedge clk); db_v = 1'b0;
        @(negedge clk); ts96 = {48'd0, 2'b00, 30'd400, 16'd0};
        repeat (18) @(negedge clk);
        ts96 = {48'd0, 2'b00, 30'd1600, 16'd0};
        repeat (30) @(negedge clk);
        ts96 = {48'd0, 2'b00, 30'd1900, 16'd0};
        repeat (20) @(negedge clk);

        if (errs == 0)
            $display("PASS_GL");
        else
            $display("FAIL_GL errs=%0d", errs);
        $finish;
    end
endmodule
