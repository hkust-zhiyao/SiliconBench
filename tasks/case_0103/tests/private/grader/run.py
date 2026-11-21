#!/usr/bin/env python3
"""Trusted isolated grader for case_0103 (WB2AXIP Coupled Bridges + Nangate45 Area & OpenSTA Closure)."""
import argparse
import hashlib
import json
import os
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
PUB_DIR = TASK_DIR / 'public'

TOOLS_DIR = pathlib.Path(str(_sb_tools_dir()))
VERILATOR_BIN = TOOLS_DIR / 'verilator-v5.038/bin/verilator'
YOSYS_BIN = TOOLS_DIR / 'oss-cad-suite/bin/yosys'
STA_BIN = TOOLS_DIR / 'openroad-runtime/usr/bin/sta'
STA_LIBPATH = f'{TOOLS_DIR / "openroad-runtime/usr/lib/x86_64-linux-gnu"}:{TOOLS_DIR / "openroad-runtime/opt/or-tools/lib"}'
LIB_PATH = PUB_DIR / 'lib/NangateOpenCellLibrary_typical.lib'

EDITABLE_FILES = {
    'code/wbm2axisp.v': 'wbm2axisp',
    'code/aximwr2wbsp.v': 'aximwr2wbsp',
    'code/aximrd2wbsp.v': 'aximrd2wbsp',
}
PROTECTED_FILES = (
    'code/skidbuffer.v',
    'code/sfifo.v',
    'code/axi_addr.v',
    'code/wbarbiter.v',
    'code/axim2wbsp.v',
    'code/wb2axip_bridge_top.v',
    'code/LICENSE',
    'lib/NangateOpenCellLibrary_typical.lib',
    'lib/LICENSE.Nangate45',
    'flow/synth.ys',
    'flow/timing.tcl',
)

AREA_LIMIT_UM2 = 6750.0
MIN_SETUP_SLACK_NS = 2.48
MIN_HOLD_SLACK_NS = 0.00


def finish(result_path: pathlib.Path, verdict: str, stage: str, detail: str, **metrics):
    payload = {
        'verdict': verdict,
        'stage': stage,
        'detail': detail,
        'reason': detail,
        **metrics,
    }
    result_path.parent.mkdir(parents=True, exist_ok=True)
    result_path.write_text(json.dumps(payload, indent=2) + '\n')
    print(json.dumps(payload), flush=True)
    raise SystemExit(0 if verdict == 'PASS' else 2 if verdict == 'ERROR' else 1)


def sha256_file(path: pathlib.Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def strip_comments_and_strings(text: str) -> str:
    text = re.sub(r'(?is)//\s*pragma\s+translate_off.*?//\s*pragma\s+translate_on', ' ', text)
    text = re.sub(r'/\*.*?\*/|//[^\n]*|"(?:\\.|[^"\\])*"', ' ', text, flags=re.S)
    return text


def screen_verilog(raw: str, expected_mod: str, rel_name: str, result_path: pathlib.Path):
    if len(raw.encode('utf-8')) > 250_000:
        finish(result_path, 'FAIL', 'policy', f'{rel_name} exceeds file size limit')
    if re.search(r'translate_(?:on|off)|synthesis\s+(?:on|off)', raw, re.I):
        finish(result_path, 'FAIL', 'policy', f'Synthesis pragma divergence in {rel_name}')
    without_benign = re.sub(
        r'(?m)^[ \t]*`(?:timescale\s+[^\n]+|default_nettype\s+(?:none|wire)|resetall)[ \t]*$',
        '',
        raw,
    )
    cleaned = strip_comments_and_strings(without_benign)
    escape_pats = [
        (r'\$(?!clog2\b|bits\b|signed\b|unsigned\b|size\b)[a-zA-Z_][\w$]*', 'forbidden_systask'),
        (r'\b(?:force|release|bind|defparam|initial|final|fork|join|join_any|join_none|wait|program|primitive|config|blackbox|whitebox)\b', 'forbidden_construct'),
        (r'\(\*(?!\s*\))', 'prohibited_synthesis_attribute'),
        (r'\b(?:import|export)\s*"DPI', 'dpi_escape'),
        (r'\$root\b|\b(?:tb|dut|u_wbm2axi|u_axi2wbm|grader|oracle)\s*\.', 'hierarchical_harness_reference'),
        (r'`\s*(?:ifdef|ifndef|elsif|include)\b', 'prohibited_preprocessor_directive'),
        (r'#\s*\d', 'prohibited_delay_control'),
    ]
    for pat, label in escape_pats:
        if re.search(pat, cleaned, re.I):
            finish(result_path, 'FAIL', 'policy', f'Policy violation ({label}) in {rel_name}')

    mods = re.findall(r'\bmodule\s+(?:automatic\s+)?([a-zA-Z_]\w*)', cleaned)
    if mods != [expected_mod]:
        finish(result_path, 'FAIL', 'structural', f'Expected module {expected_mod} in {rel_name}, found {mods}')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--candidate', required=True)
    ap.add_argument('--seed', type=int, default=1)
    ap.add_argument('--result', required=True)
    args = ap.parse_args()

    result_path = pathlib.Path(args.result).resolve()
    cand_in = pathlib.Path(args.candidate)
    if not cand_in.is_absolute() or any(p.is_symlink() for p in (cand_in, *cand_in.parents)) or not cand_in.is_dir():
        finish(result_path, 'FAIL', 'input_validation', 'Candidate path must be an absolute non-symlink directory')
    cand_root = cand_in.resolve()

    # 1. Verify read-only files if present in candidate directory
    for rel_str in PROTECTED_FILES:
        ref = PUB_DIR / rel_str
        q = cand_root / rel_str
        if q.exists() or q.is_symlink():
            if q.is_symlink() or not q.is_file() or not q.resolve().is_relative_to(cand_root):
                finish(result_path, 'FAIL', 'policy', f'Symlinked or unsafe protected file: {rel_str}')
            if sha256_file(q) != sha256_file(ref):
                finish(result_path, 'FAIL', 'policy', f'Protected file modified: {rel_str}')

    # 2. Load and screen editable files
    sources = {}
    for rel_str, exp_mod in EDITABLE_FILES.items():
        p = cand_root / rel_str
        if p.is_symlink() or not p.is_file() or not p.resolve().is_relative_to(cand_root):
            finish(result_path, 'FAIL', 'input_validation', f'Missing or invalid editable file: {rel_str}')
        txt = p.read_text(encoding='utf-8', errors='replace')
        screen_verilog(txt, exp_mod, rel_str, result_path)
        sources[rel_str] = txt

    env = {
        'PATH': f'{TOOLS_DIR / "verilator-v5.038/bin"}:{TOOLS_DIR / "oss-cad-suite/bin"}:/usr/bin:/bin',
        'VERILATOR_ROOT': str(TOOLS_DIR / 'verilator-v5.038/share/verilator'),
        'LD_LIBRARY_PATH': STA_LIBPATH,
        'HOME': '/tmp',
        'TMPDIR': '/tmp',
        'LANG': 'C.UTF-8',
        'CC': '/usr/bin/gcc',
        'CXX': '/usr/bin/g++',
        'OMP_NUM_THREADS': '1',
        'MAKEFLAGS': '-j1',
    }

    try:
        with tempfile.TemporaryDirectory(prefix='case_0103_') as td:
            w = pathlib.Path(td)
            (w / 'code').mkdir()
            (w / 'lib').mkdir()
            (w / 'flow').mkdir()

            for rel_str, txt in sources.items():
                (w / rel_str).write_text(txt, encoding='utf-8')
            for ro in ('code/skidbuffer.v', 'code/sfifo.v', 'code/axi_addr.v', 'code/wbarbiter.v', 'code/axim2wbsp.v', 'code/wb2axip_bridge_top.v', 'flow/synth.ys', 'flow/timing.tcl'):
                shutil.copyfile(PUB_DIR / ro, w / ro)
            shutil.copyfile(LIB_PATH, w / 'lib/NangateOpenCellLibrary_typical.lib')

            # 3. Functional Simulation (Verilator 5.038)
            obj_dir = w / 'obj_dir'
            comp = subprocess.run(
                [
                    str(VERILATOR_BIN),
                    '--binary',
                    '--timing',
                    '-j', '1',
                    '-O1',
                    '-Wno-fatal',
                    '--top-module', 'tb',
                    f'-GSEED={args.seed}',
                    '--Mdir', str(obj_dir),
                    str(w / 'code/skidbuffer.v'),
                    str(w / 'code/sfifo.v'),
                    str(w / 'code/axi_addr.v'),
                    str(w / 'code/wbarbiter.v'),
                    str(w / 'code/axim2wbsp.v'),
                    str(w / 'code/wbm2axisp.v'),
                    str(w / 'code/aximwr2wbsp.v'),
                    str(w / 'code/aximrd2wbsp.v'),
                    str(w / 'code/wb2axip_bridge_top.v'),
                    str(PRIV_DIR / 'tests/tb.sv'),
                ],
                cwd=w,
                env=env,
                capture_output=True,
                text=True,
                timeout=180,
            )
            if comp.returncode != 0 or not (obj_dir / 'Vtb').is_file():
                finish(result_path, 'FAIL', 'functional', f'Verilator compile failed: {(comp.stdout + comp.stderr)[-1200:].strip()}')

            sim = subprocess.run(
                [str(obj_dir / 'Vtb')],
                cwd=w,
                env=env,
                capture_output=True,
                text=True,
                timeout=60,
            )
            sim_out = sim.stdout + '\n' + sim.stderr
            if sim.returncode != 0 or f'PASS_CASE_0103 seed={args.seed}' not in sim_out:
                finish(result_path, 'FAIL', 'functional', f'Functional simulation failed (seed={args.seed}): {sim_out[-1200:].strip()}')

            # 4. Yosys Nangate45 Synthesis & Area Check
            synth = subprocess.run(
                [str(YOSYS_BIN), '-Q', '-T', '-s', 'flow/synth.ys'],
                cwd=w,
                env=env,
                capture_output=True,
                text=True,
                timeout=120,
            )
            m_area = re.search(r"Chip area for module '\\wb2axip_bridge_top':\s*([\d.]+)", synth.stdout)
            if synth.returncode != 0 or not m_area or not (w / 'mapped.v').is_file():
                finish(result_path, 'FAIL', 'synthesis', f'Yosys synthesis failed: {(synth.stdout + synth.stderr)[-1200:].strip()}')

            area_um2 = round(float(m_area.group(1)), 3)
            if area_um2 > AREA_LIMIT_UM2:
                finish(
                    result_path,
                    'FAIL',
                    'area',
                    f'Mapped cell area {area_um2:.3f} um^2 exceeds limit {AREA_LIMIT_UM2:.1f} um^2',
                    area_um2=area_um2,
                    area_limit_um2=AREA_LIMIT_UM2,
                )

            # 5. OpenSTA Timing Closure Check
            sta = subprocess.run(
                [str(STA_BIN), '-exit', 'flow/timing.tcl'],
                cwd=w,
                env=env,
                capture_output=True,
                text=True,
                timeout=60,
            )
            sta_out = sta.stdout + '\n' + sta.stderr
            if sta.returncode != 0 or '=== SETUP ===' not in sta_out or '=== HOLD ===' not in sta_out:
                finish(result_path, 'ERROR', 'environment', f'OpenSTA execution failed: {sta_out[-1200:].strip()}')

            setup_sec = sta_out.split('=== SETUP ===', 1)[1].split('=== HOLD ===', 1)[0]
            hold_sec = sta_out.split('=== HOLD ===', 1)[1]
            setup_slacks = [float(x) for x in re.findall(r'([-+\d.]+)\s+slack\s+\((?:MET|VIOLATED)\)', setup_sec)]
            hold_slacks = [float(x) for x in re.findall(r'([-+\d.]+)\s+slack\s+\((?:MET|VIOLATED)\)', hold_sec)]
            if not setup_slacks or not hold_slacks:
                finish(result_path, 'ERROR', 'environment', 'Could not parse setup/hold slack from OpenSTA output')

            worst_setup_ns = round(min(setup_slacks), 3)
            worst_hold_ns = round(min(hold_slacks), 3)
            metrics = {
                'area_um2': area_um2,
                'area_limit_um2': AREA_LIMIT_UM2,
                'worst_setup_slack_ns': worst_setup_ns,
                'worst_hold_slack_ns': worst_hold_ns,
            }

            if worst_setup_ns < MIN_SETUP_SLACK_NS:
                finish(
                    result_path,
                    'FAIL',
                    'timing',
                    f'Worst setup slack {worst_setup_ns:.3f} ns < {MIN_SETUP_SLACK_NS:.2f} ns target',
                    **metrics,
                )
            if worst_hold_ns < MIN_HOLD_SLACK_NS:
                finish(
                    result_path,
                    'FAIL',
                    'timing',
                    f'Worst hold slack {worst_hold_ns:.3f} ns < {MIN_HOLD_SLACK_NS:.2f} ns target',
                    **metrics,
                )

            finish(
                result_path,
                'PASS',
                'all',
                f'WB2AXIP credit/flush/error handling, ID sharing, area ({area_um2:.3f} um^2), and OpenSTA timing (setup={worst_setup_ns:.2f} ns, hold={worst_hold_ns:.2f} ns) passed',
                **metrics,
            )
    except subprocess.TimeoutExpired as exc:
        finish(result_path, 'ERROR', 'environment', f'Tool timeout: {exc}')
    except OSError as exc:
        finish(result_path, 'ERROR', 'environment', f'OS error: {exc}')


if __name__ == '__main__':
    main()
