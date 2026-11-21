// Copyright 2021 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

module simd_alu import ara_pkg::*; import rvv_pkg::*; #(
    parameter  fixpt_support_e FixPtSupport = FixedPointEnable,
    localparam int    unsigned DataWidth    = $bits(elen_t),
    localparam int    unsigned StrbWidth    = DataWidth/8,
    localparam type            strb_t       = logic [StrbWidth-1:0]
  ) (
    input  elen_t      operand_a_i,
    input  elen_t      operand_b_i,
    input  logic       valid_i,
    input  logic       vm_i,
    input  strb_t      mask_i,
    input  logic       narrowing_select_i,
    input  ara_op_e    op_i,
    input  vew_e       vew_i,
    output vxsat_t     vxsat_o,
    input  strb_t      rm,
    input  vxrm_t      vxrm_i,
    output elen_t      result_o
  );

  typedef union packed {
    logic [0:0][63:0] w64;
    logic [1:0][31:0] w32;
    logic [3:0][15:0] w16;
    logic [7:0][ 7:0] w8;
  } alu_operand_t;

  alu_operand_t opa, opb, res;
  assign opa      = operand_a_i;
  assign opb      = operand_b_i;
  assign result_o = res;

  vxsat_t vxsat;
  assign vxsat_o = vxsat;

  // Alternate gold: unified 8-byte carry-partitioned fixed-point add/sub network
  logic       fx_is_sub, fx_is_signed;
  logic [7:0] fx_subword_start;
  logic [7:0] fx_cin, fx_cout, fx_c7, fx_sgn_ovf;
  logic [7:0][7:0] fx_sum_byte;

  assign fx_is_sub    = op_i inside {VSSUB, VSSUBU, VASUB, VASUBU};
  assign fx_is_signed = op_i inside {VSADD, VSSUB, VAADD, VASUB};

  always_comb begin
    unique case (vew_i)
      EW8 : fx_subword_start = 8'b1111_1111;
      EW16: fx_subword_start = 8'b0101_0101;
      EW32: fx_subword_start = 8'b0001_0001;
      default: fx_subword_start = 8'b0000_0001;
    endcase

    for (int k = 0; k < 8; k++) begin
      automatic logic [7:0] a_eff = fx_is_sub ? ~opa.w8[k] : opa.w8[k];
      automatic logic [7:0] low7;
      automatic logic [1:0] top2;
      if (fx_subword_start[k]) begin
        fx_cin[k] = fx_is_sub ? 1'b1 : 1'b0;
      end else begin
        fx_cin[k] = fx_cout[k-1];
      end
      low7             = {1'b0, opb.w8[k][6:0]} + {1'b0, a_eff[6:0]} + {7'd0, fx_cin[k]};
      fx_c7[k]         = low7[7];
      top2             = {1'b0, opb.w8[k][7]} + {1'b0, a_eff[7]} + {1'b0, fx_c7[k]};
      fx_cout[k]       = top2[1];
      fx_sum_byte[k]   = {top2[0], low7[6:0]};
      fx_sgn_ovf[k]    = fx_c7[k] ^ fx_cout[k];
    end
  end

  function automatic logic avg_round(input logic b1, input logic b0, input vxrm_t mode);
    unique case (mode)
      2'b00:   return b0;
      2'b01:   return b0 & b1;
      2'b10:   return 1'b0;
      default: return (~b1) & b0;
    endcase
  endfunction

  logic is_signed;
  assign is_signed = op_i inside {VMAX, VREDMAX, VMIN, VREDMIN, VMSLT, VMSLE, VMSGT};

  logic [7:0] less;
  logic [7:0] equal;

  always_comb begin: p_comparison
    less  = '0;
    equal = '0;
    if (valid_i) begin
      unique case (vew_i)
        EW8 : for (int b = 0; b < 8; b++) less[1*b] =
            $signed({is_signed & opb.w8 [b][ 7], opb.w8 [b]}) <
            $signed({is_signed & opa.w8 [b][ 7], opa.w8 [b]});
        EW16: for (int b = 0; b < 4; b++) less[2*b] =
            $signed({is_signed & opb.w16[b][15], opb.w16[b]}) <
            $signed({is_signed & opa.w16[b][15], opa.w16[b]});
        EW32: for (int b = 0; b < 2; b++) less[4*b] =
            $signed({is_signed & opb.w32[b][31], opb.w32[b]}) <
            $signed({is_signed & opa.w32[b][31], opa.w32[b]});
        EW64: for (int b = 0; b < 1; b++) less[8*b] =
            $signed({is_signed & opb.w64[b][63], opb.w64[b]}) <
            $signed({is_signed & opa.w64[b][63], opa.w64[b]});
        default:;
      endcase
      unique case (vew_i)
        EW8 : for (int b = 0; b < 8; b++) equal[1*b] = opa.w8 [b] == opb.w8 [b];
        EW16: for (int b = 0; b < 4; b++) equal[2*b] = opa.w16[b] == opb.w16[b];
        EW32: for (int b = 0; b < 2; b++) equal[4*b] = opa.w32[b] == opb.w32[b];
        EW64: for (int b = 0; b < 1; b++) equal[8*b] = opa.w64[b] == opb.w64[b];
        default:;
      endcase
    end
  end : p_comparison

  always_comb begin: p_alu
    automatic elen_t fx_raw;
    fx_raw    = fx_sum_byte;
    res       = '0;
    vxsat.w64 = '0;

    if (valid_i)
      unique case (op_i)
        VAND, VREDAND: res = operand_a_i & operand_b_i;
        VOR, VREDOR  : res = operand_a_i | operand_b_i;
        VXOR, VREDXOR: res = operand_a_i ^ operand_b_i;

        VMAND   : res = operand_a_i & operand_b_i;
        VMANDNOT: res = ~operand_a_i & operand_b_i;
        VMNAND  : res = ~(operand_a_i & operand_b_i);
        VMOR    : res = operand_a_i | operand_b_i;
        VMNOR   : res = ~(operand_a_i | operand_b_i);
        VMORNOT : res = ~operand_a_i | operand_b_i;
        VMXOR   : res = operand_a_i ^ operand_b_i;
        VMXNOR  : res = ~(operand_a_i ^ operand_b_i);

        VCPOP, VFIRST, VMSBF, VMSOF, VMSIF, VIOTA: res = operand_b_i;
        VRGATHER, VRGATHEREI16, VCOMPRESS: res = operand_a_i;

        VSADDU, VSSUBU: if (FixPtSupport == FixedPointEnable) unique case (vew_i)
          EW8: for (int b = 0; b < 8; b++) begin
              automatic logic sat = fx_is_sub ? ~fx_cout[b] : fx_cout[b];
              vxsat.w8[b] = sat;
              res.w8[b]   = sat ? (fx_is_sub ? 8'h00 : 8'hFF) : fx_raw[8*b +: 8];
            end
          EW16: for (int b = 0; b < 4; b++) begin
              automatic logic sat = fx_is_sub ? ~fx_cout[2*b+1] : fx_cout[2*b+1];
              vxsat.w16[b] = {2{sat}};
              res.w16[b]   = sat ? (fx_is_sub ? 16'h0000 : 16'hFFFF) : fx_raw[16*b +: 16];
            end
          EW32: for (int b = 0; b < 2; b++) begin
              automatic logic sat = fx_is_sub ? ~fx_cout[4*b+3] : fx_cout[4*b+3];
              vxsat.w32[b] = {4{sat}};
              res.w32[b]   = sat ? (fx_is_sub ? 32'h0000_0000 : 32'hFFFF_FFFF) : fx_raw[32*b +: 32];
            end
          EW64: begin
              automatic logic sat = fx_is_sub ? ~fx_cout[7] : fx_cout[7];
              vxsat.w64[0] = {8{sat}};
              res.w64[0]   = sat ? (fx_is_sub ? 64'd0 : ~64'd0) : fx_raw;
            end
          default:;
        endcase

        VSADD, VSSUB: if (FixPtSupport == FixedPointEnable) unique case (vew_i)
          EW8: for (int b = 0; b < 8; b++) begin
              automatic logic sat = fx_sgn_ovf[b];
              vxsat.w8[b] = sat;
              res.w8[b]   = sat ? (opb.w8[b][7] ? 8'h80 : 8'h7F) : fx_raw[8*b +: 8];
            end
          EW16: for (int b = 0; b < 4; b++) begin
              automatic logic sat = fx_sgn_ovf[2*b+1];
              vxsat.w16[b] = {2{sat}};
              res.w16[b]   = sat ? (opb.w16[b][15] ? 16'h8000 : 16'h7FFF) : fx_raw[16*b +: 16];
            end
          EW32: for (int b = 0; b < 2; b++) begin
              automatic logic sat = fx_sgn_ovf[4*b+3];
              vxsat.w32[b] = {4{sat}};
              res.w32[b]   = sat ? (opb.w32[b][31] ? 32'h8000_0000 : 32'h7FFF_FFFF) : fx_raw[32*b +: 32];
            end
          EW64: begin
              automatic logic sat = fx_sgn_ovf[7];
              vxsat.w64[0] = {8{sat}};
              res.w64[0]   = sat ? (opb.w64[0][63] ? 64'h8000_0000_0000_0000 : 64'h7FFF_FFFF_FFFF_FFFF) : fx_raw;
            end
          default:;
        endcase

        VAADD, VAADDU, VASUB, VASUBU: if (FixPtSupport == FixedPointEnable) unique case (vew_i)
          EW8: for (int b = 0; b < 8; b++) begin
              automatic logic top_b = fx_is_signed ? (fx_sum_byte[b][7] ^ fx_sgn_ovf[b])
                                                   : (fx_is_sub ? ~fx_cout[b] : fx_cout[b]);
              automatic logic rbit  = avg_round(fx_raw[8*b+1], fx_raw[8*b], vxrm_i);
              res.w8[b] = {top_b, fx_raw[8*b+7 -: 7]} + {7'd0, rbit};
            end
          EW16: for (int b = 0; b < 4; b++) begin
              automatic logic top_b = fx_is_signed ? (fx_sum_byte[2*b+1][7] ^ fx_sgn_ovf[2*b+1])
                                                   : (fx_is_sub ? ~fx_cout[2*b+1] : fx_cout[2*b+1]);
              automatic logic rbit  = avg_round(fx_raw[16*b+1], fx_raw[16*b], vxrm_i);
              res.w16[b] = {top_b, fx_raw[16*b+15 -: 15]} + {15'd0, rbit};
            end
          EW32: for (int b = 0; b < 2; b++) begin
              automatic logic top_b = fx_is_signed ? (fx_sum_byte[4*b+3][7] ^ fx_sgn_ovf[4*b+3])
                                                   : (fx_is_sub ? ~fx_cout[4*b+3] : fx_cout[4*b+3]);
              automatic logic rbit  = avg_round(fx_raw[32*b+1], fx_raw[32*b], vxrm_i);
              res.w32[b] = {top_b, fx_raw[32*b+31 -: 31]} + {31'd0, rbit};
            end
          EW64: begin
              automatic logic top_b = fx_is_signed ? (fx_sum_byte[7][7] ^ fx_sgn_ovf[7])
                                                   : (fx_is_sub ? ~fx_cout[7] : fx_cout[7]);
              automatic logic rbit  = avg_round(fx_raw[1], fx_raw[0], vxrm_i);
              res.w64[0] = {top_b, fx_raw[63:1]} + {63'd0, rbit};
            end
          default:;
        endcase

        VADD, VADC, VMADC, VREDSUM, VWREDSUMU, VWREDSUM: unique case (vew_i)
            EW8: for (int b = 0; b < 8; b++) begin
                automatic logic [8:0] sum = opa.w8[b] + opb.w8[b] +
                logic'(op_i inside {VADC, VMADC} && mask_i[1*b] & ~vm_i);
                res.w8[b] = (op_i == VMADC) ? {6'b0, 1'b1, sum[8]} : sum[7:0];
              end
            EW16: for (int b = 0; b < 4; b++) begin
                automatic logic [16:0] sum = opa.w16[b] + opb.w16[b] +
                logic'(op_i inside {VADC, VMADC} && mask_i[2*b] & ~vm_i);
                res.w16[b] = (op_i == VMADC) ? {14'b0, 1'b1, sum[16]} : sum[15:0];
              end
            EW32: for (int b = 0; b < 2; b++) begin
                automatic logic [32:0] sum = opa.w32[b] + opb.w32[b] +
                logic'(op_i inside {VADC, VMADC} && mask_i[4*b] & ~vm_i);
                res.w32[b] = (op_i == VMADC) ? {30'b0, 1'b1, sum[32]} : sum[31:0];
              end
            EW64: for (int b = 0; b < 1; b++) begin
                automatic logic [64:0] sum = opa.w64[b] + opb.w64[b] +
                logic'(op_i inside {VADC, VMADC} && mask_i[8*b] & ~vm_i);
                res.w64[b] = (op_i == VMADC) ? {62'b0, 1'b1, sum[64]} : sum[63:0];
              end
            default:;
          endcase

        VSUB, VSBC, VMSBC: unique case (vew_i)
            EW8: for (int b = 0; b < 8; b++) begin
                automatic logic [8:0] sub = opb.w8[b] - opa.w8[b] -
                logic'(op_i inside {VSBC, VMSBC} && mask_i[1*b] & ~vm_i);
                res.w8[b] = (op_i == VMSBC) ? {6'b0, 1'b1, sub[8]} : sub[7:0];
              end
            EW16: for (int b = 0; b < 4; b++) begin
                automatic logic [16:0] sub = opb.w16[b] - opa.w16[b] -
                logic'(op_i inside {VSBC, VMSBC} && mask_i[2*b] & ~vm_i);
                res.w16[b] = (op_i == VMSBC) ? {14'b0, 1'b1, sub[16]} : sub[15:0];
              end
            EW32: for (int b = 0; b < 2; b++) begin
                automatic logic [32:0] sub = opb.w32[b] - opa.w32[b] -
                logic'(op_i inside {VSBC, VMSBC} && mask_i[4*b] & ~vm_i);
                res.w32[b] = (op_i == VMSBC) ? {30'b0, 1'b1, sub[32]} : sub[31:0];
              end
            EW64: for (int b = 0; b < 1; b++) begin
                automatic logic [64:0] sub = opb.w64[b] - opa.w64[b] -
                logic'(op_i inside {VSBC, VMSBC} && mask_i[8*b] & ~vm_i);
                res.w64[b] = (op_i == VMSBC) ? {62'b0, 1'b1, sub[64]} : sub[63:0];
              end
            default:;
          endcase

        VRSUB: unique case (vew_i)
            EW8 : for (int b = 0; b < 8; b++) res.w8 [b] = opa.w8 [b] - opb.w8 [b];
            EW16: for (int b = 0; b < 4; b++) res.w16[b] = opa.w16[b] - opb.w16[b];
            EW32: for (int b = 0; b < 2; b++) res.w32[b] = opa.w32[b] - opb.w32[b];
            EW64: for (int b = 0; b < 1; b++) res.w64[b] = opa.w64[b] - opb.w64[b];
            default:;
          endcase

        VSLL: unique case (vew_i)
            EW8 : for (int b = 0; b < 8; b++) res.w8 [b] = opb.w8 [b] << opa.w8 [b][2:0];
            EW16: for (int b = 0; b < 4; b++) res.w16[b] = opb.w16[b] << opa.w16[b][3:0];
            EW32: for (int b = 0; b < 2; b++) res.w32[b] = opb.w32[b] << opa.w32[b][4:0];
            EW64: for (int b = 0; b < 1; b++) res.w64[b] = opb.w64[b] << opa.w64[b][5:0];
            default:;
          endcase
        VSRL: unique case (vew_i)
            EW8 : for (int b = 0; b < 8; b++) res.w8 [b] = opb.w8 [b] >> opa.w8 [b][2:0];
            EW16: for (int b = 0; b < 4; b++) res.w16[b] = opb.w16[b] >> opa.w16[b][3:0];
            EW32: for (int b = 0; b < 2; b++) res.w32[b] = opb.w32[b] >> opa.w32[b][4:0];
            EW64: for (int b = 0; b < 1; b++) res.w64[b] = opb.w64[b] >> opa.w64[b][5:0];
            default:;
          endcase
        VSRA: unique case (vew_i)
            EW8 : for (int b = 0; b < 8; b++) res.w8 [b] = $signed(opb.w8 [b]) >>> opa.w8 [b][2:0];
            EW16: for (int b = 0; b < 4; b++) res.w16[b] = $signed(opb.w16[b]) >>> opa.w16[b][3:0];
            EW32: for (int b = 0; b < 2; b++) res.w32[b] = $signed(opb.w32[b]) >>> opa.w32[b][4:0];
            EW64: for (int b = 0; b < 1; b++) res.w64[b] = $signed(opb.w64[b]) >>> opa.w64[b][5:0];
            default:;
          endcase
        VNSRL: unique case (vew_i)
            EW8 : for (int b = 0; b < 4; b++) res.w8 [2*b + narrowing_select_i] = opb.w16[b] >> opa.w16[b][3:0];
            EW16: for (int b = 0; b < 2; b++) res.w16[2*b + narrowing_select_i] = opb.w32[b] >> opa.w32[b][4:0];
            EW32: for (int b = 0; b < 1; b++) res.w32[2*b + narrowing_select_i] = opb.w64[b] >> opa.w64[b][5:0];
            default:;
          endcase
        VNSRA: unique case (vew_i)
            EW8 : for (int b = 0; b < 4; b++) res.w8 [2*b + narrowing_select_i] = $signed(opb.w16[b]) >>> opa.w16[b][3:0];
            EW16: for (int b = 0; b < 2; b++) res.w16[2*b + narrowing_select_i] = $signed(opb.w32[b]) >>> opa.w32[b][4:0];
            EW32: for (int b = 0; b < 1; b++) res.w32[2*b + narrowing_select_i] = $signed(opb.w64[b]) >>> opa.w64[b][5:0];
            default:;
          endcase

        VSSRA: if (FixPtSupport == FixedPointEnable) unique case (vew_i)
            EW8 : for (int b = 0; b < 8; b++) begin automatic logic signed [7:0]  sh = $signed(opb.w8 [b]) >>> opa.w8 [b][2:0]; res.w8 [b] = sh + {7'd0,  rm[b]}; end
            EW16: for (int b = 0; b < 4; b++) begin automatic logic signed [15:0] sh = $signed(opb.w16[b]) >>> opa.w16[b][3:0]; res.w16[b] = sh + {15'd0, rm[b]}; end
            EW32: for (int b = 0; b < 2; b++) begin automatic logic signed [31:0] sh = $signed(opb.w32[b]) >>> opa.w32[b][4:0]; res.w32[b] = sh + {31'd0, rm[b]}; end
            EW64: for (int b = 0; b < 1; b++) begin automatic logic signed [63:0] sh = $signed(opb.w64[b]) >>> opa.w64[b][5:0]; res.w64[b] = sh + {63'd0, rm[b]}; end
            default:;
          endcase

        VSSRL: if (FixPtSupport == FixedPointEnable) unique case (vew_i)
            EW8 : for (int b = 0; b < 8; b++) res.w8 [b] = (opb.w8 [b] >> opa.w8 [b][2:0]) + {7'd0,  rm[b]};
            EW16: for (int b = 0; b < 4; b++) res.w16[b] = (opb.w16[b] >> opa.w16[b][3:0]) + {15'd0, rm[b]};
            EW32: for (int b = 0; b < 2; b++) res.w32[b] = (opb.w32[b] >> opa.w32[b][4:0]) + {31'd0, rm[b]};
            EW64: for (int b = 0; b < 1; b++) res.w64[b] = (opb.w64[b] >> opa.w64[b][5:0]) + {63'd0, rm[b]};
            default:;
          endcase

        VNCLIP: if (FixPtSupport == FixedPointEnable) unique case (vew_i)
            EW8: for (int b = 0; b < 4; b++) begin
                automatic logic signed [15:0] sh  = $signed(opb.w16[b]) >>> opa.w16[b][3:0];
                automatic logic signed [16:0] val = $signed({sh[15], sh}) + $signed({16'd0, rm[b]});
                automatic int unsigned slot = 2*b + int'(narrowing_select_i);
                if (val > 17'sd127) begin
                  res.w8[slot]   = 8'h7F;
                  vxsat.w8[slot] = 1'b1;
                end else if (val < -17'sd128) begin
                  res.w8[slot]   = 8'h80;
                  vxsat.w8[slot] = 1'b1;
                end else begin
                  res.w8[slot]   = val[7:0];
                  vxsat.w8[slot] = 1'b0;
                end
              end
            EW16: for (int b = 0; b < 2; b++) begin
                automatic logic signed [31:0] sh  = $signed(opb.w32[b]) >>> opa.w32[b][4:0];
                automatic logic signed [32:0] val = $signed({sh[31], sh}) + $signed({32'd0, rm[b]});
                automatic int unsigned slot = 2*b + int'(narrowing_select_i);
                if (val > 33'sd32767) begin
                  res.w16[slot]   = 16'h7FFF;
                  vxsat.w16[slot] = 2'b11;
                end else if (val < -33'sd32768) begin
                  res.w16[slot]   = 16'h8000;
                  vxsat.w16[slot] = 2'b11;
                end else begin
                  res.w16[slot]   = val[15:0];
                  vxsat.w16[slot] = 2'b00;
                end
              end
            EW32: begin
                automatic logic signed [63:0] sh  = $signed(opb.w64[0]) >>> opa.w64[0][5:0];
                automatic logic signed [64:0] val = $signed({sh[63], sh}) + $signed({64'd0, rm[0]});
                automatic int unsigned slot = int'(narrowing_select_i);
                if (val > 65'sh0_0000_0000_7FFF_FFFF) begin
                  res.w32[slot]   = 32'h7FFF_FFFF;
                  vxsat.w32[slot] = 4'hF;
                end else if (val < -65'sh0_0000_0000_8000_0000) begin
                  res.w32[slot]   = 32'h8000_0000;
                  vxsat.w32[slot] = 4'hF;
                end else begin
                  res.w32[slot]   = val[31:0];
                  vxsat.w32[slot] = 4'h0;
                end
              end
            default:;
          endcase

        VNCLIPU: if (FixPtSupport == FixedPointEnable) unique case (vew_i)
            EW8: for (int b = 0; b < 4; b++) begin
                automatic logic [16:0] val = {1'b0, (opb.w16[b] >> opa.w16[b][3:0])} + {16'd0, rm[b]};
                automatic int unsigned slot = 2*b + int'(narrowing_select_i);
                vxsat.w8[slot] = |val[16:8];
                res.w8  [slot] = (|val[16:8]) ? 8'hFF : val[7:0];
              end
            EW16: for (int b = 0; b < 2; b++) begin
                automatic logic [32:0] val = {1'b0, (opb.w32[b] >> opa.w32[b][4:0])} + {32'd0, rm[b]};
                automatic int unsigned slot = 2*b + int'(narrowing_select_i);
                vxsat.w16[slot] = {2{|val[32:16]}};
                res.w16  [slot] = (|val[32:16]) ? 16'hFFFF : val[15:0];
              end
            EW32: begin
                automatic logic [64:0] val = {1'b0, (opb.w64[0] >> opa.w64[0][5:0])} + {64'd0, rm[0]};
                automatic int unsigned slot = int'(narrowing_select_i);
                vxsat.w32[slot] = {4{|val[64:32]}};
                res.w32  [slot] = (|val[64:32]) ? 32'hFFFF_FFFF : val[31:0];
              end
            default:;
          endcase

        VMERGE: unique case (vew_i)
            EW8 : for (int b = 0; b < 8; b++) res.w8 [b] = mask_i[1*b] ? opa.w8 [b] : opb.w8 [b];
            EW16: for (int b = 0; b < 4; b++) res.w16[b] = mask_i[2*b] ? opa.w16[b] : opb.w16[b];
            EW32: for (int b = 0; b < 2; b++) res.w32[b] = mask_i[4*b] ? opa.w32[b] : opb.w32[b];
            EW64: for (int b = 0; b < 1; b++) res.w64[b] = mask_i[8*b] ? opa.w64[b] : opb.w64[b];
            default:;
          endcase

        VMVSX, VFMVSF: res = opa;

        VMIN, VMINU, VMAX, VMAXU,
        VREDMINU, VREDMIN, VREDMAXU, VREDMAX: unique case (vew_i)
            EW8 : for (int b = 0; b < 8; b++) res.w8 [b] =
                (less[1*b] ^ (op_i == VMAX || op_i == VMAXU || op_i == VREDMAXU || op_i == VREDMAX)) ? opb.w8 [b] : opa.w8 [b];
            EW16: for (int b = 0; b < 4; b++) res.w16[b] =
                (less[2*b] ^ (op_i == VMAX || op_i == VMAXU || op_i == VREDMAXU || op_i == VREDMAX)) ? opb.w16[b] : opa.w16[b];
            EW32: for (int b = 0; b < 2; b++) res.w32[b] =
                (less[4*b] ^ (op_i == VMAX || op_i == VMAXU || op_i == VREDMAXU || op_i == VREDMAX)) ? opb.w32[b] : opa.w32[b];
            EW64: for (int b = 0; b < 1; b++) res.w64[b] =
                (less[8*b] ^ (op_i == VMAX || op_i == VMAXU || op_i == VREDMAXU || op_i == VREDMAX)) ? opb.w64[b] : opa.w64[b];
            default:;
          endcase
        VMSEQ, VMSNE: unique case (vew_i)
            EW8 : for (int b = 0; b < 8; b++) res.w8 [b][1:0] =
                {mask_i[1*b], equal[1*b] ^ (op_i == VMSNE)};
            EW16: for (int b = 0; b < 4; b++) res.w16[b][1:0] =
                {mask_i[2*b], equal[2*b] ^ (op_i == VMSNE)};
            EW32: for (int b = 0; b < 2; b++) res.w32[b][1:0] =
                {mask_i[4*b], equal[4*b] ^ (op_i == VMSNE)};
            EW64: for (int b = 0; b < 1; b++) res.w64[b][1:0] =
                {mask_i[8*b], equal[8*b] ^ (op_i == VMSNE)};
            default:;
          endcase
        VMSLT, VMSLTU: unique case (vew_i)
            EW8 : for (int b = 0; b < 8; b++) res.w8 [b][1:0] = {mask_i[1*b], less[1*b]};
            EW16: for (int b = 0; b < 4; b++) res.w16[b][1:0] = {mask_i[2*b], less[2*b]};
            EW32: for (int b = 0; b < 2; b++) res.w32[b][1:0] = {mask_i[4*b], less[4*b]};
            EW64: for (int b = 0; b < 1; b++) res.w64[b][1:0] = {mask_i[8*b], less[8*b]};
            default:;
          endcase
        VMSLE, VMSLEU, VMSGT, VMSGTU: unique case (vew_i)
            EW8 : for (int b = 0; b < 8; b++) res.w8 [b][1:0] =
                {mask_i[1*b], (less[1*b] || equal[1*b]) ^ (op_i inside {VMSGT, VMSGTU})};
            EW16: for (int b = 0; b < 4; b++) res.w16[b][1:0] =
                {mask_i[2*b], (less[2*b] || equal[2*b]) ^ (op_i inside {VMSGT, VMSGTU})};
            EW32: for (int b = 0; b < 2; b++) res.w32[b][1:0] =
                {mask_i[4*b], (less[4*b] || equal[4*b]) ^ (op_i inside {VMSGT, VMSGTU})};
            EW64: for (int b = 0; b < 1; b++) res.w64[b][1:0] =
                {mask_i[8*b], (less[8*b] || equal[8*b]) ^ (op_i inside {VMSGT, VMSGTU})};
            default:;
          endcase

        default:;
      endcase
  end : p_alu

endmodule : simd_alu
