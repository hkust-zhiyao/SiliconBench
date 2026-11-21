  task automatic axi_write_gen(
    input logic [3:0]  id,
    input logic [31:0] addr,
    input logic [7:0]  len,
    input logic [2:0]  size,
    input logic [1:0]  burst,
    input logic [3:0]  cache_attr,
    input logic [63:0] wdata_arr [0:15],
    input logic [7:0]  wstrb_arr [0:15],
    input bit          inject_x_unstrobed,
    output logic [1:0] bresp_out
  );
    int cyc_aw, cyc_w, cyc_b;
    bit aw_done, w_done, b_done;
    @(posedge clk_i); #1;
    slv_b_ready = 1'b1;
    fork
      begin
        slv_aw_id = id; slv_aw_addr = addr; slv_aw_len = len;
        slv_aw_size = size; slv_aw_burst = burst; slv_aw_lock = 1'b0;
        slv_aw_cache = cache_attr; slv_aw_prot = 3'b000; slv_aw_valid = 1'b1;
        cyc_aw = 0; aw_done = 1'b0;
        while (!aw_done) begin
          @(negedge clk_i); #4;
          aw_done = (slv_aw_ready === 1'b1);
          @(posedge clk_i); #1;
          cyc_aw++; if (cyc_aw > 5000) $fatal(1, "Timeout on AW");
        end
        slv_aw_valid = 1'b0;
      end
      begin
        for (int i = 0; i <= int'(len); i++) begin
          logic [63:0] wd;
          wd = wdata_arr[i];
          if (inject_x_unstrobed) begin
            for (int b = 0; b < 8; b++) begin
              if (!wstrb_arr[i][b]) wd[b*8 +: 8] = 8'hxx;
            end
          end
          slv_w_data  = wd;
          slv_w_strb  = wstrb_arr[i];
          slv_w_last  = (i == int'(len));
          slv_w_valid = 1'b1;
          cyc_w = 0; w_done = 1'b0;
          while (!w_done) begin
            @(negedge clk_i); #4;
            w_done = (slv_w_ready === 1'b1);
            @(posedge clk_i); #1;
            cyc_w++; if (cyc_w > 5000) $fatal(1, "Timeout on W beat %0d", i);
          end
          slv_w_valid = 1'b0; slv_w_last = 1'b0; slv_w_data = 64'd0; slv_w_strb = 8'h00;
        end
      end
    join
    cyc_b = 0; b_done = 1'b0;
    while (!b_done) begin
      @(negedge clk_i); #4;
      if (slv_b_valid === 1'b1) begin
        b_done = 1'b1;
        if (slv_b_id !== id) $fatal(1, "BID mismatch got=%0h exp=%0h", slv_b_id, id);
        bresp_out = slv_b_resp;
      end
      @(posedge clk_i); #1;
      cyc_b++; if (cyc_b > 5000) $fatal(1, "Timeout on B");
    end
    slv_b_ready = 1'b0;
  endtask

  task automatic axi_read_gen(
    input logic [3:0]   id,
    input logic [31:0]  addr,
    input logic [7:0]   len,
    input logic [2:0]   size,
    input logic [1:0]   burst,
    input logic [3:0]   cache_attr,
    input bit           backpressure,
    output logic [63:0] rdata_arr [0:15],
    output logic [1:0]  rresp_out
  );
    int cyc_ar, cyc_r;
    bit ar_done, r_done;
    @(posedge clk_i); #1;
    slv_ar_id = id; slv_ar_addr = addr; slv_ar_len = len;
    slv_ar_size = size; slv_ar_burst = burst; slv_ar_lock = 1'b0;
    slv_ar_cache = cache_attr; slv_ar_prot = 3'b000; slv_ar_valid = 1'b1;
    cyc_ar = 0; ar_done = 1'b0;
    while (!ar_done) begin
      @(negedge clk_i); #4;
      ar_done = (slv_ar_ready === 1'b1);
      @(posedge clk_i); #1;
      cyc_ar++; if (cyc_ar > 5000) $fatal(1, "Timeout on AR");
    end
    slv_ar_valid = 1'b0;

    for (int i = 0; i <= int'(len); i++) begin
      if (backpressure && (i[0] == 1'b1)) begin
        slv_r_ready = 1'b0;
        repeat (3) @(posedge clk_i);
        #1;
      end
      slv_r_ready = 1'b1;
      cyc_r = 0; r_done = 1'b0;
      while (!r_done) begin
        @(negedge clk_i); #4;
        if (slv_r_valid === 1'b1) begin
          r_done = 1'b1;
          if (slv_r_id !== id) $fatal(1, "RID mismatch got=%0h exp=%0h", slv_r_id, id);
          if (slv_r_last !== (i == int'(len))) $fatal(1, "RLAST mismatch beat=%0d", i);
          if ((^slv_r_data) === 1'bx) $fatal(1, "4-state X detected on slv_r_data beat=%0d: %h", i, slv_r_data);
          rdata_arr[i] = slv_r_data;
          rresp_out    = slv_r_resp;
        end
        @(posedge clk_i); #1;
        cyc_r++; if (cyc_r > 5000) $fatal(1, "Timeout on R beat %0d", i);
      end
    end
    slv_r_ready = 1'b0;
  endtask

  task automatic fill_seq_64(
    input logic [63:0] base_v,
    input logic [7:0]  strb_v,
    output logic [63:0] wd [0:15],
    output logic [7:0]  ws [0:15]
  );
    for (int k = 0; k < 16; k++) begin
      wd[k] = base_v + {32'd0, k[31:0]} * 64'h0101_0101_0101_0101;
      ws[k] = strb_v;
    end
  endtask

  initial begin
    logic [63:0] rbuf [0:15], wbuf [0:15];
    logic [7:0]  sbuf [0:15];
    logic [1:0]  resp;
    int unsigned ar_before, aw_before, wait_c;
    if (!$value$plusargs("SEED=%d", seed_v)) seed_v = 101;

    slv_aw_id = '0; slv_aw_addr = '0; slv_aw_len = '0; slv_aw_size = '0;
    slv_aw_burst = '0; slv_aw_lock = 1'b0; slv_aw_cache = '0; slv_aw_prot = '0; slv_aw_valid = 1'b0;
    slv_w_data = '0; slv_w_strb = '0; slv_w_last = 1'b0; slv_w_valid = 1'b0; slv_b_ready = 1'b0;
    slv_ar_id = '0; slv_ar_addr = '0; slv_ar_len = '0; slv_ar_size = '0;
    slv_ar_burst = '0; slv_ar_lock = 1'b0; slv_ar_cache = '0; slv_ar_prot = '0; slv_ar_valid = 1'b0;
    slv_r_ready = 1'b0; cfg_spm = '0; cfg_flush = '0; commit_cfg = 1'b0;

    for (int k = 0; k < 32768; k++)
      mem_cached[k] = {32'(32'hC0DE_0000 ^ seed_v ^ k), 32'(32'h5A5A_0000 + k)};
    for (int k = 0; k < 8192; k++)
      mem_uncached[k] = {32'(32'hD100_0000 ^ k), 32'(32'h1234_0000 + k)};

    rst_ni = 1'b0;
    repeat (8) @(posedge clk_i);
    rst_ni = 1'b1;

    // 1. Wait for 4-way BIST initialization
    wait_c = 0;
    while (!bist_done) begin
      @(posedge clk_i); wait_c++;
      if (wait_c > 8000) $fatal(1, "Timeout waiting for BIST done");
    end
    if (bist_out !== 4'b0000) $fatal(1, "BIST reported failure: %b", bist_out);

    // 2. Critical-Word-First 64-bit BURST_WRAP cold read miss + read hit + WRAP write
    ar_before = mst_ar_cnt;
    axi_read_gen(4'h1, 32'h8000_0118, 8'd3, 3'd3, 2'b10, 4'b1111, 1'b1, rbuf, resp);
    if (resp !== 2'b00) $fatal(1, "CWF WRAP read miss resp=%b", resp);
    if (mst_ar_cnt != ar_before + 1) $fatal(1, "CWF WRAP read split across lines: delta_ar=%0d", mst_ar_cnt - ar_before);
    if (rbuf[0] !== mem_cached[mem_idx_c(32'h8000_0118)] ||
        rbuf[1] !== mem_cached[mem_idx_c(32'h8000_0100)] ||
        rbuf[2] !== mem_cached[mem_idx_c(32'h8000_0108)] ||
        rbuf[3] !== mem_cached[mem_idx_c(32'h8000_0110)])
      $fatal(1, "CWF WRAP read data order mismatch: %h %h %h %h", rbuf[0], rbuf[1], rbuf[2], rbuf[3]);

    fill_seq_64(64'hA1B2_C3D4_0000_1100, 8'hFF, wbuf, sbuf);
    axi_write_gen(4'h2, 32'h8000_0110, 8'd3, 3'd3, 2'b10, 4'b1111, wbuf, sbuf, 1'b0, resp);
    if (resp !== 2'b00) $fatal(1, "WRAP write resp=%b", resp);
    ar_before = mst_ar_cnt;
    axi_read_gen(4'h3, 32'h8000_0100, 8'd3, 3'd3, 2'b01, 4'b1111, 1'b1, rbuf, resp);
    if (mst_ar_cnt != ar_before) $fatal(1, "Unexpected AR on hit");
    if (rbuf[0] !== wbuf[2] || rbuf[1] !== wbuf[3] || rbuf[2] !== wbuf[0] || rbuf[3] !== wbuf[1])
      $fatal(1, "WRAP write -> INCR read mismatch: %h %h %h %h", rbuf[0], rbuf[1], rbuf[2], rbuf[3]);

    // 3. Sub-line narrow 32-bit BURST_WRAP (size=2, len=3 => 16B wrap 0x21C->0x210->0x214->0x218) + BURST_FIXED
    fill_seq_64(64'h0, 8'h00, wbuf, sbuf);
    wbuf[0] = 64'h1111_2222_0000_0000; sbuf[0] = 8'hF0;
    wbuf[1] = 64'h0000_0000_3333_4444; sbuf[1] = 8'h0F;
    wbuf[2] = 64'h5555_6666_0000_0000; sbuf[2] = 8'hF0;
    wbuf[3] = 64'h0000_0000_7777_8888; sbuf[3] = 8'h0F;
    axi_write_gen(4'h4, 32'h8000_021C, 8'd3, 3'd2, 2'b10, 4'b1111, wbuf, sbuf, 1'b1, resp);
    axi_read_gen(4'h5, 32'h8000_0218, 8'd3, 3'd2, 2'b10, 4'b1111, 1'b1, rbuf, resp);
    if (rbuf[0][31:0] !== 32'h7777_8888 || rbuf[1][63:32] !== 32'h1111_2222 ||
        rbuf[2][31:0] !== 32'h3333_4444 || rbuf[3][63:32] !== 32'h5555_6666)
      $fatal(1, "Narrow 32b WRAP mismatch: %h %h %h %h", rbuf[0], rbuf[1], rbuf[2], rbuf[3]);

    fill_seq_64(64'hFACE_0000_0000_CAFE, 8'hFF, wbuf, sbuf);
    axi_write_gen(4'h6, 32'h8000_0208, 8'd2, 3'd3, 2'b00, 4'b1111, wbuf, sbuf, 1'b0, resp);
    axi_read_gen(4'h7, 32'h8000_0208, 8'd1, 3'd3, 2'b00, 4'b1111, 1'b0, rbuf, resp);
    if (rbuf[0] !== wbuf[2] || rbuf[1] !== wbuf[2]) $fatal(1, "FIXED burst mismatch: %h %h", rbuf[0], rbuf[1]);

    // 4. 4-way set fill + 5th-tag dirty eviction + partial-strobe X hygiene + cross-line 8-beat INCR
    for (int w = 0; w < 4; w++) begin
      fill_seq_64(64'h9000_0000_0000_0000 + {32'd0, w[31:0]} * 64'h0010_0000_0010_0000, 8'hFF, wbuf, sbuf);
      axi_write_gen(4'(w), 32'h8000_0300 + w * 32'h0000_0800, 8'd3, 3'd3, 2'b01, 4'b1111, wbuf, sbuf, 1'b0, resp);
    end
    fill_seq_64(64'hDEAD_0000_0000_BEEF, 8'b1100_0011, wbuf, sbuf);
    axi_write_gen(4'h8, 32'h8000_0300, 8'd0, 3'd3, 2'b01, 4'b1111, wbuf, sbuf, 1'b1, resp);
    aw_before = mst_aw_cnt;
    fill_seq_64(64'hEEEE_FFFF_1234_5678, 8'hFF, wbuf, sbuf);
    axi_write_gen(4'h9, 32'h8000_2300, 8'd3, 3'd3, 2'b01, 4'b1111, wbuf, sbuf, 1'b0, resp);
    if (mst_aw_cnt <= aw_before) $fatal(1, "Expected dirty eviction AW on 5th tag in 4-way set");
    axi_read_gen(4'hA, 32'h8000_0300, 8'd0, 3'd3, 2'b01, 4'b1111, 1'b0, rbuf, resp);
    if (rbuf[0] !== 64'hDEAD_0000_0000_BEEF) $fatal(1, "4-way partial-strobe/evict readback mismatch: %h", rbuf[0]);

    fill_seq_64(64'h4444_5555_6666_7700, 8'hFF, wbuf, sbuf);
    axi_write_gen(4'hB, 32'h8000_03E0, 8'd7, 3'd3, 2'b01, 4'b1111, wbuf, sbuf, 1'b0, resp);
    axi_read_gen(4'hC, 32'h8000_03E0, 8'd7, 3'd3, 2'b01, 4'b1111, 1'b1, rbuf, resp);
    if (rbuf[0] !== wbuf[0] || rbuf[6] !== wbuf[6]) $fatal(1, "Cross-line INCR mismatch");

    // 5. Uncached bypass + Dynamic 2-way SPM (cfg_spm=4'b0011) + boundary WRAP + non-SPM way SLVERR
    fill_seq_64(64'h5566_7788_AABB_CCDD, 8'hF0, wbuf, sbuf);
    axi_write_gen(4'hD, 32'h2000_0040, 8'd1, 3'd3, 2'b01, 4'b0000, wbuf, sbuf, 1'b1, resp);
    axi_read_gen(4'hE, 32'h2000_0040, 8'd1, 3'd3, 2'b01, 4'b0000, 1'b0, rbuf, resp);
    if (rbuf[0][63:32] !== 32'h5566_7788) $fatal(1, "Bypass mismatch: %h", rbuf[0]);

    @(posedge clk_i); #1;
    cfg_spm = 4'b0011; cfg_flush = 4'b0000; commit_cfg = 1'b1;
    @(posedge clk_i); #1;
    commit_cfg = 1'b0;
    wait_c = 0;
    while (flushed !== 4'b0011) begin
      @(posedge clk_i); wait_c++;
      if (wait_c > 8000) $fatal(1, "Timeout waiting for 2-way SPM flush");
    end
    ar_before = mst_ar_cnt; aw_before = mst_aw_cnt;
    fill_seq_64(64'hF00D_CAFE_0000_2200, 8'hFF, wbuf, sbuf);
    axi_write_gen(4'h1, 32'h1000_07F8, 8'd3, 3'd3, 2'b10, 4'b0011, wbuf, sbuf, 1'b0, resp);
    if (resp !== 2'b00) $fatal(1, "SPM Way-0 boundary WRAP write failed: resp=%b", resp);
    axi_read_gen(4'h2, 32'h1000_07E0, 8'd3, 3'd3, 2'b01, 4'b0011, 1'b1, rbuf, resp);
    if (rbuf[0] !== wbuf[1] || rbuf[3] !== wbuf[0]) $fatal(1, "SPM boundary WRAP readback mismatch");
    if (mst_ar_cnt != ar_before || mst_aw_cnt != aw_before) $fatal(1, "SPM generated master traffic");

    // Populate cached set 0 across the two remaining cache ways (Ways 2 & 3), then verify
    // non-SPM Way 2 (0x1000_1000) write rejects with SLVERR (2'b10) WITHOUT corrupting cached state
    fill_seq_64(64'hC200_1111_2222_3300, 8'hFF, wbuf, sbuf);
    axi_write_gen(4'h4, 32'h8000_0000, 8'd0, 3'd3, 2'b01, 4'b1111, wbuf, sbuf, 1'b0, resp);
    fill_seq_64(64'hC300_4444_5555_6600, 8'hFF, wbuf, sbuf);
    axi_write_gen(4'h5, 32'h8000_0800, 8'd0, 3'd3, 2'b01, 4'b1111, wbuf, sbuf, 1'b0, resp);
    fill_seq_64(64'hBAD0_BAD0_BAD0_BAD0, 8'hFF, wbuf, sbuf);
    axi_write_gen(4'h3, 32'h1000_1000, 8'd0, 3'd3, 2'b01, 4'b0011, wbuf, sbuf, 1'b0, resp);
    if (resp !== 2'b10) $fatal(1, "Expected SLVERR on non-SPM way write, got=%b", resp);
    axi_read_gen(4'h6, 32'h8000_0000, 8'd0, 3'd3, 2'b01, 4'b1111, 1'b0, rbuf, resp);
    if (rbuf[0] !== 64'hC200_1111_2222_3300) $fatal(1, "Non-SPM SLVERR write corrupted cached set-0 line A: %h", rbuf[0]);
    axi_read_gen(4'h7, 32'h8000_0800, 8'd0, 3'd3, 2'b01, 4'b1111, 1'b0, rbuf, resp);
    if (rbuf[0] !== 64'hC300_4444_5555_6600) $fatal(1, "Non-SPM SLVERR write corrupted cached set-0 line B: %h", rbuf[0]);

    $display("ALL_TESTS_PASSED seed=%0d mst_ar=%0d mst_aw=%0d", seed_v, mst_ar_cnt, mst_aw_cnt);
    $finish;
  end
