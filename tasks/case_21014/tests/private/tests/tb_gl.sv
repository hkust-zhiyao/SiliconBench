`timescale 1ns / 1ps

module tb_gl #(
    parameter integer SEED = 101
);
    reg clk = 1'b0;
    always #5 clk = ~clk;
    reg rst = 1'b1;
    integer errs = 0;

    // 1. Encode RTL vs GL
    reg  [7:0] enc_in_d = 0;
    reg        enc_in_v = 0, enc_in_l = 0, enc_in_u = 0, enc_out_r = 1;
    wire       enc_rdy_r, enc_rdy_g, enc_v_r, enc_v_g, enc_l_r, enc_l_g, enc_u_r, enc_u_g;
    wire [7:0] enc_d_r, enc_d_g;

    axis_cobs_encode #(.APPEND_ZERO(1)) u_enc_rtl (
        .clk(clk), .rst(rst),
        .s_axis_tdata(enc_in_d), .s_axis_tvalid(enc_in_v), .s_axis_tready(enc_rdy_r), .s_axis_tlast(enc_in_l), .s_axis_tuser(enc_in_u),
        .m_axis_tdata(enc_d_r),  .m_axis_tvalid(enc_v_r),   .m_axis_tready(enc_out_r), .m_axis_tlast(enc_l_r),   .m_axis_tuser(enc_u_r)
    );
    axis_cobs_encode_gl u_enc_gl (
        .clk(clk), .rst(rst),
        .s_axis_tdata(enc_in_d), .s_axis_tvalid(enc_in_v), .s_axis_tready(enc_rdy_g), .s_axis_tlast(enc_in_l), .s_axis_tuser(enc_in_u),
        .m_axis_tdata(enc_d_g),  .m_axis_tvalid(enc_v_g),   .m_axis_tready(enc_out_r), .m_axis_tlast(enc_l_g),   .m_axis_tuser(enc_u_g)
    );

    // 2. Decode RTL vs GL
    reg  [7:0] dec_in_d = 0;
    reg        dec_in_v = 0, dec_in_l = 0, dec_in_u = 0, dec_out_r = 1;
    wire       dec_rdy_r, dec_rdy_g, dec_v_r, dec_v_g, dec_l_r, dec_l_g, dec_u_r, dec_u_g;
    wire [7:0] dec_d_r, dec_d_g;

    axis_cobs_decode u_dec_rtl (
        .clk(clk), .rst(rst),
        .s_axis_tdata(dec_in_d), .s_axis_tvalid(dec_in_v), .s_axis_tready(dec_rdy_r), .s_axis_tlast(dec_in_l), .s_axis_tuser(dec_in_u),
        .m_axis_tdata(dec_d_r),  .m_axis_tvalid(dec_v_r),   .m_axis_tready(dec_out_r), .m_axis_tlast(dec_l_r),   .m_axis_tuser(dec_u_r)
    );
    axis_cobs_decode_gl u_dec_gl (
        .clk(clk), .rst(rst),
        .s_axis_tdata(dec_in_d), .s_axis_tvalid(dec_in_v), .s_axis_tready(dec_rdy_g), .s_axis_tlast(dec_in_l), .s_axis_tuser(dec_in_u),
        .m_axis_tdata(dec_d_g),  .m_axis_tvalid(dec_v_g),   .m_axis_tready(dec_out_r), .m_axis_tlast(dec_l_g),   .m_axis_tuser(dec_u_g)
    );

    // 3. Frame Length Adjuster (32-bit) RTL vs GL
    reg  [31:0] adj_in_d = 0;
    reg  [3:0]  adj_in_k = 0;
    reg         adj_in_v = 0, adj_in_l = 0, adj_out_r = 1, adj_st_r = 1;
    reg  [7:0]  adj_in_id = 0, adj_in_dest = 0;
    reg  [1:0]  adj_in_u = 0;
    reg  [15:0] adj_min = 16'd6, adj_max = 16'd10;

    wire        adj_rdy_r, adj_rdy_g, adj_v_r, adj_v_g, adj_l_r, adj_l_g;
    wire [31:0] adj_d_r, adj_d_g;
    wire [3:0]  adj_k_r, adj_k_g;
    wire [7:0]  adj_id_r, adj_id_g, adj_dest_r, adj_dest_g;
    wire [1:0]  adj_u_r, adj_u_g;
    wire        st_v_r, st_v_g, st_p_r, st_p_g, st_t_r, st_t_g;
    wire [15:0] st_l_r, st_l_g, st_o_r, st_o_g;

    axis_frame_length_adjust #(
        .DATA_WIDTH(32), .KEEP_ENABLE(1), .KEEP_WIDTH(4),
        .ID_ENABLE(1), .ID_WIDTH(8), .DEST_ENABLE(1), .DEST_WIDTH(8), .USER_ENABLE(1), .USER_WIDTH(2)
    ) u_adj_rtl (
        .clk(clk), .rst(rst),
        .s_axis_tdata(adj_in_d), .s_axis_tkeep(adj_in_k), .s_axis_tvalid(adj_in_v), .s_axis_tready(adj_rdy_r),
        .s_axis_tlast(adj_in_l), .s_axis_tid(adj_in_id), .s_axis_tdest(adj_in_dest), .s_axis_tuser(adj_in_u),
        .m_axis_tdata(adj_d_r), .m_axis_tkeep(adj_k_r), .m_axis_tvalid(adj_v_r), .m_axis_tready(adj_out_r),
        .m_axis_tlast(adj_l_r), .m_axis_tid(adj_id_r), .m_axis_tdest(adj_dest_r), .m_axis_tuser(adj_u_r),
        .status_valid(st_v_r), .status_ready(adj_st_r), .status_frame_pad(st_p_r),
        .status_frame_truncate(st_t_r), .status_frame_length(st_l_r), .status_frame_original_length(st_o_r),
        .length_min(adj_min), .length_max(adj_max)
    );
    axis_frame_length_adjust_gl u_adj_gl (
        .clk(clk), .rst(rst),
        .s_axis_tdata(adj_in_d), .s_axis_tkeep(adj_in_k), .s_axis_tvalid(adj_in_v), .s_axis_tready(adj_rdy_g),
        .s_axis_tlast(adj_in_l), .s_axis_tid(adj_in_id), .s_axis_tdest(adj_in_dest), .s_axis_tuser(adj_in_u),
        .m_axis_tdata(adj_d_g), .m_axis_tkeep(adj_k_g), .m_axis_tvalid(adj_v_g), .m_axis_tready(adj_out_r),
        .m_axis_tlast(adj_l_g), .m_axis_tid(adj_id_g), .m_axis_tdest(adj_dest_g), .m_axis_tuser(adj_u_g),
        .status_valid(st_v_g), .status_ready(adj_st_r), .status_frame_pad(st_p_g),
        .status_frame_truncate(st_t_g), .status_frame_length(st_l_g), .status_frame_original_length(st_o_g),
        .length_min(adj_min), .length_max(adj_max)
    );

    reg [31:0] lfsr = 32'hA5A5_0101;
    always @(posedge clk) begin
        if (rst) begin
            lfsr <= SEED ^ 32'h55AA_1234;
            enc_out_r <= 1; dec_out_r <= 1; adj_out_r <= 1; adj_st_r <= 1;
        end else begin
            lfsr <= {lfsr[30:0], lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]};
            enc_out_r <= lfsr[0] | lfsr[1];
            dec_out_r <= lfsr[2] | lfsr[3];
            adj_out_r <= lfsr[4] | lfsr[5];
            adj_st_r  <= lfsr[6];
        end
    end

    always @(negedge clk) begin
        if (!rst) begin
            if ({enc_rdy_g, enc_v_g} !== {enc_rdy_r, enc_v_r} ||
                (enc_v_r && ({enc_d_g, enc_l_g, enc_u_g} !== {enc_d_r, enc_l_r, enc_u_r}))) begin
                $display("FAIL_GL: encode parity mismatch! gl=%b/%02h rtl=%b/%02h", enc_v_g, enc_d_g, enc_v_r, enc_d_r);
                errs = errs + 1;
            end
            if ({dec_rdy_g, dec_v_g} !== {dec_rdy_r, dec_v_r} ||
                (dec_v_r && ({dec_d_g, dec_l_g, dec_u_g} !== {dec_d_r, dec_l_r, dec_u_r}))) begin
                $display("FAIL_GL: decode parity mismatch! gl=%b/%02h(u=%b) rtl=%b/%02h(u=%b)",
                         dec_v_g, dec_d_g, dec_u_g, dec_v_r, dec_d_r, dec_u_r);
                errs = errs + 1;
            end
            if ({adj_rdy_g, adj_v_g, st_v_g} !== {adj_rdy_r, adj_v_r, st_v_r} ||
                (adj_v_r && ({adj_d_g, adj_k_g, adj_l_g, adj_id_g, adj_dest_g, adj_u_g} !==
                             {adj_d_r, adj_k_r, adj_l_r, adj_id_r, adj_dest_r, adj_u_r})) ||
                (st_v_r && ({st_p_g, st_t_g, st_l_g, st_o_g} !== {st_p_r, st_t_r, st_l_r, st_o_r}))) begin
                $display("FAIL_GL: frame_length_adjust parity mismatch!");
                errs = errs + 1;
            end
        end
    end

    integer i;
    initial begin
        #200000;
        $display("FAIL: tb_gl watchdog timeout!");
        $finish;
    end

    initial begin
        repeat (6) @(negedge clk);
        rst = 1'b0;
        repeat (4) @(negedge clk);

        // Exercise encode (including 254B exact tail + 0x00 + bad frame)
        for (i = 0; i < 254; i = i + 1) begin
            @(negedge clk); enc_in_d = (i[7:0] % 250) + 8'd1; enc_in_l = (i == 253); enc_in_u = 1'b0; enc_in_v = 1'b1;
            while (!enc_rdy_r) @(negedge clk);
        end
        @(negedge clk); enc_in_d = 8'h55; enc_in_l = 1'b1; enc_in_u = 1'b1; enc_in_v = 1'b1;
        while (!enc_rdy_r) @(negedge clk);
        @(negedge clk); enc_in_v = 1'b0; enc_in_l = 1'b0; enc_in_u = 1'b0;

        // Exercise decode (valid + malformed [0x01,0x00] + 1B truncated [0x03(tlast)])
        for (i = 0; i < 5; i = i + 1) begin
            @(negedge clk);
            case (i)
                0: begin dec_in_d = 8'h02; dec_in_l = 0; dec_in_u = 0; end
                1: begin dec_in_d = 8'h44; dec_in_l = 1; dec_in_u = 0; end
                2: begin dec_in_d = 8'h01; dec_in_l = 0; dec_in_u = 0; end
                3: begin dec_in_d = 8'h00; dec_in_l = 1; dec_in_u = 0; end
                4: begin dec_in_d = 8'h03; dec_in_l = 1; dec_in_u = 0; end
            endcase
            dec_in_v = 1'b1;
            while (!dec_rdy_r) @(negedge clk);
        end
        @(negedge clk); dec_in_v = 1'b0; dec_in_l = 1'b0;

        // Exercise adj (pad 2B->6B and truncate 14B->10B)
        @(negedge clk); adj_in_d = 32'hAABB_CCDD; adj_in_k = 4'b0011; adj_in_id = 8'h12; adj_in_dest = 8'h34; adj_in_u = 2'b01; adj_in_l = 1'b1; adj_in_v = 1'b1;
        while (!adj_rdy_r) @(negedge clk);
        for (i = 0; i < 4; i = i + 1) begin
            @(negedge clk);
            adj_in_d = 32'h1122_3344 + i; adj_in_k = (i == 3) ? 4'b0011 : 4'b1111;
            adj_in_id = 8'h56; adj_in_dest = 8'h78; adj_in_u = (i == 3) ? 2'b10 : 2'b01; adj_in_l = (i == 3); adj_in_v = 1'b1;
            while (!adj_rdy_r) @(negedge clk);
        end
        @(negedge clk); adj_in_v = 1'b0; adj_in_l = 1'b0;

        repeat (30) @(negedge clk);
        if (errs == 0)
            $display("PASS_GL seed=%0d", SEED);
        else
            $display("FAIL_GL seed=%0d errs=%0d", SEED, errs);
        $finish;
    end
endmodule
