#!/usr/bin/env python3
"""Private isolated grader for case_25011 (Caliptra Masked SHA-512 Side-Channel Share Integrity & Zeroize)."""
import argparse
import hashlib
import json
import pathlib
import re
import shutil
import struct
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

EDITABLE_FILES = {
    pathlib.Path('code/sha512_masked_defines_pkg.sv'): ('package', 'sha512_masked_defines_pkg'),
    pathlib.Path('code/sha512_masked_w_mem.sv'): ('module', 'sha512_masked_w_mem'),
    pathlib.Path('code/sha512_masked_core.sv'): ('module', 'sha512_masked_core'),
}

PROBE_C_SRC = r"""
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
    uint32_t op;
    uint32_t y;
    uint32_t a;
    uint32_t b;
    uint32_t s;
} CombGate;

typedef struct {
    uint32_t q;
    uint32_t d;
    uint32_t en;
    uint32_t sr;
    uint8_t  en_inv;
    uint8_t  sr_inv;
    uint8_t  sr_val;
    uint8_t  sr_ce;
    uint8_t  init_val;
    uint8_t  pad[3];
} SeqCell;

static uint64_t xorshift64s(uint64_t *st) {
    uint64_t x = *st;
    x ^= x << 13;
    x ^= x >> 7;
    x ^= x << 17;
    *st = x;
    return x * 0x2545F4914F6CDD1DULL;
}

static void eval_comb(const CombGate *comb, uint32_t n_comb, uint64_t *vals) {
    for (uint32_t i = 0; i < n_comb; i++) {
        const CombGate *g = &comb[i];
        uint64_t a = vals[g->a];
        uint64_t b = vals[g->b];
        uint64_t y;
        switch (g->op) {
            case 0: y = ~a; break;
            case 1: y = a & b; break;
            case 2: y = a | b; break;
            case 3: y = a ^ b; break;
            case 4: y = ~(a & b); break;
            case 5: y = ~(a | b); break;
            case 6: y = ~(a ^ b); break;
            case 7: y = a & ~b; break;
            case 8: y = a | ~b; break;
            case 9: { uint64_t s = vals[g->s]; y = (~s & a) | (s & b); break; }
            default: y = a; break;
        }
        vals[g->y] = y;
    }
}

static void step_seq(const SeqCell *seq, uint32_t n_seq, uint64_t *vals, uint64_t *next_q) {
    for (uint32_t i = 0; i < n_seq; i++) {
        const SeqCell *f = &seq[i];
        uint64_t qv = vals[f->q];
        uint64_t dv = vals[f->d];
        uint64_t ev = vals[f->en];
        if (f->en_inv) ev = ~ev;
        uint64_t sv = vals[f->sr];
        if (f->sr != 0) {
            if (f->sr_inv) sv = ~sv;
        } else {
            sv = 0ULL;
        }
        uint64_t rv = f->sr_val ? ~0ULL : 0ULL;
        uint64_t nq;
        if (f->sr != 0) {
            if (f->sr_ce) {
                uint64_t rst_take = sv & ev;
                uint64_t dat_take = (~sv) & ev;
                nq = (rst_take & rv) | (dat_take & dv) | ((~ev) & qv);
            } else {
                uint64_t dat_take = (~sv) & ev;
                uint64_t hold_take = (~sv) & (~ev);
                nq = (sv & rv) | (dat_take & dv) | (hold_take & qv);
            }
        } else {
            nq = (ev & dv) | ((~ev) & qv);
        }
        next_q[i] = nq;
    }
    for (uint32_t i = 0; i < n_seq; i++) {
        vals[seq[i].q] = next_q[i];
    }
}

int main(int argc, char **argv) {
    if (argc < 4) return 2;
    FILE *fp = fopen(argv[1], "rb");
    if (!fp) return 2;
    uint64_t base_seed = strtoull(argv[2], NULL, 10);
    int correlated = atoi(argv[3]);

    uint32_t hdr[8];
    if (fread(hdr, sizeof(uint32_t), 8, fp) != 8) return 2;
    uint32_t n_nets      = hdr[0];
    uint32_t n_comb      = hdr[1];
    uint32_t n_seq       = hdr[2];
    uint32_t net_clk     = hdr[3];
    uint32_t net_rst_n   = hdr[4];
    uint32_t net_zeroize = hdr[5];
    uint32_t net_init    = hdr[6];
    uint32_t net_next    = hdr[7];

    uint32_t hdr2[4];
    if (fread(hdr2, sizeof(uint32_t), 4, fp) != 4) return 2;
    uint32_t net_mode0   = hdr2[0];
    uint32_t net_mode1   = hdr2[1];
    uint32_t net_ready   = hdr2[2];
    uint32_t net_dvalid  = hdr2[3];

    uint32_t ent_nets[192];
    uint32_t msg_nets[1024];
    uint8_t *is_input = (uint8_t *)calloc(n_nets, 1);
    if (fread(ent_nets, sizeof(uint32_t), 192, fp) != 192) return 2;
    if (fread(msg_nets, sizeof(uint32_t), 1024, fp) != 1024) return 2;
    if (fread(is_input, 1, n_nets, fp) != n_nets) return 2;

    CombGate *comb = (CombGate *)malloc(sizeof(CombGate) * (n_comb ? n_comb : 1));
    SeqCell  *seq  = (SeqCell  *)malloc(sizeof(SeqCell)  * (n_seq  ? n_seq  : 1));
    if (n_comb && fread(comb, sizeof(CombGate), n_comb, fp) != n_comb) return 2;
    if (n_seq  && fread(seq,  sizeof(SeqCell),  n_seq,  fp) != n_seq)  return 2;
    fclose(fp);

    uint64_t msg0[16], msg1[16], msg_b2[16];
    uint64_t msg_rng = 0x9E3779B97F4A7C15ULL ^ (base_seed * 0xBF58476D1CE4E5B9ULL);
    if (!msg_rng) msg_rng = 1ULL;
    for (int i = 0; i < 16; i++) msg0[i]   = xorshift64s(&msg_rng);
    for (int i = 0; i < 16; i++) msg1[i]   = xorshift64s(&msg_rng);
    for (int i = 0; i < 16; i++) msg_b2[i] = xorshift64s(&msg_rng);
    msg1[0] ^= 0x1ULL;

    uint64_t *v0 = (uint64_t *)calloc(n_nets, sizeof(uint64_t));
    uint64_t *v1 = (uint64_t *)calloc(n_nets, sizeof(uint64_t));
    uint64_t *nq = (uint64_t *)malloc(sizeof(uint64_t) * (n_seq ? n_seq : 1));

    v0[0] = 0ULL; v0[1] = ~0ULL;
    v1[0] = 0ULL; v1[1] = ~0ULL;
    for (uint32_t i = 0; i < n_seq; i++) {
        uint64_t iv = seq[i].init_val ? ~0ULL : 0ULL;
        v0[seq[i].q] = iv;
        v1[seq[i].q] = iv;
    }

    uint64_t rng0 = 0xD1B54A32D192ED03ULL ^ (base_seed + 17ULL);
    uint64_t rng1 = 0x94D049BB133111EBULL ^ (base_seed + 991ULL);
    if (!rng0) rng0 = 3ULL;
    if (!rng1) rng1 = 7ULL;

    int issued_next = 0;
    uint32_t leak_count = 0;
    uint32_t first_cyc = 0;
    uint32_t first_net = 0;

    // Run 110 cycles: Block 1 (init_cmd -> CTRL_RND -> CTRL_ROUNDS -> CTRL_DONE)
    // followed immediately by Block 2 (next_cmd -> CTRL_RND -> early CTRL_ROUNDS)
    // so chaining registers H0..H7 are also probed while digest_valid == 0!
    for (uint32_t cyc = 0; cyc < 110; cyc++) {
        int do_init = (cyc == 0);
        int do_next = 0;
        if (cyc > 5 && !issued_next && v0[net_ready] == ~0ULL && v1[net_ready] == ~0ULL) {
            do_next = 1;
            issued_next = 1;
        }

        v0[net_clk] = 0ULL;     v1[net_clk] = 0ULL;
        v0[net_rst_n] = ~0ULL;  v1[net_rst_n] = ~0ULL;
        v0[net_zeroize] = 0ULL; v1[net_zeroize] = 0ULL;
        v0[net_init] = do_init ? ~0ULL : 0ULL;
        v1[net_init] = do_init ? ~0ULL : 0ULL;
        v0[net_next] = do_next ? ~0ULL : 0ULL;
        v1[net_next] = do_next ? ~0ULL : 0ULL;
        v0[net_mode0] = ~0ULL;  v1[net_mode0] = ~0ULL;
        v0[net_mode1] = ~0ULL;  v1[net_mode1] = ~0ULL;

        for (int b = 0; b < 1024; b++) {
            uint64_t b0 = 0ULL, b1 = 0ULL;
            if (do_init) {
                b0 = ((msg0[b >> 6] >> (b & 63)) & 1ULL) ? ~0ULL : 0ULL;
                b1 = ((msg1[b >> 6] >> (b & 63)) & 1ULL) ? ~0ULL : 0ULL;
            } else if (do_next) {
                uint64_t bv = ((msg_b2[b >> 6] >> (b & 63)) & 1ULL) ? ~0ULL : 0ULL;
                b0 = bv; b1 = bv;
            }
            v0[msg_nets[b]] = b0;
            v1[msg_nets[b]] = b1;
        }

        if (correlated) {
            uint64_t w0[64], w1[64];
            for (int i = 0; i < 64; i++) {
                w0[i] = xorshift64s(&rng0);
                w1[i] = xorshift64s(&rng1);
            }
            for (int t = 0; t < 3; t++) {
                for (int i = 0; i < 64; i++) {
                    v0[ent_nets[t * 64 + i]] = w0[i];
                    v1[ent_nets[t * 64 + i]] = w1[i];
                }
            }
        } else {
            for (int i = 0; i < 192; i++) {
                v0[ent_nets[i]] = xorshift64s(&rng0);
                v1[ent_nets[i]] = xorshift64s(&rng1);
            }
        }

        eval_comb(comb, n_comb, v0);
        eval_comb(comb, n_comb, v1);

        if (v0[net_dvalid] == 0ULL && v1[net_dvalid] == 0ULL) {
            for (uint32_t n = 2; n < n_nets; n++) {
                if (is_input[n]) continue;
                uint64_t x0 = v0[n];
                if (x0 == 0ULL || x0 == ~0ULL) {
                    uint64_t x1 = v1[n];
                    if ((x0 == 0ULL && x1 == ~0ULL) || (x0 == ~0ULL && x1 == 0ULL)) {
                        if (leak_count == 0) {
                            first_cyc = cyc;
                            first_net = n;
                        }
                        leak_count++;
                    }
                }
            }
        }

        step_seq(seq, n_seq, v0, nq);
        step_seq(seq, n_seq, v1, nq);
    }

    printf("LEAKS=%u FIRST_CYC=%u FIRST_NET=%u\n", leak_count, first_cyc, first_net);
    free(is_input); free(comb); free(seq); free(v0); free(v1); free(nq);
    return (leak_count == 0) ? 0 : 1;
}
"""


def finish(result_path: pathlib.Path, verdict: str, stage: str, detail: str):
    payload = {
        'verdict': verdict,
        'stage': stage,
        'detail': detail,
    }
    result_path.parent.mkdir(parents=True, exist_ok=True)
    result_path.write_text(json.dumps(payload, indent=2) + '\n', encoding='utf-8')
    print(json.dumps(payload))
    raise SystemExit(0 if verdict == 'PASS' else 2 if verdict == 'ERROR' else 1)


def sha256_bytes(p: pathlib.Path) -> str:
    return hashlib.sha256(p.read_bytes()).hexdigest()


def strip_comments_and_strings(text: str) -> str:
    text = re.sub(r'(?is)//\s*pragma\s+translate_off.*?//\s*pragma\s+translate_on', '', text)
    text = re.sub(r'/\*.*?\*/|//[^\n]*|"(?:\\.|[^"\\])*"', ' ', text, flags=re.S)
    return text


def screen_candidate_source(
    rel: pathlib.Path,
    kind: str,
    decl_name: str,
    cand_text: str,
    base_text: str,
    result_path: pathlib.Path,
):
    if len(cand_text.encode('utf-8')) > 250_000:
        finish(result_path, 'FAIL', 'policy', f'Editable RTL {rel} exceeds size limit')

    cand_clean = strip_comments_and_strings(cand_text)
    base_clean = strip_comments_and_strings(base_text)

    escape_pats = [
        (r'\$(?:fopen|fclose|fread|fwrite|fdisplay|fscanf|system|finish|stop|fatal|readmemh|readmemb|writememh|writememb|dumpfile|dumpvars|value\$plusargs|test\$plusargs|urandom|random)\b', 'forbidden_systask'),
        (r'\b(?:force|release|bind|defparam)\b', 'procedural_force_or_bind'),
        (r'\b(?:import|export)\s*"DPI', 'dpi_escape'),
        (r'\$root\b|\b(?:tb|u_dut_a|u_dut_b|u_dut_c|grader|oracle|K_TBL|href|exp_dig|prng_state)\s*\.', 'hierarchical_harness_reference'),
        (r'`\s*(?:ifdef|ifndef|elsif)\s+(?:VERILATOR|SYNTHESIS|SIMULATION|__ICARUS__|VCS|QUESTA|YOSYS)\b', 'simulator_macro_divergence'),
    ]
    for pat, label in escape_pats:
        c_matches = re.findall(pat, cand_clean, re.I)
        b_matches = re.findall(pat, base_clean, re.I)
        if len(c_matches) > len(b_matches):
            finish(result_path, 'FAIL', 'policy', f'Policy violation in {rel}: {label}')

    allowed_incs = set(re.findall(r'`include\s+"([^"]+)"', base_clean))
    for inc in re.findall(r'`include\s+"([^"]+)"', cand_clean):
        if inc not in allowed_incs or '..' in inc or inc.startswith('/'):
            finish(result_path, 'FAIL', 'policy', f'Unauthorized include directive in {rel}: {inc}')

    if kind == 'package':
        if len(re.findall(rf'\bpackage\s+{re.escape(decl_name)}\b', cand_clean)) != 1 or len(re.findall(r'\bmodule\b', cand_clean)) != 0:
            finish(result_path, 'FAIL', 'structural', f'Expected package {decl_name} (and zero modules) in {rel}')
    else:
        if len(re.findall(rf'\bmodule\s+{re.escape(decl_name)}\b', cand_clean)) != 1 or len(re.findall(r'\bmodule\b', cand_clean)) != 1:
            finish(result_path, 'FAIL', 'structural', f'Expected exactly one module declaration ({decl_name}) in {rel}')


def run_gate_probing_check(netlist_json: pathlib.Path, work: pathlib.Path, env: dict, seed: int, result_path: pathlib.Path):
    data = json.loads(netlist_json.read_text(encoding='utf-8'))
    mod = data.get('modules', {}).get('sha512_masked_core')
    if not mod:
        finish(result_path, 'FAIL', 'structural', 'Top module sha512_masked_core missing after elaboration')

    ports = mod.get('ports', {})
    req_ports = {
        'clk': 1, 'reset_n': 1, 'zeroize': 1, 'init_cmd': 1, 'next_cmd': 1,
        'mode': 2, 'entropy': 192, 'block_msg': 1024,
        'ready': 1, 'digest': 512, 'digest_valid': 1,
    }
    for pname, pwidth in req_ports.items():
        if pname not in ports or len(ports[pname].get('bits', [])) != pwidth:
            finish(result_path, 'FAIL', 'structural', f'Port {pname} missing or width != {pwidth}')

    cells = mod.get('cells', {})
    for cname, c in cells.items():
        if 'DLATCH' in c.get('type', ''):
            finish(result_path, 'FAIL', 'synthesis', f'Inferred latch cell {c["type"]} ({cname})')

    # Map Yosys bit IDs -> dense indices [2 .. n_nets-1]; 0 = const 0, 1 = const 1
    net_map = {}

    def map_bit(b) -> int:
        if isinstance(b, int):
            idx = net_map.get(b)
            if idx is None:
                idx = len(net_map) + 2
                net_map[b] = idx
            return idx
        return 1 if b == '1' else 0

    for pinfo in ports.values():
        for b in pinfo['bits']:
            map_bit(b)
    for c in cells.values():
        for bits in c['connections'].values():
            for b in bits:
                map_bit(b)

    n_nets = len(net_map) + 2
    rev_net_name = {}
    for wname, winfo in mod.get('netnames', {}).items():
        for i, b in enumerate(winfo.get('bits', [])):
            if isinstance(b, int) and b in net_map:
                nid = net_map[b]
                if nid not in rev_net_name or wname.startswith(('a_reg', 'b_reg', 'e_reg', 'H', 'w_mem', 'ch', 'maj')):
                    rev_net_name[nid] = f'{wname}[{i}]' if len(winfo['bits']) > 1 else wname

    is_input = bytearray(n_nets)
    for pname, pinfo in ports.items():
        if pinfo['direction'] == 'input':
            for b in pinfo['bits']:
                if isinstance(b, int):
                    is_input[map_bit(b)] = 1

    op_codes = {
        '$_NOT_': 0, '$_AND_': 1, '$_OR_': 2, '$_XOR_': 3,
        '$_NAND_': 4, '$_NOR_': 5, '$_XNOR_': 6,
        '$_ANDNOT_': 7, '$_ORNOT_': 8, '$_MUX_': 9, '$_BUF_': 10,
    }

    comb_raw = []
    seq_cells = []
    for cname, c in cells.items():
        ct = c['type']
        conn = c['connections']
        if ct in op_codes:
            op = op_codes[ct]
            y = map_bit(conn['Y'][0])
            a = map_bit(conn['A'][0])
            b = map_bit(conn['B'][0]) if 'B' in conn else 0
            s = map_bit(conn['S'][0]) if 'S' in conn else 0
            comb_raw.append((op, y, a, b, s))
        elif 'DFF' in ct:
            q = map_bit(conn['Q'][0])
            d = map_bit(conn['D'][0])
            en = map_bit(conn['E'][0]) if 'E' in conn else 1
            en_inv = 1 if ('E' in conn and ct.endswith('N_')) else 0
            sr = 0
            sr_inv = 0
            sr_val = 0
            sr_ce = 1 if 'SDFFCE' in ct else 0
            if 'ALDFF' in ct:
                init_val = 1 if conn['AD'][0] == '1' else 0
            else:
                init_val = 1 if ('1' in ct) else 0
                if 'SDFF' in ct and 'R' in conn:
                    sr = map_bit(conn['R'][0])
                    suffix = ct.split('_')[-2]
                    sr_inv = 1 if (len(suffix) >= 2 and suffix[1] == 'N') else 0
                    sr_val = init_val
            seq_cells.append((q, d, en, sr, en_inv, sr_inv, sr_val, sr_ce, init_val))
        else:
            finish(result_path, 'FAIL', 'synthesis', f'Unsupported synthesized gate cell {ct}')

    # Topological sort of combinational gates
    driver = {g[1]: idx for idx, g in enumerate(comb_raw)}
    state = bytearray(len(comb_raw))
    comb_sorted = []
    for start_idx in range(len(comb_raw)):
        if state[start_idx] == 2:
            continue
        stack = [(start_idx, 0)]
        while stack:
            idx, phase = stack.pop()
            if phase == 1:
                state[idx] = 2
                comb_sorted.append(comb_raw[idx])
                continue
            if state[idx] == 2:
                continue
            if state[idx] == 1:
                finish(result_path, 'FAIL', 'synthesis', 'Combinational loop detected in gate netlist')
            state[idx] = 1
            stack.append((idx, 1))
            _, _, a, b, s = comb_raw[idx]
            for dep in (a, b, s):
                d_idx = driver.get(dep)
                if d_idx is not None and state[d_idx] != 2:
                    stack.append((d_idx, 0))

    bin_path = work / 'netlist.bin'
    with bin_path.open('wb') as bf:
        bf.write(struct.pack(
            '<8I',
            n_nets, len(comb_sorted), len(seq_cells),
            map_bit(ports['clk']['bits'][0]),
            map_bit(ports['reset_n']['bits'][0]),
            map_bit(ports['zeroize']['bits'][0]),
            map_bit(ports['init_cmd']['bits'][0]),
            map_bit(ports['next_cmd']['bits'][0]),
        ))
        bf.write(struct.pack(
            '<4I',
            map_bit(ports['mode']['bits'][0]),
            map_bit(ports['mode']['bits'][1]),
            map_bit(ports['ready']['bits'][0]),
            map_bit(ports['digest_valid']['bits'][0]),
        ))
        bf.write(struct.pack('<192I', *(map_bit(b) for b in ports['entropy']['bits'])))
        bf.write(struct.pack('<1024I', *(map_bit(b) for b in ports['block_msg']['bits'])))
        bf.write(bytes(is_input))
        for g in comb_sorted:
            bf.write(struct.pack('<5I', *g))
        for f in seq_cells:
            bf.write(struct.pack('<4I5B3x', *f))

    c_file = work / 'probe_eval.c'
    c_bin = work / 'probe_eval'
    c_file.write_text(PROBE_C_SRC, encoding='utf-8')
    try:
        r_cc = subprocess.run(['/usr/bin/gcc', '-O2', str(c_file), '-o', str(c_bin)],
                              cwd=work, env=env, capture_output=True, text=True, timeout=30)
    except subprocess.TimeoutExpired:
        finish(result_path, 'FAIL', 'compile', 'Probing evaluator compilation timed out')
    if r_cc.returncode != 0:
        finish(result_path, 'FAIL', 'compile', f'Probing evaluator build failed: {r_cc.stderr[-500:]}')

    for corr_flag, mode_desc in [(0, 'independent_masks'), (1, 'correlated_masks')]:
        try:
            r_pr = subprocess.run([str(c_bin), str(bin_path), str(seed), str(corr_flag)],
                                  cwd=work, env=env, capture_output=True, text=True, timeout=30)
        except subprocess.TimeoutExpired:
            finish(result_path, 'FAIL', 'functional', f'Gate-level probing check timed out ({mode_desc})')
        out = r_pr.stdout.strip()
        if r_pr.returncode != 0:
            m = re.search(r'LEAKS=(\d+)\s+FIRST_CYC=(\d+)\s+FIRST_NET=(\d+)', out)
            if m:
                leaks, fcyc, fnet = int(m.group(1)), int(m.group(2)), int(m.group(3))
                nname = rev_net_name.get(fnet, f'net_{fnet}')
                finish(
                    result_path, 'FAIL', 'functional',
                    f'First-order probing share-unmasking leak under {mode_desc}: '
                    f'{leaks} zero-variance secret-dependent gate/register events while digest_valid==0 '
                    f'(first at cycle {fcyc} on {nname})',
                )
            finish(result_path, 'FAIL', 'functional', f'Gate-level probing check failed ({mode_desc}): {out}')


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--candidate', required=True)
    ap.add_argument('--seed', type=int, default=101)
    ap.add_argument('--result', required=True)
    args, _ = ap.parse_known_args()

    result_path = pathlib.Path(args.result).resolve()
    cand_root = pathlib.Path(args.candidate)
    if cand_root.is_symlink() or not cand_root.is_dir():
        finish(result_path, 'FAIL', 'input_validation', 'Invalid or symlinked candidate directory')
    cand_root = cand_root.resolve()

    cand_sources = {}
    for rel, (kind, decl_name) in EDITABLE_FILES.items():
        if (cand_root / rel).exists():
            c_file = cand_root / rel
        elif (cand_root / rel.name).exists():
            c_file = cand_root / rel.name
        else:
            finish(result_path, 'FAIL', 'input_validation', f'Missing editable file {rel}')

        if c_file.is_symlink() or not c_file.is_file() or not c_file.resolve().is_relative_to(cand_root):
            finish(result_path, 'FAIL', 'input_validation', f'Invalid or symlinked candidate file {rel}')

        c_text = c_file.read_text(encoding='utf-8', errors='replace')
        b_text = (PUB_DIR / rel).read_text(encoding='utf-8')
        screen_candidate_source(rel, kind, decl_name, c_text, b_text, result_path)
        cand_sources[rel] = c_text

    if (cand_root / 'code').is_dir():
        for ref_file in sorted((PUB_DIR / 'code').rglob('*')):
            if not ref_file.is_file():
                continue
            rel = ref_file.relative_to(PUB_DIR)
            if rel in EDITABLE_FILES:
                continue
            c_file = cand_root / rel
            if c_file.exists():
                if c_file.is_symlink() or not c_file.is_file() or sha256_bytes(c_file) != sha256_bytes(ref_file):
                    finish(result_path, 'FAIL', 'policy', f'Protected read-only file modified: {rel}')

    try:
        with tempfile.TemporaryDirectory(prefix='case_25011_grade_') as td:
            work = pathlib.Path(td)
            code_dir = work / 'code'
            shutil.copytree(PUB_DIR / 'code', code_dir)
            for rel, c_text in cand_sources.items():
                (work / rel).write_text(c_text, encoding='utf-8')
            shutil.copyfile(PRIV_DIR / 'tests' / 'tb.sv', work / 'tb.sv')

            env = {
                'PATH': f'{TOOLS_DIR}/verilator-v5.038/bin:{TOOLS_DIR}/oss-cad-suite/bin:/usr/bin:/bin',
                'HOME': str(work),
                'TMPDIR': str(work),
                'CC': '/usr/bin/gcc',
                'CXX': '/usr/bin/g++',
            }

            # Stage 1: Yosys-Slang synthesis, zero-latch, zero-SCC loop check & gate netlist export
            netlist_json = work / 'netlist.json'
            ys_script = (
                f'read_slang -DSYNTHESIS --top sha512_masked_core -I{code_dir} '
                f'{code_dir}/sha512_masked_defines_pkg.sv '
                f'{code_dir}/sha512_h_constants.v {code_dir}/sha512_k_constants.v '
                f'{code_dir}/sha512_masked_w_mem.sv {code_dir}/sha512_masked_core.sv; '
                f'proc; flatten; memory; opt_clean; check -assert; scc -expect 0; '
                f'techmap; simplemap; opt_clean; write_json {netlist_json}'
            )
            try:
                r_ys = subprocess.run([str(YOSYS), '-m', 'slang', '-p', ys_script],
                                      cwd=work, env=env, capture_output=True, text=True, timeout=90)
            except subprocess.TimeoutExpired:
                finish(result_path, 'FAIL', 'synthesis', 'Yosys synthesis timed out')
            ys_out = (r_ys.stdout + '\n' + r_ys.stderr)
            if r_ys.returncode != 0 or not netlist_json.is_file():
                finish(result_path, 'FAIL', 'synthesis',
                       f'Yosys synthesis / loop check failed: {ys_out[-1200:]}')
            if re.search(r'\$dlatch|\$_DLATCH_', ys_out):
                finish(result_path, 'FAIL', 'synthesis', 'Inferred latch detected during synthesis')

            # Stage 2: 64-stream parallel gate-level first-order probing check
            run_gate_probing_check(netlist_json, work, env, args.seed, result_path)

            # Stage 3: Verilator multi-mode, handshake, share-refresh & zeroize simulation
            cmd_comp = [
                str(VERILATOR),
                '--binary', '--timing', '-Wno-fatal', '-DSYNTHESIS', '-j', '2',
                f'-I{code_dir}',
                '--top-module', 'tb',
                '--Mdir', str(work / 'obj'),
                str(code_dir / 'sha512_masked_defines_pkg.sv'),
                str(code_dir / 'sha512_h_constants.v'),
                str(code_dir / 'sha512_k_constants.v'),
                str(code_dir / 'sha512_masked_w_mem.sv'),
                str(code_dir / 'sha512_masked_core.sv'),
                str(work / 'tb.sv'),
            ]
            try:
                r_comp = subprocess.run(cmd_comp, cwd=work, env=env, capture_output=True, text=True, timeout=180)
            except subprocess.TimeoutExpired:
                finish(result_path, 'FAIL', 'compile', 'Verilator compilation timed out')

            if r_comp.returncode != 0 or not (work / 'obj' / 'Vtb').is_file():
                tail = (r_comp.stdout + '\n' + r_comp.stderr).strip()[-1500:]
                finish(result_path, 'FAIL', 'compile', f'Verilator compile failed: {tail}')

            try:
                r_sim = subprocess.run([str(work / 'obj' / 'Vtb'), f'+SEED={args.seed}'],
                                       cwd=work, env=env, capture_output=True, text=True, timeout=90)
            except subprocess.TimeoutExpired:
                finish(result_path, 'FAIL', 'functional', f'Simulation timed out (seed={args.seed})')

            sim_out = (r_sim.stdout + '\n' + r_sim.stderr).strip()
            if r_sim.returncode != 0 or f'TB_RESULT: PASS (seed={args.seed})' not in sim_out:
                finish(result_path, 'FAIL', 'functional', f'Simulation failed (seed={args.seed}): {sim_out[-1500:]}')

            finish(
                result_path, 'PASS', 'functional',
                f'Passed Yosys-Slang zero-SCC synthesis, 64-stream gate-level first-order probing, '
                f'and FIPS 180-4 multi-mode/share-refresh/zeroize verification (seed={args.seed})',
            )
    except OSError as exc:
        finish(result_path, 'ERROR', 'environment', f'OS error: {exc}')


if __name__ == '__main__':
    main()
