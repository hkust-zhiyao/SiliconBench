// Four-cluster BlackParrot I-Cache 256x128 SRAM wrapper with byte-reverse/XOR low-to-high relay (alternate implementation).
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
  logic [127:0] cluster_dout [4];
  logic [7:0]   be_lo_swapped;

  always_comb begin
    for (int b = 0; b < 4; b++) begin
      be_lo_swapped[b]   = swap_mode_i[0] ? be_i[3-b] : be_i[b];
      be_lo_swapped[4+b] = swap_mode_i[0] ? be_i[7-b] : be_i[4+b];
    end
  end

  for (genvar i = 0; i < 4; i = i + 1) begin : cluster
    logic [63:0] perm_dout;
    logic [63:0] hi_wdata;
    logic [127:0] full_wdata;
    logic [15:0]  full_be;

    always_comb begin
      if (swap_mode_i[0]) begin
        perm_dout[31:0]  = {cluster_dout[i][7:0],   cluster_dout[i][15:8],  cluster_dout[i][23:16], cluster_dout[i][31:24]};
        perm_dout[63:32] = {cluster_dout[i][39:32], cluster_dout[i][47:40], cluster_dout[i][55:48], cluster_dout[i][63:56]};
      end else begin
        perm_dout = cluster_dout[i][63:0];
      end
      hi_wdata   = swap_mode_i[1] ? (perm_dout ^ wdata_i[127:64]) : perm_dout;
      full_wdata = relay_i[i] ? {hi_wdata, wdata_i[63:0]} : wdata_i;
      full_be    = relay_i[i] ? {be_i[15:8] | be_lo_swapped, be_i[7:0] & be_i[15:8]} : be_i;
    end

    bp_sram_256x128 mem (
      .clk_i   ( clk_i           ),
      .rst_ni  ( rst_ni          ),
      .req_i   ( req_i[i]        ),
      .we_i    ( we_i[i]         ),
      .addr_i  ( addr_i          ),
      .wdata_i ( full_wdata      ),
      .be_i    ( full_be         ),
      .rdata_o ( cluster_dout[i] )
    );
  end

  assign rdata_o = (cluster_dout[0] ^ cluster_dout[1]) ^ (cluster_dout[2] ^ cluster_dout[3]);
endmodule
