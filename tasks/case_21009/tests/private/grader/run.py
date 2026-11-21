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


TASK_DIR = Path(__file__).resolve().parents[2]
TESTS_DIR = TASK_DIR / "private" / "tests"

IVERILOG = f"{_sb_tools_dir()}/iverilog-v13/bin/iverilog"
VVP = f"{_sb_tools_dir()}/iverilog-v13/bin/vvp"
VERILATOR = f"{_sb_tools_dir()}/verilator-v5.038/bin/verilator"
YOSYS = f"{_sb_tools_dir()}/oss-cad-suite/bin/yosys"
YOSYS_SIMLIB = f"{_sb_tools_dir()}/oss-cad-suite/share/yosys/simlib.v"
STA = f"{_sb_tools_dir()}/openroad-runtime/usr/bin/sta"
STA_LD = (
    f"{_sb_tools_dir()}/openroad-runtime/usr/lib/x86_64-linux-gnu:"
    f"{_sb_tools_dir()}/openroad-runtime/opt/or-tools/lib"
)

READONLY_SHA256 = {
    "code/axis_fifo.v": "7d1ea178349654c92f2ac4823620004abe067b37f9fbd09fcff97fe00db6e19c",
    "code/LICENSE": "e718ce52d815d36c0576b9f759001200731db9b16775286ffc1b66bbf97eb1b6",
    "pdk/NangateOpenCellLibrary_typical.lib": "8d540a4d4cf6d09d27c87ad067857a9c0c2eeb023ab7a56e058cd3113db4e9b1",
}

EDITABLE_RTL = ["code/tx_checksum.v", "code/rx_checksum.v"]

FORBIDDEN_RTL_RE = re.compile(
    r"(\$(?:fatal|stop|system|readmemh|readmemb|writememh|writememb|fopen)\b|\b(?:tb|tb_gl)\.)"
)


def sha256_file(p: Path) -> str:
    return hashlib.sha256(p.read_bytes()).hexdigest()


def write_res(path: Path, verdict: str, stage: str, detail: str):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps({"verdict": verdict, "stage": stage, "detail": detail}, indent=2) + "\n")


def run_cmd(cmd, cwd: Path, timeout: int = 180, extra_env=None):
    env = os.environ.copy()
    env.pop("VERILATOR_ROOT", None)
    if extra_env:
        env.update(extra_env)
    return subprocess.run(cmd, cwd=str(cwd), env=env, capture_output=True, text=True, timeout=timeout)


def strip_comments(txt: str) -> str:
    txt = re.sub(r"/\*.*?\*/", "", txt, flags=re.S)
    txt = re.sub(r"//.*", "", txt)
    return txt


def synth_and_sta(
    work: Path,
    cand: Path,
    lib_p: Path,
    top: str,
    rtl_files: list,
    chparams: dict,
    clk_period_ns: float,
    max_area: float,
):
    net_v = work / f"{top}_net.v"
    chp_str = " ".join(f"-chparam {k} {v}" for k, v in chparams.items())
    rtl_str = " ".join(str(f) for f in rtl_files)
    ys = (
        f"read_verilog {rtl_str}; "
        f"hierarchy -check -top {top} {chp_str}; "
        f"synth -flatten -top {top}; "
        f"dfflibmap -liberty {lib_p}; "
        f"abc -liberty {lib_p}; "
        f"opt_clean -purge; "
        f"stat -liberty {lib_p}; "
        f"write_verilog -noattr -simple-lhs {net_v}"
    )
    p = run_cmd([YOSYS, "-p", ys], work, timeout=180)
    if p.returncode != 0:
        return False, "synthesis", f"Yosys Nangate45 synthesis failed on {top}:\n{(p.stdout + p.stderr)[-900:]}"

    m_area = re.findall(r"Chip area for module [`'\\]*\S+:\s*([0-9.]+)", p.stdout)
    if not m_area:
        return False, "synthesis", f"Could not parse Yosys area on {top}:\n{p.stdout[-600:]}"
    area = float(m_area[-1])
    if area > max_area:
        return False, "area", f"{top} cell area {area:.2f} um^2 exceeds limit {max_area:.2f} um^2"

    sta_tcl = work / f"{top}_sta.tcl"
    sta_tcl.write_text(
        f"read_liberty {lib_p}\n"
        f"read_verilog {net_v}\n"
        f"link_design {top}\n"
        f"create_clock -name clk -period {clk_period_ns:.2f} [get_ports clk]\n"
        f"set_false_path -from [get_ports rst]\n"
        f"foreach p [get_ports *] {{\n"
        f"    set n [get_name $p]\n"
        f"    if {{$n != \"clk\" && $n != \"rst\"}} {{\n"
        f"        if {{[get_property $p direction] == \"input\"}} {{ set_input_delay 0.10 -clock clk $p }} else {{ set_output_delay 0.10 -clock clk $p }}\n"
        f"    }}\n"
        f"}}\n"
        f"puts \"STA_SETUP_SLACK=[sta::worst_slack_cmd max]\"\n"
        f"puts \"STA_HOLD_SLACK=[sta::worst_slack_cmd min]\"\n"
        f"puts \"STA_TNS=[sta::total_negative_slack_cmd max]\"\n"
        f"report_checks -path_delay min_max\n"
    )
    p_sta = run_cmd([STA, "-no_init", "-exit", str(sta_tcl)], work, timeout=120, extra_env={"LD_LIBRARY_PATH": STA_LD})
    out = p_sta.stdout + p_sta.stderr
    if p_sta.returncode != 0 or "Error:" in out:
        return False, "timing", f"OpenSTA failed on {top}:\n{out[-900:]}"

    m_s = re.search(r"STA_SETUP_SLACK=([-+0-9.eE]+)", out)
    m_h = re.search(r"STA_HOLD_SLACK=([-+0-9.eE]+)", out)
    m_t = re.search(r"STA_TNS=([-+0-9.eE]+)", out)
    if not (m_s and m_h and m_t):
        return False, "timing", f"OpenSTA slack parse failed on {top}:\n{out[-800:]}"

    wns_ns = float(m_s.group(1)) * 1e9
    hold_ns = float(m_h.group(1)) * 1e9
    tns_ns = float(m_t.group(1)) * 1e9
    if wns_ns < -1e-4 or tns_ns < -1e-4 or hold_ns < -1e-4:
        return (
            False,
            "timing",
            f"{top} failed {clk_period_ns:.2f}ns OpenSTA signoff (WNS={wns_ns:.3f}ns, TNS={tns_ns:.3f}ns, hold={hold_ns:.3f}ns, area={area:.1f}um^2)",
        )
    return True, "ok", f"{top}@{clk_period_ns:.2f}ns(WNS={wns_ns:.3f}ns,hold={hold_ns:.3f}ns,area={area:.1f}um^2)"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--candidate", required=True)
    ap.add_argument("--seed", type=int, default=101)
    ap.add_argument("--result", required=True)
    args = ap.parse_args()

    cand = Path(args.candidate).resolve()
    res_path = Path(args.result).resolve()

    # 1. Policy & Read-Only Integrity Check
    for rel, exp_sha in READONLY_SHA256.items():
        fp = cand / rel
        if not fp.is_file() or sha256_file(fp) != exp_sha:
            write_res(res_path, "FAIL", "policy", f"Read-only file missing or modified: {rel}")
            sys.exit(1)

    for rel in EDITABLE_RTL:
        fp = cand / rel
        if not fp.is_file():
            write_res(res_path, "FAIL", "policy", f"Editable file missing: {rel}")
            sys.exit(1)
        clean = strip_comments(fp.read_text(errors="replace"))
        m = FORBIDDEN_RTL_RE.search(clean)
        if m:
            write_res(res_path, "FAIL", "policy", f"Forbidden construct '{m.group(1)}' in {rel}")
            sys.exit(1)

    rtl_files = [cand / "code/tx_checksum.v", cand / "code/rx_checksum.v", cand / "code/axis_fifo.v"]
    tb_sv = TESTS_DIR / "tb.sv"
    tb_gl_sv = TESTS_DIR / "tb_gl.sv"
    lib_p = cand / "pdk/NangateOpenCellLibrary_typical.lib"

    work = Path(tempfile.mkdtemp(prefix="grade_21009_"))
    try:
        # 2. Step 1: Icarus Verilog RTL Simulation
        vvp_bin = work / "sim_iv.vvp"
        p = run_cmd([IVERILOG, "-g2012", f"-Ptb.SEED={args.seed}", "-o", str(vvp_bin), str(tb_sv)] + [str(f) for f in rtl_files], work)
        if p.returncode != 0:
            write_res(res_path, "FAIL", "structural", f"Icarus compile failed:\n{(p.stdout + p.stderr)[-900:]}")
            sys.exit(1)
        p = run_cmd([VVP, str(vvp_bin)], work)
        if p.returncode != 0 or f"PASS seed={args.seed}" not in p.stdout or "FAIL" in p.stdout:
            write_res(res_path, "FAIL", "functional", f"Icarus RTL simulation failed:\n{(p.stdout + p.stderr)[-900:]}")
            sys.exit(1)

        # 3. Step 2: Verilator RTL Simulation
        vdir = work / "obj_verilator"
        p = run_cmd(
            [
                VERILATOR,
                "--binary",
                "--timing",
                "--output-split",
                "0",
                "-Wno-fatal",
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
        )
        if p.returncode != 0:
            write_res(res_path, "FAIL", "structural", f"Verilator build failed:\n{(p.stdout + p.stderr)[-900:]}")
            sys.exit(1)
        p = run_cmd([str(vdir / "Vtb")], work)
        if p.returncode != 0 or f"PASS seed={args.seed}" not in p.stdout or "FAIL" in p.stdout:
            write_res(res_path, "FAIL", "functional", f"Verilator RTL simulation failed:\n{(p.stdout + p.stderr)[-900:]}")
            sys.exit(1)

        # 4. Step 3: Yosys Zero-Latch Check + ASIC Initializer-Stripped Gate-Level Parity
        tx_gl = work / "tx_gl.v"
        rx_gl = work / "rx_gl.v"
        ys_tx_gl = (
            f"read_verilog {cand/'code/tx_checksum.v'} {cand/'code/axis_fifo.v'}; "
            f"hierarchy -check -top tx_checksum -chparam DATA_WIDTH 64 -chparam KEEP_WIDTH 8 -chparam USE_INIT_VALUE 1 -chparam DATA_FIFO_DEPTH 64 -chparam CHECKSUM_FIFO_DEPTH 4; "
            f"proc; setattr -unset init w:*; flatten; opt; memory -nomap; opt; techmap; opt; "
            f"select -assert-none t:$dlatch*; "
            f"rename tx_checksum tx_checksum_gl; "
            f"write_verilog -noattr -simple-lhs {tx_gl}"
        )
        ys_rx_gl = (
            f"read_verilog {cand/'code/rx_checksum.v'}; "
            f"hierarchy -check -top rx_checksum -chparam DATA_WIDTH 64 -chparam KEEP_WIDTH 8 -chparam START_OFFSET 16; "
            f"proc; setattr -unset init w:*; flatten; opt; techmap; opt; "
            f"select -assert-none t:$dlatch*; "
            f"rename rx_checksum rx_checksum_gl; "
            f"write_verilog -noattr -simple-lhs {rx_gl}"
        )
        for name, script in [("tx_checksum", ys_tx_gl), ("rx_checksum", ys_rx_gl)]:
            p = run_cmd([YOSYS, "-p", script], work)
            if p.returncode != 0:
                write_res(res_path, "FAIL", "structural", f"Yosys structural/latch check failed on {name}:\n{(p.stdout + p.stderr)[-900:]}")
                sys.exit(1)

        gl_vvp = work / "sim_gl.vvp"
        p = run_cmd(
            [IVERILOG, "-g2012", "-o", str(gl_vvp), str(tb_gl_sv), str(tx_gl), str(rx_gl), str(YOSYS_SIMLIB)] + [str(f) for f in rtl_files],
            work,
        )
        if p.returncode != 0:
            write_res(res_path, "FAIL", "structural", f"Gate-level compile failed:\n{(p.stdout + p.stderr)[-900:]}")
            sys.exit(1)
        p = run_cmd([VVP, str(gl_vvp)], work)
        if p.returncode != 0 or "PASS_GL" not in p.stdout or "FAIL" in p.stdout:
            write_res(res_path, "FAIL", "structural", f"ASIC gate-level Zero-X / parity check failed:\n{(p.stdout + p.stderr)[-900:]}")
            sys.exit(1)

        # 5. Step 4: Nangate45 Area & OpenSTA Signoff on rx_checksum (1.24ns) and tx_checksum (1.46ns)
        ok_rx, stg_rx, msg_rx = synth_and_sta(
            work,
            cand,
            lib_p,
            "rx_checksum",
            [cand / "code/rx_checksum.v"],
            {"DATA_WIDTH": 64, "START_OFFSET": 14},
            clk_period_ns=1.24,
            max_area=1750.0,
        )
        if not ok_rx:
            write_res(res_path, "FAIL", stg_rx, msg_rx)
            sys.exit(1)

        ok_tx, stg_tx, msg_tx = synth_and_sta(
            work,
            cand,
            lib_p,
            "tx_checksum",
            [cand / "code/tx_checksum.v", cand / "code/axis_fifo.v"],
            {"DATA_WIDTH": 64, "USE_INIT_VALUE": 1, "DATA_FIFO_DEPTH": 8, "CHECKSUM_FIFO_DEPTH": 4},
            clk_period_ns=1.46,
            max_area=7200.0,
        )
        if not ok_tx:
            write_res(res_path, "FAIL", stg_tx, msg_tx)
            sys.exit(1)

        write_res(res_path, "PASS", "functional", f"All RTL, GL Zero-X, and Nangate45 PPA checks passed: {msg_rx}; {msg_tx}")
    except subprocess.TimeoutExpired as exc:
        write_res(res_path, "FAIL", "functional", f"Subprocess timed out: {exc}")
        sys.exit(1)
    finally:
        shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    main()
