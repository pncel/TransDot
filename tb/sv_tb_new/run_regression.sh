#!/usr/bin/env bash
# SPDX-License-Identifier: SHL-0.51
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/../.." && pwd)

export FPNEW_HOME="${FPNEW_HOME:-$REPO_ROOT}"

NUM_TESTS="${1:-256}"
SEED="${2:-12345}"
WAVES="${WAVES:-0}"
VERBOSE="${VERBOSE:-0}"
SKIP_GEN="${SKIP_GEN:-0}"
MODE="${MODE:-all}"

echo "[REG] FPNEW_HOME=${FPNEW_HOME}"
echo "[REG] NUM_TESTS=${NUM_TESTS} SEED=${SEED} WAVES=${WAVES} VERBOSE=${VERBOSE} SKIP_GEN=${SKIP_GEN} MODE=${MODE}"

if [[ "${SKIP_GEN}" != "1" ]]; then
  FLEXFLOAT_HDR="${FPNEW_HOME}/tb/flexfloat/include/flexfloat.h"
  FLEXFLOAT_LIB_A="${FPNEW_HOME}/tb/flexfloat/libflexfloat.a"
  FLEXFLOAT_LIB_SO="${FPNEW_HOME}/tb/flexfloat/libflexfloat.so"
  if [[ ! -f "${FLEXFLOAT_HDR}" ]]; then
    echo "[REG][ERR] Missing ${FLEXFLOAT_HDR}"
    echo "[REG][ERR] Initialize/build flexfloat or run with SKIP_GEN=1 to use existing vectors."
    exit 2
  fi
  if [[ ! -f "${FLEXFLOAT_LIB_A}" && ! -f "${FLEXFLOAT_LIB_SO}" ]]; then
    echo "[REG][ERR] Missing flexfloat library in tb/flexfloat (libflexfloat.a/.so)"
    echo "[REG][ERR] Build flexfloat first or run with SKIP_GEN=1 to use existing vectors."
    exit 2
  fi

  echo "[REG] Generating deterministic vectors..."
  pushd "${FPNEW_HOME}/tb/test_data_generate" >/dev/null
  g++ -std=c++17 -O2 \
    -I../flexfloat/include \
    generate_test_data.cpp \
    -L../flexfloat -lflexfloat -lstdc++fs \
    -o generate_test_data
  ./generate_test_data "${NUM_TESTS}" "${SEED}"
  popd >/dev/null
else
  echo "[REG] SKIP_GEN=1, using existing vectors in tb/test_data_generate/generated/"
fi

COMMON_CELLS_HDR="${FPNEW_HOME}/src/common_cells/include/common_cells/registers.svh"
if [[ ! -f "${COMMON_CELLS_HDR}" ]]; then
  echo "[REG][ERR] Missing ${COMMON_CELLS_HDR}"
  echo "[REG][ERR] Initialize submodules (common_cells) before running regression."
  exit 2
fi

echo "[REG] Compiling tb/sv_tb_new..."
pushd "${SCRIPT_DIR}" >/dev/null
vcs -full64 -timescale=1ns/1ps -sverilog -f filelist.f \
  -debug_access+pp+all -kdb -lca +vpi \
  +define+FSDB \
  -o simv -l vcs.log

SIM_ARGS=()
if [[ "${VERBOSE}" == "1" ]]; then
  SIM_ARGS+=("+VERBOSE")
fi
if [[ "${WAVES}" == "1" ]]; then
  SIM_ARGS+=("+WAVES")
fi
SIM_ARGS+=("+MODE=${MODE}")

echo "[REG] Running simulation..."
./simv "${SIM_ARGS[@]}" -l sim.log
popd >/dev/null

echo "[REG] PASS"
