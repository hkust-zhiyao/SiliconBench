#!/usr/bin/env python3
"""Private isolated grader for case_23011 (Vortex Multi-Core Split-Phase & Global Barrier Subsystem, S1 + Nangate45 STA)."""
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

EDITABLE_FILES = {
    pathlib.Path("code/VX_bar_unit.sv"): "VX_bar_unit",
    pathlib.Path("code/VX_gbar_unit.sv"): "VX_gbar_unit",
    pathlib.Path("code/VX_gbar_arb.sv"): "VX_gbar_arb",
}

SV_SRCS = [
    "VX_gpu_pkg.sv", "VX_gbar_bus_if.sv",
    "VX_scan.sv", "VX_find_first.sv", "VX_lzc.sv",
    "VX_onehot_encoder.sv", "VX_onehot_mux.sv",
    "VX_priority_arbiter.sv", "VX_priority_encoder.sv", "VX_popcount.sv",
    "VX_rr_arbiter.sv", "VX_matrix_arbiter.sv", "VX_cyclic_arbiter.sv", "VX_generic_arbiter.sv",
    "VX_pipe_register.sv", "VX_pipe_buffer.sv", "VX_elastic_buffer.sv", "VX_skid_buffer.sv", "VX_stream_buffer.sv",
    "VX_stream_arb.sv", "VX_stream_fork.sv",
    "VX_dp_ram_asic.v", "VX_async_ram_patch.sv", "VX_dp_ram.sv",
    "VX_pending_size.sv", "VX_fifo_queue.sv",
    "VX_bar_unit.sv", "VX_gbar_arb.sv", "VX_gbar_unit.sv", "VX_cluster_bar_subsys.sv",
]

PROTECTED_MODS = {
    "tb", "VX_cluster_bar_subsys", "VX_gpu_pkg", "VX_gbar_bus_if",
    "VX_scan", "VX_find_first", "VX_lzc", "VX_onehot_encoder", "VX_onehot_mux",
    "VX_priority_arbiter", "VX_priority_encoder", "VX_popcount",
    "VX_rr_arbiter", "VX_matrix_arbiter", "VX_cyclic_arbiter", "VX_generic_arbiter",
    "VX_pipe_register", "VX_pipe_buffer", "VX_elastic_buffer", "VX_skid_buffer", "VX_stream_buffer",
    "VX_stream_arb", "VX_stream_fork", "VX_dp_ram_asic", "VX_async_ram_patch", "VX_dp_ram",
    "VX_pending_size", "VX_fifo_queue",
}

SIM_CONFIGS = [
    ("cfg_c4_w4", ["-DVX_CFG_NUM_CORES=4", "-DVX_CFG_NUM_WARPS=4", "-DVX_CFG_NUM_BARRIERS=4"]),
    ("cfg_c2_w8", ["-DVX_CFG_NUM_CORES=2", "-DVX_CFG_NUM_WARPS=8", "-DVX_CFG_NUM_BARRIERS=4"]),
]

MAX_AREA_UM2 = 14000.0
CLK_PERIOD_NS = 1.15


def finish(result_path: pathlib.Path, verdict: str, stage: str, detail: str, metrics=None):
    payload = {"verdict": verdict, "stage": stage, "detail": detail[:4000]}
    if metrics is not None:
        payload["metrics"] = metrics
    result_path.parent.mkdir(parents=True, exist_ok=True)
    result_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(payload))
    raise SystemExit(0 if verdict == "PASS" else 2 if verdict == "ERROR" else 1)


def strip_comments_and_strings(text: str) -> str:
    text = re.sub(r"(?is)//\s*(?:pragma|synopsys)\s+translate_off.*?//\s*(?:pragma|synopsys)\s+translate_on", "", text)
    return re.sub(r"/\*.*?\*/|//[^\n]*|\"(?:\\.|[^\"\\])*\"", " ", text, flags=re.S)


def screen_candidate_source(rel: pathlib.Path, mod_name: str, cand_text: str, base_text: str, result_path: pathlib.Path):
    if len(cand_text.encode("utf-8")) > 500_000:
        finish(result_path, "FAIL", "policy", f"Editable RTL {rel} exceeds size limit")
    cand_clean = strip_comments_and_strings(cand_text)
    base_clean = strip_comments_and_strings(base_text)
    escape_pats = [
        (r"\$(?:fopen|fclose|fread|fwrite|fdisplay|fscanf|system|finish|stop|fatal|readmemh|readmemb|writememh|writememb|dumpfile|dumpvars|value\$plusargs|test\$plusargs)\b", "forbidden_systask"),
        (r"\b(?:force|release|bind|defparam)\b", "procedural_force_or_bind"),
        (r"\b(?:import|export)\s*\"DPI", "dpi_escape"),
        (r"`include\s*\"(?:/|\.\.)", "include_path_escape"),
        (r"\btb\s*\.", "hierarchical_tb_reference"),
        (r"(?:#\s*\d+|\bwait\s*\()", "simulation_delay_or_wait"),
    ]
    for pat, label in escape_pats:
        if len(re.findall(pat, cand_clean)) > len(re.findall(pat, base_clean)):
            finish(result_path, "FAIL", "policy", f"Policy violation ({label}) in {rel}")
    mods = re.findall(r"\bmodule\s+([A-Za-z_]\w*)\b", cand_clean)
    if mod_name not in mods:
        finish(result_path, "FAIL", "policy", f"Required module {mod_name} missing in {rel}")
    for m in mods:
        if m in PROTECTED_MODS or (m != mod_name and m in EDITABLE_FILES.values()):
            finish(result_path, "FAIL", "policy", f"Unauthorized module redefinition '{m}' in {rel}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--candidate", required=True)
    ap.add_argument("--result", required=True)
    ap.add_argument("--seed", type=int, default=101)
    args, _ = ap.parse_known_args()
    cand_root = pathlib.Path(args.candidate)
    result_path = pathlib.Path(args.result).resolve()
    if cand_root.is_symlink() or not cand_root.is_dir():
        finish(result_path, "FAIL", "policy", "Invalid or symlinked candidate directory")
    cand_root = cand_root.resolve()

    for sub in ("code", "lib"):
        if (cand_root / sub).is_dir():
            non_edit = [
                p for p in (cand_root / sub).rglob("*")
                if p.is_file() and p.relative_to(cand_root) not in EDITABLE_FILES
            ]
            if non_edit:
                for ref in sorted((PUB_DIR / sub).rglob("*")):
                    if not ref.is_file():
                        continue
                    rel = ref.relative_to(PUB_DIR)
                    if rel in EDITABLE_FILES:
                        continue
                    cf = cand_root / rel
                    if not cf.is_file() or cf.is_symlink() or hashlib.sha256(cf.read_bytes()).hexdigest() != hashlib.sha256(ref.read_bytes()).hexdigest():
                        finish(result_path, "FAIL", "policy", f"Read-only file modified or missing: {rel}")

    cand_texts = {}
    for rel, mod_name in EDITABLE_FILES.items():
        p = cand_root / rel
        if not p.is_file() or p.is_symlink():
            finish(result_path, "FAIL", "policy", f"Missing or symlink editable file: {rel}")
        try:
            txt = p.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            finish(result_path, "FAIL", "policy", f"Non-UTF8 editable file: {rel}")
        base_txt = (PUB_DIR / rel).read_text(encoding="utf-8")
        screen_candidate_source(rel, mod_name, txt, base_txt, result_path)
        cand_texts[rel] = txt

    try:
        with tempfile.TemporaryDirectory(prefix="grade_23011_") as tmp:
            work = pathlib.Path(tmp)
            code_dir = work / "code"
            lib_dir = work / "lib"
            code_dir.mkdir()
            lib_dir.mkdir()
            for f in sorted((PUB_DIR / "code").iterdir()):
                if f.is_file():
                    shutil.copyfile(f, code_dir / f.name)
            for f in sorted((PUB_DIR / "lib").iterdir()):
                if f.is_file():
                    shutil.copyfile(f, lib_dir / f.name)
            for rel, txt in cand_texts.items():
                (work / rel).write_text(txt, encoding="utf-8")
            tb_path = work / "tb.sv"
            shutil.copyfile(PRIV_DIR / "tests/tb.sv", tb_path)

            env = {
                "PATH": f"{TOOLS_DIR}/verilator-v5.038/bin:{TOOLS_DIR}/oss-cad-suite/bin:{TOOLS_DIR}/bin:/usr/bin:/bin",
                "HOME": str(work), "TMPDIR": str(work), "CC": "/usr/bin/gcc", "CXX": "/usr/bin/g++",
            }
            sv_paths = [str(code_dir / f) for f in SV_SRCS]
            cdefs = ["-DASIC", "-DSYNTHESIS", "-DVX_CFG_XLEN=32"]

            for cfg_name, gflags in SIM_CONFIGS:
                mdir = work / f"obj_{cfg_name}"
                cmd_c = [
                    str(VERILATOR), "--binary", "-sv", "-j", "2", "-CFLAGS", "-O0",
                    *cdefs, *gflags,
                    "-Wno-fatal", "-Wno-DECLFILENAME", "-Wno-UNUSEDSIGNAL", "-Wno-UNUSEDPARAM",
                    "-Wno-PINCONNECTEMPTY", "-Wno-WIDTHEXPAND", "-Wno-WIDTHTRUNC", "-Wno-UNSIGNED",
                    f"-I{code_dir}", "--top-module", "tb", "--Mdir", str(mdir), "-o", "simv",
                    *sv_paths, str(tb_path),
                ]
                rc = subprocess.run(cmd_c, cwd=work, env=env, capture_output=True, text=True, timeout=180)
                if rc.returncode != 0 or not (mdir / "simv").is_file():
                    finish(result_path, "FAIL", "compile", f"Verilator compile failed ({cfg_name}): {(rc.stdout + rc.stderr)[-1500:]}")
                rs = subprocess.run([str(mdir / "simv"), f"+SEED={args.seed}"], cwd=work, env=env, capture_output=True, text=True, timeout=60)
                sout = (rs.stdout + "\n" + rs.stderr).strip()
                if rs.returncode != 0 or "PASS_CLUSTER_BAR" not in sout or "FAIL_CLUSTER_BAR" in sout:
                    finish(result_path, "FAIL", "functional", f"Simulation failed ({cfg_name}, seed={args.seed}): {sout[-1500:]}")

            ppa_srcs = " ".join(sv_paths)
            def_str = " ".join(cdefs + SIM_CONFIGS[0][1])
            if args.seed != 101:
                ys_fast = (
                    f"read_slang {def_str} -I{code_dir} {ppa_srcs} --top VX_cluster_bar_subsys; "
                    "hierarchy -check -top VX_cluster_bar_subsys; proc; opt_clean; "
                    "check -assert; select -assert-none */t:$dlatch*"
                )
                rf = subprocess.run([str(YOSYS), "-m", "slang", "-p", ys_fast], cwd=work, env=env, capture_output=True, text=True, timeout=120)
                if rf.returncode != 0:
                    finish(result_path, "FAIL", "synthesis", f"Yosys synthesis/latch check failed: {(rf.stdout + rf.stderr)[-1500:]}")
                finish(result_path, "PASS", "functional", f"All barrier subsystem configurations and latch checks passed (seed={args.seed})")

            lib_file = lib_dir / "NangateOpenCellLibrary_typical.lib"
            constr = work / "abc.constr"
            constr.write_text("set_driving_cell DFF_X1\nset_load 0.010\n", encoding="utf-8")
            synth_v = work / "synth.v"
            abc_scr = "+strash;ifraig;scorr;dc2;strash;&get -n;&dch -f;&nf {D};&put;buffer -N 8;upsize {D};dnsize {D};stime -p"
            ys_path = work / "synth.ys"
            ys_path.write_text("\n".join([
                "plugin -i slang",
                f"read_slang {def_str} -I{code_dir} {ppa_srcs} --top VX_cluster_bar_subsys",
                "hierarchy -check -top VX_cluster_bar_subsys",
                "proc; opt_clean", "check -assert", "select -assert-none */t:$dlatch*",
                "opt; fsm; opt; memory; opt", "techmap; opt",
                f"dfflibmap -liberty {lib_file}",
                f'abc -liberty {lib_file} -D 800 -constr {constr} -script "{abc_scr}"',
                "opt_clean -purge", f"stat -liberty {lib_file}",
                f"write_verilog -noattr -noexpr {synth_v}",
            ]) + "\n", encoding="utf-8")
            rsyn = subprocess.run([str(YOSYS), "-s", str(ys_path)], cwd=work, env=env, capture_output=True, text=True, timeout=240)
            yout = rsyn.stdout + "\n" + rsyn.stderr
            if rsyn.returncode != 0 or not synth_v.is_file():
                finish(result_path, "FAIL", "synthesis", f"Yosys synthesis/latch check failed: {yout[-1600:]}")
            stat_sec = yout.split("Printing statistics.")[-1] if "Printing statistics." in yout else yout
            if re.search(r"\bDLATCH", stat_sec):
                finish(result_path, "FAIL", "synthesis", "Inferred latches detected in synthesized netlist")
            m_area = re.search(r"Chip area for module '\\VX_cluster_bar_subsys':\s*([0-9.]+)", yout)
            if not m_area:
                finish(result_path, "FAIL", "synthesis", "Failed to extract Chip area from Yosys stat output")
            area = float(m_area.group(1))

            sta_path = work / "sta.tcl"
            sta_path.write_text("\n".join([
                f"read_lef {lib_dir / 'NangateOpenCellLibrary.tech.lef'}",
                f"read_lef {lib_dir / 'NangateOpenCellLibrary.macro.mod.lef'}",
                f"read_liberty {lib_file}", f"read_verilog {synth_v}",
                "link_design VX_cluster_bar_subsys",
                f"create_clock -name clk -period {CLK_PERIOD_NS:.2f} [get_ports clk]",
                "set_input_delay 0.10 -clock clk [all_inputs -no_clocks]",
                "set_output_delay 0.10 -clock clk [all_outputs]",
                'puts "__STA_BEGIN__"', "report_wns -digits 4", "report_tns -digits 4", 'puts "__STA_END__"', "exit",
            ]) + "\n", encoding="utf-8")
            rsta = subprocess.run([str(OPENROAD), "-exit", str(sta_path)], cwd=work, env=env, capture_output=True, text=True, timeout=120)
            sout = rsta.stdout + "\n" + rsta.stderr
            if rsta.returncode != 0:
                finish(result_path, "FAIL", "timing", f"OpenROAD STA failed: {sout[-1500:]}")
            sta_sec = re.search(r"__STA_BEGIN__(.*?)__STA_END__", sout, flags=re.S)
            m_wns = re.search(r"wns\s+max\s+([-+]?[0-9.]+)", sta_sec.group(1) if sta_sec else sout)
            if not m_wns:
                finish(result_path, "FAIL", "timing", f"Failed to parse WNS: {sout[-1200:]}")
            wns = float(m_wns.group(1))
            metrics = {"area_um2": area, "wns_ns": wns}
            if wns < 0.0:
                finish(result_path, "FAIL", "timing", f"Setup WNS {wns:.4f} ns < 0.0000 ns at {CLK_PERIOD_NS:.2f} ns clock", metrics)
            if area > MAX_AREA_UM2:
                finish(result_path, "FAIL", "area", f"Chip area {area:.2f} um^2 exceeds budget {MAX_AREA_UM2:.2f} um^2", metrics)
            finish(result_path, "PASS", "timing", f"All barrier simulations and Nangate45 STA/area passed (area={area:.2f} um^2, WNS={wns:.4f} ns)", metrics)
    except subprocess.TimeoutExpired as exc:
        finish(result_path, "FAIL", "functional", f"Grader step timed out: {exc}")


if __name__ == "__main__":
    main()
