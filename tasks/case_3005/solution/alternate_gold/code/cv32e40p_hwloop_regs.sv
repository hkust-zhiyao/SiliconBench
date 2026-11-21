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

  logic [N_REGS-1:0][31:0] start_r, end_r, cnt_r;
  logic                    inner_keeps_looping;

  assign hwlp_start_addr_o = start_r;
  assign hwlp_end_addr_o   = end_r;
  assign hwlp_counter_o    = cnt_r;

  assign inner_keeps_looping = hwlp_dec_cnt_i[0] && (cnt_r[0] > 32'd1) &&
                               !(hwlp_we_i[2] && (hwlp_regid_i == 1'b0));

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      start_r <= '0;
      end_r   <= '0;
      cnt_r   <= '0;
    end else if (valid_i) begin
      if (hwlp_we_i[0]) start_r[hwlp_regid_i] <= {hwlp_start_data_i[31:1], 1'b0};
      if (hwlp_we_i[1]) end_r[hwlp_regid_i]   <= {hwlp_end_data_i[31:1], 1'b0};

      if (hwlp_we_i[2] && (hwlp_regid_i == 1'b0)) begin
        cnt_r[0] <= hwlp_cnt_data_i;
      end else if (hwlp_dec_cnt_i[0] && (|cnt_r[0])) begin
        cnt_r[0] <= cnt_r[0] - 32'd1;
      end

      if (hwlp_we_i[2] && (hwlp_regid_i == 1'b1)) begin
        cnt_r[1] <= hwlp_cnt_data_i;
      end else if (hwlp_dec_cnt_i[1] && !inner_keeps_looping && (|cnt_r[1])) begin
        cnt_r[1] <= cnt_r[1] - 32'd1;
      end
    end
  end

endmodule
