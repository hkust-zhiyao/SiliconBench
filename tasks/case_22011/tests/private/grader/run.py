#!/usr/bin/env python3
"""Private isolated grader for case_22011 (Ara RVV 1.0 Segmented Load/Store Sequencer & Dispatcher)."""
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
PRIV_DIR = TASK_DIR / 'private'
PUB_DIR = TASK_DIR / 'public'
TOOLS_DIR = pathlib.Path(str(_sb_tools_dir()))
VERILATOR = TOOLS_DIR / 'verilator-v5.038' / 'bin' / 'verilator'
YOSYS = TOOLS_DIR / 'oss-cad-suite' / 'bin' / 'yosys'

EDITABLE_SPECS = [
    (pathlib.Path('code/ara_dispatcher.sv'), 'ara_dispatcher'),
    (pathlib.Path('code/segment_sequencer.sv'), 'segment_sequencer'),
]
EDITABLE_SET = {rel for rel, _ in EDITABLE_SPECS}

ALLOWED_INCLUDES = {
    'common_cells/registers.svh',
    'common_cells/assertions.svh',
    'ara/ara_typedef.svh',
    'ara/intf_typedef.svh',
}

SIM_RTL_ORDER = [
    'code/config_pkg.sv',
    'code/cv64a6_imafdcv_sv39_config_pkg.sv',
    'code/build_config_pkg.sv',
    'code/riscv_pkg.sv',
    'code/cf_math_pkg.sv',
    'code/axi_pkg.sv',
    'code/fpnew_pkg.sv',
    'code/rvv_pkg.sv',
    'code/ara_pkg.sv',
    'code/onehot_to_bin.sv',
    'code/lzc.sv',
    'code/popcount.sv',
    'code/counter.sv',
    'code/delta_counter.sv',
    'code/fall_through_register.sv',
    'code/spill_register_flushable.sv',
    'code/spill_register.sv',
    'code/fifo_v3.sv',
    'code/rr_arb_tree.sv',
    'code/stream_arbiter_flushable.sv',
    'code/stream_arbiter.sv',
    'code/stream_demux.sv',
    'code/stream_mux.sv',
    'code/stream_xbar.sv',
    'code/axi_cut.sv',
    'code/segment_sequencer.sv',
    'code/ara_dispatcher.sv',
    'code/ara_sequencer.sv',
    'code/vlsu/addrgen.sv',
    'code/vlsu/vldu.sv',
    'code/vlsu/vstu.sv',
    'code/vlsu/vlsu.sv',
]

SYNTH_RTL_ORDER = [
    'code/config_pkg.sv',
    'code/cv64a6_imafdcv_sv39_config_pkg.sv',
    'code/build_config_pkg.sv',
    'code/riscv_pkg.sv',
    'code/cf_math_pkg.sv',
    'code/axi_pkg.sv',
    'code/fpnew_pkg.sv',
    'code/rvv_pkg.sv',
    'code/ara_pkg.sv',
    'code/counter.sv',
    'code/delta_counter.sv',
    'code/lzc.sv',
    'code/popcount.sv',
    'code/fifo_v3.sv',
    'code/spill_register_flushable.sv',
    'code/spill_register.sv',
    'code/segment_sequencer.sv',
    'code/ara_dispatcher.sv',
]


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


def strip_comments(text: str) -> str:
    text = assertion_only_blocks(constant_initials(benign_directives(text)))
    text = mask_assertions(text)
    text = re.sub(r'(?is)//\s*pragma\s+translate_off.*?//\s*pragma\s+translate_on', '', text)
    return re.sub(r'/\*.*?\*/|//[^\n]*', ' ', text, flags=re.S)


def screen_source(cand_text: str, base_text: str, mod_name: str, rel_name: str, result_path: pathlib.Path):
    if len(cand_text.encode('utf-8')) > 600_000:
        finish(result_path, 'FAIL', 'policy', f'Editable RTL exceeds size limit: {rel_name}')

    cand_clean = strip_comments(cand_text)
    base_clean = strip_comments(base_text)

    escape_pats = [
        (r'\$(?:fopen|fclose|fread|fwrite|fdisplay|fscanf|system|finish|stop|fatal|readmemh|readmemb|writememh|writememb|dumpfile|dumpvars|value\$plusargs|test\$plusargs)\b', 'forbidden_systask'),
        (r'\b(?:force|release|bind|defparam)\b', 'procedural_force_or_bind'),
        (r'\b(?:import|export)\s*"DPI', 'dpi_escape'),
        (r'\$root\b|\b(?:tb|grader|oracle|golden_ref|synth_top)\s*\.', 'hierarchical_harness_reference'),
        (r'`\s*(?:ifdef|ifndef|elsif)\s+(?:VERILATOR|SYNTHESIS|SIMULATION|__ICARUS__|VCS|QUESTA)\b', 'simulator_macro_divergence'),
    ]
    for pat, label in escape_pats:
        if len(re.findall(pat, cand_clean, re.I)) > len(re.findall(pat, base_clean, re.I)):
            finish(result_path, 'FAIL', 'policy', f'Policy violation in {rel_name}: {label}')

    for inc in re.findall(r'`include\s+"([^"]+)"', cand_clean):
        if inc not in ALLOWED_INCLUDES:
            finish(result_path, 'FAIL', 'policy', f'Unauthorized include directive in {rel_name}: {inc}')

    if len(re.findall(rf'\bmodule\s+{re.escape(mod_name)}\b', cand_clean)) != 1:
        finish(result_path, 'FAIL', 'structural', f'Expected single module declaration {mod_name} in {rel_name}')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--candidate', required=True)
    ap.add_argument('--seed', type=int, default=101)
    ap.add_argument('--result', required=True)
    args = ap.parse_args()

    result_path = pathlib.Path(args.result).resolve()
    cand_root = pathlib.Path(args.candidate)
    if cand_root.is_symlink() or not cand_root.is_dir():
        finish(result_path, 'FAIL', 'input_validation', 'Invalid candidate directory')
    cand_root = cand_root.resolve()

    is_full_tree = (cand_root / 'issue.md').is_file() or (sum(1 for _ in (cand_root / 'code').glob('*')) > len(EDITABLE_SET) + 1 if (cand_root / 'code').is_dir() else False)
    if is_full_tree:
        for ref_file in sorted((PUB_DIR / 'code').rglob('*')):
            if not ref_file.is_file():
                continue
            rel = ref_file.relative_to(PUB_DIR)
            if rel in EDITABLE_SET:
                continue
            c_file = cand_root / rel
            if not c_file.is_file() or c_file.is_symlink() or sha256_bytes(c_file) != sha256_bytes(ref_file):
                finish(result_path, 'FAIL', 'policy', f'Protected file modified or missing: {rel}')

    cand_sources = {}
    for rel, mod_name in EDITABLE_SPECS:
        c_file = (cand_root / rel) if (cand_root / rel).exists() else (cand_root / rel.name)
        if not c_file.exists() or c_file.is_symlink() or not c_file.is_file() or not c_file.resolve().is_relative_to(cand_root):
            finish(result_path, 'FAIL', 'input_validation', f'Missing or invalid editable file: {rel}')
        c_txt = c_file.read_text(encoding='utf-8', errors='replace')
        b_txt = (PUB_DIR / rel).read_text(encoding='utf-8')
        screen_source(c_txt, b_txt, mod_name, str(rel), result_path)
        cand_sources[rel] = c_txt

    try:
        with tempfile.TemporaryDirectory(prefix='case_22011_grade_') as td:
            work = pathlib.Path(td)
            shutil.copytree(PUB_DIR / 'code', work / 'code')
            for rel, txt in cand_sources.items():
                (work / rel).write_text(txt, encoding='utf-8')
            shutil.copyfile(PRIV_DIR / 'tests/tb.sv', work / 'tb.sv')
            shutil.copyfile(PRIV_DIR / 'tests/synth_top.sv', work / 'synth_top.sv')

            env = {
                'PATH': f'{TOOLS_DIR}/verilator-v5.038/bin:{TOOLS_DIR}/oss-cad-suite/bin:/usr/bin:/bin',
                'HOME': str(work),
                'TMPDIR': str(work),
                'CC': '/usr/bin/gcc',
                'CXX': '/usr/bin/g++',
            }

            cmd_comp = [
                str(VERILATOR),
                '--binary', '-j', '2', '-O1', '-CFLAGS', '-O0',
                '--output-split', '8000',
                '-Wno-fatal', '-Wno-TIMESCALEMOD', '-DSYNTHESIS',
                '-Icode/include',
                '--top-module', 'tb',
                '--Mdir', str(work / 'obj_dir'),
                *SIM_RTL_ORDER,
                'tb.sv',
            ]
            r_comp = subprocess.run(cmd_comp, cwd=work, env=env, capture_output=True, text=True, timeout=450)
            if r_comp.returncode != 0 or not (work / 'obj_dir/Vtb').is_file():
                tail = (r_comp.stdout + '\n' + r_comp.stderr).strip()[-1500:]
                finish(result_path, 'FAIL', 'compile', f'Verilator compile failed: {tail}')

            r_sim = subprocess.run([str(work / 'obj_dir/Vtb'), f'+seed={args.seed}'], cwd=work, env=env, capture_output=True, text=True, timeout=120)
            sim_out = (r_sim.stdout + '\n' + r_sim.stderr).strip()
            if r_sim.returncode != 0 or f'PASS seed={args.seed}' not in sim_out:
                fail_lines = [ln for ln in sim_out.splitlines() if '[FAIL]' in ln or 'FAIL' in ln][:5]
                head = ('\n'.join(fail_lines) + '\n...\n') if fail_lines else ''
                finish(result_path, 'FAIL', 'functional', f'Simulation failed (seed={args.seed}): {head}{sim_out[-1500:]}')

            if args.seed == 101:
                stat_json = work / 'stat.json'
                ys_script = (
                    'read_slang -DSYNTHESIS --ignore-assertions --unroll-limit 20000 '
                    '-Icode/include --top synth_top '
                    + ' '.join(SYNTH_RTL_ORDER) + ' synth_top.sv; '
                    'hierarchy -check -top synth_top; proc; opt_clean; check -assert; '
                    f'tee -q -o {stat_json} stat -json'
                )
                r_ys = subprocess.run([str(YOSYS), '-m', 'slang', '-p', ys_script], cwd=work, env=env, capture_output=True, text=True, timeout=240)
                if r_ys.returncode != 0 or not stat_json.is_file():
                    tail = (r_ys.stdout + '\n' + r_ys.stderr).strip()[-1500:]
                    finish(result_path, 'FAIL', 'synthesis', f'Yosys slang synthesis check failed: {tail}')
                st = json.loads(stat_json.read_text())
                latches = sum(int(v) for k, v in st.get('design', {}).get('num_cells_by_type', {}).items() if 'dlatch' in k.lower() or 'latch' in k.lower())
                if latches > 0:
                    finish(result_path, 'FAIL', 'synthesis', f'Unintended latch inference detected ({latches} latches)')

            finish(result_path, 'PASS', 'functional', f'All RVV 1.0 segmented load/store decomposition, legality, exception, reshuffle, and synthesis checks passed (seed={args.seed})')
    except subprocess.TimeoutExpired:
        finish(result_path, 'FAIL', 'functional', f'Simulation or synthesis timed out (possible handshake deadlock) for seed={args.seed}')
    except OSError as exc:
        finish(result_path, 'ERROR', 'environment', f'OS error: {exc}')


if __name__ == '__main__':
    main()
