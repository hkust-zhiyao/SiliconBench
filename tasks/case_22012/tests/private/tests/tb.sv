`timescale 1ns/1ps

module tb;
  import ara_pkg::*;
  import rvv_pkg::*;

  logic clk_i = 1'b0;
  always #2.5 clk_i = ~clk_i;

  logic         rst_ni;
  logic [1:0]   lane_id_i;
  vxrm_t        alu_vxrm_i;
  vfu_op_4l4k_t vfu_op_i;
  logic         vfu_op_valid_i;
  elen_t [1:0]  alu_op_i;
  logic  [1:0]  alu_op_valid_i;
  logic         alu_res_gnt_i;
  logic         alu_red_ready_i;
  elen_t        sldu_op_i;
  logic         sldu_valid_i;
  logic         mask_op_ready_i;
  logic  [7:0]  mask_i;
  logic         mask_valid_i;

  // DUT Enable outputs
  logic         en_vxsat_flag_o;
  logic         en_alu_ready_o;
  logic  [7:0]  en_vinsn_done_o;
  logic         en_red_complete_o;
  logic  [1:0]  en_op_ready_o;
  logic         en_res_req_o;
  vid_t         en_res_id_o;
  vaddr_4l4k_t  en_res_addr_o;
  elen_t        en_res_wdata_o;
  logic  [7:0]  en_res_be_o;
  logic         en_red_valid_o;
  logic         en_sldu_ready_o;
  elen_t        en_mask_op_o;
  logic         en_mask_op_valid_o;
  logic         en_mask_ready_o;

  // DUT Disable outputs
  logic         dis_vxsat_flag_o;
  logic         dis_alu_ready_o;
  logic  [7:0]  dis_vinsn_done_o;
  logic         dis_red_complete_o;
  logic  [1:0]  dis_op_ready_o;
  logic         dis_res_req_o;
  vid_t         dis_res_id_o;
  vaddr_4l4k_t  dis_res_addr_o;
  elen_t        dis_res_wdata_o;
  logic  [7:0]  dis_res_be_o;
  logic         dis_red_valid_o;
  logic         dis_sldu_ready_o;
  elen_t        dis_mask_op_o;
  logic         dis_mask_op_valid_o;
  logic         dis_mask_ready_o;

  logic         dis_drive_en;

  valu #(
    .NrLanes        (4),
    .VLEN           (4096),
    .FixPtSupport   (FixedPointEnable),
    .vaddr_t        (vaddr_4l4k_t),
    .vfu_operation_t(vfu_op_4l4k_t)
  ) u_dut_en (
    .clk_i                (clk_i),
    .rst_ni               (rst_ni),
    .lane_id_i            (lane_id_i),
    .vxsat_flag_o         (en_vxsat_flag_o),
    .alu_vxrm_i           (alu_vxrm_i),
    .vfu_operation_i      (vfu_op_i),
    .vfu_operation_valid_i(vfu_op_valid_i),
    .alu_ready_o          (en_alu_ready_o),
    .alu_vinsn_done_o     (en_vinsn_done_o),
    .alu_red_complete_o   (en_red_complete_o),
    .alu_operand_i        (alu_op_i),
    .alu_operand_valid_i  (alu_op_valid_i),
    .alu_operand_ready_o  (en_op_ready_o),
    .alu_result_req_o     (en_res_req_o),
    .alu_result_id_o      (en_res_id_o),
    .alu_result_addr_o    (en_res_addr_o),
    .alu_result_wdata_o   (en_res_wdata_o),
    .alu_result_be_o      (en_res_be_o),
    .alu_result_gnt_i     (alu_res_gnt_i),
    .alu_red_valid_o      (en_red_valid_o),
    .alu_red_ready_i      (alu_red_ready_i),
    .sldu_operand_i       (sldu_op_i),
    .sldu_alu_valid_i     (sldu_valid_i),
    .sldu_alu_ready_o     (en_sldu_ready_o),
    .mask_operand_o       (en_mask_op_o),
    .mask_operand_valid_o (en_mask_op_valid_o),
    .mask_operand_ready_i (mask_op_ready_i),
    .mask_i               (mask_i),
    .mask_valid_i         (mask_valid_i),
    .mask_ready_o         (en_mask_ready_o)
  );

  valu #(
    .NrLanes        (4),
    .VLEN           (4096),
    .FixPtSupport   (FixedPointDisable),
    .vaddr_t        (vaddr_4l4k_t),
    .vfu_operation_t(vfu_op_4l4k_t)
  ) u_dut_dis (
    .clk_i                (clk_i),
    .rst_ni               (rst_ni),
    .lane_id_i            (lane_id_i),
    .vxsat_flag_o         (dis_vxsat_flag_o),
    .alu_vxrm_i           (alu_vxrm_i),
    .vfu_operation_i      (vfu_op_i),
    .vfu_operation_valid_i(vfu_op_valid_i & dis_drive_en),
    .alu_ready_o          (dis_alu_ready_o),
    .alu_vinsn_done_o     (dis_vinsn_done_o),
    .alu_red_complete_o   (dis_red_complete_o),
    .alu_operand_i        (alu_op_i),
    .alu_operand_valid_i  (alu_op_valid_i & {2{dis_drive_en}}),
    .alu_operand_ready_o  (dis_op_ready_o),
    .alu_result_req_o     (dis_res_req_o),
    .alu_result_id_o      (dis_res_id_o),
    .alu_result_addr_o    (dis_res_addr_o),
    .alu_result_wdata_o   (dis_res_wdata_o),
    .alu_result_be_o      (dis_res_be_o),
    .alu_result_gnt_i     (alu_res_gnt_i & dis_drive_en & dis_res_req_o),
    .alu_red_valid_o      (dis_red_valid_o),
    .alu_red_ready_i      (alu_red_ready_i),
    .sldu_operand_i       (sldu_op_i),
    .sldu_alu_valid_i     (sldu_valid_i & dis_drive_en),
    .sldu_alu_ready_o     (dis_sldu_ready_o),
    .mask_operand_o       (dis_mask_op_o),
    .mask_operand_valid_o (dis_mask_op_valid_o),
    .mask_operand_ready_i (mask_op_ready_i),
    .mask_i               (mask_i),
    .mask_valid_i         (mask_valid_i & dis_drive_en),
    .mask_ready_o         (dis_mask_ready_o)
  );

  // Sticky CSR model matching ara_dispatcher.sv: csr_vxsat_d |= |vxsat_flag_i
  logic sticky_vxsat;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      sticky_vxsat <= 1'b0;
    end else begin
      if (en_vxsat_flag_o) sticky_vxsat <= 1'b1;
      if (dis_vxsat_flag_o !== 1'b0) begin
        $display("FAIL [FixPtDisable]: vxsat_flag_o asserted (%b) when FixPtSupport=FixedPointDisable", dis_vxsat_flag_o);
        $fatal(1);
      end
    end
  end

  // Reference RVV 1.0 fixed-point helpers (128-bit integer math, structurally independent of RTL)
  function automatic bit ref_round_incr(input logic [63:0] uval, input int unsigned shamt, input vxrm_t vxrm);
    bit v_dm1, v_d, sticky;
    if (shamt == 0) return 1'b0;
    v_dm1  = uval[shamt - 1];
    v_d    = (shamt < 64) ? uval[shamt] : 1'b0;
    sticky = 1'b0;
    for (int k = 0; k < 64; k++) begin
      if (k + 1 < shamt && uval[k]) sticky = 1'b1;
    end
    case (vxrm)
      2'b00:   return v_dm1;
      2'b01:   return v_dm1 && (sticky || v_d);
      2'b10:   return 1'b0;
      default: return (!v_d) && (v_dm1 || sticky);
    endcase
  endfunction

  function automatic void ref_eval_word(
    input  ara_op_e    op,
    input  vew_e       vew,
    input  vxrm_t      vxrm,
    input  logic [63:0] opa_c0,
    input  logic [63:0] opb_c0,
    input  logic [63:0] opa_c1,
    input  logic [63:0] opb_c1,
    input  logic        vm,
    input  logic [7:0]  mask_b,
    input  int unsigned elem_cnt,
    output logic [63:0] exp_wdata,
    output logic [7:0]  exp_be,
    output logic [7:0]  exp_vxsat_bytes
  );
    int unsigned sew_bits;
    int unsigned n_sub;
    exp_wdata       = 64'd0;
    exp_vxsat_bytes = 8'd0;
    exp_be          = be(elem_cnt[3:0], vew) & ((vm || (op inside {VMERGE, VADC, VSBC})) ? 8'hFF : mask_b);
    sew_bits        = 8 << int'(vew);
    n_sub           = 64 / sew_bits;

    if (op inside {VNCLIP, VNCLIPU, VNSRL, VNSRA}) begin
      int unsigned w2_bits = 2 * sew_bits;
      int unsigned n_half  = n_sub / 2;
      int unsigned lg2_w2  = $clog2(w2_bits);
      for (int cyc = 0; cyc < 2; cyc++) begin
        if (cyc == 1 && elem_cnt <= n_half) continue;
        for (int b = 0; b < n_half; b++) begin
          logic [63:0] src_a = (cyc == 0) ? opa_c0 : opa_c1;
          logic [63:0] src_b = (cyc == 0) ? opb_c0 : opb_c1;
          logic [63:0] raw_a = (src_a >> (b * w2_bits)) & ((w2_bits == 64) ? ~64'd0 : ((64'd1 << w2_bits) - 64'd1));
          logic [63:0] raw_b = (src_b >> (b * w2_bits)) & ((w2_bits == 64) ? ~64'd0 : ((64'd1 << w2_bits) - 64'd1));
          int unsigned sh    = raw_a & ((1 << lg2_w2) - 1);
          int unsigned dst_slot = 2 * b + cyc;
          logic [63:0] dst_elem = 64'd0;
          bit          sat      = 1'b0;

          if (op == VNSRL) begin
            dst_elem = (raw_b >> sh) & ((64'd1 << sew_bits) - 64'd1);
          end else if (op == VNSRA) begin
            logic signed [63:0] sb = (w2_bits == 64) ? $signed(raw_b) :
                                     (w2_bits == 32) ? $signed({{32{raw_b[31]}}, raw_b[31:0]}) :
                                                       $signed({{48{raw_b[15]}}, raw_b[15:0]});
            logic signed [63:0] sr = sb >>> sh;
            dst_elem = sr & ((64'd1 << sew_bits) - 64'd1);
          end else if (op == VNCLIPU) begin
            bit inc = ref_round_incr(raw_b, sh, vxrm);
            logic [64:0] rounded = {1'b0, (raw_b >> sh)} + {64'd0, inc};
            logic [64:0] umax    = (65'd1 << sew_bits) - 65'd1;
            if (rounded > umax) begin
              sat      = 1'b1;
              dst_elem = umax[63:0];
            end else begin
              dst_elem = rounded[63:0];
            end
          end else begin // VNCLIP
            bit inc = ref_round_incr(raw_b, sh, vxrm);
            logic signed [63:0] sb = (w2_bits == 64) ? $signed(raw_b) :
                                     (w2_bits == 32) ? $signed({{32{raw_b[31]}}, raw_b[31:0]}) :
                                                       $signed({{48{raw_b[15]}}, raw_b[15:0]});
            logic signed [63:0] sr = sb >>> sh;
            logic signed [64:0] rounded = $signed({sr[63], sr}) + $signed({64'd0, inc});
            logic signed [64:0] smax    =  (65'sd1 << (sew_bits - 1)) - 65'sd1;
            logic signed [64:0] smin    = -(65'sd1 << (sew_bits - 1));
            if (rounded > smax) begin
              sat      = 1'b1;
              dst_elem = smax[63:0] & ((64'd1 << sew_bits) - 64'd1);
            end else if (rounded < smin) begin
              sat      = 1'b1;
              dst_elem = smin[63:0] & ((64'd1 << sew_bits) - 64'd1);
            end else begin
              dst_elem = rounded[63:0] & ((64'd1 << sew_bits) - 64'd1);
            end
          end

          for (int by = 0; by < (sew_bits / 8); by++) begin
            exp_wdata[(dst_slot * (sew_bits / 8) + by) * 8 +: 8] = dst_elem[by * 8 +: 8];
            exp_vxsat_bytes[dst_slot * (sew_bits / 8) + by]      = sat;
          end
        end
      end
    end else begin
      int unsigned lg2_w = $clog2(sew_bits);
      for (int b = 0; b < n_sub; b++) begin
        logic [63:0] wmask = (sew_bits == 64) ? ~64'd0 : ((64'd1 << sew_bits) - 64'd1);
        logic [63:0] ua    = (opa_c0 >> (b * sew_bits)) & wmask;
        logic [63:0] ub    = (opb_c0 >> (b * sew_bits)) & wmask;
        logic signed [64:0] sa = (sew_bits == 64) ? $signed({ua[63], ua}) :
                                 (sew_bits == 32) ? $signed({{33{ua[31]}}, ua[31:0]}) :
                                 (sew_bits == 16) ? $signed({{49{ua[15]}}, ua[15:0]}) :
                                                    $signed({{57{ua[7]}},  ua[7:0]});
        logic signed [64:0] sb = (sew_bits == 64) ? $signed({ub[63], ub}) :
                                 (sew_bits == 32) ? $signed({{33{ub[31]}}, ub[31:0]}) :
                                 (sew_bits == 16) ? $signed({{49{ub[15]}}, ub[15:0]}) :
                                                    $signed({{57{ub[7]}},  ub[7:0]});
        logic [64:0] zext_a = {1'b0, ua};
        logic [64:0] zext_b = {1'b0, ub};
        logic signed [64:0] smax =  (65'sd1 << (sew_bits - 1)) - 65'sd1;
        logic signed [64:0] smin = -(65'sd1 << (sew_bits - 1));
        logic [64:0]        umax = (sew_bits == 64) ? {1'b0, ~64'd0} : ((65'd1 << sew_bits) - 65'd1);
        logic [63:0] dst_elem = 64'd0;
        bit          sat      = 1'b0;
        int unsigned sh       = ua & ((1 << lg2_w) - 1);

        case (op)
          VADD: dst_elem = (ub + ua) & wmask;
          VSUB: dst_elem = (ub - ua) & wmask;
          VSLL: dst_elem = (ub << sh) & wmask;
          VSRL: dst_elem = (ub >> sh) & wmask;
          VSRA: begin
            logic signed [64:0] sr = sb >>> sh;
            dst_elem = sr[63:0] & wmask;
          end
          VMERGE: begin
            bit mbit = mask_b[b * (sew_bits / 8)];
            dst_elem = mbit ? ua : ub;
          end
          VSADDU: begin
            logic [64:0] usum = zext_b + zext_a;
            if (usum > umax) begin sat = 1'b1; dst_elem = umax[63:0]; end
            else dst_elem = usum[63:0] & wmask;
          end
          VSADD: begin
            logic signed [64:0] ssum = sb + sa;
            if (ssum > smax)      begin sat = 1'b1; dst_elem = smax[63:0] & wmask; end
            else if (ssum < smin) begin sat = 1'b1; dst_elem = smin[63:0] & wmask; end
            else dst_elem = ssum[63:0] & wmask;
          end
          VSSUBU: begin
            if (zext_b < zext_a) begin sat = 1'b1; dst_elem = 64'd0; end
            else dst_elem = (zext_b - zext_a) & wmask;
          end
          VSSUB: begin
            logic signed [64:0] sdiff = sb - sa;
            if (sdiff > smax)      begin sat = 1'b1; dst_elem = smax[63:0] & wmask; end
            else if (sdiff < smin) begin sat = 1'b1; dst_elem = smin[63:0] & wmask; end
            else dst_elem = sdiff[63:0] & wmask;
          end
          VAADDU: begin
            logic [64:0] usum = zext_b + zext_a;
            bit inc = ref_round_incr(usum[63:0], 1, vxrm);
            dst_elem = ((usum >> 1) + {64'd0, inc}) & wmask;
          end
          VAADD: begin
            logic signed [64:0] ssum = sb + sa;
            bit inc = ref_round_incr(ssum[63:0], 1, vxrm);
            logic signed [64:0] sr = (ssum >>> 1) + $signed({64'd0, inc});
            dst_elem = sr[63:0] & wmask;
          end
          VASUBU: begin
            logic signed [64:0] udiff = $signed(zext_b) - $signed(zext_a);
            bit inc = ref_round_incr(udiff[63:0], 1, vxrm);
            logic signed [64:0] sr = (udiff >>> 1) + $signed({64'd0, inc});
            dst_elem = sr[63:0] & wmask;
          end
          VASUB: begin
            logic signed [64:0] sdiff = sb - sa;
            bit inc = ref_round_incr(sdiff[63:0], 1, vxrm);
            logic signed [64:0] sr = (sdiff >>> 1) + $signed({64'd0, inc});
            dst_elem = sr[63:0] & wmask;
          end
          VSSRL: begin
            bit inc = ref_round_incr(ub, sh, vxrm);
            dst_elem = ((ub >> sh) + {63'd0, inc}) & wmask;
          end
          VSSRA: begin
            bit inc = ref_round_incr(ub, sh, vxrm);
            logic signed [64:0] sr = (sb >>> sh) + $signed({64'd0, inc});
            dst_elem = sr[63:0] & wmask;
          end
          default: dst_elem = 64'd0;
        endcase

        for (int by = 0; by < (sew_bits / 8); by++) begin
          exp_wdata[(b * (sew_bits / 8) + by) * 8 +: 8] = dst_elem[by * 8 +: 8];
          exp_vxsat_bytes[b * (sew_bits / 8) + by]      = sat;
        end
      end
    end
  endfunction

  task automatic reset_dut();
    rst_ni          = 1'b0;
    lane_id_i       = 2'd0;
    alu_vxrm_i      = 2'b00;
    vfu_op_i        = '0;
    vfu_op_valid_i  = 1'b0;
    alu_op_i        = '0;
    alu_op_valid_i  = 2'b00;
    alu_res_gnt_i   = 1'b0;
    alu_red_ready_i = 1'b0;
    sldu_op_i       = '0;
    sldu_valid_i    = 1'b0;
    mask_op_ready_i = 1'b0;
    mask_i          = 8'hFF;
    mask_valid_i    = 1'b0;
    dis_drive_en    = 1'b0;
    repeat (4) @(posedge clk_i);
    #0.5;
    rst_ni = 1'b1;
    @(posedge clk_i);
    #0.5;
  endtask

  task automatic clear_sticky_vxsat();
    @(negedge clk_i);
    sticky_vxsat = 1'b0;
  endtask

  // Execute a single-word or 2-cycle narrowing instruction and check against reference
  task automatic run_single_word_op(
    input string       tag,
    input ara_op_e     op,
    input vew_e        vew,
    input vxrm_t       vxrm,
    input logic        use_scalar,
    input logic [63:0] scalar_val,
    input logic [63:0] vs1_c0,
    input logic [63:0] vs2_c0,
    input logic [63:0] vs1_c1,
    input logic [63:0] vs2_c1,
    input logic        vm,
    input logic [7:0]  mask_b,
    input int unsigned vl,
    input int unsigned stall_gnt_cycles,
    input bit          also_check_disable
  );
    logic [63:0] eff_opa_c0, eff_opa_c1;
    logic [63:0] exp_wdata;
    logic [7:0]  exp_be, exp_vxsat_b;
    bit          exp_sat;
    bit          is_nar;
    int unsigned n_half;
    int unsigned timeout;
    bit          got_commit, got_done;
    logic [63:0] got_wdata;
    logic [7:0]  got_be;
    vaddr_4l4k_t got_addr;

    is_nar = (op inside {VNCLIP, VNCLIPU, VNSRL, VNSRA});
    n_half = (64 / (8 << int'(vew))) / 2;

    case (vew)
      EW64: eff_opa_c0 = use_scalar ? {1{scalar_val[63:0]}} : vs1_c0;
      EW32: eff_opa_c0 = use_scalar ? {2{scalar_val[31:0]}} : vs1_c0;
      EW16: eff_opa_c0 = use_scalar ? {4{scalar_val[15:0]}} : vs1_c0;
      default: eff_opa_c0 = use_scalar ? {8{scalar_val[7:0]}} : vs1_c0;
    endcase
    eff_opa_c1 = use_scalar ? eff_opa_c0 : vs1_c1;

    ref_eval_word(op, vew, vxrm, eff_opa_c0, vs2_c0, eff_opa_c1, vs2_c1, vm, mask_b, vl,
                  exp_wdata, exp_be, exp_vxsat_b);
    exp_sat = |(exp_vxsat_b & exp_be);

    @(negedge clk_i);
    sticky_vxsat          = 1'b0;
    alu_vxrm_i            = vxrm;
    dis_drive_en          = also_check_disable;
    vfu_op_i              = '0;
    vfu_op_i.id           = 3'd2;
    vfu_op_i.op           = op;
    vfu_op_i.vm           = vm;
    vfu_op_i.use_vs1      = !use_scalar;
    vfu_op_i.use_vs2      = 1'b1;
    vfu_op_i.use_scalar_op= use_scalar;
    vfu_op_i.scalar_op    = scalar_val;
    vfu_op_i.vfu          = VFU_Alu;
    vfu_op_i.vd           = 5'd8;
    vfu_op_i.use_vd       = 1'b1;
    vfu_op_i.vl           = vl[12:0];
    vfu_op_i.vtype.vsew   = vew;
    vfu_op_valid_i        = 1'b1;
    alu_res_gnt_i         = 1'b0;

    timeout = 0;
    while (1) begin
      @(posedge clk_i);
      if (en_alu_ready_o === 1'b1) break;
      timeout++;
      if (timeout > 4000) begin $display("FAIL [%s]: timeout waiting for alu_ready_o", tag); $fatal(1); end
    end
    #0.5;
    vfu_op_valid_i = 1'b0;

    // Feed cycle 0 operands
    alu_op_i[0]    = vs1_c0;
    alu_op_i[1]    = vs2_c0;
    alu_op_valid_i = {1'b1, !use_scalar};
    mask_i         = mask_b;
    mask_valid_i   = !vm;

    timeout = 0;
    while (1) begin
      @(posedge clk_i);
      if (en_op_ready_o[1] === 1'b1) break;
      timeout++;
      if (timeout > 40) begin $display("FAIL [%s]: timeout waiting for c0 op_ready", tag); $fatal(1); end
    end
    #0.5;

    if (is_nar && (vl > n_half)) begin
      alu_op_i[0]    = vs1_c1;
      alu_op_i[1]    = vs2_c1;
      alu_op_valid_i = {1'b1, !use_scalar};
      timeout = 0;
      while (1) begin
        @(posedge clk_i);
        if (en_op_ready_o[1] === 1'b1) break;
        timeout++;
        if (timeout > 40) begin $display("FAIL [%s]: timeout waiting for c1 op_ready", tag); $fatal(1); end
      end
      #0.5;
    end

    alu_op_valid_i = 2'b00;
    mask_valid_i   = 1'b0;

    // Wait for result request
    timeout = 0;
    while (!en_res_req_o) begin
      @(posedge clk_i);
      #0.5;
      timeout++;
      if (timeout > 40) begin $display("FAIL [%s]: timeout waiting for alu_result_req_o", tag); $fatal(1); end
    end

    repeat (stall_gnt_cycles) begin
      @(posedge clk_i);
      #0.5;
      if (!exp_sat && en_vxsat_flag_o) begin
        $display("FAIL [%s]: spurious vxsat_flag_o during gnt stall!", tag);
        $fatal(1);
      end
    end

    alu_res_gnt_i = 1'b1;
    got_commit    = 1'b0;
    got_done      = 1'b0;
    for (int cyc = 0; cyc < 10; cyc++) begin
      @(posedge clk_i);
      if (en_res_req_o && alu_res_gnt_i && !got_commit) begin
        got_commit = 1'b1;
        got_wdata  = en_res_wdata_o;
        got_be     = en_res_be_o;
        got_addr   = en_res_addr_o;
        if (also_check_disable) begin
          if (!dis_res_req_o || dis_res_be_o !== got_be || dis_res_wdata_o !== got_wdata) begin
            $display("FAIL [%s]: FixedPointDisable non-fixpt mismatch got=%h/%b exp=%h/%b",
                     tag, dis_res_wdata_o, dis_res_be_o, got_wdata, got_be);
            $fatal(1);
          end
        end
      end
      if (en_vinsn_done_o[2]) got_done = 1'b1;
      #0.2;
      if (got_commit) alu_res_gnt_i = 1'b0;
      if (got_commit && got_done) break;
    end

    if (!got_commit || !got_done) begin
      $display("FAIL [%s]: missing commit (%b) or vinsn_done (%b)", tag, got_commit, got_done);
      $fatal(1);
    end

    if (got_be !== exp_be) begin
      $display("FAIL [%s]: BE mismatch: got=%02x exp=%02x", tag, got_be, exp_be);
      $fatal(1);
    end

    for (int by = 0; by < 8; by++) begin
      if (exp_be[by]) begin
        if (got_wdata[8*by +: 8] !== exp_wdata[8*by +: 8]) begin
          $display("FAIL [%s]: byte %0d mismatch (op=%s vew=%0d vxrm=%02b): got=0x%016x exp=0x%016x (be=0x%02x)",
                   tag, by, op.name(), vew, vxrm, got_wdata, exp_wdata, exp_be);
          $fatal(1);
        end
      end
    end

    @(negedge clk_i);
    if (sticky_vxsat !== exp_sat) begin
      $display("FAIL [%s]: sticky vxsat mismatch (op=%s vew=%0d vxrm=%02b): got=%b exp=%b (be=0x%02x exp_vxsat_b=0x%02x)",
               tag, op.name(), vew, vxrm, sticky_vxsat, exp_sat, exp_be, exp_vxsat_b);
      $fatal(1);
    end
    dis_drive_en = 1'b0;
  endtask

  function automatic logic [63:0] rand64(inout int unsigned rng);
    logic [31:0] lo, hi;
    rng = rng * 32'h08088405 + 32'd1;
    lo  = rng ^ (rng >> 11);
    rng = rng * 32'h08088405 + 32'd1;
    hi  = rng ^ (rng >> 7);
    return {hi, lo};
  endfunction

  initial begin
    int unsigned seed = 32'd101;
    int unsigned rng;
    void'($value$plusargs("SEED=%d", seed));
    rng = seed ^ 32'hA5A5_5A5A;

    reset_dut();

    // =========================================================================
    // SUITE 1: VSSRL & VSSRA — shamt=0, unmasked shamt, all 4 vxrm, all 4 EWs
    // =========================================================================
    for (int m = 0; m < 4; m++) begin
      vxrm_t rm = vxrm_t'(m[1:0]);
      // shamt = 0 and unmasked upper bits (e.g. 0xF8 -> shamt[2:0] == 0 for EW8!)
      run_single_word_op("s1_vssrl_ew8_sh0_unmask", VSSRL, EW8, rm, 1'b0, 64'd0,
        64'hF8_E9_DA_CB_BC_AD_9E_80, 64'hFF_81_7F_80_01_FE_55_AA, 64'd0, 64'd0, 1'b1, 8'hFF, 8, 1, 1'b0);
      run_single_word_op("s1_vssra_ew8_sh0_unmask", VSSRA, EW8, rm, 1'b0, 64'd0,
        64'hF8_00_13_22_31_47_56_65, 64'h80_7F_FF_81_C3_3C_05_FB, 64'd0, 64'd0, 1'b1, 8'hFF, 8, 0, 1'b0);
      // rne tie vs non-tie & rod sticky checks across EW16/EW32/EW64
      run_single_word_op("s1_vssrl_ew16_ties", VSSRL, EW16, rm, 1'b0, 64'd0,
        64'hFFF4_0013_FF02_0001, 64'h0018_000C_0006_0003, 64'd0, 64'd0, 1'b1, 8'hFF, 4, 1, 1'b0);
      run_single_word_op("s1_vssra_ew16_ties", VSSRA, EW16, rm, 1'b1, 64'hFFFF_FF83,
        64'd0, 64'hFFFC_8005_7FFD_FFFB, 64'd0, 64'd0, 1'b1, 8'hFF, 4, 0, 1'b0);
      run_single_word_op("s1_vssrl_ew32_rod_rne", VSSRL, EW32, rm, 1'b0, 64'd0,
        64'hFFFF_FF20_0000_0005, 64'h8000_0001_0000_0011, 64'd0, 64'd0, 1'b1, 8'hFF, 2, 1, 1'b0);
      run_single_word_op("s1_vssra_ew64_deep", VSSRA, EW64, rm, 1'b0, 64'd0,
        64'hFFFF_FFFF_FFFF_FFC8, 64'h8000_0000_0000_0081, 64'd0, 64'd0, 1'b1, 8'hFF, 1, 2, 1'b0);
    end

    // =========================================================================
    // SUITE 2: VSADDU, VSADD, VSSUBU, VSSUB, VAADDU, VAADD, VASUBU, VASUB
    // =========================================================================
    for (int m = 0; m < 4; m++) begin
      vxrm_t rm = vxrm_t'(m[1:0]);
      // VAADD signed overflow prior to shift: +127+127, -128+-128, +127+-128, -1+-2
      run_single_word_op("s2_vaadd_ew8_ovf", VAADD, EW8, rm, 1'b0, 64'd0,
        64'h7F_80_80_FE_01_7F_81_FF, 64'h7F_80_7F_FF_00_01_81_FF, 64'd0, 64'd0, 1'b1, 8'hFF, 8, 1, 1'b0);
      run_single_word_op("s2_vaaddu_ew16", VAADDU, EW16, rm, 1'b0, 64'd0,
        64'hFFFF_FFFE_8000_0001, 64'hFFFF_FFFF_8001_0000, 64'd0, 64'd0, 1'b1, 8'hFF, 4, 0, 1'b0);
      // VASUBU unsigned borrow (vs2 < vs1: 0 - 1 = -1 -> round(-0.5) wrapped to SEW!)
      run_single_word_op("s2_vasubu_ew8_borrow", VASUBU, EW8, rm, 1'b0, 64'd0,
        64'h01_02_FF_80_7F_03_00_01, 64'h00_00_00_7F_80_01_FF_FE, 64'd0, 64'd0, 1'b1, 8'hFF, 8, 1, 1'b0);
      run_single_word_op("s2_vasubu_ew32_borrow", VASUBU, EW32, rm, 1'b0, 64'd0,
        64'hFFFF_FFFF_0000_0001, 64'h0000_0000_0000_0000, 64'd0, 64'd0, 1'b1, 8'hFF, 2, 0, 1'b0);
      // VASUB signed extreme: +127 - (-128) = +255 -> +127.5 (wraps to 0x80 on rnu/rne!), -128 - (+127) = -255
      run_single_word_op("s2_vasub_ew8_extreme", VASUB, EW8, rm, 1'b0, 64'd0,
        64'h80_7F_01_FF_7F_80_00_01, 64'h7F_80_80_7F_7F_80_00_00, 64'd0, 64'd0, 1'b1, 8'hFF, 8, 1, 1'b0);
      run_single_word_op("s2_vasub_ew64_extreme", VASUB, EW64, rm, 1'b0, 64'd0,
        64'h8000_0000_0000_0000, 64'h7FFF_FFFF_FFFF_FFFF, 64'd0, 64'd0, 1'b1, 8'hFF, 1, 0, 1'b0);
    end

    // Saturating add/sub with selective masking & tail masking
    // Byte 7 saturates (0x7F+0x7F), bytes 0..6 do not; mask_b=8'h7F masks off byte 7 -> exp_sat MUST be 0!
    run_single_word_op("s2_vsadd_masked_off_sat", VSADD, EW8, 2'b00, 1'b0, 64'd0,
      64'h7F_01_01_01_01_01_01_01, 64'h7F_01_01_01_01_01_01_01, 64'd0, 64'd0, 1'b0, 8'h7F, 8, 2, 1'b0);
    // Tail element saturates (vl=3 on EW16: shuffled slots for 3 elements are w16[0], w16[2], w16[1] -> be=8'b0011_1111; w16[3] is tail!)
    run_single_word_op("s2_vssub_ew16_tail_sat_masked", VSSUB, EW16, 2'b00, 1'b0, 64'd0,
      64'h8000_0001_0001_0001, 64'h7FFF_0002_0002_0002, 64'd0, 64'd0, 1'b1, 8'hFF, 3, 2, 1'b0);
    // Active VSSUB saturation on EW16 slot 3 when vl=4, mask enables ONLY upper byte or full subword
    run_single_word_op("s2_vssub_ew16_active_sat", VSSUB, EW16, 2'b00, 1'b0, 64'd0,
      64'h8000_0001_0001_0001, 64'h7FFF_0002_0002_0002, 64'd0, 64'd0, 1'b0, 8'h80, 4, 2, 1'b0);
    // Explicit EW8 VSSUB signed negative-overflow (0x80 - 0x01 -> 0x80) and positive-overflow (0x7f - 0xff -> 0x7f)
    run_single_word_op("s2_vssub_ew8_neg_ovf", VSSUB, EW8, 2'b00, 1'b0, 64'd0,
      64'h01_01_01_01_01_01_01_01, 64'h80_80_80_80_80_80_80_80, 64'd0, 64'd0, 1'b1, 8'hFF, 8, 1, 1'b0);
    run_single_word_op("s2_vssub_ew8_pos_ovf", VSSUB, EW8, 2'b00, 1'b0, 64'd0,
      64'hFF_FF_FF_FF_FF_FF_FF_FF, 64'h7F_7F_7F_7F_7F_7F_7F_7F, 64'd0, 64'd0, 1'b1, 8'hFF, 8, 1, 1'b0);
    run_single_word_op("s2_vsaddu_ew64_sat", VSADDU, EW64, 2'b00, 1'b0, 64'd0,
      64'hFFFF_FFFF_FFFF_FFFF, 64'h0000_0000_0000_0001, 64'd0, 64'd0, 1'b1, 8'hFF, 1, 1, 1'b0);
    run_single_word_op("s2_vssubu_ew32_sat", VSSUBU, EW32, 2'b00, 1'b0, 64'd0,
      64'h0000_0005_0000_0001, 64'h0000_0004_0000_0005, 64'd0, 64'd0, 1'b1, 8'hFF, 2, 1, 1'b0);

    // =========================================================================
    // SUITE 3: 2-Cycle Narrowing VNCLIP & VNCLIPU (half-0 sat, half-1 sat, post-round sat, negative in-range)
    // =========================================================================
    for (int m = 0; m < 4; m++) begin
      vxrm_t rm = vxrm_t'(m[1:0]);
      // Negative in-range (-1 = 0xFFFF, -128 = 0xFF80) MUST NOT set vxsat!
      run_single_word_op("s3_vnclip_ew8_neg_inrange", VNCLIP, EW8, rm, 1'b0, 64'd0,
        64'h0000_0000_0000_0000, 64'hFFFF_FF80_007F_0000,
        64'h0001_0001_0001_0001, 64'hFFFF_FF00_00FE_0001, 1'b1, 8'hFF, 8, 1, 1'b0);
      // Rounding-induced positive overflow: 0x00FF >> 1 = 127 + rm -> +128 -> saturates to 0x7F & sets vxsat on rnu/rne!
      run_single_word_op("s3_vnclip_ew8_round_ovf", VNCLIP, EW8, rm, 1'b0, 64'd0,
        64'h0001_0001_0001_0001, 64'h00FF_00FE_FF00_FEFF,
        64'h0001_0001_0001_0001, 64'h0002_0004_FFFE_FFFC, 1'b1, 8'hFF, 8, 2, 1'b0);
      // VNCLIPU rounding-induced overflow: 0x01FF >> 1 = 255 + rm -> 256 -> saturates to 0xFF!
      run_single_word_op("s3_vnclipu_ew8_round_ovf", VNCLIPU, EW8, rm, 1'b0, 64'd0,
        64'h0001_0001_0001_0001, 64'h01FF_01FE_0003_0001,
        64'h0000_0000_0000_0000, 64'h00FF_0080_0001_0000, 1'b1, 8'hFF, 8, 1, 1'b0);
      // Saturation ONLY in cycle 0 (half 0) while cycle 1 (half 1) has zero saturation!
      run_single_word_op("s3_vnclip_ew16_half0_only_sat", VNCLIP, EW16, rm, 1'b0, 64'd0,
        64'h0000_0000_0000_0000, 64'h0000_0001_0000_8000,
        64'h0000_0000_0000_0000, 64'hFFFF_FFFF_0000_7FFF, 1'b1, 8'hFF, 4, 2, 1'b0);
      // Saturation ONLY in cycle 0 (slot 0), masked OFF by mask_b = 8'b1111_1100 -> exp_sat MUST be 0!
      run_single_word_op("s3_vnclip_ew16_half0_masked_off", VNCLIP, EW16, rm, 1'b0, 64'd0,
        64'h0000_0000_0000_0000, 64'h0000_0001_0000_8000,
        64'h0000_0000_0000_0000, 64'hFFFF_FFFF_0000_7FFF, 1'b0, 8'hFC, 4, 2, 1'b0);
      // EW32 from EW64 narrowing with scalar shift amount
      run_single_word_op("s3_vnclip_ew32_wx", VNCLIP, EW32, rm, 1'b1, 64'hFFFF_FFFF_FFFF_FF03,
        64'd0, 64'h0000_0003_FFFF_FFFF,
        64'd0, 64'hFFFF_FFFC_0000_0000, 1'b1, 8'hFF, 2, 1, 1'b0);
      run_single_word_op("s3_vnclipu_ew32_wx", VNCLIPU, EW32, rm, 1'b1, 64'h0000_0000_0000_0001,
        64'd0, 64'h0000_0001_FFFF_FFFF,
        64'd0, 64'h0000_0000_FFFF_FFFE, 1'b1, 8'hFF, 2, 1, 1'b0);
    end

    // =========================================================================
    // SUITE 4: Back-to-Back Pipelined Result-Queue Stalls (False Loss & False Positive Checks)
    // =========================================================================
    begin : suite4_pipelined
      // 4A: vinsn0 = VADD (vl=1 -> be=8'h01) stalled in result_queue[0],
      //     vinsn1 = VSADD (vl=8, saturates ONLY in byte 7 -> vxsat=8'h80, be=8'hFF) pushed into result_queue[1]!
      @(negedge clk_i);
      sticky_vxsat   = 1'b0;
      alu_res_gnt_i  = 1'b0;
      alu_vxrm_i     = 2'b00;

      // Issue vinsn 0 (VADD, id=0, vl=1)
      vfu_op_i            = '0;
      vfu_op_i.id         = 3'd0;
      vfu_op_i.op         = VADD;
      vfu_op_i.vm         = 1'b1;
      vfu_op_i.use_vs1    = 1'b1;
      vfu_op_i.use_vs2    = 1'b1;
      vfu_op_i.vfu        = VFU_Alu;
      vfu_op_i.vd         = 5'd2;
      vfu_op_i.use_vd     = 1'b1;
      vfu_op_i.vl         = 13'd1;
      vfu_op_i.vtype.vsew = EW8;
      vfu_op_valid_i      = 1'b1;
      @(negedge clk_i);
      // Issue vinsn 1 back-to-back (VSADD, id=1, vl=8, saturates in byte 7)
      vfu_op_i.id         = 3'd1;
      vfu_op_i.op         = VSADD;
      vfu_op_i.vl         = 13'd8;
      vfu_op_i.vd         = 5'd4;
      @(negedge clk_i);
      vfu_op_valid_i      = 1'b0;

      // Feed operands for vinsn 0
      alu_op_i[0]    = 64'h0101_0101_0101_0101;
      alu_op_i[1]    = 64'h0202_0202_0202_0202;
      alu_op_valid_i = 2'b11;
      begin int w; w = 0; while (1) begin @(posedge clk_i); if (en_op_ready_o[1] === 1'b1) break; w++; if (w > 4000) $fatal(1, "FAIL [s4A]: timeout op0"); end end
      #0.5;
      // Feed operands for vinsn 1 (byte 7: 0x7F + 0x7F -> saturates!)
      alu_op_i[0]    = 64'h7F00_0000_0000_0001;
      alu_op_i[1]    = 64'h7F00_0000_0000_0001;
      alu_op_valid_i = 2'b11;
      begin int w; w = 0; while (1) begin @(posedge clk_i); if (en_op_ready_o[1] === 1'b1) break; w++; if (w > 4000) $fatal(1, "FAIL [s4A]: timeout op1"); end end
      #0.5;
      alu_op_valid_i = 2'b00;

      // Hold VRF writeback stalled for 3 cycles with both entries queued, then grant only active requests!
      repeat (3) @(negedge clk_i);
      for (int d = 0; d < 6; d++) begin
        @(negedge clk_i);
        alu_res_gnt_i = en_res_req_o;
      end
      @(negedge clk_i);
      alu_res_gnt_i = 1'b0;
      if (sticky_vxsat !== 1'b1) begin
        $display("FAIL [s4A_pipelined_loss]: lost vxsat from second queued instruction when first entry had be=0x01!");
        $fatal(1);
      end

      // 4B: vinsn0 = VADD (vl=8 -> be=8'hFF) stalled in result_queue[0],
      //     vinsn1 = VSADD (vm=0, mask_i=8'h01, byte 7 has 0x7F+0x7F MASKED OFF!) in result_queue[1]!
      @(negedge clk_i);
      sticky_vxsat   = 1'b0;
      alu_res_gnt_i  = 1'b0;
      vfu_op_i            = '0;
      vfu_op_i.id         = 3'd3;
      vfu_op_i.op         = VADD;
      vfu_op_i.vm         = 1'b1;
      vfu_op_i.use_vs1    = 1'b1;
      vfu_op_i.use_vs2    = 1'b1;
      vfu_op_i.vfu        = VFU_Alu;
      vfu_op_i.vd         = 5'd6;
      vfu_op_i.use_vd     = 1'b1;
      vfu_op_i.vl         = 13'd8;
      vfu_op_i.vtype.vsew = EW8;
      vfu_op_valid_i      = 1'b1;
      @(negedge clk_i);
      vfu_op_i.id         = 3'd4;
      vfu_op_i.op         = VSADD;
      vfu_op_i.vm         = 1'b0;
      vfu_op_i.vd         = 5'd7;
      vfu_op_i.vl         = 13'd8;
      @(negedge clk_i);
      vfu_op_valid_i      = 1'b0;

      alu_op_i[0]    = 64'h0101_0101_0101_0101;
      alu_op_i[1]    = 64'h0202_0202_0202_0202;
      alu_op_valid_i = 2'b11;
      begin int w; w = 0; while (1) begin @(posedge clk_i); if (en_op_ready_o[1] === 1'b1) break; w++; if (w > 4000) $fatal(1, "FAIL [s4B]: timeout op0"); end end
      #0.5;
      alu_op_i[0]    = 64'h7F7F_7F7F_7F7F_7F01;
      alu_op_i[1]    = 64'h7F7F_7F7F_7F7F_7F01;
      alu_op_valid_i = 2'b11;
      mask_i         = 8'h01;
      mask_valid_i   = 1'b1;
      begin int w; w = 0; while (1) begin @(posedge clk_i); if (en_op_ready_o[1] === 1'b1) break; w++; if (w > 4000) $fatal(1, "FAIL [s4B]: timeout op1"); end end
      #0.5;
      alu_op_valid_i = 2'b00;
      mask_valid_i   = 1'b0;

      repeat (3) @(negedge clk_i);
      for (int d = 0; d < 6; d++) begin
        @(negedge clk_i);
        alu_res_gnt_i = en_res_req_o;
      end
      @(negedge clk_i);
      alu_res_gnt_i = 1'b0;
      if (sticky_vxsat !== 1'b0) begin
        $display("FAIL [s4B_pipelined_false_pos]: falsely asserted vxsat on masked-off bytes due to prior queued entry be=0xFF!");
        $fatal(1);
      end
    end

    // =========================================================================
    // SUITE 4C: Seeded Randomized Stress Across All 12 Fixed-Point Opcodes
    // =========================================================================
    begin : suite4_random
      ara_op_e fx_ops [12] = '{VSADDU, VSADD, VSSUBU, VSSUB, VAADDU, VAADD, VASUBU, VASUB, VSSRL, VSSRA, VNCLIPU, VNCLIP};
      for (int t = 0; t < 192; t++) begin
        int unsigned op_seq = t / 12;
        ara_op_e op   = fx_ops[t % 12];
        vew_e    vew  = (op inside {VNCLIPU, VNCLIP}) ? vew_e'(op_seq % 3) : vew_e'(op_seq % 4);
        vxrm_t   rm   = (op inside {VNCLIPU, VNCLIP}) ? vxrm_t'(((op_seq / 3) + (seed & 3)) % 4)
                                                      : vxrm_t'(((op_seq / 4) + (seed & 3)) % 4);
        int unsigned max_e = 64 / (8 << int'(vew));
        int unsigned vl    = 1 + ((rng ^ t) % max_e);
        logic [63:0] a0    = rand64(rng);
        logic [63:0] b0    = rand64(rng);
        logic [63:0] a1    = rand64(rng);
        logic [63:0] b1    = rand64(rng);
        logic [63:0] cr    = rand64(rng);
        logic        vm    = cr[0];
        logic [7:0]  mb    = 8'(rand64(rng));
        logic        usc   = ((op_seq % 5) == 1);
        run_single_word_op($sformatf("s4_rand_%0d", t), op, vew, rm, usc, a0, a0, b0, a1, b1,
                           vm, mb, vl, int'(cr[2:1]) % 3, 1'b0);
      end
    end

    // =========================================================================
    // SUITE 5: Non-Fixed-Point Integer, Narrowing Shift & FixedPointDisable Parity
    // =========================================================================
    run_single_word_op("s5_vadd_ew32",   VADD,   EW32, 2'b00, 1'b0, 64'd0, 64'h1234_5678_9ABC_DEF0, 64'h0FED_CBA9_8765_4321, 64'd0, 64'd0, 1'b1, 8'hFF, 2, 1, 1'b1);
    run_single_word_op("s5_vsub_ew16",   VSUB,   EW16, 2'b01, 1'b0, 64'd0, 64'h0001_8000_7FFF_FFFF, 64'h0000_7FFF_8000_0001, 64'd0, 64'd0, 1'b0, 8'h3F, 4, 0, 1'b1);
    run_single_word_op("s5_vsra_ew8",    VSRA,   EW8,  2'b11, 1'b0, 64'd0, 64'h0706_0504_0302_0100, 64'h80FF_C07F_E040_F081, 64'd0, 64'd0, 1'b1, 8'hFF, 8, 1, 1'b1);
    run_single_word_op("s5_vnsrl_ew8",   VNSRL,  EW8,  2'b00, 1'b0, 64'd0, 64'h0004_0003_0002_0001, 64'hABCD_1234_5678_9ABC, 64'h0008_0007_0006_0005, 64'hFEDC_BA98_7654_3210, 1'b1, 8'hFF, 8, 1, 1'b1);
    run_single_word_op("s5_vnsra_ew16",  VNSRA,  EW16, 2'b00, 1'b0, 64'd0, 64'h0000_0008_0000_0004, 64'h8000_1234_FFFF_FF00, 64'h0000_0010_0000_0000, 64'h7FFF_0000_8000_0001, 1'b1, 8'hFF, 4, 0, 1'b1);
    run_single_word_op("s5_vmerge_ew8",  VMERGE, EW8,  2'b00, 1'b0, 64'd0, 64'hAA55_AA55_AA55_AA55, 64'h1122_3344_5566_7788, 64'd0, 64'd0, 1'b0, 8'hA5, 8, 0, 1'b1);

    $display("PASS: All Ara VALU fixed-point, saturation-queue, and FixedPointDisable suites passed (seed=%0d)!", seed);
    $finish;
  end

endmodule
