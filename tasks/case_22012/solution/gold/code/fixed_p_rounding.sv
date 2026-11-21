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

  typedef union packed {
    logic [0:0][63:0] w64;
    logic [1:0][31:0] w32;
    logic [3:0][15:0] w16;
    logic [7:0][ 7:0] w8;
  } rounding_args_t;

  rounding_args_t opa, opb;
  assign opa = operand_a_i;
  assign opb = operand_b_i;

  function automatic logic round_bit_w8(input logic [7:0] v, input logic [2:0] d, input vxrm_t mode);
    logic [2:0] dm1;
    logic       v_d, v_dm1, sticky_low;
    if (d == 3'd0) begin
      return 1'b0;
    end else begin
      dm1        = d - 3'd1;
      v_d        = v[d];
      v_dm1      = v[dm1];
      sticky_low = 1'b0;
      for (int k = 0; k < 8; k++) begin
        if (k < int'(dm1)) sticky_low |= v[k];
      end
      unique case (mode)
        2'b00:   return v_dm1;
        2'b01:   return v_dm1 & (sticky_low | v_d);
        2'b10:   return 1'b0;
        default: return (~v_d) & (v_dm1 | sticky_low);
      endcase
    end
  endfunction

  function automatic logic round_bit_w16(input logic [15:0] v, input logic [3:0] d, input vxrm_t mode);
    logic [3:0] dm1;
    logic       v_d, v_dm1, sticky_low;
    if (d == 4'd0) begin
      return 1'b0;
    end else begin
      dm1        = d - 4'd1;
      v_d        = v[d];
      v_dm1      = v[dm1];
      sticky_low = 1'b0;
      for (int k = 0; k < 16; k++) begin
        if (k < int'(dm1)) sticky_low |= v[k];
      end
      unique case (mode)
        2'b00:   return v_dm1;
        2'b01:   return v_dm1 & (sticky_low | v_d);
        2'b10:   return 1'b0;
        default: return (~v_d) & (v_dm1 | sticky_low);
      endcase
    end
  endfunction

  function automatic logic round_bit_w32(input logic [31:0] v, input logic [4:0] d, input vxrm_t mode);
    logic [4:0] dm1;
    logic       v_d, v_dm1, sticky_low;
    if (d == 5'd0) begin
      return 1'b0;
    end else begin
      dm1        = d - 5'd1;
      v_d        = v[d];
      v_dm1      = v[dm1];
      sticky_low = 1'b0;
      for (int k = 0; k < 32; k++) begin
        if (k < int'(dm1)) sticky_low |= v[k];
      end
      unique case (mode)
        2'b00:   return v_dm1;
        2'b01:   return v_dm1 & (sticky_low | v_d);
        2'b10:   return 1'b0;
        default: return (~v_d) & (v_dm1 | sticky_low);
      endcase
    end
  endfunction

  function automatic logic round_bit_w64(input logic [63:0] v, input logic [5:0] d, input vxrm_t mode);
    logic [5:0] dm1;
    logic       v_d, v_dm1, sticky_low;
    if (d == 6'd0) begin
      return 1'b0;
    end else begin
      dm1        = d - 6'd1;
      v_d        = v[d];
      v_dm1      = v[dm1];
      sticky_low = 1'b0;
      for (int k = 0; k < 64; k++) begin
        if (k < int'(dm1)) sticky_low |= v[k];
      end
      unique case (mode)
        2'b00:   return v_dm1;
        2'b01:   return v_dm1 & (sticky_low | v_d);
        2'b10:   return 1'b0;
        default: return (~v_d) & (v_dm1 | sticky_low);
      endcase
    end
  endfunction

  always_comb begin
    r_o = '0;
    if (valid_i) begin
      unique case (op_i)
        VSSRA, VSSRL: begin
          unique case (vew_i)
            EW8:  for (int i = 0; i < 8; i++) r_o[i] = round_bit_w8 (opb.w8 [i], opa.w8 [i][2:0], vxrm_i);
            EW16: for (int i = 0; i < 4; i++) r_o[i] = round_bit_w16(opb.w16[i], opa.w16[i][3:0], vxrm_i);
            EW32: for (int i = 0; i < 2; i++) r_o[i] = round_bit_w32(opb.w32[i], opa.w32[i][4:0], vxrm_i);
            EW64: for (int i = 0; i < 1; i++) r_o[i] = round_bit_w64(opb.w64[i], opa.w64[i][5:0], vxrm_i);
            default:;
          endcase
        end
        VNCLIP, VNCLIPU: begin
          unique case (vew_i)
            EW8:  for (int i = 0; i < 4; i++) r_o[i] = round_bit_w16(opb.w16[i], opa.w16[i][3:0], vxrm_i);
            EW16: for (int i = 0; i < 2; i++) r_o[i] = round_bit_w32(opb.w32[i], opa.w32[i][4:0], vxrm_i);
            EW32: for (int i = 0; i < 1; i++) r_o[i] = round_bit_w64(opb.w64[i], opa.w64[i][5:0], vxrm_i);
            default:;
          endcase
        end
        default: r_o = '0;
      endcase
    end
  end

endmodule : fixed_p_rounding
