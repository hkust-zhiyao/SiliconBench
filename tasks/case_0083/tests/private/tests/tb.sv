`timescale 1ns/1ps

module tb;
  parameter int SEED = 101;

  logic         clk_i = 1'b0;
  logic         rst_ni = 1'b0;
  always #5 clk_i = ~clk_i;

  logic         req_valid_i;
  logic         req_ready_o;
  logic [23:0]  req_length_i;
  logic [23:0]  req_src_addr_i;
  logic [23:0]  req_dst_addr_i;
  logic [23:0]  req_scale_addr_i;
  logic [1:0]   req_axi_id_i;
  logic         req_decouple_aw_i;
  logic         req_decouple_rw_i;
  logic [2:0]   req_src_max_llen_i;
  logic [2:0]   req_dst_max_llen_i;
  logic         req_src_reduce_len_i;
  logic         req_dst_reduce_len_i;
  logic [1:0][11:0] req_reps_i;
  logic [1:0][23:0] req_src_strides_i;
  logic [1:0][23:0] req_dst_strides_i;
  logic [1:0][23:0] req_scale_strides_i;

  logic         rsp_valid_o;
  logic         rsp_ready_i;
  axi_pkg::resp_t rsp_cause_o;
  idma_pkg::err_type_t rsp_err_type_o;
  logic [23:0]  rsp_burst_addr_o;
  logic         rsp_error_o;
  logic         rsp_last_o;

  logic         burst_rsp_valid_i;
  logic         burst_rsp_ready_o;
  axi_pkg::resp_t burst_rsp_cause_i;
  idma_pkg::err_type_t burst_rsp_err_type_i;
  logic [23:0]  burst_rsp_burst_addr_i;
  logic         burst_rsp_error_i;
  logic         burst_rsp_last_i;

  logic         r_valid_o;
  logic         r_ready_i;
  logic [23:0]  r_ar_addr_o;
  axi_pkg::len_t r_ar_len_o;
  axi_pkg::size_t r_ar_size_o;
  logic [1:0]   r_ar_id_o;
  logic [1:0]   r_dp_offset_o;
  logic [1:0]   r_dp_tailer_o;
  logic [1:0]   r_dp_shift_o;
  logic         r_dp_decouple_aw_o;
  logic         r_dp_is_single_o;

  logic         w_valid_o;
  logic         w_ready_i;
  logic [23:0]  w_aw_addr_o;
  axi_pkg::len_t w_aw_len_o;
  axi_pkg::size_t w_aw_size_o;
  logic [1:0]   w_aw_id_o;
  logic [1:0]   w_dp_offset_o;
  logic [1:0]   w_dp_tailer_o;
  logic [1:0]   w_dp_shift_o;
  axi_pkg::len_t w_dp_num_beats_o;
  logic         w_dp_is_single_o;
  logic         w_last_o;
  logic         w_super_last_o;
  logic         w_decouple_aw_o;

  logic         flush_i;
  logic         kill_i;
  logic         nd_busy_o;
  logic         r_busy_o;
  logic         w_busy_o;
  logic [23:0]  burst_scale_addr_o;

  idma_nd_legalizer_top dut (
    .clk_i                 (clk_i                 ),
    .rst_ni                (rst_ni                ),
    .req_valid_i           (req_valid_i           ),
    .req_ready_o           (req_ready_o           ),
    .req_length_i          (req_length_i          ),
    .req_src_addr_i        (req_src_addr_i        ),
    .req_dst_addr_i        (req_dst_addr_i        ),
    .req_scale_addr_i      (req_scale_addr_i      ),
    .req_axi_id_i          (req_axi_id_i          ),
    .req_decouple_aw_i     (req_decouple_aw_i     ),
    .req_decouple_rw_i     (req_decouple_rw_i     ),
    .req_src_max_llen_i    (req_src_max_llen_i    ),
    .req_dst_max_llen_i    (req_dst_max_llen_i    ),
    .req_src_reduce_len_i  (req_src_reduce_len_i  ),
    .req_dst_reduce_len_i  (req_dst_reduce_len_i  ),
    .req_reps_i            (req_reps_i            ),
    .req_src_strides_i     (req_src_strides_i     ),
    .req_dst_strides_i     (req_dst_strides_i     ),
    .req_scale_strides_i   (req_scale_strides_i   ),
    .rsp_valid_o           (rsp_valid_o           ),
    .rsp_ready_i           (rsp_ready_i           ),
    .rsp_cause_o           (rsp_cause_o           ),
    .rsp_err_type_o        (rsp_err_type_o        ),
    .rsp_burst_addr_o      (rsp_burst_addr_o      ),
    .rsp_error_o           (rsp_error_o           ),
    .rsp_last_o            (rsp_last_o            ),
    .burst_rsp_valid_i     (burst_rsp_valid_i     ),
    .burst_rsp_ready_o     (burst_rsp_ready_o     ),
    .burst_rsp_cause_i     (burst_rsp_cause_i     ),
    .burst_rsp_err_type_i  (burst_rsp_err_type_i  ),
    .burst_rsp_burst_addr_i(burst_rsp_burst_addr_i),
    .burst_rsp_error_i     (burst_rsp_error_i     ),
    .burst_rsp_last_i      (burst_rsp_last_i      ),
    .r_valid_o             (r_valid_o             ),
    .r_ready_i             (r_ready_i             ),
    .r_ar_addr_o           (r_ar_addr_o           ),
    .r_ar_len_o            (r_ar_len_o            ),
    .r_ar_size_o           (r_ar_size_o           ),
    .r_ar_id_o             (r_ar_id_o             ),
    .r_dp_offset_o         (r_dp_offset_o         ),
    .r_dp_tailer_o         (r_dp_tailer_o         ),
    .r_dp_shift_o          (r_dp_shift_o          ),
    .r_dp_decouple_aw_o    (r_dp_decouple_aw_o    ),
    .r_dp_is_single_o      (r_dp_is_single_o      ),
    .w_valid_o             (w_valid_o             ),
    .w_ready_i             (w_ready_i             ),
    .w_aw_addr_o           (w_aw_addr_o           ),
    .w_aw_len_o            (w_aw_len_o            ),
    .w_aw_size_o           (w_aw_size_o           ),
    .w_aw_id_o             (w_aw_id_o             ),
    .w_dp_offset_o         (w_dp_offset_o         ),
    .w_dp_tailer_o         (w_dp_tailer_o         ),
    .w_dp_shift_o          (w_dp_shift_o          ),
    .w_dp_num_beats_o      (w_dp_num_beats_o      ),
    .w_dp_is_single_o      (w_dp_is_single_o      ),
    .w_last_o              (w_last_o              ),
    .w_super_last_o        (w_super_last_o        ),
    .w_decouple_aw_o       (w_decouple_aw_o       ),
    .flush_i               (flush_i               ),
    .kill_i                (kill_i                ),
    .nd_busy_o             (nd_busy_o             ),
    .r_busy_o              (r_busy_o              ),
    .w_busy_o              (w_busy_o              ),
    .burst_scale_addr_o    (burst_scale_addr_o    )
  );

  initial begin
    req_valid_i            = 1'b0;
    req_length_i           = '0;
    req_src_addr_i         = '0;
    req_dst_addr_i         = '0;
    req_scale_addr_i       = '0;
    req_axi_id_i           = 2'd1;
    req_decouple_aw_i      = 1'b0;
    req_decouple_rw_i      = 1'b0;
    req_src_max_llen_i     = 3'd0;
    req_dst_max_llen_i     = 3'd0;
    req_src_reduce_len_i   = 1'b0;
    req_dst_reduce_len_i   = 1'b0;
    req_reps_i             = '0;
    req_src_strides_i      = '0;
    req_dst_strides_i      = '0;
    req_scale_strides_i    = '0;
    rsp_ready_i            = 1'b0;
    burst_rsp_valid_i      = 1'b0;
    burst_rsp_cause_i      = axi_pkg::RESP_OKAY;
    burst_rsp_err_type_i   = idma_pkg::BUS_READ;
    burst_rsp_burst_addr_i = '0;
    burst_rsp_error_i      = 1'b0;
    burst_rsp_last_i       = 1'b0;
    r_ready_i              = 1'b1;
    w_ready_i              = 1'b1;
    flush_i                = 1'b0;
    kill_i                 = 1'b0;

    rst_ni = 1'b0;
    repeat (4) @(negedge clk_i);
    rst_ni = 1'b1;
    @(negedge clk_i);

    // ----------------------------------------------------------------------
    // 1. Zero-repetition ND transfer check (req_reps_i == '0):
    //    - Must NOT issue burst_req to legalizer (r_valid_o == 0, w_valid_o == 0, r_busy_o == 0)
    //    - Must assert rsp_valid_o == 1, rsp_error_o == 1, rsp_err_type_o == ND_MIDEND
    //    - Must block burst_rsp_ready_o == 0
    //    - Must only assert req_ready_o when rsp_ready_i == 1
    // ----------------------------------------------------------------------
    req_valid_i      = 1'b1;
    req_length_i     = 24'd64;
    req_src_addr_i   = 24'h001000;
    req_dst_addr_i   = 24'h002000;
    req_scale_addr_i = 24'h003000;
    req_reps_i[0]    = 12'd0;
    req_reps_i[1]    = 12'd0;
    rsp_ready_i      = 1'b0;
    #1;
    if (!rsp_valid_o || !rsp_error_o || rsp_err_type_o !== idma_pkg::ND_MIDEND ||
        burst_rsp_ready_o !== 1'b0 || req_ready_o !== 1'b0) begin
      $fatal(1, "Zero-repetition ND request did not properly assert ND_MIDEND error or block req_ready_o while rsp_ready_i=0");
    end
    @(posedge clk_i);
    #1;
    if (r_busy_o || w_busy_o || r_valid_o || w_valid_o)
      $fatal(1, "Zero-repetition ND request leaked into legalizer!");
    @(negedge clk_i);
    rsp_ready_i = 1'b1;
    #1;
    if (req_ready_o !== 1'b1)
      $fatal(1, "Zero-repetition ND request did not assert req_ready_o when rsp_ready_i=1");
    @(posedge clk_i);
    @(negedge clk_i);
    req_valid_i = 1'b0;
    rsp_ready_i = 1'b0;

    // ----------------------------------------------------------------------
    // 2. Coupled 3D Transfer with Page-Boundary Splitting & Asymmetric Stalls:
    //    reps[0] = 2, reps[1] = 2 (4 1D bursts total).
    //    Each 1D burst has length = 48 bytes, src_addr near a 32-byte reduced
    //    page boundary (src_reduce_len=1, src_max_llen=3 -> page=32B, offset=16 -> 16B to pb),
    //    dst_addr near a 64-byte reduced page boundary (dst_reduce_len=1, dst_max_llen=4 -> page=64B, offset=40 -> 24B to pb).
    //    In coupled mode (!req_decouple_rw_i), the first split MUST be min(16, 24) = 16B,
    //    the second split MUST be min(32, 8) = 8B, and the third split MUST be min(24, 64) >= 24B -> 24B (done)!
    // ----------------------------------------------------------------------
    req_length_i         = 24'd48;
    req_src_addr_i       = 24'h001010; // offset 16 in 32B page -> 16B to pb
    req_dst_addr_i       = 24'h002028; // offset 40 in 64B page -> 24B to pb
    req_scale_addr_i     = 24'h004000;
    req_decouple_rw_i    = 1'b0;       // coupled mode
    req_src_reduce_len_i = 1'b1;
    req_src_max_llen_i   = 3'd3;       // page_addr_width = 2 + 3 = 5 -> 32B page
    req_dst_reduce_len_i = 1'b1;
    req_dst_max_llen_i   = 3'd4;       // page_addr_width = 2 + 4 = 6 -> 64B page
    req_reps_i[0]        = 12'd2;
    req_reps_i[1]        = 12'd2;
    req_src_strides_i[0] = 24'h000100;
    req_src_strides_i[1] = 24'h001000;
    req_dst_strides_i[0] = 24'h000200;
    req_dst_strides_i[1] = 24'h002000;
    req_scale_strides_i[0] = 24'h000040;
    req_scale_strides_i[1] = 24'h000400;
    req_valid_i          = 1'b1;
    r_ready_i            = 1'b1;
    w_ready_i            = 1'b1;

    for (int b1 = 0; b1 < 2; b1++) begin
      for (int b0 = 0; b0 < 2; b0++) begin
        logic [23:0] exp_s, exp_d, exp_sc;
        logic        is_super_last;
        exp_s = 24'h001010 + b1 * 24'h001000 + (b0 ? 24'h000100 : 24'h0);
        // Wait: in idma_nd_midend, src_addr_q accumulates strides sequentially:
        // burst 0: base
        // burst 1 (stage 0 en): base + stride[0]
        // burst 2 (stage 0 clear -> stride_sel=1): burst 1 + stride[1]
        // burst 3 (stage 0 en -> stride_sel=0): burst 2 + stride[0]
        if (b1 == 0 && b0 == 0) begin
          exp_s  = 24'h001010;
          exp_d  = 24'h002028;
          exp_sc = 24'h004000;
        end else if (b1 == 0 && b0 == 1) begin
          exp_s  = 24'h001010 + 24'h000100;
          exp_d  = 24'h002028 + 24'h000200;
          exp_sc = 24'h004000 + 24'h000040;
        end else if (b1 == 1 && b0 == 0) begin
          exp_s  = 24'h001010 + 24'h000100 + 24'h001000;
          exp_d  = 24'h002028 + 24'h000200 + 24'h002000;
          exp_sc = 24'h004000 + 24'h000040 + 24'h000400;
        end else begin
          exp_s  = 24'h001010 + 24'h000100 + 24'h001000 + 24'h000100;
          exp_d  = 24'h002028 + 24'h000200 + 24'h002000 + 24'h000200;
          exp_sc = 24'h004000 + 24'h000040 + 24'h000400 + 24'h000040;
        end
        is_super_last = (b1 == 1 && b0 == 1);

        #1;
        if (burst_scale_addr_o !== exp_sc)
          $fatal(1, "Scale stride mismatch at b1=%0d b0=%0d: got=0x%06x exp=0x%06x", b1, b0, burst_scale_addr_o, exp_sc);

        // Clock edge loads burst into legalizer
        @(posedge clk_i);

        // Split 0: 16 bytes (4 beats -> len=3), w_last_o=0
        // Test asymmetric backpressure (r_ready_i=1, w_ready_i=0) and flush_i=1 first!
        @(negedge clk_i);
        if (is_super_last) begin
          req_valid_i = 1'b0;
        end
        r_ready_i = 1'b1;
        w_ready_i = 1'b0;
        #1;
        if (r_valid_o !== 1'b0 || w_valid_o !== 1'b0)
          $fatal(1, "Coupled legalizer asserted r_valid_o/w_valid_o when w_ready_i=0!");
        @(posedge clk_i);
        @(negedge clk_i);
        // Now test flush_i=1 with r_ready_i=1, w_ready_i=1
        w_ready_i = 1'b1;
        flush_i   = 1'b1;
        #1;
        if (r_valid_o !== 1'b0 || w_valid_o !== 1'b0)
          $fatal(1, "Legalizer asserted valid while flush_i=1!");
        @(posedge clk_i);
        @(negedge clk_i);
        flush_i   = 1'b0;
        #1;
        if (!r_valid_o || !w_valid_o || r_ar_addr_o !== exp_s || w_aw_addr_o !== exp_d ||
            r_ar_len_o !== 8'd3 || w_aw_len_o !== 8'd3 || w_last_o !== 1'b0 || w_super_last_o !== is_super_last) begin
          $fatal(1, "Split 0 mismatch at b1=%0d b0=%0d: ar_addr=0x%06x aw_addr=0x%06x ar_len=%0d aw_len=%0d last=%0b",
                 b1, b0, r_ar_addr_o, w_aw_addr_o, r_ar_len_o, w_aw_len_o, w_last_o);
        end
        @(posedge clk_i);

        // Split 1: 8 bytes (2 beats -> len=1), w_last_o=0
        #1;
        if (!r_valid_o || !w_valid_o || r_ar_addr_o !== (exp_s + 24'd16) || w_aw_addr_o !== (exp_d + 24'd16) ||
            r_ar_len_o !== 8'd1 || w_aw_len_o !== 8'd1 || w_last_o !== 1'b0) begin
          $fatal(1, "Split 1 mismatch at b1=%0d b0=%0d: ar_addr=0x%06x aw_addr=0x%06x ar_len=%0d aw_len=%0d",
                 b1, b0, r_ar_addr_o, w_aw_addr_o, r_ar_len_o, w_aw_len_o);
        end
        @(posedge clk_i);

        // Split 2 (final split of this 1D burst): 24 bytes (6 beats -> len=5), w_last_o=1!
        #1;
        if (!r_valid_o || !w_valid_o || r_ar_addr_o !== (exp_s + 24'd24) || w_aw_addr_o !== (exp_d + 24'd24) ||
            r_ar_len_o !== 8'd5 || w_aw_len_o !== 8'd5 || w_last_o !== 1'b1 || w_super_last_o !== is_super_last) begin
          $fatal(1, "Split 2 mismatch at b1=%0d b0=%0d: ar_addr=0x%06x aw_addr=0x%06x ar_len=%0d aw_len=%0d last=%0b",
                 b1, b0, r_ar_addr_o, w_aw_addr_o, r_ar_len_o, w_aw_len_o, w_last_o);
        end
      end
    end
    @(posedge clk_i);
    @(negedge clk_i);

    // ----------------------------------------------------------------------
    // 3. Verify midend response filtering:
    //    Non-last 1D responses (burst_rsp_last_i == 0) must NOT assert rsp_valid_o;
    //    only burst_rsp_last_i == 1 asserts rsp_valid_o!
    // ----------------------------------------------------------------------
    rsp_ready_i       = 1'b1;
    burst_rsp_valid_i = 1'b1;
    burst_rsp_last_i  = 1'b0;
    #1;
    if (rsp_valid_o !== 1'b0 || burst_rsp_ready_o !== 1'b1)
      $fatal(1, "Non-last burst_rsp erroneously asserted rsp_valid_o!");
    @(posedge clk_i);
    @(negedge clk_i);
    burst_rsp_last_i  = 1'b1;
    #1;
    if (rsp_valid_o !== 1'b1 || rsp_error_o !== 1'b0)
      $fatal(1, "Last burst_rsp did not assert rsp_valid_o!");
    @(posedge clk_i);
    @(negedge clk_i);
    burst_rsp_valid_i = 1'b0;
    burst_rsp_last_i  = 1'b0;

    // ----------------------------------------------------------------------
    // 4. Verify decoupled R/W mode (req_decouple_rw_i=1) & kill_i abort:
    //    In decoupled mode, read and write split independently at their own
    //    page boundaries (read=16B, write=24B) and advance independently!
    // ----------------------------------------------------------------------
    req_length_i      = 24'd48;
    req_src_addr_i    = 24'h005010; // 16B to 32B pb
    req_dst_addr_i    = 24'h006028; // 24B to 64B pb
    req_decouple_rw_i = 1'b1;
    req_reps_i[0]     = 12'd1;
    req_reps_i[1]     = 12'd1;
    req_valid_i       = 1'b1;
    r_ready_i         = 1'b1;
    w_ready_i         = 1'b1;
    @(posedge clk_i);
    @(negedge clk_i);
    req_valid_i       = 1'b0;
    // Stall w_ready_i=0 while r_ready_i=1: in decoupled mode, r_valid_o MUST be 1 with 16B (len=3),
    // while w_aw_len_o is 24B (len=5)!
    r_ready_i         = 1'b1;
    w_ready_i         = 1'b0;
    #1;
    if (!r_valid_o || w_valid_o || r_ar_len_o !== 8'd3 || w_aw_len_o !== 8'd5)
      $fatal(1, "Decoupled mode failed independent page split or r_valid_o under w_ready_i=0: r_len=%0d w_len=%0d", r_ar_len_o, w_aw_len_o);
    @(posedge clk_i);
    @(negedge clk_i);
    // Assert kill_i to abort the remaining transfer
    kill_i = 1'b1;
    @(posedge clk_i);
    @(negedge clk_i);
    kill_i = 1'b0;
    #1;
    if (r_busy_o !== 1'b0 || w_busy_o !== 1'b0 || r_valid_o !== 1'b0 || w_valid_o !== 1'b0)
      $fatal(1, "kill_i did not clear legalizer state");

    $display("PASS idma_nd_legalizer_top seed=%0d", SEED);
    $finish(0);
  end
endmodule
