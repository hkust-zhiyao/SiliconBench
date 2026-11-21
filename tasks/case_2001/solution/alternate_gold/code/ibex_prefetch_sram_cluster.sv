// Alternate reference
// Constructed four-cluster instruction-memory integration around Ibex prefetch buffer,
// fetch FIFO, and four Cheshire-IHP 256x128 tc_sram wrappers (8x RM_IHPSG13_1P_256x64_c2_bm_bist).
module ibex_prefetch_sram_cluster (
  input  logic         clk_i,
  input  logic         rst_ni,

  // Instruction fetch interface
  input  logic         req_i,
  input  logic         branch_i,
  input  logic [31:0]  addr_i,
  input  logic         ready_i,
  input  logic         cheriot_force_uc_i,
  output logic         valid_o,
  output logic [31:0]  rdata_o,
  output logic [31:0]  addr_o,
  output logic         err_o,
  output logic         err_plus2_o,
  output logic         busy_o,

  // Four-cluster host SRAM maintenance & mirror-relay interface
  input  logic [3:0]   host_req_i,
  input  logic [3:0]   host_we_i,
  input  logic [3:0]   host_mirror_i,
  input  logic [7:0]   host_addr_i,
  input  logic [127:0] host_wdata_i,
  input  logic [15:0]  host_be_i,
  input  logic         host_fault_i,
  output logic [127:0] cluster_xor_rdata_o
);

  logic        instr_req, instr_gnt;
  logic [31:0] instr_addr, instr_rdata;
  logic        instr_rvalid, instr_err;
  logic [1:0]  bank_q, lane_q;
  wire [127:0] bank_rdata [4];

  wire [1:0] fetch_bank = instr_addr[13:12];
  assign instr_gnt = instr_req & ~host_req_i[fetch_bank];

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      instr_rvalid <= 1'b0;
      instr_err    <= 1'b0;
      bank_q       <= 2'b00;
      lane_q       <= 2'b00;
    end else begin
      instr_rvalid <= instr_gnt;
      instr_err    <= instr_gnt & (host_fault_i | (|instr_addr[31:14]));
      if (instr_gnt) begin
        bank_q <= fetch_bank;
        lane_q <= instr_addr[3:2];
      end
    end
  end

  wire [127:0] sel_bank_rdata = bank_rdata[bank_q];
  assign instr_rdata = sel_bank_rdata[32*lane_q +: 32];

  ibex_prefetch_buffer #(
    .NUM_REQS ( 2    ),
    .ResetAll ( 1'b1 )
  ) u_prefetch (
    .clk_i              ( clk_i              ),
    .rst_ni             ( rst_ni             ),
    .req_i              ( req_i              ),
    .branch_i           ( branch_i           ),
    .addr_i             ( addr_i             ),
    .ready_i            ( ready_i            ),
    .valid_o            ( valid_o            ),
    .rdata_o            ( rdata_o            ),
    .addr_o             ( addr_o             ),
    .err_o              ( err_o              ),
    .err_plus2_o        ( err_plus2_o        ),
    .cheriot_force_uc_i ( cheriot_force_uc_i ),
    .instr_req_o        ( instr_req          ),
    .instr_gnt_i        ( instr_gnt          ),
    .instr_addr_o       ( instr_addr         ),
    .instr_rdata_i      ( instr_rdata        ),
    .instr_err_i        ( instr_err          ),
    .instr_rvalid_i     ( instr_rvalid       ),
    .busy_o             ( busy_o             )
  );

  for (genvar i = 0; i < 4; i = i + 1) begin : cluster
    wire is_fetch_bank   = instr_req & ~host_req_i[i] & (fetch_bank == i[1:0]);
    wire sram_req        = host_req_i[i] | is_fetch_bank;
    wire sram_we         = host_req_i[i] & host_we_i[i];
    wire [7:0]   sram_addr = host_req_i[i] ? host_addr_i : instr_addr[11:4];
    wire [127:0] wd      = host_mirror_i[i] ? {bank_rdata[i][63:0], host_wdata_i[63:0]} : host_wdata_i;
    wire [15:0]  be      = host_mirror_i[i] ? {host_be_i[15:8] | host_be_i[7:0], host_be_i[7:0] & host_be_i[15:8]} : host_be_i;

    tc_sram #(
      .NumWords  ( 256 ),
      .DataWidth ( 128 ),
      .NumPorts  ( 1   ),
      .Latency   ( 1   )
    ) mem (
      .clk_i   ( clk_i         ),
      .rst_ni  ( rst_ni        ),
      .req_i   ( sram_req      ),
      .we_i    ( sram_we       ),
      .addr_i  ( sram_addr     ),
      .wdata_i ( wd            ),
      .be_i    ( be            ),
      .rdata_o ( bank_rdata[i] )
    );
  end

  assign cluster_xor_rdata_o = bank_rdata[0] ^ bank_rdata[1] ^ bank_rdata[2] ^ bank_rdata[3];
endmodule
