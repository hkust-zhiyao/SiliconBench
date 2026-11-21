#!/usr/bin/env python3
"""Private isolated grader for case_23015 (NVDLA CDP LRN Sum, Dual-LUT Indexer & Interpolator PPA/STA + 4-State GLS)."""
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
IVERILOG = TOOLS_DIR / "iverilog-v13" / "bin" / "iverilog"
VVP = TOOLS_DIR / "iverilog-v13" / "bin" / "vvp"
YOSYS = TOOLS_DIR / "oss-cad-suite" / "bin" / "yosys"
SIMCELLS = TOOLS_DIR / "oss-cad-suite" / "share" / "yosys" / "simcells.v"
OPENROAD = TOOLS_DIR / "bin" / "openroad"

EDITABLE_FILES = {
    pathlib.Path("code/int_sum_block.v"): "int_sum_block",
    pathlib.Path("code/NV_NVDLA_CDP_DP_LUT_CTRL_unit.v"): "NV_NVDLA_CDP_DP_LUT_CTRL_unit",
    pathlib.Path("code/NV_NVDLA_CDP_DP_INTP_unit.v"): "NV_NVDLA_CDP_DP_INTP_unit",
}

UNIT_SPECS = [
    ("int_sum_block", ["int_sum_block.v"], 6100.0),
    ("NV_NVDLA_CDP_DP_LUT_CTRL_unit", ["NV_NVDLA_CDP_DP_LUT_CTRL_unit.v", "HLS_fp32_sub.v"], 27500.0),
    ("NV_NVDLA_CDP_DP_INTP_unit", ["NV_NVDLA_CDP_DP_INTP_unit.v", "HLS_fp32_sub.v", "HLS_fp32_to_fp17.v", "HLS_fp17_mul.v", "HLS_fp17_add.v"], 32000.0),
]
MAX_TOTAL_AREA_UM2 = 59000.0
CLK_PERIOD_NS = 3.80


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


def get_protected_mods() -> set:
    pmods = {"tb", "tb_gls"}
    for f in (PUB_DIR / "code").glob("*.v"):
        rel = f.relative_to(PUB_DIR)
        if rel in EDITABLE_FILES:
            continue
        clean = strip_comments_and_strings(f.read_text(encoding="utf-8", errors="ignore"))
        pmods.update(re.findall(r"\bmodule\s+([A-Za-z_]\w*)\b", clean))
    return pmods


def screen_candidate_source(rel: pathlib.Path, mod_name: str, cand_text: str, base_text: str, pmods: set, result_path: pathlib.Path):
    if len(cand_text.encode("utf-8")) > 500_000:
        finish(result_path, "FAIL", "policy", f"Editable RTL {rel} exceeds size limit")
    cand_clean = strip_comments_and_strings(cand_text)
    base_clean = strip_comments_and_strings(base_text)
    escape_pats = [
        (r"\$(?:fopen|fclose|fread|fwrite|fdisplay|fscanf|system|finish|stop|fatal|readmemh|readmemb|writememh|writememb|dumpfile|dumpvars|value\$plusargs|test\$plusargs)\b", "forbidden_systask"),
        (r"\b(?:force|release|bind|defparam)\b", "procedural_force_or_bind"),
        (r"\b(?:import|export)\s*\"DPI", "dpi_escape"),
        (r"`include\s*\"(?:/|\.\.)", "include_path_escape"),
        (r"\b(?:tb|tb_gls)\s*\.", "hierarchical_tb_reference"),
        (r"(?:#\s*\d+|\bwait\s*\()", "simulation_delay_or_wait"),
    ]
    for pat, label in escape_pats:
        if len(re.findall(pat, cand_clean)) > len(re.findall(pat, base_clean)):
            finish(result_path, "FAIL", "policy", f"Policy violation ({label}) in {rel}")
    mods = re.findall(r"\bmodule\s+([A-Za-z_]\w*)\b", cand_clean)
    if mod_name not in mods:
        finish(result_path, "FAIL", "policy", f"Required module {mod_name} missing in {rel}")
    for m in mods:
        if m in pmods or (m != mod_name and m in EDITABLE_FILES.values()):
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
        csub = cand_root / sub
        if csub.is_symlink():
            finish(result_path, "FAIL", "policy", f"Symlinked {sub} directory")
        if csub.is_dir():
            non_edit = []
            for p in sorted(csub.rglob("*")):
                if p.is_symlink():
                    finish(result_path, "FAIL", "policy", f"Symlinked file in candidate: {p.relative_to(cand_root)}")
                if not p.is_file():
                    continue
                rel = p.relative_to(cand_root)
                if rel in EDITABLE_FILES:
                    continue
                non_edit.append(rel)
                ref = PUB_DIR / rel
                if not ref.is_file():
                    finish(result_path, "FAIL", "policy", f"Unauthorized extra file in {sub}: {rel}")
                if hashlib.sha256(p.read_bytes()).hexdigest() != hashlib.sha256(ref.read_bytes()).hexdigest():
                    finish(result_path, "FAIL", "policy", f"Read-only file modified: {rel}")
            if non_edit:
                for ref in sorted((PUB_DIR / sub).rglob("*")):
                    if ref.is_file() and ref.relative_to(PUB_DIR) not in EDITABLE_FILES:
                        if not (cand_root / ref.relative_to(PUB_DIR)).is_file():
                            finish(result_path, "FAIL", "policy", f"Read-only file missing: {ref.relative_to(PUB_DIR)}")

    pmods = get_protected_mods()
    cand_texts = {}
    for rel, mod_name in EDITABLE_FILES.items():
        p = cand_root / rel
        if not p.is_file() or p.is_symlink():
            finish(result_path, "FAIL", "policy", f"Missing or symlink editable file: {rel}")
        try:
            txt = p.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            finish(result_path, "FAIL", "policy", f"Non-UTF8 editable file: {rel}")
        screen_candidate_source(rel, mod_name, txt, (PUB_DIR / rel).read_text(encoding="utf-8"), pmods, result_path)
        cand_texts[rel] = txt

    try:
        with tempfile.TemporaryDirectory(prefix="grade_23015_") as tmp:
            work = pathlib.Path(tmp)
            code_dir, lib_dir = work / "code", work / "lib"
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
                "PATH": f"{TOOLS_DIR}/verilator-v5.038/bin:{TOOLS_DIR}/iverilog-v13/bin:{TOOLS_DIR}/oss-cad-suite/bin:{TOOLS_DIR}/bin:/usr/bin:/bin",
                "HOME": str(work), "TMPDIR": str(work), "CC": "/usr/bin/gcc", "CXX": "/usr/bin/g++",
            }
            v_srcs = [str(f) for f in sorted(code_dir.glob("*.v"))]
            mdir = work / "obj_sim"
            cmd_v = [
                str(VERILATOR), "--binary", "-j", "4", "-CFLAGS", "-O0", "-sv",
                "-DSYNTHESIS", "-DVLIB_BYPASS_POWER_CG", "-DNV_FPGA_FIFOGEN", "-DVERILINT",
                "-Wno-fatal", "-Wno-lint", "-Wno-style", "-Wno-TIMESCALEMOD", "-Wno-MULTIDRIVEN",
                f"-I{code_dir}", "--top-module", "tb", "--Mdir", str(mdir), "-o", "simv",
                *v_srcs, str(tb_path),
            ]
            rc = subprocess.run(cmd_v, cwd=work, env=env, capture_output=True, text=True, timeout=180)
            if rc.returncode != 0 or not (mdir / "simv").is_file():
                finish(result_path, "FAIL", "compile", f"Verilator compile failed: {(rc.stdout + rc.stderr)[-1500:]}")
            rs = subprocess.run([str(mdir / "simv"), f"+seed={args.seed}"], cwd=work, env=env, capture_output=True, text=True, timeout=90)
            sout = (rs.stdout + "\n" + rs.stderr).strip()
            if rs.returncode != 0 or f"TEST_PASS seed={args.seed}" not in sout or "TEST_FAIL" in sout:
                finish(result_path, "FAIL", "functional", f"RTL unit/subsystem simulation failed (seed={args.seed}): {sout[-1500:]}")

            cdefs = "-D SYNTHESIS -D VLIB_BYPASS_POWER_CG -D NV_FPGA_FIFOGEN -D VERILINT"
            if args.seed != 101:
                for top, files, _ in UNIT_SPECS:
                    srcs = " ".join(str(code_dir / fn) for fn in files)
                    ys_fast = (
                        f"plugin -i slang; read_slang -I {code_dir} --top {top} {cdefs} {srcs}; "
                        f"hierarchy -check -top {top}; proc; opt_clean; "
                        "select -assert-none */t:$dlatch* */t:$_DLATCH_*; flatten; opt_clean; scc -expect 0"
                    )
                    rf = subprocess.run([str(YOSYS), "-p", ys_fast], cwd=work, env=env, capture_output=True, text=True, timeout=120)
                    if rf.returncode != 0:
                        finish(result_path, "FAIL", "synthesis", f"Yosys latch/SCC check failed on {top}: {(rf.stdout + rf.stderr)[-1500:]}")
                finish(result_path, "PASS", "functional", f"All CDP LRN unit & subsystem checks passed (seed={args.seed})")

            lib_file = lib_dir / "NangateOpenCellLibrary_typical.lib"
            tlef = lib_dir / "NangateOpenCellLibrary.tech.lef"
            mlef = lib_dir / "NangateOpenCellLibrary.macro.mod.lef"
            gls_all = work / "gls_all.v"
            gls_parts = []
            areas, wns_map = {}, {}

            for top, files, unit_cap in UNIT_SPECS:
                srcs = " ".join(str(code_dir / fn) for fn in files)
                gls_v = work / f"gls_{top}.v"
                net_v = work / f"net_{top}.v"
                ys_scr = work / f"syn_{top}.ys"
                ys_scr.write_text("\n".join([
                    "plugin -i slang",
                    f"read_slang -I {code_dir} --top {top} {cdefs} {srcs}",
                    f"hierarchy -check -top {top}",
                    "proc; opt_clean",
                    "select -assert-none */t:$dlatch* */t:$_DLATCH_*",
                    "opt; fsm; opt; memory; opt",
                    "techmap; opt",
                    "select -assert-none */t:$dlatch* */t:$_DLATCH_*",
                    "design -push-copy",
                    f"flatten; opt_clean; scc -expect 0; write_verilog -noattr {gls_v}",
                    "design -pop",
                    f"dfflibmap -liberty {lib_file}",
                    f"abc -liberty {lib_file} -D 1800",
                    "opt_clean -purge",
                    f"stat -liberty {lib_file}",
                    f"write_verilog -noattr -noexpr {net_v}",
                ]) + "\n", encoding="utf-8")
                ry = subprocess.run([str(YOSYS), "-s", str(ys_scr)], cwd=work, env=env, capture_output=True, text=True, timeout=240)
                if ry.returncode != 0 or not net_v.is_file() or not gls_v.is_file():
                    finish(result_path, "FAIL", "synthesis", f"Yosys synthesis failed on {top}: {(ry.stdout + ry.stderr)[-1500:]}")
                m_areas = re.findall(r"Chip area for (?:top )?module.*?:\s*([0-9.]+)", ry.stdout)
                if not m_areas:
                    finish(result_path, "FAIL", "synthesis", f"Failed to parse Nangate45 cell area for {top}")
                areas[top] = float(m_areas[-1])
                gls_parts.append(gls_v.read_text(encoding="utf-8"))

                sta_tcl = work / f"sta_{top}.tcl"
                sta_tcl.write_text("\n".join([
                    f"read_lef {tlef}", f"read_lef {mlef}", f"read_liberty {lib_file}", f"read_verilog {net_v}",
                    f"link_design {top}",
                    f"create_clock -name core_clk -period {CLK_PERIOD_NS:.2f} [get_ports *clk*]",
                    "set_input_delay 0.25 -clock core_clk [all_inputs -no_clocks]",
                    "set_output_delay 0.25 -clock core_clk [all_outputs]",
                    "set_false_path -from [get_ports *rst*]",
                    'puts "__STA_BEGIN__"', "report_wns -digits 4", 'puts "__STA_END__"', "exit",
                ]) + "\n", encoding="utf-8")
                ro = subprocess.run([str(OPENROAD), "-exit", str(sta_tcl)], cwd=work, env=env, capture_output=True, text=True, timeout=120)
                oout = ro.stdout + "\n" + ro.stderr
                if ro.returncode != 0:
                    finish(result_path, "FAIL", "timing", f"OpenROAD STA failed on {top}: {oout[-1500:]}")
                sec = re.search(r"__STA_BEGIN__(.*?)__STA_END__", oout, flags=re.S)
                mw = re.search(r"wns\s+(?:max\s+)?([-+]?[0-9.]+)", sec.group(1) if sec else oout)
                if not mw:
                    finish(result_path, "FAIL", "timing", f"Failed to parse WNS on {top}: {oout[-1200:]}")
                wns_map[top] = float(mw.group(1))

            gls_all.write_text("\n".join(gls_parts), encoding="utf-8")
            tb_gls = work / "tb_gls.v"
            shutil.copyfile(PRIV_DIR / "tests/tb_gls.v", tb_gls)
            gls_vvp = work / "gls.vvp"
            riv = subprocess.run([str(IVERILOG), "-g2012", "-s", "tb_gls", "-o", str(gls_vvp), str(gls_all), str(SIMCELLS), str(tb_gls)], cwd=work, env=env, capture_output=True, text=True, timeout=120)
            if riv.returncode != 0 or not gls_vvp.is_file():
                finish(result_path, "FAIL", "synthesis", f"4-state GLS compile failed: {(riv.stdout + riv.stderr)[-1200:]}")
            rvvp = subprocess.run([str(VVP), str(gls_vvp)], cwd=work, env=env, capture_output=True, text=True, timeout=60)
            gout = (rvvp.stdout + "\n" + rvvp.stderr).strip()
            if rvvp.returncode != 0 or "GLS_PASS" not in gout or "GLS_FAIL" in gout or "GLS_ERR" in gout:
                finish(result_path, "FAIL", "functional", f"4-state gate-level simulation failed: {gout[-1200:]}")

            total_area = sum(areas.values())
            metrics = {"areas_um2": areas, "total_area_um2": round(total_area, 2), "wns_ns": wns_map}
            for top, _, unit_cap in UNIT_SPECS:
                if wns_map[top] < 0.0:
                    finish(result_path, "FAIL", "timing", f"{top} setup WNS {wns_map[top]:.4f} ns < 0.0000 ns at {CLK_PERIOD_NS:.2f} ns clock", metrics)
            for top, _, unit_cap in UNIT_SPECS[:2]:
                if areas[top] > unit_cap:
                    finish(result_path, "FAIL", "area", f"{top} cell area {areas[top]:.2f} um^2 exceeds cap {unit_cap:.2f} um^2", metrics)
            if total_area > MAX_TOTAL_AREA_UM2:
                finish(result_path, "FAIL", "area", f"Combined 3-unit area {total_area:.2f} um^2 exceeds cap {MAX_TOTAL_AREA_UM2:.2f} um^2", metrics)
            finish(result_path, "PASS", "timing", f"All CDP LRN RTL, 4-state GLS, Nangate45 area ({total_area:.2f} um^2) & 3.80 ns STA checks passed", metrics)
    except subprocess.TimeoutExpired as exc:
        finish(result_path, "FAIL", "timeout", f"Grader step timed out: {exc}")


if __name__ == "__main__":
    main()
