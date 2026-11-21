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
STA = f"{_sb_tools_dir()}/openroad-runtime/usr/bin/sta"
STA_LD = (
    f"{_sb_tools_dir()}/openroad-runtime/usr/lib/x86_64-linux-gnu:"
    f"{_sb_tools_dir()}/openroad-runtime/opt/or-tools/lib"
)

EDITABLE_RTL = {
    "code/tdma_scheduler.v": "tdma_scheduler",
    "code/tx_scheduler_ctrl_tdma.v": "tx_scheduler_ctrl_tdma",
    "code/tx_scheduler_rr.v": "tx_scheduler_rr",
}

READONLY_FILES = [
    "code/axis_fifo.v",
    "code/priority_encoder.v",
    "code/LICENSE",
    "pdk/NangateOpenCellLibrary_typical.lib",
]


def sha256_file(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def strip_comments(src: str) -> str:
    src = re.sub(r"/\*.*?\*/", "", src, flags=re.S)
    src = re.sub(r"//.*?$", "", src, flags=re.M)
    return src


def write_res(path: Path, verdict: str, stage: str, detail: str) -> int:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps({"verdict": verdict, "stage": stage, "detail": detail}, indent=2) + "\n")
    return 0 if verdict == "PASS" else 1


def run_cmd(cmd, cwd: Path, timeout_sec: int = 150, extra_env=None):
    env = dict(os.environ)
    env.pop("VERILATOR_ROOT", None)
    if extra_env:
        env.update(extra_env)
    return subprocess.run(cmd, cwd=str(cwd), env=env, capture_output=True, text=True, timeout=timeout_sec)


def check_policy(cand: Path, pub: Path):
    for rel in READONLY_FILES:
        cp = cand / rel
        pp = pub / rel
        if not cp.is_file() or sha256_file(cp) != sha256_file(pp):
            return ("policy", f"Read-only file missing or tampered: {rel}")

    for rel, mod in EDITABLE_RTL.items():
        cp = cand / rel
        if not cp.is_file():
            return ("structural", f"Missing editable RTL file: {rel}")
        clean = strip_comments(cp.read_text(errors="replace"))
        if re.search(r"\b(tb|tb_gl)\s*\.", clean):
            return ("policy", f"Policy violation in {rel}: hierarchical_harness_reference")
        if re.search(r"\$(stop|fatal|system|fopen|fdumpfile|dumpfile|readmemh|readmemb|writememh|writememb|display|write|strobe|monitor)\b", clean):
            return ("policy", f"Policy violation in {rel}: forbidden_systask")
        if re.search(r"`\s*ifn?def\s+(VERILATOR|__ICARUS__|SYNTHESIS|YOSYS)\b", clean):
            return ("policy", f"Policy violation in {rel}: tool_macro_divergence")
        if re.search(r"\bforce\b|\brelease\b", clean):
            return ("policy", f"Policy violation in {rel}: force_release_construct")
        if not re.search(rf"\bmodule\s+{mod}\b", clean):
            return ("structural", f"Missing required module {mod} in {rel}")
    return None


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--candidate", required=True)
    ap.add_argument("--result", required=True)
    ap.add_argument("--seed", type=int, default=101)
    args, _ = ap.parse_known_args()

    cand = Path(args.candidate).resolve()
    res_path = Path(args.result).resolve()
    task_dir = Path(__file__).resolve().parents[2]
    pub_dir = task_dir / "public"
    tb_sv = task_dir / "private" / "tests" / "tb.sv"
    tb_gl_sv = task_dir / "private" / "tests" / "tb_gl.sv"
    lib_p = pub_dir / "pdk" / "NangateOpenCellLibrary_typical.lib"

    pol = check_policy(cand, pub_dir)
    if pol:
        return write_res(res_path, "FAIL", pol[0], pol[1])

    rtl_files = [
        str(cand / "code/tdma_scheduler.v"),
        str(cand / "code/tx_scheduler_ctrl_tdma.v"),
        str(cand / "code/tx_scheduler_rr.v"),
        str(cand / "code/axis_fifo.v"),
        str(cand / "code/priority_encoder.v"),
    ]

    wdir = Path(tempfile.mkdtemp(prefix="case_21005_"))
    try:
        tb_loc = wdir / "tb.sv"
        tb_gl_loc = wdir / "tb_gl.sv"
        shutil.copy2(tb_sv, tb_loc)
        shutil.copy2(tb_gl_sv, tb_gl_loc)

        # 1. Icarus Verilog RTL Simulation
        vvp_bin = wdir / "sim_iv.vvp"
        p = run_cmd([IVERILOG, "-g2012", f"-Ptb.SEED={args.seed}", "-o", str(vvp_bin), str(tb_loc)] + rtl_files, wdir, 90)
        if p.returncode != 0:
            return write_res(res_path, "FAIL", "structural", f"Icarus compile failed:\n{(p.stdout + p.stderr)[-800:]}")
        p = run_cmd([VVP, str(vvp_bin)], wdir, 90)
        out = p.stdout + "\n" + p.stderr
        if p.returncode != 0 or f"PASS seed={args.seed}" not in out or "FAIL" in out:
            return write_res(res_path, "FAIL", "functional", f"Icarus simulation failed (seed={args.seed}):\n{out[-800:]}")

        # 2. Verilator RTL Simulation
        vdir = wdir / "obj_vlt"
        p = run_cmd(
            [
                VERILATOR, "--binary", "--timing", "--output-split", "0", "-Wno-fatal", "-Wno-ZEROREPL", "-j", "1",
                f"-GSEED={args.seed}", "--top-module", "tb", "--Mdir", str(vdir), "-o", "Vtb", str(tb_loc),
            ] + rtl_files,
            wdir,
            150,
        )
        if p.returncode != 0:
            return write_res(res_path, "FAIL", "structural", f"Verilator build failed:\n{(p.stdout + p.stderr)[-800:]}")
        p = run_cmd([str(vdir / "Vtb")], wdir, 90)
        out = p.stdout + "\n" + p.stderr
        if p.returncode != 0 or f"PASS seed={args.seed}" not in out or "FAIL" in out:
            return write_res(res_path, "FAIL", "functional", f"Verilator simulation failed (seed={args.seed}):\n{out[-800:]}")

        # 3. Yosys Zero-Latch + ASIC Initializer-Stripped Gate-Level Parity Check
        tdma_gl = wdir / "tdma_gl.v"
        ctrl_gl = wdir / "ctrl_gl.v"
        rr_gl = wdir / "rr_gl.v"

        gl_jobs = [
            (
                "tdma_scheduler",
                f"read_verilog {cand/'code/tdma_scheduler.v'}; "
                f"hierarchy -check -top tdma_scheduler -chparam INDEX_WIDTH 3 -chparam SCHEDULE_START_S 0 -chparam SCHEDULE_START_NS 400 "
                f"-chparam SCHEDULE_PERIOD_S 0 -chparam SCHEDULE_PERIOD_NS 1200 -chparam TIMESLOT_PERIOD_S 0 -chparam TIMESLOT_PERIOD_NS 600 "
                f"-chparam ACTIVE_PERIOD_S 0 -chparam ACTIVE_PERIOD_NS 300; "
                f"proc; setattr -unset init w:*; flatten; opt; check -assert; "
                f"select -assert-none t:$dlatch* t:$_DLATCH*; techmap; opt_clean; "
                f"rename -top tdma_scheduler_gl; write_verilog -noattr -simple-lhs {tdma_gl}",
            ),
            (
                "tx_scheduler_ctrl_tdma",
                f"read_verilog {cand/'code/tx_scheduler_ctrl_tdma.v'}; "
                f"hierarchy -check -top tx_scheduler_ctrl_tdma -chparam AXIL_DATA_WIDTH 32 -chparam AXIL_ADDR_WIDTH 16 "
                f"-chparam TDMA_INDEX_WIDTH 3 -chparam QUEUE_INDEX_WIDTH 3 -chparam PIPELINE 3; "
                f"proc; setattr -unset init w:*; flatten; opt; memory -nomap; opt; "
                f"select -assert-none t:$dlatch* t:$_DLATCH*; techmap; opt_clean; "
                f"rename -top tx_scheduler_ctrl_tdma_gl; write_verilog -noattr -simple-lhs {ctrl_gl}",
            ),
            (
                "tx_scheduler_rr",
                f"read_verilog {cand/'code/tx_scheduler_rr.v'} {cand/'code/axis_fifo.v'} {cand/'code/priority_encoder.v'}; "
                f"hierarchy -check -top tx_scheduler_rr -chparam AXIL_DATA_WIDTH 32 -chparam AXIL_ADDR_WIDTH 16 "
                f"-chparam LEN_WIDTH 16 -chparam REQ_TAG_WIDTH 8 -chparam OP_TABLE_SIZE 8 -chparam QUEUE_INDEX_WIDTH 3 "
                f"-chparam PIPELINE 3 -chparam SCHED_CTRL_ENABLE 1; "
                f"proc; setattr -unset init w:*; flatten; opt; memory -nomap; opt; "
                f"select -assert-none t:$dlatch* t:$_DLATCH*; techmap; opt_clean; "
                f"rename -top tx_scheduler_rr_gl; write_verilog -noattr -simple-lhs {rr_gl}",
            ),
        ]
        for mod_name, ys_cmd in gl_jobs:
            p = run_cmd([YOSYS, "-q", "-p", ys_cmd], wdir, 120)
            if p.returncode != 0:
                return write_res(res_path, "FAIL", "synthesis", f"Yosys ASIC synthesis/latch check failed on {mod_name}:\n{(p.stdout + p.stderr)[-700:]}")

        gl_vvp = wdir / "sim_gl.vvp"
        p = run_cmd(
            [IVERILOG, "-g2012", "-o", str(gl_vvp), str(tb_gl_loc), str(tdma_gl), str(ctrl_gl), str(rr_gl), SIMCELLS] + rtl_files,
            wdir,
            90,
        )
        if p.returncode != 0:
            return write_res(res_path, "FAIL", "synthesis", f"Gate-level compilation failed:\n{(p.stdout + p.stderr)[-700:]}")
        p = run_cmd([VVP, str(gl_vvp)], wdir, 90)
        out = p.stdout + "\n" + p.stderr
        if p.returncode != 0 or "PASS_GL" not in out or "FAIL" in out:
            return write_res(res_path, "FAIL", "synthesis", f"ASIC gate-level Zero-X / parity simulation failed:\n{out[-800:]}")

        # 4. Nangate45 Area & 2.00 ns OpenSTA Timing Closure on tdma_scheduler (INDEX_WIDTH = 8)
        sta_net = wdir / "tdma_sta.v"
        ys_sta = (
            f"read_verilog {cand/'code/tdma_scheduler.v'}; "
            f"hierarchy -check -top tdma_scheduler -chparam INDEX_WIDTH 8; "
            f"synth -top tdma_scheduler -flatten; "
            f"dfflibmap -liberty {lib_p}; "
            f"abc -liberty {lib_p}; "
            f"opt_clean -purge; "
            f"stat -liberty {lib_p}; "
            f"write_verilog -noattr -simple-lhs {sta_net}"
        )
        p = run_cmd([YOSYS, "-p", ys_sta], wdir, 120)
        if p.returncode != 0:
            return write_res(res_path, "FAIL", "synthesis", f"Yosys Nangate45 mapping failed on tdma_scheduler:\n{(p.stdout + p.stderr)[-800:]}")

        m_area = re.findall(r"Chip area for module [`'\\]*\S+:\s*([0-9.]+)", p.stdout)
        if not m_area:
            return write_res(res_path, "FAIL", "synthesis", f"Could not parse Yosys area:\n{p.stdout[-600:]}")
        area = float(m_area[-1])
        if area > 10000.0:
            return write_res(res_path, "FAIL", "area", f"tdma_scheduler area {area:.2f} um^2 exceeds 10000.00 um^2 limit")

        sta_tcl = wdir / "sta.tcl"
        sta_tcl.write_text(
            f"read_liberty {lib_p}\n"
            f"read_verilog {sta_net}\n"
            f"link_design tdma_scheduler\n"
            f"create_clock -name clk -period 2.00 [get_ports clk]\n"
            f"set_false_path -from [get_ports rst]\n"
            f"foreach p [get_ports *] {{\n"
            f"    set n [get_name $p]\n"
            f"    if {{$n != \"clk\" && $n != \"rst\"}} {{\n"
            f"        if {{[get_property $p direction] == \"input\"}} {{ set_input_delay 0.10 -clock clk $p }} else {{ set_output_delay 0.10 -clock clk $p }}\n"
            f"    }}\n"
            f"}}\n"
            f"puts \"STA_WNS=[sta::worst_slack_cmd max]\"\n"
            f"puts \"STA_TNS=[sta::total_negative_slack_cmd max]\"\n"
            f"puts \"STA_HOLD=[sta::worst_slack_cmd min]\"\n"
            f"report_checks -path_delay min_max\n"
        )
        p_sta = run_cmd([STA, "-no_init", "-exit", str(sta_tcl)], wdir, 90, extra_env={"LD_LIBRARY_PATH": STA_LD})
        out_sta = p_sta.stdout + p_sta.stderr
        if p_sta.returncode != 0 or "Error:" in out_sta:
            return write_res(res_path, "FAIL", "timing", f"OpenSTA failed:\n{out_sta[-800:]}")

        m_w = re.search(r"STA_WNS=([-+0-9.eE]+)", out_sta)
        m_t = re.search(r"STA_TNS=([-+0-9.eE]+)", out_sta)
        m_h = re.search(r"STA_HOLD=([-+0-9.eE]+)", out_sta)
        if not (m_w and m_t and m_h):
            return write_res(res_path, "FAIL", "timing", f"OpenSTA slack parse failed:\n{out_sta[-700:]}")

        wns_ns = float(m_w.group(1)) * 1e9
        tns_ns = float(m_t.group(1)) * 1e9
        hold_ns = float(m_h.group(1)) * 1e9
        if wns_ns < -1e-4 or tns_ns < -1e-4 or hold_ns < -1e-4:
            return write_res(
                res_path,
                "FAIL",
                "timing",
                f"tdma_scheduler failed 2.00 ns OpenSTA signoff (WNS={wns_ns:.3f} ns, TNS={tns_ns:.3f} ns, hold={hold_ns:.3f} ns, area={area:.1f} um^2)",
            )

        return write_res(
            res_path,
            "PASS",
            "functional",
            f"All RTL, GL Zero-X, and Nangate45 2.00ns signoff checks passed (WNS={wns_ns:.3f}ns, hold={hold_ns:.3f}ns, area={area:.1f}um^2)",
        )
    except subprocess.TimeoutExpired as exc:
        return write_res(res_path, "FAIL", "functional", f"Simulation or synthesis timed out: {exc}")
    finally:
        shutil.rmtree(wdir, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
