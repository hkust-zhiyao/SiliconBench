// SPDX-License-Identifier: Apache-2.0
module eh2_lsu_amo
import eh2_pkg::*;
#(
`include "eh2_param.vh"
)(
   input eh2_lsu_pkt_t          lsu_pkt_dc3,
   input logic                  addr_in_pic_dc3,
   input logic  [pt.XLEN-1:0]   lsu_dccm_data_corr_dc3,
   input logic  [pt.XLEN-1:0]   store_data_dc3,

   output logic [pt.XLEN-1:0]   amo_data_dc3
);

   logic [pt.XLEN-1:0] op1, op2, op2_rhs, add_sub_res;
   logic               is_amo, is_add, cout, op1_lt_op2;

   assign is_amo  = lsu_pkt_dc3.valid & lsu_pkt_dc3.atomic;
   assign is_add  = is_amo & (lsu_pkt_dc3.atomic_instr[4:0] == 5'd0);
   assign op1     = is_amo ? lsu_dccm_data_corr_dc3 : '0;
   assign op2     = is_amo ? store_data_dc3         : '0;
   assign op2_rhs = is_add ? op2 : ~op2;

   assign {cout, add_sub_res} = {1'b0, op1} + {1'b0, op2_rhs} + {{pt.XLEN{1'b0}}, ~is_add};

   always_comb begin
      if (lsu_pkt_dc3.unsign) begin
         op1_lt_op2 = ~cout;
      end else if (op1[31] != op2[31]) begin
         op1_lt_op2 = op1[31];
      end else begin
         op1_lt_op2 = ~cout;
      end

      amo_data_dc3 = '0;
      if (is_amo) begin
         unique case (lsu_pkt_dc3.atomic_instr[4:0])
            5'd0:  amo_data_dc3 = add_sub_res;
            5'd1,
            5'd3:  amo_data_dc3 = op2;
            5'd4:  amo_data_dc3 = op1 ^ op2;
            5'd8:  amo_data_dc3 = op1 | op2;
            5'd12: amo_data_dc3 = op1 & op2;
            5'd16,
            5'd24: amo_data_dc3 = op1_lt_op2 ? op1 : op2;
            5'd20,
            5'd28: amo_data_dc3 = op1_lt_op2 ? op2 : op1;
            default: amo_data_dc3 = '0;
         endcase
      end
   end

endmodule
