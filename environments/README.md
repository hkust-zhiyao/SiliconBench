# SiliconBench Harbor Environment & Customization Architecture (94 Tasks, 30 Repositories)

## 1. Do All 94 Tasks Share the Same Base Container Image?

**Yes.** Every single task in **SiliconBench** (`94` tasks across `30` real-world open-source SystemVerilog repositories) runs on the **exact same unified base container image (`siliconbench-eda:1.0`)**, defined in [`environments/siliconbench-eda/Dockerfile`](siliconbench-eda/Dockerfile) and [`environments/environment_config.json`](environment_config.json).

Using a single unified base image provides major practical advantages for Harbor users:
1. **Zero Per-Task Docker Build Overhead**: You only build or pull `siliconbench-eda:1.0` once; all 94 tasks mount their lightweight `environment/public/` subsystem workspace (`2–70` public RTL files, median `12` files / `3,670` LOC) and `tests/private/` verifier directly on top of `siliconbench-eda:1.0`.
2. **Strict Deterministic Reproducibility**: Every task executes with identical EDA tool binaries (`Verilator v5.038`, `Icarus Verilog v13.0`, `Yosys + Slang`, `OpenSTA 3.1.0`, `OpenROAD v26Q2`) and single-threaded deterministic flags (`OMP_NUM_THREADS=1`, `MAKEFLAGS=-j1`).
3. **Two-Phase Air-Gapped Harbor Isolation (`environment_mode = "separate"`)**:
   - **Phase 1 (Offline Solver Sandbox)**: Runs `siliconbench-eda:1.0` with `allow_internet = false` and `.git` history stripped, mounting **only** `instruction.md` and `environment/public/` into `/workspace` (with zero pre-supplied grading testbenches).
   - **Phase 2 (Isolated Harbor Verifier)**: Runs a separate `siliconbench-eda:1.0` container with `allow_internet = false`, overlays **only** the task's allowlisted `allowed_edits` onto a clean copy of `public/`, and executes `/tests/test.sh` against `/tests/private/grader/run.py`.

---

## 2. Unified EDA Toolchain & PDKs in `siliconbench-eda:1.0`

| Tool / PDK Category | Binary / Library | Version / Path in Container | Purpose across the 4-Stage ASIC Verification Flow |
| :--- | :--- | :--- | :--- |
| **SystemVerilog Lint & Cycle Sim** | `verilator` | `v5.038` (`/opt/siliconbench/tools/verilator-v5.038/bin/verilator`) | Stage 1 Lint & 2-State Cycle-Accurate Simulation (`94/94`) |
| **IEEE 1800-2017 4-State Sim** | `iverilog`, `vvp` | `v13.0` (`/opt/siliconbench/tools/iverilog-v13/bin/iverilog`) | Stage 1 & Stage 2 4-State (`0/1/X/Z`) RTL & Gate-Level `X`-Prop Sim |
| **SV2017 Synthesis & Mapping** | `yosys -m slang`, `sby` | `OSS CAD Suite` (`/opt/siliconbench/tools/oss-cad-suite/bin/yosys`) | Stage 2 Standard-Cell Synthesis, Area Caps & Latch/Loop Checks (`85/94`) |
| **Static Timing Analysis (STA)** | `sta` (`OpenSTA`) | `OpenSTA 3.1.0` (`/opt/siliconbench/tools/bin/sta`) | Stage 3 Single- & Multi-Corner (`SS`/`TT`/`FF`) WNS/TNS & CDC/RDC (`81/94`) |
| **Physical Implementation (PnR)** | `openroad` | `v26Q2-1164-g08f67ee5ec` (`/opt/siliconbench/tools/bin/openroad`) | Stage 4 Hard-SRAM Floorplan, PDN, `TritonCTS` Skew & `FastRoute` (`15/94`) |
| **45nm CMOS Open Cell Library** | `NanGate45` | Bundled at `/opt/siliconbench/pdk/Nangate45` ([`environments/pdk/Nangate45/`](pdk/Nangate45/)) | Shared 45nm Liberty (`.lib`) & LEF (`.lef`) for synthesis, GLS & STA |
| **130nm 3-Corner Hard-SRAM PDK** | `IHP SG13G2` | Task-bundled in `environment/public/pdk/` & `tests/private/pdk/` | 3-Corner (`SS`/`TT`/`FF`) 130nm CMOS + hard-SRAM macro LEF/LIB/Verilog |

---

## 3. Task-Specific Environment Customizations (`pdk_profile` & `task.toml`)

While the container image (`siliconbench-eda:1.0`) is identical across all 94 tasks, tasks customize their **PDK/timing collateral**, **editable file contracts (`allowed_edits`: `70/94` RTL-only vs. `24/94` joint RTL+`.sdc`/floorplan)**, and **multi-seed grading configurations** in each task's `task.toml` and [`environment_config.json`](environment_config.json):

| PDK / Collateral Profile (`pdk_id`) | Task Count | Customized Per Task? | Where Collateral Lives & How It Works |
| :--- | :---: | :---: | :--- |
| `nangate45_45nm_shared` | **8** | **No** (Shared Base) | Uses `/opt/siliconbench/pdk/Nangate45/lib/NangateOpenCellLibrary_typical.lib` & LEF pre-installed in the base image. |
| `nangate45_plus_multicorner_lib` | **36** | **Yes** (Task-Bundled) | Uses shared `NanGate45` for synthesis + task-specific multi-corner `.lib`/`.sdc` views in `environment/public/` and `tests/private/`. |
| `ihp_sg13g2_130nm_8sram` | **18** | **Yes** (Task-Bundled) | Bundles **IHP SG13G2 130nm 3-Corner Open PDK** (`sg13g2_stdcell.lef/.lib`, `sg13g2_tech.lef`) + **hard-SRAM Macro LEF/LIB/Verilog** inside `environment/public/pdk/` and `tests/private/pdk/`. |
| `custom_multicorner_liberty` | **7** | **Yes** (Task-Bundled) | Bundles custom multi-corner Liberty (`.lib`) and OpenSTA scripts inside `environment/public/` and `tests/private/`. |
| `rtl_dual_sim_standard` | **25** | **No** (Shared Base) | Multi-file SystemVerilog RTL, synthesis & gate-level verification using `Verilator` + `iverilog` + `Yosys+Slang`. |

See [`environment_config.json`](environment_config.json) for the complete 94-task machine-readable customization matrix.
