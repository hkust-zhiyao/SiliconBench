#!/usr/bin/env python3
"""Private isolated grader for case_24001 (cdc_reset_ctrlr)."""
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
PRIV_DIR = TASK_DIR / 'private'
PUB_DIR = TASK_DIR / 'public'
TOOLS_DIR = pathlib.Path(str(_sb_tools_dir()))
VERILATOR = TOOLS_DIR / 'verilator-v5.038' / 'bin' / 'verilator'
YOSYS = TOOLS_DIR / 'oss-cad-suite' / 'bin' / 'yosys'

EDITABLE_REL = pathlib.Path('code/cdc_reset_ctrlr.sv')


def finish(result_path: pathlib.Path, verdict: str, stage: str, detail: str):
    payload = {'verdict': verdict, 'stage': stage, 'detail': detail}
    result_path.parent.mkdir(parents=True, exist_ok=True)
    result_path.write_text(json.dumps(payload, indent=2) + '\n', encoding='utf-8')
    print(json.dumps(payload))
    raise SystemExit(0 if verdict == 'PASS' else 2 if verdict == 'ERROR' else 1)


def sha256_bytes(p: pathlib.Path) -> str:
    return hashlib.sha256(p.read_bytes()).hexdigest()


def strip_comments_and_strings(text: str) -> str:
    text = re.sub(r'(?is)//\s*pragma\s+translate_off.*?//\s*pragma\s+translate_on', '', text)
    text = re.sub(r'/\*.*?\*/|//[^\n]*|"(?:\\.|[^"\\])*"', ' ', text, flags=re.S)
    return text


def screen_candidate_source(cand_text: str, result_path: pathlib.Path):
    if len(cand_text.encode('utf-8')) > 250_000:
        finish(result_path, 'FAIL', 'policy', 'Editable RTL exceeds size limit')

    cand_clean = strip_comments_and_strings(cand_text)
    escape_pats = [
        (r'\$(?:fopen|fclose|fread|fwrite|fdisplay|fscanf|system|finish|stop|readmemh|readmemb|writememh|writememb|dumpfile|dumpvars|value\$plusargs|test\$plusargs)\b', 'forbidden_systask'),
        (r'\b(?:force|release|bind|defparam)\b', 'procedural_force_or_bind'),
        (r'\b(?:import|export)\s*"DPI', 'dpi_escape'),
        (r'\$root\b|\b(?:tb|dut|dut_s4|grader|oracle|golden_ref)\s*\.', 'hierarchical_harness_reference'),
        (r'`\s*(?:ifdef|ifndef|elsif)\s+(?:VERILATOR|SYNTHESIS|SIMULATION|__ICARUS__|VCS|QUESTA)\b', 'simulator_macro_divergence'),
    ]
    for pat, label in escape_pats:
        if re.search(pat, cand_clean, re.I):
            finish(result_path, 'FAIL', 'policy', f'Policy violation in candidate RTL: {label}')

    for inc in re.findall(r'`include\s+"([^"]+)"', cand_clean):
        finish(result_path, 'FAIL', 'policy', f'Unauthorized include directive: {inc}')

    if len(re.findall(r'\bmodule\s+cdc_reset_ctrlr\b', cand_clean)) != 1:
        finish(result_path, 'FAIL', 'structural', 'Expected module declaration: cdc_reset_ctrlr')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--candidate', required=True)
    ap.add_argument('--seed', type=int, default=101)
    ap.add_argument('--result', required=True)
    args = ap.parse_args()

    result_path = pathlib.Path(args.result).resolve()
    cand_root = pathlib.Path(args.candidate)
    if cand_root.is_symlink() or not cand_root.is_dir():
        finish(result_path, 'FAIL', 'input_validation', 'Invalid or symlinked candidate directory')
    cand_root = cand_root.resolve()

    if (cand_root / EDITABLE_REL).exists():
        cand_file = cand_root / EDITABLE_REL
    elif (cand_root / EDITABLE_REL.name).exists():
        cand_file = cand_root / EDITABLE_REL.name
    else:
        finish(result_path, 'FAIL', 'input_validation', f'Missing editable file {EDITABLE_REL}')

    if cand_file.is_symlink() or not cand_file.is_file() or not cand_file.resolve().is_relative_to(cand_root):
        finish(result_path, 'FAIL', 'input_validation', 'Invalid or symlinked candidate source file')

    if (cand_root / 'code').is_dir():
        for ref_file in sorted((PUB_DIR / 'code').rglob('*')):
            if not ref_file.is_file():
                continue
            rel = ref_file.relative_to(PUB_DIR)
            if rel == EDITABLE_REL:
                continue
            c_file = cand_root / rel
            if not c_file.is_file() or c_file.is_symlink() or sha256_bytes(c_file) != sha256_bytes(ref_file):
                finish(result_path, 'FAIL', 'policy', f'Protected file modified or missing: {rel}')

    cand_text = cand_file.read_text(encoding='utf-8', errors='replace')
    screen_candidate_source(cand_text, result_path)

    try:
        with tempfile.TemporaryDirectory(prefix='case_24001_grade_') as td:
            work = pathlib.Path(td)
            shutil.copytree(PUB_DIR / 'code', work / 'code')
            (work / 'code' / 'cdc_reset_ctrlr.sv').write_text(cand_text, encoding='utf-8')
            shutil.copyfile(PRIV_DIR / 'tests' / 'tb.sv', work / 'tb.sv')

            env = {
                'PATH': f'{TOOLS_DIR}/verilator-v5.038/bin:{TOOLS_DIR}/oss-cad-suite/bin:/usr/bin:/bin',
                'HOME': str(work),
                'TMPDIR': str(work),
                'CC': '/usr/bin/gcc',
                'CXX': '/usr/bin/g++',
            }

            # 1. Synthesizability & zero-latch check via Yosys + Slang
            ys_script = f"""
plugin -i slang
read_slang -DCOMMON_CELLS_ASSERTS_OFF -DSYNTHESIS -I {work}/code \
    {work}/code/cdc_reset_ctrlr_pkg.sv \
    {work}/code/sync.sv \
    {work}/code/spill_register_flushable.sv \
    {work}/code/spill_register.sv \
    {work}/code/cdc_4phase.sv \
    {work}/code/cdc_reset_ctrlr.sv \
    --top cdc_reset_ctrlr
hierarchy -check -top cdc_reset_ctrlr
proc; opt; check
select -assert-none t:$dlatch*
"""
            r_syn = subprocess.run([str(YOSYS), '-s', '-'], input=ys_script, cwd=work, env=env, capture_output=True, text=True, timeout=90)
            if r_syn.returncode != 0:
                tail = (r_syn.stdout + '\n' + r_syn.stderr).strip()[-1500:]
                finish(result_path, 'FAIL', 'synthesis', f'Yosys synthesis / latch check failed: {tail}')

            # 2. Multi-clock RDC simulation via Verilator 5.038
            cmd_comp = [
                str(VERILATOR), '--binary', '--timing', '-Wno-fatal', '-DCOMMON_CELLS_ASSERTS_OFF', '-j', '1',
                f'-I{work}/code',
                '--top-module', 'tb',
                '--Mdir', str(work / 'obj'),
                str(work / 'code' / 'cdc_reset_ctrlr_pkg.sv'),
                str(work / 'code' / 'sync.sv'),
                str(work / 'code' / 'spill_register_flushable.sv'),
                str(work / 'code' / 'spill_register.sv'),
                str(work / 'code' / 'cdc_4phase.sv'),
                str(work / 'code' / 'cdc_reset_ctrlr.sv'),
                str(work / 'tb.sv'),
            ]
            r_comp = subprocess.run(cmd_comp, cwd=work, env=env, capture_output=True, text=True, timeout=180)
            if r_comp.returncode != 0 or not (work / 'obj' / 'Vtb').is_file():
                tail = (r_comp.stdout + '\n' + r_comp.stderr).strip()[-1500:]
                finish(result_path, 'FAIL', 'compile', f'Verilator compile failed: {tail}')

            r_sim = subprocess.run([str(work / 'obj' / 'Vtb'), f'+seed={args.seed}'], cwd=work, env=env, capture_output=True, text=True, timeout=90)
            sim_out = (r_sim.stdout + '\n' + r_sim.stderr).strip()
            if r_sim.returncode != 0 or f'PASS seed={args.seed}' not in sim_out:
                finish(result_path, 'FAIL', 'functional', f'Simulation failed (seed={args.seed}): {sim_out[-1500:]}')

            finish(result_path, 'PASS', 'functional', f'All synthesis zero-latch and multi-clock RDC isolation/reset checks passed for seed={args.seed}')
    except subprocess.TimeoutExpired:
        finish(result_path, 'ERROR', 'environment', 'Compilation, synthesis, or simulation timed out')
    except OSError as exc:
        finish(result_path, 'ERROR', 'environment', f'OS error: {exc}')


if __name__ == '__main__':
    main()
