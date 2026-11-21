#!/usr/bin/env python3
"""Private multi-stage grader for case_6012 (veer_ifu_aln_bp_top)."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import pathlib
import re
import resource
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


resource.setrlimit(resource.RLIMIT_CORE, (0, 0))

OSS_CAD_BIN = pathlib.Path(f"{_sb_tools_dir()}/oss-cad-suite/bin")
OPENROAD_BIN = pathlib.Path(f"{_sb_tools_dir()}/bin/openroad")

READONLY_CODE_FILES = (
    'LICENSE',
    'common_defines.vh',
    'global.h',
    'veer_types.sv',
    'beh_lib.sv',
    'veer_ifu_aln_bp_top.sv',
)

FORBIDDEN_RTL_PATTERNS = [
    r'\$finish\b',
    r'\$fatal\b',
    r'\$stop\b',
    r'\$system\b',
    r'\$readmem[bh]\b',
    r'\$writemem[bh]\b',
    r'\$fopen\b',
    r'`include\s+"[^"]*\.\.',
    r'`include\s+"/',
    r'\bforce\b',
    r'\brelease\b',
    r'\balways_latch\b',
    r'\bdpi\b',
]

EXPECTED_IN_PORTS = {
    "rst_l", "scan_mode", "clk_override",
    "dec_ib3_valid_d", "dec_ib2_valid_d", "dec_ib0_valid_eff_d", "dec_ib1_valid_eff_d",
    "exu_flush_final", "dec_tlu_flush_err_wb", "dec_tlu_flush_noredir_wb",
    "dec_tlu_dbg_halted", "dec_tlu_pmu_fw_halted", "exu_flush_path_final", "exu_flush_upper_e2",
    "dec_tlu_mrac_ff", "dec_tlu_bpred_disable", "dec_tlu_core_ecc_disable",
    "ic_hit_f2", "ic_crit_wd_rdy", "ic_write_stall", "ic_dma_active", "dma_iccm_stall_any",
    "ifu_ic_mb_empty", "ifu_fb_consume1_ext_nc", "ic_fetch_val_f2", "ic_data_f2",
    "ic_access_fault_f2", "ic_rd_parity_final_err", "iccm_rd_ecc_single_err",
    "iccm_rd_ecc_double_err", "ic_error_f2", "ifu_icache_fetch_f2",
    "exu_mp_pkt", "exu_mp_eghr", "dec_tlu_br0_wb_pkt", "dec_tlu_br1_wb_pkt",
    "dec_tlu_flush_lower_wb", "dec_tlu_flush_leak_one_wb", "exu_rets_e1_pkt", "exu_rets_e4_pkt",
    "exu_i0_br_ret_e4", "exu_i1_br_ret_e4", "exu_i0_br_call_e4", "exu_i1_br_call_e4",
    "ghr_in", "ras_in"
}

EXPECTED_OUT_PORTS = {
    "ifc_fetch_addr_f1", "ifc_fetch_addr_f2", "ifc_fetch_req_f1", "ifc_fetch_req_f1_raw",
    "ifc_fetch_req_f2", "ifc_fetch_uncacheable_f1", "ifc_iccm_access_f1", "ifc_region_acc_fault_f1",
    "ifc_dma_access_ok", "ifu_pmu_fetch_stall",
    "ifu_bp_kill_next_f2", "ifu_bp_btb_target_f2", "ifu_bp_inst_mask_f2",
    "ifu_bp_hist1_f2", "ifu_bp_hist0_f2", "ifu_bp_poffset_f2", "ifu_bp_ret_f2",
    "ifu_bp_pc4_f2", "ifu_bp_valid_f2", "ifu_bp_fghr_f2",
    "ifu_i0_valid", "ifu_i1_valid", "ifu_i0_icaf", "ifu_i1_icaf",
    "ifu_i0_icaf_second", "ifu_i1_icaf_second", "ifu_i0_perr", "ifu_i1_perr",
    "ifu_i0_sbecc", "ifu_i1_sbecc", "ifu_i0_dbecc", "ifu_i1_dbecc",
    "ifu_i0_instr", "ifu_i1_instr", "ifu_i0_pc", "ifu_i1_pc", "ifu_i0_pc4", "ifu_i1_pc4",
    "ifu_i0_cinst", "ifu_i1_cinst", "ifu_fb_consume1", "ifu_fb_consume2", "ifu_illegal_inst",
    "i0_brp", "i1_brp", "ifu_pmu_instr_aligned", "ifu_pmu_align_stall",
    "ifu_icache_error_index", "ifu_icache_error_val", "ifu_icache_sb_error_val",
    "ghr_out", "ras_out"
}


def sha256_file(path: pathlib.Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def strip_comments(text: str) -> str:
    text = re.sub(r'/\*.*?\*/', '', text, flags=re.S)
    text = re.sub(r'//.*', '', text)
    return text


def screen_rtl(path: pathlib.Path, expected_mods: tuple[str, ...]) -> tuple[bool, str]:
    if not path.is_file():
        return False, f'Missing editable RTL file: {path.name}'
    raw = path.read_text(encoding='utf-8', errors='replace')
    cleaned = strip_comments(raw)
    for pat in FORBIDDEN_RTL_PATTERNS:
        if re.search(pat, cleaned, flags=re.I):
            return False, f'Forbidden construct matching {pat} in {path.name}'
    for mod in expected_mods:
        if not re.search(rf'\bmodule\s+{mod}\b', cleaned):
            return False, f'{path.name} must define module {mod}'
    return True, 'ok'


def validate_and_compile_constraints(cpath: pathlib.Path, out_sdc: pathlib.Path) -> tuple[bool, str]:
    if not cpath.is_file():
        return False, 'Missing constraints.json'
    try:
        data = json.loads(cpath.read_text(encoding='utf-8'))
    except Exception as e:
        return False, f'Invalid JSON in constraints.json: {e}'

    if not isinstance(data, dict):
        return False, 'constraints.json root must be an object'
    allowed_keys = {'clocks', 'clock_groups', 'false_paths', 'input_delays', 'output_delays', 'max_delays', 'multicycle_paths'}
    if set(data.keys()) != allowed_keys:
        return False, f'constraints.json must contain exact keys {sorted(allowed_keys)}'

    clocks = data['clocks']
    if not isinstance(clocks, dict) or set(clocks.keys()) != {'clk'}:
        return False, 'clocks must define only clk'
    cinfo = clocks['clk']
    if not isinstance(cinfo, dict) or 'period_ns' not in cinfo or 'waveform_ns' not in cinfo:
        return False, 'clk entry missing period_ns or waveform_ns'
    period = float(cinfo['period_ns'])
    wf = cinfo['waveform_ns']
    if abs(period - 10.0) > 1e-6:
        return False, f'clk period_ns must be 10.0, got {period}'
    if not isinstance(wf, list) or len(wf) != 2 or abs(float(wf[0]) - 0.0) > 1e-6 or abs(float(wf[1]) - 5.0) > 1e-6:
        return False, 'clk waveform_ns must be [0.0, 5.0]'

    if data['clock_groups'] != []:
        return False, 'clock_groups must be empty'
    if data['false_paths'] != []:
        return False, 'false_paths must be empty'
    if data['multicycle_paths'] != []:
        return False, 'multicycle_paths must be empty'

    in_delays = data['input_delays']
    if not isinstance(in_delays, list) or len(in_delays) != 1:
        return False, 'input_delays must have 1 entry'
    in_entry = in_delays[0]
    if in_entry.get('clock') != 'clk' or abs(float(in_entry.get('delay_ns', -1)) - 0.2) > 1e-6:
        return False, 'input_delays[0] must use clock clk and delay_ns 0.2'
    if set(in_entry.get('ports', [])) != EXPECTED_IN_PORTS or len(in_entry.get('ports', [])) != len(EXPECTED_IN_PORTS):
        return False, 'input_delays ports mismatch'

    out_delays = data['output_delays']
    if not isinstance(out_delays, list) or len(out_delays) != 1:
        return False, 'output_delays must have 1 entry'
    out_entry = out_delays[0]
    if out_entry.get('clock') != 'clk' or abs(float(out_entry.get('delay_ns', -1)) - 0.2) > 1e-6:
        return False, 'output_delays[0] must use clock clk and delay_ns 0.2'
    if set(out_entry.get('ports', [])) != EXPECTED_OUT_PORTS or len(out_entry.get('ports', [])) != len(EXPECTED_OUT_PORTS):
        return False, 'output_delays ports mismatch'

    max_delays = data['max_delays']
    if not isinstance(max_delays, list) or len(max_delays) != 2:
        return False, 'max_delays must have exactly 2 entries for ghr_in->ghr_out and ras_in->ras_out'
    seen_pairs = {}
    for md in max_delays:
        if not isinstance(md, dict) or set(md.keys()) != {'from', 'to', 'delay_ns'}:
            return False, 'Invalid max_delays entry structure'
        frm = tuple(md['from']) if isinstance(md['from'], list) else ()
        to = tuple(md['to']) if isinstance(md['to'], list) else ()
        dval = float(md['delay_ns'])
        if dval <= 0.0 or dval > 3.0:
            return False, f'max_delay {dval}ns out of allowed range (0.0, 3.0]'
        seen_pairs[(frm, to)] = dval

    req_pairs = {(('ghr_in',), ('ghr_out',)), (('ras_in',), ('ras_out',))}
    if set(seen_pairs.keys()) != req_pairs:
        return False, 'max_delays must constrain exactly ghr_in->ghr_out and ras_in->ras_out'

    sdc_lines = [
        f'create_clock -name clk -period {period:.3f} -waveform {{0.000 5.000}} [get_ports clk]',
    ]
    for p in sorted(EXPECTED_IN_PORTS):
        sdc_lines.append(f'set_input_delay -clock clk 0.200 [get_ports {{{p}*}}]')
    for p in sorted(EXPECTED_OUT_PORTS):
        sdc_lines.append(f'set_output_delay -clock clk 0.200 [get_ports {{{p}*}}]')
    for (frm, to), dval in sorted(seen_pairs.items()):
        sdc_lines.append(f'set_max_delay {dval:.3f} -from [get_ports {{{frm[0]}*}}] -to [get_ports {{{to[0]}*}}]')

    out_sdc.write_text('\n'.join(sdc_lines) + '\n', encoding='utf-8')
    return True, 'ok'


def finish_out(out_path: pathlib.Path, status: str, stage: str, detail: str, checks: list, metrics: dict):
    verdict = 'PASS' if status == 'PASS' else 'FAIL'
    payload = {
        'status': status,
        'verdict': verdict,
        'stage': stage,
        'detail': detail,
        'reason': detail,
        'checks': checks,
        'metrics': metrics,
        **metrics,
    }
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(json.dumps(payload, indent=2) + '\n', encoding='utf-8')
    print(json.dumps(payload))
    raise SystemExit(0 if verdict == 'PASS' else 1)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--candidate', required=True)
    ap.add_argument('--seed', type=int, default=101)
    ap.add_argument('--result', '--out', dest='out', required=True)
    args = ap.parse_args()

    task_dir = pathlib.Path(__file__).resolve().parents[2]
    cand_dir = pathlib.Path(args.candidate).resolve()
    out_path = pathlib.Path(args.out).resolve()

    checks = []
    metrics = {}

    def record(name: str, passed: bool, detail: str = ''):
        checks.append({'name': name, 'passed': bool(passed), 'detail': detail})

    pub_dir = task_dir / 'public'
    priv_dir = task_dir / 'private'

    for rfile in READONLY_CODE_FILES:
        cand_f = cand_dir / 'code' / rfile
        pub_f = pub_dir / 'code' / rfile
        if cand_f.exists() and sha256_file(cand_f) != sha256_file(pub_f):
            record('readonly_integrity', False, f'Read-only file modified: code/{rfile}')
            finish_out(out_path, 'FAIL', 'policy', f'Read-only file modified: code/{rfile}', checks, metrics)
    record('readonly_integrity', True, 'Read-only files intact')

    mod_map = {
        'code/ifu_compress_ctl.sv': ('ifu_compress_ctl',),
        'code/ifu_aln_ctl.sv': ('ifu_aln_ctl',),
        'code/ifu_bp_ctl.sv': ('ifu_bp_ctl',),
        'code/ifu_ifc_ctl.sv': ('ifu_ifc_ctl',),
    }
    for rel, mods in mod_map.items():
        ok, msg = screen_rtl(cand_dir / rel, mods)
        record(f'screen_{pathlib.Path(rel).stem}', ok, msg)
        if not ok:
            finish_out(out_path, 'FAIL', 'policy', msg, checks, metrics)

    with tempfile.TemporaryDirectory(prefix='grade_6012_') as tmp:
        tmpdir = pathlib.Path(tmp)
        work_code = tmpdir / 'code'
        work_code.mkdir(parents=True, exist_ok=True)
        for rfile in READONLY_CODE_FILES:
            shutil.copyfile(pub_dir / 'code' / rfile, work_code / rfile)
        for rel in mod_map:
            shutil.copyfile(cand_dir / rel, tmpdir / rel)

        sdc_path = tmpdir / 'compiled.sdc'
        sdc_ok, sdc_msg = validate_and_compile_constraints(cand_dir / 'constraints.json', sdc_path)
        record('constraints_schema', sdc_ok, sdc_msg)
        if not sdc_ok:
            finish_out(out_path, 'FAIL', 'constraints', sdc_msg, checks, metrics)

        env = os.environ.copy()
        env['PATH'] = f'{OSS_CAD_BIN}:{env.get("PATH", "")}'
        sim_bin = tmpdir / 'sim_tb'
        v_cmd = [
            str(OSS_CAD_BIN / 'verilator'),
            '--binary', '-j', '2', '-Wno-fatal', '--top-module', 'tb',
            f'-I{work_code}',
            str(work_code / 'common_defines.vh'),
            str(work_code / 'veer_types.sv'),
            str(work_code / 'beh_lib.sv'),
            str(work_code / 'ifu_compress_ctl.sv'),
            str(work_code / 'ifu_aln_ctl.sv'),
            str(work_code / 'ifu_bp_ctl.sv'),
            str(work_code / 'ifu_ifc_ctl.sv'),
            str(work_code / 'veer_ifu_aln_bp_top.sv'),
            str(priv_dir / 'tests/tb.sv'),
            '--Mdir', str(tmpdir / 'obj_dir'),
            '-o', str(sim_bin),
        ]
        v_comp = subprocess.run(v_cmd, env=env, capture_output=True, text=True, timeout=120)
        if v_comp.returncode != 0 or not sim_bin.is_file():
            record('verilator_compile', False, v_comp.stderr[-600:])
            finish_out(out_path, 'FAIL', 'compile', v_comp.stderr[-600:], checks, metrics)
        record('verilator_compile', True, 'ok')

        sim_run = subprocess.run([str(sim_bin)], env=env, capture_output=True, text=True, timeout=60)
        sim_out = sim_run.stdout + '\n' + sim_run.stderr
        sim_pass = (sim_run.returncode == 0) and ('PASS: veer_ifu_aln_bp_top verification succeeded.' in sim_out) and ('FAIL:' not in sim_out)
        sim_msg = sim_out.strip().splitlines()[-1] if sim_out.strip() else ''
        record('functional_sim', sim_pass, sim_msg)
        if not sim_pass:
            finish_out(out_path, 'FAIL', 'behavior', sim_out[-800:], checks, metrics)

        lib_file = pub_dir / 'lib/NangateOpenCellLibrary_typical.lib'
        mapped_v = tmpdir / 'mapped.v'
        ys_script = f"""
read_slang --single-unit --top veer_ifu_aln_bp_top -I{work_code} \
  {work_code / 'common_defines.vh'} \
  {work_code / 'veer_types.sv'} \
  {work_code / 'beh_lib.sv'} \
  {work_code / 'ifu_compress_ctl.sv'} \
  {work_code / 'ifu_aln_ctl.sv'} \
  {work_code / 'ifu_bp_ctl.sv'} \
  {work_code / 'ifu_ifc_ctl.sv'} \
  {work_code / 'veer_ifu_aln_bp_top.sv'}
hierarchy -check -top veer_ifu_aln_bp_top
proc
select -assert-none t:$dlatch* t:$adlatch* t:$latch* t:$sr* t:$_DLATCH* */t:$dlatch* */t:$adlatch* */t:$latch* */t:$sr* */t:$_DLATCH*
opt_clean
select -assert-none t:$dlatch* t:$adlatch* t:$latch* t:$sr* t:$_DLATCH* */t:$dlatch* */t:$adlatch* */t:$latch* */t:$sr* */t:$_DLATCH*
synth -top veer_ifu_aln_bp_top
opt
dfflibmap -liberty {lib_file}
abc -liberty {lib_file}
clean
read_liberty -lib {lib_file}
check -assert
stat -liberty {lib_file}
write_verilog -noattr {mapped_v}
"""
        ys_res = subprocess.run(
            [str(OSS_CAD_BIN / 'yosys'), '-Q', '-T', '-m', 'slang', '-p', ys_script],
            env=env, capture_output=True, text=True, timeout=180
        )
        ys_out = ys_res.stdout + '\n' + ys_res.stderr
        if ys_res.returncode != 0 or not mapped_v.is_file():
            record('yosys_synth_latch_free', False, ys_out[-600:])
            finish_out(out_path, 'FAIL', 'synthesis', ys_out[-600:], checks, metrics)
        record('yosys_synth_latch_free', True, 'Synthesis & latch-free assertions passed')

        m_area = re.search(r"Chip area for module '\\veer_ifu_aln_bp_top':\s*([0-9.]+)", ys_out)
        chip_area = float(m_area.group(1)) if m_area else 999999.0
        metrics['chip_area_um2'] = chip_area
        area_ok = chip_area <= 30000.0
        record('area_budget', area_ok, f'chip_area={chip_area:.2f} um^2 (limit 30000.00)')
        if not area_ok:
            finish_out(out_path, 'FAIL', 'area', f'chip_area={chip_area:.2f} > 30000.00', checks, metrics)

        tech_lef = pub_dir / 'lib/NangateOpenCellLibrary.tech.lef'
        macro_lef = pub_dir / 'lib/NangateOpenCellLibrary.macro.mod.lef'
        sta_v = tmpdir / 'sta.v'
        sta_v.write_text(mapped_v.read_text(encoding='utf-8').replace(' signed ', ' '), encoding='utf-8')
        sta_tcl = tmpdir / 'sta.tcl'
        sta_tcl.write_text(f"""
set_thread_count 1
read_lef {tech_lef}
read_lef {macro_lef}
read_liberty {lib_file}
read_verilog {sta_v}
link_design veer_ifu_aln_bp_top
read_sdc {sdc_path}
check_setup -verbose
report_checks -path_delay min_max -format full_clock_expanded -digits 3
report_checks -from [get_ports {{ghr_in*}}] -to [get_ports {{ghr_out*}}] -path_delay max -digits 3
report_checks -from [get_ports {{ras_in*}}] -to [get_ports {{ras_out*}}] -path_delay max -digits 3
report_wns -digits 3
report_tns -digits 3
exit
""", encoding='utf-8')
        or_res = subprocess.run(
            [str(OPENROAD_BIN), '-exit', str(sta_tcl)],
            env=env, capture_output=True, text=True, timeout=120
        )
        or_out = or_res.stdout + '\n' + or_res.stderr
        if or_res.returncode != 0:
            record('openroad_sta', False, or_out[-600:])
            finish_out(out_path, 'FAIL', 'timing', or_out[-600:], checks, metrics)

        slacks = [float(x) for x in re.findall(r'^\s*([-+]?[0-9]+\.[0-9]+)\s+slack\s+\((?:MET|VIOLATED)\)', or_out, flags=re.M)]
        m_wns = re.search(r'wns\s+(?:max\s+)?([-+]?[0-9]+\.[0-9]+)', or_out, flags=re.I)
        m_tns = re.search(r'tns\s+(?:max\s+)?([-+]?[0-9]+\.[0-9]+)', or_out, flags=re.I)
        wns = float(m_wns.group(1)) if m_wns else (-999.0 if not slacks else min(slacks))
        tns = float(m_tns.group(1)) if m_tns else (-999.0 if not slacks else sum(s for s in slacks if s < 0))
        min_slack = min(slacks) if slacks else -999.0
        metrics['wns_ns'] = wns
        metrics['tns_ns'] = tns
        metrics['min_slack_ns'] = min_slack
        sta_ok = (len(slacks) >= 4) and (min_slack >= 0.0) and (wns >= 0.0) and (tns >= 0.0) and ('VIOLATED' not in or_out)
        sta_msg = f'wns={wns:.3f} tns={tns:.3f} min_slack={min_slack:.3f}'
        record('openroad_sta', sta_ok, sta_msg)
        if not sta_ok:
            finish_out(out_path, 'FAIL', 'timing', sta_msg, checks, metrics)

        finish_out(out_path, 'PASS', 'all', f'PASS veer_ifu_aln_bp_top ({sta_msg}, area={chip_area:.2f})', checks, metrics)


if __name__ == '__main__':
    main()
