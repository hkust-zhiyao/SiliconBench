#!/usr/bin/env python3
import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
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


TASK_DIR = Path(__file__).resolve().parents[2]
PUBLIC_DIR = TASK_DIR / "public"
TESTS_DIR = TASK_DIR / "private" / "tests"

IVERILOG = f"{_sb_tools_dir()}/iverilog-v13/bin/iverilog"
VVP = f"{_sb_tools_dir()}/iverilog-v13/bin/vvp"
VERILATOR = f"{_sb_tools_dir()}/verilator-v5.038/bin/verilator"
YOSYS = f"{_sb_tools_dir()}/oss-cad-suite/bin/yosys"
SIMCELLS = f"{_sb_tools_dir()}/oss-cad-suite/share/yosys/simcells.v"

EDITABLE = [
    "code/arp.v",
    "code/arp_cache.v",
    "code/arp_eth_rx.v",
    "code/arp_eth_tx.v",
]
READONLY = [
    "code/lfsr.v",
    "code/LICENSE",
]

GL_WRAP_SV = """`timescale 1ns / 1ps
module arp_gl_wrap (
    input  wire         clk,
    input  wire         rst,
    input  wire         s_eth_hdr_valid,
    output wire         s_eth_hdr_ready,
    input  wire [47:0]  s_eth_dest_mac,
    input  wire [47:0]  s_eth_src_mac,
    input  wire [15:0]  s_eth_type,
    input  wire [255:0] s_eth_payload_axis_tdata,
    input  wire [31:0]  s_eth_payload_axis_tkeep,
    input  wire         s_eth_payload_axis_tvalid,
    output wire         s_eth_payload_axis_tready,
    input  wire         s_eth_payload_axis_tlast,
    input  wire         s_eth_payload_axis_tuser,
    output wire         m_eth_hdr_valid,
    input  wire         m_eth_hdr_ready,
    output wire [47:0]  m_eth_dest_mac,
    output wire [47:0]  m_eth_src_mac,
    output wire [15:0]  m_eth_type,
    output wire [255:0] m_eth_payload_axis_tdata,
    output wire [31:0]  m_eth_payload_axis_tkeep,
    output wire         m_eth_payload_axis_tvalid,
    input  wire         m_eth_payload_axis_tready,
    output wire         m_eth_payload_axis_tlast,
    output wire         m_eth_payload_axis_tuser,
    input  wire         arp_request_valid,
    output wire         arp_request_ready,
    input  wire [31:0]  arp_request_ip,
    output wire         arp_response_valid,
    input  wire         arp_response_ready,
    output wire         arp_response_error,
    output wire [47:0]  arp_response_mac,
    input  wire [47:0]  local_mac,
    input  wire [31:0]  local_ip,
    input  wire [31:0]  gateway_ip,
    input  wire [31:0]  subnet_mask,
    input  wire         clear_cache,
    input  wire         rx64_hdr_v,
    output wire         rx64_hdr_r,
    input  wire [63:0]  rx64_tdata,
    input  wire [7:0]   rx64_tkeep,
    input  wire         rx64_tvalid,
    output wire         rx64_tready,
    input  wire         rx64_tlast,
    input  wire         rx64_tuser,
    output wire         rx64_m_v,
    output wire         rx64_busy,
    output wire         rx64_err_e,
    output wire         rx64_err_i
);
    arp #(
        .DATA_WIDTH(256),
        .CACHE_ADDR_WIDTH(2),
        .REQUEST_RETRY_COUNT(2),
        .REQUEST_RETRY_INTERVAL(10),
        .REQUEST_TIMEOUT(18)
    ) u_arp (
        .clk(clk), .rst(rst),
        .s_eth_hdr_valid(s_eth_hdr_valid), .s_eth_hdr_ready(s_eth_hdr_ready),
        .s_eth_dest_mac(s_eth_dest_mac), .s_eth_src_mac(s_eth_src_mac), .s_eth_type(s_eth_type),
        .s_eth_payload_axis_tdata(s_eth_payload_axis_tdata), .s_eth_payload_axis_tkeep(s_eth_payload_axis_tkeep),
        .s_eth_payload_axis_tvalid(s_eth_payload_axis_tvalid), .s_eth_payload_axis_tready(s_eth_payload_axis_tready),
        .s_eth_payload_axis_tlast(s_eth_payload_axis_tlast), .s_eth_payload_axis_tuser(s_eth_payload_axis_tuser),
        .m_eth_hdr_valid(m_eth_hdr_valid), .m_eth_hdr_ready(m_eth_hdr_ready),
        .m_eth_dest_mac(m_eth_dest_mac), .m_eth_src_mac(m_eth_src_mac), .m_eth_type(m_eth_type),
        .m_eth_payload_axis_tdata(m_eth_payload_axis_tdata), .m_eth_payload_axis_tkeep(m_eth_payload_axis_tkeep),
        .m_eth_payload_axis_tvalid(m_eth_payload_axis_tvalid), .m_eth_payload_axis_tready(m_eth_payload_axis_tready),
        .m_eth_payload_axis_tlast(m_eth_payload_axis_tlast), .m_eth_payload_axis_tuser(m_eth_payload_axis_tuser),
        .arp_request_valid(arp_request_valid), .arp_request_ready(arp_request_ready),
        .arp_request_ip(arp_request_ip),
        .arp_response_valid(arp_response_valid), .arp_response_ready(arp_response_ready),
        .arp_response_error(arp_response_error), .arp_response_mac(arp_response_mac),
        .local_mac(local_mac), .local_ip(local_ip), .gateway_ip(gateway_ip),
        .subnet_mask(subnet_mask), .clear_cache(clear_cache)
    );
    arp_eth_rx #(.DATA_WIDTH(64)) u_rx64 (
        .clk(clk), .rst(rst),
        .s_eth_hdr_valid(rx64_hdr_v), .s_eth_hdr_ready(rx64_hdr_r),
        .s_eth_dest_mac(48'd0), .s_eth_src_mac(48'd0), .s_eth_type(16'h0806),
        .s_eth_payload_axis_tdata(rx64_tdata), .s_eth_payload_axis_tkeep(rx64_tkeep),
        .s_eth_payload_axis_tvalid(rx64_tvalid), .s_eth_payload_axis_tready(rx64_tready),
        .s_eth_payload_axis_tlast(rx64_tlast), .s_eth_payload_axis_tuser(rx64_tuser),
        .m_frame_valid(rx64_m_v), .m_frame_ready(1'b1),
        .m_eth_dest_mac(), .m_eth_src_mac(), .m_eth_type(),
        .m_arp_htype(), .m_arp_ptype(), .m_arp_hlen(), .m_arp_plen(),
        .m_arp_oper(), .m_arp_sha(), .m_arp_spa(), .m_arp_tha(), .m_arp_tpa(),
        .busy(rx64_busy),
        .error_header_early_termination(rx64_err_e),
        .error_invalid_header(rx64_err_i)
    );
endmodule
"""


def strip_comments(txt: str) -> str:
    txt = re.sub(r"/\*.*?\*/", lambda m: "\n" * m.group(0).count("\n"), txt, flags=re.DOTALL)
    txt = re.sub(r"//[^\n]*", "", txt)
    return txt


def strip_initial_blocks_for_yosys(txt: str) -> str:
    # Strip comments first so words like 'initial'/'begin'/'end' in comments never confuse block matching
    clean = strip_comments(txt)
    tokens = re.split(r'("(?:\\.|[^"\\])*"|\binitial\b|\bbegin\b|\bend\b|;)', clean)
    out = []
    i = 0
    while i < len(tokens):
        if tokens[i] == "initial":
            j = i + 1
            while j < len(tokens) and tokens[j].strip() == "":
                j += 1
            if j < len(tokens) and tokens[j] == "begin":
                depth = 1
                j += 1
                while j < len(tokens) and depth > 0:
                    if tokens[j] == "begin":
                        depth += 1
                    elif tokens[j] == "end":
                        depth -= 1
                    j += 1
                i = j
                continue
            else:
                while j < len(tokens) and tokens[j] != ";":
                    j += 1
                i = j + 1
                continue
        out.append(tokens[i])
        i += 1
    return "".join(out)


def sha256_file(p: Path) -> str:
    return hashlib.sha256(p.read_bytes()).hexdigest()


def run_cmd(cmd, *, timeout=90, env=None):
    try:
        cp = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, env=env)
        return cp.returncode, cp.stdout, cp.stderr, False
    except subprocess.TimeoutExpired as exc:
        out = exc.stdout if isinstance(exc.stdout, str) else ""
        err = exc.stderr if isinstance(exc.stderr, str) else ""
        return 124, out, err + f"\nTimeoutExpired after {timeout}s", True


def write_result(path: Path, verdict: str, stage: str, detail: str, metrics=None):
    payload = {
        "verdict": verdict,
        "stage": stage,
        "detail": detail,
        "metrics": metrics or {},
    }
    path.write_text(json.dumps(payload, indent=2) + "\n")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--candidate", required=True)
    ap.add_argument("--result", required=True)
    ap.add_argument("--seed", type=int, default=101)
    args = ap.parse_args()

    cand = Path(args.candidate).resolve()
    res_path = Path(args.result).resolve()

    # 1. Policy checks
    for rel in READONLY:
        cp = cand / rel
        pp = PUBLIC_DIR / rel
        if cp.exists() and sha256_file(cp) != sha256_file(pp):
            write_result(res_path, "FAIL", "policy", f"Tampered read-only file: {rel}")
            return 1

    for rel in EDITABLE:
        cp = cand / rel
        pp = PUBLIC_DIR / rel
        if not cp.exists():
            write_result(res_path, "FAIL", "policy", f"Missing editable file: {rel}")
            return 1
        c_clean = strip_comments(cp.read_text(errors="replace"))
        p_clean = strip_comments(pp.read_text(errors="replace"))

        for systask in (r"\$finish\b", r"\$stop\b", r"\$fatal\b", r"\$readmem[bh]\b", r"\$system\b"):
            if len(re.findall(systask, c_clean)) > len(re.findall(systask, p_clean)):
                write_result(res_path, "FAIL", "policy", f"Forbidden system task ({systask}) in {rel}")
                return 1
        if re.search(r"\b(force|release)\b", c_clean):
            write_result(res_path, "FAIL", "policy", f"Forbidden force/release in {rel}")
            return 1
        if re.search(r"`\s*ifn?def\s+(SYNTHESIS|VERILATOR|__ICARUS__)\b", c_clean):
            write_result(res_path, "FAIL", "policy", f"Forbidden tool-divergence macro in {rel}")
            return 1
        if re.search(r"\b(tb|tb_gl|\$root)\s*\.", c_clean):
            write_result(res_path, "FAIL", "policy", f"Forbidden hierarchical testbench reference in {rel}")
            return 1

    with tempfile.TemporaryDirectory(prefix="grade_21023_") as tmp:
        wdir = Path(tmp)
        (wdir / "code").mkdir()
        for rel in EDITABLE:
            shutil.copy2(cand / rel, wdir / rel)
        for rel in READONLY:
            shutil.copy2(PUBLIC_DIR / rel, wdir / rel)

        rtl_files = [str(wdir / r) for r in EDITABLE] + [str(wdir / "code/lfsr.v")]
        tb_sv = str(TESTS_DIR / "tb.sv")

        # 2. Icarus Verilog simulation
        sim_vvp = str(wdir / "sim.vvp")
        rc, out, err, _ = run_cmd(
            [IVERILOG, "-g2012", f"-Ptb.SEED={args.seed}", "-o", sim_vvp] + rtl_files + [tb_sv],
            timeout=60,
        )
        if rc != 0:
            write_result(res_path, "FAIL", "compile", f"iverilog compile failed: {err[-400:]}")
            return 1
        rc, out, err, _ = run_cmd([VVP, sim_vvp], timeout=60)
        if rc != 0 or "PASS:" not in out or "FAIL:" in out:
            tail = (out + "\n" + err).strip()[-500:]
            write_result(res_path, "FAIL", "functional", f"Icarus functional check failed: {tail}")
            return 1

        # 3. Verilator simulation (parity check)
        env_v = os.environ.copy()
        env_v.pop("VERILATOR_ROOT", None)
        v_dir = wdir / "obj_dir"
        rc, out, err, _ = run_cmd(
            [
                VERILATOR, "--binary", "--timing", "-Wno-fatal", "-j", "2",
                "-O1", "-CFLAGS", "-O0",
                f"-GSEED={args.seed}", "--Mdir", str(v_dir), "--top-module", "tb",
            ] + rtl_files + [tb_sv],
            timeout=120, env=env_v,
        )
        if rc != 0:
            write_result(res_path, "FAIL", "compile", f"Verilator compile failed: {err[-400:]}")
            return 1
        rc, out, err, _ = run_cmd([str(v_dir / "Vtb")], timeout=60)
        if rc != 0 or "PASS:" not in out or "FAIL:" in out:
            tail = (out + "\n" + err).strip()[-500:]
            write_result(res_path, "FAIL", "functional", f"Verilator functional check failed: {tail}")
            return 1

        # 4. Yosys initializer-stripped latch & combinational-loop check + Gate-Level netlist
        syn_dir = wdir / "syn"
        syn_dir.mkdir()
        lfsr_bb = syn_dir / "lfsr_bb.v"
        lfsr_bb.write_text(
            'module lfsr #(\n'
            '    parameter LFSR_WIDTH = 31,\n'
            '    parameter LFSR_POLY = 31\'h10000001,\n'
            '    parameter LFSR_CONFIG = "FIBONACCI",\n'
            '    parameter LFSR_FEED_FORWARD = 0,\n'
            '    parameter REVERSE = 0,\n'
            '    parameter DATA_WIDTH = 8,\n'
            '    parameter STYLE = "AUTO"\n'
            ') (\n'
            '    input  wire [DATA_WIDTH-1:0] data_in,\n'
            '    input  wire [LFSR_WIDTH-1:0] state_in,\n'
            '    output wire [DATA_WIDTH-1:0] data_out,\n'
            '    output wire [LFSR_WIDTH-1:0] state_out\n'
            ');\n'
            'endmodule\n'
        )
        syn_files = []
        for rel in EDITABLE:
            src_txt = (wdir / rel).read_text(errors="replace")
            dst_p = syn_dir / Path(rel).name
            dst_p.write_text(strip_initial_blocks_for_yosys(src_txt))
            syn_files.append(str(dst_p))
        wrap_p = syn_dir / "arp_gl_wrap.v"
        wrap_p.write_text(GL_WRAP_SV)
        syn_files.append(str(wrap_p))

        netlist_v = syn_dir / "netlist.v"
        ys_cmd = (
            f"read_verilog -lib {lfsr_bb}; "
            f"read_verilog -defer {' '.join(syn_files)}; "
            "hierarchy -check -top arp_gl_wrap; "
            "proc; opt_expr; opt_clean; setattr -unset init w:*; "
            "flatten; opt_expr; opt_clean; "
            "select -assert-none t:$dlatch* t:$_DLATCH*; "
            "synth -noabc -top arp_gl_wrap; "
            "check -assert; select -assert-none t:$dlatch* t:$_DLATCH*; "
            f"write_verilog -noattr {netlist_v}"
        )
        rc, out, err, _ = run_cmd([YOSYS, "-q", "-p", ys_cmd], timeout=90)
        if rc != 0 or not netlist_v.exists():
            tail = (out + "\n" + err).strip()[-500:]
            write_result(res_path, "FAIL", "synthesis", f"Yosys latch/loop check failed: {tail}")
            return 1

        # 5. 4-State Gate-Level Zero-X simulation
        gl_vvp = str(syn_dir / "gl.vvp")
        rc, out, err, _ = run_cmd(
            [
                IVERILOG, "-g2012", "-o", gl_vvp,
                SIMCELLS, str(PUBLIC_DIR / "code/lfsr.v"), str(netlist_v), str(TESTS_DIR / "tb_gl.sv"),
            ],
            timeout=60,
        )
        if rc != 0:
            write_result(res_path, "FAIL", "synthesis", f"GL iverilog compile failed: {err[-400:]}")
            return 1
        rc, out, err, _ = run_cmd([VVP, gl_vvp], timeout=60)
        if rc != 0 or "PASS_GL:" not in out or "FAIL_GL:" in out:
            tail = (out + "\n" + err).strip()[-500:]
            write_result(res_path, "FAIL", "functional", f"Gate-level Zero-X check failed: {tail}")
            return 1

    write_result(
        res_path, "PASS", "all",
        f"All Icarus, Verilator, Yosys initializer-stripped latch/loop, and Gate-Level Zero-X checks passed (seed={args.seed})",
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
