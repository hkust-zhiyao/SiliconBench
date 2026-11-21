#!/usr/bin/env python3
"""Private isolated grader for case_24005 (multi-module bsg_async_fifo RDC + GLS glitch + multi-corner OpenSTA)."""
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
LIB_DIR = PUB_DIR / 'lib'
TOOLS_DIR = pathlib.Path(str(_sb_tools_dir()))
IVERILOG = TOOLS_DIR / 'oss-cad-suite' / 'bin' / 'iverilog'
VVP = TOOLS_DIR / 'oss-cad-suite' / 'bin' / 'vvp'
YOSYS = TOOLS_DIR / 'oss-cad-suite' / 'bin' / 'yosys'
OPENROAD = TOOLS_DIR / 'bin' / 'openroad'

EDITABLE_RTLS = [
    pathlib.Path('code/bsg_async_fifo.sv'),
    pathlib.Path('code/bsg_async_ptr_gray.sv'),
    pathlib.Path('code/bsg_mem_1r1w.sv'),
]
EDITABLE_SDC = pathlib.Path('constraints/bsg_async_fifo.sdc')
EDITABLES = set(EDITABLE_RTLS + [EDITABLE_SDC])


def finish(result_path: pathlib.Path, verdict: str, stage: str, detail: str):
    payload = {'verdict': verdict, 'stage': stage, 'detail': detail}
    result_path.parent.mkdir(parents=True, exist_ok=True)
    result_path.write_text(json.dumps(payload, indent=2) + '\n', encoding='utf-8')
    print(json.dumps(payload))
    raise SystemExit(0 if verdict == 'PASS' else 2 if verdict == 'ERROR' else 1)


def sha256_bytes(p: pathlib.Path) -> str:
    return hashlib.sha256(p.read_bytes()).hexdigest()


def strip_sv_comments(text: str) -> str:
    text = re.sub(r'(?is)//\s*pragma\s+translate_off.*?//\s*pragma\s+translate_on', '', text)
    text = re.sub(r'/\*.*?\*/|//[^\n]*|"(?:\\.|[^"\\])*"', ' ', text, flags=re.S)
    return text


def strip_tcl_comments(text: str) -> str:
    lines = []
    for raw in text.splitlines():
        s = raw.strip()
        if s.startswith('#'):
            continue
        raw = re.sub(r';\s*#.*$', ';', raw)
        lines.append(raw)
    return '\n'.join(lines)


def screen_rtl(cand_text: str, expected_mod: str, result_path: pathlib.Path):
    if len(cand_text.encode('utf-8')) > 250_000:
        finish(result_path, 'FAIL', 'policy', f'Editable RTL {expected_mod} exceeds size limit')
    # Strip upstream BSG_HIDE_FROM_SYNTHESIS debug blocks before policy screening so untouched upstream assertions in bsg_mem_1r1w pass cleanly
    cand_no_dbg = re.sub(r'(?is)`ifndef\s+BSG_HIDE_FROM_SYNTHESIS.*?`endif', ' ', cand_text)
    cand_clean = strip_sv_comments(cand_no_dbg)
    escape_pats = [
        (r'\$(?:fopen|fclose|fread|fwrite|fdisplay|fscanf|system|finish|stop|readmemh|readmemb|writememh|writememb|dumpfile|dumpvars|value\$plusargs|test\$plusargs)\b', 'forbidden_systask'),
        (r'\b(?:force|release|bind|defparam)\b', 'procedural_force_or_bind'),
        (r'\b(?:import|export)\s*"DPI', 'dpi_escape'),
        (r'\$root\b|\b(?:tb|tb_edge|tb_gls|dut_split_nogate|dut_split_gate|dut_all_ctrl|dut_lg1|dut_gls|grader|oracle)\s*\.', 'hierarchical_harness_reference'),
        (r'`\s*(?:ifdef|ifndef|elsif)\s+(?:VERILATOR|SYNTHESIS|SIMULATION|__ICARUS__|VCS|QUESTA)\b', 'simulator_macro_divergence'),
        (r'#\s*[0-9]+', 'behavioral_delay_in_rtl'),
    ]
    for pat, label in escape_pats:
        if re.search(pat, cand_clean, re.I):
            finish(result_path, 'FAIL', 'policy', f'Policy violation in {expected_mod}: {label}')

    for inc in re.findall(r'`include\s+"([^"]+)"', strip_sv_comments(cand_text)):
        if inc != 'bsg_defines.sv':
            finish(result_path, 'FAIL', 'policy', f'Unauthorized include directive in {expected_mod}: {inc}')

    if len(re.findall(rf'\bmodule\s+{expected_mod}\b', strip_sv_comments(cand_text))) < 1:
        finish(result_path, 'FAIL', 'structural', f'Expected module declaration: {expected_mod}')


def screen_sdc_policy(sdc_text: str, result_path: pathlib.Path) -> str:
    if len(sdc_text.encode('utf-8')) > 64_000:
        finish(result_path, 'FAIL', 'policy', 'Editable SDC exceeds size limit')
    clean = strip_tcl_comments(sdc_text)
    for bad, label in [
        (r'(?m)(?:^|[;\[])\s*(?:exec|open|socket|source|load|eval|interp|proc|rename|uplevel|file)\b', 'forbidden_tcl_command'),
        (r'\b(?:private/gold|private/tests|private/grader|/proc/|/dev/|/home/)\S*', 'forbidden_path_reference'),
        (r'\b(?:set_timing_derate|read_liberty|read_verilog|link_design)\b', 'forbidden_sta_override'),
    ]:
        if re.search(bad, clean):
            finish(result_path, 'FAIL', 'policy', f'Policy violation in candidate SDC: {label}')
    return clean


def audit_sdc_semantics(sdc_clean: str, result_path: pathlib.Path):
    if re.search(r'\bset_clock_groups\b[^\n;]*-asynchronous\b', sdc_clean):
        finish(result_path, 'FAIL', 'timing', 'set_clock_groups -asynchronous is forbidden; bound CDC crossings with set_max_delay')

    for m in re.finditer(r'\bset_false_path\b([^\n;]*)', sdc_clean):
        args = m.group(1)
        if '-hold' in args:
            continue
        if ('mem' in args or 'synth' in args or 'MSYNC_1r1w' in args) and ('r_data_o' in args) and ('get_clocks' not in args) and ('bapg' not in args) and ('blss' not in args):
            continue
        finish(result_path, 'FAIL', 'timing', f'Unbounded non-hold set_false_path forbidden on clock/Gray-pointer paths: set_false_path{args.strip()}')

    max_delays = [float(v) for v in re.findall(r'\bset_max_delay\s+(?:-[a-z_]+\s+)*([0-9]+(?:\.[0-9]+)?)', sdc_clean)]
    if len(max_delays) < 1:
        finish(result_path, 'FAIL', 'timing', 'SDC must bound CDC crossings via set_max_delay')
    for val in max_delays:
        if val <= 0.0 or val > 2.5001:
            finish(result_path, 'FAIL', 'timing', f'CDC set_max_delay {val} ns must be > 0 and <= min(T_w, T_r) = 2.50 ns')

    unc_setup = [float(x) for x in re.findall(r'\bset_clock_uncertainty\b[^\n;]*-setup\s+([0-9]+(?:\.[0-9]+)?)', sdc_clean)]
    unc_hold = [float(x) for x in re.findall(r'\bset_clock_uncertainty\b[^\n;]*-hold\s+([0-9]+(?:\.[0-9]+)?)', sdc_clean)]
    unc_both = [float(x) for x in re.findall(r'\bset_clock_uncertainty\s+([0-9]+(?:\.[0-9]+)?)', sdc_clean)]
    if not ((unc_setup and min(unc_setup) >= 0.1199 and unc_hold and min(unc_hold) >= 0.0299) or (unc_both and min(unc_both) >= 0.1199)):
        finish(result_path, 'FAIL', 'timing', 'SDC must specify clock uncertainty >= 0.12 ns (-setup) and >= 0.03 ns (-hold)')

    for req_port in ('w_enq_i', 'w_data_i', 'w_full_o', 'r_deq_i', 'r_valid_o', 'r_data_o'):
        if req_port not in sdc_clean:
            finish(result_path, 'FAIL', 'timing', f'SDC missing I/O delay constraint on port {req_port}')
    if len(re.findall(r'\bset_input_delay\b[^\n;]*-max\b', sdc_clean)) < 2 or len(re.findall(r'\bset_input_delay\b[^\n;]*-min\b', sdc_clean)) < 2:
        finish(result_path, 'FAIL', 'timing', 'SDC must specify both -max and -min set_input_delay for w_clk and r_clk domains')
    if len(re.findall(r'\bset_output_delay\b[^\n;]*-max\b', sdc_clean)) < 2 or len(re.findall(r'\bset_output_delay\b[^\n;]*-min\b', sdc_clean)) < 2:
        finish(result_path, 'FAIL', 'timing', 'SDC must specify both -max and -min set_output_delay for w_clk and r_clk domains')


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

    mod_map = {
        pathlib.Path('code/bsg_async_fifo.sv'): 'bsg_async_fifo',
        pathlib.Path('code/bsg_async_ptr_gray.sv'): 'bsg_async_ptr_gray',
        pathlib.Path('code/bsg_mem_1r1w.sv'): 'bsg_mem_1r1w',
    }
    rtl_texts = {}
    for rel, mname in mod_map.items():
        txt = (cand_root / rel).read_text(encoding='utf-8', errors='replace')
        screen_rtl(txt, mname, result_path)
        rtl_texts[rel] = txt

    sdc_text = (cand_root / EDITABLE_SDC).read_text(encoding='utf-8', errors='replace')
    sdc_clean = screen_sdc_policy(sdc_text, result_path)

    try:
        with tempfile.TemporaryDirectory(prefix='case_24005_grade_') as td:
            work = pathlib.Path(td)
            shutil.copytree(PUB_DIR / 'code', work / 'code')
            for rel, txt in rtl_texts.items():
                (work / rel).write_text(txt, encoding='utf-8')
            (work / 'dut.sdc').write_text(sdc_text, encoding='utf-8')
            for tbf in ('tb_rtl.sv', 'tb_edge.sv', 'tb_gls.sv', 'delay_cells.v'):
                shutil.copyfile(PRIV_DIR / 'tests' / tbf, work / tbf)

            env = {
                'PATH': f'{TOOLS_DIR}/oss-cad-suite/bin:{TOOLS_DIR}/bin:/usr/bin:/bin',
                'HOME': str(work),
                'TMPDIR': str(work),
            }

            # Stage 1A: Core 4-state RTL simulation (unilateral/bilateral RDC + segmented gating + stress)
            cmd_iv = [
                str(IVERILOG), '-g2012', f'-I{work}/code', '-s', 'tb', '-o', str(work / 'rtl.vvp'),
                str(work / 'code' / 'bsg_and.sv'),
                str(work / 'code' / 'bsg_mem_1r1w_synth.sv'),
                str(work / 'code' / 'bsg_mem_1r1w.sv'),
                str(work / 'code' / 'bsg_launch_sync_sync.sv'),
                str(work / 'code' / 'bsg_async_ptr_gray.sv'),
                str(work / 'code' / 'bsg_async_fifo.sv'),
                str(work / 'tb_rtl.sv'),
            ]
            r_iv = subprocess.run(cmd_iv, cwd=work, env=env, capture_output=True, text=True, timeout=60)
            if r_iv.returncode != 0:
                finish(result_path, 'FAIL', 'compile', f'Icarus RTL compile failed: {(r_iv.stdout + r_iv.stderr)[-1500:]}')

            r_sim = subprocess.run([str(VVP), str(work / 'rtl.vvp'), f'+seed={args.seed}'], cwd=work, env=env, capture_output=True, text=True, timeout=90)
            sim_out = (r_sim.stdout + '\n' + r_sim.stderr).strip()
            if r_sim.returncode != 0 or f'PASS_RTL seed={args.seed}' not in sim_out or 'ERROR:' in r_sim.stdout:
                finish(result_path, 'FAIL', 'functional', f'RTL functional check failed (seed={args.seed}): {sim_out[-1500:]}')

            # Stage 1B: Edge parameterizations (lg_size_p==1 and control_width_p==width_p)
            cmd_edge = [
                str(IVERILOG), '-g2012', f'-I{work}/code', '-s', 'tb_edge', '-o', str(work / 'edge.vvp'),
                str(work / 'code' / 'bsg_and.sv'),
                str(work / 'code' / 'bsg_mem_1r1w_synth.sv'),
                str(work / 'code' / 'bsg_mem_1r1w.sv'),
                str(work / 'code' / 'bsg_launch_sync_sync.sv'),
                str(work / 'code' / 'bsg_async_ptr_gray.sv'),
                str(work / 'code' / 'bsg_async_fifo.sv'),
                str(work / 'tb_edge.sv'),
            ]
            r_ec = subprocess.run(cmd_edge, cwd=work, env=env, capture_output=True, text=True, timeout=60)
            if r_ec.returncode != 0:
                finish(result_path, 'FAIL', 'functional', f'Edge parameterization (lg_size_p=1 / control_width_p=width_p) elaboration failed: {(r_ec.stdout + r_ec.stderr)[-1200:]}')
            r_es = subprocess.run([str(VVP), str(work / 'edge.vvp')], cwd=work, env=env, capture_output=True, text=True, timeout=60)
            if r_es.returncode != 0 or 'PASS_EDGE' not in (r_es.stdout + r_es.stderr) or 'ERROR:' in r_es.stdout:
                finish(result_path, 'FAIL', 'functional', f'Edge parameterization simulation failed: {(r_es.stdout + r_es.stderr)[-1200:]}')

            # Stage 2A: Yosys simple-gate synthesis + skewed-delay gate-level glitch check
            ys_gls = f'''
plugin -i slang
read_slang --keep-hierarchy -DSYNTHESIS -DYOSYS -I {work}/code \\
    {work}/code/bsg_and.sv \\
    {work}/code/bsg_mem_1r1w_synth.sv \\
    {work}/code/bsg_mem_1r1w.sv \\
    {work}/code/bsg_launch_sync_sync.sv \\
    {work}/code/bsg_async_ptr_gray.sv \\
    {work}/code/bsg_async_fifo.sv \\
    --top bsg_async_fifo -G lg_size_p=3 -G width_p=16 -G control_width_p=4 -G and_data_with_valid_p=1
hierarchy -check -top bsg_async_fifo
proc; opt; memory; opt; techmap; opt
abc -g AND,OR,XOR,MUX
clean -purge
write_verilog -noattr {work}/fifo_gls.v
'''
            r_syn_gls = subprocess.run([str(YOSYS), '-s', '-'], input=ys_gls, cwd=work, env=env, capture_output=True, text=True, timeout=120)
            if r_syn_gls.returncode != 0 or not (work / 'fifo_gls.v').is_file():
                finish(result_path, 'FAIL', 'synthesis', f'Yosys GLS synthesis failed: {(r_syn_gls.stdout + r_syn_gls.stderr)[-1500:]}')

            gls_net = (work / 'fifo_gls.v').read_text(encoding='utf-8')
            if re.search(r'\b\$_DLATCH_[NP]_\b', gls_net):
                finish(result_path, 'FAIL', 'synthesis', 'Inferred latches forbidden in bsg_async_fifo')

            cmd_gls = [
                str(IVERILOG), '-g2012', '-s', 'tb_gls', '-o', str(work / 'gls.vvp'),
                str(work / 'delay_cells.v'),
                str(work / 'fifo_gls.v'),
                str(work / 'tb_gls.sv'),
            ]
            r_gls_c = subprocess.run(cmd_gls, cwd=work, env=env, capture_output=True, text=True, timeout=60)
            if r_gls_c.returncode != 0:
                finish(result_path, 'FAIL', 'synthesis', f'GLS compile failed: {(r_gls_c.stdout + r_gls_c.stderr)[-1500:]}')

            r_gls = subprocess.run([str(VVP), str(work / 'gls.vvp'), f'+seed={args.seed}'], cwd=work, env=env, capture_output=True, text=True, timeout=120)
            gls_out = (r_gls.stdout + '\n' + r_gls.stderr).strip()
            if r_gls.returncode != 0 or f'PASS_GLS seed={args.seed}' not in gls_out:
                finish(result_path, 'FAIL', 'functional', f'Gate-level skewed-delay glitch test failed (seed={args.seed}): {gls_out[-1500:]}')

            # Stage 2B: Verify bsg_and control isolation when and_data_with_valid_p==0
            ys_nogate = f'''
plugin -i slang
read_slang --keep-hierarchy -DSYNTHESIS -DYOSYS -I {work}/code \\
    {work}/code/bsg_and.sv \\
    {work}/code/bsg_mem_1r1w_synth.sv \\
    {work}/code/bsg_mem_1r1w.sv \\
    {work}/code/bsg_launch_sync_sync.sv \\
    {work}/code/bsg_async_ptr_gray.sv \\
    {work}/code/bsg_async_fifo.sv \\
    --top bsg_async_fifo -G lg_size_p=3 -G width_p=16 -G control_width_p=4 -G and_data_with_valid_p=0
hierarchy -check -top bsg_async_fifo
proc; opt; clean -purge
write_verilog -noattr {work}/fifo_nogate.v
'''
            r_ng = subprocess.run([str(YOSYS), '-s', '-'], input=ys_nogate, cwd=work, env=env, capture_output=True, text=True, timeout=90)
            if r_ng.returncode != 0 or 'bsg_and' not in (work / 'fifo_nogate.v').read_text(encoding='utf-8'):
                finish(result_path, 'FAIL', 'synthesis', 'Control MSBs must be gated via bsg_and even when and_data_with_valid_p=0')

            # Stage 3: Nangate45 synthesis + Slow/Fast Multi-Corner OpenSTA Signoff
            ys_sta = f'''
plugin -i slang
read_slang --keep-hierarchy -DSYNTHESIS -DYOSYS -I {work}/code \\
    {work}/code/bsg_and.sv \\
    {work}/code/bsg_mem_1r1w_synth.sv \\
    {work}/code/bsg_mem_1r1w.sv \\
    {work}/code/bsg_launch_sync_sync.sv \\
    {work}/code/bsg_async_ptr_gray.sv \\
    {work}/code/bsg_async_fifo.sv \\
    --top bsg_async_fifo -G lg_size_p=3 -G width_p=16 -G control_width_p=4 -G and_data_with_valid_p=1
hierarchy -check -top bsg_async_fifo
proc; opt; memory; opt; techmap; opt
dfflibmap -liberty {LIB_DIR}/NangateOpenCellLibrary_typical.lib
abc -liberty {LIB_DIR}/NangateOpenCellLibrary_typical.lib
autoname
clean -purge
write_verilog -noattr {work}/fifo_nangate45.v
'''
            r_syn = subprocess.run([str(YOSYS), '-s', '-'], input=ys_sta, cwd=work, env=env, capture_output=True, text=True, timeout=120)
            if r_syn.returncode != 0 or not (work / 'fifo_nangate45.v').is_file():
                finish(result_path, 'FAIL', 'synthesis', f'Yosys Nangate45 synthesis failed: {(r_syn.stdout + r_syn.stderr)[-1500:]}')

            audit_sdc_semantics(sdc_clean, result_path)

            for corner_name, late_d, early_d in [('slow', 1.25, 1.00), ('fast', 1.00, 0.75)]:
                sta_tcl = f'''
read_lef {LIB_DIR}/NangateOpenCellLibrary.tech.lef
read_lef {LIB_DIR}/NangateOpenCellLibrary.macro.mod.lef
read_liberty {LIB_DIR}/NangateOpenCellLibrary_typical.lib
read_verilog {work}/fifo_nangate45.v
link_design bsg_async_fifo
read_sdc {work}/dut.sdc
set_timing_derate -late {late_d}
set_timing_derate -early {early_d}

report_worst_slack -max
report_worst_slack -min
report_tns -max
report_tns -min

foreach p {{w_clk_i r_clk_i}} {{
  set clk_found ""
  foreach c [all_clocks] {{
    foreach src [get_property $c sources] {{
      if {{[get_full_name $src] eq $p}} {{
        set clk_found $c
      }}
    }}
  }}
  if {{$clk_found eq ""}} {{
    puts "MISSING_PRIMARY_CLK:$p"
  }} else {{
    puts "PRIMARY_CLK:$p:[get_property $clk_found period]"
  }}
}}

set blss_paths [find_timing_paths -from [get_cells -hierarchical *blss/iclk_i_DFF*] -to [get_cells -hierarchical *blss/oclk_i_DFF*] -path_delay max -group_count 32]
puts "BLSS_GRAY_CNT:[llength $blss_paths]"
foreach tp $blss_paths {{
  puts "BLSS_GRAY_SLACK:[get_property $tp slack]"
}}
set blss_hold_paths [find_timing_paths -from [get_cells -hierarchical *blss/iclk_i_DFF*] -to [get_cells -hierarchical *blss/oclk_i_DFF*] -path_delay min -group_count 32]
puts "BLSS_GRAY_HOLD_CNT:[llength $blss_hold_paths]"

set sync_w_cnt [llength [find_timing_paths -from [get_ports w_enq_i] -path_delay max]]
set sync_r_cnt [llength [find_timing_paths -from [get_ports r_deq_i] -path_delay max]]
puts "SYNC_IO_CNT:$sync_w_cnt:$sync_r_cnt"
exit
'''
                r_sta = subprocess.run([str(OPENROAD), '-exit'], input=sta_tcl, cwd=work, env=env, capture_output=True, text=True, timeout=60)
                sta_out = r_sta.stdout + '\n' + r_sta.stderr
                if r_sta.returncode != 0 or '[ERROR' in sta_out or 'Error:' in sta_out:
                    finish(result_path, 'FAIL', 'timing', f'OpenSTA ({corner_name}) error: {sta_out[-1500:]}')

                if 'MISSING_PRIMARY_CLK:' in sta_out:
                    finish(result_path, 'FAIL', 'timing', f'OpenSTA ({corner_name}) missing primary clock definition')

                m_wc = re.search(r'PRIMARY_CLK:w_clk_i:([0-9.]+)', sta_out)
                m_rc = re.search(r'PRIMARY_CLK:r_clk_i:([0-9.]+)', sta_out)
                if not m_wc or abs(float(m_wc.group(1)) - 4.0) > 0.02:
                    finish(result_path, 'FAIL', 'timing', f'w_clk_i period must be 4.0 ns')
                if not m_rc or abs(float(m_rc.group(1)) - 2.5) > 0.02:
                    finish(result_path, 'FAIL', 'timing', f'r_clk_i period must be 2.5 ns')

                m_wmax = re.search(r'worst slack max\s+(-?[0-9.]+)', sta_out)
                m_wmin = re.search(r'worst slack min\s+(-?[0-9.]+)', sta_out)
                m_tmax = re.search(r'tns max\s+(-?[0-9.]+)', sta_out)
                m_tmin = re.search(r'tns min\s+(-?[0-9.]+)', sta_out)
                if not (m_wmax and m_wmin and m_tmax):
                    finish(result_path, 'FAIL', 'timing', f'OpenSTA ({corner_name}) missing slack summary')
                wns_max, wns_min, tns_max = float(m_wmax.group(1)), float(m_wmin.group(1)), float(m_tmax.group(1))
                tns_min = float(m_tmin.group(1)) if m_tmin else 0.0
                if wns_max < -1e-4 or tns_max < -1e-4 or wns_min < -1e-4 or tns_min < -1e-4:
                    finish(result_path, 'FAIL', 'timing', f'OpenSTA ({corner_name}) timing violation: WNS_max={wns_max}, TNS_max={tns_max}, WNS_min={wns_min}, TNS_min={tns_min}')

                mc = re.search(r'BLSS_GRAY_CNT:(\d+)', sta_out)
                if not mc or int(mc.group(1)) < 8:
                    finish(result_path, 'FAIL', 'timing', f'OpenSTA ({corner_name}) Gray pointer synchronizers unconstrained (found {mc.group(1) if mc else 0} paths, expected >= 8)')
                for slk_s in re.findall(r'BLSS_GRAY_SLACK:([-+0-9.eE]+)', sta_out):
                    if float(slk_s) < -1e-12:
                        finish(result_path, 'FAIL', 'timing', f'OpenSTA ({corner_name}) CDC slack={slk_s} < 0')

                msync = re.search(r'SYNC_IO_CNT:(\d+):(\d+)', sta_out)
                if not msync or int(msync.group(1)) < 1 or int(msync.group(2)) < 1:
                    finish(result_path, 'FAIL', 'timing', f'OpenSTA ({corner_name}) synchronous I/O paths missing or false-pathed')

            finish(result_path, 'PASS', 'timing', f'Unilateral/bilateral RDC + GLS glitch + Slow/Fast OpenSTA passed (seed={args.seed})')
    except SystemExit:
        raise
    except Exception as exc:
        finish(result_path, 'ERROR', 'grader_exception', str(exc))


if __name__ == '__main__':
    main()
