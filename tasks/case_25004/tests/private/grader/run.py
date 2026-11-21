#!/usr/bin/env python3
"""Private isolated grader for case_25004:
Stage 0: Policy, module signature, and read-only file SHA-256 verification
Stage 1: Verilator cycle-accurate RTL functional & security verification (tb.sv + sim_models.sv)
Stage 2: Yosys-Slang synthesis, zero-latch check, and zero combinational-loop check (scc -expect 0)
"""
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
VERILATOR = TOOLS_DIR / 'verilator-v5.038' / 'bin' / 'verilator'
YOSYS = TOOLS_DIR / 'oss-cad-suite' / 'bin' / 'yosys'

EDITABLE_FILES = {
    pathlib.Path('code/ecc_dsa_ctrl.sv'): 'ecc_dsa_ctrl',
    pathlib.Path('code/ecc_scalar_blinding.sv'): 'ecc_scalar_blinding',
    pathlib.Path('code/ecc_hmac_drbg_interface.sv'): 'ecc_hmac_drbg_interface',
}

SIM_RTL_SOURCES = [
    'code/caliptra_prim_pkg.sv',
    'code/caliptra_prim_util_pkg.sv',
    'code/caliptra_prim_cipher_pkg.sv',
    'code/caliptra_prim_generic_flop.sv',
    'code/caliptra_prim_flop.sv',
    'code/caliptra_prim_sparse_fsm_flop.sv',
    'code/caliptra_prim_lfsr.sv',
    'code/ahb_defines_pkg.sv',
    'code/kv_defines_pkg.sv',
    'code/kv_fsm.sv',
    'code/kv_read_rule_check.sv',
    'code/kv_write_rule_check.sv',
    'code/kv_read_client.sv',
    'code/kv_write_client.sv',
    'code/ahb_slv_sif.sv',
    'code/sha512_masked_defines_pkg.sv',
    'code/sha512_h_constants.v',
    'code/sha512_k_constants.v',
    'code/sha512_masked_w_mem.sv',
    'code/sha512_masked_core.sv',
    'code/hmac_param_pkg.sv',
    'code/hmac_core.sv',
    'code/ecc_params_pkg.sv',
    'code/ecc_defines_pkg.sv',
    'code/ecc_dsa_uop_pkg.sv',
    'code/ecc_pm_uop_pkg.sv',
    'code/ecc_reg_pkg.sv',
    'code/ecc_reg.sv',
    # real_hmac_drbg_core.sv and sim_models.sv injected here
    'code/ecc_scalar_blinding.sv',
    'code/ecc_hmac_drbg_interface.sv',
    'code/ecc_dsa_sequencer.sv',
    'code/ecc_dsa_ctrl.sv',
    'code/ecc_top.sv',
]

SYNTH_RTL_SOURCES = [
    'code/caliptra_prim_pkg.sv',
    'code/caliptra_prim_util_pkg.sv',
    'code/caliptra_prim_cipher_pkg.sv',
    'code/caliptra_prim_generic_flop.sv',
    'code/caliptra_prim_flop.sv',
    'code/caliptra_prim_sparse_fsm_flop.sv',
    'code/caliptra_prim_lfsr.sv',
    'code/ahb_defines_pkg.sv',
    'code/kv_defines_pkg.sv',
    'code/kv_fsm.sv',
    'code/kv_read_rule_check.sv',
    'code/kv_write_rule_check.sv',
    'code/kv_read_client.sv',
    'code/kv_write_client.sv',
    'code/ahb_slv_sif.sv',
    'code/hmac_param_pkg.sv',
    'code/ecc_params_pkg.sv',
    'code/ecc_defines_pkg.sv',
    'code/ecc_dsa_uop_pkg.sv',
    'code/ecc_pm_uop_pkg.sv',
    'code/ecc_reg_pkg.sv',
    'code/ecc_reg.sv',
    'code/ecc_adder.sv',
    'code/ecc_mult_dsp.sv',
    'code/ecc_scalar_blinding.sv',
    'code/ecc_hmac_drbg_interface.sv',
    'code/ecc_dsa_sequencer.sv',
    'code/ecc_dsa_ctrl.sv',
    'code/ecc_top.sv',
]


def finish(result_path: pathlib.Path, verdict: str, stage: str, detail: str):
    payload = {'verdict': verdict, 'stage': stage, 'detail': detail}
    result_path.parent.mkdir(parents=True, exist_ok=True)
    result_path.write_text(json.dumps(payload, indent=2) + '\n', encoding='utf-8')
    print(json.dumps(payload))
    raise SystemExit(0 if verdict == 'PASS' else 2 if verdict == 'ERROR' else 1)


def sha256_bytes(p: pathlib.Path) -> str:
    return hashlib.sha256(p.read_bytes()).hexdigest()


def strip_comments_and_strings(text: str) -> str:
    text = re.sub(r'(?is)//\s*pragma\s+translate_off.*?//\s*pragma\s+translate_on', '', text)
    text = re.sub(r'/\*.*?\*/|//[^\n]*|"(?:\\.|[^"\\])*"', ' ', text, flags=re.S)
    return text


def screen_candidate_source(rel: pathlib.Path, mod_name: str, cand_text: str, result_path: pathlib.Path):
    if len(cand_text.encode('utf-8')) > 500_000:
        finish(result_path, 'FAIL', 'policy', f'Editable RTL {rel} exceeds size limit')
    cand_clean = strip_comments_and_strings(cand_text)
    escape_pats = [
        (r'\$(?:fopen|fclose|fread|fwrite|fdisplay|fscanf|system|finish|stop|fatal|readmemh|readmemb|writememh|writememb|dumpfile|dumpvars|value\$plusargs|test\$plusargs)\b', 'forbidden_systask'),
        (r'\b(?:force|release|bind|defparam)\b', 'procedural_force_or_bind'),
        (r'\b(?:import|export)\s*"DPI', 'dpi_escape'),
        (r'\$root\b|\b(?:tb|sim_ctrl_pkg|real_hmac_drbg_core|grader|oracle)\b', 'hierarchical_harness_reference'),
        (r'`\s*(?:ifdef|ifndef|elsif)\s+(?:VERILATOR|SYNTHESIS|SIMULATION|__ICARUS__|VCS|QUESTA)\b', 'simulator_macro_divergence'),
    ]
    for pat, label in escape_pats:
        if re.search(pat, cand_clean):
            finish(result_path, 'FAIL', 'policy', f'Policy violation in {rel}: {label}')
    if not re.search(rf'\bmodule\s+{re.escape(mod_name)}\b', cand_clean):
        finish(result_path, 'FAIL', 'policy', f'Missing module declaration {mod_name} in {rel}')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--candidate', type=pathlib.Path, required=True)
    ap.add_argument('--seed', type=int, default=101)
    ap.add_argument('--result', type=pathlib.Path, required=True)
    args = ap.parse_args()

    cand_dir = args.candidate.resolve()
    result_path = args.result.resolve()

    if not cand_dir.is_dir() or cand_dir.is_symlink():
        finish(result_path, 'FAIL', 'policy', 'Invalid candidate directory')
    for p in cand_dir.rglob('*'):
        if p.is_symlink():
            finish(result_path, 'FAIL', 'policy', f'Symlink forbidden in candidate: {p.relative_to(cand_dir)}')

    pub_code = PUB_DIR / 'code'
    for pub_f in sorted(pub_code.rglob('*')):
        if not pub_f.is_file():
            continue
        rel = pub_f.relative_to(PUB_DIR)
        cand_f = cand_dir / rel
        if not cand_f.is_file():
            finish(result_path, 'FAIL', 'policy', f'Missing required file: {rel}')
        if rel in EDITABLE_FILES:
            screen_candidate_source(rel, EDITABLE_FILES[rel], cand_f.read_text(encoding='utf-8', errors='replace'), result_path)
        else:
            if sha256_bytes(cand_f) != sha256_bytes(pub_f):
                finish(result_path, 'FAIL', 'policy', f'Read-only file modified: {rel}')

    env = os.environ.copy()
    env['PATH'] = f"{VERILATOR.parent}:{YOSYS.parent}:{env.get('PATH', '')}"
    env['VERILATOR_ROOT'] = str(TOOLS_DIR / 'verilator-v5.038' / 'share' / 'verilator')

    with tempfile.TemporaryDirectory(prefix='case_25004_grade_') as td_s:
        td = pathlib.Path(td_s)
        work = td / 'work'
        shutil.copytree(PUB_DIR, work)
        for rel in EDITABLE_FILES:
            shutil.copy2(cand_dir / rel, work / rel)

        # Build real_hmac_drbg_core.sv from read-only hmac_drbg.sv so sim_models.sv can wrap it
        real_drbg_sv = td / 'real_hmac_drbg_core.sv'
        drbg_src = (work / 'code' / 'hmac_drbg.sv').read_text(encoding='utf-8')
        real_drbg_sv.write_text(
            re.sub(r'\bmodule\s+hmac_drbg\b', 'module real_hmac_drbg_core', drbg_src, count=1),
            encoding='utf-8'
        )
        sim_models_sv = td / 'sim_models.sv'
        shutil.copy2(PRIV_DIR / 'tests' / 'sim_models.sv', sim_models_sv)
        tb_sv = td / 'tb.sv'
        shutil.copy2(PRIV_DIR / 'tests' / 'tb.sv', tb_sv)

        # Stage 1a: Also verify full-stack lint with real unmodified ecc_arith_unit.sv + hmac_drbg.sv
        full_lint_srcs = [
            'code/caliptra_prim_pkg.sv', 'code/caliptra_prim_util_pkg.sv', 'code/caliptra_prim_cipher_pkg.sv',
            'code/caliptra_prim_generic_flop.sv', 'code/caliptra_prim_flop.sv', 'code/caliptra_prim_sparse_fsm_flop.sv',
            'code/caliptra_prim_lfsr.sv', 'code/ahb_defines_pkg.sv', 'code/kv_defines_pkg.sv',
            'code/kv_fsm.sv', 'code/kv_read_rule_check.sv', 'code/kv_write_rule_check.sv',
            'code/kv_read_client.sv', 'code/kv_write_client.sv', 'code/ahb_slv_sif.sv',
            'code/sha512_masked_defines_pkg.sv', 'code/sha512_h_constants.v', 'code/sha512_k_constants.v',
            'code/sha512_masked_w_mem.sv', 'code/sha512_masked_core.sv', 'code/hmac_param_pkg.sv',
            'code/hmac_core.sv', 'code/hmac_drbg.sv', 'code/ecc_params_pkg.sv', 'code/ecc_defines_pkg.sv',
            'code/ecc_dsa_uop_pkg.sv', 'code/ecc_pm_uop_pkg.sv', 'code/ecc_reg_pkg.sv', 'code/ecc_reg.sv',
            'code/ecc_adder.sv', 'code/ecc_add_sub_mod_alter.sv', 'code/ecc_mult_dsp.sv',
            'code/ecc_pe_first.sv', 'code/ecc_pe.sv', 'code/ecc_pe_final.sv', 'code/ecc_montgomerymultiplier.sv',
            'code/ecc_fau.sv', 'code/ecc_ram_tdp_file.sv', 'code/ecc_pm_sequencer.sv', 'code/ecc_pm_ctrl.sv',
            'code/ecc_arith_unit.sv', 'code/ecc_scalar_blinding.sv', 'code/ecc_hmac_drbg_interface.sv',
            'code/ecc_dsa_sequencer.sv', 'code/ecc_dsa_ctrl.sv', 'code/ecc_top.sv',
        ]
        r_lint = subprocess.run(
            [str(VERILATOR), '--lint-only', '-Wno-fatal', '-DSYNTHESIS', f'-I{work / "code"}', '--top-module', 'ecc_top',
             *[str(work / s) for s in full_lint_srcs]],
            env=env, capture_output=True, text=True, timeout=60
        )
        if r_lint.returncode != 0:
            tail = (r_lint.stdout + '\n' + r_lint.stderr)[-1500:]
            finish(result_path, 'FAIL', 'functional', f'Full-stack ecc_top Verilator lint/port check failed:\n{tail}')

        # Stage 1b: Verilator RTL Simulation
        sim_files = []
        for s in SIM_RTL_SOURCES:
            sim_files.append(str(work / s))
            if s == 'code/ecc_reg.sv':
                sim_files.append(str(real_drbg_sv))
                sim_files.append(str(sim_models_sv))
        sim_files.append(str(tb_sv))

        v_cmd = [
            str(VERILATOR), '--binary', '--timing', '-Wno-fatal', '-sv',
            f'-I{work / "code"}', '-CFLAGS', '-O0',
            *sim_files, '--top-module', 'tb', '-Mdir', str(td / 'obj_rtl')
        ]
        r_comp = subprocess.run(v_cmd, env=env, capture_output=True, text=True, timeout=150)
        if r_comp.returncode != 0:
            tail = (r_comp.stdout + '\n' + r_comp.stderr)[-1500:]
            finish(result_path, 'FAIL', 'functional', f'Verilator RTL compilation failed:\n{tail}')

        r_sim = subprocess.run([str(td / 'obj_rtl' / 'Vtb'), f'+seed={args.seed}'], env=env, capture_output=True, text=True, timeout=120)
        if r_sim.returncode != 0 or 'RESULT: PASS' not in r_sim.stdout:
            tail = (r_sim.stdout + '\n' + r_sim.stderr)[-1800:]
            finish(result_path, 'FAIL', 'functional', f'RTL security verification failed (seed={args.seed}):\n{tail}')

        # Stage 2: Yosys-Slang Synthesis, Zero-Latch & Zero-SCC Sign-Off
        synth_stubs = td / 'synth_stubs.sv'
        shutil.copy2(PRIV_DIR / 'tests' / 'synth_stubs.sv', synth_stubs)
        syn_files = [str(synth_stubs)] + [str(work / s) for s in SYNTH_RTL_SOURCES]
        ys_script = (
            f'read_slang -DSYNTHESIS -I{work / "code"} {" ".join(syn_files)} --top ecc_top; '
            f'hierarchy -check -top ecc_top; '
            f'proc; opt; '
            f'select -assert-none t:$dlatch*; '
            f'check -assert; '
            f'scc -expect 0'
        )
        r_syn = subprocess.run([str(YOSYS), '-m', 'slang', '-p', ys_script], env=env, capture_output=True, text=True, timeout=150)
        if r_syn.returncode != 0:
            tail = (r_syn.stdout + '\n' + r_syn.stderr)[-1800:]
            finish(result_path, 'FAIL', 'synthesis', f'Yosys-Slang synthesis / latch / SCC check failed:\n{tail}')

        finish(
            result_path, 'PASS', 'functional',
            f'Passed P-384 ECDSA/ECDH RTL security verification (seed={args.seed}) and Yosys-Slang zero-latch/zero-SCC synthesis sign-off'
        )


if __name__ == '__main__':
    main()
