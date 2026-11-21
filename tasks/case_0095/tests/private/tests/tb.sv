module tb;
  import fpnew_pkg::*;

  logic clk_i = 0;
  logic rst_ni = 0;
  logic flush_i = 0;
  always #5 clk_i = ~clk_i;

  logic [1:0][31:0]  operands_i = '0;
  logic [4:0][1:0]   is_boxed_i = '1;
  roundmode_e        rnd_mode_i = RNE;
  operation_e        op_i       = F2F;
  logic              op_mod_i   = 1'b0;
  fp_format_e        src_fmt_i  = FP32;
  fp_format_e        dst_fmt_i  = FP32;
  int_format_e       int_fmt_i  = INT32;
  logic              in_valid_i = 1'b0;
  logic              in_ready_o;
  logic [31:0]       cast_result_o, exp_cast_res;
  status_t           cast_status_o;
  logic              cast_ext_bit_o;
  logic              cast_out_valid_o;
  logic              cast_out_ready_i = 1'b1;
  logic [31:0]       noncomp_result_o;
  status_t           noncomp_status_o;
  logic              noncomp_ext_bit_o;
  classmask_e        noncomp_class_mask_o;
  logic              noncomp_is_class_o;
  logic              noncomp_out_valid_o;
  logic              noncomp_out_ready_i = 1'b1;

  logic              ref_in_ready, ref_cast_out_valid, ref_cast_ext_bit;
  logic [31:0]       ref_cast_result;
  status_t           ref_cast_status;
  logic              ref_nc_out_valid, ref_nc_ext_bit, ref_nc_is_class;
  logic [31:0]       ref_nc_result;
  status_t           ref_nc_status;
  classmask_e        ref_nc_class_mask;

  fpnew_cast_noncomp_top #(
    .FpFmtConfig  ( 5'b10101          ),
    .IntFmtConfig ( 4'b1110           ),
    .NumPipeRegs  ( 1                 ),
    .PipeConfig   ( fpnew_pkg::INSIDE )
  ) u_dut (
    .clk_i(clk_i), .rst_ni(rst_ni), .flush_i(flush_i),
    .operands_i(operands_i), .is_boxed_i(is_boxed_i),
    .rnd_mode_i(rnd_mode_i), .op_i(op_i), .op_mod_i(op_mod_i),
    .src_fmt_i(src_fmt_i), .dst_fmt_i(dst_fmt_i), .int_fmt_i(int_fmt_i),
    .in_valid_i(in_valid_i), .in_ready_o(in_ready_o),
    .cast_result_o(cast_result_o), .cast_status_o(cast_status_o), .cast_ext_bit_o(cast_ext_bit_o),
    .cast_out_valid_o(cast_out_valid_o), .cast_out_ready_i(cast_out_ready_i),
    .noncomp_result_o(noncomp_result_o), .noncomp_status_o(noncomp_status_o), .noncomp_ext_bit_o(noncomp_ext_bit_o),
    .noncomp_class_mask_o(noncomp_class_mask_o), .noncomp_is_class_o(noncomp_is_class_o),
    .noncomp_out_valid_o(noncomp_out_valid_o), .noncomp_out_ready_i(noncomp_out_ready_i)
  );

  ref_fpnew_cast_noncomp_top #(
    .FpFmtConfig  ( 5'b10101          ),
    .IntFmtConfig ( 4'b1110           ),
    .NumPipeRegs  ( 1                 ),
    .PipeConfig   ( fpnew_pkg::INSIDE )
  ) u_ref (
    .clk_i(clk_i), .rst_ni(rst_ni), .flush_i(flush_i),
    .operands_i(operands_i), .is_boxed_i(is_boxed_i),
    .rnd_mode_i(rnd_mode_i), .op_i(op_i), .op_mod_i(op_mod_i),
    .src_fmt_i(src_fmt_i), .dst_fmt_i(dst_fmt_i), .int_fmt_i(int_fmt_i),
    .in_valid_i(in_valid_i), .in_ready_o(ref_in_ready),
    .cast_result_o(ref_cast_result), .cast_status_o(ref_cast_status), .cast_ext_bit_o(ref_cast_ext_bit),
    .cast_out_valid_o(ref_cast_out_valid), .cast_out_ready_i(cast_out_ready_i),
    .noncomp_result_o(ref_nc_result), .noncomp_status_o(ref_nc_status), .noncomp_ext_bit_o(ref_nc_ext_bit),
    .noncomp_class_mask_o(ref_nc_class_mask), .noncomp_is_class_o(ref_nc_is_class),
    .noncomp_out_valid_o(ref_nc_out_valid), .noncomp_out_ready_i(noncomp_out_ready_i)
  );

  int unsigned rng = 32'h13579bdf;
  function automatic int unsigned next_rand();
    rng = rng ^ (rng << 13);
    rng = rng ^ (rng >> 17);
    rng = rng ^ (rng << 5);
    return rng;
  endfunction

  localparam fp_format_e  FP_FMTS  [3] = '{FP32, FP16, FP16ALT};
  localparam int_format_e INT_FMTS [3] = '{INT8, INT16, INT32};
  localparam roundmode_e  RND_MODES[6] = '{RNE, RTZ, RDN, RUP, RMM, ROD};
  localparam operation_e  ALL_OPS  [7] = '{F2F, F2I, I2F, MINMAX, SGNJ, CMP, CLASSIFY};

  initial begin
    int seed;
    if (!$value$plusargs("seed=%d", seed)) seed = 1;
    rng = 32'h9e3779b9 ^ seed;

    rst_ni = 1;
    repeat (2) @(posedge clk_i);
    @(negedge clk_i);
    rst_ni = 0;
    repeat (3) @(posedge clk_i);
    @(negedge clk_i);
    rst_ni = 1;
    @(negedge clk_i);

    for (int t = 0; t < 4000; t++) begin
      int unsigned r1, r2, r3;
      r1 = next_rand();
      r2 = next_rand();
      r3 = next_rand();

      in_valid_i          = (t % 9 != 7);
      cast_out_ready_i    = (t % 7 != 3);
      noncomp_out_ready_i = (t % 6 != 2);
      flush_i             = (t == 500 || t == 1500);

      op_i       = ALL_OPS[t % 7];
      op_mod_i   = r1[0];
      src_fmt_i  = FP_FMTS[(t / 7) % 3];
      dst_fmt_i  = FP_FMTS[(t / 21) % 3];
      int_fmt_i  = INT_FMTS[(t / 63) % 3];
      rnd_mode_i = (op_i inside {MINMAX, SGNJ, CMP, CLASSIFY}) ? RND_MODES[(t / 5) % 4] : RND_MODES[(t / 5) % 6];

      for (int f = 0; f < 5; f++) begin
        is_boxed_i[f][0] = (t % 17 != 0);
        is_boxed_i[f][1] = (t % 23 != 0);
      end

      if (t < 800) begin
        case (t % 16)
          0:  operands_i = {32'h8000_0000, 32'h0000_0000};
          1:  operands_i = {32'h0000_0000, 32'h8000_0000};
          2:  operands_i = {32'h7f80_0000, 32'hff80_0000};
          3:  operands_i = {32'hff80_0000, 32'h7f80_0000};
          4:  operands_i = {32'h7f80_0001, 32'h3f80_0000}; // sNaN
          5:  operands_i = {32'h7fc0_0000, 32'hbf80_0000}; // qNaN
          6:  operands_i = {32'h0000_0001, 32'h8000_0001}; // subnormals
          7:  operands_i = {32'h807f_ffff, 32'h807f_ffff};
          8:  operands_i = {32'hc000_0000, 32'hbf80_0001}; // -1.00000012 in op[0] (tests d0 sticky & negative F2I!)
          9:  operands_i = {32'hbf80_0000, 32'hc000_0001}; // -2.00000024 in op[0]
          10: operands_i = {32'h3f80_0000, 32'h3380_0001}; // tiny normal -> subnormal FP16 with sticky
          11: operands_i = {32'hffff_0001, 32'hffff_0001}; // FP16 subnormal
          12: operands_i = {32'hffff_8001, 32'hffff_8001}; // FP16 neg subnormal
          13: operands_i = {32'hc000_0000, 32'hbf80_0000}; // -1.0 vs -2.0 (both negative for noncomp!)
          14: operands_i = {32'h7fff_ffff, 32'h8000_0001};
          15: operands_i = {r3, r2};
        endcase
      end else begin
        operands_i = {r3, r2};
      end

      #1;
      exp_cast_res = ref_cast_result;
      if (in_ready_o !== ref_in_ready || cast_out_valid_o !== ref_cast_out_valid) begin
        $display("FAIL cast handshake t=%0d in_rdy=%b/%b out_val=%b/%b",
                 t, in_ready_o, ref_in_ready, cast_out_valid_o, ref_cast_out_valid);
        $fatal(1);
      end
      if (cast_out_valid_o) begin
        if (cast_result_o !== ref_cast_result ||
            cast_status_o !== ref_cast_status ||
            cast_ext_bit_o !== ref_cast_ext_bit) begin
          $display("FAIL cast output t=%0d got res=%h stat=%b ext=%b exp res=%h stat=%b ext=%b dst_int=%b src_int=%b dst_fmt=%0d ref_sh_in=%h ref_shamt=%0d ref_dest_m=%h ref_pre=%h ref_r_abs=%h ref_spec=%b",
                   t, cast_result_o, cast_status_o, cast_ext_bit_o, ref_cast_result, ref_cast_status, ref_cast_ext_bit,
                   u_ref.i_cast_multi.dst_is_int_q, u_ref.i_cast_multi.src_is_int_q, u_ref.i_cast_multi.dst_fmt_q2,
                   u_ref.i_cast_multi.input_mant_q, u_ref.i_cast_multi.denorm_shamt, u_ref.i_cast_multi.destination_mant,
                   u_ref.i_cast_multi.pre_round_abs, u_ref.i_cast_multi.rounded_abs, u_ref.i_cast_multi.fp_result_is_special);
          $fatal(1);
        end
      end

      if (noncomp_out_valid_o !== ref_nc_out_valid) begin
        $display("FAIL noncomp handshake t=%0d", t);
        $fatal(1);
      end
      if (noncomp_out_valid_o) begin
        if (noncomp_result_o !== ref_nc_result ||
            noncomp_status_o !== ref_nc_status ||
            noncomp_ext_bit_o !== ref_nc_ext_bit ||
            noncomp_class_mask_o !== ref_nc_class_mask ||
            noncomp_is_class_o !== ref_nc_is_class) begin
          $display("FAIL noncomp output t=%0d got res=%h stat=%b cls=%b exp res=%h stat=%b cls=%b",
                   t, noncomp_result_o, noncomp_status_o, noncomp_class_mask_o,
                   ref_nc_result, ref_nc_status, ref_nc_class_mask);
          $fatal(1);
        end
      end

      @(posedge clk_i);
      @(negedge clk_i);
    end

    $display("PASS fpnew_cast_multi and fpnew_noncomp equivalence");
    $finish;
  end
endmodule
