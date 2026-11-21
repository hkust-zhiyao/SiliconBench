# Build and Interface Notes

## Source Layout

- **Editable RTL files**:
  - `code/sha512_masked_defines_pkg.sv` — package `sha512_masked_defines_pkg` (`masked_reg_t` and masked boolean/arithmetic conversion helpers)
  - `code/sha512_masked_w_mem.sv` — module `sha512_masked_w_mem` (16-word masked message-schedule storage and expansion)
  - `code/sha512_masked_core.sv` — module `sha512_masked_core` (top-level masked SHA-512 family compression core)
- **Read-only RTL & license files** (do not modify):
  - `code/sha512_h_constants.v` — module `sha512_h_constants`
  - `code/sha512_k_constants.v` — module `sha512_k_constants`
  - `code/LICENSE`

## Preserved Top-Level & Observable Architecture Contracts

1. Preserve the `sha512_masked_core` module name and exact top-level port list/widths:
   - Inputs: `clk`, `reset_n`, `zeroize`, `init_cmd`, `next_cmd`, `mode[1:0]`, `entropy[191:0]`, `block_msg[1023:0]`
   - Outputs: `ready`, `digest[511:0]`, `digest_valid`
2. Preserve `masked_reg_t` (`typedef struct packed { reg [63:0] masked; reg [63:0] random; }`) in `sha512_masked_defines_pkg`. Additional helper functions may be added to `sha512_masked_defines_pkg`, and internal submodule ports between `sha512_masked_core` and `sha512_masked_w_mem` may be extended as needed.
3. Preserve the following observable two-share registers (`masked_reg_t`, where `masked ^ random` equals the architectural 64-bit word):
   - Working state registers `a_reg`, `b_reg`, `c_reg`, `d_reg`, `e_reg`, `f_reg`, `g_reg`, `h_reg` in `sha512_masked_core`
   - Message-schedule instance `w_mem_inst` (`sha512_masked_w_mem`) containing `masked_reg_t w_mem [0 : 15]` in `sha512_masked_core`

## Synthesis & Simulation Checks

All RTL must be cleanly synthesizable SystemVerilog/Verilog without inferred latches, combinational loops, or simulator-only constructs:

```bash
# Synthesis, zero-latch, and zero-combinational-loop check
yosys -m slang -p "read_slang -DSYNTHESIS --top sha512_masked_core -Icode \
  code/sha512_masked_defines_pkg.sv code/sha512_h_constants.v code/sha512_k_constants.v \
  code/sha512_masked_w_mem.sv code/sha512_masked_core.sv; \
  proc; opt; check -assert; scc -expect 0"

# Verilator elaboration check
verilator --lint-only -Wno-fatal -DSYNTHESIS -Icode --top-module sha512_masked_core \
  code/sha512_masked_defines_pkg.sv code/sha512_h_constants.v code/sha512_k_constants.v \
  code/sha512_masked_w_mem.sv code/sha512_masked_core.sv
```
