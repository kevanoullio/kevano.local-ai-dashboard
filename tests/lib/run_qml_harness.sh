#!/bin/bash
# run_qml_harness.sh <harness.qml> <service.qml-abs-path> [ENV=VAL...]
#
# Assembles a self-contained quickshell config dir containing the harness, the
# qs.Commons/qs.Ui stubs, asserts.js and (for unit runs, callers pre-copy it)
# Service.qml itself. The dir IS the -p config dir, so qs.Commons resolves.
# Tokens substituted: @SERVICE_QML_PATH@ and @SECTION_QML_PATH@ (sibling of
# service under sections/), plus @TESTS_DIR@ so a harness can read a committed
# fixture regardless of which .cache dir its Service.qml was copied into.
# Prints the LAD-* summary. Exits nonzero on failure.
set -u
T="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
harn=${1:?}
service=${2:?}
shift 2

name=$(basename "$harn" .qml)
src_dir=$(cd "$(dirname "$service")" && pwd)
LOG="$T/.cache/run-$name.log"
# The assembly dir (stubs + harness qml, the -p config dir) must always live
# under tests/.cache. If the service's own dir is outside it (e.g. a dev run
# pointed at the real repo Service.qml), copy that plugin tree in first so
# nothing is ever written into the plugin source tree.
case "$src_dir" in
  "$T"/.cache/*) dir="$src_dir" ;;
  *)
    dir="$T/.cache/run-$name"
    rm -rf "$dir"
    mkdir -p "$dir"
    # .cache is excluded so the copy never reads its own destination.
    tar -C "$src_dir" --exclude=.git --exclude=.cache -cf - . | tar -C "$dir" -xf -
    ;;
esac
service="$dir/$(basename "$service")"
mkdir -p "$dir"

rm -rf "$dir/Commons" "$dir/Ui"
cp -r "$T/support/Commons" "$dir/Commons"
cp -r "$T/support/Ui" "$dir/Ui"
cp "$T/lib/asserts.js" "$dir/asserts.js"

plugin_dir=$(dirname "$service")
sed -e "s|@SERVICE_QML_PATH@|file://$service|g" \
    -e "s|@SECTION_QML_PATH@|file://$plugin_dir/sections/ServiceDetailsSection.qml|g" \
    -e "s|@DASHBOARD_QML_PATH@|file://$plugin_dir/Dashboard.qml|g" \
    -e "s|@PROBE_SCRIPT_PATH@|${PROBE_SCRIPT_PATH:-@PROBE_SCRIPT_PATH@}|g" \
    -e "s|@TESTS_DIR@|${TESTS_DIR:-$T}|g" \
    < "$harn" > "$dir/$name.qml"

(cd "$T" && env QT_QPA_PLATFORM="${QT_QPA_PLATFORM:-offscreen}" "$@" timeout 90 quickshell -p "$dir/$name.qml" > "$LOG" 2>&1) &
qpid=$!
rc=124
for _ in $(seq 1 180); do
  if grep -q "LAD-SUMMARY" "$LOG" 2>/dev/null; then
    kill "$qpid" 2>/dev/null || true
    wait "$qpid" 2>/dev/null || true
    rc=0
    break
  fi
  if ! kill -0 "$qpid" 2>/dev/null; then
    wait "$qpid" 2>/dev/null
    rc=$?
    break
  fi
  sleep 0.5
done
[ "$rc" -eq 0 ] || kill "$qpid" 2>/dev/null || true

clean=$(sed -E 's/\x1B\[[0-9;]*[mK]//g' "$LOG")
# quickshell can re-instantiate the config after Qt.quit() (a second
# onCompleted), so only the first run — up to the first LAD-SUMMARY line —
# is canonical.
first=$(echo "$clean" | sed '/LAD-SUMMARY/ q')
p=$(echo "$first" | grep -c "LAD-PASS" || true)
f=$(echo "$first" | grep -c "LAD-FAIL" || true)
summary=$(echo "$clean" | grep "LAD-SUMMARY" | head -1 | sed 's/.*LAD-SUMMARY:/LAD-SUMMARY:/')
if [ -z "$summary" ]; then
  echo "  $name: NO-SUMMARY (rc=$rc) - harness crashed or timed out"
  echo "$clean" | grep -iE "LOAD-ERROR|error|failed|ReferenceError|module .* is not installed" | head -6
  exit 1
fi
echo "  $name: $summary (pass=$p fail=$f)"
# quickshell exits nonzero after Qt.quit() with no receiver, so the summary is
# the source of truth; only print failures.
[ "$f" -eq 0 ]