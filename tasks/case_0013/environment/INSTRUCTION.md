# case_0013: Handle external resets during DMA operation

> **SiliconBench Standardized Harbor Task**
> - **Repository**: `analogdevicesinc/hdl` (`repo_38`)
> - **Engineering Problem Type**: `Gate-Level Equivalence, Security & CDC/RDC` (`PT4_GateLevel_Security_CDC`)
> - **EDA Evaluation Stage**: `Stage 1: Frontend RTL Design & Functional Simulation` (`stage1_rtl_sim`)
> - **PDK / Environment Profile**: `Standard IEEE 1800-2017 SystemVerilog Dual-Simulator + Yosys Slang`
> - **Editable Files (`allowed_edits`)**: `code/axi_dmac_reset_manager.v`

---

## Problem Specification

# Handle external resets during DMA operation

The reset manager's external-reset inputs are currently unused. Complete their handling for source, destination, and, when enabled, scatter-gather domains. Assertion must reset the affected domain immediately; release must be synchronized to that domain's clock. An external reset aborts the active DMA operation: stop admitting new requests, allow the other domains to acknowledge shutdown, then run the existing full reset sequence before restarting. A brief external reset must not be lost, and the manager must wait for every participating external reset to be released before restarting. Ignore the scatter-gather reset when that domain is disabled.

Preserve the existing enable, pause and reset sequencing when external resets stay released. The input clocks continue running throughout this sequence. The existing reset chain and enable/acknowledge interfaces provide the integration context.

---

## Build, Simulation, and EDA Verification Instructions

The editable source is `code/axi_dmac_reset_manager.v`; its `sync_bits` dependency is included unchanged from the same upstream HDL repository. Use a free Verilog simulator such as Icarus Verilog with SystemVerilog enabled, or Verilator.

---

## Submission Contract (`allowed_edits`)

You must modify **only** the following allowlisted file(s) in your workspace:
- `code/axi_dmac_reset_manager.v`

All other files in the workspace are read-only reference context and must remain unmodified.
