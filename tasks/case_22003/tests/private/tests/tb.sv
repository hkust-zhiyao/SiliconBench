// Copyright 2021 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// Comprehensive self-checking verification testbench for case_22003 (Ara lane integer VMFPU + SIMD Divider).

`timescale 1ns/1ps

module tb;
  import ara_pkg::*;
  import rvv_pkg::*;
  import fpnew_pkg::*;
  import vmfpu_synth_pkg::*;

  logic                                       clk_i = 1'b0;
  logic                                       rst_ni = 1'b0;
  logic [cf_math_pkg::idx_width(NrLanes)-1:0] lane_id_i = '0;
  logic                                       mfpu_vxsat_o;
  vxrm_t                                      mfpu_vxrm_i = '0;
  logic [4:0]                                 fflags_ex_o;
  logic                                       fflags_ex_valid_o;
  vfu_operation_t                             vfu_operation_i = '0;
  logic                                       vfu_operation_valid_i = 1'b0;
  logic                                       mfpu_ready_o;
  logic [NrVInsn-1:0]                         mfpu_vinsn_done_o;
  logic                                       fpu_red_complete_o;
  elen_t [2:0]                                mfpu_operand_i = '0;
  logic  [2:0]                                mfpu_operand_valid_i = '0;
  logic  [2:0]                                mfpu_operand_ready_o;
  logic                                       mfpu_result_req_o;
  vid_t                                       mfpu_result_id_o;
  vaddr_t                                     mfpu_result_addr_o;
  elen_t                                      mfpu_result_wdata_o;
  logic [7:0]                                 mfpu_result_be_o;
  logic                                       mfpu_result_gnt_i = 1'b0;
  logic                                       mfpu_red_valid_o;
  logic                                       mfpu_red_ready_i = 1'b0;
  elen_t                                      sldu_operand_i = '0;
  logic                                       sldu_mfpu_valid_i = 1'b0;
  logic                                       sldu_mfpu_ready_o;
  elen_t                                      mask_operand_o;
  logic                                       mask_operand_valid_o;
  logic                                       mask_operand_ready_i = 1'b0;
  logic [7:0]                                 mask_i = '0;
  logic                                       mask_valid_i = 1'b0;
  logic                                       mask_ready_o;

  always #2.5 clk_i = ~clk_i;

  vmfpu_synth_top dut (
    .clk_i                (clk_i                ),
    .rst_ni               (rst_ni               ),
    .lane_id_i            (lane_id_i            ),
    .mfpu_vxsat_o         (mfpu_vxsat_o         ),
    .mfpu_vxrm_i          (mfpu_vxrm_i          ),
    .fflags_ex_o          (fflags_ex_o          ),
    .fflags_ex_valid_o    (fflags_ex_valid_o    ),
    .vfu_operation_i      (vfu_operation_i      ),
    .vfu_operation_valid_i(vfu_operation_valid_i),
    .mfpu_ready_o         (mfpu_ready_o         ),
    .mfpu_vinsn_done_o    (mfpu_vinsn_done_o    ),
    .fpu_red_complete_o   (fpu_red_complete_o   ),
    .mfpu_operand_i       (mfpu_operand_i       ),
    .mfpu_operand_valid_i (mfpu_operand_valid_i ),
    .mfpu_operand_ready_o (mfpu_operand_ready_o ),
    .mfpu_result_req_o    (mfpu_result_req_o    ),
    .mfpu_result_id_o     (mfpu_result_id_o     ),
    .mfpu_result_addr_o   (mfpu_result_addr_o   ),
    .mfpu_result_wdata_o  (mfpu_result_wdata_o  ),
    .mfpu_result_be_o     (mfpu_result_be_o     ),
    .mfpu_result_gnt_i    (mfpu_result_gnt_i    ),
    .mfpu_red_valid_o     (mfpu_red_valid_o     ),
    .mfpu_red_ready_i     (mfpu_red_ready_i     ),
    .sldu_operand_i       (sldu_operand_i       ),
    .sldu_mfpu_valid_i    (sldu_mfpu_valid_i    ),
    .sldu_mfpu_ready_o    (sldu_mfpu_ready_o    ),
    .mask_operand_o       (mask_operand_o       ),
    .mask_operand_valid_o (mask_operand_valid_o ),
    .mask_operand_ready_i (mask_operand_ready_i ),
    .mask_i               (mask_i               ),
    .mask_valid_i         (mask_valid_i         ),
    .mask_ready_o         (mask_ready_o         )
  );

  // =========================================================================
  // Golden Reference Arithmetic Model (exact RVV 1.0 + Ara lane semantics)
  // =========================================================================

  function automatic void ref_compute_beat(
    input  ara_op_e    op,
    input  vew_e       sew,
    input  vxrm_t      vxrm,
    input  elen_t      op0_raw,
    input  elen_t      op1_raw,
    input  elen_t      op2_raw,
    input  elen_t      scalar_raw,
    input  logic       use_scalar,
    input  logic [7:0] entry_be,
    output elen_t      exp_wdata,
    output logic       exp_vxsat
  );
    elen_t scalar_rep;
    elen_t mul_a, mul_b, mul_c;
    elen_t div_a, div_b;
    logic  signed_a, signed_b;
    logic [7:0] sat_vec;

    unique case (sew)
      EW64   : scalar_rep = scalar_raw;
      EW32   : scalar_rep = {2{scalar_raw[31:0]}};
      EW16   : scalar_rep = {4{scalar_raw[15:0]}};
      default: scalar_rep = {8{scalar_raw[ 7:0]}};
    endcase

    mul_a = use_scalar ? scalar_rep : op0_raw;
    mul_b = op1_raw;
    mul_c = op2_raw;

    div_a = op1_raw;
    div_b = use_scalar ? scalar_rep : op0_raw;

    exp_wdata = '0;
    sat_vec   = '0;

    if (op inside {[VMUL:VSMUL]}) begin
      signed_a = (op inside {VMULH, VSMUL});
      signed_b = (op inside {VMULH, VMULHSU, VSMUL});

      unique case (sew)
        EW64: begin
          logic [127:0] prod;
          logic         rnd;
          prod = 128'($signed({mul_a[63] & signed_a, mul_a}) * $signed({mul_b[63] & signed_b, mul_b}));
          rnd  = 1'b0;
          unique case (op)
            VMUL: exp_wdata = prod[63:0];
            VSMUL: begin
              unique case (vxrm)
                2'b00: rnd = prod[62];
                2'b01: rnd = prod[62] & ((prod[61:0] != '0) | prod[63]);
                2'b10: rnd = 1'b0;
                2'b11: rnd = !prod[63] & (prod[62:0] != '0);
              endcase
              exp_wdata  = prod[126:63] + 64'(rnd);
              sat_vec[0] = exp_wdata[63] ^ prod[127];
            end
            VMULH, VMULHU, VMULHSU: exp_wdata = prod[127:64];
            VMACC, VMADD          : exp_wdata = prod[63:0] + mul_c;
            VNMSAC, VNMSUB        : exp_wdata = -prod[63:0] + mul_c;
            default               : exp_wdata = '0;
          endcase
        end

        EW32: begin
          for (int l = 0; l < 2; l++) begin
            logic [31:0] a32, b32, c32, res32;
            logic [63:0] prod;
            logic        rnd;
            a32  = mul_a[32*l +: 32];
            b32  = mul_b[32*l +: 32];
            c32  = mul_c[32*l +: 32];
            prod = 64'($signed({a32[31] & signed_a, a32}) * $signed({b32[31] & signed_b, b32}));
            rnd  = 1'b0;
            res32 = '0;
            unique case (op)
              VMUL: res32 = prod[31:0];
              VSMUL: begin
                unique case (vxrm)
                  2'b00: rnd = prod[30];
                  2'b01: rnd = prod[30] & ((prod[29:0] != '0) | prod[31]);
                  2'b10: rnd = 1'b0;
                  2'b11: rnd = !prod[31] & (prod[30:0] != '0);
                endcase
                res32        = prod[62:31] + 32'(rnd);
                sat_vec[4*l] = res32[31] ^ prod[63];
              end
              VMULH, VMULHU, VMULHSU: res32 = prod[63:32];
              VMACC, VMADD          : res32 = prod[31:0] + c32;
              VNMSAC, VNMSUB        : res32 = -prod[31:0] + c32;
              default               : res32 = '0;
            endcase
            exp_wdata[32*l +: 32] = res32;
          end
        end

        EW16: begin
          for (int l = 0; l < 4; l++) begin
            logic [15:0] a16, b16, c16, res16;
            logic [31:0] prod;
            logic        rnd;
            a16  = mul_a[16*l +: 16];
            b16  = mul_b[16*l +: 16];
            c16  = mul_c[16*l +: 16];
            prod = 32'($signed({a16[15] & signed_a, a16}) * $signed({b16[15] & signed_b, b16}));
            rnd  = 1'b0;
            res16 = '0;
            unique case (op)
              VMUL: res16 = prod[15:0];
              VSMUL: begin
                // Note: matches Ara simd_mul.sv EW16 shift >> 16
                unique case (vxrm)
                  2'b00: rnd = prod[14];
                  2'b01: rnd = prod[14] & ((prod[13:0] != '0) | prod[15]);
                  2'b10: rnd = 1'b0;
                  2'b11: rnd = !prod[15] & (prod[14:0] != '0);
                endcase
                res16        = prod[31:16] + 16'(rnd);
                sat_vec[2*l] = res16[15] ^ prod[31];
              end
              VMULH, VMULHU, VMULHSU: res16 = prod[31:16];
              VMACC, VMADD          : res16 = prod[15:0] + c16;
              VNMSAC, VNMSUB        : res16 = -prod[15:0] + c16;
              default               : res16 = '0;
            endcase
            exp_wdata[16*l +: 16] = res16;
          end
        end

        default: begin // EW8
          for (int l = 0; l < 8; l++) begin
            logic [ 7:0] a8, b8, c8, res8;
            logic [15:0] prod;
            logic        rnd;
            a8   = mul_a[8*l +: 8];
            b8   = mul_b[8*l +: 8];
            c8   = mul_c[8*l +: 8];
            prod = 16'($signed({a8[7] & signed_a, a8}) * $signed({b8[7] & signed_b, b8}));
            rnd  = 1'b0;
            res8 = '0;
            unique case (op)
              VMUL: res8 = prod[7:0];
              VSMUL: begin
                unique case (vxrm)
                  2'b00: rnd = prod[6];
                  2'b01: rnd = prod[6] & ((prod[5:0] != '0) | prod[7]);
                  2'b10: rnd = 1'b0;
                  2'b11: rnd = !prod[7] & (prod[6:0] != '0);
                endcase
                res8       = prod[14:7] + 8'(rnd);
                sat_vec[l] = res8[7] ^ prod[15];
              end
              VMULH, VMULHU, VMULHSU: res8 = prod[15:8];
              VMACC, VMADD          : res8 = prod[7:0] + c8;
              VNMSAC, VNMSUB        : res8 = -prod[7:0] + c8;
              default               : res8 = '0;
            endcase
            exp_wdata[8*l +: 8] = res8;
          end
        end
      endcase
    end else begin
      // Division / Remainder (RVV 1.0 exact semantics)
      unique case (sew)
        EW64: begin
          if (entry_be[0]) begin
            unique case (op)
              VDIVU: exp_wdata = (div_b == '0) ? 64'hFFFF_FFFF_FFFF_FFFF : (div_a / div_b);
              VREMU: exp_wdata = (div_b == '0) ? div_a                   : (div_a % div_b);
              VDIV : exp_wdata = (div_b == '0) ? 64'hFFFF_FFFF_FFFF_FFFF :
                                 ((div_a == 64'h8000_0000_0000_0000 && div_b == 64'hFFFF_FFFF_FFFF_FFFF) ?
                                  64'h8000_0000_0000_0000 : 64'($signed(div_a) / $signed(div_b)));
              VREM : exp_wdata = (div_b == '0) ? div_a :
                                 ((div_a == 64'h8000_0000_0000_0000 && div_b == 64'hFFFF_FFFF_FFFF_FFFF) ?
                                  64'h0 : 64'($signed(div_a) % $signed(div_b)));
              default: exp_wdata = '0;
            endcase
          end
        end

        EW32: begin
          for (int l = 0; l < 2; l++) begin
            if (entry_be[4*l]) begin
              logic [31:0] a32, b32, r32;
              a32 = div_a[32*l +: 32];
              b32 = div_b[32*l +: 32];
              unique case (op)
                VDIVU: r32 = (b32 == '0) ? 32'hFFFF_FFFF : (a32 / b32);
                VREMU: r32 = (b32 == '0) ? a32           : (a32 % b32);
                VDIV : r32 = (b32 == '0) ? 32'hFFFF_FFFF :
                             ((a32 == 32'h8000_0000 && b32 == 32'hFFFF_FFFF) ?
                              32'h8000_0000 : 32'($signed(a32) / $signed(b32)));
                VREM : r32 = (b32 == '0) ? a32 :
                             ((a32 == 32'h8000_0000 && b32 == 32'hFFFF_FFFF) ?
                              32'h0 : 32'($signed(a32) % $signed(b32)));
                default: r32 = '0;
              endcase
              exp_wdata[32*l +: 32] = r32;
            end
          end
        end

        EW16: begin
          for (int l = 0; l < 4; l++) begin
            if (entry_be[2*l]) begin
              logic [15:0] a16, b16, r16;
              a16 = div_a[16*l +: 16];
              b16 = div_b[16*l +: 16];
              unique case (op)
                VDIVU: r16 = (b16 == '0) ? 16'hFFFF : (a16 / b16);
                VREMU: r16 = (b16 == '0) ? a16      : (a16 % b16);
                VDIV : r16 = (b16 == '0) ? 16'hFFFF :
                             ((a16 == 16'h8000 && b16 == 16'hFFFF) ?
                              16'h8000 : 16'($signed(a16) / $signed(b16)));
                VREM : r16 = (b16 == '0) ? a16 :
                             ((a16 == 16'h8000 && b16 == 16'hFFFF) ?
                              16'h0 : 16'($signed(a16) % $signed(b16)));
                default: r16 = '0;
              endcase
              exp_wdata[16*l +: 16] = r16;
            end
          end
        end

        default: begin // EW8
          for (int l = 0; l < 8; l++) begin
            if (entry_be[l]) begin
              logic [7:0] a8, b8, r8;
              a8 = div_a[8*l +: 8];
              b8 = div_b[8*l +: 8];
              unique case (op)
                VDIVU: r8 = (b8 == '0) ? 8'hFF : (a8 / b8);
                VREMU: r8 = (b8 == '0) ? a8    : (a8 % b8);
                VDIV : r8 = (b8 == '0) ? 8'hFF :
                            ((a8 == 8'h80 && b8 == 8'hFF) ?
                             8'h80 : 8'($signed(a8) / $signed(b8)));
                VREM : r8 = (b8 == '0) ? a8 :
                            ((a8 == 8'h80 && b8 == 8'hFF) ?
                             8'h0 : 8'($signed(a8) % $signed(b8)));
                default: r8 = '0;
              endcase
              exp_wdata[8*l +: 8] = r8;
            end
          end
        end
      endcase
    end

    exp_vxsat = (op == VSMUL) ? (|(sat_vec & entry_be)) : 1'b0;
  endfunction

  // =========================================================================
  // Streaming Queues & Scoreboard Monitors
  // =========================================================================

  typedef struct {
    vid_t       id;
    vaddr_t     addr;
    elen_t      wdata;
    logic [7:0] be;
    logic       vxsat;
    logic       is_last;
  } exp_res_t;

  elen_t      op_buf0[0:8191], op_buf1[0:8191], op_buf2[0:8191];
  logic [7:0] mask_buf[0:8191];
  int         op0_wr = 0, op1_wr = 0, op2_wr = 0, mask_wr = 0;
  int         op0_rd_q = 0, op1_rd_q = 0, op2_rd_q = 0, mask_rd_q = 0;
  exp_res_t   exp_res_q[$];
  vid_t       exp_done_q[$];

  logic       stall_enable = 1'b0;
  int         err_cnt      = 0;
  int         checked_beats = 0;
  int         checked_insns = 0;
  int         global_cycle_cnt = 0;
  int         last_done_cycle  = 0;
  int unsigned rng_state   = 32'h12345678;

  function automatic int unsigned next_rand();
    rng_state = rng_state ^ (rng_state << 13);
    rng_state = rng_state ^ (rng_state >> 17);
    rng_state = rng_state ^ (rng_state << 5);
    return rng_state;
  endfunction

  function automatic elen_t rand64();
    return {next_rand(), next_rand()};
  endfunction

  logic [2:0] stall_op_mask;
  logic       stall_mask_bit;
  logic       stall_gnt_bit;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      stall_op_mask  <= 3'b111;
      stall_mask_bit <= 1'b1;
      stall_gnt_bit  <= 1'b1;
    end else if (stall_enable) begin
      int unsigned r;
      r = next_rand();
      stall_op_mask[0] <= (r[1:0] != 2'b00);
      stall_op_mask[1] <= (r[3:2] != 2'b00);
      stall_op_mask[2] <= (r[5:4] != 2'b00);
      stall_mask_bit   <= (r[7:6] != 2'b00);
      stall_gnt_bit    <= (r[9:8] != 2'b00);
    end else begin
      stall_op_mask  <= 3'b111;
      stall_mask_bit <= 1'b1;
      stall_gnt_bit  <= 1'b1;
    end
  end

  always_comb begin
    mfpu_operand_valid_i[0] = (op0_rd_q < op0_wr) & stall_op_mask[0];
    mfpu_operand_valid_i[1] = (op1_rd_q < op1_wr) & stall_op_mask[1];
    mfpu_operand_valid_i[2] = (op2_rd_q < op2_wr) & stall_op_mask[2];
    mfpu_operand_i[0]       = (op0_rd_q < op0_wr) ? op_buf0[op0_rd_q] : 64'hDEAD_BEEF_CAFE_0000;
    mfpu_operand_i[1]       = (op1_rd_q < op1_wr) ? op_buf1[op1_rd_q] : 64'hDEAD_BEEF_CAFE_1111;
    mfpu_operand_i[2]       = (op2_rd_q < op2_wr) ? op_buf2[op2_rd_q] : 64'hDEAD_BEEF_CAFE_2222;

    mask_valid_i            = (mask_rd_q < mask_wr) & stall_mask_bit;
    mask_i                  = (mask_rd_q < mask_wr) ? mask_buf[mask_rd_q] : 8'hAA;

    mfpu_result_gnt_i       = mfpu_result_req_o & stall_gnt_bit;
  end

  // Pure synchronous NBA capture of all DUT handshakes at posedge clk_i (zero delta-cycle race)
  logic [2:0]       mon_op_rdy_q, mon_op_vld_q;
  logic             mon_mask_rdy_q, mon_mask_vld_q;
  logic             mon_res_req_q, mon_res_gnt_q, mon_vxsat_q;
  vid_t             mon_res_id_q;
  vaddr_t           mon_res_addr_q;
  elen_t            mon_res_wdata_q;
  logic [7:0]       mon_res_be_q;
  logic [NrVInsn-1:0] mon_done_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      global_cycle_cnt <= 0;
      op0_rd_q         <= 0;
      op1_rd_q         <= 0;
      op2_rd_q         <= 0;
      mask_rd_q        <= 0;
      mon_op_rdy_q     <= '0;
      mon_op_vld_q     <= '0;
      mon_mask_rdy_q   <= 1'b0;
      mon_mask_vld_q   <= 1'b0;
      mon_res_req_q    <= 1'b0;
      mon_res_gnt_q    <= 1'b0;
      mon_vxsat_q      <= 1'b0;
      mon_res_id_q     <= '0;
      mon_res_addr_q   <= '0;
      mon_res_wdata_q  <= '0;
      mon_res_be_q     <= '0;
      mon_done_q       <= '0;
    end else begin
      global_cycle_cnt <= global_cycle_cnt + 1;
      if (mfpu_operand_valid_i[0] && mfpu_operand_ready_o[0]) op0_rd_q <= op0_rd_q + 1;
      if (mfpu_operand_valid_i[1] && mfpu_operand_ready_o[1]) op1_rd_q <= op1_rd_q + 1;
      if (mfpu_operand_valid_i[2] && mfpu_operand_ready_o[2]) op2_rd_q <= op2_rd_q + 1;
      if (mask_valid_i && mask_ready_o)                       mask_rd_q <= mask_rd_q + 1;

      mon_op_rdy_q    <= mfpu_operand_ready_o;
      mon_op_vld_q    <= mfpu_operand_valid_i;
      mon_mask_rdy_q  <= mask_ready_o;
      mon_mask_vld_q  <= mask_valid_i;
      mon_res_req_q   <= mfpu_result_req_o;
      mon_res_gnt_q   <= mfpu_result_gnt_i;
      mon_vxsat_q     <= mfpu_vxsat_o;
      mon_res_id_q    <= mfpu_result_id_o;
      mon_res_addr_q  <= mfpu_result_addr_o;
      mon_res_wdata_q <= mfpu_result_wdata_o;
      mon_res_be_q    <= mfpu_result_be_o;
      mon_done_q      <= mfpu_vinsn_done_o;
    end
  end

  // Scoreboard check on negedge clk_i using settled NBA-captured samples
  always @(negedge clk_i) begin
    if (rst_ni) begin
      for (int ch = 0; ch < 3; ch++) begin
        if (mon_op_rdy_q[ch] && !mon_op_vld_q[ch]) begin
          $display("[ERROR] t=%0t: mfpu_operand_ready_o[%0d] asserted without valid!", $time, ch);
          err_cnt++;
        end
      end
      if (mon_mask_rdy_q && !mon_mask_vld_q) begin
        $display("[ERROR] t=%0t: mask_ready_o asserted without mask_valid_i!", $time);
        err_cnt++;
      end

      if (!mon_res_req_q && mon_vxsat_q) begin
        $display("[ERROR] t=%0t: mfpu_vxsat_o asserted while mfpu_result_req_o=0!", $time);
        err_cnt++;
      end

      if (mon_res_req_q && mon_res_gnt_q) begin
        if (exp_res_q.size() == 0) begin
          $display("[ERROR] t=%0t: Unexpected VRF result req id=%0d addr=0x%0h!", $time, mon_res_id_q, mon_res_addr_q);
          err_cnt++;
        end else begin
          exp_res_t exp_b;
          exp_b = exp_res_q.pop_front();
          checked_beats++;

          if (mon_res_id_q !== exp_b.id) begin
            $display("[ERROR] t=%0t beat#%0d: id mismatch got=%0d exp=%0d", $time, checked_beats, mon_res_id_q, exp_b.id);
            err_cnt++;
          end
          if (mon_res_addr_q !== exp_b.addr) begin
            $display("[ERROR] t=%0t beat#%0d: addr mismatch got=0x%0h exp=0x%0h", $time, checked_beats, mon_res_addr_q, exp_b.addr);
            err_cnt++;
          end
          if (mon_res_be_q !== exp_b.be) begin
            $display("[ERROR] t=%0t beat#%0d: be mismatch got=8'b%08b exp=8'b%08b", $time, checked_beats, mon_res_be_q, exp_b.be);
            err_cnt++;
          end
          if (mon_vxsat_q !== exp_b.vxsat) begin
            $display("[ERROR] t=%0t beat#%0d: vxsat mismatch got=%0b exp=%0b (be=8'h%02h)", $time, checked_beats, mon_vxsat_q, exp_b.vxsat, exp_b.be);
            err_cnt++;
          end
          for (int b = 0; b < 8; b++) begin
            if (exp_b.be[b]) begin
              if (mon_res_wdata_q[8*b +: 8] !== exp_b.wdata[8*b +: 8]) begin
                $display("[ERROR] t=%0t beat#%0d byte[%0d]: wdata mismatch got=0x%02h exp=0x%02h (full got=0x%016h exp=0x%016h be=8'b%08b)",
                         $time, checked_beats, b, mon_res_wdata_q[8*b +: 8], exp_b.wdata[8*b +: 8],
                         mon_res_wdata_q, exp_b.wdata, exp_b.be);
                err_cnt++;
              end
            end
          end
        end
      end

      for (int id_idx = 0; id_idx < NrVInsn; id_idx++) begin
        if (mon_done_q[id_idx]) begin
          if (exp_done_q.size() == 0) begin
            $display("[ERROR] t=%0t: Unexpected mfpu_vinsn_done_o[%0d]!", $time, id_idx);
            err_cnt++;
          end else if (exp_done_q[0] !== vid_t'(id_idx)) begin
            $display("[ERROR] t=%0t: Out-of-order mfpu_vinsn_done_o got=%0d exp=%0d", $time, id_idx, exp_done_q[0]);
            err_cnt++;
          end else begin
            void'(exp_done_q.pop_front());
            checked_insns++;
            last_done_cycle = global_cycle_cnt;
          end
        end
      end
    end
  end

  // =========================================================================
  // Helper Task to Enqueue & Issue One Vector Instruction
  // =========================================================================

  task automatic issue_vinsn(
    input vid_t    id,
    input ara_op_e op,
    input vew_e    sew,
    input vlen_t   vl,
    input logic    vm,
    input logic    use_scalar,
    input elen_t   scalar_val,
    input logic    swap_vs2_vd,
    input logic [4:0] vd,
    input elen_t   src0_beats[],
    input elen_t   src1_beats[],
    input elen_t   src2_beats[],
    input logic [7:0] mask_beats[]
  );
    int elems_per_beat;
    int num_beats;
    logic use_vs1, use_vs2, use_vd_op;
    logic [2:0] req_mask;
    vaddr_t base_addr;

    elems_per_beat = 1 << (int'(EW64) - int'(sew));
    num_beats      = (int'(vl) + elems_per_beat - 1) / elems_per_beat;

    use_vs1   = !use_scalar;
    use_vs2   = 1'b1;
    use_vd_op = (op inside {VMACC, VNMSAC, VMADD, VNMSUB});
    if (swap_vs2_vd && !use_vd_op) begin
      // swap_vs2_vd_op is only set on 3-source MACs where vd & vs2 swap queues
      use_vd_op = 1'b0;
    end
    req_mask  = swap_vs2_vd ? {use_vs2, use_vd_op, use_vs1} : {use_vd_op, use_vs2, use_vs1};
    base_addr = vaddr_t'(vaddr(vd, NrLanes, VLEN));

    // Push expected operand beats, mask beats, and golden result beats on negedge clk_i BEFORE asserting vfu_operation_valid_i
    @(negedge clk_i);
    for (int b = 0; b < num_beats; b++) begin
      int rem_elems;
      int beat_elems;
      logic [7:0] m_val, e_be;
      elen_t o0, o1, o2, exp_w;
      logic exp_sat;
      exp_res_t er;

      rem_elems  = int'(vl) - b * elems_per_beat;
      beat_elems = (rem_elems > elems_per_beat) ? elems_per_beat : rem_elems;

      o0    = src0_beats[b];
      o1    = src1_beats[b];
      o2    = src2_beats[b];
      m_val = vm ? 8'hFF : mask_beats[b];

      if (req_mask[0]) begin op_buf0[op0_wr] = o0; op0_wr++; end
      if (req_mask[1]) begin op_buf1[op1_wr] = o1; op1_wr++; end
      if (req_mask[2]) begin op_buf2[op2_wr] = o2; op2_wr++; end
      if (!vm)         begin mask_buf[mask_wr] = m_val; mask_wr++; end

      e_be = be(beat_elems[3:0], sew) & (vm ? 8'hFF : m_val);
      ref_compute_beat(op, sew, mfpu_vxrm_i, o0, o1, o2, scalar_val, use_scalar, e_be, exp_w, exp_sat);

      er.id      = id;
      er.addr    = base_addr + vaddr_t'(b);
      er.wdata   = exp_w;
      er.be      = e_be;
      er.vxsat   = exp_sat;
      er.is_last = (b == num_beats - 1);
      exp_res_q.push_back(er);
    end
    exp_done_q.push_back(id);

    // Drive vfu_operation_i handshake (already at negedge clk_i)
    vfu_operation_i               = '0;
    vfu_operation_i.id            = id;
    vfu_operation_i.op            = op;
    vfu_operation_i.vm            = vm;
    vfu_operation_i.use_vs1       = use_vs1;
    vfu_operation_i.use_vs2       = use_vs2;
    vfu_operation_i.use_vd_op     = use_vd_op;
    vfu_operation_i.scalar_op     = scalar_val;
    vfu_operation_i.use_scalar_op = use_scalar;
    vfu_operation_i.vfu           = VFU_MFpu;
    vfu_operation_i.vd            = vd;
    vfu_operation_i.use_vd        = 1'b1;
    vfu_operation_i.swap_vs2_vd_op = swap_vs2_vd;
    vfu_operation_i.cvt_resize    = CVT_SAME;
    vfu_operation_i.vl            = vl;
    vfu_operation_i.vstart        = '0;
    vfu_operation_i.vtype.vsew    = sew;
    vfu_operation_valid_i         = 1'b1;

    begin : wait_accept
      int guard;
      guard = 0;
      while (1) begin
        @(posedge clk_i);
        if (mfpu_ready_o) break;
        guard++;
        if (guard > 2000) begin
          $fatal(1, "[FATAL] Timeout waiting for mfpu_ready_o!");
        end
      end
    end
    @(negedge clk_i);
    vfu_operation_valid_i = 1'b0;
    vfu_operation_i       = '0;
  endtask

  task automatic wait_all_drained(input int max_cycles);
    int cyc;
    cyc = 0;
    while (exp_done_q.size() > 0 || exp_res_q.size() > 0 ||
           op0_rd_q < op0_wr || op1_rd_q < op1_wr || op2_rd_q < op2_wr || mask_rd_q < mask_wr) begin
      @(posedge clk_i);
      cyc++;
      if (cyc > max_cycles) begin
        $fatal(1, "[FATAL] Timeout draining pipeline: done_q=%0d res_q=%0d op0=%0d/%0d op1=%0d/%0d op2=%0d/%0d mask=%0d/%0d",
               exp_done_q.size(), exp_res_q.size(), op0_rd_q, op0_wr, op1_rd_q, op1_wr, op2_rd_q, op2_wr, mask_rd_q, mask_wr);
      end
    end
    repeat (3) @(posedge clk_i);
  endtask

  // =========================================================================
  // Main Test Sequence
  // =========================================================================

  int seed_val;
  int cyc_all_masked, cyc_sparse_ew8, cyc_sparse_ew16;

  initial begin
    if (!$value$plusargs("seed=%d", seed_val)) begin
      seed_val = 101;
    end
    rng_state = 32'(seed_val) * 32'h9E3779B9 + 32'hA5A5_5A5A;

    rst_ni = 1'b0;
    repeat (6) @(posedge clk_i);
    @(negedge clk_i);
    rst_ni = 1'b1;
    repeat (2) @(posedge clk_i);

    // Check unused FPU valid outputs are inactive on reset
    if (fflags_ex_valid_o !== 1'b0 || fpu_red_complete_o !== 1'b0 ||
        mfpu_red_valid_o !== 1'b0 || mask_operand_valid_o !== 1'b0) begin
      $display("[ERROR] Unexpected FPU valid output active on reset!");
      err_cnt++;
    end

    // Verify non-MFPU broadcast instructions are cleanly ignored
    @(negedge clk_i);
    vfu_operation_i       = '0;
    vfu_operation_i.id    = 2'd3;
    vfu_operation_i.op    = VADD;
    vfu_operation_i.vfu   = VFU_Alu;
    vfu_operation_i.vl    = 13'd16;
    vfu_operation_valid_i = 1'b1;
    @(posedge clk_i);
    @(negedge clk_i);
    vfu_operation_valid_i = 1'b0;
    vfu_operation_i       = '0;
    repeat (4) @(posedge clk_i);

    // -----------------------------------------------------------------------
    // Suite 1: Directed Corner-Case Arithmetic, Rounding, Overflow & Masking
    // -----------------------------------------------------------------------
    begin
      ara_op_e all_ops[13] = '{
        VMUL, VMULH, VMULHU, VMULHSU, VMACC, VNMSAC, VMADD, VNMSUB, VSMUL,
        VDIVU, VDIV, VREMU, VREM
      };
      vew_e all_sews[4] = '{EW8, EW16, EW32, EW64};
      elen_t s0[4], s1[4], s2[4];
      logic [7:0] mb[4];
      vid_t cur_id;
      cur_id = 2'd0;

      // 1A: Divide-by-zero, signed -2^(W-1)/-1 overflow, unsigned 0xFF vs -1, and masked-off saturation
      s0[0] = 64'h0000_0000_0000_0000; // all zeros divisor
      s1[0] = 64'h8000_7FFF_FFFF_0001;
      s2[0] = 64'h1122_3344_5566_7788;
      mb[0] = 8'b1010_0101;

      s0[1] = 64'hFFFF_FFFF_FFFF_FFFF; // all -1s divisor
      s1[1] = 64'h8080_8000_8000_0000; // min signed values across widths
      s2[1] = 64'h99AA_BBCC_DDEE_FF00;
      mb[1] = 8'b0101_1010;

      s0[2] = 64'h8000_8000_8000_8080; // VSMUL saturation trigger (-2^(W-1) * -2^(W-1))
      s1[2] = 64'h8000_8000_8000_8080;
      s2[2] = 64'h0123_4567_89AB_CDEF;
      mb[2] = 8'b0000_0000;            // ALL MASKED OFF -> must NOT assert mfpu_vxsat_o!

      s0[3] = 64'h8000_0000_8000_0080; // VSMUL saturation on specific subwords only
      s1[3] = 64'h8000_0000_8000_0080;
      s2[3] = 64'hFEDC_BA98_7654_3210;
      mb[3] = 8'b1111_1111;

      for (int rm = 0; rm < 4; rm++) begin
        @(negedge clk_i);
        mfpu_vxrm_i = vxrm_t'(rm);
        for (int sw = 0; sw < 4; sw++) begin
          int epb;
          epb = 1 << (3 - sw);
          for (int oi = 0; oi < 13; oi++) begin
            issue_vinsn(
              cur_id,
              all_ops[oi],
              all_sews[sw],
              vlen_t'(3 * epb + ((epb > 1) ? (epb - 1) : 1)), // 4 beats with partial tail beat!
              1'b0, // vm = 0 (masked)
              (oi % 2 == 1), // alternate vector-scalar and vector-vector
              s0[(oi + sw) % 4],
              (all_ops[oi] inside {VMADD, VNMSUB}), // test swap_vs2_vd_op
              5'((oi + sw * 3) & 5'h1F),
              s0, s1, s2, mb
            );
            cur_id = cur_id + 2'd1;
            wait_all_drained(1500);
          end
        end
      end
      // 1B: Back-to-back multi-SEW & variable-latency cross-instruction ordering burst
      issue_vinsn(2'd0, VDIV,  EW64, 13'd4, 1'b1, 1'b0, '0, 1'b0, 5'd2,  s0, s1, s2, mb);
      issue_vinsn(2'd1, VMUL,  EW32, 13'd2, 1'b1, 1'b0, '0, 1'b0, 5'd6,  s0, s1, s2, mb);
      issue_vinsn(2'd2, VMUL,  EW8,  13'd8, 1'b1, 1'b0, '0, 1'b0, 5'd10, s0, s1, s2, mb);
      wait_all_drained(1500);

      issue_vinsn(2'd3, VMULH, EW64, 13'd4, 1'b1, 1'b0, '0, 1'b0, 5'd14, s0, s1, s2, mb);
      issue_vinsn(2'd0, VMUL,  EW16, 13'd4, 1'b1, 1'b0, '0, 1'b0, 5'd18, s0, s1, s2, mb);
      issue_vinsn(2'd1, VSMUL, EW8,  13'd8, 1'b1, 1'b0, '0, 1'b0, 5'd22, s0, s1, s2, mb);
      wait_all_drained(1500);
    end

    // -----------------------------------------------------------------------
    // Suite 2: Quantitative Masked Division Fast-Skip Latency Benchmarks
    // -----------------------------------------------------------------------
    stall_enable = 1'b0;

    // 2A: All-masked EW8 VDIV across 8 beats (vl = 64, vm = 0, mask = 8'h00)
    begin
      elen_t a0[8], a1[8], a2[8];
      logic [7:0] m0[8];
      int c_start;
      for (int i = 0; i < 8; i++) begin
        a0[i] = 64'h0303_0303_0303_0303;
        a1[i] = 64'h7F7E_7D7C_7B7A_7978;
        a2[i] = '0;
        m0[i] = 8'h00;
      end
      c_start = global_cycle_cnt;
      issue_vinsn(2'd0, VDIV, EW8, 13'd64, 1'b0, 1'b0, '0, 1'b0, 5'd4, a0, a1, a2, m0);
      wait_all_drained(500);
      cyc_all_masked = last_done_cycle - c_start;
      $display("[LATENCY] All-masked EW8 VDIV (8 beats, 64 elems): %0d cycles", cyc_all_masked);
      if (cyc_all_masked > 32) begin
        $display("[ERROR] All-masked EW8 VDIV latency %0d cycles exceeds fast-skip bound (<= 32 cycles)!", cyc_all_masked);
        err_cnt++;
      end
    end

    // 2B: Sparse 1-of-8 active EW8 VDIVU across 8 beats (vl = 64, vm = 0, 1 active subword per beat)
    // Inactive subwords hold slow operands (0xFF / 0x01 -> 8 iterations if not skipped);
    // active subword holds (0x18 / 0x06 -> 3 iterations).
    begin
      elen_t a0[8], a1[8], a2[8];
      logic [7:0] m1[8];
      int c_start;
      for (int i = 0; i < 8; i++) begin
        a0[i] = 64'h0101_0101_0101_0101;
        a1[i] = 64'hFFFF_FFFF_FFFF_FFFF;
        a0[i][8*i +: 8] = 8'h06;
        a1[i][8*i +: 8] = 8'h18;
        a2[i] = '0;
        m1[i] = 8'h01 << i;
      end
      c_start = global_cycle_cnt;
      issue_vinsn(2'd1, VDIVU, EW8, 13'd64, 1'b0, 1'b0, '0, 1'b0, 5'd8, a0, a1, a2, m1);
      wait_all_drained(800);
      cyc_sparse_ew8 = last_done_cycle - c_start;
      $display("[LATENCY] Sparse 1/8 EW8 VDIVU (8 beats, 64 elems): %0d cycles", cyc_sparse_ew8);
      if (cyc_sparse_ew8 > 76) begin
        $display("[ERROR] Sparse 1/8 EW8 VDIVU latency %0d cycles exceeds fast-skip bound (<= 76 cycles)!", cyc_sparse_ew8);
        err_cnt++;
      end
    end

    // 2C: Sparse 1-of-4 active EW16 VREM across 8 beats (vl = 32, vm = 0)
    begin
      elen_t a0[8], a1[8], a2[8];
      logic [7:0] m2[8];
      int c_start;
      for (int i = 0; i < 8; i++) begin
        int slot;
        slot  = i % 4;
        a0[i] = 64'h0001_0001_0001_0001;
        a1[i] = 64'h7FFF_7FFF_7FFF_7FFF;
        a0[i][16*slot +: 16] = 16'h0009;
        a1[i][16*slot +: 16] = 16'h002F;
        a2[i] = '0;
        m2[i] = 8'h03 << (2 * slot);
      end
      c_start = global_cycle_cnt;
      issue_vinsn(2'd2, VREM, EW16, 13'd32, 1'b0, 1'b0, '0, 1'b0, 5'd12, a0, a1, a2, m2);
      wait_all_drained(800);
      cyc_sparse_ew16 = last_done_cycle - c_start;
      $display("[LATENCY] Sparse 1/4 EW16 VREM (8 beats, 32 elems): %0d cycles", cyc_sparse_ew16);
      if (cyc_sparse_ew16 > 84) begin
        $display("[ERROR] Sparse 1/4 EW16 VREM latency %0d cycles exceeds fast-skip bound (<= 84 cycles)!", cyc_sparse_ew16);
        err_cnt++;
      end
    end

    // -----------------------------------------------------------------------
    // Suite 3: Pipelined Back-to-Back Multi-Instruction & Random Stall Stress
    // -----------------------------------------------------------------------
    stall_enable = 1'b1;
    @(negedge clk_i);
    mfpu_vxrm_i = vxrm_t'(seed_val & 3);

    begin
      ara_op_e stress_ops[13] = '{
        VMUL, VMULH, VMULHU, VMULHSU, VMACC, VNMSAC, VMADD, VNMSUB, VSMUL,
        VDIVU, VDIV, VREMU, VREM
      };
      vew_e stress_sews[4] = '{EW8, EW16, EW32, EW64};
      vid_t next_id;
      next_id = 2'd0;

      for (int iter = 0; iter < 180; iter++) begin
        int unsigned r1, r2;
        ara_op_e op;
        vew_e    sew;
        int      epb, nbeats;
        vlen_t   vl;
        logic    vm, use_sc, swap_op;
        elen_t   sc_val;
        elen_t   b0[], b1[], b2[];
        logic [7:0] bm[];

        // Ensure we never reuse an instruction ID that has not yet pulsed mfpu_vinsn_done_o
        begin : drain_id_slot
          int drain_guard;
          drain_guard = 0;
          while (exp_done_q.size() >= 3) begin
            @(posedge clk_i);
            drain_guard++;
            if (drain_guard > 4000) begin
              $fatal(1, "[FATAL] Timeout waiting for in-flight instructions to retire (done_q=%0d res_q=%0d)!",
                     exp_done_q.size(), exp_res_q.size());
            end
          end
        end

        r1      = next_rand();
        r2      = next_rand();
        op      = stress_ops[r1 % 13];
        sew     = stress_sews[(r1 >> 4) & 3];
        epb     = 1 << (3 - int'(sew));
        nbeats  = ((r1 >> 6) % 5) + 1; // 1..5 beats
        vl      = vlen_t'((nbeats - 1) * epb + ((r2 % epb) + 1));
        vm      = r1[10];
        use_sc  = r1[11];
        swap_op = r1[12] && (op inside {VMACC, VNMSAC, VMADD, VNMSUB});
        sc_val  = rand64();

        b0 = new[nbeats];
        b1 = new[nbeats];
        b2 = new[nbeats];
        bm = new[nbeats];
        for (int k = 0; k < nbeats; k++) begin
          b0[k] = rand64();
          b1[k] = rand64();
          b2[k] = rand64();
          // Mix all-zero masks, sparse masks, and random masks
          unique case ((r2 >> (2*k)) & 3)
            0: bm[k] = 8'h00;
            1: bm[k] = 8'h01 << ((r1 + k) & 7);
            default: bm[k] = r2[7:0] ^ 8'(k * 8'h37);
          endcase
        end

        issue_vinsn(next_id, op, sew, vl, vm, use_sc, sc_val, swap_op, r2[20:16], b0, b1, b2, bm);
        next_id = next_id + 2'd1;
      end

      wait_all_drained(8000);
    end

    if (err_cnt == 0) begin
      $display("PASS: seed=%0d insns=%0d beats=%0d lat_all_masked=%0d lat_sparse8=%0d lat_sparse16=%0d",
               seed_val, checked_insns, checked_beats, cyc_all_masked, cyc_sparse_ew8, cyc_sparse_ew16);
      $finish(0);
    end else begin
      $fatal(1, "FAIL: seed=%0d errors=%0d", seed_val, err_cnt);
    end
  end

endmodule
