# `case_25005`: Harden Caliptra HMAC-384/512 & SP 800-90A HMAC_DRBG Prime Rejection, KeyVault Isolation, AHB Word Guards, and Zeroize/Debug Sanitization

[Back to Benchmark Root (`README.md`)](../../README.md) | [Full 94-Task Catalog (`TASKS_INDEX.md`)](../../TASKS_INDEX.md) | [`task.toml`](task.toml) | [`instruction.md`](instruction.md) | [`solution/solve.sh`](solution/solve.sh) | [`tests/test.sh`](tests/test.sh) | [`tests/private/grader/run.py`](tests/private/grader/run.py)

---

## 1. Task Overview & Harbor Configuration

| Field | Value |
| :--- | :--- |
| **Task ID** | `case_25005` |
| **Source Silicon Repository** | `chipsalliance/caliptra-rtl` (`repo_50`) |
| **Engineering Problem Type** | **Gate-Level Equivalence, Security & CDC/RDC** (`PT4_GateLevel_Security_CDC`) |
| **EDA Evaluation Stage** | **Stage 2: Logic Synthesis & Gate-Level Verification** (`stage2_synth_gate`) |
| **Coupled Evaluation Gates** | Stage 1 (Functional RTL Sim) -> Stage 2 (Yosys+Slang Standard-Cell Synthesis, Cell-Area Caps & 4-State Gate-Level X-Propagation Verification) |
| **Primary Hardware Domain** | `Security_RoT_Subsystems` (Security_RoT_Subsystems) |
| **Multi-Domain Tags** | `Security_RoT_Subsystems` |
| **Editable Files (`allowed_edits`)** | [`code/hmac.sv`](environment/public/code/hmac.sv), [`code/hmac_ctrl.sv`](environment/public/code/hmac_ctrl.sv), [`code/hmac_drbg.sv`](environment/public/code/hmac_drbg.sv) (3 files, 1005 LOC) |
| **Public Subsystem Context** | 38 RTL files (9486 LOC) |
| **Base Container Image** | `siliconbench-eda:1.0` (`allow_internet = false`, `environment_mode = "separate"`) |
| **PDK / Environment Profile** | **Standard IEEE 1800-2017 SystemVerilog Dual-Simulator + Yosys Slang** |
| **Task-Customized Collateral?** | **No (Uses Shared Base Image)** — Pure RTL/protocol/synthesis check without external PDK Liberty files. |
| **Verifier Timeout & Seeds** | `600s` total (`300s`/seed) across deterministic seeds `[101, 202]` |

---

## 2. Problem Specification (`issue.md`)

# Caliptra HMAC-384/512 & SP 800-90A HMAC_DRBG Asset Isolation, Rejection Sampling, and Lifecycle Sanitization

## Context

In Caliptra's Root-of-Trust cryptographic subsystem, `code/hmac_ctrl.sv` bridges the 64-bit SoC/uC AHB-Lite slave port to `code/hmac.sv` (managing PeakRDL CSRs, KeyVault read/write clients, and `hmac_core`), while `code/hmac_drbg.sv` drives `hmac_core` to implement NIST SP 800-90A Rev. 1 §10.1.2 / RFC 6979 deterministic scalar generation modulo `HMAC_DRBG_PRIME` (P-384 group order).

Security bring-up across `code/hmac_drbg.sv`, `code/hmac.sv`, and `code/hmac_ctrl.sv` identified cross-module vulnerabilities in prime-order rejection state updates, KeyVault-vs-CSR asset isolation, mid-operation TOCTOU register locking, malformed AHB access handling, and debug/zeroize sanitization. Harden **only** `code/hmac_drbg.sv`, `code/hmac.sv`, and `code/hmac_ctrl.sv` without altering module port interfaces or read-only files in `code/`.

## Security & Architectural Requirements

### 1. SP 800-90A / RFC 6979 Scalar DRBG (`code/hmac_drbg.sv`)
- **Instantiation & Command Filtering**: After reset or `zeroize`, the DRBG is uninstantiated and must ignore `next_cmd` until instantiated by an accepted `init_cmd`. Simultaneous `init_cmd && next_cmd` is invalid and must be ignored without dropping `ready` or disturbing any held `valid`/`drbg` output. Snapshot `entropy`, `nonce`, and `lfsr_seed` on command acceptance so external input transitions or command glitches while busy cannot perturb multi-step derivation.
- **Prime-Order Rejection Sampling**: Every 384-bit candidate $T$ must strictly satisfy $1 \le T < \text{HMAC\_DRBG\_PRIME}$ (rejecting both $T = 0$ and $T \ge \text{HMAC\_DRBG\_PRIME}$). On rejection, update internal $V$ to the generated candidate $T$ before executing the SP 800-90A rejection update ($K \leftarrow \text{HMAC}_K(V \parallel \text{0x00})$, $V \leftarrow \text{HMAC}_K(V)$) and retrying. Keep `ready == 0`, `valid == 0`, and `drbg == '0` throughout all intermediate and rejection rounds until an in-range scalar completes.
- **Zeroization**: Asserting `zeroize` in any state must immediately abort active HMAC/rejection rounds, clear internal $K$/$V$/latched-input state and outputs (`drbg`, `valid`, `ready`), mark the DRBG uninstantiated, and restore `ready` once `zeroize` deasserts and the underlying core is ready.

### 2. KeyVault Asset Isolation & TOCTOU Protection (`code/hmac.sv`)
- **Gap-Free Busy & Control Lockout**: Assert `busy_o` (and deassert `HMAC512_STATUS.READY`) continuously without single-cycle gaps from KeyVault read initiation through KeyVault transfer completion, core hashing, and full KeyVault tag writeback; reflect pending launch cycles in KeyVault status `READY` bits. Lock `HMAC512_CTRL` mode/trigger fields and `HMAC512_KV_WR_CTRL` against software modification while busy or sanitizing.
- **Key & Block Source Isolation**: Starting a KeyVault key or block read must clear all software `HMAC512_KEY[0..15]` or `HMAC512_BLOCK[0..31]` dwords beforehand so shorter KeyVault entries never mix with stale software dwords or mask key-size/key-mode checks. Because `hmac_core` samples key and message blocks dozens of cycles after launch, keep KeyVault-populated key and block registers write-locked against software TOCTOU overwrites (and block `CSR_MODE` override whenever a KeyVault key read or KeyVault key data is active) until KeyVault asset consumption finishes or is sanitized. Suppress core launch whenever key-mode, zero-key, or lone-`LAST` errors are flagged.
- **Destination Tag Isolation**: Whenever KeyVault tag writeback is armed (`HMAC512_KV_WR_CTRL.write_en`) or in progress, immediately clear and hold `HMAC512_TAG[0..15]` at `32'h0` so KeyVault-destined derived secrets and prior CSR tag residue cannot be read via CSRs. For non-KeyVault destinations, zero-mask the lower 128 bits of `HMAC512_TAG` in HMAC-384 mode.

### 3. AHB-Lite Access Enforcement & Debug/Zeroize Sanitization (`code/hmac_ctrl.sv`, `code/hmac.sv`)
- **32-Bit Aligned Word Enforcement**: Every active AHB-Lite transfer (`hsel_i && hready_i && htrans_i[1]`) must be an aligned 32-bit word (`hsize_i == 3'b010`, `haddr_i[1:0] == 2'b00`). Reject byte, halfword, 64-bit, or unaligned transfers with a compliant 2-cycle AHB `H_ERROR` response, zeroed `hrdata_o`, and suppressed register select/write strobes.
- **Zeroize & Debug/Scan Switch**: Either `HMAC512_CTRL.ZEROIZE` or `debugUnlock_or_scan_mode_switch` must immediately abort in-flight core and KeyVault client operations and sanitize all key, block, tag, LFSR seed, `CSR_MODE`, error, and KeyVault control/status state (even if triggered while busy). While `debugUnlock_or_scan_mode_switch` is high, mask `cptra_csr_hmac_key`, block AHB writes, and return `'0` on AHB reads without stalling `hreadyout_o`.

Both `hmac_drbg` and `hmac_ctrl` must synthesize cleanly (`yosys -m slang`) with zero inferred latches and zero combinational loops.

---

## 3. Build & Verification Instructions (`BUILD.md`)

The RTL bundle in `code/` is extracted from `chipsalliance/caliptra-rtl` (`src/hmac/rtl`, `src/hmac_drbg/rtl`, `src/sha512_masked/rtl`, `src/keyvault/rtl`, `src/libs/rtl`, and `src/caliptra_prim/rtl`).

Editable files:
- `code/hmac_drbg.sv`
- `code/hmac.sv`
- `code/hmac_ctrl.sv`

All remaining `.sv`, `.v`, and `.svh` files in `code/` are read-only dependencies.

When compiling with Verilator or Slang/Yosys from the workspace root, pass `-Icode` and list package files before module files:

```bash
verilator --lint-only -sv -Wno-fatal -Icode --top-module hmac_ctrl \
  code/caliptra_prim_util_pkg.sv \
  code/caliptra_prim_mubi_pkg.sv \
  code/caliptra_prim_pkg.sv \
  code/caliptra_prim_cipher_pkg.sv \
  code/ahb_defines_pkg.sv \
  code/kv_defines_pkg.sv \
  code/sha512_masked_defines_pkg.sv \
  code/hmac_param_pkg.sv \
  code/hmac_reg_pkg.sv \
  code/sha512_h_constants.v \
  code/sha512_k_constants.v \
  code/sha512_masked_w_mem.sv \
  code/sha512_masked_core.sv \
  code/caliptra_prim_generic_flop.sv \
  code/caliptra_prim_flop.sv \
  code/caliptra_prim_sparse_fsm_flop.sv \
  code/caliptra_prim_lfsr.sv \
  code/ahb_slv_sif.sv \
  code/kv_fsm.sv \
  code/kv_read_rule_check.sv \
  code/kv_write_rule_check.sv \
  code/kv_read_client.sv \
  code/kv_write_client.sv \
  code/hmac_core.sv \
  code/hmac_reg.sv \
  code/hmac.sv \
  code/hmac_ctrl.sv

verilator --lint-only -sv -Wno-fatal -Icode --top-module hmac_drbg \
  code/caliptra_prim_util_pkg.sv \
  code/caliptra_prim_mubi_pkg.sv \
  code/caliptra_prim_pkg.sv \
  code/caliptra_prim_cipher_pkg.sv \
  code/sha512_masked_defines_pkg.sv \
  code/hmac_param_pkg.sv \
  code/sha512_h_constants.v \
  code/sha512_k_constants.v \
  code/sha512_masked_w_mem.sv \
  code/sha512_masked_core.sv \
  code/caliptra_prim_generic_flop.sv \
  code/caliptra_prim_flop.sv \
  code/caliptra_prim_lfsr.sv \
  code/hmac_core.sv \
  code/hmac_drbg.sv
```

---

## 4. Reference Fix Inspection (Buggy Starter vs. Golden Solution Diff)

> Human reviewers can inspect the exact reference bug fix below, or browse full files in [`environment/public/`](environment/public/), [`solution/gold/`](solution/gold/), and [`solution/alternate_gold/`](solution/alternate_gold/).

<details open>
<summary><b>Click to expand/collapse Unified Diff (<code>environment/public/</code> vs. <code>solution/gold/</code>)</b></summary>

```diff
--- a/environment/public/code/hmac.sv (Buggy Starter)
+++ b/solution/gold/code/hmac.sv (Golden Reference)
@@ -79,11 +79,17 @@
   localparam TAG_NUM_DWORDS   = TAG_SIZE / DATA_WIDTH;
   localparam SEED_NUM_DWORDS  = ((LFSR_SEED_SIZE - 1) / DATA_WIDTH) + 1;
 
+  localparam logic [HMAC_REG_ADDR_WIDTH-1:0] CTRL_ADDR_OFFSET      = 12'h010;
+  localparam logic [HMAC_REG_ADDR_WIDTH-1:0] LFSR_SEED_BASE_OFFSET = 12'h140;
+
   reg [KEY_NUM_DWORDS - 1   : 0][DATA_WIDTH - 1 : 0]    key_reg;
   reg [BLOCK_NUM_DWORDS - 1 : 0][DATA_WIDTH - 1 : 0]    block_reg;
   reg [SEED_NUM_DWORDS - 1  : 0][DATA_WIDTH - 1 : 0]    lfsr_seed_reg;
+  reg [SEED_NUM_DWORDS - 1  : 0][DATA_WIDTH - 1 : 0]    lfsr_seed_shadow_q;
+  reg                                                   csr_mode_active_q;
 
   logic zeroize_reg;
+  logic sw_zeroize_write;
 
   //----------------------------------------------------------------
   // Wires.
@@ -131,6 +137,19 @@
   kv_write_filter_metrics_t kv_write_metrics;
   logic core_tag_we;
 
+  logic kv_rd_key_busy;
+  logic kv_rd_block_busy;
+  logic kv_wr_busy;
+  logic subsys_ready;
+  logic ctrl_cmd_pulse;
+  logic cmd_blocked;
+  logic sw_ctrl_allow;
+  logic sw_csr_mode_allow;
+  logic use_csr_key_mode;
+  logic suppress_csr_tag;
+  logic kv_key_preclear;
+  logic kv_block_preclear;
+
   logic key_zero_error, key_zero_error_reg, key_zero_error_edge;
   logic key_mode_error, key_mode_error_reg, key_mode_error_edge;
   logic last_alone_error, last_alone_error_reg, last_alone_error_edge;
@@ -186,9 +205,69 @@
                 );
 
   //----------------------------------------------------------------
+  // Engine & KeyVault busy / isolation qualification
+  //----------------------------------------------------------------
+  always_comb begin
+    zeroize_reg       = hwif_out.HMAC512_CTRL.ZEROIZE.value | debugUnlock_or_scan_mode_switch;
+    sw_zeroize_write  = cs && we && (address[HMAC_REG_ADDR_WIDTH-1:0] == CTRL_ADDR_OFFSET) && write_data[2];
+
+    kv_rd_key_busy    = kv_key_read_ctrl_reg.read_en | ~kv_key_ready;
+    kv_rd_block_busy  = kv_block_read_ctrl_reg.read_en | ~kv_block_ready;
+    kv_wr_busy        = ~kv_write_ready | (core_tag_we & dest_keyvault);
+
+    subsys_ready      = core_ready & ~kv_rd_key_busy & ~kv_rd_block_busy & ~kv_wr_busy & ~zeroize_reg;
+    ctrl_cmd_pulse    = (hwif_out.HMAC512_CTRL.INIT.value | hwif_out.HMAC512_CTRL.NEXT.value) & subsys_ready;
+    cmd_blocked       = error_flag | error_flag_reg | last_alone_error;
+
+    init_reg          = hwif_out.HMAC512_CTRL.INIT.value & subsys_ready & ~cmd_blocked;
+    next_reg          = hwif_out.HMAC512_CTRL.NEXT.value & subsys_ready & ~cmd_blocked;
+    last_reg          = hwif_out.HMAC512_CTRL.LAST.value & (init_reg | next_reg);
+    mode_reg          = hwif_out.HMAC512_CTRL.MODE.value;
+
+    busy_o            = ~core_ready | kv_rd_key_busy | kv_rd_block_busy | kv_wr_busy | init_reg | next_reg;
+    sw_ctrl_allow     = ready_reg & ~busy_o & ~zeroize_reg;
+    sw_csr_mode_allow = sw_ctrl_allow & ~kv_key_data_present & ~kv_key_read_ctrl_reg.read_en;
+
+    use_csr_key_mode  = csr_mode_active_q & ~kv_key_data_present & ~kv_key_read_ctrl_reg.read_en & ~zeroize_reg;
+    suppress_csr_tag  = dest_keyvault | ~kv_write_ready;
+
+    kv_key_preclear   = kv_key_read_ctrl_reg.read_en & ~kv_key_data_present;
+    kv_block_preclear = kv_block_read_ctrl_reg.read_en & ~kv_block_data_present;
+  end
+
+  //----------------------------------------------------------------
+  // Shadow tracking for CSR_MODE and LFSR_SEED sanitization
+  //----------------------------------------------------------------
+  always_ff @(posedge clk or negedge reset_n) begin : shadow_sanitize_regs
+    if (!reset_n) begin
+      csr_mode_active_q  <= 1'b0;
+      lfsr_seed_shadow_q <= '0;
+    end
+    else if (zeroize_reg) begin
+      csr_mode_active_q  <= 1'b0;
+      lfsr_seed_shadow_q <= '0;
+    end
+    else begin
+      if (kv_key_read_ctrl_reg.read_en || kv_key_data_present || sw_zeroize_write) begin
+        csr_mode_active_q <= 1'b0;
+      end
+      else if (cs && we && (address[HMAC_REG_ADDR_WIDTH-1:0] == CTRL_ADDR_OFFSET) && sw_csr_mode_allow) begin
+        csr_mode_active_q <= write_data[4];
+      end
+
+      for (int dword = 0; dword < SEED_NUM_DWORDS; dword++) begin
+        if (cs && we && !busy_o &&
+            (address[HMAC_REG_ADDR_WIDTH-1:0] == (LFSR_SEED_BASE_OFFSET + HMAC_REG_ADDR_WIDTH'(dword * 4)))) begin
+          lfsr_seed_shadow_q[dword] <= write_data;
+        end
+      end
+    end
+  end
+
+  //----------------------------------------------------------------
   // reg_update
   //----------------------------------------------------------------
-  always @(posedge clk or negedge reset_n)
+  always_ff @(posedge clk or negedge reset_n)
     begin : reg_update
       if (!reset_n)
         begin
@@ -213,10 +292,13 @@
       else
         begin
           tag_valid_reg <= core_tag_valid & ~error_flag_reg;
-          ready_reg     <= core_ready;
-
-          if (core_tag_we)
+          ready_reg     <= ~busy_o;
+
+          if (suppress_csr_tag)
+            tag_reg <= '0;
+          else if (core_tag_we)
             tag_reg <= core_tag & get_mask;
+
           if (core_tag_we & (dest_keyvault | kv_data_present))
             kv_reg  <= core_tag & get_mask;
 
@@ -238,66 +320,61 @@
     hwif_in.HMAC512_VERSION[0].VERSION.next = HMAC_CORE_VERSION[31:0];
     hwif_in.HMAC512_VERSION[1].VERSION.next = HMAC_CORE_VERSION[63:32];
 
-    hwif_in.HMAC512_CTRL.CSR_MODE.swwe = ready_reg;
-    hwif_in.HMAC512_CTRL.INIT.swwe     = ready_reg;
-    hwif_in.HMAC512_CTRL.NEXT.swwe     = ready_reg;
-    hwif_in.HMAC512_CTRL.LAST.swwe     = ready_reg;
-    hwif_in.HMAC512_CTRL.MODE.swwe     = ready_reg;
-
-    init_reg    = hwif_out.HMAC512_CTRL.INIT.value & kv_key_ready & kv_block_ready;
-    next_reg    = hwif_out.HMAC512_CTRL.NEXT.value & kv_key_ready & kv_block_ready;
-    last_reg    = hwif_out.HMAC512_CTRL.LAST.value & kv_key_ready & kv_block_ready;
-    zeroize_reg = hwif_out.HMAC512_CTRL.ZEROIZE.value;
-    mode_reg    = hwif_out.HMAC512_CTRL.MODE.value;
-
-    hwif_in.HMAC512_STATUS.READY.next = ready_reg;
-    hwif_in.HMAC512_STATUS.VALID.next = tag_valid_reg;
+    hwif_in.HMAC512_CTRL.CSR_MODE.swwe = sw_csr_mode_allow;
+    hwif_in.HMAC512_CTRL.INIT.swwe     = sw_ctrl_allow;
+    hwif_in.HMAC512_CTRL.NEXT.swwe     = sw_ctrl_allow;
+    hwif_in.HMAC512_CTRL.LAST.swwe     = sw_ctrl_allow;
+    hwif_in.HMAC512_CTRL.MODE.swwe     = sw_ctrl_allow;
+
+    hwif_in.HMAC512_STATUS.READY.next = ready_reg & ~busy_o & ~zeroize_reg;
+    hwif_in.HMAC512_STATUS.VALID.next = tag_valid_reg & ~zeroize_reg;
     for (int dword = 0; dword < TAG_NUM_DWORDS; dword++) begin
-      hwif_in.HMAC512_TAG[dword].TAG.next  = tag_reg[(TAG_NUM_DWORDS - 1) - dword];
-      hwif_in.HMAC512_TAG[dword].TAG.hwclr = zeroize_reg;
+      hwif_in.HMAC512_TAG[dword].TAG.next  = suppress_csr_tag ? 32'h0 : tag_reg[(TAG_NUM_DWORDS - 1) - dword];
+      hwif_in.HMAC512_TAG[dword].TAG.hwclr = zeroize_reg | suppress_csr_tag;
     end
 
     for (int dword = 0; dword < BLOCK_NUM_DWORDS; dword++) begin
-      hwif_in.HMAC512_BLOCK[dword].BLOCK.we    = (kv_block_write_en & (kv_block_write_offset == dword)) & !(zeroize_reg | kv_data_present_reset);
+      hwif_in.HMAC512_BLOCK[dword].BLOCK.we    = (kv_block_write_en & (kv_block_write_offset == 5'(dword))) & !(zeroize_reg | kv_data_present_reset);
       hwif_in.HMAC512_BLOCK[dword].BLOCK.next  = kv_block_write_data;
-      hwif_in.HMAC512_BLOCK[dword].BLOCK.hwclr = zeroize_reg | kv_data_present_reset | (kv_block_error != KV_SUCCESS);
-      hwif_in.HMAC512_BLOCK[dword].BLOCK.swwel = block_reg_lock[dword];
+      hwif_in.HMAC512_BLOCK[dword].BLOCK.hwclr = zeroize_reg | kv_data_present_reset | kv_block_preclear | (kv_block_error != KV_SUCCESS);
+      hwif_in.HMAC512_BLOCK[dword].BLOCK.swwel = zeroize_reg | busy_o | kv_block_read_ctrl_reg.read_en | kv_block_data_present | block_reg_lock[dword];
     end
     for (int dword = 0; dword < KEY_NUM_DWORDS; dword++) begin
-      hwif_in.HMAC512_KEY[dword].KEY.we    = (kv_key_write_en & (kv_key_write_offset == dword)) & !(zeroize_reg | kv_data_present_reset);
+      hwif_in.HMAC512_KEY[dword].KEY.we    = (kv_key_write_en & (kv_key_write_offset == 4'(dword))) & !(zeroize_reg | kv_data_present_reset);
       hwif_in.HMAC512_KEY[dword].KEY.next  = kv_key_write_data;
-      hwif_in.HMAC512_KEY[dword].KEY.hwclr = zeroize_reg | kv_data_present_reset | (kv_key_error != KV_SUCCESS);
-      hwif_in.HMAC512_KEY[dword].KEY.swwel = kv_key_data_present;
-    end
-
-    hwif_in.HMAC512_KV_RD_KEY_STATUS.READY.next   = kv_key_ready;
-    hwif_in.HMAC512_KV_RD_BLOCK_STATUS.READY.next = kv_block_ready;
-    hwif_in.HMAC512_KV_WR_STATUS.READY.next       = kv_write_ready;
+      hwif_in.HMAC512_KEY[dword].KEY.hwclr = zeroize_reg | kv_data_present_reset | kv_key_preclear | (kv_key_error != KV_SUCCESS);
+      hwif_in.HMAC512_KEY[dword].KEY.swwel = zeroize_reg | busy_o | kv_key_read_ctrl_reg.read_en | kv_key_data_present;
+    end
+
+    hwif_in.HMAC512_KV_RD_KEY_STATUS.READY.next   = kv_key_ready & ~kv_key_read_ctrl_reg.read_en;
+    hwif_in.HMAC512_KV_RD_BLOCK_STATUS.READY.next = kv_block_ready & ~kv_block_read_ctrl_reg.read_en;
+    hwif_in.HMAC512_KV_WR_STATUS.READY.next       = kv_write_ready & ~(core_tag_we & dest_keyvault);
 
     hwif_in.HMAC512_KV_RD_KEY_STATUS.ERROR.next   = kv_key_error;
     hwif_in.HMAC512_KV_RD_BLOCK_STATUS.ERROR.next = kv_block_error;
     hwif_in.HMAC512_KV_WR_STATUS.ERROR.next       = kv_write_error;
 
-    hwif_in.HMAC512_KV_RD_KEY_STATUS.VALID.hwset   = kv_key_done;
-    hwif_in.HMAC512_KV_RD_BLOCK_STATUS.VALID.hwset = kv_block_done;
-    hwif_in.HMAC512_KV_WR_STATUS.VALID.hwset       = kv_write_done;
-
-    hwif_in.HMAC512_KV_RD_KEY_STATUS.VALID.hwclr   = kv_key_read_ctrl_reg.read_en;
-    hwif_in.HMAC512_KV_RD_BLOCK_STATUS.VALID.hwclr = kv_block_read_ctrl_reg.read_en;
+    hwif_in.HMAC512_KV_RD_KEY_STATUS.VALID.hwset   = kv_key_done & ~zeroize_reg;
+    hwif_in.HMAC512_KV_RD_BLOCK_STATUS.VALID.hwset = kv_block_done & ~zeroize_reg;
+    hwif_in.HMAC512_KV_WR_STATUS.VALID.hwset       = kv_write_done & ~zeroize_reg;
+
+    hwif_in.HMAC512_KV_RD_KEY_STATUS.VALID.hwclr   = kv_key_read_ctrl_reg.read_en | zeroize_reg;
+    hwif_in.HMAC512_KV_RD_BLOCK_STATUS.VALID.hwclr = kv_block_read_ctrl_reg.read_en | zeroize_reg;
     hwif_in.HMAC512_KV_WR_STATUS.VALID.hwclr       = kv_write_ctrl_reg.write_en | zeroize_reg;
 
-    hwif_in.HMAC512_KV_RD_KEY_CTRL.read_en.hwclr   = ~kv_key_ready;
-    hwif_in.HMAC512_KV_RD_BLOCK_CTRL.read_en.hwclr = ~kv_block_ready;
-    hwif_in.HMAC512_KV_WR_CTRL.write_en.hwclr      = ~kv_write_ready;
+    hwif_in.HMAC512_KV_RD_KEY_CTRL.read_en.hwclr   = ~kv_key_ready | zeroize_reg;
+    hwif_in.HMAC512_KV_RD_BLOCK_CTRL.read_en.hwclr = ~kv_block_ready | zeroize_reg;
+    hwif_in.HMAC512_KV_WR_CTRL.write_en.hwclr      = ~kv_write_ready | zeroize_reg;
 
     for (int dword = 0; dword < KEY_NUM_DWORDS; dword++) begin
-      key_reg[dword] = hwif_out.HMAC512_CTRL.CSR_MODE.value ? cptra_csr_hmac_key[dword] : hwif_out.HMAC512_KEY[dword].KEY.value;
+      key_reg[dword] = zeroize_reg ? '0 :
+                       (use_csr_key_mode ? cptra_csr_hmac_key[dword] : hwif_out.HMAC512_KEY[dword].KEY.value);
     end
     for (int dword = 0; dword < BLOCK_NUM_DWORDS; dword++) begin
-      block_reg[dword] = hwif_out.HMAC512_BLOCK[dword].BLOCK.value;
+      block_reg[dword] = zeroize_reg ? '0 : hwif_out.HMAC512_BLOCK[dword].BLOCK.value;
     end
     for (int dword = 0; dword < SEED_NUM_DWORDS; dword++) begin
-      lfsr_seed_reg[dword] = hwif_out.HMAC512_LFSR_SEED[dword].LFSR_SEED.value;
+      lfsr_seed_reg[dword] = zeroize_reg ? '0 : lfsr_seed_shadow_q[dword];
     end
   end
 
@@ -311,36 +388,39 @@
 
   always_comb begin
     for (int dword = 0; dword < BLOCK_NUM_DWORDS; dword++) begin
-      if (init_reg | next_reg) begin
-        block_reg_lock_nxt[dword] = '0;
+      if (kv_data_present_reset || (kv_block_error != KV_SUCCESS)) begin
+        block_reg_lock_nxt[dword] = 1'b0;
+      end
+      else if (kv_block_write_en && (kv_block_write_offset == 5'(dword))) begin
+        block_reg_lock_nxt[dword] = 1'b1;
       end
       else begin
-        block_reg_lock_nxt[dword] = (kv_block_write_en & (kv_block_write_offset == dword)) ? '1 : block_reg_lock[dword];
-      end
-    end
-  end
-
-  always_comb hwif_in.HMAC512_KV_RD_KEY_CTRL.read_en.swwe         = !kv_key_data_present && !busy_o;
-  always_comb hwif_in.HMAC512_KV_RD_KEY_CTRL.read_entry.swwe      = !kv_key_data_present && !busy_o;
+        block_reg_lock_nxt[dword] = block_reg_lock[dword];
+      end
+    end
+  end
+
+  always_comb hwif_in.HMAC512_KV_RD_KEY_CTRL.read_en.swwe         = !kv_key_data_present && !busy_o && !zeroize_reg;
+  always_comb hwif_in.HMAC512_KV_RD_KEY_CTRL.read_entry.swwe      = !kv_key_data_present && !busy_o && !zeroize_reg;
   always_comb hwif_in.HMAC512_KV_RD_KEY_CTRL.pcr_hash_extend.swwe = 0;
   always_comb hwif_in.HMAC512_KV_RD_KEY_CTRL.rsvd.swwe            = 0;
 
-  always_comb hwif_in.HMAC512_KV_RD_BLOCK_CTRL.read_en.swwe         = !kv_block_data_present && !busy_o;
-  always_comb hwif_in.HMAC512_KV_RD_BLOCK_CTRL.read_entry.swwe      = !kv_block_data_present && !busy_o;
+  always_comb hwif_in.HMAC512_KV_RD_BLOCK_CTRL.read_en.swwe         = !kv_block_data_present && !busy_o && !zeroize_reg;
+  always_comb hwif_in.HMAC512_KV_RD_BLOCK_CTRL.read_entry.swwe      = !kv_block_data_present && !busy_o && !zeroize_reg;
   always_comb hwif_in.HMAC512_KV_RD_BLOCK_CTRL.pcr_hash_extend.swwe = 0;
   always_comb hwif_in.HMAC512_KV_RD_BLOCK_CTRL.rsvd.swwe            = 0;
 
-  always_comb hwif_in.HMAC512_KV_WR_CTRL.write_en.swwe              = !busy_o;
-  always_comb hwif_in.HMAC512_KV_WR_CTRL.write_entry.swwe           = !busy_o;
-  always_comb hwif_in.HMAC512_KV_WR_CTRL.hmac_key_dest_valid.swwe   = !busy_o;
-  always_comb hwif_in.HMAC512_KV_WR_CTRL.hmac_block_dest_valid.swwe = !busy_o;
-  always_comb hwif_in.HMAC512_KV_WR_CTRL.mldsa_seed_dest_valid.swwe = !busy_o;
-  always_comb hwif_in.HMAC512_KV_WR_CTRL.ecc_pkey_dest_valid.swwe   = !busy_o;
-  always_comb hwif_in.HMAC512_KV_WR_CTRL.ecc_seed_dest_valid.swwe   = !busy_o;
-  always_comb hwif_in.HMAC512_KV_WR_CTRL.aes_key_dest_valid.swwe    = !busy_o;
-  always_comb hwif_in.HMAC512_KV_WR_CTRL.mlkem_seed_dest_valid.swwe = !busy_o;
-  always_comb hwif_in.HMAC512_KV_WR_CTRL.mlkem_msg_dest_valid.swwe  = !busy_o;
-  always_comb hwif_in.HMAC512_KV_WR_CTRL.dma_data_dest_valid.swwe   = !busy_o;
+  always_comb hwif_in.HMAC512_KV_WR_CTRL.write_en.swwe              = !busy_o && !zeroize_reg;
+  always_comb hwif_in.HMAC512_KV_WR_CTRL.write_entry.swwe           = !busy_o && !zeroize_reg;
+  always_comb hwif_in.HMAC512_KV_WR_CTRL.hmac_key_dest_valid.swwe   = !busy_o && !zeroize_reg;
+  always_comb hwif_in.HMAC512_KV_WR_CTRL.hmac_block_dest_valid.swwe = !busy_o && !zeroize_reg;
+  always_comb hwif_in.HMAC512_KV_WR_CTRL.mldsa_seed_dest_valid.swwe = !busy_o && !zeroize_reg;
+  always_comb hwif_in.HMAC512_KV_WR_CTRL.ecc_pkey_dest_valid.swwe   = !busy_o && !zeroize_reg;
+  always_comb hwif_in.HMAC512_KV_WR_CTRL.ecc_seed_dest_valid.swwe   = !busy_o && !zeroize_reg;
+  always_comb hwif_in.HMAC512_KV_WR_CTRL.aes_key_dest_valid.swwe    = !busy_o && !zeroize_reg;
+  always_comb hwif_in.HMAC512_KV_WR_CTRL.mlkem_seed_dest_valid.swwe = !busy_o && !zeroize_reg;
+  always_comb hwif_in.HMAC512_KV_WR_CTRL.mlkem_msg_dest_valid.swwe  = !busy_o && !zeroize_reg;
+  always_comb hwif_in.HMAC512_KV_WR_CTRL.dma_data_dest_valid.swwe   = !busy_o && !zeroize_reg;
   always_comb hwif_in.HMAC512_KV_WR_CTRL.rsvd.swwe                  = 0;
 
   `CALIPTRA_KV_READ_CTRL_REG2STRUCT(kv_key_read_ctrl_reg, HMAC512_KV_RD_KEY_CTRL)
@@ -373,8 +453,8 @@
       .hwif_out(hwif_out)
   );
 
-  always_comb key_mode_error   = kv_key_data_present & (init_reg | next_reg) & (mode_reg == HMAC512_MODE) & (key_reg[KEY_NUM_DWORDS-1 : HMAC384_KEY_SIZE/DATA_WIDTH] == '0);
-  always_comb key_zero_error   = kv_key_data_present & (init_reg | next_reg) & (key_reg == '0);
+  always_comb key_mode_error   = kv_key_data_present & ctrl_cmd_pulse & (mode_reg == HMAC512_MODE) & (key_reg[KEY_NUM_DWORDS-1 : HMAC384_KEY_SIZE/DATA_WIDTH] == '0);
+  always_comb key_zero_error   = kv_key_data_present & ctrl_cmd_pulse & (key_reg == '0);
   always_comb last_alone_error = hwif_out.HMAC512_CTRL.LAST.value & ~hwif_out.HMAC512_CTRL.INIT.value & ~hwif_out.HMAC512_CTRL.NEXT.value;
 
   always_comb error_flag = key_zero_error | key_mode_error | (kv_key_error == KV_RD_LEN_MISMATCH);
@@ -446,7 +526,7 @@
       .error_code(kv_key_error),
       .kv_ready(kv_key_ready),
       .read_done(kv_key_done),
-      .check_key_size((init_reg | next_reg) & kv_key_data_present),
+      .check_key_size(ctrl_cmd_pulse & kv_key_data_present),
       .expected_key_size(hmac_expected_key_size)
   );
 
@@ -527,6 +607,4 @@
     .dest_done(kv_write_done)
   );
 
-  always_comb busy_o = ~kv_write_ready | ~kv_block_ready | ~kv_key_ready | ~core_ready;
-
 endmodule

--- a/environment/public/code/hmac_ctrl.sv (Buggy Starter)
+++ b/solution/gold/code/hmac_ctrl.sv (Golden Reference)
@@ -66,11 +66,55 @@
     input  logic debugUnlock_or_scan_mode_switch
 );
 
-    logic           hmac_cs;
-    logic           hmac_we;
-    logic  [AHB_ADDR_WIDTH-1 : 0] hmac_address;
-    logic  [31 : 0] hmac_write_data;
-    logic  [31 : 0] hmac_read_data;
+    localparam logic [2:0] AHB_SIZE_WORD = 3'b010;
+
+    logic                         raw_hmac_cs;
+    logic                         raw_hmac_we;
+    logic                         hmac_cs;
+    logic                         hmac_we;
+    logic [AHB_ADDR_WIDTH-1 : 0]  hmac_address;
+    logic [31 : 0]                hmac_write_data;
+    logic [31 : 0]                hmac_read_data;
+    logic [31 : 0]                sif_rdata;
+
+    logic                         ahb_active_transfer;
+    logic                         ahb_malformed_addr_phase;
+    logic                         ahb_malformed_q;
+    logic                         ahb_err;
+    logic                         debug_or_scan_lock_q;
+    logic                         bus_isolate;
+
+    logic [`CLP_CSR_HMAC_KEY_DWORDS-1:0][31:0] csr_hmac_key_masked;
+
+    always_comb begin
+        ahb_active_transfer      = hsel_i && hready_i && (htrans_i inside {2'b10, 2'b11});
+        ahb_malformed_addr_phase = ahb_active_transfer &&
+                                   ((hsize_i != AHB_SIZE_WORD) || (haddr_i[1:0] != 2'b00));
+    end
+
+    always_ff @(posedge clk or negedge reset_n) begin
+        if (!reset_n) begin
+            ahb_malformed_q      <= 1'b0;
+            debug_or_scan_lock_q <= 1'b0;
+        end
+        else if (hready_i) begin
+            ahb_malformed_q      <= ahb_malformed_addr_phase;
+            debug_or_scan_lock_q <= ahb_active_transfer && debugUnlock_or_scan_mode_switch;
+        end
+        else if (raw_hmac_cs) begin
+            ahb_malformed_q      <= 1'b0;
+            debug_or_scan_lock_q <= 1'b0;
+        end
+    end
+
+    always_comb begin
+        ahb_err             = raw_hmac_cs && ahb_malformed_q;
+        bus_isolate         = ahb_malformed_q || debugUnlock_or_scan_mode_switch || debug_or_scan_lock_q;
+        hmac_cs             = raw_hmac_cs && !bus_isolate;
+        hmac_we             = raw_hmac_we && !bus_isolate;
+        sif_rdata           = bus_isolate ? 32'h0 : hmac_read_data;
+        csr_hmac_key_masked = debugUnlock_or_scan_mode_switch ? '0 : cptra_csr_hmac_key;
+    end
 
     hmac #(
         .ADDR_WIDTH (AHB_ADDR_WIDTH),
@@ -79,7 +123,7 @@
         .clk(clk),
         .reset_n(reset_n),
         .cptra_pwrgood(cptra_pwrgood),
-        .cptra_csr_hmac_key(cptra_csr_hmac_key),
+        .cptra_csr_hmac_key(csr_hmac_key_masked),
         .cs(hmac_cs),
         .we(hmac_we),
         .address(hmac_address),
@@ -115,13 +159,13 @@
         .hreadyout_o(hreadyout_o),
         .hrdata_o(hrdata_o),
 
-        .dv(hmac_cs),
+        .dv(raw_hmac_cs),
         .hld(1'b0),
-        .err(1'b0),
-        .write(hmac_we),
+        .err(ahb_err),
+        .write(raw_hmac_we),
         .wdata(hmac_write_data),
         .addr(hmac_address),
-        .rdata(hmac_read_data)
+        .rdata(sif_rdata)
     );
 
 endmodule

--- a/environment/public/code/hmac_drbg.sv (Buggy Starter)
+++ b/solution/gold/code/hmac_drbg.sv (Golden Reference)
@@ -77,36 +77,77 @@
   //----------------------------------------------------------------
   // Registers including update variables and write enable.
   //----------------------------------------------------------------
-  reg [4:0]             drbg_st_reg;
-  reg [4:0]             drbg_next_st;
-  reg [4:0]             drbg_st_reg_last;
-
-  reg                   ready_reg;
-  reg                   valid_reg;
-  reg [REG_SIZE-1 : 0]  drbg_reg;
-  reg                   first_round;
-  reg                   HMAC_tag_valid_last;
-  reg                   HMAC_tag_valid_edge;
-
-  reg [REG_SIZE-1:0]    K_reg;
-  reg [REG_SIZE-1:0]    V_reg;
+  reg [4:0]               drbg_st_reg;
+  reg [4:0]               drbg_next_st;
+  reg [4:0]               drbg_st_reg_last;
+
+  reg                     ready_reg;
+  reg                     valid_reg;
+  reg [REG_SIZE-1 : 0]    drbg_reg;
+  reg                     first_round;
+  reg                     HMAC_tag_valid_last;
+  reg                     HMAC_tag_valid_edge;
+
+  reg [REG_SIZE-1:0]      K_reg;
+  reg [REG_SIZE-1:0]      V_reg;
+  reg [REG_SIZE-1:0]      entropy_reg;
+  reg [REG_SIZE-1:0]      nonce_reg;
+  reg [LFSR_LENGTH-1:0]   lfsr_seed_reg;
+  reg                     instantiated_reg;
+
+  logic                   accept_init_cmd;
+  logic                   accept_next_cmd;
 
   //----------------------------------------------------------------
   // Register/Wires for HMAC-384 module instantiation.
   //----------------------------------------------------------------
-  reg                   HMAC_init;
-  reg                   HMAC_next;
-  reg                   HMAC_last;
-  reg  [1023:0]         HMAC_block;
-  reg  [REG_SIZE-1:0]   HMAC_key;
-  logic [511:0]         HMAC512_key;
-
-  wire                  HMAC_ready;
-  wire                  HMAC_tag_valid;
-  logic [REG_SIZE-1:0]  HMAC_tag;
-  logic [511:0]         HMAC512_tag;
-
-  logic                 failure_check;
+  reg                     HMAC_init;
+  reg                     HMAC_next;
+  reg                     HMAC_last;
+  reg  [1023:0]           HMAC_block;
+  reg  [REG_SIZE-1:0]     HMAC_key;
+  logic [511:0]           HMAC512_key;
+
+  wire                    HMAC_ready;
+  wire                    HMAC_tag_valid;
+  logic [REG_SIZE-1:0]    HMAC_tag;
+  logic [511:0]           HMAC512_tag;
+
+  logic                   failure_check;
+
+  //----------------------------------------------------------------
+  // Command qualification
+  //----------------------------------------------------------------
+  always_comb begin
+    accept_init_cmd = (drbg_st_reg == IDLE_ST) && HMAC_ready && !zeroize && (init_cmd && !next_cmd);
+    accept_next_cmd = (drbg_st_reg == IDLE_ST) && HMAC_ready && !zeroize && (!init_cmd && next_cmd) && instantiated_reg;
+  end
+
+  always_ff @(posedge clk or negedge reset_n) begin : seed_snapshot_update
+    if (!reset_n) begin
+      entropy_reg      <= '0;
+      nonce_reg        <= '0;
+      lfsr_seed_reg    <= '0;
+      instantiated_reg <= 1'b0;
+    end
+    else if (zeroize) begin
+      entropy_reg      <= '0;
+      nonce_reg        <= '0;
+      lfsr_seed_reg    <= '0;
+      instantiated_reg <= 1'b0;
+    end
+    else begin
+      if (accept_init_cmd) begin
+        entropy_reg      <= entropy;
+        nonce_reg        <= nonce;
+        lfsr_seed_reg    <= lfsr_seed;
+        instantiated_reg <= 1'b1;
+      end
+      else if (accept_next_cmd) begin
+        lfsr_seed_reg    <= lfsr_seed;
+      end
+    end
+  end
 
   //----------------------------------------------------------------
   // HMAC module instantiation.
@@ -119,7 +160,7 @@
     .next_cmd(HMAC_next),
     .last_cmd(HMAC_last),
     .mode_cmd(1'b0),
-    .lfsr_seed(lfsr_seed),
+    .lfsr_seed(zeroize ? '0 : lfsr_seed_reg),
     .key(HMAC512_key),
     .block_msg(HMAC_block),
     .ready(HMAC_ready),
@@ -163,12 +204,13 @@
     else begin
       unique case (drbg_st_reg)
         IDLE_ST: begin
-          if (init_cmd | next_cmd) begin
+          if (accept_init_cmd || accept_next_cmd) begin
             ready_reg <= 1'b0;
             valid_reg <= 1'b0;
+            drbg_reg  <= '0;
           end
           else begin
-            ready_reg <= 1'b1;
+            ready_reg <= HMAC_ready;
           end
         end
 
@@ -244,10 +286,7 @@
           V2_ST:   K_reg <= HMAC_tag;
           T_ST:    V_reg <= HMAC_tag;
           V3_ST:   K_reg <= HMAC_tag;
-          CHCK_ST: begin
-            if (!failure_check)
-            
```

</details>

---

## 5. Harbor Package File Inventory & Provenance

### Public Workspace (`environment/public/`)
- [`environment/public/BUILD.md`](environment/public/BUILD.md) *(Read-Only Context)*
- [`environment/public/code/LICENSE`](environment/public/code/LICENSE) *(Read-Only Context)*
- [`environment/public/code/ahb_defines_pkg.sv`](environment/public/code/ahb_defines_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/ahb_slv_sif.sv`](environment/public/code/ahb_slv_sif.sv) *(Read-Only Context)*
- [`environment/public/code/caliptra_macros.svh`](environment/public/code/caliptra_macros.svh) *(Read-Only Context)*
- [`environment/public/code/caliptra_prim_assert.sv`](environment/public/code/caliptra_prim_assert.sv) *(Read-Only Context)*
- [`environment/public/code/caliptra_prim_assert_dummy_macros.svh`](environment/public/code/caliptra_prim_assert_dummy_macros.svh) *(Read-Only Context)*
- [`environment/public/code/caliptra_prim_assert_sec_cm.svh`](environment/public/code/caliptra_prim_assert_sec_cm.svh) *(Read-Only Context)*
- [`environment/public/code/caliptra_prim_assert_standard_macros.svh`](environment/public/code/caliptra_prim_assert_standard_macros.svh) *(Read-Only Context)*
- [`environment/public/code/caliptra_prim_assert_yosys_macros.svh`](environment/public/code/caliptra_prim_assert_yosys_macros.svh) *(Read-Only Context)*
- [`environment/public/code/caliptra_prim_cipher_pkg.sv`](environment/public/code/caliptra_prim_cipher_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/caliptra_prim_flop.sv`](environment/public/code/caliptra_prim_flop.sv) *(Read-Only Context)*
- [`environment/public/code/caliptra_prim_flop_macros.sv`](environment/public/code/caliptra_prim_flop_macros.sv) *(Read-Only Context)*
- [`environment/public/code/caliptra_prim_generic_flop.sv`](environment/public/code/caliptra_prim_generic_flop.sv) *(Read-Only Context)*
- [`environment/public/code/caliptra_prim_lfsr.sv`](environment/public/code/caliptra_prim_lfsr.sv) *(Read-Only Context)*
- [`environment/public/code/caliptra_prim_module_name_macros.svh`](environment/public/code/caliptra_prim_module_name_macros.svh) *(Read-Only Context)*
- [`environment/public/code/caliptra_prim_mubi_pkg.sv`](environment/public/code/caliptra_prim_mubi_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/caliptra_prim_pkg.sv`](environment/public/code/caliptra_prim_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/caliptra_prim_sparse_fsm_flop.sv`](environment/public/code/caliptra_prim_sparse_fsm_flop.sv) *(Read-Only Context)*
- [`environment/public/code/caliptra_prim_util_pkg.sv`](environment/public/code/caliptra_prim_util_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/caliptra_sva.svh`](environment/public/code/caliptra_sva.svh) *(Read-Only Context)*
- [`environment/public/code/hmac.sv`](environment/public/code/hmac.sv) **(Editable)**
- [`environment/public/code/hmac_core.sv`](environment/public/code/hmac_core.sv) *(Read-Only Context)*
- [`environment/public/code/hmac_ctrl.sv`](environment/public/code/hmac_ctrl.sv) **(Editable)**
- [`environment/public/code/hmac_drbg.sv`](environment/public/code/hmac_drbg.sv) **(Editable)**
- [`environment/public/code/hmac_param_pkg.sv`](environment/public/code/hmac_param_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/hmac_reg.sv`](environment/public/code/hmac_reg.sv) *(Read-Only Context)*
- [`environment/public/code/hmac_reg_pkg.sv`](environment/public/code/hmac_reg_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/kv_defines_pkg.sv`](environment/public/code/kv_defines_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/kv_fsm.sv`](environment/public/code/kv_fsm.sv) *(Read-Only Context)*
- [`environment/public/code/kv_macros.svh`](environment/public/code/kv_macros.svh) *(Read-Only Context)*
- [`environment/public/code/kv_read_client.sv`](environment/public/code/kv_read_client.sv) *(Read-Only Context)*
- [`environment/public/code/kv_read_rule_check.sv`](environment/public/code/kv_read_rule_check.sv) *(Read-Only Context)*
- [`environment/public/code/kv_write_client.sv`](environment/public/code/kv_write_client.sv) *(Read-Only Context)*
- [`environment/public/code/kv_write_rule_check.sv`](environment/public/code/kv_write_rule_check.sv) *(Read-Only Context)*
- [`environment/public/code/sha512_h_constants.v`](environment/public/code/sha512_h_constants.v) *(Read-Only Context)*
- [`environment/public/code/sha512_k_constants.v`](environment/public/code/sha512_k_constants.v) *(Read-Only Context)*
- [`environment/public/code/sha512_masked_core.sv`](environment/public/code/sha512_masked_core.sv) *(Read-Only Context)*
- [`environment/public/code/sha512_masked_defines_pkg.sv`](environment/public/code/sha512_masked_defines_pkg.sv) *(Read-Only Context)*
- [`environment/public/code/sha512_masked_w_mem.sv`](environment/public/code/sha512_masked_w_mem.sv) *(Read-Only Context)*
- [`environment/public/issue.md`](environment/public/issue.md) *(Read-Only Context)*

### Reference Solutions & Isolated Verifier (`solution/` & `tests/`)
- [`solution/solve.sh`](solution/solve.sh) — Harbor oracle script
- [`solution/gold/`](solution/gold/) — Primary golden reference solution
- [`solution/alternate_gold/`](solution/alternate_gold/) — Structurally distinct secondary reference solution
- [`tests/test.sh`](tests/test.sh) — Isolated Harbor verifier entrypoint
- [`tests/private/policy_filter.py`](tests/private/policy_filter.py) — Pre-grader airlock & anti-cheat policy screen
- [`tests/private/grader/run.py`](tests/private/grader/run.py) — Deterministic front-to-back EDA verifier

### Upstream Provenance (`SOURCE.md`)

