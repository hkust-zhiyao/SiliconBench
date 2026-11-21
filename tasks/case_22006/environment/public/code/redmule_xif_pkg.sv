// Copyright 2025 ETH Zurich and University of Bologna.
// Solderpad Hardware License, Version 0.51, see LICENSE for details.
// SPDX-License-Identifier: SHL-0.51

`ifndef REDMULE_XIF_PKG_SV
`define REDMULE_XIF_PKG_SV

`define REDMULE_XIF_TYPEDEF_ALL(__prefix, __num_harts, __id_width) \
  typedef struct packed { \
    logic [31:0]                                            instr; \
    logic [((__num_harts) > 1 ? $clog2(__num_harts) : 1)-1:0] hartid; \
    logic [(__id_width)-1:0]                                id; \
  } ``__prefix``_issue_req_t; \
  typedef struct packed { \
    logic       accept; \
    logic       writeback; \
    logic [2:0] register_read; \
  } ``__prefix``_issue_resp_t; \
  typedef struct packed { \
    logic [((__num_harts) > 1 ? $clog2(__num_harts) : 1)-1:0] hartid; \
    logic [(__id_width)-1:0]                                id; \
    logic [2:0][31:0]                                       rs; \
    logic [2:0]                                             rs_valid; \
  } ``__prefix``_register_t; \
  typedef struct packed { \
    logic [((__num_harts) > 1 ? $clog2(__num_harts) : 1)-1:0] hartid; \
    logic [(__id_width)-1:0]                                id; \
    logic                                                   commit_kill; \
  } ``__prefix``_commit_t; \
  typedef struct packed { \
    logic [((__num_harts) > 1 ? $clog2(__num_harts) : 1)-1:0] hartid; \
    logic [(__id_width)-1:0]                                id; \
    logic [31:0]                                            data; \
    logic [4:0]                                             rd; \
    logic                                                   we; \
  } ``__prefix``_result_t;

package redmule_xif_pkg;
  parameter int unsigned DefaultXifNumHarts = 2;
  parameter int unsigned DefaultXifIdWidth  = 4;

  `REDMULE_XIF_TYPEDEF_ALL(default_xif, DefaultXifNumHarts, DefaultXifIdWidth)
endpackage : redmule_xif_pkg

`endif
