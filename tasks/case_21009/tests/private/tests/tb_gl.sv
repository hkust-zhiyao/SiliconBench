`timescale 1ns / 1ps

module tb_gl;
    integer errs = 0;
    reg clk = 1'b0;
    always #2 clk = ~clk;

    initial begin
        #1_000_000;
        $display("FAIL: tb_gl watchdog timeout!");
        $finish;
    end

    reg         rst = 1'b1;
    reg  [63:0] s_tdata = 0;
    reg  [7:0]  s_tkeep = 0;
    reg         s_tvalid = 0;
    reg         s_tlast = 0;
    reg         m_tready = 1'b1;

    reg         cmd_en = 0;
    reg  [7:0]  cmd_start = 0;
    reg  [7:0]  cmd_off = 0;
    reg  [15:0] cmd_init = 0;
    reg         cmd_valid = 0;

    wire        s_tready_rtl, s_tready_gl;
    wire        cmd_ready_rtl, cmd_ready_gl;
    wire [63:0] m_tdata_rtl, m_tdata_gl;
    wire [7:0]  m_tkeep_rtl, m_tkeep_gl;
    wire        m_tvalid_rtl, m_tvalid_gl;
    wire        m_tlast_rtl, m_tlast_gl;
    wire        m_tuser_rtl, m_tuser_gl;

    wire [15:0] rx_csum_rtl, rx_csum_gl;
    wire        rx_valid_rtl, rx_valid_gl;

    tx_checksum #(
        .DATA_WIDTH(64), .KEEP_WIDTH(8), .USE_INIT_VALUE(1),
        .DATA_FIFO_DEPTH(64), .CHECKSUM_FIFO_DEPTH(4)
    ) u_tx_rtl (
        .clk(clk), .rst(rst),
        .s_axis_tdata(s_tdata), .s_axis_tkeep(s_tkeep), .s_axis_tvalid(s_tvalid), .s_axis_tready(s_tready_rtl),
        .s_axis_tlast(s_tlast), .s_axis_tid(8'd0), .s_axis_tdest(8'd0), .s_axis_tuser(1'b1),
        .m_axis_tdata(m_tdata_rtl), .m_axis_tkeep(m_tkeep_rtl), .m_axis_tvalid(m_tvalid_rtl), .m_axis_tready(m_tready),
        .m_axis_tlast(m_tlast_rtl), .m_axis_tid(), .m_axis_tdest(), .m_axis_tuser(m_tuser_rtl),
        .s_axis_cmd_csum_enable(cmd_en), .s_axis_cmd_csum_start(cmd_start), .s_axis_cmd_csum_offset(cmd_off),
        .s_axis_cmd_csum_init(cmd_init), .s_axis_cmd_valid(cmd_valid), .s_axis_cmd_ready(cmd_ready_rtl)
    );

    tx_checksum_gl u_tx_gl (
        .clk(clk), .rst(rst),
        .s_axis_tdata(s_tdata), .s_axis_tkeep(s_tkeep), .s_axis_tvalid(s_tvalid), .s_axis_tready(s_tready_gl),
        .s_axis_tlast(s_tlast), .s_axis_tid(8'd0), .s_axis_tdest(8'd0), .s_axis_tuser(1'b1),
        .m_axis_tdata(m_tdata_gl), .m_axis_tkeep(m_tkeep_gl), .m_axis_tvalid(m_tvalid_gl), .m_axis_tready(m_tready),
        .m_axis_tlast(m_tlast_gl), .m_axis_tid(), .m_axis_tdest(), .m_axis_tuser(m_tuser_gl),
        .s_axis_cmd_csum_enable(cmd_en), .s_axis_cmd_csum_start(cmd_start), .s_axis_cmd_csum_offset(cmd_off),
        .s_axis_cmd_csum_init(cmd_init), .s_axis_cmd_valid(cmd_valid), .s_axis_cmd_ready(cmd_ready_gl)
    );

    rx_checksum #(.DATA_WIDTH(64), .KEEP_WIDTH(8), .START_OFFSET(16)) u_rx_rtl (
        .clk(clk), .rst(rst),
        .s_axis_tdata(s_tdata), .s_axis_tkeep(s_tkeep), .s_axis_tvalid(s_tvalid && s_tready_rtl), .s_axis_tlast(s_tlast),
        .m_axis_csum(rx_csum_rtl), .m_axis_csum_valid(rx_valid_rtl)
    );

    rx_checksum_gl u_rx_gl (
        .clk(clk), .rst(rst),
        .s_axis_tdata(s_tdata), .s_axis_tkeep(s_tkeep), .s_axis_tvalid(s_tvalid && s_tready_rtl), .s_axis_tlast(s_tlast),
        .m_axis_csum(rx_csum_gl), .m_axis_csum_valid(rx_valid_gl)
    );

    reg mon_en = 1'b0;

    always @(posedge clk) begin
        if (mon_en && !rst) begin
            if (^s_tready_gl === 1'bx || ^cmd_ready_gl === 1'bx || ^m_tvalid_gl === 1'bx || ^rx_valid_gl === 1'bx) begin
                $display("FAIL: GL control signal X detected!");
                errs <= errs + 1;
            end
            if (s_tready_gl !== s_tready_rtl || cmd_ready_gl !== cmd_ready_rtl ||
                m_tvalid_gl !== m_tvalid_rtl || rx_valid_gl !== rx_valid_rtl) begin
                $display("FAIL: GL/RTL handshake mismatch (%b/%b %b/%b %b/%b %b/%b)!",
                         s_tready_gl, s_tready_rtl, cmd_ready_gl, cmd_ready_rtl, m_tvalid_gl, m_tvalid_rtl, rx_valid_gl, rx_valid_rtl);
                errs <= errs + 1;
            end
            if (m_tvalid_rtl) begin
                if (^m_tdata_gl === 1'bx || m_tdata_gl !== m_tdata_rtl || m_tkeep_gl !== m_tkeep_rtl || m_tlast_gl !== m_tlast_rtl) begin
                    $display("FAIL: GL/RTL TX payload mismatch (%h vs %h)!", m_tdata_gl, m_tdata_rtl);
                    errs <= errs + 1;
                end
            end
            if (rx_valid_rtl) begin
                if (^rx_csum_gl === 1'bx || rx_csum_gl !== rx_csum_rtl) begin
                    $display("FAIL: GL/RTL RX csum mismatch (%h vs %h)!", rx_csum_gl, rx_csum_rtl);
                    errs <= errs + 1;
                end
            end
        end
    end

    integer k, b;
    initial begin
        rst = 1'b0;
        @(negedge clk);
        rst = 1'b1;
        repeat (5) @(negedge clk);
        rst = 1'b0;
        mon_en = 1'b1;
        repeat (2) @(negedge clk);

        m_tready = 1'b0;
        fork
            begin
                repeat (55) @(negedge clk);
                m_tready = 1'b1;
            end
            begin
        for (k = 0; k < 9; k = k + 1) begin
            @(negedge clk);
            cmd_en = 1'b1; cmd_start = (k == 0) ? 8'd0 : 8'd16; cmd_off = 8'd7; cmd_init = 16'h1122 + k[15:0]; cmd_valid = 1'b1;
            while (!cmd_ready_rtl) @(negedge clk);
            @(negedge clk); cmd_valid = 1'b0;
            for (b = 0; b < 3; b = b + 1) begin
                s_tdata = {8{8'hA0 + k[7:0] + b[7:0]}};
                s_tkeep = (b == 2) ? 8'h3F : 8'hFF;
                s_tlast = (b == 2);
                s_tvalid = 1'b1;
                while (!s_tready_rtl) @(negedge clk);
                @(negedge clk);
                s_tvalid = 1'b0; s_tlast = 1'b0;
            end
        end
            end
        join
        repeat (40) @(negedge clk);

        if (errs == 0)
            $display("PASS_GL");
        else
            $display("FAIL_GL errs=%0d", errs);
        $finish;
    end
endmodule
