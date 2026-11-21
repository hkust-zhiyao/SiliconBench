#!/usr/bin/env bash
# Standardized Harbor Isolated Verifier Entrypoint (tests/test.sh) for case_20003
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TASK_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

if [ $# -ge 1 ] && [ -n "${1:-}" ]; then
    CANDIDATE_DIR="$1"
elif [ -d "/workspace" ]; then
    CANDIDATE_DIR="${CANDIDATE_DIR:-${HARBOR_SUBMISSION_DIR:-/workspace}}"
elif [ -d "${TASK_ROOT}/environment/public" ]; then
    CANDIDATE_DIR="${CANDIDATE_DIR:-${TASK_ROOT}/environment/public}"
else
    CANDIDATE_DIR="${SCRIPT_DIR}/public"
fi

if [ $# -ge 2 ] && [ -n "${2:-}" ]; then
    LOG_DIR="$2"
    mkdir -p "${LOG_DIR}"
elif [ -d "/logs/verifier" ] || mkdir -p "/logs/verifier" 2>/dev/null; then
    LOG_DIR="${LOG_DIR:-${HARBOR_VERIFIER_LOG_DIR:-/logs/verifier}}"
else
    LOG_DIR="${LOG_DIR:-${TASK_ROOT}/logs/verifier}"
    mkdir -p "${LOG_DIR}"
fi

if [ -d "${SCRIPT_DIR}/public" ]; then
    BASE_PUBLIC="${SCRIPT_DIR}/public"
elif [ -d "${TASK_ROOT}/environment/public" ]; then
    BASE_PUBLIC="${TASK_ROOT}/environment/public"
else
    echo "ERROR: baseline public directory not found" >&2
    exit 2
fi

# 1. Stage a clean copy of public/, enforce centralized pre-grader policy & allowlist overlay
CAND_STAGE="$(mktemp -d "${TMPDIR:-/tmp}/siliconbench_cand_case_20003_XXXXXX")"
trap 'rm -rf "${CAND_STAGE}"' EXIT

cp -rf "${BASE_PUBLIC}/." "${CAND_STAGE}/"
rm -f "${LOG_DIR}"/result_seed_*.json
ALLOWED_EDITS=("code/biriscv_npc.v" "code/biriscv_fetch.v")

set +e
python3 "${SCRIPT_DIR}/private/policy_filter.py" \
    --candidate "${CANDIDATE_DIR}" \
    --stage "${CAND_STAGE}" \
    --baseline "${BASE_PUBLIC}" \
    --reward-json "${LOG_DIR}/reward.json" \
    --reward-txt "${LOG_DIR}/reward.txt" \
    --task-id "case_20003" \
    --allowed "${ALLOWED_EDITS[@]}"
PF_EXIT=$?
set -e

if [ "${PF_EXIT}" -eq 42 ]; then
    exit 0
elif [ "${PF_EXIT}" -ne 0 ]; then
    echo "0.0" > "${LOG_DIR}/reward.txt"
    exit 0
fi

# 2. Run all task-configured grading seeds (or single SEED override if explicitly set in environment)
if [ -n "${SEED:-}" ]; then
    SEEDS=("${SEED}")
else
    SEEDS=(101 202)
fi

ALL_PASS=1
for s_val in "${SEEDS[@]}"; do
    SEED_JSON="${LOG_DIR}/result_seed_${s_val}.json"
    set +e
    python3 "${SCRIPT_DIR}/private/grader/run.py" \
        --candidate "${CAND_STAGE}" \
        --seed "${s_val}" \
        --result "${SEED_JSON}"
    GRADER_EXIT=$?
    set -e
    if [ "${GRADER_EXIT}" -ne 0 ] || [ ! -f "${SEED_JSON}" ]; then
        ALL_PASS=0
        break
    fi
done

# 3. Emit unified Harbor reward.txt and reward.json after verifying exit codes + every seed JSON
EXPECTED_SEEDS="${#SEEDS[@]}"
python3 - "${LOG_DIR}" "${ALL_PASS}" "${EXPECTED_SEEDS}" "case_20003" <<'PYEOF'
import json, pathlib, sys
log_dir = pathlib.Path(sys.argv[1])
all_pass = int(sys.argv[2]) == 1
expected_seeds = int(sys.argv[3])
cid = sys.argv[4]
seeds = []
for p in sorted(log_dir.glob("result_seed_*.json")):
    try:
        seeds.append(json.loads(p.read_text(encoding="utf-8")))
    except Exception:
        pass
passed = bool(all_pass and len(seeds) == expected_seeds and all(s.get("verdict") == "PASS" for s in seeds))
if passed:
    (log_dir / "reward.txt").write_text("1.0\n", encoding="utf-8")
    out = {
        "task_id": cid,
        "verdict": "PASS",
        "reward": 1.0,
        "score": 1.0,
        "seed_results": seeds,
    }
else:
    (log_dir / "reward.txt").write_text("0.0\n", encoding="utf-8")
    last = seeds[-1] if seeds else {}
    out = {
        "task_id": cid,
        "verdict": "FAIL",
        "reward": 0.0,
        "score": 0.0,
        "stage": last.get("stage", "grader_error" if not seeds else "unknown"),
        "reason": last.get("reason") or last.get("detail") or last.get("message") or "verification failed",
        "seed_results": seeds,
    }
(log_dir / "reward.json").write_text(json.dumps(out, indent=2) + "\n", encoding="utf-8")
PYEOF

exit 0
