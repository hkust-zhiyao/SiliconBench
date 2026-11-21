`timescale 1ns/1ps

module tb_subsys #(
  parameter int unsigned CORE_COUNT = 4
);
  localparam int unsigned ADDR_W = 34;
  localparam int unsigned DATA_W = 32;
  localparam int unsigned PPN_W  = 22;
  localparam int unsigned N_CH   = 2 * CORE_COUNT;

  // RV32M instruction encodings
  localparam logic [31:0] OP_MUL    = 32'h0200_0033;
  localparam logic [31:0] OP_MULH   = 32'h0200_1033;
  localparam logic [31:0] OP_MULHSU = 32'h0200_2033;
  localparam logic [31:0] OP_MULHU  = 32'h0200_3033;
  localparam logic [31:0] OP_DIV    = 32'h0200_4033;
  localparam logic [31:0] OP_DIVU   = 32'h0200_5033;
  localparam logic [31:0] OP_REM    = 32'h0200_6033;
  localparam logic [31:0] OP_REMU   = 32'h0200_7033;
  localparam logic [31:0] OP_ILL_ADD= 32'h0000_0033;
  localparam logic [31:0] OP_ILL_FF = 32'hFFFF_FFFF;

  localparam logic [1:0] PRIV_U = 2'b00;
  localparam logic [1:0] PRIV_S = 2'b01;

  logic                        clk_i;
  logic                        rst_ni;
  logic                        test_mode_i;
  logic                        clk_d2_bypass_i;

  logic [N_CH-1:0]             tlb_req_valid_i;
  logic [N_CH-1:0]             tlb_req_ready_o;
  logic [N_CH-1:0]             tlb_req_flush_i;
  logic [N_CH*20-1:0]          tlb_req_va_i;
  logic [N_CH*PPN_W-1:0]       tlb_req_ppn_i;
  logic [N_CH*2-1:0]           tlb_req_priv_i;
  logic [N_CH-1:0]             tlb_req_read_i;
  logic [N_CH-1:0]             tlb_req_write_i;
  logic [N_CH-1:0]             tlb_req_exec_i;

  logic [N_CH-1:0]             tlb_rsp_valid_o;
  logic [N_CH-1:0]             tlb_rsp_ready_i;
  logic [N_CH*PPN_W-1:0]       tlb_rsp_pa_o;
  logic [N_CH-1:0]             tlb_rsp_fault_o;

  logic [CORE_COUNT-1:0]       acc_qvalid_i;
  logic [CORE_COUNT-1:0]       acc_qready_o;
  logic [CORE_COUNT*5-1:0]     acc_qid_i;
  logic [CORE_COUNT*32-1:0]    acc_qop_i;
  logic [CORE_COUNT*32-1:0]    acc_qarga_i;
  logic [CORE_COUNT*32-1:0]    acc_qargb_i;
  logic [CORE_COUNT*32-1:0]    acc_qargc_i;

  logic [CORE_COUNT-1:0]       acc_pvalid_o;
  logic [CORE_COUNT-1:0]       acc_pready_i;
  logic [CORE_COUNT*5-1:0]     acc_pid_o;
  logic [CORE_COUNT*32-1:0]    acc_pdata_o;
  logic [CORE_COUNT-1:0]       acc_perror_o;

  logic                        ptw_mem_qvalid_o;
  logic                        ptw_mem_qready_i;
  logic [ADDR_W-1:0]           ptw_mem_qaddr_o;
  logic [2:0]                  ptw_mem_qsize_o;
  logic                        ptw_mem_pvalid_i;
  logic                        ptw_mem_pready_o;
  logic [31:0]                 ptw_mem_pdata_i;
  logic                        ptw_mem_perror_i;

  snitch_iso_cluster_subsys #(
    .CoreCount    ( CORE_COUNT ),
    .AddrWidth    ( ADDR_W     ),
    .DataWidth    ( DATA_W     ),
    .NrTlbEntries ( 2          )
  ) dut (
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

  // Sparse page-table memory + programmable bus-error address
  logic [31:0] pt_mem [logic [ADDR_W-1:2]];
  logic        err_inject_en;
  logic [ADDR_W-1:0] err_inject_addr;
  int unsigned ptw_read_count;

  function automatic logic [31:0] make_pte(
    input logic [21:0] ppn,
    input logic d, input logic a, input logic g, input logic u,
    input logic x, input logic w, input logic r, input logic v
  );
    return {ppn, 2'b00, d, a, g, u, x, w, r, v};
  endfunction

  function automatic logic [31:0] ref_rv32m(
    input logic [31:0] op,
    input logic [31:0] a,
    input logic [31:0] b,
    output logic       is_err
  );
    logic signed [63:0] ss, su;
    logic [63:0]        uu;
    is_err = 1'b0;
    ss = $signed({{32{a[31]}}, a}) * $signed({{32{b[31]}}, b});
    su = $signed({{32{a[31]}}, a}) * $signed({32'b0, b});
    uu = {32'b0, a} * {32'b0, b};
    case (op)
      OP_MUL:    return uu[31:0];
      OP_MULH:   return ss[63:32];
      OP_MULHSU: return su[63:32];
      OP_MULHU:  return uu[63:32];
      OP_DIV: begin
        if (b == 32'h0) return 32'hFFFF_FFFF;
        if (a == 32'h8000_0000 && b == 32'hFFFF_FFFF) return 32'h8000_0000;
        return 32'($signed(a) / $signed(b));
      end
      OP_DIVU: begin
        if (b == 32'h0) return 32'hFFFF_FFFF;
        return a / b;
      end
      OP_REM: begin
        if (b == 32'h0) return a;
        if (a == 32'h8000_0000 && b == 32'hFFFF_FFFF) return 32'h0;
        return 32'($signed(a) % $signed(b));
      end
      OP_REMU: begin
        if (b == 32'h0) return a;
        return a % b;
      end
      default: begin
        is_err = 1'b1;
        return 32'h0;
      end
    endcase
  endfunction

  // PTW memory slave responder in clk_i domain
  logic        mem_pend_q;
  logic [31:0] mem_rdata_q;
  logic        mem_rerr_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      mem_pend_q     <= 1'b0;
      mem_rdata_q    <= 32'h0;
      mem_rerr_q     <= 1'b0;
      ptw_read_count <= 0;
    end else begin
      if (ptw_mem_qvalid_o && ptw_mem_qready_i) begin
        if (ptw_mem_qsize_o !== 3'd2) begin
          $display("ERROR: PTW qsize expected 2, got %0d", ptw_mem_qsize_o);
          $finish(1);
        end
        mem_pend_q     <= 1'b1;
        mem_rdata_q    <= pt_mem.exists(ptw_mem_qaddr_o[ADDR_W-1:2]) ? pt_mem[ptw_mem_qaddr_o[ADDR_W-1:2]] : 32'h0;
        mem_rerr_q     <= err_inject_en && (ptw_mem_qaddr_o == err_inject_addr);
        ptw_read_count <= ptw_read_count + 1;
      end else if (mem_pend_q && ptw_mem_pready_o) begin
        mem_pend_q <= 1'b0;
      end
    end
  end
  assign ptw_mem_qready_i = ~mem_pend_q;
  assign ptw_mem_pvalid_i = mem_pend_q;
  assign ptw_mem_pdata_i  = mem_rdata_q;
  assign ptw_mem_perror_i = mem_rerr_q;

  task automatic reset_dut(input logic byp);
    rst_ni          = 1'b0;
    test_mode_i     = 1'b0;
    clk_d2_bypass_i = byp;
    tlb_req_valid_i = '0;
    tlb_req_flush_i = '0;
    tlb_req_va_i    = '0;
    tlb_req_ppn_i   = '0;
    tlb_req_priv_i  = '0;
    tlb_req_read_i  = '0;
    tlb_req_write_i = '0;
    tlb_req_exec_i  = '0;
    tlb_rsp_ready_i = '1;
    acc_qvalid_i    = '0;
    acc_qid_i       = '0;
    acc_qop_i       = '0;
    acc_qarga_i     = '0;
    acc_qargb_i     = '0;
    acc_qargc_i     = '0;
    acc_pready_i    = '1;
    err_inject_en   = 1'b0;
    err_inject_addr = '0;
    repeat (8) @(posedge clk_i);
    #0.2 rst_ni = 1'b1;
    repeat (6) @(posedge clk_i);
  endtask

  task automatic do_tlb_req(
    input  int unsigned ch,
    input  logic        is_flush,
    input  logic [19:0] va,
    input  logic [21:0] root_ppn,
    input  logic [1:0]  priv,
    input  logic        rd,
    input  logic        wr,
    input  logic        ex,
    output logic [21:0] got_pa,
    output logic        got_fault,
    input  string       tag
  );
    int unsigned guard;
    @(negedge clk_i);
    tlb_req_valid_i[ch]          = 1'b1;
    tlb_req_flush_i[ch]          = is_flush;
    tlb_req_va_i[ch*20 +: 20]    = va;
    tlb_req_ppn_i[ch*PPN_W +: PPN_W] = root_ppn;
    tlb_req_priv_i[ch*2 +: 2]    = priv;
    tlb_req_read_i[ch]           = rd;
    tlb_req_write_i[ch]          = wr;
    tlb_req_exec_i[ch]           = ex;
    guard = 0;
    forever begin
      @(posedge clk_i);
      if (tlb_req_valid_i[ch] && tlb_req_ready_o[ch]) break;
      guard++;
      if (guard > 300) begin
        $display("ERROR [%s]: TLB req timeout on ch=%0d", tag, ch);
        $finish(1);
      end
    end
    @(negedge clk_i);
    tlb_req_valid_i[ch] = 1'b0;
    tlb_req_flush_i[ch] = 1'b0;

    guard = 0;
    forever begin
      @(posedge clk_i);
      if (tlb_rsp_valid_o[ch] && tlb_rsp_ready_i[ch]) begin
        got_pa    = tlb_rsp_pa_o[ch*PPN_W +: PPN_W];
        got_fault = tlb_rsp_fault_o[ch];
        break;
      end
      guard++;
      if (guard > 400) begin
        $display("ERROR [%s]: TLB rsp timeout on ch=%0d", tag, ch);
        $finish(1);
      end
    end
    if (^got_fault === 1'bx || (!is_flush && !got_fault && (^got_pa === 1'bx))) begin
      $display("ERROR [%s]: X detected on TLB rsp ch=%0d", tag, ch);
      $finish(1);
    end
  endtask

  task automatic run_full_suite(input logic byp_mode, input int unsigned seed);
    logic [21:0] root_ppn, l0_ppn, pa_got;
    logic        flt_got;
    int unsigned rd_before, c, k, guard;
    logic [31:0] prng;
    logic [CORE_COUNT-1:0] pend_acc;
    logic [31:0] exp_data [CORE_COUNT][32];
    logic        exp_err  [CORE_COUNT][32];
    bit          exp_vld  [CORE_COUNT][32];

    reset_dut(byp_mode);
    pt_mem.delete();
    root_ppn = 22'h00_1000;
    l0_ppn   = 22'h00_2000;

    // Populate Sv32 page tables:
    // vpn1=10'h010 -> pointer to l0_ppn
    pt_mem[{root_ppn, 10'h010}] = make_pte(l0_ppn, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b1);
    // vpn0=10'h001 -> U-mode RWX leaf (ppn=22'h05_0001)
    pt_mem[{l0_ppn, 10'h001}]   = make_pte(22'h05_0001, 1'b1, 1'b1, 1'b0, 1'b1, 1'b1, 1'b1, 1'b1, 1'b1);
    // vpn0=10'h002 -> U-mode Execute-Only leaf (X=1, R=0, W=0, A=1, U=1)
    pt_mem[{l0_ppn, 10'h002}]   = make_pte(22'h05_0002, 1'b0, 1'b1, 1'b0, 1'b1, 1'b1, 1'b0, 1'b0, 1'b1);
    // vpn0=10'h003 -> S-mode RW leaf (U=0, D=1, A=1, W=1, R=1)
    pt_mem[{l0_ppn, 10'h003}]   = make_pte(22'h05_0003, 1'b1, 1'b1, 1'b0, 1'b0, 1'b0, 1'b1, 1'b1, 1'b1);
    // vpn0=10'h004 -> U-mode clean RW leaf (D=0 -> write must fault, read must pass)
    pt_mem[{l0_ppn, 10'h004}]   = make_pte(22'h05_0004, 1'b0, 1'b1, 1'b0, 1'b1, 1'b0, 1'b1, 1'b1, 1'b1);
    // vpn0=10'h005 -> non-leaf pointer at level 0 (V=1, R=0, W=0, X=0, A=1) -> 2-level pointer fault!
    pt_mem[{l0_ppn, 10'h005}]   = make_pte(22'h05_0005, 1'b1, 1'b1, 1'b0, 1'b1, 1'b0, 1'b0, 1'b0, 1'b1);
    // vpn1=10'h020 -> valid 4 MiB superpage (ppn1=12'h0AB, ppn0=10'h000, U=1, R=1, W=1, X=1, A=1, D=1)
    pt_mem[{root_ppn, 10'h020}] = make_pte({12'h0AB, 10'h000}, 1'b1, 1'b1, 1'b0, 1'b1, 1'b1, 1'b1, 1'b1, 1'b1);
    // vpn1=10'h021 -> misaligned 4 MiB superpage (ppn0=10'h007 != 0) -> must fault & NOT poison vpn1 as superpage!
    pt_mem[{root_ppn, 10'h021}] = make_pte({12'h0AC, 10'h007}, 1'b1, 1'b1, 1'b0, 1'b1, 1'b1, 1'b1, 1'b1, 1'b1);
    // vpn1=10'h022 -> valid 4 MiB superpage used to test L1 bus-error non-poisoning
    pt_mem[{root_ppn, 10'h022}] = make_pte({12'h0AD, 10'h000}, 1'b1, 1'b1, 1'b0, 1'b1, 1'b1, 1'b1, 1'b1, 1'b1);

    // T1: Dual-port ITLB (j=0) & DTLB (j=1) across all cores + 4MiB superpage on DTLB
    for (c = 0; c < CORE_COUNT; c++) begin
      do_tlb_req(2*c+0, 1'b0, {10'h010, 10'h001}, root_ppn, PRIV_U, 1'b0, 1'b0, 1'b1, pa_got, flt_got, "T1_itlb_4k");
      if (flt_got || pa_got !== 22'h05_0001) begin $display("ERROR: T1_itlb_4k core=%0d flt=%0b pa=%h", c, flt_got, pa_got); $finish(1); end

      do_tlb_req(2*c+1, 1'b0, {10'h020, 10'h15A + c[9:0]}, root_ppn, PRIV_U, 1'b1, 1'b1, 1'b0, pa_got, flt_got, "T1_dtlb_4m");
      if (flt_got || pa_got !== {12'h0AB, 10'h15A + c[9:0]}) begin
        $display("ERROR: T1_dtlb_4m core=%0d flt=%0b pa=%h", c, flt_got, pa_got); $finish(1);
      end
    end

    // T2: 2-entry L0 TLB round-robin retention & flush coherence on ch=1 (Core 0 DTLB)
    do_tlb_req(1, 1'b1, 20'h0, root_ppn, PRIV_U, 1'b0, 1'b0, 1'b0, pa_got, flt_got, "T2_flush0");
    do_tlb_req(1, 1'b0, {10'h010, 10'h001}, root_ppn, PRIV_U, 1'b1, 1'b0, 1'b0, pa_got, flt_got, "T2_fill_slot0");
    do_tlb_req(1, 1'b0, {10'h010, 10'h003}, root_ppn, PRIV_S, 1'b1, 1'b1, 1'b0, pa_got, flt_got, "T2_fill_slot1");
    rd_before = ptw_read_count;
    do_tlb_req(1, 1'b0, {10'h010, 10'h001}, root_ppn, PRIV_U, 1'b1, 1'b0, 1'b0, pa_got, flt_got, "T2_hit_slot0");
    if (flt_got || pa_got !== 22'h05_0001) begin $display("ERROR: T2_hit_slot0"); $finish(1); end
    do_tlb_req(1, 1'b0, {10'h010, 10'h003}, root_ppn, PRIV_S, 1'b1, 1'b1, 1'b0, pa_got, flt_got, "T2_hit_slot1");
    if (flt_got || pa_got !== 22'h05_0003) begin $display("ERROR: T2_hit_slot1"); $finish(1); end
    if (ptw_read_count !== rd_before) begin
      $display("ERROR: T2 expected 0 PTW reads on 2-entry L0 TLB hits, got %0d", ptw_read_count - rd_before);
      $finish(1);
    end
    // Remap vpn0=10'h001 in memory, flush, and verify new PA
    pt_mem[{l0_ppn, 10'h001}] = make_pte(22'h09_ABCD, 1'b1, 1'b1, 1'b0, 1'b1, 1'b1, 1'b1, 1'b1, 1'b1);
    do_tlb_req(1, 1'b1, 20'h0, root_ppn, PRIV_U, 1'b0, 1'b0, 1'b0, pa_got, flt_got, "T2_flush1");
    do_tlb_req(1, 1'b0, {10'h010, 10'h001}, root_ppn, PRIV_U, 1'b1, 1'b0, 1'b0, pa_got, flt_got, "T2_post_flush");
    if (flt_got || pa_got !== 22'h09_ABCD) begin $display("ERROR: T2_post_flush pa=%h flt=%0b", pa_got, flt_got); $finish(1); end

    // T3: Permission matrix (Execute-only X=1,R=0 + D=0 write fault + U/S privilege fault)
    do_tlb_req(0, 1'b0, {10'h010, 10'h002}, root_ppn, PRIV_U, 1'b0, 1'b0, 1'b1, pa_got, flt_got, "T3_xo_exec");
    if (flt_got || pa_got !== 22'h05_0002) begin $display("ERROR: T3 execute-only fetch faulted! flt=%0b", flt_got); $finish(1); end
    do_tlb_req(1, 1'b0, {10'h010, 10'h002}, root_ppn, PRIV_U, 1'b1, 1'b0, 1'b0, pa_got, flt_got, "T3_xo_read_must_fault");
    if (!flt_got) begin $display("ERROR: T3 read on execute-only page (R=0) allowed!"); $finish(1); end
    do_tlb_req(1, 1'b0, {10'h010, 10'h004}, root_ppn, PRIV_U, 1'b0, 1'b1, 1'b0, pa_got, flt_got, "T3_dirty0_wr_fault");
    if (!flt_got) begin $display("ERROR: T3 write on D=0 page allowed!"); $finish(1); end
    do_tlb_req(1, 1'b0, {10'h010, 10'h003}, root_ppn, PRIV_U, 1'b1, 1'b0, 1'b0, pa_got, flt_got, "T3_smode_in_umode");
    if (!flt_got) begin $display("ERROR: T3 S-page accessed in U-mode allowed!"); $finish(1); end

    // T4: PTW fault containment (2-level pointer fault + misaligned superpage + L1 bus error non-poisoning)
    do_tlb_req(0, 1'b0, {10'h010, 10'h005}, root_ppn, PRIV_U, 1'b0, 1'b0, 1'b0, pa_got, flt_got, "T4_lvl2_ptr_probe_fault");
    if (!flt_got) begin $display("ERROR: T4 2-level non-leaf pointer probe did not fault!"); $finish(1); end
    do_tlb_req(0, 1'b0, {10'h010, 10'h005}, root_ppn, PRIV_U, 1'b1, 1'b0, 1'b0, pa_got, flt_got, "T4_lvl2_ptr_fault");
    if (!flt_got) begin $display("ERROR: T4 2-level non-leaf pointer walk did not fault!"); $finish(1); end
    do_tlb_req(0, 1'b0, {10'h021, 10'h001}, root_ppn, PRIV_U, 1'b1, 1'b0, 1'b0, pa_got, flt_got, "T4_misalign_4m");
    if (!flt_got) begin $display("ERROR: T4 misaligned superpage did not fault!"); $finish(1); end
    pt_mem[{root_ppn, 10'h021}] = make_pte(l0_ppn, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b0, 1'b1);
    do_tlb_req(0, 1'b0, {10'h021, 10'h002}, root_ppn, PRIV_U, 1'b0, 1'b0, 1'b1, pa_got, flt_got, "T4_misalign_no_4m_poison");
    if (flt_got || pa_got !== 22'h05_0002) begin
      $display("ERROR: T4 misaligned superpage poisoned 4MiB superpage tag! flt=%0b pa=%h", flt_got, pa_got);
      $finish(1);
    end
    // Inject transient L1 bus error on vpn1=10'h022, vpn0=10'h001, then clear error and access vpn0=10'h002!
    err_inject_en   = 1'b1;
    err_inject_addr = {root_ppn, 10'h022, 2'b00};
    do_tlb_req(0, 1'b0, {10'h022, 10'h001}, root_ppn, PRIV_U, 1'b1, 1'b0, 1'b0, pa_got, flt_got, "T4_bus_err_v1");
    if (!flt_got) begin $display("ERROR: T4 PTW bus error did not fault!"); $finish(1); end
    err_inject_en = 1'b0;
    do_tlb_req(0, 1'b0, {10'h022, 10'h002}, root_ppn, PRIV_U, 1'b1, 1'b0, 1'b0, pa_got, flt_got, "T4_no_4m_poison");
    if (flt_got || pa_got !== {12'h0AD, 10'h002}) begin
      $display("ERROR: T4 bus-errored L1 walk poisoned 4MiB superpage tag! flt=%0b pa=%h", flt_got, pa_got);
      $finish(1);
    end

    // T5: Concurrent multi-core RV32M + illegal-opcode error retirement stress
    prng = seed ^ (byp_mode ? 32'hA5A5_5A5A : 32'h5A5A_A5A5);
    for (c = 0; c < CORE_COUNT; c++) for (k = 0; k < 32; k++) exp_vld[c][k] = 0;

    for (int iter = 0; iter < 40; iter++) begin
      logic [31:0] op_sel, arg_a, arg_b, exp_r;
      logic        exp_e;
      logic [4:0]  tid;
      // Launch across all cores concurrently in this wave
      @(negedge clk_i);
      for (c = 0; c < CORE_COUNT; c++) begin
        prng = {prng[30:0], prng[31] ^ prng[21] ^ prng[1] ^ prng[0]} + 32'h9E37_79B9;
        tid  = 5'((iter + c) & 31);
        case ((iter + c) % 10)
          0: op_sel = OP_MUL;
          1: op_sel = OP_MULH;
          2: op_sel = OP_MULHSU;
          3: op_sel = OP_MULHU;
          4: op_sel = OP_DIV;
          5: op_sel = OP_DIVU;
          6: op_sel = OP_REM;
          7: op_sel = OP_REMU;
          8: op_sel = OP_ILL_ADD;
          default: op_sel = OP_ILL_FF;
        endcase
        if (iter < 8) begin
          case (iter)
            0: begin arg_a = 32'h8000_0000; arg_b = 32'hFFFF_FFFF; end
            1: begin arg_a = 32'hFFFF_FFFF; arg_b = 32'hFFFF_FFFF; end
            2: begin arg_a = 32'h1234_5678; arg_b = 32'h0000_0000; end
            3: begin arg_a = 32'h8000_0000; arg_b = 32'h8000_0000; end
            4: begin arg_a = 32'h0000_0005; arg_b = 32'hFFFF_FFF6; end
            5: begin arg_a = 32'hFFFF_FFFB; arg_b = 32'h0000_000A; end
            6: begin arg_a = 32'h7FFF_FFFF; arg_b = 32'h7FFF_FFFF; end
            default: begin op_sel = OP_DIV; arg_a = 32'h0000_0000; arg_b = 32'h0000_0000; end
          endcase
        end else begin
          arg_a = prng ^ (32'(c) << 16);
          prng  = {prng[30:0], prng[31] ^ prng[21] ^ prng[1] ^ prng[0]};
          arg_b = prng;
        end
        exp_r = ref_rv32m(op_sel, arg_a, arg_b, exp_e);
        exp_data[c][tid] = exp_r;
        exp_err[c][tid]  = exp_e;
        exp_vld[c][tid]  = 1;

        acc_qvalid_i[c]        = 1'b1;
        acc_qid_i[c*5 +: 5]    = tid;
        acc_qop_i[c*32 +: 32]  = op_sel;
        acc_qarga_i[c*32 +: 32]= arg_a;
        acc_qargb_i[c*32 +: 32]= arg_b;
      end

      pend_acc = '1;
      guard = 0;
      while (|pend_acc || exp_vld_any(exp_vld)) begin
        logic [CORE_COUNT-1:0] q_acc_now;
        @(posedge clk_i);
        guard++;
        if (guard > 600) begin
          $display("ERROR: T5 MulDiv/Illegal-op deadlock or timeout (iter=%0d byp=%0b)", iter, byp_mode);
          $finish(1);
        end
        for (c = 0; c < CORE_COUNT; c++) begin
          q_acc_now[c] = pend_acc[c] && acc_qvalid_i[c] && acc_qready_o[c];
          if (acc_pvalid_o[c] && acc_pready_i[c]) begin
            logic [4:0] rid;
            rid = acc_pid_o[c*5 +: 5];
            if (!exp_vld[c][rid]) begin
              $display("ERROR: Unexpected acc rsp core=%0d id=%0d", c, rid);
              $finish(1);
            end
            if (acc_perror_o[c] !== exp_err[c][rid]) begin
              $display("ERROR: acc_perror mismatch core=%0d id=%0d got=%0b exp=%0b", c, rid, acc_perror_o[c], exp_err[c][rid]);
              $finish(1);
            end
            if (!exp_err[c][rid] && acc_pdata_o[c*32 +: 32] !== exp_data[c][rid]) begin
              $display("ERROR: acc_pdata mismatch core=%0d id=%0d got=%h exp=%h", c, rid, acc_pdata_o[c*32 +: 32], exp_data[c][rid]);
              $finish(1);
            end
            exp_vld[c][rid] = 0;
          end
        end
        @(negedge clk_i);
        for (c = 0; c < CORE_COUNT; c++) begin
          if (q_acc_now[c]) begin
            acc_qvalid_i[c] = 1'b0;
            pend_acc[c]     = 1'b0;
          end
          acc_pready_i[c] = ((guard + c) % 4 != 0);
        end
      end
      acc_pready_i = '1;
    end
  endtask

  function automatic bit exp_vld_any(ref bit v [CORE_COUNT][32]);
    for (int cc = 0; cc < CORE_COUNT; cc++)
      for (int kk = 0; kk < 32; kk++)
        if (v[cc][kk]) return 1;
    return 0;
  endfunction

  initial begin
    int unsigned seed;
    if (!$value$plusargs("seed=%d", seed)) seed = 101;
    run_full_suite(1'b0, seed);
    run_full_suite(1'b1, seed);
    $display("PASS_RTL cores=%0d seed=%0d", CORE_COUNT, seed);
    $finish(0);
  end
endmodule
