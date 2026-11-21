#!/usr/bin/env python3
"""Trusted isolated grader for case_5010 (CVA6 I-Cache, AXI Wrapper, AXI Shim, and Nangate45 Area/STA)."""
import argparse
import hashlib
import json
import pathlib
import random
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
PRIV = TASK_DIR / 'private'
PUB = TASK_DIR / 'public'

TOOLS = pathlib.Path(str(_sb_tools_dir()))
VERILATOR = TOOLS / 'verilator-v5.038/bin/verilator'
YOSYS = TOOLS / 'oss-cad-suite/bin/yosys'
OPENROAD = TOOLS / 'bin/openroad'
LIB = PUB / 'lib/NangateOpenCellLibrary_typical.lib'
TLEF = PUB / 'lef/NangateOpenCellLibrary.tech.lef'
MLEF = PUB / 'lef/NangateOpenCellLibrary.macro.mod.lef'

AREA_LIMIT_UM2 = 8200.0
CLOCK_PERIOD_NS = 2.10

EDITABLE_NAMES = ('cva6_icache.sv', 'cva6_icache_axi_wrapper.sv', 'axi_shim.sv')
FIXED_NAMES = (
    'config_pkg.sv',
    'cv64a60ax_config_pkg.sv',
    'riscv_pkg.sv',
    'axi_pkg.sv',
    'ariane_pkg.sv',
    'wt_cache_pkg.sv',
    'cf_math_pkg.sv',
    'lzc.sv',
    'lfsr.sv',
    'sram_cache.sv',
)


def finish(result_path: pathlib.Path, verdict: str, stage: str, detail: str, **extra):
    payload = {
        'verdict': verdict,
        'stage': stage,
        'detail': detail,
        **extra,
    }
    result_path.parent.mkdir(parents=True, exist_ok=True)
    result_path.write_text(json.dumps(payload, indent=2) + '\n')
    print(json.dumps(payload))
    raise SystemExit(0 if verdict == 'PASS' else 2 if verdict == 'ERROR' else 1)


def strip_comments_and_strings(text: str) -> str:
    text = re.sub(r'(?is)//\s*(?:pragma|synthesis)\s+translate_off.*?//\s*(?:pragma|synthesis)\s+translate_on', ' ', text)
    text = re.sub(r'(?is)`ifndef\s+SYNTHESIS.*?`endif', ' ', text)
    text = re.sub(r'(?is)`ifndef\s+VERILATOR.*?`endif', ' ', text)
    return re.sub(r'/\*.*?\*/|//[^\n]*|"(?:\\.|[^"\\])*"', ' ', text, flags=re.S)


def screen_source(name: str, data: str, result_path: pathlib.Path):
    if len(data.encode('utf-8')) > 250_000:
        finish(result_path, 'FAIL', 'policy', f'{name} exceeds size limit')
    clean = strip_comments_and_strings(data)
    if re.search(
        r'`\s*(?:include|define|ifdef|ifndef|elsif)\b'
        r'|\$\s*(?!signed\b|unsigned\b|clog2\b|bits\b|high\b|low\b|size\b|onehot0\b|onehot\b)[a-zA-Z_]'
        r'|\b(?:force|release|bind|defparam|DPI|vpi|tb|grader|oracle|always_latch|blackbox)\b'
        r'|\b(?:ANTENNA|AND\d+|AOI\d+|BUF|CLKBUF|CLKGATETST|CLKGATE|DFFR?S?|DLL|FA|HA|INV|LOGIC[01]|MUX2|NAND\d+|NOR\d+|OAI\d+|OR\d+|SDFF\w*|TBUF|TINV|TLAT\w*|XNOR2|XOR2)_X\d+\b'
        r'|\$root\b',
        clean,
        re.I,
    ):
        finish(result_path, 'FAIL', 'policy', f'disallowed HDL construct or harness reference in {name}')
    if len(re.findall(r'\bmodule\b', clean)) != 1:
        finish(result_path, 'FAIL', 'policy', f'{name} must define only its single module')
    if name == 'cva6_icache.sv' and len(re.findall(r'\bsram_cache\b', clean)) < 2:
        finish(result_path, 'FAIL', 'policy', 'cva6_icache.sv must preserve tag_sram and data_sram sram_cache instantiations')


def make_tb(seed: int) -> str:
    s = (PRIV / 'tests/tb.sv').read_text(encoding='utf-8')
    r = random.Random(seed)
    lines = []
    for k in range(6):
        w0 = r.randint(1, 0xFFFF_FFFF)
        w1 = r.randint(1, 0xFFFF_FFFF)
        lines.append(
            f"wr_req_i = 1; wr_blen_i = 1'b1; wr_data_i[0] = 64'h{w0:016x}; wr_data_i[1] = 64'h{w1:016x}; "
            f"aw_ready_i = 1; w_ready_i = 1; tick(); aw_ready_i = 0; #1; "
            f"if (!w_valid_o || !w_last_o || w_data_o !== 64'h{w1:016x} || !wr_gnt_o) $fatal(1, \"rand burst wr fail\"); "
            f"tick(); wr_req_i = 0; w_ready_i = 0; tick();"
        )
    return s.replace('//RANDOM_TESTS_HERE', '\n    '.join(lines))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--candidate', required=True)
    ap.add_argument('--seed', type=int, default=101)
    ap.add_argument('--result', required=True)
    args = ap.parse_args()

    result_path = pathlib.Path(args.result).resolve()
    cand_in = pathlib.Path(args.candidate)
    if cand_in.is_symlink() or not cand_in.is_dir():
        finish(result_path, 'FAIL', 'input_validation', 'invalid or symlinked candidate directory')
    cand = cand_in.resolve()

    if (cand / 'code').is_symlink():
        finish(result_path, 'FAIL', 'input_validation', 'symlinked code directory')
    code_dir = cand / 'code' if (cand / 'code').is_dir() else cand

    for sub in ('include', 'flow', 'lib', 'lef'):
        sub_dir = cand / sub
        if sub_dir.is_symlink():
            finish(result_path, 'FAIL', 'policy', f'symlinked {sub} directory')
        if sub_dir.exists():
            for f in sub_dir.rglob('*'):
                if f.is_symlink():
                    finish(result_path, 'FAIL', 'policy', f'symlink in {sub}')
                if f.is_file():
                    ref = PUB / sub / f.relative_to(sub_dir)
                    if not ref.is_file() or hashlib.sha256(f.read_bytes()).digest() != hashlib.sha256(ref.read_bytes()).digest():
                        finish(result_path, 'FAIL', 'policy', f'modified protected {sub} file')

    for name in FIXED_NAMES:
        src = code_dir / name
        if src.exists() or src.is_symlink():
            if src.is_symlink() or not src.is_file() or hashlib.sha256(src.read_bytes()).digest() != hashlib.sha256((PUB / 'code' / name).read_bytes()).digest():
                finish(result_path, 'FAIL', 'policy', f'modified protected dependency {name}')

    sources = {}
    for name in EDITABLE_NAMES:
        p = code_dir / name
        if p.is_symlink() or not p.is_file() or p.resolve().parent != code_dir.resolve():
            finish(result_path, 'FAIL', 'input_validation', f'missing or unsafe editable source {name}')
        text = p.read_text(encoding='utf-8', errors='replace')
        screen_source(name, text, result_path)
        sources[name] = text

    env = {
        'PATH': f'{TOOLS / "verilator-v5.038/bin"}:{TOOLS / "oss-cad-suite/bin"}:{TOOLS / "bin"}:/usr/bin:/bin',
        'HOME': '/tmp',
        'TMPDIR': '/tmp',
        'LANG': 'C.UTF-8',
        'CC': '/usr/bin/gcc',
        'CXX': '/usr/bin/g++',
    }

    try:
        with tempfile.TemporaryDirectory(prefix='case_5010_grade_') as td:
            tmp = pathlib.Path(td)
            for name in FIXED_NAMES:
                shutil.copyfile(PUB / 'code' / name, tmp / name)
            shutil.copytree(PUB / 'include', tmp / 'include')
            shutil.copyfile(PUB / 'flow/icache_axi_top.sv', tmp / 'icache_axi_top.sv')
            for name, text in sources.items():
                (tmp / name).write_text(text, encoding='utf-8')
            (tmp / 'tb.sv').write_text(make_tb(args.seed), encoding='utf-8')

            compile_order = [
                'config_pkg.sv', 'cv64a60ax_config_pkg.sv', 'riscv_pkg.sv', 'axi_pkg.sv',
                'ariane_pkg.sv', 'wt_cache_pkg.sv', 'cf_math_pkg.sv', 'lzc.sv',
                'lfsr.sv', 'sram_cache.sv', 'axi_shim.sv',
                'cva6_icache.sv', 'cva6_icache_axi_wrapper.sv',
                'icache_axi_top.sv', 'tb.sv',
            ]
            comp_cmd = [
                str(VERILATOR),
                '--binary', '--timing', '-j', '1', '-CFLAGS', '-O0', '-Wno-fatal',
                '--top-module', 'tb',
                '--Mdir', str(tmp / 'obj'),
                '-I' + str(tmp / 'include'),
                *[str(tmp / n) for n in compile_order],
            ]
            c_res = subprocess.run(comp_cmd, cwd=tmp, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=180)
            if c_res.returncode != 0 or not (tmp / 'obj/Vtb').is_file():
                finish(result_path, 'FAIL', 'compile', 'Verilator compile failed:\n' + c_res.stdout[-1500:])

            s_res = subprocess.run([str(tmp / 'obj/Vtb')], cwd=tmp, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=60)
            if s_res.returncode != 0 or 'PASS icache_axi_top tests' not in s_res.stdout:
                finish(result_path, 'FAIL', 'functional', f'Simulation failed (seed={args.seed}):\n' + s_res.stdout[-1500:])

            # 2. Yosys Slang synthesis, latch check, & Nangate45 mapped area on icache_axi_top
            mapped_v = tmp / 'mapped_icache_axi.v'
            ys_ic = tmp / 'synth_ic.ys'
            ic_files = ' '.join(str(tmp / n) for n in compile_order[:-1])
            ys_ic.write_text(
                f'read_slang --ignore-assertions --top icache_axi_top -I{tmp / "include"} -DSYNTHESIS {ic_files}\n'
                f'hierarchy -check -top icache_axi_top\n'
                f'proc; opt_clean\n'
                f'select -assert-none */t:$dlatch* */t:$adlatch* */t:$latch* */t:$sr* */t:$_DLATCH*\n'
                f'synth -top icache_axi_top -flatten\n'
                f'opt\n'
                f'dfflibmap -liberty {LIB}\n'
                f'abc -liberty {LIB}\n'
                f'clean\n'
                f'read_liberty -lib {LIB}\n'
                f'check -assert\n'
                f'stat -liberty {LIB}\n'
                f'write_verilog -noattr {mapped_v}\n',
                encoding='utf-8',
            )
            y_ic = subprocess.run([str(YOSYS), '-Q', '-T', '-m', 'slang', '-s', str(ys_ic)], cwd=tmp, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=120)
            m_area = re.search(r'Chip area for .*?:\s*([\d.]+)', y_ic.stdout)
            if y_ic.returncode != 0 or not m_area or not mapped_v.is_file():
                finish(result_path, 'FAIL', 'synthesis', 'Yosys Nangate45 synthesis or latch check failed:\n' + y_ic.stdout[-1500:])
            area_um2 = round(float(m_area.group(1)), 3)
            if area_um2 > AREA_LIMIT_UM2:
                finish(
                    result_path,
                    'FAIL',
                    'area',
                    f'icache_axi_top mapped area {area_um2:.3f} um^2 exceeds limit {AREA_LIMIT_UM2:.1f} um^2',
                    area_um2=area_um2,
                )

            sta_v = tmp / 'sta_ic.v'
            sta_v.write_text(mapped_v.read_text(encoding='utf-8').replace(' signed ', ' '), encoding='utf-8')
            sta_tcl = tmp / 'sta_ic.tcl'
            sta_tcl.write_text(
                f'read_lef {TLEF}\n'
                f'read_lef {MLEF}\n'
                f'read_liberty {LIB}\n'
                f'read_verilog {sta_v}\n'
                f'link_design icache_axi_top\n'
                f'create_clock -name clk_i -period {CLOCK_PERIOD_NS} [get_ports clk_i]\n'
                f'set_input_delay 0.20 -clock clk_i [all_inputs -no_clocks]\n'
                f'set_output_delay 0.20 -clock clk_i [all_outputs]\n'
                f'set_load 5.0 [all_outputs]\n'
                f'puts "=== SETUP ==="\n'
                f'report_checks -path_delay max -format full_clock_expanded\n'
                f'puts "=== HOLD ==="\n'
                f'report_checks -path_delay min -format full_clock_expanded\n',
                encoding='utf-8',
            )
            o_res = subprocess.run([str(OPENROAD), '-exit', str(sta_tcl)], cwd=tmp, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=120)
            if o_res.returncode != 0:
                finish(result_path, 'FAIL', 'timing', 'OpenROAD STA failed:\n' + o_res.stdout[-1500:], area_um2=area_um2)
            setup_sec = re.search(r'=== SETUP ===(.*?)=== HOLD ===', o_res.stdout, re.S)
            hold_sec = re.search(r'=== HOLD ===(.*)', o_res.stdout, re.S)
            setup_slacks = [float(v) for v in re.findall(r'(-?[\d.]+)\s+slack\s+\((?:MET|VIOLATED)\)', setup_sec.group(1) if setup_sec else '')]
            hold_slacks = [float(v) for v in re.findall(r'(-?[\d.]+)\s+slack\s+\((?:MET|VIOLATED)\)', hold_sec.group(1) if hold_sec else '')]
            if not setup_slacks or not hold_slacks:
                finish(result_path, 'FAIL', 'timing', 'failed to parse OpenSTA setup/hold slacks', area_um2=area_um2)
            worst_setup_slack_ns = round(min(setup_slacks), 3)
            worst_hold_slack_ns = round(min(hold_slacks), 3)
            if worst_setup_slack_ns < 0.0:
                finish(
                    result_path,
                    'FAIL',
                    'timing',
                    f'worst setup slack {worst_setup_slack_ns:.3f} ns < 0.0 ns at {CLOCK_PERIOD_NS} ns clock',
                    area_um2=area_um2,
                    worst_setup_slack_ns=worst_setup_slack_ns,
                    worst_hold_slack_ns=worst_hold_slack_ns,
                )
            if worst_hold_slack_ns < 0.0:
                finish(
                    result_path,
                    'FAIL',
                    'timing',
                    f'worst hold slack {worst_hold_slack_ns:.3f} ns < 0.0 ns',
                    area_um2=area_um2,
                    worst_setup_slack_ns=worst_setup_slack_ns,
                    worst_hold_slack_ns=worst_hold_slack_ns,
                )

            finish(
                result_path,
                'PASS',
                'all',
                f'PASS icache_axi_top simulation (seed={args.seed}), latch-free synthesis, and Nangate45 area/STA',
                area_um2=area_um2,
                worst_setup_slack_ns=worst_setup_slack_ns,
                worst_hold_slack_ns=worst_hold_slack_ns,
            )
    except subprocess.TimeoutExpired:
        finish(result_path, 'ERROR', 'environment', 'Compilation, simulation, or synthesis timed out')
    except OSError as exc:
        finish(result_path, 'ERROR', 'environment', f'OS error: {exc}')


if __name__ == '__main__':
    main()
