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

  reg   [1:0] dbuf_wr_en_d1;
  reg         dbuf_wr_addr_d1;
  reg [127:0] dbuf_wr_data_d1;

  always @(posedge nvdla_core_clk or negedge nvdla_core_rstn) begin
    if (!nvdla_core_rstn) begin
      dbuf_wr_en_d1   <= 2'd0;
      dbuf_wr_addr_d1 <= 1'b0;
    end else begin
      dbuf_wr_en_d1 <= dbuf_wr_en;
      if (|dbuf_wr_en) dbuf_wr_addr_d1 <= dbuf_wr_addr;
    end
  end
  always @(posedge nvdla_core_clk) begin
    if (|dbuf_wr_en) dbuf_wr_data_d1 <= dbuf_wr_data;
  end

  reg [127:0] bank_mem_0 [0:1];
  reg [127:0] bank_mem_1 [0:1];

  reg [127:0] dbuf_rd_data_0;
  reg [127:0] dbuf_rd_data_1;

  reg         dbuf_rd_valid_d1, dbuf_rd_valid_d2, dbuf_rd_valid_d3;
  reg   [1:0] dbuf_rd_en_d1;
  reg         dbuf_rd_addr_d1;
  reg         dbuf_rd_layer_end_d1, dbuf_rd_layer_end_d2, dbuf_rd_layer_end_d3;
  reg [127:0] dbuf_rd_data_ecc_d2;
  reg [127:0] dbuf_rd_data_d3;

  wire        dbuf_rd_ready_d3 = cacc2sdp_ready;
  wire        dbuf_rd_ready_d2 = ~dbuf_rd_valid_d3 | dbuf_rd_ready_d3;
  wire        dbuf_rd_ready_d1 = ~dbuf_rd_valid_d2 | dbuf_rd_ready_d2;
  wire        dbuf_rd_ready_d0 = ~dbuf_rd_valid_d1 | dbuf_rd_ready_d1;

  assign dbuf_rd_ready = dbuf_rd_ready_d0;

  wire  [1:0] dbuf_rd_en_in   = dbuf_rd_ready_d0 ? dbuf_rd_en   : dbuf_rd_en_d1;
  wire        dbuf_rd_addr_in = dbuf_rd_ready_d0 ? dbuf_rd_addr : dbuf_rd_addr_d1;

  always @(posedge nvdla_core_clk) begin
    if (dbuf_wr_en_d1[0]) bank_mem_0[dbuf_wr_addr_d1] <= dbuf_wr_data_d1;
    if (dbuf_wr_en_d1[1]) bank_mem_1[dbuf_wr_addr_d1] <= dbuf_wr_data_d1;

    if (dbuf_rd_en_in[0]) dbuf_rd_data_0 <= (dbuf_wr_en_d1[0] && (dbuf_wr_addr_d1 == dbuf_rd_addr_in)) ? dbuf_wr_data_d1 : bank_mem_0[dbuf_rd_addr_in];
    if (dbuf_rd_en_in[1]) dbuf_rd_data_1 <= (dbuf_wr_en_d1[1] && (dbuf_wr_addr_d1 == dbuf_rd_addr_in)) ? dbuf_wr_data_d1 : bank_mem_1[dbuf_rd_addr_in];
  end

  wire dbuf_rd_d0_reg_en   = (|dbuf_rd_en) & dbuf_rd_ready_d0;
  wire dbuf_rd_valid_d1_w  = dbuf_rd_d0_reg_en ? 1'b1 :
                             dbuf_rd_ready_d1  ? 1'b0 :
                             dbuf_rd_valid_d1;

  wire [127:0] dbuf_rd_data_ecc_d2_w = ({128{dbuf_rd_en_d1[0]}} & dbuf_rd_data_0)
                                     | ({128{dbuf_rd_en_d1[1]}} & dbuf_rd_data_1);

  wire dbuf_rd_d1_reg_en   = dbuf_rd_valid_d1 & dbuf_rd_ready_d1;
  wire dbuf_rd_valid_d2_w  = dbuf_rd_valid_d1 ? 1'b1 :
                             dbuf_rd_ready_d2 ? 1'b0 :
                             dbuf_rd_valid_d2;

  wire dbuf_rd_d2_reg_en   = dbuf_rd_valid_d2 & dbuf_rd_ready_d2;
  wire dbuf_rd_valid_d3_w  = dbuf_rd_valid_d2 ? 1'b1 :
                             dbuf_rd_ready_d3 ? 1'b0 :
                             dbuf_rd_valid_d3;

  always @(posedge nvdla_core_clk or negedge nvdla_core_rstn) begin
    if (!nvdla_core_rstn) begin
      dbuf_rd_valid_d1     <= 1'b0;
      dbuf_rd_en_d1        <= 2'd0;
      dbuf_rd_addr_d1      <= 1'b0;
      dbuf_rd_layer_end_d1 <= 1'b0;
      dbuf_rd_valid_d2     <= 1'b0;
      dbuf_rd_layer_end_d2 <= 1'b0;
      dbuf_rd_valid_d3     <= 1'b0;
      dbuf_rd_layer_end_d3 <= 1'b0;
    end else begin
      dbuf_rd_valid_d1 <= dbuf_rd_valid_d1_w;
      if (dbuf_rd_d0_reg_en) begin
        dbuf_rd_en_d1        <= dbuf_rd_en;
        dbuf_rd_addr_d1      <= dbuf_rd_addr;
        dbuf_rd_layer_end_d1 <= dbuf_rd_layer_end;
      end

      dbuf_rd_valid_d2 <= dbuf_rd_valid_d2_w;
      if (dbuf_rd_d1_reg_en) dbuf_rd_layer_end_d2 <= dbuf_rd_layer_end_d1;
      dbuf_rd_valid_d3 <= dbuf_rd_valid_d3_w;
      if (dbuf_rd_d2_reg_en) dbuf_rd_layer_end_d3 <= dbuf_rd_layer_end_d2;
    end
  end
  always @(posedge nvdla_core_clk) begin
    if (dbuf_rd_d1_reg_en) dbuf_rd_data_ecc_d2 <= dbuf_rd_data_ecc_d2_w;
    if (dbuf_rd_d2_reg_en) dbuf_rd_data_d3     <= dbuf_rd_data_ecc_d2;
  end

  assign cacc2sdp_valid = dbuf_rd_valid_d3;
  assign cacc2sdp_pd    = {dbuf_rd_layer_end_d3, 1'b0, dbuf_rd_data_d3};

  wire       cacc_done        = dbuf_rd_valid_d3 & dbuf_rd_ready_d3 & dbuf_rd_layer_end_d3;
  reg        intr_sel;
  reg  [1:0] cacc_done_intr;

  always @(posedge nvdla_core_clk or negedge nvdla_core_rstn) begin
    if (!nvdla_core_rstn) begin
      intr_sel       <= 1'b0;
      cacc_done_intr <= 2'b00;
    end else begin
      if (cacc_done) begin
        intr_sel <= ~intr_sel;
      end
      cacc_done_intr <= {cacc_done & intr_sel, cacc_done & ~intr_sel};
    end
  end

  assign cacc2glb_done_intr_pd = cacc_done_intr;

endmodule
