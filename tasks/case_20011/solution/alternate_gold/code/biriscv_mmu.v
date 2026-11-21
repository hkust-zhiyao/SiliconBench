//-----------------------------------------------------------------
//                         biRISC-V CPU
//                            V0.8.1
//                     Ultra-Embedded.com
//                     Copyright 2019-2020
//
//                   admin@ultra-embedded.com
//
//                     License: Apache 2.0
//-----------------------------------------------------------------
module biriscv_mmu
#(
     parameter MEM_CACHE_ADDR_MIN = 0
    ,parameter MEM_CACHE_ADDR_MAX = 32'hffffffff
    ,parameter SUPPORT_MMU      = 1
)
(
     input           clk_i
    ,input           rst_i
    ,input  [  1:0]  priv_d_i
    ,input           sum_i
    ,input           mxr_i
    ,input           flush_i
    ,input  [ 31:0]  satp_i
    ,input           fetch_in_rd_i
    ,input           fetch_in_flush_i
    ,input           fetch_in_invalidate_i
    ,input  [ 31:0]  fetch_in_pc_i
    ,input  [  1:0]  fetch_in_priv_i
    ,input           fetch_out_accept_i
    ,input           fetch_out_valid_i
    ,input           fetch_out_error_i
    ,input  [ 63:0]  fetch_out_inst_i
    ,input  [ 31:0]  lsu_in_addr_i
    ,input  [ 31:0]  lsu_in_data_wr_i
    ,input           lsu_in_rd_i
    ,input  [  3:0]  lsu_in_wr_i
    ,input           lsu_in_cacheable_i
    ,input  [ 10:0]  lsu_in_req_tag_i
    ,input           lsu_in_invalidate_i
    ,input           lsu_in_writeback_i
    ,input           lsu_in_flush_i
    ,input  [ 31:0]  lsu_out_data_rd_i
    ,input           lsu_out_accept_i
    ,input           lsu_out_ack_i
    ,input           lsu_out_error_i
    ,input  [ 10:0]  lsu_out_resp_tag_i

    ,output          fetch_in_accept_o
    ,output          fetch_in_valid_o
    ,output          fetch_in_error_o
    ,output [ 63:0]  fetch_in_inst_o
    ,output          fetch_out_rd_o
    ,output          fetch_out_flush_o
    ,output          fetch_out_invalidate_o
    ,output [ 31:0]  fetch_out_pc_o
    ,output          fetch_in_fault_o
    ,output [ 31:0]  lsu_in_data_rd_o
    ,output          lsu_in_accept_o
    ,output          lsu_in_ack_o
    ,output          lsu_in_error_o
    ,output [ 10:0]  lsu_in_resp_tag_o
    ,output [ 31:0]  lsu_out_addr_o
    ,output [ 31:0]  lsu_out_data_wr_o
    ,output          lsu_out_rd_o
    ,output [  3:0]  lsu_out_wr_o
    ,output          lsu_out_cacheable_o
    ,output [ 10:0]  lsu_out_req_tag_o
    ,output          lsu_out_invalidate_o
    ,output          lsu_out_writeback_o
    ,output          lsu_out_flush_o
    ,output          lsu_in_load_fault_o
    ,output          lsu_in_store_fault_o
);

`include "biriscv_defs.v"

localparam  STATE_W            = 2;
localparam  STATE_IDLE         = 2'd0;
localparam  STATE_LEVEL_FIRST  = 2'd1;
localparam  STATE_LEVEL_SECOND = 2'd2;
localparam  STATE_UPDATE       = 2'd3;

generate
if (SUPPORT_MMU)
begin : gen_mmu

    reg [STATE_W-1:0] state_q;
    wire              idle_w = (state_q == STATE_IDLE);

    wire        resp_mmu_w   = (lsu_out_resp_tag_i[9:7] == 3'b111);
    wire        resp_valid_w = resp_mmu_w & lsu_out_ack_i;
    wire        resp_error_w = resp_mmu_w & lsu_out_error_i;
    wire [31:0] resp_data_w  = lsu_out_data_rd_i;

    wire        cpu_accept_w;

    //-----------------------------------------------------------------
    // Stalled D-Side Request Retention Buffer
    //-----------------------------------------------------------------
    reg         lsu_hold_q;
    reg         hold_rd_q;
    reg [  3:0] hold_wr_q;
    reg [ 31:0] hold_addr_q;
    reg [ 31:0] hold_wdata_q;
    reg [ 10:0] hold_tag_q;
    reg         hold_inv_q;
    reg         hold_wb_q;
    reg         hold_flush_q;

    wire        raw_d_req_w = lsu_in_rd_i || (|lsu_in_wr_i) || lsu_in_invalidate_i || lsu_in_writeback_i || lsu_in_flush_i;

    always @ (posedge clk_i or posedge rst_i)
    if (rst_i)
    begin
        lsu_hold_q   <= 1'b0;
        hold_rd_q    <= 1'b0;
        hold_wr_q    <= 4'b0;
        hold_addr_q  <= 32'b0;
        hold_wdata_q <= 32'b0;
        hold_tag_q   <= 11'b0;
        hold_inv_q   <= 1'b0;
        hold_wb_q    <= 1'b0;
        hold_flush_q <= 1'b0;
    end
    else if (lsu_hold_q)
    begin
        if (lsu_in_accept_o)
            lsu_hold_q <= 1'b0;
    end
    else if (raw_d_req_w && !lsu_in_accept_o)
    begin
        lsu_hold_q   <= 1'b1;
        hold_rd_q    <= lsu_in_rd_i;
        hold_wr_q    <= lsu_in_wr_i;
        hold_addr_q  <= lsu_in_addr_i;
        hold_wdata_q <= lsu_in_data_wr_i;
        hold_tag_q   <= lsu_in_req_tag_i;
        hold_inv_q   <= lsu_in_invalidate_i;
        hold_wb_q    <= lsu_in_writeback_i;
        hold_flush_q <= lsu_in_flush_i;
    end

    wire        load_w       = lsu_hold_q ? hold_rd_q    : lsu_in_rd_i;
    wire [ 3:0] store_w      = lsu_hold_q ? hold_wr_q    : lsu_in_wr_i;
    wire [31:0] lsu_addr_w   = lsu_hold_q ? hold_addr_q  : lsu_in_addr_i;
    wire [31:0] lsu_wdata_w  = lsu_hold_q ? hold_wdata_q : lsu_in_data_wr_i;
    wire [10:0] lsu_tag_w    = lsu_hold_q ? hold_tag_q   : lsu_in_req_tag_i;
    wire        lsu_inv_w    = lsu_hold_q ? hold_inv_q   : lsu_in_invalidate_i;
    wire        lsu_wb_w     = lsu_hold_q ? hold_wb_q    : lsu_in_writeback_i;
    wire        lsu_flush_w  = lsu_hold_q ? hold_flush_q : lsu_in_flush_i;

    //-----------------------------------------------------------------
    // Downstream In-Flight Counters (Guarantee Strictly In-Order Faults)
    //-----------------------------------------------------------------
    reg [2:0] icache_pend_q;
    wire      icache_push_w = fetch_out_rd_o && fetch_out_accept_i;
    wire      icache_pop_w  = fetch_out_valid_i;

    always @ (posedge clk_i or posedge rst_i)
    if (rst_i)
        icache_pend_q <= 3'd0;
    else if (fetch_out_flush_o)
        icache_pend_q <= 3'd0;
    else if (icache_push_w && !icache_pop_w)
        icache_pend_q <= icache_pend_q + 3'd1;
    else if (!icache_push_w && icache_pop_w && (icache_pend_q != 3'd0))
        icache_pend_q <= icache_pend_q - 3'd1;

    reg [2:0] dcache_pend_q;
    wire      src_mmu_w;
    wire      dcache_push_w = !src_mmu_w && (lsu_out_rd_o || (|lsu_out_wr_o) || lsu_out_invalidate_o || lsu_out_writeback_o || lsu_out_flush_o) && lsu_out_accept_i;
    wire      dcache_pop_w  = lsu_out_ack_i && !resp_mmu_w;

    always @ (posedge clk_i or posedge rst_i)
    if (rst_i)
        dcache_pend_q <= 3'd0;
    else if (dcache_push_w && !dcache_pop_w)
        dcache_pend_q <= dcache_pend_q + 3'd1;
    else if (!dcache_push_w && dcache_pop_w && (dcache_pend_q != 3'd0))
        dcache_pend_q <= dcache_pend_q - 3'd1;

    //-----------------------------------------------------------------
    // Sv32 Mode & Page Table Walker
    //-----------------------------------------------------------------
    wire        itlb_hit_w;
    wire        dtlb_hit_w;
    reg         dtlb_req_q;
    reg         walk_flushed_q;

    // Sv32 active ONLY when satp.MODE == 1 AND privilege != M-mode!
    wire        vm_enable_w    = satp_i[`SATP_MODE_R];
    wire [31:0] ptbr_w         = {satp_i[`SATP_PPN_R], 12'b0};

    wire        ifetch_vm_w    = (fetch_in_priv_i != `PRIV_MACHINE);
    wire        dfetch_vm_w    = (priv_d_i != `PRIV_MACHINE);

    wire        supervisor_i_w = (fetch_in_priv_i == `PRIV_SUPER);
    wire        supervisor_d_w = (priv_d_i == `PRIV_SUPER);

    wire        vm_i_enable_w  = vm_enable_w & ifetch_vm_w;
    wire        vm_d_enable_w  = vm_enable_w & dfetch_vm_w;

    wire        itlb_miss_w    = fetch_in_rd_i & vm_i_enable_w & ~itlb_hit_w;
    wire        dtlb_miss_w    = (load_w || (|store_w)) & vm_d_enable_w & ~dtlb_hit_w;

    reg [31:0]  pte_addr_q;
    reg [31:0]  pte_entry_q;
    reg [31:0]  virt_addr_q;

    // Use live address ONLY at STATE_IDLE; during walk ALWAYS use latched virt_addr_q!
    wire [31:0] idle_req_addr_w = dtlb_miss_w ? lsu_addr_w : fetch_in_pc_i;

    wire [31:0] pte_ppn_w       = {`PAGE_PFN_SHIFT'b0, resp_data_w[31:`PAGE_PFN_SHIFT]};
    wire [9:0]  pte_flags_w     = resp_data_w[9:0];

    wire        pte_v_w         = resp_data_w[`PAGE_PRESENT];
    wire        pte_r_w         = resp_data_w[`PAGE_READ];
    wire        pte_w_w         = resp_data_w[`PAGE_WRITE];
    wire        pte_x_w         = resp_data_w[`PAGE_EXEC];
    wire        pte_rwx_any_w   = pte_r_w | pte_w_w | pte_x_w;
    wire        pte_rsvd_rw_w   = (~pte_r_w) & pte_w_w;
    wire        superpage_misaligned_w = (resp_data_w[19:10] != 10'b0);

    always @ (posedge clk_i or posedge rst_i)
    if (rst_i)
    begin
        pte_addr_q     <= 32'b0;
        pte_entry_q    <= 32'b0;
        virt_addr_q    <= 32'b0;
        dtlb_req_q     <= 1'b0;
        walk_flushed_q <= 1'b0;
        state_q        <= STATE_IDLE;
    end
    else
    begin
        if (flush_i && state_q != STATE_IDLE)
            walk_flushed_q <= 1'b1;

        if (state_q == STATE_IDLE && (itlb_miss_w || dtlb_miss_w) && !flush_i)
        begin
            pte_addr_q     <= ptbr_w + {20'b0, idle_req_addr_w[31:22], 2'b0};
            virt_addr_q    <= idle_req_addr_w;
            dtlb_req_q     <= dtlb_miss_w;
            walk_flushed_q <= 1'b0;
            state_q        <= STATE_LEVEL_FIRST;
        end
        else if (state_q == STATE_LEVEL_FIRST && resp_valid_w)
        begin
            // Error, V=0, or reserved R=0 & W=1 encoding -> fault
            if (resp_error_w || !pte_v_w || pte_rsvd_rw_w)
            begin
                pte_entry_q <= 32'b0;
                state_q     <= STATE_UPDATE;
            end
            // Pointer to second-level page table (R=0, W=0, X=0)
            else if (!pte_rwx_any_w)
            begin
                if (flush_i || walk_flushed_q)
                begin
                    pte_entry_q <= 32'b0;
                    state_q     <= STATE_UPDATE;
                end
                else
                begin
                    pte_addr_q  <= {resp_data_w[29:10], 12'b0} + {20'b0, virt_addr_q[21:12], 2'b0};
                    state_q     <= STATE_LEVEL_SECOND;
                end
            end
            // Level-1 4 MiB superpage leaf: enforce PPN[0] == 0 alignment!
            else if (superpage_misaligned_w)
            begin
                pte_entry_q <= 32'b0;
                state_q     <= STATE_UPDATE;
            end
            else
            begin
                pte_entry_q <= ((pte_ppn_w | {22'b0, virt_addr_q[21:12]}) << `MMU_PGSHIFT) | {22'b0, pte_flags_w};
                state_q     <= STATE_UPDATE;
            end
        end
        else if (state_q == STATE_LEVEL_SECOND && resp_valid_w)
        begin
            // Level-2 4 KiB leaf: must have !resp_error_w, V=1, leaf (R|W|X)!=0, and !(W & !R)
            if (!resp_error_w && pte_v_w && pte_rwx_any_w && !pte_rsvd_rw_w)
            begin
                pte_entry_q <= (pte_ppn_w << `MMU_PGSHIFT) | {22'b0, pte_flags_w};
                state_q     <= STATE_UPDATE;
            end
            else
            begin
                pte_entry_q <= 32'b0;
                state_q     <= STATE_UPDATE;
            end
        end
        else if (state_q == STATE_UPDATE)
        begin
            walk_flushed_q <= 1'b0;
            state_q        <= STATE_IDLE;
        end
    end

    //-----------------------------------------------------------------
    // IMMU 2-Entry Associative LRU TLB
    //-----------------------------------------------------------------
    reg [1:0]   itlb_valid_q;
    reg [31:12] itlb_va_q [0:1];
    reg [31:0]  itlb_pte_q [0:1];
    reg         itlb_repl_q;
    reg         pc_fault_q;

    wire itlb_m0_w = itlb_valid_q[0] && (itlb_va_q[0] == fetch_in_pc_i[31:12]);
    wire itlb_m1_w = itlb_valid_q[1] && (itlb_va_q[1] == fetch_in_pc_i[31:12]);
    wire [31:0] itlb_entry_q = itlb_m0_w ? itlb_pte_q[0] : itlb_pte_q[1];

    always @ (posedge clk_i or posedge rst_i)
    if (rst_i)
    begin
        itlb_valid_q  <= 2'b00;
        itlb_va_q[0]  <= 20'b0;
        itlb_va_q[1]  <= 20'b0;
        itlb_pte_q[0] <= 32'b0;
        itlb_pte_q[1] <= 32'b0;
        itlb_repl_q   <= 1'b0;
    end
    else if (flush_i)
        itlb_valid_q <= 2'b00;
    else if (state_q == STATE_UPDATE && !dtlb_req_q && !walk_flushed_q)
    begin
        itlb_valid_q[itlb_repl_q] <= 1'b1;
        itlb_va_q[itlb_repl_q]    <= virt_addr_q[31:12];
        itlb_pte_q[itlb_repl_q]   <= pte_entry_q;
        itlb_repl_q               <= ~itlb_repl_q;
    end

    assign itlb_hit_w = fetch_in_rd_i & (itlb_m0_w | itlb_m1_w);

    reg pc_fault_raw_r;
    always @ *
    begin
        pc_fault_raw_r = 1'b0;

        if (vm_i_enable_w && itlb_hit_w)
        begin
            if (!itlb_entry_q[`PAGE_PRESENT] || !itlb_entry_q[`PAGE_ACCESSED] ||
                (!itlb_entry_q[`PAGE_READ] && itlb_entry_q[`PAGE_WRITE]))
                pc_fault_raw_r = 1'b1;
            else if (supervisor_i_w)
            begin
                if (itlb_entry_q[`PAGE_USER])
                    pc_fault_raw_r = 1'b1;
                else
                    pc_fault_raw_r = ~itlb_entry_q[`PAGE_EXEC];
            end
            else
                pc_fault_raw_r = (~itlb_entry_q[`PAGE_EXEC]) | (~itlb_entry_q[`PAGE_USER]);
        end
    end

    // Accept an I-side fault ONLY when no older downstream I-cache read is still pending!
    wire pc_fault_accept_w = pc_fault_raw_r && (icache_pend_q == 3'd0) && !pc_fault_q && !fetch_in_flush_i;

    always @ (posedge clk_i or posedge rst_i)
    if (rst_i)
        pc_fault_q <= 1'b0;
    else if (fetch_in_flush_i)
        pc_fault_q <= 1'b0;
    else
        pc_fault_q <= pc_fault_accept_w;

    assign fetch_out_rd_o         = ~pc_fault_q && ((~vm_i_enable_w & fetch_in_rd_i) || (vm_i_enable_w & itlb_hit_w & ~pc_fault_raw_r));
    assign fetch_out_pc_o         = vm_i_enable_w ? {itlb_entry_q[31:12], fetch_in_pc_i[11:0]} : fetch_in_pc_i;
    assign fetch_out_flush_o      = fetch_in_flush_i;
    assign fetch_out_invalidate_o = fetch_in_invalidate_i;

    assign fetch_in_accept_o      = (~pc_fault_q & ~vm_i_enable_w & fetch_out_accept_i) |
                                    (~pc_fault_q & vm_i_enable_w & itlb_hit_w & ~pc_fault_raw_r & fetch_out_accept_i) |
                                    pc_fault_accept_w;
    assign fetch_in_valid_o       = fetch_out_valid_i | pc_fault_q;
    assign fetch_in_error_o       = fetch_out_valid_i & fetch_out_error_i;
    assign fetch_in_fault_o       = pc_fault_q;
    assign fetch_in_inst_o        = fetch_out_inst_i;

    //-----------------------------------------------------------------
    // DMMU TLB
    //-----------------------------------------------------------------
    reg         dtlb_valid_q;
    reg [31:12] dtlb_va_addr_q;
    reg [31:0]  dtlb_entry_q;
    reg         store_fault_q;
    reg         load_fault_q;

    always @ (posedge clk_i or posedge rst_i)
    if (rst_i)
        dtlb_valid_q <= 1'b0;
    else if (flush_i)
        dtlb_valid_q <= 1'b0;
    else if (state_q == STATE_UPDATE && dtlb_req_q)
        dtlb_valid_q <= ~walk_flushed_q;

    always @ (posedge clk_i or posedge rst_i)
    if (rst_i)
    begin
        dtlb_va_addr_q <= 20'b0;
        dtlb_entry_q   <= 32'b0;
    end
    else if (state_q == STATE_UPDATE && dtlb_req_q && !walk_flushed_q && !flush_i)
    begin
        dtlb_va_addr_q <= virt_addr_q[31:12];
        dtlb_entry_q   <= pte_entry_q;
    end

    assign dtlb_hit_w = dtlb_valid_q & (dtlb_va_addr_q == lsu_addr_w[31:12]);

    reg load_fault_raw_r;
    always @ *
    begin
        load_fault_raw_r = 1'b0;

        if (vm_d_enable_w && load_w && dtlb_hit_w)
        begin
            if (!dtlb_entry_q[`PAGE_PRESENT] || !dtlb_entry_q[`PAGE_ACCESSED] ||
                (!dtlb_entry_q[`PAGE_READ] && dtlb_entry_q[`PAGE_WRITE]))
                load_fault_raw_r = 1'b1;
            else if (supervisor_d_w)
            begin
                if (dtlb_entry_q[`PAGE_USER] && !sum_i)
                    load_fault_raw_r = 1'b1;
                else
                    load_fault_raw_r = ~(dtlb_entry_q[`PAGE_READ] | (mxr_i & dtlb_entry_q[`PAGE_EXEC]));
            end
            else
                load_fault_raw_r = (~(dtlb_entry_q[`PAGE_READ] | (mxr_i & dtlb_entry_q[`PAGE_EXEC]))) | (~dtlb_entry_q[`PAGE_USER]);
        end
    end

    reg store_fault_raw_r;
    always @ *
    begin
        store_fault_raw_r = 1'b0;

        if (vm_d_enable_w && (|store_w) && dtlb_hit_w)
        begin
            if (!dtlb_entry_q[`PAGE_PRESENT] || !dtlb_entry_q[`PAGE_ACCESSED] || !dtlb_entry_q[`PAGE_DIRTY] ||
                (!dtlb_entry_q[`PAGE_READ] && dtlb_entry_q[`PAGE_WRITE]))
                store_fault_raw_r = 1'b1;
            else if (supervisor_d_w)
            begin
                if (dtlb_entry_q[`PAGE_USER] && !sum_i)
                    store_fault_raw_r = 1'b1;
                else
                    store_fault_raw_r = (~dtlb_entry_q[`PAGE_READ]) | (~dtlb_entry_q[`PAGE_WRITE]);
            end
            else
                store_fault_raw_r = (~dtlb_entry_q[`PAGE_READ]) | (~dtlb_entry_q[`PAGE_WRITE]) | (~dtlb_entry_q[`PAGE_USER]);
        end
    end

    wire d_fault_busy_w    = (dcache_pend_q != 3'd0) || load_fault_q || store_fault_q;
    wire load_fault_acc_w  = load_fault_raw_r  && !d_fault_busy_w;
    wire store_fault_acc_w = store_fault_raw_r && !d_fault_busy_w;

    always @ (posedge clk_i or posedge rst_i)
    if (rst_i)
        store_fault_q <= 1'b0;
    else
        store_fault_q <= store_fault_acc_w;

    always @ (posedge clk_i or posedge rst_i)
    if (rst_i)
        load_fault_q <= 1'b0;
    else
        load_fault_q <= load_fault_acc_w;

    wire        d_fault_active_q     = load_fault_q | store_fault_q;
    wire        d_maint_w            = lsu_inv_w | lsu_wb_w | lsu_flush_w;
    wire        lsu_out_rd_w         = ~d_fault_active_q & (vm_d_enable_w ? (load_w  & dtlb_hit_w & ~load_fault_raw_r)         : load_w);
    wire [3:0]  lsu_out_wr_w         = d_fault_active_q  ? 4'b0 : (vm_d_enable_w ? (store_w & {4{dtlb_hit_w & ~store_fault_raw_r}}) : store_w);
    wire [31:0] lsu_out_addr_w       = (vm_d_enable_w && !d_maint_w) ? {dtlb_entry_q[31:12], lsu_addr_w[11:0]} : lsu_addr_w;
    wire [31:0] lsu_out_data_wr_w    = lsu_wdata_w;

    wire        lsu_out_invalidate_w = ~d_fault_active_q & lsu_inv_w;
    wire        lsu_out_writeback_w  = ~d_fault_active_q & lsu_wb_w;
    wire        lsu_out_flush_w      = ~d_fault_active_q & lsu_flush_w;

    reg         lsu_out_cacheable_r;
    always @ *
    begin
/* verilator lint_off UNSIGNED */
/* verilator lint_off CMPCONST */
        if (lsu_inv_w || lsu_wb_w || lsu_flush_w)
            lsu_out_cacheable_r = 1'b1;
        else
            lsu_out_cacheable_r = (lsu_out_addr_w >= MEM_CACHE_ADDR_MIN && lsu_out_addr_w <= MEM_CACHE_ADDR_MAX);
/* verilator lint_on CMPCONST */
/* verilator lint_on UNSIGNED */
    end

    wire [10:0] lsu_out_req_tag_w    = lsu_tag_w;

    assign lsu_in_ack_o         = (lsu_out_ack_i & ~resp_mmu_w) | store_fault_q | load_fault_q;
    assign lsu_in_resp_tag_o    = lsu_out_resp_tag_i;
    assign lsu_in_error_o       = (lsu_out_error_i & ~resp_mmu_w) | store_fault_q | load_fault_q;
    assign lsu_in_data_rd_o     = lsu_out_data_rd_i;
    assign lsu_in_store_fault_o = store_fault_q;
    assign lsu_in_load_fault_o  = load_fault_q;

    wire d_non_mem_maint_w      = d_maint_w & ~(load_w | (|store_w));
    assign lsu_in_accept_o      = (~d_fault_active_q & (~vm_d_enable_w | d_non_mem_maint_w) & cpu_accept_w) |
                                  (~d_fault_active_q & vm_d_enable_w & dtlb_hit_w & ~load_fault_raw_r & ~store_fault_raw_r & cpu_accept_w) |
                                  load_fault_acc_w | store_fault_acc_w;

    //-----------------------------------------------------------------
    // PTE Fetch Port (Cleanly Drains Even If Aborted By flush_i!)
    //-----------------------------------------------------------------
    reg mem_req_q;
    wire mmu_accept_w;

    always @ (posedge clk_i or posedge rst_i)
    if (rst_i)
        mem_req_q <= 1'b0;
    else if (state_q == STATE_IDLE && (itlb_miss_w || dtlb_miss_w) && !flush_i)
        mem_req_q <= 1'b1;
    else if (state_q == STATE_LEVEL_FIRST && resp_valid_w && !resp_error_w && pte_v_w && !pte_rsvd_rw_w && !pte_rwx_any_w && !flush_i && !walk_flushed_q)
        mem_req_q <= 1'b1;
    else if (mmu_accept_w)
        mem_req_q <= 1'b0;

    //-----------------------------------------------------------------
    // Request Muxing
    //-----------------------------------------------------------------
    reg  read_hold_q;
    reg  src_mmu_q;
    assign src_mmu_w = read_hold_q ? src_mmu_q : mem_req_q;

    always @ (posedge clk_i or posedge rst_i)
    if (rst_i)
    begin
        read_hold_q  <= 1'b0;
        src_mmu_q    <= 1'b0;
    end
    else if ((lsu_out_rd_o || (|lsu_out_wr_o) || lsu_out_invalidate_o || lsu_out_writeback_o || lsu_out_flush_o) && !lsu_out_accept_i)
    begin
        read_hold_q  <= 1'b1;
        src_mmu_q    <= src_mmu_w;
    end
    else if (lsu_out_accept_i)
        read_hold_q  <= 1'b0;

    assign mmu_accept_w         = src_mmu_w  & lsu_out_accept_i;
    assign cpu_accept_w         = ~src_mmu_w & lsu_out_accept_i;

    assign lsu_out_rd_o         = src_mmu_w ? mem_req_q  : lsu_out_rd_w;
    assign lsu_out_wr_o         = src_mmu_w ? 4'b0       : lsu_out_wr_w;
    assign lsu_out_addr_o       = src_mmu_w ? pte_addr_q : lsu_out_addr_w;
    assign lsu_out_data_wr_o    = lsu_out_data_wr_w;

    assign lsu_out_invalidate_o = src_mmu_w ? 1'b0 : lsu_out_invalidate_w;
    assign lsu_out_writeback_o  = src_mmu_w ? 1'b0 : lsu_out_writeback_w;
    assign lsu_out_cacheable_o  = src_mmu_w ? 1'b1 : lsu_out_cacheable_r;
    assign lsu_out_req_tag_o    = src_mmu_w ? {1'b0, 3'b111, 7'b0} : lsu_out_req_tag_w;
    assign lsu_out_flush_o      = src_mmu_w ? 1'b0 : lsu_out_flush_w;

end
else
begin : gen_no_mmu
    assign fetch_out_rd_o         = fetch_in_rd_i;
    assign fetch_out_pc_o         = fetch_in_pc_i;
    assign fetch_out_flush_o      = fetch_in_flush_i;
    assign fetch_out_invalidate_o = fetch_in_invalidate_i;
    assign fetch_in_accept_o      = fetch_out_accept_i;
    assign fetch_in_valid_o       = fetch_out_valid_i;
    assign fetch_in_error_o       = fetch_out_error_i;
    assign fetch_in_fault_o       = 1'b0;
    assign fetch_in_inst_o        = fetch_out_inst_i;

    assign lsu_out_rd_o           = lsu_in_rd_i;
    assign lsu_out_wr_o           = lsu_in_wr_i;
    assign lsu_out_addr_o         = lsu_in_addr_i;
    assign lsu_out_data_wr_o      = lsu_in_data_wr_i;
    assign lsu_out_invalidate_o   = lsu_in_invalidate_i;
    assign lsu_out_writeback_o    = lsu_in_writeback_i;
    assign lsu_out_cacheable_o    = lsu_in_cacheable_i;
    assign lsu_out_req_tag_o      = lsu_in_req_tag_i;
    assign lsu_out_flush_o        = lsu_in_flush_i;

    assign lsu_in_ack_o           = lsu_out_ack_i;
    assign lsu_in_resp_tag_o      = lsu_out_resp_tag_i;
    assign lsu_in_error_o         = lsu_out_error_i;
    assign lsu_in_data_rd_o       = lsu_out_data_rd_i;
    assign lsu_in_store_fault_o   = 1'b0;
    assign lsu_in_load_fault_o    = 1'b0;

    assign lsu_in_accept_o        = lsu_out_accept_i;
end
endgenerate

endmodule
