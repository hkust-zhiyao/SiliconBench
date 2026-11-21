#!/usr/bin/env python3
"""Trusted isolated grader for case_10002 (OpenPiton 5-port mesh router input/output control + PPA/STA closure)."""
import argparse
import hashlib
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
IVERILOG_BIN = TOOLS / 'iverilog-v13/bin/iverilog'
VVP_BIN = TOOLS / 'iverilog-v13/bin/vvp'
OSS_BIN = TOOLS / 'oss-cad-suite/bin'
OPENROAD = TOOLS / 'bin/openroad'
NANGATE = pathlib.Path(str(_sb_nangate45_dir()))
LIB = NANGATE / 'lib/NangateOpenCellLibrary_typical.lib'
TECH_LEF = NANGATE / 'lef/NangateOpenCellLibrary.tech.lef'
MACRO_LEF = NANGATE / 'lef/NangateOpenCellLibrary.macro.mod.lef'

IC_AREA_LIMIT_UM2 = 232.0
OUT_AREA_LIMIT_UM2 = 472.0
CLOCK_PERIOD_NS = 0.85

EDITABLES = (
    'code/rtl/dynamic_input_route_request_calc.v',
    'code/rtl/dynamic_input_control.v',
    'code/rtl/dynamic_output_control.v',
)

RO_FILES = (
    'code/LICENSE',
    'code/include/define.tmp.h',
    'code/include/network_define.v',
    'code/rtl/bus_compare_equal.v',
    'code/rtl/flip_bus.v',
    'code/rtl/net_dff.v',
    'code/rtl/one_of_eight.v',
    'code/rtl/one_of_five.v',
    'code/rtl/network_input_blk_multi_out.v',
    'code/rtl/space_avail_top.v',
    'code/rtl/dynamic_input_top_4.v',
    'code/rtl/dynamic_input_top_16.v',
    'code/rtl/dynamic_output_datapath.v',
    'code/rtl/dynamic_output_top.v',
    'code/rtl/dynamic_node_top.v',
    'code/rtl/dynamic_node_top_wrap.v',
)


def finish(result_path: pathlib.Path, ok: bool, stage: str, reason: str, **extra):
    payload = {
        'verdict': 'PASS' if ok else 'FAIL',
        'stage': stage,
        'reason': reason,
        'detail': reason,
        **extra,
    }
    result_path.parent.mkdir(parents=True, exist_ok=True)
    result_path.write_text(json.dumps(payload, indent=2) + '\n')
    print(json.dumps(payload))
    raise SystemExit(0 if ok else 1)


def sha256_bytes(p: pathlib.Path) -> str:
    return hashlib.sha256(p.read_bytes()).hexdigest()


def screen_rtl(rel_name: str, raw_text: str, result_path: pathlib.Path):
    if len(raw_text.encode('utf-8')) > 200_000:
        finish(result_path, False, 'policy', f'{rel_name} exceeds size limit')
    if re.search(r'(?i)(?:pragma|synopsys|synthesis|verilator)\s+(?:translate_)?(?:off|on)', raw_text):
        finish(result_path, False, 'policy', f'disallowed simulation/synthesis pragma in {rel_name}')
    clean = re.sub(r'/\*.*?\*/|//[^\n]*', ' ', raw_text, flags=re.S)
    clean_no_dir = re.sub(
        r'`(?:timescale|resetall|default_nettype|include|define|ifdef|ifndef|endif)\b[^\n]*',
        ' ',
        clean,
    )
    if re.search(
        r'\$(?:fopen|fclose|fread|fwrite|fdisplay|fscanf|system|finish|stop|fatal|error|warning'
        r'|readmemh|readmemb|writememh|writememb|dumpfile|dumpvars|value\$plusargs|test\$plusargs|urandom|random)\b'
        r'|\b(?:initial|final|force|release|bind|primitive|blackbox|whitebox|always_latch|import\s*"DPI|export\s*"DPI)\b'
        r'|#\s*\d',
        clean_no_dir,
    ):
        finish(result_path, False, 'policy', f'disallowed system task, procedural escape, or delay in {rel_name}')
    if re.search(r'\$root\b|\b(?:tb|u_ic|u_oc|u_router|grader|oracle)\s*\.', clean_no_dir):
        finish(result_path, False, 'policy', f'illegal hierarchical reference in {rel_name}')
    if re.search(r'`\s*(?:ifdef|ifndef|elsif)\s+(?:VERILATOR|SYNTHESIS|SIMULATION|__ICARUS__|VCS|QUESTA)\b', clean, re.I):
        finish(result_path, False, 'policy', f'simulator/synthesis macro divergence in {rel_name}')
    for inc in re.findall(r'`include\s+"([^"]+)"', clean):
        p = pathlib.PurePosixPath(inc)
        if p.is_absolute() or '..' in p.parts:
            finish(result_path, False, 'policy', f'include path escape in {rel_name}')


def check_sta_section(log_txt: str, label: str, result_path: pathlib.Path, **metrics):
    setup_sec = re.search(r'=== SETUP ===(.*?)=== HOLD ===', log_txt, re.S)
    hold_sec = re.search(r'=== HOLD ===(.*?)BEGIN_SETUP_AUDIT', log_txt, re.S)
    audit_sec = re.search(r'BEGIN_SETUP_AUDIT(.*?)END_SETUP_AUDIT', log_txt, re.S)
    if not setup_sec or not hold_sec or not audit_sec:
        finish(result_path, False, 'timing', f'incomplete OpenROAD STA report sections for {label}', **metrics)
    audit_txt = audit_sec.group(1).strip()
    if audit_txt or re.search(r'clock not found|unconstrained|no clock', audit_txt, re.I):
        finish(result_path, False, 'timing', f'timing constraint audit failed for {label}: {audit_txt}', **metrics)
    setup_slacks = [float(v) for v in re.findall(r'([-+\d.]+)\s+slack \((?:MET|VIOLATED)\)', setup_sec.group(1))]
    hold_slacks = [float(v) for v in re.findall(r'([-+\d.]+)\s+slack \((?:MET|VIOLATED)\)', hold_sec.group(1))]
    if not setup_slacks or not hold_slacks:
        finish(result_path, False, 'timing', f'no setup or hold slack values parsed for {label}', **metrics)
    return round(min(setup_slacks), 3), round(min(hold_slacks), 3)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--candidate', required=True)
    ap.add_argument('--seed', type=int, default=1)
    ap.add_argument('--result', required=True)
    args = ap.parse_args()

    res_path = pathlib.Path(args.result).resolve()
    try:
        cand_in = pathlib.Path(args.candidate)
        if cand_in.is_symlink() or not cand_in.is_dir():
            finish(res_path, False, 'policy', 'candidate directory missing or symlinked')
        cand = cand_in.resolve(strict=True)
    except Exception as e:
        finish(res_path, False, 'policy', f'invalid candidate directory: {e}')

    for entry in sorted(cand.rglob('*')):
        if entry.is_symlink():
            finish(res_path, False, 'policy', f'symlink in candidate directory: {entry.relative_to(cand)}')

    # 1. Verify read-only files if present in candidate
    for rel_str in RO_FILES:
        ref = PUB / rel_str
        q = cand / rel_str
        if q.exists():
            if not q.is_file() or sha256_bytes(q) != sha256_bytes(ref):
                finish(res_path, False, 'policy', f'protected file modified: {rel_str}')

    for lib_f in (PUB / 'lib').iterdir():
        q = cand / 'lib' / lib_f.name
        if q.exists():
            if not q.is_file() or sha256_bytes(q) != sha256_bytes(lib_f):
                finish(res_path, False, 'policy', f'protected lib file modified: lib/{lib_f.name}')

    # 2. Load and screen editable RTL files
    cand_sources = {}
    for rel_str in EDITABLES:
        p = cand / rel_str
        if not p.exists():
            alt = cand / pathlib.Path(rel_str).name
            if alt.exists():
                p = alt
        if not p.is_file() or not p.resolve().is_relative_to(cand):
            finish(res_path, False, 'policy', f'missing editable file: {rel_str}')
        txt = p.read_text(encoding='utf-8', errors='replace')
        screen_rtl(rel_str, txt, res_path)
        cand_sources[pathlib.Path(rel_str).name] = txt

    with tempfile.TemporaryDirectory(prefix='case_10002_') as tmpd:
        t = pathlib.Path(tmpd)
        rtl_dir = t / 'rtl'
        rtl_dir.mkdir()
        for fname, txt in cand_sources.items():
            (rtl_dir / fname).write_text(txt, encoding='utf-8')

        inc_dir = PUB / 'code/include'
        ro_rtl = PUB / 'code/rtl'
        sim_files = [
            ro_rtl / 'bus_compare_equal.v',
            ro_rtl / 'flip_bus.v',
            ro_rtl / 'net_dff.v',
            ro_rtl / 'one_of_eight.v',
            ro_rtl / 'one_of_five.v',
            ro_rtl / 'network_input_blk_multi_out.v',
            ro_rtl / 'space_avail_top.v',
            rtl_dir / 'dynamic_input_route_request_calc.v',
            rtl_dir / 'dynamic_input_control.v',
            ro_rtl / 'dynamic_input_top_4.v',
            ro_rtl / 'dynamic_input_top_16.v',
            rtl_dir / 'dynamic_output_control.v',
            ro_rtl / 'dynamic_output_datapath.v',
            ro_rtl / 'dynamic_output_top.v',
            ro_rtl / 'dynamic_node_top.v',
            ro_rtl / 'dynamic_node_top_wrap.v',
        ]

        env = os.environ.copy()
        env.update({
            'PATH': f'{TOOLS / "iverilog-v13/bin"}:{OSS_BIN}:{TOOLS / "bin"}:/usr/bin:/bin',
            'HOME': str(t),
            'TMPDIR': str(t),
            'OMP_NUM_THREADS': '1',
            'MAKEFLAGS': '-j1',
        })

        # 3. Functional simulation (Icarus Verilog) across multiple seeds
        sim_vvp = t / 'sim.vvp'
        c_proc = subprocess.run(
            [str(IVERILOG_BIN), '-g2012', '-s', 'tb', '-I', str(inc_dir), '-o', str(sim_vvp),
             *map(str, sim_files), str(PRIV / 'tests/tb.sv')],
            cwd=t, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=60
        )
        if c_proc.returncode != 0:
            finish(res_path, False, 'behavior', f'Icarus compile failed: {c_proc.stdout[-1200:].strip()}')

        for s in (args.seed, args.seed + 100):
            r_proc = subprocess.run(
                [str(VVP_BIN), str(sim_vvp), f'+SEED={s}'],
                cwd=t, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=60
            )
            if r_proc.returncode != 0 or 'TB_PASS' not in r_proc.stdout or 'TB_FAIL' in r_proc.stdout:
                finish(res_path, False, 'behavior', f'Functional check failed (seed={s}): {r_proc.stdout[-1200:].strip()}')

        # 4a. Yosys/Slang synthesis on dynamic_input_control
        mapped_ic = t / 'mapped_ic.v'
        ys_ic = t / 'synth_ic.ys'
        ys_ic.write_text(
            f'read_slang --top dynamic_input_control -I {inc_dir} '
            f'{rtl_dir / "dynamic_input_route_request_calc.v"} {rtl_dir / "dynamic_input_control.v"}\n'
            'hierarchy -check -top dynamic_input_control\n'
            'synth -top dynamic_input_control\n'
            'opt\n'
            f'dfflibmap -liberty {LIB}\n'
            f'abc -liberty {LIB}\n'
            'clean\n'
            f'read_liberty -lib {LIB}\n'
            'check -assert\n'
            f'stat -liberty {LIB}\n'
            f'write_verilog -noattr {mapped_ic}\n'
        )
        y_ic = subprocess.run(
            [str(OSS_BIN / 'yosys'), '-Q', '-T', '-m', 'slang', str(ys_ic)],
            cwd=t, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=180
        )
        m_ic = re.search(r'Chip area for module .*?:\s*([\d.]+)', y_ic.stdout)
        if y_ic.returncode != 0 or not m_ic or not mapped_ic.is_file():
            finish(res_path, False, 'synthesis', f'Yosys synthesis failed on dynamic_input_control: {y_ic.stdout[-1200:].strip()}')
        if re.search(r'\bDLH_|DLL_|TLAT', mapped_ic.read_text(encoding='utf-8')):
            finish(res_path, False, 'synthesis', 'inferred latch detected in dynamic_input_control')
        ic_area_um2 = round(float(m_ic.group(1)), 3)

        # 4b. Yosys/Slang synthesis on dynamic_output_top
        mapped_out = t / 'mapped_out.v'
        ys_out = t / 'synth_out.ys'
        ys_out.write_text(
            f'read_slang --top dynamic_output_top -I {inc_dir} '
            f'{ro_rtl / "one_of_five.v"} {ro_rtl / "space_avail_top.v"} '
            f'{rtl_dir / "dynamic_output_control.v"} {ro_rtl / "dynamic_output_datapath.v"} '
            f'{ro_rtl / "dynamic_output_top.v"}\n'
            'hierarchy -check -top dynamic_output_top\n'
            'synth -top dynamic_output_top\n'
            'opt\n'
            f'dfflibmap -liberty {LIB}\n'
            f'abc -liberty {LIB}\n'
            'clean\n'
            f'read_liberty -lib {LIB}\n'
            'check -assert\n'
            f'stat -liberty {LIB}\n'
            f'write_verilog -noattr {mapped_out}\n'
        )
        y_out = subprocess.run(
            [str(OSS_BIN / 'yosys'), '-Q', '-T', '-m', 'slang', str(ys_out)],
            cwd=t, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=180
        )
        m_out = re.search(r'Chip area for module .*?:\s*([\d.]+)', y_out.stdout)
        if y_out.returncode != 0 or not m_out or not mapped_out.is_file():
            finish(res_path, False, 'synthesis', f'Yosys synthesis failed on dynamic_output_top: {y_out.stdout[-1200:].strip()}')
        if re.search(r'\bDLH_|DLL_|TLAT', mapped_out.read_text(encoding='utf-8')):
            finish(res_path, False, 'synthesis', 'inferred latch detected in dynamic_output_top')
        out_area_um2 = round(float(m_out.group(1)), 3)

        metrics = {
            'ic_area_um2': ic_area_um2,
            'ic_area_limit_um2': IC_AREA_LIMIT_UM2,
            'out_area_um2': out_area_um2,
            'out_area_limit_um2': OUT_AREA_LIMIT_UM2,
        }

        if ic_area_um2 > IC_AREA_LIMIT_UM2:
            finish(
                res_path, False, 'area',
                f'dynamic_input_control area {ic_area_um2:.3f} um^2 exceeds limit {IC_AREA_LIMIT_UM2:.1f} um^2',
                **metrics
            )
        if out_area_um2 > OUT_AREA_LIMIT_UM2:
            finish(
                res_path, False, 'area',
                f'dynamic_output_top area {out_area_um2:.3f} um^2 exceeds limit {OUT_AREA_LIMIT_UM2:.1f} um^2',
                **metrics
            )

        # 5a. OpenROAD STA on dynamic_input_control at 0.85 ns
        env_ic = dict(env)
        env_ic.update({
            'TECH_LEF': str(TECH_LEF),
            'MACRO_LEF': str(MACRO_LEF),
            'LIB_FILE': str(LIB),
            'NETLIST': str(mapped_ic),
        })
        o_ic = subprocess.run(
            [str(OPENROAD), '-exit', str(PRIV / 'tests/flow_ic.tcl')],
            cwd=t, env=env_ic, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=180
        )
        if o_ic.returncode != 0:
            finish(res_path, False, 'timing', f'OpenROAD failed on dynamic_input_control: {o_ic.stdout[-1200:].strip()}', **metrics)
        ic_setup, ic_hold = check_sta_section(o_ic.stdout, 'dynamic_input_control', res_path, **metrics)
        metrics['ic_setup_slack_ns'] = ic_setup
        metrics['ic_hold_slack_ns'] = ic_hold

        # 5b. OpenROAD STA on dynamic_output_top at 0.85 ns
        env_out = dict(env)
        env_out.update({
            'TECH_LEF': str(TECH_LEF),
            'MACRO_LEF': str(MACRO_LEF),
            'LIB_FILE': str(LIB),
            'NETLIST': str(mapped_out),
        })
        o_out = subprocess.run(
            [str(OPENROAD), '-exit', str(PRIV / 'tests/flow_out.tcl')],
            cwd=t, env=env_out, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=180
        )
        if o_out.returncode != 0:
            finish(res_path, False, 'timing', f'OpenROAD failed on dynamic_output_top: {o_out.stdout[-1200:].strip()}', **metrics)
        out_setup, out_hold = check_sta_section(o_out.stdout, 'dynamic_output_top', res_path, **metrics)
        metrics['out_setup_slack_ns'] = out_setup
        metrics['out_hold_slack_ns'] = out_hold

        if ic_setup < 0.0:
            finish(res_path, False, 'timing', f'dynamic_input_control setup slack {ic_setup:.3f} ns < 0.0 ns at {CLOCK_PERIOD_NS} ns clock', **metrics)
        if ic_hold < 0.0:
            finish(res_path, False, 'timing', f'dynamic_input_control hold slack {ic_hold:.3f} ns < 0.0 ns', **metrics)
        if out_setup < 0.0:
            finish(res_path, False, 'timing', f'dynamic_output_top setup slack {out_setup:.3f} ns < 0.0 ns at {CLOCK_PERIOD_NS} ns clock', **metrics)
        if out_hold < 0.0:
            finish(res_path, False, 'timing', f'dynamic_output_top hold slack {out_hold:.3f} ns < 0.0 ns', **metrics)

        finish(
            res_path, True, 'score',
            f'PASS functional, ic_area={ic_area_um2:.3f} um^2, out_area={out_area_um2:.3f} um^2, ic_setup={ic_setup:.3f} ns, out_setup={out_setup:.3f} ns',
            **metrics
        )


if __name__ == '__main__':
    main()
