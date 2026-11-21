# Build and Verification Guide

## Editable Files

Only the following RTL files may be modified:

- `code/axi_dma_wr.v`
- `code/axi_dma_rd.v`
- `code/axi_dma_desc_mux.v`

All other files under `code/` (`axi_dma.v`, `arbiter.v`, `priority_encoder.v`, `COPYING`) are read-only reference dependencies and must remain unchanged. Do not alter top-level port declarations or parameter names/defaults on `axi_dma`, `axi_dma_wr`, `axi_dma_rd`, or `axi_dma_desc_mux`.

## Available EDA Tools

- **Icarus Verilog**:
  - `iverilog`
  - `vvp`
- **Verilator**:
  - `verilator` (pass `-j 1`; do not set `VERILATOR_ROOT`)
- **Yosys**:
  - `yosys`

## Quick Sanity Commands

### 1. Elaboration & Lint Check

```bash
iverilog -g2012 -t null \
  code/priority_encoder.v code/arbiter.v code/axi_dma_desc_mux.v \
  code/axi_dma_rd.v code/axi_dma_wr.v code/axi_dma.v

verilator --lint-only \
  -Wno-fatal --top-module axi_dma \
  code/priority_encoder.v code/arbiter.v code/axi_dma_rd.v code/axi_dma_wr.v code/axi_dma.v

verilator --lint-only \
  -Wno-fatal --top-module axi_dma_desc_mux \
  code/priority_encoder.v code/arbiter.v code/axi_dma_desc_mux.v
```

### 2. Synthesis & Latch Check

```bash
yosys -q -p "
  read_verilog code/priority_encoder.v code/arbiter.v code/axi_dma_desc_mux.v code/axi_dma_rd.v code/axi_dma_wr.v code/axi_dma.v;
  hierarchy -check -top axi_dma;
  proc; opt_expr; opt_clean; check;
  select -assert-none t:\$dlatch* t:\$_DLATCH*
"
```
