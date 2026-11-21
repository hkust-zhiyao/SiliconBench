#!/usr/bin/env python3
"""Private isolated grader for case_23014 (Vortex 2-Bank Sectored GPU L1 Cache + 10-SRAM PnR)."""
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
OPENROAD = TOOLS_DIR / "bin" / "openroad"

EDITABLE_RTL = {
    pathlib.Path("code/VX_cache_repl.sv"): "VX_cache_repl",
    pathlib.Path("code/VX_cache_tags.sv"): "VX_cache_tags",
    pathlib.Path("code/VX_cache_data.sv"): "VX_cache_data",
}
EDITABLE_ALL = list(EDITABLE_RTL.keys()) + [
    pathlib.Path("plan/macro_placement.json"),
    pathlib.Path("constraints/cache_subsys.sdc"),
]

SV_SRCS = [
    "VX_gpu_pkg.sv", "VX_mem_bus_if.sv",
    "VX_scan.sv", "VX_find_first.sv", "VX_lzc.sv", "VX_bits_concat.sv", "VX_reduce_tree.sv",
    "VX_onehot_encoder.sv", "VX_onehot_mux.sv", "VX_mux.sv", "VX_demux.sv", "VX_transpose.sv",
    "VX_priority_arbiter.sv", "VX_priority_encoder.sv", "VX_popcount.sv",
    "VX_rr_arbiter.sv", "VX_matrix_arbiter.sv", "VX_cyclic_arbiter.sv", "VX_generic_arbiter.sv",
    "VX_pipe_register.sv", "VX_pipe_buffer.sv", "VX_elastic_buffer.sv", "VX_skid_buffer.sv", "VX_stream_buffer.sv",
    "VX_shift_register.sv", "VX_pending_size.sv", "VX_fifo_queue.sv", "VX_index_buffer.sv", "VX_allocator.sv",
    "VX_dp_ram_asic.v", "VX_sp_ram_asic.v", "VX_async_ram_patch.sv", "VX_dp_ram.sv", "VX_sp_ram.sv",
    "VX_stream_arb.sv", "VX_stream_switch.sv", "VX_stream_xpoint.sv", "VX_stream_omega.sv", "VX_stream_xbar.sv",
    "VX_stream_pack.sv", "VX_stream_unpack.sv", "VX_stream_fork.sv", "VX_stream_join.sv", "VX_stream_dispatch.sv",
    "VX_amo_alu.sv", "VX_amo_unit.sv",
    "VX_cache_init.sv", "VX_cache_flush.sv", "VX_cache_amo.sv", "VX_cache_mshr.sv",
    "VX_cache_repl.sv", "VX_cache_tags.sv", "VX_cache_data.sv",
    "VX_cache_bank.sv", "VX_cache.sv", "VX_cache_subsys.sv",
]

EXPECTED_MACROS = (
    {f"u_cache.u_bank_{b}.cache_tags.u_tag_sram" for b in range(2)}
    | {f"u_cache.u_bank_{b}.cache_data.u_data_slice_{s}" for b in range(2) for s in range(4)}
)
MACRO_W = 784.48
MACRO_H = 118.78
CORE_X0, CORE_Y0, CORE_X1, CORE_Y1 = 50.0, 50.0, 2550.0, 2150.0
CORE_MARGIN = 2.0
MACRO_HALO = 8.0
LEGAL_ORIENTS = {"R0", "R180", "MX", "MY"}

SIGNOFF_PERIOD_MAX = 17.0
SIGNOFF_IO_DELAY_MIN = 1.5
MAX_GRT_OVERFLOW = 25
MAX_GRT_WIRELENGTH = 6200000.0


def finish(result_path, verdict: str, stage: str, detail: str, metrics=None):
    payload = {"verdict": verdict, "stage": stage, "detail": detail[:4000]}
    if metrics:
        payload["metrics"] = metrics
    if result_path is not None:
        result_path.parent.mkdir(parents=True, exist_ok=True)
        result_path.write_text(json.dumps(payload, indent=2) + "\n")
    print(json.dumps(payload))
    raise SystemExit(0 if verdict == "PASS" else 2 if verdict == "ERROR" else 1)


def sha256_bytes(p: pathlib.Path) -> str:
    return hashlib.sha256(p.read_bytes()).hexdigest()


def strip_comments_and_strings(text: str) -> str:
    text = re.sub(r"(?is)//\s*pragma\s+translate_off.*?//\s*pragma\s+translate_on", "", text)
    text = re.sub(r"/\*.*?\*/|//[^\n]*|\"(?:\\.|[^\"\\])*\"", " ", text, flags=re.S)
    return text


def screen_rtl_source(rel: pathlib.Path, mod_name: str, cand_text: str, base_text: str, result_path):
    if len(cand_text.encode("utf-8")) > 500_000:
        finish(result_path, "FAIL", "policy", f"Editable RTL {rel} exceeds size limit")

    cand_clean = strip_comments_and_strings(cand_text)
    base_clean = strip_comments_and_strings(base_text)

    escape_pats = [
        (r"\$(?:fopen|fclose|fread|fwrite|fdisplay|fscanf|system|finish|stop|fatal|readmemh|readmemb|writememh|writememb|dumpfile|dumpvars|value\$plusargs|test\$plusargs)\b", "forbidden_systask"),
        (r"\b(?:force|release|bind|defparam|deassign)\b", "procedural_force_or_bind"),
        (r"\b(?:import|export)\s*\"DPI", "dpi_escape"),
        (r"\$root\b|\b(?:tb|dut|grader|backing_mem|macro_men|mrsp_q)\b", "hierarchical_harness_reference"),
        (r"`\s*(?:ifdef|ifndef|elsif)\s+(?:VERILATOR|SYNTHESIS|SIMULATION|__ICARUS__|IVERILOG|VCS|QUESTA)\b", "simulator_macro_divergence"),
    ]
    for pat, label in escape_pats:
        if len(re.findall(pat, cand_clean, re.I)) > len(re.findall(pat, base_clean, re.I)):
            finish(result_path, "FAIL", "policy", f"Policy violation in {rel}: {label}")

    if mod_name == "VX_cache_repl":
        if len(re.findall(rf"\bmodule\s+{mod_name}\b", cand_clean)) != 1:
            finish(result_path, "FAIL", "structural", f"Expected module declaration `{mod_name}` in {rel}")
    else:
        if len(re.findall(rf"\bmodule\s+{mod_name}\b", cand_clean)) != 1 or len(re.findall(r"\bmodule\b", cand_clean)) != 1:
            finish(result_path, "FAIL", "structural", f"Expected exactly one module declaration `{mod_name}` in {rel}")

    if mod_name == "VX_cache_tags":
        if not re.search(r"\bRM_IHPSG13_1P_256x64_c2_bm_bist\s+u_tag_sram\b", cand_clean):
            finish(result_path, "FAIL", "policy", f"Missing required hard SRAM macro instance u_tag_sram in {rel}")
    elif mod_name == "VX_cache_data":
        for idx in range(4):
            if not re.search(rf"\bRM_IHPSG13_1P_256x64_c2_bm_bist\s+u_data_slice_{idx}\b", cand_clean):
                finish(result_path, "FAIL", "policy", f"Missing required hard SRAM macro instance u_data_slice_{idx} in {rel}")


def validate_macro_plan(plan_text: str, result_path):
    try:
        data = json.loads(plan_text)
    except Exception as e:
        finish(result_path, "FAIL", "geometry", f"Invalid JSON in plan/macro_placement.json: {e}")

    macros = data.get("macros") if isinstance(data, dict) else None
    if not isinstance(macros, list) or len(macros) != 10:
        finish(result_path, "FAIL", "geometry", "macro_placement.json must contain a 'macros' list of 10 entries")

    seen = {}
    boxes = []
    for entry in macros:
        if not isinstance(entry, dict):
            finish(result_path, "FAIL", "geometry", "Each macro entry must be a JSON object")
        inst = entry.get("instance")
        orient = entry.get("orientation")
        try:
            x = float(entry.get("x"))
            y = float(entry.get("y"))
        except Exception:
            finish(result_path, "FAIL", "geometry", f"Non-numeric coordinates for macro {inst}")
        if inst not in EXPECTED_MACROS:
            finish(result_path, "FAIL", "geometry", f"Unexpected macro instance '{inst}'")
        if inst in seen:
            finish(result_path, "FAIL", "geometry", f"Duplicate macro instance '{inst}'")
        if orient not in LEGAL_ORIENTS:
            finish(result_path, "FAIL", "geometry", f"Illegal orientation '{orient}' for {inst}")
        if (x < CORE_X0 + CORE_MARGIN or y < CORE_Y0 + CORE_MARGIN or
                x + MACRO_W > CORE_X1 - CORE_MARGIN or y + MACRO_H > CORE_Y1 - CORE_MARGIN):
            finish(result_path, "FAIL", "geometry", f"Macro {inst} at ({x}, {y}) extends outside core boundary margin")
        seen[inst] = (x, y, orient)
        boxes.append((inst, x, y, x + MACRO_W, y + MACRO_H))

    for i in range(len(boxes)):
        n1, x1a, y1a, x1b, y1b = boxes[i]
        for j in range(i + 1, len(boxes)):
            n2, x2a, y2a, x2b, y2b = boxes[j]
            ox = min(x1b + MACRO_HALO, x2b) - max(x1a - MACRO_HALO, x2a)
            oy = min(y1b + MACRO_HALO, y2b) - max(y1a - MACRO_HALO, y2a)
            if ox > 0.0 and oy > 0.0:
                finish(result_path, "FAIL", "geometry", f"Macros {n1} and {n2} violate {MACRO_HALO} um halo spacing")
    return seen


def validate_sdc(sdc_text: str, result_path):
    joined = re.sub(r"\\\s*\n", " ", sdc_text)
    forbidden_sdc = re.compile(
        r"\b(set_multicycle_path|set_max_delay|set_min_delay|set_clock_groups|"
        r"set_disable_timing|set_case_analysis|set_ideal_network|set_ideal_latency|"
        r"set_clock_latency|group_path)\b"
    )
    if forbidden_sdc.search(joined):
        finish(result_path, "FAIL", "timing", "Forbidden timing exception or override in constraints/cache_subsys.sdc")

    vars_map = {}
    has_clk = False
    has_in_dly = False
    has_out_dly = False

    for raw_line in joined.splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        for k, v in vars_map.items():
            line = line.replace("$" + k, v).replace("${" + k + "}", v)
        tokens = line.split()
        cmd = tokens[0]
        if cmd == "set" and len(tokens) == 3:
            vars_map[tokens[1]] = tokens[2]
        elif cmd == "create_clock":
            if not re.search(r"\bclk\b", line):
                finish(result_path, "FAIL", "timing", "create_clock must target port clk")
            m = re.search(r"-period\s+([0-9]+(?:\.[0-9]+)?)", line)
            if not m:
                finish(result_path, "FAIL", "timing", "create_clock missing numeric -period")
            period = float(m.group(1))
            if period < 1.0 or period > SIGNOFF_PERIOD_MAX:
                finish(result_path, "FAIL", "timing", f"Clock period {period} ns violates signoff limit <= {SIGNOFF_PERIOD_MAX} ns")
            has_clk = True
        elif cmd == "set_input_delay":
            m = re.search(r"set_input_delay\s+(?:-[a-z_]+\s+)*([0-9]+(?:\.[0-9]+)?)", line)
            if not m or float(m.group(1)) < SIGNOFF_IO_DELAY_MIN:
                finish(result_path, "FAIL", "timing", f"set_input_delay must be >= {SIGNOFF_IO_DELAY_MIN} ns")
            has_in_dly = True
        elif cmd == "set_output_delay":
            m = re.search(r"set_output_delay\s+(?:-[a-z_]+\s+)*([0-9]+(?:\.[0-9]+)?)", line)
            if not m or float(m.group(1)) < SIGNOFF_IO_DELAY_MIN:
                finish(result_path, "FAIL", "timing", f"set_output_delay must be >= {SIGNOFF_IO_DELAY_MIN} ns")
            has_out_dly = True
        elif cmd == "set_false_path":
            if not re.fullmatch(r"set_false_path\s+-from\s+\[\s*get_ports\s+\{?reset\}?\s*\]", line):
                finish(result_path, "FAIL", "timing", f"Only reset may carry set_false_path; got: {line}")
        elif cmd in {"set_clock_uncertainty", "set_clock_transition", "set_driving_cell", "set_load"}:
            pass
        else:
            finish(result_path, "FAIL", "timing", f"Unsupported SDC command in cache_subsys.sdc: {cmd}")

    if not (has_clk and has_in_dly and has_out_dly):
        finish(result_path, "FAIL", "timing", "cache_subsys.sdc must define create_clock, set_input_delay, and set_output_delay")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--candidate", required=True)
    ap.add_argument("--seed", type=int, default=101)
    ap.add_argument("--result", default=None)
    ap.add_argument("--skip-pnr", action="store_true")
    args, _ = ap.parse_known_args()

    result_path = pathlib.Path(args.result).resolve() if args.result else None
    cand_root = pathlib.Path(args.candidate)
    if cand_root.is_symlink() or not cand_root.is_dir():
        finish(result_path, "FAIL", "input_validation", "Invalid or symlinked candidate directory")
    cand_root = cand_root.resolve()

    edit_set = set(EDITABLE_ALL)
    cand_texts = {}
    for rel in EDITABLE_ALL:
        if (cand_root / rel).exists():
            c_file = cand_root / rel
        elif (cand_root / rel.name).exists():
            c_file = cand_root / rel.name
        else:
            finish(result_path, "FAIL", "input_validation", f"Missing editable file {rel}")
        if c_file.is_symlink() or not c_file.is_file() or not c_file.resolve().is_relative_to(cand_root):
            finish(result_path, "FAIL", "input_validation", f"Invalid or symlinked editable file {rel}")
        cand_texts[rel] = c_file.read_text(encoding="utf-8", errors="replace")

    for sub in ("code", "pdk"):
        if (cand_root / sub).is_dir():
            present_non_edit = [
                p for p in (cand_root / sub).rglob("*")
                if p.is_file() and p.relative_to(cand_root) not in edit_set
            ]
            if present_non_edit:
                for ref_file in sorted((PUB_DIR / sub).rglob("*")):
                    if not ref_file.is_file():
                        continue
                    rel = ref_file.relative_to(PUB_DIR)
                    if rel in edit_set:
                        continue
                    c_file = cand_root / rel
                    if not c_file.is_file() or c_file.is_symlink() or sha256_bytes(c_file) != sha256_bytes(ref_file):
                        finish(result_path, "FAIL", "policy", f"Read-only file modified or missing: {rel}")

    for rel, mod_name in EDITABLE_RTL.items():
        base_text = (PUB_DIR / rel).read_text(encoding="utf-8")
        screen_rtl_source(rel, mod_name, cand_texts[rel], base_text, result_path)

    try:
        with tempfile.TemporaryDirectory(prefix="case_23014_grade_") as td:
            work = pathlib.Path(td)
            for sub in ("code", "pdk", "plan", "constraints"):
                (work / sub).mkdir(parents=True, exist_ok=True)
            for sub in ("code", "pdk"):
                for ref_file in sorted((PUB_DIR / sub).iterdir()):
                    if ref_file.is_file():
                        shutil.copyfile(ref_file, work / sub / ref_file.name)
            for rel, txt in cand_texts.items():
                (work / rel).write_text(txt, encoding="utf-8")

            tb_path = work / "tb.sv"
            shutil.copyfile(PRIV_DIR / "tests" / "tb.sv", tb_path)

            env = {
                "PATH": f"{TOOLS_DIR}/verilator-v5.038/bin:{TOOLS_DIR}/oss-cad-suite/bin:{TOOLS_DIR}/bin:/usr/bin:/bin",
                "HOME": str(work),
                "TMPDIR": str(work),
            }

            obj_dir = work / "obj_dir"
            sim_bin = obj_dir / "Vtb"
            comp_cmd = [
                str(VERILATOR), "-sv", "-DSYNTHESIS", "-DXLEN_32", "-DFUNCTIONAL",
                "-Wno-fatal", "--timing", "--binary", "-j", "4", "-CFLAGS", "-O0",
                f"-I{work / 'code'}", "--top-module", "tb", "--Mdir", str(obj_dir),
                str(work / "pdk/core.v"), str(work / "pdk/256.v"),
                *[str(work / "code" / s) for s in SV_SRCS],
                str(tb_path),
            ]
            r_comp = subprocess.run(comp_cmd, cwd=work, env=env, capture_output=True, text=True, timeout=180)
            if r_comp.returncode != 0 or not sim_bin.is_file():
                tail = (r_comp.stdout + "\n" + r_comp.stderr).strip()[-1800:]
                finish(result_path, "FAIL", "compile", f"Verilator compile failed: {tail}")

            r_sim = subprocess.run([str(sim_bin), f"+SEED={args.seed}"], cwd=work, env=env, capture_output=True, text=True, timeout=120)
            sim_out = (r_sim.stdout + "\n" + r_sim.stderr).strip()
            if r_sim.returncode != 0 or f"PASS_CACHE_SUBSYS seed={args.seed}" not in sim_out or "FAIL_CACHE" in sim_out:
                finish(result_path, "FAIL", "functional", f"Simulation failed (seed={args.seed}): {sim_out[-1800:]}")

            macro_map = validate_macro_plan(cand_texts[pathlib.Path("plan/macro_placement.json")], result_path)
            validate_sdc(cand_texts[pathlib.Path("constraints/cache_subsys.sdc")], result_path)

            mapped_v = work / "mapped.v"
            src_args = " ".join([str(work / "pdk/256_stub.v")] + [str(work / "code" / s) for s in SV_SRCS])
            ys_script = "\n".join([
                f"read_slang -DSYNTHESIS -DXLEN_32 -I{work / 'code'} {src_args} --top VX_cache_subsys",
                "hierarchy -check -top VX_cache_subsys",
                "synth -top VX_cache_subsys -flatten",
                "delete t:$scopeinfo",
                f"dfflibmap -liberty {work / 'pdk/sg13g2_stdcell_typ_1p20V_25C.lib'}",
                f"abc -liberty {work / 'pdk/sg13g2_stdcell_typ_1p20V_25C.lib'}",
                "setundef -zero",
                "splitnets -ports",
                "opt_clean -purge",
                f"stat -liberty {work / 'pdk/sg13g2_stdcell_typ_1p20V_25C.lib'}",
                f"write_verilog -noattr -noexpr -nohex {mapped_v}",
            ])
            ys_file = work / "synth.ys"
            ys_file.write_text(ys_script + "\n", encoding="utf-8")
            r_syn = subprocess.run([str(YOSYS), "-m", "slang", "-s", str(ys_file)], cwd=work, env=env, capture_output=True, text=True, timeout=300)
            yout = r_syn.stdout + "\n" + r_syn.stderr
            if r_syn.returncode != 0 or not mapped_v.is_file():
                finish(result_path, "FAIL", "synthesis", f"Yosys synthesis failed: {yout[-1800:]}")
            stat_sec = yout.split("Printing statistics.")[-1] if "Printing statistics." in yout else yout
            if re.search(r"\$_DLATCH_|sg13g2_dlhr|sg13g2_dlhq|sg13g2_dllr", stat_sec):
                finish(result_path, "FAIL", "synthesis", "Inferred latches detected during Yosys synthesis")
            m_sram = re.search(r"(\d+)\s+\S+\s+RM_IHPSG13_1P_256x64_c2_bm_bist", stat_sec)
            sram_cnt = int(m_sram.group(1)) if m_sram else 0
            if sram_cnt != 10:
                finish(result_path, "FAIL", "synthesis", f"Expected 10 RM_IHPSG13_1P_256x64_c2_bm_bist macros, found {sram_cnt}")

            if args.skip_pnr or args.seed != 101:
                finish(
                    result_path,
                    "PASS",
                    "functional",
                    f"RTL functional simulation, SDC/floorplan checks, and synthesis passed for seed={args.seed}",
                    {"sram_macros": sram_cnt, "pnr_skipped": True},
                )

            place_lines = [
                "place_macro -macro_name {" + inst + "} -location {" + f"{macro_map[inst][0]:.2f} {macro_map[inst][1]:.2f}" + "} -orientation " + macro_map[inst][2]
                for inst in sorted(macro_map.keys())
            ]
            tcl_lines = [
                "set_thread_count 4",
                f'set pdk "{work / "pdk"}"',
                "read_lef $pdk/sg13g2_tech.lef",
                "read_lef $pdk/sg13g2_stdcell.lef",
                "read_lef $pdk/256.lef",
                "read_liberty $pdk/sg13g2_stdcell_typ_1p20V_25C.lib",
                "read_liberty $pdk/256.lib",
                f'read_verilog "{mapped_v}"',
                "link_design VX_cache_subsys",
                "initialize_floorplan -die_area {0 0 2600 2200} -core_area {50 50 2550 2150} -site CoreSite",
                "foreach layer {Metal1 Metal2 Metal3 Metal4 Metal5} {make_tracks $layer -x_offset 0 -x_pitch 0.48 -y_offset 0 -y_pitch 0.42}",
                "make_tracks TopMetal1 -x_offset 1.64 -x_pitch 3.28 -y_offset 1.64 -y_pitch 3.28",
                "make_tracks TopMetal2 -x_offset 2 -x_pitch 4 -y_offset 2 -y_pitch 4",
                *place_lines,
                "cut_rows -halo_width_x 2.0 -halo_width_y 2.0 -row_min_width 25.0",
                "add_global_connection -net VDD -inst_pattern {.*} -pin_pattern {VDD} -power",
                "add_global_connection -net VSS -inst_pattern {.*} -pin_pattern {VSS} -ground",
                "add_global_connection -net VDD -inst_pattern {.*} -pin_pattern {VDD!} -power",
                "add_global_connection -net VDD -inst_pattern {.*} -pin_pattern {VDDARRAY!} -power",
                "add_global_connection -net VSS -inst_pattern {.*} -pin_pattern {VSS!} -ground",
                "global_connect",
                "set_voltage_domain -name CORE -power VDD -ground VSS",
                "define_pdn_grid -name core -voltage_domains CORE -pins {TopMetal2}",
                "add_pdn_ring -grid core -layer {TopMetal1 TopMetal2} -widths {10 10} -spacings {5 5} -core_offsets {2 2} -add_connect",
                "add_pdn_stripe -grid core -layer Metal1 -width 0.44 -followpins -extend_to_core_ring",
                "add_pdn_stripe -grid core -layer TopMetal2 -width 6 -pitch 138 -spacing 48 -offset 40 -extend_to_core_ring",
                "add_pdn_connect -grid core -layers {Metal1 TopMetal2}",
                "define_pdn_grid -macro -cells {RM_IHPSG13_1P_256x64_c2_bm_bist} -name sram -orient {R0 R180 MY MX} -grid_over_boundary -voltage_domains {CORE} -halo {2 2}",
                "add_pdn_ring -grid sram -layer {Metal3 Metal4} -widths {2 2} -spacings {0.6 0.6} -core_offsets {2 0.6} -add_connect",
                "add_pdn_stripe -grid sram -layer TopMetal1 -width 8 -spacing 5 -pitch 60 -offset 20 -extend_to_core_ring -starts_with POWER",
                "add_pdn_connect -grid sram -layers {Metal3 Metal1}",
                "add_pdn_connect -grid sram -layers {TopMetal1 Metal3}",
                "add_pdn_connect -grid sram -layers {TopMetal1 Metal4}",
                "add_pdn_connect -grid sram -layers {TopMetal2 TopMetal1}",
                "pdngen",
                "place_pins -hor_layers Metal2 -ver_layers Metal3",
                f'source "{work / "constraints/cache_subsys.sdc"}"',
                "set_wire_rc -signal -layer Metal3",
                "set_wire_rc -clock -layer Metal3",
                "insert_tiecells sg13g2_tielo/L_LO",
                "insert_tiecells sg13g2_tiehi/L_HI",
                "repair_tie_fanout sg13g2_tielo/L_LO",
                "repair_tie_fanout sg13g2_tiehi/L_HI",
                'foreach inst [[ord::get_db_block] getInsts] { set mname [[$inst getMaster] getName]; if {$mname eq "sg13g2_inv_1"} { replace_cell [$inst getName] sg13g2_inv_8 } elseif {$mname eq "sg13g2_nand2_1"} { replace_cell [$inst getName] sg13g2_nand2_2 } elseif {$mname eq "sg13g2_dfrbp_1"} { replace_cell [$inst getName] sg13g2_dfrbp_2 } }',
                "global_placement -density 0.34",
                "detailed_placement",
                "clock_tree_synthesis -root_buf sg13g2_buf_8 -buf_list {sg13g2_buf_2 sg13g2_buf_4 sg13g2_buf_8} -sink_clustering_enable -sink_clustering_size 8 -sink_clustering_max_diameter 400",
                "set_propagated_clock [all_clocks]",
                "detailed_placement",
                "estimate_parasitics -placement",
                "repair_timing -setup -setup_margin 3.80 -max_buffer_percent 30",
                "repair_timing -hold -hold_margin 0.30 -max_buffer_percent 20",
                "detailed_placement",
                "check_placement -verbose",
                "global_connect",
                'puts "__PDN_BEGIN__"',
                "check_power_grid -net VDD",
                "check_power_grid -net VSS",
                'puts "__PDN_END__"',
                "set_routing_layers -signal Metal2-TopMetal1 -clock Metal2-TopMetal1",
                'puts "__GRT_BEGIN__"',
                "global_route -congestion_iterations 15 -allow_congestion -verbose",
                "estimate_parasitics -global_routing",
                "global_route -start_incremental",
                "repair_timing -setup -setup_margin 0.35 -max_buffer_percent 20",
                "repair_timing -hold -hold_margin 0.20 -max_buffer_percent 15",
                "detailed_placement",
                "global_route -end_incremental -allow_congestion -verbose",
                'puts "__GRT_END__"',
                "estimate_parasitics -global_routing",
                'puts "__STA_BEGIN__"',
                "report_wns -digits 4",
                "report_tns -digits 4",
                "report_checks -path_delay max -digits 4",
                "report_checks -path_delay min -digits 4",
                'puts "__STA_END__"',
                "exit",
            ]
            tcl_file = work / "pnr.tcl"
            tcl_file.write_text("\n".join(tcl_lines) + "\n", encoding="utf-8")

            r_or = subprocess.run([str(OPENROAD), "-exit", str(tcl_file)], cwd=work, env=env, capture_output=True, text=True, timeout=600)
            olog = r_or.stdout + "\n" + r_or.stderr
            if r_or.returncode != 0:
                finish(result_path, "FAIL", "physical", f"OpenROAD exited with error: {olog[-2000:]}")

            pdn_sec = re.search(r"__PDN_BEGIN__(.*?)__PDN_END__", olog, flags=re.S)
            pdn_txt = pdn_sec.group(1) if pdn_sec else ""
            if "All shapes on net VDD are connected" not in pdn_txt or "All shapes on net VSS are connected" not in pdn_txt or "[ERROR" in pdn_txt:
                finish(result_path, "FAIL", "physical", f"PDN connectivity check failed: {pdn_txt}")

            grt_sec = re.search(r"__GRT_BEGIN__(.*?)__GRT_END__", olog, flags=re.S)
            grt_txt = grt_sec.group(1) if grt_sec else ""
            ovf_all = re.findall(r"Total\s+\d+\s+\d+\s+[\d.]+%\s+\d+\s*/\s*\d+\s*/\s*(\d+)", grt_txt)
            wl_all = re.findall(r"Total wirelength:\s*([\d.]+)\s*um", grt_txt)
            if not ovf_all or not wl_all:
                finish(result_path, "FAIL", "physical", "Failed to parse OpenROAD global route congestion/wirelength report")
            ovf = int(ovf_all[-1])
            wl = float(wl_all[-1])

            sta_sec = re.search(r"__STA_BEGIN__(.*?)__STA_END__", olog, flags=re.S)
            sta_txt = sta_sec.group(1) if sta_sec else ""
            m_wns = re.search(r"wns\s+(?:max\s+)?([-+]?[\d.]+)", sta_txt)
            m_tns = re.search(r"tns\s+(?:max\s+)?([-+]?[\d.]+)", sta_txt)
            slacks = re.findall(r"([-+]?[\d.]+)\s+slack\s+\((?:MET|VIOLATED)\)", sta_txt)
            if not m_wns or len(slacks) < 2:
                finish(result_path, "FAIL", "timing", f"Failed to parse post-GRT STA report: {sta_txt[-1200:]}")

            wns = float(m_wns.group(1))
            tns = float(m_tns.group(1)) if m_tns else 0.0
            hold_slack = float(slacks[-1])

            metrics = {
                "wns_ns": wns,
                "tns_ns": tns,
                "hold_slack_ns": hold_slack,
                "grt_overflow": ovf,
                "grt_wirelength_um": wl,
            }

            phys_viol = []
            if ovf > MAX_GRT_OVERFLOW:
                phys_viol.append(f"GRT overflow {ovf} > {MAX_GRT_OVERFLOW}")
            if wl > MAX_GRT_WIRELENGTH:
                phys_viol.append(f"GRT wirelength {wl:.0f} um > {MAX_GRT_WIRELENGTH:.0f} um")
            if phys_viol:
                finish(result_path, "FAIL", "physical", "; ".join(phys_viol), metrics)

            tim_viol = []
            if wns < 0.0:
                tim_viol.append(f"Post-GRT setup WNS {wns:.4f} ns < 0.0 ns")
            if hold_slack < 0.0:
                tim_viol.append(f"Post-GRT hold slack {hold_slack:.4f} ns < 0.0 ns")
            if tim_viol:
                finish(result_path, "FAIL", "timing", "; ".join(tim_viol), metrics)

            finish(
                result_path,
                "PASS",
                "physical",
                f"All RTL, synthesis, PDN, GRT (ovf={ovf}, wl={wl:.0f}um), and post-GRT STA (WNS={wns:.4f}ns, hold={hold_slack:.4f}ns) checks passed",
                metrics,
            )
    except subprocess.TimeoutExpired as exc:
        finish(result_path, "FAIL", "timeout", f"Grader step timed out: {exc}")


if __name__ == "__main__":
    main()
