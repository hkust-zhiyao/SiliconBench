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

`ifdef VX_CFG_TCU_WGMMA_ENABLE

//
// TB-shared B buffer (alternate gold: Beat-0 hold-register coalescer + atomic K-major row commit).
//
module VX_tcu_bbuf import VX_gpu_pkg::*, VX_tcu_pkg::*; #(
    parameter `STRING INSTANCE_ID     = "",
    parameter         NUM_BANKS       = 4,
    parameter         BANK_ADDR_WIDTH = 12
) (
    input  wire clk,
    input  wire reset,

`ifdef PERF_ENABLE
    output wire [PERF_CTR_BITS-1:0] bbuf_stalls,
    output wire [PERF_CTR_BITS-1:0] bbuf_cache_hits,
    output wire [PERF_CTR_BITS-1:0] lmem_reads,
`endif

    input  wire                     req_valid,
    input  wire                     req_setup,
    input  wire                     req_is_first_uop,
    input  wire                     req_is_sparse,
    input  wire [3:0]               req_step_m,
    input  wire [3:0]               req_step_k,
    input  wire [3:0]               req_step_n,
    input  wire [1:0]               req_cd_nregs,
    input  wire [NCTA_WIDTH-1:0]    req_cta_id,
    input  wire [`VX_CFG_XLEN-1:0]  req_desc_b,
    input  wire [UUID_WIDTH-1:0]    req_uuid,

    VX_mem_bus_if.master            tcu_lmem_if,

    output wire                     bbuf_ready,
    output wire [TCU_WG_RS2_WIDTH-1:0][`VX_CFG_XLEN-1:0] bbuf_rs2_data
);
    `UNUSED_SPARAM (INSTANCE_ID)

    localparam BANK_SEL_BITS       = $clog2(NUM_BANKS);
    localparam WORD_SIZE_LOG2      = $clog2(`VX_CFG_XLEN / 8);
    localparam B_BLOCK_WORDS       = TCU_WG_FEDP_K * TCU_TC_N;
    localparam B_BLOCK_WORDS_SP    = TCU_TC_K * TCU_TC_N;
    localparam B_BUF_WORDS         = NUM_BANKS;
    localparam LG_B_SUB_BLOCKS     = $clog2(TCU_WG_B_SUB_BLOCKS);
    localparam XLEN_RATIO          = `VX_CFG_XLEN / 32;
    localparam LG_XLEN_RATIO       = (XLEN_RATIO > 1) ? $clog2(XLEN_RATIO) : 0;

    localparam LOGICAL_ROWS_PER_BLK = TCU_WG_B_BLOCK_SIZE_SP / NUM_BANKS;
    `STATIC_ASSERT (LOGICAL_ROWS_PER_BLK == 1 || LOGICAL_ROWS_PER_BLK == 2,
                    ("flat sparse-B supports 1 or 2 logical bank-rows per block"))
    localparam bit SPARSE_TWO_SLOT  = (LOGICAL_ROWS_PER_BLK == 2);
    localparam bit SPARSE_TWO_FETCH = SPARSE_TWO_SLOT && (XLEN_RATIO == 1);

    `STATIC_ASSERT (B_BLOCK_WORDS * TCU_WG_B_SUB_BLOCKS == NUM_BANKS,
                    ("VX_tcu_bbuf assumes one bank-row per B_SUB_BLOCKS blocks"))

    localparam LDM_W               = 14;
    localparam BANK_ROW_WORDS      = NUM_BANKS * XLEN_RATIO;
    localparam BANK_ROW_WORDS_LOG2 = $clog2(BANK_ROW_WORDS);
    localparam LG_B_BLOCK_WORDS    = $clog2(B_BLOCK_WORDS);
    localparam KM_CTR_W            = $clog2(TCU_TC_N + 1);
    localparam KM_OFF_W            = LDM_W + 4 + 4;
    localparam KM_SLICE_MAX        = (2 * TCU_TC_K > TCU_WG_FEDP_K) ? (2 * TCU_TC_K) : TCU_WG_FEDP_K;
    localparam HOLD_WORDS          = (KM_SLICE_MAX > 1) ? (KM_SLICE_MAX - 1) : 1;

    logic [4:0] block_index;
    always_comb begin
        case (req_cd_nregs)
            2'd0:    block_index = {2'b0, req_step_k[0], req_step_n[1:0]};
            2'd1:    block_index = {1'b0, req_step_k[0], req_step_n[2:0]};
            default: block_index = {req_step_k[0], req_step_n[3:0]};
        endcase
    end
    if (4 > 1) begin : g_step_k_upper_unused
        `UNUSED_VAR (req_step_k[3:1])
    end

    localparam TOTAL_SHIFT = LG_B_SUB_BLOCKS + LG_XLEN_RATIO;
    wire [4:0] dense_offset = (TOTAL_SHIFT == 0) ? block_index : 5'(block_index >> TOTAL_SHIFT);

    localparam SUB_HALF_W = (LG_XLEN_RATIO == 0) ? 1 : LG_XLEN_RATIO;
    wire [SUB_HALF_W-1:0] dense_sub_half =
        (LG_XLEN_RATIO == 0) ? '0
        : SUB_HALF_W'(({27'b0, block_index} >> LG_B_SUB_BLOCKS) & ((1 << LG_XLEN_RATIO) - 1));

    localparam SP_LOGROW_W = 6;
    wire [SP_LOGROW_W-1:0] sp_logrow_a = SP_LOGROW_W'(block_index) * SP_LOGROW_W'(LOGICAL_ROWS_PER_BLK);
    wire [SP_LOGROW_W-1:0] sp_logrow_b = sp_logrow_a + SP_LOGROW_W'(1);
    wire [SUB_HALF_W-1:0] sp_sub_a = (LG_XLEN_RATIO == 0) ? '0
                                   : SUB_HALF_W'(sp_logrow_a & SP_LOGROW_W'((1 << LG_XLEN_RATIO) - 1));
    wire [SUB_HALF_W-1:0] sp_sub_b = (LG_XLEN_RATIO == 0) ? '0
                                   : SUB_HALF_W'(sp_logrow_b & SP_LOGROW_W'((1 << LG_XLEN_RATIO) - 1));

    localparam DESC_ADDR_W = BANK_ADDR_WIDTH + BANK_SEL_BITS;
    localparam SUB_OFF_W   = `UP(BANK_SEL_BITS);
    wire [DESC_ADDR_W-1:0]     desc_b_word_base = DESC_ADDR_W'(req_desc_b[15:0] >> WORD_SIZE_LOG2);
    wire [BANK_ADDR_WIDTH-1:0] desc_b_row_base  = desc_b_word_base[BANK_SEL_BITS +: BANK_ADDR_WIDTH];
    wire [SUB_OFF_W-1:0]       desc_b_sub_off   = (BANK_SEL_BITS > 0) ? desc_b_word_base[SUB_OFF_W-1:0] : '0;
    wire [LDM_W-1:0]           desc_b_ldm_words = LDM_W'(req_desc_b[31:16] >> 2);
    if (`VX_CFG_XLEN > 32) begin : g_desc_b_upper_unused
        `UNUSED_VAR (req_desc_b[`VX_CFG_XLEN-1:32])
    end

    logic                       slot_a_valid_r;
    logic [BANK_ADDR_WIDTH-1:0] slot_a_addr_r;
    logic [BANK_ADDR_WIDTH-1:0] slot_desc_b_row_base_r;
    logic [SUB_OFF_W-1:0]       slot_desc_b_sub_off_r;
    logic                       slot_fetching_r;
    logic [SUB_HALF_W-1:0]      slot_a_sub_half_r;
    logic                       slot_b_valid_r;
    logic [BANK_ADDR_WIDTH-1:0] slot_b_addr_r;
    logic [SUB_HALF_W-1:0]      slot_b_sub_half_r;
    logic                       slot_is_sparse_r;
    logic                       slot_row_major_r;
    logic [LDM_W-1:0]           slot_ldm_words_r;
    logic [3:0]                 slot_step_k_r;
    logic [3:0]                 slot_step_n_r;
    logic [NCTA_WIDTH-1:0]      slot_cta_id_r;
    logic                       refetched_for_first_uop_r;
    logic [KM_CTR_W-1:0]        km_rsp_ctr_r;
    logic [HOLD_WORDS-1:0][31:0] hold_lo_r;

    `UNUSED_VAR (req_step_m)
    wire [BANK_ADDR_WIDTH-1:0] effective_desc_b_row_base =
        req_is_first_uop ? desc_b_row_base : slot_desc_b_row_base_r;
    wire [SUB_OFF_W-1:0] effective_desc_b_sub_off =
        req_is_first_uop ? desc_b_sub_off : slot_desc_b_sub_off_r;

    wire [BANK_ADDR_WIDTH-1:0] fetch_addr_dense    = effective_desc_b_row_base + BANK_ADDR_WIDTH'(dense_offset);
    wire [BANK_ADDR_WIDTH-1:0] fetch_addr_a_sparse = effective_desc_b_row_base + BANK_ADDR_WIDTH'(sp_logrow_a >> LG_XLEN_RATIO);
    wire [BANK_ADDR_WIDTH-1:0] fetch_addr_b_sparse = effective_desc_b_row_base + BANK_ADDR_WIDTH'(sp_logrow_b >> LG_XLEN_RATIO);
    wire [BANK_ADDR_WIDTH-1:0] fetch_addr_a        = req_is_sparse ? fetch_addr_a_sparse : fetch_addr_dense;

    wire bm_coherent = !slot_row_major_r
                    && (!req_is_first_uop || refetched_for_first_uop_r)
                    && (slot_cta_id_r == req_cta_id);

    wire bank_row_resident_dense =
        slot_a_valid_r && !slot_is_sparse_r && bm_coherent
        && (slot_a_addr_r == fetch_addr_dense)
        && (slot_a_sub_half_r == dense_sub_half);

    wire bank_row_resident_sparse =
        slot_a_valid_r && slot_is_sparse_r && bm_coherent
        && (slot_a_addr_r == fetch_addr_a_sparse)
        && (slot_a_sub_half_r == sp_sub_a)
        && (!SPARSE_TWO_SLOT || (slot_b_valid_r
                                 && (slot_b_addr_r == fetch_addr_b_sparse)
                                 && (slot_b_sub_half_r == sp_sub_b)));

    wire bank_row_resident_kmajor =
        slot_a_valid_r && slot_row_major_r
        && (!SPARSE_TWO_SLOT || !slot_is_sparse_r || slot_b_valid_r)
        && (!req_is_first_uop || refetched_for_first_uop_r)
        && (slot_cta_id_r == req_cta_id)
        && (slot_step_k_r == req_step_k)
        && (slot_step_n_r == req_step_n);

    wire req_wants_kmajor  = req_is_first_uop ? (desc_b_ldm_words != '0) : slot_row_major_r;
    wire bank_row_resident = req_wants_kmajor
        ? bank_row_resident_kmajor
        : (req_is_sparse ? bank_row_resident_sparse : bank_row_resident_dense);
    wire need_fetch = req_valid && !bank_row_resident;
    wire alloc_en   = need_fetch && !slot_fetching_r;

    assign bbuf_ready = !req_valid || bank_row_resident;
    wire fire = req_valid && bbuf_ready;
    wire [LDM_W-1:0] km_ldm_words_alloc = req_is_first_uop ? desc_b_ldm_words : slot_ldm_words_r;
    wire [KM_OFF_W-1:0] ldm_ext = KM_OFF_W'(km_ldm_words_alloc);
    wire [KM_OFF_W-1:0] step_n_x_ldm =
        (req_step_n[0] ? ldm_ext        : '0)
      + (req_step_n[1] ? (ldm_ext << 1) : '0)
      + (req_step_n[2] ? (ldm_ext << 2) : '0)
      + (req_step_n[3] ? (ldm_ext << 3) : '0);
    wire [KM_OFF_W-1:0] step_k_x_kw = req_is_sparse
        ? (KM_OFF_W'(req_step_k) << $clog2(2 * TCU_TC_K))
        : (KM_OFF_W'(req_step_k) << $clog2(TCU_WG_FEDP_K));
    wire [KM_OFF_W-1:0] km_word_off_init =
        KM_OFF_W'(effective_desc_b_sub_off) + (step_n_x_ldm << $clog2(TCU_TC_N)) + step_k_x_kw;

    logic [KM_OFF_W-1:0] km_cur_off_r;
    wire [3:0] km_slice_words = slot_is_sparse_r ? 4'(2 * TCU_TC_K) : 4'(TCU_WG_FEDP_K);
    wire [BANK_ROW_WORDS_LOG2-1:0] km_cur_lane = km_cur_off_r[BANK_ROW_WORDS_LOG2-1:0];
    wire km_cur_spans_two = slot_row_major_r
                         && (({1'b0, km_cur_lane} + (BANK_ROW_WORDS_LOG2+1)'(km_slice_words))
                             > (BANK_ROW_WORDS_LOG2+1)'(BANK_ROW_WORDS));

    localparam BUF_OFF_W = $clog2(B_BUF_WORDS);
    wire [BUF_OFF_W:0] km_b_off;
    if (LG_B_SUB_BLOCKS > 0) begin : g_km_b_off
        assign km_b_off = (BUF_OFF_W+1)'(slot_step_n_r[LG_B_SUB_BLOCKS-1:0]) << LG_B_BLOCK_WORDS;
    end else begin : g_km_b_off_zero
        assign km_b_off = '0;
    end

    typedef enum logic [1:0] {
        B_IDLE  = 2'd0,
        B_FA_0  = 2'd1,
        B_FA_1  = 2'd2,
        B_FB    = 2'd3
    } b_state_e;
    b_state_e b_state_r;

    wire in_fetch_a = (b_state_r == B_FA_0) || (b_state_r == B_FA_1);
    wire in_fetch_b = (b_state_r == B_FB);
    wire in_fetch   = (b_state_r != B_IDLE);
    logic inflight_r;

    wire [BANK_ADDR_WIDTH-1:0] km_lmem_addr =
        slot_desc_b_row_base_r
      + BANK_ADDR_WIDTH'(km_cur_off_r >> BANK_ROW_WORDS_LOG2)
      + BANK_ADDR_WIDTH'(b_state_r == B_FA_1);

    wire can_issue = in_fetch && !inflight_r;
    wire km_row_commit = slot_row_major_r && in_fetch_a && tcu_lmem_if.rsp_valid
                      && (!km_cur_spans_two || (b_state_r == B_FA_1));
    wire km_final_rsp = km_row_commit && (km_rsp_ctr_r == KM_CTR_W'(TCU_TC_N - 1));
    wire bm_final_rsp = !slot_row_major_r && in_fetch && tcu_lmem_if.rsp_valid;
    wire last_rsp     = km_final_rsp || bm_final_rsp;

    assign tcu_lmem_if.req_valid          = can_issue;
    assign tcu_lmem_if.req_data.rw        = 1'b0;
    assign tcu_lmem_if.req_data.addr      = slot_row_major_r
        ? km_lmem_addr
        : (in_fetch_b ? slot_b_addr_r : slot_a_addr_r);
    assign tcu_lmem_if.req_data.data      = '0;
    assign tcu_lmem_if.req_data.byteen    = '0;
    assign tcu_lmem_if.req_data.attr      = '0;
    assign tcu_lmem_if.req_data.tag.uuid  = req_uuid;
    assign tcu_lmem_if.req_data.tag.value = '0;
    assign tcu_lmem_if.rsp_ready          = 1'b1;
    `UNUSED_VAR (tcu_lmem_if.rsp_data.tag)

    always_ff @(posedge clk) begin
        if (reset) begin
            b_state_r              <= B_IDLE;
            inflight_r             <= 1'b0;
            slot_a_valid_r         <= 1'b0;
            slot_b_valid_r         <= 1'b0;
            slot_fetching_r        <= 1'b0;
            slot_a_addr_r          <= '0;
            slot_b_addr_r          <= '0;
            slot_desc_b_row_base_r <= '0;
            slot_desc_b_sub_off_r  <= '0;
            slot_a_sub_half_r      <= '0;
            slot_b_sub_half_r      <= '0;
            slot_is_sparse_r       <= 1'b0;
            slot_row_major_r       <= 1'b0;
            slot_ldm_words_r       <= '0;
            slot_step_k_r          <= '0;
            slot_step_n_r          <= '0;
            slot_cta_id_r          <= '0;
            refetched_for_first_uop_r <= 1'b0;
            km_rsp_ctr_r           <= '0;
            km_cur_off_r           <= '0;
            hold_lo_r              <= '0;
        end else if (req_setup) begin
            b_state_r       <= B_IDLE;
            inflight_r      <= 1'b0;
            slot_a_valid_r  <= 1'b0;
            slot_b_valid_r  <= 1'b0;
            slot_fetching_r <= 1'b0;
            km_rsp_ctr_r    <= '0;
            refetched_for_first_uop_r <= 1'b0;
        end else begin
            if (tcu_lmem_if.rsp_valid)
                inflight_r <= 1'b0;
            if (tcu_lmem_if.req_valid && tcu_lmem_if.req_ready)
                inflight_r <= 1'b1;

            if (req_valid && req_is_first_uop) begin
                slot_desc_b_row_base_r <= desc_b_row_base;
                slot_desc_b_sub_off_r  <= desc_b_sub_off;
                slot_ldm_words_r       <= desc_b_ldm_words;
                slot_row_major_r       <= (desc_b_ldm_words != '0);
            end

            if (last_rsp && (!SPARSE_TWO_FETCH || !slot_is_sparse_r || slot_row_major_r || in_fetch_b) && req_is_first_uop)
                refetched_for_first_uop_r <= 1'b1;
            else if (fire && !req_is_first_uop)
                refetched_for_first_uop_r <= 1'b0;

            case (b_state_r)
                B_IDLE: begin
                    if (alloc_en) begin
                        b_state_r         <= B_FA_0;
                        slot_fetching_r   <= 1'b1;
                        slot_a_valid_r    <= 1'b0;
                        slot_b_valid_r    <= 1'b0;
                        slot_a_addr_r     <= fetch_addr_a;
                        slot_a_sub_half_r <= req_is_sparse ? sp_sub_a : dense_sub_half;
                        slot_b_addr_r     <= fetch_addr_b_sparse;
                        slot_b_sub_half_r <= sp_sub_b;
                        slot_is_sparse_r  <= req_is_sparse;
                        slot_step_k_r     <= req_step_k;
                        slot_step_n_r     <= req_step_n;
                        slot_cta_id_r     <= req_cta_id;
                        km_rsp_ctr_r      <= '0;
                        km_cur_off_r      <= km_word_off_init;
                        inflight_r        <= 1'b0;
                    end
                end
                B_FA_0: begin
                    if (tcu_lmem_if.rsp_valid) begin
                        if (slot_row_major_r && km_cur_spans_two) begin
                            for (int h = 0; h < HOLD_WORDS; ++h) begin
                                automatic int sw = int'(km_cur_lane) + h;
                                if (sw < BANK_ROW_WORDS)
                                    hold_lo_r[h] <= tcu_lmem_if.rsp_data.data[sw * 32 +: 32];
                            end
                            b_state_r <= B_FA_1;
                        end else if (last_rsp) begin
                            slot_a_valid_r <= 1'b1;
                            if (slot_is_sparse_r && !slot_row_major_r && SPARSE_TWO_FETCH) begin
                                b_state_r <= B_FB;
                            end else begin
                                if (slot_is_sparse_r && (slot_row_major_r || SPARSE_TWO_SLOT))
                                    slot_b_valid_r <= 1'b1;
                                b_state_r       <= B_IDLE;
                                slot_fetching_r <= 1'b0;
                            end
                        end else if (slot_row_major_r) begin
                            km_rsp_ctr_r <= km_rsp_ctr_r + KM_CTR_W'(1);
                            km_cur_off_r <= km_cur_off_r + KM_OFF_W'(slot_ldm_words_r);
                        end
                    end
                end
                B_FA_1: begin
                    if (tcu_lmem_if.rsp_valid) begin
                        if (last_rsp) begin
                            slot_a_valid_r <= 1'b1;
                            if (slot_is_sparse_r)
                                slot_b_valid_r <= 1'b1;
                            b_state_r       <= B_IDLE;
                            slot_fetching_r <= 1'b0;
                        end else begin
                            b_state_r    <= B_FA_0;
                            km_rsp_ctr_r <= km_rsp_ctr_r + KM_CTR_W'(1);
                            km_cur_off_r <= km_cur_off_r + KM_OFF_W'(slot_ldm_words_r);
                        end
                    end
                end
                B_FB: begin
                    if (last_rsp) begin
                        b_state_r       <= B_IDLE;
                        slot_fetching_r <= 1'b0;
                        slot_b_valid_r  <= 1'b1;
                    end
                end
                default: b_state_r <= B_IDLE;
            endcase
        end
    end

    logic [KM_SLICE_MAX-1:0][31:0] km_coalesced;
    always_comb begin
        km_coalesced = '0;
        for (int s = 0; s < KM_SLICE_MAX; ++s) begin
            automatic int raw_src = int'(km_cur_lane) + s;
            if (!km_cur_spans_two) begin
                if (raw_src < BANK_ROW_WORDS)
                    km_coalesced[s] = tcu_lmem_if.rsp_data.data[raw_src * 32 +: 32];
            end else begin
                if (raw_src < BANK_ROW_WORDS) begin
                    if (s < HOLD_WORDS)
                        km_coalesced[s] = hold_lo_r[s];
                end else if ((raw_src - BANK_ROW_WORDS) < BANK_ROW_WORDS) begin
                    km_coalesced[s] = tcu_lmem_if.rsp_data.data[(raw_src - BANK_ROW_WORDS) * 32 +: 32];
                end
            end
        end
    end

    localparam OFF_W = $clog2(NUM_BANKS * XLEN_RATIO) + 1;
    wire [OFF_W-1:0] a_off_words = OFF_W'(slot_a_sub_half_r) * OFF_W'(NUM_BANKS);
    wire [OFF_W-1:0] b_off_words = OFF_W'(slot_b_sub_half_r) * OFF_W'(NUM_BANKS);
    wire sparse_b_from_a = SPARSE_TWO_SLOT && !SPARSE_TWO_FETCH && slot_is_sparse_r && !slot_row_major_r;

    logic [B_BUF_WORDS*32-1:0] storage_a_wdata, storage_b_wdata;
    logic [B_BUF_WORDS-1:0]    storage_a_wren,  storage_b_wren;
    wire write_a_en = slot_row_major_r ? km_row_commit : (in_fetch_a && tcu_lmem_if.rsp_valid);

    (* keep *) logic [3:0] slot_rm_wbuf_r;
    always_ff @(posedge clk) begin
        if (reset) slot_rm_wbuf_r <= '0;
        else if (req_valid && req_is_first_uop) slot_rm_wbuf_r <= {4{desc_b_ldm_words != '0}};
    end

    always_comb begin
        storage_a_wren = '0;
        storage_b_wren = '0;
        for (int b = 0; b < B_BUF_WORDS; ++b) begin
            automatic int sp_z = b / (TCU_TC_N * 2);
            automatic int sp_c = b % 2;
            automatic int dn_k = b % TCU_WG_FEDP_K;
            automatic int tb_t = b + int'(B_BLOCK_WORDS_SP);
            automatic int tb_z = tb_t / (TCU_TC_N * 2);
            automatic int tb_c = tb_t % 2;
            if (slot_rm_wbuf_r[b & 3]) begin
                storage_a_wdata[b * 32 +: 32] = slot_is_sparse_r ? km_coalesced[sp_z * 2 + sp_c] : km_coalesced[dn_k];
                storage_b_wdata[b * 32 +: 32] = (tb_z * 2 + tb_c < KM_SLICE_MAX) ? km_coalesced[tb_z * 2 + tb_c] : '0;
            end else begin
                storage_a_wdata[b * 32 +: 32] = tcu_lmem_if.rsp_data.data[(int'(a_off_words) + b) * 32 +: 32];
                storage_b_wdata[b * 32 +: 32] = tcu_lmem_if.rsp_data.data[(int'(b_off_words) + b) * 32 +: 32];
            end
        end
        if (slot_row_major_r && km_row_commit && slot_is_sparse_r) begin
            for (int r = 0; r < TCU_TC_N; ++r) begin
                if (km_rsp_ctr_r == KM_CTR_W'(r)) begin
                    for (int z = 0; z < TCU_TC_K; ++z) begin
                        for (int c = 0; c < 2; ++c) begin
                            automatic int tgt = z * (TCU_TC_N * 2) + r * 2 + c;
                            if (!SPARSE_TWO_SLOT || tgt < int'(B_BLOCK_WORDS_SP)) begin
                                if (tgt < B_BUF_WORDS)
                                    storage_a_wren[tgt] = 1'b1;
                            end else if ((tgt - int'(B_BLOCK_WORDS_SP)) < B_BUF_WORDS) begin
                                storage_b_wren[tgt - int'(B_BLOCK_WORDS_SP)] = 1'b1;
                            end
                        end
                    end
                end
            end
        end else if (slot_row_major_r && km_row_commit) begin
            for (int sb = 0; sb < TCU_WG_B_SUB_BLOCKS; ++sb) begin
                if (int'(km_b_off) == sb * B_BLOCK_WORDS) begin
                    for (int r = 0; r < TCU_TC_N; ++r) begin
                        if (km_rsp_ctr_r == KM_CTR_W'(r)) begin
                            for (int k = 0; k < TCU_WG_FEDP_K; ++k) begin
                                automatic int dst = sb * B_BLOCK_WORDS + r * TCU_WG_FEDP_K + k;
                                if (dst < B_BUF_WORDS)
                                    storage_a_wren[dst] = 1'b1;
                            end
                        end
                    end
                end
            end
        end else if (!slot_row_major_r && tcu_lmem_if.rsp_valid) begin
            for (int b = 0; b < B_BUF_WORDS; ++b) begin
                if (in_fetch_a) begin
                    storage_a_wren[b] = 1'b1;
                    if (sparse_b_from_a)
                        storage_b_wren[b] = 1'b1;
                end
                if (in_fetch_b)
                    storage_b_wren[b] = 1'b1;
            end
        end
    end

    wire [B_BUF_WORDS-1:0][31:0] storage_a_rdata, storage_b_rdata;
    VX_dp_ram #(
        .DATAW   (B_BUF_WORDS * 32), .SIZE (1), .WRENW (B_BUF_WORDS),
        .LUTRAM  (1), .OUT_REG (0), .RDW_MODE("W")
    ) storage_a_ram (
        .clk (clk), .reset (reset), .read (1'b1),
        .write (write_a_en), .wren (storage_a_wren),
        .waddr (1'b0), .wdata (storage_a_wdata), .raddr (1'b0), .rdata (storage_a_rdata)
    );

    if (SPARSE_TWO_SLOT) begin : g_slot_b
        VX_dp_ram #(
            .DATAW   (B_BUF_WORDS * 32), .SIZE (1), .WRENW (B_BUF_WORDS),
            .LUTRAM  (1), .OUT_REG (0), .RDW_MODE("W")
        ) storage_b_ram (
            .clk (clk), .reset (reset), .read (1'b1),
            .write ((in_fetch_b && tcu_lmem_if.rsp_valid)
                 || (km_row_commit && slot_is_sparse_r)
                 || (in_fetch_a && tcu_lmem_if.rsp_valid && sparse_b_from_a)),
            .wren (storage_b_wren), .waddr (1'b0), .wdata (storage_b_wdata), .raddr (1'b0), .rdata (storage_b_rdata)
        );
    end else begin : g_no_slot_b
        assign storage_b_rdata = '0;
        `UNUSED_VAR ({storage_b_wdata, storage_b_wren, slot_b_valid_r, slot_b_addr_r, slot_b_sub_half_r, b_off_words})
    end

    logic [TCU_WG_RS2_WIDTH-1:0][`VX_CFG_XLEN-1:0] rs2_mux;
    always_comb begin
        rs2_mux = '0;
        for (int lane = 0; lane < TCU_WG_RS2_WIDTH; ++lane) begin
            if (slot_is_sparse_r && !slot_row_major_r) begin
                automatic int unsigned k_idx_l = lane / (TCU_TC_N * 2);
                automatic int unsigned rem_l   = lane % (TCU_TC_N * 2);
                automatic int unsigned w_l     = (k_idx_l * 2 + (rem_l % 2)) * TCU_TC_N + (rem_l / 2);
                if (w_l < int'(B_BUF_WORDS))
                    rs2_mux[lane] = `VX_CFG_XLEN'(storage_a_rdata[w_l]);
                else if (SPARSE_TWO_SLOT && w_l < int'(2 * B_BLOCK_WORDS))
                    rs2_mux[lane] = `VX_CFG_XLEN'(storage_b_rdata[(w_l - int'(B_BUF_WORDS)) & (B_BUF_WORDS-1)]);
            end else if (SPARSE_TWO_SLOT && slot_is_sparse_r && slot_row_major_r) begin
                if (lane < int'(B_BLOCK_WORDS_SP))
                    rs2_mux[lane] = `VX_CFG_XLEN'(storage_a_rdata[lane]);
                else if (lane < int'(2 * B_BLOCK_WORDS_SP))
                    rs2_mux[lane] = `VX_CFG_XLEN'(storage_b_rdata[lane - int'(B_BLOCK_WORDS_SP)]);
            end else if (lane < int'(B_BUF_WORDS)) begin
                rs2_mux[lane] = `VX_CFG_XLEN'(storage_a_rdata[lane]);
            end
        end
    end
    assign bbuf_rs2_data = rs2_mux;

endmodule

`endif // VX_CFG_TCU_WGMMA_ENABLE
