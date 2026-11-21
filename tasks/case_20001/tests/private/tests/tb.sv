`timescale 1ns/1ps
`include "biriscv_defs.v"

module issue_harness #(
    parameter SUPPORT_LOAD_BYPASS = 1,
    parameter SUPPORT_MUL_BYPASS  = 1
) (
    input  logic        clk,
    input  logic        rst,
    input  logic        f0_valid,
    input  logic [31:0] f0_instr,
    input  logic [31:0] f0_pc,
    input  logic        f0_fault_fetch,
    input  logic        f0_fault_page,
    input  logic        f1_valid,
    input  logic [31:0] f1_instr,
    input  logic [31:0] f1_pc,
    input  logic        f1_fault_fetch,
    input  logic        f1_fault_page,
    input  logic        branch_csr_req,
    input  logic [31:0] branch_csr_pc,
    input  logic [1:0]  branch_csr_priv,
    input  logic        wb_mem_valid,
    input  logic [31:0] wb_mem_value,
    input  logic [5:0]  wb_mem_exc,
    input  logic [31:0] wb_mul_value,
    input  logic        wb_div_valid,
    input  logic [31:0] wb_div_value,
    input  logic [31:0] csr_e1_value,
    input  logic        csr_e1_write,
    input  logic [31:0] csr_e1_wdata,
    input  logic [5:0]  csr_e1_exc,
    input  logic        lsu_stall,
    input  logic        take_intr,
    // Force raw invalid override for testing invalid-with-rd_valid edge case
    input  logic        force_f0_inv,

    output logic        f0_accept,
    output logic        f1_accept,
    output logic        branch_req,
    output logic [31:0] branch_pc,
    output logic        binfo_req,
    output logic        binfo_taken,
    output logic        binfo_ntaken,
    output logic [31:0] binfo_source,
    output logic        binfo_call,
    output logic        binfo_ret,
    output logic        binfo_jmp,
    output logic [31:0] binfo_pc,
    output logic        exec0_valid,
    output logic        exec1_valid,
    output logic        lsu_valid,
    output logic        csr_valid,
    output logic        csr_invalid,
    output logic        mul_valid,
    output logic        div_valid,
    output logic [31:0] lsu_opc,
    output logic [31:0] mul_opc,
    output logic [31:0] opc0_ra_val,
    output logic [31:0] opc0_rb_val,
    output logic [31:0] opc1_ra_val,
    output logic [31:0] opc1_rb_val,
    output logic [5:0]  csr_wb_exc,
    output logic [31:0] csr_wb_exc_pc,
    output logic        intr_inhibit
);
    logic dec0_inv, dec0_exec, dec0_lsu, dec0_br, dec0_mul, dec0_div, dec0_csr, dec0_rdv;
    logic dec1_inv, dec1_exec, dec1_lsu, dec1_br, dec1_mul, dec1_div, dec1_csr, dec1_rdv;

    biriscv_decoder u_dec0 (
        .valid_i(f0_valid),
        .fetch_fault_i(f0_fault_fetch | f0_fault_page),
        .enable_muldiv_i(1'b1),
        .opcode_i((f0_fault_fetch | f0_fault_page) ? 32'b0 : f0_instr),
        .invalid_o(dec0_inv),
        .exec_o(dec0_exec),
        .lsu_o(dec0_lsu),
        .branch_o(dec0_br),
        .mul_o(dec0_mul),
        .div_o(dec0_div),
        .csr_o(dec0_csr),
        .rd_valid_o(dec0_rdv)
    );

    biriscv_decoder u_dec1 (
        .valid_i(f1_valid),
        .fetch_fault_i(f1_fault_fetch | f1_fault_page),
        .enable_muldiv_i(1'b1),
        .opcode_i((f1_fault_fetch | f1_fault_page) ? 32'b0 : f1_instr),
        .invalid_o(dec1_inv),
        .exec_o(dec1_exec),
        .lsu_o(dec1_lsu),
        .branch_o(dec1_br),
        .mul_o(dec1_mul),
        .div_o(dec1_div),
        .csr_o(dec1_csr),
        .rd_valid_o(dec1_rdv)
    );

    logic        ex0_br_req, ex0_taken, ex0_ntaken, ex0_call, ex0_ret, ex0_jmp, ex0_d_req;
    logic [31:0] ex0_src, ex0_pc, ex0_d_pc, ex0_wb_val;
    logic [1:0]  ex0_d_priv;

    logic        ex1_br_req, ex1_taken, ex1_ntaken, ex1_call, ex1_ret, ex1_jmp, ex1_d_req;
    logic [31:0] ex1_src, ex1_pc, ex1_d_pc, ex1_wb_val;
    logic [1:0]  ex1_d_priv;

    logic [31:0] opc0_opc, opc0_pc, opc1_opc, opc1_pc;
    logic        opc0_inv, opc1_inv, ex0_hold, ex1_hold, mul_hold;
    logic [4:0]  opc0_rd, opc0_ra, opc0_rb, opc1_rd, opc1_ra, opc1_rb;

    biriscv_exec u_exec0 (
        .clk_i(clk), .rst_i(rst),
        .opcode_valid_i(exec0_valid),
        .opcode_opcode_i(opc0_opc),
        .opcode_pc_i(opc0_pc),
        .opcode_invalid_i(opc0_inv),
        .opcode_rd_idx_i(opc0_rd),
        .opcode_ra_idx_i(opc0_ra),
        .opcode_rb_idx_i(opc0_rb),
        .opcode_ra_operand_i(opc0_ra_val),
        .opcode_rb_operand_i(opc0_rb_val),
        .hold_i(ex0_hold),
        .branch_request_o(ex0_br_req),
        .branch_is_taken_o(ex0_taken),
        .branch_is_not_taken_o(ex0_ntaken),
        .branch_source_o(ex0_src),
        .branch_is_call_o(ex0_call),
        .branch_is_ret_o(ex0_ret),
        .branch_is_jmp_o(ex0_jmp),
        .branch_pc_o(ex0_pc),
        .branch_d_request_o(ex0_d_req),
        .branch_d_pc_o(ex0_d_pc),
        .branch_d_priv_o(ex0_d_priv),
        .writeback_value_o(ex0_wb_val)
    );

    biriscv_exec u_exec1 (
        .clk_i(clk), .rst_i(rst),
        .opcode_valid_i(exec1_valid),
        .opcode_opcode_i(opc1_opc),
        .opcode_pc_i(opc1_pc),
        .opcode_invalid_i(opc1_inv),
        .opcode_rd_idx_i(opc1_rd),
        .opcode_ra_idx_i(opc1_ra),
        .opcode_rb_idx_i(opc1_rb),
        .opcode_ra_operand_i(opc1_ra_val),
        .opcode_rb_operand_i(opc1_rb_val),
        .hold_i(ex1_hold),
        .branch_request_o(ex1_br_req),
        .branch_is_taken_o(ex1_taken),
        .branch_is_not_taken_o(ex1_ntaken),
        .branch_source_o(ex1_src),
        .branch_is_call_o(ex1_call),
        .branch_is_ret_o(ex1_ret),
        .branch_is_jmp_o(ex1_jmp),
        .branch_pc_o(ex1_pc),
        .branch_d_request_o(ex1_d_req),
        .branch_d_pc_o(ex1_d_pc),
        .branch_d_priv_o(ex1_d_priv),
        .writeback_value_o(ex1_wb_val)
    );

    biriscv_issue #(
        .SUPPORT_MULDIV(1),
        .SUPPORT_DUAL_ISSUE(1),
        .SUPPORT_LOAD_BYPASS(SUPPORT_LOAD_BYPASS),
        .SUPPORT_MUL_BYPASS(SUPPORT_MUL_BYPASS),
        .SUPPORT_REGFILE_XILINX(0)
    ) dut (
        .clk_i(clk),
        .rst_i(rst),
        .fetch0_valid_i(f0_valid),
        .fetch0_instr_i(f0_instr),
        .fetch0_pc_i(f0_pc),
        .fetch0_fault_fetch_i(f0_fault_fetch),
        .fetch0_fault_page_i(f0_fault_page),
        .fetch0_instr_exec_i(dec0_exec),
        .fetch0_instr_lsu_i(dec0_lsu),
        .fetch0_instr_branch_i(dec0_br),
        .fetch0_instr_mul_i(dec0_mul),
        .fetch0_instr_div_i(dec0_div),
        .fetch0_instr_csr_i(dec0_csr | force_f0_inv),
        .fetch0_instr_rd_valid_i(dec0_rdv),
        .fetch0_instr_invalid_i(dec0_inv | force_f0_inv),
        .fetch1_valid_i(f1_valid),
        .fetch1_instr_i(f1_instr),
        .fetch1_pc_i(f1_pc),
        .fetch1_fault_fetch_i(f1_fault_fetch),
        .fetch1_fault_page_i(f1_fault_page),
        .fetch1_instr_exec_i(dec1_exec),
        .fetch1_instr_lsu_i(dec1_lsu),
        .fetch1_instr_branch_i(dec1_br),
        .fetch1_instr_mul_i(dec1_mul),
        .fetch1_instr_div_i(dec1_div),
        .fetch1_instr_csr_i(dec1_csr),
        .fetch1_instr_rd_valid_i(dec1_rdv),
        .fetch1_instr_invalid_i(dec1_inv),
        .branch_exec0_request_i(ex0_br_req),
        .branch_exec0_is_taken_i(ex0_taken),
        .branch_exec0_is_not_taken_i(ex0_ntaken),
        .branch_exec0_source_i(ex0_src),
        .branch_exec0_is_call_i(ex0_call),
        .branch_exec0_is_ret_i(ex0_ret),
        .branch_exec0_is_jmp_i(ex0_jmp),
        .branch_exec0_pc_i(ex0_pc),
        .branch_d_exec0_request_i(ex0_d_req),
        .branch_d_exec0_pc_i(ex0_d_pc),
        .branch_d_exec0_priv_i(ex0_d_priv),
        .branch_exec1_request_i(ex1_br_req),
        .branch_exec1_is_taken_i(ex1_taken),
        .branch_exec1_is_not_taken_i(ex1_ntaken),
        .branch_exec1_source_i(ex1_src),
        .branch_exec1_is_call_i(ex1_call),
        .branch_exec1_is_ret_i(ex1_ret),
        .branch_exec1_is_jmp_i(ex1_jmp),
        .branch_exec1_pc_i(ex1_pc),
        .branch_d_exec1_request_i(ex1_d_req),
        .branch_d_exec1_pc_i(ex1_d_pc),
        .branch_d_exec1_priv_i(ex1_d_priv),
        .branch_csr_request_i(branch_csr_req),
        .branch_csr_pc_i(branch_csr_pc),
        .branch_csr_priv_i(branch_csr_priv),
        .writeback_exec0_value_i(ex0_wb_val),
        .writeback_exec1_value_i(ex1_wb_val),
        .writeback_mem_valid_i(wb_mem_valid),
        .writeback_mem_value_i(wb_mem_value),
        .writeback_mem_exception_i(wb_mem_exc),
        .writeback_mul_value_i(wb_mul_value),
        .writeback_div_valid_i(wb_div_valid),
        .writeback_div_value_i(wb_div_value),
        .csr_result_e1_value_i(csr_e1_value),
        .csr_result_e1_write_i(csr_e1_write),
        .csr_result_e1_wdata_i(csr_e1_wdata),
        .csr_result_e1_exception_i(csr_e1_exc),
        .lsu_stall_i(lsu_stall),
        .take_interrupt_i(take_intr),

        .fetch0_accept_o(f0_accept),
        .fetch1_accept_o(f1_accept),
        .branch_request_o(branch_req),
        .branch_pc_o(branch_pc),
        .branch_priv_o(),
        .branch_info_request_o(binfo_req),
        .branch_info_is_taken_o(binfo_taken),
        .branch_info_is_not_taken_o(binfo_ntaken),
        .branch_info_source_o(binfo_source),
        .branch_info_is_call_o(binfo_call),
        .branch_info_is_ret_o(binfo_ret),
        .branch_info_is_jmp_o(binfo_jmp),
        .branch_info_pc_o(binfo_pc),
        .exec0_opcode_valid_o(exec0_valid),
        .exec1_opcode_valid_o(exec1_valid),
        .lsu_opcode_valid_o(lsu_valid),
        .csr_opcode_valid_o(csr_valid),
        .mul_opcode_valid_o(mul_valid),
        .div_opcode_valid_o(div_valid),
        .opcode0_opcode_o(opc0_opc),
        .opcode0_pc_o(opc0_pc),
        .opcode0_invalid_o(opc0_inv),
        .opcode0_rd_idx_o(opc0_rd),
        .opcode0_ra_idx_o(opc0_ra),
        .opcode0_rb_idx_o(opc0_rb),
        .opcode0_ra_operand_o(opc0_ra_val),
        .opcode0_rb_operand_o(opc0_rb_val),
        .opcode1_opcode_o(opc1_opc),
        .opcode1_pc_o(opc1_pc),
        .opcode1_invalid_o(opc1_inv),
        .opcode1_rd_idx_o(opc1_rd),
        .opcode1_ra_idx_o(opc1_ra),
        .opcode1_rb_idx_o(opc1_rb),
        .opcode1_ra_operand_o(opc1_ra_val),
        .opcode1_rb_operand_o(opc1_rb_val),
        .lsu_opcode_opcode_o(lsu_opc),
        .lsu_opcode_pc_o(),
        .lsu_opcode_invalid_o(),
        .lsu_opcode_rd_idx_o(),
        .lsu_opcode_ra_idx_o(),
        .lsu_opcode_rb_idx_o(),
        .lsu_opcode_ra_operand_o(),
        .lsu_opcode_rb_operand_o(),
        .mul_opcode_opcode_o(mul_opc),
        .mul_opcode_pc_o(),
        .mul_opcode_invalid_o(),
        .mul_opcode_rd_idx_o(),
        .mul_opcode_ra_idx_o(),
        .mul_opcode_rb_idx_o(),
        .mul_opcode_ra_operand_o(),
        .mul_opcode_rb_operand_o(),
        .csr_opcode_opcode_o(),
        .csr_opcode_pc_o(),
        .csr_opcode_invalid_o(csr_invalid),
        .csr_opcode_rd_idx_o(),
        .csr_opcode_ra_idx_o(),
        .csr_opcode_rb_idx_o(),
        .csr_opcode_ra_operand_o(),
        .csr_opcode_rb_operand_o(),
        .csr_writeback_write_o(),
        .csr_writeback_waddr_o(),
        .csr_writeback_wdata_o(),
        .csr_writeback_exception_o(csr_wb_exc),
        .csr_writeback_exception_pc_o(csr_wb_exc_pc),
        .csr_writeback_exception_addr_o(),
        .exec0_hold_o(ex0_hold),
        .exec1_hold_o(ex1_hold),
        .mul_hold_o(mul_hold),
        .interrupt_inhibit_o(intr_inhibit)
    );
endmodule

module tb;
    logic clk = 0;
    always #5 clk = ~clk;

    // Encoding helpers
    function automatic [31:0] rv_addi(input [4:0] rd, input [4:0] rs1, input [11:0] imm);
        rv_addi = {imm, rs1, 3'b000, rd, 7'b0010011};
    endfunction
    function automatic [31:0] rv_add(input [4:0] rd, input [4:0] rs1, input [4:0] rs2);
        rv_add = {7'b0000000, rs2, rs1, 3'b000, rd, 7'b0110011};
    endfunction
    function automatic [31:0] rv_mul(input [4:0] rd, input [4:0] rs1, input [4:0] rs2);
        rv_mul = {7'b0000001, rs2, rs1, 3'b000, rd, 7'b0110011};
    endfunction
    function automatic [31:0] rv_div(input [4:0] rd, input [4:0] rs1, input [4:0] rs2);
        rv_div = {7'b0000001, rs2, rs1, 3'b100, rd, 7'b0110011};
    endfunction
    function automatic [31:0] rv_lw(input [4:0] rd, input [4:0] rs1, input [11:0] imm);
        rv_lw = {imm, rs1, 3'b010, rd, 7'b0000011};
    endfunction
    function automatic [31:0] rv_sw(input [4:0] rs2, input [4:0] rs1, input [11:0] imm);
        rv_sw = {imm[11:5], rs2, rs1, 3'b010, imm[4:0], 7'b0100011};
    endfunction
    function automatic [31:0] rv_lui(input [4:0] rd, input [19:0] imm20);
        rv_lui = {imm20, rd, 7'b0110111};
    endfunction
    function automatic [31:0] rv_jal(input [4:0] rd, input signed [20:0] offset);
        rv_jal = {offset[20], offset[10:1], offset[11], offset[19:12], rd, 7'b1101111};
    endfunction
    function automatic [31:0] rv_bne(input [4:0] rs1, input [4:0] rs2, input signed [12:0] offset);
        rv_bne = {offset[12], offset[10:5], rs2, rs1, 3'b001, offset[4:1], offset[11], 7'b1100011};
    endfunction
    function automatic [31:0] rv_csrrwi(input [4:0] rd, input [11:0] csr, input [4:0] zimm);
        rv_csrrwi = {csr, zimm, 3'b101, rd, 7'b1110011};
    endfunction
    function automatic [31:0] rv_csrrw(input [4:0] rd, input [11:0] csr, input [4:0] rs1);
        rv_csrrw = {csr, rs1, 3'b001, rd, 7'b1110011};
    endfunction

    logic rst;
    logic f0_valid, f0_ff, f0_fp, f1_valid, f1_ff, f1_fp;
    logic [31:0] f0_instr, f0_pc, f1_instr, f1_pc;
    logic branch_csr_req, wb_mem_valid, wb_div_valid, csr_e1_write, lsu_stall, take_intr, force_f0_inv;
    logic [31:0] branch_csr_pc, wb_mem_value, wb_mul_value, wb_div_value, csr_e1_value, csr_e1_wdata;
    logic [1:0] branch_csr_priv;
    logic [5:0] wb_mem_exc, csr_e1_exc;

    // Bypass=1 instance
    logic b_f0_acc, b_f1_acc, b_br_req, b_bi_req, b_bi_taken, b_bi_ntaken, b_bi_call, b_bi_ret, b_bi_jmp;
    logic b_ex0_v, b_ex1_v, b_lsu_v, b_csr_v, b_csr_inv, b_mul_v, b_div_v, b_inh;
    logic [31:0] b_br_pc, b_bi_src, b_bi_pc, b_lsu_opc, b_mul_opc, b_ra0, b_rb0, b_ra1, b_rb1, b_wb_epc;
    logic [5:0] b_wb_exc;

    // Bypass=0 instance
    logic nb_f0_acc, nb_f1_acc;

    issue_harness #(.SUPPORT_LOAD_BYPASS(1), .SUPPORT_MUL_BYPASS(1)) u_byp (
        .clk(clk), .rst(rst),
        .f0_valid(f0_valid), .f0_instr(f0_instr), .f0_pc(f0_pc), .f0_fault_fetch(f0_ff), .f0_fault_page(f0_fp),
        .f1_valid(f1_valid), .f1_instr(f1_instr), .f1_pc(f1_pc), .f1_fault_fetch(f1_ff), .f1_fault_page(f1_fp),
        .branch_csr_req(branch_csr_req), .branch_csr_pc(branch_csr_pc), .branch_csr_priv(branch_csr_priv),
        .wb_mem_valid(wb_mem_valid), .wb_mem_value(wb_mem_value), .wb_mem_exc(wb_mem_exc),
        .wb_mul_value(wb_mul_value), .wb_div_valid(wb_div_valid), .wb_div_value(wb_div_value),
        .csr_e1_value(csr_e1_value), .csr_e1_write(csr_e1_write), .csr_e1_wdata(csr_e1_wdata), .csr_e1_exc(csr_e1_exc),
        .lsu_stall(lsu_stall), .take_intr(take_intr), .force_f0_inv(force_f0_inv),
        .f0_accept(b_f0_acc), .f1_accept(b_f1_acc), .branch_req(b_br_req), .branch_pc(b_br_pc),
        .binfo_req(b_bi_req), .binfo_taken(b_bi_taken), .binfo_ntaken(b_bi_ntaken), .binfo_source(b_bi_src),
        .binfo_call(b_bi_call), .binfo_ret(b_bi_ret), .binfo_jmp(b_bi_jmp), .binfo_pc(b_bi_pc),
        .exec0_valid(b_ex0_v), .exec1_valid(b_ex1_v), .lsu_valid(b_lsu_v), .csr_valid(b_csr_v), .csr_invalid(b_csr_inv),
        .mul_valid(b_mul_v), .div_valid(b_div_v), .lsu_opc(b_lsu_opc), .mul_opc(b_mul_opc),
        .opc0_ra_val(b_ra0), .opc0_rb_val(b_rb0), .opc1_ra_val(b_ra1), .opc1_rb_val(b_rb1),
        .csr_wb_exc(b_wb_exc), .csr_wb_exc_pc(b_wb_epc), .intr_inhibit(b_inh)
    );

    issue_harness #(.SUPPORT_LOAD_BYPASS(0), .SUPPORT_MUL_BYPASS(0)) u_nobyp (
        .clk(clk), .rst(rst),
        .f0_valid(f0_valid), .f0_instr(f0_instr), .f0_pc(f0_pc), .f0_fault_fetch(f0_ff), .f0_fault_page(f0_fp),
        .f1_valid(f1_valid), .f1_instr(f1_instr), .f1_pc(f1_pc), .f1_fault_fetch(f1_ff), .f1_fault_page(f1_fp),
        .branch_csr_req(branch_csr_req), .branch_csr_pc(branch_csr_pc), .branch_csr_priv(branch_csr_priv),
        .wb_mem_valid(wb_mem_valid), .wb_mem_value(wb_mem_value), .wb_mem_exc(wb_mem_exc),
        .wb_mul_value(wb_mul_value), .wb_div_valid(wb_div_valid), .wb_div_value(wb_div_value),
        .csr_e1_value(csr_e1_value), .csr_e1_write(csr_e1_write), .csr_e1_wdata(csr_e1_wdata), .csr_e1_exc(csr_e1_exc),
        .lsu_stall(lsu_stall), .take_intr(take_intr), .force_f0_inv(force_f0_inv),
        .f0_accept(nb_f0_acc), .f1_accept(nb_f1_acc), .branch_req(), .branch_pc(),
        .binfo_req(), .binfo_taken(), .binfo_ntaken(), .binfo_source(),
        .binfo_call(), .binfo_ret(), .binfo_jmp(), .binfo_pc(),
        .exec0_valid(), .exec1_valid(), .lsu_valid(), .csr_valid(), .csr_invalid(),
        .mul_valid(), .div_valid(), .lsu_opc(), .mul_opc(),
        .opc0_ra_val(), .opc0_rb_val(), .opc1_ra_val(), .opc1_rb_val(),
        .csr_wb_exc(), .csr_wb_exc_pc(), .intr_inhibit()
    );

    task automatic clear_inputs();
        f0_valid = 0; f0_instr = 32'h00000013; f0_pc = 0; f0_ff = 0; f0_fp = 0;
        f1_valid = 0; f1_instr = 32'h00000013; f1_pc = 0; f1_ff = 0; f1_fp = 0;
        branch_csr_req = 0; branch_csr_pc = 0; branch_csr_priv = `PRIV_MACHINE;
        wb_mem_valid = 1; wb_mem_value = 32'hCAFE_BABE; wb_mem_exc = 0;
        wb_mul_value = 32'h1234_5678; wb_div_valid = 0; wb_div_value = 0;
        csr_e1_value = 0; csr_e1_write = 0; csr_e1_wdata = 0; csr_e1_exc = 0;
        lsu_stall = 0; take_intr = 0; force_f0_inv = 0;
    endtask

    task automatic do_reset(input [31:0] start_pc);
        clear_inputs();
        rst = 1;
        repeat (3) @(posedge clk);
        #1 rst = 0;
        branch_csr_req = 1;
        branch_csr_pc  = start_pc;
        @(posedge clk);
        #1 clear_inputs();
    endtask

    int seed = 101;
    initial begin
        void'($value$plusargs("seed=%d", seed));

        // ------------------------------------------------------------
        // Test 1: x0 immunity in E1 and E2 (both bypass=1 and bypass=0)
        // LW x0, 0(x1) followed by NOP (ADDI x0,x0,0) + ADDI x2, x0, 7
        // ------------------------------------------------------------
        do_reset(32'h1000);
        f0_valid = 1; f0_pc = 32'h1000; f0_instr = rv_lw(5'd0, 5'd1, 12'd0);
        f1_valid = 0;
        #1;
        if (!b_f0_acc || !nb_f0_acc || !b_lsu_v || b_ex0_v || b_mul_v || b_div_v || b_csr_v) begin
            $display("FAIL Test1a: LW x0 issue strobes wrong: acc=%b/%b lsu=%b ex0=%b mul=%b div=%b csr=%b",
                     b_f0_acc, nb_f0_acc, b_lsu_v, b_ex0_v, b_mul_v, b_div_v, b_csr_v);
            $finish(1);
        end
        @(posedge clk); #1;
        // Cycle E1 of LW x0: present ADDI x0, x0, 0 and ADDI x2, x0, 7 -> both MUST dual-issue immediately!
        f0_valid = 1; f0_pc = 32'h1004; f0_instr = rv_addi(5'd0, 5'd0, 12'd0);
        f1_valid = 1; f1_pc = 32'h1008; f1_instr = rv_addi(5'd2, 5'd0, 12'd7);
        #1;
        if (!b_f0_acc || !b_f1_acc || !nb_f0_acc || !nb_f1_acc) begin
            $display("FAIL Test1b: LW x0 in E1 falsely stalled x0-referencing instructions! b=%b/%b nb=%b/%b",
                     b_f0_acc, b_f1_acc, nb_f0_acc, nb_f1_acc);
            $finish(1);
        end
        @(posedge clk); #1;
        // Cycle E2 of LW x0: even in SUPPORT_LOAD_BYPASS=0, LW x0 in E2 must NOT stall ADDI x3, x0, 9!
        f0_valid = 1; f0_pc = 32'h100C; f0_instr = rv_addi(5'd3, 5'd0, 12'd9);
        f1_valid = 0;
        #1;
        if (!nb_f0_acc || !b_f0_acc) begin
            $display("FAIL Test1c: LW x0 in E2 (nobypass) falsely stalled x0 reader! nb=%b b=%b", nb_f0_acc, b_f0_acc);
            $finish(1);
        end
        @(posedge clk); #1;

        // ------------------------------------------------------------
        // Test 2: Spurious WAW / RAW on immediate fields (SW/BEQ [11:7], ADDI [24:20], LUI/JAL/CSRRWI [19:15])
        // Issue LW x5, 0(x1); on next cycle (x5 busy in E1):
        //   Slot 0: ADDI x6, x2, 12'h005 (bits [24:20] == 5 == x5, does NOT read rs2!)
        //   Slot 1: SW x3, offset_with_imm4_0_eq_5(x2) (bits [11:7] == 5 == x5, does NOT write rd, cannot issue because LW in E1? No, SW is LSU and ALU+LSU is dual_issue_ok!)
        // ------------------------------------------------------------
        do_reset(32'h2000);
        f0_valid = 1; f0_pc = 32'h2000; f0_instr = rv_lw(5'd5, 5'd1, 12'd0);
        f1_valid = 0;
        @(posedge clk); #1;
        // x5 is now in E1 scoreboard!
        // Slot 0: ADDI x6, x2, 12'h025 -> bits [24:20] = 5'd5! Must NOT stall on rb!
        // Slot 1: BEQ x2, x3, +10 (offset=10 -> imm[4:1]=5, imm[11]=0 -> bits[11:7]=5'b01010=10; let's use offset where bits[11:7]==5: imm[4:1]=2, imm[11]=1 -> offset = 2048 + 4 = 2052 -> 13'sd2052 has offset[11]=1, offset[4:1]=4'b0010 -> bits[11:7]=5'b00101=5!)
        f0_valid = 1; f0_pc = 32'h2004; f0_instr = rv_addi(5'd6, 5'd2, 12'h025); // [24:20] == 5
        f1_valid = 1; f1_pc = 32'h2008; f1_instr = rv_bne(5'd2, 5'd3, 13'sd2052); // [11:7] == 5, not-taken (0 != 0 is false)
        #1;
        if (!b_f0_acc || !b_f1_acc) begin
            $display("FAIL Test2a: Spurious RAW on I-type [24:20] or WAW on BEQ [11:7]: f0_acc=%b f1_acc=%b", b_f0_acc, b_f1_acc);
            $finish(1);
        end
        @(posedge clk); #1;
        // Also test Slot 0 WAW qualification (BNE with [11:7]==5 in Slot 0 while x5 busy in E1) + CSRRWI zimm=5
        f0_valid = 1; f0_pc = 32'h200C; f0_instr = rv_mul(5'd5, 5'd1, 5'd2);
        f1_valid = 0;
        @(posedge clk); #1;
        // x5 is in E1: Slot 0 = BNE [11:7]==5 (must NOT stall on rd!)
        f0_valid = 1; f0_pc = 32'h2010; f0_instr = rv_bne(5'd2, 5'd3, 13'sd2052);
        f1_valid = 0;
        #1;
        if (!b_f0_acc) begin
            $display("FAIL Test2a_slot0: Spurious WAW on Slot0 BNE [11:7]==5: f0_acc=%b", b_f0_acc);
            $finish(1);
        end
        @(posedge clk); #1;
        f0_valid = 1; f0_pc = 32'h2014; f0_instr = rv_mul(5'd5, 5'd1, 5'd2);
        f1_valid = 0;
        @(posedge clk); #1;
        // x5 is in E1 (from MUL, NOT LSU, so CSRRWI is allowed in Slot 0 if zimm=5 is NOT treated as rs1!)
        f0_valid = 1; f0_pc = 32'h2018; f0_instr = rv_csrrwi(5'd7, `CSR_MSCRATCH, 5'd5);
        f1_valid = 0;
        #1;
        if (!b_f0_acc || !b_csr_v) begin
            $display("FAIL Test2b: CSRRWI zimm=5 falsely stalled on busy x5! acc=%b csr_v=%b", b_f0_acc, b_csr_v);
            $finish(1);
        end
        @(posedge clk); #1;
        // Drain csr_pending_q (2 cycles to WB)
        clear_inputs();
        repeat (3) @(posedge clk); #1;

        // ------------------------------------------------------------
        // Test 2c: True cross-slot RAW (Slot 0 ADDI x8, x0, 11 -> Slot 1 ADD x9, x8, x0 MUST serialize!)
        // ------------------------------------------------------------
        do_reset(32'h2800);
        f0_valid = 1; f0_pc = 32'h2800; f0_instr = rv_addi(5'd8, 5'd0, 12'd11);
        f1_valid = 1; f1_pc = 32'h2804; f1_instr = rv_add(5'd9, 5'd8, 5'd0);
        #1;
        if (!b_f0_acc || b_f1_acc) begin
            $display("FAIL Test2c: Cross-slot RAW failed to serialize Slot 1! f0_acc=%b f1_acc=%b", b_f0_acc, b_f1_acc);
            $finish(1);
        end
        @(posedge clk); #1;

        // ------------------------------------------------------------
        // Test 3: Post-LSU hazard across BOTH slots!
        // Cycle 0: LW x4, 0(x1) issues.
        // Cycle 1 (LW in E1): Slot 0 = ADDI x6, x0, 3, Slot 1 = MUL x7, x2, x3
        //   Slot 0 ADDI MUST single-issue (f0_acc=1, ex0_v=1), while Slot 1 MUL MUST be blocked (f1_acc=0, mul_v=0)!
        // ------------------------------------------------------------
        do_reset(32'h3000);
        f0_valid = 1; f0_pc = 32'h3000; f0_instr = rv_lw(5'd4, 5'd1, 12'd0);
        f1_valid = 0;
        @(posedge clk); #1;
        f0_valid = 1; f0_pc = 32'h3004; f0_instr = rv_addi(5'd6, 5'd0, 12'd3);
        f1_valid = 1; f1_pc = 32'h3008; f1_instr = rv_mul(5'd7, 5'd2, 5'd3);
        #1;
        if (!b_f0_acc || b_f1_acc || !b_ex0_v || b_mul_v) begin
            $display("FAIL Test3: Post-LSU Slot0 ALU + Slot1 MUL failed: f0_acc=%b f1_acc=%b ex0_v=%b mul_v=%b",
                     b_f0_acc, b_f1_acc, b_ex0_v, b_mul_v);
            $finish(1);
        end
        @(posedge clk); #1;

        // ------------------------------------------------------------
        // Test 4: take_interrupt_i suppresses exec0_opcode_valid_o (taken branch) & div_opcode_valid_o
        // Also check stale interrupt_inhibit_o when f0_valid=0, f1_valid=0, f1_instr=CSRRW!
        // ------------------------------------------------------------
        do_reset(32'h4000);
        // Idle fetch with stale CSR instruction bits on fetch1
        f0_valid = 0; f1_valid = 0; f1_instr = rv_csrrw(5'd1, `CSR_MSCRATCH, 5'd2);
        #1;
        if (b_inh) begin
            $display("FAIL Test4a: Stale fetch1 CSR asserted interrupt_inhibit_o when fetch valid=0!");
            $finish(1);
        end
        // Present taken JAL at 0x4000 + DIV at 0x4000 under take_interrupt_i = 1
        f0_valid = 1; f0_pc = 32'h4000; f0_instr = rv_jal(5'd1, 21'sd64);
        f1_valid = 0; take_intr = 1;
        #1;
        if (b_ex0_v || b_f0_acc) begin
            $display("FAIL Test4b: JAL issued to exec0 during take_interrupt_i! ex0_v=%b f0_acc=%b", b_ex0_v, b_f0_acc);
            $finish(1);
        end
        @(posedge clk); #1;
        // Next cycle: take_intr=0, 0x4000 is STILL at fetch0 -> MUST NOT trigger mispredicted_r (pc_x_q must still be 0x4000 until interrupt WB!)
        take_intr = 0;
        #1;
        if (b_br_req) begin
            $display("FAIL Test4c: Interrupted JAL corrupted pc_x_q and caused false mispredicted_r!");
            $finish(1);
        end
        // Test DIV under take_interrupt_i=1 does not lock div_pending_q
        do_reset(32'h4400);
        f0_valid = 1; f0_pc = 32'h4400; f0_instr = rv_div(5'd5, 5'd1, 5'd2);
        take_intr = 1;
        #1;
        if (b_div_v || b_f0_acc) begin
            $display("FAIL Test4d: DIV asserted div_opcode_valid_o during take_interrupt_i!");
            $finish(1);
        end
        @(posedge clk); #1;
        take_intr = 0;
        f0_valid = 1; f0_pc = 32'h4400; f0_instr = rv_addi(5'd5, 5'd0, 12'd1);
        #1;
        if (!b_f0_acc) begin
            $display("FAIL Test4e: Interrupted DIV locked div_pending_q and stalled subsequent issue!");
            $finish(1);
        end

        // ------------------------------------------------------------
        // Test 5: Fetch/page fault isolation (no csr_opcode_valid_o, no dual-issue on ALU/CSR fault, blocks younger SW until squash)
        // ------------------------------------------------------------
        do_reset(32'h4C00);
        f0_valid = 1; f0_pc = 32'h4C00; f0_instr = rv_addi(5'd3, 5'd0, 12'd9); f0_fp = 1;
        f1_valid = 1; f1_pc = 32'h4C04; f1_instr = rv_sw(5'd2, 5'd1, 12'd0); f1_fp = 0;
        #1;
        if (!b_f0_acc || b_f1_acc || b_ex0_v || b_lsu_v || b_ex1_v) begin
            $display("FAIL Test5_alu_fault: Page-faulting ALU Slot0 leaked exec0_valid or dual-issued Slot1: f0_acc=%b f1_acc=%b ex0_v=%b lsu_v=%b",
                     b_f0_acc, b_f1_acc, b_ex0_v, b_lsu_v);
            $finish(1);
        end
        do_reset(32'h5000);
        f0_valid = 1; f0_pc = 32'h5000; f0_instr = rv_csrrw(5'd1, `CSR_MSCRATCH, 5'd2); f0_fp = 1;
        f1_valid = 1; f1_pc = 32'h5004; f1_instr = rv_sw(5'd2, 5'd1, 12'd0); f1_fp = 0;
        #1;
        if (!b_f0_acc || b_f1_acc || b_csr_v || b_lsu_v || b_ex0_v || b_ex1_v) begin
            $display("FAIL Test5a: Page-faulting Slot0 leaked unit valid or dual-issued Slot1: f0_acc=%b f1_acc=%b csr_v=%b lsu_v=%b",
                     b_f0_acc, b_f1_acc, b_csr_v, b_lsu_v);
            $finish(1);
        end
        @(posedge clk); #1;
        // Cycle after fault entered E1: Slot 1 (now muxed to Slot 0 at 0x5004) is SW -> MUST be blocked while fault drains to E2!
        f0_valid = 0; f0_fp = 0;
        f1_valid = 1; f1_pc = 32'h5004; f1_instr = rv_sw(5'd2, 5'd1, 12'd0);
        #1;
        if (b_lsu_v || b_f1_acc) begin
            $display("FAIL Test5b: Younger SW issued behind E1 instruction page fault! lsu_v=%b f1_acc=%b", b_lsu_v, b_f1_acc);
            $finish(1);
        end
        @(posedge clk); #1; // Fault reaches E2 -> squash_w=1
        @(posedge clk); #1; // Fault reaches WB -> csr_wb_exc == EXCEPTION_PAGE_FAULT_INST
        if (b_wb_exc != `EXCEPTION_PAGE_FAULT_INST || b_wb_epc != 32'h5000) begin
            $display("FAIL Test5c: Expected EXCEPTION_PAGE_FAULT_INST at 0x5000, got exc=%h pc=%h", b_wb_exc, b_wb_epc);
            $finish(1);
        end

        // ------------------------------------------------------------
        // Test 6: Delayed misprediction predictor feedback across 3-cycle fetch bubble!
        // Dual-issue Slot 0 ADDI (0x6000) + Slot 1 JAL x1, +0x100 (0x6004 -> target 0x6104, call=1, jmp=1, taken=1)
        // Then hold fetch0_valid=0, fetch1_valid=0 for 3 cycles!
        // Then present wrong-path fetch0_valid=1, fetch0_pc=0x6008 -> b_bi_req MUST assert with source=0x6004, pc=0x6104, taken=1, call=1, jmp=1!
        // ------------------------------------------------------------
        do_reset(32'h6000);
        f0_valid = 1; f0_pc = 32'h6000; f0_instr = rv_addi(5'd4, 5'd0, 12'd1);
        f1_valid = 1; f1_pc = 32'h6004; f1_instr = rv_jal(5'd1, 21'sd256); // target = 0x6104
        #1;
        if (!b_f0_acc || !b_f1_acc || !b_ex1_v) begin
            $display("FAIL Test6a: Dual-issue ADDI + JAL failed! acc=%b/%b ex1_v=%b", b_f0_acc, b_f1_acc, b_ex1_v);
            $finish(1);
        end
        @(posedge clk); #1;
        // Cycle T+1 (JAL in E1), T+2, T+3: fetch bubble (valid=0)!
        clear_inputs();
        repeat (3) begin
            @(posedge clk); #1;
            if (b_bi_req) begin
                $display("FAIL Test6b: Spurious branch_info_request_o during fetch bubble!");
                $finish(1);
            end
        end
        // Cycle T+4: Frontend delivers wrong sequential parcel 0x6008!
        f0_valid = 1; f0_pc = 32'h6008; f0_instr = rv_addi(5'd5, 5'd0, 12'd2);
        #1;
        if (!b_bi_req || !b_bi_taken || b_bi_ntaken || !b_bi_call || b_bi_ret || !b_bi_jmp ||
            b_bi_src !== 32'h6004 || b_bi_pc !== 32'h6104) begin
            $display("FAIL Test6c: Delayed misprediction lost branch_info: req=%b taken=%b call=%b jmp=%b src=%h pc=%h",
                     b_bi_req, b_bi_taken, b_bi_call, b_bi_jmp, b_bi_src, b_bi_pc);
            $finish(1);
        end
        @(posedge clk); #1;
        // Now present matching parcel 0x6104 (predicted target arrives) followed by a non-branch PC mismatch check to ensure saved_br cleared
        f0_valid = 1; f0_pc = 32'h6104; f0_instr = rv_addi(5'd6, 5'd0, 12'd3);
        #1;
        if (!b_f0_acc || b_bi_req) begin
            $display("FAIL Test6d: Expected 0x6104 to issue cleanly after redirect!");
            $finish(1);
        end
        @(posedge clk); #1;
        // Present unexpected PC 0x7770 without a preceding branch -> b_bi_taken/call MUST be 0 (saved_br was cleared!)
        f0_valid = 1; f0_pc = 32'h7770; f0_instr = rv_addi(5'd7, 5'd0, 12'd4);
        #1;
        if (!b_bi_req || b_bi_taken || b_bi_call) begin
            $display("FAIL Test6e: Stale saved_br replayed after matching fetch! req=%b taken=%b call=%b",
                     b_bi_req, b_bi_taken, b_bi_call);
            $finish(1);
        end

        // ------------------------------------------------------------
        // Test 7: Seeded randomized dual-issue stress (ALU + MUL + LW + SW + branches)
        // Verify unit strobes never fire when corresponding class is absent
        // ------------------------------------------------------------
        do_reset(32'h8000);
        begin
            logic [31:0] cur_pc = 32'h8000;
            for (int iter = 0; iter < 80; iter++) begin
                int r0 = $urandom(seed + iter * 2);
                int r1 = $urandom(seed + iter * 2 + 1);
                logic [4:0] rd0 = 5'(r0 % 8);
                logic [4:0] rs1_0 = 5'((r0 >> 4) % 8);
                logic [4:0] rs2_0 = 5'((r0 >> 8) % 8);
                logic [4:0] rd1 = 5'(r1 % 8);
                logic [4:0] rs1_1 = 5'((r1 >> 4) % 8);
                logic [4:0] rs2_1 = 5'((r1 >> 8) % 8);

                f0_valid = 1; f0_pc = cur_pc;
                case ((r0 >> 12) % 4)
                    0: f0_instr = rv_addi(rd0, rs1_0, 12'(r0[23:12]));
                    1: f0_instr = rv_add(rd0, rs1_0, rs2_0);
                    2: f0_instr = rv_lw(rd0, rs1_0, 12'd0);
                    default: f0_instr = rv_mul(rd0, rs1_0, rs2_0);
                endcase

                f1_valid = 1; f1_pc = cur_pc + 32'd4;
                case ((r1 >> 12) % 4)
                    0: f1_instr = rv_addi(rd1, rs1_1, 12'(r1[23:12]));
                    1: f1_instr = rv_add(rd1, rs1_1, rs2_1);
                    2: f1_instr = rv_sw(rs2_1, rs1_1, 12'd4);
                    default: f1_instr = rv_lui(rd1, 20'(r1[31:12]));
                endcase

                #1;
                // Check strict unit strobe hygiene
                if (b_lsu_v && !(((b_lsu_opc & 32'h7f) == 7'b0000011) || ((b_lsu_opc & 32'h7f) == 7'b0100011))) begin
                    $display("FAIL Test7: lsu_opcode_valid_o asserted for non-LSU opcode %h", b_lsu_opc);
                    $finish(1);
                end
                if (b_mul_v && !((b_mul_opc & 32'hfe00007f) == 32'h02000033 && b_mul_opc[14] == 1'b0)) begin
                    $display("FAIL Test7: mul_opcode_valid_o asserted for non-MUL opcode %h", b_mul_opc);
                    $finish(1);
                end
                if (b_div_v) begin
                    $display("FAIL Test7: div_opcode_valid_o asserted when no DIV present!");
                    $finish(1);
                end
                if (b_csr_v) begin
                    $display("FAIL Test7: csr_opcode_valid_o asserted when no CSR present!");
                    $finish(1);
                end

                if (b_f0_acc && b_f1_acc)
                    cur_pc = cur_pc + 32'd8;
                else if (b_f0_acc)
                    cur_pc = cur_pc + 32'd4;

                @(posedge clk); #1;
            end
        end

        $display("PASS seed=%0d", seed);
        $finish(0);
    end
endmodule
