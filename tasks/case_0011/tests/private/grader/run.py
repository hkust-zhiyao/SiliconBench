#!/usr/bin/env python3
"""Trusted isolated grader for case_0011 (HWPE partial multiplier functional + QoR/STA)."""
import argparse
import json
import os
import pathlib
import re
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
PRIV = TASK_DIR / 'private'
PUB = TASK_DIR / 'public'

TOOLS = pathlib.Path(str(_sb_tools_dir()))
OSS_BIN = TOOLS / 'oss-cad-suite/bin'
OPENROAD = TOOLS / 'bin/openroad'
LIB = pathlib.Path(f"{_sb_nangate45_dir()}/lib/NangateOpenCellLibrary_typical.lib")

AREA_LIMIT_UM2 = 1620.0


def finish(ok: bool, stage: str, reason: str, **extra):
    payload = {
        'verdict': 'PASS' if ok else 'FAIL',
        'stage': stage,
        'reason': reason,
        **extra,
    }
    pathlib.Path(ARGS.result).write_text(json.dumps(payload, indent=2) + '\n')
    print(f"{payload['verdict']} [{stage}]: {reason}")
    raise SystemExit(0 if ok else 1)


def run_cmd(cmd, **kw):
    proc = subprocess.run(
        cmd,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        timeout=300,
        **kw,
    )
    print(proc.stdout[-6000:])
    return proc


parser = argparse.ArgumentParser()
parser.add_argument('--candidate', required=True)
parser.add_argument('--seed', type=int, default=1)
parser.add_argument('--result', required=True)
ARGS = parser.parse_args()

try:
    cand = pathlib.Path(ARGS.candidate).resolve(strict=True)
except Exception as e:
    finish(False, 'anti_hack', f'invalid candidate directory: {e}')

pub_code = PUB / 'code'
orig_rtl = pub_code / 'rtl/hwpe_ctrl_partial_mult.sv'
cand_rtl = cand / 'code/rtl/hwpe_ctrl_partial_mult.sv'

# 1. Verify read-only files in code/ are untouched and no symlink escapes exist
for p in sorted(pub_code.rglob('*')):
    if p.is_file() and p != orig_rtl:
        rel = p.relative_to(pub_code)
        q = cand / 'code' / rel
        if not q.is_file() or q.is_symlink() or cand not in q.resolve().parents:
            finish(False, 'anti_hack', f'protected file missing or symlinked: code/{rel}')
        if q.read_bytes() != p.read_bytes():
            finish(False, 'anti_hack', f'protected file modified: code/{rel}')

if not cand_rtl.is_file() or cand_rtl.is_symlink() or cand not in cand_rtl.resolve().parents:
    finish(False, 'anti_hack', 'candidate hwpe_ctrl_partial_mult.sv missing or symlinked')

raw_text = cand_rtl.read_text(encoding='utf-8', errors='replace')
clean_text = re.sub(r'/\*.*?\*/|//[^\n]*', '', raw_text, flags=re.S)

# 2. Screen for forbidden HDL constructs, macro divergence, or testbench tampering
if re.search(
    r'`|\$(?!clog2\b|signed\b|unsigned\b|bits\b|size\b)'
    r'|\b(?:initial|final|force|release|bind|primitive|blackbox|whitebox|import\s*"DPI|export\s*"DPI)\b'
    r'|\(\*(?!\s*\))',
    clean_text,
):
    finish(False, 'anti_hack', 'disallowed simulation/synthesis directive, system task, or attribute in RTL')

if re.search(r'\b(?:tb|sub_tb|dut|refdut|ref_partial|grader|oracle)\s*\.', clean_text):
    finish(False, 'anti_hack', 'illegal hierarchical reference in RTL')

with tempfile.TemporaryDirectory(prefix='case_0011_') as tmpd:
    t = pathlib.Path(tmpd)
    dut_sv = t / 'candidate.sv'
    dut_sv.write_text(raw_text)

    ref_sv = t / 'reference.sv'
    ref_sv.write_text(
        orig_rtl.read_text().replace('module hwpe_ctrl_partial_mult\n', 'module ref_partial\n', 1)
    )

    pkg_sv = pub_code / 'rtl/hwpe_ctrl_package.sv'
    uloop_sv = pub_code / 'rtl/hwpe_ctrl_uloop.sv'
    tb_sv = PRIV / 'tests/tb.sv'
    obj_dir = t / 'obj'

    # 3. Compile and run multi-configuration Verilator functional verification
    c_proc = run_cmd([
        str(OSS_BIN / 'verilator'),
        '--binary',
        '--timing',
        '-j', '1',
        '-Wno-fatal',
        '--top-module', 'tb',
        '--Mdir', str(obj_dir),
        str(pkg_sv),
        str(uloop_sv),
        str(ref_sv),
        str(dut_sv),
        str(tb_sv),
    ])
    if c_proc.returncode != 0:
        finish(False, 'behavior', 'Verilator compilation failed on candidate RTL')

    s_proc = run_cmd([str(obj_dir / 'Vtb'), f'+seed={ARGS.seed}'])
    if (
        s_proc.returncode != 0
        or 'PASS partial multiplier cycle, uloop stride, and arithmetic equivalence' not in s_proc.stdout
    ):
        finish(False, 'behavior', 'functional, latency, handshake, or uloop stride mismatch in simulation')

    # 4. Run Yosys/Slang + ABC synthesis on Nangate45 typical library at AW=32, BW=32, MULT_BITS=4
    mapped_v = t / 'mapped.v'
    ys_script = t / 'map.ys'
    ys_script.write_text(
        f'read_slang --top hwpe_ctrl_partial_mult -G AW=32 -G BW=32 -G MULT_BITS=4 -DSYNTHESIS {pkg_sv} {dut_sv}\n'
        f'hierarchy -check -top hwpe_ctrl_partial_mult\n'
        f'synth -top hwpe_ctrl_partial_mult\n'
        f'opt\n'
        f'dfflibmap -liberty {LIB}\n'
        f'abc -liberty {LIB}\n'
        f'clean\n'
        f'read_liberty -lib {LIB}\n'
        f'check -assert\n'
        f'stat -liberty {LIB}\n'
        f'write_verilog -noattr {mapped_v}\n'
    )
    y_proc = run_cmd([str(OSS_BIN / 'yosys'), '-Q', '-T', '-m', 'slang', str(ys_script)])
    m_area = re.search(r'Chip area for module .*?:\s*([\d.]+)', y_proc.stdout)
    if y_proc.returncode != 0 or not m_area or not mapped_v.is_file():
        finish(False, 'synthesis', 'Yosys/Slang synthesis or ABC technology mapping failed')

    area_um2 = round(float(m_area.group(1)), 3)
    print(f'AREA_UM2={area_um2}')
    if area_um2 > AREA_LIMIT_UM2:
        finish(
            False,
            'area',
            f'mapped cell area {area_um2:.3f} um^2 exceeds limit {AREA_LIMIT_UM2:.1f} um^2',
            area_um2=area_um2,
            area_limit_um2=AREA_LIMIT_UM2,
        )

    # 5. Run OpenROAD placement-estimated STA at 3.1 ns clock period
    sta_v = t / 'sta.v'
    sta_v.write_text(mapped_v.read_text().replace(' signed ', ' '))
    env = os.environ.copy()
    env['NETLIST'] = str(sta_v)

    or_cmd = [str(OPENROAD), '-exit', str(PRIV / 'tests/flow.tcl')]

    o_proc = run_cmd(or_cmd, env=env)
    if o_proc.returncode != 0:
        finish(False, 'timing', 'OpenROAD global placement or STA failed', area_um2=area_um2)

    setup_sec = re.search(r'=== SETUP ===(.*?)=== HOLD ===', o_proc.stdout, re.S)
    hold_sec = re.search(r'=== HOLD ===(.*?)BEGIN_SETUP_AUDIT', o_proc.stdout, re.S)
    audit_sec = re.search(r'BEGIN_SETUP_AUDIT(.*?)END_SETUP_AUDIT', o_proc.stdout, re.S)

    if not setup_sec or not hold_sec or not audit_sec:
        finish(False, 'timing', 'incomplete OpenROAD STA report sections', area_um2=area_um2)

    audit_txt = audit_sec.group(1).strip()
    if (
        audit_txt
        or re.search(r'clock not found|unconstrained|no clock|missing', audit_txt, re.I)
        or re.search(r'clock not found', o_proc.stdout, re.I)
    ):
        finish(False, 'timing', f'timing constraint audit failed: {audit_txt}', area_um2=area_um2)

    setup_slacks = [float(v) for v in re.findall(r'([\d.-]+)\s+slack \((?:MET|VIOLATED)\)', setup_sec.group(1))]
    hold_slacks = [float(v) for v in re.findall(r'([\d.-]+)\s+slack \((?:MET|VIOLATED)\)', hold_sec.group(1))]
    if not setup_slacks or not hold_slacks:
        finish(False, 'timing', 'no setup or hold slack values parsed from OpenROAD report', area_um2=area_um2)

    worst_setup_slack_ns = round(min(setup_slacks), 3)
    worst_hold_slack_ns = round(min(hold_slacks), 3)
    print(f'WORST_SETUP_SLACK_NS={worst_setup_slack_ns} WORST_HOLD_SLACK_NS={worst_hold_slack_ns}')

    if worst_setup_slack_ns < 0.0:
        finish(
            False,
            'timing',
            f'worst setup slack {worst_setup_slack_ns:.3f} ns < 0.0 ns at 3.1 ns clock',
            area_um2=area_um2,
            worst_setup_slack_ns=worst_setup_slack_ns,
            worst_hold_slack_ns=worst_hold_slack_ns,
        )

    if worst_hold_slack_ns < 0.0:
        finish(
            False,
            'timing',
            f'worst hold slack {worst_hold_slack_ns:.3f} ns < 0.0 ns',
            area_um2=area_um2,
            worst_setup_slack_ns=worst_setup_slack_ns,
            worst_hold_slack_ns=worst_hold_slack_ns,
        )

    finish(
        True,
        'all',
        'functional equivalence across all widths, uloop stride integration, mapped area, and placement STA passed',
        area_um2=area_um2,
        area_limit_um2=AREA_LIMIT_UM2,
        worst_setup_slack_ns=worst_setup_slack_ns,
        worst_hold_slack_ns=worst_hold_slack_ns,
    )
