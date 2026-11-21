#!/usr/bin/env python3
"""Trusted isolated grader for case_1003 (OpenTitan KMAC Message Packer, FIFO Flush & Error Checker PPA/STA)."""
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
PRIV = TASK_DIR / 'private'
PUB = TASK_DIR / 'public'

TOOLS = pathlib.Path(str(_sb_tools_dir()))
OSS_BIN = TOOLS / 'oss-cad-suite/bin'
OPENROAD = TOOLS / 'bin/openroad'
NANGATE = pathlib.Path(str(_sb_nangate45_dir()))
LIB = NANGATE / 'lib/NangateOpenCellLibrary_typical.lib'
TECH_LEF = NANGATE / 'lef/NangateOpenCellLibrary.tech.lef'
MACRO_LEF = NANGATE / 'lef/NangateOpenCellLibrary.macro.mod.lef'

AREA_LIMIT_UM2 = 2260.0

EDITABLE_RELS = (
    pathlib.PurePosixPath('code/prim_packer.sv'),
    pathlib.PurePosixPath('code/kmac_msgfifo.sv'),
    pathlib.PurePosixPath('code/kmac_errchk.sv'),
)

RO_CODE_FILES = (
    'LICENSE',
    'prim_assert.sv',
    'prim_assert_dummy_macros.svh',
    'prim_assert_standard_macros.svh',
    'prim_assert_yosys_macros.svh',
    'prim_assert_sec_cm.svh',
    'prim_flop_macros.sv',
    'prim_util_pkg.sv',
    'prim_mubi_pkg.sv',
    'prim_count_pkg.sv',
    'lc_ctrl_reg_pkg.sv',
    'lc_ctrl_state_pkg.sv',
    'lc_ctrl_pkg.sv',
    'sha3_pkg.sv',
    'kmac_pkg.sv',
    'prim_flop.sv',
    'prim_sparse_fsm_flop.sv',
    'prim_count.sv',
    'prim_fifo_assert.svh',
    'prim_fifo_sync_cnt.sv',
    'prim_fifo_sync.sv',
    'kmac_msg_err_top.sv',
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


def screen_rtl(name: str, expected_mod: str, raw_text: str, result_path: pathlib.Path):
    if len(raw_text.encode('utf-8')) > 200_000:
        finish(result_path, False, 'anti_hack', f'{name}: file exceeds size limit')
    if re.search(r'(?i)(?:pragma|synopsys|synthesis|verilator)\s+(?:translate_)?(?:off|on)', raw_text):
        finish(result_path, False, 'anti_hack', f'{name}: disallowed synthesis/simulation pragma')
    clean = re.sub(r'/\*.*?\*/|//[^\n]*', ' ', raw_text, flags=re.S)
    clean_no_inc = re.sub(r'(?m)^\s*`include\s+"prim_assert\.sv"\s*$', ' ', clean)
    clean_no_inc = re.sub(r'`(?:ASSERT_INIT|ASSERT_KNOWN|ASSERT|ASSUME_FPV|ASSUME|COVER)\s*\([^;]*?\)\s*', ' ', clean_no_inc, flags=re.S)
    for mac in (
        '`ASSERT_INIT',
        '`ASSERT_KNOWN',
        '`ASSERT',
        '`ASSUME_FPV',
        '`ASSUME',
        '`COVER',
        '`PRIM_FLOP_SPARSE_FSM',
    ):
        clean_no_inc = clean_no_inc.replace(mac, ' ')
    if re.search(
        r'`|\$(?!clog2\b|signed\b|unsigned\b|bits\b|size\b|onehot0\b|onehot\b|countones\b|past\b|rose\b|fell\b|stable\b|changed\b)'
        r'|\b(?:initial|final|force|release|bind|primitive|blackbox|whitebox|import\s*"DPI|export\s*"DPI)\b'
        r'|\(\*(?!\s*\))',
        clean_no_inc,
    ):
        finish(result_path, False, 'anti_hack', f'{name}: disallowed directive, system task, or attribute in RTL')
    if re.search(r'\$root\b|\b(?:tb|dut|grader|oracle)\s*\.', clean_no_inc):
        finish(result_path, False, 'anti_hack', f'{name}: illegal hierarchical reference in RTL')
    mods = re.findall(r'\bmodule\s+([A-Za-z_]\w*)', clean_no_inc)
    forbidden_mods = (
        {pathlib.PurePosixPath(f).stem for f in RO_CODE_FILES if f.endswith('.sv')}
        | ({p.stem for p in EDITABLE_RELS} - {expected_mod})
        | {'tb'}
    )
    if expected_mod not in mods or any(m in forbidden_mods for m in mods):
        finish(result_path, False, 'structural', f'{name}: expected module {expected_mod} without colliding module names, got {mods}')


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
            finish(res_path, False, 'anti_hack', 'candidate directory missing or symlinked')
        cand = cand_in.resolve(strict=True)
    except Exception as e:
        finish(res_path, False, 'anti_hack', f'invalid candidate directory: {e}')

    # 1. Verify read-only files are untouched
    for fn in RO_CODE_FILES:
        ref = PUB / 'code' / fn
        q = cand / 'code' / fn
        if q.exists() or q.is_symlink():
            if q.is_symlink() or not q.is_file() or not q.resolve().is_relative_to(cand):
                finish(res_path, False, 'anti_hack', f'protected file symlinked: code/{fn}')
            if sha256_bytes(q) != sha256_bytes(ref):
                finish(res_path, False, 'anti_hack', f'protected file modified: code/{fn}')

    for lib_f in (PUB / 'lib').iterdir():
        q = cand / 'lib' / lib_f.name
        if q.exists() or q.is_symlink():
            if q.is_symlink() or not q.is_file() or sha256_bytes(q) != sha256_bytes(lib_f):
                finish(res_path, False, 'anti_hack', f'protected lib file modified: lib/{lib_f.name}')

    # 2. Load and screen editable RTL files
    cand_texts = {}
    for rel, mod_name in [
        (pathlib.PurePosixPath('code/prim_packer.sv'), 'prim_packer'),
        (pathlib.PurePosixPath('code/kmac_msgfifo.sv'), 'kmac_msgfifo'),
        (pathlib.PurePosixPath('code/kmac_errchk.sv'), 'kmac_errchk'),
    ]:
        p = cand / rel
        if not p.exists() and (cand / rel.name).exists():
            p = cand / rel.name
        if p.is_symlink() or not p.is_file() or not p.resolve().is_relative_to(cand):
            finish(res_path, False, 'anti_hack', f'missing or symlinked editable file: {rel}')
        txt = p.read_text(encoding='utf-8', errors='replace')
        screen_rtl(str(rel), mod_name, txt, res_path)
        cand_texts[rel.name] = txt

    with tempfile.TemporaryDirectory(prefix='case_1003_') as tmpd:
        t = pathlib.Path(tmpd)
        code_dir = t / 'code'
        code_dir.mkdir()
        for fn in RO_CODE_FILES:
            if fn != 'LICENSE':
                shutil.copyfile(PUB / 'code' / fn, code_dir / fn)
        for fn, txt in cand_texts.items():
            (code_dir / fn).write_text(txt, encoding='utf-8')

        rtl_sources = [
            code_dir / 'prim_util_pkg.sv',
            code_dir / 'prim_mubi_pkg.sv',
            code_dir / 'prim_count_pkg.sv',
            code_dir / 'lc_ctrl_reg_pkg.sv',
            code_dir / 'lc_ctrl_state_pkg.sv',
            code_dir / 'lc_ctrl_pkg.sv',
            code_dir / 'sha3_pkg.sv',
            code_dir / 'kmac_pkg.sv',
            code_dir / 'prim_flop.sv',
            code_dir / 'prim_sparse_fsm_flop.sv',
            code_dir / 'prim_count.sv',
            code_dir / 'prim_fifo_sync_cnt.sv',
            code_dir / 'prim_fifo_sync.sv',
            code_dir / 'prim_packer.sv',
            code_dir / 'kmac_msgfifo.sv',
            code_dir / 'kmac_errchk.sv',
            code_dir / 'kmac_msg_err_top.sv',
        ]

        env = os.environ.copy()
        env.update({
            'PATH': f'{OSS_BIN}:{TOOLS / "bin"}:/usr/bin:/bin',
            'HOME': str(t),
            'TMPDIR': str(t),
            'OMP_NUM_THREADS': '1',
            'MAKEFLAGS': '-j1',
        })

        # 3. Verilator functional simulation
        obj_dir = t / 'obj_dir'
        c_proc = subprocess.run(
            [
                str(OSS_BIN / 'verilator'),
                '--binary', '--timing', '-j', '1', '-Wno-fatal',
                '-DSYNTHESIS',
                f'-I{code_dir}',
                '--top-module', 'tb',
                '--Mdir', str(obj_dir),
                *map(str, rtl_sources),
                str(PRIV / 'tests/tb.sv'),
            ],
            cwd=t,
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            timeout=180,
        )
        if c_proc.returncode != 0 or not (obj_dir / 'Vtb').is_file():
            finish(res_path, False, 'behavior', f'Verilator compile failed: {c_proc.stdout[-1500:].strip()}')

        s_proc = subprocess.run(
            [str(obj_dir / 'Vtb'), f'+seed={args.seed}'],
            cwd=t,
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            timeout=60,
        )
        if s_proc.returncode != 0 or 'FAIL' in s_proc.stdout or f'PASS_CASE_1003 seed={args.seed}' not in s_proc.stdout:
            finish(res_path, False, 'behavior', f'Functional simulation failed: {s_proc.stdout[-1500:].strip()}')

        # 4. Yosys/Slang + ABC Nangate45 synthesis
        mapped_v = t / 'mapped.v'
        ys_script = t / 'synth.ys'
        ys_script.write_text(
            f'read_slang --ignore-assertions --top kmac_msg_err_top -DSYNTHESIS -I {code_dir} '
            + ' '.join(map(str, rtl_sources)) + '\n'
            'hierarchy -check -top kmac_msg_err_top\n'
            'synth -top kmac_msg_err_top\n'
            'opt\n'
            f'dfflibmap -liberty {LIB}\n'
            f'abc -liberty {LIB}\n'
            'clean\n'
            f'read_liberty -lib {LIB}\n'
            'check -assert\n'
            f'stat -liberty {LIB}\n'
            f'write_verilog -noattr {mapped_v}\n'
        )
        y_proc = subprocess.run(
            [str(OSS_BIN / 'yosys'), '-Q', '-T', '-m', 'slang', str(ys_script)],
            cwd=t,
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            timeout=180,
        )
        m_area = re.search(r'Chip area for module .*?:\s*([\d.]+)', y_proc.stdout)
        if y_proc.returncode != 0 or not m_area or not mapped_v.is_file():
            finish(res_path, False, 'synthesis', f'Yosys/Slang synthesis failed: {y_proc.stdout[-1500:].strip()}')

        area_um2 = round(float(m_area.group(1)), 3)
        if area_um2 > AREA_LIMIT_UM2:
            finish(
                res_path,
                False,
                'area',
                f'mapped cell area {area_um2:.3f} um^2 exceeds limit {AREA_LIMIT_UM2:.1f} um^2',
                area_um2=area_um2,
                area_limit_um2=AREA_LIMIT_UM2,
            )

        # 5. OpenROAD placement-estimated STA at 1.50 ns clock period
        sta_v = t / 'sta.v'
        sta_v.write_text(mapped_v.read_text(encoding='utf-8').replace(' signed ', ' '), encoding='utf-8')
        env_or = dict(env)
        env_or.update({
            'TECH_LEF': str(TECH_LEF),
            'MACRO_LEF': str(MACRO_LEF),
            'LIB_FILE': str(LIB),
            'NETLIST': str(sta_v),
        })
        o_proc = subprocess.run(
            [str(OPENROAD), '-exit', str(PRIV / 'tests/flow.tcl')],
            cwd=t,
            env=env_or,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            timeout=180,
        )
        if o_proc.returncode != 0:
            finish(res_path, False, 'timing', f'OpenROAD failed: {o_proc.stdout[-1500:].strip()}', area_um2=area_um2)

        setup_sec = re.search(r'=== SETUP ===(.*?)=== HOLD ===', o_proc.stdout, re.S)
        hold_sec = re.search(r'=== HOLD ===(.*?)BEGIN_SETUP_AUDIT', o_proc.stdout, re.S)
        audit_sec = re.search(r'BEGIN_SETUP_AUDIT(.*?)END_SETUP_AUDIT', o_proc.stdout, re.S)
        if not setup_sec or not hold_sec or not audit_sec:
            finish(res_path, False, 'timing', 'incomplete OpenROAD STA report sections', area_um2=area_um2)

        audit_txt = audit_sec.group(1).strip()
        if audit_txt or re.search(r'clock not found|unconstrained|no clock', audit_txt, re.I):
            finish(res_path, False, 'timing', f'timing constraint audit failed: {audit_txt}', area_um2=area_um2)

        setup_slacks = [float(v) for v in re.findall(r'([-+\d.]+)\s+slack \((?:MET|VIOLATED)\)', setup_sec.group(1))]
        hold_slacks = [float(v) for v in re.findall(r'([-+\d.]+)\s+slack \((?:MET|VIOLATED)\)', hold_sec.group(1))]
        if not setup_slacks or not hold_slacks:
            finish(res_path, False, 'timing', 'no setup or hold slack values parsed from OpenROAD report', area_um2=area_um2)

        worst_setup = round(min(setup_slacks), 3)
        worst_hold = round(min(hold_slacks), 3)
        if worst_setup < 0.0:
            finish(
                res_path,
                False,
                'timing',
                f'worst setup slack {worst_setup:.3f} ns < 0.0 ns at 1.50 ns clock',
                area_um2=area_um2,
                worst_setup_slack_ns=worst_setup,
                worst_hold_slack_ns=worst_hold,
            )
        if worst_hold < 0.0:
            finish(
                res_path,
                False,
                'timing',
                f'worst hold slack {worst_hold:.3f} ns < 0.0 ns',
                area_um2=area_um2,
                worst_setup_slack_ns=worst_setup,
                worst_hold_slack_ns=worst_hold,
            )

        finish(
            res_path,
            True,
            'score',
            f'PASS functional, area={area_um2:.3f} um^2 <= {AREA_LIMIT_UM2:.1f} um^2, setup_slack={worst_setup:.3f} ns, hold_slack={worst_hold:.3f} ns',
            area_um2=area_um2,
            area_limit_um2=AREA_LIMIT_UM2,
            worst_setup_slack_ns=worst_setup,
            worst_hold_slack_ns=worst_hold,
        )


if __name__ == '__main__':
    main()
