// Synthesis elaboration wrapper for Ara Mask Unit (NrLanes = 4, VLEN = 1024)
module synth_top import ara_pkg::*; import rvv_pkg::*; #(
    parameter int unsigned NrLanes = 4,
    parameter int unsigned VLEN    = 1024
  ) (
    input  logic                                       clk_i,
    input  logic                                       rst_ni,
    input  logic     [319:0]                           raw_req_i,
    input  logic                                       pe_req_valid_i,
    input  logic     [NrVInsn-1:0]                     pe_vinsn_running_i,
    output logic                                       pe_req_ready_o,
    output logic     [NrVInsn-1:0]                     pe_vinsn_done_o,
    output elen_t                                      result_scalar_o,
    output logic                                       result_scalar_valid_o,
    input  logic                                       result_scalar_ready_i,
    input  elen_t    [NrLanes-1:0][NrMaskFUnits+2-1:0] masku_operand_i,
    input  logic     [NrLanes-1:0][NrMaskFUnits+2-1:0] masku_operand_valid_i,
    output logic     [NrLanes-1:0][NrMaskFUnits+2-1:0] masku_operand_ready_o,
    output logic     [NrLanes-1:0]                     masku_result_req_o,
    output vid_t     [NrLanes-1:0]                     masku_result_id_o,
    output logic     [NrLanes-1:0][9:0]                masku_result_addr_o,
    output elen_t    [NrLanes-1:0]                     masku_result_wdata_o,
    output logic     [NrLanes-1:0][7:0]                masku_result_be_o,
    input  logic     [NrLanes-1:0]                     masku_result_gnt_i,
    input  logic     [NrLanes-1:0]                     masku_result_final_gnt_i,
    output logic     [NrLanes-1:0]                     masku_vrgat_req_valid_o,
    input  logic     [NrLanes-1:0]                     masku_vrgat_req_ready_i,
    output vrgat_req_t                                 masku_vrgat_req_o,
    output logic     [NrLanes-1:0][7:0]                mask_o,
    output logic     [NrLanes-1:0]                     mask_valid_o,
    output logic                                       mask_valid_lane_o,
    input  logic     [NrLanes-1:0]                     lane_mask_ready_i,
    input  logic                                       vldu_mask_ready_i,
    input  logic                                       vstu_mask_ready_i,
    input  logic                                       sldu_mask_ready_i
  );

  localparam type vlen_t  = logic [$clog2(VLEN+1)-1:0];
  localparam type vaddr_t = logic [9:0];

  `include "ara/ara_typedef.svh"

  pe_req_t  pe_req;
  pe_resp_t pe_resp;

  assign pe_req          = pe_req_t'(raw_req_i[$bits(pe_req_t)-1:0]);
  assign pe_vinsn_done_o = pe_resp.vinsn_done;

  masku #(
    .NrLanes   ( NrLanes   ),
    .VLEN      ( VLEN      ),
    .vaddr_t   ( vaddr_t   ),
    .pe_req_t  ( pe_req_t  ),
    .pe_resp_t ( pe_resp_t )
  ) i_dut (
    .clk_i                    ( clk_i                    ),
    .rst_ni                   ( rst_ni                   ),
    .pe_req_i                 ( pe_req                   ),
    .pe_req_valid_i           ( pe_req_valid_i           ),
    .pe_vinsn_running_i       ( pe_vinsn_running_i       ),
    .pe_req_ready_o           ( pe_req_ready_o           ),
    .pe_resp_o                ( pe_resp                  ),
    .result_scalar_o          ( result_scalar_o          ),
    .result_scalar_valid_o    ( result_scalar_valid_o    ),
    .result_scalar_ready_i    ( result_scalar_ready_i    ),
    .masku_operand_i          ( masku_operand_i          ),
    .masku_operand_valid_i    ( masku_operand_valid_i    ),
    .masku_operand_ready_o    ( masku_operand_ready_o    ),
    .masku_result_req_o       ( masku_result_req_o       ),
    .masku_result_id_o        ( masku_result_id_o        ),
    .masku_result_addr_o      ( masku_result_addr_o      ),
    .masku_result_wdata_o     ( masku_result_wdata_o     ),
    .masku_result_be_o        ( masku_result_be_o        ),
    .masku_result_gnt_i       ( masku_result_gnt_i       ),
    .masku_result_final_gnt_i ( masku_result_final_gnt_i ),
    .masku_vrgat_req_valid_o  ( masku_vrgat_req_valid_o  ),
    .masku_vrgat_req_ready_i  ( masku_vrgat_req_ready_i  ),
    .masku_vrgat_req_o        ( masku_vrgat_req_o        ),
    .mask_o                   ( mask_o                   ),
    .mask_valid_o             ( mask_valid_o             ),
    .mask_valid_lane_o        ( mask_valid_lane_o        ),
    .lane_mask_ready_i        ( lane_mask_ready_i        ),
    .vldu_mask_ready_i        ( vldu_mask_ready_i        ),
    .vstu_mask_ready_i        ( vstu_mask_ready_i        ),
    .sldu_mask_ready_i        ( sldu_mask_ready_i        )
  );

endmodule : synth_top
