#!/usr/bin/env python3
import argparse
import fnmatch
import hashlib
import json
import pathlib
import re
import shutil
import subprocess
import sys
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
PUB_DIR = TASK_DIR / "public"
PRIV_DIR = TASK_DIR / "private"
TOOLS_DIR = pathlib.Path(str(_sb_tools_dir()))

VERILATOR = TOOLS_DIR / "verilator-v5.038" / "bin" / "verilator"
YOSYS = TOOLS_DIR / "oss-cad-suite" / "bin" / "yosys"
IVERILOG = TOOLS_DIR / "oss-cad-suite" / "bin" / "iverilog"
VVP = TOOLS_DIR / "oss-cad-suite" / "bin" / "vvp"
SIMCELLS = TOOLS_DIR / "oss-cad-suite" / "share" / "yosys" / "simcells.v"
OPENROAD = TOOLS_DIR / "bin" / "openroad"

EDITABLE_RTL = {
    pathlib.Path("code/snitch_clkdiv2.sv"): ["snitch_clkdiv2"],
    pathlib.Path("code/snitch_l0_tlb.sv"): ["snitch_l0_tlb"],
    pathlib.Path("code/snitch_ptw.sv"): ["snitch_ptw"],
    pathlib.Path("code/snitch_shared_muldiv.sv"): ["snitch_shared_muldiv"],
    pathlib.Path("code/snitch_iso_hive.sv"): ["snitch_iso_hive"],
}
EDITABLE_ALL = list(EDITABLE_RTL.keys()) + [
    pathlib.Path("constraints/snitch_iso_hive.sdc"),
]

RTL_FILES = [
    "code/dm_pkg.sv",
    "code/axi_pkg.sv",
    "code/cf_math_pkg.sv",
    "code/reqrsp_pkg.sv",
    "code/riscv_instr.sv",
    "code/snitch_pkg.sv",
    "code/cc_onehot.sv",
    "code/lzc.sv",
    "code/onehot_to_bin.sv",
    "code/rr_arb_tree.sv",
    "code/spill_register_flushable.sv",
    "code/spill_register.sv",
    "code/fall_through_register.sv",
    "code/fifo_v3.sv",
    "code/isochronous_4phase_handshake.sv",
    "code/isochronous_spill_register.sv",
    "code/stream_arbiter_flushable.sv",
    "code/stream_arbiter.sv",
    "code/stream_demux.sv",
    "code/reqrsp_iso.sv",
    "code/snitch_clkdiv2.sv",
    "code/snitch_l0_tlb.sv",
    "code/snitch_ptw.sv",
    "code/snitch_shared_muldiv.sv",
    "code/snitch_iso_hive.sv",
    "code/snitch_iso_cluster_subsys.sv",
]

SYNC_INPUT_PREFIXES = [
    "tlb_req_valid_i", "tlb_req_flush_i", "tlb_req_va_i", "tlb_req_ppn_i",
    "tlb_req_priv_i", "tlb_req_read_i", "tlb_req_write_i", "tlb_req_exec_i",
    "tlb_rsp_ready_i", "acc_qvalid_i", "acc_qid_i", "acc_qop_i",
    "acc_qarga_i", "acc_qargb_i", "acc_qargc_i", "acc_pready_i",
    "ptw_mem_qready_i", "ptw_mem_pvalid_i", "ptw_mem_pdata_i", "ptw_mem_perror_i",
]

SIGNOFF_PERIOD_MAX = 3.15
SIGNOFF_SETUP_UNC_MIN = 0.08
SIGNOFF_HOLD_UNC_MIN = 0.02
SIGNOFF_IO_MAX_MIN = 0.40
SIGNOFF_IO_MIN_LO = 0.02
SIGNOFF_IO_MIN_HI = 0.10


def finish(result_path, verdict, stage, detail, metrics=None):
    payload = {"verdict": verdict, "stage": stage, "detail": detail}
    if metrics is not None:
        payload["metrics"] = metrics
    if result_path is not None:
        result_path.parent.mkdir(parents=True, exist_ok=True)
        result_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
    else:
        print(json.dumps(payload, indent=2))
    sys.exit(0 if verdict == "PASS" else 1)


def sha256_bytes(path: pathlib.Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def strip_sv_comments_and_strings(src: str) -> str:
    out = []
    i, n = 0, len(src)
    while i < n:
        if i + 1 < n and src[i:i + 2] == "//":
            i += 2
            while i < n and src[i] != "\n":
                i += 1
        elif i + 1 < n and src[i:i + 2] == "/*":
            i += 2
            while i + 1 < n and src[i:i + 2] != "*/":
                if src[i] == "\n":
                    out.append("\n")
                i += 1
            i += 2
        elif src[i] == '"':
            out.append('""')
            i += 1
            while i < n and src[i] != '"':
                if src[i] == "\\" and i + 1 < n:
                    i += 2
                else:
                    i += 1
            i += 1
        else:
            out.append(src[i])
            i += 1
    return "".join(out)


def screen_rtl_source(rel_path: pathlib.Path, mod_names, text: str, base_text: str, result_path):
    if re.search(r"/\*\s*verilator\b|\bverilator\s+lint_off\b", text, re.I) and not re.search(
        r"/\*\s*verilator\b|\bverilator\s+lint_off\b", base_text, re.I
    ):
        finish(result_path, "FAIL", "policy", f"Forbidden tool directive added in {rel_path}")
    stripped = strip_sv_comments_and_strings(text)
    base_stripped = strip_sv_comments_and_strings(base_text)
    rules = [
        ("simulator_macro_divergence", r"`\s*ifn?def\s+(?:VERILATOR|IVERILOG|VCS|MODEL_TECH|QUESTA|XCELIUM)\b"),
        ("hierarchical_harness_reference", r"\b(?:tb_subsys|tb_gls|dut)\s*\."),
        ("procedural_force_or_bind", r"\b(?:force|release|defparam|bind)\b"),
        ("dpi_or_pli_escape", r'\bimport\s+""\s*|(?:^|[^a-zA-Z0-9_])\$(?:system|fopen|fread|readmemh|readmemb|writememh|finish|stop|fatal)\b'),
        ("rtl_delay_control", r"(?:^|[\s;])#\s*\d+"),
    ]
    for label, pat in rules:
        if len(re.findall(pat, stripped)) > len(re.findall(pat, base_stripped)):
            finish(result_path, "FAIL", "policy", f"Policy violation in {rel_path}: {label}")
    for mod in mod_names:
        if not re.search(rf"\bmodule\s+{re.escape(mod)}\b", stripped):
            finish(result_path, "FAIL", "policy", f"Required module '{mod}' missing in {rel_path}")
    if rel_path.name == "snitch_iso_hive.sv" and not re.search(r"\bsnitch_clkdiv2\b", stripped):
        finish(result_path, "FAIL", "policy", "snitch_iso_hive must instantiate snitch_clkdiv2")


def validate_sdc(sdc_text: str, result_path) -> str:
    no_cmt = re.sub(r"(?m)#[^\n]*", "", sdc_text)
    joined = re.sub(r"\\\s*\n", " ", no_cmt)
    forbidden = re.compile(
        r"(?<!-)\b(set_multicycle_path|set_max_delay|set_min_delay|set_clock_groups|"
        r"set_disable_timing|set_ideal_network|set_ideal_latency|set_clock_latency|group_path)\b"
        r"|(?:^|[;\[])\s*(?:exec|open|socket|source|load|interp)\b",
        re.M,
    )
    if forbidden.search(joined):
        finish(result_path, "FAIL", "timing", "Forbidden timing exception or override in constraints/snitch_iso_hive.sdc")

    vars_map = {}
    brace_depth = 0
    for raw_ln in joined.splitlines():
        mset = re.match(r"^\s*set\s+([A-Za-z_]\w*)\s+([^\n;]+)", raw_ln)
        if mset:
            k, v = mset.group(1), mset.group(2).strip()
            if brace_depth == 0 or k not in vars_map:
                vars_map[k] = v
        brace_depth = max(0, brace_depth + raw_ln.count("{") - raw_ln.count("}"))
    expanded = joined
    for _ in range(4):
        for k, v in vars_map.items():
            expanded = expanded.replace("${" + k + "}", v).replace("$" + k, v)
    # If a Tcl foreach loop builds a port list from [all_inputs] / [all_outputs] (allowing nested { ... } blocks),
    # mark the lappend target variable when no synchronous data/handshake prefix is excluded.
    foreach_all_in_vars = set()
    foreach_all_out_vars = set()
    for mf in re.finditer(r"\bforeach\s+\w+\s+(\[[^\]]*\]|\$\{?[A-Za-z_]\w*\}?|\{[^}]*\})\s*\{", joined, flags=re.S):
        coll_expr = mf.group(1)
        for _ in range(3):
            for k, v in vars_map.items():
                coll_expr = coll_expr.replace("${" + k + "}", v).replace("$" + k, v)
        bdepth = 1
        pos = mf.end()
        while pos < len(joined) and bdepth > 0:
            if joined[pos] == "{":
                bdepth += 1
            elif joined[pos] == "}":
                bdepth -= 1
            pos += 1
        fbody = joined[mf.end():pos - 1] if bdepth == 0 else ""
        if "all_inputs" in coll_expr and not re.search(r"\b(?:tlb_|acc_|ptw_)", fbody):
            foreach_all_in_vars.update(re.findall(r"\blappend\s+([A-Za-z_]\w*)", fbody))
        if "all_outputs" in coll_expr and not re.search(r"\b(?:tlb_|acc_|ptw_)", fbody):
            foreach_all_out_vars.update(re.findall(r"\blappend\s+([A-Za-z_]\w*)", fbody))

    clk_name = None
    for mclk in re.finditer(r"\bcreate_clock\b([^\n;]*)", expanded):
        line = "create_clock " + mclk.group(1)
        if "clk_i" not in line:
            finish(result_path, "FAIL", "timing", "create_clock must target port clk_i")
        mp = re.search(r"-period\s+([0-9]+(?:\.[0-9]+)?)", line)
        if not mp:
            finish(result_path, "FAIL", "timing", "create_clock missing numeric -period")
        period = float(mp.group(1))
        if period < 1.0 or period > SIGNOFF_PERIOD_MAX + 1e-9:
            finish(result_path, "FAIL", "timing", f"Clock period {period} ns violates signoff limit <= {SIGNOFF_PERIOD_MAX} ns")
        mn = re.search(r"-name\s+(\S+)", line)
        clk_name = mn.group(1) if mn else "clk_i"

    has_gen_clk = False
    for mg in re.finditer(r"\bcreate_generated_clock\b([^\n;]*)", expanded):
        line = re.sub(r"\s+", " ", "create_generated_clock " + mg.group(1))
        if "-divide_by 2" not in line or "clk_i" not in line or "i_snitch_clkdiv2" not in line:
            finish(result_path, "FAIL", "timing", "create_generated_clock must specify -divide_by 2 -source [get_ports clk_i] on *i_snitch_clkdiv2*")
        has_gen_clk = True

    case_ports = {}
    for mca in re.finditer(r"\bset_case_analysis\b([^\n;]*)", expanded):
        line = ("set_case_analysis " + mca.group(1)).strip()
        mc = re.match(r"set_case_analysis\s+([01])\s+\[\s*get_ports(?:\s+-quiet)?\s+\{?([a-zA-Z0-9_\s]+)\}?\s*\]$", line)
        if not mc:
            finish(result_path, "FAIL", "timing", f"Invalid set_case_analysis in divided SDC: {line}")
        val = mc.group(1)
        for p in mc.group(2).split():
            if p in {"test_mode_i", "clk_d2_bypass_i"}:
                if val != "0":
                    finish(result_path, "FAIL", "timing", f"Invalid set_case_analysis value on {p} in divided SDC: {line}")
                case_ports[p] = val
            elif p == "rst_ni":
                if val != "1":
                    finish(result_path, "FAIL", "timing", f"Invalid set_case_analysis value on rst_ni: {line}")
            else:
                finish(result_path, "FAIL", "timing", f"Invalid set_case_analysis target in divided SDC: {line}")

    setup_unc = None
    hold_unc = None
    for mcu in re.finditer(r"\bset_clock_uncertainty\b([^\n;]*)", expanded):
        line = "set_clock_uncertainty " + mcu.group(1)
        ms = re.search(r"-setup\s+([0-9]+(?:\.[0-9]+)?)", line)
        mh = re.search(r"-hold\s+([0-9]+(?:\.[0-9]+)?)", line)
        if ms:
            setup_unc = float(ms.group(1))
        if mh:
            hold_unc = float(mh.group(1))
        if not ms and not mh:
            mb = re.search(r"set_clock_uncertainty\s+([0-9]+(?:\.[0-9]+)?)", line)
            if mb:
                setup_unc = hold_unc = float(mb.group(1))

    for mfp in re.finditer(r"\bset_false_path\b([^\n;]*)", expanded):
        line = ("set_false_path " + mfp.group(1)).strip()
        if not re.fullmatch(r"set_false_path(?:\s+-(?:setup|hold))*\s+-from\s+\[\s*get_ports(?:\s+-quiet)?\s+\{?rst_ni\}?\s*\](?:\s+-(?:setup|hold))*", line):
            finish(result_path, "FAIL", "timing", f"Only rst_ni may carry set_false_path; got: {line}")

    def _extract_io_delay(line_str: str) -> float:
        s = re.sub(r"-clock\s+(?:\[[^\]]*\]|\S+)", " ", line_str)
        s = re.sub(r"\[[^\]]*\]", " ", s)
        s = re.sub(r"\$\{?[A-Za-z_]\w*\}?", " ", s)
        nums = re.findall(r"(?:^|\s)([-+]?[0-9]+(?:\.[0-9]+)?)(?=\s|$)", s)
        if not nums:
            finish(result_path, "FAIL", "timing", f"Cannot parse delay value in: {line_str}")
        return float(nums[-1])

    in_max_ok, in_min_ok = False, False
    out_max_ok, out_min_ok = False, False
    covered_inputs = set()
    has_all_outputs = False

    for mid in re.finditer(r"\bset_input_delay\b([^\n;]*)", joined):
        raw_l = ("set_input_delay " + mid.group(1)).strip()
        exp_l = raw_l
        for _ in range(3):
            for k, v in vars_map.items():
                exp_l = exp_l.replace("${" + k + "}", v).replace("$" + k, v)
        if clk_name and clk_name not in exp_l:
            finish(result_path, "FAIL", "timing", "set_input_delay must reference clk_i's clock")
        val = _extract_io_delay(exp_l)
        toks = exp_l.split()
        if "-max" in toks:
            if val < SIGNOFF_IO_MAX_MIN - 1e-9:
                finish(result_path, "FAIL", "timing", f"set_input_delay -max {val} < {SIGNOFF_IO_MAX_MIN} ns")
            in_max_ok = True
        elif "-min" in toks:
            if val < SIGNOFF_IO_MIN_LO - 1e-9 or val > SIGNOFF_IO_MIN_HI + 1e-9:
                finish(result_path, "FAIL", "timing", f"set_input_delay -min {val} outside [{SIGNOFF_IO_MIN_LO}, {SIGNOFF_IO_MIN_HI}] ns")
            in_min_ok = True
        else:
            finish(result_path, "FAIL", "timing", "set_input_delay must specify explicit -max and -min")
        if "all_inputs" in exp_l or any(f"${v}" in raw_l or f"${{{v}}}" in raw_l for v in foreach_all_in_vars):
            covered_inputs.update(SYNC_INPUT_PREFIXES)
        else:
            port_pats = re.findall(r"[A-Za-z0-9_*]+", exp_l)
            for pfx in SYNC_INPUT_PREFIXES:
                if pfx in exp_l or any("*" in pat and fnmatch.fnmatch(pfx, pat) for pat in port_pats):
                    covered_inputs.add(pfx)

    req_outputs = ("tlb_req_ready_o", "tlb_rsp_valid_o", "acc_qready_o", "acc_pvalid_o", "ptw_mem_qvalid_o")
    covered_outputs = set()
    for mod in re.finditer(r"\bset_output_delay\b([^\n;]*)", joined):
        raw_l = ("set_output_delay " + mod.group(1)).strip()
        exp_l = raw_l
        for _ in range(3):
            for k, v in vars_map.items():
                exp_l = exp_l.replace("${" + k + "}", v).replace("$" + k, v)
        if clk_name and clk_name not in exp_l:
            finish(result_path, "FAIL", "timing", "set_output_delay must reference clk_i's clock")
        val = _extract_io_delay(exp_l)
        toks = exp_l.split()
        if "-max" in toks:
            if val < SIGNOFF_IO_MAX_MIN - 1e-9:
                finish(result_path, "FAIL", "timing", f"set_output_delay -max {val} < {SIGNOFF_IO_MAX_MIN} ns")
            out_max_ok = True
        elif "-min" in toks:
            if val < SIGNOFF_IO_MIN_LO - 1e-9 or val > SIGNOFF_IO_MIN_HI + 1e-9:
                finish(result_path, "FAIL", "timing", f"set_output_delay -min {val} outside [{SIGNOFF_IO_MIN_LO}, {SIGNOFF_IO_MIN_HI}] ns")
            out_min_ok = True
        else:
            finish(result_path, "FAIL", "timing", "set_output_delay must specify explicit -max and -min")
        if "all_outputs" in exp_l or any(f"${v}" in raw_l or f"${{{v}}}" in raw_l for v in foreach_all_out_vars):
            covered_outputs.update(req_outputs)
        else:
            port_pats = re.findall(r"[A-Za-z0-9_*]+", exp_l)
            for out_p in req_outputs:
                if out_p in exp_l or any("*" in pat and fnmatch.fnmatch(out_p, pat) for pat in port_pats):
                    covered_outputs.add(out_p)
    has_all_outputs = (covered_outputs == set(req_outputs))

    if not clk_name or not has_gen_clk:
        finish(result_path, "FAIL", "timing", "SDC missing create_clock or create_generated_clock -divide_by 2")
    if case_ports.get("test_mode_i") != "0" or case_ports.get("clk_d2_bypass_i") != "0":
        finish(result_path, "FAIL", "timing", "SDC must set_case_analysis 0 on test_mode_i and clk_d2_bypass_i")
    if setup_unc is None or setup_unc < SIGNOFF_SETUP_UNC_MIN - 1e-9 or hold_unc is None or hold_unc < SIGNOFF_HOLD_UNC_MIN - 1e-9:
        finish(result_path, "FAIL", "timing", f"SDC clock uncertainty must satisfy setup >= {SIGNOFF_SETUP_UNC_MIN} ns and hold >= {SIGNOFF_HOLD_UNC_MIN} ns")
    if not (in_max_ok and in_min_ok and out_max_ok and out_min_ok and has_all_outputs) or covered_inputs != set(SYNC_INPUT_PREFIXES):
        finish(result_path, "FAIL", "timing", "SDC missing complete -max/-min input/output delay coverage on synchronous ports")

    # Construct 1:1 bypass-mode SDC cleanly from validated divided-mode SDC (joining continuations first)
    byp_lines = []
    for raw_line in joined.splitlines():
        s = raw_line.strip()
        if not s:
            continue
        if re.match(r"^create_generated_clock\b", s):
            continue
        if re.match(r"^set_case_analysis\b", s) and "clk_d2_bypass_i" in s:
            if "test_mode_i" in s:
                byp_lines.append("set_case_analysis 0 [get_ports test_mode_i]")
            continue
        byp_lines.append(s)
    byp_lines.append("set_case_analysis 1 [get_ports clk_d2_bypass_i]")
    return "\n".join(byp_lines) + "\n"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--candidate", required=True)
    ap.add_argument("--seed", type=int, default=101)
    ap.add_argument("--result", default=None)
    ap.add_argument("--skip-sta", action="store_true")
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

    for sub in ("code", "lib"):
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

    for rel, mod_names in EDITABLE_RTL.items():
        base_text = (PUB_DIR / rel).read_text(encoding="utf-8")
        screen_rtl_source(rel, mod_names, cand_texts[rel], base_text, result_path)

    try:
        with tempfile.TemporaryDirectory(prefix="case_25015_grade_") as td:
            work = pathlib.Path(td)
            shutil.copytree(PUB_DIR / "code", work / "code")
            shutil.copytree(PUB_DIR / "lib", work / "lib")
            (work / "constraints").mkdir(parents=True, exist_ok=True)
            for rel, txt in cand_texts.items():
                (work / rel).write_text(txt, encoding="utf-8")

            env = {
                "PATH": f"{TOOLS_DIR}/verilator-v5.038/bin:{TOOLS_DIR}/oss-cad-suite/bin:{TOOLS_DIR}/bin:/usr/bin:/bin",
                "VERILATOR_ROOT": f"{TOOLS_DIR}/verilator-v5.038/share/verilator",
                "HOME": str(work),
                "TMPDIR": str(work),
            }

            tb_rtl = work / "tb_subsys.sv"
            shutil.copyfile(PRIV_DIR / "tests" / "tb_subsys.sv", tb_rtl)

            # 1. Multi-config Verilator RTL regression (CoreCount = 2 and 4)
            for cores in (2, 4):
                sim_bin = work / f"sim_c{cores}_{args.seed}"
                comp_cmd = [
                    str(VERILATOR), "--binary", "--timing", "-j", "4", "-Wno-fatal", "-Wno-UNOPTFLAT",
                    f"-GCORE_COUNT={cores}", f"-I{work / 'code'}",
                    "-top-module", "tb_subsys",
                    *[str(work / f) for f in RTL_FILES],
                    str(tb_rtl),
                    "-o", str(sim_bin),
                ]
                r_comp = subprocess.run(comp_cmd, cwd=work, env=env, capture_output=True, text=True, timeout=120)
                if r_comp.returncode != 0 or not sim_bin.is_file():
                    tail = (r_comp.stdout + "\n" + r_comp.stderr).strip()[-1800:]
                    finish(result_path, "FAIL", "compile", f"Verilator compile failed (CoreCount={cores}): {tail}")

                r_sim = subprocess.run([str(sim_bin), f"+seed={args.seed}"], cwd=work, env=env, capture_output=True, text=True, timeout=90)
                sim_out = (r_sim.stdout + "\n" + r_sim.stderr).strip()
                if r_sim.returncode != 0 or f"PASS_RTL cores={cores}" not in sim_out or "FAIL" in sim_out:
                    finish(result_path, "FAIL", "functional", f"RTL verification failed (CoreCount={cores}, seed={args.seed}): {sim_out[-1800:]}")

            # 2. SDC structural & signoff budget audit
            byp_sdc_text = validate_sdc(cand_texts[pathlib.Path("constraints/snitch_iso_hive.sdc")], result_path)

            if args.skip_sta or args.seed != 101:
                finish(
                    result_path,
                    "PASS",
                    "functional",
                    f"Multi-core RTL simulation (CoreCount=2,4) and SDC audit passed for seed={args.seed}",
                    {"sta_skipped": True},
                )

            # 3. 4-State Gate-Level Simulation (Yosys techmap + iverilog/vvp)
            files_str = " ".join(str(work / f) for f in RTL_FILES)
            gls_v = work / "gls.v"
            gls_ys = "\n".join([
                f"read_slang --keep-hierarchy -DSYNTHESIS -DYOSYS -I {work / 'code'} {files_str} --top snitch_iso_cluster_subsys -G CoreCount=2",
                "hierarchy -check -top snitch_iso_cluster_subsys",
                "proc; opt; memory; opt; scc -expect 0; select -assert-none t:$dlatch*",
                "techmap; opt; clean -purge",
                f"write_verilog -noattr {gls_v}",
            ])
            (work / "gls.ys").write_text(gls_ys + "\n", encoding="utf-8")
            r_gys = subprocess.run([str(YOSYS), "-m", "slang", "-s", str(work / "gls.ys")], cwd=work, env=env, capture_output=True, text=True, timeout=120)
            if r_gys.returncode != 0 or not gls_v.is_file():
                tail = (r_gys.stdout + "\n" + r_gys.stderr).strip()[-1800:]
                finish(result_path, "FAIL", "synthesis", f"Gate-level synthesis / latch / SCC check failed: {tail}")

            tb_gls = work / "tb_gls.sv"
            shutil.copyfile(PRIV_DIR / "tests" / "tb_gls.sv", tb_gls)
            gls_vvp = work / "gls.vvp"
            r_iv = subprocess.run([str(IVERILOG), "-g2012", "-o", str(gls_vvp), str(SIMCELLS), str(gls_v), str(tb_gls)], cwd=work, env=env, capture_output=True, text=True, timeout=90)
            if r_iv.returncode != 0 or not gls_vvp.is_file():
                tail = (r_iv.stdout + "\n" + r_iv.stderr).strip()[-1800:]
                finish(result_path, "FAIL", "synthesis", f"4-state gate-level compile failed: {tail}")

            r_vvp = subprocess.run([str(VVP), str(gls_vvp)], cwd=work, env=env, capture_output=True, text=True, timeout=90)
            vvp_out = (r_vvp.stdout + "\n" + r_vvp.stderr).strip()
            if r_vvp.returncode != 0 or "PASS_GLS" not in vvp_out or "FAIL_GLS" in vvp_out:
                finish(result_path, "FAIL", "equivalence", f"4-state gate-level simulation failed: {vvp_out[-1800:]}")

            # 4. Nangate45 Synthesis (CoreCount=4) + 4-Corner Multi-Mode OpenROAD STA
            lib_file = work / "lib/NangateOpenCellLibrary_typical.lib"
            tlef_file = work / "lib/NangateOpenCellLibrary.tech.lef"
            mlef_file = work / "lib/NangateOpenCellLibrary.macro.mod.lef"
            ng45_v = work / "ng45.v"
            ng45_ys = "\n".join([
                f"read_slang --keep-hierarchy -DSYNTHESIS -DYOSYS -I {work / 'code'} {files_str} --top snitch_iso_cluster_subsys -G CoreCount=4",
                "hierarchy -check -top snitch_iso_cluster_subsys",
                "setattr -mod -set keep_hierarchy 1 snitch_clkdiv2",
                "synth -noabc -top snitch_iso_cluster_subsys -flatten",
                "delete t:$scopeinfo; scc -expect 0",
                f"dfflibmap -liberty {lib_file}",
                f"abc -liberty {lib_file} -script +strash;scorr;dc2;strash;dch,-f;map;buffer,-N,8",
                "setundef -zero; splitnets -ports; opt_clean -purge",
                f"stat -liberty {lib_file}",
                f"write_verilog -noattr -noexpr -nohex {ng45_v}",
            ])
            (work / "ng45.ys").write_text(ng45_ys + "\n", encoding="utf-8")
            r_syn = subprocess.run([str(YOSYS), "-m", "slang", "-s", str(work / "ng45.ys")], cwd=work, env=env, capture_output=True, text=True, timeout=180)
            yout = r_syn.stdout + "\n" + r_syn.stderr
            if r_syn.returncode != 0 or not ng45_v.is_file():
                finish(result_path, "FAIL", "synthesis", f"Nangate45 synthesis failed: {yout[-1800:]}")
            stat_sec = yout.split("Printing statistics.")[-1] if "Printing statistics." in yout else yout
            if re.search(r"\$_DLATCH_|DLH_X|DLL_X", stat_sec):
                finish(result_path, "FAIL", "synthesis", "Inferred latches detected in Nangate45 netlist")
            if "i_snitch_clkdiv2" not in ng45_v.read_text(encoding="utf-8"):
                finish(result_path, "FAIL", "synthesis", "snitch_clkdiv2 hierarchy missing from synthesized netlist")

            byp_sdc = work / "constraints/bypass.sdc"
            byp_sdc.write_text(byp_sdc_text, encoding="utf-8")
            div_sdc = work / "constraints/snitch_iso_hive.sdc"

            worst_setup = 1e9
            worst_hold = 1e9
            corner_metrics = {}
            for mode, sdc_f in [("div2", div_sdc), ("bypass", byp_sdc)]:
                for corner, late, early in [("slow", 1.25, 1.00), ("fast", 1.00, 0.75)]:
                    key = f"{mode}_{corner}"
                    tcl = "\n".join([
                        f'read_lef "{tlef_file}"',
                        f'read_lef "{mlef_file}"',
                        f'read_liberty "{lib_file}"',
                        f'read_verilog "{ng45_v}"',
                        "link_design snitch_iso_cluster_subsys",
                        f'read_sdc "{sdc_f}"',
                        f"set_timing_derate -late {late}",
                        f"set_timing_derate -early {early}",
                        'puts "__STA_BEGIN__"',
                        'puts "CLK_COUNT:[llength [all_clocks]]"',
                        "report_wns -digits 4",
                        "report_tns -digits 4",
                        "report_checks -path_delay max -digits 4",
                        'puts "__STA_MIN__"',
                        "report_checks -path_delay min -digits 4",
                        'puts "__STA_END__"',
                        "exit",
                    ])
                    tcl_f = work / f"sta_{key}.tcl"
                    tcl_f.write_text(tcl + "\n", encoding="utf-8")
                    ro = subprocess.run([str(OPENROAD), "-exit", str(tcl_f)], cwd=work, env=env, capture_output=True, text=True, timeout=90)
                    olog = ro.stdout + "\n" + ro.stderr
                    if ro.returncode != 0 or "[ERROR" in olog or re.search(r"(?:^|\n)Error:", olog):
                        finish(result_path, "FAIL", "timing", f"OpenROAD STA error in {key}: {olog[-1500:]}")
                    sec = re.search(r"__STA_BEGIN__(.*?)__STA_END__", olog, flags=re.S)
                    stxt = sec.group(1) if sec else ""
                    mclkc = re.search(r"CLK_COUNT:(\d+)", stxt)
                    exp_clks = 2 if mode == "div2" else 1
                    if not mclkc or int(mclkc.group(1)) != exp_clks:
                        finish(result_path, "FAIL", "timing", f"Expected {exp_clks} active clock(s) in {key}, got {mclkc.group(1) if mclkc else 'none'}")
                    mw = re.search(r"wns\s+max\s+([-+]?[\d.]+)", stxt)
                    max_sec = stxt.split("__STA_MIN__")[0] if "__STA_MIN__" in stxt else stxt
                    min_sec = stxt.split("__STA_MIN__")[-1] if "__STA_MIN__" in stxt else stxt
                    max_slacks = [float(x) for x in re.findall(r"([-+]?[\d.]+)\s+slack\s+\((?:MET|VIOLATED)\)", max_sec)]
                    min_slacks = [float(x) for x in re.findall(r"([-+]?[\d.]+)\s+slack\s+\((?:MET|VIOLATED)\)", min_sec)]
                    if not mw or not max_slacks or not min_slacks:
                        finish(result_path, "FAIL", "timing", f"Failed to parse STA report in {key}: {stxt[-1000:]}")
                    c_setup = min([float(mw.group(1))] + max_slacks)
                    c_hold = min(min_slacks)
                    corner_metrics[key] = {"setup_slack_ns": c_setup, "hold_slack_ns": c_hold}
                    worst_setup = min(worst_setup, c_setup)
                    worst_hold = min(worst_hold, c_hold)
                    if c_setup < 0.0:
                        finish(result_path, "FAIL", "timing", f"Setup timing violation in {key}: slack {c_setup:.4f} ns < 0.0 ns", corner_metrics)
                    if c_hold < 0.0:
                        finish(result_path, "FAIL", "timing", f"Hold timing violation in {key}: slack {c_hold:.4f} ns < 0.0 ns", corner_metrics)

            finish(
                result_path,
                "PASS",
                "timing",
                f"All multi-core RTL (CoreCount=2,4), 4-state GLS, and 4-corner Nangate45 STA checks passed (min_setup={worst_setup:.4f}ns, min_hold={worst_hold:.4f}ns)",
                {"worst_setup_ns": worst_setup, "worst_hold_ns": worst_hold, "corners": corner_metrics},
            )
    except subprocess.TimeoutExpired as exc:
        finish(result_path, "FAIL", "timeout", f"Grader step timed out: {exc}")


if __name__ == "__main__":
    main()
