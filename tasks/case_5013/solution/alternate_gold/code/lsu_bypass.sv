// Copyright 2018 ETH Zurich and University of Bologna.
// Licensed under the Solderpad Hardware License, Version 0.51.

module lsu_bypass
  import ariane_pkg::*;
#(
    parameter config_pkg::cva6_cfg_t CVA6Cfg = config_pkg::cva6_cfg_empty,
    parameter type lsu_ctrl_t = logic,
    parameter type bp_resolve_t = logic
) (
    input  logic        clk_i,
    input  logic        rst_ni,
    input  logic        flush_i,
    input  lsu_ctrl_t   lsu_req_i,
    input  logic        lsu_req_valid_i,
    input  logic        pop_ld_i,
    input  logic        pop_st_i,
    input  bp_resolve_t resolved_branch_i,
    output lsu_ctrl_t   lsu_ctrl_o,
    output logic        ready_o
);

  lsu_ctrl_t [1:0] mem_n, mem_q;
  logic            read_pointer_n, read_pointer_q;
  logic            write_pointer_n, write_pointer_q;
  logic [1:0]      status_cnt_n, status_cnt_q;
  logic            empty_q;

  assign ready_o = empty_q;

  function automatic lsu_ctrl_t resolve_entry(input lsu_ctrl_t e, input bp_resolve_t br);
    lsu_ctrl_t r;
    r = e;
    if (e.is_speculative_load && br.valid) begin
      if (br.is_mispredict) begin
        r.is_speculative_load_miss = 1'b1;
      end else begin
        r.is_speculative_load = 1'b0;
      end
    end
    return r;
  endfunction

  always_comb begin
    automatic logic [1:0] status_cnt;
    automatic logic       write_pointer;
    automatic logic       read_pointer;

    status_cnt    = status_cnt_q;
    write_pointer = write_pointer_q;
    read_pointer  = read_pointer_q;
    mem_n         = mem_q;

    if (lsu_req_valid_i) begin
      mem_n[write_pointer_q] = lsu_req_i;
      write_pointer++;
      status_cnt++;
    end

    if (pop_ld_i || pop_st_i) begin
      mem_n[read_pointer_q].valid = 1'b0;
      read_pointer++;
      status_cnt--;
    end

    if (resolved_branch_i.valid) begin
      for (int i = 0; i < 2; i++) begin
        if (mem_n[i].valid) begin
          mem_n[i] = resolve_entry(mem_n[i], resolved_branch_i);
        end
      end
    end

    if (flush_i) begin
      status_cnt       = '0;
      write_pointer    = '0;
      read_pointer     = '0;
      mem_n[0].valid   = 1'b0;
      mem_n[1].valid   = 1'b0;
    end

    read_pointer_n  = read_pointer;
    write_pointer_n = write_pointer;
    status_cnt_n    = status_cnt;
  end

  always_comb begin : output_assignments
    if (empty_q) begin
      lsu_ctrl_o = resolve_entry(lsu_req_i, resolved_branch_i);
    end else begin
      lsu_ctrl_o = resolve_entry(mem_q[read_pointer_q], resolved_branch_i);
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (~rst_ni) begin
      mem_q           <= '0;
      status_cnt_q    <= '0;
      write_pointer_q <= '0;
      read_pointer_q  <= '0;
      empty_q         <= 1'b1;
    end else begin
      mem_q           <= mem_n;
      status_cnt_q    <= status_cnt_n;
      write_pointer_q <= write_pointer_n;
      read_pointer_q  <= read_pointer_n;
      empty_q         <= (status_cnt_n == 2'd0);
    end
  end
endmodule
