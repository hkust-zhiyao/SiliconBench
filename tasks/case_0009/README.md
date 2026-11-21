# `case_0009`: Keep HWPE Micro-Loop Multi-Op Results, Loop Metadata, and Clears Coherent Across Stalls

[Back to Benchmark Root (`README.md`)](../../README.md) | [Full 94-Task Catalog (`TASKS_INDEX.md`)](../../TASKS_INDEX.md) | [`task.toml`](task.toml) | [`instruction.md`](instruction.md) | [`solution/solve.sh`](solution/solve.sh) | [`tests/test.sh`](tests/test.sh) | [`tests/private/grader/run.py`](tests/private/grader/run.py)

---

## 1. Task Overview & Harbor Configuration

| Field | Value |
| :--- | :--- |
| **Task ID** | `case_0009` |
| **Source Silicon Repository** | `pulp-platform/hwpe-ctrl` (`repo_33`) |
| **Engineering Problem Type** | **Architectural & Protocol Bug Repair** (`PT1_Arch_Protocol_Bug_Repair`) |
| **EDA Evaluation Stage** | **Stage 1: Frontend RTL Design & Functional Simulation** (`stage1_rtl_sim`) |
| **Coupled Evaluation Gates** | Stage 1 (SystemVerilog Lint & Policy -> Multi-Simulator Cycle-Accurate & 4-State Functional RTL Verification -> Latch/Loop-Free Elaboration) |
| **Primary Hardware Domain** | `rtl_integration` (Multi-Module Reuse, Port Contracts, Interfaces & Subsystem Integration) |
| **Multi-Domain Tags** | `reset_rdc`, `rtl_integration` |
| **Editable Files (`allowed_edits`)** | [`code/hwpe_ctrl_uloop.sv`](environment/public/code/hwpe_ctrl_uloop.sv) (1 files, 495 LOC) |
| **Public Subsystem Context** | 2 RTL files (648 LOC) |
| **Base Container Image** | `siliconbench-eda:1.0` (`allow_internet = false`, `environment_mode = "separate"`) |
| **PDK / Environment Profile** | **Standard IEEE 1800-2017 SystemVerilog Dual-Simulator + Yosys Slang** |
| **Task-Customized Collateral?** | **No (Uses Shared Base Image)** — Pure RTL/protocol/synthesis check without external PDK Liberty files. |
| **Verifier Timeout & Seeds** | `600s` total (`300s`/seed) across deterministic seeds `[101, 202]` |

---

## 2. Problem Specification (`issue.md`)

# Keep micro-loop multi-operation results, loop metadata, and clears coherent across stalls

The accelerator consumes shadowed micro-loop results more slowly than the processor can prepare the next iteration. When `ctrl_i.ready` pauses computation during a multi-operation loop body or while a completed result waits for `ctrl_i.enable`, partially updated results can be published and the reported loop number (`flags_o.loop`) can drift away from the offsets and indices it describes.

Update `code/hwpe_ctrl_uloop.sv` so that when `flags_o.valid` is high, `flags_o.loop`, `flags_o.offs`, `flags_o.idx`, and `flags_o.idx_update` always describe the same completed loop-body iteration without partial mid-body updates across pauses, and so that asserting either `clear_i` or `ctrl_i.clear` discards all pending and visible state before a subsequent job. Preserve the existing microcode semantics, handshakes, offsets, and index progression across both shadowed (`SHADOWED = 1`) and unshadowed (`SHADOWED = 0`) configurations.

---

## 3. Build & Verification Instructions (`BUILD.md`)

The package and micro-loop RTL come from `pulp-platform/hwpe-ctrl` commit `558fe3db3413909878c03aed543257d94a57bae5`. Compile `code/hwpe_ctrl_package.sv` before `code/hwpe_ctrl_uloop.sv`; Verilator supports the packed types used here. The source header in `code/hwpe_ctrl_uloop.sv` documents the microcode programming model, parameters, and `ctrl_i` / `flags_o` handshake interface.

`code/hwpe_ctrl_uloop.sv` is the only editable file; `code/hwpe_ctrl_package.sv` is read-only.

For a quick syntax and elaboration check from the workspace root, run:
```bash
verilator --lint-only -Wno-fatal -DSYNTHESIS --top-module hwpe_ctrl_uloop code/hwpe_ctrl_package.sv code/hwpe_ctrl_uloop.sv
```

---

## 4. Reference Fix Inspection (Buggy Starter vs. Golden Solution Diff)

> Human reviewers can inspect the exact reference bug fix below, or browse full files in [`environment/public/`](environment/public/), [`solution/gold/`](solution/gold/), and [`solution/alternate_gold/`](solution/alternate_gold/).

<details open>
<summary><b>Click to expand/collapse Unified Diff (<code>environment/public/</code> vs. <code>solution/gold/</code>)</b></summary>

```diff
--- a/environment/public/code/hwpe_ctrl_uloop.sv (Buggy Starter)
+++ b/solution/gold/code/hwpe_ctrl_uloop.sv (Golden Reference)
@@ -17,135 +17,6 @@
  * CONDITIONS OF ANY KIND, either express or implied. See the License for the
  * specific language governing permissions and limitations under the License.
  */
-
-/**
- * The **hwpe_ctrl_uloop** (micro-loop processor) module
- * implements a very simple microcode processor that can be used to execute
- * the main computation block of an HWPE multiple times according to a set
- * of nested loops, while updating a handful of architectural state
- * registers between iterations. These registers are typically used to
- * generate base offsets that are forwarded to the HWPE address generators
- * to walk through tensors larger than what is described in a single job.
- *
- * The microcode processor implements *NB_LOOPS* nested loops (default 6).
- * The innermost loop is loop 0, then loop 1, and so on. The number of
- * iterations of each loop is configured at runtime through the
- * `ctrl_i.range` field of `uloop_code_i`. After every iteration of any
- * loop, the processor executes the sequence of operations associated
- * to that loop (its *body*), then starts/continues the next inner loop;
- * once the innermost loop completes, control returns to the next outer
- * loop. When the outermost loop has executed its last iteration the
- * `flags_o.done` signal is asserted.
- *
- * The architectural state is a register file with two sections:
- *
- * * *NB_REG* R/W registers (default 4) of width *REG_WIDTH* (default 32 bit).
- *   These can be both the destination *RA* and the source *RB* of a uloop
- *   instruction. Their value is exposed to the outside on `flags_o.offs`
- *   and is typically used as a base offset to feed the HWPE address
- *   generators.
- * * *NB_RO_REG* read-only registers (default 12, max 32) provided
- *   externally via `registers_read_i`. These can only be used as the *RB*
- *   source operand and are typically programmed once per job (e.g. through
- *   job-independent registers) to encode tensor strides, sizes, etc.
- *
- * The microcode supports two instructions:
- *
- * * **add** (`op_sel=1`): performs ``RA := RA + RB`` (RA is one of the
- *   R/W registers, RB is any register).
- * * **mv** (`op_sel=0`): performs ``RA := RB``.
- *
- * Each bytecode word (`uloop_bytecode_t`) is 11 bits wide and packs together
- * `op_sel` (1 bit), `a` (5 bits, selects RA) and `b` (5 bits, selects RB).
- * All operation words of all loop bodies are concatenated into a single
- * code array of up to *LENGTH* entries (default 32). A separate
- * `uloop_loops_t` per-loop header (9 bits: 5 bits `uloop_addr` + 4 bits
- * `nb_ops`) tells the processor where each loop body starts in the code
- * array and how many operations it contains.
- *
- * The microcode is normally specified at a high level as a YAML file (see
- * `uloop-example/code.yml` in the *hwpe-ctrl* repository) and compiled
- * into the two bit fields (code + loops) by the `uloop_compile.py`
- * Python helper. The resulting bit fields are typically either hardwired
- * inside an HWPE wrapper or programmed at runtime through job-independent
- * registers.
- *
- * Example YAML body (excerpt from `uloop-example/code.yml`)::
- *
- *     loop_stream_inner: # innermost: for jj in range(0, nif/TP)
- *       - { op: add, a: W,       b: TPin }
- *       - { op: add, a: x,       b: TPin }
- *     loop_filter_x:     # for k in range(0, fs)
- *       - { op: add, a: W,       b: TPin }
- *       - { op: add, a: x,       b: TPin }
- *     loop_filter_y:     # for l in range(0, fs)
- *       - { op: add, a: W,       b: TPin }
- *       - { op: add, a: x,       b: x_iter }
- *     loop_stream_outer: # for ii in range(0, nof/TP)
- *       - { op: add, a: W,       b: TPin }
- *       - { op: add, a: y,       b: TPout }
- *       - { op: mv,  a: x,       b: x_major }
- *
- * Here ``W``, ``x``, ``y``, ``x_major`` are mnemonics for R/W registers
- * (RA-eligible) while ``TPin``, ``TPout``, ``x_iter`` are mnemonics for
- * R/O registers programmed once per job; the compiler converts the
- * mnemonics into the right 5-bit indices and emits a single hex bit field
- * for the whole code array and a second one for the per-loop headers.
- *
- * When *SHADOWED* is 1, the uloop is double-buffered: a shadow register
- * latches the freshly-computed `flags_o` and exposes it externally as soon
- * as the consumer (e.g. the controller FSM) asserts `ctrl_i.enable`, so
- * that one set of indices/offsets can be consumed while the next is being
- * computed.
- *
- * .. tabularcolumns:: |l|l|J|
- * .. _hwpe_ctrl_uloop_params:
- * .. table:: **hwpe_ctrl_uloop** design-time parameters.
- *
- *   +-----------------+----------------------------------+-------------------------------------------------------------------------+
- *   | **Name**        | **Default**                      | **Description**                                                         |
- *   +-----------------+----------------------------------+-------------------------------------------------------------------------+
- *   | *LENGTH*        | `ULOOP_MAX_LENGTH` (32)          | Maximum total number of bytecode operations across all loops.           |
- *   +-----------------+----------------------------------+-------------------------------------------------------------------------+
- *   | *NB_LOOPS*      | `ULOOP_MAX_NB_LOOPS` (6)         | Number of nested loops implemented.                                     |
- *   +-----------------+----------------------------------+-------------------------------------------------------------------------+
- *   | *NB_REG*        | `ULOOP_MAX_NB_REG` (9)           | Number of R/W (RA-eligible) registers in the internal register file.   |
- *   +-----------------+----------------------------------+-------------------------------------------------------------------------+
- *   | *NB_RO_REG*     | `ULOOP_MAX_NB_RO_REG` (32)       | Number of R/O (RB-only) registers driven externally.                    |
- *   +-----------------+----------------------------------+-------------------------------------------------------------------------+
- *   | *REG_WIDTH*     | `ULOOP_MAX_REG_WIDTH` (32)       | Width in bits of each register and computed offset.                     |
- *   +-----------------+----------------------------------+-------------------------------------------------------------------------+
- *   | *CNT_WIDTH*     | `ULOOP_MAX_CNT_WIDTH` (12)       | Width in bits of each loop iteration counter.                           |
- *   +-----------------+----------------------------------+-------------------------------------------------------------------------+
- *   | *SHADOWED*      | `ULOOP_DEFAULT_SHADOWED` (1)     | If 1, double-buffer outputs through a shadow register.                  |
- *   +-----------------+----------------------------------+-------------------------------------------------------------------------+
- *   | *DEBUG_DISPLAY* | 0                                | If 1, print simulation traces of microcode execution.                   |
- *   +-----------------+----------------------------------+-------------------------------------------------------------------------+
- *
- * .. tabularcolumns:: |l|l|J|
- * .. _hwpe_ctrl_uloop_flags:
- * .. table:: **hwpe_ctrl_uloop** output flags (`flags_o`).
- *
- *   +---------------+----------------------------------------+-------------------------------------------------------------------+
- *   | **Name**      | **Type**                               | **Description**                                                   |
- *   +---------------+----------------------------------------+-------------------------------------------------------------------+
- *   | *done*        | `logic`                                | 1 when the outermost loop has completed all its iterations.       |
- *   +---------------+----------------------------------------+-------------------------------------------------------------------+
- *   | *valid*       | `logic`                                | 1 when `offs` / `idx` hold a freshly-computed set of values.      |
- *   +---------------+----------------------------------------+-------------------------------------------------------------------+
- *   | *ready*       | `logic`                                | 1 when the uloop can accept a new `ctrl_i.enable` pulse.          |
- *   +---------------+----------------------------------------+-------------------------------------------------------------------+
- *   | *offs*        | `logic [NB_REG-1:0][REG_WIDTH-1:0]`    | Current value of each R/W register (typical streamer offsets).    |
- *   +---------------+----------------------------------------+-------------------------------------------------------------------+
- *   | *idx*         | `logic [NB_LOOPS-1:0][CNT_WIDTH-1:0]`  | Current iteration counter of each loop.                           |
- *   +---------------+----------------------------------------+-------------------------------------------------------------------+
- *   | *idx_update*  | `logic [NB_LOOPS-1:0]`                 | 1 for each loop whose iteration index just changed.               |
- *   +---------------+----------------------------------------+-------------------------------------------------------------------+
- *   | *loop*        | `logic [$clog2(NB_LOOPS)-1:0]`         | Index of the loop whose body was executed last.                   |
- *   +---------------+----------------------------------------+-------------------------------------------------------------------+
- *
- */
-
 
 module hwpe_ctrl_uloop
   import hwpe_ctrl_package::*;
@@ -205,8 +76,8 @@
       flags_valid <= '0;
     end
     else begin
-      flags_valid <= busy_sticky & ~busy_int;
-      if(~busy_int)
+      flags_valid <= busy_sticky & ~busy_int & enable_int;
+      if(~busy_int && enable_int)
         busy_sticky <= 1'b0;
       else if(enable_int)
         busy_sticky <= 1'b1;
@@ -298,7 +169,7 @@
 `endif
       next_addr = uloop_code_i.loops[curr_loop].uloop_addr;
       next_op   = '0;
-      next_idx[curr_loop] = curr_idx + 1;
+      next_idx[curr_loop] = curr_idx[curr_loop] + 1;
       exec_int  = 1'b1;
     end
     // if not, go to next loop
@@ -403,7 +274,7 @@
     for(genvar i=NB_LOOPS; i<hwpe_ctrl_package::ULOOP_MAX_NB_LOOPS; i++) begin : flags_idx_update_assign_rem
       assign flags_int.idx_update [i] = '0;
     end
-    assign flags_int.loop = '0;
+    assign flags_int.loop = out_loop;
 
   endgenerate
 
@@ -412,9 +283,9 @@
   begin
     if(~rst_ni)
       out_loop <= '0;
-    else if(clear_i)
+    else if(clear_i | ctrl_i.clear)
       out_loop <= '0;
-    else if(exec_int)
+    else if(enable_int && exec_int)
       out_loop <= curr_loop;
   end
 
@@ -426,14 +297,14 @@
       logic out_valid;
 
       // when the shadow register is not valid, enable the uloop
-      assign enable_int = ~shadow_flags_wr.valid & ~flags_valid & ~flags_int.done & ~clear_i & ctrl_i.ready;
+      assign enable_int = ~shadow_flags_wr.valid & ~flags_valid & ~flags_int.done & ~(clear_i | ctrl_i.clear) & ctrl_i.ready;
 
       // the shadow register is updated when flags_valid is 1'b1
       always_ff @(posedge clk_i or negedge rst_ni)
       begin
         if(~rst_ni)
           shadow_flags_wr <= '0;
-        else if(clear_i | ctrl_i.enable)
+        else if(clear_i | ctrl_i.clear | ctrl_i.enable)
           shadow_flags_wr <= '0;
         else if (flags_int.valid | flags_int.done)
           shadow_flags_wr <= flags_int;
@@ -444,7 +315,7 @@
       begin
         if(~rst_ni)
           out_valid <= 1'b0;
-        else if(clear_i)
+        else if(clear_i | ctrl_i.clear)
           out_valid <= 1'b0;
         else
           out_valid <= ctrl_i.enable;
@@ -455,7 +326,7 @@
       begin
         if(~rst_ni)
           shadow_flags_rd <= '0;
-        else if(clear_i)
+        else if(clear_i | ctrl_i.clear)
           shadow_flags_rd <= '0;
         else if(ctrl_i.enable)
           shadow_flags_rd <= shadow_flags_wr;
@@ -474,7 +345,6 @@
         // flags_o.next_idx  = curr_idx;
         flags_o.valid = out_valid;
         flags_o.ready = shadow_flags_wr.ready;
-        flags_o.loop  = out_loop;
       end
 
     end // shadowed_gen

```

</details>

---

## 5. Harbor Package File Inventory & Provenance

### Public Workspace (`environment/public/`)
- [`environment/public/BUILD.md`](environment/public/BUILD.md) *(Read-Only Context)*
- [`environment/public/code/LICENSE`](environment/public/code/LICENSE) *(Read-Only Context)*
- [`environment/public/code/hwpe_ctrl_package.sv`](environment/public/code/hwpe_ctrl_package.sv) *(Read-Only Context)*
- [`environment/public/code/hwpe_ctrl_uloop.sv`](environment/public/code/hwpe_ctrl_uloop.sv) **(Editable)**
- [`environment/public/issue.md`](environment/public/issue.md) *(Read-Only Context)*

### Reference Solutions & Isolated Verifier (`solution/` & `tests/`)
- [`solution/solve.sh`](solution/solve.sh) — Harbor oracle script
- [`solution/gold/`](solution/gold/) — Primary golden reference solution
- [`solution/alternate_gold/`](solution/alternate_gold/) — Structurally distinct secondary reference solution
- [`tests/test.sh`](tests/test.sh) — Isolated Harbor verifier entrypoint
- [`tests/private/policy_filter.py`](tests/private/policy_filter.py) — Pre-grader airlock & anti-cheat policy screen
- [`tests/private/grader/run.py`](tests/private/grader/run.py) — Deterministic front-to-back EDA verifier

### Upstream Provenance (`SOURCE.md`)

