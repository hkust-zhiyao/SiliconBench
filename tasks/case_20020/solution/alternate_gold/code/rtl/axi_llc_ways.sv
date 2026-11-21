// Copyright 2022 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

module axi_llc_ways #(
  parameter axi_llc_pkg::llc_cfg_t Cfg          = axi_llc_pkg::llc_cfg_t'{default: '0},
  parameter type                   way_inp_t    = logic,
  parameter type                   way_oup_t    = logic,
  parameter bit                    PrintSramCfg = 0
) (
  input  logic           clk_i,
  input  logic           rst_ni,
  input  logic           test_i,
  input  way_inp_t [3:0] way_inp_i,
  input  logic     [3:0] way_inp_valid_i,
  output logic     [3:0] way_inp_ready_o,
  output way_oup_t       evict_way_out_o,
  output logic           evict_way_out_valid_o,
  input  logic           evict_way_out_ready_i,
  output way_oup_t       read_way_out_o,
  output logic           read_way_out_valid_o,
  input  logic           read_way_out_ready_i
);
  localparam int unsigned SelIdxWidth = cf_math_pkg::idx_width(Cfg.SetAssociativity);
  typedef logic [SelIdxWidth-1:0]          way_sel_t;
  typedef logic [Cfg.SetAssociativity-1:0] way_ind_t;

  logic [3:0] inp_valid, inp_ready;

  way_inp_t [Cfg.SetAssociativity-1:0] xbar_inp,      way_inp;
  logic     [Cfg.SetAssociativity-1:0] xbar_valid,    way_inp_valid;
  logic     [Cfg.SetAssociativity-1:0] xbar_ready,    way_inp_ready;

  way_oup_t [Cfg.SetAssociativity-1:0] raw_way_out,   way_out;
  logic     [Cfg.SetAssociativity-1:0] raw_out_valid, way_out_valid;
  logic     [Cfg.SetAssociativity-1:0] raw_out_ready, way_out_ready;

  way_oup_t evict_sel_out,   read_sel_out;
  logic     evict_sel_valid, evict_sel_ready;
  logic     read_sel_valid,  read_sel_ready;

  way_sel_t [3:0] way_sel;

  way_ind_t e_switch,       r_switch;
  logic     e_switch_full,  r_switch_full;
  logic     e_switch_empty, r_switch_empty;
  logic     e_switch_push,  r_switch_push;
  logic     e_switch_pop,   r_switch_pop;

  assign inp_valid[axi_llc_pkg::EvictUnit]       = ~e_switch_full & way_inp_valid_i[axi_llc_pkg::EvictUnit];
  assign way_inp_ready_o[axi_llc_pkg::EvictUnit] = ~e_switch_full & inp_ready[axi_llc_pkg::EvictUnit];
  assign inp_valid[axi_llc_pkg::RefilUnit]       = way_inp_valid_i[axi_llc_pkg::RefilUnit];
  assign way_inp_ready_o[axi_llc_pkg::RefilUnit] = inp_ready[axi_llc_pkg::RefilUnit];
  assign inp_valid[axi_llc_pkg::WChanUnit]       = way_inp_valid_i[axi_llc_pkg::WChanUnit];
  assign way_inp_ready_o[axi_llc_pkg::WChanUnit] = inp_ready[axi_llc_pkg::WChanUnit];
  assign inp_valid[axi_llc_pkg::RChanUnit]       = ~r_switch_full & way_inp_valid_i[axi_llc_pkg::RChanUnit];
  assign way_inp_ready_o[axi_llc_pkg::RChanUnit] = ~r_switch_full & inp_ready[axi_llc_pkg::RChanUnit];

  for (genvar i = 0; unsigned'(i) < 32'd4; i++) begin : gen_connect_demux
    onehot_to_bin #(
      .ONEHOT_WIDTH ( Cfg.SetAssociativity )
    ) i_onehot_to_bin (
      .onehot ( way_inp_i[i].way_ind ),
      .bin    ( way_sel[i]           )
    );
  end

  stream_xbar #(
    .NumInp      ( 32'd4                ),
    .NumOut      ( Cfg.SetAssociativity ),
    .payload_t   ( way_inp_t            ),
    .OutSpillReg ( 1'b0                 ),
    .ExtPrio     ( 1'b0                 ),
    .AxiVldRdy   ( 1'b1                 ),
    .LockIn      ( 1'b1                 )
  ) i_stream_xbar (
    .clk_i, .rst_ni,
    .flush_i ( '0          ),
    .rr_i    ( '0          ),
    .data_i  ( way_inp_i   ),
    .sel_i   ( way_sel     ),
    .valid_i ( inp_valid   ),
    .ready_o ( inp_ready   ),
    .data_o  ( xbar_inp    ),
    .idx_o   (             ),
    .valid_o ( xbar_valid  ),
    .ready_i ( xbar_ready  )
  );

  for (genvar j = 0; unsigned'(j) < Cfg.SetAssociativity; j++) begin : gen_data_ways
    spill_register #(
      .T      ( way_inp_t ),
      .Bypass ( 1'b0      )
    ) i_way_in_pipe (
      .clk_i, .rst_ni,
      .valid_i ( xbar_valid[j]    ),
      .ready_o ( xbar_ready[j]    ),
      .data_i  ( xbar_inp[j]      ),
      .valid_o ( way_inp_valid[j] ),
      .ready_i ( way_inp_ready[j] ),
      .data_o  ( way_inp[j]       )
    );

    axi_llc_data_way #(
      .Cfg          ( Cfg          ),
      .way_inp_t    ( way_inp_t    ),
      .way_oup_t    ( way_oup_t    ),
      .PrintSramCfg ( PrintSramCfg )
    ) i_data_way (
      .clk_i, .rst_ni, .test_i,
      .inp_i      ( way_inp[j]       ),
      .inp_valid_i( way_inp_valid[j] ),
      .inp_ready_o( way_inp_ready[j] ),
      .out_o      ( raw_way_out[j]   ),
      .out_valid_o( raw_out_valid[j] ),
      .out_ready_i( raw_out_ready[j] )
    );

    stream_register #(
      .T ( way_oup_t )
    ) i_way_out_reg (
      .clk_i      ( clk_i            ),
      .rst_ni     ( rst_ni           ),
      .clr_i      ( 1'b0             ),
      .testmode_i ( test_i           ),
      .valid_i    ( raw_out_valid[j] ),
      .ready_o    ( raw_out_ready[j] ),
      .data_i     ( raw_way_out[j]   ),
      .valid_o    ( way_out_valid[j] ),
      .ready_i    ( way_out_ready[j] ),
      .data_o     ( way_out[j]       )
    );
  end

  assign r_switch_push = way_inp_valid_i[axi_llc_pkg::RChanUnit] & way_inp_ready_o[axi_llc_pkg::RChanUnit];
  assign e_switch_push = way_inp_valid_i[axi_llc_pkg::EvictUnit] & way_inp_ready_o[axi_llc_pkg::EvictUnit];

  fifo_v3 #(
    .FALL_THROUGH ( 1'b0      ),
    .DEPTH        ( 32'd16    ),
    .dtype        ( way_ind_t )
  ) i_r_switch_fifo (
    .clk_i, .rst_ni,
    .flush_i    ( '0                                        ),
    .testmode_i ( test_i                                    ),
    .full_o     ( r_switch_full                             ),
    .empty_o    ( r_switch_empty                            ),
    .usage_o    (                                           ),
    .data_i     ( way_inp_i[axi_llc_pkg::RChanUnit].way_ind ),
    .push_i     ( r_switch_push                             ),
    .data_o     ( r_switch                                  ),
    .pop_i      ( r_switch_pop                              )
  );
  fifo_v3 #(
    .FALL_THROUGH ( 1'b0      ),
    .DEPTH        ( 32'd16    ),
    .dtype        ( way_ind_t )
  ) i_e_switch_fifo (
    .clk_i, .rst_ni,
    .flush_i    ( '0                                        ),
    .testmode_i ( test_i                                    ),
    .full_o     ( e_switch_full                             ),
    .empty_o    ( e_switch_empty                            ),
    .usage_o    (                                           ),
    .data_i     ( way_inp_i[axi_llc_pkg::EvictUnit].way_ind ),
    .push_i     ( e_switch_push                             ),
    .data_o     ( e_switch                                  ),
    .pop_i      ( e_switch_pop                              )
  );

  always_comb begin
    evict_sel_out   = '0;
    evict_sel_valid = 1'b0;
    e_switch_pop    = 1'b0;
    read_sel_out    = '0;
    read_sel_valid  = 1'b0;
    r_switch_pop    = 1'b0;
    way_out_ready   = '0;
    for (int unsigned m = 0; m < Cfg.SetAssociativity; m++) begin
      if (e_switch[m] && !e_switch_empty) begin
        if (way_out_valid[m] && (way_out[m].cache_unit == axi_llc_pkg::EvictUnit)) begin
          evict_sel_out   = way_out[m];
          evict_sel_valid = 1'b1;
          if (evict_sel_ready) begin
            way_out_ready[m] = 1'b1;
            e_switch_pop     = 1'b1;
          end
        end
      end
      if (r_switch[m] && !r_switch_empty) begin
        if (way_out_valid[m] && (way_out[m].cache_unit == axi_llc_pkg::RChanUnit)) begin
          read_sel_out   = way_out[m];
          read_sel_valid = 1'b1;
          if (read_sel_ready) begin
            way_out_ready[m] = 1'b1;
            r_switch_pop     = 1'b1;
          end
        end
      end
    end
  end

  stream_register #(
    .T ( way_oup_t )
  ) i_evict_out_reg (
    .clk_i      ( clk_i                 ),
    .rst_ni     ( rst_ni                ),
    .clr_i      ( 1'b0                  ),
    .testmode_i ( test_i                ),
    .valid_i    ( evict_sel_valid       ),
    .ready_o    ( evict_sel_ready       ),
    .data_i     ( evict_sel_out         ),
    .valid_o    ( evict_way_out_valid_o ),
    .ready_i    ( evict_way_out_ready_i ),
    .data_o     ( evict_way_out_o       )
  );

  stream_register #(
    .T ( way_oup_t )
  ) i_read_out_reg (
    .clk_i      ( clk_i                ),
    .rst_ni     ( rst_ni               ),
    .clr_i      ( 1'b0                 ),
    .testmode_i ( test_i               ),
    .valid_i    ( read_sel_valid       ),
    .ready_o    ( read_sel_ready       ),
    .data_i     ( read_sel_out         ),
    .valid_o    ( read_way_out_valid_o ),
    .ready_i    ( read_way_out_ready_i ),
    .data_o     ( read_way_out_o       )
  );
endmodule
