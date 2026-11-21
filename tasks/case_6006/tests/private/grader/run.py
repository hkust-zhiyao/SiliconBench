#!/usr/bin/env python3
"""Trusted isolated grader for case_6006 (VeeR-EH1 IFU Branch Predictor (BTB/BHT/RAS), I-Cache/ICCM Memory Controller, and Fetch Pipe Closure)."""
import argparse
import hashlib
import json
import math
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
PUB_CODE = PUB_DIR / 'code'
PUB_LIB = PUB_DIR / 'lib'

TOOLS_ROOT = pathlib.Path(str(_sb_tools_dir()))
VERILATOR_BIN = TOOLS_ROOT / 'verilator-v5.038' / 'bin' / 'verilator'
YOSYS_BIN = TOOLS_ROOT / 'oss-cad-suite' / 'bin' / 'yosys'
OPENROAD_BIN = TOOLS_ROOT / 'bin' / 'openroad'

EDITABLE_FILES = ('ifu_ifc_ctl.sv', 'ifu_bp_ctl.sv', 'ifu_mem_ctl.sv')
FIXED_CODE_FILES = (
    'common_defines.vh',
    'global.h',
    'veer_types.sv',
    'beh_lib.sv',
    'veer_ifu_bp_mem_top.sv',
    'LICENSE',
)
FIXED_LIB_FILES = (
    'NangateOpenCellLibrary_typical.lib',
    'NangateOpenCellLibrary.tech.lef',
    'NangateOpenCellLibrary.macro.mod.lef',
    'LICENSE.Nangate45',
)

AREA_LIMIT_UM2 = 27850.0
CLOCK_PERIOD_NS = 3.65
MIN_SETUP_SLACK_NS = 0.00
MIN_HOLD_SLACK_NS = 0.00


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
    text = re.sub(r'`ifdef\s+ASSERT_ON\b.*?`endif', ' ', text, flags=re.S)
    return re.sub(r'/\*.*?\*/|//[^\n]*|"(?:\\.|[^"\\])*"', ' ', text, flags=re.S)


def screen_rtl(filename: str, raw: str, result_path: pathlib.Path):
    if len(raw.encode('utf-8')) > 500_000:
        finish(result_path, 'FAIL', 'policy', f'{filename}: exceeds size limit')
    if re.search(r'(?i)(?:pragma|synthesis|synopsys|verilator)\s+(?:translate_)?(?:on|off)', raw):
        finish(result_path, 'FAIL', 'policy', f'{filename}: prohibited pragma translate_off/on')

    cleaned = strip_comments_and_strings(raw)
    escape_pats = [
        (r'\$(?!clog2\b|bits\b|signed\b|unsigned\b|size\b|onehot0\b|onehot\b)[a-zA-Z_][\w$]*', 'forbidden_systask'),
        (r'\b(?:force|release|bind|defparam|initial|final|fork|join|join_any|join_none|wait|always_latch)\b', 'procedural_force_or_sim_construct'),
        (r'\b(?:import|export)\s*"DPI', 'dpi_escape'),
        (r'\$root\b|\b(?:tb|dut|grader|oracle|golden_ref)\s*\.', 'hierarchical_harness_reference'),
        (r'`\s*(?:ifdef|ifndef|elsif)\s+(?:VERILATOR|SYNTHESIS|SIMULATION|__ICARUS__|VCS|QUESTA)\b', 'simulator_or_synthesis_macro_divergence'),
        (r'`\s*include\s+"(?!global\.h")[^"]+"', 'unauthorized_include'),
        (r'(?<!\bassert)\s+#\s*\d', 'prohibited_delay_control'),
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
    ap.add_argument('--seed', type=int, default=101)
    ap.add_argument('--result', required=True)
    args = ap.parse_args()

    result_path = pathlib.Path(args.result).resolve()
    cand_in = pathlib.Path(args.candidate)
    if not cand_in.is_absolute() or any(x.is_symlink() for x in (cand_in, *cand_in.parents)) or not cand_in.is_dir():
        finish(result_path, 'FAIL', 'input_validation', 'Candidate must be an absolute non-symlink directory')
    cand_root = cand_in.resolve()

    for fname in FIXED_CODE_FILES:
        ref = PUB_CODE / fname
        for q in (cand_root / 'code' / fname, cand_root / fname):
            if q.exists() or q.is_symlink():
                if q.is_symlink() or not q.is_file() or not q.resolve().is_relative_to(cand_root):
                    finish(result_path, 'FAIL', 'policy', f'Invalid or symlinked protected dependency: {fname}')
                if sha256_bytes(q) != sha256_bytes(ref):
                    finish(result_path, 'FAIL', 'policy', f'Protected dependency changed: {fname}')

    for lname in FIXED_LIB_FILES:
        ref = PUB_LIB / lname
        q = cand_root / 'lib' / lname
        if q.exists() or q.is_symlink():
            if q.is_symlink() or not q.is_file() or not q.resolve().is_relative_to(cand_root):
                finish(result_path, 'FAIL', 'policy', f'Invalid or symlinked protected library file: {lname}')
            if sha256_bytes(q) != sha256_bytes(ref):
                finish(result_path, 'FAIL', 'policy', f'Protected library file changed: {lname}')

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
        'PATH': f'{TOOLS_ROOT / "verilator-v5.038" / "bin"}:{TOOLS_ROOT / "oss-cad-suite" / "bin"}:{TOOLS_ROOT / "bin"}:/usr/bin:/bin',
        'HOME': '/tmp',
        'TMPDIR': '/tmp',
        'LANG': 'C.UTF-8',
        'VERILATOR_ROOT': str(TOOLS_ROOT / 'verilator-v5.038' / 'share' / 'verilator'),
        'OMP_NUM_THREADS': '1',
        'OPENBLAS_NUM_THREADS': '1',
        'MAKEFLAGS': '-j1',
    }

    try:
        with tempfile.TemporaryDirectory(prefix='case_6006_grade_') as tmp:
            td = pathlib.Path(tmp)
            src = td / 'code'
            src.mkdir()
            for fname in FIXED_CODE_FILES:
                shutil.copyfile(PUB_CODE / fname, src / fname)
            for fname, text in cand_sources.items():
                (src / fname).write_text(text, encoding='utf-8')
            shutil.copyfile(PRIV_DIR / 'tests' / 'tb.sv', td / 'tb.sv')

            # 1. Verilator behavioral simulation
            seed_val = (args.seed & 0x7fffffff) or 101
            obj_dir = td / 'obj'
            v_cmd = [
                str(VERILATOR_BIN),
                '--binary',
                '--timing',
                '-j', '1',
                '-Wno-fatal',
                f'-I{src}',
                f'-GSEED={seed_val}',
                '--top-module', 'tb',
                '--Mdir', str(obj_dir),
                str(src / 'common_defines.vh'),
                str(src / 'veer_types.sv'),
                str(src / 'beh_lib.sv'),
                str(src / 'ifu_ifc_ctl.sv'),
                str(src / 'ifu_bp_ctl.sv'),
                str(src / 'ifu_mem_ctl.sv'),
                str(src / 'veer_ifu_bp_mem_top.sv'),
                str(td / 'tb.sv'),
            ]
            build = subprocess.run(v_cmd, cwd=td, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=180)
            if build.returncode != 0 or not (obj_dir / 'Vtb').is_file():
                finish(result_path, 'FAIL', 'compile', f'Verilator elaboration failed:\n{build.stdout[-1500:].strip()}')

            sim = subprocess.run([str(obj_dir / 'Vtb')], cwd=td, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=60)
            if sim.returncode != 0 or f'PASS veer_ifu_bp_mem_top seed={seed_val}' not in sim.stdout:
                finish(result_path, 'FAIL', 'behavior', f'Simulation failed (seed={seed_val}):\n{sim.stdout[-1500:].strip()}')

            # 2. Yosys/Slang latch-free check + ABC Nangate45 synthesis
            lib_file = PUB_LIB / 'NangateOpenCellLibrary_typical.lib'
            tech_lef = PUB_LIB / 'NangateOpenCellLibrary.tech.lef'
            macro_lef = PUB_LIB / 'NangateOpenCellLibrary.macro.mod.lef'
            mapped_v = td / 'mapped.v'
            ys_synth = td / 'synth.ys'
            ys_synth.write_text(
                f'read_slang --single-unit --top veer_ifu_bp_mem_top -I{src} '
                f'{src / "common_defines.vh"} {src / "veer_types.sv"} {src / "beh_lib.sv"} '
                f'{src / "ifu_ifc_ctl.sv"} {src / "ifu_bp_ctl.sv"} {src / "ifu_mem_ctl.sv"} '
                f'{src / "veer_ifu_bp_mem_top.sv"}\n'
                f'hierarchy -check -top veer_ifu_bp_mem_top\n'
                f'proc\n'
                f'select -assert-none */t:$dlatch* */t:$adlatch* */t:$latch* */t:$sr* */t:$_DLATCH*\n'
                f'opt_clean\n'
                f'select -assert-none */t:$dlatch* */t:$adlatch* */t:$latch* */t:$sr* */t:$_DLATCH*\n'
                f'synth -top veer_ifu_bp_mem_top\n'
                f'opt\n'
                f'dfflibmap -liberty {lib_file}\n'
                f'abc -liberty {lib_file}\n'
                f'clean\n'
                f'read_liberty -lib {lib_file}\n'
                f'check -assert\n'
                f'stat -liberty {lib_file}\n'
                f'write_verilog -noattr {mapped_v}\n',
                encoding='utf-8',
            )
            r_syn = subprocess.run([str(YOSYS_BIN), '-Q', '-T', '-m', 'slang', str(ys_synth)], cwd=td, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=180)
            m_area = re.findall(r'Chip area for module .*?:\s*([0-9.]+)', r_syn.stdout)
            if r_syn.returncode != 0 or not m_area or not mapped_v.is_file():
                finish(result_path, 'FAIL', 'synthesis', f'Yosys/Slang latch-free or Nangate45 synthesis failed:\n{r_syn.stdout[-1500:].strip()}')

            area_um2 = round(float(m_area[-1]), 3)
            if area_um2 > AREA_LIMIT_UM2:
                finish(
                    result_path,
                    'FAIL',
                    'area',
                    f'Mapped cell area {area_um2:.3f} um^2 exceeds limit {AREA_LIMIT_UM2:.1f} um^2',
                    area_um2=area_um2,
                    area_limit_um2=AREA_LIMIT_UM2,
                )

            # 3. OpenROAD static timing analysis at 3.65 ns clock period
            sta_v = td / 'sta.v'
            sta_v.write_text(mapped_v.read_text(encoding='utf-8').replace(' signed ', ' '), encoding='utf-8')
            flow_tcl = td / 'flow.tcl'
            flow_tcl.write_text(
                f'set_thread_count 1\n'
                f'read_lef {tech_lef}\n'
                f'read_lef {macro_lef}\n'
                f'read_liberty {lib_file}\n'
                f'read_verilog {sta_v}\n'
                f'link_design veer_ifu_bp_mem_top\n'
                f'create_clock -name clk -period {CLOCK_PERIOD_NS} [get_ports clk]\n'
                f'set_input_delay 0.15 -clock clk [all_inputs -no_clocks]\n'
                f'set_output_delay 0.15 -clock clk [all_outputs]\n'
                f'set_load 5.0 [all_outputs]\n'
                f'set_false_path -from [get_ports {{rst_l scan_mode}}]\n'
                f'report_checks -path_delay max -format full_clock_expanded -digits 4\n'
                f'report_checks -path_delay min -format full_clock_expanded -digits 4\n'
                f'puts "WNS [sta::worst_slack -max]"\n'
                f'puts "WHS [sta::worst_slack -min]"\n',
                encoding='utf-8',
            )
            r_or = subprocess.run([str(OPENROAD_BIN), '-exit', str(flow_tcl)], cwd=td, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=180)
            if r_or.returncode != 0:
                finish(result_path, 'FAIL', 'timing', f'OpenROAD STA failed:\n{r_or.stdout[-1500:].strip()}', area_um2=area_um2)

            m_wns = re.search(r'WNS\s+([-+0-9.eE]+)', r_or.stdout)
            m_whs = re.search(r'WHS\s+([-+0-9.eE]+)', r_or.stdout)
            if not m_wns or not m_whs:
                finish(result_path, 'FAIL', 'timing', 'Missing WNS/WHS in OpenROAD output', area_um2=area_um2)

            wns_ns = round(float(m_wns.group(1)), 4)
            whs_ns = round(float(m_whs.group(1)), 4)
            if not math.isfinite(wns_ns) or not math.isfinite(whs_ns):
                finish(result_path, 'FAIL', 'timing', 'Non-finite slack values', area_um2=area_um2)

            if wns_ns < MIN_SETUP_SLACK_NS:
                finish(
                    result_path,
                    'FAIL',
                    'timing',
                    f'Worst setup slack {wns_ns:.4f} ns < {MIN_SETUP_SLACK_NS:.2f} ns at {CLOCK_PERIOD_NS} ns clock',
                    area_um2=area_um2,
                    wns_ns=wns_ns,
                    whs_ns=whs_ns,
                )
            if whs_ns < MIN_HOLD_SLACK_NS:
                finish(
                    result_path,
                    'FAIL',
                    'timing',
                    f'Worst hold slack {whs_ns:.4f} ns < {MIN_HOLD_SLACK_NS:.2f} ns',
                    area_um2=area_um2,
                    wns_ns=wns_ns,
                    whs_ns=whs_ns,
                )

            finish(
                result_path,
                'PASS',
                'all',
                f'PASS veer_ifu_bp_mem_top functional, latch-free, area ({area_um2:.3f} <= {AREA_LIMIT_UM2:.1f} um^2), and STA (WNS={wns_ns:.4f} ns, WHS={whs_ns:.4f} ns)',
                area_um2=area_um2,
                area_limit_um2=AREA_LIMIT_UM2,
                wns_ns=wns_ns,
                whs_ns=whs_ns,
            )
    except subprocess.TimeoutExpired:
        finish(result_path, 'ERROR', 'environment', 'Synthesis, simulation, or STA timed out')
    except OSError as exc:
        finish(result_path, 'ERROR', 'environment', f'OS error: {exc}')


if __name__ == '__main__':
    main()
