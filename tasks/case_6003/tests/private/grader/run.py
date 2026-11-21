#!/usr/bin/env python3
"""Trusted isolated grader for case_6003 (VeeR-EH1 LSU AXI4-to-AHB Bridge, DMA AHB-to-AXI4 Slave Gasket, 4-Entry DMA/Debug Controller, and Transparent Sideband Timing Closure)."""
import argparse
import hashlib
import json
import math
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

PRIV_DIR = pathlib.Path(__file__).resolve().parents[1]
TASK_DIR = PRIV_DIR.parent
PUB_DIR = TASK_DIR / 'public'
PUB_CODE = PUB_DIR / 'code'
PUB_LIB = PUB_DIR / 'lib'

TOOLS_ROOT = pathlib.Path(str(_sb_tools_dir()))
VERILATOR_BIN = TOOLS_ROOT / 'verilator-v5.038' / 'bin' / 'verilator'
YOSYS_BIN = TOOLS_ROOT / 'oss-cad-suite' / 'bin' / 'yosys'
OPENROAD_BIN = TOOLS_ROOT / 'bin' / 'openroad'

EDITABLE_RTL_FILES = ('axi4_to_ahb.sv', 'ahb_to_axi4.sv', 'dma_ctrl.sv')
FIXED_CODE_FILES = (
    'common_defines.vh',
    'global.h',
    'veer_types.sv',
    'beh_lib.sv',
    'veer_bus_dma_top.sv',
    'LICENSE',
)
FIXED_LIB_FILES = (
    'NangateOpenCellLibrary_typical.lib',
    'NangateOpenCellLibrary.tech.lef',
    'NangateOpenCellLibrary.macro.mod.lef',
    'LICENSE.Nangate45',
)

AREA_LIMIT_UM2 = 12350.0
MIN_SETUP_SLACK_NS = 0.00
MIN_HOLD_SLACK_NS = 0.00

IN_GROUPS = {
    'rst_l', 'scan_mode', 'bus_clk_en', 'dma_bus_clk_en', 'clk_override',
    'lsu_axi_awvalid', 'lsu_axi_awid', 'lsu_axi_awaddr', 'lsu_axi_awsize', 'lsu_axi_awprot',
    'lsu_axi_wvalid', 'lsu_axi_wdata', 'lsu_axi_wstrb', 'lsu_axi_wlast', 'lsu_axi_bready',
    'lsu_axi_arvalid', 'lsu_axi_arid', 'lsu_axi_araddr', 'lsu_axi_arsize', 'lsu_axi_arprot',
    'lsu_axi_rready', 'lsu_ahb_hrdata', 'lsu_ahb_hready', 'lsu_ahb_hresp',
    'dma_ahb_haddr', 'dma_ahb_hburst', 'dma_ahb_hmastlock', 'dma_ahb_hprot', 'dma_ahb_hsize',
    'dma_ahb_htrans', 'dma_ahb_hwrite', 'dma_ahb_hwdata', 'dma_ahb_hsel', 'dma_ahb_hreadyin',
    'ext_dma_axi_sel', 'ext_dma_axi_awvalid', 'ext_dma_axi_awid', 'ext_dma_axi_awaddr',
    'ext_dma_axi_awsize', 'ext_dma_axi_awprot', 'ext_dma_axi_awlen', 'ext_dma_axi_awburst',
    'ext_dma_axi_wvalid', 'ext_dma_axi_wdata', 'ext_dma_axi_wstrb', 'ext_dma_axi_wlast',
    'ext_dma_axi_bready', 'ext_dma_axi_arvalid', 'ext_dma_axi_arid', 'ext_dma_axi_araddr',
    'ext_dma_axi_arsize', 'ext_dma_axi_arprot', 'ext_dma_axi_arlen', 'ext_dma_axi_arburst',
    'ext_dma_axi_rready',
    'dbg_cmd_addr', 'dbg_cmd_wrdata', 'dbg_cmd_valid', 'dbg_cmd_write', 'dbg_cmd_type',
    'dbg_cmd_size', 'dbg_dma_bubble',
    'dccm_dma_rvalid', 'dccm_dma_ecc_error', 'dccm_dma_rdata',
    'iccm_dma_rvalid', 'iccm_dma_ecc_error', 'iccm_dma_rdata',
    'dccm_ready', 'iccm_ready', 'dec_tlu_stall_dma', 'dec_tlu_dma_qos_prty',
    'qos_in', 'region_in',
}
OUT_GROUPS = {
    'lsu_axi_awready', 'lsu_axi_wready', 'lsu_axi_bvalid', 'lsu_axi_bresp', 'lsu_axi_bid',
    'lsu_axi_arready', 'lsu_axi_rvalid', 'lsu_axi_rid', 'lsu_axi_rdata', 'lsu_axi_rresp', 'lsu_axi_rlast',
    'lsu_ahb_haddr', 'lsu_ahb_hburst', 'lsu_ahb_hmastlock', 'lsu_ahb_hprot', 'lsu_ahb_hsize',
    'lsu_ahb_htrans', 'lsu_ahb_hwrite', 'lsu_ahb_hwdata',
    'dma_ahb_hrdata', 'dma_ahb_hreadyout', 'dma_ahb_hresp',
    'ext_dma_axi_awready', 'ext_dma_axi_wready', 'ext_dma_axi_bvalid', 'ext_dma_axi_bresp', 'ext_dma_axi_bid',
    'ext_dma_axi_arready', 'ext_dma_axi_rvalid', 'ext_dma_axi_rid', 'ext_dma_axi_rdata',
    'ext_dma_axi_rresp', 'ext_dma_axi_rlast',
    'dma_dbg_ready', 'dma_dbg_cmd_done', 'dma_dbg_cmd_fail', 'dma_dbg_rddata',
    'dma_dccm_req', 'dma_iccm_req', 'dma_mem_addr', 'dma_mem_sz', 'dma_mem_write', 'dma_mem_wdata',
    'dma_dccm_stall_any', 'dma_iccm_stall_any', 'dma_mem_dccm_req', 'dma_slv_algn_err',
    'qos_out', 'region_out',
}
IN_BITS = {f'{g}[{i}]' for g in ('qos_in', 'region_in') for i in range(8)}
OUT_BITS = {f'{g}[{i}]' for g in ('qos_out', 'region_out') for i in range(8)}
ALLOWED_IN = IN_GROUPS | IN_BITS
ALLOWED_OUT = OUT_GROUPS | OUT_BITS
NON_TRANSPARENT = (IN_GROUPS - {'qos_in', 'region_in'}) | (OUT_GROUPS - {'qos_out', 'region_out'})
BUS_PREFIXES = {
    'lsu_axi_awid', 'lsu_axi_awaddr', 'lsu_axi_awsize', 'lsu_axi_awprot',
    'lsu_axi_wdata', 'lsu_axi_wstrb', 'lsu_axi_bresp', 'lsu_axi_bid',
    'lsu_axi_arid', 'lsu_axi_araddr', 'lsu_axi_arsize', 'lsu_axi_arprot',
    'lsu_axi_rid', 'lsu_axi_rdata', 'lsu_axi_rresp',
    'lsu_ahb_haddr', 'lsu_ahb_hburst', 'lsu_ahb_hprot', 'lsu_ahb_hsize', 'lsu_ahb_htrans', 'lsu_ahb_hwdata', 'lsu_ahb_hrdata',
    'dma_ahb_haddr', 'dma_ahb_hburst', 'dma_ahb_hprot', 'dma_ahb_hsize', 'dma_ahb_htrans', 'dma_ahb_hwdata', 'dma_ahb_hrdata',
    'ext_dma_axi_awaddr', 'ext_dma_axi_awsize', 'ext_dma_axi_awprot', 'ext_dma_axi_awlen', 'ext_dma_axi_awburst',
    'ext_dma_axi_wdata', 'ext_dma_axi_wstrb', 'ext_dma_axi_bresp',
    'ext_dma_axi_araddr', 'ext_dma_axi_arsize', 'ext_dma_axi_arprot', 'ext_dma_axi_arlen', 'ext_dma_axi_arburst',
    'ext_dma_axi_rdata', 'ext_dma_axi_rresp',
    'dbg_cmd_addr', 'dbg_cmd_wrdata', 'dbg_cmd_type', 'dbg_cmd_size', 'dma_dbg_rddata',
    'dma_mem_addr', 'dma_mem_sz', 'dma_mem_wdata', 'dccm_dma_rdata', 'iccm_dma_rdata', 'dec_tlu_dma_qos_prty',
    'qos_in', 'qos_out', 'region_in', 'region_out',
}


def finish(result_path: pathlib.Path, verdict: str, stage: str, detail: str, **extra):
    payload = {
        'verdict': verdict,
        'stage': stage,
        'detail': detail,
        'reason': detail,
        **extra,
    }
    result_path.parent.mkdir(parents=True, exist_ok=True)
    result_path.write_text(json.dumps(payload, indent=2) + '\n')
    print(json.dumps(payload))
    raise SystemExit(0 if verdict == 'PASS' else 2 if verdict == 'ERROR' else 1)


def sha256_bytes(path: pathlib.Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def strip_comments_and_strings(text: str) -> str:
    text = re.sub(r'`ifdef\s+ASSERT_ON\b.*?`endif', ' ', text, flags=re.S)
    return re.sub(r'/\*.*?\*/|//[^\n]*|"(?:\\.|[^"\\])*"', ' ', text, flags=re.S)


def scan_strings(node):
    if isinstance(node, str):
        yield node
    elif isinstance(node, list):
        for item in node:
            yield from scan_strings(item)
    elif isinstance(node, dict):
        for k, v in node.items():
            yield from scan_strings(k)
            yield from scan_strings(v)


def screen_rtl(filename: str, raw: str, result_path: pathlib.Path):
    if len(raw.encode('utf-8')) > 500_000:
        finish(result_path, 'FAIL', 'policy', f'{filename}: exceeds size limit')
    if re.search(r'(?i)(?:pragma|synthesis|synopsys|verilator)\s+(?:translate_)?(?:on|off)', raw):
        finish(result_path, 'FAIL', 'policy', f'{filename}: prohibited pragma translate_off/on')

    cleaned = strip_comments_and_strings(raw)
    escape_pats = [
        (r'\$(?!clog2\b|bits\b|signed\b|unsigned\b|size\b|onehot0\b|onehot\b)[a-zA-Z_][\w$]*', 'forbidden_systask'),
        (r'\b(?:force|release|bind|defparam|initial|final|fork|join|join_any|join_none|wait|always_latch)\b', 'procedural_force_or_sim_construct'),
        (r'\b(?:import|export)\s*"DPI', 'dpi_escape'),
        (r'\$root\b|\b(?:tb|dut|grader|oracle|golden_ref)\s*\.', 'hierarchical_harness_reference'),
        (r'`\s*(?:ifdef|ifndef|elsif)\s+(?:VERILATOR|SYNTHESIS|SIMULATION|__ICARUS__|VCS|QUESTA)\b', 'simulator_or_synthesis_macro_divergence'),
        (r'`\s*(?:define|undef)\b', 'prohibited_macro_definition'),
        (r'`\s*include\s+"(?!global\.h")[^"]+"', 'unauthorized_include'),
        (r'(?<!\bassert)\s+#\s*\d', 'prohibited_delay_control'),
    ]
    for pat, label in escape_pats:
        if re.search(pat, cleaned, re.I):
            finish(result_path, 'FAIL', 'policy', f'Policy violation in {filename}: {label}')

    expected_mod = filename[:-3]
    if len(re.findall(r'\bmodule\b', cleaned)) != 1 or not re.search(r'\bmodule\s+' + expected_mod + r'\b', cleaned):
        finish(result_path, 'FAIL', 'structural', f'Expected single module {expected_mod} in {filename}')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--candidate', required=True)
    ap.add_argument('--seed', type=int, default=101)
    ap.add_argument('--result', required=True)
    args = ap.parse_args()

    result_path = pathlib.Path(args.result).resolve()
    cand_in = pathlib.Path(args.candidate)
    if not cand_in.is_absolute() or any(x.is_symlink() for x in (cand_in, *cand_in.parents)) or not cand_in.is_dir():
        finish(result_path, 'FAIL', 'input_validation', 'Candidate must be an absolute non-symlink directory')
    cand_root = cand_in.resolve()

    for fname in FIXED_CODE_FILES:
        ref = PUB_CODE / fname
        for q in (cand_root / 'code' / fname, cand_root / fname):
            if q.exists() or q.is_symlink():
                if q.is_symlink() or not q.is_file() or not q.resolve().is_relative_to(cand_root):
                    finish(result_path, 'FAIL', 'policy', f'Invalid or symlinked protected dependency: {fname}')
                if sha256_bytes(q) != sha256_bytes(ref):
                    finish(result_path, 'FAIL', 'policy', f'Protected dependency changed: {fname}')

    for lname in FIXED_LIB_FILES:
        ref = PUB_LIB / lname
        q = cand_root / 'lib' / lname
        if q.exists() or q.is_symlink():
            if q.is_symlink() or not q.is_file() or not q.resolve().is_relative_to(cand_root):
                finish(result_path, 'FAIL', 'policy', f'Invalid or symlinked protected library file: {lname}')
            if sha256_bytes(q) != sha256_bytes(ref):
                finish(result_path, 'FAIL', 'policy', f'Protected library file changed: {lname}')

    cand_sources = {}
    for edit_name in EDITABLE_RTL_FILES:
        found = None
        for q in (cand_root / 'code' / edit_name, cand_root / edit_name):
            if q.exists() or q.is_symlink():
                found = q
                break
        if found is None:
            found = PUB_CODE / edit_name
        else:
            if found.is_symlink() or not found.is_file() or not found.resolve().is_relative_to(cand_root):
                finish(result_path, 'FAIL', 'policy', f'Invalid or symlinked candidate source: {edit_name}')
        text = found.read_text(encoding='utf-8', errors='replace')
        screen_rtl(edit_name, text, result_path)
        cand_sources[edit_name] = text

    c_json = cand_root / 'constraints.json'
    if not c_json.exists() and not c_json.is_symlink():
        c_json = PUB_DIR / 'constraints.json'
    elif c_json.is_symlink() or not c_json.is_file() or not c_json.resolve().is_relative_to(cand_root):
        finish(result_path, 'FAIL', 'policy', 'Invalid or symlinked constraints.json')
    if c_json.stat().st_size > 16384:
        finish(result_path, 'FAIL', 'input_validation', 'constraints.json exceeds size limit')

    try:
        c_obj = json.loads(c_json.read_text(encoding='utf-8'))
    except Exception as exc:
        finish(result_path, 'FAIL', 'input_validation', f'Malformed JSON in constraints.json: {exc}')

    for s in scan_strings(c_obj):
        if re.search(
            r'[;\n\r${}*]|'
            r'\b(?:exec|open|socket|source|load|eval|interp|puts|read_verilog|read_liberty|read_lef|'
            r'create_clock|set_input_delay|set_output_delay|set_false_path|set_multicycle_path|'
            r'all_inputs|all_outputs|all_registers|get_ports|get_pins|get_nets|get_clocks)\b',
            s,
        ):
            finish(result_path, 'FAIL', 'policy', f'Forbidden Tcl/SDC injection token in constraints.json: {s!r}')

    if not isinstance(c_obj, dict) or set(c_obj.keys()) != {'max_delays'}:
        finish(result_path, 'FAIL', 'input_validation', 'Top-level JSON object must contain only key "max_delays"')
    rules = c_obj['max_delays']
    if not isinstance(rules, list) or len(rules) > 64:
        finish(result_path, 'FAIL', 'input_validation', '"max_delays" must be a list of at most 64 rule objects')

    for idx, r in enumerate(rules):
        if not isinstance(r, dict) or set(r.keys()) != {'from', 'to', 'ns'}:
            finish(result_path, 'FAIL', 'input_validation', f'Rule {idx} must be an object with keys "from", "to", "ns"')
        if not isinstance(r['from'], list) or not r['from'] or not all(isinstance(x, str) and x in ALLOWED_IN for x in r['from']):
            finish(result_path, 'FAIL', 'input_validation', f'Rule {idx} has invalid "from" port group(s)')
        if not isinstance(r['to'], list) or not r['to'] or not all(isinstance(x, str) and x in ALLOWED_OUT for x in r['to']):
            finish(result_path, 'FAIL', 'input_validation', f'Rule {idx} has invalid "to" port group(s)')
        if type(r['ns']) not in (int, float) or not math.isfinite(r['ns']) or not (0 < r['ns'] < 1000):
            finish(result_path, 'FAIL', 'input_validation', f'Rule {idx} has invalid "ns" delay value')

    env = {
        'PATH': f'{TOOLS_ROOT / "verilator-v5.038" / "bin"}:{TOOLS_ROOT / "oss-cad-suite" / "bin"}:{TOOLS_ROOT / "bin"}:/usr/bin:/bin',
        'HOME': '/tmp',
        'TMPDIR': '/tmp',
        'LANG': 'C.UTF-8',
        'VERILATOR_ROOT': str(TOOLS_ROOT / 'verilator-v5.038' / 'share' / 'verilator'),
        'OMP_NUM_THREADS': '1',
        'OPENBLAS_NUM_THREADS': '1',
        'MAKEFLAGS': '-j1',
    }

    try:
        with tempfile.TemporaryDirectory(prefix='case_6003_grade_') as tmp:
            td = pathlib.Path(tmp)
            src = td / 'code'
            src.mkdir()
            for fname in FIXED_CODE_FILES:
                shutil.copyfile(PUB_CODE / fname, src / fname)
            for fname, text in cand_sources.items():
                (src / fname).write_text(text, encoding='utf-8')
            shutil.copyfile(PRIV_DIR / 'tests' / 'tb.sv', td / 'tb.sv')

            # 1. Verilator behavioral simulation
            seed_val = (args.seed & 0x7fffffff) or 101
            obj_dir = td / 'obj'
            v_cmd = [
                str(VERILATOR_BIN),
                '--binary',
                '--timing',
                '-j', '1',
                '-Wno-fatal',
                f'-I{src}',
                f'-GSEED={seed_val}',
                '--top-module', 'tb',
                '--Mdir', str(obj_dir),
                str(src / 'common_defines.vh'),
                str(src / 'veer_types.sv'),
                str(src / 'beh_lib.sv'),
                str(src / 'axi4_to_ahb.sv'),
                str(src / 'ahb_to_axi4.sv'),
                str(src / 'dma_ctrl.sv'),
                str(src / 'veer_bus_dma_top.sv'),
                str(td / 'tb.sv'),
            ]
            build = subprocess.run(v_cmd, cwd=td, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=180)
            if build.returncode != 0 or not (obj_dir / 'Vtb').is_file():
                finish(result_path, 'FAIL', 'compile', f'Verilator elaboration failed:\n{build.stdout[-1500:].strip()}')

            sim = subprocess.run([str(obj_dir / 'Vtb')], cwd=td, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=60)
            if sim.returncode != 0 or f'PASS veer_bus_dma_top seed={seed_val}' not in sim.stdout:
                finish(result_path, 'FAIL', 'behavior', f'Simulation failed (seed={seed_val}):\n{sim.stdout[-1500:].strip()}')

            # 2. Yosys/Slang latch-free check + ABC Nangate45 synthesis
            lib_file = PUB_LIB / 'NangateOpenCellLibrary_typical.lib'
            tech_lef = PUB_LIB / 'NangateOpenCellLibrary.tech.lef'
            macro_lef = PUB_LIB / 'NangateOpenCellLibrary.macro.mod.lef'
            mapped_v = td / 'mapped.v'
            ys_synth = td / 'synth.ys'
            ys_synth.write_text(
                f'read_slang --single-unit --top veer_bus_dma_top -I{src} '
                f'{src / "common_defines.vh"} {src / "veer_types.sv"} {src / "beh_lib.sv"} '
                f'{src / "axi4_to_ahb.sv"} {src / "ahb_to_axi4.sv"} {src / "dma_ctrl.sv"} {src / "veer_bus_dma_top.sv"}\n'
                f'hierarchy -check -top veer_bus_dma_top\n'
                f'proc\n'
                f'select -assert-none */t:$dlatch* */t:$adlatch* */t:$latch* */t:$sr* */t:$_DLATCH*\n'
                f'opt_clean\n'
                f'select -assert-none */t:$dlatch* */t:$adlatch* */t:$latch* */t:$sr* */t:$_DLATCH*\n'
                f'synth -top veer_bus_dma_top\n'
                f'opt\n'
                f'dfflibmap -liberty {lib_file}\n'
                f'abc -liberty {lib_file}\n'
                f'clean\n'
                f'read_liberty -lib {lib_file}\n'
                f'check -assert\n'
                f'stat -liberty {lib_file}\n'
                f'write_verilog -noattr {mapped_v}\n',
                encoding='utf-8',
            )
            r_syn = subprocess.run([str(YOSYS_BIN), '-Q', '-T', '-m', 'slang', str(ys_synth)], cwd=td, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=180)
            m_area = re.findall(r'Chip area for module .*?:\s*([0-9.]+)', r_syn.stdout)
            if r_syn.returncode != 0 or not m_area or not mapped_v.is_file():
                finish(result_path, 'FAIL', 'synthesis', f'Yosys/Slang latch-free or Nangate45 synthesis failed:\n{r_syn.stdout[-1500:].strip()}')

            area_um2 = round(float(m_area[-1]), 3)
            if area_um2 > AREA_LIMIT_UM2:
                finish(
                    result_path,
                    'FAIL',
                    'area',
                    f'Mapped cell area {area_um2:.3f} um^2 exceeds limit {AREA_LIMIT_UM2:.1f} um^2',
                    area_um2=area_um2,
                    area_limit_um2=AREA_LIMIT_UM2,
                )

            # 3. OpenROAD static timing analysis + transparent channel budget verification
            for r in rules:
                bad_ep = [ep for ep in (r['from'] + r['to']) if ep in NON_TRANSPARENT]
                if bad_ep:
                    finish(
                        result_path,
                        'FAIL',
                        'timing',
                        f'Registered bridge/DMA port(s) modified by max_delays exception: {", ".join(bad_ep)}',
                        area_um2=area_um2,
                    )

            def ports(groups):
                return ' '.join(g + '*' if g in BUS_PREFIXES else g for g in groups)

            clk_period_ns = 5.60 if (args.seed % 2 == 1) else 6.00
            sta_v = td / 'sta.v'
            sta_v.write_text(mapped_v.read_text(encoding='utf-8').replace(' signed ', ' '), encoding='utf-8')
            lines = [
                'set_thread_count 1',
                f'read_lef {tech_lef}',
                f'read_lef {macro_lef}',
                f'read_liberty {lib_file}',
                f'read_verilog {sta_v}',
                'link_design veer_bus_dma_top',
                f'create_clock -name clk -period {clk_period_ns:.2f} [get_ports clk]',
                'set_input_delay 2.50 -clock clk [all_inputs -no_clocks]',
                'set_output_delay 2.00 -clock clk [all_outputs]',
                'set_load 5.0 [all_outputs]',
                'set_false_path -from [get_ports {rst_l scan_mode}]',
            ]
            for r in rules:
                lines.append(f"set_max_delay {r['ns']} -from [get_ports {{{ports(r['from'])}}}] -to [get_ports {{{ports(r['to'])}}}]")

            for name in ('qos', 'region'):
                for bit in range(8):
                    lines += [
                        f'puts "BEGIN_{name}_{bit}"',
                        f'report_checks -from [get_ports {{{name}_in[{bit}]}}] -to [get_ports {{{name}_out[{bit}]}}] -path_delay max -format full_clock_expanded -digits 4',
                        f'puts "END_{name}_{bit}"',
                    ]
            lines += [
                'puts "WNS [sta::worst_slack -max]"',
                'puts "WHS [sta::worst_slack -min]"',
            ]

            flow_tcl = td / 'flow.tcl'
            flow_tcl.write_text('\n'.join(lines) + '\n', encoding='utf-8')
            r_or = subprocess.run([str(OPENROAD_BIN), '-exit', str(flow_tcl)], cwd=td, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=180)
            if r_or.returncode != 0:
                finish(result_path, 'FAIL', 'timing', f'OpenROAD STA failed:\n{r_or.stdout[-1500:].strip()}', area_um2=area_um2)

            out = r_or.stdout
            for name, target in [('qos', 1.65), ('region', 2.45)]:
                for bit in range(8):
                    m = re.search(f'BEGIN_{name}_{bit}\\n(.*?)END_{name}_{bit}', out, re.S)
                    if not m:
                        finish(result_path, 'FAIL', 'timing', f'Missing STA report for {name}[{bit}]', area_um2=area_um2)
                    slack_m = re.search(r'(-?\d+\.\d+)\s+slack\s+\(', m.group(1))
                    if not slack_m or 'max_delay' not in m.group(1):
                        finish(result_path, 'FAIL', 'timing', f'Transparent path {name}[{bit}] lacks required max_delay budget', area_um2=area_um2)
                    slack_val = float(slack_m.group(1))
                    if abs(slack_val - target) >= 0.015:
                        finish(
                            result_path,
                            'FAIL',
                            'timing',
                            f'{name}[{bit}] slack {slack_val:.4f} ns does not match target budget {target:.2f} ns',
                            area_um2=area_um2,
                        )

            m_wns = re.search(r'WNS\s+([-+0-9.eE]+)', out)
            m_whs = re.search(r'WHS\s+([-+0-9.eE]+)', out)
            if not m_wns or not m_whs:
                finish(result_path, 'FAIL', 'timing', 'Missing WNS/WHS in OpenROAD output', area_um2=area_um2)

            wns_ns = round(float(m_wns.group(1)), 4)
            whs_ns = round(float(m_whs.group(1)), 4)
            if not math.isfinite(wns_ns) or not math.isfinite(whs_ns):
                finish(result_path, 'FAIL', 'timing', 'Non-finite slack values', area_um2=area_um2)

            if wns_ns < MIN_SETUP_SLACK_NS:
                finish(
                    result_path,
                    'FAIL',
                    'timing',
                    f'Worst setup slack {wns_ns:.4f} ns < {MIN_SETUP_SLACK_NS:.2f} ns at {clk_period_ns:.2f} ns clock',
                    area_um2=area_um2,
                    wns_ns=wns_ns,
                    whs_ns=whs_ns,
                )
            if whs_ns < MIN_HOLD_SLACK_NS:
                finish(
                    result_path,
                    'FAIL',
                    'timing',
                    f'Worst hold slack {whs_ns:.4f} ns < {MIN_HOLD_SLACK_NS:.2f} ns',
                    area_um2=area_um2,
                    wns_ns=wns_ns,
                    whs_ns=whs_ns,
                )

            finish(
                result_path,
                'PASS',
                'all',
                f'PASS veer_bus_dma_top functional, latch-free, area ({area_um2:.3f} <= {AREA_LIMIT_UM2:.1f} um^2), transparent budgets, and STA (WNS={wns_ns:.4f} ns, WHS={whs_ns:.4f} ns)',
                area_um2=area_um2,
                area_limit_um2=AREA_LIMIT_UM2,
                wns_ns=wns_ns,
                whs_ns=whs_ns,
            )
    except subprocess.TimeoutExpired:
        finish(result_path, 'ERROR', 'environment', 'Synthesis, simulation, or STA timed out')
    except OSError as exc:
        finish(result_path, 'ERROR', 'environment', f'OS error: {exc}')


if __name__ == '__main__':
    main()
