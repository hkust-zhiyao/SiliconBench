#!/usr/bin/env python3
"""Isolated trusted grader for case_22003 (Ara lane integer VMFPU + SIMD Divider PPA & Fast-Skip)."""
import argparse
import json
import pathlib
import re
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
VERILATOR = TOOLS_DIR / 'verilator-v5.038/bin/verilator'
YOSYS = TOOLS_DIR / 'oss-cad-suite/bin/yosys'
OPENROAD = TOOLS_DIR / 'bin/openroad'

EDITABLE_FILES = {
    'code/vmfpu.sv': 'vmfpu',
    'code/simd_div.sv': 'simd_div',
}
ALLOWED_INCLUDES = {
    'common_cells/registers.svh',
    'common_cells/assertions.svh',
}
SV_COMPILE_ORDER = [
    'cf_math_pkg.sv',
    'config_pkg.sv',
    'cv64a6_imafdcv_sv39_config_pkg.sv',
    'riscv_pkg.sv',
    'ariane_pkg.sv',
    'axi_pkg.sv',
    'fpnew_pkg.sv',
    'rvv_pkg.sv',
    'ara_pkg.sv',
    'lzc.sv',
    'spill_register_flushable.sv',
    'spill_register.sv',
    'tc_clk.sv',
    'power_gating_generic.sv',
    'serdiv.sv',
    'simd_mul.sv',
    'simd_div.sv',
    'vmfpu.sv',
    'vmfpu_synth_top.sv',
]

AREA_LIMIT_UM2 = 83600.0
CLOCK_PERIOD_NS = 5.20


def finish(result_path: pathlib.Path, verdict: str, stage: str, detail: str, **extra):
    payload = {
        'verdict': verdict,
        'stage': stage,
        'detail': detail,
        'reason': detail,
        **extra,
    }
    result_path.parent.mkdir(parents=True, exist_ok=True)
    result_path.write_text(json.dumps(payload, indent=2) + '\n', encoding='utf-8')
    print(json.dumps(payload))
    raise SystemExit(0 if verdict == 'PASS' else 2 if verdict == 'ERROR' else 1)


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
    text = re.sub(r'(?is)//\s*pragma\s+translate_off.*?//\s*pragma\s+translate_on', ' ', text)
    text = re.sub(r'/\*.*?\*/|//[^\n]*|"(?:\\.|[^"\\])*"', ' ', text, flags=re.S)
    return text


def screen_editable_rtl(rel_path: str, expected_mod: str, cand_text: str, base_text: str, result_path: pathlib.Path):
    if len(cand_text.encode('utf-8')) > 350_000:
        finish(result_path, 'FAIL', 'policy', f'{rel_path} exceeds source size limit')

    # Screen raw comments/pragmas for synthesis-hiding directives added by candidate
    pragma_pat = r'(?i)\b(?:translate_off|translate_on|synthesis\s+off)\b'
    if len(re.findall(pragma_pat, cand_text)) > len(re.findall(pragma_pat, base_text)):
        finish(result_path, 'FAIL', 'policy', f'Disallowed synthesis/lint pragma added in {rel_path}')

    # Screen comment-stripped text BEFORE string-literal removal so `include "..." and import "DPI-C" are caught
    no_comments = re.sub(r'(?is)//\s*pragma\s+translate_off.*?//\s*pragma\s+translate_on', ' ', cand_text)
    no_comments = re.sub(r'/\*.*?\*/|//[^\n]*', ' ', no_comments, flags=re.S)

    for m_inc in re.finditer(r'`\s*include\s*(?:"([^"]*)"|<([^>]*)>|(\S+))', no_comments):
        inc = m_inc.group(1) or m_inc.group(2) or m_inc.group(3) or ''
        if inc not in ALLOWED_INCLUDES or '..' in inc or inc.startswith('/'):
            finish(result_path, 'FAIL', 'policy', f'Unauthorized include directive in {rel_path}: {inc}')

    if re.search(r'\b(?:import|export)\s*"DPI', no_comments):
        finish(result_path, 'FAIL', 'policy', f'Policy violation in {rel_path}: dpi_escape')

    cand_clean = strip_comments_and_strings(cand_text)
    base_clean = strip_comments_and_strings(base_text)

    escape_pats = [
        (r'\$(?:fopen|fclose|fread|fwrite|fdisplay|fscanf|system|finish|stop|fatal|readmemh|readmemb|writememh|writememb|dumpfile|dumpvars|value\$plusargs|test\$plusargs|random|urandom)\b', 'forbidden_systask'),
        (r'\b(?:force|release|bind|defparam)\b', 'procedural_force_or_bind'),
        (r'\b(?:import|export)\s*"DPI', 'dpi_escape'),
        (r'\$root\b|\b(?:tb|dut|grader|oracle|exp_res_q|exp_done_q)\s*\.', 'hierarchical_harness_reference'),
        (r'`\s*(?:ifdef|ifndef|elsif)\s+(?:VERILATOR|SYNTHESIS|SIMULATION|__ICARUS__|VCS|QUESTA)\b', 'simulator_macro_divergence'),
    ]
    for pat, label in escape_pats:
        if len(re.findall(pat, cand_clean, re.I)) > len(re.findall(pat, base_clean, re.I)):
            finish(result_path, 'FAIL', 'policy', f'Policy violation in {rel_path}: {label}')

    if len(re.findall(rf'\bmodule\s+{expected_mod}\b', cand_clean)) != 1:
        finish(result_path, 'FAIL', 'structural', f'Expected module {expected_mod} in {rel_path}')


def verify_candidate_tree(cand_dir: pathlib.Path, result_path: pathlib.Path):
    for sub in ('code', 'lib'):
        pub_sub = PUB_DIR / sub
        for p in sorted(pub_sub.rglob('*')):
            if not p.is_file():
                continue
            rel = p.relative_to(PUB_DIR).as_posix()
            q = cand_dir / rel
            if not q.exists() or not q.is_file() or q.is_symlink():
                finish(result_path, 'FAIL', 'policy', f'Missing or symlinked file in candidate: {rel}')
            try:
                q_resolved = q.resolve(strict=True)
            except Exception:
                finish(result_path, 'FAIL', 'policy', f'Unresolvable path in candidate: {rel}')
            if cand_dir != q_resolved and cand_dir not in q_resolved.parents:
                finish(result_path, 'FAIL', 'policy', f'Path escape detected in candidate: {rel}')
            if rel not in EDITABLE_FILES:
                if q.read_bytes() != p.read_bytes():
                    finish(result_path, 'FAIL', 'policy', f'Protected read-only file modified: {rel}')

    # Reject extra unexpected SV/Verilog files injected into candidate/code
    pub_rels = {p.relative_to(PUB_DIR).as_posix() for p in (PUB_DIR / 'code').rglob('*') if p.is_file()}
    for q in sorted((cand_dir / 'code').rglob('*')):
        if q.is_symlink():
            finish(result_path, 'FAIL', 'policy', f'Symlink not permitted in candidate/code: {q.name}')
        if q.is_file():
            rel = q.relative_to(cand_dir).as_posix()
            if rel not in pub_rels:
                finish(result_path, 'FAIL', 'policy', f'Unexpected extra file in candidate/code: {rel}')

    for rel, mod_name in EDITABLE_FILES.items():
        cand_txt = (cand_dir / rel).read_text(encoding='utf-8', errors='replace')
        base_txt = (PUB_DIR / rel).read_text(encoding='utf-8', errors='replace')
        screen_editable_rtl(rel, mod_name, cand_txt, base_txt, result_path)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--candidate', required=True)
    ap.add_argument('--seed', type=int, default=101)
    ap.add_argument('--result', required=True)
    args = ap.parse_args()

    result_path = pathlib.Path(args.result).resolve()
    try:
        cand_dir = pathlib.Path(args.candidate).resolve(strict=True)
    except Exception as exc:
        finish(result_path, 'FAIL', 'policy', f'Invalid candidate directory: {exc}')

    # 1. Policy & Read-Only Integrity Check
    verify_candidate_tree(cand_dir, result_path)

    code_dir = cand_dir / 'code'
    lib_dir = PUB_DIR / 'lib'
    sv_files = [str(code_dir / f) for f in SV_COMPILE_ORDER]

    with tempfile.TemporaryDirectory(prefix='case_22003_grade_') as tmpd:
        td = pathlib.Path(tmpd)

        # 2. Verilator Functional & Quantitative Latency Verification
        sim_dir = td / 'sim_build'
        sim_dir.mkdir()
        compile_cmd = [
            str(VERILATOR),
            '--binary', '--timing', '-j', '4', '-Wno-fatal',
            '--top-module', 'tb',
            f'-I{code_dir / "include"}',
            '-Mdir', str(sim_dir),
            '-o', 'Vtb',
            *sv_files,
            str(PRIV_DIR / 'tests/tb.sv'),
        ]
        try:
            c_proc = subprocess.run(compile_cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=180)
        except subprocess.TimeoutExpired:
            finish(result_path, 'FAIL', 'behavior', 'Verilator compilation timed out')
        if c_proc.returncode != 0 or not (sim_dir / 'Vtb').is_file():
            tail = '\n'.join(c_proc.stdout.splitlines()[-30:])
            finish(result_path, 'FAIL', 'behavior', f'Verilator compilation failed:\n{tail}')

        try:
            s_proc = subprocess.run(
                [str(sim_dir / 'Vtb'), f'+seed={args.seed}'],
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                timeout=90,
            )
        except subprocess.TimeoutExpired:
            finish(result_path, 'FAIL', 'behavior', f'Functional simulation timed out (seed={args.seed})')
        print(s_proc.stdout[-4000:])
        if (
            s_proc.returncode != 0
            or 'PASS:' not in s_proc.stdout
            or '[ERROR]' in s_proc.stdout
            or '[FATAL]' in s_proc.stdout
        ):
            tail = '\n'.join(s_proc.stdout.splitlines()[-25:])
            finish(result_path, 'FAIL', 'behavior', f'Functional or masked-latency verification failed (seed={args.seed}):\n{tail}')

        # 3. Deterministic Yosys+Slang Synthesis & Area Sign-Off
        netlist_v = td / 'netlist.v'
        lib_file = lib_dir / 'NangateOpenCellLibrary_typical.lib'
        files_str = ' '.join(sv_files)
        ys_cmd = (
            f'read_slang -DSYNTHESIS -I{code_dir / "include"} --top vmfpu_synth_top --ignore-assertions {files_str}; '
            f'hierarchy -check -top vmfpu_synth_top; '
            f'proc; check -assert; '
            f'synth -top vmfpu_synth_top -noabc; '
            f'dfflibmap -liberty {lib_file}; '
            f'abc -liberty {lib_file} -script +strash;dc2;map; '
            f'opt_clean; '
            f'stat -liberty {lib_file}; '
            f'write_verilog -noattr {netlist_v}'
        )
        try:
            y_proc = subprocess.run(
                [str(YOSYS), '-m', 'slang', '-p', ys_cmd],
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                timeout=180,
            )
        except subprocess.TimeoutExpired:
            finish(result_path, 'FAIL', 'synthesis', 'Yosys+slang synthesis timed out')
        m_area = re.search(r"Chip area for module '\\vmfpu_synth_top':\s*([0-9.]+)", y_proc.stdout)
        if y_proc.returncode != 0 or not m_area or not netlist_v.is_file():
            tail = '\n'.join(y_proc.stdout.splitlines()[-30:])
            finish(result_path, 'FAIL', 'synthesis', f'Yosys+slang synthesis or check -assert failed:\n{tail}')

        area_um2 = round(float(m_area.group(1)), 3)
        if area_um2 > AREA_LIMIT_UM2:
            finish(
                result_path,
                'FAIL',
                'area',
                f'Mapped cell area {area_um2:.3f} um^2 exceeds target {AREA_LIMIT_UM2:.1f} um^2',
                measured_area_um2=area_um2,
                target_area_um2=AREA_LIMIT_UM2,
            )

        # 4. OpenROAD Static Timing Analysis Sign-Off
        sta_tcl = td / 'sta.tcl'
        sta_tcl.write_text(
            f'read_lef {lib_dir / "NangateOpenCellLibrary.tech.lef"}\n'
            f'read_lef {lib_dir / "NangateOpenCellLibrary.macro.mod.lef"}\n'
            f'read_liberty {lib_file}\n'
            f'read_verilog {netlist_v}\n'
            f'link_design vmfpu_synth_top\n'
            f'create_clock -name clk_i -period {CLOCK_PERIOD_NS:.2f} [get_ports clk_i]\n'
            f'set_input_delay 0.20 -clock clk_i [all_inputs -no_clocks]\n'
            f'set_output_delay 0.20 -clock clk_i [all_outputs]\n'
            f'set_load 5.0 [all_outputs]\n'
            f'puts "=== SETUP ==="\n'
            f'report_checks -path_delay max -group_path_count 5 -digits 3\n'
            f'puts "=== HOLD ==="\n'
            f'report_checks -path_delay min -group_path_count 5 -digits 3\n',
            encoding='utf-8',
        )
        o_proc = subprocess.run(
            [str(OPENROAD), '-exit', str(sta_tcl)],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            timeout=90,
        )
        if o_proc.returncode != 0:
            tail = '\n'.join(o_proc.stdout.splitlines()[-25:])
            finish(result_path, 'FAIL', 'timing', f'OpenROAD STA execution failed:\n{tail}', measured_area_um2=area_um2)

        setup_sec = re.search(r'=== SETUP ===(.*?)=== HOLD ===', o_proc.stdout, re.S)
        hold_sec = re.search(r'=== HOLD ===(.*)$', o_proc.stdout, re.S)
        if not setup_sec or not hold_sec:
            finish(result_path, 'FAIL', 'timing', 'Incomplete OpenROAD STA report sections', measured_area_um2=area_um2)

        setup_slacks = [float(v) for v in re.findall(r'([-0-9.]+)\s+slack \((?:MET|VIOLATED)\)', setup_sec.group(1))]
        hold_slacks = [float(v) for v in re.findall(r'([-0-9.]+)\s+slack \((?:MET|VIOLATED)\)', hold_sec.group(1))]
        if not setup_slacks or not hold_slacks:
            finish(result_path, 'FAIL', 'timing', 'Failed to parse setup/hold slack from OpenROAD STA', measured_area_um2=area_um2)

        worst_setup_ns = round(min(setup_slacks), 3)
        worst_hold_ns = round(min(hold_slacks), 3)

        if worst_setup_ns < 0.0:
            finish(
                result_path,
                'FAIL',
                'timing',
                f'Worst setup slack {worst_setup_ns:.3f} ns < 0.000 ns at {CLOCK_PERIOD_NS:.2f} ns clock',
                measured_area_um2=area_um2,
                worst_setup_slack_ns=worst_setup_ns,
                worst_hold_slack_ns=worst_hold_ns,
            )
        if worst_hold_ns < 0.0:
            finish(
                result_path,
                'FAIL',
                'timing',
                f'Worst hold slack {worst_hold_ns:.3f} ns < 0.000 ns',
                measured_area_um2=area_um2,
                worst_setup_slack_ns=worst_setup_ns,
                worst_hold_slack_ns=worst_hold_ns,
            )

        finish(
            result_path,
            'PASS',
            'all',
            f'All functional, masked fast-skip latency, Nangate45 area ({area_um2:.1f} um^2), and STA checks (setup={worst_setup_ns:.3f} ns, hold={worst_hold_ns:.3f} ns) passed for seed={args.seed}',
            measured_area_um2=area_um2,
            target_area_um2=AREA_LIMIT_UM2,
            worst_setup_slack_ns=worst_setup_ns,
            worst_hold_slack_ns=worst_hold_ns,
        )


if __name__ == '__main__':
    main()
