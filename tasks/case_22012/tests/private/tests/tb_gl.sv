`timescale 1ns/1ps

module tb_gl;
  // Opcode encodings matching ara_pkg::ara_op_e
  localparam [7:0] OP_VADD    = 8'd0;
  localparam [7:0] OP_VSADDU  = 8'd4;
  localparam [7:0] OP_VSADD   = 8'd5;
  localparam [7:0] OP_VSSUBU  = 8'd6;
  localparam [7:0] OP_VSSUB   = 8'd7;
  localparam [7:0] OP_VAADDU  = 8'd8;
  localparam [7:0] OP_VAADD   = 8'd9;
  localparam [7:0] OP_VASUBU  = 8'd10;
  localparam [7:0] OP_VASUB   = 8'd11;
  localparam [7:0] OP_VSSRL   = 8'd20;
  localparam [7:0] OP_VSSRA   = 8'd21;
  localparam [7:0] OP_VNCLIPU = 8'd22;
  localparam [7:0] OP_VNCLIP  = 8'd23;

  localparam [2:0] EW8  = 3'd0;
  localparam [2:0] EW16 = 3'd1;
  localparam [2:0] EW32 = 3'd2;
  localparam [2:0] EW64 = 3'd3;

  reg         clk_i = 1'b0;
  always #2.5 clk_i = ~clk_i;

  reg         rst_ni;
  reg  [1:0]  lane_id_i;
  wire        vxsat_flag_o;
  reg  [1:0]  alu_vxrm_i;
  reg  [2:0]  op_id_i;
  reg  [7:0]  op_code_i;
  reg         op_vm_i;
  reg         op_use_vs1_i;
  reg         op_use_vs2_i;
  reg         op_use_vd_op_i;
  reg  [63:0] op_scalar_op_i;
  reg         op_use_scalar_op_i;
  reg  [2:0]  op_vfu_i;
  reg  [4:0]  op_vd_i;
  reg         op_use_vd_i;
  reg  [12:0] op_vl_i;
  reg  [12:0] op_vstart_i;
  reg  [2:0]  op_vsew_i;
  reg         vfu_operation_valid_i;
  wire        alu_ready_o;
  wire [7:0]  alu_vinsn_done_o;
  wire        alu_red_complete_o;
  reg  [63:0] alu_operand_0_i;
  reg  [63:0] alu_operand_1_i;
  reg  [1:0]  alu_operand_valid_i;
  wire [1:0]  alu_operand_ready_o;
  wire        alu_result_req_o;
  wire [2:0]  alu_result_id_o;
  wire [11:0] alu_result_addr_o;
  wire [63:0] alu_result_wdata_o;
  wire [7:0]  alu_result_be_o;
  reg         alu_result_gnt_i;
  wire        alu_red_valid_o;
  reg         alu_red_ready_i;
  reg  [63:0] sldu_operand_i;
  reg         sldu_alu_valid_i;
  wire        sldu_alu_ready_o;
  wire [63:0] mask_operand_o;
  wire        mask_operand_valid_o;
  reg         mask_operand_ready_i;
  reg  [7:0]  mask_i;
  reg         mask_valid_i;
  wire        mask_ready_o;

  syn_wrap_enable u_gl (
    .clk_i                (clk_i),
    .rst_ni               (rst_ni),
    .lane_id_i            (lane_id_i),
    .vxsat_flag_o         (vxsat_flag_o),
    .alu_vxrm_i           (alu_vxrm_i),
    .op_id_i              (op_id_i),
    .op_code_i            (op_code_i),
    .op_vm_i              (op_vm_i),
    .op_use_vs1_i         (op_use_vs1_i),
    .op_use_vs2_i         (op_use_vs2_i),
    .op_use_vd_op_i       (op_use_vd_op_i),
    .op_scalar_op_i       (op_scalar_op_i),
    .op_use_scalar_op_i   (op_use_scalar_op_i),
    .op_vfu_i             (op_vfu_i),
    .op_vd_i              (op_vd_i),
    .op_use_vd_i          (op_use_vd_i),
    .op_vl_i              (op_vl_i),
    .op_vstart_i          (op_vstart_i),
    .op_vsew_i            (op_vsew_i),
    .vfu_operation_valid_i(vfu_operation_valid_i),
    .alu_ready_o          (alu_ready_o),
    .alu_vinsn_done_o     (alu_vinsn_done_o),
    .alu_red_complete_o   (alu_red_complete_o),
    .alu_operand_0_i      (alu_operand_0_i),
    .alu_operand_1_i      (alu_operand_1_i),
    .alu_operand_valid_i  (alu_operand_valid_i),
    .alu_operand_ready_o  (alu_operand_ready_o),
    .alu_result_req_o     (alu_result_req_o),
    .alu_result_id_o      (alu_result_id_o),
    .alu_result_addr_o    (alu_result_addr_o),
    .alu_result_wdata_o   (alu_result_wdata_o),
    .alu_result_be_o      (alu_result_be_o),
    .alu_result_gnt_i     (alu_result_gnt_i),
    .alu_red_valid_o      (alu_red_valid_o),
    .alu_red_ready_i      (alu_red_ready_i),
    .sldu_operand_i       (sldu_operand_i),
    .sldu_alu_valid_i     (sldu_alu_valid_i),
    .sldu_alu_ready_o     (sldu_alu_ready_o),
    .mask_operand_o       (mask_operand_o),
    .mask_operand_valid_o (mask_operand_valid_o),
    .mask_operand_ready_i (mask_operand_ready_i),
    .mask_i               (mask_i),
    .mask_valid_i         (mask_valid_i),
    .mask_ready_o         (mask_ready_o)
  );

  reg sticky_vxsat;

  // Continuous 4-state X-propagation monitor on every posedge after reset
  always @(posedge clk_i) begin
    if (rst_ni === 1'b1) begin
      if (^alu_ready_o === 1'bx || ^alu_operand_ready_o === 1'bx || ^mask_ready_o === 1'bx ||
          ^alu_result_req_o === 1'bx || ^alu_vinsn_done_o === 1'bx || ^vxsat_flag_o === 1'bx) begin
        $display("FAIL [4state_gl_xcheck]: X/Z detected on control/vxsat outputs: ready=%b op_rdy=%b m_rdy=%b req=%b done=%b vxsat=%b",
                 alu_ready_o, alu_operand_ready_o, mask_ready_o, alu_result_req_o, alu_vinsn_done_o, vxsat_flag_o);
        $finish(1);
      end
      if (alu_result_req_o === 1'b1) begin
        if (^alu_result_be_o === 1'bx || ^alu_result_id_o === 1'bx || ^alu_result_addr_o === 1'bx) begin
          $display("FAIL [4state_gl_xcheck]: X/Z detected on result metadata: be=%b id=%b addr=%b",
                   alu_result_be_o, alu_result_id_o, alu_result_addr_o);
          $finish(1);
        end
        begin : check_active_bytes
          integer by;
          for (by = 0; by < 8; by = by + 1) begin
            if (alu_result_be_o[by] === 1'b1 && (^alu_result_wdata_o[8*by +: 8] === 1'bx)) begin
              $display("FAIL [4state_gl_xcheck]: X/Z detected on active result byte %0d: wdata=%h be=%b",
                       by, alu_result_wdata_o, alu_result_be_o);
              $finish(1);
            end
          end
        end
      end
      if (vxsat_flag_o === 1'b1) sticky_vxsat <= 1'b1;
    end
  end

  task run_gl_op(
    input [255:0] tag,
    input [7:0]   op_code,
    input [2:0]   vsew,
    input [1:0]   vxrm,
    input [63:0]  a0,
    input [63:0]  b0,
    input [63:0]  a1,
    input [63:0]  b1,
    input         is_nar,
    input         vm,
    input [7:0]   mb,
    input [12:0]  vl,
    input [63:0]  exp_wdata,
    input [7:0]   exp_be,
    input         exp_sat
  );
    integer timeout, by;
    reg got_commit;
    reg [63:0] got_wdata;
    reg [7:0]  got_be;
    begin
      @(negedge clk_i);
      sticky_vxsat          = 1'b0;
      alu_vxrm_i            = vxrm;
      op_id_i               = 3'd1;
      op_code_i             = op_code;
      op_vm_i               = vm;
      op_use_vs1_i          = 1'b1;
      op_use_vs2_i          = 1'b1;
      op_use_vd_op_i        = 1'b0;
      op_scalar_op_i        = 64'd0;
      op_use_scalar_op_i    = 1'b0;
      op_vfu_i              = 3'd0; // VFU_Alu
      op_vd_i               = 5'd4;
      op_use_vd_i           = 1'b1;
      op_vl_i               = vl;
      op_vstart_i           = 13'd0;
      op_vsew_i             = vsew;
      vfu_operation_valid_i = 1'b1;
      alu_result_gnt_i      = 1'b0;

      begin : wait_rdy_lbl
        while (1) begin
          @(posedge clk_i);
          if (alu_ready_o === 1'b1) disable wait_rdy_lbl;
        end
      end
      #0.5;
      vfu_operation_valid_i = 1'b0;

      alu_operand_0_i     = a0;
      alu_operand_1_i     = b0;
      alu_operand_valid_i = 2'b11;
      mask_i              = mb;
      mask_valid_i        = ~vm;
      timeout = 0;
      begin : wait_op0_lbl
        while (1) begin
          @(posedge clk_i);
          if (alu_operand_ready_o[1] === 1'b1) disable wait_op0_lbl;
          timeout = timeout + 1;
          if (timeout > 40) begin $display("FAIL [gl]: op0 timeout"); $finish(1); end
        end
      end
      #0.5;

      if (is_nar) begin
        alu_operand_0_i = a1;
        alu_operand_1_i = b1;
        timeout = 0;
        begin : wait_op1_lbl
          while (1) begin
            @(posedge clk_i);
            if (alu_operand_ready_o[1] === 1'b1) disable wait_op1_lbl;
            timeout = timeout + 1;
            if (timeout > 40) begin $display("FAIL [gl]: op1 timeout"); $finish(1); end
          end
        end
        #0.5;
      end

      alu_operand_valid_i = 2'b00;
      mask_valid_i        = 1'b0;

      timeout = 0;
      while (alu_result_req_o !== 1'b1) begin
        @(posedge clk_i);
        #0.5;
        timeout = timeout + 1;
        if (timeout > 40) begin $display("FAIL [gl]: req timeout"); $finish(1); end
      end

      alu_result_gnt_i = 1'b1;
      got_commit = 1'b0;
      for (timeout = 0; timeout < 6; timeout = timeout + 1) begin
        @(posedge clk_i);
        if (alu_result_req_o === 1'b1 && alu_result_gnt_i === 1'b1 && !got_commit) begin
          got_commit = 1'b1;
          got_wdata  = alu_result_wdata_o;
          got_be     = alu_result_be_o;
        end
        #0.2;
        if (got_commit) alu_result_gnt_i = 1'b0;
      end

      if (!got_commit || got_be !== exp_be) begin
        $display("FAIL [gl]: commit/be mismatch got_be=%h exp_be=%h", got_be, exp_be);
        $finish(1);
      end
      for (by = 0; by < 8; by = by + 1) begin
        if (exp_be[by] && (got_wdata[8*by +: 8] !== exp_wdata[8*by +: 8])) begin
          $display("FAIL [gl]: wdata mismatch at byte %0d: got=%h exp=%h", by, got_wdata, exp_wdata);
          $finish(1);
        end
      end
      @(negedge clk_i);
      if (sticky_vxsat !== exp_sat) begin
        $display("FAIL [gl]: sticky_vxsat mismatch: got=%b exp=%b", sticky_vxsat, exp_sat);
        $finish(1);
      end
    end
  endtask

  initial begin
    // verify opcode indices match ara_pkg: check with shamt=0 X-hazard, unmasked shamt, VAADD, VASUBU, VNCLIP
    rst_ni                = 1'b0;
    lane_id_i             = 2'd0;
    alu_vxrm_i            = 2'b00;
    op_id_i               = 3'd0;
    op_code_i             = 8'd0;
    op_vm_i               = 1'b1;
    op_use_vs1_i          = 1'b0;
    op_use_vs2_i          = 1'b0;
    op_use_vd_op_i        = 1'b0;
    op_scalar_op_i        = 64'd0;
    op_use_scalar_op_i    = 1'b0;
    op_vfu_i              = 3'd0;
    op_vd_i               = 5'd0;
    op_use_vd_i           = 1'b0;
    op_vl_i               = 13'd0;
    op_vstart_i           = 13'd0;
    op_vsew_i             = EW8;
    vfu_operation_valid_i = 1'b0;
    alu_operand_0_i       = 64'd0;
    alu_operand_1_i       = 64'd0;
    alu_operand_valid_i   = 2'b00;
    alu_result_gnt_i      = 1'b0;
    alu_red_ready_i       = 1'b0;
    sldu_operand_i        = 64'd0;
    sldu_alu_valid_i      = 1'b0;
    mask_operand_ready_i  = 1'b0;
    mask_i                = 8'hFF;
    mask_valid_i          = 1'b0;
    sticky_vxsat          = 1'b0;

    repeat (5) @(posedge clk_i);
    #0.5;
    rst_ni = 1'b1;
    repeat (2) @(posedge clk_i);

    // Include generated stimulus vector file written by Verilator RTL run!
    `include "gl_vectors.svh"

    $display("PASS [4state_gl]: Gate-level 4-state parity and zero-X checks passed!");
    $finish;
  end

endmodule
