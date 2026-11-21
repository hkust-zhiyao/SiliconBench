`timescale 1ns/1ps

module tb_proto;
  reg         clk;
  reg         rstn;
  reg         reg2dp_op_en;
  reg         reg2dp_conv_mode;
  reg   [1:0] reg2dp_proc_precision;
  reg   [4:0] reg2dp_clip_truncate;
  reg         mac2accu_pvld;
  reg   [7:0] mac2accu_mask;
  reg   [8:0] mac2accu_pd;
  reg  [43:0] mac2accu_data_even_pri;
  reg  [43:0] mac2accu_data_odd_pri;
  reg  [21:0] mac2accu_data_even_ext;
  reg  [21:0] mac2accu_data_odd_ext;
  reg         cacc2sdp_ready;

  wire        cacc2sdp_valid;
  wire [129:0] cacc2sdp_pd;
  wire  [1:0] cacc2glb_done_intr_pd;
  wire        dp2reg_done;

  cacc_sram_subsys dut (
     .nvdla_core_clk         (clk)
    ,.nvdla_core_rstn        (rstn)
    ,.reg2dp_op_en           (reg2dp_op_en)
    ,.reg2dp_conv_mode      (reg2dp_conv_mode)
    ,.reg2dp_proc_precision (reg2dp_proc_precision)
    ,.reg2dp_clip_truncate  (reg2dp_clip_truncate)
    ,.mac2accu_pvld          (mac2accu_pvld)
    ,.mac2accu_mask          (mac2accu_mask)
    ,.mac2accu_pd            (mac2accu_pd)
    ,.mac2accu_data_even_pri (mac2accu_data_even_pri)
    ,.mac2accu_data_odd_pri  (mac2accu_data_odd_pri)
    ,.mac2accu_data_even_ext (mac2accu_data_even_ext)
    ,.mac2accu_data_odd_ext  (mac2accu_data_odd_ext)
    ,.cacc2sdp_ready         (cacc2sdp_ready)
    ,.cacc2sdp_valid         (cacc2sdp_valid)
    ,.cacc2sdp_pd            (cacc2sdp_pd)
    ,.cacc2glb_done_intr_pd  (cacc2glb_done_intr_pd)
    ,.dp2reg_done            (dp2reg_done)
  );

  initial clk = 1'b0;
  always #5 clk = ~clk;

  // Reference calculators (1-shot step evaluation on a clean sideband channel)
  reg         ref_vld;
  reg         ref_op_vld_ep, ref_op_vld_op, ref_op_vld_ee, ref_op_vld_oe;
  reg         ref_sel;
  reg  [47:0] ref_op_ep, ref_op_op;
  reg  [33:0] ref_op_ee, ref_op_oe;
  reg  [43:0] ref_di_ep, ref_di_op;
  reg  [21:0] ref_di_ee, ref_di_oe;
  reg   [4:0] ref_trunc;

  wire [31:0] ref_i8_ep_fin, ref_i16_ep_fin, ref_fp_ep_fin;
  wire [33:0] ref_i8_ep_part;
  wire [47:0] ref_i16_ep_part, ref_fp_ep_part;
  wire [31:0] ref_i8_op_fin, ref_i16_op_fin, ref_fp_op_fin;
  wire [33:0] ref_i8_op_part;
  wire [47:0] ref_i16_op_part, ref_fp_op_part;
  wire [31:0] ref_i8_ee_fin, ref_i8_oe_fin;
  wire [33:0] ref_i8_ee_part, ref_i8_oe_part;

  // Use a fast auxiliary reference clock to step reference calculators atomically per beat!
  reg ref_clk;
  initial ref_clk = 1'b0;

  NV_NVDLA_CACC_CALC_int8  r_i8_ep (.nvdla_core_clk(ref_clk), .nvdla_core_rstn(rstn), .cfg_truncate(ref_trunc), .in_data(ref_di_ep[21:0]), .in_op(ref_op_ep[33:0]), .in_op_valid(ref_op_vld_ep), .in_sel(ref_sel), .in_valid(ref_vld), .out_final_data(ref_i8_ep_fin), .out_final_sat(), .out_final_valid(), .out_partial_data(ref_i8_ep_part), .out_partial_valid());
  NV_NVDLA_CACC_CALC_int16 r_i16_ep(.nvdla_core_clk(ref_clk), .nvdla_core_rstn(rstn), .cfg_truncate(ref_trunc), .in_data(ref_di_ep[37:0]), .in_op(ref_op_ep[47:0]), .in_op_valid(ref_op_vld_ep), .in_sel(ref_sel), .in_valid(ref_vld), .out_final_data(ref_i16_ep_fin),.out_final_sat(), .out_final_valid(), .out_partial_data(ref_i16_ep_part),.out_partial_valid());
  NV_NVDLA_CACC_CALC_fp_48b r_fp_ep(.nvdla_core_clk(ref_clk), .nvdla_core_rstn(rstn), .in_data(ref_di_ep[43:0]), .in_op(ref_op_ep[47:0]), .in_op_valid(ref_op_vld_ep), .in_sel(ref_sel), .in_valid(ref_vld), .out_final_data(ref_fp_ep_fin), .out_final_valid(), .out_partial_data(ref_fp_ep_part), .out_partial_valid());

  NV_NVDLA_CACC_CALC_int8  r_i8_op (.nvdla_core_clk(ref_clk), .nvdla_core_rstn(rstn), .cfg_truncate(ref_trunc), .in_data(ref_di_op[21:0]), .in_op(ref_op_op[33:0]), .in_op_valid(ref_op_vld_op), .in_sel(ref_sel), .in_valid(ref_vld), .out_final_data(ref_i8_op_fin), .out_final_sat(), .out_final_valid(), .out_partial_data(ref_i8_op_part), .out_partial_valid());
  NV_NVDLA_CACC_CALC_int16 r_i16_op(.nvdla_core_clk(ref_clk), .nvdla_core_rstn(rstn), .cfg_truncate(ref_trunc), .in_data(ref_di_op[37:0]), .in_op(ref_op_op[47:0]), .in_op_valid(ref_op_vld_op), .in_sel(ref_sel), .in_valid(ref_vld), .out_final_data(ref_i16_op_fin),.out_final_sat(), .out_final_valid(), .out_partial_data(ref_i16_op_part),.out_partial_valid());
  NV_NVDLA_CACC_CALC_fp_48b r_fp_op(.nvdla_core_clk(ref_clk), .nvdla_core_rstn(rstn), .in_data(ref_di_op[43:0]), .in_op(ref_op_op[47:0]), .in_op_valid(ref_op_vld_op), .in_sel(ref_sel), .in_valid(ref_vld), .out_final_data(ref_fp_op_fin), .out_final_valid(), .out_partial_data(ref_fp_op_part), .out_partial_valid());

  NV_NVDLA_CACC_CALC_int8  r_i8_ee (.nvdla_core_clk(ref_clk), .nvdla_core_rstn(rstn), .cfg_truncate(ref_trunc), .in_data(ref_di_ee), .in_op(ref_op_ee), .in_op_valid(ref_op_vld_ee), .in_sel(ref_sel), .in_valid(ref_vld), .out_final_data(ref_i8_ee_fin), .out_final_sat(), .out_final_valid(), .out_partial_data(ref_i8_ee_part), .out_partial_valid());
  NV_NVDLA_CACC_CALC_int8  r_i8_oe (.nvdla_core_clk(ref_clk), .nvdla_core_rstn(rstn), .cfg_truncate(ref_trunc), .in_data(ref_di_oe), .in_op(ref_op_oe), .in_op_valid(ref_op_vld_oe), .in_sel(ref_sel), .in_valid(ref_vld), .out_final_data(ref_i8_oe_fin), .out_final_sat(), .out_final_valid(), .out_partial_data(ref_i8_oe_part), .out_partial_valid());

  // Ideal reference SRAM array & expected output queue
  reg  [47:0] ideal_abuf [0:7][0:255];
  reg [129:0] exp_queue  [0:4095];
  integer     exp_wr_ptr, exp_rd_ptr;
  integer     errors;
  integer     ext_men_violations;
  reg         exp_intr_sel;
  integer     intr_count;
  reg  [31:0] prng;

  function [31:0] next_rng(input [31:0] cur);
    begin
      next_rng = {cur[30:0], cur[31] ^ cur[21] ^ cur[1] ^ cur[0]};
    end
  endfunction

  // Monitor extension banks 4..7 A_MEN in INT16/FP16 modes
  wire [3:0] ext_men = {
    dut.u_assembly_buffer.u_accu_abuf_7.A_MEN,
    dut.u_assembly_buffer.u_accu_abuf_6.A_MEN,
    dut.u_assembly_buffer.u_accu_abuf_5.A_MEN,
    dut.u_assembly_buffer.u_accu_abuf_4.A_MEN
  };

  reg check_non_int8_active;
  always @(posedge clk) begin
    if (rstn && check_non_int8_active) begin
      if (|ext_men) begin
        ext_men_violations = ext_men_violations + 1;
        if (ext_men_violations <= 5)
          $display("[ERR] Spurious extension bank A_MEN=%b in non-INT8 mode at t=%0t", ext_men, $time);
      end
    end
  end

  // Check output stream & hold stability under backpressure + ping-pong done interrupt
  reg         prev_vld_stalled;
  reg [129:0] prev_pd_stalled;
  reg         pend_intr_chk;
  reg   [1:0] pend_intr_exp;

  always @(posedge clk or negedge rstn) begin
    if (!rstn) begin
      prev_vld_stalled <= 1'b0;
      prev_pd_stalled  <= 130'd0;
      pend_intr_chk    <= 1'b0;
      pend_intr_exp    <= 2'b00;
    end else begin
      // Check interrupt from previous cycle
      if (pend_intr_chk) begin
        if (cacc2glb_done_intr_pd !== pend_intr_exp) begin
          $display("[ERR] Done interrupt mismatch at t=%0t: got=%b exp=%b", $time, cacc2glb_done_intr_pd, pend_intr_exp);
          errors = errors + 1;
        end else begin
          intr_count = intr_count + 1;
        end
        pend_intr_chk <= 1'b0;
      end else if (cacc2glb_done_intr_pd !== 2'b00) begin
        $display("[ERR] Unexpected spurious done interrupt=%b at t=%0t", cacc2glb_done_intr_pd, $time);
        errors = errors + 1;
      end

      // Check valid/data stability when stalled
      if (prev_vld_stalled) begin
        if (cacc2sdp_valid !== 1'b1 || cacc2sdp_pd !== prev_pd_stalled) begin
          $display("[ERR] Output unstable during cacc2sdp_ready=0 stall at t=%0t", $time);
          errors = errors + 1;
        end
      end

      if (cacc2sdp_valid && !cacc2sdp_ready) begin
        prev_vld_stalled <= 1'b1;
        prev_pd_stalled  <= cacc2sdp_pd;
      end else begin
        prev_vld_stalled <= 1'b0;
      end

      if (cacc2sdp_valid && cacc2sdp_ready) begin
        if (exp_rd_ptr >= exp_wr_ptr) begin
          $display("[ERR] Unexpected extra output beat at t=%0t: pd=%h", $time, cacc2sdp_pd);
          errors = errors + 1;
        end else begin
          if (cacc2sdp_pd !== exp_queue[exp_rd_ptr]) begin
            if (errors < 12)
              $display("[ERR] Beat %0d mismatch at t=%0t:\n  got=%h\n  exp=%h", exp_rd_ptr, $time, cacc2sdp_pd, exp_queue[exp_rd_ptr]);
            errors = errors + 1;
          end
          if (exp_queue[exp_rd_ptr][129]) begin
            pend_intr_chk <= 1'b1;
            pend_intr_exp <= exp_intr_sel ? 2'b10 : 2'b01;
            exp_intr_sel  <= ~exp_intr_sel;
          end
          exp_rd_ptr = exp_rd_ptr + 1;
        end
      end
    end
  end

  // Drive random cacc2sdp_ready backpressure (average ~65% ready, with 3-cycle stall bursts,
  // ensuring delivery FIFO doesn't overflow while exercising full d1/d2/d3 skid backpressure)
  integer stall_burst;
  always @(posedge clk or negedge rstn) begin
    if (!rstn) begin
      cacc2sdp_ready <= 1'b1;
      stall_burst    <= 0;
    end else begin
      prng = next_rng(prng);
      if (stall_burst > 0) begin
        cacc2sdp_ready <= 1'b0;
        stall_burst    <= stall_burst - 1;
      end else if ((prng[3:0] < 4'd5) && ((exp_wr_ptr - exp_rd_ptr) < 10)) begin
        cacc2sdp_ready <= 1'b0;
        stall_burst    <= (prng[5:4] == 2'b11) ? 2 : 1;
      end else begin
        cacc2sdp_ready <= 1'b1;
      end
    end
  end

  task step_ref_calc(input [1:0] prec, input is_final);
    integer c, ncyc;
    begin
      ncyc = (prec == 2'h2) ? (is_final ? 4 : 3) : 2;
      ref_vld = 1'b1;
      #0.2; ref_clk = 1'b1; #0.2; ref_clk = 1'b0;
      ref_vld = 1'b0;
      for (c = 1; c < ncyc; c = c + 1) begin
        #0.2; ref_clk = 1'b1; #0.2; ref_clk = 1'b0;
      end
      #0.1;
    end
  endtask

  task run_layer(
    input [1:0] prec,
    input       wg,
    input [4:0] trunc,
    input integer num_channels,
    input integer num_stripes,
    input integer stripe_beats,
    input       allow_bubbles
  );
    integer ch, st, bt;
    integer b_ep, b_op, b_ee, b_oe;
    reg [7:0] addr;
    reg [7:0] bmask;
    reg       ch_st, st_end, ch_end, ly_end;
    reg [43:0] d_ep, d_op;
    reg [21:0] d_ee, d_oe;
    reg [31:0] f_ep, f_op, f_ee, f_oe;
    integer wait_guard;
    begin
      @(posedge clk);
      check_non_int8_active <= (prec != 2'h0);
      reg2dp_proc_precision <= prec;
      reg2dp_conv_mode      <= wg;
      reg2dp_clip_truncate  <= trunc;
      reg2dp_op_en          <= 1'b1;
      mac2accu_pvld         <= 1'b0;
      @(posedge clk);

      for (ch = 0; ch < num_channels; ch = ch + 1) begin
        for (st = 0; st < num_stripes; st = st + 1) begin
          ch_st  = (st == 0);
          ch_end = (st == num_stripes - 1);
          for (bt = 0; bt < stripe_beats; bt = bt + 1) begin
            // Optional random MAC bubble
            prng = next_rng(prng);
            if (allow_bubbles && (prng[2:0] == 3'b001)) begin
              mac2accu_pvld <= 1'b0;
              @(posedge clk);
            end
            // Avoid delivery FIFO overflow if ready was stalled heavily on final stripe
            while (ch_end && ((exp_wr_ptr - exp_rd_ptr) >= 5)) begin
              mac2accu_pvld <= 1'b0;
              @(posedge clk);
            end

            st_end = (bt == stripe_beats - 1);
            ly_end = st_end && ch_end && (ch == num_channels - 1);

            prng = next_rng(prng);
            if (prec == 2'h2) begin
              // Valid normalized/unnormalized FP16 MAC partial sums: [43:38] exp around 26..35, [37:0] signed mant
              d_ep = { (6'd27 + {3'd0, prng[2:0]}), {{20{prng[19]}}, prng[19:2]} };
              prng = next_rng(prng);
              d_op = { (6'd27 + {3'd0, prng[2:0]}), {{20{prng[19]}}, prng[19:2]} };
            end else begin
              d_ep = {{20{prng[23]}}, prng[23:0]};
              prng = next_rng(prng);
              d_op = {{20{prng[23]}}, prng[23:0]};
            end
            prng = next_rng(prng);
            d_ee = {{6{prng[15]}}, prng[15:0]};
            prng = next_rng(prng);
            d_oe = {{6{prng[15]}}, prng[15:0]};

            if (wg) begin
              addr  = bt[8:1];
              bmask = bt[0] ? ((prec == 2'h0) ? 8'b1100_1100 : 8'b0000_1100)
                            : ((prec == 2'h0) ? 8'b0011_0011 : 8'b0000_0011);
            end else begin
              addr  = bt[9:2];
              bmask = (prec == 2'h0) ? ({4'b0001 << bt[1:0], 4'b0001 << bt[1:0]})
                                     : ({4'b0000, 4'b0001 << bt[1:0]});
            end

            mac2accu_pvld          <= 1'b1;
            mac2accu_mask          <= 8'hFF;
            mac2accu_pd            <= {ly_end, ch_end, st_end, (bt == 0), 5'd0};
            mac2accu_data_even_pri <= d_ep;
            mac2accu_data_odd_pri  <= d_op;
            mac2accu_data_even_ext <= d_ee;
            mac2accu_data_odd_ext  <= d_oe;

            // Golden reference update
            b_ep = bmask[2] ? 2 : 0;
            b_op = bmask[3] ? 3 : 1;
            b_ee = bmask[6] ? 6 : 4;
            b_oe = bmask[7] ? 7 : 5;

            ref_trunc     = trunc;
            ref_sel       = ch_end;
            ref_di_ep     = d_ep;
            ref_di_op     = d_op;
            ref_di_ee     = d_ee;
            ref_di_oe     = d_oe;
            ref_op_ep     = ideal_abuf[b_ep][addr];
            ref_op_op     = ideal_abuf[b_op][addr];
            ref_op_ee     = ideal_abuf[b_ee][addr][33:0];
            ref_op_oe     = ideal_abuf[b_oe][addr][33:0];
            ref_op_vld_ep = (!ch_st) && (|(bmask & 8'b0000_0101));
            ref_op_vld_op = (!ch_st) && (|(bmask & 8'b0000_1010));
            ref_op_vld_ee = (!ch_st) && (|(bmask & 8'b0101_0000));
            ref_op_vld_oe = (!ch_st) && (|(bmask & 8'b1010_0000));

            step_ref_calc(prec, ch_end);

            if (!ch_end) begin
              if (|(bmask & 8'b0000_0101))
                ideal_abuf[b_ep][addr] = (prec == 2'h2) ? ref_fp_ep_part : (prec == 2'h1) ? ref_i16_ep_part : {14'd0, ref_i8_ep_part};
              if (|(bmask & 8'b0000_1010))
                ideal_abuf[b_op][addr] = (prec == 2'h2) ? ref_fp_op_part : (prec == 2'h1) ? ref_i16_op_part : {14'd0, ref_i8_op_part};
              if (|(bmask & 8'b0101_0000))
                ideal_abuf[b_ee][addr] = {14'd0, ref_i8_ee_part};
              if (|(bmask & 8'b1010_0000))
                ideal_abuf[b_oe][addr] = {14'd0, ref_i8_oe_part};
            end else begin
              f_ep = (|(bmask & 8'b0000_0101)) ? ((prec == 2'h2) ? ref_fp_ep_fin : (prec == 2'h1) ? ref_i16_ep_fin : ref_i8_ep_fin) : 32'd0;
              f_op = (|(bmask & 8'b0000_1010)) ? ((prec == 2'h2) ? ref_fp_op_fin : (prec == 2'h1) ? ref_i16_op_fin : ref_i8_op_fin) : 32'd0;
              f_ee = (|(bmask & 8'b0101_0000)) ? ref_i8_ee_fin : 32'd0;
              f_oe = (|(bmask & 8'b1010_0000)) ? ref_i8_oe_fin : 32'd0;
              exp_queue[exp_wr_ptr] = {ly_end, 1'b0, f_oe, f_ee, f_op, f_ep};
              exp_wr_ptr = exp_wr_ptr + 1;
            end

            @(posedge clk);
          end
        end
      end

      mac2accu_pvld <= 1'b0;
      // Wait for dp2reg_done & drain output queue before switching reg2dp_*
      wait_guard = 0;
      while ((exp_rd_ptr < exp_wr_ptr || pend_intr_chk) && wait_guard < 500) begin
        @(posedge clk);
        wait_guard = wait_guard + 1;
      end
      if (wait_guard >= 500) begin
        $display("[ERR] Timeout draining layer outputs (rd=%0d wr=%0d)", exp_rd_ptr, exp_wr_ptr);
        errors = errors + 1;
      end
      reg2dp_op_en <= 1'b0;
      repeat (4) @(posedge clk);
      check_non_int8_active <= 1'b0;
    end
  endtask

  integer wait_guard;
  initial begin
    rstn                   = 1'b0;
    reg2dp_op_en           = 1'b0;
    reg2dp_conv_mode       = 1'b0;
    reg2dp_proc_precision  = 2'h0;
    reg2dp_clip_truncate   = 5'd0;
    mac2accu_pvld          = 1'b0;
    mac2accu_mask          = 8'd0;
    mac2accu_pd            = 9'd0;
    mac2accu_data_even_pri = 44'd0;
    mac2accu_data_odd_pri  = 44'd0;
    mac2accu_data_even_ext = 22'd0;
    mac2accu_data_odd_ext  = 22'd0;
    ref_vld                = 1'b0;
    exp_wr_ptr             = 0;
    exp_rd_ptr             = 0;
    errors                 = 0;
    ext_men_violations     = 0;
    exp_intr_sel           = 1'b0;
    intr_count             = 0;
    check_non_int8_active  = 1'b0;
    `ifdef TB_SEED
    prng                   = `TB_SEED;
`else
    prng                   = 32'hCACC_2026;
`endif

    repeat (6) @(posedge clk);
    rstn = 1'b1;
    repeat (4) @(posedge clk);

    // 1. INT8 Direct (x2), multi-channel (2 ch x 3 stripes x 12 beats), bubbles
    run_layer(2'h0, 1'b0, 5'd2, 2, 3, 12, 1'b1);
    // 2. INT16 Direct (x1), multi-channel (2 ch x 3 stripes x 8 beats), zero bubbles
    run_layer(2'h1, 1'b0, 5'd3, 2, 3, 8,  1'b0);
    // 3. FP16 Direct (x1), 8-beat stripe (exact same-address RAW collision!) + 12-beat stripe (diff-addr 1P R/W collision!)
    run_layer(2'h2, 1'b0, 5'd0, 2, 3, 8,  1'b0);
    run_layer(2'h2, 1'b0, 5'd0, 1, 3, 12, 1'b1);
    // 4. INT8 Winograd (x8 dual-pair), 100% 1P SRAM utilization (2 ch x 3 stripes x 10 beats), zero bubbles!
    run_layer(2'h0, 1'b1, 5'd1, 2, 3, 10, 1'b0);
    // 5. INT16 Winograd (x4 dual-pair), checking zero ext_men toggles!
    run_layer(2'h1, 1'b1, 5'd4, 2, 3, 10, 1'b1);
    // 6. FP16 Direct multi-channel 16-beat continuous RMW + INT8 Direct 8-beat back-to-back RAW!
    run_layer(2'h2, 1'b0, 5'd0, 2, 3, 16, 1'b0);
    run_layer(2'h0, 1'b0, 5'd3, 2, 3, 8,  1'b0);

    repeat (10) @(posedge clk);
    $display("SUMMARY: beats=%0d intrs=%0d errors=%0d ext_men_viol=%0d", exp_rd_ptr, intr_count, errors, ext_men_violations);
    if (errors == 0 && ext_men_violations == 0 && intr_count == 8) begin
      $display("TEST_PASS");
      $finish(0);
    end else begin
      $display("TEST_FAIL");
      $finish(1);
    end
  end

endmodule
