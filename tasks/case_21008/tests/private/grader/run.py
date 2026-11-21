#!/usr/bin/env python3
import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

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


IVERILOG = f"{_sb_tools_dir()}/iverilog-v13/bin/iverilog"
VVP = f"{_sb_tools_dir()}/iverilog-v13/bin/vvp"
VERILATOR = f"{_sb_tools_dir()}/verilator-v5.038/bin/verilator"
YOSYS = f"{_sb_tools_dir()}/oss-cad-suite/bin/yosys"
SIMCELLS = f"{_sb_tools_dir()}/oss-cad-suite/share/yosys/simcells.v"

EDITABLE_FILES = [
    "code/axi_adapter.v",
    "code/axi_adapter_rd.v",
    "code/axi_adapter_wr.v",
]

READONLY_FILES = [
    "code/COPYING",
]

REQUIRED_MODULES = {
    "code/axi_adapter.v": "axi_adapter",
    "code/axi_adapter_rd.v": "axi_adapter_rd",
    "code/axi_adapter_wr.v": "axi_adapter_wr",
}


def sha256_file(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def strip_comments(src: str) -> str:
    src = re.sub(r"/\*.*?\*/", "", src, flags=re.S)
    src = re.sub(r"//.*?$", "", src, flags=re.M)
    return src


def write_result(path: Path, verdict: str, stage: str, detail: str) -> int:
    path.parent.mkdir(parents=True, exist_ok=True)
    payload = {"verdict": verdict, "stage": stage, "detail": detail}
    path.write_text(json.dumps(payload, indent=2) + "\n")
    return 0 if verdict == "PASS" else 1


def check_policy(cand_dir: Path, pub_dir: Path):
    for rel in READONLY_FILES:
        cp = cand_dir / rel
        pp = pub_dir / rel
        if not cp.is_file():
            return f"Missing required read-only file: {rel}"
        if sha256_file(cp) != sha256_file(pp):
            return f"Tampered read-only file: {rel}"

    for rel in EDITABLE_FILES:
        cp = cand_dir / rel
        if not cp.is_file():
            return f"Missing editable RTL file: {rel}"
        raw = cp.read_text(errors="replace")
        clean = strip_comments(raw)

        if re.search(r"\b(tb|tb_gl)\s*\.", clean):
            return f"Policy violation in {rel}: hierarchical_harness_reference"

        if re.search(r"\$(stop|fatal|system|fopen|fdumpfile|dumpfile|readmemh|readmemb|writememh|writememb|display|write|strobe|monitor)\b", clean):
            return f"Policy violation in {rel}: forbidden_systask"

        if re.search(r"`\s*ifn?def\s+(VERILATOR|__ICARUS__|SYNTHESIS|YOSYS)\b", clean):
            return f"Policy violation in {rel}: tool_macro_divergence"

        if re.search(r"\bforce\b|\brelease\b", clean):
            return f"Policy violation in {rel}: force_release_construct"

        mod = REQUIRED_MODULES[rel]
        if not re.search(rf"\bmodule\s+{mod}\b", clean):
            return f"Structural violation in {rel}: missing module {mod}"

    return None


def run_cmd(cmd, cwd: Path, timeout_sec: int = 90):
    env = dict(os.environ)
    env.pop("VERILATOR_ROOT", None)
    return subprocess.run(
        cmd,
        cwd=str(cwd),
        env=env,
        capture_output=True,
        text=True,
        timeout=timeout_sec,
    )


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--candidate", required=True)
    ap.add_argument("--result", required=True)
    ap.add_argument("--seed", type=int, default=101)
    args, _ = ap.parse_known_args()

    cand_dir = Path(args.candidate).resolve()
    res_path = Path(args.result).resolve()
    task_dir = Path(__file__).resolve().parents[2]
    pub_dir = task_dir / "public"
    tb_path = task_dir / "private" / "tests" / "tb.sv"
    tb_gl_path = task_dir / "private" / "tests" / "tb_gl.sv"

    pol_err = check_policy(cand_dir, pub_dir)
    if pol_err:
        stage = "structural" if pol_err.startswith("Structural") else "policy"
        return write_result(res_path, "FAIL", stage, pol_err)

    rtl_files = [str(cand_dir / rel) for rel in EDITABLE_FILES]

    with tempfile.TemporaryDirectory(prefix="case_21008_") as tmp:
        wdir = Path(tmp)
        tb_local = wdir / "tb.sv"
        tb_gl_local = wdir / "tb_gl.sv"
        shutil.copy2(tb_path, tb_local)
        shutil.copy2(tb_gl_path, tb_gl_local)

        # 1. Icarus Verilog multi-parameter compilation & functional simulation
        vvp_bin = wdir / "sim_iv.vvp"
        p = run_cmd([IVERILOG, "-g2012", "-P", f"tb.SEED={args.seed}", "-o", str(vvp_bin), str(tb_local)] + rtl_files, wdir, 60)
        if p.returncode != 0:
            return write_result(res_path, "FAIL", "structural", f"Icarus elaboration failed: {(p.stderr + p.stdout)[-600:]}")

        p = run_cmd([VVP, str(vvp_bin)], wdir, 90)
        out = p.stdout + "\n" + p.stderr
        if p.returncode != 0 or f"PASS seed={args.seed}" not in out or "FAIL" in out:
            return write_result(res_path, "FAIL", "functional", f"Icarus simulation failed (seed={args.seed}): {out[-700:]}")

        # 2. Verilator multi-parameter compilation & functional simulation
        vlt_dir = wdir / "obj_dir"
        p = run_cmd(
            [
                VERILATOR,
                "--binary",
                "--timing",
                "-Wno-fatal",
                "-j",
                "1",
                f"-GSEED={args.seed}",
                "--top-module",
                "tb",
                "--Mdir",
                str(vlt_dir),
                "-o",
                "Vtb",
                str(tb_local),
            ]
            + rtl_files,
            wdir,
            120,
        )
        if p.returncode != 0:
            return write_result(res_path, "FAIL", "structural", f"Verilator elaboration failed: {(p.stderr + p.stdout)[-600:]}")

        p = run_cmd([str(vlt_dir / "Vtb")], wdir, 90)
        out = p.stdout + "\n" + p.stderr
        if p.returncode != 0 or f"PASS seed={args.seed}" not in out or "FAIL" in out:
            return write_result(res_path, "FAIL", "functional", f"Verilator simulation failed (seed={args.seed}): {out[-700:]}")

        # 3. Yosys multi-parameter synthesis, latch/loop checks & gate-level netlist generation
        rtl_q = " ".join(rtl_files)
        gl_up = wdir / "gl_up.v"
        gl_dn = wdir / "gl_dn.v"

        ys_eq = (
            f"read_verilog {rtl_q}; "
            f"chparam -set S_DATA_WIDTH 64 -set M_DATA_WIDTH 64 -set FORWARD_ID 0 "
            f"-set AWUSER_WIDTH 4 -set WUSER_WIDTH 5 -set BUSER_WIDTH 3 -set ARUSER_WIDTH 4 -set RUSER_WIDTH 6 axi_adapter; "
            f"hierarchy -check -top axi_adapter; proc; flatten; opt; check -assert; "
            f"select -assert-none t:$dlatch* t:$_DLATCH* t:DLL_* t:DLH_*"
        )
        p = run_cmd([YOSYS, "-q", "-p", ys_eq], wdir, 60)
        if p.returncode != 0:
            return write_result(res_path, "FAIL", "synthesis", f"Yosys equal-width check failed: {(p.stderr + p.stdout)[-600:]}")

        ys_up = (
            f"read_verilog {rtl_q}; "
            f"chparam -set S_DATA_WIDTH 32 -set M_DATA_WIDTH 128 -set FORWARD_ID 1 "
            f"-set CONVERT_BURST 1 -set CONVERT_NARROW_BURST 1 "
            f"-set AWUSER_ENABLE 1 -set WUSER_ENABLE 1 -set BUSER_ENABLE 1 -set ARUSER_ENABLE 1 -set RUSER_ENABLE 1 "
            f"-set AWUSER_WIDTH 3 -set WUSER_WIDTH 4 -set BUSER_WIDTH 3 -set ARUSER_WIDTH 3 -set RUSER_WIDTH 4 axi_adapter; "
            f"hierarchy -check -top axi_adapter; proc; flatten; opt; check -assert; "
            f"select -assert-none t:$dlatch* t:$_DLATCH* t:DLL_* t:DLH_*; "
            f"fsm; opt; memory; opt; techmap; opt_clean; "
            f"rename -top axi_adapter_gl_up; write_verilog -noattr {gl_up}"
        )
        p = run_cmd([YOSYS, "-q", "-p", ys_up], wdir, 60)
        if p.returncode != 0:
            return write_result(res_path, "FAIL", "synthesis", f"Yosys upsize synthesis/latch check failed: {(p.stderr + p.stdout)[-600:]}")

        ys_dn = (
            f"read_verilog {rtl_q}; "
            f"chparam -set S_DATA_WIDTH 128 -set M_DATA_WIDTH 32 -set FORWARD_ID 1 "
            f"-set CONVERT_BURST 1 -set CONVERT_NARROW_BURST 1 "
            f"-set AWUSER_ENABLE 1 -set WUSER_ENABLE 1 -set BUSER_ENABLE 1 -set ARUSER_ENABLE 1 -set RUSER_ENABLE 1 "
            f"-set AWUSER_WIDTH 3 -set WUSER_WIDTH 4 -set BUSER_WIDTH 3 -set ARUSER_WIDTH 3 -set RUSER_WIDTH 4 axi_adapter; "
            f"hierarchy -check -top axi_adapter; proc; flatten; opt; check -assert; "
            f"select -assert-none t:$dlatch* t:$_DLATCH* t:DLL_* t:DLH_*; "
            f"fsm; opt; memory; opt; techmap; opt_clean; "
            f"rename -top axi_adapter_gl_dn; write_verilog -noattr {gl_dn}"
        )
        p = run_cmd([YOSYS, "-q", "-p", ys_dn], wdir, 60)
        if p.returncode != 0:
            return write_result(res_path, "FAIL", "synthesis", f"Yosys downsize synthesis/latch check failed: {(p.stderr + p.stdout)[-600:]}")

        # 4. Gate-level vs RTL cycle-accurate co-simulation
        vvp_gl = wdir / "sim_gl.vvp"
        p = run_cmd(
            [IVERILOG, "-g2012", "-P", f"tb_gl.SEED={args.seed}", "-o", str(vvp_gl), str(tb_gl_local), str(gl_up), str(gl_dn), SIMCELLS] + rtl_files,
            wdir,
            60,
        )
        if p.returncode != 0:
            return write_result(res_path, "FAIL", "synthesis", f"Gate-level co-sim compilation failed: {(p.stderr + p.stdout)[-600:]}")

        p = run_cmd([VVP, str(vvp_gl)], wdir, 90)
        out = p.stdout + "\n" + p.stderr
        if p.returncode != 0 or f"PASS_GL seed={args.seed}" not in out or "FAIL" in out:
            return write_result(res_path, "FAIL", "synthesis", f"Gate-level vs RTL parity failed (seed={args.seed}): {out[-700:]}")

    return write_result(
        res_path,
        "PASS",
        "functional",
        f"Dual-simulator (Icarus + Verilator) multi-parameter AXI4 width adaptation, Yosys latch-free synthesis, and gate-level parity passed for seed={args.seed}",
    )


if __name__ == "__main__":
    sys.exit(main())
