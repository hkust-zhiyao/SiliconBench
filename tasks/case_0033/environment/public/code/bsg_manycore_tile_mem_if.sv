`include "bsg_manycore_defines.svh"

module bsg_manycore_tile_mem_if
  import bsg_manycore_pkg::*;
  import bsg_manycore_addr_pkg::*;
  import bsg_vanilla_pkg::*;
  #(parameter data_width_p = 32
    , parameter addr_width_p = 28
    , parameter x_cord_width_p = 7
    , parameter y_cord_width_p = 7
    , parameter pod_x_cord_width_p = 3
    , parameter pod_y_cord_width_p = 4
    , parameter num_tiles_x_p = 16
    , parameter num_tiles_y_p = 8
    , parameter vcache_size_p = 512
    , parameter vcache_block_size_in_words_p = 8
    , parameter vcache_sets_p = 64
    , parameter ipoly_hashing_p = 1
    , parameter icache_entries_p = 1024
    , parameter icache_tag_width_p = 12
    , parameter icache_block_size_in_words_p = 4
    , parameter dmem_size_p = 1024
    , parameter fifo_els_p = 2
    , parameter rev_fifo_els_p = 3
    , parameter credit_counter_width_p = `BSG_WIDTH(32)
    , localparam x_subcord_width_lp = `BSG_SAFE_CLOG2(num_tiles_x_p)
    , localparam y_subcord_width_lp = `BSG_SAFE_CLOG2(num_tiles_y_p)
    , localparam dmem_addr_width_lp = `BSG_SAFE_CLOG2(dmem_size_p)
    , localparam data_mask_width_lp = (data_width_p>>3)
    , localparam reg_addr_width_lp = RV32_reg_addr_width_gp
    , localparam pc_width_lp = (icache_tag_width_p + `BSG_SAFE_CLOG2(icache_entries_p))
    , localparam link_sif_width_lp = `bsg_manycore_link_sif_width(addr_width_p, data_width_p, x_cord_width_p, y_cord_width_p)
  )
  (
    input clk_i
    , input reset_i

    // mesh network link
    , input  [link_sif_width_lp-1:0] link_sif_i
    , output [link_sif_width_lp-1:0] link_sif_o

    // tile coordinates
    , input [x_subcord_width_lp-1:0] my_x_i
    , input [y_subcord_width_lp-1:0] my_y_i
    , input [pod_x_cord_width_p-1:0] pod_x_i
    , input [pod_y_cord_width_p-1:0] pod_y_i
    , input [pod_x_cord_width_p-1:0] cfg_pod_x_i
    , input [pod_y_cord_width_p-1:0] cfg_pod_y_i
    , input [x_subcord_width_lp-1:0] tgo_x_i
    , input [y_subcord_width_lp-1:0] tgo_y_i

    // from EXE stage to LSU
    , input decode_s exe_decode_i
    , input [data_width_p-1:0] exe_rs1_i
    , input [data_width_p-1:0] exe_rs2_i
    , input [reg_addr_width_lp-1:0] exe_rd_i
    , input [RV32_Iimm_width_gp-1:0] mem_offset_i
    , input [data_width_p-1:0] pc_plus4_i
    , input icache_miss_i
    , input stall_all_i
    , input flush_i

    // to local DMEM
    , output logic dmem_v_o
    , output logic dmem_w_o
    , output logic [dmem_addr_width_lp-1:0] dmem_addr_o
    , output logic [data_width_p-1:0] dmem_data_o
    , output logic [data_mask_width_lp-1:0] dmem_mask_o
    , output logic reserve_o
    , output logic [1:0] byte_sel_o

    // incoming request to tile client
    , output logic in_v_o
    , output logic [data_width_p-1:0] in_data_o
    , output logic [data_mask_width_lp-1:0] in_mask_o
    , output logic [addr_width_p-1:0] in_addr_o
    , output logic in_we_o
    , output bsg_manycore_load_info_s in_load_info_o
    , output logic [x_cord_width_p-1:0] in_src_x_cord_o
    , output logic [y_cord_width_p-1:0] in_src_y_cord_o
    , input in_yumi_i

    // outgoing response from tile client
    , input [data_width_p-1:0] returning_data_i
    , input returning_v_i

    // response to core pipeline
    , output logic remote_req_credit_o
    , output logic ifetch_v_o
    , output logic [data_width_p-1:0] ifetch_instr_o
    , output logic [reg_addr_width_lp-1:0] float_remote_load_resp_rd_o
    , output logic [data_width_p-1:0] float_remote_load_resp_data_o
    , output logic float_remote_load_resp_v_o
    , output logic float_remote_load_resp_force_o
    , input float_remote_load_resp_yumi_i
    , output logic [reg_addr_width_lp-1:0] int_remote_load_resp_rd_o
    , output logic [data_width_p-1:0] int_remote_load_resp_data_o
    , output logic int_remote_load_resp_v_o
    , output logic int_remote_load_resp_force_o
    , input int_remote_load_resp_yumi_i
    , output logic invalid_eva_access_o
    , output logic returned_credit_v_r_o
    , output logic [bsg_manycore_reg_id_width_gp-1:0] returned_credit_reg_id_r_o
    , output logic [credit_counter_width_p-1:0] out_credits_used_o
  );

  `declare_bsg_manycore_packet_s(addr_width_p, data_width_p, x_cord_width_p, y_cord_width_p);

  remote_req_s lsu_remote_req_lo;
  logic lsu_remote_req_v_lo;
  bsg_manycore_packet_s out_packet_lo;
  logic out_v_lo;
  logic out_credit_or_ready_lo;
  logic [data_width_p-1:0] returned_data_r_lo;
  logic [bsg_manycore_reg_id_width_gp-1:0] returned_reg_id_r_lo;
  logic returned_v_r_lo;
  bsg_manycore_return_packet_type_e returned_pkt_type_r_lo;
  logic returned_fifo_full_lo;
  logic returned_yumi_li;

  lsu #(
    .data_width_p(data_width_p)
    ,.pc_width_p(pc_width_lp)
    ,.dmem_size_p(dmem_size_p)
  ) u_lsu (
    .clk_i(clk_i)
    ,.reset_i(reset_i)
    ,.exe_decode_i(exe_decode_i)
    ,.exe_rs1_i(exe_rs1_i)
    ,.exe_rs2_i(exe_rs2_i)
    ,.exe_rd_i(exe_rd_i)
    ,.mem_offset_i(mem_offset_i)
    ,.pc_plus4_i(pc_plus4_i)
    ,.icache_miss_i(icache_miss_i)
    ,.remote_req_o(lsu_remote_req_lo)
    ,.remote_req_v_o(lsu_remote_req_v_lo)
    ,.dmem_v_o(dmem_v_o)
    ,.dmem_w_o(dmem_w_o)
    ,.dmem_addr_o(dmem_addr_o)
    ,.dmem_data_o(dmem_data_o)
    ,.dmem_mask_o(dmem_mask_o)
    ,.reserve_o(reserve_o)
    ,.byte_sel_o(byte_sel_o)
  );

  network_tx #(
    .data_width_p(data_width_p)
    ,.addr_width_p(addr_width_p)
    ,.x_cord_width_p(x_cord_width_p)
    ,.y_cord_width_p(y_cord_width_p)
    ,.pod_x_cord_width_p(pod_x_cord_width_p)
    ,.pod_y_cord_width_p(pod_y_cord_width_p)
    ,.vcache_size_p(vcache_size_p)
    ,.vcache_block_size_in_words_p(vcache_block_size_in_words_p)
    ,.vcache_sets_p(vcache_sets_p)
    ,.ipoly_hashing_p(ipoly_hashing_p)
    ,.num_tiles_x_p(num_tiles_x_p)
    ,.num_tiles_y_p(num_tiles_y_p)
    ,.icache_entries_p(icache_entries_p)
    ,.icache_tag_width_p(icache_tag_width_p)
  ) u_tx (
    .clk_i(clk_i)
    ,.reset_i(reset_i)
    ,.flush_i(flush_i)
    ,.out_packet_o(out_packet_lo)
    ,.out_v_o(out_v_lo)
    ,.out_credit_or_ready_i(out_credit_or_ready_lo)
    ,.returned_v_i(returned_v_r_lo)
    ,.returned_data_i(returned_data_r_lo)
    ,.returned_reg_id_i(returned_reg_id_r_lo)
    ,.returned_pkt_type_i(returned_pkt_type_r_lo)
    ,.returned_fifo_full_i(returned_fifo_full_lo)
    ,.returned_yumi_o(returned_yumi_li)
    ,.tgo_x_i(tgo_x_i)
    ,.tgo_y_i(tgo_y_i)
    ,.my_x_i(my_x_i)
    ,.my_y_i(my_y_i)
    ,.pod_x_i(pod_x_i)
    ,.pod_y_i(pod_y_i)
    ,.cfg_pod_x_i(cfg_pod_x_i)
    ,.cfg_pod_y_i(cfg_pod_y_i)
    ,.remote_req_i(lsu_remote_req_lo)
    ,.remote_req_v_i(lsu_remote_req_v_lo & ~stall_all_i)
    ,.remote_req_credit_o(remote_req_credit_o)
    ,.ifetch_v_o(ifetch_v_o)
    ,.ifetch_instr_o(ifetch_instr_o)
    ,.float_remote_load_resp_rd_o(float_remote_load_resp_rd_o)
    ,.float_remote_load_resp_data_o(float_remote_load_resp_data_o)
    ,.float_remote_load_resp_v_o(float_remote_load_resp_v_o)
    ,.float_remote_load_resp_force_o(float_remote_load_resp_force_o)
    ,.float_remote_load_resp_yumi_i(float_remote_load_resp_yumi_i)
    ,.int_remote_load_resp_rd_o(int_remote_load_resp_rd_o)
    ,.int_remote_load_resp_data_o(int_remote_load_resp_data_o)
    ,.int_remote_load_resp_v_o(int_remote_load_resp_v_o)
    ,.int_remote_load_resp_force_o(int_remote_load_resp_force_o)
    ,.int_remote_load_resp_yumi_i(int_remote_load_resp_yumi_i)
    ,.invalid_eva_access_o(invalid_eva_access_o)
  );

  bsg_manycore_endpoint_standard #(
    .x_cord_width_p(x_cord_width_p)
    ,.y_cord_width_p(y_cord_width_p)
    ,.fifo_els_p(fifo_els_p)
    ,.data_width_p(data_width_p)
    ,.addr_width_p(addr_width_p)
    ,.icache_block_size_in_words_p(icache_block_size_in_words_p)
    ,.credit_counter_width_p(credit_counter_width_p)
    ,.rev_fifo_els_p(rev_fifo_els_p)
    ,.use_credits_for_local_fifo_p(1)
  ) u_endp (
    .clk_i(clk_i)
    ,.reset_i(reset_i)
    ,.link_sif_i(link_sif_i)
    ,.link_sif_o(link_sif_o)
    ,.in_v_o(in_v_o)
    ,.in_data_o(in_data_o)
    ,.in_mask_o(in_mask_o)
    ,.in_addr_o(in_addr_o)
    ,.in_we_o(in_we_o)
    ,.in_load_info_o(in_load_info_o)
    ,.in_src_x_cord_o(in_src_x_cord_o)
    ,.in_src_y_cord_o(in_src_y_cord_o)
    ,.in_yumi_i(in_yumi_i)
    ,.returning_data_i(returning_data_i)
    ,.returning_v_i(returning_v_i)
    ,.out_v_i(out_v_lo)
    ,.out_packet_i(out_packet_lo)
    ,.out_credit_or_ready_o(out_credit_or_ready_lo)
    ,.returned_data_r_o(returned_data_r_lo)
    ,.returned_reg_id_r_o(returned_reg_id_r_lo)
    ,.returned_v_r_o(returned_v_r_lo)
    ,.returned_pkt_type_r_o(returned_pkt_type_r_lo)
    ,.returned_yumi_i(returned_yumi_li)
    ,.returned_fifo_full_o(returned_fifo_full_lo)
    ,.returned_credit_v_r_o(returned_credit_v_r_o)
    ,.returned_credit_reg_id_r_o(returned_credit_reg_id_r_o)
    ,.out_credits_used_o(out_credits_used_o)
    ,.global_x_i({pod_x_i, my_x_i})
    ,.global_y_i({pod_y_i, my_y_i})
  );

endmodule
