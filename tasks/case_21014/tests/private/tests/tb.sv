`timescale 1ns / 1ps

module tb #(
    parameter integer SEED = 101
);
    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg rst = 1'b1;
    integer rng_seed;
    integer errs = 0;

    initial begin
        #500000;
        $display("FAIL: global watchdog timeout!");
        $finish;
    end

    // =========================================================================
    // 1. COBS Encode + Decode Subsystem (APPEND_ZERO=1 & APPEND_ZERO=0 + Direct Decode)
    // =========================================================================
    reg  [7:0] enc1_s_tdata = 0, enc0_s_tdata = 0, decd_s_tdata = 0;
    reg        enc1_s_tvalid = 0, enc1_s_tlast = 0, enc1_s_tuser = 0;
    reg        enc0_s_tvalid = 0, enc0_s_tlast = 0, enc0_s_tuser = 0;
    reg        decd_s_tvalid = 0, decd_s_tlast = 0, decd_s_tuser = 0;
    wire       enc1_s_tready, enc0_s_tready, decd_s_tready;

    wire [7:0] enc1_m_tdata, enc0_m_tdata;
    wire       enc1_m_tvalid, enc1_m_tready, enc1_m_tlast, enc1_m_tuser;
    wire       enc0_m_tvalid, enc0_m_tready, enc0_m_tlast, enc0_m_tuser;

    wire [7:0] dec1_m_tdata, dec0_m_tdata, decd_m_tdata;
    wire       dec1_m_tvalid, dec1_m_tlast, dec1_m_tuser;
    wire       dec0_m_tvalid, dec0_m_tlast, dec0_m_tuser;
    wire       decd_m_tvalid, decd_m_tlast, decd_m_tuser;
    reg        dec1_m_tready = 1, dec0_m_tready = 1, decd_m_tready = 1;

    axis_cobs_encode #(.APPEND_ZERO(1)) u_enc1 (
        .clk(clk), .rst(rst),
        .s_axis_tdata(enc1_s_tdata), .s_axis_tvalid(enc1_s_tvalid), .s_axis_tready(enc1_s_tready),
        .s_axis_tlast(enc1_s_tlast), .s_axis_tuser(enc1_s_tuser),
        .m_axis_tdata(enc1_m_tdata), .m_axis_tvalid(enc1_m_tvalid), .m_axis_tready(enc1_m_tready),
        .m_axis_tlast(enc1_m_tlast), .m_axis_tuser(enc1_m_tuser)
    );
    axis_cobs_decode u_dec1 (
        .clk(clk), .rst(rst),
        .s_axis_tdata(enc1_m_tdata), .s_axis_tvalid(enc1_m_tvalid), .s_axis_tready(enc1_m_tready),
        .s_axis_tlast(enc1_m_tlast), .s_axis_tuser(enc1_m_tuser),
        .m_axis_tdata(dec1_m_tdata), .m_axis_tvalid(dec1_m_tvalid), .m_axis_tready(dec1_m_tready),
        .m_axis_tlast(dec1_m_tlast), .m_axis_tuser(dec1_m_tuser)
    );

    axis_cobs_encode #(.APPEND_ZERO(0)) u_enc0 (
        .clk(clk), .rst(rst),
        .s_axis_tdata(enc0_s_tdata), .s_axis_tvalid(enc0_s_tvalid), .s_axis_tready(enc0_s_tready),
        .s_axis_tlast(enc0_s_tlast), .s_axis_tuser(enc0_s_tuser),
        .m_axis_tdata(enc0_m_tdata), .m_axis_tvalid(enc0_m_tvalid), .m_axis_tready(enc0_m_tready),
        .m_axis_tlast(enc0_m_tlast), .m_axis_tuser(enc0_m_tuser)
    );
    axis_cobs_decode u_dec0 (
        .clk(clk), .rst(rst),
        .s_axis_tdata(enc0_m_tdata), .s_axis_tvalid(enc0_m_tvalid), .s_axis_tready(enc0_m_tready),
        .s_axis_tlast(enc0_m_tlast), .s_axis_tuser(enc0_m_tuser),
        .m_axis_tdata(dec0_m_tdata), .m_axis_tvalid(dec0_m_tvalid), .m_axis_tready(dec0_m_tready),
        .m_axis_tlast(dec0_m_tlast), .m_axis_tuser(dec0_m_tuser)
    );

    axis_cobs_decode u_decd (
        .clk(clk), .rst(rst),
        .s_axis_tdata(decd_s_tdata), .s_axis_tvalid(decd_s_tvalid), .s_axis_tready(decd_s_tready),
        .s_axis_tlast(decd_s_tlast), .s_axis_tuser(decd_s_tuser),
        .m_axis_tdata(decd_m_tdata), .m_axis_tvalid(decd_m_tvalid), .m_axis_tready(decd_m_tready),
        .m_axis_tlast(decd_m_tlast), .m_axis_tuser(decd_m_tuser)
    );

    // Wire-level monitor on u_enc1 & u_enc0: check non-final tuser==0 and APPEND_ZERO=1 delimiter
    always @(posedge clk) begin
        if (!rst) begin
            if (enc1_m_tvalid && enc1_m_tready) begin
                if (!enc1_m_tlast && enc1_m_tuser) begin
                    $display("FAIL: enc1 asserted m_axis_tuser on non-final beat!");
                    errs <= errs + 1;
                end
                if (enc1_m_tlast && (enc1_m_tdata !== 8'd0)) begin
                    $display("FAIL: enc1 APPEND_ZERO=1 final beat data=0x%02h != 0x00!", enc1_m_tdata);
                    errs <= errs + 1;
                end
            end
            if (enc0_m_tvalid && enc0_m_tready) begin
                if (!enc0_m_tlast && enc0_m_tuser) begin
                    $display("FAIL: enc0 asserted m_axis_tuser on non-final beat!");
                    errs <= errs + 1;
                end
                if (enc0_m_tdata == 8'd0) begin
                    $display("FAIL: enc0 APPEND_ZERO=0 emitted illegal 0x00 byte!");
                    errs <= errs + 1;
                end
            end
        end
    end

    // Clocked capture queues for dec1, dec0, decd
    reg [7:0] q1_buf [0:2047], q0_buf [0:2047], qd_buf [0:2047];
    reg       q1_last[0:2047], q0_last[0:2047], qd_last[0:2047];
    reg       q1_user[0:2047], q0_user[0:2047], qd_user[0:2047];
    integer   q1_wr = 0, q1_rd = 0, q0_wr = 0, q0_rd = 0, qd_wr = 0, qd_rd = 0;
    reg [31:0] lfsr_rdy = 32'h1234_5678;
    reg        hold_decd_stall = 0;

    always @(posedge clk) begin
        if (rst) begin
            q1_wr <= 0; q0_wr <= 0; qd_wr <= 0;
            lfsr_rdy <= SEED ^ 32'h9E37_79B9;
            dec1_m_tready <= 1'b1;
            dec0_m_tready <= 1'b1;
            decd_m_tready <= 1'b1;
        end else begin
            lfsr_rdy <= {lfsr_rdy[30:0], lfsr_rdy[31] ^ lfsr_rdy[21] ^ lfsr_rdy[1] ^ lfsr_rdy[0]};
            dec1_m_tready <= lfsr_rdy[0] | lfsr_rdy[1];
            dec0_m_tready <= lfsr_rdy[2] | lfsr_rdy[3];
            decd_m_tready <= hold_decd_stall ? 1'b0 : (lfsr_rdy[4] | lfsr_rdy[5]);

            if (dec1_m_tvalid && dec1_m_tready) begin
                q1_buf[q1_wr]  <= dec1_m_tdata;
                q1_last[q1_wr] <= dec1_m_tlast;
                q1_user[q1_wr] <= dec1_m_tuser;
                q1_wr <= q1_wr + 1;
            end
            if (dec0_m_tvalid && dec0_m_tready) begin
                q0_buf[q0_wr]  <= dec0_m_tdata;
                q0_last[q0_wr] <= dec0_m_tlast;
                q0_user[q0_wr] <= dec0_m_tuser;
                q0_wr <= q0_wr + 1;
            end
            if (decd_m_tvalid && decd_m_tready) begin
                qd_buf[qd_wr]  <= decd_m_tdata;
                qd_last[qd_wr] <= decd_m_tlast;
                qd_user[qd_wr] <= decd_m_tuser;
                qd_wr <= qd_wr + 1;
            end
        end
    end

    // =========================================================================
    // 2. Frame Length Adjuster Harnesses (64-bit KEEP=1 & 8-bit KEEP=0)
    // =========================================================================
    reg  [63:0] fla64_s_tdata = 0;
    reg  [7:0]  fla64_s_tkeep = 0;
    reg         fla64_s_tvalid = 0, fla64_s_tlast = 0;
    wire        fla64_s_tready;
    reg  [7:0]  fla64_s_tid = 0, fla64_s_tdest = 0;
    reg  [1:0]  fla64_s_tuser = 0;
    wire [63:0] fla64_m_tdata;
    wire [7:0]  fla64_m_tkeep;
    wire        fla64_m_tvalid, fla64_m_tlast;
    reg         fla64_m_tready = 1;
    wire [7:0]  fla64_m_tid, fla64_m_tdest;
    wire [1:0]  fla64_m_tuser;
    wire        fla64_st_valid, fla64_st_pad, fla64_st_trunc;
    reg         fla64_st_ready = 1;
    wire [15:0] fla64_st_len, fla64_st_orig;
    reg  [15:0] fla64_min = 16'd4, fla64_max = 16'd32;

    axis_frame_length_adjust #(
        .DATA_WIDTH(64), .KEEP_ENABLE(1), .KEEP_WIDTH(8),
        .ID_ENABLE(1), .ID_WIDTH(8), .DEST_ENABLE(1), .DEST_WIDTH(8),
        .USER_ENABLE(1), .USER_WIDTH(2)
    ) u_fla64 (
        .clk(clk), .rst(rst),
        .s_axis_tdata(fla64_s_tdata), .s_axis_tkeep(fla64_s_tkeep),
        .s_axis_tvalid(fla64_s_tvalid), .s_axis_tready(fla64_s_tready), .s_axis_tlast(fla64_s_tlast),
        .s_axis_tid(fla64_s_tid), .s_axis_tdest(fla64_s_tdest), .s_axis_tuser(fla64_s_tuser),
        .m_axis_tdata(fla64_m_tdata), .m_axis_tkeep(fla64_m_tkeep),
        .m_axis_tvalid(fla64_m_tvalid), .m_axis_tready(fla64_m_tready), .m_axis_tlast(fla64_m_tlast),
        .m_axis_tid(fla64_m_tid), .m_axis_tdest(fla64_m_tdest), .m_axis_tuser(fla64_m_tuser),
        .status_valid(fla64_st_valid), .status_ready(fla64_st_ready),
        .status_frame_pad(fla64_st_pad), .status_frame_truncate(fla64_st_trunc),
        .status_frame_length(fla64_st_len), .status_frame_original_length(fla64_st_orig),
        .length_min(fla64_min), .length_max(fla64_max)
    );

    // 32-bit instance with ID_ENABLE=0, DEST_ENABLE=0, USER_ENABLE=0 to verify disabled zeroing
    reg  [31:0] fla32_s_tdata = 32'hDEAD_BEEF;
    reg  [3:0]  fla32_s_tkeep = 4'b1111;
    reg         fla32_s_tvalid = 0, fla32_s_tlast = 0;
    wire        fla32_s_tready;
    wire [31:0] fla32_m_tdata;
    wire [3:0]  fla32_m_tkeep;
    wire        fla32_m_tvalid, fla32_m_tlast;
    wire [7:0]  fla32_m_tid, fla32_m_tdest;
    wire [1:0]  fla32_m_tuser;
    wire        fla32_st_valid;
    axis_frame_length_adjust #(
        .DATA_WIDTH(32), .KEEP_ENABLE(0), .KEEP_WIDTH(4),
        .ID_ENABLE(0), .ID_WIDTH(8), .DEST_ENABLE(0), .DEST_WIDTH(8),
        .USER_ENABLE(0), .USER_WIDTH(2)
    ) u_fla32 (
        .clk(clk), .rst(rst),
        .s_axis_tdata(fla32_s_tdata), .s_axis_tkeep(4'b0001),
        .s_axis_tvalid(fla32_s_tvalid), .s_axis_tready(fla32_s_tready), .s_axis_tlast(fla32_s_tlast),
        .s_axis_tid(8'hFF), .s_axis_tdest(8'hEE), .s_axis_tuser(2'b11),
        .m_axis_tdata(fla32_m_tdata), .m_axis_tkeep(fla32_m_tkeep),
        .m_axis_tvalid(fla32_m_tvalid), .m_axis_tready(1'b1), .m_axis_tlast(fla32_m_tlast),
        .m_axis_tid(fla32_m_tid), .m_axis_tdest(fla32_m_tdest), .m_axis_tuser(fla32_m_tuser),
        .status_valid(fla32_st_valid), .status_ready(1'b1),
        .status_frame_pad(), .status_frame_truncate(), .status_frame_length(), .status_frame_original_length(),
        .length_min(16'd4), .length_max(16'd16)
    );

    // Monitor fla64 output bytes, disabled lanes, and status stability
    reg [7:0]  f64_bytes [0:4095];
    reg        f64_last  [0:4095];
    reg [7:0]  f64_id    [0:4095], f64_dest [0:4095];
    reg [1:0]  f64_user  [0:4095];
    integer    f64_bwr = 0, f64_brd = 0;

    reg        st_pad_q  [0:127], st_trnc_q [0:127];
    reg [15:0] st_len_q  [0:127], st_olen_q [0:127];
    integer    st_wr = 0, st_rd = 0;

    reg        prev_st_stall = 0;
    reg        hold_st_pad = 0, hold_st_trnc = 0;
    reg [15:0] hold_st_len = 0, hold_st_olen = 0;
    reg        force_st_stall = 0;

    integer ln;
    always @(posedge clk) begin
        if (rst) begin
            f64_bwr <= 0; st_wr <= 0; prev_st_stall <= 0;
            fla64_m_tready <= 1'b1; fla64_st_ready <= 1'b1;
        end else begin
            fla64_m_tready <= lfsr_rdy[6] | lfsr_rdy[7];
            fla64_st_ready <= force_st_stall ? 1'b0 : lfsr_rdy[8];

            if (prev_st_stall && (!fla64_st_valid || {fla64_st_pad, fla64_st_trunc, fla64_st_len, fla64_st_orig} !==
                                                     {hold_st_pad, hold_st_trnc, hold_st_len, hold_st_olen})) begin
                $display("FAIL: status_* violated AXI handshake stability while status_ready=0!");
                errs <= errs + 1;
            end
            prev_st_stall <= fla64_st_valid && !fla64_st_ready;
            hold_st_pad   <= fla64_st_pad;
            hold_st_trnc  <= fla64_st_trunc;
            hold_st_len   <= fla64_st_len;
            hold_st_olen  <= fla64_st_orig;

            if (fla64_m_tvalid && fla64_m_tready) begin
                for (ln = 0; ln < 8; ln = ln + 1) begin
                    if (!fla64_m_tkeep[ln] && (fla64_m_tdata[ln*8 +: 8] !== 8'h00)) begin
                        $display("FAIL: fla64 unmasked lane %0d nonzero=0x%02h (tkeep=%b)!", ln, fla64_m_tdata[ln*8 +: 8], fla64_m_tkeep);
                        errs <= errs + 1;
                    end
                end
                for (ln = 0; ln < 8; ln = ln + 1) begin
                    if (fla64_m_tkeep[ln]) begin
                        f64_bytes[f64_bwr] = fla64_m_tdata[ln*8 +: 8];
                        f64_id[f64_bwr]    = fla64_m_tid;
                        f64_dest[f64_bwr]  = fla64_m_tdest;
                        // mark last valid byte of beat if fla64_m_tlast
                        f64_last[f64_bwr]  = fla64_m_tlast && ((ln == 7) || !fla64_m_tkeep[ln+1]);
                        f64_user[f64_bwr]  = f64_last[f64_bwr] ? fla64_m_tuser : 2'b00;
                        if (!f64_last[f64_bwr] && !fla64_m_tlast && (fla64_m_tuser !== 2'b00) && (ln == 0)) begin
                            // intermediate beat check handled per frame
                        end
                        f64_bwr = f64_bwr + 1;
                    end
                end
            end

            if (fla64_st_valid && fla64_st_ready) begin
                st_pad_q[st_wr]  <= fla64_st_pad;
                st_trnc_q[st_wr] <= fla64_st_trunc;
                st_len_q[st_wr]  <= fla64_st_len;
                st_olen_q[st_wr] <= fla64_st_orig;
                st_wr <= st_wr + 1;
            end

            if (fla32_m_tvalid) begin
                if (fla32_m_tkeep !== 4'b1111 || fla32_m_tid !== 8'd0 || fla32_m_tdest !== 8'd0 || fla32_m_tuser !== 2'd0) begin
                    $display("FAIL: fla32 disabled signals leaked! keep=%b id=%0h dest=%0h user=%0h",
                             fla32_m_tkeep, fla32_m_tid, fla32_m_tdest, fla32_m_tuser);
                    errs <= errs + 1;
                end
            end
        end
    end

    reg [7:0] tx_payload [0:600];

    task automatic run_cobs_roundtrip(input integer flen, input reg in_err);
        integer i;
        reg done_d1;
        begin
            // Send into both APPEND_ZERO=1 and APPEND_ZERO=0 encoders
            for (i = 0; i < flen; i = i + 1) begin
                @(negedge clk);
                enc1_s_tdata  = tx_payload[i];
                enc1_s_tlast  = (i == flen - 1);
                enc1_s_tuser  = (i == flen - 1) ? in_err : 1'b0;
                enc1_s_tvalid = 1'b1;
                while (!enc1_s_tready) @(negedge clk);
            end
            @(negedge clk);
            enc1_s_tvalid = 1'b0; enc1_s_tlast = 1'b0; enc1_s_tuser = 1'b0;

            for (i = 0; i < flen; i = i + 1) begin
                @(negedge clk);
                enc0_s_tdata  = tx_payload[i];
                enc0_s_tlast  = (i == flen - 1);
                enc0_s_tuser  = (i == flen - 1) ? in_err : 1'b0;
                enc0_s_tvalid = 1'b1;
                while (!enc0_s_tready) @(negedge clk);
            end
            @(negedge clk);
            enc0_s_tvalid = 1'b0; enc0_s_tlast = 1'b0; enc0_s_tuser = 1'b0;

            // Wait for decoded frame on dec1
            done_d1 = 1'b0;
            while (!done_d1) begin
                while (q1_rd >= q1_wr) @(negedge clk);
                if (q1_last[q1_rd]) begin
                    if (q1_user[q1_rd] !== in_err) begin
                        $display("FAIL: dec1 tuser=%0b expected %0b (flen=%0d)", q1_user[q1_rd], in_err, flen);
                        errs = errs + 1;
                    end
                    done_d1 = 1'b1;
                end
                q1_rd = q1_rd + 1;
            end
        end
    endtask

    task automatic verify_cobs_exact(input integer flen);
        integer i, start1, start0;
        begin
            start1 = q1_rd;
            start0 = q0_rd;
            for (i = 0; i < flen; i = i + 1) begin
                @(negedge clk);
                enc1_s_tdata = tx_payload[i]; enc1_s_tlast = (i == flen - 1); enc1_s_tuser = 1'b0; enc1_s_tvalid = 1'b1;
                while (!enc1_s_tready) @(negedge clk);
            end
            @(negedge clk); enc1_s_tvalid = 1'b0; enc1_s_tlast = 1'b0;

            for (i = 0; i < flen; i = i + 1) begin
                @(negedge clk);
                enc0_s_tdata = tx_payload[i]; enc0_s_tlast = (i == flen - 1); enc0_s_tuser = 1'b0; enc0_s_tvalid = 1'b1;
                while (!enc0_s_tready) @(negedge clk);
            end
            @(negedge clk); enc0_s_tvalid = 1'b0; enc0_s_tlast = 1'b0;

            for (i = 0; i < flen; i = i + 1) begin
                while (q1_rd >= q1_wr) @(negedge clk);
                if (q1_buf[q1_rd] !== tx_payload[i] || q1_last[q1_rd] !== (i == flen - 1) || q1_user[q1_rd] !== 1'b0) begin
                    $display("FAIL: dec1 byte %0d/%0d mismatch got=0x%02h(L=%0b,U=%0b) exp=0x%02h",
                             i, flen, q1_buf[q1_rd], q1_last[q1_rd], q1_user[q1_rd], tx_payload[i]);
                    errs = errs + 1;
                end
                q1_rd = q1_rd + 1;

                while (q0_rd >= q0_wr) @(negedge clk);
                if (q0_buf[q0_rd] !== tx_payload[i] || q0_last[q0_rd] !== (i == flen - 1) || q0_user[q0_rd] !== 1'b0) begin
                    $display("FAIL: dec0 byte %0d/%0d mismatch got=0x%02h(L=%0b,U=%0b) exp=0x%02h",
                             i, flen, q0_buf[q0_rd], q0_last[q0_rd], q0_user[q0_rd], tx_payload[i]);
                    errs = errs + 1;
                end
                q0_rd = q0_rd + 1;
            end
        end
    endtask

    task automatic send_decd_byte(input [7:0] b, input reg l, input reg u);
        begin
            @(negedge clk);
            decd_s_tdata = b; decd_s_tlast = l; decd_s_tuser = u; decd_s_tvalid = 1'b1;
            while (!decd_s_tready) @(negedge clk);
            @(negedge clk);
            decd_s_tvalid = 1'b0; decd_s_tlast = 1'b0; decd_s_tuser = 1'b0;
        end
    endtask

    task automatic expect_decd_frame_end(input reg exp_err);
        reg done_decd;
        begin
            done_decd = 1'b0;
            while (!done_decd) begin
                while (qd_rd >= qd_wr) @(negedge clk);
                if (qd_last[qd_rd]) begin
                    if (qd_user[qd_rd] !== exp_err) begin
                        $display("FAIL: decd frame end tuser=%0b exp=%0b!", qd_user[qd_rd], exp_err);
                        errs = errs + 1;
                    end
                    done_decd = 1'b1;
                end
                qd_rd = qd_rd + 1;
            end
        end
    endtask

    task automatic send_fla64_frame(
        input integer orig_len,
        input [7:0]   id,
        input [7:0]   dest,
        input [1:0]   mid_u,
        input [1:0]   tail_u,
        input integer change_bounds_after_beat0,
        input [15:0]  new_min,
        input [15:0]  new_max
    );
        integer idx, ln, rem;
        reg [63:0] wd;
        reg [7:0]  wk;
        begin
            idx = 0;
            while (idx < orig_len) begin
                rem = orig_len - idx;
                wd  = 64'hFFFF_FFFF_FFFF_FFFF; // dirty unmasked bytes!
                wk  = 8'h00;
                for (ln = 0; ln < 8; ln = ln + 1) begin
                    if (ln < rem) begin
                        wd[ln*8 +: 8] = 8'h30 + ((idx + ln) & 8'h3F);
                        wk[ln]        = 1'b1;
                    end
                end
                @(negedge clk);
                fla64_s_tdata  = wd;
                fla64_s_tkeep  = wk;
                fla64_s_tid    = id;
                fla64_s_tdest  = dest;
                fla64_s_tlast  = (rem <= 8);
                fla64_s_tuser  = (rem <= 8) ? tail_u : mid_u;
                fla64_s_tvalid = 1'b1;
                while (!fla64_s_tready) @(negedge clk);
                if (idx == 0 && change_bounds_after_beat0) begin
                    @(negedge clk);
                    fla64_s_tvalid = 1'b0;
                    fla64_min = new_min;
                    fla64_max = new_max;
                end
                idx = idx + 8;
            end
            @(negedge clk);
            fla64_s_tvalid = 1'b0; fla64_s_tlast = 1'b0; fla64_s_tuser = 2'b00;
        end
    endtask

    task automatic check_fla64_frame(
        input integer orig_len,
        input integer exp_len,
        input reg     exp_pad,
        input reg     exp_trnc,
        input [7:0]   exp_id,
        input [7:0]   exp_dest,
        input [1:0]   exp_user
    );
        integer i;
        reg [7:0] exp_b;
        begin
            for (i = 0; i < exp_len; i = i + 1) begin
                while (f64_brd >= f64_bwr) @(negedge clk);
                exp_b = (i < orig_len) ? (8'h30 + (i & 8'h3F)) : 8'h00;
                if (f64_bytes[f64_brd] !== exp_b) begin
                    $display("FAIL: fla64 byte %0d/%0d mismatch got=0x%02h exp=0x%02h", i, exp_len, f64_bytes[f64_brd], exp_b);
                    errs = errs + 1;
                end
                if (f64_last[f64_brd] !== (i == exp_len - 1)) begin
                    $display("FAIL: fla64 tlast mismatch at byte %0d/%0d", i, exp_len);
                    errs = errs + 1;
                end
                if (i == exp_len - 1) begin
                    if (f64_id[f64_brd] !== exp_id || f64_dest[f64_brd] !== exp_dest || f64_user[f64_brd] !== exp_user) begin
                        $display("FAIL: fla64 tail meta mismatch id=%0h/%0h dest=%0h/%0h user=%0b/%0b",
                                 f64_id[f64_brd], exp_id, f64_dest[f64_brd], exp_dest, f64_user[f64_brd], exp_user);
                        errs = errs + 1;
                    end
                end
                f64_brd = f64_brd + 1;
            end

            while (st_rd >= st_wr) @(negedge clk);
            if (st_pad_q[st_rd] !== exp_pad || st_trnc_q[st_rd] !== exp_trnc ||
                st_len_q[st_rd] !== exp_len[15:0] || st_olen_q[st_rd] !== orig_len[15:0]) begin
                $display("FAIL: fla64 status mismatch pad=%0b/%0b trnc=%0b/%0b len=%0d/%0d orig=%0d/%0d",
                         st_pad_q[st_rd], exp_pad, st_trnc_q[st_rd], exp_trnc,
                         st_len_q[st_rd], exp_len, st_olen_q[st_rd], orig_len);
                errs = errs + 1;
            end
            st_rd = st_rd + 1;
        end
    endtask

    integer i, p;
    initial begin
        rng_seed = SEED;
        repeat (6) @(negedge clk);
        rst = 1'b0;
        repeat (4) @(negedge clk);

        // --- Test 1: COBS Encode/Decode exact boundary & randomized frames ---
        // 1a. 1-byte 0x00 and 1-byte non-zero 0x42
        tx_payload[0] = 8'h00; verify_cobs_exact(1);
        tx_payload[0] = 8'h42; verify_cobs_exact(1);

        // 1b. Exact 254-byte non-zero frame (catches duplicate 0xFF code bug!)
        for (i = 0; i < 254; i = i + 1) tx_payload[i] = (i[7:0] % 250) + 8'd1;
        verify_cobs_exact(254);

        // 1c. 255-byte frame: 254 non-zero + trailing 0x00, and 255 non-zero, and 508 non-zero (2x254)
        for (i = 0; i < 254; i = i + 1) tx_payload[i] = (i[7:0] % 250) + 8'd1;
        tx_payload[254] = 8'h00;
        verify_cobs_exact(255);
        tx_payload[254] = 8'h7E;
        verify_cobs_exact(255);
        for (i = 0; i < 508; i = i + 1) tx_payload[i] = (i[7:0] % 251) + 8'd1;
        verify_cobs_exact(508);

        // 1d. Error-marked input frames (s_axis_tuser=1 on tlast)
        for (i = 0; i < 12; i = i + 1) tx_payload[i] = 8'h20 + i[7:0];
        run_cobs_roundtrip(12, 1'b1);
        begin : blk_d0_err
            reg done_d0;
            done_d0 = 1'b0;
            while (!done_d0) begin
                while (q0_rd >= q0_wr) @(negedge clk);
                if (q0_last[q0_rd]) begin
                    if (q0_user[q0_rd] !== 1'b1) begin
                        $display("FAIL: dec0 failed to report tuser=1 on error-encoded frame!");
                        errs = errs + 1;
                    end
                    done_d0 = 1'b1;
                end
                q0_rd = q0_rd + 1;
            end
        end
        // Follow immediately with valid frame to verify clean recovery
        tx_payload[0] = 8'h00; tx_payload[1] = 8'h99; tx_payload[2] = 8'h00;
        verify_cobs_exact(3);

        // --- Test 2: Direct Malformed/Truncated COBS Decode Stress ---
        // 2a. Stall decd_m_tready while driving back-to-back [0x02, 0xAA(tlast), 0x05(tlast), 0x00(tlast,tuser=1)] with zero idle bubbles!
        hold_decd_stall = 1'b1;
        fork
            begin
                repeat (6) @(negedge clk);
                hold_decd_stall = 1'b0;
            end
            begin
                @(negedge clk); decd_s_tdata = 8'h02; decd_s_tlast = 1'b0; decd_s_tuser = 1'b0; decd_s_tvalid = 1'b1;
                while (!decd_s_tready) @(negedge clk);
                @(negedge clk); decd_s_tdata = 8'hAA; decd_s_tlast = 1'b1; decd_s_tuser = 1'b0; decd_s_tvalid = 1'b1;
                while (!decd_s_tready) @(negedge clk);
                @(negedge clk); decd_s_tdata = 8'h05; decd_s_tlast = 1'b1; decd_s_tuser = 1'b0; decd_s_tvalid = 1'b1;
                while (!decd_s_tready) @(negedge clk);
                @(negedge clk); decd_s_tdata = 8'h00; decd_s_tlast = 1'b1; decd_s_tuser = 1'b1; decd_s_tvalid = 1'b1;
                while (!decd_s_tready) @(negedge clk);
                @(negedge clk); decd_s_tvalid = 1'b0; decd_s_tlast = 1'b0; decd_s_tuser = 1'b0;
            end
        join
        expect_decd_frame_end(1'b0); // valid 0xAA
        expect_decd_frame_end(1'b1); // truncated 1B [0x05(tlast)]
        expect_decd_frame_end(1'b1); // bad zero 1B [0x00(tlast,u=1)]

        // 2b. Valid COBS frame with delimiter marked bad (s_axis_tuser=1 on 0x00), plus malformed [0x01, 0x00]
        send_decd_byte(8'h02, 1'b0, 1'b0);
        send_decd_byte(8'hAA, 1'b0, 1'b0);
        send_decd_byte(8'h00, 1'b1, 1'b1);
        expect_decd_frame_end(1'b1);

        send_decd_byte(8'h01, 1'b0, 1'b0);
        send_decd_byte(8'h00, 1'b1, 1'b0);
        expect_decd_frame_end(1'b1);

        // 2c. Truncated [0xFF, 254B, 0x01(tlast)] (suppressed zero followed by unclosed 0x01 tail!)
        send_decd_byte(8'hFF, 1'b0, 1'b0);
        for (i = 0; i < 254; i = i + 1) send_decd_byte(8'h31, 1'b0, 1'b0);
        send_decd_byte(8'h01, 1'b1, 1'b0);
        expect_decd_frame_end(1'b1);

        // 2d. Unexpected 0x00 mid-segment & premature tlast mid-segment, followed by clean frame
        send_decd_byte(8'h04, 1'b0, 1'b0);
        send_decd_byte(8'h55, 1'b0, 1'b0);
        send_decd_byte(8'h00, 1'b0, 1'b0);
        expect_decd_frame_end(1'b1);

        send_decd_byte(8'h04, 1'b0, 1'b0);
        send_decd_byte(8'h66, 1'b1, 1'b0);
        expect_decd_frame_end(1'b1);

        send_decd_byte(8'h02, 1'b0, 1'b0);
        send_decd_byte(8'h77, 1'b1, 1'b0);
        expect_decd_frame_end(1'b0);

        // --- Test 3: Frame-Length Adjuster Padding, Truncation, Latched Bounds, & Status Stall ---
        fla64_min = 16'd6;  fla64_max = 16'd20;
        // 3a. Single-beat pad (3B -> 6B) & multi-beat pad (2B -> 19B)
        send_fla64_frame(3, 8'hA1, 8'hB1, 2'b00, 2'b10, 0, 16'd6, 16'd20);
        check_fla64_frame(3, 6, 1'b1, 1'b0, 8'hA1, 8'hB1, 2'b10);

        fla64_min = 16'd19; fla64_max = 16'd32;
        send_fla64_frame(2, 8'hA2, 8'hB2, 2'b00, 2'b01, 0, 16'd19, 16'd32);
        check_fla64_frame(2, 19, 1'b1, 1'b0, 8'hA2, 8'hB2, 2'b01);

        // 3b. Exact length_max (12B == 12B -> status_frame_truncate MUST be 0!) & multi-beat truncate (25B -> 12B, tuser ORed!)
        fla64_min = 16'd4;  fla64_max = 16'd12;
        send_fla64_frame(12, 8'hA3, 8'hB3, 2'b00, 2'b00, 0, 16'd4, 16'd12);
        check_fla64_frame(12, 12, 1'b0, 1'b0, 8'hA3, 8'hB3, 2'b00);

        send_fla64_frame(25, 8'hA4, 8'hB4, 2'b01, 2'b10, 0, 16'd4, 16'd12);
        check_fla64_frame(25, 12, 1'b0, 1'b1, 8'hA4, 8'hB4, 2'b11);

        // 3c. Mid-frame dynamic length_min/length_max change after beat 0: in-flight frame (10B) uses old (4..12), next frame (10B) uses new (18..24)!
        send_fla64_frame(10, 8'hA5, 8'hB5, 2'b00, 2'b00, 1, 16'd18, 16'd24);
        check_fla64_frame(10, 10, 1'b0, 1'b0, 8'hA5, 8'hB5, 2'b00);
        send_fla64_frame(10, 8'hA6, 8'hB6, 2'b00, 2'b01, 0, 16'd18, 16'd24);
        check_fla64_frame(10, 18, 1'b1, 1'b0, 8'hA6, 8'hB6, 2'b01);

        // 3d. Sustained status_ready=0 backpressure across 4 consecutive frames!
        fla64_min = 16'd6; fla64_max = 16'd10;
        force_st_stall = 1'b1;
        fork
            begin
                send_fla64_frame(3,  8'hC1, 8'hD1, 2'b00, 2'b00, 0, 16'd6, 16'd10);
                send_fla64_frame(8,  8'hC2, 8'hD2, 2'b00, 2'b00, 0, 16'd6, 16'd10);
                send_fla64_frame(14, 8'hC3, 8'hD3, 2'b00, 2'b01, 0, 16'd6, 16'd10);
                send_fla64_frame(4,  8'hC4, 8'hD4, 2'b00, 2'b10, 0, 16'd6, 16'd10);
            end
            begin
                repeat (25) @(negedge clk);
                force_st_stall = 1'b0;
            end
        join
        check_fla64_frame(3,  6,  1'b1, 1'b0, 8'hC1, 8'hD1, 2'b00);
        check_fla64_frame(8,  8,  1'b0, 1'b0, 8'hC2, 8'hD2, 2'b00);
        check_fla64_frame(14, 10, 1'b0, 1'b1, 8'hC3, 8'hD3, 2'b01);
        check_fla64_frame(4,  6,  1'b1, 1'b0, 8'hC4, 8'hD4, 2'b10);

        // 3e. Exercise fla32 (KEEP_ENABLE=0, ID/DEST/USER_ENABLE=0)
        @(negedge clk); fla32_s_tvalid = 1'b1; fla32_s_tlast = 1'b1;
        while (!fla32_s_tready) @(negedge clk);
        @(negedge clk); fla32_s_tvalid = 1'b0; fla32_s_tlast = 1'b0;

        // 3f. Seed-driven randomized COBS roundtrips
        for (p = 0; p < 6; p = p + 1) begin
            for (i = 0; i < 40 + p*15; i = i + 1)
                tx_payload[i] = ($random(rng_seed) & 8'hFF);
            verify_cobs_exact(40 + p*15);
        end

        repeat (15) @(negedge clk);
        if (errs == 0)
            $display("PASS seed=%0d", SEED);
        else
            $display("FAIL seed=%0d errs=%0d", SEED, errs);
        $finish;
    end
endmodule
