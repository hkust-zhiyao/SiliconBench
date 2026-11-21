#!/usr/bin/env python3
"""Centralized Harbor Airlock & Anti-Cheat Policy Filter (tests/private/policy_filter.py).

Enforces uniform pre-grader submission validation before running tests/private/grader/run.py:
  - Rejects symlinked candidate root, parent-directory symlinks, leaf symlinks, and path escapes
  - Rejects oversized editable files (> 2 MiB)
  - Removes deleted allowlisted files when grading a full workspace (vs sparse overlay)
  - Screens SystemVerilog/Verilog edits with safety v2 sanitization + escape & translate_off checks
  - Screens .sdc/.tcl/.ys scripts for Tcl command/path escapes and .json for valid syntax
"""
import argparse
import json
import pathlib
import re
import sys

MAX_FILE_BYTES = 2 * 1024 * 1024


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

    def _chk_sim_flop(m):
        sim_b = re.sub(r'/\*.*?\*/|//[^\n]*', '', m.group(1), flags=re.S).strip()
        syn_b = re.sub(r'/\*.*?\*/|//[^\n]*', '', m.group(2), flags=re.S).strip()
        if _has_pass_banner_in_strings(m.group(0)) or re.search(r'\$|\b(?:force|release|bind|tb|dut|u_dut)\b', m.group(0)):
            return m.group(0)
        if re.match(r'^`CALIPTRA_PRIM_FLOP_SPARSE_FSM\s*\(', sim_b) and re.match(r'^always_ff\b', syn_b):
            return syn_b
        m1 = re.fullmatch(r'([A-Za-z_]\w*)\s*<=\s*([A-Za-z_]\w*)\s*;', sim_b)
        m2 = re.fullmatch(r'([A-Za-z_]\w*)\s*<=\s*([A-Za-z_]\w*)\s*;', syn_b)
        if (m1 and m2 and m1.group(1) == m2.group(1) and 'glitch' in m1.group(2)) or (
            m1 and m2 and m1.group(1) == m2.group(1) and 'state_regs_d' in m1.group(2)
        ):
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
    if 'finish' in re.findall(r'\$(\w+)', clean) and not re.search(r'\b(?:assert|assume)\b', clean):
        return False

    local_vars = set()
    for dm in re.finditer(r'\b(?:logic|wire|reg|bit|int|integer|[A-Za-z_]\w*_t)\s+(?:\[[^;]+\]\s*)?([A-Za-z_]\w*)\s*(?:=\s*[^;]+)?;', clean):
        v = dm.group(1)
        if re.search(r'\b' + re.escape(v) + r'\b', outside_clean):
            return False
        local_vars.add(v)

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
    text = _strip_stdcell_and_sparse_fsm_wrappers(text)

    pragma_wrapped = re.compile(
        r'(?is)(?:`ifndef\s+(?:VERILATOR|SYNTHESIS|YOSYS)\s*)?//\s*(?:pragma|synopsys|synthesis|cadence|verilator)\s+translate_off.*?//\s*(?:pragma|synopsys|synthesis|cadence|verilator)\s+translate_on(?:\s*`endif\b)?'
    )
    outside = re.sub(r'/\*.*?\*/|//[^\n]*', '', pragma_wrapped.sub('', text), flags=re.S)
    text = pragma_wrapped.sub(lambda m: '' if _is_readonly_diag_block(m.group(0), outside) else m.group(0), text)

    macro_blk = re.compile(
        r'`(?:ifndef\s+(?:SYNTHESIS|VERILATOR|YOSYS)|ifdef\s+SIMULATION)\b((?:(?!`(?:ifdef|ifndef|else|elsif|endif)\b).)*?)`endif\b',
        flags=re.S,
    )
    for _ in range(2):
        outside2 = re.sub(r'/\*.*?\*/|//[^\n]*', '', macro_blk.sub('', text), flags=re.S)
        text = macro_blk.sub(lambda m: '' if _is_readonly_diag_block(m.group(0), outside2) else m.group(0), text)
    return text


def sanitize_for_policy(text: str) -> str:
    return mask_assertions(constant_initials(benign_directives(_strip_comments_keep_strings(assertion_only_blocks(text)))))


def screen_hdl_escapes(new_text: str, old_text: str) -> list[str]:
    new_c = sanitize_for_policy(new_text)
    old_c = sanitize_for_policy(old_text)
    violations = []
    escape_pats = [
        (r'\$(?:fopen|fclose|fread|fwrite|fdisplay|fscanf|system|finish|stop|readmemh|readmemb|writememh|writememb|dumpfile|dumpvars|value\$plusargs|test\$plusargs)\b', 'forbidden_systask'),
        (r'\b(?:force|release|bind)\b', 'procedural_force_or_bind'),
        (r'\b(?:import|export)\s*"DPI', 'dpi_escape'),
        (r'\$root\b|\b(?:tb|grader|oracle|golden_ref)\s*\.', 'hierarchical_harness_reference'),
        (r'`\s*(?:ifdef|ifndef|elsif)\s+(?:VERILATOR|SYNTHESIS|SIMULATION|__ICARUS__|VCS|QUESTA)\b', 'simulator_or_synthesis_macro_divergence'),
    ]
    for pat, label in escape_pats:
        if len(re.findall(pat, new_c, re.I)) > len(re.findall(pat, old_c, re.I)):
            violations.append(label)
    for inc in re.findall(r'`include\s+"([^"]+)"', new_c):
        p = pathlib.PurePosixPath(inc)
        if p.is_absolute() or '..' in p.parts:
            violations.append('include_path_escape')

    clean_ro = assertion_only_blocks(new_text)
    old_ro = assertion_only_blocks(old_text)
    if len(re.findall(r'\btranslate_off\b', clean_ro, re.I)) > len(re.findall(r'\btranslate_off\b', old_ro, re.I)):
        violations.append('translate_off_escape')
    return sorted(set(violations))


def write_policy_fail(reward_json: pathlib.Path, reward_txt: pathlib.Path, cid: str, violations: list[str]):
    reason = f"Policy violation: {', '.join(violations)}"
    reward_txt.parent.mkdir(parents=True, exist_ok=True)
    reward_txt.write_text('0.0\n', encoding='utf-8')
    out = {
        'task_id': cid,
        'verdict': 'FAIL',
        'reward': 0.0,
        'score': 0.0,
        'stage': 'policy',
        'reason': reason,
        'policy_violations': violations,
        'seed_results': [],
    }
    reward_json.write_text(json.dumps(out, indent=2) + '\n', encoding='utf-8')
    print(json.dumps(out), flush=True)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument('--candidate', required=True)
    ap.add_argument('--stage', required=True)
    ap.add_argument('--baseline', required=True)
    ap.add_argument('--reward-json', required=True)
    ap.add_argument('--reward-txt', required=True)
    ap.add_argument('--task-id', required=True)
    ap.add_argument('--allowed', nargs='*', default=[])
    args = ap.parse_args()

    cand_dir = pathlib.Path(args.candidate)
    stage_dir = pathlib.Path(args.stage)
    base_dir = pathlib.Path(args.baseline)
    reward_json = pathlib.Path(args.reward_json)
    reward_txt = pathlib.Path(args.reward_txt)

    if cand_dir.is_symlink() or not cand_dir.is_dir():
        write_policy_fail(reward_json, reward_txt, args.task_id, ['candidate_dir:invalid_or_symlink'])
        return 42

    cand_resolved = cand_dir.resolve()
    is_full_workspace = any((cand_dir / m).exists() for m in ('issue.md', 'INSTRUCTION.md', 'BUILD.md', 'SOURCE.md'))
    violations = []

    for rel in args.allowed:
        rel_p = pathlib.PurePosixPath(rel)
        chosen_p = None
        if (cand_dir / rel_p).exists() or (cand_dir / rel_p).is_symlink():
            chosen_p = rel_p
        elif rel.startswith('code/'):
            alt_p = pathlib.PurePosixPath(rel[len('code/'):])
            if (cand_dir / alt_p).exists() or (cand_dir / alt_p).is_symlink():
                chosen_p = alt_p

        if chosen_p is None:
            # Check whether an intermediate parent directory is itself a symlink
            cur = cand_dir
            parent_sym = False
            for part in rel_p.parts[:-1]:
                cur = cur / part
                if cur.is_symlink():
                    parent_sym = True
                    break
            if parent_sym:
                violations.append(f'{rel}:symlink_escape')
                continue
            if is_full_workspace and (base_dir / rel_p).is_file():
                (stage_dir / rel_p).unlink(missing_ok=True)
            continue

        cur = cand_dir
        symlink_hit = False
        for part in chosen_p.parts[:-1]:
            cur = cur / part
            if cur.is_symlink():
                symlink_hit = True
                break
        target = cand_dir / chosen_p
        if symlink_hit or target.is_symlink():
            violations.append(f'{rel}:symlink_escape')
            continue

        try:
            target_res = target.resolve()
            if not target_res.is_relative_to(cand_resolved):
                violations.append(f'{rel}:path_escape')
                continue
        except OSError:
            violations.append(f'{rel}:path_escape')
            continue

        if not target.is_file():
            violations.append(f'{rel}:not_a_regular_file')
            continue

        if target.stat().st_size > MAX_FILE_BYTES:
            violations.append(f'{rel}:oversized_file')
            continue

        bfile = base_dir / rel_p
        if not bfile.is_file() and (base_dir / 'code' / rel_p).is_file():
            bfile = base_dir / 'code' / rel_p
        before = bfile.read_bytes() if bfile.is_file() else b''
        after = target.read_bytes()

        if after != before:
            after_txt = after.decode('utf-8', 'replace')
            before_txt = before.decode('utf-8', 'replace')
            ext = target.suffix.lower()
            if ext in {'.sv', '.v', '.svh', '.vh'}:
                for v in screen_hdl_escapes(after_txt, before_txt):
                    violations.append(f'{rel}:{v}')
            elif ext in {'.tcl', '.sdc', '.ys'}:
                for bad in (
                    r'(?m)(?:^|[;\[])\s*(?:exec|open|socket|source|load|eval|interp)\b',
                    r'\b(?:private/gold|private/tests|private/grader|/proc/|/dev/|/tests/|/private/).*',
                ):
                    if len(re.findall(bad, after_txt)) > len(re.findall(bad, before_txt)):
                        violations.append(f'{rel}:script_escape')
            elif ext == '.json':
                try:
                    json.loads(after_txt)
                except Exception:
                    violations.append(f'{rel}:malformed_json')

        dst_file = stage_dir / rel_p
        dst_file.parent.mkdir(parents=True, exist_ok=True)
        if dst_file.exists():
            try:
                dst_file.chmod(0o644)
            except OSError:
                pass
        dst_file.write_bytes(after)

    if violations:
        write_policy_fail(reward_json, reward_txt, args.task_id, sorted(set(violations)))
        return 42
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
