#!/usr/bin/env python3
"""Private isolated grader for case_20009 (axi_llc 2-way multi-corner native SDC + hard-SRAM STA)."""
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
PRIV_DIR = TASK_DIR / "private"
PUB_DIR = TASK_DIR / "public"
TOOLS_DIR = pathlib.Path(str(_sb_tools_dir()))
VERILATOR = TOOLS_DIR / "verilator-v5.038" / "bin" / "verilator"
YOSYS = TOOLS_DIR / "oss-cad-suite" / "bin" / "yosys"
SIMCELLS = TOOLS_DIR / "oss-cad-suite" / "share" / "yosys" / "simcells.v"
OPENROAD = TOOLS_DIR / "bin" / "openroad"

EDITABLE_SV = [
    pathlib.Path("code/rtl/axi_llc_top.sv"),
    pathlib.Path("code/rtl/axi_llc_chan_splitter.sv"),
    pathlib.Path("code/rtl/axi_llc_tag_store.sv"),
    pathlib.Path("code/rtl/axi_llc_data_way.sv"),
]
EDITABLE_ALL = [pathlib.Path("constraints/axi_llc.sdc"), *EDITABLE_SV]


def finish(result_path: pathlib.Path, verdict: str, stage: str, detail: str):
    payload = {"verdict": verdict, "stage": stage, "detail": detail}
    result_path.parent.mkdir(parents=True, exist_ok=True)
    result_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
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


def strip_sv(text: str) -> str:
    text = assertion_only_blocks(constant_initials(benign_directives(text)))
    text = mask_assertions(text)
    text = re.sub(r'(?is)//\s*pragma\s+translate_off.*?//\s*pragma\s+translate_on', '', text)
    return re.sub(r'/\*.*?\*/|//[^\n]*|"(?:\\.|[^"\\])*"', ' ', text, flags=re.S)


def screen_sources_and_sdc(cand_root: pathlib.Path, result_path: pathlib.Path):
    for rel in EDITABLE_SV:
        ct = (cand_root / rel).read_text(encoding="utf-8", errors="replace")
        bt = (PUB_DIR / rel).read_text(encoding="utf-8", errors="replace")
        if len(ct) > 250_000:
            finish(result_path, "FAIL", "policy", f"{rel} exceeds size limit")
        cc, bc = strip_sv(ct), strip_sv(bt)
        pats = [
            (r'\$(?:fopen|fclose|fread|fwrite|fdisplay|fscanf|system|finish|stop|readmemh|readmemb|writememh|writememb|dumpfile|dumpvars|value\$plusargs|test\$plusargs)\b', "forbidden_systask"),
            (r'\b(?:force|release|bind|defparam)\b', "procedural_force_or_bind"),
            (r'\b(?:import|export)\s*"DPI', "dpi_escape"),
            (r'\$root\b|\b(?:tb|u_dut|grader|oracle)\s*\.', "hierarchical_harness_reference"),
            (r'`\s*(?:ifdef|ifndef|elsif)\s+(?:VERILATOR|SYNTHESIS|SIMULATION|__ICARUS__|VCS|QUESTA)\b', "simulator_macro_divergence"),
        ]
        for pat, lbl in pats:
            if len(re.findall(pat, cc, re.I)) > len(re.findall(pat, bc, re.I)):
                finish(result_path, "FAIL", "policy", f"Policy violation in {rel}: {lbl}")
        if len(re.findall(rf'\bmodule\s+{rel.stem}\b', cc)) != 1:
            finish(result_path, "FAIL", "structural", f"Expected single module {rel.stem} in {rel}")

    sdc_raw = (cand_root / "constraints/axi_llc.sdc").read_text(encoding="utf-8", errors="replace")
    if len(sdc_raw) > 50_000:
        finish(result_path, "FAIL", "policy", "constraints/axi_llc.sdc exceeds size limit")
    sdc = expand_tcl_vars(sdc_raw)
    bad_tcl = [
        (r'\b(?:exec|open|socket|source|load|interp|package|file\s+(?:delete|copy|rename|mkdir)|exit)\b', "forbidden_tcl_cmd"),
        (r'\.\.|/tmp/|/tests/|/private/|/root/|/home/', "forbidden_path_escape"),
        (r'\b(?:set_multicycle_path|set_disable_timing|set_case_analysis|set_ideal_network|create_generated_clock|group_path|set_max_delay|set_min_delay)\b', "forbidden_sdc_exception"),
        (r'\b(?:repair_timing|repair_design|read_liberty|read_verilog|write_verilog)\b', "forbidden_flow_cmd_in_sdc"),
    ]
    for pat, lbl in bad_tcl:
        if re.search(pat, sdc):
            finish(result_path, "FAIL", "policy", f"Disallowed construct in axi_llc.sdc: {lbl}")

    # Verify required numeric bounds in constraints/axi_llc.sdc (fail under substantive stage 'timing')
    def req_vals(pattern: str):
        return [float(x) for x in re.findall(pattern, sdc)]

    su_unc = req_vals(r'set_clock_uncertainty[^\n;]*?-setup\s+([+-]?\d+(?:\.\d+)?)')
    hd_unc = req_vals(r'set_clock_uncertainty[^\n;]*?-hold\s+([+-]?\d+(?:\.\d+)?)')
    clk_tr = req_vals(r'set_clock_transition\s+(?:-[a-z]+\s+)*([+-]?\d+(?:\.\d+)?)')
    in_max = req_vals(r'set_input_delay[^\n;]*?-max\s+([+-]?\d+(?:\.\d+)?)')
    in_min = req_vals(r'set_input_delay[^\n;]*?-min\s+([+-]?\d+(?:\.\d+)?)')
    out_max = req_vals(r'set_output_delay[^\n;]*?-max\s+([+-]?\d+(?:\.\d+)?)')
    out_min = req_vals(r'set_output_delay[^\n;]*?-min\s+([+-]?\d+(?:\.\d+)?)')
    loads = req_vals(r'set_load\s+(?:-[a-z_]+\s+)*([+-]?\d+(?:\.\d+)?)')
    fouts = req_vals(r'set_max_fanout\s+([+-]?\d+(?:\.\d+)?)')
    slews = req_vals(r'set_max_transition\s+([+-]?\d+(?:\.\d+)?)')
    if not su_unc or min(su_unc) < 0.1499 or not hd_unc or min(hd_unc) < 0.0799:
        finish(result_path, "FAIL", "timing", "SDC missing setup (>=0.15) or hold (>=0.08) clock uncertainty")
    if not clk_tr or min(clk_tr) < 0.0999:
        finish(result_path, "FAIL", "timing", "SDC missing set_clock_transition >= 0.10")
    if not re.search(r'set_driving_cell[^\n;]*?-lib_cell\s+sg13g2_buf_4\b', sdc):
        finish(result_path, "FAIL", "timing", "SDC missing set_driving_cell -lib_cell sg13g2_buf_4")
    if not in_max or min(in_max) < 1.7999 or not in_min or max(in_min) > 0.2001:
        finish(result_path, "FAIL", "timing", "SDC input_delay violates max>=1.80 or min<=0.20")
    if not out_max or min(out_max) < 1.7999 or not out_min or max(out_min) > 0.0501:
        finish(result_path, "FAIL", "timing", "SDC output_delay violates max>=1.80 or min<=0.05")
    if not loads or min(loads) < 0.0249:
        finish(result_path, "FAIL", "timing", "SDC set_load must be >= 0.025")
    if not fouts or max(fouts) > 16.001 or not slews or max(slews) > 0.4001:
        finish(result_path, "FAIL", "timing", "SDC missing set_max_fanout <= 16 or set_max_transition <= 0.40")

    lat_lines = [m.group(0) for m in re.finditer(r'set_clock_latency[^\n;]+', sdc)]
    if not lat_lines:
        finish(result_path, "FAIL", "timing", "SDC missing macro A_CLK set_clock_latency in [-0.50, -0.45]")
    for ll in lat_lines:
        if "-source" in ll or "A_CLK" not in ll or "i_cut" not in ll:
            finish(result_path, "FAIL", "timing", f"Invalid set_clock_latency target in SDC: {ll.strip()}")
        nums = [float(x) for x in re.findall(r'(?<![A-Za-z0-9_])([+-]?\d+(?:\.\d+)?)', ll)]
        if not nums or any(v < -0.5001 or v > -0.4499 for v in nums):
            finish(result_path, "FAIL", "timing", f"set_clock_latency value outside [-0.50, -0.45]: {ll.strip()}")

    for fp in [m.group(0) for m in re.finditer(r'set_false_path[^\n;]+', sdc)]:
        if re.search(r'-(?:to|through|rise_to|fall_to)\b', fp):
            finish(result_path, "FAIL", "timing", f"Disallowed -to/-through in set_false_path: {fp.strip()}")


def sv_sources(croot: pathlib.Path) -> list[pathlib.Path]:
    cc = croot / "common_cells/src"
    ax = croot / "axi/src"
    rt = croot / "rtl"
    return [
        cc / "cb_filter_pkg.sv", cc / "cf_math_pkg.sv", ax / "axi_pkg.sv", rt / "axi_llc_pkg.sv", rt / "tc_sram.sv",
        cc / "lzc.sv", cc / "onehot_to_bin.sv", cc / "counter.sv", cc / "delta_counter.sv", cc / "fifo_v3.sv",
        cc / "rr_arb_tree.sv", cc / "shift_reg.sv", cc / "shift_reg_gated.sv", cc / "spill_register_flushable.sv",
        cc / "spill_register.sv", cc / "stream_register.sv", cc / "stream_fifo.sv", cc / "stream_demux.sv",
        cc / "stream_mux.sv", cc / "stream_arbiter_flushable.sv", cc / "stream_arbiter.sv", cc / "stream_xbar.sv",
        cc / "sub_per_hash.sv", cc / "cb_filter.sv", cc / "addr_decode_dync.sv", cc / "addr_decode.sv",
        ax / "axi_cut.sv", ax / "axi_demux_id_counters.sv", ax / "axi_demux_simple.sv", ax / "axi_demux.sv",
        ax / "axi_id_prepend.sv", ax / "axi_atop_filter.sv", ax / "axi_mux.sv", ax / "axi_isolate.sv",
        rt / "axi_llc_burst_cutter.sv", rt / "axi_llc_data_way.sv", rt / "axi_llc_merge_unit.sv",
        rt / "axi_llc_read_unit.sv", rt / "axi_llc_write_unit.sv", rt / "axi_llc_ax_master.sv",
        rt / "axi_llc_r_master.sv", rt / "axi_llc_w_master.sv", rt / "axi_llc_evict_box.sv",
        rt / "axi_llc_lock_box_bloom.sv", rt / "axi_llc_miss_counters.sv", rt / "axi_llc_tag_pattern_gen.sv",
        rt / "axi_llc_chan_splitter.sv", rt / "axi_llc_evict_unit.sv", rt / "axi_llc_refill_unit.sv",
        rt / "axi_llc_ways.sv", rt / "axi_llc_tag_store.sv", rt / "axi_llc_config.sv",
        rt / "axi_llc_hit_miss.sv", rt / "axi_llc_top.sv", rt / "axi_llc_top_wrap.sv",
    ]


def expand_tcl_vars(sdc_text: str) -> str:
    joined = re.sub(r'\\\s*\n', ' ', re.sub(r'#[^\n]*', ' ', sdc_text))
    vars_map = {}
    for m in re.finditer(r'(?m)^\s*set\s+([A-Za-z_]\w*)\s+([^\n;]+)', joined):
        val = m.group(2).strip()
        for k, v in vars_map.items():
            val = val.replace('${' + k + '}', v).replace('$' + k, v)
        vars_map[m.group(1)] = val
    out = joined
    for _ in range(4):
        for k, v in vars_map.items():
            out = out.replace('${' + k + '}', v).replace('$' + k, v)
    return out


def check_sdc_numerics(cand_root: pathlib.Path, result_path: pathlib.Path):
    sdc = expand_tcl_vars((cand_root / "constraints/axi_llc.sdc").read_text(encoding="utf-8", errors="replace"))

    def req_vals(pattern: str):
        return [float(x) for x in re.findall(pattern, sdc)]

    su_unc = req_vals(r'set_clock_uncertainty[^\n;]*?-setup\s+([+-]?\d+(?:\.\d+)?)')
    hd_unc = req_vals(r'set_clock_uncertainty[^\n;]*?-hold\s+([+-]?\d+(?:\.\d+)?)')
    clk_tr = req_vals(r'set_clock_transition\s+(?:-[a-z]+\s+)*([+-]?\d+(?:\.\d+)?)')
    in_max = req_vals(r'set_input_delay[^\n;]*?-max\s+([+-]?\d+(?:\.\d+)?)')
    in_min = req_vals(r'set_input_delay[^\n;]*?-min\s+([+-]?\d+(?:\.\d+)?)')
    out_max = req_vals(r'set_output_delay[^\n;]*?-max\s+([+-]?\d+(?:\.\d+)?)')
    out_min = req_vals(r'set_output_delay[^\n;]*?-min\s+([+-]?\d+(?:\.\d+)?)')
    loads = req_vals(r'set_load\s+(?:-[a-z_]+\s+)*([+-]?\d+(?:\.\d+)?)')
    fouts = req_vals(r'set_max_fanout\s+([+-]?\d+(?:\.\d+)?)')
    slews = req_vals(r'set_max_transition\s+([+-]?\d+(?:\.\d+)?)')
    if not su_unc or min(su_unc) < 0.1499 or not hd_unc or min(hd_unc) < 0.0799:
        finish(result_path, "FAIL", "timing", "SDC missing setup (>=0.15) or hold (>=0.08) clock uncertainty")
    if not clk_tr or min(clk_tr) < 0.0999:
        finish(result_path, "FAIL", "timing", "SDC missing set_clock_transition >= 0.10")
    if not re.search(r'set_driving_cell[^\n;]*?-lib_cell\s+sg13g2_buf_4\b', sdc):
        finish(result_path, "FAIL", "timing", "SDC missing set_driving_cell -lib_cell sg13g2_buf_4")
    if not in_max or min(in_max) < 1.7999 or not in_min or max(in_min) > 0.2001:
        finish(result_path, "FAIL", "timing", "SDC input_delay violates max>=1.80 or min<=0.20")
    if not out_max or min(out_max) < 1.7999 or not out_min or max(out_min) > 0.0501:
        finish(result_path, "FAIL", "timing", "SDC output_delay violates max>=1.80 or min<=0.05")
    if not loads or min(loads) < 0.0249:
        finish(result_path, "FAIL", "timing", "SDC set_load must be >= 0.025")
    if not fouts or max(fouts) > 16.001 or not slews or max(slews) > 0.4001:
        finish(result_path, "FAIL", "timing", "SDC missing set_max_fanout <= 16 or set_max_transition <= 0.40")

    lat_lines = [m.group(0) for m in re.finditer(r'set_clock_latency[^\n;]+', sdc)]
    if not lat_lines:
        finish(result_path, "FAIL", "timing", "SDC missing macro A_CLK set_clock_latency in [-0.50, -0.45]")
    for ll in lat_lines:
        if "-source" in ll or "A_CLK" not in ll or "i_cut" not in ll:
            finish(result_path, "FAIL", "timing", f"Invalid set_clock_latency target in SDC: {ll.strip()}")
        nums = [float(x) for x in re.findall(r'(?<![A-Za-z0-9_])([+-]?\d+(?:\.\d+)?)', ll)]
        if not nums or any(v < -0.5001 or v > -0.4499 for v in nums):
            finish(result_path, "FAIL", "timing", f"set_clock_latency value outside [-0.50, -0.45]: {ll.strip()}")

    for fp in [m.group(0) for m in re.finditer(r'set_false_path[^\n;]+', sdc)]:
        if re.search(r'-(?:to|through|rise_to|fall_to)\b', fp):
            finish(result_path, "FAIL", "timing", f"Disallowed -to/-through in set_false_path: {fp.strip()}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--candidate", required=True)
    ap.add_argument("--result", required=True)
    ap.add_argument("--seed", type=int, default=101)
    args, _ = ap.parse_known_args()

    result_path = pathlib.Path(args.result).resolve()
    cand_root = pathlib.Path(args.candidate)
    if cand_root.is_symlink() or not cand_root.is_dir():
        finish(result_path, "FAIL", "input_validation", "Invalid candidate directory")
    cand_root = cand_root.resolve()

    if not VERILATOR.exists() or not YOSYS.exists() or not SIMCELLS.exists() or not OPENROAD.exists():
        finish(result_path, "ERROR", "environment", "Required EDA binary missing")

    edit_set = set(EDITABLE_ALL)
    for rel in EDITABLE_ALL:
        cp = cand_root / rel
        if not cp.is_file() or cp.is_symlink() or not cp.resolve().is_relative_to(cand_root):
            finish(result_path, "FAIL", "policy", f"Missing or symlinked editable file: {rel}")

    for sub in ("code", "constraints", "lib"):
        if (cand_root / sub).exists():
            for pub_p in sorted((PUB_DIR / sub).rglob("*")):
                if not pub_p.is_file():
                    continue
                rel = pub_p.relative_to(PUB_DIR)
                if rel in edit_set:
                    continue
                cand_p = cand_root / rel
                if cand_p.exists() and (cand_p.is_symlink() or sha256_bytes(cand_p) != sha256_bytes(pub_p)):
                    finish(result_path, "FAIL", "policy", f"Read-only file modified: {rel}")

    # Policy-only checks first; defer numeric SDC check until after functional & synthesis!
    for rel in EDITABLE_SV:
        ct = (cand_root / rel).read_text(encoding="utf-8", errors="replace")
        bt = (PUB_DIR / rel).read_text(encoding="utf-8", errors="replace")
        if len(ct) > 250_000:
            finish(result_path, "FAIL", "policy", f"{rel} exceeds size limit")
        cc, bc = strip_sv(ct), strip_sv(bt)
        for pat, lbl in [
            (r'\$(?:fopen|fclose|fread|fwrite|fdisplay|fscanf|system|finish|stop|readmemh|readmemb|writememh|writememb|dumpfile|dumpvars|value\$plusargs|test\$plusargs)\b', "forbidden_systask"),
            (r'\b(?:force|release|bind|defparam)\b', "procedural_force_or_bind"),
            (r'\b(?:import|export)\s*"DPI', "dpi_escape"),
            (r'\$root\b|\b(?:tb|u_dut|grader|oracle)\s*\.', "hierarchical_harness_reference"),
            (r'`\s*(?:ifdef|ifndef|elsif)\s+(?:VERILATOR|SYNTHESIS|SIMULATION|__ICARUS__|VCS|QUESTA)\b', "simulator_macro_divergence"),
        ]:
            if len(re.findall(pat, cc, re.I)) > len(re.findall(pat, bc, re.I)):
                finish(result_path, "FAIL", "policy", f"Policy violation in {rel}: {lbl}")
        if len(re.findall(rf'\bmodule\s+{rel.stem}\b', cc)) != 1:
            finish(result_path, "FAIL", "structural", f"Expected single module {rel.stem} in {rel}")

    sdc_raw = (cand_root / "constraints/axi_llc.sdc").read_text(encoding="utf-8", errors="replace")
    if len(sdc_raw) > 50_000:
        finish(result_path, "FAIL", "policy", "constraints/axi_llc.sdc exceeds size limit")
    sdc_clean = re.sub(r'#[^\n]*', ' ', sdc_raw)
    for pat, lbl in [
        (r'\b(?:exec|open|socket|source|load|interp|package|file\s+(?:delete|copy|rename|mkdir)|exit)\b', "forbidden_tcl_cmd"),
        (r'\.\.|/tmp/|/tests/|/private/|/root/|/home/', "forbidden_path_escape"),
        (r'\b(?:set_multicycle_path|set_disable_timing|set_case_analysis|set_ideal_network|create_generated_clock|group_path|set_max_delay|set_min_delay)\b', "forbidden_sdc_exception"),
        (r'\b(?:repair_timing|repair_design|read_liberty|read_verilog|write_verilog)\b', "forbidden_flow_cmd_in_sdc"),
    ]:
        if re.search(pat, sdc_clean):
            finish(result_path, "FAIL", "policy", f"Disallowed construct in axi_llc.sdc: {lbl}")

    try:
        with tempfile.TemporaryDirectory(prefix="case_20009_grade_") as td:
            wdir = pathlib.Path(td)
            for sub in ("code", "lib", "constraints"):
                shutil.copytree(PUB_DIR / sub, wdir / sub)
            for rel in EDITABLE_ALL:
                shutil.copyfile(cand_root / rel, wdir / rel)
            shutil.copyfile(PRIV_DIR / "tests/tb.sv", wdir / "tb.sv")
            shutil.copyfile(PRIV_DIR / "tests/tb_tasks.svh", wdir / "tb_tasks.svh")
            (wdir / "build").mkdir(parents=True, exist_ok=True)

            env = {
                "PATH": f"{TOOLS_DIR}/verilator-v5.038/bin:{TOOLS_DIR}/oss-cad-suite/bin:{TOOLS_DIR}/bin:/usr/bin:/bin",
                "HOME": str(wdir), "TMPDIR": str(wdir), "CC": "/usr/bin/gcc", "CXX": "/usr/bin/g++",
            }
            croot = wdir / "code"
            sv_list = sv_sources(croot)
            beh_srams = [
                wdir / "lib/SRAM_1P_behavioral_bm_bist.v",
                wdir / "lib/RM_IHPSG13_1P_64x64_c2_bm_bist.v",
                wdir / "lib/RM_IHPSG13_1P_256x64_c2_bm_bist.v",
            ]

            # 1. RTL Verilator simulation
            r_vrtl = subprocess.run([
                str(VERILATOR), "--binary", "-Wno-fatal", "--timing", "-j", "4", "-CFLAGS", "-O0",
                "-DFUNCTIONAL", "-DSYNTHESIS",
                f"-I{croot / 'common_cells/include'}", f"-I{croot / 'axi/include'}", f"-I{croot / 'include'}", f"-I{wdir}",
                "--top-module", "tb", "--Mdir", str(wdir / "obj_rtl"),
                *[str(p) for p in beh_srams], *[str(p) for p in sv_list], str(wdir / "tb.sv"),
            ], cwd=wdir, env=env, stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=120)
            if r_vrtl.returncode != 0:
                finish(result_path, "FAIL", "synthesis", f"Verilator RTL build failed:\n{(r_vrtl.stdout + r_vrtl.stderr)[-1200:]}")
            r_srtl = subprocess.run([str(wdir / "obj_rtl/Vtb"), f"+SEED={args.seed}"], cwd=wdir, env=env, stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=60)
            if r_srtl.returncode != 0 or "ALL_TESTS_PASSED" not in r_srtl.stdout:
                finish(result_path, "FAIL", "functional", f"RTL functional simulation failed:\n{(r_srtl.stdout + r_srtl.stderr)[-1200:]}")

            # 2. Yosys+slang synthesis -> llc_gl.v + llc_mapped.v
            gl_net = wdir / "build/llc_gl.v"
            mapped_net = wdir / "build/llc_mapped.v"
            buf_net = wdir / "build/llc_buffered.v"
            stubs = f"{wdir / 'lib/RM_IHPSG13_1P_64x64_c2_bm_bist_stub.v'} {wdir / 'lib/RM_IHPSG13_1P_256x64_c2_bm_bist_stub.v'}"
            std_typ = wdir / "lib/sg13g2_stdcell_typ_1p20V_25C.lib"
            ys_cmd = (
                f"read_slang --top axi_llc_top_wrap -I{croot / 'common_cells/include'} -I{croot / 'axi/include'} -I{croot / 'include'} -DSYNTHESIS "
                f"{stubs} {' '.join(str(p) for p in sv_list)}; "
                "hierarchy -check -top axi_llc_top_wrap; proc; opt_expr; check -assert; "
                "select -assert-none t:$dlatch*; synth -top axi_llc_top_wrap -flatten; "
                "design -save flat_generic; rename axi_llc_top_wrap axi_llc_top_wrap_gl; opt_clean; "
                f"write_verilog -noattr {gl_net}; design -load flat_generic; "
                f"dfflibmap -liberty {std_typ}; abc -D 2500 -liberty {std_typ}; "
                "hilomap -hicell sg13g2_tiehi L_HI -locell sg13g2_tielo L_LO; "
                "setundef -zero; splitnets -ports; opt_clean -purge; "
                f"write_verilog -noattr -noexpr {mapped_net}"
            )
            r_ys = subprocess.run([str(YOSYS), "-m", "slang", "-Q", "-T", "-p", ys_cmd], cwd=wdir, env=env, stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=150)
            if r_ys.returncode != 0 or not gl_net.is_file() or not mapped_net.is_file():
                finish(result_path, "FAIL", "synthesis", f"yosys+slang synthesis failed:\n{(r_ys.stdout + r_ys.stderr)[-1200:]}")

            # 3. Gate-level Verilator simulation
            r_vgl = subprocess.run([
                str(VERILATOR), "--binary", "-Wno-fatal", "--timing", "-j", "4", "-CFLAGS", "-O0",
                "-DFUNCTIONAL", "-DDUT_MOD=axi_llc_top_wrap_gl", f"-I{wdir}",
                "--top-module", "tb", "--Mdir", str(wdir / "obj_gl"),
                str(SIMCELLS), *[str(p) for p in beh_srams], str(gl_net), str(wdir / "tb.sv"),
            ], cwd=wdir, env=env, stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=150)
            if r_vgl.returncode != 0:
                finish(result_path, "FAIL", "synthesis", f"Gate-level build failed:\n{(r_vgl.stdout + r_vgl.stderr)[-1200:]}")
            r_sgl = subprocess.run([str(wdir / "obj_gl/Vtb"), f"+SEED={args.seed}"], cwd=wdir, env=env, stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=60)
            if r_sgl.returncode != 0 or "ALL_TESTS_PASSED" not in r_sgl.stdout:
                finish(result_path, "FAIL", "functional", f"Gate-level parity simulation failed:\n{(r_sgl.stdout + r_sgl.stderr)[-1200:]}")

            # 4. Native SDC audit + OpenROAD repair_design buffering + 3-corner (SS/TT/FF) STA
            check_sdc_numerics(cand_root, result_path)
            audit_tcl = PRIV_DIR / "grader/sta_audit.tcl"
            b_env = {**env, "MODE": "BUFFER", "CORNER_NAME": "SS", "CORNER_LIB": "lib/sg13g2_stdcell_slow_1p08V_125C.lib",
                     "NETLIST_IN": str(mapped_net), "NETLIST_OUT": str(buf_net), "SDC_FILE": "constraints/axi_llc.sdc"}
            r_buf = subprocess.run([str(OPENROAD), "-exit", str(audit_tcl)], cwd=wdir, env=b_env, stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=90)
            if r_buf.returncode != 0 or not buf_net.is_file():
                finish(result_path, "FAIL", "timing", f"OpenROAD repair_design/SDC load failed:\n{(r_buf.stdout + r_buf.stderr)[-1200:]}")

            corner_summaries = []
            for cname, clib in [
                ("SS", "lib/sg13g2_stdcell_slow_1p08V_125C.lib"),
                ("TT", "lib/sg13g2_stdcell_typ_1p20V_25C.lib"),
                ("FF", "lib/sg13g2_stdcell_fast_1p32V_m40C.lib"),
            ]:
                c_env = {**env, "MODE": "AUDIT_AND_STA", "CORNER_NAME": cname, "CORNER_LIB": clib,
                         "NETLIST_IN": str(buf_net), "NETLIST_OUT": str(buf_net), "SDC_FILE": "constraints/axi_llc.sdc"}
                r_sta = subprocess.run([str(OPENROAD), "-exit", str(audit_tcl)], cwd=wdir, env=c_env, stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=90)
                out = r_sta.stdout + "\n" + r_sta.stderr
                if r_sta.returncode != 0 or "AUDIT_FAIL" in out:
                    finish(result_path, "FAIL", "timing", f"OpenSTA audit failed in {cname}:\n{out[-1200:]}")
                if cname == "SS":
                    if "AUDIT_PASS" not in out or re.search(r'There are \d+ unconstrained endpoints', out):
                        finish(result_path, "FAIL", "timing", f"Unconstrained endpoints or failed SDC audit:\n{out[-1200:]}")
                m = re.search(rf'STA_RESULT_{cname}\s+setup_wns=([+-]?\d+\.\d+)\s+setup_tns=([+-]?\d+\.\d+)\s+hold_wns=([+-]?\d+\.\d+)\s+hold_tns=([+-]?\d+\.\d+)', out)
                if not m:
                    finish(result_path, "FAIL", "timing", f"Missing STA_RESULT_{cname}:\n{out[-800:]}")
                sw, st, hw, ht = (float(m.group(i)) for i in range(1, 5))
                corner_summaries.append(f"{cname}(su={sw:.3f},hd={hw:.3f})")
                if sw < 0.0 or st < -0.0005 or hw < 0.0 or ht < -0.0005:
                    finish(result_path, "FAIL", "timing", f"Corner {cname} failed signoff: setup_wns={sw:.4f}, setup_tns={st:.4f}, hold_wns={hw:.4f}, hold_tns={ht:.4f}")

            finish(result_path, "PASS", "all_gates", f"Passed RTL+GL co-sim (seed={args.seed}) and 3-corner STA: " + ", ".join(corner_summaries))
    except subprocess.TimeoutExpired as exc:
        finish(result_path, "FAIL", "timeout", f"Timed out: {exc}")


if __name__ == "__main__":
    main()
