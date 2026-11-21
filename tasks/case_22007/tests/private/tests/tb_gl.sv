
`timescale 1ns/1ps
module tb_gl;
  localparam int H = 4;
  localparam int W = 4;
  localparam int D = 4;
  localparam int TOT_DEPTH = H * D;
  localparam int DATA_W = TOT_DEPTH * 16;

  reg clk_i = 1'b0;
  always #5 clk_i = ~clk_i;

  reg rst_ni = 1'b0;
  reg clear_i = 1'b0;
  reg        c_h_shift, c_load, c_pad_setup, c_rst_w_index, c_last_x;
  reg  [4:0] c_width;
  reg  [6:0] c_height, c_slots;
  wire [23:0] ctrl_i = {c_h_shift, c_load, c_pad_setup, c_width, c_height, c_slots, c_rst_w_index, c_last_x};
  wire [1:0]  flags_o;
  wire        f_empty = flags_o[1];
  wire        f_full  = flags_o[0];
  wire [W*H*16-1:0] x_buffer_o;
  reg  [DATA_W-1:0] x_buffer_i;

  redmule_x_buffer dut (
    .clk_i      ( clk_i      ),
    .rst_ni     ( rst_ni     ),
    .clear_i    ( clear_i    ),
    .ctrl_i     ( ctrl_i     ),
    .flags_o    ( flags_o    ),
    .x_buffer_o ( x_buffer_o ),
    .x_buffer_i ( x_buffer_i )
  );

  // Strict 4-state X/Z monitor on every falling edge once out of reset
  always @(negedge clk_i) begin
    if (rst_ni) begin
      if ((^flags_o === 1'bx) || (^x_buffer_o === 1'bx)) begin
        $display("[GL-FAIL] 4-state X/Z propagated to outputs! flags=%b x_buffer_o=%h", flags_o, x_buffer_o);
        $fatal(1, "GL X/Z detected");
      end
    end
  end

  reg [15:0] tile_mat   [0:2][0:W-1][0:TOT_DEPTH-1];
  reg [15:0] exp_stream [0:63][0:W-1];
  reg [15:0] exp_out    [0:W-1][0:H-1];
  integer widths [0:2];
  integer heights[0:2];
  integer slots_a[0:2];

  integer t, r, c, h;
  integer total_cols, cur_cfg_tile, loaded_tiles, staged_tiles;
  reg stage_pipe_pending, reloading, empty_seen_wait_rst;
  integer load_row, shift_mod_h, global_shift_idx, wait_cnt, empty_pulses, cyc_guard;
  reg [31:0] rng;
  reg want_shift, can_shift, do_load, pre_empty, pre_full, do_rst_w;
  integer prefix_cols;
  reg [15:0] got_word;

  initial begin
    rng = 32'hCAFE_1234;
    void'($value$plusargs("SEED=%d", rng));

    c_h_shift = 0; c_load = 0; c_pad_setup = 0; c_rst_w_index = 0; c_last_x = 0;
    c_width = W; c_height = TOT_DEPTH; c_slots = TOT_DEPTH;
    // Deliberately drive X on x_buffer_i when load=0 to test 4-state X-isolation!
    x_buffer_i = {DATA_W{1'bx}};

    repeat (2) @(posedge clk_i); #1;
    rst_ni = 1'b1;
    @(posedge clk_i); #1;

    if (x_buffer_o !== {W*H*16{1'b0}} || f_empty !== 1'b0) begin
      $display("[GL-FAIL] Post-reset outputs not clean 0: %h", x_buffer_o);
      $fatal(1, "post-reset X or non-zero");
    end

    // 3 tiles: Tile 0 partial width=2, partial height=11, slots=12;
    //          Tile 1 full width=4, partial height=5, slots=8;
    //          Tile 2 partial width=3, full height=16, slots=16.
    widths[0] = 2; heights[0] = 11; slots_a[0] = 12;
    widths[1] = 4; heights[1] = 5;  slots_a[1] = 8;
    widths[2] = 3; heights[2] = 16; slots_a[2] = 16;

    total_cols = 0;
    for (t = 0; t < 3; t = t + 1) begin
      for (r = 0; r < W; r = r + 1) begin
        for (c = 0; c < TOT_DEPTH; c = c + 1) begin
          rng = rng * 32'd1664525 + 32'd1013904223;
          tile_mat[t][r][c] = 16'h2000 ^ rng[15:0] ^ ((t + 1) << 12) ^ (r << 6) ^ c;
          if (tile_mat[t][r][c] == 16'h0000) tile_mat[t][r][c] = 16'h3c00;
        end
      end
      for (c = 0; c < slots_a[t]; c = c + 1) begin
        for (r = 0; r < W; r = r + 1) begin
          if ((r < widths[t]) && (c < heights[t]))
            exp_stream[total_cols + c][r] = tile_mat[t][r][c];
          else
            exp_stream[total_cols + c][r] = 16'h0000;
        end
      end
      total_cols = total_cols + slots_a[t];
    end

    for (r = 0; r < W; r = r + 1)
      for (h = 0; h < H; h = h + 1)
        exp_out[r][h] = 16'h0000;

    cur_cfg_tile = 0;
    c_width  = widths[0];
    c_height = heights[0];
    c_slots  = slots_a[0];
    @(posedge clk_i); #1;

    load_row = 0;
    while (load_row < widths[0]) begin
      c_load = 1'b1;
      for (c = 0; c < TOT_DEPTH; c = c + 1)
        x_buffer_i[c*16 +: 16] = tile_mat[0][load_row][c];
      load_row = load_row + 1;
      @(posedge clk_i); #1;
    end
    c_load = 1'b0;
    x_buffer_i = {DATA_W{1'bx}}; // 4-state X on idle data bus!

    if (f_full !== 1'b1) begin
      $display("[GL-FAIL] Expected f_full=1 after preload");
      $fatal(1, "preload full");
    end

    c_pad_setup = 1'b1;
    @(posedge clk_i); #1;
    c_pad_setup = 1'b0;

    loaded_tiles = 1; staged_tiles = 1; stage_pipe_pending = 0;
    load_row = 0; reloading = 0; empty_seen_wait_rst = 0;
    shift_mod_h = 0; global_shift_idx = 0; wait_cnt = 2;
    empty_pulses = 0; cyc_guard = 0;

    while (global_shift_idx < total_cols) begin
      cyc_guard = cyc_guard + 1;
      if (cyc_guard > 2000) begin
        $display("[GL-FAIL] Timeout at shift %0d/%0d", global_shift_idx, total_cols);
        $fatal(1, "gl timeout");
      end

      prefix_cols = 0;
      for (t = 0; t < staged_tiles; t = t + 1) prefix_cols = prefix_cols + slots_a[t];

      rng = rng * 32'd1664525 + 32'd1013904223;
      want_shift = (wait_cnt >= 2) && (rng[1:0] != 2'b00);
      can_shift  = want_shift && (global_shift_idx < prefix_cols);

      c_h_shift = can_shift;
      #1;
      pre_empty = f_empty;
      pre_full  = f_full;

      do_rst_w = can_shift && ((shift_mod_h == H - 1) || pre_empty) && pre_full;
      c_rst_w_index = do_rst_w;

      do_load = reloading && !pre_full && (loaded_tiles < 3) && (rng[0] == 1'b1);
      c_load = do_load;
      if (do_load) begin
        for (c = 0; c < TOT_DEPTH; c = c + 1)
          x_buffer_i[c*16 +: 16] = tile_mat[loaded_tiles][load_row][c];
      end else begin
        x_buffer_i = {DATA_W{1'bx}};
      end

      @(posedge clk_i); #1;

      if (stage_pipe_pending) begin
        staged_tiles = staged_tiles + 1;
        stage_pipe_pending = 0;
      end

      if (do_load) begin
        load_row = load_row + 1;
        if (load_row == widths[loaded_tiles]) begin
          reloading = 0;
          load_row = 0;
          loaded_tiles = loaded_tiles + 1;
          stage_pipe_pending = 1;
        end
      end

      if (pre_empty) begin
        empty_pulses = empty_pulses + 1;
        if (cur_cfg_tile + 1 < 3) begin
          cur_cfg_tile = cur_cfg_tile + 1;
          c_width  = widths[cur_cfg_tile];
          c_height = heights[cur_cfg_tile];
          c_slots  = slots_a[cur_cfg_tile];
          if (!pre_full || do_rst_w) reloading = 1;
          else empty_seen_wait_rst = 1;
        end
      end else if (empty_seen_wait_rst && !f_full) begin
        reloading = 1;
        empty_seen_wait_rst = 0;
      end

      if (can_shift) begin
        for (r = 0; r < W; r = r + 1)
          exp_out[r][global_shift_idx % H] = exp_stream[global_shift_idx][r];

        for (r = 0; r < W; r = r + 1) begin
          for (h = 0; h < H; h = h + 1) begin
            got_word = x_buffer_o[(r*H + h)*16 +: 16];
            if (h <= global_shift_idx) begin
              if (got_word !== exp_out[r][h]) begin
                $display("[GL-FAIL] shift=%0d r=%0d h=%0d got=%h exp=%h", global_shift_idx, r, h, got_word, exp_out[r][h]);
                $fatal(1, "gl data mismatch");
              end
            end else begin
              if ((got_word !== 16'h0000) && (got_word !== exp_stream[h][r])) begin
                $display("[GL-FAIL] pre-wavefront shift=%0d r=%0d h=%0d got=%h", global_shift_idx, r, h, got_word);
                $fatal(1, "gl pre-wavefront mismatch");
              end
            end
          end
        end
        global_shift_idx = global_shift_idx + 1;
        wait_cnt = 0;
        if (pre_full && pre_empty) shift_mod_h = 0;
        else shift_mod_h = (shift_mod_h == H - 1) ? 0 : (shift_mod_h + 1);
      end else begin
        wait_cnt = wait_cnt + 1;
      end
    end

    // Test simultaneous clear_i + c_load + c_h_shift with non-zero data!
    clear_i   = 1'b1;
    c_load    = 1'b1;
    c_h_shift = 1'b1;
    x_buffer_i = {DATA_W{1'b1}};
    @(posedge clk_i); #1;
    clear_i   = 1'b0;
    c_load    = 1'b0;
    c_h_shift = 1'b0;
    x_buffer_i = {DATA_W{1'bx}};
    if (x_buffer_o !== {W*H*16{1'b0}} || f_empty !== 1'b0) begin
      $display("[GL-FAIL] Simultaneous clear_i failed in gate-level sim: %h", x_buffer_o);
      $fatal(1, "gl clear failed");
    end

    $display("4-STATE GATE-LEVEL EQUIVALENCE PASSED!");
    $finish;
  end
endmodule
