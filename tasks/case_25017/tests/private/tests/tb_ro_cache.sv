`timescale 1ns/1ps

module tb_ro_cache;
  localparam int unsigned LineWidth    = 256;
  localparam int unsigned LineCount    = 256;
  localparam int unsigned SetCount     = 2;
  localparam int unsigned AxiAddrWidth = 32;
  localparam int unsigned AxiDataWidth = 64;
  localparam int unsigned AxiIdWidth   = 3;
  localparam int unsigned AxiUserWidth = 2;
  localparam int unsigned MaxTrans     = 4;
  localparam int unsigned NrAddrRules  = 2;

  `ifndef TB_SEED
  `define TB_SEED 32'h25017101
  `endif

  logic clk = 1'b0;
  always #5 clk = ~clk;

  logic rst_n;
  logic enable;
  logic flush_valid, flush_ready;
  logic [NrAddrRules-1:0][31:0] start_addr, end_addr;

  logic [2:0]  slv_aw_id, slv_ar_id;
  logic [31:0] slv_aw_addr, slv_ar_addr;
  logic [7:0]  slv_aw_len, slv_ar_len;
  logic [2:0]  slv_aw_size, slv_ar_size;
  logic [1:0]  slv_aw_burst, slv_ar_burst;
  logic        slv_aw_lock, slv_ar_lock;
  logic [3:0]  slv_aw_cache, slv_ar_cache, slv_aw_qos, slv_ar_qos, slv_aw_region, slv_ar_region;
  logic [2:0]  slv_aw_prot, slv_ar_prot;
  logic [5:0]  slv_aw_atop;
  logic [1:0]  slv_aw_user, slv_ar_user, slv_w_user;
  logic        slv_aw_valid, slv_aw_ready;
  logic [63:0] slv_w_data;
  logic [7:0]  slv_w_strb;
  logic        slv_w_last, slv_w_valid, slv_w_ready;
  logic [2:0]  slv_b_id;
  logic [1:0]  slv_b_resp, slv_b_user;
  logic        slv_b_valid, slv_b_ready;
  logic        slv_ar_valid, slv_ar_ready;
  logic [2:0]  slv_r_id;
  logic [63:0] slv_r_data;
  logic [1:0]  slv_r_resp, slv_r_user;
  logic        slv_r_last, slv_r_valid, slv_r_ready;

  logic [3:0]  mst_aw_id, mst_b_id, mst_ar_id, mst_r_id;
  logic [31:0] mst_aw_addr, mst_ar_addr;
  logic [7:0]  mst_aw_len, mst_ar_len;
  logic [2:0]  mst_aw_size, mst_ar_size;
  logic [1:0]  mst_aw_burst, mst_ar_burst, mst_b_resp, mst_r_resp;
  logic        mst_aw_lock, mst_ar_lock;
  logic [3:0]  mst_aw_cache, mst_ar_cache, mst_aw_qos, mst_ar_qos, mst_aw_region, mst_ar_region;
  logic [2:0]  mst_aw_prot, mst_ar_prot;
  logic [5:0]  mst_aw_atop;
  logic [1:0]  mst_aw_user, mst_w_user, mst_b_user, mst_ar_user, mst_r_user;
  logic        mst_aw_valid, mst_aw_ready;
  logic [63:0] mst_w_data, mst_r_data;
  logic [7:0]  mst_w_strb;
  logic        mst_w_last, mst_w_valid, mst_w_ready;
  logic        mst_b_valid, mst_b_ready;
  logic        mst_ar_valid, mst_ar_ready;
  logic        mst_r_last, mst_r_valid, mst_r_ready;

  snitch_ro_cache_subsys dut (
    .clk_i           ( clk           ),
    .rst_ni          ( rst_n         ),
    .enable_i        ( enable        ),
    .flush_valid_i   ( flush_valid   ),
    .flush_ready_o   ( flush_ready   ),
    .start_addr_i    ( start_addr    ),
    .end_addr_i      ( end_addr      ),
    .slv_aw_id_i     ( slv_aw_id     ),
    .slv_aw_addr_i   ( slv_aw_addr   ),
    .slv_aw_len_i    ( slv_aw_len    ),
    .slv_aw_size_i   ( slv_aw_size   ),
    .slv_aw_burst_i  ( slv_aw_burst  ),
    .slv_aw_lock_i   ( slv_aw_lock   ),
    .slv_aw_cache_i  ( slv_aw_cache  ),
    .slv_aw_prot_i   ( slv_aw_prot   ),
    .slv_aw_qos_i    ( slv_aw_qos    ),
    .slv_aw_region_i ( slv_aw_region ),
    .slv_aw_atop_i   ( slv_aw_atop   ),
    .slv_aw_user_i   ( slv_aw_user   ),
    .slv_aw_valid_i  ( slv_aw_valid  ),
    .slv_aw_ready_o  ( slv_aw_ready  ),
    .slv_w_data_i    ( slv_w_data    ),
    .slv_w_strb_i    ( slv_w_strb    ),
    .slv_w_last_i    ( slv_w_last    ),
    .slv_w_user_i    ( slv_w_user    ),
    .slv_w_valid_i   ( slv_w_valid   ),
    .slv_w_ready_o   ( slv_w_ready   ),
    .slv_b_id_o      ( slv_b_id      ),
    .slv_b_resp_o    ( slv_b_resp    ),
    .slv_b_user_o    ( slv_b_user    ),
    .slv_b_valid_o   ( slv_b_valid   ),
    .slv_b_ready_i   ( slv_b_ready   ),
    .slv_ar_id_i     ( slv_ar_id     ),
    .slv_ar_addr_i   ( slv_ar_addr   ),
    .slv_ar_len_i    ( slv_ar_len    ),
    .slv_ar_size_i   ( slv_ar_size   ),
    .slv_ar_burst_i  ( slv_ar_burst  ),
    .slv_ar_lock_i   ( slv_ar_lock   ),
    .slv_ar_cache_i  ( slv_ar_cache  ),
    .slv_ar_prot_i   ( slv_ar_prot   ),
    .slv_ar_qos_i    ( slv_ar_qos    ),
    .slv_ar_region_i ( slv_ar_region ),
    .slv_ar_user_i   ( slv_ar_user   ),
    .slv_ar_valid_i  ( slv_ar_valid  ),
    .slv_ar_ready_o  ( slv_ar_ready  ),
    .slv_r_id_o      ( slv_r_id      ),
    .slv_r_data_o    ( slv_r_data    ),
    .slv_r_resp_o    ( slv_r_resp    ),
    .slv_r_last_o    ( slv_r_last    ),
    .slv_r_user_o    ( slv_r_user    ),
    .slv_r_valid_o   ( slv_r_valid   ),
    .slv_r_ready_i   ( slv_r_ready   ),
    .mst_aw_id_o     ( mst_aw_id     ),
    .mst_aw_addr_o   ( mst_aw_addr   ),
    .mst_aw_len_o    ( mst_aw_len    ),
    .mst_aw_size_o   ( mst_aw_size   ),
    .mst_aw_burst_o  ( mst_aw_burst  ),
    .mst_aw_lock_o   ( mst_aw_lock   ),
    .mst_aw_cache_o  ( mst_aw_cache  ),
    .mst_aw_prot_o   ( mst_aw_prot   ),
    .mst_aw_qos_o    ( mst_aw_qos    ),
    .mst_aw_region_o ( mst_aw_region ),
    .mst_aw_atop_o   ( mst_aw_atop   ),
    .mst_aw_user_o   ( mst_aw_user   ),
    .mst_aw_valid_o  ( mst_aw_valid  ),
    .mst_aw_ready_i  ( mst_aw_ready  ),
    .mst_w_data_o    ( mst_w_data    ),
    .mst_w_strb_o    ( mst_w_strb    ),
    .mst_w_last_o    ( mst_w_last    ),
    .mst_w_user_o    ( mst_w_user    ),
    .mst_w_valid_o   ( mst_w_valid   ),
    .mst_w_ready_i   ( mst_w_ready   ),
    .mst_b_id_i      ( mst_b_id      ),
    .mst_b_resp_i    ( mst_b_resp    ),
    .mst_b_user_i    ( mst_b_user    ),
    .mst_b_valid_i   ( mst_b_valid   ),
    .mst_b_ready_o   ( mst_b_ready   ),
    .mst_ar_id_o     ( mst_ar_id     ),
    .mst_ar_addr_o   ( mst_ar_addr   ),
    .mst_ar_len_o    ( mst_ar_len    ),
    .mst_ar_size_o   ( mst_ar_size   ),
    .mst_ar_burst_o  ( mst_ar_burst  ),
    .mst_ar_lock_o   ( mst_ar_lock   ),
    .mst_ar_cache_o  ( mst_ar_cache  ),
    .mst_ar_prot_o   ( mst_ar_prot   ),
    .mst_ar_qos_o    ( mst_ar_qos    ),
    .mst_ar_region_o ( mst_ar_region ),
    .mst_ar_user_o   ( mst_ar_user   ),
    .mst_ar_valid_o  ( mst_ar_valid  ),
    .mst_ar_ready_i  ( mst_ar_ready  ),
    .mst_r_id_i      ( mst_r_id      ),
    .mst_r_data_i    ( mst_r_data    ),
    .mst_r_resp_i    ( mst_r_resp    ),
    .mst_r_last_i    ( mst_r_last    ),
    .mst_r_user_i    ( mst_r_user    ),
    .mst_r_valid_i   ( mst_r_valid   ),
    .mst_r_ready_o   ( mst_r_ready   )
  );

  // Backing memory & AXI4 Slave Responder
  logic [63:0] mem [int unsigned];
  int unsigned mst_ar_count;
  int unsigned mst_r_delay_cycles;
  bit          inject_err_en;
  logic [31:0] inject_err_line;
  int unsigned inject_err_beat;
  logic [63:0] fifo_seq_val;

  function automatic logic [63:0] mem_read64(input logic [31:0] addr_aligned);
    logic [31:0] idx = addr_aligned >> 3;
    if (mem.exists(idx)) return mem[idx];
    return {idx ^ `TB_SEED, (idx * 32'h9E37_79B9) ^ 32'hA5A5_5A5A};
  endfunction

  task automatic mem_write64(input logic [31:0] addr_aligned, input logic [63:0] wdata, input logic [7:0] wstrb);
    logic [31:0] idx = addr_aligned >> 3;
    logic [63:0] cur = mem_read64(addr_aligned);
    for (int b = 0; b < 8; b++) begin
      if (wstrb[b]) cur[b*8 +: 8] = wdata[b*8 +: 8];
    end
    mem[idx] = cur;
  endtask

  typedef struct {
    logic [3:0]  id;
    logic [31:0] addr;
    logic [7:0]  len;
    logic [2:0]  size;
    logic [1:0]  burst;
    logic [1:0]  user;
    int unsigned delay_left;
  } ar_item_t;

  typedef struct {
    logic [3:0]  id;
    logic [31:0] addr;
    logic [7:0]  len;
    logic [2:0]  size;
    logic [1:0]  burst;
    logic [1:0]  user;
    int unsigned beat_idx;
  } aw_item_t;

  typedef struct {
    logic [63:0] data;
    logic [7:0]  strb;
    logic        last;
  } w_item_t;

  ar_item_t ar_q[$];
  aw_item_t aw_q[$];
  w_item_t  w_q[$];
  logic [3:0] b_q_id[$];
  logic [1:0] b_q_user[$];
  int unsigned cur_r_beat;
  bit cur_r_active;
  ar_item_t cur_r_req;
  assign mst_aw_ready = 1'b1;
  assign mst_w_ready  = 1'b1;
  assign mst_ar_ready = 1'b1;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      ar_q.delete();
      aw_q.delete();
      w_q.delete();
      b_q_id.delete();
      b_q_user.delete();
      cur_r_active <= 1'b0;
      cur_r_beat   <= 0;
      mst_ar_count <= 0;
      mst_r_valid  <= 1'b0;
      mst_b_valid  <= 1'b0;
    end else begin
      if (mst_ar_valid && mst_ar_ready) begin
        ar_item_t it;
        it.id         = mst_ar_id;
        it.addr       = mst_ar_addr;
        it.len        = mst_ar_len;
        it.size       = mst_ar_size;
        it.burst      = mst_ar_burst;
        it.user       = mst_ar_user;
        it.delay_left = mst_r_delay_cycles;
        ar_q.push_back(it);
        mst_ar_count <= mst_ar_count + 1;
      end

      if (mst_aw_valid && mst_aw_ready) begin
        aw_item_t wit;
        wit.id       = mst_aw_id;
        wit.addr     = mst_aw_addr;
        wit.len      = mst_aw_len;
        wit.size     = mst_aw_size;
        wit.burst    = mst_aw_burst;
        wit.user     = mst_aw_user;
        wit.beat_idx = 0;
        aw_q.push_back(wit);
      end

      if (mst_w_valid && mst_w_ready) begin
        w_item_t wb;
        wb.data = mst_w_data;
        wb.strb = mst_w_strb;
        wb.last = mst_w_last;
        w_q.push_back(wb);
      end

      while (aw_q.size() > 0 && w_q.size() > 0) begin
        w_item_t wb;
        logic [31:0] baddr;
        logic [31:0] step;
        wb   = w_q.pop_front();
        step = 32'd1 << aw_q[0].size;
        if (aw_q[0].burst == 2'b00) begin
          baddr = aw_q[0].addr;
        end else if (aw_q[0].burst == 2'b10) begin
          logic [31:0] wmask;
          wmask = ((32'(aw_q[0].len) + 32'd1) << aw_q[0].size) - 32'd1;
          baddr = (aw_q[0].addr & ~wmask) | ((aw_q[0].addr + aw_q[0].beat_idx * step) & wmask);
        end else begin
          baddr = aw_q[0].addr + aw_q[0].beat_idx * step;
        end
        mem_write64({baddr[31:3], 3'b000}, wb.data, wb.strb);
        if (wb.last) begin
          b_q_id.push_back(aw_q[0].id);
          b_q_user.push_back(aw_q[0].user);
          void'(aw_q.pop_front());
        end else begin
          aw_q[0].beat_idx++;
        end
      end

      if (mst_b_valid && mst_b_ready) begin
        mst_b_valid <= 1'b0;
      end
      if ((!mst_b_valid || mst_b_ready) && (b_q_id.size() > 0)) begin
        mst_b_valid <= 1'b1;
        mst_b_id    <= b_q_id.pop_front();
        mst_b_user  <= b_q_user.pop_front();
        mst_b_resp  <= 2'b00;
      end

      if (mst_r_valid && mst_r_ready) begin
        if (mst_r_last) begin
          mst_r_valid  <= 1'b0;
          cur_r_active <= 1'b0;
        end else begin
          int unsigned nb = cur_r_beat + 1;
          logic [31:0] step = 32'd1 << cur_r_req.size;
          logic [31:0] raddr;
          if (cur_r_req.burst == 2'b00) raddr = cur_r_req.addr;
          else if (cur_r_req.burst == 2'b10) begin
            logic [31:0] wmask = ((32'(cur_r_req.len) + 32'd1) << cur_r_req.size) - 32'd1;
            raddr = (cur_r_req.addr & ~wmask) | ((cur_r_req.addr + nb * step) & wmask);
          end else raddr = cur_r_req.addr + nb * step;

          cur_r_beat <= nb;
          mst_r_id   <= cur_r_req.id;
          mst_r_user <= cur_r_req.user;
          mst_r_last <= (nb == int'(cur_r_req.len));
          if (cur_r_req.burst == 2'b00 && cur_r_req.addr == 32'h1000_0400) begin
            mst_r_data   <= fifo_seq_val;
            fifo_seq_val <= fifo_seq_val + 64'h0101_0101_0000_0001;
          end else begin
            mst_r_data <= mem_read64({raddr[31:3], 3'b000});
          end
          if (inject_err_en && ({cur_r_req.addr[31:5], 5'b0} == inject_err_line) && (nb == inject_err_beat))
            mst_r_resp <= 2'b10;
          else
            mst_r_resp <= 2'b00;
        end
      end

      if (!cur_r_active && (!mst_r_valid || (mst_r_ready && mst_r_last)) && (ar_q.size() > 0)) begin
        if (ar_q[0].delay_left > 0) begin
          ar_q[0].delay_left--;
        end else begin
          ar_item_t req = ar_q.pop_front();
          cur_r_req    <= req;
          cur_r_active <= 1'b1;
          cur_r_beat   <= 0;
          mst_r_valid  <= 1'b1;
          mst_r_id     <= req.id;
          mst_r_user   <= req.user;
          mst_r_last   <= (req.len == 8'd0);
          if (req.burst == 2'b00 && req.addr == 32'h1000_0400) begin
            mst_r_data   <= fifo_seq_val;
            fifo_seq_val <= fifo_seq_val + 64'h0101_0101_0000_0001;
          end else begin
            mst_r_data <= mem_read64({req.addr[31:3], 3'b000});
          end
          if (inject_err_en && ({req.addr[31:5], 5'b0} == inject_err_line) && (inject_err_beat == 0))
            mst_r_resp <= 2'b10;
          else
            mst_r_resp <= 2'b00;
        end
      end
    end
  end

  // AXI4 Slave R stability monitor
  logic        prev_r_stall;
  logic [2:0]  prev_r_id;
  logic [63:0] prev_r_data;
  logic [1:0]  prev_r_resp;
  logic        prev_r_last;

  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      prev_r_stall <= 1'b0;
    end else begin
      if (prev_r_stall) begin
        if (!slv_r_valid || slv_r_id !== prev_r_id || slv_r_data !== prev_r_data ||
            slv_r_resp !== prev_r_resp || slv_r_last !== prev_r_last) begin
          $display("TEST_FAIL: AXI R channel violated stability under r_ready=0 stall");
          $finish;
        end
      end
      prev_r_stall <= slv_r_valid && !slv_r_ready;
      prev_r_id    <= slv_r_id;
      prev_r_data  <= slv_r_data;
      prev_r_resp  <= slv_r_resp;
      prev_r_last  <= slv_r_last;
    end
  end
  task automatic fail_msg(input string s);
    $display("TEST_FAIL: %s", s);
    $finish;
  endtask

  task automatic issue_ar(
    input logic [2:0]  id,
    input logic [31:0] addr,
    input logic [7:0]  len,
    input logic [2:0]  size,
    input logic [1:0]  burst,
    input logic        lock_bit = 1'b0,
    input logic [1:0]  user_bits = 2'b01
  );
    int guard = 0;
    slv_ar_id     = id;
    slv_ar_addr   = addr;
    slv_ar_len    = len;
    slv_ar_size   = size;
    slv_ar_burst  = burst;
    slv_ar_lock   = lock_bit;
    slv_ar_cache  = 4'h2;
    slv_ar_prot   = 3'h0;
    slv_ar_qos    = 4'h0;
    slv_ar_region = 4'h0;
    slv_ar_user   = user_bits;
    slv_ar_valid  = 1'b1;
    do begin
      @(posedge clk);
      guard++;
      if (guard > 4000) fail_msg("Timeout waiting for slv_ar_ready");
    end while (!slv_ar_ready);
    #1;
    slv_ar_valid = 1'b0;
  endtask

  task automatic do_read_burst(
    input  logic [2:0]  id,
    input  logic [31:0] addr,
    input  logic [7:0]  len,
    input  logic [2:0]  size,
    input  logic [1:0]  burst,
    input  logic        lock_bit,
    input  int unsigned stall_cycles,
    input  logic [1:0]  exp_resp,
    output logic [63:0] rbuf [0:15]
  );
    int beats = int'(len) + 1;
    int got   = 0;
    int guard = 0;
    slv_r_ready = 1'b0;
    issue_ar(id, addr, len, size, burst, lock_bit, 2'b10);
    while (got < beats) begin
      for (int s = 0; s < stall_cycles; s++) begin
        slv_r_ready = 1'b0;
        @(posedge clk);
        #1;
      end
      slv_r_ready = 1'b1;
      do begin
        @(posedge clk);
        guard++;
        if (guard > 6000) fail_msg("Timeout waiting for slv_r_valid");
      end while (!slv_r_valid);
      if (slv_r_id !== id) fail_msg($sformatf("R ID mismatch: got %0d exp %0d", slv_r_id, id));
      if (slv_r_resp !== exp_resp) fail_msg($sformatf("R RESP mismatch on beat %0d: got %b exp %b", got, slv_r_resp, exp_resp));
      if (slv_r_last !== (got == beats - 1)) fail_msg($sformatf("R LAST mismatch on beat %0d/%0d", got, beats));
      rbuf[got] = slv_r_data;
      got++;
      #1;
    end
    slv_r_ready = 1'b0;
  endtask

  task automatic do_write_burst(
    input logic [2:0]  id,
    input logic [31:0] addr,
    input logic [7:0]  len,
    input logic [2:0]  size,
    input logic [1:0]  burst,
    input logic [63:0] base_val,
    input logic [7:0]  strb_mask
  );
    int beats = int'(len) + 1;
    int guard = 0;
    slv_aw_id     = id;
    slv_aw_addr   = addr;
    slv_aw_len    = len;
    slv_aw_size   = size;
    slv_aw_burst  = burst;
    slv_aw_lock   = 1'b0;
    slv_aw_cache  = 4'h2;
    slv_aw_prot   = 3'h0;
    slv_aw_qos    = 4'h0;
    slv_aw_region = 4'h0;
    slv_aw_atop   = 6'h0;
    slv_aw_user   = 2'b01;
    slv_aw_valid  = 1'b1;
    do begin
      @(posedge clk);
      guard++;
      if (guard > 4000) fail_msg("Timeout waiting for slv_aw_ready");
    end while (!slv_aw_ready);
    #1;
    slv_aw_valid = 1'b0;

    for (int b = 0; b < beats; b++) begin
      slv_w_data  = base_val + (64'(b) * 64'h1111_2222_3333_4444);
      slv_w_strb  = strb_mask;
      slv_w_last  = (b == beats - 1);
      slv_w_user  = 2'b01;
      slv_w_valid = 1'b1;
      guard = 0;
      do begin
        @(posedge clk);
        guard++;
        if (guard > 4000) fail_msg("Timeout waiting for slv_w_ready");
      end while (!slv_w_ready);
      #1;
    end
    slv_w_valid = 1'b0;
    slv_w_last  = 1'b0;

    slv_b_ready = 1'b1;
    guard = 0;
    do begin
      @(posedge clk);
      guard++;
      if (guard > 4000) fail_msg("Timeout waiting for slv_b_valid");
    end while (!slv_b_valid);
    if (slv_b_id !== id || slv_b_resp !== 2'b00) fail_msg("Write B response mismatch");
    #1;
    slv_b_ready = 1'b0;
  endtask
  initial begin
    logic [63:0] rbuf [0:15];
    int unsigned ar_before;
    int guard;
    int got_id1, got_id5, got_id2a, got_id2b;

    rst_n              = 1'b0;
    enable             = 1'b1;
    flush_valid        = 1'b0;
    start_addr[0]      = 32'h1000_0000;
    end_addr[0]        = 32'h1000_2000;
    start_addr[1]      = 32'h1001_0000;
    end_addr[1]        = 32'h1001_1000;
    slv_aw_valid       = 1'b0;
    slv_w_valid        = 1'b0;
    slv_b_ready        = 1'b0;
    slv_ar_valid       = 1'b0;
    slv_r_ready        = 1'b0;
    mst_r_delay_cycles = 0;
    inject_err_en      = 1'b0;
    inject_err_line    = '0;
    inject_err_beat    = 0;
    fifo_seq_val       = 64'hF1F0_0000_0000_0010 ^ {32'h0, `TB_SEED};

    repeat (6) @(posedge clk);
    #1 rst_n = 1'b1;

    // 1. Cross-line unaligned 6-beat INCR burst + warm hit verification
    ar_before = mst_ar_count;
    do_read_burst(3'd1, 32'h1000_0018, 8'd5, 3'd3, 2'b01, 1'b0, 1, 2'b00, rbuf);
    for (int i = 0; i < 6; i++) begin
      if (rbuf[i] !== mem_read64(32'h1000_0018 + i * 8))
        fail_msg($sformatf("Phase 1 data mismatch at beat %0d", i));
    end
    if (mst_ar_count != ar_before + 3)
      fail_msg($sformatf("Phase 1 expected 3 cache line refills, got %0d", mst_ar_count - ar_before));

    ar_before = mst_ar_count;
    do_read_burst(3'd2, 32'h1000_0018, 8'd5, 3'd3, 2'b01, 1'b0, 2, 2'b00, rbuf);
    for (int i = 0; i < 6; i++) begin
      if (rbuf[i] !== mem_read64(32'h1000_0018 + i * 8))
        fail_msg("Phase 1 warm hit data mismatch");
    end
    if (mst_ar_count != ar_before)
      fail_msg("Phase 1 warm read missed unexpectedly");

    // 2. Multi-ID MSHR coalescing + back-to-back same-ID under multi-cycle r_ready=0 stalls
    mst_r_delay_cycles = 6;
    slv_r_ready        = 1'b0;
    issue_ar(3'd1, 32'h1000_0208, 8'd2, 3'd3, 2'b01); // 3 beats on line 0x200 (offsets 1..3)
    issue_ar(3'd5, 32'h1000_0210, 8'd0, 3'd3, 2'b01); // coalesced onto same MSHR line 0x200!
    issue_ar(3'd2, 32'h1000_0020, 8'd0, 3'd3, 2'b01); // warm hit #1 on id=2
    issue_ar(3'd2, 32'h1000_0040, 8'd0, 3'd3, 2'b01); // warm hit #2 on SAME id=2!

    got_id1 = 0; got_id5 = 0; got_id2a = 0; got_id2b = 0;
    guard   = 0;
    while ((got_id1 < 3) || (got_id5 < 1) || (got_id2a < 1) || (got_id2b < 1)) begin
      repeat (3) begin
        slv_r_ready = 1'b0;
        @(posedge clk);
        #1;
      end
      slv_r_ready = 1'b1;
      do begin
        @(posedge clk);
        guard++;
        if (guard > 8000) fail_msg("Phase 2 timeout collecting coalesced/stalled beats");
      end while (!slv_r_valid);
      if (slv_r_resp !== 2'b00) fail_msg("Phase 2 unexpected error resp");
      case (slv_r_id)
        3'd1: begin
          if (slv_r_data !== mem_read64(32'h1000_0208 + got_id1 * 8)) fail_msg("Phase 2 id=1 data mismatch");
          if (slv_r_last !== (got_id1 == 2)) fail_msg("Phase 2 id=1 last mismatch");
          got_id1++;
        end
        3'd5: begin
          if (slv_r_data !== mem_read64(32'h1000_0210) || !slv_r_last) fail_msg("Phase 2 id=5 mismatch");
          got_id5++;
        end
        3'd2: begin
          if (!slv_r_last) fail_msg("Phase 2 id=2 last mismatch");
          if (got_id2a == 0) begin
            if (slv_r_data !== mem_read64(32'h1000_0020)) fail_msg("Phase 2 id=2 first hit mismatch");
            got_id2a = 1;
          end else begin
            if (slv_r_data !== mem_read64(32'h1000_0040)) fail_msg("Phase 2 id=2 second hit mismatch");
            got_id2b = 1;
          end
        end
        default: fail_msg("Phase 2 unexpected R ID");
      endcase
      #1;
    end
    slv_r_ready        = 1'b0;
    mst_r_delay_cycles = 0;

    // 3. Non-cacheable burst shapes: BURST_FIXED FIFO, BURST_WRAP, narrow multi-beat, lock, boundary-crossing
    begin
      logic [63:0] exp_f0 = fifo_seq_val;
      do_read_burst(3'd3, 32'h1000_0400, 8'd3, 3'd3, 2'b00, 1'b0, 1, 2'b00, rbuf);
      for (int b = 0; b < 4; b++) begin
        if (rbuf[b] !== (exp_f0 + b * 64'h0101_0101_0000_0001))
          fail_msg("Phase 3 BURST_FIXED failed to bypass cache onto streaming FIFO");
      end
      exp_f0 = fifo_seq_val;
      do_read_burst(3'd3, 32'h1000_0400, 8'd3, 3'd3, 2'b00, 1'b0, 0, 2'b00, rbuf);
      for (int b = 0; b < 4; b++) begin
        if (rbuf[b] !== (exp_f0 + b * 64'h0101_0101_0000_0001))
          fail_msg("Phase 3 second BURST_FIXED returned cached data instead of live FIFO stream");
      end
    end

    do_read_burst(3'd4, 32'h1000_0318, 8'd3, 3'd3, 2'b10, 1'b0, 0, 2'b00, rbuf);
    if (rbuf[0] !== mem_read64(32'h1000_0318) || rbuf[1] !== mem_read64(32'h1000_0300))
      fail_msg("Phase 3 BURST_WRAP data mismatch");

    do_read_burst(3'd6, 32'h1000_0340, 8'd1, 3'd2, 2'b01, 1'b0, 1, 2'b00, rbuf);
    do_read_burst(3'd0, 32'h1000_0360, 8'd0, 3'd3, 2'b01, 1'b1, 0, 2'b00, rbuf);

    // Disabled cache (enable=0) must bypass warm cached line 0x1000_0020 without hitting or allocating
    enable = 1'b0;
    begin
      logic [63:0] saved_m = mem[32'h1000_0020 >> 3];
      mem[32'h1000_0020 >> 3] = 64'hE0AB_1E00_DEAD_C0DE;
      do_read_burst(3'd2, 32'h1000_0020, 8'd0, 3'd3, 2'b01, 1'b0, 0, 2'b00, rbuf);
      if (rbuf[0] !== 64'hE0AB_1E00_DEAD_C0DE)
        fail_msg("Phase 3 enable=0 read failed to bypass warm cache line");
      mem[32'h1000_0020 >> 3] = saved_m;
    end
    enable = 1'b1;

    // Boundary-crossing INCR read [0x1000_1FE8 .. 0x1000_2007] must bypass and NOT cache 0x1000_1FE0
    do_read_burst(3'd1, 32'h1000_1FE8, 8'd3, 3'd3, 2'b01, 1'b0, 0, 2'b00, rbuf);
    mem[32'h1000_1FE8 >> 3] = 64'hCAFE_BABE_1234_5678;
    do_read_burst(3'd1, 32'h1000_1FE8, 8'd0, 3'd3, 2'b01, 1'b0, 0, 2'b00, rbuf);
    if (rbuf[0] !== 64'hCAFE_BABE_1234_5678)
      fail_msg("Phase 3 boundary-crossing burst polluted cache");

    // 4. Multi-beat refill error on non-last beat (beat 0..2) -> RESP_SLVERR & non-allocation
    inject_err_en   = 1'b1;
    inject_err_line = 32'h1001_0080;
    inject_err_beat = (`TB_SEED % 3); // beat 0, 1, or 2 (non-last!)
    do_read_burst(3'd7, 32'h1001_0088, 8'd1, 3'd3, 2'b01, 1'b0, 1, 2'b10, rbuf);

    inject_err_en = 1'b0;
    ar_before     = mst_ar_count;
    do_read_burst(3'd7, 32'h1001_0088, 8'd1, 3'd3, 2'b01, 1'b0, 0, 2'b00, rbuf);
    if (mst_ar_count == ar_before || rbuf[0] !== mem_read64(32'h1001_0088))
      fail_msg("Phase 4 errored refill was cached instead of re-fetching cleanly");

    // 5. Write-through invalidation + warm preservation on unrelated/MMIO writes + in-flight R/W race
    do_read_burst(3'd1, 32'h1000_0100, 8'd7, 3'd3, 2'b01, 1'b0, 0, 2'b00, rbuf); // caches 0x100 & 0x120
    do_read_burst(3'd1, 32'h1000_0600, 8'd0, 3'd3, 2'b01, 1'b0, 0, 2'b00, rbuf); // caches 0x600

    // MMIO write outside cacheable rules (aliasing set index of 0x100) must NOT evict 0x100
    do_write_burst(3'd2, 32'h2000_0100, 8'd0, 3'd3, 2'b01, 64'hDEAD_0000_0000_BEEF, 8'hFF);
    ar_before = mst_ar_count;
    do_read_burst(3'd1, 32'h1000_0100, 8'd0, 3'd3, 2'b01, 1'b0, 0, 2'b00, rbuf);
    if (mst_ar_count != ar_before) fail_msg("Phase 5 non-cacheable MMIO write needlessly evicted cached line");

    // Multi-line write spanning 0x1000_0118 .. 0x1000_012F invalidates BOTH 0x100 and 0x120, keeping 0x600 warm
    do_write_burst(3'd3, 32'h1000_0118, 8'd2, 3'd3, 2'b01, 64'h55AA_1122_3344_7788, 8'hFF);
    ar_before = mst_ar_count;
    do_read_burst(3'd1, 32'h1000_0600, 8'd0, 3'd3, 2'b01, 1'b0, 0, 2'b00, rbuf);
    if (mst_ar_count != ar_before) fail_msg("Phase 5 targeted write evicted unrelated cached set 0x600");

    do_read_burst(3'd1, 32'h1000_0118, 8'd2, 3'd3, 2'b01, 1'b0, 1, 2'b00, rbuf);
    for (int i = 0; i < 3; i++) begin
      if (rbuf[i] !== mem_read64(32'h1000_0118 + i * 8))
        fail_msg("Phase 5 stale cache data returned after multi-line AXI write");
    end

    // In-flight miss refill raced by concurrent AXI write to same line
    mst_r_delay_cycles = 8;
    slv_r_ready        = 1'b1;
    issue_ar(3'd4, 32'h1000_0700, 8'd0, 3'd3, 2'b01);
    fork
      begin
        do_write_burst(3'd5, 32'h1000_0700, 8'd0, 3'd3, 2'b01, 64'hFACE_B00C_9988_7766, 8'hFF);
      end
      begin
        int rg;
        rg = 0;
        do begin
          @(posedge clk);
          rg = rg + 1;
          if (rg > 4000) fail_msg("Phase 5 timeout on concurrent R/W miss");
        end while (!slv_r_valid);
        #1;
        slv_r_ready = 1'b0;
      end
    join
    mst_r_delay_cycles = 0;
    do_read_burst(3'd4, 32'h1000_0700, 8'd0, 3'd3, 2'b01, 1'b0, 0, 2'b00, rbuf);
    if (rbuf[0] !== 64'hFACE_B00C_9988_7766)
      fail_msg("Phase 5 pre-write in-flight refill poisoned cache over concurrent write");

    // 6. Flush handshake while miss refill is in flight
    mst_r_delay_cycles = 10;
    slv_r_ready        = 1'b1;
    issue_ar(3'd6, 32'h1000_0800, 8'd0, 3'd3, 2'b01);
    @(posedge clk); #1;
    flush_valid = 1'b1;
    fork
      begin
        int g = 0;
        while (!slv_r_valid) begin @(posedge clk); g = g + 1; if (g > 4000) fail_msg("Phase 6 R timeout"); end
        @(posedge clk); #1; slv_r_ready = 1'b0;
      end
      begin
        int g = 0;
        do begin @(posedge clk); g = g + 1; if (g > 4000) fail_msg("Phase 6 flush_ready timeout"); end while (!flush_ready);
        #1; flush_valid = 1'b0;
      end
    join
    mst_r_delay_cycles = 0;
    mem[32'h1000_0800 >> 3] = 64'h7777_8888_9999_AAAA;
    mem[32'h1000_0600 >> 3] = 64'hBBBB_CCCC_DDDD_EEEE;
    do_read_burst(3'd1, 32'h1000_0800, 8'd0, 3'd3, 2'b01, 1'b0, 0, 2'b00, rbuf);
    if (rbuf[0] !== 64'h7777_8888_9999_AAAA) fail_msg("Phase 6 pre-flush in-flight refill survived flush");
    do_read_burst(3'd1, 32'h1000_0600, 8'd0, 3'd3, 2'b01, 1'b0, 0, 2'b00, rbuf);
    if (rbuf[0] !== 64'hBBBB_CCCC_DDDD_EEEE) fail_msg("Phase 6 pre-flush cached line survived flush");

    $display("TEST_PASS");
    $finish;
  end

endmodule
