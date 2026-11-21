`timescale 1ns/1ps

module tb_gls;
    reg          clk = 1'b0;
    always #2.0  clk = ~clk;
    reg          reset;

    reg  [0:0]   macro_valid;
    wire [0:0]   macro_ready;
    reg  [0:0]   macro_wid;
    reg  [0:0]   macro_cta_id;
    reg  [7:0]   macro_tmask;
    reg  [29:0]  macro_PC;
    reg  [3:0]   macro_op_type;
    reg  [4:0]   macro_fmt_s;
    reg  [4:0]   macro_fmt_d;
    reg  [0:0]   macro_a_from_smem;
    reg  [1:0]   macro_cd_nregs;

    wire [0:0]   uop_valid;
    reg  [0:0]   uop_ready;
    wire [0:0]   uop_fire;
    wire [0:0]   rf_rd_wid;
    wire [5:0]   rf_rs1_addr;
    wire [5:0]   rf_rs2_addr;
    wire [5:0]   rf_rs3_addr;
    wire [2:0]   rf_used_rs;
    wire [0:0]   uop_wb;
    wire [5:0]   uop_rd_addr;
    wire [0:0]   uop_fu_lock;
    wire [0:0]   uop_fu_unlock;
    reg  [255:0] rf_rs1_data;
    reg  [255:0] rf_rs2_data;
    reg  [255:0] rf_rs3_data;

    reg          meta_wr_en;
    reg  [0:0]   meta_wr_wid;
    reg  [4:0]   meta_wr_idx;
    reg  [255:0] meta_wr_data;

    wire         lmem_req_valid;
    reg          lmem_req_ready;
    wire         lmem_req_rw;
    wire [8:0]   lmem_req_addr;
    wire [2:0]   lmem_req_tag;
    reg          lmem_rsp_valid;
    wire         lmem_rsp_ready;
    reg  [255:0] lmem_rsp_data;
    reg  [2:0]   lmem_rsp_tag;

    wire [0:0]   res_valid;
    reg  [0:0]   res_ready;
    wire [0:0]   res_wid;
    wire [0:0]   res_cta_id;
    wire [7:0]   res_tmask;
    wire [29:0]  res_PC;
    wire [0:0]   res_wb;
    wire [5:0]   res_rd;
    wire [255:0] res_data;

    VX_tcu_subsys dut (
        .clk               (clk),
        .reset             (reset),
        .macro_valid       (macro_valid),
        .macro_ready       (macro_ready),
        .macro_wid         (macro_wid),
        .macro_cta_id      (macro_cta_id),
        .macro_tmask       (macro_tmask),
        .macro_PC          (macro_PC),
        .macro_op_type     (macro_op_type),
        .macro_fmt_s       (macro_fmt_s),
        .macro_fmt_d       (macro_fmt_d),
        .macro_a_from_smem (macro_a_from_smem),
        .macro_cd_nregs    (macro_cd_nregs),
        .uop_valid         (uop_valid),
        .uop_ready         (uop_ready),
        .uop_fire          (uop_fire),
        .rf_rd_wid         (rf_rd_wid),
        .rf_rs1_addr       (rf_rs1_addr),
        .rf_rs2_addr       (rf_rs2_addr),
        .rf_rs3_addr       (rf_rs3_addr),
        .rf_used_rs        (rf_used_rs),
        .uop_wb            (uop_wb),
        .uop_rd_addr       (uop_rd_addr),
        .uop_fu_lock       (uop_fu_lock),
        .uop_fu_unlock     (uop_fu_unlock),
        .rf_rs1_data       (rf_rs1_data),
        .rf_rs2_data       (rf_rs2_data),
        .rf_rs3_data       (rf_rs3_data),
        .meta_wr_en        (meta_wr_en),
        .meta_wr_wid       (meta_wr_wid),
        .meta_wr_idx       (meta_wr_idx),
        .meta_wr_data      (meta_wr_data),
        .lmem_req_valid    (lmem_req_valid),
        .lmem_req_ready    (lmem_req_ready),
        .lmem_req_rw       (lmem_req_rw),
        .lmem_req_addr     (lmem_req_addr),
        .lmem_req_tag      (lmem_req_tag),
        .lmem_rsp_valid    (lmem_rsp_valid),
        .lmem_rsp_ready    (lmem_rsp_ready),
        .lmem_rsp_data     (lmem_rsp_data),
        .lmem_rsp_tag      (lmem_rsp_tag),
        .res_valid         (res_valid),
        .res_ready         (res_ready),
        .res_wid           (res_wid),
        .res_cta_id        (res_cta_id),
        .res_tmask         (res_tmask),
        .res_PC            (res_PC),
        .res_wb            (res_wb),
        .res_rd            (res_rd),
        .res_data          (res_data)
    );

    reg [31:0]  lmem [0:4095];
    reg [255:0] rf   [0:1][0:63];
    reg [7:0]   exp_fifo [0:255];
    integer     q_head = 0, q_tail = 0, errs = 0, retires = 0;

    always @(*) begin
        uop_ready   = 1'b1;
        rf_rs1_data = rf[rf_rd_wid][rf_rs1_addr];
        rf_rs2_data = rf[rf_rd_wid][rf_rs2_addr];
        rf_rs3_data = rf[rf_rd_wid][rf_rs3_addr];
    end

    integer b_idx;
    always @(posedge clk) begin
        if (reset) begin
            lmem_rsp_valid <= 1'b0;
            lmem_rsp_data  <= 256'd0;
            lmem_rsp_tag   <= 3'd0;
            q_head         <= 0;
            q_tail         <= 0;
        end else begin
            if (^uop_valid === 1'bx || ^lmem_req_valid === 1'bx || ^res_valid === 1'bx) begin
                $display("GLS_ERR: X on handshake valid signals");
                errs <= errs + 1;
            end
            lmem_rsp_valid <= 1'b0;
            if (lmem_req_valid && lmem_req_ready) begin
                if (^lmem_req_addr === 1'bx || ^lmem_req_tag === 1'bx || lmem_req_rw !== 1'b0) begin
                    $display("GLS_ERR: X/invalid on lmem_req");
                    errs <= errs + 1;
                end
                lmem_rsp_valid <= 1'b1;
                lmem_rsp_tag   <= lmem_req_tag;
                for (b_idx = 0; b_idx < 8; b_idx = b_idx + 1)
                    lmem_rsp_data[b_idx*32 +: 32] <= lmem[lmem_req_addr * 8 + b_idx];
            end
            if (uop_fire[0]) begin
                exp_fifo[q_tail] <= {rf_rd_wid[0], uop_wb[0], uop_rd_addr};
                q_tail <= q_tail + 1;
            end
            if (res_valid[0] && res_ready[0]) begin
                retires <= retires + 1;
                if (^res_wid === 1'bx || ^res_wb === 1'bx || (res_wb[0] && (^res_rd === 1'bx || ^res_data === 1'bx))) begin
                    $display("GLS_FAIL: X propagated to committed result");
                    errs <= errs + 1;
                end
                if (q_head >= q_tail) begin
                    $display("GLS_FAIL: unexpected retirement");
                    errs <= errs + 1;
                end else begin
                    if ({res_wid[0], res_wb[0]} !== exp_fifo[q_head][7:6]
                        || (exp_fifo[q_head][6] && res_rd !== exp_fifo[q_head][5:0])) begin
                        $display("GLS_FAIL: FIFO order mismatch got=%h exp=%h",
                                 {res_wid[0], res_wb[0], res_rd}, exp_fifo[q_head]);
                        errs <= errs + 1;
                    end
                    q_head <= q_head + 1;
                end
                if (res_wb[0])
                    rf[res_wid[0]][res_rd] <= res_data;
            end
        end
    end

    task issue_op(input reg wid_i, input reg cta_i, input [3:0] op_i, input reg a_smem_i);
        integer g;
        begin
            @(negedge clk);
            macro_valid       = 1'b1;
            macro_wid         = wid_i;
            macro_cta_id      = cta_i;
            macro_tmask       = 8'hFF;
            macro_PC          = 30'h100;
            macro_op_type     = op_i;
            macro_fmt_s       = 5'd17;
            macro_fmt_d       = 5'd16;
            macro_a_from_smem = a_smem_i;
            macro_cd_nregs    = 2'd0;
            g = 0;
            while (g < 2000) begin
                @(posedge clk);
                if (macro_valid[0] && macro_ready[0]) g = 9999;
                else g = g + 1;
            end
            if (g != 9999) begin $display("GLS_FAIL: macro timeout"); errs = errs + 1; end
            @(negedge clk);
            macro_valid = 1'b0;
        end
    endtask

    integer idx, w_i, r_i;
    reg [31:0] tmp_w;
    initial begin
        reset = 1'b1; macro_valid = 1'b0; macro_wid = 1'b0; macro_cta_id = 1'b0;
        macro_tmask = 8'd0; macro_PC = 30'd0; macro_op_type = 4'd0;
        macro_fmt_s = 5'd0; macro_fmt_d = 5'd0; macro_a_from_smem = 1'b0; macro_cd_nregs = 2'd0;
        meta_wr_en = 1'b0; meta_wr_wid = 1'b0; meta_wr_idx = 5'd0; meta_wr_data = 256'd0;
        lmem_req_ready = 1'b1; res_ready = 1'b1;
        for (idx = 0; idx < 4096; idx = idx + 1) lmem[idx] = 32'hA500_0000 ^ (idx * 32'h0101_0103);
        for (w_i = 0; w_i < 2; w_i = w_i + 1)
            for (r_i = 0; r_i < 64; r_i = r_i + 1) begin
                tmp_w = 32'h1100_0000 ^ ((w_i * 64 + r_i) * 32'h0001_1001);
                rf[w_i][r_i] = {8{tmp_w}};
            end
        // Set x10/x11 WGMMA descriptors with sub-row straddling offsets
        rf[0][10] = {8{32'h0018_0088}}; // stride=24B (6w), base=0x88 (sub_off=2w)
        rf[0][11] = {8{32'h0028_0218}}; // stride=40B (10w), base=0x218 (sub_off=6w -> straddles!)
        rf[1][10] = {8{32'h0000_0100}};
        rf[1][11] = {8{32'h0028_0318}};

        repeat (6) @(posedge clk);
        @(negedge clk); reset = 1'b0;
        repeat (8) @(posedge clk);
        if (^macro_ready === 1'bx || uop_valid !== 1'b0 || res_valid !== 1'b0) begin
            $display("GLS_FAIL: post-reset X/idle check failed");
            errs = errs + 1;
        end
        for (w_i = 0; w_i < 2; w_i = w_i + 1) begin
            for (idx = 0; idx < 4; idx = idx + 1) begin
                @(negedge clk); meta_wr_en = 1'b1; meta_wr_wid = w_i[0]; meta_wr_idx = idx[4:0]; meta_wr_data = {8{32'h9966_55AA}};
                @(posedge clk);
            end
        end
        @(negedge clk); meta_wr_en = 1'b0;

        // 1) SS WGMMA straddling + 2) Back-to-back WMMA(w0) -> RS WGMMA(w1) under res_ready stall + 3) WGMMA_SP
        issue_op(1'b0, 1'b0, 4'h1, 1'b1);
        repeat (40) @(posedge clk);
        @(negedge clk); res_ready = 1'b0;
        fork
            begin repeat (8) @(posedge clk); @(negedge clk); res_ready = 1'b1; end
            begin
                issue_op(1'b0, 1'b0, 4'h0, 1'b0);
                issue_op(1'b1, 1'b1, 4'h1, 1'b0);
            end
        join
        repeat (60) @(posedge clk);
        issue_op(1'b0, 1'b0, 4'h4, 1'b1);
        repeat (60) @(posedge clk);

        if (errs == 0 && q_head == q_tail && retires >= 30) begin
            $display("GLS_PASS retires=%0d", retires);
            $finish;
        end else begin
            $display("GLS_FAIL errs=%0d q_head=%0d q_tail=%0d retires=%0d", errs, q_head, q_tail, retires);
            $finish;
        end
    end
endmodule
