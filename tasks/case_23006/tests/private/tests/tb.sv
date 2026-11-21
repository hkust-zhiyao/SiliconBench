`timescale 1ns/1ps

module tb;
  reg nvdla_core_clk;
  reg nvdla_core_rstn;

  initial begin
    nvdla_core_clk = 1'b0;
    forever #5 nvdla_core_clk = ~nvdla_core_clk;
  end

  // =========================================================================
  // Shared FP17 Oracle Helper (uses read-only HLS_fp16_to_fp17 & HLS_fp17_add)
  // =========================================================================
  reg  [15:0] orc_f16_in;
  reg         orc_f16_vld;
  wire        orc_f16_rdy;
  wire [16:0] orc_f17_out;
  wire        orc_f17_vld;
  reg         orc_f17_rdy;

  HLS_fp16_to_fp17 u_orc_f16_to_f17 (
    .nvdla_core_clk  (nvdla_core_clk),
    .nvdla_core_rstn (nvdla_core_rstn),
    .chn_a_rsc_z     (orc_f16_in),
    .chn_a_rsc_vz    (orc_f16_vld),
    .chn_a_rsc_lz    (orc_f16_rdy),
    .chn_o_rsc_z     (orc_f17_out),
    .chn_o_rsc_vz    (orc_f17_rdy),
    .chn_o_rsc_lz    (orc_f17_vld)
  );

  reg  [16:0] orc_add_a;
  reg         orc_add_a_vld;
  wire        orc_add_a_rdy;
  reg  [16:0] orc_add_b;
  reg         orc_add_b_vld;
  wire        orc_add_b_rdy;
  wire [16:0] orc_add_z;
  wire        orc_add_z_vld;
  reg         orc_add_z_rdy;

  HLS_fp17_add u_orc_f17_add (
    .nvdla_core_clk  (nvdla_core_clk),
    .nvdla_core_rstn (nvdla_core_rstn),
    .chn_a_rsc_z     (orc_add_a),
    .chn_a_rsc_vz    (orc_add_a_vld),
    .chn_a_rsc_lz    (orc_add_a_rdy),
    .chn_b_rsc_z     (orc_add_b),
    .chn_b_rsc_vz    (orc_add_b_vld),
    .chn_b_rsc_lz    (orc_add_b_rdy),
    .chn_o_rsc_z     (orc_add_z),
    .chn_o_rsc_vz    (orc_add_z_rdy),
    .chn_o_rsc_lz    (orc_add_z_vld)
  );

  task automatic eval_fp16_to_fp17(input [15:0] f16, output [16:0] f17);
    integer guard;
    begin
      @(negedge nvdla_core_clk);
      orc_f16_in  = f16;
      orc_f16_vld = 1'b1;
      orc_f17_rdy = 1'b1;
      #1;
      guard = 0;
      while (!orc_f16_rdy) begin
        @(negedge nvdla_core_clk);
        #1;
        guard = guard + 1;
        if (guard > 50) $fatal(1, "Timeout waiting orc_f16_rdy");
      end
      @(negedge nvdla_core_clk);
      orc_f16_vld = 1'b0;
      #1;
      while (!orc_f17_vld) begin
        @(negedge nvdla_core_clk);
        #1;
        guard = guard + 1;
        if (guard > 50) $fatal(1, "Timeout waiting orc_f17_vld");
      end
      f17 = orc_f17_out;
      @(negedge nvdla_core_clk);
      orc_f17_rdy = 1'b0;
    end
  endtask

  task automatic eval_fp17_add(input [16:0] a, input [16:0] b, output [16:0] z);
    integer guard;
    begin
      @(negedge nvdla_core_clk);
      orc_add_a     = a;
      orc_add_b     = b;
      orc_add_a_vld = 1'b1;
      orc_add_b_vld = 1'b1;
      orc_add_z_rdy = 1'b1;
      #1;
      guard = 0;
      while (!(orc_add_a_rdy && orc_add_b_rdy)) begin
        @(negedge nvdla_core_clk);
        #1;
        guard = guard + 1;
        if (guard > 50) $fatal(1, "Timeout waiting orc_add_rdy");
      end
      @(negedge nvdla_core_clk);
      orc_add_a_vld = 1'b0;
      orc_add_b_vld = 1'b0;
      #1;
      while (!orc_add_z_vld) begin
        @(negedge nvdla_core_clk);
        #1;
        guard = guard + 1;
        if (guard > 50) $fatal(1, "Timeout waiting orc_add_z_vld");
      end
      z = orc_add_z;
      @(negedge nvdla_core_clk);
      orc_add_z_rdy = 1'b0;
    end
  endtask

  // =========================================================================
  // Subsystem DUT: NV_NVDLA_PDP_nan -> NV_NVDLA_PDP_CORE_cal1d (+ 8x unit1d)
  // =========================================================================
  reg         dp2reg_done;
  reg  [75:0] rdma_pd;
  reg         rdma_vld;
  wire        rdma_rdy;

  reg  [75:0] sdp_pd;
  reg         sdp_vld;
  wire        sdp_rdy;

  reg         reg2dp_flying_mode; // 1 = offline RDMA, 0 = flying SDP
  reg   [1:0] reg2dp_input_data;  // 0 = INT8, 1 = INT16, 2 = FP16
  reg         reg2dp_nan_to_zero;
  reg         reg2dp_op_en;
  reg   [1:0] pooling_type_cfg;   // 0 = AVE, 1 = MAX, 2 = MIN

  reg   [2:0] reg2dp_pad_left;
  reg   [2:0] reg2dp_pad_right;
  reg  [12:0] pooling_channel_cfg;
  reg   [9:0] pooling_fwidth_cfg;
  reg   [9:0] pooling_mwidth_cfg;
  reg   [9:0] pooling_lwidth_cfg;
  reg   [9:0] pooling_out_fwidth_cfg;
  reg   [9:0] pooling_out_mwidth_cfg;
  reg   [9:0] pooling_out_lwidth_cfg;
  reg   [2:0] reg2dp_kernel_width;
  reg   [3:0] reg2dp_kernel_stride_width;
  reg   [7:0] pooling_splitw_num_cfg;
  reg  [12:0] reg2dp_cube_in_height;
  reg  [12:0] reg2dp_cube_in_width;
  reg  [12:0] reg2dp_cube_out_width;
  reg  [18:0] reg2dp_pad_value_1x_cfg;
  reg  [18:0] reg2dp_pad_value_2x_cfg;
  reg  [18:0] reg2dp_pad_value_3x_cfg;
  reg  [18:0] reg2dp_pad_value_4x_cfg;
  reg  [18:0] reg2dp_pad_value_5x_cfg;
  reg  [18:0] reg2dp_pad_value_6x_cfg;
  reg  [18:0] reg2dp_pad_value_7x_cfg;

  wire [31:0] dp2reg_inf_input_num;
  wire [31:0] dp2reg_nan_input_num;
  wire [75:0] nan_preproc_pd;
  wire        nan_preproc_pvld;
  wire        nan_preproc_prdy;

  wire        pdp_op_start;
  wire [111:0] pooling1d_pd;
  wire        pooling1d_pvld;
  reg         pooling1d_prdy;

  wire reg2dp_int8_en  = (reg2dp_input_data == 2'h0);
  wire reg2dp_int16_en = (reg2dp_input_data == 2'h1);
  wire reg2dp_fp16_en  = (reg2dp_input_data == 2'h2);

  NV_NVDLA_PDP_nan u_nan (
    .nvdla_core_clk       (nvdla_core_clk),
    .nvdla_core_rstn      (nvdla_core_rstn),
    .dp2reg_done          (dp2reg_done),
    .nan_preproc_prdy     (nan_preproc_prdy),
    .pdp_rdma2dp_pd       (rdma_pd),
    .pdp_rdma2dp_valid    (rdma_vld),
    .reg2dp_flying_mode   (reg2dp_flying_mode),
    .reg2dp_input_data    (reg2dp_input_data),
    .reg2dp_nan_to_zero   (reg2dp_nan_to_zero),
    .reg2dp_op_en         (reg2dp_op_en),
    .dp2reg_inf_input_num (dp2reg_inf_input_num),
    .dp2reg_nan_input_num (dp2reg_nan_input_num),
    .nan_preproc_pd       (nan_preproc_pd),
    .nan_preproc_pvld     (nan_preproc_pvld),
    .pdp_rdma2dp_ready    (rdma_rdy)
  );

  NV_NVDLA_PDP_CORE_cal1d u_cal1d (
    .nvdla_core_clk             (nvdla_core_clk),
    .nvdla_core_rstn            (nvdla_core_rstn),
    .datin_src_cfg              (reg2dp_flying_mode),
    .dp2reg_done                (dp2reg_done),
    .nvdla_op_gated_clk_fp16    (nvdla_core_clk),
    .padding_h_cfg              (reg2dp_pad_left),
    .pdp_rdma2dp_pd             (nan_preproc_pd),
    .pdp_rdma2dp_valid          (nan_preproc_pvld),
    .pooling1d_prdy             (pooling1d_prdy),
    .pooling_channel_cfg        (pooling_channel_cfg),
    .pooling_fwidth_cfg         (pooling_fwidth_cfg),
    .pooling_lwidth_cfg         (pooling_lwidth_cfg),
    .pooling_mwidth_cfg         (pooling_mwidth_cfg),
    .pooling_out_fwidth_cfg     (pooling_out_fwidth_cfg),
    .pooling_out_lwidth_cfg     (pooling_out_lwidth_cfg),
    .pooling_out_mwidth_cfg     (pooling_out_mwidth_cfg),
    .pooling_size_h_cfg         (reg2dp_kernel_width),
    .pooling_splitw_num_cfg     (pooling_splitw_num_cfg),
    .pooling_stride_h_cfg       (reg2dp_kernel_stride_width),
    .pooling_type_cfg           (pooling_type_cfg),
    .pwrbus_ram_pd              (32'd0),
    .reg2dp_cube_in_height      (reg2dp_cube_in_height),
    .reg2dp_cube_in_width       (reg2dp_cube_in_width),
    .reg2dp_cube_out_width      (reg2dp_cube_out_width),
    .reg2dp_fp16_en             (reg2dp_fp16_en),
    .reg2dp_input_data          (reg2dp_input_data),
    .reg2dp_int16_en            (reg2dp_int16_en),
    .reg2dp_int8_en             (reg2dp_int8_en),
    .reg2dp_kernel_stride_width (reg2dp_kernel_stride_width),
    .reg2dp_kernel_width        (reg2dp_kernel_width),
    .reg2dp_op_en               (reg2dp_op_en),
    .reg2dp_pad_left            (reg2dp_pad_left),
    .reg2dp_pad_right           (reg2dp_pad_right),
    .reg2dp_pad_right_cfg       (reg2dp_pad_right),
    .reg2dp_pad_value_1x_cfg    (reg2dp_pad_value_1x_cfg),
    .reg2dp_pad_value_2x_cfg    (reg2dp_pad_value_2x_cfg),
    .reg2dp_pad_value_3x_cfg    (reg2dp_pad_value_3x_cfg),
    .reg2dp_pad_value_4x_cfg    (reg2dp_pad_value_4x_cfg),
    .reg2dp_pad_value_5x_cfg    (reg2dp_pad_value_5x_cfg),
    .reg2dp_pad_value_6x_cfg    (reg2dp_pad_value_6x_cfg),
    .reg2dp_pad_value_7x_cfg    (reg2dp_pad_value_7x_cfg),
    .sdp2pdp_pd                 (sdp_pd),
    .sdp2pdp_valid              (sdp_vld),
    .pdp_op_start               (pdp_op_start),
    .pdp_rdma2dp_ready          (nan_preproc_prdy),
    .pooling1d_pd               (pooling1d_pd),
    .pooling1d_pvld             (pooling1d_pvld),
    .sdp2pdp_ready              (sdp_rdy)
  );

  // =========================================================================
  // Pure Arithmetic Golden Helpers
  // =========================================================================
  function automatic bit is_fp16_nan(input [15:0] v);
    is_fp16_nan = (&v[14:10]) && (|v[9:0]);
  endfunction

  function automatic bit is_fp16_inf(input [15:0] v);
    is_fp16_inf = (&v[14:10]) && !(|v[9:0]);
  endfunction

  function automatic [15:0] fp16_min_comb(input [15:0] a, input [15:0] b);
    if (is_fp16_nan(a))
      fp16_min_comb = a;
    else if (is_fp16_nan(b))
      fp16_min_comb = b;
    else if (!a[15] && !b[15])
      fp16_min_comb = (a[14:0] > b[14:0]) ? b : a;
    else if (a[15] && b[15])
      fp16_min_comb = (a[14:0] > b[14:0]) ? a : b;
    else if (a[15] && !b[15])
      fp16_min_comb = a;
    else
      fp16_min_comb = b;
  endfunction

  function automatic [15:0] fp16_max_comb(input [15:0] a, input [15:0] b);
    if (is_fp16_nan(a))
      fp16_max_comb = a;
    else if (is_fp16_nan(b))
      fp16_max_comb = b;
    else if (!a[15] && !b[15])
      fp16_max_comb = (a[14:0] > b[14:0]) ? a : b;
    else if (a[15] && b[15])
      fp16_max_comb = (a[14:0] > b[14:0]) ? b : a;
    else if (a[15] && !b[15])
      fp16_max_comb = b;
    else
      fp16_max_comb = a;
  endfunction

  // =========================================================================
  // Cube Stimulus & Golden Scoreboard Storage
  // Max W=32, H=4, Surfaces=4, 4 pos_c beats per pixel (64 bits each)
  // =========================================================================
  reg [63:0] cube_mem [0:3][0:3][0:31][0:3]; // [surf][y][x][pos_c]
  reg [111:0] exp_fifo [0:4095];
  integer exp_wr_ptr;
  integer exp_rd_ptr;
  integer seed_val;
  integer init_seed;
  reg stall_enable;

  function automatic [31:0] next_rand();
    begin
      seed_val = seed_val * 32'd1664525 + 32'd1013904223;
      next_rand = seed_val;
    end
  endfunction

  // Monitor output beats
  always @(posedge nvdla_core_clk) begin
    if (nvdla_core_rstn) begin
      if (stall_enable)
        pooling1d_prdy <= (next_rand() % 100) < 65;
      else
        pooling1d_prdy <= 1'b1;

      if (pooling1d_pvld && pooling1d_prdy) begin
        if (exp_rd_ptr >= exp_wr_ptr) begin
          $display("FAIL: Unexpected extra pooling1d output beat #%0d: got %028h", exp_rd_ptr, pooling1d_pd);
          $fatal(1, "Extra output beat");
        end
        if (pooling1d_pd !== exp_fifo[exp_rd_ptr]) begin
          $display("FAIL: Mismatch at output beat #%0d: got %028h, expected %028h",
                   exp_rd_ptr, pooling1d_pd, exp_fifo[exp_rd_ptr]);
          $fatal(1, "Output data mismatch");
        end
        exp_rd_ptr = exp_rd_ptr + 1;
      end
    end
  end

  // Run a full 1D layer & check outputs + NaN/Inf counters
  task automatic run_layer_test(
    input string name,
    input bit    flying,       // 1 = offline RDMA (flying_mode=1), 0 = flying SDP (flying_mode=0)
    input [1:0]  dtype,        // 0=INT8, 1=INT16, 2=FP16
    input [1:0]  pmethod,      // 0=AVE, 1=MAX, 2=MIN
    input bit    nan_to_zero,
    input int    W,
    input int    H,
    input int    num_surf,     // number of 32B surfaces (each has pos_c=0..3)
    input int    K,            // 1..8
    input int    S,            // 1..8
    input int    PL,           // 0..K-1
    input int    PR,           // 0..K-1
    input int    split_num,    // 0, 1, or 2
    input int    W_f,          // used when split_num > 0
    input int    W_m,          // used when split_num == 2
    input int    W_l,          // used when split_num > 0
    input int    pad_base_val, // signed int for INT8/INT16, or FP16 raw bits for FP16
    input int    nan_mode      // 0=none, 1=random across all beats + terminal beat, 2=terminal cube_end beat ONLY
  );
    int W_out_total, W_out_f, W_out_m, W_out_l;
    int overlap_mag;
    int s_idx, surf, y, x, cpos, lane;
    int x_start, x_len, w_out_stripe, ox, kx, src_x, active_cnt, pad_idx;
    reg [63:0] beat64, clean64;
    reg [15:0] w16, cur16, acc16;
    reg [16:0] f17_elem, f17_acc, pad_f17 [0:7];
    reg [18:0] pad_cfg [1:7];
    reg signed [10:0] acc8 [0:7];
    reg signed [21:0] acc16s [0:3];
    reg [111:0] exp_word;
    int exp_nan_cnt, exp_inf_cnt;
    int total_beats, beat_idx;
    int guard;
    begin
      W_out_total = (PL + W + PR - K) / S + 1;
      if (split_num == 0) begin
        W_out_f = W_out_total;
        W_out_m = 0;
        W_out_l = 0;
      end else if (split_num == 1) begin
        W_out_f = (PL + W_f - K) / S + 1;
        W_out_m = 0;
        W_out_l = W_out_total - W_out_f;
      end else begin
        W_out_f = (PL + W_f - K) / S + 1;
        W_out_m = W_m / S;
        W_out_l = W_out_total - W_out_f - (split_num - 1) * W_out_m;
      end
      overlap_mag = (K >= S) ? (K - S) : (S - K);

      // Prepare pad_cfg[1..7]
      pad_f17[0] = 17'd0;
      for (int k = 1; k <= 7; k++) begin
        if (dtype == 2'h0) begin
          int pv = k * pad_base_val;
          pad_cfg[k] = $signed(pv);
          pad_f17[k] = 17'd0;
        end else if (dtype == 2'h1) begin
          int pv = k * pad_base_val;
          pad_cfg[k] = $signed(pv);
          pad_f17[k] = 17'd0;
        end else begin
          // Convert base FP16 pad value to FP17 and accumulate k times
          reg [16:0] base_f17, sum_f17;
          eval_fp16_to_fp17(pad_base_val[15:0], base_f17);
          sum_f17 = base_f17;
          for (int m = 1; m < k; m++) begin
            eval_fp17_add(sum_f17, base_f17, sum_f17);
          end
          pad_f17[k] = sum_f17;
          pad_cfg[k] = {{2{sum_f17[16]}}, sum_f17};
        end
      end

      // Populate cube_mem
      for (surf = 0; surf < num_surf; surf++) begin
        for (y = 0; y < H; y++) begin
          for (x = 0; x < W; x++) begin
            for (cpos = 0; cpos < 4; cpos++) begin
              beat64 = 64'd0;
              for (lane = 0; lane < 4; lane++) begin
                reg [31:0] r = next_rand();
                if (dtype == 2'h0) begin
                  reg signed [7:0] b0 = $signed(r[7:0]) >>> 1;   // [-64..63]
                  reg signed [7:0] b1 = $signed(r[15:8]) >>> 1;
                  if ((nan_mode != 0) && ((r[23:20] == 4'd0))) begin
                    // Test that 0x7eXX in INT8 is NOT flushed as FP16 NaN!
                    w16 = 16'h7e25;
                  end else begin
                    w16 = {b1, b0};
                  end
                end else if (dtype == 2'h1) begin
                  reg signed [15:0] s16 = $signed(r[15:0]) >>> 2; // [-8192..8191]
                  if ((nan_mode != 0) && (r[23:20] == 4'd1))
                    w16 = 16'hfc01;
                  else
                    w16 = s16;
                end else begin
                  // FP16
                  bit is_final_cube_beat = (surf == num_surf - 1) && (y == H - 1) && (x == W - 1) && (cpos == 3);
                  if (is_final_cube_beat && (nan_mode == 2)) begin
                    // Terminal-beat-ONLY NaN/Inf stimulus (all earlier beats are strictly finite)
                    if (pmethod == 2'h0) begin
                      case (lane)
                        0: w16 = 16'h7e01;
                        1: w16 = 16'hfe02;
                        2: w16 = 16'h7e03;
                        default: w16 = 16'hfe77;
                      endcase
                    end else if (!nan_to_zero) begin
                      case (lane)
                        0: w16 = 16'hfe01;
                        1: w16 = 16'h7c00;
                        2: w16 = 16'h7e55;
                        default: w16 = 16'h7e01;
                      endcase
                    end else begin
                      case (lane)
                        0: w16 = 16'hfc00;
                        1: w16 = 16'h7c00;
                        2: w16 = 16'hfc00;
                        default: w16 = 16'hfe11;
                      endcase
                    end
                  end else if (is_final_cube_beat && (nan_mode == 1)) begin
                    // Ensure terminal cube_end beat also carries NaN/Inf in random mode
                    case (lane)
                      0: w16 = 16'h7e01;
                      1: w16 = (pmethod != 2'h0) ? 16'hfc00 : 16'hfe03;
                      2: w16 = (pmethod != 2'h0) ? 16'h7c00 : 16'h3c00;
                      default: w16 = 16'hfe55;
                    endcase
                  end else if ((nan_mode == 1) && (r[19:16] == 4'd0)) begin
                    // Quiet or signaling NaN (either sign)
                    w16 = {r[31], 5'h1f, (r[9:0] == 10'd0) ? 10'h201 : r[9:0]};
                  end else if ((nan_mode == 1) && (pmethod != 2'h0) && (r[19:16] == 4'd1)) begin
                    // +/- Inf in MIN/MAX
                    w16 = {r[31], 5'h1f, 10'd0};
                  end else if (r[19:16] == 4'd2) begin
                    // Subnormal or +/-0
                    w16 = {r[31], 5'h00, r[9:0]};
                  end else begin
                    // Normal exponent 1..22 so sums of 8 never overflow to Inf unless intended
                    reg [4:0] exp5 = 5'd1 + (r[14:10] % 5'd22);
                    w16 = {r[31], exp5, r[9:0]};
                  end
                end
                beat64[lane*16 +: 16] = w16;
              end
              cube_mem[surf][y][x][cpos] = beat64;
            end
          end
        end
      end

      // Compute Golden Expected Output Stream & NaN/Inf Counts
      // Order of output beats in cal1d:
      // For each split stripe s_idx = 0 .. split_num:
      //   For each surface surf = 0 .. num_surf-1:
      //     For each line y = 0 .. H-1:
      //       For each output pixel ox = 0 .. w_out_stripe-1:
      //         For each cpos = 0 .. 3: 112-bit pooling1d_pd
      exp_wr_ptr = 0;
      exp_rd_ptr = 0;
      exp_nan_cnt = 0;
      exp_inf_cnt = 0;

      for (s_idx = 0; s_idx <= split_num; s_idx++) begin
        if (split_num == 0) begin
          x_start = 0;
          x_len   = W;
          w_out_stripe = W_out_total;
        end else if (s_idx == 0) begin
          x_start = 0;
          x_len   = W_f;
          w_out_stripe = W_out_f;
        end else if (s_idx == split_num) begin
          x_start = (K >= S) ? (W - W_l - overlap_mag) : (W - W_l + overlap_mag);
          x_len   = (K >= S) ? (W_l + overlap_mag)     : (W_l - overlap_mag);
          w_out_stripe = W_out_l;
        end else begin
          x_start = (K >= S) ? (W_f + (s_idx - 1) * W_m - overlap_mag) : (W_f + (s_idx - 1) * W_m + overlap_mag);
          x_len   = (K >= S) ? (W_m + overlap_mag)                     : (W_m - overlap_mag);
          w_out_stripe = W_out_m;
        end

        // Count NaNs/Infs sent over RDMA in offline mode across all beats (including terminal cube_end beat)
        if (flying && (dtype == 2'h2)) begin
          for (surf = 0; surf < num_surf; surf++) begin
            for (y = 0; y < H; y++) begin
              for (int xi = 0; xi < x_len; xi++) begin
                for (cpos = 0; cpos < 4; cpos++) begin
                  beat64 = cube_mem[surf][y][x_start + xi][cpos];
                  for (lane = 0; lane < 4; lane++) begin
                    if (is_fp16_nan(beat64[lane*16 +: 16])) exp_nan_cnt++;
                    if (is_fp16_inf(beat64[lane*16 +: 16])) exp_inf_cnt++;
                  end
                end
              end
            end
          end
        end

        // Compute golden pooled outputs for this stripe
        for (surf = 0; surf < num_surf; surf++) begin
          for (y = 0; y < H; y++) begin
            for (ox = 0; ox < w_out_stripe; ox++) begin
              int global_ox;
              if (split_num == 0 || s_idx == 0)
                global_ox = ox;
              else if (s_idx < split_num)
                global_ox = W_out_f + (s_idx - 1) * W_out_m + ox;
              else
                global_ox = W_out_f + (split_num - 1) * W_out_m + ox;

              for (cpos = 0; cpos < 4; cpos++) begin
                active_cnt = 0;
                for (kx = 0; kx < K; kx++) begin
                  src_x = global_ox * S - PL + kx;
                  if (src_x >= 0 && src_x < W) begin
                    beat64 = cube_mem[surf][y][src_x][cpos];
                    // Apply NaN flush if offline & FP16 & nan_to_zero
                    clean64 = beat64;
                    if (flying && (dtype == 2'h2) && nan_to_zero) begin
                      for (lane = 0; lane < 4; lane++) begin
                        if (is_fp16_nan(clean64[lane*16 +: 16]))
                          clean64[lane*16 +: 16] = 16'd0;
                      end
                    end

                    if (dtype == 2'h0) begin
                      for (int b = 0; b < 8; b++) begin
                        reg signed [10:0] v8 = $signed(clean64[b*8 +: 8]);
                        if (active_cnt == 0) begin
                          acc8[b] = v8;
                        end else if (pmethod == 2'h0) begin
                          acc8[b] = acc8[b] + v8;
                        end else if (pmethod == 2'h1) begin
                          acc8[b] = (acc8[b] > v8) ? acc8[b] : v8;
                        end else begin
                          acc8[b] = (acc8[b] < v8) ? acc8[b] : v8;
                        end
                      end
                    end else if (dtype == 2'h1) begin
                      for (lane = 0; lane < 4; lane++) begin
                        reg signed [21:0] v16 = $signed(clean64[lane*16 +: 16]);
                        if (active_cnt == 0) begin
                          acc16s[lane] = v16;
                        end else if (pmethod == 2'h0) begin
                          acc16s[lane] = acc16s[lane] + v16;
                        end else if (pmethod == 2'h1) begin
                          acc16s[lane] = (acc16s[lane] > v16) ? acc16s[lane] : v16;
                        end else begin
                          acc16s[lane] = (acc16s[lane] < v16) ? acc16s[lane] : v16;
                        end
                      end
                    end else begin
                      // FP16
                      if (pmethod == 2'h0) begin
                        // Handled per-lane below via HLS_fp16_to_fp17 & HLS_fp17_add
                      end else begin
                        for (lane = 0; lane < 4; lane++) begin
                          cur16 = clean64[lane*16 +: 16];
                          if (active_cnt == 0) begin
                            acc16s[lane] = {{6{cur16[15]}}, cur16};
                          end else if (pmethod == 2'h1) begin
                            acc16 = fp16_max_comb(acc16s[lane][15:0], cur16);
                            acc16s[lane] = {acc16s[lane][21:16], acc16}; // wait: check upper bits in unit1d!
                          end else begin
                            acc16 = fp16_min_comb(acc16s[lane][15:0], cur16);
                            acc16s[lane] = {acc16s[lane][21:16], acc16};
                          end
                        end
                      end
                    end
                    active_cnt++;
                  end
                end

                // Check FP16 MAX/MIN upper sign-extension in unit1d:
                // In cal1d: datain_16bit_k = {{6{fp16[15]}}, fp16[15:0]} (22 bits).
                // In unit1d: pooling_MIN/MAX selects the entire 22-bit data0 or data1!
                // So bits [21:16] are ALWAYS {6{selected_fp16[15]}}!
                if (dtype == 2'h2 && pmethod != 2'h0) begin
                  active_cnt = 0;
                  for (kx = 0; kx < K; kx++) begin
                    src_x = global_ox * S - PL + kx;
                    if (src_x >= 0 && src_x < W) begin
                      clean64 = cube_mem[surf][y][src_x][cpos];
                      if (flying && nan_to_zero) begin
                        for (lane = 0; lane < 4; lane++)
                          if (is_fp16_nan(clean64[lane*16 +: 16])) clean64[lane*16 +: 16] = 16'd0;
                      end
                      for (lane = 0; lane < 4; lane++) begin
                        cur16 = clean64[lane*16 +: 16];
                        if (active_cnt == 0)
                          acc16s[lane] = {{6{cur16[15]}}, cur16};
                        else if (pmethod == 2'h1) begin
                          acc16 = fp16_max_comb(acc16s[lane][15:0], cur16);
                          acc16s[lane] = {{6{acc16[15]}}, acc16};
                        end else begin
                          acc16 = fp16_min_comb(acc16s[lane][15:0], cur16);
                          acc16s[lane] = {{6{acc16[15]}}, acc16};
                        end
                      end
                      active_cnt++;
                    end
                  end
                end

                pad_idx = K - active_cnt;
                exp_word = 112'd0;
                if (dtype == 2'h0) begin
                  for (int b = 0; b < 8; b++) begin
                    reg signed [10:0] v8_fin = acc8[b];
                    if (pmethod == 2'h0 && pad_idx > 0)
                      v8_fin = v8_fin + $signed(pad_cfg[pad_idx][10:0]);
                    exp_word[b*14 +: 14] = {{3{v8_fin[10]}}, v8_fin};
                  end
                end else if (dtype == 2'h1) begin
                  for (lane = 0; lane < 4; lane++) begin
                    reg signed [21:0] v16_fin = acc16s[lane];
                    if (pmethod == 2'h0 && pad_idx > 0)
                      v16_fin = v16_fin + $signed({pad_cfg[pad_idx][18], pad_cfg[pad_idx]});
                    exp_word[lane*28 +: 28] = {{6{v16_fin[21]}}, v16_fin};
                  end
                end else if (pmethod != 2'h0) begin
                  // FP16 MAX/MIN
                  for (lane = 0; lane < 4; lane++) begin
                    exp_word[lane*28 +: 28] = {{6{acc16s[lane][21]}}, acc16s[lane]};
                  end
                end else begin
                  // FP16 AVE -> exact sequential HLS_fp16_to_fp17 + HLS_fp17_add
                  for (lane = 0; lane < 4; lane++) begin
                    int a_cnt = 0;
                    for (kx = 0; kx < K; kx++) begin
                      src_x = global_ox * S - PL + kx;
                      if (src_x >= 0 && src_x < W) begin
                        cur16 = cube_mem[surf][y][src_x][cpos][lane*16 +: 16];
                        if (flying && nan_to_zero && is_fp16_nan(cur16))
                          cur16 = 16'd0;
                        eval_fp16_to_fp17(cur16, f17_elem);
                        if (a_cnt == 0)
                          f17_acc = f17_elem;
                        else
                          eval_fp17_add(f17_acc, f17_elem, f17_acc);
                        a_cnt++;
                      end
                    end
                    // Final pad addition in cal1d u_HLS_fp17_add_0..3 (always adds pad_f17[pad_idx], where pad_f17[0]=0)
                    eval_fp17_add(f17_acc, pad_f17[pad_idx], f17_acc);
                    exp_word[lane*28 +: 28] = {11'd0, f17_acc};
                  end
                end
                exp_fifo[exp_wr_ptr] = exp_word;
                exp_wr_ptr++;
              end
            end
          end
        end
      end

      // Configure registers while op_en == 0
      @(negedge nvdla_core_clk);
      reg2dp_flying_mode         = flying;
      reg2dp_input_data          = dtype;
      reg2dp_nan_to_zero         = nan_to_zero;
      pooling_type_cfg           = pmethod;
      reg2dp_pad_left            = PL[2:0];
      reg2dp_pad_right           = PR[2:0];
      pooling_channel_cfg        = (dtype == 2'h0) ? (num_surf * 32 - 1) : (num_surf * 16 - 1);
      pooling_fwidth_cfg         = (split_num > 0) ? (W_f - 1) : 10'd0;
      pooling_mwidth_cfg         = (split_num > 1) ? (W_m - 1) : 10'd0;
      pooling_lwidth_cfg         = (split_num > 0) ? (W_l - 1) : 10'd0;
      pooling_out_fwidth_cfg     = (split_num > 0) ? (W_out_f - 1) : 10'd0;
      pooling_out_mwidth_cfg     = (split_num > 1) ? (W_out_m - 1) : 10'd0;
      pooling_out_lwidth_cfg     = (split_num > 0) ? (W_out_l - 1) : 10'd0;
      reg2dp_kernel_width        = (K - 1);
      reg2dp_kernel_stride_width = (S - 1);
      pooling_splitw_num_cfg     = split_num[7:0];
      reg2dp_cube_in_height      = (H - 1);
      reg2dp_cube_in_width       = (W - 1);
      reg2dp_cube_out_width      = (W_out_total - 1);
      reg2dp_pad_value_1x_cfg    = pad_cfg[1];
      reg2dp_pad_value_2x_cfg    = pad_cfg[2];
      reg2dp_pad_value_3x_cfg    = pad_cfg[3];
      reg2dp_pad_value_4x_cfg    = pad_cfg[4];
      reg2dp_pad_value_5x_cfg    = pad_cfg[5];
      reg2dp_pad_value_6x_cfg    = pad_cfg[6];
      reg2dp_pad_value_7x_cfg    = pad_cfg[7];

      @(negedge nvdla_core_clk);
      // Verify waiting_for_op_en blocks RDMA before op_en rises!
      if (flying) begin
        rdma_vld = 1'b1;
        rdma_pd  = 76'hdead_beef_cafe_1234;
        @(negedge nvdla_core_clk);
        #1;
        if (rdma_rdy !== 1'b0) begin
          $display("FAIL [%s]: rdma_rdy high before reg2dp_op_en asserted!", name);
          $fatal(1, "op_en gating failed");
        end
        rdma_vld = 1'b0;
      end else begin
        // In flying SDP mode (flying_mode==0), u_nan must keep rdma_rdy==0 even after op_en!
        rdma_vld = 1'b1;
        rdma_pd  = 76'h0;
      end

      @(negedge nvdla_core_clk);
      reg2dp_op_en = 1'b1;
      @(negedge nvdla_core_clk);
      if (!flying) begin
        #1;
        if (rdma_rdy !== 1'b0) begin
          $display("FAIL [%s]: rdma_rdy high during flying SDP mode!", name);
          $fatal(1, "flying mode rdma block failed");
        end
      end

      // Stream all beats across splits, surfaces, lines, pixels, cpos
      for (s_idx = 0; s_idx <= split_num; s_idx++) begin
        if (split_num == 0) begin
          x_start = 0; x_len = W;
        end else if (s_idx == 0) begin
          x_start = 0; x_len = W_f;
        end else if (s_idx == split_num) begin
          x_start = (K >= S) ? (W - W_l - overlap_mag) : (W - W_l + overlap_mag);
          x_len   = (K >= S) ? (W_l + overlap_mag)     : (W_l - overlap_mag);
        end else begin
          x_start = (K >= S) ? (W_f + (s_idx - 1) * W_m - overlap_mag) : (W_f + (s_idx - 1) * W_m + overlap_mag);
          x_len   = (K >= S) ? (W_m + overlap_mag)                     : (W_m - overlap_mag);
        end

        for (surf = 0; surf < num_surf; surf++) begin
          for (y = 0; y < H; y++) begin
            for (int xi = 0; xi < x_len; xi++) begin
              for (cpos = 0; cpos < 4; cpos++) begin
                bit f_line_end  = (xi == x_len - 1) && (cpos == 3);
                bit f_bsync     = f_line_end;
                bit f_surf_end  = f_line_end && (y == H - 1);
                bit f_split_end = f_surf_end && (surf == num_surf - 1);
                bit f_cube_end  = f_split_end && (s_idx == split_num);
                reg [75:0] pkt;
                pkt = {f_cube_end, f_split_end, f_surf_end, f_line_end, f_bsync, cpos[2:0], 4'd0, cube_mem[surf][y][x_start + xi][cpos]};

                // Optional random upstream bubble
                while (stall_enable && ((next_rand() % 100) < 25)) begin
                  if (flying) rdma_vld = 1'b0; else sdp_vld = 1'b0;
                  @(negedge nvdla_core_clk);
                end

                if (flying) begin
                  rdma_vld = 1'b1;
                  rdma_pd  = pkt;
                  #1;
                  guard = 0;
                  while (!rdma_rdy) begin
                    @(negedge nvdla_core_clk);
                    #1;
                    guard++;
                    if (guard > 2000) $fatal(1, "Timeout waiting rdma_rdy in %s", name);
                  end
                  @(negedge nvdla_core_clk);
                  rdma_vld = 1'b0;
                end else begin
                  sdp_vld = 1'b1;
                  sdp_pd  = pkt;
                  #1;
                  guard = 0;
                  while (!sdp_rdy) begin
                    @(negedge nvdla_core_clk);
                    #1;
                    guard++;
                    if (guard > 2000) $fatal(1, "Timeout waiting sdp_rdy in %s", name);
                  end
                  @(negedge nvdla_core_clk);
                  sdp_vld = 1'b0;
                end
              end
            end
          end
        end
      end

      // If offline mode, verify waiting_for_op_en re-engaged after layer_end!
      if (flying) begin
        rdma_vld = 1'b1;
        rdma_pd  = 76'hfeed_face_1234_5678;
        @(negedge nvdla_core_clk);
        #1;
        if (rdma_rdy !== 1'b0) begin
          $display("FAIL [%s]: rdma_rdy stayed high after cube_end before next op_en!", name);
          $fatal(1, "post-cube_end gating failed");
        end
        rdma_vld = 1'b0;
      end else begin
        rdma_vld = 1'b0;
      end

      // Wait for all expected output beats to drain
      guard = 0;
      while (exp_rd_ptr < exp_wr_ptr) begin
        @(negedge nvdla_core_clk);
        guard++;
        if (guard > 5000) begin
          $display("FAIL [%s]: Timeout draining outputs (%0d / %0d received)", name, exp_rd_ptr, exp_wr_ptr);
          $fatal(1, "Drain timeout");
        end
      end
      // Extra settle cycles to ensure no spurious trailing beats
      repeat (10) @(negedge nvdla_core_clk);

      // Pulse dp2reg_done for 1 cycle and deassert reg2dp_op_en
      dp2reg_done  = 1'b1;
      reg2dp_op_en = 1'b0;
      @(negedge nvdla_core_clk);
      dp2reg_done  = 1'b0;
      @(negedge nvdla_core_clk);
      #1;

      if (flying) begin
        if (dp2reg_nan_input_num !== exp_nan_cnt[31:0]) begin
          $display("FAIL [%s]: dp2reg_nan_input_num=%0d expected=%0d", name, dp2reg_nan_input_num, exp_nan_cnt);
          $fatal(1, "NaN count mismatch");
        end
        if (dp2reg_inf_input_num !== exp_inf_cnt[31:0]) begin
          $display("FAIL [%s]: dp2reg_inf_input_num=%0d expected=%0d", name, dp2reg_inf_input_num, exp_inf_cnt);
          $fatal(1, "Inf count mismatch");
        end
      end

      $display("[OK] %s (beats=%0d, nan=%0d, inf=%0d)", name, exp_wr_ptr, exp_nan_cnt, exp_inf_cnt);
    end
  endtask

  initial begin
    if (!$value$plusargs("seed=%d", seed_val))
      seed_val = 101;
    init_seed = seed_val;

    nvdla_core_rstn = 1'b0;
    dp2reg_done     = 1'b0;
    rdma_pd         = 76'd0;
    rdma_vld        = 1'b0;
    sdp_pd          = 76'd0;
    sdp_vld         = 1'b0;
    reg2dp_flying_mode = 1'b1;
    reg2dp_input_data  = 2'h0;
    reg2dp_nan_to_zero = 1'b0;
    reg2dp_op_en       = 1'b0;
    pooling_type_cfg   = 2'h0;
    reg2dp_pad_left    = 3'd0;
    reg2dp_pad_right   = 3'd0;
    pooling_channel_cfg = 13'd0;
    pooling_fwidth_cfg  = 10'd0;
    pooling_mwidth_cfg  = 10'd0;
    pooling_lwidth_cfg  = 10'd0;
    pooling_out_fwidth_cfg = 10'd0;
    pooling_out_mwidth_cfg = 10'd0;
    pooling_out_lwidth_cfg = 10'd0;
    reg2dp_kernel_width = 3'd0;
    reg2dp_kernel_stride_width = 4'd0;
    pooling_splitw_num_cfg = 8'd0;
    reg2dp_cube_in_height = 13'd0;
    reg2dp_cube_in_width  = 13'd0;
    reg2dp_cube_out_width = 13'd0;
    reg2dp_pad_value_1x_cfg = 19'd0;
    reg2dp_pad_value_2x_cfg = 19'd0;
    reg2dp_pad_value_3x_cfg = 19'd0;
    reg2dp_pad_value_4x_cfg = 19'd0;
    reg2dp_pad_value_5x_cfg = 19'd0;
    reg2dp_pad_value_6x_cfg = 19'd0;
    reg2dp_pad_value_7x_cfg = 19'd0;
    pooling1d_prdy = 1'b1;
    stall_enable   = 1'b0;
    orc_f16_in     = 16'd0;
    orc_f16_vld    = 1'b0;
    orc_f17_rdy    = 1'b0;
    orc_add_a      = 17'd0;
    orc_add_b      = 17'd0;
    orc_add_a_vld  = 1'b0;
    orc_add_b_vld  = 1'b0;
    orc_add_z_rdy  = 1'b0;

    repeat (8) @(posedge nvdla_core_clk);
    nvdla_core_rstn = 1'b1;
    repeat (4) @(posedge nvdla_core_clk);

    // Phase 1: Unstalled multi-precision & multi-mode tests (including ping-pong layer counters)
    stall_enable = 1'b0;
    // Layer 0 (ping-pong bank 0): FP16 MAX with NaN propagation (nan_to_zero=0), K=3, S=1, PL=1, PR=1
    run_layer_test("L0_fp16_max_nan_prop", 1'b1, 2'h2, 2'h1, 1'b0, 8, 2, 2, 3, 1, 1, 1, 0, 0, 0, 0, 16'h0000, 1'b1);
    // Layer 1 (ping-pong bank 1): FP16 MIN with NaN flush-to-zero (nan_to_zero=1), K=5, S=2, PL=2, PR=2
    run_layer_test("L1_fp16_min_nan_zero", 1'b1, 2'h2, 2'h2, 1'b1, 9, 2, 1, 5, 2, 2, 2, 0, 0, 0, 0, 16'h0000, 1'b1);
    // Layer 2 (ping-pong bank 0 wrap): FP16 AVE with negative pad value (-1.5 = 16'hbe00) & NaN flush-to-zero, K=4, S=2, PL=1, PR=3 (flush_num=1)
    run_layer_test("L2_fp16_ave_pad_neg",  1'b1, 2'h2, 2'h0, 1'b1, 8, 2, 1, 4, 2, 1, 3, 0, 0, 0, 0, 16'hbe00, 1'b1);
    // Layer 3 (ping-pong bank 1 wrap): INT8 AVE asymmetric pad & negative pad_val=-7, K=7, S=2, PL=3, PR=5 (flush_num=2)
    run_layer_test("L3_int8_ave_asym_pad", 1'b1, 2'h0, 2'h0, 1'b0, 11, 2, 2, 7, 2, 3, 5, 0, 0, 0, 0, -7, 1'b1);

    // Phase 2: Randomized backpressure + upstream stalls across all corner cases!
    stall_enable = 1'b1;
    // INT8 MAX & MIN with flying SDP mode (flying_mode=0) and non-zero stale pad_value CSRs
    run_layer_test("S1_int8_max_flying",   1'b0, 2'h0, 2'h1, 1'b0, 10, 2, 2, 3, 1, 1, 2, 0, 0, 0, 0, 11, 1'b1);
    run_layer_test("S2_int8_min_bigstride",1'b1, 2'h0, 2'h2, 1'b0, 13, 2, 1, 2, 4, 1, 0, 0, 0, 0, 0, -9, 1'b1);
    // INT16 AVE, MAX, MIN with need_bubble (flush_num >= first_out_num: e.g., K=5, S=1, PL=3 => first_out_num=2, PR=4 => flush_num=4 >= 2 -> need_bubble=1!)
    run_layer_test("S3_int16_ave_bubble",  1'b1, 2'h1, 2'h0, 1'b0, 9,  2, 2, 5, 1, 3, 4, 0, 0, 0, 0, 19, 1'b1);
    run_layer_test("S4_int16_max_k8",      1'b1, 2'h1, 2'h1, 1'b0, 13, 2, 1, 8, 3, 2, 5, 0, 0, 0, 0, -23, 1'b0);
    run_layer_test("S5_int16_min_flying",  1'b0, 2'h1, 2'h2, 1'b0, 10, 2, 1, 4, 2, 2, 2, 0, 0, 0, 0, 0,  1'b0);
    // Small-width non-split cube (W + PL < K: W=2, PL=1, K=5, S=1, PR=3 -> W+PL=3 < 5, total=6 -> W_out=2, pad_r_remain=1)
    run_layer_test("S6_int8_small_width",  1'b1, 2'h0, 2'h0, 1'b0, 2,  2, 1, 5, 1, 1, 3, 0, 0, 0, 0, -5, 1'b0);

    // Phase 3: Split-width multi-stripe tests (split_num = 1 and split_num = 2) across K>=S, K<S, INT8/INT16/FP16!
    // 1) split_num=1 (2 stripes), K=3, S=1, PL=1, PR=1, W=10: W_f=5, W_l=5
    run_layer_test("SP1_int16_ave_2split", 1'b1, 2'h1, 2'h0, 1'b0, 10, 2, 2, 3, 1, 1, 1, 1, 5, 0, 5, -13, 1'b0);
    // 2) split_num=2 (3 stripes: first, mid, last), K=5, S=2, PL=2, PR=3, W=20: W_f=7, W_m=6, W_l=7 -> (2+20+3-5)=20 % 2 == 0!
    run_layer_test("SP2_fp16_ave_3split",  1'b1, 2'h2, 2'h0, 1'b1, 20, 2, 1, 5, 2, 2, 3, 2, 7, 6, 7, 16'h3c00, 1'b1);
    run_layer_test("SP3_int8_max_3split",  1'b1, 2'h0, 2'h1, 1'b0, 20, 2, 2, 5, 2, 2, 3, 2, 7, 6, 7, 0, 1'b0);
    // 3) split_num=1 with big_stride (S > K): K=2, S=4, PL=1, PR=1, W=12: W_f=5, W_l=7 -> (1+12+1-2)=12 % 4 == 0!
    run_layer_test("SP4_fp16_max_bigstr",  1'b1, 2'h2, 2'h1, 1'b0, 12, 2, 1, 2, 4, 1, 1, 1, 5, 0, 7, 16'h0000, 1'b1);

        // 4) split_num=1 with small final stripe (split_small_active): K=6, S=2, PL=4, PR=5, W=7: W_f=6, W_l=1
    run_layer_test("SP5_fp16_min_small_last", 1'b1, 2'h2, 2'h2, 1'b1, 7, 2, 1, 6, 2, 4, 5, 1, 6, 0, 1, 16'h0000, 1);

    // Phase 4: Directed terminal cube_end beat NaN/Inf telemetry across ping-pong groups (d0 -> d1 -> d0)
    run_layer_test("T0_fp16_term_only_d0",  1'b1, 2'h2, 2'h1, 1'b0, 4, 1, 1, 2, 1, 0, 0, 0, 0, 0, 0, 16'h0000, 2);
    run_layer_test("T1_fp16_term_only_d1",  1'b1, 2'h2, 2'h2, 1'b1, 4, 1, 1, 2, 1, 0, 0, 0, 0, 0, 0, 16'h0000, 2);
    run_layer_test("T2_fp16_ave_term_only", 1'b1, 2'h2, 2'h0, 1'b1, 4, 1, 1, 2, 1, 1, 1, 0, 0, 0, 0, 16'h3c00, 2);

    $display("PASS seed=%0d", init_seed);
    $finish;
  end
endmodule
