#!/usr/bin/env python3
import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

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


TASK_DIR  = Path(__file__).resolve().parents[2]
PUB_DIR   = TASK_DIR / "public"
TESTS_DIR = TASK_DIR / "private" / "tests"

IVERILOG  = f"{_sb_tools_dir()}/iverilog-v13/bin/iverilog"
VVP       = f"{_sb_tools_dir()}/iverilog-v13/bin/vvp"
VERILATOR = f"{_sb_tools_dir()}/verilator-v5.038/bin/verilator"
YOSYS     = f"{_sb_tools_dir()}/oss-cad-suite/bin/yosys"
SIMCELLS  = f"{_sb_tools_dir()}/oss-cad-suite/share/yosys/simcells.v"

EDITABLE_FILES = [
    "code/axil_crossbar.v",
    "code/axil_crossbar_addr.v",
    "code/axil_crossbar_wr.v",
    "code/axil_crossbar_rd.v",
]
READONLY_FILES = [
    "code/arbiter.v",
    "code/priority_encoder.v",
    "code/axil_register_wr.v",
    "code/axil_register_rd.v",
    "code/COPYING",
]


def sha256_file(p: Path) -> str:
    return hashlib.sha256(p.read_bytes()).hexdigest()


def strip_comments_and_strings(src: str) -> str:
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
                i += 1
            i += 2
        elif src[i] == '"':
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


def strip_initial_blocks(clean: str) -> str:
    # Allow benign elaboration-only $finish inside `initial begin ... end` (as present in upstream),
    # while still catching any $finish/$fatal/$stop added outside elaboration checks or any newly added $stop/$fatal/$system/$readmem* anywhere.
    res = clean
    while True:
        m = re.search(r"\binitial\s+begin\b", res)
        if not m:
            break
        pos = m.end()
        depth = 1
        while pos < len(res) and depth > 0:
            tok = re.search(r"\b(begin|end)\b", res[pos:])
            if not tok:
                pos = len(res)
                break
            if tok.group(1) == "begin":
                depth += 1
            else:
                depth -= 1
            pos += tok.end()
        res = res[:m.start()] + " " + res[pos:]
    return res


def write_res(path: Path, verdict: str, stage: str, detail: str) -> int:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps({"verdict": verdict, "stage": stage, "detail": detail}, indent=2) + "\n")
    return 0 if verdict == "PASS" else 1


def check_policy(cand: Path):
    for rel in READONLY_FILES:
        cp = cand / rel
        pp = PUB_DIR / rel
        if not cp.is_file() or sha256_file(cp) != sha256_file(pp):
            return ("policy", f"Read-only file missing or tampered: {rel}")

    for rel in EDITABLE_FILES:
        cp = cand / rel
        if not cp.is_file():
            return ("structural", f"Missing editable RTL file: {rel}")
        clean = strip_comments_and_strings(cp.read_text(errors="replace"))
        if re.search(r"\$(?:fatal|stop|system|fopen|fwrite|fdisplay|fscanf|readmemh|readmemb|writememh|writememb)\b", clean):
            return ("policy", f"Policy violation in {rel}: forbidden_systask")
        non_init = strip_initial_blocks(clean)
        if re.search(r"\$finish\b", non_init):
            return ("policy", f"Policy violation in {rel}: runtime_finish_systask")
        if re.search(r"`\s*ifdef\s+(?:SYNTHESIS|VERILATOR|__ICARUS__)\b", clean) or re.search(
            r"`\s*ifndef\s+(?:SYNTHESIS|VERILATOR|__ICARUS__)\b", clean
        ):
            return ("policy", f"Policy violation in {rel}: conditional_sim_synth_divergence")
        if re.search(r"\b(?:tb|tb_gl|\$root)\s*\.", clean) or re.search(r"\bforce\b|\brelease\b", clean):
            return ("policy", f"Policy violation in {rel}: hierarchical_or_force_hack")
    return None


def run_cmd(cmd, cwd: Path, timeout_sec: int = 180):
    env = dict(os.environ)
    env.pop("VERILATOR_ROOT", None)
    try:
        return subprocess.run(cmd, cwd=str(cwd), env=env, text=True, capture_output=True, timeout=timeout_sec)
    except subprocess.TimeoutExpired as exc:
        out = exc.stdout if isinstance(exc.stdout, str) else (exc.stdout.decode("utf-8", "replace") if exc.stdout else "")
        err = exc.stderr if isinstance(exc.stderr, str) else (exc.stderr.decode("utf-8", "replace") if exc.stderr else "")
        return subprocess.CompletedProcess(cmd, 124, out, err + f"\nTIMEOUT after {timeout_sec}s")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--candidate", required=True)
    ap.add_argument("--result", required=True)
    ap.add_argument("--seed", type=int, default=101)
    args, _ = ap.parse_known_args()

    cand = Path(args.candidate).resolve()
    res_path = Path(args.result).resolve()

    pol = check_policy(cand)
    if pol is not None:
        return write_res(res_path, "FAIL", pol[0], pol[1])

    rtl_files = [
        cand / "code/priority_encoder.v",
        cand / "code/arbiter.v",
        cand / "code/axil_register_wr.v",
        cand / "code/axil_register_rd.v",
        cand / "code/axil_crossbar_addr.v",
        cand / "code/axil_crossbar_wr.v",
        cand / "code/axil_crossbar_rd.v",
        cand / "code/axil_crossbar.v",
    ]
    tb_sv = TESTS_DIR / "tb.sv"
    tb_gl_sv = TESTS_DIR / "tb_gl.sv"

    work = Path(tempfile.mkdtemp(prefix="grade_21017_"))
    try:
        # 1. Icarus Verilog 4-State RTL Simulation
        vvp_bin = work / "sim_iv.vvp"
        p = run_cmd([IVERILOG, "-g2012", f"-Ptb.SEED={args.seed}", "-o", str(vvp_bin), str(tb_sv)] + [str(f) for f in rtl_files], work)
        if p.returncode != 0:
            return write_res(res_path, "FAIL", "structural", f"Icarus compile failed:\n{(p.stdout + p.stderr)[-900:]}")
        p = run_cmd([VVP, "-N", str(vvp_bin)], work, timeout_sec=45)
        if p.returncode != 0 or f"PASS seed={args.seed}" not in p.stdout or "FAIL" in p.stdout:
            return write_res(res_path, "FAIL", "functional", f"Icarus RTL simulation failed:\n{(p.stdout + p.stderr)[-900:]}")

        # 2. Verilator Simulation
        vdir = work / "obj_verilator"
        p = run_cmd(
            [
                VERILATOR,
                "--binary",
                "--timing",
                "--output-split",
                "0",
                "-Wno-fatal",
                "-j",
                "1",
                f"-GSEED={args.seed}",
                "--top-module",
                "tb",
                "--Mdir",
                str(vdir),
                "-o",
                "Vtb",
                str(tb_sv),
            ]
            + [str(f) for f in rtl_files],
            work,
            timeout_sec=240,
        )
        if p.returncode != 0:
            return write_res(res_path, "FAIL", "structural", f"Verilator build failed:\n{(p.stdout + p.stderr)[-900:]}")
        p = run_cmd([str(vdir / "Vtb")], work, timeout_sec=45)
        if p.returncode != 0 or f"PASS seed={args.seed}" not in p.stdout or "FAIL" in p.stdout:
            return write_res(res_path, "FAIL", "functional", f"Verilator simulation failed:\n{(p.stdout + p.stderr)[-900:]}")

        # 3. Yosys Synthesis Cleanliness (1x3, 3x1, and 2x3 overlapping+coupled+zero-slice) + Initializer-Stripped Gate-Level Zero-X Sim
        ys_dir = work / "ys_src"
        ys_dir.mkdir(parents=True, exist_ok=True)
        ys_files = []
        for idx, f in enumerate(rtl_files):
            dst = ys_dir / f"{idx:02d}_{f.name}"
            dst.write_text(re.sub(r"\$error\s*\(", "$display(", f.read_text(errors="replace")))
            ys_files.append(dst)

        for s_c, m_c in [(1, 3), (3, 1)]:
            ys_edge = (
                f"read_verilog -sv {' '.join(str(f) for f in ys_files)}; "
                f"hierarchy -check -top axil_crossbar -chparam S_COUNT {s_c} -chparam M_COUNT {m_c}; "
                f"proc; flatten; select -assert-none t:$dlatch* t:$_DLATCH*; check -assert"
            )
            p = run_cmd([YOSYS, "-q", "-p", ys_edge], work, timeout_sec=120)
            if p.returncode != 0:
                return write_res(res_path, "FAIL", "synthesis", f"Yosys {s_c}x{m_c} synthesis check failed:\n{(p.stdout + p.stderr)[-900:]}")

        gl_wrap = work / "gl_wrap.v"
        gl_wrap.write_text(
            "`timescale 1ns / 1ps\n"
            "module axil_crossbar_gl (\n"
            "    input  wire        clk, rst,\n"
            "    input  wire [63:0] s_axil_awaddr, s_axil_wdata, s_axil_araddr,\n"
            "    input  wire [5:0]  s_axil_awprot, s_axil_arprot,\n"
            "    input  wire [7:0]  s_axil_wstrb,\n"
            "    input  wire [1:0]  s_axil_awvalid, s_axil_wvalid, s_axil_bready, s_axil_arvalid, s_axil_rready,\n"
            "    output wire [1:0]  s_axil_awready, s_axil_wready, s_axil_bvalid, s_axil_arready, s_axil_rvalid,\n"
            "    output wire [3:0]  s_axil_bresp, s_axil_rresp,\n"
            "    output wire [63:0] s_axil_rdata,\n"
            "    output wire [95:0] m_axil_awaddr, m_axil_wdata, m_axil_araddr,\n"
            "    output wire [8:0]  m_axil_awprot, m_axil_arprot,\n"
            "    output wire [11:0] m_axil_wstrb,\n"
            "    output wire [2:0]  m_axil_awvalid, m_axil_wvalid, m_axil_bready, m_axil_arvalid, m_axil_rready,\n"
            "    input  wire [2:0]  m_axil_awready, m_axil_wready, m_axil_bvalid, m_axil_arready, m_axil_rvalid,\n"
            "    input  wire [5:0]  m_axil_bresp, m_axil_rresp,\n"
            "    input  wire [95:0] m_axil_rdata\n"
            ");\n"
            "    axil_crossbar #(\n"
            "        .S_COUNT(2), .M_COUNT(3), .M_REGIONS(2),\n"
            "        .M_BASE_ADDR({32'h4000_2000, 32'h4000_0000, 32'h0, 32'h4000_1000, 32'h0, 32'h0}),\n"
            "        .M_ADDR_WIDTH({32'd12, 32'd16, 32'd0, 32'd12, 32'd0, 32'd32}),\n"
            "        .M_SECURE(3'b010),\n"
            "        .M_AW_REG_TYPE({2'd0, 2'd1, 2'd1}),\n"
            "        .M_W_REG_TYPE({2'd0, 2'd2, 2'd2}),\n"
            "        .M_B_REG_TYPE({3{2'd0}}),\n"
            "        .M_R_REG_TYPE({3{2'd0}})\n"
            "    ) u_core (\n"
            "        .clk(clk), .rst(rst),\n"
            "        .s_axil_awaddr(s_axil_awaddr), .s_axil_awprot(s_axil_awprot), .s_axil_awvalid(s_axil_awvalid), .s_axil_awready(s_axil_awready),\n"
            "        .s_axil_wdata(s_axil_wdata), .s_axil_wstrb(s_axil_wstrb), .s_axil_wvalid(s_axil_wvalid), .s_axil_wready(s_axil_wready),\n"
            "        .s_axil_bresp(s_axil_bresp), .s_axil_bvalid(s_axil_bvalid), .s_axil_bready(s_axil_bready),\n"
            "        .s_axil_araddr(s_axil_araddr), .s_axil_arprot(s_axil_arprot), .s_axil_arvalid(s_axil_arvalid), .s_axil_arready(s_axil_arready),\n"
            "        .s_axil_rdata(s_axil_rdata), .s_axil_rresp(s_axil_rresp), .s_axil_rvalid(s_axil_rvalid), .s_axil_rready(s_axil_rready),\n"
            "        .m_axil_awaddr(m_axil_awaddr), .m_axil_awprot(m_axil_awprot), .m_axil_awvalid(m_axil_awvalid), .m_axil_awready(m_axil_awready),\n"
            "        .m_axil_wdata(m_axil_wdata), .m_axil_wstrb(m_axil_wstrb), .m_axil_wvalid(m_axil_wvalid), .m_axil_wready(m_axil_wready),\n"
            "        .m_axil_bresp(m_axil_bresp), .m_axil_bvalid(m_axil_bvalid), .m_axil_bready(m_axil_bready),\n"
            "        .m_axil_araddr(m_axil_araddr), .m_axil_arprot(m_axil_arprot), .m_axil_arvalid(m_axil_arvalid), .m_axil_arready(m_axil_arready),\n"
            "        .m_axil_rdata(m_axil_rdata), .m_axil_rresp(m_axil_rresp), .m_axil_rvalid(m_axil_rvalid), .m_axil_rready(m_axil_rready)\n"
            "    );\n"
            "endmodule\n"
        )
        gl_net = work / "dut_gl.v"
        ys_gl = (
            f"read_verilog -sv {' '.join(str(f) for f in ys_files)} {gl_wrap}; "
            f"hierarchy -check -top axil_crossbar_gl; "
            f"proc; setattr -unset init w:*; flatten; "
            f"select -assert-none t:$dlatch* t:$_DLATCH*; "
            f"synth -top axil_crossbar_gl; "
            f"check -assert; select -assert-none t:$dlatch* t:$_DLATCH*; "
            f"write_verilog -noattr {gl_net}"
        )
        p = run_cmd([YOSYS, "-q", "-p", ys_gl], work)
        if p.returncode != 0:
            return write_res(res_path, "FAIL", "synthesis", f"Yosys gate-level synthesis/loop/latch check failed:\n{(p.stdout + p.stderr)[-900:]}")

        gl_vvp = work / "sim_gl.vvp"
        p = run_cmd([IVERILOG, "-g2012", "-o", str(gl_vvp), str(tb_gl_sv), str(gl_net), SIMCELLS], work)
        if p.returncode != 0:
            return write_res(res_path, "FAIL", "synthesis", f"Gate-level compile failed:\n{(p.stdout + p.stderr)[-900:]}")
        p = run_cmd([VVP, "-N", str(gl_vvp)], work)
        if p.returncode != 0 or "PASS_GL" not in p.stdout or "FAIL" in p.stdout:
            return write_res(res_path, "FAIL", "functional", f"Gate-level Zero-X parity simulation failed:\n{(p.stdout + p.stderr)[-900:]}")

        return write_res(res_path, "PASS", "all", f"All Icarus, Verilator, Yosys 1x3/3x1/loop/latch, and Gate-Level Zero-X checks passed (seed={args.seed})")
    finally:
        shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
