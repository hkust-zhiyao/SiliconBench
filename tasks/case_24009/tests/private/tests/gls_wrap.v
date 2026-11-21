`timescale 1ns/100ps

module util_pack_asic_cluster (
  input         clk,
  input         reset,
  input  [4:0]  en5,
  input         wr5_en,
  input  [59:0] wr5_data,
  output        p5_wr_en,
  output [59:0] p5_wr_data,
  output        p5_sync,
  input         rd5_en,
  output        rd5_valid,
  output        rd5_uflow,
  output [59:0] rd5_data,
  input         s5_valid,
  output        s5_ready,
  input  [59:0] s5_data
);

  util_cpack2_impl #(
    .NUM_OF_CHANNELS(5),
    .SAMPLES_PER_CHANNEL(1),
    .SAMPLE_DATA_WIDTH(12),
    .INTERFACE_TYPE(1),
    .PARALLEL_OR_SERIAL_N(1),
    .PIPELINE_STAGES(2)
  ) u_cpack5 (
    .clk(clk),
    .reset(reset),
    .enable(en5),
    .fifo_wr_en({5{wr5_en}}),
    .fifo_wr_overflow(),
    .fifo_wr_data(wr5_data),
    .m_axis_ready(1'b1),
    .m_axis_valid(),
    .m_axis_data(),
    .m_axis_keep(),
    .m_axis_last(),
    .packed_fifo_wr_en(p5_wr_en),
    .packed_fifo_wr_overflow(1'b0),
    .packed_fifo_wr_data(p5_wr_data),
    .packed_sync(p5_sync)
  );

  util_upack2_impl #(
    .NUM_OF_CHANNELS(5),
    .SAMPLES_PER_CHANNEL(1),
    .SAMPLE_DATA_WIDTH(12),
    .PARALLEL_OR_SERIAL_N(1),
    .PIPELINE_STAGES(2)
  ) u_upack5 (
    .clk(clk),
    .reset(reset),
    .enable(en5),
    .fifo_rd_en({5{rd5_en}}),
    .fifo_rd_valid(rd5_valid),
    .fifo_rd_underflow(rd5_uflow),
    .fifo_rd_data(rd5_data),
    .s_axis_valid(s5_valid),
    .s_axis_ready(s5_ready),
    .s_axis_data(s5_data)
  );

endmodule
