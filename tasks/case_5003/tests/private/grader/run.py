#!/usr/bin/env python3
"""Trusted isolated grader for case_5003 (CVA6 Sv39+Svnapot MMU shared-TLB arbitration, NAPOT set indexing, PLRU refill, PTW flush control, and Nangate45 area/STA)."""
import argparse
import hashlib
import json
import pathlib
import random
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
PRIV = TASK_DIR / 'private'
PUB = TASK_DIR / 'public'

TOOLS = pathlib.Path(str(_sb_tools_dir()))
VERILATOR = TOOLS / 'verilator-v5.038/bin/verilator'
YOSYS = TOOLS / 'oss-cad-suite/bin/yosys'
OPENROAD = TOOLS / 'bin/openroad'
NANGATE = pathlib.Path(str(_sb_nangate45_dir()))
LIB = NANGATE / 'lib/NangateOpenCellLibrary_typical.lib'
TLEF = NANGATE / 'lef/NangateOpenCellLibrary.tech.lef'
MLEF = NANGATE / 'lef/NangateOpenCellLibrary.macro.mod.lef'

TLB_AREA_LIMIT_UM2 = 2260.0
CLOCK_PERIOD_NS = 2.42

EDITABLE_NAMES = ('cva6_tlb.sv', 'cva6_shared_tlb.sv', 'cva6_ptw.sv')
FIXED_NAMES = (
    'config_pkg.sv',
    'cv64a60ax_config_pkg.sv',
    'riscv_pkg.sv',
    'ariane_pkg.sv',
    'cf_math_pkg.sv',
    'lzc.sv',
    'lfsr.sv',
    'tc_sram.sv',
    'tc_sram_wrapper.sv',
    'sram.sv',
    'pmp_entry.sv',
    'pmp.sv',
    'pmp_data_if.sv',
    'cva6_mmu.sv',
)


def finish(result_path: pathlib.Path, verdict: str, stage: str, detail: str, **extra):
    payload = {
        'verdict': verdict,
        'stage': stage,
        'detail': detail,
        **extra,
    }
    result_path.parent.mkdir(parents=True, exist_ok=True)
    result_path.write_text(json.dumps(payload, indent=2) + '\n')
    print(json.dumps(payload))
    raise SystemExit(0 if verdict == 'PASS' else 2 if verdict == 'ERROR' else 1)


def strip_comments_and_strings(text: str) -> str:
    text = re.sub(r'(?is)//\s*(?:pragma|synthesis)\s+translate_off.*?//\s*(?:pragma|synthesis)\s+translate_on', ' ', text)
    return re.sub(r'/\*.*?\*/|//[^\n]*|"(?:\\.|[^"\\])*"', ' ', text, flags=re.S)


def screen_source(name: str, data: str, result_path: pathlib.Path):
    if len(data.encode('utf-8')) > 250_000:
        finish(result_path, 'FAIL', 'policy', f'{name} exceeds size limit')
    clean = strip_comments_and_strings(data)
    if re.search(
        r'`\s*(?:include|define|ifdef|ifndef|elsif)\b'
        r'|\$\s*(?!signed\b|unsigned\b|clog2\b|bits\b|high\b|low\b|size\b)[a-zA-Z_]'
        r'|\b(?:force|release|bind|defparam|DPI|vpi|tb|grader|oracle|always_latch)\b'
        r'|\$root\b',
        clean,
        re.I,
    ):
        finish(result_path, 'FAIL', 'policy', f'disallowed HDL construct or harness reference in {name}')


def make_tb(seed: int) -> str:
    s = (PRIV / 'tests/tb.sv').read_text(encoding='utf-8')
    r = random.Random(seed)
    lines = []
    for k in range(8):
        sub_install = r.randint(0, 7)
        sub_query = r.randint(8, 15)
        base_vpn = 0x0400 + k * 0x20
        base_ppn = 0x10000 + k * 0x20
        va_inst = ((base_vpn + sub_install) << 12)
        va_qry = ((base_vpn + sub_query) << 12)
        ppn_napot = base_ppn | 0x8
        exp_paddr = ((base_ppn + sub_query) << 12)
        lines.append(
            f"mock_leaf_pte = '0; mock_leaf_pte.v = 1; mock_leaf_pte.r = 1; mock_leaf_pte.w = 1; "
            f"mock_leaf_pte.x = 1; mock_leaf_pte.a = 1; mock_leaf_pte.d = 1; mock_leaf_pte.n = 1; "
            f"mock_leaf_pte.ppn = 44'h{ppn_napot:011x}; "
            f"lsu_req = 1; lsu_vaddr = 64'h{va_inst:016x}; #1; "
            f"while (!lsu_dtlb_hit) tick(); tick(); "
            f"icache_areq_i.fetch_req = 1; icache_areq_i.fetch_vaddr = 64'h{va_qry:016x}; #1; tick(); "
            f"if (itlb_miss) $fatal(1, \"rand napot miss\"); tick(); "
            f"if (!icache_areq_o.fetch_valid || icache_areq_o.fetch_paddr !== 56'h{exp_paddr:014x}) $fatal(1, \"rand napot paddr\"); "
            f"icache_areq_i.fetch_req = 0; lsu_req = 0; tick();"
        )
    return s.replace('//RANDOM_TESTS_HERE', '\n    '.join(lines))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--candidate', required=True)
    ap.add_argument('--seed', type=int, default=101)
    ap.add_argument('--result', required=True)
    args = ap.parse_args()

    result_path = pathlib.Path(args.result).resolve()
    cand_in = pathlib.Path(args.candidate)
    if cand_in.is_symlink() or not cand_in.is_dir():
        finish(result_path, 'FAIL', 'input_validation', 'invalid or symlinked candidate directory')
    cand = cand_in.resolve()

    if (cand / 'code').is_symlink():
        finish(result_path, 'FAIL', 'input_validation', 'symlinked code directory')
    code_dir = cand / 'code' if (cand / 'code').is_dir() else cand

    inc = cand / 'include'
    if inc.is_symlink():
        finish(result_path, 'FAIL', 'policy', 'symlinked include directory')
    if inc.exists():
        for f in inc.rglob('*'):
            if f.is_symlink():
                finish(result_path, 'FAIL', 'policy', 'symlink in include')
            if f.is_file():
                ref = PUB / 'include' / f.relative_to(inc)
                if not ref.is_file() or hashlib.sha256(f.read_bytes()).digest() != hashlib.sha256(ref.read_bytes()).digest():
                    finish(result_path, 'FAIL', 'policy', 'modified protected include file')

    for name in FIXED_NAMES:
        src = code_dir / name
        if src.exists() or src.is_symlink():
            if src.is_symlink() or not src.is_file() or hashlib.sha256(src.read_bytes()).digest() != hashlib.sha256((PUB / 'code' / name).read_bytes()).digest():
                finish(result_path, 'FAIL', 'policy', f'modified protected dependency {name}')

    sources = {}
    for name in EDITABLE_NAMES:
        p = code_dir / name
        if p.is_symlink() or not p.is_file() or p.resolve().parent != code_dir.resolve():
            finish(result_path, 'FAIL', 'input_validation', f'missing or unsafe editable source {name}')
        text = p.read_text(encoding='utf-8', errors='replace')
        screen_source(name, text, result_path)
        sources[name] = text

    env = {
        'PATH': f'{TOOLS / "verilator-v5.038/bin"}:{TOOLS / "oss-cad-suite/bin"}:{TOOLS / "bin"}:/usr/bin:/bin',
        'HOME': '/tmp',
        'TMPDIR': '/tmp',
        'LANG': 'C.UTF-8',
        'CC': '/usr/bin/gcc',
        'CXX': '/usr/bin/g++',
    }

    try:
        with tempfile.TemporaryDirectory(prefix='case_5003_grade_') as td:
            tmp = pathlib.Path(td)
            for name in FIXED_NAMES:
                shutil.copyfile(PUB / 'code' / name, tmp / name)
            shutil.copytree(PUB / 'include', tmp / 'include')
            for name, text in sources.items():
                (tmp / name).write_text(text, encoding='utf-8')
            (tmp / 'tb.sv').write_text(make_tb(args.seed), encoding='utf-8')

            compile_order = [
                'config_pkg.sv', 'cv64a60ax_config_pkg.sv', 'riscv_pkg.sv', 'ariane_pkg.sv',
                'cf_math_pkg.sv', 'lzc.sv', 'lfsr.sv', 'tc_sram.sv', 'tc_sram_wrapper.sv',
                'sram.sv', 'pmp_entry.sv', 'pmp.sv', 'pmp_data_if.sv',
                'cva6_tlb.sv', 'cva6_shared_tlb.sv', 'cva6_ptw.sv', 'cva6_mmu.sv', 'tb.sv',
            ]
            comp_cmd = [
                str(VERILATOR),
                '--binary', '--timing', '-j', '1', '-CFLAGS', '-O0', '-Wno-fatal',
                '--top-module', 'tb',
                '--Mdir', str(tmp / 'obj'),
                '-I' + str(tmp / 'include'),
                *[str(tmp / n) for n in compile_order],
            ]
            c_res = subprocess.run(comp_cmd, cwd=tmp, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=180)
            if c_res.returncode != 0 or not (tmp / 'obj/Vtb').is_file():
                finish(result_path, 'FAIL', 'compile', 'Verilator compile failed:\n' + c_res.stdout[-1500:])

            s_res = subprocess.run([str(tmp / 'obj/Vtb')], cwd=tmp, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=60)
            if s_res.returncode != 0 or 'PASS MMU Sv39+Svnapot tests' not in s_res.stdout:
                finish(result_path, 'FAIL', 'functional', f'Simulation failed (seed={args.seed}):\n' + s_res.stdout[-1500:])

            # 2. Yosys Slang elaboration & latch check on full MMU subsystem
            wrap_sv = tmp / 'mmu_synth_top.sv'
            wrap_sv.write_text(
                """module mmu_synth_top import ariane_pkg::*; (
  input  logic        clk_i,
  input  logic        rst_ni,
  input  logic        flush_i,
  input  logic        fetch_req_i,
  input  logic [63:0] fetch_vaddr_i,
  input  logic        lsu_req_i,
  input  logic [63:0] lsu_vaddr_i,
  input  logic        ptw_gnt_i,
  input  logic        ptw_rvalid_i,
  input  logic [63:0] ptw_rdata_i,
  output logic        fetch_valid_o,
  output logic [55:0] fetch_paddr_o,
  output logic        dtlb_hit_o,
  output logic [43:0] dtlb_ppn_o,
  output logic        itlb_miss_o,
  output logic        dtlb_miss_o
);
  function automatic config_pkg::cva6_cfg_t make_cfg();
    config_pkg::cva6_cfg_t c;
    c = '0;
    c.XLEN = 64; c.IS_XLEN64 = 1; c.VLEN = 64; c.PLEN = 56; c.GPLEN = 41;
    c.PPNW = 44; c.GPPNW = 29; c.PtLevels = 3; c.VpnLen = 27; c.SV = 39; c.SVX = 41;
    c.ASID_WIDTH = 16; c.VMID_WIDTH = 14; c.InstrTlbEntries = 4; c.DataTlbEntries = 4;
    c.UseSharedTlb = 1; c.SharedTlbDepth = 4; c.DCACHE_INDEX_WIDTH = 12; c.DCACHE_TAG_WIDTH = 44;
    c.XLEN_ALIGN_BYTES = 3; c.MmuPresent = 1; c.SvnapotEn = 1; c.RVH = 0; c.TvalEn = 1;
    return c;
  endfunction
  localparam config_pkg::cva6_cfg_t Cfg = make_cfg();
  typedef struct packed { logic valid; logic [63:0] cause; logic [63:0] tval; logic [63:0] tval2; logic [31:0] tinst; logic gva; logic timing; } exception_t;
  typedef struct packed { logic fetch_valid; logic [55:0] fetch_paddr; exception_t fetch_exception; } icache_areq_t;
  typedef struct packed { logic fetch_req; logic [63:0] fetch_vaddr; } icache_arsp_t;
  typedef struct packed { logic [11:0] address_index; logic [43:0] address_tag; logic [63:0] data_wdata; logic [7:0] data_wuser; logic data_req; logic data_we; logic [7:0] data_be; logic [1:0] data_size; logic [1:0] data_id; logic kill_req; logic tag_valid; logic [7:0] cbo_op; } dcache_req_i_t;
  typedef struct packed { logic data_gnt; logic data_rvalid; logic [1:0] data_rid; logic [63:0] data_rdata; logic data_error; logic [7:0] data_ruser; } dcache_req_o_t;

  icache_arsp_t areq_i;
  icache_areq_t areq_o;
  dcache_req_o_t ptw_i;
  dcache_req_i_t ptw_o;
  riscv::pmpcfg_t [0:0] pmpcfg;
  logic [0:0][53:0] pmpaddr;
  assign pmpcfg = '0;
  assign pmpaddr = '0;
  assign areq_i = '{fetch_req: fetch_req_i, fetch_vaddr: fetch_vaddr_i};
  assign ptw_i = '{data_gnt: ptw_gnt_i, data_rvalid: ptw_rvalid_i, data_rid: 0, data_rdata: ptw_rdata_i, data_error: 0, data_ruser: 0};
  assign fetch_valid_o = areq_o.fetch_valid;
  assign fetch_paddr_o = areq_o.fetch_paddr;

  cva6_mmu #(.CVA6Cfg(Cfg), .icache_areq_t(icache_areq_t), .icache_arsp_t(icache_arsp_t), .icache_dreq_t(logic), .icache_drsp_t(logic), .dcache_req_i_t(dcache_req_i_t), .dcache_req_o_t(dcache_req_o_t), .exception_t(exception_t), .HYP_EXT(0)) u_mmu (
    .clk_i(clk_i), .rst_ni(rst_ni), .flush_i(flush_i),
    .enable_translation_i(1'b1), .enable_g_translation_i(1'b0), .en_ld_st_translation_i(1'b1), .en_ld_st_g_translation_i(1'b0),
    .icache_areq_i(areq_i), .icache_areq_o(areq_o), .misaligned_ex_i('0),
    .lsu_req_i(lsu_req_i), .lsu_vaddr_i(lsu_vaddr_i), .lsu_tinst_i('0), .lsu_is_store_i(1'b0),
    .csr_hs_ld_st_inst_o(), .lsu_dtlb_hit_o(dtlb_hit_o), .lsu_dtlb_ppn_o(dtlb_ppn_o),
    .lsu_valid_o(), .lsu_paddr_o(), .lsu_vaddr_o(), .lsu_is_store_o(), .lsu_hlvx_inst_o(), .lsu_exception_o(),
    .priv_lvl_i(riscv::PRIV_LVL_S), .v_i(1'b0), .ld_st_priv_lvl_i(riscv::PRIV_LVL_S), .ld_st_v_i(1'b0),
    .sum_i(1'b1), .vs_sum_i(1'b1), .mxr_i(1'b1), .vmxr_i(1'b1), .mbe_i(1'b0), .hlvx_inst_i(1'b0), .hs_ld_st_inst_i(1'b0),
    .satp_ppn_i(44'd1), .vsatp_ppn_i(44'd2), .hgatp_ppn_i(44'd3),
    .asid_i(16'd1), .vs_asid_i(16'd2), .asid_to_be_flushed_i('0), .vmid_i(14'd1), .vmid_to_be_flushed_i('0),
    .vaddr_to_be_flushed_i('0), .gpaddr_to_be_flushed_i('0),
    .flush_tlb_i(1'b0), .flush_tlb_vvma_i(1'b0), .flush_tlb_gvma_i(1'b0),
    .shared_tlb_flush_busy_o(), .itlb_miss_o(itlb_miss_o), .dtlb_miss_o(dtlb_miss_o),
    .req_port_i(ptw_i), .req_port_o(ptw_o), .pmpcfg_i(pmpcfg), .pmpaddr_i(pmpaddr)
  );
endmodule
""",
                encoding='utf-8',
            )
            synth_files = ' '.join(str(tmp / n) for n in compile_order[:-1] + ['mmu_synth_top.sv'])
            ys_file = tmp / 'synth.ys'
            ys_file.write_text(
                f'read_slang --top mmu_synth_top -I{tmp / "include"} -DSYNTHESIS {synth_files}\n'
                f'hierarchy -check -top mmu_synth_top\n'
                f'proc; opt_clean\n'
                f'select -assert-none t:$dlatch* t:$adlatch* t:$latch* t:$sr*\n',
                encoding='utf-8',
            )
            y_res = subprocess.run([str(YOSYS), '-m', 'slang', '-s', str(ys_file)], cwd=tmp, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=60)
            if y_res.returncode != 0:
                finish(result_path, 'FAIL', 'synthesis', 'Yosys synthesis or latch check failed:\n' + y_res.stdout[-1500:])

            # 3. Nangate45 mapped area & OpenSTA timing closure on cva6_tlb (TLB_ENTRIES=2, HYP_EXT=0)
            tlb_wrap = tmp / 'tlb_top.sv'
            tlb_wrap.write_text(
                """module tlb_top import ariane_pkg::*; (
  input  logic        clk_i,
  input  logic        rst_ni,
  input  logic        flush_i,
  input  logic        flush_vvma_i,
  input  logic        flush_gvma_i,
  input  logic        s_st_enbl_i,
  input  logic        g_st_enbl_i,
  input  logic        v_i,
  input  logic        update_valid_i,
  input  logic        update_is_napot_i,
  input  logic [1:0]  update_is_page_i,
  input  logic [26:0] update_vpn_i,
  input  logic [15:0] update_asid_i,
  input  logic [13:0] update_vmid_i,
  input  logic [0:0]  update_v_st_enbl_i,
  input  logic [63:0] update_content_i,
  input  logic [63:0] update_g_content_i,
  input  logic        lu_access_i,
  input  logic [15:0] lu_asid_i,
  input  logic [13:0] lu_vmid_i,
  input  logic [63:0] lu_vaddr_i,
  input  logic [15:0] asid_to_be_flushed_i,
  input  logic [13:0] vmid_to_be_flushed_i,
  input  logic [63:0] vaddr_to_be_flushed_i,
  input  logic [40:0] gpaddr_to_be_flushed_i,
  output logic [40:0] lu_gpaddr_o,
  output logic [63:0] lu_content_o,
  output logic [63:0] lu_g_content_o,
  output logic [1:0]  lu_is_page_o,
  output logic        lu_hit_o
);
  function automatic config_pkg::cva6_cfg_t make_cfg();
    config_pkg::cva6_cfg_t c;
    c = '0;
    c.XLEN = 64; c.IS_XLEN64 = 1; c.VLEN = 64; c.PLEN = 56; c.GPLEN = 41;
    c.PPNW = 44; c.GPPNW = 29; c.PtLevels = 3; c.VpnLen = 27; c.SV = 39; c.SVX = 41;
    c.ASID_WIDTH = 16; c.VMID_WIDTH = 14; c.InstrTlbEntries = 2; c.DataTlbEntries = 2;
    c.UseSharedTlb = 1; c.SharedTlbDepth = 4; c.DCACHE_INDEX_WIDTH = 12; c.DCACHE_TAG_WIDTH = 44;
    c.XLEN_ALIGN_BYTES = 3; c.MmuPresent = 1; c.SvnapotEn = 1; c.RVH = 0; c.TvalEn = 1;
    return c;
  endfunction
  localparam config_pkg::cva6_cfg_t Cfg = make_cfg();
  typedef struct packed { logic n; logic [8:0] reserved; logic [43:0] ppn; logic [1:0] rsw; logic d; logic a; logic g; logic u; logic x; logic w; logic r; logic v; } pte_cva6_t;
  typedef struct packed { logic valid; logic is_napot_64k; logic [1:0][0:0] is_page; logic [26:0] vpn; logic [15:0] asid; logic [13:0] vmid; logic [0:0] v_st_enbl; pte_cva6_t content; pte_cva6_t g_content; } tlb_update_cva6_t;
  tlb_update_cva6_t upd;
  assign upd = '{valid: update_valid_i, is_napot_64k: update_is_napot_i, is_page: update_is_page_i, vpn: update_vpn_i, asid: update_asid_i, vmid: update_vmid_i, v_st_enbl: update_v_st_enbl_i, content: pte_cva6_t'(update_content_i), g_content: pte_cva6_t'(update_g_content_i)};
  cva6_tlb #(.CVA6Cfg(Cfg), .pte_cva6_t(pte_cva6_t), .tlb_update_cva6_t(tlb_update_cva6_t), .TLB_ENTRIES(2), .HYP_EXT(0)) u_tlb (
    .clk_i, .rst_ni, .flush_i, .flush_vvma_i, .flush_gvma_i, .s_st_enbl_i, .g_st_enbl_i, .v_i,
    .update_i(upd), .lu_access_i, .lu_asid_i, .lu_vmid_i, .lu_vaddr_i,
    .lu_gpaddr_o, .lu_content_o, .lu_g_content_o,
    .asid_to_be_flushed_i, .vmid_to_be_flushed_i, .vaddr_to_be_flushed_i, .gpaddr_to_be_flushed_i,
    .lu_is_page_o, .lu_hit_o
  );
endmodule
""",
                encoding='utf-8',
            )
            mapped_v = tmp / 'mapped_tlb.v'
            ys_tlb = tmp / 'synth_tlb.ys'
            tlb_files = ' '.join(str(tmp / n) for n in ('config_pkg.sv', 'cv64a60ax_config_pkg.sv', 'riscv_pkg.sv', 'ariane_pkg.sv', 'cva6_tlb.sv', 'tlb_top.sv'))
            ys_tlb.write_text(
                f'read_slang --ignore-assertions --top tlb_top -I{tmp / "include"} -DSYNTHESIS {tlb_files}\n'
                f'hierarchy -check -top tlb_top\n'
                f'synth -top tlb_top -flatten\n'
                f'opt\n'
                f'dfflibmap -liberty {LIB}\n'
                f'abc -liberty {LIB}\n'
                f'clean\n'
                f'read_liberty -lib {LIB}\n'
                f'check -assert\n'
                f'stat -liberty {LIB}\n'
                f'write_verilog -noattr {mapped_v}\n',
                encoding='utf-8',
            )
            y_tlb = subprocess.run([str(YOSYS), '-Q', '-T', '-m', 'slang', '-s', str(ys_tlb)], cwd=tmp, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=60)
            m_area = re.search(r'Chip area for .*?:\s*([\d.]+)', y_tlb.stdout)
            if y_tlb.returncode != 0 or not m_area or not mapped_v.is_file():
                finish(result_path, 'FAIL', 'synthesis', 'Yosys Nangate45 synthesis failed on tlb_top:\n' + y_tlb.stdout[-1500:])
            tlb_area_um2 = round(float(m_area.group(1)), 3)
            if tlb_area_um2 > TLB_AREA_LIMIT_UM2:
                finish(
                    result_path,
                    'FAIL',
                    'area',
                    f'tlb_top mapped area {tlb_area_um2:.3f} um^2 exceeds limit {TLB_AREA_LIMIT_UM2:.1f} um^2',
                    tlb_area_um2=tlb_area_um2,
                )

            sta_v = tmp / 'sta_tlb.v'
            sta_v.write_text(mapped_v.read_text(encoding='utf-8').replace(' signed ', ' '), encoding='utf-8')
            sta_tcl = tmp / 'sta_tlb.tcl'
            sta_tcl.write_text(
                f'read_lef {TLEF}\n'
                f'read_lef {MLEF}\n'
                f'read_liberty {LIB}\n'
                f'read_verilog {sta_v}\n'
                f'link_design tlb_top\n'
                f'create_clock -name clk_i -period {CLOCK_PERIOD_NS} [get_ports clk_i]\n'
                f'set_input_delay 0.20 -clock clk_i [all_inputs -no_clocks]\n'
                f'set_output_delay 0.20 -clock clk_i [all_outputs]\n'
                f'set_load 5.0 [all_outputs]\n'
                f'puts "=== SETUP ==="\n'
                f'report_checks -path_delay max -format full_clock_expanded\n'
                f'puts "=== HOLD ==="\n'
                f'report_checks -path_delay min -format full_clock_expanded\n',
                encoding='utf-8',
            )
            o_res = subprocess.run([str(OPENROAD), '-exit', str(sta_tcl)], cwd=tmp, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=60)
            if o_res.returncode != 0:
                finish(result_path, 'FAIL', 'timing', 'OpenROAD STA failed:\n' + o_res.stdout[-1500:], tlb_area_um2=tlb_area_um2)
            setup_sec = re.search(r'=== SETUP ===(.*?)=== HOLD ===', o_res.stdout, re.S)
            hold_sec = re.search(r'=== HOLD ===(.*)', o_res.stdout, re.S)
            setup_slacks = [float(v) for v in re.findall(r'(-?[\d.]+)\s+slack\s+\((?:MET|VIOLATED)\)', setup_sec.group(1) if setup_sec else '')]
            hold_slacks = [float(v) for v in re.findall(r'(-?[\d.]+)\s+slack\s+\((?:MET|VIOLATED)\)', hold_sec.group(1) if hold_sec else '')]
            if not setup_slacks or not hold_slacks:
                finish(result_path, 'FAIL', 'timing', 'failed to parse OpenSTA setup/hold slacks', tlb_area_um2=tlb_area_um2)
            worst_setup_slack_ns = round(min(setup_slacks), 3)
            worst_hold_slack_ns = round(min(hold_slacks), 3)
            if worst_setup_slack_ns < 0.0:
                finish(
                    result_path,
                    'FAIL',
                    'timing',
                    f'worst setup slack {worst_setup_slack_ns:.3f} ns < 0.0 ns at {CLOCK_PERIOD_NS} ns clock',
                    tlb_area_um2=tlb_area_um2,
                    worst_setup_slack_ns=worst_setup_slack_ns,
                    worst_hold_slack_ns=worst_hold_slack_ns,
                )
            if worst_hold_slack_ns < 0.0:
                finish(
                    result_path,
                    'FAIL',
                    'timing',
                    f'worst hold slack {worst_hold_slack_ns:.3f} ns < 0.0 ns',
                    tlb_area_um2=tlb_area_um2,
                    worst_setup_slack_ns=worst_setup_slack_ns,
                    worst_hold_slack_ns=worst_hold_slack_ns,
                )

            finish(
                result_path,
                'PASS',
                'all',
                f'PASS MMU Sv39+Svnapot functional simulation (seed={args.seed}), latch-free synthesis, and Nangate45 area/STA',
                tlb_area_um2=tlb_area_um2,
                worst_setup_slack_ns=worst_setup_slack_ns,
                worst_hold_slack_ns=worst_hold_slack_ns,
            )
    except subprocess.TimeoutExpired:
        finish(result_path, 'ERROR', 'environment', 'Compilation, simulation, or synthesis timed out')
    except OSError as exc:
        finish(result_path, 'ERROR', 'environment', f'OS error: {exc}')


if __name__ == '__main__':
    main()
