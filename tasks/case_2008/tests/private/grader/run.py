#!/usr/bin/env python3
"""Trusted isolated grader for case_2008 (Ibex Scrambling ICache + IF Stage + Zcmp + OpenSTA Boundary Budgets)."""
import argparse
import hashlib
import json
import math
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
VERILATOR = TOOLS_DIR / 'verilator-v5.038/bin/verilator'
YOSYS = TOOLS_DIR / 'oss-cad-suite/bin/yosys'
OPENROAD = TOOLS_DIR / 'bin/openroad'

EDITABLE_RTL = (
    pathlib.PurePosixPath('code/ibex_icache.sv'),
    pathlib.PurePosixPath('code/ibex_if_stage.sv'),
    pathlib.PurePosixPath('code/ibex_compressed_decoder.sv'),
)
EDITABLE_ALL = (*EDITABLE_RTL, pathlib.PurePosixPath('constraints.json'))

IN_GROUPS = {
    'cheriot_enable_i', 'boot_addr_i', 'req_i', 'debug_mode_i',
    'instr_gnt_i', 'instr_rvalid_i', 'instr_rdata_i', 'instr_bus_err_i',
    'ic_tag_rdata_i', 'ic_data_rdata_i', 'ic_scr_key_valid_i',
    'pmp_err_if_i', 'pmp_err_if_plus2_i', 'instr_valid_clear_i',
    'pc_set_i', 'pc_mux_i', 'nt_branch_mispredict_i', 'nt_branch_addr_i',
    'exc_pc_mux_i', 'exc_cause', 'dummy_instr_en_i', 'dummy_instr_mask_i',
    'dummy_instr_seed_en_i', 'dummy_instr_seed_i', 'icache_enable_i',
    'icache_inval_i', 'branch_target_ex_i', 'csr_mepc_i', 'csr_depc_i',
    'csr_mtvec_i', 'id_in_ready_i', 'pcc_cap_i',
    'scr_mon_in', 'pmp_mon_in',
}
OUT_GROUPS = {
    'instr_req_o', 'instr_addr_o', 'instr_intg_err_o',
    'ic_tag_req_o', 'ic_tag_write_o', 'ic_tag_addr_o', 'ic_tag_wdata_o',
    'ic_data_req_o', 'ic_data_write_o', 'ic_data_addr_o', 'ic_data_wdata_o',
    'ic_scr_key_req_o', 'instr_valid_id_o', 'instr_new_id_o',
    'instr_rdata_id_o', 'instr_rdata_alu_id_o', 'instr_rdata_c_id_o',
    'instr_is_compressed_id_o', 'instr_gets_expanded_id_o', 'instr_expanded_id_o',
    'instr_bp_taken_o', 'instr_fetch_err_o', 'instr_fetch_err_plus2_o',
    'illegal_c_insn_id_o', 'instr_fetch_cheriot_acc_vio_o',
    'instr_fetch_cheriot_bound_vio_o', 'dummy_instr_id_o',
    'pc_if_o', 'pc_id_o', 'icache_ecc_error_o', 'csr_mtvec_init_o',
    'pc_mismatch_alert_o', 'if_busy_o',
    'scr_mon_out', 'pmp_mon_out',
}
BUS_PORTS = {
    'cheriot_enable_i', 'boot_addr_i', 'instr_rdata_i', 'ic_tag_rdata_i',
    'ic_data_rdata_i', 'pc_mux_i', 'nt_branch_addr_i', 'exc_pc_mux_i',
    'exc_cause', 'dummy_instr_mask_i', 'dummy_instr_seed_i',
    'branch_target_ex_i', 'csr_mepc_i', 'csr_depc_i', 'csr_mtvec_i',
    'pcc_cap_i', 'scr_mon_in', 'pmp_mon_in',
    'instr_addr_o', 'ic_tag_req_o', 'ic_tag_addr_o', 'ic_tag_wdata_o',
    'ic_data_req_o', 'ic_data_addr_o', 'ic_data_wdata_o',
    'instr_rdata_id_o', 'instr_rdata_alu_id_o', 'instr_rdata_c_id_o',
    'instr_gets_expanded_id_o', 'instr_expanded_id_o',
    'pc_if_o', 'pc_id_o', 'scr_mon_out', 'pmp_mon_out',
}
VALID_IN = IN_GROUPS | {f'scr_mon_in[{i}]' for i in range(8)} | {f'pmp_mon_in[{i}]' for i in range(8)}
VALID_OUT = OUT_GROUPS | {f'scr_mon_out[{i}]' for i in range(8)} | {f'pmp_mon_out[{i}]' for i in range(8)}


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
    print(json.dumps(payload, indent=2))
    raise SystemExit(0 if verdict == 'PASS' else 2 if verdict == 'ERROR' else 1)


def sha256_file(path: pathlib.Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def strip_comments_and_strings(text: str) -> str:
    text = re.sub(r'(?is)//\s*pragma\s+translate_off.*?//\s*pragma\s+translate_on', ' ', text)
    text = re.sub(r'/\*.*?\*/|//[^\n]*|"(?:\\.|[^"\\])*"', ' ', text, flags=re.S)
    return text


def screen_hdl_escapes(rel_name: str, new_text: str, old_text: str, result_path: pathlib.Path):
    if len(new_text.encode('utf-8')) > 250_000:
        finish(result_path, 'FAIL', 'policy', f'{rel_name}: candidate file exceeds size limit')
    new_c = strip_comments_and_strings(new_text)
    old_c = strip_comments_and_strings(old_text)
    escape_pats = [
        (
            r'\$(?:fopen|fclose|fread|fwrite|fdisplay|fscanf|system|finish|stop|readmemh|readmemb|writememh|writememb|dumpfile|dumpvars|value\$plusargs|test\$plusargs)\b',
            'forbidden_systask',
        ),
        (r'\b(?:force|release|bind|defparam|always_latch)\b', 'procedural_force_or_bind'),
        (r'\b(?:import|export)\s*"DPI', 'dpi_escape'),
        (r'\$root\b|\b(?:tb|dut|grader|oracle|golden_ref)\s*\.', 'hierarchical_harness_reference'),
        (
            r'`\s*(?:ifdef|ifndef|elsif)\s+(?:VERILATOR|SYNTHESIS|SIMULATION|__ICARUS__|VCS|QUESTA)\b',
            'simulator_or_synthesis_macro_divergence',
        ),
    ]
    for pat, label in escape_pats:
        if len(re.findall(pat, new_c, re.I)) > len(re.findall(pat, old_c, re.I)):
            finish(result_path, 'FAIL', 'policy', f'Policy violation in {rel_name}: {label}')
    for inc in re.findall(r'`include\s+"([^"]+)"', new_c):
        p = pathlib.PurePosixPath(inc)
        if p.is_absolute() or '..' in p.parts or str(p) not in {'prim_assert.sv', 'dv_fcov_macros.svh', 'formal_tb_frag.svh'}:
            finish(result_path, 'FAIL', 'policy', f'Unauthorized include in {rel_name}: {inc}')


def scan_strings(x):
    if isinstance(x, str):
        yield x
    elif isinstance(x, dict):
        for k, v in x.items():
            yield from scan_strings(k)
            yield from scan_strings(v)
    elif isinstance(x, list):
        for v in x:
            yield from scan_strings(v)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--candidate', required=True)
    ap.add_argument('--seed', type=int, default=101)
    ap.add_argument('--result', required=True)
    args = ap.parse_args()

    res_path = pathlib.Path(args.result).resolve()
    cand_in = pathlib.Path(args.candidate)
    if not cand_in.is_dir() or any(x.is_symlink() for x in (cand_in, *cand_in.parents)):
        finish(res_path, 'FAIL', 'input_validation', 'Invalid or symlinked candidate directory')
    cand_dir = cand_in.resolve()

    editable_set = {str(r) for r in EDITABLE_ALL}

    # 1. Verify read-only files in code/ and lib/ are untouched
    for sub in ('code', 'lib'):
        for trusted_f in sorted((PUB_DIR / sub).rglob('*')):
            if not trusted_f.is_file():
                continue
            rel = trusted_f.relative_to(PUB_DIR)
            if str(rel) in editable_set:
                continue
            cand_f = cand_dir / rel
            if cand_f.exists() or cand_f.is_symlink():
                if (
                    cand_f.is_symlink()
                    or not cand_f.is_file()
                    or not cand_f.resolve().is_relative_to(cand_dir)
                    or sha256_file(cand_f) != sha256_file(trusted_f)
                ):
                    finish(res_path, 'FAIL', 'policy', f'Protected file modified or symlinked: {rel}')

    # 2. Screen editable RTL files
    cand_texts = {}
    for rel in EDITABLE_RTL:
        cf = cand_dir / rel
        if cf.is_symlink() or not cf.is_file() or not cf.resolve().is_relative_to(cand_dir):
            finish(res_path, 'FAIL', 'input_validation', f'Missing or symlinked editable file: {rel}')
        new_txt = cf.read_text(encoding='utf-8', errors='replace')
        old_txt = (PUB_DIR / rel).read_text(encoding='utf-8', errors='replace')
        screen_hdl_escapes(str(rel), new_txt, old_txt, res_path)
        mod_name = rel.stem
        clean_txt = strip_comments_and_strings(new_txt)
        if not re.search(rf'\bmodule\s+{mod_name}\b', clean_txt):
            finish(res_path, 'FAIL', 'structural', f'Expected module {mod_name} in {rel}')
        cand_texts[rel.name] = new_txt

    # 3. Screen constraints.json
    c_json_path = cand_dir / 'constraints.json'
    if c_json_path.is_symlink() or not c_json_path.is_file() or not c_json_path.resolve().is_relative_to(cand_dir):
        finish(res_path, 'FAIL', 'input_validation', 'Missing or symlinked constraints.json')
    try:
        c_obj = json.loads(c_json_path.read_text(encoding='utf-8'))
    except Exception as exc:
        finish(res_path, 'FAIL', 'input_validation', f'Invalid JSON in constraints.json: {exc}')

    for s in scan_strings(c_obj):
        if re.search(
            r'[;\n\r${}*]|'
            r'\b(?:exec|open|socket|source|load|eval|interp|puts|read_verilog|read_liberty|read_lef|'
            r'create_clock|set_input_delay|set_output_delay|set_false_path|set_multicycle_path|'
            r'all_inputs|all_outputs|all_registers|get_ports|get_pins|get_nets|get_clocks)\b',
            s,
        ):
            finish(res_path, 'FAIL', 'policy', f'Forbidden Tcl/SDC injection token in constraints.json: {s!r}')

    if not isinstance(c_obj, dict) or set(c_obj.keys()) != {'max_delays'}:
        finish(res_path, 'FAIL', 'input_validation', 'constraints.json must contain only key "max_delays"')
    rules = c_obj['max_delays']
    if not isinstance(rules, list) or len(rules) > 64:
        finish(res_path, 'FAIL', 'input_validation', '"max_delays" must be a list of at most 64 rule objects')

    for idx, r in enumerate(rules):
        if not isinstance(r, dict) or set(r.keys()) != {'from', 'to', 'ns'}:
            finish(res_path, 'FAIL', 'input_validation', f'Rule {idx} must have keys "from", "to", "ns"')
        if not isinstance(r['from'], list) or not r['from'] or not all(isinstance(x, str) and x in VALID_IN for x in r['from']):
            finish(res_path, 'FAIL', 'input_validation', f'Rule {idx} has invalid "from" port group(s)')
        if not isinstance(r['to'], list) or not r['to'] or not all(isinstance(x, str) and x in VALID_OUT for x in r['to']):
            finish(res_path, 'FAIL', 'input_validation', f'Rule {idx} has invalid "to" port group(s)')
        if type(r['ns']) not in (int, float) or not math.isfinite(r['ns']) or not (0 < r['ns'] < 1000):
            finish(res_path, 'FAIL', 'input_validation', f'Rule {idx} has invalid "ns" value')

    env = {
        'PATH': f'{TOOLS_DIR / "verilator-v5.038/bin"}:{TOOLS_DIR / "oss-cad-suite/bin"}:{TOOLS_DIR / "bin"}:/usr/bin:/bin',
        'HOME': '/tmp',
        'TMPDIR': '/tmp',
        'LANG': 'C.UTF-8',
        'OMP_NUM_THREADS': '1',
        'OPENBLAS_NUM_THREADS': '1',
        'MAKEFLAGS': '-j1',
        'VERILATOR_ROOT': str(TOOLS_DIR / 'verilator-v5.038/share/verilator'),
    }

    lib_dir = PUB_DIR / 'lib'
    ng_lib = lib_dir / 'NangateOpenCellLibrary_typical.lib'
    ng_tech_lef = lib_dir / 'NangateOpenCellLibrary.tech.lef'
    ng_macro_lef = lib_dir / 'NangateOpenCellLibrary.macro.mod.lef'

    try:
        with tempfile.TemporaryDirectory(prefix='case_2008_grade_') as tmpd:
            tmp = pathlib.Path(tmpd)
            code_dir = tmp / 'code'
            shutil.copytree(PUB_DIR / 'code', code_dir)
            for fname, txt in cand_texts.items():
                (code_dir / fname).write_text(txt, encoding='utf-8')
            shutil.copyfile(PRIV_DIR / 'tests/tb.sv', tmp / 'tb.sv')

            rtl_files = [
                str(code_dir / f)
                for f in (
                    'prim_util_pkg.sv', 'prim_cipher_pkg.sv', 'prim_secded_pkg.sv',
                    'ibex_pkg.sv', 'ibex_cheriot_pkg.sv',
                    'prim_buf.sv', 'prim_lfsr.sv',
                    'prim_secded_inv_28_22_dec.sv', 'prim_secded_inv_28_22_enc.sv',
                    'prim_secded_inv_39_32_dec.sv', 'prim_secded_inv_39_32_enc.sv',
                    'ibex_fetch_fifo.sv', 'ibex_prefetch_buffer.sv', 'ibex_icache.sv',
                    'ibex_dummy_instr.sv', 'ibex_branch_predict.sv',
                    'ibex_compressed_decoder.sv', 'ibex_if_stage.sv',
                    'ibex_icache_if_subsys_top.sv',
                )
            ]

            # 4. Verilator simulation
            obj_dir = tmp / 'obj'
            v_cmd = [
                str(VERILATOR),
                '--binary',
                '--timing',
                '-j', '1',
                '-Werror-LATCH',
                '-Wno-fatal',
                f'-I{code_dir}',
                '-DSYNTHESIS',
                f'-GSEED={args.seed}',
                '--top-module', 'tb',
                '--Mdir', str(obj_dir),
                *rtl_files,
                str(tmp / 'tb.sv'),
            ]
            c_proc = subprocess.run(v_cmd, cwd=tmp, env=env, capture_output=True, text=True, timeout=180)
            if c_proc.returncode != 0 or not (obj_dir / 'Vtb').is_file():
                tail = (c_proc.stdout + '\n' + c_proc.stderr).strip()[-1500:]
                stage = 'synthesis' if 'LATCH' in tail else 'structural'
                finish(res_path, 'FAIL', stage, f'Verilator compile/lint failed: {tail}')

            s_proc = subprocess.run([str(obj_dir / 'Vtb')], cwd=tmp, env=env, capture_output=True, text=True, timeout=60)
            sim_out = (s_proc.stdout + '\n' + s_proc.stderr).strip()
            if s_proc.returncode != 0 or 'TB_FAIL' in sim_out or f'PASS ibex_icache_if_subsys_top seed={args.seed}' not in sim_out:
                finish(res_path, 'FAIL', 'functional', f'Simulation failed (seed={args.seed}): {sim_out[-1500:]}', seed=args.seed)

            # 5. Yosys synthesis
            mapped_v = tmp / 'mapped.v'
            ys_script = (
                f'read_slang --top ibex_icache_if_subsys_top -I{code_dir} -DSYNTHESIS '
                + ' '.join(rtl_files) + '; '
                'hierarchy -check -top ibex_icache_if_subsys_top; '
                'proc; opt_clean; '
                'select -assert-none */t:$dlatch* */t:$adlatch* */t:$latch* */t:$sr* */t:$_DLATCH*; '
                'synth -top ibex_icache_if_subsys_top; '
                'opt; '
                f'dfflibmap -liberty {ng_lib}; '
                f'abc -liberty {ng_lib}; '
                'clean; '
                f'read_liberty -lib {ng_lib}; '
                'check -assert; '
                f'stat -liberty {ng_lib}; '
                f'write_verilog -noattr {mapped_v}'
            )
            y_proc = subprocess.run([str(YOSYS), '-m', 'slang', '-Q', '-T', '-p', ys_script], cwd=tmp, env=env, capture_output=True, text=True, timeout=180)
            y_out = (y_proc.stdout or '') + '\n' + (y_proc.stderr or '')
            if y_proc.returncode != 0 or not mapped_v.is_file():
                finish(res_path, 'FAIL', 'synthesis', f'Yosys/Slang synthesis failed: {y_out[-1500:]}')

            # 6. OpenROAD / OpenSTA timing evaluation
            def expand_ports(groups):
                return ' '.join(g + '*' if g in BUS_PORTS else g for g in groups)

            clk_period = 10.0 if (args.seed % 2 == 1) else 12.0
            tcl_lines = [
                f'read_lef {ng_tech_lef}',
                f'read_lef {ng_macro_lef}',
                f'read_liberty {ng_lib}',
                f'read_verilog {mapped_v}',
                'link_design ibex_icache_if_subsys_top',
                f'create_clock -name clk_i -period {clk_period} [get_ports clk_i]',
                'set_input_delay 3.5 -clock clk_i [all_inputs -no_clocks]',
                'set_output_delay 3.0 -clock clk_i [all_outputs]',
                'set_false_path -from [get_ports rst_ni]',
            ]
            for r in rules:
                tcl_lines.append(
                    f"set_max_delay {r['ns']} -from [get_ports {{{expand_ports(r['from'])}}}] -to [get_ports {{{expand_ports(r['to'])}}}]"
                )
            for name in ('scr_mon', 'pmp_mon'):
                for bit in range(8):
                    tcl_lines += [
                        f'puts "BEGIN_{name}_{bit}"',
                        f'report_checks -from [get_ports {{{name}_in[{bit}]}}] -to [get_ports {{{name}_out[{bit}]}}] -path_delay max -format full_clock_expanded',
                        f'puts "END_{name}_{bit}"',
                    ]
            tcl_lines += [
                'puts "BEGIN_REG_REG"',
                'report_checks -from [all_registers -clock_pins] -to [all_registers -data_pins] -path_delay max -format full_clock_expanded',
                'puts "END_REG_REG"',
            ]
            sta_tcl = tmp / 'sta.tcl'
            sta_tcl.write_text('\n'.join(tcl_lines) + '\n', encoding='utf-8')
            o_proc = subprocess.run([str(OPENROAD), '-exit', str(sta_tcl)], cwd=tmp, env=env, capture_output=True, text=True, timeout=120)
            o_out = (o_proc.stdout or '') + '\n' + (o_proc.stderr or '')
            if o_proc.returncode != 0:
                finish(res_path, 'FAIL', 'timing', f'OpenROAD STA failed: {o_out[-1500:]}')

            def extract_slack(tag: str) -> float:
                m = re.search(rf'BEGIN_{tag}\s+(.*?)END_{tag}', o_out, re.S)
                if not m:
                    finish(res_path, 'FAIL', 'timing', f'Missing timing report block for {tag}')
                ms = re.search(r'([-+]?\d+(?:\.\d+)?)\s+slack\b', m.group(1))
                if not ms:
                    finish(res_path, 'FAIL', 'timing', f'Missing slack value in timing report for {tag}')
                return float(ms.group(1))

            for name, target_budget in (('scr_mon', 1.25), ('pmp_mon', 2.25)):
                for bit in range(8):
                    slk = extract_slack(f'{name}_{bit}')
                    if abs(slk - target_budget) > 0.03:
                        finish(
                            res_path,
                            'FAIL',
                            'timing',
                            f'{name}[{bit}] slack {slk:.2f} ns does not match target internal budget {target_budget:.2f} ns',
                            seed=args.seed,
                        )

            reg_slk = extract_slack('REG_REG')
            if reg_slk < 0.0:
                finish(res_path, 'FAIL', 'timing', f'Sequential reg-to-reg setup slack {reg_slk:.2f} ns < 0.00 ns', seed=args.seed)

            finish(
                res_path,
                'PASS',
                'timing',
                f'PASS: functional, synthesis, and OpenSTA boundary budgets met (reg_slack={reg_slk:.2f} ns)',
                seed=args.seed,
                worst_setup_slack_ns=reg_slk,
            )
    except subprocess.TimeoutExpired:
        finish(res_path, 'ERROR', 'environment', 'Tool execution timed out')
    except OSError as exc:
        finish(res_path, 'ERROR', 'environment', f'OS error: {exc}')


if __name__ == '__main__':
    main()
