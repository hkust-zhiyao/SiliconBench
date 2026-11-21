
`include "axi/typedef.svh"
`include "axi_llc/typedef.svh"
module axi_llc_top_wrap #(
  parameter int unsigned SetAssociativity = 32'd2,
  parameter int unsigned NumLines         = 32'd64,
  parameter int unsigned NumBlocks        = 32'd4,
  parameter int unsigned AxiIdWidth       = 32'd4,
  parameter int unsigned AxiAddrWidth     = 32'd32,
  parameter int unsigned AxiDataWidth     = 32'd64,
  parameter int unsigned AxiUserWidth     = 32'd1
) (
  input  logic                        clk_i,
  input  logic                        rst_ni,
  input  logic                        test_i,
  // AXI4 Slave AW/W/B/AR/R
  input  logic [AxiIdWidth-1:0]       slv_aw_id_i,
  input  logic [AxiAddrWidth-1:0]     slv_aw_addr_i,
  input  logic [7:0]                  slv_aw_len_i,
  input  logic [2:0]                  slv_aw_size_i,
  input  logic [1:0]                  slv_aw_burst_i,
  input  logic                        slv_aw_lock_i,
  input  logic [3:0]                  slv_aw_cache_i,
  input  logic [2:0]                  slv_aw_prot_i,
  input  logic                        slv_aw_valid_i,
  output logic                        slv_aw_ready_o,
  input  logic [AxiDataWidth-1:0]     slv_w_data_i,
  input  logic [AxiDataWidth/8-1:0]   slv_w_strb_i,
  input  logic                        slv_w_last_i,
  input  logic                        slv_w_valid_i,
  output logic                        slv_w_ready_o,
  output logic [AxiIdWidth-1:0]       slv_b_id_o,
  output logic [1:0]                  slv_b_resp_o,
  output logic                        slv_b_valid_o,
  input  logic                        slv_b_ready_i,
  input  logic [AxiIdWidth-1:0]       slv_ar_id_i,
  input  logic [AxiAddrWidth-1:0]     slv_ar_addr_i,
  input  logic [7:0]                  slv_ar_len_i,
  input  logic [2:0]                  slv_ar_size_i,
  input  logic [1:0]                  slv_ar_burst_i,
  input  logic                        slv_ar_lock_i,
  input  logic [3:0]                  slv_ar_cache_i,
  input  logic [2:0]                  slv_ar_prot_i,
  input  logic                        slv_ar_valid_i,
  output logic                        slv_ar_ready_o,
  output logic [AxiIdWidth-1:0]       slv_r_id_o,
  output logic [AxiDataWidth-1:0]     slv_r_data_o,
  output logic [1:0]                  slv_r_resp_o,
  output logic                        slv_r_last_o,
  output logic                        slv_r_valid_o,
  input  logic                        slv_r_ready_i,
  // AXI4 Master AW/W/B/AR/R
  output logic [AxiIdWidth:0]         mst_aw_id_o,
  output logic [AxiAddrWidth-1:0]     mst_aw_addr_o,
  output logic [7:0]                  mst_aw_len_o,
  output logic [2:0]                  mst_aw_size_o,
  output logic [1:0]                  mst_aw_burst_o,
  output logic                        mst_aw_lock_o,
  output logic [3:0]                  mst_aw_cache_o,
  output logic [2:0]                  mst_aw_prot_o,
  output logic                        mst_aw_valid_o,
  input  logic                        mst_aw_ready_i,
  output logic [AxiDataWidth-1:0]     mst_w_data_o,
  output logic [AxiDataWidth/8-1:0]   mst_w_strb_o,
  output logic                        mst_w_last_o,
  output logic                        mst_w_valid_o,
  input  logic                        mst_w_ready_i,
  input  logic [AxiIdWidth:0]         mst_b_id_i,
  input  logic [1:0]                  mst_b_resp_i,
  input  logic                        mst_b_valid_i,
  output logic                        mst_b_ready_o,
  output logic [AxiIdWidth:0]         mst_ar_id_o,
  output logic [AxiAddrWidth-1:0]     mst_ar_addr_o,
  output logic [7:0]                  mst_ar_len_o,
  output logic [2:0]                  mst_ar_size_o,
  output logic [1:0]                  mst_ar_burst_o,
  output logic                        mst_ar_lock_o,
  output logic [3:0]                  mst_ar_cache_o,
  output logic [2:0]                  mst_ar_prot_o,
  output logic                        mst_ar_valid_o,
  input  logic                        mst_ar_ready_i,
  input  logic [AxiIdWidth:0]         mst_r_id_i,
  input  logic [AxiDataWidth-1:0]     mst_r_data_i,
  input  logic [1:0]                  mst_r_resp_i,
  input  logic                        mst_r_last_i,
  input  logic                        mst_r_valid_i,
  output logic                        mst_r_ready_o,
  // Synchronous config control & status
  input  logic [SetAssociativity-1:0] cfg_spm_i,
  input  logic [SetAssociativity-1:0] cfg_flush_i,
  input  logic                        commit_cfg_i,
  output logic [SetAssociativity-1:0] flushed_o,
  output logic [SetAssociativity-1:0] bist_out_o,
  output logic                        bist_done_o,
  // Static address-map straps
  input  logic [AxiAddrWidth-1:0]     cached_start_addr_i,
  input  logic [AxiAddrWidth-1:0]     cached_end_addr_i,
  input  logic [AxiAddrWidth-1:0]     spm_start_addr_i
);
  typedef logic [AxiIdWidth-1:0]       slv_id_t;
  typedef logic [AxiIdWidth:0]         mst_id_t;
  typedef logic [AxiAddrWidth-1:0]     addr_t;
  typedef logic [AxiDataWidth-1:0]     data_t;
  typedef logic [AxiDataWidth/8-1:0]   strb_t;
  typedef logic [AxiUserWidth-1:0]     user_t;
  typedef logic [SetAssociativity-1:0] way_ind_t;

  `AXI_TYPEDEF_ALL(slv, addr_t, slv_id_t, data_t, strb_t, user_t)
  `AXI_TYPEDEF_ALL(mst, addr_t, mst_id_t, data_t, strb_t, user_t)
  `AXI_LLC_TYPEDEF_ALL(llc, logic [63:0], way_ind_t)

  typedef struct packed {
    int unsigned idx;
    addr_t       start_addr;
    addr_t       end_addr;
  } rule_32_t;

  slv_req_t  slv_req;
  slv_resp_t slv_resp;
  mst_req_t  mst_req;
  mst_resp_t mst_resp;
  llc_cfg_regs_q_t conf_q;
  llc_cfg_regs_d_t conf_d;
  way_ind_t  flushed_q, bist_out_q;
  logic      bist_done_q;

  always_comb begin
    slv_req          = '0;
    slv_req.aw.id    = slv_aw_id_i;
    slv_req.aw.addr  = slv_aw_addr_i;
    slv_req.aw.len   = slv_aw_len_i;
    slv_req.aw.size  = slv_aw_size_i;
    slv_req.aw.burst = slv_aw_burst_i;
    slv_req.aw.lock  = slv_aw_lock_i;
    slv_req.aw.cache = slv_aw_cache_i;
    slv_req.aw.prot  = slv_aw_prot_i;
    slv_req.aw_valid = slv_aw_valid_i;
    slv_req.w.data   = slv_w_data_i;
    slv_req.w.strb   = slv_w_strb_i;
    slv_req.w.last   = slv_w_last_i;
    slv_req.w_valid  = slv_w_valid_i;
    slv_req.b_ready  = slv_b_ready_i;
    slv_req.ar.id    = slv_ar_id_i;
    slv_req.ar.addr  = slv_ar_addr_i;
    slv_req.ar.len   = slv_ar_len_i;
    slv_req.ar.size  = slv_ar_size_i;
    slv_req.ar.burst = slv_ar_burst_i;
    slv_req.ar.lock  = slv_ar_lock_i;
    slv_req.ar.cache = slv_ar_cache_i;
    slv_req.ar.prot  = slv_ar_prot_i;
    slv_req.ar_valid = slv_ar_valid_i;
    slv_req.r_ready  = slv_r_ready_i;

    mst_resp          = '0;
    mst_resp.aw_ready = mst_aw_ready_i;
    mst_resp.w_ready  = mst_w_ready_i;
    mst_resp.b.id     = mst_b_id_i;
    mst_resp.b.resp   = mst_b_resp_i;
    mst_resp.b_valid  = mst_b_valid_i;
    mst_resp.ar_ready = mst_ar_ready_i;
    mst_resp.r.id     = mst_r_id_i;
    mst_resp.r.data   = mst_r_data_i;
    mst_resp.r.resp   = mst_r_resp_i;
    mst_resp.r.last   = mst_r_last_i;
    mst_resp.r_valid  = mst_r_valid_i;
  end

  assign slv_aw_ready_o = slv_resp.aw_ready;
  assign slv_w_ready_o  = slv_resp.w_ready;
  assign slv_b_id_o     = slv_resp.b.id;
  assign slv_b_resp_o   = slv_resp.b.resp;
  assign slv_b_valid_o  = slv_resp.b_valid;
  assign slv_ar_ready_o = slv_resp.ar_ready;
  assign slv_r_id_o     = slv_resp.r.id;
  assign slv_r_data_o   = slv_resp.r.data;
  assign slv_r_resp_o   = slv_resp.r.resp;
  assign slv_r_last_o   = slv_resp.r.last;
  assign slv_r_valid_o  = slv_resp.r_valid;

  assign mst_aw_id_o    = mst_req.aw.id;
  assign mst_aw_addr_o  = mst_req.aw.addr;
  assign mst_aw_len_o   = mst_req.aw.len;
  assign mst_aw_size_o  = mst_req.aw.size;
  assign mst_aw_burst_o = mst_req.aw.burst;
  assign mst_aw_lock_o  = mst_req.aw.lock;
  assign mst_aw_cache_o = mst_req.aw.cache;
  assign mst_aw_prot_o  = mst_req.aw.prot;
  assign mst_aw_valid_o = mst_req.aw_valid;
  assign mst_w_data_o   = mst_req.w.data;
  assign mst_w_strb_o   = mst_req.w.strb;
  assign mst_w_last_o   = mst_req.w.last;
  assign mst_w_valid_o  = mst_req.w_valid;
  assign mst_b_ready_o  = mst_req.b_ready;
  assign mst_ar_id_o    = mst_req.ar.id;
  assign mst_ar_addr_o  = mst_req.ar.addr;
  assign mst_ar_len_o   = mst_req.ar.len;
  assign mst_ar_size_o  = mst_req.ar.size;
  assign mst_ar_burst_o = mst_req.ar.burst;
  assign mst_ar_lock_o  = mst_req.ar.lock;
  assign mst_ar_cache_o = mst_req.ar.cache;
  assign mst_ar_prot_o  = mst_req.ar.prot;
  assign mst_ar_valid_o = mst_req.ar_valid;
  assign mst_r_ready_o  = mst_req.r_ready;

  logic [SetAssociativity-1:0] cfg_spm_q, cfg_flush_q;
  logic                        commit_cfg_q;
  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      cfg_spm_q    <= '0;
      cfg_flush_q  <= '0;
      commit_cfg_q <= 1'b0;
      flushed_q    <= '0;
      bist_out_q   <= '0;
      bist_done_q  <= 1'b0;
    end else begin
      cfg_spm_q    <= cfg_spm_i;
      cfg_flush_q  <= (commit_cfg_i ? cfg_flush_i : (conf_d.cfg_flush_en ? conf_d.cfg_flush[SetAssociativity-1:0] : cfg_flush_q));
      commit_cfg_q <= commit_cfg_i ? 1'b1 : (conf_d.commit_cfg_en ? conf_d.commit_cfg : commit_cfg_q);
      if (conf_d.flushed_en)    flushed_q   <= conf_d.flushed;
      if (conf_d.bist_out_en)   bist_out_q  <= conf_d.bist_out;
      if (conf_d.bist_status_en) bist_done_q <= conf_d.bist_status_done;
    end
  end

  assign conf_q = llc_cfg_regs_q_t'{
    cfg_spm:    cfg_spm_q,
    cfg_flush:  64'(cfg_flush_q),
    commit_cfg: commit_cfg_q,
    flushed:    flushed_q
  };
  assign flushed_o   = flushed_q;
  assign bist_out_o  = bist_out_q;
  assign bist_done_o = bist_done_q;

  axi_llc_top #(
    .SetAssociativity ( SetAssociativity ),
    .NumLines         ( NumLines         ),
    .NumBlocks        ( NumBlocks        ),
    .AxiIdWidth       ( AxiIdWidth       ),
    .AxiAddrWidth     ( AxiAddrWidth     ),
    .AxiDataWidth     ( AxiDataWidth     ),
    .AxiUserWidth     ( AxiUserWidth     ),
    .RegWidth         ( 32'd64           ),
    .conf_regs_d_t    ( llc_cfg_regs_d_t ),
    .conf_regs_q_t    ( llc_cfg_regs_q_t ),
    .slv_req_t        ( slv_req_t        ),
    .slv_resp_t       ( slv_resp_t       ),
    .mst_req_t        ( mst_req_t        ),
    .mst_resp_t       ( mst_resp_t       ),
    .rule_full_t      ( rule_32_t        )
  ) u_dut (
    .clk_i, .rst_ni, .test_i,
    .slv_req_i           ( slv_req  ),
    .slv_resp_o          ( slv_resp ),
    .mst_req_o           ( mst_req  ),
    .mst_resp_i          ( mst_resp ),
    .conf_regs_i         ( conf_q   ),
    .conf_regs_o         ( conf_d   ),
    .cached_start_addr_i,
    .cached_end_addr_i,
    .spm_start_addr_i,
    .axi_llc_events_o    (          )
  );
endmodule
