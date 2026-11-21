# `case_0033`: BSG Manycore Tile Memory Interface Stall Lock, Flush Cancellation, and PPA/STA Closure

[Back to Benchmark Root (`README.md`)](../../README.md) | [Full 94-Task Catalog (`TASKS_INDEX.md`)](../../TASKS_INDEX.md) | [`task.toml`](task.toml) | [`instruction.md`](instruction.md) | [`solution/solve.sh`](solution/solve.sh) | [`tests/test.sh`](tests/test.sh) | [`tests/private/grader/run.py`](tests/private/grader/run.py)

---

## 1. Task Overview & Harbor Configuration

| Field | Value |
| :--- | :--- |
| **Task ID** | `case_0033` |
| **Source Silicon Repository** | `bespoke-silicon-group/bsg_manycore` (`repo_11`) |
| **Engineering Problem Type** | **Architectural & Protocol Bug Repair** (`PT1_Arch_Protocol_Bug_Repair`) |
| **EDA Evaluation Stage** | **Stage 4: Hard-SRAM Floorplanning, CTS & Routing (PnR)** (`stage4_macro_pnr`) |
| **Coupled Evaluation Gates** | Stage 1 (Functional RTL Sim) -> Stage 2 (Hard-SRAM Macro Synthesis) -> Stage 3 (Multi-Corner STA) -> Stage 4 (OpenROAD Macro Floorplanning, PDN, CTS & Routing) |
| **Primary Hardware Domain** | `synthesis_qor` (Logic Synthesis, Resource Sharing, Retiming, Structuring & Area/Delay QoR) |
| **Multi-Domain Tags** | `reset_rdc`, `rtl_integration`, `synthesis_qor` |
| **Editable Files (`allowed_edits`)** | [`code/lsu.sv`](environment/public/code/lsu.sv), [`code/network_tx.sv`](environment/public/code/network_tx.sv), [`code/bsg_manycore_endpoint_standard.sv`](environment/public/code/bsg_manycore_endpoint_standard.sv) (3 files, 571 LOC) |
| **Public Subsystem Context** | 25 RTL files (3175 LOC) |
| **Base Container Image** | `siliconbench-eda:1.0` (`allow_internet = false`, `environment_mode = "separate"`) |
| **PDK / Environment Profile** | **Nangate45 45nm Open Cell Library + Task Multi-Corner Liberty/SDC** |
| **Task-Customized Collateral?** | **Yes (Task-Bundled Collateral)** — Uses shared Nangate45 library for synthesis plus task-bundled fast/slow/scan corner timing views. |
| **Verifier Timeout & Seeds** | `1200s` total (`600s`/seed) across deterministic seeds `[1, 2]` |

---

## 2. Problem Specification (`issue.md`)

# BSG Manycore Tile Memory Interface Stall Lock, Flush Cancellation, and PPA/STA Closure

In `code/bsg_manycore_tile_mem_if.sv`, update `code/lsu.sv`, `code/network_tx.sv`, and `code/bsg_manycore_endpoint_standard.sv` to fix address-generation, stall-lock, flush, and response-serialization defects. In `lsu`, `icache_miss_i` must issue a remote word-load fetch (`icache_fetch == 1`, `write_not_read == 0`, `is_amo_op == 0`, `is_uncached_op == 0`, `mask == 4'b1111`, `addr == (pc_plus4_i - 32'd4) | 32'h8000_0000`) while suppressing `dmem_v_o`, `dmem_w_o`, and `reserve_o`; when `exe_decode_i.is_uncached_op` is high on a load/store/AMO (including addresses with `addr[31:12] == 20'h0_0000`, e.g., `0x0000_0100`), it must route to the network (`remote_req_v_o == 1`, `remote_req_o.is_uncached_op == 1`, `load_info.part_sel == 2'b00`) and never assert `dmem_v_o` or `reserve_o`. In `network_tx`, any valid outgoing request (`remote_req_v_i && !invalid_eva_access_o && !flush_i`) stalled by `out_credit_or_ready_i == 0` must hold `out_v_o` and `out_packet_o` invariant across `clk_i` edges (keeping `remote_req_credit_o == 0` and `invalid_eva_access_o == 0` while held, including on the cycle `out_credit_or_ready_i == 1` accepts the held packet) until drained on the accepting clock edge or cleared by `reset_i` or `flush_i`; `flush_i` must immediately force `out_v_o == 0` and `invalid_eva_access_o == 0` and cancel any held request, and `returned_yumi_o` must assert only when `returned_v_i` is high. In `bsg_manycore_endpoint_standard`, after `in_v_o && in_yumi_i`, suppress `in_v_o` until `returning_v_i` asserts (allowing same-cycle handoff when `returning_v_i` is high), ignore `returning_v_i` when idle, return the prior lock bit on `e_remote_amoswap`, and advance `out_credits_used_o` only on accepted outgoing packets (`out_v_i && out_credit_or_ready_o`).

Under the Nangate45 Yosys/Slang flow (`BUILD.md`), `bsg_manycore_tile_mem_if` must map to `<= 3,665.0 um^2`, and OpenROAD STA must achieve setup and hold slack `>= 0.0 ns` at a `2.33 ns` `clk_i` period (`0.20 ns` input delay, `0.40 ns` output delay, `5.0 fF` load). Edit only `code/lsu.sv`, `code/network_tx.sv`, and `code/bsg_manycore_endpoint_standard.sv`.

---

## 3. Build & Verification Instructions (`BUILD.md`)

# Build, Simulation, Synthesis, and Timing Evaluation Guide

## 1. Repository Layout and Editable Scope

- `code/lsu.sv`: BSG Manycore Vanilla Bean load-store address generator and local/remote classifier (**editable target**).
- `code/network_tx.sv`: Outgoing network packet builder, EVA-to-NPA wrapper, and return packet demultiplexer (**editable target**).
- `code/bsg_manycore_endpoint_standard.sv`: Standard manycore tile endpoint controller (**editable target**).
- `code/bsg_manycore_tile_mem_if.sv`: Top-level tile memory interface integration wrapper (read-only).
- `code/bsg_*.sv`, `code/bsg_*.svh`: Upstream BSG Manycore and BaseJump STL packages and dependencies (read-only).
- `lib/`: Nangate45 typical Liberty (`NangateOpenCellLibrary_typical.lib`) and LEF (`NangateOpenCellLibrary.tech.lef`, `NangateOpenCellLibrary.macro.mod.lef`) files.

Edit only `code/lsu.sv`, `code/network_tx.sv`, and `code/bsg_manycore_endpoint_standard.sv`.

## 2. Functional Simulation (Verilator)

```bash
verilator --binary --timing -j 1 -Wno-fatal -DBSG_HIDE_FROM_SYNTHESIS -Icode --top-module tb \
  code/bsg_manycore_pkg.sv code/bsg_manycore_addr_pkg.sv code/bsg_vanilla_pkg.sv \
  code/bsg_dff_reset.sv code/bsg_circular_ptr.sv code/bsg_fifo_tracker.sv \
  code/bsg_mem_1r1w_synth.sv code/bsg_mem_1r1w.sv \
  code/bsg_fifo_1r1w_small_unhardened.sv code/bsg_fifo_1r1w_small.sv \
  code/bsg_two_fifo.sv code/bsg_counter_up_down.sv code/bsg_hashing_ipoly.sv \
  code/bsg_manycore_reg_id_decode.sv code/bsg_manycore_dram_hash_function.sv \
  code/bsg_manycore_eva_to_npa.sv code/bsg_manycore_endpoint.sv \
  code/bsg_manycore_endpoint_fc.sv code/bsg_manycore_endpoint_standard.sv \
  code/lsu.sv code/network_tx.sv code/bsg_manycore_tile_mem_if.sv tb.sv
./obj_dir/Vtb
```

## 3. Yosys/Slang + ABC Synthesis (Nangate45)

```bash
yosys -Q -T -m slang -p "
  read_slang --ignore-assertions --top bsg_manycore_tile_mem_if -DBSG_HIDE_FROM_SYNTHESIS -I code \
    code/bsg_manycore_pkg.sv code/bsg_manycore_addr_pkg.sv code/bsg_vanilla_pkg.sv \
    code/bsg_dff_reset.sv code/bsg_circular_ptr.sv code/bsg_fifo_tracker.sv \
    code/bsg_mem_1r1w_synth.sv code/bsg_mem_1r1w.sv \
    code/bsg_fifo_1r1w_small_unhardened.sv code/bsg_fifo_1r1w_small.sv \
    code/bsg_two_fifo.sv code/bsg_counter_up_down.sv code/bsg_hashing_ipoly.sv \
    code/bsg_manycore_reg_id_decode.sv code/bsg_manycore_dram_hash_function.sv \
    code/bsg_manycore_eva_to_npa.sv code/bsg_manycore_endpoint.sv \
    code/bsg_manycore_endpoint_fc.sv code/bsg_manycore_endpoint_standard.sv \
    code/lsu.sv code/network_tx.sv code/bsg_manycore_tile_mem_if.sv
  hierarchy -check -top bsg_manycore_tile_mem_if
  synth -top bsg_manycore_tile_mem_if
  opt
  dfflibmap -liberty lib/NangateOpenCellLibrary_typical.lib
  abc -liberty lib/NangateOpenCellLibrary_typical.lib
  clean
  read_liberty -lib lib/NangateOpenCellLibrary_typical.lib
  check -assert
  stat -liberty lib/NangateOpenCellLibrary_typical.lib
  write_verilog -noattr mapped.v
"
```

The reported `Chip area for module '\bsg_manycore_tile_mem_if':` must be `<= 3665.0` (`um^2`).

## 4. OpenROAD Placement-Estimated Static Timing Analysis

Strip any ` signed ` wire tokens if emitted by Yosys (`sed 's/ signed / /g' mapped.v > sta.v`), then run OpenROAD (`openroad -exit flow.tcl`) with:

```tcl
read_lef lib/NangateOpenCellLibrary.tech.lef
read_lef lib/NangateOpenCellLibrary.macro.mod.lef
read_liberty lib/NangateOpenCellLibrary_typical.lib
read_verilog sta.v
link_design bsg_manycore_tile_mem_if
initialize_floorplan -die_area {0 0 140 140} -core_area {10 10 130 130} -site FreePDK45_38x28_10R_NP_162NW_34O
create_clock -name clk_i -period 2.33 [get_ports clk_i]
set_input_delay 0.20 -clock clk_i [all_inputs -no_clocks]
set_output_delay 0.40 -clock clk_i [all_outputs]
set_load 5.0 [all_outputs]
make_tracks
place_pins -hor_layers metal3 -ver_layers metal2
set_wire_rc -signal -layer metal3
set_wire_rc -clock -layer metal3
global_placement -density 0.50
estimate_parasitics -placement
puts "=== SETUP ==="
report_checks -path_delay max -format full_clock_expanded
puts "=== HOLD ==="
report_checks -path_delay min -format full_clock_expanded
puts "BEGIN_SETUP_AUDIT"
check_setup -verbose
puts "END_SETUP_AUDIT"
```

Both the worst setup slack (`-path_delay max`) and worst hold slack (`-path_delay min`) must be `>= 0.0` (`ns`), with an empty `check_setup -verbose` audit block.

---

## 4. Reference Fix Inspection (Buggy Starter vs. Golden Solution Diff)

> Human reviewers can inspect the exact reference bug fix below, or browse full files in [`environment/public/`](environment/public/), [`solution/gold/`](solution/gold/), and [`solution/alternate_gold/`](solution/alternate_gold/).

<details open>
<summary><b>Click to expand/collapse Unified Diff (<code>environment/public/</code> vs. <code>solution/gold/</code>)</b></summary>

```diff
--- a/environment/public/code/lsu.sv (Buggy Starter)
+++ b/solution/gold/code/lsu.sv (Golden Reference)
@@ -34,11 +34,35 @@
 
   wire unused = clk_i ^ reset_i;
 
-  logic [data_width_p-1:0] mem_addr;
-  logic [data_width_p-1:0] miss_addr;
+  wire [data_width_p-1:0] addr_a = icache_miss_i ? pc_plus4_i : exe_rs1_i;
+  wire [11:0] off_lo = icache_miss_i ? 12'hffc : mem_offset_i;
+  wire off_neg = icache_miss_i | mem_offset_i[11];
 
-  assign mem_addr = exe_rs1_i + `BSG_SIGN_EXTEND(mem_offset_i, data_width_p);
-  assign miss_addr = (pc_plus4_i - 32'h4) | bsg_dram_npa_prefix_gp;
+  // 12-bit low adder + parallel Kogge-Stone prefix +/-1 on upper 20 bits
+  wire [12:0] sum_lo = {1'b0, addr_a[11:0]} + {1'b0, off_lo};
+  wire c12 = sum_lo[12];
+  wire do_inc = ~off_neg & c12;
+  wire do_dec =  off_neg & ~c12;
+
+  wire [19:0] h0 = addr_a[31:12];
+  wire [19:0] p1 = {h0[19:1] & h0[18:0], h0[0]};
+  wire [19:0] p2 = {p1[19:2] & p1[17:0], p1[1:0]};
+  wire [19:0] p3 = {p2[19:4] & p2[15:0], p2[3:0]};
+  wire [19:0] p4 = {p3[19:8] & p3[11:0], p3[7:0]};
+  wire [19:0] p5 = {p4[19:16] & p4[3:0], p4[15:0]};
+  wire [19:0] prop_inc = {p5[18:0], 1'b1};
+
+  wire [19:0] z0 = ~h0;
+  wire [19:0] q1 = {z0[19:1] & z0[18:0], z0[0]};
+  wire [19:0] q2 = {q1[19:2] & q1[17:0], q1[1:0]};
+  wire [19:0] q3 = {q2[19:4] & q2[15:0], q2[3:0]};
+  wire [19:0] q4 = {q3[19:8] & q3[11:0], q3[7:0]};
+  wire [19:0] q5 = {q4[19:16] & q4[3:0], q4[15:0]};
+  wire [19:0] prop_dec = {q5[18:0], 1'b1};
+
+  wire [19:0] sum_hi = h0 ^ ({20{do_inc}} & prop_inc) ^ ({20{do_dec}} & prop_dec);
+  wire [data_width_p-1:0] calc_addr = {sum_hi, sum_lo[11:0]};
+  wire [data_width_p-1:0] req_addr = icache_miss_i ? (calc_addr | bsg_dram_npa_prefix_gp) : calc_addr;
 
   logic [data_width_p-1:0] store_data;
   logic [data_mask_width_lp-1:0] store_mask;
@@ -47,17 +71,17 @@
     if (exe_decode_i.is_byte_op) begin
       store_data = {4{exe_rs2_i[7:0]}};
       store_mask = {
-         mem_addr[1] &  mem_addr[0],
-         mem_addr[1] & ~mem_addr[0],
-        ~mem_addr[1] &  mem_addr[0],
-        ~mem_addr[1] & ~mem_addr[0]
+         calc_addr[1] &  calc_addr[0],
+         calc_addr[1] & ~calc_addr[0],
+        ~calc_addr[1] &  calc_addr[0],
+        ~calc_addr[1] & ~calc_addr[0]
       };
     end
     else if (exe_decode_i.is_hex_op) begin
       store_data = {2{exe_rs2_i[15:0]}};
       store_mask = {
-        {2{mem_addr[1]}},
-        {2{~mem_addr[1]}}
+        {2{calc_addr[1]}},
+        {2{~calc_addr[1]}}
       };
     end
     else begin
@@ -66,16 +90,16 @@
     end
   end
 
-  wire is_local_dmem_addr = (mem_addr[31:12] == 20'h0_0000);
+  wire is_local_dmem_addr = ~icache_miss_i & ~exe_decode_i.is_uncached_op & ~(|sum_hi);
 
   assign dmem_v_o = is_local_dmem_addr &
     (exe_decode_i.is_load_op | exe_decode_i.is_store_op |
      exe_decode_i.is_lr_op | exe_decode_i.is_lr_aq_op);
-  assign dmem_w_o = exe_decode_i.is_store_op;
-  assign dmem_addr_o = mem_addr[2+:dmem_addr_width_lp];
+  assign dmem_w_o = ~icache_miss_i & exe_decode_i.is_store_op;
+  assign dmem_addr_o = calc_addr[2+:dmem_addr_width_lp];
   assign dmem_data_o = store_data;
   assign dmem_mask_o = store_mask;
-  assign byte_sel_o = mem_addr[1:0];
+  assign byte_sel_o = calc_addr[1:0];
 
   bsg_manycore_load_info_s load_info;
 
@@ -97,26 +121,26 @@
         is_unsigned_op: exe_decode_i.is_load_unsigned,
         is_byte_op: exe_decode_i.is_byte_op,
         is_hex_op: exe_decode_i.is_hex_op,
-        part_sel: exe_decode_i.is_uncached_op ? 2'b00 : mem_addr[1:0]
+        part_sel: exe_decode_i.is_uncached_op ? 2'b00 : calc_addr[1:0]
       };
     end
 
     remote_req_o = '{
-      write_not_read : exe_decode_i.is_store_op,
-      is_amo_op : exe_decode_i.is_amo_op,
-      is_uncached_op : exe_decode_i.is_uncached_op,
+      write_not_read : (~icache_miss_i & exe_decode_i.is_store_op),
+      is_amo_op : (~icache_miss_i & exe_decode_i.is_amo_op),
+      is_uncached_op : (~icache_miss_i & exe_decode_i.is_uncached_op),
       amo_type : exe_decode_i.amo_type,
       mask: store_mask,
       load_info : load_info,
       reg_id : exe_rd_i,
       data : store_data,
-      addr : (icache_miss_i ? miss_addr : mem_addr)
+      addr : req_addr
     };
   end
 
   assign remote_req_v_o = icache_miss_i |
     ((exe_decode_i.is_load_op | exe_decode_i.is_store_op | exe_decode_i.is_amo_op) & ~is_local_dmem_addr);
 
-  assign reserve_o = exe_decode_i.is_lr_op & is_local_dmem_addr;
+  assign reserve_o = ~icache_miss_i & exe_decode_i.is_lr_op & is_local_dmem_addr;
 
 endmodule

--- a/environment/public/code/network_tx.sv (Buggy Starter)
+++ b/solution/gold/code/network_tx.sv (Golden Reference)
@@ -73,12 +73,7 @@
     , output logic invalid_eva_access_o
   );
 
-  wire unused = clk_i ^ reset_i ^ flush_i;
-
   `declare_bsg_manycore_packet_s(addr_width_p,data_width_p,x_cord_width_p,y_cord_width_p);
-
-  bsg_manycore_packet_s out_packet;
-  assign out_packet_o = out_packet;
 
   logic is_invalid_addr_lo;
   logic is_invalid_eva;
@@ -90,16 +85,15 @@
   wire [y_cord_width_p-1:0] src_y_cord = {pod_y_i, my_y_i};
 
   wire proxy_is_in_the_south = src_y_cord[y_subcord_width_lp-1];
-
-  wire [x_cord_width_p-1:0] proxy_x_cord_lo = (x_cord_width_p)'(src_x_cord);
-  wire [y_cord_width_p-1:0] proxy_y_cord_lo = proxy_is_in_the_south
-    ? {(pod_y_cord_width_p)'(pod_y_i + 1'b1), {y_subcord_width_lp{1'b0}}}
-    : {(pod_y_cord_width_p)'(pod_y_i - 1'b1), {y_subcord_width_lp{1'b1}}};
+  wire [pod_y_cord_width_p-1:0] proxy_pod_y_step = proxy_is_in_the_south ? {{(pod_y_cord_width_p-1){1'b0}}, 1'b1} : {pod_y_cord_width_p{1'b1}};
+  wire [pod_y_cord_width_p-1:0] proxy_pod_y = pod_y_i + proxy_pod_y_step;
+
+  wire [x_cord_width_p-1:0] proxy_x_cord_lo = src_x_cord;
+  wire [y_cord_width_p-1:0] proxy_y_cord_lo = {proxy_pod_y, {y_subcord_width_lp{~proxy_is_in_the_south}}};
 
   wire [addr_width_p-1:0] io_addr = remote_req_i.addr[addr_width_p+1:2];
-
   wire is_uncached_op = remote_req_i.is_uncached_op;
-  assign is_invalid_addr_lo = is_invalid_eva & ~is_uncached_op;
+  assign is_invalid_addr_lo = is_invalid_eva & ~is_uncached_op & ~remote_req_i.load_info.icache_fetch;
 
   bsg_manycore_eva_to_npa #(
     .data_width_p(data_width_p)
@@ -126,58 +120,116 @@
     ,.pod_y_i(remote_req_i.load_info.icache_fetch ? pod_y_i : cfg_pod_y_i)
   );
 
+  bsg_manycore_packet_s live_pkt;
   always_comb begin
     if (remote_req_i.write_not_read | remote_req_i.is_amo_op) begin
-      out_packet.payload = remote_req_i.data;
-    end
-    else begin
-      out_packet.payload.load_info_s.load_info = remote_req_i.load_info;
-      out_packet.payload.load_info_s.reserved  = '0;
+      live_pkt.payload = remote_req_i.data;
+    end
+    else begin
+      live_pkt.payload.load_info_s.load_info = remote_req_i.load_info;
+      live_pkt.payload.load_info_s.reserved  = '0;
     end
 
     if (is_uncached_op) begin
-      out_packet.y_cord = proxy_y_cord_lo;
-      out_packet.x_cord = proxy_x_cord_lo;
-      out_packet.addr = io_addr;
-    end
-    else begin
-      out_packet.y_cord = y_cord_lo;
-      out_packet.x_cord = x_cord_lo;
-      out_packet.addr = epa_lo;
+      live_pkt.y_cord = proxy_y_cord_lo;
+      live_pkt.x_cord = proxy_x_cord_lo;
+      live_pkt.addr   = io_addr;
+    end
+    else begin
+      live_pkt.y_cord = y_cord_lo;
+      live_pkt.x_cord = x_cord_lo;
+      live_pkt.addr   = epa_lo;
     end
 
     if (remote_req_i.write_not_read) begin
-      out_packet.reg_id.store_mask_s.mask = remote_req_i.mask;
-      out_packet.reg_id.store_mask_s.unused = 1'b0;
-    end
-    else begin
-      out_packet.reg_id = remote_req_i.reg_id;
-    end
-
-    out_packet.src_y_cord = src_y_cord;
-    out_packet.src_x_cord = src_x_cord;
+      live_pkt.reg_id.store_mask_s.mask   = remote_req_i.mask;
+      live_pkt.reg_id.store_mask_s.unused = 1'b0;
+    end
+    else begin
+      live_pkt.reg_id = remote_req_i.reg_id;
+    end
+
+    live_pkt.src_y_cord = src_y_cord;
+    live_pkt.src_x_cord = src_x_cord;
 
     if (remote_req_i.is_amo_op) begin
       case (remote_req_i.amo_type)
-        e_vanilla_amoswap:  out_packet.op_v2 = e_remote_amoswap;
-        e_vanilla_amoor:    out_packet.op_v2 = e_remote_amoor;
-        e_vanilla_amoadd:   out_packet.op_v2 = e_remote_amoadd;
-        default:            out_packet.op_v2 = e_remote_amoswap;
+        e_vanilla_amoswap: live_pkt.op_v2 = e_remote_amoswap;
+        e_vanilla_amoor:   live_pkt.op_v2 = e_remote_amoor;
+        e_vanilla_amoadd:  live_pkt.op_v2 = e_remote_amoadd;
+        default:           live_pkt.op_v2 = e_remote_amoswap;
       endcase
     end
-    else begin
-      if (remote_req_i.write_not_read) begin
-        out_packet.op_v2 = is_uncached_op ? e_remote_uncached_store : e_remote_store;
-      end
-      else begin
-        out_packet.op_v2 = is_uncached_op ? e_remote_uncached_load : e_remote_load;
-      end
-    end
-  end
-
-  assign out_v_o = remote_req_v_i & ~is_invalid_addr_lo;
-  assign remote_req_credit_o = out_credit_or_ready_i;
-  assign invalid_eva_access_o = remote_req_v_i & is_invalid_addr_lo;
+    else if (remote_req_i.write_not_read) begin
+      live_pkt.op_v2 = is_uncached_op ? e_remote_uncached_store : e_remote_store;
+    end
+    else begin
+      live_pkt.op_v2 = is_uncached_op ? e_remote_uncached_load : e_remote_load;
+    end
+  end
+
+  typedef struct packed {
+    logic [addr_width_p-1:0] addr;
+    bsg_manycore_packet_op_e op_v2;
+    bsg_manycore_packet_reg_id_u reg_id;
+    bsg_manycore_packet_payload_u payload;
+    logic [y_cord_width_p-1:0] y_cord;
+    logic [x_cord_width_p-1:0] x_cord;
+  } held_pkt_s;
+
+  logic held_v_r;
+  held_pkt_s held_pkt_r;
+
+  wire live_req_valid = ~held_v_r & remote_req_v_i & ~is_invalid_addr_lo & ~flush_i;
+
+  always_ff @(posedge clk_i) begin
+    if (reset_i | flush_i) begin
+      held_v_r <= 1'b0;
+    end
+    else if (held_v_r) begin
+      if (out_credit_or_ready_i) begin
+        held_v_r <= 1'b0;
+      end
+    end
+    else if (remote_req_v_i & ~is_invalid_addr_lo & ~out_credit_or_ready_i) begin
+      held_v_r <= 1'b1;
+    end
+  end
+
+  always_ff @(posedge clk_i) begin
+    if (~held_v_r & ~out_credit_or_ready_i) begin
+      held_pkt_r <= '{
+        addr    : live_pkt.addr,
+        op_v2   : live_pkt.op_v2,
+        reg_id  : live_pkt.reg_id,
+        payload : live_pkt.payload,
+        y_cord  : live_pkt.y_cord,
+        x_cord  : live_pkt.x_cord
+      };
+    end
+  end
+
+  bsg_manycore_packet_s out_packet;
+  always_comb begin
+    if (held_v_r) begin
+      out_packet.addr       = held_pkt_r.addr;
+      out_packet.op_v2      = held_pkt_r.op_v2;
+      out_packet.reg_id     = held_pkt_r.reg_id;
+      out_packet.payload    = held_pkt_r.payload;
+      out_packet.src_y_cord = src_y_cord;
+      out_packet.src_x_cord = src_x_cord;
+      out_packet.y_cord     = held_pkt_r.y_cord;
+      out_packet.x_cord     = held_pkt_r.x_cord;
+    end
+    else begin
+      out_packet = live_pkt;
+    end
+  end
+
+  assign out_packet_o = out_packet;
+  assign out_v_o = ~flush_i & (held_v_r | live_req_valid);
+  assign remote_req_credit_o = out_credit_or_ready_i & ~held_v_r;
+  assign invalid_eva_access_o = ~held_v_r & ~flush_i & remote_req_v_i & is_invalid_addr_lo;
 
   assign ifetch_instr_o = returned_data_i;
   assign int_remote_load_resp_data_o = returned_data_i;
@@ -201,12 +253,12 @@
       e_return_float_wb: begin
         float_remote_load_resp_v_o = returned_v_i;
         float_remote_load_resp_force_o = returned_v_i & returned_fifo_full_i;
-        returned_yumi_o = float_remote_load_resp_yumi_i;
+        returned_yumi_o = returned_v_i & float_remote_load_resp_yumi_i;
       end
       e_return_int_wb: begin
         int_remote_load_resp_v_o = returned_v_i;
         int_remote_load_resp_force_o = returned_v_i & returned_fifo_full_i;
-        returned_yumi_o = int_remote_load_resp_yumi_i;
+        returned_yumi_o = returned_v_i & int_remote_load_resp_yumi_i;
       end
       default: begin
       end

--- a/environment/public/code/bsg_manycore_endpoint_standard.sv (Buggy Starter)
+++ b/solution/gold/code/bsg_manycore_endpoint_standard.sv (Golden Reference)
@@ -83,7 +83,7 @@
     ,.credit_counter_width_p(credit_counter_width_p)
     ,.warn_out_of_credits_p(warn_out_of_credits_p)
     ,.rev_fifo_els_p(rev_fifo_els_p)
-    ,.use_credits_for_local_fifo_p(use_credits_for_local_fifo_p)
+    ,.use_credits_for_local_fifo_p(0)
   ) bme (
     .clk_i(clk_i)
     ,.reset_i(reset_i)
@@ -107,17 +107,30 @@
   logic lock_r, lock_n;
   logic lock_v_r, lock_v_n;
   logic lock_return_r;
+  logic resp_pending_r;
+
+  assign return_packet_v_li = resp_pending_r & (lock_v_r | returning_v_i);
+  wire can_accept_req = ~resp_pending_r | return_packet_v_li;
 
   always_ff @ (posedge clk_i) begin
     if (reset_i) begin
       lock_r <= 1'b0;
       lock_v_r <= 1'b0;
       lock_return_r <= 1'b0;
+      resp_pending_r <= 1'b0;
     end
     else begin
       lock_r <= lock_n;
       lock_v_r <= lock_v_n;
-      lock_return_r <= lock_r;
+      if (lock_v_n) begin
+        lock_return_r <= lock_r;
+      end
+      if (packet_v_lo & packet_yumi_li) begin
+        resp_pending_r <= 1'b1;
+      end
+      else if (return_packet_v_li) begin
+        resp_pending_r <= 1'b0;
+      end
     end
   end
 
@@ -130,6 +143,8 @@
 
   logic [bsg_manycore_reg_id_width_gp-1:0] return_reg_id;
   bsg_manycore_return_packet_type_e return_pkt_type;
+
+  wire req_v_gated = packet_v_lo & can_accept_req;
 
   always_comb begin
     in_v_o    = 1'b0;
@@ -150,36 +165,34 @@
 
     case (packet_lo.op_v2)
       e_remote_load: begin
-        in_v_o = packet_v_lo;
-        packet_yumi_li = in_yumi_i;
+        in_v_o = req_v_gated;
+        packet_yumi_li = req_v_gated & in_yumi_i;
         return_pkt_type = packet_lo.payload.load_info_s.load_info.float_wb
           ? e_return_float_wb
           : e_return_int_wb;
       end
 
       e_remote_sw: begin
-        in_v_o = packet_v_lo;
+        in_v_o = req_v_gated;
         in_we_o = 1'b1;
         in_mask_o = 4'b1111;
-        packet_yumi_li = in_yumi_i;
+        packet_yumi_li = req_v_gated & in_yumi_i;
         return_pkt_type = e_return_credit;
       end
 
       e_remote_store: begin
-        in_v_o = packet_v_lo;
+        in_v_o = req_v_gated;
         in_we_o = 1'b1;
         in_mask_o = packet_lo.reg_id.store_mask_s.mask;
-        packet_yumi_li = in_yumi_i;
+        packet_yumi_li = req_v_gated & in_yumi_i;
         return_pkt_type = e_return_credit;
         return_reg_id = payload_reg_id;
       end
 
       e_remote_amoswap: begin
-        packet_yumi_li = packet_v_lo;
-        lock_v_n = packet_v_lo;
-        lock_n = packet_v_lo
-          ? packet_lo.payload[0]
-          : lock_r;
+        packet_yumi_li = req_v_gated;
+        lock_v_n = req_v_gated;
+        lock_n = req_v_gated ? packet_lo.payload[0] : lock_r;
         return_pkt_type = e_return_int_wb;
       end
 
@@ -198,33 +211,32 @@
   return_info_s return_info_r;
 
   always_ff @ (posedge clk_i) begin
-    if (packet_v_lo & packet_yumi_li) begin
+    if (reset_i) begin
+      return_info_r <= '0;
+    end
+    else if (packet_v_lo & packet_yumi_li) begin
       return_info_r <= '{
-        x_cord : packet_lo.src_x_cord,
-        y_cord : packet_lo.src_y_cord,
-        reg_id : return_reg_id,
+        x_cord   : packet_lo.src_x_cord,
+        y_cord   : packet_lo.src_y_cord,
+        reg_id   : return_reg_id,
         pkt_type : return_pkt_type
       };
     end
   end
 
-  assign return_packet_v_li = lock_v_r | returning_v_i;
-
   assign return_packet_li = '{
-    pkt_type  : return_info_r.pkt_type,
-    data      : lock_v_r
-                ? (data_width_p)'(lock_return_r)
-                : returning_data_i,
-    y_cord    : return_info_r.y_cord,
-    x_cord    : return_info_r.x_cord,
-    reg_id    : return_info_r.reg_id
+    pkt_type : return_info_r.pkt_type,
+    data     : lock_v_r ? (data_width_p)'(lock_return_r) : returning_data_i,
+    y_cord   : return_info_r.y_cord,
+    x_cord   : return_info_r.x_cord,
+    reg_id   : return_info_r.reg_id
   };
 
   assign returned_data_r_o     = return_packet_lo.data;
   assign returned_reg_id_r_o   = return_packet_lo.reg_id;
   assign returned_pkt_type_r_o = return_packet_lo.pkt_type;
   assign returned_v_r_o        = return_packet_v_lo & (return_packet_lo.pkt_type != e_return_credit);
-  assign return_packet_yumi_li = returned_yumi_i | (return_packet_v_lo & (return_packet_lo.pkt_type == e_return_credit));
+  assign return_packet_yumi_li = (returned_v_r_o & returned_yumi_i) | (return_packet_v_lo & (return_packet_lo.pkt_type == e_return_credit));
 
   wire returned_credit              = return_packet_v_lo & return_packet_yumi_li;
   assign returned_credit_v_r_o      = returned_credit;

```

</details>

---

## 5. Harbor Package File Inventory & Provenance

### Public Workspace (`environment/public/`)
- [`environment/public/BUILD.md`](environment/public/BUILD.md) *(Read-Only Context)*
- [`environment/public/code/LICENSE`](environment/public/code/LICENSE) *(Read-Only Context)*
- [`environment/public/code/bsg_circular_ptr.sv`](environment/public/code/bsg_circular_ptr.sv) *(Read-Only Context)*
- [`environment/public/code/bsg_counter_up_down.sv`](environment/public/code/bsg_counter_up_down.sv) *(Read-Only Context)*
- [`environment/public/code/bsg_defines.sv`](environment/public/code/bsg_defines.sv) *(Read-Only Context)*
- [`environment/public/code/bsg_dff_reset.sv`](environment/public/code/bsg_dff_reset.sv) *(Read-Only Context)*
- [`environment/public/code/bsg_fifo_1r1w_small.sv`](environment/public/code/bsg_fifo_1r1w_small.sv) *(Read-Only Context)*
- [`environment/public/code/bsg_fifo_1r1w_small_unhardened.sv`](environment/public/code/bsg_fifo_1r1w_small_unhardened.sv) *(Read-Only Context)*
- [`environment/public/code/bsg_fifo_tracker.sv`](environment/public/code/bsg_fifo_tracker.sv) *(Read-Only Context)*
- [`environment/public/code/bsg_hashing_ipoly.sv`](environment/public/code/bsg_hashing_ipoly.sv) *(Read-Only Context)*
- [`environment/public/code/bsg_manycore_addr_pkg.sv`](environment/public/code/bsg_manycore_addr_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/bsg_manycore_defines.svh`](environment/public/code/bsg_manycore_defines.svh) *(Read-Only Context)*
- [`environment/public/code/bsg_manycore_dram_hash_function.sv`](environment/public/code/bsg_manycore_dram_hash_function.sv) *(Read-Only Context)*
- [`environment/public/code/bsg_manycore_endpoint.sv`](environment/public/code/bsg_manycore_endpoint.sv) *(Read-Only Context)*
- [`environment/public/code/bsg_manycore_endpoint_fc.sv`](environment/public/code/bsg_manycore_endpoint_fc.sv) *(Read-Only Context)*
- [`environment/public/code/bsg_manycore_endpoint_standard.sv`](environment/public/code/bsg_manycore_endpoint_standard.sv) **(Editable)**
- [`environment/public/code/bsg_manycore_eva_to_npa.sv`](environment/public/code/bsg_manycore_eva_to_npa.sv) *(Read-Only Context)*
- [`environment/public/code/bsg_manycore_pkg.sv`](environment/public/code/bsg_manycore_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/bsg_manycore_reg_id_decode.sv`](environment/public/code/bsg_manycore_reg_id_decode.sv) *(Read-Only Context)*
- [`environment/public/code/bsg_manycore_tile_mem_if.sv`](environment/public/code/bsg_manycore_tile_mem_if.sv) *(Read-Only Context)*
- [`environment/public/code/bsg_mem_1r1w.sv`](environment/public/code/bsg_mem_1r1w.sv) *(Read-Only Context)*
- [`environment/public/code/bsg_mem_1r1w_synth.sv`](environment/public/code/bsg_mem_1r1w_synth.sv) *(Read-Only Context)*
- [`environment/public/code/bsg_noc_links.svh`](environment/public/code/bsg_noc_links.svh) *(Read-Only Context)*
- [`environment/public/code/bsg_two_fifo.sv`](environment/public/code/bsg_two_fifo.sv) *(Read-Only Context)*
- [`environment/public/code/bsg_vanilla_pkg.sv`](environment/public/code/bsg_vanilla_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/lsu.sv`](environment/public/code/lsu.sv) **(Editable)**
- [`environment/public/code/network_tx.sv`](environment/public/code/network_tx.sv) **(Editable)**
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

