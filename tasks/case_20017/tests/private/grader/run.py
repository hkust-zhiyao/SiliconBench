#!/usr/bin/env python3
"""Private isolated grader for case_20017 (biriscv 16KB 2-way dcache hard-SRAM + AXI4 + 3-corner SDC/STA)."""
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
PRIV_DIR = TASK_DIR / "private"
PUB_DIR = TASK_DIR / "public"
TOOLS_DIR = pathlib.Path(str(_sb_tools_dir()))
VERILATOR = TOOLS_DIR / "verilator-v5.038" / "bin" / "verilator"
YOSYS = TOOLS_DIR / "oss-cad-suite" / "bin" / "yosys"
SIMCELLS = TOOLS_DIR / "oss-cad-suite" / "share" / "yosys" / "simcells.v"
OPENROAD = TOOLS_DIR / "bin" / "openroad"

EDITABLE_V = [
    pathlib.Path("code/dcache_core.v"),
    pathlib.Path("code/dcache_core_tag_ram.v"),
    pathlib.Path("code/dcache_core_data_ram.v"),
    pathlib.Path("code/dcache_axi_axi.v"),
]
EDITABLE_ALL = [pathlib.Path("constraints/dcache.sdc"), *EDITABLE_V]

ALL_V = [
    "code/dcache_core_tag_ram.v",
    "code/dcache_core_data_ram.v",
    "code/dcache_core.v",
    "code/dcache_if_pmem.v",
    "code/dcache_mux.v",
    "code/dcache_pmem_mux.v",
    "code/dcache_axi_axi.v",
    "code/dcache_axi.v",
    "code/dcache.v",
]


def finish(result_path: pathlib.Path, verdict: str, stage: str, detail: str):
    payload = {"verdict": verdict, "stage": stage, "detail": detail}
    result_path.parent.mkdir(parents=True, exist_ok=True)
    result_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(payload))
    raise SystemExit(0 if verdict == "PASS" else 2 if verdict == "ERROR" else 1)


def sha256_bytes(p: pathlib.Path) -> str:
    return hashlib.sha256(p.read_bytes()).hexdigest()


def strip_v(text: str) -> str:
    text = re.sub(r'(?is)//\s*pragma\s+translate_off.*?//\s*pragma\s+translate_on', '', text)
    return re.sub(r'/\*.*?\*/|//[^\n]*|"(?:\\.|[^"\\])*"', ' ', text, flags=re.S)


def check_sdc_numerics(cand_root: pathlib.Path, result_path: pathlib.Path):
    sdc = re.sub(r'#[^\n]*', ' ', (cand_root / "constraints/dcache.sdc").read_text(encoding="utf-8", errors="replace"))

    def req_vals(pattern: str):
        return [float(x) for x in re.findall(pattern, sdc)]

    su_unc = req_vals(r'set_clock_uncertainty[^\n;]*?-setup\s+([+-]?\d+(?:\.\d+)?)')
    hd_unc = req_vals(r'set_clock_uncertainty[^\n;]*?-hold\s+([+-]?\d+(?:\.\d+)?)')
    clk_tr = req_vals(r'set_clock_transition\s+(?:-[a-z]+\s+)*([+-]?\d+(?:\.\d+)?)')
    in_max = req_vals(r'set_input_delay[^\n;]*?-max\s+([+-]?\d+(?:\.\d+)?)')
    in_min = req_vals(r'set_input_delay[^\n;]*?-min\s+([+-]?\d+(?:\.\d+)?)')
    out_max = req_vals(r'set_output_delay[^\n;]*?-max\s+([+-]?\d+(?:\.\d+)?)')
    out_min = req_vals(r'set_output_delay[^\n;]*?-min\s+([+-]?\d+(?:\.\d+)?)')
    loads = req_vals(r'set_load\s+(?:-[a-z_]+\s+)*([+-]?\d+(?:\.\d+)?)')
    fouts = req_vals(r'set_max_fanout\s+([+-]?\d+(?:\.\d+)?)')
    slews = req_vals(r'set_max_transition\s+([+-]?\d+(?:\.\d+)?)')
    if not su_unc or min(su_unc) < 0.1499 or not hd_unc or min(hd_unc) < 0.0799:
        finish(result_path, "FAIL", "timing", "SDC missing setup (>=0.15) or hold (>=0.08) clock uncertainty")
    if not clk_tr or min(clk_tr) < 0.0999:
        finish(result_path, "FAIL", "timing", "SDC missing set_clock_transition >= 0.10")
    if not re.search(r'set_driving_cell[^\n;]*?-lib_cell\s+sg13g2_buf_4\b', sdc):
        finish(result_path, "FAIL", "timing", "SDC missing set_driving_cell -lib_cell sg13g2_buf_4")
    if not in_max or min(in_max) < 1.7999 or not in_min or max(in_min) > 0.2001:
        finish(result_path, "FAIL", "timing", "SDC input_delay violates max>=1.80 or min<=0.20")
    if not out_max or min(out_max) < 1.7999 or not out_min or max(out_min) > 0.0501:
        finish(result_path, "FAIL", "timing", "SDC output_delay violates max>=1.80 or min<=0.05")
    if not loads or min(loads) < 0.0249:
        finish(result_path, "FAIL", "timing", "SDC set_load must be >= 0.025")
    if not fouts or max(fouts) > 16.001 or not slews or max(slews) > 0.4001:
        finish(result_path, "FAIL", "timing", "SDC missing set_max_fanout <= 16 or set_max_transition <= 0.40")

    lat_lines = [m.group(0) for m in re.finditer(r'set_clock_latency[^\n;]+', sdc)]
    if not lat_lines:
        finish(result_path, "FAIL", "timing", "SDC missing macro A_CLK set_clock_latency in [-0.42, -0.38]")
    for ll in lat_lines:
        if "-source" in ll or "A_CLK" not in ll:
            finish(result_path, "FAIL", "timing", f"Invalid set_clock_latency target in SDC: {ll.strip()}")
        nums = [float(x) for x in re.findall(r'(?<![A-Za-z0-9_])([+-]?\d+(?:\.\d+)?)', ll)]
        if not nums or any(v < -0.4201 or v > -0.3799 for v in nums):
            finish(result_path, "FAIL", "timing", f"set_clock_latency value outside [-0.42, -0.38]: {ll.strip()}")

    for fp in [m.group(0) for m in re.finditer(r'set_false_path[^\n;]+', sdc)]:
        if re.search(r'-(?:to|through|rise_to|fall_to)\b', fp) or not re.search(r'\brst_i\b', fp) or re.search(r'\b(?:all_inputs|all_clocks|clk_i|mem_|axi_)\w*', fp):
            finish(result_path, "FAIL", "timing", f"Disallowed target in set_false_path: {fp.strip()}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--candidate", required=True)
    ap.add_argument("--result", required=True)
    ap.add_argument("--seed", type=int, default=101)
    args, _ = ap.parse_known_args()

    result_path = pathlib.Path(args.result).resolve()
    cand_root = pathlib.Path(args.candidate)
    if cand_root.is_symlink() or not cand_root.is_dir():
        finish(result_path, "FAIL", "input_validation", "Invalid candidate directory")
    cand_root = cand_root.resolve()

    if not VERILATOR.exists() or not YOSYS.exists() or not SIMCELLS.exists() or not OPENROAD.exists():
        finish(result_path, "ERROR", "environment", "Required EDA binary missing")

    edit_set = set(EDITABLE_ALL)
    for rel in EDITABLE_ALL:
        cp = cand_root / rel
        if not cp.is_file() or cp.is_symlink() or not cp.resolve().is_relative_to(cand_root):
            finish(result_path, "FAIL", "policy", f"Missing or symlinked editable file: {rel}")

    for sub in ("code", "constraints", "lib"):
        if (cand_root / sub).exists():
            for pub_p in sorted((PUB_DIR / sub).rglob("*")):
                if not pub_p.is_file():
                    continue
                rel = pub_p.relative_to(PUB_DIR)
                if rel in edit_set:
                    continue
                cand_p = cand_root / rel
                if cand_p.exists() and (cand_p.is_symlink() or sha256_bytes(cand_p) != sha256_bytes(pub_p)):
                    finish(result_path, "FAIL", "policy", f"Read-only file modified: {rel}")

    for rel in EDITABLE_V:
        ct = (cand_root / rel).read_text(encoding="utf-8", errors="replace")
        bt = (PUB_DIR / rel).read_text(encoding="utf-8", errors="replace")
        if len(ct) > 250_000:
            finish(result_path, "FAIL", "policy", f"{rel} exceeds size limit")
        cc, bc = strip_v(ct), strip_v(bt)
        for pat, lbl in [
            (r'\$(?:fopen|fclose|fread|fwrite|fdisplay|fscanf|system|finish|stop|readmemh|readmemb|writememh|writememb|dumpfile|dumpvars|value\$plusargs|test\$plusargs)\b', "forbidden_systask"),
            (r'\b(?:force|release|bind|defparam)\b', "procedural_force_or_bind"),
            (r'\b(?:import|export)\s*"DPI', "dpi_escape"),
            (r'\$root\b|\b(?:tb|u_dut|grader|oracle)\s*\.', "hierarchical_harness_reference"),
            (r'`\s*(?:ifdef|ifndef|elsif)\s+(?:VERILATOR|SYNTHESIS|SIMULATION|__ICARUS__|VCS|QUESTA)\b', "simulator_macro_divergence"),
        ]:
            if len(re.findall(pat, cc, re.I)) > len(re.findall(pat, bc, re.I)):
                finish(result_path, "FAIL", "policy", f"Policy violation in {rel}: {lbl}")
        if len(re.findall(rf'\bmodule\s+{rel.stem}\b', cc)) != 1:
            finish(result_path, "FAIL", "structural", f"Expected single module {rel.stem} in {rel}")

    sdc_raw = (cand_root / "constraints/dcache.sdc").read_text(encoding="utf-8", errors="replace")
    if len(sdc_raw) > 50_000:
        finish(result_path, "FAIL", "policy", "constraints/dcache.sdc exceeds size limit")
    sdc_clean = re.sub(r'#[^\n]*', ' ', sdc_raw)
    for pat, lbl in [
        (r'\b(?:exec|open|socket|source|load|interp|package|file\s+(?:delete|copy|rename|mkdir)|exit)\b', "forbidden_tcl_cmd"),
        (r'\.\.|/tmp/|/tests/|/private/|/root/|/home/', "forbidden_path_escape"),
        (r'\b(?:set_multicycle_path|set_disable_timing|set_case_analysis|set_ideal_network|create_generated_clock|group_path|set_max_delay|set_min_delay)\b', "forbidden_sdc_exception"),
        (r'\b(?:repair_timing|repair_design|read_liberty|read_verilog|write_verilog)\b', "forbidden_flow_cmd_in_sdc"),
    ]:
        if re.search(pat, sdc_clean):
            finish(result_path, "FAIL", "policy", f"Disallowed construct in dcache.sdc: {lbl}")

    try:
        with tempfile.TemporaryDirectory(prefix="case_20017_grade_") as td:
            wdir = pathlib.Path(td)
            for sub in ("code", "lib", "constraints"):
                shutil.copytree(PUB_DIR / sub, wdir / sub)
            for rel in EDITABLE_ALL:
                shutil.copyfile(cand_root / rel, wdir / rel)
            shutil.copyfile(PRIV_DIR / "tests/tb.sv", wdir / "tb.sv")
            (wdir / "build").mkdir(parents=True, exist_ok=True)

            env = {
                "PATH": f"{TOOLS_DIR}/verilator-v5.038/bin:{TOOLS_DIR}/oss-cad-suite/bin:{TOOLS_DIR}/bin:/usr/bin:/bin",
                "HOME": str(wdir), "TMPDIR": str(wdir), "CC": "/usr/bin/gcc", "CXX": "/usr/bin/g++",
            }
            beh_srams = [
                str(wdir / "lib/SRAM_1P_behavioral_bm_bist.v"),
                str(wdir / "lib/RM_IHPSG13_1P_256x64_c2_bm_bist.v"),
            ]
            v_srcs = [str(wdir / p) for p in ALL_V]

            # 1. RTL Verilator simulation
            r_vrtl = subprocess.run([
                str(VERILATOR), "--binary", "-Wno-fatal", "--timing", "-j", "4", "-CFLAGS", "-O0",
                "-DFUNCTIONAL", "--top-module", "tb", "--Mdir", str(wdir / "obj_rtl"),
                *beh_srams, *v_srcs, str(wdir / "tb.sv"),
            ], cwd=wdir, env=env, stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=110)
            if r_vrtl.returncode != 0:
                finish(result_path, "FAIL", "synthesis", f"Verilator RTL build failed:\n{(r_vrtl.stdout + r_vrtl.stderr)[-1200:]}")
            r_srtl = subprocess.run([str(wdir / "obj_rtl/Vtb"), f"+SEED={args.seed}"], cwd=wdir, env=env, stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=55)
            if r_srtl.returncode != 0 or "ALL_TESTS_PASSED" not in r_srtl.stdout:
                finish(result_path, "FAIL", "functional", f"RTL functional simulation failed (seed={args.seed}):\n{(r_srtl.stdout + r_srtl.stderr)[-1200:]}")

            # 2. Yosys synthesis -> dcache_gl.v + dcache_mapped.v
            gl_net = wdir / "build/dcache_gl.v"
            mapped_net = wdir / "build/dcache_mapped.v"
            buf_net = wdir / "build/dcache_buffered.v"
            stub_v = wdir / "lib/RM_IHPSG13_1P_256x64_c2_bm_bist_stub.v"
            std_typ = wdir / "lib/sg13g2_stdcell_typ_1p20V_25C.lib"
            ys_cmd = (
                f"read_verilog {stub_v} {' '.join(v_srcs)}; "
                "hierarchy -check -top dcache; proc; opt; check -assert; "
                "select -assert-none t:$dlatch*; "
                "synth -top dcache -flatten; "
                "design -save flat_generic; rename dcache dcache_gl; opt_clean; "
                f"write_verilog -noattr {gl_net}; design -load flat_generic; "
                f"dfflibmap -liberty {std_typ}; abc -D 2500 -liberty {std_typ}; "
                "hilomap -hicell sg13g2_tiehi L_HI -locell sg13g2_tielo L_LO; "
                "setundef -zero; splitnets -ports; opt_clean -purge; "
                f"write_verilog -noattr -noexpr {mapped_net}"
            )
            r_ys = subprocess.run([str(YOSYS), "-Q", "-T", "-p", ys_cmd], cwd=wdir, env=env, stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=130)
            if r_ys.returncode != 0 or not gl_net.is_file() or not mapped_net.is_file():
                finish(result_path, "FAIL", "synthesis", f"Yosys synthesis failed:\n{(r_ys.stdout + r_ys.stderr)[-1200:]}")

            # 3. Gate-level Verilator parity simulation
            r_vgl = subprocess.run([
                str(VERILATOR), "--binary", "-Wno-fatal", "--timing", "-j", "4", "-CFLAGS", "-O0",
                "-DFUNCTIONAL", "-DDUT_MOD=dcache_gl", "--top-module", "tb", "--Mdir", str(wdir / "obj_gl"),
                str(SIMCELLS), *beh_srams, str(gl_net), str(wdir / "tb.sv"),
            ], cwd=wdir, env=env, stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=130)
            if r_vgl.returncode != 0:
                finish(result_path, "FAIL", "synthesis", f"Gate-level build failed:\n{(r_vgl.stdout + r_vgl.stderr)[-1200:]}")
            r_sgl = subprocess.run([str(wdir / "obj_gl/Vtb"), f"+SEED={args.seed}"], cwd=wdir, env=env, stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=55)
            if r_sgl.returncode != 0 or "ALL_TESTS_PASSED" not in r_sgl.stdout:
                finish(result_path, "FAIL", "functional", f"Gate-level parity simulation failed (seed={args.seed}):\n{(r_sgl.stdout + r_sgl.stderr)[-1200:]}")

            # 4. Native SDC audit + 10-macro check + OpenROAD buffering + 3-corner STA
            check_sdc_numerics(cand_root, result_path)
            audit_tcl = PRIV_DIR / "grader/sta_audit.tcl"
            b_ss_net = wdir / "build/dcache_buf_ss.v"
            b_env = {**env, "MODE": "BUFFER_SS", "CORNER_NAME": "SS", "CORNER_LIB": "lib/sg13g2_stdcell_slow_1p08V_125C.lib",
                     "NETLIST_IN": str(mapped_net), "NETLIST_OUT": str(b_ss_net), "SDC_FILE": "constraints/dcache.sdc"}
            r_buf = subprocess.run([str(OPENROAD), "-exit", str(audit_tcl)], cwd=wdir, env=b_env, stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=90)
            buf_out = r_buf.stdout + "\n" + r_buf.stderr
            if r_buf.returncode != 0 or "AUDIT_FAIL" in buf_out or not b_ss_net.is_file():
                finish(result_path, "FAIL", "timing", f"Hard-SRAM macro count or OpenROAD SS buffering failed:\n{buf_out[-1200:]}")
            bf_env = {**env, "MODE": "BUFFER_FF", "CORNER_NAME": "FF", "CORNER_LIB": "lib/sg13g2_stdcell_fast_1p32V_m40C.lib",
                      "NETLIST_IN": str(b_ss_net), "NETLIST_OUT": str(buf_net), "SDC_FILE": "constraints/dcache.sdc"}
            r_bff = subprocess.run([str(OPENROAD), "-exit", str(audit_tcl)], cwd=wdir, env=bf_env, stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=90)
            if r_bff.returncode != 0 or not buf_net.is_file():
                finish(result_path, "FAIL", "timing", f"OpenROAD FF hold buffering failed:\n{(r_bff.stdout + r_bff.stderr)[-1200:]}")

            corner_summaries = []
            for cname, clib in [
                ("SS", "lib/sg13g2_stdcell_slow_1p08V_125C.lib"),
                ("TT", "lib/sg13g2_stdcell_typ_1p20V_25C.lib"),
                ("FF", "lib/sg13g2_stdcell_fast_1p32V_m40C.lib"),
            ]:
                c_env = {**env, "MODE": "AUDIT_AND_STA", "CORNER_NAME": cname, "CORNER_LIB": clib,
                         "NETLIST_IN": str(buf_net), "NETLIST_OUT": str(buf_net), "SDC_FILE": "constraints/dcache.sdc"}
                r_sta = subprocess.run([str(OPENROAD), "-exit", str(audit_tcl)], cwd=wdir, env=c_env, stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=90)
                out = r_sta.stdout + "\n" + r_sta.stderr
                if r_sta.returncode != 0 or "AUDIT_FAIL" in out:
                    finish(result_path, "FAIL", "timing", f"OpenSTA audit failed in {cname}:\n{out[-1200:]}")
                if cname == "SS":
                    if "AUDIT_PASS" not in out or re.search(r'There are \d+ unconstrained endpoints', out):
                        finish(result_path, "FAIL", "timing", f"Unconstrained endpoints or failed SDC audit:\n{out[-1200:]}")
                    m_in = re.search(r'There (?:is|are) (\d+) input ports? missing set_input_delay\.\s*\n\s*(\S+)', out)
                    if (m_in and (int(m_in.group(1)) > 1 or m_in.group(2) != "rst_i")) or re.search(r'output ports? missing set_output_delay', out):
                        finish(result_path, "FAIL", "timing", f"Ports missing set_input_delay/set_output_delay:\n{out[-1200:]}")
                m = re.search(rf'STA_RESULT_{cname}\s+setup_wns=([+-]?\d+\.\d+)\s+setup_tns=([+-]?\d+\.\d+)\s+hold_wns=([+-]?\d+\.\d+)\s+hold_tns=([+-]?\d+\.\d+)', out)
                if not m:
                    finish(result_path, "FAIL", "timing", f"Missing STA_RESULT_{cname}:\n{out[-800:]}")
                sw, st, hw, ht = (float(m.group(i)) for i in range(1, 5))
                corner_summaries.append(f"{cname}(su={sw:.3f},hd={hw:.3f})")
                if sw < 0.0 or st < -0.0005 or hw < 0.0 or ht < -0.0005:
                    finish(result_path, "FAIL", "timing", f"Corner {cname} failed signoff: setup_wns={sw:.4f}, setup_tns={st:.4f}, hold_wns={hw:.4f}, hold_tns={ht:.4f}")

            finish(result_path, "PASS", "all_gates", f"Passed RTL+GL co-sim (seed={args.seed}) and 10-macro 3-corner STA: " + ", ".join(corner_summaries))
    except subprocess.TimeoutExpired as exc:
        finish(result_path, "FAIL", "timeout", f"Timed out: {exc}")


if __name__ == "__main__":
    main()
