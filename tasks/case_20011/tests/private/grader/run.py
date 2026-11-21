#!/usr/bin/env python3
"""Private isolated grader for case_20011 (biriscv_mmu.v)."""
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

EDITABLE_FILES = [pathlib.Path("code/biriscv_mmu.v")]


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


def screen_candidate_source(cand_text: str, base_text: str, result_path: pathlib.Path):
    if len(cand_text.encode("utf-8")) > 250_000:
        finish(result_path, "FAIL", "policy", "Editable RTL exceeds size limit")

    cand_clean = strip_comments_and_strings(cand_text)
    base_clean = strip_comments_and_strings(base_text)

    escape_pats = [
        (r'\$(?:fopen|fclose|fread|fwrite|fdisplay|fscanf|system|finish|stop|readmemh|readmemb|writememh|writememb|dumpfile|dumpvars|value\$plusargs|test\$plusargs)\b', "forbidden_systask"),
        (r'\b(?:force|release|bind|defparam)\b', "procedural_force_or_bind"),
        (r'\b(?:import|export)\s*"DPI', "dpi_escape"),
        (r'\$root\b|\b(?:tb|dut|dut_nommu|pmem|grader|oracle)\s*\.', "hierarchical_harness_reference"),
        (r'`\s*(?:ifdef|ifndef|elsif)\s+(?:VERILATOR|SYNTHESIS|SIMULATION|__ICARUS__|VCS|QUESTA)\b', "simulator_macro_divergence"),
    ]
    for pat, label in escape_pats:
        if len(re.findall(pat, cand_clean, re.I)) > len(re.findall(pat, base_clean, re.I)):
            finish(result_path, "FAIL", "policy", f"Policy violation in biriscv_mmu.v: {label}")

    for inc in re.findall(r'`include\s+"([^"]+)"', cand_clean):
        if inc != "biriscv_defs.v":
            finish(result_path, "FAIL", "policy", f"Unauthorized include directive: {inc}")

    if len(re.findall(r'\bmodule\s+biriscv_mmu\b', cand_clean)) != 1:
        finish(result_path, "FAIL", "structural", "Expected module declaration biriscv_mmu")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--candidate", required=True)
    ap.add_argument("--result", required=True)
    ap.add_argument("--seed", type=int, default=101)
    args, _ = ap.parse_known_args()

    cand_root = pathlib.Path(args.candidate).resolve()
    result_path = pathlib.Path(args.result).resolve()

    if not VERILATOR.exists() or not YOSYS.exists():
        finish(result_path, "ERROR", "environment", "Required EDA binary missing")

    edit_set = set(EDITABLE_FILES)
    for rel in EDITABLE_FILES:
        if not (cand_root / rel).is_file():
            finish(result_path, "FAIL", "policy", f"Missing editable file: {rel}")

    for pub_p in sorted((PUB_DIR / "code").rglob("*")):
        if not pub_p.is_file():
            continue
        rel = pub_p.relative_to(PUB_DIR)
        if rel in edit_set:
            continue
        cand_p = cand_root / rel
        if cand_p.exists() and sha256_bytes(cand_p) != sha256_bytes(pub_p):
            finish(result_path, "FAIL", "policy", f"Read-only file modified: {rel}")

    screen_candidate_source(
        (cand_root / "code/biriscv_mmu.v").read_text(encoding="utf-8", errors="replace"),
        (PUB_DIR / "code/biriscv_mmu.v").read_text(encoding="utf-8", errors="replace"),
        result_path,
    )

    with tempfile.TemporaryDirectory(prefix="case_20011_grade_") as tmp:
        wdir = pathlib.Path(tmp)
        cdir = wdir / "code"
        cdir.mkdir()
        for pub_p in (PUB_DIR / "code").iterdir():
            if pub_p.is_file():
                shutil.copyfile(pub_p, cdir / pub_p.name)
        shutil.copyfile(cand_root / "code/biriscv_mmu.v", cdir / "biriscv_mmu.v")

        ys_script = f"""
read_verilog -sv -DSYNTHESIS -I{cdir} {cdir}/biriscv_defs.v {cdir}/biriscv_mmu.v
hierarchy -check -top biriscv_mmu -chparam SUPPORT_MMU 1
proc
opt_expr
check -assert
select -assert-none t:$dlatch*
"""
        (wdir / "synth.ys").write_text(ys_script, encoding="utf-8")
        ys = subprocess.run([str(YOSYS), "-q", "-s", str(wdir / "synth.ys")], capture_output=True, text=True, timeout=90)
        if ys.returncode != 0:
            finish(result_path, "FAIL", "synthesis", f"Yosys synthesis/latch/loop check failed:\n{(ys.stderr or ys.stdout)[-1200:]}")

        shutil.copyfile(PRIV_DIR / "tests" / "tb.sv", wdir / "tb.sv")
        vl_cmd = [
            str(VERILATOR), "--binary", "-sv", "-Wno-fatal",
            f"-I{cdir}", "--top-module", "tb",
            str(cdir / "biriscv_defs.v"),
            str(cdir / "biriscv_mmu.v"),
            str(wdir / "tb.sv"),
            "--Mdir", str(wdir / "obj_dir"),
            "-o", str(wdir / "simv"),
        ]
        vl = subprocess.run(vl_cmd, capture_output=True, text=True, timeout=120)
        if vl.returncode != 0:
            finish(result_path, "FAIL", "structural", f"Verilator compile failed:\n{(vl.stderr or vl.stdout)[-1200:]}")

        sim = subprocess.run([str(wdir / "simv"), f"+seed={args.seed}"], cwd=str(wdir), capture_output=True, text=True, timeout=90)
        out = (sim.stdout or "") + "\n" + (sim.stderr or "")
        if sim.returncode != 0 or f"PASS seed={args.seed}" not in out:
            finish(result_path, "FAIL", "functional", f"Simulation failed (seed={args.seed}): {out.strip()[-800:]}")

        finish(result_path, "PASS", "all_gates", f"Passed Yosys check and Sv32 MMU verification (seed={args.seed})")


if __name__ == "__main__":
    main()
