// SPDX-License-Identifier: Apache-2.0
// Cycle-accurate simulation models & dual-mode HMAC-DRBG wrapper for case_25004 private grading

package sim_ctrl_pkg;
    // Controllable DRBG harness configuration (per instance ID: 0 = unit u_drbg_if, 1 = ecc_top)
    bit         drbg_mock_en       [0:1];
    bit         drbg_hold_not_rdy  [0:1];
    int         drbg_stall_cycles  [0:1];
    int         drbg_zero_low192_n [0:1]; // number of next_cmd calls to return [191:0]==0
    bit         drbg_force_zero_rnd[0:1]; // force persistent [191:0]==0 for ctrl defense-in-depth test
    logic [383:0] drbg_fixed_keygen[0:1];
    logic [383:0] drbg_fixed_sign  [0:1];

    // Observed DRBG boundary signals
    int           drbg_cmd_round   [0:1];
    logic [383:0] obs_idle_entropy [0:1];
    logic [383:0] obs_idle_nonce   [0:1];
    logic [383:0] obs_lfsr_entropy [0:1];
    logic [383:0] obs_lfsr_nonce   [0:1];
    int           obs_init_cnt     [0:1];
    int           obs_next_cnt     [0:1];

    // Controllable ecc_arith_unit results & latency
    int           pm_latency_cycles = 10;
    logic [383:0] cfg_kg_qx;
    logic [383:0] cfg_kg_qy;
    logic [383:0] cfg_sgn_r;
    logic [383:0] cfg_sgn_s;
    logic [383:0] cfg_pk_chk_val;
    logic [383:0] cfg_ver_u1;
    logic [383:0] cfg_ver_u2;
    logic [383:0] cfg_ver_rx;
    logic [383:0] cfg_dh_shared;

    // Observed ecc_arith_unit boundary captures
    logic [575:0] obs_pm_secret_key;
    logic [383:0] obs_pm_privkey;
    logic [383:0] obs_pm_msg;
    logic [383:0] obs_pm_lambda;
    logic [383:0] obs_pm_masking;
    int           obs_pm_cmd_cnt;
    int           obs_wr_scalar_cnt;
endpackage


module hmac_drbg #(
    parameter                  REG_SIZE        = 384,
    parameter [REG_SIZE-1 : 0] HMAC_DRBG_PRIME = 384'hffffffffffffffffffffffffffffffffffffffffffffffffc7634d81f4372ddf581a0db248b0a77aecec196accc52973
)(
    input  wire                 clk,
    input  wire                 reset_n,
    input  wire                 zeroize,
    input  wire                 init_cmd,
    input  wire                 next_cmd,
    output logic                ready,
    output logic                valid,
    input  wire [147:0]         lfsr_seed,
    input  wire [REG_SIZE-1:0]  entropy,
    input  wire [REG_SIZE-1:0]  nonce,
    output logic [REG_SIZE-1:0] drbg
);
    import sim_ctrl_pkg::*;

    int inst_id;
    initial begin
        string path;
        path = $sformatf("%m");
        if (path.len() >= 10 && path.substr(0, 9) == "tb.u_drbg_")
            inst_id = 0;
        else
            inst_id = 1;
    end

    logic                real_ready, real_valid;
    logic [REG_SIZE-1:0] real_drbg;

    real_hmac_drbg_core #(
        .REG_SIZE(REG_SIZE),
        .HMAC_DRBG_PRIME(HMAC_DRBG_PRIME)
    ) u_real (
        .clk(clk),
        .reset_n(reset_n),
        .zeroize(zeroize),
        .init_cmd(drbg_mock_en[inst_id] ? 1'b0 : init_cmd),
        .next_cmd(drbg_mock_en[inst_id] ? 1'b0 : next_cmd),
        .ready(real_ready),
        .valid(real_valid),
        .lfsr_seed(lfsr_seed),
        .entropy(entropy),
        .nonce(nonce),
        .drbg(real_drbg)
    );

    typedef enum logic [1:0] {
        MK_IDLE  = 2'd0,
        MK_BUSY  = 2'd1,
        MK_STALL = 2'd2
    } mk_st_e;

    mk_st_e              mk_st;
    int                  mk_cnt;
    logic [REG_SIZE-1:0] mk_drbg;
    logic                mk_valid;
    logic                mk_ready;

    always_comb begin
        mk_ready = (mk_st == MK_IDLE) && !drbg_hold_not_rdy[inst_id];
    end

    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            mk_st     <= MK_IDLE;
            mk_cnt    <= 0;
            mk_drbg   <= '0;
            mk_valid  <= 1'b0;
            drbg_cmd_round[inst_id] <= 0;
            obs_init_cnt[inst_id]   <= 0;
            obs_next_cnt[inst_id]   <= 0;
        end else if (zeroize) begin
            mk_st     <= MK_STALL;
            mk_cnt    <= 1;
            mk_drbg   <= '0;
            mk_valid  <= 1'b0;
            drbg_cmd_round[inst_id] <= 0;
        end else begin
            obs_idle_entropy[inst_id] <= entropy;
            obs_idle_nonce[inst_id]   <= nonce;

            if (!drbg_mock_en[inst_id]) begin
                if (init_cmd && real_ready) begin
                    obs_init_cnt[inst_id] <= obs_init_cnt[inst_id] + 1;
                    if (drbg_cmd_round[inst_id] == 0) begin
                        obs_lfsr_entropy[inst_id] <= entropy;
                        obs_lfsr_nonce[inst_id]   <= nonce;
                    end
                    drbg_cmd_round[inst_id] <= drbg_cmd_round[inst_id] + 1;
                end else if (next_cmd && real_ready) begin
                    obs_next_cnt[inst_id]   <= obs_next_cnt[inst_id] + 1;
                    drbg_cmd_round[inst_id] <= drbg_cmd_round[inst_id] + 1;
                end
            end else begin
                unique case (mk_st)
                    MK_IDLE: begin
                        if (!drbg_hold_not_rdy[inst_id] && (init_cmd || next_cmd)) begin
                            mk_valid <= 1'b0;
                            if (init_cmd) begin
                                obs_init_cnt[inst_id] <= obs_init_cnt[inst_id] + 1;
                                if (drbg_cmd_round[inst_id] == 0) begin
                                    obs_lfsr_entropy[inst_id] <= entropy;
                                    obs_lfsr_nonce[inst_id]   <= nonce;
                                end
                            end else begin
                                obs_next_cnt[inst_id] <= obs_next_cnt[inst_id] + 1;
                            end
                            mk_cnt <= 3;
                            mk_st  <= MK_BUSY;

                            // Synthesize deterministic valid P-384 output in (0, GROUP_ORDER)
                            if (init_cmd && drbg_cmd_round[inst_id] == 0) begin
                                drbg_cmd_round[inst_id] <= drbg_cmd_round[inst_id] + 1;
                                mk_drbg <= (entropy ^ nonce ^ 384'h11223344_55667788_99AABBCC_DDEEFF00_13579BDF_2468ACE0_CAFEBABE_01020304_55AA55AA_12345678_87654321_0F0E0D0C) & {1'b0, {383{1'b1}}};
                                if (((entropy ^ nonce) & {1'b0, {383{1'b1}}}) == '0)
                                    mk_drbg <= 384'h22334455_66778899_AABBCCDD_EEFF0011_22334455_66778899_AABBCCDD_EEFF0011_22334455_66778899_AABBCCDD_EEFF0011;
                            end else if (next_cmd && drbg_cmd_round[inst_id] == 2 && (drbg_force_zero_rnd[inst_id] || drbg_zero_low192_n[inst_id] > 0)) begin
                                mk_drbg <= {192'h01234567_89ABCDEF_FEDCBA98_76543210_13579BDF_2468ACE0, 192'd0};
                                if (drbg_zero_low192_n[inst_id] > 0)
                                    drbg_zero_low192_n[inst_id] <= drbg_zero_low192_n[inst_id] - 1;
                                if (drbg_force_zero_rnd[inst_id])
                                    drbg_cmd_round[inst_id] <= drbg_cmd_round[inst_id] + 1;
                            end else if (init_cmd && drbg_cmd_round[inst_id] >= 3) begin
                                drbg_cmd_round[inst_id] <= drbg_cmd_round[inst_id] + 1;
                                if (drbg_fixed_keygen[inst_id] != '0)
                                    mk_drbg <= drbg_fixed_keygen[inst_id];
                                else if (drbg_fixed_sign[inst_id] != '0)
                                    mk_drbg <= drbg_fixed_sign[inst_id];
                                else
                                    mk_drbg <= ({1'b0, entropy[382:0]} ^ {1'b0, nonce[382:0]} ^ 384'h33445566_778899AA_BBCCDDEE_FF001122_33445566_778899AA_BBCCDDEE_FF001122_33445566_778899AA_BBCCDDEE_FF001123) | 384'd1;
                            end else begin
                                drbg_cmd_round[inst_id] <= drbg_cmd_round[inst_id] + 1;
                                mk_drbg <= ({1'b0, entropy[382:0]} ^ 384'(drbg_cmd_round[inst_id] * 32'h0101_0103 + 32'h5A5A_A5A5) ^ 384'h0A0B0C0D_1A1B1C1D_2A2B2C2D_3A3B3C3D_4A4B4C4D_5A5B5C5D_6A6B6C6D_7A7B7C7D_8A8B8C8D_9A9B9C9D_AAABACAD_BABBBCBD) | 384'd5;
                            end
                        end
                    end
                    MK_BUSY: begin
                        if (mk_cnt > 1) begin
                            mk_cnt <= mk_cnt - 1;
                        end else begin
                            mk_valid <= 1'b1;
                            if (drbg_stall_cycles[inst_id] > 0) begin
                                mk_cnt <= drbg_stall_cycles[inst_id];
                                mk_st  <= MK_STALL;
                            end else begin
                                mk_st <= MK_IDLE;
                            end
                        end
                    end
                    MK_STALL: begin
                        if (mk_cnt > 1)
                            mk_cnt <= mk_cnt - 1;
                        else
                            mk_st <= MK_IDLE;
                    end
                    default: mk_st <= MK_IDLE;
                endcase
            end
        end
    end

    assign ready = drbg_mock_en[inst_id] ? mk_ready : real_ready;
    assign valid = drbg_mock_en[inst_id] ? mk_valid : real_valid;
    assign drbg  = drbg_mock_en[inst_id] ? mk_drbg  : real_drbg;
endmodule


module ecc_arith_unit
    import ecc_pm_uop_pkg::*;
    import sim_ctrl_pkg::*;
#(
    parameter                  REG_SIZE     = 384,
    parameter                  RND_SIZE     = 192,
    parameter                  RADIX        = 32,
    parameter                  ADDR_WIDTH   = 6,
    parameter [REG_SIZE-1 : 0] p_prime      = 384'hfffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffeffffffff0000000000000000ffffffff,
    parameter [RADIX-1    : 0] p_mu         = 32'h00000001,
    parameter [REG_SIZE-1 : 0] q_grouporder = 384'hffffffffffffffffffffffffffffffffffffffffffffffffc7634d81f4372ddf581a0db248b0a77aecec196accc52973,
    parameter [RADIX-1    : 0] q_mu         = 32'he88fdc45
)(
    input  wire                             clk,
    input  wire                             reset_n,
    input  wire                             zeroize,
    input  wire [3 : 0]                     ecc_cmd_i,
    input  wire [ADDR_WIDTH-1 : 0]          addr_i,
    input  wire                             wr_op_sel_i,
    input  wire                             wr_en_i,
    input  wire                             rd_reg_i,
    input  wire [(REG_SIZE+RND_SIZE)-1 : 0] data_i,
    output wire [REG_SIZE-1: 0]             data_o,
    output wire                             busy_o
);
    localparam int MEM_DEPTH = 1 << OPR_ADDR_WIDTH;

    logic [REG_SIZE-1:0]            mem [0:MEM_DEPTH-1];
    logic [REG_SIZE-1:0]            doutb;
    logic [REG_SIZE-1:0]            reg_dinb_r;
    logic [OPR_ADDR_WIDTH-1:0]      reg_addr_r;
    logic                           reg_web_r;
    logic [(REG_SIZE+RND_SIZE)-1:0] secret_key;
    logic [REG_SIZE-1:0]            d_o;
    logic                           ecc_busy_s;
    int                             busy_cnt;
    logic [3:0]                     active_cmd;

    assign ecc_busy_s = (busy_cnt > 0);
    assign busy_o     = ecc_busy_s;
    assign data_o     = d_o;

    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            doutb             <= '0;
            reg_dinb_r        <= '0;
            reg_addr_r        <= '0;
            reg_web_r         <= 1'b0;
            secret_key        <= '0;
            d_o               <= '0;
            busy_cnt          <= 0;
            active_cmd        <= '0;
            obs_pm_cmd_cnt    <= 0;
            obs_wr_scalar_cnt <= 0;
            for (int idx = 0; idx < MEM_DEPTH; idx++) mem[idx] <= '0;
        end else if (zeroize) begin
            doutb      <= '0;
            reg_dinb_r <= '0;
            reg_addr_r <= '0;
            reg_web_r  <= 1'b0;
            secret_key <= '0;
            d_o        <= '0;
            busy_cnt   <= 0;
            active_cmd <= '0;
            for (int idx = 0; idx < MEM_DEPTH; idx++) mem[idx] <= '0;
        end else begin
            // Exact 4-cycle memory read/write pipeline matching upstream ecc_arith_unit + ecc_ram_tdp_file
            if (wr_en_i) begin
                if (wr_op_sel_i == 1'b0) begin
                    reg_dinb_r <= data_i[REG_SIZE-1:0];
                end else begin
                    secret_key        <= data_i;
                    obs_wr_scalar_cnt <= obs_wr_scalar_cnt + 1;
                end
            end

            reg_addr_r <= addr_i;
            if (wr_op_sel_i == 1'b0)
                reg_web_r <= wr_en_i;
            else
                reg_web_r <= 1'b0;

            if (!ecc_busy_s && reg_web_r)
                mem[reg_addr_r] <= reg_dinb_r;

            doutb <= mem[reg_addr_r];

            if (rd_reg_i)
                d_o <= doutb;
            else
                d_o <= '0;

            // PM command execution model
            if (!ecc_busy_s && (ecc_cmd_i != 4'b0000)) begin
                active_cmd        <= ecc_cmd_i;
                busy_cnt          <= (pm_latency_cycles > 2) ? pm_latency_cycles : 4;
                obs_pm_secret_key <= secret_key;
                obs_pm_privkey    <= mem[UOP_OPR_PRIVKEY];
                obs_pm_msg        <= mem[UOP_OPR_HASH_MSG];
                obs_pm_lambda     <= mem[UOP_OPR_LAMBDA];
                obs_pm_masking    <= mem[UOP_OPR_MASKING];
                obs_pm_cmd_cnt    <= obs_pm_cmd_cnt + 1;
            end else if (busy_cnt > 0) begin
                if (busy_cnt == 1) begin
                    unique case (active_cmd)
                        KEYGEN_CMD: begin
                            mem[UOP_OPR_Qx_AFFN] <= cfg_kg_qx;
                            mem[UOP_OPR_Qy_AFFN] <= cfg_kg_qy;
                        end
                        SIGN_CMD: begin
                            mem[UOP_OPR_SIGN_R] <= cfg_sgn_r;
                            mem[UOP_OPR_SIGN_S] <= cfg_sgn_s;
                        end
                        CHK_PK_CMD: begin
                            mem[UOP_OPR_PK_VALID] <= cfg_pk_chk_val;
                        end
                        VER_PART0_CMD: begin
                            mem[UOP_OPR_SCALAR_G]  <= cfg_ver_u1;
                            mem[UOP_OPR_SCALAR_PK] <= cfg_ver_u2;
                        end
                        VER_PART2_CMD: begin
                            mem[UOP_OPR_Qx_AFFN] <= cfg_ver_rx;
                        end
                        DH_SHARED_CMD: begin
                            mem[UOP_OPR_Qx_AFFN] <= cfg_dh_shared;
                        end
                        default: ;
                    endcase
                end
                busy_cnt <= busy_cnt - 1;
            end
        end
    end
endmodule
