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
  wire [7:0]   low_be_perm = swap_mode_i[0] ? {
    be_i[4], be_i[5], be_i[6], be_i[7],
    be_i[0], be_i[1], be_i[2], be_i[3]
  } : be_i[7:0];

  for (genvar i = 0; i < 4; i = i + 1) begin : cluster
    wire [31:0] rev_hi32 = {rdata[i][39:32], rdata[i][47:40], rdata[i][55:48], rdata[i][63:56]};
    wire [31:0] rev_lo32 = {rdata[i][7:0],   rdata[i][15:8],  rdata[i][23:16], rdata[i][31:24]};
    wire [63:0] low_perm = swap_mode_i[0] ? {rev_hi32, rev_lo32} : rdata[i][63:0];
    wire [63:0] rel_hi   = swap_mode_i[1] ? (low_perm ^ wdata_i[127:64]) : low_perm;
    wire [127:0] wd      = relay_i[i] ? {rel_hi, wdata_i[63:0]} : wdata_i;
    wire [15:0]  be      = relay_i[i] ? {be_i[15:8] | low_be_perm, be_i[7:0] & be_i[15:8]} : be_i;

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

  assign rdata_o = rdata[0] ^ rdata[1] ^ rdata[2] ^ rdata[3];
endmodule
