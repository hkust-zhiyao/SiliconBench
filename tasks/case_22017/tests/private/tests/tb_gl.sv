`timescale 1ns/1ps

`ifndef NRLANES
`define NRLANES 4
`endif

module tb_gl;
  localparam int L      = `NRLANES;
  localparam int VLEN   = 1024;
  localparam int ADDR_W = $clog2(VLEN * 32 / L / 64);

  // Exact ara_pkg / rvv_pkg encodings
  localparam [7:0] OP_VREDSUM    = 8'd32;
  localparam [7:0] OP_VFREDOSUM  = 8'd87;
  localparam [7:0] OP_VSLIDEUP   = 8'd128;
  localparam [7:0] OP_VSLIDEDOWN = 8'd129;

  localparam [2:0] VFU_ALU   = 3'd0;
  localparam [2:0] VFU_MFPU  = 3'd1;
  localparam [2:0] VFU_SLDU  = 3'd2;

  localparam [2:0] EW32      = 3'b010;
  localparam [2:0] EW64      = 3'b011;
  localparam [2:0] LMUL_1    = 3'b000;
  localparam [2:0] LMUL_2    = 3'b001;
  localparam [2:0] LMUL_1_8  = 3'b101;

  reg                 clk = 1'b0;
  reg                 rst_n = 1'b0;
  reg  [2:0]          req_id;
  reg  [7:0]          req_op;
  reg                 req_vm;
  reg  [2:0]          req_eew_vs2;
  reg                 req_use_vs2;
  reg  [63:0]         req_scalar_op;
  reg                 req_use_scalar_op;
  reg  [63:0]         req_stride;
  reg                 req_is_stride_np2;
  reg  [2:0]          req_vfu;
  reg  [4:0]          req_vd;
  reg                 req_use_vd;
  reg  [10:0]         req_vl;
  reg  [8:0]          req_vtype;
  reg                 pe_req_valid;
  reg  [7:0]          pe_vinsn_running;
  wire                pe_req_ready;
  wire [7:0]          pe_vinsn_done;

  reg  [L*64-1:0]     sldu_operand;
  reg  [L-1:0]        sldu_operand_valid;
  wire [L-1:0]        sldu_operand_ready;
  wire [L-1:0]        sldu_result_req;
  wire [L*3-1:0]      sldu_result_id;
  wire [L*ADDR_W-1:0] sldu_result_addr;
  wire [L*64-1:0]     sldu_result_wdata;
  wire [L*8-1:0]      sldu_result_be;
  reg  [L-1:0]        sldu_result_gnt;
  reg  [L-1:0]        sldu_result_final_gnt;
  wire [1:0]          sldu_mux_sel;
  wire [L-1:0]        sldu_red_valid;
  reg  [L*8-1:0]      mask_data;
  reg  [L-1:0]        mask_valid;
  wire                mask_ready;

  always #5 clk = ~clk;

  sldu_subsys_top dut (
    .clk_i                  (clk                  ),
    .rst_ni                 (rst_n                ),
    .req_id_i               (req_id               ),
    .req_op_i               (req_op               ),
    .req_vm_i               (req_vm               ),
    .req_eew_vs2_i          (req_eew_vs2          ),
    .req_use_vs2_i          (req_use_vs2          ),
    .req_scalar_op_i        (req_scalar_op        ),
    .req_use_scalar_op_i    (req_use_scalar_op    ),
    .req_stride_i           (req_stride           ),
    .req_is_stride_np2_i    (req_is_stride_np2    ),
    .req_vfu_i              (req_vfu              ),
    .req_vd_i               (req_vd               ),
    .req_use_vd_i           (req_use_vd           ),
    .req_vl_i               (req_vl               ),
    .req_vtype_i            (req_vtype            ),
    .pe_req_valid_i         (pe_req_valid         ),
    .pe_vinsn_running_i     (pe_vinsn_running     ),
    .pe_req_ready_o         (pe_req_ready         ),
    .pe_vinsn_done_o        (pe_vinsn_done        ),
    .sldu_operand_i         (sldu_operand         ),
    .sldu_operand_valid_i   (sldu_operand_valid   ),
    .sldu_operand_ready_o   (sldu_operand_ready   ),
    .sldu_result_req_o      (sldu_result_req      ),
    .sldu_result_id_o       (sldu_result_id       ),
    .sldu_result_addr_o     (sldu_result_addr     ),
    .sldu_result_wdata_o    (sldu_result_wdata    ),
    .sldu_result_be_o       (sldu_result_be       ),
    .sldu_result_gnt_i      (sldu_result_gnt      ),
    .sldu_result_final_gnt_i(sldu_result_final_gnt),
    .sldu_mux_sel_o         (sldu_mux_sel         ),
    .sldu_red_valid_o       (sldu_red_valid       ),
    .mask_i                 (mask_data            ),
    .mask_valid_i           (mask_valid           ),
    .mask_ready_o           (mask_ready           )
  );

  integer err_cnt = 0;

  task check_no_x_ctrl(input [127:0] tag);
    begin
      if ((^pe_req_ready === 1'bx) || (^pe_vinsn_done === 1'bx) ||
          (^sldu_result_req === 1'bx) || (^sldu_red_valid === 1'bx) ||
          (^sldu_operand_ready === 1'bx) || (^mask_ready === 1'bx)) begin
        $display("[GL-ERROR] X detected on control outputs in %0s", tag);
        err_cnt = err_cnt + 1;
      end
    end
  endtask

  task issue_req(
    input [2:0]  id,
    input [7:0]  op,
    input        vm,
    input [2:0]  eew_vs2,
    input [63:0] scalar_op,
    input        use_scalar,
    input [63:0] stride,
    input        is_np2,
    input [2:0]  vfu,
    input [4:0]  vd,
    input [10:0] vl,
    input [2:0]  vsew,
    input [2:0]  vlmul
  );
    integer c;
    begin
      req_id            = id;
      req_op            = op;
      req_vm            = vm;
      req_eew_vs2       = eew_vs2;
      req_use_vs2       = 1'b1;
      req_scalar_op     = scalar_op;
      req_use_scalar_op = use_scalar;
      req_stride        = stride;
      req_is_stride_np2 = is_np2;
      req_vfu           = vfu;
      req_vd            = vd;
      req_use_vd        = 1'b1;
      req_vl            = vl;
      req_vtype         = {3'b000, vsew, vlmul};
      pe_req_valid      = 1'b1;
      c = 0;
      #1;
      while (pe_req_ready !== 1'b1 && c < 100) begin
        @(posedge clk); #1;
        c = c + 1;
      end
      @(posedge clk); #1;
      pe_req_valid         = 1'b0;
      pe_vinsn_running[id] = 1'b1;
    end
  endtask
  integer l, b, cyc;
  reg [L-1:0] sent_op, got_res;
  reg [63:0]  got_word [0:L-1];
  reg [7:0]   got_be   [0:L-1];
  reg         done_flag;

  initial begin
    rst_n                 = 1'b0;
    req_id                = 3'd0;
    req_op                = OP_VSLIDEUP;
    req_vm                = 1'b1;
    req_eew_vs2           = EW64;
    req_use_vs2           = 1'b1;
    req_scalar_op         = 64'h0;
    req_use_scalar_op     = 1'b0;
    req_stride            = 64'h0;
    req_is_stride_np2     = 1'b0;
    req_vfu               = VFU_SLDU;
    req_vd                = 5'd0;
    req_use_vd            = 1'b1;
    req_vl                = 11'd0;
    req_vtype             = 9'd0;
    pe_req_valid          = 1'b0;
    pe_vinsn_running      = 8'h00;
    sldu_operand          = {L{64'h0}};
    sldu_operand_valid    = {L{1'b0}};
    sldu_result_gnt       = {L{1'b1}};
    sldu_result_final_gnt = {L{1'b0}};
    mask_data             = {L{8'h00}};
    mask_valid            = {L{1'b0}};

    repeat (4) @(posedge clk);
    #1;
    rst_n = 1'b1;
    #1;
    check_no_x_ctrl("post_reset");
    if ((pe_req_ready !== 1'b1) || (pe_vinsn_done !== 8'h00) ||
        (sldu_result_req !== {L{1'b0}}) || (sldu_red_valid !== {L{1'b0}}) ||
        (mask_ready !== 1'b0)) begin
      $display("[GL-ERROR] Unexpected post-reset idle outputs");
      err_cnt = err_cnt + 1;
    end

    // Test 1: Null VSLIDEUP with 64-bit stride >= vl (0 pops, 0 writes, clean done[0])
    issue_req(3'd0, OP_VSLIDEUP, 1'b0, EW64, 64'h0, 1'b0, 64'h8000_0000_0000_0004, 1'b1,
              VFU_SLDU, 5'd1, 11'd4, EW64, LMUL_1);
    done_flag = 1'b0;
    for (cyc = 0; cyc < 16 && !done_flag; cyc = cyc + 1) begin
      #1;
      check_no_x_ctrl("null_vslideup");
      if ((|sldu_result_req) || mask_ready) begin
        $display("[GL-ERROR] Null VSLIDEUP requested VRF write or mask beat");
        err_cnt = err_cnt + 1;
      end
      if (pe_vinsn_done[0] === 1'b1) done_flag = 1'b1;
      @(posedge clk); #1;
      if (done_flag) pe_vinsn_running[0] = 1'b0;
    end
    if (!done_flag) begin
      $display("[GL-ERROR] Null VSLIDEUP did not assert pe_vinsn_done[0]");
      err_cnt = err_cnt + 1;
    end

    // Test 2: Intra-row NP2 VSLIDEUP (EW32, vl = 2*L, stride = 3 -> exercises p2_stride_gen!)
    issue_req(3'd1, OP_VSLIDEUP, 1'b1, EW32, 64'h0, 1'b0, 64'd3, 1'b1,
              VFU_SLDU, 5'd2, 2*L, EW32, LMUL_1);
    for (l = 0; l < L; l = l + 1) begin
      sldu_operand[l*64 +: 64] = {32'hB000_0000 + l + L, 32'hA000_0000 + l};
    end
    sent_op   = {L{1'b0}};
    got_res   = {L{1'b0}};
    done_flag = 1'b0;
    for (cyc = 0; cyc < 60 && !done_flag; cyc = cyc + 1) begin
      sldu_operand_valid    = ~sent_op;
      sldu_result_gnt       = {L{1'b1}};
      sldu_result_final_gnt = {L{1'b0}};
      #1;
      check_no_x_ctrl("np2_vslideup");
      begin : sample_np2
        reg [L-1:0] op_hs, res_hs;
        reg         d_s;
        op_hs  = sldu_operand_valid & sldu_operand_ready;
        res_hs = sldu_result_req & sldu_result_gnt;
        d_s    = pe_vinsn_done[1];
        for (l = 0; l < L; l = l + 1) begin
          if (res_hs[l]) begin
            got_word[l] = sldu_result_wdata[l*64 +: 64];
            got_be[l]   = sldu_result_be[l*8 +: 8];
          end
        end
        @(posedge clk); #1;
        sent_op = sent_op | op_hs;
        got_res = got_res | res_hs;
        if (|res_hs) begin
          sldu_result_final_gnt = res_hs;
          @(posedge clk); #1;
          sldu_result_final_gnt = {L{1'b0}};
          if (pe_vinsn_done[1] === 1'b1) d_s = 1'b1;
        end
        if (d_s) begin
          done_flag           = 1'b1;
          pe_vinsn_running[1] = 1'b0;
        end
      end
    end
    sldu_operand_valid = {L{1'b0}};
    // Check element 3 (which receives source element 0 = 32'hA000_0000):
    // For L=2: elem 3 is lane 1 [63:32], lane 0 be == 8'h00, lane 1 be == 8'hF0
    // For L=4: elem 3 is lane 3 [31:0], lane 3 be == 8'hFF (elems 3 & 7)
    if (!done_flag || (got_res !== {L{1'b1}})) begin
      $display("[GL-ERROR] NP2 VSLIDEUP failed handshake (done=%b got_res=%b)", done_flag, got_res);
      err_cnt = err_cnt + 1;
    end else if (L == 2) begin
      if ((got_be[0] !== 8'h00) || (got_be[1] !== 8'hF0) || (got_word[1][63:32] !== 32'hA000_0000)) begin
        $display("[GL-ERROR] L=2 NP2 VSLIDEUP mismatch: be0=%h be1=%h w1=%h", got_be[0], got_be[1], got_word[1]);
        err_cnt = err_cnt + 1;
      end
    end else if (L == 4) begin
      if ((got_be[3] !== 8'hFF) || (got_word[3][31:0] !== 32'hA000_0000) || (got_word[3][63:32] !== 32'hB000_0000)) begin
        $display("[GL-ERROR] L=4 NP2 VSLIDEUP mismatch: be3=%h w3=%h", got_be[3], got_word[3]);
        err_cnt = err_cnt + 1;
      end
    end

    // Test 3: VSLIDEDOWN out-of-bounds zero-fill (EW64, LMUL_1_8 -> vlmax=2, vl=2, stride=1)
    issue_req(3'd2, OP_VSLIDEDOWN, 1'b1, EW64, 64'h0, 1'b0, 64'd1, 1'b0,
              VFU_SLDU, 5'd4, 11'd2, EW64, LMUL_1_8);
    for (l = 0; l < L; l = l + 1) begin
      sldu_operand[l*64 +: 64] = 64'hDEAD_BEEF_0000_0000 + l;
    end
    sent_op   = {L{1'b0}};
    got_res   = {L{1'b0}};
    done_flag = 1'b0;
    for (cyc = 0; cyc < 50 && !done_flag; cyc = cyc + 1) begin
      sldu_operand_valid    = ~sent_op;
      sldu_result_gnt       = {L{1'b1}};
      sldu_result_final_gnt = {L{1'b0}};
      #1;
      check_no_x_ctrl("vslidedown_zfill");
      begin : sample_zfill
        reg [L-1:0] op_hs, res_hs;
        reg         d_s;
        op_hs  = sldu_operand_valid & sldu_operand_ready;
        res_hs = sldu_result_req & sldu_result_gnt;
        d_s    = pe_vinsn_done[2];
        for (l = 0; l < L; l = l + 1) begin
          if (res_hs[l]) begin
            got_word[l] = sldu_result_wdata[l*64 +: 64];
            got_be[l]   = sldu_result_be[l*8 +: 8];
          end
        end
        @(posedge clk); #1;
        sent_op = sent_op | op_hs;
        got_res = got_res | res_hs;
        if (|res_hs) begin
          sldu_result_final_gnt = res_hs;
          @(posedge clk); #1;
          sldu_result_final_gnt = {L{1'b0}};
          if (pe_vinsn_done[2] === 1'b1) d_s = 1'b1;
        end
        if (d_s) begin
          done_flag           = 1'b1;
          pe_vinsn_running[2] = 1'b0;
        end
      end
    end
    sldu_operand_valid = {L{1'b0}};
    if (!done_flag || (got_be[0] !== 8'hFF) || (got_word[0] !== 64'hDEAD_BEEF_0000_0001) ||
        (got_be[1] !== 8'hFF) || (got_word[1] !== 64'h0000_0000_0000_0000)) begin
      $display("[GL-ERROR] VSLIDEDOWN vlmax zero-fill failed: done=%b w0=%h w1=%h",
               done_flag, got_word[0], got_word[1]);
      err_cnt = err_cnt + 1;
    end

    if (err_cnt == 0) begin
      $display("PASS: Gate-level 4-state verification passed for NrLanes=%0d", L);
      $finish;
    end else begin
      $display("[GL-FATAL] NrLanes=%0d gate-level errors=%0d", L, err_cnt);
      $fatal(1, "Gate-level check failed");
    end
  end
endmodule
