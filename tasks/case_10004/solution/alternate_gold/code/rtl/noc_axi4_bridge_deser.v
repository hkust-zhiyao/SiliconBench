// ========== Copyright Header Begin ============================================
// Copyright (c) 2019 Princeton University
// All rights reserved.
// BSD-3-Clause
// ========== Copyright Header End ============================================

`include "mc_define.h"
`include "define.tmp.h"
`include "noc_axi4_bridge_define.vh"

module noc_axi4_bridge_deser (
  input  wire                          clk,
  input  wire                          rst_n,

  input  wire [`NOC_DATA_WIDTH-1:0]    flit_in,
  input  wire                          flit_in_val,
  output wire                          flit_in_rdy,
  input  wire                          phy_init_done,

  output wire [`MSG_HEADER_WIDTH-1:0]  header_out,
  output wire [`AXI4_DATA_WIDTH-1:0]   data_out,
  output wire                          out_val,
  input  wire                          out_rdy
);

  localparam ACCEPT_W1   = 3'd0;
  localparam ACCEPT_W2   = 3'd1;
  localparam ACCEPT_W3   = 3'd2;
  localparam ACCEPT_DATA = 3'd3;
  localparam SEND        = 3'd4;

  reg [`NOC_DATA_WIDTH-1:0] pkt_w1;
  reg [`NOC_DATA_WIDTH-1:0] pkt_w2;
  reg [`NOC_DATA_WIDTH-1:0] pkt_w3;
  reg [`NOC_DATA_WIDTH-1:0] in_data_buf [`PAYLOAD_LEN-1:0];
  reg [2:0]                 wr_idx;
  reg [2:0]                 last_idx;
  reg                       has_data;
  reg [2:0]                 state;

  assign flit_in_rdy = (state != SEND) & phy_init_done;
  wire flit_in_go    = flit_in_val & flit_in_rdy;
  assign out_val     = (state == SEND);

  wire [`MSG_LENGTH_WIDTH-1:0] w1_len = flit_in[`MSG_LENGTH];
  wire w1_has_data = (w1_len > `MSG_LENGTH_WIDTH'd2);
  wire [3:0] w1_last_idx4 = w1_has_data ? (w1_len[3:0] - 4'd3) : 4'd0;
  wire [2:0] w1_last_idx  = w1_last_idx4[2:0];

  integer k;
  always @(posedge clk) begin
    if (~rst_n) begin
      state    <= ACCEPT_W1;
      wr_idx   <= 3'd0;
      last_idx <= 3'd0;
      has_data <= 1'b0;
      pkt_w1   <= {`NOC_DATA_WIDTH{1'b0}};
      pkt_w2   <= {`NOC_DATA_WIDTH{1'b0}};
      pkt_w3   <= {`NOC_DATA_WIDTH{1'b0}};
      for (k = 0; k < `PAYLOAD_LEN; k = k + 1) begin
        in_data_buf[k] <= {`NOC_DATA_WIDTH{1'b0}};
      end
    end else begin
      case (state)
        ACCEPT_W1: begin
          if (flit_in_go) begin
            state    <= ACCEPT_W2;
            wr_idx   <= 3'd0;
            last_idx <= w1_last_idx;
            has_data <= w1_has_data;
            pkt_w1   <= flit_in;
            for (k = 0; k < `PAYLOAD_LEN; k = k + 1) begin
              in_data_buf[k] <= {`NOC_DATA_WIDTH{1'b0}};
            end
          end
        end
        ACCEPT_W2: begin
          if (flit_in_go) begin
            state  <= ACCEPT_W3;
            pkt_w2 <= flit_in;
          end
        end
        ACCEPT_W3: begin
          if (flit_in_go) begin
            pkt_w3 <= flit_in;
            state  <= has_data ? ACCEPT_DATA : SEND;
          end
        end
        ACCEPT_DATA: begin
          if (flit_in_go) begin
            in_data_buf[3'd7 - wr_idx] <= flit_in;
            if (wr_idx == last_idx) begin
              state  <= SEND;
              wr_idx <= 3'd0;
            end else begin
              wr_idx <= wr_idx + 3'd1;
            end
          end
        end
        SEND: begin
          if (out_rdy) begin
            state    <= ACCEPT_W1;
            wr_idx   <= 3'd0;
            last_idx <= 3'd0;
            has_data <= 1'b0;
          end
        end
        default: begin
          state    <= ACCEPT_W1;
          wr_idx   <= 3'd0;
          last_idx <= 3'd0;
          has_data <= 1'b0;
        end
      endcase
    end
  end

  assign header_out = {pkt_w3, pkt_w2, pkt_w1};
  assign data_out   = {in_data_buf[0], in_data_buf[1], in_data_buf[2], in_data_buf[3],
                       in_data_buf[4], in_data_buf[5], in_data_buf[6], in_data_buf[7]};

endmodule
