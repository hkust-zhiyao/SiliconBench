// ========== Copyright Header Begin ============================================
// Copyright (c) 2019 Princeton University
// All rights reserved.
// BSD-3-Clause
// ========== Copyright Header End ============================================

`include "mc_define.h"
`include "define.tmp.h"
`include "noc_axi4_bridge_define.vh"

module noc_axi4_bridge_ser (
  input  wire                          clk,
  input  wire                          rst_n,

  input  wire [`MSG_HEADER_WIDTH-1:0]  header_in,
  input  wire [`AXI4_DATA_WIDTH-1:0]   data_in,
  input  wire                          in_val,
  output wire                          in_rdy,

  output reg  [`NOC_DATA_WIDTH-1:0]    flit_out,
  output wire                          flit_out_val,
  input  wire                          flit_out_rdy
);

  localparam ACCEPT      = 2'd0;
  localparam SEND_HEADER = 2'd1;
  localparam SEND_DATA   = 2'd2;

  reg [`AXI4_DATA_WIDTH-1:0]  data_in_f;
  reg [`NOC_DATA_WIDTH-1:0]   resp_header;
  reg [1:0]                   state;
  reg [`MSG_LENGTH_WIDTH-1:0] remaining_flits;
  reg [2:0]                   word_idx;

  wire in_go       = in_val & in_rdy;
  wire flit_out_go = flit_out_val & flit_out_rdy;

  assign flit_out_val = (state == SEND_HEADER) || (state == SEND_DATA);
  assign in_rdy       = (state == ACCEPT);

  reg [`MSG_LENGTH_WIDTH-1:0] calc_len;
  always @(*) begin
    case (header_in[`MSG_TYPE])
      `MSG_TYPE_LOAD_MEM:     calc_len = `PAYLOAD_LEN;
      `MSG_TYPE_STORE_MEM:    calc_len = `MSG_LENGTH_WIDTH'd0;
      `MSG_TYPE_NC_STORE_REQ: calc_len = `MSG_LENGTH_WIDTH'd0;
      `MSG_TYPE_NC_LOAD_REQ: begin
        if (header_in[`MSG_DATA_SIZE] == `MSG_DATA_SIZE_0B)
          calc_len = `MSG_LENGTH_WIDTH'd0;
        else if (header_in[`MSG_DATA_SIZE] <= `MSG_DATA_SIZE_8B)
          calc_len = `MSG_LENGTH_WIDTH'd1;
        else
          calc_len = `PAYLOAD_LEN;
      end
      default:                calc_len = `MSG_LENGTH_WIDTH'd0;
    endcase
  end

  always @(posedge clk) begin
    if (~rst_n) begin
      state           <= ACCEPT;
      remaining_flits <= `MSG_LENGTH_WIDTH'd0;
      word_idx        <= 3'd0;
      data_in_f       <= {`AXI4_DATA_WIDTH{1'b0}};
      resp_header     <= {`NOC_DATA_WIDTH{1'b0}};
    end else begin
      case (state)
        ACCEPT: begin
          if (in_go) begin
            state           <= SEND_HEADER;
            remaining_flits <= calc_len;
            word_idx        <= 3'd0;
            data_in_f       <= data_in;
            resp_header     <= {`NOC_DATA_WIDTH{1'b0}};
            resp_header[`MSG_DST_CHIPID] <= header_in[`MSG_SRC_CHIPID];
            resp_header[`MSG_DST_X]      <= header_in[`MSG_SRC_X];
            resp_header[`MSG_DST_Y]      <= header_in[`MSG_SRC_Y];
            resp_header[`MSG_DST_FBITS]  <= header_in[`MSG_SRC_FBITS];
            resp_header[`MSG_MSHRID]     <= header_in[`MSG_MSHRID];
            resp_header[`MSG_OPTIONS_1]  <= {`MSG_OPTIONS_1_WIDTH{1'b0}};
            resp_header[`MSG_LENGTH]     <= calc_len;
            case (header_in[`MSG_TYPE])
              `MSG_TYPE_LOAD_MEM:     resp_header[`MSG_TYPE] <= `MSG_TYPE_LOAD_MEM_ACK;
              `MSG_TYPE_STORE_MEM:    resp_header[`MSG_TYPE] <= `MSG_TYPE_STORE_MEM_ACK;
              `MSG_TYPE_NC_LOAD_REQ:  resp_header[`MSG_TYPE] <= `MSG_TYPE_NC_LOAD_MEM_ACK;
              `MSG_TYPE_NC_STORE_REQ: resp_header[`MSG_TYPE] <= `MSG_TYPE_NC_STORE_MEM_ACK;
              default:                resp_header[`MSG_TYPE] <= `MSG_TYPE_WIDTH'd0;
            endcase
          end
        end
        SEND_HEADER: begin
          if (flit_out_go) begin
            if (remaining_flits == `MSG_LENGTH_WIDTH'd0) begin
              state <= ACCEPT;
            end else begin
              state    <= SEND_DATA;
              word_idx <= 3'd0;
            end
          end
        end
        SEND_DATA: begin
          if (flit_out_go) begin
            if (remaining_flits == `MSG_LENGTH_WIDTH'd1) begin
              state           <= ACCEPT;
              remaining_flits <= `MSG_LENGTH_WIDTH'd0;
              word_idx        <= 3'd0;
            end else begin
              remaining_flits <= remaining_flits - `MSG_LENGTH_WIDTH'd1;
              word_idx        <= word_idx + 3'd1;
            end
          end
        end
        default: begin
          state           <= ACCEPT;
          remaining_flits <= `MSG_LENGTH_WIDTH'd0;
          word_idx        <= 3'd0;
        end
      endcase
    end
  end

  reg [`NOC_DATA_WIDTH-1:0] data_word_mux;
  always @(*) begin
    case (word_idx)
      3'd0: data_word_mux = data_in_f[ 63:  0];
      3'd1: data_word_mux = data_in_f[127: 64];
      3'd2: data_word_mux = data_in_f[191:128];
      3'd3: data_word_mux = data_in_f[255:192];
      3'd4: data_word_mux = data_in_f[319:256];
      3'd5: data_word_mux = data_in_f[383:320];
      3'd6: data_word_mux = data_in_f[447:384];
      3'd7: data_word_mux = data_in_f[511:448];
    endcase
  end

  always @(*) begin
    case (state)
      SEND_HEADER: flit_out = resp_header;
      SEND_DATA:   flit_out = data_word_mux;
      default:     flit_out = {`NOC_DATA_WIDTH{1'b0}};
    endcase
  end

endmodule
