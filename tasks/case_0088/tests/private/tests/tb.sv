`timescale 1ns/1ps
module tb #(parameter integer N0 = 4, N1 = 2, SEED = 1);
  localparam integer P0  = 1 << $clog2(N0);
  localparam integer P1  = 1 << $clog2(N1);
  localparam integer IDW = N0 + N1;

  logic clk = 0;
  always #5 clk = ~clk;

  logic rst_n = 0, ready = 0;
  logic [1:0] policy = 2'b00;

  logic [N0-1:0]       req0 = '0, gnt0, rv0;
  logic [N0-1:0][8:0]  add0;
  logic [N0-1:0]       wen0;
  logic [N0-1:0][31:0] wd0;
  logic [N0-1:0][3:0]  be0;
  logic [N0-1:0][IDW-1:0] ids0;

  logic [N1-1:0]       req1 = '0, gnt1, rv1;
  logic [N1-1:0][8:0]  add1;
  logic [N1-1:0]       wen1;
  logic [N1-1:0][31:0] wd1;
  logic [N1-1:0][3:0]  be1;
  logic [N1-1:0][IDW-1:0] ids1;

  logic                memreq, ts, memwen;
  logic [7:0]          memadd;
  logic [31:0]         memwd;
  logic [3:0]          membe;
  logic [IDW-1:0]      memid, rid;
  logic                rvalid;

  integer cyc, i, waits0[0:N0-1], waits1[0:N1-1], mux_wait0, mux_wait1;
  logic [31:0] rng = SEED;
  logic [N0-1:0] held_req0;
  logic [N1-1:0] held_req1;

  RequestBlock2CH #(
    .N_CH0          ( N0  ),
    .N_CH1          ( N1  ),
    .ADDR_MEM_WIDTH ( 8   ),
    .DATA_WIDTH     ( 32  ),
    .ID_WIDTH       ( IDW )
  ) dut (
    .clk                ( clk    ),
    .rst_n              ( rst_n  ),
    .TCDM_arb_policy_i  ( policy ),
    .data_req_CH0_i     ( req0   ),
    .data_add_CH0_i     ( add0   ),
    .data_wen_CH0_i     ( wen0   ),
    .data_wdata_CH0_i   ( wd0    ),
    .data_be_CH0_i      ( be0    ),
    .data_ID_CH0_i      ( ids0   ),
    .data_gnt_CH0_o     ( gnt0   ),
    .data_req_CH1_i     ( req1   ),
    .data_add_CH1_i     ( add1   ),
    .data_wen_CH1_i     ( wen1   ),
    .data_wdata_CH1_i   ( wd1    ),
    .data_be_CH1_i      ( be1    ),
    .data_ID_CH1_i      ( ids1   ),
    .data_gnt_CH1_o     ( gnt1   ),
    .data_req_o         ( memreq ),
    .data_ts_set_o      ( ts     ),
    .data_add_o         ( memadd ),
    .data_wen_o         ( memwen ),
    .data_wdata_o       ( memwd  ),
    .data_be_o          ( membe  ),
    .data_ID_o          ( memid  ),
    .data_gnt_i         ( ready  ),
    .data_r_ID_i        ( rid    ),
    .data_r_valid_i     ( rvalid ),
    .data_r_valid_CH0_o ( rv0    ),
    .data_r_valid_CH1_o ( rv1    )
  );

  task automatic reset_unit;
    begin
      @(negedge clk);
      rst_n  = 0;
      req0   = '0;
      req1   = '0;
      ready  = 0;
      rvalid = 0;
      rid    = '0;
      repeat (3) @(negedge clk);
      rst_n     = 1;
      mux_wait0 = 0;
      mux_wait1 = 0;
      for (integer x = 0; x < N0; x = x + 1) waits0[x] = 0;
      for (integer y = 0; y < N1; y = y + 1) waits1[y] = 0;
    end
  endtask

  initial begin
    for (i = 0; i < N0; i = i + 1) begin
      add0[i]   = 9'(i + 16);
      wen0[i]   = 1'b1;
      wd0[i]    = 32'hA000_0000 + i;
      be0[i]    = 4'((i % 15) + 1);
      ids0[i]   = (IDW'(1) << i);
      waits0[i] = 0;
    end
    for (i = 0; i < N1; i = i + 1) begin
      add1[i]   = 9'(i + 64);
      wen1[i]   = 1'b1;
      wd1[i]    = 32'hB000_0000 + i;
      be1[i]    = 4'(((i + 5) % 15) + 1);
      ids1[i]   = (IDW'(1) << (N0 + i));
      waits1[i] = 0;
    end

    // Phase 1: Cross-channel & intra-channel stall lock
    // Let CH1[N1-1] present a request alone while ready=0, then assert CH0='1 and CH1='1 during stall
    reset_unit();
    policy = 2'b00;
    @(negedge clk);
    req0 = '0;
    req1 = '0;
    req1[N1-1] = 1'b1;
    ready = 0;
    #1;
    if (!memreq || memid !== ids1[N1-1] || memadd !== add1[N1-1][7:0] || memwd !== wd1[N1-1])
      $fatal(1, "initial stalled selection failed for CH1[N1-1]");
    @(posedge clk);
    // Now CH0 and all of CH1 assert req during the stall while policy toggles
    for (cyc = 0; cyc < 4; cyc = cyc + 1) begin
      @(negedge clk);
      req0   = '1;
      req1   = '1;
      policy = {cyc[0], ~cyc[0]};
      ready  = 0;
      #1;
      if (!memreq || gnt0 !== '0 || gnt1 !== '0 || memid !== ids1[N1-1] || memadd !== add1[N1-1][7:0] || memwd !== wd1[N1-1] || membe !== be1[N1-1] || memwen !== wen1[N1-1])
        $fatal(1, "stalled CH1 winner preempted by CH0 or higher-priority contender on cycle %0d: got id=%b expected=%b", cyc, memid, ids1[N1-1]);
      @(posedge clk);
    end
    // Release stall: CH1[N1-1] must win and receive gnt1[N1-1]
    @(negedge clk);
    policy = 2'b00;
    ready  = 1;
    #1;
    if (!memreq || gnt0 !== '0 || gnt1 !== (N1'(1) << (N1-1)) || memid !== ids1[N1-1])
      $fatal(1, "locked CH1 winner did not receive grant upon stall release: gnt0=%b gnt1=%b", gnt0, gnt1);
    @(posedge clk);

    // Next cycle: since CH1 just won at MUX2_REQ, RR_FLAG must now favor CH0!
    // Also test CH0[N0-1] stall lock when CH0[N0-1] requests alone then CH0[0] arrives mid-stall
    reset_unit();
    policy = 2'b00;
    @(negedge clk);
    req0 = '0;
    req1 = '0;
    req0[N0-1] = 1'b1;
    ready = 0;
    #1;
    if (!memreq || memid !== ids0[N0-1])
      $fatal(1, "initial stalled selection failed for CH0[N0-1]");
    @(posedge clk);
    for (cyc = 0; cyc < 3; cyc = cyc + 1) begin
      @(negedge clk);
      req0   = '1;
      req1   = '1;
      policy = {cyc[0], cyc[0]};
      ready  = 0;
      #1;
      if (!memreq || gnt0 !== '0 || gnt1 !== '0 || memid !== ids0[N0-1] || memwd !== wd0[N0-1])
        $fatal(1, "stalled CH0 winner preempted on cycle %0d: got id=%b expected=%b", cyc, memid, ids0[N0-1]);
      @(posedge clk);
    end
    @(negedge clk);
    ready = 1;
    #1;
    if (!memreq || gnt1 !== '0 || gnt0 !== (N0'(1) << (N0-1)) || memid !== ids0[N0-1])
      $fatal(1, "locked CH0 winner did not receive grant upon stall release");
    @(posedge clk);

    // Phase 2: MUX2_REQ work-conserving round-robin fairness (~SEL update)
    // If CH0 is granted solo while RR_FLAG=0, RR_FLAG must become 1 so CH1 wins next when both contend!
    reset_unit();
    policy = 2'b11;
    @(negedge clk);
    req0  = 1; // Only CH0[0] requests
    req1  = '0;
    ready = 1;
    #1;
    if (gnt0[0] !== 1'b1 || gnt1 !== '0) $fatal(1, "solo CH0[0] not granted");
    @(posedge clk);
    // Now CH0[0] requests solo AGAIN! With RR_FLAG <= ~SEL, RR_FLAG must remain 1 (favoring CH1), NOT toggle back to 0!
    @(negedge clk);
    req0  = 1;
    req1  = '0;
    ready = 1;
    #1;
    if (gnt0[0] !== 1'b1 || gnt1 !== '0) $fatal(1, "second solo CH0[0] not granted");
    @(posedge clk);
    // Now BOTH CH0[0] and CH1[0] contend: CH1[0] MUST win immediately because CH0 won the previous transfer!
    @(negedge clk);
    req0  = 1;
    req1  = 1;
    ready = 1;
    #1;
    if (gnt1[0] !== 1'b1 || gnt0 !== '0 || memid !== ids1[0])
      $fatal(1, "CH1 starved after consecutive solo CH0 grants: gnt0=%b gnt1=%b", gnt0, gnt1);
    @(posedge clk);

    // Phase 3: Policy 1 bounded fairness on CH0 (<= P0-1) and CH1 (<= P1-1) & cross-channel fairness
    reset_unit();
    policy = 2'b11;
    held_req0 = '1;
    held_req1 = '1;
    for (cyc = 0; cyc < 320; cyc = cyc + 1) begin
      @(negedge clk);
      rng    = (rng << 1) ^ (rng[31] ? 32'h04c11db7 : 32'h0);
      req0   = held_req0 | rng[N0-1:0] | 1;
      req1   = held_req1 | rng[N0 +: N1] | 1;
      ready  = (cyc % 7 < 5);
      rid    = (IDW'(1) << (cyc % IDW));
      rvalid = cyc[0];
      #1;
      if ({rv1, rv0} !== (rvalid ? rid : '0)) $fatal(1, "response decode mismatch");
      if (!ready && (gnt0 !== '0 || gnt1 !== '0)) $fatal(1, "grant during stall");
      if (ready && (req0 != '0 || req1 != '0)) begin
        if (!memreq || ts || $countones({gnt1, gnt0}) != 1)
          $fatal(1, "grant integrity violation gnt0=%b gnt1=%b", gnt0, gnt1);
        if (|gnt0) begin
          if (|req1) begin
            mux_wait1 = mux_wait1 + 1;
            if (mux_wait1 >= 2) $fatal(1, "CH1 starved at MUX2_REQ");
          end
          mux_wait0 = 0;
          for (integer z = 0; z < N0; z = z + 1) begin
            if (!req0[z] || gnt0[z]) waits0[z] = 0;
            else begin
              waits0[z] = waits0[z] + 1;
              if (waits0[z] >= P0) $fatal(1, "CH0 starvation port=%0d waits=%0d bound=%0d", z, waits0[z], P0);
            end
          end
        end else begin
          if (|req0) begin
            mux_wait0 = mux_wait0 + 1;
            if (mux_wait0 >= 2) $fatal(1, "CH0 starved at MUX2_REQ");
          end
          mux_wait1 = 0;
          for (integer z = 0; z < N1; z = z + 1) begin
            if (!req1[z] || gnt1[z]) waits1[z] = 0;
            else begin
              waits1[z] = waits1[z] + 1;
              if (waits1[z] >= P1) $fatal(1, "CH1 starvation port=%0d waits=%0d bound=%0d", z, waits1[z], P1);
            end
          end
        end
      end
      held_req0 = req0 & ~gnt0;
      held_req1 = req1 & ~gnt1;
      @(posedge clk);
    end

    // Phase 4: Policy 0 exact round-robin on CH0 when CH1 is idle
    reset_unit();
    policy = 2'b00;
    req0   = '1;
    req1   = '0;
    begin
      integer ref_flag0 = 0, best0, score0, sel0;
      for (cyc = 0; cyc < 40; cyc = cyc + 1) begin
        @(negedge clk);
        ready = (cyc % 4 != 1);
        #1;
        if (ready) begin
          best0  = -1;
          score0 = 99999;
          for (integer z = 0; z < N0; z = z + 1)
            if (req0[z] && (z ^ ref_flag0) < score0) begin
              best0  = z;
              score0 = (z ^ ref_flag0);
            end
          sel0 = -1;
          for (integer z = 0; z < N0; z = z + 1) if (gnt0[z]) sel0 = z;
          if (sel0 != best0) $fatal(1, "CH0 policy0 mismatch got=%0d expected=%0d", sel0, best0);
          ref_flag0 = (ref_flag0 == N0 - 1) ? 0 : ref_flag0 + 1;
        end
        @(posedge clk);
      end
    end

    // Phase 5: Two-cycle atomic Test-and-Set with sampled write-data forwarding (`data_wdata_i`)
    reset_unit();
    policy = 2'b11;
    @(negedge clk);
    req0       = '0;
    req1       = '0;
    req0[0]    = 1'b1;
    add0[0][8] = 1'b1; // T&S bit set
    wen0[0]    = 1'b1; // Load phase
    wd0[0]     = 32'hCAFE_BABE; // Custom atomic store value
    be0[0]     = 4'b1010;
    ready      = 1'b1;
    #1;
    if (gnt0[0] !== 1'b1 || !memreq || ts || memwen !== 1'b1 || memadd !== add0[0][7:0] || memid !== ids0[0])
      $fatal(1, "atomic load phase failed");
    @(posedge clk);
    // Second cycle (SET_STORE): upstream changes inputs & asserts all contenders while ready stalls
    @(negedge clk);
    add0[0][8] = 1'b0;
    wd0[0]     = 32'hDEAD_BEEF;
    be0[0]     = 4'b0101;
    req0       = '1;
    req1       = '1;
    ready      = 1'b0;
    repeat (3) begin
      #1;
      if (!ts || !memreq || gnt0 != '0 || gnt1 != '0 || memwen !== 1'b0 ||
          memwd !== 32'hCAFE_BABE || membe !== 4'b1010 || memid !== ids0[0] || memadd !== add0[0][7:0])
        $fatal(1, "atomic SET_STORE continuation failed: ts=%b wen=%b wd=%h be=%b id=%b", ts, memwen, memwd, membe, memid);
      @(negedge clk);
    end
    ready = 1'b1;
    #1;
    if (!ts || gnt0 != '0 || gnt1 != '0 || memwd !== 32'hCAFE_BABE)
      $fatal(1, "atomic SET_STORE grant leaked or wdata corrupted");
    @(posedge clk);
    @(negedge clk);
    req0  = '0;
    req1  = '0;
    ready = 1'b0;
    #1;
    if (ts) $fatal(1, "atomic SET_STORE did not complete");

    // Reset mid-atomic SET_STORE
    @(negedge clk);
    req1[0]    = 1'b1;
    add1[0][8] = 1'b1;
    wen1[0]    = 1'b1;
    wd1[0]     = 32'h1234_5678;
    ready      = 1'b1;
    #1;
    if (!gnt1[0] || !memreq || ts) $fatal(1, "CH1 atomic load not accepted");
    @(posedge clk);
    @(negedge clk);
    req1  = '0;
    ready = 1'b0;
    #1;
    if (!ts || memwd !== 32'h1234_5678) $fatal(1, "CH1 atomic SET_STORE not active");
    rst_n = 1'b0;
    repeat (2) @(negedge clk);
    rst_n = 1'b1;
    #1;
    if (ts || memreq || gnt0 != '0 || gnt1 != '0) $fatal(1, "reset did not flush atomic SET_STORE");

    $display("PASS_2CH N0=%0d N1=%0d", N0, N1);
    $finish;
  end

  initial begin
    #200000;
    $fatal(1, "simulation timeout");
  end
endmodule
