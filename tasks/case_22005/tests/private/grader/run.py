#!/usr/bin/env python3
"""Private isolated grader for case_22005 (Ara Mask Unit RVV 1.0 bit-scan, popcount & viota.m)."""
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

EDITABLES = [
    pathlib.Path('code/masku_operands.sv'),
    pathlib.Path('code/masku.sv'),
]

ALLOWED_INCLUDES = {
    'common_cells/registers.svh',
    'common_cells/assertions.svh',
    'ara/ara_typedef.svh',
}

PKG_AND_LIB_ORDER = [
    'config_pkg.sv',
    'cv64a6_imafdcv_sv39_config_pkg.sv',
    'riscv_pkg.sv',
    'cf_math_pkg.sv',
    'axi_pkg.sv',
    'fpnew_pkg.sv',
    'rvv_pkg.sv',
    'ara_pkg.sv',
    'spill_register_flushable.sv',
    'spill_register.sv',
    'delta_counter.sv',
    'lzc.sv',
    'popcount.sv',
    'fifo_v3.sv',
]


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


def strip_comments_and_strings(text: str) -> str:
    text = re.sub(r'(?is)//\s*pragma\s+translate_off.*?//\s*pragma\s+translate_on', '', text)
    text = re.sub(r'/\*.*?\*/|//[^\n]*', ' ', text, flags=re.S)
    return text


def screen_candidate_source(cand_text: str, base_text: str, expected_mod: str, result_path: pathlib.Path):
    if len(cand_text.encode('utf-8')) > 350_000:
        finish(result_path, 'FAIL', 'policy', f'Editable RTL {expected_mod} exceeds size limit')

    cand_clean = strip_comments_and_strings(cand_text)
    base_clean = strip_comments_and_strings(base_text)

    escape_pats = [
        (r'\$(?:fopen|fclose|fread|fwrite|fdisplay|fscanf|system|finish|stop|fatal|readmemh|readmemb|writememh|writememb|dumpfile|dumpvars|value\$plusargs|test\$plusargs)\b', 'forbidden_systask'),
        (r'\b(?:force|release|bind|defparam)\b', 'procedural_force_or_bind'),
        (r'\b(?:import|export)\s*"DPI', 'dpi_escape'),
        (r'\$root\b|\b(?:tb|i_dut|dut_vrf|ref_vrf|grader|oracle|synth_top)\s*\.', 'hierarchical_harness_reference'),
        (r'`\s*(?:ifdef|ifndef|elsif)\s+(?:VERILATOR|SYNTHESIS|SIMULATION|__ICARUS__|VCS|QUESTA)\b', 'simulator_macro_divergence'),
    ]
    for pat, label in escape_pats:
        if len(re.findall(pat, cand_clean, re.I)) > len(re.findall(pat, base_clean, re.I)):
            finish(result_path, 'FAIL', 'policy', f'Policy violation in {expected_mod}: {label}')

    for inc in re.findall(r'`include\s+"([^"]+)"', cand_clean):
        if inc not in ALLOWED_INCLUDES:
            finish(result_path, 'FAIL', 'policy', f'Unauthorized include directive in {expected_mod}: {inc}')

    if len(re.findall(rf'\bmodule\s+{re.escape(expected_mod)}\b', cand_clean)) != 1 or len(re.findall(r'\bmodule\b', cand_clean)) != 1:
        finish(result_path, 'FAIL', 'structural', f'Expected exactly one module declaration: {expected_mod}')


def run_yosys_check(work: pathlib.Path, env: dict, src_files: list[str], result_path: pathlib.Path):
    yosys_srcs = ' '.join(src_files + [str(work / 'synth_top.sv')])
    stat_json_path = work / 'yosys_stat.json'
    yosys_script = (
        f'read_slang -DSYNTHESIS --ignore-assertions --unroll-limit 20000 '
        f'-I{work / "include"} --top synth_top {yosys_srcs}; '
        f'hierarchy -check -top synth_top; '
        f'proc; opt_clean; check -assert; '
        f'tee -o {stat_json_path} stat -json'
    )
    r_syn = subprocess.run(
        [str(YOSYS), '-m', 'slang', '-p', yosys_script],
        cwd=work,
        env=env,
        capture_output=True,
        text=True,
        timeout=150,
    )
    syn_out = (r_syn.stdout + '\n' + r_syn.stderr).strip()
    if r_syn.returncode != 0 or not stat_json_path.is_file():
        finish(result_path, 'FAIL', 'synthesis', f'Yosys slang synthesis check failed: {syn_out[-1500:]}')

    try:
        stat_data = json.loads(stat_json_path.read_text(encoding='utf-8'))
    except json.JSONDecodeError as exc:
        finish(result_path, 'FAIL', 'synthesis', f'Malformed Yosys stat JSON: {exc}')

    latch_cells = 0
    for mod_info in stat_data.get('modules', {}).values():
        for cell_type, count in mod_info.get('num_cells_by_type', {}).items():
            if 'dlatch' in cell_type.lower() or 'latch' in cell_type.lower():
                latch_cells += int(count)

    design_cells = stat_data.get('design', {}).get('num_cells_by_type', {})
    if latch_cells == 0:
        for cell_type, count in design_cells.items():
            if 'dlatch' in cell_type.lower() or 'latch' in cell_type.lower():
                latch_cells += int(count)

    if latch_cells > 0:
        finish(result_path, 'FAIL', 'synthesis', f'Unintended latch inference detected ({latch_cells} latch cells)')


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

    editable_set = set(EDITABLES)
    is_full_tree = (cand_root / 'issue.md').is_file() or sum(1 for _ in (cand_root / 'code').glob('*')) > len(EDITABLES) + 1 if (cand_root / 'code').is_dir() else False
    if is_full_tree:
        for ref_file in sorted((PUB_DIR / 'code').rglob('*')):
            if not ref_file.is_file():
                continue
            rel = ref_file.relative_to(PUB_DIR)
            if rel in editable_set:
                continue
            c_file = cand_root / rel
            if not c_file.is_file() or c_file.is_symlink() or sha256_bytes(c_file) != sha256_bytes(ref_file):
                finish(result_path, 'FAIL', 'policy', f'Protected file modified or missing: {rel}')

    cand_texts: dict[str, str] = {}
    for rel_ed, mod_name in [(EDITABLES[0], 'masku_operands'), (EDITABLES[1], 'masku')]:
        if (cand_root / rel_ed).exists():
            c_path = cand_root / rel_ed
        elif (cand_root / rel_ed.name).exists():
            c_path = cand_root / rel_ed.name
        else:
            finish(result_path, 'FAIL', 'input_validation', f'Missing editable file {rel_ed}')

        if c_path.is_symlink() or not c_path.is_file() or not c_path.resolve().is_relative_to(cand_root):
            finish(result_path, 'FAIL', 'input_validation', f'Invalid or symlinked candidate source file: {rel_ed}')

        c_txt = c_path.read_text(encoding='utf-8', errors='replace')
        b_txt = (PUB_DIR / rel_ed).read_text(encoding='utf-8')
        screen_candidate_source(c_txt, b_txt, mod_name, result_path)
        cand_texts[rel_ed.name] = c_txt

    try:
        with tempfile.TemporaryDirectory(prefix='case_22005_grade_') as td:
            work = pathlib.Path(td)
            shutil.copytree(PUB_DIR / 'code/include', work / 'include')
            for fname in PKG_AND_LIB_ORDER:
                shutil.copyfile(PUB_DIR / 'code' / fname, work / fname)

            (work / 'masku_operands.sv').write_text(cand_texts['masku_operands.sv'], encoding='utf-8')
            (work / 'masku.sv').write_text(cand_texts['masku.sv'], encoding='utf-8')
            shutil.copyfile(PRIV_DIR / 'tests/tb.sv', work / 'tb.sv')
            shutil.copyfile(PRIV_DIR / 'tests/sim_main.cpp', work / 'sim_main.cpp')
            shutil.copyfile(PRIV_DIR / 'tests/synth_top.sv', work / 'synth_top.sv')

            tool_env = {
                'PATH': f'{TOOLS_DIR}/verilator-v5.038/bin:{TOOLS_DIR}/oss-cad-suite/bin:/usr/bin:/bin',
                'HOME': str(work),
                'TMPDIR': str(work),
                'CC': '/usr/bin/gcc',
                'CXX': '/usr/bin/g++',
            }

            rtl_srcs = [str(work / f) for f in PKG_AND_LIB_ORDER] + [
                str(work / 'masku_operands.sv'),
                str(work / 'masku.sv'),
            ]

            cmd_comp = [
                str(VERILATOR),
                '--cc', '--exe', '--build', '-O2', '-CFLAGS', '-O1',
                '--output-split', '5000',
                '-Wno-fatal', '-DSYNTHESIS', '-j', '2',
                f'-I{work / "include"}',
                '--top-module', 'tb',
                '--Mdir', str(work / 'obj'),
                *rtl_srcs,
                str(work / 'tb.sv'),
                str(work / 'sim_main.cpp'),
            ]
            r_comp = subprocess.run(cmd_comp, cwd=work, env=tool_env, capture_output=True, text=True, timeout=360)
            if r_comp.returncode != 0 or not (work / 'obj/Vtb').is_file():
                tail = (r_comp.stdout + '\n' + r_comp.stderr).strip()[-1500:]
                finish(result_path, 'FAIL', 'compile', f'Verilator compile failed: {tail}')

            try:
                r_sim = subprocess.run(
                    [str(work / 'obj/Vtb'), f'+seed={args.seed}'],
                    cwd=work,
                    env=tool_env,
                    capture_output=True,
                    text=True,
                    timeout=240,
                )
            except subprocess.TimeoutExpired:
                finish(result_path, 'FAIL', 'functional', f'Simulation timed out (deadlock/hang) for seed={args.seed}')
            sim_out = (r_sim.stdout + '\n' + r_sim.stderr).strip()
            if r_sim.returncode != 0 or f'PASS seed={args.seed}' not in sim_out:
                finish(result_path, 'FAIL', 'functional', f'Simulation failed (seed={args.seed}): {sim_out[-1500:]}')

            if args.seed == 101:
                run_yosys_check(work, tool_env, rtl_srcs, result_path)

            finish(
                result_path,
                'PASS',
                'functional',
                f'All RVV 1.0 multi-lane mask scan, popcount, prefix-sum, policy, and synthesis checks passed for seed={args.seed}',
            )
    except subprocess.TimeoutExpired:
        finish(result_path, 'ERROR', 'environment', 'Compilation, simulation, or synthesis timed out')
    except OSError as exc:
        finish(result_path, 'ERROR', 'environment', f'OS error: {exc}')


if __name__ == '__main__':
    main()
