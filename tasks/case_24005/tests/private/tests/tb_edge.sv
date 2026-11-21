`timescale 1ps/1ps

module tb_edge;
  logic w_clk = 1'b0, r_clk = 1'b0;
  always #2000 w_clk = ~w_clk;
  always #1250 r_clk = ~r_clk;

  logic       c_wrst = 1'b1, c_rrst = 1'b1, c_enq = 1'b0, c_deq = 1'b0, c_full, c_valid;
  logic [5:0] c_wdata = '0, c_rdata;

  bsg_async_fifo #(
    .lg_size_p(2),
    .width_p(6),
    .control_width_p(6),
    .and_data_with_valid_p(0)
  ) dut_all_ctrl (
    .w_clk_i(w_clk), .w_reset_i(c_wrst), .w_enq_i(c_enq), .w_data_i(c_wdata), .w_full_o(c_full),
    .r_clk_i(r_clk), .r_reset_i(c_rrst), .r_deq_i(c_deq), .r_data_o(c_rdata), .r_valid_o(c_valid)
  );

  logic       d_wrst = 1'b1, d_rrst = 1'b1, d_enq = 1'b0, d_deq = 1'b0, d_full, d_valid;
  logic [7:0] d_wdata = '0, d_rdata;

  bsg_async_fifo #(
    .lg_size_p(1),
    .width_p(8),
    .control_width_p(0),
    .and_data_with_valid_p(1)
  ) dut_lg1 (
    .w_clk_i(w_clk), .w_reset_i(d_wrst), .w_enq_i(d_enq), .w_data_i(d_wdata), .w_full_o(d_full),
    .r_clk_i(r_clk), .r_reset_i(d_rrst), .r_deq_i(d_deq), .r_data_o(d_rdata), .r_valid_o(d_valid)
  );

  initial begin
    repeat (3) @(posedge w_clk);
    @(negedge w_clk); c_wrst = 1'b0; d_wrst = 1'b0;
    @(negedge r_clk); c_rrst = 1'b0; d_rrst = 1'b0;
    while ((c_full !== 1'b0 || d_full !== 1'b0) && $time < 200000) @(posedge w_clk);
    if (c_full !== 1'b0 || d_full !== 1'b0) begin $display("FAIL_EDGE: stuck full"); $fatal(1); end

    @(negedge w_clk); c_enq = 1'b1; c_wdata = 6'h3D;
    @(posedge w_clk); #50; c_enq = 1'b0;
    if (c_valid === 1'b0 && c_rdata !== 6'h00) begin $display("FAIL_EDGE: dut_all_ctrl ungated"); $fatal(1); end
    repeat (5) @(posedge r_clk);
    if (c_valid !== 1'b1 || c_rdata !== 6'h3D) begin $display("FAIL_EDGE: dut_all_ctrl mismatch"); $fatal(1); end
    @(negedge r_clk); c_deq = 1'b1;
    @(posedge r_clk);
    @(negedge r_clk); c_deq = 1'b0;

    @(negedge w_clk); d_enq = 1'b1; d_wdata = 8'h11;
    @(negedge w_clk); d_wdata = 8'h22;
    @(posedge w_clk); #50;
    if (d_full !== 1'b1) begin $display("FAIL_EDGE: dut_lg1 not full"); $fatal(1); end
    @(negedge w_clk); d_wdata = 8'hEE;
    @(posedge w_clk);
    @(negedge w_clk); d_enq = 1'b0;
    repeat (5) @(posedge r_clk);
    if (d_valid !== 1'b1 || d_rdata !== 8'h11) begin $display("FAIL_EDGE: dut_lg1 first word"); $fatal(1); end
    @(negedge r_clk); d_deq = 1'b1;
    @(posedge r_clk); #50;
    if (d_valid !== 1'b1 || d_rdata !== 8'h22) begin $display("FAIL_EDGE: dut_lg1 second word"); $fatal(1); end
    @(posedge r_clk); #50;
    if (d_valid !== 1'b0) begin $display("FAIL_EDGE: dut_lg1 not empty"); $fatal(1); end
    @(negedge r_clk); d_deq = 1'b0;
    $display("PASS_EDGE");
    $finish;
  end
endmodule
