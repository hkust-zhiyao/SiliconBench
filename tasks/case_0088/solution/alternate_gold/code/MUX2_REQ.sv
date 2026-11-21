// Copyright 2018 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51.

`include "parameters.v"

module MUX2_REQ 
#(
    parameter ID_WIDTH   = 20,
    parameter ADDR_WIDTH = 32,
    parameter DATA_WIDTH = 32,
    parameter BE_WIDTH   = DATA_WIDTH/8
)
(
    input  logic                                 data_req_CH0_i,
    input  logic [ADDR_WIDTH-1:0]                data_add_CH0_i,
    input  logic                                 data_wen_CH0_i,
    input  logic [DATA_WIDTH-1:0]                data_wdata_CH0_i,
    input  logic [BE_WIDTH-1:0]                  data_be_CH0_i,
    input  logic [ID_WIDTH-1:0]                  data_ID_CH0_i,
`ifdef GNT_BASED_FC
    output logic                                 data_gnt_CH0_o,
`else
    output logic                                 data_stall_CH0_o,
`endif

    input  logic                                 data_req_CH1_i,
    input  logic [ADDR_WIDTH-1:0]                data_add_CH1_i,
    input  logic                                 data_wen_CH1_i,
    input  logic [DATA_WIDTH-1:0]                data_wdata_CH1_i,
    input  logic [BE_WIDTH-1:0]                  data_be_CH1_i,
    input  logic [ID_WIDTH-1:0]                  data_ID_CH1_i,
`ifdef GNT_BASED_FC
    output logic                                 data_gnt_CH1_o,
`else
    output logic                                 data_stall_CH1_o,
`endif

    output  logic                                data_req_o,
    output  logic [ADDR_WIDTH-1:0]               data_add_o,
    output  logic                                data_wen_o,
    output  logic [DATA_WIDTH-1:0]               data_wdata_o,
    output  logic [BE_WIDTH-1:0]                 data_be_o,
    output  logic [ID_WIDTH-1:0]                 data_ID_o,
`ifdef GNT_BASED_FC
    input   logic                                data_gnt_i,
`else
    input   logic                                data_stall_i,
`endif

    input   logic                                clk,
    input   logic                                rst_n
);

    logic                                        SEL;
    logic                                        RR_FLAG;
    logic [1:0]                                  held_q;
    logic [1:0]                                  req_in, eff_req;
    logic                                        hs_ok;

`ifdef GNT_BASED_FC
    assign hs_ok = data_gnt_i;
`else
    assign hs_ok = ~data_stall_i;
`endif

    assign req_in  = {data_req_CH1_i, data_req_CH0_i};
    assign eff_req = (|(held_q & req_in)) ? (held_q & req_in) : req_in;

    assign data_req_o = |eff_req;
    assign SEL        = ~eff_req[0] | (RR_FLAG & eff_req[1]);

`ifdef GNT_BASED_FC
    assign data_gnt_CH0_o     = (( eff_req[0] & ~eff_req[1]) | ( eff_req[0] & ~RR_FLAG)) & data_gnt_i;
    assign data_gnt_CH1_o     = ((~eff_req[0] &  eff_req[1]) | ( eff_req[1] &  RR_FLAG)) & data_gnt_i;
`else
    assign data_stall_CH0_o   = (eff_req[0] & eff_req[1] & RR_FLAG)  | ((( eff_req[0] & ~eff_req[1]) | ( eff_req[0] & ~RR_FLAG)) & data_stall_i);
    assign data_stall_CH1_o   = (eff_req[0] & eff_req[1] & ~RR_FLAG) | (((~eff_req[0] &  eff_req[1]) | ( eff_req[1] &  RR_FLAG)) & data_stall_i);
`endif

    always_ff @(posedge clk or negedge rst_n)
    begin
      if (rst_n == 1'b0) begin
          RR_FLAG <= 1'b0;
          held_q  <= 2'b00;
      end else begin
          if (data_req_o && hs_ok) begin
              RR_FLAG <= ~SEL;
              held_q  <= 2'b00;
          end else if (data_req_o && !hs_ok) begin
              held_q  <= {SEL, ~SEL};
          end else begin
              held_q  <= 2'b00;
          end
      end
    end

    always_comb
    begin : MUX2_REQ_COMB
      case(SEL)
      1'b0: begin
            data_add_o   = data_add_CH0_i;
            data_wen_o   = data_wen_CH0_i;
            data_wdata_o = data_wdata_CH0_i;
            data_be_o    = data_be_CH0_i;
            data_ID_o    = data_ID_CH0_i;
          end
      1'b1: begin
            data_add_o   = data_add_CH1_i;
            data_wen_o   = data_wen_CH1_i;
            data_wdata_o = data_wdata_CH1_i;
            data_be_o    = data_be_CH1_i;
            data_ID_o    = data_ID_CH1_i;
          end
      endcase
    end
endmodule
