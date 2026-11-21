#!/usr/bin/env python3
"""Trusted isolated grader for case_1009 (OpenTitan HMAC Core & SHA-256 Padding Subsystem + Nangate45 PPA/STA)."""
import argparse
import hashlib
import json
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


TASK_DIR = pathlib.Path(__file__).resolve().parents[2]
PRIV_DIR = TASK_DIR / 'private'
PUB_DIR = TASK_DIR / 'public'

TOOLS_DIR = pathlib.Path(str(_sb_tools_dir()))
VERILATOR = TOOLS_DIR / 'verilator-v5.038/bin/verilator'
YOSYS = TOOLS_DIR / 'oss-cad-suite/bin/yosys'
OPENROAD = TOOLS_DIR / 'bin/openroad'

AREA_LIMIT_UM2 = 4150.0
CLOCK_PERIOD_NS = 2.75
MIN_SETUP_SLACK_NS = 0.0
MIN_HOLD_SLACK_NS = 0.0

EDITABLE_REL = (
    pathlib.PurePosixPath('code/hmac_core.sv'),
    pathlib.PurePosixPath('code/prim_sha2_pad.sv'),
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
        if p.is_absolute() or '..' in p.parts or str(p) not in {'prim_assert.sv'}:
            finish(result_path, 'FAIL', 'policy', f'Unauthorized include in {rel_name}: {inc}')


def resolve_candidate_file(cand_dir: pathlib.Path, rel: pathlib.PurePosixPath) -> pathlib.Path:
    p1 = cand_dir / rel
    if p1.exists() or p1.is_symlink():
        return p1
    p2 = cand_dir / pathlib.PurePosixPath(*rel.parts[1:])
    if p2.exists() or p2.is_symlink():
        return p2
    return p1


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

    editable_set = {str(r) for r in EDITABLE_REL}

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

    cand_texts = {}
    for rel in EDITABLE_REL:
        cf = resolve_candidate_file(cand_dir, rel)
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
        with tempfile.TemporaryDirectory(prefix='case_1009_grade_') as tmpd:
            tmp = pathlib.Path(tmpd)
            code_dir = tmp / 'code'
            shutil.copytree(PUB_DIR / 'code', code_dir)
            for fname, txt in cand_texts.items():
                (code_dir / fname).write_text(txt, encoding='utf-8')
            shutil.copyfile(PRIV_DIR / 'tests/tb.sv', tmp / 'tb.sv')

            rtl_files = [
                str(code_dir / 'prim_sha2_pkg.sv'),
                str(code_dir / 'prim_sha2_pad.sv'),
                str(code_dir / 'hmac_core.sv'),
                str(code_dir / 'ot_hmac_pad_top.sv'),
            ]

            obj_dir = tmp / 'obj'
            v_cmd = [
                str(VERILATOR),
                '--binary',
                '--timing',
                '-j', '1',
                '-O0',
                '--CFLAGS', '-O0 -g0',
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
            if s_proc.returncode != 0 or f'PASS ot_hmac_pad_top seed={args.seed}' not in sim_out:
                finish(res_path, 'FAIL', 'functional', f'Simulation failed (seed={args.seed}): {sim_out[-1500:]}', seed=args.seed)

            mapped_v = tmp / 'mapped.v'
            ys_script = (
                f'read_slang --ignore-assertions --top ot_hmac_pad_top -I{code_dir} -DSYNTHESIS '
                + ' '.join(rtl_files) + '; '
                'hierarchy -check -top ot_hmac_pad_top; '
                'synth -top ot_hmac_pad_top; '
                'opt; '
                f'dfflibmap -liberty {ng_lib}; '
                f'abc -liberty {ng_lib}; '
                'clean; '
                f'read_liberty -lib {ng_lib}; '
                'check -assert; '
                f'stat -liberty {ng_lib}; '
                f'write_verilog -noattr {mapped_v}'
            )
            y_proc = subprocess.run(
                [str(YOSYS), '-m', 'slang', '-Q', '-T', '-p', ys_script],
                cwd=tmp,
                env=env,
                capture_output=True,
                text=True,
                timeout=180,
            )
            y_out = (y_proc.stdout or '') + '\n' + (y_proc.stderr or '')
            m_area = re.findall(r'Chip area for module .*?:\s*([0-9.]+)', y_out)
            if y_proc.returncode != 0 or not m_area or not mapped_v.is_file():
                finish(res_path, 'FAIL', 'synthesis', f'Yosys/Slang synthesis failed: {y_out[-1500:]}')

            area_um2 = round(float(m_area[-1]), 3)
            if area_um2 > AREA_LIMIT_UM2:
                finish(
                    res_path,
                    'FAIL',
                    'area',
                    f'Mapped cell area {area_um2:.3f} um^2 exceeds limit {AREA_LIMIT_UM2:.1f} um^2',
                    area_um2=area_um2,
                    area_limit_um2=AREA_LIMIT_UM2,
                )

            sta_tcl = tmp / 'sta.tcl'
            sta_tcl.write_text(
                f'read_lef {ng_tech_lef}\n'
                f'read_lef {ng_macro_lef}\n'
                f'read_liberty {ng_lib}\n'
                f'read_verilog {mapped_v}\n'
                'link_design ot_hmac_pad_top\n'
                f'create_clock -name clk_i -period {CLOCK_PERIOD_NS} [get_ports clk_i]\n'
                'set_input_delay 0.15 -clock clk_i [all_inputs -no_clocks]\n'
                'set_output_delay 0.15 -clock clk_i [all_outputs]\n'
                'set_load 5.0 [all_outputs]\n'
                'set_false_path -from [get_ports rst_ni]\n'
                'check_setup -verbose\n'
                'puts "=== SETUP ==="\n'
                'report_checks -path_delay max -format full_clock_expanded -digits 4\n'
                'puts "=== HOLD ==="\n'
                'report_checks -path_delay min -format full_clock_expanded -digits 4\n',
                encoding='utf-8',
            )
            o_proc = subprocess.run([str(OPENROAD), '-exit', str(sta_tcl)], cwd=tmp, env=env, capture_output=True, text=True, timeout=120)
            o_out = (o_proc.stdout or '') + '\n' + (o_proc.stderr or '')
            if o_proc.returncode != 0:
                finish(res_path, 'FAIL', 'timing', f'OpenROAD STA failed: {o_out[-1500:]}', area_um2=area_um2)

            setup_sec = re.search(r'=== SETUP ===(.*?)=== HOLD ===', o_out, re.S)
            hold_sec = re.search(r'=== HOLD ===(.*)', o_out, re.S)
            if not setup_sec or not hold_sec:
                finish(res_path, 'FAIL', 'timing', 'Missing setup or hold STA report sections', area_um2=area_um2)

            setup_slacks = [float(v) for v in re.findall(r'(-?[0-9]+\.[0-9]+)\s+slack\s+\((?:MET|VIOLATED)\)', setup_sec.group(1))]
            hold_slacks = [float(v) for v in re.findall(r'(-?[0-9]+\.[0-9]+)\s+slack\s+\((?:MET|VIOLATED)\)', hold_sec.group(1))]
            if not setup_slacks or not hold_slacks:
                finish(res_path, 'FAIL', 'timing', 'Unable to parse setup or hold slack from OpenROAD report', area_um2=area_um2)

            worst_setup = round(min(setup_slacks), 4)
            worst_hold = round(min(hold_slacks), 4)

            if worst_setup < MIN_SETUP_SLACK_NS:
                finish(
                    res_path,
                    'FAIL',
                    'timing',
                    f'Worst setup slack {worst_setup:.4f} ns < {MIN_SETUP_SLACK_NS:.2f} ns at {CLOCK_PERIOD_NS} ns clock',
                    area_um2=area_um2,
                    worst_setup_slack_ns=worst_setup,
                    worst_hold_slack_ns=worst_hold,
                )
            if worst_hold < MIN_HOLD_SLACK_NS:
                finish(
                    res_path,
                    'FAIL',
                    'timing',
                    f'Worst hold slack {worst_hold:.4f} ns < {MIN_HOLD_SLACK_NS:.2f} ns',
                    area_um2=area_um2,
                    worst_setup_slack_ns=worst_setup,
                    worst_hold_slack_ns=worst_hold,
                )

            finish(
                res_path,
                'PASS',
                'timing',
                f'PASS: functional, mapped area ({area_um2:.3f} <= {AREA_LIMIT_UM2:.1f} um^2), setup slack ({worst_setup:.4f} ns), hold slack ({worst_hold:.4f} ns)',
                seed=args.seed,
                area_um2=area_um2,
                area_limit_um2=AREA_LIMIT_UM2,
                worst_setup_slack_ns=worst_setup,
                worst_hold_slack_ns=worst_hold,
            )
    except subprocess.TimeoutExpired:
        finish(res_path, 'ERROR', 'environment', 'Tool execution timed out')
    except OSError as exc:
        finish(res_path, 'ERROR', 'environment', f'OS error: {exc}')


if __name__ == '__main__':
    main()
