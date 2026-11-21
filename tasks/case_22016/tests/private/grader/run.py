#!/usr/bin/env python3
"""Private isolated grader for case_22016 (Ara Multi-VFU Vector Chaining, Queue Accounting & CSR Ordering)."""
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
    (pathlib.Path('code/ara_sequencer.sv'), 'ara_sequencer'),
    (pathlib.Path('code/ara_dispatcher.sv'), 'ara_dispatcher'),
]
EDITABLE_SET = {rel for rel, _ in EDITABLE_SPECS}

ALLOWED_INCLUDES = {
    'common_cells/registers.svh',
    'common_cells/assertions.svh',
    'ara/ara_typedef.svh',
    'ara/intf_typedef.svh',
}

SIM_RTL_ORDER = [
    'code/config_pkg.sv',
    'code/cv64a6_imafdcv_sv39_config_pkg.sv',
    'code/build_config_pkg.sv',
    'code/riscv_pkg.sv',
    'code/cf_math_pkg.sv',
    'code/axi_pkg.sv',
    'code/fpnew_pkg.sv',
    'code/rvv_pkg.sv',
    'code/ara_pkg.sv',
    'code/onehot_to_bin.sv',
    'code/lzc.sv',
    'code/popcount.sv',
    'code/counter.sv',
    'code/delta_counter.sv',
    'code/fall_through_register.sv',
    'code/spill_register_flushable.sv',
    'code/spill_register.sv',
    'code/stream_register.sv',
    'code/fifo_v3.sv',
    'code/rr_arb_tree.sv',
    'code/stream_arbiter_flushable.sv',
    'code/stream_arbiter.sv',
    'code/stream_demux.sv',
    'code/stream_mux.sv',
    'code/stream_xbar.sv',
    'code/axi_cut.sv',
    'code/segment_sequencer.sv',
    'code/ara_dispatcher.sv',
    'code/ara_sequencer.sv',
    'code/lane/lane_sequencer.sv',
    'code/lane/operand_requester.sv',
]

SYNTH_RTL_ORDER = [
    'code/config_pkg.sv',
    'code/cv64a6_imafdcv_sv39_config_pkg.sv',
    'code/build_config_pkg.sv',
    'code/riscv_pkg.sv',
    'code/cf_math_pkg.sv',
    'code/axi_pkg.sv',
    'code/fpnew_pkg.sv',
    'code/rvv_pkg.sv',
    'code/ara_pkg.sv',
    'code/counter.sv',
    'code/delta_counter.sv',
    'code/lzc.sv',
    'code/popcount.sv',
    'code/fifo_v3.sv',
    'code/spill_register_flushable.sv',
    'code/spill_register.sv',
    'code/segment_sequencer.sv',
    'code/ara_dispatcher.sv',
    'code/ara_sequencer.sv',
]


def finish(result_path: pathlib.Path, verdict: str, stage: str, detail: str):
    payload = {'verdict': verdict, 'stage': stage, 'detail': detail}
    result_path.parent.mkdir(parents=True, exist_ok=True)
    result_path.write_text(json.dumps(payload, indent=2) + '\n', encoding='utf-8')
    print(json.dumps(payload))
    raise SystemExit(0 if verdict == 'PASS' else 2 if verdict == 'ERROR' else 1)


def sha256_bytes(p: pathlib.Path) -> str:
    return hashlib.sha256(p.read_bytes()).hexdigest()


def strip_comments(text: str) -> str:
    text = re.sub(r'(?is)//\s*pragma\s+translate_off.*?//\s*pragma\s+translate_on', '', text)
    return re.sub(r'/\*.*?\*/|//[^\n]*', ' ', text, flags=re.S)


def screen_source(cand_text: str, base_text: str, mod_name: str, rel_name: str, result_path: pathlib.Path):
    if len(cand_text.encode('utf-8')) > 600_000:
        finish(result_path, 'FAIL', 'policy', f'Editable RTL exceeds size limit: {rel_name}')

    cand_clean = strip_comments(cand_text)
    base_clean = strip_comments(base_text)

    escape_pats = [
        (r'\$(?:fopen|fclose|fread|fwrite|fdisplay|fscanf|system|finish|stop|fatal|readmemh|readmemb|writememh|writememb|dumpfile|dumpvars|value\$plusargs|test\$plusargs)\b', 'forbidden_systask'),
        (r'\b(?:force|release|bind|defparam)\b', 'procedural_force_or_bind'),
        (r'\b(?:import|export)\s*"DPI', 'dpi_escape'),
        (r'\$root\b|\b(?:tb|grader|oracle|golden_ref|synth_top)\s*\.', 'hierarchical_harness_reference'),
        (r'`\s*(?:ifdef|ifndef|elsif)\s+SYNTHESIS\b', 'synthesis_macro_divergence'),
    ]
    for pat, label in escape_pats:
        if len(re.findall(pat, cand_clean, re.I)) > len(re.findall(pat, base_clean, re.I)):
            finish(result_path, 'FAIL', 'policy', f'Policy violation in {rel_name}: {label}')
    if re.search(r'`\s*(?:ifdef|ifndef|elsif)\s+(?:VERILATOR|SIMULATION|__ICARUS__|VCS|QUESTA)\b', cand_clean, re.I):
        finish(result_path, 'FAIL', 'policy', f'Policy violation in {rel_name}: simulator_macro_divergence')

    for inc in re.findall(r'`include\s+"([^"]+)"', cand_clean):
        if inc not in ALLOWED_INCLUDES:
            finish(result_path, 'FAIL', 'policy', f'Unauthorized include directive in {rel_name}: {inc}')

    if len(re.findall(rf'\bmodule\s+{re.escape(mod_name)}\b', cand_clean)) != 1 or len(re.findall(r'\bmodule\b', cand_clean)) != 1:
        finish(result_path, 'FAIL', 'structural', f'Expected single module declaration {mod_name} in {rel_name}')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--candidate', required=True)
    ap.add_argument('--seed', type=int, default=101)
    ap.add_argument('--result', required=True)
    args = ap.parse_args()

    result_path = pathlib.Path(args.result).resolve()
    cand_root = pathlib.Path(args.candidate)
    if cand_root.is_symlink() or not cand_root.is_dir():
        finish(result_path, 'FAIL', 'input_validation', 'Invalid candidate directory')
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

    cand_sources = {}
    for rel, mod_name in EDITABLE_SPECS:
        c_file = (cand_root / rel) if (cand_root / rel).exists() else (cand_root / rel.name)
        if not c_file.exists() or c_file.is_symlink() or not c_file.is_file() or not c_file.resolve().is_relative_to(cand_root):
            finish(result_path, 'FAIL', 'input_validation', f'Missing or invalid editable file: {rel}')
        c_txt = c_file.read_text(encoding='utf-8', errors='replace')
        b_txt = (PUB_DIR / rel).read_text(encoding='utf-8')
        screen_source(c_txt, b_txt, mod_name, str(rel), result_path)
        cand_sources[rel] = c_txt

    try:
        with tempfile.TemporaryDirectory(prefix='case_22016_grade_') as td:
            work = pathlib.Path(td)
            shutil.copytree(PUB_DIR / 'code', work / 'code')
            for rel, txt in cand_sources.items():
                (work / rel).write_text(txt, encoding='utf-8')
            shutil.copyfile(PRIV_DIR / 'tests/tb.sv', work / 'tb.sv')
            shutil.copyfile(PRIV_DIR / 'tests/synth_top.sv', work / 'synth_top.sv')

            env = {
                'PATH': f'{TOOLS_DIR}/verilator-v5.038/bin:{TOOLS_DIR}/oss-cad-suite/bin:/usr/bin:/bin',
                'HOME': str(work),
                'TMPDIR': str(work),
                'CC': '/usr/bin/gcc',
                'CXX': '/usr/bin/g++',
            }

            cmd_comp = [
                str(VERILATOR),
                '--binary', '-j', '2', '-O1', '-CFLAGS', '-O0',
                '--output-split', '8000',
                '-Wno-fatal', '-Wno-ENUMVALUE', '-Wno-TIMESCALEMOD', '-DSYNTHESIS',
                '-Icode/include',
                '--top-module', 'tb',
                '--Mdir', str(work / 'obj_dir'),
                *SIM_RTL_ORDER,
                'tb.sv',
            ]
            r_comp = subprocess.run(cmd_comp, cwd=work, env=env, capture_output=True, text=True, timeout=240)
            if r_comp.returncode != 0 or not (work / 'obj_dir/Vtb').is_file():
                tail = (r_comp.stdout + '\n' + r_comp.stderr).strip()[-1500:]
                finish(result_path, 'FAIL', 'compile', f'Verilator compile failed: {tail}')

            r_sim = subprocess.run([str(work / 'obj_dir/Vtb'), f'+seed={args.seed}'], cwd=work, env=env, capture_output=True, text=True, timeout=120)
            sim_out = (r_sim.stdout + '\n' + r_sim.stderr).strip()
            if r_sim.returncode != 0 or f'PASS seed={args.seed}' not in sim_out:
                finish(result_path, 'FAIL', 'functional', f'Simulation failed (seed={args.seed}): {sim_out[-1500:]}')

            if args.seed == 101:
                stat_json = work / 'stat.json'
                ys_script = (
                    'read_slang -DSYNTHESIS --ignore-assertions --unroll-limit 20000 '
                    '-Icode/include --top synth_top '
                    + ' '.join(SYNTH_RTL_ORDER) + ' synth_top.sv; '
                    'hierarchy -check -top synth_top; proc; opt_clean; check -assert; '
                    f'tee -q -o {stat_json} stat -json'
                )
                r_ys = subprocess.run([str(YOSYS), '-m', 'slang', '-p', ys_script], cwd=work, env=env, capture_output=True, text=True, timeout=240)
                if r_ys.returncode != 0 or not stat_json.is_file():
                    tail = (r_ys.stdout + '\n' + r_ys.stderr).strip()[-1500:]
                    finish(result_path, 'FAIL', 'synthesis', f'Yosys slang synthesis check failed: {tail}')
                st = json.loads(stat_json.read_text())
                latches = sum(int(v) for k, v in st.get('design', {}).get('num_cells_by_type', {}).items() if 'dlatch' in k.lower() or 'latch' in k.lower())
                if latches > 0:
                    finish(result_path, 'FAIL', 'synthesis', f'Unintended latch inference detected ({latches} latches)')

            finish(result_path, 'PASS', 'functional', f'All RVV multi-VFU chaining, scoreboard, queue-capacity, scalar-response, zero-vl, and CSR ordering checks passed (seed={args.seed})')
    except subprocess.TimeoutExpired:
        finish(result_path, 'FAIL', 'functional', f'Simulation or synthesis timed out (possible handshake deadlock) for seed={args.seed}')
    except OSError as exc:
        finish(result_path, 'ERROR', 'environment', f'OS error: {exc}')


if __name__ == '__main__':
    main()
