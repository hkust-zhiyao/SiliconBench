#!/usr/bin/env python3
"""Private isolated grader for case_23006 (NVDLA PDP 1D Multi-Precision Pooling + Split-Stripe + NaN Engine)."""
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
IVERILOG = TOOLS_DIR / 'iverilog-v13' / 'bin' / 'iverilog'
VVP = TOOLS_DIR / 'iverilog-v13' / 'bin' / 'vvp'
YOSYS = TOOLS_DIR / 'oss-cad-suite' / 'bin' / 'yosys'

EDITABLE_FILES = {
    pathlib.Path('code/NV_NVDLA_PDP_nan.v'): 'NV_NVDLA_PDP_nan',
    pathlib.Path('code/NV_NVDLA_PDP_CORE_unit1d.v'): 'NV_NVDLA_PDP_CORE_unit1d',
    pathlib.Path('code/NV_NVDLA_PDP_CORE_cal1d.v'): 'NV_NVDLA_PDP_CORE_cal1d',
}

V_CLOSURE = [
    'NV_BLKBOX_SINK.v',
    'CKLNQD12.v',
    'NV_CLK_gate_power.v',
    'HLS_fp16_to_fp17.v',
    'HLS_fp17_add.v',
    'cal1d_fp16_pool_sum.v',
    'NV_NVDLA_PDP_nan.v',
    'NV_NVDLA_PDP_CORE_unit1d.v',
    'NV_NVDLA_PDP_CORE_cal1d.v',
]

PROTECTED_MODS = {
    'tb', 'HLS_fp16_to_fp17', 'HLS_fp17_add', 'cal1d_fp16_pool_sum',
    'NV_CLK_gate_power', 'CKLNQD12', 'NV_BLKBOX_SINK',
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
    text = re.sub(r'(?is)//\s*(?:pragma|synopsys)\s+translate_off.*?//\s*(?:pragma|synopsys)\s+translate_on', '', text)
    text = re.sub(r'/\*.*?\*/|//[^\n]*|"(?:\\.|[^"\\])*"', ' ', text, flags=re.S)
    return text


def screen_candidate_source(rel: pathlib.Path, mod_name: str, cand_text: str, base_text: str, result_path: pathlib.Path):
    if len(cand_text.encode('utf-8')) > 800_000:
        finish(result_path, 'FAIL', 'policy', f'Editable RTL {rel} exceeds size limit')

    cand_clean = strip_comments_and_strings(cand_text)
    base_clean = strip_comments_and_strings(base_text)

    escape_pats = [
        (r'\$(?:fopen|fclose|fread|fwrite|fdisplay|fscanf|system|finish|stop|readmemh|readmemb|writememh|writememb|dumpfile|dumpvars|value\$plusargs|test\$plusargs)\b', 'forbidden_systask'),
        (r'\b(?:force|release|bind|defparam)\b', 'procedural_force_or_bind'),
        (r'\b(?:import|export)\s*"DPI', 'dpi_escape'),
        (r'\$root\b|\b(?:tb|grader|oracle|golden_ref|exp_fifo|cube_mem)\s*\.', 'hierarchical_harness_reference'),
        (r'`\s*(?:ifdef|ifndef|elsif)\s+(?:VERILATOR|SYNTHESIS|SIMULATION|__ICARUS__|VCS|QUESTA)\b', 'simulator_macro_divergence'),
    ]
    for pat, label in escape_pats:
        if len(re.findall(pat, cand_clean, re.I)) > len(re.findall(pat, base_clean, re.I)):
            finish(result_path, 'FAIL', 'policy', f'Policy violation in {rel}: {label}')

    base_incs = set(re.findall(r'`include\s+"([^"]+)"', base_clean))
    for inc in re.findall(r'`include\s+"([^"]+)"', cand_clean):
        p = pathlib.PurePosixPath(inc)
        if p.is_absolute() or '..' in p.parts or (inc not in base_incs and not (PUB_DIR / 'code' / inc).is_file()):
            finish(result_path, 'FAIL', 'policy', f'Unauthorized include directive in {rel}: {inc}')

    if len(re.findall(rf'\bmodule\s+{mod_name}\b', cand_clean)) != 1:
        finish(result_path, 'FAIL', 'structural', f'Expected module declaration `{mod_name}` in {rel}')

    for pmod in PROTECTED_MODS:
        if re.search(rf'\bmodule\s+{pmod}\b', cand_clean):
            finish(result_path, 'FAIL', 'policy', f'Redeclaration of protected module `{pmod}` in {rel}')


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

    cand_sources = {}
    for rel, mod_name in EDITABLE_FILES.items():
        if (cand_root / rel).exists():
            c_file = cand_root / rel
        elif (cand_root / rel.name).exists():
            c_file = cand_root / rel.name
        else:
            finish(result_path, 'FAIL', 'input_validation', f'Missing editable file {rel}')
        if c_file.is_symlink() or not c_file.is_file() or not c_file.resolve().is_relative_to(cand_root):
            finish(result_path, 'FAIL', 'input_validation', f'Invalid or symlinked candidate source {rel}')
        cand_sources[rel] = (mod_name, c_file.read_text(encoding='utf-8', errors='replace'))

    # Verify non-editable files were not tampered with if full code/ tree is present
    if (cand_root / 'code').is_dir():
        present_non_edit = [
            p for p in (cand_root / 'code').rglob('*')
            if p.is_file() and p.relative_to(cand_root) not in EDITABLE_FILES
        ]
        if present_non_edit:
            for ref_file in sorted((PUB_DIR / 'code').rglob('*')):
                if not ref_file.is_file():
                    continue
                rel = ref_file.relative_to(PUB_DIR)
                if rel in EDITABLE_FILES:
                    continue
                c_file = cand_root / rel
                if not c_file.is_file() or c_file.is_symlink() or sha256_bytes(c_file) != sha256_bytes(ref_file):
                    finish(result_path, 'FAIL', 'policy', f'Protected file modified or missing: {rel}')

    for rel, (mod_name, cand_text) in cand_sources.items():
        base_text = (PUB_DIR / rel).read_text(encoding='utf-8')
        screen_candidate_source(rel, mod_name, cand_text, base_text, result_path)

    try:
        with tempfile.TemporaryDirectory(prefix='case_23006_grade_') as td:
            work = pathlib.Path(td)
            code_dir = work / 'code'
            code_dir.mkdir(parents=True, exist_ok=True)

            for ref_file in sorted((PUB_DIR / 'code').iterdir()):
                if ref_file.is_file():
                    shutil.copyfile(ref_file, code_dir / ref_file.name)

            for rel, (_, cand_text) in cand_sources.items():
                (work / rel).write_text(cand_text, encoding='utf-8')

            shutil.copyfile(PRIV_DIR / 'tests/tb.sv', work / 'tb.sv')

            env = {
                'PATH': f'{TOOLS_DIR}/iverilog-v13/bin:{TOOLS_DIR}/oss-cad-suite/bin:/usr/bin:/bin',
                'HOME': str(work),
                'TMPDIR': str(work),
            }

            v_paths = [str(code_dir / f) for f in V_CLOSURE]

            # Step 1: Yosys elaboration & latch-free synthesis check on both NV_NVDLA_PDP_nan and NV_NVDLA_PDP_CORE_cal1d
            for top_mod in ('NV_NVDLA_PDP_nan', 'NV_NVDLA_PDP_CORE_cal1d'):
                ys_script = (
                    f'read_verilog -DVERILINT -DSYNTHESIS -DDESIGNWARE_NOEXIST -DVLIB_BYPASS_POWER_CG -I{code_dir} '
                    + ' '.join(v_paths) + '; '
                    f'hierarchy -check -top {top_mod}; proc; opt_clean; '
                    'check -assert; select -assert-none */t:$dlatch*'
                )
                r_syn = subprocess.run(
                    [str(YOSYS), '-q', '-p', ys_script],
                    cwd=work, env=env, capture_output=True, text=True, timeout=120
                )
                if r_syn.returncode != 0:
                    tail = (r_syn.stdout + '\n' + r_syn.stderr).strip()[-1500:]
                    finish(result_path, 'FAIL', 'synthesis', f'Yosys synthesis/latch check failed on {top_mod}: {tail}')

            # Step 2: Icarus Verilog compile & multi-layer functional verification
            vvp_bin = work / 'sim.vvp'
            cmd_comp = [
                str(IVERILOG),
                '-g2012',
                '-DVERILINT', '-DSYNTHESIS', '-DDESIGNWARE_NOEXIST',
                f'-I{code_dir}',
                '-s', 'tb',
                '-o', str(vvp_bin),
                *v_paths,
                str(work / 'tb.sv'),
            ]
            r_comp = subprocess.run(cmd_comp, cwd=work, env=env, capture_output=True, text=True, timeout=90)
            if r_comp.returncode != 0 or not vvp_bin.is_file():
                tail = (r_comp.stdout + '\n' + r_comp.stderr).strip()[-1500:]
                finish(result_path, 'FAIL', 'compile', f'iverilog compile failed: {tail}')

            r_sim = subprocess.run(
                [str(VVP), str(vvp_bin), f'+seed={args.seed}'],
                cwd=work, env=env, capture_output=True, text=True, timeout=180
            )
            sim_out = (r_sim.stdout + '\n' + r_sim.stderr).strip()
            if r_sim.returncode != 0 or f'PASS seed={args.seed}' not in sim_out:
                finish(result_path, 'FAIL', 'functional', f'Simulation failed (seed={args.seed}): {sim_out[-1500:]}')

            finish(
                result_path, 'PASS', 'functional',
                f'Yosys latch-free synthesis clean and all 18 multi-precision/split-stripe/NaN PDP 1D pooling layers passed for seed={args.seed}'
            )
    except subprocess.TimeoutExpired:
        finish(result_path, 'FAIL', 'timeout', 'Synthesis, compilation, or simulation timed out')
    except OSError as exc:
        finish(result_path, 'ERROR', 'environment', f'OS error: {exc}')


if __name__ == '__main__':
    main()
