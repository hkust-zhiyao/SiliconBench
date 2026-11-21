#!/usr/bin/env bash
# Standardized Harbor Oracle Solution Script (solve.sh)
# Copies ONLY the task's allowlisted golden reference files into the active solver workspace.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_DIR="${HARBOR_WORKSPACE:-/workspace}"
if [ ! -d "$WORKSPACE_DIR" ]; then
  WORKSPACE_DIR="$(pwd)"
fi
ALLOWED_EDITS=("constraints/axi_llc_ways.sdc" "code/rtl/axi_llc_burst_cutter.sv" "code/rtl/axi_llc_merge_unit.sv" "code/rtl/axi_llc_read_unit.sv" "code/rtl/axi_llc_write_unit.sv" "code/rtl/axi_llc_ways.sv")
for rel in "${ALLOWED_EDITS[@]}"; do
  if [ -f "$SCRIPT_DIR/gold/$rel" ]; then
    mkdir -p "$(dirname "$WORKSPACE_DIR/$rel")"
    cp -f "$SCRIPT_DIR/gold/$rel" "$WORKSPACE_DIR/$rel"
  elif [[ "$rel" == code/* ]] && [ -f "$SCRIPT_DIR/gold/${rel#code/}" ]; then
    mkdir -p "$(dirname "$WORKSPACE_DIR/$rel")"
    cp -f "$SCRIPT_DIR/gold/${rel#code/}" "$WORKSPACE_DIR/$rel"
  fi
done
echo "[SiliconBench Oracle] Applied certified gold allowed_edits for case_20020 to $WORKSPACE_DIR"
