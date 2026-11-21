#!/usr/bin/env python3
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
PUB_DIR = TASK_DIR / 'public'
PRIV_DIR = TASK_DIR / 'private'
LIB_DIR = PUB_DIR / 'lib'
TOOLS_DIR = pathlib.Path(str(_sb_tools_dir()))
IVERILOG = TOOLS_DIR / 'oss-cad-suite' / 'bin' / 'iverilog'
VVP = TOOLS_DIR / 'oss-cad-suite' / 'bin' / 'vvp'
VERILATOR = TOOLS_DIR / 'oss-cad-suite' / 'bin' / 'verilator'
YOSYS = TOOLS_DIR / 'oss-cad-suite' / 'bin' / 'yosys'

EDITABLE_MAP = {
    pathlib.Path('code/util_cpack2_impl.v'): 'util_cpack2_impl',
    pathlib.Path('code/util_upack2_impl.v'): 'util_upack2_impl',
    pathlib.Path('code/pack_shell.v'): 'pack_shell',
    pathlib.Path('code/pack_ctrl.v'): 'pack_ctrl',
    pathlib.Path('code/pack_network.v'): 'pack_network',
}
EDITABLES = set(EDITABLE_MAP.keys())


def finish(result_path: pathlib.Path, verdict: str, stage: str, detail: str):
    payload = {'verdict': verdict, 'stage': stage, 'detail': detail[:4000]}
    result_path.parent.mkdir(parents=True, exist_ok=True)
    result_path.write_text(json.dumps(payload, indent=2) + '\n', encoding='utf-8')
    print(json.dumps(payload))
    raise SystemExit(0 if verdict == 'PASS' else 2 if verdict == 'ERROR' else 1)


def sha256_bytes(p: pathlib.Path) -> str:
    return hashlib.sha256(p.read_bytes()).hexdigest()


def strip_comments(text: str) -> str:
    text = re.sub(r'(?is)//\s*pragma\s+translate_off.*?//\s*pragma\s+translate_on', '', text)
    text = re.sub(r'/\*.*?\*/|//[^\n]*|"(?:\\.|[^"\\])*"', ' ', text, flags=re.S)
    return text


def screen_rtl(cand_text: str, expected_mod: str, result_path: pathlib.Path):
    if len(cand_text.encode('utf-8')) > 250_000:
        finish(result_path, 'FAIL', 'policy', f'Editable file {expected_mod} exceeds size limit')
    clean = strip_comments(cand_text)
    escape_pats = [
        (r'\$(?:fopen|fclose|fread|fwrite|fdisplay|fscanf|system|finish|stop|readmemh|readmemb|writememh|writememb|dumpfile|dumpvars|value\$plusargs|test\$plusargs)\b', 'forbidden_systask'),
        (r'\b(?:force|release|bind|defparam)\b', 'procedural_force_or_bind'),
        (r'\b(?:import|export)\s*"DPI', 'dpi_escape'),
        (r'\$root\b|\b(?:tb_matrix|tb_gls_parity|pack_pair_harness|util_pack_asic_cluster|grader|oracle)\s*\.', 'hierarchical_harness_reference'),
        (r'`\s*(?:ifdef|ifndef|elsif)\s+(?:VERILATOR|SYNTHESIS|SIMULATION|__ICARUS__|VCS|QUESTA)\b', 'simulator_macro_divergence'),
        (r'#\s*[0-9]+', 'behavioral_delay_in_rtl'),
    ]
    for pat, label in escape_pats:
        if re.search(pat, clean, re.I):
            finish(result_path, 'FAIL', 'policy', f'Policy violation in {expected_mod}: {label}')
    if re.search(r'`include\b', clean):
        finish(result_path, 'FAIL', 'policy', f'Unauthorized include directive in {expected_mod}')
    if len(re.findall(rf'\bmodule\s+{expected_mod}\b', clean)) < 1:
        finish(result_path, 'FAIL', 'structural', f'Expected module {expected_mod}')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--candidate', required=True)
    ap.add_argument('--seed', type=int, default=101)
    ap.add_argument('--result', required=True)
    args = ap.parse_args()

    result_path = pathlib.Path(args.result).resolve()
    cand_root = pathlib.Path(args.candidate)
    if cand_root.is_symlink() or not cand_root.is_dir():
        finish(result_path, 'FAIL', 'input_validation', 'Invalid or symlinked candidate directory')
    cand_root = cand_root.resolve()

    for rel in EDITABLES:
        f = cand_root / rel
        if not f.exists() or f.is_symlink() or not f.is_file() or not f.resolve().is_relative_to(cand_root):
            finish(result_path, 'FAIL', 'input_validation', f'Missing or invalid editable file: {rel}')

    for subdir in ('code', 'lib'):
        if (cand_root / subdir).is_dir():
            for ref_file in sorted((PUB_DIR / subdir).rglob('*')):
                if not ref_file.is_file():
                    continue
                rel = ref_file.relative_to(PUB_DIR)
                if rel in EDITABLES:
                    continue
                c_file = cand_root / rel
                if not c_file.is_file() or c_file.is_symlink() or sha256_bytes(c_file) != sha256_bytes(ref_file):
                    finish(result_path, 'FAIL', 'policy', f'Protected file modified or missing: {rel}')

    rtl_texts = {}
    for rel, mname in EDITABLE_MAP.items():
        txt = (cand_root / rel).read_text(encoding='utf-8', errors='replace')
        screen_rtl(txt, mname, result_path)
        rtl_texts[rel] = txt

    try:
        with tempfile.TemporaryDirectory(prefix='case_24009_grade_') as td:
            work = pathlib.Path(td)
            shutil.copytree(PUB_DIR / 'code', work / 'code')
            for rel, txt in rtl_texts.items():
                (work / rel).write_text(txt, encoding='utf-8')
            for tbf in ('tb_matrix.sv', 'gls_wrap.v', 'asic_cells_4state.v', 'tb_gls_parity.sv'):
                shutil.copyfile(PRIV_DIR / 'tests' / tbf, work / tbf)

            env = {
                'PATH': f'{TOOLS_DIR}/oss-cad-suite/bin:{TOOLS_DIR}/bin:/usr/bin:/bin',
                'HOME': str(work),
                'TMPDIR': str(work),
            }

            rtl_srcs = [
                str(work / 'code' / 'ad_perfect_shuffle.v'),
                str(work / 'code' / 'util_pipeline_stage.v'),
                str(work / 'code' / 'pack_interconnect.v'),
                str(work / 'code' / 'pack_ctrl.v'),
                str(work / 'code' / 'pack_network.v'),
                str(work / 'code' / 'pack_shell.v'),
                str(work / 'code' / 'util_cpack2_impl.v'),
                str(work / 'code' / 'util_upack2_impl.v'),
            ]

            # Stage 1: Multi-parameter odd/non-pow2 matrix simulation in Verilator
            cmd_vl = [
                str(VERILATOR), '--binary', '--timing', '+1364-2005ext+v', '-Wno-fatal',
                '--Mdir', str(work / 'obj_mat'), '--top-module', 'tb_matrix',
                *rtl_srcs,
                str(work / 'tb_matrix.sv'),
            ]
            r_vc = subprocess.run(cmd_vl, cwd=work, env=env, capture_output=True, text=True, timeout=90)
            if r_vc.returncode != 0:
                finish(result_path, 'FAIL', 'compile', f'Verilator elaboration/compile failed: {(r_vc.stdout + r_vc.stderr)[-1500:]}')
            r_vs = subprocess.run([str(work / 'obj_mat' / 'Vtb_matrix'), f'+seed={args.seed}'], cwd=work, env=env, capture_output=True, text=True, timeout=90)
            vs_out = (r_vs.stdout + '\n' + r_vs.stderr).strip()
            if r_vs.returncode != 0 or f'PASS_MATRIX seed={args.seed}' not in vs_out or '%Error' in vs_out:
                finish(result_path, 'FAIL', 'functional', f'Multi-parameter odd/non-pow2 pack/upack matrix failed (seed={args.seed}): {vs_out[-1600:]}')

            # Stage 2A: 4-state RTL simulation on Icarus Verilog
            cmd_iv_rtl = [
                str(IVERILOG), '-g2005-sv', '-s', 'tb_gls_parity', '-o', str(work / 'rtl4.vvp'),
                *rtl_srcs,
                str(work / 'gls_wrap.v'),
                str(work / 'tb_gls_parity.sv'),
            ]
            r_irc = subprocess.run(cmd_iv_rtl, cwd=work, env=env, capture_output=True, text=True, timeout=60)
            if r_irc.returncode != 0:
                finish(result_path, 'FAIL', 'compile', f'Icarus 4-state RTL compile failed: {(r_irc.stdout + r_irc.stderr)[-1400:]}')
            r_irs = subprocess.run([str(VVP), str(work / 'rtl4.vvp')], cwd=work, env=env, capture_output=True, text=True, timeout=60)
            if r_irs.returncode != 0 or 'PASS_GLS_PARITY' not in (r_irs.stdout + r_irs.stderr):
                finish(result_path, 'FAIL', 'functional', f'Icarus 4-state RTL test failed: {(r_irs.stdout + r_irs.stderr)[-1400:]}')

            # Stage 2B: Yosys synthesis (hierarchy check that pack_interconnect butterfly is preserved + zero latches + 4-state ASIC GLS!)
            read_cmds = '\n'.join([f'read_verilog -DSYNTHESIS -DYOSYS {s}' for s in rtl_srcs + [str(work / 'gls_wrap.v')]])
            ys_scr = f'''
{read_cmds}
hierarchy -check -top util_pack_asic_cluster
proc; opt; memory; opt
select -assert-any t:*pack_interconnect*
techmap; opt
abc -g AND,OR,XOR,MUX
clean -purge
write_verilog -noattr {work}/cluster_gls.v
'''
            r_syn = subprocess.run([str(YOSYS), '-s', '-'], input=ys_scr, cwd=work, env=env, capture_output=True, text=True, timeout=120)
            if r_syn.returncode != 0 or not (work / 'cluster_gls.v').is_file():
                finish(result_path, 'FAIL', 'synthesis', f'Yosys synthesis or pack_interconnect architecture check failed: {(r_syn.stdout + r_syn.stderr)[-1500:]}')

            gls_net = (work / 'cluster_gls.v').read_text(encoding='utf-8')
            if re.search(r'\b\$_DLATCH_[NP]_\b', gls_net):
                finish(result_path, 'FAIL', 'synthesis', 'Inferred latches forbidden in util_pack')

            # Stage 2C: 4-State ASIC Gate-Level Simulation (all DFFs power up to 1'bx!)
            cmd_iv_gls = [
                str(IVERILOG), '-g2005-sv', '-s', 'tb_gls_parity', '-o', str(work / 'gls4.vvp'),
                str(work / 'asic_cells_4state.v'),
                str(work / 'cluster_gls.v'),
                str(work / 'tb_gls_parity.sv'),
            ]
            r_igc = subprocess.run(cmd_iv_gls, cwd=work, env=env, capture_output=True, text=True, timeout=60)
            if r_igc.returncode != 0:
                finish(result_path, 'FAIL', 'synthesis', f'Icarus GLS compile failed: {(r_igc.stdout + r_igc.stderr)[-1400:]}')
            r_igs = subprocess.run([str(VVP), str(work / 'gls4.vvp')], cwd=work, env=env, capture_output=True, text=True, timeout=90)
            igs_out = (r_igs.stdout + '\n' + r_igs.stderr).strip()
            if r_igs.returncode != 0 or 'PASS_GLS_PARITY' not in igs_out:
                finish(result_path, 'FAIL', 'equivalence', f'4-state standard-cell GLS parity failed (uninitialized DFF X-prop): {igs_out[-1500:]}')

            finish(result_path, 'PASS', 'equivalence', f'Odd/non-pow2 parameter matrix + dynamic mask switch + 4-state ASIC GLS parity passed (seed={args.seed})')
    except SystemExit:
        raise
    except Exception as exc:
        finish(result_path, 'ERROR', 'grader_exception', str(exc))


if __name__ == '__main__':
    main()
