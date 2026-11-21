module sub_tb #(
  parameter int unsigned AW = 32,
  parameter int unsigned BW = 32,
  parameter int unsigned MB = 4
) (
  input  int unsigned seed_i,
  output bit          done_o
);
  import hwpe_ctrl_package::*;

  localparam int unsigned AW_PAD  = (AW % MB == 0) ? AW : (AW + MB - (AW % MB));
  localparam int unsigned N_STEPS = AW_PAD / MB;

  logic clk = 1'b0;
  logic rst = 1'b0;
  logic clear = 1'b0;
  logic start = 1'b0;
  logic inv = 1'b0;
  logic step_uloop = 1'b0;
  logic [AW-1:0] a;
  logic [BW-1:0] b;
  wire [AW+BW-1:0] prod, refprod;
  wire ready, valid, refready, refvalid;

  always #5 clk = ~clk;

  hwpe_ctrl_partial_mult #(
    .AW(AW),
    .BW(BW),
    .MULT_BITS(MB)
  ) dut (
    .clk_i(clk),
    .rst_ni(rst),
    .clear_i(clear),
    .start_i(start),
    .a_i(a),
    .b_i(b),
    .invert_i(inv),
    .valid_o(valid),
    .ready_o(ready),
    .prod_o(prod)
  );

  ref_partial #(
    .AW(AW),
    .BW(BW),
    .MULT_BITS(MB)
  ) refdut (
    .clk_i(clk),
    .rst_ni(rst),
    .clear_i(clear),
    .start_i(start),
    .a_i(a),
    .b_i(b),
    .invert_i(inv),
    .valid_o(refvalid),
    .ready_o(refready),
    .prod_o(refprod)
  );

  // Closed-loop integration with hwpe_ctrl_uloop
  ctrl_uloop_t  u_ctrl;
  flags_uloop_t u_flags;
  uloop_code_t  u_code;
  logic [0:0][31:0] u_ro;

  assign u_ctrl.enable = step_uloop && valid && ready;
  assign u_ctrl.ready  = 1'b1;
  assign u_ctrl.clear  = 1'b0;
  assign u_ro[0]       = 32'(prod);

  always_comb begin
    u_code = '0;
    u_code.range[0] = 12'd4;
    u_code.range[1] = 12'd1;
    u_code.loops[0].nb_ops = 4'd1;
    u_code.loops[1].nb_ops = 4'd1;
    u_code.code[0].a = 5'd0;
    u_code.code[0].b = 5'd1;
    u_code.code[0].op_sel = 1'b1;
  end

  hwpe_ctrl_uloop #(
    .LENGTH(32),
    .NB_LOOPS(2),
    .NB_REG(1),
    .NB_RO_REG(1),
    .REG_WIDTH(32),
    .CNT_WIDTH(12),
    .SHADOWED(0)
  ) u_loop (
    .clk_i(clk),
    .rst_ni(rst),
    .test_mode_i(1'b0),
    .clear_i(clear),
    .ctrl_i(u_ctrl),
    .flags_o(u_flags),
    .uloop_code_i(u_code),
    .registers_read_i(u_ro)
  );

  task automatic tick;
    @(negedge clk);
    #1;
    if ({ready, valid} !== {refready, refvalid}) begin
      $fatal(1, "handshake mismatch AW=%0d BW=%0d ready=%b/%b valid=%b/%b", AW, BW, ready, refready, valid, refvalid);
    end
    if ((!rst || clear || valid) && (prod !== refprod)) begin
      $fatal(1, "prod mismatch AW=%0d BW=%0d valid=%b got=%h ref=%h", AW, BW, valid, prod, refprod);
    end
  endtask

  task automatic run_op(
    input logic [AW-1:0] x,
    input logic [BW-1:0] y,
    input bit            neg,
    input bit            hold_idle
  );
    int unsigned n;
    logic [AW+BW-1:0] exp;
    begin
      if (ready !== 1'b1) begin
        $fatal(1, "DUT not ready before start AW=%0d", AW);
      end
      a = x;
      b = y;
      inv = neg;
      exp = x * y;
      if (neg) exp = -exp;
      start = 1'b1;
      tick;
      start = 1'b0;
      n = 1;
      while (valid !== 1'b1) begin
        if (ready !== 1'b0) begin
          $fatal(1, "ready high while busy AW=%0d step=%0d", AW, n);
        end
        tick;
        n = n + 1;
        if (n > N_STEPS + 2) begin
          $fatal(1, "progress timeout AW=%0d", AW);
        end
      end
      if (n != N_STEPS || ready !== 1'b1 || prod !== exp) begin
        $fatal(1, "product/latency mismatch AW=%0d got=%h exp=%h n=%0d/%0d", AW, prod, exp, n, N_STEPS);
      end
      if (hold_idle) begin
        tick;
        if (valid !== 1'b1 || ready !== 1'b1 || prod !== exp) begin
          $fatal(1, "idle hold mismatch AW=%0d got=%h exp=%h", AW, prod, exp);
        end
      end
    end
  endtask

  initial begin
    int unsigned s;
    logic [31:0] exp_offs;
    done_o = 1'b0;
    a = '0;
    b = '0;
    inv = 1'b0;
    start = 1'b0;
    clear = 1'b0;
    step_uloop = 1'b0;
    #1;
    s = seed_i + AW * 97 + BW * 31;

    // Async reset check
    rst = 1'b1; #1; rst = 1'b0;
    tick;
    if (ready !== 1'b1 || valid !== 1'b0 || prod !== '0) begin
      $fatal(1, "async reset failed AW=%0d", AW);
    end
    rst = 1'b1;
    tick;

    // Directed corner cases (including back-to-back starts when hold_idle == 0)
    run_op('0, '0, 1'b0, 1'b1);
    run_op('0, '1, 1'b1, 1'b0);
    run_op('1, '0, 1'b1, 1'b0);
    run_op('1, '1, 1'b0, 1'b0);
    run_op('1, '1, 1'b1, 1'b1);
    run_op(AW'(1) << (AW - 1), BW'(3), 1'b0, 1'b0);
    run_op(AW'(1) << (AW - 1), BW'(3), 1'b1, 1'b0);
    run_op((AW'(1) << (AW - 1)) | AW'(1), (BW'(1) << (BW - 1)) | BW'(1), 1'b0, 1'b0);
    run_op((AW'(1) << (AW - 1)) | AW'(1), (BW'(1) << (BW - 1)) | BW'(1), 1'b1, 1'b1);

    // Test every single-bit position in a_i and b_i
    for (int unsigned bit_a = 0; bit_a < AW; bit_a++) begin
      run_op(AW'(1) << bit_a, {BW{1'b1}}, bit_a[0], 1'b0);
    end
    for (int unsigned bit_b = 0; bit_b < BW; bit_b++) begin
      run_op({AW{1'b1}}, BW'(1) << bit_b, bit_b[0], 1'b0);
    end

    // Verify closed-loop stride accumulation in hwpe_ctrl_uloop
    clear = 1'b1; tick; clear = 1'b0; tick;
    exp_offs = 32'd0;
    run_op(AW'(23), BW'(19), 1'b0, 1'b0);
    step_uloop = 1'b1; tick; step_uloop = 1'b0; tick;
    exp_offs = exp_offs + 32'(23 * 19);
    if (u_flags.offs[0] !== exp_offs) begin
      $fatal(1, "uloop stride 1 mismatch AW=%0d got=%h exp=%h", AW, u_flags.offs[0], exp_offs);
    end
    run_op(AW'(15), BW'(7), 1'b1, 1'b0);
    step_uloop = 1'b1; tick; step_uloop = 1'b0; tick;
    exp_offs = exp_offs + 32'(refprod);
    if (u_flags.offs[0] !== exp_offs) begin
      $fatal(1, "uloop stride 2 mismatch AW=%0d got=%h exp=%h", AW, u_flags.offs[0], exp_offs);
    end

    // Mid-operation synchronous clear check at every in-flight cycle
    for (int unsigned k = 1; k < N_STEPS; k++) begin
      a = '1; b = '1; inv = k[0];
      start = 1'b1; tick; start = 1'b0;
      for (int unsigned c = 1; c < k; c++) tick;
      clear = 1'b1; tick; clear = 1'b0;
      if (ready !== 1'b1 || valid !== 1'b0 || prod !== '0) begin
        $fatal(1, "mid-op clear failed AW=%0d at step %0d", AW, k);
      end
      run_op(AW'(11 + k), BW'(13 + k), ~k[0], 1'b0);
    end

    // Mid-operation async reset check
    a = '1; b = '1; inv = 1'b1;
    start = 1'b1; tick; start = 1'b0; tick;
    rst = 1'b0; tick; rst = 1'b1; tick;
    run_op(AW'(37), BW'(41), 1'b0, 1'b1);

    // Pseudo-random stress including back-to-back chains
    for (int unsigned i = 0; i < 120; i++) begin
      logic [63:0] ra, rb;
      ra = {$urandom(s + i * 4 + 0), $urandom(s + i * 4 + 1)};
      rb = {$urandom(s + i * 4 + 2), $urandom(s + i * 4 + 3)};
      run_op(ra[AW-1:0], rb[BW-1:0], ra[0] ^ rb[1], (i % 3 == 0));
    end

    done_o = 1'b1;
  end
endmodule

module tb;
  int unsigned seed = 1;
  bit d1, d2, d3;

  sub_tb #(.AW(32), .BW(32), .MB(4)) u_cfg_32_32 (.seed_i(seed), .done_o(d1));
  sub_tb #(.AW(17), .BW(11), .MB(4)) u_cfg_17_11 (.seed_i(seed + 1000), .done_o(d2));
  sub_tb #(.AW(24), .BW(16), .MB(4)) u_cfg_24_16 (.seed_i(seed + 2000), .done_o(d3));

  initial begin
    if (!$value$plusargs("seed=%d", seed)) seed = 1;
    wait (d1 && d2 && d3);
    $display("PASS partial multiplier cycle, uloop stride, and arithmetic equivalence");
    $finish;
  end

  initial begin
    #500000;
    $fatal(1, "global simulation timeout");
  end
endmodule
