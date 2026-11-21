#!/usr/bin/env python3
"""Isolated private grader for case_3011 (CV32E40P Int Controller + Sleep Unit & OpenSTA timing budgets)."""
import argparse
import hashlib
import json
import math
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


P = pathlib.Path(__file__).resolve().parents[2]
PUB = P / 'public'
PRIV = P / 'private'
LIB = pathlib.Path(
    str(_sb_nangate45_dir())
)
TOOLS = pathlib.Path(str(_sb_tools_dir()))
VERILATOR = TOOLS / 'verilator-v5.038/bin/verilator'
YOSYS = TOOLS / 'oss-cad-suite/bin/yosys'
OPENROAD = TOOLS / 'bin/openroad'

EDITABLES = {
    'code/cv32e40p_int_controller.sv',
    'code/cv32e40p_sleep_unit.sv',
    'constraints.json',
}

IN_GROUPS = {
    'rst_ni', 'scan_cg_en_i', 'cluster_mode_i', 'fetch_enable_i',
    'if_busy_i', 'ctrl_busy_i', 'lsu_busy_i', 'apu_busy_i',
    'pulp_clock_en_i', 'p_elw_start_i', 'p_elw_finish_i',
    'debug_p_elw_no_sleep_i', 'wake_from_ctrl_i',
    'irq_i', 'irq_sec_i', 'mie_bypass_i', 'm_ie_i', 'u_ie_i', 'current_priv_lvl_i',
    'clint_timer_in', 'eu_event_in',
}
OUT_GROUPS = {
    'fetch_enable_o', 'clk_gated_o', 'core_sleep_o',
    'mip_o', 'irq_req_ctrl_o', 'irq_sec_ctrl_o', 'irq_id_ctrl_o', 'irq_wu_ctrl_o',
    'clint_timer_out', 'eu_event_out',
}
IN_BITS = (
    {f'{g}[{i}]' for g in ('irq_i', 'mie_bypass_i') for i in range(32)}
    | {f'current_priv_lvl_i[{i}]' for i in range(2)}
    | {f'{g}[{i}]' for g in ('clint_timer_in', 'eu_event_in') for i in range(8)}
)
OUT_BITS = (
    {f'mip_o[{i}]' for i in range(32)}
    | {f'irq_id_ctrl_o[{i}]' for i in range(5)}
    | {f'{g}[{i}]' for g in ('clint_timer_out', 'eu_event_out') for i in range(8)}
)
IN = IN_GROUPS | IN_BITS
OUT = OUT_GROUPS | OUT_BITS
NON_TRANSPARENT = (
    (IN_GROUPS - {'clint_timer_in', 'eu_event_in'})
    | (OUT_GROUPS - {'clint_timer_out', 'eu_event_out'})
    | (IN_BITS - {f'{g}[{i}]' for g in ('clint_timer_in', 'eu_event_in') for i in range(8)})
    | (OUT_BITS - {f'{g}[{i}]' for g in ('clint_timer_out', 'eu_event_out') for i in range(8)})
)


def finish(result_path: pathlib.Path, verdict: str, stage: str, detail: str, seed: int, **extra):
    result = {
        'verdict': verdict,
        'stage': stage,
        'detail': detail,
        'message': detail,
        'reason': detail,
        'seed': seed,
        **extra,
    }
    result_path.parent.mkdir(parents=True, exist_ok=True)
    result_path.write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result))
    raise SystemExit(0 if verdict == 'PASS' else (1 if verdict == 'FAIL' else 2))


def scan_strings(node):
    if isinstance(node, str):
        yield node
    elif isinstance(node, list):
        for item in node:
            yield from scan_strings(item)
    elif isinstance(node, dict):
        for k, v in node.items():
            yield from scan_strings(k)
            yield from scan_strings(v)


def benign_directives(text: str) -> str:
    return re.sub(r'(?m)^[ \t]*`(?:timescale\s+[^\n]+|default_nettype\s+(?:none|wire)|resetall)[ \t]*$', '', text)


def mask_assertions(text: str) -> str:
    return re.sub(r'\$(?:fatal|error|warning)\b', '', text)


def screen_hdl_escapes(new_text: str, old_text: str) -> list[str]:
    clean = lambda s: re.sub(r'/\*.*?\*/|//[^\n]*', '', s, flags=re.S)
    new_c = mask_assertions(benign_directives(clean(new_text)))
    old_c = mask_assertions(benign_directives(clean(old_text)))
    violations = []
    escape_pats = [
        (
            r'\$(?:fopen|fclose|fread|fwrite|fdisplay|fscanf|system|finish|stop|readmemh|readmemb|writememh|writememb|dumpfile|dumpvars|value\$plusargs|test\$plusargs)\b',
            'forbidden_systask',
        ),
        (r'\b(?:force|release|bind|always_latch)\b', 'procedural_force_or_bind'),
        (r'\b(?:import|export)\s*"DPI', 'dpi_escape'),
        (r'\$root\b|\b(?:tb|grader|oracle|golden_ref)\s*\.', 'hierarchical_harness_reference'),
        (
            r'`\s*(?:ifdef|ifndef|elsif)\s+(?:VERILATOR|SYNTHESIS|SIMULATION|__ICARUS__|VCS|QUESTA)\b',
            'simulator_or_synthesis_macro_divergence',
        ),
    ]
    for pat, label in escape_pats:
        if len(re.findall(pat, new_c, re.I)) > len(re.findall(pat, old_c, re.I)):
            violations.append(label)
    for inc in re.findall(r'`include\s+"([^"]+)"', new_c):
        p = pathlib.PurePosixPath(inc)
        if p.is_absolute() or '..' in p.parts:
            violations.append('include_path_escape')
    return violations


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--candidate', required=True)
    ap.add_argument('--seed', type=int, required=True)
    ap.add_argument('--result', required=True)
    args = ap.parse_args()

    res_path = pathlib.Path(args.result).resolve()
    c_raw = pathlib.Path(args.candidate)
    if c_raw.is_symlink() or not c_raw.exists() or not c_raw.is_dir():
        finish(res_path, 'FAIL', 'anti_hack', 'Candidate directory missing or symlinked', args.seed)
    c = c_raw.resolve(strict=True)

    for entry in sorted(c.rglob('*')):
        if entry.is_symlink():
            finish(res_path, 'FAIL', 'anti_hack', f'Symlink in candidate path: {entry.relative_to(c)}', args.seed)

    for pub_f in sorted(PUB.rglob('*')):
        if not pub_f.is_file():
            continue
        rel_str = str(pub_f.relative_to(PUB))
        if rel_str in EDITABLES:
            continue
        cand_f = c / rel_str
        if cand_f.exists():
            if not cand_f.is_file() or hashlib.sha256(cand_f.read_bytes()).digest() != hashlib.sha256(pub_f.read_bytes()).digest():
                finish(res_path, 'FAIL', 'anti_hack', f'Protected file modified: {rel_str}', args.seed)

    for rel_rtl in ('code/cv32e40p_int_controller.sv', 'code/cv32e40p_sleep_unit.sv'):
        cf = c / rel_rtl
        if not cf.is_file():
            finish(res_path, 'FAIL', 'structural', f'Missing editable RTL: {rel_rtl}', args.seed)
        new_txt = cf.read_text(encoding='utf-8', errors='replace')
        old_txt = (PUB / rel_rtl).read_text(encoding='utf-8', errors='replace')
        viols = screen_hdl_escapes(new_txt, old_txt)
        if viols:
            finish(res_path, 'FAIL', 'anti_hack', f'Policy violation in {rel_rtl}: {viols}', args.seed)

    q = c / 'constraints.json'
    if not q.is_file() or q.stat().st_size > 16384:
        finish(res_path, 'FAIL', 'structural', 'Missing or invalid constraints.json file', args.seed)

    try:
        raw_text = q.read_text(encoding='utf-8')
        obj = json.loads(raw_text)
    except Exception as e:
        finish(res_path, 'FAIL', 'structural', f'Malformed JSON in constraints.json: {e}', args.seed)

    for s in scan_strings(obj):
        if re.search(
            r'[;\n\r${}*]|'
            r'\b(?:exec|open|socket|source|load|eval|interp|puts|read_verilog|read_liberty|read_lef|'
            r'create_clock|set_input_delay|set_output_delay|set_false_path|set_multicycle_path|'
            r'all_inputs|all_outputs|all_registers|get_ports|get_pins|get_nets|get_clocks)\b',
            s,
        ):
            finish(res_path, 'FAIL', 'anti_hack', f'Forbidden Tcl/SDC injection token in constraints.json: {s!r}', args.seed)

    if not isinstance(obj, dict) or set(obj.keys()) != {'max_delays'}:
        finish(res_path, 'FAIL', 'structural', 'Top-level JSON object must contain only key "max_delays"', args.seed)
    rules = obj['max_delays']
    if not isinstance(rules, list) or len(rules) > 64:
        finish(res_path, 'FAIL', 'structural', '"max_delays" must be a list of at most 64 rule objects', args.seed)

    for idx, r in enumerate(rules):
        if not isinstance(r, dict) or set(r.keys()) != {'from', 'to', 'ns'}:
            finish(res_path, 'FAIL', 'structural', f'Rule {idx} must be an object with keys "from", "to", "ns"', args.seed)
        if not isinstance(r['from'], list) or not r['from'] or not all(isinstance(x, str) and x in IN for x in r['from']):
            finish(res_path, 'FAIL', 'structural', f'Rule {idx} has invalid "from" port group(s)', args.seed)
        if not isinstance(r['to'], list) or not r['to'] or not all(isinstance(x, str) and x in OUT for x in r['to']):
            finish(res_path, 'FAIL', 'structural', f'Rule {idx} has invalid "to" port group(s)', args.seed)
        if type(r['ns']) not in (int, float) or not math.isfinite(r['ns']) or not (0 < r['ns'] < 1000):
            finish(res_path, 'FAIL', 'structural', f'Rule {idx} has invalid "ns" delay value', args.seed)

    try:
        with tempfile.TemporaryDirectory(prefix='case_3011_') as tmp:
            t = pathlib.Path(tmp)
            code_dir = t / 'code'
            shutil.copytree(PUB / 'code', code_dir)
            shutil.copyfile(c / 'code/cv32e40p_int_controller.sv', code_dir / 'cv32e40p_int_controller.sv')
            shutil.copyfile(c / 'code/cv32e40p_sleep_unit.sv', code_dir / 'cv32e40p_sleep_unit.sv')

            eda_env = os.environ.copy()
            eda_env.pop('VERILATOR_ROOT', None)
            eda_env.pop('LD_PRELOAD', None)
            eda_env.update({
                'PATH': f'{TOOLS / "oss-cad-suite/bin"}:{TOOLS / "bin"}:/usr/bin:/bin',
                'HOME': str(t),
                'TMPDIR': str(t),
                'OMP_NUM_THREADS': '1',
                'OPENBLAS_NUM_THREADS': '1',
                'MAKEFLAGS': '-j1',
            })

            obj_dir = t / 'obj_dir'
            build_cmd = [
                str(VERILATOR),
                '--binary',
                '--timing',
                '-MAKEFLAGS',
                'VM_PARALLEL_BUILDS=0 OPT_FAST=-O0 OPT_SLOW=-O0 OPT_GLOBAL=-O0',
                '-Wno-fatal',
                '--top-module',
                'tb',
                '--Mdir',
                str(obj_dir),
                str(code_dir / 'include/cv32e40p_pkg.sv'),
                str(code_dir / 'cv32e40p_sim_clock_gate.sv'),
                str(code_dir / 'cv32e40p_int_controller.sv'),
                str(code_dir / 'cv32e40p_sleep_unit.sv'),
                str(code_dir / 'top.sv'),
                str(PRIV / 'tests/tb.sv'),
            ]
            b_proc = subprocess.run(
                build_cmd,
                cwd=str(t),
                env=eda_env,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                timeout=180,
            )
            if b_proc.returncode != 0:
                finish(res_path, 'FAIL', 'structural', f'Verilator compile failed: {b_proc.stdout[-1500:]}', args.seed)

            s_proc = subprocess.run(
                [str(obj_dir / 'Vtb'), f'+SEED={args.seed}'],
                cwd=str(t),
                env=eda_env,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                timeout=60,
            )
            if s_proc.returncode != 0 or 'TB_PASS' not in s_proc.stdout or 'TB_FAIL' in s_proc.stdout:
                finish(res_path, 'FAIL', 'behavior', f'Functional simulation failed: {s_proc.stdout[-1500:]}', args.seed)

            files = [
                'include/cv32e40p_pkg.sv',
                'cv32e40p_sim_clock_gate.sv',
                'cv32e40p_int_controller.sv',
                'cv32e40p_sleep_unit.sv',
                'top.sv',
            ]
            lib = LIB / 'lib/NangateOpenCellLibrary_typical.lib'
            cmd_ys = (
                f'read_slang --top top --keep-hierarchy '
                + ' '.join(str(code_dir / x) for x in files)
                + '; hierarchy -check -top top; proc; opt_clean; '
                + 'select -assert-none cv32e40p_int_controller*/t:$dlatch* cv32e40p_int_controller*/t:$adlatch* cv32e40p_int_controller*/t:$latch* cv32e40p_int_controller*/t:$sr* cv32e40p_int_controller*/t:$_DLATCH* cv32e40p_sleep_unit*/t:$dlatch* cv32e40p_sleep_unit*/t:$adlatch* cv32e40p_sleep_unit*/t:$latch* cv32e40p_sleep_unit*/t:$sr* cv32e40p_sleep_unit*/t:$_DLATCH*; '
                + f'synth -top top; read_liberty -lib {lib}; dfflibmap -liberty {lib}; abc -liberty {lib}; clean; check -assert; write_verilog -noattr {t / "mapped.v"}'
            )
            p_ys = subprocess.run(
                [str(YOSYS), '-m', 'slang', '-Q', '-p', cmd_ys],
                cwd=str(t),
                env=eda_env,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                timeout=180,
            )
            if p_ys.returncode != 0 or not (t / 'mapped.v').is_file():
                finish(res_path, 'FAIL', 'synthesis', f'Yosys synthesis failed: {p_ys.stdout[-1500:]}', args.seed)

            bus_groups = {
                'irq_i', 'mie_bypass_i', 'current_priv_lvl_i',
                'mip_o', 'irq_id_ctrl_o',
                'clint_timer_in', 'clint_timer_out', 'eu_event_in', 'eu_event_out',
            }

            def ports(groups):
                return ' '.join(g + '*' if g in bus_groups else g for g in groups)

            lines = [
                f'read_lef {LIB}/lef/NangateOpenCellLibrary.tech.lef',
                f'read_lef {LIB}/lef/NangateOpenCellLibrary.macro.mod.lef',
                f'read_liberty {lib}',
                f'read_verilog {t}/mapped.v',
                'link_design top',
                f'create_clock -period {10 if args.seed % 2 else 12} [get_ports clk_i]',
                f'set_input_delay 3.50 -clock clk_i [get_ports {{{ports(sorted(IN_GROUPS))}}}]',
                f'set_output_delay 2.75 -clock clk_i [get_ports {{{ports(sorted(OUT_GROUPS))}}}]',
                'set_false_path -from [get_ports rst_ni]',
            ]
            for r in rules:
                lines.append(
                    f"set_max_delay {r['ns']} -from [get_ports {{{ports(r['from'])}}}] -to [get_ports {{{ports(r['to'])}}}]"
                )
            for name in ('clint_timer', 'eu_event'):
                for bit in range(8):
                    lines += [
                        f'puts "BEGIN_{name}_{bit}"',
                        f'report_checks -from [get_ports {{{name}_in[{bit}]}}] -to [get_ports {{{name}_out[{bit}]}}] -path_delay max -format full_clock_expanded',
                        f'puts "END_{name}_{bit}"',
                    ]
            seq = [
                ('in', '-from [get_ports {cluster_mode_i fetch_enable_i if_busy_i ctrl_busy_i lsu_busy_i apu_busy_i p_elw_start_i p_elw_finish_i debug_p_elw_no_sleep_i irq_i* irq_sec_i}] -to [all_registers -data_pins]'),
                ('out', '-from [all_registers -clock_pins] -to [get_ports {fetch_enable_o core_sleep_o mip_o* irq_req_ctrl_o irq_sec_ctrl_o irq_id_ctrl_o*}]'),
                ('reg', '-from [all_registers -clock_pins] -to [all_registers -data_pins]'),
            ]
            for name, selection in seq:
                lines += [
                    f'puts "SEQ_MAX_BEGIN_{name}"',
                    f'report_checks {selection} -path_delay max -format full_clock_expanded',
                    f'puts "SEQ_MAX_END_{name}"',
                    f'puts "SEQ_MIN_BEGIN_{name}"',
                    f'report_checks {selection} -path_delay min -format full_clock_expanded',
                    f'puts "SEQ_MIN_END_{name}"',
                ]

            script = t / 'sta.tcl'
            script.write_text('\n'.join(lines) + '\n', encoding='utf-8')
            p_sta = subprocess.run(
                [str(OPENROAD), '-exit', str(script)],
                cwd=str(t),
                env=eda_env,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                timeout=180,
            )
            out = p_sta.stdout
            if p_sta.returncode != 0:
                finish(res_path, 'ERROR', 'environment', f'OpenROAD failed: {out[-1500:]}', args.seed)

            for name, _ in seq:
                for kind in ('MAX', 'MIN'):
                    m = re.search(f'SEQ_{kind}_BEGIN_{name}\\n(.*?)SEQ_{kind}_END_{name}', out, re.S)
                    if not m or 'slack' not in m.group(1) or 'Path Group: clk_i' not in m.group(1) or 'max_delay' in m.group(1):
                        finish(res_path, 'FAIL', 'timing', f'Registered path {name} ({kind}) missing or excepted by max_delay', args.seed)
                    seq_slack_m = re.search(r'(-?\d+\.\d+)\s+slack\s+\(', m.group(1))
                    if not seq_slack_m or float(seq_slack_m.group(1)) < 0.0:
                        finish(res_path, 'FAIL', 'timing', f'Registered path {name} ({kind}) timing violation: slack={seq_slack_m.group(1) if seq_slack_m else "none"} ns', args.seed)

            for r in rules:
                bad_ep = [ep for ep in (r['from'] + r['to']) if ep in NON_TRANSPARENT]
                if bad_ep:
                    finish(
                        res_path,
                        'FAIL',
                        'timing',
                        f'Registered IntController/SleepUnit port(s) modified by max_delays exception: {", ".join(bad_ep)}',
                        args.seed,
                    )

            for name, target in [('clint_timer', 1.25), ('eu_event', 2.00)]:
                for bit in range(8):
                    m = re.search(f'BEGIN_{name}_{bit}\\n(.*?)END_{name}_{bit}', out, re.S)
                    if not m:
                        finish(res_path, 'FAIL', 'timing', f'Missing STA report for {name}[{bit}]', args.seed)
                    slack_m = re.search(r'(-?\d+\.\d+)\s+slack\s+\(', m.group(1))
                    if not slack_m:
                        finish(res_path, 'FAIL', 'timing', f'Unconstrained path for {name}[{bit}]', args.seed)
                    slack_val = float(slack_m.group(1))
                    if not (0.0 <= slack_val <= target + 0.015):
                        finish(
                            res_path,
                            'FAIL',
                            'timing',
                            f'{name}[{bit}] slack {slack_val:.2f} ns does not match target budget {target:.2f} ns',
                            args.seed,
                        )

            finish(
                res_path,
                'PASS',
                'timing',
                f'All functional IntController/SleepUnit checks and 16 transparent channel bits passed (seed={args.seed})',
                args.seed,
            )
    except subprocess.TimeoutExpired:
        finish(res_path, 'ERROR', 'environment', 'EDA simulation, synthesis, or STA timed out', args.seed)
    except OSError as e:
        finish(res_path, 'ERROR', 'environment', f'OS error running EDA tools: {e}', args.seed)


if __name__ == '__main__':
    main()
