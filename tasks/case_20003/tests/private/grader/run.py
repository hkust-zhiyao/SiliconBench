#!/usr/bin/env python3
"""Private isolated grader for case_20003 (biriscv_npc.v + biriscv_fetch.v)."""
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

EDITABLE_FILES = [
    pathlib.Path("code/biriscv_npc.v"),
    pathlib.Path("code/biriscv_fetch.v"),
]


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


def screen_candidate_source(cand_text: str, base_text: str, mod_name: str, result_path: pathlib.Path):
    if len(cand_text.encode("utf-8")) > 250_000:
        finish(result_path, "FAIL", "policy", f"Editable RTL {mod_name} exceeds size limit")

    cand_clean = strip_comments_and_strings(cand_text)
    base_clean = strip_comments_and_strings(base_text)

    escape_pats = [
        (r'\$(?:fopen|fclose|fread|fwrite|fdisplay|fscanf|system|finish|stop|readmemh|readmemb|writememh|writememb|dumpfile|dumpvars|value\$plusargs|test\$plusargs)\b', "forbidden_systask"),
        (r'\b(?:force|release|bind|defparam)\b', "procedural_force_or_bind"),
        (r'\b(?:import|export)\s*"DPI', "dpi_escape"),
        (r'\$root\b|\b(?:tb|u_fe|u_npc_gsh|u_npc_nobht|u_fetch_mmu1|u_fetch_mmu0|grader|oracle)\s*\.', "hierarchical_harness_reference"),
        (r'`\s*(?:ifdef|ifndef|elsif)\s+(?:VERILATOR|SYNTHESIS|SIMULATION|__ICARUS__|VCS|QUESTA)\b', "simulator_macro_divergence"),
    ]
    for pat, label in escape_pats:
        if len(re.findall(pat, cand_clean, re.I)) > len(re.findall(pat, base_clean, re.I)):
            finish(result_path, "FAIL", "policy", f"Policy violation in {mod_name}: {label}")

    for inc in re.findall(r'`include\s+"([^"]+)"', cand_clean):
        if inc != "biriscv_defs.v":
            finish(result_path, "FAIL", "policy", f"Unauthorized include directive in {mod_name}: {inc}")

    if len(re.findall(rf'\bmodule\s+{mod_name}\b', cand_clean)) != 1:
        finish(result_path, "FAIL", "structural", f"Expected module declaration {mod_name}")


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
    for pub_f in PUB_DIR.rglob("*"):
        if not pub_f.is_file():
            continue
        rel = pub_f.relative_to(PUB_DIR)
        if rel in edit_set:
            continue
        cand_f = cand_root / rel
        if cand_f.exists() and sha256_bytes(cand_f) != sha256_bytes(pub_f):
            finish(result_path, "FAIL", "policy", f"Read-only file modified: {rel}")

    for rel, mod in zip(EDITABLE_FILES, ["biriscv_npc", "biriscv_fetch"]):
        cf = cand_root / rel
        if not cf.is_file():
            finish(result_path, "FAIL", "structural", f"Missing editable file: {rel}")
        screen_candidate_source(cf.read_text(encoding="utf-8", errors="replace"),
                                (PUB_DIR / rel).read_text(encoding="utf-8"),
                                mod, result_path)

    with tempfile.TemporaryDirectory(prefix="case_20003_grade_") as tmp:
        work = pathlib.Path(tmp)
        code_dir = work / "code"
        shutil.copytree(PUB_DIR / "code", code_dir)
        for rel in EDITABLE_FILES:
            shutil.copyfile(cand_root / rel, work / rel)
        shutil.copyfile(PRIV_DIR / "tests" / "tb.sv", work / "tb.sv")

        # Stage 1: Yosys synthesis & zero-latch / zero-comb-loop check across biriscv_frontend (both MMU=1 and MMU=0)
        yosys_script = (
            f"read_verilog -sv -DSYNTHESIS -I{code_dir} "
            f"{code_dir/'biriscv_defs.v'} {code_dir/'biriscv_npc.v'} {code_dir/'biriscv_fetch.v'} "
            f"{code_dir/'biriscv_decoder.v'} {code_dir/'biriscv_decode.v'} {code_dir/'biriscv_frontend.v'}; "
            "hierarchy -check -top biriscv_frontend -chparam SUPPORT_MMU 1 -chparam GSHARE_ENABLE 1; "
            "proc; opt_expr; check -assert; select -assert-none t:$dlatch*"
        )
        yo = subprocess.run([str(YOSYS), "-Q", "-q", "-p", yosys_script],
                            cwd=work, capture_output=True, text=True, timeout=90)
        if yo.returncode != 0:
            detail = (yo.stderr or yo.stdout or "Yosys check failed").strip()[-800:]
            finish(result_path, "FAIL", "synthesis", f"Yosys synthesis/latch/loop check failed: {detail}")

        # Stage 2: Verilator compile & simulation
        v_cmd = [
            str(VERILATOR), "--binary", "-sv", "-Wno-fatal",
            f"-I{code_dir}", "--top-module", "tb",
            str(code_dir / "biriscv_defs.v"),
            str(code_dir / "biriscv_npc.v"),
            str(code_dir / "biriscv_fetch.v"),
            str(code_dir / "biriscv_decoder.v"),
            str(code_dir / "biriscv_decode.v"),
            str(code_dir / "biriscv_frontend.v"),
            str(work / "tb.sv"),
            "-o", str(work / "simv"),
        ]
        comp = subprocess.run(v_cmd, cwd=work, capture_output=True, text=True, timeout=90)
        if comp.returncode != 0 or not (work / "simv").exists():
            detail = (comp.stderr or comp.stdout or "Verilator compile failed").strip()[-800:]
            finish(result_path, "FAIL", "synthesis", f"Verilator elaboration failed: {detail}")

        sim = subprocess.run([str(work / "simv"), f"+seed={args.seed}"],
                             cwd=work, capture_output=True, text=True, timeout=60)
        out = (sim.stdout or "") + "\n" + (sim.stderr or "")
        if sim.returncode != 0 or f"PASS seed={args.seed}" not in out:
            finish(result_path, "FAIL", "functional", f"Simulation failed (seed={args.seed}): {out.strip()[-800:]}")

        finish(result_path, "PASS", "all_gates", f"Passed Yosys structural check and frontend/NPC/fetch simulation (seed={args.seed})")


if __name__ == "__main__":
    main()
