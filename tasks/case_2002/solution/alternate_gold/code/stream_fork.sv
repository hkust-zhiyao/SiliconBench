// Copyright 2018 ETH Zurich and University of Bologna (Alternate Reference).

`include "prim_assert.sv"

module stream_fork #(
    parameter int unsigned N_OUP = 0
) (
    input  logic                clk_i,
    input  logic                rst_ni,
    input  logic                valid_i,
    input  logic                clr_i,
    output logic                ready_o,
    output logic [N_OUP-1:0]    valid_o,
    input  logic [N_OUP-1:0]    ready_i
);

    logic [N_OUP-1:0] done_q, done_d;
    logic [N_OUP-1:0] oup_hs;

    assign valid_o = {N_OUP{valid_i}} & ~done_q;
    assign oup_hs  = valid_o & ready_i;
    assign ready_o = valid_i & (&(done_q | ready_i));

    always_comb begin
        if (clr_i || !valid_i || ready_o) begin
            done_d = '0;
        end else begin
            done_d = done_q | oup_hs;
        end
    end

    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            done_q <= '0;
        end else begin
            done_q <= done_d;
        end
    end

    `ASSERT_INIT(NumOutputLargerZero_A, N_OUP >= 1)

endmodule
