// Copyright 2018 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51

module cv32e41p_hwloop_regs #(
    parameter N_REGS     = 2,
    parameter N_REG_BITS = $clog2(N_REGS)
) (
    input logic clk,
    input logic rst_n,

    input logic [          31:0] hwlp_start_data_i,
    input logic [          31:0] hwlp_end_data_i,
    input logic [          31:0] hwlp_cnt_data_i,
    input logic [           2:0] hwlp_we_i,
    input logic [N_REG_BITS-1:0] hwlp_regid_i,

    input logic valid_i,
    input logic [N_REGS-1:0] hwlp_dec_cnt_i,

    output logic [N_REGS-1:0][31:0] hwlp_start_addr_o,
    output logic [N_REGS-1:0][31:0] hwlp_end_addr_o,
    output logic [N_REGS-1:0][31:0] hwlp_counter_o
);

  logic [N_REGS-1:0][31:0] hwlp_start_q;
  logic [N_REGS-1:0][31:0] hwlp_end_q;
  logic [N_REGS-1:0][31:0] hwlp_counter_q;

  assign hwlp_start_addr_o = hwlp_start_q;
  assign hwlp_end_addr_o   = hwlp_end_q;
  assign hwlp_counter_o    = hwlp_counter_q;

  for (genvar r = 0; r < N_REGS; r++) begin : gen_hwlp_slots
    logic sel_slot;
    assign sel_slot = (hwlp_regid_i == r[N_REG_BITS-1:0]);

    always_ff @(posedge clk or negedge rst_n) begin
      if (~rst_n) begin
        hwlp_start_q[r]   <= 32'h0;
        hwlp_end_q[r]     <= 32'h0;
        hwlp_counter_q[r] <= 32'h0;
      end else begin
        if (hwlp_we_i[0] & sel_slot) begin
          hwlp_start_q[r] <= hwlp_start_data_i;
        end
        if (hwlp_we_i[1] & sel_slot) begin
          hwlp_end_q[r] <= hwlp_end_data_i;
        end
        if (hwlp_we_i[2] & sel_slot) begin
          hwlp_counter_q[r] <= hwlp_cnt_data_i;
        end else if (valid_i & hwlp_dec_cnt_i[r] & (|hwlp_counter_q[r])) begin
          hwlp_counter_q[r] <= hwlp_counter_q[r] - 32'd1;
        end
      end
    end
  end

endmodule
