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
