// SPDX-License-Identifier: BSD-2-Clause-Views
/*
 * Copyright (c) 2019-2023 The Regents of the University of California
 */

// Language: Verilog 2001

`resetall
`timescale 1ns / 1ps
`default_nettype none

/*
 * Receive checksum offload module (Alternate architecture: 18-bit bounded partial-fold accumulator)
 */
module rx_checksum #
(
    parameter DATA_WIDTH = 256,
    parameter KEEP_WIDTH = (DATA_WIDTH/8),
    parameter START_OFFSET = 14
)
(
    input  wire                   clk,
    input  wire                   rst,

    input  wire [DATA_WIDTH-1:0]  s_axis_tdata,
    input  wire [KEEP_WIDTH-1:0]  s_axis_tkeep,
    input  wire                   s_axis_tvalid,
    input  wire                   s_axis_tlast,

    output wire [15:0]            m_axis_csum,
    output wire                   m_axis_csum_valid
);

localparam LEVELS = $clog2(DATA_WIDTH/8);
localparam BEAT_SKIP = START_OFFSET / KEEP_WIDTH;
localparam BYTE_REM  = START_OFFSET % KEEP_WIDTH;
localparam CNT_W     = (BEAT_SKIP >= 2) ? $clog2(BEAT_SKIP + 1) : 1;
localparam FINAL_W   = 16 + LEVELS - 1;
localparam HI_W      = FINAL_W - 16;

reg [CNT_W-1:0]      skip_cnt_reg = BEAT_SKIP[CNT_W-1:0];
reg                  in_body_reg  = (BEAT_SKIP == 0);
reg                  rem_beat_reg = (BEAT_SKIP == 0);

reg [DATA_WIDTH-1:0] sum_reg [LEVELS-2:0];
reg [LEVELS-2:0]     sum_valid_reg = {LEVELS-1{1'b0}};
reg [LEVELS-2:0]     sum_last_reg  = {LEVELS-1{1'b0}};

// 18-bit bounded partial-fold accumulator (invariant: acc18_reg <= 18'h20010)
reg [17:0] acc18_reg      = 18'd0;
reg [17:0] fold18_reg     = 18'd0;
reg        fold_valid_reg = 1'b0;

reg [15:0] csum_out_reg       = 16'd0;
reg        csum_out_valid_reg = 1'b0;

assign m_axis_csum       = csum_out_reg;
assign m_axis_csum_valid = csum_out_valid_reg;

reg [DATA_WIDTH-1:0] masked_beat;
integer k;
always @* begin
    for (k = 0; k < KEEP_WIDTH; k = k + 1) begin
        if (!in_body_reg || !s_axis_tkeep[k] || (rem_beat_reg && (k < BYTE_REM))) begin
            masked_beat[k*8 +: 8] = 8'd0;
        end else begin
            masked_beat[k*8 +: 8] = s_axis_tdata[k*8 +: 8];
        end
    end
end

integer i;
always @(posedge clk) begin
    if (rst) begin
        skip_cnt_reg     <= BEAT_SKIP[CNT_W-1:0];
        in_body_reg      <= (BEAT_SKIP == 0);
        rem_beat_reg     <= (BEAT_SKIP == 0);
        sum_valid_reg[0] <= 1'b0;
        sum_last_reg[0]  <= 1'b0;
        for (i = 0; i < DATA_WIDTH/32; i = i + 1) begin
            sum_reg[0][i*17 +: 17] <= 17'd0;
        end
    end else begin
        sum_valid_reg[0] <= 1'b0;
        if (s_axis_tvalid) begin
            for (i = 0; i < DATA_WIDTH/32; i = i + 1) begin
                if ((START_OFFSET % 2) != 0) begin
                    sum_reg[0][i*17 +: 17] <= {1'b0, masked_beat[(4*i+1)*8 +: 8], masked_beat[(4*i+0)*8 +: 8]} +
                                              {1'b0, masked_beat[(4*i+3)*8 +: 8], masked_beat[(4*i+2)*8 +: 8]};
                end else begin
                    sum_reg[0][i*17 +: 17] <= {1'b0, masked_beat[(4*i+0)*8 +: 8], masked_beat[(4*i+1)*8 +: 8]} +
                                              {1'b0, masked_beat[(4*i+2)*8 +: 8], masked_beat[(4*i+3)*8 +: 8]};
                end
            end
            sum_valid_reg[0] <= 1'b1;
            sum_last_reg[0]  <= s_axis_tlast;

            if (s_axis_tlast) begin
                skip_cnt_reg <= BEAT_SKIP[CNT_W-1:0];
                in_body_reg  <= (BEAT_SKIP == 0);
                rem_beat_reg <= (BEAT_SKIP == 0);
            end else if (in_body_reg) begin
                rem_beat_reg <= 1'b0;
            end else begin
                skip_cnt_reg <= skip_cnt_reg - 1'b1;
                if (skip_cnt_reg == {{(CNT_W-1){1'b0}}, 1'b1}) begin
                    in_body_reg  <= 1'b1;
                    rem_beat_reg <= 1'b1;
                end
            end
        end
    end
end

generate
    genvar l;
    for (l = 1; l < LEVELS-1; l = l + 1) begin : gen_levels
        always @(posedge clk) begin
            if (rst) begin
                sum_valid_reg[l] <= 1'b0;
                sum_last_reg[l]  <= 1'b0;
                for (i = 0; i < (DATA_WIDTH/32)/(1 << l); i = i + 1) begin
                    sum_reg[l][i*(17+l) +: (17+l)] <= {(17+l){1'b0}};
                end
            end else begin
                sum_valid_reg[l] <= 1'b0;
                if (sum_valid_reg[l-1]) begin
                    for (i = 0; i < (DATA_WIDTH/32)/(1 << l); i = i + 1) begin
                        sum_reg[l][i*(17+l) +: (17+l)] <= sum_reg[l-1][(i*2+0)*(17+l-1) +: (17+l-1)] +
                                                          sum_reg[l-1][(i*2+1)*(17+l-1) +: (17+l-1)];
                    end
                    sum_valid_reg[l] <= 1'b1;
                    sum_last_reg[l]  <= sum_last_reg[l-1];
                end
            end
        end
    end
endgenerate

wire [15:0]   tree_lo = sum_reg[LEVELS-2][15:0];
wire [HI_W-1:0] tree_hi = sum_reg[LEVELS-2][FINAL_W-1:16];
wire [5:0]    hi_sum  = {4'd0, acc18_reg[17:16]} + {{(6-HI_W){1'b0}}, tree_hi};
wire [17:0]   acc18_next = {2'd0, acc18_reg[15:0]} + {2'd0, tree_lo} + {12'd0, hi_sum};

wire [16:0]   fold_mid = {1'b0, fold18_reg[15:0]} + {15'd0, fold18_reg[17:16]};

always @(posedge clk) begin
    if (rst) begin
        acc18_reg          <= 18'd0;
        fold18_reg         <= 18'd0;
        fold_valid_reg     <= 1'b0;
        csum_out_reg       <= 16'd0;
        csum_out_valid_reg <= 1'b0;
    end else begin
        fold_valid_reg     <= 1'b0;
        csum_out_valid_reg <= 1'b0;

        if (sum_valid_reg[LEVELS-2]) begin
            if (sum_last_reg[LEVELS-2]) begin
                fold18_reg     <= acc18_next;
                fold_valid_reg <= 1'b1;
                acc18_reg      <= 18'd0;
            end else begin
                acc18_reg <= acc18_next;
            end
        end

        if (fold_valid_reg) begin
            csum_out_reg       <= fold_mid[15:0] + {15'd0, fold_mid[16]};
            csum_out_valid_reg <= 1'b1;
        end
    end
end

endmodule

`resetall
