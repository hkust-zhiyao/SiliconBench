// Copyright 2023 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
//
// Mask Unit Operands Module (Alternate Architecture: Gather Deshuffle + Active Body Mask)

module masku_operands import ara_pkg::*; import rvv_pkg::*; #(
    parameter int unsigned NrLanes   = 0,
    parameter type         pe_req_t  = logic,
    parameter type         pe_resp_t = logic,
    localparam int unsigned VlBitMaskEnable = 1
  ) (
    input logic clk_i,
    input logic rst_ni,

    // Control logic
    input masku_fu_e                        masku_fu_i,
    input pe_req_t                          vinsn_issue_i,
    input logic [idx_width(ELEN*NrLanes):0] vrf_pnt_i,

    // Operands and operand handshake signals coming from lanes
    input  logic  [NrLanes-1:0][NrMaskFUnits+2-1:0] masku_operand_valid_i,
    output logic  [NrLanes-1:0][NrMaskFUnits+2-1:0] masku_operand_ready_o,
    input  elen_t [NrLanes-1:0][NrMaskFUnits+2-1:0] masku_operands_i,

    // Operands prepared for masku execution
    output elen_t [     NrLanes-1:0] masku_operand_alu_o,
    output logic  [     NrLanes-1:0] masku_operand_alu_valid_o,
    input  logic  [     NrLanes-1:0] masku_operand_alu_ready_i,
    output logic  [NrLanes*ELEN-1:0] masku_operand_alu_seq_o,
    output logic  [     NrLanes-1:0] masku_operand_alu_seq_valid_o,
    input  logic  [     NrLanes-1:0] masku_operand_alu_seq_ready_i,
    output elen_t [     NrLanes-1:0] masku_operand_vd_o,
    output logic  [     NrLanes-1:0] masku_operand_vd_valid_o,
    input  logic  [     NrLanes-1:0] masku_operand_vd_ready_i,
    output logic  [NrLanes*ELEN-1:0] masku_operand_vd_seq_o,
    output logic  [     NrLanes-1:0] masku_operand_vd_seq_valid_o,
    input  logic  [     NrLanes-1:0] masku_operand_vd_seq_ready_i,
    output elen_t [     NrLanes-1:0] masku_operand_m_o,
    output logic  [     NrLanes-1:0] masku_operand_m_valid_o,
    input  logic  [     NrLanes-1:0] masku_operand_m_ready_i,
    output logic  [NrLanes*ELEN-1:0] masku_operand_m_seq_o,
    output logic  [     NrLanes-1:0] masku_operand_m_seq_valid_o,
    input  logic  [     NrLanes-1:0] masku_operand_m_seq_ready_i,
    output logic  [NrLanes*ELEN-1:0] bit_enable_mask_o,
    output logic  [NrLanes*ELEN-1:0] alu_result_compressed_seq_o
  );

  import cf_math_pkg::idx_width;

  localparam int unsigned DATAPATH_WIDTH = NrLanes * ELEN;

  elen_t [NrLanes-1:0] masku_operand_vd_d;
  logic  [NrLanes-1:0] masku_operand_vd_lane_valid;
  logic  [NrLanes-1:0] masku_operand_vd_lane_ready;
  logic  [NrLanes-1:0] masku_operand_vd_spill_valid;
  logic  [NrLanes-1:0] masku_operand_vd_spill_ready;

  elen_t [NrLanes-1:0] masku_operand_m_d;
  logic  [NrLanes-1:0] masku_operand_m_lane_valid;
  logic  [NrLanes-1:0] masku_operand_m_lane_ready;
  logic  [NrLanes-1:0] masku_operand_m_spill_valid;
  logic  [NrLanes-1:0] masku_operand_m_spill_ready;

  for (genvar lane = 0; lane < NrLanes; lane++) begin : gen_extract_lane_ops
    assign masku_operand_alu_o[lane] = masku_operands_i[lane][2 + masku_fu_i];
    assign masku_operand_vd_d[lane]  = masku_operands_i[lane][1];
    assign masku_operand_m_d[lane]   = masku_operands_i[lane][0];
  end

  // Gather-based deshuffling: for each sequential byte index seq_b, locate its shuffled lane & byte offset
  always_comb begin
    masku_operand_alu_seq_o = '0;
    masku_operand_vd_seq_o  = '0;
    masku_operand_m_seq_o   = '0;
    for (int seq_b = 0; seq_b < (NrLanes * ELENB); seq_b++) begin
      automatic int shuf_alu = shuffle_index(16'(seq_b), NrLanes, vinsn_issue_i.eew_vs2);
      automatic int shuf_vd  = shuffle_index(16'(seq_b), NrLanes, vinsn_issue_i.eew_vd_op);
      automatic int shuf_m   = shuffle_index(16'(seq_b), NrLanes, vinsn_issue_i.eew_vmask);

      masku_operand_alu_seq_o[8*seq_b +: 8] = masku_operand_alu_o[shuf_alu / ELENB][8*(shuf_alu % ELENB) +: 8];
      masku_operand_vd_seq_o[8*seq_b +: 8]  = masku_operand_vd_o[shuf_vd / ELENB][8*(shuf_vd % ELENB) +: 8];
      masku_operand_m_seq_o[8*seq_b +: 8]   = masku_operand_m_o[shuf_m / ELENB][8*(shuf_m % ELENB) +: 8];
    end
  end

  // Provide sequential active-mask vector (vm ? '1 : m_seq) on bit_enable_mask_o
  always_comb begin
    if (VlBitMaskEnable) begin
      bit_enable_mask_o = vinsn_issue_i.vm ? {DATAPATH_WIDTH{1'b1}} : masku_operand_m_seq_o;
    end else begin
      bit_enable_mask_o = '0;
    end
  end

  always_comb begin
    masku_operand_vd_spill_ready = '0;
    masku_operand_m_spill_ready  = '0;
    for (int lane = 0; lane < NrLanes; lane++) begin
      masku_operand_vd_spill_ready[lane] = masku_operand_vd_ready_i[lane] | masku_operand_vd_seq_ready_i[lane];
      masku_operand_m_spill_ready[lane]  = masku_operand_m_ready_i[lane]  | masku_operand_m_seq_ready_i[lane];
    end
  end

  for (genvar lane = 0; lane < NrLanes; lane++) begin : gen_masku_operands_spill_regs
    spill_register #(
      .T ( elen_t )
    ) i_spill_register_vd (
      .clk_i   (clk_i),
      .rst_ni  (rst_ni),
      .valid_i (masku_operand_vd_lane_valid[lane]),
      .ready_o (masku_operand_vd_lane_ready[lane]),
      .data_i  (masku_operand_vd_d[lane]),
      .valid_o (masku_operand_vd_spill_valid[lane]),
      .ready_i (masku_operand_vd_spill_ready[lane]),
      .data_o  (masku_operand_vd_o[lane])
    );

    spill_register #(
      .T ( elen_t )
    ) i_spill_register_m (
      .clk_i   (clk_i),
      .rst_ni  (rst_ni),
      .valid_i (masku_operand_m_lane_valid[lane]),
      .ready_o (masku_operand_m_lane_ready[lane]),
      .data_i  (masku_operand_m_d[lane]),
      .valid_o (masku_operand_m_spill_valid[lane]),
      .ready_i (masku_operand_m_spill_ready[lane]),
      .data_o  (masku_operand_m_o[lane])
    );
  end

  for (genvar lane = 0; lane < NrLanes; lane++) begin : gen_spill_valids
    assign masku_operand_alu_seq_valid_o[lane] = masku_operand_valid_i[lane][2 + masku_fu_i];
    assign masku_operand_vd_valid_o[lane]      = masku_operand_vd_spill_valid[lane];
    assign masku_operand_vd_seq_valid_o[lane]  = masku_operand_vd_spill_valid[lane];
    assign masku_operand_m_valid_o[lane]       = masku_operand_m_spill_valid[lane];
    assign masku_operand_m_seq_valid_o[lane]   = masku_operand_m_spill_valid[lane];
  end

  always_comb begin
    masku_operand_vd_lane_valid = '0;
    masku_operand_m_lane_valid  = '0;
    for (int lane = 0; lane < NrLanes; lane++) begin
      masku_operand_vd_lane_valid[lane] = masku_operand_valid_i[lane][1];
      masku_operand_m_lane_valid[lane]  = masku_operand_valid_i[lane][0];
    end
  end

  // Compress ALU/FPU comparison results into a sequential mask vector
  always_comb begin
    alu_result_compressed_seq_o = '1;
    for (int b = 0; b < ELENB * NrLanes; b++) begin
      if ((b % (1 << vinsn_issue_i.eew_vs2)) == '0) begin
        automatic int src_byte        = shuffle_index(16'(b), NrLanes, vinsn_issue_i.eew_vs2);
        automatic int src_byte_lane   = src_byte[idx_width(ELENB) +: idx_width(NrLanes)];
        automatic int src_byte_offset = src_byte[idx_width(ELENB)-1:0];

        automatic int dest_bit_seq  = (b >> vinsn_issue_i.eew_vs2) + vrf_pnt_i;
        automatic int dest_byte_seq = dest_bit_seq / ELENB;
        alu_result_compressed_seq_o[ELENB * dest_byte_seq + dest_bit_seq[idx_width(ELENB)-1:0]] =
          masku_operand_alu_o[src_byte_lane][8 * src_byte_offset];
      end
    end
  end

  for (genvar lane = 0; lane < NrLanes; lane++) begin : gen_unpack_masku_operands
    assign masku_operand_alu_valid_o[lane] = masku_operand_valid_i[lane][2 + masku_fu_i];
  end

  always_comb begin
    masku_operand_ready_o = '0;
    for (int lane = 0; lane < NrLanes; lane++) begin
      for (int operand_fu = 0; operand_fu < NrMaskFUnits; operand_fu++) begin
        masku_operand_ready_o[lane][2 + operand_fu] =
          (masku_fu_e'(operand_fu) == masku_fu_i) &&
          (masku_operand_alu_ready_i[lane] | masku_operand_alu_seq_ready_i[lane]);
      end
      masku_operand_ready_o[lane][1] = masku_operand_vd_lane_ready[lane];
      masku_operand_ready_o[lane][0] = masku_operand_m_lane_ready[lane];
    end
  end

endmodule : masku_operands
