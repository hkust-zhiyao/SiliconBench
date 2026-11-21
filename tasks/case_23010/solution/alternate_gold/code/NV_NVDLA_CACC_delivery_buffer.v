// ================================================================
// NVDLA Open Source Project
//
// Copyright(c) 2016 - 2017 NVIDIA Corporation.  Licensed under the
// NVDLA Open Hardware License; Check "LICENSE" which comes with
// this distribution for more information.
// ================================================================
// File Name: NV_NVDLA_CACC_delivery_buffer.v

module NV_NVDLA_CACC_delivery_buffer (
   input  wire         nvdla_core_clk
  ,input  wire         nvdla_core_rstn
  ,input  wire         cacc2sdp_ready
  ,input  wire         dbuf_rd_addr
  ,input  wire   [1:0] dbuf_rd_en
  ,input  wire         dbuf_rd_layer_end
  ,input  wire         dbuf_wr_addr
  ,input  wire [127:0] dbuf_wr_data
  ,input  wire   [1:0] dbuf_wr_en
  ,input  wire  [31:0] pwrbus_ram_pd
  ,output wire   [1:0] cacc2glb_done_intr_pd
  ,output wire [129:0] cacc2sdp_pd
  ,output wire         cacc2sdp_valid
  ,output wire         dbuf_rd_ready
);

  reg   [1:0] wr_en_q;
  reg         wr_ad_q;
  reg [127:0] wr_dt_q;

  always @(posedge nvdla_core_clk or negedge nvdla_core_rstn) begin
    if (!nvdla_core_rstn) begin
      wr_en_q <= 2'd0;
      wr_ad_q <= 1'b0;
    end else begin
      wr_en_q <= dbuf_wr_en;
      if (|dbuf_wr_en) wr_ad_q <= dbuf_wr_addr;
    end
  end
  always @(posedge nvdla_core_clk) begin
    if (|dbuf_wr_en) wr_dt_q <= dbuf_wr_data;
  end

  reg [127:0] mem_b0 [0:1];
  reg [127:0] mem_b1 [0:1];

  reg         st1_v, st2_v, st3_v;
  reg         st1_le, st2_le, st3_le;
  reg [127:0] st1_dt, st2_dt, st3_dt;

  wire rdy3 = cacc2sdp_ready;
  wire rdy2 = ~st3_v | rdy3;
  wire rdy1 = ~st2_v | rdy2;
  wire rdy0 = ~st1_v | rdy1;
  assign dbuf_rd_ready = rdy0;

  wire [127:0] b0_val = (wr_en_q[0] && (wr_ad_q == dbuf_rd_addr)) ? wr_dt_q : mem_b0[dbuf_rd_addr];
  wire [127:0] b1_val = (wr_en_q[1] && (wr_ad_q == dbuf_rd_addr)) ? wr_dt_q : mem_b1[dbuf_rd_addr];
  wire [127:0] rd_mux = dbuf_rd_en[1] ? b1_val : b0_val;
  wire         push0  = (|dbuf_rd_en) & rdy0;

  always @(posedge nvdla_core_clk) begin
    if (wr_en_q[0]) mem_b0[wr_ad_q] <= wr_dt_q;
    if (wr_en_q[1]) mem_b1[wr_ad_q] <= wr_dt_q;
    if (push0)      st1_dt          <= rd_mux;
    if (st1_v & rdy1) st2_dt        <= st1_dt;
    if (st2_v & rdy2) st3_dt        <= st2_dt;
  end

  always @(posedge nvdla_core_clk or negedge nvdla_core_rstn) begin
    if (!nvdla_core_rstn) begin
      st1_v <= 1'b0; st2_v <= 1'b0; st3_v <= 1'b0;
      st1_le <= 1'b0; st2_le <= 1'b0; st3_le <= 1'b0;
    end else begin
      if (push0) begin
        st1_v  <= 1'b1;
        st1_le <= dbuf_rd_layer_end;
      end else if (rdy1) begin
        st1_v  <= 1'b0;
      end

      if (st1_v & rdy1) begin
        st2_v  <= 1'b1;
        st2_le <= st1_le;
      end else if (rdy2) begin
        st2_v  <= 1'b0;
      end

      if (st2_v & rdy2) begin
        st3_v  <= 1'b1;
        st3_le <= st2_le;
      end else if (rdy3) begin
        st3_v  <= 1'b0;
      end
    end
  end

  assign cacc2sdp_valid = st3_v;
  assign cacc2sdp_pd    = {st3_le, 1'b0, st3_dt};

  wire       fire_done = st3_v & rdy3 & st3_le;
  reg        ping_q;
  reg  [1:0] intr_q;

  always @(posedge nvdla_core_clk or negedge nvdla_core_rstn) begin
    if (!nvdla_core_rstn) begin
      ping_q <= 1'b0;
      intr_q <= 2'b00;
    end else begin
      if (fire_done) ping_q <= ~ping_q;
      intr_q <= {fire_done & ping_q, fire_done & ~ping_q};
    end
  end

  assign cacc2glb_done_intr_pd = intr_q;

endmodule
