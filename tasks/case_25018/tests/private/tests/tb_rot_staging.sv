`timescale 1ns/1ps

module tb_rot_staging;
  import soc_ifc_pkg::*;

  localparam int unsigned AXI_AW = 16;
  localparam int unsigned AXI_DW = 32;
  localparam int unsigned AXI_IW = 4;
  localparam int unsigned AXI_UW = 32;

  localparam logic [SOC_IFC_ADDR_W-1:0] CSR_BASE       = SHA_REG_START_ADDR[SOC_IFC_ADDR_W-1:0];
  localparam logic [SOC_IFC_ADDR_W-1:0] REG_LOCK       = CSR_BASE + 19'h000;
  localparam logic [SOC_IFC_ADDR_W-1:0] REG_USER       = CSR_BASE + 19'h004;
  localparam logic [SOC_IFC_ADDR_W-1:0] REG_MODE       = CSR_BASE + 19'h008;
  localparam logic [SOC_IFC_ADDR_W-1:0] REG_START_ADDR = CSR_BASE + 19'h00C;
  localparam logic [SOC_IFC_ADDR_W-1:0] REG_DLEN       = CSR_BASE + 19'h010;
  localparam logic [SOC_IFC_ADDR_W-1:0] REG_DATAIN     = CSR_BASE + 19'h014;
  localparam logic [SOC_IFC_ADDR_W-1:0] REG_EXECUTE    = CSR_BASE + 19'h018;
  localparam logic [SOC_IFC_ADDR_W-1:0] REG_STATUS     = CSR_BASE + 19'h01C;
  localparam logic [SOC_IFC_ADDR_W-1:0] REG_DIGEST0    = CSR_BASE + 19'h020;
  localparam logic [SOC_IFC_ADDR_W-1:0] REG_CONTROL    = CSR_BASE + 19'h060;
  localparam logic [SOC_IFC_ADDR_W-1:0] REG_ERR_INTR   = CSR_BASE + 19'h814;
  localparam logic [SOC_IFC_ADDR_W-1:0] REG_NOTIF_INTR = CSR_BASE + 19'h818;

  localparam logic [31:0] ALLOW_USER0 = 32'hA5A5_0001;
  localparam logic [31:0] ALLOW_USER1 = 32'h5A5A_0002;
  localparam logic [31:0] ROGUE_USER  = 32'hDEAD_BEEF;

  logic              clk;
  logic              rst_b;
  logic              cptra_pwrgood;
  logic [1:0][31:0]  allow_axi_user;
  logic              ecc_err_inj_en;
  logic [1:0]        ecc_err_inj_mask;

  logic [AXI_AW-1:0] awaddr;
  logic [1:0]        awburst;
  logic [2:0]        awsize;
  logic [7:0]        awlen;
  logic [AXI_UW-1:0] awuser;
  logic [AXI_IW-1:0] awid;
  logic              awlock, awvalid, awready;

  logic [AXI_DW-1:0] wdata;
  logic [3:0]        wstrb;
  logic              wlast, wvalid, wready;

  logic [1:0]        bresp;
  logic [AXI_IW-1:0] bid;
  logic              bvalid, bready;

  logic [AXI_AW-1:0] araddr;
  logic [1:0]        arburst;
  logic [2:0]        arsize;
  logic [7:0]        arlen;
  logic [AXI_UW-1:0] aruser;
  logic [AXI_IW-1:0] arid;
  logic              arlock, arvalid, arready;

  logic [AXI_DW-1:0] rdata;
  logic [1:0]        rresp;
  logic [AXI_IW-1:0] rid;
  logic              rlast, rvalid, rready;

  logic                      csr_req_dv, csr_req_hold;
  logic [SOC_IFC_ADDR_W-1:0] csr_req_addr;
  logic [31:0]               csr_req_wdata, csr_req_user, csr_rdata;
  logic [3:0]                csr_req_wstrb;
  logic [SOC_IFC_ID_W-1:0]   csr_req_id;
  logic                      csr_req_write, csr_req_soc, csr_err;

  logic sha_error_intr, sha_notif_intr, sha_fsm_error;
  logic ecc_single_pulse, ecc_double_pulse;

  int err_cnt = 0;
  int single_pulse_cnt = 0;
  int double_pulse_cnt = 0;

  initial clk = 1'b0;
  always #5.0 clk = ~clk;

  always @(posedge clk) begin
    if (rst_b) begin
      if (ecc_single_pulse) single_pulse_cnt <= single_pulse_cnt + 1;
      if (ecc_double_pulse) double_pulse_cnt <= double_pulse_cnt + 1;
    end
  end

  rot_staging_subsys #(
    .AXI_AW(AXI_AW), .AXI_DW(AXI_DW), .AXI_IW(AXI_IW), .AXI_UW(AXI_UW)
  ) dut (
    .clk                    (clk),
    .rst_b                  (rst_b),
    .cptra_pwrgood          (cptra_pwrgood),
    .allow_axi_user_i       (allow_axi_user),
    .ecc_err_inj_en_i       (ecc_err_inj_en),
    .ecc_err_inj_mask_i     (ecc_err_inj_mask),
    .s_axi_awaddr_i         (awaddr),
    .s_axi_awburst_i        (awburst),
    .s_axi_awsize_i         (awsize),
    .s_axi_awlen_i          (awlen),
    .s_axi_awuser_i         (awuser),
    .s_axi_awid_i           (awid),
    .s_axi_awlock_i         (awlock),
    .s_axi_awvalid_i        (awvalid),
    .s_axi_awready_o        (awready),
    .s_axi_wdata_i          (wdata),
    .s_axi_wstrb_i          (wstrb),
    .s_axi_wlast_i          (wlast),
    .s_axi_wvalid_i         (wvalid),
    .s_axi_wready_o         (wready),
    .s_axi_bresp_o          (bresp),
    .s_axi_bid_o            (bid),
    .s_axi_bvalid_o         (bvalid),
    .s_axi_bready_i         (bready),
    .s_axi_araddr_i         (araddr),
    .s_axi_arburst_i        (arburst),
    .s_axi_arsize_i         (arsize),
    .s_axi_arlen_i          (arlen),
    .s_axi_aruser_i         (aruser),
    .s_axi_arid_i           (arid),
    .s_axi_arlock_i         (arlock),
    .s_axi_arvalid_i        (arvalid),
    .s_axi_arready_o        (arready),
    .s_axi_rdata_o          (rdata),
    .s_axi_rresp_o          (rresp),
    .s_axi_rid_o            (rid),
    .s_axi_rlast_o          (rlast),
    .s_axi_rvalid_o         (rvalid),
    .s_axi_rready_i         (rready),
    .csr_req_dv_i           (csr_req_dv),
    .csr_req_hold_o         (csr_req_hold),
    .csr_req_addr_i         (csr_req_addr),
    .csr_req_wdata_i        (csr_req_wdata),
    .csr_req_wstrb_i        (csr_req_wstrb),
    .csr_req_user_i         (csr_req_user),
    .csr_req_id_i           (csr_req_id),
    .csr_req_write_i        (csr_req_write),
    .csr_req_soc_i          (csr_req_soc),
    .csr_rdata_o            (csr_rdata),
    .csr_err_o              (csr_err),
    .sha_error_intr_o       (sha_error_intr),
    .sha_notif_intr_o       (sha_notif_intr),
    .sha_fsm_error_o        (sha_fsm_error),
    .ecc_single_err_pulse_o (ecc_single_pulse),
    .ecc_double_err_pulse_o (ecc_double_pulse)
  );

  task automatic check_cond(input bit cond, input string msg);
    if (!cond) begin
      $display("[FAIL] %s (t=%0t)", msg, $time);
      err_cnt++;
    end
  endtask

  task automatic csr_access(
    input  logic [SOC_IFC_ADDR_W-1:0] addr,
    input  logic                      is_wr,
    input  logic [31:0]               wr_val,
    input  logic                      soc_req,
    input  logic [31:0]               usr,
    output logic [31:0]               rd_val,
    output logic                      err_out
  );
    int guard = 0;
    @(negedge clk);
    csr_req_dv    = 1'b1;
    csr_req_addr  = addr;
    csr_req_write = is_wr;
    csr_req_wdata = wr_val;
    csr_req_wstrb = 4'hF;
    csr_req_soc   = soc_req;
    csr_req_user  = usr;
    csr_req_id    = '0;
    while (1) begin
      @(posedge clk);
      if (!csr_req_hold) break;
      guard++;
      if (guard > 500) begin
        $display("[FAIL] CSR hold timeout at addr 0x%0h", addr);
        err_cnt++;
        break;
      end
    end
    rd_val  = csr_rdata;
    err_out = csr_err;
    @(negedge clk);
    csr_req_dv    = 1'b0;
    csr_req_write = 1'b0;
  endtask

  task automatic csr_wr_fw(input logic [SOC_IFC_ADDR_W-1:0] addr, input logic [31:0] val);
    logic [31:0] dummy;
    logic        e;
    csr_access(addr, 1'b1, val, 1'b0, ALLOW_USER0, dummy, e);
    check_cond(!e, $sformatf("Unexpected CSR FW write error at 0x%0h", addr));
  endtask

  task automatic csr_rd_fw(input logic [SOC_IFC_ADDR_W-1:0] addr, output logic [31:0] val);
    logic e;
    csr_access(addr, 1'b0, 32'h0, 1'b0, ALLOW_USER0, val, e);
    check_cond(!e, $sformatf("Unexpected CSR FW read error at 0x%0h", addr));
  endtask
  task automatic axi_write_burst(
    input  logic [15:0] addr,
    input  logic [1:0]  burst,
    input  logic [2:0]  size,
    input  logic [7:0]  len,
    input  logic [31:0] usr,
    input  logic [31:0] data_arr [],
    input  logic [3:0]  strb_arr [],
    output logic [1:0]  resp_out
  );
    int guard;
    @(negedge clk);
    awaddr  = addr;
    awburst = burst;
    awsize  = size;
    awlen   = len;
    awuser  = usr;
    awid    = 4'h3;
    awlock  = 1'b0;
    awvalid = 1'b1;
    guard   = 0;
    while (1) begin
      @(posedge clk);
      if (awready) break;
      guard++;
      if (guard > 500) begin err_cnt++; $display("[FAIL] AWREADY timeout"); break; end
    end
    @(negedge clk);
    awvalid = 1'b0;

    for (int beat = 0; beat <= int'(len); beat++) begin
      @(negedge clk);
      wdata  = data_arr[beat];
      wstrb  = strb_arr[beat];
      wlast  = (beat == int'(len));
      wvalid = 1'b1;
      guard  = 0;
      while (1) begin
        @(posedge clk);
        if (wready) break;
        guard++;
        if (guard > 500) begin err_cnt++; $display("[FAIL] WREADY timeout beat %0d", beat); break; end
      end
    end
    @(negedge clk);
    wvalid = 1'b0;
    wlast  = 1'b0;
    bready = 1'b1;
    guard  = 0;
    while (1) begin
      @(posedge clk);
      if (bvalid) break;
      guard++;
      if (guard > 500) begin err_cnt++; $display("[FAIL] BVALID timeout"); break; end
    end
    resp_out = bresp;
    @(negedge clk);
    bready = 1'b0;
  endtask

  task automatic axi_write_word(
    input  logic [15:0] addr,
    input  logic [31:0] val,
    input  logic [3:0]  strb,
    input  logic [31:0] usr,
    output logic [1:0]  resp_out
  );
    logic [31:0] d_arr [1];
    logic [3:0]  s_arr [1];
    d_arr[0] = val;
    s_arr[0] = strb;
    axi_write_burst(addr, 2'b01, 3'd2, 8'd0, usr, d_arr, s_arr, resp_out);
  endtask

  task automatic axi_read_burst(
    input  logic [15:0] addr,
    input  logic [1:0]  burst,
    input  logic [2:0]  size,
    input  logic [7:0]  len,
    input  logic [31:0] usr,
    input  bit          stall_rready,
    output logic [31:0] data_arr [],
    output logic [1:0]  resp_arr []
  );
    int guard;
    data_arr = new[int'(len) + 1];
    resp_arr = new[int'(len) + 1];
    @(negedge clk);
    araddr  = addr;
    arburst = burst;
    arsize  = size;
    arlen   = len;
    aruser  = usr;
    arid    = 4'h5;
    arlock  = 1'b0;
    arvalid = 1'b1;
    rready  = 1'b0;
    guard   = 0;
    while (1) begin
      @(posedge clk);
      if (arready) break;
      guard++;
      if (guard > 500) begin err_cnt++; $display("[FAIL] ARREADY timeout"); break; end
    end
    @(negedge clk);
    arvalid = 1'b0;

    if (stall_rready) begin
      repeat (4) @(posedge clk);
    end

    for (int beat = 0; beat <= int'(len); beat++) begin
      if (stall_rready && (beat % 2 == 1)) begin
        @(negedge clk);
        rready = 1'b0;
        repeat (2) @(posedge clk);
      end
      @(negedge clk);
      rready = 1'b1;
      guard  = 0;
      while (1) begin
        @(posedge clk);
        if (rvalid) break;
        guard++;
        if (guard > 500) begin err_cnt++; $display("[FAIL] RVALID timeout beat %0d", beat); break; end
      end
      data_arr[beat] = rdata;
      resp_arr[beat] = rresp;
      check_cond(rlast == (beat == int'(len)), $sformatf("RLAST mismatch on beat %0d", beat));
    end
    @(negedge clk);
    rready = 1'b0;
  endtask

  task automatic axi_read_word(
    input  logic [15:0] addr,
    input  logic [31:0] usr,
    output logic [31:0] val,
    output logic [1:0]  resp_out
  );
    logic [31:0] d_arr [];
    logic [1:0]  r_arr [];
    axi_read_burst(addr, 2'b01, 3'd2, 8'd0, usr, 1'b0, d_arr, r_arr);
    val      = d_arr[0];
    resp_out = r_arr[0];
  endtask

  task automatic wait_sha_done(output bit saw_valid);
    logic [31:0] st;
    saw_valid = 1'b0;
    for (int poll = 0; poll < 400; poll++) begin
      csr_rd_fw(REG_STATUS, st);
      if (st[0]) begin
        saw_valid = 1'b1;
        break;
      end
    end
  endtask

  task automatic read_digest(output logic [0:15][31:0] dig);
    for (int k = 0; k < 16; k++) begin
      csr_rd_fw(REG_DIGEST0 + 19'(k * 4), dig[k]);
    end
  endtask
  initial begin
    logic [1:0]          b_rsp, r_rsp;
    logic [31:0]         rd_w, lock_v, err_sts;
    logic [31:0]         wr_buf [];
    logic [3:0]          st_buf [];
    logic [31:0]         rd_buf [];
    logic [1:0]          rr_buf [];
    logic [0:15][31:0]   dig_stream, dig_mbox, dig_chk;
    logic                c_err;
    bit                  ok_done;
    int                  sp_before, dp_before;

    rst_b            = 1'b0;
    cptra_pwrgood    = 1'b0;
    allow_axi_user   = {ALLOW_USER1, ALLOW_USER0};
    ecc_err_inj_en   = 1'b0;
    ecc_err_inj_mask = 2'b00;
    awaddr = '0; awburst = '0; awsize = '0; awlen = '0; awuser = '0; awid = '0; awlock = 0; awvalid = 0;
    wdata = '0; wstrb = '0; wlast = 0; wvalid = 0; bready = 0;
    araddr = '0; arburst = '0; arsize = '0; arlen = '0; aruser = '0; arid = '0; arlock = 0; arvalid = 0; rready = 0;
    csr_req_dv = 0; csr_req_addr = '0; csr_req_wdata = '0; csr_req_wstrb = '0; csr_req_user = '0; csr_req_id = '0;
    csr_req_write = 0; csr_req_soc = 0;

    repeat (6) @(posedge clk);
    cptra_pwrgood = 1'b1;
    rst_b         = 1'b1;
    repeat (6) @(posedge clk);
    csr_wr_fw(REG_LOCK, 32'd1); // Release reset-owned FW lock to start from unlocked state

    // 1. AXI burst write/read + backpressure + user/bounds/burst-legality + WSTRB=0 no-op
    wr_buf = new[4]; st_buf = new[4];
    for (int i = 0; i < 4; i++) begin wr_buf[i] = 32'h1122_3300 + i; st_buf[i] = 4'hF; end
    axi_write_burst(16'h0040, 2'b01, 3'd2, 8'd3, ALLOW_USER0, wr_buf, st_buf, b_rsp);
    check_cond(b_rsp == 2'b00, "Burst write OKAY");
    axi_read_burst(16'h0040, 2'b01, 3'd2, 8'd3, ALLOW_USER1, 1'b1, rd_buf, rr_buf);
    for (int i = 0; i < 4; i++) begin
      check_cond(rr_buf[i] == 2'b00 && rd_buf[i] == (32'h1122_3300 + i), "Burst readback under backpressure");
    end

    // WSTRB=0 no-op must preserve data & SECDED parity
    sp_before = single_pulse_cnt; dp_before = double_pulse_cnt;
    axi_write_word(16'h0040, 32'hFFFF_FFFF, 4'h0, ALLOW_USER0, b_rsp);
    check_cond(b_rsp == 2'b00, "WSTRB=0 write OKAY");
    axi_read_word(16'h0040, ALLOW_USER0, rd_w, r_rsp);
    check_cond(r_rsp == 2'b00 && rd_w == 32'h1122_3300, "WSTRB=0 preserved word");
    check_cond(single_pulse_cnt == sp_before && double_pulse_cnt == dp_before, "WSTRB=0 preserved ECC parity");

    // Unauthorized user, OOB >= 0x2000, and illegal burst attributes
    axi_write_word(16'h0040, 32'hBAD0_BAD0, 4'hF, ROGUE_USER, b_rsp);
    check_cond(b_rsp == 2'b10, "Rogue AXI write SLVERR");
    axi_read_word(16'h0040, ROGUE_USER, rd_w, r_rsp);
    check_cond(r_rsp == 2'b10 && rd_w == 32'h0, "Rogue AXI read SLVERR + zero rdata");
    axi_read_word(16'h2000, ALLOW_USER0, rd_w, r_rsp);
    check_cond(r_rsp == 2'b10 && rd_w == 32'h0, "OOB AXI read SLVERR + zero rdata");
    axi_write_burst(16'h0040, 2'b11, 3'd2, 8'd1, ALLOW_USER0, wr_buf, st_buf, b_rsp);
    check_cond(b_rsp == 2'b10, "Illegal RESERVED burst write SLVERR");
    axi_read_burst(16'h0040, 2'b01, 3'd3, 8'd1, ALLOW_USER0, 1'b0, rd_buf, rr_buf);
    check_cond(rr_buf[0] == 2'b10 && rd_buf[0] == 32'h0 && rr_buf[1] == 2'b10 && rd_buf[1] == 32'h0, "Illegal ARSIZE>2 SLVERR + zero rdata");
    axi_read_word(16'h0040, ALLOW_USER0, rd_w, r_rsp);
    check_cond(rd_w == 32'h1122_3300, "Illegal writes did not mutate SRAM");

    // 2. Sub-dword ECC-checked RMW
    axi_write_word(16'h0044, 32'h00AA_BB00, 4'b0110, ALLOW_USER0, b_rsp);
    check_cond(b_rsp == 2'b00, "Sub-dword RMW OKAY");
    sp_before = single_pulse_cnt; dp_before = double_pulse_cnt;
    axi_read_word(16'h0044, ALLOW_USER0, rd_w, r_rsp);
    check_cond(r_rsp == 2'b00 && rd_w == 32'h11AA_BB01, "Sub-dword RMW merged value");
    check_cond(single_pulse_cnt == sp_before && double_pulse_cnt == dp_before, "Sub-dword RMW clean ECC");

    // 3. Single-bit ECC fault injection -> correction + 1-cycle hardware scrub
    ecc_err_inj_en = 1'b1; ecc_err_inj_mask = 2'b01;
    axi_write_word(16'h0810, 32'hCAFE_F00D, 4'hF, ALLOW_USER0, b_rsp);
    ecc_err_inj_en = 1'b0; ecc_err_inj_mask = 2'b00;
    sp_before = single_pulse_cnt;
    axi_read_word(16'h0810, ALLOW_USER0, rd_w, r_rsp);
    repeat (2) @(posedge clk);
    check_cond(r_rsp == 2'b00 && rd_w == 32'hCAFE_F00D && (single_pulse_cnt == sp_before + 1), "1-bit ECC corrected + pulsed");
    sp_before = single_pulse_cnt;
    axi_read_word(16'h0810, ALLOW_USER0, rd_w, r_rsp);
    repeat (2) @(posedge clk);
    check_cond(r_rsp == 2'b00 && rd_w == 32'hCAFE_F00D && (single_pulse_cnt == sp_before), "1-bit ECC scrubbed in SRAM");

    // 4. Double-bit ECC fault injection -> read SLVERR+zero & RMW abort
    ecc_err_inj_en = 1'b1; ecc_err_inj_mask = 2'b11;
    axi_write_word(16'h0C20, 32'hFACE_1234, 4'hF, ALLOW_USER0, b_rsp);
    ecc_err_inj_en = 1'b0; ecc_err_inj_mask = 2'b00;
    dp_before = double_pulse_cnt;
    axi_read_word(16'h0C20, ALLOW_USER0, rd_w, r_rsp);
    repeat (2) @(posedge clk);
    check_cond(r_rsp == 2'b10 && rd_w == 32'h0 && (double_pulse_cnt == dp_before + 1), "2-bit ECC AXI read SLVERR + zero rdata");
    dp_before = double_pulse_cnt;
    axi_write_word(16'h0C20, 32'h0000_0099, 4'b0001, ALLOW_USER0, b_rsp);
    repeat (2) @(posedge clk);
    check_cond(b_rsp == 2'b10 && (double_pulse_cnt == dp_before + 1), "2-bit ECC RMW aborted with SLVERR");

    // 5. Empty-message (DLEN = 0) SHA-512 in streaming_mode and mailbox_mode
    csr_rd_fw(REG_LOCK, lock_v); check_cond(lock_v == 32'd0, "Acquire FW lock empty stream");
    csr_wr_fw(REG_MODE, 32'h0000_0001); // streaming SHA-512
    csr_wr_fw(REG_DLEN, 32'd0);
    csr_wr_fw(REG_EXECUTE, 32'd1);
    wait_sha_done(ok_done); check_cond(ok_done, "Streaming DLEN=0 completed");
    read_digest(dig_chk);
    check_cond(dig_chk[0] == 32'hcf83e135 && dig_chk[15] == 32'hf927da3e, "Streaming DLEN=0 NIST SHA-512 match");
    csr_wr_fw(REG_LOCK, 32'd1);

    csr_rd_fw(REG_LOCK, lock_v);
    csr_wr_fw(REG_MODE, 32'h0000_0003); // mailbox SHA-512
    csr_wr_fw(REG_START_ADDR, 32'h0000_0100);
    csr_wr_fw(REG_DLEN, 32'd0);
    csr_wr_fw(REG_EXECUTE, 32'd1);
    wait_sha_done(ok_done); check_cond(ok_done, "Mailbox DLEN=0 completed");
    read_digest(dig_chk);
    check_cond(dig_chk[0] == 32'hcf83e135 && dig_chk[15] == 32'hf927da3e, "Mailbox DLEN=0 NIST SHA-512 match");
    csr_wr_fw(REG_LOCK, 32'd1);

    // 6 & 7. Multi-block (260B across bank boundary 0x0380..0x0484) + 1-bit ECC in window + active write-lock
    for (int w = 0; w < 65; w++) begin
      if (w == 7) begin ecc_err_inj_en = 1'b1; ecc_err_inj_mask = 2'b01; end
      axi_write_word(16'h0380 + 16'(w * 4), 32'h3040_5000 + w, 4'hF, ALLOW_USER0, b_rsp);
      ecc_err_inj_en = 1'b0; ecc_err_inj_mask = 2'b00;
    end
    // Reference streaming digest on same 260B payload
    csr_rd_fw(REG_LOCK, lock_v);
    csr_wr_fw(REG_MODE, 32'h0000_0001);
    csr_wr_fw(REG_DLEN, 32'd260);
    for (int w = 0; w < 65; w++) csr_wr_fw(REG_DATAIN, 32'h3040_5000 + w);
    csr_wr_fw(REG_EXECUTE, 32'd1);
    wait_sha_done(ok_done); check_cond(ok_done, "Streaming 260B completed");
    read_digest(dig_stream);
    csr_wr_fw(REG_LOCK, 32'd1);

    // Launch mailbox_mode on [0x0380, 0x0484) and immediately test active staging write-lock
    csr_rd_fw(REG_LOCK, lock_v);
    csr_wr_fw(REG_MODE, 32'h0000_0003);
    csr_wr_fw(REG_START_ADDR, 32'h0000_0380);
    csr_wr_fw(REG_DLEN, 32'd260);
    csr_wr_fw(REG_EXECUTE, 32'd1);
    // Concurrent AXI write inside locked window must fail with SLVERR; outside window must succeed
    axi_write_word(16'h0390, 32'hDEAD_0000, 4'hF, ALLOW_USER0, b_rsp);
    check_cond(b_rsp == 2'b10, "AXI write inside active SHA staging window rejected");
    axi_write_word(16'h1800, 32'h7788_99AA, 4'hF, ALLOW_USER0, b_rsp);
    check_cond(b_rsp == 2'b00, "AXI write outside active SHA staging window allowed");
    wait_sha_done(ok_done); check_cond(ok_done, "Mailbox 260B completed");
    read_digest(dig_mbox);
    check_cond(dig_mbox == dig_stream, "Mailbox 260B digest matches streaming reference");
    // Verify 1-bit fault at word 7 (0x039C) was scrubbed during SHA direct read
    sp_before = single_pulse_cnt;
    axi_read_word(16'h039C, ALLOW_USER0, rd_w, r_rsp);
    repeat (2) @(posedge clk);
    check_cond(r_rsp == 2'b00 && rd_w == (32'h3040_5000 + 7) && (single_pulse_cnt == sp_before), "SHA read 1-bit fault scrubbed");

    // 9. CONTROL.ZEROIZE access control & persistent secret wipe
    csr_access(REG_CONTROL, 1'b1, 32'd1, 1'b1, ROGUE_USER, rd_w, c_err);
    check_cond(c_err == 1'b1, "Unauthorized SoC CONTROL.ZEROIZE write blocked while FW holds lock");
    read_digest(dig_chk);
    check_cond(dig_chk == dig_stream, "Digest intact after blocked unauthorized ZEROIZE");
    csr_wr_fw(REG_CONTROL, 32'd1); // Authorized FW ZEROIZE
    repeat (6) @(posedge clk);
    read_digest(dig_chk);
    csr_rd_fw(REG_STATUS, rd_w);
    check_cond(dig_chk == '0 && rd_w[0] == 1'b0, "Authorized ZEROIZE persistently wiped DIGEST and STATUS.VALID");
    csr_wr_fw(REG_LOCK, 32'd1);
    // Unauthorized SoC write to CONTROL when LOCK=0 must also be blocked
    csr_access(REG_CONTROL, 1'b1, 32'd1, 1'b1, ALLOW_USER0, rd_w, c_err);
    check_cond(c_err == 1'b1, "Unauthorized SoC CONTROL.ZEROIZE write blocked when LOCK=0");

    // 8. Out-of-bounds mailbox_mode (error1_sts) & 2-bit ECC fault quarantine (error2_sts)
    csr_rd_fw(REG_LOCK, lock_v);
    csr_wr_fw(REG_ERR_INTR, 32'hFFFF_FFFF); // W1C clear error_internal_intr_r
    csr_wr_fw(REG_MODE, 32'h0000_0003);
    csr_wr_fw(REG_START_ADDR, 32'h0000_1FF0);
    csr_wr_fw(REG_DLEN, 32'd32); // 0x1FF0 + 0x20 = 0x2010 > 0x2000
    csr_wr_fw(REG_EXECUTE, 32'd1);
    repeat (10) @(posedge clk);
    csr_rd_fw(REG_ERR_INTR, err_sts);
    csr_rd_fw(REG_STATUS, rd_w);
    check_cond(err_sts[1] == 1'b1 && rd_w[0] == 1'b0, "OOB mailbox_mode sets error1_sts and suppresses VALID");
    csr_wr_fw(REG_ERR_INTR, 32'hFFFF_FFFF);

    // 2-bit ECC fault at 0x0C20 inside mailbox_mode window [0x0C1C, 0x0C28)
    axi_write_word(16'h0C1C, 32'h1234_5678, 4'hF, ALLOW_USER0, b_rsp);
    axi_write_word(16'h0C24, 32'h8765_4321, 4'hF, ALLOW_USER0, b_rsp);
    csr_wr_fw(REG_START_ADDR, 32'h0000_0C1C);
    csr_wr_fw(REG_DLEN, 32'd12);
    csr_wr_fw(REG_EXECUTE, 32'd1);
    repeat (25) @(posedge clk);
    csr_rd_fw(REG_ERR_INTR, err_sts);
    csr_rd_fw(REG_STATUS, rd_w);
    read_digest(dig_chk);
    check_cond(err_sts[2] == 1'b1 && rd_w[0] == 1'b0 && dig_chk == '0, "2-bit ECC in mailbox_mode sets error2_sts and quarantines digest");
    csr_wr_fw(REG_LOCK, 32'd1);

    if (err_cnt == 0) begin
      $display("PASS: All rot_staging_subsys tests passed!");
      $finish;
    end else begin
      $display("FAIL: %0d errors detected", err_cnt);
      $fatal(1, "rot_staging_subsys testbench failed");
    end
  end
endmodule
