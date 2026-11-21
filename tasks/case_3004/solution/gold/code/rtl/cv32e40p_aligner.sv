// Copyright 2018 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51

module cv32e40p_aligner (
    input logic clk,
    input logic rst_n,

    input  logic fetch_valid_i,
    output logic aligner_ready_o,

    input logic if_valid_i,

    input  logic [31:0] fetch_rdata_i,
    input  logic        fetch_err_i,
    output logic [31:0] instr_aligned_o,
    output logic        instr_valid_o,
    output logic        instr_err_o,

    input logic [31:0] branch_addr_i,
    input logic        branch_i,

    input logic [31:0] hwlp_addr_i,
    input logic        hwlp_update_pc_i,

    output logic [31:0] pc_o
);

  enum logic [2:0] {
    ALIGNED32,
    MISALIGNED32,
    MISALIGNED16,
    BRANCH_MISALIGNED,
    WAIT_VALID_BRANCH
  } state, next_state;

  logic [15:0] r_instr_h;
  logic        r_err_q;
  logic [31:0] hwlp_addr_q;
  logic [31:0] pc_q, pc_n;
  logic        update_state;
  logic [31:0] pc_plus4, pc_plus2;
  logic        aligner_ready_q, hwlp_update_pc_q;

  logic        hwlp_active;
  logic [31:0] hwlp_target_mux;

  assign pc_o            = pc_q;
  assign pc_plus2        = pc_q + 32'd2;
  assign pc_plus4        = pc_q + 32'd4;
  assign hwlp_active     = hwlp_update_pc_i || hwlp_update_pc_q;
  assign hwlp_target_mux = hwlp_update_pc_i ? hwlp_addr_i : hwlp_addr_q;

  always_ff @(posedge clk or negedge rst_n) begin : proc_SEQ_FSM
    if (~rst_n) begin
      state            <= ALIGNED32;
      r_instr_h        <= '0;
      r_err_q          <= 1'b0;
      hwlp_addr_q      <= '0;
      pc_q             <= '0;
      aligner_ready_q  <= 1'b0;
      hwlp_update_pc_q <= 1'b0;
    end else begin
      if (update_state) begin
        pc_q             <= pc_n;
        state            <= next_state;
        r_instr_h        <= fetch_rdata_i[31:16];
        r_err_q          <= fetch_err_i;
        aligner_ready_q  <= aligner_ready_o;
        hwlp_update_pc_q <= 1'b0;
      end else if (hwlp_update_pc_i) begin
        hwlp_addr_q      <= hwlp_addr_i;
        hwlp_update_pc_q <= 1'b1;
      end
    end
  end

  always_comb begin
    pc_n            = pc_q;
    instr_valid_o   = fetch_valid_i;
    instr_err_o     = 1'b0;
    instr_aligned_o = fetch_rdata_i;
    aligner_ready_o = 1'b1;
    update_state    = 1'b0;
    next_state      = state;

    case (state)
      ALIGNED32: begin
        update_state = fetch_valid_i & if_valid_i;
        if (fetch_valid_i && fetch_err_i) begin
          instr_valid_o = 1'b1;
          instr_err_o   = 1'b1;
          pc_n          = pc_q;
          next_state    = WAIT_VALID_BRANCH;
        end else if (fetch_rdata_i[1:0] == 2'b11) begin
          next_state = hwlp_active ? (hwlp_target_mux[1] ? BRANCH_MISALIGNED : ALIGNED32) : ALIGNED32;
          pc_n       = hwlp_active ? hwlp_target_mux : pc_plus4;
        end else begin
          next_state = hwlp_active ? (hwlp_target_mux[1] ? BRANCH_MISALIGNED : ALIGNED32) : MISALIGNED32;
          pc_n       = hwlp_active ? hwlp_target_mux : pc_plus2;
        end
      end

      MISALIGNED32: begin
        if (r_instr_h[1:0] == 2'b11) begin
          instr_aligned_o = {fetch_rdata_i[15:0], r_instr_h[15:0]};
          update_state    = fetch_valid_i & if_valid_i;
          if (fetch_valid_i && fetch_err_i) begin
            instr_valid_o = 1'b1;
            instr_err_o   = 1'b1;
            pc_n          = pc_q;
            next_state    = WAIT_VALID_BRANCH;
          end else begin
            next_state = hwlp_active ? (hwlp_target_mux[1] ? BRANCH_MISALIGNED : ALIGNED32) : MISALIGNED32;
            pc_n       = hwlp_active ? hwlp_target_mux : pc_plus4;
          end
        end else begin
          instr_aligned_o = {fetch_rdata_i[31:16], r_instr_h[15:0]};
          instr_valid_o   = 1'b1;
          instr_err_o     = 1'b0;
          next_state      = hwlp_active ? (hwlp_target_mux[1] ? BRANCH_MISALIGNED : ALIGNED32) : MISALIGNED16;
          pc_n            = hwlp_active ? hwlp_target_mux : pc_plus2;
          aligner_ready_o = !fetch_valid_i;
          update_state    = if_valid_i;
        end
      end

      MISALIGNED16: begin
        instr_valid_o = !aligner_ready_q || fetch_valid_i;
        update_state  = instr_valid_o & if_valid_i;
        if (instr_valid_o && (!aligner_ready_q ? r_err_q : fetch_err_i)) begin
          instr_err_o = 1'b1;
          pc_n        = pc_q;
          next_state  = WAIT_VALID_BRANCH;
        end else if (fetch_rdata_i[1:0] == 2'b11) begin
          next_state = hwlp_active ? (hwlp_target_mux[1] ? BRANCH_MISALIGNED : ALIGNED32) : ALIGNED32;
          pc_n       = hwlp_active ? hwlp_target_mux : pc_plus4;
        end else begin
          next_state = hwlp_active ? (hwlp_target_mux[1] ? BRANCH_MISALIGNED : ALIGNED32) : MISALIGNED32;
          pc_n       = hwlp_active ? hwlp_target_mux : pc_plus2;
        end
      end

      BRANCH_MISALIGNED: begin
        update_state = fetch_valid_i & if_valid_i;
        if (fetch_valid_i && fetch_err_i) begin
          instr_valid_o   = 1'b1;
          instr_err_o     = 1'b1;
          instr_aligned_o = {fetch_rdata_i[31:16], fetch_rdata_i[31:16]};
          pc_n            = pc_q;
          next_state      = WAIT_VALID_BRANCH;
        end else if (fetch_rdata_i[17:16] == 2'b11) begin
          next_state      = MISALIGNED32;
          instr_valid_o   = 1'b0;
          pc_n            = pc_q;
          instr_aligned_o = fetch_rdata_i;
        end else begin
          next_state      = hwlp_active ? (hwlp_target_mux[1] ? BRANCH_MISALIGNED : ALIGNED32) : ALIGNED32;
          pc_n            = hwlp_active ? hwlp_target_mux : pc_plus2;
          instr_aligned_o = {fetch_rdata_i[31:16], fetch_rdata_i[31:16]};
        end
      end

      default: begin
        instr_valid_o   = 1'b0;
        instr_err_o     = 1'b0;
        aligner_ready_o = 1'b0;
        pc_n            = pc_q;
        next_state      = WAIT_VALID_BRANCH;
        update_state    = 1'b0;
      end
    endcase

    if (branch_i) begin
      update_state = 1'b1;
      pc_n         = branch_addr_i;
      next_state   = branch_addr_i[1] ? BRANCH_MISALIGNED : ALIGNED32;
    end
  end

endmodule
