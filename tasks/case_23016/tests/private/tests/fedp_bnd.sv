`include "VX_define.vh"
module VX_tcu_fedp_tfr import VX_tcu_pkg::*; #(
    parameter `STRING INSTANCE_ID = "",
    parameter LANE_MASK = 0,
    parameter LATENCY = 4,
    parameter N = TCU_TC_K,
    parameter SF = 1,
    parameter W = 25,
    parameter USE_DSP = 0
) (
    input  wire clk,
    input  wire reset,
    input  wire enable,
    input  wire [TCU_MAX_INPUTS-1:0] vld_mask,
    input  wire [4:0] fmt_s,
    input  wire [4:0] fmt_d,
    input  wire [N-1:0][31:0] a_row,
    input  wire [N-1:0][31:0] b_col,
    input  wire [31:0] c_val,
    output wire [31:0] d_val
);
    `UNUSED_SPARAM (INSTANCE_ID)
    `UNUSED_PARAM ({LANE_MASK, SF, W, USE_DSP})
    reg [31:0] pipe_r [0:LATENCY-1];
    logic [31:0] fold_w;
    always_comb begin
        fold_w = c_val ^ {22'd0, fmt_s, fmt_d} ^ 32'(vld_mask);
        for (int k = 0; k < N; ++k)
            fold_w = fold_w ^ a_row[k] ^ {b_col[k][15:0], b_col[k][31:16]};
    end
    always_ff @(posedge clk) begin
        if (reset) begin
            for (int s = 0; s < LATENCY; ++s) pipe_r[s] <= 32'd0;
        end else if (enable) begin
            pipe_r[0] <= fold_w;
            for (int s = 1; s < LATENCY; ++s) pipe_r[s] <= pipe_r[s-1];
        end
    end
    assign d_val = pipe_r[LATENCY-1];
endmodule
