// Copyright lowRISC contributors (OpenTitan project).
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0
//
// Private boundary verification testbench for spi_host_core (`case_1011`).

module tb #(
  parameter int SEED = 101
);
  import spi_host_cmd_pkg::*;

  localparam int NumCS = 1;
  localparam int CSW   = prim_util_pkg::vbits(NumCS);

  logic             clk_i;
  logic             rst_ni;
  command_t         command_i;
  logic [CSW-1:0]   command_csid_i;
  logic             command_valid_i;
  logic             en_i;
  logic [31:0]      tx_data_i;
  logic [3:0]       tx_be_i;
  logic             tx_valid_i;
  logic             rx_ready_i;
  logic             sw_rst_i;
  logic [3:0]       sd_i;

  // DUT outputs
  logic             dut_command_ready_o;
  logic             dut_tx_ready_o;
  logic             dut_tx_byte_select_full_o;
  logic [31:0]      dut_rx_data_o;
  logic             dut_rx_valid_o;
  logic             dut_sck_o;
  logic [NumCS-1:0] dut_csb_o;
  logic [3:0]       dut_sd_o;
  logic [3:0]       dut_sd_en_o;
  logic             dut_rx_stall_o;
  logic             dut_tx_stall_o;
  logic             dut_active_o;

  // Reference outputs
  logic             ref_command_ready_o;
  logic             ref_tx_ready_o;
  logic             ref_tx_byte_select_full_o;
  logic [31:0]      ref_rx_data_o;
  logic             ref_rx_valid_o;
  logic             ref_sck_o;
  logic [NumCS-1:0] ref_csb_o;
  logic [3:0]       ref_sd_o;
  logic [3:0]       ref_sd_en_o;
  logic             ref_rx_stall_o;
  logic             ref_tx_stall_o;
  logic             ref_active_o;

  spi_host_core #(
    .NumCS(NumCS)
  ) dut (
    .clk_i                (clk_i),
    .rst_ni               (rst_ni),
    .command_i            (command_i),
    .command_csid_i       (command_csid_i),
    .command_valid_i      (command_valid_i),
    .command_ready_o      (dut_command_ready_o),
    .en_i                 (en_i),
    .tx_data_i            (tx_data_i),
    .tx_be_i              (tx_be_i),
    .tx_valid_i           (tx_valid_i),
    .tx_ready_o           (dut_tx_ready_o),
    .tx_byte_select_full_o(dut_tx_byte_select_full_o),
    .rx_data_o            (dut_rx_data_o),
    .rx_valid_o           (dut_rx_valid_o),
    .rx_ready_i           (rx_ready_i),
    .sw_rst_i             (sw_rst_i),
    .sck_o                (dut_sck_o),
    .csb_o                (dut_csb_o),
    .sd_o                 (dut_sd_o),
    .sd_en_o              (dut_sd_en_o),
    .sd_i                 (sd_i),
    .rx_stall_o           (dut_rx_stall_o),
    .tx_stall_o           (dut_tx_stall_o),
    .active_o             (dut_active_o)
  );

  // Inline cycle-accurate reference model of spi_host_core
  logic       ref_rx_valid_sr, ref_rx_ready_sr, ref_rx_last_sr;
  logic [7:0] ref_rx_data_sr;
  logic       ref_tx_valid_sr, ref_tx_ready_sr, ref_tx_flush_sr;
  logic [7:0] ref_tx_data_sr;
  logic       ref_wr_en, ref_rd_en, ref_wr_ready, ref_rd_ready;
  logic       ref_sample_en, ref_shift_en, ref_full_cyc, ref_last_read, ref_last_write;
  logic [1:0] ref_speed;

  // Reference byte_merge
  spi_host_byte_merge u_ref_merge (
    .clk_i       (clk_i),
    .rst_ni      (rst_ni),
    .byte_i      (ref_rx_data_sr),
    .byte_last_i (ref_rx_last_sr),
    .byte_valid_i(ref_rx_valid_sr),
    .byte_ready_o(ref_rx_ready_sr),
    .word_o      (ref_rx_data_o),
    .word_valid_o(ref_rx_valid_o),
    .word_ready_i(rx_ready_i),
    .sw_rst_i    (sw_rst_i)
  );

  // Reference byte_select
  logic [35:0] ref_bs_wdata_be;
  logic        ref_bs_do_drain, ref_bs_byte_en, ref_bs_byte_valid, ref_bs_byte_ready, ref_bs_clr;
  assign ref_bs_clr                = ref_tx_flush_sr | sw_rst_i;
  assign ref_tx_valid_sr           = ref_bs_byte_valid & ref_bs_byte_en;
  assign ref_bs_do_drain           = ref_bs_byte_valid & ~ref_bs_byte_en;
  assign ref_bs_byte_ready         = ref_tx_ready_sr | ref_bs_do_drain;
  assign ref_tx_byte_select_full_o = ref_tx_valid_sr;
  for (genvar ii = 0; ii < 4; ii++) begin : gen_ref_bs_map
    assign ref_bs_wdata_be[9*ii +: 9] = {tx_be_i[ii], tx_data_i[8*ii +: 8]};
  end
  prim_packer_fifo #(
    .InW(36),
    .OutW(9)
  ) u_ref_bs_packer (
    .clk_i   (clk_i),
    .rst_ni  (rst_ni),
    .clr_i   (ref_bs_clr),
    .wdata_i (ref_bs_wdata_be),
    .wvalid_i(tx_valid_i),
    .wready_o(ref_tx_ready_o),
    .rdata_o ({ref_bs_byte_en, ref_tx_data_sr}),
    .rvalid_o(ref_bs_byte_valid),
    .rready_i(ref_bs_byte_ready),
    .depth_o ()
  );

  // Reference shift_register
  logic [7:0] ref_sr_q, ref_sr_d, ref_sr_shifted;
  logic [3:0] ref_sd_i_q, ref_sd_i_d, ref_next_bits;
  logic [8:0] ref_rx_buf_q, ref_rx_buf_d;
  logic       ref_rx_buf_valid_q, ref_rx_buf_valid_d;

  assign ref_next_bits          = ref_full_cyc ? sd_i : ref_sd_i_q;
  assign ref_sr_shifted         = (ref_speed == Standard) ? {ref_sr_q[6:0], ref_next_bits[1]}   :
                                  (ref_speed == Dual)     ? {ref_sr_q[5:0], ref_next_bits[1:0]} :
                                  (ref_speed == Quad)     ? {ref_sr_q[3:0], ref_next_bits[3:0]} :
                                  8'h00;
  assign ref_sd_o               = (ref_speed == Standard) ? {3'b000, ref_sr_q[7]}   :
                                  (ref_speed == Dual)     ? {2'b00,  ref_sr_q[7:6]} :
                                  (ref_speed == Quad)     ? ref_sr_q[7:4]           :
                                  4'h0;
  assign ref_rd_ready           = ~ref_rx_buf_valid_q | (ref_rx_valid_sr & ref_rx_ready_sr);
  assign ref_rx_valid_sr        = ref_rx_buf_valid_q;
  assign ref_rx_buf_d           = sw_rst_i                    ? 9'h0 :
                                  (ref_rd_en && ref_rd_ready) ? {ref_last_read, ref_sr_shifted} :
                                  ref_rx_buf_q;
  assign ref_rx_buf_valid_d     = sw_rst_i                            ? 1'b0 :
                                  (ref_rd_en && ref_rd_ready)         ? 1'b1 :
                                  (ref_rx_valid_sr & ref_rx_ready_sr) ? 1'b0 :
                                  ref_rx_buf_valid_q;
  assign ref_sd_i_d             = sw_rst_i      ? 4'b0 :
                                  ref_sample_en ? sd_i :
                                  ref_sd_i_q;
  assign {ref_rx_last_sr, ref_rx_data_sr} = ref_rx_buf_q;
  assign ref_wr_ready           = ref_tx_valid_sr;
  assign ref_tx_ready_sr        = ref_wr_en;
  assign ref_tx_flush_sr        = ref_last_write;
  assign ref_sr_d               = sw_rst_i                   ? 8'h0 :
                                  (ref_wr_en & ref_wr_ready) ? ref_tx_data_sr :
                                  ref_shift_en               ? ref_sr_shifted :
                                  ref_sr_q;

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      ref_sd_i_q         <= 4'h0;
      ref_sr_q           <= 8'h0;
      ref_rx_buf_valid_q <= 1'b0;
      ref_rx_buf_q       <= 9'h0;
    end else begin
      ref_sd_i_q         <= ref_sd_i_d;
      ref_sr_q           <= ref_sr_d;
      ref_rx_buf_valid_q <= ref_rx_buf_valid_d;
      ref_rx_buf_q       <= ref_rx_buf_d;
    end
  end

  // Reference FSM
  logic             ref_is_idle;
  logic [15:0]      ref_clkdiv, ref_clkdiv_q, ref_clk_cntr_q, ref_clk_cntr_d;
  logic [CSW-1:0]   ref_csid, ref_csid_q;
  logic [3:0]       ref_csnidle, ref_csntrail, ref_csnlead;
  logic [3:0]       ref_csnidle_q, ref_csntrail_q, ref_csnlead_q;
  logic             ref_cpha, ref_cpol, ref_full_cyc_q, ref_cpha_q, ref_cpol_q;
  logic [1:0]       ref_cmd_speed_d, ref_cmd_speed_q;
  logic             ref_cmd_wr_en_d, ref_cmd_wr_en_q;
  logic             ref_cmd_rd_en_d, ref_cmd_rd_en_q;
  logic [19:0]      ref_cmd_len_d;
  logic             ref_csaat, ref_csaat_q;
  logic [2:0]       ref_bit_cntr_d, ref_bit_cntr_q;
  logic [19:0]      ref_byte_cntr_d, ref_byte_cntr_q;
  logic [3:0]       ref_wait_cntr_d, ref_wait_cntr_q;
  logic             ref_last_bit, ref_last_byte;
  logic             ref_state_changing;
  logic             ref_byte_starting, ref_byte_starting_cpha0, ref_byte_starting_cpha1;
  logic             ref_bit_shifting, ref_bit_shifting_cpha0, ref_bit_shifting_cpha1;
  logic             ref_byte_ending, ref_byte_ending_cpha0, ref_byte_ending_cpha1;
  logic             ref_sample_en_d, ref_sample_en_q, ref_sample_en_q2;
  logic             ref_config_changed, ref_fsm_en, ref_new_command;
  logic             ref_csb_single_d, ref_sck_d, ref_sck_q;
  logic [NumCS-1:0] ref_csb_q;
  logic             ref_wr_en_int, ref_rd_en_int, ref_sample_en_int, ref_shift_en_int;
  logic             ref_stall, ref_cmd_ready_int;
  logic             ref_seg_rd_en, ref_seg_rd_en_cpha1;
  logic             ref_cmd_wr_en_last_bit;

  typedef enum logic [2:0] {
    RefIdle,
    RefWaitLead,
    RefInternalClkLow,
    RefInternalClkHigh,
    RefWaitTrail,
    RefWaitIdle,
    RefCSBSwitch,
    RefIdleCSBActive
  } ref_st_e;
  ref_st_e ref_state_q, ref_state_d, ref_next_idle, ref_next_csb_act;
  logic    ref_cmd_rdy_csb_act;

  assign ref_stall           = ref_rx_stall_o | ref_tx_stall_o;
  assign ref_wr_en           = ref_wr_en_int & ~ref_stall;
  assign ref_rd_en           = ref_rd_en_int & ~ref_stall;
  assign ref_sample_en       = ref_sample_en_int & ~ref_stall;
  assign ref_shift_en        = ref_shift_en_int & ~ref_stall;
  assign ref_command_ready_o = ref_cmd_ready_int & ~ref_stall;
  assign ref_new_command     = command_valid_i && ref_cmd_ready_int;
  assign ref_config_changed  = (command_i.configopts.cpol     != ref_cpol_q) ||
                               (command_i.configopts.cpha     != ref_cpha_q) ||
                               (command_i.configopts.full_cyc != ref_full_cyc_q) ||
                               (command_i.configopts.csnidle  != ref_csnidle_q) ||
                               (command_i.configopts.csntrail != ref_csntrail_q) ||
                               (command_i.configopts.csnlead  != ref_csnlead_q) ||
                               (command_i.configopts.clkdiv   != ref_clkdiv_q);

  always_comb begin
    ref_csid        = ref_new_command ? command_csid_i : ref_csid_q;
    ref_cpol        = ref_new_command ? command_i.configopts.cpol : ref_cpol_q;
    ref_cpha        = ref_new_command ? command_i.configopts.cpha : ref_cpha_q;
    ref_full_cyc    = ref_new_command ? command_i.configopts.full_cyc : ref_full_cyc_q;
    ref_csnidle     = ref_new_command ? command_i.configopts.csnidle : ref_csnidle_q;
    ref_csnlead     = ref_new_command ? command_i.configopts.csnlead : ref_csnlead_q;
    ref_csntrail    = ref_new_command ? command_i.configopts.csntrail : ref_csntrail_q;
    ref_clkdiv      = ref_new_command ? command_i.configopts.clkdiv : ref_clkdiv_q;
    ref_csaat       = ref_new_command ? command_i.segment.csaat : ref_csaat_q;
    ref_cmd_len_d   = command_i.segment.len;
    ref_cmd_wr_en_d = ref_new_command ? command_i.segment.cmd_wr_en : ref_cmd_wr_en_q;
    ref_cmd_rd_en_d = ref_new_command ? command_i.segment.cmd_rd_en : ref_cmd_rd_en_q;
    ref_cmd_speed_d = ref_new_command ? command_i.segment.speed : ref_cmd_speed_q;
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      ref_csid_q      <= '0;
      ref_cpol_q      <= 1'b0;
      ref_cpha_q      <= 1'b0;
      ref_full_cyc_q  <= 1'b0;
      ref_csnidle_q   <= 4'h0;
      ref_csnlead_q   <= 4'h0;
      ref_csntrail_q  <= 4'h0;
      ref_clkdiv_q    <= 16'h0;
      ref_csaat_q     <= 1'b0;
      ref_cmd_rd_en_q <= 1'b0;
      ref_cmd_wr_en_q <= 1'b0;
      ref_cmd_speed_q <= 2'b00;
    end else if (ref_new_command && !ref_stall) begin
      ref_csid_q      <= ref_csid;
      ref_cpol_q      <= ref_cpol;
      ref_cpha_q      <= ref_cpha;
      ref_full_cyc_q  <= ref_full_cyc;
      ref_csnidle_q   <= ref_csnidle;
      ref_csnlead_q   <= ref_csnlead;
      ref_csntrail_q  <= ref_csntrail;
      ref_clkdiv_q    <= ref_clkdiv;
      ref_csaat_q     <= ref_csaat;
      ref_cmd_wr_en_q <= ref_cmd_wr_en_d;
      ref_cmd_rd_en_q <= ref_cmd_rd_en_d;
      ref_cmd_speed_q <= ref_cmd_speed_d;
    end
  end

  assign ref_is_idle    = (ref_state_q == RefIdle) || (ref_state_q == RefIdleCSBActive);
  assign ref_active_o   = ~ref_is_idle;
  assign ref_clk_cntr_d = sw_rst_i                  ? 16'h0 :
                          !en_i                     ? ref_clk_cntr_q :
                          ref_new_command           ? ref_clkdiv :
                          ref_is_idle               ? ref_clk_cntr_q :
                          (ref_clk_cntr_q == 16'h0) ? ref_clkdiv :
                          ref_clk_cntr_q - 16'd1;
  assign ref_tx_stall_o = ref_wr_en_int & ~ref_wr_ready;
  assign ref_rx_stall_o = ref_rd_en_int & ~ref_rd_ready;
  assign ref_fsm_en     = en_i && ((ref_clk_cntr_q == 16'h0) || ref_is_idle);

  always_comb begin
    if (command_valid_i) begin
      ref_next_idle = ref_config_changed ? RefCSBSwitch : RefWaitLead;
    end else begin
      ref_next_idle = RefIdle;
    end
    if (command_valid_i) begin
      if (command_csid_i != ref_csid_q) begin
        ref_next_csb_act    = RefWaitTrail;
        ref_cmd_rdy_csb_act = 1'b0;
      end else begin
        ref_next_csb_act    = ref_cpha_q ? RefInternalClkHigh : RefInternalClkLow;
        ref_cmd_rdy_csb_act = 1'b1;
      end
    end else begin
      ref_next_csb_act    = RefIdleCSBActive;
      ref_cmd_rdy_csb_act = 1'b1;
    end
  end

  always_comb begin
    ref_state_d       = ref_state_q;
    ref_cmd_ready_int = 1'b0;
    if (sw_rst_i) begin
      ref_state_d = RefIdle;
    end else if (ref_fsm_en) begin
      unique case (ref_state_q)
        RefIdle: begin
          ref_cmd_ready_int = 1'b1;
          ref_state_d       = ref_next_idle;
        end
        RefWaitLead: begin
          if (ref_wait_cntr_q == 4'h0) ref_state_d = RefInternalClkHigh;
        end
        RefInternalClkLow: begin
          if (!ref_last_bit || !ref_last_byte || !ref_cpha_q) begin
            ref_state_d = RefInternalClkHigh;
          end else if (!ref_csaat_q) begin
            ref_state_d = RefWaitTrail;
          end else begin
            ref_state_d       = ref_next_csb_act;
            ref_cmd_ready_int = ref_cmd_rdy_csb_act;
          end
        end
        RefInternalClkHigh: begin
          if (!ref_last_bit || !ref_last_byte || ref_cpha_q) begin
            ref_state_d = RefInternalClkLow;
          end else if (!ref_csaat_q) begin
            ref_state_d = RefWaitTrail;
          end else begin
            ref_state_d       = ref_next_csb_act;
            ref_cmd_ready_int = ref_cmd_rdy_csb_act;
          end
        end
        RefWaitTrail: begin
          if (ref_wait_cntr_q == 4'h0) ref_state_d = RefWaitIdle;
        end
        RefWaitIdle: begin
          if (ref_wait_cntr_q == 4'h0) begin
            ref_cmd_ready_int = 1'b1;
            ref_state_d       = ref_next_idle;
          end
        end
        RefCSBSwitch: begin
          ref_state_d = (ref_wait_cntr_q == 4'h0) ? RefWaitLead : RefCSBSwitch;
        end
        RefIdleCSBActive: begin
          ref_state_d       = ref_next_csb_act;
          ref_cmd_ready_int = ref_cmd_rdy_csb_act;
        end
        default: begin
          ref_cmd_ready_int = 1'b0;
          ref_state_d       = RefIdle;
        end
      endcase
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      ref_state_q    <= RefIdle;
      ref_clk_cntr_q <= 16'h0;
    end else if (!ref_stall) begin
      ref_state_q    <= ref_state_d;
      ref_clk_cntr_q <= ref_clk_cntr_d;
    end
  end

  assign ref_state_changing      = (ref_state_q != ref_state_d);
  assign ref_byte_starting_cpha0 = ~sw_rst_i & ref_state_changing &
                                   ((ref_state_d == RefWaitLead) |
                                    (ref_state_d == RefInternalClkLow & ref_bit_cntr_q == 0));
  assign ref_bit_shifting_cpha0  = ~sw_rst_i & ref_state_changing &
                                   (ref_state_d == RefInternalClkLow & ref_bit_cntr_q != 0);
  assign ref_byte_ending_cpha0   = ~sw_rst_i & ref_state_changing &
                                   (ref_state_q == RefInternalClkHigh & ref_bit_cntr_q == 0);
  assign ref_byte_starting_cpha1 = ~sw_rst_i & ref_state_changing &
                                   (ref_state_d == RefInternalClkHigh & ref_bit_cntr_q == 0);
  assign ref_bit_shifting_cpha1  = ~sw_rst_i & ref_state_changing &
                                   (ref_state_d == RefInternalClkHigh & ref_bit_cntr_q != 0);
  assign ref_byte_ending_cpha1   = ~sw_rst_i & ref_state_changing &
                                   (ref_state_q == RefInternalClkLow & ref_bit_cntr_q == 0);

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      ref_seg_rd_en_cpha1 <= 1'b0;
    end else if (ref_state_changing && !ref_stall) begin
      ref_seg_rd_en_cpha1 <= ref_cmd_rd_en_q;
    end
  end

  assign ref_byte_starting = (ref_cpha == 1'b0) ? ref_byte_starting_cpha0 : ref_byte_starting_cpha1;
  assign ref_byte_ending   = (ref_cpha == 1'b0) ? ref_byte_ending_cpha0   : ref_byte_ending_cpha1;
  assign ref_bit_shifting  = (ref_cpha == 1'b0) ? ref_bit_shifting_cpha0  : ref_bit_shifting_cpha1;
  assign ref_speed         = ref_cmd_speed_q;
  assign ref_seg_rd_en     = (ref_cpha == 1'b0) ? ref_cmd_rd_en_q         : ref_seg_rd_en_cpha1;

  logic [2:0] ref_shift_size, ref_start_bit;
  always_comb begin
    if (!ref_cmd_rd_en_d && !ref_cmd_wr_en_d) begin
      ref_shift_size = 3'h0;
      ref_start_bit  = 3'h0;
    end else begin
      unique case (ref_cmd_speed_d)
        Standard: begin ref_shift_size = 3'h1; ref_start_bit = 3'h7; end
        Dual:     begin ref_shift_size = 3'h2; ref_start_bit = 3'h6; end
        Quad:     begin ref_shift_size = 3'h4; ref_start_bit = 3'h4; end
        default:  begin ref_shift_size = 3'h1; ref_start_bit = 3'h1; end
      endcase
    end
  end

  assign ref_bit_cntr_d  = sw_rst_i          ? 3'h0 :
                           !ref_fsm_en       ? ref_bit_cntr_q :
                           ref_byte_starting ? ref_start_bit :
                           ref_bit_shifting  ? ref_bit_cntr_q - ref_shift_size :
                           ref_bit_cntr_q;
  assign ref_last_bit    = (ref_bit_cntr_q == 3'h0);
  assign ref_last_byte   = (ref_byte_cntr_q == 20'h0);
  logic ref_dec_byte_cntr;
  assign ref_dec_byte_cntr = (ref_cpha_q == 1'b0) ? ref_byte_ending_cpha0 : ref_byte_ending_cpha1;
  assign ref_byte_cntr_d = sw_rst_i          ? 20'h0 :
                           !ref_fsm_en       ? ref_byte_cntr_q :
                           ref_new_command   ? ref_cmd_len_d :
                           ref_dec_byte_cntr ? (ref_byte_cntr_q - 20'd1) :
                           ref_byte_cntr_q;

  always_comb begin
    if (sw_rst_i) begin
      ref_wait_cntr_d = 4'b0;
    end else if (!ref_fsm_en) begin
      ref_wait_cntr_d = ref_wait_cntr_q;
    end else if (ref_state_changing) begin
      unique case (ref_state_d)
        RefWaitLead:  ref_wait_cntr_d = ref_csnlead;
        RefWaitTrail: ref_wait_cntr_d = ref_csntrail;
        RefWaitIdle:  ref_wait_cntr_d = ref_csnidle;
        RefCSBSwitch: ref_wait_cntr_d = ref_csnidle;
        default:      ref_wait_cntr_d = 4'b0;
      endcase
    end else if (ref_wait_cntr_q == 4'h0) begin
      ref_wait_cntr_d = 4'h0;
    end else begin
      ref_wait_cntr_d = ref_wait_cntr_q - 4'd1;
    end
  end

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      ref_bit_cntr_q         <= 3'h0;
      ref_byte_cntr_q        <= 20'h0;
      ref_wait_cntr_q        <= 4'h0;
      ref_sample_en_q        <= 1'b0;
      ref_sample_en_q2       <= 1'b0;
      ref_sck_q              <= 1'b0;
      ref_csb_q              <= '1;
      ref_cmd_wr_en_last_bit <= 1'b0;
    end else begin
      if (!ref_stall) begin
        ref_bit_cntr_q  <= ref_bit_cntr_d;
        ref_byte_cntr_q <= ref_byte_cntr_d;
        ref_wait_cntr_q <= ref_wait_cntr_d;
        ref_sck_q       <= ref_sck_d;
      end
      if (ref_fsm_en && !ref_stall) begin
        ref_sample_en_q  <= ref_sample_en_d;
        ref_sample_en_q2 <= ref_sample_en_q;
      end
      for (int ii = 0; ii < NumCS; ii++) begin
        if (ref_csid != ii) ref_csb_q[ii] <= 1'b1;
        else if (!ref_stall) ref_csb_q[ii] <= ref_csb_single_d;
      end
      if (ref_is_idle || ref_byte_ending) begin
        ref_cmd_wr_en_last_bit <= 1'b0;
      end else if (ref_cmd_wr_en_q & ref_last_bit) begin
        ref_cmd_wr_en_last_bit <= 1'b1;
      end
    end
  end

  assign ref_wr_en_int     = ref_byte_starting & ref_cmd_wr_en_d;
  assign ref_shift_en_int  = ref_bit_shifting;
  assign ref_rd_en_int     = ref_byte_ending & ref_seg_rd_en;
  assign ref_sample_en_d   = ref_byte_starting | ref_shift_en;
  assign ref_sample_en_int = ref_full_cyc ? ref_sample_en_q2 : ref_sample_en_q;
  assign ref_last_read     = (ref_byte_cntr_q == 20'h0) & ref_rd_en & ref_rd_ready;
  assign ref_last_write    = (ref_byte_cntr_d == 20'h0) & ref_wr_en & ref_wr_ready;

  always_comb begin
    unique case (ref_state_d)
      RefWaitLead, RefInternalClkLow, RefInternalClkHigh, RefIdleCSBActive, RefWaitTrail:
        ref_csb_single_d = 1'b0;
      default:
        ref_csb_single_d = 1'b1;
    endcase
  end

  assign ref_sck_d = ref_cpol ? (ref_state_d != RefInternalClkHigh) : (ref_state_d == RefInternalClkHigh);
  assign ref_sck_o = ref_sck_q;
  assign ref_csb_o = ref_csb_q;

  always_comb begin
    if (&ref_csb_o) begin
      ref_sd_en_o = 4'h0;
    end else begin
      unique case (ref_speed)
        Standard: begin
          ref_sd_en_o[0]   = ref_cmd_wr_en_q | ref_cmd_wr_en_last_bit;
          ref_sd_en_o[1]   = 1'b0;
          ref_sd_en_o[3:2] = 2'b00;
        end
        Dual: begin
          ref_sd_en_o[1:0] = {2{ref_cmd_wr_en_q}};
          ref_sd_en_o[3:2] = 2'b00;
        end
        Quad: begin
          ref_sd_en_o[3:0] = {4{ref_cmd_wr_en_q}};
        end
        default: begin
          ref_sd_en_o[3:0] = 4'h0;
        end
      endcase
    end
  end

  initial begin
    clk_i = 1'b0;
    forever #5 clk_i = ~clk_i;
  end

  int cycle_cnt;

  task automatic check_outputs(string tag);
    #1;
    if ( ({dut_command_ready_o, dut_tx_ready_o, dut_tx_byte_select_full_o, dut_rx_data_o, dut_rx_valid_o,
           dut_sck_o, dut_csb_o, dut_sd_o, dut_sd_en_o, dut_rx_stall_o, dut_tx_stall_o, dut_active_o} ^
          {dut_command_ready_o, dut_tx_ready_o, dut_tx_byte_select_full_o, dut_rx_data_o, dut_rx_valid_o,
           dut_sck_o, dut_csb_o, dut_sd_o, dut_sd_en_o, dut_rx_stall_o, dut_tx_stall_o, dut_active_o}) !== '0 ) begin
      $display("FAIL [%s] cycle=%0d: X/Z on outputs", tag, cycle_cnt);
      $finish(1);
    end
    if (dut_command_ready_o !== ref_command_ready_o) begin
      $display("FAIL [%s] cycle=%0d: command_ready_o got=%b exp=%b", tag, cycle_cnt, dut_command_ready_o, ref_command_ready_o);
      $finish(1);
    end
    if (dut_tx_ready_o !== ref_tx_ready_o || dut_tx_byte_select_full_o !== ref_tx_byte_select_full_o) begin
      $display("FAIL [%s] cycle=%0d: tx_ready/full got=(%b,%b) exp=(%b,%b)",
               tag, cycle_cnt, dut_tx_ready_o, dut_tx_byte_select_full_o, ref_tx_ready_o, ref_tx_byte_select_full_o);
      $finish(1);
    end
    if (dut_rx_valid_o !== ref_rx_valid_o || (ref_rx_valid_o && (dut_rx_data_o !== ref_rx_data_o))) begin
      $display("FAIL [%s] cycle=%0d: rx got=(vld=%b, data=0x%08x) exp=(vld=%b, data=0x%08x)",
               tag, cycle_cnt, dut_rx_valid_o, dut_rx_data_o, ref_rx_valid_o, ref_rx_data_o);
      $finish(1);
    end
    if (dut_sck_o !== ref_sck_o || dut_csb_o !== ref_csb_o || dut_sd_en_o !== ref_sd_en_o) begin
      $display("FAIL [%s] cycle=%0d: spi ctrl got=(sck=%b, csb=%b, sd_en=0x%x) exp=(sck=%b, csb=%b, sd_en=0x%x)",
               tag, cycle_cnt, dut_sck_o, dut_csb_o, dut_sd_en_o, ref_sck_o, ref_csb_o, ref_sd_en_o);
      $finish(1);
    end
    if ((|ref_sd_en_o) && ((dut_sd_o & ref_sd_en_o) !== (ref_sd_o & ref_sd_en_o))) begin
      $display("FAIL [%s] cycle=%0d: sd_o got=0x%x exp=0x%x (sd_en=0x%x)",
               tag, cycle_cnt, dut_sd_o, ref_sd_o, ref_sd_en_o);
      $finish(1);
    end
    if (dut_rx_stall_o !== ref_rx_stall_o || dut_tx_stall_o !== ref_tx_stall_o || dut_active_o !== ref_active_o) begin
      $display("FAIL [%s] cycle=%0d: status got=(rx_stall=%b, tx_stall=%b, active=%b) exp=(%b,%b,%b)",
               tag, cycle_cnt, dut_rx_stall_o, dut_tx_stall_o, dut_active_o,
               ref_rx_stall_o, ref_tx_stall_o, ref_active_o);
      $finish(1);
    end
  endtask

  task automatic step_cycle(string tag);
    check_outputs(tag);
    @(posedge clk_i);
    cycle_cnt++;
    if (cycle_cnt > 25000) begin
      $display("FAIL [%s]: watchdog timeout at cycle %0d", tag, cycle_cnt);
      $finish(1);
    end
  endtask

  logic [31:0] prng;
  function automatic logic [31:0] next_rand();
    prng = prng ^ (prng << 13);
    prng = prng ^ (prng >> 17);
    prng = prng ^ (prng << 5);
    return prng;
  endfunction

  task automatic build_cmd(
    output command_t cmd,
    input logic [15:0] clkdiv,
    input logic        cpol,
    input logic        cpha,
    input logic        full_cyc,
    input logic [3:0]  csnidle,
    input logic [3:0]  csnlead,
    input logic [3:0]  csntrail,
    input logic [19:0] len,
    input logic        csaat,
    input logic [1:0]  speed,
    input logic        wr_en,
    input logic        rd_en
  );
    cmd.configopts.clkdiv   = clkdiv;
    cmd.configopts.cpol     = cpol;
    cmd.configopts.cpha     = cpha;
    cmd.configopts.full_cyc = full_cyc;
    cmd.configopts.csnidle  = csnidle;
    cmd.configopts.csnlead  = csnlead;
    cmd.configopts.csntrail = csntrail;
    cmd.segment.len         = len;
    cmd.segment.csaat       = csaat;
    cmd.segment.speed       = speed;
    cmd.segment.cmd_wr_en   = wr_en;
    cmd.segment.cmd_rd_en   = rd_en;
  endtask

  initial begin
    prng            = 32'(SEED) ^ 32'hA5A5_5A5A;
    if (prng == 0) prng = 32'h2468_ACE1;
    cycle_cnt       = 0;
    rst_ni          = 1'b0;
    command_i       = '0;
    command_csid_i  = '0;
    command_valid_i = 1'b0;
    en_i            = 1'b1;
    tx_data_i       = 32'h0;
    tx_be_i         = 4'hF;
    tx_valid_i      = 1'b0;
    rx_ready_i      = 1'b1;
    sw_rst_i        = 1'b0;
    sd_i            = 4'h5;

    repeat (4) @(posedge clk_i);
    rst_ni = 1'b1;
    step_cycle("post_reset");

    // -----------------------------------------------------------------------
    // Directed Test 1: Partial-word TX write segment (1 byte out of 4 enabled bytes)
    // followed by a Standard-mode read segment (CSAAT=1 -> 0) and a second TX word
    // -----------------------------------------------------------------------
    tx_data_i  = 32'hDDCC_BBAA;
    tx_be_i    = 4'b1111;
    tx_valid_i = 1'b1;
    while (!ref_tx_ready_o) step_cycle("dir1_feed_tx0");
    step_cycle("dir1_accept_tx0");
    tx_valid_i = 1'b0;

    build_cmd(command_i, 16'd0, 1'b0, 1'b0, 1'b0, 4'd1, 4'd1, 4'd1, 20'd0, 1'b1, Standard, 1'b1, 1'b0);
    command_valid_i = 1'b1;
    while (!ref_command_ready_o) step_cycle("dir1_wait_cmd0");
    step_cycle("dir1_accept_cmd0");

    build_cmd(command_i, 16'd0, 1'b0, 1'b0, 1'b0, 4'd1, 4'd1, 4'd1, 20'd1, 1'b0, Standard, 1'b0, 1'b1);
    while (!ref_command_ready_o) begin
      sd_i = next_rand()[3:0];
      step_cycle("dir1_wait_cmd1");
    end
    step_cycle("dir1_accept_cmd1");
    command_valid_i = 1'b0;

    // Wait for read segment to complete
    while (ref_active_o) begin
      sd_i = next_rand()[3:0];
      step_cycle("dir1_wait_rd_done");
    end
    repeat (6) step_cycle("dir1_drain_rx");

    tx_data_i  = 32'h4433_2211;
    tx_be_i    = 4'b1111;
    tx_valid_i = 1'b1;
    while (!ref_tx_ready_o) step_cycle("dir1_feed_tx1");
    step_cycle("dir1_accept_tx1");
    tx_valid_i = 1'b0;

    build_cmd(command_i, 16'd0, 1'b0, 1'b0, 1'b0, 4'd1, 4'd1, 4'd1, 20'd1, 1'b0, Quad, 1'b1, 1'b0);
    command_valid_i = 1'b1;
    while (!ref_command_ready_o) step_cycle("dir1_wait_cmd2");
    step_cycle("dir1_accept_cmd2");
    command_valid_i = 1'b0;
    while (ref_active_o) step_cycle("dir1_run_cmd2");

    // -----------------------------------------------------------------------
    // Directed Test 2: Simultaneous RX buffer pop (rx_valid_sr & rx_ready_sr)
    // and shift-register push (rd_en_i & rd_ready_o)
    // When u_merge holds 3 bytes and rx_buf_q holds the 4th byte while rx_ready_i=0,
    // wait until u_shift_reg is on the cycle where rd_en_i=1, or run back-to-back
    // Quad read bytes with clkdiv=0 while u_merge accepts rx_buf_q on the exact rd_en_i cycle!
    // Notice: when u_merge has 4 bytes (word_valid_o=1) and rx_ready_i=0, byte_ready_o=0!
    // Then rx_buf_q fills with byte 5 (rx_buf_valid_q=1).
    // Next, when the FSM reaches the final bit of byte 6 (rd_en_int=1), if rx_ready_i=0, rx_stall_o=1!
    // On the NEXT cycle, while rd_en_int=1 is still held by the stalled FSM, we assert rx_ready_i=1!
    // Wait: u_merge clears depth_q on word_ready_i && word_valid_o, so on the following cycle
    // byte_ready_o becomes 1 while rd_en_int is STILL 1! That triggers (rx_valid_sr & rx_ready_sr)
    // AND (rd_en_i & rd_ready_o) in the EXACT SAME CYCLE!
    // -----------------------------------------------------------------------
    rx_ready_i = 1'b0;
    build_cmd(command_i, 16'd0, 1'b0, 1'b0, 1'b0, 4'd0, 4'd0, 4'd0, 20'd5, 1'b0, Quad, 1'b0, 1'b1);
    command_valid_i = 1'b1;
    while (!ref_command_ready_o) step_cycle("dir2_wait_cmd");
    step_cycle("dir2_accept_cmd");
    command_valid_i = 1'b0;

    while (!ref_rx_stall_o) begin
      sd_i = next_rand()[3:0];
      step_cycle("dir2_wait_rx_stall");
    end
    step_cycle("dir2_stalled_0");
    rx_ready_i = 1'b1;
    while (ref_active_o) begin
      sd_i = next_rand()[3:0];
      step_cycle("dir2_drain_after_stall");
    end
    repeat (6) step_cycle("dir2_post_drain");

    // -----------------------------------------------------------------------
    // Randomized Multi-Segment Stress Test
    // -----------------------------------------------------------------------
    for (int seg = 0; seg < 24; seg++) begin
      logic [31:0] r;
      logic [15:0] clkdiv;
      logic        cpol, cpha, full_cyc, csaat, wr_en, rd_en;
      logic [1:0]  speed;
      logic [19:0] len;

      r        = next_rand();
      clkdiv   = 16'(r[1:0]);
      cpol     = r[2];
      cpha     = r[3];
      full_cyc = cpha ? 1'b0 : r[4];
      speed    = (r[6:5] == 2'd3) ? Quad : r[6:5];
      if (speed == Standard) begin
        wr_en = r[7];
        rd_en = r[8];
      end else begin
        wr_en = r[7];
        rd_en = ~r[7] & r[8];
      end
      len   = 20'(r[10:9]);
      csaat = (seg % 3 != 2);

      build_cmd(command_i, clkdiv, cpol, cpha, full_cyc, r[14:13], r[16:15], r[18:17], len, csaat, speed, wr_en, rd_en);
      command_valid_i = 1'b1;

      for (int cyc = 0; cyc < 300; cyc++) begin
        logic [31:0] rc;
        rc         = next_rand();
        sd_i       = rc[3:0];
        tx_valid_i = (rc[5:4] != 2'b00);
        if (ref_tx_ready_o && tx_valid_i) begin
          tx_data_i = rc;
          tx_be_i   = (rc[9:6] == 4'h0) ? 4'b0101 : rc[9:6];
        end
        rx_ready_i = (rc[11:10] != 2'b00);
        if (command_valid_i && ref_command_ready_o) begin
          step_cycle("rand_cmd_accept");
          command_valid_i = 1'b0;
        end else begin
          step_cycle("rand_run");
        end
        if (!command_valid_i && (ref_state_q == RefIdle || ref_state_q == RefIdleCSBActive)) begin
          break;
        end
      end

      if (seg == 11) begin
        sw_rst_i        = 1'b1;
        tx_valid_i      = 1'b0;
        command_valid_i = 1'b0;
        step_cycle("sw_rst_assert");
        sw_rst_i        = 1'b0;
        step_cycle("sw_rst_deassert");
      end
    end

    // Directed Test 3: Assert sw_rst_i during Standard-mode write last_bit (when cmd_wr_en_last_bit==1)
    // and then issue a Standard-mode READ segment (cmd_wr_en_q==0, full_cyc=1, clkdiv=1) to verify sd_en_o[0] is 0 and full_cyc sampling!
    sw_rst_i        = 1'b1;
    tx_valid_i      = 1'b0;
    command_valid_i = 1'b0;
    rx_ready_i      = 1'b1;
    step_cycle("dir3_pre_rst");
    sw_rst_i        = 1'b0;
    step_cycle("dir3_pre_rst_done");
    tx_data_i  = 32'hA5A5_5A5A;
    tx_be_i    = 4'b1111;
    tx_valid_i = 1'b1;
    while (!ref_tx_ready_o) step_cycle("dir3_feed_tx");
    step_cycle("dir3_accept_tx");
    tx_valid_i = 1'b0;
    build_cmd(command_i, 16'd1, 1'b0, 1'b0, 1'b1, 4'd1, 4'd1, 4'd1, 20'd0, 1'b0, Standard, 1'b1, 1'b0);
    command_valid_i = 1'b1;
    while (!ref_command_ready_o) step_cycle("dir3_wait_cmd");
    step_cycle("dir3_accept_cmd");
    command_valid_i = 1'b0;
    while (!ref_cmd_wr_en_last_bit) step_cycle("dir3_wait_last_bit");
    // Now cmd_wr_en_last_bit is 1 and clk_cntr_q != 0; assert sw_rst_i!
    sw_rst_i = 1'b1;
    step_cycle("dir3_sw_rst_on_last_bit");
    sw_rst_i = 1'b0;
    step_cycle("dir3_post_sw_rst");
    // Issue a Standard-mode READ command with full_cyc=1, clkdiv=1; sd_en_o[0] must remain 0!
    build_cmd(command_i, 16'd1, 1'b0, 1'b0, 1'b1, 4'd1, 4'd1, 4'd1, 20'd0, 1'b0, Standard, 1'b0, 1'b1);
    command_valid_i = 1'b1;
    while (!ref_command_ready_o) step_cycle("dir3_wait_rd_cmd");
    step_cycle("dir3_accept_rd_cmd");
    command_valid_i = 1'b0;
    while (ref_active_o) begin
      sd_i = next_rand()[3:0];
      step_cycle("dir3_run_rd_cmd");
    end
    repeat (8) begin
      sd_i = next_rand()[3:0];
      step_cycle("dir3_drain_rd_cmd");
    end

    tx_valid_i      = 1'b0;
    command_valid_i = 1'b0;
    rx_ready_i      = 1'b1;
    repeat (10) step_cycle("final_drain");

    $display("PASS spi_host_core seed=%0d cycles=%0d", SEED, cycle_cnt);
    $finish(0);
  end

endmodule
