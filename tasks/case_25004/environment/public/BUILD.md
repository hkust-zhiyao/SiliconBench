# Caliptra P-384 ECDSA / ECDH Subsystem — Build & Lint Reference

## Editable RTL Modules
Only the following three files may be modified:
- `code/ecc_dsa_ctrl.sv`
- `code/ecc_scalar_blinding.sv`
- `code/ecc_hmac_drbg_interface.sv`

All other SystemVerilog packages, headers, register blocks, KeyVault clients, HMAC-DRBG cores, and P-384 arithmetic modules under `code/` are read-only reference dependencies and must remain unmodified.

## Verilator Compile / Lint Order
```bash
verilator --lint-only -Wno-fatal -DSYNTHESIS -Icode --top-module ecc_top \
  code/caliptra_prim_pkg.sv \
  code/caliptra_prim_util_pkg.sv \
  code/caliptra_prim_cipher_pkg.sv \
  code/caliptra_prim_generic_flop.sv \
  code/caliptra_prim_flop.sv \
  code/caliptra_prim_sparse_fsm_flop.sv \
  code/caliptra_prim_lfsr.sv \
  code/ahb_defines_pkg.sv \
  code/kv_defines_pkg.sv \
  code/kv_fsm.sv \
  code/kv_read_rule_check.sv \
  code/kv_write_rule_check.sv \
  code/kv_read_client.sv \
  code/kv_write_client.sv \
  code/ahb_slv_sif.sv \
  code/sha512_masked_defines_pkg.sv \
  code/sha512_h_constants.v \
  code/sha512_k_constants.v \
  code/sha512_masked_w_mem.sv \
  code/sha512_masked_core.sv \
  code/hmac_param_pkg.sv \
  code/hmac_core.sv \
  code/hmac_drbg.sv \
  code/ecc_params_pkg.sv \
  code/ecc_defines_pkg.sv \
  code/ecc_dsa_uop_pkg.sv \
  code/ecc_pm_uop_pkg.sv \
  code/ecc_reg_pkg.sv \
  code/ecc_reg.sv \
  code/ecc_adder.sv \
  code/ecc_add_sub_mod_alter.sv \
  code/ecc_mult_dsp.sv \
  code/ecc_pe_first.sv \
  code/ecc_pe.sv \
  code/ecc_pe_final.sv \
  code/ecc_montgomerymultiplier.sv \
  code/ecc_fau.sv \
  code/ecc_ram_tdp_file.sv \
  code/ecc_pm_sequencer.sv \
  code/ecc_pm_ctrl.sv \
  code/ecc_arith_unit.sv \
  code/ecc_scalar_blinding.sv \
  code/ecc_hmac_drbg_interface.sv \
  code/ecc_dsa_sequencer.sv \
  code/ecc_dsa_ctrl.sv \
  code/ecc_top.sv
```

## Synthesis & Combinational-Loop Sign-Off
All three editable modules must remain cleanly synthesizable under `yosys -m slang` (`proc; opt; check -assert; scc -expect 0`) with **zero inferred latches** and **zero combinational loops**, and must preserve their exact top-level port declarations and parameters.
