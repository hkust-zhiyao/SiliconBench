# `case_0103`: Coupled WB2AXIP Outstanding Credit Tracking, Wishbone Error Abort Drain, and Nangate45 Area/Timing Closure

[Back to Benchmark Root (`README.md`)](../../README.md) | [Full 94-Task Catalog (`TASKS_INDEX.md`)](../../TASKS_INDEX.md) | [`task.toml`](task.toml) | [`instruction.md`](instruction.md) | [`solution/solve.sh`](solution/solve.sh) | [`tests/test.sh`](tests/test.sh) | [`tests/private/grader/run.py`](tests/private/grader/run.py)

---

## 1. Task Overview & Harbor Configuration

| Field | Value |
| :--- | :--- |
| **Task ID** | `case_0103` |
| **Source Silicon Repository** | `zipcpu/wb2axip` (`repo_43`) |
| **Engineering Problem Type** | **Architectural & Protocol Bug Repair** (`PT1_Arch_Protocol_Bug_Repair`) |
| **EDA Evaluation Stage** | **Stage 3: Static Timing (STA) & CDC/RDC Closure** (`stage3_sta_cdc`) |
| **Coupled Evaluation Gates** | Stage 1 (Functional RTL Sim) -> Stage 2 (Logic Synthesis & Gate-Level Verification) -> Stage 3 (OpenSTA Single-/Multi-Corner Setup/Hold WNS/TNS & CDC/RDC Closure) |
| **Primary Hardware Domain** | `protocol_control` (Protocol Handshake, Backpressure, Arbitration, FIFO & FSM Control) |
| **Multi-Domain Tags** | `protocol_control`, `reset_rdc`, `rtl_integration`, `synthesis_qor`, `verification_debug` |
| **Editable Files (`allowed_edits`)** | [`code/wbm2axisp.v`](environment/public/code/wbm2axisp.v), [`code/aximwr2wbsp.v`](environment/public/code/aximwr2wbsp.v), [`code/aximrd2wbsp.v`](environment/public/code/aximrd2wbsp.v) (3 files, 1539 LOC) |
| **Public Subsystem Context** | 10 RTL files (3717 LOC) |
| **Base Container Image** | `siliconbench-eda:1.0` (`allow_internet = false`, `environment_mode = "separate"`) |
| **PDK / Environment Profile** | **Nangate45 45nm Open Cell Library + Task Multi-Corner Liberty/SDC** |
| **Task-Customized Collateral?** | **Yes (Task-Bundled Collateral)** — Uses shared Nangate45 library for synthesis plus task-bundled fast/slow/scan corner timing views. |
| **Verifier Timeout & Seeds** | `600s` total (`300s`/seed) across deterministic seeds `[1, 2]` |

---

## 2. Problem Specification (`issue.md`)

In `code/wb2axip_bridge_top.v`, the editable Wishbone-to-AXI4 bridge (`code/wbm2axisp.v`) and AXI4-to-Wishbone write/read burst bridges (`code/aximwr2wbsp.v` and `code/aximrd2wbsp.v`) fail on outstanding credit accounting, Wishbone abort/error draining, AXI ID ordering, and Nangate45 area/timing closure. Repair `code/wbm2axisp.v` so it tracks up to `1 << LGFIFO` in-flight Wishbone requests without direction-switch races, shifts 32-bit read data and write strobes according to sub-word address offset, and enters a flush state upon any AXI error response (`i_axi_rresp[1]` or `i_axi_bresp[1]`, emitting a single `o_wb_err` pulse) or premature `i_wb_cyc` drop while transactions are in flight—suppressing `o_wb_ack`/`o_wb_err` and stalling new Wishbone requests until all outstanding AXI responses have drained.

Repair `code/aximwr2wbsp.v` and `code/aximrd2wbsp.v` so each bridge enforces single-ID in-flight ordering (stalling a new AXI burst whose `AWID`/`ARID` differs from an active in-flight ID until all prior Wishbone acknowledgments complete) and cleanly handles a downstream Wishbone bus error (`i_wb_err` while `o_wb_cyc` is high): immediately drop `o_wb_cyc` and `o_wb_stb`, drain any remaining beats of the faulted write burst or synthesize the remaining beats of the faulted read burst with `S_AXI_RRESP = 2'b10` and `S_AXI_RLAST` on the final beat, and return `S_AXI_BRESP = 2'b10` for the faulted write burst before accepting new bursts. Share the active transaction ID across in-flight beats so that under `flow/synth.ys` and `flow/timing.tcl` (`10.0 ns` `i_clk`, `6.0 ns` input delay on `wb_dn_ack`, `wb_dn_err`, `wb_dn_stall`), `wb2axip_bridge_top` achieves mapped Nangate45 cell area `<= 6,750.0 um^2`, worst setup slack `>= 2.48 ns`, and worst hold slack `>= 0.00 ns`.

---

## 3. Build & Verification Instructions (`BUILD.md`)

# Build, Simulation, Synthesis, and Static Timing Verification

## 1. Editable vs. Read-Only Files

Editable files (only these files are collected and graded):
- `code/wbm2axisp.v`
- `code/aximwr2wbsp.v`
- `code/aximrd2wbsp.v`

Read-only files (must remain unmodified):
- `code/skidbuffer.v`
- `code/sfifo.v`
- `code/axi_addr.v`
- `code/wbarbiter.v`
- `code/axim2wbsp.v`
- `code/wb2axip_bridge_top.v`
- `code/LICENSE`
- `lib/NangateOpenCellLibrary_typical.lib`
- `lib/LICENSE.Nangate45`
- `flow/synth.ys`
- `flow/timing.tcl`

Keep the module names and port interfaces of `wbm2axisp`, `aximwr2wbsp`, `aximrd2wbsp`, and `wb2axip_bridge_top` unchanged. All editable RTL must be pure synthesizable Verilog-2001 without simulation system tasks, delays, `initial` blocks, `force`/`release`/`bind`, synthesis/simulation conditional compilation macros, or hierarchical testbench references.

## 2. Functional Simulation (`verilator`)

You can compile and simulate `wb2axip_bridge_top` with your own testbench using Verilator:

```bash
verilator --binary --timing -j 1 -Wno-fatal --top-module tb \
  code/skidbuffer.v \
  code/sfifo.v \
  code/axi_addr.v \
  code/wbarbiter.v \
  code/axim2wbsp.v \
  code/wbm2axisp.v \
  code/aximwr2wbsp.v \
  code/aximrd2wbsp.v \
  code/wb2axip_bridge_top.v \
  tb.sv
./obj_dir/Vtb
```

Functional verification checks:
1. `wbm2axisp`: pipelined 32-bit Wishbone reads and writes mapped onto 64-bit AXI4 (`OPT_LITTLE_ENDIAN = 1`), sub-word write strobe shifting (`o_axi_wstrb`) and read data lane extraction (`o_wb_data`), read/write direction locking while `npending > 0`, and full flush recovery on AXI `SLVERR` (`i_axi_rresp[1]` / `i_axi_bresp[1]`) or mid-flight `i_wb_cyc` drop (suppressing `o_wb_ack`/`o_wb_err` and holding `o_wb_stall = 1` until all in-flight AXI responses have returned).
2. `aximwr2wbsp`: multi-beat AXI4 `INCR` write bursts converted to pipelined Wishbone writes, blocking new bursts with a different `S_AXI_AWID` while `acks_expected > 0`, and Wishbone error (`i_wb_err`) abort handling (dropping `o_wb_cyc`/`o_wb_stb`, draining remaining `W` beats of the faulted burst, and returning `S_AXI_BRESP = 2'b10` with the matching `S_AXI_BID`).
3. `aximrd2wbsp`: multi-beat AXI4 `INCR` read bursts converted to pipelined Wishbone reads, blocking new bursts with a different `S_AXI_ARID` while transactions are in flight (`!wb_empty`), and Wishbone error (`i_wb_err`) abort handling (immediately dropping `o_wb_cyc`/`o_wb_stb` and returning `S_AXI_RRESP = 2'b10` for all remaining beats of the burst through `S_AXI_RLAST = 1` with the matching `S_AXI_RID`).

## 3. Yosys Nangate45 Synthesis & Area Check

Run Yosys using `flow/synth.ys`:

```bash
yosys -Q -T -s flow/synth.ys
```

From `stat -liberty lib/NangateOpenCellLibrary_typical.lib`, verify:
- `Chip area for module '\wb2axip_bridge_top': <= 6750.0` (`um^2`).

## 4. OpenSTA Timing Closure Check

Run OpenSTA on the synthesized `mapped.v` using `flow/timing.tcl`:

```bash
LD_LIBRARY_PATH=/opt/siliconbench/tools/openroad-runtime/usr/lib/x86_64-linux-gnu:/opt/siliconbench/tools/openroad-runtime/opt/or-tools/lib \
  sta -exit flow/timing.tcl
```

Verify that:
- `check_setup -verbose` reports no unconstrained endpoints or clock errors.
- Worst setup slack (`-path_delay max`) is `>= 2.48 ns` (`MET`).
- Worst hold slack (`-path_delay min`) is `>= 0.00 ns` (`MET`).

---

## 4. Reference Fix Inspection (Buggy Starter vs. Golden Solution Diff)

> Human reviewers can inspect the exact reference bug fix below, or browse full files in [`environment/public/`](environment/public/), [`solution/gold/`](solution/gold/), and [`solution/alternate_gold/`](solution/alternate_gold/).

<details open>
<summary><b>Click to expand/collapse Unified Diff (<code>environment/public/</code> vs. <code>solution/gold/</code>)</b></summary>

```diff
--- a/environment/public/code/wbm2axisp.v (Buggy Starter)
+++ b/solution/gold/code/wbm2axisp.v (Golden Reference)
@@ -232,7 +232,7 @@
 	end
 	else if ((i_axi_rvalid && i_axi_rresp[1])
 		||(i_axi_bvalid && i_axi_bresp[1])
-		)
+		||(!i_wb_cyc && !empty))
 		flushing <= 1'b1;
 	else if (empty)
 		flushing <= 1'b0;
@@ -469,7 +469,7 @@
 		if (OPT_LITTLE_ENDIAN)
 		begin : LITTLE_ENDIAN_RDATA
 
-			assign	return_data = i_axi_rdata;
+			assign	return_data = i_axi_rdata >> (fifo_value * DW);
 
 		end else begin : BIG_ENDIAN_RDATA
 

--- a/environment/public/code/aximwr2wbsp.v (Buggy Starter)
+++ b/solution/gold/code/aximwr2wbsp.v (Golden Reference)
@@ -484,29 +484,34 @@
 	always @(posedge S_AXI_ACLK)
 	if (!S_AXI_ARESETN)
 		err_fifo_write <= 0;
-	else if (read_ack_fifo && ack_empty && fifo_ack_ln == 0)
-		err_fifo_write <= (i_wb_ack || i_wb_err || err_state);
-	else if (ack_last)
-		err_fifo_write <= (i_wb_ack || i_wb_err || err_state);
+	else if (read_ack_fifo && !wb_ack_fifo_empty && ((fifo_ack_ln == 0 && (i_wb_ack || i_wb_err)) || err_state))
+		err_fifo_write <= 1'b1;
+	else if (ack_last && (i_wb_ack || i_wb_err))
+		err_fifo_write <= 1'b1;
+	else if (o_wb_cyc && i_wb_err && !ack_empty && !ack_last)
+		err_fifo_write <= 1'b1;
 	else
 		err_fifo_write <= 1'b0;
 	// }}}
 
-	// bid_fifo - Keep track of BID's
-	// {{{
-	sfifo #(.BW(C_AXI_ID_WIDTH), .LGFLEN(LGFIFO))
-	bid_fifo(S_AXI_ACLK, !S_AXI_ARESETN,
-		skid_wvalid && skid_wready && skid_wlast,
-			(total_fifo_fill == bid_fifo_fill) ? skid_awid:axi_wid,
-		bid_fifo_full, bid_fifo_fill,
-		S_AXI_BVALID & S_AXI_BREADY, S_AXI_BID, bid_fifo_empty);
-	// }}}
+	reg [LGFIFO:0] wlast_fill_r;
+	always @(posedge S_AXI_ACLK)
+	if (!S_AXI_ARESETN) wlast_fill_r <= 0;
+	else case({skid_wvalid && skid_wready && skid_wlast, S_AXI_BVALID && S_AXI_BREADY})
+	2'b10: wlast_fill_r <= wlast_fill_r + 1;
+	2'b01: wlast_fill_r <= wlast_fill_r - 1;
+	default: ;
+	endcase
+	assign bid_fifo_full  = wlast_fill_r[LGFIFO];
+	assign bid_fifo_fill  = wlast_fill_r;
+	assign bid_fifo_empty = (wlast_fill_r == 0);
+	assign S_AXI_BID      = axi_wid;
 
 	// err_fifo - Keep track of error returns
 	// {{{
 	sfifo #(.BW(1), .LGFLEN(LGFIFO))
 	err_fifo(S_AXI_ACLK, !S_AXI_ARESETN,
-		err_fifo_write, 1'b0,
+		err_fifo_write, { ack_err || i_wb_err || err_state },
 		err_fifo_full, err_fifo_fill,
 		S_AXI_BVALID & S_AXI_BREADY, S_AXI_BRESP[1], err_fifo_empty);
 	// }}}

--- a/environment/public/code/aximrd2wbsp.v (Buggy Starter)
+++ b/solution/gold/code/aximrd2wbsp.v (Golden Reference)
@@ -310,14 +310,34 @@
 	assign	lastid_fifo_wr = (o_wb_stb && (i_wb_err || !i_wb_stall))
 			||(err_state && midissue && !lastid_fifo_full);
 
-	sfifo #(.BW(C_AXI_ID_WIDTH+1), .LGFLEN(LGFIFO))
-	lastid_fifo(S_AXI_ACLK, w_reset,
-		lastid_fifo_wr,
-		{ axi_id, last_stb },
-		lastid_fifo_full, lastid_fifo_fill,
-		S_AXI_RVALID && S_AXI_RREADY,
-		{ S_AXI_RID, S_AXI_RLAST },
-		lastid_fifo_empty);
+	reg [(1<<LGFIFO)-1:0] rlast_vec_r;
+	reg [LGFIFO:0] rlast_wr_r, rlast_rd_r, rlast_fill_r;
+	wire rlast_push = lastid_fifo_wr && !lastid_fifo_full;
+	wire rlast_pop  = S_AXI_RVALID && S_AXI_RREADY && !lastid_fifo_empty;
+	always @(posedge S_AXI_ACLK)
+	if (w_reset) begin
+		rlast_wr_r <= 0;
+		rlast_rd_r <= 0;
+		rlast_fill_r <= 0;
+		rlast_vec_r <= 0;
+	end else begin
+		if (rlast_push) begin
+			rlast_vec_r[rlast_wr_r[LGFIFO-1:0]] <= last_stb;
+			rlast_wr_r <= rlast_wr_r + 1;
+		end
+		if (rlast_pop)
+			rlast_rd_r <= rlast_rd_r + 1;
+		case ({rlast_push, rlast_pop})
+		2'b10: rlast_fill_r <= rlast_fill_r + 1;
+		2'b01: rlast_fill_r <= rlast_fill_r - 1;
+		default: ;
+		endcase
+	end
+	assign lastid_fifo_full  = rlast_fill_r[LGFIFO];
+	assign lastid_fifo_fill  = rlast_fill_r;
+	assign lastid_fifo_empty = (rlast_fill_r == 0);
+	assign S_AXI_RLAST       = rlast_vec_r[rlast_rd_r[LGFIFO-1:0]];
+	assign S_AXI_RID         = axi_id;
 	// }}}
 
 	// read_data
@@ -418,7 +438,7 @@
 	always @(*)
 	begin
 		S_AXI_RRESP[0] = 1'b0;
-		S_AXI_RRESP[1] = response_err;
+		S_AXI_RRESP[1] = response_err || (resp_fifo_empty && err_state);
 
 
 		S_AXI_RVALID = !resp_fifo_empty

```

</details>

---

## 5. Harbor Package File Inventory & Provenance

### Public Workspace (`environment/public/`)
- [`environment/public/BUILD.md`](environment/public/BUILD.md) *(Read-Only Context)*
- [`environment/public/code/LICENSE`](environment/public/code/LICENSE) *(Read-Only Context)*
- [`environment/public/code/axi_addr.v`](environment/public/code/axi_addr.v) *(Read-Only Context)*
- [`environment/public/code/axim2wbsp.v`](environment/public/code/axim2wbsp.v) *(Read-Only Context)*
- [`environment/public/code/aximrd2wbsp.v`](environment/public/code/aximrd2wbsp.v) **(Editable)**
- [`environment/public/code/aximwr2wbsp.v`](environment/public/code/aximwr2wbsp.v) **(Editable)**
- [`environment/public/code/sfifo.v`](environment/public/code/sfifo.v) *(Read-Only Context)*
- [`environment/public/code/skidbuffer.v`](environment/public/code/skidbuffer.v) *(Read-Only Context)*
- [`environment/public/code/wb2axip_bridge_top.v`](environment/public/code/wb2axip_bridge_top.v) *(Read-Only Context)*
- [`environment/public/code/wbarbiter.v`](environment/public/code/wbarbiter.v) *(Read-Only Context)*
- [`environment/public/code/wbm2axisp.v`](environment/public/code/wbm2axisp.v) **(Editable)**
- [`environment/public/flow/synth.ys`](environment/public/flow/synth.ys) *(Read-Only Context)*
- [`environment/public/flow/timing.tcl`](environment/public/flow/timing.tcl) *(Read-Only Context)*
- [`environment/public/issue.md`](environment/public/issue.md) *(Read-Only Context)*
- [`environment/public/lib/LICENSE.Nangate45`](environment/public/lib/LICENSE.Nangate45) *(Read-Only Context)*
- [`environment/public/lib/NangateOpenCellLibrary_typical.lib`](environment/public/lib/NangateOpenCellLibrary_typical.lib) *(Read-Only Context)*

### Reference Solutions & Isolated Verifier (`solution/` & `tests/`)
- [`solution/solve.sh`](solution/solve.sh) — Harbor oracle script
- [`solution/gold/`](solution/gold/) — Primary golden reference solution
- [`solution/alternate_gold/`](solution/alternate_gold/) — Structurally distinct secondary reference solution
- [`tests/test.sh`](tests/test.sh) — Isolated Harbor verifier entrypoint
- [`tests/private/policy_filter.py`](tests/private/policy_filter.py) — Pre-grader airlock & anti-cheat policy screen
- [`tests/private/grader/run.py`](tests/private/grader/run.py) — Deterministic front-to-back EDA verifier

### Upstream Provenance (`SOURCE.md`)

