`timescale 1ns/1ps

module tb;
  localparam int unsigned SetAssociativity = 32'd2;
  localparam int unsigned NumLines         = 32'd64;
  localparam int unsigned NumBlocks        = 32'd4;
  localparam int unsigned AxiIdWidth       = 32'd4;
  localparam int unsigned AxiAddrWidth     = 32'd32;
  localparam int unsigned AxiDataWidth     = 32'd64;

  logic clk_i = 1'b0;
  logic rst_ni = 1'b0;
  always #5.0 clk_i = ~clk_i;

  logic [AxiIdWidth-1:0]       slv_aw_id, slv_ar_id, slv_b_id, slv_r_id;
  logic [AxiAddrWidth-1:0]     slv_aw_addr, slv_ar_addr;
  logic [7:0]                  slv_aw_len, slv_ar_len;
  logic [2:0]                  slv_aw_size, slv_ar_size;
  logic [1:0]                  slv_aw_burst, slv_ar_burst, slv_b_resp, slv_r_resp;
  logic                        slv_aw_lock, slv_ar_lock, slv_w_last, slv_r_last;
  logic [3:0]                  slv_aw_cache, slv_ar_cache;
  logic [2:0]                  slv_aw_prot, slv_ar_prot;
  logic                        slv_aw_valid, slv_aw_ready, slv_w_valid, slv_w_ready;
  logic                        slv_b_valid, slv_b_ready, slv_ar_valid, slv_ar_ready;
  logic                        slv_r_valid, slv_r_ready;
  logic [AxiDataWidth-1:0]     slv_w_data, slv_r_data;
  logic [AxiDataWidth/8-1:0]   slv_w_strb;

  logic [AxiIdWidth:0]         mst_aw_id, mst_ar_id, mst_b_id, mst_r_id;
  logic [AxiAddrWidth-1:0]     mst_aw_addr, mst_ar_addr;
  logic [7:0]                  mst_aw_len, mst_ar_len;
  logic [2:0]                  mst_aw_size, mst_ar_size;
  logic [1:0]                  mst_aw_burst, mst_ar_burst, mst_b_resp, mst_r_resp;
  logic                        mst_aw_lock, mst_ar_lock, mst_w_last, mst_r_last;
  logic [3:0]                  mst_aw_cache, mst_ar_cache;
  logic [2:0]                  mst_aw_prot, mst_ar_prot;
  logic                        mst_aw_valid, mst_aw_ready, mst_w_valid, mst_w_ready;
  logic                        mst_b_valid, mst_b_ready, mst_ar_valid, mst_ar_ready;
  logic                        mst_r_valid, mst_r_ready;
  logic [AxiDataWidth-1:0]     mst_w_data, mst_r_data;
  logic [AxiDataWidth/8-1:0]   mst_w_strb;

  logic [SetAssociativity-1:0] cfg_spm, cfg_flush, flushed, bist_out;
  logic                        commit_cfg, bist_done;

  `ifndef DUT_MOD
  `define DUT_MOD axi_llc_top_wrap
  `endif

  `DUT_MOD u_dut (
    .clk_i(clk_i), .rst_ni(rst_ni), .test_i(1'b0),
    .slv_aw_id_i(slv_aw_id), .slv_aw_addr_i(slv_aw_addr), .slv_aw_len_i(slv_aw_len),
    .slv_aw_size_i(slv_aw_size), .slv_aw_burst_i(slv_aw_burst), .slv_aw_lock_i(slv_aw_lock),
    .slv_aw_cache_i(slv_aw_cache), .slv_aw_prot_i(slv_aw_prot), .slv_aw_valid_i(slv_aw_valid),
    .slv_aw_ready_o(slv_aw_ready), .slv_w_data_i(slv_w_data), .slv_w_strb_i(slv_w_strb),
    .slv_w_last_i(slv_w_last), .slv_w_valid_i(slv_w_valid), .slv_w_ready_o(slv_w_ready),
    .slv_b_id_o(slv_b_id), .slv_b_resp_o(slv_b_resp), .slv_b_valid_o(slv_b_valid),
    .slv_b_ready_i(slv_b_ready), .slv_ar_id_i(slv_ar_id), .slv_ar_addr_i(slv_ar_addr),
    .slv_ar_len_i(slv_ar_len), .slv_ar_size_i(slv_ar_size), .slv_ar_burst_i(slv_ar_burst),
    .slv_ar_lock_i(slv_ar_lock), .slv_ar_cache_i(slv_ar_cache), .slv_ar_prot_i(slv_ar_prot),
    .slv_ar_valid_i(slv_ar_valid), .slv_ar_ready_o(slv_ar_ready), .slv_r_id_o(slv_r_id),
    .slv_r_data_o(slv_r_data), .slv_r_resp_o(slv_r_resp), .slv_r_last_o(slv_r_last),
    .slv_r_valid_o(slv_r_valid), .slv_r_ready_i(slv_r_ready),
    .mst_aw_id_o(mst_aw_id), .mst_aw_addr_o(mst_aw_addr), .mst_aw_len_o(mst_aw_len),
    .mst_aw_size_o(mst_aw_size), .mst_aw_burst_o(mst_aw_burst), .mst_aw_lock_o(mst_aw_lock),
    .mst_aw_cache_o(mst_aw_cache), .mst_aw_prot_o(mst_aw_prot), .mst_aw_valid_o(mst_aw_valid),
    .mst_aw_ready_i(mst_aw_ready), .mst_w_data_o(mst_w_data), .mst_w_strb_o(mst_w_strb),
    .mst_w_last_o(mst_w_last), .mst_w_valid_o(mst_w_valid), .mst_w_ready_i(mst_w_ready),
    .mst_b_id_i(mst_b_id), .mst_b_resp_i(mst_b_resp), .mst_b_valid_i(mst_b_valid),
    .mst_b_ready_o(mst_b_ready), .mst_ar_id_o(mst_ar_id), .mst_ar_addr_o(mst_ar_addr),
    .mst_ar_len_o(mst_ar_len), .mst_ar_size_o(mst_ar_size), .mst_ar_burst_o(mst_ar_burst),
    .mst_ar_lock_o(mst_ar_lock), .mst_ar_cache_o(mst_ar_cache), .mst_ar_prot_o(mst_ar_prot),
    .mst_ar_valid_o(mst_ar_valid), .mst_ar_ready_i(mst_ar_ready), .mst_r_id_i(mst_r_id),
    .mst_r_data_i(mst_r_data), .mst_r_resp_i(mst_r_resp), .mst_r_last_i(mst_r_last),
    .mst_r_valid_i(mst_r_valid), .mst_r_ready_o(mst_r_ready),
    .cfg_spm_i(cfg_spm), .cfg_flush_i(cfg_flush), .commit_cfg_i(commit_cfg),
    .flushed_o(flushed), .bist_out_o(bist_out), .bist_done_o(bist_done),
    .cached_start_addr_i(32'h8000_0000), .cached_end_addr_i(32'h8004_0000),
    .spm_start_addr_i(32'h1000_0000)
  );

  // 256 KiB backing DRAM + 64 KiB uncached MMIO backing array (8-byte words)
  logic [63:0] mem_cached [0:32767];
  logic [63:0] mem_uncached [0:8191];
  int unsigned mst_ar_cnt, mst_aw_cnt;
  int unsigned seed_v;

  function automatic int unsigned mem_idx_c(input logic [31:0] a);
    return (a - 32'h8000_0000) >> 3;
  endfunction
  function automatic int unsigned mem_idx_u(input logic [31:0] a);
    return (a - 32'h2000_0000) >> 3;
  endfunction

  // Latency-elastic AXI4 Master backing memory responder with backpressure
  logic        aw_act, ar_act;
  logic [4:0]  aw_id_q, ar_id_q;
  logic [31:0] aw_addr_q, ar_addr_q;
  logic [7:0]  aw_rem_q, ar_rem_q;
  logic [31:0] lfsr_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      aw_act <= 1'b0; ar_act <= 1'b0;
      mst_b_valid <= 1'b0; mst_b_id <= '0; mst_b_resp <= 2'b00;
      mst_r_valid <= 1'b0; mst_r_id <= '0; mst_r_data <= '0; mst_r_resp <= 2'b00; mst_r_last <= 1'b0;
      mst_ar_cnt <= 0; mst_aw_cnt <= 0;
      lfsr_q <= 32'hACE1_0001 ^ seed_v;
    end else begin
      lfsr_q <= {lfsr_q[30:0], lfsr_q[31] ^ lfsr_q[21] ^ lfsr_q[1] ^ lfsr_q[0]};
      if (mst_b_valid && mst_b_ready) mst_b_valid <= 1'b0;
      if (!aw_act && !mst_b_valid && mst_aw_valid && mst_aw_ready) begin
        aw_act <= 1'b1; aw_id_q <= mst_aw_id; aw_addr_q <= mst_aw_addr; aw_rem_q <= mst_aw_len;
        mst_aw_cnt <= mst_aw_cnt + 1;
      end else if (aw_act && mst_w_valid && mst_w_ready) begin
        for (int b = 0; b < 8; b++) begin
          if (mst_w_strb[b]) begin
            if (aw_addr_q >= 32'h8000_0000)
              mem_cached[mem_idx_c(aw_addr_q)][b*8 +: 8] <= mst_w_data[b*8 +: 8];
            else
              mem_uncached[mem_idx_u(aw_addr_q)][b*8 +: 8] <= mst_w_data[b*8 +: 8];
          end
        end
        aw_addr_q <= aw_addr_q + 32'd8;
        if (aw_rem_q == 8'd0 || mst_w_last) begin
          aw_act <= 1'b0; mst_b_valid <= 1'b1; mst_b_id <= aw_id_q; mst_b_resp <= 2'b00;
        end else begin
          aw_rem_q <= aw_rem_q - 8'd1;
        end
      end

      if (mst_r_valid && mst_r_ready) begin
        if (mst_r_last) begin
          mst_r_valid <= 1'b0; ar_act <= 1'b0;
        end else begin
          logic [31:0] nxt_a;
          nxt_a = ar_addr_q + 32'd8;
          ar_addr_q <= nxt_a;
          ar_rem_q <= ar_rem_q - 8'd1;
          mst_r_data <= (nxt_a >= 32'h8000_0000) ? mem_cached[mem_idx_c(nxt_a)] : mem_uncached[mem_idx_u(nxt_a)];
          mst_r_last <= (ar_rem_q == 8'd1);
        end
      end
      if (!ar_act && mst_ar_valid && mst_ar_ready) begin
        ar_act <= 1'b1; ar_id_q <= mst_ar_id; ar_addr_q <= mst_ar_addr; ar_rem_q <= mst_ar_len;
        mst_ar_cnt <= mst_ar_cnt + 1;
        mst_r_valid <= 1'b1; mst_r_id <= mst_ar_id; mst_r_resp <= 2'b00;
        mst_r_data <= (mst_ar_addr >= 32'h8000_0000) ? mem_cached[mem_idx_c(mst_ar_addr)] : mem_uncached[mem_idx_u(mst_ar_addr)];
        mst_r_last <= (mst_ar_len == 8'd0);
      end
    end
  end

  assign mst_aw_ready = !aw_act && !mst_b_valid && lfsr_q[0];
  assign mst_w_ready  = aw_act && (lfsr_q[1] || lfsr_q[2]);
  assign mst_ar_ready = !ar_act && lfsr_q[3];

  `include "tb_tasks.svh"
endmodule
