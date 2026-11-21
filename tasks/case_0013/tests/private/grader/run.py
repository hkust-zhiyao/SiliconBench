#!/usr/bin/env python3
"""Private isolated grader for case_0013 (axi_dmac_reset_manager)."""
import argparse
import hashlib
import json
import os
import pathlib
import re
import subprocess
import sys
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
TOOLS_DIR = pathlib.Path(f"{_sb_tools_dir()}/iverilog-v13/bin")
IVERILOG = TOOLS_DIR / 'iverilog'
VVP = TOOLS_DIR / 'vvp'

EDITABLE_REL = pathlib.Path('code/axi_dmac_reset_manager.v')


def finish(result_path: pathlib.Path, verdict: str, stage: str, detail: str):
    payload = {
        'verdict': verdict,
        'stage': stage,
        'detail': detail,
    }
    result_path.parent.mkdir(parents=True, exist_ok=True)
    result_path.write_text(json.dumps(payload, indent=2) + '\n')
    print(json.dumps(payload))
    raise SystemExit(0 if verdict == 'PASS' else 2 if verdict == 'ERROR' else 1)


def sha256_bytes(p: pathlib.Path) -> str:
    return hashlib.sha256(p.read_bytes()).hexdigest()


def screen_candidate_source(text: str, result_path: pathlib.Path):
    if len(text.encode('utf-8')) > 250_000:
        finish(result_path, 'FAIL', 'anti_hack', 'Editable RTL exceeds size limit')

    if re.search(r'(?:pragma|synopsys|synthesis)\s+translate_(?:off|on)|verilator\s+(?:lint|coverage)', text, re.I):
        finish(result_path, 'FAIL', 'anti_hack', 'Policy violation: simulation directive')

    scan = re.sub(r'/\*.*?\*/|//[^\n]*', '', text, flags=re.S)
    if re.search(r'`(?!timescale\b)|\b(?:force|release|bind|initial|final|fork|join|disable|tb|trial)\b|#\s*\d|\bimport\s*"DPI', scan):
        finish(result_path, 'FAIL', 'anti_hack', 'Policy violation: unsupported simulation or escape construct')

    if re.search(r'\$(?!(?:clog2|bits|signed|unsigned)\b)', scan):
        finish(result_path, 'FAIL', 'anti_hack', 'Policy violation: unsupported system function or task')

    if re.search(r'\bmodule\s+(?:tb|trial|sync_bits)\b', scan):
        finish(result_path, 'FAIL', 'anti_hack', 'Policy violation: protected module override')

    if len(re.findall(r'\bmodule\s+axi_dmac_reset_manager\b', scan)) != 1:
        finish(result_path, 'FAIL', 'structural', 'Expected module declaration axi_dmac_reset_manager')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--candidate', required=True)
    ap.add_argument('--seed', type=int, required=True)
    ap.add_argument('--result', required=True)
    args = ap.parse_args()

    result_path = pathlib.Path(args.result).resolve()
    cand_root = pathlib.Path(args.candidate)
    if cand_root.is_symlink() or not cand_root.is_dir():
        finish(result_path, 'FAIL', 'structural', 'Invalid or symlinked candidate directory')
    cand_root = cand_root.resolve()

    if (cand_root / EDITABLE_REL).exists():
        cand_file = cand_root / EDITABLE_REL
    elif (cand_root / 'axi_dmac_reset_manager.v').exists():
        cand_file = cand_root / 'axi_dmac_reset_manager.v'
    else:
        finish(result_path, 'FAIL', 'structural', 'Missing editable file code/axi_dmac_reset_manager.v')

    if cand_file.is_symlink() or not cand_file.is_file() or not cand_file.resolve().is_relative_to(cand_root):
        finish(result_path, 'FAIL', 'anti_hack', 'Unsafe or symlinked candidate source file')

    # Verify protected read-only files if present in candidate directory
    for rel_str in ('code/sync_bits.v', 'code/LICENSE_GPL2', 'code/LICENSE_ADIBSD'):
        rel = pathlib.Path(rel_str)
        ref_f = PUB_DIR / rel
        cand_f = cand_root / rel
        if cand_f.exists() or cand_f.is_symlink():
            if cand_f.is_symlink() or not cand_f.is_file() or sha256_bytes(cand_f) != sha256_bytes(ref_f):
                finish(result_path, 'FAIL', 'anti_hack', f'Protected file modified: {rel_str}')

    text = cand_file.read_text(encoding='utf-8', errors='replace')
    screen_candidate_source(text, result_path)

    try:
        with tempfile.TemporaryDirectory(prefix='case_0013_grade_') as td:
            work = pathlib.Path(td)
            cand_v = work / 'candidate.v'
            cand_v.write_text(text, encoding='utf-8')
            sim_bin = work / 'sim'

            comp_cmd = [
                str(IVERILOG),
                '-g2012',
                '-s', 'tb',
                '-o', str(sim_bin),
                str(PRIV_DIR / 'trusted/sync_bits.v'),
                str(cand_v),
                str(PRIV_DIR / 'tests/tb.sv'),
            ]
            r_comp = subprocess.run(comp_cmd, cwd=work, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=30)
            if r_comp.returncode != 0:
                finish(result_path, 'FAIL', 'compile', 'compile failure: ' + r_comp.stdout[-1500:])

            r_sim = subprocess.run([str(VVP), str(sim_bin), f'+seed={args.seed}'], cwd=work, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=30)
            out = r_sim.stdout.strip()
            if r_sim.returncode != 0 or not re.search(r'^PASS\b', r_sim.stdout, re.M):
                finish(result_path, 'FAIL', 'behavior', f'behavior mismatch (seed={args.seed}): {out[-1500:]}')

            finish(result_path, 'PASS', 'behavior', f'All external reset, startup abort, pause, and SG checks passed (seed={args.seed})')
    except subprocess.TimeoutExpired:
        finish(result_path, 'ERROR', 'environment', 'Compilation or simulation timed out')
    except OSError as exc:
        finish(result_path, 'ERROR', 'environment', f'OS error: {exc}')


if __name__ == '__main__':
    main()
