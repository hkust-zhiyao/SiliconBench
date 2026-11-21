// ================================================================
// NVDLA Open Source Project
// 
// Copyright(c) 2016 - 2017 NVIDIA Corporation.  Licensed under the
// NVDLA Open Hardware License; Check "LICENSE" which comes with 
// this distribution for more information.
// ================================================================

// File Name: NV_NVDLA_PDP_nan.v

module NV_NVDLA_PDP_nan (
   nvdla_core_clk
  ,nvdla_core_rstn
  ,dp2reg_done
  ,nan_preproc_prdy
  ,pdp_rdma2dp_pd
  ,pdp_rdma2dp_valid
  ,reg2dp_flying_mode
  ,reg2dp_input_data
  ,reg2dp_nan_to_zero
  ,reg2dp_op_en
  ,dp2reg_inf_input_num
  ,dp2reg_nan_input_num
  ,nan_preproc_pd
  ,nan_preproc_pvld
  ,pdp_rdma2dp_ready
  );
input         nvdla_core_clk;
input         nvdla_core_rstn;
input         dp2reg_done;
input         nan_preproc_prdy;
input  [75:0] pdp_rdma2dp_pd;
input         pdp_rdma2dp_valid;
input         reg2dp_flying_mode;
input   [1:0] reg2dp_input_data;
input         reg2dp_nan_to_zero;
input         reg2dp_op_en;
output reg [31:0] dp2reg_inf_input_num;
output reg [31:0] dp2reg_nan_input_num;
output [75:0] nan_preproc_pd;
output        nan_preproc_pvld;
output        pdp_rdma2dp_ready;

wire is_fp16    = (reg2dp_input_data == 2'h2);
wire is_offline = (reg2dp_flying_mode == 1'b1);
wire flush_nan  = reg2dp_nan_to_zero;

reg op_en_q;
reg rdma_gate_open;
reg stage_vld;
reg [75:0] stage_pd;
reg [2:0]  stage_nan_add;
reg [2:0]  stage_inf_add;
reg        stage_cube_end;

wire stage_accept = (~stage_vld) | nan_preproc_prdy;
assign pdp_rdma2dp_ready = stage_accept & rdma_gate_open;
wire in_fire = pdp_rdma2dp_valid & pdp_rdma2dp_ready;
wire out_fire = stage_vld & nan_preproc_prdy;

always @(posedge nvdla_core_clk or negedge nvdla_core_rstn) begin
  if (!nvdla_core_rstn) begin
    op_en_q        <= 1'b0;
    rdma_gate_open <= 1'b0;
  end else begin
    op_en_q <= reg2dp_op_en;
    if (in_fire && pdp_rdma2dp_pd[75] && pdp_rdma2dp_pd[71] && is_offline) begin
      rdma_gate_open <= 1'b0;
    end else if (reg2dp_op_en && !op_en_q) begin
      rdma_gate_open <= is_offline;
    end
  end
end

wire [3:0] lane_nan;
wire [3:0] lane_inf;
wire [63:0] sanitized_data;

genvar g;
generate
  for (g = 0; g < 4; g = g + 1) begin : g_fp16_cls
    wire [15:0] raw16 = pdp_rdma2dp_pd[g*16 +: 16];
    wire exp_max = (&raw16[14:10]);
    wire mant_nz = (|raw16[9:0]);
    assign lane_nan[g] = is_fp16 & exp_max & mant_nz;
    assign lane_inf[g] = is_fp16 & exp_max & (~mant_nz);
    assign sanitized_data[g*16 +: 16] = (lane_nan[g] & flush_nan) ? 16'h0000 : raw16;
  end
endgenerate

wire [2:0] cur_nan_cnt = {2'b0, lane_nan[0]} + {2'b0, lane_nan[1]} + {2'b0, lane_nan[2]} + {2'b0, lane_nan[3]};
wire [2:0] cur_inf_cnt = {2'b0, lane_inf[0]} + {2'b0, lane_inf[1]} + {2'b0, lane_inf[2]} + {2'b0, lane_inf[3]};

always @(posedge nvdla_core_clk or negedge nvdla_core_rstn) begin
  if (!nvdla_core_rstn) begin
    stage_vld      <= 1'b0;
    stage_pd       <= 76'd0;
    stage_nan_add  <= 3'd0;
    stage_inf_add  <= 3'd0;
    stage_cube_end <= 1'b0;
  end else begin
    if (in_fire) begin
      stage_vld      <= 1'b1;
      stage_pd       <= {pdp_rdma2dp_pd[75:64], sanitized_data};
      stage_nan_add  <= cur_nan_cnt;
      stage_inf_add  <= cur_inf_cnt;
      stage_cube_end <= pdp_rdma2dp_pd[75] & pdp_rdma2dp_pd[71];
    end else if (nan_preproc_prdy) begin
      stage_vld <= 1'b0;
    end
  end
end

assign nan_preproc_pvld = stage_vld;
assign nan_preproc_pd   = stage_pd;

reg [31:0] acc_nan;
reg [31:0] acc_inf;
reg [31:0] bank_nan [0:1];
reg [31:0] bank_inf [0:1];
reg        wr_bank;
reg        rd_bank;

wire [31:0] next_acc_nan = acc_nan + {29'd0, stage_nan_add};
wire [31:0] next_acc_inf = acc_inf + {29'd0, stage_inf_add};

always @(posedge nvdla_core_clk or negedge nvdla_core_rstn) begin
  if (!nvdla_core_rstn) begin
    acc_nan     <= 32'd0;
    acc_inf     <= 32'd0;
    bank_nan[0] <= 32'd0;
    bank_nan[1] <= 32'd0;
    bank_inf[0] <= 32'd0;
    bank_inf[1] <= 32'd0;
    wr_bank     <= 1'b0;
  end else if (out_fire) begin
    if (stage_cube_end) begin
      bank_nan[wr_bank] <= next_acc_nan;
      bank_inf[wr_bank] <= next_acc_inf;
      wr_bank           <= ~wr_bank;
      acc_nan           <= 32'd0;
      acc_inf           <= 32'd0;
    end else begin
      acc_nan <= next_acc_nan;
      acc_inf <= next_acc_inf;
    end
  end
end

always @(posedge nvdla_core_clk or negedge nvdla_core_rstn) begin
  if (!nvdla_core_rstn) begin
    rd_bank              <= 1'b0;
    dp2reg_nan_input_num <= 32'd0;
    dp2reg_inf_input_num <= 32'd0;
  end else if (dp2reg_done) begin
    dp2reg_nan_input_num <= bank_nan[rd_bank];
    dp2reg_inf_input_num <= bank_inf[rd_bank];
    rd_bank              <= ~rd_bank;
  end
end

endmodule // NV_NVDLA_PDP_nan
