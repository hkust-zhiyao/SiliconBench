// Copyright 2018 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51
// Derived from pulp-platform/riscv-dbg dm_pkg.sv

package dm;
  localparam logic [3:0]  DataCount = 4'h2;
  localparam logic [11:0] DataAddr  = 12'h380;

  typedef enum logic [1:0] {
    PRIV_LVL_M = 2'b11,
    PRIV_LVL_H = 2'b10,
    PRIV_LVL_S = 2'b01,
    PRIV_LVL_U = 2'b00
  } priv_lvl_t;

  typedef struct packed {
    logic [31:24] zero1;
    logic [23:20] nscratch;
    logic [19:17] zero0;
    logic         dataaccess;
    logic [15:12] datasize;
    logic [11:0]  dataaddr;
  } hartinfo_t;

  typedef struct packed {
    logic [31:28] xdebugver;
    logic [27:16] zero2;
    logic         ebreakm;
    logic         zero1;
    logic         ebreaks;
    logic         ebreaku;
    logic         stepie;
    logic         stopcount;
    logic         stoptime;
    logic [8:6]   cause;
    logic         zero0;
    logic         mprven;
    logic         nmip;
    logic         step;
    priv_lvl_t    prv;
  } dcsr_t;

  localparam logic [63:0] HaltAddress      = 64'h800;
  localparam logic [63:0] ResumeAddress    = HaltAddress + 4;
  localparam logic [63:0] ExceptionAddress = HaltAddress + 8;

  localparam logic [2:0] CauseBreakpoint = 3'h1;
  localparam logic [2:0] CauseTrigger    = 3'h2;
  localparam logic [2:0] CauseRequest    = 3'h3;
  localparam logic [2:0] CauseSingleStep = 3'h4;
endpackage
