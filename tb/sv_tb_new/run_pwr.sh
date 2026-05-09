#!/usr/bin/env bash
# SPDX-License-Identifier: SHL-0.51
set -euo pipefail

vcs -full64 -timescale=1ns/1ps -sverilog -f filelist_pwr.f \
    -debug_access+pp+all -kdb -lca +vpi \
    +define+FSDB \
    -o simv

./simv