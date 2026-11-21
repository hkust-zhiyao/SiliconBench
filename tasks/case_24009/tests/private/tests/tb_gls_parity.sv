`timescale 1ns/100ps

module tb_gls_parity;
  reg clk = 1'b0;
  always #2 clk = ~clk;

  reg         rst = 1'b1;
  reg  [4:0]  en5 = 5'b10110; // 3 of 5 channels active!
  reg         wr5_en = 1'b0;
  reg  [59:0] wr5_data = 60'h0;
  wire        p5_wr_en, p5_sync;
  wire [59:0] p5_wr_data;
  reg         rd5_en = 1'b0;
  wire        rd5_valid, rd5_uflow;
  wire [59:0] rd5_data;
  reg         s5_valid = 1'b0;
  wire        s5_ready;
  reg  [59:0] s5_data = 60'h0;

  util_pack_asic_cluster dut (
    .clk(clk),
    .reset(rst),
    .en5(en5),
    .wr5_en(wr5_en),
    .wr5_data(wr5_data),
    .p5_wr_en(p5_wr_en),
    .p5_wr_data(p5_wr_data),
    .p5_sync(p5_sync),
    .rd5_en(rd5_en),
    .rd5_valid(rd5_valid),
    .rd5_uflow(rd5_uflow),
    .rd5_data(rd5_data),
    .s5_valid(s5_valid),
    .s5_ready(s5_ready),
    .s5_data(s5_data)
  );

  reg [59:0] fifo_mem [0:127];
  integer wptr = 0, rptr = 0;
  reg [11:0] exp_s [0:511];
  integer exp_w = 0, exp_r = 0;
  reg mon_x = 1'b0;

  always @(posedge clk) begin
    if (mon_x) begin
      if ((^p5_wr_en === 1'bx) || (^p5_sync === 1'bx) || (^s5_ready === 1'bx) ||
          (^rd5_valid === 1'bx) || (^rd5_uflow === 1'bx)) begin
        $display("FAIL_GLS: 4-state X leaked onto control/handshake outputs! p_wr=%b sync=%b s_rdy=%b r_v=%b ufl=%b",
                 p5_wr_en, p5_sync, s5_ready, rd5_valid, rd5_uflow);
        $fatal(1);
      end
      if (p5_wr_en) begin
        if (^p5_wr_data === 1'bx) begin
          $display("FAIL_GLS: 4-state X leaked onto p5_wr_data=%h!", p5_wr_data);
          $fatal(1);
        end
        fifo_mem[wptr] <= p5_wr_data;
        wptr <= wptr + 1;
      end
      if (s5_valid && s5_ready) begin
        rptr <= rptr + 1;
      end
      if (rd5_valid) begin
        integer ch;
        for (ch = 0; ch < 5; ch = ch + 1) begin
          if (en5[ch]) begin
            if ((^rd5_data[ch*12 +: 12] === 1'bx) || (rd5_data[ch*12 +: 12] !== exp_s[exp_r])) begin
              $display("FAIL_GLS: mismatch/X at sample %0d ch=%0d got=%h exp=%h",
                       exp_r, ch, rd5_data[ch*12 +: 12], exp_s[exp_r]);
              $fatal(1);
            end
            exp_r = exp_r + 1;
          end
        end
      end
    end
  end

  always @(*) begin
    if (wptr > rptr) begin
      s5_valid = 1'b1;
      s5_data  = fifo_mem[rptr];
    end else begin
      s5_valid = 1'b0;
      s5_data  = 60'h0;
    end
  end

  integer b, c;
  initial begin
    // Synchronous reset for 8 cycles: MUST clear all ASIC power-on 1'bx states!
    repeat (8) @(posedge clk);
    @(negedge clk);
    rst = 1'b0;
    repeat (6) @(posedge clk);
    mon_x = 1'b1;

    // Phase 1: en5 = 5'b10110 (K=3), send 25 beats (20 real + 5 pipeline flush)
    for (b = 0; b < 25; b = b + 1) begin
      @(negedge clk);
      wr5_en = 1'b1;
      for (c = 0; c < 5; c = c + 1) begin
        wr5_data[c*12 +: 12] = 12'h300 + (b * 7) + c;
        if (b < 20 && en5[c]) begin
          exp_s[exp_w] = 12'h300 + (b * 7) + c;
          exp_w = exp_w + 1;
        end
      end
      @(posedge clk);
    end
    @(negedge clk);
    wr5_en = 1'b0;
    repeat (4) @(posedge clk);

    // Drain 12 packed words (60 samples = 20 unpacked beats)
    while (exp_r < 60) begin
      @(negedge clk);
      rd5_en = (wptr > rptr && rptr < 12);
      @(posedge clk);
    end
    @(negedge clk);
    rd5_en = 1'b0;
    repeat (6) @(posedge clk);

    // Phase 2: Dynamic mask switch to en5 = 5'b11101 (K=4, consecutive spanning!) WITHOUT pulsing reset!
    wptr = 0; rptr = 0; exp_w = 0; exp_r = 0;
    @(negedge clk);
    en5 = 5'b11101;
    repeat (6) @(posedge clk);

    for (b = 0; b < 20; b = b + 1) begin
      @(negedge clk);
      wr5_en = 1'b1;
      for (c = 0; c < 5; c = c + 1) begin
        wr5_data[c*12 +: 12] = 12'h700 + (b * 11) + c;
        if (b < 15 && en5[c]) begin
          exp_s[exp_w] = 12'h700 + (b * 11) + c;
          exp_w = exp_w + 1;
        end
      end
      @(posedge clk);
    end
    @(negedge clk);
    wr5_en = 1'b0;
    repeat (4) @(posedge clk);

    while (exp_r < 60) begin
      @(negedge clk);
      rd5_en = (wptr > rptr && rptr < 12);
      @(posedge clk);
    end
    @(negedge clk);
    rd5_en = 1'b0;
    repeat (6) @(posedge clk);

    $display("PASS_GLS_PARITY");
    $finish;
  end
endmodule
