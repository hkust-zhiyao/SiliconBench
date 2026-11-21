# case_23010: CACC Asymmetric 8-SRAM Accumulator RMW Pipeline & Physical Macro Co-Design

> **SiliconBench Standardized Harbor Task**
> - **Repository**: `nvdla/hw` (`repo_36`)
> - **Engineering Problem Type**: `RTL + Hard-SRAM Macro Physical Co-Design` (`PT5_RTL_HardSRAM_Macro_PnR`)
> - **EDA Evaluation Stage**: `Stage 4: Hard-SRAM Floorplanning, CTS & Routing (PnR)` (`stage4_macro_pnr`)
> - **PDK / Environment Profile**: `IHP SG13G2 130nm Open PDK + RM_IHPSG13_1P Hard-SRAM Macros`
> - **Editable Files (`allowed_edits`)**: `code/NV_NVDLA_CACC_assembly_ctrl.v`, `code/NV_NVDLA_CACC_assembly_buffer.v`, `code/NV_NVDLA_CACC_delivery_buffer.v`, `plan/macro_placement.json`, `constraints/cacc_subsys.sdc`

---

## Problem Specification

# CACC Asymmetric 8-SRAM Accumulator Subsystem & Physical Macro Co-Design

## Overview
`cacc_sram_subsys` (`code/cacc_sram_subsys.v`) integrates NVDLA's Convolution Accumulator control, 8-bank single-port SRAM assembly buffer, multi-precision calculators (`INT8=2'h0`, `INT16=2'h1`, `FP16=2'h2`), and downstream SDP delivery interface. You own the RTL-to-physical co-design across:
- `code/NV_NVDLA_CACC_assembly_ctrl.v`
- `code/NV_NVDLA_CACC_assembly_buffer.v`
- `code/NV_NVDLA_CACC_delivery_buffer.v`
- `plan/macro_placement.json`
- `constraints/cacc_subsys.sdc`

All other files under `code/` and `pdk/` are read-only collateral.

## Architectural & Protocol Contract
1. **Multi-Stripe Accumulation (`Direct` & `Winograd`)**:
   - Accumulate incoming MAC stripes bounded by `mac2accu_pd[6]` (`stripe_end`), `mac2accu_pd[7]` (`channel_end`), and `mac2accu_pd[8]` (`layer_end`) across `INT8` and `INT16` precisions in both `reg2dp_conv_mode=0` (Direct) and `reg2dp_conv_mode=1` (Winograd) modes, and `FP16` precision in `reg2dp_conv_mode=0` (Direct) mode.
   - Start each channel group clean of residual SRAM data, accumulate intermediate stripes in the assembly buffer, and deliver rounded/saturated final channel-group results to SDP on `channel_end=1`.
2. **8-Bank Single-Port SRAM Assembly Buffer**:
   - `NV_NVDLA_CACC_assembly_buffer` instantiates eight `RM_IHPSG13_1P_256x64_c2_bm_bist` single-port synchronous SRAM macros (`u_accu_abuf_0`..`u_accu_abuf_7`), maintaining the 3-cycle `abuf_rd_en -> abuf_rd_data_*` read contract across arbitrary stripe lengths and input bubble patterns.
   - Primary banks `0..3` (`48`-bit payload) operate in all precisions; extension banks `4..7` (`34`-bit payload) operate only in `INT8` mode and must hold `A_MEN == 1'b0` throughout `INT16` and `FP16` operation.
3. **Backpressured SDP Delivery & Layer Interrupts**:
   - `NV_NVDLA_CACC_delivery_buffer` must preserve lossless `cacc2sdp_valid`/`cacc2sdp_pd` handshaking under arbitrary `cacc2sdp_ready` backpressure and emit a 1-cycle completion pulse on `cacc2glb_done_intr_pd[1:0]` alternating between `2'b01` and `2'b10` when a `layer_end` (`cacc2sdp_pd[129]`) beat retires.

## Physical Floorplan & Signoff Timing Targets (IHP SG13G2 130nm)
- **Floorplan (`plan/macro_placement.json`)**: Die area `[0, 0, 2600, 1900]` um, core area `[50, 50, 2550, 1850]` um. Place all eight `RM_IHPSG13_1P_256x64_c2_bm_bist` macros (`784.48 x 118.78` um) inside the core boundary (`>= 2` um core margin, `>= 8` um inter-macro halo, orientation in `{R0, R180, MX, MY}`).
- **SDC (`constraints/cacc_subsys.sdc`)**: Constrain `nvdla_core_clk` to period `<= 15.0` ns with `>= 1.2` ns input/output delays on all non-clock ports (only `nvdla_core_rstn` may carry `set_false_path`).
- **OpenROAD Signoff**: Connected `VDD`/`VSS` PDN grids, post-GRT setup `WNS >= 0.0` ns, hold slack `>= 0.0` ns, total GRT overflow `<= 15`, and total routed wirelength `<= 2,650,000` um.

---

## Build, Simulation, and EDA Verification Instructions

# Build & Verification Environment (`case_23010`)

## Available Tools & Collateral
- **RTL Simulation**: Icarus Verilog (`iverilog -g2012` / `vvp`) or Verilator (`verilator`)
- **Synthesis**: Yosys with SystemVerilog Slang frontend (`yosys -m slang`)
- **Physical Implementation & STA**: OpenROAD (`openroad -exit`)
- **PDK Collateral (`pdk/`)**: IHP SG13G2 130nm standard cells (`sg13g2_tech.lef`, `sg13g2_stdcell.lef`, `sg13g2_stdcell_typ_1p20V_25C.lib`, `core.v`) and `RM_IHPSG13_1P_256x64_c2_bm_bist` SRAM macro views (`256.v` behavioral model, `256_stub.v` blackbox stub, `256.lef`, `256.lib`).

## Editable Files
- `code/NV_NVDLA_CACC_assembly_ctrl.v`
- `code/NV_NVDLA_CACC_assembly_buffer.v`
- `code/NV_NVDLA_CACC_delivery_buffer.v`
- `plan/macro_placement.json`
- `constraints/cacc_subsys.sdc`

## Example Commands
```bash
# 1. Behavioral RTL elaboration check
iverilog -g2012 -o /tmp/cacc_sim \
  pdk/core.v pdk/256.v code/NV_DW_lsd.v \
  code/NV_NVDLA_CACC_CALC_int8.v code/NV_NVDLA_CACC_CALC_int16.v code/NV_NVDLA_CACC_CALC_fp_48b.v \
  code/NV_NVDLA_CACC_assembly_ctrl.v code/NV_NVDLA_CACC_assembly_buffer.v \
  code/NV_NVDLA_CACC_delivery_buffer.v code/cacc_sram_subsys.v

# 2. Synthesis to SG13G2 standard cells + 8x hard SRAM macros
yosys -m slang -p "
  read_slang -DSYNTHESIS pdk/256_stub.v code/NV_DW_lsd.v \
    code/NV_NVDLA_CACC_CALC_int8.v code/NV_NVDLA_CACC_CALC_int16.v code/NV_NVDLA_CACC_CALC_fp_48b.v \
    code/NV_NVDLA_CACC_assembly_ctrl.v code/NV_NVDLA_CACC_assembly_buffer.v \
    code/NV_NVDLA_CACC_delivery_buffer.v code/cacc_sram_subsys.v --top cacc_sram_subsys;
  hierarchy -check -top cacc_sram_subsys;
  synth -top cacc_sram_subsys -flatten;
  delete t:\$scopeinfo;
  dfflibmap -liberty pdk/sg13g2_stdcell_typ_1p20V_25C.lib;
  abc -liberty pdk/sg13g2_stdcell_typ_1p20V_25C.lib;
  setundef -zero; splitnets -ports; opt_clean -purge;
  write_verilog -noattr -noexpr -nohex /tmp/mapped.v
"
```

---

## Submission Contract (`allowed_edits`)

You must modify **only** the following allowlisted file(s) in your workspace:
- `code/NV_NVDLA_CACC_assembly_ctrl.v`
- `code/NV_NVDLA_CACC_assembly_buffer.v`
- `code/NV_NVDLA_CACC_delivery_buffer.v`
- `plan/macro_placement.json`
- `constraints/cacc_subsys.sdc`

All other files in the workspace are read-only reference context and must remain unmodified.
