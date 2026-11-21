  task automatic axi_write_burst(
    input logic [3:0]  id,
    input logic [31:0] addr,
    input logic [7:0]  len,
    input logic [3:0]  cache_attr,
    input logic [63:0] base_val,
    input logic [7:0]  strb_mask,
    output logic [1:0] bresp_out
  );
    int cyc;
    @(posedge clk_i); #1;
    slv_b_ready = 1'b1;
    fork
      begin
        slv_aw_id = id; slv_aw_addr = addr; slv_aw_len = len;
        slv_aw_size = 3'd3; slv_aw_burst = 2'b01; slv_aw_lock = 1'b0;
        slv_aw_cache = cache_attr; slv_aw_prot = 3'b000; slv_aw_valid = 1'b1;
        cyc = 0;
        do begin @(posedge clk_i); cyc++; if (cyc > 4000) $fatal(1, "Timeout on AW"); end while (!slv_aw_ready);
        #1; slv_aw_valid = 1'b0;
      end
      begin
        for (int i = 0; i <= int'(len); i++) begin
          slv_w_data = base_val + {32'd0, i[31:0]} * 64'h0101_0101_0101_0101;
          slv_w_strb = strb_mask;
          slv_w_last = (i == int'(len));
          slv_w_valid = 1'b1;
          cyc = 0;
          do begin @(posedge clk_i); cyc++; if (cyc > 4000) $fatal(1, "Timeout on W beat %0d", i); end while (!slv_w_ready);
          #1; slv_w_valid = 1'b0; slv_w_last = 1'b0;
        end
      end
    join
    cyc = 0;
    while (!slv_b_valid) begin @(posedge clk_i); cyc++; if (cyc > 4000) $fatal(1, "Timeout on B"); end
    if (slv_b_id !== id) $fatal(1, "BID mismatch got=%0h exp=%0h", slv_b_id, id);
    bresp_out = slv_b_resp;
    @(posedge clk_i); #1;
    slv_b_ready = 1'b0;
  endtask

  task automatic axi_read_burst(
    input logic [3:0]  id,
    input logic [31:0] addr,
    input logic [7:0]  len,
    input logic [3:0]  cache_attr,
    input bit          backpressure,
    output logic [63:0] rdata_arr [0:15],
    output logic [1:0]  rresp_out
  );
    int cyc;
    @(posedge clk_i); #1;
    slv_ar_id = id; slv_ar_addr = addr; slv_ar_len = len;
    slv_ar_size = 3'd3; slv_ar_burst = 2'b01; slv_ar_lock = 1'b0;
    slv_ar_cache = cache_attr; slv_ar_prot = 3'b000; slv_ar_valid = 1'b1;
    cyc = 0;
    do begin @(posedge clk_i); cyc++; if (cyc > 4000) $fatal(1, "Timeout on AR"); end while (!slv_ar_ready);
    #1; slv_ar_valid = 1'b0;

    for (int i = 0; i <= int'(len); i++) begin
      if (backpressure && (i[0] == 1'b1)) begin
        slv_r_ready = 1'b0;
        repeat (3) @(posedge clk_i);
        #1;
      end
      slv_r_ready = 1'b1;
      cyc = 0;
      do begin @(posedge clk_i); cyc++; if (cyc > 4000) $fatal(1, "Timeout on R beat %0d", i); end while (!slv_r_valid);
      if (slv_r_id !== id) $fatal(1, "RID mismatch got=%0h exp=%0h", slv_r_id, id);
      if (slv_r_last !== (i == int'(len))) $fatal(1, "RLAST mismatch beat=%0d", i);
      rdata_arr[i] = slv_r_data;
      rresp_out    = slv_r_resp;
      #1;
    end
    slv_r_ready = 1'b0;
  endtask

  initial begin
    logic [63:0] rbuf [0:15];
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

    // 1. Wait for BIST initialization
    wait_c = 0;
    while (!bist_done) begin
      @(posedge clk_i); wait_c++;
      if (wait_c > 6000) $fatal(1, "Timeout waiting for BIST done");
    end
    if (bist_out !== 2'b00) $fatal(1, "BIST reported failure: %b", bist_out);

    // 2. Cold read miss + cached read hit under R backpressure
    ar_before = mst_ar_cnt;
    axi_read_burst(4'h1, 32'h8000_0100, 8'd3, 4'b1111, 1'b1, rbuf, resp);
    if (resp !== 2'b00) $fatal(1, "Cold read resp error");
    for (int i = 0; i < 4; i++)
      if (rbuf[i] !== mem_cached[mem_idx_c(32'h8000_0100) + i])
        $fatal(1, "Cold read mismatch[%0d]: got=%h exp=%h", i, rbuf[i], mem_cached[mem_idx_c(32'h8000_0100) + i]);
    if (mst_ar_cnt != ar_before + 1) $fatal(1, "Expected 1 refill AR, got delta=%0d", mst_ar_cnt - ar_before);

    ar_before = mst_ar_cnt;
    axi_read_burst(4'h2, 32'h8000_0100, 8'd3, 4'b1111, 1'b1, rbuf, resp);
    if (mst_ar_cnt != ar_before) $fatal(1, "Read hit unexpectedly issued master AR");
    for (int i = 0; i < 4; i++)
      if (rbuf[i] !== mem_cached[mem_idx_c(32'h8000_0100) + i])
        $fatal(1, "Hit read mismatch[%0d]", i);

    // 3. Cross-line 8-beat write + partial-strobe write + dirty eviction across 2-way set
    // Set index bits [10:5] (64 lines * 32B = 2048B = 0x800 stride per way!)
    axi_write_burst(4'h3, 32'h8000_0100, 8'd7, 4'b1111, 64'hCAFE_BEEF_1100_2200, 8'hFF, resp);
    if (resp !== 2'b00) $fatal(1, "Cross-line write resp=%b", resp);
    axi_write_burst(4'h4, 32'h8000_0100, 8'd0, 4'b1111, 64'hDEAD_0000_0000_99AA, 8'b1100_0011, resp);
    // Fill second way of same set (0x8000_0900) with dirty data, then access third tag (0x8000_1100)
    axi_write_burst(4'h5, 32'h8000_0900, 8'd3, 4'b1111, 64'hABCD_1234_5678_0000, 8'hFF, resp);
    aw_before = mst_aw_cnt;
    axi_write_burst(4'h6, 32'h8000_1100, 8'd3, 4'b1111, 64'h7777_8888_9999_0000, 8'hFF, resp);
    if (mst_aw_cnt <= aw_before) $fatal(1, "Expected dirty eviction AW on 3rd tag in 2-way set");
    // Read back both dirty-written lines (one from cache, one refilled from backing DRAM after eviction!)
    axi_read_burst(4'h7, 32'h8000_0100, 8'd7, 4'b1111, 1'b1, rbuf, resp);
    if (rbuf[0] !== 64'hDEAD_BEEF_1100_99AA)
      $fatal(1, "Partial-strobe/evict readback[0] mismatch: got=%h", rbuf[0]);
    if (rbuf[5] !== (64'hCAFE_BEEF_1100_2200 + 64'd5 * 64'h0101_0101_0101_0101))
      $fatal(1, "Cross-line readback[5] mismatch: got=%h", rbuf[5]);

    // 4. Uncached bypass write & read (0x2000_0040)
    axi_write_burst(4'h8, 32'h2000_0040, 8'd1, 4'b0000, 64'h5566_7788_AABB_CCDD, 8'hF0, resp);
    axi_read_burst(4'h9, 32'h2000_0040, 8'd1, 4'b0000, 1'b0, rbuf, resp);
    if (rbuf[0][63:32] !== 32'h5566_7788) $fatal(1, "Bypass readback mismatch: got=%h", rbuf[0]);

    // 5. Dynamic SPM way 0 configuration + SPM read/write without master bus traffic
    @(posedge clk_i); #1;
    cfg_spm = 2'b01; cfg_flush = 2'b00; commit_cfg = 1'b1;
    @(posedge clk_i); #1;
    commit_cfg = 1'b0;
    wait_c = 0;
    while (flushed !== 2'b01) begin
      @(posedge clk_i); wait_c++;
      if (wait_c > 6000) $fatal(1, "Timeout waiting for SPM way flush");
    end
    ar_before = mst_ar_cnt; aw_before = mst_aw_cnt;
    axi_write_burst(4'hA, 32'h1000_0080, 8'd3, 4'b0011, 64'hF00D_CAFE_0000_1111, 8'hFF, resp);
    axi_read_burst(4'hB, 32'h1000_0080, 8'd3, 4'b0011, 1'b1, rbuf, resp);
    if (resp !== 2'b00 || rbuf[2] !== (64'hF00D_CAFE_0000_1111 + 64'd2 * 64'h0101_0101_0101_0101))
      $fatal(1, "SPM readback mismatch: got=%h resp=%b", rbuf[2], resp);
    if (mst_ar_cnt != ar_before || mst_aw_cnt != aw_before)
      $fatal(1, "SPM access unexpectedly generated master AXI traffic");

    $display("ALL_TESTS_PASSED seed=%0d mst_ar=%0d mst_aw=%0d", seed_v, mst_ar_cnt, mst_aw_cnt);
    $finish;
  end
