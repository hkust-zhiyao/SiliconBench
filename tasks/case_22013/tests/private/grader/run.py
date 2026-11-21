#!/usr/bin/env python3
"""Private isolated grader for case_22013 (Ara VLSU burst splitting, lane rotation & memory ordering)."""
import argparse
import hashlib
import json
import os
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

EDITABLE_MAP = {
    pathlib.Path('code/vlsu.sv'): 'vlsu',
    pathlib.Path('code/addrgen.sv'): 'addrgen',
    pathlib.Path('code/vldu.sv'): 'vldu',
    pathlib.Path('code/vstu.sv'): 'vstu',
}

RTL_COMPILE_ORDER = [
    'cf_math_pkg.sv',
    'riscv_pkg.sv',
    'config_pkg.sv',
    'cv64a6_imafdcv_sv39_config_pkg.sv',
    'axi_pkg.sv',
    'fpnew_pkg.sv',
    'rvv_pkg.sv',
    'ara_pkg.sv',
    'build_config_pkg.sv',
    'lzc.sv',
    'onehot_to_bin.sv',
    'rr_arb_tree.sv',
    'fifo_v3.sv',
    'spill_register_flushable.sv',
    'spill_register.sv',
    'fall_through_register.sv',
    'stream_arbiter_flushable.sv',
    'stream_arbiter.sv',
    'stream_mux.sv',
    'stream_demux.sv',
    'stream_xbar.sv',
    'counter.sv',
    'delta_counter.sv',
    'axi_cut.sv',
    'addrgen.sv',
    'vldu.sv',
    'vstu.sv',
    'vlsu.sv',
]

ALLOWED_INCLUDES = {
    'axi/assign.svh',
    'axi/typedef.svh',
    'common_cells/registers.svh',
    'common_cells/assertions.svh',
    'ara_typedef.svh',
}


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


def screen_candidate_source(rel_path: pathlib.Path, expected_mod: str, cand_text: str, base_text: str, result_path: pathlib.Path):
    if len(cand_text.encode('utf-8')) > 400_000:
        finish(result_path, 'FAIL', 'policy', f'Editable RTL exceeds size limit: {rel_path}')

    cand_clean = strip_comments_and_strings(cand_text)
    base_clean = strip_comments_and_strings(base_text)

    escape_pats = [
        (r'\$(?:fopen|fclose|fread|fwrite|fdisplay|fscanf|system|finish|stop|readmemh|readmemb|writememh|writememb|dumpfile|dumpvars|value\$plusargs|test\$plusargs)\b', 'forbidden_systask'),
        (r'\b(?:force|release|bind|defparam)\b', 'procedural_force_or_bind'),
        (r'\b(?:import|export)\s*"DPI', 'dpi_escape'),
        (r'\$root\b|\b(?:tb|gen_env|grader|oracle|golden_ref|ref_mem|ref_vrf)\s*\.', 'hierarchical_harness_reference'),
        (r'`\s*(?:ifdef|ifndef|elsif)\s+(?:VERILATOR|SYNTHESIS|SIMULATION|__ICARUS__|VCS|QUESTA)\b', 'simulator_macro_divergence'),
    ]
    for pat, label in escape_pats:
        if len(re.findall(pat, cand_clean, re.I)) > len(re.findall(pat, base_clean, re.I)):
            finish(result_path, 'FAIL', 'policy', f'Policy violation in {rel_path}: {label}')

    for inc in re.findall(r'`include\s+"([^"]+)"', cand_clean):
        if inc not in ALLOWED_INCLUDES:
            finish(result_path, 'FAIL', 'policy', f'Unauthorized include directive in {rel_path}: {inc}')

    if len(re.findall(rf'\bmodule\s+{re.escape(expected_mod)}\b', cand_clean)) != 1 or len(re.findall(r'\bmodule\b', cand_clean)) != 1:
        finish(result_path, 'FAIL', 'structural', f'Expected exactly one module declaration `{expected_mod}` in {rel_path}')


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

    cand_sources: dict[pathlib.Path, str] = {}
    for rel_path, expected_mod in EDITABLE_MAP.items():
        if (cand_root / rel_path).exists():
            c_file = cand_root / rel_path
        elif (cand_root / rel_path.name).exists():
            c_file = cand_root / rel_path.name
        else:
            finish(result_path, 'FAIL', 'input_validation', f'Missing editable file {rel_path}')

        if c_file.is_symlink() or not c_file.is_file() or not c_file.resolve().is_relative_to(cand_root):
            finish(result_path, 'FAIL', 'input_validation', f'Invalid or symlinked candidate source file: {rel_path}')

        c_text = c_file.read_text(encoding='utf-8', errors='replace')
        b_text = (PUB_DIR / rel_path).read_text(encoding='utf-8')
        screen_candidate_source(rel_path, expected_mod, c_text, b_text, result_path)
        cand_sources[rel_path] = c_text

    is_full_workspace = (cand_root / 'issue.md').exists() or (cand_root / 'BUILD.md').exists()
    if (cand_root / 'code').is_dir():
        for ref_file in sorted((PUB_DIR / 'code').rglob('*')):
            if not ref_file.is_file():
                continue
            rel = ref_file.relative_to(PUB_DIR)
            if rel in EDITABLE_MAP:
                continue
            c_file = cand_root / rel
            if c_file.is_symlink():
                finish(result_path, 'FAIL', 'policy', f'Protected file symlinked: {rel}')
            if c_file.exists():
                if not c_file.is_file() or sha256_bytes(c_file) != sha256_bytes(ref_file):
                    finish(result_path, 'FAIL', 'policy', f'Protected file modified: {rel}')
            elif is_full_workspace:
                finish(result_path, 'FAIL', 'policy', f'Protected file deleted from workspace: {rel}')

    try:
        with tempfile.TemporaryDirectory(prefix='case_22013_grade_') as td:
            work = pathlib.Path(td)
            code_dir = work / 'code'
            shutil.copytree(PUB_DIR / 'code', code_dir)
            for rel_path, c_text in cand_sources.items():
                (work / rel_path).write_text(c_text, encoding='utf-8')

            shutil.copyfile(PRIV_DIR / 'tests' / 'tb.sv', work / 'tb.sv')
            shutil.copyfile(PRIV_DIR / 'tests' / 'vlsu_synth_wrap.sv', work / 'vlsu_synth_wrap.sv')

            env = {
                'PATH': f'{TOOLS_DIR}/verilator-v5.038/bin:{TOOLS_DIR}/oss-cad-suite/bin:/usr/bin:/bin',
                'HOME': str(work),
                'TMPDIR': str(work),
                'CC': '/usr/bin/gcc',
                'CXX': '/usr/bin/g++',
            }

            rtl_files = [str(code_dir / fn) for fn in RTL_COMPILE_ORDER]

            # 1. Yosys + slang elaboration, structural check, and zero-latch verification
            stat_json = work / 'stat.json'
            yosys_script = (
                f"read_slang --top vlsu_synth_wrap --ignore-assertions --ignore-timing --ignore-initial "
                f"-I {code_dir / 'include'} {' '.join(rtl_files)} {work / 'vlsu_synth_wrap.sv'}; "
                f"hierarchy -check -top vlsu_synth_wrap; "
                f"proc; opt_expr; opt_clean; check -assert; "
                f"tee -o {stat_json} stat -json"
            )
            r_syn = subprocess.run(
                [str(YOSYS), '-m', 'slang', '-p', yosys_script],
                cwd=work, env=env, capture_output=True, text=True, timeout=90
            )
            if r_syn.returncode != 0 or not stat_json.is_file():
                tail = (r_syn.stdout + '\n' + r_syn.stderr).strip()[-1500:]
                finish(result_path, 'FAIL', 'synthesis', f'Yosys slang synthesis check failed: {tail}')

            stat_data = json.loads(stat_json.read_text(encoding='utf-8'))
            latch_cells = {}
            for mod_name, mod_info in stat_data.get('modules', {}).items():
                for cell_type, cnt in mod_info.get('num_cells_by_type', {}).items():
                    if 'latch' in cell_type.lower() and int(cnt) > 0:
                        latch_cells[f'{mod_name}:{cell_type}'] = int(cnt)
            if latch_cells:
                finish(result_path, 'FAIL', 'synthesis', f'Inferred latches forbidden in VLSU RTL: {latch_cells}')

            # 2. Verilator dual-bus-width AXI4 + 4-lane RVV functional regression
            cmd_comp = [
                str(VERILATOR),
                '--binary', '--timing', '-Wno-fatal', '-DSYNTHESIS',
                '--output-split', '15000',
                '-MAKEFLAGS', 'OPT_FAST=-O0 OPT_SLOW=-O0 -j2',
                '--top-module', 'tb',
                '--Mdir', str(work / 'obj'),
                f'-I{code_dir / "include"}',
                *rtl_files,
                str(work / 'tb.sv'),
            ]
            r_comp = subprocess.run(cmd_comp, cwd=work, env=env, capture_output=True, text=True, timeout=450)
            if r_comp.returncode != 0 or not (work / 'obj' / 'Vtb').is_file():
                tail = (r_comp.stdout + '\n' + r_comp.stderr).strip()[-1500:]
                finish(result_path, 'FAIL', 'compile', f'Verilator compile failed: {tail}')

            try:
                r_sim = subprocess.run(
                    [str(work / 'obj' / 'Vtb'), f'+seed={args.seed}'],
                    cwd=work, env=env, capture_output=True, text=True, timeout=180
                )
            except subprocess.TimeoutExpired:
                finish(result_path, 'FAIL', 'functional', f'Simulation timed out (hang/deadlock) for seed={args.seed}')
            sim_out = (r_sim.stdout + '\n' + r_sim.stderr).strip()
            if r_sim.returncode != 0 or f'TEST_PASSED (seed={args.seed})' not in sim_out or 'TEST_FAILED' in sim_out or '[ERR]' in sim_out:
                finish(result_path, 'FAIL', 'functional', f'Simulation failed (seed={args.seed}): {sim_out[-1500:]}')

            finish(
                result_path,
                'PASS',
                'functional',
                f'Yosys latch-free synthesis check and dual AxiDataWidth (128/64) VLSU AXI4 burst-splitting, vstart lane-rotation, and scatter/gather ordering suites passed for seed={args.seed}'
            )
    except subprocess.TimeoutExpired:
        finish(result_path, 'ERROR', 'environment', 'Synthesis, compilation, or simulation timed out')
    except OSError as exc:
        finish(result_path, 'ERROR', 'environment', f'OS error: {exc}')


if __name__ == '__main__':
    main()
