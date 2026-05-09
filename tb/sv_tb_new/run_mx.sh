#!/usr/bin/env bash
# SPDX-License-Identifier: SHL-0.51
#
# Build and run the two MX micro-TBs:
#   simv_mx_dp_micro -> tb_mx_dp_micro    (FMA-level, exp-shift datapath)
#   simv_mx_pe_micro -> tb_mx_pe_micro    (pe_tile-level, MX_MODE="MXFP4")
#
# Requires: source ../../sourceme.sh first (sets FPNEW_HOME) and VCS in PATH.
set -euo pipefail

cd "$(dirname "$0")"

if [[ -z "${FPNEW_HOME:-}" ]]; then
  echo "FPNEW_HOME is not set. 'source ../../sourceme.sh' first." >&2
  exit 1
fi

VCS_COMMON=(
  -full64 -timescale=1ns/1ps -sverilog -f filelist.f
  -debug_access+pp+all -kdb -lca +vpi
  +define+FSDB
)

build_one() {
  local tb_src="$1" top="$2" out="$3"
  shift 3
  echo "=== build ${out} (-top ${top}) ==="
  vcs "${VCS_COMMON[@]}" "$@" "${tb_src}" -top "${top}" -o "${out}" -l "vcs_${out}.log"
}

# tb_mx_dp_micro is FMA-level, no systolic RTL needed.
build_one "${FPNEW_HOME}/tb/sv_tb_new/tb_mx_dp_micro.sv" tb_mx_dp_micro simv_mx_dp_micro

# tb_mx_pe_micro instantiates pe_tile, so pull in the systolic RTL it needs.
build_one "${FPNEW_HOME}/tb/sv_tb_new/tb_mx_pe_micro.sv" tb_mx_pe_micro simv_mx_pe_micro \
  "${FPNEW_HOME}/src/systolic/pe_tile.sv"

FAIL=0

run_one() {
  local bin="$1"
  echo
  echo "--- run ./${bin} ---"
  ./"${bin}" -l "sim_${bin}.log"
  # tb_mx_dp_micro prints "OVERALL: ALL PASS"; tb_mx_pe_micro prints
  # "SUMMARY: PASS=N FAIL=0". Treat any FAIL>0 marker as a failure.
  if grep -qE "FAIL +[1-9]|FAIL=[1-9]|\\[TB_MX[^]]*\\] FAIL " "sim_${bin}.log"; then
    echo "[${bin}] FAIL — see sim_${bin}.log"
    FAIL=$((FAIL + 1))
  else
    echo "[${bin}] PASS"
  fi
}

run_one simv_mx_dp_micro
run_one simv_mx_pe_micro

echo
if [[ $FAIL -eq 0 ]]; then
  echo "[run_mx] ALL PASS"
else
  echo "[run_mx] ${FAIL} failure(s)"
  exit 1
fi
