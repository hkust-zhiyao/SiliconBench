`timescale 1ns/1ps

module tb_data_offload;

  localparam int MEM_SIZE_LOG2 = 10;
  localparam int NARROW_W      = 32;
  localparam int WIDE_W        = 128;

  logic up_clk = 1'b0;
  logic dev_clk = 1'b0;
  logic sys_clk = 1'b0;

  logic up_rstn = 1'b0;
  logic dev_aresetn = 1'b0;
  logic sys_aresetn = 1'b0;

  // AXI4-Lite RX & TX
  logic        rx_axi_awvalid, rx_axi_awready, rx_axi_wvalid, rx_axi_wready;
  logic [15:0] rx_axi_awaddr,  rx_axi_araddr;
  logic [ 2:0] rx_axi_awprot = 3'd0, rx_axi_arprot = 3'd0;
  logic [31:0] rx_axi_wdata,   rx_axi_rdata;
  logic [ 3:0] rx_axi_wstrb = 4'hF;
  logic        rx_axi_bvalid,  rx_axi_bready, rx_axi_arvalid, rx_axi_arready;
  logic [ 1:0] rx_axi_bresp,   rx_axi_rresp;
  logic        rx_axi_rvalid,  rx_axi_rready;

  logic        tx_axi_awvalid, tx_axi_awready, tx_axi_wvalid, tx_axi_wready;
  logic [15:0] tx_axi_awaddr,  tx_axi_araddr;
  logic [ 2:0] tx_axi_awprot = 3'd0, tx_axi_arprot = 3'd0;
  logic [31:0] tx_axi_wdata,   tx_axi_rdata;
  logic [ 3:0] tx_axi_wstrb = 4'hF;
  logic        tx_axi_bvalid,  tx_axi_bready, tx_axi_arvalid, tx_axi_arready;
  logic [ 1:0] tx_axi_bresp,   tx_axi_rresp;
  logic        tx_axi_rvalid,  tx_axi_rready;

  // RX Stream & Storage
  logic                  rx_s_axis_ready, rx_s_axis_valid, rx_s_axis_last;
  logic [NARROW_W-1:0]   rx_s_axis_data;
  logic [NARROW_W/8-1:0] rx_s_axis_keep;

  logic                  rx_m_axis_ready, rx_m_axis_valid, rx_m_axis_last;
  logic [WIDE_W-1:0]     rx_m_axis_data;
  logic [WIDE_W/8-1:0]   rx_m_axis_keep;

  logic                  rx_init_req, rx_sync_ext, rx_ddr_calib_done;

  logic                  rx_m_storage_axis_ready, rx_m_storage_axis_valid, rx_m_storage_axis_last;
  logic [NARROW_W-1:0]   rx_m_storage_axis_data;
  logic [NARROW_W/8-1:0] rx_m_storage_axis_keep;

  logic                  rx_s_storage_axis_ready, rx_s_storage_axis_valid, rx_s_storage_axis_last;
  logic [WIDE_W-1:0]     rx_s_storage_axis_data;
  logic [WIDE_W/8-1:0]   rx_s_storage_axis_keep;

  logic                     rx_wr_request_enable, rx_wr_request_valid, rx_wr_request_ready;
  logic [MEM_SIZE_LOG2-1:0] rx_wr_request_length, rx_wr_response_measured_length;
  logic                     rx_wr_response_eot, rx_wr_overflow;

  logic                     rx_rd_request_enable, rx_rd_request_valid, rx_rd_request_ready;
  logic [MEM_SIZE_LOG2-1:0] rx_rd_request_length;
  logic                     rx_rd_response_eot, rx_rd_underflow;

  // TX Stream & Storage
  logic                  tx_s_axis_ready, tx_s_axis_valid, tx_s_axis_last;
  logic [WIDE_W-1:0]     tx_s_axis_data;
  logic [WIDE_W/8-1:0]   tx_s_axis_keep;

  logic                  tx_m_axis_ready, tx_m_axis_valid, tx_m_axis_last;
  logic [NARROW_W-1:0]   tx_m_axis_data;
  logic [NARROW_W/8-1:0] tx_m_axis_keep;

  logic                  tx_init_req, tx_sync_ext, tx_ddr_calib_done;

  logic                  tx_m_storage_axis_ready, tx_m_storage_axis_valid, tx_m_storage_axis_last;
  logic [WIDE_W-1:0]     tx_m_storage_axis_data;
  logic [WIDE_W/8-1:0]   tx_m_storage_axis_keep;

  logic                  tx_s_storage_axis_ready, tx_s_storage_axis_valid, tx_s_storage_axis_last;
  logic [NARROW_W-1:0]   tx_s_storage_axis_data;
  logic [NARROW_W/8-1:0] tx_s_storage_axis_keep;

  logic                     tx_wr_request_enable, tx_wr_request_valid, tx_wr_request_ready;
  logic [MEM_SIZE_LOG2-1:0] tx_wr_request_length, tx_wr_response_measured_length;
  logic                     tx_wr_response_eot, tx_wr_overflow;

  logic                     tx_rd_request_enable, tx_rd_request_valid, tx_rd_request_ready;
  logic [MEM_SIZE_LOG2-1:0] tx_rd_request_length;
  logic                     tx_rd_response_eot, tx_rd_underflow;

  data_offload_subsys #(
    .MEM_SIZE_LOG2(MEM_SIZE_LOG2)
  ) dut (.*);

  int seed = 101;
  int err_cnt = 0;

  // Three asynchronous clocks (up_clk ~135MHz, dev_clk ~77MHz, sys_clk ~185MHz)
  initial begin
    #1.1ns;
    forever #3.7ns up_clk = ~up_clk;
  end
  initial begin
    #2.3ns;
    forever #6.5ns dev_clk = ~dev_clk;
  end
  initial begin
    #0.7ns;
    forever #2.7ns sys_clk = ~sys_clk;
  end

  function automatic void check(input bit cond, input string msg);
    if (!cond) begin
      $display("FAIL: [%0t] %s", $time, msg);
      err_cnt++;
      if (err_cnt >= 8) $fatal(1, "Aborting after %0d errors", err_cnt);
    end
  endfunction

  // Continuous TX DAC idle-zero invariant check (Requirement 1)
  logic tx_idle_chk_en = 1'b0;
  always @(posedge dev_clk) begin
    if (dev_aresetn && tx_idle_chk_en && !tx_m_axis_valid) begin
      check(tx_m_axis_data === 32'd0, $sformatf("TX m_axis_data non-zero (0x%08x) while m_axis_valid==0", tx_m_axis_data));
    end
  end
  // AXI4-Lite Master Tasks (simulator-order-independent pre-edge handshake sampling)
  task automatic axi_write_rx(input logic [15:0] addr, input logic [31:0] data);
    int to = 0;
    bit aw_done = 1'b0, w_done = 1'b0, b_done = 1'b0;
    bit aw_fire, w_fire, b_fire;
    @(posedge up_clk); #1ps;
    rx_axi_awaddr  = addr;
    rx_axi_awvalid = 1'b1;
    rx_axi_wdata   = data;
    rx_axi_wvalid  = 1'b1;
    rx_axi_bready  = 1'b1;
    while (!(aw_done && w_done && b_done)) begin
      #1ps;
      aw_fire = rx_axi_awvalid && rx_axi_awready;
      w_fire  = rx_axi_wvalid  && rx_axi_wready;
      b_fire  = rx_axi_bvalid  && rx_axi_bready;
      @(posedge up_clk); #1ps;
      if (aw_fire) begin aw_done = 1'b1; rx_axi_awvalid = 1'b0; end
      if (w_fire)  begin w_done  = 1'b1; rx_axi_wvalid  = 1'b0; end
      if (b_fire)  begin b_done  = 1'b1; rx_axi_bready  = 1'b0; end
      to = to + 1;
      if (to > 200) begin check(0, "RX AXI write timeout"); break; end
    end
    rx_axi_awvalid = 1'b0;
    rx_axi_wvalid  = 1'b0;
    rx_axi_bready  = 1'b0;
  endtask

  task automatic axi_write_tx(input logic [15:0] addr, input logic [31:0] data);
    int to = 0;
    bit aw_done = 1'b0, w_done = 1'b0, b_done = 1'b0;
    bit aw_fire, w_fire, b_fire;
    @(posedge up_clk); #1ps;
    tx_axi_awaddr  = addr;
    tx_axi_awvalid = 1'b1;
    tx_axi_wdata   = data;
    tx_axi_wvalid  = 1'b1;
    tx_axi_bready  = 1'b1;
    while (!(aw_done && w_done && b_done)) begin
      #1ps;
      aw_fire = tx_axi_awvalid && tx_axi_awready;
      w_fire  = tx_axi_wvalid  && tx_axi_wready;
      b_fire  = tx_axi_bvalid  && tx_axi_bready;
      @(posedge up_clk); #1ps;
      if (aw_fire) begin aw_done = 1'b1; tx_axi_awvalid = 1'b0; end
      if (w_fire)  begin w_done  = 1'b1; tx_axi_wvalid  = 1'b0; end
      if (b_fire)  begin b_done  = 1'b1; tx_axi_bready  = 1'b0; end
      to = to + 1;
      if (to > 200) begin check(0, "TX AXI write timeout"); break; end
    end
    tx_axi_awvalid = 1'b0;
    tx_axi_wvalid  = 1'b0;
    tx_axi_bready  = 1'b0;
  endtask

  task automatic axi_read_tx(input logic [15:0] addr, output logic [31:0] rdata);
    int to = 0;
    bit ar_done = 1'b0, r_done = 1'b0;
    bit ar_fire, r_fire;
    @(posedge up_clk); #1ps;
    tx_axi_araddr  = addr;
    tx_axi_arvalid = 1'b1;
    tx_axi_rready  = 1'b1;
    while (!(ar_done && r_done)) begin
      #1ps;
      ar_fire = tx_axi_arvalid && tx_axi_arready;
      r_fire  = tx_axi_rvalid  && tx_axi_rready;
      if (r_fire) rdata = tx_axi_rdata;
      @(posedge up_clk); #1ps;
      if (ar_fire) begin ar_done = 1'b1; tx_axi_arvalid = 1'b0; end
      if (r_fire)  begin r_done  = 1'b1; tx_axi_rready  = 1'b0; end
      to = to + 1;
      if (to > 200) begin check(0, "TX AXI read timeout"); break; end
    end
    tx_axi_arvalid = 1'b0;
    tx_axi_rready  = 1'b0;
  endtask

  // util_do_ram-faithful Storage Models (2-request pipelined read queue)
  byte rx_mem [0:1023];
  logic        rx_wr_act = 1'b0;
  logic [9:0]  rx_wr_ptr = 10'd0, rx_wr_lim = 10'd0;
  assign rx_wr_request_ready    = !rx_wr_act;
  assign rx_m_storage_axis_ready = rx_wr_act;
  assign rx_wr_overflow = 1'b0;

  always @(posedge dev_clk) begin
    if (!dev_aresetn || !rx_wr_request_enable) begin
      rx_wr_act <= 1'b0;
      rx_wr_ptr <= 10'd0;
      rx_wr_response_eot <= 1'b0;
      rx_wr_response_measured_length <= 10'd0;
    end else begin
      rx_wr_response_eot <= 1'b0;
      if (rx_wr_request_valid && rx_wr_request_ready) begin
        rx_wr_act <= 1'b1;
        rx_wr_ptr <= 10'd0;
        rx_wr_lim <= rx_wr_request_length;
      end else if (rx_wr_act && rx_m_storage_axis_valid && rx_m_storage_axis_ready) begin
        for (int b = 0; b < 4; b++) begin
          if (rx_m_storage_axis_keep[b]) rx_mem[rx_wr_ptr + b[9:0]] <= rx_m_storage_axis_data[8*b +: 8];
        end
        if (rx_m_storage_axis_last || (rx_wr_ptr + 10'd3 >= rx_wr_lim)) begin
          rx_wr_act <= 1'b0;
          rx_wr_response_eot <= 1'b1;
          rx_wr_response_measured_length <= rx_wr_ptr + 10'd3;
        end else begin
          rx_wr_ptr <= rx_wr_ptr + 10'd4;
        end
      end
    end
  end

  logic [9:0] rx_rd_q [0:1];
  logic       rx_rd_wp = 1'b0, rx_rd_rp = 1'b0;
  logic [1:0] rx_rd_cnt = 2'd0;
  logic [9:0] rx_rd_ptr = 10'd0;
  wire        rx_rd_act = (rx_rd_cnt != 2'd0);
  wire [9:0]  rx_rd_lim = rx_rd_q[rx_rd_rp];
  assign rx_rd_request_ready = ~rx_rd_cnt[1];
  assign rx_rd_underflow = 1'b0;
  assign rx_s_storage_axis_valid = rx_rd_act && rx_rd_request_enable;
  assign rx_s_storage_axis_last  = rx_s_storage_axis_valid && ((rx_rd_ptr + 10'd15) >= rx_rd_lim);
  always_comb begin
    for (int b = 0; b < 16; b++) begin
      rx_s_storage_axis_data[8*b +: 8] = rx_mem[rx_rd_ptr + b[9:0]];
      rx_s_storage_axis_keep[b]        = ((rx_rd_ptr + b[9:0]) <= rx_rd_lim);
    end
  end
  assign rx_rd_response_eot = (rx_s_storage_axis_valid && rx_s_storage_axis_ready && rx_s_storage_axis_last) ||
                              (rx_rd_act && !rx_rd_request_enable);

  always @(posedge sys_clk) begin
    if (!sys_aresetn || !rx_rd_request_enable) begin
      rx_rd_cnt <= 2'd0;
      rx_rd_wp  <= 1'b0;
      rx_rd_rp  <= 1'b0;
      rx_rd_ptr <= 10'd0;
    end else begin
      automatic bit push = rx_rd_request_valid && rx_rd_request_ready;
      automatic bit pop  = rx_s_storage_axis_valid && rx_s_storage_axis_ready && rx_s_storage_axis_last;
      if (push) begin
        rx_rd_q[rx_rd_wp] <= rx_rd_request_length;
        rx_rd_wp <= ~rx_rd_wp;
      end
      if (rx_s_storage_axis_valid && rx_s_storage_axis_ready) begin
        if (rx_s_storage_axis_last) begin
          rx_rd_ptr <= 10'd0;
          rx_rd_rp  <= ~rx_rd_rp;
        end else begin
          rx_rd_ptr <= rx_rd_ptr + 10'd16;
        end
      end
      case ({push, pop})
        2'b10: rx_rd_cnt <= rx_rd_cnt + 2'd1;
        2'b01: rx_rd_cnt <= rx_rd_cnt - 2'd1;
        default: ;
      endcase
    end
  end
  // TX Storage Model (128b @ sys_clk write -> 32b @ dev_clk 2-request pipelined read)
  byte tx_mem [0:1023];
  logic        tx_wr_act = 1'b0;
  logic [9:0]  tx_wr_ptr = 10'd0, tx_wr_lim = 10'd0;
  int          tx_wr_req_cnt_mon = 0;
  assign tx_wr_request_ready     = !tx_wr_act;
  assign tx_m_storage_axis_ready = tx_wr_act;
  assign tx_wr_overflow = 1'b0;

  always @(posedge sys_clk) begin
    if (!sys_aresetn || !tx_wr_request_enable) begin
      tx_wr_act <= 1'b0;
      tx_wr_ptr <= 10'd0;
      tx_wr_response_eot <= 1'b0;
      tx_wr_response_measured_length <= 10'd0;
    end else begin
      tx_wr_response_eot <= 1'b0;
      if (tx_wr_request_valid && tx_wr_request_ready) begin
        tx_wr_act <= 1'b1;
        tx_wr_ptr <= 10'd0;
        tx_wr_lim <= tx_wr_request_length;
        tx_wr_req_cnt_mon <= tx_wr_req_cnt_mon + 1;
      end else if (tx_wr_act && tx_m_storage_axis_valid && tx_m_storage_axis_ready) begin
        for (int b = 0; b < 16; b++) begin
          if (tx_m_storage_axis_keep[b]) tx_mem[tx_wr_ptr + b[9:0]] <= tx_m_storage_axis_data[8*b +: 8];
        end
        if (tx_m_storage_axis_last || (tx_wr_ptr + 10'd15 >= tx_wr_lim)) begin
          tx_wr_act <= 1'b0;
          tx_wr_response_eot <= 1'b1;
          tx_wr_response_measured_length <= tx_wr_ptr + 10'd15;
        end else begin
          tx_wr_ptr <= tx_wr_ptr + 10'd16;
        end
      end
    end
  end

  logic [9:0] tx_rd_q [0:1];
  logic       tx_rd_wp = 1'b0, tx_rd_rp = 1'b0;
  logic [1:0] tx_rd_cnt = 2'd0;
  logic [9:0] tx_rd_ptr = 10'd0;
  int         tx_rd_req_cnt_mon = 0;
  wire        tx_rd_act = (tx_rd_cnt != 2'd0);
  wire [9:0]  tx_rd_lim = tx_rd_q[tx_rd_rp];
  assign tx_rd_request_ready = ~tx_rd_cnt[1];
  assign tx_rd_underflow = 1'b0;
  assign tx_s_storage_axis_valid = tx_rd_act && tx_rd_request_enable;
  assign tx_s_storage_axis_last  = tx_s_storage_axis_valid && ((tx_rd_ptr + 10'd3) >= tx_rd_lim);
  always_comb begin
    for (int b = 0; b < 4; b++) begin
      tx_s_storage_axis_data[8*b +: 8] = tx_mem[tx_rd_ptr + b[9:0]];
      tx_s_storage_axis_keep[b]        = ((tx_rd_ptr + b[9:0]) <= tx_rd_lim);
    end
  end
  assign tx_rd_response_eot = (tx_s_storage_axis_valid && tx_s_storage_axis_ready && tx_s_storage_axis_last) ||
                              (tx_rd_act && !tx_rd_request_enable);

  always @(posedge dev_clk) begin
    if (!dev_aresetn || !tx_rd_request_enable) begin
      tx_rd_cnt <= 2'd0;
      tx_rd_wp  <= 1'b0;
      tx_rd_rp  <= 1'b0;
      tx_rd_ptr <= 10'd0;
    end else begin
      automatic bit push = tx_rd_request_valid && tx_rd_request_ready;
      automatic bit pop  = tx_s_storage_axis_valid && tx_s_storage_axis_ready && tx_s_storage_axis_last;
      if (push) begin
        tx_rd_q[tx_rd_wp] <= tx_rd_request_length;
        tx_rd_wp <= ~tx_rd_wp;
        tx_rd_req_cnt_mon <= tx_rd_req_cnt_mon + 1;
      end
      if (tx_s_storage_axis_valid && tx_s_storage_axis_ready) begin
        if (tx_s_storage_axis_last) begin
          tx_rd_ptr <= 10'd0;
          tx_rd_rp  <= ~tx_rd_rp;
        end else begin
          tx_rd_ptr <= tx_rd_ptr + 10'd4;
        end
      end
      case ({push, pop})
        2'b10: tx_rd_cnt <= tx_rd_cnt + 2'd1;
        2'b01: tx_rd_cnt <= tx_rd_cnt - 2'd1;
        default: ;
      endcase
    end
  end

  // Byte-stream packet monitors for RX m_axis (128b @ sys_clk) and TX m_axis (32b @ dev_clk)
  typedef struct {
    int  len;
    byte b[256];
  } pkt_t;

  pkt_t rx_pkts[$];
  pkt_t tx_pkts[$];
  pkt_t rx_cur;
  pkt_t tx_cur;

  always @(posedge sys_clk) begin
    if (!sys_aresetn) begin
      rx_cur.len = 0;
    end else if (rx_m_axis_valid && rx_m_axis_ready) begin
      for (int k = 0; k < 16; k++) begin
        if (rx_m_axis_keep[k]) begin
          if (rx_cur.len < 256) rx_cur.b[rx_cur.len] = rx_m_axis_data[8*k +: 8];
          rx_cur.len++;
        end
      end
      if (rx_m_axis_last) begin
        rx_pkts.push_back(rx_cur);
        rx_cur.len = 0;
      end
    end
  end

  always @(posedge dev_clk) begin
    if (!dev_aresetn) begin
      tx_cur.len = 0;
    end else if (tx_m_axis_valid && tx_m_axis_ready) begin
      for (int k = 0; k < 4; k++) begin
        if (tx_m_axis_keep[k]) begin
          if (tx_cur.len < 256) tx_cur.b[tx_cur.len] = tx_m_axis_data[8*k +: 8];
          tx_cur.len++;
        end
      end
      if (tx_m_axis_last) begin
        tx_pkts.push_back(tx_cur);
        tx_cur.len = 0;
      end
    end
  end

  initial begin
    #600000ns;
    $display("FAIL: Global simulation watchdog timeout");
    $fatal(1, "Watchdog timeout");
  end

  task automatic send_rx_pkt(input int nbytes, input byte base_tag);
    int idx = 0;
    @(posedge dev_clk);
    #1ps;
    while (idx < nbytes) begin
      int rem = nbytes - idx;
      int take = (rem > 4) ? 4 : rem;
      logic [31:0] d = 32'hDEAD_BEEF;
      logic [ 3:0] kp = 4'd0;
      for (int k = 0; k < take; k++) begin
        d[8*k +: 8] = base_tag + byte'(idx + k);
        kp[k]       = 1'b1;
      end
      rx_s_axis_valid <= 1'b1;
      rx_s_axis_data  <= d;
      rx_s_axis_keep  <= kp;
      rx_s_axis_last  <= ((idx + take) == nbytes);
      #1ps;
      begin
        int to = 0;
        while (!rx_s_axis_ready) begin
          @(posedge dev_clk);
          #1ps;
          to = to + 1;
          if (to > 400) begin
            check(0, $sformatf("RX s_axis_ready stall timeout at byte %0d/%0d", idx, nbytes));
            break;
          end
        end
        @(posedge dev_clk);
        #1ps;
      end
      idx += take;
    end
    rx_s_axis_valid <= 1'b0;
    rx_s_axis_last  <= 1'b0;
    rx_s_axis_keep  <= 4'd0;
  endtask

  task automatic send_tx_pkt(input int nbytes, input byte base_tag);
    int idx = 0;
    @(posedge sys_clk);
    #1ps;
    while (idx < nbytes) begin
      int rem = nbytes - idx;
      int take = (rem > 16) ? 16 : rem;
      logic [127:0] d = 128'hCAFE_BABE_1234_5678_9ABC_DEF0_1122_3344;
      logic [ 15:0] kp = 16'd0;
      for (int k = 0; k < take; k++) begin
        d[8*k +: 8] = base_tag + byte'(idx + k);
        kp[k]       = 1'b1;
      end
      tx_s_axis_valid <= 1'b1;
      tx_s_axis_data  <= d;
      tx_s_axis_keep  <= kp;
      tx_s_axis_last  <= ((idx + take) == nbytes);
      #1ps;
      begin
        int to = 0;
        while (!tx_s_axis_ready) begin
          @(posedge sys_clk);
          #1ps;
          to = to + 1;
          if (to > 400) begin
            check(0, $sformatf("TX s_axis_ready stall timeout at byte %0d/%0d", idx, nbytes));
            break;
          end
        end
        @(posedge sys_clk);
        #1ps;
      end
      idx += take;
    end
    tx_s_axis_valid <= 1'b0;
    tx_s_axis_last  <= 1'b0;
    tx_s_axis_keep  <= 16'd0;
  endtask
  function automatic void verify_pkt(input pkt_t got, input int exp_len, input byte base_tag, input string ctx);
    check(got.len == exp_len, $sformatf("%s: len=%0d exp=%0d", ctx, got.len, exp_len));
    for (int i = 0; i < exp_len && i < got.len; i++) begin
      byte exp_b = base_tag + byte'(i);
      if (got.b[i] !== exp_b) begin
        check(0, $sformatf("%s: byte[%0d]=0x%02x exp=0x%02x", ctx, i, got.b[i], exp_b));
        break;
      end
    end
  endfunction

  logic bp_mode = 1'b0;
  logic hold_rx_m_ready = 1'b0;
  int   sys_cyc = 0, dev_cyc = 0;
  always @(posedge sys_clk) begin
    sys_cyc <= sys_cyc + 1;
    if (!sys_aresetn || hold_rx_m_ready) rx_m_axis_ready <= 1'b0;
    else if (bp_mode)                    rx_m_axis_ready <= ((sys_cyc + seed) % 11 == 0);
    else                                 rx_m_axis_ready <= 1'b1;
  end
  always @(posedge dev_clk) begin
    dev_cyc <= dev_cyc + 1;
    if (!dev_aresetn) tx_m_axis_ready <= 1'b0;
    else if (bp_mode) tx_m_axis_ready <= ((dev_cyc + seed) % 7 == 0);
    else              tx_m_axis_ready <= 1'b1;
  end

  initial begin
    void'($value$plusargs("seed=%d", seed));
    rx_axi_awvalid = 0; rx_axi_wvalid = 0; rx_axi_bready = 0; rx_axi_arvalid = 0; rx_axi_rready = 0;
    tx_axi_awvalid = 0; tx_axi_wvalid = 0; tx_axi_bready = 0; tx_axi_arvalid = 0; tx_axi_rready = 0;
    rx_s_axis_valid = 0; rx_s_axis_data = '0; rx_s_axis_keep = '0; rx_s_axis_last = 0;
    tx_s_axis_valid = 0; tx_s_axis_data = '0; tx_s_axis_keep = '0; tx_s_axis_last = 0;
    rx_init_req = 0; rx_sync_ext = 0; rx_ddr_calib_done = 1;
    tx_init_req = 0; tx_sync_ext = 0; tx_ddr_calib_done = 1;

    repeat (12) @(posedge dev_clk);
    up_rstn = 1'b1;
    dev_aresetn = 1'b1;
    sys_aresetn = 1'b1;
    repeat (10) @(posedge dev_clk);
    tx_idle_chk_en = 1'b1;

    // =========================================================================
    // PHASE 1: Asymmetric Bypass (RX 32->128 & TX 128->32, short/partial/backpressure)
    // =========================================================================
    axi_write_rx(16'h0088, 32'h0000_0003); // ONESHOT=1, BYPASS=1
    axi_write_tx(16'h0088, 32'h0000_0001); // BYPASS=1
    axi_write_rx(16'h0084, 32'h0000_0001); // RESETN=1
    axi_write_tx(16'h0084, 32'h0000_0001); // RESETN=1
    repeat (15) @(posedge dev_clk);

    bp_mode = 1'b1;
    begin
      int rx_lens[12] = '{3, 6, 11, 16, 2, 9, 15, 21, 4, 7, 13, 19};
      int tx_lens[8]  = '{3, 7, 13, 16, 19, 25, 31, 36};
      rx_pkts.delete();
      tx_pkts.delete();
      fork
        begin
          for (int p = 0; p < 12; p++) send_rx_pkt(rx_lens[p], byte'(8'h10 + p*7));
        end
        begin
          for (int p = 0; p < 8; p++)  send_tx_pkt(tx_lens[p], byte'(8'h80 + p*9));
        end
      join
      bp_mode = 1'b0;
      repeat (80) @(posedge dev_clk);
      check(rx_pkts.size() == 12, $sformatf("Phase1 RX bypass pkt count=%0d exp=12", rx_pkts.size()));
      for (int p = 0; p < 12 && p < rx_pkts.size(); p++)
        verify_pkt(rx_pkts[p], rx_lens[p], byte'(8'h10 + p*7), $sformatf("Phase1 RX[%0d]", p));
      check(tx_pkts.size() == 8, $sformatf("Phase1 TX bypass pkt count=%0d exp=8", tx_pkts.size()));
      for (int p = 0; p < 8 && p < tx_pkts.size(); p++)
        verify_pkt(tx_pkts[p], tx_lens[p], byte'(8'h80 + p*9), $sformatf("Phase1 TX[%0d]", p));
    end

    // Explicit burst-fill + early-TLAST hold/drain test on RX bypass (small_slave)
    begin : blk_phase1b
      bit sender_done;
      sender_done = 1'b0;
      rx_pkts.delete();
      @(posedge sys_clk);
      bp_mode = 1'b0;
      hold_rx_m_ready = 1'b1;
      @(posedge sys_clk);
      fork
        begin
          for (int f = 0; f < 15; f++) send_rx_pkt(16, byte'(8'h30 + f));
          send_rx_pkt(8, 8'h75);
          sender_done = 1'b1;
        end
        begin
          int full_cycs;
          full_cycs = 0;
          // Hold downstream m_axis_ready=0 until either all 16 pkts buffer OR FIFO reaches full backpressure!
          while (!sender_done && full_cycs < 12) begin
            @(posedge dev_clk);
            if (!rx_s_axis_ready) full_cycs = full_cycs + 1;
            else full_cycs = 0;
          end
          repeat (8) @(posedge dev_clk);
          hold_rx_m_ready = 1'b0;
        end
      join
      repeat (100) @(posedge sys_clk);
      check(rx_pkts.size() == 16, $sformatf("Phase1b early-TLAST stall test count=%0d exp=16", rx_pkts.size()));
      if (rx_pkts.size() == 16) verify_pkt(rx_pkts[15], 8, 8'h75, "Phase1b tail pkt");
    end

    // =========================================================================
    // PHASE 2: RX Offload Three-Clock Sync (6 staggered single-write SW triggers + HW + AUTO)
    // =========================================================================
    axi_write_rx(16'h0084, 32'h0000_0000);
    axi_write_rx(16'h0088, 32'h0000_0002); // ONESHOT=1, BYPASS=0
    axi_write_rx(16'h001C, 32'h0000_0000); // 64B max transfer_length ({0, 6'h3F} = 63)
    axi_write_rx(16'h0104, 32'h0000_0002); // SOFTWARE sync
    axi_write_rx(16'h0084, 32'h0000_0001);
    repeat (15) @(posedge dev_clk);

    rx_pkts.delete();
    for (int s = 0; s < 6; s++) begin
      rx_init_req <= 1'b1;
      repeat (12) @(posedge dev_clk); // Wait for WR_STATE_SYNC
      repeat (s + (seed % 3)) @(posedge up_clk); // Sweep CDC toggle phase!
      axi_write_rx(16'h0100, 32'h0000_0001);     // Single software trigger write
      send_rx_pkt(32, byte'(8'h40 + s*5));
      begin
        int to = 0;
        while (rx_pkts.size() <= s && to < 250) begin
          @(posedge sys_clk);
          to++;
        end
        check(rx_pkts.size() == s + 1, $sformatf("Phase2 RX SW sync[%0d] missed or duplicated (got %0d)", s, rx_pkts.size()));
        if (rx_pkts.size() == s + 1) verify_pkt(rx_pkts[s], 32, byte'(8'h40 + s*5), $sformatf("Phase2 RX SW[%0d]", s));
      end
      rx_init_req <= 1'b0;
      repeat (12) @(posedge dev_clk);
    end

    // RX HARDWARE sync
    axi_write_rx(16'h0104, 32'h0000_0001);
    repeat (10) @(posedge dev_clk);
    rx_init_req <= 1'b1;
    repeat (12) @(posedge dev_clk);
    @(posedge dev_clk); rx_sync_ext <= 1'b1;
    @(posedge dev_clk); rx_sync_ext <= 1'b0;
    send_rx_pkt(32, 8'h99);
    repeat (40) @(posedge sys_clk);
    check(rx_pkts.size() == 7, $sformatf("Phase2 RX HW sync count=%0d exp=7", rx_pkts.size()));
    rx_init_req <= 1'b0;
    repeat (12) @(posedge dev_clk);
    // RX AUTOMATIC sync
    axi_write_rx(16'h0104, 32'h0000_0000);
    repeat (10) @(posedge dev_clk);
    rx_init_req <= 1'b1;
    repeat (10) @(posedge dev_clk);
    send_rx_pkt(32, 8'hAA);
    repeat (40) @(posedge sys_clk);
    check(rx_pkts.size() == 8, $sformatf("Phase2 RX AUTO sync count=%0d exp=8", rx_pkts.size()));
    if (rx_pkts.size() == 8) verify_pkt(rx_pkts[7], 32, 8'hAA, "Phase2 RX AUTO");
    rx_init_req <= 1'b0;
    repeat (12) @(posedge dev_clk);

    // =========================================================================
    // PHASE 3: TX Cyclic Replay (SW, HW, AUTO) & Replacement Buffer Lock
    // =========================================================================
    axi_write_tx(16'h0084, 32'h0000_0000);
    axi_write_tx(16'h0088, 32'h0000_0000); // ONESHOT=0 (CYCLIC), BYPASS=0
    axi_write_tx(16'h001C, 32'h0000_0000); // 64B max transfer_length
    axi_write_tx(16'h0104, 32'h0000_0002); // SOFTWARE sync
    axi_write_tx(16'h0084, 32'h0000_0001); // RESETN=1
    repeat (15) @(posedge dev_clk);

    tx_pkts.delete();
    tx_wr_req_cnt_mon = 0;
    tx_rd_req_cnt_mon = 0;

    // Load 32B waveform A into TX storage (tx_init_req=1 during load, then 0)
    tx_init_req <= 1'b1;
    repeat (10) @(posedge sys_clk);
    send_tx_pkt(32, 8'hA0);
    repeat (8) @(posedge sys_clk);
    tx_init_req <= 1'b0;

    // Wait 35 dev_clk cycles before any trigger: must remain gated at sync barrier
    // with ZERO emitted packets and NO runaway storage read requests!
    repeat (35) @(posedge dev_clk);
    check(tx_pkts.size() == 0, $sformatf("Phase3 TX SW cyclic emitted %0d pkts before trigger", tx_pkts.size()));
    check(tx_rd_req_cnt_mon == 1, $sformatf("Phase3 TX SW cyclic runaway rd_req=%0d exp=1 before trigger", tx_rd_req_cnt_mon));

    // Issue 4 staggered single-write software triggers: each must emit EXACTLY 1 pass!
    for (int t = 0; t < 4; t++) begin
      repeat (t + (seed % 3)) @(posedge up_clk);
      axi_write_tx(16'h0100, 32'h0000_0001);
      repeat (35) @(posedge dev_clk);
      check(tx_pkts.size() == t + 1, $sformatf("Phase3 TX SW cyclic[%0d] pkt count=%0d exp=%0d", t, tx_pkts.size(), t + 1));
      if (tx_pkts.size() == t + 1) verify_pkt(tx_pkts[t], 32, 8'hA0, $sformatf("Phase3 TX SW[%0d]", t));
      // Verify TX WR FSM is STILL locked in WR_STATE_WAIT_RD while cyclic replay is active!
      begin
        logic [31:0] dbg;
        axi_read_tx(16'h0200, dbg);
        check(dbg[4:0] == 5'b10000, $sformatf("Phase3 TX WR FSM unlocked early during cyclic pass %0d (dbg=0x%08x)", t, dbg));
      end
    end

    // Switch to HARDWARE sync in cyclic mode: 2 pulses -> 2 exact passes
    axi_write_tx(16'h0104, 32'h0000_0001);
    repeat (12) @(posedge dev_clk);
    for (int h = 0; h < 2; h++) begin
      @(posedge dev_clk); tx_sync_ext <= 1'b1;
      @(posedge dev_clk); tx_sync_ext <= 1'b0;
      repeat (30) @(posedge dev_clk);
      check(tx_pkts.size() == 5 + h, $sformatf("Phase3 TX HW cyclic[%0d] pkt count=%0d exp=%0d", h, tx_pkts.size(), 5 + h));
      if (tx_pkts.size() == 5 + h) verify_pkt(tx_pkts[4 + h], 32, 8'hA0, $sformatf("Phase3 TX HW[%0d]", h));
    end

    // Switch to AUTOMATIC cyclic replay & test replacement buffer loading via tx_init_req=1
    axi_write_tx(16'h0104, 32'h0000_0000);
    repeat (60) @(posedge dev_clk);
    check(tx_pkts.size() >= 10, $sformatf("Phase3 TX AUTO cyclic did not stream continuously (got %0d)", tx_pkts.size()));
    check(tx_wr_req_cnt_mon == 1, $sformatf("Phase3 TX WR req count=%0d exp=1 before re-init", tx_wr_req_cnt_mon));

    // Assert tx_init_req=1 to stop cyclic replay and load replacement waveform B (8'hB0)
    tx_init_req <= 1'b1;
    send_tx_pkt(32, 8'hB0);
    begin
      int to = 0;
      while (tx_wr_req_cnt_mon < 2 && to < 120) begin
        @(posedge sys_clk);
        to = to + 1;
      end
    end
    repeat (8) @(posedge sys_clk);
    tx_init_req <= 1'b0;
    check(tx_wr_req_cnt_mon == 2, $sformatf("Phase3 TX replacement write did not execute (wr_req=%0d exp=2)", tx_wr_req_cnt_mon));

    repeat (50) @(posedge dev_clk);
    check(tx_pkts.size() >= 14, "Phase3 TX replacement waveform B did not replay");
    if (tx_pkts.size() > 0) verify_pkt(tx_pkts[tx_pkts.size()-1], 32, 8'hB0, "Phase3 TX waveform B");

    // =========================================================================
    // PHASE 4: Software & Hardware Reset Domain Crossing Clean Recovery
    // =========================================================================
    // 4a) Software reset (0x0084=0) during active TX cyclic replay must clear rd_cyclic_en / tx_rd_request_valid
    axi_write_tx(16'h0084, 32'h0000_0000);
    repeat (15) @(posedge dev_clk);
    check(tx_rd_request_valid === 1'b0, "Phase4a tx_rd_request_valid stuck high after SW reset");
    check(tx_wr_request_enable === 1'b0, "Phase4a tx_wr_request_enable stuck high after SW reset");

    tx_pkts.delete();
    tx_rd_req_cnt_mon = 0;
    axi_write_tx(16'h0088, 32'h0000_0002); // ONESHOT=1, BYPASS=0
    axi_write_tx(16'h0084, 32'h0000_0001); // Release SW reset with tx_init_req==0
    repeat (35) @(posedge dev_clk);
    check(tx_rd_req_cnt_mon == 0 && tx_pkts.size() == 0,
          $sformatf("Phase4a phantom TX read after SW reset (rd_req=%0d, pkts=%0d)", tx_rd_req_cnt_mon, tx_pkts.size()));

    // 4b) Stale measured_length CDC & stream reset purge on dev_aresetn / sys_aresetn
    rx_pkts.delete();
    hold_rx_m_ready = 1'b1;
    @(posedge sys_clk);
    rx_init_req <= 1'b1;
    repeat (8) @(posedge dev_clk);
    send_rx_pkt(32, 8'hC0);
    repeat (10) @(posedge dev_clk);
    rx_init_req <= 1'b0;
    dev_aresetn <= 1'b0;
    sys_aresetn <= 1'b0;
    repeat (10) @(posedge dev_clk);
    hold_rx_m_ready = 1'b0;
    dev_aresetn <= 1'b1;
    sys_aresetn <= 1'b1;
    repeat (30) @(posedge sys_clk);
    check(rx_pkts.size() == 0 && rx_rd_request_valid === 1'b0,
          $sformatf("Phase4b stale RX transfer after dev/sys_aresetn (pkts=%0d, rd_req_val=%0b)", rx_pkts.size(), rx_rd_request_valid));

    // Final post-reset clean RX capture sanity check after joint reset
    rx_init_req <= 1'b1;
    repeat (10) @(posedge dev_clk);
    send_rx_pkt(32, 8'hD4);
    repeat (40) @(posedge sys_clk);
    rx_init_req <= 1'b0;
    check(rx_pkts.size() == 1, $sformatf("Phase4b post-reset RX capture count=%0d exp=1", rx_pkts.size()));
    if (rx_pkts.size() == 1) verify_pkt(rx_pkts[0], 32, 8'hD4, "Phase4b post-reset RX");
    repeat (10) @(posedge dev_clk);

    // 4c) Unilateral dev_aresetn-only reset (sys_aresetn=1) during RX write completion & backpressure
    #1ps;
    rx_pkts.delete();
    rx_cur.len = 0;
    hold_rx_m_ready = 1'b1;
    @(posedge sys_clk);
    rx_init_req <= 1'b1;
    repeat (8) @(posedge dev_clk);
    send_rx_pkt(32, 8'hC0);
    repeat (10) @(posedge dev_clk);
    rx_init_req <= 1'b0;
    dev_aresetn <= 1'b0; // sys_aresetn stays 1'b1!
    repeat (6) @(posedge dev_clk);
    check(rx_m_axis_valid === 1'b0 && rx_rd_request_enable === 1'b0 && rx_wr_request_enable === 1'b0,
          "Phase4c unilateral dev_aresetn did not clear RX dst/storage state");
    repeat (4) @(posedge dev_clk);
    hold_rx_m_ready = 1'b0;
    dev_aresetn <= 1'b1;
    repeat (12) @(posedge dev_clk);
    check(rx_pkts.size() == 0 && rx_cur.len == 0 && rx_rd_request_valid === 1'b0 && rx_m_axis_valid === 1'b0,
          $sformatf("Phase4c stale RX transfer after unilateral dev_aresetn (pkts=%0d, cur=%0d, rd_req_val=%0b)",
                    rx_pkts.size(), rx_cur.len, rx_rd_request_valid));

    rx_init_req <= 1'b1;
    repeat (10) @(posedge dev_clk);
    send_rx_pkt(32, 8'hD5);
    repeat (40) @(posedge sys_clk);
    rx_init_req <= 1'b0;
    check(rx_pkts.size() == 1, $sformatf("Phase4c post-dev_aresetn RX capture count=%0d exp=1", rx_pkts.size()));
    if (rx_pkts.size() == 1) verify_pkt(rx_pkts[0], 32, 8'hD5, "Phase4c post-dev_aresetn RX");
    repeat (10) @(posedge dev_clk);

    // 4d) Unilateral sys_aresetn-only reset (dev_aresetn=1) during stalled >32B RX readout (WR_STATE_WAIT_RD)
    #1ps;
    rx_pkts.delete();
    rx_cur.len = 0;
    hold_rx_m_ready = 1'b1;
    @(posedge sys_clk);
    rx_init_req <= 1'b1;
    repeat (8) @(posedge dev_clk);
    send_rx_pkt(48, 8'hC8);
    repeat (10) @(posedge dev_clk);
    rx_init_req <= 1'b0;
    sys_aresetn <= 1'b0; // dev_aresetn stays 1'b1!
    repeat (6) @(posedge dev_clk);
    check(rx_wr_request_enable === 1'b0 && rx_wr_request_valid === 1'b0 && rx_m_axis_valid === 1'b0,
          "Phase4d unilateral sys_aresetn did not clear RX src/wr_fsm state");
    repeat (4) @(posedge dev_clk);
    hold_rx_m_ready = 1'b0;
    sys_aresetn <= 1'b1;
    repeat (12) @(posedge dev_clk);
    check(rx_pkts.size() == 0 && rx_cur.len == 0 && rx_rd_request_valid === 1'b0 && rx_m_axis_valid === 1'b0,
          $sformatf("Phase4d stale RX transfer after unilateral sys_aresetn (pkts=%0d, cur=%0d, rd_req_val=%0b)",
                    rx_pkts.size(), rx_cur.len, rx_rd_request_valid));

    rx_init_req <= 1'b1;
    repeat (10) @(posedge dev_clk);
    send_rx_pkt(32, 8'hD8);
    repeat (40) @(posedge sys_clk);
    rx_init_req <= 1'b0;
    check(rx_pkts.size() == 1, $sformatf("Phase4d post-sys_aresetn RX capture count=%0d exp=1", rx_pkts.size()));
    if (rx_pkts.size() == 1) verify_pkt(rx_pkts[0], 32, 8'hD8, "Phase4d post-sys_aresetn RX");
    repeat (10) @(posedge dev_clk);

    // 4e) Unilateral sys_aresetn-only reset mid-RX-capture (partial non-TLAST write active in storage)
    #1ps;
    rx_pkts.delete();
    rx_cur.len = 0;
    rx_init_req <= 1'b1;
    repeat (10) @(posedge dev_clk);
    for (int w = 0; w < 4; w++) begin
      @(posedge dev_clk);
      #1ps;
      rx_s_axis_valid <= 1'b1;
      rx_s_axis_data  <= {4{byte'(8'hE0 + w)}};
      rx_s_axis_keep  <= 4'hF;
      rx_s_axis_last  <= 1'b0;
      begin
        int to = 0;
        while (!rx_s_axis_ready && to < 200) begin
          @(posedge dev_clk);
          #1ps;
          to++;
        end
      end
    end
    @(posedge dev_clk);
    #1ps;
    rx_s_axis_valid <= 1'b0;
    rx_s_axis_keep  <= 4'h0;
    rx_init_req     <= 1'b0;
    sys_aresetn     <= 1'b0; // Unilateral sys_aresetn mid-capture!
    repeat (6) @(posedge dev_clk);
    check(rx_wr_request_enable === 1'b0 && rx_wr_act === 1'b0,
          "Phase4e unilateral sys_aresetn mid-capture did not abort active RX storage write");
    repeat (4) @(posedge dev_clk);
    sys_aresetn <= 1'b1;
    repeat (12) @(posedge dev_clk);
    check(rx_pkts.size() == 0 && rx_cur.len == 0,
          "Phase4e phantom RX data after mid-capture unilateral sys_aresetn");

    rx_init_req <= 1'b1;
    repeat (10) @(posedge dev_clk);
    send_rx_pkt(32, 8'hDC);
    repeat (40) @(posedge sys_clk);
    rx_init_req <= 1'b0;
    check(rx_pkts.size() == 1, $sformatf("Phase4e post-abort RX capture count=%0d exp=1", rx_pkts.size()));
    if (rx_pkts.size() == 1) verify_pkt(rx_pkts[0], 32, 8'hDC, "Phase4e post-abort RX");
    repeat (10) @(posedge dev_clk);

    // 4f & 4g) Unilateral dev_aresetn-only and unilateral sys_aresetn-only resets during active TX cyclic playback
    axi_write_tx(16'h0084, 32'h0000_0000);
    axi_write_tx(16'h0088, 32'h0000_0000); // ONESHOT=0 (CYCLIC), BYPASS=0
    axi_write_tx(16'h0104, 32'h0000_0000); // AUTOMATIC sync
    axi_write_tx(16'h0084, 32'h0000_0001);
    repeat (15) @(posedge dev_clk);
    #1ps;
    tx_pkts.delete();
    tx_cur.len = 0;
    tx_wr_req_cnt_mon = 0;
    tx_rd_req_cnt_mon = 0;

    tx_init_req <= 1'b1;
    repeat (10) @(posedge sys_clk);
    send_tx_pkt(32, 8'hE4);
    repeat (8) @(posedge sys_clk);
    tx_init_req <= 1'b0;
    repeat (45) @(posedge dev_clk);
    check(tx_pkts.size() >= 2, $sformatf("Phase4f TX cyclic pre-reset did not stream (got %0d)", tx_pkts.size()));

    // 4f) Unilateral dev_aresetn=0 (sys_aresetn=1) during active TX cyclic replay
    dev_aresetn <= 1'b0;
    repeat (6) @(posedge dev_clk);
    check(tx_wr_request_enable === 1'b0 && tx_rd_request_enable === 1'b0 &&
          tx_rd_request_valid === 1'b0 && tx_m_axis_valid === 1'b0,
          "Phase4f unilateral dev_aresetn during TX cyclic did not clear TX wr/rd state");
    repeat (4) @(posedge dev_clk);
    dev_aresetn <= 1'b1;
    repeat (10) @(posedge dev_clk);
    #1ps;
    tx_pkts.delete();
    tx_cur.len = 0;
    tx_rd_req_cnt_mon = 0;
    repeat (30) @(posedge dev_clk);
    check(tx_rd_req_cnt_mon == 0 && tx_pkts.size() == 0 && tx_cur.len == 0 && tx_m_axis_valid === 1'b0,
          $sformatf("Phase4f phantom TX cyclic replay after unilateral dev_aresetn (rd_req=%0d, pkts=%0d)",
                    tx_rd_req_cnt_mon, tx_pkts.size()));
    begin
      logic [31:0] dbg;
      axi_read_tx(16'h0200, dbg);
      check(dbg[4:0] == 5'b00001,
            $sformatf("Phase4f TX WR FSM stuck after unilateral dev_aresetn (dbg=0x%08x)", dbg));
    end

    // Reload TX cyclic buffer (0xEC) and verify recovery
    tx_init_req <= 1'b1;
    repeat (10) @(posedge sys_clk);
    send_tx_pkt(32, 8'hEC);
    repeat (8) @(posedge sys_clk);
    tx_init_req <= 1'b0;
    repeat (45) @(posedge dev_clk);
    check(tx_pkts.size() >= 2, $sformatf("Phase4f post-dev_aresetn TX cyclic count=%0d exp>=2", tx_pkts.size()));
    if (tx_pkts.size() >= 1) verify_pkt(tx_pkts[0], 32, 8'hEC, "Phase4f post-dev_aresetn TX");

    // 4g) Unilateral sys_aresetn=0 (dev_aresetn=1) during active TX cyclic replay
    sys_aresetn <= 1'b0;
    repeat (6) @(posedge dev_clk);
    check(tx_wr_request_enable === 1'b0 && tx_rd_request_enable === 1'b0 &&
          tx_rd_request_valid === 1'b0 && tx_m_axis_valid === 1'b0,
          "Phase4g unilateral sys_aresetn during TX cyclic did not halt TX rd/m_axis");
    repeat (4) @(posedge dev_clk);
    sys_aresetn <= 1'b1;
    repeat (10) @(posedge dev_clk);
    #1ps;
    tx_pkts.delete();
    tx_cur.len = 0;
    tx_rd_req_cnt_mon = 0;
    repeat (30) @(posedge dev_clk);
    check(tx_rd_req_cnt_mon == 0 && tx_pkts.size() == 0 && tx_cur.len == 0 && tx_m_axis_valid === 1'b0,
          $sformatf("Phase4g phantom TX cyclic replay after unilateral sys_aresetn (rd_req=%0d, pkts=%0d, cur=%0d)",
                    tx_rd_req_cnt_mon, tx_pkts.size(), tx_cur.len));

    axi_write_tx(16'h0088, 32'h0000_0002); // ONESHOT=1, BYPASS=0
    repeat (8) @(posedge dev_clk);
    tx_init_req <= 1'b1;
    repeat (10) @(posedge sys_clk);
    send_tx_pkt(32, 8'hF2);
    repeat (8) @(posedge sys_clk);
    tx_init_req <= 1'b0;
    repeat (35) @(posedge dev_clk);
    check(tx_pkts.size() == 1, $sformatf("Phase4g post-sys_aresetn TX oneshot count=%0d exp=1", tx_pkts.size()));
    if (tx_pkts.size() == 1) verify_pkt(tx_pkts[0], 32, 8'hF2, "Phase4g post-sys_aresetn TX");

    if (err_cnt == 0) begin
      $display("PASS_DATA_OFFLOAD seed=%0d", seed);
      $finish;
    end else begin
      $fatal(1, "FAILED with %0d errors", err_cnt);
    end
  end

endmodule
