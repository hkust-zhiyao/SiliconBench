# `case_22007`: RedMulE Input Feature Buffer Parameterized Elaboration, Multi-Tile Padding, and 4-State Gate-Level Parity

[Back to Benchmark Root (`README.md`)](../../README.md) | [Full 94-Task Catalog (`TASKS_INDEX.md`)](../../TASKS_INDEX.md) | [`task.toml`](task.toml) | [`instruction.md`](instruction.md) | [`solution/solve.sh`](solution/solve.sh) | [`tests/test.sh`](tests/test.sh) | [`tests/private/grader/run.py`](tests/private/grader/run.py)

---

## 1. Task Overview & Harbor Configuration

| Field | Value |
| :--- | :--- |
| **Task ID** | `case_22007` |
| **Source Silicon Repository** | `pulp-platform/redmule` (`repo_30`) |
| **Engineering Problem Type** | **Gate-Level Equivalence, Security & CDC/RDC** (`PT4_GateLevel_Security_CDC`) |
| **EDA Evaluation Stage** | **Stage 3: Static Timing (STA) & CDC/RDC Closure** (`stage3_sta_cdc`) |
| **Coupled Evaluation Gates** | Stage 1 (Functional RTL Sim) -> Stage 2 (Logic Synthesis & Gate-Level Verification) -> Stage 3 (OpenSTA Single-/Multi-Corner Setup/Hold WNS/TNS & CDC/RDC Closure) |
| **Primary Hardware Domain** | `Vector_GPU_NPU_Accelerators` (Vector_GPU_NPU_Accelerators) |
| **Multi-Domain Tags** | `Vector_GPU_NPU_Accelerators` |
| **Editable Files (`allowed_edits`)** | [`code/x_buffer/redmule_x_buffer.sv`](environment/public/code/x_buffer/redmule_x_buffer.sv), [`code/x_buffer/redmule_x_buffer_scm.sv`](environment/public/code/x_buffer/redmule_x_buffer_scm.sv), [`code/x_buffer/redmule_x_pad_scm.sv`](environment/public/code/x_buffer/redmule_x_pad_scm.sv) (3 files, 539 LOC) |
| **Public Subsystem Context** | 9 RTL files (1859 LOC) |
| **Base Container Image** | `siliconbench-eda:1.0` (`allow_internet = false`, `environment_mode = "separate"`) |
| **PDK / Environment Profile** | **Standard IEEE 1800-2017 SystemVerilog Dual-Simulator + Yosys Slang** |
| **Task-Customized Collateral?** | **No (Uses Shared Base Image)** — Pure RTL/protocol/synthesis check without external PDK Liberty files. |
| **Verifier Timeout & Seeds** | `600s` total (`300s`/seed) across deterministic seeds `[101, 202]` |

---

## 2. Problem Specification (`issue.md`)

# RedMulE Input Feature Buffer (`redmule_x_buffer`) Parameterized Synthesis, Padding, and Gate-Level Parity

## Context
`redmule_x_buffer` (`code/x_buffer/redmule_x_buffer.sv`) and its standard-cell memory (SCM) submodules (`code/x_buffer/redmule_x_pad_scm.sv` and `code/x_buffer/redmule_x_buffer_scm.sv`) buffer and transpose incoming TCDM words (`x_buffer_i`, width `DataW`) into `Width x Height` elements (`x_buffer_o`) for RedMulE's systolic array.

Each tile is loaded row-by-row (`0 .. ctrl_i.width - 1`) into the pad SCM (`Width` rows by `TOT_DEPTH = Height * D` columns, where `D = DataW / (Height * FpWidth)`) under `ctrl_i.load`, asserting `flags_o.full` once `ctrl_i.width` rows are loaded. After `ctrl_i.pad_setup` starts a job, `ctrl_i.slots` columns (a positive multiple of `Height` up to `TOT_DEPTH`) drain into the `2 * Height`-entry output buffer, which shifts one systolic lane per `ctrl_i.h_shift` cycle onto `x_buffer_o[w][h]`. When the final column of the active tile transfers out of the pad buffer, `flags_o.empty` pulses on an active `ctrl_i.h_shift` cycle so the scheduler can update `(ctrl_i.width, ctrl_i.height, ctrl_i.slots)` and preload the next tile after `ctrl_i.rst_w_index`.

## Observed Failures
Multi-configuration regression and post-synthesis 4-state gate-level simulation across `UseLatches = 0` and `UseLatches = 1` expose four issues:
1. **Parameterized Elaboration Failures**: Valid configurations with unit dimensions or single-block depth (`Width == 1`, `Height == 1`, or `D == 1`, with `1 <= Width < MaxDim` and `1 <= TOT_DEPTH < MaxDepth`) fail elaboration/synthesis.
2. **Multi-Tile Streaming & Backpressure Breakdown**: Across single-block (`D == 1`) and deep multi-block (`D >= 3`) configurations under variable `ctrl_i.h_shift`, `ctrl_i.load`, and `ctrl_i.rst_w_index` schedules (including preloaded back-to-back tiles), unread columns are overwritten or tile transitions stall / mis-pulse `flags_o.empty`.
3. **Partial-Tile Zero-Padding Leakage**: Partial tiles (`1 <= ctrl_i.width < Width` and/or `0 <= ctrl_i.height < ctrl_i.slots`) leak stale or uninitialized data onto padded rows (`w >= loaded_width`) or columns (`c >= ctrl_i.height`) across tile drains.
4. **Clear Priority & 4-State `X` Propagation**: Simultaneous `clear_i` with `ctrl_i.load` / `ctrl_i.h_shift` fails to cleanly reset state, and unwritten SCM locations or idle `X` inputs on `x_buffer_i` propagate `X`/`Z` onto `flags_o` and `x_buffer_o` in 4-state post-synthesis gate-level simulation.

## Requirements
Modify only `code/x_buffer/redmule_x_buffer.sv`, `code/x_buffer/redmule_x_buffer_scm.sv`, and `code/x_buffer/redmule_x_pad_scm.sv` (preserving all module port signatures and read-only packages) so that:
- All valid `(DataW, FpFormat, Height, Width, UseLatches)` configurations elaborate and synthesize cleanly in `verilator` and `yosys -m slang` (`check -assert`), including `Height == 1`, `Width == 1`, `D == 1`, and `D >= 3`.
- `UseLatches = 0` synthesizes completely latch-free flip-flop storage, while `UseLatches = 1` preserves `tc_clk_gating` latch-based SCM storage.
- Multi-tile jobs with arbitrary per-tile `(width, height, slots)`, random load/shift stalls, partial row/column zero-padding, asynchronous reset (`!rst_ni`), and synchronous `clear_i` match across RTL and 4-state gate-level simulation with zero `X`/`Z` on `flags_o` or `x_buffer_o`.

---

## 3. Build & Verification Instructions (`BUILD.md`)

# Build & Verification Environment

## Source Files (`code/`)
- Packages & clock gate cell (read-only):
  - `code/fpnew_pkg.sv`
  - `code/hci_package.sv`
  - `code/hwpe_ctrl_package.sv`
  - `code/hwpe_stream_package.sv`
  - `code/redmule_pkg.sv`
  - `code/tc_clk.sv`
- Target RTL modules (editable):
  - `code/x_buffer/redmule_x_pad_scm.sv`
  - `code/x_buffer/redmule_x_buffer_scm.sv`
  - `code/x_buffer/redmule_x_buffer.sv`

## Available Toolchain Commands
1. **SystemVerilog Lint & Functional Simulation (`verilator`)**:
   ```bash
   verilator --lint-only -Wall -Wno-fatal \
     code/fpnew_pkg.sv code/hci_package.sv code/hwpe_ctrl_package.sv \
     code/hwpe_stream_package.sv code/redmule_pkg.sv code/tc_clk.sv \
     code/x_buffer/redmule_x_pad_scm.sv code/x_buffer/redmule_x_buffer_scm.sv \
     code/x_buffer/redmule_x_buffer.sv --top-module redmule_x_buffer
   ```

2. **Elaboration & Gate-Level Synthesis (`yosys -m slang`)**:
   ```bash
   yosys -m slang -p "
     read_slang --top redmule_x_buffer -GHeight=4 -GWidth=4 -GDataW=256 -GUseLatches=1 \
       code/fpnew_pkg.sv code/hci_package.sv code/hwpe_ctrl_package.sv \
       code/hwpe_stream_package.sv code/redmule_pkg.sv code/tc_clk.sv \
       code/x_buffer/redmule_x_pad_scm.sv code/x_buffer/redmule_x_buffer_scm.sv \
       code/x_buffer/redmule_x_buffer.sv;
     synth -top redmule_x_buffer;
     check -assert;
     write_verilog -noattr netlist_lat1.v
   "
   ```

3. **4-State Gate-Level Simulation (`iverilog` + Yosys `simcells.v`)**:
   ```bash
   SIMCELLS="$(dirname "$(dirname "$(which yosys)")")/share/yosys/simcells.v"
   iverilog -g2012 -o gl_sim.vvp "$SIMCELLS" netlist_lat1.v your_gl_tb.sv
   vvp gl_sim.vvp
   ```

---

## 4. Reference Fix Inspection (Buggy Starter vs. Golden Solution Diff)

> Human reviewers can inspect the exact reference bug fix below, or browse full files in [`environment/public/`](environment/public/), [`solution/gold/`](solution/gold/), and [`solution/alternate_gold/`](solution/alternate_gold/).

<details open>
<summary><b>Click to expand/collapse Unified Diff (<code>environment/public/</code> vs. <code>solution/gold/</code>)</b></summary>

```diff
--- a/environment/public/code/x_buffer/redmule_x_buffer.sv (Buggy Starter)
+++ b/solution/gold/code/x_buffer/redmule_x_buffer.sv (Golden Reference)
@@ -28,68 +28,186 @@
   input  logic                           [DataW-1:0] x_buffer_i
 );
 
-localparam int unsigned D         = DataW/(H*FpWidth);
-localparam int unsigned TOT_DEPTH = H*D;
-
-typedef enum logic [2:0] {
-  PRELOAD,
-  FAST_FILL,
-  WAIT_FIRST_READ,
-  WAIT_SHIFT,
-  FILL,
-  PAD_EMPTY
-} redmule_x_state_e;
-
-logic [$clog2(W):0]             w_index_d, w_index_q;
-logic [$clog2(H)-1:0]           h_index_r, h_index_w;
-logic [W-1:0][FpWidth-1:0]         x_pad_q;
-logic [H-1:0][W-1:0][FpWidth-1:0]  x_buffer_q;
-
-logic [$clog2(TOT_DEPTH)-1:0]   pad_r_addr_d, pad_r_addr_q;
-logic                           buf_r_addr, buf_w_addr;
-
-logic [$clog2(TOT_DEPTH):0]     pad_read_cnt;
-logic                           pad_read_cnt_rst;
-
-logic [$clog2(2*H):0]           buf_write_cnt;
-
-logic                           pad_read_en,
-                                buf_read_en,
-                                buf_write_en;
-
-logic [$clog2(TOT_DEPTH)-1:0]   pad_read_addr;
-
-redmule_x_state_e               current_state, next_state;
-
-logic                           first_block,
-                                refilling;
-
-always_ff @(posedge clk_i or negedge rst_ni) begin : first_block_register
-  if(~rst_ni) begin
-    first_block <= '0;
-  end else begin
-    if (clear_i || pad_r_addr_q == 2*H-1)
-      first_block <= '0;
-    else if (ctrl_i.pad_setup)
-      first_block <= '1;
-  end
-end
-
-always_ff @(posedge clk_i or negedge rst_ni) begin : refill_flag_register
-  if(~rst_ni) begin
-    refilling <= '1;
-  end else begin
-    if (clear_i)
-      refilling <= '1;
-    else if (flags_o.full)
-      refilling <= '0;
-    else if (pad_read_cnt >= ctrl_i.slots)
-      refilling <= '1;
-  end
-end
-
-assign pad_read_en   = buf_write_en || ctrl_i.pad_setup;
-assign pad_read_addr = ctrl_i.pad_setup ? '0 : pad_r_addr_d;
+localparam int unsigned D          = DataW/(H*FpWidth);
+localparam int unsigned TOT_DEPTH  = H*D;
+localparam int unsigned W_ADDR_W   = (W > 1) ? $clog2(W) : 1;
+localparam int unsigned H_ADDR_W   = (H > 1) ? $clog2(H) : 1;
+localparam int unsigned PAD_ADDR_W = (TOT_DEPTH > 1) ? $clog2(TOT_DEPTH) : 1;
+localparam int unsigned BUF_ADDR_W = $clog2(H) + 1;
+localparam int unsigned BUF_CNT_W  = $clog2(2*H + 1);
+localparam int unsigned PAD_CNT_W  = $clog2(TOT_DEPTH + 1);
+
+logic [$clog2(W):0]                 w_index_d, w_index_q;
+logic [W-1:0]                       pad_row_valid_q;
+logic [W_ADDR_W-1:0]                pad_write_addr;
+
+logic [H_ADDR_W-1:0]                h_index_r, h_index_w;
+logic                               buf_r_addr, buf_w_addr;
+logic [BUF_ADDR_W-1:0]              scm_write_addr, scm_read_addr;
+
+logic [W-1:0][FpWidth-1:0]          x_pad_q;
+logic [W-1:0][FpWidth-1:0]          buf_wdata;
+logic [H-1:0][W-1:0][FpWidth-1:0]   x_buffer_q;
+
+logic [PAD_ADDR_W-1:0]              pad_r_addr_d, pad_r_addr_q;
+logic [PAD_ADDR_W-1:0]              pad_read_addr;
+logic [PAD_CNT_W-1:0]               pad_col_idx_q;
+
+logic [BUF_CNT_W-1:0]               init_writes_q;
+logic [BUF_CNT_W-1:0]               unread_cnt_q;
+
+logic                               started_q;
+logic                               pad_tile_valid_q;
+logic                               tile_consumed_q;
+logic                               fresh_pad_full;
+
+logic                               pad_read_en;
+logic                               buf_can_write;
+logic                               buf_write_en;
+logic                               buf_read_fire;
+logic                               tile_cols_done;
+logic                               col_in_bounds;
+
+// Counter to track rows loaded into i_x_pad for the incoming tile
+assign w_index_d      = ctrl_i.load ? (w_index_q + 1'b1) : w_index_q;
+assign flags_o.full   = (usize_eq(32'(w_index_q), 32'(ctrl_i.width)));
+assign pad_write_addr = (W > 1) ? w_index_q[W_ADDR_W-1:0] : '0;
+
+function automatic logic usize_eq(input logic [31:0] a, input logic [31:0] b);
+  return (a == b);
+endfunction
+
+always_ff @(posedge clk_i or negedge rst_ni) begin : row_loaded_counter
+  if (~rst_ni) begin
+    w_index_q <= '0;
+  end else begin
+    if (ctrl_i.rst_w_index || clear_i) begin
+      w_index_q <= '0;
+    end else if (ctrl_i.load) begin
+      w_index_q <= w_index_d;
+    end
+  end
+end
+
+// Persist which rows [0..W-1] were actually loaded for the tile currently in i_x_pad,
+// even after ctrl_i.rst_w_index clears w_index_q mid-drain.
+always_ff @(posedge clk_i or negedge rst_ni) begin : row_valid_tracker
+  if (~rst_ni) begin
+    pad_row_valid_q <= '0;
+  end else begin
+    if (clear_i) begin
+      pad_row_valid_q <= '0;
+    end else if (ctrl_i.load && !ctrl_i.rst_w_index) begin
+      if (w_index_q == '0) begin
+        pad_row_valid_q    <= '0;
+        pad_row_valid_q[0] <= 1'b1;
+      end else if (32'(w_index_q) < W) begin
+        pad_row_valid_q[pad_write_addr] <= 1'b1;
+      end
+    end else if (flags_o.empty) begin
+      pad_row_valid_q <= '0;
+    end
+  end
+end
+
+assign fresh_pad_full = flags_o.full && !tile_consumed_q;
+
+always_ff @(posedge clk_i or negedge rst_ni) begin : tile_lifecycle_registers
+  if (~rst_ni) begin
+    started_q        <= 1'b0;
+    pad_tile_valid_q <= 1'b0;
+    tile_consumed_q  <= 1'b0;
+  end else begin
+    if (clear_i) begin
+      started_q        <= 1'b0;
+      pad_tile_valid_q <= 1'b0;
+      tile_consumed_q  <= 1'b0;
+    end else begin
+      if (ctrl_i.pad_setup) begin
+        started_q <= 1'b1;
+      end
+
+      if (ctrl_i.pad_setup && flags_o.full) begin
+        pad_tile_valid_q <= 1'b1;
+        tile_consumed_q  <= ~ctrl_i.rst_w_index;
+      end else if (flags_o.empty) begin
+        if (fresh_pad_full) begin
+          pad_tile_valid_q <= 1'b1;
+          tile_consumed_q  <= ~ctrl_i.rst_w_index;
+        end else begin
+          pad_tile_valid_q <= 1'b0;
+          if (ctrl_i.rst_w_index) begin
+            tile_consumed_q <= 1'b0;
+          end
+        end
+      end else begin
+        if (!pad_tile_valid_q && (started_q || ctrl_i.pad_setup) && fresh_pad_full) begin
+          pad_tile_valid_q <= 1'b1;
+          tile_consumed_q  <= ~ctrl_i.rst_w_index;
+        end else if (ctrl_i.rst_w_index) begin
+          tile_consumed_q <= 1'b0;
+        end
+      end
+    end
+  end
+end
+
+// Capacity / lookahead flow control into the 2*H-deep ping-pong buffer i_x_buf:
+// - The first 2*H writes after reset/clear populate slots 0 and 1 for the first time.
+// - Thereafter, slot (floor(W_tot/H) mod 2, W_tot mod H) becomes free once R_tot reaches
+//   W_tot - H (either R_tot > W_tot - H already, or R_tot == W_tot - H with h_shift=1).
+assign buf_can_write = (32'(init_writes_q) < 2*H) ||
+                       (32'(unread_cnt_q) < H) ||
+                       ((32'(unread_cnt_q) == H) && ctrl_i.h_shift);
+
+assign buf_write_en  = pad_tile_valid_q && (32'(pad_col_idx_q) < 32'(ctrl_i.slots)) && buf_can_write;
+assign buf_read_fire = ctrl_i.h_shift && ((unread_cnt_q != '0) || buf_write_en);
+
+always_ff @(posedge clk_i or negedge rst_ni) begin : buf_occupancy_counters
+  if (~rst_ni) begin
+    init_writes_q <= '0;
+    unread_cnt_q  <= '0;
+  end else begin
+    if (clear_i) begin
+      init_writes_q <= '0;
+      unread_cnt_q  <= '0;
+    end else begin
+      if (buf_write_en && (32'(init_writes_q) < 2*H)) begin
+        init_writes_q <= init_writes_q + 1'b1;
+      end
+      unique case ({buf_write_en, buf_read_fire})
+        2'b10:   unread_cnt_q <= unread_cnt_q + 1'b1;
+        2'b01:   unread_cnt_q <= unread_cnt_q - 1'b1;
+        default: unread_cnt_q <= unread_cnt_q;
+      endcase
+    end
+  end
+end
+
+// Track how many columns [0..ctrl_i.slots] of the active i_x_pad tile have entered i_x_buf
+always_ff @(posedge clk_i or negedge rst_ni) begin : pad_col_counter
+  if (~rst_ni) begin
+    pad_col_idx_q <= '0;
+    pad_r_addr_q  <= '0;
+  end else begin
+    if (clear_i || ctrl_i.pad_setup || flags_o.empty) begin
+      pad_col_idx_q <= '0;
+      pad_r_addr_q  <= '0;
+    end else if (buf_write_en) begin
+      pad_col_idx_q <= pad_col_idx_q + 1'b1;
+      pad_r_addr_q  <= pad_r_addr_d;
+    end
+  end
+end
+
+assign pad_r_addr_d   = (32'(pad_col_idx_q) + 32'd1 < 32'(ctrl_i.slots)) ? (pad_r_addr_q + 1'b1) : '0;
+assign pad_read_en    = buf_write_en || ctrl_i.pad_setup || flags_o.empty;
+assign pad_read_addr  = (ctrl_i.pad_setup || flags_o.empty) ? '0 : pad_r_addr_d;
+
+assign tile_cols_done = pad_tile_valid_q &&
+                        ((32'(pad_col_idx_q) >= 32'(ctrl_i.slots)) ||
+                         ((32'(pad_col_idx_q) + 32'd1 == 32'(ctrl_i.slots)) && buf_write_en));
+assign flags_o.empty  = tile_cols_done && ctrl_i.h_shift;
 
 redmule_x_pad_scm #(
   .WORD_SIZE   ( FpWidth    ),
@@ -97,21 +215,31 @@
   .COLS        ( TOT_DEPTH  ),
   .USE_LATCHES ( UseLatches )
 ) i_x_pad (
-  .clk_i        ( clk_i                     ),
-  .rst_ni       ( rst_ni                    ),
-  .clear_i      ( clear_i                   ),
-  .write_en_i   ( ctrl_i.load               ),
-  .write_addr_i ( w_index_q [$clog2(W)-1:0] ),
-  .wdata_i      ( x_buffer_i                ),
-  .read_en_i    ( pad_read_en               ),
-  .read_addr_i  ( pad_read_addr             ),
-  .rdata_o      ( x_pad_q                   )
+  .clk_i        ( clk_i          ),
+  .rst_ni       ( rst_ni         ),
+  .clear_i      ( clear_i        ),
+  .write_en_i   ( ctrl_i.load    ),
+  .write_addr_i ( pad_write_addr ),
+  .wdata_i      ( x_buffer_i     ),
+  .read_en_i    ( pad_read_en    ),
+  .read_addr_i  ( pad_read_addr  ),
+  .rdata_o      ( x_pad_q        )
 );
 
-// Normally, we only write a row in the buffer when another one is read
-// In the FAST_FILL state we write a new row in the buffer every cycle until it is full
-assign buf_write_en = (current_state == FAST_FILL && ~refilling ||
-                      current_state == FILL && ctrl_i.h_shift);
+assign col_in_bounds = (32'(pad_col_idx_q) < 32'(ctrl_i.height));
+always_comb begin : gen_buf_wdata
+  for (int unsigned w = 0; w < W; w++) begin
+    buf_wdata[w] = (col_in_bounds && pad_row_valid_q[w]) ? x_pad_q[w] : '0;
+  end
+end
+
+if (H > 1) begin : gen_multi_h_scm_addr
+  assign scm_write_addr = {buf_w_addr, h_index_w};
+  assign scm_read_addr  = {buf_r_addr, h_index_r};
+end else begin : gen_single_h_scm_addr
+  assign scm_write_addr = buf_w_addr;
+  assign scm_read_addr  = buf_r_addr;
+end
 
 redmule_x_buffer_scm #(
   .WORD_SIZE   ( FpWidth    ),
@@ -120,203 +248,62 @@
   .N_OUTPUTS   ( H          ),
   .USE_LATCHES ( UseLatches )
 ) i_x_buf (
-  .clk_i        ( clk_i                                        ),
-  .rst_ni       ( rst_ni                                       ),
-  .clear_i      ( clear_i                                      ),
-  .write_en_i   ( buf_write_en                                 ),
-  .write_addr_i ( {buf_w_addr, h_index_w}                      ),
-  .wdata_i      ( pad_read_cnt <= ctrl_i.height ? x_pad_q : '0 ),
-  .read_en_i    ( ctrl_i.h_shift                               ),
-  .read_addr_i  ( {buf_r_addr, h_index_r}                      ),
-  .rdata_o      ( x_buffer_q                                   )
+  .clk_i        ( clk_i          ),
+  .rst_ni       ( rst_ni         ),
+  .clear_i      ( clear_i        ),
+  .write_en_i   ( buf_write_en   ),
+  .write_addr_i ( scm_write_addr ),
+  .wdata_i      ( buf_wdata      ),
+  .read_en_i    ( ctrl_i.h_shift ),
+  .read_addr_i  ( scm_read_addr  ),
+  .rdata_o      ( x_buffer_q     )
 );
 
-always_ff @(posedge clk_i or negedge rst_ni) begin  : state_register
-  if(~rst_ni) begin
-    current_state <= PRELOAD;
-  end else begin
-    if (clear_i) begin
-      current_state <= PRELOAD;
-    end else begin
-      current_state <= next_state;
-    end
-  end
-end
-
-always_comb begin : fsm
-  next_state = current_state;
-
-  case (current_state)
-    PRELOAD: begin
-      if (ctrl_i.pad_setup) begin
-        next_state = FAST_FILL;
-      end
-    end
-
-    FAST_FILL: begin
-      // As buf_write_cnt increments one cycle late, we have to check if its value is set to increase in the next cycle
-      if ((pad_r_addr_q == buf_write_cnt-1 || flags_o.empty) && (~ctrl_i.h_shift || first_block || (pad_read_cnt == ctrl_i.slots))) begin
-        if (pad_read_cnt == ctrl_i.slots) begin
-          if (~flags_o.full) begin
-            next_state = PAD_EMPTY;
-          end else begin
-            next_state = WAIT_FIRST_READ;
-          end
-        end else if (first_block) begin
-          next_state = WAIT_FIRST_READ;
-        end else begin
-          if (pad_read_cnt == ctrl_i.slots) begin // There is nothing more to read inside the pad, we just have to assert the empty flag once we are read
-            next_state = WAIT_SHIFT;
-          end else begin
-            next_state = FILL;
-          end
-        end
-      end
-    end
-
-    WAIT_FIRST_READ: begin
-      if (h_index_r == H-1 && ctrl_i.h_shift) begin
-          next_state = FILL;
-      end
-    end
-
-    WAIT_SHIFT: begin // The pad is empty but we are waiting for the first h_shift to assert the empty flag
-      if (ctrl_i.h_shift) begin
-        next_state = PAD_EMPTY;
-      end
-    end
-
-    FILL: begin
-      if (flags_o.empty) begin
-        // If the width of the buffer is 1, the full flag is asserted at the same time as the empty flag so we skip the PAD_EMPTY state
-        if (ctrl_i.width == 1 && flags_o.full) begin
-          next_state = FILL;
-        end else begin
-          next_state = PAD_EMPTY;
-        end
-      end
-    end
-
-    PAD_EMPTY: begin
-      if (flags_o.full) begin
-        if (buf_write_cnt != '0 || ctrl_i.h_shift) begin
-          next_state = FAST_FILL;
-        end else begin
-          next_state = FILL;
-        end
-      end
-    end
-  endcase
-end
-
-always_ff @(posedge clk_i or negedge rst_ni) begin : x_pad_read_pointer
-  if(~rst_ni) begin
-    pad_r_addr_q <= '0;
-  end else begin
-    if (clear_i)
-      pad_r_addr_q <= '0;
-    else if (buf_write_en)
-      pad_r_addr_q <= pad_r_addr_d;
-  end
-end
-
-assign pad_r_addr_d = (pad_r_addr_q < ctrl_i.slots-1) ? pad_r_addr_q + 1 : '0;
-
-// Counter to track the rows that have to be loaded
-always_ff @(posedge clk_i or negedge rst_ni) begin : row_loaded_counter
-  if(~rst_ni) begin
-    w_index_q <= '0;
-  end else begin
-    // The rst signal is externally supplied, as the full flag has to stay asserted until the scheduler acknowledges it
-    if (ctrl_i.rst_w_index || clear_i)
-      w_index_q <= '0;
-    else if (ctrl_i.load)
-      w_index_q <= w_index_d;
-    else
-      w_index_q <= w_index_q;
-  end
-end
-
-assign w_index_d = ctrl_i.load ? w_index_q + 1 : w_index_q;
-
-assign flags_o.full = w_index_q == ctrl_i.width;
-
-
-always_ff @(posedge clk_i or negedge rst_ni) begin : pad_read_counter
-  if(~rst_ni) begin
-    pad_read_cnt <= '0;
-  end else begin
-    if (clear_i)
-      pad_read_cnt <= '0;
-    else begin
-      if (pad_read_cnt_rst)
-        pad_read_cnt <= 1;
-      else if (pad_read_en)
-        pad_read_cnt <= pad_read_cnt == ctrl_i.slots ? pad_read_cnt : pad_read_cnt + 1;
-    end
-  end
-end
-
-assign pad_read_cnt_rst = (pad_read_cnt >= ctrl_i.slots) && ctrl_i.h_shift;
-assign flags_o.empty    = pad_read_cnt_rst;
-
-// This counts the number of times we have to write the buffer to fill it during the FAST_FILL state
-always_ff @(posedge clk_i or negedge rst_ni) begin : buf_write_counter
-  if(~rst_ni) begin
-    buf_write_cnt <= '0;
-  end else begin
-    if (clear_i || pad_read_cnt_rst)
-      buf_write_cnt <= '0;
-    else begin
-      if ((current_state == PAD_EMPTY || current_state == FAST_FILL && ~first_block) && ctrl_i.h_shift)
-        buf_write_cnt <= buf_write_cnt + 1;
-      else if (ctrl_i.pad_setup)
-        buf_write_cnt <= ctrl_i.slots;
-    end
-  end
-end
-
 always_ff @(posedge clk_i or negedge rst_ni) begin : h_index_r_register
-  if(~rst_ni) begin
+  if (~rst_ni) begin
     h_index_r <= '0;
   end else begin
-    if (clear_i)
+    if (clear_i) begin
       h_index_r <= '0;
-    else if(ctrl_i.h_shift)
-      h_index_r <= h_index_r == H-1 ? '0 : h_index_r + 1;
+    end else if (ctrl_i.h_shift && (H > 1)) begin
+      h_index_r <= (32'(h_index_r) == (H - 1)) ? '0 : (h_index_r + 1'b1);
+    end
   end
 end
 
 always_ff @(posedge clk_i or negedge rst_ni) begin : buffer_read_address
-  if(~rst_ni) begin
-    buf_r_addr <= '0;
-  end else begin
-    if (clear_i)
-      buf_r_addr <= '0;
-    else if (h_index_r == H-1 && ctrl_i.h_shift)
-      buf_r_addr <= buf_r_addr + 1;
+  if (~rst_ni) begin
+    buf_r_addr <= 1'b0;
+  end else begin
+    if (clear_i) begin
+      buf_r_addr <= 1'b0;
+    end else if (((H == 1) || (32'(h_index_r) == (H - 1))) && ctrl_i.h_shift) begin
+      buf_r_addr <= ~buf_r_addr;
+    end
   end
 end
 
 always_ff @(posedge clk_i or negedge rst_ni) begin : h_index_w_register
-  if(~rst_ni) begin
+  if (~rst_ni) begin
     h_index_w <= '0;
   end else begin
-    if (clear_i)
+    if (clear_i) begin
       h_index_w <= '0;
-    else if(buf_write_en)
-      h_index_w <= h_index_w == H-1 ? '0 : h_index_w + 1;
+    end else if (buf_write_en && (H > 1)) begin
+      h_index_w <= (32'(h_index_w) == (H - 1)) ? '0 : (h_index_w + 1'b1);
+    end
   end
 end
 
 always_ff @(posedge clk_i or negedge rst_ni) begin : buffer_write_address
-  if(~rst_ni) begin
-    buf_w_addr <= '0;
-  end else begin
-    if (clear_i)
-      buf_w_addr <= '0;
-    else if (h_index_w == H-1 && buf_write_en)
-      buf_w_addr <= buf_w_addr + 1;
+  if (~rst_ni) begin
+    buf_w_addr <= 1'b0;
+  end else begin
+    if (clear_i) begin
+      buf_w_addr <= 1'b0;
+    end else if (((H == 1) || (32'(h_index_w) == (H - 1))) && buf_write_en) begin
+      buf_w_addr <= ~buf_w_addr;
+    end
   end
 end
 

--- a/environment/public/code/x_buffer/redmule_x_buffer_scm.sv (Buggy Starter)
+++ b/solution/gold/code/x_buffer/redmule_x_buffer_scm.sv (Golden Reference)
@@ -8,72 +8,116 @@
 module redmule_x_buffer_scm
   import redmule_pkg::*;
 #(
-  parameter int unsigned WORD_SIZE   = 32,
-  parameter int unsigned WIDTH       = 1 ,
-  parameter int unsigned HEIGHT      = 2 ,
-  parameter int unsigned N_OUTPUTS   = 1 ,
-  parameter int unsigned USE_LATCHES = 0
+  parameter int unsigned WORD_SIZE    = 32,
+  parameter int unsigned WIDTH        = 1 ,
+  parameter int unsigned HEIGHT       = 2 ,
+  parameter int unsigned N_OUTPUTS    = 1 ,
+  parameter int unsigned USE_LATCHES  = 0 ,
+  localparam int unsigned ROW_BITS    = $clog2(N_OUTPUTS),
+  localparam int unsigned SLOT_BITS   = $clog2(HEIGHT),
+  localparam int unsigned SLOT_ADDR_W = (SLOT_BITS > 0) ? SLOT_BITS : 1,
+  localparam int unsigned ADDR_W      = ((ROW_BITS + SLOT_BITS) > 0) ? (ROW_BITS + SLOT_BITS) : 1
 ) (
   input  logic                                           clk_i        ,
   input  logic                                           rst_ni       ,
   input  logic                                           clear_i      ,
   input  logic                                           write_en_i   ,
-  input  logic [$clog2(N_OUTPUTS)+$clog2(HEIGHT)-1:0]    write_addr_i ,
+  input  logic [ADDR_W-1:0]                              write_addr_i ,
   input  logic [WIDTH-1:0][WORD_SIZE-1:0]                wdata_i      ,
   input  logic                                           read_en_i    ,
-  input  logic [$clog2(N_OUTPUTS)+$clog2(HEIGHT)-1:0]    read_addr_i  ,
+  input  logic [ADDR_W-1:0]                              read_addr_i  ,
   output logic [N_OUTPUTS-1:0][WIDTH-1:0][WORD_SIZE-1:0] rdata_o
 );
   logic [HEIGHT-1:0][N_OUTPUTS-1:0][WIDTH-1:0][WORD_SIZE-1:0] buffer_q;
   logic [WIDTH-1:0][WORD_SIZE-1:0]                            wdata_q;
-  logic [N_OUTPUTS-1:0][$clog2(HEIGHT)-1:0]                   read_addr_q;
+  logic [N_OUTPUTS-1:0][SLOT_ADDR_W-1:0]                      read_addr_q;
+  logic [HEIGHT-1:0][N_OUTPUTS-1:0]                           entry_valid_q;
 
-  logic [$clog2(N_OUTPUTS)-1:0]                               row_w_addr;
-  logic [$clog2(HEIGHT)-1:0]                                  slot_w_addr;
+  logic [N_OUTPUTS-1:0]                                       row_w_sel;
+  logic [N_OUTPUTS-1:0]                                       row_r_sel;
+  logic [SLOT_ADDR_W-1:0]                                     slot_w_addr;
+  logic [SLOT_ADDR_W-1:0]                                     slot_r_addr;
 
   logic [HEIGHT-1:0][N_OUTPUTS-1:0]                           clk_w;
 
+  if (SLOT_BITS > 0) begin : gen_multi_slot_addr
+    assign slot_w_addr = write_addr_i[ROW_BITS +: SLOT_BITS];
+    assign slot_r_addr = read_addr_i[ROW_BITS +: SLOT_BITS];
+  end else begin : gen_single_slot_addr
+    assign slot_w_addr = '0;
+    assign slot_r_addr = '0;
+  end
+
+  for (genvar o = 0; o < N_OUTPUTS; o++) begin : gen_row_match
+    if (N_OUTPUTS > 1) begin : gen_multi_out
+      assign row_w_sel[o] = (write_addr_i[ROW_BITS-1:0] == ROW_BITS'(o));
+      assign row_r_sel[o] = (read_addr_i[ROW_BITS-1:0] == ROW_BITS'(o));
+    end else begin : gen_single_out
+      assign row_w_sel[o] = 1'b1;
+      assign row_r_sel[o] = 1'b1;
+    end
+  end
+
   for (genvar o = 0; o < N_OUTPUTS; o++) begin : gen_read_addr_registers
     always_ff @(posedge clk_i or negedge rst_ni) begin : sample_raddr
-      if(~rst_ni) begin
+      if (~rst_ni) begin
         read_addr_q[o] <= '0;
       end else begin
         if (clear_i) begin
           read_addr_q[o] <= '0;
-        end if (read_en_i && read_addr_i[$clog2(N_OUTPUTS)-1:0] == o) begin
-          read_addr_q[o] <= read_addr_i[$clog2(N_OUTPUTS)+:$clog2(HEIGHT)];
+        end else if (read_en_i && row_r_sel[o]) begin
+          read_addr_q[o] <= slot_r_addr;
+        end
+      end
+    end
+  end
+
+  always_ff @(posedge clk_i or negedge rst_ni) begin : track_entry_valid
+    if (~rst_ni) begin
+      entry_valid_q <= '0;
+    end else begin
+      if (clear_i) begin
+        entry_valid_q <= '0;
+      end else if (write_en_i) begin
+        for (int unsigned h = 0; h < HEIGHT; h++) begin
+          for (int unsigned o = 0; o < N_OUTPUTS; o++) begin
+            if ((slot_w_addr == SLOT_ADDR_W'(h)) && row_w_sel[o]) begin
+              entry_valid_q[h][o] <= 1'b1;
+            end
+          end
         end
       end
     end
   end
 
   for (genvar o = 0; o < N_OUTPUTS; o++) begin : gen_output_assignment
-    assign rdata_o[o] = buffer_q[read_addr_q[o]][o];
+    if (HEIGHT > 1) begin : gen_multi_slot_out
+      assign rdata_o[o] = entry_valid_q[read_addr_q[o]][o] ? buffer_q[read_addr_q[o]][o] : '0;
+    end else begin : gen_single_slot_out
+      assign rdata_o[o] = entry_valid_q[0][o] ? buffer_q[0][o] : '0;
+    end
   end
 
   always_ff @(posedge clk_i or negedge rst_ni) begin : sample_wdata
-    if(~rst_ni) begin
+    if (~rst_ni) begin
       wdata_q <= '0;
     end else begin
       if (clear_i) begin
         wdata_q <= '0;
-      end if (write_en_i) begin
+      end else if (write_en_i) begin
         wdata_q <= wdata_i;
       end
     end
   end
 
-  assign row_w_addr  = write_addr_i[$clog2(N_OUTPUTS)-1:0];
-  assign slot_w_addr = write_addr_i[$clog2(N_OUTPUTS)+:$clog2(HEIGHT)];
-
-  if (USE_LATCHES) begin : gen_latches
+  if (USE_LATCHES != 0) begin : gen_latches
     for (genvar h = 0; h < HEIGHT; h++) begin : gen_slots_cg
       for (genvar o = 0; o < N_OUTPUTS; o++) begin : gen_rows_cg
         tc_clk_gating i_row_cg (
-          .clk_i     ( clk_i                                                        ),
-          .en_i      ( row_w_addr == o && slot_w_addr == h && write_en_i || clear_i ),
-          .test_en_i ( '0                                                           ),
-          .clk_o     ( clk_w[h][o]                                                  )
+          .clk_i     ( clk_i                                                                  ),
+          .en_i      ( (row_w_sel[o] && (slot_w_addr == SLOT_ADDR_W'(h)) && write_en_i) || clear_i ),
+          .test_en_i ( 1'b0                                                                   ),
+          .clk_o     ( clk_w[h][o]                                                            )
         );
       end
     end
@@ -96,7 +140,7 @@
           end else begin
             if (clear_i) begin
               buffer_q[h][o] <= '0;
-            end else if (row_w_addr == o && slot_w_addr == h && write_en_i) begin
+            end else if (row_w_sel[o] && (slot_w_addr == SLOT_ADDR_W'(h)) && write_en_i) begin
               buffer_q[h][o] <= wdata_i;
             end
           end

--- a/environment/public/code/x_buffer/redmule_x_pad_scm.sv (Buggy Starter)
+++ b/solution/gold/code/x_buffer/redmule_x_pad_scm.sv (Golden Reference)
@@ -11,59 +11,90 @@
   parameter int unsigned WORD_SIZE   = 32,
   parameter int unsig
```

</details>

---

## 5. Harbor Package File Inventory & Provenance

### Public Workspace (`environment/public/`)
- [`environment/public/BUILD.md`](environment/public/BUILD.md) *(Read-Only Context)*
- [`environment/public/code/LICENSE`](environment/public/code/LICENSE) *(Read-Only Context)*
- [`environment/public/code/fpnew_pkg.sv`](environment/public/code/fpnew_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/hci_package.sv`](environment/public/code/hci_package.sv) *(Read-Only Context)*
- [`environment/public/code/hwpe_ctrl_package.sv`](environment/public/code/hwpe_ctrl_package.sv) *(Read-Only Context)*
- [`environment/public/code/hwpe_stream_package.sv`](environment/public/code/hwpe_stream_package.sv) *(Read-Only Context)*
- [`environment/public/code/redmule_pkg.sv`](environment/public/code/redmule_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/tc_clk.sv`](environment/public/code/tc_clk.sv) *(Read-Only Context)*
- [`environment/public/code/x_buffer/redmule_x_buffer.sv`](environment/public/code/x_buffer/redmule_x_buffer.sv) **(Editable)**
- [`environment/public/code/x_buffer/redmule_x_buffer_scm.sv`](environment/public/code/x_buffer/redmule_x_buffer_scm.sv) **(Editable)**
- [`environment/public/code/x_buffer/redmule_x_pad_scm.sv`](environment/public/code/x_buffer/redmule_x_pad_scm.sv) **(Editable)**
- [`environment/public/issue.md`](environment/public/issue.md) *(Read-Only Context)*

### Reference Solutions & Isolated Verifier (`solution/` & `tests/`)
- [`solution/solve.sh`](solution/solve.sh) — Harbor oracle script
- [`solution/gold/`](solution/gold/) — Primary golden reference solution
- [`solution/alternate_gold/`](solution/alternate_gold/) — Structurally distinct secondary reference solution
- [`tests/test.sh`](tests/test.sh) — Isolated Harbor verifier entrypoint
- [`tests/private/policy_filter.py`](tests/private/policy_filter.py) — Pre-grader airlock & anti-cheat policy screen
- [`tests/private/grader/run.py`](tests/private/grader/run.py) — Deterministic front-to-back EDA verifier

### Upstream Provenance (`SOURCE.md`)

