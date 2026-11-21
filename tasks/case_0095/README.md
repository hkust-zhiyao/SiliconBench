# `case_0095`: CVFPU Multi-Format Cast and Non-Computational Unit Area and Critical-Path Delay Closure

[Back to Benchmark Root (`README.md`)](../../README.md) | [Full 94-Task Catalog (`TASKS_INDEX.md`)](../../TASKS_INDEX.md) | [`task.toml`](task.toml) | [`instruction.md`](instruction.md) | [`solution/solve.sh`](solution/solve.sh) | [`tests/test.sh`](tests/test.sh) | [`tests/private/grader/run.py`](tests/private/grader/run.py)

---

## 1. Task Overview & Harbor Configuration

| Field | Value |
| :--- | :--- |
| **Task ID** | `case_0095` |
| **Source Silicon Repository** | `openhwgroup/cvfpu` (`repo_35`) |
| **Engineering Problem Type** | **High-Frequency Timing & Area Optimization** (`PT3_Timing_Area_PPA_Closure`) |
| **EDA Evaluation Stage** | **Stage 3: Static Timing (STA) & CDC/RDC Closure** (`stage3_sta_cdc`) |
| **Coupled Evaluation Gates** | Stage 1 (Functional RTL Sim) -> Stage 2 (Logic Synthesis & Gate-Level Verification) -> Stage 3 (OpenSTA Single-/Multi-Corner Setup/Hold WNS/TNS & CDC/RDC Closure) |
| **Primary Hardware Domain** | `rtl_integration` (Multi-Module Reuse, Port Contracts, Interfaces & Subsystem Integration) |
| **Multi-Domain Tags** | `arithmetic_datapath`, `parameters_widths`, `rtl_integration`, `synthesis_qor` |
| **Editable Files (`allowed_edits`)** | [`code/rtl/fpnew_cast_multi.sv`](environment/public/code/rtl/fpnew_cast_multi.sv), [`code/rtl/fpnew_noncomp.sv`](environment/public/code/rtl/fpnew_noncomp.sv) (2 files, 1286 LOC) |
| **Public Subsystem Context** | 10 RTL files (2696 LOC) |
| **Base Container Image** | `siliconbench-eda:1.0` (`allow_internet = false`, `environment_mode = "separate"`) |
| **PDK / Environment Profile** | **Nangate45 45nm Open Cell Library + Task Multi-Corner Liberty/SDC** |
| **Task-Customized Collateral?** | **Yes (Task-Bundled Collateral)** — Uses shared Nangate45 library for synthesis plus task-bundled fast/slow/scan corner timing views. |
| **Verifier Timeout & Seeds** | `1200s` total (`600s`/seed) across deterministic seeds `[1, 2]` |

---

## 2. Problem Specification (`issue.md`)

# CVFPU Multi-Format Cast and Non-Computational Unit Area and Critical-Path Delay Closure

In the CVFPU multi-format conversion and non-computational subsystem (`code/rtl/fpnew_cast_multi.sv` and `code/rtl/fpnew_noncomp.sv` integrated in `code/rtl/fpnew_cast_noncomp_top.sv`), wide denormalization shifting, cascaded two's-complement rounding-negation, and redundant pipeline registers cause excessive standard-cell area and critical-path arrival delay. Reduce the mapped area and critical-path delay of `code/rtl/fpnew_cast_multi.sv` and `code/rtl/fpnew_noncomp.sv` while preserving exact IEEE-754 and RISC-V semantics across `F2F`, `F2I`, and `I2F` casts (`FP32`, `FP16`, `FP16ALT` and signed/unsigned `INT8`, `INT16`, `INT32`), `SGNJ`, `MINMAX`, `CMP`, and `CLASSIFY` operations, all rounding modes (`RNE`, `RTZ`, `RDN`, `RUP`, `RMM`), subnormal inputs and outputs, NaN-boxing checks (`is_boxed_i`), `status_o` flags (`NV, DZ, OF, UF, NX`), `extension_bit_o`, `in_valid_i`/`in_ready_o` and `out_valid_o`/`out_ready_i` handshakes under downstream stalls, synchronous `flush_i`, and asynchronous `rst_ni`.

Under `BUILD.md` (`NumPipeRegs=1, PipeConfig=fpnew_pkg::INSIDE`), `fpnew_cast_noncomp_top` must map to at most `3,525.0 um^2` in Nangate45, and OpenSTA must achieve nonnegative setup and hold slack under a `2.80 ns` clock (`clk_i`) with `0.20 ns` I/O delays and `3.0 fF` output load. Edit only `code/rtl/fpnew_cast_multi.sv` and `code/rtl/fpnew_noncomp.sv`.

---

## 3. Build & Verification Instructions (`BUILD.md`)

# Build, Simulation, Synthesis, and Timing Guide

Editable files: `code/rtl/fpnew_cast_multi.sv` and `code/rtl/fpnew_noncomp.sv`. All other files in `code/` and `lib/` are read-only.

## 1. Functional Simulation (Verilator)
```bash
verilator --binary --timing -j 1 -Wno-fatal --top-module tb \
  -Icode/include +define+COMMON_CELLS_ASSERTS_OFF \
  code/rtl/cf_math_pkg.sv code/rtl/lzc.sv code/rtl/fpnew_pkg.sv \
  code/rtl/fpnew_classifier.sv code/rtl/fpnew_rounding.sv \
  code/rtl/fpnew_cast_multi.sv code/rtl/fpnew_noncomp.sv \
  code/rtl/fpnew_cast_noncomp_top.sv tb.sv
./obj_dir/Vtb
```

## 2. Synthesis & Area (`Nangate45`, `<= 3525.0 um^2`)
```bash
yosys -Q -T -m slang -p "read_slang --top fpnew_cast_noncomp_top -Icode/include -DCOMMON_CELLS_ASSERTS_OFF -DSYNTHESIS code/rtl/cf_math_pkg.sv code/rtl/lzc.sv code/rtl/fpnew_pkg.sv code/rtl/fpnew_classifier.sv code/rtl/fpnew_rounding.sv code/rtl/fpnew_cast_multi.sv code/rtl/fpnew_noncomp.sv code/rtl/fpnew_cast_noncomp_top.sv; hierarchy -check -top fpnew_cast_noncomp_top; synth -top fpnew_cast_noncomp_top -flatten; opt; dfflibmap -liberty lib/NangateOpenCellLibrary_typical.lib; abc -liberty lib/NangateOpenCellLibrary_typical.lib; clean; read_liberty -lib lib/NangateOpenCellLibrary_typical.lib; check -assert; stat -liberty lib/NangateOpenCellLibrary_typical.lib; write_verilog -noattr mapped.v"
```

## 3. OpenSTA (`2.80 ns` Clock)
Strip ` signed ` from `mapped.v` (`sed 's/ signed / /g' mapped.v > sta.v`) and run `openroad -exit sta.tcl`:
```tcl
read_lef lib/NangateOpenCellLibrary.tech.lef
read_lef lib/NangateOpenCellLibrary.macro.mod.lef
read_liberty lib/NangateOpenCellLibrary_typical.lib
read_verilog sta.v
link_design fpnew_cast_noncomp_top
create_clock -name clk_i -period 2.80 [get_ports clk_i]
set_input_delay 0.20 -clock clk_i [all_inputs -no_clocks]
set_output_delay 0.20 -clock clk_i [all_outputs]
set_load 3.0 [all_outputs]
report_checks -path_delay max -format full_clock_expanded
report_checks -path_delay min -format full_clock_expanded
check_setup -verbose
```
Worst setup and hold slack must be `>= 0.0 ns`.

---

## 4. Reference Fix Inspection (Buggy Starter vs. Golden Solution Diff)

> Human reviewers can inspect the exact reference bug fix below, or browse full files in [`environment/public/`](environment/public/), [`solution/gold/`](solution/gold/), and [`solution/alternate_gold/`](solution/alternate_gold/).

<details open>
<summary><b>Click to expand/collapse Unified Diff (<code>environment/public/</code> vs. <code>solution/gold/</code>)</b></summary>

```diff
--- a/environment/public/code/rtl/fpnew_cast_multi.sv (Buggy Starter)
+++ b/solution/gold/code/rtl/fpnew_cast_multi.sv (Golden Reference)
@@ -329,9 +329,8 @@
 
 
   logic                   [0:NUM_MID_REGS]                    mid_pipe_input_sign_q;
-  logic signed            [0:NUM_MID_REGS][INT_EXP_WIDTH-1:0] mid_pipe_input_exp_q;
+  logic signed            [0:NUM_MID_REGS][INT_EXP_WIDTH-1:0] mid_pipe_exp_q;
   logic                   [0:NUM_MID_REGS][INT_MAN_WIDTH-1:0] mid_pipe_input_mant_q;
-  logic signed            [0:NUM_MID_REGS][INT_EXP_WIDTH-1:0] mid_pipe_dest_exp_q;
   logic                   [0:NUM_MID_REGS]                    mid_pipe_src_is_int_q;
   logic                   [0:NUM_MID_REGS]                    mid_pipe_dst_is_int_q;
   fpnew_pkg::fp_info_t    [0:NUM_MID_REGS]                    mid_pipe_info_q;
@@ -350,9 +349,8 @@
 
   // Input stage: First element of pipeline is taken from upstream logic
   assign mid_pipe_input_sign_q[0] = input_sign;
-  assign mid_pipe_input_exp_q[0]  = input_exp;
+  assign mid_pipe_exp_q[0]        = dst_is_int ? input_exp : destination_exp;
   assign mid_pipe_input_mant_q[0] = input_mant;
-  assign mid_pipe_dest_exp_q[0]   = destination_exp;
   assign mid_pipe_src_is_int_q[0] = src_is_int;
   assign mid_pipe_dst_is_int_q[0] = dst_is_int;
   assign mid_pipe_info_q[0]       = info[src_fmt_q];
@@ -383,16 +381,15 @@
     assign reg_ena = (mid_pipe_ready[i] & mid_pipe_valid_q[i]) | reg_ena_i[NUM_INP_REGS + i];
     // Generate the pipeline registers within the stages, use enable-registers
     `FFL(mid_pipe_input_sign_q[i+1], mid_pipe_input_sign_q[i], reg_ena, '0)
-    `FFL(mid_pipe_input_exp_q[i+1],  mid_pipe_input_exp_q[i],  reg_ena, '0)
+    `FFL(mid_pipe_exp_q[i+1],        mid_pipe_exp_q[i],        reg_ena, '0)
     `FFL(mid_pipe_input_mant_q[i+1], mid_pipe_input_mant_q[i], reg_ena, '0)
-    `FFL(mid_pipe_dest_exp_q[i+1],   mid_pipe_dest_exp_q[i],   reg_ena, '0)
     `FFL(mid_pipe_src_is_int_q[i+1], mid_pipe_src_is_int_q[i], reg_ena, '0)
     `FFL(mid_pipe_dst_is_int_q[i+1], mid_pipe_dst_is_int_q[i], reg_ena, '0)
     `FFL(mid_pipe_info_q[i+1],       mid_pipe_info_q[i],       reg_ena, '0)
     `FFL(mid_pipe_mant_zero_q[i+1],  mid_pipe_mant_zero_q[i],  reg_ena, '0)
     `FFL(mid_pipe_op_mod_q[i+1],     mid_pipe_op_mod_q[i],     reg_ena, '0)
     `FFL(mid_pipe_rnd_mode_q[i+1],   mid_pipe_rnd_mode_q[i],   reg_ena, fpnew_pkg::RNE)
-    `FFL(mid_pipe_src_fmt_q[i+1],    mid_pipe_src_fmt_q[i],    reg_ena, fpnew_pkg::fp_format_e'(0))
+    assign mid_pipe_src_fmt_q[i+1] = fpnew_pkg::fp_format_e'(0);
     `FFL(mid_pipe_dst_fmt_q[i+1],    mid_pipe_dst_fmt_q[i],    reg_ena, fpnew_pkg::fp_format_e'(0))
     `FFL(mid_pipe_int_fmt_q[i+1],    mid_pipe_int_fmt_q[i],    reg_ena, fpnew_pkg::int_format_e'(0))
     `FFL(mid_pipe_tag_q[i+1],        mid_pipe_tag_q[i],        reg_ena, TagType'('0))
@@ -401,9 +398,9 @@
   end
   // Output stage: assign selected pipe outputs to signals for later use
   assign input_sign_q      = mid_pipe_input_sign_q[NUM_MID_REGS];
-  assign input_exp_q       = mid_pipe_input_exp_q[NUM_MID_REGS];
+  assign input_exp_q       = mid_pipe_exp_q[NUM_MID_REGS];
   assign input_mant_q      = mid_pipe_input_mant_q[NUM_MID_REGS];
-  assign destination_exp_q = mid_pipe_dest_exp_q[NUM_MID_REGS];
+  assign destination_exp_q = mid_pipe_exp_q[NUM_MID_REGS];
   assign src_is_int_q      = mid_pipe_src_is_int_q[NUM_MID_REGS];
   assign dst_is_int_q      = mid_pipe_dst_is_int_q[NUM_MID_REGS];
   assign info_q            = mid_pipe_info_q[NUM_MID_REGS];
@@ -484,18 +481,34 @@
     end
   end
 
-  localparam NUM_FP_STICKY  = 2 * INT_MAN_WIDTH - SUPER_MAN_BITS - 1; // removed mantissa, 1. and R
-  localparam NUM_INT_STICKY = 2 * INT_MAN_WIDTH - MAX_INT_WIDTH; // removed int and R
-
-  // Mantissa adjustment shift
-  assign destination_mant = preshift_mant >> denorm_shamt;
-  // Extract final mantissa and round bit, discard the normal bit (for FP)
-  assign {final_mant, fp_round_sticky_bits[1]} =
-      destination_mant[2*INT_MAN_WIDTH-1-:SUPER_MAN_BITS+1];
-  assign {final_int, int_round_sticky_bits[1]} = destination_mant[2*INT_MAN_WIDTH-:MAX_INT_WIDTH+1];
-  // Collapse sticky bits
-  assign fp_round_sticky_bits[0]  = (| {destination_mant[NUM_FP_STICKY-1:0]});
-  assign int_round_sticky_bits[0] = (| {destination_mant[NUM_INT_STICKY-1:0]});
+  localparam NUM_FP_STICKY  = 2 * INT_MAN_WIDTH - SUPER_MAN_BITS - 1;
+  localparam NUM_INT_STICKY = 2 * INT_MAN_WIDTH - MAX_INT_WIDTH;
+
+  wire fp_of_clamp = ~dst_is_int_q & of_before_round;
+  wire fp_inf_zero = ~dst_is_int_q & ~src_is_int_q & info_q.is_inf;
+  wire [32:0] sh_in = fp_inf_zero ? 33'd0 : (fp_of_clamp ? 33'h1_ffff_ffff : {input_mant_q, 1'b0});
+
+  wire [4:0]  sh5 = denorm_shamt[4:0];
+  wire [32:0] st0 = sh5[4] ? {16'b0, sh_in[32:16]} : sh_in;
+  wire         d0  = sh5[4] & (|sh_in[15:0]);
+  wire [32:0] st1 = sh5[3] ? {8'b0,  st0[32:8]}    : st0;
+  wire         d1  = sh5[3] & (|st0[7:0]);
+  wire [32:0] st2 = sh5[2] ? {4'b0,  st1[32:4]}    : st1;
+  wire         d2  = sh5[2] & (|st1[3:0]);
+  wire [32:0] st3 = sh5[1] ? {2'b0,  st2[32:2]}    : st2;
+  wire         d3  = sh5[1] & (|st2[1:0]);
+  wire [32:0] st4 = sh5[0] ? {1'b0,  st3[32:1]}    : st3;
+  wire         d4  = sh5[0] & st3[0];
+
+  wire [32:0] sh_top = fp_of_clamp ? 33'h1_ffff_ffff : (denorm_shamt[5] ? (denorm_shamt[0] ? 33'd0 : {32'b0, sh_in[32]}) : st4);
+  wire        int_sticky = fp_of_clamp | (denorm_shamt[5] ? (denorm_shamt[0] ? (|sh_in) : (|sh_in[31:0]))
+                                                          : (d0 | d1 | d2 | d3 | d4));
+
+  assign {final_int, int_round_sticky_bits[1]} = sh_top[32:0];
+  assign int_round_sticky_bits[0]              = int_sticky;
+  assign {final_mant, fp_round_sticky_bits[1]} = sh_top[31:8];
+  assign fp_round_sticky_bits[0]               = int_sticky | (|sh_top[7:0]);
+  assign destination_mant                      = {sh_top, 32'b0};
 
   // select RS bits for destination operation
   assign round_sticky_bits = dst_is_int_q ? int_round_sticky_bits : fp_round_sticky_bits;
@@ -556,15 +569,60 @@
   end
 
   // Select output with destination format and operation
-  assign pre_round_abs = dst_is_int_q ? ifmt_pre_round_abs[int_fmt_q2] : fmt_pre_round_abs[dst_fmt_q2];
+  wire neg_int_round = dst_is_int_q & input_sign_q;
+  wire [WIDTH-1:0] raw_pre_round = dst_is_int_q ? ifmt_pre_round_abs[int_fmt_q2] : fmt_pre_round_abs[dst_fmt_q2];
+  assign pre_round_abs = neg_int_round ? ~raw_pre_round : raw_pre_round;
+
+  logic [1:0] eff_rs_bits;
+  fpnew_pkg::roundmode_e eff_rnd_mode;
+  always_comb begin
+    eff_rs_bits  = round_sticky_bits;
+    eff_rnd_mode = rnd_mode_q;
+    if (neg_int_round) begin
+      unique case (rnd_mode_q)
+        fpnew_pkg::RNE: begin
+          unique case (round_sticky_bits)
+            2'b00, 2'b01: eff_rs_bits = 2'b11;
+            2'b10:        eff_rs_bits = 2'b10;
+            2'b11:        eff_rs_bits = 2'b00;
+            default:      eff_rs_bits = 2'b00;
+          endcase
+        end
+        fpnew_pkg::RTZ: begin
+          eff_rnd_mode = fpnew_pkg::RNE;
+          eff_rs_bits  = 2'b11;
+        end
+        fpnew_pkg::RDN: begin
+          eff_rnd_mode = fpnew_pkg::RNE;
+          eff_rs_bits  = (|round_sticky_bits) ? 2'b00 : 2'b11;
+        end
+        fpnew_pkg::RUP: begin
+          eff_rnd_mode = fpnew_pkg::RNE;
+          eff_rs_bits  = 2'b11;
+        end
+        fpnew_pkg::RMM: begin
+          eff_rnd_mode = fpnew_pkg::RNE;
+          eff_rs_bits  = round_sticky_bits[1] ? 2'b00 : 2'b11;
+        end
+        fpnew_pkg::ROD: begin
+          eff_rnd_mode = fpnew_pkg::RNE;
+          eff_rs_bits  = (~raw_pre_round[0] & (|round_sticky_bits)) ? 2'b00 : 2'b11;
+        end
+        default: begin
+          eff_rnd_mode = fpnew_pkg::RNE;
+          eff_rs_bits  = 2'b11;
+        end
+      endcase
+    end
+  end
 
   fpnew_rounding #(
     .AbsWidth ( WIDTH )
   ) i_fpnew_rounding (
     .abs_value_i             ( pre_round_abs     ),
     .sign_i                  ( input_sign_q      ), // source format
-    .round_sticky_bits_i     ( round_sticky_bits ),
-    .rnd_mode_i              ( rnd_mode_q        ),
+    .round_sticky_bits_i     ( eff_rs_bits       ),
+    .rnd_mode_i              ( eff_rnd_mode      ),
     .effective_subtraction_i ( 1'b0              ), // no operation happened
     .abs_rounded_o           ( rounded_abs       ),
     .sign_o                  ( rounded_sign      ),
@@ -583,9 +641,9 @@
     if (FpFmtConfig[fmt]) begin : active_format
       always_comb begin : post_process
         // detect of / uf
-        fmt_uf_after_round[fmt] = (rounded_abs[EXP_BITS+MAN_BITS-1:MAN_BITS] == '0) // denormal
-            || ((pre_round_abs[EXP_BITS+MAN_BITS-1:MAN_BITS] == '0) && (rounded_abs[EXP_BITS+MAN_BITS-1:MAN_BITS] == 1) &&
-               ((round_sticky_bits != 2'b11) || (!destination_mant[NUM_FP_STICKY-1] && ((rnd_mode_q == fpnew_pkg::RNE) || (rnd_mode_q == fpnew_pkg::RMM)))));
+        fmt_uf_after_round[fmt] = uf_before_round & (~rounded_abs[MAN_BITS]
+            || (round_sticky_bits != 2'b11)
+            || (!destination_mant[NUM_FP_STICKY-1] && ((rnd_mode_q == fpnew_pkg::RNE) || (rnd_mode_q == fpnew_pkg::RMM))));
         fmt_of_after_round[fmt] = rounded_abs[EXP_BITS+MAN_BITS-1:MAN_BITS] == '1; // inf exp.
 
         // Assemble regular result, nan box short ones. Int zeroes need to be detected`
@@ -602,7 +660,7 @@
   end
 
   // Negative integer result needs to be brought into two's complement
-  assign rounded_uint_res      = rounded_sign ? unsigned'(-rounded_abs) : rounded_abs;
+  assign rounded_uint_res      = {input_sign_q ? ~rounded_int_res_zero : raw_pre_round[31], rounded_abs[30:0]};
 
     // Sign-extend integer result
   for (genvar ifmt = 0; ifmt < int'(NUM_INT_FORMATS); ifmt++) begin : gen_int_res_sign_ext
@@ -621,7 +679,7 @@
   end
   
   assign rounded_int_res = ifmt_rounded_signed_res[int_fmt_q2];
-  assign rounded_int_res_zero = (rounded_int_res == '0) && (pre_round_abs == '0);
+  assign rounded_int_res_zero = (raw_pre_round == '0) & (neg_int_round ? (eff_rs_bits != 2'b00) : 1'b1);
 
   // Detect integer overflows after rounding (only positives)
   for (genvar ifmt = 0; ifmt < int'(NUM_INT_FORMATS); ifmt++) begin : gen_int_overflow
@@ -632,17 +690,17 @@
       always_comb begin : detect_overflow
         ifmt_of_after_round[ifmt] = 1'b0;
         // Int result can overflow if we're at the max exponent
-        if (!rounded_sign && input_exp_q == signed'(INT_WIDTH - 2 + op_mod_q2)) begin
-          // Check whether the rounded MSB differs from unrounded MSB
-          ifmt_of_after_round[ifmt] = ~rounded_int_res[INT_WIDTH-2+op_mod_q2];
-        end
-        // Negative overflow: value at exp=INT_WIDTH-1 rounded more negative than INT_MIN
-        // This can happen with RDN/RNE when fractional bits cause rounding away from zero.
-        // Detect by checking if the negated magnitude overflowed INT_MIN's bit position.
-        if (!op_mod_q2 && rounded_sign && input_exp_q == signed'(INT_WIDTH - 1)) begin
+        if (INT_WIDTH == 32) begin
+          if (!op_mod_q2 && rounded_sign && input_exp_q == signed'(INT_WIDTH - 1)) begin
+            ifmt_of_after_round[ifmt] = |input_mant_q[30:8];
+          end
+        end else begin
+          if (!rounded_sign && input_exp_q == signed'(INT_WIDTH - 2 + op_mod_q2)) begin
+            ifmt_of_after_round[ifmt] = ~rounded_int_res[INT_WIDTH-2+op_mod_q2];
+          end
+          if (!op_mod_q2 && rounded_sign && input_exp_q == signed'(INT_WIDTH - 1)) begin
             ifmt_of_after_round[ifmt] = ~rounded_uint_res[INT_WIDTH-1];
-            // If bit INT_WIDTH-1 is set in the two's complement negative result, it means
-            // -(magnitude) underflowed past INT_MIN = -2^(INT_WIDTH-1)
+          end
         end
       end
     end else begin : inactive_format
@@ -737,7 +795,7 @@
 
   // Detect special case from source format (inf, nan, overflow, nan-boxing or negative unsigned)
   assign int_result_is_special = info_q.is_nan | info_q.is_inf |
-                                 of_before_round | of_after_round | ~info_q.is_boxed |
+                                 of_before_round | ifmt_of_after_round[int_fmt_q2] | ~info_q.is_boxed |
                                  (input_sign_q & op_mod_q2 & ~rounded_int_res_zero);
 
   // All integer special cases are invalid
@@ -756,10 +814,10 @@
 
   assign fp_regular_status.NV = 1'b0; // floating-point results are always valid
   assign fp_regular_status.DZ = 1'b0; // no divisions
-  assign fp_regular_status.OF = (src_is_int_q | ~info_q.is_inf) & (of_before_round | of_after_round); // inf casts no OF
+  assign fp_regular_status.OF = (src_is_int_q | ~info_q.is_inf) & (of_before_round | fmt_of_after_round[dst_fmt_q2]);
   assign fp_regular_status.UF = uf_after_round & fp_regular_status.NX;
-  assign fp_regular_status.NX = (| fp_round_sticky_bits) | ((src_is_int_q | ~info_q.is_inf) & (of_before_round | of_after_round));
-  assign int_regular_status = '{NV: of_before_round | of_after_round, // overflow is invalid for F2I casts
+  assign fp_regular_status.NX = (| fp_round_sticky_bits) | ((src_is_int_q | ~info_q.is_inf) & of_before_round);
+  assign int_regular_status = '{NV: of_before_round | ifmt_of_after_round[int_fmt_q2],
                                 NX: (| int_round_sticky_bits), default: 1'b0};
 
   assign fp_result  = fp_result_is_special  ? fp_special_result  : fmt_result[dst_fmt_q2];

--- a/environment/public/code/rtl/fpnew_noncomp.sv (Buggy Starter)
+++ b/solution/gold/code/rtl/fpnew_noncomp.sv (Golden Reference)
@@ -172,10 +172,9 @@
 
   logic operands_equal, operand_a_smaller;
 
-  // Equality checks for zeroes too
-  assign operands_equal    = (operand_a == operand_b) || (info_a.is_zero && info_b.is_zero);
-  // Invert result if non-zero signs involved (unsigned comparison)
-  assign operand_a_smaller = (operand_a < operand_b) ^ (operand_a.sign || operand_b.sign);
+  wire [WIDTH:0] cmp_diff  = {1'b0, operand_a} - {1'b0, operand_b};
+  assign operands_equal    = (cmp_diff[WIDTH-1:0] == '0) || (info_a.is_zero && info_b.is_zero);
+  assign operand_a_smaller = cmp_diff[WIDTH] ^ (operand_a.sign || operand_b.sign);
 
   // ---------------
   // Sign Injection

```

</details>

---

## 5. Harbor Package File Inventory & Provenance

### Public Workspace (`environment/public/`)
- [`environment/public/BUILD.md`](environment/public/BUILD.md) *(Read-Only Context)*
- [`environment/public/code/LICENSE.apache`](environment/public/code/LICENSE.apache) *(Read-Only Context)*
- [`environment/public/code/LICENSE.solderpad`](environment/public/code/LICENSE.solderpad) *(Read-Only Context)*
- [`environment/public/code/README.md`](environment/public/code/README.md) *(Read-Only Context)*
- [`environment/public/code/include/common_cells/assertions.svh`](environment/public/code/include/common_cells/assertions.svh) *(Read-Only Context)*
- [`environment/public/code/include/common_cells/registers.svh`](environment/public/code/include/common_cells/registers.svh) *(Read-Only Context)*
- [`environment/public/code/rtl/cf_math_pkg.sv`](environment/public/code/rtl/cf_math_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/rtl/fpnew_cast_multi.sv`](environment/public/code/rtl/fpnew_cast_multi.sv) **(Editable)**
- [`environment/public/code/rtl/fpnew_cast_noncomp_top.sv`](environment/public/code/rtl/fpnew_cast_noncomp_top.sv) *(Read-Only Context)*
- [`environment/public/code/rtl/fpnew_classifier.sv`](environment/public/code/rtl/fpnew_classifier.sv) *(Read-Only Context)*
- [`environment/public/code/rtl/fpnew_noncomp.sv`](environment/public/code/rtl/fpnew_noncomp.sv) **(Editable)**
- [`environment/public/code/rtl/fpnew_pkg.sv`](environment/public/code/rtl/fpnew_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/rtl/fpnew_rounding.sv`](environment/public/code/rtl/fpnew_rounding.sv) *(Read-Only Context)*
- [`environment/public/code/rtl/lzc.sv`](environment/public/code/rtl/lzc.sv) *(Read-Only Context)*
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

