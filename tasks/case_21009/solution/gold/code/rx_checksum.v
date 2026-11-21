// SPDX-License-Identifier: BSD-2-Clause-Views
/*
 * Copyright (c) 2019-2023 The Regents of the University of California
 */

// Language: Verilog 2001

`resetall
`timescale 1ns / 1ps
`default_nettype none

/*
 * Receive checksum offload module
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
localparam SKIP_BEATS = START_OFFSET / KEEP_WIDTH;
localparam REM_OFFSET = START_OFFSET % KEEP_WIDTH;
localparam OFFSET_WIDTH = (SKIP_BEATS > 0) ? $clog2(SKIP_BEATS + 1) : 1;
localparam [KEEP_WIDTH-1:0] INIT_MASK = (SKIP_BEATS > 0) ? {KEEP_WIDTH{1'b0}} : ({KEEP_WIDTH{1'b1}} << REM_OFFSET);
localparam [KEEP_WIDTH-1:0] REM_MASK  = ({KEEP_WIDTH{1'b1}} << REM_OFFSET);
localparam FINAL_SUM_W = 16 + LEVELS - 1;

reg [OFFSET_WIDTH-1:0] offset_reg = SKIP_BEATS[OFFSET_WIDTH-1:0];
reg [KEEP_WIDTH-1:0]   mask_reg   = INIT_MASK;
reg [DATA_WIDTH-1:0]   s_axis_tdata_masked;

reg [DATA_WIDTH-1:0] sum_reg [LEVELS-2:0];
reg [LEVELS-2:0]     sum_valid_reg = {LEVELS-1{1'b0}};
reg [LEVELS-2:0]     sum_last_reg  = {LEVELS-1{1'b0}};

// Unfolded binary accumulator + dedicated post-tlast fold pipeline stage
reg [29:0] sum_acc_reg    = 30'd0;
reg [29:0] fold_acc_reg   = 30'd0;
reg        fold_valid_reg = 1'b0;

reg [15:0] m_axis_csum_reg       = 16'd0;
reg        m_axis_csum_valid_reg = 1'b0;

assign m_axis_csum       = m_axis_csum_reg;
assign m_axis_csum_valid = m_axis_csum_valid_reg;

integer j;
always @* begin
    for (j = 0; j < KEEP_WIDTH; j = j + 1) begin
        s_axis_tdata_masked[j*8 +: 8] = (s_axis_tkeep[j] && mask_reg[j]) ? s_axis_tdata[j*8 +: 8] : 8'd0;
    end
end

integer i;
always @(posedge clk) begin
    if (rst) begin
        offset_reg       <= SKIP_BEATS[OFFSET_WIDTH-1:0];
        mask_reg         <= INIT_MASK;
        sum_valid_reg[0] <= 1'b0;
        sum_last_reg[0]  <= 1'b0;
        for (i = 0; i < DATA_WIDTH/32; i = i + 1) begin
            sum_reg[0][i*17 +: 17] <= 17'd0;
        end
    end else begin
        sum_valid_reg[0] <= 1'b0;

        if (s_axis_tvalid) begin
            for (i = 0; i < DATA_WIDTH/32; i = i + 1) begin
                sum_reg[0][i*17 +: 17] <= {1'b0, s_axis_tdata_masked[(4*i+0)*8 +: 8], s_axis_tdata_masked[(4*i+1)*8 +: 8]} +
                                          {1'b0, s_axis_tdata_masked[(4*i+2)*8 +: 8], s_axis_tdata_masked[(4*i+3)*8 +: 8]};
            end
            sum_valid_reg[0] <= 1'b1;
            sum_last_reg[0]  <= s_axis_tlast;

            if (s_axis_tlast) begin
                offset_reg <= SKIP_BEATS[OFFSET_WIDTH-1:0];
                mask_reg   <= INIT_MASK;
            end else if (offset_reg == {OFFSET_WIDTH{1'b0}}) begin
                mask_reg <= {KEEP_WIDTH{1'b1}};
            end else begin
                offset_reg <= offset_reg - 1'b1;
                if (offset_reg == {{(OFFSET_WIDTH-1){1'b0}}, 1'b1}) begin
                    mask_reg <= REM_MASK;
                end else begin
                    mask_reg <= {KEEP_WIDTH{1'b0}};
                end
            end
        end
    end
end

generate
    genvar l;
    for (l = 1; l < LEVELS-1; l = l + 1) begin : gen_tree
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

wire [29:0] next_acc = sum_acc_reg + {{(30-FINAL_SUM_W){1'b0}}, sum_reg[LEVELS-2][FINAL_SUM_W-1:0]};
wire [16:0] fold_s1  = {1'b0, fold_acc_reg[15:0]} + {3'd0, fold_acc_reg[29:16]};
wire [15:0] fold_out = fold_s1[15:0] + {15'd0, fold_s1[16]};

always @(posedge clk) begin
    if (rst) begin
        sum_acc_reg           <= 30'd0;
        fold_acc_reg          <= 30'd0;
        fold_valid_reg        <= 1'b0;
        m_axis_csum_reg       <= 16'd0;
        m_axis_csum_valid_reg <= 1'b0;
    end else begin
        fold_valid_reg        <= 1'b0;
        m_axis_csum_valid_reg <= 1'b0;

        if (sum_valid_reg[LEVELS-2]) begin
            if (sum_last_reg[LEVELS-2]) begin
                fold_acc_reg   <= next_acc;
                fold_valid_reg <= 1'b1;
                sum_acc_reg    <= 30'd0;
            end else begin
                sum_acc_reg <= next_acc;
            end
        end

        if (fold_valid_reg) begin
            m_axis_csum_reg       <= ((START_OFFSET % 2) != 0) ? {fold_out[7:0], fold_out[15:8]} : fold_out;
            m_axis_csum_valid_reg <= 1'b1;
        end
    end
end

endmodule

`resetall
