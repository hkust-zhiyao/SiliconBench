# `case_21007`: AXI4 Crossbar QoS-Aware Arbitration, Starvation-Bounded Ageing, and High-QoS Reserve Admission

[Back to Benchmark Root (`README.md`)](../../README.md) | [Full 94-Task Catalog (`TASKS_INDEX.md`)](../../TASKS_INDEX.md) | [`task.toml`](task.toml) | [`instruction.md`](instruction.md) | [`solution/solve.sh`](solution/solve.sh) | [`tests/test.sh`](tests/test.sh) | [`tests/private/grader/run.py`](tests/private/grader/run.py)

---

## 1. Task Overview & Harbor Configuration

| Field | Value |
| :--- | :--- |
| **Task ID** | `case_21007` |
| **Source Silicon Repository** | `alexforencich/verilog-axi` (`repo_40`) |
| **Engineering Problem Type** | **New ISA & Subsystem Feature Implementation** (`PT2_New_Feature_ISA_Impl`) |
| **EDA Evaluation Stage** | **Stage 3: Static Timing (STA) & CDC/RDC Closure** (`stage3_sta_cdc`) |
| **Coupled Evaluation Gates** | Stage 1 (Functional RTL Sim) -> Stage 2 (Logic Synthesis & Gate-Level Verification) -> Stage 3 (OpenSTA Single-/Multi-Corner Setup/Hold WNS/TNS & CDC/RDC Closure) |
| **Primary Hardware Domain** | `HighSpeed_AXI_NIC_Cache_DMA` (HighSpeed_AXI_NIC_Cache_DMA) |
| **Multi-Domain Tags** | `HighSpeed_AXI_NIC_Cache_DMA` |
| **Editable Files (`allowed_edits`)** | [`code/axi_crossbar.v`](environment/public/code/axi_crossbar.v), [`code/axi_crossbar_addr.v`](environment/public/code/axi_crossbar_addr.v), [`code/axi_crossbar_rd.v`](environment/public/code/axi_crossbar_rd.v), [`code/axi_crossbar_wr.v`](environment/public/code/axi_crossbar_wr.v), [`code/arbiter.v`](environment/public/code/arbiter.v) (5 files, 2247 LOC) |
| **Public Subsystem Context** | 8 RTL files (3560 LOC) |
| **Base Container Image** | `siliconbench-eda:1.0` (`allow_internet = false`, `environment_mode = "separate"`) |
| **PDK / Environment Profile** | **IHP SG13G2 130nm Open PDK + RM_IHPSG13_1P Hard-SRAM Macros** |
| **Task-Customized Collateral?** | **Yes (Task-Bundled Collateral)** — Includes task-bundled IHP SG13G2 standard-cell LEF/Liberty and single-port hard-SRAM macro LEF/Liberty/Verilog models. |
| **Verifier Timeout & Seeds** | `600s` total (`300s`/seed) across deterministic seeds `[101, 202]` |

---

## 2. Problem Specification (`issue.md`)

# Add QoS-aware arbitration, starvation-bounded ageing, and high-QoS reserve admission to the AXI4 crossbar

`axi_crossbar` currently accepts 4-bit `s_axi_awqos` and `s_axi_arqos` signals on its slave ports (`0 .. S_COUNT-1`), but ignores them during master-port contention and slave-port admission, leaves the top-level `M_*_REG_TYPE` slice parameters disconnected from `axi_crossbar_wr` / `axi_crossbar_rd`, and allows decode-error (`DECERR`) completions to underflow slave in-flight tracking or bypass earlier in-flight transactions sharing the same AXI ID.

Implement AMBA AXI4 QoS-aware scheduling, bounded ageing promotion, and high-QoS reserve admission across `code/axi_crossbar.v`, `code/axi_crossbar_addr.v`, `code/axi_crossbar_rd.v`, `code/axi_crossbar_wr.v`, and `code/arbiter.v`:

1. **Effective QoS Arbitration & Per-Level Round-Robin Fairness**: On each master output interface (`0 .. M_COUNT-1`) for both read (`AR`) and write (`AW`/`W`) channels, grant access to the contending slave port with the highest effective 4-bit QoS (`4'h0` lowest, `4'hF` highest). Break ties among contenders sharing the same effective QoS level using fair round-robin per effective QoS level so that grants won at higher effective QoS levels do not reset or bias the round-robin turn order of lower-QoS levels. Always forward the originating slave port's unmodified `s_axi_awqos` / `s_axi_arqos` value onto `m_axi_awqos` / `m_axi_arqos`, maintain strict `AW`/`W` grant order alignment across multi-beat bursts and downstream stalls, forward all `M_*_REG_TYPE` parameters from `axi_crossbar` to its read/write channel instances, and preserve AXI4 valid/payload stability whenever a valid channel is stalled.
2. **Starvation-Bounded Ageing Promotion (`AGEING_LIMIT`)**: When `AGEING_LIMIT == 0`, disable ageing promotion (strict effective QoS priority). When `AGEING_LIMIT > 0`, track starvation independently per master output interface on both read and write channels: if a slave port has a decoded request pending for a master output interface and remains ungranted while `AGEING_LIMIT` arbitration grants on that same master output interface are awarded to other ports, promote that contender's effective arbitration QoS on that master output interface to `4'hF` until its pending request is granted and acknowledged (retaining accumulated wait count across multi-beat `W` bursts or `M_ISSUE` stalls, and clearing it once granted or when no request is pending).
3. **High-QoS Reserve Admission (`HIGH_QOS_MIN`, `QOS_RESERVE`) & Decode-Error Ordering**: On each slave input interface (`0 .. S_COUNT-1`), reserve `QOS_RESERVE` in-flight slots below `S_ACCEPT` (`0 <= QOS_RESERVE < S_ACCEPT`) for high-QoS requests (`qos >= HIGH_QOS_MIN`). Admit normal-QoS requests (`qos < HIGH_QOS_MIN`) only when the port's effective in-flight count (accounting for any same-cycle transaction completion) is strictly less than `S_ACCEPT - QOS_RESERVE`, while admitting high-QoS requests (`qos >= HIGH_QOS_MIN`) whenever the effective in-flight count is strictly less than `S_ACCEPT`. Ensure unmapped, disconnected (`M_CONNECT_*`), or security-rejected (`M_SECURE`) transactions returning `DECERR` (`2'b11`) properly increment/decrement slave in-flight counters without underflow and obey `S_THREADS` same-ID ordering with respect to in-flight mapped transactions.

---

## 3. Build & Verification Instructions (`BUILD.md`)

The AXI4 crossbar RTL in `code/` comes from `alexforencich/verilog-axi` commit `516bd5dadc3365b7f9e225d2af8fe0b8d804fe53` (`code/COPYING`, MIT License), with `AGEING_LIMIT`, `HIGH_QOS_MIN`, and `QOS_RESERVE` parameter stubs exposed on `axi_crossbar`, `axi_crossbar_wr`, `axi_crossbar_rd`, and `axi_crossbar_addr`.

Editable files:
- `code/axi_crossbar.v`
- `code/axi_crossbar_addr.v`
- `code/axi_crossbar_rd.v`
- `code/axi_crossbar_wr.v`
- `code/arbiter.v`

Read-only support files (must remain unmodified):
- `code/axi_register_rd.v`
- `code/axi_register_wr.v`
- `code/priority_encoder.v`
- `code/COPYING`

For quick local elaboration, simulation, and latch-free synthesis checks from the workspace root:
```bash
# Icarus Verilog compilation check
iverilog -g2012 -o /tmp/xbar_chk.vvp code/*.v

# Verilator lint/elaboration check
verilator --lint-only -Wno-fatal --top-module axi_crossbar code/*.v

# Yosys elaboration and latch-free check
yosys -p "read_verilog code/*.v; chparam -set S_COUNT 4 -set M_COUNT 2 -set AGEING_LIMIT 4 -set HIGH_QOS_MIN 8 -set QOS_RESERVE 2 axi_crossbar; hierarchy -check -top axi_crossbar; proc; opt; check -assert; select -assert-none t:\$dlatch* t:\$_DLATCH* t:DLL_* t:DLH_*"
```

---

## 4. Reference Fix Inspection (Buggy Starter vs. Golden Solution Diff)

> Human reviewers can inspect the exact reference bug fix below, or browse full files in [`environment/public/`](environment/public/), [`solution/gold/`](solution/gold/), and [`solution/alternate_gold/`](solution/alternate_gold/).

<details open>
<summary><b>Click to expand/collapse Unified Diff (<code>environment/public/</code> vs. <code>solution/gold/</code>)</b></summary>

```diff
--- a/environment/public/code/axi_crossbar.v (Buggy Starter)
+++ b/solution/gold/code/axi_crossbar.v (Golden Reference)
@@ -258,7 +258,10 @@
     .M_SECURE(M_SECURE),
     .S_AW_REG_TYPE(S_AW_REG_TYPE),
     .S_W_REG_TYPE (S_W_REG_TYPE),
-    .S_B_REG_TYPE (S_B_REG_TYPE)
+    .S_B_REG_TYPE (S_B_REG_TYPE),
+    .M_AW_REG_TYPE(M_AW_REG_TYPE),
+    .M_W_REG_TYPE (M_W_REG_TYPE),
+    .M_B_REG_TYPE (M_B_REG_TYPE)
 )
 axi_crossbar_wr_inst (
     .clk(clk),
@@ -344,7 +347,9 @@
     .M_ISSUE(M_ISSUE),
     .M_SECURE(M_SECURE),
     .S_AR_REG_TYPE(S_AR_REG_TYPE),
-    .S_R_REG_TYPE (S_R_REG_TYPE)
+    .S_R_REG_TYPE (S_R_REG_TYPE),
+    .M_AR_REG_TYPE(M_AR_REG_TYPE),
+    .M_R_REG_TYPE (M_R_REG_TYPE)
 )
 axi_crossbar_rd_inst (
     .clk(clk),

--- a/environment/public/code/axi_crossbar_addr.v (Buggy Starter)
+++ b/solution/gold/code/axi_crossbar_addr.v (Golden Reference)
@@ -120,6 +120,8 @@
 parameter CL_S_INT_THREADS = $clog2(S_INT_THREADS);
 parameter CL_S_ACCEPT = $clog2(S_ACCEPT);
 
+localparam [31:0] NORM_ACCEPT = (S_ACCEPT > QOS_RESERVE) ? (S_ACCEPT - QOS_RESERVE) : 32'd0;
+
 // default address computation
 function [M_COUNT*M_REGIONS*ADDR_WIDTH-1:0] calcBaseAddrs(input [31:0] dummy);
     integer i;
@@ -176,61 +178,6 @@
             $finish;
         end
     end
-
-    $display("Addressing configuration for axi_crossbar_addr instance %m");
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
-            end
-        end
-    end
 end
 
 localparam [2:0]
@@ -261,17 +208,38 @@
 assign m_rc_decerr = m_decerr_reg;
 assign m_rc_valid = m_rc_valid_reg;
 
-reg match;
+reg dec_match;
+reg [CL_M_COUNT-1:0] dec_m_select;
+reg [3:0] dec_aregion;
+
+always @* begin
+    dec_match = 1'b0;
+    dec_m_select = {CL_M_COUNT{1'b0}};
+    dec_aregion = 4'd0;
+    for (i = 0; i < M_COUNT; i = i + 1) begin
+        for (j = 0; j < M_REGIONS; j = j + 1) begin
+            if (M_ADDR_WIDTH[(i*M_REGIONS+j)*32 +: 32] && (!M_SECURE[i] || !s_axi_aprot[1]) && (M_CONNECT & (1 << (S+i*S_COUNT))) && (s_axi_aaddr >> M_ADDR_WIDTH[(i*M_REGIONS+j)*32 +: 32]) == (M_BASE_ADDR_INT[(i*M_REGIONS+j)*ADDR_WIDTH +: ADDR_WIDTH] >> M_ADDR_WIDTH[(i*M_REGIONS+j)*32 +: 32])) begin
+                dec_m_select = i[CL_M_COUNT-1:0];
+                dec_aregion = j[3:0];
+                dec_match = 1'b1;
+            end
+        end
+    end
+end
+
 reg trans_start;
-reg trans_complete;
+wire trans_complete = s_cpl_valid;
 
 reg [$clog2(S_ACCEPT+1)-1:0] trans_count_reg = 0;
-wire trans_limit = trans_count_reg >= S_ACCEPT && !trans_complete;
+wire [31:0] eff_trans_count = (trans_complete && (trans_count_reg != 0)) ? (trans_count_reg - 1'b1) : trans_count_reg;
+wire is_high_qos = (s_axi_aqos >= HIGH_QOS_MIN);
+wire trans_limit = is_high_qos ? (eff_trans_count >= S_ACCEPT) : (eff_trans_count >= NORM_ACCEPT);
 
 // transfer ID thread tracking
 reg [ID_WIDTH-1:0] thread_id_reg[S_INT_THREADS-1:0];
 reg [CL_M_COUNT-1:0] thread_m_reg[S_INT_THREADS-1:0];
 reg [3:0] thread_region_reg[S_INT_THREADS-1:0];
+reg thread_decerr_reg[S_INT_THREADS-1:0];
 reg [$clog2(S_ACCEPT+1)-1:0] thread_count_reg[S_INT_THREADS-1:0];
 
 wire [S_INT_THREADS-1:0] thread_active;
@@ -284,14 +252,19 @@
 generate
     genvar n;
 
-    for (n = 0; n < S_INT_THREADS; n = n + 1) begin
+    for (n = 0; n < S_INT_THREADS; n = n + 1) begin : threads
         initial begin
-            thread_count_reg[n] <= 0;
+            thread_count_reg[n] = 0;
+            thread_decerr_reg[n] = 1'b0;
         end
 
         assign thread_active[n] = thread_count_reg[n] != 0;
         assign thread_match[n] = thread_active[n] && thread_id_reg[n] == s_axi_aid;
-        assign thread_match_dest[n] = thread_match[n] && thread_m_reg[n] == m_select_next && (M_REGIONS < 2 || thread_region_reg[n] == m_axi_aregion_next);
+        assign thread_match_dest[n] = thread_match[n] && (
+            dec_match
+            ? (!thread_decerr_reg[n] && thread_m_reg[n] == dec_m_select && (M_REGIONS < 2 || thread_region_reg[n] == dec_aregion))
+            : thread_decerr_reg[n]
+        );
         assign thread_cpl_match[n] = thread_active[n] && thread_id_reg[n] == s_cpl_id;
         assign thread_trans_start[n] = (thread_match[n] || (!thread_active[n] && !thread_match && !(thread_trans_start & ({S_INT_THREADS{1'b1}} >> (S_INT_THREADS-n))))) && trans_start;
         assign thread_trans_complete[n] = thread_cpl_match[n] && trans_complete;
@@ -299,6 +272,7 @@
         always @(posedge clk) begin
             if (rst) begin
                 thread_count_reg[n] <= 0;
+                thread_decerr_reg[n] <= 1'b0;
             end else begin
                 if (thread_trans_start[n] && !thread_trans_complete[n]) begin
                     thread_count_reg[n] <= thread_count_reg[n] + 1;
@@ -309,8 +283,9 @@
 
             if (thread_trans_start[n]) begin
                 thread_id_reg[n] <= s_axi_aid;
-                thread_m_reg[n] <= m_select_next;
-                thread_region_reg[n] <= m_axi_aregion_next;
+                thread_m_reg[n] <= dec_m_select;
+                thread_region_reg[n] <= dec_aregion;
+                thread_decerr_reg[n] <= !dec_match;
             end
         end
     end
@@ -319,9 +294,7 @@
 always @* begin
     state_next = STATE_IDLE;
 
-    match = 1'b0;
     trans_start = 1'b0;
-    trans_complete = 1'b0;
 
     s_axi_aready_next = 1'b0;
 
@@ -334,42 +307,27 @@
 
     case (state_reg)
         STATE_IDLE: begin
-            // idle state, store values
             s_axi_aready_next = 1'b0;
 
             if (s_axi_avalid && !s_axi_aready) begin
-                match = 1'b0;
-                for (i = 0; i < M_COUNT; i = i + 1) begin
-                    for (j = 0; j < M_REGIONS; j = j + 1) begin
-                        if (M_ADDR_WIDTH[(i*M_REGIONS+j)*32 +: 32] && (!M_SECURE[i] || !s_axi_aprot[1]) && (M_CONNECT & (1 << (S+i*S_COUNT))) && (s_axi_aaddr >> M_ADDR_WIDTH[(i*M_REGIONS+j)*32 +: 32]) == (M_BASE_ADDR_INT[(i*M_REGIONS+j)*ADDR_WIDTH +: ADDR_WIDTH] >> M_ADDR_WIDTH[(i*M_REGIONS+j)*32 +: 32])) begin
-                            m_select_next = i;
-                            m_axi_aregion_next = j;
-                            match = 1'b1;
-                        end
-                    end
-                end
-
-                if (match) begin
-                    // address decode successful
-                    if (!trans_limit && (thread_match_dest || (!(&thread_active) && !thread_match))) begin
-                        // transaction limit not reached
+                if (!trans_limit && (|thread_match_dest || (!(&thread_active) && !(|thread_match)))) begin
+                    m_select_next = dec_m_select;
+                    m_axi_aregion_next = dec_aregion;
+                    if (dec_match) begin
                         m_axi_avalid_next = 1'b1;
                         m_decerr_next = 1'b0;
                         m_wc_valid_next = WC_OUTPUT;
                         m_rc_valid_next = 1'b0;
-                        trans_start = 1'b1;
-                        state_next = STATE_DECODE;
                     end else begin
-                        // transaction limit reached; block in idle
-                        state_next = STATE_IDLE;
+                        m_axi_avalid_next = 1'b0;
+                        m_decerr_next = 1'b1;
+                        m_wc_valid_next = WC_OUTPUT;
+                        m_rc_valid_next = 1'b1;
                     end
+                    trans_start = 1'b1;
+                    state_next = STATE_DECODE;
                 end else begin
-                    // decode error
-                    m_axi_avalid_next = 1'b0;
-                    m_decerr_next = 1'b1;
-                    m_wc_valid_next = WC_OUTPUT;
-                    m_rc_valid_next = 1'b1;
-                    state_next = STATE_DECODE;
+                    state_next = STATE_IDLE;
                 end
             end else begin
                 state_next = STATE_IDLE;
@@ -384,9 +342,6 @@
             end
         end
     endcase
-
-    // manage completions
-    trans_complete = s_cpl_valid;
 end
 
 always @(posedge clk) begin

--- a/environment/public/code/axi_crossbar_rd.v (Buggy Starter)
+++ b/solution/gold/code/axi_crossbar_rd.v (Golden Reference)
@@ -341,13 +341,17 @@
             .ARB_TYPE_ROUND_ROBIN(1),
             .ARB_BLOCK(1),
             .ARB_BLOCK_ACK(1),
-            .ARB_LSB_HIGH_PRIORITY(1)
+            .ARB_LSB_HIGH_PRIORITY(1),
+            .QOS_ENABLE(0),
+            .AGEING_LIMIT(0)
         )
         r_arb_inst (
             .clk(clk),
             .rst(rst),
             .request(r_request),
             .acknowledge(r_acknowledge),
+            .qos({M_COUNT_P1*4{1'b0}}),
+            .pending({M_COUNT_P1{1'b0}}),
             .grant(r_grant),
             .grant_valid(r_grant_valid),
             .grant_encoded(r_grant_encoded)
@@ -458,22 +462,31 @@
         // address arbitration
         wire [S_COUNT-1:0] a_request;
         wire [S_COUNT-1:0] a_acknowledge;
+        wire [S_COUNT-1:0] a_pending;
         wire [S_COUNT-1:0] a_grant;
         wire a_grant_valid;
         wire [CL_S_COUNT-1:0] a_grant_encoded;
+
+        for (m = 0; m < S_COUNT; m = m + 1) begin : a_pend_map
+            assign a_pending[m] = int_axi_arvalid[m*M_COUNT+n];
+        end
 
         arbiter #(
             .PORTS(S_COUNT),
             .ARB_TYPE_ROUND_ROBIN(1),
             .ARB_BLOCK(1),
             .ARB_BLOCK_ACK(1),
-            .ARB_LSB_HIGH_PRIORITY(1)
+            .ARB_LSB_HIGH_PRIORITY(1),
+            .QOS_ENABLE(1),
+            .AGEING_LIMIT(AGEING_LIMIT)
         )
         a_arb_inst (
             .clk(clk),
             .rst(rst),
             .request(a_request),
             .acknowledge(a_acknowledge),
+            .qos(int_s_axi_arqos),
+            .pending(a_pending),
             .grant(a_grant),
             .grant_valid(a_grant_valid),
             .grant_encoded(a_grant_encoded)

--- a/environment/public/code/axi_crossbar_wr.v (Buggy Starter)
+++ b/solution/gold/code/axi_crossbar_wr.v (Golden Reference)
@@ -391,13 +391,17 @@
             .ARB_TYPE_ROUND_ROBIN(1),
             .ARB_BLOCK(1),
             .ARB_BLOCK_ACK(1),
-            .ARB_LSB_HIGH_PRIORITY(1)
+            .ARB_LSB_HIGH_PRIORITY(1),
+            .QOS_ENABLE(0),
+            .AGEING_LIMIT(0)
         )
         b_arb_inst (
             .clk(clk),
             .rst(rst),
             .request(b_request),
             .acknowledge(b_acknowledge),
+            .qos({M_COUNT_P1*4{1'b0}}),
+            .pending({M_COUNT_P1{1'b0}}),
             .grant(b_grant),
             .grant_valid(b_grant_valid),
             .grant_encoded(b_grant_encoded)
@@ -521,22 +525,31 @@
 
         wire [S_COUNT-1:0] a_request;
         wire [S_COUNT-1:0] a_acknowledge;
+        wire [S_COUNT-1:0] a_pending;
         wire [S_COUNT-1:0] a_grant;
         wire a_grant_valid;
         wire [CL_S_COUNT-1:0] a_grant_encoded;
+
+        for (m = 0; m < S_COUNT; m = m + 1) begin : a_pend_map
+            assign a_pending[m] = int_axi_awvalid[m*M_COUNT+n];
+        end
 
         arbiter #(
             .PORTS(S_COUNT),
             .ARB_TYPE_ROUND_ROBIN(1),
             .ARB_BLOCK(1),
             .ARB_BLOCK_ACK(1),
-            .ARB_LSB_HIGH_PRIORITY(1)
+            .ARB_LSB_HIGH_PRIORITY(1),
+            .QOS_ENABLE(1),
+            .AGEING_LIMIT(AGEING_LIMIT)
         )
         a_arb_inst (
             .clk(clk),
             .rst(rst),
             .request(a_request),
             .acknowledge(a_acknowledge),
+            .qos(int_s_axi_awqos),
+            .pending(a_pending),
             .grant(a_grant),
             .grant_valid(a_grant_valid),
             .grant_encoded(a_grant_encoded)

--- a/environment/public/code/arbiter.v (Buggy Starter)
+++ b/solution/gold/code/arbiter.v (Golden Reference)
@@ -29,7 +29,8 @@
 `default_nettype none
 
 /*
- * Arbiter module
+ * Arbiter module with optional 4-bit QoS priority, per-level round-robin,
+ * and starvation-bounded ageing promotion
  */
 module arbiter #
 (
@@ -41,7 +42,11 @@
     // block on acknowledge assert when nonzero, request deassert when 0
     parameter ARB_BLOCK_ACK = 1,
     // LSB priority selection
-    parameter ARB_LSB_HIGH_PRIORITY = 0
+    parameter ARB_LSB_HIGH_PRIORITY = 0,
+    // enable 4-bit QoS-aware arbitration
+    parameter QOS_ENABLE = 0,
+    // starvation-bounded ageing limit (0 disables ageing promotion)
+    parameter AGEING_LIMIT = 0
 )
 (
     input  wire                     clk,
@@ -49,6 +54,8 @@
 
     input  wire [PORTS-1:0]         request,
     input  wire [PORTS-1:0]         acknowledge,
+    input  wire [PORTS*4-1:0]       qos,
+    input  wire [PORTS-1:0]         pending,
 
     output wire [PORTS-1:0]         grant,
     output wire                     grant_valid,
@@ -62,6 +69,49 @@
 assign grant_valid = grant_valid_reg;
 assign grant = grant_reg;
 assign grant_encoded = grant_encoded_reg;
+
+reg [PORTS-1:0] mask_reg = 0, mask_next;
+reg [16*PORTS-1:0] qos_mask_reg = 0, qos_mask_next;
+reg [PORTS*32-1:0] age_reg = 0, age_next;
+
+reg [PORTS*4-1:0] eff_qos;
+reg [3:0] max_qos;
+reg [PORTS-1:0] eff_request;
+reg [PORTS-1:0] active_mask;
+
+integer p;
+
+always @* begin
+    eff_qos = {PORTS*4{1'b0}};
+    max_qos = 4'd0;
+    for (p = 0; p < PORTS; p = p + 1) begin
+        if (QOS_ENABLE && (AGEING_LIMIT > 0) && (age_reg[p*32 +: 32] >= AGEING_LIMIT)) begin
+            eff_qos[p*4 +: 4] = 4'hF;
+        end else if (QOS_ENABLE) begin
+            eff_qos[p*4 +: 4] = qos[p*4 +: 4];
+        end else begin
+            eff_qos[p*4 +: 4] = 4'd0;
+        end
+
+        if (request[p] && (eff_qos[p*4 +: 4] > max_qos)) begin
+            max_qos = eff_qos[p*4 +: 4];
+        end
+    end
+
+    for (p = 0; p < PORTS; p = p + 1) begin
+        if (QOS_ENABLE) begin
+            eff_request[p] = request[p] && (eff_qos[p*4 +: 4] == max_qos);
+        end else begin
+            eff_request[p] = request[p];
+        end
+    end
+
+    if (QOS_ENABLE) begin
+        active_mask = qos_mask_reg[max_qos*PORTS +: PORTS];
+    end else begin
+        active_mask = mask_reg;
+    end
+end
 
 wire request_valid;
 wire [$clog2(PORTS)-1:0] request_index;
@@ -72,13 +122,11 @@
     .LSB_HIGH_PRIORITY(ARB_LSB_HIGH_PRIORITY)
 )
 priority_encoder_inst (
-    .input_unencoded(request),
+    .input_unencoded(eff_request),
     .output_valid(request_valid),
     .output_encoded(request_index),
     .output_unencoded(request_mask)
 );
-
-reg [PORTS-1:0] mask_reg = 0, mask_next;
 
 wire masked_request_valid;
 wire [$clog2(PORTS)-1:0] masked_request_index;
@@ -89,19 +137,32 @@
     .LSB_HIGH_PRIORITY(ARB_LSB_HIGH_PRIORITY)
 )
 priority_encoder_masked (
-    .input_unencoded(request & mask_reg),
+    .input_unencoded(eff_request & active_mask),
     .output_valid(masked_request_valid),
     .output_encoded(masked_request_index),
     .output_unencoded(masked_request_mask)
 );
+
+reg [PORTS-1:0] next_rr_mask;
 
 always @* begin
     grant_next = 0;
     grant_valid_next = 0;
     grant_encoded_next = 0;
     mask_next = mask_reg;
-
-    if (ARB_BLOCK && !ARB_BLOCK_ACK && grant_reg & request) begin
+    qos_mask_next = qos_mask_reg;
+    age_next = age_reg;
+    next_rr_mask = {PORTS{1'b0}};
+
+    if (QOS_ENABLE) begin
+        for (p = 0; p < PORTS; p = p + 1) begin
+            if (!pending[p]) begin
+                age_next[p*32 +: 32] = 32'd0;
+            end
+        end
+    end
+
+    if (ARB_BLOCK && !ARB_BLOCK_ACK && (grant_reg & request)) begin
         // granted request still asserted; hold it
         grant_valid_next = grant_valid_reg;
         grant_next = grant_reg;
@@ -114,28 +175,45 @@
     end else if (request_valid) begin
         if (ARB_TYPE_ROUND_ROBIN) begin
             if (masked_request_valid) begin
-                grant_valid_next = 1;
+                grant_valid_next = 1'b1;
                 grant_next = masked_request_mask;
                 grant_encoded_next = masked_request_index;
                 if (ARB_LSB_HIGH_PRIORITY) begin
-                    mask_next = {PORTS{1'b1}} << (masked_request_index + 1);
+                    next_rr_mask = {PORTS{1'b1}} << (masked_request_index + 1);
                 end else begin
-                    mask_next = {PORTS{1'b1}} >> (PORTS - masked_request_index);
+                    next_rr_mask = {PORTS{1'b1}} >> (PORTS - masked_request_index);
                 end
             end else begin
-                grant_valid_next = 1;
+                grant_valid_next = 1'b1;
                 grant_next = request_mask;
                 grant_encoded_next = request_index;
                 if (ARB_LSB_HIGH_PRIORITY) begin
-                    mask_next = {PORTS{1'b1}} << (request_index + 1);
+                    next_rr_mask = {PORTS{1'b1}} << (request_index + 1);
                 end else begin
-                    mask_next = {PORTS{1'b1}} >> (PORTS - request_index);
+                    next_rr_mask = {PORTS{1'b1}} >> (PORTS - request_index);
                 end
             end
+            if (QOS_ENABLE) begin
+                qos_mask_next[max_qos*PORTS +: PORTS] = next_rr_mask;
+            end else begin
+                mask_next = next_rr_mask;
+            end
         end else begin
-            grant_valid_next = 1;
+            grant_valid_next = 1'b1;
             grant_next = request_mask;
             grant_encoded_next = request_index;
+        end
+
+        if (QOS_ENABLE) begin
+            for (p = 0; p < PORTS; p = p + 1) begin
+                if (!pending[p] || grant_next[p]) begin
+                    age_next[p*32 +: 32] = 32'd0;
+                end else if (request[p]) begin
+                    if ((AGEING_LIMIT > 0) && (age_reg[p*32 +: 32] < AGEING_LIMIT)) begin
+                        age_next[p*32 +: 32] = age_reg[p*32 +: 32] + 32'd1;
+                    end
+                end
+            end
         end
     end
 end
@@ -146,11 +224,15 @@
         grant_valid_reg <= 0;
         grant_encoded_reg <= 0;
         mask_reg <= 0;
+        qos_mask_reg <= 0;
+        age_reg <= 0;
     end else begin
         grant_reg <= grant_next;
         grant_valid_reg <= grant_valid_next;
         grant_encoded_reg <= grant_encoded_next;
         mask_reg <= mask_next;
+        qos_mask_reg <= qos_mask_next;
+        age_reg <= age_next;
     end
 end
 

```

</details>

---

## 5. Harbor Package File Inventory & Provenance

### Public Workspace (`environment/public/`)
- [`environment/public/BUILD.md`](environment/public/BUILD.md) *(Read-Only Context)*
- [`environment/public/code/COPYING`](environment/public/code/COPYING) *(Read-Only Context)*
- [`environment/public/code/arbiter.v`](environment/public/code/arbiter.v) **(Editable)**
- [`environment/public/code/axi_crossbar.v`](environment/public/code/axi_crossbar.v) **(Editable)**
- [`environment/public/code/axi_crossbar_addr.v`](environment/public/code/axi_crossbar_addr.v) **(Editable)**
- [`environment/public/code/axi_crossbar_rd.v`](environment/public/code/axi_crossbar_rd.v) **(Editable)**
- [`environment/public/code/axi_crossbar_wr.v`](environment/public/code/axi_crossbar_wr.v) **(Editable)**
- [`environment/public/code/axi_register_rd.v`](environment/public/code/axi_register_rd.v) *(Read-Only Context)*
- [`environment/public/code/axi_register_wr.v`](environment/public/code/axi_register_wr.v) *(Read-Only Context)*
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

