# `case_20020`: Four-Way 8-KiB AXI4 Last-Level Cache Datapath, WRAP Coherency & 8-Macro Multi-Corner Signoff

[Back to Benchmark Root (`README.md`)](../../README.md) | [Full 94-Task Catalog (`TASKS_INDEX.md`)](../../TASKS_INDEX.md) | [`task.toml`](task.toml) | [`instruction.md`](instruction.md) | [`solution/solve.sh`](solution/solve.sh) | [`tests/test.sh`](tests/test.sh) | [`tests/private/grader/run.py`](tests/private/grader/run.py)

---

## 1. Task Overview & Harbor Configuration

| Field | Value |
| :--- | :--- |
| **Task ID** | `case_20020` |
| **Source Silicon Repository** | `pulp-platform/axi_llc` (`repo_26`) |
| **Engineering Problem Type** | **Architectural & Protocol Bug Repair** (`PT1_Arch_Protocol_Bug_Repair`) |
| **EDA Evaluation Stage** | **Stage 3: Static Timing (STA) & CDC/RDC Closure** (`stage3_sta_cdc`) |
| **Coupled Evaluation Gates** | Stage 1 (Functional RTL Sim) -> Stage 2 (Logic Synthesis & Gate-Level Verification) -> Stage 3 (OpenSTA Single-/Multi-Corner Setup/Hold WNS/TNS & CDC/RDC Closure) |
| **Primary Hardware Domain** | `HighSpeed_AXI_NIC_Cache_DMA` (HighSpeed_AXI_NIC_Cache_DMA) |
| **Multi-Domain Tags** | `HighSpeed_AXI_NIC_Cache_DMA` |
| **Editable Files (`allowed_edits`)** | [`constraints/axi_llc_ways.sdc`](environment/public/constraints/axi_llc_ways.sdc), [`code/rtl/axi_llc_burst_cutter.sv`](environment/public/code/rtl/axi_llc_burst_cutter.sv), [`code/rtl/axi_llc_merge_unit.sv`](environment/public/code/rtl/axi_llc_merge_unit.sv), [`code/rtl/axi_llc_read_unit.sv`](environment/public/code/rtl/axi_llc_read_unit.sv), [`code/rtl/axi_llc_write_unit.sv`](environment/public/code/rtl/axi_llc_write_unit.sv), [`code/rtl/axi_llc_ways.sv`](environment/public/code/rtl/axi_llc_ways.sv) (6 files, 983 LOC) |
| **Public Subsystem Context** | 66 RTL files (14059 LOC) |
| **Base Container Image** | `siliconbench-eda:1.0` (`allow_internet = false`, `environment_mode = "separate"`) |
| **PDK / Environment Profile** | **IHP SG13G2 130nm Open PDK + RM_IHPSG13_1P Hard-SRAM Macros** |
| **Task-Customized Collateral?** | **Yes (Task-Bundled Collateral)** — Includes task-bundled IHP SG13G2 standard-cell LEF/Liberty and single-port hard-SRAM macro LEF/Liberty/Verilog models. |
| **Verifier Timeout & Seeds** | `720s` total (`360s`/seed) across deterministic seeds `[101, 202]` |

---

## 2. Problem Specification (`issue.md`)

# 4-Way 8-KiB AXI4 Last-Level Cache Datapath, Critical-Word-First `WRAP` Coherency & 8-Macro Multi-Corner Signoff

## Problem Overview
Close functional, 4-state gate-level, and 3-corner (`SS`/`TT`/`FF`) hard-SRAM timing signoff on the 4-way set-associative AXI4 Last-Level Cache (`axi_llc_top_wrap`: `SetAssociativity=4`, `NumLines=64`, `NumBlocks=4`, 32 B cache lines, 8 KiB total data capacity, 64-bit data, 32-bit address, 4-bit slave / 5-bit master ID) in IHP SG13G2 130 nm technology.

## Scope & Editable Files
Only the following files may be modified (all other files under `code/` and `lib/` are read-only):
- `code/rtl/axi_llc_burst_cutter.sv`
- `code/rtl/axi_llc_merge_unit.sv`
- `code/rtl/axi_llc_read_unit.sv`
- `code/rtl/axi_llc_write_unit.sv`
- `code/rtl/axi_llc_ways.sv`
- `constraints/axi_llc_ways.sdc`

## Functional, Coherency & 4-State Gate-Level Contract
1. **Initialization & Address Map**: After `rst_ni` deassertion, tag BIST must complete (`bist_done_o = 1`, `bist_out_o = 4'b0000`). Slave transactions map to cached DRAM (`[cached_start_addr_i, cached_end_addr_i)`), per-way 2 KiB scratchpad regions (`spm_start_addr_i + w * 32'h800` for way `w` in `0..3` when `cfg_spm_i[w] = 1` and `flushed_o[w] = 1`), or uncached AXI4 master bypass; SPM-range accesses targeting ways still configured as cache must complete with `SLVERR` (`2'b10`) without corrupting cached state.
2. **AXI4 Burst Modes & Coherency**: Cached and SPM transactions must support `FIXED` (`2'b00`), single- and multi-line `INCR` (`2'b01`), and intra-cache-line Critical-Word-First `WRAP` (`2'b10` where `((AxLEN + 1) << AxSIZE) <= 32` bytes across narrow and 64-bit `AxSIZE`) read and write bursts without spurious cross-line splits or extra refill requests, preserving AXI4 ordering, 4-way dirty eviction writeback, and elastic `valid`/`ready` handshaking under arbitrary slave/master backpressure.
3. **4-State Partial-Strobe Hygiene**: Byte-masked writes (`slv_w_strb_i`) may carry `X` on unstrobed byte lanes (`slv_w_strb_i[b] == 0`) per AXI4; synthesized 4-state gate-level simulation (`iverilog -g2012`) must never propagate `X` onto read data or control handshakes, and must disallow latches (`$dlatch*`).

## Multi-Corner Hard-SRAM Timing Contract (`constraints/axi_llc_ways.sdc`)
1. **Clock & Boundary Budget**: Constrain single clock `clk_i` at **`10.80 ns`** (`92.59 MHz`) with `-setup >= 0.15 ns`, `-hold >= 0.08 ns` uncertainty, and `set_clock_transition >= 0.10 ns`. Every synchronous input (all inputs except `clk_i`, `rst_ni`, `test_i`, `cached_start_addr_i*`, `cached_end_addr_i*`, `spm_start_addr_i*`) requires `set_driving_cell -lib_cell sg13g2_buf_4 -pin X` and `set_input_delay` (`-max >= 1.80 ns`, `-min <= 0.20 ns`); every output requires `set_output_delay` (`-max >= 1.80 ns`, `-min <= 0.05 ns`) and `set_load >= 0.025` pF. Declare `set_false_path -from` only on `rst_ni`, `test_i`, and the three static `*_addr_i*` strap buses, with `set_max_fanout <= 16` and `set_max_transition <= 0.40 ns`.
2. **8-Macro CTS Balance & Signoff**: Preserve all **8** hard SRAM macros (`4` `RM_IHPSG13_1P_64x64_c2_bm_bist` + `4` `RM_IHPSG13_1P_256x64_c2_bm_bist`) with CTS macro clock-tree balance `set_clock_latency` in `[-0.50, -0.45]` ns on all `*i_cut/A_CLK` pins. No timing exceptions (`set_multicycle_path`, `set_max_delay`, `set_min_delay`, `set_disable_timing`, `set_case_analysis`, `set_ideal_network`, `create_generated_clock`, `group_path`) or unconstrained endpoints are allowed; post-`repair_design` (`SS`) and `repair_timing -hold` (`FF`) STA must achieve `setup_wns >= 0.0 ns`, `setup_tns >= 0.0 ns`, `hold_wns >= 0.0 ns`, and `hold_tns >= 0.0 ns` across `SS` (`1.08V, 125C`), `TT` (`1.20V, 25C`), and `FF` (`1.32V, -40C`).

---

## 3. Build & Verification Instructions (`BUILD.md`)

# Build & Signoff Reference (`axi_llc_top_wrap`)

## 1. Source Compilation Order
Compile the behavioral SRAM models (`lib/SRAM_1P_behavioral_bm_bist.v`, `lib/RM_IHPSG13_1P_64x64_c2_bm_bist.v`, `lib/RM_IHPSG13_1P_256x64_c2_bm_bist.v`) with `-DFUNCTIONAL -DSYNTHESIS`, include directories `-Icode/common_cells/include -Icode/axi/include -Icode/include`, and the SystemVerilog packages/modules in dependency order (`cb_filter_pkg.sv`, `cf_math_pkg.sv`, `axi_pkg.sv`, `axi_llc_pkg.sv`, `tc_sram.sv`, `common_cells/src/*.sv`, `axi/src/*.sv`, `rtl/*.sv`, top `axi_llc_top_wrap`).

## 2. Synthesis & 4-State Gate-Level Simulation (`yosys -m slang` + `iverilog` / `verilator`)
Synthesize `axi_llc_top_wrap` with `yosys -m slang` against the hard-SRAM blackbox stubs (`lib/RM_IHPSG13_1P_*_stub.v`) and `lib/sg13g2_stdcell_typ_1p20V_25C.lib` (`synth -top axi_llc_top_wrap -flatten`, `dfflibmap`, `abc -D 2500`, `hilomap`, `setundef -zero`, `splitnets -ports`). Simulate both the RTL and the flattened gate-level netlist (`simcells.v` + behavioral SRAM models) using `verilator --binary --timing -CFLAGS -O0` and 4-state `iverilog -g2012`.

## 3. Multi-Corner Hard-SRAM Buffering & STA (`openroad`)
Load `lib/sg13g2_tech.lef`, `lib/sg13g2_stdcell.lef`, both `RM_IHPSG13_1P_*_bm_bist.lef`/`.lib` views, and the corner standard-cell liberty (`slow_1p08V_125C.lib`, `typ_1p20V_25C.lib`, `fast_1p32V_m40C.lib`), read `constraints/axi_llc_ways.sdc`, set `Metal3`/`Metal4` wire RC (`estimate_parasitics -placement`), run `repair_design` in `SS` followed by `repair_timing -hold -hold_margin 0.02` in `FF`, and verify setup/hold WNS & TNS across `SS`, `TT`, and `FF`.

---

## 4. Reference Fix Inspection (Buggy Starter vs. Golden Solution Diff)

> Human reviewers can inspect the exact reference bug fix below, or browse full files in [`environment/public/`](environment/public/), [`solution/gold/`](solution/gold/), and [`solution/alternate_gold/`](solution/alternate_gold/).

<details open>
<summary><b>Click to expand/collapse Unified Diff (<code>environment/public/</code> vs. <code>solution/gold/</code>)</b></summary>

```diff
--- a/environment/public/constraints/axi_llc_ways.sdc (Buggy Starter)
+++ b/solution/gold/constraints/axi_llc_ways.sdc (Golden Reference)
@@ -1,7 +1,28 @@
-# Starter SDC for 4-way axi_llc_top_wrap (incomplete — fails 3-corner signoff)
 create_clock -name clk_i -period 10.80 [get_ports clk_i]
+set_clock_uncertainty -setup 0.15 [get_clocks clk_i]
+set_clock_uncertainty -hold  0.08 [get_clocks clk_i]
+set_clock_transition  0.10 [get_clocks clk_i]
 
-# Incomplete scalar port exclusion and missing uncertainty/slew/load/8-macro clock balance
-set_input_delay  -clock clk_i -max 1.80 [all_inputs]
-set_output_delay -clock clk_i -max 1.80 [all_outputs]
-set_false_path -from [get_ports {rst_ni test_i}]
+set async_and_static [get_ports {clk_i rst_ni test_i cached_start_addr_i* cached_end_addr_i* spm_start_addr_i*}]
+set sync_in {}
+foreach p [all_inputs] {
+  if {[lsearch -exact $async_and_static $p] == -1} {
+    lappend sync_in $p
+  }
+}
+set sync_out [all_outputs]
+
+set_driving_cell -lib_cell sg13g2_buf_4 -pin X $sync_in
+set_input_delay  -clock clk_i -max 1.80 $sync_in
+set_input_delay  -clock clk_i -min 0.20 $sync_in
+set_output_delay -clock clk_i -max 1.80 $sync_out
+set_output_delay -clock clk_i -min 0.05 $sync_out
+set_load 0.025 $sync_out
+
+# CTS macro clock-tree balance target (-0.48 ns early arrival across all 8 hard SRAM A_CLK pins)
+set_clock_latency -0.48 [get_pins -hierarchical *i_cut/A_CLK]
+
+set_false_path -from [get_ports {rst_ni test_i cached_start_addr_i* cached_end_addr_i* spm_start_addr_i*}]
+
+set_max_fanout 12 [current_design]
+set_max_transition 0.35 [current_design]

--- a/environment/public/code/rtl/axi_llc_burst_cutter.sv (Buggy Starter)
+++ b/solution/gold/code/rtl/axi_llc_burst_cutter.sv (Golden Reference)
@@ -1,80 +1,47 @@
 // Copyright 2022 ETH Zurich and University of Bologna.
 // Solderpad Hardware License, Version 0.51, see LICENSE for details.
 // SPDX-License-Identifier: SHL-0.51
-//
-// Author: Wolfgang Roenninger <wroennin@iis.ee.ethz.ch>
-// Date:   02.05.2019
 
-
-/// This module takes as input an Axi4 AW or AR channel struct
-/// It computes the current descriptor for the LLC, which maps part of the burst
-/// onto a cache line
-/// It computes the remaining channel struct, all remaining parts of the burst
-/// which map onto other cache lines
-/// This module further calculates the exact data way where an spm access will go to.
 module axi_llc_burst_cutter #(
-  /// LLC configuration struct, with static parameters.
   parameter axi_llc_pkg::llc_cfg_t     Cfg    = axi_llc_pkg::llc_cfg_t'{default: '0},
-  /// AXI channel configuration struct.
   parameter axi_llc_pkg::llc_axi_cfg_t AxiCfg = axi_llc_pkg::llc_axi_cfg_t'{default: '0},
-  /// AXI AW or AR channel struct definition.
   parameter type                       chan_t = logic,
-  /// The type of channel, how the write bit in the descriptor should be set.
-  /// `0`: AR channel is connected, descriptors do read accesses.
-  /// `1`: AW channel is connected, descriptors do write accesses.
   parameter bit                        Write  = 1'b0,
-  /// LLC descriptor type defeintion.
   parameter type                       desc_t = logic,
-  /// Type of the address rule struct used for SPM access streeri
   parameter type                       rule_t = axi_pkg::xbar_rule_64_t
 ) (
-  /// Clock, positive edge triggered.
- 	input  logic  clk_i,
-  /// Asynchronous reset, active low.
- 	input  logic  rst_ni,
-  /// The current AW or AR channel. This is the whole AXI transaction.
-  /// It is split into a descriptor and a next channel, which is a smaller transfer if it accesses
-  /// another cache line.
+  input  logic  clk_i,
+  input  logic  rst_ni,
   input  chan_t curr_chan_i,
-  /// The Ax transaction where the part accessed on the current cache line has been removed.
   output chan_t next_chan_o,
-  /// Output descriptor for the current line.
   output desc_t desc_o,
-  /// Address rule for mapping the cached address region.
-  /// `start_addr` and `end_addr` are used.
   input  rule_t cached_rule_i,
-  /// Address rule for mapping the SPM mapped region.
-  /// Here only the `satrt_addr` field is used. Internal builds an address decoding map
-  /// one for each cache way.
   input  rule_t spm_rule_i
-  );
+);
 
-  // typedefs for casting
-  typedef logic [AxiCfg.AddrWidthFull-1:0] addr_t; // address type
-  typedef logic [Cfg.SetAssociativity-1:0] indi_t; // way indicator type
+  typedef logic [AxiCfg.AddrWidthFull-1:0] addr_t;
+  typedef logic [Cfg.SetAssociativity-1:0] indi_t;
 
-  // line offset is the index where we are interested in, or where the line index starts
   localparam int unsigned LineOffset     = Cfg.ByteOffsetLength + Cfg.BlockOffsetLength;
   localparam int unsigned RuleIndexWidth = cf_math_pkg::idx_width(Cfg.SetAssociativity + 32'd1);
+  localparam addr_t       LineBytes      = addr_t'(1) << LineOffset;
 
-  addr_t         this_line_address; // address of this line (tag included)
-  addr_t         next_line_address; // address of the next line (tag included)
-  addr_t         bytes_on_line;     // how many bytes are on this cache line
-  axi_pkg::len_t beats_on_line;     // how many beats are on this cache line
-  // addr decode signals
+  addr_t         this_line_address;
+  addr_t         next_line_address;
+  addr_t         bytes_on_line;
+  addr_t         wrap_bytes;
+  logic          is_intra_line_wrap;
+  axi_pkg::len_t beats_on_line;
   logic                      rule_valid;
-  logic [RuleIndexWidth-1:0] rule_index; // so that width matches decoder port
+  logic [RuleIndexWidth-1:0] rule_index;
 
-  // generate the addr map for the decoder, ram has rule 0 and each way has one for its spm region
   rule_t [Cfg.SetAssociativity:0] addr_map;
   always_comb begin : proc_assign_addr_map
-    addr_t tmp_addr;                  // this counts up for the spm regions, one for each way
-    tmp_addr = spm_rule_i.start_addr; // init tmp_addr
+    addr_t tmp_addr;
+    tmp_addr = spm_rule_i.start_addr;
     addr_map = '0;
-    // assign the ram range
     addr_map[0].start_addr = cached_rule_i.start_addr;
     addr_map[0].end_addr   = cached_rule_i.end_addr;
-    // assign the spm regions
     for (int unsigned i = 32'd1; i <= Cfg.SetAssociativity; i++) begin
       addr_map[i].idx        = i;
       addr_map[i].start_addr = tmp_addr;
@@ -84,9 +51,8 @@
   end
 
   always_comb begin : proc_cutter
-    // Make sure the outputs are defined to a default.
-    next_chan_o         = curr_chan_i;
-    desc_o              = desc_t'{
+    next_chan_o = curr_chan_i;
+    desc_o      = desc_t'{
       a_x_id:    curr_chan_i.id,
       a_x_addr:  curr_chan_i.addr,
       a_x_size:  curr_chan_i.size,
@@ -99,42 +65,37 @@
       default: '0
     };
 
-    // calculate the line address (tag included)
-    this_line_address   = addr_t'(curr_chan_i.addr[LineOffset+:(AxiCfg.AddrWidthFull-LineOffset)]
+    this_line_address  = addr_t'(curr_chan_i.addr[LineOffset+:(AxiCfg.AddrWidthFull-LineOffset)]
                              << LineOffset);
-    // calculate the next line address (tag included)
-    next_line_address   = this_line_address + (addr_t'(1) << LineOffset);
-    // how many bytes are on the line from curr addr to the end
-    bytes_on_line       = next_line_address - curr_chan_i.addr;
-    // how many transaction beats map onto the current line
-    beats_on_line       = axi_pkg::len_t'((bytes_on_line - 1) >> curr_chan_i.size) + 1;
+    next_line_address  = this_line_address + LineBytes;
+    bytes_on_line      = next_line_address - curr_chan_i.addr;
+    beats_on_line      = axi_pkg::len_t'((bytes_on_line - 1) >> curr_chan_i.size) + 1;
+    wrap_bytes         = (addr_t'(curr_chan_i.len) + addr_t'(1)) << curr_chan_i.size;
+    is_intra_line_wrap = (curr_chan_i.burst == axi_pkg::BURST_WRAP) && (wrap_bytes <= LineBytes);
 
-    // Are we making an SPM access?
     if (rule_valid) begin
       if (rule_index != '0) begin
         desc_o.spm     = 1'b1;
         desc_o.way_ind = indi_t'(1 << (rule_index - 1));
       end
     end else begin
-      // make it an spm access on decerror go always onto way 0
       desc_o.spm     = 1'b1;
       desc_o.way_ind = indi_t'(1 << 0);
       desc_o.x_resp  = axi_pkg::RESP_SLVERR;
     end
 
-    // Do we have beats left on the next line?
-    if(((beats_on_line - 1) < curr_chan_i.len) &&
-        !(curr_chan_i.burst == axi_pkg::BURST_FIXED)) begin
-      // in this case we have at least one beat on the next cache line.
-      next_chan_o.addr  = next_line_address;
-      next_chan_o.len   = curr_chan_i.len - beats_on_line;
-      desc_o.a_x_len    = beats_on_line - 1;
-      desc_o.x_last     = 1'b0;
-    end else begin // all remaining beats are on the current cacheline.
-      next_chan_o.addr  = addr_t'(0);
-      next_chan_o.len   = axi_pkg::len_t'(0);
-      desc_o.a_x_len    = curr_chan_i.len;
-      desc_o.x_last     = 1'b1;
+    if (((beats_on_line - 1) < curr_chan_i.len) &&
+        !(curr_chan_i.burst == axi_pkg::BURST_FIXED) &&
+        !is_intra_line_wrap) begin
+      next_chan_o.addr = next_line_address;
+      next_chan_o.len  = curr_chan_i.len - beats_on_line;
+      desc_o.a_x_len   = beats_on_line - 1;
+      desc_o.x_last    = 1'b0;
+    end else begin
+      next_chan_o.addr = addr_t'(0);
+      next_chan_o.len  = axi_pkg::len_t'(0);
+      desc_o.a_x_len   = curr_chan_i.len;
+      desc_o.x_last    = 1'b1;
     end
   end
 
@@ -148,27 +109,8 @@
     .addr_map_i       ( addr_map         ),
     .idx_o            ( rule_index       ),
     .dec_valid_o      ( rule_valid       ),
-    .dec_error_o      ( /*not used*/     ), // implicit used in rule_valid
+    .dec_error_o      (                  ),
     .en_default_idx_i ( 1'b0             ),
     .default_idx_i    ( '0               )
   );
-
-  // pragma translate_off
-  `ifndef VERILATOR
-  `ifndef VCS
-  `ifndef SYNTHESIS
-  address_rollover: assert property( @(posedge clk_i) disable iff (~rst_ni)
-                        (next_line_address > this_line_address)) else
-    $fatal(1, $sformatf("burst_cutter > We habe an Global Address rollover in burst_cutter.\n \
-                         this_line_address: %s\nnext_line_address: %s",
-                         this_line_address, next_line_address));
-  line_address: assert property( @(posedge clk_i) disable iff (~rst_ni)
-                        ((next_line_address >= curr_chan_i.addr))) else
-    $fatal(1, $sformatf("burst_cutter > nWe habe an problem with the current burst address and \
-                         the next line address.\nthis_line_address: %s\ncurr_addr_i: %s",
-                         this_line_address, curr_chan_i.addr));
-  `endif
-  `endif
-  `endif
-  // pragma translate_on
 endmodule

--- a/environment/public/code/rtl/axi_llc_merge_unit.sv (Buggy Starter)
+++ b/solution/gold/code/rtl/axi_llc_merge_unit.sv (Golden Reference)
@@ -1,70 +1,37 @@
 // Copyright 2022 ETH Zurich and University of Bologna.
 // Solderpad Hardware License, Version 0.51, see LICENSE for details.
 // SPDX-License-Identifier: SHL-0.51
-//
-// Author: Wolfgang Roenninger <wroennin@iis.ee.ethz.ch>
-// Date:   12.06.2019
 
-/// This module merges the descriptor streams form the bypass and the eviction/refill
-/// pipeline. It distributes the descriptors to the read and write unit.
-/// It also notifies the counter unit in the hit_miss that a descriptor left the
-/// eviction/refill pipeline.
 module axi_llc_merge_unit #(
-  /// Static LLC configuration struct.
   parameter axi_llc_pkg::llc_cfg_t Cfg = axi_llc_pkg::llc_cfg_t'{default: '0},
-  /// LLC descriptor type definition.
   parameter type desc_t = logic,
-  /// Counter struct, is used in the miss counters for  ensuring the right ordering of
-  /// the descriptors.
-  ///
-  /// The struct `cnt_t` has to be defined as follows (done in `axi_llc_top`):
-  /// typedef struct packed {
-  ///    axi_slv_id_t id;     // AXI ID of the count operation
-  ///    logic        rw;     // 0: read, 1: write
-  ///    logic        valid;  // valid, equals enable
-  ///  } cnt_t;
-  parameter type cnt_t = logic
+  parameter type cnt_t  = logic
 ) (
-  /// Clock, positive edge triggered.
-  input logic clk_i,
-  /// Asynchronous reset, active low.
-  input logic rst_ni,
-  /// Input descriptor payload from the hit bypass.
-  input desc_t bypass_desc_i,
-  /// Hit bypass descriptor is valid.
-  input logic bypass_valid_i,
-  /// We are ready to accept a descriptor from the hit bypass.
-  output logic bypass_ready_o,
-  /// Input descriptor payload from the eviction / refill pipeline.
-  input desc_t refill_desc_i,
-  /// Miss pipeline descriptor is valid.
-  input logic refill_valid_i,
-  /// We are ready to accept a descriptor from the miss pipeline.
-  output logic refill_ready_o,
-  /// Output descriptor payload to the read unit.
+  input  logic  clk_i,
+  input  logic  rst_ni,
+  input  desc_t bypass_desc_i,
+  input  logic  bypass_valid_i,
+  output logic  bypass_ready_o,
+  input  desc_t refill_desc_i,
+  input  logic  refill_valid_i,
+  output logic  refill_ready_o,
   output desc_t read_desc_o,
-  /// Read descriptor is valid.
-  output logic read_valid_o,
-  /// Read unit is ready to accept a descriptor
-  input logic read_ready_i,
-  /// Write descriptor payload to the write unit.
+  output logic  read_valid_o,
+  input  logic  read_ready_i,
   output desc_t write_desc_o,
-  /// Write descriptor is valid.
-  output logic write_valid_o,
-  /// Write unit is ready to accept a descriptor.
-  input logic write_ready_i,
-  /// Output to the miss counters in the hit miss unit.
-  /// When valid a descriptor leaves the miss pipeline.
-  output cnt_t cnt_down_o
+  output logic  write_valid_o,
+  input  logic  write_ready_i,
+  output cnt_t  cnt_down_o
 );
 
-  // count down output towards the miss counters
-  // enable cnt_down_o if there is a transfer from the pipeline
+  desc_t xbar_w_desc,  xbar_r_desc;
+  logic  xbar_w_valid, xbar_w_ready;
+  logic  xbar_r_valid, xbar_r_ready;
+
   assign cnt_down_o.id    = refill_desc_i.a_x_id;
   assign cnt_down_o.rw    = refill_desc_i.rw;
   assign cnt_down_o.valid = refill_valid_i & refill_ready_o;
 
-  // The rw field is write = 1, read = 0.
   stream_xbar #(
     .NumInp     ( 32'd2  ),
     .NumOut     ( 32'd2  ),
@@ -82,9 +49,69 @@
     .sel_i   ({bypass_desc_i.rw, refill_desc_i.rw}),
     .valid_i ({bypass_valid_i,   refill_valid_i  }),
     .ready_o ({bypass_ready_o,   refill_ready_o  }),
-    .data_o  ({write_desc_o,     read_desc_o     }),
-    .idx_o   ( /*not used*/                       ),
-    .valid_o ({write_valid_o,    read_valid_o    }),
-    .ready_i ({write_ready_i,    read_ready_i    })
+    .data_o  ({xbar_w_desc,      xbar_r_desc     }),
+    .idx_o   (                                    ),
+    .valid_o ({xbar_w_valid,     xbar_r_valid    }),
+    .ready_i ({xbar_w_ready,     xbar_r_ready    })
   );
+
+  // Decoupled A/B spill stage for write descriptors (zero downstream ready load on xbar_w_desc)
+  desc_t w_a_q, w_b_q;
+  logic  w_a_full_q, w_b_full_q;
+  wire   w_a_fill  = xbar_w_valid & xbar_w_ready;
+  wire   w_a_drain = w_a_full_q & ~w_b_full_q;
+  wire   w_b_fill  = w_a_drain & ~write_ready_i;
+  wire   w_b_drain = w_b_full_q & write_ready_i;
+
+  assign xbar_w_ready  = ~w_a_full_q | ~w_b_full_q;
+  assign write_valid_o = w_a_full_q | w_b_full_q;
+  assign write_desc_o  = w_b_full_q ? w_b_q : w_a_q;
+
+  always_ff @(posedge clk_i or negedge rst_ni) begin
+    if (!rst_ni) begin
+      w_a_q      <= '0;
+      w_b_q      <= '0;
+      w_a_full_q <= 1'b0;
+      w_b_full_q <= 1'b0;
+    end else begin
+      if (w_a_fill)
+        w_a_q <= xbar_w_desc;
+      if (w_b_fill)
+        w_b_q <= w_a_q;
+      if (w_a_fill || w_a_drain)
+        w_a_full_q <= w_a_fill;
+      if (w_b_fill || w_b_drain)
+        w_b_full_q <= w_b_fill;
+    end
+  end
+
+  // Decoupled A/B spill stage for read descriptors
+  desc_t r_a_q, r_b_q;
+  logic  r_a_full_q, r_b_full_q;
+  wire   r_a_fill  = xbar_r_valid & xbar_r_ready;
+  wire   r_a_drain = r_a_full_q & ~r_b_full_q;
+  wire   r_b_fill  = r_a_drain & ~read_ready_i;
+  wire   r_b_drain = r_b_full_q & read_ready_i;
+
+  assign xbar_r_ready = ~r_a_full_q | ~r_b_full_q;
+  assign read_valid_o = r_a_full_q | r_b_full_q;
+  assign read_desc_o  = r_b_full_q ? r_b_q : r_a_q;
+
+  always_ff @(posedge clk_i or negedge rst_ni) begin
+    if (!rst_ni) begin
+      r_a_q      <= '0;
+      r_b_q      <= '0;
+      r_a_full_q <= 1'b0;
+      r_b_full_q <= 1'b0;
+    end else begin
+      if (r_a_fill)
+        r_a_q <= xbar_r_desc;
+      if (r_b_fill)
+        r_b_q <= r_a_q;
+      if (r_a_fill || r_a_drain)
+        r_a_full_q <= r_a_fill;
+      if (r_b_fill || r_b_drain)
+        r_b_full_q <= r_b_fill;
+    end
+  end
 endmodule

--- a/environment/public/code/rtl/axi_llc_read_unit.sv (Buggy Starter)
+++ b/solution/gold/code/rtl/axi_llc_read_unit.sv (Golden Reference)
@@ -1,196 +1,132 @@
 // Copyright 2022 ETH Zurich and University of Bologna.
 // Solderpad Hardware License, Version 0.51, see LICENSE for details.
 // SPDX-License-Identifier: SHL-0.51
-//
-// Author: Wolfgang Roenninger <wroennin@iis.ee.ethz.ch>
-// Date:   24.05.2019
 
-/// This module takes a descriptor as input and sends appropriate R channel beats from the data
-/// storage.
-/// It issues read requests to the data SRAM way specified in the descriptor.
-/// There is a FIFO, which stores the R channel meta information, when the read request is made to
-/// the data SRAM, all other fields of the R beat get also described into this R metadata FIFO.
-/// When the read data response arrives, the complete R beat gets assembled and put into the R
-/// channel output FIFO.
 module axi_llc_read_unit #(
-  /// Static LLC configuration parameter struct.
-  parameter axi_llc_pkg::llc_cfg_t Cfg = axi_llc_pkg::llc_cfg_t'{default: 0},
-  /// Static LLC AXI configuration parameters.
-  parameter axi_llc_pkg::llc_axi_cfg_t AxiCfg = axi_llc_pkg::llc_axi_cfg_t'{default: '0},
-  /// LLC descriptor type definition.
+  parameter axi_llc_pkg::llc_cfg_t     Cfg       = axi_llc_pkg::llc_cfg_t'{default: 0},
+  parameter axi_llc_pkg::llc_axi_cfg_t AxiCfg    = axi_llc_pkg::llc_axi_cfg_t'{default: '0},
   parameter type                       desc_t    = logic,
-  /// Data way request payload type definition.
   parameter type                       way_inp_t = logic,
-  /// Data way response payload type definition.
   parameter type                       way_oup_t = logic,
-  /// Lock struct definition. This is for the bloom filter to signal, that the line is unlocked.
   parameter type                       lock_t    = logic,
-  /// AXI slave port R channel struct definition.
   parameter type                       r_chan_t  = logic
 ) (
-  /// Clock, positive edge triggered.
-  input logic clk_i,
-  /// Asynchronous reset, active low.
-  input logic rst_ni,
-  /// Testmode enable, active high.
-  input logic test_i,
-  /// Read descriptor payload input.
-  input desc_t desc_i,
-  /// Input descriptor is valid.
-  input logic desc_valid_i,
-  /// Module is ready to take in a new descriptor.
-  output logic desc_ready_o,
-  /// Slave port R channel beat data.
-  output r_chan_t r_chan_slv_o,
-  /// R beat is valid.
-  output logic r_chan_valid_o,
-  /// R beat is ready.
-  input logic r_chan_ready_i,
-  /// Data storage way request payload.
+  input  logic     clk_i,
+  input  logic     rst_ni,
+  input  logic     test_i,
+  input  desc_t    desc_i,
+  input  logic     desc_valid_i,
+  output logic     desc_ready_o,
+  output r_chan_t  r_chan_slv_o,
+  output logic     r_chan_valid_o,
+  input  logic     r_chan_ready_i,
   output way_inp_t way_inp_o,
-  /// Data way request is valid.
-  output logic way_inp_valid_o,
-  /// Data way is ready for a request.
-  input logic way_inp_ready_i,
-  /// Read data payload from the data ways.
-  input way_oup_t way_out_i,
-  /// Data way response is valid.
-  input logic way_out_valid_i,
-  /// Module is ready to take in a response.
-  output logic way_out_ready_o,
-  /// Unlock signal payload for the line locking mechanism.
-  output lock_t r_unlock_o,
-  /// Request to unlock the line.
-  /// NOT AXI compliant!
-  output logic r_unlock_req_o,
-  /// Grant for the unlock request.
-  /// NOT AXI compliant!
-  input logic r_unlock_gnt_i
+  output logic     way_inp_valid_o,
+  input  logic     way_inp_ready_i,
+  input  way_oup_t way_out_i,
+  input  logic     way_out_valid_i,
+  output logic     way_out_ready_o,
+  output lock_t    r_unlock_o,
+  output logic     r_unlock_req_o,
+  input  logic     r_unlock_gnt_i
 );
   `include "common_cells/registers.svh"
   typedef logic [AxiCfg.SlvPortIdWidth-1:0] id_t;
   typedef logic [AxiCfg.DataWidthFull-1:0]  data_t;
-  // this struct saves the r channel meta information before it goes to the R FIFO
+  typedef logic [AxiCfg.AddrWidthFull-1:0]  addr_t;
+
   typedef struct packed {
     id_t            id;
     axi_pkg::resp_t resp;
     logic           last;
   } r_meta_t;
 
-  // flipflops
-  desc_t          desc_d,    desc_q;  // flipflop to hold descriptor
-  logic           load_desc;
-  logic           busy_d,    busy_q;  // status if descriptor occupies unit
-  logic           load_busy;
-  // R FIFO control signals
-  r_chan_t        r_fifo_inp;      // the assembled R beat to put on the channel
-  logic           r_fifo_push;     // push a read response from way into FIFO
-  logic           r_fifo_full;     // the R FIFO is full
-  logic           r_fifo_empty;    // to signal valid status to axi and control
-  logic           r_fifo_pop;      // is set to high if a data transfer occurs
-  // R channel metadate FIFO
-  r_meta_t        meta_fifo_inp;
-  logic           meta_fifo_full;
-  logic           meta_fifo_push;
-  r_meta_t        meta_fifo_outp;
-  logic           meta_fifo_empty;
-  logic           meta_fifo_pop;
+  desc_t   desc_d,      desc_q;
+  addr_t   wrap_mask_d, wrap_mask_q;
+  addr_t   next_lin_addr;
+  logic    load_desc;
+  logic    busy_d,      busy_q;
+  logic    load_busy;
 
-  // way_inp assignments
+  r_chan_t r_fifo_inp;
+  logic    r_fifo_push, r_fifo_full, r_fifo_empty, r_fifo_pop;
+  r_meta_t meta_fifo_inp, meta_fifo_outp;
+  logic    meta_fifo_full, meta_fifo_push, meta_fifo_empty, meta_fifo_pop;
+
   assign way_inp_o = '{
     cache_unit: axi_llc_pkg::RChanUnit,
     way_ind:    desc_q.way_ind,
     line_addr:  desc_q.a_x_addr[(Cfg.ByteOffsetLength + Cfg.BlockOffsetLength)+:Cfg.IndexLength],
     blk_offset: desc_q.a_x_addr[ Cfg.ByteOffsetLength +: Cfg.BlockOffsetLength],
     default: '0
-  }; // other fields not needed, `we` is `1'b0.
+  };
 
-  // unlock assignment
   assign r_unlock_o = '{
     index:   desc_q.a_x_addr[(Cfg.ByteOffsetLength + Cfg.BlockOffsetLength)+:Cfg.IndexLength],
     way_ind: desc_q.way_ind
   };
 
-  // control
+  function void load_new_desc ();
+    desc_ready_o = 1'b1;
+    if (desc_valid_i) begin
+      desc_d      = desc_i;
+      wrap_mask_d = ((addr_t'(desc_i.a_x_len) + addr_t'(1)) << desc_i.a_x_size) - addr_t'(1);
+      load_desc   = 1'b1;
+      busy_d      = 1'b1;
+      load_busy   = 1'b1;
+    end
+  endfunction : load_new_desc
+
   always_comb begin
-    // default assignments
-    desc_d    = desc_q;
-    load_desc = 1'b0;
-    busy_d    = busy_q;
-    load_busy = 1'b0;
-    // handshaking signals
+    desc_d          = desc_q;
+    wrap_mask_d     = wrap_mask_q;
+    load_desc       = 1'b0;
+    busy_d          = busy_q;
+    load_busy       = 1'b0;
     way_inp_valid_o = 1'b0;
     desc_ready_o    = 1'b0;
-    // unlock signal
-    r_unlock_req_o = 1'b0;
+    r_unlock_req_o  = 1'b0;
+    next_lin_addr   = axi_pkg::aligned_addr(desc_q.a_x_addr + axi_pkg::num_bytes(desc_q.a_x_size), desc_q.a_x_size);
 
-    // control
     if (busy_q) begin
-      // we are busy and have a descriptor inside (listen to meta FIFO)
       if (!meta_fifo_full && r_unlock_gnt_i) begin
-        // send requests towards the macros
         way_inp_valid_o = 1'b1;
         if (way_inp_ready_i) begin
-          //transaction
           if (desc_q.a_x_len == '0) begin
-            // all read requests where made, go to IDLE and load potential new descriptor
-            busy_d    = 1'b0;
-            load_busy = 1'b1;
-            // unlock the line, line is free when the bloom filter is updated in the next cycle
+            busy_d         = 1'b0;
+            load_busy      = 1'b1;
             r_unlock_req_o = 1'b1;
             load_new_desc();
           end else begin
-            // more read requests have to be made, update the address and update the length
-            if (desc_q.a_x_burst != axi_pkg::BURST_FIXED) begin
-              // update the address
-              desc_d.a_x_addr = axi_pkg::aligned_addr(desc_q.a_x_addr +
-                                    axi_pkg::num_bytes(desc_q.a_x_size), desc_q.a_x_size);
+            if (desc_q.a_x_burst == axi_pkg
```

</details>

---

## 5. Harbor Package File Inventory & Provenance

### Public Workspace (`environment/public/`)
- [`environment/public/BUILD.md`](environment/public/BUILD.md) *(Read-Only Context)*
- [`environment/public/code/LICENSE.llc`](environment/public/code/LICENSE.llc) *(Read-Only Context)*
- [`environment/public/code/axi/include/axi/assign.svh`](environment/public/code/axi/include/axi/assign.svh) *(Read-Only Context)*
- [`environment/public/code/axi/include/axi/typedef.svh`](environment/public/code/axi/include/axi/typedef.svh) *(Read-Only Context)*
- [`environment/public/code/axi/src/axi_atop_filter.sv`](environment/public/code/axi/src/axi_atop_filter.sv) *(Read-Only Context)*
- [`environment/public/code/axi/src/axi_cut.sv`](environment/public/code/axi/src/axi_cut.sv) *(Read-Only Context)*
- [`environment/public/code/axi/src/axi_demux.sv`](environment/public/code/axi/src/axi_demux.sv) *(Read-Only Context)*
- [`environment/public/code/axi/src/axi_demux_id_counters.sv`](environment/public/code/axi/src/axi_demux_id_counters.sv) *(Read-Only Context)*
- [`environment/public/code/axi/src/axi_demux_simple.sv`](environment/public/code/axi/src/axi_demux_simple.sv) *(Read-Only Context)*
- [`environment/public/code/axi/src/axi_id_prepend.sv`](environment/public/code/axi/src/axi_id_prepend.sv) *(Read-Only Context)*
- [`environment/public/code/axi/src/axi_isolate.sv`](environment/public/code/axi/src/axi_isolate.sv) *(Read-Only Context)*
- [`environment/public/code/axi/src/axi_mux.sv`](environment/public/code/axi/src/axi_mux.sv) *(Read-Only Context)*
- [`environment/public/code/axi/src/axi_pkg.sv`](environment/public/code/axi/src/axi_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/common_cells/include/common_cells/assertions.svh`](environment/public/code/common_cells/include/common_cells/assertions.svh) *(Read-Only Context)*
- [`environment/public/code/common_cells/include/common_cells/registers.svh`](environment/public/code/common_cells/include/common_cells/registers.svh) *(Read-Only Context)*
- [`environment/public/code/common_cells/src/addr_decode.sv`](environment/public/code/common_cells/src/addr_decode.sv) *(Read-Only Context)*
- [`environment/public/code/common_cells/src/addr_decode_dync.sv`](environment/public/code/common_cells/src/addr_decode_dync.sv) *(Read-Only Context)*
- [`environment/public/code/common_cells/src/cb_filter.sv`](environment/public/code/common_cells/src/cb_filter.sv) *(Read-Only Context)*
- [`environment/public/code/common_cells/src/cb_filter_pkg.sv`](environment/public/code/common_cells/src/cb_filter_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/common_cells/src/cf_math_pkg.sv`](environment/public/code/common_cells/src/cf_math_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/common_cells/src/counter.sv`](environment/public/code/common_cells/src/counter.sv) *(Read-Only Context)*
- [`environment/public/code/common_cells/src/delta_counter.sv`](environment/public/code/common_cells/src/delta_counter.sv) *(Read-Only Context)*
- [`environment/public/code/common_cells/src/fifo_v3.sv`](environment/public/code/common_cells/src/fifo_v3.sv) *(Read-Only Context)*
- [`environment/public/code/common_cells/src/lzc.sv`](environment/public/code/common_cells/src/lzc.sv) *(Read-Only Context)*
- [`environment/public/code/common_cells/src/onehot_to_bin.sv`](environment/public/code/common_cells/src/onehot_to_bin.sv) *(Read-Only Context)*
- [`environment/public/code/common_cells/src/rr_arb_tree.sv`](environment/public/code/common_cells/src/rr_arb_tree.sv) *(Read-Only Context)*
- [`environment/public/code/common_cells/src/shift_reg.sv`](environment/public/code/common_cells/src/shift_reg.sv) *(Read-Only Context)*
- [`environment/public/code/common_cells/src/shift_reg_gated.sv`](environment/public/code/common_cells/src/shift_reg_gated.sv) *(Read-Only Context)*
- [`environment/public/code/common_cells/src/spill_register.sv`](environment/public/code/common_cells/src/spill_register.sv) *(Read-Only Context)*
- [`environment/public/code/common_cells/src/spill_register_flushable.sv`](environment/public/code/common_cells/src/spill_register_flushable.sv) *(Read-Only Context)*
- [`environment/public/code/common_cells/src/stream_arbiter.sv`](environment/public/code/common_cells/src/stream_arbiter.sv) *(Read-Only Context)*
- [`environment/public/code/common_cells/src/stream_arbiter_flushable.sv`](environment/public/code/common_cells/src/stream_arbiter_flushable.sv) *(Read-Only Context)*
- [`environment/public/code/common_cells/src/stream_demux.sv`](environment/public/code/common_cells/src/stream_demux.sv) *(Read-Only Context)*
- [`environment/public/code/common_cells/src/stream_fifo.sv`](environment/public/code/common_cells/src/stream_fifo.sv) *(Read-Only Context)*
- [`environment/public/code/common_cells/src/stream_mux.sv`](environment/public/code/common_cells/src/stream_mux.sv) *(Read-Only Context)*
- [`environment/public/code/common_cells/src/stream_register.sv`](environment/public/code/common_cells/src/stream_register.sv) *(Read-Only Context)*
- [`environment/public/code/common_cells/src/stream_xbar.sv`](environment/public/code/common_cells/src/stream_xbar.sv) *(Read-Only Context)*
- [`environment/public/code/common_cells/src/sub_per_hash.sv`](environment/public/code/common_cells/src/sub_per_hash.sv) *(Read-Only Context)*
- [`environment/public/code/include/axi_llc/typedef.svh`](environment/public/code/include/axi_llc/typedef.svh) *(Read-Only Context)*
- [`environment/public/code/rtl/axi_llc_ax_master.sv`](environment/public/code/rtl/axi_llc_ax_master.sv) *(Read-Only Context)*
- [`environment/public/code/rtl/axi_llc_burst_cutter.sv`](environment/public/code/rtl/axi_llc_burst_cutter.sv) **(Editable)**
- [`environment/public/code/rtl/axi_llc_chan_splitter.sv`](environment/public/code/rtl/axi_llc_chan_splitter.sv) *(Read-Only Context)*
- [`environment/public/code/rtl/axi_llc_config.sv`](environment/public/code/rtl/axi_llc_config.sv) *(Read-Only Context)*
- [`environment/public/code/rtl/axi_llc_data_way.sv`](environment/public/code/rtl/axi_llc_data_way.sv) *(Read-Only Context)*
- [`environment/public/code/rtl/axi_llc_evict_box.sv`](environment/public/code/rtl/axi_llc_evict_box.sv) *(Read-Only Context)*
- [`environment/public/code/rtl/axi_llc_evict_unit.sv`](environment/public/code/rtl/axi_llc_evict_unit.sv) *(Read-Only Context)*
- [`environment/public/code/rtl/axi_llc_hit_miss.sv`](environment/public/code/rtl/axi_llc_hit_miss.sv) *(Read-Only Context)*
- [`environment/public/code/rtl/axi_llc_lock_box_bloom.sv`](environment/public/code/rtl/axi_llc_lock_box_bloom.sv) *(Read-Only Context)*
- [`environment/public/code/rtl/axi_llc_merge_unit.sv`](environment/public/code/rtl/axi_llc_merge_unit.sv) **(Editable)**
- [`environment/public/code/rtl/axi_llc_miss_counters.sv`](environment/public/code/rtl/axi_llc_miss_counters.sv) *(Read-Only Context)*
- [`environment/public/code/rtl/axi_llc_pkg.sv`](environment/public/code/rtl/axi_llc_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/rtl/axi_llc_r_master.sv`](environment/public/code/rtl/axi_llc_r_master.sv) *(Read-Only Context)*
- [`environment/public/code/rtl/axi_llc_read_unit.sv`](environment/public/code/rtl/axi_llc_read_unit.sv) **(Editable)**
- [`environment/public/code/rtl/axi_llc_refill_unit.sv`](environment/public/code/rtl/axi_llc_refill_unit.sv) *(Read-Only Context)*
- [`environment/public/code/rtl/axi_llc_tag_pattern_gen.sv`](environment/public/code/rtl/axi_llc_tag_pattern_gen.sv) *(Read-Only Context)*
- [`environment/public/code/rtl/axi_llc_tag_store.sv`](environment/public/code/rtl/axi_llc_tag_store.sv) *(Read-Only Context)*
- [`environment/public/code/rtl/axi_llc_top.sv`](environment/public/code/rtl/axi_llc_top.sv) *(Read-Only Context)*
- [`environment/public/code/rtl/axi_llc_top_wrap.sv`](environment/public/code/rtl/axi_llc_top_wrap.sv) *(Read-Only Context)*
- [`environment/public/code/rtl/axi_llc_w_master.sv`](environment/public/code/rtl/axi_llc_w_master.sv) *(Read-Only Context)*
- [`environment/public/code/rtl/axi_llc_ways.sv`](environment/public/code/rtl/axi_llc_ways.sv) **(Editable)**
- [`environment/public/code/rtl/axi_llc_write_unit.sv`](environment/public/code/rtl/axi_llc_write_unit.sv) **(Editable)**
- [`environment/public/code/rtl/tc_sram.sv`](environment/public/code/rtl/tc_sram.sv) *(Read-Only Context)*
- [`environment/public/constraints/axi_llc_ways.sdc`](environment/public/constraints/axi_llc_ways.sdc) **(Editable)**
- [`environment/public/issue.md`](environment/public/issue.md) *(Read-Only Context)*
- [`environment/public/lib/RM_IHPSG13_1P_256x64_c2_bm_bist.lef`](environment/public/lib/RM_IHPSG13_1P_256x64_c2_bm_bist.lef) *(Read-Only Context)*
- [`environment/public/lib/RM_IHPSG13_1P_256x64_c2_bm_bist.lib`](environment/public/lib/RM_IHPSG13_1P_256x64_c2_bm_bist.lib) *(Read-Only Context)*
- [`environment/public/lib/RM_IHPSG13_1P_256x64_c2_bm_bist.v`](environment/public/lib/RM_IHPSG13_1P_256x64_c2_bm_bist.v) *(Read-Only Context)*
- [`environment/public/lib/RM_IHPSG13_1P_256x64_c2_bm_bist_stub.v`](environment/public/lib/RM_IHPSG13_1P_256x64_c2_bm_bist_stub.v) *(Read-Only Context)*
- [`environment/public/lib/RM_IHPSG13_1P_64x64_c2_bm_bist.lef`](environment/public/lib/RM_IHPSG13_1P_64x64_c2_bm_bist.lef) *(Read-Only Context)*
- [`environment/public/lib/RM_IHPSG13_1P_64x64_c2_bm_bist.lib`](environment/public/lib/RM_IHPSG13_1P_64x64_c2_bm_bist.lib) *(Read-Only Context)*
- [`environment/public/lib/RM_IHPSG13_1P_64x64_c2_bm_bist.v`](environment/public/lib/RM_IHPSG13_1P_64x64_c2_bm_bist.v) *(Read-Only Context)*
- [`environment/public/lib/RM_IHPSG13_1P_64x64_c2_bm_bist_stub.v`](environment/public/lib/RM_IHPSG13_1P_64x64_c2_bm_bist_stub.v) *(Read-Only Context)*
- [`environment/public/lib/SRAM_1P_behavioral_bm_bist.v`](environment/public/lib/SRAM_1P_behavioral_bm_bist.v) *(Read-Only Context)*
- [`environment/public/lib/sg13g2_stdcell.lef`](environment/public/lib/sg13g2_stdcell.lef) *(Read-Only Context)*
- [`environment/public/lib/sg13g2_stdcell_fast_1p32V_m40C.lib`](environment/public/lib/sg13g2_stdcell_fast_1p32V_m40C.lib) *(Read-Only Context)*
- [`environment/public/lib/sg13g2_stdcell_slow_1p08V_125C.lib`](environment/public/lib/sg13g2_stdcell_slow_1p08V_125C.lib) *(Read-Only Context)*
- [`environment/public/lib/sg13g2_stdcell_typ_1p20V_25C.lib`](environment/public/lib/sg13g2_stdcell_typ_1p20V_25C.lib) *(Read-Only Context)*
- [`environment/public/lib/sg13g2_tech.lef`](environment/public/lib/sg13g2_tech.lef) *(Read-Only Context)*

### Reference Solutions & Isolated Verifier (`solution/` & `tests/`)
- [`solution/solve.sh`](solution/solve.sh) — Harbor oracle script
- [`solution/gold/`](solution/gold/) — Primary golden reference solution
- [`solution/alternate_gold/`](solution/alternate_gold/) — Structurally distinct secondary reference solution
- [`tests/test.sh`](tests/test.sh) — Isolated Harbor verifier entrypoint
- [`tests/private/policy_filter.py`](tests/private/policy_filter.py) — Pre-grader airlock & anti-cheat policy screen
- [`tests/private/grader/run.py`](tests/private/grader/run.py) — Deterministic front-to-back EDA verifier

### Upstream Provenance (`SOURCE.md`)

