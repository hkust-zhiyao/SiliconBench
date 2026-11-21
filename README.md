# SiliconBench v1.0

**Benchmarking agents on full-stack, front-to-back silicon engineering.**

[Website](https://siliconbench.github.io) · [Leaderboard](https://siliconbench.github.io/leaderboard/) · [Task Explorer](https://siliconbench.github.io/explorer/) · [Blog](https://siliconbench.github.io/blog/siliconbench-v1/)

**SiliconBench v1.0** provides **94 hardware engineering tasks** curated from **30 open-source SystemVerilog repositories** in the standardized two-container **[Harbor](https://github.com/laude-institute/harbor)** format, built on a shared EDA base container (`siliconbench-eda:1.0`).

---

## How to Browse the Benchmark

- **94-Task Catalog**: See [`TASKS_INDEX.md`](TASKS_INDEX.md) for the full list of tasks with repository names, EDA stages, problem types, editable files, and direct links.
- **Per-Task Structure (`tasks/<case_id>/`)**:
  - `README.md`: Task overview (`task.toml` metadata summary), problem specification (`issue.md`), build notes (`BUILD.md`), unified diff between `environment/public/` and `solution/gold/`, and file inventory.
  - `instruction.md`: Self-contained task prompt provided to the solver (problem specification, build guide, and editable-file allowlist).
  - `task.toml`: Standardized Harbor task configuration (timeouts, network isolation `allow_internet = false`, `environment_mode = "separate"`, editable allowlist, and deterministic grading seeds).
  - `environment/public/`: Public multi-file RTL workspace mounted into `/workspace` in Phase 1 (zero grading testbenches).
  - `solution/`: Reference solutions (`solve.sh` oracle entrypoint, `gold/`, and `alternate_gold/`).
  - `tests/`: Isolated Phase 2 verifier (`test.sh` and `tests/private/` containing `policy_filter.py`, private multi-seed testbenches, and `grader/run.py`).

---

## Repository Structure

```text
SiliconBench/
├── README.md                          # Benchmark browsing and usage guide
├── TASKS_INDEX.md                     # Complete 94-task catalog with direct links
├── harbor.toml                        # Harbor suite configuration (94 tasks)
├── dataset.toml                       # Dataset manifest (94 tasks)
├── environments/
│   ├── README.md                      # Base image and per-task PDK profile notes
│   ├── environment_config.json        # Machine-readable 94-task environment matrix
│   ├── siliconbench-eda/
│   │   └── Dockerfile                 # Unified EDA base image (siliconbench-eda:1.0)
│   └── pdk/
│       └── Nangate45/                 # Bundled NanGate45 45nm open cell library
├── scripts/
│   ├── install_eda_tools.sh           # Install pinned open-source EDA toolchain locally
│   ├── setup_tools.py                 # Link/verify local EDA tools into environments/tools/
│   └── run_harbor_eval.py             # Standalone verifier CLI (oracle / alt_oracle / starter / candidate)
└── tasks/
    └── case_xxxx/                     # 94 Harbor task packages (case_0009 ... case_25018)
```

---

## Running Verification

### 1. Using the Harbor CLI

```bash
# Build the shared base image once
docker build -t siliconbench-eda:1.0 -f environments/siliconbench-eda/Dockerfile environments/

# Verify a single task with the oracle solution (runs solution/solve.sh -> tests/test.sh)
harbor run --task tasks/case_0009 --agent oracle

# Run an agent across the full 94-task benchmark
harbor run --config harbor.toml --agent <your-agent>
```

### 2. Using the Standalone Verifier CLI (`scripts/run_harbor_eval.py`)

If running outside Docker, install or link the pinned EDA toolchain (`Verilator v5.038`, `Icarus Verilog v13.0`, `OSS CAD Suite Yosys+Slang`, `OpenSTA 3.1.0`, `OpenROAD v26Q2`) first:

```bash
# Option A: Install pinned EDA tools into environments/tools/
bash scripts/install_eda_tools.sh

# Option B: Link an existing local toolchain directory
python3 scripts/setup_tools.py --from-dir /path/to/tools
```

Then run verification:

```bash
# Verify primary reference solution (expected reward = 1.0)
python3 scripts/run_harbor_eval.py --mode oracle --task case_0009

# Verify alternate_gold reference solution (expected reward = 1.0)
python3 scripts/run_harbor_eval.py --mode alt_oracle --task case_0009

# Verify unmodified buggy starter fails (expected reward = 0.0)
python3 scripts/run_harbor_eval.py --mode starter --task case_0009

# Grade candidate workspaces across all 94 tasks
python3 scripts/run_harbor_eval.py --mode candidate --submissions-dir /path/to/submissions --workers 6 --output results.json
```

---

## Leaderboard (v1.0)

| Agent | Pass rate | Tool calls (median) | Runs attempting hacks |
|---|---:|---:|---:|
| Claude Opus 5.5 (high) | **84.0%** | 61.5 | 2.1% |
| Claude Sonnet 5.5 (high) | 73.4% | 54.0 | 1.1% |
| GPT-Sol 6.1 (high) | 52.1% | 44.5 | 2.1% |
| GPT-Terra 6.1 (high) | 40.4% | 37.5 | 2.1% |
| GLM-5.3 (high) | 33.0% | 136.0 | 17.0% |
| DeepSeek-V4.1-Flash-1017 (high) | 27.7% | 122.0 | 31.9% |

No hacking attempt succeeded.

## License

Each task keeps the license of its upstream open-source repository (see `environment/public/code/LICENSE` in each task).

## Citation

```bibtex
@misc{liu2026siliconbench,
  title  = {SiliconBench-v1.0: Benchmarking Agents on Full-Stack Front-to-Back Silicon Engineering},
  author = {Liu, Shang and Fang, Wenji and Wang, Jing and Guo, Ziyan and Lu, Yao and Xie, Zhiyao},
  year   = {2026},
  url    = {https://siliconbench.github.io}
}
```

Built at the Hong Kong University of Science and Technology (HKUST).
