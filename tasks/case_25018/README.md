# `case_25018`: Caliptra RoT 8-Macro SECDED Staging Memory, AXI4 Access Lock & SHA-512 Direct-Read PnR

[Back to Benchmark Root (`README.md`)](../../README.md) | [Full 94-Task Catalog (`TASKS_INDEX.md`)](../../TASKS_INDEX.md) | [`task.toml`](task.toml) | [`instruction.md`](instruction.md) | [`solution/solve.sh`](solution/solve.sh) | [`tests/test.sh`](tests/test.sh) | [`tests/private/grader/run.py`](tests/private/grader/run.py)

---

## 1. Task Overview & Harbor Configuration

| Field | Value |
| :--- | :--- |
| **Task ID** | `case_25018` |
| **Source Silicon Repository** | `chipsalliance/caliptra-rtl` (`repo_50`) |
| **Engineering Problem Type** | **RTL + Hard-SRAM Macro Physical Co-Design** (`PT5_RTL_HardSRAM_Macro_PnR`) |
| **EDA Evaluation Stage** | **Stage 4: Hard-SRAM Floorplanning, CTS & Routing (PnR)** (`stage4_macro_pnr`) |
| **Coupled Evaluation Gates** | Stage 1 (Functional RTL Sim) -> Stage 2 (Hard-SRAM Macro Synthesis) -> Stage 3 (Multi-Corner STA) -> Stage 4 (OpenROAD Macro Floorplanning, PDN, CTS & Routing) |
| **Primary Hardware Domain** | `Security_RoT_Subsystems` (Security_RoT_Subsystems) |
| **Multi-Domain Tags** | `Security_RoT_Subsystems` |
| **Editable Files (`allowed_edits`)** | [`code/sha512_acc_top.sv`](environment/public/code/sha512_acc_top.sv), [`code/axi_sub_rd.sv`](environment/public/code/axi_sub_rd.sv), [`code/axi_sub_wr.sv`](environment/public/code/axi_sub_wr.sv), [`code/rot_sram_ecc_ctrl.sv`](environment/public/code/rot_sram_ecc_ctrl.sv), [`plan/macro_placement.json`](environment/public/plan/macro_placement.json), [`constraints/rot_staging_subsys.sdc`](environment/public/constraints/rot_staging_subsys.sdc) (6 files, 1635 LOC) |
| **Public Subsystem Context** | 45 RTL files (22760 LOC) |
| **Base Container Image** | `siliconbench-eda:1.0` (`allow_internet = false`, `environment_mode = "separate"`) |
| **PDK / Environment Profile** | **IHP SG13G2 130nm Open PDK + RM_IHPSG13_1P Hard-SRAM Macros** |
| **Task-Customized Collateral?** | **Yes (Task-Bundled Collateral)** — Includes task-bundled IHP SG13G2 standard-cell LEF/Liberty and single-port hard-SRAM macro LEF/Liberty/Verilog models. |
| **Verifier Timeout & Seeds** | `1800s` total (`900s`/seed) across deterministic seeds `[101, 202]` |

---

## 2. Problem Specification (`issue.md`)

# Caliptra RoT SECDED Staging Memory & SHA-512 Direct-Read Subsystem Signoff

`rot_staging_subsys` (`code/rot_staging_subsys.sv`, read-only) integrates a 32-bit AXI4 subordinate (`axi_sub`, `C_LAT = 2`), an 8-bank `8 KB` (`2048` dwords, byte aperture `0x0000..0x1FFF`) inverted-Hsiao 39/32 SECDED hard-SRAM staging controller (`rot_sram_ecc_ctrl`), and the Caliptra SHA-384/512 accelerator (`sha512_acc_top`, CSR offset `0x21000`). Bring the subsystem to functional, security, and IHP SG13G2 physical signoff by updating only `code/sha512_acc_top.sv`, `code/axi_sub_rd.sv`, `code/axi_sub_wr.sv`, `code/rot_sram_ecc_ctrl.sv`, `plan/macro_placement.json`, and `constraints/rot_staging_subsys.sdc`.

## Functional, Security & ECC Contracts

1. **AXI4 Staging Protocol, Access Control & Active Window Lock**:
   - Validate every AXI read and write transaction against burst legality (`AxSIZE <= 3'd2`, `AxBURST != 2'b11`), requester allowlist (`AxUSER` matching `allow_axi_user_i[0]` or `allow_axi_user_i[1]`), and byte-aperture bounds (`addr < 16'h2000`).
   - While `sha512_acc_top` is actively executing a `mailbox_mode` hash operation (prior to `SHA_DONE`, fault abort, lock release, or zeroize), reject any AXI write targeting a dword within `[START_ADDRESS >> 2, (START_ADDRESS + ((DLEN + 3) & ~3)) >> 2)` without mutating SRAM; concurrent AXI reads and disjoint staging writes remain permitted.
   - Any failing AXI read beat (illegal burst, unauthorized `ARUSER`, out-of-bounds address, or uncorrectable 2-bit ECC error) must complete all `ARLEN + 1` beats with `RRESP = SLVERR` (`2'b10`) and zero-masked `RDATA = 32'h0000_0000`.
   - Any failing AXI write transaction (illegal burst, unauthorized `AWUSER`, out-of-bounds address, active SHA staging lock, or uncorrectable 2-bit ECC error during sub-dword pre-read) must prevent SRAM mutation on the failing beat and all subsequent beats of that burst, drain all `AWLEN + 1` `W` beats, and return `BRESP = SLVERR` (`2'b10`). Authorized, unlocked, in-bounds beats with `WSTRB == 4'h0` are valid no-ops (`OKAY`, no data or ECC mutation).

2. **Pipelined 8-Macro SECDED Controller, Sub-Dword RMW & Hardware Scrub**:
   - Preserve all `8` `RM_IHPSG13_1P_256x64_c2_bm_bist` hard macros (`g_bank[0..7].u_sram`) with zero inferred latches and exact `C_LAT = 2` read response alignment to `axi_sub`.
   - Sub-dword AXI writes (`WSTRB != 4'hF` and `WSTRB != 4'h0`) must execute an ECC-checked read-modify-write: abort with `SLVERR` (`ecc_double_err_pulse_o` pulsed, SRAM untouched) if the pre-read codeword has a 2-bit ECC fault; otherwise merge enabled byte lanes into the (if needed, 1-bit corrected) 32-bit word and write a freshly encoded 39-bit codeword (XORing `{37'h0, ecc_err_inj_mask_i}` when `ecc_err_inj_en_i` is asserted on normal and RMW writes).
   - Single-bit ECC faults on valid AXI or SHA direct reads must deliver corrected data, pulse `ecc_single_err_pulse_o` for 1 cycle, and perform a 1-cycle clean codeword scrub writeback (bypassing `ecc_err_inj_en_i`) to that bank/row so subsequent reads observe clean parity. Double-bit ECC faults pulse `ecc_double_err_pulse_o` for 1 cycle without scrubbing.

3. **SHA-512 Direct-Read Pipeline, Quarantine & `CONTROL.ZEROIZE` Hardening**:
   - Support empty-message (`DLEN == 0`) execution in both `streaming_mode` and valid in-bounds `mailbox_mode`, alongside arbitrary byte-length single- and multi-block payloads across SRAM hold/scrub stalls.
   - In `mailbox_mode`, require `START_ADDRESS[1:0] == 2'b00`, `START_ADDRESS < 32'h0000_2000`, and `START_ADDRESS + DLEN <= 33'h0_0000_2000` upon `EXECUTE`; violations must pulse `error1_sts` (`error_internal_intr_r[1]`) and abort without issuing SRAM reads or asserting `STATUS.VALID`. Uncorrectable 2-bit ECC faults on `mailbox_mode` SRAM reads must pulse `error2_sts` (`error_internal_intr_r[2]`), halt further reads, clear internal block/digest state (`DIGEST[0..15] == 0`), and abort without asserting `STATUS.VALID`.
   - Permit CSR writes to `CONTROL` (`offset 0x060`) only from the active `LOCK` owner or from local firmware (`csr_req_soc_i == 0`) when `LOCK == 0`, rejecting unauthorized writes with `csr_err_o = 1'b1`. Authorized `CONTROL.ZEROIZE` writes must persistently wipe `DIGEST[0..15]`, `STATUS.VALID`, and internal message/digest state across subsequent clock cycles.

## Physical Implementation & Signoff Targets (IHP SG13G2 130 nm)

- **Floorplan (`plan/macro_placement.json`)**: Die `{0 0 2600 1750}` um, core `{50 50 2550 1700}` um. Place all `8` `u_sram_ctrl.g_bank[0..7].u_sram` macros (`784.48 x 118.78` um, orientations in `{R0, R180, MX, MY}`) with `>= 20.0` um margin to core boundaries and `>= 20.0` um edge-to-edge channel spacing between macros.
- **Timing & Routing (`constraints/rot_staging_subsys.sdc`)**: Constrain `clk` at `<= 15.5` ns period (`>= 64.5` MHz), `>= 1.5` ns max input/output delays (`[all_inputs -no_clocks]` / `[all_outputs]`), and `set_false_path` only from `rst_b` / `cptra_pwrgood` (no multicycle, max/min delay, or disable-timing overrides). Close OpenROAD PDN (`VDD`/`VSS` connected), CTS, global routing (`<= 15` overflows, wirelength `<= 4,500,000` um), and post-GRT STA (`WNS >= 0.0` ns, hold slack `>= 0.0` ns).

---

## 3. Build & Verification Instructions (`BUILD.md`)

# Build & Verification Reference (`rot_staging_subsys`)

## Editable Deliverables

Only the following six files may be modified:
- `code/sha512_acc_top.sv`
- `code/axi_sub_rd.sv`
- `code/axi_sub_wr.sv`
- `code/rot_sram_ecc_ctrl.sv`
- `plan/macro_placement.json`
- `constraints/rot_staging_subsys.sdc`

All other files under `code/` and `pdk/` are read-only infrastructure.

## Toolchain Paths

- Verilator: `verilator`
- Yosys (with Slang frontend): `yosys`
- OpenROAD: `openroad`

## Compilation Order

Package files (`PKG_FILES`):
```text
code/caliptra_prim_util_pkg.sv code/caliptra_prim_pkg.sv code/caliptra_prim_mubi_pkg.sv
code/axi_pkg.sv code/kv_defines_pkg.sv code/pv_defines_pkg.sv code/soc_ifc_pkg.sv
code/mbox_pkg.sv code/sha512_params_pkg.sv code/sha512_acc_csr_pkg.sv
```

Design RTL files (`RTL_FILES`):
```text
code/caliptra_prim_generic_flop.sv code/caliptra_prim_flop.sv code/caliptra_prim_sparse_fsm_flop.sv
code/caliptra_2ff_sync.sv code/caliptra_prim_secded_inv_39_32_enc.sv code/caliptra_prim_secded_inv_39_32_dec.sv
code/axi_if.sv code/axi_addr.v code/skidbuffer.v code/axi_sub_arb.sv code/axi_sub_rd.sv
code/axi_sub_wr.sv code/axi_sub.sv code/sha512_h_constants.v code/sha512_k_constants.v
code/sha512_w_mem.v code/sha512_core.v code/sha512_acc_csr.sv code/sha512_acc_top.sv
code/rot_sram_ecc_ctrl.sv code/rot_staging_subsys.sv
```

- **Simulation (Verilator)**: Include `pdk/core.v pdk/256.v` before `$PKG_FILES $RTL_FILES` with `--binary --timing -Wno-fatal -Icode`.
- **Synthesis (Yosys + Slang)**:
  ```tcl
  read_slang --top rot_staging_subsys --keep-hierarchy --allow-use-before-declare -Icode -DSYNTHESIS pdk/256_stub.v <PKG_FILES> <RTL_FILES>
  hierarchy -check -top rot_staging_subsys
  setattr -set keep_hierarchy 1 t:RM_IHPSG13_1P_256x64_c2_bm_bist
  synth -top rot_staging_subsys -flatten
  dfflibmap -liberty pdk/sg13g2_stdcell_typ_1p20V_25C.lib
  abc -liberty pdk/sg13g2_stdcell_typ_1p20V_25C.lib -D 10000
  opt_clean -purge
  ```
- **Physical Implementation (OpenROAD IHP SG13G2)**:
  - Floorplan: `initialize_floorplan -die_area {0 0 2600 1750} -core_area {50 50 2550 1700} -site CoreSite`, macro placement from `plan/macro_placement.json`, `cut_rows -halo_width_x 4.0 -halo_width_y 4.0`, core + `RM_IHPSG13_1P_256x64_c2_bm_bist` PDN rings/stripes (`TopMetal1`/`TopMetal2`/`Metal3`/`Metal4`), `pdngen`, `source constraints/rot_staging_subsys.sdc`, placement, CTS, `global_route` (`Metal2-TopMetal1`), `estimate_parasitics -global_routing`, and `report_wns` / `report_checks`.

---

## 4. Reference Fix Inspection (Buggy Starter vs. Golden Solution Diff)

> Human reviewers can inspect the exact reference bug fix below, or browse full files in [`environment/public/`](environment/public/), [`solution/gold/`](solution/gold/), and [`solution/alternate_gold/`](solution/alternate_gold/).

<details open>
<summary><b>Click to expand/collapse Unified Diff (<code>environment/public/</code> vs. <code>solution/gold/</code>)</b></summary>

```diff
--- a/environment/public/code/sha512_acc_top.sv (Buggy Starter)
+++ b/solution/gold/code/sha512_acc_top.sv (Golden Reference)
@@ -155,9 +155,32 @@
   logic extend_load_block;
   logic [0:BLOCK_NO-1][DATA_WIDTH-1:0] extend_block;
 
+  logic        cpuif_addr_hit;
+  logic        control_wr_attempt;
+  logic        control_wr_allowed;
+  logic        unauth_control_wr;
+  logic        mbox_bounds_err;
+  logic        mbox_bounds_abort;
+  logic        mbox_ecc_abort;
+  logic        wipe_state;
+  logic [10:0] mbox_start_dword;
+  logic [11:0] mbox_dlen_dwords, mbox_end_dword;
+  logic [10:0] lock_start_q;
+  logic [11:0] lock_end_q;
+  logic [11:0] mbox_rd_dword_q;
+  logic [2:0]  mbox_inflight_q;
+  logic        mbox_req_active_state;
+  logic        mbox_req_fire;
+  logic        empty_msg_exec;
+
   assign req_hold = stall_write;
-  
-  assign err = read_error | write_error;
+
+  assign cpuif_addr_hit     = (req_data.addr[SOC_IFC_ADDR_W-1:SHA512_ACC_CSR_ADDR_WIDTH] == SHA_REG_START_ADDR[SOC_IFC_ADDR_W-1:SHA512_ACC_CSR_ADDR_WIDTH]);
+  assign control_wr_attempt = req_dv && cpuif_addr_hit && req_data.write && (req_data.addr[SHA512_ACC_CSR_ADDR_WIDTH-1:0] == 12'h060);
+  assign control_wr_allowed = hwif_in.valid_user || (!hwif_out.LOCK.LOCK.value && !req_data.soc_req);
+  assign unauth_control_wr  = control_wr_attempt && !control_wr_allowed;
+
+  assign err = read_error | write_error | unauth_control_wr;
 
   assign zeroize_pulse = hwif_out.CONTROL.ZEROIZE.value;
 
@@ -167,7 +190,7 @@
   sha512_core core(
                    .clk(clk),
                    .reset_n(rst_b),
-                   .zeroize(zeroize_pulse),
+                   .zeroize(zeroize_pulse | mbox_ecc_abort),
 
                    .init_cmd(init_reg),
                    .next_cmd(next_reg),
@@ -188,6 +211,12 @@
 //registers for sha core controls
   always_ff @(posedge clk or negedge rst_b) begin : sha_regs
     if (!rst_b) begin
+      digest_reg <= '0;
+      digest_valid_reg <= '0;
+      init_reg <= '0;
+      next_reg <= '0;
+    end
+    else if (wipe_state) begin
       digest_reg <= '0;
       digest_valid_reg <= '0;
       init_reg <= '0;
@@ -238,23 +267,35 @@
                            (block_wptr[BLOCK_OFFSET_W] & ~(num_bytes_wr > hwif_out.DLEN.LENGTH.value));
   always_comb mbox_mode_last_dword_wr = mbox_mode_block_we & (block_wptr == (BLOCK_NO-1));
 
-  //read from mbox is one clock ahead of writes
-  //stall reads based on hold signal from mbox (which is asserted during ECC write-back)
-  //don't read the next dword if we are writing the last dword of a block and core isn't ready
-  //keep stalling the read once the block is full until core is ready - this will reset the block pointer and start the next one
-  always_comb mbox_read_en = mailbox_mode & ~mbox_read_done & !sha_sram_hold & ~(mbox_mode_last_dword_wr | block_full);
-
-  always_comb sha_sram_req_dv = mbox_read_en;
-  always_comb sha_sram_req_addr = mbox_rdptr[CPTRA_MBOX_ADDR_W-1:0];
-  assign sha_lock_active_o      = 1'b0;
-  assign sha_lock_start_dword_o = 11'h0;
-  assign sha_lock_end_dword_o   = 12'h0;
-  wire _unused_sha_sram_ext = &{1'b0, sha_sram_resp_dv, sha_sram_resp_ecc_err};
+  always_comb mbox_start_dword = hwif_out.START_ADDRESS.ADDR.value[12:2];
+  always_comb mbox_dlen_dwords = 12'((hwif_out.DLEN.LENGTH.value[13:0] + 14'd3) >> 2);
+  always_comb mbox_end_dword   = {1'b0, mbox_start_dword} + mbox_dlen_dwords;
+  always_comb mbox_bounds_err  = (hwif_out.START_ADDRESS.ADDR.value[1:0] != 2'b00) ||
+                                 (hwif_out.START_ADDRESS.ADDR.value >= 32'h0000_2000) ||
+                                 (({1'b0, hwif_out.START_ADDRESS.ADDR.value} + {1'b0, hwif_out.DLEN.LENGTH.value}) > 33'h0_0000_2000);
+  always_comb mbox_bounds_abort = (sha_fsm_ps == SHA_IDLE) && mailbox_mode && execute_set &&
+                                  (mbox_inflight_q == 3'd0) && mbox_bounds_err;
+  always_comb mbox_ecc_abort    = mbox_req_active_state && sha_sram_resp_dv && sha_sram_resp_ecc_err;
+  always_comb wipe_state        = zeroize_pulse || mbox_bounds_abort || mbox_ecc_abort;
+
+  always_comb mbox_req_active_state = mailbox_mode && ((sha_fsm_ps == SHA_BLOCK_0) || (sha_fsm_ps == SHA_BLOCK_N));
+  always_comb mbox_read_en = mbox_req_active_state && !mbox_read_done && !(init_reg | next_reg) &&
+                             ((block_wptr + {3'b0, mbox_inflight_q}) < 6'd32);
+
+  always_comb sha_sram_req_dv   = mbox_read_en;
+  always_comb sha_sram_req_addr = {{(CPTRA_MBOX_ADDR_W-11){1'b0}}, mbox_rd_dword_q[10:0]};
+  always_comb mbox_req_fire     = sha_sram_req_dv && !sha_sram_hold;
+
+  assign sha_lock_active_o      = mailbox_mode &&
+                                  ((sha_fsm_ps == SHA_BLOCK_0) || (sha_fsm_ps == SHA_BLOCK_N) ||
+                                   (sha_fsm_ps == SHA_PAD0)    || (sha_fsm_ps == SHA_PAD1));
+  assign sha_lock_start_dword_o = lock_start_q;
+  assign sha_lock_end_dword_o   = lock_end_q;
 
   //stall the write if we are trying to stream datain and it's the end of a block but the core isn't ready
   always_comb stall_write = datain_write & block_full;
 
-  always_comb mbox_mode_block_we = (mailbox_mode & mbox_block_we);
+  always_comb mbox_mode_block_we = mbox_req_active_state && sha_sram_resp_dv && !sha_sram_resp_ecc_err;
   always_comb stream_mode_block_we = (streaming_mode & datain_write & ~stall_write);
 
   always_comb block_we = mbox_mode_block_we | stream_mode_block_we | iccm_mode_block_we;
@@ -282,34 +323,60 @@
 
   always_ff @(posedge clk or negedge rst_b) begin : api_regs
     if (~rst_b) begin
-      soc_has_lock  <= '0;
-      block_wptr    <= '0;
-      mbox_rdptr    <= '0;
-      mbox_block_we <= '0;
-      block_reg     <= '0;
-      num_bytes_wr  <= '0;
+      soc_has_lock    <= '0;
+      block_wptr      <= '0;
+      mbox_rdptr      <= '0;
+      mbox_block_we   <= '0;
+      block_reg       <= '0;
+      num_bytes_wr    <= '0;
+      lock_start_q    <= '0;
+      lock_end_q      <= '0;
+      mbox_rd_dword_q <= '0;
+      mbox_inflight_q <= '0;
     end
     else begin
       soc_has_lock <= (hwif_in.lock_set & req_data.soc_req) ? '1 : 
                        hwif_out.LOCK.LOCK.value ? soc_has_lock : '0;
 
-      block_wptr <= (arc_SHA_BLOCK_0_SHA_BLOCK_N | arc_SHA_BLOCK_N_SHA_BLOCK_N | arc_IDLE) ? '0 :
-                    block_we                                                               ? block_wptr + 'd1 : 
-                                                                                             block_wptr;
-
-      mbox_rdptr <= arc_SHA_IDLE_SHA_BLOCK_0 & mailbox_mode ? {1'b0,mbox_start_addr} :
-                    mbox_read_en                            ? mbox_rdptr + 'd1 :
-                                                              mbox_rdptr;
-
-      mbox_block_we <= mbox_read_en;
-
-      num_bytes_wr <= arc_IDLE ? '0 :
-                      block_we ? num_bytes_wr + 'd4 : num_bytes_wr;
-
-      for (int dword = 0; dword < BLOCK_NO; dword++) begin
-        block_reg[dword] <= extend_load_block                                       ? extend_block[dword] :
-                            block_we & (block_wptr[BLOCK_OFFSET_W-1:0] == dword)    ? block_wdata :
-                                                                                      block_reg_nxt[dword];
+      mbox_inflight_q <= mbox_inflight_q + (mbox_req_fire ? 3'd1 : 3'd0) - (sha_sram_resp_dv ? 3'd1 : 3'd0);
+
+      if (wipe_state) begin
+        block_wptr      <= '0;
+        mbox_rdptr      <= '0;
+        mbox_block_we   <= '0;
+        block_reg       <= '0;
+        num_bytes_wr    <= '0;
+        lock_start_q    <= '0;
+        lock_end_q      <= '0;
+        mbox_rd_dword_q <= '0;
+      end else begin
+        block_wptr <= (arc_SHA_BLOCK_0_SHA_BLOCK_N | arc_SHA_BLOCK_N_SHA_BLOCK_N | arc_IDLE) ? '0 :
+                      block_we                                                               ? block_wptr + 'd1 : 
+                                                                                               block_wptr;
+
+        mbox_rdptr <= '0;
+        mbox_block_we <= mbox_mode_block_we;
+
+        if (arc_IDLE) begin
+          lock_start_q    <= '0;
+          lock_end_q      <= '0;
+          mbox_rd_dword_q <= '0;
+        end else if ((arc_SHA_IDLE_SHA_BLOCK_0 | arc_SHA_IDLE_SHA_PAD0) & mailbox_mode) begin
+          lock_start_q    <= mbox_start_dword;
+          lock_end_q      <= mbox_end_dword;
+          mbox_rd_dword_q <= {1'b0, mbox_start_dword};
+        end else if (mbox_req_fire) begin
+          mbox_rd_dword_q <= mbox_rd_dword_q + 12'd1;
+        end
+
+        num_bytes_wr <= arc_IDLE ? '0 :
+                        block_we ? num_bytes_wr + 'd4 : num_bytes_wr;
+
+        for (int dword = 0; dword < BLOCK_NO; dword++) begin
+          block_reg[dword] <= extend_load_block                                       ? extend_block[dword] :
+                              block_we & (block_wptr[BLOCK_OFFSET_W-1:0] == dword)    ? block_wdata :
+                                                                                        block_reg_nxt[dword];
+        end
       end
     end
   end
@@ -324,9 +391,7 @@
   assign extra_pad_block_required = (num_bytes_data >= 'd112);
 
   always_comb begin : sha_padding_logic
-    pad_mask = '1;
-    //set the valid bytes to '1 to keep the valid data and zero out the rest
-    pad_mask = pad_mask << (1024-(num_bytes_data*8));
+    pad_mask = (num_bytes_data == '0) ? '0 : ('1 << (1024 - (int'(num_bytes_data) * 8)));
     //we append the length in bits to the least significant 128 bits
     pad_length = {{($bits(pad_length)-32){1'b0}}, effective_dlen} << 3;
 
@@ -368,48 +433,48 @@
                                                   hwif_out.DLEN.LENGTH.value[CPTRA_MBOX_ADDR_W+2:2] + 
                                                   (hwif_out.DLEN.LENGTH.value[1] | hwif_out.DLEN.LENGTH.value[0]);
   
-  always_comb mbox_read_done = (sha_fsm_ps == SHA_IDLE) | ~mailbox_mode | 
-                               //If the DLEN overflowed our end address, just read to the end of the mailbox and stop
-                               //Otherwise read until read pointer == end address
-                               (~mbox_read_to_end & mbox_rdptr[CPTRA_MBOX_ADDR_W-1:0] == mbox_end_addr) | 
-                               (mbox_read_to_end & mbox_rdptr[CPTRA_MBOX_ADDR_W]);
+  always_comb mbox_read_done = ~mbox_req_active_state | (mbox_rd_dword_q >= lock_end_q);
 
   //HW API State Machine
   //whenever lock is cleared, go back to idle (in iccm_mode, lock is held by HW so this won't fire)
   always_comb arc_IDLE = ~hwif_out.LOCK.LOCK.value & ~iccm_mode;
+  always_comb empty_msg_exec = execute_set & (hwif_out.DLEN.LENGTH.value == 32'd0) &
+                               (streaming_mode | (mailbox_mode & ~mbox_bounds_err & (mbox_inflight_q == 3'd0)));
+
+  // Zero-length execution from IDLE -- skip directly to PAD0
+  always_comb arc_SHA_IDLE_SHA_PAD0 = (sha_fsm_ps == SHA_IDLE) & ~wipe_state &
+                                      ((iccm_mode_execute & (iccm_num_bytes_wr == '0)) | empty_msg_exec);
+
   //Streaming mode - go to block 0 when first datain comes
-  //Mailbox mode - go to block 0 when execute is set
+  //Mailbox mode - go to block 0 when execute is set (in-bounds and non-zero length)
   //ICCM mode - go to block 0 when first iccm write arrives
-  always_comb arc_SHA_IDLE_SHA_BLOCK_0 = (sha_fsm_ps == SHA_IDLE) & (
+  always_comb arc_SHA_IDLE_SHA_BLOCK_0 = (sha_fsm_ps == SHA_IDLE) & ~wipe_state & ~arc_SHA_IDLE_SHA_PAD0 & (
                                          (streaming_mode & datain_write) |
-                                         (mailbox_mode & execute_set) |
+                                         (mailbox_mode & execute_set & ~mbox_bounds_err & (mbox_inflight_q == 3'd0)) |
                                          (iccm_mode & iccm_hash_dv_i));
 
-  // ICCM zero-length: lock asserts from IDLE with no prior writes -- skip to PAD0
-  always_comb arc_SHA_IDLE_SHA_PAD0 = (sha_fsm_ps == SHA_IDLE) & iccm_mode_execute &
-                                      (iccm_num_bytes_wr == '0);
   //When a full block is complete, send INIT and move to BLOCK_N state
-  always_comb arc_SHA_BLOCK_0_SHA_BLOCK_N = (sha_fsm_ps == SHA_BLOCK_0) & block_full & core_ready_q;
-  always_comb arc_SHA_BLOCK_N_SHA_BLOCK_N = (sha_fsm_ps == SHA_BLOCK_N) & block_full & core_ready_q;
+  always_comb arc_SHA_BLOCK_0_SHA_BLOCK_N = (sha_fsm_ps == SHA_BLOCK_0) & ~wipe_state & block_full & core_ready_q;
+  always_comb arc_SHA_BLOCK_N_SHA_BLOCK_N = (sha_fsm_ps == SHA_BLOCK_N) & ~wipe_state & block_full & core_ready_q;
   //When execute is set for streaming, OR we reach the end of the mailbox region, move to PAD0
   //For ICCM mode, move to PAD0 when iccm_lock asserts (finalize trigger)
   //If a block ends on 1024 bit boundary, we can't move to PAD until that block is processed
   //so we give priority to the end of block arcs, and move to PAD only after core is ready for the pad block
-  always_comb arc_SHA_BLOCK_0_SHA_PAD0 = (sha_fsm_ps == SHA_BLOCK_0) & ~arc_SHA_BLOCK_0_SHA_BLOCK_N &
+  always_comb arc_SHA_BLOCK_0_SHA_PAD0 = (sha_fsm_ps == SHA_BLOCK_0) & ~wipe_state & ~arc_SHA_BLOCK_0_SHA_BLOCK_N &
                                          (streaming_mode & (execute_set & core_ready_q) |
-                                          mailbox_mode & (mbox_read_done & ~block_we & core_ready_q) |
+                                          mailbox_mode & (mbox_read_done & (mbox_inflight_q == 3'd0) & ~block_we & core_ready_q) |
                                           iccm_mode & (iccm_mode_execute & core_ready_q));
-  always_comb arc_SHA_BLOCK_N_SHA_PAD0 = (sha_fsm_ps == SHA_BLOCK_N) & ~arc_SHA_BLOCK_N_SHA_BLOCK_N &
+  always_comb arc_SHA_BLOCK_N_SHA_PAD0 = (sha_fsm_ps == SHA_BLOCK_N) & ~wipe_state & ~arc_SHA_BLOCK_N_SHA_BLOCK_N &
                                          (streaming_mode & (execute_set & core_ready_q) |
-                                          mailbox_mode & (mbox_read_done & ~block_we & core_ready_q) |
+                                          mailbox_mode & (mbox_read_done & (mbox_inflight_q == 3'd0) & ~block_we & core_ready_q) |
                                           iccm_mode & (iccm_mode_execute & core_ready_q)); 
   //Moving to PAD0 fills in the padding for the current block and sends NEXT command
   //If we can't fit the length into the current block we'll need another block to pad and write the length in
   //So go to PAD1 after PAD0 in this case
-  always_comb arc_SHA_PAD0_SHA_PAD1 = (sha_fsm_ps == SHA_PAD0) & extra_pad_block_required & core_ready_q;                            
+  always_comb arc_SHA_PAD0_SHA_PAD1 = (sha_fsm_ps == SHA_PAD0) & ~wipe_state & extra_pad_block_required & core_ready_q;                            
   //Move to done state as soon as SHA is done with the final padded block
-  always_comb arc_SHA_PAD0_SHA_DONE = (sha_fsm_ps == SHA_PAD0) & ~extra_pad_block_required & core_digest_valid_q;
-  always_comb arc_SHA_PAD1_SHA_DONE = (sha_fsm_ps == SHA_PAD1) & core_digest_valid_q;
+  always_comb arc_SHA_PAD0_SHA_DONE = (sha_fsm_ps == SHA_PAD0) & ~wipe_state & ~extra_pad_block_required & core_digest_valid_q;
+  always_comb arc_SHA_PAD1_SHA_DONE = (sha_fsm_ps == SHA_PAD1) & ~wipe_state & core_digest_valid_q;
 
   //SHA API FSM State Combo
   always_comb begin : sha_api_combo
@@ -423,26 +488,26 @@
         else if (arc_SHA_IDLE_SHA_BLOCK_0) sha_fsm_ns = SHA_BLOCK_0;
       end
       SHA_BLOCK_0: begin
-        if (arc_IDLE) sha_fsm_ns = SHA_IDLE;
+        if (arc_IDLE | wipe_state) sha_fsm_ns = SHA_IDLE;
         else if (arc_SHA_BLOCK_0_SHA_BLOCK_N) sha_fsm_ns = SHA_BLOCK_N;
         else if (arc_SHA_BLOCK_0_SHA_PAD0) sha_fsm_ns = SHA_PAD0;
       end
       SHA_BLOCK_N: begin
-        if (arc_IDLE) sha_fsm_ns = SHA_IDLE;
+        if (arc_IDLE | wipe_state) sha_fsm_ns = SHA_IDLE;
         else if (arc_SHA_BLOCK_N_SHA_BLOCK_N) sha_fsm_ns = SHA_BLOCK_N;
         else if (arc_SHA_BLOCK_N_SHA_PAD0) sha_fsm_ns = SHA_PAD0;
       end
       SHA_PAD0: begin
-        if (arc_IDLE) sha_fsm_ns = SHA_IDLE;
+        if (arc_IDLE | wipe_state) sha_fsm_ns = SHA_IDLE;
         else if (arc_SHA_PAD0_SHA_PAD1) sha_fsm_ns = SHA_PAD1;
         else if (arc_SHA_PAD0_SHA_DONE) sha_fsm_ns = SHA_DONE;
       end
       SHA_PAD1: begin
-        if (arc_IDLE) sha_fsm_ns = SHA_IDLE;
+        if (arc_IDLE | wipe_state) sha_fsm_ns = SHA_IDLE;
         else if (arc_SHA_PAD1_SHA_DONE) sha_fsm_ns = SHA_DONE;
       end
       SHA_DONE: begin
-        if (arc_IDLE) sha_fsm_ns = SHA_IDLE;
+        if (arc_IDLE | wipe_state) sha_fsm_ns = SHA_IDLE;
       end
       SHA_ERROR: begin
         // Terminal error state — sticky until reset
@@ -459,11 +524,11 @@
 
 //register hw interface
 always_comb begin
-  hwif_in.STATUS.VALID.next = (sha_fsm_ps == SHA_DONE) & ~iccm_mode;
-  hwif_in.EXECUTE.EXECUTE.hwclr = arc_IDLE;
+  hwif_in.STATUS.VALID.next = (sha_fsm_ps == SHA_DONE) & ~iccm_mode & ~wipe_state;
+  hwif_in.EXECUTE.EXECUTE.hwclr = arc_IDLE | wipe_state;
   for (int dword =0; dword < 16; dword++) begin
     hwif_in.DIGEST[dword].DIGEST.next = digest_reg[dword];
-    hwif_in.DIGEST[dword].DIGEST.hwclr = zeroize_pulse;
+    hwif_in.DIGEST[dword].DIGEST.hwclr = wipe_state;
   end
 end
 
@@ -482,11 +547,11 @@
     .clk(clk),
     .rst(1'b0),
 
-    .s_cpuif_req         (req_dv & (req_data.addr[SOC_IFC_ADDR_W-1:SHA512_ACC_CSR_ADDR_WIDTH] == SHA_REG_START_ADDR[SOC_IFC_ADDR_W-1:SHA512_ACC_CSR_ADDR_WIDTH])),
+    .s_cpuif_req         (req_dv & cpuif_addr_hit),
     .s_cpuif_req_is_wr   (req_data.write),
     .s_cpuif_addr        (req_data.addr[SHA512_ACC_CSR_ADDR_WIDTH-1:0]),
     .s_cpuif_wr_data     (req_data.wdata),
-    .s_cpuif_wr_biten    (reg_biten),
+    .s_cpuif_wr_biten    (unauth_control_wr ? '0 : reg_biten),
     .s_cpuif_req_stall_wr( ),
     .s_cpuif_req_stall_rd( ),
     .s_cpuif_rd_ack      ( ),
@@ -502,16 +567,17 @@
 //Error conditions
 //mailbox mode addressing errors
 logic mailbox_address_err;
-always_comb mailbox_address_err = (mbox_end_addr < mbox_start_addr); //calculated end comes before start
+always_comb mailbox_address_err = mbox_bounds_err | (mbox_end_addr < mbox_start_addr) | mbox_read_to_end | mbox_mode_last_dword_wr;
+wire _unused_mbox_addr = &{1'b0, mailbox_address_err, mbox_rdptr};
 
 //interrupt register hw interface
 assign hwif_in.cptra_rst_b = rst_b;
 assign hwif_in.cptra_pwrgood = cptra_pwrgood;
 assign hwif_in.intr_block_rf.notif_internal_intr_r.notif_cmd_done_sts.hwset = ~soc_has_lock & ~iccm_mode & (arc_SHA_PAD0_SHA_DONE | arc_SHA_PAD1_SHA_DONE);
 assign hwif_in.intr_block_rf.error_internal_intr_r.error0_sts.hwset = sha_fsm_error; // FSM glitch/invalid encoding detected
-assign hwif_in.intr_block_rf.error_internal_intr_r.error1_sts.hwset = 1'b0; // TODO
-assign hwif_in.intr_block_rf.error_internal_intr_r.error2_sts.hwset = 1'b0; // TODO
-assign hwif_in.intr_block_rf.error_internal_intr_r.error3_sts.hwset = 1'b0; // TODO
+assign hwif_in.intr_block_rf.error_internal_intr_r.error1_sts.hwset = mbox_bounds_abort;
+assign hwif_in.intr_block_rf.error_internal_intr_r.error2_sts.hwset = mbox_ecc_abort;
+assign hwif_in.intr_block_rf.error_internal_intr_r.error3_sts.hwset = 1'b0;
 
 assign error_intr = hwif_out.intr_block_rf.error_global_intr_r.intr;
 assign notif_intr = hwif_out.intr_block_rf.notif_global_intr_r.intr;

--- a/environment/public/code/axi_sub_rd.sv (Buggy Starter)
+++ b/solution/gold/code/axi_sub_rd.sv (Golden Reference)
@@ -193,8 +193,10 @@
     // To check this, look at the 'ready' output from all stages of the
     // skidbuffer pipeline (but omit the C_LAT+1 index because that comes from
     // axi rready)
-    assign dv = txn_active && &dp_rready[C_LAT:0];
-    assign txn_rvalid[0] = dv && !hld;
+    logic txn_illegal;
+    assign txn_illegal = (txn_ctx.size > 3'(BW)) || (txn_ctx.burst == AXI_BURST_RESERVED);
+    assign dv = txn_active && !txn_illegal && &dp_rready[C_LAT:0];
+    assign txn_rvalid[0] = txn_illegal ? (txn_active && &dp_rready[C_LAT:0]) : (dv && !hld);
 
     // Asserts on the final beat of the COMPONENT INF which means it lags the
     // final AXI beat by at least C_LAT clocks (or more depending on backpressure)
@@ -230,7 +232,7 @@
     assign txn_xfer_ctx[0].id   = txn_ctx.id;
     assign txn_xfer_ctx[0].user = txn_ctx.user;
     assign txn_xfer_ctx[0].last = txn_cnt == 0;
-    assign txn_xfer_ctx[0].resp =
+    assign txn_xfer_ctx[0].resp = txn_illegal ? AXI_RESP_SLVERR :
     `ifdef CALIPTRA_AXI_SUB_EX_EN
                                   txn_ctx.lock ? AXI_RESP_EXOKAY :
     `endif
@@ -322,11 +324,13 @@
     // --------------------------------------- //
     // Data/Response                           //
     // --------------------------------------- //
+    logic beat_err;
+    assign beat_err       = err || (txn_xfer_ctx[C_LAT].resp == AXI_RESP_SLVERR);
     assign dp_rvalid[0]   = txn_rvalid[C_LAT];
-    assign dp_rdata[0]    = rdata;
+    assign dp_rdata[0]    = beat_err ? '0 : rdata;
     assign dp_xfer_ctx[0].id   = txn_xfer_ctx[C_LAT].id;
     assign dp_xfer_ctx[0].user = txn_xfer_ctx[C_LAT].user; // NOTE: Unused after it enters data pipeline
-    assign dp_xfer_ctx[0].resp = err   ? AXI_RESP_SLVERR :
+    assign dp_xfer_ctx[0].resp = beat_err ? AXI_RESP_SLVERR :
     `ifdef CALIPTRA_AXI_SUB_EX_EN
                                          txn_xfer_ctx[C_LAT].resp;
     `else

--- a/environment/public/code/axi_sub_wr.sv (Buggy Starter)
+++ b/solution/gold/code/axi_sub_wr.sv (Golden Reference)
@@ -203,6 +203,11 @@
         assign txn_allow = 1'b1;
     `endif
 
+    logic txn_illegal;
+    logic txn_abort;
+    assign txn_illegal = (txn_ctx.size > 3'(BW)) || (txn_ctx.burst == AXI_BURST_RESERVED);
+    assign txn_abort   = txn_illegal || txn_err;
+
     always_ff@(posedge clk or negedge rst_n) begin
         if (!rst_n) begin
             txn_ctx   <= '{default:0, burst:AXI_BURST_FIXED};
@@ -222,9 +227,9 @@
             `ifdef CALIPTRA_AXI_SUB_EX_EN
             txn_allow     <= !req_ctx.lock || (ex_active[req_ctx.id] && req_matches_ex);
             `endif
-            txn_err       <= 1'b0;
-        end
-        else if (dv && !hld) begin
+            txn_err       <= (req_ctx.size > 3'(BW)) || (req_ctx.burst == AXI_BURST_RESERVED);
+        end
+        else if ((dv && !hld) || (dv_pre && (!txn_allow || txn_abort))) begin
             txn_ctx.addr  <= txn_addr_nxt;
             txn_ctx.burst <= txn_ctx.burst;
             txn_ctx.size  <= txn_ctx.size;
@@ -232,7 +237,7 @@
             txn_ctx.user  <= txn_ctx.user;
             txn_ctx.id    <= txn_ctx.id  ;
             txn_ctx.lock  <= txn_ctx.lock;
-            txn_err       <= txn_err || err;
+            txn_err       <= txn_err || txn_illegal || (dv && err);
         end
         else begin
             txn_ctx       <= txn_ctx;
@@ -242,7 +247,7 @@
 
     // Asserts on the final COMPONENT INF beat, which means data does not
     // arrive at endpoint until after C_LAT clocks
-    assign txn_final_beat = dv_pre && (!txn_allow || !hld) && last;
+    assign txn_final_beat = dv_pre && (!txn_allow || txn_abort || !hld) && last;
 
 
     // --------------------------------------- //
@@ -323,13 +328,13 @@
                   s_axi_if.wstrb,
                   s_axi_if.wlast}),
         .o_valid(dv_pre          ),
-        .i_ready(!hld            ),
+        .i_ready(!hld || !txn_allow || txn_abort),
         .o_data ({wdata,
                   wstrb,
                   last }         )
     );
 
-    assign dv = dv_pre && txn_allow;
+    assign dv = dv_pre && txn_allow && !txn_abort;
 
     // Registered skidbuffer to pipeline response signals.
     // Skid buffer captures any response transfer if the
@@ -338,9 +343,9 @@
     // There is guaranteed to be space in the skid buffer because new
     // requests are stalled (AWREADY=0) until this buffer is ready.
     assign rp_valid = txn_final_beat;
-    assign rp_resp  = txn_allow && (txn_err || err) ? AXI_RESP_SLVERR :
-                      txn_allow && txn_ctx.lock     ? AXI_RESP_EXOKAY :
-                                                      AXI_RESP_OKAY;
+    assign rp_resp  = (txn_illegal || (txn_allow && (txn_err || err))) ? AXI_RESP_SLVERR :
+                      txn_allow && txn_ctx.lock                        ? AXI_RESP_EXOKAY :
+                                                                         AXI_RESP_OKAY;
     assign rp_id    = txn_ctx.id;
 
     skidbuffer #(

--- a/environment/public/code/rot_sram_ecc_ctrl.sv (Buggy Starter)
+++ b/solution/gold/code/rot_sram_ecc_ctrl.sv (Golden Reference)
@@ -46,108 +46,238 @@
 
   localparam int unsigned NUM_BANKS = 8;
 
-  logic [38:0] enc_codeword_raw, enc_codeword;
-  logic [63:0] bank_dout [NUM_BANKS];
-  logic [63:0] bank_din, bank_bm;
-  logic [NUM_BANKS-1:0] bank_men, bank_wen, bank_ren;
-  logic [7:0]  bank_row_addr;
-
-  logic        sha_win;
-  logic [10:0] req
```

</details>

---

## 5. Harbor Package File Inventory & Provenance

### Public Workspace (`environment/public/`)
- [`environment/public/BUILD.md`](environment/public/BUILD.md) *(Read-Only Context)*
- [`environment/public/code/LICENSE`](environment/public/code/LICENSE) *(Read-Only Context)*
- [`environment/public/code/axi_addr.v`](environment/public/code/axi_addr.v) *(Read-Only Context)*
- [`environment/public/code/axi_if.sv`](environment/public/code/axi_if.sv) *(Read-Only Context)*
- [`environment/public/code/axi_pkg.sv`](environment/public/code/axi_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/axi_sub.sv`](environment/public/code/axi_sub.sv) *(Read-Only Context)*
- [`environment/public/code/axi_sub_arb.sv`](environment/public/code/axi_sub_arb.sv) *(Read-Only Context)*
- [`environment/public/code/axi_sub_rd.sv`](environment/public/code/axi_sub_rd.sv) **(Editable)**
- [`environment/public/code/axi_sub_wr.sv`](environment/public/code/axi_sub_wr.sv) **(Editable)**
- [`environment/public/code/caliptra_2ff_sync.sv`](environment/public/code/caliptra_2ff_sync.sv) *(Read-Only Context)*
- [`environment/public/code/caliptra_macros.svh`](environment/public/code/caliptra_macros.svh) *(Read-Only Context)*
- [`environment/public/code/caliptra_prim_assert.sv`](environment/public/code/caliptra_prim_assert.sv) *(Read-Only Context)*
- [`environment/public/code/caliptra_prim_assert_dummy_macros.svh`](environment/public/code/caliptra_prim_assert_dummy_macros.svh) *(Read-Only Context)*
- [`environment/public/code/caliptra_prim_assert_sec_cm.svh`](environment/public/code/caliptra_prim_assert_sec_cm.svh) *(Read-Only Context)*
- [`environment/public/code/caliptra_prim_assert_standard_macros.svh`](environment/public/code/caliptra_prim_assert_standard_macros.svh) *(Read-Only Context)*
- [`environment/public/code/caliptra_prim_assert_yosys_macros.svh`](environment/public/code/caliptra_prim_assert_yosys_macros.svh) *(Read-Only Context)*
- [`environment/public/code/caliptra_prim_flop.sv`](environment/public/code/caliptra_prim_flop.sv) *(Read-Only Context)*
- [`environment/public/code/caliptra_prim_flop_macros.sv`](environment/public/code/caliptra_prim_flop_macros.sv) *(Read-Only Context)*
- [`environment/public/code/caliptra_prim_generic_flop.sv`](environment/public/code/caliptra_prim_generic_flop.sv) *(Read-Only Context)*
- [`environment/public/code/caliptra_prim_module_name_macros.svh`](environment/public/code/caliptra_prim_module_name_macros.svh) *(Read-Only Context)*
- [`environment/public/code/caliptra_prim_mubi_pkg.sv`](environment/public/code/caliptra_prim_mubi_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/caliptra_prim_pkg.sv`](environment/public/code/caliptra_prim_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/caliptra_prim_secded_inv_39_32_dec.sv`](environment/public/code/caliptra_prim_secded_inv_39_32_dec.sv) *(Read-Only Context)*
- [`environment/public/code/caliptra_prim_secded_inv_39_32_enc.sv`](environment/public/code/caliptra_prim_secded_inv_39_32_enc.sv) *(Read-Only Context)*
- [`environment/public/code/caliptra_prim_sparse_fsm_flop.sv`](environment/public/code/caliptra_prim_sparse_fsm_flop.sv) *(Read-Only Context)*
- [`environment/public/code/caliptra_prim_util_pkg.sv`](environment/public/code/caliptra_prim_util_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/caliptra_reg_defines.svh`](environment/public/code/caliptra_reg_defines.svh) *(Read-Only Context)*
- [`environment/public/code/caliptra_reg_field_defines.svh`](environment/public/code/caliptra_reg_field_defines.svh) *(Read-Only Context)*
- [`environment/public/code/caliptra_sva.svh`](environment/public/code/caliptra_sva.svh) *(Read-Only Context)*
- [`environment/public/code/config_defines.svh`](environment/public/code/config_defines.svh) *(Read-Only Context)*
- [`environment/public/code/kv_defines_pkg.sv`](environment/public/code/kv_defines_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/mbox_pkg.sv`](environment/public/code/mbox_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/pv_defines_pkg.sv`](environment/public/code/pv_defines_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/rot_sram_ecc_ctrl.sv`](environment/public/code/rot_sram_ecc_ctrl.sv) **(Editable)**
- [`environment/public/code/rot_staging_subsys.sv`](environment/public/code/rot_staging_subsys.sv) *(Read-Only Context)*
- [`environment/public/code/sha512_acc_csr.sv`](environment/public/code/sha512_acc_csr.sv) *(Read-Only Context)*
- [`environment/public/code/sha512_acc_csr_pkg.sv`](environment/public/code/sha512_acc_csr_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/sha512_acc_top.sv`](environment/public/code/sha512_acc_top.sv) **(Editable)**
- [`environment/public/code/sha512_core.v`](environment/public/code/sha512_core.v) *(Read-Only Context)*
- [`environment/public/code/sha512_h_constants.v`](environment/public/code/sha512_h_constants.v) *(Read-Only Context)*
- [`environment/public/code/sha512_k_constants.v`](environment/public/code/sha512_k_constants.v) *(Read-Only Context)*
- [`environment/public/code/sha512_params_pkg.sv`](environment/public/code/sha512_params_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/sha512_w_mem.v`](environment/public/code/sha512_w_mem.v) *(Read-Only Context)*
- [`environment/public/code/skidbuffer.v`](environment/public/code/skidbuffer.v) *(Read-Only Context)*
- [`environment/public/code/soc_ifc_pkg.sv`](environment/public/code/soc_ifc_pkg.sv) *(Read-Only Context)*
- [`environment/public/constraints/rot_staging_subsys.sdc`](environment/public/constraints/rot_staging_subsys.sdc) **(Editable)**
- [`environment/public/issue.md`](environment/public/issue.md) *(Read-Only Context)*
- [`environment/public/pdk/256.lef`](environment/public/pdk/256.lef) *(Read-Only Context)*
- [`environment/public/pdk/256.lib`](environment/public/pdk/256.lib) *(Read-Only Context)*
- [`environment/public/pdk/256.v`](environment/public/pdk/256.v) *(Read-Only Context)*
- [`environment/public/pdk/256_stub.v`](environment/public/pdk/256_stub.v) *(Read-Only Context)*
- [`environment/public/pdk/LICENSE.IHP`](environment/public/pdk/LICENSE.IHP) *(Read-Only Context)*
- [`environment/public/pdk/core.v`](environment/public/pdk/core.v) *(Read-Only Context)*
- [`environment/public/pdk/sg13g2_stdcell.lef`](environment/public/pdk/sg13g2_stdcell.lef) *(Read-Only Context)*
- [`environment/public/pdk/sg13g2_stdcell_typ_1p20V_25C.lib`](environment/public/pdk/sg13g2_stdcell_typ_1p20V_25C.lib) *(Read-Only Context)*
- [`environment/public/pdk/sg13g2_tech.lef`](environment/public/pdk/sg13g2_tech.lef) *(Read-Only Context)*
- [`environment/public/plan/macro_placement.json`](environment/public/plan/macro_placement.json) **(Editable)**

### Reference Solutions & Isolated Verifier (`solution/` & `tests/`)
- [`solution/solve.sh`](solution/solve.sh) — Harbor oracle script
- [`solution/gold/`](solution/gold/) — Primary golden reference solution
- [`solution/alternate_gold/`](solution/alternate_gold/) — Structurally distinct secondary reference solution
- [`tests/test.sh`](tests/test.sh) — Isolated Harbor verifier entrypoint
- [`tests/private/policy_filter.py`](tests/private/policy_filter.py) — Pre-grader airlock & anti-cheat policy screen
- [`tests/private/grader/run.py`](tests/private/grader/run.py) — Deterministic front-to-back EDA verifier

### Upstream Provenance (`SOURCE.md`)

