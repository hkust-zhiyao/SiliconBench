// Copyright 2018 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51.

`include "parameters.v"

module priority_Flag_Req 
#(
      parameter WIDTH     = 3,
      parameter MAX_COUNT = 2**WIDTH-1
)
(
      input  logic                 clk,
      input  logic                 rst_n,
      input  logic                 TCDM_arb_policy_i,

      output logic [WIDTH-1:0]     PRIO_FLAG_o,
      input  logic                 data_req_i,
      input  logic [WIDTH-1:0]     ID_i,
`ifdef GNT_BASED_FC
      input  logic                 data_gnt_i
`else
      input  logic                 data_stall_i
`endif
);

   logic hs_done;
`ifdef GNT_BASED_FC
   assign hs_done = data_req_i && data_gnt_i;
`else
   assign hs_done = data_req_i && !data_stall_i;
`endif

   always_ff @(posedge clk or negedge rst_n) begin
      if (!rst_n) begin
         PRIO_FLAG_o <= '0;
      end else if (hs_done) begin
         if (!TCDM_arb_policy_i) begin
            PRIO_FLAG_o <= (PRIO_FLAG_o < MAX_COUNT) ? (PRIO_FLAG_o + 1'b1) : '0;
         end else begin
            PRIO_FLAG_o <= ID_i;
         end
      end
   end

endmodule
