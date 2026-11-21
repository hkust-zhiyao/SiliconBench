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
