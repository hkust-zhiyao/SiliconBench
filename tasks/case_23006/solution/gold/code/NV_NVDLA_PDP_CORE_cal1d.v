// ================================================================
// NVDLA Open Source Project
// 
// Copyright(c) 2016 - 2017 NVIDIA Corporation.  Licensed under the
// NVDLA Open Hardware License; Check "LICENSE" which comes with 
// this distribution for more information.
// ================================================================

// File Name: NV_NVDLA_PDP_CORE_cal1d.v

module NV_NVDLA_PDP_CORE_cal1d (
   nvdla_core_clk
  ,nvdla_core_rstn
  ,datin_src_cfg
  ,dp2reg_done
  ,nvdla_op_gated_clk_fp16
  ,padding_h_cfg
  ,pdp_rdma2dp_pd
  ,pdp_rdma2dp_valid
  ,pooling1d_prdy
  ,pooling_channel_cfg
  ,pooling_fwidth_cfg
  ,pooling_lwidth_cfg
  ,pooling_mwidth_cfg
  ,pooling_out_fwidth_cfg
  ,pooling_out_lwidth_cfg
  ,pooling_out_mwidth_cfg
  ,pooling_size_h_cfg
  ,pooling_splitw_num_cfg
  ,pooling_stride_h_cfg
  ,pooling_type_cfg
  ,pwrbus_ram_pd
  ,reg2dp_cube_in_height
  ,reg2dp_cube_in_width
  ,reg2dp_cube_out_width
  ,reg2dp_fp16_en
  ,reg2dp_input_data
  ,reg2dp_int16_en
  ,reg2dp_int8_en
  ,reg2dp_kernel_stride_width
  ,reg2dp_kernel_width
  ,reg2dp_op_en
  ,reg2dp_pad_left
  ,reg2dp_pad_right
  ,reg2dp_pad_right_cfg
  ,reg2dp_pad_value_1x_cfg
  ,reg2dp_pad_value_2x_cfg
  ,reg2dp_pad_value_3x_cfg
  ,reg2dp_pad_value_4x_cfg
  ,reg2dp_pad_value_5x_cfg
  ,reg2dp_pad_value_6x_cfg
  ,reg2dp_pad_value_7x_cfg
  ,sdp2pdp_pd
  ,sdp2pdp_valid
  ,pdp_op_start
  ,pdp_rdma2dp_ready
  ,pooling1d_pd
  ,pooling1d_pvld
  ,sdp2pdp_ready
  );

input          nvdla_core_clk;
input          nvdla_core_rstn;
input          datin_src_cfg;
input          dp2reg_done;
input          nvdla_op_gated_clk_fp16;
input    [2:0] padding_h_cfg;
input   [75:0] pdp_rdma2dp_pd;
input          pdp_rdma2dp_valid;
input          pooling1d_prdy;
input   [12:0] pooling_channel_cfg;
input    [9:0] pooling_fwidth_cfg;
input    [9:0] pooling_lwidth_cfg;
input    [9:0] pooling_mwidth_cfg;
input    [9:0] pooling_out_fwidth_cfg;
input    [9:0] pooling_out_lwidth_cfg;
input    [9:0] pooling_out_mwidth_cfg;
input    [2:0] pooling_size_h_cfg;
input    [7:0] pooling_splitw_num_cfg;
input    [3:0] pooling_stride_h_cfg;
input    [1:0] pooling_type_cfg;
input   [31:0] pwrbus_ram_pd;
input   [12:0] reg2dp_cube_in_height;
input   [12:0] reg2dp_cube_in_width;
input   [12:0] reg2dp_cube_out_width;
input          reg2dp_fp16_en;
input    [1:0] reg2dp_input_data;
input          reg2dp_int16_en;
input          reg2dp_int8_en;
input    [3:0] reg2dp_kernel_stride_width;
input    [2:0] reg2dp_kernel_width;
input          reg2dp_op_en;
input    [2:0] reg2dp_pad_left;
input    [2:0] reg2dp_pad_right;
input    [2:0] reg2dp_pad_right_cfg;
input   [18:0] reg2dp_pad_value_1x_cfg;
input   [18:0] reg2dp_pad_value_2x_cfg;
input   [18:0] reg2dp_pad_value_3x_cfg;
input   [18:0] reg2dp_pad_value_4x_cfg;
input   [18:0] reg2dp_pad_value_5x_cfg;
input   [18:0] reg2dp_pad_value_6x_cfg;
input   [18:0] reg2dp_pad_value_7x_cfg;
input   [75:0] sdp2pdp_pd;
input          sdp2pdp_valid;
output         pdp_op_start;
output         pdp_rdma2dp_ready;
output [111:0] pooling1d_pd;
output         pooling1d_pvld;
output         sdp2pdp_ready;
wire           average_pooling_en;
wire           big_stride;
wire           bsync;
wire           bubble_en_end;
wire     [2:0] bubble_num_dec;
wire    [13:0] cube_out_channel;
wire     [3:0] cube_width_in;
wire           cur_datin_disable_sync;
wire    [21:0] datain_16bit_0;
wire    [21:0] datain_16bit_1;
wire    [21:0] datain_16bit_2;
wire    [21:0] datain_16bit_3;
wire    [21:0] datain_8bit_0;
wire    [21:0] datain_8bit_1;
wire    [21:0] datain_8bit_2;
wire    [21:0] datain_8bit_3;
wire    [87:0] datain_ext;
wire    [21:0] datain_ext_0;
wire    [21:0] datain_ext_1;
wire    [21:0] datain_ext_2;
wire    [21:0] datain_ext_3;
wire    [96:0] datin_buf;
wire    [96:0] datin_buf_1;
wire     [2:0] first_out_num_dec2;
wire           first_splitw;
wire           first_splitw_en;
wire           fp16_add_pad_in0_a_rdy;
wire           fp16_add_pad_in0_a_vld;
wire           fp16_add_pad_in0_b_rdy;
wire           fp16_add_pad_in0_b_vld;
wire           fp16_add_pad_in1_a_rdy;
wire           fp16_add_pad_in1_a_vld;
wire           fp16_add_pad_in1_b_rdy;
wire           fp16_add_pad_in1_b_vld;
wire           fp16_add_pad_in2_a_rdy;
wire           fp16_add_pad_in2_a_vld;
wire           fp16_add_pad_in2_b_rdy;
wire           fp16_add_pad_in2_b_vld;
wire           fp16_add_pad_in3_a_rdy;
wire           fp16_add_pad_in3_a_vld;
wire           fp16_add_pad_in3_b_rdy;
wire           fp16_add_pad_in3_b_vld;
wire    [16:0] fp16_add_pad_out0;
wire           fp16_add_pad_out0_rdy;
wire           fp16_add_pad_out0_vld;
wire    [16:0] fp16_add_pad_out1;
wire           fp16_add_pad_out1_rdy;
wire           fp16_add_pad_out1_vld;
wire    [16:0] fp16_add_pad_out2;
wire           fp16_add_pad_out2_rdy;
wire           fp16_add_pad_out2_vld;
wire    [16:0] fp16_add_pad_out3;
wire           fp16_add_pad_out3_rdy;
wire           fp16_add_pad_out3_vld;
wire           fp16_en;
wire           fp16_in_prdy;
wire           fp16_in_pvld;
wire           fp16_mean_din_pvld;
wire           fp16_mean_pool_cfg;
wire   [111:0] fp16_out_dp;
wire           fp16_out_prdy;
wire           fp16_out_pvld;
wire    [79:0] fp16_switch_out_pd;
wire           fp16_switch_out_vld;
wire           init_cnt;
wire     [7:0] init_unit1d_set;
wire    [10:0] k_add_ks;
wire     [4:0] kernel_padl;
wire     [4:0] ks_width;
wire           last_c;
wire           last_c_sync;
wire           last_line_in;
wire           last_out_done;
wire           last_out_en_sync;
wire           last_pooling_flag;
wire           last_splitw;
wire           last_splitw_en;
wire           line_last_stripe_done;
wire           line_ldata_valid;
wire     [2:0] line_regs_1;
wire     [2:0] line_regs_2;
wire     [2:0] line_regs_3;
wire     [2:0] line_regs_4;
wire           load_din;
wire           loading_en;
wire           mon_deno_in;
wire     [2:0] mon_first_out_num_dec2;
wire           mon_inf_in;
wire           mon_nan_in;
wire           mon_overlap;
wire     [1:0] mon_overlap_ff;
wire     [0:0] mon_pad_table_index;
wire           mon_rest_width;
wire     [5:0] mon_strip_xcnt_offset;
wire           mon_surface_num_0;
wire     [0:0] mon_unit1d_actv_data_16bit_0;
wire     [0:0] mon_unit1d_actv_data_16bit_0_ff;
wire     [0:0] mon_unit1d_actv_data_16bit_1;
wire     [0:0] mon_unit1d_actv_data_16bit_1_ff;
wire     [0:0] mon_unit1d_actv_data_16bit_2;
wire     [0:0] mon_unit1d_actv_data_16bit_2_ff;
wire     [0:0] mon_unit1d_actv_data_16bit_3;
wire     [0:0] mon_unit1d_actv_data_16bit_3_ff;
wire     [1:0] mon_unit1d_actv_data_8bit_0;
wire     [1:0] mon_unit1d_actv_data_8bit_0_ff;
wire     [1:0] mon_unit1d_actv_data_8bit_1;
wire     [1:0] mon_unit1d_actv_data_8bit_1_ff;
wire     [1:0] mon_unit1d_actv_data_8bit_2;
wire     [1:0] mon_unit1d_actv_data_8bit_2_ff;
wire     [1:0] mon_unit1d_actv_data_8bit_3;
wire     [1:0] mon_unit1d_actv_data_8bit_3_ff;
wire     [1:0] mon_unit1d_actv_data_8bit_4;
wire     [1:0] mon_unit1d_actv_data_8bit_4_ff;
wire     [1:0] mon_unit1d_actv_data_8bit_5;
wire     [1:0] mon_unit1d_actv_data_8bit_5_ff;
wire     [1:0] mon_unit1d_actv_data_8bit_6;
wire     [1:0] mon_unit1d_actv_data_8bit_6_ff;
wire     [1:0] mon_unit1d_actv_data_8bit_7;
wire     [1:0] mon_unit1d_actv_data_8bit_7_ff;
wire           non_split_small_active;
wire     [3:0] non_split_w_pl;
wire     [4:0] non_split_w_pl_pr;
wire           non_splitw;
wire           off_flying_en;
wire           on_flying_en;
wire     [3:0] overlap;
wire     [2:0] overlap_ff;
wire     [2:0] pad_l;
wire     [2:0] pad_r;
wire     [2:0] pad_table_index;
wire           padding_here;
wire           padding_here_int16;
wire           padding_here_int8;
wire     [2:0] padding_stride1_num;
wire     [2:0] padding_stride2_num;
wire     [2:0] padding_stride3_num;
wire     [2:0] padding_stride4_num;
wire    [10:0] partial_w_last;
wire           pdp_cube_end;
wire           pdp_cube_sync;
wire   [100:0] pdp_datin_pd;
wire   [100:0] pdp_datin_pd_f0;
wire    [87:0] pdp_datin_pd_f1;
wire    [79:0] pdp_datin_pd_f_0;
wire    [75:0] pdp_datin_pd_f_mux0;
wire           pdp_datin_prdy;
wire           pdp_datin_prdy0;
wire           pdp_datin_prdy1;
wire           pdp_datin_prdy_0;
wire           pdp_datin_prdy_1;
wire           pdp_datin_prdy_f;
wire           pdp_datin_prdy_mux0;
wire           pdp_datin_pvld;
wire           pdp_datin_pvld_f;
wire           pdp_datin_pvld_f0;
wire           pdp_datin_pvld_f1;
wire           pdp_datin_pvld_mux0;
wire    [16:0] pdp_din_0;
wire    [16:0] pdp_din_1;
wire    [16:0] pdp_din_2;
wire    [16:0] pdp_din_3;
wire           pdp_din_lc;
wire           pdp_din_lc_sync;
wire           pdp_full_pvld;
wire    [11:0] pdp_info_in_pd;
wire           pdp_info_in_prdy;
wire           pdp_info_in_pvld;
wire    [11:0] pdp_info_out_pd;
wire           pdp_info_out_prdy;
wire           pdp_info_out_pvld;
wire           pooling1d_data_pad_rdy;
wire           pooling1d_out_v;
wire           pooling1d_out_v_disable;
wire           pooling1d_out_v_lastout;
wire           pooling1d_out_v_norm;
wire           pooling_1d_rdy;
wire     [7:0] pooling_din_last;
wire     [7:0] pooling_din_last_sync;
wire     [3:0] pooling_size;
wire     [3:0] pooling_size_h;
wire     [4:0] pooling_stride_h;
wire           posc_last;
wire    [12:0] pout_width_cur;
wire    [12:0] rest_width;
wire    [13:0] rest_width_use;
wire           split_small_active;
wire     [5:0] split_w_olap;
wire     [6:0] split_w_olap_pr;
wire           splitw_enable;
wire           splitw_end;
wire           splitw_end_sync;
wire           splitw_start;
wire     [4:0] stride;
wire     [4:0] stride_1x;
wire     [5:0] stride_2x;
wire     [6:0] stride_3x;
wire     [6:0] stride_4x;
wire     [7:0] stride_5x;
wire     [7:0] stride_6x;
wire     [7:0] stride_7x;
wire           stride_end;
wire           strip_recieve_done;
wire           strip_width_end;
wire     [2:0] strip_xcnt_offset;
wire     [9:0] surface_num;
wire     [9:0] surface_num_0;
wire     [9:0] surface_num_1;
wire           switch_in_prdy;
wire     [3:0] switch_in_rdy;
wire     [3:0] switch_in_vld;
wire    [16:0] switch_out_0;
wire    [16:0] switch_out_1;
wire    [16:0] switch_out_2;
wire    [16:0] switch_out_3;
wire     [3:0] switch_out_rdy;
wire     [3:0] switch_out_vld;
wire    [11:0] sync_switch_in_pd;
wire    [11:0] sync_switch_in_pd_d0;
wire    [11:0] sync_switch_in_pd_d1;
wire           sync_switch_in_rdy;
wire           sync_switch_in_rdy_d0;
wire           sync_switch_in_rdy_d1;
wire           sync_switch_in_vld;
wire           sync_switch_in_vld_d0;
wire           sync_switch_in_vld_d1;
wire    [11:0] sync_switch_out_pd;
wire           sync_switch_out_rdy;
wire           sync_switch_out_vld;
wire    [21:0] unit1d_actv_data_16bit_0;
wire    [21:0] unit1d_actv_data_16bit_0_ff;
wire    [21:0] unit1d_actv_data_16bit_1;
wire    [21:0] unit1d_actv_data_16bit_1_ff;
wire    [21:0] unit1d_actv_data_16bit_2;
wire    [21:0] unit1d_actv_data_16bit_2_ff;
wire    [21:0] unit1d_actv_data_16bit_3;
wire    [21:0] unit1d_actv_data_16bit_3_ff;
wire    [10:0] unit1d_actv_data_8bit_0;
wire    [10:0] unit1d_actv_data_8bit_0_ff;
wire    [10:0] unit1d_actv_data_8bit_1;
wire    [10:0] unit1d_actv_data_8bit_1_ff;
wire    [10:0] unit1d_actv_data_8bit_2;
wire    [10:0] unit1d_actv_data_8bit_2_ff;
wire    [10:0] unit1d_actv_data_8bit_3;
wire    [10:0] unit1d_actv_data_8bit_3_ff;
wire    [10:0] unit1d_actv_data_8bit_4;
wire    [10:0] unit1d_actv_data_8bit_4_ff;
wire    [10:0] unit1d_actv_data_8bit_5;
wire    [10:0] unit1d_actv_data_8bit_5_ff;
wire    [10:0] unit1d_actv_data_8bit_6;
wire    [10:0] unit1d_actv_data_8bit_6_ff;
wire    [10:0] unit1d_actv_data_8bit_7;
wire    [10:0] unit1d_actv_data_8bit_7_ff;
wire    [91:0] unit1d_actv_out;
wire           unit1d_actv_out_prdy;
wire           unit1d_actv_out_pvld;
wire     [7:0] unit1d_clr;
wire    [91:0] unit1d_out_0;
wire    [91:0] unit1d_out_1;
wire    [91:0] unit1d_out_2;
wire    [91:0] unit1d_out_3;
wire    [91:0] unit1d_out_4;
wire    [91:0] unit1d_out_5;
wire    [91:0] unit1d_out_6;
wire    [91:0] unit1d_out_7;
wire     [7:0] unit1d_out_prdy;
wire           unit1d_out_prdy_use;
wire     [7:0] unit1d_out_pvld;
wire           unit1d_out_pvld_use;
wire     [7:0] unit1d_prdy;
wire     [7:0] unit1d_pvld;
wire     [7:0] unit1d_set;
wire     [7:0] unit1d_set_trig;
wire           wr_line_dat_done;
wire           wr_subcube_dat_done;
wire           wr_surface_dat_done;
wire           wr_total_cube_done;

reg      [2:0] bubble_cnt;
reg      [2:0] bubble_num;
reg      [1:0] channel_cnt;
reg            cur_datin_disable;
reg      [4:0] first_out_num;
reg      [2:0] flush_num;
reg      [2:0] flush_num_cal;
reg      [2:0] last_out_cnt;
reg            last_out_en;
reg      [6:0] mon_first_out_num;
reg            need_bubble;
reg    [100:0] p2_pipe_data;
reg    [100:0] p2_pipe_rand_data;
reg            p2_pipe_rand_ready;
reg            p2_pipe_rand_valid;
reg            p2_pipe_ready;
reg            p2_pipe_ready_bc;
reg            p2_pipe_valid;
reg            p2_skid_catch;
reg    [100:0] p2_skid_data;
reg    [100:0] p2_skid_pipe_data;
reg            p2_skid_pipe_ready;
reg            p2_skid_pipe_valid;
reg            p2_skid_ready;
reg            p2_skid_ready_flop;
reg            p2_skid_valid;
reg     [87:0] p3_pipe_data;
reg     [87:0] p3_pipe_rand_data;
reg            p3_pipe_rand_ready;
reg            p3_pipe_rand_valid;
reg            p3_pipe_ready;
reg            p3_pipe_ready_bc;
reg            p3_pipe_valid;
reg            p3_skid_catch;
reg     [87:0] p3_skid_data;
reg     [87:0] p3_skid_pipe_data;
reg            p3_skid_pipe_ready;
reg            p3_skid_pipe_valid;
reg            p3_skid_ready;
reg            p3_skid_ready_flop;
reg            p3_skid_valid;
reg      [7:0] pad_r_remain;
reg     [18:0] pad_table_out;
reg      [2:0] padding_left;
reg      [2:0] padding_stride_num;
reg    [100:0] pdp_datin_pd0;
reg     [87:0] pdp_datin_pd1;
reg            pdp_datin_prdy_f0;
reg            pdp_datin_prdy_f1;
reg            pdp_datin_pvld0;
reg            pdp_datin_pvld1;
reg            pdp_op_pending;
reg            pdpw_active_en;
reg    [111:0] pooling1d_data_pad;
reg            pooling1d_data_pad_vld;
reg            pooling_din_1st_0;
reg            pooling_din_1st_1;
reg            pooling_din_1st_2;
reg            pooling_din_1st_3;
reg            pooling_din_1st_4;
reg            pooling_din_1st_5;
reg            pooling_din_1st_6;
reg            pooling_din_1st_7;
reg      [2:0] pooling_out_cnt;
reg     [12:0] pooling_pwidth;
reg      [2:0] regs_num;
reg      [2:0] samllW_flush_num;
reg      [7:0] splitw_cnt;
reg     [12:0] strip_cnt_total;
reg      [2:0] strip_xcnt_psize;
reg      [3:0] strip_xcnt_stride;
reg      [3:0] strip_xcnt_stride_f;
reg            subcube_end_flag;
reg     [10:0] surface_cnt_rd;
reg     [91:0] unit1d_actv_out_f;
reg      [2:0] unit1d_cnt_pooling;
reg      [2:0] unit1d_cnt_stride;
reg      [7:0] unit1d_en;
reg     [12:0] wr_line_dat_cnt;
reg      [7:0] wr_splitc_cnt;
reg     [12:0] wr_surface_dat_cnt;

    
//==============================================================
//--------------------------------------------------------------
assign pdp_op_start = ~pdp_op_pending & reg2dp_op_en;
always @(posedge nvdla_core_clk or negedge nvdla_core_rstn) begin
  if (!nvdla_core_rstn) begin
    pdp_op_pending <= 1'b0;
  end else begin
    if(pdp_op_start)
         pdp_op_pending <=  1'b1;
    else if(dp2reg_done)
         pdp_op_pending <= 1'b0;
  end
end
//==============================================================
//--------------------------------------------------------------
assign off_flying_en = (datin_src_cfg == 1'h1 );
assign on_flying_en  = (datin_src_cfg == 1'h0 );
assign pdp_datin_pd_f_mux0 = off_flying_en?  pdp_rdma2dp_pd[75:0] : sdp2pdp_pd[75:0];
assign pdp_datin_pvld_mux0 = off_flying_en?  pdp_rdma2dp_valid     : sdp2pdp_valid;
assign pdp_rdma2dp_ready = pdp_datin_prdy_mux0 & off_flying_en;
assign sdp2pdp_ready     = pdp_datin_prdy_mux0 & on_flying_en;
assign pdp_datin_prdy_mux0 = fp16_mean_pool_cfg ? switch_in_prdy : pdp_datin_prdy_f;
//---------------------------------------------------------------
assign fp16_mean_pool_cfg = reg2dp_fp16_en & average_pooling_en;
assign fp16_mean_din_pvld = pdp_datin_pvld_mux0 & fp16_mean_pool_cfg;
assign switch_in_vld[0] = fp16_mean_din_pvld & sync_switch_in_rdy & (&{switch_in_rdy[3:1]});
assign switch_in_vld[1] = fp16_mean_din_pvld & sync_switch_in_rdy & (&{switch_in_rdy[3:2],switch_in_rdy[0]});
assign switch_in_vld[2] = fp16_mean_din_pvld & sync_switch_in_rdy & (&{switch_in_rdy[3],switch_in_rdy[1:0]});
assign switch_in_vld[3] = fp16_mean_din_pvld & sync_switch_in_rdy & (&{switch_in_rdy[2:0]});
assign sync_switch_in_vld = fp16_mean_din_pvld & (&{switch_in_rdy[3:0]});
assign switch_in_prdy = &switch_in_rdy & sync_switch_in_rdy;
HLS_fp16_to_fp17 core_din_format_switch_0 (
   .nvdla_core_clk          (nvdla_core_clk)
  ,.nvdla_core_rstn         (nvdla_core_rstn)
  ,.chn_a_rsc_z             (pdp_datin_pd_f_mux0[15:0])
  ,.chn_a_rsc_vz            (switch_in_vld[0])
  ,.chn_a_rsc_lz            (switch_in_rdy[0])
  ,.chn_o_rsc_z             (switch_out_0[16:0])
  ,.chn_o_rsc_vz            (switch_out_rdy[0])
  ,.chn_o_rsc_lz            (switch_out_vld[0])
  );
HLS_fp16_to_fp17 core_din_format_switch_1 (
   .nvdla_core_clk          (nvdla_core_clk)
  ,.nvdla_core_rstn         (nvdla_core_rstn)
  ,.chn_a_rsc_z             (pdp_datin_pd_f_mux0[31:16])
  ,.chn_a_rsc_vz            (switch_in_vld[1])
  ,.chn_a_rsc_lz            (switch_in_rdy[1])
  ,.chn_o_rsc_z             (switch_out_1[16:0])
  ,.chn_o_rsc_vz            (switch_out_rdy[1])
  ,.chn_o_rsc_lz            (switch_out_vld[1])
  );
HLS_fp16_to_fp17 core_din_format_switch_2 (
   .nvdla_core_clk          (nvdla_core_clk)
  ,.nvdla_core_rstn         (nvdla_core_rstn)
  ,.chn_a_rsc_z             (pdp_datin_pd_f_mux0[47:32])
  ,.chn_a_rsc_vz            (switch_in_vld[2])
  ,.chn_a_rsc_lz            (switch_in_rdy[2])
  ,.chn_o_rsc_z             (switch_out_2[16:0])
  ,.chn_o_rsc_vz            (switch_out_rdy[2])
  ,.chn_o_rsc_lz            (switch_out_vld[2])
  );
HLS_fp16_to_fp17 core_din_format_switch_3 (
   .nvdla_core_clk          (nvdla_core_clk)
  ,.nvdla_core_rstn         (nvdla_core_rstn)
  ,.chn_a_rsc_z             (pdp_datin_pd_f_mux0[63:48])
  ,.chn_a_rsc_vz            (switch_in_vld[3])
  ,.chn_a_rsc_lz            (switch_in_rdy[3])
  ,.chn_o_rsc_z             (switch_out_3[16:0])
  ,.chn_o_rsc_vz            (switch_out_rdy[3])
  ,.chn_o_rsc_lz            (switch_out_vld[3])
  );
assign sync_switch_in_pd = pdp_datin_pd_f_mux0[75:64];

assign sync_switch_in_vld_d0 = sync_switch_in_vld;
assign sync_switch_in_rdy = sync_switch_in_rdy_d0;
assign sync_switch_in_pd_d0[11:0] = sync_switch_in_pd[11:0];
NV_NVDLA_PDP_CORE_CAL1D_pipe_p1 pipe_p1 (
   .nvdla_core_clk          (nvdla_core_clk)
  ,.nvdla_core_rstn         (nvdla_core_rstn)
  ,.sync_switch_in_pd_d0    (sync_switch_in_pd_d0[11:0])
  ,.sync_switch_in_rdy_d1   (sync_switch_in_rdy_d1)
  ,.sync_switch_in_vld_d0   (sync_switch_in_vld_d0)
  ,.sync_switch_in_pd_d1    (sync_switch_in_pd_d1[11:0])
  ,.sync_switch_in_rdy_d0   (sync_switch_in_rdy_d0)
  ,.sync_switch_in_vld_d1   (sync_switch_in_vld_d1)
  );
assign sync_switch_out_vld = sync_switch_in_vld_d1;
assign sync_switch_in_rdy_d1 = sync_switch_out_rdy;
assign sync_switch_out_pd[11:0] = sync_switch_in_pd_d1[11:0];

assign sync_switch_out_rdy = pdp_datin_prdy_f & (&{switch_out_vld[3:0]});

assign switch_out_rdy[0] = pdp_datin_prdy_f & sync_switch_out_vld & (&{switch_out_vld[3:1]});
assign switch_out_rdy[1] = pdp_datin_prdy_f & sync_switch_out_vld & (&{switch_out_vld[3:2],switch_out_vld[0]});
assign switch_out_rdy[2] = pdp_datin_prdy_f & sync_switch_out_vld & (&{switch_out_vld[3],switch_out_vld[1:0]});
assign switch_out_rdy[3] = pdp_datin_prdy_f & sync_switch_out_vld & (&{switch_out_vld[2:0]});
assign fp16_switch_out_vld = &switch_out_vld & sync_switch_out_vld;
assign fp16_switch_out_pd = {sync_switch_out_pd[11:0],switch_out_3[16:0],switch_out_2[16:0],switch_out_1[16:0],switch_out_0[16:0]};
//---------------------------------------------------------------
assign pdp_datin_pd_f_0 = fp16_mean_pool_cfg ? fp16_switch_out_pd : {pdp_datin_pd_f_mux0[75:64],pdp_datin_pd_f_mux0[63],pdp_datin_pd_f_mux0[63:48],pdp_datin_pd_f_mux0[47],pdp_datin_pd_f_mux0[47:32],pdp_datin_pd_f_mux0[31],pdp_datin_pd_f_mux0[31:16],pdp_datin_pd_f_mux0[15],pdp_datin_pd_f_mux0[15:0]};
assign pdp_datin_pvld_f = fp16_mean_pool_cfg ? fp16_switch_out_vld : pdp_datin_pvld_mux0;
//---------------------------------------------------------------

//===============================================================
//---------------------------------------------------------------
assign posc_last = pdp_datin_pd_f_0[74:72]==3'd3;

assign pdp_din_0 = pdp_datin_pd_f_0[16:0];
assign pdp_din_1 = pdp_datin_pd_f_0[33:17];
assign pdp_din_2 = pdp_datin_pd_f_0[50:34];
assign pdp_din_3 = pdp_datin_pd_f_0[67:51];

assign datain_16bit_0 = {{5{pdp_din_0[16]}},pdp_din_0[16:0]};
assign datain_16bit_1 = {{5{pdp_din_1[16]}},pdp_din_1[16:0]};
assign datain_16bit_2 = {{5{pdp_din_2[16]}},pdp_din_2[16:0]};
assign datain_16bit_3 = {{5{pdp_din_3[16]}},pdp_din_3[16:0]};

assign datain_8bit_0 = {{{3{pdp_din_0[15]}},pdp_din_0[15:8]}, {{3{pdp_din_0[7]}},pdp_din_0[7:0]}};
assign datain_8bit_1 = {{{3{pdp_din_1[15]}},pdp_din_1[15:8]}, {{3{pdp_din_1[7]}},pdp_din_1[7:0]}};
assign datain_8bit_2 = {{{3{pdp_din_2[15]}},pdp_din_2[15:8]}, {{3{pdp_din_2[7]}},pdp_din_2[7:0]}};
assign datain_8bit_3 = {{{3{pdp_din_3[15]}},pdp_din_3[15:8]}, {{3{pdp_din_3[7]}},pdp_din_3[7:0]}};

assign datain_ext_0  =  reg2dp_int8_en ? datain_8bit_0 : datain_16bit_0;
assign datain_ext_1  =  reg2dp_int8_en ? datain_8bit_1 : datain_16bit_1;
assign datain_ext_2  =  reg2dp_int8_en ? datain_8bit_2 : datain_16bit_2;
assign datain_ext_3  =  reg2dp_int8_en ? datain_8bit_3 : datain_16bit_3;

assign datain_ext = {datain_ext_3, datain_ext_2, datain_ext_1, datain_ext_0};

assign pdp_datin_prdy_f = pdp_datin_prdy_f0 & pdp_datin_prdy_f1;
assign pdp_datin_pvld_f0 = pdp_datin_pvld_f & pdp_datin_prdy_f1;
assign pdp_datin_pvld_f1 = pdp_datin_pvld_f & pdp_datin_prdy_f0;
assign pdp_datin_pd_f0 = {posc_last,pdp_datin_pd_f_0[79:68],datain_ext[87:0]};
assign pdp_datin_pd_f1 = datain_ext[87:0];
`ifndef SYNTHESIS
reg p2_pipe_rand_active;
`endif
always @(
  `ifndef SYNTHESIS
  p2_pipe_rand_active
  or 
     `endif
     pdp_datin_pvld_f0
  or p2_pipe_rand_ready
  or pdp_datin_pd_f0
  ) begin
  `ifdef SYNTHESIS
  p2_pipe_rand_valid = pdp_datin_pvld_f0;
  pdp_datin_prdy_f0 = p2_pipe_rand_ready;
  p2_pipe_rand_data = pdp_datin_pd_f0;
  `else
  p2_pipe_rand_valid = (p2_pipe_rand_active)? 1'b0 : pdp_datin_pvld_f0;
  pdp_datin_prdy_f0 = (p2_pipe_rand_active)? 1'b0 : p2_pipe_rand_ready;
  p2_pipe_rand_data = (p2_pipe_rand_active)?  'bx : pdp_datin_pd_f0;
  `endif
end
`ifndef SYNTHESIS
integer p2_pipe_stall_cycles;
integer p2_pipe_stall_probability;
integer p2_pipe_stall_cycles_min;
integer p2_pipe_stall_cycles_max;
initial begin
  p2_pipe_stall_cycles = 0;
  p2_pipe_stall_probability = 0;
  p2_pipe_stall_cycles_min = 1;
  p2_pipe_stall_cycles_max = 10;
`ifndef SYNTH_LEVEL1_COMPILE
  if      ( $value$plusargs( "NV_NVDLA_PDP_CORE_cal1d_pipe_rand_probability=%d",  p2_pipe_stall_probability ) ) ;
  else if ( $value$plusargs(    "default_pipe_rand_probability=%d",  p2_pipe_stall_probability ) ) ;
  if      ( $value$plusargs( "NV_NVDLA_PDP_CORE_cal1d_pipe_stall_probability=%d", p2_pipe_stall_probability ) ) ; 
  else if ( $value$plusargs(    "default_pipe_stall_probability=%d", p2_pipe_stall_probability ) ) ; 
  if      ( $value$plusargs( "NV_NVDLA_PDP_CORE_cal1d_pipe_stall_cycles_min=%d",  p2_pipe_stall_cycles_min  ) ) ;
  else if ( $value$plusargs(    "default_pipe_stall_cycles_min=%d",  p2_pipe_stall_cycles_min  ) ) ;
  if      ( $value$plusargs( "NV_NVDLA_PDP_CORE_cal1d_pipe_stall_cycles_max=%d",  p2_pipe_stall_cycles_max  ) ) ;
  else if ( $value$plusargs(    "default_pipe_stall_cycles_max=%d",  p2_pipe_stall_cycles_max  ) ) ;
`endif
end
`ifndef SYNTH_LEVEL1_COMPILE
`ifdef SIMTOP_RANDOMIZE_STALLS
always @( `SIMTOP_RANDOMIZE_STALLS.global_stall_event ) begin
  if ( ! $test$plusargs( "NV_NVDLA_PDP_CORE_cal1d_pipe_stall_probability" ) ) p2_pipe_stall_probability = `SIMTOP_RANDOMIZE_STALLS.global_stall_pipe_probability;
  if ( ! $test$plusargs( "NV_NVDLA_PDP_CORE_cal1d_pipe_stall_cycles_min"  ) ) p2_pipe_stall_cycles_min  = `SIMTOP_RANDOMIZE_STALLS.global_stall_pipe_cycles_min;
  if ( ! $test$plusargs( "NV_NVDLA_PDP_CORE_cal1d_pipe_stall_cycles_max"  ) ) p2_pipe_stall_cycles_max  = `SIMTOP_RANDOMIZE_STALLS.global_stall_pipe_cycles_max;
end
`endif
`endif
reg p2_pipe_rand_enable;
reg p2_pipe_rand_poised;
always @(
  p2_pipe_stall_cycles
  or p2_pipe_stall_probability
  or pdp_datin_pvld_f0
  ) begin
  p2_pipe_rand_active = p2_pipe_stall_cycles != 0;
  p2_pipe_rand_enable = p2_pipe_stall_probability != 0;
  p2_pipe_rand_poised = p2_pipe_rand_enable && !p2_pipe_rand_active && pdp_datin_pvld_f0 === 1'b1;
end
always @(posedge nvdla_core_clk or negedge nvdla_core_rstn) begin
  if (!nvdla_core_rstn) begin
    p2_pipe_stall_cycles <= 1'b0;
  end else begin
  if (p2_pipe_rand_poised) begin
    if (p2_pipe_stall_probability >= prand_inst0(1, 100)) begin
      p2_pipe_stall_cycles <= prand_inst1(p2_pipe_stall_cycles_min, p2_pipe_stall_cycles_max);
    end
  end else if (p2_pipe_rand_active) begin
    p2_pipe_stall_cycles <= p2_pipe_stall_cycles - 1;
  end else begin
    p2_pipe_stall_cycles <= 0;
  end
  end
end

`ifdef SYNTH_LEVEL1_COMPILE
`else
`ifdef SYNTHESIS
`else
`ifdef PRAND_VERILOG
reg [47:0] prand_local_seed0;
reg prand_initialized0;
reg prand_no_rollpli0;
`endif
`endif
`endif

function [31:0] prand_inst0;
    input [31:0] min;
    input [31:0] max;
    reg [32:0] diff;
    
    begin
`ifdef SYNTH_LEVEL1_COMPILE
        prand_inst0 = min;
`else
`ifdef SYNTHESIS
        prand_inst0 = min;
`else
`ifdef PRAND_VERILOG
        if (prand_initialized0 !== 1'b1) begin
            prand_no_rollpli0 = $test$plusargs("NO_ROLLPLI");
            if (!prand_no_rollpli0)
                prand_local_seed0 = {$prand_get_seed(0), 16'b0};
            prand_initialized0 = 1'b1;
        end
        if (prand_no_rollpli0) begin
            prand_inst0 = min;
        end else begin
            diff = max - min + 1;
            prand_inst0 = min + prand_local_seed0[47:16] % diff;
            prand_local_seed0 = prand_local_seed0 * 48'h5deece66d + 48'd11;
        end
`else
`ifdef PRAND_OFF
        prand_inst0 = min;
`else
        prand_inst0 = $RollPLI(min, max, "auto");
`endif
`endif
`endif
`endif
    end
endfunction

`ifdef SYNTH_LEVEL1_COMPILE
`else
`ifdef SYNTHESIS
`else
`ifdef PRAND_VERILOG
reg [47:0] prand_local_seed1;
reg prand_initialized1;
reg prand_no_rollpli1;
`endif
`endif
`endif

function [31:0] prand_inst1;
    input [31:0] min;
    input [31:0] max;
    reg [32:0] diff;
    
    begin
`ifdef SYNTH_LEVEL1_COMPILE
        prand_inst1 = min;
`else
`ifdef SYNTHESIS
        prand_inst1 = min;
`else
`ifdef PRAND_VERILOG
        if (prand_initialized1 !== 1'b1) begin
            prand_no_rollpli1 = $test$plusargs("NO_ROLLPLI");
            if (!prand_no_rollpli1)
                prand_local_seed1 = {$prand_get_seed(1), 16'b0};
            prand_initialized1 = 1'b1;
        end
        if (prand_no_rollpli1) begin
            prand_inst1 = min;
        end else begin
            diff = max - min + 1;
            prand_inst1 = min + prand_local_seed1[47:16] % diff;
            prand_local_seed1 = prand_local_seed1 * 48'h5deece66d + 48'd11;
        end
`else
`ifdef PRAND_OFF
        prand_inst1 = min;
`else
        prand_inst1 = $RollPLI(min, max, "auto");
`endif
`endif
`endif
`endif
    end
endfunction

`endif
always @(
  p2_pipe_rand_valid
  or p2_skid_ready_flop
  or p2_skid_pipe_ready
  or p2_skid_valid
  ) begin
  p2_skid_catch = p2_pipe_rand_valid && p2_skid_ready_flop && !p2_skid_pipe_ready;  
  p2_skid_ready = (p2_skid_valid)? p2_skid_pipe_ready : !p2_skid_catch;
end
always @(posedge nvdla_core_clk or negedge nvdla_core_rstn) begin
  if (!nvdla_core_rstn) begin
    p2_skid_valid <= 1'b0;
    p2_skid_ready_flop <= 1'b1;
    p2_pipe_rand_ready <= 1'b1;
  end else begin
  p2_skid_valid <= (p2_skid_valid)? !p2_skid_pipe_ready : p2_skid_catch;
  p2_skid_ready_flop <= p2_skid_ready;
  p2_pipe_rand_ready <= p2_skid_ready;
  end
end
always @(posedge nvdla_core_clk) begin
  p2_skid_data <= (p2_skid_catch)? p2_pipe_rand_data : p2_skid_data;
end
always @(
  p2_skid_ready_flop
  or p2_pipe_rand_valid
  or p2_skid_valid
  or p2_pipe_rand_data
  or p2_skid_data
  ) begin
  p2_skid_pipe_valid = (p2_skid_ready_flop)? p2_pipe_rand_valid : p2_skid_valid; 
  p2_skid_pipe_data = (p2_skid_ready_flop)? p2_pipe_rand_data : p2_skid_data;
end
always @(
  p2_pipe_ready
  or p2_pipe_valid
  ) begin
  p2_pipe_ready_bc = p2_pipe_ready || !p2_pipe_valid;
end
always @(posedge nvdla_core_clk or negedge nvdla_core_rstn) begin
  if (!nvdla_core_rstn) begin
    p2_pipe_valid <= 1'b0;
  end else begin
  p2_pipe_valid <= (p2_pipe_ready_bc)? p2_skid_pipe_valid : 1'd1;
  end
end
always @(posedge nvdla_core_clk) begin
  p2_pipe_data <= (p2_pipe_ready_bc && p2_skid_pipe_valid)? p2_skid_pipe_data : p2_pipe_data;
end
always @(
  p2_pipe_ready_bc
  ) begin
  p2_skid_pipe_ready = p2_pipe_ready_bc;
end
always @(
  p2_pipe_valid
  or pdp_datin_prdy0
  or p2_pipe_data
  ) begin
  pdp_datin_pvld0 = p2_pipe_valid;
  p2_pipe_ready = pdp_datin_prdy0;
  pdp_datin_pd0 = p2_pipe_data;
end
`ifndef VIVA_PLUGIN_PIPE_DISABLE_ASSERTIONS
wire p2_assert_clk = nvdla_core_clk;
`endif
`ifndef SYNTHESIS
reg p3_pipe_rand_active;
`endif
always @(
  `ifndef SYNTHESIS
  p3_pipe_rand_active
  or 
     `endif
     pdp_datin_pvld_f1
  or p3_pipe_rand_ready
  or pdp_datin_pd_f1
  ) begin
  `ifdef SYNTHESIS
  p3_pipe_rand_valid = pdp_datin_pvld_f1;
  pdp_datin_prdy_f1 = p3_pipe_rand_ready;
  p3_pipe_rand_data = pdp_datin_pd_f1;
  `else
  p3_pipe_rand_valid = (p3_pipe_rand_active)? 1'b0 : pdp_datin_pvld_f1;
  pdp_datin_prdy_f1 = (p3_pipe_rand_active)? 1'b0 : p3_pipe_rand_ready;
  p3_pipe_rand_data = (p3_pipe_rand_active)?  'bx : pdp_datin_pd_f1;
  `endif
end
`ifndef SYNTHESIS
integer p3_pipe_stall_cycles;
integer p3_pipe_stall_probability;
integer p3_pipe_stall_cycles_min;
integer p3_pipe_stall_cycles_max;
initial begin
  p3_pipe_stall_cycles = 0;
  p3_pipe_stall_probability = 0;
  p3_pipe_stall_cycles_min = 1;
  p3_pipe_stall_cycles_max = 10;
`ifndef SYNTH_LEVEL1_COMPILE
  if      ( $value$plusargs( "NV_NVDLA_PDP_CORE_cal1d_pipe_rand_probability=%d",  p3_pipe_stall_probability ) ) ;
  else if ( $value$plusargs(    "default_pipe_rand_probability=%d",  p3_pipe_stall_probability ) ) ;
  if      ( $value$plusargs( "NV_NVDLA_PDP_CORE_cal1d_pipe_stall_probability=%d", p3_pipe_stall_probability ) ) ; 
  else if ( $value$plusargs(    "default_pipe_stall_probability=%d", p3_pipe_stall_probability ) ) ; 
  if      ( $value$plusargs( "NV_NVDLA_PDP_CORE_cal1d_pipe_stall_cycles_min=%d",  p3_pipe_stall_cycles_min  ) ) ;
  else if ( $value$plusargs(    "default_pipe_stall_cycles_min=%d",  p3_pipe_stall_cycles_min  ) ) ;
  if      ( $value$plusargs( "NV_NVDLA_PDP_CORE_cal1d_pipe_stall_cycles_max=%d",  p3_pipe_stall_cycles_max  ) ) ;
  else if ( $value$plusargs(    "default_pipe_stall_cycles_max=%d",  p3_pipe_stall_cycles_max  ) ) ;
`endif
end
`ifndef SYNTH_LEVEL1_COMPILE
`ifdef SIMTOP_RANDOMIZE_STALLS
always @( `SIMTOP_RANDOMIZE_STALLS.global_stall_event ) begin
  if ( ! $test$plusargs( "NV_NVDLA_PDP_CORE_cal1d_pipe_stall_probability" ) ) p3_pipe_stall_probability = `SIMTOP_RANDOMIZE_STALLS.global_stall_pipe_probability;
  if ( ! $test$plusargs( "NV_NVDLA_PDP_CORE_cal1d_pipe_stall_cycles_min"  ) ) p3_pipe_stall_cycles_min  = `SIMTOP_RANDOMIZE_STALLS.global_stall_pipe_cycles_min;
  if ( ! $test$plusargs( "NV_NVDLA_PDP_CORE_cal1d_pipe_stall_cycles_max"  ) ) p3_pipe_stall_cycles_max  = `SIMTOP_RANDOMIZE_STALLS.global_stall_pipe_cycles_max;
end
`endif
`endif
reg p3_pipe_rand_enable;
reg p3_pipe_rand_poised;
always @(
  p3_pipe_stall_cycles
  or p3_pipe_stall_probability
  or pdp_datin_pvld_f1
  ) begin
  p3_pipe_rand_active = p3_pipe_stall_cycles != 0;
  p3_pipe_rand_enable = p3_pipe_stall_probability != 0;
  p3_pipe_rand_poised = p3_pipe_rand_enable && !p3_pipe_rand_active && pdp_datin_pvld_f1 === 1'b1;
end
always @(posedge nvdla_core_clk or negedge nvdla_core_rstn) begin
  if (!nvdla_core_rstn) begin
    p3_pipe_stall_cycles <= 1'b0;
  end else begin
  if (p3_pipe_rand_poised) begin
    if (p3_pipe_stall_probability >= prand_inst2(1, 100)) begin
      p3_pipe_stall_cycles <= prand_inst3(p3_pipe_stall_cycles_min, p3_pipe_stall_cycles_max);
    end
  end else if (p3_pipe_rand_active) begin
    p3_pipe_stall_cycles <= p3_pipe_stall_cycles - 1;
  end else begin
    p3_pipe_stall_cycles <= 0;
  end
  end
end

`ifdef SYNTH_LEVEL1_COMPILE
`else
`ifdef SYNTHESIS
`else
`ifdef PRAND_VERILOG
reg [47:0] prand_local_seed2;
reg prand_initialized2;
reg prand_no_rollpli2;
`endif
`endif
`endif

function [31:0] prand_inst2;
    input [31:0] min;
    input [31:0] max;
    reg [32:0] diff;
    
    begin
`ifdef SYNTH_LEVEL1_COMPILE
        prand_inst2 = min;
`else
`ifdef SYNTHESIS
        prand_inst2 = min;
`else
`ifdef PRAND_VERILOG
        if (prand_initialized2 !== 1'b1) begin
            prand_no_rollpli2 = $test$plusargs("NO_ROLLPLI");
            if (!prand_no_rollpli2)
                prand_local_seed2 = {$prand_get_seed(2), 16'b0};
            prand_initialized2 = 1'b1;
        end
        if (prand_no_rollpli2) begin
            prand_inst2 = min;
        end else begin
            diff = max - min + 1;
            prand_inst2 = min + prand_local_seed2[47:16] % diff;
            prand_local_seed2 = prand_local_seed2 * 48'h5deece66d + 48'd11;
        end
`else
`ifdef PRAND_OFF
        prand_inst2 = min;
`else
        prand_inst2 = $RollPLI(min, max, "auto");
`endif
`endif
`endif
`endif
    end
endfunction

`ifdef SYNTH_LEVEL1_COMPILE
`else
`ifdef SYNTHESIS
`else
`ifdef PRAND_VERILOG
reg [47:0] prand_local_seed3;
reg prand_initialized3;
reg prand_no_rollpli3;
`endif
`endif
`endif

function [31:0] prand_inst3;
    input [31:0] min;
    input [31:0] max;
    reg [32:0] diff;
    
    begin
`ifdef SYNTH_LEVEL1_COMPILE
        prand_inst3 = min;
`else
`ifdef SYNTHESIS
        prand_inst3 = min;
`else
`ifdef PRAND_VERILOG
        if (prand_initialized3 !== 1'b1) begin
            prand_no_rollpli3 = $test$plusargs("NO_ROLLPLI");
            if (!prand_no_rollpli3)
                prand_local_seed3 = {$prand_get_seed(3), 16'b0};
            prand_initialized3 = 1'b1;
        end
        if (prand_no_rollpli3) begin
            prand_inst3 = min;
        end else begin
            diff = max - min + 1;
            prand_inst3 = min + prand_local_seed3[47:16] % diff;
            prand_local_seed3 = prand_local_seed3 * 48'h5deece66d + 48'd11;
        end
`else
`ifdef PRAND_OFF
        prand_inst3 = min;
`else
        prand_inst3 = $RollPLI(min, max, "auto");
`endif
`endif
`endif
`endif
    end
endfunction

`endif
always @(
  p3_pipe_rand_valid
  or p3_skid_ready_flop
  or p3_skid_pipe_ready
  or p3_skid_valid
  ) begin
  p3_skid_catch = p3_pipe_rand_valid && p3_skid_ready_flop && !p3_skid_pipe_ready;  
  p3_skid_ready = (p3_skid_valid)? p3_skid_pipe_ready : !p3_skid_catch;
end
always @(posedge nvdla_core_clk or negedge nvdla_core_rstn) begin
  if (!nvdla_core_rstn) begin
    p3_skid_valid <= 1'b0;
    p3_skid_ready_flop <= 1'b1;
    p3_pipe_rand_ready <= 1'b1;
  end else begin
  p3_skid_valid <= (p3_skid_valid)? !p3_skid_pipe_ready : p3_skid_catch;
  p3_skid_ready_flop <= p3_skid_ready;
  p3_pipe_rand_ready <= p3_skid_ready;
  end
end
always @(posedge nvdla_core_clk) begin
  p3_skid_data <= (p3_skid_catch)? p3_pipe_rand_data : p3_skid_data;
end
always @(
  p3_skid_ready_flop
  or p3_pipe_rand_valid
  or p3_skid_valid
  or p3_pipe_rand_data
  or p3_skid_data
  ) begin
  p3_skid_pipe_valid = (p3_skid_ready_flop)? p3_pipe_rand_valid : p3_skid_valid; 
  p3_skid_pipe_data = (p3_skid_ready_flop)? p3_pipe_rand_data : p3_skid_data;
end
always @(
  p3_pipe_ready
  or p3_pipe_valid
  ) begin
  p3_pipe_ready_bc = p3_pipe_ready || !p3_pipe_valid;
end
always @(posedge nvdla_core_clk or negedge nvdla_core_rstn) begin
  if (!nvdla_core_rstn) begin
    p3_pipe_valid <= 1'b0;
  end else begin
  p3_pipe_valid <= (p3_pipe_ready_bc)? p3_skid_pipe_valid : 1'd1;
  end
end
always @(posedge nvdla_core_clk) begin
  p3_pipe_data <= (p3_pipe_ready_bc && p3_skid_pipe_valid)? p3_skid_pipe_data : p3_pipe_data;
end
always @(
  p3_pipe_ready_bc
  ) begin
  p3_skid_pipe_ready = p3_pipe_ready_bc;
end
always @(
  p3_pipe_valid
  or pdp_datin_prdy1
  or p3_pipe_data
  ) begin
  pdp_datin_pvld1 = p3_pipe_valid;
  p3_pipe_ready = pdp_datin_prdy1;
  pdp_datin_pd1 = p3_pipe_data;
end
`ifndef VIVA_PLUGIN_PIPE_DISABLE_ASSERTIONS
wire p3_assert_clk = nvdla_core_clk;
`endif

assign pdp_datin_pd = pdp_datin_pd0;
assign pdp_datin_pvld = pdp_datin_pvld0 & pdp_datin_pvld1;
assign pdp_datin_prdy0 = pdp_datin_prdy & pdp_datin_pvld1;
assign pdp_datin_prdy1 = pdp_datin_prdy & pdp_datin_pvld0;

assign pdp_datin_prdy = (pdp_datin_prdy_0 & pdp_datin_prdy_1) & pdpw_active_en; 
assign pdp_datin_prdy_0 = ~ cur_datin_disable;
//==============================================================
//---------------------------------------------------------------
assign bsync           = pdp_datin_pd[95];
assign splitw_end_sync = load_din ? pdp_datin_pd[98] : 1'b0;
assign pdp_cube_sync   = pdp_datin_pd[99];
assign pdp_cube_end    = pdp_cube_sync & bsync & load_din;

always @(posedge nvdla_core_clk or negedge nvdla_core_rstn) begin
  if (!nvdla_core_rstn) begin
    splitw_cnt[7:0] <= {8{1'b0}};
  end else begin
   if(splitw_end & bsync & splitw_end_sync & load_din)
        splitw_cnt[7:0] <= 8'd0;
   else if(splitw_end_sync & bsync & load_din)
        splitw_cnt[7:0] <= splitw_cnt + 1;
  end
end
assign splitw_end   = (splitw_cnt==pooling_splitw_num_cfg[7:0]);
assign splitw_start = (splitw_cnt==8'd0);
//===============================================================
//---------------------------------------------------------------
assign non_splitw      = pooling_splitw_num_cfg[7:0]==8'd0 ;
assign first_splitw_en = ~non_splitw & splitw_start;
assign last_splitw_en  = ~non_splitw & splitw_end;

assign {mon_overlap,overlap[3:0]} = ({1'b0,reg2dp_kernel_width} < reg2dp_kernel_stride_width) ? (reg2dp_kernel_stride_width[3:0] - {1'b0,reg2dp_kernel_width[2:0]}) : ({1'b0,reg2dp_kernel_width[2:0]} - reg2dp_kernel_stride_width[3:0]);
always @(
  non_splitw
  or reg2dp_cube_in_width
  or splitw_end
  or reg2dp_kernel_stride_width
  or reg2dp_kernel_width
  or pooling_lwidth_cfg
  or overlap
  or splitw_start
  or pooling_fwidth_cfg
  or pooling_mwidth_cfg
  ) begin
    if(non_splitw)
        pooling_pwidth = reg2dp_cube_in_width[12:0];
    else if(splitw_end) begin
        if(reg2dp_kernel_stride_width > {1'b0,reg2dp_kernel_width})
            pooling_pwidth = {3'd0,pooling_lwidth_cfg[9:0]} - {8'd0,overlap[3:0]};
        else
            pooling_pwidth = {3'd0,pooling_lwidth_cfg[9:0]} + {8'd0,overlap[3:0]};
    end else if(splitw_start)
        pooling_pwidth = {3'd0,pooling_fwidth_cfg[9:0]};
    else begin
        if(reg2dp_kernel_stride_width > {1'b0,reg2dp_kernel_width})
            pooling_pwidth = {3'd0,pooling_mwidth_cfg[9:0]} - {8'd0,overlap[3:0]};
        else
            pooling_pwidth = {3'd0,pooling_mwidth_cfg[9:0]} + {8'd0,overlap[3:0]};
    end
end
//==============================================================
//--------------------------------------------------------------
always @(posedge nvdla_core_clk or negedge nvdla_core_rstn) begin
  if (!nvdla_core_rstn) begin
    pdpw_active_en <= 1'b0;
  end else begin
   if(pdp_op_start)
          pdpw_active_en   <= 1'b1; 
   else  if(pdp_cube_end)
          pdpw_active_en   <= 1'b0;
  end
end
//==============================================================
//--------------------------------------------------------------
always @(
  non_splitw
  or padding_h_cfg
  or first_splitw_en
  or splitw_end_sync
  ) begin
    if(non_splitw)
        padding_left =  padding_h_cfg[2:0];
    else if(first_splitw_en & (~splitw_end_sync))
        padding_left =  padding_h_cfg[2:0];
    else
        padding_left =  3'd0;
end

assign padding_stride1_num =  padding_left[2:0];
assign padding_stride2_num = {1'b0,padding_left[2:1]};
assign padding_stride3_num= (padding_left[2:0]>=3'd6) ? 3'd2 :
                            (padding_left[2:0]>=3'd3) ? 3'd1 : 3'd0;
assign pooling_stride_h[4:0] = pooling_stride_h_cfg[3:0] + 3'd1;
assign padding_stride4_num = ({1'b0,padding_left[2:0]} > pooling_stride_h_cfg[3:0]) ? 3'd1 : 3'd0;
always @(
  pooling_stride_h_cfg
  or padding_stride1_num
  or padding_stride2_num
  or padding_stride3_num
  or padding_stride4_num
  ) begin
    case(pooling_stride_h_cfg)
        4'd0: padding_stride_num = padding_stride1_num;
        4'd1: padding_stride_num = padding_stride2_num;
        4'd2: padding_stride_num = padding_stride3_num;
        default: padding_stride_num = padding_stride4_num;
    endcase
end
 
assign   {mon_strip_xcnt_offset[5:0],strip_xcnt_offset[2:0]} = {5'b0, padding_left} - padding_stride_num * pooling_stride_h;

//////////////////////////////////////////////////
//------------------------------------------------
assign line_regs_1[2:0] = pooling_size_h_cfg[2:0];  
assign line_regs_2[2:0] = {1'd0,pooling_size_h_cfg[2:1]};
assign line_regs_3[2:0] = (pooling_size_h_cfg[2:0]>3'd5)? 3'd2 : ((pooling_size_h_cfg[2:0]>3'd2)? 3'd1 : 3'd0); 
assign line_regs_4 = ({1'b0,pooling_size_h_cfg[2:0]}>pooling_stride_h_cfg)? 3'd1 : 3'd0;

always @(posedge nvdla_core_clk or negedge nvdla_core_rstn) begin
  if (!nvdla_core_rstn) begin
    regs_num[2:0] <= {3{1'b0}};
  end else begin
  if(pdp_op_start) 
   case(pooling_stride_h_cfg)
       4'd0:    regs_num[2:0] <= line_regs_1;  
       4'd1:    regs_num[2:0] <= line_regs_2;
       4'd2:    regs_num[2:0] <= line_regs_3;
       default: regs_num[2:0] <= line_regs_4;
   endcase
  end
end
//////////////////////////////////////////////////
 
//==============================================================
//-------------------------------------------------------------
assign load_din            = pdp_datin_prdy & pdp_datin_pvld;
assign pooling_size_h[3:0] = pooling_size_h_cfg[2:0] + 3'd1;
assign strip_recieve_done  = load_din & pdp_din_lc;
assign pdp_din_lc          = pdp_datin_pd[100];
assign stride_end          = strip_recieve_done & (strip_xcnt_stride==pooling_stride_h_cfg[3:0]);
assign init_cnt            = line_last_stripe_done | pdp_op_start;

always @(
  init_cnt
  or strip_xcnt_offset
  or stride_end
  or strip_recieve_done
  or strip_xcnt_stride
  ) begin
   if(init_cnt) begin
        strip_xcnt_stride_f[3:0] = {1'b0,strip_xcnt_offset};
   end else if(stride_end)
        strip_xcnt_stride_f[3:0] = 4'd0;
   else if(strip_recieve_done)
        strip_xcnt_stride_f[3:0] = strip_xcnt_stride + 1;
   else
        strip_xcnt_stride_f[3:0] = strip_xcnt_stride;
end
always @(posedge nvdla_core_clk or negedge nvdla_core_rstn) begin
  if (!nvdla_core_rstn) begin
    strip_xcnt_stride[3:0] <= {4{1'b0}};
  end else begin
  if ((init_cnt | stride_end | strip_recieve_done) == 1'b1) begin
    strip_xcnt_stride[3:0] <= strip_xcnt_stride_f[3:0];
  end else if ((init_cnt | stride_end | strip_recieve_done) == 1'b0) begin
  end else begin
    strip_xcnt_stride[3:0] <= 'bx;
  end
  end
end

assign {mon_overlap_ff[1:0],overlap_ff[2:0]} = {1'b0,pooling_size_h_cfg} - pooling_stride_h_cfg;
always @(posedge nvdla_core_clk or negedge nvdla_core_rstn) begin
  if (!nvdla_core_rstn) begin
    strip_xcnt_psize <= {3{1'b0}};
  end else begin
    if(init_cnt)
        strip_xcnt_psize[2:0] <= padding_left[2:0];
    else if({1'b0,pooling_size_h_cfg} >= pooling_stride_h_cfg)begin
        if(pooling_1d_rdy)
            strip_xcnt_psize <= overlap_ff[2:0];
        else if(strip_recieve_done)
            strip_xcnt_psize<= strip_xcnt_psize + 1;
    end
    else begin
        if(strip_xcnt_stride_f <= {1'b0,pooling_size_h_cfg[2:0]})
            strip_xcnt_psize <= strip_xcnt_stride_f[2:0];
        else 
            strip_xcnt_psize <= 3'd0;
    end
  end
end
/////////////////////////////////////////////////////////
//-------------------------------------------------------
assign pooling_size[3:0] = pooling_size_h;
assign stride[4:0] = pooling_stride_h;
assign pad_l[2:0] = padding_left;

assign pad_r = reg2dp_pad_right_cfg[2:0];

always @(
  pad_r
  or stride_1x
  or stride_2x
  or stride_3x
  or stride_4x
  or stride_5x
  or stride_6x
  or stride_7x
  ) begin
    if({2'd0,pad_r} < stride_1x[4:0])
        flush_num_cal = 3'd0;
    else if({3'd0,pad_r} < stride_2x[5:0])
        flush_num_cal = 3'd1;
    else if({4'd0,pad_r} < stride_3x[6:0])
        flush_num_cal = 3'd2;
    else if({4'd0,pad_r} < stride_4x[6:0])
        flush_num_cal = 3'd3;
    else if({5'd0,pad_r} < stride_5x[7:0])
        flush_num_cal = 3'd4;
    else if({5'd0,pad_r} < stride_6x[7:0])
        flush_num_cal = 3'd5;
    else if({5'd0,pad_r} < stride_7x[7:0])
        flush_num_cal = 3'd6;
    else
        flush_num_cal = 3'd7;
end
assign non_split_small_active = (non_splitw & (~(|reg2dp_cube_in_width[12:3])) & ((reg2dp_cube_in_width[2:0] + reg2dp_pad_left[2:0]) < {1'b0,reg2dp_kernel_width[2:0]}));
assign split_small_active = (~non_splitw) & ((big_stride & ((pooling_lwidth_cfg[9:0] - {6'd0,overlap[3:0]}) < {8'b0,reg2dp_kernel_width[2:0]}))
                                         | ((~big_stride) & ((pooling_lwidth_cfg[9:0] + {6'd0,overlap[3:0]}) < {8'b0,reg2dp_kernel_width[2:0]})));
assign non_split_w_pl[3:0] = reg2dp_cube_in_width[2:0] + reg2dp_pad_left[2:0];
assign non_split_w_pl_pr[4:0] = non_split_w_pl[3:0] + {1'b0,reg2dp_pad_right[2:0]};

assign big_stride = (reg2dp_kernel_stride_width[3:0] >= {1'b0,reg2dp_kernel_width});
assign split_w_olap[5:0] = big_stride ? (pooling_lwidth_cfg[4:0] - {1'd0,overlap[3:0]}) : (pooling_lwidth_cfg[4:0] + {1'd0,overlap[3:0]});
assign split_w_olap_pr[6:0] = split_w_olap[5:0] + {3'd0,reg2dp_pad_right[2:0]};
always @(
  non_split_small_active
  or non_split_w_pl_pr
  or reg2dp_kernel_width
  or split_small_active
  or split_w_olap_pr
  ) begin
    if(non_split_small_active)
        pad_r_remain[7:0] = {3'd0,non_split_w_pl_pr[4:0]} - {1'd0,reg2dp_kernel_width[2:0]} ;
    else if(split_small_active)
        pad_r_remain[7:0] = split_w_olap_pr[6:0] - {4'd0,reg2dp_kernel_width[2:0]} ;
    else
        pad_r_remain[7:0] = 8'd0 ;
end
always @(
  pad_r_remain
  or stride_6x
  or stride_5x
  or stride_4x
  or stride_3x
  or stride_2x
  or stride_1x
  ) begin
    if(pad_r_remain == stride_6x[7:0])
        samllW_flush_num = 3'd6;
    else if(pad_r_remain == stride_5x[7:0])
        samllW_flush_num = 3'd5;
    else if(pad_r_remain == {1'd0,stride_4x[6:0]})
        samllW_flush_num = 3'd4;
    else if(pad_r_remain == {1'd0,stride_3x[6:0]})
        samllW_flush_num = 3'd3;
    else if(pad_r_remain == {2'd0,stride_2x[5:0]})
        samllW_flush_num = 3'd2;
    else if(pad_r_remain == {3'd0,stride_1x[4:0]})
        samllW_flush_num = 3'd1;
    else
        samllW_flush_num = 3'd0;
end

always @(
  flush_num_cal
  or non_split_small_active
  or split_small_active
  or samllW_flush_num
  ) begin
    if(flush_num_cal==3'd0)
         flush_num[2:0] = 3'd0;
    else if(non_split_small_active | split_small_active)
         flush_num[2:0] = samllW_flush_num;
    else
        flush_num[2:0] = flush_num_cal[2:0];
end

assign stride_1x[4:0] =   stride[4:0];
assign stride_2x[5:0] =  {stride[4:0],1'b0};
assign stride_3x[6:0] = ( stride_2x+{1'b0,stride[4:0]});
assign stride_4x[6:0] =  {stride[4:0],2'b0}; 
assign stride_5x[7:0] = ( stride_4x+{2'd0,stride[4:0]});
assign stride_6x[7:0] = ( stride_3x+stride_3x);
assign stride_7x[7:0] = ( stride_4x+stride_3x);

assign kernel_padl[4:0] = pooling_size[3:0] - {1'b0,pad_l[2:0]};
assign partial_w_last[10:0] = pooling_lwidth_cfg[9:0] + 10'd1;
assign cube_width_in[3:0] = reg2dp_cube_in_width[2:0] + 3'd1;
assign ks_width[4:0] = reg2dp_kernel_stride_width[3:0] + 4'd1;
assign k_add_ks[10:0]= {7'd0,pooling_size[3:0]} + {6'd0,ks_width[4:0]};

always @(
  non_splitw
  or non_split_small_active
  or cube_width_in
  or kernel_padl
  or first_splitw_en
  or last_splitw_en
  or split_small_active
  or big_stride
  or partial_w_last
  or overlap
  or k_add_ks
  or pooling_size
  ) begin
    if(non_splitw) begin
        if(non_split_small_active)
            {mon_first_out_num[6:0],first_out_num[4:0]} = {8'd0,cube_width_in[3:0]};
        else
            {mon_first_out_num[6:0],first_out_num[4:0]} = {7'd0,kernel_padl[4:0]};
    end else begin
        if(first_splitw_en)
            {mon_first_out_num[6:0],first_out_num[4:0]} = {7'd0,kernel_padl[4:0]};
        else if(last_splitw_en & split_small_active) begin
            if(big_stride)
                {mon_first_out_num[6:0],first_out_num[4:0]} = {1'b0,partial_w_last[10:0]};
            else
                {mon_first_out_num[6:0],first_out_num[4:0]} = partial_w_last[10:0] + {7'd0,overlap[3:0]};
        end else begin
            if(big_stride)
                {mon_first_out_num[6:0],first_out_num[4:0]} = {1'b0,k_add_ks};
            else
                {mon_first_out_num[6:0],first_out_num[4:0]} = {8'd0,pooling_size[3:0]};
        end
    end
end

always @(posedge nvdla_core_clk or negedge nvdla_core_rstn) begin
  if (!nvdla_core_rstn) begin
    need_bubble <= 1'b0;
    bubble_num[2:0] <= {3{1'b0}};
  end else begin
    if(pdp_cube_end) begin
        if(|flush_num) begin
            need_bubble <= 1'b1;
            bubble_num[2:0]  <= flush_num;
        end else begin
            need_bubble <= 1'b0;
            bubble_num[2:0]  <= 3'd0;
        end
    end else if(non_splitw) begin
        if(pdp_op_start) begin
            if({2'd0,flush_num} >= first_out_num) begin
                need_bubble <= 1'b1;
                bubble_num[2:0]  <= flush_num - first_out_num[2:0] + 1'b1;
            end else begin
                need_bubble <= 1'b0;
                bubble_num[2:0]  <= 3'd0;
            end
        end
    end else begin
        if(splitw_end) begin
            if({2'd0,flush_num} >= first_out_num) begin
                need_bubble <= 1'b1;
                bubble_num[2:0]  <= flush_num - first_out_num[2:0] + 1'b1;
            end else begin
                need_bubble <= 1'b0;
                bubble_num[2:0]  <= 3'd0;
            end
        end
    end
  end
end

always @(posedge nvdla_core_clk or negedge nvdla_core_rstn) begin
  if (!nvdla_core_rstn) begin
    cur_datin_disable <= 1'b0;
  end else begin
    if(pdp_cube_end & (|flush_num))
        cur_datin_disable <= 1'b1;
    else if(non_splitw) begin
        if(line_last_stripe_done & need_bubble)
            cur_datin_disable <= 1'b1;
        else if(bubble_en_end)
            cur_datin_disable <= 1'b0;
    end else begin
        if(last_splitw_en & line_last_stripe_done & need_bubble)
            cur_datin_disable <= 1'b1;
        else if(bubble_en_end)
            cur_datin_disable <= 1'b0;
    end
  end
end

always @(posedge nvdla_core_clk or negedge nvdla_core_rstn) begin
  if (!nvdla_core_rstn) begin
    channel_cnt <= {2{1'b0}};
  end else begin
    if(cur_datin_disable) begin
        if(last_c)
            channel_cnt <= 2'd0;
        else if(pdp_datin_prdy_1)
            channel_cnt <= channel_cnt + 1'b1;
    end else
        channel_cnt <= 2'd0;
  end
end
assign last_c = (channel_cnt==2'd3) & pdp_datin_prdy_1;

always @(posedge nvdla_core_clk or negedge nvdla_core_rstn) begin
  if (!nvdla_core_rstn) begin
    bubble_cnt <= {3{1'b0}};
  end else begin
    if(cur_datin_disable) begin
        if(bubble_en_end)
            bubble_cnt <= 3'd0;
        else if(last_c)
            bubble_cnt <= bubble_cnt + 1'b1;
    end else
            bubble_cnt <= 3'd0;
  end
end
assign bubble_num_dec[2:0] = bubble_num[2:0]-1'b1;
assign bubble_en_end = (bubble_cnt == bubble_num_dec) & last_c;

//////////////////////////////////////////////////////
//----------------------------------------------------
always @(posedge nvdla_core_clk or negedge nvdla_core_rstn) begin
  if (!nvdla_core_rstn) begin
    subcube_end_flag <= 1'b0;
  end else begin
    if(splitw_end_sync & bsync)
        subcube_end_flag <= 1'b1;
    else if(load_din)
        subcube_end_flag <= 1'b0;
  end
end

always @(posedge nvdla_core_clk or negedge nvdla_core_rstn) begin
  if (!nvdla_core_rstn) begin
    last_out_en <= 1'b0;
  end else begin
    if(last_out_done)
        last_out_en <= 1'b0;
    else if(pdp_cube_end)
        last_out_en <= 1'b0;
    else if((first_out_num != 5'd1) & (~subcube_end_flag)) begin
        if(need_bubble) begin
            if(bubble_en_end)
                last_out_en <= 1'b1;
        end else if(|flush_num) begin
            if(non_splitw & line_last_stripe_done)
                last_out_en <= 1'b1;
            else if(~non_splitw & last_splitw_en & line_last_stripe_done)
                last_out_en <= 1'b1;
        end
    end else
        last_out_en <= 1'b0;
  end
end

assign {mon_first_out_num_dec2[2:0],first_out_num_dec2[2:0]} = need_bubble ? (first_out_num - 5'd2) : ({2'b0,flush_num} - 5'd1);

always @(posedge nvdla_core_clk or negedge nvdla_core_rstn) begin
  if (!nvdla_core_rstn) begin
    last_out_cnt <= {3{1'b0}};
  end else begin
    if(last_out_en) begin
        if(strip_recieve_done) begin
            if(last_out_done)
                last_out_cnt <= 3'd0;
            else
                last_out_cnt <= last_out_cnt + 1'b1;
        end
    end else
        last_out_cnt <= 3'd0;
  end
end
assign last_out_done = (last_out_cnt[2:0] == first_out_num_dec2[2:0]) & strip_recieve_done & last_out_en;

assign pooling_1d_rdy      = (strip_xcnt_psize== pooling_size_h_cfg[2:0]) &  strip_recieve_done;

/////////////////////////////////////////////////////////

always @(posedge nvdla_core_clk or negedge nvdla_core_rstn) begin
  if (!nvdla_core_rstn) begin
    strip_cnt_total[12:0] <= {13{1'b0}};
  end else begin
    if(init_cnt)
        strip_cnt_total[12:0] <= 13'd0;
    else if(strip_recieve_done)
        strip_cnt_total[12:0] <= strip_cnt_total + 1;
  end
end
  
assign strip_width_end  = (strip_cnt_total == pooling_pwidth);
assign line_last_stripe_done = (strip_width_end & strip_recieve_done);

//-----------------------
//-----------------------
assign {mon_rest_width,rest_width[12:0]} = pooling_pwidth - strip_cnt_total;
assign rest_width_use[13:0] = (non_splitw | splitw_end) ? (rest_width + {10'd0,reg2dp_pad_right_cfg}) : {1'b0,rest_width};
assign last_pooling_flag = rest_width_use[13:0] <= {11'd0,pooling_size_h_cfg};
//======================================================================
//----------------------------------------------------------------------
always @(posedge nvdla_core_clk or negedge nvdla_core_rstn) begin
  if (!nvdla_core_rstn) begin
    unit1d_cnt_stride[2:0] <= {3{1'b0}};
  end else begin
    if(init_cnt) begin
       unit1d_cnt_stride[2:0] <= padding_stride_num;
    end else if(stride_end) begin
       if(unit1d_cnt_stride == regs_num)
          unit1d_cnt_stride[2:0] <= 3'd0;
       else
          unit1d_cnt_stride[2:0] <= unit1d_cnt_stride +1;
    end
  end
end

always @(posedge nvdla_core_clk or negedge nvdla_core_rstn) begin
  if (!nvdla_core_rstn) begin
    unit1d_cnt_pooling[2:0] <= {3{1'b0}};
  end else begin
    if(init_cnt)
         unit1d_cnt_pooling[2:0] <= 0;
    else if(pooling_1d_rdy | line_ldata_valid) begin
       if(unit1d_cnt_pooling == regs_num)
         unit1d_cnt_pooling[2:0] <= 0;
       else
         unit1d_cnt_pooling[2:0] <= unit1d_cnt_pooling + 1;
   end
  end
end

assign line_ldata_valid = line_last_stripe_done;

assign init_unit1d_set[0] = init_cnt & (padding_stride_num>=0) & (pout_width_cur >= 3'd0); 

assign unit1d_set_trig[0] = stride_end & (unit1d_cnt_stride == regs_num) & (~last_pooling_flag);

assign unit1d_set[0] = unit1d_set_trig[0] | init_unit1d_set[0];

assign unit1d_clr[0]=  (pooling_1d_rdy & (unit1d_cnt_pooling == 3'd0)) | line_ldata_valid;

always @(posedge nvdla_core_clk or negedge nvdla_core_rstn) begin
  if (!nvdla_core_rstn) begin
    unit1d_en[0] <= 1'b0;
  end else begin

 if(pdp_cube_end) 

      unit1d_en[0] <= 1'b0;

 else if(unit1d_set[0])

      unit1d_en[0] <= 1'b1;

 else if(unit1d_clr[0]) 

      unit1d_en[0] <= 1'b0;

  end
end

assign init_unit1d_set[1] = init_cnt & (padding_stride_num>=1) & (pout_width_cur >= 3'd1); 

assign unit1d_set_trig[1]=  stride_end & (unit1d_cnt_stride == 3'd0) & (unit1d_cnt_stride != regs_num) & (~last_pooling_flag);

assign unit1d_set[1] = unit1d_set_trig[1] | init_unit1d_set[1];

assign unit1d_clr[1]=  (pooling_1d_rdy & (unit1d_cnt_pooling == 3'd1)) | line_ldata_valid;

always @(posedge nvdla_core_clk or negedge nvdla_core_rstn) begin
  if (!nvdla_core_rstn) begin
    unit1d_en[1] <= 1'b0;
  end else begin

 if(pdp_cube_end) 

      unit1d_en[1] <= 1'b0;

 else if(unit1d_set[1])

      unit1d_en[1] <= 1'b1;

 else if(unit1d_clr[1]) 

      unit1d_en[1] <= 1'b0;

  end
end

assign init_unit1d_set[2] = init_cnt & (padding_stride_num>=2) & (pout_width_cur >= 3'd2); 

assign unit1d_set_trig[2]=  stride_end & (unit1d_cnt_stride == 3'd1) & (unit1d_cnt_stride != regs_num) & (~last_pooling_flag);

assign unit1d_set[2] = unit1d_set_trig[2] | init_unit1d_set[2];

assign unit1d_clr[2]=  (pooling_1d_rdy & (unit1d_cnt_pooling == 3'd2)) | line_ldata_valid;

always @(posedge nvdla_core_clk or negedge nvdla_core_rstn) begin
  if (!nvdla_core_rstn) begin
    unit1d_en[2] <= 1'b0;
  end else begin

 if(pdp_cube_end) 

      unit1d_en[2] <= 1'b0;

 else if(unit1d_set[2])

      unit1d_en[2] <= 1'b1;

 else if(unit1d_clr[2]) 

      unit1d_en[2] <= 1'b0;

  end
end

assign init_unit1d_set[3] = init_cnt & (padding_stride_num>=3) & (pout_width_cur >= 3'd3); 

assign unit1d_set_trig[3]=  stride_end & (unit1d_cnt_stride == 3'd2) & (unit1d_cnt_stride != regs_num) & (~last_pooling_flag);

assign unit1d_set[3] = unit1d_set_trig[3] | init_unit1d_set[3];

assign unit1d_clr[3]=  (pooling_1d_rdy & (unit1d_cnt_pooling == 3'd3)) | line_ldata_valid;

always @(posedge nvdla_core_clk or negedge nvdla_core_rstn) begin
  if (!nvdla_core_rstn) begin
    unit1d_en[3] <= 1'b0;
  end else begin

 if(pdp_cube_end) 

      unit1d_en[3] <= 1'b0;

 else if(unit1d_set[3])

      unit1d_en[3] <= 1'b1;

 else if(unit1d_clr[3]) 

      unit1d_en[3] <= 1'b0;

  end
end

assign init_unit1d_set[4] = init_cnt & (padding_stride_num>=4) & (pout_width_cur >= 3'd4); 

assign unit1d_set_trig[4]=  stride_end & (unit1d_cnt_stride == 3'd3) & (unit1d_cnt_stride != regs_num) & (~last_pooling_flag);

assign unit1d_set[4] = unit1d_set_trig[4] | init_unit1d_set[4];

assign unit1d_clr[4]=  (pooling_1d_rdy & (unit1d_cnt_pooling == 3'd4)) | line_ldata_valid;

always @(posedge nvdla_core_clk or negedge nvdla_core_rstn) begin
  if (!nvdla_core_rstn) begin
    unit1d_en[4] <= 1'b0;
  end else begin

 if(pdp_cube_end) 

      unit1d_en[4] <= 1'b0;

 else if(unit1d_set[4])

      unit1d_en[4] <= 1'b1;

 else if(unit1d_clr[4]) 

      unit1d_en[4] <= 1'b0;

  end
end

assign init_unit1d_set[5] = init_cnt & (padding_stride_num>=5) & (pout_width_cur >= 3'd5); 

assign unit1d_set_trig[5]=  stride_end & (unit1d_cnt_stride == 3'd4) & (unit1d_cnt_stride != regs_num) & (~last_pooling_flag);

assign unit1d_set[5] = unit1d_set_trig[5] | init_unit1d_set[5];

assign unit1d_clr[5]=  (pooling_1d_rdy & (unit1d_cnt_pooling == 3'd5)) | line_ldata_valid;

always @(posedge nvdla_core_clk or negedge nvdla_core_rstn) begin
  if (!nvdla_core_rstn) begin
    unit1d_en[5] <= 1'b0;
  end else begin

 if(pdp_cube_end) 

      unit1d_en[5] <= 1'b0;

 else if(unit1d_set[5])

      unit1d_en[5] <= 1'b1;

 else if(unit1d_clr[5]) 

      unit1d_en[5] <= 1'b0;

  end
end

assign init_unit1d_set[6] = init_cnt & (padding_stride_num>=6) & (pout_width_cur >= 3'd6); 

assign unit1d_set_trig[6]=  stride_end & (unit1d_cnt_stride == 3'd5) & (unit1d_cnt_stride != regs_num) & (~last_pooling_flag);

assign unit1d_set[6] = unit1d_set_trig[6] | init_unit1d_set[6];

assign unit1d_clr[6]=  (pooling_1d_rdy & (unit1d_cnt_pooling == 3'd6)) | line_ldata_valid;

always @(posedge nvdla_core_clk or negedge nvdla_core_rstn) begin
  if (!nvdla_core_rstn) begin
    unit1d_en[6] <= 1'b0;
  end else begin

 if(pdp_cube_end) 

      unit1d_en[6] <= 1'b0;

 else if(unit1d_set[6])

      unit1d_en[6] <= 1'b1;

 else if(unit1d_clr[6]) 

      unit1d_en[6] <= 1'b0;

  end
end

assign init_unit1d_set[7] = init_cnt & (padding_stride_num>=7) & (pout_width_cur >= 3'd7); 

assign unit1d_set_trig[7]=  stride_end & (unit1d_cnt_stride == 3'd6) & (unit1d_cnt_stride != regs_num) & (~last_pooling_flag);

assign unit1d_set[7] = unit1d_set_trig[7] | init_unit1d_set[7];

assign unit1d_clr[7]=  (pooling_1d_rdy & (unit1d_cnt_pooling == 3'd7)) | line_ldata_valid;

always @(posedge nvdla_core_clk or negedge nvdla_core_rstn) begin
  if (!nvdla_core_rstn) begin
    unit1d_en[7] <= 1'b0;
  end else begin

 if(pdp_cube_end) 

      unit1d_en[7] <= 1'b0;

 else if(unit1d_set[7])

      unit1d_en[7] <= 1'b1;

 else if(unit1d_clr[7]) 

      unit1d_en[7] <= 1'b0;

  end
end

 always @(posedge nvdla_core_clk or negedge nvdla_core_rstn) begin
   if (!nvdla_core_rstn) begin
     pooling_din_1st_0 <= 1'b0;
   end else begin

    if(unit1d_set[0])

        pooling_din_1st_0 <= 1'b1;

    else if(strip_recieve_done)

        pooling_din_1st_0 <= 1'b0;

   end
 end

 always @(posedge nvdla_core_clk or negedge nvdla_core_rstn) begin
   if (!nvdla_core_rstn) begin
     pooling_din_1st_1 <= 1'b0;
   end else begin

    if(unit1d_set[1])

        pooling_din_1st_1 <= 1'b1;

    else if(strip_recieve_done)

        pooling_din_1st_1 <= 1'b0;

   end
 end

 always @(posedge nvdla_core_clk or negedge nvdla_core_rstn) begin
   if (!nvdla_core_rstn) begin
     pooling_din_1st_2 <= 1'b0;
   end else begin

    if(unit1d_set[2])

        pooling_din_1st_2 <= 1'b1;

    else if(strip_recieve_done)

        pooling_din_1st_2 <= 1'b0;

   end
 end

 always @(posedge nvdla_core_clk or negedge nvdla_core_rstn) begin
   if (!nvdla_core_rstn) begin
     pooling_din_1st_3 <= 1'b0;
   end else begin

    if(unit1d_set[3])

        pooling_din_1st_3 <= 1'b1;

    else if(strip_recieve_done)

        pooling_din_1st_3 <= 1'b0;

   end
 end

 always @(posedge nvdla_core_clk or negedge nvdla_core_rstn) begin
   if (!nvdla_core_rstn) begin
     pooling_din_1st_4 <= 1'b0;
   end else begin

    if(unit1d_set[4])

        pooling_din_1st_4 <= 1'b1;

    else if(strip_recieve_done)

        pooling_din_1st_4 <= 1'b0;

   end
 end

 always @(posedge nvdla_core_clk or negedge nvdla_core_rstn) begin
   if (!nvdla_core_rstn) begin
     pooling_din_1st_5 <= 1'b0;
   end else begin

    if(unit1d_set[5])

        pooling_din_1st_5 <= 1'b1;

    else if(strip_recieve_done)

        pooling_din_1st_5 <= 1'b0;

   end
 end

 always @(posedge nvdla_core_clk or negedge nvdla_core_rstn) begin
   if (!nvdla_core_rstn) begin
     pooling_din_1st_6 <= 1'b0;
   end else begin

    if(unit1d_set[6])

        pooling_din_1st_6 <= 1'b1;

    else if(strip_recieve_done)

        pooling_din_1st_6 <= 1'b0;

   end
 end

 always @(posedge nvdla_core_clk or negedge nvdla_core_rstn) begin
   if (!nvdla_core_rstn) begin
     pooling_din_1st_7 <= 1'b0;
   end else begin

    if(unit1d_set[7])

        pooling_din_1st_7 <= 1'b1;

    else if(strip_recieve_done)

        pooling_din_1st_7 <= 1'b0;

   end
 end

//////////////////////////////////////////////////////////////////////////////////////
assign datin_buf    = pdp_datin_pd[96:0];
assign datin_buf_1  = {pdp_datin_pd[96:88],pdp_datin_pd1[87:0]};
assign pdp_datin_prdy_1 = &unit1d_prdy & pdp_info_in_prdy;
assign pdp_full_pvld = pdp_datin_pvld | cur_datin_disable;

assign unit1d_pvld[0] = pdp_full_pvld & pdp_info_in_prdy & (&{unit1d_prdy[7:1]});
assign unit1d_pvld[1] = pdp_full_pvld & pdp_info_in_prdy & (&{unit1d_prdy[7:2],unit1d_prdy[0]});
assign unit1d_pvld[2] = pdp_full_pvld & pdp_info_in_prdy & (&{unit1d_prdy[7:3],unit1d_prdy[1:0]});
assign unit1d_pvld[3] = pdp_full_pvld & pdp_info_in_prdy & (&{unit1d_prdy[7:4],unit1d_prdy[2:0]});
assign unit1d_pvld[4] = pdp_full_pvld & pdp_info_in_prdy & (&{unit1d_prdy[7:5],unit1d_prdy[3:0]});
assign unit1d_pvld[5] = pdp_full_pvld & pdp_info_in_prdy & (&{unit1d_prdy[7:6],unit1d_prdy[4:0]});
assign unit1d_pvld[6] = pdp_full_pvld & pdp_info_in_prdy & (&{unit1d_prdy[7  ],unit1d_prdy[5:0]});
assign unit1d_pvld[7] = pdp_full_pvld & pdp_info_in_prdy & (&{unit1d_prdy[6:0]});

//============================================================
assign pdp_info_in_pvld = pdp_full_pvld & (&unit1d_prdy);
assign pdp_info_in_pd = {pdp_din_lc,last_c,last_out_en,cur_datin_disable,pooling_din_last[7:0]};
NV_NVDLA_PDP_cal1d_info_fifo u_NV_NVDLA_PDP_cal1d_info_fifo (
   .nvdla_core_clk          (nvdla_core_clk)
  ,.nvdla_core_rstn         (nvdla_core_rstn)
  ,.pdp_info_in_prdy        (pdp_info_in_prdy)
  ,.pdp_info_in_pvld        (pdp_info_in_pvld)
  ,.pdp_info_in_pd          (pdp_info_in_pd[11:0])
  ,.pdp_info_out_prdy       (pdp_info_out_prdy)
  ,.pdp_info_out_pvld       (pdp_info_out_pvld)
  ,.pdp_info_out_pd         (pdp_info_out_pd[11:0])
  ,.pwrbus_ram_pd           (pwrbus_ram_pd[31:0])
  );
assign pdp_info_out_prdy = unit1d_out_prdy_use & (&unit1d_out_pvld);
assign {pdp_din_lc_sync,last_c_sync, last_out_en_sync,cur_datin_disable_sync,pooling_din_last_sync[7:0]} = pdp_info_out_pd[11:0];
//============================================================
//------------------------------------------------------------

 assign pooling_din_last[0] = unit1d_en[0] & (((strip_xcnt_psize== pooling_size_h_cfg[2:0]) & (unit1d_cnt_pooling==3'd0)) | strip_width_end) ; 

NV_NVDLA_PDP_CORE_unit1d unit1d_0 (
   .nvdla_core_clk          (nvdla_core_clk)
  ,.nvdla_core_rstn         (nvdla_core_rstn)
  ,.average_pooling_en      (average_pooling_en)
  ,.cur_datin_disable       (cur_datin_disable)
  ,.last_out_en             ((last_out_en_sync | cur_datin_disable_sync))
  ,.nvdla_op_gated_clk_fp16 (nvdla_op_gated_clk_fp16)
  ,.pdma2pdp_pd             (datin_buf[93:0])
  ,.pdma2pdp_pvld           (unit1d_pvld[0])
  ,.pdp_din_lc_f            (pdp_din_lc)
  ,.pooling_din_1st         ((pooling_din_1st_0 ))
  ,.pooling_din_last        (pooling_din_last[0])
  ,.pooling_out_prdy        (unit1d_out_prdy[0])
  ,.pooling_type_cfg        (pooling_type_cfg[1:0])
  ,.pooling_unit_en         (unit1d_en[0])
  ,.reg2dp_fp16_en          (reg2dp_fp16_en)
  ,.reg2dp_int16_en         (reg2dp_int16_en)
  ,.reg2dp_int8_en          (reg2dp_int8_en)
  ,.pdma2pdp_prdy           (unit1d_prdy[0])
  ,.pooling_out             (unit1d_out_0[91:0])
  ,.pooling_out_pvld        (unit1d_out_pvld[0])
  );

 assign pooling_din_last[1] = unit1d_en[1] & (((strip_xcnt_psize== pooling_size_h_cfg[2:0]) & (unit1d_cnt_pooling==3'd1)) | strip_width_end) ; 

NV_NVDLA_PDP_CORE_unit1d unit1d_1 (
   .nvdla_core_clk          (nvdla_core_clk)
  ,.nvdla_core_rstn         (nvdla_core_rstn)
  ,.average_pooling_en      (average_pooling_en)
  ,.cur_datin_disable       (cur_datin_disable)
  ,.last_out_en             ((last_out_en_sync | cur_datin_disable_sync))
  ,.nvdla_op_gated_clk_fp16 (nvdla_op_gated_clk_fp16)
  ,.pdma2pdp_pd             (datin_buf[93:0])
  ,.pdma2pdp_pvld           (unit1d_pvld[1])
  ,.pdp_din_lc_f            (pdp_din_lc)
  ,.pooling_din_1st         ((pooling_din_1st_1 ))
  ,.pooling_din_last        (pooling_din_last[1])
  ,.pooling_out_prdy        (unit1d_out_prdy[1])
  ,.pooling_type_cfg        (pooling_type_cfg[1:0])
  ,.pooling_unit_en         (unit1d_en[1])
  ,.reg2dp_fp16_en          (reg2dp_fp16_en)
  ,.reg2dp_int16_en         (reg2dp_int16_en)
  ,.reg2dp_int8_en          (reg2dp_int8_en)
  ,.pdma2pdp_prdy           (unit1d_prdy[1])
  ,.pooling_out             (unit1d_out_1[91:0])
  ,.pooling_out_pvld        (unit1d_out_pvld[1])
  );

 assign pooling_din_last[2] = unit1d_en[2] & (((strip_xcnt_psize== pooling_size_h_cfg[2:0]) & (unit1d_cnt_pooling==3'd2)) | strip_width_end) ; 

NV_NVDLA_PDP_CORE_unit1d unit1d_2 (
   .nvdla_core_clk          (nvdla_core_clk)
  ,.nvdla_core_rstn         (nvdla_core_rstn)
  ,.average_pooling_en      (average_pooling_en)
  ,.cur_datin_disable       (cur_datin_disable)
  ,.last_out_en             ((last_out_en_sync | cur_datin_disable_sync))
  ,.nvdla_op_gated_clk_fp16 (nvdla_op_gated_clk_fp16)
  ,.pdma2pdp_pd             (datin_buf[93:0])
  ,.pdma2pdp_pvld           (unit1d_pvld[2])
  ,.pdp_din_lc_f            (pdp_din_lc)
  ,.pooling_din_1st         ((pooling_din_1st_2 ))
  ,.pooling_din_last        (pooling_din_last[2])
  ,.pooling_out_prdy        (unit1d_out_prdy[2])
  ,.pooling_type_cfg        (pooling_type_cfg[1:0])
  ,.pooling_unit_en         (unit1d_en[2])
  ,.reg2dp_fp16_en          (reg2dp_fp16_en)
  ,.reg2dp_int16_en         (reg2dp_int16_en)
  ,.reg2dp_int8_en          (reg2dp_int8_en)
  ,.pdma2pdp_prdy           (unit1d_prdy[2])
  ,.pooling_out             (unit1d_out_2[91:0])
  ,.pooling_out_pvld        (unit1d_out_pvld[2])
  );

 assign pooling_din_last[3] = unit1d_en[3] & (((strip_xcnt_psize== pooling_size_h_cfg[2:0]) & (unit1d_cnt_pooling==3'd3)) | strip_width_end) ; 

NV_NVDLA_PDP_CORE_unit1d unit1d_3 (
   .nvdla_core_clk          (nvdla_core_clk)
  ,.nvdla_core_rstn         (nvdla_core_rstn)
  ,.average_pooling_en      (average_pooling_en)
  ,.cur_datin_disable       (cur_datin_disable)
  ,.last_out_en             ((last_out_en_sync | cur_datin_disable_sync))
  ,.nvdla_op_gated_clk_fp16 (nvdla_op_gated_clk_fp16)
  ,.pdma2pdp_pd             (datin_buf[93:0])
  ,.pdma2pdp_pvld           (unit1d_pvld[3])
  ,.pdp_din_lc_f            (pdp_din_lc)
  ,.pooling_din_1st         ((pooling_din_1st_3 ))
  ,.pooling_din_last        (pooling_din_last[3])
  ,.pooling_out_prdy        (unit1d_out_prdy[3])
  ,.pooling_type_cfg        (pooling_type_cfg[1:0])
  ,.pooling_unit_en         (unit1d_en[3])
  ,.reg2dp_fp16_en          (reg2dp_fp16_en)
  ,.reg2dp_int16_en         (reg2dp_int16_en)
  ,.reg2dp_int8_en          (reg2dp_int8_en)
  ,.pdma2pdp_prdy           (unit1d_prdy[3])
  ,.pooling_out             (unit1d_out_3[91:0])
  ,.pooling_out_pvld        (unit1d_out_pvld[3])
  );

 assign pooling_din_last[4] = unit1d_en[4] & (((strip_xcnt_psize== pooling_size_h_cfg[2:0]) & (unit1d_cnt_pooling==3'd4)) | strip_width_end) ; 

NV_NVDLA_PDP_CORE_unit1d unit1d_4 (
   .nvdla_core_clk          (nvdla_core_clk)
  ,.nvdla_core_rstn         (nvdla_core_rstn)
  ,.average_pooling_en      (average_pooling_en)
  ,.cur_datin_disable       (cur_datin_disable)
  ,.last_out_en             ((last_out_en_sync | cur_datin_disable_sync))
  ,.nvdla_op_gated_clk_fp16 (nvdla_op_gated_clk_fp16)
  ,.pdma2pdp_pd             (datin_buf_1[93:0])
  ,.pdma2pdp_pvld           (unit1d_pvld[4])
  ,.pdp_din_lc_f            (pdp_din_lc)
  ,.pooling_din_1st         ((pooling_din_1st_4 ))
  ,.pooling_din_last        (pooling_din_last[4])
  ,.pooling_out_prdy        (unit1d_out_prdy[4])
  ,.pooling_type_cfg        (pooling_type_cfg[1:0])
  ,.pooling_unit_en         (unit1d_en[4])
  ,.reg2dp_fp16_en          (reg2dp_fp16_en)
  ,.reg2dp_int16_en         (reg2dp_int16_en)
  ,.reg2dp_int8_en          (reg2dp_int8_en)
  ,.pdma2pdp_prdy           (unit1d_prdy[4])
  ,.pooling_out             (unit1d_out_4[91:0])
  ,.pooling_out_pvld        (unit1d_out_pvld[4])
  );

 assign pooling_din_last[5] = unit1d_en[5] & (((strip_xcnt_psize== pooling_size_h_cfg[2:0]) & (unit1d_cnt_pooling==3'd5)) | strip_width_end) ; 

NV_NVDLA_PDP_CORE_unit1d unit1d_5 (
   .nvdla_core_clk          (nvdla_core_clk)
  ,.nvdla_core_rstn         (nvdla_core_rstn)
  ,.average_pooling_en      (average_pooling_en)
  ,.cur_datin_disable       (cur_datin_disable)
  ,.last_out_en             ((last_out_en_sync | cur_datin_disable_sync))
  ,.nvdla_op_gated_clk_fp16 (nvdla_op_gated_clk_fp16)
  ,.pdma2pdp_pd             (datin_buf_1[93:0])
  ,.pdma2pdp_pvld           (unit1d_pvld[5])
  ,.pdp_din_lc_f            (pdp_din_lc)
  ,.pooling_din_1st         ((pooling_din_1st_5 ))
  ,.pooling_din_last        (pooling_din_last[5])
  ,.pooling_out_prdy        (unit1d_out_prdy[5])
  ,.pooling_type_cfg        (pooling_type_cfg[1:0])
  ,.pooling_unit_en         (unit1d_en[5])
  ,.reg2dp_fp16_en          (reg2dp_fp16_en)
  ,.reg2dp_int16_en         (reg2dp_int16_en)
  ,.reg2dp_int8_en          (reg2dp_int8_en)
  ,.pdma2pdp_prdy           (unit1d_prdy[5])
  ,.pooling_out             (unit1d_out_5[91:0])
  ,.pooling_out_pvld        (unit1d_out_pvld[5])
  );

 assign pooling_din_last[6] = unit1d_en[6] & (((strip_xcnt_psize== pooling_size_h_cfg[2:0]) & (unit1d_cnt_pooling==3'd6)) | strip_width_end) ; 

NV_NVDLA_PDP_CORE_unit1d unit1d_6 (
   .nvdla_core_clk          (nvdla_core_clk)
  ,.nvdla_core_rstn         (nvdla_core_rstn)
  ,.average_pooling_en      (average_pooling_en)
  ,.cur_datin_disable       (cur_datin_disable)
  ,.last_out_en             ((last_out_en_sync | cur_datin_disable_sync))
  ,.nvdla_op_gated_clk_fp16 (nvdla_op_gated_clk_fp16)
  ,.pdma2pdp_pd             (datin_buf_1[93:0])
  ,.pdma2pdp_pvld           (unit1d_pvld[6])
  ,.pdp_din_lc_f            (pdp_din_lc)
  ,.pooling_din_1st         ((pooling_din_1st_6 ))
  ,.pooling_din_last        (pooling_din_last[6])
  ,.pooling_out_prdy        (unit1d_out_prdy[6])
  ,.pooling_type_cfg        (pooling_type_cfg[1:0])
  ,.pooling_unit_en         (unit1d_en[6])
  ,.reg2dp_fp16_en          (reg2dp_fp16_en)
  ,.reg2dp_int16_en         (reg2dp_int16_en)
  ,.reg2dp_int8_en          (reg2dp_int8_en)
  ,.pdma2pdp_prdy           (unit1d_prdy[6])
  ,.pooling_out             (unit1d_out_6[91:0])
  ,.pooling_out_pvld        (unit1d_out_pvld[6])
  );

 assign pooling_din_last[7] = unit1d_en[7] & (((strip_xcnt_psize== pooling_size_h_cfg[2:0]) & (unit1d_cnt_pooling==3'd7)) | strip_width_end) ; 

NV_NVDLA_PDP_CORE_unit1d unit1d_7 (
   .nvdla_core_clk          (nvdla_core_clk)
  ,.nvdla_core_rstn         (nvdla_core_rstn)
  ,.average_pooling_en      (average_pooling_en)
  ,.cur_datin_disable       (cur_datin_disable)
  ,.last_out_en             ((last_out_en_sync | cur_datin_disable_sync))
  ,.nvdla_op_gated_clk_fp16 (nvdla_op_gated_clk_fp16)
  ,.pdma2pdp_pd             (datin_buf_1[93:0])
  ,.pdma2pdp_pvld           (unit1d_pvld[7])
  ,.pdp_din_lc_f            (pdp_din_lc)
  ,.pooling_din_1st         ((pooling_din_1st_7 ))
  ,.pooling_din_last        (pooling_din_last[7])
  ,.pooling_out_prdy        (unit1d_out_prdy[7])
  ,.pooling_type_cfg        (pooling_type_cfg[1:0])
  ,.pooling_unit_en         (unit1d_en[7])
  ,.reg2dp_fp16_en          (reg2dp_fp16_en)
  ,.reg2dp_int16_en         (reg2dp_int16_en)
  ,.reg2dp_int8_en          (reg2dp_int8_en)
  ,.pdma2pdp_prdy           (unit1d_prdy[7])
  ,.pooling_out             (unit1d_out_7[91:0])
  ,.pooling_out_pvld        (unit1d_out_pvld[7])
  );

//////////////////////////////////////////////////////////////////////////////////////
assign unit1d_out_prdy[0] = unit1d_out_prdy_use & pdp_info_out_pvld & (&{unit1d_out_pvld[7:1]});
assign unit1d_out_prdy[1] = unit1d_out_prdy_use & pdp_info_out_pvld & (&{unit1d_out_pvld[7:2],unit1d_out_pvld[0]});
assign unit1d_out_prdy[2] = unit1d_out_prdy_use & pdp_info_out_pvld & (&{unit1d_out_pvld[7:3],unit1d_out_pvld[1:0]});
assign unit1d_out_prdy[3] = unit1d_out_prdy_use & pdp_info_out_pvld & (&{unit1d_out_pvld[7:4],unit1d_out_pvld[2:0]});
assign unit1d_out_prdy[4] = unit1d_out_prdy_use & pdp_info_out_pvld & (&{unit1d_out_pvld[7:5],unit1d_out_pvld[3:0]});
assign unit1d_out_prdy[5] = unit1d_out_prdy_use & pdp_info_out_pvld & (&{unit1d_out_pvld[7:6],unit1d_out_pvld[4:0]});
assign unit1d_out_prdy[6] = unit1d_out_prdy_use & pdp_info_out_pvld & (&{unit1d_out_pvld[7  ],unit1d_out_pvld[5:0]});
assign unit1d_out_prdy[7] = unit1d_out_prdy_use & pdp_info_out_pvld & (&{unit1d_out_pvld[6:0]});

assign unit1d_out_pvld_use = &unit1d_out_pvld & pdp_info_out_pvld;
//=========================================================
//---------------------------------------------------------
assign pooling1d_out_v_norm = ((|pooling_din_last_sync) & pdp_din_lc_sync & (~cur_datin_disable_sync) & unit1d_out_pvld_use & unit1d_out_prdy_use);
assign pooling1d_out_v_disable = (cur_datin_disable_sync & last_c_sync) & unit1d_out_pvld_use & unit1d_out_prdy_use;
assign pooling1d_out_v_lastout = (last_out_en_sync & pdp_din_lc_sync & unit1d_out_pvld_use & unit1d_out_prdy_use);
assign pooling1d_out_v = pooling1d_out_v_norm | pooling1d_out_v_disable | pooling1d_out_v_lastout;
//////////////////////////////////////////////////////////////////////////////////////
//////////////////////////////////////////////////////////////////////////////////////
always @(posedge nvdla_core_clk or negedge nvdla_core_rstn) begin
  if (!nvdla_core_rstn) begin
    wr_line_dat_cnt[12:0] <= {13{1'b0}};
  end else begin
    if(wr_line_dat_done)
        wr_line_dat_cnt[12:0] <= 0;
    else if(pooling1d_out_v)
        wr_line_dat_cnt[12:0] <= wr_line_dat_cnt + 1;
  end
end
assign wr_line_dat_done  = (wr_line_dat_cnt==pout_width_cur) & pooling1d_out_v;

always @(posedge nvdla_core_clk or negedge nvdla_core_rstn) begin
  if (!nvdla_core_rstn) begin
    wr_surface_dat_cnt <= {13{1'b0}};
  end else begin
   if(wr_surface_dat_done)
       wr_surface_dat_cnt <= 13'd0;
   else if(wr_line_dat_done)
       wr_surface_dat_cnt <= wr_surface_dat_cnt + 13'd1;
  end
end
assign last_line_in = (wr_surface_dat_cnt==reg2dp_cube_in_height[12:0]);
assign wr_surface_dat_done = wr_line_dat_done & last_line_in;

assign cube_out_channel[13:0]= pooling_channel_cfg[12:0] + 1'b1;
assign {mon_surface_num_0,surface_num_0[9:0]} = cube_out_channel[13:4] + {9'd0,(|cube_out_channel[3:0])};
assign surface_num_1[9:0] = {1'b0,cube_out_channel[13:5]} + (|cube_out_channel[4:0]);
assign surface_num        = (reg2dp_input_data[1:0] == 2'h0 )? surface_num_1 : surface_num_0;

always @(posedge nvdla_core_clk or negedge nvdla_core_rstn) begin
  if (!nvdla_core_rstn) begin
    surface_cnt_rd[10:0] <= {11{1'b0}};
  end else begin
  if(wr_subcube_dat_done)
       surface_cnt_rd[10:0] <=  11'd0;
  else if(wr_surface_dat_done)
       surface_cnt_rd[10:0] <= surface_cnt_rd + 1;
  end
end
assign wr_subcube_dat_done = ((surface_num-1)==surface_cnt_rd) & wr_surface_dat_done;

always @(posedge nvdla_core_clk or negedge nvdla_core_rstn) begin
  if (!nvdla_core_rstn) begin
    wr_splitc_cnt[7:0] <= {8{1'b0}};
  end else begin
    if(wr_total_cube_done)
        wr_splitc_cnt[7:0] <= 8'd0;
    else if(wr_subcube_dat_done)
        wr_splitc_cnt[7:0] <= wr_splitc_cnt + 1;
  end
end
assign wr_total_cube_done = (wr_splitc_cnt==pooling_splitw_num_cfg[7:0]) & wr_subcube_dat_done;
//-------------------------------------------------
assign splitw_enable = (pooling_splitw_num_cfg!=8'd0);
assign last_splitw   = (wr_splitc_cnt==pooling_splitw_num_cfg[7:0]) & splitw_enable;
assign first_splitw  = (wr_splitc_cnt==8'd0) & splitw_enable;

assign pout_width_cur[12:0]= (~splitw_enable) ? reg2dp_cube_out_width[12:0] : 
                            (last_splitw  ? {3'd0,pooling_out_lwidth_cfg[9:0]} : 
                             first_splitw ? {3'd0,pooling_out_fwidth_cfg[9:0]} : 
                                            {3'd0,pooling_out_mwidth_cfg[9:0]});

//////////////////////////////////////////////////////////////////////////////////////
//////////////////////////////////////////////////////////////////////////////////////
always @(posedge nvdla_core_clk or negedge nvdla_core_rstn) begin
  if (!nvdla_core_rstn) begin
    pooling_out_cnt[2:0] <= {3{1'b0}};
  end else begin
   if(pdp_op_start)
       pooling_out_cnt[2:0] <= 3'd0;
   else if(pooling1d_out_v) begin
       if((pooling_out_cnt == regs_num) | wr_line_dat_done)
            pooling_out_cnt[2:0] <= 3'd0;
       else
            pooling_out_cnt[2:0] <= pooling_out_cnt + 3'd1 ;
   end
  end
end

always @(
  pooling_out_cnt
  or unit1d_out_0
  or unit1d_out_1
  or unit1d_out_2
  or unit1d_out_3
  or unit1d_out_4
  or unit1d_out_5
  or unit1d_out_6
  or unit1d_out_7
  ) begin
    case(pooling_out_cnt)
       3'd0 : unit1d_actv_out_f = unit1d_out_0;
       3'd1 : unit1d_actv_out_f = unit1d_out_1;
       3'd2 : unit1d_actv_out_f = unit1d_out_2;
       3'd3 : unit1d_actv_out_f = unit1d_out_3;
       3'd4 : unit1d_actv_out_f = unit1d_out_4;
       3'd5 : unit1d_actv_out_f = unit1d_out_5;
       3'd6 : unit1d_actv_out_f = unit1d_out_6;
       3'd7 : unit1d_actv_out_f = unit1d_out_7;
       default : unit1d_actv_out_f = 92'd0;
    endcase
end

assign unit1d_out_prdy_use = unit1d_actv_out_prdy;
assign unit1d_actv_out_pvld = unit1d_out_pvld_use & ((|pooling_din_last_sync) | cur_datin_disable_sync | last_out_en_sync);
assign unit1d_actv_out = unit1d_actv_out_f[91:0];

//=================================
//----------------------------------
always @(
  pad_table_index
  or reg2dp_pad_value_1x_cfg
  or reg2dp_pad_value_2x_cfg
  or reg2dp_pad_value_3x_cfg
  or reg2dp_pad_value_4x_cfg
  or reg2dp_pad_value_5x_cfg
  or reg2dp_pad_value_6x_cfg
  or reg2dp_pad_value_7x_cfg
  ) begin
      case(pad_table_index)
          3'd1: pad_table_out = reg2dp_pad_value_1x_cfg[18:0];
          3'd2: pad_table_out = reg2dp_pad_value_2x_cfg[18:0];
          3'd3: pad_table_out = reg2dp_pad_value_3x_cfg[18:0];
          3'd4: pad_table_out = reg2dp_pad_value_4x_cfg[18:0];
          3'd5: pad_table_out = reg2dp_pad_value_5x_cfg[18:0];
          3'd6: pad_table_out = reg2dp_pad_value_6x_cfg[18:0];
          3'd7: pad_table_out = reg2dp_pad_value_7x_cfg[18:0];
          default:pad_table_out = 19'd0;
       endcase
end

assign loading_en = unit1d_actv_out_pvld & unit1d_actv_out_prdy;

assign {mon_unit1d_actv_data_16bit_0_ff[0],unit1d_actv_data_16bit_0_ff[21:0]} = $signed(unit1d_actv_out[21:0])  + $signed({pad_table_out[18], pad_table_out});
assign {mon_unit1d_actv_data_16bit_1_ff[0],unit1d_actv_data_16bit_1_ff[21:0]} = $signed(unit1d_actv_out[43:22]) + $signed({pad_table_out[18], pad_table_out});
assign {mon_unit1d_actv_data_16bit_2_ff[0],unit1d_actv_data_16bit_2_ff[21:0]} = $signed(unit1d_actv_out[65:44]) + $signed({pad_table_out[18], pad_table_out});
assign {mon_unit1d_actv_data_16bit_3_ff[0],unit1d_actv_data_16bit_3_ff[21:0]} = $signed(unit1d_actv_out[87:66]) + $signed({pad_table_out[18], pad_table_out});
assign {mon_unit1d_actv_data_16bit_0[0],unit1d_actv_data_16bit_0[21:0]} = padding_here_int16 ? {mon_unit1d_actv_data_16bit_0_ff[0],unit1d_actv_data_16bit_0_ff[21:0]} : {unit1d_actv_out[21] ,unit1d_actv_out[21:0]  };
assign {mon_unit1d_actv_data_16bit_1[0],unit1d_actv_data_16bit_1[21:0]} = padding_here_int16 ? {mon_unit1d_actv_data_16bit_1_ff[0],unit1d_actv_data_16bit_1_ff[21:0]} : {unit1d_actv_out[43] ,unit1d_actv_out[43:22] };
assign {mon_unit1d_actv_data_16bit_2[0],unit1d_actv_data_16bit_2[21:0]} = padding_here_int16 ? {mon_unit1d_actv_data_16bit_2_ff[0],unit1d_actv_data_16bit_2_ff[21:0]} : {unit1d_actv_out[65] ,unit1d_actv_out[65:44] };
assign {mon_unit1d_actv_data_16bit_3[0],unit1d_actv_data_16bit_3[21:0]} = padding_here_int16 ? {mon_unit1d_actv_data_16bit_3_ff[0],unit1d_actv_data_16bit_3_ff[21:0]} : {unit1d_actv_out[87] ,unit1d_actv_out[87:66]};

assign {mon_unit1d_actv_data_8bit_0_ff[1:0],unit1d_actv_data_8bit_0_ff[10:0]} = $signed({{1{unit1d_actv_out[10]}},unit1d_actv_out[10:0] }) + $signed({pad_table_out[10], pad_table_out[10:0]});
assign {mon_unit1d_actv_data_8bit_1_ff[1:0],unit1d_actv_data_8bit_1_ff[10:0]} = $signed({{1{unit1d_actv_out[21]}},unit1d_actv_out[21:11]}) + $signed({pad_table_out[10], pad_table_out[10:0]});
assign {mon_unit1d_actv_data_8bit_2_ff[1:0],unit1d_actv_data_8bit_2_ff[10:0]} = $signed({{1{unit1d_actv_out[32]}},unit1d_actv_out[32:22]}) + $signed({pad_table_out[10], pad_table_out[10:0]});
assign {mon_unit1d_actv_data_8bit_3_ff[1:0],unit1d_actv_data_8bit_3_ff[10:0]} = $signed({{1{unit1d_actv_out[43]}},unit1d_actv_out[43:33]}) + $signed({pad_table_out[10], pad_table_out[10:0]});
assign {mon_unit1d_actv_data_8bit_4_ff[1:0],unit1d_actv_data_8bit_4_ff[10:0]} = $signed({{1{unit1d_actv_out[54]}},unit1d_actv_out[54:44]}) + $signed({pad_table_out[10], pad_table_out[10:0]});
assign {mon_unit1d_actv_data_8bit_5_ff[1:0],unit1d_actv_data_8bit_5_ff[10:0]} = $signed({{1{unit1d_actv_out[65]}},unit1d_actv_out[65:55]}) + $signed({pad_table_out[10], pad_table_out[10:0]});
assign {mon_unit1d_actv_data_8bit_6_ff[1:0],unit1d_actv_data_8bit_6_ff[10:0]} = $signed({{1{unit1d_actv_out[76]}},unit1d_actv_out[76:66]}) + $signed({pad_table_out[10], pad_table_out[10:0]});
assign {mon_unit1d_actv_data_8bit_7_ff[1:0],unit1d_actv_data_8bit_7_ff[10:0]} = $signed({{1{unit1d_actv_out[87]}},unit1d_actv_out[87:77]}) + $signed({pad_table_out[10], pad_table_out[10:0]});

assign {mon_unit1d_actv_data_8bit_0[1:0],unit1d_actv_data_8bit_0[10:0]} = padding_here_int8 ? {mon_unit1d_actv_data_8bit_0_ff[1:0],unit1d_actv_data_8bit_0_ff[10:0]} : {2'd0,unit1d_actv_out[10:0] };
assign {mon_unit1d_actv_data_8bit_1[1:0],unit1d_actv_data_8bit_1[10:0]} = padding_here_int8 ? {mon_unit1d_actv_data_8bit_1_ff[1:0],unit1d_actv_data_8bit_1_ff[10:0]} : {2'd0,unit1d_actv_out[21:11]};
assign {mon_unit1d_actv_data_8bit_2[1:0],unit1d_actv_data_8bit_2[10:0]} = padding_here_int8 ? {mon_unit1d_actv_data_8bit_2_ff[1:0],unit1d_actv_data_8bit_2_ff[10:0]} : {2'd0,unit1d_actv_out[32:22]};
assign {mon_unit1d_actv_data_8bit_3[1:0],unit1d_actv_data_8bit_3[10:0]} = padding_here_int8 ? {mon_unit1d_actv_data_8bit_3_ff[1:0],unit1d_actv_data_8bit_3_ff[10:0]} : {2'd0,unit1d_actv_out[43:33]};
assign {mon_unit1d_actv_data_8bit_4[1:0],unit1d_actv_data_8bit_4[10:0]} = padding_here_int8 ? {mon_unit1d_actv_data_8bit_4_ff[1:0],unit1d_actv_data_8bit_4_ff[10:0]} : {2'd0,unit1d_actv_out[54:44]};
assign {mon_unit1d_actv_data_8bit_5[1:0],unit1d_actv_data_8bit_5[10:0]} = padding_here_int8 ? {mon_unit1d_actv_data_8bit_5_ff[1:0],unit1d_actv_data_8bit_5_ff[10:0]} : {2'd0,unit1d_actv_out[65:55]};
assign {mon_unit1d_actv_data_8bit_6[1:0],unit1d_actv_data_8bit_6[10:0]} = padding_here_int8 ? {mon_unit1d_actv_data_8bit_6_ff[1:0],unit1d_actv_data_8bit_6_ff[10:0]} : {2'd0,unit1d_actv_out[76:66]};
assign {mon_unit1d_actv_data_8bit_7[1:0],unit1d_actv_data_8bit_7[10:0]} = padding_here_int8 ? {mon_unit1d_actv_data_8bit_7_ff[1:0],unit1d_actv_data_8bit_7_ff[10:0]} : {2'd0,unit1d_actv_out[87:77]};

assign padding_here = (pooling_type_cfg== 2'h0 ) & (unit1d_actv_out[90:88] != pooling_size_h_cfg);
assign padding_here_int16 = padding_here & (reg2dp_input_data== 2'h1 );
assign padding_here_int8  = padding_here & (reg2dp_input_data== 2'h0 );

assign {mon_pad_table_index[0],pad_table_index[2:0]} = pooling_size_h_cfg - unit1d_actv_out[90:88];

always @(posedge nvdla_core_clk or negedge nvdla_core_rstn) begin
  if (!nvdla_core_rstn) begin
    pooling1d_data_pad <= {112{1'b0}};
  end else begin
   if(loading_en) begin
      if(reg2dp_input_data== 2'h0 )
          pooling1d_data_pad <= {{{3{unit1d_actv_data_8bit_7[10]}}, unit1d_actv_data_8bit_7[10:0]}, {{3{unit1d_actv_data_8bit_6[10]}}, unit1d_actv_data_8bit_6[10:0]},{{3{unit1d_actv_data_8bit_5[10]}}, unit1d_actv_data_8bit_5[10:0]},{{3{unit1d_actv_data_8bit_4[10]}}, unit1d_actv_data_8bit_4[10:0]},
                                  {{3{unit1d_actv_data_8bit_3[10]}}, unit1d_actv_data_8bit_3[10:0]}, {{3{unit1d_actv_data_8bit_2[10]}}, unit1d_actv_data_8bit_2[10:0]},{{3{unit1d_actv_data_8bit_1[10]}}, unit1d_actv_data_8bit_1[10:0]},{{3{unit1d_actv_data_8bit_0[10]}}, unit1d_actv_data_8bit_0[10:0]}};
      else
          pooling1d_data_pad <= {{{6{unit1d_actv_data_16bit_3[21]}}, unit1d_actv_data_16bit_3[21:0]}, {{6{unit1d_actv_data_16bit_2[21]}}, unit1d_actv_data_16bit_2[21:0]}, {{6{unit1d_actv_data_16bit_1[21]}}, unit1d_actv_data_16bit_1[21:0]}, {{6{unit1d_actv_data_16bit_0[21]}}, unit1d_actv_data_16bit_0[21:0]}};
   end
  end
end

always @(posedge nvdla_core_clk or negedge nvdla_core_rstn) begin
  if (!nvdla_core_rstn) begin
    pooling1d_data_pad_vld <= 1'b0;
  end else begin
    if(fp16_en & average_pooling_en) begin
        pooling1d_data_pad_vld <= 1'b0;
    end else begin
        if(unit1d_actv_out_pvld)
           pooling1d_data_pad_vld <= 1'b1;
        else if(pooling1d_data_pad_rdy)
           pooling1d_data_pad_vld <= 1'b0;
    end
  end
end

assign unit1d_actv_out_prdy = (fp16_en & average_pooling_en)? fp16_in_prdy : (~pooling1d_data_pad_vld | pooling1d_data_pad_rdy);
//=================================
//----------------------------------
assign fp16_en = reg2dp_fp16_en;
assign average_pooling_en = (pooling_type_cfg== 2'h0 );
/////////////////////////////////////////////////////////////////////////////////////
assign fp16_in_pvld = unit1d_actv_out_pvld & fp16_en & average_pooling_en;
assign fp16_in_prdy = fp16_add_pad_in3_b_rdy & fp16_add_pad_in2_b_rdy & fp16_add_pad_in1_b_rdy & fp16_add_pad_in0_b_rdy
                    & fp16_add_pad_in3_a_rdy & fp16_add_pad_in2_a_rdy & fp16_add_pad_in1_a_rdy & fp16_add_pad_in0_a_rdy ; 
assign fp16_add_pad_in0_a_vld = (fp16_in_pvld) & (fp16_add_pad_in0_b_rdy&fp16_add_pad_in1_a_rdy&fp16_add_pad_in1_b_rdy&fp16_add_pad_in2_a_rdy&fp16_add_pad_in2_b_rdy&fp16_add_pad_in3_a_rdy&fp16_add_pad_in3_b_rdy);
assign fp16_add_pad_in1_a_vld = (fp16_in_pvld) & (fp16_add_pad_in0_a_rdy&fp16_add_pad_in0_b_rdy&fp16_add_pad_in1_b_rdy&fp16_add_pad_in2_a_rdy&fp16_add_pad_in2_b_rdy&fp16_add_pad_in3_a_rdy&fp16_add_pad_in3_b_rdy);
assign fp16_add_pad_in2_a_vld = (fp16_in_pvld) & (fp16_add_pad_in0_a_rdy&fp16_add_pad_in0_b_rdy&fp16_add_pad_in1_a_rdy&fp16_add_pad_in1_b_rdy&fp16_add_pad_in2_b_rdy&fp16_add_pad_in3_a_rdy&fp16_add_pad_in3_b_rdy);
assign fp16_add_pad_in3_a_vld = (fp16_in_pvld) & (fp16_add_pad_in0_a_rdy&fp16_add_pad_in0_b_rdy&fp16_add_pad_in1_a_rdy&fp16_add_pad_in1_b_rdy&fp16_add_pad_in2_a_rdy&fp16_add_pad_in2_b_rdy&fp16_add_pad_in3_b_rdy);
assign fp16_add_pad_in0_b_vld = (fp16_in_pvld) & (fp16_add_pad_in0_a_rdy&fp16_add_pad_in1_a_rdy&fp16_add_pad_in1_b_rdy&fp16_add_pad_in2_a_rdy&fp16_add_pad_in2_b_rdy&fp16_add_pad_in3_a_rdy&fp16_add_pad_in3_b_rdy);
assign fp16_add_pad_in1_b_vld = (fp16_in_pvld) & (fp16_add_pad_in0_a_rdy&fp16_add_pad_in0_b_rdy&fp16_add_pad_in1_a_rdy&fp16_add_pad_in2_a_rdy&fp16_add_pad_in2_b_rdy&fp16_add_pad_in3_a_rdy&fp16_add_pad_in3_b_rdy);
assign fp16_add_pad_in2_b_vld = (fp16_in_pvld) & (fp16_add_pad_in0_a_rdy&fp16_add_pad_in0_b_rdy&fp16_add_pad_in1_a_rdy&fp16_add_pad_in1_b_rdy&fp16_add_pad_in2_a_rdy&fp16_add_pad_in3_a_rdy&fp16_add_pad_in3_b_rdy);
assign fp16_add_pad_in3_b_vld = (fp16_in_pvld) & (fp16_add_pad_in0_a_rdy&fp16_add_pad_in0_b_rdy&fp16_add_pad_in1_a_rdy&fp16_add_pad_in1_b_rdy&fp16_add_pad_in2_a_rdy&fp16_add_pad_in2_b_rdy&fp16_add_pad_in3_a_rdy);

HLS_fp17_add u_HLS_fp17_add_0 (
   .nvdla_core_clk          (nvdla_op_gated_clk_fp16)
  ,.nvdla_core_rstn         (nvdla_core_rstn)
  ,.chn_a_rsc_z             (unit1d_actv_out[16:0])
  ,.chn_a_rsc_vz            (fp16_add_pad_in0_a_vld)
  ,.chn_a_rsc_lz            (fp16_add_pad_in0_a_rdy)
  ,.chn_b_rsc_z             (pad_table_out[16:0])
  ,.chn_b_rsc_vz            (fp16_add_pad_in0_b_vld)
  ,.chn_b_rsc_lz            (fp16_add_pad_in0_b_rdy)
  ,.chn_o_rsc_z             (fp16_add_pad_out0[16:0])
  ,.chn_o_rsc_vz            (fp16_add_pad_out0_rdy)
  ,.chn_o_rsc_lz            (fp16_add_pad_out0_vld)
  );

HLS_fp17_add u_HLS_fp17_add_1 (
   .nvdla_core_clk          (nvdla_op_gated_clk_fp16)
  ,.nvdla_core_rstn         (nvdla_core_rstn)
  ,.chn_a_rsc_z             (unit1d_actv_out[38:22])
  ,.chn_a_rsc_vz            (fp16_add_pad_in1_a_vld)
  ,.chn_a_rsc_lz            (fp16_add_pad_in1_a_rdy)
  ,.chn_b_rsc_z             (pad_table_out[16:0])
  ,.chn_b_rsc_vz            (fp16_add_pad_in1_b_vld)
  ,.chn_b_rsc_lz            (fp16_add_pad_in1_b_rdy)
  ,.chn_o_rsc_z             (fp16_add_pad_out1[16:0])
  ,.chn_o_rsc_vz            (fp16_add_pad_out1_rdy)
  ,.chn_o_rsc_lz            (fp16_add_pad_out1_vld)
  );

HLS_fp17_add u_HLS_fp17_add_2 (
   .nvdla_core_clk          (nvdla_op_gated_clk_fp16)
  ,.nvdla_core_rstn         (nvdla_core_rstn)
  ,.chn_a_rsc_z             (unit1d_actv_out[60:44])
  ,.chn_a_rsc_vz            (fp16_add_pad_in2_a_vld)
  ,.chn_a_rsc_lz            (fp16_add_pad_in2_a_rdy)
  ,.chn_b_rsc_z             (pad_table_out[16:0])
  ,.chn_b_rsc_vz            (fp16_add_pad_in2_b_vld)
  ,.chn_b_rsc_lz            (fp16_add_pad_in2_b_rdy)
  ,.chn_o_rsc_z             (fp16_add_pad_out2[16:0])
  ,.chn_o_rsc_vz            (fp16_add_pad_out2_rdy)
  ,.chn_o_rsc_lz            (fp16_add_pad_out2_vld)
  );

HLS_fp17_add u_HLS_fp17_add_3 (
   .nvdla_core_clk          (nvdla_op_gated_clk_fp16)
  ,.nvdla_core_rstn         (nvdla_core_rstn)
  ,.chn_a_rsc_z             (unit1d_actv_out[82:66])
  ,.chn_a_rsc_vz            (fp16_add_pad_in3_a_vld)
  ,.chn_a_rsc_lz            (fp16_add_pad_in3_a_rdy)
  ,.chn_b_rsc_z             (pad_table_out[16:0])
  ,.chn_b_rsc_vz            (fp16_add_pad_in3_b_vld)
  ,.chn_b_rsc_lz            (fp16_add_pad_in3_b_rdy)
  ,.chn_o_rsc_z             (fp16_add_pad_out3[16:0])
  ,.chn_o_rsc_vz            (fp16_add_pad_out3_rdy)
  ,.chn_o_rsc_lz            (fp16_add_pad_out3_vld)
  );

assign fp16_add_pad_out0_rdy = fp16_out_prdy & (fp16_add_pad_out3_vld & fp16_add_pad_out2_vld & fp16_add_pad_out1_vld);
assign fp16_add_pad_out1_rdy = fp16_out_prdy & (fp16_add_pad_out3_vld & fp16_add_pad_out2_vld & fp16_add_pad_out0_vld);
assign fp16_add_pad_out2_rdy = fp16_out_prdy & (fp16_add_pad_out3_vld & fp16_add_pad_out1_vld & fp16_add_pad_out0_vld);
assign fp16_add_pad_out3_rdy = fp16_out_prdy & (fp16_add_pad_out2_vld & fp16_add_pad_out1_vld & fp16_add_pad_out0_vld);

assign fp16_out_pvld = fp16_add_pad_out3_vld & fp16_add_pad_out2_vld & fp16_add_pad_out1_vld & fp16_add_pad_out0_vld;
assign fp16_out_dp   = {11'd0,fp16_add_pad_out3,11'd0,fp16_add_pad_out2,11'd0,fp16_add_pad_out1,11'd0,fp16_add_pad_out0}; 
//=================================
//----------------------------------
assign pooling1d_pd          = (fp16_en & average_pooling_en)? fp16_out_dp : pooling1d_data_pad;
assign pooling1d_pvld        = (fp16_en & average_pooling_en)? fp16_out_pvld : pooling1d_data_pad_vld;
assign pooling1d_data_pad_rdy= (fp16_en & average_pooling_en)? 1'b0 : pooling1d_prdy;
assign fp16_out_prdy         = (fp16_en & average_pooling_en)? pooling1d_prdy : 1'b0;

//==============
//==============

///////////////
///////////////

//////////////////////
assign mon_nan_in = ((|datain_16bit_3[9:0]) & (&datain_16bit_3[14:10]))
                  | ((|datain_16bit_2[9:0]) & (&datain_16bit_2[14:10])) 
                  | ((|datain_16bit_1[9:0]) & (&datain_16bit_1[14:10])) 
                  | ((|datain_16bit_0[9:0]) & (&datain_16bit_0[14:10]));
assign mon_inf_in = ((~(|datain_16bit_3[9:0])) & (&datain_16bit_3[14:10]))
                  | ((~(|datain_16bit_2[9:0])) & (&datain_16bit_2[14:10])) 
                  | ((~(|datain_16bit_1[9:0])) & (&datain_16bit_1[14:10])) 
                  | ((~(|datain_16bit_0[9:0])) & (&datain_16bit_0[14:10]));
assign mon_deno_in = ((|datain_16bit_3[9:0]) & (~(|datain_16bit_3[14:10])))
                   | ((|datain_16bit_2[9:0]) & (~(|datain_16bit_2[14:10]))) 
                   | ((|datain_16bit_1[9:0]) & (~(|datain_16bit_1[14:10]))) 
                   | ((|datain_16bit_0[9:0]) & (~(|datain_16bit_0[14:10])));

////==============
////==============

endmodule // NV_NVDLA_PDP_CORE_cal1d

module NV_NVDLA_PDP_CORE_CAL1D_pipe_p1 (
   nvdla_core_clk
  ,nvdla_core_rstn
  ,sync_switch_in_pd_d0
  ,sync_switch_in_rdy_d1
  ,sync_switch_in_vld_d0
  ,sync_switch_in_pd_d1
  ,sync_switch_in_rdy_d0
  ,sync_switch_in_vld_d1
  );
input         nvdla_core_clk;
input         nvdla_core_rstn;
input  [11:0] sync_switch_in_pd_d0;
input         sync_switch_in_rdy_d1;
input         sync_switch_in_vld_d0;
output [11:0] sync_switch_in_pd_d1;
output        sync_switch_in_rdy_d0;
output        sync_switch_in_vld_d1;
reg    [11:0] p1_pipe_data;
reg           p1_pipe_ready;
reg           p1_pipe_ready_bc;
reg           p1_pipe_valid;
reg    [11:0] sync_switch_in_pd_d1;
reg           sync_switch_in_rdy_d0;
reg           sync_switch_in_vld_d1;
always @(
  p1_pipe_ready
  or p1_pipe_valid
  ) begin
  p1_pipe_ready_bc = p1_pipe_ready || !p1_pipe_valid;
end
always @(posedge nvdla_core_clk or negedge nvdla_core_rstn) begin
  if (!nvdla_core_rstn) begin
    p1_pipe_valid <= 1'b0;
  end else begin
  p1_pipe_valid <= (p1_pipe_ready_bc)? sync_switch_in_vld_d0 : 1'd1;
  end
end
always @(posedge nvdla_core_clk) begin
  p1_pipe_data <= (p1_pipe_ready_bc && sync_switch_in_vld_d0)? sync_switch_in_pd_d0[11:0] : p1_pipe_data;
end
always @(
  p1_pipe_ready_bc
  ) begin
  sync_switch_in_rdy_d0 = p1_pipe_ready_bc;
end
always @(
  p1_pipe_valid
  or sync_switch_in_rdy_d1
  or p1_pipe_data
  ) begin
  sync_switch_in_vld_d1 = p1_pipe_valid;
  p1_pipe_ready = sync_switch_in_rdy_d1;
  sync_switch_in_pd_d1[11:0] = p1_pipe_data;
end
`ifndef VIVA_PLUGIN_PIPE_DISABLE_ASSERTIONS
wire p1_assert_clk = nvdla_core_clk;
`endif
endmodule // NV_NVDLA_PDP_CORE_CAL1D_pipe_p1

`define FORCE_CONTENTION_ASSERTION_RESET_ACTIVE 1'b1
`include "simulate_x_tick.vh"

module NV_NVDLA_PDP_cal1d_info_fifo (
      nvdla_core_clk
    , nvdla_core_rstn
    , pdp_info_in_prdy
    , pdp_info_in_pvld
    , pdp_info_in_pd
    , pdp_info_out_prdy
    , pdp_info_out_pvld
    , pdp_info_out_pd
    , pwrbus_ram_pd
    );

input         nvdla_core_clk;
input         nvdla_core_rstn;
output        pdp_info_in_prdy;
input         pdp_info_in_pvld;
input  [11:0] pdp_info_in_pd;
input         pdp_info_out_prdy;
output        pdp_info_out_pvld;
output [11:0] pdp_info_out_pd;
input  [31:0] pwrbus_ram_pd;

wire nvdla_core_clk_mgated_enable;
wire nvdla_core_clk_mgated;
NV_CLK_gate_power nvdla_core_clk_mgate( .clk(nvdla_core_clk), .reset_(nvdla_core_rstn), .clk_en(nvdla_core_clk_mgated_enable), .clk_gated(nvdla_core_clk_mgated) );

wire wr_reserving;
reg        pdp_info_in_busy_int;
assign     pdp_info_in_prdy = !pdp_info_in_busy_int;
assign       wr_reserving = pdp_info_in_pvld && !pdp_info_in_busy_int;

wire       wr_popping;

reg  [3:0] pdp_info_in_count;

wire [3:0] wr_count_next_wr_popping = wr_reserving ? pdp_info_in_count : (pdp_info_in_count - 1'd1);
wire [3:0] wr_count_next_no_wr_popping = wr_reserving ? (pdp_info_in_count + 1'd1) : pdp_info_in_count;
wire [3:0] wr_count_next = wr_popping ? wr_count_next_wr_popping : 
                                               wr_count_next_no_wr_popping;

wire wr_count_next_no_wr_popping_is_8 = ( wr_count_next_no_wr_popping == 4'd8 );
wire wr_count_next_is_8 = wr_popping ? 1'b0 :
                                          wr_count_next_no_wr_popping_is_8;
wire [3:0] wr_limit_muxed;
wire [3:0] wr_limit_reg = wr_limit_muxed;
wire       pdp_info_in_busy_next = wr_count_next_is_8 ||
                          (wr_limit_reg != 4'd0 &&
                           wr_count_next >= wr_limit_reg)  ;
always @( posedge nvdla_core_clk_mgated or negedge nvdla_core_rstn ) begin
    if ( !nvdla_core_rstn ) begin
        pdp_info_in_busy_int <=  1'b0;
        pdp_info_in_count <=  4'd0;
    end else begin
	pdp_info_in_busy_int <=  pdp_info_in_busy_next;
	if ( wr_reserving ^ wr_popping ) begin
	    pdp_info_in_count <=  wr_count_next;
        end 
            else if ( !(wr_reserving ^ wr_popping) ) begin
        end else begin
            pdp_info_in_count <=  {4{`x_or_0}};
        end

    end
end

wire       wr_pushing = wr_reserving;

reg  [2:0] pdp_info_in_adr;

always @( posedge nvdla_core_clk_mgated or negedge nvdla_core_rstn ) begin
    if ( !nvdla_core_rstn ) begin
        pdp_info_in_adr <=  3'd0;
    end else begin
        if ( wr_pushing ) begin
	    pdp_info_in_adr <=  pdp_info_in_adr + 1'd1;
        end
    end
end

wire rd_popping;

reg [2:0] pdp_info_out_adr;
wire ram_we = wr_pushing && (pdp_info_in_count > 4'd0 || !rd_popping);
wire [11:0] pdp_info_out_pd_p;

wire [31 : 0] pwrbus_ram_pd;

NV_NVDLA_PDP_cal1d_info_fifo_flopram_rwsa_8x12 ram (
      .clk( nvdla_core_clk_mgated )
    , .pwrbus_ram_pd ( pwrbus_ram_pd )
    , .di        ( pdp_info_in_pd )
    , .we        ( ram_we )
    , .wa        ( pdp_info_in_adr )
    , .ra        ( (pdp_info_in_count == 0) ? 4'd8 : {1'b0,pdp_info_out_adr} )
    , .dout        ( pdp_info_out_pd_p )
    );

wire [2:0] rd_adr_next_popping = pdp_info_out_adr + 1'd1;
always @( posedge nvdla_core_clk_mgated or negedge nvdla_core_rstn ) begin
    if ( !nvdla_core_rstn ) begin
        pdp_info_out_adr <=  3'd0;
    end else begin
        if ( rd_popping ) begin
	    pdp_info_out_adr <=  rd_adr_next_popping;
        end 
            else if ( !rd_popping ) begin
        end else begin
            pdp_info_out_adr <=  {3{`x_or_0}};
        end

    end
end

assign wr_popping = rd_popping;

wire   rd_pushing = wr_pushing;

wire       pdp_info_out_pvld_p;

reg        pdp_info_out_pvld_int;
assign     pdp_info_out_pvld = pdp_info_out_pvld_int;
assign     rd_popping = pdp_info_out_pvld_p && !(pdp_info_out_pvld_int && !pdp_info_out_prdy);

reg  [3:0] pdp_info_out_count_p;
wire [3:0] rd_count_p_next_rd_popping = rd_pushing ? pdp_info_out_count_p : 
                                                                (pdp_info_out_count_p - 1'd1);
wire [3:0] rd_count_p_next_no_rd_popping =  rd_pushing ? (pdp_info_out_count_p + 1'd1) : 
                                                                    pdp_info_out_count_p;
wire [3:0] rd_count_p_next = rd_popping ? rd_count_p_next_rd_popping :
                                                     rd_count_p_next_no_rd_popping; 
assign     pdp_info_out_pvld_p = pdp_info_out_count_p != 0 || rd_pushing;
always @( posedge nvdla_core_clk_mgated or negedge nvdla_core_rstn ) begin
    if ( !nvdla_core_rstn ) begin
        pdp_info_out_count_p <=  4'd0;
    end else begin
        if ( rd_pushing || rd_popping  ) begin
	    pdp_info_out_count_p <=  rd_count_p_next;
        end 
            else if ( !(rd_pushing || rd_popping ) ) begin
        end else begin
            pdp_info_out_count_p <=  {4{`x_or_0}};
        end

    end
end
reg [11:0]  pdp_info_out_pd;
wire        rd_req_next = (pdp_info_out_pvld_p || (pdp_info_out_pvld_int && !pdp_info_out_prdy)) ;

always @( posedge nvdla_core_clk_mgated or negedge nvdla_core_rstn ) begin
    if ( !nvdla_core_rstn ) begin
        pdp_info_out_pvld_int <=  1'b0;
    end else begin
        pdp_info_out_pvld_int <=  rd_req_next;
    end
end
always @( posedge nvdla_core_clk_mgated ) begin
    if ( (rd_popping) ) begin
        pdp_info_out_pd <=  pdp_info_out_pd_p;
    end 
        else if ( !((rd_popping)) ) begin
    end else begin
        pdp_info_out_pd <=  {12{`x_or_0}};
    end

end

`ifndef SYNTH_LEVEL1_COMPILE
`ifndef SYNTHESIS
reg master_clk_gating_disabled;  initial master_clk_gating_disabled = $test$plusargs( "fifogen_disable_master_clk_gating" ) != 0;
`endif
`endif
assign nvdla_core_clk_mgated_enable = ((wr_reserving || wr_pushing || wr_popping || (pdp_info_in_pvld && !pdp_info_in_busy_int) || (pdp_info_in_busy_int != pdp_info_in_busy_next)) || (rd_pushing || rd_popping || (pdp_info_out_pvld_int && pdp_info_out_prdy)) || (wr_pushing))
                               `ifdef FIFOGEN_MASTER_CLK_GATING_DISABLED
                               || 1'b1
                               `endif
			       `ifndef SYNTH_LEVEL1_COMPILE
			       `ifndef SYNTHESIS
                               || master_clk_gating_disabled
			       `endif
			       `endif
                               ;

`ifdef EMU

`ifdef EMU_FIFO_CFG
assign wr_limit_muxed = `EMU_FIFO_CFG.NV_NVDLA_PDP_cal1d_info_fifo_wr_limit_override ? `EMU_FIFO_CFG.NV_NVDLA_PDP_cal1d_info_fifo_wr_limit : 4'd0;
`else
assign wr_limit_muxed = 4'd0;
`endif

`else
`ifdef SYNTH_LEVEL1_COMPILE

assign wr_limit_muxed = 4'd0;
`else
`ifdef SYNTHESIS

assign wr_limit_muxed = 4'd0;

`else  

reg wr_limit_override;
reg [3:0] wr_limit_override_value; 
assign wr_limit_muxed = wr_limit_override ? wr_limit_override_value : 4'd0;
`ifdef NV_ARCHPRO
event reinit;

initial begin
    $display("fifogen reinit initial block %m");
    -> reinit;
end
`endif

`ifdef NV_ARCHPRO
always @( reinit ) begin
`else 
initial begin
`endif
    wr_limit_override = 0;
    wr_limit_override_value = 0;
    if ( $test$plusargs( "NV_NVDLA_PDP_cal1d_info_fifo_wr_limit" ) ) begin
        wr_limit_override = 1;
        $value$plusargs( "NV_NVDLA_PDP_cal1d_info_fifo_wr_limit=%d", wr_limit_override_value);
    end
end

`endif 
`endif
`endif

`ifdef PERFMON_HISTOGRAM 
`ifndef SYNTH_LEVEL1_COMPILE
`ifndef SYNTHESIS
perfmon_histogram perfmon (
      .clk	( nvdla_core_clk ) 
    , .max      ( {28'd0, (wr_limit_reg == 4'd0) ? 4'd8 : wr_limit_reg} )
    , .curr	( {28'd0, pdp_info_in_count} )
    );
`endif
`endif
`endif

`ifdef SPYGLASS
`else

`ifdef FV_ASSERT_ON
`else
`endif

`ifdef ASSERT_ON

`ifdef SPYGLASS
wire disable_assert_plusarg = 1'b0;
`else

`ifdef FV_ASSERT_ON
wire disable_assert_plusarg = 1'b0;
`else
wire disable_assert_plusarg = $test$plusargs("DISABLE_NESS_FLOW_ASSERTIONS");
`endif

`endif
wire assert_enabled = 1'b1 && !disable_assert_plusarg;

`endif

`ifdef FV_ASSERT_ON
`else
`endif

`ifdef ASSERT_ON

`ifndef SYNTH_LEVEL1_COMPILE
`ifndef SYNTHESIS
always @(assert_enabled) begin
    if ( assert_enabled === 1'b0 ) begin
        $display("Asserts are disabled for %m");
    end
end
`endif
`endif

`endif

`endif

`ifdef FIFOGEN_MODULE_SEARCH
NV_BLKBOX_SRC0 dummy_breadcrumb_fifogen_blkbox (.Y());
`endif

endmodule // NV_NVDLA_PDP_cal1d_info_fifo

module NV_NVDLA_PDP_cal1d_info_fifo_flopram_rwsa_8x12 (
      clk
    , pwrbus_ram_pd
    , di
    , we
    , wa
    , ra
    , dout
    );

input  clk;
input [31 : 0] pwrbus_ram_pd;
input  [11:0] di;
input  we;
input  [2:0] wa;
input  [3:0] ra;
output [11:0] dout;

NV_BLKBOX_SINK UJ_BBOX2UNIT_UNUSED_pwrbus_0 (.A(pwrbus_ram_pd[0]));
NV_BLKBOX_SINK UJ_BBOX2UNIT_UNUSED_pwrbus_1 (.A(pwrbus_ram_pd[1]));
NV_BLKBOX_SINK UJ_BBOX2UNIT_UNUSED_pwrbus_2 (.A(pwrbus_ram_pd[2]));
NV_BLKBOX_SINK UJ_BBOX2UNIT_UNUSED_pwrbus_3 (.A(pwrbus_ram_pd[3]));
NV_BLKBOX_SINK UJ_BBOX2UNIT_UNUSED_pwrbus_4 (.A(pwrbus_ram_pd[4]));
NV_BLKBOX_SINK UJ_BBOX2UNIT_UNUSED_pwrbus_5 (.A(pwrbus_ram_pd[5]));
NV_BLKBOX_SINK UJ_BBOX2UNIT_UNUSED_pwrbus_6 (.A(pwrbus_ram_pd[6]));
NV_BLKBOX_SINK UJ_BBOX2UNIT_UNUSED_pwrbus_7 (.A(pwrbus_ram_pd[7]));
NV_BLKBOX_SINK UJ_BBOX2UNIT_UNUSED_pwrbus_8 (.A(pwrbus_ram_pd[8]));
NV_BLKBOX_SINK UJ_BBOX2UNIT_UNUSED_pwrbus_9 (.A(pwrbus_ram_pd[9]));
NV_BLKBOX_SINK UJ_BBOX2UNIT_UNUSED_pwrbus_10 (.A(pwrbus_ram_pd[10]));
NV_BLKBOX_SINK UJ_BBOX2UNIT_UNUSED_pwrbus_11 (.A(pwrbus_ram_pd[11]));
NV_BLKBOX_SINK UJ_BBOX2UNIT_UNUSED_pwrbus_12 (.A(pwrbus_ram_pd[12]));
NV_BLKBOX_SINK UJ_BBOX2UNIT_UNUSED_pwrbus_13 (.A(pwrbus_ram_pd[13]));
NV_BLKBOX_SINK UJ_BBOX2UNIT_UNUSED_pwrbus_14 (.A(pwrbus_ram_pd[14]));
NV_BLKBOX_SINK UJ_BBOX2UNIT_UNUSED_pwrbus_15 (.A(pwrbus_ram_pd[15]));
NV_BLKBOX_SINK UJ_BBOX2UNIT_UNUSED_pwrbus_16 (.A(pwrbus_ram_pd[16]));
NV_BLKBOX_SINK UJ_BBOX2UNIT_UNUSED_pwrbus_17 (.A(pwrbus_ram_pd[17]));
NV_BLKBOX_SINK UJ_BBOX2UNIT_UNUSED_pwrbus_18 (.A(pwrbus_ram_pd[18]));
NV_BLKBOX_SINK UJ_BBOX2UNIT_UNUSED_pwrbus_19 (.A(pwrbus_ram_pd[19]));
NV_BLKBOX_SINK UJ_BBOX2UNIT_UNUSED_pwrbus_20 (.A(pwrbus_ram_pd[20]));
NV_BLKBOX_SINK UJ_BBOX2UNIT_UNUSED_pwrbus_21 (.A(pwrbus_ram_pd[21]));
NV_BLKBOX_SINK UJ_BBOX2UNIT_UNUSED_pwrbus_22 (.A(pwrbus_ram_pd[22]));
NV_BLKBOX_SINK UJ_BBOX2UNIT_UNUSED_pwrbus_23 (.A(pwrbus_ram_pd[23]));
NV_BLKBOX_SINK UJ_BBOX2UNIT_UNUSED_pwrbus_24 (.A(pwrbus_ram_pd[24]));
NV_BLKBOX_SINK UJ_BBOX2UNIT_UNUSED_pwrbus_25 (.A(pwrbus_ram_pd[25]));
NV_BLKBOX_SINK UJ_BBOX2UNIT_UNUSED_pwrbus_26 (.A(pwrbus_ram_pd[26]));
NV_BLKBOX_SINK UJ_BBOX2UNIT_UNUSED_pwrbus_27 (.A(pwrbus_ram_pd[27]));
NV_BLKBOX_SINK UJ_BBOX2UNIT_UNUSED_pwrbus_28 (.A(pwrbus_ram_pd[28]));
NV_BLKBOX_SINK UJ_BBOX2UNIT_UNUSED_pwrbus_29 (.A(pwrbus_ram_pd[29]));
NV_BLKBOX_SINK UJ_BBOX2UNIT_UNUSED_pwrbus_30 (.A(pwrbus_ram_pd[30]));
NV_BLKBOX_SINK UJ_BBOX2UNIT_UNUSED_pwrbus_31 (.A(pwrbus_ram_pd[31]));

`ifdef EMU

wire [11:0] dout_p;

reg [2:0] Wa0_vmw;
reg we0_vmw;
reg [11:0] Di0_vmw;

always @( posedge clk ) begin
    Wa0_vmw <=  wa;
    we0_vmw <=  we;
    Di0_vmw <=  di;
end

vmw_NV_NVDLA_PDP_cal1d_info_fifo_flopram_rwsa_8x12 emu_ram (
     .Wa0( Wa0_vmw ) 
   , .we0( we0_vmw ) 
   , .Di0( Di0_vmw )
   , .Ra0( ra[2:0] ) 
   , .Do0( dout_p )
   );

assign dout = (ra == 8) ? di : dout_p;

`else

reg [11:0] ram_ff0;
reg [11:0] ram_ff1;
reg [11:0] ram_ff2;
reg [11:0] ram_ff3;
reg [11:0] ram_ff4;
reg [11:0] ram_ff5;
reg [11:0] ram_ff6;
reg [11:0] ram_ff7;

always @( posedge clk ) begin
    if ( we && wa == 3'd0 ) begin
	ram_ff0 <=  di;
    end
    if ( we && wa == 3'd1 ) begin
	ram_ff1 <=  di;
    end
    if ( we && wa == 3'd2 ) begin
	ram_ff2 <=  di;
    end
    if ( we && wa == 3'd3 ) begin
	ram_ff3 <=  di;
    end
    if ( we && wa == 3'd4 ) begin
	ram_ff4 <=  di;
    end
    if ( we && wa == 3'd5 ) begin
	ram_ff5 <=  di;
    end
    if ( we && wa == 3'd6 ) begin
	ram_ff6 <=  di;
    end
    if ( we && wa == 3'd7 ) begin
	ram_ff7 <=  di;
    end
end

reg [11:0] dout;

always @(*) begin
    case( ra ) 
    4'd0:       dout = ram_ff0;
    4'd1:       dout = ram_ff1;
    4'd2:       dout = ram_ff2;
    4'd3:       dout = ram_ff3;
    4'd4:       dout = ram_ff4;
    4'd5:       dout = ram_ff5;
    4'd6:       dout = ram_ff6;
    4'd7:       dout = ram_ff7;
    4'd8:       dout = di;
    default:    dout = {12{`x_or_0}};
    endcase
end

`endif

endmodule // NV_NVDLA_PDP_cal1d_info_fifo_flopram_rwsa_8x12

`ifdef EMU

module vmw_NV_NVDLA_PDP_cal1d_info_fifo_flopram_rwsa_8x12 (
   Wa0, we0, Di0,
   Ra0, Do0
   );

input  [2:0] Wa0;
input            we0;
input  [11:0] Di0;
input  [2:0] Ra0;
output [11:0] Do0;

`ifdef SPYGLASS_FLOPRAM

assign Do0 = 12'd0;
wire dummy = 1'b0 | (|Wa0) | (|we0) | (|Di0) | (|Ra0);

`endif

`ifndef SYNTH_LEVEL1_COMPILE
`ifndef SYNTHESIS
reg [11:0] mem[7:0];

`ifdef EMU_EXPAND_FLOPRAM_MEM
wire [11:0] Q0 = mem[0];
wire [11:0] Q1 = mem[1];
wire [11:0] Q2 = mem[2];
wire [11:0] Q3 = mem[3];
wire [11:0] Q4 = mem[4];
wire [11:0] Q5 = mem[5];
wire [11:0] Q6 = mem[6];
wire [11:0] Q7 = mem[7];
`endif

always @(*) begin
  if ( we0 == 1'b1 ) begin
    #0.1;
    mem[Wa0] = Di0;
  end
end

assign Do0 = mem[Ra0];
`endif
`endif

endmodule // vmw_NV_NVDLA_PDP_cal1d_info_fifo_flopram_rwsa_8x12

`endif

