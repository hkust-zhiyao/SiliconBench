# `case_5010`: CVA6 I-Cache Speculative Non-Idempotent Kill Recovery, S1 Kill Gating, AXI Wrapper Unacknowledged AR Stability, Burst Write Handshake, and Area/Timing Closure

[Back to Benchmark Root (`README.md`)](../../README.md) | [Full 94-Task Catalog (`TASKS_INDEX.md`)](../../TASKS_INDEX.md) | [`task.toml`](task.toml) | [`instruction.md`](instruction.md) | [`solution/solve.sh`](solution/solve.sh) | [`tests/test.sh`](tests/test.sh) | [`tests/private/grader/run.py`](tests/private/grader/run.py)

---

## 1. Task Overview & Harbor Configuration

| Field | Value |
| :--- | :--- |
| **Task ID** | `case_5010` |
| **Source Silicon Repository** | `openhwfoundation/cva6` (`repo_05`) |
| **Engineering Problem Type** | **Architectural & Protocol Bug Repair** (`PT1_Arch_Protocol_Bug_Repair`) |
| **EDA Evaluation Stage** | **Stage 3: Static Timing (STA) & CDC/RDC Closure** (`stage3_sta_cdc`) |
| **Coupled Evaluation Gates** | Stage 1 (Functional RTL Sim) -> Stage 2 (Logic Synthesis & Gate-Level Verification) -> Stage 3 (OpenSTA Single-/Multi-Corner Setup/Hold WNS/TNS & CDC/RDC Closure) |
| **Primary Hardware Domain** | `rtl_semantics` (SystemVerilog Semantics, Sim-Synth Mismatch, Latch Avoidance & X-Blocking) |
| **Multi-Domain Tags** | `protocol_control`, `rtl_integration`, `rtl_semantics`, `synthesis_qor` |
| **Editable Files (`allowed_edits`)** | [`code/cva6_icache.sv`](environment/public/code/cva6_icache.sv), [`code/cva6_icache_axi_wrapper.sv`](environment/public/code/cva6_icache_axi_wrapper.sv), [`code/axi_shim.sv`](environment/public/code/axi_shim.sv) (3 files, 1122 LOC) |
| **Public Subsystem Context** | 15 RTL files (5127 LOC) |
| **Base Container Image** | `siliconbench-eda:1.0` (`allow_internet = false`, `environment_mode = "separate"`) |
| **PDK / Environment Profile** | **Nangate45 45nm Open Cell Library + Task Multi-Corner Liberty/SDC** |
| **Task-Customized Collateral?** | **Yes (Task-Bundled Collateral)** — Uses shared Nangate45 library for synthesis plus task-bundled fast/slow/scan corner timing views. |
| **Verifier Timeout & Seeds** | `600s` total (`300s`/seed) across deterministic seeds `[101, 202]` |

---

## 2. Problem Specification (`issue.md`)

# CVA6 I-Cache Speculative Non-Idempotent Kill Recovery, S1 Kill Gating, AXI Wrapper Unacknowledged AR Stability, and Area/Timing Closure

In the CVA6 instruction cache and AXI interface subsystem (`code/cva6_icache.sv`, `code/cva6_icache_axi_wrapper.sv`, and `code/axi_shim.sv` integrated in `flow/icache_axi_top.sv`), stage-1/stage-2 request kills, speculative non-idempotent fetches, and stalled AXI read/write handshakes expose four functional and synthesis/timing issues:

1. **Stage-1 kill (`kill_s1`) state/SRAM side-effects and speculative non-idempotent `kill_s2` deadlock in `code/cva6_icache.sv`**:
   - When `dreq_i.req` and `dreq_i.kill_s1` are both asserted on a cycle where `dreq_o.ready` is high (in `IDLE` or on a hit in `READ`), `cva6_icache` currently still asserts `cache_rden = 1'b1` (triggering a spurious SRAM read) and updates `vaddr_q` and `cl_offset_q` to the killed `dreq_i.vaddr`. Whenever `dreq_i.kill_s1` is asserted, a new S1 request must not trigger `cache_rden` (`1'b0` in `IDLE`), must not transition to `READ`, and must not update `vaddr_q` or `cl_offset_q`.
   - In `READ`, when `areq_i.fetch_valid` is asserted for a speculative fetch (`dreq_i.spec == 1'b1`) targeting a non-idempotent physical address (`CVA6Cfg.NonIdemPotenceEn && addr_ni`), the cache waits for `dreq_i.spec` to deassert before issuing the non-idempotent memory access. Currently, if `dreq_i.kill_s2` or `flush_d` is asserted on that cycle while `areq_i.fetch_valid == 1'b1`, `cva6_icache` transitions to `KILL_ATRANS` (which waits for another `areq_i.fetch_valid`) instead of returning directly to `IDLE`. When `dreq_i.kill_s2 || flush_d` is asserted in `READ` and `areq_i.fetch_valid` is already high, `state_d` must transition to `IDLE` (`KILL_ATRANS` is only entered when `areq_i.fetch_valid == 1'b0`).

2. **AXI read channel payload stability under `ar_ready` backpressure in `code/cva6_icache_axi_wrapper.sv`**:
   - `cva6_icache_axi_wrapper` immediately acknowledges `icache_mem_data_req` (`icache_mem_data_ack = icache_mem_data_req`) and holds `axi_rd_req` high via `req_valid_q` until `axi_rd_gnt` (`ar_ready`) is received. However, `req_data_d = (icache_mem_data_req) ? icache_mem_data : req_data_q` unconditionally overwrites `req_data_q` whenever `icache_mem_data_req` asserts, even while an earlier unacknowledged AXI read request is still pending (`req_valid_q == 1'b1` and `ar_valid_o == 1'b1`, `ar_ready_i == 1'b0`), violating the AXI4 requirement that `ar_addr`, `ar_len`, and `ar_id` remain stable while `ar_valid && !ar_ready`. `req_data_d` must only capture `icache_mem_data` when `icache_mem_data_req && !req_valid_q`.

3. **Burst write handshake and beat counter control in `code/axi_shim.sv`**:
   - In `axi_shim`, multi-beat burst writes (`CVA6Cfg.AxiBurstWriteEn && !wr_single_req`) must advance `wr_cnt_q` on each accepted `W` beat (`axi_resp_i.w_ready`), assert `w.last` on the final beat (`wr_cnt_q == wr_blen_i`), and transition to `WAIT_LAST_W_READY_AW_READY` when neither `aw_ready` nor `w_ready` is asserted in `IDLE` (`{aw_ready, w_ready} == 2'b00`) or when only `w_ready` is asserted (`2'b01`), clearing `wr_cnt_q` and asserting `wr_gnt_o` only when both `AW` and the final `W` beat have been accepted.

4. **Synthesis, area, and timing closure**:
   - When `icache_axi_top` (`flow/icache_axi_top.sv`) is synthesized with Yosys + Slang against Nangate45 (`lib/NangateOpenCellLibrary_typical.lib`) and timed in OpenROAD/OpenSTA (`lef/NangateOpenCellLibrary.tech.lef`, `lef/NangateOpenCellLibrary.macro.mod.lef`) as documented in `BUILD.md`, the design must infer zero latches, achieve a mapped cell area **`<= 8,200.0 um^2`**, and meet setup and hold timing (`slack >= 0.00 ns`) at a **`2.10 ns`** clock period (`0.20 ns` I/O delays, `5.0 fF` load). Edit only `code/cva6_icache.sv`, `code/cva6_icache_axi_wrapper.sv`, and `code/axi_shim.sv`.

---

## 3. Build & Verification Instructions (`BUILD.md`)

# Build, Simulation, and Synthesis/STA Environment

## Editable Files
Only the following files may be modified:
- `code/cva6_icache.sv`
- `code/cva6_icache_axi_wrapper.sv`
- `code/axi_shim.sv`

All other files in `code/`, `include/`, `flow/`, `lib/`, and `lef/` are read-only.
Editable RTL must remain technology-independent behavioral/structural SystemVerilog without directly instantiating library cell primitives (e.g., `BUF_X*`, `INV_X*`, `NAND*`, `DFF*`), `(* blackbox *)` modules, or introducing simulator/synthesis conditional compilation macros (`` `ifdef ``, `` `ifndef ``, `` `define ``). Each editable file must define only its own module (`cva6_icache`, `cva6_icache_axi_wrapper`, `axi_shim`), and `code/cva6_icache.sv` must preserve the `sram_cache` (`code/sram_cache.sv`) `tag_sram` and `data_sram` instantiations without replacing `sram_cache` with custom memory modules.

## Compilation Order (`Verilator` / `Yosys -m slang`)
With `-Iinclude`:
1. `code/config_pkg.sv`
2. `code/cv64a60ax_config_pkg.sv`
3. `code/riscv_pkg.sv`
4. `code/axi_pkg.sv`
5. `code/ariane_pkg.sv`
6. `code/wt_cache_pkg.sv`
7. `code/cf_math_pkg.sv`
8. `code/lzc.sv`
9. `code/lfsr.sv`
10. `code/sram_cache.sv`
11. `code/axi_shim.sv`
12. `code/cva6_icache.sv`
13. `code/cva6_icache_axi_wrapper.sv`

## Synthesis, Area, and STA Target
`icache_axi_top` (`flow/icache_axi_top.sv`) is synthesized with `yosys -m slang`:
```
read_slang --ignore-assertions --top icache_axi_top -Iinclude -DSYNTHESIS code/config_pkg.sv code/cv64a60ax_config_pkg.sv code/riscv_pkg.sv code/axi_pkg.sv code/ariane_pkg.sv code/wt_cache_pkg.sv code/cf_math_pkg.sv code/lzc.sv code/lfsr.sv code/sram_cache.sv code/axi_shim.sv code/cva6_icache.sv code/cva6_icache_axi_wrapper.sv flow/icache_axi_top.sv
hierarchy -check -top icache_axi_top
proc; opt_clean
select -assert-none */t:$dlatch* */t:$adlatch* */t:$latch* */t:$sr* */t:$_DLATCH*
synth -top icache_axi_top -flatten
opt
dfflibmap -liberty lib/NangateOpenCellLibrary_typical.lib
abc -liberty lib/NangateOpenCellLibrary_typical.lib
clean
read_liberty -lib lib/NangateOpenCellLibrary_typical.lib
check -assert
stat -liberty lib/NangateOpenCellLibrary_typical.lib
write_verilog -noattr mapped_icache_axi.v
```
and timed in OpenROAD/OpenSTA (`lef/NangateOpenCellLibrary.tech.lef`, `lef/NangateOpenCellLibrary.macro.mod.lef`, `lib/NangateOpenCellLibrary_typical.lib`) with:
- `create_clock -name clk_i -period 2.10 [get_ports clk_i]`
- `set_input_delay 0.20 -clock clk_i [all_inputs -no_clocks]`
- `set_output_delay 0.20 -clock clk_i [all_outputs]`
- `set_load 5.0 [all_outputs]`
Targets:
- Zero inferred latches (`$dlatch`, `$adlatch`, `$latch`, `$sr`, `$_DLATCH`)
- Mapped area `<= 8,200.0 um^2`
- Setup slack `>= 0.00 ns` and hold slack `>= 0.00 ns`
- Pure technology-independent behavioral/structural SystemVerilog preserving the `sram_cache` (`tag_sram` and `data_sram`) instances in `code/cva6_icache.sv` (no direct Nangate45 standard-cell instantiations, `blackbox` declarations, extra module definitions, or simulator/synthesis macro divergence)

---

## 4. Reference Fix Inspection (Buggy Starter vs. Golden Solution Diff)

> Human reviewers can inspect the exact reference bug fix below, or browse full files in [`environment/public/`](environment/public/), [`solution/gold/`](solution/gold/), and [`solution/alternate_gold/`](solution/alternate_gold/).

<details open>
<summary><b>Click to expand/collapse Unified Diff (<code>environment/public/</code> vs. <code>solution/gold/</code>)</b></summary>

```diff
--- a/environment/public/code/cva6_icache.sv (Buggy Starter)
+++ b/solution/gold/code/cva6_icache.sv (Golden Reference)
@@ -146,16 +146,16 @@
 
   // latch this in case we have to stall later on
   // make sure this is 32bit aligned
-  assign vaddr_d = (dreq_o.ready & dreq_i.req) ? dreq_i.vaddr : vaddr_q;
+  assign vaddr_d = (dreq_o.ready & dreq_i.req & ~dreq_i.kill_s1) ? dreq_i.vaddr : vaddr_q;
   assign areq_o.fetch_vaddr = (vaddr_q >> CVA6Cfg.FETCH_ALIGN_BITS) << CVA6Cfg.FETCH_ALIGN_BITS;
 
   // split virtual address into index and offset to address cache arrays
-  assign cl_index = vaddr_d[CVA6Cfg.ICACHE_INDEX_WIDTH-1:ICACHE_OFFSET_WIDTH];
+  assign cl_index = (cache_rden && dreq_i.req) ? dreq_i.vaddr[CVA6Cfg.ICACHE_INDEX_WIDTH-1:ICACHE_OFFSET_WIDTH] : vaddr_q[CVA6Cfg.ICACHE_INDEX_WIDTH-1:ICACHE_OFFSET_WIDTH];
 
 
   if (CVA6Cfg.NOCType == config_pkg::NOC_TYPE_AXI4_ATOP) begin : gen_axi_offset
     // if we generate a noncacheable access, the word will be at offset 0 or 4 in the cl coming from memory
-    assign cl_offset_d = ( dreq_o.ready & dreq_i.req)      ? (dreq_i.vaddr >> CVA6Cfg.FETCH_ALIGN_BITS) << CVA6Cfg.FETCH_ALIGN_BITS :
+    assign cl_offset_d = ( dreq_o.ready & dreq_i.req & ~dreq_i.kill_s1) ? (dreq_i.vaddr >> CVA6Cfg.FETCH_ALIGN_BITS) << CVA6Cfg.FETCH_ALIGN_BITS :
                          ( paddr_is_nc  & mem_data_req_o ) ? {{ICACHE_OFFSET_WIDTH-1{1'b0}}, cl_offset_q[2]}<<2 : // needed since we transfer 32bit over a 64bit AXI bus in this case
         cl_offset_q;
     // request word address instead of cl address in case of NC access
@@ -244,13 +244,10 @@
           if (!mem_rtrn_vld_i) begin
             dreq_o.ready = 1'b1;
             // we have a new request
-            if (dreq_i.req) begin
+            if (dreq_i.req && !dreq_i.kill_s1) begin
               cache_rden = 1'b1;
               state_d    = READ;
             end
-          end
-          if (dreq_i.kill_s1) begin
-            state_d = IDLE;
           end
         end
       end
@@ -281,14 +278,9 @@
             // note: we are not expecting ifill return packets here...
             if (!mem_rtrn_vld_i) begin
               dreq_o.ready = 1'b1;
-              if (dreq_i.req) begin
+              if (dreq_i.req && !dreq_i.kill_s1) begin
                 state_d = READ;
               end
-            end
-            // if a request is being killed at this stage,
-            // we have to bail out and wait for the address translation to complete
-            if (dreq_i.kill_s1) begin
-              state_d = IDLE;
             end
             // we have a miss / NC transaction
           end else if (dreq_i.kill_s2) begin
@@ -306,7 +298,7 @@
           end
           // bail out if this request is being killed (and we missed on the TLB)
         end else if (dreq_i.kill_s2 || flush_d) begin
-          state_d = KILL_ATRANS;
+          state_d = areq_i.fetch_valid ? IDLE : KILL_ATRANS;
         end
       end
       //////////////////////////////////

--- a/environment/public/code/cva6_icache_axi_wrapper.sv (Buggy Starter)
+++ b/solution/gold/code/cva6_icache_axi_wrapper.sv (Golden Reference)
@@ -79,7 +79,7 @@
   assign req_valid_d           = ~axi_rd_gnt & (icache_mem_data_req | req_valid_q);
 
   // Update read request information on a new request
-  assign req_data_d            = (icache_mem_data_req) ? icache_mem_data : req_data_q;
+  assign req_data_d            = (icache_mem_data_req && !req_valid_q) ? icache_mem_data : req_data_q;
 
   // We have a new or pending read request
   assign axi_rd_req            = icache_mem_data_req | req_valid_q;

--- a/environment/public/code/axi_shim.sv (Buggy Starter)
+++ b/solution/gold/code/axi_shim.sv (Golden Reference)
@@ -145,7 +145,7 @@
               2'b11:   wr_state_d = WAIT_LAST_W_READY;
               2'b01:   wr_state_d = WAIT_LAST_W_READY_AW_READY;
               2'b10:   wr_state_d = WAIT_LAST_W_READY;
-              default: ;
+              default: wr_state_d = WAIT_LAST_W_READY_AW_READY;
             endcase
           end else if (wr_single_req) begin  // its a single write
             wr_cnt_clr = 1'b1;

```

</details>

---

## 5. Harbor Package File Inventory & Provenance

### Public Workspace (`environment/public/`)
- [`environment/public/BUILD.md`](environment/public/BUILD.md) *(Read-Only Context)*
- [`environment/public/code/LICENSE`](environment/public/code/LICENSE) *(Read-Only Context)*
- [`environment/public/code/ariane_pkg.sv`](environment/public/code/ariane_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/axi_pkg.sv`](environment/public/code/axi_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/axi_shim.sv`](environment/public/code/axi_shim.sv) **(Editable)**
- [`environment/public/code/cf_math_pkg.sv`](environment/public/code/cf_math_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/config_pkg.sv`](environment/public/code/config_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/cv64a60ax_config_pkg.sv`](environment/public/code/cv64a60ax_config_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/cva6_icache.sv`](environment/public/code/cva6_icache.sv) **(Editable)**
- [`environment/public/code/cva6_icache_axi_wrapper.sv`](environment/public/code/cva6_icache_axi_wrapper.sv) **(Editable)**
- [`environment/public/code/lfsr.sv`](environment/public/code/lfsr.sv) *(Read-Only Context)*
- [`environment/public/code/lzc.sv`](environment/public/code/lzc.sv) *(Read-Only Context)*
- [`environment/public/code/riscv_pkg.sv`](environment/public/code/riscv_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/sram_cache.sv`](environment/public/code/sram_cache.sv) *(Read-Only Context)*
- [`environment/public/code/wt_cache_pkg.sv`](environment/public/code/wt_cache_pkg.sv) *(Read-Only Context)*
- [`environment/public/flow/icache_axi_top.sv`](environment/public/flow/icache_axi_top.sv) *(Read-Only Context)*
- [`environment/public/include/common_cells/LICENSE.Apache-2.0`](environment/public/include/common_cells/LICENSE.Apache-2.0) *(Read-Only Context)*
- [`environment/public/include/common_cells/assertions.svh`](environment/public/include/common_cells/assertions.svh) *(Read-Only Context)*
- [`environment/public/issue.md`](environment/public/issue.md) *(Read-Only Context)*
- [`environment/public/lef/NangateOpenCellLibrary.macro.mod.lef`](environment/public/lef/NangateOpenCellLibrary.macro.mod.lef) *(Read-Only Context)*
- [`environment/public/lef/NangateOpenCellLibrary.tech.lef`](environment/public/lef/NangateOpenCellLibrary.tech.lef) *(Read-Only Context)*
- [`environment/public/lib/LICENSE_NANGATE`](environment/public/lib/LICENSE_NANGATE) *(Read-Only Context)*
- [`environment/public/lib/NangateOpenCellLibrary_typical.lib`](environment/public/lib/NangateOpenCellLibrary_typical.lib) *(Read-Only Context)*

### Reference Solutions & Isolated Verifier (`solution/` & `tests/`)
- [`solution/solve.sh`](solution/solve.sh) — Harbor oracle script
- [`solution/gold/`](solution/gold/) — Primary golden reference solution
- [`solution/alternate_gold/`](solution/alternate_gold/) — Structurally distinct secondary reference solution
- [`tests/test.sh`](tests/test.sh) — Isolated Harbor verifier entrypoint
- [`tests/private/policy_filter.py`](tests/private/policy_filter.py) — Pre-grader airlock & anti-cheat policy screen
- [`tests/private/grader/run.py`](tests/private/grader/run.py) — Deterministic front-to-back EDA verifier

### Upstream Provenance (`SOURCE.md`)

