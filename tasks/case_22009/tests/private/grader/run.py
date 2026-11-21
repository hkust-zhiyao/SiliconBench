#!/usr/bin/env python3
"""Private isolated grader for case_22009 (RedMulE systolic wave-front scheduling)."""
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

EDITABLE_SPECS = [
    (pathlib.Path('code/redmule_tiler.sv'), 'redmule_tiler'),
    (pathlib.Path('code/redmule_scheduler.sv'), 'redmule_scheduler'),
    (pathlib.Path('code/redmule_memory_scheduler.sv'), 'redmule_memory_scheduler'),
]
EDITABLE_SET = {rel for rel, _ in EDITABLE_SPECS}

RTL_FILES = [
    'code/fpnew_pkg.sv',
    'code/cf_math_pkg.sv',
    'code/hci_package.sv',
    'code/hwpe_ctrl_package.sv',
    'code/hwpe_stream_package.sv',
    'code/redmule_pkg.sv',
    'code/tc_clk.sv',
    'code/edge_detect.sv',
    'code/sync.sv',
    'code/sync_wedge.sv',
    'code/lzc.sv',
    'code/hwpe_stream_fifo.sv',
    'code/fpnew_classifier.sv',
    'code/fpnew_rounding.sv',
    'code/redmule_fma.sv',
    'code/redmule_row.sv',
    'code/redmule_engine.sv',
    'code/x_buffer/redmule_x_pad_scm.sv',
    'code/x_buffer/redmule_x_buffer_scm.sv',
    'code/x_buffer/redmule_x_buffer.sv',
    'code/w_buffer/redmule_w_buffer_scm.sv',
    'code/w_buffer/redmule_w_buffer.sv',
    'code/z_buffer/redmule_z_buffer_scm.sv',
    'code/z_buffer/redmule_z_buffer.sv',
    'code/redmule_config_fifo.sv',
    'code/redmule_ctrl.sv',
    'code/redmule_tiler.sv',
    'code/redmule_memory_scheduler.sv',
    'code/redmule_scheduler.sv',
    'code/redmule_subsys.sv',
]


def finish(result_path: pathlib.Path, verdict: str, stage: str, detail: str):
    payload = {
        'verdict': verdict,
        'stage': stage,
        'detail': detail,
    }
    result_path.parent.mkdir(parents=True, exist_ok=True)
    result_path.write_text(json.dumps(payload, indent=2) + '\n', encoding='utf-8')
    print(json.dumps(payload))
    raise SystemExit(0 if verdict == 'PASS' else 2 if verdict == 'ERROR' else 1)


def sha256_bytes(p: pathlib.Path) -> str:
    return hashlib.sha256(p.read_bytes()).hexdigest()


def strip_comments_and_strings(text: str) -> str:
    text = re.sub(r'(?is)//\s*pragma\s+translate_off.*?//\s*pragma\s+translate_on', '', text)
    text = re.sub(r'/\*.*?\*/|//[^\n]*', ' ', text, flags=re.S)
    return text


def screen_candidate_source(cand_text: str, base_text: str, mod_name: str, rel_name: str, result_path: pathlib.Path):
    if len(cand_text.encode('utf-8')) > 500_000:
        finish(result_path, 'FAIL', 'policy', f'Editable RTL exceeds size limit: {rel_name}')

    cand_clean = strip_comments_and_strings(cand_text)
    base_clean = strip_comments_and_strings(base_text)

    escape_pats = [
        (r'\$(?:fopen|fclose|fread|fwrite|fdisplay|fscanf|system|finish|stop|fatal|readmemh|readmemb|writememh|writememb|dumpfile|dumpvars|value\$plusargs|test\$plusargs)\b', 'forbidden_systask'),
        (r'\b(?:force|release|bind|defparam)\b', 'procedural_force_or_bind'),
        (r'\b(?:import|export)\s*"DPI', 'dpi_escape'),
        (r'\$root\b|\b(?:tb|dut|grader|oracle|golden_ref|tcdm_mem)\s*\.', 'hierarchical_harness_reference'),
        (r'`\s*(?:ifdef|ifndef|elsif)\s+(?:VERILATOR|SYNTHESIS|SIMULATION|__ICARUS__|VCS|QUESTA)\b', 'simulator_macro_divergence'),
    ]
    for pat, label in escape_pats:
        if len(re.findall(pat, cand_clean, re.I)) > len(re.findall(pat, base_clean, re.I)):
            finish(result_path, 'FAIL', 'policy', f'Policy violation in {rel_name}: {label}')

    allowed_inc = {'common_cells/registers.svh', 'common_cells/assertions.svh'}
    for inc in re.findall(r'`include\s+"([^"]+)"', cand_clean):
        if inc not in allowed_inc:
            finish(result_path, 'FAIL', 'policy', f'Unauthorized include directive in {rel_name}: {inc}')

    if len(re.findall(rf'\bmodule\s+{re.escape(mod_name)}\b', cand_clean)) != 1 or len(re.findall(r'\bmodule\b', cand_clean)) != 1:
        finish(result_path, 'FAIL', 'structural', f'Expected exactly one module declaration ({mod_name}) in {rel_name}')


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

    is_full_tree = (cand_root / 'issue.md').is_file() or (sum(1 for _ in (cand_root / 'code').glob('*')) > len(EDITABLE_SET) + 1 if (cand_root / 'code').is_dir() else False)
    if is_full_tree:
        for ref_file in sorted((PUB_DIR / 'code').rglob('*')):
            if not ref_file.is_file():
                continue
            rel = ref_file.relative_to(PUB_DIR)
            if rel in EDITABLE_SET:
                continue
            c_file = cand_root / rel
            if not c_file.is_file() or c_file.is_symlink() or sha256_bytes(c_file) != sha256_bytes(ref_file):
                finish(result_path, 'FAIL', 'policy', f'Protected file modified or missing: {rel}')

    cand_sources: dict[pathlib.Path, str] = {}
    for rel, mod_name in EDITABLE_SPECS:
        if (cand_root / rel).exists():
            c_file = cand_root / rel
        elif (cand_root / rel.name).exists():
            c_file = cand_root / rel.name
        else:
            finish(result_path, 'FAIL', 'input_validation', f'Missing editable file {rel}')

        if c_file.is_symlink() or not c_file.is_file() or not c_file.resolve().is_relative_to(cand_root):
            finish(result_path, 'FAIL', 'input_validation', f'Invalid or symlinked candidate source file: {rel}')

        c_text = c_file.read_text(encoding='utf-8', errors='replace')
        b_text = (PUB_DIR / rel).read_text(encoding='utf-8')
        screen_candidate_source(c_text, b_text, mod_name, str(rel), result_path)
        cand_sources[rel] = c_text

    try:
        with tempfile.TemporaryDirectory(prefix='case_22009_grade_') as td:
            work = pathlib.Path(td)
            shutil.copytree(PUB_DIR / 'code', work / 'code')
            for rel, c_text in cand_sources.items():
                (work / rel).write_text(c_text, encoding='utf-8')
            shutil.copyfile(PRIV_DIR / 'tests' / 'tb.sv', work / 'tb.sv')

            v_env = {
                'PATH': f'{TOOLS_DIR}/verilator-v5.038/bin:{TOOLS_DIR}/oss-cad-suite/bin:/usr/bin:/bin',
                'HOME': str(work),
                'TMPDIR': str(work),
                'CC': '/usr/bin/gcc',
                'CXX': '/usr/bin/g++',
            }

            cmd_comp = [
                str(VERILATOR),
                '--binary', '-j', '2', '-O1', '-CFLAGS', '-O0',
                '-Wno-fatal', '-Wno-TIMESCALEMOD',
                '-Icode/include',
                '--top-module', 'tb',
                '--Mdir', str(work / 'obj_dir'),
                *RTL_FILES,
                'tb.sv',
            ]
            r_comp = subprocess.run(cmd_comp, cwd=work, env=v_env, capture_output=True, text=True, timeout=180)
            if r_comp.returncode != 0 or not (work / 'obj_dir' / 'Vtb').is_file():
                tail = (r_comp.stdout + '\n' + r_comp.stderr).strip()[-1500:]
                finish(result_path, 'FAIL', 'compile', f'Verilator compile failed: {tail}')

            r_sim = subprocess.run(
                [str(work / 'obj_dir' / 'Vtb'), f'+SEED={args.seed}'],
                cwd=work, env=v_env, capture_output=True, text=True, timeout=60
            )
            sim_out = (r_sim.stdout + '\n' + r_sim.stderr).strip()
            expected_summary = f'=== SUMMARY (SEED={args.seed}): 27/27 passed, 0 failed ==='
            if r_sim.returncode != 0 or expected_summary not in sim_out:
                fail_lines = [
                    ln for ln in sim_out.splitlines()
                    if any(k in ln for k in ('[FAIL]', 'Assertion failed', '%Error', '%Fatal', 'SUMMARY'))
                ]
                snippet = '\n'.join(fail_lines[:10]) if fail_lines else sim_out[-1200:]
                finish(result_path, 'FAIL', 'functional', f'Simulation failed (seed={args.seed}): {snippet}')

            ys_script = (
                'read_slang --top redmule_subsys --keep-hierarchy --allow-use-before-declare '
                '--ignore-assertions -Wno-range-oob -I code/include '
                + ' '.join(RTL_FILES)
                + '; hierarchy -check -top redmule_subsys; blackbox *tc_clk_gating*; '
                'proc; opt_clean; check; select -assert-none t:$dlatch'
            )
            r_ys = subprocess.run(
                [str(YOSYS), '-m', 'slang', '-p', ys_script],
                cwd=work, env=v_env, capture_output=True, text=True, timeout=90
            )
            if r_ys.returncode != 0:
                ys_tail = (r_ys.stdout + '\n' + r_ys.stderr).strip()[-1200:]
                finish(result_path, 'FAIL', 'synthesis', f'Yosys elaboration or zero-latch check failed: {ys_tail}')

            finish(
                result_path,
                'PASS',
                'functional',
                f'All 27 systolic wave-front, leftover, loopback, queue, and clear checks + zero-latch synthesis passed for seed={args.seed}'
            )
    except subprocess.TimeoutExpired:
        finish(result_path, 'FAIL', 'functional', f'Simulation or synthesis timed out (possible controller deadlock) for seed={args.seed}')
    except OSError as exc:
        finish(result_path, 'ERROR', 'environment', f'OS error: {exc}')


if __name__ == '__main__':
    main()
