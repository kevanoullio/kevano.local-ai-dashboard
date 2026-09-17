#!/bin/bash
# Extract the embedded bash constants from Service.qml into tests/.cache/consts/
# so integration tests execute the exact strings the panel ships. Single source
# of truth is Service.qml — nothing is duplicated. Exits nonzero if extraction
# fails (dump crash, missing marker, or unparseable value).
set -eu
T="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT="$(cd "$T/.." && pwd)"
LOG="$T/.cache/dump.log"
CONSTS="$T/.cache/consts"
mkdir -p "$CONSTS"

# Assemble a run dir ({dump.qml, Common, Ui}) so qs.Commons resolves for Service.
cp -r "$T/support/Common"* "$T/support/Ui" "$T/.cache/"
sed "s|@SERVICE_QML_PATH@|file://$ROOT/Service.qml|g" \
  < "$T/support/dump_constants.qml" > "$T/.cache/dump.qml"

QT_QPA_PLATFORM="${QT_QPA_PLATFORM:-offscreen}" timeout 60 quickshell -p "$T/.cache/dump.qml" > "$LOG" 2>&1 || true

python3 - "$LOG" "$CONSTS" <<'PY'
import json, re, sys
log, out = sys.argv[1], sys.argv[2]
data = re.sub(r"\x1b\[[0-9;]*m", "", open(log, errors="replace").read())
names = []
for m in re.finditer(r">>>DUMP:(\w+)<<<(.*?)>>>END<<<", data, re.S):
    name, body = m.group(1), m.group(2)
    quoted = re.search(r'"((?:[^"\\]|\\.)*)"', body)
    if not quoted:
        print(f"extract: {name} has no quoted value", file=sys.stderr)
        sys.exit(1)
    value = json.loads(quoted.group(0))
    if not isinstance(value, str):
        print(f"extract: {name} not a string", file=sys.stderr)
        sys.exit(1)
    open(f"{out}/{name}.txt", "w").write(value)
    names.append(name)
print(f"extract: {len(names)} constants -> {out}")
PY
if [ "$(grep -c '>>>DUMP:' "$LOG")" -eq 0 ]; then
  echo "extract: no dump markers found in output" >&2
  grep -iE "error|fail|LOAD" "$LOG" | head -5 >&2 || true
  exit 1
fi