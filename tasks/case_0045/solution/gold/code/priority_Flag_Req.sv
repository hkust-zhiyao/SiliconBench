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

   always_ff @(posedge clk, negedge rst_n)
   begin : Prio_Flag_Req_SEQ
      if(rst_n == 1'b0)
         PRIO_FLAG_o <= '0;
      else
      `ifdef GNT_BASED_FC
            if( data_req_i  & data_gnt_i )
      `else
            if( data_req_i  & ~data_stall_i )
      `endif
            begin
                  if(TCDM_arb_policy_i == 1'b0)
                  begin : RR_PRIORIY
                     if(PRIO_FLAG_o < MAX_COUNT)
                        PRIO_FLAG_o <= PRIO_FLAG_o + 1'b1;
                     else
                        PRIO_FLAG_o <= '0;
                  end
                  else
                  begin : LAST_WIN_PRIO
                     PRIO_FLAG_o <= ID_i;
                  end
            end
   end
   
endmodule
