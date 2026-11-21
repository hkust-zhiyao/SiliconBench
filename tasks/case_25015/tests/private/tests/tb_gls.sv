`timescale 1ns/1ps

module tb_gls;
  localparam int CORE_COUNT = 2;
  localparam int ADDR_W     = 34;
  localparam int PPN_W      = 22;
  localparam int N_CH       = 4;

  localparam [31:0] OP_MUL    = 32'h0200_0033;
  localparam [31:0] OP_MULH   = 32'h0200_1033;
  localparam [31:0] OP_DIV    = 32'h0200_4033;
  localparam [31:0] OP_REMU   = 32'h0200_7033;
  localparam [31:0] OP_ILL    = 32'h0000_0033;

  reg                     clk_i;
  reg                     rst_ni;
  reg                     test_mode_i;
  reg                     clk_d2_bypass_i;

  reg  [N_CH-1:0]         tlb_req_valid_i;
  wire [N_CH-1:0]         tlb_req_ready_o;
  reg  [N_CH-1:0]         tlb_req_flush_i;
  reg  [N_CH*20-1:0]      tlb_req_va_i;
  reg  [N_CH*PPN_W-1:0]   tlb_req_ppn_i;
  reg  [N_CH*2-1:0]       tlb_req_priv_i;
  reg  [N_CH-1:0]         tlb_req_read_i;
  reg  [N_CH-1:0]         tlb_req_write_i;
  reg  [N_CH-1:0]         tlb_req_exec_i;

  wire [N_CH-1:0]         tlb_rsp_valid_o;
  reg  [N_CH-1:0]         tlb_rsp_ready_i;
  wire [N_CH*PPN_W-1:0]   tlb_rsp_pa_o;
  wire [N_CH-1:0]         tlb_rsp_fault_o;

  reg  [CORE_COUNT-1:0]    acc_qvalid_i;
  wire [CORE_COUNT-1:0]    acc_qready_o;
  reg  [CORE_COUNT*5-1:0]  acc_qid_i;
  reg  [CORE_COUNT*32-1:0] acc_qop_i;
  reg  [CORE_COUNT*32-1:0] acc_qarga_i;
  reg  [CORE_COUNT*32-1:0] acc_qargb_i;
  reg  [CORE_COUNT*32-1:0] acc_qargc_i;

  wire [CORE_COUNT-1:0]    acc_pvalid_o;
  reg  [CORE_COUNT-1:0]    acc_pready_i;
  wire [CORE_COUNT*5-1:0]  acc_pid_o;
  wire [CORE_COUNT*32-1:0] acc_pdata_o;
  wire [CORE_COUNT-1:0]    acc_perror_o;

  wire                    ptw_mem_qvalid_o;
  wire                    ptw_mem_qready_i;
  wire [ADDR_W-1:0]       ptw_mem_qaddr_o;
  wire [2:0]              ptw_mem_qsize_o;
  wire                    ptw_mem_pvalid_i;
  wire                    ptw_mem_pready_o;
  wire [31:0]             ptw_mem_pdata_i;
  wire                    ptw_mem_perror_i;

  snitch_iso_cluster_subsys dut (
    .clk_i            ( clk_i            ),
    .rst_ni           ( rst_ni           ),
    .test_mode_i      ( test_mode_i      ),
    .clk_d2_bypass_i  ( clk_d2_bypass_i  ),
    .tlb_req_valid_i  ( tlb_req_valid_i  ),
    .tlb_req_ready_o  ( tlb_req_ready_o  ),
    .tlb_req_flush_i  ( tlb_req_flush_i  ),
    .tlb_req_va_i     ( tlb_req_va_i     ),
    .tlb_req_ppn_i    ( tlb_req_ppn_i    ),
    .tlb_req_priv_i   ( tlb_req_priv_i   ),
    .tlb_req_read_i   ( tlb_req_read_i   ),
    .tlb_req_write_i  ( tlb_req_write_i  ),
    .tlb_req_exec_i   ( tlb_req_exec_i   ),
    .tlb_rsp_valid_o  ( tlb_rsp_valid_o  ),
    .tlb_rsp_ready_i  ( tlb_rsp_ready_i  ),
    .tlb_rsp_pa_o     ( tlb_rsp_pa_o     ),
    .tlb_rsp_fault_o  ( tlb_rsp_fault_o  ),
    .acc_qvalid_i     ( acc_qvalid_i     ),
    .acc_qready_o     ( acc_qready_o     ),
    .acc_qid_i        ( acc_qid_i        ),
    .acc_qop_i        ( acc_qop_i        ),
    .acc_qarga_i      ( acc_qarga_i      ),
    .acc_qargb_i      ( acc_qargb_i      ),
    .acc_qargc_i      ( acc_qargc_i      ),
    .acc_pvalid_o     ( acc_pvalid_o     ),
    .acc_pready_i     ( acc_pready_i     ),
    .acc_pid_o        ( acc_pid_o        ),
    .acc_pdata_o      ( acc_pdata_o      ),
    .acc_perror_o     ( acc_perror_o     ),
    .ptw_mem_qvalid_o ( ptw_mem_qvalid_o ),
    .ptw_mem_qready_i ( ptw_mem_qready_i ),
    .ptw_mem_qaddr_o  ( ptw_mem_qaddr_o  ),
    .ptw_mem_qsize_o  ( ptw_mem_qsize_o  ),
    .ptw_mem_pvalid_i ( ptw_mem_pvalid_i ),
    .ptw_mem_pready_o ( ptw_mem_pready_o ),
    .ptw_mem_pdata_i  ( ptw_mem_pdata_i  ),
    .ptw_mem_perror_i ( ptw_mem_perror_i )
  );

  initial begin
    clk_i = 1'b0;
    forever #2.5 clk_i = ~clk_i;
  end

  reg        mem_pend_q;
  reg [31:0] mem_rdata_q;
  assign ptw_mem_qready_i = ~mem_pend_q;
  assign ptw_mem_pvalid_i = mem_pend_q;
  assign ptw_mem_pdata_i  = mem_rdata_q;
  assign ptw_mem_perror_i = 1'b0;

  function [31:0] lookup_pte(input [ADDR_W-1:0] addr);
    begin
      case (addr)
        // root_ppn=22'h00_1000: vpn1=10'h010 -> pointer to l0_ppn=22'h00_2000
        {22'h00_1000, 10'h010, 2'b00}: lookup_pte = {22'h00_2000, 2'b00, 8'b0000_0001};
        // l0_ppn=22'h00_2000: vpn0=10'h001 -> U-mode RWX leaf ppn=22'h05_0001
        {22'h00_2000, 10'h001, 2'b00}: lookup_pte = {22'h05_0001, 2'b00, 8'b1101_1111};
        // l0_ppn=22'h00_2000: vpn0=10'h002 -> U-mode Execute-Only leaf (X=1,R=0,W=0,U=1,A=1)
        {22'h00_2000, 10'h002, 2'b00}: lookup_pte = {22'h05_0002, 2'b00, 8'b0101_1001};
        // root_ppn=22'h00_1000: vpn1=10'h020 -> 4MiB superpage ppn1=12'h0AB
        {22'h00_1000, 10'h020, 2'b00}: lookup_pte = {12'h0AB, 10'h000, 2'b00, 8'b1101_1111};
        default:                       lookup_pte = 32'h0;
      endcase
    end
  endfunction

  always @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      mem_pend_q  <= 1'b0;
      mem_rdata_q <= 32'h0;
    end else begin
      if ((^ptw_mem_qvalid_o === 1'bx)) begin
        $display("ERROR_GLS: X on ptw_mem_qvalid_o");
        $finish(1);
      end
      if (ptw_mem_qvalid_o === 1'b1 && ptw_mem_qready_i === 1'b1) begin
        mem_pend_q  <= 1'b1;
        mem_rdata_q <= lookup_pte(ptw_mem_qaddr_o);
      end else if (mem_pend_q && ptw_mem_pready_o === 1'b1) begin
        mem_pend_q <= 1'b0;
      end
    end
  end

  task gls_reset(input byp);
    begin
      rst_ni          = 1'b0;
      test_mode_i     = 1'b0;
      clk_d2_bypass_i = byp;
      tlb_req_valid_i = 0;
      tlb_req_flush_i = 0;
      tlb_req_va_i    = 0;
      tlb_req_ppn_i   = 0;
      tlb_req_priv_i  = 0;
      tlb_req_read_i  = 0;
      tlb_req_write_i = 0;
      tlb_req_exec_i  = 0;
      tlb_rsp_ready_i = 4'b1111;
      acc_qvalid_i    = 0;
      acc_qid_i       = 0;
      acc_qop_i       = 0;
      acc_qarga_i     = 0;
      acc_qargb_i     = 0;
      acc_qargc_i     = 0;
      acc_pready_i    = 2'b11;
      repeat (8) @(posedge clk_i);
      #0.3 rst_ni = 1'b1;
      repeat (6) @(posedge clk_i);
      if ((^tlb_req_ready_o === 1'bx) || (^tlb_rsp_valid_o === 1'bx) || (^acc_qready_o === 1'bx) || (^acc_pvalid_o === 1'bx)) begin
        $display("ERROR_GLS: X on handshake outputs after reset (byp=%0b)", byp);
        $finish(1);
      end
    end
  endtask

  task gls_tlb(
    input integer ch,
    input [19:0]  va,
    input         rd,
    input         ex,
    input [21:0]  exp_pa,
    input         exp_flt
  );
    integer g;
    reg [21:0] got_pa;
    reg        got_flt;
    begin
      @(negedge clk_i);
      tlb_req_valid_i[ch]              = 1'b1;
      tlb_req_va_i[ch*20 +: 20]        = va;
      tlb_req_ppn_i[ch*PPN_W +: PPN_W] = 22'h00_1000;
      tlb_req_priv_i[ch*2 +: 2]        = 2'b00;
      tlb_req_read_i[ch]               = rd;
      tlb_req_write_i[ch]              = 1'b0;
      tlb_req_exec_i[ch]               = ex;
      g = 0;
      @(posedge clk_i);
      while (tlb_req_ready_o[ch] !== 1'b1) begin
        g = g + 1;
        if (g > 300) begin
          $display("ERROR_GLS: TLB req timeout ch=%0d (likely unreset clk_d2 X lockup)", ch);
          $finish(1);
        end
        @(posedge clk_i);
      end
      @(negedge clk_i);
      tlb_req_valid_i[ch] = 1'b0;
      g = 0;
      @(posedge clk_i);
      while (tlb_rsp_valid_o[ch] !== 1'b1) begin
        g = g + 1;
        if (g > 400) begin
          $display("ERROR_GLS: TLB rsp timeout ch=%0d", ch);
          $finish(1);
        end
        @(posedge clk_i);
      end
      got_pa  = tlb_rsp_pa_o[ch*PPN_W +: PPN_W];
      got_flt = tlb_rsp_fault_o[ch];
      if ((^got_flt === 1'bx) || (got_flt !== exp_flt) || (!exp_flt && (got_pa !== exp_pa))) begin
        $display("ERROR_GLS: TLB mismatch ch=%0d got_flt=%b exp_flt=%b got_pa=%h exp_pa=%h", ch, got_flt, exp_flt, got_pa, exp_pa);
        $finish(1);
      end
    end
  endtask

  task gls_acc(
    input integer core,
    input [4:0]   tid,
    input [31:0]  op,
    input [31:0]  a,
    input [31:0]  b,
    input [31:0]  exp_res,
    input         exp_err
  );
    integer g;
    begin
      @(negedge clk_i);
      acc_qvalid_i[core]         = 1'b1;
      acc_qid_i[core*5 +: 5]     = tid;
      acc_qop_i[core*32 +: 32]   = op;
      acc_qarga_i[core*32 +: 32] = a;
      acc_qargb_i[core*32 +: 32] = b;
      g = 0;
      @(posedge clk_i);
      while (acc_qready_o[core] !== 1'b1) begin
        g = g + 1;
        if (g > 200) begin $display("ERROR_GLS: acc req timeout"); $finish(1); end
        @(posedge clk_i);
      end
      @(negedge clk_i);
      acc_qvalid_i[core] = 1'b0;
      g = 0;
      @(posedge clk_i);
      while (acc_pvalid_o[core] !== 1'b1) begin
        g = g + 1;
        if (g > 200) begin $display("ERROR_GLS: acc rsp timeout"); $finish(1); end
        @(posedge clk_i);
      end
      if ((acc_perror_o[core] !== exp_err) || (acc_pid_o[core*5 +: 5] !== tid) || (!exp_err && (acc_pdata_o[core*32 +: 32] !== exp_res))) begin
        $display("ERROR_GLS: acc rsp mismatch core=%0d err=%b id=%0d data=%h", core, acc_perror_o[core], acc_pid_o[core*5 +: 5], acc_pdata_o[core*32 +: 32]);
        $finish(1);
      end
    end
  endtask

  integer mode;
  initial begin
    for (mode = 0; mode < 2; mode = mode + 1) begin
      gls_reset(mode[0]);
      gls_tlb(0, {10'h010, 10'h001}, 1'b0, 1'b1, 22'h05_0001, 1'b0);
      gls_tlb(3, {10'h020, 10'h1AB}, 1'b1, 1'b0, {12'h0AB, 10'h1AB}, 1'b0);
      gls_tlb(2, {10'h010, 10'h002}, 1'b0, 1'b1, 22'h05_0002, 1'b0);
      gls_tlb(1, {10'h010, 10'h002}, 1'b1, 1'b0, 22'h00_0000, 1'b1);
      gls_acc(0, 5'd7,  OP_MUL,  32'h1234_5678, 32'h0000_0010, 32'h2345_6780, 1'b0);
      gls_acc(1, 5'd11, OP_MULH, 32'h8000_0000, 32'hFFFF_FFFF, 32'h0000_0000, 1'b0);
      gls_acc(0, 5'd13, OP_DIV,  32'hFFFF_FF9C, 32'h0000_000A, 32'hFFFF_FFF6, 1'b0);
      gls_acc(1, 5'd19, OP_ILL,  32'hDEAD_BEEF, 32'hCAFE_BABE, 32'h0000_0000, 1'b1);
      gls_acc(0, 5'd21, OP_REMU, 32'h0000_0069, 32'h0000_000A, 32'h0000_0005, 1'b0);
    end
    $display("PASS_GLS");
    $finish(0);
  end
endmodule
