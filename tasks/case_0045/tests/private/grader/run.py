#!/usr/bin/env python3
"""Trusted isolated grader for case_0045 (TCDM Crossbar Stall Lock + Bounded Starvation Fairness + Latch-Free Synthesis)."""
import argparse
import hashlib
import json
import pathlib
import re
import resource
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


resource.setrlimit(resource.RLIMIT_CORE, (0, 0))

PRIV_DIR = pathlib.Path(__file__).resolve().parents[1]
TASK_DIR = PRIV_DIR.parent
PUB_CODE = TASK_DIR / 'public' / 'code'
TOOLS_ROOT = pathlib.Path(str(_sb_tools_dir()))
VERILATOR_BIN = TOOLS_ROOT / 'verilator-v5.038' / 'bin' / 'verilator'
YOSYS_BIN = TOOLS_ROOT / 'oss-cad-suite' / 'bin' / 'yosys'

EDITABLE_FILES = ('ArbitrationTree.sv', 'priority_Flag_Req.sv')
FIXED_FILES = (
    'parameters.v',
    'FanInPrimitive_Req.sv',
    'TestAndSet.sv',
    'AddressDecoder_Resp.sv',
    'RequestBlock1CH.sv',
)


def finish(result_path: pathlib.Path, verdict: str, stage: str, detail: str, **extra):
    payload = {
        'verdict': verdict,
        'stage': stage,
        'detail': detail,
        'reason': detail,
        **extra,
    }
    result_path.parent.mkdir(parents=True, exist_ok=True)
    result_path.write_text(json.dumps(payload, indent=2) + '\n')
    print(json.dumps(payload))
    raise SystemExit(0 if verdict == 'PASS' else 2 if verdict == 'ERROR' else 1)


def sha256_bytes(path: pathlib.Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def strip_comments_and_strings(text: str) -> str:
    text = re.sub(r'/\*.*?\*/|//[^\n]*|"(?:\\.|[^"\\])*"', ' ', text, flags=re.S)
    return text


def screen_rtl(filename: str, raw: str, result_path: pathlib.Path):
    if len(raw.encode('utf-8')) > 500_000:
        finish(result_path, 'FAIL', 'policy', f'{filename}: exceeds size limit')
    if re.search(r'(?i)(?:pragma|synthesis|synopsys|verilator)\s+(?:translate_)?(?:on|off)', raw):
        finish(result_path, 'FAIL', 'policy', f'{filename}: prohibited pragma translate_off/on')

    cleaned = strip_comments_and_strings(raw)
    escape_pats = [
        (r'\$(?!clog2\b|bits\b|signed\b|unsigned\b|size\b)[a-zA-Z_][\w$]*', 'forbidden_systask'),
        (r'\b(?:force|release|bind|defparam|initial|final|fork|join|join_any|join_none|wait|always_latch)\b', 'procedural_force_or_sim_construct'),
        (r'\b(?:import|export)\s*"DPI', 'dpi_escape'),
        (r'\$root\b|\b(?:tb|dut|grader|oracle|golden_ref)\s*\.', 'hierarchical_harness_reference'),
        (r'`\s*(?:ifdef|ifndef|elsif)\s+(?!GNT_BASED_FC\b)\w+', 'simulator_or_synthesis_macro_divergence'),
        (r'`\s*(?:define|undef)\b', 'prohibited_macro_definition'),
        (r'`\s*include\s+"(?!parameters\.v")[^"]+"', 'unauthorized_include'),
        (r'#\s*\d', 'prohibited_delay_control'),
    ]
    for pat, label in escape_pats:
        if re.search(pat, cleaned, re.I):
            finish(result_path, 'FAIL', 'policy', f'Policy violation in {filename}: {label}')

    expected_mod = filename[:-3]
    if len(re.findall(r'\bmodule\b', cleaned)) != 1 or not re.search(r'\bmodule\s+' + expected_mod + r'\b', cleaned):
        finish(result_path, 'FAIL', 'structural', f'Expected single module {expected_mod} in {filename}')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--candidate', required=True)
    ap.add_argument('--seed', type=int, required=True)
    ap.add_argument('--result', required=True)
    args = ap.parse_args()

    result_path = pathlib.Path(args.result).resolve()
    cand_in = pathlib.Path(args.candidate)
    if not cand_in.is_absolute() or any(x.is_symlink() for x in (cand_in, *cand_in.parents)) or not cand_in.is_dir():
        finish(result_path, 'FAIL', 'input_validation', 'Candidate must be an absolute non-symlink directory')
    cand_root = cand_in.resolve()

    for fname in FIXED_FILES:
        ref = PUB_CODE / fname
        for q in (cand_root / 'code' / fname, cand_root / fname):
            if q.exists() or q.is_symlink():
                if q.is_symlink() or not q.is_file() or not q.resolve().is_relative_to(cand_root):
                    finish(result_path, 'FAIL', 'policy', f'Invalid or symlinked protected dependency: {fname}')
                if sha256_bytes(q) != sha256_bytes(ref):
                    finish(result_path, 'FAIL', 'policy', f'Protected dependency changed: {fname}')

    cand_sources = {}
    for edit_name in EDITABLE_FILES:
        found = None
        for q in (cand_root / 'code' / edit_name, cand_root / edit_name):
            if q.exists() or q.is_symlink():
                found = q
                break
        if found is None:
            found = PUB_CODE / edit_name
        else:
            if found.is_symlink() or not found.is_file() or not found.resolve().is_relative_to(cand_root):
                finish(result_path, 'FAIL', 'policy', f'Invalid or symlinked candidate source: {edit_name}')
        text = found.read_text(encoding='utf-8', errors='replace')
        screen_rtl(edit_name, text, result_path)
        cand_sources[edit_name] = text

    env = {
        'PATH': f'{TOOLS_ROOT / "verilator-v5.038" / "bin"}:{TOOLS_ROOT / "oss-cad-suite" / "bin"}:/usr/bin:/bin',
        'HOME': '/tmp',
        'TMPDIR': '/tmp',
        'LANG': 'C.UTF-8',
        'VERILATOR_ROOT': str(TOOLS_ROOT / 'verilator-v5.038' / 'share' / 'verilator'),
    }

    try:
        with tempfile.TemporaryDirectory(prefix='case_0045_grade_') as tmp:
            td = pathlib.Path(tmp)
            src = td / 'code'
            src.mkdir()
            for fname in FIXED_FILES:
                shutil.copyfile(PUB_CODE / fname, src / fname)
            for fname, text in cand_sources.items():
                (src / fname).write_text(text, encoding='utf-8')
            shutil.copyfile(PRIV_DIR / 'tests' / 'tb.sv', td / 'tb.sv')

            # 1. Yosys synthesis & latch-free cleanliness check
            ys_script = (
                f'read_verilog -sv -I{src} '
                f'{src / "ArbitrationTree.sv"} {src / "FanInPrimitive_Req.sv"} '
                f'{src / "priority_Flag_Req.sv"} {src / "TestAndSet.sv"} '
                f'{src / "AddressDecoder_Resp.sv"} {src / "RequestBlock1CH.sv"}; '
                'hierarchy -check -top RequestBlock1CH -chparam N_CH0 4; '
                'proc; opt_clean; '
                'select -assert-none t:$dlatch* t:$adlatch* t:$latch* t:$sr*'
            )
            ys_run = subprocess.run(
                [str(YOSYS_BIN), '-q', '-p', ys_script],
                cwd=td,
                env=env,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                timeout=120,
            )
            if ys_run.returncode != 0:
                finish(result_path, 'FAIL', 'synthesis', f'Yosys synthesis or latch check failed:\n{ys_run.stdout[-1500:].strip()}')

            # 2. Verilator behavioral verification across N=4, N=3 (non-power-of-two padded), N=8, N=2
            n_list = [4, 3, 8, 2] if (args.seed % 2 == 1) else [3, 8, 4, 2]
            seed_val = (args.seed & 0x7fffffff) or 1
            for n_val in n_list:
                obj_dir = td / f'obj_{n_val}'
                cmd = [
                    str(VERILATOR_BIN),
                    '--binary',
                    '--timing',
                    '-j', '1',
                    '-Wno-fatal',
                    '--top-module', 'tb',
                    f'-GN={n_val}',
                    f'-GSEED={seed_val + n_val}',
                    '--Mdir', str(obj_dir),
                    f'+incdir+{src}',
                    str(src / 'RequestBlock1CH.sv'),
                    str(src / 'ArbitrationTree.sv'),
                    str(src / 'FanInPrimitive_Req.sv'),
                    str(src / 'priority_Flag_Req.sv'),
                    str(src / 'TestAndSet.sv'),
                    str(src / 'AddressDecoder_Resp.sv'),
                    str(td / 'tb.sv'),
                ]
                build = subprocess.run(
                    cmd,
                    cwd=td,
                    env=env,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.STDOUT,
                    text=True,
                    timeout=180,
                )
                if build.returncode != 0:
                    finish(result_path, 'FAIL', 'compile', f'Verilator elaboration failed (N={n_val}):\n{build.stdout[-1500:].strip()}')

                sim = subprocess.run(
                    [str(obj_dir / 'Vtb')],
                    cwd=td,
                    env=env,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.STDOUT,
                    text=True,
                    timeout=60,
                )
                if sim.returncode != 0 or f'FAIRNESS_PASS N={n_val}' not in sim.stdout:
                    finish(
                        result_path,
                        'FAIL',
                        'behavior',
                        f'Simulation failed for N={n_val}:\n{sim.stdout[-1500:].strip()}',
                        tested_n=n_val,
                    )

            finish(
                result_path,
                'PASS',
                'behavior',
                f'PASS latch-free synthesis and stall-locked bounded fairness across N={n_list}',
                tested_n_list=n_list,
            )
    except subprocess.TimeoutExpired:
        finish(result_path, 'ERROR', 'environment', 'Synthesis or simulation timed out')
    except OSError as exc:
        finish(result_path, 'ERROR', 'environment', f'OS error: {exc}')


if __name__ == '__main__':
    main()
