
module tc_sram #(
  parameter int unsigned NumWords     = 32'd256,
  parameter int unsigned DataWidth    = 32'd64,
  parameter int unsigned ByteWidth    = 32'd8,
  parameter int unsigned NumPorts     = 32'd1,
  parameter int unsigned Latency      = 32'd1,
  parameter              SimInit      = "none",
  parameter bit          PrintSimCfg  = 1'b0,
  parameter              ImplKey      = "none",
  parameter int unsigned AddrWidth = (NumWords > 32'd1) ? $clog2(NumWords) : 32'd1,
  parameter int unsigned BeWidth   = (DataWidth + ByteWidth - 32'd1) / ByteWidth,
  parameter type         addr_t    = logic [AddrWidth-1:0],
  parameter type         data_t    = logic [DataWidth-1:0],
  parameter type         be_t      = logic [BeWidth-1:0]
) (
  input  logic                 clk_i,
  input  logic                 rst_ni,
  input  logic  [NumPorts-1:0] req_i,
  input  logic  [NumPorts-1:0] we_i,
  input  addr_t [NumPorts-1:0] addr_i,
  input  data_t [NumPorts-1:0] wdata_i,
  input  be_t   [NumPorts-1:0] be_i,
  output data_t [NumPorts-1:0] rdata_o
);
  logic [NumPorts-1:0][DataWidth-1:0] bm;
  for (genvar p = 0; p < NumPorts; ++p) begin : gen_bm_ports
    for (genvar b = 0; b < DataWidth; ++b) begin : gen_bm_bits
      assign bm[p][b] = be_i[p][b / ByteWidth];
    end
  end
  if (NumWords == 64 && DataWidth <= 64 && NumPorts == 1 && Latency == 1) begin : gen_64x64
    logic [63:0] wdata64, rdata64, bm64;
    assign wdata64 = 64'(wdata_i[0]);
    assign bm64    = 64'(bm[0]);
    assign rdata_o[0] = rdata64[DataWidth-1:0];
    RM_IHPSG13_1P_64x64_c2_bm_bist i_cut (
      .A_CLK(clk_i), .A_ADDR(addr_i[0][5:0]), .A_BM(bm64),
      .A_MEN(req_i[0]), .A_WEN(we_i[0]), .A_REN(~we_i[0]),
      .A_DIN(wdata64), .A_DOUT(rdata64),
      .A_BIST_CLK(1'b0), .A_BIST_ADDR(6'd0), .A_BIST_DIN(64'd0), .A_BIST_BM(64'd0),
      .A_BIST_MEN(1'b0), .A_BIST_WEN(1'b0), .A_BIST_REN(1'b0), .A_BIST_EN(1'b0), .A_DLY(1'b0)
    );
  end else if (NumWords == 256 && DataWidth == 64 && NumPorts == 1 && Latency == 1) begin : gen_256x64
    RM_IHPSG13_1P_256x64_c2_bm_bist i_cut (
      .A_CLK(clk_i), .A_ADDR(addr_i[0][7:0]), .A_BM(bm[0]),
      .A_MEN(req_i[0]), .A_WEN(we_i[0]), .A_REN(~we_i[0]),
      .A_DIN(wdata_i[0]), .A_DOUT(rdata_o[0]),
      .A_BIST_CLK(1'b0), .A_BIST_ADDR(8'd0), .A_BIST_DIN(64'd0), .A_BIST_BM(64'd0),
      .A_BIST_MEN(1'b0), .A_BIST_WEN(1'b0), .A_BIST_REN(1'b0), .A_BIST_EN(1'b0), .A_DLY(1'b0)
    );
  end
endmodule
