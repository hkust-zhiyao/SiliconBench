module synth_top import ara_pkg::*; import rvv_pkg::*; (
  input  logic clk_i,
  input  logic rst_ni,
  input  logic [255:0] raw_in_i,
  output logic [255:0] raw_out_o
);
  localparam int unsigned NrLanes = 2;
  localparam int unsigned VLEN    = 256;
  localparam int unsigned VLENB   = VLEN / 8;
  localparam int unsigned NrPEs   = NrLanes + 4;
  typedef logic [$clog2(VLEN+1)-1:0] vlen_t;

  `include "ara/intf_typedef.svh"
  `include "ara/ara_typedef.svh"

  localparam config_pkg::cva6_cfg_t CVA6Cfg = build_config_pkg::build_config(cva6_config_pkg::cva6_cfg);
  `CVA6_TYPEDEF_EXCEPTION(exception_t, CVA6Cfg)
  `CVA6_INTF_TYPEDEF_ACC_REQ(accelerator_req_t, CVA6Cfg, fpnew_pkg::roundmode_e)
  `CVA6_INTF_TYPEDEF_ACC_RESP(accelerator_resp_t, CVA6Cfg, exception_t)

  typedef struct packed {
    ara_op_e op;
    logic scale_vl;
    logic vm;
    rvv_pkg::vew_e eew_vmask;
    logic [4:0] vs1;
    logic use_vs1;
    opqueue_conversion_e conversion_vs1;
    rvv_pkg::vew_e eew_vs1;
    rvv_pkg::vew_e old_eew_vs1;
    logic [4:0] vs2;
    logic use_vs2;
    opqueue_conversion_e conversion_vs2;
    rvv_pkg::vew_e eew_vs2;
    logic use_vd_op;
    rvv_pkg::vew_e eew_vd_op;
    elen_t scalar_op;
    logic use_scalar_op;
    elen_t stride;
    logic is_stride_np2;
    logic [4:0] vd;
    logic use_vd;
    logic swap_vs2_vd_op;
    rvv_pkg::vlmul_e emul;
    logic [2:0] nf;
    logic fault_only_first;
    fpnew_pkg::roundmode_e fp_rm;
    logic wide_fp_imm;
    resize_e cvt_resize;
    vlen_t vl;
    vlen_t vstart;
    rvv_pkg::vtype_t vtype;
    logic token;
  } ara_req_t;

  typedef struct packed {
    elen_t resp;
    exception_t exception;
    logic fof_exception;
    vlen_t exception_vstart;
  } ara_resp_t;

  accelerator_req_t  acc_req;
  accelerator_resp_t acc_resp;
  ara_req_t          ara_req;
  ara_resp_t         ara_resp;
  logic              ara_req_valid, ara_req_ready, ara_resp_valid, ara_idle;
  logic              lsu_ex_flush, core_st_pending;
  vxrm_t [NrLanes-1:0] alu_vxrm;

  pe_req_t                         pe_req;
  logic                            pe_req_valid;
  logic [NrVInsn-1:0]              pe_vinsn_running;
  logic [NrPEs-1:0]                pe_req_ready;
  pe_resp_t [NrPEs-1:0]            pe_resp;
  logic [NrVInsn-1:0][NrVInsn-1:0] ght;
  logic                            pe_scalar_resp_ready;

  assign acc_req        = accelerator_req_t'(raw_in_i[$bits(accelerator_req_t)-1:0]);
  assign pe_req_ready   = raw_in_i[205:200];
  always_comb begin
    pe_resp = '0;
    for (int p = 0; p < NrPEs; p++) begin
      pe_resp[p].vinsn_done = raw_in_i[208 + p*4 +: 4];
    end
  end

  ara_dispatcher #(
    .CVA6Cfg           (CVA6Cfg),
    .NrLanes           (NrLanes),
    .VLEN              (VLEN),
    .SegSupport        (SegSupportDisable),
    .ara_req_t         (ara_req_t),
    .ara_resp_t        (ara_resp_t),
    .accelerator_req_t (accelerator_req_t),
    .accelerator_resp_t(accelerator_resp_t)
  ) i_dispatcher (
    .clk_i              (clk_i),
    .rst_ni             (rst_ni),
    .acc_req_i          (acc_req),
    .acc_resp_o         (acc_resp),
    .ara_req_o          (ara_req),
    .ara_req_valid_o    (ara_req_valid),
    .ara_req_ready_i    (ara_req_ready),
    .ara_resp_i         (ara_resp),
    .ara_resp_valid_i   (ara_resp_valid),
    .ara_idle_i         (ara_idle),
    .fflags_ex_i        ('0),
    .fflags_ex_valid_i  ({2{raw_in_i[240]}}),
    .lsu_ex_flush_o     (lsu_ex_flush),
    .lsu_ex_flush_done_i(raw_in_i[241]),
    .vxsat_flag_i       ({2{raw_in_i[242]}}),
    .alu_vxrm_o         (alu_vxrm),
    .core_st_pending_o  (core_st_pending),
    .load_complete_i    (raw_in_i[243]),
    .store_complete_i   (raw_in_i[244]),
    .store_pending_i    (raw_in_i[245])
  );

  ara_sequencer #(
    .NrLanes    (NrLanes),
    .VLEN       (VLEN),
    .ara_req_t  (ara_req_t),
    .ara_resp_t (ara_resp_t),
    .pe_req_t   (pe_req_t),
    .pe_resp_t  (pe_resp_t),
    .exception_t(exception_t)
  ) i_sequencer (
    .clk_i                        (clk_i),
    .rst_ni                       (rst_ni),
    .ara_req_i                    (ara_req),
    .ara_req_valid_i              (ara_req_valid),
    .ara_req_ready_o              (ara_req_ready),
    .ara_resp_o                   (ara_resp),
    .ara_resp_valid_o             (ara_resp_valid),
    .ara_idle_o                   (ara_idle),
    .pe_req_o                     (pe_req),
    .pe_req_valid_o               (pe_req_valid),
    .pe_vinsn_running_o           (pe_vinsn_running),
    .pe_req_ready_i               (pe_req_ready),
    .pe_resp_i                    (pe_resp),
    .alu_vinsn_done_i             (raw_in_i[246]),
    .mfpu_vinsn_done_i            (raw_in_i[247]),
    .global_hazard_table_o        (ght),
    .pe_scalar_resp_i             (raw_in_i[63:0]),
    .pe_scalar_resp_valid_i       (raw_in_i[248]),
    .pe_scalar_resp_ready_o       (pe_scalar_resp_ready),
    .addrgen_ack_i                (raw_in_i[249]),
    .addrgen_exception_i          ('0),
    .addrgen_exception_vstart_i   ('0),
    .addrgen_fof_exception_i      (1'b0),
    .lsu_current_burst_exception_i(raw_in_i[250])
  );

  assign raw_out_o = 256'({acc_resp, pe_req, pe_req_valid, pe_vinsn_running, ght, pe_scalar_resp_ready, lsu_ex_flush, core_st_pending, alu_vxrm});
endmodule
