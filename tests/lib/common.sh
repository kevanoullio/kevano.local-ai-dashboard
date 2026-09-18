#!/bin/bash
# Shared bootstrap and phase helpers for the tests/ runners. Source this from
# any tests/*.sh script; paths resolve from this file's own location, so it
# works identically for every caller. Defines the repo paths, the FAILED/UNITS
# counters, and the per-phase functions used by both run_all.sh and the focused
# per-phase runners (run_unit_tests.sh, run_integration_tests.sh, run_e2e_tests.sh).

set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
T="$ROOT/tests"
CACHE="$T/.cache"
LIB="$T/lib"
E2E="$CACHE/e2e"

FAILED=0
UNITS=0
ITS=0
E2ES=0

step() { echo "── $1"; }

check_deps() {
  local ok=1 c
  for c in "$@"; do
    command -v "$c" >/dev/null || { echo "missing dependency: $c"; ok=0; }
  done
  [ "$ok" -eq 1 ] || exit 2
}

# Phase 1: dump the embedded bash scripts/constants from Service.qml.
extract_constants_phase() {
  bash "$LIB/extract_constants.sh" || FAILED=$((FAILED+1))
}

# Phase 2: QML unit tests against tests/.cache/run/Service.qml. One quickshell
# run per harness (the engine assertions live in QML, not bash), then every
# assertion is re-reported as a real bats test via lib/gen_assert_bats.sh so
# the whole suite shares one UI.
run_unit_phase() {
  local bats_bin="$LIB/bats/bin/bats" h base
  if [ ! -x "$bats_bin" ]; then
    echo "  vendored bats not found at $bats_bin — re-vendor it (see tests/README.md)"
    FAILED=$((FAILED+1))
    return
  fi
  rm -rf "$CACHE/generated/unit"
  mkdir -p "$CACHE/run" "$CACHE/generated/unit"
  cp -f "$ROOT/Service.qml" "$CACHE/run/Service.qml"
  UNITS=0
  for h in "$T"/unit_tests/tst_*.qml; do
    base=$(basename "$h" .qml)
    UNITS=$((UNITS+1))
    bash "$LIB/run_qml_harness.sh" "$h" "$CACHE/run/Service.qml" || true
    bash "$LIB/gen_assert_bats.sh" "$CACHE/generated/unit/$base.bats" "$CACHE/run-$base.log" "$base"
  done
  "$bats_bin" -t "$CACHE"/generated/unit/*.bats || FAILED=$((FAILED+1))
}

# Phase 3: shell integration tests (vendored bats-core).
run_integration_phase() {
  local bats_bin="$LIB/bats/bin/bats" f
  if [ -x "$bats_bin" ]; then
    ITS=0
    for f in "$T"/integration_tests/*.bats; do
      [ -e "$f" ] || continue
      ITS=$((ITS+1))
    done
    "$bats_bin" -t "$T"/integration_tests/*.bats || FAILED=$((FAILED+1))
  else
    echo "  vendored bats not found at $bats_bin — re-vendor it (see tests/README.md)"
    FAILED=$((FAILED+1))
  fi
}

setup_e2e() { # fresh isolated plugin sandbox under tests/.cache/e2e
  rm -rf "$E2E"
  mkdir -p "$E2E/plugin/configs" "$E2E/home/.config/systemd/user" "$E2E/bin"
  cp "$ROOT/Service.qml" "$ROOT/Dashboard.qml" "$E2E/plugin/"
  cp -r "$ROOT/sections" "$ROOT/ui" "$E2E/plugin/"
  cp "$LIB/mocks/systemctl" "$LIB/mocks/systemd-analyze" "$LIB/mocks/llama-server" "$LIB/mocks/curl" "$E2E/bin/"
  chmod +x "$E2E/bin"/*
  : > "$E2E/mocklog"
}

# Phase 4: e2e sandbox harnesses + the Dashboard→section wiring pin, each
# assertion re-reported as a real bats test via lib/gen_assert_bats.sh.
run_e2e_phase() {
  local bats_bin="$LIB/bats/bin/bats" wlog h
  if [ ! -x "$bats_bin" ]; then
    echo "  vendored bats not found at $bats_bin — re-vendor it (see tests/README.md)"
    FAILED=$((FAILED+1))
    return
  fi
  rm -rf "$CACHE/generated/e2e"
  mkdir -p "$CACHE/generated/e2e"
  E2ES=0
  for h in "$T"/e2e_tests/e2e_*.qml; do
    [ -e "$h" ] || continue
    E2ES=$((E2ES+1))
  done

  setup_e2e
  bash "$LIB/run_qml_harness.sh" "$T/e2e_tests/e2e_llama_lifecycle.qml" "$E2E/plugin/Service.qml" \
    HOME="$E2E/home" PATH="$E2E/bin:$PATH" __mocklog="$E2E/mocklog" || true
  bash "$LIB/gen_assert_bats.sh" "$CACHE/generated/e2e/e2e_llama_lifecycle.bats" "$CACHE/run-e2e_llama_lifecycle.log" "e2e_llama_lifecycle"

  setup_e2e
  printf 'OLD-UNIT\n' > "$E2E/home/.config/systemd/user/llama.cpp.service"
  bash "$LIB/run_qml_harness.sh" "$T/e2e_tests/e2e_llama_rollback.qml" "$E2E/plugin/Service.qml" \
    HOME="$E2E/home" PATH="$E2E/bin:$PATH" __mocklog="$E2E/mocklog" FAIL_START=1 || true
  bash "$LIB/gen_assert_bats.sh" "$CACHE/generated/e2e/e2e_llama_rollback.bats" "$CACHE/run-e2e_llama_rollback.log" "e2e_llama_rollback"

  setup_e2e
  printf 'UNIT-SEEDED\n' > "$E2E/home/.config/systemd/user/llama.cpp.service"
  bash "$LIB/run_qml_harness.sh" "$T/e2e_tests/e2e_dashboard_confirm_wiring.qml" "$E2E/plugin/Service.qml" \
    HOME="$E2E/home" PATH="$E2E/bin:$PATH" __mocklog="$E2E/mocklog" || true
  bash "$LIB/gen_assert_bats.sh" "$CACHE/generated/e2e/e2e_dashboard_confirm_wiring.bats" "$CACHE/run-e2e_dashboard_confirm_wiring.log" "e2e_dashboard_confirm_wiring"

  # Dashboard↔service consent arc, pinned at source level (the live button drive
  # above already proves section→service propagation; this pins the Dashboard side).
  wlog="$CACHE/run-e2e_dashboard_wiring.log"
  if rg -q 'onConfirmProvisionRequested:.*confirmProvision()' "$E2E/plugin/Dashboard.qml" \
     && rg -q 'onCancelProvisionRequested:.*cancelProvision()' "$E2E/plugin/Dashboard.qml"; then
    printf 'LAD-PASS  dashboard-wiring\nLAD-SUMMARY:1:0\n' > "$wlog"
  else
    printf 'LAD-FAIL  dashboard-wiring  got=missing-handler expected=onConfirm/onCancelProvisionRequested -> confirm/cancelProvision()\nLAD-SUMMARY:1:1\n' > "$wlog"
  fi
  bash "$LIB/gen_assert_bats.sh" "$CACHE/generated/e2e/e2e_dashboard_wiring.bats" "$wlog" "dashboard-wiring"

  "$bats_bin" -t "$CACHE"/generated/e2e/*.bats || FAILED=$((FAILED+1))
}

summary() { # label [detail]
  local label=$1 detail=${2:-}
  echo
  if [ "$FAILED" -eq 0 ]; then
    if [ -n "$detail" ]; then
      echo "ALL $label TESTS PASSED ($detail)"
    else
      echo "ALL $label TESTS PASSED"
    fi
  else
    echo "FAILED $label stage(s)/component(s): $FAILED"
    exit 1
  fi
}