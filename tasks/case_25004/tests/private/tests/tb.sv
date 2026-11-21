// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps

module tb;
    import ecc_params_pkg::*;
    import ecc_reg_pkg::*;
    import kv_defines_pkg::*;
    import sim_ctrl_pkg::*;

    logic clk = 1'b0;
    always #5 clk = ~clk;

    // -----------------------------------------------------------------------
    // 1. Standalone Unit Under Test: ecc_scalar_blinding
    // -----------------------------------------------------------------------
    logic         sb_rst_n;
    logic         sb_zeroize;
    logic         sb_en;
    logic [383:0] sb_data_i;
    logic [191:0] sb_rnd_i;
    wire  [575:0] sb_data_o;
    wire          sb_busy_o;

    ecc_scalar_blinding #(
        .REG_SIZE(384),
        .RND_SIZE(192),
        .RADIX(32),
        .GROUP_ORDER(GROUP_ORDER)
    ) u_sb (
        .clk(clk),
        .reset_n(sb_rst_n),
        .zeroize(sb_zeroize),
        .en_i(sb_en),
        .data_i(sb_data_i),
        .rnd_i(sb_rnd_i),
        .data_o(sb_data_o),
        .busy_o(sb_busy_o)
    );

    // -----------------------------------------------------------------------
    // 2. Standalone Unit Under Test: ecc_hmac_drbg_interface (inst_id == 0)
    // -----------------------------------------------------------------------
    logic         di_rst_n;
    logic         di_zeroize;
    logic [1:0]   di_mode;
    logic         di_en;
    wire          di_ready;
    logic [383:0] di_seed, di_nonce, di_privkey, di_msg, di_iv;
    wire  [383:0] di_lambda, di_scalar_rnd, di_masking_rnd, di_drbg;

    ecc_hmac_drbg_interface #(
        .REG_SIZE(384),
        .GROUP_ORDER(GROUP_ORDER)
    ) u_drbg_if (
        .clk(clk),
        .reset_n(di_rst_n),
        .zeroize(di_zeroize),
        .hmac_mode(di_mode),
        .en(di_en),
        .ready(di_ready),
        .keygen_seed(di_seed),
        .keygen_nonce(di_nonce),
        .privKey(di_privkey),
        .hashed_msg(di_msg),
        .IV(di_iv),
        .lambda(di_lambda),
        .scalar_rnd(di_scalar_rnd),
        .masking_rnd(di_masking_rnd),
        .drbg(di_drbg)
    );

    // -----------------------------------------------------------------------
    // 3. Full Subsystem Under Test: ecc_top (inst_id == 1)
    // -----------------------------------------------------------------------
    logic         reset_n;
    logic         cptra_pwrgood;
    logic [31:0]  haddr_i;
    logic [31:0]  hwdata_i;
    logic         hsel_i;
    logic         hwrite_i;
    logic         hready_i;
    logic [1:0]   htrans_i;
    logic [2:0]   hsize_i;
    wire          hresp_o;
    wire          hreadyout_o;
    wire  [31:0]  hrdata_o;

    kv_read_t  [1:0]   kv_read;
    kv_write_t         kv_write;
    kv_rd_resp_t [1:0] kv_rd_resp;
    kv_wr_resp_t       kv_wr_resp;
    pcr_signing_t            pcr_signing_data;
    logic                    ocp_lock_in_progress;
    wire                     busy_o;
    wire                     error_intr;
    wire                     notif_intr;
    logic                    debugUnlock_or_scan_mode_switch;

    ecc_top dut (
        .clk(clk),
        .reset_n(reset_n),
        .cptra_pwrgood(cptra_pwrgood),
        .haddr_i(haddr_i),
        .hwdata_i(hwdata_i),
        .hsel_i(hsel_i),
        .hwrite_i(hwrite_i),
        .hready_i(hready_i),
        .htrans_i(htrans_i),
        .hsize_i(hsize_i),
        .hresp_o(hresp_o),
        .hreadyout_o(hreadyout_o),
        .hrdata_o(hrdata_o),
        .kv_read(kv_read),
        .kv_write(kv_write),
        .kv_rd_resp(kv_rd_resp),
        .kv_wr_resp(kv_wr_resp),
        .pcr_signing_data(pcr_signing_data),
        .ocp_lock_in_progress(ocp_lock_in_progress),
        .busy_o(busy_o),
        .error_intr(error_intr),
        .notif_intr(notif_intr),
        .debugUnlock_or_scan_mode_switch(debugUnlock_or_scan_mode_switch)
    );

    // -----------------------------------------------------------------------
    // Simple KeyVault Responder Model (Slot 2 = PKEY, Slot 3 = SEED, Slot 4 = WR)
    // -----------------------------------------------------------------------
    logic [383:0] kv_slot_pkey;
    logic [383:0] kv_slot_seed;
    logic [11:0][31:0] kv_wr_dwords;
    int           kv_wr_beat_cnt;
    logic         kv_wr_seen_any;

    always_comb begin
        for (int c = 0; c < 2; c++) begin
            kv_rd_resp[c].error            = 1'b0;
            kv_rd_resp[c].last             = (kv_read[c].read_offset == 4'd11);
            kv_rd_resp[c].entry_last_dword = 4'd11;
            if (c == 0)
                kv_rd_resp[c].read_data = kv_slot_pkey[383 - 32 * int'(kv_read[c].read_offset) -: 32];
            else
                kv_rd_resp[c].read_data = kv_slot_seed[383 - 32 * int'(kv_read[c].read_offset) -: 32];
        end
    end

    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            kv_wr_dwords   <= '0;
            kv_wr_beat_cnt <= 0;
            kv_wr_seen_any <= 1'b0;
        end else if (kv_write.write_en && !kv_wr_resp.error) begin
            if (kv_write.write_offset < 4'd12)
                kv_wr_dwords[11 - kv_write.write_offset] <= kv_write.write_data;
            kv_wr_beat_cnt <= kv_wr_beat_cnt + 1;
            kv_wr_seen_any <= 1'b1;
        end
    end

    // -----------------------------------------------------------------------
    // CSR Offsets & Helpers
    // -----------------------------------------------------------------------
    localparam logic [31:0] ADDR_CTRL             = 32'h010;
    localparam logic [31:0] ADDR_STATUS           = 32'h018;
    localparam logic [31:0] ADDR_SEED             = 32'h080;
    localparam logic [31:0] ADDR_MSG              = 32'h100;
    localparam logic [31:0] ADDR_PRIVKEY_OUT      = 32'h180;
    localparam logic [31:0] ADDR_PUBKEY_X         = 32'h200;
    localparam logic [31:0] ADDR_PUBKEY_Y         = 32'h280;
    localparam logic [31:0] ADDR_SIGN_R           = 32'h300;
    localparam logic [31:0] ADDR_SIGN_S           = 32'h380;
    localparam logic [31:0] ADDR_VERIFY_R         = 32'h400;
    localparam logic [31:0] ADDR_IV               = 32'h480;
    localparam logic [31:0] ADDR_NONCE            = 32'h500;
    localparam logic [31:0] ADDR_PRIVKEY_IN       = 32'h580;
    localparam logic [31:0] ADDR_DH_SHARED_KEY    = 32'h5C0;
    localparam logic [31:0] ADDR_KV_RD_PKEY_CTRL  = 32'h600;
    localparam logic [31:0] ADDR_KV_RD_PKEY_STS   = 32'h604;
    localparam logic [31:0] ADDR_KV_RD_SEED_CTRL  = 32'h608;
    localparam logic [31:0] ADDR_KV_RD_SEED_STS   = 32'h60C;
    localparam logic [31:0] ADDR_KV_WR_PKEY_CTRL  = 32'h610;
    localparam logic [31:0] ADDR_KV_WR_PKEY_STS   = 32'h614;
    localparam logic [31:0] ADDR_GLOBAL_INTR_EN   = 32'h800;
    localparam logic [31:0] ADDR_ERROR_INTR_EN    = 32'h804;
    localparam logic [31:0] ADDR_NOTIF_INTR_EN    = 32'h808;
    localparam logic [31:0] ADDR_ERROR_INTR_STS   = 32'h814;
    localparam logic [31:0] ADDR_NOTIF_INTR_STS   = 32'h818;

    int checks   = 0;
    int failures = 0;

    task automatic check_cond(input bit cond, input string msg);
        checks++;
        if (!cond) begin
            failures++;
            if (failures <= 30)
                $display("[FAIL] @%0t: %s", $time, msg);
        end
    endtask

    function automatic logic [11:0][31:0] pack_pcr384(input logic [383:0] v);
        logic [11:0][31:0] arr;
        for (int d = 0; d < 12; d++)
            arr[d] = v[383 - 32*d -: 32];
        return arr;
    endfunction

    task automatic ahb_write(input logic [31:0] addr, input logic [31:0] wdata);
        @(negedge clk);
        haddr_i  = addr;
        hsel_i   = 1'b1;
        hwrite_i = 1'b1;
        hready_i = 1'b1;
        htrans_i = 2'b10;
        hsize_i  = 3'b010;
        @(posedge clk);
        @(negedge clk);
        hwdata_i = wdata;
        haddr_i  = 32'h0;
        hsel_i   = 1'b0;
        hwrite_i = 1'b0;
        htrans_i = 2'b00;
        while (!hreadyout_o) begin
            @(posedge clk);
            @(negedge clk);
        end
        @(posedge clk);
        @(negedge clk);
        hwdata_i = 32'h0;
    endtask

    task automatic ahb_read(input logic [31:0] addr, output logic [31:0] rdata);
        @(negedge clk);
        haddr_i  = addr;
        hsel_i   = 1'b1;
        hwrite_i = 1'b0;
        hready_i = 1'b1;
        htrans_i = 2'b10;
        hsize_i  = 3'b010;
        @(posedge clk);
        @(negedge clk);
        haddr_i  = 32'h0;
        hsel_i   = 1'b0;
        htrans_i = 2'b00;
        while (!hreadyout_o) begin
            @(posedge clk);
            @(negedge clk);
        end
        rdata = hrdata_o;
        @(posedge clk);
    endtask

    task automatic write_384(input logic [31:0] base, input logic [383:0] val);
        for (int i = 0; i < 12; i++)
            ahb_write(base + 32'(4*i), val[383 - 32*i -: 32]);
    endtask

    task automatic read_384(input logic [31:0] base, output logic [383:0] val);
        logic [31:0] dw;
        for (int i = 0; i < 12; i++) begin
            ahb_read(base + 32'(4*i), dw);
            val[383 - 32*i -: 32] = dw;
        end
    endtask

    task automatic enable_intrs();
        ahb_write(ADDR_GLOBAL_INTR_EN, 32'h0000_0003);
        ahb_write(ADDR_ERROR_INTR_EN,  32'h0000_0001);
        ahb_write(ADDR_NOTIF_INTR_EN,  32'h0000_0001);
        ahb_write(ADDR_ERROR_INTR_STS, 32'h0000_0001);
        ahb_write(ADDR_NOTIF_INTR_STS, 32'h0000_0001);
    endtask

    task automatic clear_intrs();
        ahb_write(ADDR_ERROR_INTR_STS, 32'h0000_0001);
        ahb_write(ADDR_NOTIF_INTR_STS, 32'h0000_0001);
    endtask

    task automatic reset_dut();
        haddr_i  = 32'h0;
        hwdata_i = 32'h0;
        hsel_i   = 1'b0;
        hwrite_i = 1'b0;
        hready_i = 1'b1;
        htrans_i = 2'b00;
        hsize_i  = 3'b010;
        kv_wr_resp.error = 1'b0;
        ocp_lock_in_progress = 1'b0;
        debugUnlock_or_scan_mode_switch = 1'b0;
        pcr_signing_data = '0;

        drbg_mock_en[1]        = 1'b1;
        drbg_hold_not_rdy[1]   = 1'b0;
        drbg_stall_cycles[1]   = 2;
        drbg_zero_low192_n[1]  = 0;
        drbg_force_zero_rnd[1] = 1'b0;
        drbg_fixed_keygen[1]   = '0;
        drbg_fixed_sign[1]     = '0;

        pm_latency_cycles = 8;
        cfg_kg_qx      = 384'h11223344_55667788_99AABBCC_DDEEFF00_11223344_55667788_99AABBCC_DDEEFF00_11223344_55667788_99AABBCC_DDEEFF01;
        cfg_kg_qy      = 384'h22334455_66778899_AABBCCDD_EEFF0011_22334455_66778899_AABBCCDD_EEFF0011_22334455_66778899_AABBCCDD_EEFF0022;
        cfg_sgn_r      = 384'h33445566_778899AA_BBCCDDEE_FF001122_33445566_778899AA_BBCCDDEE_FF001122_33445566_778899AA_BBCCDDEE_FF001133;
        cfg_sgn_s      = 384'h44556677_8899AABB_CCDDEEFF_00112233_44556677_8899AABB_CCDDEEFF_00112233_44556677_8899AABB_CCDDEEFF_00112244;
        cfg_pk_chk_val = 384'd0;
        cfg_ver_u1     = 384'h55667788_99AABBCC_DDEEFF00_11223344_55667788_99AABBCC_DDEEFF00_11223344_55667788_99AABBCC_DDEEFF00_11223355;
        cfg_ver_u2     = 384'h66778899_AABBCCDD_EEFF0011_22334455_66778899_AABBCCDD_EEFF0011_22334455_66778899_AABBCCDD_EEFF0011_22334466;
        cfg_ver_rx     = cfg_sgn_r;
        cfg_dh_shared  = 384'h778899AA_BBCCDDEE_FF001122_33445566_778899AA_BBCCDDEE_FF001122_33445566_778899AA_BBCCDDEE_FF001122_33445577;

        cptra_pwrgood = 1'b0;
        reset_n       = 1'b0;
        repeat (4) @(posedge clk);
        cptra_pwrgood = 1'b1;
        repeat (2) @(posedge clk);
        reset_n       = 1'b1;
        repeat (16) @(posedge clk);
        enable_intrs();
    endtask

    task automatic wait_ecc_idle(output logic [31:0] sts, output bit timed_out);
        timed_out = 1'b1;
        repeat (2) @(posedge clk);
        for (int p = 0; p < 400; p++) begin
            ahb_read(ADDR_STATUS, sts);
            if (sts[0] && !busy_o) begin
                timed_out = 1'b0;
                break;
            end
        end
        repeat (3) @(posedge clk);
        ahb_read(ADDR_STATUS, sts);
    endtask

    task automatic check_all_outputs_zero(input string tag);
        logic [383:0] v;
        read_384(ADDR_PRIVKEY_OUT,   v); check_cond(v === '0, {tag, ": ECC_PRIVKEY_OUT must be 0"});
        read_384(ADDR_PUBKEY_X,      v); check_cond(v === '0, {tag, ": ECC_PUBKEY_X must be 0"});
        read_384(ADDR_PUBKEY_Y,      v); check_cond(v === '0, {tag, ": ECC_PUBKEY_Y must be 0"});
        read_384(ADDR_SIGN_R,        v); check_cond(v === '0, {tag, ": ECC_SIGN_R must be 0"});
        read_384(ADDR_SIGN_S,        v); check_cond(v === '0, {tag, ": ECC_SIGN_S must be 0"});
        read_384(ADDR_VERIFY_R,      v); check_cond(v === '0, {tag, ": ECC_VERIFY_R must be 0"});
        read_384(ADDR_DH_SHARED_KEY, v); check_cond(v === '0, {tag, ": ECC_DH_SHARED_KEY must be 0"});
    endtask

    task automatic populate_nonzero_outputs();
        logic [31:0] sts;
        bit to;
        // Run valid KEYGEN + SIGN + VERIFY + DH_SHAREDKEY so output CSRs hold non-zero values prior to fault
        write_384(ADDR_SEED,  384'hA1A2A3A4_B1B2B3B4_C1C2C3C4_D1D2D3D4_E1E2E3E4_F1F2F3F4_01020304_05060708_090A0B0C_0D0E0F10_11121314_15161718);
        write_384(ADDR_NONCE, 384'h10203040_50607080_90A0B0C0_D0E0F001_10203040_50607080_90A0B0C0_D0E0F002_10203040_50607080_90A0B0C0_D0E0F003);
        write_384(ADDR_IV,    384'hCAFEBABE_DEADBEEF_01234567_89ABCDEF_CAFEBABE_DEADBEEF_01234567_89ABCDEF_CAFEBABE_DEADBEEF_01234567_89ABCDE1);
        drbg_cmd_round[1] = 0;
        ahb_write(ADDR_CTRL, 32'h01); // KEYGEN
        wait_ecc_idle(sts, to);

        write_384(ADDR_PRIVKEY_IN, 384'h01234567_89ABCDEF_FEDCBA98_76543210_01234567_89ABCDEF_FEDCBA98_76543210_01234567_89ABCDEF_FEDCBA98_76543211);
        write_384(ADDR_MSG,        384'h55AA55AA_12345678_9ABCDEF0_13579BDF_2468ACE0_55AA55AA_12345678_9ABCDEF0_13579BDF_2468ACE0_55AA55AA_12345679);
        drbg_cmd_round[1] = 0;
        ahb_write(ADDR_CTRL, 32'h02); // SIGN
        wait_ecc_idle(sts, to);

        drbg_cmd_round[1] = 0;
        ahb_write(ADDR_CTRL, 32'h03); // VERIFY
        wait_ecc_idle(sts, to);

        drbg_cmd_round[1] = 0;
        ahb_write(ADDR_CTRL, 32'h10); // DH_SHAREDKEY
        wait_ecc_idle(sts, to);
        clear_intrs();
    endtask

    task automatic zeroize_and_recover();
        logic [31:0] sts;
        bit to;
        ahb_write(ADDR_CTRL, 32'h04); // ZEROIZE
        repeat (6) @(posedge clk);
        clear_intrs();
        wait_ecc_idle(sts, to);
        check_cond(!to && sts[0] === 1'b1 && sts[1] === 1'b0 && sts[2] === 1'b0, "Post-ZEROIZE must return READY=1, VALID=0, VERIFY_PASS=0");
    endtask

    // -----------------------------------------------------------------------
    // Main Verification Sequence
    // -----------------------------------------------------------------------
    initial begin
        int unsigned seed = 101;
        logic [31:0] sts, kv_ctrl_rd, kv_sts_rd;
        logic [383:0] v384, first_lambda, second_lambda;
        logic [575:0] exp576;
        bit to;
        int w;

        void'($value$plusargs("seed=%d", seed));
        void'($urandom(seed));

        sb_rst_n = 1'b0; sb_zeroize = 1'b0; sb_en = 1'b0; sb_data_i = '0; sb_rnd_i = '0;
        di_rst_n = 1'b0; di_zeroize = 1'b0; di_mode = 2'b00; di_en = 1'b0;
        di_seed = '0; di_nonce = '0; di_privkey = '0; di_msg = '0; di_iv = '0;
        drbg_mock_en[0] = 1'b1; drbg_hold_not_rdy[0] = 1'b0; drbg_stall_cycles[0] = 0;
        drbg_zero_low192_n[0] = 0; drbg_force_zero_rnd[0] = 1'b0;
        drbg_fixed_keygen[0] = '0; drbg_fixed_sign[0] = '0;

        repeat (4) @(posedge clk);
        sb_rst_n = 1'b1;
        di_rst_n = 1'b1;
        repeat (4) @(posedge clk);

        // ===================================================================
        // T1: Standalone ecc_scalar_blinding Verification
        // ===================================================================
        $display("[TB] T1: ecc_scalar_blinding valid math, degenerate input suppression, and mid-run zeroize...");
        begin
            logic [383:0] valid_scalars [0:2];
            logic [191:0] valid_rnds    [0:2];
            int           valid_lat0;
            valid_scalars[0] = 384'd1;
            valid_scalars[1] = GROUP_ORDER - 384'd1;
            valid_scalars[2] = {12{$urandom(seed ^ 32'h13579BDF)}} & {1'b0, {383{1'b1}}};
            if (valid_scalars[2] == '0) valid_scalars[2] = 384'd42;
            valid_rnds[0] = 192'd1;
            valid_rnds[1] = {192{1'b1}};
            valid_rnds[2] = {6{$urandom(seed ^ 32'h2468ACE0)}} | 192'd1;

            for (int k = 0; k < 3; k++) begin
                @(negedge clk);
                sb_data_i = valid_scalars[k];
                sb_rnd_i  = valid_rnds[k];
                sb_en     = 1'b1;
                @(posedge clk);
                @(negedge clk);
                sb_en     = 1'b0;
                w = 0;
                while (sb_busy_o && w < 200) begin @(posedge clk); w++; end
                if (k == 0) valid_lat0 = w;
                else check_cond(w == valid_lat0, $sformatf("T1 valid blinding latency must be constant-time (vec0=%0d, vec%0d=%0d)", valid_lat0, k, w));
                @(posedge clk);
                exp576 = 576'(valid_scalars[k]) + (576'(valid_rnds[k]) * 576'(GROUP_ORDER));
                check_cond(!sb_busy_o && sb_data_o === exp576, $sformatf("T1 valid blinding vector %0d mismatch", k));
            end

            // Degenerate inputs when data_o already holds non-zero value from previous valid run
            for (int bad = 0; bad < 4; bad++) begin
                // Re-populate non-zero data_o first
                @(negedge clk);
                sb_data_i = 384'h12345678_9ABCDEF1;
                sb_rnd_i  = 192'hCAFEBABE_00000001;
                sb_en     = 1'b1;
                @(posedge clk);
                @(negedge clk);
                sb_en     = 1'b0;
                w = 0;
                while (sb_busy_o && w < 200) begin @(posedge clk); w++; end
                @(posedge clk);
                check_cond(sb_data_o != '0, "T1 pre-degenerate data_o must be non-zero");

                @(negedge clk);
                unique case (bad)
                    0: begin sb_data_i = '0;                  sb_rnd_i = 192'd7; end
                    1: begin sb_data_i = GROUP_ORDER;         sb_rnd_i = 192'd7; end
                    2: begin sb_data_i = {384{1'b1}};         sb_rnd_i = 192'd7; end
                    3: begin sb_data_i = 384'h99887766_55443; sb_rnd_i = '0;     end
                endcase
                sb_en = 1'b1;
                @(posedge clk);
                @(negedge clk);
                sb_en = 1'b0;
                w = 0;
                while (sb_busy_o && w < 60) begin @(posedge clk); w++; end
                @(posedge clk);
                check_cond(!sb_busy_o && sb_data_o === '0, $sformatf("T1 degenerate case %0d must return busy_o=0 and data_o=0", bad));
            end

            // Mid-operation zeroize (sample immediately after launch + 1 active MAC cycle so fast widened-radix MACs are still in-flight)
            @(negedge clk);
            sb_data_i = GROUP_ORDER - 384'd99;
            sb_rnd_i  = 192'hFEDCBA98_76543210_01234567_89ABCDEF_55AA55AA_12345678;
            sb_en     = 1'b1;
            @(posedge clk);
            @(negedge clk);
            sb_en     = 1'b0;
            check_cond(sb_busy_o === 1'b1, "T1 scalar blinding should assert busy_o immediately after launch");
            @(posedge clk);
            #1;
            check_cond(sb_busy_o === 1'b1, "T1 scalar blinding should be busy mid-run");
            @(negedge clk);
            sb_zeroize = 1'b1;
            @(posedge clk);
            #1;
            check_cond(sb_busy_o === 1'b0 && sb_data_o === '0, "T1 zeroize must clear busy_o and data_o in 1 cycle");
            @(negedge clk);
            sb_zeroize = 1'b0;
            repeat (6) @(posedge clk);
            #1;
            check_cond(sb_busy_o === 1'b0 && sb_data_o === '0, "T1 aborted blinding run must remain idle/zero after zeroize deasserts");
        end

        // ===================================================================
        // T2: Standalone ecc_hmac_drbg_interface Verification
        // ===================================================================
        $display("[TB] T2: ecc_hmac_drbg_interface ready gating, stall handshake, 192-bit zero slice retry, & freshness...");
        begin
            // 2a. ready must be 0 when hmac_drbg_ready == 0, and IV must NOT snapshot until en && ready
            drbg_hold_not_rdy[0] = 1'b1;
            di_iv      = 384'hAAAA_BBBB_CCCC_DDDD;
            di_privkey = 384'h1111_2222_3333_4444;
            di_msg     = 384'h5555_6666_7777_8888;
            di_mode    = 2'b01; // SIGN_CMD
            @(negedge clk);
            di_en = 1'b1;
            #1;
            check_cond(di_ready === 1'b0, "T2 di_ready must be 0 while hmac_drbg_ready==0");
            repeat (3) @(posedge clk);
            // Change IV before releasing drbg_hold_not_rdy; accepted launch must use NEW IV!
            @(negedge clk);
            di_iv = 384'h12345678_9ABCDEF0_11223344_55667788_99AABBCC_DDEEFF00_0F1E2D3C_4B5A6978_8796A5B4_C3D2E1F0_13579BDF_2468ACE1;
            drbg_hold_not_rdy[0] = 1'b0;
            drbg_stall_cycles[0] = 5;
            drbg_zero_low192_n[0] = 3; // force 3 rejected 192-bit zero slices!
            drbg_cmd_round[0] = 0;
            obs_next_cnt[0]   = 0;
            #1;
            check_cond(di_ready === 1'b1, "T2 di_ready must assert once hmac_drbg_ready==1");
            @(posedge clk);
            @(negedge clk);
            di_en = 1'b0;
            // Mutate di_iv in-flight — must NOT affect snapshotted sca_entropy!
            di_iv = 384'hDEAD_DEAD_DEAD_DEAD;

            w = 0;
            while (!di_ready && w < 300) begin @(posedge clk); w++; end
            check_cond(di_ready === 1'b1, "T2 SIGN_CMD must finish without hanging under 5-cycle DRBG stalls");
            check_cond(obs_lfsr_entropy[0] !== (384'hAAAA_BBBB_CCCC_DDDD ^ 384'h0), "T2 must snapshot IV on en&&ready, not while !ready");
            check_cond(di_scalar_rnd[191:0] !== '0, "T2 scalar_rnd[191:0] must be non-zero after rejecting zero-low192 slices");
            check_cond(obs_next_cnt[0] >= 6, "T2 must re-issue hmac_drbg_next for all 3 rejected scalar_rnd[191:0]==0 draws");
            check_cond(di_masking_rnd !== '0 && di_drbg !== '0, "T2 SIGN_CMD must populate masking_rnd and drbg");

            // 2b. Cross-command freshness: launch DH_SHARED_CMD (2'b10) and verify masking_rnd & drbg clear to 0!
            drbg_cmd_round[0] = 0;
            drbg_zero_low192_n[0] = 0;
            @(negedge clk);
            di_mode = 2'b10; // DH_SHARED_CMD
            di_iv   = 384'hCAFE0001_CAFE0002_CAFE0003;
            di_en   = 1'b1;
            @(posedge clk);
            #1;
            check_cond(di_masking_rnd === '0 && di_drbg === '0 && di_lambda === '0 && di_scalar_rnd === '0,
                       "T2 en&&ready must immediately clear prior-command outputs");
            @(negedge clk);
            di_en = 1'b0;
            w = 0;
            while (!di_ready && w < 300) begin @(posedge clk); w++; end
            check_cond(di_ready === 1'b1 && di_lambda !== '0 && di_scalar_rnd[191:0] !== '0 &&
                       di_masking_rnd === '0 && di_drbg === '0,
                       "T2 DH_SHARED_CMD must not leak prior SIGN_CMD masking_rnd or drbg");

            // 2c. Zeroize resets internal counter_nonce & sca_entropy identically to cold reset
            di_rst_n = 1'b0;
            repeat (3) @(posedge clk);
            di_rst_n = 1'b1;
            repeat (2) @(posedge clk);
            drbg_cmd_round[0] = 0;
            @(negedge clk);
            di_iv   = 384'h01020304_05060708_090A0B0C;
            di_mode = 2'b10;
            di_en   = 1'b1;
            @(posedge clk);
            @(negedge clk);
            di_en   = 1'b0;
            w = 0;
            while (!di_ready && w < 300) begin @(posedge clk); w++; end
            first_lambda = di_lambda;

            // Now zeroize (without toggling reset_n!) and verify sca_entropy_reg, counter_nonce_reg, and lfsr_seed_reg are scrubbed!
            @(negedge clk);
            di_zeroize = 1'b1;
            @(posedge clk);
            #1;
            check_cond(di_lambda === '0 && di_scalar_rnd === '0 && di_masking_rnd === '0 && di_drbg === '0,
                       "T2 zeroize must wipe all DRBG interface outputs");
            @(negedge clk);
            di_zeroize = 1'b0;
            repeat (2) @(posedge clk);
            check_cond(obs_idle_entropy[0] === '0 && obs_idle_nonce[0] === '0,
                       "T2 zeroize must scrub internal sca_entropy_reg and counter_nonce_reg");
            repeat (2) @(posedge clk);
            drbg_cmd_round[0] = 0;
            @(negedge clk);
            di_en = 1'b1;
            @(posedge clk);
            @(negedge clk);
            di_en = 1'b0;
            w = 0;
            while (!di_ready && w < 300) begin @(posedge clk); w++; end
            check_cond((obs_lfsr_entropy[0] ^ obs_lfsr_nonce[0] ^ di_iv) === '0,
                       "T2 zeroize must scrub internal lfsr_seed_reg to zero");

            // 2d. Real SHA-512 HMAC-DRBG end-to-end handshake smoke test (drbg_mock_en[0] = 0)
            drbg_mock_en[0] = 1'b0;
            di_rst_n = 1'b0;
            repeat (3) @(posedge clk);
            di_rst_n = 1'b1;
            w = 0;
            while (!di_ready && w < 500) begin @(posedge clk); w++; end
            check_cond(di_ready === 1'b1, "T2 real HMAC-DRBG ready after reset");
            @(negedge clk);
            di_iv   = 384'hA5A5A5A5_5A5A5A5A_12345678_9ABCDEF0;
            di_mode = 2'b10;
            di_en   = 1'b1;
            @(posedge clk);
            @(negedge clk);
            di_en   = 1'b0;
            w = 0;
            while (!di_ready && w < 6000) begin @(posedge clk); w++; end
            check_cond(di_ready === 1'b1 && di_lambda !== '0 && di_scalar_rnd[191:0] !== '0,
                       "T2 real SHA-512 HMAC-DRBG DH_SHARED_CMD handshake failed");
        end

        // ===================================================================
        // T3: Full ecc_top Valid Operations (CSR + KeyVault + VERIFY pass/fail)
        // ===================================================================
        $display("[TB] T3: Full ecc_top valid KEYGEN (CSR & KV), SIGN (blinded scalar), VERIFY, and DH_SHAREDKEY...");
        reset_dut();

        // 3a. Valid KV KEYGEN -> writes generated private key to KV slot 4 without exposing ECC_PRIVKEY_OUT
        kv_slot_seed         = 384'h11112222_33334444_55556666_77778888_9999AAAA_BBBBCCCC_DDDDEEEE_FFFF0001_12345678_9ABCDEF0_13579BDF_2468ACE1;
        drbg_fixed_keygen[1] = 384'h0ACE1357_9BDF2468_11223344_55667788_99AABBCC_DDEEFF00_11223344_55667788_99AABBCC_DDEEFF00_12345678_9ABCDEF5;
        kv_wr_seen_any       = 1'b0;
        kv_wr_beat_cnt       = 0;
        write_384(ADDR_NONCE, 384'h01020304_05060708);
        write_384(ADDR_IV,    384'h89ABCDEF_01234567);
        // Trigger KV seed read from slot 3 (read_entry=3, read_en=1 -> {25'd0, 5'd3, 1'b0, 1'b1} = 32'h0D)
        ahb_write(ADDR_KV_RD_SEED_CTRL, {25'd0, 5'd3, 1'b0, 1'b1});
        for (int p = 0; p < 60; p++) begin
            ahb_read(ADDR_KV_RD_SEED_STS, kv_sts_rd);
            if (kv_sts_rd[1] && kv_sts_rd[0]) break;
        end
        check_cond(kv_sts_rd[1] === 1'b1, "T3 KV seed read VALID");
        // Arm KV pkey write to slot 4 with ecc_pkey_dest_valid (dest bit 3 -> 9'h008): {17'd0, 9'h008, 5'd4, 1'b1}
        ahb_write(ADDR_KV_WR_PKEY_CTRL, {17'd0, 9'h008, 5'd4, 1'b1});
        drbg_cmd_round[1] = 0;
        ahb_write(ADDR_CTRL, 32'h01); // KEYGEN
        wait_ecc_idle(sts, to);
        check_cond(!to && sts[1] === 1'b1 && error_intr === 1'b0 && notif_intr === 1'b1, "T3 KV KEYGEN completion status");
        check_cond(kv_wr_seen_any && kv_wr_beat_cnt == 12 && kv_wr_dwords === drbg_fixed_keygen[1], "T3 KV KEYGEN writeback data mismatch");
        read_384(ADDR_PRIVKEY_OUT, v384);
        check_cond(v384 === '0, "T3 KV KEYGEN must NOT expose private key in ECC_PRIVKEY_OUT");
        read_384(ADDR_PUBKEY_X, v384);
        check_cond(v384 === cfg_kg_qx, "T3 KV KEYGEN PUBKEY_X mismatch");
        drbg_fixed_keygen[1] = '0;
        clear_intrs();

        // 3b. Valid CSR SIGN + verify 576-bit blinded scalar k + r*q passed to ecc_arith_unit
        write_384(ADDR_PRIVKEY_IN, 384'h0FEDCBA9_87654321_11223344_55667788_99AABBCC_DDEEFF00_13579BDF_2468ACE0_CAFEBABE_12345678_87654321_00000077);
        write_384(ADDR_MSG,        384'h12345678_9ABCDEF0_0FEDCBA9_87654321_55AA55AA_A5A5A5A5_01020304_05060708_090A0B0C_0D0E0F10_11121314_15161718);
        drbg_fixed_sign[1] = 384'h00112233_44556677_8899AABB_CCDDEEFF_00112233_44556677_8899AABB_CCDDEEFF_00112233_44556677_8899AABB_CCDDEEF9;
        drbg_zero_low192_n[1] = 2; // also exercise 192-bit zero mask retry inside full ecc_top!
        drbg_cmd_round[1] = 0;
        ahb_write(ADDR_CTRL, 32'h02); // SIGN
        wait_ecc_idle(sts, to);
        check_cond(!to && sts[1] === 1'b1 && error_intr === 1'b0, "T3 CSR SIGN valid completion");
        check_cond(obs_pm_secret_key[575:384] !== '0 &&
                   (obs_pm_secret_key - 576'(drbg_fixed_sign[1])) % 576'(GROUP_ORDER) == 0,
                   "T3 CSR SIGN scalar sent to ecc_arith_unit must be validly blinded modulo GROUP_ORDER");
        read_384(ADDR_SIGN_R, v384); check_cond(v384 === cfg_sgn_r, "T3 SIGN_R mismatch");
        read_384(ADDR_SIGN_S, v384); check_cond(v384 === cfg_sgn_s, "T3 SIGN_S mismatch");
        drbg_fixed_sign[1] = '0;
        clear_intrs();

        // 3c. Valid VERIFY (matching R -> VERIFY_PASS=1; mismatching R -> VALID=1, VERIFY_PASS=0, error_intr=0)
        cfg_ver_rx = cfg_sgn_r;
        ahb_write(ADDR_CTRL, 32'h03); // VERIFY
        wait_ecc_idle(sts, to);
        check_cond(!to && sts[1] === 1'b1 && sts[2] === 1'b1 && error_intr === 1'b0, "T3 VERIFY matching R must set VERIFY_PASS=1");
        clear_intrs();

        cfg_ver_rx = cfg_sgn_r ^ 384'd1;
        ahb_write(ADDR_CTRL, 32'h03); // VERIFY mismatch
        wait_ecc_idle(sts, to);
        check_cond(!to && sts[1] === 1'b1 && sts[2] === 1'b0 && error_intr === 1'b0, "T3 VERIFY mismatching R must clear VERIFY_PASS=0 without error_intr");
        cfg_ver_rx = cfg_sgn_r;
        clear_intrs();

        // ===================================================================
        // T4: Degenerate Operand/Output Fault Containment & Zero-Commit Suppression
        // ===================================================================
        $display("[TB] T4: Degenerate operands/outputs across KEYGEN, SIGN, VERIFY, DH_SHAREDKEY & sticky fault containment...");
        for (int fcase = 0; fcase < 12; fcase++) begin
            reset_dut();
            populate_nonzero_outputs();
            kv_wr_seen_any = 1'b0;
            obs_wr_scalar_cnt = 0;

            unique case (fcase)
                0: begin // SIGN privkey == 0
                    write_384(ADDR_PRIVKEY_IN, '0);
                    ahb_write(ADDR_CTRL, 32'h02);
                end
                1: begin // SIGN privkey >= GROUP_ORDER
                    write_384(ADDR_PRIVKEY_IN, GROUP_ORDER);
                    ahb_write(ADDR_CTRL, 32'h02);
                end
                2: begin // SIGN output s == GROUP_ORDER AFTER r was already read from PM! (partial ECC_SIGN_R must clear!)
                    cfg_sgn_s = GROUP_ORDER;
                    drbg_cmd_round[1] = 0;
                    ahb_write(ADDR_CTRL, 32'h02);
                end
                3: begin // SIGN output r == 0
                    cfg_sgn_r = '0;
                    drbg_cmd_round[1] = 0;
                    ahb_write(ADDR_CTRL, 32'h02);
                end
                4: begin // KEYGEN output privkey >= GROUP_ORDER with KV write armed!
                    drbg_fixed_keygen[1] = GROUP_ORDER;
                    ahb_write(ADDR_KV_WR_PKEY_CTRL, {17'd0, 9'h008, 5'd4, 1'b1});
                    drbg_cmd_round[1] = 0;
                    ahb_write(ADDR_CTRL, 32'h01);
                end
                5: begin // KEYGEN output pubkey_y >= PRIME AFTER privkey & pubkey_x were read!
                    cfg_kg_qy = PRIME;
                    drbg_cmd_round[1] = 0;
                    ahb_write(ADDR_CTRL, 32'h01);
                end
                6: begin // VERIFY r >= GROUP_ORDER
                    write_384(ADDR_SIGN_R, GROUP_ORDER);
                    ahb_write(ADDR_CTRL, 32'h03);
                end
                7: begin // VERIFY pubkey_x >= PRIME
                    write_384(ADDR_PUBKEY_X, PRIME);
                    ahb_write(ADDR_CTRL, 32'h03);
                end
                8: begin // VERIFY off-curve point pk_chk != 0
                    cfg_pk_chk_val = 384'd1;
                    ahb_write(ADDR_CTRL, 32'h03);
                end
                9: begin // DH_SHAREDKEY off-curve point pk_chk != 0 with KV write armed!
                    cfg_pk_chk_val = 384'd3;
                    ahb_write(ADDR_KV_WR_PKEY_CTRL, {17'd0, 9'h008, 5'd5, 1'b1});
                    drbg_cmd_round[1] = 0;
                    ahb_write(ADDR_CTRL, 32'h10);
                end
                10: begin // DH_SHAREDKEY output sharedkey == 0 with KV write armed!
                    cfg_dh_shared = '0;
                    ahb_write(ADDR_KV_WR_PKEY_CTRL, {17'd0, 9'h008, 5'd5, 1'b1});
                    drbg_cmd_round[1] = 0;
                    ahb_write(ADDR_CTRL, 32'h10);
                end
                11: begin // DH_SHAREDKEY output sharedkey >= PRIME with KV write armed!
                    cfg_dh_shared = PRIME;
                    ahb_write(ADDR_KV_WR_PKEY_CTRL, {17'd0, 9'h008, 5'd5, 1'b1});
                    drbg_cmd_round[1] = 0;
                    ahb_write(ADDR_CTRL, 32'h10);
                end
            endcase

            wait_ecc_idle(sts, to);
            check_cond(!to, $sformatf("T4 fault case %0d hung instead of returning READY=1", fcase));
            check_cond(error_intr === 1'b1 && notif_intr === 1'b0,
                       $sformatf("T4 fault case %0d must assert error_intr=1 and notif_intr=0", fcase));
            check_cond(sts[0] === 1'b1 && sts[1] === 1'b0 && sts[2] === 1'b0,
                       $sformatf("T4 fault case %0d must return READY=1, VALID=0, VERIFY_PASS=0", fcase));
            check_cond(!kv_wr_seen_any, $sformatf("T4 fault case %0d must block kv_write.write_en", fcase));

            ahb_read(ADDR_KV_WR_PKEY_CTRL, kv_ctrl_rd);
            ahb_read(ADDR_KV_WR_PKEY_STS,  kv_sts_rd);
            check_cond(kv_ctrl_rd[0] === 1'b0 && kv_sts_rd[1] === 1'b0,
                       $sformatf("T4 fault case %0d must clear ECC_KV_WR_PKEY_CTRL.write_en and VALID", fcase));
            check_all_outputs_zero($sformatf("T4_case%0d", fcase));

            // Verify sticky latched fault blocks a follow-up operation until ZEROIZE is issued
            if (fcase == 2) begin
                cfg_sgn_s = 384'h12345;
                write_384(ADDR_PRIVKEY_IN, 384'h987654321);
                ahb_write(ADDR_CTRL, 32'h02);
                wait_ecc_idle(sts, to);
                check_cond(!to && sts[1] === 1'b0, "T4 latched fault must suppress new commands until ZEROIZE");
                check_all_outputs_zero("T4_latched");
                zeroize_and_recover();
            end
        end

        // ===================================================================
        // T5: Hardware PCR_SIGN Attestation Key Isolation
        // ===================================================================
        $display("[TB] T5: Hardware PCR_SIGN exclusive mode gating, KV mutual exclusion, & post-PCR scrubbing...");
        reset_dut();
        begin
            logic [383:0] pcr_priv, pcr_digest, rd_msg;
            pcr_priv   = 384'h0BADF00D_CAFEBABE_11223344_55667788_99AABBCC_DDEEFF00_13579BDF_2468ACE0_01020304_05060708_090A0B0C_0D0E0F11;
            pcr_digest = 384'h77665544_33221100_FEDCBA98_76543210_01234567_89ABCDEF_55AA55AA_A5A5A5A5_11112222_33334444_55556666_77778889;
            pcr_signing_data.pcr_ecc_signing_privkey = pack_pcr384(pcr_priv);
            pcr_signing_data.pcr_hash                = pack_pcr384(pcr_digest);
            pcr_signing_data.pcr_mldsa_signing_seed  = '0;

            // 5a. Invalid PCR_SIGN modes: PCR_SIGN alone (0x08), PCR_SIGN|KEYGEN (0x09), PCR_SIGN|VERIFY (0x0B), PCR_SIGN|DH (0x18), PCR_SIGN|SIGN|DH (0x1A)
            begin
                logic [31:0] bad_pcr_cmds [0:4] = '{32'h08, 32'h09, 32'h0B, 32'h18, 32'h1A};
                for (int b = 0; b < 5; b++) begin
                    zeroize_and_recover();
                    obs_pm_cmd_cnt = 0;
                    ahb_write(ADDR_CTRL, bad_pcr_cmds[b]);
                    wait_ecc_idle(sts, to);
                    check_cond(!to && error_intr === 1'b1 && sts[1] === 1'b0 && obs_pm_cmd_cnt == 0,
                               $sformatf("T5 invalid PCR_SIGN ctrl=0x%02x must immediately fault without running PM", bad_pcr_cmds[b]));
                    read_384(ADDR_MSG, rd_msg);
                    check_cond(rd_msg === '0, $sformatf("T5 invalid PCR_SIGN ctrl=0x%02x must not load ECC_MSG", bad_pcr_cmds[b]));
                end
            end

            // 5b. Invalid PCR_SIGN|SIGN while KV write armed or KV key resident!
            zeroize_and_recover();
            ahb_write(ADDR_KV_WR_PKEY_CTRL, {17'd0, 9'h008, 5'd4, 1'b1});
            obs_pm_cmd_cnt = 0;
            ahb_write(ADDR_CTRL, 32'h0A); // PCR_SIGN | SIGN while KV write armed!
            wait_ecc_idle(sts, to);
            check_cond(!to && error_intr === 1'b1 && sts[1] === 1'b0 && obs_pm_cmd_cnt == 0,
                       "T5 PCR_SIGN with KV write armed must immediately fault");

            zeroize_and_recover();
            kv_slot_pkey = 384'h01234567_89ABCDEF_11223344_55667788_99AABBCC_DDEEFF00_11223344_55667788_99AABBCC_DDEEFF00_11223344_55667789;
            ahb_write(ADDR_KV_RD_PKEY_CTRL, {25'd0, 5'd2, 1'b0, 1'b1});
            for (int p = 0; p < 60; p++) begin
                ahb_read(ADDR_KV_RD_PKEY_STS, kv_sts_rd);
                if (kv_sts_rd[1] && kv_sts_rd[0]) break;
            end
            obs_pm_cmd_cnt = 0;
            ahb_write(ADDR_CTRL, 32'h0A); // PCR_SIGN | SIGN while KV pkey resident!
            wait_ecc_idle(sts, to);
            check_cond(!to && error_intr === 1'b1 && sts[1] === 1'b0 && obs_pm_cmd_cnt == 0,
                       "T5 PCR_SIGN with resident KV key must immediately fault");

            // 5c. Valid PCR_SIGN|SIGN (0x0A): mid-flight PRIVKEY_IN SW write blocked, signs with pcr_priv/pcr_digest, then scrubs BOTH ECC_PRIVKEY_IN & ECC_MSG!
            zeroize_and_recover();
            write_384(ADDR_IV, 384'hA5A5_5A5A_CAFE_BABE_1234_5678);
            drbg_cmd_round[1] = 0;
            pm_latency_cycles = 24;
            ahb_write(ADDR_CTRL, 32'h0A); // Valid PCR_SIGN | SIGN
            // Attempt mid-flight overwrite of ECC_PRIVKEY_IN[11] while busy!
            ahb_write(ADDR_PRIVKEY_IN + 32'h2C, 32'hDEAD_BEEF);
            wait_ecc_idle(sts, to);
            pm_latency_cycles = 8;
            check_cond(!to && sts[1] === 1'b1 && error_intr === 1'b0 && notif_intr === 1'b1,
                       "T5 valid PCR_SIGN must succeed with VALID=1 and error_intr=0");
            check_cond(obs_pm_msg === pcr_digest, "T5 valid PCR_SIGN must sign pcr_signing_data.pcr_hash");
            read_384(ADDR_SIGN_R, v384); check_cond(v384 === cfg_sgn_r, "T5 valid PCR_SIGN SIGN_R mismatch");
            read_384(ADDR_SIGN_S, v384); check_cond(v384 === cfg_sgn_s, "T5 valid PCR_SIGN SIGN_S mismatch");
            // Verify ECC_MSG was scrubbed to 0 upon PCR_SIGN completion!
            read_384(ADDR_MSG, rd_msg);
            check_cond(rd_msg === '0, "T5 ECC_MSG must be scrubbed to 0 upon PCR_SIGN completion");

            // Verify ECC_PRIVKEY_IN was ALSO scrubbed: a follow-up SIGN or DH_SHAREDKEY without writing PRIVKEY_IN must immediately fault on privkey==0!
            clear_intrs();
            write_384(ADDR_MSG, 384'h12345678);
            drbg_cmd_round[1] = 0;
            ahb_write(ADDR_CTRL, 32'h02); // SIGN without new key
            wait_ecc_idle(sts, to);
            check_cond(!to && error_intr === 1'b1 && sts[1] === 1'b0,
                       "T5 post-PCR_SIGN follow-up SIGN without new key must fault (pcr_ecc_signing_privkey scrubbed)");
        end

        // ===================================================================
        // T6: Mid-Operation ZEROIZE & debugUnlock_or_scan_mode_switch Sanitization
        // ===================================================================
        $display("[TB] T6: Mid-operation ZEROIZE & debugUnlock_or_scan_mode_switch sanitization + post-zeroize recovery...");
        reset_dut();
        populate_nonzero_outputs();
        pm_latency_cycles = 40;
        write_384(ADDR_PRIVKEY_IN, 384'h01234567_89ABCDEF_13579BDF_2468ACE0_11223344_55667788_99AABBCC_DDEEFF00_11223344_55667788_99AABBCC_DDEEFF07);
        drbg_cmd_round[1] = 0;
        ahb_write(ADDR_CTRL, 32'h02); // Launch SIGN
        repeat (10) @(posedge clk);
        check_cond(busy_o === 1'b1, "T6 dut should be busy mid-SIGN");
        debugUnlock_or_scan_mode_switch = 1'b1;
        repeat (3) @(posedge clk);
        debugUnlock_or_scan_mode_switch = 1'b0;
        pm_latency_cycles = 8;
        wait_ecc_idle(sts, to);
        check_cond(!to && sts[0] === 1'b1 && sts[1] === 1'b0, "T6 debugUnlock mid-SIGN must abort cleanly to READY=1, VALID=0");
        check_all_outputs_zero("T6_debugUnlock");

        // Post-zeroize clean recovery
        clear_intrs();
        write_384(ADDR_PRIVKEY_IN, 384'h01234567_89ABCDEF_13579BDF_2468ACE0_11223344_55667788_99AABBCC_DDEEFF00_11223344_55667788_99AABBCC_DDEEFF09);
        write_384(ADDR_MSG,        384'hCAFEBABE_12345678);
        write_384(ADDR_IV,         384'h13579BDF_2468ACE0);
        drbg_cmd_round[1] = 0;
        ahb_write(ADDR_CTRL, 32'h02);
        wait_ecc_idle(sts, to);
        check_cond(!to && sts[1] === 1'b1 && error_intr === 1'b0, "T6 post-debugUnlock valid SIGN recovery failed");

        if (failures == 0) begin
            $display("RESULT: PASS (seed=%0d, checks=%0d)", seed, checks);
            $finish;
        end else begin
            $display("RESULT: FAIL (seed=%0d, failures=%0d, checks=%0d)", seed, failures, checks);
            $fatal(1, "Caliptra P-384 ECC security verification failed");
        end
    end

    initial begin
        #50_000_000;
        $display("RESULT: FAIL (watchdog_timeout)");
        $fatal(1, "Watchdog timeout in case_25004 tb");
    end
endmodule
