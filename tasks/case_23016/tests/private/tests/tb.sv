`timescale 1ns/1ps
`include "VX_define.vh"

module tb;
    import VX_gpu_pkg::*;
    import VX_tcu_pkg::*;

    localparam int BLOCK_SIZE      = `VX_CFG_NUM_TCU_BLOCKS;
    localparam int NUM_BANKS       = `VX_CFG_LMEM_NUM_BANKS;
    localparam int BANK_ADDR_WIDTH = `VX_CFG_LMEM_LOG_SIZE
                                   - $clog2(`VX_CFG_XLEN / 8)
                                   - $clog2(`VX_CFG_LMEM_NUM_BANKS);
    localparam int LMEM_DATA_BITS  = NUM_BANKS * `VX_CFG_XLEN;
    localparam int BLOCK_DATA_BITS = TCU_BLOCK_CAP * `VX_CFG_XLEN;
    localparam int LMEM_ROWS       = (1 << BANK_ADDR_WIDTH);
    localparam int NUM_WARPS_TB    = `VX_CFG_NUM_WARPS;
    localparam int TOTAL_REGS      = (1 << NUM_REGS_BITS);

    logic clk = 1'b0;
    always #2.0 clk = ~clk;
    logic reset;

    logic [BLOCK_SIZE-1:0]                      macro_valid;
    wire  [BLOCK_SIZE-1:0]                      macro_ready;
    logic [BLOCK_SIZE*NW_WIDTH-1:0]             macro_wid;
    logic [BLOCK_SIZE*NCTA_WIDTH-1:0]           macro_cta_id;
    logic [BLOCK_SIZE*`VX_CFG_NUM_THREADS-1:0]  macro_tmask;
    logic [BLOCK_SIZE*PC_BITS-1:0]              macro_PC;
    logic [BLOCK_SIZE*INST_OP_BITS-1:0]         macro_op_type;
    logic [BLOCK_SIZE*5-1:0]                    macro_fmt_s;
    logic [BLOCK_SIZE*5-1:0]                    macro_fmt_d;
    logic [BLOCK_SIZE-1:0]                      macro_a_from_smem;
    logic [BLOCK_SIZE*2-1:0]                    macro_cd_nregs;

    wire  [BLOCK_SIZE-1:0]                      uop_valid;
    logic [BLOCK_SIZE-1:0]                      uop_ready;
    wire  [BLOCK_SIZE-1:0]                      uop_fire;
    wire  [BLOCK_SIZE*NW_WIDTH-1:0]             rf_rd_wid;
    wire  [BLOCK_SIZE*NUM_REGS_BITS-1:0]        rf_rs1_addr;
    wire  [BLOCK_SIZE*NUM_REGS_BITS-1:0]        rf_rs2_addr;
    wire  [BLOCK_SIZE*NUM_REGS_BITS-1:0]        rf_rs3_addr;
    wire  [BLOCK_SIZE*3-1:0]                    rf_used_rs;
    wire  [BLOCK_SIZE-1:0]                      uop_wb;
    wire  [BLOCK_SIZE*NUM_REGS_BITS-1:0]        uop_rd_addr;
    wire  [BLOCK_SIZE-1:0]                      uop_fu_lock;
    wire  [BLOCK_SIZE-1:0]                      uop_fu_unlock;
    logic [BLOCK_SIZE*BLOCK_DATA_BITS-1:0]      rf_rs1_data;
    logic [BLOCK_SIZE*BLOCK_DATA_BITS-1:0]      rf_rs2_data;
    logic [BLOCK_SIZE*BLOCK_DATA_BITS-1:0]      rf_rs3_data;

    logic                                       meta_wr_en;
    logic [NW_WIDTH-1:0]                        meta_wr_wid;
    logic [4:0]                                 meta_wr_idx;
    logic [BLOCK_DATA_BITS-1:0]                 meta_wr_data;

    wire                                        lmem_req_valid;
    logic                                       lmem_req_ready;
    wire                                        lmem_req_rw;
    wire  [BANK_ADDR_WIDTH-1:0]                 lmem_req_addr;
    wire  [TCU_LMEM_TAG_W-1:0]                  lmem_req_tag;
    logic                                       lmem_rsp_valid;
    wire                                        lmem_rsp_ready;
    logic [LMEM_DATA_BITS-1:0]                  lmem_rsp_data;
    logic [TCU_LMEM_TAG_W-1:0]                  lmem_rsp_tag;

    wire  [BLOCK_SIZE-1:0]                      res_valid;
    logic [BLOCK_SIZE-1:0]                      res_ready;
    wire  [BLOCK_SIZE*NW_WIDTH-1:0]             res_wid;
    wire  [BLOCK_SIZE*NCTA_WIDTH-1:0]           res_cta_id;
    wire  [BLOCK_SIZE*`VX_CFG_NUM_THREADS-1:0]  res_tmask;
    wire  [BLOCK_SIZE*PC_BITS-1:0]              res_PC;
    wire  [BLOCK_SIZE-1:0]                      res_wb;
    wire  [BLOCK_SIZE*NUM_REGS_BITS-1:0]        res_rd;
    wire  [BLOCK_SIZE*BLOCK_DATA_BITS-1:0]      res_data;

    VX_tcu_subsys #(
        .BLOCK_SIZE      (BLOCK_SIZE),
        .NUM_BANKS       (NUM_BANKS),
        .BANK_ADDR_WIDTH (BANK_ADDR_WIDTH)
    ) dut (.*);

    // Backing warp register file [wid][reg][lane] and LMEM [word_addr]
    logic [31:0] warp_rf [0:NUM_WARPS_TB-1][0:TOTAL_REGS-1][0:TCU_BLOCK_CAP-1];
    int          pend_wb [0:NUM_WARPS_TB-1][0:TOTAL_REGS-1];
    logic [31:0] lmem_words [0:LMEM_ROWS*NUM_BANKS-1];

    localparam int EXP_ENTRY_W = NW_WIDTH + 1 + NUM_REGS_BITS;
    logic [EXP_ENTRY_W-1:0] exp_ring [0:BLOCK_SIZE-1][0:1023];
    int exp_head [0:BLOCK_SIZE-1];
    int exp_tail [0:BLOCK_SIZE-1];
    int err_cnt = 0;
    int total_retires = 0;
    int stall_mode = 0;
    int unsigned rng_state = 32'h12345678;

    function automatic int unsigned next_rng();
        rng_state ^= (rng_state << 13);
        rng_state ^= (rng_state >> 17);
        rng_state ^= (rng_state << 5);
        return rng_state;
    endfunction

    // Static LMEM latency ring buffer (avoids Verilator unpacked-struct-queue bugs)
    int                         lmem_rem  [0:511];
    logic [LMEM_DATA_BITS-1:0]  lmem_d_q  [0:511];
    logic [TCU_LMEM_TAG_W-1:0]  lmem_t_q  [0:511];
    int                         lmem_head = 0;
    int                         lmem_tail = 0;

    // Scoreboard & combinational RF read ports
    always_comb begin
        for (int b = 0; b < BLOCK_SIZE; ++b) begin
            automatic logic [NW_WIDTH-1:0]      w   = rf_rd_wid[b*NW_WIDTH +: NW_WIDTH];
            automatic logic [NUM_REGS_BITS-1:0] rs1 = rf_rs1_addr[b*NUM_REGS_BITS +: NUM_REGS_BITS];
            automatic logic [NUM_REGS_BITS-1:0] rs2 = rf_rs2_addr[b*NUM_REGS_BITS +: NUM_REGS_BITS];
            automatic logic [NUM_REGS_BITS-1:0] rs3 = rf_rs3_addr[b*NUM_REGS_BITS +: NUM_REGS_BITS];
            automatic logic [NUM_REGS_BITS-1:0] rd  = uop_rd_addr[b*NUM_REGS_BITS +: NUM_REGS_BITS];
            automatic logic [2:0]               urs = rf_used_rs[b*3 +: 3];
            automatic logic hazard = (urs[0] && pend_wb[w][rs1] > 0)
                                  || (urs[1] && pend_wb[w][rs2] > 0)
                                  || (urs[2] && pend_wb[w][rs3] > 0)
                                  || (uop_wb[b] && pend_wb[w][rd] > 0);
            uop_ready[b] = !hazard;
            for (int t = 0; t < TCU_BLOCK_CAP; ++t) begin
                rf_rs1_data[b*BLOCK_DATA_BITS + t*32 +: 32] = warp_rf[w][rs1][t];
                rf_rs2_data[b*BLOCK_DATA_BITS + t*32 +: 32] = warp_rf[w][rs2][t];
                rf_rs3_data[b*BLOCK_DATA_BITS + t*32 +: 32] = warp_rf[w][rs3][t];
            end
        end
    end

    // Sequential scoreboard tracking, LMEM model, and retirement checker
    always_ff @(posedge clk) begin
        if (reset) begin
            lmem_req_ready <= 1'b1;
            lmem_rsp_valid <= 1'b0;
            lmem_rsp_data  <= '0;
            lmem_rsp_tag   <= '0;
            res_ready      <= '1;
            lmem_head      <= 0;
            lmem_tail      <= 0;
            for (int b = 0; b < BLOCK_SIZE; ++b) begin
                exp_head[b] <= 0;
                exp_tail[b] <= 0;
            end
            for (int w = 0; w < NUM_WARPS_TB; ++w)
                for (int r = 0; r < TOTAL_REGS; ++r)
                    pend_wb[w][r] <= 0;
        end else begin
            // Randomize ready signals when stall_mode is active
            if (stall_mode == 0) begin
                lmem_req_ready <= 1'b1;
                res_ready      <= '1;
            end else if (stall_mode == 2) begin
                // Hold res_ready low to force landing_queue parking
                lmem_req_ready <= 1'b1;
                res_ready      <= '0;
            end else begin
                automatic int unsigned r = next_rng();
                lmem_req_ready <= (r[1:0] != 2'b00);
                for (int b = 0; b < BLOCK_SIZE; ++b)
                    res_ready[b] <= (r[2 + b*2 +: 2] != 2'b00);
            end

            // LMEM response delivery (at most 1 rsp per cycle; DUT keeps rsp_ready=1)
            lmem_rsp_valid <= 1'b0;
            if (lmem_head < lmem_tail) begin
                if (lmem_rem[lmem_head & 511] <= 0) begin
                    lmem_rsp_valid <= 1'b1;
                    lmem_rsp_data  <= lmem_d_q[lmem_head & 511];
                    lmem_rsp_tag   <= lmem_t_q[lmem_head & 511];
                    lmem_head      <= lmem_head + 1;
                end else begin
                    lmem_rem[lmem_head & 511] <= lmem_rem[lmem_head & 511] - 1;
                end
            end

            if (lmem_req_valid && lmem_req_ready) begin
                automatic logic [LMEM_DATA_BITS-1:0] rdata;
                if (lmem_req_rw !== 1'b0) begin
                    $display("TEST_FAIL: unexpected LMEM write rw=%b", lmem_req_rw);
                    err_cnt <= err_cnt + 1;
                end
                for (int bk = 0; bk < NUM_BANKS; ++bk)
                    rdata[bk*32 +: 32] = lmem_words[int'(lmem_req_addr)*NUM_BANKS + bk];
                lmem_rem[lmem_tail & 511] <= (stall_mode == 1) ? int'(next_rng() % 3) : 0;
                lmem_d_q[lmem_tail & 511] <= rdata;
                lmem_t_q[lmem_tail & 511] <= lmem_req_tag;
                lmem_tail                 <= lmem_tail + 1;
            end

            // Track uop_fire & res_fire net pending_wb delta + strict FIFO retirement
            for (int b = 0; b < BLOCK_SIZE; ++b) begin
                automatic logic ufire = uop_fire[b];
                automatic logic rfire = res_valid[b] && res_ready[b];
                automatic logic [NW_WIDTH-1:0]      uw  = rf_rd_wid[b*NW_WIDTH +: NW_WIDTH];
                automatic logic [NUM_REGS_BITS-1:0] urd = uop_rd_addr[b*NUM_REGS_BITS +: NUM_REGS_BITS];
                automatic logic [NW_WIDTH-1:0]      rw  = res_wid[b*NW_WIDTH +: NW_WIDTH];
                automatic logic [NUM_REGS_BITS-1:0] rrd = res_rd[b*NUM_REGS_BITS +: NUM_REGS_BITS];

                if (ufire) begin
                    exp_ring[b][exp_tail[b] & 1023] <= {uw, uop_wb[b], urd};
                    exp_tail[b] <= exp_tail[b] + 1;
                end

                if (rfire) begin
                    total_retires <= total_retires + 1;
                    if (exp_head[b] >= exp_tail[b]) begin
                        $display("TEST_FAIL: unexpected retirement on block %0d", b);
                        err_cnt <= err_cnt + 1;
                    end else begin
                        automatic logic [EXP_ENTRY_W-1:0] exp_e = exp_ring[b][exp_head[b] & 1023];
                        automatic logic [NW_WIDTH-1:0]      ew  = exp_e[NUM_REGS_BITS+1 +: NW_WIDTH];
                        automatic logic                     ewb = exp_e[NUM_REGS_BITS];
                        automatic logic [NUM_REGS_BITS-1:0] erd = exp_e[NUM_REGS_BITS-1:0];
                        exp_head[b] <= exp_head[b] + 1;
                        if (rw !== ew || res_wb[b] !== ewb || (ewb && (rrd !== erd))) begin
                            $display("TEST_FAIL: out-of-order retirement on blk=%0d got(wid=%0d wb=%0b rd=%0d) exp(wid=%0d wb=%0b rd=%0d)",
                                     b, rw, res_wb[b], rrd, ew, ewb, erd);
                            err_cnt <= err_cnt + 1;
                        end
                    end
                    if (res_wb[b]) begin
                        for (int t = 0; t < TCU_BLOCK_CAP; ++t)
                            warp_rf[rw][rrd][t] <= res_data[b*BLOCK_DATA_BITS + t*32 +: 32];
                    end
                end

                if (ufire && uop_wb[b] && rfire && res_wb[b] && (uw == rw) && (urd == rrd)) begin
                    // Net delta = 0
                end else begin
                    if (ufire && uop_wb[b])
                        pend_wb[uw][urd] <= pend_wb[uw][urd] + 1;
                    if (rfire && res_wb[b])
                        pend_wb[rw][rrd] <= pend_wb[rw][rrd] - 1;
                end
            end
        end
    end

    // Pure-integer exact dyadic IEEE-754 helpers (Q2 inputs -> Q4 exact FP32 accumulators)
    function automatic logic [31:0] int_to_fp32_scaled(input int signed val, input int shift_exp);
        logic        s;
        int unsigned mag;
        int          msb;
        logic [22:0] frac;
        logic [7:0]  exp8;
        if (val == 0) return 32'h0000_0000;
        s   = (val < 0);
        mag = s ? 32'(-val) : 32'(val);
        msb = 0;
        for (int b = 0; b < 31; ++b)
            if (mag[b]) msb = b;
        frac = (msb <= 23) ? 23'((mag << (23 - msb)) & 32'h007F_FFFF)
                           : 23'((mag >> (msb - 23)) & 32'h007F_FFFF);
        exp8 = 8'(127 + msb + shift_exp);
        return {s, exp8, frac};
    endfunction

    function automatic int signed fp32_to_q4(input logic [31:0] f);
        int          sh;
        int unsigned m24, mag_q4;
        if (f[30:23] == 8'd0) return 0;
        sh     = int'(f[30:23]) - 127 - 23 + 4;
        m24    = {8'd0, 1'b1, f[22:0]};
        mag_q4 = (sh >= 0) ? (m24 << sh) : (m24 >> (-sh));
        return f[31] ? -int'(mag_q4) : int'(mag_q4);
    endfunction

    function automatic int signed fp16_to_q2(input logic [15:0] h);
        int          sh;
        int unsigned m11, mag_q2;
        if (h[14:10] == 5'd0) return 0;
        sh     = int'(h[14:10]) - 15 - 10 + 2;
        m11    = {21'd0, 1'b1, h[9:0]};
        mag_q2 = (sh >= 0) ? (m11 << sh) : (m11 >> (-sh));
        return h[15] ? -int'(mag_q2) : int'(mag_q2);
    endfunction

    function automatic int signed bf16_to_q2(input logic [15:0] bh);
        int          sh;
        int unsigned m8, mag_q2;
        if (bh[14:7] == 8'd0) return 0;
        sh     = int'(bh[14:7]) - 127 - 7 + 2;
        m8     = {24'd0, 1'b1, bh[6:0]};
        mag_q2 = (sh >= 0) ? (m8 << sh) : (m8 >> (-sh));
        return bh[15] ? -int'(mag_q2) : int'(mag_q2);
    endfunction

    function automatic logic [15:0] small_fp16(input int val_q2);
        logic [31:0] b;
        if (val_q2 == 0) return 16'h0000;
        b = int_to_fp32_scaled(val_q2, -2);
        return {b[31], 5'(int'(b[30:23]) - 112), b[22:13]};
    endfunction

    function automatic logic [15:0] small_bf16(input int val_q2);
        logic [31:0] b;
        if (val_q2 == 0) return 16'h0000;
        b = int_to_fp32_scaled(val_q2, -2);
        return b[31:16];
    endfunction

    function automatic logic [31:0] fedp_word_accum(
        input logic [4:0]  fmt_s,
        input logic [4:0]  fmt_d,
        input logic [31:0] a_w,
        input logic [31:0] b_w,
        input logic [31:0] acc_in
    );
        if (fmt_d == TCU_I32_ID) begin
            int signed sum;
            sum = signed'(acc_in);
            case (fmt_s)
                TCU_I8_ID:  for (int e = 0; e < 4; ++e) sum += int'(signed'(a_w[e*8 +: 8])) * int'(signed'(b_w[e*8 +: 8]));
                TCU_U8_ID:  for (int e = 0; e < 4; ++e) sum += int'(unsigned'(a_w[e*8 +: 8])) * int'(unsigned'(b_w[e*8 +: 8]));
                TCU_I4_ID:  for (int e = 0; e < 8; ++e) sum += int'(signed'(a_w[e*4 +: 4])) * int'(signed'(b_w[e*4 +: 4]));
                TCU_U4_ID:  for (int e = 0; e < 8; ++e) sum += int'(unsigned'(a_w[e*4 +: 4])) * int'(unsigned'(b_w[e*4 +: 4]));
                default: ;
            endcase
            return 32'(sum);
        end else begin
            int signed q4;
            q4 = fp32_to_q4(acc_in);
            case (fmt_s)
                TCU_FP16_ID: for (int e = 0; e < 2; ++e) q4 += fp16_to_q2(a_w[e*16 +: 16]) * fp16_to_q2(b_w[e*16 +: 16]);
                TCU_BF16_ID: for (int e = 0; e < 2; ++e) q4 += bf16_to_q2(a_w[e*16 +: 16]) * bf16_to_q2(b_w[e*16 +: 16]);
                default: ;
            endcase
            return int_to_fp32_scaled(q4, -4);
        end
    endfunction

    function automatic logic [31:0] sp_gather_word(
        input logic [4:0]  fmt_s,
        input logic [31:0] b1,
        input logic [31:0] b2,
        input logic [TCU_MAX_META_BLOCK_WIDTH-1:0] vld_blk,
        input int          row_i,
        input int          k_idx
    );
        if (fmt_s == TCU_FP16_ID || fmt_s == TCU_BF16_ID) begin
            localparam int MRW = TCU_TC_K * 4;
            logic [MRW-1:0] mrow;
            logic [1:0] m_lo, m_hi;
            logic [3:0] gm;
            logic [15:0] e10, e11, e20, e21, s0, s1;
            mrow = vld_blk[MRW * row_i +: MRW];
            m_lo = mrow[2 * k_idx +: 2];
            m_hi = mrow[2 * (TCU_TC_K + k_idx) +: 2];
            gm   = {m_hi, m_lo};
            e10 = b1[15:0]; e11 = b1[31:16]; e20 = b2[15:0]; e21 = b2[31:16];
            s0 = gm[0] ? e10 : gm[1] ? e11 : gm[2] ? e20 : e21;
            s1 = gm[3] ? e21 : gm[2] ? e20 : gm[1] ? e11 : e10;
            return {s1, s0};
        end else begin
            // I_RATIO=4 (INT8/UINT8): b1 holds 4-elem 2:4 group (grp_mask_lo), b2 holds 4-elem 2:4 group (grp_mask_hi)
            localparam int MRW = TCU_TC_K * 8;
            logic [MRW-1:0] mrow;
            logic [3:0] m_lo, m_hi;
            logic [7:0] b1_e [0:3], b2_e [0:3];
            logic [7:0] lo_0, lo_1, hi_0, hi_1;
            mrow = vld_blk[MRW * row_i +: MRW];
            m_lo = mrow[4 * k_idx +: 4];
            m_hi = mrow[4 * (TCU_TC_K + k_idx) +: 4];
            for (int q = 0; q < 4; ++q) begin
                b1_e[q] = b1[q*8 +: 8];
                b2_e[q] = b2[q*8 +: 8];
            end
            lo_0 = m_lo[0] ? b1_e[0] : m_lo[1] ? b1_e[1] : b1_e[2];
            lo_1 = m_lo[3] ? b1_e[3] : m_lo[2] ? b1_e[2] : b1_e[1];
            hi_0 = m_hi[0] ? b2_e[0] : m_hi[1] ? b2_e[1] : b2_e[2];
            hi_1 = m_hi[3] ? b2_e[3] : m_hi[2] ? b2_e[2] : b2_e[1];
            return {hi_1, hi_0, lo_1, lo_0};
        end
    endfunction

    // Preload uniform 2:4 metadata pattern across all banks/cols of warp `w`
    logic [TCU_MAX_META_BLOCK_WIDTH-1:0] tb_meta_blk [0:NUM_WARPS_TB-1];
    task automatic write_uniform_meta(input int w, input logic [31:0] word_pat);
        localparam int NUM_COLS = TCU_MAX_META_BLOCK_WIDTH / 32;
        localparam int GROUPS   = (NUM_COLS + TCU_META_COLS_PER_LOAD - 1) / TCU_META_COLS_PER_LOAD;
        for (int c = 0; c < NUM_COLS; ++c)
            tb_meta_blk[w][c*32 +: 32] = word_pat;
        for (int g = 0; g < GROUPS * TCU_STORES_PER_COL; ++g) begin
            @(negedge clk);
            meta_wr_en   = 1'b1;
            meta_wr_wid  = NW_WIDTH'(w);
            meta_wr_idx  = 5'(g);
            for (int t = 0; t < TCU_BLOCK_CAP; ++t)
                meta_wr_data[t*32 +: 32] = word_pat;
            @(posedge clk);
        end
        @(negedge clk);
        meta_wr_en = 1'b0;
    endtask

    task automatic wait_all_drained(input int max_cyc = 4000);
        int cyc = 0;
        while (cyc < max_cyc) begin
            automatic bit busy = (lmem_head < lmem_tail) || lmem_rsp_valid;
            for (int b = 0; b < BLOCK_SIZE; ++b)
                if (exp_head[b] != exp_tail[b] || uop_valid[b] || res_valid[b]) busy = 1'b1;
            for (int w = 0; w < NUM_WARPS_TB; ++w)
                for (int r = 0; r < TOTAL_REGS; ++r)
                    if (pend_wb[w][r] != 0) busy = 1'b1;
            if (!busy) return;
            @(posedge clk);
            cyc++;
        end
        $display("TEST_FAIL: timeout waiting for pipeline drain");
        err_cnt++;
    endtask

    task automatic issue_macro_on_block(
        input int                  b,
        input logic [NW_WIDTH-1:0] wid,
        input logic [NCTA_WIDTH-1:0] cta,
        input logic [INST_OP_BITS-1:0] op,
        input logic [4:0]          fs,
        input logic [4:0]          fd,
        input logic                a_smem,
        input logic [1:0]          cd_nr
    );
        int guard = 0;
        @(negedge clk);
        macro_valid[b]                             = 1'b1;
        macro_wid[b*NW_WIDTH +: NW_WIDTH]          = wid;
        macro_cta_id[b*NCTA_WIDTH +: NCTA_WIDTH]   = cta;
        macro_tmask[b*`VX_CFG_NUM_THREADS +: `VX_CFG_NUM_THREADS] = '1;
        macro_PC[b*PC_BITS +: PC_BITS]             = PC_BITS'(32'h1000 + total_retires*4);
        macro_op_type[b*INST_OP_BITS +: INST_OP_BITS] = op;
        macro_fmt_s[b*5 +: 5]                      = fs;
        macro_fmt_d[b*5 +: 5]                      = fd;
        macro_a_from_smem[b]                       = a_smem;
        macro_cd_nregs[b*2 +: 2]                   = cd_nr;
        while (1) begin
            @(posedge clk);
            if (macro_valid[b] && macro_ready[b]) break;
            guard++;
            if (guard > 6000) begin
                $display("TEST_FAIL: timeout waiting for macro_ready[%0d]", b);
                err_cnt++;
                break;
            end
        end
        @(negedge clk);
        macro_valid[b] = 1'b0;
    endtask
    logic [31:0] exp_rf [0:NUM_WARPS_TB-1][0:TOTAL_REGS-1][0:TCU_BLOCK_CAP-1];

    task automatic golden_wmma(
        input int         w,
        input bit         is_sp,
        input logic [4:0] fs,
        input logic [4:0] fd
    );
        localparam int LG_N    = $clog2(TCU_N_STEPS);
        localparam int LG_M    = $clog2(TCU_M_STEPS);
        localparam int LG_K    = $clog2(TCU_K_STEPS);
        localparam int LG_A_SB = $clog2(TCU_A_SUB_BLOCKS);
        localparam int LG_B_SB = $clog2(TCU_B_SUB_BLOCKS);
        int ucnt = is_sp ? (TCU_UOPS / 2) : TCU_UOPS;
        for (int u = 0; u < ucnt; ++u) begin
            int n_idx = (LG_N > 0) ? ((u >> 0) & ((1 << LG_N) - 1)) : 0;
            int m_idx = (LG_M > 0) ? ((u >> LG_N) & ((1 << LG_M) - 1)) : 0;
            int k_idx = (LG_K > 0) ? ((u >> (LG_N + LG_M)) & ((1 << LG_K) - 1)) : 0;
            int ra_o, rb_o, rc_o, rs1_o, rs2_o, rs3_o;
            int m_hi = (LG_M > 1) ? ((m_idx >> (LG_M - 1)) & 1) : (m_idx & 1);
            int n_hi = (LG_N > 1) ? ((n_idx >> (LG_N - 1)) & 1) : (n_idx & 1);
            int k_hi = (LG_K > 1) ? ((k_idx >> (LG_K - 1)) & 1) : (k_idx & 1);
            if (LG_B_SB == 0) begin
                ra_o = ((m_idx & 1) << 2) | ((1 ^ m_hi) << 1) | (k_idx & 1);
                rb_o = (((n_idx & 1) ^ (k_idx & 1)) << 1) | (1 ^ (k_idx & 1));
                rc_o = ((m_idx & 1) << 2) | ((1 ^ m_hi) << 1) | (1 ^ (m_hi ^ (n_idx & 1)));
            end else begin
                ra_o = ((k_idx & 1) << 2) | ((1 ^ (m_idx & 1)) << 1) | ((m_idx & 1) ^ k_hi);
                rb_o = ((k_idx & 1) << 2) | ((k_hi ^ n_hi) << 1) | (1 ^ n_hi);
                rc_o = ((n_idx & 1) << 2) | ((1 ^ (m_idx & 1)) << 1) | n_hi;
            end
            if (is_sp) begin
                rs1_o = ((m_idx >> LG_A_SB) << (LG_K / 2)) | k_idx;
                rs2_o = (n_hi << 2) | ((1 ^ ((n_idx & 1) ^ (k_idx & 1))) << 1) | (1 ^ (k_idx & 1));
                rs3_o = (n_hi << 2) | ((m_idx & 1) << 1) | (1 ^ ((m_idx & 1) ^ (n_idx & 1)));
            end else begin
                rs1_o = ra_o; rs2_o = rb_o; rs3_o = rc_o;
            end
            begin
                int r1 = int'(make_reg_num(REG_TYPE_F, 5'(TCU_RA + rs1_o)));
                int r2 = int'(make_reg_num(REG_TYPE_F, 5'(TCU_RB + rs2_o)));
                int r3 = int'(make_reg_num(REG_TYPE_F, 5'(TCU_RC + rs3_o)));
                int a_off = (m_idx & (TCU_A_SUB_BLOCKS - 1)) * TCU_A_BLOCK_SIZE;
                int b_off = is_sp ? ((n_idx & (TCU_B_SUB_BLOCKS_SP - 1)) * TCU_B_BLOCK_SIZE_SP)
                                  : ((n_idx & (TCU_B_SUB_BLOCKS - 1)) * TCU_B_BLOCK_SIZE);
                for (int i = 0; i < TCU_TC_M; ++i) begin
                    for (int j = 0; j < TCU_TC_N; ++j) begin
                        logic [31:0] acc = exp_rf[w][r3][i*TCU_TC_N + j];
                        for (int k = 0; k < TCU_TC_K; ++k) begin
                            logic [31:0] aw = exp_rf[w][r1][a_off + i*TCU_TC_K + k];
                            logic [31:0] bw = is_sp
                                ? sp_gather_word(fs,
                                    exp_rf[w][r2][b_off + j*TCU_TC_K*2 + k*2],
                                    exp_rf[w][r2][b_off + j*TCU_TC_K*2 + k*2 + 1],
                                    tb_meta_blk[w], i, k)
                                : exp_rf[w][r2][b_off + j*TCU_TC_K + k];
                            acc = fedp_word_accum(fs, fd, aw, bw, acc);
                        end
                        exp_rf[w][r3][i*TCU_TC_N + j] = acc;
                    end
                end
            end
        end
    endtask

    task automatic golden_wgmma(
        input int         w,
        input bit         is_sp,
        input logic [4:0] fs,
        input logic [4:0] fd,
        input bit         a_smem,
        input logic [1:0] cd_nr
    );
        localparam int A_BLK_ROWS    = (TCU_TC_M * TCU_WG_FEDP_K + NUM_BANKS - 1) / NUM_BANKS;
        localparam int A_BLK_ROWS_SP = (TCU_TC_M * TCU_TC_K + NUM_BANKS - 1) / NUM_BANKS;
        localparam int A_PAD         = A_BLK_ROWS * NUM_BANKS;
        localparam int A_PAD_SP      = A_BLK_ROWS_SP * NUM_BANKS;
        localparam int A_STRIPE_W    = TCU_WG_M_STEPS * A_PAD;
        int n_steps   = (cd_nr == 2'd0) ? 4 : (cd_nr == 2'd1) ? 8 : 16;
        int k_steps   = is_sp ? ((TCU_WG_K_STEPS > 1) ? (TCU_WG_K_STEPS / 2) : 1) : TCU_WG_K_STEPS;
        int fk_eff    = is_sp ? TCU_TC_K : TCU_WG_FEDP_K;
        int rx10      = int'(make_reg_num(REG_TYPE_I, 5'd10));
        int rx11      = int'(make_reg_num(REG_TYPE_I, 5'd11));
        logic [31:0] da = exp_rf[w][rx10][0];
        logic [31:0] db = exp_rf[w][rx11][0];
        int a_wbase   = int'(da[15:0] >> 2);
        int a_ldm     = int'(da[31:16] >> 2);
        int b_wbase   = int'(db[15:0] >> 2);
        int b_ldm     = int'(db[31:16] >> 2);

        for (int sk = 0; sk < k_steps; ++sk) begin
            for (int sn = 0; sn < n_steps; ++sn) begin
                for (int sm = 0; sm < TCU_WG_M_STEPS; ++sm) begin
                    int rd_f   = int'(make_reg_num(REG_TYPE_F, 5'(TCU_WG_RC + ((sn << $clog2(TCU_WG_M_STEPS)) | sm))));
                    int rs1_o  = is_sp ? sm : ((sm << 1) | sk);
                    int r_a0   = int'(make_reg_num(REG_TYPE_F, 5'(TCU_WG_RA + rs1_o)));
                    int r_a1   = int'(make_reg_num(REG_TYPE_F, 5'(TCU_WG_RA + rs1_o + 1)));
                    int blk_id = sk * n_steps + sn;
                    for (int i = 0; i < TCU_TC_M; ++i) begin
                        for (int j = 0; j < TCU_TC_N; ++j) begin
                            logic [31:0] acc = exp_rf[w][rd_f][i*TCU_TC_N + j];
                            for (int k = 0; k < fk_eff; ++k) begin
                                logic [31:0] aw, bw, b1, b2;
                                if (a_smem) begin
                                    if (a_ldm != 0)
                                        aw = lmem_words[a_wbase + (sm * TCU_TC_M + i) * a_ldm + sk * fk_eff + k];
                                    else if (is_sp)
                                        aw = lmem_words[(a_wbase & ~(NUM_BANKS - 1)) + sk * A_STRIPE_W + sm * A_PAD_SP + i * TCU_TC_K + k];
                                    else
                                        aw = lmem_words[(a_wbase & ~(NUM_BANKS - 1)) + sk * A_STRIPE_W + sm * A_PAD + i * TCU_WG_FEDP_K + k];
                                end else begin
                                    if (k < TCU_TC_K)
                                        aw = exp_rf[w][r_a0][i*TCU_TC_K + k];
                                    else
                                        aw = exp_rf[w][r_a1][i*TCU_TC_K + (k - TCU_TC_K)];
                                end
                                if (!is_sp) begin
                                    if (b_ldm != 0)
                                        bw = lmem_words[b_wbase + (sn * TCU_TC_N + j) * b_ldm + sk * TCU_WG_FEDP_K + k];
                                    else
                                        bw = lmem_words[(b_wbase & ~(NUM_BANKS - 1)) + blk_id * (TCU_WG_FEDP_K * TCU_TC_N) + j * TCU_WG_FEDP_K + k];
                                end else begin
                                    if (b_ldm != 0) begin
                                        b1 = lmem_words[b_wbase + (sn * TCU_TC_N + j) * b_ldm + sk * (2 * TCU_TC_K) + 2*k];
                                        b2 = lmem_words[b_wbase + (sn * TCU_TC_N + j) * b_ldm + sk * (2 * TCU_TC_K) + 2*k + 1];
                                    end else begin
                                        b1 = lmem_words[(b_wbase & ~(NUM_BANKS - 1)) + blk_id * TCU_WG_B_BLOCK_SIZE_SP + (2*k) * TCU_TC_N + j];
                                        b2 = lmem_words[(b_wbase & ~(NUM_BANKS - 1)) + blk_id * TCU_WG_B_BLOCK_SIZE_SP + (2*k + 1) * TCU_TC_N + j];
                                    end
                                    bw = sp_gather_word(fs, b1, b2, tb_meta_blk[w], i, k);
                                end
                                acc = fedp_word_accum(fs, fd, aw, bw, acc);
                            end
                            exp_rf[w][rd_f][i*TCU_TC_N + j] = acc;
                        end
                    end
                end
            end
        end
    endtask

    task automatic check_warp_fregs(input string tag, input int w, input int num_fregs);
        for (int fr = 0; fr < num_fregs; ++fr) begin
            int r = int'(make_reg_num(REG_TYPE_F, 5'(fr)));
            for (int t = 0; t < TCU_BLOCK_CAP; ++t) begin
                if (warp_rf[w][r][t] !== exp_rf[w][r][t]) begin
                    $display("TEST_FAIL [%s]: w=%0d f%0d lane=%0d got=0x%08x exp=0x%08x",
                             tag, w, fr, t, warp_rf[w][r][t], exp_rf[w][r][t]);
                    err_cnt++;
                    if (err_cnt > 12) return;
                end
            end
        end
    endtask
    function automatic logic [31:0] gen_fmt_word(input logic [4:0] fs);
        int unsigned r = next_rng();
        case (fs)
            TCU_FP16_ID: begin
                int v0 = int'(r[4:0]) - 15;
                int v1 = int'(r[12:8]) - 15;
                return {small_fp16(v1), small_fp16(v0)};
            end
            TCU_BF16_ID: begin
                int v0 = int'(r[4:0]) - 15;
                int v1 = int'(r[12:8]) - 15;
                return {small_bf16(v1), small_bf16(v0)};
            end
            TCU_I8_ID:  return {8'(int'(r[28:24])-15), 8'(int'(r[20:16])-15), 8'(int'(r[12:8])-15), 8'(int'(r[4:0])-15)};
            TCU_U8_ID:  return {3'b0, r[28:24], 3'b0, r[20:16], 3'b0, r[12:8], 3'b0, r[4:0]};
            TCU_I4_ID, TCU_U4_ID: return r;
            default:    return r;
        endcase
    endfunction

    task automatic fill_env(input logic [4:0] fs, input logic [4:0] fd, input int acc_limit = 10);
        for (int idx = 0; idx < LMEM_ROWS * NUM_BANKS; ++idx)
            lmem_words[idx] = gen_fmt_word(fs);
        for (int w = 0; w < NUM_WARPS_TB; ++w) begin
            for (int r = 0; r < TOTAL_REGS; ++r) begin
                for (int t = 0; t < TCU_BLOCK_CAP; ++t) begin
                    logic [31:0] v;
                    if (get_reg_type(NUM_REGS_BITS'(r)) == REG_TYPE_F) begin
                        if (int'(get_reg_idx(NUM_REGS_BITS'(r))) < acc_limit)
                            v = (fd == TCU_I32_ID) ? 32'(int'(next_rng() % 200) - 100)
                                                   : int_to_fp32_scaled(int'(next_rng() % 32) - 16, -1);
                        else
                            v = gen_fmt_word(fs);
                    end else begin
                        v = 32'd0;
                    end
                    warp_rf[w][r][t] = v;
                    exp_rf[w][r][t]  = v;
                end
            end
        end
    endtask

    task automatic set_wgmma_descs(input int w, input logic [15:0] stride_a_b, input logic [15:0] base_a_b,
                                   input logic [15:0] stride_b_b, input logic [15:0] base_b_b);
        int rx10 = int'(make_reg_num(REG_TYPE_I, 5'd10));
        int rx11 = int'(make_reg_num(REG_TYPE_I, 5'd11));
        for (int t = 0; t < TCU_BLOCK_CAP; ++t) begin
            warp_rf[w][rx10][t] = {stride_a_b, base_a_b};
            exp_rf [w][rx10][t] = {stride_a_b, base_a_b};
            warp_rf[w][rx11][t] = {stride_b_b, base_b_b};
            exp_rf [w][rx11][t] = {stride_b_b, base_b_b};
        end
    endtask

    int seed_arg = 101;
    initial begin
        void'($value$plusargs("seed=%d", seed_arg));
        rng_state = 32'(seed_arg * 7919 + 32'hA5A5_1357);

        reset             = 1'b1;
        macro_valid       = '0;
        macro_wid         = '0;
        macro_cta_id      = '0;
        macro_tmask       = '0;
        macro_PC          = '0;
        macro_op_type     = '0;
        macro_fmt_s       = '0;
        macro_fmt_d       = '0;
        macro_a_from_smem = '0;
        macro_cd_nregs    = '0;
        meta_wr_en        = 1'b0;
        meta_wr_wid       = '0;
        meta_wr_idx       = '0;
        meta_wr_data      = '0;
        stall_mode        = 0;

        fill_env(TCU_FP16_ID, TCU_FP32_ID);
        repeat (6) @(posedge clk);
        @(negedge clk);
        reset = 1'b0;
        repeat (2) @(posedge clk);

        // Preload valid 2:4 sparse metadata for all warps (each 4-elem group has 2 bits set: 0x9966_55AA -> 1001/0110/0101/1010)
        for (int w = 0; w < NUM_WARPS_TB; ++w)
            write_uniform_meta(w, (w[0] ? 32'h6699_AA55 : 32'h9966_55AA));

        // T1: Warp-level WMMA across FP16, BF16, INT8, INT4 with random backpressure
        stall_mode = 1;
        begin
            logic [4:0] fmts_s [0:3] = '{TCU_FP16_ID, TCU_BF16_ID, TCU_I8_ID, TCU_I4_ID};
            logic [4:0] fmts_d [0:3] = '{TCU_FP32_ID, TCU_FP32_ID, TCU_I32_ID, TCU_I32_ID};
            for (int f = 0; f < 4; ++f) begin
                fill_env(fmts_s[f], fmts_d[f]);
                golden_wmma(0, 1'b0, fmts_s[f], fmts_d[f]);
                issue_macro_on_block(0, NW_WIDTH'(0), NCTA_WIDTH'(0), INST_OP_BITS'(INST_TCU_WMMA), fmts_s[f], fmts_d[f], 1'b0, 2'd0);
                wait_all_drained();
                check_warp_fregs("T1_WMMA", 0, 8);
            end
        end

        // T2: Warp-level 2:4 Sparse WMMA_SP (FP16 + INT8)
        begin
            logic [4:0] fmts_s [0:1] = '{TCU_FP16_ID, TCU_I8_ID};
            logic [4:0] fmts_d [0:1] = '{TCU_FP32_ID, TCU_I32_ID};
            for (int f = 0; f < 2; ++f) begin
                fill_env(fmts_s[f], fmts_d[f]);
                golden_wmma(1 % NUM_WARPS_TB, 1'b1, fmts_s[f], fmts_d[f]);
                issue_macro_on_block(0, NW_WIDTH'(1 % NUM_WARPS_TB), NCTA_WIDTH'(0), INST_OP_BITS'(INST_TCU_WMMA_SP), fmts_s[f], fmts_d[f], 1'b0, 2'd0);
                wait_all_drained();
                check_warp_fregs("T2_WMMA_SP", 1 % NUM_WARPS_TB, 8);
            end
        end

        // T3: WGMMA Block-Major & SS Row-Major/K-Major across cd_nregs = 0, 1, 2
        for (int cd = 0; cd < 3; ++cd) begin
            int nrc = (cd == 0) ? 8 : (cd == 1) ? 16 : 32;
            fill_env(TCU_FP16_ID, TCU_FP32_ID, 32);
            set_wgmma_descs(0, 16'd0, 16'h0100, 16'd0, 16'h0600);
            golden_wgmma(0, 1'b0, TCU_FP16_ID, TCU_FP32_ID, 1'b1, 2'(cd));
            issue_macro_on_block(0, NW_WIDTH'(0), NCTA_WIDTH'(0), INST_OP_BITS'(INST_TCU_WGMMA), TCU_FP16_ID, TCU_FP32_ID, 1'b1, 2'(cd));
            wait_all_drained();
            check_warp_fregs("T3_WGMMA_BM", 0, nrc);

            fill_env(TCU_I8_ID, TCU_I32_ID, 32);
            set_wgmma_descs(0, 16'd32, 16'h0080, 16'd32, 16'h0800);
            golden_wgmma(0, 1'b0, TCU_I8_ID, TCU_I32_ID, 1'b1, 2'(cd));
            issue_macro_on_block(0, NW_WIDTH'(0), NCTA_WIDTH'(0), INST_OP_BITS'(INST_TCU_WGMMA), TCU_I8_ID, TCU_I32_ID, 1'b1, 2'(cd));
            wait_all_drained();
            check_warp_fregs("T3_WGMMA_SS_ALIGNED", 0, nrc);
        end

        // T4: Sub-Row Descriptor Offset & Bank-Row-Straddling Stride (ldm=6w / 10w, sub_off=2w / 6w)
        fill_env(TCU_I8_ID, TCU_I32_ID, 32);
        // base_a=0x0108 (sub_off=2w), stride_a=24B (6w); base_b=0x0818 (sub_off=6w -> straddles 8-word bank row!), stride_b=40B (10w)
        set_wgmma_descs(0, 16'd24, 16'h0108, 16'd40, 16'h0818);
        golden_wgmma(0, 1'b0, TCU_I8_ID, TCU_I32_ID, 1'b1, 2'd1);
        issue_macro_on_block(0, NW_WIDTH'(0), NCTA_WIDTH'(0), INST_OP_BITS'(INST_TCU_WGMMA), TCU_I8_ID, TCU_I32_ID, 1'b1, 2'd1);
        wait_all_drained();
        check_warp_fregs("T4_STRADDLE_DENSE", 0, 16);

        // T5: B-Tile Cache Coherency (K-major -> Block-major switch, in-place SMEM rewrite, CTA switch)
        fill_env(TCU_I8_ID, TCU_I32_ID);
        set_wgmma_descs(0, 16'd32, 16'h0100, 16'd40, 16'h0400);
        golden_wgmma(0, 1'b0, TCU_I8_ID, TCU_I32_ID, 1'b1, 2'd0);
        issue_macro_on_block(0, NW_WIDTH'(0), NCTA_WIDTH'(0), INST_OP_BITS'(INST_TCU_WGMMA), TCU_I8_ID, TCU_I32_ID, 1'b1, 2'd0);
        wait_all_drained();
        // Switch immediately to Block-Major at base_b=0x0460 (row 0x23, aliasing final step_n=3 addr of 0x0400)!
        set_wgmma_descs(0, 16'd0, 16'h0100, 16'd0, 16'h0460);
        golden_wgmma(0, 1'b0, TCU_I8_ID, TCU_I32_ID, 1'b1, 2'd0);
        issue_macro_on_block(0, NW_WIDTH'(0), NCTA_WIDTH'(0), INST_OP_BITS'(INST_TCU_WGMMA), TCU_I8_ID, TCU_I32_ID, 1'b1, 2'd0);
        wait_all_drained();
        check_warp_fregs("T5_KM_TO_BM", 0, 8);
        // Rewrite SMEM in place and issue at base_b=0x04c0 (row 0x26, aliasing final step_n=3 addr of 0x0460)!
        for (int idx = 0; idx < LMEM_ROWS * NUM_BANKS; ++idx)
            lmem_words[idx] = gen_fmt_word(TCU_I8_ID);
        set_wgmma_descs(0, 16'd0, 16'h0100, 16'd0, 16'h04c0);
        golden_wgmma(0, 1'b0, TCU_I8_ID, TCU_I32_ID, 1'b1, 2'd0);
        issue_macro_on_block(0, NW_WIDTH'(0), NCTA_WIDTH'(0), INST_OP_BITS'(INST_TCU_WGMMA), TCU_I8_ID, TCU_I32_ID, 1'b1, 2'd0);
        wait_all_drained();
        check_warp_fregs("T5_INPLACE_SMEM_RELOAD", 0, 8);

        // T6: Back-to-back Compute (warp 0) -> Dense RS WGMMA Setup-Uop (warp 1) under commit stall (landing_queue FIFO ordering!)
        fill_env(TCU_FP16_ID, TCU_FP32_ID);
        set_wgmma_descs(1 % NUM_WARPS_TB, 16'd0, 16'h0100, 16'd40, 16'h0618);
        golden_wmma(0, 1'b0, TCU_FP16_ID, TCU_FP32_ID);
        golden_wgmma(1 % NUM_WARPS_TB, 1'b0, TCU_FP16_ID, TCU_FP32_ID, 1'b0, 2'd0);
        stall_mode = 2; // stall res_ready for 14 cycles so warp 0 compute results park in landing_queue!
        fork
            begin
                repeat (14) @(posedge clk);
                stall_mode = 1;
            end
            begin
                issue_macro_on_block(0, NW_WIDTH'(0), NCTA_WIDTH'(0), INST_OP_BITS'(INST_TCU_WMMA), TCU_FP16_ID, TCU_FP32_ID, 1'b0, 2'd0);
                issue_macro_on_block(0, NW_WIDTH'(1 % NUM_WARPS_TB), NCTA_WIDTH'(1 % (1 << NCTA_WIDTH)), INST_OP_BITS'(INST_TCU_WGMMA), TCU_FP16_ID, TCU_FP32_ID, 1'b0, 2'd0);
            end
        join
        wait_all_drained();
        check_warp_fregs("T6_FIFO_W0", 0, 8);
        check_warp_fregs("T6_FIFO_W1", 1 % NUM_WARPS_TB, 8);

        // T7: 2:4 Sparse WGMMA_SP (both SS straddling K-major and RS block-major + multi-block lockstep when BLOCK_SIZE==2)
        fill_env(TCU_I8_ID, TCU_I32_ID);
        set_wgmma_descs(0, 16'd24, 16'h0108, 16'd40, 16'h0818);
        golden_wgmma(0, 1'b1, TCU_I8_ID, TCU_I32_ID, 1'b1, 2'd1);
        issue_macro_on_block(0, NW_WIDTH'(0), NCTA_WIDTH'(0), INST_OP_BITS'(INST_TCU_WGMMA_SP), TCU_I8_ID, TCU_I32_ID, 1'b1, 2'd1);
        wait_all_drained();
        check_warp_fregs("T7_WGMMA_SP_STRADDLE", 0, 16);

        if (BLOCK_SIZE > 1) begin
            // Concurrent dual-block different-CTA lockstep serialization test
            fill_env(TCU_I8_ID, TCU_I32_ID);
            set_wgmma_descs(0, 16'd24, 16'h0108, 16'd40, 16'h0508);
            set_wgmma_descs(1, 16'd0,  16'h0300, 16'd0,  16'h0900);
            golden_wgmma(0, 1'b0, TCU_I8_ID, TCU_I32_ID, 1'b1, 2'd0);
            golden_wgmma(1, 1'b1, TCU_I8_ID, TCU_I32_ID, 1'b0, 2'd0);
            fork
                issue_macro_on_block(0, NW_WIDTH'(0), NCTA_WIDTH'(0), INST_OP_BITS'(INST_TCU_WGMMA),    TCU_I8_ID, TCU_I32_ID, 1'b1, 2'd0);
                issue_macro_on_block(1, NW_WIDTH'(1), NCTA_WIDTH'(1), INST_OP_BITS'(INST_TCU_WGMMA_SP), TCU_I8_ID, TCU_I32_ID, 1'b0, 2'd0);
            join
            wait_all_drained();
            check_warp_fregs("T7_DUAL_BLK0", 0, 8);
            check_warp_fregs("T7_DUAL_BLK1", 1, 8);
        end

        if (err_cnt == 0 && total_retires > 40) begin
            $display("TEST_PASS seed=%0d retires=%0d", seed_arg, total_retires);
            $finish;
        end else begin
            $display("TEST_FAIL seed=%0d errs=%0d retires=%0d", seed_arg, err_cnt, total_retires);
            $fatal(1);
        end
    end
endmodule
