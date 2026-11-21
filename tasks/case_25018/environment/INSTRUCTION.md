# case_25018: Caliptra RoT 8-Macro SECDED Staging Memory, AXI4 Access Lock & SHA-512 Direct-Read PnR

> **SiliconBench Standardized Harbor Task**
> - **Repository**: `chipsalliance/caliptra-rtl` (`repo_50`)
> - **Engineering Problem Type**: `RTL + Hard-SRAM Macro Physical Co-Design` (`PT5_RTL_HardSRAM_Macro_PnR`)
> - **EDA Evaluation Stage**: `Stage 4: Hard-SRAM Floorplanning, CTS & Routing (PnR)` (`stage4_macro_pnr`)
> - **PDK / Environment Profile**: `IHP SG13G2 130nm Open PDK + RM_IHPSG13_1P Hard-SRAM Macros`
> - **Editable Files (`allowed_edits`)**: `code/sha512_acc_top.sv`, `code/axi_sub_rd.sv`, `code/axi_sub_wr.sv`, `code/rot_sram_ecc_ctrl.sv`, `plan/macro_placement.json`, `constraints/rot_staging_subsys.sdc`

---

## Problem Specification

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

## Build, Simulation, and EDA Verification Instructions

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

## Submission Contract (`allowed_edits`)

You must modify **only** the following allowlisted file(s) in your workspace:
- `code/sha512_acc_top.sv`
- `code/axi_sub_rd.sv`
- `code/axi_sub_wr.sv`
- `code/rot_sram_ecc_ctrl.sv`
- `plan/macro_placement.json`
- `constraints/rot_staging_subsys.sdc`

All other files in the workspace are read-only reference context and must remain unmodified.
