# `case_7003`: VeeR EH2 AXI4-to-AHB and AHB-to-AXI4 Bus Bridge Force-Halt Cancellation, Error Drain, and Transparent Channel Timing Budgets

[Back to Benchmark Root (`README.md`)](../../README.md) | [Full 94-Task Catalog (`TASKS_INDEX.md`)](../../TASKS_INDEX.md) | [`task.toml`](task.toml) | [`instruction.md`](instruction.md) | [`solution/solve.sh`](solution/solve.sh) | [`tests/test.sh`](tests/test.sh) | [`tests/private/grader/run.py`](tests/private/grader/run.py)

---

## 1. Task Overview & Harbor Configuration

| Field | Value |
| :--- | :--- |
| **Task ID** | `case_7003` |
| **Source Silicon Repository** | `chipsalliance/cores-veer-eh2` (`repo_07`) |
| **Engineering Problem Type** | **High-Frequency Timing & Area Optimization** (`PT3_Timing_Area_PPA_Closure`) |
| **EDA Evaluation Stage** | **Stage 3: Static Timing (STA) & CDC/RDC Closure** (`stage3_sta_cdc`) |
| **Coupled Evaluation Gates** | Stage 1 (Functional RTL Sim) -> Stage 2 (Logic Synthesis & Gate-Level Verification) -> Stage 3 (OpenSTA Single-/Multi-Corner Setup/Hold WNS/TNS & CDC/RDC Closure) |
| **Primary Hardware Domain** | `reset_rdc` (Reset Recovery, Abort Drain, Reset Domain Crossing (RDC) & Boot Sequencing) |
| **Multi-Domain Tags** | `protocol_control`, `reset_rdc`, `rtl_integration`, `sdc_sta`, `verification_debug` |
| **Editable Files (`allowed_edits`)** | [`code/axi4_to_ahb.sv`](environment/public/code/axi4_to_ahb.sv), [`code/ahb_to_axi4.sv`](environment/public/code/ahb_to_axi4.sv), [`constraints.json`](environment/public/constraints.json) (3 files, 839 LOC) |
| **Public Subsystem Context** | 10 RTL files (3686 LOC) |
| **Base Container Image** | `siliconbench-eda:1.0` (`allow_internet = false`, `environment_mode = "separate"`) |
| **PDK / Environment Profile** | **Nangate45 45nm Open Cell Library (Shared Base Image)** |
| **Task-Customized Collateral?** | **No (Uses Shared Base Image)** — Uses unified Nangate45 typical Liberty and LEF from base image. |
| **Verifier Timeout & Seeds** | `600s` total (`300s`/seed) across deterministic seeds `[1, 2]` |

---

## 2. Problem Specification (`issue.md`)

# VeeR EH2 AXI4-to-AHB and AHB-to-AXI4 Bus Bridge Force-Halt Cancellation, Error Drain, and Transparent Channel Timing Budgets

In `code/axi4_to_ahb.sv`, `code/ahb_to_axi4.sv`, and `constraints.json` (integrated in `code/top.sv`), force-halt buffer cancellation, two-cycle AHB error signaling and SLVERR propagation, and transparent sideband channel timing budgets fail verification. In `code/axi4_to_ahb.sv`, asserting `dec_tlu_force_halt` (including when `bus_clk_en` is low) must latch through `force_halt_busff` and clear both the write buffer (`wrbuf_vld`, `wrbuf_data_vld`) and `buf_state` on the active bus clock edge, and any AHB error (`ahb_hresp_q`) in `DATA_RD`, `STREAM_RD`, or `DATA_WR` must record `slvbuf_error` and return `axi_rresp = 2'b10` or `axi_bresp = 2'b10`. In `code/ahb_to_axi4.sv`, any AHB transaction outside DCCM (`[0xf0040000, 0xf005ffff]`) and ICCM (`[0xee000000, 0xee00ffff]`), any ICCM read/write or DCCM write whose size is not 32-bit (`3'h2`) or 64-bit (`3'h3`), any unaligned AHB transfer, or any downstream AXI read error (`|axi_rresp[1:0]` in `PEND`) must assert a two-cycle AHB error response (`ahb_hresp = 1'b1` with `ahb_hreadyout = 1'b0` on the first bus clock cycle and `ahb_hreadyout = 1'b1` on the second) while clearing/blocking `cmdbuf_vld` for errored reads.

In `code/top.sv`, the bridge operates at `10 ns` and `12 ns` clock periods (`clk_i`), with a `5.0 ns` external input delay on all non-clock inputs and a `4.0 ns` external output delay on all outputs, which flags the two zero-cut transparent 8-bit sideband channels (`qos_in` to `qos_out` and `region_in` to `region_out`) even with zero internal delay. Keep the clock and the existing I/O delays on all ports, and update `constraints.json` (`"max_delays"`) using the declarative schema documented in `BUILD.md` so that the maximum internal input-to-output combinational delay is `1.75 ns` for `qos_in` to `qos_out` and `2.75 ns` for `region_in` to `region_out`, while preserving the existing timing requirements for all registered bridge ports. Edit only `code/axi4_to_ahb.sv`, `code/ahb_to_axi4.sv`, and `constraints.json`.

---

## 3. Build & Verification Instructions (`BUILD.md`)

# Build, Simulation, and Static Timing Analysis Guide

## 1. Editable Files
Only the following three files are collected and graded:
- `code/axi4_to_ahb.sv`
- `code/ahb_to_axi4.sv`
- `constraints.json`

All other files in `code/` (`code/top.sv`, `code/common_defines.vh`, `code/eh2_param.vh`, `code/eh2_pdef.vh`, `code/eh2_def.sv`, `code/beh_lib.sv`, `code/eh2_lib.sv`, `code/LICENSE`) are read-only and must remain unmodified.

## 2. Functional Simulation (`Verilator`)
Compile and simulate `code/axi4_to_ahb.sv`, `code/ahb_to_axi4.sv`, and `code/top.sv` with Verilator:

```bash
verilator \
  --binary --timing -Wno-fatal -Icode \
  --top-module <your_tb> --Mdir obj_dir \
  code/common_defines.vh code/eh2_pdef.vh code/eh2_def.sv \
  code/beh_lib.sv code/eh2_lib.sv \
  code/axi4_to_ahb.sv code/ahb_to_axi4.sv code/top.sv <your_tb.sv>
./obj_dir/V<your_tb>
```

## 3. Synthesis and Declarative Timing Constraints (`Yosys/Slang` + `OpenROAD/OpenSTA`)
The flow reads `constraints.json`: `max_delays` is an array of objects with numeric `ns`, `from`, and `to`; each `from` and `to` is an array of port-group (or bit-indexed port) names.
- Input groups are `rst_ni`, `bus_clk_en`, `dec_tlu_force_halt`, `m_axi_awvalid`, `m_axi_awid`, `m_axi_awaddr`, `m_axi_awsize`, `m_axi_awprot`, `m_axi_wvalid`, `m_axi_wdata`, `m_axi_wstrb`, `m_axi_wlast`, `m_axi_bready`, `m_axi_arvalid`, `m_axi_arid`, `m_axi_araddr`, `m_axi_arsize`, `m_axi_arprot`, `m_axi_rready`, `s_axi_awready`, `s_axi_wready`, `s_axi_bvalid`, `s_axi_bresp`, `s_axi_bid`, `s_axi_arready`, `s_axi_rvalid`, `s_axi_rid`, `s_axi_rdata`, `s_axi_rresp`, `qos_in`, and `region_in` (or bit-indexed `qos_in[0..7]`, `region_in[0..7]`).
- Output groups are `m_axi_awready`, `m_axi_wready`, `m_axi_bvalid`, `m_axi_bresp`, `m_axi_bid`, `m_axi_arready`, `m_axi_rvalid`, `m_axi_rid`, `m_axi_rdata`, `m_axi_rresp`, `m_axi_rlast`, `s_axi_awvalid`, `s_axi_awid`, `s_axi_awaddr`, `s_axi_awsize`, `s_axi_awprot`, `s_axi_awlen`, `s_axi_awburst`, `s_axi_wvalid`, `s_axi_wdata`, `s_axi_wstrb`, `s_axi_wlast`, `s_axi_bready`, `s_axi_arvalid`, `s_axi_arid`, `s_axi_araddr`, `s_axi_arsize`, `s_axi_arprot`, `s_axi_arlen`, `s_axi_arburst`, `s_axi_rready`, `qos_out`, and `region_out` (or bit-indexed `qos_out[0..7]`, `region_out[0..7]`).
A group name without bit index selects all bits of that port. Each object is translated to `set_max_delay <ns> -from [get_ports {...}] -to [get_ports {...}]`.

The flow retains the existing clock (`10 ns` or `12 ns` on `clk_i`), `5.0 ns` input delay on all non-clock inputs (`set_input_delay 5.0 -clock clk_i`), and `4.0 ns` output delay on all outputs (`set_output_delay 4.0 -clock clk_i`), using Nangate45 typical Liberty and OpenROAD/OpenSTA. No other timing exceptions are applied. All delays are in `ns`.

---

## 4. Reference Fix Inspection (Buggy Starter vs. Golden Solution Diff)

> Human reviewers can inspect the exact reference bug fix below, or browse full files in [`environment/public/`](environment/public/), [`solution/gold/`](solution/gold/), and [`solution/alternate_gold/`](solution/alternate_gold/).

<details open>
<summary><b>Click to expand/collapse Unified Diff (<code>environment/public/</code> vs. <code>solution/gold/</code>)</b></summary>

```diff
--- a/environment/public/code/axi4_to_ahb.sv (Buggy Starter)
+++ b/solution/gold/code/axi4_to_ahb.sv (Golden Reference)
@@ -259,7 +259,7 @@
    assign wrbuf_en       = axi_awvalid & axi_awready & master_ready;
    assign wrbuf_data_en  = axi_wvalid & axi_wready & master_ready;
    assign wrbuf_cmd_sent = master_valid & master_ready & (master_opc[2:1] == 2'b01);
-   assign wrbuf_rst      = (wrbuf_cmd_sent & ~wrbuf_en);
+   assign wrbuf_rst      = (wrbuf_cmd_sent & ~wrbuf_en) | dec_tlu_force_halt_bus[wrbuf_tag[TAG-1]];
 
    assign axi_awready = ~(wrbuf_vld & ~wrbuf_cmd_sent) & master_ready;
    assign axi_wready  = ~(wrbuf_data_vld & ~wrbuf_cmd_sent) & master_ready;
@@ -358,7 +358,7 @@
                   buf_nxtstate   = DONE;
                   buf_state_en   = (ahb_hready_q | ahb_hresp_q);
                   buf_data_wr_en = buf_state_en;
-                  slvbuf_error_in= 1'b0;
+                  slvbuf_error_in= ahb_hresp_q;
                   slvbuf_error_en= buf_state_en;
                   slvbuf_wr_en   = buf_state_en;
 
@@ -408,7 +408,7 @@
       endcase
    end
 
-   assign buf_rst              = 1'b0;
+   assign buf_rst              = dec_tlu_force_halt_bus[buf_tag[TAG-1]];
    assign cmd_done_rst         = slave_valid_pre;
 
    assign buf_addr_in[pt.XLEN-1:BUS_ADDR_OFF]  = master_addr[pt.XLEN-1:BUS_ADDR_OFF];
@@ -469,7 +469,7 @@
 
    assign slave_valid          = slave_valid_pre;// & (~slvbuf_posted_write | slvbuf_error);
    assign slave_opc[3:2]       = slvbuf_write ? 2'b11 : 2'b00;
-   assign slave_opc[1:0]       = {2{slvbuf_error}} & 2'b10;
+   assign slave_opc[1:0]       = {2{slvbuf_error}} & 2'b01;
    assign slave_rdata[BUS_WIDTH-1:0] = slvbuf_error ? {2{last_bus_addr[pt.XLEN-1:0]}} : ((buf_state == DONE) ? buf_data[BUS_WIDTH-1:0] : ahb_hrdata_q[BUS_WIDTH-1:0]);
    assign slave_tag[TAG-1:0]   = slvbuf_tag[TAG-1:0];
 

--- a/environment/public/code/ahb_to_axi4.sv (Buggy Starter)
+++ b/solution/gold/code/ahb_to_axi4.sv (Golden Reference)
@@ -161,7 +161,7 @@
                  buf_nxtstate      = IDLE;                                                          // go back for next command and present data next cycle
                  buf_state_en      = axi_rvalid & ~cmdbuf_write;                                    // read data is back
                  buf_rdata_en      = buf_state_en;                                                  // buffer the read data coming back from core
-                 buf_read_error_in = 1'b0;                                // buffer error flag if return has Error ( ECC )
+                 buf_read_error_in = buf_state_en & |axi_rresp[1:0];                                // buffer error flag if return has Error ( ECC )
          end
      endcase
    end // always_comb begin
@@ -174,7 +174,8 @@
                                                    ({BUS_BYTES{ahb_hsize_q[2:0] == 3'b011}} & ((BUS_BYTES)'('b1111_1111) << ahb_haddr_q[BUS_ADDR_OFF-1:0])) |
                                                    ({BUS_BYTES{(ahb_hsize_q[2:0] == 3'b100) & (BUS_WIDTH == 128)}} & {BUS_BYTES{1'b1}}) ;
    // AHB signals
-   assign ahb_hreadyout       = ((~cmdbuf_full | (buf_state == IDLE)) & ~(buf_state == RD | buf_state == PEND)  & ~buf_read_error);
+   assign ahb_hreadyout       = ahb_hresp ? (ahb_hresp_q & ~ahb_hready_q) :
+                                         ((~cmdbuf_full | (buf_state == IDLE)) & ~(buf_state == RD | buf_state == PEND)  & ~buf_read_error);
 
    assign ahb_hready                   = ahb_hreadyout & ahb_hreadyin;
    assign ahb_htrans_in[1:0]           = {2{ahb_hsel}} & ahb_htrans[1:0];
@@ -229,7 +230,7 @@
    end
 
    // Command Buffer - Holding for the commands to be sent for the AXI. It will be converted to the AXI signals.
-   assign cmdbuf_rst         = (((axi_awvalid & axi_awready) | (axi_arvalid & axi_arready)) & ~cmdbuf_wr_en);
+   assign cmdbuf_rst         = (((axi_awvalid & axi_awready) | (axi_arvalid & axi_arready)) & ~cmdbuf_wr_en) | (ahb_hresp & ~cmdbuf_write);
    assign cmdbuf_full        = (cmdbuf_vld & ~((axi_awvalid & axi_awready) | (axi_arvalid & axi_arready)));
 
    rvdffsc_fpga #(.WIDTH(1))                 cmdbuf_vldff      (.din(1'b1),              .dout(cmdbuf_vld),         .en(cmdbuf_wr_en), .clear(cmdbuf_rst), .clk(bus_clk), .clken(bus_clk_en), .rawclk(clk), .*);

--- a/environment/public/constraints.json (Buggy Starter)
+++ b/solution/gold/constraints.json (Golden Reference)
@@ -1,3 +1,22 @@
 {
-  "max_delays": []
+  "max_delays": [
+    {
+      "from": [
+        "qos_in"
+      ],
+      "to": [
+        "qos_out"
+      ],
+      "ns": 10.75
+    },
+    {
+      "from": [
+        "region_in"
+      ],
+      "to": [
+        "region_out"
+      ],
+      "ns": 11.75
+    }
+  ]
 }

```

</details>

---

## 5. Harbor Package File Inventory & Provenance

### Public Workspace (`environment/public/`)
- [`environment/public/BUILD.md`](environment/public/BUILD.md) *(Read-Only Context)*
- [`environment/public/code/LICENSE`](environment/public/code/LICENSE) *(Read-Only Context)*
- [`environment/public/code/ahb_to_axi4.sv`](environment/public/code/ahb_to_axi4.sv) **(Editable)**
- [`environment/public/code/axi4_to_ahb.sv`](environment/public/code/axi4_to_ahb.sv) **(Editable)**
- [`environment/public/code/beh_lib.sv`](environment/public/code/beh_lib.sv) *(Read-Only Context)*
- [`environment/public/code/common_defines.vh`](environment/public/code/common_defines.vh) *(Read-Only Context)*
- [`environment/public/code/eh2_def.sv`](environment/public/code/eh2_def.sv) *(Read-Only Context)*
- [`environment/public/code/eh2_lib.sv`](environment/public/code/eh2_lib.sv) *(Read-Only Context)*
- [`environment/public/code/eh2_param.vh`](environment/public/code/eh2_param.vh) *(Read-Only Context)*
- [`environment/public/code/eh2_pdef.vh`](environment/public/code/eh2_pdef.vh) *(Read-Only Context)*
- [`environment/public/code/top.sv`](environment/public/code/top.sv) *(Read-Only Context)*
- [`environment/public/constraints.json`](environment/public/constraints.json) **(Editable)**
- [`environment/public/issue.md`](environment/public/issue.md) *(Read-Only Context)*

### Reference Solutions & Isolated Verifier (`solution/` & `tests/`)
- [`solution/solve.sh`](solution/solve.sh) — Harbor oracle script
- [`solution/gold/`](solution/gold/) — Primary golden reference solution
- [`solution/alternate_gold/`](solution/alternate_gold/) — Structurally distinct secondary reference solution
- [`tests/test.sh`](tests/test.sh) — Isolated Harbor verifier entrypoint
- [`tests/private/policy_filter.py`](tests/private/policy_filter.py) — Pre-grader airlock & anti-cheat policy screen
- [`tests/private/grader/run.py`](tests/private/grader/run.py) — Deterministic front-to-back EDA verifier

### Upstream Provenance (`SOURCE.md`)

