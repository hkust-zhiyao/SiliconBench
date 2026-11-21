#!/usr/bin/env python3
"""Private isolated grader for case_25005 (Caliptra HMAC-384/512 & SP 800-90A HMAC_DRBG)."""
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

EDITABLE_MODULES = {
    'code/hmac.sv': 'hmac',
    'code/hmac_ctrl.sv': 'hmac_ctrl',
    'code/hmac_drbg.sv': 'hmac_drbg',
}

PKG_ORDER = [
    'caliptra_prim_util_pkg.sv',
    'caliptra_prim_mubi_pkg.sv',
    'caliptra_prim_pkg.sv',
    'caliptra_prim_cipher_pkg.sv',
    'ahb_defines_pkg.sv',
    'kv_defines_pkg.sv',
    'sha512_masked_defines_pkg.sv',
    'hmac_param_pkg.sv',
    'hmac_reg_pkg.sv',
]

HEADER_EXCLUDE = set(PKG_ORDER) | {
    'caliptra_prim_assert.sv',
    'caliptra_prim_flop_macros.sv',
}


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
    text = re.sub(r'(?is)//\s*pragma\s+translate_off.*?//\s*pragma\s+translate_on', ' ', text)
    text = re.sub(r'/\*.*?\*/|//[^\n]*|"(?:\\.|[^"\\])*"', ' ', text, flags=re.S)
    return text


def strip_includes_and_comments(text: str) -> str:
    text = re.sub(r'(?is)//\s*pragma\s+translate_off.*?//\s*pragma\s+translate_on', ' ', text)
    text = re.sub(r'/\*.*?\*/|//[^\n]*', ' ', text, flags=re.S)
    return text


def screen_candidate_source(
    rel_name: str,
    expected_mod: str,
    cand_text: str,
    base_text: str,
    result_path: pathlib.Path,
):
    if len(cand_text.encode('utf-8')) > 300_000:
        finish(result_path, 'FAIL', 'policy', f'{rel_name} exceeds size limit')

    cand_no_cmt = strip_includes_and_comments(cand_text)
    base_no_cmt = strip_includes_and_comments(base_text)

    cand_incs = set(re.findall(r'`include\s+"([^"]+)"', cand_no_cmt))
    base_incs = set(re.findall(r'`include\s+"([^"]+)"', base_no_cmt))
    extra_incs = cand_incs - base_incs
    if extra_incs:
        finish(result_path, 'FAIL', 'policy', f'Unauthorized include directive in {rel_name}: {sorted(extra_incs)}')

    cand_clean = strip_comments_and_strings(cand_text)
    base_clean = strip_comments_and_strings(base_text)

    escape_pats = [
        (r'\$(?:fopen|fclose|fread|fwrite|fdisplay|fscanf|system|finish|stop|fatal|readmemh|readmemb|writememh|writememb|dumpfile|dumpvars|value\$plusargs|test\$plusargs)\b', 'forbidden_systask'),
        (r'\b(?:force|release|bind|defparam)\b', 'procedural_force_or_bind'),
        (r'\b(?:import|export)\s*"DPI', 'dpi_escape'),
        (r'\$root\b|\b(?:tb|tb_drbg_zero|u_hmac_ctrl|u_drbg_std|u_drbg_eq|u_drbg_plus1|u_drbg_chain|grader|oracle|golden_ref)\s*\.', 'hierarchical_harness_reference'),
        (r'`\s*(?:ifdef|ifndef|elsif)\s+(?:VERILATOR|SYNTHESIS|SIMULATION|__ICARUS__|VCS|QUESTA)\b', 'simulator_macro_divergence'),
    ]
    for pat, label in escape_pats:
        if len(re.findall(pat, cand_clean, re.I)) > len(re.findall(pat, base_clean, re.I)):
            finish(result_path, 'FAIL', 'policy', f'Policy violation in {rel_name}: {label}')

    if (
        len(re.findall(rf'\bmodule\s+{re.escape(expected_mod)}\b', cand_clean)) != 1
        or len(re.findall(r'\bmodule\b', cand_clean)) != 1
    ):
        finish(result_path, 'FAIL', 'structural', f'{rel_name} must declare exactly one module `{expected_mod}`')


def resolve_candidate_files(cand_root: pathlib.Path, result_path: pathlib.Path) -> dict[str, str]:
    editable_rel_set = set(EDITABLE_MODULES.keys())
    code_dir = cand_root / 'code'

    if code_dir.is_symlink():
        finish(result_path, 'FAIL', 'policy', 'Symlinked code directory is forbidden')

    # Check read-only integrity if full public/code tree is present
    if code_dir.is_dir():
        has_readonly = any(
            (cand_root / ref.relative_to(PUB_DIR)).exists()
            for ref in (PUB_DIR / 'code').iterdir()
            if ref.is_file() and str(ref.relative_to(PUB_DIR)) not in editable_rel_set
        )
        if has_readonly:
            for ref_file in sorted((PUB_DIR / 'code').rglob('*')):
                if not ref_file.is_file():
                    continue
                rel_str = str(ref_file.relative_to(PUB_DIR))
                if rel_str in editable_rel_set:
                    continue
                c_file = cand_root / rel_str
                if not c_file.is_file() or c_file.is_symlink() or sha256_bytes(c_file) != sha256_bytes(ref_file):
                    finish(result_path, 'FAIL', 'policy', f'Protected file modified or missing: {rel_str}')

    cand_sources: dict[str, str] = {}
    for rel_str, mod_name in EDITABLE_MODULES.items():
        fname = pathlib.PurePosixPath(rel_str).name
        if (cand_root / rel_str).exists() or (cand_root / rel_str).is_symlink():
            c_path = cand_root / rel_str
        elif (cand_root / fname).exists() or (cand_root / fname).is_symlink():
            c_path = cand_root / fname
        else:
            finish(result_path, 'FAIL', 'input_validation', f'Missing editable file {rel_str}')

        if c_path.is_symlink() or not c_path.is_file() or not c_path.resolve().is_relative_to(cand_root):
            finish(result_path, 'FAIL', 'policy', f'Invalid or symlinked candidate source file: {rel_str}')

        cand_text = c_path.read_text(encoding='utf-8', errors='replace')
        base_text = (PUB_DIR / rel_str).read_text(encoding='utf-8')
        screen_candidate_source(rel_str, mod_name, cand_text, base_text, result_path)
        cand_sources[fname] = cand_text

    return cand_sources


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--candidate', required=True)
    ap.add_argument('--seed', type=int, default=101)
    ap.add_argument('--result', required=True)
    args, _ = ap.parse_known_args()

    result_path = pathlib.Path(args.result).resolve()
    cand_root = pathlib.Path(args.candidate)
    if cand_root.is_symlink() or not cand_root.is_dir():
        finish(result_path, 'FAIL', 'input_validation', 'Invalid or symlinked candidate directory')
    cand_root = cand_root.resolve()

    cand_sources = resolve_candidate_files(cand_root, result_path)

    try:
        with tempfile.TemporaryDirectory(prefix='case_25005_grade_') as td:
            work = pathlib.Path(td)
            code_work = work / 'code'
            code_work.mkdir(parents=True, exist_ok=True)

            for ref_file in (PUB_DIR / 'code').iterdir():
                if ref_file.is_file():
                    shutil.copyfile(ref_file, code_work / ref_file.name)

            for fname, content in cand_sources.items():
                (code_work / fname).write_text(content, encoding='utf-8')

            shutil.copyfile(PRIV_DIR / 'tests/tb.sv', work / 'tb.sv')
            shutil.copyfile(PRIV_DIR / 'tests/tb_drbg_zero.sv', work / 'tb_drbg_zero.sv')

            v_env = {
                'PATH': f'{TOOLS_DIR}/verilator-v5.038/bin:{TOOLS_DIR}/oss-cad-suite/bin:/usr/bin:/bin',
                'HOME': str(work),
                'TMPDIR': str(work),
                'CC': '/usr/bin/gcc',
                'CXX': '/usr/bin/g++',
            }

            hdl_files = [str(code_work / p) for p in PKG_ORDER] + sorted(
                str(p)
                for p in list(code_work.glob('*.v')) + list(code_work.glob('*.sv'))
                if p.name not in HEADER_EXCLUDE
            )

            # 1. Compile & run full-hierarchy Verilator testbench (hmac_ctrl + hmac + hmac_drbg)
            obj_tb = work / 'obj_tb'
            cmd_comp = [
                str(VERILATOR),
                '--binary', '--timing', '-sv', '-Wno-fatal', '-O1', '-CFLAGS', '-O0', '-j', '4',
                f'-I{code_work}',
                '--top-module', 'tb',
                '--Mdir', str(obj_tb),
                '-o', 'Vtb',
            ] + hdl_files + [str(work / 'tb.sv')]

            r_comp = subprocess.run(cmd_comp, cwd=work, env=v_env, capture_output=True, text=True, timeout=240)
            if r_comp.returncode != 0 or not (obj_tb / 'Vtb').is_file():
                tail = (r_comp.stdout + '\n' + r_comp.stderr).strip()[-1500:]
                finish(result_path, 'FAIL', 'synthesis', f'Verilator elaboration/compile failed: {tail}')

            try:
                r_sim = subprocess.run(
                    [str(obj_tb / 'Vtb'), f'+SEED={args.seed}', f'+verilator+seed+{args.seed}'],
                    cwd=work, env=v_env, capture_output=True, text=True, timeout=150,
                )
            except subprocess.TimeoutExpired:
                finish(result_path, 'FAIL', 'functional', f'Simulation timed out on tb (seed={args.seed})')

            sim_out = (r_sim.stdout + '\n' + r_sim.stderr).strip()
            if r_sim.returncode != 0 or f'ALL_TESTS_PASSED:' not in sim_out or f'seed={args.seed}' not in sim_out:
                finish(result_path, 'FAIL', 'functional', f'Functional verification failed (seed={args.seed}): {sim_out[-1500:]}')

            # 2. Compile & run exact zero-scalar rejection DRBG unit testbench
            obj_zero = work / 'obj_zero'
            cmd_zero = [
                str(VERILATOR),
                '--binary', '--timing', '-sv', '-Wno-fatal', '-O1', '-CFLAGS', '-O0', '-j', '2',
                f'-I{code_work}',
                '--top-module', 'tb_drbg_zero',
                '--Mdir', str(obj_zero),
                '-o', 'Vtb_zero',
                str(code_work / 'hmac_drbg.sv'),
                str(work / 'tb_drbg_zero.sv'),
            ]
            r_zcomp = subprocess.run(cmd_zero, cwd=work, env=v_env, capture_output=True, text=True, timeout=120)
            if r_zcomp.returncode != 0 or not (obj_zero / 'Vtb_zero').is_file():
                tail = (r_zcomp.stdout + '\n' + r_zcomp.stderr).strip()[-1200:]
                finish(result_path, 'FAIL', 'synthesis', f'Zero-scalar DRBG harness compile failed: {tail}')

            try:
                r_zsim = subprocess.run(
                    [str(obj_zero / 'Vtb_zero'), f'+verilator+seed+{args.seed}'],
                    cwd=work, env=v_env, capture_output=True, text=True, timeout=30,
                )
            except subprocess.TimeoutExpired:
                finish(result_path, 'FAIL', 'functional', 'Zero-scalar DRBG rejection test timed out')

            zsim_out = (r_zsim.stdout + '\n' + r_zsim.stderr).strip()
            if r_zsim.returncode != 0 or 'ZERO_SCALAR_REJECTION_PASSED' not in zsim_out:
                finish(result_path, 'FAIL', 'functional', f'DRBG zero-scalar rejection failed: {zsim_out[-1200:]}')

            # 3. Yosys + Slang synthesis sanity check (0 latches, 0 combinational loops) on both top modules
            for top_mod in ('hmac_ctrl', 'hmac_drbg'):
                y_script = (
                    f'read_slang -DSYNTHESIS --ignore-assertions -I{code_work} --top {top_mod} '
                    + ' '.join(hdl_files)
                    + '; proc; opt -fast; check -assert; scc -expect 0; '
                    + 'select -assert-none t:$adlatch t:$dlatch t:$dlatchsr t:$sr'
                )
                r_yosys = subprocess.run(
                    [str(YOSYS), '-m', 'slang', '-p', y_script],
                    cwd=work, env=v_env, capture_output=True, text=True, timeout=120,
                )
                if r_yosys.returncode != 0:
                    tail = (r_yosys.stdout + '\n' + r_yosys.stderr).strip()[-1500:]
                    finish(result_path, 'FAIL', 'synthesis', f'Yosys synthesis/latch/SCC check failed on {top_mod}: {tail}')

            finish(
                result_path,
                'PASS',
                'functional',
                f'Passed SP 800-90A P-384 DRBG KATs & boundary/zero/chain rejection, HMAC-384/512 KV isolation, AHB word guards, zeroize/debug sanitization, and Yosys synthesis (seed={args.seed})',
            )
    except subprocess.TimeoutExpired:
        finish(result_path, 'FAIL', 'synthesis', 'Compilation or synthesis timed out')
    except OSError as exc:
        finish(result_path, 'ERROR', 'environment', f'OS error: {exc}')


if __name__ == '__main__':
    main()
