`include "VX_define.vh"

module tb;
    import VX_gpu_pkg::*;

    localparam NUM_LANES = `VX_CFG_NUM_SFU_LANES;
    localparam NUM_PKTS  = `VX_CFG_NUM_THREADS / NUM_LANES;
    localparam PID_W     = `LOG2UP(NUM_PKTS);

    logic clk = 0;
    always #5 clk = ~clk;

    logic reset = 1;
    int   seed  = 101;
    bit   failed = 0;

    // DUT ports
    logic                               exe_valid;
    sfu_execute_t                       exe_data;
    wire                                exe_ready;

    logic                               txbar_valid;
    txbar_t                             txbar_data;
    wire                                txbar_ready;

    logic [`VX_CFG_NUM_WARPS-1:0]       warp_pending_alm_empty;
    logic                               lsu_sched_drained;
    logic                               bar_phase_in;

    wire                                res_valid;
    sfu_result_t                        res_data;
    logic                               res_ready;

    wire                                wspawn_valid;
    wire                                tmc_valid;
    wire                                split_valid;
    wire                                sjoin_valid;
    wire                                bar_valid;
    wire                                wsync_valid;
    wire [NW_WIDTH-1:0]                 wctl_wid;
    tmc_t                               tmc_out;
    wspawn_t                            wspawn_out;
    split_t                             split_out;
    join_t                              sjoin_out;
    barrier_t                           bar_out;
    wire [BAR_ADDR_W-1:0]               bar_addr_out;
    wire [DV_STACK_SIZEW-1:0]           dvstack_ptr_mon;

    wire                                join_valid;
    wire                                join_is_dvg;
    wire                                join_is_else;
    wire [NW_WIDTH-1:0]                 join_wid;
    wire [`VX_CFG_NUM_THREADS-1:0]      join_tmask;
    wire [PC_BITS-1:0]                  join_pc;

    VX_wctl_ipdom_top #(
        .NUM_LANES (NUM_LANES)
    ) dut (
        .clk                    (clk),
        .reset                  (reset),
        .exe_valid              (exe_valid),
        .exe_data               (exe_data),
        .exe_ready              (exe_ready),
        .txbar_valid            (txbar_valid),
        .txbar_data             (txbar_data),
        .txbar_ready            (txbar_ready),
        .warp_pending_alm_empty (warp_pending_alm_empty),
        .lsu_sched_drained      (lsu_sched_drained),
        .bar_phase_in           (bar_phase_in),
        .res_valid              (res_valid),
        .res_data               (res_data),
        .res_ready              (res_ready),
        .wspawn_valid           (wspawn_valid),
        .tmc_valid              (tmc_valid),
        .split_valid            (split_valid),
        .sjoin_valid            (sjoin_valid),
        .bar_valid              (bar_valid),
        .wsync_valid            (wsync_valid),
        .wctl_wid               (wctl_wid),
        .tmc_out                (tmc_out),
        .wspawn_out             (wspawn_out),
        .split_out              (split_out),
        .sjoin_out              (sjoin_out),
        .bar_out                (bar_out),
        .bar_addr_out           (bar_addr_out),
        .dvstack_ptr_mon        (dvstack_ptr_mon),
        .join_valid             (join_valid),
        .join_is_dvg            (join_is_dvg),
        .join_is_else           (join_is_else),
        .join_wid               (join_wid),
        .join_tmask             (join_tmask),
        .join_pc                (join_pc)
    );

    // -------------------------------------------------------------------------
    // Reference Architectural Model for SIMT IPDOM Stack & Result Queue
    // -------------------------------------------------------------------------
    logic [`VX_CFG_NUM_THREADS-1:0] ref_orig_mask [`VX_CFG_NUM_WARPS-1:0][DV_STACK_SIZE-1:0];
    logic [PC_BITS-1:0]             ref_next_pc   [`VX_CFG_NUM_WARPS-1:0][DV_STACK_SIZE-1:0];
    logic                           ref_phase     [`VX_CFG_NUM_WARPS-1:0][DV_STACK_SIZE-1:0];
    int                             ref_sp        [`VX_CFG_NUM_WARPS-1:0];
    logic [`VX_CFG_NUM_THREADS-1:0] ref_cur_mask  [`VX_CFG_NUM_WARPS-1:0];

    typedef struct {
        logic [UUID_WIDTH-1:0] uuid;
        logic [NW_WIDTH-1:0]   wid;
        logic [`VX_CFG_XLEN-1:0] exp_val;
    } exp_res_t;

    typedef struct {
        int       kind; // 0=tmc/pred, 1=wspawn, 2=split, 3=join, 4=wsync
        logic [NW_WIDTH-1:0] wid;
        logic [`VX_CFG_NUM_THREADS-1:0] exp_tmc;
        logic [`VX_CFG_NUM_WARPS-1:0]   exp_wmask;
        logic [PC_BITS-1:0]             exp_pc;
        logic                           exp_is_dvg;
        logic [`VX_CFG_NUM_THREADS-1:0] exp_then;
        logic [`VX_CFG_NUM_THREADS-1:0] exp_else;
        logic                           exp_join_else;
        logic [`VX_CFG_NUM_THREADS-1:0] exp_join_tmask;
    } exp_cmd_t;

    exp_res_t exp_res_q[$];
    exp_cmd_t exp_cmd_q[$];

    int unsigned rng_state;
    function automatic int unsigned next_rand();
        rng_state = rng_state * 32'd1664525 + 32'd1013904223;
        return rng_state;
    endfunction

    function automatic int popcnt_mask(input logic [`VX_CFG_NUM_THREADS-1:0] m);
        int c = 0;
        for (int b = 0; b < `VX_CFG_NUM_THREADS; b++) c += int'(m[b]);
        return c;
    endfunction

    // Output scoreboard monitor
    always @(posedge clk) begin
        if (!reset && !failed) begin
            if (res_valid && res_ready) begin
                if (exp_res_q.size() == 0) begin
                    $display("FAIL: Unexpected result_if beat (wid=%0d uuid=%0d)", res_data.header.wid, res_data.header.uuid);
                    failed <= 1;
                end else begin
                    exp_res_t er = exp_res_q.pop_front();
                    if (res_data.header.wid !== er.wid || res_data.header.uuid !== er.uuid) begin
                        $display("FAIL: result_if header mismatch got(wid=%0d,uuid=%0d) exp(wid=%0d,uuid=%0d)",
                                 res_data.header.wid, res_data.header.uuid, er.wid, er.uuid);
                        failed <= 1;
                    end
                    for (int l = 0; l < NUM_LANES; l++) begin
                        if (res_data.data[l] !== er.exp_val) begin
                            $display("FAIL: result_if data[%0d] mismatch uuid=%0d got=0x%08x exp=0x%08x",
                                     l, er.uuid, res_data.data[l], er.exp_val);
                            failed <= 1;
                        end
                    end
                end
            end

            if (tmc_valid || wspawn_valid || split_valid || sjoin_valid || wsync_valid) begin
                if (exp_cmd_q.size() == 0) begin
                    $display("FAIL: Unexpected wctl command pulse (tmc=%0b wspawn=%0b split=%0b join=%0b wsync=%0b)",
                             tmc_valid, wspawn_valid, split_valid, sjoin_valid, wsync_valid);
                    failed <= 1;
                end else begin
                    exp_cmd_t ec = exp_cmd_q.pop_front();
                    if (wctl_wid !== ec.wid) begin
                        $display("FAIL: wctl_wid mismatch kind=%0d got=%0d exp=%0d", ec.kind, wctl_wid, ec.wid);
                        failed <= 1;
                    end
                    case (ec.kind)
                        0: begin
                            if (!tmc_valid || tmc_out.tmask !== ec.exp_tmc) begin
                                $display("FAIL: TMC/PRED mismatch wid=%0d got_v=%0b mask=0x%0x exp=0x%0x",
                                         wctl_wid, tmc_valid, tmc_out.tmask, ec.exp_tmc);
                                failed <= 1;
                            end
                        end
                        1: begin
                            if (!wspawn_valid || wspawn_out.wmask !== ec.exp_wmask || wspawn_out.pc !== ec.exp_pc) begin
                                $display("FAIL: WSPAWN mismatch got(v=%0b,wmask=0x%0x,pc=0x%0x) exp(wmask=0x%0x,pc=0x%0x)",
                                         wspawn_valid, wspawn_out.wmask, wspawn_out.pc, ec.exp_wmask, ec.exp_pc);
                                failed <= 1;
                            end
                        end
                        2: begin
                            if (!split_valid || split_out.is_dvg !== ec.exp_is_dvg) begin
                                $display("FAIL: SPLIT dvg mismatch wid=%0d got(v=%0b,dvg=%0b) exp(dvg=%0b)",
                                         wctl_wid, split_valid, split_out.is_dvg, ec.exp_is_dvg);
                                failed <= 1;
                            end else if (ec.exp_is_dvg && (split_out.then_tmask !== ec.exp_then ||
                                         split_out.else_tmask !== ec.exp_else || split_out.next_pc !== ec.exp_pc)) begin
                                $display("FAIL: SPLIT mismatch wid=%0d got(dvg=%0b,then=0x%0x,else=0x%0x,npc=0x%0x) exp(dvg=%0b,then=0x%0x,else=0x%0x,npc=0x%0x)",
                                         wctl_wid, split_out.is_dvg, split_out.then_tmask, split_out.else_tmask, split_out.next_pc,
                                         ec.exp_is_dvg, ec.exp_then, ec.exp_else, ec.exp_pc);
                                failed <= 1;
                            end
                        end
                        3: begin
                            if (!sjoin_valid || !join_valid || join_wid !== ec.wid || join_is_dvg !== ec.exp_is_dvg) begin
                                $display("FAIL: JOIN valid/dvg mismatch wid=%0d got(sj=%0b,jv=%0b,jwid=%0d,dvg=%0b) exp(dvg=%0b)",
                                         ec.wid, sjoin_valid, join_valid, join_wid, join_is_dvg, ec.exp_is_dvg);
                                failed <= 1;
                            end else if (ec.exp_is_dvg) begin
                                if (join_is_else !== ec.exp_join_else || join_tmask !== ec.exp_join_tmask || join_pc !== ec.exp_pc) begin
                                    $display("FAIL: JOIN payload mismatch wid=%0d got(else=%0b,tmask=0x%0x,pc=0x%0x) exp(else=%0b,tmask=0x%0x,pc=0x%0x)",
                                             ec.wid, join_is_else, join_tmask, join_pc,
                                             ec.exp_join_else, ec.exp_join_tmask, ec.exp_pc);
                                    failed <= 1;
                                end
                            end
                        end
                        4: begin
                            if (!wsync_valid) begin
                                $display("FAIL: Expected wsync_valid pulse on wid=%0d", ec.wid);
                                failed <= 1;
                            end
                        end
                    endcase
                end
            end
        end
    end

    int uuid_seq = 1;

    // Drive a single sub-packet (sop/eop/pid explicit)
    task automatic send_subpkt(
        input int                              wid,
        input int                              pid,
        input logic                            sop,
        input logic                            eop,
        input logic [NUM_LANES-1:0]            pkt_tmask,
        input logic [PC_BITS-1:0]              pc,
        input logic [INST_OP_BITS-1:0]         op_type,
        input wctl_args_t                      wargs,
        input logic [NUM_LANES-1:0][31:0]      rs1,
        input logic [NUM_LANES-1:0][31:0]      rs2,
        input logic [31:0]                     exp_res_val
    );
        int w = 0;
        int my_uuid = uuid_seq;
        uuid_seq = uuid_seq + 1;

        @(negedge clk);
        exe_valid                   = 1'b1;
        exe_data                    = '0;
        exe_data.header.uuid        = UUID_WIDTH'(my_uuid);
        exe_data.header.wid         = NW_WIDTH'(wid);
        exe_data.header.tmask       = pkt_tmask;
        exe_data.header.pid         = PID_W'(pid);
        exe_data.header.sop         = sop;
        exe_data.header.eop         = eop;
        exe_data.header.PC          = pc;
        exe_data.header.wb          = 1'b1;
        exe_data.op_type            = op_type;
        exe_data.op_args.wctl       = wargs;
        exe_data.rs1_data           = rs1;
        exe_data.rs2_data           = rs2;

        forever begin
            @(posedge clk);
            if ((exe_valid && exe_ready) || failed) break;
            w = w + 1;
            if (w > 4) begin
                @(negedge clk);
                res_ready = 1'b1;
            end
            if (w > 400) begin
                $display("FAIL: Timeout waiting for exe_ready on uuid=%0d wid=%0d", my_uuid, wid);
                failed = 1;
                break;
            end
        end
        exp_res_q.push_back('{uuid: UUID_WIDTH'(my_uuid), wid: NW_WIDTH'(wid), exp_val: exp_res_val});
    endtask

    // Issue a full warp instruction across active sub-packets (or single sub-packet if active_mask fits 1 pkt)
    task automatic issue_warp_op(
        input int                              wid,
        input logic [`VX_CFG_NUM_THREADS-1:0]  active_mask,
        input logic [`VX_CFG_NUM_THREADS-1:0]  cond_bits,
        input logic [PC_BITS-1:0]              pc,
        input logic [INST_OP_BITS-1:0]         op_type,
        input logic                            cond_neg,
        input logic                            sync_bar,
        input logic                            bar_arrive,
        input logic [31:0]                     scalar_rs1,
        input logic [31:0]                     scalar_rs2,
        input bit                              single_pkt_only = 0
    );
        wctl_args_t wargs;
        int pkt_list[$];
        logic [`VX_CFG_NUM_THREADS-1:0] eff_cond;
        logic [`VX_CFG_NUM_THREADS-1:0] th_m, el_m;
        int cur_sp;
        exp_cmd_t ec;

        wargs = '0;
        wargs.is_cond_neg   = cond_neg;
        wargs.is_sync_bar   = sync_bar;
        wargs.is_bar_arrive = bar_arrive;

        if (single_pkt_only) begin
            int chosen_p = 0;
            for (int p = 0; p < NUM_PKTS; p++) begin
                if (active_mask[p*NUM_LANES +: NUM_LANES] != '0) begin
                    chosen_p = p;
                    break;
                end
            end
            pkt_list.push_back(chosen_p);
        end else begin
            for (int p = 0; p < NUM_PKTS; p++) begin
                if (active_mask[p*NUM_LANES +: NUM_LANES] != '0) begin
                    pkt_list.push_back(p);
                end
            end
            if (pkt_list.size() == 0) pkt_list.push_back(0);
        end

        cur_sp = ref_sp[wid];
        for (int idx = 0; idx < pkt_list.size() && !failed; idx++) begin
            int p = pkt_list[idx];
            logic [NUM_LANES-1:0] pm = active_mask[p*NUM_LANES +: NUM_LANES];
            logic [NUM_LANES-1:0][31:0] r1, r2;
            int last_l = 0;
            logic [31:0] exp_rv;

            for (int l = 0; l < NUM_LANES; l++) begin
                if (pm[l]) last_l = l;
            end
            for (int l = 0; l < NUM_LANES; l++) begin
                // Poison non-last inactive lanes to verify highest-active-lane selection!
                if (op_type == INST_SFU_SPLIT || op_type == INST_SFU_PRED) begin
                    r1[l] = {31'h5A5A_000 + 31'(l), cond_bits[p*NUM_LANES + l]};
                end else begin
                    r1[l] = (l == last_l) ? scalar_rs1 : (32'hDEAD_0000 | 32'(l));
                end
                r2[l] = (l == last_l) ? scalar_rs2 : (32'hBEEF_0000 | 32'(l));
            end

            exp_rv = (op_type == INST_SFU_BAR && bar_arrive) ? 32'(bar_phase_in) : 32'(cur_sp);
            send_subpkt(
                wid, p, (idx == 0), (idx == pkt_list.size() - 1),
                pm, pc, op_type, wargs, r1, r2, exp_rv
            );
        end

        // Push expected warp_ctl / split_join command & update architectural IPDOM stack
        eff_cond = cond_neg ? ~cond_bits : cond_bits;
        th_m = active_mask & eff_cond;
        el_m = active_mask & ~eff_cond;

        ec = '{default: '0};
        ec.wid = NW_WIDTH'(wid);

        case (op_type)
            INST_SFU_TMC: begin
                ec.kind    = 0;
                ec.exp_tmc = scalar_rs1[`VX_CFG_NUM_THREADS-1:0];
                ref_cur_mask[wid] = ec.exp_tmc;
                exp_cmd_q.push_back(ec);
            end
            INST_SFU_PRED: begin
                ec.kind    = 0;
                ec.exp_tmc = (th_m != '0) ? th_m : scalar_rs2[`VX_CFG_NUM_THREADS-1:0];
                ref_cur_mask[wid] = ec.exp_tmc;
                exp_cmd_q.push_back(ec);
            end
            INST_SFU_WSPAWN: begin
                ec.kind = 1;
                for (int w = 0; w < `VX_CFG_NUM_WARPS; w++) begin
                    ec.exp_wmask[w] = (w < scalar_rs1[NW_BITS:0]) && (w != wid);
                end
                ec.exp_pc = from_fullPC(scalar_rs2);
                exp_cmd_q.push_back(ec);
            end
            INST_SFU_SPLIT: begin
                bit tf = (popcnt_mask(th_m) <= popcnt_mask(el_m));
                ec.kind       = 2;
                ec.exp_is_dvg = (th_m != '0) && (el_m != '0);
                ec.exp_then   = tf ? th_m : el_m;
                ec.exp_else   = tf ? el_m : th_m;
                ec.exp_pc     = pc + from_fullPC(32'd4);
                exp_cmd_q.push_back(ec);
                if (ec.exp_is_dvg) begin
                    ref_orig_mask[wid][cur_sp] = th_m | el_m;
                    ref_next_pc[wid][cur_sp]   = ec.exp_pc;
                    ref_phase[wid][cur_sp]     = 1'b0;
                    ref_sp[wid]                = cur_sp + 1;
                    ref_cur_mask[wid]          = ec.exp_then;
                end else begin
                    ref_cur_mask[wid]          = active_mask;
                end
            end
            INST_SFU_JOIN: begin
                int rptr = int'(scalar_rs1[DV_STACK_SIZEW-1:0]);
                ec.kind       = 3;
                ec.exp_is_dvg = (rptr != cur_sp);
                if (ec.exp_is_dvg) begin
                    if (!ref_phase[wid][rptr]) begin
                        ec.exp_join_else  = 1'b1;
                        ec.exp_join_tmask = ref_orig_mask[wid][rptr] & ~active_mask;
                        ec.exp_pc         = ref_next_pc[wid][rptr];
                        ref_phase[wid][rptr] = 1'b1;
                        ref_sp[wid]          = rptr + 1;
                        ref_cur_mask[wid]    = ec.exp_join_tmask;
                    end else begin
                        ec.exp_join_else  = 1'b0;
                        ec.exp_join_tmask = ref_orig_mask[wid][rptr];
                        ec.exp_pc         = ref_next_pc[wid][rptr];
                        ref_sp[wid]       = rptr;
                        ref_cur_mask[wid] = ec.exp_join_tmask;
                    end
                end
                exp_cmd_q.push_back(ec);
            end
            INST_SFU_WSYNC: begin
                ec.kind = 4;
                exp_cmd_q.push_back(ec);
            end
            default: ;
        endcase
    endtask

    task automatic idle_cycles(input int n);
        @(negedge clk);
        exe_valid = 1'b0;
        res_ready = 1'b1;
        repeat (n) @(posedge clk);
    endtask

    initial begin
        void'($value$plusargs("SEED=%d", seed));
        rng_state = 32'(seed) ^ 32'h9E37_79B9;

        exe_valid              = 0;
        exe_data               = '0;
        txbar_valid            = 0;
        txbar_data             = '0;
        warp_pending_alm_empty = '1;
        lsu_sched_drained      = 1'b1;
        bar_phase_in           = 1'b0;
        res_ready              = 1'b1;
        for (int w = 0; w < `VX_CFG_NUM_WARPS; w++) ref_sp[w] = 0;

        repeat (5) @(posedge clk);
        @(negedge clk);
        reset = 0;
        repeat (2) @(posedge clk);

        // =====================================================================
        // Phase 1: Highest-Active-Lane Scalar Operands (lane 0 masked off!),
        //          TMC, PRED (hit + fallback + cond_neg), WSPAWN
        // =====================================================================
        begin
            // Mask with lane 0 = 0 and upper lane(s) = 1
            logic [`VX_CFG_NUM_THREADS-1:0] hi_lane_mask = (`VX_CFG_NUM_THREADS'(1) << (NUM_LANES - 1));
            issue_warp_op(0, hi_lane_mask, '0, PC_BITS'('h100), INST_SFU_TMC,    1'b0, 1'b0, 1'b0, 32'h0000_0005, 32'h0);
            issue_warp_op(1, hi_lane_mask, '0, PC_BITS'('h110), INST_SFU_WSPAWN, 1'b0, 1'b0, 1'b0, 32'd3,         32'h0000_2040);
            // PRED all-false -> fallback to scalar_rs2
            issue_warp_op(0, '1,           '0, PC_BITS'('h120), INST_SFU_PRED,   1'b0, 1'b0, 1'b0, 32'd0,         32'h0000_0003);
            // PRED negated (cond_bits = 0x1 -> ~cond = all except bit 0)
            issue_warp_op(2, '1, `VX_CFG_NUM_THREADS'(1), PC_BITS'('h130), INST_SFU_PRED, 1'b1, 1'b0, 1'b0, 32'd0, 32'h0000_000F);
            idle_cycles(4);
        end

        // =====================================================================
        // Phase 2: Multi-Packet Interleaved Warps, Smaller-Branch-First + Tie,
        //          Negated SPLIT, Non-Divergent SPLIT, Two-Phase JOIN
        // =====================================================================
        if (!failed && NUM_PKTS > 1) begin
            // Interleave pid=0 of wid=0 with pid=0 of wid=1 BEFORE wid=0's eop!
            wctl_args_t wa;
            logic [NUM_LANES-1:0][31:0] r1_w0_p0, r1_w0_p1, r1_w1_p0, r1_w1_p1, r2z;
            wa  = '0;
            r2z = '0;
            for (int l = 0; l < NUM_LANES; l++) begin
                r1_w0_p0[l] = (l == 0) ? 32'd1 : 32'd0; // wid=0 pkt0: bit0=1, bit1=0
                r1_w0_p1[l] = 32'd0;                    // wid=0 pkt1: both 0 -> then=0b0001 (1), else=0b1110 (3) -> smaller then!
                r1_w1_p0[l] = 32'd1;                    // wid=1 pkt0: both 1
                r1_w1_p1[l] = (l == 0) ? 32'd1 : 32'd0; // wid=1 pkt1: bit2=1, bit3=0 -> then=0b0111 (3), else=0b1000 (1) -> smaller else!
            end
            send_subpkt(0, 0, 1'b1, 1'b0, '1, PC_BITS'('h200), INST_SFU_SPLIT, wa, r1_w0_p0, r2z, 32'd0);
            send_subpkt(1, 0, 1'b1, 1'b0, '1, PC_BITS'('h300), INST_SFU_SPLIT, wa, r1_w1_p0, r2z, 32'd0);
            send_subpkt(0, 1, 1'b0, 1'b1, '1, PC_BITS'('h200), INST_SFU_SPLIT, wa, r1_w0_p1, r2z, 32'd0);
            begin
                exp_cmd_t ec0 = '{default: '0};
                ec0.kind = 2; ec0.wid = NW_WIDTH'(0); ec0.exp_is_dvg = 1'b1;
                ec0.exp_then = `VX_CFG_NUM_THREADS'('b0001);
                ec0.exp_else = `VX_CFG_NUM_THREADS'('b1110);
                ec0.exp_pc   = PC_BITS'('h200) + from_fullPC(32'd4);
                exp_cmd_q.push_back(ec0);
                ref_orig_mask[0][0] = `VX_CFG_NUM_THREADS'('b1111);
                ref_next_pc[0][0]   = ec0.exp_pc;
                ref_phase[0][0]     = 1'b0;
                ref_sp[0]           = 1;
            end
            send_subpkt(1, 1, 1'b0, 1'b1, '1, PC_BITS'('h300), INST_SFU_SPLIT, wa, r1_w1_p1, r2z, 32'd0);
            begin
                exp_cmd_t ec1 = '{default: '0};
                ec1.kind = 2; ec1.wid = NW_WIDTH'(1); ec1.exp_is_dvg = 1'b1;
                ec1.exp_then = `VX_CFG_NUM_THREADS'('b1000);
                ec1.exp_else = `VX_CFG_NUM_THREADS'('b0111);
                ec1.exp_pc   = PC_BITS'('h300) + from_fullPC(32'd4);
                exp_cmd_q.push_back(ec1);
                ref_orig_mask[1][0] = `VX_CFG_NUM_THREADS'('b1111);
                ref_next_pc[1][0]   = ec1.exp_pc;
                ref_phase[1][0]     = 1'b0;
                ref_sp[1]           = 1;
            end
            idle_cycles(3);
            // Reconverge both warps (2 JOINs each)
            issue_warp_op(0, `VX_CFG_NUM_THREADS'('b0001), '0, PC_BITS'('h204), INST_SFU_JOIN, 1'b0, 1'b0, 1'b0, 32'd0, 32'd0);
            issue_warp_op(0, `VX_CFG_NUM_THREADS'('b1110), '0, PC_BITS'('h208), INST_SFU_JOIN, 1'b0, 1'b0, 1'b0, 32'd0, 32'd0);
            issue_warp_op(1, `VX_CFG_NUM_THREADS'('b1000), '0, PC_BITS'('h304), INST_SFU_JOIN, 1'b0, 1'b0, 1'b0, 32'd0, 32'd0);
            issue_warp_op(1, `VX_CFG_NUM_THREADS'('b0111), '0, PC_BITS'('h308), INST_SFU_JOIN, 1'b0, 1'b0, 1'b0, 32'd0, 32'd0);
            idle_cycles(4);
        end

        // Tie-break (2 then vs 2 else), larger-then swap (3 then vs 1 else), negated SPLIT, and non-divergent SPLIT+JOIN
        if (!failed) begin
            // 3 then vs 1 else -> else (1 thread) goes first!
            issue_warp_op(0, `VX_CFG_NUM_THREADS'('b1111), `VX_CFG_NUM_THREADS'('b0111), PC_BITS'('h220), INST_SFU_SPLIT, 1'b0, 1'b0, 1'b0, 32'd0, 32'd0);
            // Equal tie (2 then vs 2 else) -> then goes first!
            issue_warp_op(1, `VX_CFG_NUM_THREADS'('b1111), `VX_CFG_NUM_THREADS'('b0101), PC_BITS'('h240), INST_SFU_SPLIT, 1'b0, 1'b0, 1'b0, 32'd0, 32'd0);
            // Non-divergent SPLIT (all active lanes true) + non-divergent JOIN
            issue_warp_op(2, `VX_CFG_NUM_THREADS'('b1111), `VX_CFG_NUM_THREADS'('b1111), PC_BITS'('h260), INST_SFU_SPLIT, 1'b0, 1'b0, 1'b0, 32'd0, 32'd0);
            idle_cycles(2);
            issue_warp_op(2, `VX_CFG_NUM_THREADS'('b1111), '0, PC_BITS'('h264), INST_SFU_JOIN, 1'b0, 1'b0, 1'b0, 32'd0, 32'd0);
            // Negated SPLIT on warp 3
            issue_warp_op(3, `VX_CFG_NUM_THREADS'('b1111), `VX_CFG_NUM_THREADS'('b0001), PC_BITS'('h280), INST_SFU_SPLIT, 1'b1, 1'b0, 1'b0, 32'd0, 32'd0);
            idle_cycles(3);
            // Unwind warps 0, 1, 3
            issue_warp_op(0, `VX_CFG_NUM_THREADS'('b1000), '0, PC_BITS'('h224), INST_SFU_JOIN, 1'b0, 1'b0, 1'b0, 32'd0, 32'd0);
            issue_warp_op(0, `VX_CFG_NUM_THREADS'('b0111), '0, PC_BITS'('h228), INST_SFU_JOIN, 1'b0, 1'b0, 1'b0, 32'd0, 32'd0);
            issue_warp_op(1, `VX_CFG_NUM_THREADS'('b0101), '0, PC_BITS'('h244), INST_SFU_JOIN, 1'b0, 1'b0, 1'b0, 32'd0, 32'd0);
            issue_warp_op(1, `VX_CFG_NUM_THREADS'('b1010), '0, PC_BITS'('h248), INST_SFU_JOIN, 1'b0, 1'b0, 1'b0, 32'd0, 32'd0);
            issue_warp_op(3, `VX_CFG_NUM_THREADS'('b0001), '0, PC_BITS'('h284), INST_SFU_JOIN, 1'b0, 1'b0, 1'b0, 32'd0, 32'd0);
            issue_warp_op(3, `VX_CFG_NUM_THREADS'('b1110), '0, PC_BITS'('h288), INST_SFU_JOIN, 1'b0, 1'b0, 1'b0, 32'd0, 32'd0);
            idle_cycles(4);
        end

        // =====================================================================
        // Phase 3: Zero-Bubble Back-to-Back Same-Warp Divergent SPLITs +
        //          Cross-Warp stack_wid Sampling
        // =====================================================================
        if (!failed) begin
            // Single-packet zero-bubble back-to-back divergent SPLITs on wid=0
            // (active_mask confined to pkt 0: 2 lanes active, 1 taken, 1 untaken!)
            issue_warp_op(0, `VX_CFG_NUM_THREADS'('b0011), `VX_CFG_NUM_THREADS'('b0001), PC_BITS'('h400), INST_SFU_SPLIT, 1'b0, 1'b0, 1'b0, 32'd0, 32'd0, 1'b1);
            issue_warp_op(0, `VX_CFG_NUM_THREADS'('b0011), `VX_CFG_NUM_THREADS'('b0001), PC_BITS'('h404), INST_SFU_SPLIT, 1'b0, 1'b0, 1'b0, 32'd0, 32'd0, 1'b1);
            // Immediately issue a SPLIT on wid=1 on the very next cycle (tests stack_wid vs delayed wid!)
            issue_warp_op(1, `VX_CFG_NUM_THREADS'('b0011), `VX_CFG_NUM_THREADS'('b0001), PC_BITS'('h410), INST_SFU_SPLIT, 1'b0, 1'b0, 1'b0, 32'd0, 32'd0, 1'b1);
            idle_cycles(4);

            // Cleanly unwind wid=1 (sp 0) and wid=0 (early unwind directly to sp 0!)
            issue_warp_op(1, `VX_CFG_NUM_THREADS'('b0001), '0, PC_BITS'('h414), INST_SFU_JOIN, 1'b0, 1'b0, 1'b0, 32'd0, 32'd0, 1'b1);
            issue_warp_op(1, `VX_CFG_NUM_THREADS'('b0010), '0, PC_BITS'('h418), INST_SFU_JOIN, 1'b0, 1'b0, 1'b0, 32'd0, 32'd0, 1'b1);
            idle_cycles(3);

            // =================================================================
            // Phase 4: Early Multi-Frame Branch-Out Unwinding on wid=0
            // wid=0 currently has 2 frames pushed (sp=2); push a 3rd frame (sp=3),
            // then JOIN directly with stack_ptr=0 (skipping frames 2 and 1)!
            // =================================================================
            issue_warp_op(0, `VX_CFG_NUM_THREADS'('b0011), `VX_CFG_NUM_THREADS'('b0001), PC_BITS'('h408), INST_SFU_SPLIT, 1'b0, 1'b0, 1'b0, 32'd0, 32'd0, 1'b1);
            idle_cycles(3);
            // Early JOIN directly to stack_ptr = 0 (first visit -> else path, sp becomes 1!)
            issue_warp_op(0, `VX_CFG_NUM_THREADS'('b0001), '0, PC_BITS'('h420), INST_SFU_JOIN, 1'b0, 1'b0, 1'b0, 32'd0, 32'd0, 1'b1);
            idle_cycles(2);
            // Push inside else path -> MUST observe pre-push sp == 1!
            issue_warp_op(0, `VX_CFG_NUM_THREADS'('b0011), `VX_CFG_NUM_THREADS'('b0001), PC_BITS'('h424), INST_SFU_SPLIT, 1'b0, 1'b0, 1'b0, 32'd0, 32'd0, 1'b1);
            idle_cycles(2);
            // Early JOIN directly to stack_ptr = 0 again (second visit -> full reconvergence, sp becomes 0!)
            issue_warp_op(0, `VX_CFG_NUM_THREADS'('b0010), '0, PC_BITS'('h428), INST_SFU_JOIN, 1'b0, 1'b0, 1'b0, 32'd0, 32'd0, 1'b1);
            idle_cycles(2);
            // Verify wid=0 stack pointer is completely unwound to 0!
            issue_warp_op(0, `VX_CFG_NUM_THREADS'('b0011), '0, PC_BITS'('h42C), INST_SFU_TMC,  1'b0, 1'b0, 1'b0, 32'd3, 32'd0, 1'b1);
            idle_cycles(4);
        end

        // =====================================================================
        // Phase 5: WSYNC & BAR Drain Stalls, BAR Arrive / expect_tx / txbar_bus
        // =====================================================================
        if (!failed) begin
            // 5a: WSYNC must stall while warp_pending_alm_empty[wid=2] == 0
            @(negedge clk);
            warp_pending_alm_empty[2] = 1'b0;
            exe_valid                 = 1'b1;
            exe_data                  = '0;
            exe_data.header.uuid      = UUID_WIDTH'(uuid_seq);
            exe_data.header.wid       = NW_WIDTH'(2);
            exe_data.header.tmask     = '1;
            exe_data.header.sop       = 1'b1;
            exe_data.header.eop       = 1'b1;
            exe_data.op_type          = INST_SFU_WSYNC;
            #1;
            if (exe_ready !== 1'b0 || res_valid !== 1'b0) begin
                $display("FAIL: WSYNC did not stall while warp_pending_alm_empty[2]=0 (exe_ready=%0b)", exe_ready);
                failed = 1;
            end
            repeat (2) @(posedge clk);
            @(negedge clk);
            warp_pending_alm_empty[2] = 1'b1;
            exe_valid                 = 1'b0;
            repeat (2) @(posedge clk);

            // Issue WSYNC cleanly once drained
            issue_warp_op(2, `VX_CFG_NUM_THREADS'('b0011), '0, PC_BITS'('h500), INST_SFU_WSYNC, 1'b0, 1'b0, 1'b0, 32'd0, 32'd0, 1'b1);
            idle_cycles(3);

            // 5b: BAR stall when lsu_sched_drained == 0
            @(negedge clk);
            lsu_sched_drained    = 1'b0;
            exe_valid            = 1'b1;
            exe_data             = '0;
            exe_data.header.wid  = NW_WIDTH'(1);
            exe_data.header.tmask= '1;
            exe_data.header.sop  = 1'b1;
            exe_data.header.eop  = 1'b1;
            exe_data.op_type     = INST_SFU_BAR;
            #1;
            if (exe_ready !== 1'b0) begin
                $display("FAIL: BAR did not stall while lsu_sched_drained=0");
                failed = 1;
            end
            @(posedge clk);
            @(negedge clk);
            lsu_sched_drained = 1'b1;
            exe_valid         = 1'b0;
            repeat (2) @(posedge clk);

            // 5c: BAR arrive writeback (bar_phase_in = 1) vs expect_tx (rs2[31] = 1)
            bar_phase_in = 1'b1;
            issue_warp_op(1, `VX_CFG_NUM_THREADS'('b0011), '0, PC_BITS'('h510), INST_SFU_BAR, 1'b0, 1'b0, 1'b1, 32'h8000_0001, 32'h0000_0003, 1'b1);
            idle_cycles(3);

            // expect_tx: is_bar_arrive=1, rs2[31]=1 -> bar_valid=1, is_event=1, is_arrive=0, phase=1
            begin
                bit saw_tx_exp = 0;
                fork
                    begin
                        issue_warp_op(1, `VX_CFG_NUM_THREADS'('b0011), '0, PC_BITS'('h514), INST_SFU_BAR, 1'b0, 1'b0, 1'b1, 32'h0000_0002, 32'h8000_0004, 1'b1);
                        idle_cycles(1);
                    end
                    begin
                        repeat (6) begin
                            @(posedge clk);
                            if (bar_valid) begin
                                saw_tx_exp = 1;
                                if (bar_out.is_event !== 1'b1 || bar_out.is_arrive !== 1'b0 || bar_out.phase !== 1'b1) begin
                                    $display("FAIL: expect_tx BAR fields wrong: is_event=%0b is_arrive=%0b phase=%0b",
                                             bar_out.is_event, bar_out.is_arrive, bar_out.phase);
                                    failed = 1;
                                end
                            end
                        end
                    end
                join
                if (!saw_tx_exp) begin
                    $display("FAIL: Did not observe bar_valid on expect_tx BAR");
                    failed = 1;
                end
            end
            idle_cycles(3);

            // 5d: Async txbar_bus_if event when execute_if is idle
            @(negedge clk);
            txbar_valid        = 1'b1;
            txbar_data.addr    = BAR_ADDR_W'('h3);
            txbar_data.is_done = 1'b1;
            #1;
            if (txbar_ready !== 1'b1 || bar_addr_out !== BAR_ADDR_W'('h3)) begin
                $display("FAIL: txbar_bus_if not accepted when idle (rdy=%0b addr=0x%0x)", txbar_ready, bar_addr_out);
                failed = 1;
            end
            @(posedge clk);
            @(negedge clk);
            txbar_valid = 1'b0;
            @(posedge clk);
            if (!bar_valid || bar_out.is_event !== 1'b1 || bar_out.phase !== 1'b0) begin
                $display("FAIL: Registered txbar_bus_if event wrong (bar_valid=%0b is_event=%0b phase=%0b)",
                         bar_valid, bar_out.is_event, bar_out.phase);
                failed = 1;
            end
            idle_cycles(3);
        end

        // =====================================================================
        // Phase 6: 120-Op Randomized Multi-Warp SIMT Divergence/Reconvergence
        //          with Backpressure on result_if
        // =====================================================================
        begin
            int last_join_wid;
            last_join_wid = -1;
            for (int w = 0; w < `VX_CFG_NUM_WARPS; w++) ref_cur_mask[w] = '1;
            for (int it = 0; it < 120 && !failed; it++) begin
            int w;
            w = next_rand() % `VX_CFG_NUM_WARPS;
            if (w == last_join_wid) idle_cycles(1);
            res_ready = (next_rand() % 4 != 0);
            if (ref_sp[w] > 0 && (ref_sp[w] >= (DV_STACK_SIZE - 1) || (next_rand() % 2 == 0))) begin
                // Reconverge either top frame or an earlier frame using the warp's active execution mask!
                int target_sp;
                logic [`VX_CFG_NUM_THREADS-1:0] cur_m;
                target_sp = (next_rand() % 4 == 0) ? (next_rand() % ref_sp[w]) : (ref_sp[w] - 1);
                cur_m = (ref_cur_mask[w] != '0) ? ref_cur_mask[w] : `VX_CFG_NUM_THREADS'(1);
                issue_warp_op(w, cur_m, '0, PC_BITS'(32'h600 + it*4), INST_SFU_JOIN, 1'b0, 1'b0, 1'b0, 32'(target_sp), 32'd0);
                last_join_wid = w;
            end else begin
                int kind;
                logic [`VX_CFG_NUM_THREADS-1:0] am, cb, fallback_m;
                logic neg;
                kind = next_rand() % 4;
                am = (ref_sp[w] > 0 && ref_cur_mask[w] != '0)
                     ? ref_cur_mask[w]
                     : (`VX_CFG_NUM_THREADS'(next_rand()) | `VX_CFG_NUM_THREADS'(3));
                cb = `VX_CFG_NUM_THREADS'(next_rand());
                neg = (next_rand() % 2 == 0);
                fallback_m = (ref_sp[w] > 0) ? am : `VX_CFG_NUM_THREADS'(32'h0000_0005);
                if (kind < 2 || ref_sp[w] > 0) begin
                    issue_warp_op(w, am, cb, PC_BITS'(32'h600 + it*4), INST_SFU_SPLIT, neg, 1'b0, 1'b0, 32'd0, 32'd0);
                end else if (kind == 2) begin
                    issue_warp_op(w, am, cb, PC_BITS'(32'h600 + it*4), INST_SFU_PRED,  neg, 1'b0, 1'b0, 32'd0, 32'(fallback_m));
                end else begin
                    issue_warp_op(w, am, '0, PC_BITS'(32'h600 + it*4), INST_SFU_TMC,   1'b0, 1'b0, 1'b0, 32'(am), 32'd0);
                end
                last_join_wid = -1;
            end
            end
        end

        // Drain all remaining stack frames and pending scoreboards
        for (int w = 0; w < `VX_CFG_NUM_WARPS && !failed; w++) begin
            while (ref_sp[w] > 0 && !failed) begin
                logic [`VX_CFG_NUM_THREADS-1:0] drain_m;
                drain_m = (ref_cur_mask[w] != '0) ? ref_cur_mask[w] : `VX_CFG_NUM_THREADS'(1);
                res_ready = 1'b1;
                issue_warp_op(w, drain_m, '0, PC_BITS'('h900), INST_SFU_JOIN, 1'b0, 1'b0, 1'b0, 32'(ref_sp[w] - 1), 32'd0);
                idle_cycles(2);
            end
        end
        idle_cycles(10);

        if (exp_res_q.size() != 0 || exp_cmd_q.size() != 0) begin
            $display("FAIL: Undrained scoreboard items (res=%0d cmd=%0d)", exp_res_q.size(), exp_cmd_q.size());
            failed = 1;
        end

        if (!failed) begin
            $display("PASS_ALL_SIMT_WCTL (seed=%0d)", seed);
            $finish;
        end else begin
            $display("FAIL_SIMT_WCTL (seed=%0d)", seed);
            $fatal(1);
        end
    end
endmodule
