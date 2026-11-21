#!/usr/bin/env python3
"""Private isolated grader for case_22017 (Ara Multi-Lane SLDU + p2_stride_gen)."""
import argparse
import hashlib
import json
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
VERILATOR = TOOLS_DIR / 'verilator-v5.038' / 'bin' / 'verilator'
YOSYS = TOOLS_DIR / 'oss-cad-suite' / 'bin' / 'yosys'
SIMCELLS = TOOLS_DIR / 'oss-cad-suite' / 'share' / 'yosys' / 'simcells.v'
IVERILOG = (
    TOOLS_DIR / 'iverilog-v13' / 'bin' / 'iverilog'
    if (TOOLS_DIR / 'iverilog-v13' / 'bin' / 'iverilog').is_file()
    else TOOLS_DIR / 'oss-cad-suite' / 'bin' / 'iverilog'
)
VVP = IVERILOG.parent / 'vvp'

AREA_LIMIT_UM2 = 60000.0

EDITABLE_SPECS = [
    (pathlib.Path('code/sldu.sv'), 'sldu'),
    (pathlib.Path('code/p2_stride_gen.sv'), 'p2_stride_gen'),
]
EDITABLE_SET = {rel for rel, _ in EDITABLE_SPECS}

ALLOWED_INCLUDES = {
    'common_cells/registers.svh',
    'common_cells/assertions.svh',
}

RTL_ORDER = [
    'code/cf_math_pkg.sv',
    'code/config_pkg.sv',
    'code/cv64a6_imafdcv_sv39_config_pkg.sv',
    'code/riscv_pkg.sv',
    'code/ariane_pkg.sv',
    'code/axi_pkg.sv',
    'code/fpnew_pkg.sv',
    'code/rvv_pkg.sv',
    'code/ara_pkg.sv',
    'code/lzc.sv',
    'code/popcount.sv',
    'code/spill_register_flushable.sv',
    'code/spill_register.sv',
    'code/p2_stride_gen.sv',
    'code/sldu_op_dp.sv',
    'code/sldu.sv',
    'code/sldu_subsys_top.sv',
]


def finish(result_path: pathlib.Path, verdict: str, stage: str, detail: str, **extra):
    payload = {'verdict': verdict, 'stage': stage, 'detail': detail, **extra}
    result_path.parent.mkdir(parents=True, exist_ok=True)
    result_path.write_text(json.dumps(payload, indent=2) + '\n', encoding='utf-8')
    print(json.dumps(payload))
    raise SystemExit(0 if verdict == 'PASS' else 2 if verdict == 'ERROR' else 1)


def sha256_bytes(p: pathlib.Path) -> str:
    return hashlib.sha256(p.read_bytes()).hexdigest()


def strip_comments(text: str) -> str:
    text = re.sub(r'(?is)//\s*pragma\s+translate_off.*?//\s*pragma\s+translate_on', '', text)
    return re.sub(r'/\*.*?\*/|//[^\n]*', ' ', text, flags=re.S)


def count_latches(stat_json: pathlib.Path) -> int:
    st = json.loads(stat_json.read_text(encoding='utf-8'))
    total = 0
    for _, mod_info in st.get('modules', {}).items():
        for cell_type, cnt in mod_info.get('num_cells_by_type', {}).items():
            if 'latch' in cell_type.lower() or 'dlatch' in cell_type.lower():
                total += int(cnt)
    for cell_type, cnt in st.get('design', {}).get('num_cells_by_type', {}).items():
        if 'latch' in cell_type.lower() or 'dlatch' in cell_type.lower():
            total = max(total, int(cnt))
    return total


def screen_source(cand_text: str, base_text: str, mod_name: str, rel_name: str, result_path: pathlib.Path):
    if len(cand_text.encode('utf-8')) > 600_000:
        finish(result_path, 'FAIL', 'policy', f'Editable RTL exceeds size limit: {rel_name}')

    cand_clean = strip_comments(cand_text)
    base_clean = strip_comments(base_text)

    escape_pats = [
        (r'\$(?:fopen|fclose|fread|fwrite|fdisplay|fscanf|system|finish|stop|fatal|readmemh|readmemb|writememh|writememb|dumpfile|dumpvars|value\$plusargs|test\$plusargs)\b', 'forbidden_systask'),
        (r'\b(?:force|release|bind|defparam)\b', 'procedural_force_or_bind'),
        (r'\b(?:import|export)\s*"DPI', 'dpi_escape'),
        (r'\$root\b|\b(?:tb|tb_gl|sldu_lane_harness|grader|oracle|golden_ref)\s*\.', 'hierarchical_harness_reference'),
        (r'`\s*(?:ifdef|ifndef|elsif)\s+SYNTHESIS\b', 'synthesis_macro_divergence'),
    ]
    for pat, label in escape_pats:
        if len(re.findall(pat, cand_clean, re.I)) > len(re.findall(pat, base_clean, re.I)):
            finish(result_path, 'FAIL', 'policy', f'Policy violation in {rel_name}: {label}')
    if re.search(r'`\s*(?:ifdef|ifndef|elsif)\s+(?:VERILATOR|SIMULATION|__ICARUS__|VCS|QUESTA)\b', cand_clean, re.I):
        finish(result_path, 'FAIL', 'policy', f'Policy violation in {rel_name}: simulator_macro_divergence')

    for inc in re.findall(r'`include\s+"([^"]+)"', cand_clean):
        if inc not in ALLOWED_INCLUDES:
            finish(result_path, 'FAIL', 'policy', f'Unauthorized include directive in {rel_name}: {inc}')

    if len(re.findall(rf'\bmodule\s+{re.escape(mod_name)}\b', cand_clean)) != 1 or len(re.findall(r'\bmodule\b', cand_clean)) != 1:
        finish(result_path, 'FAIL', 'structural', f'Expected single module declaration {mod_name} in {rel_name}')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--candidate', required=True)
    ap.add_argument('--seed', type=int, default=101)
    ap.add_argument('--result', required=True)
    args = ap.parse_args()

    result_path = pathlib.Path(args.result).resolve()
    cand_root = pathlib.Path(args.candidate)
    if cand_root.is_symlink() or not cand_root.is_dir():
        finish(result_path, 'FAIL', 'input_validation', 'Invalid candidate directory')
    cand_root = cand_root.resolve()

    is_full_workspace = (cand_root / 'issue.md').is_file()
    is_full_code = (cand_root / 'code').is_dir() and sum(1 for _ in (cand_root / 'code').glob('*')) > len(EDITABLE_SET) + 1
    for ref_file in sorted(PUB_DIR.rglob('*')):
        if not ref_file.is_file():
            continue
        rel = ref_file.relative_to(PUB_DIR)
        if rel in EDITABLE_SET or rel.name in {'issue.md', 'BUILD.md'}:
            continue
        c_file = cand_root / rel
        if c_file.is_symlink():
            finish(result_path, 'FAIL', 'policy', f'Protected file symlinked: {rel}')
        if c_file.exists():
            if not c_file.is_file() or sha256_bytes(c_file) != sha256_bytes(ref_file):
                finish(result_path, 'FAIL', 'policy', f'Protected file modified: {rel}')
        elif is_full_workspace or (is_full_code and rel.parts[0] == 'code'):
            finish(result_path, 'FAIL', 'policy', f'Protected file deleted: {rel}')

    cand_sources = {}
    for rel, mod_name in EDITABLE_SPECS:
        c_file = (cand_root / rel) if (cand_root / rel).exists() else (cand_root / rel.name)
        if not c_file.exists() or c_file.is_symlink() or not c_file.is_file() or not c_file.resolve().is_relative_to(cand_root):
            finish(result_path, 'FAIL', 'input_validation', f'Missing or invalid editable file: {rel}')
        c_txt = c_file.read_text(encoding='utf-8', errors='replace')
        b_txt = (PUB_DIR / rel).read_text(encoding='utf-8')
        screen_source(c_txt, b_txt, mod_name, str(rel), result_path)
        cand_sources[rel] = c_txt

    try:
        with tempfile.TemporaryDirectory(prefix='case_22017_grade_') as td:
            work = pathlib.Path(td)
            shutil.copytree(PUB_DIR / 'code', work / 'code')
            shutil.copytree(PUB_DIR / 'lib', work / 'lib')
            for rel, txt in cand_sources.items():
                (work / rel).write_text(txt, encoding='utf-8')
            shutil.copyfile(PRIV_DIR / 'tests/tb.sv', work / 'tb.sv')
            shutil.copyfile(PRIV_DIR / 'tests/tb_gl.sv', work / 'tb_gl.sv')

            env = {
                'PATH': f'{TOOLS_DIR}/verilator-v5.038/bin:{TOOLS_DIR}/oss-cad-suite/bin:/usr/bin:/bin',
                'HOME': str(work),
                'TMPDIR': str(work),
                'CC': '/usr/bin/gcc',
                'CXX': '/usr/bin/g++',
            }

            # 1. Multi-parameter (NrLanes = 2, 4, 8) Verilator functional & backpressure regression
            cmd_comp = [
                str(VERILATOR),
                '--binary', '--timing', '-j', '4', '-Wno-fatal',
                '--top-module', 'tb',
                '-Icode/include',
                '--Mdir', str(work / 'obj_dir'),
                *RTL_ORDER,
                'tb.sv',
            ]
            r_comp = subprocess.run(cmd_comp, cwd=work, env=env, capture_output=True, text=True, timeout=180)
            if r_comp.returncode != 0 or not (work / 'obj_dir/Vtb').is_file():
                tail = (r_comp.stdout + '\n' + r_comp.stderr).strip()[-1500:]
                finish(result_path, 'FAIL', 'compile', f'Verilator compile failed: {tail}')

            r_sim = subprocess.run([str(work / 'obj_dir/Vtb'), f'+seed={args.seed}'], cwd=work, env=env, capture_output=True, text=True, timeout=60)
            sim_out = (r_sim.stdout + '\n' + r_sim.stderr).strip()
            if (
                r_sim.returncode != 0
                or f'PASS: All NrLanes={{2,4,8}} SLDU + p2_stride_gen checks passed (seed={args.seed})' not in sim_out
                or '[ERROR]' in sim_out
                or '[FATAL]' in sim_out
            ):
                finish(result_path, 'FAIL', 'functional', f'Simulation failed (seed={args.seed}): {sim_out[-1500:]}')

            area_um2 = None
            if args.seed == 101:
                files_str = ' '.join(RTL_ORDER)
                lib_file = work / 'lib/NangateOpenCellLibrary_typical.lib'

                # 2a. NrLanes = 2 elaboration, zero-latch check, and 4-state gate-level simulation
                stat_l2 = work / 'stat_l2.json'
                gl_l2 = work / 'gl_l2.v'
                ys_l2 = (
                    f'read_slang -DSYNTHESIS -Icode/include -GNrLanes=2 -GVLEN=1024 --top sldu_subsys_top --ignore-assertions {files_str}; '
                    f'hierarchy -check -top sldu_subsys_top; proc; opt_clean; check -assert; '
                    f'tee -q -o {stat_l2} stat -json; '
                    f'synth -top sldu_subsys_top -noabc; opt_clean; write_verilog -noattr {gl_l2}'
                )
                r_ys2 = subprocess.run([str(YOSYS), '-m', 'slang', '-p', ys_l2], cwd=work, env=env, capture_output=True, text=True, timeout=120)
                if r_ys2.returncode != 0 or not stat_l2.is_file() or not gl_l2.is_file():
                    tail = (r_ys2.stdout + '\n' + r_ys2.stderr).strip()[-1500:]
                    finish(result_path, 'FAIL', 'synthesis', f'Yosys NrLanes=2 elaboration/synthesis failed: {tail}')
                lat2 = count_latches(stat_l2)
                if lat2 > 0:
                    finish(result_path, 'FAIL', 'synthesis', f'Unintended latch inference detected at NrLanes=2 ({lat2} latches)')

                vvp_l2 = work / 'gl_l2.vvp'
                r_ivl = subprocess.run([str(IVERILOG), '-g2012', '-DNRLANES=2', '-o', str(vvp_l2), str(SIMCELLS), str(gl_l2), 'tb_gl.sv'], cwd=work, env=env, capture_output=True, text=True, timeout=60)
                if r_ivl.returncode != 0 or not vvp_l2.is_file():
                    tail = (r_ivl.stdout + '\n' + r_ivl.stderr).strip()[-1500:]
                    finish(result_path, 'FAIL', 'gate_level', f'Icarus gate-level compile failed: {tail}')
                r_vvp = subprocess.run([str(VVP), str(vvp_l2)], cwd=work, env=env, capture_output=True, text=True, timeout=60)
                gl_out = (r_vvp.stdout + '\n' + r_vvp.stderr).strip()
                if r_vvp.returncode != 0 or 'PASS: Gate-level 4-state verification passed for NrLanes=2' not in gl_out or '[GL-' in gl_out:
                    finish(result_path, 'FAIL', 'gate_level', f'4-state gate-level verification failed: {gl_out[-1500:]}')

                # 2b. NrLanes = 8 elaboration & zero-latch check
                stat_l8 = work / 'stat_l8.json'
                ys_l8 = (
                    f'read_slang -DSYNTHESIS -Icode/include -GNrLanes=8 -GVLEN=1024 --top sldu_subsys_top --ignore-assertions {files_str}; '
                    f'hierarchy -check -top sldu_subsys_top; proc; opt_clean; check -assert; '
                    f'tee -q -o {stat_l8} stat -json'
                )
                r_ys8 = subprocess.run([str(YOSYS), '-m', 'slang', '-p', ys_l8], cwd=work, env=env, capture_output=True, text=True, timeout=120)
                if r_ys8.returncode != 0 or not stat_l8.is_file():
                    tail = (r_ys8.stdout + '\n' + r_ys8.stderr).strip()[-1500:]
                    finish(result_path, 'FAIL', 'synthesis', f'Yosys NrLanes=8 elaboration check failed: {tail}')
                lat8 = count_latches(stat_l8)
                if lat8 > 0:
                    finish(result_path, 'FAIL', 'synthesis', f'Unintended latch inference detected at NrLanes=8 ({lat8} latches)')

                # 2c. NrLanes = 4 zero-latch check & Nangate45 mapped synthesis
                stat_l4 = work / 'stat_l4.json'
                ys_l4 = (
                    f'read_slang -DSYNTHESIS -Icode/include -GNrLanes=4 -GVLEN=1024 --top sldu_subsys_top --ignore-assertions {files_str}; '
                    f'hierarchy -check -top sldu_subsys_top; proc; opt_clean; check -assert; '
                    f'tee -q -o {stat_l4} stat -json; '
                    f'synth -top sldu_subsys_top -noabc; '
                    f'dfflibmap -liberty {lib_file}; '
                    f'abc -liberty {lib_file} -D 4800; '
                    f'opt_clean; stat -liberty {lib_file}'
                )
                r_ys4 = subprocess.run([str(YOSYS), '-m', 'slang', '-p', ys_l4], cwd=work, env=env, capture_output=True, text=True, timeout=180)
                ys4_out = r_ys4.stdout + '\n' + r_ys4.stderr
                m_area = re.search(r"Chip area for module '\\sldu_subsys_top':\s*([0-9.]+)", ys4_out)
                if r_ys4.returncode != 0 or not stat_l4.is_file() or not m_area:
                    finish(result_path, 'FAIL', 'synthesis', f'Yosys NrLanes=4 Nangate45 synthesis failed: {ys4_out.strip()[-1500:]}')
                lat4 = count_latches(stat_l4)
                if lat4 > 0:
                    finish(result_path, 'FAIL', 'synthesis', f'Unintended latch inference detected at NrLanes=4 ({lat4} latches)')
                area_um2 = round(float(m_area.group(1)), 3)
                if area_um2 > AREA_LIMIT_UM2:
                    finish(result_path, 'FAIL', 'area', f'Mapped Nangate45 cell area {area_um2:.3f} um^2 exceeds limit {AREA_LIMIT_UM2:.1f} um^2', measured_area_um2=area_um2)

            extra = {'measured_area_um2': area_um2} if area_um2 is not None else {}
            finish(result_path, 'PASS', 'functional', f'All NrLanes={{2,4,8}} RVV slide/reduction, zero-latch, 4-state GL, and Nangate45 signoff checks passed (seed={args.seed})', **extra)
    except subprocess.TimeoutExpired:
        finish(result_path, 'FAIL', 'functional', f'Grading timed out (possible deadlock) for seed={args.seed}')
    except OSError as exc:
        finish(result_path, 'ERROR', 'environment', f'OS error: {exc}')


if __name__ == '__main__':
    main()
