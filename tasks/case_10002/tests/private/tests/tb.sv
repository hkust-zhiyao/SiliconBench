`timescale 1ns/1ps
`include "define.tmp.h"
`include "network_define.v"

module tb;
    reg clk;
    reg reset;

    // 1. Standalone dynamic_input_control instance
    wire ic_thanks_all;
    wire ic_req_n, ic_req_e, ic_req_s, ic_req_w, ic_req_p;
    wire ic_def_n, ic_def_e, ic_def_s, ic_def_w, ic_def_p;
    wire ic_tail;
    reg  [7:0]  ic_my_x, ic_my_y, ic_abs_x, ic_abs_y, ic_len;
    reg  [13:0] ic_my_chip, ic_abs_chip;
    reg  [2:0]  ic_fbits;
    reg         ic_valid;
    reg         ic_th_n, ic_th_e, ic_th_s, ic_th_w, ic_th_p;

    dynamic_input_control u_ic (
        .thanks_all_temp_out(ic_thanks_all),
        .route_req_n_out(ic_req_n),
        .route_req_e_out(ic_req_e),
        .route_req_s_out(ic_req_s),
        .route_req_w_out(ic_req_w),
        .route_req_p_out(ic_req_p),
        .default_ready_n(ic_def_n),
        .default_ready_e(ic_def_e),
        .default_ready_s(ic_def_s),
        .default_ready_w(ic_def_w),
        .default_ready_p(ic_def_p),
        .tail_out(ic_tail),
        .clk(clk),
        .reset(reset),
        .my_loc_x_in(ic_my_x),
        .my_loc_y_in(ic_my_y),
        .my_chip_id_in(ic_my_chip),
        .abs_x(ic_abs_x),
        .abs_y(ic_abs_y),
        .abs_chip_id(ic_abs_chip),
        .final_bits(ic_fbits),
        .valid_in(ic_valid),
        .thanks_n(ic_th_n),
        .thanks_e(ic_th_e),
        .thanks_s(ic_th_s),
        .thanks_w(ic_th_w),
        .thanks_p(ic_th_p),
        .length(ic_len)
    );

    // 2. Standalone dynamic_output_control instance
    wire oc_th_a, oc_th_b, oc_th_c, oc_th_d, oc_th_x;
    wire oc_valid_out;
    wire [2:0] oc_curr_route;
    wire oc_ec_stall;
    reg  oc_req_a, oc_req_b, oc_req_c, oc_req_d, oc_req_x;
    reg  oc_tail_a, oc_tail_b, oc_tail_c, oc_tail_d, oc_tail_x;
    reg  oc_val_temp, oc_def_rdy, oc_spc_avail;

    dynamic_output_control u_oc (
        .thanks_a(oc_th_a),
        .thanks_b(oc_th_b),
        .thanks_c(oc_th_c),
        .thanks_d(oc_th_d),
        .thanks_x(oc_th_x),
        .valid_out(oc_valid_out),
        .current_route(oc_curr_route),
        .ec_wants_to_send_but_cannot(oc_ec_stall),
        .clk(clk),
        .reset(reset),
        .route_req_a_in(oc_req_a),
        .route_req_b_in(oc_req_b),
        .route_req_c_in(oc_req_c),
        .route_req_d_in(oc_req_d),
        .route_req_x_in(oc_req_x),
        .tail_a_in(oc_tail_a),
        .tail_b_in(oc_tail_b),
        .tail_c_in(oc_tail_c),
        .tail_d_in(oc_tail_d),
        .tail_x_in(oc_tail_x),
        .valid_out_temp(oc_val_temp),
        .default_ready(oc_def_rdy),
        .space_avail(oc_spc_avail)
    );

    // 3. Full 5-port router instance (dynamic_node_top_wrap)
    reg  [63:0] dn_in_N, dn_in_E, dn_in_S, dn_in_W, dn_in_P;
    reg         dn_val_N, dn_val_E, dn_val_S, dn_val_W, dn_val_P;
    reg         dn_yum_N, dn_yum_E, dn_yum_S, dn_yum_W, dn_yum_P;
    wire [63:0] dn_out_N, dn_out_E, dn_out_S, dn_out_W, dn_out_P;
    wire        dn_vout_N, dn_vout_E, dn_vout_S, dn_vout_W, dn_vout_P;
    wire        dn_yout_N, dn_yout_E, dn_yout_S, dn_yout_W, dn_yout_P;
    wire        dn_th_P;

    dynamic_node_top_wrap u_router (
        .clk(clk),
        .reset_in(reset),
        .dataIn_N(dn_in_N), .dataIn_E(dn_in_E), .dataIn_S(dn_in_S), .dataIn_W(dn_in_W), .dataIn_P(dn_in_P),
        .validIn_N(dn_val_N), .validIn_E(dn_val_E), .validIn_S(dn_val_S), .validIn_W(dn_val_W), .validIn_P(dn_val_P),
        .yummyIn_N(dn_yum_N), .yummyIn_E(dn_yum_E), .yummyIn_S(dn_yum_S), .yummyIn_W(dn_yum_W), .yummyIn_P(dn_yum_P),
        .myLocX(8'd2), .myLocY(8'd2), .myChipID(14'd1),
        .dataOut_N(dn_out_N), .dataOut_E(dn_out_E), .dataOut_S(dn_out_S), .dataOut_W(dn_out_W), .dataOut_P(dn_out_P),
        .validOut_N(dn_vout_N), .validOut_E(dn_vout_E), .validOut_S(dn_vout_S), .validOut_W(dn_vout_W), .validOut_P(dn_vout_P),
        .yummyOut_N(dn_yout_N), .yummyOut_E(dn_yout_E), .yummyOut_S(dn_yout_S), .yummyOut_W(dn_yout_W), .yummyOut_P(dn_yout_P),
        .thanksIn_P(dn_th_P)
    );

    initial clk = 1'b0;
    always #2.5 clk = ~clk;

    initial begin
        #400000;
        $display("TB_FAIL: Simulation watchdog timeout");
        $finish(1);
    end

    // Auto-return yummy credits on router outputs 1 cycle after validOut
    always @(posedge clk) begin
        if (reset) begin
            dn_yum_N <= 1'b0; dn_yum_E <= 1'b0; dn_yum_S <= 1'b0; dn_yum_W <= 1'b0; dn_yum_P <= 1'b0;
        end else begin
            dn_yum_N <= dn_vout_N;
            dn_yum_E <= dn_vout_E;
            dn_yum_S <= dn_vout_S;
            dn_yum_W <= dn_vout_W;
            dn_yum_P <= dn_vout_P;
        end
    end

    integer seed, err_cnt, i, j, k;
    reg [4:0] exp_req;
    reg [7:0] eff_x, eff_y;

    initial begin
        if (!$value$plusargs("SEED=%d", seed)) seed = 1;
        err_cnt = 0;

        reset = 1'b1;
        ic_my_x = 8'd2; ic_my_y = 8'd2; ic_my_chip = 14'd1;
        ic_abs_x = 8'd2; ic_abs_y = 8'd2; ic_abs_chip = 14'd1;
        ic_fbits = 3'd0; ic_valid = 1'b0; ic_len = 8'd0;
        ic_th_n = 1'b0; ic_th_e = 1'b0; ic_th_s = 1'b0; ic_th_w = 1'b0; ic_th_p = 1'b0;

        // Drive oc_val_temp=1, oc_def_rdy=1, oc_spc_avail=0 during reset to verify ec_wants_to_send_but_cannot resets to 0!
        oc_req_a = 1'b0; oc_req_b = 1'b0; oc_req_c = 1'b0; oc_req_d = 1'b0; oc_req_x = 1'b0;
        oc_tail_a = 1'b0; oc_tail_b = 1'b0; oc_tail_c = 1'b0; oc_tail_d = 1'b0; oc_tail_x = 1'b0;
        oc_val_temp = 1'b1; oc_def_rdy = 1'b1; oc_spc_avail = 1'b0;

        dn_in_N = 64'd0; dn_in_E = 64'd0; dn_in_S = 64'd0; dn_in_W = 64'd0; dn_in_P = 64'd0;
        dn_val_N = 1'b0; dn_val_E = 1'b0; dn_val_S = 1'b0; dn_val_W = 1'b0; dn_val_P = 1'b0;

        repeat (3) @(negedge clk);
        if (oc_ec_stall !== 1'b0 || oc_curr_route !== 3'd0 ||
            ({oc_th_a, oc_th_b, oc_th_c, oc_th_d, oc_th_x} !== 5'b00000)) begin
            $display("TB_FAIL: dynamic_output_control reset state invalid: ec=%b route=%b th=%b",
                     oc_ec_stall, oc_curr_route, {oc_th_a, oc_th_b, oc_th_c, oc_th_d, oc_th_x});
            err_cnt = err_cnt + 1;
        end
        oc_val_temp = 1'b0; oc_def_rdy = 1'b0; oc_spc_avail = 1'b1;

        // Test 1: Check 8-bit reset of dynamic_input_control after loading length = 8'hE0 (lower 5 bits [4:0] = 5'd0, upper bits [7:5] = 3'b111)
        reset = 1'b0;
        ic_valid = 1'b1;
        ic_len   = 8'hE0; // 224 flits (lower 5 bits are 0!)
        ic_th_p  = 1'b1;
        @(negedge clk); // Header accepted with length=8'hE0
        ic_th_p  = 1'b0;
        reset    = 1'b1;
        @(negedge clk); // Reset asserted: all 8 bits of count must clear to 0!
        reset    = 1'b0;
        ic_len   = 8'd0;
        #1;
        if (ic_req_p !== 1'b1 || ic_tail !== 1'b1) begin
            $display("TB_FAIL: 8-bit count_f did not clear upper bits [7:5] on reset: req_p=%b tail=%b", ic_req_p, ic_tail);
            err_cnt = err_cnt + 1;
        end
        ic_th_p  = 1'b1;
        @(negedge clk);
        ic_th_p  = 1'b0;
        ic_valid = 1'b0;

        // Test 2: Exhaustive XY routing & final_bits check (including off-chip and all 8 final_bits codes 0..7)
        for (i = 0; i < 200; i = i + 1) begin
            ic_my_x    = ($urandom(seed)) & 8'hFF;
            ic_my_y    = ($urandom(seed)) & 8'hFF;
            ic_my_chip = ($urandom(seed)) & 14'h3FFF;
            if ((i % 4) == 0) begin
                ic_abs_chip = ic_my_chip ^ (14'd1 << (i % 14)); // off-chip!
                ic_abs_x    = ($urandom(seed)) & 8'hFF;
                ic_abs_y    = ($urandom(seed)) & 8'hFF;
                eff_x       = 8'd0;
                eff_y       = 8'd0;
            end else begin
                ic_abs_chip = ic_my_chip;
                ic_abs_x    = ((i % 3) == 1) ? ic_my_x : (($urandom(seed)) & 8'hFF);
                ic_abs_y    = ((i % 3) == 1) ? ic_my_y : (($urandom(seed)) & 8'hFF);
                eff_x       = ic_abs_x;
                eff_y       = ic_abs_y;
            end
            ic_fbits = i[2:0];
            ic_valid = 1'b1;
            #1;
            exp_req = 5'b00000;
            if (eff_x > ic_my_x)      exp_req[3] = 1'b1; // East
            else if (eff_x < ic_my_x) exp_req[1] = 1'b1; // West
            else if (eff_y < ic_my_y) exp_req[4] = 1'b1; // North
            else if (eff_y > ic_my_y) exp_req[2] = 1'b1; // South
            else begin
                case (ic_fbits)
                    3'b101:  exp_req[4] = 1'b1; // FINAL_NORTH
                    3'b100:  exp_req[3] = 1'b1; // FINAL_EAST
                    3'b011:  exp_req[2] = 1'b1; // FINAL_SOUTH
                    3'b010:  exp_req[1] = 1'b1; // FINAL_WEST
                    default: exp_req[0] = 1'b1; // FINAL_NONE or unallocated -> proc
                endcase
            end
            if ({ic_req_n, ic_req_e, ic_req_s, ic_req_w, ic_req_p} !== exp_req ||
                {ic_def_n, ic_def_e, ic_def_s, ic_def_w, ic_def_p} !== exp_req) begin
                $display("TB_FAIL: route_request_calc mismatch at i=%0d fbits=%b: got=%b def=%b exp=%b",
                         i, ic_fbits, {ic_req_n, ic_req_e, ic_req_s, ic_req_w, ic_req_p},
                         {ic_def_n, ic_def_e, ic_def_s, ic_def_w, ic_def_p}, exp_req);
                err_cnt = err_cnt + 1;
            end
            {ic_th_n, ic_th_e, ic_th_s, ic_th_w, ic_th_p} = exp_req;
            @(negedge clk);
            {ic_th_n, ic_th_e, ic_th_s, ic_th_w, ic_th_p} = 5'b00000;
            ic_valid = 1'b0;
        end

        reset = 1'b1;
        @(negedge clk);
        reset = 1'b0;

        // Test 3: Multi-flit packet framing with length = 140 (> 127, tests bit 7 of length!) and mid-packet bubbles/stalls
        ic_my_x = 8'd2; ic_my_y = 8'd2; ic_my_chip = 14'd1;
        ic_abs_x = 8'd5; ic_abs_y = 8'd2; ic_abs_chip = 14'd1; // East
        ic_fbits = 3'b000;
        ic_len = 8'd140;
        ic_valid = 1'b1;
        ic_th_e = 1'b0;
        @(negedge clk); // stalled header cycle
        if (ic_req_e !== 1'b1 || ic_tail !== 1'b0) begin
            $display("TB_FAIL: stalled header state wrong");
            err_cnt = err_cnt + 1;
        end
        ic_th_e = 1'b1;
        @(negedge clk); // header granted! Now 140 body flits remain
        for (i = 140; i >= 1; i = i - 1) begin
            if (i == 70 || i == 1) begin
                ic_valid = 1'b0;
                ic_th_e  = 1'b0;
                @(negedge clk);
                if (ic_req_e !== 1'b0 || ic_tail !== (i == 1)) begin
                    $display("TB_FAIL: body beat %0d bubble state wrong: req_e=%b tail=%b", i, ic_req_e, ic_tail);
                    err_cnt = err_cnt + 1;
                end
                ic_valid = 1'b1;
                ic_th_e  = 1'b0;
                @(negedge clk);
                if (ic_req_e !== 1'b0 || ic_tail !== (i == 1)) begin
                    $display("TB_FAIL: body beat %0d stall state wrong: req_e=%b tail=%b", i, ic_req_e, ic_tail);
                    err_cnt = err_cnt + 1;
                end
            end
            ic_valid = 1'b1;
            #1;
            if (ic_req_e !== 1'b0 || ic_tail !== (i == 1)) begin
                $display("TB_FAIL: body beat %0d active state wrong: req_e=%b tail=%b", i, ic_req_e, ic_tail);
                err_cnt = err_cnt + 1;
            end
            ic_th_e = 1'b1;
            @(negedge clk);
        end
        ic_th_e = 1'b0;
        #1;
        if (ic_req_e !== 1'b1) begin
            $display("TB_FAIL: did not return to header state after 140 body beats");
            err_cnt = err_cnt + 1;
        end

        // Test 4: Output control back-to-back self-regrant AND multi-beat lock against preemption
        reset = 1'b1;
        @(negedge clk);
        reset = 1'b0;
        oc_spc_avail = 1'b1;
        oc_val_temp  = 1'b1;
        oc_def_rdy   = 1'b0;
        oc_req_b     = 1'b1;
        oc_tail_b    = 1'b0;
        @(negedge clk); // Route B planned!
        if (oc_curr_route !== 3'b001 || oc_th_b !== 1'b1) begin
            $display("TB_FAIL: Route B not planned on cycle 1: route=%b th_b=%b", oc_curr_route, oc_th_b);
            err_cnt = err_cnt + 1;
        end
        // Beat 0 of Route B transfers on next posedge while tail_b == 0 AND Route C asserts a competing request!
        // Route B MUST stay locked (must NOT be preempted by Route C before tail_b == 1)!
        oc_req_b  = 1'b0;
        oc_tail_b = 1'b0;
        oc_req_c  = 1'b1;
        oc_tail_c = 1'b1;
        @(negedge clk);
        if (oc_curr_route !== 3'b001 || oc_th_b !== 1'b1) begin
            $display("TB_FAIL: Route B was preempted mid-packet before tail flit: route=%b", oc_curr_route);
            err_cnt = err_cnt + 1;
        end
        // Now finish Route B's packet on a back-to-back single-flit stream (with Route C withdrawn)
        oc_req_c  = 1'b0;
        oc_req_b  = 1'b1;
        oc_tail_b = 1'b1;
        @(negedge clk); // Packet 1 finishes on this edge; since oc_req_b=1 and nobody else requests, Route B must stay on 001!
        if (oc_curr_route !== 3'b001) begin
            $display("TB_FAIL: Route B lost grant on back-to-back single-flit stream (dropped to route %b)", oc_curr_route);
            err_cnt = err_cnt + 1;
        end

        // Test 5: Output control ROUTE_D priority order (D -> X -> A -> B -> C -> D)
        if (oc_th_b === 1'b1) begin
            oc_req_b = 1'b0; oc_tail_b = 1'b1;
            @(negedge clk);
        end
        oc_req_b = 1'b0; oc_tail_b = 1'b0;
        oc_req_d = 1'b1; oc_tail_d = 1'b1;
        @(negedge clk); // Now on Route D!
        if (oc_curr_route !== 3'b011) begin
            $display("TB_FAIL: Expected Route D (011), got %b", oc_curr_route);
            err_cnt = err_cnt + 1;
        end
        // While Route D finishes its 1-flit packet, both Route C and Route X request!
        // After Route D, rotating priority MUST pick Route X (100), NOT Route C (010)!
        oc_req_d = 1'b0;
        oc_req_c = 1'b1; oc_tail_c = 1'b1;
        oc_req_x = 1'b1; oc_tail_x = 1'b1;
        @(negedge clk);
        if (oc_curr_route !== 3'b100) begin
            $display("TB_FAIL: After Route D, expected Route X (100) over Route C (010), got %b", oc_curr_route);
            err_cnt = err_cnt + 1;
        end

        // Test 6: Starvation / fairness across idle gaps!
        // Let Route B be granted and finish its 1-flit packet with NO other requests pending on that cycle,
        // so the output port goes completely IDLE (planned_f = 0, current_route_f drops to ROUTE_A = 000)!
        oc_req_c = 1'b0; oc_req_x = 1'b0;
        oc_req_b = 1'b1; oc_tail_b = 1'b1;
        @(negedge clk); // Route B is now planned (current_route_f == 001)
        // On this cycle, Route B transfers its tail flit (valid_out_temp=1, tail_b=1) while oc_req_* are ALL 0!
        oc_req_b = 1'b0;
        @(negedge clk); // Packet on Route B finished; output is now IDLE (planned_f == 0)!
        oc_val_temp = 1'b0;
        @(negedge clk); // Idle cycle 1
        @(negedge clk); // Idle cycle 2
        // Now both Route B and Route C assert requests simultaneously!
        // Because Route B was the last route served before the idle gap, Route C (010) MUST win over Route B (001)!
        oc_val_temp = 1'b1;
        oc_req_b = 1'b1; oc_tail_b = 1'b1;
        oc_req_c = 1'b1; oc_tail_c = 1'b1;
        @(negedge clk);
        if (oc_curr_route !== 3'b010) begin
            $display("TB_FAIL: Idle gap reset round-robin history! Route B starved Route C (got route %b, expected 010)", oc_curr_route);
            err_cnt = err_cnt + 1;
        end

        // Test 7: Full 5-port router integration test (multi-port contention + 36-flit packet through dynamic_node_top_wrap)
        reset = 1'b1;
        @(negedge clk);
        @(negedge clk);
        reset = 1'b0;
        @(negedge clk);
        @(negedge clk);

        fork
            begin : inject_pkt
                integer n_cred;
                n_cred = 4;
                dn_val_N = 1'b1;
                dn_in_N  = {14'd1, 8'd5, 8'd2, 4'd0, 8'd35, 22'h15_5555};
                n_cred   = n_cred - 1;
                @(negedge clk);
                if (dn_yout_N) n_cred = n_cred + 1;
                dn_val_N = 1'b0;
                @(negedge clk);
                if (dn_yout_N) n_cred = n_cred + 1;
                dn_val_W = 1'b1;
                dn_in_W  = {14'd1, 8'd4, 8'd2, 4'd0, 8'd0, 22'h2A_AAAA};
                for (i = 1; i <= 35; i = i - 0 + 1) begin
                    while (n_cred == 0) begin
                        dn_val_N = 1'b0;
                        @(negedge clk);
                        dn_val_W = 1'b0;
                        if (dn_yout_N) n_cred = n_cred + 1;
                    end
                    dn_val_N = 1'b1;
                    dn_in_N  = 64'hCAFE_0000_0000_0000 | i;
                    n_cred   = n_cred - 1;
                    @(negedge clk);
                    dn_val_W = 1'b0;
                    if (dn_yout_N) n_cred = n_cred + 1;
                end
                dn_val_N = 1'b0;
            end
            begin : monitor_east
                j = 0;
                for (k = 0; k < 200; k = k + 1) begin
                    @(posedge clk);
                    if (dn_vout_E) begin
                        j = j + 1;
                        if (j == 1 && dn_out_E !== {14'd1, 8'd5, 8'd2, 4'd0, 8'd35, 22'h15_5555}) begin
                            $display("TB_FAIL: Router East flit 1 mismatch: %016x", dn_out_E);
                            err_cnt = err_cnt + 1;
                        end else if (j > 1 && j <= 36 && dn_out_E !== (64'hCAFE_0000_0000_0000 | (j - 1))) begin
                            $display("TB_FAIL: Router East flit %0d mismatch: got %016x (West packet interleaved early!)", j, dn_out_E);
                            err_cnt = err_cnt + 1;
                        end else if (j == 37 && dn_out_E !== {14'd1, 8'd4, 8'd2, 4'd0, 8'd0, 22'h2A_AAAA}) begin
                            $display("TB_FAIL: Router East flit 37 (West packet) mismatch: got %016x", dn_out_E);
                            err_cnt = err_cnt + 1;
                        end
                    end
                end
            end
        join
        if (j !== 37) begin
            $display("TB_FAIL: Expected 37 total flits on East output, got %0d", j);
            err_cnt = err_cnt + 1;
        end

        if (err_cnt == 0) begin
            $display("TB_PASS: All router input/output/integration checks passed (seed=%0d)", seed);
            $finish(0);
        end else begin
            $display("TB_FAIL: %0d errors encountered", err_cnt);
            $finish(1);
        end
    end
endmodule
