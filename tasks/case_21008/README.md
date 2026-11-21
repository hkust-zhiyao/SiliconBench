# `case_21008`: Parameterized AXI4 Width Adapter Multi-Ratio Burst Repacking, Splitting, and Synthesis Parity

[Back to Benchmark Root (`README.md`)](../../README.md) | [Full 94-Task Catalog (`TASKS_INDEX.md`)](../../TASKS_INDEX.md) | [`task.toml`](task.toml) | [`instruction.md`](instruction.md) | [`solution/solve.sh`](solution/solve.sh) | [`tests/test.sh`](tests/test.sh) | [`tests/private/grader/run.py`](tests/private/grader/run.py)

---

## 1. Task Overview & Harbor Configuration

| Field | Value |
| :--- | :--- |
| **Task ID** | `case_21008` |
| **Source Silicon Repository** | `alexforencich/verilog-axi` (`repo_40`) |
| **Engineering Problem Type** | **New ISA & Subsystem Feature Implementation** (`PT2_New_Feature_ISA_Impl`) |
| **EDA Evaluation Stage** | **Stage 3: Static Timing (STA) & CDC/RDC Closure** (`stage3_sta_cdc`) |
| **Coupled Evaluation Gates** | Stage 1 (Functional RTL Sim) -> Stage 2 (Logic Synthesis & Gate-Level Verification) -> Stage 3 (OpenSTA Single-/Multi-Corner Setup/Hold WNS/TNS & CDC/RDC Closure) |
| **Primary Hardware Domain** | `HighSpeed_AXI_NIC_Cache_DMA` (HighSpeed_AXI_NIC_Cache_DMA) |
| **Multi-Domain Tags** | `HighSpeed_AXI_NIC_Cache_DMA` |
| **Editable Files (`allowed_edits`)** | [`code/axi_adapter.v`](environment/public/code/axi_adapter.v), [`code/axi_adapter_rd.v`](environment/public/code/axi_adapter_rd.v), [`code/axi_adapter_wr.v`](environment/public/code/axi_adapter_wr.v) (3 files, 1789 LOC) |
| **Public Subsystem Context** | 3 RTL files (1789 LOC) |
| **Base Container Image** | `siliconbench-eda:1.0` (`allow_internet = false`, `environment_mode = "separate"`) |
| **PDK / Environment Profile** | **Standard IEEE 1800-2017 SystemVerilog Dual-Simulator + Yosys Slang** |
| **Task-Customized Collateral?** | **No (Uses Shared Base Image)** — Pure RTL/protocol/synthesis check without external PDK Liberty files. |
| **Verifier Timeout & Seeds** | `600s` total (`300s`/seed) across deterministic seeds `[101, 202]` |

---

## 2. Problem Specification (`issue.md`)

# Parameterized AXI4 Width Adapter Multi-Ratio Burst Repacking, Splitting, and Synthesis Parity

`axi_adapter` (`axi_adapter_rd` and `axi_adapter_wr`) bridges an `S_DATA_WIDTH`-bit AXI4 slave interface to an `M_DATA_WIDTH`-bit AXI4 master interface across equal-width (`S_DATA_WIDTH == M_DATA_WIDTH`), upsize (`S_DATA_WIDTH < M_DATA_WIDTH`), and downsize (`S_DATA_WIDTH > M_DATA_WIDTH`) datapaths. Across multi-ratio instantiations (`32 <-> 128`, `64 <-> 256`, `64 <-> 64`), narrow/unaligned bursts, `FIXED`/`INCR`/`WRAP` burst types, and post-synthesis gate-level verification, the adapter exhibits elaboration width errors, malformed master burst headers, premature `WLAST`/`RLAST` framing, and sub-word lane corruption:

1. **Multi-Parameter Elaboration & RTL/Gate-Level Synthesis Parity (`axi_adapter`, `axi_adapter_rd`, `axi_adapter_wr`)**:
   - All `generate` branches (`S_DATA_WIDTH == M_DATA_WIDTH`, upsize, and downsize) must elaborate and synthesize cleanly without undeclared/zero-multiplier replications, out-of-bounds part-selects, width-truncation bugs, inferred latches, or combinational loops across arbitrary power-of-two width ratios, `FORWARD_ID` in `{0, 1}`, `CONVERT_BURST` in `{0, 1}`, `CONVERT_NARROW_BURST` in `{0, 1}`, and multi-bit `*USER_WIDTH >= 1` with `*USER_ENABLE` in `{0, 1}` (driving full-width zeros on disabled user ports and on `m_axi_awid`/`m_axi_arid` when `FORWARD_ID == 0`).

2. **AXI4 `FIXED`, `INCR`, and `WRAP` Slave Address Stepping & Byte-Lane Steering**:
   - Slave beat addresses must follow AXI4 rules across full-size, narrow (`size < $clog2(S_STRB_WIDTH)`), and unaligned start addresses: `FIXED` (`2'b00`) repeats the original start address on every beat, `INCR` (`2'b01`) advances to `(cur_addr + (1 << size)) & ~((1 << size) - 1)`, and `WRAP` (`2'b10`, `len` in `{1, 3, 7, 15}`) wraps within its `((len + 1) << size)` byte boundary, steering `WDATA`/`WSTRB` and `RDATA` to/from the addressed byte and sub-word lanes.

3. **Upsize Wide Burst Repacking vs. Narrow Passthrough (`S_DATA_WIDTH < M_DATA_WIDTH`)**:
   - Convert a slave request into a full-width (`M_BURST_SIZE = $clog2(M_STRB_WIDTH)`) master `INCR` (`2'b01`) burst aligned to `s_axi_a*addr & ~((1 << M_BURST_SIZE) - 1)` if and only if `CONVERT_BURST != 0`, `s_axi_a*cache[1] == 1'b1` (modifiable), `CONVERT_NARROW_BURST != 0 || s_axi_a*size == $clog2(S_STRB_WIDTH)`, and the slave burst is either `INCR` (`2'b01`) or a `WRAP` (`2'b10`) burst that starts on its wrap boundary or fits within a single master word (`m_axi_a*len = 0`). Otherwise, forward `addr`, `len`, `size`, and `burst` unchanged and steer each slave beat individually.
   - During repacked transfers, set `m_axi_a*len` to the exact number of master words spanned minus one, merge sub-word writes (`WDATA`/`WSTRB`) across master word boundaries without asserting `m_axi_wlast` before the final wide beat, and unpack each wide read beat across all covered slave beats before accepting the next master beat.

4. **Downsize Child Burst Splitting & Sticky Response Aggregation (`S_DATA_WIDTH > M_DATA_WIDTH`)**:
   - Pass narrow slave bursts with `s_axi_a*size <= $clog2(M_STRB_WIDTH)` through as a single master burst preserving `addr`, `len`, `size`, and `burst`.
   - Split wide slave bursts (`s_axi_a*size > $clog2(M_STRB_WIDTH)`) into full-width (`M_BURST_SIZE`) master `INCR` (`2'b01`) child bursts accounting for unaligned start offsets: issue one child burst per slave beat for `FIXED` (`2'b00`), split at any `WRAP` (`2'b10`) wrap boundary so master `INCR` bursts never cross it, and split long bursts so no child `m_axi_a*len` exceeds `8'hFF`.
   - Propagate the highest-severity response (`2'b11 > 2'b10 > 2'b01 > 2'b00`) across all master sub-beats forming a slave `R` beat (`s_axi_rresp`) and across all child `B` responses of a split write (`s_axi_bresp`, latching `s_axi_buser` from the first child response and updating it whenever a strictly higher-severity `m_axi_bresp` arrives), with cycle-accurate parity between RTL simulation and synthesized gate-level netlist simulation.

---

## 3. Build & Verification Instructions (`BUILD.md`)

The parameterized AXI4 width adapter RTL in `code/` comes from `alexforencich/verilog-axi` commit `516bd5dadc3365b7f9e225d2af8fe0b8d804fe53` (`code/COPYING`, MIT License).

Editable files:
- `code/axi_adapter.v`
- `code/axi_adapter_rd.v`
- `code/axi_adapter_wr.v`

Read-only support files (must remain unmodified):
- `code/COPYING`

For quick local multi-parameter elaboration, simulation, and latch-free synthesis checks from the workspace root:
```bash
# Icarus Verilog compilation check
iverilog -g2012 -o /tmp/adap_chk.vvp code/*.v

# Verilator lint/elaboration check (upsize & downsize)
verilator --lint-only -Wno-fatal -GS_DATA_WIDTH=32 -GM_DATA_WIDTH=128 -GFORWARD_ID=1 -GCONVERT_NARROW_BURST=1 --top-module axi_adapter code/*.v
verilator --lint-only -Wno-fatal -GS_DATA_WIDTH=128 -GM_DATA_WIDTH=32 -GFORWARD_ID=1 --top-module axi_adapter code/*.v

# Yosys elaboration and latch-free synthesis check
yosys -p "read_verilog code/*.v; chparam -set S_DATA_WIDTH 64 -set M_DATA_WIDTH 256 -set FORWARD_ID 1 -set CONVERT_NARROW_BURST 1 axi_adapter; hierarchy -check -top axi_adapter; proc; opt; check -assert; select -assert-none t:\$dlatch* t:\$_DLATCH* t:DLL_* t:DLH_*"
```

---

## 4. Reference Fix Inspection (Buggy Starter vs. Golden Solution Diff)

> Human reviewers can inspect the exact reference bug fix below, or browse full files in [`environment/public/`](environment/public/), [`solution/gold/`](solution/gold/), and [`solution/alternate_gold/`](solution/alternate_gold/).

<details open>
<summary><b>Click to expand/collapse Unified Diff (<code>environment/public/</code> vs. <code>solution/gold/</code>)</b></summary>

```diff
--- a/environment/public/code/axi_adapter_rd.v (Buggy Starter)
+++ b/solution/gold/code/axi_adapter_rd.v (Golden Reference)
@@ -29,35 +29,22 @@
 `default_nettype none
 
 /*
- * AXI4 width adapter
+ * AXI4 width adapter (read channel)
  */
 module axi_adapter_rd #
 (
-    // Width of address bus in bits
     parameter ADDR_WIDTH = 32,
-    // Width of input (slave) interface data bus in bits
     parameter S_DATA_WIDTH = 32,
-    // Width of input (slave) interface wstrb (width of data bus in words)
     parameter S_STRB_WIDTH = (S_DATA_WIDTH/8),
-    // Width of output (master) interface data bus in bits
     parameter M_DATA_WIDTH = 32,
-    // Width of output (master) interface wstrb (width of data bus in words)
     parameter M_STRB_WIDTH = (M_DATA_WIDTH/8),
-    // Width of ID signal
     parameter ID_WIDTH = 8,
-    // Propagate aruser signal
     parameter ARUSER_ENABLE = 0,
-    // Width of aruser signal
     parameter ARUSER_WIDTH = 1,
-    // Propagate ruser signal
     parameter RUSER_ENABLE = 0,
-    // Width of ruser signal
     parameter RUSER_WIDTH = 1,
-    // When adapting to a wider bus, re-pack full-width burst instead of passing through narrow burst if possible
     parameter CONVERT_BURST = 1,
-    // When adapting to a wider bus, re-pack all bursts instead of passing through narrow burst if possible
     parameter CONVERT_NARROW_BURST = 0,
-    // Forward ID through adapter
     parameter FORWARD_ID = 0
 )
 (
@@ -122,15 +109,15 @@
 parameter S_BURST_SIZE = $clog2(S_STRB_WIDTH);
 parameter M_BURST_SIZE = $clog2(M_STRB_WIDTH);
 
-// output bus is wider
 parameter EXPAND = M_STRB_WIDTH > S_STRB_WIDTH;
 parameter DATA_WIDTH = EXPAND ? M_DATA_WIDTH : S_DATA_WIDTH;
 parameter STRB_WIDTH = EXPAND ? M_STRB_WIDTH : S_STRB_WIDTH;
-// required number of segments in wider bus
 parameter SEGMENT_COUNT = EXPAND ? (M_STRB_WIDTH / S_STRB_WIDTH) : (S_STRB_WIDTH / M_STRB_WIDTH);
-// data width and keep width per segment
 parameter SEGMENT_DATA_WIDTH = DATA_WIDTH / SEGMENT_COUNT;
 parameter SEGMENT_STRB_WIDTH = STRB_WIDTH / SEGMENT_COUNT;
+
+localparam [2:0] S_BURST_SIZE_LP = S_BURST_SIZE[2:0];
+localparam [2:0] M_BURST_SIZE_LP = M_BURST_SIZE[2:0];
 
 // bus width assertions
 initial begin
@@ -166,10 +153,49 @@
     STATE_DATA_READ = 2'd2,
     STATE_DATA_SPLIT = 2'd3;
 
+function [ADDR_WIDTH-1:0] calc_wrap_mask;
+    input [2:0] sz;
+    input [7:0] len;
+    reg [ADDR_WIDTH-1:0] beat_bytes;
+    begin
+        beat_bytes = ({{(ADDR_WIDTH-1){1'b0}}, 1'b1} << sz);
+        case (len)
+            8'd1:    calc_wrap_mask = (beat_bytes << 1) - {{(ADDR_WIDTH-1){1'b0}}, 1'b1};
+            8'd3:    calc_wrap_mask = (beat_bytes << 2) - {{(ADDR_WIDTH-1){1'b0}}, 1'b1};
+            8'd7:    calc_wrap_mask = (beat_bytes << 3) - {{(ADDR_WIDTH-1){1'b0}}, 1'b1};
+            default: calc_wrap_mask = (beat_bytes << 4) - {{(ADDR_WIDTH-1){1'b0}}, 1'b1};
+        endcase
+    end
+endfunction
+
+function [ADDR_WIDTH-1:0] step_slave_addr;
+    input [ADDR_WIDTH-1:0] cur_addr;
+    input [ADDR_WIDTH-1:0] orig_addr;
+    input [ADDR_WIDTH-1:0] wmask;
+    input [2:0] sz;
+    input [1:0] btype;
+    reg [ADDR_WIDTH-1:0] beat_step;
+    reg [ADDR_WIDTH-1:0] align_mask;
+    reg [ADDR_WIDTH-1:0] inc_aligned;
+    begin
+        beat_step = ({{(ADDR_WIDTH-1){1'b0}}, 1'b1} << sz);
+        align_mask = ~(beat_step - {{(ADDR_WIDTH-1){1'b0}}, 1'b1});
+        inc_aligned = (cur_addr + beat_step) & align_mask;
+        case (btype)
+            2'b00:   step_slave_addr = orig_addr;
+            2'b10:   step_slave_addr = (cur_addr & ~wmask) | (inc_aligned & wmask);
+            default: step_slave_addr = inc_aligned;
+        endcase
+    end
+endfunction
+
 reg [1:0] state_reg = STATE_IDLE, state_next;
 
 reg [ID_WIDTH-1:0] id_reg = {ID_WIDTH{1'b0}}, id_next;
 reg [ADDR_WIDTH-1:0] addr_reg = {ADDR_WIDTH{1'b0}}, addr_next;
+reg [ADDR_WIDTH-1:0] orig_addr_reg = {ADDR_WIDTH{1'b0}}, orig_addr_next;
+reg [ADDR_WIDTH-1:0] wrap_mask_reg = {ADDR_WIDTH{1'b0}}, wrap_mask_next;
+reg [1:0] burst_type_reg = 2'd0, burst_type_next;
 reg [DATA_WIDTH-1:0] data_reg = {DATA_WIDTH{1'b0}}, data_next;
 reg [1:0] resp_reg = 2'd0, resp_next;
 reg [RUSER_WIDTH-1:0] ruser_reg = {RUSER_WIDTH{1'b0}}, ruser_next;
@@ -220,46 +246,48 @@
 assign m_axi_arvalid = m_axi_arvalid_reg;
 assign m_axi_rready = m_axi_rready_reg;
 
-always @* begin
-    state_next = STATE_IDLE;
-
-    id_next = id_reg;
-    addr_next = addr_reg;
-    data_next = data_reg;
-    resp_next = resp_reg;
-    ruser_next = ruser_reg;
-    burst_next = burst_reg;
-    burst_size_next = burst_size_reg;
-    master_burst_next = master_burst_reg;
-    master_burst_size_next = master_burst_size_reg;
-
-    s_axi_arready_next = 1'b0;
-    m_axi_arid_next = m_axi_arid_reg;
-    m_axi_araddr_next = m_axi_araddr_reg;
-    m_axi_arlen_next = m_axi_arlen_reg;
-    m_axi_arsize_next = m_axi_arsize_reg;
-    m_axi_arburst_next = m_axi_arburst_reg;
-    m_axi_arlock_next = m_axi_arlock_reg;
-    m_axi_arcache_next = m_axi_arcache_reg;
-    m_axi_arprot_next = m_axi_arprot_reg;
-    m_axi_arqos_next = m_axi_arqos_reg;
-    m_axi_arregion_next = m_axi_arregion_reg;
-    m_axi_aruser_next = m_axi_aruser_reg;
-    m_axi_arvalid_next = m_axi_arvalid_reg && !m_axi_arready;
-    m_axi_rready_next = 1'b0;
-
-    if (SEGMENT_COUNT == 1) begin
-        // master output is same width; direct transfer with no splitting/merging
+generate
+if (SEGMENT_COUNT == 1) begin : gen_passthrough
+    always @* begin
+        state_next = STATE_IDLE;
+
+        id_next = id_reg;
+        addr_next = addr_reg;
+        orig_addr_next = orig_addr_reg;
+        wrap_mask_next = wrap_mask_reg;
+        burst_type_next = burst_type_reg;
+        data_next = data_reg;
+        resp_next = resp_reg;
+        ruser_next = ruser_reg;
+        burst_next = burst_reg;
+        burst_size_next = burst_size_reg;
+        master_burst_next = master_burst_reg;
+        master_burst_size_next = master_burst_size_reg;
+
+        s_axi_arready_next = 1'b0;
+        m_axi_arid_next = m_axi_arid_reg;
+        m_axi_araddr_next = m_axi_araddr_reg;
+        m_axi_arlen_next = m_axi_arlen_reg;
+        m_axi_arsize_next = m_axi_arsize_reg;
+        m_axi_arburst_next = m_axi_arburst_reg;
+        m_axi_arlock_next = m_axi_arlock_reg;
+        m_axi_arcache_next = m_axi_arcache_reg;
+        m_axi_arprot_next = m_axi_arprot_reg;
+        m_axi_arqos_next = m_axi_arqos_reg;
+        m_axi_arregion_next = m_axi_arregion_reg;
+        m_axi_aruser_next = m_axi_aruser_reg;
+        m_axi_arvalid_next = m_axi_arvalid_reg && !m_axi_arready;
+        m_axi_rready_next = 1'b0;
+
         s_axi_rid_int = id_reg;
         s_axi_rdata_int = m_axi_rdata;
         s_axi_rresp_int = m_axi_rresp;
         s_axi_rlast_int = m_axi_rlast;
         s_axi_ruser_int = m_axi_ruser;
-        s_axi_rvalid_int = 0;
+        s_axi_rvalid_int = 1'b0;
 
         case (state_reg)
             STATE_IDLE: begin
-                // idle state; wait for new burst
                 s_axi_arready_next = !m_axi_arvalid;
 
                 if (s_axi_arready && s_axi_arvalid) begin
@@ -284,7 +312,6 @@
                 end
             end
             STATE_DATA: begin
-                // data state; transfer read data
                 m_axi_rready_next = s_axi_rready_int_early;
 
                 if (m_axi_rready && m_axi_rvalid) begin
@@ -295,7 +322,6 @@
                     s_axi_ruser_int = m_axi_ruser;
                     s_axi_rvalid_int = 1'b1;
                     if (m_axi_rlast) begin
-                        // last data word, return to idle
                         m_axi_rready_next = 1'b0;
                         s_axi_arready_next = !m_axi_arvalid;
                         state_next = STATE_IDLE;
@@ -306,48 +332,98 @@
                     state_next = STATE_DATA;
                 end
             end
+            default: begin
+                state_next = STATE_IDLE;
+            end
         endcase
-    end else if (EXPAND) begin
-        // master output is wider; split reads
+    end
+end else if (EXPAND) begin : gen_upsize
+    localparam [ADDR_WIDTH-1:0] M_OFFSET_MASK = ({{(ADDR_WIDTH-1){1'b0}}, 1'b1} << M_BURST_SIZE) - {{(ADDR_WIDTH-1){1'b0}}, 1'b1};
+
+    reg [ADDR_WIDTH-1:0] wmask_init;
+    reg [ADDR_WIDTH-1:0] s_align_mask_init;
+    reg [15:0] start_off_init;
+    reg [15:0] total_span_init;
+    reg [15:0] m_len_calc;
+    reg can_repack_wide;
+
+    always @* begin
+        state_next = STATE_IDLE;
+
+        id_next = id_reg;
+        addr_next = addr_reg;
+        orig_addr_next = orig_addr_reg;
+        wrap_mask_next = wrap_mask_reg;
+        burst_type_next = burst_type_reg;
+        data_next = data_reg;
+        resp_next = resp_reg;
+        ruser_next = ruser_reg;
+        burst_next = burst_reg;
+        burst_size_next = burst_size_reg;
+        master_burst_next = master_burst_reg;
+        master_burst_size_next = master_burst_size_reg;
+
+        s_axi_arready_next = 1'b0;
+        m_axi_arid_next = m_axi_arid_reg;
+        m_axi_araddr_next = m_axi_araddr_reg;
+        m_axi_arlen_next = m_axi_arlen_reg;
+        m_axi_arsize_next = m_axi_arsize_reg;
+        m_axi_arburst_next = m_axi_arburst_reg;
+        m_axi_arlock_next = m_axi_arlock_reg;
+        m_axi_arcache_next = m_axi_arcache_reg;
+        m_axi_arprot_next = m_axi_arprot_reg;
+        m_axi_arqos_next = m_axi_arqos_reg;
+        m_axi_arregion_next = m_axi_arregion_reg;
+        m_axi_aruser_next = m_axi_aruser_reg;
+        m_axi_arvalid_next = m_axi_arvalid_reg && !m_axi_arready;
+        m_axi_rready_next = 1'b0;
+
         s_axi_rid_int = id_reg;
-        s_axi_rdata_int = m_axi_rdata;
+        s_axi_rdata_int = m_axi_rdata[S_DATA_WIDTH-1:0];
         s_axi_rresp_int = m_axi_rresp;
         s_axi_rlast_int = m_axi_rlast;
         s_axi_ruser_int = m_axi_ruser;
-        s_axi_rvalid_int = 0;
+        s_axi_rvalid_int = 1'b0;
+
+        wmask_init = calc_wrap_mask(s_axi_arsize, s_axi_arlen);
+        s_align_mask_init = ~(({{(ADDR_WIDTH-1){1'b0}}, 1'b1} << s_axi_arsize) - {{(ADDR_WIDTH-1){1'b0}}, 1'b1});
+        start_off_init = {{(16-M_ADDR_BIT_OFFSET){1'b0}}, s_axi_araddr[M_ADDR_BIT_OFFSET-1:0]} & {{(16-M_ADDR_BIT_OFFSET){1'b1}}, s_align_mask_init[M_ADDR_BIT_OFFSET-1:0]};
+        total_span_init = start_off_init + ({8'd0, s_axi_arlen} << s_axi_arsize);
+        m_len_calc = total_span_init >> M_BURST_SIZE;
+
+        can_repack_wide = CONVERT_BURST && s_axi_arcache[1] && (CONVERT_NARROW_BURST || (s_axi_arsize == S_BURST_SIZE_LP)) &&
+                          ((s_axi_arburst == 2'b01) ||
+                           ((s_axi_arburst == 2'b10) && (((s_axi_araddr & wmask_init) == {ADDR_WIDTH{1'b0}}) || (wmask_init == M_OFFSET_MASK))));
 
         case (state_reg)
             STATE_IDLE: begin
-                // idle state; wait for new burst
                 s_axi_arready_next = !m_axi_arvalid;
 
                 if (s_axi_arready && s_axi_arvalid) begin
                     s_axi_arready_next = 1'b0;
                     id_next = s_axi_arid;
                     m_axi_arid_next = s_axi_arid;
-                    m_axi_araddr_next = s_axi_araddr;
                     addr_next = s_axi_araddr;
+                    orig_addr_next = s_axi_araddr;
+                    wrap_mask_next = wmask_init;
+                    burst_type_next = s_axi_arburst;
                     burst_next = s_axi_arlen;
                     burst_size_next = s_axi_arsize;
-                    if (CONVERT_BURST && s_axi_arcache[1] && (CONVERT_NARROW_BURST || s_axi_arsize == S_BURST_SIZE)) begin
-                        // split reads
-                        // require CONVERT_BURST and arcache[1] set
-                        master_burst_size_next = M_BURST_SIZE;
-                        if (CONVERT_NARROW_BURST) begin
-                            m_axi_arlen_next = (({{S_ADDR_BIT_OFFSET+1{1'b0}}, s_axi_arlen} << s_axi_arsize) + s_axi_araddr[M_ADDR_BIT_OFFSET-1:0]) >> M_BURST_SIZE;
-                        end else begin
-                            m_axi_arlen_next = ({1'b0, s_axi_arlen} + s_axi_araddr[M_ADDR_BIT_OFFSET-1:S_ADDR_BIT_OFFSET]) >> $clog2(SEGMENT_COUNT);
-                        end
-                        m_axi_arsize_next = M_BURST_SIZE;
+                    if (can_repack_wide) begin
+                        master_burst_size_next = M_BURST_SIZE_LP;
+                        m_axi_araddr_next = s_axi_araddr & ~M_OFFSET_MASK;
+                        m_axi_arlen_next = (s_axi_arburst == 2'b10 && wmask_init == M_OFFSET_MASK) ? 8'd0 : m_len_calc[7:0];
+                        m_axi_arsize_next = M_BURST_SIZE_LP;
+                        m_axi_arburst_next = 2'b01;
                         state_next = STATE_DATA_READ;
                     end else begin
-                        // output narrow burst
                         master_burst_size_next = s_axi_arsize;
+                        m_axi_araddr_next = s_axi_araddr;
                         m_axi_arlen_next = s_axi_arlen;
                         m_axi_arsize_next = s_axi_arsize;
+                        m_axi_arburst_next = s_axi_arburst;
                         state_next = STATE_DATA;
                     end
-                    m_axi_arburst_next = s_axi_arburst;
                     m_axi_arlock_next = s_axi_arlock;
                     m_axi_arcache_next = s_axi_arcache;
                     m_axi_arprot_next = s_axi_arprot;
@@ -365,12 +441,12 @@
 
                 if (m_axi_rready && m_axi_rvalid) begin
                     s_axi_rid_int = id_reg;
-                    s_axi_rdata_int = m_axi_rdata >> (addr_reg[M_ADDR_BIT_OFFSET-1:S_ADDR_BIT_OFFSET] * S_DATA_WIDTH);
+                    s_axi_rdata_int = m_axi_rdata[addr_reg[M_ADDR_BIT_OFFSET-1:S_ADDR_BIT_OFFSET]*S_DATA_WIDTH +: S_DATA_WIDTH];
                     s_axi_rresp_int = m_axi_rresp;
                     s_axi_rlast_int = m_axi_rlast;
                     s_axi_ruser_int = m_axi_ruser;
                     s_axi_rvalid_int = 1'b1;
-                    addr_next = addr_reg + (1 << burst_size_reg);
+                    addr_next = step_slave_addr(addr_reg, orig_addr_reg, wrap_mask_reg, burst_size_reg, burst_type_reg);
                     if (m_axi_rlast) begin
                         m_axi_rready_next = 1'b0;
                         s_axi_arready_next = !m_axi_arvalid;
@@ -390,19 +466,19 @@
                     data_next = m_axi_rdata;
                     resp_next = m_axi_rresp;
                     ruser_next = m_axi_ruser;
-                    s_axi_rdata_int = m_axi_rdata >> (addr_reg[M_ADDR_BIT_OFFSET-1:S_ADDR_BIT_OFFSET] * S_DATA_WIDTH);
+                    s_axi_rdata_int = m_axi_rdata[addr_reg[M_ADDR_BIT_OFFSET-1:S_ADDR_BIT_OFFSET]*S_DATA_WIDTH +: S_DATA_WIDTH];
                     s_axi_rresp_int = m_axi_rresp;
                     s_axi_rlast_int = 1'b0;
                     s_axi_ruser_int = m_axi_ruser;
                     s_axi_rvalid_int = 1'b1;
-                    burst_next = burst_reg - 1;
-                    addr_next = addr_reg + (1 << burst_size_reg);
-                    if (burst_reg == 0) begin
+                    burst_next = burst_reg - 8'd1;
+                    addr_next = step_slave_addr(addr_reg, orig_addr_reg, wrap_mask_reg, burst_size_reg, burst_type_reg);
+                    if (burst_reg == 8'd0) begin
                         m_axi_rready_next = 1'b0;
                         s_axi_arready_next = !m_axi_arvalid;
                         s_axi_rlast_int = 1'b1;
                         state_next = STATE_IDLE;
-                    end else if (addr_next[master_burst_size_reg] != addr_reg[master_burst_size_reg]) begin
+                    end else if (addr_next[M_ADDR_BIT_OFFSET] != addr_reg[M_ADDR_BIT_OFFSET]) begin
                         state_next = STATE_DATA_READ;
                     end else begin
                         m_axi_rready_next = 1'b0;
@@ -417,18 +493,18 @@
 
                 if (s_axi_rready_int_reg) begin
                     s_axi_rid_int = id_reg;
-                    s_axi_rdata_int = data_reg >> (addr_reg[M_ADDR_BIT_OFFSET-1:S_ADDR_BIT_OFFSET] * S_DATA_WIDTH);
+                    s_axi_rdata_int = data_reg[addr_reg[M_ADDR_BIT_OFFSET-1:S_ADDR_BIT_OFFSET]*S_DATA_WIDTH +: S_DATA_WIDTH];
                     s_axi_rresp_int = resp_reg;
                     s_axi_rlast_int = 1'b0;
                     s_axi_ruser_int = ruser_reg;
                     s_axi_rvalid_int = 1'b1;
-                    burst_next = burst_reg - 1;
-                    addr_next = addr_reg + (1 << burst_size_reg);
-                    if (burst_reg == 0) begin
+                    burst_next = burst_reg - 8'd1;
+                    addr_next = step_slave_addr(addr_reg, orig_addr_reg, wrap_mask_reg, burst_size_reg, burst_type_reg);
+                    if (burst_reg == 8'd0) begin
                         s_axi_arready_next = !m_axi_arvalid;
                         s_axi_rlast_int = 1'b1;
                         state_next = STATE_IDLE;
-                    end else if (addr_next[master_burst_size_reg] != addr_reg[master_burst_size_reg]) begin
+                    end else if (addr_next[M_ADDR_BIT_OFFSET] != addr_reg[M_ADDR_BIT_OFFSET]) begin
                         m_axi_rready_next = s_axi_rready_int_early;
                         state_next = STATE_DATA_READ;
                     end else begin
@@ -439,20 +515,88 @@
                 end
             end
         endcase
-    end else begin
-        // master output is narrower; merge reads and possibly split burst
+    end
+end else begin : gen_downsize
+    function [7:0] calc_downsize_child_len;
+        input [ADDR_WIDTH-1:0] start_addr;
+        input [ADDR_WIDTH-1:0] wmask;
+        input [7:0] rem_slave_len;
+        input [2:0] s_sz;
+        input [1:0] btype;
+        reg [2:0] shift;
+        reg [ADDR_WIDTH-1:0] s_beat_mask;
+        reg [ADDR_WIDTH-1:0] first_extra_full;
+        reg [ADDR_WIDTH-1:0] wrap_rem_full;
+        reg [7:0] max_s_len;
+        reg [7:0] eff_s_len;
+        begin
+            shift = s_sz - M_BURST_SIZE_LP;
+            s_beat_mask = ({{(ADDR_WIDTH-1){1'b0}}, 1'b1} << s_sz) - {{(ADDR_WIDTH-1){1'b0}}, 1'b1};
+            first_extra_full = (~start_addr & s_beat_mask) >> M_BURST_SIZE;
+            wrap_rem_full = (~start_addr & wmask) >> s_sz;
+            max_s_len = 8'hFF >> shift;
+            if (btype == 2'b00) begin
+                eff_s_len = 8'd0;
+            end else if (btype == 2'b10) begin
+                eff_s_len = (rem_slave_len <= wrap_rem_full[7:0]) ? rem_slave_len : wrap_rem_full[7:0];
+            end else begin
+                eff_s_len = (rem_slave_len <= max_s_len) ? rem_slave_len : max_s_len;
+            end
+            calc_downsize_child_len = (eff_s_len << shift) | first_extra_full[7:0];
+        end
+    endfunction
+
+    reg [ADDR_WIDTH-1:0] wmask_init;
+    reg [ADDR_WIDTH-1:0] sub_step_aligned;
+    reg slave_beat_done;
+
+    always @* begin
+        state_next = STATE_IDLE;
+
+        id_next = id_reg;
+        addr_next = addr_reg;
+        orig_addr_next = orig_addr_reg;
+        wrap_mask_next = wrap_mask_reg;
+        burst_type_next = burst_type_reg;
+        data_next = data_reg;
+        resp_next = resp_reg;
+        ruser_next = ruser_reg;
+        burst_next = burst_reg;
+        burst_size_next = burst_size_reg;
+        master_burst_next = master_burst_reg;
+        master_burst_size_next = master_burst_size_reg;
+
+        s_axi_arready_next = 1'b0;
+        m_axi_arid_next = m_axi_arid_reg;
+        m_axi_araddr_next = m_axi_araddr_reg;
+        m_axi_arlen_next = m_axi_arlen_reg;
+        m_axi_arsize_next = m_axi_arsize_reg;
+        m_axi_arburst_next = m_axi_arburst_reg;
+        m_axi_arlock_next = m_axi_arlock_reg;
+        m_axi_arcache_next = m_axi_arcache_reg;
+        m_axi_arprot_next = m_axi_arprot_reg;
+        m_axi_arqos_next = m_axi_arqos_reg;
+        m_axi_arregion_next = m_axi_arregion_reg;
+        m_axi_aruser_next = m_axi_aruser_reg;
+        m_axi_arvalid_next = m_axi_arvalid_reg && !m_axi_arready;
+        m_axi_rready_next = 1'b0;
+
         s_axi_rid_int = id_reg;
         s_axi_rdata_int = data_reg;
         s_axi_rresp_int = resp_reg;
         s_axi_rlast_int = 1'b0;
         s_axi_ruser_int = m_axi_ruser;
-        s_axi_rvalid_int = 0;
+        s_axi_rvalid_int = 1'b0;
+
+        wmask_init = calc_wrap_mask(s_axi_arsize, s_axi_arlen);
+        sub_step_aligned = (addr_reg + ({{(ADDR_WIDTH-1){1'b0}}, 1'b1} << master_burst_size_reg)) &
+                           ~(({{(ADDR_WIDTH-1){1'b0}}, 1'b1} << master_burst_size_reg) - {{(ADDR_WIDTH-1){1'b0}}, 1'b1});
+        slave_beat_done = (burst_size_reg <= M_BURST_SIZE_LP) || (sub_step_aligned[{2'b00, burst_size_reg}] != addr_reg[{2'b00, burst_size_reg}]);
 
         case (state_reg)
             STATE_IDLE: begin
-                // idle state; wait for new burst
                 s_axi_arready_next = !m_axi_arvalid;
-
+                data_next = {DATA_WIDTH{1'b0}};
                 resp_next = 2'd0;
 
                 if (s_axi_arready && s_axi_arvalid) begin
@@ -461,27 +605,24 @@
                     m_axi_arid_next = s_axi_arid;
                     m_axi_araddr_next = s_axi_araddr;
                     addr_next = s_axi_araddr;
+                    orig_addr_next = s_axi_araddr;
+                    wrap_mask_next = wmask_init;
+                    burst_type_next = s_axi_arburst;
                     burst_next = s_axi_arlen;
                     burst_size_next = s_axi_arsize;
-                    if (s_axi_arsize > M_BURST_SIZE) begin
-                        // need to adjust burst size
-                        if (s_axi_arlen >> (8+M_BURST_SIZE-s_axi_arsize) != 0) begin
-                            // limit burst length to max
-                            master_burst_next = (8'd255 << (s_axi_arsize-M_BURST_SIZE)) | ((~s_axi_araddr & (8'hff >> (8-s_axi_arsize))) >> M_BURST_SIZE);
-                        end else begin
-                            master_burst_next = (s_axi_arlen << (s_axi_arsize-M_BURST_SIZE)) | ((~s_axi_araddr & (8'hff >> (8-s_axi_arsize))) >> M_BURST_SIZE);
-                        end
-                        master_burst_size_next = M_BURST_SIZE;
+                    if (s_axi_arsize > M_BURST_SIZE_LP) begin
+                        master_burst_next = calc_downsize_child_len(s_axi_araddr, wmask_init, s_axi_arlen, s_axi_arsize, s_axi_arburst);
+                        master_burst_size_next = M_BURST_SIZE_LP;
                         m_axi_arlen_next = master_burst_next;
-                        m_axi_arsize_next = master_burst_size_next;
+                        m_axi_arsize_next = M_BURST_SIZE_LP;
+                        m_axi_arburst_next = 2'b01;
                     end else begin
-                        // pass through narrow (enough) burst
                         master_burst_next = s_axi_arlen;
                         master_burst_size_next = s_axi_arsize;
                         m_axi_arlen_next = s_axi_arlen;
                         m_axi_arsize_next = s_axi_arsize;
-                    end
-                    m_axi_arburst_next = s_axi_arburst;
+                        m_axi_arburst_next = s_axi_arburst;
+                    end
                     m_axi_arlock_next = s_axi_arlock;
                     m_axi_arcache_next = s_axi_arcache;
                     m_axi_arprot_next = s_axi_arprot;
@@ -500,7 +641,7 @@
 
                 if (m_axi_rready && m_axi_rvalid) begin
                     data_next[addr_reg[S_ADDR_BIT_OFFSET-1:M_ADDR_BIT_OFFSET]*SEGMENT_DATA_WIDTH +: SEGMENT_DATA_WIDTH] = m_axi_rdata;
-                    if (m_axi_rresp) begin
+                    if (m_axi_rresp > resp_reg) begin
                         resp_next = m_axi_rresp;
                     end
                     s_axi_rid_int = id_reg;
@@ -509,31 +650,38 @@
                     s_axi_rlast_int = 1'b0;
                     s_axi_ruser_int = m_axi_ruser;
                     s_axi_rvalid_int = 1'b0;
-                    master_burst_next = master_burst_reg - 1;
-                    addr_next = (addr_reg + (1 << master_burst_size_reg)) & ({ADDR_WIDTH{1'b1}} << master_burst_size_reg);
+                    master_burst_next = master_burst_reg - 8'd1;
+
+                    if (burst_size_reg <= M_BURST_SIZE_LP) begin
+                        addr_next = step_slave_addr(addr_reg, orig_addr_reg, wrap_mask_reg, burst_size_reg, burst_type_reg);
+                    end else if (slave_beat_done) begin
+                        case (burst_type_reg)
+                            2'b00:   addr_next = orig_addr_reg;
+                            2'b10:   addr_next = (addr_reg & ~wrap_mask_reg) | (sub_step_aligned & wrap_mask_reg);
+                            default: addr_next = sub_step_aligned;
+                        endcase
+                    end else begin
+                        addr_next = sub_
```

</details>

---

## 5. Harbor Package File Inventory & Provenance

### Public Workspace (`environment/public/`)
- [`environment/public/BUILD.md`](environment/public/BUILD.md) *(Read-Only Context)*
- [`environment/public/code/COPYING`](environment/public/code/COPYING) *(Read-Only Context)*
- [`environment/public/code/axi_adapter.v`](environment/public/code/axi_adapter.v) **(Editable)**
- [`environment/public/code/axi_adapter_rd.v`](environment/public/code/axi_adapter_rd.v) **(Editable)**
- [`environment/public/code/axi_adapter_wr.v`](environment/public/code/axi_adapter_wr.v) **(Editable)**
- [`environment/public/issue.md`](environment/public/issue.md) *(Read-Only Context)*

### Reference Solutions & Isolated Verifier (`solution/` & `tests/`)
- [`solution/solve.sh`](solution/solve.sh) — Harbor oracle script
- [`solution/gold/`](solution/gold/) — Primary golden reference solution
- [`solution/alternate_gold/`](solution/alternate_gold/) — Structurally distinct secondary reference solution
- [`tests/test.sh`](tests/test.sh) — Isolated Harbor verifier entrypoint
- [`tests/private/policy_filter.py`](tests/private/policy_filter.py) — Pre-grader airlock & anti-cheat policy screen
- [`tests/private/grader/run.py`](tests/private/grader/run.py) — Deterministic front-to-back EDA verifier

### Upstream Provenance (`SOURCE.md`)

