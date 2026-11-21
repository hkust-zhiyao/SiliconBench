#!/usr/bin/env python3
"""Zero-trust grader for case_22006 (RedMulE CORE-V-XIF Offload & Queued Controller)."""
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
PUBLIC_DIR = TASK_DIR / "public"
TESTS_DIR = TASK_DIR / "private" / "tests"

TOOLS = pathlib.Path(str(_sb_tools_dir()))
VERILATOR = TOOLS / "verilator-v5.038" / "bin" / "verilator"
YOSYS = TOOLS / "oss-cad-suite" / "bin" / "yosys"

EDITABLE = ["code/redmule_inst_decoder.sv", "code/redmule_ctrl.sv"]

RTL_SOURCES = [
    "code/cf_math_pkg.sv",
    "code/fpnew_pkg.sv",
    "code/hci_package.sv",
    "code/hwpe_ctrl_package.sv",
    "code/hwpe_stream_package.sv",
    "code/redmule_pkg.sv",
    "code/redmule_xif_pkg.sv",
    "code/tc_clk.sv",
    "code/redmule_config_fifo.sv",
    "code/redmule_tiler.sv",
    "code/redmule_ctrl.sv",
    "code/redmule_inst_decoder.sv",
    "code/redmule_xif_offload_subsys.sv",
]

FORBIDDEN_PATTERNS = [
    (r"`ifdef\s+SYNTHESIS", "Forbidden `ifdef SYNTHESIS macro"),
    (r"`ifndef\s+SYNTHESIS", "Forbidden `ifndef SYNTHESIS macro"),
    (r"\$finish\b|\$stop\b|\$fatal\b", "Forbidden simulation control system task in RTL"),
    (r"\bimport\s+\"DPI", "Forbidden DPI import in RTL"),
]


def sha256_file(p: pathlib.Path) -> str:
    return hashlib.sha256(p.read_bytes()).hexdigest()


def finish(verdict: str, stage: str, detail: str, result_path: pathlib.Path | None) -> int:
    payload = {"verdict": verdict, "stage": stage, "detail": detail}
    print(json.dumps(payload))
    if result_path is not None:
        result_path.parent.mkdir(parents=True, exist_ok=True)
        result_path.write_text(json.dumps(payload, indent=2) + "\n")
    return 0 if verdict == "PASS" else 1


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--candidate", required=True)
    ap.add_argument("--seed", type=int, default=101)
    ap.add_argument("--result", default=None)
    args, _ = ap.parse_known_args()

    cand = pathlib.Path(args.candidate).resolve()
    res_path = pathlib.Path(args.result).resolve() if args.result else None

    # 1. Check read-only integrity if candidate contains non-editable public files
    for pub_f in sorted(PUBLIC_DIR.rglob("*")):
        if not pub_f.is_file():
            continue
        rel = pub_f.relative_to(PUBLIC_DIR).as_posix()
        if rel in EDITABLE:
            continue
        cand_f = cand / rel
        if cand_f.exists() and sha256_file(cand_f) != sha256_file(pub_f):
            return finish("FAIL", "structural", f"Read-only file modified: {rel}", res_path)

    with tempfile.TemporaryDirectory(prefix="grade_22006_") as tmp:
        wdir = pathlib.Path(tmp)
        shutil.copytree(PUBLIC_DIR / "code", wdir / "code")
        for rel in EDITABLE:
            src = cand / rel
            if src.exists():
                shutil.copy2(src, wdir / rel)

        # 2. Structural & anti-hack checks on editable RTL
        for rel in EDITABLE:
            txt = (wdir / rel).read_text(errors="replace")
            txt_nocomment = re.sub(r"//.*?$|/\*.*?\*/", "", txt, flags=re.M | re.S)
            for pat, msg in FORBIDDEN_PATTERNS:
                if re.search(pat, txt_nocomment):
                    return finish("FAIL", "structural", f"{rel}: {msg}", res_path)

        dec_txt = re.sub(r"//.*?$|/\*.*?\*/", "", (wdir / "code/redmule_inst_decoder.sv").read_text(errors="replace"), flags=re.M | re.S)
        ctrl_txt = re.sub(r"//.*?$|/\*.*?\*/", "", (wdir / "code/redmule_ctrl.sv").read_text(errors="replace"), flags=re.M | re.S)
        if not re.search(r"\bmodule\s+redmule_inst_decoder\b", dec_txt):
            return finish("FAIL", "structural", "Missing module redmule_inst_decoder", res_path)
        if not re.search(r"\bmodule\s+redmule_ctrl\b", ctrl_txt) or not re.search(r"\bredmule_tiler\b", ctrl_txt):
            return finish("FAIL", "structural", "redmule_ctrl must preserve redmule_tiler instantiation", res_path)

        # 3. Functional simulation via Verilator
        sim_bin = wdir / "obj_dir" / "Vtb"
        v_cmd = [
            str(VERILATOR),
            "--binary",
            "--timing",
            "-sv",
            "-Wno-fatal",
            "-Wno-DECLFILENAME",
            "-Wno-UNUSEDPARAM",
            "-Wno-UNUSEDSIGNAL",
            "-Wno-PINCONNECTEMPTY",
            "-Wno-WIDTHEXPAND",
            "-Wno-WIDTHTRUNC",
            f"+incdir+{wdir / 'code/include'}",
            *[str(wdir / f) for f in RTL_SOURCES],
            str(TESTS_DIR / "tb.sv"),
            "--top-module",
            "tb",
            "--Mdir",
            str(wdir / "obj_dir"),
        ]
        try:
            comp = subprocess.run(v_cmd, capture_output=True, text=True, timeout=150)
        except subprocess.TimeoutExpired:
            return finish("FAIL", "compile", "Verilator compilation timed out", res_path)
        if comp.returncode != 0 or not sim_bin.exists():
            tail = (comp.stdout + "\n" + comp.stderr)[-1800:]
            return finish("FAIL", "compile", f"Verilator compilation failed:\n{tail}", res_path)

        try:
            sim = subprocess.run([str(sim_bin), f"+SEED={args.seed}"], capture_output=True, text=True, timeout=90)
        except subprocess.TimeoutExpired:
            return finish("FAIL", "functional", f"Simulation timed out (deadlock) (seed={args.seed})", res_path)
        if sim.returncode != 0 or "PASS:" not in sim.stdout:
            tail = (sim.stdout + "\n" + sim.stderr)[-1800:]
            return finish("FAIL", "functional", f"Simulation failed (seed={args.seed}):\n{tail}", res_path)

        # 4. Yosys + slang elaboration, zero-latch, SCC loop, and combinational x_result_ready_i -> config_valid_o check
        for split_mode in (0, 1):
            ys_Files = " ".join(str(wdir / f) for f in RTL_SOURCES)
            ys_latch_script = f"""
                read_slang --keep-hierarchy --top redmule_xif_offload_subsys -G XifIssueRegisterSplit={split_mode} -I {wdir / 'code/include'} {ys_Files}
                hierarchy -check -top redmule_xif_offload_subsys
                proc; opt
                select -assert-none *redmule_inst_decoder*/t:$*latch* *redmule_ctrl*/t:$*latch*
                flatten; opt
                scc -expect 0
            """
            yr = subprocess.run([str(YOSYS), "-m", "slang", "-p", ys_latch_script], capture_output=True, text=True, timeout=120)
            if yr.returncode != 0:
                tail = (yr.stdout + "\n" + yr.stderr)[-1800:]
                return finish("FAIL", "synthesis", f"Yosys synthesis/latch/SCC check failed (Split={split_mode}):\n{tail}", res_path)

            dec_only_files = " ".join(str(wdir / f) for f in RTL_SOURCES[:-1])
            cone_sv = wdir / f"dec_cone_{split_mode}.sv"
            cone_sv.write_text(f"""
module dec_cone_chk import redmule_pkg::*; import redmule_xif_pkg::*; (
  input  logic                    clk_i, rst_ni, clear_i, config_ready_i, op_done_i,
  output logic                    config_valid_o,
  output redmule_config_t         config_o,
  input  default_xif_issue_req_t  x_issue_req_i,
  output default_xif_issue_resp_t x_issue_resp_o,
  input  logic                    x_issue_valid_i,
  output logic                    x_issue_ready_o,
  input  default_xif_register_t   x_register_i,
  input  logic                    x_register_valid_i,
  output logic                    x_register_ready_o,
  input  default_xif_commit_t     x_commit_i,
  input  logic                    x_commit_valid_i,
  output default_xif_result_t     x_result_o,
  output logic                    x_result_valid_o,
  input  logic                    x_result_ready_i
);
  redmule_inst_decoder #(
    .XifNumHarts(2), .XifIdWidth(4), .XifIssueRegisterSplit({split_mode}),
    .x_issue_req_t(default_xif_issue_req_t), .x_issue_resp_t(default_xif_issue_resp_t),
    .x_register_t(default_xif_register_t), .x_commit_t(default_xif_commit_t), .x_result_t(default_xif_result_t)
  ) u_dec (.*);
endmodule
""")
            ys_dec_cone = f"""
                read_slang --top dec_cone_chk -I {wdir / 'code/include'} {dec_only_files} {cone_sv}
                hierarchy -check -top dec_cone_chk
                flatten; proc; memory -nomap; opt; opt_clean
                delete t:$*dff* t:$*latch* t:$mem*
                select -assert-none i:x_result_ready_i %co* o:config_valid_o %i
            """
            yc = subprocess.run([str(YOSYS), "-m", "slang", "-p", ys_dec_cone], capture_output=True, text=True, timeout=120)
            if yc.returncode != 0:
                tail = (yc.stdout + "\n" + yc.stderr)[-1800:]
                return finish("FAIL", "synthesis", f"Combinational x_result_ready_i -> config_valid_o path detected (Split={split_mode}):\n{tail}", res_path)

    return finish("PASS", "all_checks", f"All XIF, controller, zero-latch, and cone checks passed (seed={args.seed})", res_path)


if __name__ == "__main__":
    raise SystemExit(main())
