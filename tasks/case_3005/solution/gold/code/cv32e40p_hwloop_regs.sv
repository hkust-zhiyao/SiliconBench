// Copyright 2018 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51

module cv32e40p_hwloop_regs #(
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
  logic [N_REGS-1:0][31:0] hwlp_counter_q, hwlp_counter_n;

  int unsigned i;

  assign hwlp_start_addr_o = hwlp_start_q;
  assign hwlp_end_addr_o   = hwlp_end_q;
  assign hwlp_counter_o    = hwlp_counter_q;

  always_ff @(posedge clk, negedge rst_n) begin : HWLOOP_REGS_START
    if (rst_n == 1'b0) begin
      hwlp_start_q <= '{default: 32'b0};
    end else if (valid_i && (hwlp_we_i[0] == 1'b1)) begin
      hwlp_start_q[hwlp_regid_i] <= {hwlp_start_data_i[31:1], 1'b0};
    end
  end

  always_ff @(posedge clk, negedge rst_n) begin : HWLOOP_REGS_END
    if (rst_n == 1'b0) begin
      hwlp_end_q <= '{default: 32'b0};
    end else if (valid_i && (hwlp_we_i[1] == 1'b1)) begin
      hwlp_end_q[hwlp_regid_i] <= {hwlp_end_data_i[31:1], 1'b0};
    end
  end

  genvar k;
  for (k = 0; k < N_REGS; k++) begin : gen_dec
    assign hwlp_counter_n[k] = (hwlp_counter_q[k] > 32'd0) ? (hwlp_counter_q[k] - 32'd1) : 32'd0;
  end

  always_ff @(posedge clk, negedge rst_n) begin : HWLOOP_REGS_COUNTER
    if (rst_n == 1'b0) begin
      hwlp_counter_q <= '{default: 32'b0};
    end else if (valid_i) begin
      for (i = 0; i < N_REGS; i++) begin
        if ((hwlp_we_i[2] == 1'b1) && (i[N_REG_BITS-1:0] == hwlp_regid_i)) begin
          hwlp_counter_q[i] <= hwlp_cnt_data_i;
        end else if (hwlp_dec_cnt_i[i]) begin
          if ((i == 1) && hwlp_dec_cnt_i[0] && (hwlp_counter_q[0] > 32'd1) &&
              !((hwlp_we_i[2] == 1'b1) && (hwlp_regid_i == '0))) begin
            hwlp_counter_q[i] <= hwlp_counter_q[i];
          end else begin
            hwlp_counter_q[i] <= hwlp_counter_n[i];
          end
        end
      end
    end
  end

endmodule
