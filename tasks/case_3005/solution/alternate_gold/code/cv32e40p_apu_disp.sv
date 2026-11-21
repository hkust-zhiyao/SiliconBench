// Copyright 2018 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51

module cv32e40p_apu_disp (
    input logic clk_i,
    input logic rst_ni,
    input logic flush_i,

    input logic       enable_i,
    input logic [1:0] apu_lat_i,
    input logic [5:0] apu_waddr_i,

    output logic [5:0] apu_waddr_o,
    output logic       apu_multicycle_o,
    output logic       apu_singlecycle_o,
    output logic       apu_rvalid_wb_o,

    output logic active_o,
    output logic stall_o,

    input  logic            is_decoding_i,
    input  logic [2:0][5:0] read_regs_i,
    input  logic [2:0]      read_regs_valid_i,
    output logic            read_dep_o,
    output logic            read_dep_for_jalr_o,

    input  logic [1:0][5:0] write_regs_i,
    input  logic [1:0]      write_regs_valid_i,
    output logic            write_dep_o,

    output logic perf_type_o,
    output logic perf_cont_o,

    output logic apu_req_o,
    input  logic apu_gnt_i,
    input  logic apu_rvalid_i
);

  logic       s0_valid_q, s1_valid_q;
  logic       s0_killed_q, s1_killed_q;
  logic [5:0] s0_waddr_q, s1_waddr_q;
  logic [1:0] lat_q;

  logic active_w, stall_full_w, stall_type_w, stall_nack_w;
  logic req_vld_w, req_hsk_w;
  logic ret_direct_w, ret_s0_w, ret_s1_w;

  assign active_w     = s0_valid_q | s1_valid_q;
  assign stall_full_w = s0_valid_q & s1_valid_q;
  assign stall_type_w = enable_i & !flush_i & active_w &
                        ((apu_lat_i == 2'h1) | ((apu_lat_i == 2'h2) & (lat_q == 2'h3)) | (apu_lat_i == 2'h3));
  assign req_vld_w    = enable_i & !flush_i & !(stall_full_w | stall_type_w);
  assign req_hsk_w    = req_vld_w & apu_gnt_i;
  assign stall_nack_w = req_vld_w & !apu_gnt_i;

  assign ret_direct_w = req_vld_w & apu_rvalid_i & !active_w;
  assign ret_s0_w     = s0_valid_q & apu_rvalid_i & !s1_valid_q;
  assign ret_s1_w     = s1_valid_q & apu_rvalid_i;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      s0_valid_q  <= 1'b0;
      s1_valid_q  <= 1'b0;
      s0_killed_q <= 1'b0;
      s1_killed_q <= 1'b0;
      s0_waddr_q  <= '0;
      s1_waddr_q  <= '0;
      lat_q       <= '0;
    end else begin
      if (req_hsk_w || (req_vld_w && !active_w)) begin
        lat_q <= apu_lat_i;
      end

      if (req_hsk_w && !ret_direct_w) begin
        s0_valid_q  <= 1'b1;
        s0_waddr_q  <= apu_waddr_i;
        s0_killed_q <= 1'b0;
        if ((s0_valid_q && !ret_s0_w) || ret_s1_w) begin
          s1_valid_q  <= 1'b1;
          s1_waddr_q  <= s0_waddr_q;
          s1_killed_q <= s0_killed_q | flush_i;
        end else begin
          s1_killed_q <= s1_killed_q | (flush_i & s1_valid_q);
        end
      end else if (ret_s0_w) begin
        s0_valid_q  <= 1'b0;
        s1_valid_q  <= 1'b0;
        s0_waddr_q  <= '0;
        s1_waddr_q  <= '0;
        s0_killed_q <= 1'b0;
        s1_killed_q <= 1'b0;
      end else if (ret_s1_w) begin
        s1_valid_q  <= 1'b0;
        s1_waddr_q  <= '0;
        s1_killed_q <= 1'b0;
        s0_killed_q <= s0_killed_q | (flush_i & s0_valid_q);
      end else begin
        s0_killed_q <= s0_killed_q | (flush_i & s0_valid_q);
        s1_killed_q <= s1_killed_q | (flush_i & s1_valid_q);
      end
    end
  end

  logic r_match_req, r_match_s0, r_match_s1;
  logic w_match_req, w_match_s0, w_match_s1;

  assign r_match_req = ((read_regs_i[0] == apu_waddr_i) & read_regs_valid_i[0]) |
                       ((read_regs_i[1] == apu_waddr_i) & read_regs_valid_i[1]) |
                       ((read_regs_i[2] == apu_waddr_i) & read_regs_valid_i[2]);
  assign r_match_s0  = ((read_regs_i[0] == s0_waddr_q)  & read_regs_valid_i[0]) |
                       ((read_regs_i[1] == s0_waddr_q)  & read_regs_valid_i[1]) |
                       ((read_regs_i[2] == s0_waddr_q)  & read_regs_valid_i[2]);
  assign r_match_s1  = ((read_regs_i[0] == s1_waddr_q)  & read_regs_valid_i[0]) |
                       ((read_regs_i[1] == s1_waddr_q)  & read_regs_valid_i[1]) |
                       ((read_regs_i[2] == s1_waddr_q)  & read_regs_valid_i[2]);

  assign w_match_req = ((write_regs_i[0] == apu_waddr_i) & write_regs_valid_i[0]) |
                       ((write_regs_i[1] == apu_waddr_i) & write_regs_valid_i[1]);
  assign w_match_s0  = ((write_regs_i[0] == s0_waddr_q)  & write_regs_valid_i[0]) |
                       ((write_regs_i[1] == s0_waddr_q)  & write_regs_valid_i[1]);
  assign w_match_s1  = ((write_regs_i[0] == s1_waddr_q)  & write_regs_valid_i[0]) |
                       ((write_regs_i[1] == s1_waddr_q)  & write_regs_valid_i[1]);

  assign read_dep_o = is_decoding_i & (
      (r_match_req & req_vld_w & !ret_direct_w) |
      (r_match_s0  & s0_valid_q & !s0_killed_q & !ret_s0_w) |
      (r_match_s1  & s1_valid_q & !s1_killed_q & !ret_s1_w)
  );
  assign write_dep_o = is_decoding_i & (
      (w_match_req & req_vld_w & !ret_direct_w) |
      (w_match_s0  & s0_valid_q & !s0_killed_q & !ret_s0_w) |
      (w_match_s1  & s1_valid_q & !s1_killed_q & !ret_s1_w)
  );
  assign read_dep_for_jalr_o = is_decoding_i & (
      (r_match_req & enable_i & !flush_i) |
      (r_match_s0  & s0_valid_q & !s0_killed_q) |
      (r_match_s1  & s1_valid_q & !s1_killed_q)
  );

  assign apu_req_o         = req_vld_w;
  assign stall_o           = stall_full_w | stall_type_w | stall_nack_w;
  assign active_o          = active_w;
  assign perf_type_o       = stall_type_w;
  assign perf_cont_o       = stall_nack_w;
  assign apu_multicycle_o  = (lat_q == 2'h3);
  assign apu_singlecycle_o = ~active_w;
  assign apu_waddr_o       = ret_s1_w ? s1_waddr_q : (ret_s0_w ? s0_waddr_q : (ret_direct_w ? apu_waddr_i : '0));
  assign apu_rvalid_wb_o   = !flush_i & (ret_direct_w | (ret_s0_w & !s0_killed_q) | (ret_s1_w & !s1_killed_q));

endmodule
