# Build & Verification Environment

## Editable RTL
- `code/rtl/axi_llc_miss_counters.sv`
- `code/rtl/axi_llc_tag_pattern_gen.sv`
- `code/rtl/axi_llc_hit_miss.sv`

## Read-Only Context & Dependencies
- `code/rtl/axi_llc_pkg.sv`, `code/rtl/axi_llc_tag_store.sv`, `code/rtl/axi_llc_evict_box.sv`, `code/rtl/axi_llc_lock_box_bloom.sv`, `code/rtl/tc_sram.sv`
- `code/common_cells/` and `code/axi/`

## Toolchain
- SystemVerilog Simulation: `verilator`
  ```bash
  verilator --binary --timing -Wno-fatal -j 1 \
    +incdir+code/common_cells/include +incdir+code/axi/include \
    code/common_cells/src/cb_filter_pkg.sv \
    code/common_cells/src/cf_math_pkg.sv \
    code/axi/src/axi_pkg.sv \
    code/rtl/axi_llc_pkg.sv \
    code/common_cells/src/delta_counter.sv \
    code/common_cells/src/counter.sv \
    code/common_cells/src/lzc.sv \
    code/common_cells/src/onehot_to_bin.sv \
    code/common_cells/src/fifo_v3.sv \
    code/common_cells/src/rr_arb_tree.sv \
    code/common_cells/src/shift_reg_gated.sv \
    code/common_cells/src/shift_reg.sv \
    code/common_cells/src/spill_register_flushable.sv \
    code/common_cells/src/spill_register.sv \
    code/common_cells/src/sub_per_hash.sv \
    code/common_cells/src/cb_filter.sv \
    code/rtl/tc_sram.sv \
    code/rtl/axi_llc_miss_counters.sv \
    code/rtl/axi_llc_tag_pattern_gen.sv \
    code/rtl/axi_llc_evict_box.sv \
    code/rtl/axi_llc_tag_store.sv \
    code/rtl/axi_llc_lock_box_bloom.sv \
    code/rtl/axi_llc_hit_miss.sv
  ```
- SystemVerilog Synthesis (`yosys+slang`): `yosys -m slang`
