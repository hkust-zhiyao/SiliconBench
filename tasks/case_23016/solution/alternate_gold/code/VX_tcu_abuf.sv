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
// Per-block A buffer (alternate gold: Beat-0 hold-register coalescer + atomic row commit).
//
module VX_tcu_abuf import VX_gpu_pkg::*, VX_tcu_pkg::*; #(
    parameter `STRING INSTANCE_ID     = "",
    parameter         NUM_BANKS       = 4,
    parameter         BANK_ADDR_WIDTH = 12
) (
    input  wire clk,
    input  wire reset,

`ifdef PERF_ENABLE
    output wire [PERF_CTR_BITS-1:0] abuf_stalls,
    output wire [PERF_CTR_BITS-1:0] lmem_reads,
`endif

    input  wire [NW_WIDTH-1:0]      req_wid,
    input  wire                     req_valid,
    input  wire                     req_setup,
    input  wire [3:0]               req_step_m,
    input  wire [3:0]               req_step_n,
    input  wire [3:0]               req_step_k,
    input  wire [`VX_CFG_XLEN-1:0]  req_desc_a,
    input  wire                     req_a_is_smem,
    input  wire                     req_is_sparse,
    input  wire [UUID_WIDTH-1:0]    req_uuid,

    VX_mem_bus_if.master            tcu_lmem_if,

    output wire                     abuf_ready,
    output wire [TCU_WG_A_DATA_SIZE-1:0][`VX_CFG_XLEN-1:0] abuf_rs1_data
);
    `UNUSED_SPARAM (INSTANCE_ID)
    `UNUSED_VAR (req_wid)

    localparam BANK_SEL_BITS         = $clog2(NUM_BANKS);
    localparam WORD_SIZE_LOG2        = $clog2(`VX_CFG_XLEN / 8);
    localparam A_BLOCK_WORDS         = TCU_TC_M * TCU_WG_FEDP_K;
    localparam A_BLOCK_WORDS_SP      = TCU_TC_M * TCU_TC_K;
    localparam A_BLOCK_BANK_ROWS     = (A_BLOCK_WORDS + NUM_BANKS - 1) / NUM_BANKS;
    localparam A_BLOCK_BANK_ROWS_SP  = (A_BLOCK_WORDS_SP + NUM_BANKS - 1) / NUM_BANKS;
    localparam BLOCK_WORDS_PADDED    = A_BLOCK_BANK_ROWS * NUM_BANKS;
    localparam BLOCK_WORDS_PADDED_SP = A_BLOCK_BANK_ROWS_SP * NUM_BANKS;
    localparam A_STRIPE_BANK_ROWS    = TCU_WG_M_STEPS * A_BLOCK_BANK_ROWS;
    localparam A_STRIPE_BANK_ROWS_SP = TCU_WG_M_STEPS * A_BLOCK_BANK_ROWS_SP;
    localparam A_STRIPE_WORDS        = A_STRIPE_BANK_ROWS * NUM_BANKS;
    localparam XLEN_RATIO            = `VX_CFG_XLEN / 32;
    localparam BANK_ROW_WORDS        = NUM_BANKS * XLEN_RATIO;
    localparam BANK_ROW_WORDS_LOG2   = $clog2(BANK_ROW_WORDS);
    localparam A_STRIPE_LMEM_ROWS    = (A_STRIPE_WORDS + BANK_ROW_WORDS - 1) / BANK_ROW_WORDS;
    localparam A_STRIPE_LMEM_ROWS_SP = (A_STRIPE_BANK_ROWS_SP * NUM_BANKS + BANK_ROW_WORDS - 1) / BANK_ROW_WORDS;
    localparam A_TOTAL_ROWS          = TCU_WG_M_STEPS * TCU_TC_M;
    localparam FETCH_CTR_W_BM        = `CLOG2(A_STRIPE_LMEM_ROWS + 1);
    localparam FETCH_CTR_W_RM        = `CLOG2(A_TOTAL_ROWS + 1);
    localparam FETCH_CTR_W           = (FETCH_CTR_W_BM > FETCH_CTR_W_RM) ? FETCH_CTR_W_BM : FETCH_CTR_W_RM;
    localparam K_STEPS_W             = `CLOG2(TCU_WG_K_STEPS);
    localparam LDM_W                 = 14;
    localparam SUB_OFF_W             = `UP(BANK_SEL_BITS);
    localparam HOLD_WORDS            = (TCU_WG_FEDP_K > 1) ? (TCU_WG_FEDP_K - 1) : 1;

    logic                       slot_valid_r;
    logic [BANK_ADDR_WIDTH-1:0] slot_desc_a_row_base_r;
    logic [SUB_OFF_W-1:0]       slot_desc_a_sub_off_r;
    logic [`UP(K_STEPS_W)-1:0]  slot_step_k_r;
    logic                       slot_fetching_r;
    logic                       slot_row_major_r;
    logic [LDM_W-1:0]           slot_ldm_words_r;
    logic                       slot_is_sparse_r;

    wire [`UP(K_STEPS_W)-1:0] req_step_k_trunc = `UP(K_STEPS_W)'(req_step_k);
    if (4 > K_STEPS_W) begin : g_step_k_upper_unused
        `UNUSED_VAR (req_step_k[3:`UP(K_STEPS_W)])
    end

    wire is_first_compute_uop = (req_step_m == '0) && (req_step_n == '0) && (req_step_k == '0);
    `UNUSED_VAR (req_step_n)

    reg refetched_for_first_compute_r;
    wire stripe_resident = slot_valid_r
                        && (slot_step_k_r == req_step_k_trunc)
                        && (!is_first_compute_uop || refetched_for_first_compute_r);

    wire need_smem  = req_valid && req_a_is_smem;
    wire need_fetch = need_smem && !stripe_resident;
    wire alloc_en   = need_fetch && !slot_fetching_r;

    assign abuf_ready = !req_valid || !req_a_is_smem || stripe_resident;
    wire fire = req_valid && abuf_ready;

    localparam DESC_ADDR_W = BANK_ADDR_WIDTH + BANK_SEL_BITS;
    wire [DESC_ADDR_W-1:0]     desc_a_word_base = DESC_ADDR_W'(req_desc_a[15:0] >> WORD_SIZE_LOG2);
    wire [BANK_ADDR_WIDTH-1:0] desc_a_row_base  = desc_a_word_base[BANK_SEL_BITS +: BANK_ADDR_WIDTH];
    wire [SUB_OFF_W-1:0]       desc_a_sub_off   = (BANK_SEL_BITS > 0) ? desc_a_word_base[SUB_OFF_W-1:0] : '0;
    wire [LDM_W-1:0]           desc_a_ldm_words = LDM_W'(req_desc_a[31:16] >> 2);
    if (`VX_CFG_XLEN > 32) begin : g_desc_a_upper_unused
        `UNUSED_VAR (req_desc_a[`VX_CFG_XLEN-1:32])
    end

    localparam STRIPE_STRIDE_BANK_ROWS = A_STRIPE_LMEM_ROWS;

    wire [BANK_ADDR_WIDTH-1:0] effective_desc_a_row_base =
        is_first_compute_uop ? desc_a_row_base : slot_desc_a_row_base_r;
    wire [SUB_OFF_W-1:0] effective_desc_a_sub_off =
        is_first_compute_uop ? desc_a_sub_off : slot_desc_a_sub_off_r;
    wire [LDM_W-1:0] effective_ldm_words =
        is_first_compute_uop ? desc_a_ldm_words : slot_ldm_words_r;
    wire effective_row_major = (effective_ldm_words != '0);

    wire [BANK_ADDR_WIDTH-1:0] stripe_base =
        effective_desc_a_row_base
      + BANK_ADDR_WIDTH'(req_step_k_trunc) * BANK_ADDR_WIDTH'(STRIPE_STRIDE_BANK_ROWS);

    typedef enum logic [1:0] {
        A_IDLE  = 2'd0,
        A_REQ0  = 2'd1,
        A_REQ1  = 2'd2
    } a_state_e;
    a_state_e state_r;

    wire in_fetch = (state_r != A_IDLE);

    logic [FETCH_CTR_W-1:0]     rsp_ctr_r;
    logic                       inflight_r;
    logic [BANK_ADDR_WIDTH-1:0] fetch_base_r;
    logic [HOLD_WORDS-1:0][31:0] hold_lo_r;

    wire [FETCH_CTR_W-1:0] target_fetches = slot_row_major_r
        ? FETCH_CTR_W'(A_TOTAL_ROWS)
        : (slot_is_sparse_r ? FETCH_CTR_W'(A_STRIPE_LMEM_ROWS_SP)
                            : FETCH_CTR_W'(A_STRIPE_LMEM_ROWS));

    localparam ROW_OFF_W = LDM_W + FETCH_CTR_W + 4;
    wire [3:0] row_k_words = slot_is_sparse_r ? 4'(TCU_TC_K) : 4'(TCU_WG_FEDP_K);
    wire [ROW_OFF_W-1:0] step_k_word_off = req_is_sparse
        ? (ROW_OFF_W'(req_step_k_trunc) << $clog2(TCU_TC_K))
        : (ROW_OFF_W'(req_step_k_trunc) << $clog2(TCU_WG_FEDP_K));
    wire [ROW_OFF_W-1:0] row_word_off_init =
        ROW_OFF_W'(effective_desc_a_sub_off) + step_k_word_off;

    logic [ROW_OFF_W-1:0] cur_word_off_r;
    wire [BANK_ROW_WORDS_LOG2-1:0] cur_lane_w = cur_word_off_r[BANK_ROW_WORDS_LOG2-1:0];
    wire cur_spans_two = slot_row_major_r
                      && (({1'b0, cur_lane_w} + (BANK_ROW_WORDS_LOG2+1)'(row_k_words))
                          > (BANK_ROW_WORDS_LOG2+1)'(BANK_ROW_WORDS));

    wire can_issue = in_fetch && !inflight_r;
    wire commit_en = in_fetch && tcu_lmem_if.rsp_valid
                  && (!cur_spans_two || (state_r == A_REQ1));
    wire last_rsp  = commit_en && (rsp_ctr_r == target_fetches - FETCH_CTR_W'(1));

    wire [BANK_ADDR_WIDTH-1:0] row_lmem_addr =
        fetch_base_r + BANK_ADDR_WIDTH'(cur_word_off_r >> BANK_ROW_WORDS_LOG2)
      + BANK_ADDR_WIDTH'(state_r == A_REQ1);

    assign tcu_lmem_if.req_valid          = can_issue;
    assign tcu_lmem_if.req_data.rw        = 1'b0;
    assign tcu_lmem_if.req_data.addr      = slot_row_major_r
        ? row_lmem_addr
        : (fetch_base_r + BANK_ADDR_WIDTH'(rsp_ctr_r));
    assign tcu_lmem_if.req_data.data      = '0;
    assign tcu_lmem_if.req_data.byteen    = '0;
    assign tcu_lmem_if.req_data.attr      = '0;
    assign tcu_lmem_if.req_data.tag.uuid  = req_uuid;
    assign tcu_lmem_if.req_data.tag.value = '0;
    assign tcu_lmem_if.rsp_ready          = 1'b1;
    `UNUSED_VAR (tcu_lmem_if.rsp_data.tag)
    always_ff @(posedge clk) begin
        if (reset) begin
            state_r                <= A_IDLE;
            rsp_ctr_r              <= '0;
            inflight_r             <= 1'b0;
            slot_valid_r           <= 1'b0;
            slot_fetching_r        <= 1'b0;
            slot_desc_a_row_base_r <= '0;
            slot_desc_a_sub_off_r  <= '0;
            slot_step_k_r          <= '0;
            fetch_base_r           <= '0;
            slot_row_major_r       <= 1'b0;
            slot_ldm_words_r       <= '0;
            slot_is_sparse_r       <= 1'b0;
            cur_word_off_r         <= '0;
            hold_lo_r              <= '0;
            refetched_for_first_compute_r <= 1'b0;
        end else if (req_setup) begin
            state_r         <= A_IDLE;
            rsp_ctr_r       <= '0;
            inflight_r      <= 1'b0;
            slot_valid_r    <= 1'b0;
            slot_fetching_r <= 1'b0;
            refetched_for_first_compute_r <= 1'b0;
        end else begin
            if (tcu_lmem_if.rsp_valid)
                inflight_r <= 1'b0;
            if (tcu_lmem_if.req_valid && tcu_lmem_if.req_ready)
                inflight_r <= 1'b1;

            if (req_valid && is_first_compute_uop) begin
                slot_desc_a_row_base_r <= desc_a_row_base;
                slot_desc_a_sub_off_r  <= desc_a_sub_off;
                slot_ldm_words_r       <= desc_a_ldm_words;
                slot_row_major_r       <= (desc_a_ldm_words != '0);
            end

            if (last_rsp && is_first_compute_uop)
                refetched_for_first_compute_r <= 1'b1;
            else if (fire && !is_first_compute_uop)
                refetched_for_first_compute_r <= 1'b0;

            case (state_r)
                A_IDLE: begin
                    if (alloc_en) begin
                        state_r          <= A_REQ0;
                        slot_fetching_r  <= 1'b1;
                        slot_valid_r     <= 1'b0;
                        slot_step_k_r    <= req_step_k_trunc;
                        slot_is_sparse_r <= req_is_sparse;
                        fetch_base_r     <= effective_row_major ? effective_desc_a_row_base : stripe_base;
                        rsp_ctr_r        <= '0;
                        cur_word_off_r   <= row_word_off_init;
                        inflight_r       <= 1'b0;
                    end
                end
                A_REQ0: begin
                    if (tcu_lmem_if.rsp_valid) begin
                        if (cur_spans_two) begin
                            for (int h = 0; h < HOLD_WORDS; ++h) begin
                                automatic int src_w = int'(cur_lane_w) + h;
                                if (src_w < BANK_ROW_WORDS)
                                    hold_lo_r[h] <= tcu_lmem_if.rsp_data.data[src_w * 32 +: 32];
                            end
                            state_r <= A_REQ1;
                        end else if (last_rsp) begin
                            state_r         <= A_IDLE;
                            slot_fetching_r <= 1'b0;
                            slot_valid_r    <= 1'b1;
                        end else begin
                            rsp_ctr_r      <= rsp_ctr_r + FETCH_CTR_W'(1);
                            cur_word_off_r <= cur_word_off_r + ROW_OFF_W'(slot_ldm_words_r);
                        end
                    end
                end
                A_REQ1: begin
                    if (tcu_lmem_if.rsp_valid) begin
                        if (last_rsp) begin
                            state_r         <= A_IDLE;
                            slot_fetching_r <= 1'b0;
                            slot_valid_r    <= 1'b1;
                        end else begin
                            state_r        <= A_REQ0;
                            rsp_ctr_r      <= rsp_ctr_r + FETCH_CTR_W'(1);
                            cur_word_off_r <= cur_word_off_r + ROW_OFF_W'(slot_ldm_words_r);
                        end
                    end
                end
                default: state_r <= A_IDLE;
            endcase
        end
    end

    logic [TCU_WG_FEDP_K-1:0][31:0] coalesced_slice;
    always_comb begin
        coalesced_slice = '0;
        for (int k = 0; k < TCU_WG_FEDP_K; ++k) begin
            automatic int raw_src = int'(cur_lane_w) + k;
            if (!cur_spans_two) begin
                if (raw_src < BANK_ROW_WORDS)
                    coalesced_slice[k] = tcu_lmem_if.rsp_data.data[raw_src * 32 +: 32];
            end else begin
                if (raw_src < BANK_ROW_WORDS) begin
                    if (k < HOLD_WORDS)
                        coalesced_slice[k] = hold_lo_r[k];
                end else if ((raw_src - BANK_ROW_WORDS) < BANK_ROW_WORDS) begin
                    coalesced_slice[k] = tcu_lmem_if.rsp_data.data[(raw_src - BANK_ROW_WORDS) * 32 +: 32];
                end
            end
        end
    end

    (* keep *) logic [3:0] slot_rm_wbuf_r;
    always_ff @(posedge clk) begin
        if (reset) slot_rm_wbuf_r <= '0;
        else if (req_valid && is_first_compute_uop) slot_rm_wbuf_r <= {4{desc_a_ldm_words != '0}};
    end

    logic [A_STRIPE_WORDS*32-1:0] storage_wdata;
    logic [A_STRIPE_WORDS-1:0]    storage_wren;
    always_comb begin
        storage_wren = '0;
        for (int dst = 0; dst < A_STRIPE_WORDS; ++dst) begin
            automatic int dn_k = dst % TCU_WG_FEDP_K;
            automatic int sp_m = dst / BLOCK_WORDS_PADDED_SP;
            automatic int sp_r = dst % BLOCK_WORDS_PADDED_SP;
            automatic int sp_k = sp_r % TCU_TC_K;
            automatic int bm_b = dst % BANK_ROW_WORDS;
            if (slot_rm_wbuf_r[dst & 3]) begin
                if (slot_is_sparse_r && sp_m < TCU_WG_M_STEPS && sp_r < (TCU_TC_M * TCU_TC_K))
                    storage_wdata[dst * 32 +: 32] = coalesced_slice[sp_k];
                else
                    storage_wdata[dst * 32 +: 32] = coalesced_slice[dn_k];
            end else begin
                storage_wdata[dst * 32 +: 32] = tcu_lmem_if.rsp_data.data[bm_b * 32 +: 32];
            end
        end
        if (commit_en) begin
            if (slot_row_major_r) begin
                for (int r = 0; r < A_TOTAL_ROWS; ++r) begin
                    if (rsp_ctr_r == FETCH_CTR_W'(r)) begin
                        if (slot_is_sparse_r) begin
                            for (int k = 0; k < TCU_TC_K; ++k) begin
                                automatic int dst_sp = (r / TCU_TC_M) * BLOCK_WORDS_PADDED_SP
                                                     + (r % TCU_TC_M) * TCU_TC_K + k;
                                if (dst_sp < A_STRIPE_WORDS)
                                    storage_wren[dst_sp] = 1'b1;
                            end
                        end else begin
                            for (int k = 0; k < TCU_WG_FEDP_K; ++k) begin
                                automatic int dst_dn = r * TCU_WG_FEDP_K + k;
                                if (dst_dn < A_STRIPE_WORDS)
                                    storage_wren[dst_dn] = 1'b1;
                            end
                        end
                    end
                end
            end else begin
                for (int rr = 0; rr < A_STRIPE_LMEM_ROWS; ++rr) begin
                    if (rsp_ctr_r == FETCH_CTR_W'(rr)) begin
                        for (int b = 0; b < BANK_ROW_WORDS; ++b) begin
                            if (rr * BANK_ROW_WORDS + b < A_STRIPE_WORDS)
                                storage_wren[rr * BANK_ROW_WORDS + b] = 1'b1;
                        end
                    end
                end
            end
        end
    end

    wire [A_STRIPE_WORDS-1:0][31:0] storage_rdata;
    VX_dp_ram #(
        .DATAW   (A_STRIPE_WORDS * 32),
        .SIZE    (1),
        .WRENW   (A_STRIPE_WORDS),
        .LUTRAM  (1),
        .OUT_REG (0),
        .RDW_MODE("W")
    ) storage_ram (
        .clk   (clk),
        .reset (reset),
        .read  (1'b1),
        .write (commit_en),
        .wren  (storage_wren),
        .waddr (1'b0),
        .wdata (storage_wdata),
        .raddr (1'b0),
        .rdata (storage_rdata)
    );

    logic [TCU_WG_A_DATA_SIZE-1:0][`VX_CFG_XLEN-1:0] rs1_mux;
    always_comb begin
        rs1_mux = '0;
        for (int lane = 0; lane < TCU_WG_A_DATA_SIZE; ++lane) begin
            int src_idx;
            if (req_is_sparse) begin
                automatic int row = lane / int'(TCU_WG_FEDP_K);
                automatic int k   = lane % int'(TCU_WG_FEDP_K);
                if (row < int'(TCU_TC_M) && k < int'(TCU_TC_K)) begin
                    src_idx = int'(req_step_m) * int'(BLOCK_WORDS_PADDED_SP) + row * int'(TCU_TC_K) + k;
                    if (src_idx < int'(A_STRIPE_WORDS))
                        rs1_mux[lane] = `VX_CFG_XLEN'(storage_rdata[src_idx]);
                end
            end else if (lane < int'(A_BLOCK_WORDS)) begin
                src_idx = int'(req_step_m) * int'(BLOCK_WORDS_PADDED) + lane;
                if (src_idx < int'(A_STRIPE_WORDS))
                    rs1_mux[lane] = `VX_CFG_XLEN'(storage_rdata[src_idx]);
            end
        end
    end
    assign abuf_rs1_data = rs1_mux;

`ifdef PERF_ENABLE
    reg [PERF_CTR_BITS-1:0] stall_ctr_r, reads_ctr_r;
    always_ff @(posedge clk) begin
        if (reset) begin
            stall_ctr_r <= '0;
            reads_ctr_r <= '0;
        end else begin
            if (req_valid && !abuf_ready)
                stall_ctr_r <= stall_ctr_r + PERF_CTR_BITS'(1);
            if (tcu_lmem_if.req_valid && tcu_lmem_if.req_ready)
                reads_ctr_r <= reads_ctr_r + PERF_CTR_BITS'(1);
        end
    end
    assign abuf_stalls = stall_ctr_r;
    assign lmem_reads  = reads_ctr_r;
`endif

endmodule

`endif // VX_CFG_TCU_WGMMA_ENABLE
