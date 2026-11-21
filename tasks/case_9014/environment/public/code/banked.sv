// Four-cluster BlackParrot I-Cache 256x128 SRAM wrapper with byte-reverse/XOR low-to-high relay.
module banked (
  input  logic         clk_i,
  input  logic         rst_ni,
  input  logic [3:0]   req_i,
  input  logic [3:0]   we_i,
  input  logic [3:0]   relay_i,
  input  logic [1:0]   swap_mode_i,
  input  logic [7:0]   addr_i,
  input  logic [127:0] wdata_i,
  input  logic [15:0]  be_i,
  output logic [127:0] rdata_o
);
  wire [127:0] rdata [4];

  for (genvar i = 0; i < 4; i = i + 1) begin : cluster
    wire [127:0] wd = relay_i[i] ? {rdata[i][127:64], wdata_i[63:0]} : wdata_i;
    wire [15:0]  be = be_i;

    bp_sram_256x128 mem (
      .clk_i   ( clk_i     ),
      .rst_ni  ( rst_ni    ),
      .req_i   ( req_i[i]  ),
      .we_i    ( we_i[i]   ),
      .addr_i  ( addr_i    ),
      .wdata_i ( wd        ),
      .be_i    ( be        ),
      .rdata_o ( rdata[i]  )
    );
  end

  assign rdata_o = {
    rdata[0][127:64] ^ rdata[1][127:64] ^ rdata[2][127:64] ^ rdata[3][127:64],
    rdata[0][63:0]   ^ rdata[1][63:0]   ^ rdata[2][63:0]
  };
endmodule
