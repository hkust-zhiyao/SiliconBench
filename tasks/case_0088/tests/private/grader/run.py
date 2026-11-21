#!/usr/bin/env python3
"""Trusted isolated grader for case_0088 (TCDM 2-channel crossbar stall lock, bounded fairness, atomic write-data forwarding, and Nangate45 PPA/STA)."""
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

EDITABLE_FILES = ('ArbitrationTree.sv', 'MUX2_REQ.sv', 'TestAndSet.sv')
FIXED_CODE_FILES = (
    'parameters.v',
    'FanInPrimitive_Req.sv',
    'priority_Flag_Req.sv',
    'AddressDecoder_Resp.sv',
    'RequestBlock2CH.sv',
)
FIXED_LIB_FILES = (
    'NangateOpenCellLibrary_typical.lib',
    'NangateOpenCellLibrary.tech.lef',
    'NangateOpenCellLibrary.macro.mod.lef',
    'LICENSE.Nangate45',
)

AREA_LIMIT_UM2 = 2705.0
MIN_SETUP_SLACK_NS = 0.60
MIN_HOLD_SLACK_NS = 0.00


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
    return re.sub(r'/\*.*?\*/|//[^\n]*|"(?:\\.|[^"\\])*"', ' ', text, flags=re.S)


def screen_rtl(filename: str, raw: str, result_path: pathlib.Path):
    if len(raw.encode('utf-8')) > 500_000:
        finish(result_path, 'FAIL', 'policy', f'{filename}: exceeds size limit')
    if re.search(r'(?i)(?:pragma|synthesis|synopsys|verilator)\s+(?:translate_)?(?:on|off)', raw):
        finish(result_path, 'FAIL', 'policy', f'{filename}: prohibited pragma translate_off/on')

    cleaned = strip_comments_and_strings(raw)
    escape_pats = [
        (r'\$(?!clog2\b|bits\b|signed\b|unsigned\b|size\b)[a-zA-Z_][\w$]*', 'forbidden_systask'),
        (r'\b(?:force|release|bind|defparam|initial|final|fork|join|join_any|join_none|wait|always_latch)\b', 'procedural_force_or_sim_construct'),
        (r'\b(?:import|export)\s*"DPI', 'dpi_escape'),
        (r'\$root\b|\b(?:tb|dut|grader|oracle|golden_ref)\s*\.', 'hierarchical_harness_reference'),
        (r'`\s*(?:ifdef|ifndef|elsif)\s+(?!GNT_BASED_FC\b)\w+', 'simulator_or_synthesis_macro_divergence'),
        (r'`\s*(?:define|undef)\b', 'prohibited_macro_definition'),
        (r'`\s*include\s+"(?!parameters\.v")[^"]+"', 'unauthorized_include'),
        (r'#\s*\d', 'prohibited_delay_control'),
    ]
    for pat, label in escape_pats:
        if re.search(pat, cleaned, re.I):
            finish(result_path, 'FAIL', 'policy', f'Policy violation in {filename}: {label}')

    expected_mod = filename[:-3]
    declared_mods = re.findall(r'\bmodule\s+([a-zA-Z_]\w*)\b', cleaned)
    if expected_mod not in declared_mods:
        finish(result_path, 'FAIL', 'structural', f'Expected module {expected_mod} in {filename}')
    forbidden_redefs = {
        'RequestBlock2CH',
        'FanInPrimitive_Req',
        'priority_Flag_Req',
        'AddressDecoder_Resp',
        'tb',
        *(f[:-3] for f in EDITABLE_FILES if f != filename),
    }
    bad_mods = [m for m in declared_mods if m in forbidden_redefs]
    if bad_mods:
        finish(result_path, 'FAIL', 'structural', f'Redefinition of protected/external module {bad_mods[0]} in {filename}')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--candidate', required=True)
    ap.add_argument('--seed', type=int, required=True)
    ap.add_argument('--result', required=True)
    args = ap.parse_args()

    result_path = pathlib.Path(args.result).resolve()
    cand_in = pathlib.Path(args.candidate)
    if not cand_in.is_absolute() or any(x.is_symlink() for x in (cand_in, *cand_in.parents)) or not cand_in.is_dir():
        finish(result_path, 'FAIL', 'input_validation', 'Candidate must be an absolute non-symlink directory')
    cand_root = cand_in.resolve()

    # Verify protected code and library files if present in candidate
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
    for edit_name in EDITABLE_FILES:
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
        with tempfile.TemporaryDirectory(prefix='case_0088_grade_') as tmp:
            td = pathlib.Path(tmp)
            src = td / 'code'
            src.mkdir()
            for fname in FIXED_CODE_FILES:
                shutil.copyfile(PUB_CODE / fname, src / fname)
            for fname, text in cand_sources.items():
                (src / fname).write_text(text, encoding='utf-8')
            shutil.copyfile(PRIV_DIR / 'tests' / 'tb.sv', td / 'tb.sv')

            # 1. Yosys latch-free cleanliness check
            ys_latch = (
                f'read_verilog -sv -I{src} '
                f'{src / "ArbitrationTree.sv"} {src / "FanInPrimitive_Req.sv"} '
                f'{src / "priority_Flag_Req.sv"} {src / "MUX2_REQ.sv"} '
                f'{src / "TestAndSet.sv"} {src / "AddressDecoder_Resp.sv"} '
                f'{src / "RequestBlock2CH.sv"}; '
                'hierarchy -check -top RequestBlock2CH -chparam N_CH0 4 -chparam N_CH1 2; '
                'proc; opt_clean; '
                'select -assert-none t:$dlatch* t:$adlatch* t:$latch* t:$sr*'
            )
            r_latch = subprocess.run(
                [str(YOSYS_BIN), '-q', '-p', ys_latch],
                cwd=td,
                env=env,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                timeout=120,
            )
            if r_latch.returncode != 0:
                finish(result_path, 'FAIL', 'synthesis', f'Yosys latch-free synthesis check failed:\n{r_latch.stdout[-1500:].strip()}')

            # 2. Verilator behavioral verification across (N_CH0, N_CH1) configurations
            cfg_pairs = [(4, 2), (3, 2), (8, 4)] if (args.seed % 2 == 1) else [(8, 4), (4, 2), (3, 2)]
            seed_val = (args.seed & 0x7fffffff) or 1
            for n0, n1 in cfg_pairs:
                obj_dir = td / f'obj_{n0}_{n1}'
                cmd = [
                    str(VERILATOR_BIN),
                    '--binary',
                    '--timing',
                    '-j', '1',
                    '-Wno-fatal',
                    '--top-module', 'tb',
                    f'-GN0={n0}',
                    f'-GN1={n1}',
                    f'-GSEED={seed_val + n0 * 7 + n1}',
                    '--Mdir', str(obj_dir),
                    f'+incdir+{src}',
                    str(src / 'RequestBlock2CH.sv'),
                    str(src / 'ArbitrationTree.sv'),
                    str(src / 'FanInPrimitive_Req.sv'),
                    str(src / 'priority_Flag_Req.sv'),
                    str(src / 'MUX2_REQ.sv'),
                    str(src / 'TestAndSet.sv'),
                    str(src / 'AddressDecoder_Resp.sv'),
                    str(td / 'tb.sv'),
                ]
                build = subprocess.run(cmd, cwd=td, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=180)
                if build.returncode != 0:
                    finish(result_path, 'FAIL', 'compile', f'Verilator elaboration failed (N0={n0}, N1={n1}):\n{build.stdout[-1500:].strip()}')

                sim = subprocess.run([str(obj_dir / 'Vtb')], cwd=td, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=60)
                if sim.returncode != 0 or f'PASS_2CH N0={n0} N1={n1}' not in sim.stdout:
                    finish(
                        result_path,
                        'FAIL',
                        'behavior',
                        f'Simulation failed for (N0={n0}, N1={n1}):\n{sim.stdout[-1500:].strip()}',
                        tested_config=[n0, n1],
                    )

            # 3. Yosys/Slang + ABC synthesis on Nangate45 at N_CH0=8, N_CH1=4, ADDR_MEM_WIDTH=32, DATA_WIDTH=32
            lib_file = PUB_LIB / 'NangateOpenCellLibrary_typical.lib'
            tech_lef = PUB_LIB / 'NangateOpenCellLibrary.tech.lef'
            macro_lef = PUB_LIB / 'NangateOpenCellLibrary.macro.mod.lef'
            mapped_v = td / 'mapped.v'
            ys_synth = td / 'synth.ys'
            ys_synth.write_text(
                f'read_slang --top RequestBlock2CH -G N_CH0=8 -G N_CH1=4 -G ADDR_MEM_WIDTH=32 -G DATA_WIDTH=32 -I {src} '
                f'{src / "ArbitrationTree.sv"} {src / "FanInPrimitive_Req.sv"} {src / "priority_Flag_Req.sv"} '
                f'{src / "MUX2_REQ.sv"} {src / "TestAndSet.sv"} {src / "AddressDecoder_Resp.sv"} {src / "RequestBlock2CH.sv"}\n'
                f'hierarchy -check -top RequestBlock2CH\n'
                f'synth -top RequestBlock2CH\n'
                f'opt\n'
                f'dfflibmap -liberty {lib_file}\n'
                f'abc -liberty {lib_file}\n'
                f'clean\n'
                f'read_liberty -lib {lib_file}\n'
                f'check -assert\n'
                f'stat -liberty {lib_file}\n'
                f'write_verilog -noattr {mapped_v}\n'
            )
            r_syn = subprocess.run([str(YOSYS_BIN), '-Q', '-T', '-m', 'slang', str(ys_synth)], cwd=td, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=180)
            m_area = re.search(r'Chip area for module .*?:\s*([\d.]+)', r_syn.stdout)
            if r_syn.returncode != 0 or not m_area or not mapped_v.is_file():
                finish(result_path, 'FAIL', 'synthesis', f'Yosys/Slang Nangate45 synthesis failed:\n{r_syn.stdout[-1500:].strip()}')

            area_um2 = round(float(m_area.group(1)), 3)
            if area_um2 > AREA_LIMIT_UM2:
                finish(
                    result_path,
                    'FAIL',
                    'area',
                    f'Mapped cell area {area_um2:.3f} um^2 exceeds limit {AREA_LIMIT_UM2:.1f} um^2',
                    area_um2=area_um2,
                    area_limit_um2=AREA_LIMIT_UM2,
                )

            # 4. OpenROAD placement-estimated STA at 2.85 ns clock period
            sta_v = td / 'sta.v'
            sta_v.write_text(mapped_v.read_text().replace(' signed ', ' '))
            flow_tcl = td / 'flow.tcl'
            flow_tcl.write_text(
                f'set_thread_count 1\n'
                f'read_lef {tech_lef}\n'
                f'read_lef {macro_lef}\n'
                f'read_liberty {lib_file}\n'
                f'read_verilog {sta_v}\n'
                f'link_design RequestBlock2CH\n'
                f'initialize_floorplan -die_area {{0 0 220 220}} -core_area {{10 10 210 210}} -site FreePDK45_38x28_10R_NP_162NW_34O\n'
                f'create_clock -name clk -period 2.85 [get_ports clk]\n'
                f'set_input_delay 0.2 -clock clk [get_ports {{data_req* data_add* data_wen* data_wdata* data_be* data_ID* data_gnt_i data_r_* TCDM_arb_policy_i*}}]\n'
                f'set_output_delay 0.2 -clock clk [all_outputs]\n'
                f'set_load 5.0 [all_outputs]\n'
                f'make_tracks\n'
                f'place_pins -hor_layers metal3 -ver_layers metal2\n'
                f'set_wire_rc -signal -layer metal3\n'
                f'set_wire_rc -clock -layer metal3\n'
                f'global_placement -density 0.5\n'
                f'estimate_parasitics -placement\n'
                f'report_checks -path_delay max -format full_clock_expanded\n'
                f'report_checks -path_delay min -format full_clock_expanded\n'
                f'puts "WNS [sta::worst_slack -max]"\n'
                f'puts "WHS [sta::worst_slack -min]"\n'
            )
            r_or = subprocess.run([str(OPENROAD_BIN), '-exit', str(flow_tcl)], cwd=td, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=240)
            if r_or.returncode != 0:
                finish(result_path, 'FAIL', 'timing', f'OpenROAD placement STA failed:\n{r_or.stdout[-1500:].strip()}', area_um2=area_um2)

            m_wns = re.search(r'WNS\s+([-+0-9.eE]+)', r_or.stdout)
            m_whs = re.search(r'WHS\s+([-+0-9.eE]+)', r_or.stdout)
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
                    f'Worst setup slack {wns_ns:.4f} ns < {MIN_SETUP_SLACK_NS:.2f} ns at 2.85 ns clock',
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
                f'PASS 2-channel TCDM functional, latch-free, area ({area_um2:.3f} um^2 <= {AREA_LIMIT_UM2:.1f}), and STA (WNS={wns_ns:.4f} ns, WHS={whs_ns:.4f} ns)',
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
