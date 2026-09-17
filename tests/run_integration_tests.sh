#!/bin/bash
# Local AI Dashboard — shell integration tests only (Phase 3, vendored bats).
# Extracts the embedded bash constants from Service.qml first so every test
# executes the exact scripts the panel ships; runs against a scratch sandbox.
set -u
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

check_deps bash python3 stat flock timeout

step "1. extracting constants from Service.qml"
bash "$LIB/extract_constants.sh" || {
  echo "  constants extraction failed — integration tests can't run"
  exit 1
}

step "2. integration tests (bats)"
run_integration_phase

summary "INTEGRATION" "harnesses: $ITS"