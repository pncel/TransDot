#!/usr/bin/env bash
# SPDX-License-Identifier: SHL-0.51
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/../.." && pwd)

export FPNEW_HOME="${FPNEW_HOME:-$REPO_ROOT}"

MODE="${MODE:-all}"
WAVES="${WAVES:-0}"
VERBOSE="${VERBOSE:-0}"

echo "[REG][SYN] FPNEW_HOME=${FPNEW_HOME}"
echo "[REG][SYN] MODE=${MODE} WAVES=${WAVES} VERBOSE=${VERBOSE}"

pushd "${SCRIPT_DIR}" >/dev/null
vcs -full64 -timescale=1ns/1ps -sverilog -top tb_fpnew_syn -f filelist_syn.f \
  -debug_access+pp+all -kdb -lca +vpi \
  +define+FSDB \
  -o simv_syn -l vcs_syn.log

SIM_ARGS=("+MODE=${MODE}")
if [[ "${VERBOSE}" == "1" ]]; then
  SIM_ARGS+=("+VERBOSE")
fi
if [[ "${WAVES}" == "1" ]]; then
  SIM_ARGS+=("+WAVES")
fi

./simv_syn "${SIM_ARGS[@]}" -l "sim_syn_${MODE}.log"
popd >/dev/null

echo "[REG][SYN] PASS"
