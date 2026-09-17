#!/bin/bash
# Local AI Dashboard — full test suite runner.
#   Phase 1: dump embedded bash constants from Service.qml (source of truth)
#   Phase 2: QML unit tests (quickshell harness + asserts.js)
#   Phase 3: shell integration tests (vendored bats-core + sandbox + mocks)
#   Phase 4: end-to-end sandbox tests (quickshell against isolated plugin copy)
# Everything runs inside tests/.cache — no host state is touched.
set -u
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

check_deps quickshell timeout bash python3 stat flock mktemp rg

step "1. extracting constants from Service.qml"
extract_constants_phase

step "2. QML unit tests"
run_unit_phase

step "3. integration tests (bats)"
run_integration_phase

step "4. e2e tests (isolated sandbox)"
run_e2e_phase

summary "SUITE" "harnesses: $UNITS unit, $ITS integration, $E2ES e2e"