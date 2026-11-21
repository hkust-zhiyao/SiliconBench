`timescale 1ns/1ps
`include "caliptra_macros.svh"

module doe_key_obs (
    input logic         clk,
    input logic         zeroize,
    input logic [127:0] round_key,
    input logic [31:0]  sboxw,
    input logic         ready
);
endmodule

module doe_cbc_obs (
    input logic clk,
    input logic doe_init,
    input logic zeroize
);
endmodule

module tb;
    import doe_defines_pkg::*;
    import kv_defines_pkg::*;
    import ahb_defines_pkg::*;

    localparam int AHB_ADDR_WIDTH = 32;
    localparam int AHB_DATA_WIDTH = 32;

    // CSR byte offsets
    localparam logic [31:0] ADDR_DOE_IV0       = 32'h0000_0000;
    localparam logic [31:0] ADDR_DOE_IV1       = 32'h0000_0004;
    localparam logic [31:0] ADDR_DOE_IV2       = 32'h0000_0008;
    localparam logic [31:0] ADDR_DOE_IV3       = 32'h0000_000c;
    localparam logic [31:0] ADDR_DOE_CTRL      = 32'h0000_0010;
    localparam logic [31:0] ADDR_DOE_STATUS    = 32'h0000_0014;
    localparam logic [31:0] ADDR_GLOBAL_INTR   = 32'h0000_0800;
    localparam logic [31:0] ADDR_ERROR_INTR_EN = 32'h0000_0804;
    localparam logic [31:0] ADDR_NOTIF_INTR_EN = 32'h0000_0808;
    localparam logic [31:0] ADDR_ERROR_STS     = 32'h0000_0814;
    localparam logic [31:0] ADDR_NOTIF_STS     = 32'h0000_0818;

    // Clock & resets
    logic clk = 1'b0;
    always #5 clk = ~clk;

    logic reset_n;
    logic cptra_pwrgood;

    // DUT inputs/outputs
    logic [255:0]       cptra_obf_key;
    logic [7:0][31:0]   obf_field_entropy;
    logic [15:0][31:0]  obf_uds_seed;
    logic [7:0][31:0]   obf_hek_seed;

    logic [AHB_ADDR_WIDTH-1:0] haddr_i;
    logic [AHB_DATA_WIDTH-1:0] hwdata_i;
    logic                      hsel_i;
    logic                      hwrite_i;
    logic                      hready_i;
    logic [1:0]                htrans_i;
    logic [2:0]                hsize_i;

    logic                      hresp_o;
    logic                      hreadyout_o;
    logic [AHB_DATA_WIDTH-1:0] hrdata_o;

    kv_write_t   kv_write;
    kv_wr_resp_t kv_wr_resp;

    logic clear_obf_secrets;
    logic busy_o;
    logic error_intr;
    logic notif_intr;
    logic doe_fsm_error;
    logic ocp_lock_en;
    logic doe_cmd_lock;
    logic debugUnlock_or_scan_mode_switch;

    doe_ctrl #(
        .AHB_DATA_WIDTH(AHB_DATA_WIDTH),
        .AHB_ADDR_WIDTH(AHB_ADDR_WIDTH)
    ) dut (
        .clk                            (clk),
        .reset_n                        (reset_n),
        .cptra_pwrgood                  (cptra_pwrgood),
        .cptra_obf_key                  (cptra_obf_key),
        .obf_field_entropy              (obf_field_entropy),
        .obf_uds_seed                   (obf_uds_seed),
        .obf_hek_seed                   (obf_hek_seed),
        .haddr_i                        (haddr_i),
        .hwdata_i                       (hwdata_i),
        .hsel_i                         (hsel_i),
        .hwrite_i                       (hwrite_i),
        .hready_i                       (hready_i),
        .htrans_i                       (htrans_i),
        .hsize_i                        (hsize_i),
        .hresp_o                        (hresp_o),
        .hreadyout_o                    (hreadyout_o),
        .hrdata_o                       (hrdata_o),
        .kv_write                       (kv_write),
        .kv_wr_resp                     (kv_wr_resp),
        .clear_obf_secrets              (clear_obf_secrets),
        .busy_o                         (busy_o),
        .error_intr                     (error_intr),
        .notif_intr                     (notif_intr),
        .doe_fsm_error                  (doe_fsm_error),
        .ocp_lock_en                    (ocp_lock_en),
        .doe_cmd_lock                   (doe_cmd_lock),
        .debugUnlock_or_scan_mode_switch(debugUnlock_or_scan_mode_switch)
    );

    bind doe_key_mem doe_key_obs u_key_obs (
        .clk      (clk),
        .zeroize  (zeroize),
        .round_key(round_key),
        .sboxw    (sboxw),
        .ready    (ready)
    );

    bind doe_cbc doe_cbc_obs u_cbc_obs (
        .clk     (clk),
        .doe_init(doe_init),
        .zeroize (zeroize)
    );

    // Standalone port-level doe_key_mem unit under test for round-key 0..15 & zeroize verification
    logic         km_zeroize   = 1'b0;
    logic [255:0] km_key       = '0;
    logic         km_keylen    = 1'b1;
    logic         km_init_cmd  = 1'b0;
    logic [3:0]   km_round     = 4'd0;
    logic [127:0] km_round_key;
    logic         km_ready;
    logic [31:0]  km_sboxw, km_new_sboxw;

    doe_sbox u_km_sbox (
        .sboxw    (km_sboxw),
        .new_sboxw(km_new_sboxw)
    );

    doe_key_mem u_km_unit (
        .clk      (clk),
        .reset_n  (reset_n),
        .zeroize  (km_zeroize),
        .key      (km_key),
        .keylen   (km_keylen),
        .init_cmd (km_init_cmd),
        .round    (km_round),
        .round_key(km_round_key),
        .ready    (km_ready),
        .sboxw    (km_sboxw),
        .new_sboxw(km_new_sboxw)
    );

    // Scoreboard / KV capture array
    int unsigned seed = 101;
    int unsigned checks = 0;
    int unsigned failures = 0;

    logic [23:0][15:0][31:0] kv_captured_data;
    logic [23:0][8:0]        kv_captured_dest_valid;
    int unsigned             kv_write_beat_count;
    int unsigned             doe_init_pulse_count;
    logic [4:0]              err_inject_beat;
    logic                    err_inject_enable;

    task automatic check_cond(input bit cond, input string msg);
        checks++;
        if (!cond) begin
            failures++;
            if (failures <= 40) begin
                $display("[FAIL] @%0t: %s", $time, msg);
            end
        end
    endtask

    // Monitor kv_write & doe_init pulses on every clock edge
    always_ff @(posedge clk) begin
        if (reset_n && cptra_pwrgood) begin
            if (dut.doe_inst.u_cbc_obs.doe_init) begin
                doe_init_pulse_count <= doe_init_pulse_count + 1;
            end
            if (kv_write.write_en) begin
                kv_write_beat_count <= kv_write_beat_count + 1;
                if (!kv_wr_resp.error && (kv_write.write_entry < 5'd24)) begin
                    kv_captured_data[kv_write.write_entry][kv_write.write_offset] <= kv_write.write_data;
                    kv_captured_dest_valid[kv_write.write_entry] <= kv_write.write_dest_valid;
                end
            end
        end
    end

    always_comb begin
        kv_wr_resp.error = err_inject_enable && kv_write.write_en && (kv_write.write_offset == err_inject_beat[3:0]);
    end

    // Continuous combinational zero-leakage check during zeroize
    always @(posedge clk) begin
        #1;
        if (reset_n && dut.doe_inst.u_cbc_obs.zeroize) begin
            check_cond(dut.doe_inst.i_doe_core_cbc.keymem.u_key_obs.round_key === 128'h0,
                       "Combinational round_key leaked non-zero value while zeroize=1");
            check_cond(dut.doe_inst.i_doe_core_cbc.keymem.u_key_obs.sboxw === 32'h0,
                       "Combinational sboxw leaked non-zero value while zeroize=1");
            check_cond(kv_write.write_en === 1'b0,
                       "kv_write.write_en asserted while zeroize=1");
        end
    end

    // AHB-Lite helper tasks
    task automatic ahb_idle();
        haddr_i  = '0;
        hwdata_i = '0;
        hsel_i   = 1'b0;
        hwrite_i = 1'b0;
        hready_i = 1'b1;
        htrans_i = 2'b00;
        hsize_i  = 3'b010;
    endtask

    task automatic ahb_write(input logic [31:0] addr, input logic [31:0] wdata);
        @(negedge clk);
        haddr_i  = addr;
        hsel_i   = 1'b1;
        hwrite_i = 1'b1;
        hready_i = 1'b1;
        htrans_i = 2'b10; // NONSEQ
        hsize_i  = 3'b010;
        @(posedge clk);
        @(negedge clk);
        hwdata_i = wdata;
        haddr_i  = '0;
        hsel_i   = 1'b0;
        hwrite_i = 1'b0;
        htrans_i = 2'b00;
        @(posedge clk);
        @(negedge clk);
        hwdata_i = '0;
    endtask

    task automatic ahb_read(input logic [31:0] addr, output logic [31:0] rdata);
        @(negedge clk);
        haddr_i  = addr;
        hsel_i   = 1'b1;
        hwrite_i = 1'b0;
        hready_i = 1'b1;
        htrans_i = 2'b10; // NONSEQ
        hsize_i  = 3'b010;
        @(posedge clk);
        @(negedge clk);
        haddr_i  = '0;
        hsel_i   = 1'b0;
        htrans_i = 2'b00;
        while (!hreadyout_o) begin
            @(posedge clk);
            @(negedge clk);
        end
        rdata = hrdata_o;
        @(posedge clk);
    endtask

    function automatic logic [31:0] encode_doe_ctrl(input doe_cmd_e cmd, input logic [4:0] dest);
        return {23'h0, cmd[3:2], dest, cmd[1:0]};
    endfunction

    // Pack 256-bit big-endian key into cptra_obf_key port (matching doe_cbc swizzle)
    function automatic logic [255:0] pack_obf_key(input logic [255:0] key_be);
        return {
            key_be[31:0],    key_be[63:32],   key_be[95:64],   key_be[127:96],
            key_be[159:128], key_be[191:160], key_be[223:192], key_be[255:224]
        };
    endfunction

    // Pack 128-bit big-endian ciphertext block into 4x32-bit obf_*_seed slice (matching doe_cbc block_reg swizzle)
    function automatic logic [127:0] pack_ct_block(input logic [127:0] ct_be);
        return {ct_be[31:0], ct_be[63:32], ct_be[95:64], ct_be[127:96]};
    endfunction

    task automatic program_iv(input logic [127:0] iv_be);
        ahb_write(ADDR_DOE_IV0, iv_be[127:96]);
        ahb_write(ADDR_DOE_IV1, iv_be[95:64]);
        ahb_write(ADDR_DOE_IV2, iv_be[63:32]);
        ahb_write(ADDR_DOE_IV3, iv_be[31:0]);
    endtask

    task automatic wait_for_valid_or_timeout(output bit timed_out, output logic [31:0] status_val, input int max_polls = 200);
        timed_out  = 1'b1;
        status_val = '0;
        for (int p = 0; p < max_polls; p++) begin
            ahb_read(ADDR_DOE_STATUS, status_val);
            if (status_val[1] && !busy_o) begin
                timed_out = 1'b0;
                return;
            end
        end
    endtask

    task automatic cold_reset_dut();
        ahb_idle();
        err_inject_enable               = 1'b0;
        err_inject_beat                 = '0;
        ocp_lock_en                     = 1'b0;
        doe_cmd_lock                    = 1'b0;
        debugUnlock_or_scan_mode_switch = 1'b0;
        kv_captured_data                = '0;
        kv_captured_dest_valid          = '0;
        kv_write_beat_count             = 0;
        doe_init_pulse_count            = 0;
        cptra_pwrgood                   = 1'b0;
        reset_n                         = 1'b0;
        repeat (4) @(posedge clk);
        cptra_pwrgood                   = 1'b1;
        repeat (2) @(posedge clk);
        reset_n                         = 1'b1;
        repeat (4) @(posedge clk);
    endtask

    task automatic warm_reset_dut();
        ahb_idle();
        reset_n = 1'b0;
        repeat (4) @(posedge clk);
        reset_n = 1'b1;
        repeat (4) @(posedge clk);
    endtask

    // Pure SystemVerilog AES-256 ECB encrypt helper (used to build randomized CBC ciphertexts from arbitrary keys/IVs/plaintexts!)
    localparam byte AES_SBOX [0:255] = '{
        8'h63,8'h7c,8'h77,8'h7b,8'hf2,8'h6b,8'h6f,8'hc5,8'h30,8'h01,8'h67,8'h2b,8'hfe,8'hd7,8'hab,8'h76,
        8'hca,8'h82,8'hc9,8'h7d,8'hfa,8'h59,8'h47,8'hf0,8'had,8'hd4,8'ha2,8'haf,8'h9c,8'ha4,8'h72,8'hc0,
        8'hb7,8'hfd,8'h93,8'h26,8'h36,8'h3f,8'hf7,8'hcc,8'h34,8'ha5,8'he5,8'hf1,8'h71,8'hd8,8'h31,8'h15,
        8'h04,8'hc7,8'h23,8'hc3,8'h18,8'h96,8'h05,8'h9a,8'h07,8'h12,8'h80,8'he2,8'heb,8'h27,8'hb2,8'h75,
        8'h09,8'h83,8'h2c,8'h1a,8'h1b,8'h6e,8'h5a,8'ha0,8'h52,8'h3b,8'hd6,8'hb3,8'h29,8'he3,8'h2f,8'h84,
        8'h53,8'hd1,8'h00,8'hed,8'h20,8'hfc,8'hb1,8'h5b,8'h6a,8'hcb,8'hbe,8'h39,8'h4a,8'h4c,8'h58,8'hcf,
        8'hd0,8'hef,8'haa,8'hfb,8'h43,8'h4d,8'h33,8'h85,8'h45,8'hf9,8'h02,8'h7f,8'h50,8'h3c,8'h9f,8'ha8,
        8'h51,8'ha3,8'h40,8'h8f,8'h92,8'h9d,8'h38,8'hf5,8'hbc,8'hb6,8'hda,8'h21,8'h10,8'hff,8'hf3,8'hd2,
        8'hcd,8'h0c,8'h13,8'hec,8'h5f,8'h97,8'h44,8'h17,8'hc4,8'ha7,8'h7e,8'h3d,8'h64,8'h5d,8'h19,8'h73,
        8'h60,8'h81,8'h4f,8'hdc,8'h22,8'h2a,8'h90,8'h88,8'h46,8'hee,8'hb8,8'h14,8'hde,8'h5e,8'h0b,8'hdb,
        8'he0,8'h32,8'h3a,8'h0a,8'h49,8'h06,8'h24,8'h5c,8'hc2,8'hd3,8'hac,8'h62,8'h91,8'h95,8'he4,8'h79,
        8'he7,8'hc8,8'h37,8'h6d,8'h8d,8'hd5,8'h4e,8'ha9,8'h6c,8'h56,8'hf4,8'hea,8'h65,8'h7a,8'hae,8'h08,
        8'hba,8'h78,8'h25,8'h2e,8'h1c,8'ha6,8'hb4,8'hc6,8'he8,8'hdd,8'h74,8'h1f,8'h4b,8'hbd,8'h8b,8'h8a,
        8'h70,8'h3e,8'hb5,8'h66,8'h48,8'h03,8'hf6,8'h0e,8'h61,8'h35,8'h57,8'hb9,8'h86,8'hc1,8'h1d,8'h9e,
        8'he1,8'hf8,8'h98,8'h11,8'h69,8'hd9,8'h8e,8'h94,8'h9b,8'h1e,8'h87,8'he9,8'hce,8'h55,8'h28,8'hdf,
        8'h8c,8'ha1,8'h89,8'h0d,8'hbf,8'he6,8'h42,8'h68,8'h41,8'h99,8'h2d,8'h0f,8'hb0,8'h54,8'hbb,8'h16
    };

    function automatic byte xtime(input byte b);
        return {b[6:0], 1'b0} ^ (b[7] ? 8'h1b : 8'h00);
    endfunction

    function automatic logic [31:0] sub_word(input logic [31:0] w);
        return {AES_SBOX[w[31:24]], AES_SBOX[w[23:16]], AES_SBOX[w[15:8]], AES_SBOX[w[7:0]]};
    endfunction

    function automatic logic [127:0] aes256_encrypt_block(input logic [255:0] key_be, input logic [127:0] pt_be);
        logic [31:0] w [0:59];
        byte         st [0:15];
        byte         tmp [0:15];
        byte         rc;
        logic [127:0] rk;

        for (int i = 0; i < 8; i++) begin
            w[i] = key_be[255 - 32*i -: 32];
        end
        rc = 8'h01;
        for (int i = 8; i < 60; i++) begin
            logic [31:0] t;
            t = w[i-1];
            if ((i % 8) == 0) begin
                t = sub_word({t[23:0], t[31:24]}) ^ {rc, 24'h0};
                rc = xtime(rc);
            end else if ((i % 8) == 4) begin
                t = sub_word(t);
            end
            w[i] = w[i-8] ^ t;
        end

        rk = {w[0], w[1], w[2], w[3]} ^ pt_be;
        for (int b = 0; b < 16; b++) st[b] = rk[127 - 8*b -: 8];

        for (int r = 1; r <= 14; r++) begin
            // SubBytes
            for (int b = 0; b < 16; b++) tmp[b] = AES_SBOX[st[b]];
            // ShiftRows
            st[0]  = tmp[0];  st[1]  = tmp[5];  st[2]  = tmp[10]; st[3]  = tmp[15];
            st[4]  = tmp[4];  st[5]  = tmp[9];  st[6]  = tmp[14]; st[7]  = tmp[3];
            st[8]  = tmp[8];  st[9]  = tmp[13]; st[10] = tmp[2];  st[11] = tmp[7];
            st[12] = tmp[12]; st[13] = tmp[1];  st[14] = tmp[6];  st[15] = tmp[11];
            // MixColumns
            if (r < 14) begin
                for (int c = 0; c < 4; c++) begin
                    byte a0, a1, a2, a3, s;
                    a0 = st[4*c+0]; a1 = st[4*c+1]; a2 = st[4*c+2]; a3 = st[4*c+3];
                    s  = a0 ^ a1 ^ a2 ^ a3;
                    st[4*c+0] = a0 ^ s ^ xtime(a0 ^ a1);
                    st[4*c+1] = a1 ^ s ^ xtime(a1 ^ a2);
                    st[4*c+2] = a2 ^ s ^ xtime(a2 ^ a3);
                    st[4*c+3] = a3 ^ s ^ xtime(a3 ^ a0);
                end
            end
            // AddRoundKey
            rk = {w[4*r+0], w[4*r+1], w[4*r+2], w[4*r+3]};
            for (int b = 0; b < 16; b++) st[b] = st[b] ^ rk[127 - 8*b -: 8];
        end

        return {st[0],st[1],st[2],st[3],st[4],st[5],st[6],st[7],st[8],st[9],st[10],st[11],st[12],st[13],st[14],st[15]};
    endfunction

    function automatic logic [31:0] next_rng();
        seed = (seed * 32'd1664525) + 32'd1013904223;
        return seed;
    endfunction

    //--------------------------------------------------------------------------
    // Test Phases
    //--------------------------------------------------------------------------
    initial begin
        logic [255:0] nist_key;
        logic [127:0] nist_iv;
        logic [127:0] nist_pt [0:3];
        logic [127:0] nist_ct [0:3];
        logic [31:0]  sts, rd_val;
        bit           to;
        int unsigned  init_before, beats_before;

        if ($value$plusargs("seed=%d", seed)) begin
            $display("[TB] Starting Caliptra DOE Security Verification with seed=%0d", seed);
        end

        // NIST SP 800-38A Section F.2.6 AES-256-CBC Test Vectors
        nist_key   = 256'h603deb10_15ca71be_2b73aef0_857d7781_1f352c07_3b6108d7_2d9810a3_0914dff4;
        nist_iv    = 128'h00010203_04050607_08090a0b_0c0d0e0f;
        nist_pt[0] = 128'h6bc1bee2_2e409f96_e93d7e11_7393172a;
        nist_pt[1] = 128'hae2d8a57_1e03ac9c_9eb76fac_45af8e51;
        nist_pt[2] = 128'h30c81c46_a35ce411_e5fbc119_1a0a52ef;
        nist_pt[3] = 128'hf69f2445_df4f9b17_ad2b417b_e66c3710;
        nist_ct[0] = 128'hf58c4c04_d6e5f1ba_779eabfb_5f7bfbd6;
        nist_ct[1] = 128'h9cfc4e96_7edb808d_679f777b_c6702c7d;
        nist_ct[2] = 128'h39f23369_a9d9bacf_a530e263_04231461;
        nist_ct[3] = 128'hb2eb05e2_c39be9fc_da6c1907_8c6a9d1b;

        // Sanity check SV AES-256 helper against NIST F.2.6
        check_cond(aes256_encrypt_block(nist_key, nist_pt[0] ^ nist_iv) === nist_ct[0], "Internal AES-256 KAT self-check block 0");

        //======================================================================
        // T1: NIST AES-256-CBC KAT across DOE_UDS, DOE_FE, and DOE_HEK
        //======================================================================
        $display("[TB] Running T1: NIST SP 800-38A AES-256-CBC KAT (UDS, FE, HEK)...");
        cold_reset_dut();
        ocp_lock_en   = 1'b1;
        cptra_obf_key = pack_obf_key(nist_key);
        obf_uds_seed  = {pack_ct_block(nist_ct[3]), pack_ct_block(nist_ct[2]), pack_ct_block(nist_ct[1]), pack_ct_block(nist_ct[0])};
        obf_field_entropy = {pack_ct_block(nist_ct[1]), pack_ct_block(nist_ct[0])};
        obf_hek_seed      = {pack_ct_block(nist_ct[3]), pack_ct_block(nist_ct[2])};

        // Check sparse FSM state register width >= 10
        check_cond($bits(dut.doe_inst.doe_fsm1.kv_doe_fsm_ps) >= 10,
                   "kv_doe_fsm_ps width must be >= 10 bits for sparse Hamming-distance encoding");

        // 1) DOE_UDS -> Slot 3 (Standard)
        program_iv(nist_iv);
        ahb_write(ADDR_DOE_CTRL, encode_doe_ctrl(DOE_UDS, 5'd3));
        wait_for_valid_or_timeout(to, sts);
        check_cond(!to, "T1 DOE_UDS timed out");
        check_cond(sts[2] === 1'b1 && sts[8] === 1'b0, "T1 DOE_UDS expected UDS_FLOW_DONE=1, ERROR=0");
        check_cond(kv_captured_dest_valid[3] === 9'h003, "T1 DOE_UDS expected dest_valid=9'h003");
        for (int b = 0; b < 4; b++) begin
            for (int w = 0; w < 4; w++) begin
                check_cond(kv_captured_data[3][b*4 + w] === nist_pt[b][127 - 32*w -: 32],
                           $sformatf("T1 DOE_UDS dword %0d mismatch", b*4 + w));
            end
        end

        // 2) DOE_FE -> Slot 12 (Standard)
        program_iv(nist_iv);
        ahb_write(ADDR_DOE_CTRL, encode_doe_ctrl(DOE_FE, 5'd12));
        wait_for_valid_or_timeout(to, sts);
        check_cond(!to, "T1 DOE_FE timed out");
        check_cond(sts[3] === 1'b1 && sts[8] === 1'b0, "T1 DOE_FE expected FE_FLOW_DONE=1, ERROR=0");
        check_cond(kv_captured_dest_valid[12] === 9'h003, "T1 DOE_FE expected dest_valid=9'h003");
        for (int b = 0; b < 2; b++) begin
            for (int w = 0; w < 4; w++) begin
                check_cond(kv_captured_data[12][b*4 + w] === nist_pt[b][127 - 32*w -: 32],
                           $sformatf("T1 DOE_FE dword %0d mismatch", b*4 + w));
            end
        end

        // 3) DOE_HEK -> Slot 22 (OCP_LOCK_HEK_SEED_KV_SLOT) using C1 as IV for C2..C3
        program_iv(nist_ct[1]);
        ahb_write(ADDR_DOE_CTRL, encode_doe_ctrl(DOE_HEK, 5'd22));
        wait_for_valid_or_timeout(to, sts);
        check_cond(!to, "T1 DOE_HEK timed out");
        check_cond(sts[5] === 1'b1 && sts[8] === 1'b0, "T1 DOE_HEK expected HEK_FLOW_DONE=1, ERROR=0");
        check_cond(kv_captured_dest_valid[22] === 9'h002, "T1 DOE_HEK expected dest_valid=OCP_LOCK_HEK_SEED_DEST_VALID (9'h002)");
        for (int b = 0; b < 2; b++) begin
            for (int w = 0; w < 4; w++) begin
                check_cond(kv_captured_data[22][b*4 + w] === nist_pt[b+2][127 - 32*w -: 32],
                           $sformatf("T1 DOE_HEK dword %0d mismatch", b*4 + w));
            end
        end

        //======================================================================
        // T2: Sticky Flow Locks, Warm vs Cold Reset, Slot/Strap Rules, & Invalid Cmds
        //======================================================================
        $display("[TB] Running T2: Sticky Flow Locks, Warm Reset Persistence, & Command Filtering...");
        // Re-attempt locked UDS, FE, HEK before and after warm reset!
        for (int pass = 0; pass < 2; pass++) begin
            if (pass == 1) begin
                warm_reset_dut();
                ahb_read(ADDR_DOE_STATUS, sts);
                check_cond(sts[2] === 1'b1 && sts[3] === 1'b1 && sts[5] === 1'b1,
                           "T2 sticky UDS/FE/HEK locks must survive warm reset_n");
            end

            init_before  = doe_init_pulse_count;
            beats_before = kv_write_beat_count;

            ahb_write(ADDR_DOE_CTRL, encode_doe_ctrl(DOE_UDS, 5'd1));
            wait_for_valid_or_timeout(to, sts, 20);
            check_cond(!to && sts[8] === 1'b1, "T2 locked DOE_UDS must complete immediately with ERROR=1");

            ahb_write(ADDR_DOE_CTRL, encode_doe_ctrl(DOE_FE, 5'd2));
            wait_for_valid_or_timeout(to, sts, 20);
            check_cond(!to && sts[8] === 1'b1, "T2 locked DOE_FE must complete immediately with ERROR=1");

            ahb_write(ADDR_DOE_CTRL, encode_doe_ctrl(DOE_HEK, 5'd22));
            wait_for_valid_or_timeout(to, sts, 20);
            check_cond(!to && sts[8] === 1'b1, "T2 locked DOE_HEK must complete immediately with ERROR=1");

            check_cond(doe_init_pulse_count == init_before,
                       "T2 locked flow re-attempt must NOT trigger doe_init key expansion");
            check_cond(kv_write_beat_count == beats_before,
                       "T2 locked flow re-attempt must NOT assert kv_write.write_en");
        end

        // Cold reset clears sticky locks
        cold_reset_dut();
        cptra_obf_key     = pack_obf_key(nist_key);
        obf_uds_seed      = {pack_ct_block(nist_ct[3]), pack_ct_block(nist_ct[2]), pack_ct_block(nist_ct[1]), pack_ct_block(nist_ct[0])};
        obf_field_entropy = {pack_ct_block(nist_ct[1]), pack_ct_block(nist_ct[0])};
        obf_hek_seed      = {pack_ct_block(nist_ct[3]), pack_ct_block(nist_ct[2])};

        ahb_read(ADDR_DOE_STATUS, sts);
        check_cond(sts[2] === 1'b0 && sts[3] === 1'b0 && sts[5] === 1'b0,
                   "T2 cold reset (~cptra_pwrgood) must clear sticky flow locks");

        // Test unauthorized slot / ocp_lock_en combinations (must NOT set sticky locks or pulse doe_init!)
        init_before  = doe_init_pulse_count;
        beats_before = kv_write_beat_count;

        // a) DOE_HEK when ocp_lock_en == 0 (targeting slot 22 and Standard slot 4)
        ocp_lock_en = 1'b0;
        ahb_write(ADDR_DOE_CTRL, encode_doe_ctrl(DOE_HEK, 5'd22));
        wait_for_valid_or_timeout(to, sts, 20);
        check_cond(!to && sts[8] === 1'b1 && sts[5] === 1'b0,
                   "T2 DOE_HEK with ocp_lock_en=0 (slot 22) must reject with ERROR=1 and HEK_FLOW_DONE=0");

        ahb_write(ADDR_DOE_CTRL, encode_doe_ctrl(DOE_HEK, 5'd4));
        wait_for_valid_or_timeout(to, sts, 20);
        check_cond(!to && sts[8] === 1'b1 && sts[5] === 1'b0,
                   "T2 DOE_HEK with ocp_lock_en=0 (slot 4) must reject with ERROR=1 and HEK_FLOW_DONE=0");

        // b) DOE_HEK when ocp_lock_en == 1 but wrong slots (slot 5, 16, 23, 30)
        ocp_lock_en = 1'b1;
        begin
            logic [4:0] bad_hek_slots [0:3] = '{5'd5, 5'd16, 5'd23, 5'd30};
            for (int i = 0; i < 4; i++) begin
                ahb_write(ADDR_DOE_CTRL, encode_doe_ctrl(DOE_HEK, bad_hek_slots[i]));
                wait_for_valid_or_timeout(to, sts, 20);
                check_cond(!to && sts[8] === 1'b1 && sts[5] === 1'b0,
                           $sformatf("T2 DOE_HEK to illegal slot %0d must reject without setting lock_hek_flow", bad_hek_slots[i]));
            end
        end

        // c) DOE_UDS / DOE_FE to OCP LOCK / out-of-range slots (16, 22, 23, 24, 31)
        begin
            logic [4:0] bad_std_slots [0:4] = '{5'd16, 5'd22, 5'd23, 5'd24, 5'd31};
            for (int i = 0; i < 5; i++) begin
                ahb_write(ADDR_DOE_CTRL, encode_doe_ctrl(DOE_UDS, bad_std_slots[i]));
                wait_for_valid_or_timeout(to, sts, 20);
                check_cond(!to && sts[8] === 1'b1 && sts[2] === 1'b0,
                           $sformatf("T2 DOE_UDS to non-standard slot %0d must reject", bad_std_slots[i]));

                ahb_write(ADDR_DOE_CTRL, encode_doe_ctrl(DOE_FE, bad_std_slots[i]));
                wait_for_valid_or_timeout(to, sts, 20);
                check_cond(!to && sts[8] === 1'b1 && sts[3] === 1'b0,
                           $sformatf("T2 DOE_FE to non-standard slot %0d must reject", bad_std_slots[i]));
            end
        end

        // d) All 11 reserved / invalid doe_cmd_e values (4'd5 .. 4'd15)
        for (int c = 5; c <= 15; c++) begin
            ahb_write(ADDR_DOE_CTRL, encode_doe_ctrl(doe_cmd_e'(c[3:0]), 5'd2));
            wait_for_valid_or_timeout(to, sts, 20);
            ahb_read(ADDR_DOE_CTRL, rd_val);
            check_cond(!to && sts[8] === 1'b1 && ({rd_val[8:7], rd_val[1:0]} === 4'b0000),
                       $sformatf("T2 invalid cmd %0d must clear CMD/CMD_EXT and assert ERROR=1 without hanging", c));
        end

        check_cond(doe_init_pulse_count == init_before,
                   "T2 unauthorized/reserved commands must NEVER pulse doe_init");
        check_cond(kv_write_beat_count == beats_before,
                   "T2 unauthorized/reserved commands must NEVER assert kv_write.write_en");

        // e) KV write error (kv_wr_resp.error=1 on beat 2) aborts remaining beats and does NOT set lock_uds_flow
        program_iv(nist_iv);
        err_inject_enable = 1'b1;
        err_inject_beat   = 5'd2;
        beats_before      = kv_write_beat_count;
        ahb_write(ADDR_DOE_CTRL, encode_doe_ctrl(DOE_UDS, 5'd5));
        wait_for_valid_or_timeout(to, sts);
        err_inject_enable = 1'b0;
        check_cond(!to && sts[8] === 1'b1 && sts[2] === 1'b0,
                   "T2 kv_wr_resp.error during DOE_WRITE must assert ERROR=1 and NOT set lock_uds_flow");
        check_cond((kv_write_beat_count - beats_before) == 3,
                   "T2 kv_wr_resp.error on beat 2 must abort remaining 13 UDS beats immediately");

        //======================================================================
        // T3: In-Flight AHB CSR Write Protection & doe_cmd_lock Enforcement
        //======================================================================
        $display("[TB] Running T3: In-Flight CSR Tampering Protection & doe_cmd_lock Gating...");
        cold_reset_dut();
        ocp_lock_en   = 1'b1;
        cptra_obf_key = pack_obf_key(nist_key);
        obf_uds_seed  = {pack_ct_block(nist_ct[3]), pack_ct_block(nist_ct[2]), pack_ct_block(nist_ct[1]), pack_ct_block(nist_ct[0])};
        program_iv(nist_iv);

        // Launch DOE_UDS -> Slot 6, then immediately attempt mid-flight IV & CTRL tampering while busy_o==1
        ahb_write(ADDR_DOE_CTRL, encode_doe_ctrl(DOE_UDS, 5'd6));
        wait (busy_o === 1'b1);
        // Attempt mid-key-expansion IV overwrite and DEST/CMD overwrite
        ahb_write(ADDR_DOE_IV0, 32'hdead_beef);
        ahb_write(ADDR_DOE_IV3, 32'hbad0_cafe);
        ahb_write(ADDR_DOE_CTRL, encode_doe_ctrl(DOE_FE, 5'd11));
        repeat (16) @(posedge clk);
        // Attempt mid-CBC-decryption IV overwrite and DEST overwrite
        if (busy_o) begin
            ahb_write(ADDR_DOE_IV1, 32'h1234_5678);
            ahb_write(ADDR_DOE_CTRL, encode_doe_ctrl(DOE_UDS, 5'd14));
        end
        wait_for_valid_or_timeout(to, sts);
        check_cond(!to && sts[2] === 1'b1 && sts[8] === 1'b0,
                   "T3 DOE_UDS must complete cleanly despite mid-flight AHB tampering attempts");
        check_cond(kv_captured_dest_valid[6] === 9'h003 && kv_captured_dest_valid[11] === 9'h0 && kv_captured_dest_valid[14] === 9'h0,
                   "T3 mid-flight DEST tamper redirected KV write away from slot 6");
        for (int b = 0; b < 4; b++) begin
            for (int w = 0; w < 4; w++) begin
                check_cond(kv_captured_data[6][b*4 + w] === nist_pt[b][127 - 32*w -: 32],
                           $sformatf("T3 mid-flight IV tamper corrupted UDS dword %0d", b*4 + w));
            end
        end

        // Test doe_cmd_lock == 1 blocks DOE_IV and DOE_CTRL (including DEST and DOE_CLEAR), while allowing reads & intr CSRs
        doe_cmd_lock = 1'b1;
        ahb_read(ADDR_DOE_IV0, rd_val);
        check_cond(rd_val === nist_iv[127:96], "T3 pre-check DOE_IV0 before locked write attempt");
        ahb_write(ADDR_DOE_IV0, 32'hffff_0000);
        ahb_write(ADDR_DOE_CTRL, encode_doe_ctrl(DOE_CLEAR, 5'd15));
        ahb_write(ADDR_GLOBAL_INTR, 32'h0000_0003);
        ahb_read(ADDR_DOE_IV0, rd_val);
        check_cond(rd_val === nist_iv[127:96], "T3 doe_cmd_lock=1 must block AHB writes to DOE_IV0");
        ahb_read(ADDR_DOE_CTRL, rd_val);
        check_cond(rd_val[6:2] === 5'd6, "T3 doe_cmd_lock=1 must block AHB writes to DOE_CTRL.DEST");
        ahb_read(ADDR_GLOBAL_INTR, rd_val);
        check_cond(rd_val[1:0] === 2'b11, "T3 doe_cmd_lock=1 must still permit interrupt CSR writes");

        //======================================================================
        // T4: Mid-Unwrap DOE_CLEAR / debugUnlock Zeroization & Post-Zeroize Recovery
        //======================================================================
        $display("[TB] Running T4: Mid-Expansion & Mid-Decrypt Zeroization + Post-Clear Non-Zero Slot Recovery...");
        cold_reset_dut();
        ocp_lock_en       = 1'b1;
        cptra_obf_key     = pack_obf_key(nist_key);
        obf_uds_seed      = {pack_ct_block(nist_ct[3]), pack_ct_block(nist_ct[2]), pack_ct_block(nist_ct[1]), pack_ct_block(nist_ct[0])};
        obf_field_entropy = {pack_ct_block(nist_ct[1]), pack_ct_block(nist_ct[0])};

        // 0) Port-level doe_key_mem verification: all 15 round keys (0..14), out-of-bounds round 15,
        //    combinational masking during zeroize, and 1-cycle full wipe!
        km_key      = nist_key;
        km_keylen   = 1'b1;
        km_zeroize  = 1'b0;
        @(negedge clk);
        km_init_cmd = 1'b1;
        @(negedge clk);
        km_init_cmd = 1'b0;
        repeat (20) @(posedge clk);
        #1;
        check_cond(km_ready === 1'b1, "T4 u_km_unit ready must assert after AES-256 key expansion");
        km_round = 4'd14;
        #1;
        check_cond(km_round_key !== 128'h0, "T4 u_km_unit round 14 key must be populated");
        km_round = 4'd15;
        #1;
        check_cond(km_round_key === 128'h0, "T4 u_km_unit out-of-bounds round 15 must be masked to 0");
        km_round = 4'd14;
        #1;
        // Assert km_zeroize: combinational masking must take effect immediately BEFORE clock edge!
        km_zeroize = 1'b1;
        #1;
        check_cond(km_round_key === 128'h0 && km_sboxw === 32'h0,
                   "T4 u_km_unit combinational round_key/sboxw must mask to 0 immediately when zeroize=1");
        @(posedge clk);
        #1;
        km_zeroize = 1'b0;
        #1;
        check_cond(km_ready === 1'b0 && km_sboxw === 32'h0,
                   "T4 u_km_unit ready and sboxw must clear within 1 clock cycle of zeroize");
        for (int rk_i = 0; rk_i <= 15; rk_i++) begin
            km_round = 4'(rk_i);
            #1;
            check_cond(km_round_key === 128'h0,
                       $sformatf("T4 u_km_unit round_key[%0d] survived 1-cycle zeroize", rk_i));
        end

        // 1) Start DOE_UDS -> Slot 9, wait until upper round keys (round >= 12) are populated, then issue emergency DOE_CLEAR!
        program_iv(nist_iv);
        ahb_write(ADDR_DOE_CTRL, encode_doe_ctrl(DOE_UDS, 5'd9));
        repeat (14) @(posedge clk);
        // Issue emergency DOE_CLEAR over AHB while busy_o == 1!
        ahb_write(ADDR_DOE_CTRL, encode_doe_ctrl(DOE_CLEAR, 5'd0));
        repeat (3) @(posedge clk);
        #1;
        check_cond(dut.doe_inst.i_doe_core_cbc.keymem.u_key_obs.round_key === 128'h0 &&
                   dut.doe_inst.i_doe_core_cbc.keymem.u_key_obs.sboxw === 32'h0 &&
                   dut.doe_inst.i_doe_core_cbc.keymem.u_key_obs.ready === 1'b0,
                   "T4 emergency DOE_CLEAR left non-zero round_key/sboxw/ready in doe_key_mem");
        check_cond(busy_o === 1'b0, "T4 busy_o must return to 0 after DOE_CLEAR abort");
        ahb_read(ADDR_DOE_STATUS, sts);
        check_cond(sts[4] === 1'b1 && sts[2] === 1'b0,
                   "T4 DOE_CLEAR must set DEOBF_SECRETS_CLEARED=1 and leave UDS_FLOW_DONE=0");
        ahb_read(ADDR_DOE_IV0, rd_val);
        check_cond(rd_val === 32'h0, "T4 DOE_CLEAR must zeroize DOE_IV0");

        // 2) Immediately run valid DOE_UDS to NON-ZERO Slot 9 (verifies post-zeroize dest_addr recovery!)
        program_iv(nist_iv);
        ahb_write(ADDR_DOE_CTRL, encode_doe_ctrl(DOE_UDS, 5'd9));
        wait_for_valid_or_timeout(to, sts);
        check_cond(!to && sts[2] === 1'b1 && sts[8] === 1'b0,
                   "T4 post-DOE_CLEAR DOE_UDS recovery failed");
        check_cond(kv_captured_dest_valid[9] === 9'h003 && kv_captured_dest_valid[0] === 9'h000,
                   "T4 post-DOE_CLEAR DOE_UDS clobbered dest_addr to slot 0 instead of slot 9");
        for (int b = 0; b < 4; b++) begin
            for (int w = 0; w < 4; w++) begin
                check_cond(kv_captured_data[9][b*4 + w] === nist_pt[b][127 - 32*w -: 32],
                           $sformatf("T4 post-DOE_CLEAR UDS slot 9 dword %0d mismatch", b*4 + w));
            end
        end

        // 3) Mid-CBC-decryption debugUnlock_or_scan_mode_switch pulse during DOE_FE -> Slot 13, then recover to Slot 14
        program_iv(nist_iv);
        ahb_write(ADDR_DOE_CTRL, encode_doe_ctrl(DOE_FE, 5'd13));
        repeat (22) @(posedge clk);
        @(negedge clk);
        debugUnlock_or_scan_mode_switch = 1'b1;
        @(posedge clk);
        #1;
        check_cond(dut.doe_inst.i_doe_core_cbc.keymem.u_key_obs.round_key === 128'h0 &&
                   dut.doe_inst.i_doe_core_cbc.keymem.u_key_obs.sboxw === 32'h0 &&
                   dut.doe_inst.i_doe_core_cbc.keymem.u_key_obs.ready === 1'b0,
                   "T4 debugUnlock_or_scan_mode_switch failed to zeroize doe_key_mem within 1 cycle");
        @(negedge clk);
        debugUnlock_or_scan_mode_switch = 1'b0;
        repeat (3) @(posedge clk);

        program_iv(nist_iv);
        ahb_write(ADDR_DOE_CTRL, encode_doe_ctrl(DOE_FE, 5'd14));
        wait_for_valid_or_timeout(to, sts);
        check_cond(!to && sts[3] === 1'b1 && sts[8] === 1'b0,
                   "T4 post-debugUnlock DOE_FE recovery to slot 14 failed");
        check_cond(kv_captured_dest_valid[14] === 9'h003 && kv_captured_dest_valid[13] === 9'h000,
                   "T4 post-debugUnlock DOE_FE slot 14 dest_valid mismatch");
        for (int b = 0; b < 2; b++) begin
            for (int w = 0; w < 4; w++) begin
                check_cond(kv_captured_data[14][b*4 + w] === nist_pt[b][127 - 32*w -: 32],
                           $sformatf("T4 post-debugUnlock FE slot 14 dword %0d mismatch", b*4 + w));
            end
        end

        //======================================================================
        // T5: Multi-Seed Randomized AES-256-CBC + Policy Fuzzing
        //======================================================================
        $display("[TB] Running T5: Randomized Multi-Seed AES-256-CBC & Security Stress (seed=%0d)...", seed);
        for (int iter = 0; iter < 4; iter++) begin
            logic [255:0] r_key;
            logic [127:0] r_iv, prev_c;
            logic [127:0] r_pt [0:3];
            logic [127:0] r_ct [0:3];
            logic [4:0]   uds_slot, fe_slot;

            cold_reset_dut();
            ocp_lock_en = 1'b1;

            r_key = {next_rng(), next_rng(), next_rng(), next_rng(), next_rng(), next_rng(), next_rng(), next_rng()};
            r_iv  = {next_rng(), next_rng(), next_rng(), next_rng()};
            prev_c = r_iv;
            for (int b = 0; b < 4; b++) begin
                r_pt[b] = {next_rng(), next_rng(), next_rng(), next_rng()};
                r_ct[b] = aes256_encrypt_block(r_key, r_pt[b] ^ prev_c);
                prev_c  = r_ct[b];
            end

            uds_slot = 5'(1 + (next_rng() % 7));         // 1..7
            fe_slot  = 5'(8 + (next_rng() % 8));         // 8..15

            cptra_obf_key     = pack_obf_key(r_key);
            obf_uds_seed      = {pack_ct_block(r_ct[3]), pack_ct_block(r_ct[2]), pack_ct_block(r_ct[1]), pack_ct_block(r_ct[0])};
            obf_field_entropy = {pack_ct_block(r_ct[1]), pack_ct_block(r_ct[0])};
            obf_hek_seed      = {pack_ct_block(r_ct[3]), pack_ct_block(r_ct[2])};

            // Optional pre-flow DOE_CLEAR on odd iterations to stress post-clear recovery
            if (iter[0]) begin
                ahb_write(ADDR_DOE_CTRL, encode_doe_ctrl(DOE_CLEAR, 5'd0));
                repeat (3) @(posedge clk);
            end

            program_iv(r_iv);
            ahb_write(ADDR_DOE_CTRL, encode_doe_ctrl(DOE_UDS, uds_slot));
            wait_for_valid_or_timeout(to, sts);
            check_cond(!to && sts[2] === 1'b1 && sts[8] === 1'b0,
                       $sformatf("T5 iter %0d UDS unwrap failed", iter));
            for (int b = 0; b < 4; b++) begin
                for (int w = 0; w < 4; w++) begin
                    check_cond(kv_captured_data[uds_slot][b*4 + w] === r_pt[b][127 - 32*w -: 32],
                               $sformatf("T5 iter %0d UDS dword %0d mismatch", iter, b*4 + w));
                end
            end

            program_iv(r_iv);
            ahb_write(ADDR_DOE_CTRL, encode_doe_ctrl(DOE_FE, fe_slot));
            wait_for_valid_or_timeout(to, sts);
            check_cond(!to && sts[3] === 1'b1 && sts[8] === 1'b0,
                       $sformatf("T5 iter %0d FE unwrap failed", iter));
            for (int b = 0; b < 2; b++) begin
                for (int w = 0; w < 4; w++) begin
                    check_cond(kv_captured_data[fe_slot][b*4 + w] === r_pt[b][127 - 32*w -: 32],
                               $sformatf("T5 iter %0d FE dword %0d mismatch", iter, b*4 + w));
                end
            end

            program_iv(r_ct[1]);
            ahb_write(ADDR_DOE_CTRL, encode_doe_ctrl(DOE_HEK, 5'd22));
            wait_for_valid_or_timeout(to, sts);
            check_cond(!to && sts[5] === 1'b1 && sts[8] === 1'b0,
                       $sformatf("T5 iter %0d HEK unwrap failed", iter));
            for (int b = 0; b < 2; b++) begin
                for (int w = 0; w < 4; w++) begin
                    check_cond(kv_captured_data[22][b*4 + w] === r_pt[b+2][127 - 32*w -: 32],
                               $sformatf("T5 iter %0d HEK dword %0d mismatch", iter, b*4 + w));
                end
            end
        end

        if (failures == 0) begin
            $display("RESULT: PASS (seed=%0d, checks=%0d)", seed, checks);
            $finish;
        end else begin
            $display("RESULT: FAIL (seed=%0d, failures=%0d, checks=%0d)", seed, failures, checks);
            $fatal(1, "Caliptra DOE RTL security verification failed");
        end
    end

    // Global watchdog
    initial begin
        #5_000_000;
        $display("RESULT: FAIL (seed=%0d, watchdog_timeout)", seed);
        $fatal(1, "Watchdog timeout");
    end

endmodule
