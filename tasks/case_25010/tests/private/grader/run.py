#!/usr/bin/env python3
"""Private isolated grader for case_25010 (Snitch 2-Port 6-SRAM ICache Coherence & SG13G2 Macro PnR)."""
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
YOSYS = TOOLS_DIR / "oss-cad-suite" / "bin" / "yosys"
OPENROAD = TOOLS_DIR / "bin" / "openroad"

EDITABLE_RTL = {
    pathlib.Path("code/snitch_icache.sv"): ["snitch_icache", "l0_to_bypass"],
    pathlib.Path("code/snitch_icache_l0.sv"): ["snitch_icache_l0"],
    pathlib.Path("code/snitch_icache_lookup.sv"): ["snitch_icache_lookup"],
    pathlib.Path("code/snitch_icache_handler.sv"): ["snitch_icache_handler"],
    pathlib.Path("code/snitch_icache_refill.sv"): ["snitch_icache_refill"],
}
EDITABLE_ALL = list(EDITABLE_RTL.keys()) + [
    pathlib.Path("plan/macro_placement.json"),
    pathlib.Path("constraints/snitch_icache.sdc"),
]

EXPECTED_MACROS = {
    "u_icache.i_lookup.g_sets[0].i_tag.gen_tag_macro.u_sram",
    "u_icache.i_lookup.g_sets[0].i_data.gen_data_macros.u_sram_lo",
    "u_icache.i_lookup.g_sets[0].i_data.gen_data_macros.u_sram_hi",
    "u_icache.i_lookup.g_sets[1].i_tag.gen_tag_macro.u_sram",
    "u_icache.i_lookup.g_sets[1].i_data.gen_data_macros.u_sram_lo",
    "u_icache.i_lookup.g_sets[1].i_data.gen_data_macros.u_sram_hi",
}
MACRO_W = 784.48
MACRO_H = 118.78
CORE_X0, CORE_Y0, CORE_X1, CORE_Y1 = 50.0, 50.0, 2350.0, 1550.0
CORE_MARGIN = 2.0
MACRO_HALO = 8.0
LEGAL_ORIENTS = {"R0", "R180", "MX", "MY"}

SIGNOFF_PERIOD_MAX = 11.5
SIGNOFF_IO_DELAY_MIN = 1.2
MAX_GRT_OVERFLOW = 10
MAX_GRT_WIRELENGTH = 1850000.0

RTL_COMMON = [
    "code/axi_pkg.sv",
    "code/cf_math_pkg.sv",
    "code/riscv_instr.sv",
    "code/snitch_icache_pkg.sv",
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
    "code/tc_sram_impl.sv",
    "code/snitch_icache_lfsr.sv",
    "code/snitch_icache_l0.sv",
    "code/snitch_icache_lookup.sv",
    "code/snitch_icache_handler.sv",
    "code/snitch_icache_refill.sv",
    "code/snitch_icache.sv",
    "code/snitch_icache_subsys.sv",
]


def finish(result_path, verdict: str, stage: str, detail: str, metrics=None):
    payload = {"verdict": verdict, "stage": stage, "detail": detail[:4000]}
    if metrics:
        payload["metrics"] = metrics
    if result_path is not None:
        result_path.parent.mkdir(parents=True, exist_ok=True)
        result_path.write_text(json.dumps(payload, indent=2) + "\n")
    print(json.dumps(payload))
    raise SystemExit(0 if verdict == "PASS" else 2 if verdict == "ERROR" else 1)


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
    text = re.sub(r"(?is)//\s*pragma\s+translate_off.*?//\s*pragma\s+translate_on", "", text)
    text = re.sub(r"/\*.*?\*/|//[^\n]*|\"(?:\\.|[^\"\\])*\"", " ", text, flags=re.S)
    return text


def screen_rtl_source(rel: pathlib.Path, mod_names: list, cand_text: str, base_text: str, result_path):
    if len(cand_text.encode("utf-8")) > 500_000:
        finish(result_path, "FAIL", "policy", f"Editable RTL {rel} exceeds size limit")

    cand_clean = strip_comments_and_strings(cand_text)
    base_clean = strip_comments_and_strings(base_text)

    escape_pats = [
        (r"\$(?:fopen|fclose|fread|fwrite|fdisplay|fscanf|system|finish|stop|fatal|readmemh|readmemb|writememh|writememb|dumpfile|dumpvars|value\$plusargs|test\$plusargs)\b", "forbidden_systask"),
        (r"\b(?:force|release|bind|defparam|deassign)\b", "procedural_force_or_bind"),
        (r"\b(?:import|export)\s*\"DPI", "dpi_escape"),
        (r"\$root\b|\b(?:tb_icache|dut|grader|ar_q|err_mode)\b", "hierarchical_harness_reference"),
        (r"`\s*(?:ifdef|ifndef|elsif)\s+(?:VERILATOR|SYNTHESIS|SIMULATION|__ICARUS__|IVERILOG|VCS|QUESTA)\b", "simulator_macro_divergence"),
    ]
    for pat, label in escape_pats:
        if len(re.findall(pat, cand_clean, re.I)) > len(re.findall(pat, base_clean, re.I)):
            finish(result_path, "FAIL", "policy", f"Policy violation in {rel}: {label}")

    for mname in mod_names:
        if len(re.findall(rf"\bmodule\s+{mname}\b", cand_clean)) != 1:
            finish(result_path, "FAIL", "structural", f"Expected module `{mname}` in {rel}")

    if "snitch_icache_lookup" in mod_names:
        if len(re.findall(r"\btc_sram_impl\b", cand_clean)) < 2:
            finish(result_path, "FAIL", "policy", "snitch_icache_lookup must retain tc_sram_impl tag/data macro wrappers")


def validate_macro_plan(plan_text: str, result_path):
    try:
        data = json.loads(plan_text)
    except Exception as e:
        finish(result_path, "FAIL", "geometry", f"Invalid JSON in plan/macro_placement.json: {e}")

    macros = data.get("macros") if isinstance(data, dict) else None
    if not isinstance(macros, list) or len(macros) != 6:
        finish(result_path, "FAIL", "geometry", "macro_placement.json must contain a 'macros' list of 6 entries")

    seen = {}
    boxes = []
    for entry in macros:
        if not isinstance(entry, dict):
            finish(result_path, "FAIL", "geometry", "Each macro entry must be a JSON object")
        raw_inst = entry.get("instance")
        inst = raw_inst.replace(r"\[", "[").replace(r"\]", "]") if isinstance(raw_inst, str) else raw_inst
        orient = entry.get("orientation")
        try:
            x = float(entry.get("x"))
            y = float(entry.get("y"))
        except Exception:
            finish(result_path, "FAIL", "geometry", f"Non-numeric coordinates for macro {inst}")
        if inst not in EXPECTED_MACROS:
            finish(result_path, "FAIL", "geometry", f"Unexpected macro instance '{inst}'")
        if inst in seen:
            finish(result_path, "FAIL", "geometry", f"Duplicate macro instance '{inst}'")
        if orient not in LEGAL_ORIENTS:
            finish(result_path, "FAIL", "geometry", f"Illegal orientation '{orient}' for {inst}")
        if (x < CORE_X0 + CORE_MARGIN or y < CORE_Y0 + CORE_MARGIN or
                x + MACRO_W > CORE_X1 - CORE_MARGIN or y + MACRO_H > CORE_Y1 - CORE_MARGIN):
            finish(result_path, "FAIL", "geometry", f"Macro {inst} at ({x}, {y}) extends outside core boundary margin")
        seen[inst] = (x, y, orient)
        boxes.append((inst, x, y, x + MACRO_W, y + MACRO_H))

    for i in range(len(boxes)):
        n1, x1a, y1a, x1b, y1b = boxes[i]
        for j in range(i + 1, len(boxes)):
            n2, x2a, y2a, x2b, y2b = boxes[j]
            ox = min(x1b + MACRO_HALO, x2b) - max(x1a - MACRO_HALO, x2a)
            oy = min(y1b + MACRO_HALO, y2b) - max(y1a - MACRO_HALO, y2a)
            if ox > 0.0 and oy > 0.0:
                finish(result_path, "FAIL", "geometry", f"Macros {n1} and {n2} violate {MACRO_HALO} um halo spacing")
    return seen


def validate_sdc(sdc_text: str, result_path):
    joined = re.sub(r"\\\s*\n", " ", sdc_text)
    forbidden_sdc = re.compile(
        r"\b(set_multicycle_path|set_max_delay|set_min_delay|set_clock_groups|"
        r"set_disable_timing|set_case_analysis|set_ideal_network|set_ideal_latency|"
        r"set_clock_latency|group_path)\b"
    )
    if forbidden_sdc.search(joined):
        finish(result_path, "FAIL", "timing", "Forbidden timing exception or override in constraints/snitch_icache.sdc")

    vars_map = {}
    has_clk = False
    has_in_dly = False
    has_out_dly = False

    for raw_line in joined.splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        for k, v in vars_map.items():
            line = line.replace("$" + k, v).replace("${" + k + "}", v)
        tokens = line.split()
        cmd = tokens[0]
        if cmd == "set" and len(tokens) == 3:
            vars_map[tokens[1]] = tokens[2]
        elif cmd == "create_clock":
            if "clk_i" not in line:
                finish(result_path, "FAIL", "timing", "create_clock must target clk_i")
            m = re.search(r"-period\s+([0-9]+(?:\.[0-9]+)?)", line)
            if not m:
                finish(result_path, "FAIL", "timing", "create_clock missing numeric -period")
            period = float(m.group(1))
            if period < 1.0 or period > SIGNOFF_PERIOD_MAX:
                finish(result_path, "FAIL", "timing", f"Clock period {period} ns violates signoff limit <= {SIGNOFF_PERIOD_MAX} ns")
            has_clk = True
        elif cmd == "set_input_delay":
            m = re.search(r"set_input_delay\s+(?:-[a-z_]+\s+)*([0-9]+(?:\.[0-9]+)?)", line)
            if not m or float(m.group(1)) < SIGNOFF_IO_DELAY_MIN:
                finish(result_path, "FAIL", "timing", f"set_input_delay must be >= {SIGNOFF_IO_DELAY_MIN} ns")
            has_in_dly = True
        elif cmd == "set_output_delay":
            m = re.search(r"set_output_delay\s+(?:-[a-z_]+\s+)*([0-9]+(?:\.[0-9]+)?)", line)
            if not m or float(m.group(1)) < SIGNOFF_IO_DELAY_MIN:
                finish(result_path, "FAIL", "timing", f"set_output_delay must be >= {SIGNOFF_IO_DELAY_MIN} ns")
            has_out_dly = True
        elif cmd == "set_false_path":
            if not re.fullmatch(r"set_false_path\s+-from\s+\[\s*get_ports\s+\{?rst_ni\}?\s*\]", line):
                finish(result_path, "FAIL", "timing", f"Only rst_ni may carry set_false_path; got: {line}")
        elif cmd in {"set_clock_uncertainty", "set_clock_transition", "set_driving_cell", "set_load"}:
            pass
        else:
            finish(result_path, "FAIL", "timing", f"Unsupported SDC command in snitch_icache.sdc: {cmd}")

    if not (has_clk and has_in_dly and has_out_dly):
        finish(result_path, "FAIL", "timing", "snitch_icache.sdc must define create_clock, set_input_delay, and set_output_delay")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--candidate", required=True)
    ap.add_argument("--seed", type=int, default=101)
    ap.add_argument("--result", default=None)
    ap.add_argument("--skip-pnr", action="store_true")
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

    for sub in ("code", "pdk"):
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
        with tempfile.TemporaryDirectory(prefix="case_25010_grade_") as td:
            work = pathlib.Path(td)
            shutil.copytree(PUB_DIR / "code", work / "code")
            shutil.copytree(PUB_DIR / "pdk", work / "pdk")
            for sub in ("plan", "constraints"):
                (work / sub).mkdir(parents=True, exist_ok=True)
            for rel, txt in cand_texts.items():
                (work / rel).write_text(txt, encoding="utf-8")

            tb_path = work / "tb_icache.sv"
            shutil.copyfile(PRIV_DIR / "tests" / "tb_icache.sv", tb_path)

            env = {
                "PATH": f"{TOOLS_DIR}/verilator-v5.038/bin:{TOOLS_DIR}/oss-cad-suite/bin:{TOOLS_DIR}/bin:/usr/bin:/bin",
                "VERILATOR_ROOT": f"{TOOLS_DIR}/verilator-v5.038/share/verilator",
                "HOME": str(work),
                "TMPDIR": str(work),
            }

            sim_bin = work / f"sim_{args.seed}.out"
            seed_hex = f"32'h{((0x25010000 ^ (args.seed * 0x9E37)) & 0xFFFFFFFF):08x}"
            comp_cmd = [
                str(VERILATOR), "--binary", "--timing", "-Wno-fatal", "-Wno-UNOPTFLAT",
                f"-DTB_SEED={seed_hex}", f"-I{work / 'code'}",
                "-top-module", "tb_icache",
                str(work / "pdk/core.v"),
                str(work / "pdk/256.v"),
                *[str(work / f) for f in RTL_COMMON],
                str(tb_path),
                "-o", str(sim_bin),
            ]
            r_comp = subprocess.run(comp_cmd, cwd=work, env=env, capture_output=True, text=True, timeout=120)
            if r_comp.returncode != 0 or not sim_bin.is_file():
                tail = (r_comp.stdout + "\n" + r_comp.stderr).strip()[-1800:]
                finish(result_path, "FAIL", "compile", f"Verilator compile failed: {tail}")

            r_sim = subprocess.run([str(sim_bin)], cwd=work, env=env, capture_output=True, text=True, timeout=120)
            sim_out = (r_sim.stdout + "\n" + r_sim.stderr).strip()
            if r_sim.returncode != 0 or "TEST_PASS" not in sim_out or "TEST_FAIL" in sim_out:
                finish(result_path, "FAIL", "functional", f"Simulation failed (seed={args.seed}): {sim_out[-1800:]}")

            macro_map = validate_macro_plan(cand_texts[pathlib.Path("plan/macro_placement.json")], result_path)
            validate_sdc(cand_texts[pathlib.Path("constraints/snitch_icache.sdc")], result_path)

            mapped_v = work / "mapped.v"
            files_str = " ".join(str(work / f) for f in (["pdk/256_stub.v"] + RTL_COMMON))
            ys_script = "\n".join([
                f"read_slang -DSYNTHESIS -I{work / 'code'} {files_str} --top snitch_icache_subsys",
                "hierarchy -check -top snitch_icache_subsys",
                "synth -noabc -top snitch_icache_subsys -flatten",
                "delete t:$scopeinfo",
                "scc -expect 0",
                f"dfflibmap -liberty {work / 'pdk/sg13g2_stdcell_typ_1p20V_25C.lib'}",
                f"abc -liberty {work / 'pdk/sg13g2_stdcell_typ_1p20V_25C.lib'}",
                "setundef -zero",
                "splitnets -ports",
                "opt_clean -purge",
                f"stat -liberty {work / 'pdk/sg13g2_stdcell_typ_1p20V_25C.lib'}",
                f"write_verilog -noattr -noexpr -nohex {mapped_v}",
            ])
            ys_file = work / "synth.ys"
            ys_file.write_text(ys_script + "\n", encoding="utf-8")
            r_syn = subprocess.run([str(YOSYS), "-m", "slang", "-s", str(ys_file)], cwd=work, env=env, capture_output=True, text=True, timeout=240)
            yout = r_syn.stdout + "\n" + r_syn.stderr
            if r_syn.returncode != 0 or not mapped_v.is_file():
                finish(result_path, "FAIL", "synthesis", f"Yosys synthesis failed: {yout[-1800:]}")
            stat_sec = yout.split("Printing statistics.")[-1] if "Printing statistics." in yout else yout
            if re.search(r"\$_DLATCH_|sg13g2_dlhr|sg13g2_dlhq|sg13g2_dllr", stat_sec):
                finish(result_path, "FAIL", "synthesis", "Inferred latches detected during Yosys synthesis")
            m_sram = re.search(r"(\d+)\s+\S+\s+RM_IHPSG13_1P_256x64_c2_bm_bist", stat_sec)
            sram_cnt = int(m_sram.group(1)) if m_sram else 0
            if sram_cnt != 6:
                finish(result_path, "FAIL", "synthesis", f"Expected 6 RM_IHPSG13_1P_256x64_c2_bm_bist macros, found {sram_cnt}")

            if args.skip_pnr or args.seed != 101:
                finish(
                    result_path,
                    "PASS",
                    "functional",
                    f"RTL functional simulation, SDC/floorplan checks, and synthesis passed for seed={args.seed}",
                    {"sram_macros": sram_cnt, "pnr_skipped": True},
                )

            place_lines = []
            for inst in sorted(macro_map.keys()):
                x, y, orient = macro_map[inst]
                or_inst = inst.replace("[", r"\[").replace("]", r"\]")
                place_lines.append(
                    "place_macro -macro_name {" + or_inst + "} -location {" + f"{x:.2f} {y:.2f}" + "} -orientation " + orient
                )

            tcl_lines = [
                "set_thread_count 2",
                f'set pdk "{work / "pdk"}"',
                "read_lef $pdk/sg13g2_tech.lef",
                "read_lef $pdk/sg13g2_stdcell.lef",
                "read_lef $pdk/256.lef",
                "read_liberty $pdk/sg13g2_stdcell_typ_1p20V_25C.lib",
                "read_liberty $pdk/256.lib",
                f'read_verilog "{mapped_v}"',
                "link_design snitch_icache_subsys",
                "initialize_floorplan -die_area {0 0 2400 1600} -core_area {50 50 2350 1550} -site CoreSite",
                "foreach layer {Metal1 Metal2 Metal3 Metal4 Metal5} {make_tracks $layer -x_offset 0 -x_pitch 0.48 -y_offset 0 -y_pitch 0.42}",
                "make_tracks TopMetal1 -x_offset 1.64 -x_pitch 3.28 -y_offset 1.64 -y_pitch 3.28",
                "make_tracks TopMetal2 -x_offset 2 -x_pitch 4 -y_offset 2 -y_pitch 4",
                *place_lines,
                "cut_rows -halo_width_x 2.0 -halo_width_y 2.0 -row_min_width 25.0",
                "add_global_connection -net VDD -inst_pattern {.*} -pin_pattern {VDD} -power",
                "add_global_connection -net VSS -inst_pattern {.*} -pin_pattern {VSS} -ground",
                "add_global_connection -net VDD -inst_pattern {.*} -pin_pattern {VDD!} -power",
                "add_global_connection -net VDD -inst_pattern {.*} -pin_pattern {VDDARRAY!} -power",
                "add_global_connection -net VSS -inst_pattern {.*} -pin_pattern {VSS!} -ground",
                "global_connect",
                "set_voltage_domain -name CORE -power VDD -ground VSS",
                "define_pdn_grid -name core -voltage_domains CORE -pins {TopMetal2}",
                "add_pdn_ring -grid core -layer {TopMetal1 TopMetal2} -widths {10 10} -spacings {5 5} -core_offsets {2 2} -add_connect",
                "add_pdn_stripe -grid core -layer Metal1 -width 0.44 -followpins -extend_to_core_ring",
                "add_pdn_stripe -grid core -layer TopMetal2 -width 6 -pitch 138 -spacing 48 -offset 40 -extend_to_core_ring",
                "add_pdn_connect -grid core -layers {Metal1 TopMetal2}",
                "define_pdn_grid -macro -cells {RM_IHPSG13_1P_256x64_c2_bm_bist} -name sram -orient {R0 R180 MY MX} -grid_over_boundary -voltage_domains {CORE} -halo {2 2}",
                "add_pdn_ring -grid sram -layer {Metal3 Metal4} -widths {2 2} -spacings {0.6 0.6} -core_offsets {2 0.6} -add_connect",
                "add_pdn_stripe -grid sram -layer TopMetal1 -width 8 -spacing 5 -pitch 60 -offset 20 -extend_to_core_ring -starts_with POWER",
                "add_pdn_connect -grid sram -layers {Metal3 Metal1}",
                "add_pdn_connect -grid sram -layers {TopMetal1 Metal3}",
                "add_pdn_connect -grid sram -layers {TopMetal1 Metal4}",
                "add_pdn_connect -grid sram -layers {TopMetal2 TopMetal1}",
                "pdngen",
                "place_pins -hor_layers Metal2 -ver_layers Metal3",
                f'source "{work / "constraints/snitch_icache.sdc"}"',
                "set_wire_rc -signal -layer Metal3",
                "set_wire_rc -clock -layer Metal3",
                "insert_tiecells sg13g2_tielo/L_LO",
                "insert_tiecells sg13g2_tiehi/L_HI",
                "repair_tie_fanout sg13g2_tielo/L_LO",
                "repair_tie_fanout sg13g2_tiehi/L_HI",
                'foreach inst [[ord::get_db_block] getInsts] { if {[[$inst getMaster] getName] eq "sg13g2_inv_1"} { replace_cell [$inst getName] sg13g2_inv_8 } }',
                "global_placement -density 0.34",
                "detailed_placement",
                "set_dont_touch [get_nets -of_objects [get_pins *u_sram*/A_DOUT*]]",
                "estimate_parasitics -placement",
                "repair_design",
                "detailed_placement",
                "clock_tree_synthesis -root_buf sg13g2_buf_8 -buf_list {sg13g2_buf_2 sg13g2_buf_4 sg13g2_buf_8} -sink_clustering_enable -sink_clustering_size 8 -sink_clustering_max_diameter 400",
                "set_propagated_clock [all_clocks]",
                "detailed_placement",
                "estimate_parasitics -placement",
                "repair_timing -setup -setup_margin 1.35 -max_buffer_percent 35",
                "repair_timing -hold -hold_margin 0.30 -max_buffer_percent 25",
                "detailed_placement",
                "check_placement -verbose",
                "global_connect",
                'puts "__PDN_BEGIN__"',
                "check_power_grid -net VDD",
                "check_power_grid -net VSS",
                'puts "__PDN_END__"',
                "set_routing_layers -signal Metal2-TopMetal1 -clock Metal2-TopMetal1",
                'puts "__GRT_BEGIN__"',
                "global_route -congestion_iterations 6 -allow_congestion -verbose",
                'puts "__GRT_END__"',
                "estimate_parasitics -global_routing",
                'puts "__STA_BEGIN__"',
                "report_wns -digits 4",
                "report_tns -digits 4",
                "report_checks -path_delay max -digits 4",
                "report_checks -path_delay min -digits 4",
                'puts "__STA_END__"',
                "exit",
            ]
            tcl_file = work / "pnr.tcl"
            tcl_file.write_text("\n".join(tcl_lines) + "\n", encoding="utf-8")

            r_or = subprocess.run([str(OPENROAD), "-exit", str(tcl_file)], cwd=work, env=env, capture_output=True, text=True, timeout=600)
            olog = r_or.stdout + "\n" + r_or.stderr
            if r_or.returncode != 0:
                finish(result_path, "FAIL", "physical", f"OpenROAD exited with error: {olog[-2000:]}")

            pdn_sec = re.search(r"__PDN_BEGIN__(.*?)__PDN_END__", olog, flags=re.S)
            pdn_txt = pdn_sec.group(1) if pdn_sec else ""
            if "All shapes on net VDD are connected" not in pdn_txt or "All shapes on net VSS are connected" not in pdn_txt or "[ERROR" in pdn_txt:
                finish(result_path, "FAIL", "physical", f"PDN connectivity check failed: {pdn_txt}")

            grt_sec = re.search(r"__GRT_BEGIN__(.*?)__GRT_END__", olog, flags=re.S)
            grt_txt = grt_sec.group(1) if grt_sec else ""
            m_ovf = re.search(r"Total\s+\d+\s+\d+\s+[\d.]+%\s+\d+\s*/\s*\d+\s*/\s*(\d+)", grt_txt)
            m_wl = re.search(r"Total wirelength:\s*([\d.]+)\s*um", grt_txt)
            if not m_ovf or not m_wl:
                finish(result_path, "FAIL", "physical", "Failed to parse OpenROAD global route congestion/wirelength report")
            ovf = int(m_ovf.group(1))
            wl = float(m_wl.group(1))

            sta_sec = re.search(r"__STA_BEGIN__(.*?)__STA_END__", olog, flags=re.S)
            sta_txt = sta_sec.group(1) if sta_sec else ""
            m_wns = re.search(r"wns\s+max\s+([-+]?[\d.]+)", sta_txt)
            m_tns = re.search(r"tns\s+max\s+([-+]?[\d.]+)", sta_txt)
            slacks = re.findall(r"([-+]?[\d.]+)\s+slack\s+\((?:MET|VIOLATED)\)", sta_txt)
            if not m_wns or len(slacks) < 2:
                finish(result_path, "FAIL", "timing", f"Failed to parse post-GRT STA report: {sta_txt[-1200:]}")

            wns = float(m_wns.group(1))
            tns = float(m_tns.group(1)) if m_tns else 0.0
            setup_slack = float(slacks[0])
            hold_slack = float(slacks[-1])

            metrics = {
                "wns_ns": wns,
                "setup_slack_ns": setup_slack,
                "tns_ns": tns,
                "hold_slack_ns": hold_slack,
                "grt_overflow": ovf,
                "grt_wirelength_um": wl,
            }

            violations = []
            if ovf > MAX_GRT_OVERFLOW:
                violations.append(f"GRT overflow {ovf} > {MAX_GRT_OVERFLOW}")
            if wl > MAX_GRT_WIRELENGTH:
                violations.append(f"GRT wirelength {wl:.0f} um > {MAX_GRT_WIRELENGTH:.0f} um")
            if wns < 0.0 or setup_slack < 0.0:
                violations.append(f"Post-GRT setup slack {min(wns, setup_slack):.4f} ns < 0.0 ns")
            if hold_slack < 0.0:
                violations.append(f"Post-GRT hold slack {hold_slack:.4f} ns < 0.0 ns")

            if violations:
                finish(result_path, "FAIL", "physical", "; ".join(violations), metrics)

            finish(
                result_path,
                "PASS",
                "physical",
                f"All RTL, synthesis, PDN, GRT (ovf={ovf}, wl={wl:.0f}um), and post-GRT STA (WNS={wns:.4f}ns, hold={hold_slack:.4f}ns) checks passed",
                metrics,
            )
    except subprocess.TimeoutExpired as exc:
        finish(result_path, "FAIL", "timeout", f"Grader step timed out: {exc}")


if __name__ == "__main__":
    main()
