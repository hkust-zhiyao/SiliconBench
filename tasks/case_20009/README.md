# `case_20009`: Two-Way AXI4 Last-Level Cache Multi-Corner Native SDC & Hard-SRAM Critical-Path Closure

[Back to Benchmark Root (`README.md`)](../../README.md) | [Full 94-Task Catalog (`TASKS_INDEX.md`)](../../TASKS_INDEX.md) | [`task.toml`](task.toml) | [`instruction.md`](instruction.md) | [`solution/solve.sh`](solution/solve.sh) | [`tests/test.sh`](tests/test.sh) | [`tests/private/grader/run.py`](tests/private/grader/run.py)

---

## 1. Task Overview & Harbor Configuration

| Field | Value |
| :--- | :--- |
| **Task ID** | `case_20009` |
| **Source Silicon Repository** | `pulp-platform/axi_llc` (`repo_26`) |
| **Engineering Problem Type** | **High-Frequency Timing & Area Optimization** (`PT3_Timing_Area_PPA_Closure`) |
| **EDA Evaluation Stage** | **Stage 3: Static Timing (STA) & CDC/RDC Closure** (`stage3_sta_cdc`) |
| **Coupled Evaluation Gates** | Stage 1 (Functional RTL Sim) -> Stage 2 (Logic Synthesis & Gate-Level Verification) -> Stage 3 (OpenSTA Single-/Multi-Corner Setup/Hold WNS/TNS & CDC/RDC Closure) |
| **Primary Hardware Domain** | `HighSpeed_AXI_NIC_Cache_DMA` (HighSpeed_AXI_NIC_Cache_DMA) |
| **Multi-Domain Tags** | `HighSpeed_AXI_NIC_Cache_DMA` |
| **Editable Files (`allowed_edits`)** | [`constraints/axi_llc.sdc`](environment/public/constraints/axi_llc.sdc), [`code/rtl/axi_llc_top.sv`](environment/public/code/rtl/axi_llc_top.sv), [`code/rtl/axi_llc_chan_splitter.sv`](environment/public/code/rtl/axi_llc_chan_splitter.sv), [`code/rtl/axi_llc_tag_store.sv`](environment/public/code/rtl/axi_llc_tag_store.sv), [`code/rtl/axi_llc_data_way.sv`](environment/public/code/rtl/axi_llc_data_way.sv) (5 files, 1770 LOC) |
| **Public Subsystem Context** | 66 RTL files (13984 LOC) |
| **Base Container Image** | `siliconbench-eda:1.0` (`allow_internet = false`, `environment_mode = "separate"`) |
| **PDK / Environment Profile** | **IHP SG13G2 130nm Open PDK + RM_IHPSG13_1P Hard-SRAM Macros** |
| **Task-Customized Collateral?** | **Yes (Task-Bundled Collateral)** — Includes task-bundled IHP SG13G2 standard-cell LEF/Liberty and single-port hard-SRAM macro LEF/Liberty/Verilog models. |
| **Verifier Timeout & Seeds** | `720s` total (`360s`/seed) across deterministic seeds `[101, 202]` |

---

## 2. Problem Specification (`issue.md`)

# Two-Way AXI4 Last-Level Cache Multi-Corner Native SDC & Hard-SRAM Critical-Path Closure

## Overview
`code/rtl/axi_llc_top_wrap.sv` integrates the complete 2-way, 4 KiB, 64-bit PULP `axi_llc` subsystem (`SetAssociativity = 2`, `NumLines = 64`, `NumBlocks = 4`, `AxiIdWidth = 4`, `AxiAddrWidth = 32`, `AxiDataWidth = 64`) backed by two hard `RM_IHPSG13_1P_64x64_c2_bm_bist` Tag SRAMs and two hard `RM_IHPSG13_1P_256x64_c2_bm_bist` Data SRAMs on IHP SG13G2. Under a `9.50 ns` (`~105.26 MHz`) target clock across all three signoff corners (`SS 1.08V 125C`, `TT 1.20V 25C`, `FF 1.32V -40C`), the baseline RTL and starter `constraints/axi_llc.sdc` fail worst-corner setup timing across unpipelined AXI4/descriptor/SRAM boundaries, fast-corner macro hold timing, and native `.sdc` signoff completeness.

## Architectural, Constraint & Multi-Corner Signoff Contract

1. **Lossless AXI4 LLC Protocol, Coherency, BIST & SPM Behavior**:
   - Preserve full AXI4 and LLC architectural behavior across post-reset Tag BIST initialization (`bist_done_o`, `bist_out_o`), cached cold-miss refills, cached read/write hits, multi-line bursts crossing 32-byte cache-line boundaries, partial-strobe (`slv_w_strb_i`) updates, dirty victim writeback evictions, uncached address-range bypasses (`outside [cached_start_addr_i, cached_end_addr_i)`), and dynamic Scratchpad Memory way partitioning/flushing (`cfg_spm_i`, `cfg_flush_i`, `commit_cfg_i`, `flushed_o`) under arbitrary slave/master channel backpressure.
   - Internal stream/channel pipelining across the editable RTL modules is permitted (latency-elastic `valid`/`ready` AXI4 and internal descriptor/way handshakes), provided transaction ordering, `ID` tags, responses, cache coherency, and BIST pass/fail self-checking remain exact, and synthesized gate-level netlist behavior matches RTL.

2. **Native Signoff Timing Constraints (`constraints/axi_llc.sdc`)**:
   - Define primary clock `clk_i` on port `clk_i` with `-period 9.50`, `-setup` clock uncertainty `>= 0.15` ns, `-hold` clock uncertainty `>= 0.08` ns, and clock transition `>= 0.10` ns.
   - Treat `rst_ni`, `test_i`, and static address-map strap buses (`cached_start_addr_i*`, `cached_end_addr_i*`, `spm_start_addr_i*`, matching post-`splitnets -ports` scalarized bus ports) as asynchronous/static false-path inputs (`set_false_path -from`), excluded from `set_input_delay`.
   - Constrain **every** remaining synchronous input port with `set_driving_cell -lib_cell sg13g2_buf_4 -pin X`, `set_input_delay -clock clk_i -max >= 1.80`, and `set_input_delay -clock clk_i -min <= 0.20`. Constrain **every** output port (`[all_outputs]`) with `set_output_delay -clock clk_i -max >= 1.80`, `set_output_delay -clock clk_i -min <= 0.05`, and `set_load >= 0.025`.
   - Model pre-CTS early macro clock-tree balance on **only** the four hard SRAM macro `A_CLK` pins (`*i_cut/A_CLK`) with `set_clock_latency` in `[-0.50, -0.45]` ns (do not apply clock latency to standard-cell flip-flops or top ports), set electrical design limits `set_max_fanout <= 16` and `set_max_transition <= 0.40` on `[current_design]`, and do **not** use `set_multicycle_path`, `set_disable_timing`, `set_case_analysis`, `set_ideal_network`, or false paths on synchronous logic/ports (`check_setup` must report `0` unconstrained endpoints).

3. **Three-Corner (`SS` / `TT` / `FF`) OpenROAD Signoff**:
   - Following `yosys -m slang` synthesis to `sg13g2` (`synth -top axi_llc_top_wrap -flatten`) and OpenROAD `repair_design` buffering on `sg13g2_stdcell_slow_1p08V_125C.lib` (`Metal3` signal / `Metal4` clock wire RC, `estimate_parasitics -placement`), all three corners (`slow_1p08V_125C`, `typ_1p20V_25C`, `fast_1p32V_m40C` paired with `RM_IHPSG13_1P_{64,256}x64_c2_bm_bist.lib`) must achieve `setup WNS >= 0.0 ns`, `setup TNS == 0.0 ns`, `hold WNS >= 0.0 ns`, and `hold TNS == 0.0 ns`.
   - Editable files: `constraints/axi_llc.sdc`, `code/rtl/axi_llc_top.sv`, `code/rtl/axi_llc_chan_splitter.sv`, `code/rtl/axi_llc_tag_store.sv`, and `code/rtl/axi_llc_data_way.sv`. Preserve all module names, parameters, and port signatures; all other files in `code/` and `lib/` are read-only.

---

## 3. Build & Verification Instructions (`BUILD.md`)

# Build, Synthesis, Buffering & Multi-Corner STA Reference

## Editable Files
- `constraints/axi_llc.sdc`
- `code/rtl/axi_llc_top.sv`
- `code/rtl/axi_llc_chan_splitter.sv`
- `code/rtl/axi_llc_tag_store.sv`
- `code/rtl/axi_llc_data_way.sv`

All other files in `code/` and `lib/` are read-only.

## Reference Signoff Commands
- **Yosys + Slang Synthesis (`build/llc_mapped.v`)**:
  ```bash
  mkdir -p build
  yosys -m slang -p "
    read_slang --top axi_llc_top_wrap -Icode/common_cells/include -Icode/axi/include -Icode/include -DSYNTHESIS \
      lib/RM_IHPSG13_1P_64x64_c2_bm_bist_stub.v lib/RM_IHPSG13_1P_256x64_c2_bm_bist_stub.v \
      code/common_cells/src/cb_filter_pkg.sv code/common_cells/src/cf_math_pkg.sv \
      code/axi/src/axi_pkg.sv code/rtl/axi_llc_pkg.sv code/rtl/tc_sram.sv \
      code/common_cells/src/*.sv code/axi/src/*.sv code/rtl/*.sv;
    hierarchy -check -top axi_llc_top_wrap; proc; opt_expr; check -assert;
    select -assert-none t:\$dlatch*;
    synth -top axi_llc_top_wrap -flatten;
    dfflibmap -liberty lib/sg13g2_stdcell_typ_1p20V_25C.lib;
    abc -D 2500 -liberty lib/sg13g2_stdcell_typ_1p20V_25C.lib;
    hilomap -hicell sg13g2_tiehi L_HI -locell sg13g2_tielo L_LO;
    setundef -zero; splitnets -ports; opt_clean -purge;
    write_verilog -noattr -noexpr build/llc_mapped.v"
  ```
- **OpenROAD `repair_design` Buffering & 3-Corner (`SS` / `TT` / `FF`) STA**:
  `openroad`
- **Verilator Simulation (with `lib/SRAM_1P_behavioral_bm_bist.v` + `lib/RM_IHPSG13_1P_*x64_c2_bm_bist.v`, `-DFUNCTIONAL`)**:
  `verilator`

---

## 4. Reference Fix Inspection (Buggy Starter vs. Golden Solution Diff)

> Human reviewers can inspect the exact reference bug fix below, or browse full files in [`environment/public/`](environment/public/), [`solution/gold/`](solution/gold/), and [`solution/alternate_gold/`](solution/alternate_gold/).

<details open>
<summary><b>Click to expand/collapse Unified Diff (<code>environment/public/</code> vs. <code>solution/gold/</code>)</b></summary>

```diff
--- a/environment/public/constraints/axi_llc.sdc (Buggy Starter)
+++ b/solution/gold/constraints/axi_llc.sdc (Golden Reference)
@@ -1,7 +1,29 @@
-# Starter SDC for axi_llc_top_wrap (incomplete — fails 3-corner signoff)
+
 create_clock -name clk_i -period 9.50 [get_ports clk_i]
+set_clock_uncertainty -setup 0.15 [get_clocks clk_i]
+set_clock_uncertainty -hold  0.08 [get_clocks clk_i]
+set_clock_transition  0.10 [get_clocks clk_i]
 
-# Incomplete scalar port exclusion (misses splitnets bus indices) and missing uncertainty/slew/load/macro balance
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
+# CTS macro clock-tree balance target (-0.48 ns early arrival at hard SRAM A_CLK pins)
+set_clock_latency -0.48 [get_pins -hierarchical *i_cut/A_CLK]
+
+set_false_path -from [get_ports {rst_ni test_i cached_start_addr_i* cached_end_addr_i* spm_start_addr_i*}]
+
+set_max_fanout 12 [current_design]
+set_max_transition 0.35 [current_design]

--- a/environment/public/code/rtl/axi_llc_top.sv (Buggy Starter)
+++ b/solution/gold/code/rtl/axi_llc_top.sv (Golden Reference)
@@ -402,6 +402,26 @@
     spm_addr_rule.end_addr      = spm_start_addr_i + axi_addr_t'(Cfg.SPMLength);
   end
 
+  slv_req_t  slv_cut_req;
+  slv_resp_t slv_cut_resp;
+  axi_cut #(
+    .Bypass     ( 1'b0          ),
+    .aw_chan_t  ( slv_aw_chan_t ),
+    .w_chan_t   ( w_chan_t      ),
+    .b_chan_t   ( slv_b_chan_t  ),
+    .ar_chan_t  ( slv_ar_chan_t ),
+    .r_chan_t   ( slv_r_chan_t  ),
+    .axi_req_t  ( slv_req_t     ),
+    .axi_resp_t ( slv_resp_t    )
+  ) i_slv_axi_cut (
+    .clk_i      ( clk_i        ),
+    .rst_ni     ( rst_ni       ),
+    .slv_req_i  ( slv_req_i    ),
+    .slv_resp_o ( slv_resp_o   ),
+    .mst_req_o  ( slv_cut_req  ),
+    .mst_resp_i ( slv_cut_resp )
+  );
+
   // configuration, also has control over bypass logic and flush
   axi_llc_config #(
     .Cfg            ( Cfg           ),
@@ -426,8 +446,8 @@
     .desc_valid_o      ( ax_desc_valid[axi_llc_pkg::ConfigUnit] ),
     .desc_ready_i      ( ax_desc_ready[axi_llc_pkg::ConfigUnit] ),
     // AXI address input from slave port for controlling bypass
-    .slv_aw_addr_i     ( slv_req_i.aw.addr                      ),
-    .slv_ar_addr_i     ( slv_req_i.ar.addr                      ),
+    .slv_aw_addr_i     ( to_demux_req.aw.addr                   ),
+    .slv_ar_addr_i     ( to_demux_req.ar.addr                   ),
     .mst_aw_bypass_o   ( slv_aw_bypass                          ),
     .mst_ar_bypass_o   ( slv_ar_bypass                          ),
     // flush control signals to prevent new data in ax_cutter loading
@@ -457,8 +477,8 @@
   ) i_axi_isolate_flush (
     .clk_i,
     .rst_ni,
-    .slv_req_i,  // Slave port request
-    .slv_resp_o, // Slave port response
+    .slv_req_i  ( slv_cut_req  ),
+    .slv_resp_o ( slv_cut_resp ),
     .mst_req_o  ( to_demux_req  ),
     .mst_resp_i ( to_demux_resp ),
     .isolate_i  ( llc_isolate   ),
@@ -477,11 +497,11 @@
     .NoMstPorts     ( 32'd2                  ),
     .MaxTrans       ( axi_llc_pkg::MaxTrans  ),
     .AxiLookBits    ( AxiIdLookupBits         ),
-    .SpillAw        ( 1'b0                   ),
-    .SpillW         ( 1'b0                   ),
-    .SpillB         ( 1'b0                   ),
-    .SpillAr        ( 1'b0                   ),
-    .SpillR         ( 1'b0                   )
+    .SpillAw        ( 1'b1                   ),
+    .SpillW         ( 1'b1                   ),
+    .SpillB         ( 1'b1                   ),
+    .SpillAr        ( 1'b1                   ),
+    .SpillR         ( 1'b1                   )
   ) i_axi_bypass_demux (
     .clk_i           ( clk_i                    ),
     .rst_ni          ( rst_ni                   ),
@@ -606,6 +626,26 @@
     .bist_valid_o   ( bist_valid   )
   );
 
+  llc_desc_t miss_desc_cut, hit_desc_cut, evict_desc_cut, refill_desc_cut;
+  logic miss_cut_valid, miss_cut_ready, hit_cut_valid, hit_cut_ready;
+  logic evict_cut_valid, evict_cut_ready, refill_cut_valid, refill_cut_ready;
+  spill_register #(.T(llc_desc_t), .Bypass(1'b0)) i_miss_desc_spill (
+    .clk_i, .rst_ni, .valid_i(miss_valid), .ready_o(miss_ready), .data_i(desc),
+    .valid_o(miss_cut_valid), .ready_i(miss_cut_ready), .data_o(miss_desc_cut)
+  );
+  spill_register #(.T(llc_desc_t), .Bypass(1'b0)) i_hit_desc_spill (
+    .clk_i, .rst_ni, .valid_i(hit_valid), .ready_o(hit_ready), .data_i(desc),
+    .valid_o(hit_cut_valid), .ready_i(hit_cut_ready), .data_o(hit_desc_cut)
+  );
+  spill_register #(.T(llc_desc_t), .Bypass(1'b0)) i_evict_desc_spill (
+    .clk_i, .rst_ni, .valid_i(evict_desc_valid), .ready_o(evict_desc_ready), .data_i(evict_desc),
+    .valid_o(evict_cut_valid), .ready_i(evict_cut_ready), .data_o(evict_desc_cut)
+  );
+  spill_register #(.T(llc_desc_t), .Bypass(1'b0)) i_refill_desc_spill (
+    .clk_i, .rst_ni, .valid_i(refill_desc_valid), .ready_o(refill_desc_ready), .data_i(refill_desc),
+    .valid_o(refill_cut_valid), .ready_i(refill_cut_ready), .data_o(refill_desc_cut)
+  );
+
   axi_llc_evict_unit #(
     .Cfg       ( Cfg           ),
     .AxiCfg    ( AxiCfg        ),
@@ -619,9 +659,9 @@
     .clk_i             ( clk_i                                ),
     .rst_ni            ( rst_ni                               ),
     .test_i            ( test_i                               ),
-    .desc_i            ( desc                                 ),
-    .desc_valid_i      ( miss_valid                           ),
-    .desc_ready_o      ( miss_ready                           ),
+    .desc_i            ( miss_desc_cut                        ),
+    .desc_valid_i      ( miss_cut_valid                       ),
+    .desc_ready_o      ( miss_cut_ready                       ),
     .desc_o            ( evict_desc                           ),
     .desc_valid_o      ( evict_desc_valid                     ),
     .desc_ready_i      ( evict_desc_ready                     ),
@@ -655,9 +695,9 @@
     .clk_i           ( clk_i                                ),
     .rst_ni          ( rst_ni                               ),
     .test_i          ( test_i                               ),
-    .desc_i          ( evict_desc                           ),
-    .desc_valid_i    ( evict_desc_valid                     ),
-    .desc_ready_o    ( evict_desc_ready                     ),
+    .desc_i          ( evict_desc_cut                       ),
+    .desc_valid_i    ( evict_cut_valid                      ),
+    .desc_ready_o    ( evict_cut_ready                      ),
     .desc_o          ( refill_desc                          ),
     .desc_valid_o    ( refill_desc_valid                    ),
     .desc_ready_i    ( refill_desc_ready                    ),
@@ -680,12 +720,12 @@
   ) i_merge_unit (
     .clk_i,
     .rst_ni,
-    .bypass_desc_i ( desc              ),
-    .bypass_valid_i( hit_valid         ),
-    .bypass_ready_o( hit_ready         ),
-    .refill_desc_i ( refill_desc       ),
-    .refill_valid_i( refill_desc_valid ),
-    .refill_ready_o( refill_desc_ready ),
+    .bypass_desc_i ( hit_desc_cut      ),
+    .bypass_valid_i( hit_cut_valid     ),
+    .bypass_ready_o( hit_cut_ready     ),
+    .refill_desc_i ( refill_desc_cut   ),
+    .refill_valid_i( refill_cut_valid  ),
+    .refill_ready_o( refill_cut_ready  ),
     .read_desc_o   ( read_desc         ),
     .read_valid_o  ( read_desc_valid   ),
     .read_ready_i  ( read_desc_ready   ),
@@ -693,6 +733,20 @@
     .write_valid_o ( write_desc_valid  ),
     .write_ready_i ( write_desc_ready  ),
     .cnt_down_o    ( cnt_down          )
+  );
+
+  llc_desc_t write_desc_cut, read_desc_cut;
+  logic      write_desc_cut_valid, write_desc_cut_ready;
+  logic      read_desc_cut_valid,  read_desc_cut_ready;
+  spill_register #(.T(llc_desc_t), .Bypass(1'b0)) i_wdesc_spill (
+    .clk_i, .rst_ni,
+    .valid_i(write_desc_valid), .ready_o(write_desc_ready), .data_i(write_desc),
+    .valid_o(write_desc_cut_valid), .ready_i(write_desc_cut_ready), .data_o(write_desc_cut)
+  );
+  spill_register #(.T(llc_desc_t), .Bypass(1'b0)) i_rdesc_spill (
+    .clk_i, .rst_ni,
+    .valid_i(read_desc_valid), .ready_o(read_desc_ready), .data_i(read_desc),
+    .valid_o(read_desc_cut_valid), .ready_i(read_desc_cut_ready), .data_o(read_desc_cut)
   );
 
   // write unit
@@ -708,9 +762,9 @@
     .clk_i           ( clk_i                                ),
     .rst_ni          ( rst_ni                               ),
     .test_i          ( test_i                               ),
-    .desc_i          ( write_desc                           ),
-    .desc_valid_i    ( write_desc_valid                     ),
-    .desc_ready_o    ( write_desc_ready                     ),
+    .desc_i          ( write_desc_cut                       ),
+    .desc_valid_i    ( write_desc_cut_valid                 ),
+    .desc_ready_o    ( write_desc_cut_ready                 ),
     .w_chan_slv_i    ( to_llc_req.w                         ),
     .w_chan_valid_i  ( to_llc_req.w_valid                   ),
     .w_chan_ready_o  ( to_llc_resp.w_ready                  ),
@@ -738,9 +792,9 @@
     .clk_i           ( clk_i                                ),
     .rst_ni          ( rst_ni                               ),
     .test_i          ( test_i                               ),
-    .desc_i          ( read_desc                            ),
-    .desc_valid_i    ( read_desc_valid                      ),
-    .desc_ready_o    ( read_desc_ready                      ),
+    .desc_i          ( read_desc_cut                        ),
+    .desc_valid_i    ( read_desc_cut_valid                  ),
+    .desc_ready_o    ( read_desc_cut_ready                  ),
     .r_chan_slv_o    ( to_llc_resp.r                        ),
     .r_chan_valid_o  ( to_llc_resp.r_valid                  ),
     .r_chan_ready_i  ( to_llc_req.r_ready                   ),
@@ -755,6 +809,38 @@
     .r_unlock_gnt_i  ( r_unlock_gnt                         )
   );
 
+  way_inp_t [3:0] to_way_cut;
+  logic     [3:0] to_way_cut_valid, to_way_cut_ready;
+  for (genvar u = 0; u < 4; u++) begin : gen_way_inp_cuts
+    spill_register #(
+      .T      ( way_inp_t ),
+      .Bypass ( 1'b0      )
+    ) i_way_inp_spill (
+      .clk_i   ( clk_i               ),
+      .rst_ni  ( rst_ni              ),
+      .valid_i ( to_way_valid[u]     ),
+      .ready_o ( to_way_ready[u]     ),
+      .data_i  ( to_way[u]           ),
+      .valid_o ( to_way_cut_valid[u] ),
+      .ready_i ( to_way_cut_ready[u] ),
+      .data_o  ( to_way_cut[u]       )
+    );
+  end
+
+  way_oup_t evict_way_out_raw, read_way_out_raw;
+  logic     evict_way_out_raw_valid, evict_way_out_raw_ready;
+  logic     read_way_out_raw_valid,  read_way_out_raw_ready;
+  spill_register #(.T(way_oup_t), .Bypass(1'b0)) i_evict_way_out_spill (
+    .clk_i, .rst_ni,
+    .valid_i(evict_way_out_raw_valid), .ready_o(evict_way_out_raw_ready), .data_i(evict_way_out_raw),
+    .valid_o(evict_way_out_valid),     .ready_i(evict_way_out_ready),     .data_o(evict_way_out)
+  );
+  spill_register #(.T(way_oup_t), .Bypass(1'b0)) i_read_way_out_spill (
+    .clk_i, .rst_ni,
+    .valid_i(read_way_out_raw_valid), .ready_o(read_way_out_raw_ready), .data_i(read_way_out_raw),
+    .valid_o(read_way_out_valid),     .ready_i(read_way_out_ready),     .data_o(read_way_out)
+  );
+
   // data storage
   axi_llc_ways #(
     .Cfg          ( Cfg          ),
@@ -765,15 +851,15 @@
     .clk_i                ( clk_i               ),
     .rst_ni               ( rst_ni              ),
     .test_i               ( test_i              ),
-    .way_inp_i            ( to_way              ),
-    .way_inp_valid_i      ( to_way_valid        ),
-    .way_inp_ready_o      ( to_way_ready        ),
-    .evict_way_out_o      ( evict_way_out       ),
-    .evict_way_out_valid_o( evict_way_out_valid ),
-    .evict_way_out_ready_i( evict_way_out_ready ),
-    .read_way_out_o       ( read_way_out        ),
-    .read_way_out_valid_o ( read_way_out_valid  ),
-    .read_way_out_ready_i ( read_way_out_ready  )
+    .way_inp_i            ( to_way_cut          ),
+    .way_inp_valid_i      ( to_way_cut_valid    ),
+    .way_inp_ready_o      ( to_way_cut_ready    ),
+    .evict_way_out_o      ( evict_way_out_raw       ),
+    .evict_way_out_valid_o( evict_way_out_raw_valid ),
+    .evict_way_out_ready_i( evict_way_out_raw_ready ),
+    .read_way_out_o       ( read_way_out_raw        ),
+    .read_way_out_valid_o ( read_way_out_raw_valid  ),
+    .read_way_out_ready_i ( read_way_out_raw_ready  )
   );
 
   // this unit widens the AXI ID by one!
@@ -795,11 +881,11 @@
     .NoSlvPorts    ( 32'd2                     ),
     .MaxWTrans     ( axi_llc_pkg::MaxTrans     ),
     .FallThrough   ( 1'b0                      ), // No registers
-    .SpillAw       ( 1'b0                      ), // No registers
-    .SpillW        ( 1'b0                      ), // No registers
-    .SpillB        ( 1'b0                      ), // No registers
-    .SpillAr       ( 1'b0                      ), // No registers
-    .SpillR        ( 1'b0                      )  // No registers
+    .SpillAw       ( 1'b1                      ), // No registers
+    .SpillW        ( 1'b1                      ), // No registers
+    .SpillB        ( 1'b1                      ), // No registers
+    .SpillAr       ( 1'b1                      ), // No registers
+    .SpillR        ( 1'b1                      )  // No registers
   ) i_axi_bypass_mux (
     .clk_i       ( clk_i                      ),
     .rst_ni      ( rst_ni                     ),

--- a/environment/public/code/rtl/axi_llc_chan_splitter.sv (Buggy Starter)
+++ b/solution/gold/code/rtl/axi_llc_chan_splitter.sv (Golden Reference)
@@ -61,21 +61,36 @@
   logic  busy_d,    busy_q;      // to store if spitter is ready for next descriptor or not
   logic  load_chan, load_busy;   // register enable
 
+  chan_t ax_cut_chan;
+  logic  ax_cut_valid, ax_cut_ready;
+  spill_register #(
+    .T      ( chan_t ),
+    .Bypass ( 1'b0   )
+  ) i_ax_in_spill (
+    .clk_i   ( clk_i           ),
+    .rst_ni  ( rst_ni          ),
+    .valid_i ( ax_chan_valid_i ),
+    .ready_o ( ax_chan_ready_o ),
+    .data_i  ( ax_chan_slv_i   ),
+    .valid_o ( ax_cut_valid    ),
+    .ready_i ( ax_cut_ready    ),
+    .data_o  ( ax_cut_chan     )
+  );
   chan_t curr_chan;
   chan_t next_chan;
 
   always_comb begin : proc_control_cut
     // default assignments
-    curr_chan       = ax_chan_slv_i;
+    curr_chan       = ax_cut_chan;
     chan_d          = chan_q;
     load_chan       = 1'b0;
     busy_d          = busy_q;
     load_busy       = 1'b0;
     // handshakes
-    ax_chan_ready_o = 1'b0;
+    ax_cut_ready    = 1'b0;
     desc_valid_o    = 1'b0;
     // status flag
-    unit_busy_o     = 1'b0;
+    unit_busy_o     = ax_cut_valid;
 
     // control
     if (busy_q) begin
@@ -87,10 +102,10 @@
         // do something different, if it is the last descriptor or not
         // it is the last descriptor
         if (desc_o.x_last) begin
-          ax_chan_ready_o = 1'b1;
+          ax_cut_ready    = 1'b1;
           // handshake new ax vector
-          if (ax_chan_valid_i) begin
-            chan_d    = ax_chan_slv_i;
+          if (ax_cut_valid) begin
+            chan_d    = ax_cut_chan;
             load_chan = 1'b1;
           // no new vector, go not busy
           end else begin
@@ -106,9 +121,9 @@
 
     // we are ready to take in a new vector, if we do not get stalled of flushing
     end else begin
-      ax_chan_ready_o = 1'b1;
+      ax_cut_ready    = 1'b1;
       // handshake the new vector
-      if (ax_chan_valid_i) begin
+      if (ax_cut_valid) begin
         unit_busy_o  = 1'b1;
         desc_valid_o = 1'b1;
         // what happens, if the descriptor handshakes out
@@ -123,7 +138,7 @@
           end
         // downstream not ready, save vector in register and get busy
         end else begin
-          chan_d    = ax_chan_slv_i;
+          chan_d    = ax_cut_chan;
           load_chan = 1'b1;
           busy_d    = 1'b1;
           load_busy = 1'b1;

--- a/environment/public/code/rtl/axi_llc_tag_store.sv (Buggy Starter)
+++ b/solution/gold/code/rtl/axi_llc_tag_store.sv (Golden Reference)
@@ -146,15 +146,15 @@
             ram_we     = {Cfg.SetAssociativity{gen_we}};
             ram_index  = gen_index;
             ram_wdata  = gen_pattern;
-            bist_valid = |ram_rvalid;
+            bist_valid = |ram_rvalid_q;
             // If BIST finished, go to idle.
-            if (gen_eoc) begin
+            if (gen_eoc && !(|ram_rvalid) && !(|ram_rvalid_q)) begin
               switch_busy = 1'b1;
             end
           end
           axi_llc_pkg::Lookup: begin
             // Wait for valid macro output
-            if ((|ram_rvalid) | (|ram_rvalid_q)) begin
+            if (|ram_rvalid_q) begin
               // We are valid on hit.
               if (|hit) begin
                 res_valid = 1'b1;
@@ -209,7 +209,7 @@
             end
           end
           axi_llc_pkg::Flush: begin
-            if ((|ram_rvalid) | (|ram_rvalid_q)) begin
+            if (|ram_rvalid_q) begin
               // We are valid when the read output of the macros is valid!
               res_valid = 1'b1;
             end
@@ -259,8 +259,9 @@
   `FFLARN(busy_q, busy_d, switch_busy, 1'b0, clk_i, rst_ni)
   assign busy_d = ~busy_q;
   `FFLARN(ram_rvalid_q, ram_rvalid_d, lock_rvalid, way_ind_t'(0), clk_i, rst_ni)
-  assign ram_rvalid_d = (res_valid & res_ready) ? way_ind_t'(0) : ram_rvalid;
-  assign lock_rvalid  = (res_valid & res_ready) | (|ram_rvalid);
+  assign ram_rvalid_d = (|ram_rvalid) ? ram_rvalid :
+                        ((req_q.mode == axi_llc_pkg::Bist) || (res_valid && res_ready)) ? way_ind_t'(0) : ram_rvalid_q;
+  assign lock_rvalid  = (|ram_rvalid) | (req_q.mode == axi_llc_pkg::Bist) | (res_valid & res_ready);
 
   // generate for each Way one tag storage macro
   for (genvar i = 0; unsigned'(i) < Cfg.SetAssociativity; i++) begin : gen_tag_macros
@@ -302,18 +303,23 @@
     logic i_tag_equ;
 
     assign tag_compare  = (req_q.mode == axi_llc_pkg::Bist) ? bist_pattern.tag : req_q.tag;
-    assign i_tag_equ    = &(ram_rdata.tag ~^ tag_compare);
+    tag_data_t ram_rdata_q;
+    always_ff @(posedge clk_i or negedge rst_ni) begin
+      if (!rst_ni) ram_rdata_q <= tag_data_t'(0);
+      else if (ram_rvalid[i]) ram_rdata_q <= ram_rdata;
+    end
+    assign i_tag_equ    = &(ram_rdata_q.tag ~^ tag_compare);
     assign tag_equ[i]   = i_tag_equ;
-    assign tag_val[i]   = ram_rdata.val;
-    assign tag_dit[i]   = ram_rdata.dit;
+    assign tag_val[i]   = ram_rdata_q.val;
+    assign tag_dit[i]   = ram_rdata_q.dit;
 
     assign hit[i]      = req_q.indicator[i] & tag_val[i] & tag_equ[i];
-    assign bist_res[i] = (ram_rdata.val == bist_pattern.val) &
-                         (ram_rdata.dit == bist_pattern.dit) &
+    assign bist_res[i] = (ram_rdata_q.val == bist_pattern.val) &
+                         (ram_rdata_q.dit == bist_pattern.dit) &
                          i_tag_equ;
 
     // assignment to wide output signal that goes to the tag output mux
-    assign stored_tag[i] = ram_rdata;
+    assign stored_tag[i] = ram_rdata_q;
   end
 
   axi_llc_tag_pattern_gen #(
@@ -339,8 +345,8 @@
 
   // This shift register holds the pattern for comparison of the bist.
   shift_reg #(
-    .dtype ( tag_data_t                   ),
-    .Depth ( axi_llc_pkg::TagMacroLatency )
+    .dtype ( tag_data_t                            ),
+    .Depth ( axi_llc_pkg::TagMacroLatency + 32'd1  )
   ) i_shift_reg_bist (
     .clk_i,
     .rst_ni,

--- a/environment/public/code/rtl/axi_llc_data_way.sv (Buggy Starter)
+++ b/solution/gold/code/rtl/axi_llc_data_way.sv (Golden Reference)
@@ -72,8 +72,10 @@
   //----------------------------------------------------------
   // Control
   //----------------------------------------------------------
-  assign out_o.cache_unit = cache_unit_q; // for the data demux in the module `axi_llc_ways`
-  assign out_valid_o      = outp_valid_q;
+  way_oup_t sram_out;
+  logic sram_out_valid, sram_out_ready;
+  assign sram_out.cache_unit = cache_unit_q; // for the data demux in the module `axi_llc_ways`
+  assign sram_out_valid      = outp_valid_q;
 
   // control of the data way, handles the handshaking and macro signals
   always_comb begin
@@ -87,7 +89,7 @@
     inp_ready_o  = 1'b0;
     if (outp_valid_q) begin
       // valid output from the SRAM, wait for handshake
-      if (out_ready_i) begin
+      if (sram_out_ready) begin
         // we update `outp_valid_d` anyway
         load_valid = 1'b1;
         // what value gets written depends on if there is another sram request
@@ -132,12 +134,27 @@
     .addr_i  ( addr       ),
     .wdata_i ( inp_i.data ),
     .be_i    ( inp_i.strb ),
-    .rdata_o ( out_o.data )
+    .rdata_o ( sram_out.data )
   );
 
   // Flip Flops to hold the read request meta information
   `FFLARN(outp_valid_q, outp_valid_d, load_valid, '0, clk_i, rst_ni)
   `FFLARN(cache_unit_q, cache_unit_d, load_unit, axi_llc_pkg::EvictUnit, clk_i, rst_ni)
+
+  stream_register #(
+    .T ( way_oup_t )
+  ) i_out_stream_reg (
+    .clk_i      ( clk_i          ),
+    .rst_ni     ( rst_ni         ),
+    .clr_i      ( 1'b0           ),
+    .testmode_i ( test_i         ),
+    .valid_i    ( sram_out_valid ),
+    .ready_o    ( sram_out_ready ),
+    .data_i     ( sram_out       ),
+    .valid_o    ( out_valid_o    ),
+    .ready_i    ( out_ready_i    ),
+    .data_o     ( out_o          )
+  );
 
 // pragma translate_off
 `ifndef VERILATOR

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
- [`environment/public/code/rtl/axi_llc_burst_cutter.sv`](environment/public/code/rtl/axi_llc_burst_cutter.sv) *(Read-Only Context)*
- [`environment/public/code/rtl/axi_llc_chan_splitter.sv`](environment/public/code/rtl/axi_llc_chan_splitter.sv) **(Editable)**
- [`environment/public/code/rtl/axi_llc_config.sv`](environment/public/code/rtl/axi_llc_config.sv) *(Read-Only Context)*
- [`environment/public/code/rtl/axi_llc_data_way.sv`](environment/public/code/rtl/axi_llc_data_way.sv) **(Editable)**
- [`environment/public/code/rtl/axi_llc_evict_box.sv`](environment/public/code/rtl/axi_llc_evict_box.sv) *(Read-Only Context)*
- [`environment/public/code/rtl/axi_llc_evict_unit.sv`](environment/public/code/rtl/axi_llc_evict_unit.sv) *(Read-Only Context)*
- [`environment/public/code/rtl/axi_llc_hit_miss.sv`](environment/public/code/rtl/axi_llc_hit_miss.sv) *(Read-Only Context)*
- [`environment/public/code/rtl/axi_llc_lock_box_bloom.sv`](environment/public/code/rtl/axi_llc_lock_box_bloom.sv) *(Read-Only Context)*
- [`environment/public/code/rtl/axi_llc_merge_unit.sv`](environment/public/code/rtl/axi_llc_merge_unit.sv) *(Read-Only Context)*
- [`environment/public/code/rtl/axi_llc_miss_counters.sv`](environment/public/code/rtl/axi_llc_miss_counters.sv) *(Read-Only Context)*
- [`environment/public/code/rtl/axi_llc_pkg.sv`](environment/public/code/rtl/axi_llc_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/rtl/axi_llc_r_master.sv`](environment/public/code/rtl/axi_llc_r_master.sv) *(Read-Only Context)*
- [`environment/public/code/rtl/axi_llc_read_unit.sv`](environment/public/code/rtl/axi_llc_read_unit.sv) *(Read-Only Context)*
- [`environment/public/code/rtl/axi_llc_refill_unit.sv`](environment/public/code/rtl/axi_llc_refill_unit.sv) *(Read-Only Context)*
- [`environment/public/code/rtl/axi_llc_tag_pattern_gen.sv`](environment/public/code/rtl/axi_llc_tag_pattern_gen.sv) *(Read-Only Context)*
- [`environment/public/code/rtl/axi_llc_tag_store.sv`](environment/public/code/rtl/axi_llc_tag_store.sv) **(Editable)**
- [`environment/public/code/rtl/axi_llc_top.sv`](environment/public/code/rtl/axi_llc_top.sv) **(Editable)**
- [`environment/public/code/rtl/axi_llc_top_wrap.sv`](environment/public/code/rtl/axi_llc_top_wrap.sv) *(Read-Only Context)*
- [`environment/public/code/rtl/axi_llc_w_master.sv`](environment/public/code/rtl/axi_llc_w_master.sv) *(Read-Only Context)*
- [`environment/public/code/rtl/axi_llc_ways.sv`](environment/public/code/rtl/axi_llc_ways.sv) *(Read-Only Context)*
- [`environment/public/code/rtl/axi_llc_write_unit.sv`](environment/public/code/rtl/axi_llc_write_unit.sv) *(Read-Only Context)*
- [`environment/public/code/rtl/tc_sram.sv`](environment/public/code/rtl/tc_sram.sv) *(Read-Only Context)*
- [`environment/public/constraints/axi_llc.sdc`](environment/public/constraints/axi_llc.sdc) **(Editable)**
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

