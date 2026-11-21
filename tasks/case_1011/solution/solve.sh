#!/usr/bin/env bash
# Standardized Harbor Oracle Solution Script (solve.sh)
# Copies ONLY the task's allowlisted golden reference files into the active solver workspace.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_DIR="${HARBOR_WORKSPACE:-/workspace}"
if [ ! -d "$WORKSPACE_DIR" ]; then
  WORKSPACE_DIR="$(pwd)"
fi
ALLOWED_EDITS=("code/spi_host_fsm.sv" "code/spi_host_shift_register.sv" "code/spi_host_byte_select.sv")
for rel in "${ALLOWED_EDITS[@]}"; do
  if [ -f "$SCRIPT_DIR/gold/$rel" ]; then
    mkdir -p "$(dirname "$WORKSPACE_DIR/$rel")"
    cp -f "$SCRIPT_DIR/gold/$rel" "$WORKSPACE_DIR/$rel"
  elif [[ "$rel" == code/* ]] && [ -f "$SCRIPT_DIR/gold/${rel#code/}" ]; then
    mkdir -p "$(dirname "$WORKSPACE_DIR/$rel")"
    cp -f "$SCRIPT_DIR/gold/${rel#code/}" "$WORKSPACE_DIR/$rel"
  fi
done
echo "[SiliconBench Oracle] Applied certified gold allowed_edits for case_1011 to $WORKSPACE_DIR"
