#!/usr/bin/env python3
"""Private isolated grader for case_20006 (pulp-platform/axi_llc S2 Synthesis/Simulation Parity)."""
import argparse
import hashlib
import json
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
PRIV_DIR = TASK_DIR / "private"
PUB_DIR = TASK_DIR / "public"
TOOLS_DIR = pathlib.Path(str(_sb_tools_dir()))
VERILATOR = TOOLS_DIR / "verilator-v5.038" / "bin" / "verilator"
YOSYS = TOOLS_DIR / "oss-cad-suite" / "bin" / "yosys"
SIMCELLS = TOOLS_DIR / "oss-cad-suite" / "share" / "yosys" / "simcells.v"

EDITABLE_FILES = [
    pathlib.Path("code/rtl/axi_llc_miss_counters.sv"),
    pathlib.Path("code/rtl/axi_llc_tag_pattern_gen.sv"),
    pathlib.Path("code/rtl/axi_llc_hit_miss.sv"),
]

EXPECTED_MODULES = {
    "code/rtl/axi_llc_miss_counters.sv": "axi_llc_miss_counters",
    "code/rtl/axi_llc_tag_pattern_gen.sv": "axi_llc_tag_pattern_gen",
    "code/rtl/axi_llc_hit_miss.sv": "axi_llc_hit_miss",
}


def finish(result_path: pathlib.Path, verdict: str, stage: str, detail: str):
    payload = {"verdict": verdict, "stage": stage, "detail": detail}
    result_path.parent.mkdir(parents=True, exist_ok=True)
    result_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(payload))
    raise SystemExit(0 if verdict == "PASS" else 2 if verdict == "ERROR" else 1)


def sha256_bytes(p: pathlib.Path) -> str:
    return hashlib.sha256(p.read_bytes()).hexdigest()


def strip_comments_and_strings(text: str) -> str:
    text = re.sub(r'(?is)//\s*pragma\s+translate_off.*?//\s*pragma\s+translate_on', '', text)
    text = re.sub(r'/\*.*?\*/|//[^\n]*|"(?:\\.|[^"\\])*"', ' ', text, flags=re.S)
    return text


def screen_candidate_source(rel_str: str, cand_text: str, base_text: str, result_path: pathlib.Path):
    if len(cand_text.encode("utf-8")) > 250_000:
        finish(result_path, "FAIL", "policy", f"{rel_str} exceeds size limit")

    cand_clean = strip_comments_and_strings(cand_text)
    base_clean = strip_comments_and_strings(base_text)

    escape_pats = [
        (r'\$(?:fopen|fclose|fread|fwrite|fdisplay|fscanf|system|finish|stop|readmemh|readmemb|writememh|writememb|dumpfile|dumpvars|value\$plusargs|test\$plusargs)\b', "forbidden_systask"),
        (r'\b(?:force|release|bind|defparam)\b', "procedural_force_or_bind"),
        (r'\b(?:import|export)\s*"DPI', "dpi_escape"),
        (r'\$root\b|\b(?:tb|u_rtl_wrap|u_gl_wrap|u_bist_dut|grader|oracle)\s*\.', "hierarchical_harness_reference"),
        (r'`\s*(?:ifdef|ifndef|elsif)\s+(?:VERILATOR|SYNTHESIS|SIMULATION|__ICARUS__|VCS|QUESTA)\b', "simulator_macro_divergence"),
    ]
    for pat, label in escape_pats:
        if len(re.findall(pat, cand_clean, re.I)) > len(re.findall(pat, base_clean, re.I)):
            finish(result_path, "FAIL", "policy", f"Policy violation in {rel_str}: {label}")

    for inc in re.findall(r'`include\s+"([^"]+)"', cand_clean):
        if inc != "common_cells/registers.svh":
            finish(result_path, "FAIL", "policy", f"Unauthorized include directive in {rel_str}: {inc}")

    mod_name = EXPECTED_MODULES[rel_str]
    if len(re.findall(rf'\bmodule\s+{mod_name}\b', cand_clean)) != 1:
        finish(result_path, "FAIL", "structural", f"Expected single module {mod_name} in {rel_str}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--candidate", required=True)
    ap.add_argument("--result", required=True)
    ap.add_argument("--seed", type=int, default=101)
    args, _ = ap.parse_known_args()

    result_path = pathlib.Path(args.result).resolve()
    cand_root = pathlib.Path(args.candidate)
    if cand_root.is_symlink() or not cand_root.is_dir():
        finish(result_path, "FAIL", "input_validation", "Invalid candidate directory")
    cand_root = cand_root.resolve()

    if not VERILATOR.exists() or not YOSYS.exists() or not SIMCELLS.exists():
        finish(result_path, "ERROR", "environment", "Required EDA binary missing")

    edit_set = set(EDITABLE_FILES)
    for rel in EDITABLE_FILES:
        cp = cand_root / rel
        if not cp.is_file() or cp.is_symlink():
            finish(result_path, "FAIL", "policy", f"Missing or symlinked editable file: {rel}")

    for pub_p in sorted((PUB_DIR / "code").rglob("*")):
        if not pub_p.is_file():
            continue
        rel = pub_p.relative_to(PUB_DIR)
        if rel in edit_set:
            continue
        cand_p = cand_root / rel
        if cand_p.exists() and (cand_p.is_symlink() or sha256_bytes(cand_p) != sha256_bytes(pub_p)):
            finish(result_path, "FAIL", "policy", f"Read-only file modified: {rel}")

    for rel in EDITABLE_FILES:
        screen_candidate_source(
            rel.as_posix(),
            (cand_root / rel).read_text(encoding="utf-8", errors="replace"),
            (PUB_DIR / rel).read_text(encoding="utf-8", errors="replace"),
            result_path,
        )

    try:
        with tempfile.TemporaryDirectory(prefix="case_20006_grade_") as td:
            wdir = pathlib.Path(td)
            shutil.copytree(PUB_DIR / "code", wdir / "code")
            for rel in EDITABLE_FILES:
                shutil.copyfile(cand_root / rel, wdir / rel)
            shutil.copyfile(PRIV_DIR / "tests" / "synth_wrap.sv", wdir / "synth_wrap.sv")
            shutil.copyfile(PRIV_DIR / "tests" / "tb.sv", wdir / "tb.sv")

            croot = wdir / "code"
            sv_sources = [
                croot / "common_cells/src/cb_filter_pkg.sv",
                croot / "common_cells/src/cf_math_pkg.sv",
                croot / "axi/src/axi_pkg.sv",
                croot / "rtl/axi_llc_pkg.sv",
                croot / "common_cells/src/delta_counter.sv",
                croot / "common_cells/src/counter.sv",
                croot / "common_cells/src/lzc.sv",
                croot / "common_cells/src/onehot_to_bin.sv",
                croot / "common_cells/src/fifo_v3.sv",
                croot / "common_cells/src/rr_arb_tree.sv",
                croot / "common_cells/src/shift_reg_gated.sv",
                croot / "common_cells/src/shift_reg.sv",
                croot / "common_cells/src/spill_register_flushable.sv",
                croot / "common_cells/src/spill_register.sv",
                croot / "common_cells/src/sub_per_hash.sv",
                croot / "common_cells/src/cb_filter.sv",
                croot / "rtl/tc_sram.sv",
                croot / "rtl/axi_llc_miss_counters.sv",
                croot / "rtl/axi_llc_tag_pattern_gen.sv",
                croot / "rtl/axi_llc_evict_box.sv",
                croot / "rtl/axi_llc_tag_store.sv",
                croot / "rtl/axi_llc_lock_box_bloom.sv",
                croot / "rtl/axi_llc_hit_miss.sv",
                wdir / "synth_wrap.sv",
            ]

            env = {
                "PATH": f"{TOOLS_DIR}/verilator-v5.038/bin:{TOOLS_DIR}/oss-cad-suite/bin:/usr/bin:/bin",
                "HOME": str(wdir),
                "TMPDIR": str(wdir),
                "CC": "/usr/bin/gcc",
                "CXX": "/usr/bin/g++",
            }

            # Stage 1: yosys+slang elaboration, latch/loop check, and gate-level netlist synthesis
            src_str = " ".join(str(s) for s in sv_sources)
            ys_cmd = (
                f"read_slang --top synth_hit_miss_wrap "
                f"-I{croot / 'common_cells/include'} -I{croot / 'axi/include'} -DSYNTHESIS {src_str}; "
                "hierarchy -check -top synth_hit_miss_wrap; proc; opt_expr; check -assert; "
                "select -assert-none t:$dlatch*; "
                "synth -top synth_hit_miss_wrap -flatten; "
                "rename synth_hit_miss_wrap synth_hit_miss_wrap_gl; "
                "opt_clean; "
                f"write_verilog -noattr {wdir / 'gl_netlist.v'}"
            )
            r_ys = subprocess.run([str(YOSYS), "-m", "slang", "-Q", "-T", "-p", ys_cmd], cwd=wdir, env=env, capture_output=True, text=True, timeout=120)
            if r_ys.returncode != 0 or not (wdir / "gl_netlist.v").is_file():
                tail = (r_ys.stdout + "\n" + r_ys.stderr).strip()[-1500:]
                finish(result_path, "FAIL", "synthesis", f"yosys+slang synthesis / latch / loop check failed:\n{tail}")

            # Stage 2: Verilator RTL + Gate-Level lockstep co-simulation
            cmd_vl = [
                str(VERILATOR),
                "--binary", "--timing", "-Wno-fatal", "-j", "1",
                f"+incdir+{croot / 'common_cells/include'}",
                f"+incdir+{croot / 'axi/include'}",
                "--top-module", "tb",
                "--Mdir", str(wdir / "obj"),
                str(SIMCELLS),
                str(wdir / "gl_netlist.v"),
                *[str(s) for s in sv_sources],
                str(wdir / "tb.sv"),
            ]
            r_vl = subprocess.run(cmd_vl, cwd=wdir, env=env, capture_output=True, text=True, timeout=180)
            if r_vl.returncode != 0 or not (wdir / "obj" / "Vtb").is_file():
                tail = (r_vl.stdout + "\n" + r_vl.stderr).strip()[-1500:]
                finish(result_path, "FAIL", "structural", f"Verilator co-simulation compile failed:\n{tail}")

            r_sim = subprocess.run([str(wdir / "obj" / "Vtb"), f"+seed={args.seed}"], cwd=wdir, env=env, capture_output=True, text=True, timeout=60)
            sim_out = (r_sim.stdout + "\n" + r_sim.stderr).strip()
            if r_sim.returncode != 0 or f"PASS seed={args.seed}" not in sim_out:
                finish(result_path, "FAIL", "functional", f"RTL/Gate-Level parity or functional check failed (seed={args.seed}):\n{sim_out[-1500:]}")

            finish(result_path, "PASS", "all_gates", f"Passed yosys+slang synthesis and RTL-vs-Gate-Level co-simulation (seed={args.seed})")
    except subprocess.TimeoutExpired:
        finish(result_path, "ERROR", "environment", "Synthesis or simulation timed out")
    except OSError as exc:
        finish(result_path, "ERROR", "environment", f"OS error: {exc}")


if __name__ == "__main__":
    main()
