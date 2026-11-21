// Copyright © 2019-2023
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

`include "VX_define.vh"

//
// TCU uop expander (alternate gold: dynamic shift-mask NRC decoder).
//
module VX_tcu_uops import VX_tcu_pkg::*, VX_gpu_pkg::*; (
    input clk,
    input reset,

    input  ibuffer_t ibuf_in,
    output ibuffer_t ibuf_out,

    input wire start,
    input wire advance,
    input wire [UOP_CTR_W-1:0] uop_idx,
    output wire [UOP_CTR_W-1:0] uop_count
);
`ifdef VX_CFG_TCU_SPARSE_ENABLE
    localparam MAX_UOPS = SYM_SPARSE ? TCU_UOPS : (TCU_UOPS / 2);
`else
    localparam MAX_UOPS = TCU_UOPS;
`endif

    localparam LG_N = $clog2(TCU_N_STEPS);
    localparam LG_M = $clog2(TCU_M_STEPS);
    localparam LG_K = $clog2(TCU_K_STEPS);

    localparam IDX_BITS = LG_N + LG_M + LG_K;
`ifdef VX_CFG_TCU_WGMMA_ENABLE
  `ifdef VX_CFG_TCU_SPARSE_ENABLE
    localparam TCU_WG_K_STEPS_SP = (TCU_WG_K_STEPS > 1) ? (TCU_WG_K_STEPS / 2) : 1;
    localparam MAX_WG_UOPS_SP = TCU_WG_M_STEPS * TCU_WG_N_STEPS * TCU_WG_K_STEPS_SP;
  `ifdef VX_CFG_TCU_FEDP2K
    localparam MAX_WG_UOPS_DENSE = TCU_WG_UOPS + 1;
  `else
    localparam MAX_WG_UOPS_DENSE = TCU_WG_UOPS;
  `endif
    localparam CTR_W_MAX_WMMA = MAX_UOPS > MAX_WG_UOPS_DENSE ? MAX_UOPS : MAX_WG_UOPS_DENSE;
    localparam CTR_W_BASE = $clog2(CTR_W_MAX_WMMA > MAX_WG_UOPS_SP ? CTR_W_MAX_WMMA : MAX_WG_UOPS_SP);
  `else
  `ifdef VX_CFG_TCU_FEDP2K
    localparam MAX_WG_UOPS_DENSE = TCU_WG_UOPS + 1;
  `else
    localparam MAX_WG_UOPS_DENSE = TCU_WG_UOPS;
  `endif
    localparam CTR_W_BASE = $clog2(MAX_UOPS > MAX_WG_UOPS_DENSE ? MAX_UOPS : MAX_WG_UOPS_DENSE);
  `endif
`else
    localparam CTR_W_BASE = $clog2(MAX_UOPS);
`endif
    localparam CTR_W = (CTR_W_BASE > IDX_BITS) ? CTR_W_BASE : IDX_BITS;
    `STATIC_ASSERT (CTR_W <= UOP_CTR_W, ("invalid parameter"))

`ifdef VX_CFG_TCU_SPARSE_ENABLE
    localparam LG_A_SB = $clog2(TCU_A_SUB_BLOCKS);
`endif
    localparam LG_B_SB = $clog2(TCU_B_SUB_BLOCKS);

    `UNUSED_VAR ({clk, reset, start, advance, uop_idx})

    wire [`UP(CTR_W)-1:0] ctr = `UP(CTR_W)'(uop_idx);

`ifdef VX_CFG_TCU_WGMMA_ENABLE
    wire is_wgmma = (ibuf_in.op_type == INST_TCU_WGMMA)
              `ifdef VX_CFG_TCU_SPARSE_ENABLE
                 || (ibuf_in.op_type == INST_TCU_WGMMA_SP)
              `endif
                 ;
`ifdef VX_CFG_TCU_SPARSE_ENABLE
    wire wg_is_sparse = (ibuf_in.op_type == INST_TCU_WGMMA_SP);
`endif
    wire wg_a_from_smem = ibuf_in.op_args.tcu.a_from_smem;
    wire wg_needs_setup =
        `ifdef VX_CFG_TCU_FEDP2K
            !wg_a_from_smem
        `ifdef VX_CFG_TCU_SPARSE_ENABLE
            && !wg_is_sparse
        `endif
        `else
            1'b0
        `endif
            ;

    localparam LG_M_WG     = $clog2(TCU_WG_M_STEPS);
    localparam LG_K_WG     = $clog2(TCU_WG_K_STEPS);
    localparam LG_N_WG_MAX = $clog2(TCU_WG_N_STEPS);

    // Shift-and-mask NRC decoder (cd_nregs: 0->shift 2, 1->shift 3, 2/3->shift 4)
    wire [2:0] wg_n_lg = (ibuf_in.op_args.tcu.cd_nregs == 2'd0) ? 3'd2 :
                         (ibuf_in.op_args.tcu.cd_nregs == 2'd1) ? 3'd3 : 3'd4;
    wire [6:0] wg_mn_cnt = (7'd1 << (wg_n_lg + 3'd1));
`ifdef VX_CFG_TCU_SPARSE_ENABLE
    wire [6:0] wg_base_cnt = wg_is_sparse
        ? ((TCU_WG_K_STEPS_SP == 2) ? (wg_mn_cnt << 1) : wg_mn_cnt)
        : ((TCU_WG_K_STEPS    == 2) ? (wg_mn_cnt << 1) : wg_mn_cnt);
`else
    wire [6:0] wg_base_cnt = (TCU_WG_K_STEPS == 2) ? (wg_mn_cnt << 1) : wg_mn_cnt;
`endif
    wire [6:0] wg_tot_cnt  = wg_base_cnt + {6'd0, wg_needs_setup};
    wire [UOP_CTR_W-1:0] wg_uop_cnt  = UOP_CTR_W'(wg_tot_cnt);
    wire [`UP(CTR_W)-1:0] wg_last_idx = `UP(CTR_W)'(wg_base_cnt - {6'd0, ~wg_needs_setup});

    wire is_wg_setup_uop = wg_needs_setup && (ctr == '0);
    wire [`UP(CTR_W)-1:0] wg_idx_ctr = wg_needs_setup
        ? (is_wg_setup_uop ? '0 : (ctr - `UP(CTR_W)'(1)))
        : ctr;
    wire is_wg_first_compute_uop = !is_wg_setup_uop && (wg_idx_ctr == '0);
    wire [`UP(LG_M_WG)-1:0] wg_m_index = wg_idx_ctr[0 +: `UP(LG_M_WG)];

    wire [`UP(CTR_W)-1:0] wg_nk_shifted = wg_idx_ctr >> LG_M_WG;
    wire [`UP(LG_N_WG_MAX)-1:0] wg_n_mask =
        (ibuf_in.op_args.tcu.cd_nregs == 2'd0) ? `UP(LG_N_WG_MAX)'(4'b0011) :
        (ibuf_in.op_args.tcu.cd_nregs == 2'd1) ? `UP(LG_N_WG_MAX)'(4'b0111) :
                                                 `UP(LG_N_WG_MAX)'(4'b1111);
`ifdef VX_CFG_TCU_SPARSE_ENABLE
    wire [`UP(LG_N_WG_MAX)-1:0] wg_n_index = wg_is_sparse
        ? `UP(LG_N_WG_MAX)'(wg_nk_shifted)
        : (`UP(LG_N_WG_MAX)'(wg_nk_shifted) & wg_n_mask);
    wire [`UP(LG_K_WG)-1:0] wg_k_index = wg_is_sparse
        ? '0
        : `UP(LG_K_WG)'(wg_nk_shifted >> wg_n_lg);
`else
    wire [`UP(LG_N_WG_MAX)-1:0] wg_n_index = `UP(LG_N_WG_MAX)'(wg_nk_shifted) & wg_n_mask;
    wire [`UP(LG_K_WG)-1:0]     wg_k_index = `UP(LG_K_WG)'(wg_nk_shifted >> wg_n_lg);
`endif

    wire [4:0] wg_rs3_off = (5'(wg_n_index) << LG_M_WG) | 5'(wg_m_index);
    localparam [4:0] wg_ra_base = TCU_WG_RA;

    wire [`UP(CTR_W)-1:0] wg_rs1_reg_off_dense = (`UP(CTR_W)'(wg_m_index) << 1) | `UP(CTR_W)'(wg_k_index);
`ifdef VX_CFG_TCU_SPARSE_ENABLE
    wire [`UP(CTR_W)-1:0] wg_rs1_reg_off = (wg_is_sparse && !wg_a_from_smem)
        ? `UP(CTR_W)'(wg_m_index)
        : wg_rs1_reg_off_dense;
`else
    wire [`UP(CTR_W)-1:0] wg_rs1_reg_off = wg_rs1_reg_off_dense;
`endif
    if (`UP(CTR_W) > 5) begin : g_unused_wg_rs1_off
        `UNUSED_VAR (wg_rs1_reg_off[`UP(CTR_W)-1 : 5])
    end
`endif
`ifdef VX_CFG_TCU_SPARSE_ENABLE
    wire is_sparse = (ibuf_in.op_type == INST_TCU_WMMA_SP)
              `ifdef VX_CFG_TCU_WGMMA_ENABLE
                  || (ibuf_in.op_type == INST_TCU_WGMMA_SP)
              `endif
                  ;
`endif

    assign uop_count =
`ifdef VX_CFG_TCU_WGMMA_ENABLE
        is_wgmma ? wg_uop_cnt :
`endif
`ifdef VX_CFG_TCU_SPARSE_ENABLE
        is_sparse ? (SYM_SPARSE ? UOP_CTR_W'(TCU_UOPS) : UOP_CTR_W'(TCU_UOPS / 2)) :
`endif
        UOP_CTR_W'(TCU_UOPS);

    wire [`UP(CTR_W)-1:0] eff_ctr = ctr;
`ifdef VX_CFG_TCU_SPARSE_ENABLE
    logic [`VX_CFG_NUM_THREADS-1:0] sym_mask_lo;
    if (SYM_SPARSE) begin : g_sym_mask
        for (genvar t = 0; t < `VX_CFG_NUM_THREADS; ++t) begin : g_bit
            assign sym_mask_lo[t] = ((t % TCU_TC_N) < (TCU_TC_N / 2)) ? 1'b1 : 1'b0;
        end
    end else begin : g_sym_mask
        assign sym_mask_lo = '0;
    end
`endif

    logic [`UP(LG_N)-1:0] n_index;
    logic [`UP(LG_M)-1:0] m_index;
    logic [`UP(LG_K)-1:0] k_index;

    if (LG_N != 0) begin : g_n_idx
        assign n_index = eff_ctr[0 +: LG_N];
    end else begin : g_n_idx0
        assign n_index = 0;
    end

    if (LG_M != 0) begin : g_m_idx
        assign m_index = eff_ctr[LG_N +: LG_M];
    end else begin : g_m_idx0
        assign m_index = 0;
    end

    if (LG_K != 0) begin : g_k_idx
        assign k_index = eff_ctr[LG_N + LG_M +: LG_K];
    end else begin : g_k_idx0
        assign k_index = 0;
    end

    logic [`UP(CTR_W)-1:0] rs1_offset;
    logic [`UP(CTR_W)-1:0] rs2_offset;
    logic [`UP(CTR_W)-1:0] rs3_offset;

    wire [`UP(CTR_W)-1:0] ra_off, rb_off, rc_off;
    if (LG_B_SB == 0) begin : g_bcfree_bsub1
        assign ra_off = `UP(CTR_W)'({m_index[0], ~m_index[`UP(LG_M)-1], k_index[0]});
        assign rb_off = `UP(CTR_W)'({n_index[0] ^ k_index[0], ~k_index[0]});
        assign rc_off = `UP(CTR_W)'({m_index[0], ~m_index[`UP(LG_M)-1], ~(m_index[`UP(LG_M)-1] ^ n_index[0])});
    end else begin : g_bcfree_bsub2
        assign ra_off = `UP(CTR_W)'({k_index[0], ~m_index[0], m_index[0] ^ k_index[`UP(LG_K)-1]});
        assign rb_off = `UP(CTR_W)'({k_index[0], k_index[`UP(LG_K)-1] ^ n_index[`UP(LG_N)-1], ~n_index[`UP(LG_N)-1]});
        assign rc_off = `UP(CTR_W)'({n_index[0], ~m_index[0], n_index[`UP(LG_N)-1]});
    end

`ifdef VX_CFG_TCU_SPARSE_ENABLE
    if (SYM_SPARSE) begin : g_sym_off
        wire [`UP(CTR_W)-1:0] n_sp = `UP(CTR_W)'(eff_ctr[0 +: (LG_N + LG_K)]);
        wire [`UP(CTR_W)-1:0] m_sp = `UP(CTR_W)'(eff_ctr[(LG_N + LG_K) +: LG_M]);
        assign rs1_offset = is_sparse ? `UP(CTR_W)'(m_sp) : ra_off;
        assign rs2_offset = is_sparse ? `UP(CTR_W)'(n_sp) : rb_off;
        assign rs3_offset = is_sparse ? (`UP(CTR_W)'(eff_ctr) >> 1) : rc_off;
    end else begin : g_def_off
        wire [`UP(CTR_W)-1:0] rb_off_sp = `UP(CTR_W)'({n_index[`UP(LG_N)-1], ~(n_index[0] ^ k_index[0]), ~k_index[0]});
        wire [`UP(CTR_W)-1:0] rc_off_sp = `UP(CTR_W)'({n_index[`UP(LG_N)-1], m_index[0], ~(m_index[0] ^ n_index[0])});
        assign rs1_offset = is_sparse
            ? ((`UP(CTR_W)'(m_index) >> LG_A_SB) << (LG_K / 2)) | `UP(CTR_W)'(k_index)
            : ra_off;
        assign rs2_offset = is_sparse ? rb_off_sp : rb_off;
        assign rs3_offset = is_sparse ? rc_off_sp : rc_off;
    end
`else
    assign rs1_offset = ra_off;
    assign rs2_offset = rb_off;
    assign rs3_offset = rc_off;
`endif
    if (`UP(CTR_W) > LG_N+LG_M+LG_K) begin : g_unused_upper_eff_ctr
        `UNUSED_VAR (eff_ctr[`UP(CTR_W)-1 : LG_N+LG_M+LG_K])
    end
    if (`UP(CTR_W) > 5) begin : g_unused_upper_offsets
        `UNUSED_VAR (rs1_offset[`UP(CTR_W)-1 : 5])
        `UNUSED_VAR (rs2_offset[`UP(CTR_W)-1 : 5])
        `UNUSED_VAR (rs3_offset[`UP(CTR_W)-1 : 5])
    end

    wire [4:0] rs1 = TCU_RA + 5'(rs1_offset);
    wire [4:0] rs2 = TCU_RB + 5'(rs2_offset);
    wire [4:0] rs3 = TCU_RC + 5'(rs3_offset);

`ifdef VX_CFG_TCU_SPARSE_ENABLE
    logic [3:0] n_sp_s;
    logic [3:0] m_sp_s;
`endif

    ibuffer_t ibuf_r;
    always_comb begin
        ibuf_r = ibuf_in;
    `ifdef VX_CFG_TCU_SPARSE_ENABLE
        n_sp_s = '0;
        m_sp_s = '0;
    `endif
    `ifdef VX_CFG_TCU_WGMMA_ENABLE
        if (is_wgmma) begin
            ibuf_r.op_args.tcu.step_m = is_wg_setup_uop ? 4'd0 : 4'(wg_m_index);
            ibuf_r.op_args.tcu.step_n = is_wg_setup_uop ? 4'd0 : 4'(wg_n_index);
            ibuf_r.op_args.tcu.step_k = is_wg_setup_uop ? 4'd0 : 4'(wg_k_index);
            ibuf_r.wb  = !is_wg_setup_uop;
            ibuf_r.rd  = make_reg_num(REG_TYPE_F, TCU_WG_RC + wg_rs3_off);
            ibuf_r.rs3 = make_reg_num(REG_TYPE_F, TCU_WG_RC + wg_rs3_off);
            ibuf_r.used_rs[2] = !is_wg_setup_uop;
            if (is_wg_setup_uop) begin
                ibuf_r.used_rs[0] = 1'b0;
            end else if (is_wg_first_compute_uop && wg_a_from_smem) begin
                ibuf_r.rs1 = make_reg_num(REG_TYPE_I, 5'd10);
                ibuf_r.used_rs[0] = 1'b1;
            end else if (wg_a_from_smem) begin
                ibuf_r.rs1 = make_reg_num(REG_TYPE_I, 5'd10);
                ibuf_r.used_rs[0] = 1'b0;
            end else begin
                ibuf_r.rs1 = make_reg_num(REG_TYPE_F, wg_ra_base + 5'(wg_rs1_reg_off));
                ibuf_r.used_rs[0] = 1'b1;
            end
            ibuf_r.rs2 = make_reg_num(REG_TYPE_I, 5'd11);
            if (is_wg_setup_uop || (!wg_needs_setup && is_wg_first_compute_uop)) begin
                ibuf_r.used_rs[1] = 1'b1;
            end else if (wg_needs_setup) begin
                ibuf_r.rs2 = make_reg_num(REG_TYPE_F, wg_ra_base + 5'(wg_rs1_reg_off) + 5'd1);
                ibuf_r.used_rs[1] = 1'b1;
            end else begin
                ibuf_r.used_rs[1] = 1'b0;
            end
        end else
    `endif
        begin
    `ifdef VX_CFG_TCU_SPARSE_ENABLE
        if (SYM_SPARSE) begin
            ibuf_r.tmask = is_sparse
                ? (eff_ctr[0] ? ibuf_in.tmask & ~sym_mask_lo : ibuf_in.tmask &  sym_mask_lo)
                : ibuf_in.tmask;
            n_sp_s = 4'(eff_ctr[0 +: (LG_N + LG_K)]);
            m_sp_s = 4'(eff_ctr[(LG_N + LG_K) +: LG_M]);
        end

        ibuf_r.op_args.tcu.step_m = SYM_SPARSE && is_sparse ? 4'(m_sp_s) : 4'(m_index);
        ibuf_r.op_args.tcu.step_n = SYM_SPARSE && is_sparse ? 4'(n_sp_s >> LG_K) : 4'(n_index);
        ibuf_r.op_args.tcu.step_k = SYM_SPARSE && is_sparse ? 4'(0)      : 4'(k_index);
        ibuf_r.wb = 1'b1;
        ibuf_r.rd = make_reg_num(REG_TYPE_F, rs3);
        ibuf_r.rs1 = make_reg_num(REG_TYPE_F, rs1);
        ibuf_r.rs2 = make_reg_num(REG_TYPE_F, rs2);
        ibuf_r.rs3 = make_reg_num(REG_TYPE_F, rs3);
        ibuf_r.used_rs[0] = 1'b1;
        ibuf_r.used_rs[1] = 1'b1;
        ibuf_r.used_rs[2] = 1'b1;
    `else
        ibuf_r.op_args.tcu.step_m = 4'(m_index);
        ibuf_r.op_args.tcu.step_n = 4'(n_index);
        ibuf_r.op_args.tcu.step_k = 4'(k_index);
        ibuf_r.wb  = 1'b1;
        ibuf_r.rd  = make_reg_num(REG_TYPE_F, rs3);
        ibuf_r.rs1 = make_reg_num(REG_TYPE_F, rs1);
        ibuf_r.rs2 = make_reg_num(REG_TYPE_F, rs2);
        ibuf_r.rs3 = make_reg_num(REG_TYPE_F, rs3);
        ibuf_r.used_rs[0] = 1'b1;
        ibuf_r.used_rs[1] = 1'b1;
        ibuf_r.used_rs[2] = 1'b1;
    `endif
        end
    `ifdef VX_CFG_TCU_WGMMA_ENABLE
        if (is_wgmma) begin
            automatic logic ctr_hi_zero = (uop_idx[UOP_CTR_W-1:`UP(CTR_W)] == '0);
            automatic logic is_wg_last  = ctr_hi_zero && (ctr == wg_last_idx);
            ibuf_r.fu_lock   = ctr_hi_zero && (ctr == '0);
            ibuf_r.fu_unlock = is_wg_last;
            ibuf_r.op_args.tcu.is_first_uop = is_wg_first_compute_uop;
            ibuf_r.op_args.tcu.is_last_uop  = !is_wg_setup_uop && is_wg_last;
        end
    `endif
    end

    assign ibuf_out = ibuf_r;

endmodule
