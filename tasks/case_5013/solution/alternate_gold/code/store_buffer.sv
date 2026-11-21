// Copyright 2018 ETH Zurich and University of Bologna.
// Licensed under the Solderpad Hardware License, Version 0.51.

module store_buffer
  import ariane_pkg::*;
#(
    parameter config_pkg::cva6_cfg_t CVA6Cfg        = config_pkg::cva6_cfg_empty,
    parameter type                   dcache_req_i_t = logic,
    parameter type                   dcache_req_o_t = logic,
    parameter type                   cbo_t          = logic
) (
    input  logic                    clk_i,
    input  logic                    rst_ni,
    input  logic                    flush_i,
    input  logic                    stall_st_pending_i,
    output logic                    no_st_pending_o,
    output logic                    store_buffer_empty_o,
    input  logic [11:0]             page_offset_i,
    output logic                    page_offset_matches_o,
    input  logic                    commit_i,
    output logic                    commit_ready_o,
    output logic                    ready_o,
    input  logic                    valid_i,
    input  logic                    valid_without_flush_i,
    input  logic [CVA6Cfg.PLEN-1:0] paddr_i,
    output logic [CVA6Cfg.PLEN-1:0] rvfi_mem_paddr_o,
    input  logic [CVA6Cfg.XLEN-1:0] data_i,
    input  logic [(CVA6Cfg.XLEN/8)-1:0] be_i,
    input  logic [1:0]              data_size_i,
    input  cbo_t                    cbo_op_i,
    input  dcache_req_o_t           req_port_i,
    output dcache_req_i_t           req_port_o
);

  function automatic logic [1:0] encode_cbo(input cbo_t op);
    unique case (op)
      ariane_pkg::CBO_INVAL: return 2'b01;
      ariane_pkg::CBO_CLEAN: return 2'b10;
      ariane_pkg::CBO_FLUSH: return 2'b11;
      default:               return 2'b00;
    endcase
  endfunction

  function automatic cbo_t decode_cbo(input logic [1:0] code);
    unique case (code)
      2'b01:   return ariane_pkg::CBO_INVAL;
      2'b10:   return ariane_pkg::CBO_CLEAN;
      2'b11:   return ariane_pkg::CBO_FLUSH;
      default: return ariane_pkg::CBO_NONE;
    endcase
  endfunction

  struct packed {
    logic [CVA6Cfg.PLEN-1:0]     address;
    logic [CVA6Cfg.XLEN-1:0]     data;
    logic [(CVA6Cfg.XLEN/8)-1:0] be;
    logic [1:0]                  data_size;
    logic [1:0]                  cbo_code;
    logic                        valid;
  }
      speculative_queue_n[DEPTH_SPEC-1:0],
      speculative_queue_q[DEPTH_SPEC-1:0],
      commit_queue_n[DEPTH_COMMIT-1:0],
      commit_queue_q[DEPTH_COMMIT-1:0];

  logic                        cbo_wait_rvalid_n, cbo_wait_rvalid_q;
  logic [$clog2(DEPTH_SPEC):0] speculative_status_cnt_n, speculative_status_cnt_q;
  logic [$clog2(DEPTH_COMMIT):0] commit_status_cnt_n, commit_status_cnt_q;
  logic [$clog2(DEPTH_SPEC)-1:0] speculative_read_pointer_n, speculative_read_pointer_q;
  logic [$clog2(DEPTH_SPEC)-1:0] speculative_write_pointer_n, speculative_write_pointer_q;
  logic [$clog2(DEPTH_COMMIT)-1:0] commit_read_pointer_n, commit_read_pointer_q;
  logic [$clog2(DEPTH_COMMIT)-1:0] commit_write_pointer_n, commit_write_pointer_q;

  assign store_buffer_empty_o = (speculative_status_cnt_q == 0) & no_st_pending_o;

  always_comb begin : core_if
    automatic logic [$clog2(DEPTH_SPEC):0] speculative_status_cnt;
    speculative_status_cnt      = speculative_status_cnt_q;
    speculative_read_pointer_n  = speculative_read_pointer_q;
    speculative_write_pointer_n = speculative_write_pointer_q;
    speculative_queue_n         = speculative_queue_q;

    if (valid_i) begin
      speculative_queue_n[speculative_write_pointer_q].address   = paddr_i;
      speculative_queue_n[speculative_write_pointer_q].data      = data_i;
      speculative_queue_n[speculative_write_pointer_q].be        = be_i;
      speculative_queue_n[speculative_write_pointer_q].data_size = data_size_i;
      speculative_queue_n[speculative_write_pointer_q].cbo_code  = encode_cbo(cbo_op_i);
      speculative_queue_n[speculative_write_pointer_q].valid     = 1'b1;
      speculative_write_pointer_n = speculative_write_pointer_q + 1'b1;
      speculative_status_cnt++;
    end

    if (commit_i) begin
      speculative_queue_n[speculative_read_pointer_q].valid = 1'b0;
      speculative_read_pointer_n = speculative_read_pointer_q + 1'b1;
      speculative_status_cnt--;
    end

    speculative_status_cnt_n = speculative_status_cnt;

    if (flush_i) begin
      for (int unsigned i = 0; i < DEPTH_SPEC; i++) speculative_queue_n[i].valid = 1'b0;
      speculative_write_pointer_n = speculative_read_pointer_q;
      speculative_status_cnt_n = 'b0;
    end

    ready_o = (speculative_status_cnt_n < (DEPTH_SPEC)) || commit_i;
  end

  assign req_port_o.kill_req  = 1'b0;
  assign req_port_o.data_we   = 1'b1;
  assign req_port_o.tag_valid = 1'b0;
  assign req_port_o.data_id   = '0;
  assign req_port_o.address_index = commit_queue_q[commit_read_pointer_q].address[CVA6Cfg.DCACHE_INDEX_WIDTH-1:0];
  assign req_port_o.address_tag   = commit_queue_q[commit_read_pointer_q].address[CVA6Cfg.DCACHE_TAG_WIDTH + CVA6Cfg.DCACHE_INDEX_WIDTH - 1 : CVA6Cfg.DCACHE_INDEX_WIDTH];
  assign req_port_o.data_wdata = commit_queue_q[commit_read_pointer_q].data;
  assign req_port_o.data_wuser = '0;
  assign req_port_o.data_be    = commit_queue_q[commit_read_pointer_q].be;
  assign req_port_o.data_size  = commit_queue_q[commit_read_pointer_q].data_size;

  assign rvfi_mem_paddr_o = speculative_queue_q[speculative_read_pointer_q].address;

  always_comb begin : store_if
    automatic logic [$clog2(DEPTH_COMMIT):0] commit_status_cnt;
    commit_status_cnt      = commit_status_cnt_q;

    commit_ready_o         = (commit_status_cnt_q < DEPTH_COMMIT);
    no_st_pending_o        = (commit_status_cnt_q == 0);
    commit_read_pointer_n  = commit_read_pointer_q;
    commit_write_pointer_n = commit_write_pointer_q;
    commit_queue_n         = commit_queue_q;
    cbo_wait_rvalid_n   = cbo_wait_rvalid_q;

    req_port_o.data_req    = 1'b0;
    req_port_o.cbo_op      = decode_cbo(commit_queue_q[commit_read_pointer_q].cbo_code);

    if (commit_queue_q[commit_read_pointer_q].valid && !stall_st_pending_i && !cbo_wait_rvalid_q) begin
      req_port_o.data_req = 1'b1;
      if (req_port_i.data_gnt) begin
        if (commit_queue_q[commit_read_pointer_q].cbo_code != 2'b00) begin
          cbo_wait_rvalid_n = 1'b1;
        end else begin
          commit_queue_n[commit_read_pointer_q].valid = 1'b0;
          commit_read_pointer_n = commit_read_pointer_q + 1'b1;
          commit_status_cnt--;
        end
      end
    end

    if (commit_queue_q[commit_read_pointer_q].valid && cbo_wait_rvalid_q) begin
      if (req_port_i.data_rvalid) begin
        commit_queue_n[commit_read_pointer_q].valid = 1'b0;
        cbo_wait_rvalid_n  = 1'b0;
        commit_read_pointer_n = commit_read_pointer_q + 1'b1;
        commit_status_cnt--;
      end
    end

    if (commit_i) begin
      commit_queue_n[commit_write_pointer_q] = speculative_queue_q[speculative_read_pointer_q];
      commit_write_pointer_n = commit_write_pointer_n + 1'b1;
      commit_status_cnt++;
    end

    commit_status_cnt_n = commit_status_cnt;
  end

  logic [int'(DEPTH_COMMIT)-1:0] c_match;
  logic [int'(DEPTH_SPEC)-1:0]   s_match;
  always_comb begin : address_checker
    for (int unsigned i = 0; i < DEPTH_COMMIT; i++) begin
      c_match[i] = commit_queue_q[i].valid && (page_offset_i[11:2] == commit_queue_q[i].address[11:2]);
    end
    for (int unsigned i = 0; i < DEPTH_SPEC; i++) begin
      s_match[i] = speculative_queue_q[i].valid && (page_offset_i[11:2] == speculative_queue_q[i].address[11:2]);
    end
    page_offset_matches_o = (|c_match) | (|s_match) | (valid_without_flush_i && (page_offset_i[11:2] == paddr_i[11:2]));
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin : p_spec
    if (~rst_ni) begin
      speculative_queue_q         <= '{default: 0};
      speculative_read_pointer_q  <= '0;
      speculative_write_pointer_q <= '0;
      speculative_status_cnt_q    <= '0;
    end else begin
      speculative_queue_q         <= speculative_queue_n;
      speculative_read_pointer_q  <= speculative_read_pointer_n;
      speculative_write_pointer_q <= speculative_write_pointer_n;
      speculative_status_cnt_q    <= speculative_status_cnt_n;
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin : p_commit
    if (~rst_ni) begin
      commit_queue_q         <= '{default: 0};
      commit_read_pointer_q  <= '0;
      commit_write_pointer_q <= '0;
      commit_status_cnt_q    <= '0;
      cbo_wait_rvalid_q   <= 1'b0;
    end else begin
      commit_queue_q         <= commit_queue_n;
      commit_read_pointer_q  <= commit_read_pointer_n;
      commit_write_pointer_q <= commit_write_pointer_n;
      commit_status_cnt_q    <= commit_status_cnt_n;
      cbo_wait_rvalid_q   <= cbo_wait_rvalid_n;
    end
  end
endmodule
