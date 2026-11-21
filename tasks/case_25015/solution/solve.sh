#!/usr/bin/env bash
# Standardized Harbor Oracle Solution Script (solve.sh)
# Copies ONLY the task's allowlisted golden reference files into the active solver workspace.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_DIR="${HARBOR_WORKSPACE:-/workspace}"
if [ ! -d "$WORKSPACE_DIR" ]; then
  WORKSPACE_DIR="$(pwd)"
fi
ALLOWED_EDITS=("code/snitch_clkdiv2.sv" "code/snitch_l0_tlb.sv" "code/snitch_ptw.sv" "code/snitch_shared_muldiv.sv" "code/snitch_iso_hive.sv" "constraints/snitch_iso_hive.sdc")
for rel in "${ALLOWED_EDITS[@]}"; do
  if [ -f "$SCRIPT_DIR/gold/$rel" ]; then
    mkdir -p "$(dirname "$WORKSPACE_DIR/$rel")"
    cp -f "$SCRIPT_DIR/gold/$rel" "$WORKSPACE_DIR/$rel"
  elif [[ "$rel" == code/* ]] && [ -f "$SCRIPT_DIR/gold/${rel#code/}" ]; then
    mkdir -p "$(dirname "$WORKSPACE_DIR/$rel")"
    cp -f "$SCRIPT_DIR/gold/${rel#code/}" "$WORKSPACE_DIR/$rel"
  fi
done
echo "[SiliconBench Oracle] Applied certified gold allowed_edits for case_25015 to $WORKSPACE_DIR"
