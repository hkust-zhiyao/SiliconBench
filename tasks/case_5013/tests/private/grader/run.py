#!/usr/bin/env python3
import argparse, json, pathlib, re, shutil, subprocess, tempfile

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
PUBLIC_DIR = TASK_DIR / 'public'
TESTS_DIR = TASK_DIR / 'private' / 'tests'

TOOLS_DIR = pathlib.Path(str(_sb_tools_dir()))
VERILATOR = TOOLS_DIR / 'verilator-v5.038/bin/verilator'
YOSYS = TOOLS_DIR / 'oss-cad-suite/bin/yosys'
OPENROAD = TOOLS_DIR / 'bin/openroad'

LIB_FILE = PUBLIC_DIR / 'lib/NangateOpenCellLibrary_typical.lib'
TECH_LEF = PUBLIC_DIR / 'lef/NangateOpenCellLibrary.tech.lef'
MACRO_LEF = PUBLIC_DIR / 'lef/NangateOpenCellLibrary.macro.mod.lef'

EDITABLE = [
    'code/lsu_bypass.sv',
    'code/load_unit.sv',
    'code/store_buffer.sv',
    'code/load_store_unit.sv',
]

CLOCK_PERIOD_NS = 1.80
MAX_AREA_UM2 = 8260.0


def strip_comments(text: str) -> str:
    return re.sub(r'/\*.*?\*/|//[^\n]*', '', text, flags=re.S)


def check_anti_hack(cand_dir: pathlib.Path) -> str | None:
    forbidden = [
        r'\$(?:finish|stop|fatal|system|fopen|readmemh|writememh)\b',
        r'\b(?:force|release|bind)\b',
        r'\b(?:tb|grader|oracle)\s*\.',
        r'`\s*(?:ifdef|ifndef|elsif)\s+(?:SYNTHESIS|VERILATOR|SIMULATION)\b',
    ]
    for rel in EDITABLE:
        f = cand_dir / rel
        if not f.exists():
            return f'missing editable file {rel}'
        raw = strip_comments(f.read_text(errors='ignore'))
        base_raw = strip_comments((PUBLIC_DIR / rel).read_text(errors='ignore'))
        for pat in forbidden:
            if len(re.findall(pat, raw)) > len(re.findall(pat, base_raw)):
                return f'disallowed construct ({pat}) in {rel}'
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--candidate', required=True)
    ap.add_argument('--seed', type=int, default=101)
    ap.add_argument('--result', required=True)
    args = ap.parse_args()

    cand_dir = pathlib.Path(args.candidate)
    res_path = pathlib.Path(args.result)

    def write_result(payload: dict, rc: int):
        res_path.parent.mkdir(parents=True, exist_ok=True)
        res_path.write_text(json.dumps(payload, indent=2) + '\n')
        raise SystemExit(rc)

    viol = check_anti_hack(cand_dir)
    if viol:
        write_result({'verdict': 'FAIL', 'stage': 'policy', 'detail': viol}, 1)

    with tempfile.TemporaryDirectory(prefix='case_5013_grade_') as td:
        tmp = pathlib.Path(td)
        for rel in EDITABLE:
            shutil.copy2(cand_dir / rel, tmp / pathlib.Path(rel).name)

        rtl_files = [
            str(PUBLIC_DIR / 'code/config_pkg.sv'),
            str(PUBLIC_DIR / 'code/cv64a60ax_config_pkg.sv'),
            str(PUBLIC_DIR / 'code/riscv_pkg.sv'),
            str(PUBLIC_DIR / 'code/ariane_pkg.sv'),
            str(PUBLIC_DIR / 'code/cf_math_pkg.sv'),
            str(PUBLIC_DIR / 'code/lzc.sv'),
            str(PUBLIC_DIR / 'code/shift_reg.sv'),
            str(PUBLIC_DIR / 'code/cva6_fifo_v3.sv'),
            str(PUBLIC_DIR / 'code/amo_buffer.sv'),
            str(PUBLIC_DIR / 'code/pmp_entry.sv'),
            str(PUBLIC_DIR / 'code/pmp.sv'),
            str(PUBLIC_DIR / 'code/pmp_data_if.sv'),
            str(tmp / 'lsu_bypass.sv'),
            str(tmp / 'store_buffer.sv'),
            str(PUBLIC_DIR / 'code/store_unit.sv'),
            str(tmp / 'load_unit.sv'),
            str(tmp / 'load_store_unit.sv'),
            str(PUBLIC_DIR / 'flow/lsu_subsys_top.sv'),
        ]

        # 1. Verilator simulation
        c_cmd = [
            str(VERILATOR), '--binary', '--timing', '-Wno-fatal',
            '--top-module', 'tb',
            '-I' + str(PUBLIC_DIR / 'include'),
            *rtl_files,
            str(TESTS_DIR / 'tb.sv'),
        ]
        c_proc = subprocess.run(c_cmd, cwd=tmp, capture_output=True, text=True, timeout=120)
        if c_proc.returncode != 0:
            write_result({'verdict': 'FAIL', 'stage': 'compile', 'detail': c_proc.stderr[-1500:]}, 1)

        s_proc = subprocess.run([str(tmp / 'obj_dir/Vtb'), f'+seed={args.seed}'], cwd=tmp, capture_output=True, text=True, timeout=60)
        if s_proc.returncode != 0 or 'PASS:' not in s_proc.stdout:
            write_result({'verdict': 'FAIL', 'stage': 'functional', 'detail': (s_proc.stdout + s_proc.stderr)[-1500:]}, 1)

        # 2. Yosys synthesis + latch/SCC check
        netlist = tmp / 'netlist.v'
        ys_script = tmp / 'synth.ys'
        ys_script.write_text(f"""read_slang --ignore-assertions --top lsu_subsys_top -I{PUBLIC_DIR / 'include'} -DSYNTHESIS {' '.join(rtl_files)}
hierarchy -check -top lsu_subsys_top
proc; opt_clean
scc -expect 0
select -assert-none */t:$dlatch* */t:$adlatch* */t:$latch* */t:$sr* */t:$_DLATCH*
synth -top lsu_subsys_top -flatten
dfflibmap -liberty {LIB_FILE}
abc -liberty {LIB_FILE} -D 1000
clean
stat -liberty {LIB_FILE}
write_verilog -noattr -noexpr -nohex -nodec {netlist}
""")
        y_proc = subprocess.run([str(YOSYS), '-Q', '-T', '-m', 'slang', '-s', str(ys_script)], cwd=tmp, capture_output=True, text=True, timeout=120)
        if y_proc.returncode != 0 or not netlist.exists():
            write_result({'verdict': 'FAIL', 'stage': 'synthesis', 'detail': (y_proc.stdout + y_proc.stderr)[-1500:]}, 1)

        m_area = re.search(r"Chip area for module '\\lsu_subsys_top':\s+([0-9.]+)", y_proc.stdout)
        if not m_area:
            write_result({'verdict': 'FAIL', 'stage': 'synthesis', 'detail': 'failed to parse chip area'}, 1)
        area_um2 = float(m_area.group(1))
        if area_um2 > MAX_AREA_UM2:
            write_result({
                'verdict': 'FAIL',
                'stage': 'area',
                'detail': f'area {area_um2:.3f} um^2 exceeds {MAX_AREA_UM2}',
                'area_um2': area_um2,
            }, 1)

        # 3. OpenROAD STA
        sdc_file = tmp / 'design.sdc'
        sdc_file.write_text(f"""create_clock -name core_clk -period {CLOCK_PERIOD_NS} [get_ports clk_i]
set_input_delay 0.15 -clock core_clk [all_inputs]
set_output_delay 0.15 -clock core_clk [all_outputs]
set_false_path -from [get_ports rst_ni]
""")
        tcl_file = tmp / 'sta.tcl'
        tcl_file.write_text(f"""read_lef {TECH_LEF}
read_lef {MACRO_LEF}
read_liberty {LIB_FILE}
read_verilog {netlist}
link_design lsu_subsys_top
read_sdc {sdc_file}
report_worst_slack -max
report_worst_slack -min
exit
""")
        o_proc = subprocess.run([str(OPENROAD), '-exit', str(tcl_file)], cwd=tmp, capture_output=True, text=True, timeout=60)
        if o_proc.returncode != 0:
            write_result({'verdict': 'FAIL', 'stage': 'timing', 'detail': (o_proc.stdout + o_proc.stderr)[-1500:]}, 1)

        m_setup = re.search(r'worst slack max\s+([-0-9.]+)', o_proc.stdout)
        m_hold = re.search(r'worst slack min\s+([-0-9.]+)', o_proc.stdout)
        if not m_setup or not m_hold:
            write_result({'verdict': 'FAIL', 'stage': 'timing', 'detail': 'failed to parse slack from OpenROAD'}, 1)
        setup_slack = float(m_setup.group(1))
        hold_slack = float(m_hold.group(1))

        if setup_slack < 0.0 or hold_slack < 0.0:
            write_result({
                'verdict': 'FAIL',
                'stage': 'timing',
                'detail': f'setup slack {setup_slack:.3f} ns, hold slack {hold_slack:.3f} ns at {CLOCK_PERIOD_NS} ns clock',
                'area_um2': area_um2,
                'worst_setup_slack_ns': setup_slack,
                'worst_hold_slack_ns': hold_slack,
            }, 1)

        write_result({
            'verdict': 'PASS',
            'stage': 'complete',
            'area_um2': area_um2,
            'worst_setup_slack_ns': setup_slack,
            'worst_hold_slack_ns': hold_slack,
        }, 0)


if __name__ == '__main__':
    main()
