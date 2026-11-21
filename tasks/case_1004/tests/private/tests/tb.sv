`timescale 1ns/1ps
module tb_cfg #(
  parameter int unsigned N_CH0 = 4,
  parameter int unsigned N_CH1 = 2
) (
  output bit passed
);
  localparam int unsigned SramDw = 32;
  localparam int unsigned SramAw = 12;
  localparam int unsigned P_CH0  = 1 << $clog2(N_CH0);
  localparam int unsigned P_CH1  = 1 << $clog2(N_CH1);

  logic              clk_i = 0;
  always #5 clk_i = ~clk_i;

  logic              rst_ni          = 0;
  logic [1:0]        arb_policy_i    = 0;
  logic [N_CH0-1:0]  req_ch0_i       = 0;
  logic [SramAw-1:0] req_addr_ch0_i  [N_CH0];
  logic [N_CH0-1:0]  req_write_ch0_i = 0;
  logic [N_CH0-1:0]  req_amo_ch0_i   = 0;
  logic [SramDw-1:0] req_wdata_ch0_i [N_CH0];
  logic [SramDw-1:0] req_wmask_ch0_i [N_CH0];
  wire  [N_CH0-1:0]  gnt_ch0_o;
  wire  [N_CH0-1:0]  rsp_rvalid_ch0_o;
  wire  [SramDw-1:0] rsp_rdata_ch0_o [N_CH0];
  wire  [1:0]        rsp_error_ch0_o [N_CH0];

  logic [N_CH1-1:0]  req_ch1_i       = 0;
  logic [SramAw-1:0] req_addr_ch1_i  [N_CH1];
  logic [N_CH1-1:0]  req_write_ch1_i = 0;
  logic [N_CH1-1:0]  req_amo_ch1_i   = 0;
  logic [SramDw-1:0] req_wdata_ch1_i [N_CH1];
  logic [SramDw-1:0] req_wmask_ch1_i [N_CH1];
  wire  [N_CH1-1:0]  gnt_ch1_o;
  wire  [N_CH1-1:0]  rsp_rvalid_ch1_o;
  wire  [SramDw-1:0] rsp_rdata_ch1_o [N_CH1];
  wire  [1:0]        rsp_error_ch1_o [N_CH1];

  wire               sram_req_o;
  logic              sram_gnt_i      = 0;
  wire  [SramAw-1:0] sram_addr_o;
  wire               sram_write_o;
  wire               sram_amo_write_o;
  wire  [SramDw-1:0] sram_wdata_o;
  wire  [SramDw-1:0] sram_wmask_o;
  logic              sram_rvalid_i   = 0;
  logic [SramDw-1:0] sram_rdata_i    = 0;
  logic [1:0]        sram_rerror_i   = 0;

  ot_sram_xbar_2ch #(
    .N_CH0  ( N_CH0  ),
    .N_CH1  ( N_CH1  ),
    .SramDw ( SramDw ),
    .SramAw ( SramAw ),
    .EnMask ( 1'b1   )
  ) dut (
    .clk_i,
    .rst_ni,
    .arb_policy_i,
    .req_ch0_i,
    .req_addr_ch0_i,
    .req_write_ch0_i,
    .req_amo_ch0_i,
    .req_wdata_ch0_i,
    .req_wmask_ch0_i,
    .gnt_ch0_o,
    .rsp_rvalid_ch0_o,
    .rsp_rdata_ch0_o,
    .rsp_error_ch0_o,
    .req_ch1_i,
    .req_addr_ch1_i,
    .req_write_ch1_i,
    .req_amo_ch1_i,
    .req_wdata_ch1_i,
    .req_wmask_ch1_i,
    .gnt_ch1_o,
    .rsp_rvalid_ch1_o,
    .rsp_rdata_ch1_o,
    .rsp_error_ch1_o,
    .sram_req_o,
    .sram_gnt_i,
    .sram_addr_o,
    .sram_write_o,
    .sram_amo_write_o,
    .sram_wdata_o,
    .sram_wmask_o,
    .sram_rvalid_i,
    .sram_rdata_i,
    .sram_rerror_i
  );

  initial begin
    passed = 0;
    for (int i = 0; i < N_CH0; i++) begin
      req_addr_ch0_i[i]  = 12'h100 + i[11:0];
      req_wdata_ch0_i[i] = 32'hA000_0000 + i;
      req_wmask_ch0_i[i] = 32'hFFFF_0000 | (1 << i);
    end
    for (int i = 0; i < N_CH1; i++) begin
      req_addr_ch1_i[i]  = 12'h200 + i[11:0];
      req_wdata_ch1_i[i] = 32'hB000_0000 + i;
      req_wmask_ch1_i[i] = 32'h0000_FFFF | (1 << i);
    end

    repeat (2) @(posedge clk_i);
    rst_ni = 1;
    @(posedge clk_i);

    // Test 1: Stall lock across both prim_arbiter_tree and prim_sram_arbiter
    @(negedge clk_i);
    sram_gnt_i   = 0;
    arb_policy_i = 2'b00;
    req_ch0_i    = (1 << (N_CH0 - 1));
    req_write_ch0_i = '1;
    #1;
    begin
      logic [SramAw-1:0] held_addr;
      logic [SramDw-1:0] held_wdata, held_wmask;
      held_addr  = sram_addr_o;
      held_wdata = sram_wdata_o;
      held_wmask = sram_wmask_o;
      if (sram_req_o !== 1'b1 || held_addr !== req_addr_ch0_i[N_CH0-1]) begin
        $display("TB_FAIL [%0d,%0d]: Test 1 initial request mismatch", N_CH0, N_CH1);
        $fatal(1);
      end
      @(posedge clk_i);
      @(negedge clk_i);
      req_ch0_i       = '1;
      req_ch1_i       = '1;
      req_write_ch1_i = '1;
      arb_policy_i    = 2'b11;
      for (int c = 0; c < 4; c++) begin
        #1;
        if (sram_req_o !== 1'b1 || sram_addr_o !== held_addr || sram_wdata_o !== held_wdata || sram_wmask_o !== held_wmask || gnt_ch0_o !== '0 || gnt_ch1_o !== '0) begin
          $display("TB_FAIL [%0d,%0d]: Test 1 stall lock violated at cycle %0d: addr=%0h exp=%0h",
                   N_CH0, N_CH1, c, sram_addr_o, held_addr);
          $fatal(1);
        end
        @(posedge clk_i);
        @(negedge clk_i);
        arb_policy_i = ~arb_policy_i;
      end
      sram_gnt_i = 1;
      #1;
      if (gnt_ch0_o !== (1 << (N_CH0 - 1)) || gnt_ch1_o !== '0 || sram_addr_o !== held_addr) begin
        $display("TB_FAIL [%0d,%0d]: Test 1 grant on stall release went to wrong master: gnt0=%b gnt1=%b",
                 N_CH0, N_CH1, gnt_ch0_o, gnt_ch1_o);
        $fatal(1);
      end
      @(posedge clk_i);
    end

    // Test 2: Channel alternation after even number of solo CH0 grants (~sel_ch1 vs ~rr_flag_q)
    @(negedge clk_i);
    req_ch0_i       = 1;
    req_ch1_i       = 0;
    req_write_ch0_i = '1;
    req_write_ch1_i = '1;
    sram_gnt_i      = 1;
    @(posedge clk_i);
    @(negedge clk_i);
    req_ch0_i  = 1;
    req_ch1_i  = 0;
    @(posedge clk_i);
    @(negedge clk_i);
    req_ch0_i  = 1;
    req_ch1_i  = 1;
    #1;
    if (gnt_ch1_o[0] !== 1'b1 || gnt_ch0_o !== '0) begin
      $display("TB_FAIL [%0d,%0d]: Test 2 CH1 starved after two solo CH0 grants (rr_flag_q toggled instead of ~sel_ch1)",
               N_CH0, N_CH1);
      $fatal(1);
    end
    @(posedge clk_i);

    // Test 3: Policy 1 bounded starvation (at most P_c - 1 other grants on channel c)
    @(negedge clk_i);
    req_ch1_i       = 0;
    arb_policy_i    = 2'b11;
    req_ch0_i       = '1;
    req_write_ch0_i = '1;
    sram_gnt_i      = 1;
    begin
      int wait_cnt [N_CH0];
      for (int i = 0; i < N_CH0; i++) wait_cnt[i] = 0;
      for (int step = 0; step < 8 * P_CH0; step++) begin
        if ((step % 5) == 2) begin
          sram_gnt_i = 0;
          @(posedge clk_i);
          @(negedge clk_i);
          sram_gnt_i = 1;
        end
        #1;
        for (int i = 0; i < N_CH0; i++) begin
          if (req_ch0_i[i]) begin
            if (gnt_ch0_o[i]) begin
              wait_cnt[i] = 0;
            end else begin
              wait_cnt[i]++;
              if (wait_cnt[i] >= P_CH0) begin
                $display("TB_FAIL [%0d,%0d]: Test 3 Policy 1 starvation on CH0 master %0d: waited %0d >= P_CH0=%0d grants",
                         N_CH0, N_CH1, i, wait_cnt[i], P_CH0);
                $fatal(1);
              end
            end
          end
        end
        @(posedge clk_i);
        @(negedge clk_i);
      end
    end

    // Adversarial Policy 1 test against blind modulo counter:
    @(negedge clk_i);
    arb_policy_i = 2'b11;
    for (int r = 0; r < N_CH0; r++) begin
      req_ch0_i = (1 << 0);
      @(posedge clk_i);
      @(negedge clk_i);
      req_ch0_i = '1;
      begin
        int waits [N_CH0];
        for (int i = 0; i < N_CH0; i++) waits[i] = 0;
        for (int s = 0; s < 4 * P_CH0; s++) begin
          #1;
          for (int i = 0; i < N_CH0; i++) begin
            if (gnt_ch0_o[i]) waits[i] = 0;
            else begin
              waits[i]++;
              if (waits[i] >= P_CH0) begin
                $display("TB_FAIL [%0d,%0d]: Test 3b Policy 1 adversarial starvation on CH0 master %0d (waited %0d >= %0d)",
                         N_CH0, N_CH1, i, waits[i], P_CH0);
                $fatal(1);
              end
            end
          end
          @(posedge clk_i);
          @(negedge clk_i);
        end
      end
    end

    // Test 4: Atomic Read-Modify-Write (AMO) two-cycle sequence & write-data forwarding + read FIFO steering under stall
    @(negedge clk_i);
    req_ch0_i          = 0;
    req_ch1_i          = 1;
    req_write_ch1_i[0] = 0;
    req_amo_ch1_i[0]   = 1;
    req_addr_ch1_i[0]  = 12'h345;
    req_wdata_ch1_i[0] = 32'hCAFE_BABE;
    req_wmask_ch1_i[0] = 32'h0F0F_F0F0;
    sram_gnt_i         = 0;
    repeat (2) @(posedge clk_i);
    @(negedge clk_i);
    sram_gnt_i = 1;
    #1;
    if (sram_req_o !== 1'b1 || sram_write_o !== 1'b0 || sram_amo_write_o !== 1'b0 || sram_addr_o !== 12'h345 || gnt_ch1_o[0] !== 1'b1) begin
      $display("TB_FAIL [%0d,%0d]: Test 4 AMO cycle 1 (read) mismatch", N_CH0, N_CH1);
      $fatal(1);
    end
    @(posedge clk_i);
    @(negedge clk_i);
    req_ch1_i          = 0;
    req_ch0_i          = 1;
    req_write_ch0_i[0] = 0;
    req_amo_ch0_i[0]   = 0;
    req_addr_ch0_i[0]  = 12'h777;
    sram_rvalid_i      = 1;
    sram_rdata_i       = 32'h1122_3344;
    #1;
    if (sram_req_o !== 1'b1 || sram_write_o !== 1'b1 || sram_amo_write_o !== 1'b1 ||
        sram_addr_o !== 12'h345 || sram_wdata_o !== 32'hCAFE_BABE || sram_wmask_o !== 32'h0F0F_F0F0 ||
        gnt_ch0_o !== '0 || rsp_rvalid_ch1_o[0] !== 1'b1 || rsp_rdata_ch1_o[0] !== 32'h1122_3344) begin
      $display("TB_FAIL [%0d,%0d]: Test 4 AMO cycle 2 (write/rsp) mismatch: req=%b wr=%b amo_wr=%b addr=%0h wdata=%08h wmask=%08h gnt0=%b rvalid1=%b",
               N_CH0, N_CH1, sram_req_o, sram_write_o, sram_amo_write_o, sram_addr_o, sram_wdata_o, sram_wmask_o, gnt_ch0_o, rsp_rvalid_ch1_o);
      $fatal(1);
    end
    @(posedge clk_i);
    @(negedge clk_i);
    sram_rvalid_i = 0;
    #1;
    if (gnt_ch0_o[0] !== 1'b1 || sram_addr_o !== 12'h777 || sram_write_o !== 1'b0) begin
      $display("TB_FAIL [%0d,%0d]: Test 4 post-AMO CH0 read grant mismatch", N_CH0, N_CH1);
      $fatal(1);
    end
    @(posedge clk_i);
    @(negedge clk_i);
    req_ch0_i     = 0;
    sram_rvalid_i = 1;
    sram_rdata_i  = 32'h5566_7788;
    #1;
    if (rsp_rvalid_ch0_o[0] !== 1'b1 || rsp_rvalid_ch1_o !== '0 || rsp_rdata_ch0_o[0] !== 32'h5566_7788) begin
      $display("TB_FAIL [%0d,%0d]: Test 4 read response FIFO steering corrupted by stalled cycles: rvalid0=%b rvalid1=%b",
               N_CH0, N_CH1, rsp_rvalid_ch0_o, rsp_rvalid_ch1_o);
      $fatal(1);
    end
    @(posedge clk_i);
    @(negedge clk_i);
    sram_rvalid_i = 0;

    // Also test CH1[1] read steering to verify N_CH0_i offset calculation
    req_ch1_i          = 2'b10;
    req_write_ch1_i[1] = 0;
    req_amo_ch1_i[1]   = 0;
    req_addr_ch1_i[1]  = 12'h888;
    @(posedge clk_i);
    @(negedge clk_i);
    req_ch1_i     = 0;
    sram_rvalid_i = 1;
    sram_rdata_i  = 32'h99aa_bbcc;
    #1;
    if (rsp_rvalid_ch1_o[1] !== 1'b1 || rsp_rvalid_ch1_o[0] !== 1'b0 || rsp_rvalid_ch0_o !== '0) begin
      $display("TB_FAIL [%0d,%0d]: Test 4b CH1[1] read response steering mismatch: rvalid1=%b",
               N_CH0, N_CH1, rsp_rvalid_ch1_o);
      $fatal(1);
    end
    @(posedge clk_i);
    sram_rvalid_i = 0;
    passed = 1;
  end
endmodule

module tb;
  bit p42, p32, p84;
  tb_cfg #(.N_CH0(4), .N_CH1(2)) u_42 (.passed(p42));
  tb_cfg #(.N_CH0(3), .N_CH1(2)) u_32 (.passed(p32));
  tb_cfg #(.N_CH0(8), .N_CH1(4)) u_84 (.passed(p84));

  initial begin
    wait (p42 && p32 && p84);
    $display("PASS_CASE_1004");
    $finish;
  end
endmodule
