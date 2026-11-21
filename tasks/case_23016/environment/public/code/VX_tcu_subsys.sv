// Copyright © 2019-2023
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

`include "VX_define.vh"

module VX_tcu_subsys import VX_gpu_pkg::*, VX_tcu_pkg::*; #(
    parameter BLOCK_SIZE      = `VX_CFG_NUM_TCU_BLOCKS,
    parameter NUM_BANKS       = `VX_CFG_LMEM_NUM_BANKS,
    parameter BANK_ADDR_WIDTH = `VX_CFG_LMEM_LOG_SIZE
                              - $clog2(`VX_CFG_XLEN / 8)
                              - $clog2(`VX_CFG_LMEM_NUM_BANKS),
    parameter LMEM_DATA_BITS  = NUM_BANKS * `VX_CFG_XLEN,
    parameter BLOCK_DATA_BITS = TCU_BLOCK_CAP * `VX_CFG_XLEN
) (
    input  wire                                       clk,
    input  wire                                       reset,

    // Per-block macro-instruction issue interface
    input  wire [BLOCK_SIZE-1:0]                      macro_valid,
    output wire [BLOCK_SIZE-1:0]                      macro_ready,
    input  wire [BLOCK_SIZE*NW_WIDTH-1:0]             macro_wid,
    input  wire [BLOCK_SIZE*NCTA_WIDTH-1:0]           macro_cta_id,
    input  wire [BLOCK_SIZE*`VX_CFG_NUM_THREADS-1:0]  macro_tmask,
    input  wire [BLOCK_SIZE*PC_BITS-1:0]              macro_PC,
    input  wire [BLOCK_SIZE*INST_OP_BITS-1:0]         macro_op_type,
    input  wire [BLOCK_SIZE*5-1:0]                    macro_fmt_s,
    input  wire [BLOCK_SIZE*5-1:0]                    macro_fmt_d,
    input  wire [BLOCK_SIZE-1:0]                      macro_a_from_smem,
    input  wire [BLOCK_SIZE*2-1:0]                    macro_cd_nregs,

    // Per-block expanded-uop scoreboard/operand-collector interface
    output wire [BLOCK_SIZE-1:0]                      uop_valid,
    input  wire [BLOCK_SIZE-1:0]                      uop_ready,
    output wire [BLOCK_SIZE-1:0]                      uop_fire,
    output wire [BLOCK_SIZE*NW_WIDTH-1:0]             rf_rd_wid,
    output wire [BLOCK_SIZE*NUM_REGS_BITS-1:0]        rf_rs1_addr,
    output wire [BLOCK_SIZE*NUM_REGS_BITS-1:0]        rf_rs2_addr,
    output wire [BLOCK_SIZE*NUM_REGS_BITS-1:0]        rf_rs3_addr,
    output wire [BLOCK_SIZE*3-1:0]                    rf_used_rs,
    output wire [BLOCK_SIZE-1:0]                      uop_wb,
    output wire [BLOCK_SIZE*NUM_REGS_BITS-1:0]        uop_rd_addr,
    output wire [BLOCK_SIZE-1:0]                      uop_fu_lock,
    output wire [BLOCK_SIZE-1:0]                      uop_fu_unlock,
    input  wire [BLOCK_SIZE*BLOCK_DATA_BITS-1:0]      rf_rs1_data,
    input  wire [BLOCK_SIZE*BLOCK_DATA_BITS-1:0]      rf_rs2_data,
    input  wire [BLOCK_SIZE*BLOCK_DATA_BITS-1:0]      rf_rs3_data,

    // Sparse metadata SRAM broadcast write port
    input  wire                                       meta_wr_en,
    input  wire [NW_WIDTH-1:0]                        meta_wr_wid,
    input  wire [4:0]                                 meta_wr_idx,
    input  wire [BLOCK_DATA_BITS-1:0]                 meta_wr_data,

    // Shared LMEM bank-parallel read master port
    output wire                                       lmem_req_valid,
    input  wire                                       lmem_req_ready,
    output wire                                       lmem_req_rw,
    output wire [BANK_ADDR_WIDTH-1:0]                 lmem_req_addr,
    output wire [TCU_LMEM_TAG_W-1:0]                  lmem_req_tag,
    input  wire                                       lmem_rsp_valid,
    output wire                                       lmem_rsp_ready,
    input  wire [LMEM_DATA_BITS-1:0]                  lmem_rsp_data,
    input  wire [TCU_LMEM_TAG_W-1:0]                  lmem_rsp_tag,

    // Per-block result commit interface
    output wire [BLOCK_SIZE-1:0]                      res_valid,
    input  wire [BLOCK_SIZE-1:0]                      res_ready,
    output wire [BLOCK_SIZE*NW_WIDTH-1:0]             res_wid,
    output wire [BLOCK_SIZE*NCTA_WIDTH-1:0]           res_cta_id,
    output wire [BLOCK_SIZE*`VX_CFG_NUM_THREADS-1:0]  res_tmask,
    output wire [BLOCK_SIZE*PC_BITS-1:0]              res_PC,
    output wire [BLOCK_SIZE-1:0]                      res_wb,
    output wire [BLOCK_SIZE*NUM_REGS_BITS-1:0]        res_rd,
    output wire [BLOCK_SIZE*BLOCK_DATA_BITS-1:0]      res_data
);

    VX_ibuffer_if seq_in_if  [BLOCK_SIZE]();
    VX_ibuffer_if seq_out_if [BLOCK_SIZE]();

    VX_execute_if #(
        .data_t (tcu_execute_t)
    ) core_execute_if [BLOCK_SIZE]();

    VX_result_if #(
        .data_t (tcu_result_t)
    ) core_result_if [BLOCK_SIZE]();

    VX_mem_bus_if #(
        .DATA_SIZE  (NUM_BANKS * (`VX_CFG_XLEN / 8)),
        .TAG_WIDTH  (TCU_LMEM_TAG_W),
        .ATTR_WIDTH (LMEM_DMA_ATTR_W),
        .ADDR_WIDTH (BANK_ADDR_WIDTH)
    ) tcu_lmem_if();

    assign lmem_req_valid            = tcu_lmem_if.req_valid;
    assign lmem_req_rw               = tcu_lmem_if.req_data.rw;
    assign lmem_req_addr             = tcu_lmem_if.req_data.addr;
    assign lmem_req_tag              = tcu_lmem_if.req_data.tag;
    assign tcu_lmem_if.req_ready     = lmem_req_ready;
    assign tcu_lmem_if.rsp_valid     = lmem_rsp_valid;
    assign tcu_lmem_if.rsp_data.data = lmem_rsp_data;
    assign tcu_lmem_if.rsp_data.tag  = lmem_rsp_tag;
    assign lmem_rsp_ready            = tcu_lmem_if.rsp_ready;
    `UNUSED_VAR ({tcu_lmem_if.req_data.data, tcu_lmem_if.req_data.byteen, tcu_lmem_if.req_data.attr})

    wire [BLOCK_SIZE-1:0]                                         exec_valid_w;
    wire [BLOCK_SIZE-1:0]                                         exec_ready_w;
    tcu_execute_t                                                 exec_data_w [BLOCK_SIZE];
    wire [BLOCK_SIZE-1:0][TCU_WG_A_DATA_SIZE-1:0][`VX_CFG_XLEN-1:0] tbuf_rs1_data;
    wire [BLOCK_SIZE-1:0][TCU_WG_RS2_WIDTH-1:0][`VX_CFG_XLEN-1:0] tbuf_rs2_data;
    wire [BLOCK_SIZE-1:0]                                         tbuf_ready_eff;

    localparam EXEC_DATAW = $bits(tcu_execute_t);

    for (genvar bi = 0; bi < BLOCK_SIZE; ++bi) begin : g_front
        ibuffer_t macro_ibuf;
        always_comb begin
            macro_ibuf                         = '0;
            macro_ibuf.wid                     = macro_wid[bi*NW_WIDTH +: NW_WIDTH];
            macro_ibuf.cta_id                  = macro_cta_id[bi*NCTA_WIDTH +: NCTA_WIDTH];
            macro_ibuf.tmask                   = macro_tmask[bi*`VX_CFG_NUM_THREADS +: `VX_CFG_NUM_THREADS];
            macro_ibuf.PC                      = macro_PC[bi*PC_BITS +: PC_BITS];
            macro_ibuf.ex_type                 = EX_TCU;
            macro_ibuf.op_type                 = macro_op_type[bi*INST_OP_BITS +: INST_OP_BITS];
            macro_ibuf.op_args.tcu.fmt_s       = macro_fmt_s[bi*5 +: 5];
            macro_ibuf.op_args.tcu.fmt_d       = macro_fmt_d[bi*5 +: 5];
            macro_ibuf.op_args.tcu.a_from_smem = macro_a_from_smem[bi];
            macro_ibuf.op_args.tcu.cd_nregs    = macro_cd_nregs[bi*2 +: 2];
            macro_ibuf.fu_lock                 = 1'b1;
            macro_ibuf.fu_unlock               = 1'b1;
        end

        assign seq_in_if[bi].valid = macro_valid[bi];
        assign seq_in_if[bi].data  = macro_ibuf;
        assign macro_ready[bi]     = seq_in_if[bi].ready;

        VX_uop_sequencer #(
            .INSTANCE_ID (`SFORMATF(("uop_seq%0d", bi))),
            .WARP_ID     (bi)
        ) uop_seq (
            .clk       (clk),
            .reset     (reset),
            .input_if  (seq_in_if[bi]),
            .output_if (seq_out_if[bi])
        );

        wire [2:0] used_rs_b = seq_out_if[bi].data.used_rs;
        wire pipe_ready_in;

        assign uop_valid  [bi]                                = seq_out_if[bi].valid;
        assign seq_out_if [bi].ready                          = uop_ready[bi] && pipe_ready_in;
        assign uop_fire   [bi]                                = seq_out_if[bi].valid && seq_out_if[bi].ready;
        assign rf_rd_wid  [bi*NW_WIDTH +: NW_WIDTH]           = seq_out_if[bi].data.wid;
        assign rf_rs1_addr[bi*NUM_REGS_BITS +: NUM_REGS_BITS] = seq_out_if[bi].data.rs1;
        assign rf_rs2_addr[bi*NUM_REGS_BITS +: NUM_REGS_BITS] = seq_out_if[bi].data.rs2;
        assign rf_rs3_addr[bi*NUM_REGS_BITS +: NUM_REGS_BITS] = seq_out_if[bi].data.rs3;
        assign rf_used_rs [bi*3 +: 3]                         = used_rs_b;
        assign uop_wb     [bi]                                = seq_out_if[bi].data.wb;
        assign uop_rd_addr[bi*NUM_REGS_BITS +: NUM_REGS_BITS] = seq_out_if[bi].data.rd;
        assign uop_fu_lock[bi]                                = seq_out_if[bi].data.fu_lock;
        assign uop_fu_unlock[bi]                              = seq_out_if[bi].data.fu_unlock;

        tcu_execute_t exe_d, exe_q;
        always_comb begin
            exe_d               = '0;
            exe_d.header.uuid   = seq_out_if[bi].data.uuid;
            exe_d.header.wid    = seq_out_if[bi].data.wid;
            exe_d.header.cta_id = seq_out_if[bi].data.cta_id;
            exe_d.header.tmask  = seq_out_if[bi].data.tmask;
            exe_d.header.PC     = seq_out_if[bi].data.PC;
            exe_d.header.wb     = seq_out_if[bi].data.wb;
            exe_d.header.rd     = seq_out_if[bi].data.rd;
            exe_d.op_type       = INST_TCU_BITS'(seq_out_if[bi].data.op_type);
            exe_d.op_args       = seq_out_if[bi].data.op_args;
            exe_d.rs1_data      = used_rs_b[0] ? rf_rs1_data[bi*BLOCK_DATA_BITS +: BLOCK_DATA_BITS] : '0;
            exe_d.rs2_data      = used_rs_b[1] ? rf_rs2_data[bi*BLOCK_DATA_BITS +: BLOCK_DATA_BITS] : '0;
            exe_d.rs3_data      = used_rs_b[2] ? rf_rs3_data[bi*BLOCK_DATA_BITS +: BLOCK_DATA_BITS] : '0;
        end

        VX_pipe_buffer #(
            .DATAW  (EXEC_DATAW),
            .RESETW (EXEC_DATAW),
            .DEPTH  (1)
        ) exec_pipe (
            .clk       (clk),
            .reset     (reset),
            .valid_in  (seq_out_if[bi].valid && uop_ready[bi]),
            .ready_in  (pipe_ready_in),
            .data_in   (exe_d),
            .data_out  (exe_q),
            .ready_out (core_execute_if[bi].ready),
            .valid_out (core_execute_if[bi].valid)
        );

        assign core_execute_if[bi].data = exe_q;
        assign exec_valid_w[bi]         = core_execute_if[bi].valid;
        assign exec_ready_w[bi]         = core_execute_if[bi].ready;
        assign exec_data_w[bi]          = exe_q;
    end

    VX_tcu_wgmma #(
        .INSTANCE_ID     ("wgmma"),
        .BLOCK_SIZE      (BLOCK_SIZE),
        .BANK_ADDR_WIDTH (BANK_ADDR_WIDTH)
    ) wgmma (
        .clk            (clk),
        .reset          (reset),
        .exec_valid     (exec_valid_w),
        .exec_ready     (exec_ready_w),
        .exec_data      (exec_data_w),
        .tcu_lmem_if    (tcu_lmem_if),
        .tbuf_rs1_data  (tbuf_rs1_data),
        .tbuf_rs2_data  (tbuf_rs2_data),
        .tbuf_ready_eff (tbuf_ready_eff)
    );

    for (genvar bi = 0; bi < BLOCK_SIZE; ++bi) begin : g_blocks
        VX_tcu_core #(
            .INSTANCE_ID (`SFORMATF(("core%0d", bi)))
        ) tcu_core (
            .clk              (clk),
            .reset            (reset),
            .tbuf_rs1_data    (tbuf_rs1_data[bi]),
            .tbuf_rs2_data    (tbuf_rs2_data[bi]),
            .tbuf_ready       (tbuf_ready_eff[bi]),
            .ext_meta_wr_en   (meta_wr_en),
            .ext_meta_wr_wid  (meta_wr_wid),
            .ext_meta_wr_idx  (meta_wr_idx),
            .ext_meta_wr_data (meta_wr_data),
            .execute_if       (core_execute_if[bi]),
            .result_if        (core_result_if[bi])
        );

        assign res_valid [bi]                                      = core_result_if[bi].valid;
        assign core_result_if[bi].ready                            = res_ready[bi];
        assign res_wid   [bi*NW_WIDTH +: NW_WIDTH]                 = core_result_if[bi].data.header.wid;
        assign res_cta_id[bi*NCTA_WIDTH +: NCTA_WIDTH]             = core_result_if[bi].data.header.cta_id;
        assign res_tmask [bi*`VX_CFG_NUM_THREADS +: `VX_CFG_NUM_THREADS] = core_result_if[bi].data.header.tmask;
        assign res_PC    [bi*PC_BITS +: PC_BITS]                   = core_result_if[bi].data.header.PC;
        assign res_wb    [bi]                                      = core_result_if[bi].data.header.wb;
        assign res_rd    [bi*NUM_REGS_BITS +: NUM_REGS_BITS]       = core_result_if[bi].data.header.rd;
        assign res_data  [bi*BLOCK_DATA_BITS +: BLOCK_DATA_BITS]   = core_result_if[bi].data.data;
    end

endmodule
