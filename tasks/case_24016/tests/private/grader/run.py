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
VERILATOR = TOOLS_DIR / 'oss-cad-suite' / 'bin' / 'verilator'
YOSYS = TOOLS_DIR / 'oss-cad-suite' / 'bin' / 'yosys'
OPENROAD = TOOLS_DIR / 'bin' / 'openroad'

EDITABLE_MAP = {
    pathlib.Path('code/data_offload.v'): 'data_offload',
    pathlib.Path('code/data_offload_fsm.v'): 'data_offload_fsm',
    pathlib.Path('code/data_offload_regmap.v'): 'data_offload_regmap',
    pathlib.Path('code/util_axis_fifo_asym.v'): 'util_axis_fifo_asym',
}
EDITABLES = set(EDITABLE_MAP.keys())

SYNTH_ORDER = [
    'ad_mem.v',
    'up_axi.v',
    'axi_register_slice.v',
    'sync_bits.v',
    'sync_data.v',
    'sync_event.v',
    'sync_gray.v',
    'util_axis_fifo_address_generator.v',
    'util_axis_fifo.v',
    'util_axis_fifo_asym.v',
    'data_offload_fsm.v',
    'data_offload_regmap.v',
    'data_offload.v',
    'data_offload_subsys.v',
]


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
        finish(result_path, 'FAIL', 'policy', f'Editable RTL {expected_mod} exceeds size limit')
    for inc in re.findall(r'`include\s+"([^"]+)"', re.sub(r'/\*.*?\*/|//[^\n]*', ' ', cand_text, flags=re.S)):
        finish(result_path, 'FAIL', 'policy', f'Unauthorized include directive in {expected_mod}: {inc}')
    clean = strip_comments(cand_text)
    escape_pats = [
        (r'\$(?:fopen|fclose|fread|fwrite|fdisplay|fscanf|system|finish|stop|readmemh|readmemb|writememh|writememb|dumpfile|dumpvars|value\$plusargs|test\$plusargs)\b', 'forbidden_systask'),
        (r'\b(?:force|release|bind|defparam)\b', 'procedural_force_or_bind'),
        (r'\b(?:import|export)\s*"DPI', 'dpi_escape'),
        (r'\$root\b|\b(?:tb_data_offload|dut|grader|oracle)\s*\.', 'hierarchical_harness_reference'),
        (r'`\s*(?:ifdef|ifndef|elsif)\s+(?:VERILATOR|SYNTHESIS|SIMULATION|__ICARUS__|VCS|QUESTA)\b', 'simulator_macro_divergence'),
        (r'#\s*[0-9]+', 'behavioral_delay_in_rtl'),
    ]
    for pat, label in escape_pats:
        if re.search(pat, clean, re.I):
            finish(result_path, 'FAIL', 'policy', f'Policy violation in {expected_mod}: {label}')
    if len(re.findall(rf'\bmodule\s+{expected_mod}\b', clean)) < 1:
        finish(result_path, 'FAIL', 'structural', f'Expected module declaration: {expected_mod}')


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
        with tempfile.TemporaryDirectory(prefix='case_24016_grade_') as td:
            work = pathlib.Path(td)
            shutil.copytree(PUB_DIR / 'code', work / 'code')
            for rel, txt in rtl_texts.items():
                (work / rel).write_text(txt, encoding='utf-8')
            shutil.copyfile(PRIV_DIR / 'tests' / 'tb_data_offload.sv', work / 'tb_data_offload.sv')

            env = {
                'PATH': f'{TOOLS_DIR}/oss-cad-suite/bin:{TOOLS_DIR}/bin:/usr/bin:/bin',
                'HOME': str(work),
                'TMPDIR': str(work),
            }

            # Stage 1: Three-Clock Dual-Channel Offload & Bypass Simulation (Verilator)
            cmd_vl = [
                str(VERILATOR), '--binary', '--timing', '--output-split-cfuncs', '0',
                '+1364-2005ext+v', '-Wno-fatal', f'-I{work}/code',
                '--Mdir', str(work / 'obj_vl'), '--top-module', 'tb_data_offload',
                *[str(work / 'code' / fn) for fn in SYNTH_ORDER],
                str(work / 'tb_data_offload.sv'),
            ]
            r_vc = subprocess.run(cmd_vl, cwd=work, env=env, capture_output=True, text=True, timeout=90)
            if r_vc.returncode != 0:
                finish(result_path, 'FAIL', 'compile', f'Verilator compile failed: {(r_vc.stdout + r_vc.stderr)[-1500:]}')

            r_vs = subprocess.run([str(work / 'obj_vl' / 'Vtb_data_offload'), f'+seed={args.seed}'], cwd=work, env=env, capture_output=True, text=True, timeout=90)
            vs_out = (r_vs.stdout + '\n' + r_vs.stderr).strip()
            if r_vs.returncode != 0 or f'PASS_DATA_OFFLOAD seed={args.seed}' not in vs_out or '%Error' in vs_out:
                finish(result_path, 'FAIL', 'functional', f'Three-clock data_offload simulation failed (seed={args.seed}): {vs_out[-1500:]}')

            # Stage 2: Nangate45 ASIC Synthesis (Yosys + ABC buffer/upsize)
            rv_cmds = '\n'.join(f'read_verilog -I{work}/code {work}/code/{fn}' for fn in SYNTH_ORDER)
            ys_script = f"""
{rv_cmds}
hierarchy -check -top data_offload_subsys
proc; opt; memory; opt; flatten; opt; techmap; opt
dfflibmap -liberty {LIB_DIR}/NangateOpenCellLibrary_typical.lib
abc -liberty {LIB_DIR}/NangateOpenCellLibrary_typical.lib -script "+strash; &get -n; &fraig -x; &put; scorr; dc2; dretime; strash; &get -n; &dch -f; &nf -D 800; &put; buffer -N 8; upsize -D 800; dnsize -D 800"
hilomap -hicell LOGIC1_X1 Z -locell LOGIC0_X1 Z
clean -purge
write_verilog -noattr {work}/subsys_ng45.v
"""
            r_ys = subprocess.run([str(YOSYS), '-s', '-'], input=ys_script, cwd=work, env=env, capture_output=True, text=True, timeout=120)
            if r_ys.returncode != 0 or not (work / 'subsys_ng45.v').is_file():
                finish(result_path, 'FAIL', 'synthesis', f'Yosys Nangate45 synthesis failed: {(r_ys.stdout + r_ys.stderr)[-1500:]}')

            net_txt = (work / 'subsys_ng45.v').read_text(encoding='utf-8')
            if re.search(r'\bDLH_X\d+\b|\bDLL_X\d+\b', net_txt):
                finish(result_path, 'FAIL', 'synthesis', 'Inferred latches forbidden in data_offload_subsys')

            # Stage 3: Nangate45 Three-Clock OpenSTA Signoff (exact published constraints)
            up_in = 'rx_axi_awvalid rx_axi_awaddr[*] rx_axi_awprot[*] rx_axi_wvalid rx_axi_wdata[*] rx_axi_wstrb[*] rx_axi_bready rx_axi_arvalid rx_axi_araddr[*] rx_axi_arprot[*] rx_axi_rready tx_axi_awvalid tx_axi_awaddr[*] tx_axi_awprot[*] tx_axi_wvalid tx_axi_wdata[*] tx_axi_wstrb[*] tx_axi_bready tx_axi_arvalid tx_axi_araddr[*] tx_axi_arprot[*] tx_axi_rready'
            up_out = 'rx_axi_awready rx_axi_wready rx_axi_bvalid rx_axi_bresp[*] rx_axi_arready rx_axi_rvalid rx_axi_rresp[*] rx_axi_rdata[*] tx_axi_awready tx_axi_wready tx_axi_bvalid tx_axi_bresp[*] tx_axi_arready tx_axi_rvalid tx_axi_rresp[*] tx_axi_rdata[*]'
            dev_in = 'rx_s_axis_valid rx_s_axis_data[*] rx_s_axis_last rx_s_axis_keep[*] rx_m_storage_axis_ready rx_wr_request_ready rx_wr_response_measured_length[*] rx_wr_response_eot rx_wr_overflow tx_m_axis_ready tx_s_storage_axis_valid tx_s_storage_axis_data[*] tx_s_storage_axis_last tx_s_storage_axis_keep[*] tx_rd_request_ready tx_rd_response_eot tx_rd_underflow'
            dev_out = 'rx_s_axis_ready rx_m_storage_axis_valid rx_m_storage_axis_data[*] rx_m_storage_axis_last rx_m_storage_axis_keep[*] rx_wr_request_enable rx_wr_request_valid rx_wr_request_length[*] tx_m_axis_valid tx_m_axis_data[*] tx_m_axis_last tx_m_axis_keep[*] tx_s_storage_axis_ready tx_rd_request_enable tx_rd_request_valid tx_rd_request_length[*]'
            sys_in = 'rx_m_axis_ready rx_s_storage_axis_valid rx_s_storage_axis_data[*] rx_s_storage_axis_last rx_s_storage_axis_keep[*] rx_rd_request_ready rx_rd_response_eot rx_rd_underflow tx_s_axis_valid tx_s_axis_data[*] tx_s_axis_last tx_s_axis_keep[*] tx_m_storage_axis_ready tx_wr_request_ready tx_wr_response_measured_length[*] tx_wr_response_eot tx_wr_overflow'
            sys_out = 'rx_m_axis_valid rx_m_axis_data[*] rx_m_axis_last rx_m_axis_keep[*] rx_s_storage_axis_ready rx_rd_request_enable rx_rd_request_valid rx_rd_request_length[*] tx_s_axis_ready tx_m_storage_axis_valid tx_m_storage_axis_data[*] tx_m_storage_axis_last tx_m_storage_axis_keep[*] tx_wr_request_enable tx_wr_request_valid tx_wr_request_length[*]'

            sta_tcl = f"""
read_lef {LIB_DIR}/NangateOpenCellLibrary.tech.lef
read_lef {LIB_DIR}/NangateOpenCellLibrary.macro.mod.lef
read_liberty {LIB_DIR}/NangateOpenCellLibrary_typical.lib
read_verilog {work}/subsys_ng45.v
link_design data_offload_subsys

create_clock -name up_clk  -period 2.00 [get_ports up_clk]
create_clock -name dev_clk -period 3.00 [get_ports dev_clk]
create_clock -name sys_clk -period 3.00 [get_ports sys_clk]
set_clock_groups -asynchronous -group {{up_clk}} -group {{dev_clk}} -group {{sys_clk}}

set_input_delay  -clock up_clk  -max 0.40 [get_ports {{{up_in}}}]
set_input_delay  -clock up_clk  -min 0.00 [get_ports {{{up_in}}}]
set_output_delay -clock up_clk  -max 0.40 [get_ports {{{up_out}}}]
set_output_delay -clock up_clk  -min 0.00 [get_ports {{{up_out}}}]

set_input_delay  -clock dev_clk -max 1.95 [get_ports {{{dev_in}}}]
set_input_delay  -clock dev_clk -min 0.00 [get_ports {{{dev_in}}}]
set_output_delay -clock dev_clk -max 1.20 [get_ports {{{dev_out}}}]
set_output_delay -clock dev_clk -min 0.00 [get_ports {{{dev_out}}}]

set_input_delay  -clock sys_clk -max 1.95 [get_ports {{{sys_in}}}]
set_input_delay  -clock sys_clk -min 0.00 [get_ports {{{sys_in}}}]
set_output_delay -clock sys_clk -max 1.20 [get_ports {{{sys_out}}}]
set_output_delay -clock sys_clk -min 0.00 [get_ports {{{sys_out}}}]

set_false_path -from [get_ports {{up_rstn dev_aresetn sys_aresetn rx_init_req rx_sync_ext rx_ddr_calib_done tx_init_req tx_sync_ext tx_ddr_calib_done}}]

report_worst_slack -max
report_worst_slack -min
report_tns -max
report_tns -min
report_checks -path_delay max -group_path_count 2 -digits 3
exit
"""
            r_sta = subprocess.run([str(OPENROAD), '-exit'], input=sta_tcl, cwd=work, env=env, capture_output=True, text=True, timeout=60)
            sta_out = r_sta.stdout + '\n' + r_sta.stderr
            if r_sta.returncode != 0 or '[ERROR' in sta_out or 'Error:' in sta_out:
                finish(result_path, 'FAIL', 'timing', f'OpenSTA failed: {sta_out[-1500:]}')

            m_wmax = re.search(r'worst slack max\s+(-?[0-9.]+)', sta_out)
            m_wmin = re.search(r'worst slack min\s+(-?[0-9.]+)', sta_out)
            m_tmax = re.search(r'tns max\s+(-?[0-9.]+)', sta_out)
            m_tmin = re.search(r'tns min\s+(-?[0-9.]+)', sta_out)
            if not (m_wmax and m_wmin and m_tmax):
                finish(result_path, 'FAIL', 'timing', f'OpenSTA missing slack summary: {sta_out[-1200:]}')

            wns_max, wns_min, tns_max = float(m_wmax.group(1)), float(m_wmin.group(1)), float(m_tmax.group(1))
            tns_min = float(m_tmin.group(1)) if m_tmin else 0.0
            if wns_max < -1e-4 or tns_max < -1e-4 or wns_min < -1e-4 or tns_min < -1e-4:
                finish(result_path, 'FAIL', 'timing', f'Nangate45 STA timing violation: WNS_setup={wns_max} ns, TNS_setup={tns_max} ns, WNS_hold={wns_min} ns\n{sta_out[-1400:]}')

            finish(result_path, 'PASS', 'timing', f'Three-clock data_offload + Nangate45 STA signoff passed (WNS_setup={wns_max:.3f}ns, WNS_hold={wns_min:.3f}ns, seed={args.seed})')
    except SystemExit:
        raise
    except Exception as exc:
        finish(result_path, 'ERROR', 'grader_exception', str(exc))


if __name__ == '__main__':
    main()
