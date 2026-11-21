// Verification testbench for case_23011: Vortex Multi-Core Split-Phase & Global Barrier Subsystem
`include "VX_define.vh"

module tb ();
    import VX_gpu_pkg::*;

    localparam NUM_CORES = `VX_CFG_NUM_CORES;
    localparam NUM_WARPS = `VX_CFG_NUM_WARPS;
    localparam NUM_BARS  = `VX_CFG_NUM_BARRIERS;

    logic clk = 1'b0;
    logic reset = 1'b1;
    always #2 clk = ~clk;

    int seed = 101;
    int cycle_cnt = 0;
    int err_cnt = 0;

    logic [NUM_CORES-1:0]                        req_valid;
    logic [NUM_CORES-1:0][NW_WIDTH-1:0]          req_wid;
    barrier_t [NUM_CORES-1:0]                    req_data;
    logic [NUM_CORES-1:0][BAR_ADDR_W-1:0]        read_addr;
    wire  [NUM_CORES-1:0]                        read_phase;

    logic [NUM_CORES-1:0][NUM_WARPS-1:0]         active_warps;
    wire  [NUM_CORES-1:0]                        unlock_valid;
    wire  [NUM_CORES-1:0][NUM_WARPS-1:0]         unlock_mask;

    VX_cluster_bar_subsys #(
        .NUM_CORES   (NUM_CORES),
        .REQ_OUT_BUF (0),
        .RSP_OUT_BUF (0)
    ) dut (.*);

    task automatic fail_now(input string msg);
        $display("FAIL_CLUSTER_BAR [cycle=%0d, C=%0d, W=%0d]: %s", cycle_cnt, NUM_CORES, NUM_WARPS, msg);
        err_cnt++;
        if (err_cnt >= 6) $fatal(1, "FAIL_CLUSTER_BAR abort");
    endtask

    // Per-core unlocked warp accumulator & X-propagation monitor
    logic [NUM_CORES-1:0][NUM_WARPS-1:0] seen_unlock;
    bit dup_check_en = 1'b1;
    int core0_w2_pulses = 0;

    always_ff @(posedge clk) begin
        if (reset) begin
            cycle_cnt       <= 0;
            seen_unlock     <= '0;
            core0_w2_pulses <= 0;
        end else begin
            cycle_cnt <= cycle_cnt + 1;
            for (int c = 0; c < NUM_CORES; c++) begin
                if ($isunknown(unlock_valid[c]) || $isunknown(read_phase[c]))
                    fail_now($sformatf("X/Z detected on unlock_valid/read_phase on core %0d", c));
                if (unlock_valid[c]) begin
                    if ($isunknown(unlock_mask[c]))
                        fail_now($sformatf("X/Z detected on unlock_mask on core %0d", c));
                    if (unlock_mask[c] == '0)
                        fail_now($sformatf("Spurious unlock_valid with zero unlock_mask on core %0d", c));
                    if (dup_check_en && ((seen_unlock[c] & unlock_mask[c]) != '0))
                        fail_now($sformatf("Duplicate warp unlock on core %0d mask=%b", c, unlock_mask[c]));
                    seen_unlock[c] <= seen_unlock[c] | unlock_mask[c];
                    if (c == 0 && unlock_mask[0][2])
                        core0_w2_pulses <= core0_w2_pulses + 1;
                end
            end
        end
    end

    function automatic barrier_t mk_bar(
        input int id, input bit is_ev, input bit is_glob,
        input bit is_arr, input bit is_syn, input bit ph, input int sz_m1
    );
        barrier_t b;
        b.id        = NB_WIDTH'(id);
        b.is_event  = is_ev;
        b.is_global = is_glob;
        b.is_arrive = is_arr;
        b.is_sync   = is_syn;
        b.phase     = ph;
        b.size_m1   = BAR_SIZE_W'(sz_m1);
        return b;
    endfunction

    // Helper: 2-cycle pipelined single-core barrier op (cycle 0: read_addr + sample read_phase; cycle 1: req_valid)
    task automatic send_bar_1c(
        input int c, input logic [BAR_ADDR_W-1:0] slot, input int wid,
        input barrier_t pkt, output logic sampled_phase
    );
        @(negedge clk);
        read_addr[c] = slot;
        #1;
        sampled_phase = read_phase[c];
        @(posedge clk);
        @(negedge clk);
        req_valid[c] = 1'b1;
        req_wid[c]   = NW_WIDTH'(wid);
        req_data[c]  = pkt;
        @(posedge clk);
        @(negedge clk);
        req_valid[c] = 1'b0;
    endtask

    task automatic wait_core_unlock(input int c, input logic [NUM_WARPS-1:0] exp_mask, input int max_cyc, input string tag);
        int g = 0;
        while ((seen_unlock[c] & exp_mask) != exp_mask) begin
            @(posedge clk);
            g++;
            if (g > max_cyc) begin
                fail_now($sformatf("Timeout (%s) on core %0d: seen=%b exp=%b", tag, c, seen_unlock[c], exp_mask));
                return;
            end
        end
    endtask

    initial begin
        logic ph0, ph1, ph2;
        logic [BAR_ADDR_W-1:0] s_loc0, s_loc1, s_loc2;
        if (!$value$plusargs("SEED=%d", seed)) seed = 101;
        req_valid    = '0;
        req_wid      = '0;
        req_data     = '0;
        read_addr    = '0;
        active_warps = '0;
        for (int c = 0; c < NUM_CORES; c++) active_warps[c] = {NUM_WARPS{1'b1}};

        repeat (5) @(posedge clk);
        @(negedge clk); reset = 1'b0;
        repeat (3) @(posedge clk);

        s_loc0 = BAR_ADDR_W'(1 << NB_BITS) | BAR_ADDR_W'(1);
        s_loc1 = BAR_ADDR_W'(1 << NB_BITS) | BAR_ADDR_W'(2);
        s_loc2 = BAR_ADDR_W'(1 << NB_BITS) | BAR_ADDR_W'(3);

        // =====================================================================
        // PHASE 1: Split-Phase ARRIVE/SYNC/WAIT & Straggler Next-Epoch Overlap
        // =====================================================================
        seen_unlock = '0;
        send_bar_1c(0, s_loc0, 0, mk_bar(1, 0, 0, 1, 0, 0, 2), ph0); // W0 ARRIVE (non-stalling)
        if (ph0 !== 1'b0) fail_now("Phase 1: expected initial read_phase=0");
        send_bar_1c(0, s_loc0, 1, mk_bar(1, 0, 0, 1, 1, 0, 2), ph1); // W1 SYNC (stalls)
        repeat (2) @(posedge clk);
        if (seen_unlock[0] != '0) fail_now("Phase 1: premature unlock before W2 arrived");
        send_bar_1c(0, s_loc0, 2, mk_bar(1, 0, 0, 1, 0, 0, 2), ph2); // W2 ARRIVE -> completes Epoch 0!
        wait_core_unlock(0, (NUM_WARPS'(1) << 1), 6, "P1_W1_unlock");
        if (seen_unlock[0] != (NUM_WARPS'(1) << 1))
            fail_now("Phase 1: non-stalling ARRIVE warps were erroneously unlocked");

        // W1 & W2 immediately start Epoch 1 BEFORE straggler W0 executes Epoch 0's BAR.WAIT(phase=0)!
        seen_unlock = '0;
        send_bar_1c(0, s_loc0, 1, mk_bar(1, 0, 0, 1, 1, 1, 2), ph1); // W1 SYNC Epoch 1
        if (ph1 !== 1'b1) fail_now("Phase 1: read_phase did not toggle to 1 for Epoch 1");
        send_bar_1c(0, s_loc0, 2, mk_bar(1, 0, 0, 1, 0, 1, 2), ph2); // W2 ARRIVE Epoch 1
        // Straggler W0 now executes Epoch 0 BAR.WAIT(phase=0) while Epoch 1 is active!
        send_bar_1c(0, s_loc0, 0, mk_bar(1, 0, 0, 0, 0, 0, 2), ph0);
        wait_core_unlock(0, (NUM_WARPS'(1) << 0), 6, "P1_straggler_W0");
        if ((seen_unlock[0] & (NUM_WARPS'(1) << 1)) != '0)
            fail_now("Phase 1: straggler WAIT corrupted Epoch 1 waiter W1");
        // Now W0 arrives for Epoch 1 -> releases W1 and flips phase back 1 -> 0!
        seen_unlock = '0;
        send_bar_1c(0, s_loc0, 0, mk_bar(1, 0, 0, 1, 0, 1, 2), ph0);
        wait_core_unlock(0, (NUM_WARPS'(1) << 1), 6, "P1_Epoch1_done");

        // 1B: Pure non-stalling ARRIVE-only epoch (is_sync=0 for all warps -> zero-mask guard)
        seen_unlock = '0;
        send_bar_1c(0, s_loc0, 0, mk_bar(1, 0, 0, 1, 0, 0, 1), ph0);
        send_bar_1c(0, s_loc0, 1, mk_bar(1, 0, 0, 1, 0, 0, 1), ph1);
        repeat (2) @(posedge clk);
        @(negedge clk); read_addr[0] = s_loc0; #1;
        if (read_phase[0] !== 1'b1) fail_now("Phase 1B: ARRIVE-only epoch did not toggle phase to 1");
        send_bar_1c(0, s_loc0, 0, mk_bar(1, 0, 0, 1, 0, 1, 1), ph0);
        send_bar_1c(0, s_loc0, 1, mk_bar(1, 0, 0, 1, 0, 1, 1), ph1);
        repeat (2) @(posedge clk);

        // =====================================================================
        // PHASE 2: Signed Async Events — 0-Warps Guard & Out-of-Order txbar
        // =====================================================================
        seen_unlock = '0;
        // 2A: EXPECT_TX(2) + two txbar completions BEFORE any warp arrives!
        send_bar_1c(0, s_loc1, 0, mk_bar(2, 1, 0, 0, 0, 1, 1), ph0); // +2 events
        send_bar_1c(0, s_loc1, 3, mk_bar(2, 1, 0, 0, 0, 0, 0), ph0); // -1 event
        send_bar_1c(0, s_loc1, 2, mk_bar(2, 1, 0, 0, 0, 0, 0), ph0); // -1 event -> events==0, 0 warps!
        @(negedge clk); read_addr[0] = s_loc1; #1;
        if (read_phase[0] !== 1'b0) fail_now("Phase 2A: 0-warp async event completion prematurely flipped phase!");
        send_bar_1c(0, s_loc1, 0, mk_bar(2, 0, 0, 1, 1, 0, 1), ph0);
        send_bar_1c(0, s_loc1, 1, mk_bar(2, 0, 0, 1, 1, 0, 1), ph1);
        wait_core_unlock(0, NUM_WARPS'('b11), 6, "P2A_done");

        // 2B: Out-of-order txbar (-2) arrives BEFORE warps and BEFORE EXPECT_TX(2)!
        seen_unlock = '0;
        send_bar_1c(0, s_loc1, 1, mk_bar(2, 1, 0, 0, 0, 0, 0), ph0); // -1
        send_bar_1c(0, s_loc1, 2, mk_bar(2, 1, 0, 0, 0, 0, 0), ph0); // -2
        send_bar_1c(0, s_loc1, 0, mk_bar(2, 0, 0, 1, 1, 1, 1), ph0); // W0 SYNC
        send_bar_1c(0, s_loc1, 1, mk_bar(2, 0, 0, 1, 1, 1, 1), ph1); // W1 SYNC (all warps arrived, ev=-2)
        repeat (3) @(posedge clk);
        if (seen_unlock[0] != '0) fail_now("Phase 2B: unlocked while signed event balance was negative (-2)");
        send_bar_1c(0, s_loc1, 0, mk_bar(2, 1, 0, 0, 0, 1, 1), ph0); // EXPECT_TX(2) -> ev==0 -> UNLOCK!
        wait_core_unlock(0, NUM_WARPS'('b11), 6, "P2B_ooo_expect_tx");

        // =====================================================================
        // PHASE 3: Back-to-Back 1-Cycle Same-Slot RDW Pipeline Hazard Stress
        // =====================================================================
        seen_unlock = '0;
        @(negedge clk); read_addr[0] = s_loc2;
        @(posedge clk);
        // Cycle 1: EXPECT_TX(1), keep read_addr on s_loc2
        @(negedge clk); req_valid[0] = 1'b1; req_wid[0] = 0; req_data[0] = mk_bar(3, 1, 0, 0, 0, 1, 0);
        @(posedge clk);
        // Cycle 2: W0 SYNC (size=2), keep read_addr on s_loc2
        @(negedge clk); req_valid[0] = 1'b1; req_wid[0] = 0; req_data[0] = mk_bar(3, 0, 0, 1, 1, 0, 1);
        @(posedge clk);
        // Cycle 3: W1 SYNC (all warps arrived, ev=+1), keep read_addr on s_loc2
        @(negedge clk); req_valid[0] = 1'b1; req_wid[0] = 1; req_data[0] = mk_bar(3, 0, 0, 1, 1, 0, 1);
        @(posedge clk);
        // Cycle 4: txbar (-1 -> completes Epoch 0, flips phase 0->1!), keep read_addr on s_loc2!
        @(negedge clk); req_valid[0] = 1'b1; req_wid[0] = 2; req_data[0] = mk_bar(3, 1, 0, 0, 0, 0, 0);
        #1;
        if (read_phase[0] !== 1'b1) fail_now("Phase 3: combinational RDW read_phase failed to forward new phase=1");
        @(posedge clk);
        // Cycle 5: Immediate Epoch 1 W2 WAIT(phase=0) using forwarded phase_r=1 -> immediate unlock!
        @(negedge clk); req_valid[0] = 1'b1; req_wid[0] = 2; req_data[0] = mk_bar(3, 0, 0, 0, 0, 0, 1);
        @(posedge clk);
        @(negedge clk); req_valid[0] = 1'b0;
        wait_core_unlock(0, NUM_WARPS'('b111), 6, "P3_b2b_rdw");

        // =====================================================================
        // PHASE 4: Global Barriers — Async req_wid Guard, Subset Under Local Flood & Multi-ID
        // =====================================================================
        seen_unlock = '0;
        for (int c = 0; c < NUM_CORES; c++) active_warps[c] = NUM_WARPS'('b0011);

        // 4A: Global barrier id=0 across all NUM_CORES, with Core 0 async event carrying req_wid=1 before W1 arrives!
        send_bar_1c(0, BAR_ADDR_W'(0), 0, mk_bar(0, 1, 1, 0, 0, 1, 0), ph0); // Core 0 EXPECT_TX(1)
        send_bar_1c(0, BAR_ADDR_W'(0), 0, mk_bar(0, 0, 1, 1, 1, 0, NUM_CORES-1), ph0); // Core 0 W0 SYNC
        // Async txbar on Core 0 with req_wid=1 BEFORE Core 0 W1 arrived!
        send_bar_1c(0, BAR_ADDR_W'(0), 1, mk_bar(0, 1, 1, 0, 0, 0, 0), ph0);
        for (int c = 1; c < NUM_CORES; c++) begin
            send_bar_1c(c, BAR_ADDR_W'(0), 0, mk_bar(0, 0, 1, 1, 1, 0, NUM_CORES-1), ph0);
            send_bar_1c(c, BAR_ADDR_W'(0), 1, mk_bar(0, 0, 1, 1, 1, 0, NUM_CORES-1), ph1);
        end
        repeat (10) @(posedge clk);
        if (seen_unlock != '0)
            fail_now("Phase 4A: global barrier prematurely unlocked before Core 0 W1 arrived!");
        // Now Core 0 W1 arrives -> all cores unlock!
        send_bar_1c(0, BAR_ADDR_W'(0), 1, mk_bar(0, 0, 1, 1, 1, 0, NUM_CORES-1), ph1);
        for (int c = 0; c < NUM_CORES; c++)
            wait_core_unlock(c, NUM_WARPS'('b0011), 24, "P4A_global_all");
        @(negedge clk); read_addr[0] = BAR_ADDR_W'(0); #1;
        if (read_phase[0] !== 1'b1)
            fail_now("Phase 4A: global barrier broadcast did not toggle slot 0 read_phase to 1!");

        // 4B: 4 consecutive subset global barriers while non-participating cores hold req_valid=1 every cycle!
        begin
            int sub_cores = (NUM_CORES >= 4) ? 2 : 1;
            fork
                begin
                    @(negedge clk);
                    for (int c = sub_cores; c < NUM_CORES; c++) read_addr[c] = s_loc0;
                    @(posedge clk);
                    for (int k = 0; k < 68; k++) begin
                        @(negedge clk);
                        for (int c = sub_cores; c < NUM_CORES; c++) begin
                            read_addr[c] = s_loc0;
                            req_valid[c] = 1'b1;
                            req_wid[c]   = 0;
                            req_data[c]  = mk_bar(1, 1, 0, 0, 0, (k[0] ? 1'b0 : 1'b1), 0);
                        end
                        @(posedge clk);
                    end
                    @(negedge clk);
                    for (int c = sub_cores; c < NUM_CORES; c++) req_valid[c] = 1'b0;
                end
                begin
                    for (int rep = 0; rep < 4; rep++) begin
                        seen_unlock = '0;
                        for (int c = 0; c < sub_cores; c++) begin
                            send_bar_1c(c, BAR_ADDR_W'(1), 0, mk_bar(1, 0, 1, 1, 1, 0, sub_cores-1), ph0);
                            send_bar_1c(c, BAR_ADDR_W'(1), 1, mk_bar(1, 0, 1, 1, 1, 0, sub_cores-1), ph1);
                        end
                        for (int c = 0; c < sub_cores; c++)
                            wait_core_unlock(c, NUM_WARPS'('b0011), 20, "P4B_subset_under_flood");
                    end
                end
            join
        end

        // 4C: Simultaneous local + global unlock collision on Core 0 (slot s_loc2 vs gbar id=2)
        seen_unlock = '0;
        for (int c = 0; c < NUM_CORES; c++) active_warps[c] = NUM_WARPS'('b0011);
        for (int c = 0; c < NUM_CORES - 1; c++) begin
            send_bar_1c(c, BAR_ADDR_W'(2), 0, mk_bar(2, 0, 1, 1, 1, 0, NUM_CORES-1), ph0);
            send_bar_1c(c, BAR_ADDR_W'(2), 1, mk_bar(2, 0, 1, 1, 1, 0, NUM_CORES-1), ph1);
        end
        send_bar_1c(NUM_CORES-1, BAR_ADDR_W'(2), 0, mk_bar(2, 0, 1, 1, 1, 0, NUM_CORES-1), ph0);
        begin
            int base_w2;
            dup_check_en = 1'b0;
            @(negedge clk);
            base_w2 = core0_w2_pulses;
            read_addr[0] = s_loc2;
            read_addr[NUM_CORES-1] = BAR_ADDR_W'(2);
            @(posedge clk);
            // Fire final Core (NUM_CORES-1) W1 global arrival while Core 0 fires 10 consecutive 1-warp local SYNCs on s_loc2!
            for (int k = 0; k < 10; k++) begin
                @(negedge clk);
                req_valid[0] = 1'b1;
                req_wid[0]   = NW_WIDTH'(2);
                req_data[0]  = mk_bar(3, 0, 0, 1, 1, 0, 0);
                if (k == 0) begin
                    req_valid[NUM_CORES-1] = 1'b1;
                    req_wid[NUM_CORES-1]   = NW_WIDTH'(1);
                    req_data[NUM_CORES-1]  = mk_bar(2, 0, 1, 1, 1, 0, NUM_CORES-1);
                end else begin
                    req_valid[NUM_CORES-1] = 1'b0;
                end
                @(posedge clk);
            end
            @(negedge clk);
            req_valid[0] = 1'b0;
            repeat (4) @(posedge clk);
            if ((core0_w2_pulses - base_w2) != 10)
                fail_now($sformatf("Phase 4C: lost local W2 unlock on global broadcast collision (%0d != 10)", core0_w2_pulses - base_w2));
            for (int c = 0; c < NUM_CORES; c++)
                wait_core_unlock(c, NUM_WARPS'('b0011), 6, "P4C_global_collision");
            dup_check_en = 1'b1;
        end

        // 4D: Back-to-back 4-ID global barriers (id=3, id=2, id=0, id=1) under rsp_ready stall on id=3
        seen_unlock = '0;
        active_warps[0] = NUM_WARPS'('b0001);
        active_warps[1] = NUM_WARPS'('b0001);
        for (int c = 2; c < NUM_CORES; c++) active_warps[c] = '0;
        send_bar_1c(0, BAR_ADDR_W'(3), 0, mk_bar(3, 0, 1, 1, 0, 0, 1), ph0);
        send_bar_1c(0, BAR_ADDR_W'(3), 1, mk_bar(3, 0, 1, 0, 0, ph0, 1), ph2);
        send_bar_1c(0, BAR_ADDR_W'(2), 0, mk_bar(2, 0, 1, 1, 0, 0, 1), ph0);
        send_bar_1c(0, BAR_ADDR_W'(2), 3, mk_bar(2, 0, 1, 0, 0, ph0, 1), ph2);
        send_bar_1c(0, BAR_ADDR_W'(0), 0, mk_bar(0, 0, 1, 1, 0, 0, 1), ph0);
        send_bar_1c(0, BAR_ADDR_W'(0), 2, mk_bar(0, 0, 1, 0, 0, ph0, 1), ph2);
        send_bar_1c(0, BAR_ADDR_W'(1), 0, mk_bar(1, 0, 1, 1, 1, 0, 1), ph1);
        // Core 1 completes id=3, id=2, id=0, id=1 while Core 0 stalls slot 3 for 18 cycles!
        begin
            fork
                begin
                    @(negedge clk); read_addr[0] = BAR_ADDR_W'(3); @(posedge clk);
                    for (int k = 0; k < 18; k++) begin
                        @(negedge clk);
                        read_addr[0] = BAR_ADDR_W'(3);
                        req_valid[0] = 1'b1;
                        req_wid[0]   = NW_WIDTH'(2);
                        req_data[0]  = mk_bar(3, 1, 1, 0, 0, (k[0] ? 1'b0 : 1'b1), 0);
                        @(posedge clk);
                    end
                    @(negedge clk); req_valid[0] = 1'b0;
                end
                begin
                    send_bar_1c(1, BAR_ADDR_W'(3), 0, mk_bar(3, 0, 1, 1, 0, 0, 1), ph2);
                    send_bar_1c(1, BAR_ADDR_W'(2), 0, mk_bar(2, 0, 1, 1, 0, 0, 1), ph2);
                    send_bar_1c(1, BAR_ADDR_W'(0), 0, mk_bar(0, 0, 1, 1, 1, 0, 1), ph0);
                    send_bar_1c(1, BAR_ADDR_W'(1), 0, mk_bar(1, 0, 1, 1, 0, 0, 1), ph1);
                end
            join
            wait_core_unlock(0, NUM_WARPS'('b1111), 28, "P4D_multi_id_c0");
            wait_core_unlock(1, NUM_WARPS'('b0001), 28, "P4D_multi_id_c1");
        end
        for (int c = 0; c < NUM_CORES; c++) active_warps[c] = {NUM_WARPS{1'b1}};

        // =====================================================================
        // PHASE 5: Seed-Driven Randomized Split-Phase + Signed OOO Event Stress
        // =====================================================================
        begin
            int rng;
            rng = seed * 7919 + 17;
            for (int ep = 0; ep < 6; ep++) begin
                int n_ev, sync_mask_exp, perm_off;
                logic cur_ph;
                seen_unlock   = '0;
                rng           = (rng * 1103515245 + 12345) & 32'h7fffffff;
                n_ev          = 2 + (rng % 2);
                perm_off      = (rng >> 4) % NUM_WARPS;
                sync_mask_exp = 0;
                @(negedge clk); read_addr[0] = s_loc0; #1; cur_ph = read_phase[0];
                // Pre-deliver (n_ev - 1 >= 1) txbar events BEFORE expect_tx (negative balance)
                for (int e = 0; e < n_ev - 1; e++)
                    send_bar_1c(0, s_loc0, e % NUM_WARPS, mk_bar(1, 1, 0, 0, 0, 0, 0), ph0);
                // Permuted warp arrivals (mix of ARRIVE and SYNC; ensure >=1 SYNC)
                for (int k = 0; k < NUM_WARPS; k++) begin
                    int w;
                    bit do_sync;
                    w       = (k + perm_off) % NUM_WARPS;
                    do_sync = (k == NUM_WARPS - 1) ? 1'b1 : bit'((rng >> (8 + k)) & 1);
                    if (do_sync) sync_mask_exp |= (1 << w);
                    send_bar_1c(0, s_loc0, w, mk_bar(1, 0, 0, 1, do_sync, cur_ph, NUM_WARPS - 1), ph0);
                end
                // Register expect_tx(n_ev), then deliver final txbar completion!
                send_bar_1c(0, s_loc0, 0, mk_bar(1, 1, 0, 0, 0, 1, n_ev - 1), ph0);
                if (seen_unlock[0] != '0)
                    fail_now($sformatf("Phase 5 ep=%0d: unlocked with 1 remaining event", ep));
                send_bar_1c(0, s_loc0, 1, mk_bar(1, 1, 0, 0, 0, 0, 0), ph0);
                wait_core_unlock(0, NUM_WARPS'(sync_mask_exp), 8, "P5_rand_split_ev");
                if (seen_unlock[0] != NUM_WARPS'(sync_mask_exp))
                    fail_now($sformatf("Phase 5 ep=%0d: unlock mask mismatch got=%b exp=%b", ep, seen_unlock[0], NUM_WARPS'(sync_mask_exp)));
            end
        end

        if (err_cnt == 0) begin
            $display("PASS_CLUSTER_BAR (C=%0d, W=%0d, seed=%0d)", NUM_CORES, NUM_WARPS, seed);
            $finish;
        end else begin
            $fatal(1, "FAIL_CLUSTER_BAR errors=%0d", err_cnt);
        end
    end
endmodule
