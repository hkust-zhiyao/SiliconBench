module syn_wrap_enable import ara_pkg::*; import rvv_pkg::*; (
  input  logic         clk_i,
  input  logic         rst_ni,
  input  logic [1:0]   lane_id_i,
  output logic         vxsat_flag_o,
  input  logic [1:0]   alu_vxrm_i,
  // Flattened vfu_op_4l4k_t fields
  input  logic [2:0]   op_id_i,
  input  logic [7:0]   op_code_i,
  input  logic         op_vm_i,
  input  logic         op_use_vs1_i,
  input  logic         op_use_vs2_i,
  input  logic         op_use_vd_op_i,
  input  logic [63:0]  op_scalar_op_i,
  input  logic         op_use_scalar_op_i,
  input  logic [2:0]   op_vfu_i,
  input  logic [4:0]   op_vd_i,
  input  logic         op_use_vd_i,
  input  logic [12:0]  op_vl_i,
  input  logic [12:0]  op_vstart_i,
  input  logic [2:0]   op_vsew_i,
  input  logic         vfu_operation_valid_i,
  output logic         alu_ready_o,
  output logic [7:0]   alu_vinsn_done_o,
  output logic         alu_red_complete_o,
  input  logic [63:0]  alu_operand_0_i,
  input  logic [63:0]  alu_operand_1_i,
  input  logic [1:0]   alu_operand_valid_i,
  output logic [1:0]   alu_operand_ready_o,
  output logic         alu_result_req_o,
  output logic [2:0]   alu_result_id_o,
  output logic [11:0]  alu_result_addr_o,
  output logic [63:0]  alu_result_wdata_o,
  output logic [7:0]   alu_result_be_o,
  input  logic         alu_result_gnt_i,
  output logic         alu_red_valid_o,
  input  logic         alu_red_ready_i,
  input  logic [63:0]  sldu_operand_i,
  input  logic         sldu_alu_valid_i,
  output logic         sldu_alu_ready_o,
  output logic [63:0]  mask_operand_o,
  output logic         mask_operand_valid_o,
  input  logic         mask_operand_ready_i,
  input  logic [7:0]   mask_i,
  input  logic         mask_valid_i,
  output logic         mask_ready_o
);

  vfu_op_4l4k_t vfu_op;
  always_comb begin
    vfu_op               = '0;
    vfu_op.id            = op_id_i;
    vfu_op.op            = ara_op_e'(op_code_i);
    vfu_op.vm            = op_vm_i;
    vfu_op.use_vs1       = op_use_vs1_i;
    vfu_op.use_vs2       = op_use_vs2_i;
    vfu_op.use_vd_op     = op_use_vd_op_i;
    vfu_op.scalar_op     = op_scalar_op_i;
    vfu_op.use_scalar_op = op_use_scalar_op_i;
    vfu_op.vfu           = vfu_e'(op_vfu_i);
    vfu_op.vd            = op_vd_i;
    vfu_op.use_vd        = op_use_vd_i;
    vfu_op.vl            = op_vl_i;
    vfu_op.vstart        = op_vstart_i;
    vfu_op.vtype.vsew    = vew_e'(op_vsew_i);
  end

  valu #(
    .NrLanes        (4),
    .VLEN           (4096),
    .FixPtSupport   (FixedPointEnable),
    .vaddr_t        (vaddr_4l4k_t),
    .vfu_operation_t(vfu_op_4l4k_t)
  ) i_valu (
    .clk_i                (clk_i),
    .rst_ni               (rst_ni),
    .lane_id_i            (lane_id_i),
    .vxsat_flag_o         (vxsat_flag_o),
    .alu_vxrm_i           (vxrm_t'(alu_vxrm_i)),
    .vfu_operation_i      (vfu_op),
    .vfu_operation_valid_i(vfu_operation_valid_i),
    .alu_ready_o          (alu_ready_o),
    .alu_vinsn_done_o     (alu_vinsn_done_o),
    .alu_red_complete_o   (alu_red_complete_o),
    .alu_operand_i        ({alu_operand_1_i, alu_operand_0_i}),
    .alu_operand_valid_i  (alu_operand_valid_i),
    .alu_operand_ready_o  (alu_operand_ready_o),
    .alu_result_req_o     (alu_result_req_o),
    .alu_result_id_o      (alu_result_id_o),
    .alu_result_addr_o    (alu_result_addr_o),
    .alu_result_wdata_o   (alu_result_wdata_o),
    .alu_result_be_o      (alu_result_be_o),
    .alu_result_gnt_i     (alu_result_gnt_i),
    .alu_red_valid_o      (alu_red_valid_o),
    .alu_red_ready_i      (alu_red_ready_i),
    .sldu_operand_i       (sldu_operand_i),
    .sldu_alu_valid_i     (sldu_alu_valid_i),
    .sldu_alu_ready_o     (sldu_alu_ready_o),
    .mask_operand_o       (mask_operand_o),
    .mask_operand_valid_o (mask_operand_valid_o),
    .mask_operand_ready_i (mask_operand_ready_i),
    .mask_i               (mask_i),
    .mask_valid_i         (mask_valid_i),
    .mask_ready_o         (mask_ready_o)
  );

endmodule

module syn_wrap_disable import ara_pkg::*; import rvv_pkg::*; (
  input  logic         clk_i,
  input  logic         rst_ni,
  input  logic [1:0]   lane_id_i,
  output logic         vxsat_flag_o,
  input  logic [1:0]   alu_vxrm_i,
  input  logic [2:0]   op_id_i,
  input  logic [7:0]   op_code_i,
  input  logic         op_vm_i,
  input  logic         op_use_vs1_i,
  input  logic         op_use_vs2_i,
  input  logic         op_use_vd_op_i,
  input  logic [63:0]  op_scalar_op_i,
  input  logic         op_use_scalar_op_i,
  input  logic [2:0]   op_vfu_i,
  input  logic [4:0]   op_vd_i,
  input  logic         op_use_vd_i,
  input  logic [12:0]  op_vl_i,
  input  logic [12:0]  op_vstart_i,
  input  logic [2:0]   op_vsew_i,
  input  logic         vfu_operation_valid_i,
  output logic         alu_ready_o,
  output logic [7:0]   alu_vinsn_done_o,
  output logic         alu_red_complete_o,
  input  logic [63:0]  alu_operand_0_i,
  input  logic [63:0]  alu_operand_1_i,
  input  logic [1:0]   alu_operand_valid_i,
  output logic [1:0]   alu_operand_ready_o,
  output logic         alu_result_req_o,
  output logic [2:0]   alu_result_id_o,
  output logic [11:0]  alu_result_addr_o,
  output logic [63:0]  alu_result_wdata_o,
  output logic [7:0]   alu_result_be_o,
  input  logic         alu_result_gnt_i,
  output logic         alu_red_valid_o,
  input  logic         alu_red_ready_i,
  input  logic [63:0]  sldu_operand_i,
  input  logic         sldu_alu_valid_i,
  output logic         sldu_alu_ready_o,
  output logic [63:0]  mask_operand_o,
  output logic         mask_operand_valid_o,
  input  logic         mask_operand_ready_i,
  input  logic [7:0]   mask_i,
  input  logic         mask_valid_i,
  output logic         mask_ready_o
);

  vfu_op_4l4k_t vfu_op;
  always_comb begin
    vfu_op               = '0;
    vfu_op.id            = op_id_i;
    vfu_op.op            = ara_op_e'(op_code_i);
    vfu_op.vm            = op_vm_i;
    vfu_op.use_vs1       = op_use_vs1_i;
    vfu_op.use_vs2       = op_use_vs2_i;
    vfu_op.use_vd_op     = op_use_vd_op_i;
    vfu_op.scalar_op     = op_scalar_op_i;
    vfu_op.use_scalar_op = op_use_scalar_op_i;
    vfu_op.vfu           = vfu_e'(op_vfu_i);
    vfu_op.vd            = op_vd_i;
    vfu_op.use_vd        = op_use_vd_i;
    vfu_op.vl            = op_vl_i;
    vfu_op.vstart        = op_vstart_i;
    vfu_op.vtype.vsew    = vew_e'(op_vsew_i);
  end

  valu #(
    .NrLanes        (4),
    .VLEN           (4096),
    .FixPtSupport   (FixedPointDisable),
    .vaddr_t        (vaddr_4l4k_t),
    .vfu_operation_t(vfu_op_4l4k_t)
  ) i_valu (
    .clk_i                (clk_i),
    .rst_ni               (rst_ni),
    .lane_id_i            (lane_id_i),
    .vxsat_flag_o         (vxsat_flag_o),
    .alu_vxrm_i           (vxrm_t'(alu_vxrm_i)),
    .vfu_operation_i      (vfu_op),
    .vfu_operation_valid_i(vfu_operation_valid_i),
    .alu_ready_o          (alu_ready_o),
    .alu_vinsn_done_o     (alu_vinsn_done_o),
    .alu_red_complete_o   (alu_red_complete_o),
    .alu_operand_i        ({alu_operand_1_i, alu_operand_0_i}),
    .alu_operand_valid_i  (alu_operand_valid_i),
    .alu_operand_ready_o  (alu_operand_ready_o),
    .alu_result_req_o     (alu_result_req_o),
    .alu_result_id_o      (alu_result_id_o),
    .alu_result_addr_o    (alu_result_addr_o),
    .alu_result_wdata_o   (alu_result_wdata_o),
    .alu_result_be_o      (alu_result_be_o),
    .alu_result_gnt_i     (alu_result_gnt_i),
    .alu_red_valid_o      (alu_red_valid_o),
    .alu_red_ready_i      (alu_red_ready_i),
    .sldu_operand_i       (sldu_operand_i),
    .sldu_alu_valid_i     (sldu_alu_valid_i),
    .sldu_alu_ready_o     (sldu_alu_ready_o),
    .mask_operand_o       (mask_operand_o),
    .mask_operand_valid_o (mask_operand_valid_o),
    .mask_operand_ready_i (mask_operand_ready_i),
    .mask_i               (mask_i),
    .mask_valid_i         (mask_valid_i),
    .mask_ready_o         (mask_ready_o)
  );

endmodule
