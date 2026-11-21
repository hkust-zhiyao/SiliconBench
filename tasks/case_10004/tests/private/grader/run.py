#!/usr/bin/env python3
"""Trusted isolated grader for case_10004 (OpenPiton NoC-to-AXI4 Memory Bridge Framing, Slot Protection, Response Arbitration, and PPA/STA)."""
import argparse
import hashlib
import json
import os
import pathlib
import re
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
IVERILOG_BIN = TOOLS / 'iverilog-v13/bin/iverilog'
VVP_BIN = TOOLS / 'iverilog-v13/bin/vvp'
OSS_BIN = TOOLS / 'oss-cad-suite/bin'
OPENROAD = TOOLS / 'bin/openroad'
NANGATE = pathlib.Path(str(_sb_nangate45_dir()))
LIB = NANGATE / 'lib/NangateOpenCellLibrary_typical.lib'
TECH_LEF = NANGATE / 'lef/NangateOpenCellLibrary.tech.lef'
MACRO_LEF = NANGATE / 'lef/NangateOpenCellLibrary.macro.mod.lef'

DESER_AREA_LIMIT_UM2 = 4955.0
SER_AREA_LIMIT_UM2 = 4810.0
BUF_AREA_LIMIT_UM2 = 21350.0
CLOCK_PERIOD_NS = 1.08

EDITABLES = (
    'code/rtl/noc_axi4_bridge_deser.v',
    'code/rtl/noc_axi4_bridge_ser.v',
    'code/rtl/noc_axi4_bridge_buffer.v',
)

RO_FILES = (
    'code/LICENSE',
    'code/include/define.tmp.h',
    'code/include/mc_define.h',
    'code/include/network_define.v',
    'code/include/noc_axi4_bridge_define.vh',
    'code/rtl/storage_addr_trans.v',
    'code/rtl/noc_axi4_bridge_sram_data.v',
    'code/rtl/noc_axi4_bridge_sram_req.v',
    'code/rtl/noc_axi4_bridge_read.v',
    'code/rtl/noc_axi4_bridge_write.v',
    'code/rtl/noc_axi4_bridge.v',
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


def screen_rtl(rel_name: str, raw_text: str, result_path: pathlib.Path):
    if len(raw_text.encode('utf-8')) > 200_000:
        finish(result_path, False, 'policy', f'{rel_name} exceeds size limit')
    if re.search(r'(?i)(?:pragma|synopsys|synthesis|verilator)\s+(?:translate_)?(?:off|on)', raw_text):
        finish(result_path, False, 'policy', f'disallowed simulation/synthesis pragma in {rel_name}')
    clean = re.sub(r'/\*.*?\*/|//[^\n]*', ' ', raw_text, flags=re.S)
    clean_no_dir = re.sub(
        r'`(?:timescale|resetall|default_nettype|include|define|ifdef|ifndef|endif)\b[^\n]*',
        ' ',
        clean,
    )
    if re.search(
        r'\$(?:fopen|fclose|fread|fwrite|fdisplay|fscanf|system|finish|stop|fatal|error|warning'
        r'|readmemh|readmemb|writememh|writememb|dumpfile|dumpvars|value\$plusargs|test\$plusargs|urandom|random)\b'
        r'|\b(?:initial|final|force|release|bind|primitive|blackbox|whitebox|always_latch|import\s*"DPI|export\s*"DPI)\b'
        r'|#\s*\d',
        clean_no_dir,
    ):
        finish(result_path, False, 'policy', f'disallowed system task, procedural escape, or delay in {rel_name}')
    if re.search(r'\$root\b|\b(?:tb|u_deser|u_ser|u_buf|u_bridge|grader|oracle)\s*\.', clean_no_dir):
        finish(result_path, False, 'policy', f'illegal hierarchical reference in {rel_name}')
    if re.search(r'`\s*(?:ifdef|ifndef|elsif)\s+(?:VERILATOR|SYNTHESIS|SIMULATION|__ICARUS__|VCS|QUESTA)\b', clean, re.I):
        finish(result_path, False, 'policy', f'simulator/synthesis macro divergence in {rel_name}')
    for inc in re.findall(r'`include\s+"([^"]+)"', clean):
        p = pathlib.PurePosixPath(inc)
        if p.is_absolute() or '..' in p.parts:
            finish(result_path, False, 'policy', f'include path escape in {rel_name}')


def check_sta_section(log_txt: str, label: str, result_path: pathlib.Path, **metrics):
    setup_sec = re.search(r'=== SETUP ===(.*?)=== HOLD ===', log_txt, re.S)
    hold_sec = re.search(r'=== HOLD ===(.*?)BEGIN_SETUP_AUDIT', log_txt, re.S)
    audit_sec = re.search(r'BEGIN_SETUP_AUDIT(.*?)END_SETUP_AUDIT', log_txt, re.S)
    if not setup_sec or not hold_sec or not audit_sec:
        finish(result_path, False, 'timing', f'incomplete OpenROAD STA report sections for {label}', **metrics)
    audit_txt = audit_sec.group(1).strip()
    if audit_txt or re.search(r'clock not found|unconstrained|no clock', audit_txt, re.I):
        finish(result_path, False, 'timing', f'timing constraint audit failed for {label}: {audit_txt}', **metrics)
    setup_slacks = [float(v) for v in re.findall(r'([-+\d.]+)\s+slack \((?:MET|VIOLATED)\)', setup_sec.group(1))]
    hold_slacks = [float(v) for v in re.findall(r'([-+\d.]+)\s+slack \((?:MET|VIOLATED)\)', hold_sec.group(1))]
    if not setup_slacks or not hold_slacks:
        finish(result_path, False, 'timing', f'no setup or hold slack values parsed for {label}', **metrics)
    return round(min(setup_slacks), 3), round(min(hold_slacks), 3)


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
            finish(res_path, False, 'policy', 'candidate directory missing or symlinked')
        cand = cand_in.resolve(strict=True)
    except Exception as e:
        finish(res_path, False, 'policy', f'invalid candidate directory: {e}')

    for entry in sorted(cand.rglob('*')):
        if entry.is_symlink():
            finish(res_path, False, 'policy', f'symlink in candidate directory: {entry.relative_to(cand)}')

    for rel_str in RO_FILES:
        ref = PUB / rel_str
        q = cand / rel_str
        if q.exists():
            if not q.is_file() or sha256_bytes(q) != sha256_bytes(ref):
                finish(res_path, False, 'policy', f'protected file modified: {rel_str}')

    for lib_f in (PUB / 'lib').iterdir():
        q = cand / 'lib' / lib_f.name
        if q.exists():
            if not q.is_file() or sha256_bytes(q) != sha256_bytes(lib_f):
                finish(res_path, False, 'policy', f'protected lib file modified: lib/{lib_f.name}')

    cand_sources = {}
    for rel_str in EDITABLES:
        p = cand / rel_str
        if not p.exists():
            alt = cand / pathlib.Path(rel_str).name
            if alt.exists():
                p = alt
        if not p.is_file() or not p.resolve().is_relative_to(cand):
            finish(res_path, False, 'policy', f'missing editable file: {rel_str}')
        txt = p.read_text(encoding='utf-8', errors='replace')
        screen_rtl(rel_str, txt, res_path)
        cand_sources[pathlib.Path(rel_str).name] = txt

    with tempfile.TemporaryDirectory(prefix='case_10004_') as tmpd:
        t = pathlib.Path(tmpd)
        rtl_dir = t / 'rtl'
        rtl_dir.mkdir()
        for fname, txt in cand_sources.items():
            (rtl_dir / fname).write_text(txt, encoding='utf-8')

        inc_dir = PUB / 'code/include'
        ro_rtl = PUB / 'code/rtl'
        sim_files = [
            ro_rtl / 'storage_addr_trans.v',
            ro_rtl / 'noc_axi4_bridge_sram_data.v',
            ro_rtl / 'noc_axi4_bridge_sram_req.v',
            ro_rtl / 'noc_axi4_bridge_read.v',
            ro_rtl / 'noc_axi4_bridge_write.v',
            rtl_dir / 'noc_axi4_bridge_deser.v',
            rtl_dir / 'noc_axi4_bridge_ser.v',
            rtl_dir / 'noc_axi4_bridge_buffer.v',
            ro_rtl / 'noc_axi4_bridge.v',
        ]

        env = os.environ.copy()
        env.pop('LD_PRELOAD', None)
        env.update({
            'PATH': f'{TOOLS / "iverilog-v13/bin"}:{OSS_BIN}:{TOOLS / "bin"}:/usr/bin:/bin',
            'HOME': str(t),
            'TMPDIR': str(t),
            'OMP_NUM_THREADS': '1',
            'MAKEFLAGS': '-j1',
        })

        # 3. Functional simulation (Icarus Verilog)
        sim_vvp = t / 'sim.vvp'
        c_proc = subprocess.run(
            [str(IVERILOG_BIN), '-g2012', '-s', 'tb', '-I', str(inc_dir), '-o', str(sim_vvp),
             *map(str, sim_files), str(PRIV / 'tests/tb.sv')],
            cwd=t, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=60
        )
        if c_proc.returncode != 0:
            finish(res_path, False, 'behavior', f'Icarus compile failed: {c_proc.stdout[-1200:].strip()}')

        for s in (args.seed, args.seed + 100):
            r_proc = subprocess.run(
                [str(VVP_BIN), str(sim_vvp), f'+SEED={s}'],
                cwd=t, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=30
            )
            if r_proc.returncode != 0 or 'TB_PASS' not in r_proc.stdout or 'TB_FAIL' in r_proc.stdout:
                finish(res_path, False, 'behavior', f'Functional check failed (seed={s}): {r_proc.stdout[-1200:].strip()}')

        def run_yosys(top_name: str, src_files: list[pathlib.Path], out_v: pathlib.Path) -> float:
            ys = t / f'synth_{top_name}.ys'
            ys.write_text(
                f'read_slang --top {top_name} -I {inc_dir} ' + ' '.join(map(str, src_files)) + '\n'
                f'hierarchy -check -top {top_name}\n'
                f'synth -top {top_name}\n'
                'opt\n'
                f'dfflibmap -liberty {LIB}\n'
                f'abc -liberty {LIB}\n'
                'clean\n'
                f'read_liberty -lib {LIB}\n'
                'check -assert\n'
                f'stat -liberty {LIB}\n'
                f'write_verilog -noattr {out_v}\n'
            )
            yp = subprocess.run(
                [str(OSS_BIN / 'yosys'), '-Q', '-T', '-m', 'slang', str(ys)],
                cwd=t, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=180
            )
            m = re.search(r'Chip area for module .*?:\s*([\d.]+)', yp.stdout)
            if yp.returncode != 0 or not m or not out_v.is_file():
                finish(res_path, False, 'synthesis', f'Yosys synthesis failed on {top_name}: {yp.stdout[-1200:].strip()}')
            if re.search(r'\bDLH_|DLL_|TLAT', out_v.read_text(encoding='utf-8')):
                finish(res_path, False, 'synthesis', f'inferred latch detected in {top_name}')
            return round(float(m.group(1)), 3)

        mapped_deser = t / 'mapped_deser.v'
        deser_area_um2 = run_yosys('noc_axi4_bridge_deser', [rtl_dir / 'noc_axi4_bridge_deser.v'], mapped_deser)

        mapped_ser = t / 'mapped_ser.v'
        ser_area_um2 = run_yosys('noc_axi4_bridge_ser', [rtl_dir / 'noc_axi4_bridge_ser.v'], mapped_ser)

        mapped_buf = t / 'mapped_buf.v'
        buf_area_um2 = run_yosys(
            'noc_axi4_bridge_buffer',
            [ro_rtl / 'noc_axi4_bridge_sram_data.v', ro_rtl / 'noc_axi4_bridge_sram_req.v', rtl_dir / 'noc_axi4_bridge_buffer.v'],
            mapped_buf,
        )

        metrics = {
            'deser_area_um2': deser_area_um2,
            'deser_area_limit_um2': DESER_AREA_LIMIT_UM2,
            'ser_area_um2': ser_area_um2,
            'ser_area_limit_um2': SER_AREA_LIMIT_UM2,
            'buf_area_um2': buf_area_um2,
            'buf_area_limit_um2': BUF_AREA_LIMIT_UM2,
        }

        if deser_area_um2 > DESER_AREA_LIMIT_UM2:
            finish(res_path, False, 'area', f'noc_axi4_bridge_deser area {deser_area_um2:.3f} um^2 exceeds limit {DESER_AREA_LIMIT_UM2:.1f} um^2', **metrics)
        if ser_area_um2 > SER_AREA_LIMIT_UM2:
            finish(res_path, False, 'area', f'noc_axi4_bridge_ser area {ser_area_um2:.3f} um^2 exceeds limit {SER_AREA_LIMIT_UM2:.1f} um^2', **metrics)
        if buf_area_um2 > BUF_AREA_LIMIT_UM2:
            finish(res_path, False, 'area', f'noc_axi4_bridge_buffer area {buf_area_um2:.3f} um^2 exceeds limit {BUF_AREA_LIMIT_UM2:.1f} um^2', **metrics)

        # OpenROAD STA on noc_axi4_bridge_deser and noc_axi4_bridge_ser at 1.08 ns
        for label, netlist_p, tcl_name, prefix in (
            ('noc_axi4_bridge_deser', mapped_deser, 'flow_deser.tcl', 'deser'),
            ('noc_axi4_bridge_ser', mapped_ser, 'flow_ser.tcl', 'ser'),
        ):
            env_or = dict(env)
            env_or.update({
                'TECH_LEF': str(TECH_LEF),
                'MACRO_LEF': str(MACRO_LEF),
                'LIB_FILE': str(LIB),
                'NETLIST': str(netlist_p),
            })
            o_proc = subprocess.run(
                [str(OPENROAD), '-exit', str(PRIV / 'tests' / tcl_name)],
                cwd=t, env=env_or, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=180
            )
            if o_proc.returncode != 0:
                finish(res_path, False, 'timing', f'OpenROAD failed on {label}: {o_proc.stdout[-1200:].strip()}', **metrics)
            setup_s, hold_s = check_sta_section(o_proc.stdout, label, res_path, **metrics)
            metrics[f'{prefix}_setup_slack_ns'] = setup_s
            metrics[f'{prefix}_hold_slack_ns'] = hold_s
            if setup_s < 0.0:
                finish(res_path, False, 'timing', f'{label} setup slack {setup_s:.3f} ns < 0.0 ns at {CLOCK_PERIOD_NS} ns clock', **metrics)
            if hold_s < 0.0:
                finish(res_path, False, 'timing', f'{label} hold slack {hold_s:.3f} ns < 0.0 ns', **metrics)

        finish(
            res_path, True, 'score',
            f'PASS functional, deser_area={deser_area_um2:.1f}, ser_area={ser_area_um2:.1f}, buf_area={buf_area_um2:.1f}, '
            f'deser_setup={metrics["deser_setup_slack_ns"]:.2f}, ser_setup={metrics["ser_setup_slack_ns"]:.2f}',
            **metrics
        )


if __name__ == '__main__':
    main()
