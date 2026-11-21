#!/usr/bin/env python3
"""Trusted isolated grader for case_10012 (OpenPiton 8-Port Chipset I/O Crossbar Route Decoding, 8-Bit Payload Framing, Output Arbitration Fairness, and Timing Closure)."""
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

IC_AREA_LIMIT_UM2 = 195.0
OUT_AREA_LIMIT_UM2 = 720.0
CLOCK_PERIOD_NS = 0.85

EDITABLES = (
    'code/rtl/io_xbar_input_route_request_calc.v',
    'code/rtl/io_xbar_input_control.v',
    'code/rtl/io_xbar_output_control.v',
)

RO_FILES = (
    'code/LICENSE',
    'code/include/define.tmp.h',
    'code/include/network_define.v',
    'code/rtl/bus_compare_equal.v',
    'code/rtl/flip_bus.v',
    'code/rtl/net_dff.v',
    'code/rtl/one_of_eight.v',
    'code/rtl/space_avail_top.v',
    'code/rtl/io_xbar_output_datapath.v',
    'code/rtl/io_xbar_output_top.v',
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
    if re.search(r'\$root\b|\b(?:tb|u_ic|u_oc|u_top|grader|oracle)\s*\.', clean_no_dir):
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

    with tempfile.TemporaryDirectory(prefix='case_10012_') as tmpd:
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
            ro_rtl / 'space_avail_top.v',
            rtl_dir / 'io_xbar_input_route_request_calc.v',
            rtl_dir / 'io_xbar_input_control.v',
            rtl_dir / 'io_xbar_output_control.v',
            ro_rtl / 'io_xbar_output_datapath.v',
            ro_rtl / 'io_xbar_output_top.v',
        ]

        env = os.environ.copy()
        env.pop('LD_PRELOAD', None)
        env.update({
            'PATH': f'{TOOLS / "iverilog-v13/bin"}:{OSS_BIN}:{TOOLS / "bin"}:/usr/bin:/bin',
            'HOME': str(t),
            'TMPDIR': str(t),
            'OMP_NUM_THREADS': '1',
            'MAKEFLAGS': '-j1',
        })

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

        def run_yosys(top_name: str, src_files: list[pathlib.Path], out_v: pathlib.Path) -> float:
            ys = t / f'synth_{top_name}.ys'
            ys.write_text(
                f'read_slang --top {top_name} -I {inc_dir} ' + ' '.join(map(str, src_files)) + '\n'
                f'hierarchy -check -top {top_name}\n'
                f'synth -top {top_name}\n'
                'opt\n'
                f'dfflibmap -liberty {LIB}\n'
                f'abc -liberty {LIB}\n'
                'clean\n'
                f'read_liberty -lib {LIB}\n'
                'check -assert\n'
                f'stat -liberty {LIB}\n'
                f'write_verilog -noattr {out_v}\n'
            )
            yp = subprocess.run(
                [str(OSS_BIN / 'yosys'), '-Q', '-T', '-m', 'slang', str(ys)],
                cwd=t, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=180
            )
            m = re.search(r'Chip area for module .*?:\s*([\d.]+)', yp.stdout)
            if yp.returncode != 0 or not m or not out_v.is_file():
                finish(res_path, False, 'synthesis', f'Yosys synthesis failed on {top_name}: {yp.stdout[-1200:].strip()}')
            if re.search(r'\bDLH_|DLL_|TLAT', out_v.read_text(encoding='utf-8')):
                finish(res_path, False, 'synthesis', f'inferred latch detected in {top_name}')
            return round(float(m.group(1)), 3)

        mapped_ic = t / 'mapped_ic.v'
        ic_area_um2 = run_yosys(
            'io_xbar_input_control',
            [rtl_dir / 'io_xbar_input_route_request_calc.v', rtl_dir / 'io_xbar_input_control.v'],
            mapped_ic,
        )

        mapped_out = t / 'mapped_out.v'
        out_area_um2 = run_yosys(
            'io_xbar_output_top',
            [
                ro_rtl / 'one_of_eight.v',
                ro_rtl / 'space_avail_top.v',
                rtl_dir / 'io_xbar_output_control.v',
                ro_rtl / 'io_xbar_output_datapath.v',
                ro_rtl / 'io_xbar_output_top.v',
            ],
            mapped_out,
        )

        metrics = {
            'ic_area_um2': ic_area_um2,
            'ic_area_limit_um2': IC_AREA_LIMIT_UM2,
            'out_area_um2': out_area_um2,
            'out_area_limit_um2': OUT_AREA_LIMIT_UM2,
        }

        if ic_area_um2 > IC_AREA_LIMIT_UM2:
            finish(res_path, False, 'area', f'io_xbar_input_control area {ic_area_um2:.3f} um^2 exceeds limit {IC_AREA_LIMIT_UM2:.1f} um^2', **metrics)
        if out_area_um2 > OUT_AREA_LIMIT_UM2:
            finish(res_path, False, 'area', f'io_xbar_output_top area {out_area_um2:.3f} um^2 exceeds limit {OUT_AREA_LIMIT_UM2:.1f} um^2', **metrics)

        for label, netlist_p, die, core, repair, prefix in (
            ('io_xbar_input_control', mapped_ic, '60 60', '6 6 54 54', False, 'ic'),
            ('io_xbar_output_top', mapped_out, '90 90', '9 9 81 81', True, 'out'),
        ):
            tcl = t / f'flow_{prefix}.tcl'
            tcl.write_text(
                f'set_thread_count 1\n'
                f'read_lef {TECH_LEF}\n'
                f'read_lef {MACRO_LEF}\n'
                f'read_liberty {LIB}\n'
                f'read_verilog {netlist_p}\n'
                f'link_design {label}\n'
                f'initialize_floorplan -die_area {{0 0 {die}}} -core_area {{{core}}} -site FreePDK45_38x28_10R_NP_162NW_34O\n'
                f'create_clock -name clk -period {CLOCK_PERIOD_NS} [get_ports clk]\n'
                f'set_input_delay 0.15 -clock clk [all_inputs -no_clocks]\n'
                f'set_output_delay 0.15 -clock clk [all_outputs]\n'
                f'set_load 5.0 [all_outputs]\n'
                f'make_tracks\n'
                f'place_pins -hor_layers metal3 -ver_layers metal2\n'
                f'set_wire_rc -signal -layer metal3\n'
                f'set_wire_rc -clock -layer metal3\n'
                f'global_placement -density 0.50\n'
                f'estimate_parasitics -placement\n'
                + ('repair_design\ndetailed_placement\nestimate_parasitics -placement\n' if repair else '')
                + f'puts "=== SETUP ==="\n'
                f'report_checks -path_delay max -format full_clock_expanded\n'
                f'puts "=== HOLD ==="\n'
                f'report_checks -path_delay min -format full_clock_expanded\n'
                f'puts "BEGIN_SETUP_AUDIT"\n'
                f'check_setup -verbose\n'
                f'puts "END_SETUP_AUDIT"\n'
            )
            o_proc = subprocess.run(
                [str(OPENROAD), '-exit', str(tcl)],
                cwd=t, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=180
            )
            if o_proc.returncode != 0:
                finish(res_path, False, 'timing', f'OpenROAD failed on {label}: {o_proc.stdout[-1200:].strip()}', **metrics)
            setup_s, hold_s = check_sta_section(o_proc.stdout, label, res_path, **metrics)
            metrics[f'{prefix}_setup_slack_ns'] = setup_s
            metrics[f'{prefix}_hold_slack_ns'] = hold_s
            if setup_s < 0.0:
                finish(res_path, False, 'timing', f'{label} setup slack {setup_s:.3f} ns < 0.0 ns at {CLOCK_PERIOD_NS} ns clock', **metrics)
            if hold_s < 0.0:
                finish(res_path, False, 'timing', f'{label} hold slack {hold_s:.3f} ns < 0.0 ns', **metrics)

        finish(
            res_path, True, 'score',
            f'PASS functional, ic_area={ic_area_um2:.1f}, out_area={out_area_um2:.1f}, '
            f'ic_setup={metrics["ic_setup_slack_ns"]:.2f}, out_setup={metrics["out_setup_slack_ns"]:.2f}',
            **metrics
        )


if __name__ == '__main__':
    main()
