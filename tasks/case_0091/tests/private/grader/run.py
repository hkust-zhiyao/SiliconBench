#!/usr/bin/env python3
"""Trusted isolated grader for case_0091 (NEureka normalization-quantization functional + Nangate45 area/STA)."""
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
NANGATE = pathlib.Path(str(_sb_nangate45_dir()))
LIB = NANGATE / 'lib/NangateOpenCellLibrary_typical.lib'
TLEF = NANGATE / 'lef/NangateOpenCellLibrary.tech.lef'
MLEF = NANGATE / 'lef/NangateOpenCellLibrary.macro.mod.lef'

SHIFTER_AREA_LIMIT_UM2 = 915.0
NORMQUANT_AREA_LIMIT_UM2 = 4685.0
CLOCK_PERIOD_NS = 1.75


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
    print(proc.stdout[-4000:])
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
edit_rels = {
    pathlib.Path('rtl/neureka_normquant.sv'),
    pathlib.Path('rtl/neureka_normquant_shifter.sv'),
}

# 1. Verify read-only files in code/ are untouched and no symlink escapes exist
for p in sorted(pub_code.rglob('*')):
    if p.is_file():
        rel = p.relative_to(pub_code)
        if rel in edit_rels:
            continue
        q = cand / 'code' / rel
        if q.exists() or q.is_symlink():
            if not q.is_file() or q.is_symlink() or cand not in q.resolve().parents:
                finish(False, 'anti_hack', f'protected file missing or symlinked: code/{rel}')
            if q.read_bytes() != p.read_bytes():
                finish(False, 'anti_hack', f'protected file modified: code/{rel}')

cand_files = {}
for rel in sorted(edit_rels):
    q = cand / 'code' / rel
    if not q.exists() and (cand / rel).exists():
        q = cand / rel
    if not q.is_file() or q.is_symlink() or cand not in q.resolve().parents:
        finish(False, 'anti_hack', f'candidate {rel} missing or symlinked')
    raw_text = q.read_text(encoding='utf-8', errors='replace')
    clean_text = re.sub(r'/\*.*?\*/|//[^\n]*', '', raw_text, flags=re.S)
    if re.search(
        r'`|\$(?!clog2\b|signed\b|unsigned\b|bits\b|size\b)'
        r'|\b(?:initial|final|force|release|bind|primitive|blackbox|whitebox|import\s*"DPI|export\s*"DPI)\b'
        r'|\(\*(?!\s*\))',
        clean_text,
    ):
        finish(False, 'anti_hack', f'disallowed simulation/synthesis directive, system task, or attribute in {rel}')
    if re.search(r'\b(?:tb|u_nq_p1_r1|u_nq_p1_r0|u_sh_r1|grader|oracle)\s*\.', clean_text):
        finish(False, 'anti_hack', f'illegal hierarchical reference in {rel}')
    cand_files[rel.name] = raw_text

with tempfile.TemporaryDirectory(prefix='case_0091_') as tmpd:
    t = pathlib.Path(tmpd)
    nq_sv = t / 'neureka_normquant.sv'
    sh_sv = t / 'neureka_normquant_shifter.sv'
    nq_sv.write_text(cand_files['neureka_normquant.sv'])
    sh_sv.write_text(cand_files['neureka_normquant_shifter.sv'])

    pkg_stream = pub_code / 'rtl/hwpe_stream_package.sv'
    pkg_hci = pub_code / 'rtl/hci_package.sv'
    pkg_neureka = pub_code / 'rtl/neureka_package.sv'
    mult_sv = pub_code / 'rtl/neureka_normquant_multiplier.sv'
    tb_sv = PRIV / 'tests/tb.sv'
    obj_dir = t / 'obj'

    # 2. Verilator functional simulation
    c_proc = run_cmd([
        str(OSS_BIN / 'verilator'),
        '--binary',
        '--timing',
        '-j', '1',
        '-Wno-fatal',
        '--top-module', 'tb',
        '--Mdir', str(obj_dir),
        str(pkg_stream),
        str(pkg_hci),
        str(pkg_neureka),
        str(mult_sv),
        str(sh_sv),
        str(nq_sv),
        str(tb_sv),
    ])
    if c_proc.returncode != 0:
        finish(False, 'behavior', 'Verilator compilation failed on candidate RTL')

    s_proc = run_cmd([str(obj_dir / 'Vtb'), f'+seed={ARGS.seed}'])
    if (
        s_proc.returncode != 0
        or 'PASS neureka_normquant and neureka_normquant_shifter equivalence' not in s_proc.stdout
    ):
        finish(False, 'behavior', 'functional, rounding, saturation, stall hold, or clear mismatch in simulation')

    # 3. Yosys/Slang + ABC synthesis on neureka_normquant_shifter (INT=48, OUTPUT_REGISTER=1)
    mapped_sh = t / 'mapped_shifter.v'
    ys_sh = t / 'map_shifter.ys'
    ys_sh.write_text(
        f'read_slang --top neureka_normquant_shifter -G INT=48 -G OUTPUT_REGISTER=1 -DSYNTHESIS '
        f'{pkg_stream} {pkg_hci} {pkg_neureka} {sh_sv}\n'
        f'hierarchy -check -top neureka_normquant_shifter\n'
        f'synth -top neureka_normquant_shifter\n'
        f'opt\n'
        f'dfflibmap -liberty {LIB}\n'
        f'abc -liberty {LIB}\n'
        f'clean\n'
        f'read_liberty -lib {LIB}\n'
        f'check -assert\n'
        f'stat -liberty {LIB}\n'
        f'write_verilog -noattr {mapped_sh}\n'
    )
    y_sh = run_cmd([str(OSS_BIN / 'yosys'), '-Q', '-T', '-m', 'slang', str(ys_sh)])
    m_sh_area = re.search(r'Chip area for module .*?:\s*([\d.]+)', y_sh.stdout)
    if y_sh.returncode != 0 or not m_sh_area or not mapped_sh.is_file():
        finish(False, 'synthesis', 'Yosys/Slang synthesis failed on neureka_normquant_shifter')
    shifter_area_um2 = round(float(m_sh_area.group(1)), 3)

    # 4. Yosys/Slang + ABC synthesis on neureka_normquant (OUTPUT_REGISTER=1, multiplier blackboxed)
    mapped_nq = t / 'mapped_normquant.v'
    ys_nq = t / 'map_normquant.ys'
    ys_nq.write_text(
        f'read_slang --blackboxed-module neureka_normquant_multiplier --top neureka_normquant '
        f'-G OUTPUT_REGISTER=1 -DSYNTHESIS '
        f'{pkg_stream} {pkg_hci} {pkg_neureka} {mult_sv} {sh_sv} {nq_sv}\n'
        f'hierarchy -check -top neureka_normquant\n'
        f'synth -top neureka_normquant -flatten\n'
        f'opt\n'
        f'dfflibmap -liberty {LIB}\n'
        f'abc -liberty {LIB}\n'
        f'clean\n'
        f'read_liberty -lib {LIB}\n'
        f'check -assert\n'
        f'stat -liberty {LIB}\n'
        f'write_verilog -noattr {mapped_nq}\n'
    )
    y_nq = run_cmd([str(OSS_BIN / 'yosys'), '-Q', '-T', '-m', 'slang', str(ys_nq)])
    m_nq_area = re.search(r'Chip area for module .*?:\s*([\d.]+)', y_nq.stdout)
    if y_nq.returncode != 0 or not m_nq_area or not mapped_nq.is_file():
        finish(False, 'synthesis', 'Yosys/Slang synthesis failed on neureka_normquant')
    normquant_area_um2 = round(float(m_nq_area.group(1)), 3)

    if shifter_area_um2 > SHIFTER_AREA_LIMIT_UM2:
        finish(
            False,
            'area',
            f'shifter mapped area {shifter_area_um2:.3f} um^2 exceeds limit {SHIFTER_AREA_LIMIT_UM2:.1f} um^2',
            shifter_area_um2=shifter_area_um2,
            normquant_area_um2=normquant_area_um2,
        )

    if normquant_area_um2 > NORMQUANT_AREA_LIMIT_UM2:
        finish(
            False,
            'area',
            f'normquant mapped area {normquant_area_um2:.3f} um^2 exceeds limit {NORMQUANT_AREA_LIMIT_UM2:.1f} um^2',
            shifter_area_um2=shifter_area_um2,
            normquant_area_um2=normquant_area_um2,
        )

    # 5. OpenSTA timing closure at 1.75 ns clock
    sta_v = t / 'sta.v'
    sta_v.write_text(mapped_sh.read_text().replace(' signed ', ' '))
    sta_tcl = t / 'sta.tcl'
    sta_tcl.write_text(
        f'read_lef {TLEF}\n'
        f'read_lef {MLEF}\n'
        f'read_liberty {LIB}\n'
        f'read_verilog {sta_v}\n'
        f'link_design neureka_normquant_shifter\n'
        f'create_clock -name clk_i -period {CLOCK_PERIOD_NS} [get_ports clk_i]\n'
        f'set_input_delay 0.25 -clock clk_i [all_inputs -no_clocks]\n'
        f'set_output_delay 0.25 -clock clk_i [all_outputs]\n'
        f'set_load 5.0 [all_outputs]\n'
        f'puts "=== SETUP ==="\n'
        f'report_checks -path_delay max -format full_clock_expanded\n'
        f'puts "=== HOLD ==="\n'
        f'report_checks -path_delay min -format full_clock_expanded\n'
        f'puts "BEGIN_SETUP_AUDIT"\n'
        f'check_setup -verbose\n'
        f'puts "END_SETUP_AUDIT"\n'
    )
    o_proc = run_cmd([str(OPENROAD), '-exit', str(sta_tcl)])
    if o_proc.returncode != 0:
        finish(False, 'timing', 'OpenROAD STA failed', shifter_area_um2=shifter_area_um2, normquant_area_um2=normquant_area_um2)

    setup_sec = re.search(r'=== SETUP ===(.*?)=== HOLD ===', o_proc.stdout, re.S)
    hold_sec = re.search(r'=== HOLD ===(.*?)BEGIN_SETUP_AUDIT', o_proc.stdout, re.S)
    audit_sec = re.search(r'BEGIN_SETUP_AUDIT(.*?)END_SETUP_AUDIT', o_proc.stdout, re.S)

    if not setup_sec or not hold_sec or not audit_sec:
        finish(False, 'timing', 'incomplete OpenROAD STA report sections', shifter_area_um2=shifter_area_um2)

    audit_txt = audit_sec.group(1).strip()
    if audit_txt or re.search(r'clock not found|unconstrained|no clock', audit_txt, re.I):
        finish(False, 'timing', f'timing constraint audit failed: {audit_txt}', shifter_area_um2=shifter_area_um2)

    setup_slacks = [float(v) for v in re.findall(r'([\d.-]+)\s+slack \((?:MET|VIOLATED)\)', setup_sec.group(1))]
    hold_slacks = [float(v) for v in re.findall(r'([\d.-]+)\s+slack \((?:MET|VIOLATED)\)', hold_sec.group(1))]
    if not setup_slacks or not hold_slacks:
        finish(False, 'timing', 'no setup or hold slack values parsed from OpenROAD report', shifter_area_um2=shifter_area_um2)

    worst_setup_slack_ns = round(min(setup_slacks), 3)
    worst_hold_slack_ns = round(min(hold_slacks), 3)

    if worst_setup_slack_ns < 0.0:
        finish(
            False,
            'timing',
            f'worst setup slack {worst_setup_slack_ns:.3f} ns < 0.0 ns at {CLOCK_PERIOD_NS} ns clock',
            shifter_area_um2=shifter_area_um2,
            normquant_area_um2=normquant_area_um2,
            worst_setup_slack_ns=worst_setup_slack_ns,
            worst_hold_slack_ns=worst_hold_slack_ns,
        )

    if worst_hold_slack_ns < 0.0:
        finish(
            False,
            'timing',
            f'worst hold slack {worst_hold_slack_ns:.3f} ns < 0.0 ns',
            shifter_area_um2=shifter_area_um2,
            normquant_area_um2=normquant_area_um2,
            worst_setup_slack_ns=worst_setup_slack_ns,
            worst_hold_slack_ns=worst_hold_slack_ns,
        )

    finish(
        True,
        'all',
        'functional equivalence, stall hold, clear, Nangate45 mapped area, and OpenSTA timing closure passed',
        shifter_area_um2=shifter_area_um2,
        normquant_area_um2=normquant_area_um2,
        worst_setup_slack_ns=worst_setup_slack_ns,
        worst_hold_slack_ns=worst_hold_slack_ns,
    )
