# Build, Simulation, and Synthesis Guide

## Workspace Layout

- **Editable RTL files**:
  - `code/NV_NVDLA_PDP_nan.v`
  - `code/NV_NVDLA_PDP_CORE_unit1d.v`
  - `code/NV_NVDLA_PDP_CORE_cal1d.v`
- **Read-only NVDLA helper & HLS arithmetic files** (do **not** modify):
  - `code/HLS_fp16_to_fp17.v` (4-stage pipelined IEEE-754 FP16 -> internal FP17 converter)
  - `code/HLS_fp17_add.v` (4-stage pipelined internal FP17 adder)
  - `code/cal1d_fp16_pool_sum.v` (4-lane synchronized `HLS_fp17_add` wrapper used by `unit1d`)
  - `code/NV_CLK_gate_power.v`, `code/CKLNQD12.v`, `code/NV_BLKBOX_SINK.v`
  - `code/NV_HWACC_NVDLA_tick_defines.vh`, `code/simulate_x_tick.vh`, `code/LICENSE`

---

## Tool Commands

### 1. Fast Compile & Simulation with Icarus Verilog (`iverilog -g2012`)

```bash
iverilog -g2012 -DVERILINT -DSYNTHESIS -DDESIGNWARE_NOEXIST -Icode \
  -s <your_tb_top> -o /tmp/pdp_sim.vvp \
  code/NV_BLKBOX_SINK.v \
  code/CKLNQD12.v \
  code/NV_CLK_gate_power.v \
  code/HLS_fp16_to_fp17.v \
  code/HLS_fp17_add.v \
  code/cal1d_fp16_pool_sum.v \
  code/NV_NVDLA_PDP_nan.v \
  code/NV_NVDLA_PDP_CORE_unit1d.v \
  code/NV_NVDLA_PDP_CORE_cal1d.v \
  <your_tb.sv>

vvp /tmp/pdp_sim.vvp
```

### 2. Verilator Lint / Binary Simulation

```bash
verilator --lint-only -Wall -Wno-fatal \
  -DVERILINT -DSYNTHESIS -DDESIGNWARE_NOEXIST -Icode \
  --top-module NV_NVDLA_PDP_CORE_cal1d \
  code/NV_BLKBOX_SINK.v \
  code/CKLNQD12.v \
  code/NV_CLK_gate_power.v \
  code/HLS_fp16_to_fp17.v \
  code/HLS_fp17_add.v \
  code/cal1d_fp16_pool_sum.v \
  code/NV_NVDLA_PDP_nan.v \
  code/NV_NVDLA_PDP_CORE_unit1d.v \
  code/NV_NVDLA_PDP_CORE_cal1d.v
```

### 3. Yosys Elaboration & Latch-Free Synthesis Check (Mandatory Signoff Gate)

Both `NV_NVDLA_PDP_nan` and `NV_NVDLA_PDP_CORE_cal1d` must elaborate with zero inferred latches (`$dlatch*`) and zero combinational loops:

```bash
for TOP in NV_NVDLA_PDP_nan NV_NVDLA_PDP_CORE_cal1d; do
  yosys -q -p "
    read_verilog -DVERILINT -DSYNTHESIS -DDESIGNWARE_NOEXIST -DVLIB_BYPASS_POWER_CG -Icode \
      code/NV_BLKBOX_SINK.v code/CKLNQD12.v code/NV_CLK_gate_power.v \
      code/HLS_fp16_to_fp17.v code/HLS_fp17_add.v code/cal1d_fp16_pool_sum.v \
      code/NV_NVDLA_PDP_nan.v code/NV_NVDLA_PDP_CORE_unit1d.v code/NV_NVDLA_PDP_CORE_cal1d.v;
    hierarchy -check -top ${TOP};
    proc; opt_clean;
    check -assert;
    select -assert-none */t:\$dlatch*
  "
done
```
