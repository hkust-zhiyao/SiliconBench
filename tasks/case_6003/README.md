# `case_6003`: VeeR-EH1 LSU AXI4-to-AHB Bridge, DMA AHB-to-AXI4 Slave Gasket, 4-Entry DMA/Debug Controller, and Transparent Sideband Timing Closure

[Back to Benchmark Root (`README.md`)](../../README.md) | [Full 94-Task Catalog (`TASKS_INDEX.md`)](../../TASKS_INDEX.md) | [`task.toml`](task.toml) | [`instruction.md`](instruction.md) | [`solution/solve.sh`](solution/solve.sh) | [`tests/test.sh`](tests/test.sh) | [`tests/private/grader/run.py`](tests/private/grader/run.py)

---

## 1. Task Overview & Harbor Configuration

| Field | Value |
| :--- | :--- |
| **Task ID** | `case_6003` |
| **Source Silicon Repository** | `chipsalliance/cores-veer-eh1` (`repo_06`) |
| **Engineering Problem Type** | **High-Frequency Timing & Area Optimization** (`PT3_Timing_Area_PPA_Closure`) |
| **EDA Evaluation Stage** | **Stage 3: Static Timing (STA) & CDC/RDC Closure** (`stage3_sta_cdc`) |
| **Coupled Evaluation Gates** | Stage 1 (Functional RTL Sim) -> Stage 2 (Logic Synthesis & Gate-Level Verification) -> Stage 3 (OpenSTA Single-/Multi-Corner Setup/Hold WNS/TNS & CDC/RDC Closure) |
| **Primary Hardware Domain** | `rtl_integration` (Multi-Module Reuse, Port Contracts, Interfaces & Subsystem Integration) |
| **Multi-Domain Tags** | `protocol_control`, `rtl_integration`, `sdc_sta`, `verification_debug` |
| **Editable Files (`allowed_edits`)** | [`code/axi4_to_ahb.sv`](environment/public/code/axi4_to_ahb.sv), [`code/ahb_to_axi4.sv`](environment/public/code/ahb_to_axi4.sv), [`code/dma_ctrl.sv`](environment/public/code/dma_ctrl.sv), [`constraints.json`](environment/public/constraints.json) (4 files, 1483 LOC) |
| **Public Subsystem Context** | 8 RTL files (2927 LOC) |
| **Base Container Image** | `siliconbench-eda:1.0` (`allow_internet = false`, `environment_mode = "separate"`) |
| **PDK / Environment Profile** | **Nangate45 45nm Open Cell Library + Task Multi-Corner Liberty/SDC** |
| **Task-Customized Collateral?** | **Yes (Task-Bundled Collateral)** — Uses shared Nangate45 library for synthesis plus task-bundled fast/slow/scan corner timing views. |
| **Verifier Timeout & Seeds** | `960s` total (`480s`/seed) across deterministic seeds `[101, 202]` |

---

## 2. Problem Specification (`issue.md`)

# VeeR-EH1 LSU AXI4-to-AHB Bridge, DMA AHB-to-AXI4 Slave Gasket, 4-Entry DMA/Debug Controller, and Transparent Sideband Timing Closure

In `code/veer_bus_dma_top.sv`, the core LSU AXI4-to-AHB-Lite master bridge (`code/axi4_to_ahb.sv`), the external DMA AHB-Lite-to-AXI4 slave gasket (`code/ahb_to_axi4.sv`), the 4-entry DMA and abstract debug memory controller (`code/dma_ctrl.sv`), and two zero-cut transparent 8-bit sideband pass-through channels (`qos_in` to `qos_out` and `region_in` to `region_out`) are integrated together.

Update only `code/axi4_to_ahb.sv`, `code/ahb_to_axi4.sv`, `code/dma_ctrl.sv`, and `constraints.json` to satisfy all functional, synthesis, and static timing contracts:

1. **LSU AXI4-to-AHB-Lite Master Bridge (`code/axi4_to_ahb.sv`)**:
   - Translate 64-bit AXI4 read and write requests into AHB-Lite `NONSEQ` (`2'b10`) transactions. Aligned byte, halfword, word, and contiguous sub-dword writes (`8'hff`, `8'hf0`, `8'h0f`, `8'hc0`, `8'h30`, `8'h0c`, `8'h03`) must issue as a single AHB transfer with the matching transfer size and byte offset (`0, 2, 4, 6`), while unaligned or sparse 64-bit writes must walk only the asserted byte lanes in ascending byte order (`0..7`) using single-byte (`3'h0`) AHB beats and terminate immediately after the highest asserted byte lane completes.
   - Support back-to-back streaming AXI reads without dead cycles when no write is pending. When `lsu_ahb_hresp` is asserted during a single read, a streaming read beat, or a write data phase, complete the pending AHB phase cleanly, return an AXI error response (`lsu_axi_rresp[1] == 1'b1` or `lsu_axi_bresp[1] == 1'b1`) on the corresponding response channel, and drive the last active AHB write bus address replicated across both 32-bit halves of `lsu_axi_rdata` for errored reads.

2. **DMA AHB-Lite-to-AXI4 Slave Gasket (`code/ahb_to_axi4.sv`)**:
   - Accept AHB-Lite slave transactions targeting DCCM (`[0xf0040000, 0xf004ffff]`) or ICCM (`[0xee000000, 0xee07ffff]`). Any transfer outside DCCM and ICCM, any ICCM read/write or DCCM write that is not 32-bit (`3'h2`) or 64-bit (`3'h3`), any size-unaligned address, or any downstream AXI read response error must assert the two-cycle AHB-Lite error response (`dma_ahb_hresp = 1'b1` with `dma_ahb_hreadyout = 1'b0` on the first bus-clock cycle and `dma_ahb_hreadyout = 1'b1` on the second) while clearing any pending read command in the gasket buffer.

3. **4-Entry Core DMA & Abstract Debug Memory Controller (`code/dma_ctrl.sv`)**:
   - Arbitrate between buffered AXI write and read requests with alternating priority whenever both buffers are valid. Normalize 64-bit AXI writes carrying a single 32-bit word strobe (`8'h0f` or `8'hf0`) into 32-bit word core requests (`dma_mem_sz = 3'h2`, advancing address bit `[2]` when `wstrb == 8'hf0`), and record address or size/strobe alignment errors in the FIFO without issuing a core memory request (returning `SLVERR = 2'b10` on alignment or ECC errors and `DECERR = 2'b11` on address decode errors).
   - Count consecutive cycles where a valid head FIFO memory request is not granted by `dccm_ready` / `iccm_ready`; once the count reaches `dec_tlu_dma_qos_prty`, assert and hold `dma_dccm_stall_any` / `dma_iccm_stall_any` until the request is accepted. Support abstract debug memory accesses (`dbg_cmd_valid` with `dbg_cmd_type == 2'b10` to DCCM, ICCM, or PIC `[0xf00c0000, 0xf00c7fff]`) when the FIFO is empty and `dbg_dma_bubble` is asserted, extracting the addressed byte, halfword, or word from the selected 32-bit half of the 64-bit read data (`dma_dbg_rddata`).

4. **Declarative Timing Constraints (`constraints.json`) & Synthesis QoR**:
   - In `veer_bus_dma_top`, `clk` operates at `5.60 ns` and `6.00 ns` periods with a `2.50 ns` external input delay on all non-clock inputs and a `2.00 ns` external output delay on all outputs. Keep the clock and existing I/O delays on all ports, and update `constraints.json` (`"max_delays"`) using the schema in `BUILD.md` so that the maximum internal input-to-output combinational delay is `1.65 ns` for `qos_in` to `qos_out` and `2.45 ns` for `region_in` to `region_out`, while preserving the registered timing constraints on all bridge and DMA ports.
   - The RTL must synthesize without latches, achieve mapped cell area `<= 12,350.0 um^2`, and meet `WNS >= 0.00 ns` and `WHS >= 0.00 ns` on all registered timing paths.

---

## 3. Build & Verification Instructions (`BUILD.md`)

# Build, Simulation, Synthesis, and Static Timing Guide (`veer_bus_dma_top`)

## 1. Editable Files
Only the following four files are collected and graded:
- `code/axi4_to_ahb.sv`
- `code/ahb_to_axi4.sv`
- `code/dma_ctrl.sv`
- `constraints.json`

All other files in `code/` (`code/veer_bus_dma_top.sv`, `code/common_defines.vh`, `code/global.h`, `code/veer_types.sv`, `code/beh_lib.sv`, `code/LICENSE`) and `lib/` are read-only and must remain unmodified.

## 2. Functional Simulation (`Verilator`)
```bash
verilator \
  --binary --timing -j 1 -Wno-fatal -Icode \
  --top-module <your_tb> --Mdir obj_dir \
  code/common_defines.vh code/veer_types.sv code/beh_lib.sv \
  code/axi4_to_ahb.sv code/ahb_to_axi4.sv code/dma_ctrl.sv \
  code/veer_bus_dma_top.sv <your_tb.sv>
./obj_dir/V<your_tb>
```

## 3. Synthesis & Declarative Timing Constraints (`Yosys/Slang` + `OpenROAD/OpenSTA`)
1. **Synthesis (`Yosys/Slang`)**:
   ```bash
   yosys -m slang -p "
     read_slang --single-unit --top veer_bus_dma_top -Icode \
       code/common_defines.vh code/veer_types.sv code/beh_lib.sv \
       code/axi4_to_ahb.sv code/ahb_to_axi4.sv code/dma_ctrl.sv code/veer_bus_dma_top.sv;
     hierarchy -check -top veer_bus_dma_top;
     proc;
     select -assert-none */t:\$dlatch* */t:\$adlatch* */t:\$latch* */t:\$sr* */t:\$_DLATCH*;
     opt_clean;
     select -assert-none */t:\$dlatch* */t:\$adlatch* */t:\$latch* */t:\$sr* */t:\$_DLATCH*;
     synth -top veer_bus_dma_top;
     opt;
     dfflibmap -liberty lib/NangateOpenCellLibrary_typical.lib;
     abc -liberty lib/NangateOpenCellLibrary_typical.lib;
     clean;
     read_liberty -lib lib/NangateOpenCellLibrary_typical.lib;
     check -assert;
     stat -liberty lib/NangateOpenCellLibrary_typical.lib;
     write_verilog -noattr mapped.v
   "
   ```

2. **Declarative Timing Constraints (`constraints.json`) & Static Timing Analysis (`OpenROAD`)**:
   - `constraints.json` has a single top-level key `"max_delays"`, which is a list of rule objects `{"from": [...], "to": [...], "ns": <float>}`.
   - Allowed input port groups in `"from"` are the non-clock input port names of `veer_bus_dma_top` (or bit-indexed `qos_in[0..7]`, `region_in[0..7]`).
   - Allowed output port groups in `"to"` are the output port names of `veer_bus_dma_top` (or bit-indexed `qos_out[0..7]`, `region_out[0..7]`).
   - A group name without bit index selects all bits of that port. Each rule object is translated to:
     `set_max_delay <ns> -from [get_ports {...}] -to [get_ports {...}]`
   - The STA flow retains the clock (`5.60 ns` or `6.00 ns` on `clk`), `set_input_delay 2.50 -clock clk [all_inputs -no_clocks]`, `set_output_delay 2.00 -clock clk [all_outputs]`, `set_load 5.0 [all_outputs]`, and `set_false_path -from [get_ports {rst_l scan_mode}]`. All delays are in `ns`.

---

## 4. Reference Fix Inspection (Buggy Starter vs. Golden Solution Diff)

> Human reviewers can inspect the exact reference bug fix below, or browse full files in [`environment/public/`](environment/public/), [`solution/gold/`](solution/gold/), and [`solution/alternate_gold/`](solution/alternate_gold/).

<details open>
<summary><b>Click to expand/collapse Unified Diff (<code>environment/public/</code> vs. <code>solution/gold/</code>)</b></summary>

```diff
--- a/environment/public/code/axi4_to_ahb.sv (Buggy Starter)
+++ b/solution/gold/code/axi4_to_ahb.sv (Golden Reference)
@@ -180,7 +180,7 @@
       logic [1:0]       size;
 
       size[1:0] = (2'b11 & {2{(byteen[7:0] == 8'hff)}}) |
-                  (2'b10 & {2{(byteen[7:0] == 8'h0f)}}) |
+                  (2'b10 & {2{((byteen[7:0] == 8'hf0) | (byteen[7:0] == 8'h0f))}}) |
                   (2'b01 & {2{((byteen[7:0] == 8'hc0) | (byteen[7:0] == 8'h30) | (byteen[7:0] == 8'h0c) | (byteen[7:0] == 8'h03))}});
 
       return size[1:0];
@@ -206,7 +206,7 @@
       logic       found;
       found = '0;
       //get_nxtbyte_ptr[2:0] = current_byte_ptr[2:0];
-      start_ptr[2:0] = current_byte_ptr[2:0];
+      start_ptr[2:0] = get_next ? (current_byte_ptr[2:0] + 3'b1) : current_byte_ptr[2:0];
       for (int j=0; j<8; j++) begin
          if (~found) begin
             get_nxtbyte_ptr[2:0] = 3'(j);
@@ -314,7 +314,7 @@
          STREAM_RD: begin
                   master_ready  =  (ahb_hready_q & ~ahb_hresp_q) & ~(master_valid & master_opc[2:1] == 2'b01);
                   buf_wr_en       = (master_valid & master_ready & (master_opc[2:0] == 3'b000)); // update the fifo if we are streaming the read commands
-                  buf_nxtstate    = buf_wr_en ? STREAM_RD : DATA_RD;            // assuming that the master accpets the slave response right away.
+                  buf_nxtstate    = ahb_hresp_q ? STREAM_ERR_RD : (buf_wr_en ? STREAM_RD : DATA_RD);            // assuming that the master accpets the slave response right away.
                   buf_state_en    = (ahb_hready_q | ahb_hresp_q);
                   buf_data_wr_en  = buf_state_en;
                   slvbuf_error_in = ahb_hresp_q;
@@ -349,7 +349,8 @@
                   buf_cmd_byte_ptr_en = buf_state_en;
                   slvbuf_wr_en    = buf_state_en;
                   buf_cmd_byte_ptr    = trxn_done ? get_nxtbyte_ptr(buf_cmd_byte_ptrQ[2:0],buf_byteen[7:0],1'b1) : buf_cmd_byte_ptrQ;
-                  cmd_done            = trxn_done & (buf_aligned | (buf_cmd_byte_ptrQ == 3'b111));
+                  cmd_done            = trxn_done & (buf_aligned | (buf_cmd_byte_ptrQ == 3'b111) |
+                                                     (buf_byteen[get_nxtbyte_ptr(buf_cmd_byte_ptrQ[2:0],buf_byteen[7:0],1'b1)] == 1'b0));
                   ahb_htrans[1:0] = {2{~(cmd_done | cmd_doneQ)}} & 2'b10;
          end
          DATA_WR: begin
@@ -364,7 +365,8 @@
                   buf_wr_en = buf_state_en & ((buf_nxtstate == CMD_WR) | (buf_nxtstate == CMD_RD));
                   buf_data_wr_en = buf_wr_en;
 
-                  cmd_done     = (ahb_hresp_q | (ahb_hready_q & (ahb_htrans_q[1:0] != 2'b0) & (buf_cmd_byte_ptrQ == 3'b111)));
+                  cmd_done     = (ahb_hresp_q | (ahb_hready_q & (ahb_htrans_q[1:0] != 2'b0) &
+                                 ((buf_cmd_byte_ptrQ == 3'b111) | (buf_byteen[get_nxtbyte_ptr(buf_cmd_byte_ptrQ[2:0],buf_byteen[7:0],1'b1)] == 1'b0))));
                   bypass_en       = buf_state_en & buf_write_in & (buf_nxtstate == CMD_WR);   // Only bypass for writes for the time being
                   ahb_htrans[1:0] = {2{(~(cmd_done | cmd_doneQ) | bypass_en)}} & 2'b10;
                   slave_valid_pre  = buf_state_en & (buf_nxtstate != DONE);
@@ -411,7 +413,7 @@
    assign slave_valid          = slave_valid_pre;
    assign slave_opc[3:2]       = slvbuf_write ? 2'b11 : 2'b00;
    assign slave_opc[1:0]       = {2{slvbuf_error}} & 2'b10;
-   assign slave_rdata[63:0]    = (buf_state == DONE) ? buf_data[63:0] : ahb_hrdata_q[63:0];
+   assign slave_rdata[63:0]    = slvbuf_error ? {2{last_bus_addr[31:0]}} : ((buf_state == DONE) ? buf_data[63:0] : ahb_hrdata_q[63:0]);
    assign slave_tag[TAG-1:0]   = slvbuf_tag[TAG-1:0];
 
    assign last_addr_en = (ahb_htrans[1:0] != 2'b0) & ahb_hready & ahb_hwrite ;

--- a/environment/public/code/ahb_to_axi4.sv (Buggy Starter)
+++ b/solution/gold/code/ahb_to_axi4.sv (Golden Reference)
@@ -164,7 +164,7 @@
                                 ({8{ahb_hsize_q[2:0] == 3'b11}} & 8'b1111_1111);
 
    // AHB signals
-   assign ahb_hreadyout       = ahb_hresp ? 1'b1 :
+   assign ahb_hreadyout       = ahb_hresp ? (ahb_hresp_q & ~ahb_hready_q) :
                                          ((~cmdbuf_full | (buf_state == IDLE)) & ~(buf_state == RD | buf_state == PEND)  & ~buf_read_error);
 
    assign ahb_hready          = ahb_hreadyout & ahb_hreadyin;
@@ -174,8 +174,10 @@
                              ((~(ahb_addr_in_dccm | ahb_addr_in_iccm)) |                                                                                   // request not for ICCM or DCCM
                              ((ahb_addr_in_iccm | (ahb_addr_in_dccm &  ahb_hwrite_q)) & ~((ahb_hsize_q[1:0] == 2'b10) | (ahb_hsize_q[1:0] == 2'b11))) |    // ICCM Rd/Wr OR DCCM Wr not the right size
                              ((ahb_hsize_q[2:0] == 3'h1) & ahb_haddr_q[0])   |                                                                             // HW size but unaligned
-                             1'b0)) |
-                             buf_read_error;                                                                                                // This is for second cycle of hresp protocol
+                             ((ahb_hsize_q[2:0] == 3'h2) & (|ahb_haddr_q[1:0])) |                                                                          // W size but unaligned
+                             ((ahb_hsize_q[2:0] == 3'h3) & (|ahb_haddr_q[2:0])))) |                                                                        // DW size but unaligned
+                             buf_read_error |                                                                                                              // Read ECC error
+                             (ahb_hresp_q & ~ahb_hready_q);                                                                                                // This is for second cycle of hresp protocol
 
     // Buffer signals - needed for the read data and ECC error response
 
@@ -238,7 +240,7 @@
    );
 
    // Command Buffer - Holding for the commands to be sent for the AXI. It will be converted to the AXI signals.
-   assign cmdbuf_rst         = (((axi_awvalid & axi_awready) | (axi_arvalid & axi_arready)) & ~cmdbuf_wr_en);
+   assign cmdbuf_rst         = (((axi_awvalid & axi_awready) | (axi_arvalid & axi_arready)) & ~cmdbuf_wr_en) | (ahb_hresp & ~cmdbuf_write);
    assign cmdbuf_full        = (cmdbuf_vld & ~((axi_awvalid & axi_awready) | (axi_arvalid & axi_arready)));
 
    rvdffsc_fpga #(.WIDTH(1))   cmdbuf_vldff      (.din(1'b1), .clear(cmdbuf_rst), .dout(cmdbuf_vld),        .en(cmdbuf_wr_en), .clk(bus_clk), .clken(bus_clk_en), .rawclk(clk), .*);

--- a/environment/public/code/dma_ctrl.sv (Buggy Starter)
+++ b/solution/gold/code/dma_ctrl.sv (Golden Reference)
@@ -238,8 +238,8 @@
    //------------------------LOGIC STARTS HERE---------------------------------
 
    // FIFO inputs
-   assign fifo_addr_in[31:0]    = dbg_cmd_valid ? dbg_cmd_addr[31:0] : axi_mstr_addr[31:0];
-   assign fifo_sz_in[2:0]       = dbg_cmd_valid ? {1'b0,dbg_cmd_size[1:0]} : axi_mstr_size[2:0];
+   assign fifo_addr_in[31:0]    = dbg_cmd_valid ? dbg_cmd_addr[31:0] : (axi_mstr_write & (axi_mstr_wstrb[7:0] == 8'hf0)) ? {axi_mstr_addr[31:3],1'b1,axi_mstr_addr[1:0]} : axi_mstr_addr[31:0];
+   assign fifo_sz_in[2:0]       = dbg_cmd_valid ? {1'b0,dbg_cmd_size[1:0]} : (axi_mstr_write & ((axi_mstr_wstrb[7:0] == 8'h0f) | (axi_mstr_wstrb[7:0] == 8'hf0))) ? 3'h2 : axi_mstr_size[2:0];
    assign fifo_write_in         = dbg_cmd_valid ? dbg_cmd_write : axi_mstr_write;
    assign fifo_posted_write_in  = axi_mstr_valid & axi_mstr_posted_write;
    assign fifo_dbg_in           = dbg_cmd_valid;
@@ -332,7 +332,7 @@
 
    assign dma_dbg_sz[1:0]          = fifo_sz[RspPtr][1:0];
    assign dma_dbg_addr[1:0]        = fifo_addr[RspPtr][1:0];
-   assign dma_dbg_mem_rddata[31:0] = fifo_data[RspPtr][31:0];
+   assign dma_dbg_mem_rddata[31:0] = fifo_addr[RspPtr][2] ? fifo_data[RspPtr][63:32] : fifo_data[RspPtr][31:0];
    assign dma_dbg_rddata[31:0]     = ({32{(dma_dbg_sz[1:0] == 2'h0)}} & ((dma_dbg_mem_rddata[31:0] >> 8*dma_dbg_addr[1:0]) & 32'hff)) |
                                      ({32{(dma_dbg_sz[1:0] == 2'h1)}} & ((dma_dbg_mem_rddata[31:0] >> 16*dma_dbg_addr[1]) & 32'hffff)) |
                                      ({32{(dma_dbg_sz[1:0] == 2'h2)}} & dma_dbg_mem_rddata[31:0]);
@@ -355,7 +355,7 @@
 
    // Nack counter, stall the lsu pipe if 7 nacks
    assign dma_nack_count_csr[2:0] = dec_tlu_dma_qos_prty[2:0];
-   assign dma_nack_count_d[2:0] = (dma_nack_count[2:0] >= dma_nack_count_csr[2:0]) ? 3'b0 :
+   assign dma_nack_count_d[2:0] = (dma_nack_count[2:0] >= dma_nack_count_csr[2:0]) ? ({3{~(dma_dccm_req | dma_iccm_req)}} & dma_nack_count[2:0]) :
                                                                                     (dma_mem_req & ~(dma_dccm_req | dma_iccm_req)) ? (dma_nack_count[2:0] + 1'b1) : 3'b0;
 
    rvdffs #(3) nack_count_dff(.din(dma_nack_count_d[2:0]), .dout(dma_nack_count[2:0]), .en(dma_mem_req), .clk(dma_free_clk), .*);
@@ -466,7 +466,7 @@
    assign axi_mstr_wstrb[7:0]             = wrbuf_byteen[7:0];
 
    // Sel=1 -> write has higher priority
-   assign axi_mstr_sel     = (wrbuf_vld & wrbuf_data_vld);
+   assign axi_mstr_sel     = (wrbuf_vld & wrbuf_data_vld & rdbuf_vld) ? axi_mstr_priority : (wrbuf_vld & wrbuf_data_vld);
    assign axi_mstr_prty_in = ~axi_mstr_priority;
    assign axi_mstr_prty_en = axi_mstr_valid;
 

--- a/environment/public/constraints.json (Buggy Starter)
+++ b/solution/gold/constraints.json (Golden Reference)
@@ -1,3 +1,14 @@
 {
-  "max_delays": []
+  "max_delays": [
+    {
+      "from": ["qos_in"],
+      "to": ["qos_out"],
+      "ns": 6.15
+    },
+    {
+      "from": ["region_in"],
+      "to": ["region_out"],
+      "ns": 6.95
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
- [`environment/public/code/dma_ctrl.sv`](environment/public/code/dma_ctrl.sv) **(Editable)**
- [`environment/public/code/global.h`](environment/public/code/global.h) *(Read-Only Context)*
- [`environment/public/code/veer_bus_dma_top.sv`](environment/public/code/veer_bus_dma_top.sv) *(Read-Only Context)*
- [`environment/public/code/veer_types.sv`](environment/public/code/veer_types.sv) *(Read-Only Context)*
- [`environment/public/constraints.json`](environment/public/constraints.json) **(Editable)**
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

