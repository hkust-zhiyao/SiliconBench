// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps

`include "caliptra_macros.svh"
`include "kv_macros.svh"

module tb;
  import kv_defines_pkg::*;
  import hmac_param_pkg::*;

  localparam int AHB_ADDR_W = 32;
  localparam int AHB_DATA_W = 64;

  // Register offsets
  localparam logic [31:0] REG_NAME0              = 32'h000;
  localparam logic [31:0] REG_CTRL               = 32'h010;
  localparam logic [31:0] REG_STATUS             = 32'h018;
  localparam logic [31:0] REG_KEY_BASE           = 32'h040;
  localparam logic [31:0] REG_BLOCK_BASE         = 32'h080;
  localparam logic [31:0] REG_TAG_BASE           = 32'h100;
  localparam logic [31:0] REG_LFSR_SEED_BASE     = 32'h140;
  localparam logic [31:0] REG_KV_RD_KEY_CTRL     = 32'h600;
  localparam logic [31:0] REG_KV_RD_KEY_STATUS   = 32'h604;
  localparam logic [31:0] REG_KV_RD_BLOCK_CTRL   = 32'h608;
  localparam logic [31:0] REG_KV_RD_BLOCK_STATUS = 32'h60C;
  localparam logic [31:0] REG_KV_WR_CTRL         = 32'h610;
  localparam logic [31:0] REG_KV_WR_STATUS       = 32'h614;
  localparam logic [31:0] REG_GLOBAL_INTR_EN     = 32'h800;
  localparam logic [31:0] REG_ERROR_INTR_EN      = 32'h804;
  localparam logic [31:0] REG_ERROR_INTR_STS     = 32'h814;

  // DRBG KAT constants (NIST SP 800-90A / Caliptra P-384)
  localparam logic [383:0] P384_ORDER =
    384'hFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFC7634D81F4372DDF581A0DB248B0A77AECEC196ACCC52973;

  localparam logic [383:0] DRBG_C0_EXP0 =
    384'hFEEEF5544A76564990128AD189E873F21F0DFD5AD7E2FA861127EE6E394CA784871C1AEC032C7A8B10B93E0EAB8946D6;
  localparam logic [383:0] DRBG_C0_EXP1 =
    384'hd7f1b8ee5fc4eca7b022ccbdc2b03bee146c8985ea52ae400b9e23ce3cb3a95849ef93140c8a519ed8f817e66e6f0de4;

  localparam logic [383:0] DRBG_C2_ENT =
    384'hF71EE80F1D123DC3F70EAA1FB3272714858EA555BC496BF39ADB107B192BF0BCBA9BB5B5799CFF8E12A1154F37CA7BBD;
  localparam logic [383:0] DRBG_C2_NONCE =
    384'hDE2B2A66EE13797C69438A9BF6F8514C0A8ABEFD3E5533E1119AE88E8D641771E9BCE4CBE44430A0ADAAAB4103095FC4;
  localparam logic [383:0] DRBG_C2_EXP0 =
    384'h316f0937ff54b3d16398d5d07799ab59d0e1f3962831101f1eca892f0f1567df2f964c19b8690761d188d2100403eea6;
  localparam logic [383:0] DRBG_C2_EXP1 =
    384'h9a42b5046712b4e32c1f9db62a7900d2e0d4e051580b5dc2cbc8498a04df6676ff80b4e6e2b34b29152bd96e5b4eefed;
  localparam logic [383:0] DRBG_C2_EXP2 =
    384'h28ff268d4fea88d4bc28a712feb777bb72dace10e9886eefd226615f5f9d508aa8f59d4b087b65d54223a2186f53031b;

  localparam logic [383:0] CHAIN_PRIME =
    384'h300000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000;

  // HMAC-384/512 KAT constants
  localparam logic [1023:0] MSG_B1 =
    1024'h43616c697074726120526f5420484d41432d353132204b4154800000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000004c8;
  localparam logic [511:0] TAG512_SINGLE =
    512'hb2daebb2233edb176d25f49881cb7088dd55777d67fba5704128b0fcfc0dfca84ea4f0aa8596856e5aecb63eb0240afc8ba021bf2ab6db35eb63f471229d6f8c;
  localparam logic [383:0] TAG384_SINGLE =
    384'h378d1ecbf8507c8813335c7982fd38ace98c5ab21af34b2c9deb4536ec372070e68d19fb01723fb0aea8e98302a74603;

  localparam logic [1023:0] MSG_M2_BLK0 =
    1024'ha5a4a7a6a1a0a3a2adacafaea9a8abaab5b4b7b6b1b0b3b2bdbcbfbeb9b8bbba85848786818083828d8c8f8e89888b8a95949796919093929d9c9f9e99989b9ae5e4e7e6e1e0e3e2edecefeee9e8ebeaf5f4f7f6f1f0f3f2fdfcfffef9f8fbfac5c4c7c6c1c0c3c2cdcccfcec9c8cbcad5d4d7d6d1d0d3d2dddcdfded9d8dbda;
  localparam logic [1023:0] MSG_M2_BLK1 =
    1024'h5365636f6e6420426c6f636b205461696c800000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000888;
  localparam logic [511:0] TAG512_MULTI =
    512'h319bd6d62a999bca26d68ef57a82f76b55a2a3e32accbca8be7d13c77815f63b78e95b85e930284aa336572ca1bfe7c0a7bbbc01ba2915f7ce39a00e47365356;

  localparam logic [511:0] TAG512_CSR =
    512'h6c9c82ded30eff5bfa07c8ecedb808fda7ecde1d6c5c2d4a0fa9d2fa3fec2da8e99f0fdfbee82231725bfa37754be1c1bf6d18b4f0615a276bd57d3f1cb95698;
  localparam logic [383:0] TAG384_KV_KEY_SW_MSG =
    384'h92483132592cef9b2e7c10d9b0013d8848bac4d49d523950e9e7bb006accfc27376f3393919175873c493dae333adc37;
  localparam logic [383:0] TAG384_KV_KEY_KV_MSG =
    384'hdd571e5d0be1cc87c4b21cb03cb54b7433ac60aaf10aaaffde24cb276fd71e27e4825cf4772f6ff66de85d6c399690c8;
  localparam logic [511:0] TAG512_KV_DEST =
    512'h71bcf8920ce6623a5a23f40494d40a7cde0ebbd7403320f7c2306a8a977fcd80e9a8fd6f2a2fbab91f32d7d6b48a480ffb7f4b76e08010ef5594f6a4b924513f;

  logic clk = 1'b0;
  always #5 clk = ~clk;

  int fail_cnt = 0;
  int pass_cnt = 0;

  task automatic check_cond(input bit cond, input string msg);
    if (!cond) begin
      $display("[FAIL] %s (t=%0t)", msg, $time);
      fail_cnt++;
    end else begin
      pass_cnt++;
    end
  endtask

  // =========================================================================
  // 1. HMAC_DRBG Instances (Standard P-384, Prime==T0, Prime==T0+1, Chain)
  // =========================================================================
  logic         drbg_rst_n;
  logic         drbg_zeroize;
  logic [3:0]   drbg_init, drbg_next;
  wire  [3:0]   drbg_ready, drbg_valid;
  logic [191:0] drbg_seed;
  logic [383:0] drbg_entropy, drbg_nonce;
  wire  [383:0] drbg_out [4];

  hmac_drbg #(
    .REG_SIZE(384), .LFSR_LENGTH(192), .HMAC_DRBG_PRIME(P384_ORDER)
  ) u_drbg_std (
    .clk(clk), .reset_n(drbg_rst_n), .zeroize(drbg_zeroize),
    .init_cmd(drbg_init[0]), .next_cmd(drbg_next[0]),
    .ready(drbg_ready[0]), .valid(drbg_valid[0]),
    .lfsr_seed(drbg_seed), .entropy(drbg_entropy), .nonce(drbg_nonce),
    .drbg(drbg_out[0])
  );

  hmac_drbg #(
    .REG_SIZE(384), .LFSR_LENGTH(192), .HMAC_DRBG_PRIME(DRBG_C0_EXP0)
  ) u_drbg_eq (
    .clk(clk), .reset_n(drbg_rst_n), .zeroize(drbg_zeroize),
    .init_cmd(drbg_init[1]), .next_cmd(drbg_next[1]),
    .ready(drbg_ready[1]), .valid(drbg_valid[1]),
    .lfsr_seed(drbg_seed), .entropy(drbg_entropy), .nonce(drbg_nonce),
    .drbg(drbg_out[1])
  );

  hmac_drbg #(
    .REG_SIZE(384), .LFSR_LENGTH(192), .HMAC_DRBG_PRIME(DRBG_C0_EXP0 + 384'd1)
  ) u_drbg_plus1 (
    .clk(clk), .reset_n(drbg_rst_n), .zeroize(drbg_zeroize),
    .init_cmd(drbg_init[2]), .next_cmd(drbg_next[2]),
    .ready(drbg_ready[2]), .valid(drbg_valid[2]),
    .lfsr_seed(drbg_seed), .entropy(drbg_entropy), .nonce(drbg_nonce),
    .drbg(drbg_out[2])
  );

  hmac_drbg #(
    .REG_SIZE(384), .LFSR_LENGTH(192), .HMAC_DRBG_PRIME(CHAIN_PRIME)
  ) u_drbg_chain (
    .clk(clk), .reset_n(drbg_rst_n), .zeroize(drbg_zeroize),
    .init_cmd(drbg_init[3]), .next_cmd(drbg_next[3]),
    .ready(drbg_ready[3]), .valid(drbg_valid[3]),
    .lfsr_seed(drbg_seed), .entropy(drbg_entropy), .nonce(drbg_nonce),
    .drbg(drbg_out[3])
  );

  // =========================================================================
  // 2. HMAC_CTRL + HMAC Full Hierarchy Instance (64-bit AHB + KV BFM)
  // =========================================================================
  logic                       ctrl_rst_n;
  logic                       cptra_pwrgood;
  logic [15:0][31:0]          cptra_csr_hmac_key;
  logic [AHB_ADDR_W-1:0]      haddr_i;
  logic [AHB_DATA_W-1:0]      hwdata_i;
  logic                       hsel_i;
  logic                       hwrite_i;
  wire                        hready_i;
  logic [1:0]                 htrans_i;
  logic [2:0]                 hsize_i;
  wire                        hresp_o;
  wire                        hreadyout_o;
  wire  [AHB_DATA_W-1:0]      hrdata_o;
  wire  kv_read_t  [1:0]      kv_read;
  wire  kv_write_t            kv_write;
  kv_rd_resp_t     [1:0]      kv_rd_resp;
  kv_wr_resp_t                kv_wr_resp;
  wire                        busy_o;
  wire                        error_intr;
  wire                        notif_intr;
  logic                       ocp_lock_in_progress;
  logic                       debugUnlock_or_scan_mode_switch;

  assign hready_i = hreadyout_o;

  hmac_ctrl #(
    .AHB_DATA_WIDTH(AHB_DATA_W),
    .AHB_ADDR_WIDTH(AHB_ADDR_W)
  ) u_hmac_ctrl (
    .clk(clk),
    .reset_n(ctrl_rst_n),
    .cptra_pwrgood(cptra_pwrgood),
    .cptra_csr_hmac_key(cptra_csr_hmac_key),
    .haddr_i(haddr_i),
    .hwdata_i(hwdata_i),
    .hsel_i(hsel_i),
    .hwrite_i(hwrite_i),
    .hready_i(hready_i),
    .htrans_i(htrans_i),
    .hsize_i(hsize_i),
    .hresp_o(hresp_o),
    .hreadyout_o(hreadyout_o),
    .hrdata_o(hrdata_o),
    .kv_read(kv_read),
    .kv_write(kv_write),
    .kv_rd_resp(kv_rd_resp),
    .kv_wr_resp(kv_wr_resp),
    .busy_o(busy_o),
    .error_intr(error_intr),
    .notif_intr(notif_intr),
    .ocp_lock_in_progress(ocp_lock_in_progress),
    .debugUnlock_or_scan_mode_switch(debugUnlock_or_scan_mode_switch)
  );

  // KeyVault BFM storage: 24 slots, up to 16 dwords per slot + configurable last_dword
  logic [23:0][15:0][31:0] kv_mem;
  logic [23:0][3:0]        kv_last_dw;
  logic [23:0][15:0][31:0] kv_wr_captured;
  int                      kv_wr_beat_cnt;
  logic [8:0]              kv_wr_last_dest_valid;

  always_comb begin
    for (int c = 0; c < 2; c++) begin
      automatic logic [4:0] slot = kv_read[c].read_entry;
      automatic logic [3:0] off  = kv_read[c].read_offset;
      kv_rd_resp[c].error            = 1'b0;
      kv_rd_resp[c].entry_last_dword = (slot < 5'd24) ? kv_last_dw[slot] : 4'd15;
      kv_rd_resp[c].last             = (slot < 5'd24) ? (off == kv_last_dw[slot]) : (off == 4'd15);
      kv_rd_resp[c].read_data        = (slot < 5'd24) ? kv_mem[slot][off] : 32'h0;
    end
    kv_wr_resp.error = 1'b0;
  end

  always_ff @(posedge clk or negedge ctrl_rst_n) begin
    if (!ctrl_rst_n) begin
      kv_wr_captured        <= '0;
      kv_wr_beat_cnt        <= 0;
      kv_wr_last_dest_valid <= '0;
    end else if (kv_write.write_en) begin
      if (kv_write.write_entry < 5'd24) begin
        kv_wr_captured[kv_write.write_entry][kv_write.write_offset] <= kv_write.write_data;
      end
      kv_wr_beat_cnt <= kv_wr_beat_cnt + 1;
      if (|kv_write.write_dest_valid)
        kv_wr_last_dest_valid <= kv_write.write_dest_valid;
    end
  end

  // =========================================================================
  // AHB-Lite Master Helper Tasks
  // =========================================================================
  task automatic ahb_idle();
    hsel_i   = 1'b0;
    hwrite_i = 1'b0;
    htrans_i = 2'b00;
    hsize_i  = 3'b010;
    haddr_i  = '0;
    hwdata_i = '0;
  endtask

  task automatic ahb_write32(input logic [31:0] addr, input logic [31:0] data, output bit saw_err);
    int guard;
    bit rdy_done;
    saw_err = 1'b0;
    @(posedge clk);
    #1;
    while (!hreadyout_o) begin
      @(posedge clk);
      #1;
    end
    // Address phase (setup 9ns before posedge clk, hold 1ns after)
    hsel_i   = 1'b1;
    hwrite_i = 1'b1;
    htrans_i = 2'b10;
    hsize_i  = 3'b010;
    haddr_i  = addr;
    @(posedge clk);
    #1;
    // Data phase
    hsel_i   = 1'b0;
    hwrite_i = 1'b0;
    htrans_i = 2'b00;
    hwdata_i = addr[2] ? {data, 32'h0} : {32'h0, data};
    guard = 0;
    do begin
      #1;
      if (hresp_o) saw_err = 1'b1;
      rdy_done = hreadyout_o;
      @(posedge clk);
      #1;
      guard++;
    end while (!rdy_done && guard < 20);
    hwdata_i = '0;
  endtask

  task automatic ahb_read32(input logic [31:0] addr, output logic [31:0] data, output bit saw_err);
    int guard;
    bit rdy_done;
    saw_err = 1'b0;
    @(posedge clk);
    #1;
    while (!hreadyout_o) begin
      @(posedge clk);
      #1;
    end
    // Address phase (setup 9ns before posedge clk, hold 1ns after)
    hsel_i   = 1'b1;
    hwrite_i = 1'b0;
    htrans_i = 2'b10;
    hsize_i  = 3'b010;
    haddr_i  = addr;
    @(posedge clk);
    #1;
    // Data phase
    hsel_i   = 1'b0;
    htrans_i = 2'b00;
    guard = 0;
    do begin
      #1;
      if (hresp_o) saw_err = 1'b1;
      data     = addr[2] ? hrdata_o[63:32] : hrdata_o[31:0];
      rdy_done = hreadyout_o;
      @(posedge clk);
      #1;
      guard++;
    end while (!rdy_done && guard < 20);
  endtask

  task automatic ahb_raw_xfer(
    input  logic [31:0] addr,
    input  logic [2:0]  sz,
    input  logic        wr,
    input  logic [63:0] wdata,
    output bit          err_two_cycle_ok,
    output logic [63:0] rdata_sample
  );
    bit cyc1_err_low_rdy;
    bit cyc2_err_hi_rdy;
    @(posedge clk);
    #1;
    while (!hreadyout_o) begin
      @(posedge clk);
      #1;
    end
    hsel_i   = 1'b1;
    hwrite_i = wr;
    htrans_i = 2'b10;
    hsize_i  = sz;
    haddr_i  = addr;
    @(posedge clk);
    #1;
    // Data phase cycle 1
    hsel_i   = 1'b0;
    hwrite_i = 1'b0;
    htrans_i = 2'b00;
    hsize_i  = 3'b010;
    hwdata_i = wdata;
    #1;
    cyc1_err_low_rdy = (hreadyout_o == 1'b0) && (hresp_o == 1'b1);
    rdata_sample     = hrdata_o;
    @(posedge clk);
    #1;
    // Data phase cycle 2
    #1;
    cyc2_err_hi_rdy = (hreadyout_o == 1'b1) && (hresp_o == 1'b1);
    if (hrdata_o != 64'h0) rdata_sample = hrdata_o;
    err_two_cycle_ok = cyc1_err_low_rdy && cyc2_err_hi_rdy;
    @(posedge clk);
    #1;
    hwdata_i = '0;
  endtask

  task automatic wait_hmac_ready(output bit ok);
    logic [31:0] st;
    bit err;
    int polls;
    ok = 1'b0;
    for (polls = 0; polls < 600; polls++) begin
      ahb_read32(REG_STATUS, st, err);
      if (!err && st[0] && !busy_o) begin
        ok = 1'b1;
        return;
      end
    end
  endtask

  task automatic read_csr_tag512(output logic [511:0] tag_out);
    logic [31:0] dw;
    bit err;
    for (int i = 0; i < 16; i++) begin
      ahb_read32(REG_TAG_BASE + i*4, dw, err);
      tag_out[(15 - i)*32 +: 32] = dw;
    end
  endtask

  task automatic write_csr_block1024(input logic [1023:0] blk);
    bit err;
    for (int i = 0; i < 32; i++) begin
      ahb_write32(REG_BLOCK_BASE + i*4, blk[(31 - i)*32 +: 32], err);
    end
  endtask

  // =========================================================================
  // DRBG Test Suite
  // =========================================================================
  task automatic run_drbg_tests(input int unsigned seed_val);
    int cyc;
    bit premature_valid;
    $display("[INFO] Starting HMAC_DRBG tests (seed=%0d)...", seed_val);

    drbg_rst_n   = 1'b0;
    drbg_zeroize = 1'b0;
    drbg_init    = 4'b0000;
    drbg_next    = 4'b0000;
    drbg_seed    = {6{seed_val ^ 32'h5A5A_F0F0}};
    drbg_entropy = '0;
    drbg_nonce   = '0;
    repeat (4) @(posedge clk);
    drbg_rst_n = 1'b1;
    repeat (4) @(posedge clk);

    check_cond(drbg_ready == 4'b1111, "DRBG: all instances ready after reset");
    check_cond(drbg_valid == 4'b0000, "DRBG: valid low after reset");

    // D1: Uninstantiated next_cmd must be ignored!
    drbg_next[0] = 1'b1;
    @(posedge clk);
    drbg_next[0] = 1'b0;
    repeat (5) begin
      @(posedge clk);
      check_cond(drbg_ready[0] == 1'b1 && drbg_valid[0] == 1'b0 && drbg_out[0] == '0,
                 "DRBG D1: uninstantiated next_cmd ignored");
    end

    // D2: Simultaneous {init_cmd, next_cmd} == 2'b11 ignored while uninstantiated
    drbg_init[0] = 1'b1;
    drbg_next[0] = 1'b1;
    @(posedge clk);
    drbg_init[0] = 1'b0;
    drbg_next[0] = 1'b0;
    repeat (4) begin
      @(posedge clk);
      check_cond(drbg_ready[0] == 1'b1 && drbg_valid[0] == 1'b0,
                 "DRBG D2: invalid simultaneous init+next ignored");
    end

    // D3: Boundary Prime Check on u_drbg_std, u_drbg_eq (PRIME == T0), u_drbg_plus1 (PRIME == T0+1)
    drbg_entropy = 384'h0;
    drbg_nonce   = 384'h0;
    @(posedge clk);
    drbg_init[2:0] = 3'b111;
    @(posedge clk);
    drbg_init[2:0] = 3'b000;
    // Mutate entropy/nonce and glitch next_cmd while busy!
    repeat (3) @(posedge clk);
    drbg_entropy = ~384'h0;
    drbg_nonce   = 384'hDEAD_BEEF_CAFE_BABE;
    drbg_next[2:0] = 3'b111;
    @(posedge clk);
    drbg_next[2:0] = 3'b000;

    // Wait for u_drbg_std and u_drbg_plus1 to finish first candidate; u_drbg_eq MUST still be busy rejecting T0 == PRIME!
    cyc = 0;
    while (!drbg_valid[0] && cyc < 5000) begin
      if (drbg_valid[1]) premature_valid = 1'b1;
      @(posedge clk);
      cyc++;
    end
    check_cond(drbg_valid[0] && drbg_out[0] == DRBG_C0_EXP0,
               "DRBG D3a: standard P-384 KAT init output matches despite input mutation while busy");
    check_cond(drbg_valid[2] && drbg_out[2] == DRBG_C0_EXP0,
               "DRBG D3b: PRIME == T0 + 1 accepts candidate T0");
    check_cond(!premature_valid && !drbg_valid[1] && !drbg_ready[1] && drbg_out[1] == '0,
               "DRBG D3c: PRIME == T0 strictly rejects candidate T0 without premature valid/drbg leak");

    // Wait for u_drbg_eq to complete SP 800-90A rejection update (K3->V3->T) and output DRBG_C0_EXP1!
    while (!drbg_valid[1] && cyc < 9000) begin
      @(posedge clk);
      cyc++;
    end
    check_cond(drbg_valid[1] && drbg_out[1] == DRBG_C0_EXP1,
               "DRBG D3d: PRIME == T0 rejection update hashes rejected T0 and produces exact EXP1");

    // D4: Verify 2'b11 glitch in IDLE preserves valid & drbg output, then run next_cmd on u_drbg_std
    repeat (2) @(posedge clk);
    drbg_init[0] = 1'b1;
    drbg_next[0] = 1'b1;
    @(posedge clk);
    drbg_init[0] = 1'b0;
    drbg_next[0] = 1'b0;
    @(posedge clk);
    check_cond(drbg_ready[0] && drbg_valid[0] && drbg_out[0] == DRBG_C0_EXP0,
               "DRBG D4a: 2'b11 glitch in IDLE preserves valid output and ready");

    drbg_next[0] = 1'b1;
    @(posedge clk);
    drbg_next[0] = 1'b0;
    cyc = 0;
    while (!drbg_valid[0] && cyc < 5000) begin
      @(posedge clk);
      cyc++;
    end
    check_cond(drbg_valid[0] && drbg_out[0] == DRBG_C0_EXP1,
               "DRBG D4b: standard P-384 next_cmd matches EXP1");

    // D5: Multi-rejection chain (2 consecutive rejections: 0x316f >= 0x3000 -> 0x9a42 >= 0x3000 -> 0x28ff < 0x3000)
    drbg_entropy = DRBG_C2_ENT;
    drbg_nonce   = DRBG_C2_NONCE;
    @(posedge clk);
    drbg_init[3] = 1'b1;
    @(posedge clk);
    drbg_init[3] = 1'b0;
    cyc = 0;
    while (!drbg_valid[3] && cyc < 15000) begin
      check_cond(drbg_out[3] == '0, "DRBG D5a: drbg output remains zero throughout multi-rejection loop");
      @(posedge clk);
      cyc++;
    end
    check_cond(drbg_valid[3] && drbg_out[3] == DRBG_C2_EXP2,
               "DRBG D5b: 2-step rejection chain outputs exact 3rd candidate DRBG_C2_EXP2");
    check_cond(cyc > 4000, "DRBG D5c: multi-rejection loop executed full HMAC rejection rounds");

    // D6: Mid-rejection-loop zeroize sanitization & uninstantiated state enforcement
    @(posedge clk);
    drbg_init[3] = 1'b1;
    @(posedge clk);
    drbg_init[3] = 1'b0;
    // Advance ~4200 cycles into the first rejection loop (K3_ST / V3_ST)
    repeat (4200) @(posedge clk);
    check_cond(!drbg_ready[3] && !drbg_valid[3], "DRBG D6a: busy inside rejection loop before zeroize");
    drbg_zeroize = 1'b1;
    @(posedge clk);
    #1;
    check_cond(!drbg_valid[3] && drbg_out[3] == '0, "DRBG D6b: valid & drbg immediately cleared on zeroize");
    @(posedge clk);
    drbg_zeroize = 1'b0;
    repeat (3) @(posedge clk);
    check_cond(drbg_ready[3] && !drbg_valid[3] && drbg_out[3] == '0,
               "DRBG D6c: ready recovers cleanly to 1 after mid-rejection zeroize");

    // Post-zeroize next_cmd MUST be rejected because zeroize uninstantiated the DRBG!
    drbg_next[3] = 1'b1;
    @(posedge clk);
    drbg_next[3] = 1'b0;
    repeat (5) begin
      @(posedge clk);
      check_cond(drbg_ready[3] && !drbg_valid[3] && drbg_out[3] == '0,
                 "DRBG D6d: post-zeroize next_cmd blocked until fresh init_cmd");
    end

    // Fresh init_cmd on u_drbg_std after zeroize produces clean KAT
    drbg_entropy = DRBG_C2_ENT;
    drbg_nonce   = DRBG_C2_NONCE;
    @(posedge clk);
    drbg_init[0] = 1'b1;
    @(posedge clk);
    drbg_init[0] = 1'b0;
    cyc = 0;
    while (!drbg_valid[0] && cyc < 5000) begin
      @(posedge clk);
      cyc++;
    end
    check_cond(drbg_valid[0] && drbg_out[0] == DRBG_C2_EXP0,
               "DRBG D6e: post-zeroize fresh init_cmd produces clean KAT");
  endtask

  // =========================================================================
  // HMAC_CTRL + HMAC Full Subsystem Security & Isolation Suite
  // =========================================================================
  task automatic run_hmac_subsystem_tests(input int unsigned seed_val);
    logic [511:0] got_tag;
    logic [31:0]  rd_val;
    logic [63:0]  raw_rdata;
    bit           err, rdy_ok, err_2cyc_ok;
    int           wait_cyc;

    $display("[INFO] Starting HMAC_CTRL + HMAC security tests (seed=%0d)...", seed_val);

    // Initialize signals and KV slots
    ctrl_rst_n                      = 1'b0;
    cptra_pwrgood                   = 1'b0;
    ocp_lock_in_progress            = 1'b0;
    debugUnlock_or_scan_mode_switch = 1'b0;
    ahb_idle();

    for (int i = 0; i < 16; i++)
      cptra_csr_hmac_key[i] = 32'hC5A0_0000 + i;

    kv_mem     = '0;
    kv_last_dw = '0;
    // Slot 2: 384-bit key (12 dwords, last_dword = 11)
    kv_last_dw[2] = 4'd11;
    for (int i = 0; i < 12; i++)
      kv_mem[2][i] = 32'h3840_1000 + i;
    // Slot 3: 512-bit key (16 dwords, last_dword = 15)
    kv_last_dw[3] = 4'd15;
    for (int i = 0; i < 16; i++)
      kv_mem[3][i] = 32'h5120_3000 + i;
    // Slot 4: 256-bit secret block (8 dwords, last_dword = 7)
    kv_last_dw[4] = 4'd7;
    for (int i = 0; i < 8; i++)
      kv_mem[4][i] = 32'hB10C_2000 + i;

    repeat (5) @(posedge clk);
    cptra_pwrgood = 1'b1;
    ctrl_rst_n    = 1'b1;
    repeat (5) @(posedge clk);

    wait_hmac_ready(rdy_ok);
    check_cond(rdy_ok, "HMAC T0: ready after reset");

    // Enable error interrupts
    ahb_write32(REG_GLOBAL_INTR_EN, 32'h0000_0003, err);
    ahb_write32(REG_ERROR_INTR_EN,  32'h0000_000F, err);

    // -----------------------------------------------------------------------
    // T1: Software HMAC-512 (single & multi-block) and HMAC-384 truncation
    // -----------------------------------------------------------------------
    for (int i = 0; i < 16; i++) begin
      logic [31:0] kw;
      kw = {8'(4*i), 8'(4*i+1), 8'(4*i+2), 8'(4*i+3)};
      ahb_write32(REG_KEY_BASE + i*4, kw, err);
    end
    for (int i = 0; i < 6; i++)
      ahb_write32(REG_LFSR_SEED_BASE + i*4, (seed_val ^ (32'h1357_2468 + i)), err);
    write_csr_block1024(MSG_B1);

    // HMAC-512 single-block: INIT(0)=1, MODE(3)=1, LAST(5)=1 => 0x29
    ahb_write32(REG_CTRL, 32'h0000_0029, err);
    wait_hmac_ready(rdy_ok);
    check_cond(rdy_ok, "HMAC T1a: HMAC-512 single-block completed");
    read_csr_tag512(got_tag);
    check_cond(got_tag == TAG512_SINGLE, "HMAC T1a: HMAC-512 single-block KAT exact match");

    // HMAC-384 single-block: INIT(0)=1, MODE(3)=0, LAST(5)=1 => 0x21
    ahb_write32(REG_CTRL, 32'h0000_0021, err);
    wait_hmac_ready(rdy_ok);
    read_csr_tag512(got_tag);
    check_cond(got_tag[511:128] == TAG384_SINGLE && got_tag[127:0] == 128'h0,
               "HMAC T1b: HMAC-384 KAT matches and lower 128 tag bits masked to zero");

    // HMAC-512 two-block: block 0 with INIT(0)=1, MODE(3)=1 => 0x09; block 1 with NEXT(1)=1, MODE(3)=1, LAST(5)=1 => 0x2A
    write_csr_block1024(MSG_M2_BLK0);
    ahb_write32(REG_CTRL, 32'h0000_0009, err);
    wait_hmac_ready(rdy_ok);
    write_csr_block1024(MSG_M2_BLK1);
    ahb_write32(REG_CTRL, 32'h0000_002A, err);
    wait_hmac_ready(rdy_ok);
    read_csr_tag512(got_tag);
    check_cond(got_tag == TAG512_MULTI, "HMAC T1c: HMAC-512 multi-block KAT exact match");

    // -----------------------------------------------------------------------
    // T2: CSR_MODE key operation & mid-run ZEROIZE clearing CSR_MODE + LFSR_SEED
    // -----------------------------------------------------------------------
    write_csr_block1024(MSG_B1);
    // INIT(0)=1, MODE(3)=1, CSR_MODE(4)=1, LAST(5)=1 => 0x39
    ahb_write32(REG_CTRL, 32'h0000_0039, err);
    wait_hmac_ready(rdy_ok);
    read_csr_tag512(got_tag);
    check_cond(got_tag == TAG512_CSR, "HMAC T2a: CSR_MODE HMAC-512 KAT exact match");

    // Start another CSR_MODE op, then issue mid-run ZEROIZE while busy (ready_reg == 0)!
    ahb_write32(REG_CTRL, 32'h0000_0039, err);
    repeat (25) @(posedge clk);
    check_cond(busy_o == 1'b1, "HMAC T2b: engine busy before mid-run ZEROIZE");
    // Write ZEROIZE (bit 2 = 0x04) while busy; note CSR_MODE.swwe is 0 in hmac_reg while busy!
    ahb_write32(REG_CTRL, 32'h0000_0004, err);
    wait_hmac_ready(rdy_ok);
    check_cond(rdy_ok, "HMAC T2c: engine recovers ready after mid-run ZEROIZE");
    read_csr_tag512(got_tag);
    check_cond(got_tag == 512'h0, "HMAC T2d: HMAC512_TAG zeroed by mid-run ZEROIZE");

    // Verify CSR_MODE did NOT stay stuck high: write SW key + block and launch with CSR_MODE=0 (0x29)
    // Even more subtly: check that before writing REG_CTRL, KV/SW state is clean
    for (int i = 0; i < 16; i++) begin
      logic [31:0] kw;
      kw = {8'(4*i), 8'(4*i+1), 8'(4*i+2), 8'(4*i+3)};
      ahb_write32(REG_KEY_BASE + i*4, kw, err);
    end
    write_csr_block1024(MSG_B1);
    ahb_write32(REG_CTRL, 32'h0000_0029, err);
    wait_hmac_ready(rdy_ok);
    read_csr_tag512(got_tag);
    check_cond(got_tag == TAG512_SINGLE, "HMAC T2e: post-ZEROIZE SW key operation clean");

    // -----------------------------------------------------------------------
    // T3: KeyVault 384-bit Key Pre-Clear, CSR_MODE Isolation, & key_mode_error
    // -----------------------------------------------------------------------
    // Poison all 16 SW key dwords (especially [12..15]!) and enable CSR_MODE=1 while idle
    for (int i = 0; i < 16; i++)
      ahb_write32(REG_KEY_BASE + i*4, 32'hDEAD_BEEF, err);
    ahb_write32(REG_CTRL, 32'h0000_0018, err); // MODE=1, CSR_MODE=1 (no INIT)

    // Trigger KV read of 384-bit key from slot 2 (read_entry=2, read_en=1 => (2<<1)|1 = 0x05)
    ahb_write32(REG_KV_RD_KEY_CTRL, 32'h0000_0005, err);
    // Immediately check on very next AHB read that engine/KV key status reflects busy or completed cleanly
    wait_hmac_ready(rdy_ok);
    check_cond(rdy_ok, "HMAC T3a: KV 384-bit key read completed");

    // Attempt HMAC-512 (MODE=1, INIT=1, LAST=1 => 0x29) with 384-bit KV key!
    // Because dwords [12..15] MUST have been pre-cleared (wiping 0xDEAD_BEEF) and CSR_MODE MUST be overridden,
    // key_mode_error MUST fire and core execution MUST be blocked!
    write_csr_block1024(MSG_B1);
    ahb_write32(REG_CTRL, 32'h0000_0029, err);
    repeat (10) @(posedge clk);
    ahb_read32(REG_ERROR_INTR_STS, rd_val, err);
    check_cond(rd_val[0] == 1'b1 && error_intr == 1'b1,
               "HMAC T3b: 384-bit KV key in HMAC-512 mode triggers key_mode_error despite prior SW key[12..15] poison & CSR_MODE");
    ahb_read32(REG_STATUS, rd_val, err);
    check_cond(rd_val[1] == 1'b0, "HMAC T3c: blocked key_mode_error command does not assert STATUS.VALID");

    // Clear error state via ZEROIZE + W1C interrupt status
    ahb_write32(REG_CTRL, 32'h0000_0004, err);
    ahb_write32(REG_ERROR_INTR_STS, 32'h0000_000F, err);
    wait_hmac_ready(rdy_ok);

    // Reload 384-bit KV key (slot 2), then attempt SW key overwrite AND CSR_MODE=1 override!
    for (int i = 0; i < 16; i++)
      ahb_write32(REG_KEY_BASE + i*4, 32'hCAFE_F00D, err);
    ahb_write32(REG_KV_RD_KEY_CTRL, 32'h0000_0005, err);
    wait_hmac_ready(rdy_ok);
    // Attempt rogue SW writes to KEY[0..3] and CSR_MODE=1 while kv_key_data_present == 1
    for (int i = 0; i < 4; i++)
      ahb_write32(REG_KEY_BASE + i*4, 32'hBAD0_0000 + i, err);
    write_csr_block1024(MSG_B1);
    // Launch HMAC-384 with CSR_MODE bit attempted (INIT=1, MODE=0, CSR_MODE=1, LAST=1 => 0x31)
    ahb_write32(REG_CTRL, 32'h0000_0031, err);
    wait_hmac_ready(rdy_ok);
    read_csr_tag512(got_tag);
    check_cond(got_tag[511:128] == TAG384_KV_KEY_SW_MSG && got_tag[127:0] == 128'h0,
               "HMAC T3d: KV 384-bit key isolated from SW key writes & CSR_MODE override; CSR tag readable when dest_keyvault=0");

    // -----------------------------------------------------------------------
    // T4: KeyVault Block Pre-Clear & Mid-Hash Cycle-20 TOCTOU Write-Lock
    // -----------------------------------------------------------------------
    for (int i = 0; i < 32; i++)
      ahb_write32(REG_BLOCK_BASE + i*4, 32'hF00D_BAAD, err);
    // Load KV key slot 2 (384b) and KV block slot 4 (8 dwords)
    ahb_write32(REG_KV_RD_KEY_CTRL,   32'h0000_0005, err);
    wait_hmac_ready(rdy_ok);
    ahb_write32(REG_KV_RD_BLOCK_CTRL, 32'h0000_0009, err); // slot 4: (4<<1)|1 = 0x09
    wait_hmac_ready(rdy_ok);

    // Kick off HMAC-384 (INIT=1, MODE=0, LAST=1 => 0x21)
    ahb_write32(REG_CTRL, 32'h0000_0021, err);
    // 15 cycles into hash (during CTRL_ENTROPY, ~150 cycles BEFORE CTRL_MSG reads block_msg!),
    // attempt rogue AHB overwrites of HMAC512_BLOCK[0..3], HMAC512_KEY[0..1], and HMAC512_CTRL (MODE flip)!
    repeat (15) @(posedge clk);
    check_cond(busy_o == 1'b1, "HMAC T4a: engine busy during mid-hash TOCTOU attack window");
    ahb_write32(REG_BLOCK_BASE + 0,  32'h1111_2222, err);
    ahb_write32(REG_BLOCK_BASE + 4,  32'h3333_4444, err);
    ahb_write32(REG_BLOCK_BASE + 32, 32'h0000_0000, err);
    ahb_write32(REG_KEY_BASE   + 0,  32'h9999_8888, err);
    ahb_write32(REG_CTRL,            32'h0000_0009, err); // attempt MODE=1 + INIT re-entry

    wait_hmac_ready(rdy_ok);
    read_csr_tag512(got_tag);
    check_cond(got_tag[511:128] == TAG384_KV_KEY_KV_MSG && got_tag[127:0] == 128'h0,
               "HMAC T4b: KV block & key completely immune to mid-hash TOCTOU SW overwrites & MODE flip");

    // -----------------------------------------------------------------------
    // T5: KeyVault Destination Tag Suppression & KV Writeback Busy Lockout
    // -----------------------------------------------------------------------
    // Note: HMAC512_TAG currently holds non-zero TAG384_KV_KEY_KV_MSG!
    // Load 512-bit KV key (slot 3: (3<<1)|1 = 0x07) and KV block (slot 4: 0x09)
    ahb_write32(REG_KV_RD_KEY_CTRL,   32'h0000_0007, err);
    wait_hmac_ready(rdy_ok);
    ahb_write32(REG_KV_RD_BLOCK_CTRL, 32'h0000_0009, err);
    wait_hmac_ready(rdy_ok);

    kv_wr_beat_cnt = 0;
    // Arm KV write to slot 5 with hmac_key_dest_valid (bit 6): (1<<6) | (5<<1) | 1 = 0x4B
    ahb_write32(REG_KV_WR_CTRL, 32'h0000_004B, err);
    repeat (2) @(posedge clk);
    read_csr_tag512(got_tag);
    check_cond(got_tag == 512'h0, "HMAC T5a: arming KV_WR_CTRL immediately suppresses prior CSR TAG residue");

    // Launch HMAC-512 (INIT=1, MODE=1, LAST=1 => 0x29)
    ahb_write32(REG_CTRL, 32'h0000_0029, err);
    // Wait until kv_write.write_en goes high (mid-KV-writeback!) and check busy_o, STATUS.READY, and CTRL lock!
    wait_cyc = 0;
    while (!kv_write.write_en && wait_cyc < 2000) begin
      @(posedge clk);
      wait_cyc++;
    end
    check_cond(kv_write.write_en == 1'b1, "HMAC T5b: KV writeback started");
    check_cond(busy_o == 1'b1, "HMAC T5c: busy_o remains asserted during KV writeback");
    // Attempt MODE flip to 0 mid-KV-writeback (which would corrupt num_dwords from 16 to 12 if not locked!)
    ahb_write32(REG_CTRL, 32'h0000_0000, err);

    wait_hmac_ready(rdy_ok);
    check_cond(rdy_ok, "HMAC T5d: engine ready after KV writeback completes");
    check_cond(kv_wr_beat_cnt == 16, "HMAC T5e: full 16-dword HMAC-512 tag written to KV despite mid-writeback CTRL write");

    for (int i = 0; i < 16; i++)
      got_tag[(15 - i)*32 +: 32] = kv_wr_captured[5][i];
    check_cond(got_tag == TAG512_KV_DEST, "HMAC T5f: KV destination captured exact 512-bit KAT tag");

    read_csr_tag512(got_tag);
    check_cond(got_tag == 512'h0, "HMAC T5g: CSR HMAC512_TAG[0..15] completely suppressed (all zero) after KV-dest op");

    // -----------------------------------------------------------------------
    // T6: debugUnlock_or_scan_mode_switch Bus Isolation & Mid-KV-Writeback Abort
    // -----------------------------------------------------------------------
    // Leave CSR_MODE=1, LFSR_SEED non-zero, SW tag non-zero, then arm KV_WR_CTRL and start op
    write_csr_block1024(MSG_B1);
    ahb_write32(REG_CTRL, 32'h0000_0039, err); // CSR_MODE HMAC-512 -> populates TAG
    wait_hmac_ready(rdy_ok);
    read_csr_tag512(got_tag);
    check_cond(got_tag == TAG512_CSR, "HMAC T6a: pre-debug CSR tag populated");

    // First check immediate CSR TAG wipe & in-flight core abort WITHOUT arming KV_WR_CTRL first!
    ahb_write32(REG_CTRL, 32'h0000_0039, err);
    repeat (25) @(posedge clk);
    check_cond(busy_o == 1'b1, "HMAC T6a_busy: engine busy before debugUnlock");
    #1;
    debugUnlock_or_scan_mode_switch = 1'b1;
    @(posedge clk);
    #1;
    debugUnlock_or_scan_mode_switch = 1'b0;
    repeat (4) @(posedge clk);
    check_cond(busy_o == 1'b0, "HMAC T6a_abort: debugUnlock immediately aborts in-flight HMAC core");
    read_csr_tag512(got_tag);
    check_cond(got_tag == 512'h0, "HMAC T6a_tag: debugUnlock immediately wipes non-KV CSR TAG");

    // Now arm KV_WR_CTRL (slot 6) and start another CSR_MODE op
    ahb_write32(REG_KV_WR_CTRL, 32'h0000_004D, err);
    ahb_write32(REG_CTRL, 32'h0000_0039, err);
    repeat (30) @(posedge clk);

    // Assert debugUnlock_or_scan_mode_switch!
    #1;
    debugUnlock_or_scan_mode_switch = 1'b1;
    @(posedge clk);
    #1;
    // While debugUnlock_or_scan_mode_switch == 1, AHB reads must return 0 without hanging and writes must be blocked!
    ahb_read32(REG_NAME0, rd_val, err);
    check_cond(!err && rd_val == 32'h0, "HMAC T6b: AHB read masked to 0 during debugUnlock_or_scan_mode_switch");
    ahb_write32(REG_KEY_BASE, 32'hAAAA_5555, err);
    repeat (2) @(posedge clk);
    #1;
    debugUnlock_or_scan_mode_switch = 1'b0;

    wait_hmac_ready(rdy_ok);
    check_cond(rdy_ok && !busy_o, "HMAC T6c: engine cleanly aborts and recovers ready after debugUnlock_or_scan_mode_switch");
    ahb_read32(REG_KV_WR_CTRL, rd_val, err);
    check_cond(rd_val[0] == 1'b0, "HMAC T6d: KV_WR_CTRL.write_en cleared by debugUnlock_or_scan_mode_switch");
    read_csr_tag512(got_tag);
    check_cond(got_tag == 512'h0, "HMAC T6e: CSR TAG cleared by debugUnlock_or_scan_mode_switch");

    // Verify CSR_MODE and KEY[0] write during debug were NOT retained:
    // Running SW key HMAC-512 with all-zero key (since KEY was wiped and debug write blocked) + MSG_B1
    // vs writing fresh SW key[0..15] and launching with 0x29:
    for (int i = 0; i < 16; i++) begin
      logic [31:0] kw;
      kw = {8'(4*i), 8'(4*i+1), 8'(4*i+2), 8'(4*i+3)};
      if (i > 0) ahb_write32(REG_KEY_BASE + i*4, kw, err);
    end
    // Note: we deliberately write KEY[0] = 0x00010203 ONLY AFTER checking KEY[0] wasn't 0xAAAA_5555!
    ahb_write32(REG_KEY_BASE + 0, 32'h0001_0203, err);
    write_csr_block1024(MSG_B1);
    ahb_write32(REG_CTRL, 32'h0000_0029, err);
    wait_hmac_ready(rdy_ok);
    read_csr_tag512(got_tag);
    check_cond(got_tag == TAG512_SINGLE, "HMAC T6f: post-debug clean SW HMAC-512 KAT verified");

    // -----------------------------------------------------------------------
    // T7: Malformed AHB-Lite Transfers (Byte, Halfword, 64b Dword, Unaligned Word)
    // -----------------------------------------------------------------------
    // Attempt malformed byte write to KEY[0] and CTRL
    ahb_raw_xfer(REG_KEY_BASE, 3'b000, 1'b1, 64'hFFFF_FFFF_FFFF_FFFF, err_2cyc_ok, raw_rdata);
    check_cond(err_2cyc_ok, "HMAC T7a: byte write rejected with 2-cycle AHB H_ERROR");

    // Attempt malformed halfword write to KEY[0]
    ahb_raw_xfer(REG_KEY_BASE, 3'b001, 1'b1, 64'hFFFF_FFFF_FFFF_FFFF, err_2cyc_ok, raw_rdata);
    check_cond(err_2cyc_ok, "HMAC T7b: halfword write rejected with 2-cycle AHB H_ERROR");

    // Attempt malformed 64-bit dword write to KEY[0]
    ahb_raw_xfer(REG_KEY_BASE, 3'b011, 1'b1, 64'hFFFF_FFFF_FFFF_FFFF, err_2cyc_ok, raw_rdata);
    check_cond(err_2cyc_ok, "HMAC T7c: 64-bit dword write rejected with 2-cycle AHB H_ERROR");

    // Attempt unaligned 32-bit word write (addr[1:0] == 2'b10) to CTRL
    ahb_raw_xfer(REG_CTRL + 32'h2, 3'b010, 1'b1, 64'h0000_0004_0000_0004, err_2cyc_ok, raw_rdata);
    check_cond(err_2cyc_ok, "HMAC T7d: unaligned word write rejected with 2-cycle AHB H_ERROR");

    // Attempt malformed halfword read from TAG[0] (which currently holds TAG512_SINGLE != 0!)
    ahb_raw_xfer(REG_TAG_BASE, 3'b001, 1'b0, 64'h0, err_2cyc_ok, raw_rdata);
    check_cond(err_2cyc_ok && raw_rdata == 64'h0,
               "HMAC T7e: sub-word read from TAG[0] rejected with 2-cycle H_ERROR and zeroed hrdata_o");

    // Confirm none of the malformed writes corrupted KEY[0], BLOCK, or TAG[0..15]!
    read_csr_tag512(got_tag);
    check_cond(got_tag == TAG512_SINGLE, "HMAC T7f: malformed CTRL+2 zeroize write did not clobber TAG");
    ahb_write32(REG_CTRL, 32'h0000_0029, err);
    wait_hmac_ready(rdy_ok);
    read_csr_tag512(got_tag);
    check_cond(got_tag == TAG512_SINGLE, "HMAC T7g: malformed writes did not corrupt HMAC512_KEY[0]");
  endtask

  initial begin
    int unsigned seed_val = 32'd101;
    void'($value$plusargs("SEED=%d", seed_val));

    run_drbg_tests(seed_val);
    run_hmac_subsystem_tests(seed_val);

    if (fail_cnt == 0) begin
      $display("ALL_TESTS_PASSED: pass_cnt=%0d seed=%0d", pass_cnt, seed_val);
      $finish;
    end else begin
      $display("TESTS_FAILED: fail_cnt=%0d pass_cnt=%0d seed=%0d", fail_cnt, pass_cnt, seed_val);
      $fatal(1, "Verification failed");
    end
  end

  initial begin
    #25000000;
    $display("TIMEOUT: testbench exceeded simulation watchdog");
    $fatal(1, "Simulation timeout");
  end

endmodule
