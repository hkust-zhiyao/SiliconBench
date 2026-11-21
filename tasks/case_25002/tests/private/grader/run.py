#!/usr/bin/env python3
"""Private isolated cross-stage grader for case_25002:
Stage 0: Policy, port signature, and read-only collateral (code/ + pdk/) SHA-256 verification
Stage 1: Verilator cycle-accurate RTL functional & security verification (tb.sv)
Stage 2: Yosys-Slang Nangate45 gate-level synthesis, zero-latch / zero-SCC check, and >=10 sparse state DFF preservation
Stage 3: Icarus Verilog post-synthesis Nangate45 gate-level AES-256-CBC KAT & exhaustive single-bit state-DFF SEU fault injection
"""
import argparse
import hashlib
import json
import os
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
PRIV_DIR = TASK_DIR / 'private'
PUB_DIR = TASK_DIR / 'public'
TOOLS_DIR = pathlib.Path(str(_sb_tools_dir()))
VERILATOR = TOOLS_DIR / 'verilator-v5.038' / 'bin' / 'verilator'
YOSYS = TOOLS_DIR / 'oss-cad-suite' / 'bin' / 'yosys'
IVERILOG = TOOLS_DIR / 'iverilog-v13' / 'bin' / 'iverilog'
VVP = TOOLS_DIR / 'iverilog-v13' / 'bin' / 'vvp'
if not IVERILOG.exists():
    IVERILOG = TOOLS_DIR / 'oss-cad-suite' / 'bin' / 'iverilog'
    VVP = TOOLS_DIR / 'oss-cad-suite' / 'bin' / 'vvp'

EDITABLE_FILES = {
    pathlib.Path('code/doe_ctrl.sv'): 'doe_ctrl',
    pathlib.Path('code/doe_fsm.sv'): 'doe_fsm',
    pathlib.Path('code/doe_key_mem.sv'): 'doe_key_mem',
}

RTL_SOURCES = [
    'code/config_defines.svh',
    'code/caliptra_prim_pkg.sv',
    'code/caliptra_prim_mubi_pkg.sv',
    'code/ahb_defines_pkg.sv',
    'code/kv_defines_pkg.sv',
    'code/doe_defines_pkg.sv',
    'code/doe_reg_pkg.sv',
    'code/caliptra_prim_generic_flop.sv',
    'code/caliptra_prim_flop.sv',
    'code/caliptra_prim_sparse_fsm_flop.sv',
    'code/ahb_slv_sif.sv',
    'code/kv_write_rule_check.sv',
    'code/doe_sbox.sv',
    'code/doe_inv_sbox.sv',
    'code/doe_encipher_block.sv',
    'code/doe_decipher_block.sv',
    'code/doe_key_mem.sv',
    'code/doe_core_cbc.sv',
    'code/doe_reg.sv',
    'code/doe_fsm.sv',
    'code/doe_cbc.sv',
    'code/doe_ctrl.sv',
]

SINGLE_REG_DFF_MODELS = """
module DFF_X1(D, Q, CK, QN);
  input D, CK; output Q, QN;
  reg q_reg = 1'b0;
  assign Q = q_reg; assign QN = ~q_reg;
  always @(posedge CK) q_reg <= D;
endmodule
module DFF_X2(D, Q, CK, QN);
  input D, CK; output Q, QN;
  reg q_reg = 1'b0;
  assign Q = q_reg; assign QN = ~q_reg;
  always @(posedge CK) q_reg <= D;
endmodule
module DFFR_X1(D, Q, CK, RN, QN);
  input D, CK, RN; output Q, QN;
  reg q_reg = 1'b0;
  assign Q = q_reg; assign QN = ~q_reg;
  always @(posedge CK or negedge RN) if (!RN) q_reg <= 1'b0; else q_reg <= D;
endmodule
module DFFR_X2(D, Q, CK, RN, QN);
  input D, CK, RN; output Q, QN;
  reg q_reg = 1'b0;
  assign Q = q_reg; assign QN = ~q_reg;
  always @(posedge CK or negedge RN) if (!RN) q_reg <= 1'b0; else q_reg <= D;
endmodule
module DFFS_X1(D, Q, CK, SN, QN);
  input D, CK, SN; output Q, QN;
  reg q_reg = 1'b1;
  assign Q = q_reg; assign QN = ~q_reg;
  always @(posedge CK or negedge SN) if (!SN) q_reg <= 1'b1; else q_reg <= D;
endmodule
module DFFS_X2(D, Q, CK, SN, QN);
  input D, CK, SN; output Q, QN;
  reg q_reg = 1'b1;
  assign Q = q_reg; assign QN = ~q_reg;
  always @(posedge CK or negedge SN) if (!SN) q_reg <= 1'b1; else q_reg <= D;
endmodule
module DFFRS_X1(D, Q, CK, RN, SN, QN);
  input D, CK, RN, SN; output Q, QN;
  reg q_reg = 1'b0;
  assign Q = q_reg; assign QN = ~q_reg;
  always @(posedge CK or negedge RN or negedge SN) if (!RN) q_reg <= 1'b0; else if (!SN) q_reg <= 1'b1; else q_reg <= D;
endmodule
module DFFRS_X2(D, Q, CK, RN, SN, QN);
  input D, CK, RN, SN; output Q, QN;
  reg q_reg = 1'b0;
  assign Q = q_reg; assign QN = ~q_reg;
  always @(posedge CK or negedge RN or negedge SN) if (!RN) q_reg <= 1'b0; else if (!SN) q_reg <= 1'b1; else q_reg <= D;
endmodule
module SDFF_X1(D, Q, CK, SE, QN, SI);
  input D, CK, SE, SI; output Q, QN;
  reg q_reg = 1'b0;
  assign Q = q_reg; assign QN = ~q_reg;
  always @(posedge CK) q_reg <= SE ? SI : D;
endmodule
module SDFF_X2(D, Q, CK, SE, QN, SI);
  input D, CK, SE, SI; output Q, QN;
  reg q_reg = 1'b0;
  assign Q = q_reg; assign QN = ~q_reg;
  always @(posedge CK) q_reg <= SE ? SI : D;
endmodule
module SDFFR_X1(D, Q, CK, SE, RN, QN, SI);
  input D, CK, SE, RN, SI; output Q, QN;
  reg q_reg = 1'b0;
  assign Q = q_reg; assign QN = ~q_reg;
  always @(posedge CK or negedge RN) if (!RN) q_reg <= 1'b0; else q_reg <= SE ? SI : D;
endmodule
module SDFFR_X2(D, Q, CK, SE, RN, QN, SI);
  input D, CK, SE, RN, SI; output Q, QN;
  reg q_reg = 1'b0;
  assign Q = q_reg; assign QN = ~q_reg;
  always @(posedge CK or negedge RN) if (!RN) q_reg <= 1'b0; else q_reg <= SE ? SI : D;
endmodule
module SDFFS_X1(D, Q, CK, SE, SN, QN, SI);
  input D, CK, SE, SN, SI; output Q, QN;
  reg q_reg = 1'b1;
  assign Q = q_reg; assign QN = ~q_reg;
  always @(posedge CK or negedge SN) if (!SN) q_reg <= 1'b1; else q_reg <= SE ? SI : D;
endmodule
module SDFFS_X2(D, Q, CK, SE, SN, QN, SI);
  input D, CK, SE, SN, SI; output Q, QN;
  reg q_reg = 1'b1;
  assign Q = q_reg; assign QN = ~q_reg;
  always @(posedge CK or negedge SN) if (!SN) q_reg <= 1'b1; else q_reg <= SE ? SI : D;
endmodule
module SDFFRS_X1(D, Q, CK, SE, RN, SN, QN, SI);
  input D, CK, SE, RN, SN, SI; output Q, QN;
  reg q_reg = 1'b0;
  assign Q = q_reg; assign QN = ~q_reg;
  always @(posedge CK or negedge RN or negedge SN) if (!RN) q_reg <= 1'b0; else if (!SN) q_reg <= 1'b1; else q_reg <= SE ? SI : D;
endmodule
module SDFFRS_X2(D, Q, CK, SE, RN, SN, QN, SI);
  input D, CK, SE, RN, SN, SI; output Q, QN;
  reg q_reg = 1'b0;
  assign Q = q_reg; assign QN = ~q_reg;
  always @(posedge CK or negedge RN or negedge SN) if (!RN) q_reg <= 1'b0; else if (!SN) q_reg <= 1'b1; else q_reg <= SE ? SI : D;
endmodule
"""


def finish(result_path: pathlib.Path, verdict: str, stage: str, detail: str):
    payload = {'verdict': verdict, 'stage': stage, 'detail': detail}
    result_path.parent.mkdir(parents=True, exist_ok=True)
    result_path.write_text(json.dumps(payload, indent=2) + '\n', encoding='utf-8')
    print(json.dumps(payload))
    raise SystemExit(0 if verdict == 'PASS' else 2 if verdict == 'ERROR' else 1)


def sha256_bytes(p: pathlib.Path) -> str:
    return hashlib.sha256(p.read_bytes()).hexdigest()


def benign_directives(text: str) -> str:
    return re.sub(
        r'(?m)^[ \t]*`(?:timescale\s+[^\n]+|default_nettype\s+(?:none|wire)|resetall)[ \t]*$',
        '',
        text,
    )


def _has_pass_banner_in_strings(raw_block: str) -> bool:
    for m in re.finditer(r'"((?:\\.|[^"\\])*)"', raw_block):
        if re.search(r'pass', m.group(1), re.I):
            return True
    return False


def _mask_comments_and_strings_preserve_len(src: str) -> str:
    """Replace comments and string interiors with spaces while keeping exact character offsets."""
    out = list(src)
    i, n = 0, len(src)
    while i < n:
        if i + 1 < n and src[i] == '/' and src[i + 1] == '/':
            out[i] = ' '
            out[i + 1] = ' '
            i += 2
            while i < n and src[i] != '\n':
                out[i] = ' '
                i += 1
        elif i + 1 < n and src[i] == '/' and src[i + 1] == '*':
            out[i] = ' '
            out[i + 1] = ' '
            i += 2
            while i < n and not (i + 1 < n and src[i] == '*' and src[i + 1] == '/'):
                if src[i] != '\n':
                    out[i] = ' '
                i += 1
            if i + 1 < n:
                out[i] = ' '
                out[i + 1] = ' '
                i += 2
        elif src[i] == '"':
            i += 1
            while i < n and src[i] != '"':
                if src[i] == '\\' and i + 1 < n:
                    if src[i] != '\n':
                        out[i] = ' '
                    if src[i + 1] != '\n':
                        out[i + 1] = ' '
                    i += 2
                else:
                    if src[i] != '\n':
                        out[i] = ' '
                    i += 1
            if i < n:
                i += 1
        else:
            i += 1
    return ''.join(out)


def _strip_comments_keep_strings(src: str) -> str:
    """Strip // and /*...*/ comments without corrupting string literals."""
    out = []
    i, n = 0, len(src)
    while i < n:
        if i + 1 < n and src[i] == '/' and src[i + 1] == '/':
            i += 2
            while i < n and src[i] != '\n':
                i += 1
        elif i + 1 < n and src[i] == '/' and src[i + 1] == '*':
            i += 2
            while i < n and not (i + 1 < n and src[i] == '*' and src[i + 1] == '/'):
                if src[i] == '\n':
                    out.append('\n')
                i += 1
            i += 2
        elif src[i] == '"':
            out.append('"')
            i += 1
            while i < n and src[i] != '"':
                if src[i] == '\\' and i + 1 < n:
                    out.append(src[i:i + 2])
                    i += 2
                else:
                    out.append(src[i])
                    i += 1
            if i < n:
                out.append('"')
                i += 1
        else:
            out.append(src[i])
            i += 1
    return ''.join(out)


def _strip_kw_parens(body: str, keywords=('for', 'if')) -> tuple[str, list[tuple[str, str]]]:
    """Strip balanced (...) headers after given keywords, returning (stripped_body, [(kw, inner), ...])."""
    pat = re.compile(r'\b(' + '|'.join(keywords) + r')\s*\(')
    headers = []
    res = []
    pos = 0
    while True:
        m = pat.search(body, pos)
        if not m:
            res.append(body[pos:])
            break
        res.append(body[pos:m.end()])
        depth = 1
        j = m.end()
        while j < len(body) and depth > 0:
            if body[j] == '(':
                depth += 1
            elif body[j] == ')':
                depth -= 1
            j += 1
        inner = body[m.end():j - 1] if depth == 0 else body[m.end():j]
        headers.append((m.group(1), inner))
        res.append(')')
        pos = j
    return ''.join(res), headers


def constant_initials(text: str) -> str:
    """Omit static power-up assignment blocks and elaboration-only parameter guards."""
    masked = _mask_comments_and_strings_preserve_len(text)
    matches = list(re.finditer(r'\binitial\b', masked))
    for m in reversed(matches):
        tail_m = masked[m.end():]
        b = re.match(r'\s*begin\b', tail_m)
        if b:
            depth = 1
            stop = None
            for token in re.finditer(r'\b(begin|end)\b', tail_m[b.end():]):
                depth += 1 if token[1] == 'begin' else -1
                if depth == 0:
                    stop = b.end() + token.end()
                    break
            if stop is None:
                continue
        else:
            # Handle single-statement initial or `initial if (...) begin ... end`
            ib = re.match(r'\s*if\s*\(', tail_m)
            if ib:
                pdepth = 1
                j = ib.end()
                while j < len(tail_m) and pdepth > 0:
                    if tail_m[j] == '(':
                        pdepth += 1
                    elif tail_m[j] == ')':
                        pdepth -= 1
                    j += 1
                b2 = re.match(r'\s*begin\b', tail_m[j:])
                if b2:
                    depth = 1
                    stop = None
                    base_off = j + b2.end()
                    for token in re.finditer(r'\b(begin|end)\b', tail_m[base_off:]):
                        depth += 1 if token[1] == 'begin' else -1
                        if depth == 0:
                            stop = base_off + token.end()
                            break
                    if stop is None:
                        continue
                else:
                    semi = tail_m.find(';', j)
                    if semi < 0:
                        continue
                    stop = semi + 1
            else:
                semi = tail_m.find(';')
                if semi < 0:
                    continue
                stop = semi + 1
        raw_body = text[m.end():m.end() + stop]
        if _has_pass_banner_in_strings(raw_body):
            continue
        body = masked[m.end():m.end() + stop]

        # Case A: Static elaboration parameter check (zero non-loop assignments, zero timing/delays)
        if not re.search(r'[@#`\\]|\b(?:while|repeat|forever|wait|fork|task|function|disable|force|release|bind)\b', body):
            stmt_body, hdrs = _strip_kw_parens(body, ('for', 'if'))
            if_has_assign = any(kw == 'if' and re.search(r'(?<![=!<>])=(?!=)', inner) for kw, inner in hdrs)
            if not if_has_assign and not re.search(r'(?<![=!<>])=(?!=)|<=', stmt_body):
                sys_calls = re.findall(r'\$(\w+)', body)
                allowed_sys = {
                    'display', 'write', 'strobe', 'info', 'warning', 'error', 'fatal', 'finish',
                    'sformatf', 'clog2', 'bits', 'signed', 'unsigned', 'size', 'high', 'low', 'left', 'right',
                }
                if all(sc in allowed_sys for sc in sys_calls):
                    if not re.search(r'\b(?:tb|tb_\w+|dut|dut_\w+|u_dut|grader|oracle|golden_ref)\s*\.|\$root\b', body):
                        text = text[:m.start()] + text[m.end() + stop:]
                        masked = masked[:m.start()] + masked[m.end() + stop:]
                        continue

        # Case B: Original static constant power-up array/register initialization
        if re.search(r'[@#$`"\\]|\b(?:if|case|while|repeat|forever|wait|fork|task|function|disable|force|release|bind)\b', body):
            continue
        if re.search(r'\b(?!for\b)[A-Za-z_]\w*\s*\(', body):
            continue
        loops = set(re.findall(r'\bfor\s*\(\s*(?:int(?:eger)?\s+)?(\w+)\s*=', body))
        valid = True
        assignments, _ = _strip_kw_parens(body, ('for',))
        for assignment in re.finditer(r'(?<![=!<>])=(?!=)\s*([^;]+);', assignments):
            rhs = re.sub(r"(?:\d+)?'[sS]?[bBoOdDhH]?[0-9a-fA-F_xXzZ?]+", '0', assignment[1])
            names = set(re.findall(r'\b[A-Za-z_]\w*\b', rhs))
            if any(n not in loops and not re.fullmatch(r'[A-Z][A-Z0-9_]*', n) for n in names):
                valid = False
        if not valid:
            continue
        text = text[:m.start()] + text[m.end() + stop:]
        masked = masked[:m.start()] + masked[m.end() + stop:]
    return text


def mask_assertions(text: str) -> str:
    return re.sub(r'\$(?:fatal|error|warning|info)\b', '', text)


def _strip_stdcell_and_sparse_fsm_wrappers(text: str) -> str:
    """Strip boolean-equivalent PDK buffer/delay wrappers and Caliptra sparse-FSM flop hooks."""
    # 1. Blackbox stdcell buffer/delay declarations under `ifdef SYNTHESIS ... `endif
    def _chk_bb(m):
        body = re.sub(r'/\*.*?\*/|//[^\n]*', '', m.group(1), flags=re.S)
        mods = re.findall(r'\bmodule\s+([A-Za-z_]\w*)\b', body)
        if mods and all(re.fullmatch(r'(?:sg13g2_(?:buf|dlygate|clkbuf)\w*|(?:CLK)?BUF_X\d+|DLY\d+_X\d+)', mn) for mn in mods):
            if not re.search(r'\b(?:always|always_ff|always_comb|initial|force|release|bind)\b|\$', body):
                return ''
        return m.group(0)

    text = re.sub(
        r'`ifdef\s+SYNTHESIS\b((?:(?!`(?:ifdef|ifndef|else|elsif|endif)\b).)*?)`endif\b',
        _chk_bb,
        text,
        flags=re.S,
    )

    # 2. `ifdef SYNTHESIS <stdcell buf/dly instantiation> `else assign out = in; `endif
    def _chk_buf_mux(m):
        syn_b = re.sub(r'/\*.*?\*/|//[^\n]*', '', m.group(1), flags=re.S)
        sim_b = re.sub(r'/\*.*?\*/|//[^\n]*', '', m.group(2), flags=re.S).strip()
        if not re.fullmatch(r'assign\s+[A-Za-z_]\w*\s*=\s*[A-Za-z_]\w*\s*;', sim_b):
            return m.group(0)
        if re.search(r'\b(?:always|always_ff|always_comb|initial|force|release|bind)\b|\$', syn_b):
            return m.group(0)
        if re.search(r'\b(?:sg13g2_(?:buf|dlygate|clkbuf)\w*|(?:CLK)?BUF_X\d+|DLY\d+_X\d+)\b', syn_b):
            return sim_b
        return m.group(0)

    text = re.sub(
        r'`ifdef\s+SYNTHESIS\b((?:(?!`(?:ifdef|ifndef|else|elsif|endif)\b).)*?)`else\b((?:(?!`(?:ifdef|ifndef|else|elsif|endif)\b).)*?)`endif\b',
        _chk_buf_mux,
        text,
        flags=re.S,
    )

    # 3. Caliptra sparse-FSM flop SIMULATION hook (`CALIPTRA_PRIM_FLOP_SPARSE_FSM or 0-tied glitch_inject)
    def _chk_sim_flop(m):
        sim_b = re.sub(r'/\*.*?\*/|//[^\n]*', '', m.group(1), flags=re.S).strip()
        syn_b = re.sub(r'/\*.*?\*/|//[^\n]*', '', m.group(2), flags=re.S).strip()
        if _has_pass_banner_in_strings(m.group(0)) or re.search(r'\$|\b(?:force|release|bind|tb|dut|u_dut)\b', m.group(0)):
            return m.group(0)
        if re.match(r'^`CALIPTRA_PRIM_FLOP_SPARSE_FSM\s*\(', sim_b) and re.match(r'^always_ff\b', syn_b):
            return syn_b
        m1 = re.fullmatch(r'([A-Za-z_]\w*)\s*<=\s*([A-Za-z_]\w*)\s*;', sim_b)
        m2 = re.fullmatch(r'([A-Za-z_]\w*)\s*<=\s*([A-Za-z_]\w*)\s*;', syn_b)
        if m1 and m2 and m1.group(1) == m2.group(1) and 'glitch' in m1.group(2) or (m1 and m2 and m1.group(1) == m2.group(1) and 'state_regs_d' in m1.group(2)):
            return syn_b
        return m.group(0)

    text = re.sub(
        r'`ifdef\s+SIMULATION\b((?:(?!`(?:ifdef|ifndef|else|elsif|endif)\b).)*?)`else\b((?:(?!`(?:ifdef|ifndef|else|elsif|endif)\b).)*?)`endif\b',
        _chk_sim_flop,
        text,
        flags=re.S,
    )

    def _chk_sim_glitch_decl(m):
        body = re.sub(r'/\*.*?\*/|//[^\n]*', '', m.group(1), flags=re.S)
        if 'glitch_inject' in body and re.search(r'glitch_inject\s*=\s*1\'b0\s*;', body) and not re.search(r'\$|\b(?:always|initial|force|release|bind)\b', body):
            return ''
        return m.group(0)

    text = re.sub(
        r'`ifdef\s+SIMULATION\b((?:(?!`(?:ifdef|ifndef|else|elsif|endif)\b).)*?)`endif\b',
        _chk_sim_glitch_decl,
        text,
        flags=re.S,
    )
    return text


def _is_readonly_diag_block(raw_block: str, outside_clean: str) -> bool:
    if _has_pass_banner_in_strings(raw_block):
        return False
    body = re.sub(r'/\*.*?\*/|//[^\n]*', '', raw_block, flags=re.S)
    clean = re.sub(r'"(?:\\.|[^"\\])*"', '""', body, flags=re.S)
    # Disallow nested `else / `elsif (no behavioral branching!)
    for d in re.findall(r'(?m)^\s*`[^\n]*', clean):
        if not re.fullmatch(r'\s*`(?:ifndef\s+(?:SYNTHESIS|VERILATOR|XSIM|YOSYS)|ifdef\s+SIMULATION|endif)\b.*', d):
            return False
    if re.search(r'\b(?:force|release|bind|defparam|import|export|module|interface|package)\b', clean):
        return False
    if re.search(r'\b(?:tb|tb_\w+|dut|u_dut|grader|oracle|golden_ref)\s*\.|\$root\b', clean):
        return False
    allowed_sys = {
        'fatal', 'error', 'warning', 'info', 'display', 'write', 'strobe', 'finish',
        'time', 'realtime', 'stime', 'sformatf',
        'past', 'onehot0', 'onehot', 'bits', 'clog2', 'signed', 'unsigned', 'size',
        'stable', 'rose', 'fell', 'isunknown', 'countones',
    }
    if any(x not in allowed_sys for x in re.findall(r'\$(\w+)', clean)):
        return False
    # Any `$finish` inside a diagnostic block is ONLY allowed if the block contains an `assert` or `assume`!
    if 'finish' in re.findall(r'\$(\w+)', clean) and not re.search(r'\b(?:assert|assume)\b', clean):
        return False

    # Collect locally declared probe/debug variables (must NOT appear anywhere outside the block)
    local_vars = set()
    for dm in re.finditer(r'\b(?:logic|wire|reg|bit|int|integer|[A-Za-z_]\w*_t)\s+(?:\[[^;]+\]\s*)?([A-Za-z_]\w*)\s*(?:=\s*[^;]+)?;', clean):
        v = dm.group(1)
        if re.search(r'\b' + re.escape(v) + r'\b', outside_clean):
            return False
        local_vars.add(v)

    # Check all blocking/continuous/NBA assignments target ONLY local_vars
    clean_no_decl = re.sub(
        r'\b(?:logic|wire|reg|bit|int|integer)\s+(?:\[[^;]+\]\s*)?([A-Za-z_]\w*)\s*=\s*[^;]+;',
        '',
        clean,
    )
    for am in re.finditer(r'([A-Za-z_]\w*)\s*(?:\[[^\]]*\])?\s*(?:<=|(?<![=!<>|])=(?!=|>))', clean_no_decl):
        lhs = am.group(1)
        if lhs not in local_vars:
            return False
    return True


def assertion_only_blocks(text: str) -> str:
    """Remove verified read-only assertion/diagnostic blocks and boolean-equivalent stdcell wrappers."""
    text = _strip_stdcell_and_sparse_fsm_wrappers(text)

    # 1. Strip pragma translate_off ... translate_on (optionally wrapped immediately in `ifndef VERILATOR/SYNTHESIS ... `endif)
    pragma_wrapped = re.compile(
        r'(?is)(?:`ifndef\s+(?:VERILATOR|SYNTHESIS|YOSYS)\s*)?//\s*pragma\s+translate_off.*?//\s*pragma\s+translate_on(?:\s*`endif\b)?'
    )
    outside = re.sub(r'/\*.*?\*/|//[^\n]*', '', pragma_wrapped.sub('', text), flags=re.S)
    text = pragma_wrapped.sub(lambda m: '' if _is_readonly_diag_block(m.group(0), outside) else m.group(0), text)

    # 2. Strip standalone `ifndef SYNTHESIS / VERILATOR ... `endif or `ifdef SIMULATION ... `endif read-only blocks
    macro_blk = re.compile(
        r'`(?:ifndef\s+(?:SYNTHESIS|VERILATOR|YOSYS)|ifdef\s+SIMULATION)\b((?:(?!`(?:ifdef|ifndef|else|elsif|endif)\b).)*?)`endif\b',
        flags=re.S,
    )
    for _ in range(2):
        outside2 = re.sub(r'/\*.*?\*/|//[^\n]*', '', macro_blk.sub('', text), flags=re.S)
        text = macro_blk.sub(lambda m: '' if _is_readonly_diag_block(m.group(0), outside2) else m.group(0), text)
    return text


def sanitize_for_policy(text: str) -> str:
    """Full comment/assertion/elaboration-guard sanitizer for HDL escape screening."""
    return mask_assertions(constant_initials(benign_directives(_strip_comments_keep_strings(assertion_only_blocks(text)))))


def strip_comments_and_strings(text: str) -> str:
    text = assertion_only_blocks(constant_initials(benign_directives(text)))
    text = mask_assertions(text)
    text = re.sub(r'(?is)//\s*pragma\s+translate_off.*?//\s*pragma\s+translate_on', '', text)
    text = re.sub(r'/\*.*?\*/|//[^\n]*|"(?:\\.|[^"\\])*"', ' ', text, flags=re.S)
    return text


def screen_candidate_source(rel: pathlib.Path, mod_name: str, cand_text: str, result_path: pathlib.Path):
    if len(cand_text.encode('utf-8')) > 400_000:
        finish(result_path, 'FAIL', 'policy', f'Editable RTL {rel} exceeds size limit')
    cand_clean = strip_comments_and_strings(cand_text)
    escape_pats = [
        (r'\$(?:fopen|fclose|fread|fwrite|fdisplay|fscanf|system|finish|stop|fatal|readmemh|readmemb|writememh|writememb|dumpfile|dumpvars|value\$plusargs|test\$plusargs)\b', 'forbidden_systask'),
        (r'\b(?:force|release|bind|defparam)\b', 'procedural_force_or_bind'),
        (r'\b(?:import|export)\s*"DPI', 'dpi_escape'),
        (r'\$root\b|\b(?:tb|gate_tb|doe_key_obs|doe_cbc_obs|u_km_unit|grader|oracle)\s*\.', 'hierarchical_harness_reference'),
        (r'`\s*(?:ifdef|ifndef|elsif)\s+(?:VERILATOR|SYNTHESIS|SIMULATION|__ICARUS__|VCS|QUESTA)\b', 'simulator_macro_divergence'),
    ]
    for pat, label in escape_pats:
        if re.search(pat, cand_clean):
            finish(result_path, 'FAIL', 'policy', f'Policy violation in {rel}: {label}')
    if not re.search(rf'\bmodule\s+{re.escape(mod_name)}\b', cand_clean):
        finish(result_path, 'FAIL', 'policy', f'Missing module declaration {mod_name} in {rel}')


def verilog_hier_cell(cell_name: str) -> str:
    if re.fullmatch(r'[A-Za-z_][A-Za-z0-9_$]*', cell_name):
        return f'dut.{cell_name}.q_reg'
    return f'dut.\\{cell_name} .q_reg'


def build_gate_tb(state_dffs: list[str], km_sample_dffs: list[str], seed: int) -> str:
    flip_cases_idle = []
    flip_cases_init = []
    flip_cases_wr = []
    for idx, cn in enumerate(state_dffs):
        ref = verilog_hier_cell(cn)
        flip_cases_idle.append(f"            {idx}: {ref} = ~{ref};")
        flip_cases_init.append(f"            {idx}: {ref} = ~{ref};")
        flip_cases_wr.append(f"            {idx}: {ref} = ~{ref};")

    km_ors = ' | '.join(verilog_hier_cell(cn) for cn in km_sample_dffs) if km_sample_dffs else "1'b0"

    return f"""`timescale 1ns/1ps
module gate_tb;
    reg clk = 1'b0;
    always #5 clk = ~clk;

    reg reset_n;
    reg cptra_pwrgood;
    reg [255:0] cptra_obf_key;
    reg [255:0] obf_field_entropy;
    reg [511:0] obf_uds_seed;
    reg [255:0] obf_hek_seed;

    reg [31:0] haddr_i;
    reg [31:0] hwdata_i;
    reg        hsel_i;
    reg        hwrite_i;
    reg        hready_i;
    reg [1:0]  htrans_i;
    reg [2:0]  hsize_i;

    wire        hresp_o;
    wire        hreadyout_o;
    wire [31:0] hrdata_o;
    wire [50:0] kv_write;
    reg         kv_wr_resp;
    wire        clear_obf_secrets;
    wire        busy_o;
    wire        error_intr;
    wire        notif_intr;
    wire        doe_fsm_error;
    reg         ocp_lock_en;
    reg         doe_cmd_lock;
    reg         debugUnlock_or_scan_mode_switch;

    doe_ctrl dut (
        .clk(clk),
        .reset_n(reset_n),
        .cptra_pwrgood(cptra_pwrgood),
        .cptra_obf_key(cptra_obf_key),
        .obf_field_entropy(obf_field_entropy),
        .obf_uds_seed(obf_uds_seed),
        .obf_hek_seed(obf_hek_seed),
        .haddr_i(haddr_i),
        .hwdata_i(hwdata_i),
        .hsel_i(hsel_i),
        .hwrite_i(hwrite_i),
        .hready_i(hready_i),
        .htrans_i(htrans_i),
        .hsize_i(hsize_i),
        .hresp_o(hresp_o),
        .hreadyout_o(hreadyout_o),
        .hrdata_o(hrdata_o),
        .kv_write(kv_write),
        .kv_wr_resp(kv_wr_resp),
        .clear_obf_secrets(clear_obf_secrets),
        .busy_o(busy_o),
        .error_intr(error_intr),
        .notif_intr(notif_intr),
        .doe_fsm_error(doe_fsm_error),
        .ocp_lock_en(ocp_lock_en),
        .doe_cmd_lock(doe_cmd_lock),
        .debugUnlock_or_scan_mode_switch(debugUnlock_or_scan_mode_switch)
    );

    wire        kv_wr_en         = kv_write[50];
    wire [4:0]  kv_wr_entry      = kv_write[49:45];
    wire [3:0]  kv_wr_offset     = kv_write[44:41];
    wire [31:0] kv_wr_data       = kv_write[40:9];
    wire [8:0]  kv_wr_dest_valid = kv_write[8:0];

    wire km_any_nonzero = ({km_ors});

    integer checks = 0;
    integer failures = 0;
    reg [31:0] kv_slot3 [0:15];
    reg [8:0]  kv_slot3_dv;

    always @(posedge clk) begin
        if (reset_n && cptra_pwrgood && kv_wr_en && !kv_wr_resp && kv_wr_entry == 5'd3) begin
            kv_slot3[kv_wr_offset] <= kv_wr_data;
            kv_slot3_dv <= kv_wr_dest_valid;
        end
    end

    task check_cond(input cond, input [511:0] msg);
        begin
            checks = checks + 1;
            if (!cond) begin
                failures = failures + 1;
                if (failures <= 25)
                    $display("[GATE_FAIL] @%0t: %0s", $time, msg);
            end
        end
    endtask

    task ahb_write(input [31:0] addr, input [31:0] wdata);
        begin
            @(negedge clk);
            haddr_i  = addr;
            hsel_i   = 1'b1;
            hwrite_i = 1'b1;
            hready_i = 1'b1;
            htrans_i = 2'b10;
            hsize_i  = 3'b010;
            @(posedge clk);
            @(negedge clk);
            hwdata_i = wdata;
            haddr_i  = 32'h0;
            hsel_i   = 1'b0;
            hwrite_i = 1'b0;
            htrans_i = 2'b00;
            @(posedge clk);
            @(negedge clk);
            hwdata_i = 32'h0;
        end
    endtask

    task ahb_read(input [31:0] addr, output [31:0] rdata);
        begin
            @(negedge clk);
            haddr_i  = addr;
            hsel_i   = 1'b1;
            hwrite_i = 1'b0;
            hready_i = 1'b1;
            htrans_i = 2'b10;
            hsize_i  = 3'b010;
            @(posedge clk);
            @(negedge clk);
            haddr_i  = 32'h0;
            hsel_i   = 1'b0;
            htrans_i = 2'b00;
            while (!hreadyout_o) begin
                @(posedge clk);
                @(negedge clk);
            end
            rdata = hrdata_o;
            @(posedge clk);
        end
    endtask

    function [255:0] pack_obf_key(input [255:0] k);
        pack_obf_key = {{k[31:0], k[63:32], k[95:64], k[127:96], k[159:128], k[191:160], k[223:192], k[255:224]}};
    endfunction

    function [127:0] pack_ct_block(input [127:0] c);
        pack_ct_block = {{c[31:0], c[63:32], c[95:64], c[127:96]}};
    endfunction

    task cold_reset;
        integer k;
        begin
            haddr_i = 0; hwdata_i = 0; hsel_i = 0; hwrite_i = 0; hready_i = 1; htrans_i = 0; hsize_i = 3'b010;
            kv_wr_resp = 0; ocp_lock_en = 1; doe_cmd_lock = 0; debugUnlock_or_scan_mode_switch = 0;
            for (k = 0; k < 16; k = k + 1) kv_slot3[k] = 32'h0;
            kv_slot3_dv = 9'h0;
            cptra_pwrgood = 0;
            reset_n = 0;
            repeat (4) @(posedge clk);
            cptra_pwrgood = 1;
            repeat (2) @(posedge clk);
            reset_n = 1;
            repeat (4) @(posedge clk);
        end
    endtask

    task flip_state_bit(input integer bidx);
        begin
            case (bidx)
{chr(10).join(flip_cases_idle)}
                default: ;
            endcase
        end
    endtask

    reg [255:0] nist_key;
    reg [127:0] nist_iv;
    reg [127:0] nist_pt0, nist_pt1, nist_pt2, nist_pt3;
    reg [127:0] nist_ct0, nist_ct1, nist_ct2, nist_ct3;
    reg [31:0]  sts, rd_val;
    integer p, bit_i, w_guard;

    initial begin
        nist_key = 256'h603deb10_15ca71be_2b73aef0_857d7781_1f352c07_3b6108d7_2d9810a3_0914dff4;
        nist_iv  = 128'h00010203_04050607_08090a0b_0c0d0e0f;
        nist_pt0 = 128'h6bc1bee2_2e409f96_e93d7e11_7393172a;
        nist_pt1 = 128'hae2d8a57_1e03ac9c_9eb76fac_45af8e51;
        nist_pt2 = 128'h30c81c46_a35ce411_e5fbc119_1a0a52ef;
        nist_pt3 = 128'hf69f2445_df4f9b17_ad2b417b_e66c3710;
        nist_ct0 = 128'hf58c4c04_d6e5f1ba_779eabfb_5f7bfbd6;
        nist_ct1 = 128'h9cfc4e96_7edb808d_679f777b_c6702c7d;
        nist_ct2 = 128'h39f23369_a9d9bacf_a530e263_04231461;
        nist_ct3 = 128'hb2eb05e2_c39be9fc_da6c1907_8c6a9d1b;

        // 1) Gate-level NIST AES-256-CBC DOE_UDS unwrap check
        cold_reset();
        cptra_obf_key     = pack_obf_key(nist_key);
        obf_uds_seed      = {{pack_ct_block(nist_ct3), pack_ct_block(nist_ct2), pack_ct_block(nist_ct1), pack_ct_block(nist_ct0)}};
        obf_field_entropy = {{pack_ct_block(nist_ct1), pack_ct_block(nist_ct0)}};
        obf_hek_seed      = {{pack_ct_block(nist_ct3), pack_ct_block(nist_ct2)}};

        ahb_write(32'h0, nist_iv[127:96]);
        ahb_write(32'h4, nist_iv[95:64]);
        ahb_write(32'h8, nist_iv[63:32]);
        ahb_write(32'hc, nist_iv[31:0]);
        ahb_write(32'h10, {{23'h0, 2'b00, 5'd3, 2'b01}}); // DOE_UDS -> slot 3

        sts = 0;
        for (p = 0; p < 200; p = p + 1) begin
            ahb_read(32'h14, sts);
            if (sts[1] && !busy_o) p = 999;
        end
        check_cond(sts[1] === 1'b1 && sts[2] === 1'b1 && sts[8] === 1'b0, "Gate NIST UDS status check");
        check_cond(kv_slot3_dv === 9'h003, "Gate NIST UDS dest_valid check");
        check_cond(kv_slot3[0] === nist_pt0[127:96] && kv_slot3[3] === nist_pt0[31:0], "Gate NIST UDS block0 check");
        check_cond(kv_slot3[12] === nist_pt3[127:96] && kv_slot3[15] === nist_pt3[31:0], "Gate NIST UDS block3 check");

        // 2) Single-bit SEU state-flip across ALL {len(state_dffs)} synthesized state DFFs during IDLE, KEY-EXPANSION, and KV-WRITE!
        for (bit_i = 0; bit_i < {len(state_dffs)}; bit_i = bit_i + 1) begin
            // (a) Flip in DOE_IDLE
            cold_reset();
            @(negedge clk);
            flip_state_bit(bit_i);
            #1;
            check_cond(doe_fsm_error === 1'b1 && kv_wr_en === 1'b0, "Gate IDLE SEU combinational containment");
            @(posedge clk);
            #1;
            check_cond(doe_fsm_error === 1'b1 && kv_wr_en === 1'b0, "Gate IDLE SEU 1-cycle sticky DOE_ERROR");

            // (b) Flip mid-decrypt / key-schedule populated (cycle 18 after DOE_UDS launch)
            cold_reset();
            ahb_write(32'h0, nist_iv[127:96]);
            ahb_write(32'h4, nist_iv[95:64]);
            ahb_write(32'h8, nist_iv[63:32]);
            ahb_write(32'hc, nist_iv[31:0]);
            ahb_write(32'h10, {{23'h0, 2'b00, 5'd4, 2'b01}});
            repeat (18) @(posedge clk);
            @(negedge clk);
            flip_state_bit(bit_i);
            #1;
            check_cond(doe_fsm_error === 1'b1 && kv_wr_en === 1'b0 && kv_wr_data === 32'h0, "Gate mid-decrypt SEU combinational containment");
            @(posedge clk);
            #1;
            check_cond(doe_fsm_error === 1'b1 && kv_wr_en === 1'b0 && km_any_nonzero === 1'b0, "Gate mid-decrypt SEU 1-cycle keymem DFF wipe");
            // Verify sticky DOE_ERROR survives debugUnlock/zeroize and blocks AHB DOE_CLEAR
            debugUnlock_or_scan_mode_switch = 1'b1;
            @(posedge clk);
            debugUnlock_or_scan_mode_switch = 1'b0;
            ahb_write(32'h10, {{23'h0, 2'b00, 5'd0, 2'b11}}); // DOE_CLEAR attempt while faulted
            ahb_read(32'h14, sts);
            ahb_read(32'h0, rd_val);
            check_cond(doe_fsm_error === 1'b1 && sts[8] === 1'b1 && sts[2] === 1'b0 && rd_val === 32'h0, "Gate SEU sticky error & IV zeroization");

            // (c) Flip directly during active DOE_WRITE (while kv_wr_en == 1)!
            cold_reset();
            ahb_write(32'h0, nist_iv[127:96]);
            ahb_write(32'h4, nist_iv[95:64]);
            ahb_write(32'h8, nist_iv[63:32]);
            ahb_write(32'hc, nist_iv[31:0]);
            ahb_write(32'h10, {{23'h0, 2'b00, 5'd5, 2'b10}}); // DOE_FE -> slot 5
            w_guard = 0;
            while (!kv_wr_en && w_guard < 300) begin
                @(posedge clk);
                #1;
                w_guard = w_guard + 1;
            end
            check_cond(kv_wr_en === 1'b1, "Gate reached DOE_WRITE before SEU");
            @(negedge clk);
            flip_state_bit(bit_i);
            #1;
            check_cond(doe_fsm_error === 1'b1 && kv_wr_en === 1'b0 && kv_wr_data === 32'h0 && kv_wr_dest_valid === 9'h0,
                       "Gate DOE_WRITE SEU immediate same-cycle kv_write suppression");
            @(posedge clk);
            #1;
            check_cond(doe_fsm_error === 1'b1 && kv_wr_en === 1'b0 && km_any_nonzero === 1'b0,
                       "Gate DOE_WRITE SEU 1-cycle sticky lock & keymem wipe");
            ahb_read(32'h14, sts);
            check_cond(sts[8] === 1'b1 && sts[3] === 1'b0, "Gate DOE_WRITE SEU must set ERROR=1 and NOT set FE_FLOW_DONE");
        end

        if (failures == 0) begin
            $display("GATE_RESULT: PASS (seed=%0d, checks=%0d)", {seed}, checks);
            $finish;
        end else begin
            $display("GATE_RESULT: FAIL (seed=%0d, failures=%0d, checks=%0d)", {seed}, failures, checks);
            $finish(1);
        end
    end

    initial begin
        #8000000;
        $display("GATE_RESULT: FAIL (watchdog_timeout)");
        $finish(1);
    end
endmodule
"""


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--candidate', type=pathlib.Path, required=True)
    ap.add_argument('--seed', type=int, default=101)
    ap.add_argument('--result', type=pathlib.Path, required=True)
    args = ap.parse_args()

    cand_dir = args.candidate.resolve()
    result_path = args.result.resolve()

    if not cand_dir.is_dir() or cand_dir.is_symlink():
        finish(result_path, 'FAIL', 'policy', 'Invalid candidate directory')
    for p in cand_dir.rglob('*'):
        if p.is_symlink():
            finish(result_path, 'FAIL', 'policy', f'Symlink forbidden in candidate: {p.relative_to(cand_dir)}')

    # Verify read-only files in code/ and pdk/ match public baseline
    for sub in ('code', 'pdk'):
        pub_sub = PUB_DIR / sub
        if not pub_sub.exists():
            continue
        for pub_f in sorted(pub_sub.rglob('*')):
            if not pub_f.is_file():
                continue
            rel = pub_f.relative_to(PUB_DIR)
            cand_f = cand_dir / rel
            if not cand_f.is_file():
                finish(result_path, 'FAIL', 'policy', f'Missing required file: {rel}')
            if rel in EDITABLE_FILES:
                screen_candidate_source(rel, EDITABLE_FILES[rel], cand_f.read_text(encoding='utf-8', errors='replace'), result_path)
            else:
                if sha256_bytes(cand_f) != sha256_bytes(pub_f):
                    finish(result_path, 'FAIL', 'policy', f'Read-only file modified: {rel}')

    env = os.environ.copy()
    env['PATH'] = f"{VERILATOR.parent}:{IVERILOG.parent}:{YOSYS.parent}:{env.get('PATH', '')}"
    env['VERILATOR_ROOT'] = str(TOOLS_DIR / 'verilator-v5.038' / 'share' / 'verilator')

    with tempfile.TemporaryDirectory(prefix='case_25002_grade_') as td_s:
        td = pathlib.Path(td_s)
        work = td / 'work'
        shutil.copytree(PUB_DIR, work)
        for rel in EDITABLE_FILES:
            shutil.copy2(cand_dir / rel, work / rel)

        # Stage 1: Verilator RTL Simulation
        tb_copy = td / 'tb.sv'
        shutil.copy2(PRIV_DIR / 'tests' / 'tb.sv', tb_copy)
        v_cmd = [
            str(VERILATOR), '--binary', '--timing', '-Wno-fatal', '-sv',
            f'-I{work / "code"}', '-CFLAGS', '-O0',
            *[str(work / s) for s in RTL_SOURCES],
            str(tb_copy), '--top-module', 'tb', '-Mdir', str(td / 'obj_rtl')
        ]
        r_comp = subprocess.run(v_cmd, env=env, capture_output=True, text=True, timeout=120)
        if r_comp.returncode != 0:
            tail = (r_comp.stdout + '\n' + r_comp.stderr)[-1500:]
            finish(result_path, 'FAIL', 'functional', f'Verilator RTL compilation failed:\n{tail}')

        r_sim = subprocess.run([str(td / 'obj_rtl' / 'Vtb'), f'+seed={args.seed}'], env=env, capture_output=True, text=True, timeout=90)
        if r_sim.returncode != 0 or 'RESULT: PASS' not in r_sim.stdout:
            tail = (r_sim.stdout + '\n' + r_sim.stderr)[-1800:]
            finish(result_path, 'FAIL', 'functional', f'RTL security verification failed (seed={args.seed}):\n{tail}')

        # Stage 2: Yosys-Slang Nangate45 Gate-Level Synthesis & Sparse-FSM Preservation
        lib_path = work / 'pdk' / 'NangateOpenCellLibrary_typical.lib'
        gate_json = td / 'doe_gate.json'
        gate_v = td / 'doe_gate.v'
        src_list = ' '.join(str(work / s) for s in RTL_SOURCES)
        ys_script = (
            f'read_slang -DSYNTHESIS -I{work / "code"} {src_list} --top doe_ctrl; '
            f'synth -top doe_ctrl; '
            f'select -assert-none t:$dlatch*; '
            f'check -assert; '
            f'scc -expect 0; '
            f'dfflibmap -liberty {lib_path}; '
            f'abc -liberty {lib_path}; '
            f'setattr -mod -unset keep_hierarchy *; '
            f'setattr -unset keep_hierarchy *; '
            f'flatten; '
            f'opt_clean; '
            f'rename -enumerate -pattern _c%_ c:*; '
            f'write_json {gate_json}; '
            f'write_verilog -noattr {gate_v}'
        )
        r_syn = subprocess.run([str(YOSYS), '-m', 'slang', '-p', ys_script], env=env, capture_output=True, text=True, timeout=150)
        if r_syn.returncode != 0 or not gate_json.exists():
            tail = (r_syn.stdout + '\n' + r_syn.stderr)[-1800:]
            finish(result_path, 'FAIL', 'synthesis', f'Yosys-Slang Nangate45 synthesis / latch / SCC check failed:\n{tail}')

        net_data = json.loads(gate_json.read_text(encoding='utf-8'))
        top_mod = net_data.get('modules', {}).get('doe_ctrl', {})
        ps_bits = set()
        km_bits = set()
        for nn, nd in top_mod.get('netnames', {}).items():
            if 'kv_doe_fsm_ps' in nn:
                ps_bits.update(b for b in nd.get('bits', []) if isinstance(b, int))
            if 'keymem.key_mem' in nn:
                km_bits.update(b for b in nd.get('bits', []) if isinstance(b, int))

        state_dffs = []
        km_dffs = []
        for cn, cd in sorted(top_mod.get('cells', {}).items()):
            ctype = cd.get('type', '')
            if ctype.startswith(('DFF', 'SDFF')):
                conns = cd.get('connections', {})
                qbits = set(b for p in ('Q', 'QN') for b in conns.get(p, []) if isinstance(b, int))
                if qbits & ps_bits:
                    state_dffs.append(cn)
                if qbits & km_bits:
                    km_dffs.append(cn)

        if len(ps_bits) < 10 or len(state_dffs) < 10:
            finish(
                result_path, 'FAIL', 'synthesis',
                f'Sparse FSM state flip-flops pruned during Nangate45 synthesis: '
                f'kv_doe_fsm_ps net bits={len(ps_bits)}, driving DFF cells={len(state_dffs)} (required >= 10)'
            )

        # Sample up to 64 spread-out keymem DFFs across round keys 0..14 (including upper round keys)
        if len(km_dffs) > 64:
            step = max(1, len(km_dffs) // 64)
            km_sample = km_dffs[::step][:63] + [km_dffs[-1]]
        else:
            km_sample = km_dffs

        # Stage 3: Post-Synthesis Gate-Level Simulation & Single-Bit State-DFF Fault Injection
        raw_cells_v = td / 'raw_cells.v'
        r_lib = subprocess.run(
            [str(YOSYS), '-q', '-p', f'read_liberty -ignore_miss_func {lib_path}; proc; write_verilog -noattr {raw_cells_v}'],
            env=env, capture_output=True, text=True, timeout=60
        )
        if r_lib.returncode != 0 or not raw_cells_v.exists():
            finish(result_path, 'ERROR', 'synthesis', f'Failed to extract Nangate45 cell models: {r_lib.stderr[-800:]}')

        cells_txt = raw_cells_v.read_text(encoding='utf-8')
        cells_txt = re.sub(r'module\s+(?:S?DFF[A-Z0-9_]*)\s*\([^;]*?\);.*?endmodule', '', cells_txt, flags=re.S)
        sim_cells_v = td / 'nangate45_sim_cells.v'
        sim_cells_v.write_text(cells_txt + '\n' + SINGLE_REG_DFF_MODELS + '\n', encoding='utf-8')

        gate_tb_sv = td / 'gate_tb.sv'
        gate_tb_sv.write_text(build_gate_tb(state_dffs, km_sample, args.seed), encoding='utf-8')

        sim_vvp = td / 'gate_sim.vvp'
        r_iv = subprocess.run(
            [str(IVERILOG), '-g2012', '-o', str(sim_vvp), str(sim_cells_v), str(gate_v), str(gate_tb_sv)],
            env=env, capture_output=True, text=True, timeout=90
        )
        if r_iv.returncode != 0:
            tail = (r_iv.stdout + '\n' + r_iv.stderr)[-1500:]
            finish(result_path, 'FAIL', 'functional', f'Post-synthesis gate-level compilation failed:\n{tail}')

        r_vvp = subprocess.run([str(VVP), str(sim_vvp)], env=env, capture_output=True, text=True, timeout=120)
        if r_vvp.returncode != 0 or 'GATE_RESULT: PASS' not in r_vvp.stdout:
            tail = (r_vvp.stdout + '\n' + r_vvp.stderr)[-1800:]
            finish(result_path, 'FAIL', 'functional', f'Post-synthesis gate-level fault-injection failed:\n{tail}')

        finish(
            result_path, 'PASS', 'functional',
            f'Passed RTL verification, Nangate45 synthesis ({len(state_dffs)} sparse FSM DFFs preserved, 0 latches, 0 SCCs), '
            f'and gate-level single-bit SEU fault injection (seed={args.seed})'
        )


if __name__ == '__main__':
    main()
