`timescale 1ns/1ps
`include "define.tmp.h"
`include "network_define.v"

module tb;
    reg clk = 1'b0;
    always #2.5 clk = ~clk;

    initial begin
        #400000;
        $display("TB_FAIL: Simulation watchdog timeout");
        $finish(1);
    end

    reg reset;

    // 1. Standalone io_xbar_input_control instance
    wire ic_thanks_all;
    wire [7:0] ic_req;
    wire [7:0] ic_def;
    wire ic_tail;
    reg  [7:0]  ic_my_x, ic_my_y, ic_abs_x, ic_abs_y, ic_len;
    reg  [13:0] ic_my_chip, ic_abs_chip;
    reg  [2:0]  ic_fbits;
    reg         ic_valid;
    reg  [7:0]  ic_th;

    io_xbar_input_control u_ic (
        .thanks_all_temp_out(ic_thanks_all),
        .route_req_0_out(ic_req[0]), .route_req_1_out(ic_req[1]), .route_req_2_out(ic_req[2]), .route_req_3_out(ic_req[3]),
        .route_req_4_out(ic_req[4]), .route_req_5_out(ic_req[5]), .route_req_6_out(ic_req[6]), .route_req_7_out(ic_req[7]),
        .default_ready_0(ic_def[0]), .default_ready_1(ic_def[1]), .default_ready_2(ic_def[2]), .default_ready_3(ic_def[3]),
        .default_ready_4(ic_def[4]), .default_ready_5(ic_def[5]), .default_ready_6(ic_def[6]), .default_ready_7(ic_def[7]),
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
        .thanks_0(ic_th[0]), .thanks_1(ic_th[1]), .thanks_2(ic_th[2]), .thanks_3(ic_th[3]),
        .thanks_4(ic_th[4]), .thanks_5(ic_th[5]), .thanks_6(ic_th[6]), .thanks_7(ic_th[7]),
        .length(ic_len)
    );

    // 2. Standalone io_xbar_output_control instance
    wire [7:0] oc_th;
    wire oc_valid_out;
    wire [2:0] oc_curr_route;
    wire oc_ec_stall;
    reg  [7:0] oc_req;
    reg  [7:0] oc_tail;
    reg  oc_val_temp, oc_def_rdy, oc_spc_avail;

    io_xbar_output_control u_oc (
        .thanks_0(oc_th[0]), .thanks_1(oc_th[1]), .thanks_2(oc_th[2]), .thanks_3(oc_th[3]),
        .thanks_4(oc_th[4]), .thanks_5(oc_th[5]), .thanks_6(oc_th[6]), .thanks_7(oc_th[7]),
        .valid_out(oc_valid_out),
        .current_route(oc_curr_route),
        .ec_wants_to_send_but_cannot(oc_ec_stall),
        .clk(clk),
        .reset(reset),
        .route_req_0_in(oc_req[0]), .route_req_1_in(oc_req[1]), .route_req_2_in(oc_req[2]), .route_req_3_in(oc_req[3]),
        .route_req_4_in(oc_req[4]), .route_req_5_in(oc_req[5]), .route_req_6_in(oc_req[6]), .route_req_7_in(oc_req[7]),
        .tail_0_in(oc_tail[0]), .tail_1_in(oc_tail[1]), .tail_2_in(oc_tail[2]), .tail_3_in(oc_tail[3]),
        .tail_4_in(oc_tail[4]), .tail_5_in(oc_tail[5]), .tail_6_in(oc_tail[6]), .tail_7_in(oc_tail[7]),
        .valid_out_temp(oc_val_temp),
        .default_ready(oc_def_rdy),
        .space_avail(oc_spc_avail)
    );

    // 3. Integrated io_xbar_output_top instance
    wire [63:0] top_data_out;
    wire [7:0]  top_thanks;
    wire        top_valid_out;
    wire        top_pop_int, top_pop_mem;
    wire [9:0]  top_pop_sender;
    wire        top_ec_stall;
    reg  [7:0]  top_req, top_tail, top_valid_in;
    reg  [63:0] top_data_0, top_data_1, top_data_2, top_data_3, top_data_4, top_data_5, top_data_6, top_data_7;
    reg         top_def_rdy, top_yummy;

    io_xbar_output_top u_top (
        .data_out(top_data_out),
        .thanks_0_out(top_thanks[0]), .thanks_1_out(top_thanks[1]), .thanks_2_out(top_thanks[2]), .thanks_3_out(top_thanks[3]),
        .thanks_4_out(top_thanks[4]), .thanks_5_out(top_thanks[5]), .thanks_6_out(top_thanks[6]), .thanks_7_out(top_thanks[7]),
        .valid_out(top_valid_out),
        .popped_interrupt_mesg_out(top_pop_int),
        .popped_memory_ack_mesg_out(top_pop_mem),
        .popped_memory_ack_mesg_out_sender(top_pop_sender),
        .ec_wants_to_send_but_cannot(top_ec_stall),
        .clk(clk),
        .reset(reset),
        .route_req_0_in(top_req[0]), .route_req_1_in(top_req[1]), .route_req_2_in(top_req[2]), .route_req_3_in(top_req[3]),
        .route_req_4_in(top_req[4]), .route_req_5_in(top_req[5]), .route_req_6_in(top_req[6]), .route_req_7_in(top_req[7]),
        .tail_0_in(top_tail[0]), .tail_1_in(top_tail[1]), .tail_2_in(top_tail[2]), .tail_3_in(top_tail[3]),
        .tail_4_in(top_tail[4]), .tail_5_in(top_tail[5]), .tail_6_in(top_tail[6]), .tail_7_in(top_tail[7]),
        .data_0_in(top_data_0), .data_1_in(top_data_1), .data_2_in(top_data_2), .data_3_in(top_data_3),
        .data_4_in(top_data_4), .data_5_in(top_data_5), .data_6_in(top_data_6), .data_7_in(top_data_7),
        .valid_0_in(top_valid_in[0]), .valid_1_in(top_valid_in[1]), .valid_2_in(top_valid_in[2]), .valid_3_in(top_valid_in[3]),
        .valid_4_in(top_valid_in[4]), .valid_5_in(top_valid_in[5]), .valid_6_in(top_valid_in[6]), .valid_7_in(top_valid_in[7]),
        .default_ready_in(top_def_rdy),
        .yummy_in(top_yummy)
    );

    integer seed, err_cnt, i, p;
    reg [7:0] exp_req;

    initial begin
        if (!$value$plusargs("SEED=%d", seed)) seed = 1;
        err_cnt = 0;

        reset = 1'b1;
        ic_my_x = 8'd0; ic_my_y = 8'd0; ic_my_chip = 14'd1;
        ic_abs_x = 8'd0; ic_abs_y = 8'd0; ic_abs_chip = 14'd1;
        ic_fbits = 3'd0; ic_valid = 1'b0; ic_len = 8'd0;
        ic_th = 8'd0;

        oc_req = 8'd0; oc_tail = 8'd0;
        oc_val_temp = 1'b1; oc_def_rdy = 1'b1; oc_spc_avail = 1'b0;

        top_req = 8'd0; top_tail = 8'd0; top_valid_in = 8'd0;
        top_data_0 = 64'hA0; top_data_1 = 64'hA1; top_data_2 = 64'hA2; top_data_3 = 64'hA3;
        top_data_4 = 64'hA4; top_data_5 = 64'hA5; top_data_6 = 64'hA6; top_data_7 = 64'hA7;
        top_def_rdy = 1'b0; top_yummy = 1'b0;

        repeat (3) @(negedge clk);
        if (oc_ec_stall !== 1'b0 || oc_curr_route !== 3'd0 || oc_th !== 8'd0) begin
            $display("TB_FAIL: io_xbar_output_control reset state invalid: ec=%b route=%b th=%b",
                     oc_ec_stall, oc_curr_route, oc_th);
            err_cnt = err_cnt + 1;
        end
        oc_val_temp = 1'b0; oc_def_rdy = 1'b0; oc_spc_avail = 1'b1;

        // Test 1: Check 8-bit reset of io_xbar_input_control after loading length = 8'hE0 (lower 5 bits [4:0] = 5'd0, upper bits [7:5] = 3'b111)
        reset = 1'b0;
        ic_valid = 1'b1;
        ic_len   = 8'hE0;
        ic_th[0] = 1'b1;
        @(negedge clk);
        ic_th[0] = 1'b0;
        reset    = 1'b1;
        @(negedge clk);
        reset    = 1'b0;
        ic_len   = 8'd0;
        #1;
        if (ic_req[0] !== 1'b1 || ic_tail !== 1'b1) begin
            $display("TB_FAIL: 8-bit count_f did not clear upper bits [7:5] on reset: req0=%b tail=%b", ic_req[0], ic_tail);
            err_cnt = err_cnt + 1;
        end

        // Test 2: Exhaustive 8-port crossbar routing check (ports 0..7, off-chip, and abs_x >= 8 fallback to port 0)
        for (i = 0; i < 160; i = i + 1) begin
            ic_my_chip = 14'd5;
            if ((i % 4) == 0) begin
                ic_abs_chip = 14'd9; // off-chip -> must route to port 0!
                ic_abs_x    = i[7:0];
            end else begin
                ic_abs_chip = 14'd5; // on-chip
                ic_abs_x    = (i % 12); // tests 0..7 and unmapped 8..11!
            end
            ic_valid = 1'b1;
            #1;
            if (ic_abs_chip != ic_my_chip || ic_abs_x >= 8'd8 || ic_abs_x == 8'd0)
                exp_req = 8'b0000_0001;
            else
                exp_req = (8'b0000_0001 << ic_abs_x[2:0]);

            if (ic_req !== exp_req || ic_def !== exp_req) begin
                $display("TB_FAIL: io_xbar_route_request_calc mismatch at i=%0d abs_x=%0d off_chip=%b: got=%b def=%b exp=%b",
                         i, ic_abs_x, (ic_abs_chip != ic_my_chip), ic_req, ic_def, exp_req);
                err_cnt = err_cnt + 1;
            end
        end

        // Test 3: Multi-flit packet framing with length = 150 (> 127) and mid-packet bubbles/stalls on port 6
        reset       = 1'b1;
        @(negedge clk);
        reset       = 1'b0;
        ic_my_chip  = 14'd1;
        ic_abs_chip = 14'd1;
        ic_abs_x    = 8'd6;
        ic_len      = 8'd150;
        ic_valid    = 1'b1;
        ic_th       = 8'd0;
        @(negedge clk);
        if (ic_req !== 8'b0100_0000 || ic_tail !== 1'b0) begin
            $display("TB_FAIL: stalled header on port 6 wrong");
            err_cnt = err_cnt + 1;
        end
        ic_th[6] = 1'b1;
        @(negedge clk);
        for (i = 150; i >= 1; i = i - 1) begin
            if (i == 75 || i == 1) begin
                ic_valid = 1'b0;
                ic_th[6] = 1'b0;
                @(negedge clk);
                if (ic_req !== 8'd0 || ic_tail !== (i == 1)) begin
                    $display("TB_FAIL: body beat %0d bubble state wrong: req=%b tail=%b", i, ic_req, ic_tail);
                    err_cnt = err_cnt + 1;
                end
                ic_valid = 1'b1;
                ic_th[6] = 1'b0;
                @(negedge clk);
                if (ic_req !== 8'd0 || ic_tail !== (i == 1)) begin
                    $display("TB_FAIL: body beat %0d stall state wrong: req=%b tail=%b", i, ic_req, ic_tail);
                    err_cnt = err_cnt + 1;
                end
            end
            ic_valid = 1'b1;
            #1;
            if (ic_req !== 8'd0 || ic_tail !== (i == 1)) begin
                $display("TB_FAIL: body beat %0d active state wrong: req=%b tail=%b", i, ic_req, ic_tail);
                err_cnt = err_cnt + 1;
            end
            ic_th[6] = 1'b1;
            @(negedge clk);
        end
        ic_th[6] = 1'b0;
        #1;
        if (ic_req !== 8'b0100_0000) begin
            $display("TB_FAIL: did not return to header state after 150 body beats");
            err_cnt = err_cnt + 1;
        end

        // Test 4: Self-fallback on all 8 ports (ports 1..7) and multi-beat lock against preemption
        for (p = 1; p < 8; p = p + 1) begin
            reset = 1'b1;
            @(negedge clk);
            reset = 1'b0;
            oc_spc_avail = 1'b1;
            oc_val_temp  = 1'b1;
            oc_def_rdy   = 1'b0;
            oc_req       = (8'd1 << p);
            oc_tail      = 8'd0;
            @(negedge clk); // Port p planned!
            if (oc_curr_route !== p[2:0] || oc_th !== (8'd1 << p)) begin
                $display("TB_FAIL: Port %0d not planned on cycle 1: route=%b th=%b", p, oc_curr_route, oc_th);
                err_cnt = err_cnt + 1;
            end
            // Beat 0 of Port p transfers while oc_tail == 0 AND another port ((p % 7) + 1) requests!
            // Port p MUST stay locked (must NOT be preempted mid-packet before oc_tail == 1)!
            oc_req  = (8'd1 << ((p % 7) + 1));
            oc_tail = (8'd1 << ((p % 7) + 1));
            @(negedge clk);
            if (oc_curr_route !== p[2:0] || oc_th !== (8'd1 << p)) begin
                $display("TB_FAIL: Port %0d was preempted mid-packet before tail flit: route=%b", p, oc_curr_route);
                err_cnt = err_cnt + 1;
            end
            // Now test back-to-back single-flit self-regrant on port p (with contender withdrawn):
            oc_req  = (8'd1 << p);
            oc_tail = (8'd1 << p);
            @(negedge clk);
            if (oc_curr_route !== p[2:0]) begin
                $display("TB_FAIL: Port %0d lost self-regrant on back-to-back single-flit stream (dropped to %b)", p, oc_curr_route);
                err_cnt = err_cnt + 1;
            end
        end

        // Also test thanks_7 on io_xbar_input_control so mutant_06 is killed:
        reset = 1'b1;
        @(negedge clk);
        reset = 1'b0;
        ic_my_chip  = 14'd1;
        ic_abs_chip = 14'd1;
        ic_abs_x    = 8'd7;
        ic_len      = 8'd1;
        ic_valid    = 1'b1;
        ic_th       = 8'b1000_0000; // thanks_7!
        @(negedge clk); // header granted via thanks_7 -> now 1 body beat remains (tail_out must be 1, req must be 0!)
        #1;
        if (ic_req !== 8'd0 || ic_tail !== 1'b1) begin
            $display("TB_FAIL: io_xbar_input_control did not advance on thanks_7: req=%b tail=%b", ic_req, ic_tail);
            err_cnt = err_cnt + 1;
        end
        ic_th = 8'd0;

        // Test 5: Full 8-port round-robin rotation (0 -> 1 -> 2 -> 3 -> 4 -> 5 -> 6 -> 7 -> 0) and fairness across idle gaps!
        reset = 1'b1;
        @(negedge clk);
        reset = 1'b0;
        oc_val_temp = 1'b1;
        oc_req      = 8'hFF;
        oc_tail     = 8'hFF;
        for (p = 1; p <= 8; p = p + 1) begin
            @(negedge clk);
            if (oc_curr_route !== (p % 8)) begin
                $display("TB_FAIL: 8-way round-robin step %0d expected %0d, got %0d", p, (p % 8), oc_curr_route);
                err_cnt = err_cnt + 1;
            end
        end

        // Now test idle-gap memory after serving port 5:
        // First let port 0 (currently planned at the end of the 8-step loop) finish with only port 5 requesting:
        oc_req  = 8'b0010_0000; // port 5 only
        oc_tail = 8'b0010_0001; // tail_0=1 so port 0 finishes, tail_5=1 so port 5 is a 1-flit packet
        @(negedge clk); // port 0 finishes and port 5 is now planned (current_route_f == 3'd5)!
        if (oc_curr_route !== 3'd5) begin
            $display("TB_FAIL: Expected port 5 to be planned, got %0d", oc_curr_route);
            err_cnt = err_cnt + 1;
        end
        oc_req  = 8'd0; // no contenders when port 5 finishes!
        @(negedge clk); // port 5 finishes -> planned_f == 0 (IDLE), last_route_f == 3'd5!
        oc_val_temp = 1'b0;
        oc_tail     = 8'd0;
        repeat (2) @(negedge clk); // 2 idle cycles
        // Now port 5 and port 6 request simultaneously! Because port 5 was served last before the idle gap, port 6 MUST win!
        oc_val_temp = 1'b1;
        oc_req      = 8'b0110_0000;
        oc_tail     = 8'b0110_0000;
        @(negedge clk);
        if (oc_curr_route !== 3'd6) begin
            $display("TB_FAIL: Idle gap reset 8-port round-robin history! Expected port 6 after port 5, got %0d", oc_curr_route);
            err_cnt = err_cnt + 1;
        end

        if (err_cnt == 0) begin
            $display("TB_PASS");
            $finish(0);
        end else begin
            $display("TB_FAIL: %0d errors", err_cnt);
            $finish(1);
        end
    end
endmodule
