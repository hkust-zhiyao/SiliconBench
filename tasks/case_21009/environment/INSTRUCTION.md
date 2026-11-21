# case_21009: Streaming Ones'-Complement Checksum Offload Pipeline Backpressure, Multi-Beat Offset & Nangate45 PPA Closure

> **SiliconBench Standardized Harbor Task**
> - **Repository**: `corundum/corundum` (`repo_39`)
> - **Engineering Problem Type**: `High-Frequency Timing & Area Optimization` (`PT3_Timing_Area_PPA_Closure`)
> - **EDA Evaluation Stage**: `Stage 3: Static Timing (STA) & CDC/RDC Closure` (`stage3_sta_cdc`)
> - **PDK / Environment Profile**: `IHP SG13G2 130nm Open PDK + RM_IHPSG13_1P Hard-SRAM Macros`
> - **Editable Files (`allowed_edits`)**: `code/tx_checksum.v`, `code/rx_checksum.v`

---

## Problem Specification

# Streaming Ones'-Complement Checksum Offload Pipeline Backpressure, Multi-Beat Offset & Nangate45 PPA Closure

`tx_checksum` (`code/tx_checksum.v`) and `rx_checksum` (`code/rx_checksum.v`) implement streaming RFC 1071 16-bit ones'-complement checksum offload across parameterized AXI4-Stream datapaths (`DATA_WIDTH` in `{64, 256}`). In ASIC synthesis and system integration, both modules fail high-frequency timing closure due to cascaded single-cycle end-around carry folding and dynamic byte-offset muxing, while exhibiting packet-to-checksum desynchronization under FIFO backpressure, multi-beat offset counter truncation, and unreset accumulator state:

Update `code/tx_checksum.v` and `code/rx_checksum.v` while preserving all top-level module names, port interfaces, and parameter definitions (`DATA_WIDTH`, `KEEP_WIDTH`, `ID_ENABLE`, `ID_WIDTH`, `DEST_ENABLE`, `DEST_WIDTH`, `USER_ENABLE`, `USER_WIDTH`, `USE_INIT_VALUE`, `DATA_FIFO_DEPTH`, `CHECKSUM_FIFO_DEPTH` on `tx_checksum`; `DATA_WIDTH`, `KEEP_WIDTH`, `START_OFFSET` on `rx_checksum`):

1. **Multi-Width Checksum Accuracy, FIFO Backpressure Integrity & ASIC Reset Hygiene (`DATA_WIDTH` in `{64, 256}`)**:
   - **`tx_checksum`**: Compute big-endian 16-bit ones'-complement checksums from byte `s_axis_cmd_csum_start` through `s_axis_tlast` (supporting even and odd `s_axis_cmd_csum_start` byte swaps, single-beat and multi-beat skip offsets `>= KEEP_WIDTH`, `USE_INIT_VALUE` in `{0, 1}`, and passthrough when `s_axis_cmd_csum_enable == 1'b0`), writing the inverted 16-bit checksum at `s_axis_cmd_csum_offset` (including 2-byte split insertion across consecutive beats when `csum_offset % KEEP_WIDTH == KEEP_WIDTH - 1`). Preserve strict 1-to-1 packet/checksum alignment without dropping or shifting checksums when `csum_fifo` fills under sustained `m_axis_tready == 1'b0` backpressure.
   - **`rx_checksum`**: Compute big-endian 16-bit ones'-complement packet sums from byte `START_OFFSET` through `s_axis_tlast` across arbitrary `START_OFFSET >= 0`, including multi-beat skip offsets `START_OFFSET >= 2 * KEEP_WIDTH` (e.g., `START_OFFSET = 16` at `DATA_WIDTH = 64` and `START_OFFSET = 64` at `DATA_WIDTH = 256`) and frames shorter than `START_OFFSET` (`m_axis_csum = 16'h0000`).
   - Synchronously reset all control, pipeline valid, and accumulator state on `rst` so ASIC gate-level simulation (without FPGA power-on register initializers) and mid-frame `rst` recovery exhibit zero `X` propagation and zero cross-packet residue.

2. **Nangate45 Datapath Timing & Area Signoff (`DATA_WIDTH = 64`)**:
   - Refactor/retime the end-around carry accumulation and byte-lane insertion paths so under Nangate45 OpenSTA setup/hold signoff (`0.10` ns input/output delay on all non-clock, non-reset ports; `set_false_path -from [get_ports rst]`):
     - `rx_checksum` (`DATA_WIDTH=64, START_OFFSET=14`) closes at **`clk = 1.24` ns** with **`WNS >= 0.00` ns**, **`TNS >= 0.00` ns**, **`worst hold slack >= 0.00` ns**, and mapped cell area **`<= 1,750` um²**;
     - `tx_checksum` (`DATA_WIDTH=64, USE_INIT_VALUE=1, DATA_FIFO_DEPTH=8, CHECKSUM_FIFO_DEPTH=4`) closes at **`clk = 1.46` ns** with **`WNS >= 0.00` ns**, **`TNS >= 0.00` ns**, **`worst hold slack >= 0.00` ns**, and mapped cell area **`<= 7,200` um²**.

---

## Build, Simulation, and EDA Verification Instructions

The checksum offload RTL in `code/` derives from `corundum/corundum` commit `1ca0151b97af85aa5dd306d74b6bcec65904d2ce` (`code/LICENSE`, BSD-2-Clause-Views).

Editable files:
- `code/tx_checksum.v`
- `code/rx_checksum.v`

Read-only files:
- `code/axis_fifo.v`
- `code/LICENSE`
- `pdk/NangateOpenCellLibrary_typical.lib`

Editable RTL must remain pure synthesizable HDL (do not add simulation-control or file-I/O system tasks such as `$finish`, `$stop`, `$fatal`, or `$readmem*`, and do not use simulator/synthesis macro divergence).

Local compilation, Yosys Nangate45 synthesis, and OpenSTA timing/area check from the workspace root:
```bash
# 1. Icarus Verilog compilation check
iverilog -g2012 -o /tmp/csum_chk.vvp \
  code/tx_checksum.v code/rx_checksum.v code/axis_fifo.v

# 2. Yosys Nangate45 synthesis & area report (example for tx_checksum; repeat for rx_checksum with -chparam DATA_WIDTH 64 -chparam START_OFFSET 14)
yosys -p "
  read_verilog code/tx_checksum.v code/axis_fifo.v;
  hierarchy -check -top tx_checksum -chparam DATA_WIDTH 64 -chparam USE_INIT_VALUE 1 -chparam DATA_FIFO_DEPTH 8 -chparam CHECKSUM_FIFO_DEPTH 4;
  synth -flatten -top tx_checksum;
  dfflibmap -liberty pdk/NangateOpenCellLibrary_typical.lib;
  abc -liberty pdk/NangateOpenCellLibrary_typical.lib;
  opt_clean -purge;
  stat -liberty pdk/NangateOpenCellLibrary_typical.lib;
  write_verilog -noattr -simple-lhs /tmp/tx_csum_net.v
"

# 3. OpenSTA timing verification (1.46 ns for tx_checksum; 1.24 ns for rx_checksum)
LD_LIBRARY_PATH=/opt/siliconbench/tools/openroad-runtime/usr/lib/x86_64-linux-gnu:/opt/siliconbench/tools/openroad-runtime/opt/or-tools/lib \
  sta -no_init -exit <<'EOF'
read_liberty pdk/NangateOpenCellLibrary_typical.lib
read_verilog /tmp/tx_csum_net.v
link_design tx_checksum
create_clock -name clk -period 1.46 [get_ports clk]
set_false_path -from [get_ports rst]
foreach p [get_ports *] {
    set n [get_name $p]
    if {$n != "clk" && $n != "rst"} {
        if {[get_property $p direction] == "input"} { set_input_delay 0.10 -clock clk $p } else { set_output_delay 0.10 -clock clk $p }
    }
}
report_tns
report_wns
report_checks -path_delay min_max
EOF
```

---

## Submission Contract (`allowed_edits`)

You must modify **only** the following allowlisted file(s) in your workspace:
- `code/tx_checksum.v`
- `code/rx_checksum.v`

All other files in the workspace are read-only reference context and must remain unmodified.
