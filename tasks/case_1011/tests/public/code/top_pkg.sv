// Copyright lowRISC contributors (OpenTitan project).
// Licensed under the Apache License, Version 2.0, see LICENSE for details.
// SPDX-License-Identifier: Apache-2.0

package top_pkg;
  localparam int TL_AW  = 32;
  localparam int TL_DW  = 32;
  localparam int TL_AIW = 8;
  localparam int TL_DIW = 1;
  localparam int TL_DUW = 4;
  localparam int TL_DBW = (TL_DW >> 3);
  localparam int TL_SZW = $clog2($clog2(TL_DBW) + 1);
endpackage
