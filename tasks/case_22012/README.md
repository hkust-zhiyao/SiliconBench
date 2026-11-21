# `case_22012`: Fix RVV 1.0 Fixed-Point Rounding, Averaging/Clipping Arithmetic, Saturation Queuing, and Gate-Level X-Parity in Ara Vector ALU

[Back to Benchmark Root (`README.md`)](../../README.md) | [Full 94-Task Catalog (`TASKS_INDEX.md`)](../../TASKS_INDEX.md) | [`task.toml`](task.toml) | [`instruction.md`](instruction.md) | [`solution/solve.sh`](solution/solve.sh) | [`tests/test.sh`](tests/test.sh) | [`tests/private/grader/run.py`](tests/private/grader/run.py)

---

## 1. Task Overview & Harbor Configuration

| Field | Value |
| :--- | :--- |
| **Task ID** | `case_22012` |
| **Source Silicon Repository** | `pulp-platform/ara` (`repo_19`) |
| **Engineering Problem Type** | **New ISA & Subsystem Feature Implementation** (`PT2_New_Feature_ISA_Impl`) |
| **EDA Evaluation Stage** | **Stage 3: Static Timing (STA) & CDC/RDC Closure** (`stage3_sta_cdc`) |
| **Coupled Evaluation Gates** | Stage 1 (Functional RTL Sim) -> Stage 2 (Logic Synthesis & Gate-Level Verification) -> Stage 3 (OpenSTA Single-/Multi-Corner Setup/Hold WNS/TNS & CDC/RDC Closure) |
| **Primary Hardware Domain** | `Vector_GPU_NPU_Accelerators` (Vector_GPU_NPU_Accelerators) |
| **Multi-Domain Tags** | `Vector_GPU_NPU_Accelerators` |
| **Editable Files (`allowed_edits`)** | [`code/fixed_p_rounding.sv`](environment/public/code/fixed_p_rounding.sv), [`code/simd_alu.sv`](environment/public/code/simd_alu.sv), [`code/valu.sv`](environment/public/code/valu.sv) (3 files, 1600 LOC) |
| **Public Subsystem Context** | 16 RTL files (8114 LOC) |
| **Base Container Image** | `siliconbench-eda:1.0` (`allow_internet = false`, `environment_mode = "separate"`) |
| **PDK / Environment Profile** | **Standard IEEE 1800-2017 SystemVerilog Dual-Simulator + Yosys Slang** |
| **Task-Customized Collateral?** | **No (Uses Shared Base Image)** — Pure RTL/protocol/synthesis check without external PDK Liberty files. |
| **Verifier Timeout & Seeds** | `720s` total (`360s`/seed) across deterministic seeds `[101, 202]` |

---

## 2. Problem Specification (`issue.md`)

# Ara Lane Vector ALU: RVV 1.0 Fixed-Point Arithmetic, Saturation Reporting, and Gate-Level Parity

## Context
`valu` (`code/valu.sv`), `simd_alu` (`code/simd_alu.sv`), and `fixed_p_rounding` (`code/fixed_p_rounding.sv`) implement the per-lane 64-bit integer and fixed-point execution pipeline in PULP Ara (`NrLanes = 4`, `VLEN = 4096`). Regression testing across RVV 1.0 fixed-point workloads and 4-state post-synthesis gate-level netlist simulation exposed arithmetic mismatches, corrupted or dropped `vxsat` reports under pipelining/backpressure, and `X`-propagation on boundary shift amounts.

## Architectural Requirements

1. **RVV 1.0 Fixed-Point Operations & Rounding Modes (`EW8`, `EW16`, `EW32`, `EW64`)**:
   - Support single-width saturating add/subtract (`VSADDU`, `VSADD`, `VSSUBU`, `VSSUB`), single-width averaging add/subtract (`VAADDU`, `VAADD`, `VASUBU`, `VASUB`), single-width scaling shifts (`VSSRL`, `VSSRA`), and 2-cycle narrowing fixed-point clips (`VNCLIPU`, `VNCLIP`, for destination `vsew` in `{EW8, EW16, EW32}` narrowing `2*SEW` operands in `alu_operand_i[1]` / `alu_operand_i[0]` or `scalar_op`) across both vector-vector and scalar-vector (`use_scalar_op`) forms.
   - Follow Ara's operand convention (`operand_a` = `vs1`/`rs1`/`imm`, `operand_b` = `vs2`) and intra-lane shuffled subword byte layout (`ara_pkg::shuffle_index` / `be`).
   - Implement exact RVV 1.0 §12.1 fixed-point rounding (`vxrm_i`: `2'b00` `rnu`, `2'b01` `rne`, `2'b10` `rdn`, `2'b11` `rod`), including zero shift amounts (`shamt == 0` -> rounding increment `0`) and masking shift amounts to `lg2(SEW)` bits for single-width shifts or `lg2(2*SEW)` bits for narrowing clips.
   - Compute `VAADDU`/`VAADD` and `VASUBU`/`VASUB` from the full `(SEW+1)`-bit unsigned or signed sum/difference before shifting right by 1, rounding per `vxrm_i`, and wrapping to `SEW` bits without asserting saturation.
   - For `VNCLIPU` and `VNCLIP`, round the shifted `2*SEW` value per `vxrm_i` and clamp to `[0, 2^SEW - 1]` or `[-2^(SEW-1), 2^(SEW-1) - 1]` (including post-rounding boundary overflow), flagging saturation on the corresponding narrowed subword bytes.

2. **Byte-Exact `vxsat_flag_o` Tracking Under Pipelining, Narrowing, and Backpressure**:
   - In Ara, the dispatcher accumulates sticky `vxsat` via `csr_vxsat_d |= |vxsat_flag_i`. `vxsat_flag_o` must assert only for saturation occurring on **active** destination bytes (unmasked and `< vl`, matching `alu_result_be_o`) of fixed-point saturating instructions (`VSADDU`, `VSADD`, `VSSUBU`, `VSSUB`, `VNCLIPU`, `VNCLIP`).
   - Masked-off elements (`vm == 0` with `mask_i` clear), tail elements (`>= vl`), non-saturating instructions, and stalled/pipelined back-to-back micro-operations or 2-cycle narrowing halves must never drop a real active saturation event nor falsely assert `vxsat_flag_o` due to adjacent instructions in flight.
   - Existing non-fixed-point integer ALU, comparison/mask, merge, narrowing shift (`VNSRL`, `VNSRA`), and intra-/inter-lane reduction behaviors must remain intact.

3. **`FixPtSupport` Parameterization & 4-State Gate-Level Synthesis Parity**:
   - `valu` and `simd_alu` must elaborate and synthesize cleanly under `yosys -m slang` (latch-free) for both `FixPtSupport = FixedPointEnable` and `FixPtSupport = FixedPointDisable` (with fixed-point datapath disabled and `vxsat_flag_o` tied `1'b0` when `FixedPointDisable`).
   - The synthesized `FixedPointEnable` gate-level netlist must match RTL cycle-for-cycle in 4-state simulation with zero `X`/`Z` propagation on valid outputs (`alu_ready_o`, `alu_operand_ready_o`, `mask_ready_o`, `alu_result_req_o`, `alu_vinsn_done_o`, `vxsat_flag_o`, and active `alu_result_wdata_o` bytes).

---

## 3. Build & Verification Instructions (`BUILD.md`)

# Build and Verification Environment

## Editable RTL Files
Only the following files may be modified:
- `code/fixed_p_rounding.sv`
- `code/simd_alu.sv`
- `code/valu.sv`

All package definitions and support modules under `code/` (`ara_pkg.sv`, `rvv_pkg.sv`, `cf_math_pkg.sv`, `spill_register.sv`, `include/common_cells/*`) are read-only context.

## Toolchain Commands

### 1. Functional RTL Simulation (Verilator)
```bash
verilator \
  --binary -j 4 -Wno-fatal --timing -sv \
  +incdir+code/include \
  code/cf_math_pkg.sv code/riscv_pkg.sv code/config_pkg.sv \
  code/cv64a6_imafdcv_sv39_config_pkg.sv code/ariane_pkg.sv code/axi_pkg.sv \
  code/fpnew_pkg.sv code/rvv_pkg.sv code/ara_pkg.sv \
  code/spill_register_flushable.sv code/spill_register.sv \
  code/fixed_p_rounding.sv code/simd_alu.sv code/valu.sv \
  <your_tb.sv> --top-module <top>
```

### 2. Synthesis Elaboration & Gate-Level Netlist Generation (`yosys -m slang`)
```bash
yosys -m slang -p "
  read_slang --top <syn_wrapper> -I code/include \
    code/cf_math_pkg.sv code/riscv_pkg.sv code/config_pkg.sv \
    code/cv64a6_imafdcv_sv39_config_pkg.sv code/ariane_pkg.sv code/axi_pkg.sv \
    code/fpnew_pkg.sv code/rvv_pkg.sv code/ara_pkg.sv \
    code/spill_register_flushable.sv code/spill_register.sv \
    code/fixed_p_rounding.sv code/simd_alu.sv code/valu.sv <syn_wrapper.sv>;
  synth -top <syn_wrapper>;
  write_verilog -noattr netlist.v
"
```

### 3. 4-State Gate-Level Simulation (`iverilog -g2012`)
```bash
iverilog -g2012 \
  -o sim_gl.out \
  /opt/siliconbench/tools/oss-cad-suite/share/yosys/simcells.v \
  netlist.v <gl_tb.sv>
vvp sim_gl.out
```

---

## 4. Reference Fix Inspection (Buggy Starter vs. Golden Solution Diff)

> Human reviewers can inspect the exact reference bug fix below, or browse full files in [`environment/public/`](environment/public/), [`solution/gold/`](solution/gold/), and [`solution/alternate_gold/`](solution/alternate_gold/).

<details open>
<summary><b>Click to expand/collapse Unified Diff (<code>environment/public/</code> vs. <code>solution/gold/</code>)</b></summary>

```diff
--- a/environment/public/code/fixed_p_rounding.sv (Buggy Starter)
+++ b/solution/gold/code/fixed_p_rounding.sv (Golden Reference)
@@ -1,13 +1,8 @@
 // Copyright 2021 ETH Zurich and University of Bologna.
 // Solderpad Hardware License, Version 0.51, see LICENSE for details.
 // SPDX-License-Identifier: SHL-0.51
-//
-// Author: Muhammad Ijaz
-// Description:
-// Ara's fixed point rounding module, operating on elements 64-bit wide, and generating rounding r for each stream of elements.
 
 module fixed_p_rounding import ara_pkg::*; import rvv_pkg::*; #(
-    // Dependant parameters. DO NOT CHANGE!
     localparam int  unsigned DataWidth = $bits(elen_t),
     localparam int  unsigned StrbWidth = DataWidth/8,
     localparam type          strb_t    = logic [StrbWidth-1:0]
@@ -21,163 +16,129 @@
     output strb_t   r_o
   );
 
-  /////////////////
-  // Definitions //
-  /////////////////
-
   typedef union packed {
     logic [0:0][63:0] w64;
     logic [1:0][31:0] w32;
     logic [3:0][15:0] w16;
     logic [7:0][ 7:0] w8;
-  } rounding_args;
+  } rounding_args_t;
 
-  rounding_args opa, opb;
+  rounding_args_t opa, opb;
   assign opa = operand_a_i;
   assign opb = operand_b_i;
 
-  vxrm_t vxrm;
-  assign vxrm = vxrm_i;
+  function automatic logic round_bit_w8(input logic [7:0] v, input logic [2:0] d, input vxrm_t mode);
+    logic [2:0] dm1;
+    logic       v_d, v_dm1, sticky_low;
+    if (d == 3'd0) begin
+      return 1'b0;
+    end else begin
+      dm1        = d - 3'd1;
+      v_d        = v[d];
+      v_dm1      = v[dm1];
+      sticky_low = 1'b0;
+      for (int k = 0; k < 8; k++) begin
+        if (k < int'(dm1)) sticky_low |= v[k];
+      end
+      unique case (mode)
+        2'b00:   return v_dm1;
+        2'b01:   return v_dm1 & (sticky_low | v_d);
+        2'b10:   return 1'b0;
+        default: return (~v_d) & (v_dm1 | sticky_low);
+      endcase
+    end
+  endfunction
 
-  elen_t [DataWidth-1:0] bit_select;
-  int j;
+  function automatic logic round_bit_w16(input logic [15:0] v, input logic [3:0] d, input vxrm_t mode);
+    logic [3:0] dm1;
+    logic       v_d, v_dm1, sticky_low;
+    if (d == 4'd0) begin
+      return 1'b0;
+    end else begin
+      dm1        = d - 4'd1;
+      v_d        = v[d];
+      v_dm1      = v[dm1];
+      sticky_low = 1'b0;
+      for (int k = 0; k < 16; k++) begin
+        if (k < int'(dm1)) sticky_low |= v[k];
+      end
+      unique case (mode)
+        2'b00:   return v_dm1;
+        2'b01:   return v_dm1 & (sticky_low | v_d);
+        2'b10:   return 1'b0;
+        default: return (~v_d) & (v_dm1 | sticky_low);
+      endcase
+    end
+  endfunction
+
+  function automatic logic round_bit_w32(input logic [31:0] v, input logic [4:0] d, input vxrm_t mode);
+    logic [4:0] dm1;
+    logic       v_d, v_dm1, sticky_low;
+    if (d == 5'd0) begin
+      return 1'b0;
+    end else begin
+      dm1        = d - 5'd1;
+      v_d        = v[d];
+      v_dm1      = v[dm1];
+      sticky_low = 1'b0;
+      for (int k = 0; k < 32; k++) begin
+        if (k < int'(dm1)) sticky_low |= v[k];
+      end
+      unique case (mode)
+        2'b00:   return v_dm1;
+        2'b01:   return v_dm1 & (sticky_low | v_d);
+        2'b10:   return 1'b0;
+        default: return (~v_d) & (v_dm1 | sticky_low);
+      endcase
+    end
+  endfunction
+
+  function automatic logic round_bit_w64(input logic [63:0] v, input logic [5:0] d, input vxrm_t mode);
+    logic [5:0] dm1;
+    logic       v_d, v_dm1, sticky_low;
+    if (d == 6'd0) begin
+      return 1'b0;
+    end else begin
+      dm1        = d - 6'd1;
+      v_d        = v[d];
+      v_dm1      = v[dm1];
+      sticky_low = 1'b0;
+      for (int k = 0; k < 64; k++) begin
+        if (k < int'(dm1)) sticky_low |= v[k];
+      end
+      unique case (mode)
+        2'b00:   return v_dm1;
+        2'b01:   return v_dm1 & (sticky_low | v_d);
+        2'b10:   return 1'b0;
+        default: return (~v_d) & (v_dm1 | sticky_low);
+      endcase
+    end
+  endfunction
 
   always_comb begin
-    j   =  0;
     r_o = '0;
-
     if (valid_i) begin
       unique case (op_i)
-        VSSRA, VSSRL, VNCLIP, VNCLIPU : begin
+        VSSRA, VSSRL: begin
           unique case (vew_i)
-            EW8 : begin
-              unique case (vxrm)
-                2'b00: begin
-                  for (int i=0; i<8; i++) begin
-                    j      = opa.w8[i];
-                    r_o[i] = opb.w8[i][j-1];
-                  end
-                end
-                2'b01: begin
-                  for (int i=0; i<8; i++) begin
-                    j      = opa.w8[i];
-                    r_o[i] = opb.w8[i][j-1] & opb.w8[i][j];
-                  end
-                end
-                2'b10: begin
-                  r_o = '0;
-                end
-                2'b11: begin
-                  for (int i=0; i<8; i++) begin
-                    j      = opa.w8[i];
-                    r_o[i] = !opb.w8[i][j] & |(opb.w8[i] & bit_select);
-                  end
-                end
-              endcase
-            end
-            EW16: begin
-              unique case (vxrm)
-                2'b00: begin
-                  for (int i=0; i<4; i++) begin
-                    j      = opa.w16[i];
-                    r_o[i] = opb.w16[i][j-1];
-                  end
-                end
-                2'b01: begin
-                  for (int i=0; i<4; i++) begin
-                    j      = opa.w16[i];
-                    r_o[i] = opb.w16[i][j-1] & opb.w16[i][j];
-                  end
-                end
-                2'b10: begin
-                  r_o = '0;
-                end
-                2'b11: begin
-                  for (int i=0; i<4; i++) begin
-                    j      = opa.w16[i];
-                    r_o[i] = !opb.w16[i][j] & |(opb.w16[i] & bit_select);
-                  end
-                end
-              endcase
-            end
-            EW32: begin
-              unique case (vxrm)
-                2'b00: begin
-                  for (int i=0; i<2; i++) begin
-                    j      = opa.w32[i];
-                    r_o[i] = opb.w32[i][j-1];
-                  end
-                end
-                2'b01: begin
-                  for (int i=0; i<2; i++) begin
-                    j      = opa.w32[i];
-                    r_o[i] = opb.w32[i][j-1] & opb.w32[i][j];
-                  end
-                end
-                2'b10: begin
-                  r_o = '0;
-                end
-                2'b11: begin
-                  for (int i=0; i<2; i++) begin
-                    j      = opa.w32[i];
-                    r_o[i] = !opb.w32[i][j] & |(opb.w32[i] & bit_select);
-                  end
-                end
-              endcase
-            end
-            EW64: begin
-              unique case (vxrm)
-                2'b00: begin
-                  for (int i=0; i<1; i++) begin
-                    j      = opa.w64[i];
-                    r_o[i] = opb.w64[i][j-1];
-                  end
-                end
-                2'b01: begin
-                  for (int i=0; i<1; i++) begin
-                    j      = opa.w64[i];
-                    r_o[i] = opb.w64[i][j-1] & opb.w64[i][j];
-                  end
-                end
-                2'b10: begin
-                  r_o = '0;
-                end
-                2'b11: begin
-                  for (int i=0; i<1; i++) begin
-                    j      = opa.w64[i];
-                    r_o[i] = !opb.w64[i][j] & |(opb.w64[i] & bit_select);
-                  end
-                end
-              endcase
-            end
+            EW8:  for (int i = 0; i < 8; i++) r_o[i] = round_bit_w8 (opb.w8 [i], opa.w8 [i][2:0], vxrm_i);
+            EW16: for (int i = 0; i < 4; i++) r_o[i] = round_bit_w16(opb.w16[i], opa.w16[i][3:0], vxrm_i);
+            EW32: for (int i = 0; i < 2; i++) r_o[i] = round_bit_w32(opb.w32[i], opa.w32[i][4:0], vxrm_i);
+            EW64: for (int i = 0; i < 1; i++) r_o[i] = round_bit_w64(opb.w64[i], opa.w64[i][5:0], vxrm_i);
+            default:;
+          endcase
+        end
+        VNCLIP, VNCLIPU: begin
+          unique case (vew_i)
+            EW8:  for (int i = 0; i < 4; i++) r_o[i] = round_bit_w16(opb.w16[i], opa.w16[i][3:0], vxrm_i);
+            EW16: for (int i = 0; i < 2; i++) r_o[i] = round_bit_w32(opb.w32[i], opa.w32[i][4:0], vxrm_i);
+            EW32: for (int i = 0; i < 1; i++) r_o[i] = round_bit_w64(opb.w64[i], opa.w64[i][5:0], vxrm_i);
+            default:;
           endcase
         end
         default: r_o = '0;
       endcase
-    end else begin
-      r_o = '0;
     end
   end
 
-  //////////////////
-  // Lookup Table //
-  //////////////////
-
-  assign bit_select = {64'h0000000000000000, 64'h0000000000000001, 64'h0000000000000003, 64'h0000000000000007,
-                       64'h000000000000000F, 64'h000000000000001F, 64'h000000000000003F, 64'h000000000000007F,
-                       64'h00000000000000FF, 64'h00000000000001FF, 64'h00000000000003FF, 64'h00000000000007FF,
-                       64'h0000000000000FFF, 64'h0000000000001FFF, 64'h0000000000003FFF, 64'h0000000000007FFF,
-                       64'h000000000000FFFF, 64'h000000000001FFFF, 64'h000000000003FFFF, 64'h000000000007FFFF,
-                       64'h00000000000FFFFF, 64'h00000000001FFFFF, 64'h00000000003FFFFF, 64'h00000000007FFFFF,
-                       64'h0000000000FFFFFF, 64'h0000000001FFFFFF, 64'h0000000003FFFFFF, 64'h0000000007FFFFFF,
-                       64'h000000000FFFFFFF, 64'h000000001FFFFFFF, 64'h000000003FFFFFFF, 64'h000000007FFFFFFF,
-                       64'h00000000FFFFFFFF, 64'h00000001FFFFFFFF, 64'h00000003FFFFFFFF, 64'h00000007FFFFFFFF,
-                       64'h0000000FFFFFFFFF, 64'h0000001FFFFFFFFF, 64'h0000003FFFFFFFFF, 64'h0000007FFFFFFFFF,
-                       64'h000000FFFFFFFFFF, 64'h000001FFFFFFFFFF, 64'h000003FFFFFFFFFF, 64'h000007FFFFFFFFFF,
-                       64'h00000FFFFFFFFFFF, 64'h00001FFFFFFFFFFF, 64'h00003FFFFFFFFFFF, 64'h00007FFFFFFFFFFF,
-                       64'h0000FFFFFFFFFFFF, 64'h0001FFFFFFFFFFFF, 64'h0003FFFFFFFFFFFF, 64'h0007FFFFFFFFFFFF,
-                       64'h000FFFFFFFFFFFFF, 64'h001FFFFFFFFFFFFF, 64'h003FFFFFFFFFFFFF, 64'h007FFFFFFFFFFFFF,
-                       64'h00FFFFFFFFFFFFFF, 64'h01FFFFFFFFFFFFFF, 64'h03FFFFFFFFFFFFFF, 64'h07FFFFFFFFFFFFFF,
-                       64'h0FFFFFFFFFFFFFFF, 64'h1FFFFFFFFFFFFFFF, 64'h3FFFFFFFFFFFFFFF, 64'h7FFFFFFFFFFFFFFF};
-
 endmodule : fixed_p_rounding

--- a/environment/public/code/simd_alu.sv (Buggy Starter)
+++ b/solution/gold/code/simd_alu.sv (Golden Reference)
@@ -1,15 +1,9 @@
 // Copyright 2021 ETH Zurich and University of Bologna.
 // Solderpad Hardware License, Version 0.51, see LICENSE for details.
 // SPDX-License-Identifier: SHL-0.51
-//
-// Author: Matheus Cavalcante <matheusd@iis.ee.ethz.ch>
-// Description:
-// Ara's SIMD ALU, operating on elements 64-bit wide, and generating 64 bits per cycle.
 
 module simd_alu import ara_pkg::*; import rvv_pkg::*; #(
-    // Support for fixed-point data types
     parameter  fixpt_support_e FixPtSupport = FixedPointEnable,
-    // Dependant parameters. DO NOT CHANGE!
     localparam int    unsigned DataWidth    = $bits(elen_t),
     localparam int    unsigned StrbWidth    = DataWidth/8,
     localparam type            strb_t       = logic [StrbWidth-1:0]
@@ -28,10 +22,6 @@
     output elen_t      result_o
   );
 
-  ///////////////////
-  //  Definitions  //
-  ///////////////////
-
   typedef union packed {
     logic [0:0][63:0] w64;
     logic [1:0][31:0] w32;
@@ -44,38 +34,27 @@
   assign opb      = operand_b_i;
   assign result_o = res;
 
-
-  typedef union packed {
-    logic [0:0][71:0] w64;
-    logic [1:0][35:0] w32;
-    logic [3:0][17:0] w16;
-    logic [7:0][ 8:0] w8;
-  } alu_sat_operand_t;
-
-  alu_sat_operand_t sat_sum, sat_sub;
-  vxsat_t     vxsat;
-  vxrm_t      vxrm;
-  logic       r;
-
-  assign vxrm = vxrm_i;
+  vxsat_t vxsat;
+  vxrm_t  vxrm;
+  assign vxrm    = vxrm_i;
   assign vxsat_o = vxsat;
-  ///////////////////
-  //  Comparisons  //
-  ///////////////////
-
-  // Comparison instructions that use signed operands
+
+  function automatic logic round_1b(input logic [1:0] low2, input vxrm_t mode);
+    unique case (mode)
+      2'b00:   return low2[0];
+      2'b01:   return &low2;
+      2'b10:   return 1'b0;
+      default: return (~low2[1]) & low2[0];
+    endcase
+  endfunction
+
   logic is_signed;
   assign is_signed = op_i inside {VMAX, VREDMAX, VMIN, VREDMIN, VMSLT, VMSLE, VMSGT};
-  // Compare operands.
-  // For vew_i = EW8, all bits are valid.
-  // For vew_i = EW16, bits 0, 2, 4, and 6 are valid.
-  // For vew_i = EW32, bits 0 and 4 are valid.
-  // For vew_i = EW64, only bit 0 indicates the result of the comparison.
+
   logic [7:0] less;
   logic [7:0] equal;
 
   always_comb begin: p_comparison
-    // Default assignment
     less  = '0;
     equal = '0;
 
@@ -106,23 +85,16 @@
     end
   end : p_comparison
 
-  ///////////
-  //  ALU  //
-  ///////////
-
   always_comb begin: p_alu
-    // Default assignment
     res       = '0;
     vxsat.w64 = '0;
 
     if (valid_i)
       unique case (op_i)
-        // Logical operations
         VAND, VREDAND: res = operand_a_i & operand_b_i;
         VOR, VREDOR  : res = operand_a_i | operand_b_i;
         VXOR, VREDXOR: res = operand_a_i ^ operand_b_i;
 
-        // Mask logical operations
         VMAND   : res = operand_a_i & operand_b_i;
         VMANDNOT: res = ~operand_a_i & operand_b_i;
         VMNAND  : res = ~(operand_a_i & operand_b_i);
@@ -132,102 +104,87 @@
         VMXOR   : res = operand_a_i ^ operand_b_i;
         VMXNOR  : res = ~(operand_a_i ^ operand_b_i);
 
-        // Mask operands pass-through
         VCPOP, VFIRST, VMSBF, VMSOF, VMSIF, VIOTA: res = operand_b_i;
-
-        // Mask operands pass-through
         VRGATHER, VRGATHEREI16, VCOMPRESS: res = operand_a_i;
 
-        // Arithmetic instructions
         VSADDU: if (FixPtSupport == FixedPointEnable) unique case (vew_i)
             EW8: for (int b = 0; b < 8; b++) begin
-                automatic logic [8:0] sum = opa.w8[b] + opb.w8[b];
-                vxsat.w8[b]   = sum[8];
-                res.w8[b]     = vxsat.w8[b] ? {8{1'b1}} : sum[7:0];
-              end
-            EW16: for (int b = 0; b < 4; b++) begin
-                automatic logic [16:0] sum = opa.w16[b] + opb.w16[b];
-                vxsat.w16[b]   = {2{sum[16]}};
-                res.w16[b]     = &vxsat.w16[b] ? {16{1'b1}} : sum[15:0];
-              end
-            EW32: for (int b = 0; b < 2; b++) begin
-                automatic logic [32:0] sum = opa.w32[b] + opb.w32[b];
-                vxsat.w32[b]   = {4{sum[32]}};
-                res.w32[b]     = &vxsat.w32[b] ? {32{1'b1}} : sum[31:0];
-              end
-            EW64: for (int b = 0; b < 1; b++) begin
-                automatic logic [64:0] sum = opa.w64[b] + opb.w64[b];
-                vxsat.w64[b]   = {8{sum[64]}};
-                res.w64[b]     = &vxsat.w64[b] ? {64{1'b1}} : sum[63:0];
-              end
-          endcase
+                automatic logic [8:0] sum = {1'b0, opa.w8[b]} + {1'b0, opb.w8[b]};
+                vxsat.w8[b] = sum[8];
+                res.w8[b]   = sum[8] ? 8'hFF : sum[7:0];
+              end
+            EW16: for (int b = 0; b < 4; b++) begin
+                automatic logic [16:0] sum = {1'b0, opa.w16[b]} + {1'b0, opb.w16[b]};
+                vxsat.w16[b] = {2{sum[16]}};
+                res.w16[b]   = sum[16] ? 16'hFFFF : sum[15:0];
+              end
+            EW32: for (int b = 0; b < 2; b++) begin
+                automatic logic [32:0] sum = {1'b0, opa.w32[b]} + {1'b0, opb.w32[b]};
+                vxsat.w32[b] = {4{sum[32]}};
+                res.w32[b]   = sum[32] ? 32'hFFFF_FFFF : sum[31:0];
+              end
+            EW64: for (int b = 0; b < 1; b++) begin
+                automatic logic [64:0] sum = {1'b0, opa.w64[b]} + {1'b0, opb.w64[b]};
+                vxsat.w64[b] = {8{sum[64]}};
+                res.w64[b]   = sum[64] ? 64'hFFFF_FFFF_FFFF_FFFF : sum[63:0];
+              end
+            default:;
+          endcase
+
         VSADD: if (FixPtSupport == FixedPointEnable) unique case (vew_i)
             EW8: for (int b = 0; b < 8; b++) begin
-                automatic logic [8:0] sum = opa.w8[b] + opb.w8[b];
-                vxsat.w8[b]   = (sum[7]^opa.w8[b][7]) & ~(opa.w8[b][7] ^ opb.w8[b][7]);
-                res.w8[b]     = vxsat.w8[b] ? (sum[7] ? {1'b0, {7{1'b1}}} : {1'b1, {7{1'b0}}} ) : sum[7:0];
-              end
-            EW16: for (int b = 0; b < 4; b++) begin
-                automatic logic [16:0] sum = opa.w16[b] + opb.w16[b];
-                vxsat.w16[b]   = {2{(sum[15] ^ opa.w16[b][15]) & ~(opa.w16[b][15] ^ opb.w16[b][15])}};
-                res.w16[b]     = &vxsat.w16[b] ? (sum[15] ? {1'b0, {15{1'b1}}} : {1'b1, {15{1'b0}}} ) : sum[15:0];
-              end
-            EW32: for (int b = 0; b < 2; b++) begin
-                automatic logic [32:0] sum = opa.w32[b] + opb.w32[b];
-                vxsat.w32[b]   = {4{(sum[31] ^ opa.w32[b][31]) && !(opa.w32[b][31] ^ opb.w32[b][31])}};
-                res.w32[b]     = &vxsat.w32[b] ? (sum[31] ? {1'b0, {31{1'b1}}} : {1'b1, {31{1'b0}}} ) : sum[31:0];
-              end
-            EW64: for (int b = 0; b < 1; b++) begin
-                automatic logic [64:0] sum = opa.w64[b] + opb.w64[b];
-                vxsat.w64[b]   = {8{(sum[63] ^ opa.w64[b][63]) & ~(opa.w64[b][63] ^ opb.w64[b][63])}};
-                res.w64[b]     = &vxsat.w64[b] ? (sum[63] ? {1'b0, {63{1'b1}}} : {1'b1, {63{1'b0}}} ) : sum[63:0];
-              end
-          endcase
-        VAADD, VAADDU: if (FixPtSupport == FixedPointEnable) unique case (vew_i)
-            EW8: for (int b = 0; b < 8; b++) begin
-              automatic logic [ 8:0] sum = opa.w8 [b] + opb.w8 [b];
-                unique case (vxrm)
-                  2'b00: r = sum[0];
-                  2'b01: r = &sum[1:0];
-                  2'b10: r = 1'b0;
-                  2'b11: r = !sum[1] & (sum[0]!=0);
-                endcase
-                res.w8[b] = (op_i == VAADDU) ? sum[8:1] + r : {sum[7], sum[7:1]} + r;
-              end
-            EW16: for (int b = 0; b < 4; b++) begin
-                automatic logic [16:0] sum = opa.w16[b] + opb.w16[b];
-                unique case (vxrm)
-                  2'b00: r = sum[0];
-                  2'b01: r = &sum[1:0];
-                  2'b10: r = 1'b0;
-                  2'b11: r = !sum[1] & (sum[0]!=0);
-                endcase
-                res.w16[b] = (op_i == VAADDU) ? sum[16:1] + r : {sum[15], sum[15:1]} + r;
-              end
-            EW32: for (int b = 0; b < 2; b++) begin
-                automatic logic [32:0] sum = opa.w32[b] + opb.w32[b];
-                unique case (vxrm)
-                  2'b00: r = sum[0];
-                  2'b01: r = &sum[1:0];
-                  2'b10: r = 1'b0;
-                  2'b11: r = !sum[1] & (sum[0]!=0);
-                endcase
-                res.w32[b] = (op_i == VAADDU) ? sum[32:1] + r : {sum[31], sum[31:1]} + r;
-              end
-            EW64: for (int b = 0; b < 1; b++) begin
-                automatic logic [64:0] sum = opa.w64[b] + opb.w64[b];
-                unique case (vxrm)
-                  2'b00: r = sum[0];
-                  2'b01: r = &sum[1:0];
-                  2'b10: r = 1'b0;
-                  2'b11: r = !sum[1] & (sum[0]!=0);
-                endcase
-                res.w64[b] = (op_i == VAADDU) ? sum[64:1] + r : {sum[63], sum[63:1]} + r;
-              end
-          endcase
+                automatic logic [7:0] sum = opa.w8[b] + opb.w8[b];
+                automatic logic       sat = (sum[7] ^ opa.w8[b][7]) & ~(opa.w8[b][7] ^ opb.w8[b][7]);
+                vxsat.w8[b] = sat;
+                res.w8[b]   = sat ? (opa.w8[b][7] ? 8'h80 : 8'h7F) : sum;
+              end
+            EW16: for (int b = 0; b < 4; b++) begin
+                automatic logic [15:0] sum = opa.w16[b] + opb.w16[b];
+                automatic logic        sat = (sum[15] ^ opa.w16[b][15]) & ~(opa.w16[b][15] ^ opb.w16[b][15]);
+                vxsat.w16[b] = {2{sat}};
+                res.w16[b]   = sat ? (opa.w16[b][15] ? 16'h8000 : 16'h7FFF) : sum;
+              end
+            EW32: for (int b = 0; b < 2; b++) begin
+                automatic logic [31:0] sum = opa.w32[b] + opb.w32[b];
+                automatic logic        sat = (sum[31] ^ opa.w32[b][31]) & ~(opa.w32[b][31] ^ opb.w32[b][31]);
+                vxsat.w32[b] = {4{sat}};
+                res.w32[b]   = sat ? (opa.w32[b][31] ? 32'h8000_0000 : 32'h7FFF_FFFF) : sum;
+              end
+            EW64: for (int b = 0; b < 1; b++) begin
+                automatic logic [63:0] sum = opa.w64[b] + opb.w64[b];
+                automatic logic        sat = (sum[63] ^ opa.w64[b][63]) & ~(opa.w64[b][63] ^ opb.w64[b][63]);
+                vxsat.w64[b] = {8{sat}};
+                res.w64[b]   = sat ? (opa.w64[b][63] ? 64'h8000_0000_0000_0000 : 64'h7FFF_FFFF_FFFF_FFFF) : sum;
+              end
+            default:;
+          endcase
+
+        VAADD, VAADDU: if (FixPtSupport == FixedPointEnable) begin
+          automatic logic sgn = (op_i == VAADD);
+          unique case (vew_i)
+            EW8: for (int b = 0; b < 8; b++) begin
+                automatic logic [8:0] sum = {sgn & opb.w8[b][7], opb.w8[b]} + {sgn & opa.w8[b][7], opa.w8[b]};
+                res.w8[b] = sum[8:1] + {7'd0, round_1b(sum[1:0], vxrm)};
+              end
+            EW16: for (int b = 0; b < 4; b++) begin
+                automatic logic [16:0] sum = {sgn & opb.w16[b][15], opb.w16[b]} + {sgn & opa.w16[b][15], opa.w16[b]};
+                res.w16[b] = sum[16:1] + {15'd0, round_1b(sum[1:0], vxrm)};
+              end
+            EW32: for (int b = 0; b < 2; b++) begin
+                automatic logic [32:0] sum = {sgn & opb.w32[b][31], opb.w32[b]} + {sgn & opa.w32[b][31], opa.w32[b]};
+                res.w32[b] = sum[32:1] + {31'd0, round_1b(sum[1:0], vxrm)};
+              end
+            EW64: for (int b = 0; b < 1; b++) begin
+                automatic logic [64:0] sum = {sgn & opb.w64[b][63], opb.w64[b]} + {sgn & opa.w64[b][63], opa.w64[b]};
+                res.w64[b] = sum[64:1] + {63'd0, round_1b(sum[1:0], vxrm)};
+              end
+            default:;
+          endcase
+        end
+
         VADD, VADC, VMADC, VREDSUM, VWREDSUMU, VWREDSUM: unique case (vew_i)
             EW8: for (int b = 0; b < 8; b++) begin
-                automatic logic [ 8:0] sum = opa.w8 [b] + opb.w8 [b] +
+                automatic logic [8:0] sum = opa.w8[b] + opb.w8[b] +
                 logic'(op_i inside {VADC, VMADC} && mask_i[1*b] & ~vm_i);
                 res.w8[b] = (op_i == VMADC) ? {6'b0, 1'b1, sum[8]} : sum[7:0];
               end
@@ -246,10 +203,12 @@
                 logic'(op_i inside {VADC, VMADC} && mask_i[8*b] & ~vm_i);
                 res.w64[b] = (op_i == VMADC) ? {62'b0, 1'b1, sum[64]} : sum[63:0];
               end
-          endcase
+            default:;
+          endcase
+
         VSUB, VSBC, VMSBC: unique case (vew_i)
             EW8: for (int b = 0; b < 8; b++) begin
-                automatic logic [ 8:0] sub = opb.w8 [b] - opa.w8 [b] -
+                automatic logic [8:0] sub = opb.w8[b] - opa.w8[b] -
                 logic'(op_i inside {VSBC, VMSBC} && mask_i[1*b] & ~vm_i);
                 res.w8[b] = (op_i == VMSBC) ? {6'b0, 1'b1, sub[8]} : sub[7:0];
               end
@@ -268,226 +227,233 @@
                 logic'(op_i inside {VSBC, VMSBC} && mask_i[8*b] & ~vm_i);
                 res.w64[b] = (op_i == VMSBC) ? {62'b0, 1'b1, sub[64]} : sub[63:0];
               end
-          endcase
+            default:;
+          endcase
+
         VRSUB: unique case (vew_i)
             EW8 : for (int b = 0; b < 8; b++) res.w8 [b] = opa.w8 [b] - opb.w8 [b];
             EW16: for (int b = 0; b < 4; b++) res.w16[b] = opa.w16[b] - opb.w16[b];
             EW32: for (int b = 0; b < 2; b++) res.w32[b] = opa.w32[b] - opb.w32[b];
             EW64: for (int b = 0; b < 1; b++) res.w64[b] = opa.w64[b] - opb.w64[b];
-          endcase
+            default:;
+          endcase
+
         VSSUBU: if (FixPtSupport == FixedPointEnable) unique case (vew_i)
             EW8: for (int b = 0; b < 8; b++) begin
-                automatic logic [8:0] sub = opb.w8 [b] - opa.w8 [b];
-                vxsat.w8[b]   = sub[8];
-                res.w8[b]     = vxsat.w8[b] ? {8{1'b0}} : sub[7:0];
-              end
-            EW16: for (int b = 0; b < 4; b++) begin
-                automatic logic [16:0] sub = opb.w16[b] - opa.w16[b];
-                vxsat.w16[b]   = {2{sub[16]}};
-                res.w16[b]     = &vxsat.w16[b] ? {16{1'b0}} : sub[15:0];
-              end
-            EW32: for (int b = 0; b < 2; b++) begin
-                
```

</details>

---

## 5. Harbor Package File Inventory & Provenance

### Public Workspace (`environment/public/`)
- [`environment/public/BUILD.md`](environment/public/BUILD.md) *(Read-Only Context)*
- [`environment/public/code/LICENSE`](environment/public/code/LICENSE) *(Read-Only Context)*
- [`environment/public/code/ara_pkg.sv`](environment/public/code/ara_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/ariane_pkg.sv`](environment/public/code/ariane_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/axi_pkg.sv`](environment/public/code/axi_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/cf_math_pkg.sv`](environment/public/code/cf_math_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/config_pkg.sv`](environment/public/code/config_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/cv64a6_imafdcv_sv39_config_pkg.sv`](environment/public/code/cv64a6_imafdcv_sv39_config_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/fixed_p_rounding.sv`](environment/public/code/fixed_p_rounding.sv) **(Editable)**
- [`environment/public/code/fpnew_pkg.sv`](environment/public/code/fpnew_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/include/common_cells/assertions.svh`](environment/public/code/include/common_cells/assertions.svh) *(Read-Only Context)*
- [`environment/public/code/include/common_cells/registers.svh`](environment/public/code/include/common_cells/registers.svh) *(Read-Only Context)*
- [`environment/public/code/riscv_pkg.sv`](environment/public/code/riscv_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/rvv_pkg.sv`](environment/public/code/rvv_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/simd_alu.sv`](environment/public/code/simd_alu.sv) **(Editable)**
- [`environment/public/code/spill_register.sv`](environment/public/code/spill_register.sv) *(Read-Only Context)*
- [`environment/public/code/spill_register_flushable.sv`](environment/public/code/spill_register_flushable.sv) *(Read-Only Context)*
- [`environment/public/code/valu.sv`](environment/public/code/valu.sv) **(Editable)**
- [`environment/public/issue.md`](environment/public/issue.md) *(Read-Only Context)*

### Reference Solutions & Isolated Verifier (`solution/` & `tests/`)
- [`solution/solve.sh`](solution/solve.sh) — Harbor oracle script
- [`solution/gold/`](solution/gold/) — Primary golden reference solution
- [`solution/alternate_gold/`](solution/alternate_gold/) — Structurally distinct secondary reference solution
- [`tests/test.sh`](tests/test.sh) — Isolated Harbor verifier entrypoint
- [`tests/private/policy_filter.py`](tests/private/policy_filter.py) — Pre-grader airlock & anti-cheat policy screen
- [`tests/private/grader/run.py`](tests/private/grader/run.py) — Deterministic front-to-back EDA verifier

### Upstream Provenance (`SOURCE.md`)

