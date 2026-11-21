#!/usr/bin/env python3
"""
SiliconBench Standardized Harbor Verifier & Batch Evaluation CLI (94 Tasks, 30 Repositories).

Supports:
  1. Verifying the Harbor Oracle (`--mode oracle` using `solution/gold` or `solution/alternate_gold`)
  2. Verifying the Buggy Starter fails (`--mode starter` using `environment/public`)
  3. Grading external agent submissions (`--mode candidate --submissions-dir /path/to/subs`)
  4. Filtering by task (`--task case_0009`) or running all 94 tasks in parallel (`--workers 16`).
"""
import argparse
import concurrent.futures
import json
import os
import pathlib
import signal
import subprocess
import tempfile
import time

REPO_ROOT = pathlib.Path(__file__).resolve().parents[1]
TASKS_DIR = REPO_ROOT / 'tasks'


def eval_one_task(task_id: str, mode: str, submissions_dir: pathlib.Path | None, timeout_override: int | None):
    t0 = time.time()
    tdir = TASKS_DIR / task_id
    cfg = json.loads((tdir / 'task_config.json').read_text(encoding='utf-8'))
    grading = cfg.get('grading', {})
    n_seeds = max(1, len(grading.get('configurations', [{'seed': 1}])))
    timeout_sec = timeout_override or grading.get('verifier_timeout_seconds') or (grading.get('grader_timeout_seconds', 600) * n_seeds)

    if mode == 'oracle':
        cand_dir = tdir / 'solution/gold'
    elif mode == 'alt_oracle':
        cand_dir = tdir / 'solution/alternate_gold'
    elif mode == 'starter':
        cand_dir = tdir / 'environment/public'
    elif mode == 'candidate':
        if not submissions_dir:
            raise ValueError('--submissions-dir is required when --mode=candidate')
        cand_dir = submissions_dir / task_id
    else:
        raise ValueError(f'Unknown mode: {mode}')

    tmp_root = '/tmp' if os.path.isdir('/tmp') and os.access('/tmp', os.W_OK) else None
    with tempfile.TemporaryDirectory(prefix=f'harbor_eval_{task_id}_', dir=tmp_root) as tmp:
        log_dir = pathlib.Path(tmp) / 'verifier_logs'
        log_dir.mkdir(parents=True, exist_ok=True)
        env = dict(os.environ)
        env.setdefault('TMPDIR', tmp_root or tmp)
        if 'SILICONBENCH_TOOLS' not in env and not pathlib.Path('/opt/siliconbench/tools').exists():
            tools_dir = REPO_ROOT / 'environments/tools'
            if tools_dir.is_dir():
                env['SILICONBENCH_TOOLS'] = str(tools_dir)
        if 'SILICONBENCH_NANGATE45' not in env and not pathlib.Path('/opt/siliconbench/pdk/Nangate45').exists():
            env['SILICONBENCH_NANGATE45'] = str(REPO_ROOT / 'environments/pdk/Nangate45')

        cmd = [str(tdir / 'tests/test.sh'), str(cand_dir.resolve()), str(log_dir)]
        proc = None
        try:
            proc = subprocess.Popen(
                cmd,
                env=env,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                start_new_session=True,
            )
            stdout, stderr = proc.communicate(timeout=timeout_sec)
            reward_json = log_dir / 'reward.json'
            if reward_json.is_file():
                res = json.loads(reward_json.read_text(encoding='utf-8'))
            else:
                res = {
                    'task_id': task_id,
                    'verdict': 'PASS' if proc.returncode == 0 else 'FAIL',
                    'reward': 1.0 if proc.returncode == 0 else 0.0,
                    'stdout': stdout[-1000:],
                    'stderr': stderr[-1000:],
                }
        except subprocess.TimeoutExpired:
            if proc is not None:
                try:
                    os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
                except OSError:
                    proc.kill()
                try:
                    proc.communicate(timeout=5)
                except Exception:
                    pass
            res = {'task_id': task_id, 'verdict': 'TIMEOUT', 'reward': 0.0, 'score': 0.0}
        res['elapsed_sec'] = round(time.time() - t0, 2)
        res['mode'] = mode
        return res


def main():
    ap = argparse.ArgumentParser(description='SiliconBench Harbor Verifier & Batch Evaluation CLI (94 Tasks)')
    ap.add_argument('--mode', choices=['oracle', 'alt_oracle', 'starter', 'candidate'], default='oracle',
                    help='Evaluation mode: oracle (gold), alt_oracle (alternate_gold), starter (buggy public), or candidate')
    ap.add_argument('--task', type=str, default=None, help='Single task_id to evaluate (e.g. case_0009), or omit for all 94 tasks')
    ap.add_argument('--submissions-dir', type=pathlib.Path, default=None, help='Directory containing <task_id>/ candidate edits')
    ap.add_argument('--workers', type=int, default=8, help='Parallel verification workers')
    ap.add_argument('--timeout', type=int, default=None, help='Optional per-task verifier timeout override in seconds')
    ap.add_argument('--output', type=pathlib.Path, default=None, help='Optional JSON summary output path')
    args = ap.parse_args()

    if args.task:
        task_ids = [args.task]
    else:
        task_ids = sorted(
            [p.name for p in TASKS_DIR.iterdir() if p.is_dir() and (p / 'task.toml').is_file()],
            key=lambda x: (int(x.split('_')[1]), x)
        )

    print(f'[SiliconBench Harbor Eval] Running mode={args.mode} across {len(task_ids)} task(s) with {args.workers} worker(s)...')
    results = []
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.workers) as ex:
        futs = {ex.submit(eval_one_task, tid, args.mode, args.submissions_dir, args.timeout): tid for tid in task_ids}
        for fut in concurrent.futures.as_completed(futs):
            r = fut.result()
            results.append(r)
            print(f"  [{r['verdict']:4s}] {r['task_id']:10s} | reward={r.get('reward', 0.0):.1f} | {r['elapsed_sec']:5.2f}s")

    results.sort(key=lambda r: (int(r['task_id'].split('_')[1]), r['task_id']))
    passed = sum(1 for r in results if r.get('reward', 0.0) == 1.0)
    summary = {
        'mode': args.mode,
        'total_tasks': len(results),
        'passed_tasks': passed,
        'pass_rate_pct': round(100.0 * passed / max(1, len(results)), 2),
        'results': results,
    }
    print(f"\n=== Summary ({args.mode}): {passed}/{len(results)} ({summary['pass_rate_pct']}%) PASS ===")
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(summary, indent=2) + '\n', encoding='utf-8')


if __name__ == '__main__':
    main()
