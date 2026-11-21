# `case_0083`: iDMA ND-Midend Zero-Transfer Rejection, Legalizer Page-Boundary Splitting, and Timing Closure

[Back to Benchmark Root (`README.md`)](../../README.md) | [Full 94-Task Catalog (`TASKS_INDEX.md`)](../../TASKS_INDEX.md) | [`task.toml`](task.toml) | [`instruction.md`](instruction.md) | [`solution/solve.sh`](solution/solve.sh) | [`tests/test.sh`](tests/test.sh) | [`tests/private/grader/run.py`](tests/private/grader/run.py)

---

## 1. Task Overview & Harbor Configuration

| Field | Value |
| :--- | :--- |
| **Task ID** | `case_0083` |
| **Source Silicon Repository** | `pulp-platform/idma` (`repo_23`) |
| **Engineering Problem Type** | **Architectural & Protocol Bug Repair** (`PT1_Arch_Protocol_Bug_Repair`) |
| **EDA Evaluation Stage** | **Stage 3: Static Timing (STA) & CDC/RDC Closure** (`stage3_sta_cdc`) |
| **Coupled Evaluation Gates** | Stage 1 (Functional RTL Sim) -> Stage 2 (Logic Synthesis & Gate-Level Verification) -> Stage 3 (OpenSTA Single-/Multi-Corner Setup/Hold WNS/TNS & CDC/RDC Closure) |
| **Primary Hardware Domain** | `rtl_integration` (Multi-Module Reuse, Port Contracts, Interfaces & Subsystem Integration) |
| **Multi-Domain Tags** | `rtl_integration` |
| **Editable Files (`allowed_edits`)** | [`code/idma_nd_midend.sv`](environment/public/code/idma_nd_midend.sv), [`code/idma_legalizer_page_splitter.sv`](environment/public/code/idma_legalizer_page_splitter.sv), [`code/idma_legalizer.sv`](environment/public/code/idma_legalizer.sv) (3 files, 668 LOC) |
| **Public Subsystem Context** | 15 RTL files (3046 LOC) |
| **Base Container Image** | `siliconbench-eda:1.0` (`allow_internet = false`, `environment_mode = "separate"`) |
| **PDK / Environment Profile** | **Nangate45 45nm Open Cell Library + Task Multi-Corner Liberty/SDC** |
| **Task-Customized Collateral?** | **Yes (Task-Bundled Collateral)** — Uses shared Nangate45 library for synthesis plus task-bundled fast/slow/scan corner timing views. |
| **Verifier Timeout & Seeds** | `600s` total (`300s`/seed) across deterministic seeds `[101, 202]` |

---

## 2. Problem Specification (`issue.md`)

# iDMA ND-Midend Zero-Transfer Rejection, Legalizer Page-Boundary Splitting, and Timing Closure

In the iDMA multi-dimensional transfer and burst legalization subsystem (`code/idma_nd_legalizer_top.sv`), repair `code/idma_nd_midend.sv`, `code/idma_legalizer_page_splitter.sv`, and `code/idma_legalizer.sv`. In `code/idma_nd_midend.sv`, expand multi-dimensional transfers across outer repetition counts (`req_reps_i`) and strides (`req_src_strides_i`, `req_dst_strides_i`, `req_scale_strides_i`), marking only the final 1D burst with `burst_req_o.opt.last == 1'b1` and asserting `nd_rsp_valid_o` on normal transfers only when `burst_rsp_valid_i && burst_rsp_i.last`; when all outer repetition counts are zero (`req_reps_i == '0`), suppress `burst_req_valid_o`, deassert `burst_rsp_ready_o`, and complete on `nd_rsp_valid_o && nd_rsp_ready_i` with `nd_rsp_o.error == 1'b1` and `nd_rsp_o.pld.err_type == idma_pkg::ND_MIDEND`.

In `code/idma_legalizer_page_splitter.sv` and `code/idma_legalizer.sv`, compute the remaining bytes to the active virtual page boundary (`OffsetWidth` when `not_bursting_i`, otherwise `min(12, OffsetWidth + (reduce_len_i ? max_llen_i : BurstLen))`), splitting coupled transfers (`!req_decouple_rw_i`) at the closer of the source and destination page boundaries with lockstep `r_ready_i && w_ready_i` handshaking and splitting decoupled transfers (`req_decouple_rw_i`) independently per channel, while honoring `flush_i` pause and `kill_i` abort semantics. Under the Nangate45 synthesis and OpenROAD STA flow in `BUILD.md` (`idma_nd_legalizer_top`, `2.70 ns` clock on `clk_i`, `0.15 ns` I/O delays, `5.0 fF` load), achieve mapped area `<= 3680.0 um^2` and setup/hold slack `>= 0.0 ns`.

---

## 3. Build & Verification Instructions (`BUILD.md`)

# Build, Simulation, Synthesis, and Timing Evaluation Guide

## 1. Editable Scope and Read-Only Dependencies

Editable RTL files:
- `code/idma_nd_midend.sv`
- `code/idma_legalizer_page_splitter.sv`
- `code/idma_legalizer.sv`

All other files in `code/` (`idma_nd_legalizer_top.sv`, `idma_pkg.sv`, `axi_pkg.sv`, `cc_pkg.sv`, `cc_popcount.sv`, `include/*`) and `lib/` (`NangateOpenCellLibrary_typical.lib`, `NangateOpenCellLibrary.tech.lef`, `NangateOpenCellLibrary.macro.mod.lef`) are read-only.

## 2. Behavioral Verification (Verilator)

Compile and simulate `idma_nd_legalizer_top` with Verilator:

```bash
verilator --binary --timing -j 1 -Wno-fatal -Icode/include -DSYNTHESIS \
  --top-module tb \
  code/cc_pkg.sv code/axi_pkg.sv code/idma_pkg.sv code/cc_popcount.sv \
  code/idma_legalizer_page_splitter.sv code/idma_legalizer.sv \
  code/idma_nd_midend.sv code/idma_nd_legalizer_top.sv /tmp/tb.sv
```

## 3. Nangate45 Mapped Area Flow (Yosys + Slang)

Run Yosys with the Slang frontend on `idma_nd_legalizer_top`:

```bash
yosys -m slang -Q -T -p "
  read_slang --top idma_nd_legalizer_top -Icode/include -DSYNTHESIS \
    code/cc_pkg.sv code/axi_pkg.sv code/idma_pkg.sv code/cc_popcount.sv \
    code/idma_legalizer_page_splitter.sv code/idma_legalizer.sv \
    code/idma_nd_midend.sv code/idma_nd_legalizer_top.sv;
  hierarchy -check -top idma_nd_legalizer_top;
  synth -top idma_nd_legalizer_top;
  opt;
  dfflibmap -liberty lib/NangateOpenCellLibrary_typical.lib;
  abc -liberty lib/NangateOpenCellLibrary_typical.lib;
  clean;
  read_liberty -lib lib/NangateOpenCellLibrary_typical.lib;
  check -assert;
  stat -liberty lib/NangateOpenCellLibrary_typical.lib;
  write_verilog -noattr /tmp/mapped.v
"
```

Target mapped cell area (`Chip area for module '\idma_nd_legalizer_top'`): **`<= 3680.0 um^2`**.

## 4. Static Timing Analysis Flow (OpenROAD / OpenSTA)

Evaluate `/tmp/mapped.v` in OpenROAD with a `2.70 ns` clock period on `clk_i`, `0.15 ns` input/output delays, `5.0 fF` output load, and false path from asynchronous reset `rst_ni`:

```tcl
read_lef lib/NangateOpenCellLibrary.tech.lef
read_lef lib/NangateOpenCellLibrary.macro.mod.lef
read_liberty lib/NangateOpenCellLibrary_typical.lib
read_verilog /tmp/mapped.v
link_design idma_nd_legalizer_top
create_clock -name clk_i -period 2.70 [get_ports clk_i]
set_input_delay 0.15 -clock clk_i [all_inputs -no_clocks]
set_output_delay 0.15 -clock clk_i [all_outputs]
set_load 5.0 [all_outputs]
set_false_path -from [get_ports rst_ni]
check_setup -verbose
puts "=== SETUP ==="
report_checks -path_delay max -format full_clock_expanded -digits 4
puts "=== HOLD ==="
report_checks -path_delay min -format full_clock_expanded -digits 4
```

Target worst setup slack (`-path_delay max`) and worst hold slack (`-path_delay min`): **`>= 0.0 ns`**.

---

## 4. Reference Fix Inspection (Buggy Starter vs. Golden Solution Diff)

> Human reviewers can inspect the exact reference bug fix below, or browse full files in [`environment/public/`](environment/public/), [`solution/gold/`](solution/gold/), and [`solution/alternate_gold/`](solution/alternate_gold/).

<details open>
<summary><b>Click to expand/collapse Unified Diff (<code>environment/public/</code> vs. <code>solution/gold/</code>)</b></summary>

```diff
--- a/environment/public/code/idma_nd_midend.sv (Buggy Starter)
+++ b/solution/gold/code/idma_nd_midend.sv (Golden Reference)
@@ -107,7 +107,7 @@
     assign adv  = zero ? nd_rsp_ready_i : burst_req_ready_i;
 
     // assign handshake on the output
-    assign burst_req_valid_o = nd_req_valid_i;
+    assign burst_req_valid_o = nd_req_valid_i & !zero;
 
     // buffer burst_req handshake
     assign burst_sent_d = burst_req_valid_o & burst_req_ready_i;
@@ -173,28 +173,40 @@
     //--------------------------------------
     // Select the active stride
     //--------------------------------------
-    addr_t [NumDim-2:0] src_cand, dst_cand, scale_cand;
-    idma_nd_req_t held_nd_req_q;
-    `FFL(held_nd_req_q, nd_req_i, nd_req_valid_i && !burst_sent_q, '0, clk_i, rst_ni)
-    for (genvar g = 0; g < NumDim - 1; g++) begin : gen_cand_add
-        assign src_cand[g]   = src_addr_q + (nd_req_valid_i ? nd_req_i.d_req[g].src_strides : held_nd_req_q.d_req[g].src_strides);
-        assign dst_cand[g]   = dst_addr_q + (nd_req_valid_i ? nd_req_i.d_req[g].dst_strides : held_nd_req_q.d_req[g].dst_strides);
-        assign scale_cand[g] = scale_addr_q + (nd_req_valid_i ? nd_req_i.d_req[g].scale_strides : held_nd_req_q.d_req[g].scale_strides);
-    end
     always_comb begin : src_addr_calc
-        if (stride_sel_q == NumDim - 1) src_addr_d = nd_req_i.burst_req.src_addr;
-        else if (burst_sent_q)          src_addr_d = src_cand[stride_sel_q];
-        else                            src_addr_d = src_addr_q;
-    end
+        if (stride_sel_q == NumDim - 1) begin
+            src_addr_d = nd_req_i.burst_req.src_addr;
+        end else begin
+            if (burst_sent_q) begin
+                src_addr_d = src_addr_q + nd_req_i.d_req[stride_sel_q].src_strides;
+            end else begin
+                src_addr_d = src_addr_q;
+            end
+        end
+    end
+
     always_comb begin : dst_addr_calc
-        if (stride_sel_q == NumDim - 1) dst_addr_d = nd_req_i.burst_req.dst_addr;
-        else if (burst_sent_q)          dst_addr_d = dst_cand[stride_sel_q];
-        else                            dst_addr_d = dst_addr_q;
-    end
+        if (stride_sel_q == NumDim - 1) begin
+            dst_addr_d = nd_req_i.burst_req.dst_addr;
+        end else begin
+            if (burst_sent_q) begin
+                dst_addr_d = dst_addr_q + nd_req_i.d_req[stride_sel_q].dst_strides;
+            end else begin
+                dst_addr_d = dst_addr_q;
+            end
+        end
+    end
+
     always_comb begin : scale_addr_calc
-        if (stride_sel_q == NumDim - 1) scale_addr_d = nd_req_i.burst_req.scale_addr;
-        else if (burst_sent_q)          scale_addr_d = scale_cand[stride_sel_q];
-        else                            scale_addr_d = scale_addr_q;
+        if (stride_sel_q == NumDim - 1) begin
+            scale_addr_d = nd_req_i.burst_req.scale_addr;
+        end else begin
+            if (burst_sent_q) begin
+                scale_addr_d = scale_addr_q + nd_req_i.d_req[stride_sel_q].scale_strides;
+            end else begin
+                scale_addr_d = scale_addr_q;
+            end
+        end
     end
 
 
@@ -218,7 +230,7 @@
     always_comb begin : proc_modify_response_zero_length
         // default: bypass
         nd_rsp_o          = burst_rsp_i;
-        nd_rsp_valid_o    = burst_rsp_valid_i;
+        nd_rsp_valid_o    = burst_rsp_valid_i & burst_rsp_i.last;
         burst_rsp_ready_o = nd_rsp_ready_i;
 
         // a zero transfer happens

--- a/environment/public/code/idma_legalizer_page_splitter.sv (Buggy Starter)
+++ b/solution/gold/code/idma_legalizer_page_splitter.sv (Golden Reference)
@@ -51,7 +51,7 @@
     always_comb begin : proc_range_select
         page_offset = '0;
         for (int i = 0; i < PageAddrWidth; i++) begin
-            page_offset[i] = page_addr_width < i ? addr_i[i] : 1'b0;
+            page_offset[i] = page_addr_width > i ? addr_i[i] : 1'b0;
         end
     end
 

--- a/environment/public/code/idma_legalizer.sv (Buggy Starter)
+++ b/solution/gold/code/idma_legalizer.sv (Golden Reference)
@@ -109,7 +109,7 @@
     assign w_num_bytes_to_pb = w_page_num_bytes_to_pb;
 
     assign c_num_bytes_to_pb = (r_num_bytes_to_pb > w_num_bytes_to_pb) ?
-                                r_num_bytes_to_pb : w_num_bytes_to_pb;
+                                w_num_bytes_to_pb : r_num_bytes_to_pb;
 
     always_comb begin : proc_num_bytes_possible
         r_num_bytes_possible = c_num_bytes_to_pb;
@@ -181,6 +181,7 @@
     assign ld_in = load(req_i);
 
     always_comb begin : proc_read_write_transaction
+        logic r_fits_r, r_fits_w, w_fits_w, w_fits_r;
         r_tf_d   = r_tf_q;
         w_tf_d   = w_tf_q;
         opt_tf_d = opt_tf_q;
@@ -188,24 +189,34 @@
         r_done = 1'b0;
         w_done = 1'b0;
 
-        if (r_tf_q.length > r_num_bytes_possible) begin
+        r_fits_r = ~(|r_tf_q.length[$bits(r_tf_q.length)-1:PageAddrWidth+1]) &&
+                   (r_tf_q.length[PageAddrWidth:0] <= r_num_bytes_to_pb);
+        r_fits_w = ~(|r_tf_q.length[$bits(r_tf_q.length)-1:PageAddrWidth+1]) &&
+                   (r_tf_q.length[PageAddrWidth:0] <= w_num_bytes_to_pb);
+        w_fits_w = ~(|w_tf_q.length[$bits(w_tf_q.length)-1:PageAddrWidth+1]) &&
+                   (w_tf_q.length[PageAddrWidth:0] <= w_num_bytes_to_pb);
+        w_fits_r = ~(|w_tf_q.length[$bits(w_tf_q.length)-1:PageAddrWidth+1]) &&
+                   (w_tf_q.length[PageAddrWidth:0] <= r_num_bytes_to_pb);
+
+        r_done = opt_tf_q.decouple_rw ? r_fits_r : (r_fits_r & r_fits_w);
+        w_done = opt_tf_q.decouple_rw ? w_fits_w : (w_fits_w & w_fits_r);
+
+        if (!r_done) begin
             r_num_bytes   = r_num_bytes_possible;
             r_tf_d.length = r_tf_q.length - r_num_bytes_possible;
             r_tf_d.addr   = r_tf_q.addr + r_num_bytes;
         end else begin
             r_num_bytes  = r_tf_q.length[PageAddrWidth:0];
             r_tf_d.valid = 1'b0;
-            r_done       = 1'b1;
-        end
-
-        if (w_tf_q.length > w_num_bytes_possible) begin
+        end
+
+        if (!w_done) begin
             w_num_bytes   = w_num_bytes_possible;
             w_tf_d.length = w_tf_q.length - w_num_bytes_possible;
             w_tf_d.addr   = w_tf_q.addr + w_num_bytes;
         end else begin
             w_num_bytes  = w_tf_q.length[PageAddrWidth:0];
             w_tf_d.valid = 1'b0;
-            w_done       = 1'b1;
         end
 
         if (kill_i) begin
@@ -289,7 +300,7 @@
             r_valid_o = r_tf_q.valid & r_ready_i & !flush_i;
             w_valid_o = w_tf_q.valid & w_ready_i & !flush_i;
         end else begin
-            r_tf_ena  = (r_ready_i & !flush_i) | kill_i;
+            r_tf_ena  = (r_ready_i & w_ready_i & !flush_i) | kill_i;
             w_tf_ena  = (r_ready_i & w_ready_i & !flush_i) | kill_i;
             r_valid_o = r_tf_q.valid & w_ready_i & r_ready_i & !flush_i;
             w_valid_o = w_tf_q.valid & r_ready_i & w_ready_i & !flush_i;

```

</details>

---

## 5. Harbor Package File Inventory & Provenance

### Public Workspace (`environment/public/`)
- [`environment/public/BUILD.md`](environment/public/BUILD.md) *(Read-Only Context)*
- [`environment/public/code/LICENSE`](environment/public/code/LICENSE) *(Read-Only Context)*
- [`environment/public/code/axi_pkg.sv`](environment/public/code/axi_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/cc_pkg.sv`](environment/public/code/cc_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/cc_popcount.sv`](environment/public/code/cc_popcount.sv) *(Read-Only Context)*
- [`environment/public/code/idma_legalizer.sv`](environment/public/code/idma_legalizer.sv) **(Editable)**
- [`environment/public/code/idma_legalizer_page_splitter.sv`](environment/public/code/idma_legalizer_page_splitter.sv) **(Editable)**
- [`environment/public/code/idma_nd_legalizer_top.sv`](environment/public/code/idma_nd_legalizer_top.sv) *(Read-Only Context)*
- [`environment/public/code/idma_nd_midend.sv`](environment/public/code/idma_nd_midend.sv) **(Editable)**
- [`environment/public/code/idma_pkg.sv`](environment/public/code/idma_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/include/axi/typedef.svh`](environment/public/code/include/axi/typedef.svh) *(Read-Only Context)*
- [`environment/public/code/include/common_cells/assertions.svh`](environment/public/code/include/common_cells/assertions.svh) *(Read-Only Context)*
- [`environment/public/code/include/common_cells/deprecated/registers.svh`](environment/public/code/include/common_cells/deprecated/registers.svh) *(Read-Only Context)*
- [`environment/public/code/include/common_cells/registers.svh`](environment/public/code/include/common_cells/registers.svh) *(Read-Only Context)*
- [`environment/public/code/include/idma/compute.svh`](environment/public/code/include/idma/compute.svh) *(Read-Only Context)*
- [`environment/public/code/include/idma/guard.svh`](environment/public/code/include/idma/guard.svh) *(Read-Only Context)*
- [`environment/public/code/include/idma/typedef.svh`](environment/public/code/include/idma/typedef.svh) *(Read-Only Context)*
- [`environment/public/issue.md`](environment/public/issue.md) *(Read-Only Context)*
- [`environment/public/lib/LICENSE.Nangate45`](environment/public/lib/LICENSE.Nangate45) *(Read-Only Context)*
- [`environment/public/lib/NangateOpenCellLibrary.macro.mod.lef`](environment/public/lib/NangateOpenCellLibrary.macro.mod.lef) *(Read-Only Context)*
- [`environment/public/lib/NangateOpenCellLibrary.tech.lef`](environment/public/lib/NangateOpenCellLibrary.tech.lef) *(Read-Only Context)*
- [`environment/public/lib/NangateOpenCellLibrary_typical.lib`](environment/public/lib/NangateOpenCellLibrary_typical.lib) *(Read-Only Context)*

### Reference Solutions & Isolated Verifier (`solution/` & `tests/`)
- [`solution/solve.sh`](solution/solve.sh) — Harbor oracle script
- [`solution/gold/`](solution/gold/) — Primary golden reference solution
- [`solution/alternate_gold/`](solution/alternate_gold/) — Structurally distinct secondary reference solution
- [`tests/test.sh`](tests/test.sh) — Isolated Harbor verifier entrypoint
- [`tests/private/policy_filter.py`](tests/private/policy_filter.py) — Pre-grader airlock & anti-cheat policy screen
- [`tests/private/grader/run.py`](tests/private/grader/run.py) — Deterministic front-to-back EDA verifier

### Upstream Provenance (`SOURCE.md`)

