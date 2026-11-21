module vlsu_synth_wrap import ara_pkg::*; import rvv_pkg::*; import axi_pkg::*; #(
  parameter int unsigned NrLanes      = 4,
  parameter int unsigned VLEN         = 4096,
  parameter int unsigned AxiDataWidth = 128,
  parameter int unsigned AxiAddrWidth = 64
) ();
  localparam int unsigned DataWidth = $bits(elen_t);
  localparam type strb_t = logic [DataWidth/8-1:0];
  localparam type vlen_t = logic [$clog2(VLEN+1)-1:0];
  localparam int unsigned VLENB = VLEN / 8;
  localparam type vaddr_t = logic [$clog2(VLENB/NrLanes)-1:0];
  localparam config_pkg::cva6_cfg_t CVA6AraConfig = build_config_pkg::build_config(cva6_config_pkg::cva6_cfg);

  typedef struct packed {
    logic [63:0] cause;
    logic [63:0] tval;
    logic [63:0] tval2;
    logic [31:0] tinst;
    logic        gva;
    logic        valid;
  } exception_t;

  `include "ara/ara_typedef.svh"
  `include "axi/typedef.svh"

  typedef logic [AxiAddrWidth-1:0]   axi_addr_t;
  typedef logic [AxiDataWidth-1:0]   axi_data_t;
  typedef logic [AxiDataWidth/8-1:0] axi_strb_t;
  typedef logic [0:0]                axi_id_t;
  typedef logic [0:0]                axi_user_t;

  `AXI_TYPEDEF_ALL(ara_axi, axi_addr_t, axi_id_t, axi_data_t, axi_strb_t, axi_user_t)

  logic clk_i, rst_ni;
  ara_axi_req_t axi_req_o;
  ara_axi_resp_t axi_resp_i;
  logic core_st_pending_i, load_complete_o, store_complete_o, store_pending_o;
  pe_req_t pe_req_i;
  logic pe_req_valid_i;
  logic [NrVInsn-1:0] pe_vinsn_running_i;
  logic [1:0] pe_req_ready_o;
  pe_resp_t [1:0] pe_resp_o;
  logic addrgen_ack_o, addrgen_fof_exception_o, lsu_current_burst_exception_o;
  exception_t addrgen_exception_o;
  vlen_t addrgen_exception_vstart_o;
  elen_t [NrLanes-1:0] stu_operand_i, addrgen_operand_i, ldu_result_wdata_o;
  logic [NrLanes-1:0] stu_operand_valid_i, stu_operand_ready_o, addrgen_operand_valid_i;
  logic addrgen_operand_ready_o, lsu_ex_flush_i, lsu_ex_flush_done_o;
  strb_t [NrLanes-1:0] mask_i, ldu_result_be_o;
  logic [NrLanes-1:0] mask_valid_i, ldu_result_req_o, ldu_result_gnt_i, ldu_result_final_gnt_i;
  logic vldu_mask_ready_o, vstu_mask_ready_o, en_ld_st_translation_i;
  logic mmu_misaligned_ex_o, mmu_req_o, mmu_is_store_o, mmu_dtlb_hit_i, mmu_valid_i;
  logic [CVA6AraConfig.VLEN-1:0] mmu_vaddr_o;
  logic [CVA6AraConfig.PPNW-1:0] mmu_dtlb_ppn_i;
  logic [CVA6AraConfig.PLEN-1:0] mmu_paddr_i;
  exception_t mmu_exception_i;
  vid_t [NrLanes-1:0] ldu_result_id_o;
  vaddr_t [NrLanes-1:0] ldu_result_addr_o;

  vlsu #(
    .NrLanes     (NrLanes          ),
    .VLEN        (VLEN             ),
    .vaddr_t     (vaddr_t          ),
    .pe_req_t    (pe_req_t         ),
    .pe_resp_t   (pe_resp_t        ),
    .CVA6Cfg     (CVA6AraConfig    ),
    .exception_t (exception_t      ),
    .AxiDataWidth(AxiDataWidth     ),
    .AxiAddrWidth(AxiAddrWidth     ),
    .axi_ar_t    (ara_axi_ar_chan_t),
    .axi_r_t     (ara_axi_r_chan_t ),
    .axi_aw_t    (ara_axi_aw_chan_t),
    .axi_w_t     (ara_axi_w_chan_t ),
    .axi_b_t     (ara_axi_b_chan_t ),
    .axi_req_t   (ara_axi_req_t    ),
    .axi_resp_t  (ara_axi_resp_t   )
  ) dut (.*);
endmodule
