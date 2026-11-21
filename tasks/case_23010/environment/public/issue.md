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
