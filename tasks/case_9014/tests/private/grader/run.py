#!/usr/bin/env python3
"""Trusted isolated grader for case_9014:
Co-design of four-cluster BlackParrot I-Cache SRAM byte-reverse/XOR low-to-high relay (code/banked.sv)
and 8-macro floorplan/orientation for propagated CTS latency spread and global-route timing closure (plan/placement.json).
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


P = pathlib.Path(__file__).resolve().parents[1]
TASK_DIR = P.parent
PUB = TASK_DIR / 'public'
TOOLS = pathlib.Path(str(_sb_tools_dir()))
YOSYS = TOOLS / 'oss-cad-suite/bin/yosys'
OPENROAD = TOOLS / 'bin/openroad'
IVERILOG_BIN = TOOLS / 'iverilog-v13/bin'
PDK = P / 'pdk'
FIX = P / 'fixed'

EDITABLE_RTL = 'code/banked.sv'
EDITABLE_PLAN = 'plan/placement.json'


def done(result_path: pathlib.Path, verdict: str, message: str, stage: str, **metrics):
    result = {'verdict': verdict, 'message': message, 'stage': stage, **metrics}
    result_path.parent.mkdir(parents=True, exist_ok=True)
    result_path.write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result))
    raise SystemExit(0 if verdict == 'PASS' else 1 if verdict == 'FAIL' else 2)


def sha256_bytes(b: bytes) -> str:
    return hashlib.sha256(b).hexdigest()


def strip_comments_and_strings(src: str) -> str:
    return re.sub(r'//[^\n]*|/\*[\s\S]*?\*/|"(?:\\.|[^"\\])*"', lambda m: ' ' * len(m.group(0)), src)


def check_rtl_policy(rtl_text: str) -> str | None:
    if len(rtl_text) > 200_000:
        return 'RTL file exceeds size limit'
    body = strip_comments_and_strings(rtl_text)
    if re.search(
        r'\b(?:force|release|bind|import\s+"DPI|export\s+"DPI)\b'
        r'|\$(?:fopen|fclose|fread|fwrite|fdisplay|fscanf|readmemh|readmemb|writememh|writememb'
        r'|system|finish|stop|fatal|error|warning|display|monitor|dumpfile|dumpvars|root|unit'
        r'|value\$plusargs|test\$plusargs|urandom|random)\b'
        r'|\b(?:tb|grader|oracle|ref_mem|ref_dout)\s*\.',
        body,
        re.I,
    ):
        return 'forbidden simulator escape or hierarchical reference'
    if re.search(r'`\s*(?:ifdef|ifndef|elsif)\s+(?:VERILATOR|SYNTHESIS|SIMULATION|VCS|QUESTA|__ICARUS__)\b', body, re.I) or re.search(r'`include\b', body):
        return 'forbidden conditional macro split or file include'
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--candidate', required=True)
    ap.add_argument('--seed', type=int, required=True)
    ap.add_argument('--result', required=True)
    args = ap.parse_args()

    res_path = pathlib.Path(args.result).resolve()
    cand = pathlib.Path(args.candidate)

    try:
        if not cand.is_absolute() or cand.is_symlink() or cand.resolve() != cand or not cand.is_dir():
            done(res_path, 'FAIL', 'invalid candidate directory', 'anti_hack')
        for rel in (EDITABLE_RTL, EDITABLE_PLAN):
            cur = cand
            for part in pathlib.PurePosixPath(rel).parts:
                cur = cur / part
                if cur.is_symlink():
                    done(res_path, 'FAIL', f'symlink detected in {rel}', 'anti_hack')
            if not cur.is_file():
                done(res_path, 'FAIL', f'missing editable file {rel}', 'structural')
    except OSError as e:
        done(res_path, 'FAIL', f'OS error validating candidate: {e}', 'structural')

    for pub_file in sorted(PUB.rglob('*')):
        if not pub_file.is_file():
            continue
        rel_str = str(pub_file.relative_to(PUB))
        if rel_str in {EDITABLE_RTL, EDITABLE_PLAN}:
            continue
        cand_file = cand / rel_str
        if cand_file.is_symlink():
            done(res_path, 'FAIL', f'protected file symlinked: {rel_str}', 'anti_hack')
        if cand_file.exists():
            if not cand_file.is_file() or sha256_bytes(cand_file.read_bytes()) != sha256_bytes(pub_file.read_bytes()):
                done(res_path, 'FAIL', f'protected file modified: {rel_str}', 'anti_hack')

    try:
        rtl_text = (cand / EDITABLE_RTL).read_text(encoding='utf-8')
    except Exception as e:
        done(res_path, 'FAIL', f'cannot read {EDITABLE_RTL}: {e}', 'structural')

    pol_err = check_rtl_policy(rtl_text)
    if pol_err:
        done(res_path, 'FAIL', pol_err, 'anti_hack')

    plan_file = cand / EDITABLE_PLAN
    try:
        plan = json.loads(plan_file.read_text(encoding='utf-8'))
    except (OSError, ValueError):
        done(res_path, 'FAIL', 'invalid placement JSON', 'structural')

    if not isinstance(plan, dict) or set(plan) != {'macros'} or not isinstance(plan['macros'], list) or len(plan['macros']) != 8:
        done(res_path, 'FAIL', 'exactly eight macros required', 'structural')

    positions = {}
    for m in plan['macros']:
        if (
            not isinstance(m, dict)
            or set(m) != {'bank', 'half', 'x', 'y', 'orient'}
            or type(m['bank']) is not int
            or m['bank'] not in range(4)
            or m['half'] not in ('low', 'high')
            or type(m['x']) is not int
            or type(m['y']) is not int
            or m['orient'] not in ('R0', 'R180', 'MX', 'MY')
        ):
            done(res_path, 'FAIL', 'invalid macro entry', 'structural')
        key = (m['bank'], m['half'])
        x, y, orient = m['x'], m['y'], m['orient']
        if key in positions:
            done(res_path, 'FAIL', 'duplicate macro', 'structural')
        if not (65 <= x and x + 784.48 <= 2335 and 68 <= y and y + 118.78 <= 1730):
            done(res_path, 'FAIL', 'macro outside usable core', 'geometry')
        for px, py, _ in positions.values():
            if not (x + 784.48 + 20 <= px or px + 784.48 + 20 <= x or y + 118.78 + 20 <= py or py + 118.78 + 20 <= y):
                done(res_path, 'FAIL', 'macro overlap or insufficient clearance', 'geometry')
        positions[key] = (x, y, orient)

    if len(positions) != 8:
        done(res_path, 'FAIL', 'missing macro identity', 'structural')

    for b in range(4):
        lx, ly, lo = positions[(b, 'low')]
        hx, hy, ho = positions[(b, 'high')]
        if ly != hy or lx >= hx:
            done(res_path, 'FAIL', f'bank {b} low/high cuts must share Y coordinate with low X < high X', 'geometry')
        if b in (0, 1):
            if not (68 <= ly and ly + 118.78 <= 420):
                done(res_path, 'FAIL', f'south-bay bank {b} intrudes into central corridor [420, 1340] um', 'geometry')
        else:
            if not (1340 <= ly and ly + 118.78 <= 1730):
                done(res_path, 'FAIL', f'north-bay bank {b} intrudes into central corridor [420, 1340] um', 'geometry')
    if positions[(0, 'low')][1] >= positions[(1, 'low')][1] or positions[(2, 'low')][1] >= positions[(3, 'low')][1]:
        done(res_path, 'FAIL', 'bank vertical ordering violated (bank 0 < bank 1 and bank 2 < bank 3 required)', 'geometry')

    try:
        with tempfile.TemporaryDirectory(prefix='case_9014_') as tmp:
            d = pathlib.Path(tmp)
            (d / 'code').mkdir()
            (d / 'pdk').mkdir()
            shutil.copyfile(FIX / 'bp_sram_256x128.sv', d / 'code/bp_sram_256x128.sv')
            (d / 'code/banked.sv').write_text(rtl_text, encoding='utf-8')
            for f in PDK.iterdir():
                if f.is_file():
                    shutil.copyfile(f, d / 'pdk' / f.name)

            # 2. Functional Verification (Icarus Verilog)
            sim = d / 'sim'
            r = subprocess.run(
                [
                    str(IVERILOG_BIN / 'iverilog'),
                    '-B', str(IVERILOG_BIN.parent / 'lib/ivl'),
                    '-g2012',
                    '-s', 'tb',
                    '-o', str(sim),
                    str(d / 'pdk/256.v'),
                    str(d / 'pdk/core.v'),
                    str(d / 'code/bp_sram_256x128.sv'),
                    str(d / 'code/banked.sv'),
                    str(P / 'tests/tb.sv'),
                ],
                cwd=d,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                timeout=60,
            )
            print(r.stdout)
            if r.returncode != 0:
                done(res_path, 'FAIL', 'functional compile failed: ' + r.stdout[-800:], 'structural')

            r = subprocess.run(
                [
                    str(IVERILOG_BIN / 'vvp'),
                    '-M', str(IVERILOG_BIN.parent / 'lib/ivl'),
                    str(sim),
                    f'+SEED={args.seed}',
                ],
                cwd=d,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                timeout=60,
            )
            print(r.stdout)
            if r.returncode != 0 or 'PASS four SRAM clusters' not in r.stdout:
                done(res_path, 'FAIL', 'RTL functional verification failed: ' + r.stdout[-800:], 'behavior')

            # 3. Logic Synthesis (Yosys + Slang)
            mapped = d / 'mapped.v'
            df = d / 'placed.def'
            guide = d / 'route.guide'
            sy = d / 'synth.ys'
            shutil.copyfile(FIX / 'synth.ys', sy)

            r = subprocess.run(
                [str(YOSYS), '-m', 'slang', '-s', str(sy)],
                cwd=d,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                timeout=150,
            )
            print(r.stdout)
            if r.returncode != 0 or not mapped.is_file():
                done(res_path, 'FAIL', 'Yosys synthesis failed', 'synthesis')

            mapped_text = mapped.read_text(encoding='utf-8')
            if mapped_text.count('RM_IHPSG13_1P_256x64_c2_bm_bist ') != 8:
                done(res_path, 'FAIL', 'expected eight RM_IHPSG13_1P_256x64_c2_bm_bist macros in synthesized netlist', 'synthesis')
            if re.search(r'\bsg13g2_d(?:l|fr|f|s)', mapped_text):
                done(res_path, 'FAIL', 'extra standard-cell flip-flops or latches are forbidden in banked.sv', 'synthesis')

            # 4. Physical Implementation & STA (OpenROAD)
            moves = []
            for (bank, half), (x, y, orient) in sorted(positions.items()):
                name = f'cluster\\[{bank}\\].mem.gen_256x128xBx1.i_cut_{half}'
                moves.append(f'place_macro -macro_name {{{name}}} -location {{{x} {y}}} -orientation {orient}')

            t = (
                (FIX / 'flow.tcl.in')
                .read_text(encoding='utf-8')
                .replace('@PDK@', str(d / 'pdk'))
                .replace('@MAPPED@', str(mapped))
                .replace('@DEF@', str(df))
                .replace('@GUIDE@', str(guide))
                .replace('@PLACEMENTS@', '\n'.join(moves))
            )
            tf = d / 'flow.tcl'
            tf.write_text(t, encoding='utf-8')

            r = subprocess.run(
                [str(OPENROAD), '-exit', str(tf)],
                cwd=d,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                timeout=600,
            )
            log = r.stdout
            print(log)
            if r.returncode != 0 or '[ERROR' in log or re.search(r'(?im)^Error:', log):
                if re.search(r'\[ERROR (?:DPL|MPL|PSM|GRT|PDN)-|RELAY_COVERAGE|MACRO_POWER|missing clock connection', log):
                    done(res_path, 'FAIL', 'placement, power, route or relay path coverage violation', 'physical')
                done(res_path, 'ERROR', 'environment_retry OpenROAD flow failed', 'environment')

            required = [
                '__PLACEMENT_OK__',
                '__MACRO_COUNT__ 8',
                '__CLOCK_PINS__ 8',
                '__RELAY_PATHS__ 256',
                '[INFO CTS-0099]  Sinks 8',
            ]
            if not all(x in log for x in required) or not df.is_file():
                done(res_path, 'FAIL', 'missing placement, macro, clock sink or relay path coverage', 'physical')
            if log.count('All shapes on net VDD are connected') != 1 or log.count('All shapes on net VSS are connected') != 1:
                done(res_path, 'FAIL', 'power-grid connectivity failure', 'physical')

            cov = re.search(r'__COVERAGE_BEGIN__\s*(.*?)__COVERAGE_END__', log, re.S)
            if not cov or re.search(r'unconstrained|no clock|no input delay|no output delay|unlinked', cov[1], re.I):
                done(res_path, 'FAIL', 'timing coverage incomplete', 'timing')

            lat = re.search(r'__CLOCK_LATENCY_BEGIN__\s*(.*?)__CLOCK_LATENCY_END__', log, re.S)
            rise = re.search(r'rise -> rise(.*?)fall -> fall', lat[1] if lat else '', re.S)
            if not rise or len(re.findall(r'network latency\s+cluster\[\d\].*?/A_CLK', rise[1])) != 2:
                done(res_path, 'FAIL', 'missing macro clock latency endpoints', 'timing')
            skew_list = re.findall(r'(?m)^\s*([\d.]+)\s+skew\s*$', rise[1])
            latency = re.findall(r'(?m)^\s*([\d.]+)\s+network latency\s+cluster\[\d\].*?/A_CLK', rise[1])
            if len(skew_list) != 1 or len(latency) != 2:
                done(res_path, 'ERROR', 'environment_retry missing clock latency spread', 'environment')
            derived = abs(float(latency[1]) - float(latency[0]))
            skew = float(skew_list[0])
            buffers = re.findall(r'Created\s+(\d+)\s+clock buffers', log)
            depths = re.findall(r'Path depth\s+(\d+)\s*-\s*(\d+)', log)
            if not buffers or int(buffers[-1]) < 1 or not depths or min(map(int, depths[-1])) < 1 or min(map(float, latency)) <= 0:
                done(res_path, 'FAIL', 'propagated clock tree is absent or incomplete', 'timing')
            if abs(derived - skew) > 0.00002:
                done(res_path, 'ERROR', 'environment_retry inconsistent clock latency report', 'environment')

            setup = re.search(r'__SETUP_BEGIN__\s*(.*?)__SETUP_END__', log, re.S)
            hold = re.search(r'__HOLD_BEGIN__\s*(.*?)__HOLD_END__', log, re.S)
            sm = re.findall(r'(-?[\d.]+)\s+slack\s+\((MET|VIOLATED)\)', setup[1] if setup else '')
            hm = re.findall(r'(-?[\d.]+)\s+slack\s+\((MET|VIOLATED)\)', hold[1] if hold else '')
            if not sm or not hm:
                done(res_path, 'ERROR', 'environment_retry timing report incomplete', 'environment')
            setup_slack = float(sm[-1][0])
            hold_slack = float(hm[-1][0])

            section = re.search(r'__WIRE_BEGIN__\s*(.*?)__WIRE_END__', log, re.S)
            rows = re.findall(r'(?m)^Metal[2-5]\s+([\d.]+)um\s+', section[1] if section else '')
            if len(rows) != 4:
                done(res_path, 'ERROR', 'environment_retry routed wire report incomplete', 'environment')
            wire = sum(map(float, rows))
            routed = re.findall(r'Routed nets:\s*(\d+)', log)
            if not routed or not guide.is_file():
                done(res_path, 'ERROR', 'environment_retry routing guide missing', 'environment')
            blocks = len(re.findall(r'^\S[^\n]*\n\($', guide.read_text(encoding='utf-8'), re.M))
            if blocks != int(routed[-1]):
                done(res_path, 'FAIL', 'routing guide count mismatch', 'physical', routed_nets=int(routed[-1]), guide_nets=blocks)

            congestion = re.search(r'Final congestion report:(.*?)(?:\[INFO GRT-0018\]|\[INFO GRT-0014\])', log, re.S)
            total = re.findall(r'(?m)^Total\s+\d+\s+\d+\s+[\d.]+%\s+(\d+)\s*/\s*(\d+)\s*/\s*(\d+)', congestion[1] if congestion else '')
            if not total:
                done(res_path, 'ERROR', 'environment_retry congestion report missing', 'environment')
            if any(int(x) for x in total[-1]):
                done(res_path, 'FAIL', 'global-route overflow', 'physical')

            metrics = {
                'clock_spread_ns': skew,
                'setup_slack_ns': setup_slack,
                'hold_slack_ns': hold_slack,
                'wire_um': round(wire, 1),
                'routed_nets': int(routed[-1]),
                'clock_sinks': 8,
                'relay_paths': 256,
            }
            if skew > 0.00400:
                done(res_path, 'FAIL', 'rise clock network latency spread exceeds 0.00400 ns', 'timing', **metrics)
            if setup_slack < 2.70 or sm[-1][1] != 'MET':
                done(res_path, 'FAIL', 'routed setup slack below 2.70 ns', 'timing', **metrics)
            if hold_slack < 0.00 or hm[-1][1] != 'MET':
                done(res_path, 'FAIL', 'routed hold slack is negative', 'timing', **metrics)
            if wire > 1110000.0:
                done(res_path, 'FAIL', 'global-route wire length exceeds 1110000.0 µm', 'physical', **metrics)

            done(res_path, 'PASS', 'RTL function, clock spread, routed timing, power, and coverage passed', 'physical', **metrics)
    except (OSError, subprocess.TimeoutExpired) as e:
        done(res_path, 'ERROR', 'environment_retry ' + str(e), 'environment')


if __name__ == '__main__':
    main()
