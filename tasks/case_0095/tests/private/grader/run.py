#!/usr/bin/env python3
import argparse
import hashlib
import json
import os
import pathlib
import re
import shutil
import subprocess
import sys
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


OSS_CAD_BIN = pathlib.Path(f"{_sb_tools_dir()}/oss-cad-suite/bin")
VERILATOR = str(OSS_CAD_BIN / 'verilator')
YOSYS = str(OSS_CAD_BIN / 'yosys')
OPENROAD = f"{_sb_tools_dir()}/bin/openroad"

TASK_DIR = pathlib.Path(__file__).resolve().parents[2]
PUBLIC_DIR = TASK_DIR / 'public'
PRIVATE_DIR = TASK_DIR / 'private'
LIB_PATH = PUBLIC_DIR / 'lib/NangateOpenCellLibrary_typical.lib'
TLEF_PATH = PUBLIC_DIR / 'lib/NangateOpenCellLibrary.tech.lef'
MLEF_PATH = PUBLIC_DIR / 'lib/NangateOpenCellLibrary.macro.mod.lef'

EDITABLE = {
    'code/rtl/fpnew_cast_multi.sv',
    'code/rtl/fpnew_noncomp.sv',
}
READONLY = [
    'code/rtl/fpnew_pkg.sv',
    'code/rtl/fpnew_classifier.sv',
    'code/rtl/fpnew_rounding.sv',
    'code/rtl/fpnew_cast_noncomp_top.sv',
    'code/rtl/cf_math_pkg.sv',
    'code/rtl/lzc.sv',
    'code/include/common_cells/registers.svh',
    'code/include/common_cells/assertions.svh',
    'lib/NangateOpenCellLibrary_typical.lib',
]

AREA_LIMIT_UM2 = 3525.0


def sha256(p: pathlib.Path) -> str:
    return hashlib.sha256(p.read_bytes()).hexdigest()


def finish(result_path: str, verdict: str, stage: str, reason: str, extra=None):
    payload = {'verdict': verdict, 'stage': stage, 'reason': reason}
    if extra:
        payload.update(extra)
    if result_path:
        pathlib.Path(result_path).write_text(json.dumps(payload, indent=2) + '\n')
    print(f'{verdict} [{stage}]: {reason}')
    sys.exit(0 if verdict == 'PASS' else 1)


def strip_comments(text: str) -> str:
    text = re.sub(r'/\*.*?\*/', '', text, flags=re.S)
    text = re.sub(r'//.*', '', text)
    return text


def check_anti_hack(cand_dir: pathlib.Path, result_path: str):
    for rel in READONLY:
        pub_f = PUBLIC_DIR / rel
        cand_f = cand_dir / rel
        if cand_f.exists() and sha256(pub_f) != sha256(cand_f):
            finish(result_path, 'FAIL', 'anti_hack', f'read-only file modified: {rel}')

    for rel in EDITABLE:
        f = cand_dir / rel
        if not f.exists():
            finish(result_path, 'FAIL', 'anti_hack', f'missing editable file: {rel}')
        raw = f.read_text(errors='ignore')
        clean = strip_comments(raw)
        if re.search(r'`\s*(?:ifdef|ifndef|elsif|else|endif|undef)\b', clean):
            finish(result_path, 'FAIL', 'anti_hack', f'preprocessor conditional macro in {rel}')
        for m in re.finditer(r'`\s*(\w+)\b', clean):
            if m.group(1) not in {'include', 'FFL', 'FFLARNC'}:
                finish(result_path, 'FAIL', 'anti_hack', f'disallowed macro `{m.group(1)} in {rel}')
        for pat, desc in [
            (r'\b(?:tb|u_ref)\s*\.', 'hierarchical testbench reference'),
            (r'\$(?:readmem|writemem|fopen|fwrite|system|finish|stop|fatal|urandom|random)\b', 'simulation system task'),
            (r'\bimport\s+"DPI', 'DPI import'),
        ]:
            if re.search(pat, clean):
                finish(result_path, 'FAIL', 'anti_hack', f'{desc} detected in {rel}')


def make_ref_rtl(src_path: pathlib.Path, dst_path: pathlib.Path):
    txt = src_path.read_text()
    for mod in ('fpnew_cast_multi', 'fpnew_noncomp', 'fpnew_cast_noncomp_top'):
        txt = re.sub(rf'\bmodule\s+{mod}\b', f'module ref_{mod}', txt)
        txt = re.sub(rf'\bendmodule\s*:\s*{mod}\b', f'endmodule : ref_{mod}', txt)
        txt = re.sub(rf'\b{mod}\s+#\(', f'ref_{mod} #(', txt)
    dst_path.write_text(txt)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--candidate', required=True)
    ap.add_argument('--seed', type=int, default=1)
    ap.add_argument('--result', default='')
    args = ap.parse_args()

    cand_dir = pathlib.Path(args.candidate).resolve()
    check_anti_hack(cand_dir, args.result)

    env = os.environ.copy()
    env['PATH'] = f'{OSS_CAD_BIN}:' + env.get('PATH', '')

    with tempfile.TemporaryDirectory(prefix='case_0095_') as tmp:
        tmp_path = pathlib.Path(tmp)
        for rel in EDITABLE:
            shutil.copy2(cand_dir / rel, tmp_path / pathlib.Path(rel).name)

        make_ref_rtl(PUBLIC_DIR / 'code/rtl/fpnew_cast_multi.sv', tmp_path / 'ref_fpnew_cast_multi.sv')
        make_ref_rtl(PUBLIC_DIR / 'code/rtl/fpnew_noncomp.sv', tmp_path / 'ref_fpnew_noncomp.sv')
        make_ref_rtl(PUBLIC_DIR / 'code/rtl/fpnew_cast_noncomp_top.sv', tmp_path / 'ref_fpnew_cast_noncomp_top.sv')

        rtl_dir = PUBLIC_DIR / 'code/rtl'
        inc_dir = PUBLIC_DIR / 'code/include'
        sim_srcs = [
            str(rtl_dir / 'cf_math_pkg.sv'),
            str(rtl_dir / 'lzc.sv'),
            str(rtl_dir / 'fpnew_pkg.sv'),
            str(rtl_dir / 'fpnew_classifier.sv'),
            str(rtl_dir / 'fpnew_rounding.sv'),
            str(tmp_path / 'fpnew_cast_multi.sv'),
            str(tmp_path / 'fpnew_noncomp.sv'),
            str(rtl_dir / 'fpnew_cast_noncomp_top.sv'),
            str(tmp_path / 'ref_fpnew_cast_multi.sv'),
            str(tmp_path / 'ref_fpnew_noncomp.sv'),
            str(tmp_path / 'ref_fpnew_cast_noncomp_top.sv'),
            str(PRIVATE_DIR / 'tests/tb.sv'),
        ]
        obj_dir = tmp_path / 'obj'
        v_cmd = [
            VERILATOR, '--binary', '-sv', '-Wno-fatal', '--timing',
            f'+incdir+{inc_dir}',
            '--top-module', 'tb', '--Mdir', str(obj_dir),
            *sim_srcs
        ]
        p = subprocess.run(v_cmd, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        print(p.stdout)
        if p.returncode != 0:
            finish(args.result, 'FAIL', 'behavior', 'Verilator compilation failed on candidate RTL')

        sim_cmd = [str(obj_dir / 'Vtb'), f'+seed={args.seed}']
        p = subprocess.run(sim_cmd, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=120)
        print(p.stdout)
        if p.returncode != 0 or 'PASS fpnew_cast_multi and fpnew_noncomp equivalence' not in p.stdout:
            finish(args.result, 'FAIL', 'behavior', 'functional, subnormal/negative rounding, NaN-boxing, or handshake mismatch in simulation')

        netlist_v = tmp_path / 'mapped.v'
        ys_script = f"""
plugin -i slang
read_slang -I {inc_dir} -D COMMON_CELLS_ASSERTS_OFF {rtl_dir / 'cf_math_pkg.sv'} {rtl_dir / 'lzc.sv'} {rtl_dir / 'fpnew_pkg.sv'} {rtl_dir / 'fpnew_classifier.sv'} {rtl_dir / 'fpnew_rounding.sv'} {tmp_path / 'fpnew_cast_multi.sv'} {tmp_path / 'fpnew_noncomp.sv'} {rtl_dir / 'fpnew_cast_noncomp_top.sv'} --top fpnew_cast_noncomp_top
synth -top fpnew_cast_noncomp_top -flatten
dfflibmap -liberty {LIB_PATH}
abc -liberty {LIB_PATH}
opt_clean -purge
stat -liberty {LIB_PATH}
write_verilog -noattr -noexpr {netlist_v}
"""
        ys_file = tmp_path / 'synth.ys'
        ys_file.write_text(ys_script)
        p = subprocess.run([YOSYS, '-s', str(ys_file)], env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        print(p.stdout)
        if p.returncode != 0:
            finish(args.result, 'FAIL', 'area', 'Yosys synthesis failed')

        m = re.search(r"Chip area for module '\\fpnew_cast_noncomp_top':\s*([0-9.]+)", p.stdout)
        if not m:
            finish(args.result, 'FAIL', 'area', 'could not parse Chip area from Yosys stat')
        area_um2 = round(float(m.group(1)), 3)

        if area_um2 > AREA_LIMIT_UM2:
            finish(args.result, 'FAIL', 'area',
                   f'mapped area {area_um2:.3f} um^2 exceeds limit {AREA_LIMIT_UM2:.1f} um^2',
                   {'area_um2': area_um2, 'area_limit_um2': AREA_LIMIT_UM2})

        sta_v = tmp_path / 'sta.v'
        sta_v.write_text(netlist_v.read_text().replace(' signed ', ' '))
        sta_tcl = tmp_path / 'sta.tcl'
        sta_tcl.write_text(f"""
read_lef {TLEF_PATH}
read_lef {MLEF_PATH}
read_liberty {LIB_PATH}
read_verilog {sta_v}
link_design fpnew_cast_noncomp_top
create_clock -name clk_i -period 2.80 [get_ports clk_i]
set_input_delay 0.20 -clock clk_i [all_inputs -no_clocks]
set_output_delay 0.20 -clock clk_i [all_outputs]
set_load 3.0 [all_outputs]
puts "=== SETUP ==="
report_checks -path_delay max -group_count 3 -digits 3
puts "=== HOLD ==="
report_checks -path_delay min -group_count 3 -digits 3
puts "BEGIN_SETUP_AUDIT"
check_setup -verbose
puts "END_SETUP_AUDIT"
exit
""")
        p = subprocess.run([OPENROAD, '-exit', str(sta_tcl)], env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        print(p.stdout)
        if p.returncode != 0:
            finish(args.result, 'FAIL', 'timing', 'OpenSTA execution failed')

        setup_sec = p.stdout.split('=== SETUP ===')[-1].split('=== HOLD ===')[0]
        hold_sec = p.stdout.split('=== HOLD ===')[-1].split('BEGIN_SETUP_AUDIT')[0]
        setup_slacks = [float(x) for x in re.findall(r'([-+]?\d+\.\d+)\s+slack\s+\((?:MET|VIOLATED)\)', setup_sec)]
        hold_slacks = [float(x) for x in re.findall(r'([-+]?\d+\.\d+)\s+slack\s+\((?:MET|VIOLATED)\)', hold_sec)]
        if not setup_slacks or not hold_slacks:
            finish(args.result, 'FAIL', 'timing', 'failed to parse OpenSTA slacks')

        worst_setup = round(min(setup_slacks), 3)
        worst_hold = round(min(hold_slacks), 3)
        metrics = {
            'area_um2': area_um2,
            'area_limit_um2': AREA_LIMIT_UM2,
            'worst_setup_slack_ns': worst_setup,
            'worst_hold_slack_ns': worst_hold,
        }
        if worst_setup < 0.0 or worst_hold < 0.0:
            finish(args.result, 'FAIL', 'timing',
                   f'OpenSTA timing violation: setup_slack={worst_setup:.2f} ns, hold_slack={worst_hold:.2f} ns',
                   metrics)

        finish(args.result, 'PASS', 'all',
               'functional equivalence, Nangate45 mapped area, and OpenSTA timing closure passed',
               metrics)


if __name__ == '__main__':
    main()
