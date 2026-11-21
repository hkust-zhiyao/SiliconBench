// Copyright 2021 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

module fixed_p_rounding import ara_pkg::*; import rvv_pkg::*; #(
    localparam int  unsigned DataWidth = $bits(elen_t),
    localparam int  unsigned StrbWidth = DataWidth/8,
    localparam type          strb_t    = logic [StrbWidth-1:0]
  ) (
    input  elen_t   operand_a_i,
    input  elen_t   operand_b_i,
    input  logic    valid_i,
    input  ara_op_e op_i,
    input  vew_e    vew_i,
    input  vxrm_t   vxrm_i,
    output strb_t   r_o
  );

  // Alternate implementation: 64-bit zero-extended shift-and-mask evaluator
  function automatic logic eval_round64(
    input logic [63:0] val64,
    input logic [5:0]  shamt,
    input vxrm_t       vxrm
  );
    logic [5:0]  sh_m1;
    logic [63:0] shifted_m1;
    logic [63:0] low_mask;
    logic        v_dm1, v_d, sticky_dm2;
    if (shamt == 6'd0) begin
      return 1'b0;
    end else begin
      sh_m1      = shamt - 6'd1;
      shifted_m1 = val64 >> sh_m1;
      v_dm1      = shifted_m1[0];
      v_d        = shifted_m1[1];
      low_mask   = (64'd1 << sh_m1) - 64'd1;
      sticky_dm2 = |(val64 & low_mask);
      unique case (vxrm)
        2'b00:   return v_dm1;
        2'b01:   return v_dm1 & (sticky_dm2 | v_d);
        2'b10:   return 1'b0;
        default: return (~v_d) & (v_dm1 | sticky_dm2);
      endcase
    end
  endfunction

  always_comb begin
    r_o = '0;
    if (valid_i) begin
      if (op_i inside {VSSRA, VSSRL}) begin
        unique case (vew_i)
          EW8:  for (int c = 0; c < 8; c++)
                  r_o[c] = eval_round64({56'd0, operand_b_i[8*c +: 8]},   {3'd0, operand_a_i[8*c +: 3]},   vxrm_i);
          EW16: for (int c = 0; c < 4; c++)
                  r_o[c] = eval_round64({48'd0, operand_b_i[16*c +: 16]}, {2'd0, operand_a_i[16*c +: 4]},  vxrm_i);
          EW32: for (int c = 0; c < 2; c++)
                  r_o[c] = eval_round64({32'd0, operand_b_i[32*c +: 32]}, {1'd0, operand_a_i[32*c +: 5]},  vxrm_i);
          EW64:   r_o[0] = eval_round64(operand_b_i,                      operand_a_i[5:0],                vxrm_i);
          default:;
        endcase
      end else if (op_i inside {VNCLIP, VNCLIPU}) begin
        unique case (vew_i)
          EW8:  for (int c = 0; c < 4; c++)
                  r_o[c] = eval_round64({48'd0, operand_b_i[16*c +: 16]}, {2'd0, operand_a_i[16*c +: 4]},  vxrm_i);
          EW16: for (int c = 0; c < 2; c++)
                  r_o[c] = eval_round64({32'd0, operand_b_i[32*c +: 32]}, {1'd0, operand_a_i[32*c +: 5]},  vxrm_i);
          EW32:   r_o[0] = eval_round64(operand_b_i,                      operand_a_i[5:0],                vxrm_i);
          default:;
        endcase
      end
    end
  end

endmodule : fixed_p_rounding
