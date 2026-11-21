// SPDX-License-Identifier: Apache-2.0
// Alternate implementation of ecc_hmac_drbg_interface with explicit ISSUE/WAIT split phase FSM
module ecc_hmac_drbg_interface#(
    parameter                  REG_SIZE       = 384,
    parameter [REG_SIZE-1 : 0] GROUP_ORDER    = 384'hffffffffffffffffffffffffffffffffffffffffffffffffc7634d81f4372ddf581a0db248b0a77aecec196accc52973
)(
    input  wire                     clk,
    input  wire                     reset_n,
    input  wire                     zeroize,
    input  wire  [1 : 0]            hmac_mode,
    input  wire                     en,
    output wire                     ready,
    input  wire  [REG_SIZE-1 : 0]   keygen_seed,
    input  wire  [REG_SIZE-1 : 0]   keygen_nonce,
    input  wire  [REG_SIZE-1 : 0]   privKey,
    input  wire  [REG_SIZE-1 : 0]   hashed_msg,
    input  wire  [REG_SIZE-1 : 0]   IV,
    output wire  [REG_SIZE-1 : 0]   lambda,
    output wire  [REG_SIZE-1 : 0]   scalar_rnd,
    output wire  [REG_SIZE-1 : 0]   masking_rnd,
    output wire  [REG_SIZE-1 : 0]   drbg
);
    import hmac_param_pkg::*;

    localparam [1:0] MODE_KEYGEN = 2'b00;
    localparam [1:0] MODE_SIGN   = 2'b01;

    typedef enum logic [3:0] {
        PH_IDLE         = 4'd0,
        PH_ISS_LFSR     = 4'd1,
        PH_WAIT_LFSR    = 4'd2,
        PH_ISS_LAMBDA   = 4'd3,
        PH_WAIT_LAMBDA  = 4'd4,
        PH_ISS_SCALAR   = 4'd5,
        PH_WAIT_SCALAR  = 4'd6,
        PH_ISS_MASK     = 4'd7,
        PH_WAIT_MASK    = 4'd8,
        PH_ISS_KEYGEN   = 4'd9,
        PH_WAIT_KEYGEN  = 4'd10,
        PH_ISS_SIGN     = 4'd11,
        PH_WAIT_SIGN    = 4'd12,
        PH_DONE         = 4'd13
    } drbg_phase_e;

    drbg_phase_e                   ph_q, ph_d;
    logic [REG_SIZE-1:0]           lfsr_seed_q;
    logic [LFSR_SEED_SIZE-1:0]     lfsr_bus;
    logic                          core_init, core_next, core_ready, core_valid;
    logic                          core_valid_q, valid_rise;
    logic [REG_SIZE-1:0]           core_entropy, core_nonce, core_out;
    logic [REG_SIZE-1:0]           lambda_q, scalar_rnd_q, masking_rnd_q, drbg_q;
    logic [63:0]                   cnt_q;
    logic [REG_SIZE-1:0]           cnt_nonce_w, cnt_nonce_q;
    logic [REG_SIZE-1:0]           sca_ent_w, sca_ent_q;
    logic                          launch_ok;

    hmac_drbg #(
        .REG_SIZE(REG_SIZE),
        .HMAC_DRBG_PRIME(GROUP_ORDER)
    ) hmac_drbg_i (
        .clk(clk),
        .reset_n(reset_n),
        .zeroize(zeroize),
        .init_cmd(core_init),
        .next_cmd(core_next),
        .ready(core_ready),
        .valid(core_valid),
        .lfsr_seed(lfsr_bus),
        .entropy(core_entropy),
        .nonce(core_nonce),
        .drbg(core_out)
    );

    genvar g;
    generate
        for (g = 0; g < LFSR_SEED_SIZE/32; g++) begin : gen_lfsr
            caliptra_prim_lfsr #(
                .LfsrType("FIB_XNOR"),
                .LfsrDw(32),
                .StateOutDw(32)
            ) caliptra_prim_lfsr_inst_i (
                .clk_i(clk),
                .rst_ni(reset_n),
                .seed_en_i(core_init),
                .seed_i(sca_ent_w[g*32 +: 32]),
                .lfsr_en_i(1'b1),
                .entropy_i('0),
                .state_o(lfsr_bus[g*32 +: 32])
            );
        end
    endgenerate

    assign ready      = (ph_q == PH_IDLE) & core_ready & ~zeroize;
    assign launch_ok  = en & ready;
    assign valid_rise = core_valid & ~core_valid_q;
    assign cnt_nonce_w = {6{cnt_q}};
    assign sca_ent_w   = IV ^ lfsr_seed_q ^ cnt_nonce_w;

    always_comb begin
        core_entropy = sca_ent_q;
        core_nonce   = cnt_nonce_q;
        unique case (ph_q)
            PH_ISS_KEYGEN, PH_WAIT_KEYGEN: begin
                core_entropy = keygen_seed;
                core_nonce   = keygen_nonce;
            end
            PH_ISS_SIGN, PH_WAIT_SIGN: begin
                core_entropy = privKey;
                core_nonce   = hashed_msg;
            end
            default: ;
        endcase
    end

    always_comb begin
        core_init = 1'b0;
        core_next = 1'b0;
        ph_d      = ph_q;

        unique case (ph_q)
            PH_IDLE: begin
                if (launch_ok) ph_d = PH_ISS_LFSR;
            end
            PH_ISS_LFSR: begin
                if (!zeroize && core_ready) begin
                    core_init = 1'b1;
                    ph_d      = PH_WAIT_LFSR;
                end
            end
            PH_WAIT_LFSR: begin
                if (valid_rise) ph_d = PH_ISS_LAMBDA;
            end
            PH_ISS_LAMBDA: begin
                if (!zeroize && core_ready) begin
                    core_next = 1'b1;
                    ph_d      = PH_WAIT_LAMBDA;
                end
            end
            PH_WAIT_LAMBDA: begin
                if (valid_rise) ph_d = PH_ISS_SCALAR;
            end
            PH_ISS_SCALAR: begin
                if (!zeroize && core_ready) begin
                    core_next = 1'b1;
                    ph_d      = PH_WAIT_SCALAR;
                end
            end
            PH_WAIT_SCALAR: begin
                if (valid_rise) begin
                    if (core_out[191:0] == '0)
                        ph_d = PH_ISS_SCALAR;
                    else if (hmac_mode == MODE_SIGN)
                        ph_d = PH_ISS_MASK;
                    else if (hmac_mode == MODE_KEYGEN)
                        ph_d = PH_ISS_KEYGEN;
                    else
                        ph_d = PH_DONE;
                end
            end
            PH_ISS_MASK: begin
                if (!zeroize && core_ready) begin
                    core_next = 1'b1;
                    ph_d      = PH_WAIT_MASK;
                end
            end
            PH_WAIT_MASK: begin
                if (valid_rise) ph_d = PH_ISS_SIGN;
            end
            PH_ISS_KEYGEN: begin
                if (!zeroize && core_ready) begin
                    core_init = 1'b1;
                    ph_d      = PH_WAIT_KEYGEN;
                end
            end
            PH_WAIT_KEYGEN: begin
                if (valid_rise) ph_d = PH_DONE;
            end
            PH_ISS_SIGN: begin
                if (!zeroize && core_ready) begin
                    core_init = 1'b1;
                    ph_d      = PH_WAIT_SIGN;
                end
            end
            PH_WAIT_SIGN: begin
                if (valid_rise) ph_d = PH_DONE;
            end
            PH_DONE: begin
                ph_d = PH_IDLE;
            end
            default: ph_d = PH_IDLE;
        endcase
    end

    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            ph_q          <= PH_IDLE;
            core_valid_q  <= 1'b0;
            lfsr_seed_q   <= '0;
            lambda_q      <= '0;
            scalar_rnd_q  <= '0;
            masking_rnd_q <= '0;
            drbg_q        <= '0;
            cnt_nonce_q   <= '0;
            sca_ent_q     <= '0;
        end else if (zeroize) begin
            ph_q          <= PH_IDLE;
            core_valid_q  <= 1'b0;
            lfsr_seed_q   <= '0;
            lambda_q      <= '0;
            scalar_rnd_q  <= '0;
            masking_rnd_q <= '0;
            drbg_q        <= '0;
            cnt_nonce_q   <= '0;
            sca_ent_q     <= '0;
        end else begin
            ph_q <= ph_d;
            if (core_init || core_next)
                core_valid_q <= 1'b0;
            else
                core_valid_q <= core_valid;

            if (launch_ok) begin
                cnt_nonce_q   <= cnt_nonce_w;
                sca_ent_q     <= sca_ent_w;
                lambda_q      <= '0;
                scalar_rnd_q  <= '0;
                masking_rnd_q <= '0;
                drbg_q        <= '0;
            end else if (valid_rise) begin
                unique case (ph_q)
                    PH_WAIT_LFSR:   lfsr_seed_q  <= core_out;
                    PH_WAIT_LAMBDA: lambda_q     <= core_out;
                    PH_WAIT_SCALAR: if (core_out[191:0] != '0) scalar_rnd_q <= core_out;
                    PH_WAIT_MASK:   masking_rnd_q <= core_out;
                    PH_WAIT_KEYGEN,
                    PH_WAIT_SIGN:   drbg_q       <= core_out;
                    default: ;
                endcase
            end
        end
    end

    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) cnt_q <= '0;
        else          cnt_q <= cnt_q + 64'd1;
    end

    assign lambda      = zeroize ? '0 : lambda_q;
    assign scalar_rnd  = zeroize ? '0 : scalar_rnd_q;
    assign masking_rnd = zeroize ? '0 : masking_rnd_q;
    assign drbg        = zeroize ? '0 : drbg_q;
endmodule
