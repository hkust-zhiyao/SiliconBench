#!/usr/bin/env python3
"""Isolated grader for case_22007 (RedMulE redmule_x_buffer S2_elab_synth_sim_parity)."""
import argparse
import hashlib
import json
import os
import pathlib
import re
import shutil
import subprocess
import tempfile

import os
import pathlib

def _sb_tools_dir() -> pathlib.Path:
    cand_env = os.environ.get('SILICONBENCH_TOOLS')
    if cand_env and pathlib.Path(cand_env).exists():
        return pathlib.Path(cand_env)
    if pathlib.Path('/opt/siliconbench/tools').exists():
        return pathlib.Path('/opt/siliconbench/tools')
    parents = pathlib.Path(__file__).resolve().parents
    repo_root = parents[5] if len(parents) > 5 else parents[-1]
    local_tools = repo_root / 'environments/tools'
    if local_tools.exists():
        return local_tools
    setup_script = repo_root / 'scripts/setup_tools.py'
    if setup_script.is_file():
        import subprocess as _sp
        _sp.run(['python3', str(setup_script), '--quiet'], check=False)
    return local_tools


def _sb_nangate45_dir() -> pathlib.Path:
    cand_env = os.environ.get('SILICONBENCH_NANGATE45')
    if cand_env and pathlib.Path(cand_env).exists():
        return pathlib.Path(cand_env)
    if pathlib.Path('/opt/siliconbench/pdk/Nangate45').exists():
        return pathlib.Path('/opt/siliconbench/pdk/Nangate45')
    parents = pathlib.Path(__file__).resolve().parents
    repo_root = parents[5] if len(parents) > 5 else parents[-1]
    return repo_root / 'environments/pdk/Nangate45'


TASK_DIR = pathlib.Path(__file__).resolve().parents[2]
PUB_DIR = TASK_DIR / "public"
TESTS_DIR = TASK_DIR / "private" / "tests"
TOOLS_DIR = pathlib.Path(str(_sb_tools_dir()))

EDITABLE = [
    "code/x_buffer/redmule_x_buffer.sv",
    "code/x_buffer/redmule_x_buffer_scm.sv",
    "code/x_buffer/redmule_x_pad_scm.sv",
]
READONLY = [
    "code/LICENSE",
    "code/fpnew_pkg.sv",
    "code/hci_package.sv",
    "code/hwpe_ctrl_package.sv",
    "code/hwpe_stream_package.sv",
    "code/redmule_pkg.sv",
    "code/tc_clk.sv",
]


def sha256_bytes(b: bytes) -> str:
    return hashlib.sha256(b).hexdigest()


def strip_comments(text: str) -> str:
    return re.sub(r"/\*.*?\*/|//[^\n]*", "", text, flags=re.S)


def write_result(path: pathlib.Path, verdict: str, stage: str, detail: str, extra: dict = None):
    payload = {
        "verdict": verdict,
        "stage": stage,
        "detail": detail,
    }
    if extra:
        payload.update(extra)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2) + "\n")


def tool_env() -> dict:
    env = os.environ.copy()
    extra_paths = [
        str(TOOLS_DIR / "verilator-v5.038" / "bin"),
        str(TOOLS_DIR / "iverilog-v13" / "bin"),
        str(TOOLS_DIR / "oss-cad-suite" / "bin"),
        "/usr/bin",
        "/bin",
    ]
    env["PATH"] = ":".join(extra_paths + [env.get("PATH", "")])
    if (TOOLS_DIR / "verilator-v5.038" / "share" / "verilator").exists():
        env["VERILATOR_ROOT"] = str(TOOLS_DIR / "verilator-v5.038" / "share" / "verilator")
    return env


def run_cmd(cmd: list[str], cwd: pathlib.Path, env: dict, timeout: int = 120):
    return subprocess.run(cmd, cwd=str(cwd), env=env, capture_output=True, text=True, timeout=timeout)


def check_structural(cand_dir: pathlib.Path) -> tuple[bool, str]:
    for rel in READONLY:
        pub_f = PUB_DIR / rel
        cand_f = cand_dir / rel
        if cand_f.exists() and sha256_bytes(cand_f.read_bytes()) != sha256_bytes(pub_f.read_bytes()):
            return False, f"Read-only file modified: {rel}"

    expected_ports = {
        "code/x_buffer/redmule_x_buffer.sv": [
            "module redmule_x_buffer", "DataW", "FpFormat", "Height", "Width", "UseLatches",
            "clk_i", "rst_ni", "clear_i", "ctrl_i", "flags_o", "x_buffer_o", "x_buffer_i",
        ],
        "code/x_buffer/redmule_x_buffer_scm.sv": [
            "module redmule_x_buffer_scm", "WORD_SIZE", "WIDTH", "HEIGHT", "N_OUTPUTS", "USE_LATCHES",
            "clk_i", "rst_ni", "clear_i", "write_en_i", "write_addr_i", "wdata_i", "read_en_i", "read_addr_i", "rdata_o",
        ],
        "code/x_buffer/redmule_x_pad_scm.sv": [
            "module redmule_x_pad_scm", "WORD_SIZE", "ROWS", "COLS", "USE_LATCHES",
            "clk_i", "rst_ni", "clear_i", "write_en_i", "write_addr_i", "wdata_i", "read_en_i", "read_addr_i", "rdata_o",
        ],
    }

    banned_macros = re.compile(r"`\s*(?:ifdef|ifndef|elsif)\s+(?:VERILATOR|SYNTHESIS|SIMULATION|__ICARUS__|VCS|QUESTA)\b", re.I)
    banned_tasks = re.compile(r"\$(?:fopen|fread|fwrite|system|finish|stop|readmemh|readmemb)\b|\b(?:force|release|bind)\b")

    for rel, req_tokens in expected_ports.items():
        f = cand_dir / rel
        if not f.is_file() or f.is_symlink():
            return False, f"Missing or symlinked editable file: {rel}"
        clean = strip_comments(f.read_text(errors="replace"))
        for tok in req_tokens:
            if tok not in clean:
                return False, f"Missing required module/port/parameter identifier `{tok}` in {rel}"
        if banned_macros.search(clean):
            return False, f"Forbidden simulator/synthesis macro divergence in {rel}"
        if banned_tasks.search(clean):
            return False, f"Forbidden system task or procedural force/bind in {rel}"

    return True, "ok"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--candidate", required=True)
    ap.add_argument("--seed", type=int, default=101)
    ap.add_argument("--result", required=True)
    args, _ = ap.parse_known_args()

    cand = pathlib.Path(args.candidate).resolve()
    res_path = pathlib.Path(args.result).resolve()
    env = tool_env()

    ok, msg = check_structural(cand)
    if not ok:
        write_result(res_path, "FAIL", "structural", msg)
        raise SystemExit(1)

    with tempfile.TemporaryDirectory(prefix="case_22007_grade_") as tmp:
        wdir = pathlib.Path(tmp)
        code_dir = wdir / "code"
        shutil.copytree(PUB_DIR / "code", code_dir)
        for rel in EDITABLE:
            shutil.copy2(cand / rel, wdir / rel)
        shutil.copy2(TESTS_DIR / "tb.sv", wdir / "tb.sv")
        shutil.copy2(TESTS_DIR / "tb_gl.sv", wdir / "tb_gl.sv")

        rtl_sources = [
            "code/fpnew_pkg.sv",
            "code/hci_package.sv",
            "code/hwpe_ctrl_package.sv",
            "code/hwpe_stream_package.sv",
            "code/redmule_pkg.sv",
            "code/tc_clk.sv",
            "code/x_buffer/redmule_x_pad_scm.sv",
            "code/x_buffer/redmule_x_buffer_scm.sv",
            "code/x_buffer/redmule_x_buffer.sv",
        ]

        # Stage 2: Multi-parameter functional Verilator simulation (10 configurations)
        v_cmd = [
            "verilator", "--binary", "-j", "4", "--timing", "-Wno-fatal",
            "-Mdir", "obj_sim", *rtl_sources, "tb.sv", "--top-module", "tb",
        ]
        r_comp = run_cmd(v_cmd, wdir, env, timeout=120)
        if r_comp.returncode != 0:
            tail = "\n".join((r_comp.stdout + "\n" + r_comp.stderr).strip().splitlines()[-25:])
            write_result(res_path, "FAIL", "functional", f"Verilator compilation/elaboration failed:\n{tail}")
            raise SystemExit(1)

        r_sim = run_cmd([str(wdir / "obj_sim" / "Vtb"), f"+SEED={args.seed}"], wdir, env, timeout=60)
        if r_sim.returncode != 0 or "ALL 10 PARAMETERIZED X_BUFFER CONFIGURATIONS PASSED" not in r_sim.stdout:
            tail = "\n".join((r_sim.stdout + "\n" + r_sim.stderr).strip().splitlines()[-25:])
            write_result(res_path, "FAIL", "functional", f"RTL functional simulation failed (seed={args.seed}):\n{tail}")
            raise SystemExit(1)

        # Stage 3: Yosys+slang synthesis & latch/loop audit across UseLatches=0, UseLatches=1, and degenerate H=1,W=1,DataW=16
        ys_deg = (
            "read_slang --top redmule_x_buffer -GHeight=1 -GWidth=1 -GDataW=16 -GUseLatches=0 "
            + " ".join(rtl_sources)
            + "; proc; opt; check -assert"
        )
        r_deg = run_cmd(["yosys", "-m", "slang", "-p", ys_deg], wdir, env, timeout=90)
        if r_deg.returncode != 0:
            tail = "\n".join((r_deg.stdout + "\n" + r_deg.stderr).strip().splitlines()[-25:])
            write_result(res_path, "FAIL", "synthesis", f"Degenerate (H=1,W=1,DataW=16) Yosys+slang elaboration failed:\n{tail}")
            raise SystemExit(1)

        for lat_val in (0, 1):
            netlist = f"netlist_lat{lat_val}.v"
            stat_json = f"stat_lat{lat_val}.json"
            ys_script = (
                f"read_slang --top redmule_x_buffer -GHeight=4 -GWidth=4 -GDataW=256 -GUseLatches={lat_val} "
                + " ".join(rtl_sources)
                + f"; synth -top redmule_x_buffer; check -assert; write_verilog -noattr {netlist}; tee -q -o {stat_json} stat -json"
            )
            r_syn = run_cmd(["yosys", "-m", "slang", "-p", ys_script], wdir, env, timeout=120)
            if r_syn.returncode != 0:
                tail = "\n".join((r_syn.stdout + "\n" + r_syn.stderr).strip().splitlines()[-25:])
                write_result(res_path, "FAIL", "synthesis", f"Yosys+slang synthesis failed for UseLatches={lat_val}:\n{tail}")
                raise SystemExit(1)

            stat_data = json.loads((wdir / stat_json).read_text())
            cells_by_type = stat_data.get("design", {}).get("num_cells_by_type", {})
            dlatch_cnt = sum(v for k, v in cells_by_type.items() if k.startswith("$_DLATCH_"))
            if lat_val == 0 and dlatch_cnt != 0:
                write_result(res_path, "FAIL", "synthesis", f"UseLatches=0 synthesized {dlatch_cnt} unexpected latches (must be 0)")
                raise SystemExit(1)
            if lat_val == 1 and dlatch_cnt < 64:
                write_result(res_path, "FAIL", "synthesis", f"UseLatches=1 synthesized only {dlatch_cnt} latches (expected latch-based SCM storage preserved)")
                raise SystemExit(1)

        # Stage 4: 4-state post-synthesis gate-level simulation equivalence (iverilog + simcells.v)
        simcells = TOOLS_DIR / "oss-cad-suite" / "share" / "yosys" / "simcells.v"
        for lat_val in (0, 1):
            netlist = f"netlist_lat{lat_val}.v"
            vvp_bin = f"gl_lat{lat_val}.vvp"
            r_iv = run_cmd(["iverilog", "-g2012", "-o", vvp_bin, str(simcells), netlist, "tb_gl.sv"], wdir, env, timeout=60)
            if r_iv.returncode != 0:
                tail = "\n".join((r_iv.stdout + "\n" + r_iv.stderr).strip().splitlines()[-25:])
                write_result(res_path, "FAIL", "equivalence", f"Gate-level iverilog compile failed (UseLatches={lat_val}):\n{tail}")
                raise SystemExit(1)
            r_vvp = run_cmd(["vvp", vvp_bin, f"+SEED={args.seed}"], wdir, env, timeout=60)
            if r_vvp.returncode != 0 or "4-STATE GATE-LEVEL EQUIVALENCE PASSED!" not in r_vvp.stdout:
                tail = "\n".join((r_vvp.stdout + "\n" + r_vvp.stderr).strip().splitlines()[-25:])
                write_result(res_path, "FAIL", "equivalence", f"4-state gate-level simulation failed (UseLatches={lat_val}, seed={args.seed}):\n{tail}")
                raise SystemExit(1)

    write_result(
        res_path,
        "PASS",
        "equivalence",
        f"All 10 RTL configurations, Yosys+slang synthesis checks, and 4-state gate-level netlist simulations passed (seed={args.seed})",
    )


if __name__ == "__main__":
    main()
