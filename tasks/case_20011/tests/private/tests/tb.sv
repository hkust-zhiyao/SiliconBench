`timescale 1ns/1ps
`include "biriscv_defs.v"

module tb;
    reg clk;
    reg rst;
    int seed;

    initial begin
        clk = 0;
        forever #5 clk = ~clk;
    end

    // Helper function to construct Sv32 PTE: {PPN1[11:0], PPN0[9:0], RSW[1:0], D, A, G, U, X, W, R, V}
    function automatic [31:0] make_pte(
        input [19:0] ppn20,
        input logic d, a, g, u, x, w, r, v
    );
        make_pte = {2'b00, ppn20, 2'b00, d, a, g, u, x, w, r, v};
    endfunction

    // DUT inputs/outputs (SUPPORT_MMU=1)
    reg  [ 1:0] priv_d;
    reg         sum, mxr, flush;
    reg  [31:0] satp;

    reg         f_in_rd, f_in_flush, f_in_inv;
    reg  [31:0] f_in_pc;
    reg  [ 1:0] f_in_priv;
    reg         f_out_accept, f_out_valid, f_out_error;
    reg  [63:0] f_out_inst;

    reg  [31:0] l_in_addr, l_in_wdata;
    reg         l_in_rd;
    reg  [ 3:0] l_in_wr;
    reg         l_in_cacheable;
    reg  [10:0] l_in_tag;
    reg         l_in_inv, l_in_wb, l_in_flush;

    reg  [31:0] l_out_rdata;
    reg         l_out_accept, l_out_ack, l_out_error;
    reg  [10:0] l_out_rtag;

    wire        f_in_accept, f_in_valid, f_in_error, f_in_fault;
    wire [63:0] f_in_inst;
    wire        f_out_rd, f_out_flush, f_out_inv;
    wire [31:0] f_out_pc;

    wire [31:0] l_in_rdata;
    wire        l_in_accept, l_in_ack, l_in_error, l_in_lfault, l_in_sfault;
    wire [10:0] l_in_rtag;

    wire [31:0] l_out_addr, l_out_wdata;
    wire        l_out_rd, l_out_cacheable, l_out_inv, l_out_wb, l_out_flush;
    wire [ 3:0] l_out_wr;
    wire [10:0] l_out_tag;

    biriscv_mmu #(
        .MEM_CACHE_ADDR_MIN(32'h8000_0000),
        .MEM_CACHE_ADDR_MAX(32'h8FFF_FFFF),
        .SUPPORT_MMU(1)
    ) dut (
        .clk_i(clk), .rst_i(rst),
        .priv_d_i(priv_d), .sum_i(sum), .mxr_i(mxr), .flush_i(flush), .satp_i(satp),
        .fetch_in_rd_i(f_in_rd), .fetch_in_flush_i(f_in_flush), .fetch_in_invalidate_i(f_in_inv),
        .fetch_in_pc_i(f_in_pc), .fetch_in_priv_i(f_in_priv),
        .fetch_out_accept_i(f_out_accept), .fetch_out_valid_i(f_out_valid),
        .fetch_out_error_i(f_out_error), .fetch_out_inst_i(f_out_inst),
        .lsu_in_addr_i(l_in_addr), .lsu_in_data_wr_i(l_in_wdata),
        .lsu_in_rd_i(l_in_rd), .lsu_in_wr_i(l_in_wr),
        .lsu_in_cacheable_i(l_in_cacheable), .lsu_in_req_tag_i(l_in_tag),
        .lsu_in_invalidate_i(l_in_inv), .lsu_in_writeback_i(l_in_wb), .lsu_in_flush_i(l_in_flush),
        .lsu_out_data_rd_i(l_out_rdata), .lsu_out_accept_i(l_out_accept),
        .lsu_out_ack_i(l_out_ack), .lsu_out_error_i(l_out_error), .lsu_out_resp_tag_i(l_out_rtag),

        .fetch_in_accept_o(f_in_accept), .fetch_in_valid_o(f_in_valid),
        .fetch_in_error_o(f_in_error), .fetch_in_inst_o(f_in_inst),
        .fetch_out_rd_o(f_out_rd), .fetch_out_flush_o(f_out_flush),
        .fetch_out_invalidate_o(f_out_inv), .fetch_out_pc_o(f_out_pc), .fetch_in_fault_o(f_in_fault),
        .lsu_in_data_rd_o(l_in_rdata), .lsu_in_accept_o(l_in_accept),
        .lsu_in_ack_o(l_in_ack), .lsu_in_error_o(l_in_error), .lsu_in_resp_tag_o(l_in_rtag),
        .lsu_out_addr_o(l_out_addr), .lsu_out_data_wr_o(l_out_wdata),
        .lsu_out_rd_o(l_out_rd), .lsu_out_wr_o(l_out_wr),
        .lsu_out_cacheable_o(l_out_cacheable), .lsu_out_req_tag_o(l_out_tag),
        .lsu_out_invalidate_o(l_out_inv), .lsu_out_writeback_o(l_out_wb), .lsu_out_flush_o(l_out_flush),
        .lsu_in_load_fault_o(l_in_lfault), .lsu_in_store_fault_o(l_in_sfault)
    );

    // SUPPORT_MMU=0 passthrough instance check
    wire [31:0] nommu_f_pc;
    wire        nommu_f_fault, nommu_l_lfault, nommu_l_sfault;
    biriscv_mmu #(.SUPPORT_MMU(0)) dut_nommu (
        .clk_i(clk), .rst_i(rst),
        .priv_d_i(`PRIV_USER), .sum_i(1'b0), .mxr_i(1'b0), .flush_i(1'b0), .satp_i(32'h8008_0000),
        .fetch_in_rd_i(1'b1), .fetch_in_flush_i(1'b0), .fetch_in_invalidate_i(1'b0),
        .fetch_in_pc_i(32'h1234_5678), .fetch_in_priv_i(`PRIV_USER),
        .fetch_out_accept_i(1'b1), .fetch_out_valid_i(1'b0), .fetch_out_error_i(1'b0), .fetch_out_inst_i(64'd0),
        .lsu_in_addr_i(32'h2345_6780), .lsu_in_data_wr_i(32'd0), .lsu_in_rd_i(1'b1), .lsu_in_wr_i(4'b0),
        .lsu_in_cacheable_i(1'b1), .lsu_in_req_tag_i(11'd5),
        .lsu_in_invalidate_i(1'b0), .lsu_in_writeback_i(1'b0), .lsu_in_flush_i(1'b0),
        .lsu_out_data_rd_i(32'd0), .lsu_out_accept_i(1'b1), .lsu_out_ack_i(1'b0), .lsu_out_error_i(1'b0), .lsu_out_resp_tag_i(11'd0),
        .fetch_in_accept_o(), .fetch_in_valid_o(), .fetch_in_error_o(), .fetch_in_inst_o(),
        .fetch_out_rd_o(), .fetch_out_flush_o(), .fetch_out_invalidate_o(), .fetch_out_pc_o(nommu_f_pc), .fetch_in_fault_o(nommu_f_fault),
        .lsu_in_data_rd_o(), .lsu_in_accept_o(), .lsu_in_ack_o(), .lsu_in_error_o(), .lsu_in_resp_tag_o(),
        .lsu_out_addr_o(), .lsu_out_data_wr_o(), .lsu_out_rd_o(), .lsu_out_wr_o(), .lsu_out_cacheable_o(), .lsu_out_req_tag_o(),
        .lsu_out_invalidate_o(), .lsu_out_writeback_o(), .lsu_out_flush_o(),
        .lsu_in_load_fault_o(nommu_l_lfault), .lsu_in_store_fault_o(nommu_l_sfault)
    );

    // Sparse physical memory + pipelined D-cache / I-cache responder model
    logic [31:0] pmem [logic [31:2]];

    typedef struct packed {
        int          rem;
        logic [31:0] addr;
        logic [31:0] rdata;
        logic [31:0] wdata;
        logic [ 3:0] wr;
        logic [10:0] tag;
        logic        err;
    } dreq_t;
    dreq_t dqueue[$];

    typedef struct packed {
        int          rem;
        logic [31:0] pc;
    } ireq_t;
    ireq_t iqueue[$];

    int d_default_lat;
    int i_default_lat;
    int ptw_read_count;

    always @(posedge clk) begin
        if (rst) begin
            dqueue.delete();
            iqueue.delete();
            l_out_ack   <= 1'b0;
            l_out_error <= 1'b0;
            l_out_rdata <= 32'd0;
            l_out_rtag  <= 11'd0;
            f_out_valid <= 1'b0;
            f_out_error <= 1'b0;
            f_out_inst  <= 64'd0;
            ptw_read_count <= 0;
        end else begin
            // Capture downstream D-cache/PTW request on handshake
            if ((l_out_rd || (|l_out_wr) || l_out_inv || l_out_wb || l_out_flush) && l_out_accept) begin
                dreq_t nr;
                nr.rem   = (l_out_tag[9:7] == 3'b111) ? 2 : d_default_lat;
                nr.addr  = l_out_addr;
                nr.wdata = l_out_wdata;
                nr.wr    = l_out_wr;
                nr.tag   = l_out_tag;
                nr.err   = (l_out_addr[31:28] == 4'hF); // 0xFxxx_xxxx simulates bus error
                nr.rdata = nr.err ? 32'hFFFF_FFFF : (pmem.exists(l_out_addr[31:2]) ? pmem[l_out_addr[31:2]] : 32'd0);
                if (l_out_tag[9:7] == 3'b111)
                    ptw_read_count <= ptw_read_count + 1;
                if (|l_out_wr && !nr.err) begin
                    logic [31:0] cur;
                    cur = pmem.exists(l_out_addr[31:2]) ? pmem[l_out_addr[31:2]] : 32'd0;
                    if (l_out_wr[0]) cur[ 7: 0] = l_out_wdata[ 7: 0];
                    if (l_out_wr[1]) cur[15: 8] = l_out_wdata[15: 8];
                    if (l_out_wr[2]) cur[23:16] = l_out_wdata[23:16];
                    if (l_out_wr[3]) cur[31:24] = l_out_wdata[31:24];
                    pmem[l_out_addr[31:2]] = cur;
                end
                dqueue.push_back(nr);
            end

            // Step D-queue (in-order ack)
            l_out_ack   <= 1'b0;
            l_out_error <= 1'b0;
            for (int k = 0; k < dqueue.size(); k++) begin
                if (dqueue[k].rem > 0) dqueue[k].rem--;
            end
            if (dqueue.size() > 0 && dqueue[0].rem == 0) begin
                dreq_t c;
                c = dqueue.pop_front();
                l_out_ack   <= 1'b1;
                l_out_error <= c.err;
                l_out_rtag  <= c.tag;
                l_out_rdata <= c.rdata;
            end

            // Capture downstream I-cache request
            if (f_out_flush) begin
                iqueue.delete();
                f_out_valid <= 1'b0;
            end else begin
                if (f_out_rd && f_out_accept) begin
                    ireq_t ir;
                    ir.rem = i_default_lat;
                    ir.pc  = f_out_pc;
                    iqueue.push_back(ir);
                end
                f_out_valid <= 1'b0;
                f_out_error <= 1'b0;
                for (int k = 0; k < iqueue.size(); k++) begin
                    if (iqueue[k].rem > 0) iqueue[k].rem--;
                end
                if (iqueue.size() > 0 && iqueue[0].rem == 0) begin
                    ireq_t ic;
                    ic = iqueue.pop_front();
                    f_out_valid <= 1'b1;
                    f_out_error <= 1'b0;
                    f_out_inst  <= {32'hCAFE_0000 ^ ic.pc, ic.pc};
                end
            end
        end
    end

    task automatic reset_all();
        rst = 1'b1;
        priv_d = `PRIV_SUPER; sum = 0; mxr = 0; flush = 0; satp = 32'd0;
        f_in_rd = 0; f_in_flush = 0; f_in_inv = 0; f_in_pc = 32'd0; f_in_priv = `PRIV_SUPER;
        f_out_accept = 1'b1;
        l_in_addr = 32'd0; l_in_wdata = 32'd0; l_in_rd = 0; l_in_wr = 4'b0;
        l_in_cacheable = 1'b1; l_in_tag = 11'd0; l_in_inv = 0; l_in_wb = 0; l_in_flush = 0;
        l_out_accept = 1'b1;
        d_default_lat = 1;
        i_default_lat = 1;
        repeat (4) @(posedge clk);
        #1; rst = 1'b0;
        @(posedge clk); #1;
    endtask

    initial begin
        int cyc, pre_ptw;
        if (!$value$plusargs("seed=%d", seed)) seed = 101;
        reset_all();

        if (nommu_f_pc !== 32'h1234_5678 || nommu_f_fault !== 1'b0 || nommu_l_lfault !== 1'b0 || nommu_l_sfault !== 1'b0) begin
            $display("FAIL Test0: SUPPORT_MMU=0 passthrough broken!"); $finish(1);
        end

        // -----------------------------------------------------------------
        // Test 1: Bare mode when satp[31]==0 in U/S mode (Bug 1: vm_i_enable_w!)
        // -----------------------------------------------------------------
        satp = 32'h0008_0010; // MODE=0 (Bare!), non-zero PPN
        f_in_priv = `PRIV_USER;
        f_in_pc   = 32'h0040_1000;
        f_in_rd   = 1'b1;
        #1;
        if (!f_in_accept || !f_out_rd || f_out_pc !== 32'h0040_1000) begin
            $display("FAIL Test1: S/U-mode I-fetch with satp.MODE==0 failed Bare bypass! acc=%b rd=%b out_pc=%h",
                     f_in_accept, f_out_rd, f_out_pc);
            $finish(1);
        end
        @(posedge clk); #1; f_in_rd = 1'b0;
        cyc = 0;
        while (!f_in_valid && cyc < 30) begin @(posedge clk); #1; cyc++; end
        if (!f_in_valid || f_in_fault || f_in_error || f_in_inst[31:0] !== 32'h0040_1000) begin
            $display("FAIL Test1b: Bare fetch faulted or returned wrong PC!"); $finish(1);
        end
        @(posedge clk); #1;

        // -----------------------------------------------------------------
        // Setup Sv32 Page Tables at Root PPN = 20'h80010 (phys 0x8001_0000):
        //   - VPN1 = 10'h100 (VA 0x4000_0000..0x403F_FFFF) -> L2 table at PPN 20'h80020 (phys 0x8002_0000)
        //       * VPN0 = 10'h001 (VA 0x4000_1000): S-mode RX+RW (D=1,A=1,U=0,X=1,W=1,R=1,V=1) -> PPN 20'h80101
        //       * VPN0 = 10'h002 (VA 0x4000_2000): U-mode Exec-Only (D=0,A=1,U=1,X=1,W=0,R=0,V=1) -> PPN 20'h80102
        //       * VPN0 = 10'h003 (VA 0x4000_3000): Reserved W=1,R=0,X=1 (D=1,A=1,U=0,X=1,W=1,R=0,V=1) -> MUST FAULT!
        //       * VPN0 = 10'h004 (VA 0x4000_4000): A=0 leaf (D=1,A=0,U=0,X=1,W=1,R=1,V=1) -> MUST FAULT!
        //       * VPN0 = 10'h005 (VA 0x4000_5000): D=0 writable leaf (D=0,A=1,U=0,X=0,W=1,R=1,V=1) -> load OK, store FAULT!
        //       * VPN0 = 10'h006 (VA 0x4000_6000): Level-2 non-leaf pointer (V=1,R=0,W=0,X=0) -> MUST FAULT!
        //   - VPN1 = 10'h101 (VA 0x4040_0000..0x407F_FFFF) -> Valid 4 MiB Superpage (PPN = {10'h204, 10'd0}, D=1,A=1,U=0,X=1,W=1,R=1,V=1)
        //   - VPN1 = 10'h102 (VA 0x4080_0000..0x40BF_FFFF) -> MISALIGNED 4 MiB Superpage (PPN = {10'h208, 10'h005}, D=1,A=1,U=0,X=1,W=1,R=1,V=1) -> MUST FAULT!
        // -----------------------------------------------------------------
        pmem[32'h8001_0400 >> 2] = make_pte(20'h80020, 0,0,0,0, 0,0,0, 1); // VPN1=0x100 -> L2 @ 0x8002_0000
        pmem[32'h8002_0004 >> 2] = make_pte(20'h80101, 1,1,0,0, 1,1,1, 1); // VA 0x4000_1000 -> PA 0x8010_1000
        pmem[32'h8002_0008 >> 2] = make_pte(20'h80102, 0,1,0,1, 1,0,0, 1); // VA 0x4000_2000 -> PA 0x8010_2000 (U, X-only)
        pmem[32'h8002_000C >> 2] = make_pte(20'h80103, 1,1,0,0, 1,1,0, 1); // VA 0x4000_3000 -> Reserved W=1,R=0
        pmem[32'h8002_0010 >> 2] = make_pte(20'h80104, 1,0,0,0, 1,1,1, 1); // VA 0x4000_4000 -> A=0
        pmem[32'h8002_0014 >> 2] = make_pte(20'h80105, 0,1,0,0, 0,1,1, 1); // VA 0x4000_5000 -> D=0
        pmem[32'h8002_0018 >> 2] = make_pte(20'h80106, 0,0,0,0, 0,0,0, 1); // VA 0x4000_6000 -> L2 non-leaf!

        pmem[32'h8001_0404 >> 2] = make_pte({10'h204, 10'd0},   1,1,0,0, 1,1,1, 1); // VPN1=0x101 -> aligned 4MB superpage (PA 0x8100_0000 + offset)
        pmem[32'h8001_0408 >> 2] = make_pte({10'h208, 10'h005}, 1,1,0,0, 1,1,1, 1); // VPN1=0x102 -> MISALIGNED superpage!
        pmem[32'h8010_1000 >> 2] = 32'h1122_3344;
        pmem[32'h8010_2000 >> 2] = 32'h5566_7788;
        pmem[32'h8010_5000 >> 2] = 32'h99AA_BBCC;
        pmem[32'h8112_3000 >> 2] = 32'hDEAD_C0DE; // Superpage VPN1=0x101, VPN0=0x123 -> {10'h204, 10'h123, 12'h000} = 0x8112_3000!

        satp = 32'h8008_0010; // MODE=1, PPN=20'h80010
        flush = 1'b1; @(posedge clk); #1; flush = 1'b0;

        // -----------------------------------------------------------------
        // Test 2: Single-Walk ITLB Fill + Mid-Walk PC Redirect Address-Drift Immunity!
        //   Start I-fetch at VA 0x4000_1000; 1 cycle into PTW, redirect fetch_in_pc_i to 0x4000_2000!
        //   Walk MUST still complete cleanly for 0x4000_1000 (exactly 2 PTW reads) without corrupting TLB!
        // -----------------------------------------------------------------
        pre_ptw   = ptw_read_count;
        f_in_priv = `PRIV_SUPER;
        f_in_pc   = 32'h4000_1000;
        f_in_rd   = 1'b1;
        @(posedge clk); #1; // PTW started on 0x4000_1000!
        // Redirect fetch_in_pc_i mid-walk to 0x4000_2000 (different VPN0 = 2)!
        f_in_pc   = 32'h4000_2000;
        repeat (5) @(posedge clk); #1;
        // Now return fetch_in_pc_i to 0x4000_1008 -> MUST hit the installed 0x4000_1000 ITLB entry with ZERO additional PTW reads!
        f_in_pc   = 32'h4000_1008;
        cyc = 0;
        while (!f_in_accept && cyc < 20) begin @(posedge clk); #1; cyc++; end
        if (!f_in_accept || f_out_pc !== 32'h8010_1008 || (ptw_read_count - pre_ptw) != 2) begin
            $display("FAIL Test2: Mid-walk PC redirect corrupted ITLB or caused double-walk! acc=%b out_pc=%h ptw_reads=%0d",
                     f_in_accept, f_out_pc, ptw_read_count - pre_ptw);
            $finish(1);
        end
        @(posedge clk); #1; f_in_rd = 1'b0;
        cyc = 0;
        while (!f_in_valid && cyc < 30) begin @(posedge clk); #1; cyc++; end
        if (!f_in_valid || f_in_fault || f_in_error || f_in_inst[31:0] !== 32'h8010_1008) begin
            $display("FAIL Test2b: Post-walk I-fetch failed! valid=%b fault=%b inst=%h",
                     f_in_valid, f_in_fault, f_in_inst);
            $finish(1);
        end
        @(posedge clk); #1;

        // -----------------------------------------------------------------
        // Test 3: 4 MiB Superpage Alignment (Aligned 0x4052_3000 -> PA 0x8112_3000 vs Misaligned 0x4080_0000 -> Page Fault!)
        // -----------------------------------------------------------------
        // 3a: Aligned superpage D-load (also test 1-cycle pulse on l_in_rd to verify stalled D-request retention!)
        priv_d    = `PRIV_SUPER;
        l_in_addr = 32'h4052_3000;
        l_in_rd   = 1'b1;
        l_in_tag  = 11'h02A;
        @(posedge clk); #1;
        l_in_rd   = 1'b0; // Pulse dropped while stalled in PTW!
        l_in_addr = 32'h0000_0000;
        l_in_tag  = 11'h000;
        cyc = 0;
        while (!l_in_ack && cyc < 30) begin @(posedge clk); #1; cyc++; end
        if (!l_in_ack || l_in_error || l_in_lfault || l_in_sfault || l_in_rdata !== 32'hDEAD_C0DE || l_in_rtag !== 11'h02A) begin
            $display("FAIL Test3a: Aligned 4MB superpage pulsed D-load failed! ack=%b err=%b rdata=%h rtag=%h",
                     l_in_ack, l_in_error, l_in_rdata, l_in_rtag);
            $finish(1);
        end
        @(posedge clk); #1;

        // 3b: Misaligned superpage (PPN[0] != 0 at VA 0x4080_1000) -> MUST raise load page fault!
        l_in_addr = 32'h4080_1000;
        l_in_rd   = 1'b1;
        #1;
        cyc = 0;
        while (!l_in_accept && cyc < 30) begin @(posedge clk); #1; cyc++; end
        if (!l_in_accept) begin $display("FAIL Test3b: Timed out waiting for l_in_accept!"); $finish(1); end
        @(posedge clk); #1; l_in_rd = 1'b0; #1;
        cyc = 0;
        while (!l_in_ack && cyc < 30) begin @(posedge clk); #1; cyc++; end
        if (!l_in_ack || !l_in_error || !l_in_lfault || l_in_sfault) begin
            $display("FAIL Test3b: Misaligned 4MB superpage (PPN[0]!=0) did NOT raise load page fault! ack=%b err=%b lf=%b sf=%b",
                     l_in_ack, l_in_error, l_in_lfault, l_in_sfault);
            $finish(1);
        end
        @(posedge clk); #1;

        // -----------------------------------------------------------------
        // Test 4: PTE Validity & Permission Matrix (R=0/W=1 reserved, A=0, D=0, L2 non-leaf, SUM, MXR, S-exec-on-U)
        // -----------------------------------------------------------------
        // 4a: Reserved R=0, W=1, X=1 with MXR=1 -> MUST still fault!
        mxr = 1'b1;
        l_in_addr = 32'h4000_3000; l_in_rd = 1'b1; #1;
        cyc = 0;
        while (!l_in_accept && cyc < 30) begin @(posedge clk); #1; cyc++; end
        if (!l_in_accept) begin $display("FAIL Test4a: Timed out waiting for l_in_accept!"); $finish(1); end
        @(posedge clk); #1; l_in_rd = 1'b0; #1;
        cyc = 0;
        while (!l_in_ack && cyc < 30) begin @(posedge clk); #1; cyc++; end
        if (!l_in_ack || !l_in_error || !l_in_lfault || l_in_sfault) begin $display("FAIL Test4a: Reserved R=0,W=1 PTE did not fault under MXR=1!"); $finish(1); end
        @(posedge clk); #1;

        // 4b: A=0 leaf (0x4000_4000) -> MUST fault on load!
        l_in_addr = 32'h4000_4000; l_in_rd = 1'b1; #1;
        cyc = 0;
        while (!l_in_accept && cyc < 30) begin @(posedge clk); #1; cyc++; end
        if (!l_in_accept) begin $display("FAIL Test4b: Timed out waiting for l_in_accept!"); $finish(1); end
        @(posedge clk); #1; l_in_rd = 1'b0; #1;
        cyc = 0;
        while (!l_in_ack && cyc < 30) begin @(posedge clk); #1; cyc++; end
        if (!l_in_ack || !l_in_error || !l_in_lfault || l_in_sfault) begin $display("FAIL Test4b: A=0 PTE did not fault on load!"); $finish(1); end
        @(posedge clk); #1;

        // 4c: D=0 leaf (0x4000_5000) -> Load SUCCEEDS, Store FAULTS!
        l_in_addr = 32'h4000_5000; l_in_rd = 1'b1; l_in_tag = 11'h041; #1;
        cyc = 0;
        while (!l_in_accept && cyc < 30) begin @(posedge clk); #1; cyc++; end
        if (!l_in_accept) begin $display("FAIL Test4c_1: Timed out waiting for l_in_accept!"); $finish(1); end
        @(posedge clk); #1; l_in_rd = 1'b0; #1;
        cyc = 0;
        while (!l_in_ack && cyc < 30) begin @(posedge clk); #1; cyc++; end
        if (!l_in_ack || l_in_error || l_in_lfault || l_in_sfault || l_in_rdata !== 32'h99AA_BBCC || l_in_rtag !== 11'h041) begin
            $display("FAIL Test4c_1: D=0 PTE load failed! ack=%b err=%b rdata=%h rtag=%h",
                     l_in_ack, l_in_error, l_in_rdata, l_in_rtag);
            $finish(1);
        end
        @(posedge clk); #1;

        l_in_addr = 32'h4000_5000; l_in_wr = 4'hF; l_in_wdata = 32'h1234_5678; l_in_tag = 11'h042; #1;
        cyc = 0;
        while (!l_in_accept && cyc < 30) begin @(posedge clk); #1; cyc++; end
        if (!l_in_accept) begin $display("FAIL Test4c_2: Timed out waiting for l_in_accept!"); $finish(1); end
        @(posedge clk); #1; l_in_wr = 4'h0; #1;
        cyc = 0;
        while (!l_in_ack && cyc < 30) begin @(posedge clk); #1; cyc++; end
        if (!l_in_ack || !l_in_error || !l_in_sfault || l_in_lfault) begin $display("FAIL Test4c_2: D=0 PTE store did NOT fault!"); $finish(1); end
        @(posedge clk); #1;

        // 4d: Level-2 PTW physical bus error (VPN1=0x103 -> L2 table at 0xF002_0000 returning error + 0xFFFF_FFFF with SUM=1) -> MUST fault!
        pmem[32'h8001_040C >> 2] = make_pte(20'hF0020, 0,0,0,0, 0,0,0, 1); // L1 pointer to 0xF002_0000 (bus error region!)
        sum = 1'b1;
        l_in_addr = 32'h40C0_0000; l_in_rd = 1'b1; #1;
        cyc = 0;
        while (!l_in_accept && cyc < 30) begin @(posedge clk); #1; cyc++; end
        if (!l_in_accept) begin $display("FAIL Test4d: Timed out waiting for l_in_accept!"); $finish(1); end
        @(posedge clk); #1; l_in_rd = 1'b0; sum = 1'b0; #1;
        cyc = 0;
        while (!l_in_ack && cyc < 30) begin @(posedge clk); #1; cyc++; end
        if (!l_in_ack || !l_in_error || !l_in_lfault || l_in_sfault) begin $display("FAIL Test4d: Level-2 PTW bus error did not fault!"); $finish(1); end
        @(posedge clk); #1;

        // 4e: U-mode Exec-Only page (0x4000_2000):
        //     - U-mode load with MXR=1 -> SUCCEEDS!
        //     - S-mode load with SUM=0, MXR=1 -> FAULTS!
        //     - S-mode load with SUM=1, MXR=1 -> SUCCEEDS!
        //     - S-mode I-fetch even with SUM=1 -> FAULTS (S-mode can NEVER execute U=1 page)!
        priv_d = `PRIV_USER; mxr = 1'b1; sum = 1'b0;
        l_in_addr = 32'h4000_2000; l_in_rd = 1'b1; l_in_tag = 11'h043; #1;
        cyc = 0;
        while (!l_in_accept && cyc < 30) begin @(posedge clk); #1; cyc++; end
        if (!l_in_accept) begin $display("FAIL Test4e_1: Timed out waiting for l_in_accept!"); $finish(1); end
        @(posedge clk); #1; l_in_rd = 1'b0; #1;
        cyc = 0;
        while (!l_in_ack && cyc < 30) begin @(posedge clk); #1; cyc++; end
        if (!l_in_ack || l_in_error || l_in_lfault || l_in_sfault || l_in_rdata !== 32'h5566_7788 || l_in_rtag !== 11'h043) begin
            $display("FAIL Test4e_1: U-mode MXR=1 load on X-only page failed!"); $finish(1);
        end
        @(posedge clk); #1;

        priv_d = `PRIV_SUPER; mxr = 1'b1; sum = 1'b0;
        l_in_addr = 32'h4000_2000; l_in_rd = 1'b1; #1;
        cyc = 0;
        while (!l_in_accept && cyc < 30) begin @(posedge clk); #1; cyc++; end
        if (!l_in_accept) begin $display("FAIL Test4e_2: Timed out waiting for l_in_accept!"); $finish(1); end
        @(posedge clk); #1; l_in_rd = 1'b0; #1;
        cyc = 0;
        while (!l_in_ack && cyc < 30) begin @(posedge clk); #1; cyc++; end
        if (!l_in_ack || !l_in_error || !l_in_lfault || l_in_sfault) begin $display("FAIL Test4e_2: S-mode SUM=0 load on U=1 page did not fault!"); $finish(1); end
        @(posedge clk); #1;

        priv_d = `PRIV_SUPER; mxr = 1'b1; sum = 1'b1;
        l_in_addr = 32'h4000_2000; l_in_rd = 1'b1; l_in_tag = 11'h044; #1;
        cyc = 0;
        while (!l_in_accept && cyc < 30) begin @(posedge clk); #1; cyc++; end
        if (!l_in_accept) begin $display("FAIL Test4e_3: Timed out waiting for l_in_accept!"); $finish(1); end
        @(posedge clk); #1; l_in_rd = 1'b0; #1;
        cyc = 0;
        while (!l_in_ack && cyc < 30) begin @(posedge clk); #1; cyc++; end
        if (!l_in_ack || l_in_error || l_in_lfault || l_in_sfault || l_in_rdata !== 32'h5566_7788 || l_in_rtag !== 11'h044) begin
            $display("FAIL Test4e_3: S-mode SUM=1 MXR=1 load failed!"); $finish(1);
        end
        @(posedge clk); #1;

        f_in_priv = `PRIV_SUPER; sum = 1'b1; f_in_pc = 32'h4000_2000; f_in_rd = 1'b1; #1;
        cyc = 0;
        while (!f_in_accept && cyc < 30) begin @(posedge clk); #1; cyc++; end
        if (!f_in_accept) begin $display("FAIL Test4e_4: Timed out waiting for f_in_accept!"); $finish(1); end
        @(posedge clk); #1; f_in_rd = 1'b0; #1;
        cyc = 0;
        while (!f_in_valid && cyc < 30) begin @(posedge clk); #1; cyc++; end
        if (!f_in_valid || !f_in_fault || f_in_error) begin $display("FAIL Test4e_4: S-mode execute on U=1 page did not fault!"); $finish(1); end
        @(posedge clk); #1;

        // -----------------------------------------------------------------
        // Test 5: SFENCE.VMA (flush_i) Mid-Walk Race!
        //   Start D-walk on 0x4000_1000 (currently mapped to 0x8010_1000 -> 0x1122_3344),
        //   update PTE in memory to 0x8010_5000 (0x99AA_BBCC) and pulse flush_i = 1 WHILE PTW IS IN FLIGHT!
        //   In-flight PTW MUST NOT install the stale 0x8010_1000 PTE; it must re-walk and read 0x99AA_BBCC!
        // -----------------------------------------------------------------
        flush = 1'b1; @(posedge clk); #1; flush = 1'b0; #1;
        priv_d = `PRIV_SUPER; sum = 1'b0; mxr = 1'b0;
        l_in_addr = 32'h4000_1000; l_in_rd = 1'b1; l_in_tag = 11'h055; #1;
        // Wait 5 cycles so Level-1 finishes and Level-2 PTW read has ALREADY been accepted on C5 (sampling old PTE 20'h80101 into nr.rdata)!
        repeat (5) @(posedge clk); #1;
        // OS updates L2 PTE in memory and executes SFENCE.VMA while L2 PTW response is in flight!
        pmem[32'h8002_0004 >> 2] = make_pte(20'h80105, 1,1,0,0, 1,1,1, 1);
        flush = 1'b1; @(posedge clk); #1; flush = 1'b0; #1;
        cyc = 0;
        while (!l_in_accept && cyc < 40) begin @(posedge clk); #1; cyc++; end
        if (!l_in_accept) begin $display("FAIL Test5: Timed out waiting for l_in_accept!"); $finish(1); end
        @(posedge clk); #1; l_in_rd = 1'b0; #1;
        cyc = 0;
        while (!l_in_ack && cyc < 30) begin @(posedge clk); #1; cyc++; end
        if (!l_in_ack || l_in_error || l_in_lfault || l_in_sfault || l_in_rdata !== 32'h99AA_BBCC || l_in_rtag !== 11'h055) begin
            $display("FAIL Test5: SFENCE.VMA during in-flight PTW installed stale PTE! got=%h rtag=%h (exp 99AABBCC, 055)", l_in_rdata, l_in_rtag);
            $finish(1);
        end
        @(posedge clk); #1;

        // -----------------------------------------------------------------
        // Test 6: In-Order Downstream Completion (Older Slow Cache Miss Followed By Younger DTLB/ITLB Page Fault!)
        //   6a: Issue D-load #1 to valid 0x4000_1000 (already in DTLB, d_default_lat = 5 cycles),
        //       then IMMEDIATELY on next cycle present D-store #2 to 0x4000_1000 with U-mode privilege (DTLB hit -> store fault!).
        //       Load #1 MUST complete cleanly FIRST (ack #1: error=0, rdata=99AABBCC), and Store #2 MUST fault SECOND (ack #2: sfault=1)!
        // -----------------------------------------------------------------
        d_default_lat = 5;
        priv_d    = `PRIV_SUPER;
        l_in_addr = 32'h4000_1000; l_in_rd = 1'b1; l_in_tag = 11'h071; #1;
        if (!l_in_accept) begin $display("FAIL Test6a_0: Expected DTLB hit accept!"); $finish(1); end
        @(posedge clk); #1; l_in_rd = 1'b0;

        // Immediately present younger faulting store (priv_d = PRIV_USER on S-only page 0x4000_1000 -> immediate DTLB hit + store_fault!)
        priv_d    = `PRIV_USER;
        l_in_addr = 32'h4000_1000; l_in_wr = 4'hF; l_in_wdata = 32'hDEAD_BEEF; l_in_tag = 11'h072; #1;
        begin
            int ack_cnt;
            ack_cnt = 0;
            for (int t = 0; t < 30 && ack_cnt < 2; t++) begin
                // Clear l_in_wr once accepted
                if (l_in_accept && (|l_in_wr)) begin
                    @(posedge clk); #1;
                    l_in_wr = 4'h0; #1;
                end else begin
                    @(posedge clk); #1;
                end
                if (l_in_ack) begin
                    ack_cnt++;
                    if (ack_cnt == 1) begin
                        if (l_in_error || l_in_lfault || l_in_sfault || l_in_rdata !== 32'h99AA_BBCC || l_in_rtag !== 11'h071) begin
                            $display("FAIL Test6a_1: Younger D-fault overtook or corrupted older D-cache load! err=%b sf=%b rdata=%h tag=%h",
                                     l_in_error, l_in_sfault, l_in_rdata, l_in_rtag);
                            $finish(1);
                        end
                    end else if (ack_cnt == 2) begin
                        if (!l_in_error || !l_in_sfault || l_in_lfault) begin
                            $display("FAIL Test6a_2: Younger D-store fault missing on second ack! err=%b sf=%b lf=%b",
                                     l_in_error, l_in_sfault, l_in_lfault);
                            $finish(1);
                        end
                    end
                end
            end
            if (ack_cnt != 2 || (|l_in_wr)) begin
                $display("FAIL Test6a_3: Expected 2 sequential acks (load hit then store fault), got %0d!", ack_cnt);
                $finish(1);
            end
        end
        @(posedge clk); #1;

        // 6b: Same in-order check on I-side (older 4-cycle I-cache fetch to 0x4000_1000 in S-mode, followed immediately by U-mode fetch to 0x4000_1008!)
        i_default_lat = 4;
        f_in_priv = `PRIV_SUPER; f_in_pc = 32'h4000_1000; f_in_rd = 1'b1; #1;
        cyc = 0;
        while (!f_in_accept && cyc < 30) begin @(posedge clk); #1; cyc++; end
        if (!f_in_accept) begin $display("FAIL Test6b_0: Timed out waiting for f_in_accept!"); $finish(1); end
        @(posedge clk); #1;
        // Younger fetch in U-mode to S-only ITLB entry 0x4000_1008 -> ITLB hit + pc_fault!
        f_in_priv = `PRIV_USER; f_in_pc = 32'h4000_1008; f_in_rd = 1'b1; #1;
        begin
            int iv_cnt;
            iv_cnt = 0;
            for (int t = 0; t < 30 && iv_cnt < 2; t++) begin
                if (f_in_accept && f_in_rd) begin
                    @(posedge clk); #1;
                    f_in_rd = 1'b0; #1;
                end else begin
                    @(posedge clk); #1;
                end
                if (f_in_valid) begin
                    iv_cnt++;
                    if (iv_cnt == 1) begin
                        if (f_in_fault || f_in_error || f_in_inst[31:0] !== 32'h8010_5000) begin
                            $display("FAIL Test6b_1: Younger I-fault overtook or corrupted older I-cache fetch! fault=%b inst=%h",
                                     f_in_fault, f_in_inst);
                            $finish(1);
                        end
                    end else if (iv_cnt == 2) begin
                        if (!f_in_fault || f_in_error) begin
                            $display("FAIL Test6b_2: Younger I-fault missing on second valid!");
                            $finish(1);
                        end
                    end
                end
            end
            if (iv_cnt != 2 || f_in_rd) begin
                $display("FAIL Test6b_3: Expected 2 sequential I-fetch responses, got %0d!", iv_cnt);
                $finish(1);
            end
        end

        $display("PASS seed=%0d", seed);
        $finish(0);
    end
endmodule
