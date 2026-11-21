`timescale 1ns/1ps

module tb;
  import redmule_pkg::*;
  import hwpe_ctrl_package::*;
  import redmule_xif_pkg::*;

  localparam logic [6:0] OPC = 7'b0001011;
  localparam logic [2:0] F3_MCNFIG = 3'b000;
  localparam logic [2:0] F3_MARITH = 3'b001;
  localparam logic [2:0] F3_MOPCNT = 3'b010;
  localparam logic [1:0] F2_ZERO   = 2'b00;

  `REDMULE_XIF_TYPEDEF_ALL(xif_1h4, 1, 4)
  `REDMULE_XIF_TYPEDEF_ALL(xif_2h4, 2, 4)
  `REDMULE_XIF_TYPEDEF_ALL(xif_2h5, 2, 5)

  logic clk = 1'b0;
  always #5 clk = ~clk;

  int seed = 101;

  function automatic logic [31:0] mk_instr(
    input logic [1:0] f2,
    input logic [2:0] f3,
    input logic [4:0] rd,
    input logic [6:0] op
  );
    return {5'b00001, f2, 5'b00010, 5'b00011, f3, rd, op};
  endfunction

  function automatic logic [31:0] mk_mcnfig0(input logic [15:0] m, input logic [15:0] k);
    return {k, m};
  endfunction

  function automatic logic [31:0] mk_mcnfig1(
    input logic [15:0] n,
    input logic        rx_x,
    input logic        tx_x,
    input logic        rx_w,
    input logic        tx_w,
    input gemm_op_e    op,
    input gemm_fmt_e   ifmt,
    input gemm_fmt_e   ofmt
  );
    return {5'b0, ofmt, ifmt, op, tx_w, rx_w, tx_x, rx_x, n};
  endfunction

  // =========================================================================
  // Instance A: 1 Hart, InstFifoDepth=2, OpIdWidth=3, Split=0
  // =========================================================================
  logic                rst_n_a, clear_a;
  xif_1h4_issue_req_t  iss_req_a;
  xif_1h4_issue_resp_t iss_rsp_a;
  logic                iss_val_a, iss_rdy_a;
  xif_1h4_register_t   reg_req_a;
  logic                reg_val_a, reg_rdy_a;
  xif_1h4_commit_t     com_req_a;
  logic                com_val_a;
  xif_1h4_result_t     res_pkt_a;
  logic                res_val_a, res_rdy_a;
  flgs_streamer_t      flgs_a;
  logic                z_empty_a, z_full_a, w_loaded_a;
  logic                busy_a, evt_a, fifo_full_a, fifo_empty_a, cfg_comp_a;
  cntrl_scheduler_t    sched_a;
  cntrl_flags_t        cflags_a;
  redmule_config_t     act_cfg_a;

  redmule_xif_offload_subsys #(
    .InstFifoDepth         ( 2                    ),
    .OpIdWidth             ( 3                    ),
    .XifIdWidth            ( 4                    ),
    .XifNumHarts           ( 1                    ),
    .XifIssueRegisterSplit ( 0                    ),
    .x_issue_req_t         ( xif_1h4_issue_req_t  ),
    .x_issue_resp_t        ( xif_1h4_issue_resp_t ),
    .x_register_t          ( xif_1h4_register_t   ),
    .x_commit_t            ( xif_1h4_commit_t     ),
    .x_result_t            ( xif_1h4_result_t     )
  ) i_dut_a (
    .clk_i               ( clk          ),
    .rst_ni              ( rst_n_a      ),
    .clear_i             ( clear_a      ),
    .test_mode_i         ( 1'b0         ),
    .x_issue_req_i       ( iss_req_a    ),
    .x_issue_resp_o      ( iss_rsp_a    ),
    .x_issue_valid_i     ( iss_val_a    ),
    .x_issue_ready_o     ( iss_rdy_a    ),
    .x_register_i        ( reg_req_a    ),
    .x_register_valid_i  ( reg_val_a    ),
    .x_register_ready_o  ( reg_rdy_a    ),
    .x_commit_i          ( com_req_a    ),
    .x_commit_valid_i    ( com_val_a    ),
    .x_result_o          ( res_pkt_a    ),
    .x_result_valid_o    ( res_val_a    ),
    .x_result_ready_i    ( res_rdy_a    ),
    .flgs_streamer_i     ( flgs_a       ),
    .reg_enable_i        ( 1'b1         ),
    .z_fifo_empty_i      ( z_empty_a    ),
    .z_fifo_full_i       ( z_full_a     ),
    .w_loaded_i          ( w_loaded_a   ),
    .busy_o              ( busy_a       ),
    .tiler_busy_o        (              ),
    .ctrl_clear_o        (              ),
    .evt_o               ( evt_a        ),
    .engine_flush_o      (              ),
    .cntrl_scheduler_o   ( sched_a      ),
    .cntrl_flags_o       ( cflags_a     ),
    .active_config_o     ( act_cfg_a    ),
    .config_fifo_full_o  ( fifo_full_a  ),
    .config_fifo_empty_o ( fifo_empty_a ),
    .cfg_complete_o      ( cfg_comp_a   )
  );

  // =========================================================================
  // Instance B: 2 Harts, InstFifoDepth=4, OpIdWidth=4, Split=0
  // =========================================================================
  logic                rst_n_b, clear_b;
  xif_2h4_issue_req_t  iss_req_b;
  xif_2h4_issue_resp_t iss_rsp_b;
  logic                iss_val_b, iss_rdy_b;
  xif_2h4_register_t   reg_req_b;
  logic                reg_val_b, reg_rdy_b;
  xif_2h4_commit_t     com_req_b;
  logic                com_val_b;
  xif_2h4_result_t     res_pkt_b;
  logic                res_val_b, res_rdy_b;
  flgs_streamer_t      flgs_b;
  logic                z_empty_b, z_full_b, w_loaded_b;
  logic                busy_b, evt_b, fifo_full_b, fifo_empty_b, cfg_comp_b;
  cntrl_scheduler_t    sched_b;
  cntrl_flags_t        cflags_b;
  redmule_config_t     act_cfg_b;

  redmule_xif_offload_subsys #(
    .InstFifoDepth         ( 4                    ),
    .OpIdWidth             ( 4                    ),
    .XifIdWidth            ( 4                    ),
    .XifNumHarts           ( 2                    ),
    .XifIssueRegisterSplit ( 0                    ),
    .x_issue_req_t         ( xif_2h4_issue_req_t  ),
    .x_issue_resp_t        ( xif_2h4_issue_resp_t ),
    .x_register_t          ( xif_2h4_register_t   ),
    .x_commit_t            ( xif_2h4_commit_t     ),
    .x_result_t            ( xif_2h4_result_t     )
  ) i_dut_b (
    .clk_i               ( clk          ),
    .rst_ni              ( rst_n_b      ),
    .clear_i             ( clear_b      ),
    .test_mode_i         ( 1'b0         ),
    .x_issue_req_i       ( iss_req_b    ),
    .x_issue_resp_o      ( iss_rsp_b    ),
    .x_issue_valid_i     ( iss_val_b    ),
    .x_issue_ready_o     ( iss_rdy_b    ),
    .x_register_i        ( reg_req_b    ),
    .x_register_valid_i  ( reg_val_b    ),
    .x_register_ready_o  ( reg_rdy_b    ),
    .x_commit_i          ( com_req_b    ),
    .x_commit_valid_i    ( com_val_b    ),
    .x_result_o          ( res_pkt_b    ),
    .x_result_valid_o    ( res_val_b    ),
    .x_result_ready_i    ( res_rdy_b    ),
    .flgs_streamer_i     ( flgs_b       ),
    .reg_enable_i        ( 1'b1         ),
    .z_fifo_empty_i      ( z_empty_b    ),
    .z_fifo_full_i       ( z_full_b     ),
    .w_loaded_i          ( w_loaded_b   ),
    .busy_o              ( busy_b       ),
    .tiler_busy_o        (              ),
    .ctrl_clear_o        (              ),
    .evt_o               ( evt_b        ),
    .engine_flush_o      (              ),
    .cntrl_scheduler_o   ( sched_b      ),
    .cntrl_flags_o       ( cflags_b     ),
    .active_config_o     ( act_cfg_b    ),
    .config_fifo_full_o  ( fifo_full_b  ),
    .config_fifo_empty_o ( fifo_empty_b ),
    .cfg_complete_o      ( cfg_comp_b   )
  );

  // =========================================================================
  // Instance C: 2 Harts, InstFifoDepth=4, OpIdWidth=4, Split=1 (Out-of-Order)
  // =========================================================================
  logic                rst_n_c, clear_c;
  xif_2h5_issue_req_t  iss_req_c;
  xif_2h5_issue_resp_t iss_rsp_c;
  logic                iss_val_c, iss_rdy_c;
  xif_2h5_register_t   reg_req_c;
  logic                reg_val_c, reg_rdy_c;
  xif_2h5_commit_t     com_req_c;
  logic                com_val_c;
  xif_2h5_result_t     res_pkt_c;
  logic                res_val_c, res_rdy_c;
  flgs_streamer_t      flgs_c;
  logic                z_empty_c, z_full_c, w_loaded_c;
  logic                busy_c, evt_c, fifo_full_c, fifo_empty_c, cfg_comp_c;
  cntrl_scheduler_t    sched_c;
  cntrl_flags_t        cflags_c;
  redmule_config_t     act_cfg_c;

  redmule_xif_offload_subsys #(
    .InstFifoDepth         ( 4                    ),
    .OpIdWidth             ( 4                    ),
    .XifIdWidth            ( 5                    ),
    .XifNumHarts           ( 2                    ),
    .XifIssueRegisterSplit ( 1                    ),
    .x_issue_req_t         ( xif_2h5_issue_req_t  ),
    .x_issue_resp_t        ( xif_2h5_issue_resp_t ),
    .x_register_t          ( xif_2h5_register_t   ),
    .x_commit_t            ( xif_2h5_commit_t     ),
    .x_result_t            ( xif_2h5_result_t     )
  ) i_dut_c (
    .clk_i               ( clk          ),
    .rst_ni              ( rst_n_c      ),
    .clear_i             ( clear_c      ),
    .test_mode_i         ( 1'b0         ),
    .x_issue_req_i       ( iss_req_c    ),
    .x_issue_resp_o      ( iss_rsp_c    ),
    .x_issue_valid_i     ( iss_val_c    ),
    .x_issue_ready_o     ( iss_rdy_c    ),
    .x_register_i        ( reg_req_c    ),
    .x_register_valid_i  ( reg_val_c    ),
    .x_register_ready_o  ( reg_rdy_c    ),
    .x_commit_i          ( com_req_c    ),
    .x_commit_valid_i    ( com_val_c    ),
    .x_result_o          ( res_pkt_c    ),
    .x_result_valid_o    ( res_val_c    ),
    .x_result_ready_i    ( res_rdy_c    ),
    .flgs_streamer_i     ( flgs_c       ),
    .reg_enable_i        ( 1'b1         ),
    .z_fifo_empty_i      ( z_empty_c    ),
    .z_fifo_full_i       ( z_full_c     ),
    .w_loaded_i          ( w_loaded_c   ),
    .busy_o              ( busy_c       ),
    .tiler_busy_o        (              ),
    .ctrl_clear_o        (              ),
    .evt_o               ( evt_c        ),
    .engine_flush_o      (              ),
    .cntrl_scheduler_o   ( sched_c      ),
    .cntrl_flags_o       ( cflags_c     ),
    .active_config_o     ( act_cfg_c    ),
    .config_fifo_full_o  ( fifo_full_c  ),
    .config_fifo_empty_o ( fifo_empty_c ),
    .cfg_complete_o      ( cfg_comp_c   )
  );

  // =========================================================================
  // Continuous Protocol & Stability Assertions on B and C
  // =========================================================================
  logic                prev_stall_b, prev_stall_c;
  xif_2h4_result_t     prev_res_b;
  xif_2h5_result_t     prev_res_c;

  always_ff @(posedge clk or negedge rst_n_b) begin
    if (!rst_n_b || clear_b) begin
      prev_stall_b <= 1'b0;
      prev_res_b   <= '0;
    end else begin
      if (prev_stall_b) begin
        if (!res_val_b || (res_pkt_b !== prev_res_b)) begin
          $display("FAIL [proto_b]: x_result changed or dropped during x_result_ready_i=0 stall (prev=%p cur_val=%0b cur=%p)",
                   prev_res_b, res_val_b, res_pkt_b);
          $fatal(1);
        end
      end
      prev_stall_b <= res_val_b && !res_rdy_b;
      prev_res_b   <= res_pkt_b;
    end
  end

  always_ff @(posedge clk or negedge rst_n_c) begin
    if (!rst_n_c || clear_c) begin
      prev_stall_c <= 1'b0;
      prev_res_c   <= '0;
    end else begin
      if (prev_stall_c) begin
        if (!res_val_c || (res_pkt_c !== prev_res_c)) begin
          $display("FAIL [proto_c]: x_result changed or dropped during x_result_ready_i=0 stall (prev=%p cur_val=%0b cur=%p)",
                   prev_res_c, res_val_c, res_pkt_c);
          $fatal(1);
        end
      end
      prev_stall_c <= res_val_c && !res_rdy_c;
      prev_res_c   <= res_pkt_c;
    end
  end

  // Result capture queues
  xif_1h4_result_t res_q_a[$];
  xif_2h4_result_t res_q_b[$];
  xif_2h5_result_t res_q_c[$];
  int evt_cnt_a = 0, evt_cnt_b = 0, evt_cnt_c = 0;

  always @(posedge clk) begin
    if (rst_n_a && !clear_a) begin
      if (res_val_a && res_rdy_a) res_q_a.push_back(res_pkt_a);
      if (evt_a) evt_cnt_a++;
    end
    if (rst_n_b && !clear_b) begin
      if (res_val_b && res_rdy_b) res_q_b.push_back(res_pkt_b);
      if (evt_b) evt_cnt_b++;
    end
    if (rst_n_c && !clear_c) begin
      if (res_val_c && res_rdy_c) res_q_c.push_back(res_pkt_c);
      if (evt_c) evt_cnt_c++;
    end
  end

  // =========================================================================
  // Helper Tasks
  // =========================================================================
  task automatic init_all();
    rst_n_a = 0; clear_a = 0; iss_req_a = '0; iss_val_a = 0; reg_req_a = '0; reg_val_a = 0;
    com_req_a = '0; com_val_a = 0; res_rdy_a = 1; flgs_a = '0; flgs_a.store_fifo_empty = 1;
    z_empty_a = 1; z_full_a = 0; w_loaded_a = 0;

    rst_n_b = 0; clear_b = 0; iss_req_b = '0; iss_val_b = 0; reg_req_b = '0; reg_val_b = 0;
    com_req_b = '0; com_val_b = 0; res_rdy_b = 1; flgs_b = '0; flgs_b.store_fifo_empty = 1;
    z_empty_b = 1; z_full_b = 0; w_loaded_b = 0;

    rst_n_c = 0; clear_c = 0; iss_req_c = '0; iss_val_c = 0; reg_req_c = '0; reg_val_c = 0;
    com_req_c = '0; com_val_c = 0; res_rdy_c = 1; flgs_c = '0; flgs_c.store_fifo_empty = 1;
    z_empty_c = 1; z_full_c = 0; w_loaded_c = 0;

    res_q_a.delete(); res_q_b.delete(); res_q_c.delete();
    evt_cnt_a = 0; evt_cnt_b = 0; evt_cnt_c = 0;

    repeat (4) @(negedge clk);
    rst_n_a = 1; rst_n_b = 1; rst_n_c = 1;
    repeat (3) @(negedge clk);
  endtask

  task automatic wait_res_b(output xif_2h4_result_t r, input string tag);
    int t = 0;
    while (res_q_b.size() == 0) begin
      @(negedge clk);
      t++;
      if (t > 200) begin
        $display("FAIL [%s]: timeout waiting for x_result on DUT_B", tag);
        $fatal(1);
      end
    end
    r = res_q_b.pop_front();
  endtask

  task automatic wait_res_c(output xif_2h5_result_t r, input string tag);
    int t = 0;
    while (res_q_c.size() == 0) begin
      @(negedge clk);
      t++;
      if (t > 200) begin
        $display("FAIL [%s]: timeout waiting for x_result on DUT_C", tag);
        $fatal(1);
      end
    end
    r = res_q_c.pop_front();
  endtask

  task automatic wait_res_a(output xif_1h4_result_t r, input string tag);
    int t = 0;
    while (res_q_a.size() == 0) begin
      @(negedge clk);
      t++;
      if (t > 200) begin
        $display("FAIL [%s]: timeout waiting for x_result on DUT_A", tag);
        $fatal(1);
      end
    end
    r = res_q_a.pop_front();
  endtask

  // Execute one active job in DUT_C and verify active_config_o stability + store_fifo_empty gating
  task automatic run_one_ctrl_job_c(
    input logic [31:0] exp_x,
    input logic [31:0] exp_w,
    input logic [31:0] exp_z,
    input logic [15:0] exp_m,
    input logic [15:0] exp_n,
    input logic [15:0] exp_k,
    input gemm_op_e    exp_op,
    input gemm_fmt_e   exp_ifmt,
    input gemm_fmt_e   exp_ofmt,
    input logic [31:0] exp_yoffs,
    input string       tag
  );
    int cyc = 0;
    int pre_evt = evt_cnt_c;
    // Wait until controller enters STARTING (first_load == 1)
    while (!sched_c.first_load) begin
      @(negedge clk);
      cyc++;
      if (cyc > 100) begin
        $display("FAIL [%s]: controller never entered STARTING (busy=%0b idle=%0b)", tag, busy_c, cflags_c.idle);
        $fatal(1);
      end
    end

    // Check tiled active_config_o right at STARTING
    if (act_cfg_c.x_addr !== exp_x || act_cfg_c.w_addr !== exp_w || act_cfg_c.z_addr !== exp_z ||
        act_cfg_c.m_size !== exp_m || act_cfg_c.n_size !== exp_n || act_cfg_c.k_size !== exp_k ||
        act_cfg_c.gemm_ops !== exp_op || act_cfg_c.gemm_input_fmt !== exp_ifmt ||
        act_cfg_c.gemm_output_fmt !== exp_ofmt || act_cfg_c.y_offs !== exp_yoffs) begin
      $display("FAIL [%s]: active_config_o mismatch at STARTING: got(x=%h w=%h z=%h m=%0d n=%0d k=%0d op=%0d ifmt=%0d ofmt=%0d yoff=%h) exp(x=%h w=%h z=%h m=%0d n=%0d k=%0d op=%0d ifmt=%0d ofmt=%0d yoff=%h)",
               tag, act_cfg_c.x_addr, act_cfg_c.w_addr, act_cfg_c.z_addr,
               act_cfg_c.m_size, act_cfg_c.n_size, act_cfg_c.k_size,
               act_cfg_c.gemm_ops, act_cfg_c.gemm_input_fmt, act_cfg_c.gemm_output_fmt, act_cfg_c.y_offs,
               exp_x, exp_w, exp_z, exp_m, exp_n, exp_k, exp_op, exp_ifmt, exp_ofmt, exp_yoffs);
      $fatal(1);
    end

    // Spend 6 cycles in STARTING so any buggy ungated i_cfg_tiler would finish tiling a queued job!
    repeat (6) begin
      @(negedge clk);
      if (act_cfg_c.x_addr !== exp_x || act_cfg_c.w_addr !== exp_w || act_cfg_c.z_addr !== exp_z ||
          act_cfg_c.gemm_ops !== exp_op || cfg_comp_c !== 1'b0) begin
        $display("FAIL [%s]: queued job overwrote active_config_o or pulsed cfg_complete_o mid-STARTING! got_x=%h exp_x=%h cfg_comp=%0b",
                 tag, act_cfg_c.x_addr, exp_x, cfg_comp_c);
        $fatal(1);
      end
    end

    // Advance STARTING -> COMPUTING
    w_loaded_c = 1'b1;
    @(negedge clk);
    w_loaded_c = 1'b0;

    // Simulate Z streamer finishing stream beats BEFORE store_fifo drains!
    z_empty_c = 1'b1;
    flgs_c.z_stream_sink_flags.ready_start = 1'b1;
    flgs_c.z_stream_sink_flags.done        = 1'b1;
    flgs_c.store_fifo_empty                = 1'b0;
    repeat (4) begin
      @(negedge clk);
      if (evt_cnt_c != pre_evt || sched_c.finished) begin
        $display("FAIL [%s]: premature evt_o or FINISHED while store_fifo_empty==0! evt_cnt=%0d->%0d",
                 tag, pre_evt, evt_cnt_c);
        $fatal(1);
      end
      if (act_cfg_c.x_addr !== exp_x || act_cfg_c.z_addr !== exp_z) begin
        $display("FAIL [%s]: active_config_o corrupted during COMPUTING!", tag);
        $fatal(1);
      end
    end
    flgs_c.z_stream_sink_flags.done = 1'b0;

    // Now drain store_fifo -> controller must enter FINISHED for 1 cycle and pulse evt_o once
    flgs_c.store_fifo_empty = 1'b1;
    cyc = 0;
    while (evt_cnt_c == pre_evt) begin
      @(negedge clk);
      cyc++;
      if (cyc > 20) begin
        $display("FAIL [%s]: evt_o never pulsed after store_fifo_empty=1", tag);
        $fatal(1);
      end
    end
    flgs_c.z_stream_sink_flags.ready_start = 1'b0;
    @(negedge clk);
    if (evt_cnt_c != pre_evt + 1) begin
      $display("FAIL [%s]: evt_o pulsed %0d times instead of 1!", tag, evt_cnt_c - pre_evt);
      $fatal(1);
    end
  endtask

  // =========================================================================
  // Main Test Sequence
  // =========================================================================
  initial begin
    xif_2h4_result_t rb;
    xif_2h5_result_t rc;
    xif_1h4_result_t ra;

    void'($value$plusargs("SEED=%d", seed));
    init_all();

    // -----------------------------------------------------------------------
    // T1: Illegal Instructions (accept=0, no slot alloc, no x_result) &
    //     Operandless MOPCNT Reset Value ('1 = 4'hF) on Hart 0 & Hart 1 (DUT_B)
    // -----------------------------------------------------------------------
    begin
      // Issue illegal opcode on hart 0 with speculative x_register_valid_i=1 in same cycle
      iss_req_b.hartid = 1'b0;
      iss_req_b.id     = 4'd1;
      iss_req_b.instr  = mk_instr(2'b00, 3'b111, 5'd4, OPC); // funct3=111 illegal
      iss_val_b        = 1'b1;
      reg_req_b.hartid = 1'b0;
      reg_req_b.id     = 4'd1;
      reg_req_b.rs     = {32'hDEAD_0002, 32'hDEAD_0001, 32'hDEAD_0000};
      reg_req_b.rs_valid = 3'b111;
      reg_val_b        = 1'b1;
      #1;
      if (iss_rsp_b.accept !== 1'b0 || iss_rsp_b.writeback !== 1'b0 || iss_rsp_b.register_read !== 3'b000) begin
        $display("FAIL [T1_illegal]: illegal funct3 accepted or non-zero resp (%p)", iss_rsp_b);
        $fatal(1);
      end
      @(negedge clk);
      iss_val_b = 1'b0;
      reg_val_b = 1'b0;
      repeat (4) @(negedge clk);
      if (res_q_b.size() != 0) begin
        $display("FAIL [T1_illegal]: illegal instruction emitted x_result!");
        $fatal(1);
      end

      // Issue MOPCNT on Hart 1 (NO x_register beat sent!) with rd = x5
      iss_req_b.hartid = 1'b1;
      iss_req_b.id     = 4'd9;
      iss_req_b.instr  = mk_instr(F2_ZERO, F3_MOPCNT, 5'd5, OPC);
      iss_val_b        = 1'b1;
      com_req_b.hartid = 1'b1;
      com_req_b.id     = 4'd9;
      com_req_b.commit_kill = 1'b0;
      com_val_b        = 1'b1;
      #1;
      if (iss_rsp_b.accept !== 1'b1 || iss_rsp_b.writeback !== 1'b1 || iss_rsp_b.register_read !== 3'b000 || !iss_rdy_b) begin
        $display("FAIL [T1_mopcnt_resp]: unexpected issue_resp (%p) or rdy=%0b", iss_rsp_b, iss_rdy_b);
        $fatal(1);
      end
      @(negedge clk);
      iss_val_b = 1'b0;
      com_val_b = 1'b0;

      wait_res_b(rb, "T1_mopcnt_reset_h1");
      if (rb.hartid !== 1'b1 || rb.id !== 4'd9 || rb.rd !== 5'd5 || rb.we !== 1'b1 || rb.data !== 32'h0000_000F) begin
        $display("FAIL [T1_mopcnt_reset_h1]: got %p, expected hart=1 id=9 rd=5 we=1 data=0xF", rb);
        $fatal(1);
      end

      // MOPCNT with rd = x0 -> writeback=0, we=0
      iss_req_b.hartid = 1'b0;
      iss_req_b.id     = 4'd2;
      iss_req_b.instr  = mk_instr(F2_ZERO, F3_MOPCNT, 5'd0, OPC);
      iss_val_b        = 1'b1;
      com_req_b.hartid = 1'b0;
      com_req_b.id     = 4'd2;
      com_req_b.commit_kill = 1'b0;
      com_val_b        = 1'b1;
      #1;
      if (iss_rsp_b.writeback !== 1'b0) begin
        $display("FAIL [T1_mopcnt_x0]: writeback must be 0 when rd=x0");
        $fatal(1);
      end
      @(negedge clk);
      iss_val_b = 1'b0;
      com_val_b = 1'b0;
      wait_res_b(rb, "T1_mopcnt_x0");
      if (rb.hartid !== 1'b0 || rb.id !== 4'd2 || rb.we !== 1'b0) begin
        $display("FAIL [T1_mopcnt_x0]: got %p", rb);
        $fatal(1);
      end
    end

    // -----------------------------------------------------------------------
    // T2: Speculative Issue vs Commit/Kill (Selective Kill without Flushing
    //     Neighboring Instructions or Corrupting Prior MCNFIG!) on DUT_B
    // -----------------------------------------------------------------------
    begin
      // Step 2a: Issue & commit valid MCNFIG (id=3) on Hart 0: M=8, K=16, N=12, ADDMAX, Float8/Float16Alt
      iss_req_b = '{instr: mk_instr(F2_ZERO, F3_MCNFIG, 5'd0, OPC), hartid: 1'b0, id: 4'd3};
      iss_val_b = 1'b1;
      reg_req_b = '{hartid: 1'b0, id: 4'd3,
                    rs: {32'h0000_0180, mk_mcnfig1(16'd12, 1'b1, 1'b0, 1'b0, 1'b1, ADDMAX, Float8, Float16Alt), mk_mcnfig0(16'd8, 16'd16)},
                    rs_valid: 3'b111};
      reg_val_b = 1'b1;
      @(negedge clk);
      iss_val_b = 1'b0; reg_val_b = 1'b0;

      // Verify MCNFIG does NOT retire before x_commit arrives!
      repeat (4) @(negedge clk);
      if (res_q_b.size() != 0) begin
        $display("FAIL [T2_spec_hold]: MCNFIG retired speculatively before x_commit!");
        $fatal(1);
      end

      // Now queue 3 more instructions on Hart 0 BEFORE committing any of them:
      //   id=4: Speculative MCNFIG (BOGUS M=64, MINMAX) -> WILL BE KILLED!
      //   id=5: Speculative MARITH (BOGUS addrs)        -> WILL BE KILLED!
      //   id=6: Valid MARITH (x=0x1000, w=0x2000, z=0x3000, rd=x7) -> WILL COMMIT!
      iss_req_b = '{instr: mk_instr(F2_ZERO, F3_MCNFIG, 5'd0, OPC), hartid: 1'b0, id: 4'd4};
      iss_val_b = 1'b1;
      reg_req_b = '{hartid: 1'b0, id: 4'd4,
                    rs: {32'hDEAD_BEEF, mk_mcnfig1(16'd64, 1'b0, 1'b0, 1'b0, 1'b0, MINMAX, Float16, Float16), mk_mcnfig0(16'd64, 16'd64)},
                    rs_valid: 3'b111};
      reg_val_b = 1'b1;
      @(negedge clk);

      iss_req_b = '{instr: mk_instr(F2_ZERO, F3_MARITH, 5'd6, OPC), hartid: 1'b0, id: 4'd5};
      reg_req_b = '{hartid: 1'b0, id: 4'd5, rs: {32'hBAD0_0003, 32'hBAD0_0002, 32'hBAD0_0001}, rs_valid: 3'b111};
      @(negedge clk);

      iss_req_b = '{instr: mk_instr(F2_ZERO, F3_MARITH, 5'd7, OPC), hartid: 1'b0, id: 4'd6};
      reg_req_b = '{hartid: 1'b0, id: 4'd6, rs: {32'h1C01_3000, 32'h1C01_2000, 32'h1C01_1000}, rs_valid: 3'b111};
      @(negedge clk);
      iss_val_b = 1'b0; reg_val_b = 1'b0;

      // Kill id=4 and id=5, commit id=6, and finally commit oldest id=3!
      com_req_b = '{hartid: 1'b0, id: 4'd4, commit_kill: 1'b1}; com_val_b = 1'b1; @(negedge clk);
      com_req_b = '{hartid: 1'b0, id: 4'd5, commit_kill: 1'b1}; com_val_b = 1'b1; @(negedge clk);
      com_req_b = '{hartid: 1'b0, id: 4'd6, commit_kill: 1'b0}; com_val_b = 1'b1; @(negedge clk);
      com_req_b = '{hartid: 1'b0, id: 4'd3, commit_kill: 1'b0}; com_val_b = 1'b1; @(negedge clk);
      com_val_b = 1'b0;

      // Expect x_result ONLY for id=3 (MCNFIG, we=0) and id=6 (MARITH, we=1, op_id=0)!
      wait_res_b(rb, "T2_res_id3");
      if (rb.id !== 4'd3 || rb.we !== 1'b0) begin
        $display("FAIL [T2_res_id3]: expected id=3 we=0, got %p", rb);
        $fatal(1);
      end
      wait_res_b(rb, "T2_res_id6");
      if (rb.id !== 4'd6 || rb.rd !== 5'd7 || rb.we !== 1'b1 || rb.data !== 32'd0) begin
        $display("FAIL [T2_res_id6]: expected id=6 rd=7 we=1 op_id=0 (killed id=5 must not inc op_id!), got %p", rb);
        $fatal(1);
      end

      // Verify controller received id=6 with id=3's intact MCNFIG (M=8, N=12, K=16, ADDMAX, Float8/Float16Alt)!
      begin
        int c = 0;
        while (!sched_b.first_load) begin
          @(negedge clk); c++;
          if (c > 50) begin $display("FAIL [T2_ctrl]: DUT_B never entered STARTING"); $fatal(1); end
        end
        if (act_cfg_b.x_addr !== 32'h1C01_1000 || act_cfg_b.w_addr !== 32'h1C01_2000 || act_cfg_b.z_addr !== 32'h1C01_3000 ||
            act_cfg_b.m_size !== 16'd8 || act_cfg_b.n_size !== 16'd12 || act_cfg_b.k_size !== 16'd16 ||
            act_cfg_b.gemm_ops !== ADDMAX || act_cfg_b.gemm_input_fmt !== Float8 ||
            act_cfg_b.gemm_output_fmt !== Float16Alt || act_cfg_b.y_offs !== 32'h0000_0180 ||
            act_cfg_b.receive_x !== 1'b1 || act_cfg_b.send_w !== 1'b1) begin
          $display("FAIL [T2_cfg]: killed MCNFIG corrupted config or MARITH clobbered formats! got %p", act_cfg_b);
          $fatal(1);
        end
        // Finish job on DUT_B
        w_loaded_b = 1'b1; @(negedge clk); w_loaded_b = 1'b0;
        flgs_b.z_stream_sink_flags.ready_start = 1'b1; flgs_b.store_fifo_empty = 1'b1;
        while (evt_cnt_b == 0) @(negedge clk);
        flgs_b.z_stream_sink_flags.ready_start = 1'b0;
        @(negedge clk);
      end
    end

    // -----------------------------------------------------------------------
    // T3 & T5: Split/Out-of-Order Partial rs_valid Assembly (XifIssueRegisterSplit=1),
    //          Backpressure Stability (x_result_ready_i=0), 3 Queued Jobs Isolation,
    //          and Post-Store-Drain evt_o / MOPCNT Verification on DUT_C!
    // -----------------------------------------------------------------------
    begin
      // Issue 3 instructions on Hart 0 and 2 instructions on Hart 1 WITHOUT operands yet:
      //   H0 id=10: MCNFIG (M=12, K=24, N=16, MULMIN, Float8Alt, Float16, y_offs=0x400)
      //   H0 id=11: MARITH Job0 (x=0x10000, w=0x20000, z=0x30000, rd=x1)
      //   H1 id=20: MCNFIG (M=4,  K=8,  N=8,  MAXMIN, Float16Alt, Float8, y_offs=0x200)
      //   H1 id=21: MARITH Job1 (x=0x40000, w=0x50000, z=0x60000, rd=x2)
      //   H0 id=12: MARITH Job2 (x=0x70000, w=0x80000, z=0x90000, rd=x3)
      iss_val_c = 1'b1;
      iss_req_c = '{instr: mk_instr(F2_ZERO, F3_MCNFIG, 5'd0, OPC), hartid: 1'b0, id: 5'd10}; @(negedge clk);
      iss_req_c = '{instr: mk_instr(F2_ZERO, F3_MARITH, 5'd1, OPC), hartid: 1'b0, id: 5'd11}; @(negedge clk);
      iss_req_c = '{instr: mk_instr(F2_ZERO, F3_MCNFIG, 5'd0, OPC), hartid: 1'b1, id: 5'd20}; @(negedge clk);
      iss_req_c = '{instr: mk_instr(F2_ZERO, F3_MARITH, 5'd2, OPC), hartid: 1'b1, id: 5'd21}; @(negedge clk);
      iss_req_c = '{instr: mk_instr(F2_ZERO, F3_MARITH, 5'd3, OPC), hartid: 1'b0, id: 5'd12}; @(negedge clk);
      iss_val_c = 1'b0;

      // Commit all 5 out of order
      com_val_c = 1'b1;
      com_req_c = '{hartid: 1'b0, id: 5'd12, commit_kill: 1'b0}; @(negedge clk);
      com_req_c = '{hartid: 1'b1, id: 5'd21, commit_kill: 1'b0}; @(negedge clk);
      com_req_c = '{hartid: 1'b0, id: 5'd11, commit_kill: 1'b0}; @(negedge clk);
      com_req_c = '{hartid: 1'b1, id: 5'd20, commit_kill: 1'b0}; @(negedge clk);
      com_req_c = '{hartid: 1'b0, id: 5'd10, commit_kill: 1'b0}; @(negedge clk);
      com_val_c = 1'b0;

      // Stall x_result_ready_i = 0 while delivering out-of-order partial rs_valid beats!
      res_rdy_c = 1'b0;
      reg_val_c = 1'b1;
      // Deliver H0 id=12 first (youngest on H0!) in 2 partial beats (101 then 010)
      reg_req_c = '{hartid: 1'b0, id: 5'd12, rs: {32'h0009_0000, 32'hDEAD_BEEF, 32'h0007_0000}, rs_valid: 3'b101}; @(negedge clk);
      reg_req_c = '{hartid: 1'b0, id: 5'd12, rs: {32'hDEAD_BEEF, 32'h0008_0000, 32'hDEAD_BEEF}, rs_valid: 3'b010}; @(negedge clk);
      // Deliver H0 id=11 in 3 single-operand beats (010, 001, 100)
      reg_req_c = '{hartid: 1'b0, id: 5'd11, rs: {32'd0, 32'h0002_0000, 32'd0}, rs_valid: 3'b010}; @(negedge clk);
      reg_req_c = '{hartid: 1'b0, id: 5'd11, rs: {32'd0, 32'd0, 32'h0001_0000}, rs_valid: 3'b001}; @(negedge clk);
      reg_req_c = '{hartid: 1'b0, id: 5'd11, rs: {32'h0003_0000, 32'd0, 32'd0}, rs_valid: 3'b100}; @(negedge clk);
      // Deliver H1 id=21 before H1 id=20
      reg_req_c = '{hartid: 1'b1, id: 5'd21, rs: {32'h0006_0000, 32'h0005_0000, 32'h0004_0000}, rs_valid: 3'b111}; @(negedge clk);
      // Deliver H0 id=10 (MCNFIG) in 2 beats (011 then 100)
      reg_req_c = '{hartid: 1'b0, id: 5'd10,
                    rs: {32'hBAD0_BAD0, mk_mcnfig1(16'd16, 1'b0, 1'b1, 1'b1, 1'b0, MULMIN, Float8Alt, Float16), mk_mcnfig0(16'd12, 16'd24)},
                    rs_valid: 3'b011}; @(negedge clk);
      reg_req_c = '{hartid: 1'b0, id: 5'd10, rs: {32'h0000_0400, 32'hBAD1_BAD1, 32'hBAD2_BAD2}, rs_valid: 3'b100}; @(negedge clk);
      // Deliver H1 id=20 (MCNFIG)
      reg_req_c = '{hartid: 1'b1, id: 5'd20,
                    rs: {32'h0000_0200, mk_mcnfig1(16'd8, 1'b0, 1'b0, 1'b0, 1'b0, MAXMIN, Float16Alt, Float8), mk_mcnfig0(16'd4, 16'd8)},
                    rs_valid: 3'b111}; @(negedge clk);
      reg_val_c = 1'b0;

      // Hold x_result_ready_i = 0 for 5 more cycles to verify stability & no duplicate config pushes!
      repeat (5) @(negedge clk);
      res_rdy_c = 1'b1;

      // Collect all 5 x_result packets; verify per-hart op_id tags:
      //   H0 id=10 -> we=0
      //   H0 id=11 -> we=1, data=0
      //   H0 id=12 -> we=1, data=1
      //   H1 id=20 -> we=0
      //   H1 id=21 -> we=1, data=0
      begin
        int seen_mask = 0;
        for (int k = 0; k < 5; k++) begin
          wait_res_c(rc, "T3_split_5res");
          if (rc.hartid == 1'b0 && rc.id == 5'd10 && rc.we == 1'b0) seen_mask |= 1;
          else if (rc.hartid == 1'b0 && rc.id == 5'd11 && rc.we == 1'b1 && rc.data == 32'd0) seen_mask |= 2;
          else if (rc.hartid == 1'b0 && rc.id == 5'd12 && rc.we == 1'b1 && rc.data == 32'd1) seen_mask |= 4;
          else if (rc.hartid == 1'b1 && rc.id == 5'd20 && rc.we == 1'b0) seen_mask |= 8;
          else if (rc.hartid == 1'b1 && rc.id == 5'd21 && rc.we == 1'b1 && rc.data == 32'd0) seen_mask |= 16;
          else begin
            $display("FAIL [T3_split_5res]: unexpected result packet %p", rc);
            $fatal(1);
          end
        end
        if (seen_mask != 31) begin
          $display("FAIL [T3_split_5res]: missing expected results, seen_mask=0x%x", seen_mask);
          $fatal(1);
        end
      end

      // Now all 3 MARITH jobs are in flight simultaneously (1 active in redmule_ctrl + 2 queued in i_config_fifo)!
      // Determine round-robin order in which MARITHs entered i_config_fifo:
      // Cycle after H0 id=10 retired (winner=0 -> rr=1): H1 id=20 retired (winner=1 -> rr=0) ->
      // H0 id=11 retired (JobA: H0 Job0, winner=0 -> rr=1) -> H1 id=21 retired (JobB: H1 Job1, winner=1 -> rr=0) ->
      // H0 id=12 retired (JobC: H0 Job2)!
      run_one_ctrl_job_c(32'h0001_0000, 32'h0002_0000, 32'h0003_0000,
                         16'd12, 16'd16, 16'd24, MULMIN, Float8Alt, Float16, 32'h0000_0400, "T5_queued_jobA_H0");
      run_one_ctrl_job_c(32'h0004_0000, 32'h0005_0000, 32'h0006_0000,
                         16'd4,  16'd8,  16'd8,  MAXMIN, Float16Alt, Float8, 32'h0000_0200, "T5_queued_jobB_H1");
      run_one_ctrl_job_c(32'h0007_0000, 32'h0008_0000, 32'h0009_0000,
                         16'd12, 16'd16, 16'd24, MULMIN, Float8Alt, Float16, 32'h0000_0400, "T5_queued_jobC_H0");

      // Check MOPCNT on both harts: H0 completed 2 ops (wrap: F -> 0 -> 1), H1 completed 1 op (F -> 0)!
      iss_val_c = 1'b1; com_val_c = 1'b1;
      iss_req_c = '{instr: mk_instr(F2_ZERO, F3_MOPCNT, 5'd10, OPC), hartid: 1'b0, id: 5'd13};
      com_req_c = '{hartid: 1'b0, id: 5'd13, commit_kill: 1'b0};
      @(negedge clk);
      iss_req_c = '{instr: mk_instr(F2_ZERO, F3_MOPCNT, 5'd11, OPC), hartid: 1'b1, id: 5'd22};
      com_req_c = '{hartid: 1'b1, id: 5'd22, commit_kill: 1'b0};
      @(negedge clk);
      iss_val_c = 1'b0; com_val_c = 1'b0;

      for (int k = 0; k < 2; k++) begin
        wait_res_c(rc, "T5_mopcnt_post3");
        if (rc.hartid == 1'b0 && rc.data !== 32'd1) begin
          $display("FAIL [T5_mopcnt_h0]: expected 1, got %0d", rc.data);
          $fatal(1);
        end
        if (rc.hartid == 1'b1 && rc.data !== 32'd0) begin
          $display("FAIL [T5_mopcnt_h1]: expected 0, got %0d", rc.data);
          $fatal(1);
        end
      end
    end

    // -----------------------------------------------------------------------
    // T6: Multi-Hart MOPCNT Spin-Loop Fairness (Hart 0 floods MOPCNT while
    //     Hart 1 issues MCNFIG + MOPCNT) on DUT_B
    // -----------------------------------------------------------------------
    begin
      int h1_retired = 0;
      // Pre-fill Hart 0 with 4 MOPCNTs and Hart 1 with 2 MOPCNTs
      for (int k = 0; k < 4; k++) begin
        iss_val_b = 1'b1; com_val_b = 1'b1;
        iss_req_b = '{instr: mk_instr(F2_ZERO, F3_MOPCNT, 5'd8, OPC), hartid: 1'b0, id: 4'(k)};
        com_req_b = '{hartid: 1'b0, id: 4'(k), commit_kill: 1'b0};
        @(negedge clk);
      end
      for (int k = 0; k < 2; k++) begin
        iss_val_b = 1'b1; com_val_b = 1'b1;
        iss_req_b = '{instr: mk_instr(F2_ZERO, F3_MOPCNT, 5'd9, OPC), hartid: 1'b1, id: 4'(8 + k)};
        com_req_b = '{hartid: 1'b1, id: 4'(8 + k), commit_kill: 1'b0};
        @(negedge clk);
      end
      iss_val_b = 1'b0; com_val_b = 1'b0;

      // Keep pushing MOPCNTs on Hart 0 every cycle for 8 cycles; Hart 1 MUST NOT be starved!
      for (int k = 0; k < 8; k++) begin
        iss_val_b = 1'b1;
        iss_req_b = '{instr: mk_instr(F2_ZERO, F3_MOPCNT, 5'd8, OPC), hartid: 1'b0, id: 4'((4 + k) & 7)};
        com_val_b = iss_rdy_b;
        com_req_b = '{hartid: 1'b0, id: 4'((4 + k) & 7), commit_kill: 1'b0};
        @(negedge clk);
      end
      iss_val_b = 1'b0; com_val_b = 1'b0;
      repeat (12) @(negedge clk);

      while (res_q_b.size() > 0) begin
        rb = res_q_b.pop_front();
        if (rb.hartid == 1'b1) h1_retired++;
      end
      if (h1_retired != 2) begin
        $display("FAIL [T6_rr_fairness]: Hart 1 starved under Hart 0 MOPCNT polling! h1_retired=%0d/2", h1_retired);
        $fatal(1);
      end
    end

    // -----------------------------------------------------------------------
    // T7: Deep In-Flight Pipeline Occupancy & OpId Wrap-Around on DUT_A
    //     (XifNumHarts=1, InstFifoDepth=2, OpIdWidth=3 -> 5 simultaneous MARITHs
    //      in flight without hartid_fifo overflow + wrap 0..7 -> 0 + clear_i!)
    // -----------------------------------------------------------------------
    begin
      // Configure MCNFIG on DUT_A
      iss_val_a = 1'b1; reg_val_a = 1'b1; com_val_a = 1'b1;
      iss_req_a = '{instr: mk_instr(F2_ZERO, F3_MCNFIG, 5'd0, OPC), hartid: 1'b0, id: 4'd0};
      reg_req_a = '{hartid: 1'b0, id: 4'd0,
                    rs: {32'd0, mk_mcnfig1(16'd8, 1'b0, 1'b0, 1'b0, 1'b0, GEMM, Float16, Float16), mk_mcnfig0(16'd8, 16'd8)},
                    rs_valid: 3'b111};
      com_req_a = '{hartid: 1'b0, id: 4'd0, commit_kill: 1'b0};
      @(negedge clk);
      iss_val_a = 1'b0; reg_val_a = 1'b0; com_val_a = 1'b0;
      wait_res_a(ra, "T7_mcnfig_a");

      // Issue 9 MARITHs total: first queue 5 before completing any (1 in ctrl + 2 in config_fifo + 2 in inst_decoder)!
      for (int j = 0; j < 5; j++) begin
        int guard = 0;
        iss_val_a = 1'b1; reg_val_a = 1'b1;
        iss_req_a = '{instr: mk_instr(F2_ZERO, F3_MARITH, 5'd3, OPC), hartid: 1'b0, id: 4'(j + 1)};
        reg_req_a = '{hartid: 1'b0, id: 4'(j + 1), rs: {32'h3000 + j*16, 32'h2000 + j*16, 32'h1000 + j*16}, rs_valid: 3'b111};
        #1;
        while (!iss_rdy_a || !reg_rdy_a) begin
          @(negedge clk); #1;
          guard++;
          if (guard > 60) begin $display("FAIL [T7_queue5]: stall at j=%0d", j); $fatal(1); end
        end
        com_val_a = 1'b1;
        com_req_a = '{hartid: 1'b0, id: 4'(j + 1), commit_kill: 1'b0};
        @(negedge clk);
        iss_val_a = 1'b0; reg_val_a = 1'b0; com_val_a = 1'b0;
        repeat (4) @(negedge clk);
      end

      // Now complete all 5 and issue 4 more (total 9 -> OpIdWidth=3 wraps 0..7, 0!)
      for (int j = 0; j < 9; j++) begin
        int c = 0;
        if (j >= 5) begin
          iss_val_a = 1'b1; reg_val_a = 1'b1; com_val_a = 1'b1;
          iss_req_a = '{instr: mk_instr(F2_ZERO, F3_MARITH, 5'd3, OPC), hartid: 1'b0, id: 4'((j + 1) & 15)};
          reg_req_a = '{hartid: 1'b0, id: 4'((j + 1) & 15), rs: {32'h3000 + j*16, 32'h2000 + j*16, 32'h1000 + j*16}, rs_valid: 3'b111};
          com_req_a = '{hartid: 1'b0, id: 4'((j + 1) & 15), commit_kill: 1'b0};
          @(negedge clk);
          iss_val_a = 1'b0; reg_val_a = 1'b0; com_val_a = 1'b0;
        end
        wait_res_a(ra, $sformatf("T7_marith_res_%0d", j));
        if (ra.data !== 32'(j & 7)) begin
          $display("FAIL [T7_opid_in]: job %0d expected op_id_in=%0d, got %0d", j, j & 7, ra.data);
          $fatal(1);
        end
        while (!sched_a.first_load) begin
          @(negedge clk); c++;
          if (c > 80) begin $display("FAIL [T7_ctrl]: job %0d never started", j); $fatal(1); end
        end
        w_loaded_a = 1'b1; @(negedge clk); w_loaded_a = 1'b0;
        flgs_a.z_stream_sink_flags.ready_start = 1'b1; flgs_a.store_fifo_empty = 1'b1;
        while (evt_cnt_a <= j) @(negedge clk);
        flgs_a.z_stream_sink_flags.ready_start = 1'b0;
        @(negedge clk);
      end

      // Verify MOPCNT after 9 completed ops with OpIdWidth=3: ('1 = 7) + 9 = 16 -> 0 (mod 8)!
      iss_val_a = 1'b1; com_val_a = 1'b1;
      iss_req_a = '{instr: mk_instr(F2_ZERO, F3_MOPCNT, 5'd4, OPC), hartid: 1'b0, id: 4'd14};
      com_req_a = '{hartid: 1'b0, id: 4'd14, commit_kill: 1'b0};
      @(negedge clk);
      iss_val_a = 1'b0; com_val_a = 1'b0;
      wait_res_a(ra, "T7_mopcnt_wrap9");
      if (ra.data !== 32'd0) begin
        $display("FAIL [T7_mopcnt_wrap9]: after 9 ops (OpIdWidth=3), expected 0, got %0d", ra.data);
        $fatal(1);
      end

      // Test mid-flight clear_i recovery on DUT_C
      iss_val_c = 1'b1;
      iss_req_c = '{instr: mk_instr(F2_ZERO, F3_MARITH, 5'd2, OPC), hartid: 1'b0, id: 5'd30};
      @(negedge clk);
      iss_val_c = 1'b0;
      clear_c   = 1'b1;
      @(negedge clk);
      clear_c   = 1'b0;
      res_q_c.delete();
      repeat (3) @(negedge clk);

      // Post-clear MOPCNT on H0 must read '1 (4'hF)
      iss_val_c = 1'b1; com_val_c = 1'b1;
      iss_req_c = '{instr: mk_instr(F2_ZERO, F3_MOPCNT, 5'd2, OPC), hartid: 1'b0, id: 5'd1};
      com_req_c = '{hartid: 1'b0, id: 5'd1, commit_kill: 1'b0};
      @(negedge clk);
      iss_val_c = 1'b0; com_val_c = 1'b0;
      wait_res_c(rc, "T7_post_clear_mopcnt");
      if (rc.data !== 32'h0000_000F) begin
        $display("FAIL [T7_post_clear]: expected 0xF after clear_i, got 0x%h", rc.data);
        $fatal(1);
      end
    end

    // -----------------------------------------------------------------------
    // T8: Seeded Randomized Multi-Hart Speculative / Split-Beat Stress on DUT_C
    // -----------------------------------------------------------------------
    begin
      int unsigned rng;
      int exp_in_cnt[2];
      int exp_done_cnt[2];
      rng = seed * 32'h9E37_79B9 + 32'h1234_5678;
      exp_in_cnt[0] = 0; exp_in_cnt[1] = 0;
      exp_done_cnt[0] = 15; exp_done_cnt[1] = 15;

      // Program distinct MCNFIGs per hart
      for (int h = 0; h < 2; h++) begin
        iss_val_c = 1'b1; reg_val_c = 1'b1; com_val_c = 1'b1;
        iss_req_c = '{instr: mk_instr(F2_ZERO, F3_MCNFIG, 5'd0, OPC), hartid: 1'(h), id: 5'(2 + h)};
        reg_req_c = '{hartid: 1'(h), id: 5'(2 + h),
                      rs: {32'(h * 32'h100),
                           mk_mcnfig1(16'(8 + 4*h), 1'b0, 1'b0, 1'b0, 1'b0, gemm_op_e'(h ? MINMAX : ADDMIN), Float16, Float16Alt),
                           mk_mcnfig0(16'(8 + 4*h), 16'd16)},
                      rs_valid: 3'b111};
        com_req_c = '{hartid: 1'(h), id: 5'(2 + h), commit_kill: 1'b0};
        @(negedge clk);
      end
      iss_val_c = 1'b0; reg_val_c = 1'b0; com_val_c = 1'b0;
      wait_res_c(rc, "T8_cfg0");
      wait_res_c(rc, "T8_cfg1");

      for (int iter = 0; iter < 12; iter++) begin
        logic h;
        logic kill_it;
        logic [4:0] id_v;
        logic [31:0] xa, wa, za;
        rng = rng * 32'd1664525 + 32'd1013904223;
        h       = rng[0];
        kill_it = (rng[3:1] == 3'b011); // ~12.5% killed
        id_v    = 5'(4 + (iter & 15));
        xa      = 32'h2000_0000 + iter * 32'h100;
        wa      = 32'h3000_0000 + iter * 32'h100;
        za      = 32'h4000_0000 + iter * 32'h100;

        // Issue MARITH
        iss_val_c = 1'b1;
        iss_req_c = '{instr: mk_instr(F2_ZERO, F3_MARITH, 5'd12, OPC), hartid: h, id: id_v};
        @(negedge clk);
        iss_val_c = 1'b0;

        // Randomly stall x_result_ready_i for 1..3 cycles
        res_rdy_c = rng[4];

        // Send operands in 2 split beats in randomized order
        reg_val_c = 1'b1;
        if (rng[5]) begin
          reg_req_c = '{hartid: h, id: id_v, rs: {za, 32'hXXXX_XXXX, xa}, rs_valid: 3'b101}; @(negedge clk);
          reg_req_c = '{hartid: h, id: id_v, rs: {32'd0, wa, 32'd0}, rs_valid: 3'b010}; @(negedge clk);
        end else begin
          reg_req_c = '{hartid: h, id: id_v, rs: {za, wa, 32'd0}, rs_valid: 3'b110}; @(negedge clk);
          reg_req_c = '{hartid: h, id: id_v, rs: {32'd0, 32'd0, xa}, rs_valid: 3'b001}; @(negedge clk);
        end
        reg_val_c = 1'b0;

        // Send commit or kill
        com_val_c = 1'b1;
        com_req_c = '{hartid: h, id: id_v, commit_kill: kill_it};
        @(negedge clk);
        com_val_c = 1'b0;
        res_rdy_c = 1'b1;

        if (kill_it) begin
          repeat (5) @(negedge clk);
          if (res_q_c.size() != 0 || busy_c) begin
            $display("FAIL [T8_rand_kill]: iter=%0d killed MARITH produced result or started controller!", iter);
            $fatal(1);
          end
        end else begin
          wait_res_c(rc, $sformatf("T8_rand_res_%0d", iter));
          if (rc.hartid !== h || rc.id !== id_v || rc.data !== 32'(exp_in_cnt[h] & 15)) begin
            $display("FAIL [T8_rand_res]: iter=%0d got %p exp op_id=%0d", iter, rc, exp_in_cnt[h] & 15);
            $fatal(1);
          end
          exp_in_cnt[h]++;
          run_one_ctrl_job_c(xa, wa, za, 16'(8 + 4*h), 16'(8 + 4*h), 16'd16,
                             gemm_op_e'(h ? MINMAX : ADDMIN), Float16, Float16Alt, 32'(h * 32'h100),
                             $sformatf("T8_rand_ctrl_%0d", iter));
          exp_done_cnt[h] = (exp_done_cnt[h] + 1) & 15;
        end
      end

      // Final MOPCNT check on both harts
      for (int h = 0; h < 2; h++) begin
        iss_val_c = 1'b1; com_val_c = 1'b1;
        iss_req_c = '{instr: mk_instr(F2_ZERO, F3_MOPCNT, 5'd15, OPC), hartid: 1'(h), id: 5'(25 + h)};
        com_req_c = '{hartid: 1'(h), id: 5'(25 + h), commit_kill: 1'b0};
        @(negedge clk);
        iss_val_c = 1'b0; com_val_c = 1'b0;
        wait_res_c(rc, $sformatf("T8_final_mopcnt_h%0d", h));
        if (rc.data !== 32'(exp_done_cnt[h])) begin
          $display("FAIL [T8_final_mopcnt_h%0d]: got %0d exp %0d", h, rc.data, exp_done_cnt[h]);
          $fatal(1);
        end
      end
    end

    $display("PASS: All RedMulE CORE-V-XIF & Controller tests passed (seed=%0d)", seed);
    $finish;
  end

  initial begin
    repeat (30000) @(posedge clk);
    $display("FAIL: Global simulation watchdog timeout (deadlock detected)!");
    $fatal(1);
  end

endmodule
