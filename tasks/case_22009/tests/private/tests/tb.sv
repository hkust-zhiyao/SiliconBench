`timescale 1ns/1ps

module tb;
  import fpnew_pkg::*;
  import redmule_pkg::*;
  import hci_package::*;
  import hwpe_ctrl_package::*;
  import hwpe_stream_package::*;

  localparam int unsigned DATA_W    = 128;
  localparam int unsigned STRB_W    = DATA_W / 8; // 16 bytes
  localparam int unsigned FP_W      = 16;
  localparam int unsigned HEIGHT    = 4;
  localparam int unsigned WIDTH     = 4;
  localparam int unsigned PIPE_REGS = 1;
  localparam int unsigned DEPTH     = DATA_W / FP_W; // 8 FP16 elements
  localparam int unsigned MEM_BYTES = 262144; // 256 KB TCDM

  logic clk = 1'b0;
  always #5 clk = ~clk;

  logic             rst_ni;
  logic             test_mode_i;
  logic             target_clear_i;
  logic             cfg_valid_i;
  logic             cfg_ready_o;
  redmule_config_t  cfg_i;
  logic             busy_o;
  logic             evt_o;
  logic             done_o;

  cntrl_streamer_t  cntrl_streamer;
  flgs_streamer_t   flgs_streamer;

  logic               x_valid, x_ready;
  logic [DATA_W-1:0]  x_data;
  logic [STRB_W-1:0]  x_strb;

  logic               w_valid, w_ready;
  logic [DATA_W-1:0]  w_data;
  logic [STRB_W-1:0]  w_strb;

  logic               y_valid, y_ready;
  logic [DATA_W-1:0]  y_data;
  logic [STRB_W-1:0]  y_strb;

  logic               z_valid, z_ready;
  logic [DATA_W-1:0]  z_data;
  logic [STRB_W-1:0]  z_strb;

  redmule_subsys #(
    .DataW        ( DATA_W      ),
    .FpFormat     ( FP16        ),
    .Height       ( HEIGHT      ),
    .Width        ( WIDTH       ),
    .NumPipeRegs  ( PIPE_REGS   ),
    .PipeConfig   ( DISTRIBUTED ),
    .LatchBuffers ( 1'b0        )
  ) dut (
    .clk_i            ( clk            ),
    .rst_ni           ( rst_ni         ),
    .test_mode_i      ( test_mode_i    ),
    .target_clear_i   ( target_clear_i ),
    .cfg_valid_i      ( cfg_valid_i    ),
    .cfg_ready_o      ( cfg_ready_o    ),
    .cfg_i            ( cfg_i          ),
    .busy_o           ( busy_o         ),
    .evt_o            ( evt_o          ),
    .done_o           ( done_o         ),
    .cntrl_streamer_o ( cntrl_streamer ),
    .flgs_streamer_i  ( flgs_streamer  ),
    .x_stream_valid_i ( x_valid        ),
    .x_stream_ready_o ( x_ready        ),
    .x_stream_data_i  ( x_data         ),
    .x_stream_strb_i  ( x_strb         ),
    .w_stream_valid_i ( w_valid        ),
    .w_stream_ready_o ( w_ready        ),
    .w_stream_data_i  ( w_data         ),
    .w_stream_strb_i  ( w_strb         ),
    .y_stream_valid_i ( y_valid        ),
    .y_stream_ready_o ( y_ready        ),
    .y_stream_data_i  ( y_data         ),
    .y_stream_strb_i  ( y_strb         ),
    .z_stream_valid_o ( z_valid        ),
    .z_stream_ready_i ( z_ready        ),
    .z_stream_data_o  ( z_data         ),
    .z_stream_strb_o  ( z_strb         )
  );

  // =========================================================================
  // Byte-addressable 256 KB TCDM memory + HCI 3D/4D Streamer + Store FIFO
  // =========================================================================
  logic [7:0] tcdm_mem [0:MEM_BYTES-1];

  function automatic logic [DATA_W-1:0] mem_read_word(input logic [31:0] addr);
    logic [DATA_W-1:0] w;
    int unsigned base;
    base = addr[17:0];
    for (int b = 0; b < STRB_W; b++) begin
      w[b*8 +: 8] = tcdm_mem[(base + b) & (MEM_BYTES - 1)];
    end
    return w;
  endfunction

  task automatic mem_write_word(
    input logic [31:0]       addr,
    input logic [DATA_W-1:0] w,
    input logic [STRB_W-1:0] be
  );
    int unsigned base;
    base = addr[17:0];
    for (int b = 0; b < STRB_W; b++) begin
      if (be[b]) begin
        tcdm_mem[(base + b) & (MEM_BYTES - 1)] = w[b*8 +: 8];
      end
    end
  endtask

  typedef struct {
    logic                active;
    logic                done_pulse;
    ctrl_addressgen_v4_t ag;
    int unsigned         rem;
    int unsigned         i0, i1, i2;
    int signed           off0, off1, off2;
  } ag_chan_t;

  function automatic logic [31:0] ag_cur_addr(input ag_chan_t ch);
    return ch.ag.base_addr + ch.off0 + ch.off1 + ch.off2;
  endfunction

  function automatic ag_chan_t ag_step(input ag_chan_t ch_in);
    ag_chan_t ch;
    ch = ch_in;
    if (ch.rem <= 1) begin
      ch.rem        = 0;
      ch.active     = 1'b0;
      ch.done_pulse = 1'b1;
    end else begin
      ch.rem = ch.rem - 1;
      if (ch.i0 + 1 < ch.ag.d0_len) begin
        ch.i0   = ch.i0 + 1;
        ch.off0 = ch.off0 + ch.ag.d0_stride;
      end else begin
        ch.i0   = 0;
        ch.off0 = 0;
        if (ch.ag.dim_enable_1h[0] && (ch.i1 + 1 < ch.ag.d1_len)) begin
          ch.i1   = ch.i1 + 1;
          ch.off1 = ch.off1 + ch.ag.d1_stride;
        end else begin
          ch.i1   = 0;
          ch.off1 = 0;
          if (ch.ag.dim_enable_1h[1]) begin
            ch.i2   = ch.i2 + 1;
            ch.off2 = ch.off2 + ch.ag.d2_stride;
          end
        end
      end
    end
    return ch;
  endfunction

  function automatic ag_chan_t ag_init(input ctrl_addressgen_v4_t ctrl);
    ag_chan_t ch;
    ch.ag         = ctrl;
    ch.rem        = ctrl.tot_len;
    ch.i0         = 0;
    ch.i1         = 0;
    ch.i2         = 0;
    ch.off0       = 0;
    ch.off1       = 0;
    ch.off2       = 0;
    ch.active     = (ctrl.tot_len != 0);
    ch.done_pulse = (ctrl.tot_len == 0);
    return ch;
  endfunction

  ag_chan_t src_ch [0:2]; // 0: X, 1: W, 2: Y
  ag_chan_t snk_z;

  logic [1:0][31:0]       st_fifo_addr;
  logic [1:0][DATA_W-1:0] st_fifo_data;
  logic [1:0][STRB_W-1:0] st_fifo_strb;
  logic                   st_wptr, st_rptr;
  logic [1:0]             st_cnt;

  logic        bp_enable = 1'b0;
  logic [31:0] seed_init = 32'hACE1_0065;
  logic [31:0] lfsr_q    = 32'hACE1_0065;
  logic [1:0]  rr_arb_q  = 2'd0;

  wire st_fifo_full  = (st_cnt == 2'd2);
  wire st_fifo_empty = (st_cnt == 2'd0);

  logic [2:0] chan_grant;
  logic       z_mem_grant;
  logic       tcdm_avail;

  always_comb begin
    tcdm_avail  = !bp_enable || (lfsr_q[2:0] != 3'b000 && lfsr_q[4:3] != 2'b11);
    chan_grant  = '0;
    z_mem_grant = 1'b0;

    if (tcdm_avail) begin
      if (!st_fifo_empty && cntrl_streamer.z_priority) begin
        z_mem_grant = 1'b1;
      end else begin
        logic granted;
        granted = 1'b0;
        for (int off = 0; off < 3; off++) begin
          int idx;
          idx = (int'(rr_arb_q) + off) % 3;
          if (!granted && src_ch[idx].active) begin
            if ((idx == 0 && x_ready) || (idx == 1 && w_ready) || (idx == 2 && y_ready)) begin
              chan_grant[idx] = 1'b1;
              granted         = 1'b1;
            end
          end
        end
        if (!granted && !st_fifo_empty) begin
          z_mem_grant = 1'b1;
        end
      end
    end

    x_valid = src_ch[0].active && chan_grant[0];
    x_data  = src_ch[0].active ? mem_read_word(ag_cur_addr(src_ch[0])) : '0;
    x_strb  = '1;

    w_valid = src_ch[1].active && chan_grant[1];
    w_data  = src_ch[1].active ? mem_read_word(ag_cur_addr(src_ch[1])) : '0;
    w_strb  = '1;

    y_valid = src_ch[2].active && chan_grant[2];
    y_data  = src_ch[2].active ? mem_read_word(ag_cur_addr(src_ch[2])) : '0;
    y_strb  = '1;

    z_ready = snk_z.active && !st_fifo_full && (!bp_enable || lfsr_q[6:5] != 2'b00);

    flgs_streamer                                   = '0;
    flgs_streamer.store_fifo_empty                  = st_fifo_empty;
    flgs_streamer.x_stream_source_flags.ready_start = !src_ch[0].active && !src_ch[0].done_pulse;
    flgs_streamer.x_stream_source_flags.done        = src_ch[0].done_pulse;
    flgs_streamer.w_stream_source_flags.ready_start = !src_ch[1].active && !src_ch[1].done_pulse;
    flgs_streamer.w_stream_source_flags.done        = src_ch[1].done_pulse;
    flgs_streamer.y_stream_source_flags.ready_start = !src_ch[2].active && !src_ch[2].done_pulse;
    flgs_streamer.y_stream_source_flags.done        = src_ch[2].done_pulse;
    flgs_streamer.z_stream_sink_flags.ready_start   = !snk_z.active;
    flgs_streamer.z_stream_sink_flags.done          = snk_z.done_pulse;
  end

  always_ff @(posedge clk or negedge rst_ni) begin
    if (!rst_ni) begin
      for (int c = 0; c < 3; c++) begin
        src_ch[c].active     <= 1'b0;
        src_ch[c].done_pulse <= 1'b0;
        src_ch[c].rem        <= 0;
      end
      snk_z.active     <= 1'b0;
      snk_z.done_pulse <= 1'b0;
      snk_z.rem        <= 0;
      st_wptr          <= 1'b0;
      st_rptr          <= 1'b0;
      st_cnt           <= 2'd0;
      rr_arb_q         <= 2'd0;
      lfsr_q           <= seed_init;
    end else if (target_clear_i) begin
      for (int c = 0; c < 3; c++) begin
        src_ch[c].active     <= 1'b0;
        src_ch[c].done_pulse <= 1'b0;
        src_ch[c].rem        <= 0;
      end
      snk_z.active     <= 1'b0;
      snk_z.done_pulse <= 1'b0;
      snk_z.rem        <= 0;
      st_wptr          <= 1'b0;
      st_rptr          <= 1'b0;
      st_cnt           <= 2'd0;
    end else begin
      lfsr_q   <= {lfsr_q[30:0], lfsr_q[31] ^ lfsr_q[21] ^ lfsr_q[1] ^ lfsr_q[0]};
      rr_arb_q <= (rr_arb_q == 2'd2) ? 2'd0 : (rr_arb_q + 2'd1);

      for (int c = 0; c < 3; c++) begin
        hci_streamer_ctrl_t sctrl;
        logic sready;
        if (c == 0)      begin sctrl = cntrl_streamer.x_stream_source_ctrl; sready = x_ready; end
        else if (c == 1) begin sctrl = cntrl_streamer.w_stream_source_ctrl; sready = w_ready; end
        else             begin sctrl = cntrl_streamer.y_stream_source_ctrl; sready = y_ready; end

        if (src_ch[c].done_pulse) begin
          src_ch[c].done_pulse <= 1'b0;
        end else if (!src_ch[c].active) begin
          if (sctrl.req_start) begin
            src_ch[c] <= ag_init(sctrl.addressgen_ctrl);
          end
        end else if (chan_grant[c] && sready) begin
          src_ch[c] <= ag_step(src_ch[c]);
        end
      end

      begin
        logic do_st_push, do_st_pop;
        do_st_push = z_valid && z_ready;
        do_st_pop  = z_mem_grant;

        if (snk_z.done_pulse) begin
          snk_z.done_pulse <= 1'b0;
          if (cntrl_streamer.z_stream_sink_ctrl.req_start) begin
            snk_z <= ag_init(cntrl_streamer.z_stream_sink_ctrl.addressgen_ctrl);
          end
        end else if (!snk_z.active) begin
          if (cntrl_streamer.z_stream_sink_ctrl.req_start) begin
            snk_z <= ag_init(cntrl_streamer.z_stream_sink_ctrl.addressgen_ctrl);
          end
        end else if (do_st_push) begin
          snk_z <= ag_step(snk_z);
        end

        if (do_st_push) begin
          st_fifo_addr[st_wptr] <= ag_cur_addr(snk_z);
          st_fifo_data[st_wptr] <= z_data;
          st_fifo_strb[st_wptr] <= z_strb;
          st_wptr               <= ~st_wptr;
        end
        if (do_st_pop) begin
          mem_write_word(st_fifo_addr[st_rptr], st_fifo_data[st_rptr], st_fifo_strb[st_rptr]);
          st_rptr <= ~st_rptr;
        end
        case ({do_st_push, do_st_pop})
          2'b10:   st_cnt <= st_cnt + 2'd1;
          2'b01:   st_cnt <= st_cnt - 2'd1;
          default: st_cnt <= st_cnt;
        endcase
      end
    end
  end

  // Count job retirement pulses on done_o
  int unsigned done_pulse_cnt = 0;
  always_ff @(posedge clk or negedge rst_ni) begin
    if (!rst_ni || target_clear_i)
      done_pulse_cnt <= 0;
    else if (done_o)
      done_pulse_cnt <= done_pulse_cnt + 1;
  end

  // =========================================================================
  // Exact dyadic FP16 helpers for deterministic bit-exact matrix verification
  // =========================================================================
  function automatic logic [15:0] int_to_fp16(input int signed val);
    logic        sgn;
    int unsigned mag;
    int          msb;
    logic [4:0]  exp_f;
    logic [9:0]  man_f;
    if (val == 0) return 16'h0000;
    sgn = (val < 0);
    mag = (val < 0) ? unsigned'(-val) : unsigned'(val);
    msb = 0;
    for (int b = 0; b < 15; b++) begin
      if (mag[b]) msb = b;
    end
    exp_f = 5'(15 + msb);
    if (msb <= 10)
      man_f = 10'(mag << (10 - msb));
    else
      man_f = 10'(mag >> (msb - 10));
    return {sgn, exp_f, man_f};
  endfunction

  function automatic logic [15:0] q2_to_fp16(input int signed q2_val);
    logic [15:0] h;
    h = int_to_fp16(q2_val);
    if (h[14:10] != 5'd0) h[14:10] = h[14:10] - 5'd2;
    return h;
  endfunction

  function automatic logic [15:0] q4_to_fp16(input int signed q4_val);
    logic [15:0] h;
    h = int_to_fp16(q4_val);
    if (h[14:10] != 5'd0) h[14:10] = h[14:10] - 5'd4;
    return h;
  endfunction

  task automatic write_fp16(input logic [31:0] byte_addr, input logic [15:0] val);
    tcdm_mem[byte_addr]     = val[7:0];
    tcdm_mem[byte_addr + 1] = val[15:8];
  endtask

  function automatic logic [15:0] read_fp16(input logic [31:0] byte_addr);
    return {tcdm_mem[byte_addr + 1], tcdm_mem[byte_addr]};
  endfunction

  function automatic redmule_config_t make_job_cfg(
    input logic [31:0] x_addr,
    input logic [31:0] w_addr,
    input logic [31:0] y_addr,
    input logic [31:0] z_addr,
    input int unsigned m_sz,
    input int unsigned n_sz,
    input int unsigned k_sz,
    input bit          is_gemm,
    input int unsigned w_cols_offs
  );
    redmule_config_t c;
    c                 = '0;
    c.x_addr          = x_addr;
    c.w_addr          = w_addr;
    c.y_addr          = y_addr;
    c.z_addr          = z_addr;
    c.y_offs          = y_addr - z_addr;
    c.m_size          = 16'(m_sz);
    c.n_size          = 16'(n_sz);
    c.k_size          = 16'(k_sz);
    c.gemm_ops        = is_gemm ? GEMM : MATMUL;
    c.gemm_input_fmt  = Float16;
    c.gemm_output_fmt = Float16;
    c.w_cols_offset   = 16'(w_cols_offs);
    return c;
  endfunction

  int unsigned total_tests = 0;
  int unsigned total_fails = 0;

  task automatic fill_canary_all();
    for (int i = 0; i < MEM_BYTES; i += 2) begin
      tcdm_mem[i]     = 8'hAD;
      tcdm_mem[i + 1] = 8'hDE; // 0xDEAD = NaN/huge canary
    end
  endtask

  task automatic populate_job_Region(
    input logic [31:0] x_base,
    input logic [31:0] w_base,
    input logic [31:0] y_base,
    input logic [31:0] z_base,
    input int unsigned M,
    input int unsigned N,
    input int unsigned K,
    input bit          is_gemm,
    input int unsigned salt,
    output logic [15:0] exp_z [0:15][0:31]
  );
    int signed x_q2 [0:15][0:31];
    int signed w_q2 [0:31][0:31];
    int signed y_q4 [0:15][0:31];
    int signed acc_q4;

    for (int m = 0; m < M; m++) begin
      for (int n = 0; n < N; n++) begin
        x_q2[m][n] = int'(((m * 7 + n * 3 + salt + 1) % 7)) - 3;
        write_fp16(x_base + (m * N + n) * 2, q2_to_fp16(x_q2[m][n]));
      end
    end

    for (int n = 0; n < N; n++) begin
      for (int k = 0; k < K; k++) begin
        w_q2[n][k] = int'(((n * 5 + k * 11 + salt * 3 + 2) % 7)) - 3;
        write_fp16(w_base + (n * K + k) * 2, q2_to_fp16(w_q2[n][k]));
      end
    end

    for (int m = 0; m < M; m++) begin
      for (int k = 0; k < K; k++) begin
        y_q4[m][k] = is_gemm ? (int'(((m * 3 + k * 5 + salt) % 11)) - 5) : 0;
        if (is_gemm) begin
          write_fp16(y_base + (m * K + k) * 2, q4_to_fp16(y_q4[m][k]));
        end
        write_fp16(z_base + (m * K + k) * 2, 16'hBEEF);
        acc_q4 = y_q4[m][k];
        for (int n = 0; n < N; n++) begin
          acc_q4 += x_q2[m][n] * w_q2[n][k];
        end
        exp_z[m][k] = q4_to_fp16(acc_q4);
      end
    end
  endtask

  task automatic check_job_result(
    input string        name,
    input logic [31:0]  z_base,
    input int unsigned  M,
    input int unsigned  K,
    input logic [15:0]  exp_z [0:15][0:31],
    output int unsigned errs
  );
    logic [15:0] got_fp16;
    errs = 0;
    if (z_base >= 64) begin
      for (int pre = 1; pre <= 16; pre++) begin
        got_fp16 = read_fp16(z_base - pre * 2);
        if (got_fp16 !== 16'hDEAD) begin
          if (errs < 4)
            $display("  [ERR] %s pre-canary overwrite at -0x%0x: got=0x%04x", name, pre*2, got_fp16);
          errs++;
        end
      end
    end
    for (int m = 0; m < M; m++) begin
      for (int k = 0; k < K; k++) begin
        got_fp16 = read_fp16(z_base + (m * K + k) * 2);
        if (got_fp16 !== exp_z[m][k]) begin
          if (errs < 4)
            $display("  [ERR] %s Z[%0d][%0d]: got=0x%04x exp=0x%04x", name, m, k, got_fp16, exp_z[m][k]);
          errs++;
        end
      end
    end
    for (int extra = 0; extra < 4 * K + 16; extra++) begin
      got_fp16 = read_fp16(z_base + (M * K + extra) * 2);
      if (got_fp16 !== 16'hDEAD) begin
        if (errs < 4)
          $display("  [ERR] %s post-canary OOB overwrite at +0x%0x: got=0x%04x exp=0xDEAD", name, extra*2, got_fp16);
        errs++;
      end
    end
  endtask

  task automatic recover_after_timeout();
    target_clear_i <= 1'b1;
    cfg_valid_i    <= 1'b0;
    repeat (6) @(posedge clk);
    target_clear_i <= 1'b0;
    repeat (6) @(posedge clk);
  endtask

  task automatic run_single_job(
    input string       name,
    input int unsigned M,
    input int unsigned N,
    input int unsigned K,
    input bit          is_gemm,
    input int unsigned w_cols_offs,
    input bit          enable_bp,
    input int unsigned salt
  );
    logic [31:0] x_base, w_base, y_base, z_base;
    logic [15:0] exp_z [0:15][0:31];
    int unsigned start_done_cnt, cyc, errs;

    total_tests++;
    x_base = 32'h0000_1000;
    w_base = 32'h0000_8000;
    y_base = 32'h0001_0000;
    z_base = 32'h0001_8000;

    fill_canary_all();
    populate_job_Region(x_base, w_base, y_base, z_base, M, N, K, is_gemm, salt, exp_z);
    bp_enable = enable_bp;

    @(posedge clk);
    cyc = 0;
    while (!cfg_ready_o && cyc < 2000) begin @(posedge clk); cyc++; end
    if (!cfg_ready_o) begin
      $display("[FAIL] %s: cfg_ready_o stuck low before launch", name);
      total_fails++;
      recover_after_timeout();
    end else begin
      start_done_cnt = done_pulse_cnt;
      cfg_i          <= make_job_cfg(x_base, w_base, y_base, z_base, M, N, K, is_gemm, w_cols_offs);
      cfg_valid_i    <= 1'b1;
      @(posedge clk);
      cfg_valid_i    <= 1'b0;

      cyc = 0;
      while ((done_pulse_cnt == start_done_cnt) && cyc < 30000) begin
        @(posedge clk);
        cyc++;
      end
      while ((busy_o || !st_fifo_empty) && cyc < 30000) begin
        @(posedge clk);
        cyc++;
      end
      repeat (3) @(posedge clk);

      if (cyc >= 30000) begin
        $display("[FAIL] %s: TIMEOUT (deadlock)", name);
        total_fails++;
        recover_after_timeout();
      end else begin
        check_job_result(name, z_base, M, K, exp_z, errs);
        if (done_pulse_cnt != start_done_cnt + 1) begin
          $display("  [ERR] %s: expected 1 done_o pulse, got %0d", name, done_pulse_cnt - start_done_cnt);
          errs++;
        end

        if (errs == 0) begin
          $display("[PASS] %s (%0d cycles)", name, cyc);
        end else begin
          $display("[FAIL] %s: %0d errors", name, errs);
          total_fails++;
        end
      end
    end
  endtask

  task automatic run_queued_pair(
    input string       name,
    input int unsigned M1, input int unsigned N1, input int unsigned K1, input bit gemm1, input int unsigned offs1,
    input int unsigned M2, input int unsigned N2, input int unsigned K2, input bit gemm2, input int unsigned offs2,
    input bit          enable_bp,
    input int unsigned salt
  );
    logic [31:0] x1, w1, y1, z1, x2, w2, y2, z2;
    logic [15:0] exp_z1 [0:15][0:31];
    logic [15:0] exp_z2 [0:15][0:31];
    int unsigned start_done_cnt, cyc, errs1, errs2;

    total_tests++;
    x1 = 32'h0000_1000; w1 = 32'h0000_5000; y1 = 32'h0000_9000; z1 = 32'h0000_D000;
    x2 = 32'h0001_2000; w2 = 32'h0001_6000; y2 = 32'h0001_A000; z2 = 32'h0001_E000;

    fill_canary_all();
    populate_job_Region(x1, w1, y1, z1, M1, N1, K1, gemm1, salt,      exp_z1);
    populate_job_Region(x2, w2, y2, z2, M2, N2, K2, gemm2, salt + 17, exp_z2);
    bp_enable = enable_bp;

    @(posedge clk);
    cyc = 0;
    while (!cfg_ready_o && cyc < 2000) begin @(posedge clk); cyc++; end
    start_done_cnt = done_pulse_cnt;

    // Push Job 1
    cfg_i       <= make_job_cfg(x1, w1, y1, z1, M1, N1, K1, gemm1, offs1);
    cfg_valid_i <= 1'b1;
    @(posedge clk);
    cfg_valid_i <= 1'b0;

    // Immediately queue Job 2 while Job 1 is actively starting/executing
    repeat (2) @(posedge clk);
    cyc = 0;
    while (!cfg_ready_o && cyc < 2000) begin @(posedge clk); cyc++; end
    cfg_i       <= make_job_cfg(x2, w2, y2, z2, M2, N2, K2, gemm2, offs2);
    cfg_valid_i <= 1'b1;
    @(posedge clk);
    cfg_valid_i <= 1'b0;

    cyc = 0;
    while ((done_pulse_cnt < start_done_cnt + 2) && cyc < 50000) begin
      @(posedge clk);
      cyc++;
    end
    while ((busy_o || !st_fifo_empty) && cyc < 50000) begin
      @(posedge clk);
      cyc++;
    end
    repeat (4) @(posedge clk);

    if (cyc >= 50000) begin
      $display("[FAIL] %s: TIMEOUT (done_cnt=%0d/%0d)", name, done_pulse_cnt - start_done_cnt, 2);
      total_fails++;
      recover_after_timeout();
    end else begin
      check_job_result({name, "_job1"}, z1, M1, K1, exp_z1, errs1);
      check_job_result({name, "_job2"}, z2, M2, K2, exp_z2, errs2);

      if (errs1 + errs2 == 0) begin
        $display("[PASS] %s (%0d cycles)", name, cyc);
      end else begin
        $display("[FAIL] %s: job1_errs=%0d job2_errs=%0d", name, errs1, errs2);
        total_fails++;
      end
    end
  endtask

  task automatic run_midjob_clear_test(input int unsigned salt);
    logic [31:0] x_abrt, w_abrt, y_abrt, z_abrt;
    logic [31:0] x_clean, w_clean, y_clean, z_clean;
    logic [15:0] exp_abrt  [0:15][0:31];
    logic [15:0] exp_clean [0:15][0:31];
    int unsigned start_done_cnt, cyc, errs;

    total_tests++;
    x_abrt  = 32'h0000_2000; w_abrt  = 32'h0000_6000; y_abrt  = 32'h0000_A000; z_abrt  = 32'h0000_E000;
    x_clean = 32'h0001_2000; w_clean = 32'h0001_6000; y_clean = 32'h0001_A000; z_clean = 32'h0001_E000;

    fill_canary_all();
    populate_job_Region(x_abrt,  w_abrt,  y_abrt,  z_abrt,  8, 16, 24, 1'b1, salt,      exp_abrt);
    populate_job_Region(x_clean, w_clean, y_clean, z_clean, 7,  3, 19, 1'b1, salt + 31, exp_clean);
    bp_enable = 1'b1;

    @(posedge clk);
    cfg_i       <= make_job_cfg(x_abrt, w_abrt, y_abrt, z_abrt, 8, 16, 24, 1'b1, 0);
    cfg_valid_i <= 1'b1;
    @(posedge clk);
    cfg_valid_i <= 1'b0;

    // Let accelerator run mid-wavefront then assert synchronous clear
    repeat (55) @(posedge clk);
    target_clear_i <= 1'b1;
    repeat (2) @(posedge clk);
    target_clear_i <= 1'b0;
    repeat (4) @(posedge clk);

    // Immediately launch recovery job (7x3x19 GEMM with w_cols_offset=8)
    start_done_cnt = done_pulse_cnt;
    cfg_i          <= make_job_cfg(x_clean, w_clean, y_clean, z_clean, 7, 3, 19, 1'b1, 8);
    cfg_valid_i    <= 1'b1;
    @(posedge clk);
    cfg_valid_i    <= 1'b0;

    cyc = 0;
    while ((done_pulse_cnt == start_done_cnt) && cyc < 30000) begin
      @(posedge clk);
      cyc++;
    end
    while ((busy_o || !st_fifo_empty) && cyc < 30000) begin
      @(posedge clk);
      cyc++;
    end
    repeat (4) @(posedge clk);

    if (cyc >= 30000) begin
      $display("[FAIL] T9_midjob_clear_recovery: TIMEOUT after clear");
      total_fails++;
      recover_after_timeout();
    end else begin
      check_job_result("T9_midjob_clear_recovery", z_clean, 7, 19, exp_clean, errs);
      if (errs == 0) begin
        $display("[PASS] T9_midjob_clear_recovery (%0d cycles)", cyc);
      end else begin
        $display("[FAIL] T9_midjob_clear_recovery: %0d errors", errs);
        total_fails++;
      end
    end
  endtask

  initial begin
    int unsigned user_seed;
    if (!$value$plusargs("SEED=%d", user_seed)) begin
      user_seed = 101;
    end
    seed_init = 32'h9E37_79B9 ^ (user_seed * 32'h0101_0193);
    if (seed_init == 32'd0) seed_init = 32'hACE1_1234;

    rst_ni         = 1'b0;
    test_mode_i    = 1'b0;
    target_clear_i = 1'b0;
    cfg_valid_i    = 1'b0;
    cfg_i          = '0;
    repeat (6) @(posedge clk);
    rst_ni = 1'b1;
    repeat (4) @(posedge clk);

    $display("=== Running RedMulE Wavefront Verification (SEED=%0d) ===", user_seed);

    // T1: Aligned baseline sanity
    run_single_job("T1a_aligned_matmul_4x8x16",     4,  8, 16, 1'b0, 0,  1'b0, user_seed + 1);
    run_single_job("T1b_aligned_gemm_8x16x24_bp",   8, 16, 24, 1'b1, 0,  1'b1, user_seed + 2);

    // T2: Small-N promotion & W-operand zero-gating (N <= Height)
    run_single_job("T2a_small_n1_matmul_8x1x16",    8,  1, 16, 1'b0, 0,  1'b0, user_seed + 3);
    run_single_job("T2b_small_n3_gemm_8x3x24_bp",   8,  3, 24, 1'b1, 0,  1'b1, user_seed + 4);
    run_single_job("T2c_small_n4_matmul_12x4x16",  12,  4, 16, 1'b0, 0,  1'b1, user_seed + 5);

    // T3: Padded W-row leftover zero-gating when N > Height and N % Height == 1
    run_single_job("T3a_nlft1_matmul_8x5x16",       8,  5, 16, 1'b0, 0,  1'b0, user_seed + 6);
    run_single_job("T3b_nlft1_gemm_8x9x24_bp",      8,  9, 24, 1'b1, 0,  1'b1, user_seed + 7);

    // T4: Odd and even K leftovers (WAIT-state drain + z_height/z_strb sync)
    run_single_job("T4a_odd_k5_matmul_4x8x5",       4,  8,  5, 1'b0, 0,  1'b0, user_seed + 8);
    run_single_job("T4b_even_k14_matmul_4x8x14",    4,  8, 14, 1'b0, 0,  1'b0, user_seed + 9);
    run_single_job("T4c_odd_k13_gemm_8x8x13_bp",    8,  8, 13, 1'b1, 0,  1'b1, user_seed + 10);
    run_single_job("T4d_odd_k1_gemm_4x12x1",        4, 12,  1, 1'b1, 0,  1'b1, user_seed + 11);

    // T5: Non-divisible M leftovers + strict OOB canary protection
    run_single_job("T5a_mlft_matmul_6x8x16",        6,  8, 16, 1'b0, 0,  1'b0, user_seed + 12);
    run_single_job("T5b_mlft_gemm_5x8x16_bp",       5,  8, 16, 1'b1, 0,  1'b1, user_seed + 13);
    run_single_job("T5c_mlft_gemm_1x8x16",          1,  8, 16, 1'b1, 0,  1'b0, user_seed + 14);

    // T6: Coupled prime (M, N, K) leftovers under randomized TCDM backpressure
    run_single_job("T6a_prime_gemm_5x11x19_bp",     5, 11, 19, 1'b1, 0,  1'b1, user_seed + 15);
    run_single_job("T6b_prime_gemm_7x3x13_bp",      7,  3, 13, 1'b1, 0,  1'b1, user_seed + 16);
    run_single_job("T6c_prime_matmul_6x9x17_bp",    6,  9, 17, 1'b0, 0,  1'b1, user_seed + 17);

    // T7: Multi-pass loopback_w (w_cols_offset != 0) with leftovers & backpressure
    run_single_job("T7a_loopback_gemm_6x11x21_bp",  6, 11, 21, 1'b1, 16, 1'b1, user_seed + 18);
    run_single_job("T7b_loopback_matmul_5x3x24_bp", 5,  3, 24, 1'b0, 16, 1'b1, user_seed + 19);
    run_single_job("T7c_loopback_gemm_7x9x27_bp",   7,  9, 27, 1'b1, 16, 1'b1, user_seed + 20);

    // T8: Back-to-back queued jobs (including loopback_w + small-N and 1-word MATMUL + GEMM)
    run_queued_pair("T8a_queued_loopback_then_smalln",
                    6,  9, 21, 1'b1, 16,
                    5,  3, 13, 1'b1, 0,
                    1'b1, user_seed + 21);
    run_queued_pair("T8b_queued_1word_matmul_then_gemm",
                    1,  8,  8, 1'b0, 0,
                    5,  9, 11, 1'b1, 0,
                    1'b1, user_seed + 25);

    // T9: Mid-job target_clear_i abort and immediate recovery
    run_midjob_clear_test(user_seed + 29);

    // T10: Seeded sweep across additional randomized shapes
    for (int r = 0; r < 4; r++) begin
      int unsigned rm, rn, rk, roffs;
      bit          rgemm;
      rm    = 2 + ((user_seed * 3 + r * 5) % 9);  // 2..10
      rn    = 1 + ((user_seed * 7 + r * 4) % 13); // 1..13
      rk    = 9 + ((user_seed * 5 + r * 7) % 19); // 9..27
      rgemm = bit'((user_seed + r) & 1);
      roffs = ((r % 2 == 1) && (rk > 10)) ? 8 : 0;
      run_single_job($sformatf("T10_rand_%0d_%0dx%0dx%0d_g%0d_o%0d", r, rm, rn, rk, rgemm, roffs),
                     rm, rn, rk, rgemm, roffs, 1'b1, user_seed + 40 + r);
    end

    $display("=== SUMMARY (SEED=%0d): %0d/%0d passed, %0d failed ===",
             user_seed, total_tests - total_fails, total_tests, total_fails);
    if (total_fails != 0) begin
      $fatal(1, "Verification failed");
    end
    $finish;
  end

endmodule
