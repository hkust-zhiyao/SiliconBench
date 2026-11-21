`timescale 1ns / 1ps

module tb #(
    parameter integer SEED = 101
);
    integer errs = 0;
    integer rng;

    reg clk = 1'b0;
    always #2 clk = ~clk;

    initial begin
        #4_000_000;
        $display("FAIL: tb watchdog timeout!");
        $finish;
    end

    // Reference RFC 1071 ones'-complement sum over pkt_buf[start_idx .. pkt_len-1]
    reg [7:0] pkt_buf [0:255];

    function automatic [15:0] calc_ones_comp_sum(
        input integer start_idx,
        input integer pkt_len,
        input [15:0]  init_val
    );
        reg [31:0] acc;
        integer idx;
        reg [7:0] hi_b, lo_b;
        begin
            acc = {16'd0, init_val};
            idx = start_idx;
            while (idx < pkt_len) begin
                hi_b = pkt_buf[idx];
                lo_b = ((idx + 1) < pkt_len) ? pkt_buf[idx + 1] : 8'd0;
                acc  = acc + {16'd0, hi_b, lo_b};
                idx  = idx + 2;
            end
            acc = (acc & 32'h0000_FFFF) + (acc >> 16);
            acc = (acc & 32'h0000_FFFF) + (acc >> 16);
            calc_ones_comp_sum = acc[15:0];
        end
    endfunction

    function automatic [15:0] calc_tx_csum(
        input integer start_idx,
        input integer pkt_len,
        input [15:0]  init_val,
        input         use_init
    );
        reg [31:0] acc;
        integer m;
        reg [7:0] b0, b1;
        reg [15:0] folded, inv16;
        begin
            acc = use_init ? {16'd0, init_val} : 32'd0;
            for (m = 0; m < pkt_len; m = m + 2) begin
                b0 = (m >= start_idx) ? pkt_buf[m] : 8'd0;
                b1 = (((m + 1) < pkt_len) && ((m + 1) >= start_idx)) ? pkt_buf[m + 1] : 8'd0;
                acc = acc + {16'd0, b0, b1};
            end
            acc = (acc & 32'h0000_FFFF) + (acc >> 16);
            acc = (acc & 32'h0000_FFFF) + (acc >> 16);
            folded = acc[15:0];
            inv16  = ~folded;
            calc_tx_csum = start_idx[0] ? {inv16[7:0], inv16[15:8]} : inv16;
        end
    endfunction

    // =========================================================================
    // 1. tx_checksum Instance A: DATA_WIDTH=64, USE_INIT_VALUE=1, CSUM_FIFO=4
    // =========================================================================
    reg         rst_tx64 = 1'b1;
    reg  [63:0] s64_tdata = 0;
    reg  [7:0]  s64_tkeep = 0;
    reg         s64_tvalid = 0;
    wire        s64_tready;
    reg         s64_tlast = 0;
    reg  [7:0]  s64_tid = 0;
    reg  [7:0]  s64_tdest = 0;
    reg  [3:0]  s64_tuser = 0;

    wire [63:0] m64_tdata;
    wire [7:0]  m64_tkeep;
    wire        m64_tvalid;
    reg         m64_tready_drv = 1'b1;
    integer     m64_stall_cnt = 0;
    wire        m64_tready = m64_tready_drv && (m64_stall_cnt == 0);
    wire        m64_tlast;
    wire [7:0]  m64_tid;
    wire [7:0]  m64_tdest;
    wire [3:0]  m64_tuser;

    reg         cmd64_en = 0;
    reg  [7:0]  cmd64_start = 0;
    reg  [7:0]  cmd64_offset = 0;
    reg  [15:0] cmd64_init = 0;
    reg         cmd64_valid = 0;
    wire        cmd64_ready;

    tx_checksum #(
        .DATA_WIDTH(64),
        .KEEP_WIDTH(8),
        .ID_ENABLE(1),
        .ID_WIDTH(8),
        .DEST_ENABLE(1),
        .DEST_WIDTH(8),
        .USER_ENABLE(1),
        .USER_WIDTH(4),
        .USE_INIT_VALUE(1),
        .DATA_FIFO_DEPTH(512),
        .CHECKSUM_FIFO_DEPTH(4)
    ) u_tx64 (
        .clk(clk), .rst(rst_tx64),
        .s_axis_tdata(s64_tdata), .s_axis_tkeep(s64_tkeep),
        .s_axis_tvalid(s64_tvalid), .s_axis_tready(s64_tready),
        .s_axis_tlast(s64_tlast), .s_axis_tid(s64_tid),
        .s_axis_tdest(s64_tdest), .s_axis_tuser(s64_tuser),
        .m_axis_tdata(m64_tdata), .m_axis_tkeep(m64_tkeep),
        .m_axis_tvalid(m64_tvalid), .m_axis_tready(m64_tready),
        .m_axis_tlast(m64_tlast), .m_axis_tid(m64_tid),
        .m_axis_tdest(m64_tdest), .m_axis_tuser(m64_tuser),
        .s_axis_cmd_csum_enable(cmd64_en),
        .s_axis_cmd_csum_start(cmd64_start),
        .s_axis_cmd_csum_offset(cmd64_offset),
        .s_axis_cmd_csum_init(cmd64_init),
        .s_axis_cmd_valid(cmd64_valid),
        .s_axis_cmd_ready(cmd64_ready)
    );

    // Expected packet scoreboard for u_tx64
    reg [7:0] exp64_bytes [0:63][0:127];
    integer   exp64_len   [0:63];
    reg [7:0] exp64_id    [0:63];
    reg [7:0] exp64_dest  [0:63];
    reg [3:0] exp64_user  [0:63];
    integer   wr64_ptr = 0, rd64_ptr = 0, cur64_idx = 0;
    reg       mon64_active = 1'b0;

    always @(posedge clk) begin
        if (!rst_tx64 && mon64_active) begin
            if (^m64_tvalid === 1'bx) begin
                $display("FAIL: m64_tvalid is X at t=%0t!", $time);
                errs <= errs + 1;
            end
            if (m64_tvalid && m64_tready) begin
                integer lane;
                for (lane = 0; lane < 8; lane = lane + 1) begin
                    if (m64_tkeep[lane]) begin
                        if (m64_tdata[lane*8 +: 8] !== exp64_bytes[rd64_ptr][cur64_idx]) begin
                            $display("FAIL [tx64 pkt %0d byte %0d]: got 0x%02x exp 0x%02x",
                                     rd64_ptr, cur64_idx, m64_tdata[lane*8 +: 8], exp64_bytes[rd64_ptr][cur64_idx]);
                            errs <= errs + 1;
                        end
                        cur64_idx = cur64_idx + 1;
                    end
                end
                if (m64_tid !== exp64_id[rd64_ptr] || m64_tdest !== exp64_dest[rd64_ptr] || m64_tuser !== exp64_user[rd64_ptr]) begin
                    $display("FAIL [tx64 pkt %0d sideband]: got (%02x,%02x,%01x) exp (%02x,%02x,%01x)",
                             rd64_ptr, m64_tid, m64_tdest, m64_tuser, exp64_id[rd64_ptr], exp64_dest[rd64_ptr], exp64_user[rd64_ptr]);
                    errs <= errs + 1;
                end
                if (m64_tlast) begin
                    if (cur64_idx != exp64_len[rd64_ptr]) begin
                        $display("FAIL [tx64 pkt %0d len]: got %0d exp %0d", rd64_ptr, cur64_idx, exp64_len[rd64_ptr]);
                        errs <= errs + 1;
                    end
                    cur64_idx = 0;
                    rd64_ptr  = rd64_ptr + 1;
                end
            end
        end
    end

    task automatic send_tx64_pkt(
        input integer pkt_len,
        input         cs_en,
        input [7:0]   cs_start,
        input [7:0]   cs_off,
        input [15:0]  cs_init,
        input         fill_ones
    );
        integer b, pos, lane;
        reg [15:0] cs;
        begin
            for (b = 0; b < pkt_len; b = b + 1) begin
                pkt_buf[b] = fill_ones ? ((b & 1) ? 8'hFF : 8'hFE) : ($random(rng) & 8'hFF);
                exp64_bytes[wr64_ptr][b] = pkt_buf[b];
            end
            cs = calc_tx_csum(cs_start, pkt_len, cs_init, 1'b1);
            if (cs_en) begin
                if (cs_off < pkt_len)       exp64_bytes[wr64_ptr][cs_off]     = cs[15:8];
                if ((cs_off + 1) < pkt_len) exp64_bytes[wr64_ptr][cs_off + 1] = cs[7:0];
            end
            exp64_len[wr64_ptr]  = pkt_len;
            exp64_id[wr64_ptr]   = wr64_ptr[7:0] ^ 8'h5A;
            exp64_dest[wr64_ptr] = wr64_ptr[7:0] + 8'h10;
            exp64_user[wr64_ptr] = wr64_ptr[3:0] ^ 4'h9;

            @(negedge clk);
            cmd64_en     = cs_en;
            cmd64_start  = cs_start;
            cmd64_offset = cs_off;
            cmd64_init   = cs_init;
            cmd64_valid  = 1'b1;
            while (!cmd64_ready) @(negedge clk);
            @(negedge clk);
            cmd64_valid  = 1'b0;

            pos = 0;
            while (pos < pkt_len) begin
                s64_tdata = 64'd0;
                s64_tkeep = 8'd0;
                for (lane = 0; lane < 8; lane = lane + 1) begin
                    if ((pos + lane) < pkt_len) begin
                        s64_tdata[lane*8 +: 8] = pkt_buf[pos + lane];
                        s64_tkeep[lane]        = 1'b1;
                    end
                end
                s64_tlast  = ((pos + 8) >= pkt_len);
                s64_tid    = exp64_id[wr64_ptr];
                s64_tdest  = exp64_dest[wr64_ptr];
                s64_tuser  = exp64_user[wr64_ptr];
                s64_tvalid = 1'b1;
                while (!s64_tready) @(negedge clk);
                @(negedge clk);
                s64_tvalid = 1'b0;
                s64_tlast  = 1'b0;
                pos = pos + 8;
            end
            wr64_ptr = wr64_ptr + 1;
        end
    endtask

    // =========================================================================
    // 2. tx_checksum Instance B: DATA_WIDTH=256, USE_INIT_VALUE=0, CSUM_FIFO=4
    // =========================================================================
    reg          rst_tx256 = 1'b1;
    reg  [255:0] s256_tdata = 0;
    reg  [31:0]  s256_tkeep = 0;
    reg          s256_tvalid = 0;
    wire         s256_tready;
    reg          s256_tlast = 0;
    wire [255:0] m256_tdata;
    wire [31:0]  m256_tkeep;
    wire         m256_tvalid;
    reg          m256_tready_drv = 1'b1;
    integer      m256_stall_cnt = 0;
    wire         m256_tready = m256_tready_drv && (m256_stall_cnt == 0);
    wire         m256_tlast;
    reg          cmd256_en = 0;
    reg  [7:0]   cmd256_start = 0;
    reg  [7:0]   cmd256_offset = 0;
    reg  [15:0]  cmd256_init = 16'hBEEF;
    reg          cmd256_valid = 0;
    wire         cmd256_ready;

    tx_checksum #(
        .DATA_WIDTH(256),
        .KEEP_WIDTH(32),
        .USE_INIT_VALUE(0),
        .DATA_FIFO_DEPTH(2048),
        .CHECKSUM_FIFO_DEPTH(4)
    ) u_tx256 (
        .clk(clk), .rst(rst_tx256),
        .s_axis_tdata(s256_tdata), .s_axis_tkeep(s256_tkeep),
        .s_axis_tvalid(s256_tvalid), .s_axis_tready(s256_tready),
        .s_axis_tlast(s256_tlast), .s_axis_tid(8'd0), .s_axis_tdest(8'd0), .s_axis_tuser(1'b0),
        .m_axis_tdata(m256_tdata), .m_axis_tkeep(m256_tkeep),
        .m_axis_tvalid(m256_tvalid), .m_axis_tready(m256_tready),
        .m_axis_tlast(m256_tlast), .m_axis_tid(), .m_axis_tdest(), .m_axis_tuser(),
        .s_axis_cmd_csum_enable(cmd256_en),
        .s_axis_cmd_csum_start(cmd256_start),
        .s_axis_cmd_csum_offset(cmd256_offset),
        .s_axis_cmd_csum_init(cmd256_init),
        .s_axis_cmd_valid(cmd256_valid),
        .s_axis_cmd_ready(cmd256_ready)
    );

    reg [7:0] exp256_bytes [0:31][0:191];
    integer   exp256_len   [0:31];
    integer   wr256_ptr = 0, rd256_ptr = 0, cur256_idx = 0;

    always @(posedge clk) begin
        if (!rst_tx256 && m256_tvalid && m256_tready) begin
            integer lane;
            for (lane = 0; lane < 32; lane = lane + 1) begin
                if (m256_tkeep[lane]) begin
                    if (m256_tdata[lane*8 +: 8] !== exp256_bytes[rd256_ptr][cur256_idx]) begin
                        $display("FAIL [tx256 pkt %0d byte %0d]: got 0x%02x exp 0x%02x",
                                 rd256_ptr, cur256_idx, m256_tdata[lane*8 +: 8], exp256_bytes[rd256_ptr][cur256_idx]);
                        errs <= errs + 1;
                    end
                    cur256_idx = cur256_idx + 1;
                end
            end
            if (m256_tlast) begin
                if (cur256_idx != exp256_len[rd256_ptr]) begin
                    $display("FAIL [tx256 pkt %0d len]: got %0d exp %0d", rd256_ptr, cur256_idx, exp256_len[rd256_ptr]);
                    errs <= errs + 1;
                end
                cur256_idx = 0;
                rd256_ptr  = rd256_ptr + 1;
            end
        end
    end

    task automatic send_tx256_pkt(
        input integer pkt_len,
        input         cs_en,
        input [7:0]   cs_start,
        input [7:0]   cs_off
    );
        integer b, pos, lane;
        reg [15:0] cs;
        begin
            for (b = 0; b < pkt_len; b = b + 1) begin
                pkt_buf[b] = ($random(rng) & 8'hFF);
                exp256_bytes[wr256_ptr][b] = pkt_buf[b];
            end
            // USE_INIT_VALUE=0 must ignore cmd256_init=16'hBEEF!
            cs = calc_tx_csum(cs_start, pkt_len, 16'hBEEF, 1'b0);
            if (cs_en) begin
                if (cs_off < pkt_len)       exp256_bytes[wr256_ptr][cs_off]     = cs[15:8];
                if ((cs_off + 1) < pkt_len) exp256_bytes[wr256_ptr][cs_off + 1] = cs[7:0];
            end
            exp256_len[wr256_ptr] = pkt_len;

            @(negedge clk);
            cmd256_en     = cs_en;
            cmd256_start  = cs_start;
            cmd256_offset = cs_off;
            cmd256_init   = 16'hBEEF;
            cmd256_valid  = 1'b1;
            while (!cmd256_ready) @(negedge clk);
            @(negedge clk);
            cmd256_valid  = 1'b0;

            pos = 0;
            while (pos < pkt_len) begin
                s256_tdata = 256'd0;
                s256_tkeep = 32'd0;
                for (lane = 0; lane < 32; lane = lane + 1) begin
                    if ((pos + lane) < pkt_len) begin
                        s256_tdata[lane*8 +: 8] = pkt_buf[pos + lane];
                        s256_tkeep[lane]        = 1'b1;
                    end
                end
                s256_tlast  = ((pos + 32) >= pkt_len);
                s256_tvalid = 1'b1;
                while (!s256_tready) @(negedge clk);
                @(negedge clk);
                s256_tvalid = 1'b0;
                s256_tlast  = 1'b0;
                pos = pos + 32;
            end
            wr256_ptr = wr256_ptr + 1;
        end
    endtask

    // =========================================================================
    // 3. rx_checksum Instances: even & odd START_OFFSETs across 64b and 256b
    //    (64b: 1, 14, 15, 16, 17;  256b: 14, 15, 64, 65)
    // =========================================================================
    reg          rst_rx = 1'b1;
    reg  [63:0]  rx64_tdata = 0;
    reg  [7:0]   rx64_tkeep = 0;
    reg          rx64_tvalid = 0;
    reg          rx64_tlast = 0;
    wire [15:0]  rx64_1_csum, rx64_14_csum, rx64_15_csum, rx64_16_csum, rx64_17_csum;
    wire         rx64_1_valid, rx64_14_valid, rx64_15_valid, rx64_16_valid, rx64_17_valid;

    reg  [255:0] rx256_tdata = 0;
    reg  [31:0]  rx256_tkeep = 0;
    reg          rx256_tvalid = 0;
    reg          rx256_tlast = 0;
    wire [15:0]  rx256_64_csum, rx256_65_csum, rx256_14_csum, rx256_15_csum;
    wire         rx256_64_valid, rx256_65_valid, rx256_14_valid, rx256_15_valid;

    rx_checksum #(.DATA_WIDTH(64),  .KEEP_WIDTH(8),  .START_OFFSET(1))  u_rx64_1   (.clk(clk), .rst(rst_rx), .s_axis_tdata(rx64_tdata),  .s_axis_tkeep(rx64_tkeep),  .s_axis_tvalid(rx64_tvalid),  .s_axis_tlast(rx64_tlast),  .m_axis_csum(rx64_1_csum),   .m_axis_csum_valid(rx64_1_valid));
    rx_checksum #(.DATA_WIDTH(64),  .KEEP_WIDTH(8),  .START_OFFSET(14)) u_rx64_14  (.clk(clk), .rst(rst_rx), .s_axis_tdata(rx64_tdata),  .s_axis_tkeep(rx64_tkeep),  .s_axis_tvalid(rx64_tvalid),  .s_axis_tlast(rx64_tlast),  .m_axis_csum(rx64_14_csum),  .m_axis_csum_valid(rx64_14_valid));
    rx_checksum #(.DATA_WIDTH(64),  .KEEP_WIDTH(8),  .START_OFFSET(15)) u_rx64_15  (.clk(clk), .rst(rst_rx), .s_axis_tdata(rx64_tdata),  .s_axis_tkeep(rx64_tkeep),  .s_axis_tvalid(rx64_tvalid),  .s_axis_tlast(rx64_tlast),  .m_axis_csum(rx64_15_csum),  .m_axis_csum_valid(rx64_15_valid));
    rx_checksum #(.DATA_WIDTH(64),  .KEEP_WIDTH(8),  .START_OFFSET(16)) u_rx64_16  (.clk(clk), .rst(rst_rx), .s_axis_tdata(rx64_tdata),  .s_axis_tkeep(rx64_tkeep),  .s_axis_tvalid(rx64_tvalid),  .s_axis_tlast(rx64_tlast),  .m_axis_csum(rx64_16_csum),  .m_axis_csum_valid(rx64_16_valid));
    rx_checksum #(.DATA_WIDTH(64),  .KEEP_WIDTH(8),  .START_OFFSET(17)) u_rx64_17  (.clk(clk), .rst(rst_rx), .s_axis_tdata(rx64_tdata),  .s_axis_tkeep(rx64_tkeep),  .s_axis_tvalid(rx64_tvalid),  .s_axis_tlast(rx64_tlast),  .m_axis_csum(rx64_17_csum),  .m_axis_csum_valid(rx64_17_valid));
    rx_checksum #(.DATA_WIDTH(256), .KEEP_WIDTH(32), .START_OFFSET(64)) u_rx256_64 (.clk(clk), .rst(rst_rx), .s_axis_tdata(rx256_tdata), .s_axis_tkeep(rx256_tkeep), .s_axis_tvalid(rx256_tvalid), .s_axis_tlast(rx256_tlast), .m_axis_csum(rx256_64_csum), .m_axis_csum_valid(rx256_64_valid));
    rx_checksum #(.DATA_WIDTH(256), .KEEP_WIDTH(32), .START_OFFSET(65)) u_rx256_65 (.clk(clk), .rst(rst_rx), .s_axis_tdata(rx256_tdata), .s_axis_tkeep(rx256_tkeep), .s_axis_tvalid(rx256_tvalid), .s_axis_tlast(rx256_tlast), .m_axis_csum(rx256_65_csum), .m_axis_csum_valid(rx256_65_valid));
    rx_checksum #(.DATA_WIDTH(256), .KEEP_WIDTH(32), .START_OFFSET(14)) u_rx256_14 (.clk(clk), .rst(rst_rx), .s_axis_tdata(rx256_tdata), .s_axis_tkeep(rx256_tkeep), .s_axis_tvalid(rx256_tvalid), .s_axis_tlast(rx256_tlast), .m_axis_csum(rx256_14_csum), .m_axis_csum_valid(rx256_14_valid));
    rx_checksum #(.DATA_WIDTH(256), .KEEP_WIDTH(32), .START_OFFSET(15)) u_rx256_15 (.clk(clk), .rst(rst_rx), .s_axis_tdata(rx256_tdata), .s_axis_tkeep(rx256_tkeep), .s_axis_tvalid(rx256_tvalid), .s_axis_tlast(rx256_tlast), .m_axis_csum(rx256_15_csum), .m_axis_csum_valid(rx256_15_valid));

    reg [15:0] exp_rx64_1 [0:63], exp_rx64_14 [0:63], exp_rx64_15 [0:63], exp_rx64_16 [0:63], exp_rx64_17 [0:63];
    reg [15:0] exp_rx256_64 [0:63], exp_rx256_65 [0:63], exp_rx256_14 [0:63], exp_rx256_15 [0:63];
    integer wr_rx64 = 0, rd_rx64_1 = 0, rd_rx64_14 = 0, rd_rx64_15 = 0, rd_rx64_16 = 0, rd_rx64_17 = 0;
    integer wr_rx256 = 0, rd_rx256_64 = 0, rd_rx256_65 = 0, rd_rx256_14 = 0, rd_rx256_15 = 0;
    reg rx_mon_en = 1'b0;

    always @(posedge clk) begin
        if (!rst_rx && rx_mon_en) begin
            if (rx64_1_valid) begin
                if (rx64_1_csum !== exp_rx64_1[rd_rx64_1]) begin
                    $display("FAIL [rx64_1 pkt %0d]: got 0x%04x exp 0x%04x", rd_rx64_1, rx64_1_csum, exp_rx64_1[rd_rx64_1]);
                    errs <= errs + 1;
                end
                rd_rx64_1 <= rd_rx64_1 + 1;
            end
            if (rx64_14_valid) begin
                if (rx64_14_csum !== exp_rx64_14[rd_rx64_14]) begin
                    $display("FAIL [rx64_14 pkt %0d]: got 0x%04x exp 0x%04x", rd_rx64_14, rx64_14_csum, exp_rx64_14[rd_rx64_14]);
                    errs <= errs + 1;
                end
                rd_rx64_14 <= rd_rx64_14 + 1;
            end
            if (rx64_15_valid) begin
                if (rx64_15_csum !== exp_rx64_15[rd_rx64_15]) begin
                    $display("FAIL [rx64_15 pkt %0d]: got 0x%04x exp 0x%04x", rd_rx64_15, rx64_15_csum, exp_rx64_15[rd_rx64_15]);
                    errs <= errs + 1;
                end
                rd_rx64_15 <= rd_rx64_15 + 1;
            end
            if (rx64_16_valid) begin
                if (rx64_16_csum !== exp_rx64_16[rd_rx64_16]) begin
                    $display("FAIL [rx64_16 pkt %0d]: got 0x%04x exp 0x%04x", rd_rx64_16, rx64_16_csum, exp_rx64_16[rd_rx64_16]);
                    errs <= errs + 1;
                end
                rd_rx64_16 <= rd_rx64_16 + 1;
            end
            if (rx64_17_valid) begin
                if (rx64_17_csum !== exp_rx64_17[rd_rx64_17]) begin
                    $display("FAIL [rx64_17 pkt %0d]: got 0x%04x exp 0x%04x", rd_rx64_17, rx64_17_csum, exp_rx64_17[rd_rx64_17]);
                    errs <= errs + 1;
                end
                rd_rx64_17 <= rd_rx64_17 + 1;
            end
            if (rx256_64_valid) begin
                if (rx256_64_csum !== exp_rx256_64[rd_rx256_64]) begin
                    $display("FAIL [rx256_64 pkt %0d]: got 0x%04x exp 0x%04x", rd_rx256_64, rx256_64_csum, exp_rx256_64[rd_rx256_64]);
                    errs <= errs + 1;
                end
                rd_rx256_64 <= rd_rx256_64 + 1;
            end
            if (rx256_65_valid) begin
                if (rx256_65_csum !== exp_rx256_65[rd_rx256_65]) begin
                    $display("FAIL [rx256_65 pkt %0d]: got 0x%04x exp 0x%04x", rd_rx256_65, rx256_65_csum, exp_rx256_65[rd_rx256_65]);
                    errs <= errs + 1;
                end
                rd_rx256_65 <= rd_rx256_65 + 1;
            end
            if (rx256_14_valid) begin
                if (rx256_14_csum !== exp_rx256_14[rd_rx256_14]) begin
                    $display("FAIL [rx256_14 pkt %0d]: got 0x%04x exp 0x%04x", rd_rx256_14, rx256_14_csum, exp_rx256_14[rd_rx256_14]);
                    errs <= errs + 1;
                end
                rd_rx256_14 <= rd_rx256_14 + 1;
            end
            if (rx256_15_valid) begin
                if (rx256_15_csum !== exp_rx256_15[rd_rx256_15]) begin
                    $display("FAIL [rx256_15 pkt %0d]: got 0x%04x exp 0x%04x", rd_rx256_15, rx256_15_csum, exp_rx256_15[rd_rx256_15]);
                    errs <= errs + 1;
                end
                rd_rx256_15 <= rd_rx256_15 + 1;
            end
        end
    end

    task automatic send_rx_from_buf(input integer pkt_len);
        integer pos, lane;
        begin
            exp_rx64_1[wr_rx64]    = calc_ones_comp_sum(1,  pkt_len, 16'd0);
            exp_rx64_14[wr_rx64]   = calc_ones_comp_sum(14, pkt_len, 16'd0);
            exp_rx64_15[wr_rx64]   = calc_ones_comp_sum(15, pkt_len, 16'd0);
            exp_rx64_16[wr_rx64]   = calc_ones_comp_sum(16, pkt_len, 16'd0);
            exp_rx64_17[wr_rx64]   = calc_ones_comp_sum(17, pkt_len, 16'd0);
            exp_rx256_64[wr_rx256] = calc_ones_comp_sum(64, pkt_len, 16'd0);
            exp_rx256_65[wr_rx256] = calc_ones_comp_sum(65, pkt_len, 16'd0);
            exp_rx256_14[wr_rx256] = calc_ones_comp_sum(14, pkt_len, 16'd0);
            exp_rx256_15[wr_rx256] = calc_ones_comp_sum(15, pkt_len, 16'd0);
            wr_rx64  = wr_rx64 + 1;
            wr_rx256 = wr_rx256 + 1;

            // Drive 64b RX stream with occasional bubble cycles
            pos = 0;
            while (pos < pkt_len) begin
                if (($random(rng) & 3) == 0) begin
                    @(negedge clk); rx64_tvalid = 1'b0;
                end
                @(negedge clk);
                rx64_tdata = 64'hA55A_C33C_F00F_1234; rx64_tkeep = 8'd0;
                for (lane = 0; lane < 8; lane = lane + 1) begin
                    if ((pos + lane) < pkt_len) begin
                        rx64_tdata[lane*8 +: 8] = pkt_buf[pos + lane];
                        rx64_tkeep[lane]        = 1'b1;
                    end
                end
                rx64_tlast  = ((pos + 8) >= pkt_len);
                rx64_tvalid = 1'b1;
                pos = pos + 8;
            end
            @(negedge clk);
            rx64_tvalid = 1'b0; rx64_tlast = 1'b0;

            // Drive 256b RX stream
            pos = 0;
            while (pos < pkt_len) begin
                @(negedge clk);
                rx256_tdata = {8{32'hDEAD_BEEF}}; rx256_tkeep = 32'd0;
                for (lane = 0; lane < 32; lane = lane + 1) begin
                    if ((pos + lane) < pkt_len) begin
                        rx256_tdata[lane*8 +: 8] = pkt_buf[pos + lane];
                        rx256_tkeep[lane]        = 1'b1;
                    end
                end
                rx256_tlast  = ((pos + 32) >= pkt_len);
                rx256_tvalid = 1'b1;
                pos = pos + 32;
            end
            @(negedge clk);
            rx256_tvalid = 1'b0; rx256_tlast = 1'b0;
        end
    endtask

    task automatic send_rx_pkt(input integer pkt_len, input fill_ones);
        integer b;
        begin
            for (b = 0; b < pkt_len; b = b + 1)
                pkt_buf[b] = fill_ones ? ((b == 16) ? 8'h47 : ((b == 17) ? 8'h43 : ((b & 1) ? 8'hFF : 8'hFE))) : ($random(rng) & 8'hFF);
            send_rx_from_buf(pkt_len);
        end
    endtask

    reg start_m64_stall = 1'b0;
    reg start_m256_stall = 1'b0;
    always @(negedge clk) begin
        if (start_m64_stall)
            m64_stall_cnt <= 95;
        else if (m64_stall_cnt > 0)
            m64_stall_cnt <= m64_stall_cnt - 1;

        if (start_m256_stall)
            m256_stall_cnt <= 80;
        else if (m256_stall_cnt > 0)
            m256_stall_cnt <= m256_stall_cnt - 1;
    end

    integer p;
    initial begin
        rng = SEED;
        rst_tx64 = 1'b0; rst_tx256 = 1'b0; rst_rx = 1'b0;
        @(negedge clk);
        rst_tx64 = 1'b1; rst_tx256 = 1'b1; rst_rx = 1'b1;
        repeat (5) @(negedge clk);
        rst_tx64  = 1'b0;
        rst_tx256 = 1'b0;
        rst_rx    = 1'b0;
        mon64_active = 1'b1;
        rx_mon_en    = 1'b1;
        repeat (2) @(negedge clk);

        // --- Test 1: Sustained m_axis_tready=0 Backpressure Overflow (12 packets into CSUM_FIFO_DEPTH=4!) ---
        start_m64_stall = 1'b1;
        @(negedge clk);
        start_m64_stall = 1'b0;
        for (p = 0; p < 12; p = p + 1) begin
            send_tx64_pkt(12 + (p % 5), 1'b1, (p % 3 == 0) ? 8'd0 : ((p % 3 == 1) ? 8'd3 : 8'd8),
                          (p % 2 == 0) ? 8'd6 : 8'd7, 16'h1234 + p[15:0], 1'b0);
        end
        while (m64_stall_cnt > 0) @(negedge clk);
        // Drain with choppy m64_tready
        while (rd64_ptr < wr64_ptr) begin
            @(negedge clk);
            m64_tready_drv = ($random(rng) & 1);
        end
        m64_tready_drv = 1'b1;

        // --- Test 2: Split-beat offsets (7, 15, 23), odd/even multi-beat start, passthrough, carry-wrap ---
        send_tx64_pkt(32, 1'b1, 8'd0,  8'd7,  16'h1008, 1'b1); // carry-heavy + 2nd-pass fold carry + split beat 0->1
        send_tx64_pkt(41, 1'b1, 8'd14, 8'd15, 16'hABCD, 1'b0); // multi-beat start=14 + split beat 1->2
        send_tx64_pkt(47, 1'b1, 8'd15, 8'd23, 16'h0000, 1'b0); // odd multi-beat start=15 + split beat 2->3
        send_tx64_pkt(36, 1'b1, 8'd19, 8'd26, 16'h0000, 1'b0); // start >= 2*KEEP_WIDTH + odd
        send_tx64_pkt(25, 1'b0, 8'd4,  8'd6,  16'hFFFF, 1'b0); // csum_enable=0 passthrough!
        for (p = 0; p < 8; p = p + 1) begin
            send_tx64_pkt(20 + (p * 7), 1'b1, p[7:0] * 8'd2 + p[0], 8'd10 + p[7:0], $random(rng) & 16'hFFFF, 1'b0);
        end
        while (rd64_ptr < wr64_ptr) @(negedge clk);

        // --- Test 3: Mid-packet synchronous reset recovery on tx64 ---
        mon64_active = 1'b0;
        @(negedge clk);
        cmd64_en = 1'b1; cmd64_start = 8'd0; cmd64_offset = 8'd4; cmd64_init = 16'h7777; cmd64_valid = 1'b1;
        while (!cmd64_ready) @(negedge clk);
        @(negedge clk); cmd64_valid = 1'b0;
        s64_tdata = 64'hFFFF_FFFF_FFFF_FFFF; s64_tkeep = 8'hFF; s64_tlast = 1'b0; s64_tvalid = 1'b1;
        repeat (2) @(negedge clk);
        rst_tx64 = 1'b1; s64_tvalid = 1'b0;
        repeat (3) @(negedge clk);
        rst_tx64 = 1'b0;
        cur64_idx = 0;
        mon64_active = 1'b1;
        send_tx64_pkt(28, 1'b1, 8'd2, 8'd14, 16'h0102, 1'b0);
        while (rd64_ptr < wr64_ptr) @(negedge clk);

        // --- Test 4: 256-bit tx_checksum (USE_INIT_VALUE=0, multi-beat & split 31/63, backpressure) ---
        start_m256_stall = 1'b1;
        @(negedge clk);
        start_m256_stall = 1'b0;
        for (p = 0; p < 10; p = p + 1) begin
            send_tx256_pkt(40 + p * 9, 1'b1, (p % 2 == 0) ? 8'd14 : 8'd33, (p % 2 == 0) ? 8'd31 : 8'd34);
        end
        while (m256_stall_cnt > 0) @(negedge clk);
        send_tx256_pkt(130, 1'b1, 8'd66, 8'd63); // 3-beat start skip + split across beat 1->2
        send_tx256_pkt(72,  1'b0, 8'd14, 8'd24); // passthrough
        while (rd256_ptr < wr256_ptr) @(negedge clk);

        // --- Test 5: rx_checksum across even & odd START_OFFSETs (1, 14, 15, 16, 17, 64, 65), short/multi-beat, carry-wrap & rst ---
        // Directed 17B frame for odd START_OFFSET=15: bytes[15..16] = {8'h12, 8'h34} -> must sum to 16'h1234 (not 16'h3412!)
        for (p = 0; p < 15; p = p + 1) pkt_buf[p] = 8'hAA;
        pkt_buf[15] = 8'h12;
        pkt_buf[16] = 8'h34;
        send_rx_from_buf(17);

        // Directed 16B odd-tail frame for START_OFFSET=15: byte[15] = 8'hAB -> must pad to 16'hAB00 (not 16'h00AB!)
        for (p = 0; p < 15; p = p + 1) pkt_buf[p] = 8'h55;
        pkt_buf[15] = 8'hAB;
        send_rx_from_buf(16);

        // Directed 19B cross-beat carry-wrap frame across odd START_OFFSET=15 & 17: {8'hFF, 8'h02, 8'h01, 8'hFF} -> 16'h0102
        for (p = 0; p < 15; p = p + 1) pkt_buf[p] = 8'hCC;
        pkt_buf[15] = 8'hFF;
        pkt_buf[16] = 8'h02;
        pkt_buf[17] = 8'h01;
        pkt_buf[18] = 8'hFF;
        send_rx_from_buf(19);

        // Directed 66B & 67B frames for multi-beat odd START_OFFSET=65 on 256-bit bus
        for (p = 0; p < 65; p = p + 1) pkt_buf[p] = 8'h77;
        pkt_buf[65] = 8'hDE;
        send_rx_from_buf(66);
        pkt_buf[65] = 8'hCA;
        pkt_buf[66] = 8'hFE;
        send_rx_from_buf(67);

        send_rx_pkt(10,  1'b0); // shorter than 14, 15, 16, 17, 64, 65 (only START_OFFSET=1 sums!)
        send_rx_pkt(15,  1'b0); // >14, ==15 (0x0000 on 15, 16, 17, 64, 65)
        send_rx_pkt(17,  1'b0); // >15, >16, ==17
        send_rx_pkt(65,  1'b0); // >64, ==65
        send_rx_pkt(160, 1'b1); // carry-heavy all-0xFF/0xFE across all even & odd START_OFFSETs
        for (p = 0; p < 12; p = p + 1) begin
            send_rx_pkt(16 + p * 17, 1'b0);
        end
        repeat (20) @(negedge clk);

        // Mid-frame RX reset recovery
        rx_mon_en = 1'b0;
        @(negedge clk);
        rx64_tdata = 64'hDEAD_BEEF_CAFE_BABE; rx64_tkeep = 8'hFF; rx64_tvalid = 1'b1; rx64_tlast = 1'b0;
        rx256_tdata = {8{32'hFFFF_EEEE}}; rx256_tkeep = 32'hFFFF_FFFF; rx256_tvalid = 1'b1; rx256_tlast = 1'b0;
        repeat (2) @(negedge clk);
        rst_rx = 1'b1; rx64_tvalid = 1'b0; rx256_tvalid = 1'b0;
        repeat (3) @(negedge clk);
        rst_rx = 1'b0; rx_mon_en = 1'b1;
        send_rx_pkt(96, 1'b0);
        repeat (25) @(negedge clk);

        if (rd_rx64_1  != wr_rx64  || rd_rx64_14  != wr_rx64  || rd_rx64_15  != wr_rx64  ||
            rd_rx64_16 != wr_rx64  || rd_rx64_17  != wr_rx64  ||
            rd_rx256_64 != wr_rx256 || rd_rx256_65 != wr_rx256 ||
            rd_rx256_14 != wr_rx256 || rd_rx256_15 != wr_rx256) begin
            $display("FAIL: RX packet count mismatch (64b: %0d,%0d,%0d,%0d,%0d vs %0d; 256b: %0d,%0d,%0d,%0d vs %0d)",
                     rd_rx64_1, rd_rx64_14, rd_rx64_15, rd_rx64_16, rd_rx64_17, wr_rx64,
                     rd_rx256_64, rd_rx256_65, rd_rx256_14, rd_rx256_15, wr_rx256);
            errs = errs + 1;
        end

        if (errs == 0)
            $display("PASS seed=%0d", SEED);
        else
            $display("FAIL seed=%0d errs=%0d", SEED, errs);
        $finish;
    end
endmodule
