// SPDX-License-Identifier: Apache-2.0
// Alternate implementation of ecc_scalar_blinding using a 6-step radix-32 x 384-bit streaming MAC
module ecc_scalar_blinding #(
    parameter                   REG_SIZE     = 384,
    parameter                   RND_SIZE     = 192,
    parameter                   RADIX        = 32,
    parameter [REG_SIZE-1 : 0]  GROUP_ORDER  = 384'hffffffffffffffffffffffffffffffffffffffffffffffffc7634d81f4372ddf581a0db248b0a77aecec196accc52973
)(
    input  wire                             clk,
    input  wire                             reset_n,
    input  wire                             zeroize,
    input  wire                             en_i,
    input  wire [REG_SIZE-1 : 0]            data_i,
    input  wire [RND_SIZE-1 : 0]            rnd_i,
    output wire [(REG_SIZE+RND_SIZE)-1 : 0] data_o,
    output wire                             busy_o
);
    localparam int OUT_W     = REG_SIZE + RND_SIZE;
    localparam int NUM_STEPS = RND_SIZE / RADIX; // 6 steps of 32 bits

    typedef enum logic [1:0] {
        SB_IDLE = 2'b00,
        SB_MAC  = 2'b01,
        SB_COMMIT = 2'b10
    } sb_state_e;

    sb_state_e             st_q;
    logic [2:0]            step_q;
    logic [RND_SIZE-1:0]   rnd_shift_q;
    logic [OUT_W-1:0]      acc_q;
    logic [OUT_W-1:0]      res_q;

    logic                  bad_req;
    logic [RADIX-1:0]      cur_limb;
    logic [REG_SIZE+RADIX-1:0] limb_prod;
    logic [OUT_W-1:0]      shifted_prod;

    assign bad_req      = (data_i == '0) || (data_i >= GROUP_ORDER) || (rnd_i == '0);
    assign cur_limb     = rnd_shift_q[RADIX-1:0];
    assign limb_prod    = {{RADIX{1'b0}}, GROUP_ORDER} * {{REG_SIZE{1'b0}}, cur_limb};
    assign shifted_prod = OUT_W'(limb_prod) << (step_q * RADIX);

    always_ff @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            st_q        <= SB_IDLE;
            step_q      <= '0;
            rnd_shift_q <= '0;
            acc_q       <= '0;
            res_q       <= '0;
        end else if (zeroize) begin
            st_q        <= SB_IDLE;
            step_q      <= '0;
            rnd_shift_q <= '0;
            acc_q       <= '0;
            res_q       <= '0;
        end else if (en_i) begin
            if (bad_req) begin
                st_q        <= SB_IDLE;
                step_q      <= '0;
                rnd_shift_q <= '0;
                acc_q       <= '0;
                res_q       <= '0;
            end else begin
                st_q        <= SB_MAC;
                step_q      <= 3'd0;
                rnd_shift_q <= rnd_i;
                acc_q       <= {{RND_SIZE{1'b0}}, data_i};
                res_q       <= '0;
            end
        end else begin
            unique case (st_q)
                SB_MAC: begin
                    acc_q       <= acc_q + shifted_prod;
                    rnd_shift_q <= {{RADIX{1'b0}}, rnd_shift_q[RND_SIZE-1:RADIX]};
                    if (step_q == 3'(NUM_STEPS - 1)) begin
                        st_q <= SB_COMMIT;
                    end else begin
                        step_q <= step_q + 3'd1;
                    end
                end
                SB_COMMIT: begin
                    res_q       <= acc_q;
                    acc_q       <= '0;
                    rnd_shift_q <= '0;
                    st_q        <= SB_IDLE;
                end
                default: begin
                    st_q <= SB_IDLE;
                end
            endcase
        end
    end

    assign data_o = zeroize ? '0 : res_q;
    assign busy_o = ~zeroize & (st_q != SB_IDLE);
endmodule
