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
    pathlib.Path('code/dmac_sg.v'): 'dmac_sg',
    pathlib.Path('code/data_mover.v'): 'data_mover',
    pathlib.Path('code/request_arb.v'): 'request_arb',
    pathlib.Path('code/axi_dmac_burst_memory.v'): 'axi_dmac_burst_memory',
}
EDITABLES = set(EDITABLE_MAP.keys())

SYNTH_ORDER = [
    'ad_mem.v',
    'ad_mem_asym.v',
    'sync_bits.v',
    'sync_gray.v',
    'sync_event.v',
    'util_axis_fifo_address_generator.v',
    'util_axis_fifo.v',
    'splitter.v',
    'address_generator.v',
    'request_generator.v',
    'response_handler.v',
    'axi_dmac_response_manager.v',
    'axi_dmac_resize_src.v',
    'axi_dmac_resize_dest.v',
    'axi_register_slice.v',
    'axi_dmac_ext_sync.v',
    'data_mover.v',
    'src_axi_stream.v',
    'src_axi_mm.v',
    'src_fifo_inf.v',
    'dest_axi_mm.v',
    'dest_axi_stream.v',
    'dest_fifo_inf.v',
    'axi_dmac_burst_memory.v',
    'request_arb.v',
    'dmac_sg.v',
    'dmac_sg_cluster.v',
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
        if inc not in ('inc_id.vh', 'resp.vh'):
            finish(result_path, 'FAIL', 'policy', f'Unauthorized include directive in {expected_mod}: {inc}')
    clean = strip_comments(cand_text)
    escape_pats = [
        (r'\$(?:fopen|fclose|fread|fwrite|fdisplay|fscanf|system|finish|stop|readmemh|readmemb|writememh|writememb|dumpfile|dumpvars|value\$plusargs|test\$plusargs)\b', 'forbidden_systask'),
        (r'\b(?:force|release|bind|defparam)\b', 'procedural_force_or_bind'),
        (r'\b(?:import|export)\s*"DPI', 'dpi_escape'),
        (r'\$root\b|\b(?:tb_sg_dmac|dut|grader|oracle)\s*\.', 'hierarchical_harness_reference'),
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
        with tempfile.TemporaryDirectory(prefix='case_24010_grade_') as td:
            work = pathlib.Path(td)
            shutil.copytree(PUB_DIR / 'code', work / 'code')
            for rel, txt in rtl_texts.items():
                (work / rel).write_text(txt, encoding='utf-8')
            shutil.copyfile(PRIV_DIR / 'tests' / 'tb_sg_dmac.sv', work / 'tb_sg_dmac.sv')

            env = {
                'PATH': f'{TOOLS_DIR}/oss-cad-suite/bin:{TOOLS_DIR}/bin:/usr/bin:/bin',
                'HOME': str(work),
                'TMPDIR': str(work),
            }

            # Stage 1: Multi-Clock Protocol & Corner Stress Simulation (Verilator)
            cmd_vl = [
                str(VERILATOR), '--binary', '--timing', '+1364-2005ext+v', '-Wno-fatal', f'-I{work}/code',
                '--Mdir', str(work / 'obj_vl'), '--top-module', 'tb_sg_dmac',
                *[str(work / 'code' / fn) for fn in SYNTH_ORDER],
                str(work / 'tb_sg_dmac.sv'),
            ]
            r_vc = subprocess.run(cmd_vl, cwd=work, env=env, capture_output=True, text=True, timeout=90)
            if r_vc.returncode != 0:
                finish(result_path, 'FAIL', 'compile', f'Verilator compile failed: {(r_vc.stdout + r_vc.stderr)[-1500:]}')

            r_vs = subprocess.run([str(work / 'obj_vl' / 'Vtb_sg_dmac'), f'+seed={args.seed}'], cwd=work, env=env, capture_output=True, text=True, timeout=90)
            vs_out = (r_vs.stdout + '\n' + r_vs.stderr).strip()
            if r_vs.returncode != 0 or f'PASS_SG_DMAC seed={args.seed}' not in vs_out or '%Error' in vs_out:
                finish(result_path, 'FAIL', 'functional', f'Multi-clock SG DMA protocol simulation failed (seed={args.seed}): {vs_out[-1500:]}')

            # Stage 2: Nangate45 ASIC Synthesis (Yosys + ABC buffer/upsize)
            rv_cmds = '\n'.join(f'read_verilog -I{work}/code {work}/code/{fn}' for fn in SYNTH_ORDER)
            ys_script = f"""
{rv_cmds}
hierarchy -check -top dmac_sg_cluster
proc; opt; memory; opt; flatten; opt; techmap; opt
dfflibmap -liberty {LIB_DIR}/NangateOpenCellLibrary_typical.lib
abc -liberty {LIB_DIR}/NangateOpenCellLibrary_typical.lib -script "+strash; &get -n; &fraig -x; &put; scorr; dc2; dretime; strash; &get -n; &dch -f; &nf -D 800; &put; buffer -N 8; upsize -D 800; dnsize -D 800"
hilomap -hicell LOGIC1_X1 Z -locell LOGIC0_X1 Z
clean -purge
write_verilog -noattr {work}/cluster_ng45.v
"""
            r_ys = subprocess.run([str(YOSYS), '-s', '-'], input=ys_script, cwd=work, env=env, capture_output=True, text=True, timeout=120)
            if r_ys.returncode != 0 or not (work / 'cluster_ng45.v').is_file():
                finish(result_path, 'FAIL', 'synthesis', f'Yosys Nangate45 synthesis failed: {(r_ys.stdout + r_ys.stderr)[-1500:]}')
            net_txt = (work / 'cluster_ng45.v').read_text(encoding='utf-8')
            if re.search(r'\bDLH_X\d+\b|\bDLL_X\d+\b', net_txt):
                finish(result_path, 'FAIL', 'synthesis', 'Inferred latches forbidden in dmac_sg_cluster')

            # Stage 3: Nangate45 Multi-Clock OpenSTA Signoff (exact published constraints!)
            sta_tcl = f"""
read_lef {LIB_DIR}/NangateOpenCellLibrary.tech.lef
read_lef {LIB_DIR}/NangateOpenCellLibrary.macro.mod.lef
read_liberty {LIB_DIR}/NangateOpenCellLibrary_typical.lib
read_verilog {work}/cluster_ng45.v
link_design dmac_sg_cluster

create_clock -name req_clk -period 1.85 [get_ports req_clk]
create_clock -name sg_clk  -period 1.85 [get_ports m_sg_axi_aclk]
create_clock -name src_clk -period 1.40 [get_ports s_axis_aclk]
create_clock -name dst_clk -period 2.15 [get_ports m_dest_axi_aclk]
set_clock_groups -asynchronous -group {{req_clk}} -group {{sg_clk}} -group {{src_clk}} -group {{dst_clk}}

set_input_delay  -clock src_clk -max 0.85 [get_ports {{s_axis_valid s_axis_data[*] s_axis_last s_axis_user[*]}}]
set_input_delay  -clock src_clk -min 0.05 [get_ports {{s_axis_valid s_axis_data[*] s_axis_last s_axis_user[*]}}]
set_output_delay -clock src_clk -max 0.85 [get_ports {{s_axis_ready s_axis_xfer_req}}]
set_output_delay -clock src_clk -min 0.00 [get_ports {{s_axis_ready s_axis_xfer_req}}]

set_input_delay  -clock dst_clk -max 1.45 [get_ports {{m_axi_awready m_axi_wready m_axi_bvalid m_axi_bresp[*]}}]
set_input_delay  -clock dst_clk -min 0.05 [get_ports {{m_axi_awready m_axi_wready m_axi_bvalid m_axi_bresp[*]}}]
set_output_delay -clock dst_clk -max 1.45 [get_ports {{m_axi_awvalid m_axi_awaddr[*] m_axi_awlen[*] m_axi_awsize[*] m_axi_awburst[*] m_axi_wvalid m_axi_wdata[*] m_axi_wstrb[*] m_axi_wlast m_axi_bready}}]
set_output_delay -clock dst_clk -min 0.00 [get_ports {{m_axi_awvalid m_axi_awaddr[*] m_axi_awlen[*] m_axi_awsize[*] m_axi_awburst[*] m_axi_wvalid m_axi_wdata[*] m_axi_wstrb[*] m_axi_wlast m_axi_bready}}]

set_input_delay  -clock sg_clk  -max 0.60 [get_ports {{m_sg_axi_arready m_sg_axi_rdata[*] m_sg_axi_rlast m_sg_axi_rvalid m_sg_axi_rresp[*]}}]
set_input_delay  -clock sg_clk  -min 0.05 [get_ports {{m_sg_axi_arready m_sg_axi_rdata[*] m_sg_axi_rlast m_sg_axi_rvalid m_sg_axi_rresp[*]}}]
set_output_delay -clock sg_clk  -max 0.60 [get_ports {{m_sg_axi_arvalid m_sg_axi_araddr[*] m_sg_axi_arlen[*] m_sg_axi_arsize[*] m_sg_axi_arburst[*] m_sg_axi_rready}}]
set_output_delay -clock sg_clk  -min 0.00 [get_ports {{m_sg_axi_arvalid m_sg_axi_araddr[*] m_sg_axi_arlen[*] m_sg_axi_arsize[*] m_sg_axi_arburst[*] m_sg_axi_rready}}]

set_false_path -from [get_ports {{req_resetn m_sg_axi_aresetn s_axis_aresetn m_dest_axi_aresetn req_enable sg_enable src_enable dest_enable}}]

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

            finish(result_path, 'PASS', 'timing', f'Multi-clock SG DMA protocol + Nangate45 STA signoff passed (WNS_setup={wns_max:.3f}ns, WNS_hold={wns_min:.3f}ns, seed={args.seed})')
    except SystemExit:
        raise
    except Exception as exc:
        finish(result_path, 'ERROR', 'grader_exception', str(exc))


if __name__ == '__main__':
    main()
