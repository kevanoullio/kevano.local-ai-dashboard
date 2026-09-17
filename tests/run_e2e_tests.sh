#!/bin/bash
# Local AI Dashboard — end-to-end sandbox tests only (Phase 4).
# Drives the full llama.cpp lifecycle, the rollback path, and the consent-wiring
# arc against an isolated copy of the plugin plus mocked systemd binaries.
set -u
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

check_deps quickshell timeout bash rg

step "e2e tests (isolated sandbox)"
run_e2e_phase

summary "E2E" "harnesses: $E2ES"