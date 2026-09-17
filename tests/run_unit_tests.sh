#!/bin/bash
# Local AI Dashboard — QML unit tests only (Phase 2).
# Runs each tests/unit_tests/tst_*.qml under a quickshell harness with the real
# Service.qml copied into tests/.cache/run. Everything stays inside .cache.
set -u
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

check_deps quickshell timeout bash

step "QML unit tests"
run_unit_phase

summary "UNIT" "harnesses: $UNITS"