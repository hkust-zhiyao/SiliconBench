# Build, Synthesis, & Gate-Level Fault-Injection Guide

## Workspace Layout

- `code/doe_ctrl.sv` *(editable)* — Top-level AHB-Lite DOE controller wrapping `ahb_slv_sif` and `doe_cbc`.
- `code/doe_fsm.sv` *(editable)* — Sparse-encoded DOE command/KeyVault sequencer and flow-lock controller.
- `code/doe_key_mem.sv` *(editable)* — AES-256 round-key expansion engine and 15-round key storage.
- `code/*.sv`, `code/*.svh` *(read-only)* — Caliptra DOE AES-256-CBC datapath (`doe_cbc.sv`, `doe_core_cbc.sv`, `doe_encipher_block.sv`, `doe_decipher_block.sv`, `doe_sbox.sv`, `doe_inv_sbox.sv`), PeakRDL register block (`doe_reg_pkg.sv`, `doe_reg.sv`), KeyVault rule checker (`kv_defines_pkg.sv`, `kv_write_rule_check.sv`), AHB interface (`ahb_defines_pkg.sv`, `ahb_slv_sif.sv`), and `caliptra_prim` primitives.
- `pdk/NangateOpenCellLibrary_typical.lib` *(read-only)* — Nangate 45nm standard-cell Liberty library used for gate-level synthesis and post-synthesis single-bit state-flip fault-injection verification.

Do not modify read-only files or create symlinks anywhere in the workspace.

---

## 1. RTL Compilation Order (Verilator 5.038)

Compile the subsystem packages and modules in dependency order with `-Icode`:

```bash
verilator --binary --timing -Wno-fatal -sv -Icode -CFLAGS -O0 \
  code/config_defines.svh \
  code/caliptra_prim_pkg.sv \
  code/caliptra_prim_mubi_pkg.sv \
  code/ahb_defines_pkg.sv \
  code/kv_defines_pkg.sv \
  code/doe_defines_pkg.sv \
  code/doe_reg_pkg.sv \
  code/caliptra_prim_generic_flop.sv \
  code/caliptra_prim_flop.sv \
  code/caliptra_prim_sparse_fsm_flop.sv \
  code/ahb_slv_sif.sv \
  code/kv_write_rule_check.sv \
  code/doe_sbox.sv \
  code/doe_inv_sbox.sv \
  code/doe_encipher_block.sv \
  code/doe_decipher_block.sv \
  code/doe_key_mem.sv \
  code/doe_core_cbc.sv \
  code/doe_reg.sv \
  code/doe_fsm.sv \
  code/doe_cbc.sv \
  code/doe_ctrl.sv \
  /tmp/my_doe_driver.sv --top-module my_doe_driver -Mdir /tmp/obj_doe
```

---

## 2. Cross-Stage Nangate45 Gate-Level Synthesis (`yosys -m slang`)

Sign-off synthesizes the complete `doe_ctrl` hierarchy to Nangate45 standard cells (`DFF_X*`, `DFFR_X*`, `DFFS_X*`, `DFFRS_X*`, and combinational gates) and checks zero inferred latches, zero combinational loops (`scc -expect 0`), and preservation of all `>= 10` sparse state flip-flops (`kv_doe_fsm_ps`) in `doe_fsm`:

```bash
yosys -m slang -p "
  read_slang -DSYNTHESIS -Icode \
    code/config_defines.svh \
    code/caliptra_prim_pkg.sv \
    code/caliptra_prim_mubi_pkg.sv \
    code/ahb_defines_pkg.sv \
    code/kv_defines_pkg.sv \
    code/doe_defines_pkg.sv \
    code/doe_reg_pkg.sv \
    code/caliptra_prim_generic_flop.sv \
    code/caliptra_prim_flop.sv \
    code/caliptra_prim_sparse_fsm_flop.sv \
    code/ahb_slv_sif.sv \
    code/kv_write_rule_check.sv \
    code/doe_sbox.sv \
    code/doe_inv_sbox.sv \
    code/doe_encipher_block.sv \
    code/doe_decipher_block.sv \
    code/doe_key_mem.sv \
    code/doe_core_cbc.sv \
    code/doe_reg.sv \
    code/doe_fsm.sv \
    code/doe_cbc.sv \
    code/doe_ctrl.sv --top doe_ctrl;
  synth -top doe_ctrl;
  select -assert-none t:\$dlatch*;
  check -assert;
  scc -expect 0;
  dfflibmap -liberty pdk/NangateOpenCellLibrary_typical.lib;
  abc -liberty pdk/NangateOpenCellLibrary_typical.lib;
  opt_clean;
  write_json /tmp/doe_gate.json;
  write_verilog -noattr /tmp/doe_gate.v
"
```

---

## 3. Gate-Level Simulation & Single-Bit State-Flip Fault Injection (`iverilog`)

You can extract behavioral Verilog cell models directly from `pdk/NangateOpenCellLibrary_typical.lib` via Yosys (replacing `DFF*` sequential cells with single-register models where `Q = q_reg` and `QN = ~q_reg` so flipping `q_reg` coherently flips both `Q` and `QN`) and simulate `/tmp/doe_gate.v` using `iverilog -g2012`:

```bash
yosys -q -p "
  read_liberty -ignore_miss_func pdk/NangateOpenCellLibrary_typical.lib;
  proc;
  write_verilog -noattr /tmp/nangate45_cells.v
"
iverilog -g2012 -o /tmp/doe_gate_sim /tmp/nangate45_cells.v /tmp/doe_gate.v /tmp/my_gate_harness.sv
vvp /tmp/doe_gate_sim
```

Inspect `/tmp/doe_gate.json` to verify that all `>= 10` state `DFF*` cells driving `kv_doe_fsm_ps` survive `synth -top doe_ctrl` without FSM re-encoding or redundant-bit pruning, and verify that flipping any single state `DFF*` bit during an active unwrap immediately suppresses `kv_write`, asserts sticky `doe_fsm_error`, and zeroes `doe_key_mem` within 1 clock cycle.
