`timescale 1ns/1ps
module tb #(parameter integer N=4, SEED=1);
  localparam integer P = 1 << $clog2(N);
  logic clk = 0;
  always #5 clk = ~clk;

  logic rst_n = 0, policy = 0, ready = 0;
  logic [N-1:0] req = '0, gnt, rv;
  logic [N-1:0][8:0] add;
  logic [N-1:0] wen;
  logic [N-1:0][31:0] wd;
  logic [N-1:0][3:0] be;
  logic [N-1:0][N-1:0] ids;
  logic memreq, ts, memwen;
  logic [7:0] memadd;
  logic [31:0] memwd;
  logic [3:0] membe;
  logic [N-1:0] memid, rid;
  logic rvalid;

  integer cyc, i, sel, ref_flag = 0, best, score, lastsel = 0, waits[0:N-1];
  logic [31:0] rng = SEED;
  logic [N-1:0] stalled_id, held_req;

  RequestBlock1CH #(
    .ADDR_MEM_WIDTH(8),
    .N_CH0(N),
    .ID_WIDTH(N),
    .DATA_WIDTH(32)
  ) dut (
    .clk                ( clk    ),
    .rst_n              ( rst_n  ),
    .TCDM_arb_policy_i  ( policy ),
    .data_req_CH0_i     ( req    ),
    .data_add_CH0_i     ( add    ),
    .data_wen_CH0_i     ( wen    ),
    .data_wdata_CH0_i   ( wd     ),
    .data_be_CH0_i      ( be     ),
    .data_ID_CH0_i      ( ids    ),
    .data_gnt_CH0_o     ( gnt    ),
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
    .data_r_valid_CH0_o ( rv     )
  );

  task automatic reset_unit;
    begin
      @(negedge clk);
      rst_n = 0;
      req   = 0;
      ready = 0;
      repeat (3) @(negedge clk);
      rst_n    = 1;
      ref_flag = 0;
      for (integer x = 0; x < N; x = x + 1) waits[x] = 0;
    end
  endtask

  task automatic check_normal(input bit exact_mode0, input bit fairness);
    begin
      #1;
      if (fairness) for (integer z = 0; z < N; z = z + 1) if (!req[z]) waits[z] = 0;
      if (rv !== (rvalid ? rid : '0)) $fatal(1, "response decode");
      if (!ready && gnt !== '0) $fatal(1, "grant during stall");
      if (ready && req != '0) begin
        if (!memreq || ts || $countones(gnt) != 1 || (gnt & ~req) != '0)
          $fatal(1, "grant integrity req=%b gnt=%b", req, gnt);
        sel = -1;
        for (integer z = 0; z < N; z = z + 1) if (gnt[z]) sel = z;
        lastsel = sel;
        if (memid !== ids[sel] || memadd !== add[sel][7:0] || memwd !== wd[sel] || membe !== be[sel] || memwen !== wen[sel])
          $fatal(1, "payload mismatch selected=%0d", sel);
        if (exact_mode0) begin
          best  = -1;
          score = 99999;
          for (integer z = 0; z < N; z = z + 1)
            if (req[z] && (z ^ ref_flag) < score) begin
              best  = z;
              score = (z ^ ref_flag);
            end
          if (sel != best) $fatal(1, "policy0 changed got=%0d expected=%0d", sel, best);
          ref_flag = (ref_flag == N - 1) ? 0 : ref_flag + 1;
        end
        if (fairness)
          for (integer z = 0; z < N; z = z + 1) begin
            if (!req[z] || gnt[z]) waits[z] = 0;
            else begin
              waits[z] = waits[z] + 1;
              if (waits[z] >= P) $fatal(1, "starvation port=%0d bound=%0d", z, P);
            end
          end
      end else if (ready && req == '0 && gnt != '0) $fatal(1, "spurious grant");
    end
  endtask

  initial begin
    rid = 0;
    rvalid = 0;
    for (i = 0; i < N; i = i + 1) begin
      add[i]   = i;
      wen[i]   = 1;
      wd[i]    = 32'h98760000 + i;
      be[i]    = (i % 15) + 1;
      ids[i]   = 1 << i;
      waits[i] = 0;
    end

    // Phase 1: Stall-lock verification under Policy 0 and Policy 1 when higher-priority / favored contenders arrive mid-stall
    reset_unit();
    policy = 0;
    @(negedge clk);
    req = '0;
    req[N-1] = 1'b1; // Master N-1 alone requests while PRIO_FLAG=0 favors Master 0
    ready = 0;
    #1;
    if (!memreq || memid !== ids[N-1] || memadd !== add[N-1][7:0] || memwd !== wd[N-1])
      $fatal(1, "initial stalled selection failed for N-1");
    @(posedge clk);
    // Now favored Master 0 and all other masters assert req during the stall, and policy toggles!
    for (cyc = 0; cyc < 4; cyc = cyc + 1) begin
      @(negedge clk);
      req    = '1;
      policy = cyc[0];
      ready  = 0;
      #1;
      if (!memreq || gnt !== '0 || memid !== ids[N-1] || memadd !== add[N-1][7:0] || memwd !== wd[N-1] || membe !== be[N-1] || memwen !== wen[N-1])
        $fatal(1, "stalled winner preempted by late higher-priority contender on cycle %0d: got id=%b expected=%b", cyc, memid, ids[N-1]);
      @(posedge clk);
    end
    // Release stall under policy 0 and verify locked Master N-1 receives the grant
    @(negedge clk);
    policy = 0;
    ready  = 1;
    #1;
    if (!memreq || gnt !== (1 << (N-1)) || memid !== ids[N-1] || memadd !== add[N-1][7:0] || memwd !== wd[N-1])
      $fatal(1, "locked winner N-1 did not receive grant upon stall release: gnt=%b", gnt);
    @(posedge clk);

    // Phase 2: Policy 0 exact round-robin sequence across stalls
    reset_unit();
    policy = 0;
    req    = '1;
    for (cyc = 0; cyc < 50; cyc = cyc + 1) begin
      @(negedge clk);
      ready  = (cyc % 5 != 1);
      rid    = 1 << (cyc % N);
      rvalid = cyc[0];
      check_normal(1, 0);
      @(posedge clk);
    end

    // Phase 3: Policy 1 stall stability & bounded fairness across all-contending and dynamic-contending traffic
    reset_unit();
    policy = 1;
    req    = '1;
    ready  = 0;
    @(negedge clk);
    #1;
    stalled_id = memid;
    repeat (5) begin
      @(negedge clk);
      #1;
      if (memid !== stalled_id || gnt != '0) $fatal(1, "priority advanced while memory stalled");
      @(posedge clk);
    end
    for (cyc = 0; cyc < 100; cyc = cyc + 1) begin
      @(negedge clk);
      ready  = (cyc % 7 < 4);
      rid    = 1 << (cyc % N);
      rvalid = cyc[0];
      check_normal(0, 1);
      @(posedge clk);
    end

    // Dynamic contenders holding valid requests until granted, with requester zero persistent
    held_req = req;
    for (cyc = 0; cyc < 400; cyc = cyc + 1) begin
      @(negedge clk);
      rng      = (rng << 1) ^ ((rng[31]) ? 32'h04c11db7 : 0);
      req      = held_req | rng[N-1:0] | 1;
      ready    = (cyc % 11 < 7);
      rid      = 1 << (cyc % N);
      rvalid   = 1;
      check_normal(0, 1);
      held_req = req & ~gnt;
      @(posedge clk);
    end

    // Phase 4: Change policy while requests remain pending
    @(negedge clk);
    policy   = 0;
    ready    = 0;
    ref_flag = lastsel;
    req      = '1;
    for (cyc = 0; cyc < 40; cyc = cyc + 1) begin
      @(negedge clk);
      ready = (cyc % 5 != 0);
      check_normal(1, 0);
      @(posedge clk);
    end
    @(negedge clk);
    policy = 1;
    ready  = 0;
    for (i = 0; i < N; i = i + 1) waits[i] = 0;
    for (cyc = 0; cyc < 80; cyc = cyc + 1) begin
      @(negedge clk);
      ready = (cyc % 7 < 4);
      check_normal(0, 1);
      @(posedge clk);
    end

    // Phase 5: Test-and-set read creates a held internal write, which must finish before a new grant
    reset_unit();
    policy = 1;
    @(negedge clk);
    req       = '0;
    req[0]    = 1;
    add[0][8] = 1;
    ready     = 1;
    #1;
    if (gnt[0] !== 1 || !memreq || ts) $fatal(1, "atomic read not granted");
    @(posedge clk);
    @(negedge clk);
    add[0][8] = 0;
    req       = '1;
    ready     = 0;
    repeat (3) begin
      #1;
      if (!ts || !memreq || gnt != '0 || memwen !== 0 || memwd !== 32'hffffffff || memid !== ids[0] || memadd !== add[0][7:0])
        $fatal(1, "atomic continuation not held");
      @(negedge clk);
    end
    ready = 1;
    #1;
    if (!ts || gnt != '0) $fatal(1, "atomic continuation grant leaked");
    @(posedge clk);
    @(negedge clk);
    #1;
    if (ts || gnt == '0) $fatal(1, "atomic did not complete");
    for (i = 0; i < N; i = i + 1) begin
      #1;
      held_req = req & ~gnt;
      @(posedge clk);
      @(negedge clk);
      req = held_req;
    end
    req   = '0;
    ready = 0;

    // Reset while an internal test-and-set store is pending
    req       = '0;
    req[0]    = 1;
    add[0][8] = 1;
    ready     = 1;
    #1;
    if (!gnt[0]) $fatal(1, "second atomic read not accepted");
    @(posedge clk);
    @(negedge clk);
    req   = 0;
    ready = 0;
    rst_n = 0;
    repeat (2) @(negedge clk);
    rst_n = 1;
    #1;
    if (ts || gnt != '0) $fatal(1, "reset did not flush atomic continuation");

    $display("FAIRNESS_PASS N=%0d", N);
    $finish;
  end

  initial begin
    #100000;
    $fatal(1, "progress timeout");
  end
endmodule
