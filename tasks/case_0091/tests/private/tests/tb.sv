module tb;
  import neureka_package::*;

  logic clk_i = 0;
  logic rst_ni = 0;
  logic clear_i = 0;
  logic [31:0] norm_mult_i = '0;
  logic [31:0] shift_i = '0;
  logic signed [127:0] accumulator_i = '0;
  ctrl_normquant_t ctrl_i = '0;

  logic signed [127:0] acc_o_p1_r1, acc_o_p1_r0;
  flags_normquant_t [3:0] flags_p1_r1, flags_p1_r0;

  logic [47:0] sh_data_i = '0;
  logic [7:0]  sh_shift_i = '0;
  logic signed [31:0] sh_o_r1;

  always #5 clk_i = ~clk_i;

  neureka_normquant #(
    .NMULT(4), .NMS(8), .ACC(32), .INT(48), .QNT(32),
    .PIPE(1), .OUTPUT_REGISTER(1)
  ) u_nq_p1_r1 (
    .clk_i(clk_i), .rst_ni(rst_ni), .test_mode_i(1'b0), .clear_i(clear_i),
    .norm_mult_i(norm_mult_i), .shift_i(shift_i),
    .accumulator_i(accumulator_i), .accumulator_o(acc_o_p1_r1),
    .ctrl_i(ctrl_i), .flags_o(flags_p1_r1)
  );

  neureka_normquant #(
    .NMULT(4), .NMS(8), .ACC(32), .INT(48), .QNT(32),
    .PIPE(1), .OUTPUT_REGISTER(0)
  ) u_nq_p1_r0 (
    .clk_i(clk_i), .rst_ni(rst_ni), .test_mode_i(1'b0), .clear_i(clear_i),
    .norm_mult_i(norm_mult_i), .shift_i(shift_i),
    .accumulator_i(accumulator_i), .accumulator_o(acc_o_p1_r0),
    .ctrl_i(ctrl_i), .flags_o(flags_p1_r0)
  );

  neureka_normquant_shifter #(
    .ACC(32), .INT(48), .OUTPUT_REGISTER(1)
  ) u_sh_r1 (
    .clk_i(clk_i), .rst_ni(rst_ni), .test_mode_i(1'b0), .clear_i(clear_i),
    .data_i(sh_data_i), .shift_i(sh_shift_i),
    .accumulator_o(sh_o_r1), .ctrl_i(ctrl_i)
  );

  function automatic logic [31:0] ref_quant(
    input logic signed [47:0] val,
    input logic [7:0]         sh_in,
    input ctrl_normquant_t    c
  );
    logic [4:0] shamt;
    logic signed [48:0] rnd, val_rnd, shifted;
    logic [31:0] res;
    shamt = sh_in[4:0];
    if (!c.use_shifting) begin
      shifted = $signed(val);
    end else begin
      rnd = (c.use_rounding && (shamt != 5'd0)) ? (49'sd1 <<< (shamt - 5'd1)) : 49'sd0;
      val_rnd = $signed(val) + rnd;
      shifted = val_rnd >>> shamt;
    end
    res = '0;
    if (!c.use_shifting) begin
      if (c.quant_mode == NEUREKA_MODE_8B)       res[7:0]  = shifted[7:0];
      else if (c.quant_mode == NEUREKA_MODE_16B) res[15:0] = shifted[15:0];
      else if (c.quant_mode == NEUREKA_MODE_32B) res       = shifted[31:0];
    end else if (c.relu) begin
      if (shifted < 0) begin
        res = '0;
      end else if (c.quant_mode == NEUREKA_MODE_8B) begin
        res[7:0] = (shifted > 49'sd255) ? 8'hff : shifted[7:0];
      end else if (c.quant_mode == NEUREKA_MODE_16B) begin
        res[15:0] = (shifted > 49'sd65535) ? 16'hffff : shifted[15:0];
      end else if (c.quant_mode == NEUREKA_MODE_32B) begin
        res = (shifted > 49'sd4294967295) ? 32'hffffffff : shifted[31:0];
      end
    end else begin
      if (c.quant_mode == NEUREKA_MODE_8B) begin
        if (shifted < -49'sd128)      res[7:0] = 8'h80;
        else if (shifted > 49'sd127)  res[7:0] = 8'h7f;
        else                          res[7:0] = shifted[7:0];
      end else if (c.quant_mode == NEUREKA_MODE_16B) begin
        if (shifted < -49'sd32768)     res[15:0] = 16'h8000;
        else if (shifted > 49'sd32767) res[15:0] = 16'h7fff;
        else                           res[15:0] = shifted[15:0];
      end else if (c.quant_mode == NEUREKA_MODE_32B) begin
        if (shifted < -49'sd2147483648)     res = 32'h8000_0000;
        else if (shifted > 49'sd2147483647) res = 32'h7fff_ffff;
        else                                res = shifted[31:0];
      end
    end
    return res;
  endfunction

  function automatic logic [127:0] ref_normquant(
    input logic [31:0]  nm_in,
    input logic [127:0] acc_in,
    input logic [31:0]  sh_in,
    input ctrl_normquant_t c
  );
    logic signed [47:0] p_shift [3:0];
    logic signed [39:0] prod [3:0];
    logic [127:0] out_v;
    for (int i = 0; i < 4; i++) begin
      logic signed [31:0] a_sel;
      logic sbit;
      logic signed [8:0] m_s;
      a_sel = (c.norm_mode == NEUREKA_MODE_8B)  ? $signed(acc_in[i*32 +: 32]) :
              (c.norm_mode == NEUREKA_MODE_16B) ? $signed(acc_in[(i/2)*32 +: 32]) :
              (c.norm_mode == NEUREKA_MODE_32B) ? $signed(acc_in[31:0]) : 32'sd0;
      sbit  = (c.norm_mode == NEUREKA_MODE_8B)                  ? nm_in[i*8 + 7] :
              ((c.norm_mode == NEUREKA_MODE_16B) && (i % 2 == 1)) ? nm_in[i*8 + 7] :
              ((c.norm_mode == NEUREKA_MODE_32B) && (i == 3))     ? nm_in[31]      : 1'b0;
      m_s   = {c.norm_signed & sbit, nm_in[i*8 +: 8]};
      prod[i] = m_s * a_sel;
    end
    p_shift[0] = '0; p_shift[1] = '0; p_shift[2] = '0; p_shift[3] = '0;
    if (c.norm_mode == NEUREKA_MODE_8B) begin
      for (int i = 0; i < 4; i++) p_shift[i] = {{8{prod[i][39]}}, prod[i]};
    end else if (c.norm_mode == NEUREKA_MODE_16B) begin
      p_shift[0] = {{8{prod[0][39]}}, prod[0]} + ({{8{prod[1][39]}}, prod[1]} <<< 8);
      p_shift[1] = {{8{prod[2][39]}}, prod[2]} + ({{8{prod[3][39]}}, prod[3]} <<< 8);
    end else if (c.norm_mode == NEUREKA_MODE_32B) begin
      p_shift[0] = {{8{prod[0][39]}}, prod[0]} + ({{8{prod[1][39]}}, prod[1]} <<< 8) + ({{8{prod[2][39]}}, prod[2]} <<< 16) + ({{8{prod[3][39]}}, prod[3]} <<< 24);
    end
    for (int i = 0; i < 4; i++) begin
      out_v[i*32 +: 32] = ref_quant(p_shift[i], sh_in[i*8 +: 8], c);
    end
    return out_v;
  endfunction

  int unsigned rng = 32'h13572468;
  function automatic int unsigned next_rand();
    rng = rng ^ (rng << 13);
    rng = rng ^ (rng >> 17);
    rng = rng ^ (rng << 5);
    return rng;
  endfunction

  initial begin
    int seed;
    if (!$value$plusargs("seed=%d", seed)) seed = 1;
    rng = 32'h9e3779b9 ^ seed;

    rst_ni = 0; clear_i = 0;
    repeat (3) @(posedge clk_i);
    rst_ni = 1;
    @(negedge clk_i);
    if (acc_o_p1_r1 !== '0 || sh_o_r1 !== '0 || flags_p1_r1 !== 4'hf || flags_p1_r0 !== 4'hf) begin
      $display("FAIL reset state");
      $fatal(1);
    end

    for (int iter = 0; iter < 600; iter++) begin
      logic [31:0]  nm_v, sh_v;
      logic [127:0] acc_v, exp_r0;
      logic [47:0]  sd_v;
      logic [31:0]  exp_sh;
      ctrl_normquant_t c_v;

      nm_v  = next_rand();
      sh_v  = {3'b0, next_rand() & 5'h1f, 3'b0, next_rand() & 5'h1f, 3'b0, next_rand() & 5'h1f, 3'b0, next_rand() & 5'h1f};
      acc_v = {next_rand(), next_rand(), next_rand(), next_rand()};
      sd_v  = {next_rand() & 16'hffff, next_rand()};
      if (iter < 120) begin
        sh_v = {8'(1 + (iter % 23)), 8'(1 + ((iter + 3) % 23)), 8'(1 + ((iter + 7) % 23)), 8'(1 + ((iter + 11) % 23))};
        case (iter % 6)
          0: sd_v = (48'sd127 <<< sh_v[4:0]) + (48'sd1 <<< (sh_v[4:0] - 1));
          1: sd_v = (-48'sd128 <<< sh_v[4:0]) - (48'sd1 <<< (sh_v[4:0] - 1)) - 1;
          2: sd_v = (48'sd255 <<< sh_v[4:0]) + (48'sd1 <<< (sh_v[4:0] - 1));
          3: sd_v = (48'sd65535 <<< sh_v[4:0]) + (48'sd1 <<< (sh_v[4:0] - 1));
          4: sd_v = (48'sd4294967295 <<< sh_v[4:0]) + (48'sd1 <<< (sh_v[4:0] - 1));
          default: sd_v = (48'sd2147483647 <<< sh_v[4:0]) + (48'sd1 <<< (sh_v[4:0] - 1));
        endcase
      end

      c_v.start        = 1'b1;
      c_v.relu         = iter[0];
      c_v.right_shift  = sh_v[4:0];
      c_v.norm_mode    = (iter % 3 == 0) ? NEUREKA_MODE_8B : ((iter % 3 == 1) ? NEUREKA_MODE_16B : NEUREKA_MODE_32B);
      c_v.quant_mode   = ((iter / 3) % 3 == 0) ? NEUREKA_MODE_8B : (((iter / 3) % 3 == 1) ? NEUREKA_MODE_16B : NEUREKA_MODE_32B);
      c_v.norm_signed  = iter[1];
      c_v.use_rounding = (iter < 120) ? 1'b1 : iter[2];
      c_v.use_shifting = (iter < 120) ? 1'b1 : (iter % 7 != 0);

      @(negedge clk_i);
      clear_i       = 1'b0;
      norm_mult_i   = nm_v;
      shift_i       = sh_v;
      accumulator_i = acc_v;
      sh_data_i     = sd_v;
      sh_shift_i    = sh_v[7:0];
      ctrl_i        = c_v;

      @(posedge clk_i);
      #1;
      exp_r0 = ref_normquant(nm_v, acc_v, sh_v, c_v);
      exp_sh = ref_quant($signed(sd_v), sh_v[7:0], c_v);
      if (acc_o_p1_r0 !== exp_r0 || flags_p1_r0 !== 4'hf || flags_p1_r1 !== 4'hf) begin
        $display("FAIL r0 iter=%0d got=%h exp=%h", iter, acc_o_p1_r0, exp_r0);
        $fatal(1);
      end
      if (sh_o_r1 !== $signed(exp_sh)) begin
        $display("FAIL sh_r1 iter=%0d got=%h exp=%h", iter, sh_o_r1, exp_sh);
        $fatal(1);
      end

      @(negedge clk_i);
      ctrl_i.start  = 1'b0;
      norm_mult_i   = ~nm_v;
      accumulator_i = ~acc_v;
      sh_data_i     = ~sd_v;
      @(posedge clk_i);
      #1;
      if (acc_o_p1_r0 !== exp_r0 || sh_o_r1 !== $signed(exp_sh)) begin
        $display("FAIL stall hold iter=%0d r0=%h (exp %h) sh=%h (exp %h)", iter, acc_o_p1_r0, exp_r0, sh_o_r1, exp_sh);
        $fatal(1);
      end

      @(negedge clk_i);
      ctrl_i.start  = 1'b1;
      norm_mult_i   = nm_v;
      accumulator_i = acc_v;
      sh_data_i     = sd_v;
      @(posedge clk_i);
      #1;
      if (acc_o_p1_r1 !== exp_r0) begin
        $display("FAIL r1 iter=%0d got=%h exp=%h", iter, acc_o_p1_r1, exp_r0);
        $fatal(1);
      end

      if (iter % 29 == 28) begin
        @(negedge clk_i);
        clear_i = 1'b1;
        @(posedge clk_i);
        #1;
        if (acc_o_p1_r1 !== '0 || sh_o_r1 !== '0) begin
          $display("FAIL clear iter=%0d", iter);
          $fatal(1);
        end
      end
    end

    $display("PASS neureka_normquant and neureka_normquant_shifter equivalence");
    $finish;
  end
endmodule
