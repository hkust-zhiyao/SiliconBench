#!/usr/bin/env python3
"""Isolated grader for case_22012 (Ara Lane Fixed-Point Rounding, SIMD ALU & VALU S2_elab_synth_sim_parity)."""
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


TASK_DIR = Path(__file__).resolve().parents[2]
PUB_DIR = TASK_DIR / "public"
TESTS_DIR = TASK_DIR / "private" / "tests"
TOOLS = Path(str(_sb_tools_dir()))
VERILATOR = TOOLS / "verilator-v5.038/bin/verilator"
YOSYS = TOOLS / "oss-cad-suite/bin/yosys"
IVERILOG = TOOLS / "iverilog-v13/bin/iverilog"
VVP = TOOLS / "iverilog-v13/bin/vvp"
SIMCELLS = TOOLS / "oss-cad-suite/share/yosys/simcells.v"

EDITABLE = [
    "code/fixed_p_rounding.sv",
    "code/simd_alu.sv",
    "code/valu.sv",
]

READONLY = [
    "code/cf_math_pkg.sv",
    "code/riscv_pkg.sv",
    "code/config_pkg.sv",
    "code/cv64a6_imafdcv_sv39_config_pkg.sv",
    "code/ariane_pkg.sv",
    "code/axi_pkg.sv",
    "code/fpnew_pkg.sv",
    "code/rvv_pkg.sv",
    "code/ara_pkg.sv",
    "code/spill_register_flushable.sv",
    "code/spill_register.sv",
    "code/include/common_cells/registers.svh",
    "code/include/common_cells/assertions.svh",
]

RTL_FILES = [
    "code/cf_math_pkg.sv",
    "code/riscv_pkg.sv",
    "code/config_pkg.sv",
    "code/cv64a6_imafdcv_sv39_config_pkg.sv",
    "code/ariane_pkg.sv",
    "code/axi_pkg.sv",
    "code/fpnew_pkg.sv",
    "code/rvv_pkg.sv",
    "code/ara_pkg.sv",
    "code/spill_register_flushable.sv",
    "code/spill_register.sv",
    "code/fixed_p_rounding.sv",
    "code/simd_alu.sv",
    "code/valu.sv",
]


def sha256_bytes(b: bytes) -> str:
    return hashlib.sha256(b).hexdigest()


def strip_comments(text: str) -> str:
    return re.sub(r"/\*.*?\*/|//[^\n]*", "", text, flags=re.S)


def emit(res_path: Path | None, verdict: str, stage: str, detail: str, rc: int) -> int:
    payload = {"verdict": verdict, "stage": stage, "detail": detail}
    if res_path is not None:
        res_path.parent.mkdir(parents=True, exist_ok=True)
        res_path.write_text(json.dumps(payload, indent=2) + "\n")
    print(json.dumps(payload))
    return rc


def check_structural(cand: Path) -> tuple[bool, str]:
    for rel in READONLY:
        pub_f = PUB_DIR / rel
        cand_f = cand / rel
        if cand_f.exists() and sha256_bytes(cand_f.read_bytes()) != sha256_bytes(pub_f.read_bytes()):
            return False, f"Read-only file modified: {rel}"

    expected_ports = {
        "code/fixed_p_rounding.sv": [
            "module fixed_p_rounding",
            "operand_a_i",
            "operand_b_i",
            "valid_i",
            "op_i",
            "vew_i",
            "vxrm_i",
            "r_o",
        ],
        "code/simd_alu.sv": [
            "module simd_alu",
            "FixPtSupport",
            "operand_a_i",
            "operand_b_i",
            "valid_i",
            "vm_i",
            "mask_i",
            "narrowing_select_i",
            "op_i",
            "vew_i",
            "vxsat_o",
            "rm",
            "vxrm_i",
            "result_o",
        ],
        "code/valu.sv": [
            "module valu",
            "NrLanes",
            "VLEN",
            "FixPtSupport",
            "vxsat_flag_o",
            "alu_vxrm_i",
            "vfu_operation_i",
            "vfu_operation_valid_i",
            "alu_ready_o",
            "alu_vinsn_done_o",
            "alu_operand_i",
            "alu_operand_valid_i",
            "alu_operand_ready_o",
            "alu_result_req_o",
            "alu_result_wdata_o",
            "alu_result_be_o",
            "alu_result_gnt_i",
            "mask_i",
            "mask_valid_i",
            "mask_ready_o",
        ],
    }

    banned_macros = re.compile(
        r"`\s*(?:ifdef|ifndef|elsif)\s+(?:VERILATOR|SYNTHESIS|SIMULATION|__ICARUS__|VCS|QUESTA)\b",
        re.I,
    )
    banned_tasks = re.compile(
        r"\$(?:fopen|fread|fwrite|system|finish|stop|readmemh|readmemb)\b|\b(?:force|release|bind|import\s+\"DPI)\b"
    )

    for rel, req_tokens in expected_ports.items():
        f = cand / rel
        if not f.is_file() or f.is_symlink():
            return False, f"Missing or symlinked editable file: {rel}"
        clean = strip_comments(f.read_text(errors="replace"))
        for tok in req_tokens:
            if tok not in clean:
                return False, f"Missing required module/port/parameter identifier `{tok}` in {rel}"
        if banned_macros.search(clean):
            return False, f"Forbidden simulator/synthesis macro divergence in {rel}"
        if banned_tasks.search(clean):
            return False, f"Forbidden system task, DPI, or procedural force/bind in {rel}"

    return True, "ok"


def run_cmd(cmd, cwd, timeout=180):
    env = os.environ.copy()
    if (TOOLS / "verilator-v5.038/share/verilator").exists():
        env["VERILATOR_ROOT"] = str(TOOLS / "verilator-v5.038/share/verilator")
    return subprocess.run(
        cmd, cwd=cwd, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=timeout
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--candidate", required=True)
    parser.add_argument("--seed", type=int, default=101)
    parser.add_argument("--result", default=None)
    args, _ = parser.parse_known_args()

    cand = Path(args.candidate).resolve()
    res_path = Path(args.result).resolve() if args.result else None

    ok, msg = check_structural(cand)
    if not ok:
        return emit(res_path, "FAIL", "structural", msg, 1)

    current_stage = "functional"
    try:
        with tempfile.TemporaryDirectory(prefix="case_22012_grade_") as tmp:
            work = Path(tmp)
            shutil.copytree(PUB_DIR / "code", work / "code")
            for rel in EDITABLE:
                shutil.copy2(cand / rel, work / rel)
            shutil.copy2(TESTS_DIR / "tb.sv", work / "tb.sv")
            shutil.copy2(TESTS_DIR / "tb_gl.sv", work / "tb_gl.sv")
            shutil.copy2(TESTS_DIR / "syn_wrap.sv", work / "syn_wrap.sv")

            gl_gen_sv = work / "gen_gl_vec.sv"
            gl_gen_sv.write_text(
                """`timescale 1ns/1ps
module gen_gl_vec;
  import ara_pkg::*;
  import rvv_pkg::*;
  initial begin
    int fd = $fopen("gl_vectors.svh", "w");
    // 1. VSSRL EW8 shamt=0 + unmasked upper bits (4-state X trap if opb[j-1] or unmasked j!)
    $fdisplay(fd, "run_gl_op(\\"vssrl_sh0\\", 8'd%0d, 3'd0, 2'b00, 64'hF8_00_01_02_03_04_05_00, 64'hFF_80_03_07_0F_1F_3F_AA, 64'd0, 64'd0, 1'b0, 1'b1, 8'hFF, 13'd8, 64'hFF_80_02_02_02_02_02_AA, 8'hFF, 1'b0);", int'(VSSRL));
    // 2. VSSRA EW16 rne (01) tie vs non-tie
    $fdisplay(fd, "run_gl_op(\\"vssra_rne\\", 8'd%0d, 3'd1, 2'b01, 64'hFFF2_0002_0002_0000, 64'h0006_0007_0002_8001, 64'd0, 64'd0, 1'b0, 1'b1, 8'hFF, 13'd4, 64'h0002_0002_0000_8001, 8'hFF, 1'b0);", int'(VSSRA));
    // 3. VSSRL EW16 rod (11) sticky mask
    $fdisplay(fd, "run_gl_op(\\"vssrl_rod\\", 8'd%0d, 3'd1, 2'b11, 64'h0004_0004_0004_0000, 64'h0001_0011_0020_1234, 64'd0, 64'd0, 1'b0, 1'b1, 8'hFF, 13'd4, 64'h0001_0001_0002_1234, 8'hFF, 1'b0);", int'(VSSRL));
    // 4. VAADD EW8 signed overflow before shift (+127+127=127, -128+-128=-128)
    $fdisplay(fd, "run_gl_op(\\"vaadd_ovf\\", 8'd%0d, 3'd0, 2'b00, 64'h7F_80_01_FF_00_00_00_00, 64'h7F_80_01_FF_00_00_00_00, 64'd0, 64'd0, 1'b0, 1'b1, 8'hFF, 13'd8, 64'h7F_80_01_FF_00_00_00_00, 8'hFF, 1'b0);", int'(VAADD));
    // 5. VASUBU EW8 unsigned borrow (0 - 1 = -0.5 -> 0xFF on rdn!)
    $fdisplay(fd, "run_gl_op(\\"vasubu_rdn\\", 8'd%0d, 3'd0, 2'b10, 64'h01_01_02_00_00_00_00_00, 64'h00_03_00_04_00_00_00_00, 64'd0, 64'd0, 1'b0, 1'b1, 8'hFF, 13'd8, 64'hFF_01_FF_02_00_00_00_00, 8'hFF, 1'b0);", int'(VASUBU));
    // 6. VNCLIP EW8 2-cycle narrowing with half-0 saturation only (slot 0: 0x00FF>>1+1=+128->0x7F, sat=1)
    $fdisplay(fd, "run_gl_op(\\"vnclip_nar\\", 8'd%0d, 3'd0, 2'b00, 64'h0000_0000_0000_0001, 64'hFFFF_FF80_007F_00FF, 64'h0000_0000_0000_0000, 64'h0004_0003_0002_0001, 1'b1, 1'b1, 8'hFF, 13'd8, 64'h04_FF_03_80_02_7F_01_7F, 8'hFF, 1'b1);", int'(VNCLIP));
    // 7. VNCLIP EW8 masked-off saturation (slot 0 masked off by mask=8'hFE -> sat MUST be 0!)
    $fdisplay(fd, "run_gl_op(\\"vnclip_msk\\", 8'd%0d, 3'd0, 2'b00, 64'h0000_0000_0000_0001, 64'hFFFF_FF80_007F_00FF, 64'h0000_0000_0000_0000, 64'h0004_0003_0002_0001, 1'b1, 1'b0, 8'hFE, 13'd8, 64'h04_FF_03_80_02_7F_01_00, 8'hFE, 1'b0);", int'(VNCLIP));
    $fclose(fd);
    $finish;
  end
endmodule
"""
            )

            # Stage 1: Verilator compile & run functional testbench
            v_cmd = [
                str(VERILATOR),
                "--binary",
                "-j",
                "4",
                "-Wno-fatal",
                "--timing",
                "-sv",
                "+incdir+code/include",
                *RTL_FILES,
                "tb.sv",
                "--top-module",
                "tb",
                "-o",
                "Vtb",
            ]
            res = run_cmd(v_cmd, work, timeout=120)
            if res.returncode != 0:
                return emit(res_path, "FAIL", "functional", f"Verilator compile failed:\n{res.stdout[-1500:]}", 1)

            sim = run_cmd([str(work / "obj_dir/Vtb"), f"+SEED={args.seed}"], work, timeout=120)
            if sim.returncode != 0 or "PASS:" not in sim.stdout:
                return emit(
                    res_path,
                    "FAIL",
                    "functional",
                    f"RTL simulation failed (seed={args.seed}):\n{sim.stdout[-1500:]}",
                    1,
                )

            # Stage 2: Synthesis elaboration & latch check for BOTH FixedPointEnable and FixedPointDisable
            current_stage = "synthesis"
            rtl_list = " ".join(RTL_FILES)
            ys_dis = (
                f"read_slang --top syn_wrap_disable -I code/include {rtl_list} syn_wrap.sv; "
                f"synth -top syn_wrap_disable; check -assert; select -assert-none t:$_DLATCH_*"
            )
            r_dis = run_cmd([str(YOSYS), "-m", "slang", "-p", ys_dis], work, timeout=150)
            if r_dis.returncode != 0:
                return emit(
                    res_path,
                    "FAIL",
                    "synthesis",
                    f"yosys-slang FixedPointDisable synthesis/latch check failed:\n{r_dis.stdout[-1500:]}",
                    1,
                )

            ys_en = (
                f"read_slang --top syn_wrap_enable -I code/include {rtl_list} syn_wrap.sv; "
                f"synth -top syn_wrap_enable; check -assert; select -assert-none t:$_DLATCH_*; "
                f"write_verilog -noattr netlist_en.v"
            )
            r_en = run_cmd([str(YOSYS), "-m", "slang", "-p", ys_en], work, timeout=210)
            if r_en.returncode != 0 or not (work / "netlist_en.v").is_file():
                return emit(
                    res_path,
                    "FAIL",
                    "synthesis",
                    f"yosys-slang FixedPointEnable synthesis/latch check failed:\n{r_en.stdout[-1500:]}",
                    1,
                )

            # Stage 3: 4-State Gate-Level Simulation Parity & X-Check
            current_stage = "equivalence"
            g_cmd = [
                str(VERILATOR),
                "--binary",
                "-j",
                "2",
                "-Wno-fatal",
                "-sv",
                "+incdir+code/include",
                "code/cf_math_pkg.sv",
                "code/riscv_pkg.sv",
                "code/config_pkg.sv",
                "code/cv64a6_imafdcv_sv39_config_pkg.sv",
                "code/ariane_pkg.sv",
                "code/axi_pkg.sv",
                "code/fpnew_pkg.sv",
                "code/rvv_pkg.sv",
                "code/ara_pkg.sv",
                "gen_gl_vec.sv",
                "--top-module",
                "gen_gl_vec",
                "-o",
                "Vgen",
            ]
            rg = run_cmd(g_cmd, work, timeout=60)
            if rg.returncode != 0 or run_cmd([str(work / "obj_dir/Vgen")], work, timeout=30).returncode != 0:
                return emit(res_path, "FAIL", "equivalence", f"GL vector generation failed:\n{rg.stdout[-1000:]}", 1)

            iv_cmd = [
                str(IVERILOG),
                "-g2012",
                "-o",
                "sim_gl.out",
                str(SIMCELLS),
                "netlist_en.v",
                "tb_gl.sv",
            ]
            riv = run_cmd(iv_cmd, work, timeout=90)
            if riv.returncode != 0:
                return emit(res_path, "FAIL", "equivalence", f"iverilog gate-level compile failed:\n{riv.stdout[-1500:]}", 1)

            rvvp = run_cmd([str(VVP), "sim_gl.out"], work, timeout=90)
            if rvvp.returncode != 0 or "PASS [4state_gl]" not in rvvp.stdout:
                return emit(
                    res_path,
                    "FAIL",
                    "equivalence",
                    f"4-state gate-level simulation failed:\n{rvvp.stdout[-1500:]}",
                    1,
                )

            return emit(
                res_path,
                "PASS",
                "equivalence",
                f"All RTL, synthesis, and 4-state GL checks passed (seed={args.seed})",
                0,
            )
    except subprocess.TimeoutExpired as exc:
        out_tail = ""
        if exc.stdout:
            out_tail = (exc.stdout.decode("utf-8", "replace") if isinstance(exc.stdout, bytes) else str(exc.stdout))[-1200:]
        return emit(
            res_path,
            "FAIL",
            current_stage,
            f"Stage '{current_stage}' timed out after {exc.timeout}s:\n{out_tail}",
            1,
        )


if __name__ == "__main__":
    sys.exit(main())
