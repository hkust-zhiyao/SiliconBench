# `case_21017`: Multi-Region Overlapping Aperture Decode, Coupled Write Arbitration, and Gate-Level Zero-X Parity in AXI4-Lite Crossbar

[Back to Benchmark Root (`README.md`)](../../README.md) | [Full 94-Task Catalog (`TASKS_INDEX.md`)](../../TASKS_INDEX.md) | [`task.toml`](task.toml) | [`instruction.md`](instruction.md) | [`solution/solve.sh`](solution/solve.sh) | [`tests/test.sh`](tests/test.sh) | [`tests/private/grader/run.py`](tests/private/grader/run.py)

---

## 1. Task Overview & Harbor Configuration

| Field | Value |
| :--- | :--- |
| **Task ID** | `case_21017` |
| **Source Silicon Repository** | `alexforencich/verilog-axi` (`repo_40`) |
| **Engineering Problem Type** | **Gate-Level Equivalence, Security & CDC/RDC** (`PT4_GateLevel_Security_CDC`) |
| **EDA Evaluation Stage** | **Stage 3: Static Timing (STA) & CDC/RDC Closure** (`stage3_sta_cdc`) |
| **Coupled Evaluation Gates** | Stage 1 (Functional RTL Sim) -> Stage 2 (Logic Synthesis & Gate-Level Verification) -> Stage 3 (OpenSTA Single-/Multi-Corner Setup/Hold WNS/TNS & CDC/RDC Closure) |
| **Primary Hardware Domain** | `HighSpeed_AXI_NIC_Cache_DMA` (HighSpeed_AXI_NIC_Cache_DMA) |
| **Multi-Domain Tags** | `HighSpeed_AXI_NIC_Cache_DMA` |
| **Editable Files (`allowed_edits`)** | [`code/axil_crossbar.v`](environment/public/code/axil_crossbar.v), [`code/axil_crossbar_addr.v`](environment/public/code/axil_crossbar_addr.v), [`code/axil_crossbar_wr.v`](environment/public/code/axil_crossbar_wr.v), [`code/axil_crossbar_rd.v`](environment/public/code/axil_crossbar_rd.v) (4 files, 1548 LOC) |
| **Public Subsystem Context** | 8 RTL files (2696 LOC) |
| **Base Container Image** | `siliconbench-eda:1.0` (`allow_internet = false`, `environment_mode = "separate"`) |
| **PDK / Environment Profile** | **Standard IEEE 1800-2017 SystemVerilog Dual-Simulator + Yosys Slang** |
| **Task-Customized Collateral?** | **No (Uses Shared Base Image)** — Pure RTL/protocol/synthesis check without external PDK Liberty files. |
| **Verifier Timeout & Seeds** | `600s` total (`300s`/seed) across deterministic seeds `[101, 202]` |

---

## 2. Problem Specification (`issue.md`)

# Multi-Region Overlapping Aperture Decode, Coupled Write Arbitration, and Gate-Level Zero-X Parity in AXI4-Lite Crossbar

`axil_crossbar` (`code/axil_crossbar.v`) and its submodules `axil_crossbar_addr` (`code/axil_crossbar_addr.v`), `axil_crossbar_wr` (`code/axil_crossbar_wr.v`), and `axil_crossbar_rd` (`code/axil_crossbar_rd.v`) interconnect `S_COUNT` AXI4-Lite slave interfaces (`s_axil_*`, connected to upstream masters) with `M_COUNT` AXI4-Lite master interfaces (`m_axil_*`, connected to downstream peripherals), using read-only `code/arbiter.v`, `code/priority_encoder.v`, `code/axil_register_wr.v`, and `code/axil_register_rd.v`. Currently, the subsystem aborts or misroutes hierarchical overlapping address apertures, overflows 32-bit shifts on full-range apertures (`M_ADDR_WIDTH == ADDR_WIDTH`) and wide connectivity matrices (`S_COUNT * M_COUNT > 32`), drops top-level master register-slice parameters, fails elaboration/synthesis on `S_COUNT == 1` or `M_COUNT == 1`, stalls downstream targets when `AW` arrives without `W`, and leaks `X` onto handshake signals in initializer-stripped gate-level simulation.

Update `code/axil_crossbar.v`, `code/axil_crossbar_addr.v`, `code/axil_crossbar_wr.v`, and `code/axil_crossbar_rd.v` while preserving `axil_crossbar`'s module name, parameters, and port declarations (internal `axil_crossbar_addr`/`wr`/`rd` index widths may be guarded for `S_COUNT == 1` or `M_COUNT == 1`):

1. **Hierarchical Overlapping Aperture Decode, Wide `M_CONNECT` & Security Window Isolation (`axil_crossbar_addr`)**:
   - Support `M_REGIONS >= 1` with overlapping address apertures (removing the elaboration overlap abort while retaining alignment/range checks) and full-width apertures up to `M_ADDR_WIDTH == ADDR_WIDTH` (e.g., `32` on a `32`-bit bus); regions with `M_ADDR_WIDTH == 0` remain inactive.
   - Across all active regions `(i, j)` (`0 <= i < M_COUNT`, `0 <= j < M_REGIONS`) where `M_CONNECT[i*S_COUNT + S] == 1'b1` (supporting `S_COUNT * M_COUNT > 32` without 32-bit shift truncation) and `s_axil_aaddr` falls within region `(i, j)`, select the winning target by **longest-prefix match** (smallest matching `M_ADDR_WIDTH`; break ties in favor of higher master index `i`, then higher region index `j`).
   - Enforce security isolation **after** winning aperture selection: if no connected region matches, or if the winning aperture belongs to a secure master (`M_SECURE[i] == 1'b1`) and the transaction is non-secure (`s_axil_aprot[1] == 1'b1`), complete the transaction internally with `DECERR` (`2'b11`, returning `RDATA = 0` on reads and absorbing the `W` beat on writes without asserting downstream `m_axil_awvalid`/`m_axil_wvalid`/`m_axil_arvalid`), never falling through to a wider non-secure fallback aperture.

2. **Top-Level Slice Parameter Forwarding, `1xM` / `Sx1` Support & Deadlock-Free Write Arbitration (`axil_crossbar`, `axil_crossbar_wr`, `axil_crossbar_rd`)**:
   - Forward `M_AW_REG_TYPE`, `M_W_REG_TYPE`, `M_B_REG_TYPE`, `M_AR_REG_TYPE`, and `M_R_REG_TYPE` from `axil_crossbar` to `axil_crossbar_wr` and `axil_crossbar_rd`, and support all `S_COUNT >= 1`, `M_COUNT >= 1` geometries (including `S_COUNT == 1` and `M_COUNT == 1`) without negative/zero-width vectors or out-of-bounds indexing.
   - In `axil_crossbar_wr`, prevent a master that presents `AW` many cycles ahead of `W` (or `W` ahead of `AW`) from locking a shared downstream peripheral and blocking ready `AW+W` writers, and ensure coupled zero-slice (`M_AW_REG_TYPE = 0, M_W_REG_TYPE = 0`) downstream slaves that wait for simultaneous `m_axil_awvalid && m_axil_wvalid` complete without deadlock.

3. **Synthesis Cleanliness & Initializer-Stripped ASIC Gate-Level Zero-X Parity**:
   - Synthesize cleanly in Yosys with zero inferred latches, zero combinational loops, and strictly one-hot/zero downstream `m_axil_*valid` / `*ready` strobes per transaction.
   - Synchronously reset all control/FIFO-status/drop/select state on `rst` and guard empty response-routing FIFO outputs so 4-state RTL (`iverilog`, `verilator`) and initializer-stripped gate-level simulation exhibit zero `X`/`Z` on all `s_axil_*` and `m_axil_*` handshake/response signals after synchronous `rst` and produce identical transaction results.

---

## 3. Build & Verification Instructions (`BUILD.md`)

# Build & Verification Guide

## Workspace Layout
- **Editable RTL**:
  - `code/axil_crossbar.v`
  - `code/axil_crossbar_addr.v`
  - `code/axil_crossbar_wr.v`
  - `code/axil_crossbar_rd.v`
- **Read-Only Collateral** (must remain unmodified):
  - `code/arbiter.v`
  - `code/priority_encoder.v`
  - `code/axil_register_wr.v`
  - `code/axil_register_rd.v`
  - `code/COPYING`

## Toolchain Commands
1. **Icarus Verilog Compilation & Simulation**:
   ```bash
   iverilog -g2012 \
     -o sim.vvp <your_tb.sv> \
     code/priority_encoder.v code/arbiter.v \
     code/axil_register_wr.v code/axil_register_rd.v \
     code/axil_crossbar_addr.v code/axil_crossbar_wr.v code/axil_crossbar_rd.v code/axil_crossbar.v
   vvp sim.vvp
   ```

2. **Verilator Lint & Simulation**:
   ```bash
   env -u VERILATOR_ROOT verilator \
     --lint-only -Wall -Wno-fatal --top-module axil_crossbar \
     code/priority_encoder.v code/arbiter.v \
     code/axil_register_wr.v code/axil_register_rd.v \
     code/axil_crossbar_addr.v code/axil_crossbar_wr.v code/axil_crossbar_rd.v code/axil_crossbar.v
   ```

3. **Yosys Synthesis, Loop/Latch Check & Initializer-Stripped Gate-Level Netlist**:
   ```bash
   yosys -p "
     read_verilog code/priority_encoder.v code/arbiter.v code/axil_register_wr.v code/axil_register_rd.v code/axil_crossbar_addr.v code/axil_crossbar_wr.v code/axil_crossbar_rd.v code/axil_crossbar.v;
     hierarchy -check -top axil_crossbar;
     proc; setattr -unset init w:*; flatten;
     select -assert-none t:\$dlatch* t:\$_DLATCH*;
     synth -top axil_crossbar;
     check -assert; select -assert-none t:\$dlatch* t:\$_DLATCH*;
     write_verilog -noattr netlist.v
   "
   ```
   Simulate `netlist.v` with `/opt/siliconbench/tools/oss-cad-suite/share/yosys/simcells.v`.

## Implementation Notes
- Editable RTL must remain pure synthesizable Verilog-2001/SystemVerilog: do **not** add new simulation-control or file-I/O system tasks (such as `$finish`, `$stop`, `$fatal`, `$readmem*`, or `$system`), `force`/`release` statements, or simulator/synthesis conditional compilation macros (`ifdef SYNTHESIS`, `ifdef VERILATOR`, `ifdef __ICARUS__`).

---

## 4. Reference Fix Inspection (Buggy Starter vs. Golden Solution Diff)

> Human reviewers can inspect the exact reference bug fix below, or browse full files in [`environment/public/`](environment/public/), [`solution/gold/`](solution/gold/), and [`solution/alternate_gold/`](solution/alternate_gold/).

<details open>
<summary><b>Click to expand/collapse Unified Diff (<code>environment/public/</code> vs. <code>solution/gold/</code>)</b></summary>

```diff
--- a/environment/public/code/axil_crossbar.v (Buggy Starter)
+++ b/solution/gold/code/axil_crossbar.v (Golden Reference)
@@ -33,69 +33,28 @@
  */
 module axil_crossbar #
 (
-    // Number of AXI inputs (slave interfaces)
     parameter S_COUNT = 4,
-    // Number of AXI outputs (master interfaces)
     parameter M_COUNT = 4,
-    // Width of data bus in bits
     parameter DATA_WIDTH = 32,
-    // Width of address bus in bits
     parameter ADDR_WIDTH = 32,
-    // Width of wstrb (width of data bus in words)
     parameter STRB_WIDTH = (DATA_WIDTH/8),
-    // Number of concurrent operations for each slave interface
-    // S_COUNT concatenated fields of 32 bits
     parameter S_ACCEPT = {S_COUNT{32'd16}},
-    // Number of regions per master interface
     parameter M_REGIONS = 1,
-    // Master interface base addresses
-    // M_COUNT concatenated fields of M_REGIONS concatenated fields of ADDR_WIDTH bits
-    // set to zero for default addressing based on M_ADDR_WIDTH
     parameter M_BASE_ADDR = 0,
-    // Master interface address widths
-    // M_COUNT concatenated fields of M_REGIONS concatenated fields of 32 bits
     parameter M_ADDR_WIDTH = {M_COUNT{{M_REGIONS{32'd24}}}},
-    // Read connections between interfaces
-    // M_COUNT concatenated fields of S_COUNT bits
     parameter M_CONNECT_READ = {M_COUNT{{S_COUNT{1'b1}}}},
-    // Write connections between interfaces
-    // M_COUNT concatenated fields of S_COUNT bits
     parameter M_CONNECT_WRITE = {M_COUNT{{S_COUNT{1'b1}}}},
-    // Number of concurrent operations for each master interface
-    // M_COUNT concatenated fields of 32 bits
     parameter M_ISSUE = {M_COUNT{32'd16}},
-    // Secure master (fail operations based on awprot/arprot)
-    // M_COUNT bits
     parameter M_SECURE = {M_COUNT{1'b0}},
-    // Slave interface AW channel register type (input)
-    // 0 to bypass, 1 for simple buffer, 2 for skid buffer
     parameter S_AW_REG_TYPE = {S_COUNT{2'd0}},
-    // Slave interface W channel register type (input)
-    // 0 to bypass, 1 for simple buffer, 2 for skid buffer
     parameter S_W_REG_TYPE = {S_COUNT{2'd0}},
-    // Slave interface B channel register type (output)
-    // 0 to bypass, 1 for simple buffer, 2 for skid buffer
     parameter S_B_REG_TYPE = {S_COUNT{2'd1}},
-    // Slave interface AR channel register type (input)
-    // 0 to bypass, 1 for simple buffer, 2 for skid buffer
     parameter S_AR_REG_TYPE = {S_COUNT{2'd0}},
-    // Slave interface R channel register type (output)
-    // 0 to bypass, 1 for simple buffer, 2 for skid buffer
     parameter S_R_REG_TYPE = {S_COUNT{2'd2}},
-    // Master interface AW channel register type (output)
-    // 0 to bypass, 1 for simple buffer, 2 for skid buffer
     parameter M_AW_REG_TYPE = {M_COUNT{2'd1}},
-    // Master interface W channel register type (output)
-    // 0 to bypass, 1 for simple buffer, 2 for skid buffer
     parameter M_W_REG_TYPE = {M_COUNT{2'd2}},
-    // Master interface B channel register type (input)
-    // 0 to bypass, 1 for simple buffer, 2 for skid buffer
     parameter M_B_REG_TYPE = {M_COUNT{2'd0}},
-    // Master interface AR channel register type (output)
-    // 0 to bypass, 1 for simple buffer, 2 for skid buffer
     parameter M_AR_REG_TYPE = {M_COUNT{2'd1}},
-    // Master interface R channel register type (input)
-    // 0 to bypass, 1 for simple buffer, 2 for skid buffer
     parameter M_R_REG_TYPE = {M_COUNT{2'd0}}
 )
 (
@@ -164,15 +123,14 @@
     .M_SECURE(M_SECURE),
     .S_AW_REG_TYPE(S_AW_REG_TYPE),
     .S_W_REG_TYPE (S_W_REG_TYPE),
-    .S_B_REG_TYPE (S_B_REG_TYPE)
+    .S_B_REG_TYPE (S_B_REG_TYPE),
+    .M_AW_REG_TYPE(M_AW_REG_TYPE),
+    .M_W_REG_TYPE (M_W_REG_TYPE),
+    .M_B_REG_TYPE (M_B_REG_TYPE)
 )
 axil_crossbar_wr_inst (
     .clk(clk),
     .rst(rst),
-
-    /*
-     * AXI lite slave interfaces
-     */
     .s_axil_awaddr(s_axil_awaddr),
     .s_axil_awprot(s_axil_awprot),
     .s_axil_awvalid(s_axil_awvalid),
@@ -184,10 +142,6 @@
     .s_axil_bresp(s_axil_bresp),
     .s_axil_bvalid(s_axil_bvalid),
     .s_axil_bready(s_axil_bready),
-
-    /*
-     * AXI lite master interfaces
-     */
     .m_axil_awaddr(m_axil_awaddr),
     .m_axil_awprot(m_axil_awprot),
     .m_axil_awvalid(m_axil_awvalid),
@@ -215,15 +169,13 @@
     .M_ISSUE(M_ISSUE),
     .M_SECURE(M_SECURE),
     .S_AR_REG_TYPE(S_AR_REG_TYPE),
-    .S_R_REG_TYPE (S_R_REG_TYPE)
+    .S_R_REG_TYPE (S_R_REG_TYPE),
+    .M_AR_REG_TYPE(M_AR_REG_TYPE),
+    .M_R_REG_TYPE (M_R_REG_TYPE)
 )
 axil_crossbar_rd_inst (
     .clk(clk),
     .rst(rst),
-
-    /*
-     * AXI lite slave interfaces
-     */
     .s_axil_araddr(s_axil_araddr),
     .s_axil_arprot(s_axil_arprot),
     .s_axil_arvalid(s_axil_arvalid),
@@ -232,10 +184,6 @@
     .s_axil_rresp(s_axil_rresp),
     .s_axil_rvalid(s_axil_rvalid),
     .s_axil_rready(s_axil_rready),
-
-    /*
-     * AXI lite master interfaces
-     */
     .m_axil_araddr(m_axil_araddr),
     .m_axil_arprot(m_axil_arprot),
     .m_axil_arvalid(m_axil_arvalid),

--- a/environment/public/code/axil_crossbar_addr.v (Buggy Starter)
+++ b/solution/gold/code/axil_crossbar_addr.v (Golden Reference)
@@ -33,31 +33,17 @@
  */
 module axil_crossbar_addr #
 (
-    // Slave interface index
     parameter S = 0,
-    // Number of AXI inputs (slave interfaces)
     parameter S_COUNT = 4,
-    // Number of AXI outputs (master interfaces)
     parameter M_COUNT = 4,
-    // Width of address bus in bits
     parameter ADDR_WIDTH = 32,
-    // Number of regions per master interface
     parameter M_REGIONS = 1,
-    // Master interface base addresses
-    // M_COUNT concatenated fields of M_REGIONS concatenated fields of ADDR_WIDTH bits
-    // set to zero for default addressing based on M_ADDR_WIDTH
     parameter M_BASE_ADDR = 0,
-    // Master interface address widths
-    // M_COUNT concatenated fields of M_REGIONS concatenated fields of 32 bits
     parameter M_ADDR_WIDTH = {M_COUNT{{M_REGIONS{32'd24}}}},
-    // Connections between interfaces
-    // M_COUNT concatenated fields of S_COUNT bits
     parameter M_CONNECT = {M_COUNT{{S_COUNT{1'b1}}}},
-    // Secure master (fail operations based on awprot/arprot)
-    // M_COUNT bits
     parameter M_SECURE = {M_COUNT{1'b0}},
-    // Enable write command output
-    parameter WC_OUTPUT = 0
+    parameter WC_OUTPUT = 0,
+    parameter CL_M_COUNT = M_COUNT > 1 ? $clog2(M_COUNT) : 1
 )
 (
     input  wire                       clk,
@@ -74,14 +60,14 @@
     /*
      * Address output
      */
-    output wire [$clog2(M_COUNT)-1:0] m_select,
+    output wire [CL_M_COUNT-1:0]      m_select,
     output wire                       m_axil_avalid,
     input  wire                       m_axil_aready,
 
     /*
      * Write command output
      */
-    output wire [$clog2(M_COUNT)-1:0] m_wc_select,
+    output wire [CL_M_COUNT-1:0]      m_wc_select,
     output wire                       m_wc_decerr,
     output wire                       m_wc_valid,
     input  wire                       m_wc_ready,
@@ -89,150 +75,104 @@
     /*
      * Reply command output
      */
-    output wire [$clog2(M_COUNT)-1:0] m_rc_select,
+    output wire [CL_M_COUNT-1:0]      m_rc_select,
     output wire                       m_rc_decerr,
     output wire                       m_rc_valid,
     input  wire                       m_rc_ready
 );
 
-parameter CL_S_COUNT = $clog2(S_COUNT);
-parameter CL_M_COUNT = $clog2(M_COUNT);
+localparam [M_COUNT*S_COUNT-1:0] M_CONNECT_VEC = M_CONNECT;
+localparam [M_COUNT-1:0]         M_SECURE_VEC  = M_SECURE;
 
 // default address computation
 function [M_COUNT*M_REGIONS*ADDR_WIDTH-1:0] calcBaseAddrs(input [31:0] dummy);
-    integer i;
+    integer k;
+    reg [31:0] width;
     reg [ADDR_WIDTH-1:0] base;
-    reg [ADDR_WIDTH-1:0] width;
     reg [ADDR_WIDTH-1:0] size;
     reg [ADDR_WIDTH-1:0] mask;
     begin
         calcBaseAddrs = {M_COUNT*M_REGIONS*ADDR_WIDTH{1'b0}};
-        base = 0;
-        for (i = 0; i < M_COUNT*M_REGIONS; i = i + 1) begin
-            width = M_ADDR_WIDTH[i*32 +: 32];
-            mask = {ADDR_WIDTH{1'b1}} >> (ADDR_WIDTH - width);
-            size = mask + 1;
-            if (width > 0) begin
+        base = {ADDR_WIDTH{1'b0}};
+        for (k = 0; k < M_COUNT*M_REGIONS; k = k + 1) begin
+            width = M_ADDR_WIDTH[k*32 +: 32];
+            if (width > 0 && width <= ADDR_WIDTH) begin
+                mask = (width == ADDR_WIDTH) ? {ADDR_WIDTH{1'b1}} : ({ADDR_WIDTH{1'b1}} >> (ADDR_WIDTH - width));
+                size = mask + 1'b1;
                 if ((base & mask) != 0) begin
-                   base = base + size - (base & mask); // align
+                    base = base + size - (base & mask);
                 end
-                calcBaseAddrs[i * ADDR_WIDTH +: ADDR_WIDTH] = base;
-                base = base + size; // increment
+                calcBaseAddrs[k * ADDR_WIDTH +: ADDR_WIDTH] = base;
+                base = base + size;
             end
         end
     end
 endfunction
 
-parameter M_BASE_ADDR_INT = M_BASE_ADDR ? M_BASE_ADDR : calcBaseAddrs(0);
+parameter [M_COUNT*M_REGIONS*ADDR_WIDTH-1:0] M_BASE_ADDR_INT = M_BASE_ADDR ? M_BASE_ADDR : calcBaseAddrs(0);
 
 integer i, j;
-
-// check configuration
 initial begin
     if (M_REGIONS < 1) begin
-        $error("Error: need at least 1 region (instance %m)");
+        $display("Error: need at least 1 region (instance %m)");
         $finish;
     end
 
     for (i = 0; i < M_COUNT*M_REGIONS; i = i + 1) begin
         if (M_ADDR_WIDTH[i*32 +: 32] && M_ADDR_WIDTH[i*32 +: 32] > ADDR_WIDTH) begin
-            $error("Error: address width out of range (instance %m)");
+            $display("Error: address width out of range (instance %m)");
             $finish;
         end
-    end
-
-    $display("Addressing configuration for axil_crossbar_addr instance %m");
-    for (i = 0; i < M_COUNT*M_REGIONS; i = i + 1) begin
-        if (M_ADDR_WIDTH[i*32 +: 32]) begin
-            $display("%2d (%2d): %x / %02d -- %x-%x",
-                i/M_REGIONS, i%M_REGIONS,
-                M_BASE_ADDR_INT[i*ADDR_WIDTH +: ADDR_WIDTH],
-                M_ADDR_WIDTH[i*32 +: 32],
-                M_BASE_ADDR_INT[i*ADDR_WIDTH +: ADDR_WIDTH] & ({ADDR_WIDTH{1'b1}} << M_ADDR_WIDTH[i*32 +: 32]),
-                M_BASE_ADDR_INT[i*ADDR_WIDTH +: ADDR_WIDTH] | ({ADDR_WIDTH{1'b1}} >> (ADDR_WIDTH - M_ADDR_WIDTH[i*32 +: 32]))
-            );
-        end
-    end
-
-    for (i = 0; i < M_COUNT*M_REGIONS; i = i + 1) begin
-        if ((M_BASE_ADDR_INT[i*ADDR_WIDTH +: ADDR_WIDTH] & (2**M_ADDR_WIDTH[i*32 +: 32]-1)) != 0) begin
-            $display("Region not aligned:");
-            $display("%2d (%2d): %x / %2d -- %x-%x",
-                i/M_REGIONS, i%M_REGIONS,
-                M_BASE_ADDR_INT[i*ADDR_WIDTH +: ADDR_WIDTH],
-                M_ADDR_WIDTH[i*32 +: 32],
-                M_BASE_ADDR_INT[i*ADDR_WIDTH +: ADDR_WIDTH] & ({ADDR_WIDTH{1'b1}} << M_ADDR_WIDTH[i*32 +: 32]),
-                M_BASE_ADDR_INT[i*ADDR_WIDTH +: ADDR_WIDTH] | ({ADDR_WIDTH{1'b1}} >> (ADDR_WIDTH - M_ADDR_WIDTH[i*32 +: 32]))
-            );
-            $error("Error: address range not aligned (instance %m)");
-            $finish;
-        end
-    end
-
-    for (i = 0; i < M_COUNT*M_REGIONS; i = i + 1) begin
-        for (j = i+1; j < M_COUNT*M_REGIONS; j = j + 1) begin
-            if (M_ADDR_WIDTH[i*32 +: 32] && M_ADDR_WIDTH[j*32 +: 32]) begin
-                if (((M_BASE_ADDR_INT[i*ADDR_WIDTH +: ADDR_WIDTH] & ({ADDR_WIDTH{1'b1}} << M_ADDR_WIDTH[i*32 +: 32])) <= (M_BASE_ADDR_INT[j*ADDR_WIDTH +: ADDR_WIDTH] | ({ADDR_WIDTH{1'b1}} >> (ADDR_WIDTH - M_ADDR_WIDTH[j*32 +: 32]))))
-                        && ((M_BASE_ADDR_INT[j*ADDR_WIDTH +: ADDR_WIDTH] & ({ADDR_WIDTH{1'b1}} << M_ADDR_WIDTH[j*32 +: 32])) <= (M_BASE_ADDR_INT[i*ADDR_WIDTH +: ADDR_WIDTH] | ({ADDR_WIDTH{1'b1}} >> (ADDR_WIDTH - M_ADDR_WIDTH[i*32 +: 32]))))) begin
-                    $display("Overlapping regions:");
-                    $display("%2d (%2d): %x / %2d -- %x-%x",
-                        i/M_REGIONS, i%M_REGIONS,
-                        M_BASE_ADDR_INT[i*ADDR_WIDTH +: ADDR_WIDTH],
-                        M_ADDR_WIDTH[i*32 +: 32],
-                        M_BASE_ADDR_INT[i*ADDR_WIDTH +: ADDR_WIDTH] & ({ADDR_WIDTH{1'b1}} << M_ADDR_WIDTH[i*32 +: 32]),
-                        M_BASE_ADDR_INT[i*ADDR_WIDTH +: ADDR_WIDTH] | ({ADDR_WIDTH{1'b1}} >> (ADDR_WIDTH - M_ADDR_WIDTH[i*32 +: 32]))
-                    );
-                    $display("%2d (%2d): %x / %2d -- %x-%x",
-                        j/M_REGIONS, j%M_REGIONS,
-                        M_BASE_ADDR_INT[j*ADDR_WIDTH +: ADDR_WIDTH],
-                        M_ADDR_WIDTH[j*32 +: 32],
-                        M_BASE_ADDR_INT[j*ADDR_WIDTH +: ADDR_WIDTH] & ({ADDR_WIDTH{1'b1}} << M_ADDR_WIDTH[j*32 +: 32]),
-                        M_BASE_ADDR_INT[j*ADDR_WIDTH +: ADDR_WIDTH] | ({ADDR_WIDTH{1'b1}} >> (ADDR_WIDTH - M_ADDR_WIDTH[j*32 +: 32]))
-                    );
-                    $error("Error: address ranges overlap (instance %m)");
-                    $finish;
-                end
+        if (M_ADDR_WIDTH[i*32 +: 32] && M_ADDR_WIDTH[i*32 +: 32] < ADDR_WIDTH) begin
+            if ((M_BASE_ADDR_INT[i*ADDR_WIDTH +: ADDR_WIDTH] & ({ADDR_WIDTH{1'b1}} >> (ADDR_WIDTH - M_ADDR_WIDTH[i*32 +: 32]))) != 0) begin
+                $display("Error: address range not aligned (instance %m)");
+                $finish;
             end
         end
     end
 end
 
-localparam [2:0]
-    STATE_IDLE = 3'd0,
-    STATE_DECODE = 3'd1;
-
-reg [2:0] state_reg = STATE_IDLE, state_next;
-
-reg s_axil_aready_reg = 0, s_axil_aready_next;
-
-reg [CL_M_COUNT-1:0] m_select_reg = 0, m_select_next;
-reg m_axil_avalid_reg = 1'b0, m_axil_avalid_next;
-reg m_decerr_reg = 1'b0, m_decerr_next;
-reg m_wc_valid_reg = 1'b0, m_wc_valid_next;
-reg m_rc_valid_reg = 1'b0, m_rc_valid_next;
+localparam [1:0]
+    STATE_IDLE   = 2'd0,
+    STATE_DECODE = 2'd1;
+
+reg [1:0] state_reg, state_next;
+reg s_axil_aready_reg, s_axil_aready_next;
+reg [CL_M_COUNT-1:0] m_select_reg, m_select_next;
+reg m_axil_avalid_reg, m_axil_avalid_next;
+reg m_decerr_reg, m_decerr_next;
+reg m_wc_valid_reg, m_wc_valid_next;
+reg m_rc_valid_reg, m_rc_valid_next;
 
 assign s_axil_aready = s_axil_aready_reg;
-
-assign m_select = m_select_reg;
+assign m_select      = m_select_reg;
 assign m_axil_avalid = m_axil_avalid_reg;
-
-assign m_wc_select = m_select_reg;
-assign m_wc_decerr = m_decerr_reg;
-assign m_wc_valid = m_wc_valid_reg;
-
-assign m_rc_select = m_select_reg;
-assign m_rc_decerr = m_decerr_reg;
-assign m_rc_valid = m_rc_valid_reg;
+assign m_wc_select   = m_select_reg;
+assign m_wc_decerr   = m_decerr_reg;
+assign m_wc_valid    = m_wc_valid_reg;
+assign m_rc_select   = m_select_reg;
+assign m_rc_decerr   = m_decerr_reg;
+assign m_rc_valid    = m_rc_valid_reg;
 
 reg match;
+reg [31:0] best_width;
+reg [CL_M_COUNT-1:0] best_master;
+reg best_secure;
+reg [31:0] cur_w;
+reg [ADDR_WIDTH-1:0] cur_base;
+reg [ADDR_WIDTH-1:0] cur_mask;
 
 always @* begin
     state_next = STATE_IDLE;
-
     match = 1'b0;
+    best_width = ADDR_WIDTH + 32'd1;
+    best_master = {CL_M_COUNT{1'b0}};
+    best_secure = 1'b0;
+    cur_w = 32'd0;
+    cur_base = {ADDR_WIDTH{1'b0}};
+    cur_mask = {ADDR_WIDTH{1'b0}};
 
     s_axil_aready_next = 1'b0;
-
     m_select_next = m_select_reg;
     m_axil_avalid_next = m_axil_avalid_reg && !m_axil_aready;
     m_decerr_next = m_decerr_reg;
@@ -241,37 +181,46 @@
 
     case (state_reg)
         STATE_IDLE: begin
-            // idle state, store values
             s_axil_aready_next = 1'b0;
-
             if (s_axil_avalid && !s_axil_aready) begin
                 match = 1'b0;
+                best_width = ADDR_WIDTH + 32'd1;
+                best_master = {CL_M_COUNT{1'b0}};
+                best_secure = 1'b0;
+
                 for (i = 0; i < M_COUNT; i = i + 1) begin
                     for (j = 0; j < M_REGIONS; j = j + 1) begin
-                        if (M_ADDR_WIDTH[(i*M_REGIONS+j)*32 +: 32] && (!M_SECURE[i] || !s_axil_aprot[1]) && (M_CONNECT & (1 << (S+i*S_COUNT))) && (s_axil_aaddr >> M_ADDR_WIDTH[(i*M_REGIONS+j)*32 +: 32]) == (M_BASE_ADDR_INT[(i*M_REGIONS+j)*ADDR_WIDTH +: ADDR_WIDTH] >> M_ADDR_WIDTH[(i*M_REGIONS+j)*32 +: 32])) begin
-                            m_select_next = i;
-                            match = 1'b1;
+                        cur_w = M_ADDR_WIDTH[(i*M_REGIONS+j)*32 +: 32];
+                        cur_base = M_BASE_ADDR_INT[(i*M_REGIONS+j)*ADDR_WIDTH +: ADDR_WIDTH];
+                        if (cur_w > 32'd0 && cur_w <= ADDR_WIDTH && M_CONNECT_VEC[i*S_COUNT + S]) begin
+                            cur_mask = (cur_w == ADDR_WIDTH) ? {ADDR_WIDTH{1'b1}} : ({ADDR_WIDTH{1'b1}} >> (ADDR_WIDTH - cur_w));
+                            if (((s_axil_aaddr ^ cur_base) & ~cur_mask) == {ADDR_WIDTH{1'b0}}) begin
+                                if (!match || (cur_w <= best_width)) begin
+                                    match = 1'b1;
+                                    best_width = cur_w;
+                                    best_master = i[CL_M_COUNT-1:0];
+                                    best_secure = M_SECURE_VEC[i];
+                                end
+                            end
                         end
                     end
                 end
 
-                if (match) begin
-                    // address decode successful
+                if (match && !(best_secure && s_axil_aprot[1])) begin
+                    m_select_next = best_master;
                     m_axil_avalid_next = 1'b1;
                     m_decerr_next = 1'b0;
-                    m_wc_valid_next = WC_OUTPUT;
+                    m_wc_valid_next = WC_OUTPUT ? 1'b1 : 1'b0;
                     m_rc_valid_next = 1'b1;
                     state_next = STATE_DECODE;
                 end else begin
-                    // decode error
+                    m_select_next = {CL_M_COUNT{1'b0}};
                     m_axil_avalid_next = 1'b0;
                     m_decerr_next = 1'b1;
-                    m_wc_valid_next = WC_OUTPUT;
+                    m_wc_valid_next = WC_OUTPUT ? 1'b1 : 1'b0;
                     m_rc_valid_next = 1'b1;
                     state_next = STATE_DECODE;
                 end
-            end else begin
-                state_next = STATE_IDLE;
             end
         end
         STATE_DECODE: begin
@@ -282,26 +231,30 @@
                 state_next = STATE_DECODE;
             end
         end
+        default: begin
+            state_next = STATE_IDLE;
+        end
     endcase
 end
 
 always @(posedge clk) begin
     if (rst) begin
-        state_reg <= STATE_IDLE;
+        state_reg         <= STATE_IDLE;
         s_axil_aready_reg <= 1'b0;
+        m_select_reg      <= {CL_M_COUNT{1'b0}};
         m_axil_avalid_reg <= 1'b0;
-        m_wc_valid_reg <= 1'b0;
-        m_rc_valid_reg <= 1'b0;
+        m_decerr_reg      <= 1'b0;
+        m_wc_valid_reg    <= 1'b0;
+        m_rc_valid_reg    <= 1'b0;
     end else begin
-        state_reg <= state_next;
+        state_reg         <= state_next;
         s_axil_aready_reg <= s_axil_aready_next;
+        m_select_reg      <= m_select_next;
         m_axil_avalid_reg <= m_axil_avalid_next;
-        m_wc_valid_reg <= m_wc_valid_next;
-        m_rc_valid_reg <= m_rc_valid_next;
-    end
-
-    m_select_reg <= m_select_next;
-    m_decerr_reg <= m_decerr_next;
+        m_decerr_reg      <= m_decerr_next;
+        m_wc_valid_reg    <= m_wc_valid_next;
+        m_rc_valid_reg    <= m_rc_valid_next;
+    end
 end
 
 endmodule

--- a/environment/public/code/axil_crossbar_wr.v (Buggy Starter)
+++ b/solution/gold/code/axil_crossbar_wr.v (Golden Reference)
@@ -33,54 +33,23 @@
  */
 module axil_crossbar_wr #
 (
-    // Number of AXI inputs (slave interfaces)
     parameter S_COUNT = 4,
-    // Number of AXI outputs (master interfaces)
     parameter M_COUNT = 4,
-    // Width of data bus in bits
     parameter DATA_WIDTH = 32,
-    // Width of address bus in bits
     parameter ADDR_WIDTH = 32,
-    // Width of wstrb (width of data bus in words)
     parameter STRB_WIDTH = (DATA_WIDTH/8),
-    // Number of concurrent operations for each slave interface
-    // S_COUNT concatenated fields of 32 bits
     parameter S_ACCEPT = {S_COUNT{32'd16}},
-    // Number of regions per master interface
     parameter M_REGIONS = 1,
-    // Master interface base addresses
-    // M_COUNT concatenated fields of M_REGIONS concatenated fields of ADDR_WIDTH bits
-    // set to zero for default addressing based on M_ADDR_WIDTH
     parameter M_BASE_ADDR = 0,
-    // Master interface address widths
-    // M_COUNT concatenated fields of M_REGIONS concatenated fields of 32 bits
     parameter M_ADDR_WIDTH = {M_COUNT{{M_REGIONS{32'd24}}}},
-    // Write connections between interfaces
-    // M_COUNT concatenated fields of S_COUNT bits
     parameter M_CONNECT = {M_COUNT{{S_COUNT{1'b1}}}},
-    // Number of concurrent operations for each master interface
-    // M_COUNT concatenated fields of 32 bits
     parameter M_ISSUE = {M_COUNT{32'd16}},
-    // Secure master (fail operations based on awprot/arprot)
-    // M_COUNT bits
     parameter M_SECURE = {M_COUNT{1'b0}},
-    // Slave interface AW channel register type (input)
-    // 0 to bypass, 1 for simple buffer, 2 for skid buffer
     parameter S_AW_REG_TYPE = {S_COUNT{2'd0}},
-    // Slave interface W channel register type (input)
-    // 0 to bypass, 1 for simple buffer, 2 for skid buffer
     parameter S_W_REG_TYPE = {S_COUNT{2'd0}},
-    // Slave interface B channel register type (output)
-    // 0 to bypass, 1 for simple buffer, 2 for skid buffer
     parameter S_B_REG_TYPE = {S_COUNT{2'd1}},
-    // Master interface AW channel register type (output)
-    // 0 to bypass, 1 for simple buffer, 2 for skid buffer
     parameter M_AW_REG_TYPE = {M_COUNT{2'd1}},
-    // Master interface W channel register type (output)
-    // 0 to bypass, 1 for simple buffer, 2 for skid buffer
     parameter M_W_REG_TYPE = {M_COUNT{2'd2}},
-    // Master interface B channel register type (input)
-    // 0 to bypass, 1 for simple buffer, 2 for skid buffer
     parameter M_B_REG_TYPE = {M_COUNT{2'd0}}
 )
 (
@@ -118,22 +87,8 @@
     output wire [M_COUNT-1:0]               m_axil_bready
 );
 
-parameter CL_S_COUNT = $clog2(S_COUNT);
-parameter CL_M_COUNT = $clog2(M_COUNT);
-parameter M_COUNT_P1 = M_COUNT+1;
-parameter CL_M_COUNT_P1 = $clog2(M_COUNT_P1);
-
-integer i;
-
-// check configuration
-initial begin
-    for (i = 0; i < M_COUNT*M_REGIONS; i = i + 1) begin
-        if (M_ADDR_WIDTH[i*32 +: 32] && (M_ADDR_WIDTH[i*32 +: 32] < $clog2(STRB_WIDTH) || M_ADDR_WIDTH[i*32 +: 32] > ADDR_WIDTH)) begin
-            $error("Error: value out of range (instance %m)");
-            $finish;
-        end
-    end
-end
+localparam CL_S_COUNT = S_COUNT > 1 ? $clog2(S_COUNT) : 1;
+localparam CL_M_COUNT = M_COUNT > 1 ? $clog2(M_COUNT) : 1;
 
 wire [S_COUNT*ADDR_WIDTH-1:0]    int_s_axil_awaddr;
 wire [S_COUNT*3-1:0]             int_s_axil_awprot;
@@ -163,11 +118,10 @@
     genvar m, n;
 
     for (m = 0; m < S_COUNT; m = m + 1) begin : s_ifaces
-        // response routing FIFO
-        localparam FIFO_ADDR_WIDTH = $clog2(S_ACCEPT[m*32 +: 32])+1;
-
-        reg [FIFO_ADDR_WIDTH+1-1:0] fifo_wr_ptr_reg = 0;
-        reg [FIFO_ADDR_WIDTH+1-1:0] fifo_rd_ptr_reg = 0;
+        localparam FIFO_ADDR_WIDTH = $clog2(S_ACCEPT[m*32 +: 32]) + 1;
+
+        reg [FIFO_ADDR_WIDTH:0] fifo_wr_ptr_reg;
+        reg [FIFO_ADDR_WIDTH:0] fifo_rd_ptr_reg;
 
         (* ram_style = "distributed", ramstyle = "no_rw_check, mlab" *)
         reg [CL_M_COUNT-1:0] fifo_select[(2**FIFO_ADDR_WIDTH)-1:0];
@@ -178,53 +132,43 @@
         wire fifo_wr_decerr;
         wire fifo_wr_en;
 
-        reg [CL_M_COUNT-1:0] fifo_rd_select_reg = 0;
-        reg fifo_rd_decerr_reg = 0;
-        reg fifo_rd_valid_reg = 0;
+        reg [CL_M_COUNT-1:0] fifo_rd_select_reg;
+        reg fifo_rd_decerr_reg;
+        reg fifo_rd_valid_reg;
         wire fifo_rd_en;
-        reg fifo_half_full_reg = 1'b0;
-
-        wire fifo_empty = fifo_rd_ptr_reg == fifo_wr_ptr_reg;
-
-        integer i;
-
-        initial begin
-            for (i = 0; i < 2**FIFO_ADDR_WIDTH; i = i + 1) begin
-                fifo_select[i] = 0;
-                fifo_decerr[i] = 0;
-            end
-        end
+        reg fifo_half_full_reg;
 
         always @(posedge clk) begin
-            if (fifo_wr_en) begin
-                fifo_select[fifo_wr_ptr_reg[FIFO_ADDR_WIDTH-1:0]] <= fifo_wr_select;
-                fifo_decerr[fifo_wr_ptr_reg[FIFO_ADDR_WIDTH-1:0]] <= fifo_wr_decerr;
-                fifo_wr_ptr_reg <= fifo_wr_ptr_reg + 1;
-            end
-
-            fifo_rd_valid_reg <= fifo_rd_valid_reg && !fifo_rd_en;
-
-            if ((fifo_rd_ptr_reg != fifo_wr_ptr_reg) && (!fifo_rd_valid_reg || fifo_rd_en)) begin
-                fifo_rd_select_reg <= fifo_select[fifo_rd_ptr_reg
```

</details>

---

## 5. Harbor Package File Inventory & Provenance

### Public Workspace (`environment/public/`)
- [`environment/public/BUILD.md`](environment/public/BUILD.md) *(Read-Only Context)*
- [`environment/public/code/COPYING`](environment/public/code/COPYING) *(Read-Only Context)*
- [`environment/public/code/arbiter.v`](environment/public/code/arbiter.v) *(Read-Only Context)*
- [`environment/public/code/axil_crossbar.v`](environment/public/code/axil_crossbar.v) **(Editable)**
- [`environment/public/code/axil_crossbar_addr.v`](environment/public/code/axil_crossbar_addr.v) **(Editable)**
- [`environment/public/code/axil_crossbar_rd.v`](environment/public/code/axil_crossbar_rd.v) **(Editable)**
- [`environment/public/code/axil_crossbar_wr.v`](environment/public/code/axil_crossbar_wr.v) **(Editable)**
- [`environment/public/code/axil_register_rd.v`](environment/public/code/axil_register_rd.v) *(Read-Only Context)*
- [`environment/public/code/axil_register_wr.v`](environment/public/code/axil_register_wr.v) *(Read-Only Context)*
- [`environment/public/code/priority_encoder.v`](environment/public/code/priority_encoder.v) *(Read-Only Context)*
- [`environment/public/issue.md`](environment/public/issue.md) *(Read-Only Context)*

### Reference Solutions & Isolated Verifier (`solution/` & `tests/`)
- [`solution/solve.sh`](solution/solve.sh) — Harbor oracle script
- [`solution/gold/`](solution/gold/) — Primary golden reference solution
- [`solution/alternate_gold/`](solution/alternate_gold/) — Structurally distinct secondary reference solution
- [`tests/test.sh`](tests/test.sh) — Isolated Harbor verifier entrypoint
- [`tests/private/policy_filter.py`](tests/private/policy_filter.py) — Pre-grader airlock & anti-cheat policy screen
- [`tests/private/grader/run.py`](tests/private/grader/run.py) — Deterministic front-to-back EDA verifier

### Upstream Provenance (`SOURCE.md`)

