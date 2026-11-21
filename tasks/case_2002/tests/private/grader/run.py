#!/usr/bin/env python3
"""Isolated private grader for case_2002 (Ibex TRVK capability revocation bridge backpressure,
heap-base underflow guard, flush recovery, and OpenSTA transparent channel timing budgets)."""
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
    'code/ibex_trvk.sv',
    'code/stream_fork.sv',
    'constraints.json',
}

IN_GROUPS = {
    'flush_i', 'heap_base_addr_i', 'upstream_req_i', 'upstream_rready_i',
    'upstream_we_i', 'upstream_be_i', 'upstream_addr_i', 'upstream_wdata_i',
    'upstream_wdata_intg_i', 'upstream_tag_i', 'downstream_gnt_i',
    'downstream_rvalid_i', 'downstream_rdata_i', 'downstream_rdata_intg_i',
    'downstream_err_i', 'downstream_tag_i', 'revbm_gnt_i', 'revbm_rvalid_i',
    'revbm_rdata_i', 'revbm_rdata_intg_i', 'revbm_err_i', 'alert_in', 'trace_in',
}
OUT_GROUPS = {
    'upstream_gnt_o', 'upstream_rvalid_o', 'upstream_rdata_o',
    'upstream_rdata_intg_o', 'upstream_err_o', 'upstream_tag_o',
    'downstream_req_o', 'downstream_we_o', 'downstream_be_o',
    'downstream_addr_o', 'downstream_wdata_o', 'downstream_wdata_intg_o',
    'downstream_tag_o', 'revbm_req_o', 'revbm_addr_o',
    'revbm_data_intg_error_o', 'revbm_device_error_o', 'alert_out', 'trace_out',
}
BUS_IN = {
    'heap_base_addr_i', 'upstream_be_i', 'upstream_addr_i', 'upstream_wdata_i',
    'upstream_wdata_intg_i', 'downstream_rdata_i', 'downstream_rdata_intg_i',
    'revbm_rdata_i', 'revbm_rdata_intg_i', 'alert_in', 'trace_in',
}
BUS_OUT = {
    'upstream_rdata_o', 'upstream_rdata_intg_o', 'downstream_be_o',
    'downstream_addr_o', 'downstream_wdata_o', 'downstream_wdata_intg_o',
    'revbm_addr_o', 'alert_out', 'trace_out',
}
IN_BITS = {f'{g}[{i}]' for g in ('alert_in', 'trace_in') for i in range(8)}
OUT_BITS = {f'{g}[{i}]' for g in ('alert_out', 'trace_out') for i in range(8)}
IN = IN_GROUPS | IN_BITS
OUT = OUT_GROUPS | OUT_BITS
NON_TRANSPARENT = (IN_GROUPS - {'alert_in', 'trace_in'}) | (OUT_GROUPS - {'alert_out', 'trace_out'})


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
        finish(res_path, 'FAIL', 'input_validation', 'Candidate directory missing or symlinked', args.seed)
    c = c_raw.resolve(strict=True)

    for entry in sorted(c.rglob('*')):
        if entry.is_symlink():
            finish(res_path, 'FAIL', 'policy', f'Symlink in candidate path: {entry.relative_to(c)}', args.seed)

    # 1. Protected file integrity check
    for pub_f in sorted(PUB.rglob('*')):
        if not pub_f.is_file():
            continue
        rel_str = str(pub_f.relative_to(PUB))
        if rel_str in EDITABLES:
            continue
        cand_f = c / rel_str
        if cand_f.exists():
            if not cand_f.is_file() or hashlib.sha256(cand_f.read_bytes()).digest() != hashlib.sha256(pub_f.read_bytes()).digest():
                finish(res_path, 'FAIL', 'policy', f'Protected file modified: {rel_str}', args.seed)

    # 2. Check editable RTL files
    for rel_rtl in ('code/ibex_trvk.sv', 'code/stream_fork.sv'):
        cf = c / rel_rtl
        if not cf.is_file():
            finish(res_path, 'FAIL', 'input_validation', f'Missing editable RTL: {rel_rtl}', args.seed)
        new_txt = cf.read_text(encoding='utf-8', errors='replace')
        old_txt = (PUB / rel_rtl).read_text(encoding='utf-8', errors='replace')
        viols = screen_hdl_escapes(new_txt, old_txt)
        if viols:
            finish(res_path, 'FAIL', 'policy', f'Policy violation in {rel_rtl}: {viols}', args.seed)

    # 3. Validate constraints.json schema and Tcl injection safety
    q = c / 'constraints.json'
    if not q.is_file() or q.stat().st_size > 16384:
        finish(res_path, 'FAIL', 'input_validation', 'Missing or invalid constraints.json file', args.seed)

    try:
        raw_text = q.read_text(encoding='utf-8')
        obj = json.loads(raw_text)
    except Exception as e:
        finish(res_path, 'FAIL', 'input_validation', f'Malformed JSON in constraints.json: {e}', args.seed)

    for s in scan_strings(obj):
        if re.search(
            r'[;\n\r${}*]|'
            r'\b(?:exec|open|socket|source|load|eval|interp|puts|read_verilog|read_liberty|read_lef|'
            r'create_clock|set_input_delay|set_output_delay|set_false_path|set_multicycle_path|'
            r'all_inputs|all_outputs|all_registers|get_ports|get_pins|get_nets|get_clocks)\b',
            s,
        ):
            finish(res_path, 'FAIL', 'policy', f'Forbidden Tcl/SDC injection token in constraints.json: {s!r}', args.seed)

    if not isinstance(obj, dict) or set(obj.keys()) != {'max_delays'}:
        finish(res_path, 'FAIL', 'input_validation', 'Top-level JSON object must contain only key "max_delays"', args.seed)
    rules = obj['max_delays']
    if not isinstance(rules, list) or len(rules) > 64:
        finish(res_path, 'FAIL', 'input_validation', '"max_delays" must be a list of at most 64 rule objects', args.seed)

    for idx, r in enumerate(rules):
        if not isinstance(r, dict) or set(r.keys()) != {'from', 'to', 'ns'}:
            finish(res_path, 'FAIL', 'input_validation', f'Rule {idx} must be an object with keys "from", "to", "ns"', args.seed)
        if not isinstance(r['from'], list) or not r['from'] or not all(isinstance(x, str) and x in IN for x in r['from']):
            finish(res_path, 'FAIL', 'input_validation', f'Rule {idx} has invalid "from" port group(s)', args.seed)
        if not isinstance(r['to'], list) or not r['to'] or not all(isinstance(x, str) and x in OUT for x in r['to']):
            finish(res_path, 'FAIL', 'input_validation', f'Rule {idx} has invalid "to" port group(s)', args.seed)
        if type(r['ns']) not in (int, float) or not math.isfinite(r['ns']) or not (0 < r['ns'] < 1000):
            finish(res_path, 'FAIL', 'input_validation', f'Rule {idx} has invalid "ns" delay value', args.seed)

    try:
        with tempfile.TemporaryDirectory(prefix='case_2002_') as tmp:
            t = pathlib.Path(tmp)
            code_dir = t / 'code'
            shutil.copytree(PUB / 'code', code_dir)
            shutil.copyfile(c / 'code/ibex_trvk.sv', code_dir / 'ibex_trvk.sv')
            shutil.copyfile(c / 'code/stream_fork.sv', code_dir / 'stream_fork.sv')

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

            rtl_files = [
                'prim_util_pkg.sv',
                'prim_mubi_pkg.sv',
                'prim_count_pkg.sv',
                'prim_secded_pkg.sv',
                'ibex_cheriot_pkg.sv',
                'prim_flop_macros.sv',
                'prim_count.sv',
                'prim_fifo_sync_cnt.sv',
                'prim_fifo_sync.sv',
                'prim_secded_inv_39_32_dec.sv',
                'stream_fork.sv',
                'stream_join_dynamic.sv',
                'ibex_trvk.sv',
                'ibex_trvk_bridge_top.sv',
            ]

            # 4. Verilator functional simulation
            obj_dir = t / 'obj_dir'
            build_cmd = [
                str(VERILATOR),
                '--binary',
                '--timing',
                '-MAKEFLAGS',
                'VM_PARALLEL_BUILDS=0 OPT_FAST=-O0 OPT_SLOW=-O0 OPT_GLOBAL=-O0',
                '-Wno-fatal',
                '-DSYNTHESIS',
                f'-I{code_dir}',
                '--top-module',
                'tb',
                '--Mdir',
                str(obj_dir),
                *(str(code_dir / x) for x in rtl_files),
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
                finish(res_path, 'FAIL', 'compile', f'Verilator compile failed: {b_proc.stdout[-1500:]}', args.seed)

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

            # 5. Yosys/Slang synthesis of ibex_trvk_bridge_top.sv + latch check
            lib = LIB / 'lib/NangateOpenCellLibrary_typical.lib'
            cmd_ys = (
                f'read_slang -DSYNTHESIS --top ibex_trvk_bridge_top -I{code_dir} '
                + ' '.join(str(code_dir / x) for x in rtl_files)
                + f'; synth -top ibex_trvk_bridge_top; read_liberty -lib {lib}; dfflibmap -liberty {lib}; abc -liberty {lib}; clean; check -assert; write_verilog -noattr {t / "mapped.v"}'
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

            mapped_txt = (t / 'mapped.v').read_text(encoding='utf-8')
            if re.search(r'\bDLH_|DLL_', mapped_txt):
                finish(res_path, 'FAIL', 'synthesis', 'Inferred standard-cell latches are forbidden in mapped netlist', args.seed)

            # 6. OpenROAD/OpenSTA timing evaluation
            def ports(groups):
                return ' '.join(
                    g + '*' if g in (BUS_IN | BUS_OUT) else g
                    for g in groups
                )

            lines = [
                f'read_lef {LIB}/lef/NangateOpenCellLibrary.tech.lef',
                f'read_lef {LIB}/lef/NangateOpenCellLibrary.macro.mod.lef',
                f'read_liberty {lib}',
                f'read_verilog {t}/mapped.v',
                'link_design ibex_trvk_bridge_top',
                f'create_clock -period {10 if args.seed % 2 else 12} [get_ports clk_i]',
                f'set_input_delay 4.0 -clock clk_i [get_ports {{{ports(sorted(IN_GROUPS))}}}]',
                f'set_output_delay 3.5 -clock clk_i [get_ports {{{ports(sorted(OUT_GROUPS))}}}]',
            ]
            for r in rules:
                lines.append(
                    f"set_max_delay {r['ns']} -from [get_ports {{{ports(r['from'])}}}] -to [get_ports {{{ports(r['to'])}}}]"
                )
            for name in ('alert', 'trace'):
                for bit in range(8):
                    lines += [
                        f'puts "BEGIN_{name}_{bit}"',
                        f'report_checks -from [get_ports {{{name}_in[{bit}]}}] -to [get_ports {{{name}_out[{bit}]}}] -path_delay max -format full_clock_expanded',
                        f'puts "END_{name}_{bit}"',
                    ]
            seq = [
                ('in', '-from [get_ports {flush_i upstream_req_i upstream_rready_i downstream_rvalid_i revbm_rvalid_i}] -to [all_registers -data_pins]'),
                ('out', '-from [all_registers -clock_pins] -to [get_ports {upstream_rvalid_o upstream_rdata_o* upstream_tag_o revbm_req_o revbm_addr_o*}]'),
                ('reg', '-from [all_registers -clock_pins] -to [all_registers -data_pins]'),
            ]
            for name, selection in seq:
                lines += [
                    f'puts "SEQ_BEGIN_{name}"',
                    f'report_checks {selection} -path_delay max -format full_clock_expanded',
                    f'puts "SEQ_END_{name}"',
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
                m = re.search(f'SEQ_BEGIN_{name}\\n(.*?)SEQ_END_{name}', out, re.S)
                if not m or 'slack' not in m.group(1) or 'Path Group: clk_i' not in m.group(1) or 'max_delay' in m.group(1):
                    finish(res_path, 'FAIL', 'timing', f'Registered path {name} missing or excepted by max_delay', args.seed)

            for r in rules:
                bad_ep = [ep for ep in (r['from'] + r['to']) if ep in NON_TRANSPARENT]
                if bad_ep:
                    finish(
                        res_path,
                        'FAIL',
                        'timing',
                        f'Registered bridge port(s) modified by max_delays exception: {", ".join(bad_ep)}',
                        args.seed,
                    )

            for name, target in [('alert', 1.5), ('trace', 2.5)]:
                for bit in range(8):
                    m = re.search(f'BEGIN_{name}_{bit}\\n(.*?)END_{name}_{bit}', out, re.S)
                    if not m:
                        finish(res_path, 'FAIL', 'timing', f'Missing STA report for {name}[{bit}]', args.seed)
                    slack_m = re.search(r'(-?\d+\.\d+)\s+slack\s+\(', m.group(1))
                    if not slack_m:
                        finish(res_path, 'FAIL', 'timing', f'Unconstrained path for {name}[{bit}]', args.seed)
                    slack_val = float(slack_m.group(1))
                    if abs(slack_val - target) >= 0.015:
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
                f'All TRVK backpressure, heap-base underflow, flush recovery, latch-free synthesis, and 16 transparent channel bits passed (seed={args.seed})',
                args.seed,
            )
    except subprocess.TimeoutExpired:
        finish(res_path, 'ERROR', 'environment', 'EDA simulation, synthesis, or STA timed out', args.seed)
    except OSError as e:
        finish(res_path, 'ERROR', 'environment', f'OS error running EDA tools: {e}', args.seed)


if __name__ == '__main__':
    main()
