// SPDX-License-Identifier: Apache-2.0
// Blackbox declarations of heavy leaf engines for fast Yosys-slang synthesis & SCC sign-off
(* blackbox *)
module ecc_arith_unit #(
    parameter                  REG_SIZE     = 384,
    parameter                  RND_SIZE     = 192,
    parameter                  RADIX        = 32,
    parameter                  ADDR_WIDTH   = 6,
    parameter [REG_SIZE-1 : 0] p_prime      = '0,
    parameter [RADIX-1    : 0] p_mu         = '0,
    parameter [REG_SIZE-1 : 0] q_grouporder = '0,
    parameter [RADIX-1    : 0] q_mu         = '0
)(
    input  wire                           clk,
    input  wire                           reset_n,
    input  wire                           zeroize,
    input  wire [3:0]                     ecc_cmd_i,
    input  wire [ADDR_WIDTH-1:0]          addr_i,
    input  wire                           wr_op_sel_i,
    input  wire                           wr_en_i,
    input  wire                           rd_reg_i,
    input  wire [(REG_SIZE+RND_SIZE)-1:0] data_i,
    output wire [REG_SIZE-1:0]            data_o,
    output wire                           busy_o
);
endmodule

(* blackbox *)
module hmac_drbg #(
    parameter                  REG_SIZE        = 384,
    parameter [REG_SIZE-1 : 0] HMAC_DRBG_PRIME = '0
)(
    input  wire                 clk,
    input  wire                 reset_n,
    input  wire                 zeroize,
    input  wire                 init_cmd,
    input  wire                 next_cmd,
    output wire                 ready,
    output wire                 valid,
    input  wire [147:0]         lfsr_seed,
    input  wire [REG_SIZE-1:0]  entropy,
    input  wire [REG_SIZE-1:0]  nonce,
    output wire [REG_SIZE-1:0]  drbg
);
endmodule
