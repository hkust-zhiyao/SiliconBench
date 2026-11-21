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

  reg [`AXI4_DATA_WIDTH-1:0] data_in_f;
  reg [`NOC_DATA_WIDTH-1:0]  resp_header;
  reg [1:0]                  state;
  reg [2:0]                  cur_idx;
  reg [2:0]                  end_idx;

  wire in_go       = in_val & in_rdy;
  wire flit_out_go = flit_out_val & flit_out_rdy;

  assign flit_out_val = (state == SEND_HEADER) || (state == SEND_DATA);
  assign in_rdy       = (state == ACCEPT);

  wire is_nc_small = (header_in[`MSG_TYPE] == `MSG_TYPE_NC_LOAD_REQ) &&
                     (header_in[`MSG_DATA_SIZE] <= `MSG_DATA_SIZE_8B) &&
                     (header_in[`MSG_DATA_SIZE] != `MSG_DATA_SIZE_0B);
  wire is_nc_zero  = (header_in[`MSG_TYPE] == `MSG_TYPE_NC_LOAD_REQ) &&
                     (header_in[`MSG_DATA_SIZE] == `MSG_DATA_SIZE_0B);

  always @(posedge clk) begin
    if (~rst_n) begin
      state       <= ACCEPT;
      cur_idx     <= 3'd0;
      end_idx     <= 3'd0;
      data_in_f   <= {`AXI4_DATA_WIDTH{1'b0}};
      resp_header <= {`NOC_DATA_WIDTH{1'b0}};
    end else begin
      case (state)
        ACCEPT: begin
          if (in_go) begin
            state     <= SEND_HEADER;
            cur_idx   <= 3'd0;
            data_in_f <= data_in;
            resp_header <= {`NOC_DATA_WIDTH{1'b0}};
            resp_header[`MSG_DST_CHIPID] <= header_in[`MSG_SRC_CHIPID];
            resp_header[`MSG_DST_X]      <= header_in[`MSG_SRC_X];
            resp_header[`MSG_DST_Y]      <= header_in[`MSG_SRC_Y];
            resp_header[`MSG_DST_FBITS]  <= header_in[`MSG_SRC_FBITS];
            resp_header[`MSG_MSHRID]     <= header_in[`MSG_MSHRID];
            resp_header[`MSG_OPTIONS_1]  <= {`MSG_OPTIONS_1_WIDTH{1'b0}};
            case (header_in[`MSG_TYPE])
              `MSG_TYPE_LOAD_MEM: begin
                resp_header[`MSG_TYPE]   <= `MSG_TYPE_LOAD_MEM_ACK;
                resp_header[`MSG_LENGTH] <= `PAYLOAD_LEN;
                end_idx                  <= 3'd7;
              end
              `MSG_TYPE_STORE_MEM: begin
                resp_header[`MSG_TYPE]   <= `MSG_TYPE_STORE_MEM_ACK;
                resp_header[`MSG_LENGTH] <= `MSG_LENGTH_WIDTH'd0;
                end_idx                  <= 3'd0;
              end
              `MSG_TYPE_NC_LOAD_REQ: begin
                resp_header[`MSG_TYPE]   <= `MSG_TYPE_NC_LOAD_MEM_ACK;
                resp_header[`MSG_LENGTH] <= is_nc_zero  ? `MSG_LENGTH_WIDTH'd0 :
                                            is_nc_small ? `MSG_LENGTH_WIDTH'd1 : `PAYLOAD_LEN;
                end_idx                  <= (is_nc_zero || is_nc_small) ? 3'd0 : 3'd7;
              end
              `MSG_TYPE_NC_STORE_REQ: begin
                resp_header[`MSG_TYPE]   <= `MSG_TYPE_NC_STORE_MEM_ACK;
                resp_header[`MSG_LENGTH] <= `MSG_LENGTH_WIDTH'd0;
                end_idx                  <= 3'd0;
              end
              default: begin
                resp_header[`MSG_TYPE]   <= `MSG_TYPE_WIDTH'd0;
                resp_header[`MSG_LENGTH] <= `MSG_LENGTH_WIDTH'd0;
                end_idx                  <= 3'd0;
              end
            endcase
          end
        end
        SEND_HEADER: begin
          if (flit_out_go) begin
            if (resp_header[`MSG_LENGTH] == `MSG_LENGTH_WIDTH'd0) begin
              state   <= ACCEPT;
              cur_idx <= 3'd0;
            end else begin
              state   <= SEND_DATA;
              cur_idx <= 3'd0;
            end
          end
        end
        SEND_DATA: begin
          if (flit_out_go) begin
            if (cur_idx == end_idx) begin
              state   <= ACCEPT;
              cur_idx <= 3'd0;
            end else begin
              cur_idx <= cur_idx + 3'd1;
            end
          end
        end
        default: begin
          state   <= ACCEPT;
          cur_idx <= 3'd0;
        end
      endcase
    end
  end

  reg [`NOC_DATA_WIDTH-1:0] data_slice;
  always @(*) begin
    case (cur_idx)
      3'd0: data_slice = data_in_f[ 63:  0];
      3'd1: data_slice = data_in_f[127: 64];
      3'd2: data_slice = data_in_f[191:128];
      3'd3: data_slice = data_in_f[255:192];
      3'd4: data_slice = data_in_f[319:256];
      3'd5: data_slice = data_in_f[383:320];
      3'd6: data_slice = data_in_f[447:384];
      3'd7: data_slice = data_in_f[511:448];
    endcase
  end

  always @(*) begin
    case (state)
      SEND_HEADER: flit_out = resp_header;
      SEND_DATA:   flit_out = data_slice;
      default:     flit_out = {`NOC_DATA_WIDTH{1'b0}};
    endcase
  end

endmodule
