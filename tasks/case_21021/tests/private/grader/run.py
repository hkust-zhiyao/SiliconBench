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


TASK_DIR  = Path(__file__).resolve().parents[2]
PUB_DIR   = TASK_DIR / "public"
TESTS_DIR = TASK_DIR / "private" / "tests"

IVERILOG  = f"{_sb_tools_dir()}/iverilog-v13/bin/iverilog"
VVP       = f"{_sb_tools_dir()}/iverilog-v13/bin/vvp"
VERILATOR = f"{_sb_tools_dir()}/verilator-v5.038/bin/verilator"
YOSYS     = f"{_sb_tools_dir()}/oss-cad-suite/bin/yosys"
SIMCELLS  = f"{_sb_tools_dir()}/oss-cad-suite/share/yosys/simcells.v"

EDITABLE_FILES = [
    "code/axi_vfifo_enc.v",
    "code/axi_vfifo_dec.v",
    "code/axi_vfifo_raw_wr.v",
    "code/axi_vfifo_raw_rd.v",
    "code/axi_vfifo_raw.v",
    "code/axi_vfifo.v",
]
READONLY_FILES = [
    "code/COPYING",
]


def sha256_file(p: Path) -> str:
    return hashlib.sha256(p.read_bytes()).hexdigest()


def strip_comments_and_strings(src: str) -> str:
    out = []
    i, n = 0, len(src)
    while i < n:
        if i + 1 < n and src[i:i + 2] == "//":
            i += 2
            while i < n and src[i] != "\n":
                i += 1
        elif i + 1 < n and src[i:i + 2] == "/*":
            i += 2
            while i + 1 < n and src[i:i + 2] != "*/":
                i += 1
            i += 2
        elif src[i] == '"':
            i += 1
            while i < n and src[i] != '"':
                if src[i] == "\\" and i + 1 < n:
                    i += 2
                else:
                    i += 1
            i += 1
        else:
            out.append(src[i])
            i += 1
    return "".join(out)


def strip_initial_blocks(clean: str) -> str:
    res = clean
    while True:
        m = re.search(r"\binitial\s+begin\b", res)
        if not m:
            break
        pos = m.end()
        depth = 1
        while pos < len(res) and depth > 0:
            tok = re.search(r"\b(begin|end)\b", res[pos:])
            if not tok:
                pos = len(res)
                break
            if tok.group(1) == "begin":
                depth += 1
            else:
                depth -= 1
            pos += tok.end()
        res = res[:m.start()] + " " + res[pos:]
    return res


def write_res(path: Path, verdict: str, stage: str, detail: str) -> int:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps({"verdict": verdict, "stage": stage, "detail": detail}, indent=2) + "\n")
    return 0 if verdict == "PASS" else 1


def check_policy(cand: Path):
    for rel in READONLY_FILES:
        cp = cand / rel
        pp = PUB_DIR / rel
        if not cp.is_file() or sha256_file(cp) != sha256_file(pp):
            return ("policy", f"Read-only file missing or tampered: {rel}")

    for rel in EDITABLE_FILES:
        cp = cand / rel
        if not cp.is_file():
            return ("structural", f"Missing editable RTL file: {rel}")
        clean = strip_comments_and_strings(cp.read_text(errors="replace"))
        if re.search(r"\$(?:fatal|stop|system|fopen|fwrite|fdisplay|fscanf|readmemh|readmemb|writememh|writememb)\b", clean):
            return ("policy", f"Policy violation in {rel}: forbidden_systask")
        non_init = strip_initial_blocks(clean)
        if re.search(r"\$finish\b", non_init):
            return ("policy", f"Policy violation in {rel}: runtime_finish_systask")
        if re.search(r"`\s*ifdef\s+(?:SYNTHESIS|VERILATOR|__ICARUS__)\b", clean) or re.search(
            r"`\s*ifndef\s+(?:SYNTHESIS|VERILATOR|__ICARUS__)\b", clean
        ):
            return ("policy", f"Policy violation in {rel}: conditional_sim_synth_divergence")
        if re.search(r"\b(?:tb|tb_gl|\$root)\s*\.", clean) or re.search(r"\bforce\b|\brelease\b", clean):
            return ("policy", f"Policy violation in {rel}: hierarchical_or_force_hack")
    return None


def run_cmd(cmd, cwd: Path, timeout_sec: int = 180):
    env = dict(os.environ)
    env.pop("VERILATOR_ROOT", None)
    try:
        return subprocess.run(cmd, cwd=str(cwd), env=env, text=True, capture_output=True, timeout=timeout_sec)
    except subprocess.TimeoutExpired as exc:
        out = exc.stdout if isinstance(exc.stdout, str) else (exc.stdout.decode("utf-8", "replace") if exc.stdout else "")
        err = exc.stderr if isinstance(exc.stderr, str) else (exc.stderr.decode("utf-8", "replace") if exc.stderr else "")
        return subprocess.CompletedProcess(cmd, 124, out, err + f"\nTIMEOUT after {timeout_sec}s")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--candidate", required=True)
    ap.add_argument("--result", required=True)
    ap.add_argument("--seed", type=int, default=101)
    args, _ = ap.parse_known_args()

    cand = Path(args.candidate).resolve()
    res_path = Path(args.result).resolve()

    pol = check_policy(cand)
    if pol is not None:
        return write_res(res_path, "FAIL", pol[0], pol[1])

    rtl_files = [cand / rel for rel in EDITABLE_FILES]
    tb_sv = TESTS_DIR / "tb.sv"
    tb_gl_sv = TESTS_DIR / "tb_gl.sv"

    work = Path(tempfile.mkdtemp(prefix="grade_21021_"))
    try:
        # 1. Icarus Verilog 4-State RTL Simulation
        vvp_bin = work / "sim_iv.vvp"
        p = run_cmd(
            [IVERILOG, "-g2012", f"-Ptb.SEED={args.seed}", "-o", str(vvp_bin), str(tb_sv)] + [str(f) for f in rtl_files],
            work,
        )
        if p.returncode != 0:
            return write_res(res_path, "FAIL", "structural", f"Icarus compile failed:\n{(p.stdout + p.stderr)[-900:]}")
        p = run_cmd([VVP, str(vvp_bin)], work, timeout_sec=90)
        if p.returncode != 0 or f"PASS seed={args.seed}" not in p.stdout or "FAIL" in p.stdout:
            return write_res(res_path, "FAIL", "functional", f"Icarus RTL simulation failed:\n{(p.stdout + p.stderr)[-900:]}")

        # 2. Verilator Simulation
        vdir = work / "obj_verilator"
        p = run_cmd(
            [
                VERILATOR,
                "--binary",
                "--timing",
                "--output-split",
                "0",
                "-Wno-fatal",
                "-Wno-ZEROREPL",
                "-j",
                "1",
                f"-GSEED={args.seed}",
                "--top-module",
                "tb",
                "--Mdir",
                str(vdir),
                "-o",
                "Vtb",
                str(tb_sv),
            ]
            + [str(f) for f in rtl_files],
            work,
            timeout_sec=240,
        )
        if p.returncode != 0:
            return write_res(res_path, "FAIL", "structural", f"Verilator build failed:\n{(p.stdout + p.stderr)[-900:]}")
        p = run_cmd([str(vdir / "Vtb")], work, timeout_sec=90)
        if p.returncode != 0 or f"PASS seed={args.seed}" not in p.stdout or "FAIL" in p.stdout:
            return write_res(res_path, "FAIL", "functional", f"Verilator simulation failed:\n{(p.stdout + p.stderr)[-900:]}")

        # 3. Yosys Multi-Config Synthesis + Initializer-Stripped Gate-Level Zero-X Sim
        ys_dir = work / "ys_src"
        ys_dir.mkdir(parents=True, exist_ok=True)
        ys_files = []
        for idx, f in enumerate(rtl_files):
            dst = ys_dir / f"{idx:02d}_{f.name}"
            dst.write_text(re.sub(r"\$error\s*\(", "$display(", f.read_text(errors="replace")))
            ys_files.append(dst)

        ys_chk = (
            f"read_verilog -defer -sv {' '.join(str(f) for f in ys_files)}; "
            f"hierarchy -check -top axi_vfifo -chparam AXI_CH 2 -chparam AXI_DATA_WIDTH 64 -chparam AXI_STRB_WIDTH 8 "
            f"-chparam AXI_ADDR_WIDTH 10 -chparam LEN_WIDTH 10 -chparam AXIS_DATA_WIDTH 64 -chparam AXIS_KEEP_WIDTH 8 "
            f"-chparam MAX_SEG_WIDTH 32 -chparam WRITE_FIFO_DEPTH 16 -chparam WRITE_MAX_BURST_LEN 4 "
            f"-chparam READ_FIFO_DEPTH 32 -chparam READ_MAX_BURST_LEN 4; "
            f"proc; opt_expr; opt_clean; flatten; opt_expr; opt_clean; "
            f"select -assert-none t:$dlatch* t:$_DLATCH*; memory -nomap; opt_clean; check -assert"
        )
        p = run_cmd([YOSYS, "-q", "-p", ys_chk], work, timeout_sec=120)
        if p.returncode != 0:
            return write_res(res_path, "FAIL", "synthesis", f"Yosys 2-channel multi-segment check failed:\n{(p.stdout + p.stderr)[-900:]}")

        gl_net = work / "dut_gl.v"
        ys_gl = (
            f"read_verilog -defer -sv {' '.join(str(f) for f in ys_files)}; "
            f"hierarchy -check -top axi_vfifo -chparam AXI_CH 1 -chparam AXI_DATA_WIDTH 64 -chparam AXI_STRB_WIDTH 8 "
            f"-chparam AXI_ADDR_WIDTH 9 -chparam LEN_WIDTH 9 -chparam AXIS_DATA_WIDTH 32 -chparam AXIS_KEEP_WIDTH 4 "
            f"-chparam AXIS_ID_ENABLE 1 -chparam AXIS_ID_WIDTH 3 -chparam AXIS_DEST_ENABLE 1 -chparam AXIS_DEST_WIDTH 3 "
            f"-chparam AXIS_USER_ENABLE 1 -chparam AXIS_USER_WIDTH 2 -chparam MAX_SEG_WIDTH 32 "
            f"-chparam WRITE_FIFO_DEPTH 16 -chparam WRITE_MAX_BURST_LEN 4 "
            f"-chparam READ_FIFO_DEPTH 16 -chparam READ_MAX_BURST_LEN 4; "
            f"proc; opt_expr; opt_clean; setattr -unset init w:*; flatten; opt_expr; opt_clean; "
            f"select -assert-none t:$dlatch* t:$_DLATCH*; "
            f"synth -top axi_vfifo; "
            f"check -assert; select -assert-none t:$dlatch* t:$_DLATCH*; "
            f"rename axi_vfifo axi_vfifo_gl; "
            f"write_verilog -noattr {gl_net}"
        )
        p = run_cmd([YOSYS, "-q", "-p", ys_gl], work, timeout_sec=180)
        if p.returncode != 0:
            return write_res(res_path, "FAIL", "synthesis", f"Yosys gate-level synthesis/loop/latch check failed:\n{(p.stdout + p.stderr)[-900:]}")

        gl_vvp = work / "sim_gl.vvp"
        p = run_cmd([IVERILOG, "-g2012", "-o", str(gl_vvp), str(tb_gl_sv), str(gl_net), SIMCELLS], work)
        if p.returncode != 0:
            return write_res(res_path, "FAIL", "synthesis", f"Gate-level compile failed:\n{(p.stdout + p.stderr)[-900:]}")
        p = run_cmd([VVP, str(gl_vvp)], work, timeout_sec=90)
        if p.returncode != 0 or "PASS_GL" not in p.stdout or "FAIL" in p.stdout:
            return write_res(res_path, "FAIL", "functional", f"Gate-level Zero-X parity simulation failed:\n{(p.stdout + p.stderr)[-900:]}")

        return write_res(
            res_path,
            "PASS",
            "all",
            f"All Icarus, Verilator, Yosys multi-config latch/loop, and Gate-Level Zero-X checks passed (seed={args.seed})",
        )
    finally:
        shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
