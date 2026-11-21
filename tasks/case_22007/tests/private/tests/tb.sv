
module xbuf_harness #(
  parameter int unsigned H = 4,
  parameter int unsigned W = 4,
  parameter int unsigned D = 2,
  parameter bit          USE_LATCHES = 1'b0
) (
  input  logic        clk_i,
  input  logic [31:0] seed_i,
  output logic        done_o,
  output logic        err_o
);
  import fpnew_pkg::*;
  import redmule_pkg::*;

  localparam int unsigned TOT_DEPTH = H * D;
  localparam int unsigned DATA_W    = TOT_DEPTH * 16;

  logic rst_ni;
  logic clear_i;
  x_buffer_ctrl_t ctrl_i;
  x_buffer_flgs_t flags_o;
  logic [W-1:0][H-1:0][15:0] x_buffer_o;
  logic [DATA_W-1:0] x_buffer_i;

  redmule_x_buffer #(
    .DataW      ( DATA_W      ),
    .FpFormat   ( FP16        ),
    .Height     ( H           ),
    .Width      ( W           ),
    .UseLatches ( USE_LATCHES )
  ) dut (
    .clk_i      ( clk_i      ),
    .rst_ni     ( rst_ni     ),
    .clear_i    ( clear_i    ),
    .ctrl_i     ( ctrl_i     ),
    .flags_o    ( flags_o    ),
    .x_buffer_o ( x_buffer_o ),
    .x_buffer_i ( x_buffer_i )
  );

  always @(negedge clk_i) begin
    if (rst_ni) begin
      if ((^flags_o === 1'bx) || (^x_buffer_o === 1'bx)) begin
        $display("[FAIL] H=%0d W=%0d D=%0d L=%0d: 4-state X/Z on outputs!", H, W, D, USE_LATCHES);
        err_o = 1'b1;
        $fatal(1, "X/Z detected");
      end
    end
  end

  function automatic int get_prefix_cols(input int slots_arr[0:7], input int n);
    int s = 0;
    for (int i = 0; i < n; i++) s += slots_arr[i];
    return s;
  endfunction

  task automatic run_job(
    input int num_tiles,
    input int widths   [0:7],
    input int heights  [0:7],
    input int slots_arr[0:7],
    input int pipe_wait,
    input bit abort_mid_job,
    inout logic [31:0] rng
  );
    logic [15:0] tile_mat   [0:7][0:W-1][0:TOT_DEPTH-1];
    logic [15:0] exp_stream [0:255][0:W-1];
    logic [15:0] exp_out    [0:W-1][0:H-1];
    int total_cols;
    int cur_cfg_tile;
    int loaded_tiles;
    int staged_tiles;
    bit stage_pipe_pending;
    int load_row;
    bit reloading;
    bit empty_seen_wait_rst;
    int shift_mod_h;
    int global_shift_idx;
    int wait_cnt;
    int empty_pulses;
    int cyc_guard;

    total_cols = 0;
    for (int t = 0; t < num_tiles; t++) begin
      for (int r = 0; r < W; r++) begin
        for (int c = 0; c < TOT_DEPTH; c++) begin
          rng = rng * 32'd1664525 + 32'd1013904223;
          tile_mat[t][r][c] = 16'h1000 ^ rng[15:0] ^ ((t[3:0] + 4'd1) << 12) ^ (r[3:0] << 6) ^ c[5:0];
          if (tile_mat[t][r][c] == 16'h0000) tile_mat[t][r][c] = 16'h3c00;
        end
      end
      for (int c = 0; c < slots_arr[t]; c++) begin
        for (int r = 0; r < W; r++) begin
          if ((r < widths[t]) && (c < heights[t]))
            exp_stream[total_cols + c][r] = tile_mat[t][r][c];
          else
            exp_stream[total_cols + c][r] = 16'h0000;
        end
      end
      total_cols += slots_arr[t];
    end

    for (int r = 0; r < W; r++)
      for (int h = 0; h < H; h++)
        exp_out[r][h] = 16'h0000;

    // Preload Tile 0 (drive changes right after posedge so ICG latches see clean setup before negedge)
    cur_cfg_tile = 0;
    ctrl_i = '0;
    ctrl_i.width  = widths[0];
    ctrl_i.height = heights[0];
    ctrl_i.slots  = slots_arr[0];
    x_buffer_i    = '0;
    @(posedge clk_i); #1;

    load_row = 0;
    while (load_row < widths[0]) begin
      rng = rng * 32'd1664525 + 32'd1013904223;
      if (rng[1:0] != 2'b00) begin
        ctrl_i.load = 1'b1;
        for (int c = 0; c < TOT_DEPTH; c++)
          x_buffer_i[c*16 +: 16] = tile_mat[0][load_row][c];
        load_row++;
      end else begin
        ctrl_i.load = 1'b0;
        x_buffer_i  = {DATA_W{1'b1}};
      end
      @(posedge clk_i); #1;
    end
    ctrl_i.load = 1'b0;
    if (flags_o.full !== 1'b1) begin
      $display("[FAIL] H=%0d W=%0d D=%0d L=%0d: flags_o.full!=1 after preload", H, W, D, USE_LATCHES);
      err_o = 1'b1;
      $fatal(1, "preload full");
    end

    // Pulse pad_setup for 1 cycle
    ctrl_i.pad_setup = 1'b1;
    @(posedge clk_i); #1;
    ctrl_i.pad_setup = 1'b0;

    loaded_tiles        = 1;
    staged_tiles        = 1;
    stage_pipe_pending  = 1'b0;
    load_row            = 0;
    reloading           = 1'b0;
    empty_seen_wait_rst = 1'b0;
    shift_mod_h         = 0;
    global_shift_idx    = 0;
    wait_cnt            = pipe_wait;
    empty_pulses        = 0;
    cyc_guard           = 0;

    while (global_shift_idx < total_cols) begin
      automatic bit want_shift;
      automatic bit can_shift;
      automatic bit do_load;
      automatic bit pre_empty;
      automatic bit pre_full;
      automatic bit do_rst_w;

      cyc_guard++;
      if (cyc_guard > 3000) begin
        $display("[FAIL] H=%0d W=%0d D=%0d L=%0d: timeout at shift %0d/%0d (staged=%0d loaded=%0d)",
                 H, W, D, USE_LATCHES, global_shift_idx, total_cols, staged_tiles, loaded_tiles);
        err_o = 1'b1;
        $fatal(1, "timeout");
      end

      if (abort_mid_job && (global_shift_idx == total_cols / 2)) begin
        clear_i        = 1'b1;
        ctrl_i.load    = 1'b1;
        ctrl_i.h_shift = 1'b1;
        x_buffer_i     = {DATA_W{1'b1}};
        @(posedge clk_i); #1;
        clear_i        = 1'b0;
        ctrl_i         = '0;
        x_buffer_i     = '0;
        if (flags_o.empty !== 1'b0 || x_buffer_o !== '0) begin
          $display("[FAIL] H=%0d W=%0d D=%0d L=%0d: clear_i simultaneous with load/shift left non-zero state: %h",
                   H, W, D, USE_LATCHES, x_buffer_o);
          err_o = 1'b1;
          $fatal(1, "clear failed");
        end
        return;
      end

      rng = rng * 32'd1664525 + 32'd1013904223;
      want_shift = (wait_cnt >= pipe_wait) && (rng[2:0] != 3'b000);
      can_shift  = want_shift && (global_shift_idx < get_prefix_cols(slots_arr, staged_tiles));

      ctrl_i.h_shift = can_shift;
      #1; // evaluate combinational flags_o.empty from ctrl_i.h_shift
      pre_empty = flags_o.empty;
      pre_full  = flags_o.full;

      do_rst_w = can_shift && (((H == 1) || (shift_mod_h == H - 1)) || pre_empty) && pre_full;
      ctrl_i.rst_w_index = do_rst_w;

      do_load = reloading && !pre_full && (loaded_tiles < num_tiles) && (rng[1:0] != 2'b00);
      ctrl_i.load = do_load;
      if (do_load) begin
        for (int c = 0; c < TOT_DEPTH; c++)
          x_buffer_i[c*16 +: 16] = tile_mat[loaded_tiles][load_row][c];
      end else begin
        x_buffer_i = {DATA_W{1'b1}};
      end

      @(posedge clk_i); #1;

      if (stage_pipe_pending) begin
        staged_tiles++;
        stage_pipe_pending = 1'b0;
      end

      if (do_load) begin
        load_row++;
        if (load_row == widths[loaded_tiles]) begin
          reloading          = 1'b0;
          load_row           = 0;
          loaded_tiles++;
          stage_pipe_pending = 1'b1; // 1 cycle after flags_o.full asserts, tile enters i_x_buf
        end
      end

      if (pre_empty) begin
        empty_pulses++;
        if (cur_cfg_tile + 1 < num_tiles) begin
          cur_cfg_tile++;
          ctrl_i.width  = widths[cur_cfg_tile];
          ctrl_i.height = heights[cur_cfg_tile];
          ctrl_i.slots  = slots_arr[cur_cfg_tile];
          if (!pre_full || do_rst_w)
            reloading = 1'b1;
          else
            empty_seen_wait_rst = 1'b1;
        end
      end else if (empty_seen_wait_rst && !flags_o.full) begin
        reloading           = 1'b1;
        empty_seen_wait_rst = 1'b0;
      end

      if (can_shift) begin
        automatic int h_lane = global_shift_idx % H;
        for (int r = 0; r < W; r++) begin
          exp_out[r][h_lane] = exp_stream[global_shift_idx][r];
        end
        for (int r = 0; r < W; r++) begin
          for (int h = 0; h < H; h++) begin
            if (h <= global_shift_idx) begin
              if (x_buffer_o[r][h] !== exp_out[r][h]) begin
                $display("[FAIL] H=%0d W=%0d D=%0d L=%0d shift=%0d r=%0d h=%0d: got %h expected %h",
                         H, W, D, USE_LATCHES, global_shift_idx, r, h, x_buffer_o[r][h], exp_out[r][h]);
                err_o = 1'b1;
                $fatal(1, "output mismatch");
              end
            end else begin
              if ((x_buffer_o[r][h] !== 16'h0000) && (x_buffer_o[r][h] !== exp_stream[h][r])) begin
                $display("[FAIL] H=%0d W=%0d D=%0d L=%0d pre-wavefront shift=%0d r=%0d h=%0d: got %h",
                         H, W, D, USE_LATCHES, global_shift_idx, r, h, x_buffer_o[r][h]);
                err_o = 1'b1;
                $fatal(1, "pre-wavefront mismatch");
              end
            end
          end
        end
        global_shift_idx++;
        wait_cnt = 0;
        if (pre_full && pre_empty)
          shift_mod_h = 0;
        else
          shift_mod_h = (H == 1) ? 0 : ((shift_mod_h == H - 1) ? 0 : (shift_mod_h + 1));
      end else begin
        wait_cnt++;
      end
    end

    if (empty_pulses != num_tiles) begin
      $display("[FAIL] H=%0d W=%0d D=%0d L=%0d: expected %0d empty pulses, got %0d",
               H, W, D, USE_LATCHES, num_tiles, empty_pulses);
      err_o = 1'b1;
      $fatal(1, "empty pulse count mismatch");
    end

    // Clear after job
    clear_i = 1'b1;
    ctrl_i  = '0;
    @(posedge clk_i); #1;
    clear_i = 1'b0;
  endtask

  initial begin
    logic [31:0] rng;
    int w_arr [0:7];
    int h_arr [0:7];
    int s_arr [0:7];

    done_o     = 1'b0;
    err_o      = 1'b0;
    rst_ni     = 1'b0;
    clear_i    = 1'b0;
    ctrl_i     = '0;
    ctrl_i.width = W;
    ctrl_i.height = TOT_DEPTH;
    ctrl_i.slots = TOT_DEPTH;
    x_buffer_i = '0;
    rng        = seed_i ^ (H * 32'h111) ^ (W * 32'h222) ^ (D * 32'h333) ^ {31'd0, USE_LATCHES};

    repeat (2) @(posedge clk_i); #1;
    rst_ni = 1'b1;
    @(posedge clk_i); #1;

    // Check post-reset clean zero outputs (especially UseLatches=1!)
    if (x_buffer_o !== '0 || flags_o.empty !== 1'b0) begin
      $display("[FAIL] H=%0d W=%0d D=%0d L=%0d: non-zero post-reset outputs!", H, W, D, USE_LATCHES);
      err_o = 1'b1;
      $fatal(1, "post-reset non-zero");
    end

    // Job 1: Full-width + partial-width + partial-height + partial-slots multi-tile job (pipe_wait = 3)
    for (int t = 0; t < 4; t++) begin
      w_arr[t] = (t % 2 == 0) ? W : ((W > 1) ? (W - 1) : 1);
      s_arr[t] = ((t == 2) && (D > 1)) ? ((D - 1) * H) : (D * H);
      h_arr[t] = (t == 1) ? ((s_arr[t] > 1) ? (s_arr[t] - 1) : 1)
               : ((t == 3) ? 1 : s_arr[t]);
    end
    run_job(4, w_arr, h_arr, s_arr, 3, 1'b0, rng);

    // Job 2: Mid-job simultaneous clear_i + load + h_shift hazard test, followed immediately by Job 3!
    for (int t = 0; t < 3; t++) begin
      w_arr[t] = W;
      s_arr[t] = D * H;
      h_arr[t] = D * H;
    end
    run_job(3, w_arr, h_arr, s_arr, 0, 1'b1, rng);

    // Job 3: Back-to-back zero-wait shifts (pipe_wait = 0) with extreme partial dimensions (width=1, height=0..slots)
    for (int t = 0; t < 4; t++) begin
      w_arr[t] = (t == 0) ? 1 : ((W > 2 && t == 2) ? 2 : W);
      s_arr[t] = (D > 2 && t == 1) ? (2 * H) : ((D > 1 && t == 3) ? H : (D * H));
      h_arr[t] = (t == 2) ? 0 : ((s_arr[t] > 1 && t == 1) ? (s_arr[t] - 1) : s_arr[t]);
    end
    run_job(4, w_arr, h_arr, s_arr, 0, 1'b0, rng);

    done_o = 1'b1;
  end
endmodule

module tb;
  logic clk = 1'b0;
  always #5 clk = ~clk;

  logic [31:0] seed = 32'd101;
  initial ignore_plusargs: begin
    void'($value$plusargs("SEED=%d", seed));
  end

  logic [9:0] done_v, err_v;

  // 10 multi-parameter instances covering D=4, D=2, D=1, H=1, W=1, UseLatches=0 & 1!
  xbuf_harness #(.H(4), .W(4), .D(4), .USE_LATCHES(1'b0)) u0 (.clk_i(clk), .seed_i(seed), .done_o(done_v[0]), .err_o(err_v[0]));
  xbuf_harness #(.H(4), .W(4), .D(4), .USE_LATCHES(1'b1)) u1 (.clk_i(clk), .seed_i(seed), .done_o(done_v[1]), .err_o(err_v[1]));
  xbuf_harness #(.H(4), .W(4), .D(2), .USE_LATCHES(1'b0)) u2 (.clk_i(clk), .seed_i(seed), .done_o(done_v[2]), .err_o(err_v[2]));
  xbuf_harness #(.H(4), .W(4), .D(2), .USE_LATCHES(1'b1)) u3 (.clk_i(clk), .seed_i(seed), .done_o(done_v[3]), .err_o(err_v[3]));
  xbuf_harness #(.H(4), .W(4), .D(1), .USE_LATCHES(1'b0)) u4 (.clk_i(clk), .seed_i(seed), .done_o(done_v[4]), .err_o(err_v[4]));
  xbuf_harness #(.H(4), .W(4), .D(1), .USE_LATCHES(1'b1)) u5 (.clk_i(clk), .seed_i(seed), .done_o(done_v[5]), .err_o(err_v[5]));
  xbuf_harness #(.H(1), .W(1), .D(1), .USE_LATCHES(1'b0)) u6 (.clk_i(clk), .seed_i(seed), .done_o(done_v[6]), .err_o(err_v[6]));
  xbuf_harness #(.H(1), .W(1), .D(1), .USE_LATCHES(1'b1)) u7 (.clk_i(clk), .seed_i(seed), .done_o(done_v[7]), .err_o(err_v[7]));
  xbuf_harness #(.H(1), .W(3), .D(3), .USE_LATCHES(1'b1)) u8 (.clk_i(clk), .seed_i(seed), .done_o(done_v[8]), .err_o(err_v[8]));
  xbuf_harness #(.H(3), .W(1), .D(3), .USE_LATCHES(1'b0)) u9 (.clk_i(clk), .seed_i(seed), .done_o(done_v[9]), .err_o(err_v[9]));

  initial begin
    wait (&done_v);
    if (|err_v) $fatal(1, "Errors observed");
    $display("ALL 10 PARAMETERIZED X_BUFFER CONFIGURATIONS PASSED (seed=%0d)!", seed);
    $finish;
  end
endmodule
