#!/usr/bin/env bats
# Documentation guards. The plan's P9 batch renamed four documents and deleted a
# fifth; every check here exists because the corresponding breakage was silent.
# A broken link, a renamed file still named in prose, a stale constant list and a
# duplicated heading all pass every lexical check that does not look for exactly
# them — so each is its own test, and each names what it found.

load "$BATS_TEST_DIRNAME/../lib/helpers.bash"

# Files that are documentation proper (READMEs and docs/). The concern/plan files
# are deliberately excluded from the filename guard: they are the record OF the
# rename and must be free to name the old paths.
doc_files() {
  echo "$REPO_ROOT/README.md"
  echo "$T/README.md"
  find "$REPO_ROOT/docs" -maxdepth 1 -name '*.md' | sort
}

# Everything a link may point at, for the resolver.
all_link_files() {
  doc_files
  echo "$REPO_ROOT/big-pickle-full-plan.md"
  find "$REPO_ROOT" -maxdepth 1 -name 'concern-*.md' | sort
}

# Emit "BROKEN <source>:<line> -> <target>" for every unresolved relative link.
# A broken ANCHOR is reported the same way: GitHub deletes punctuation and
# replaces each space individually, so a collapsing checker would call the
# plan's own double-hyphen anchors dead.
check_links() {
  REPO_ROOT="$REPO_ROOT" ALL_FILES="$(all_link_files)" python3 - <<'PY'
import os, re, sys

repo = os.environ["REPO_ROOT"]
sources = [l for l in os.environ["ALL_FILES"].splitlines() if l]

def slug(text):
    t = text.strip().lower()
    t = re.sub(r'\[([^\]]*)\]\([^)]*\)', r'\1', t)   # [txt](url) -> txt
    t = t.replace('`', '')
    t = re.sub(r'[*~]', '', t)                       # emphasis, but KEEP underscores
    t = re.sub(r'[^\w\- ]', '', t)                   # drop punctuation, keep spaces
    return t.replace(' ', '-')

def slugs(path):
    out, seen = set(), {}
    try:
        lines = open(path, encoding='utf-8').read().splitlines()
    except OSError:
        return out
    for line in lines:
        m = re.match(r'^#{1,6}\s+(.*?)\s*#*\s*$', line)
        if not m:
            continue
        base = slug(m.group(1))
        n = seen.get(base, 0)
        seen[base] = n + 1
        out.add(base if n == 0 else "%s-%d" % (base, n))
    return out

cache = {}
def get_slugs(path):
    if path not in cache:
        cache[path] = slugs(path)
    return cache[path]

link_re = re.compile(r'\[[^\]]*\]\(([^)\s]+)(?:\s+"[^"]*")?\)')
broken = []
for src in sources:
    try:
        lines = open(src, encoding='utf-8').read().splitlines()
    except OSError:
        continue
    for i, line in enumerate(lines, 1):
        for target in link_re.findall(line):
            if re.match(r'^(https?:|mailto:|tel:)', target):
                continue
            path, _, anchor = target.partition('#')
            if path == '':
                dest = src
            else:
                dest = os.path.normpath(os.path.join(os.path.dirname(src), path))
            if not os.path.exists(dest):
                broken.append((src, i, target, "file"))
                continue
            if anchor and dest.endswith('.md'):
                if anchor not in get_slugs(dest):
                    broken.append((src, i, target, "anchor"))

for src, i, target, kind in broken:
    print("BROKEN [%s] %s:%d -> %s" % (kind, os.path.relpath(src, repo), i, target))
sys.exit(1 if broken else 0)
PY
}

@test "docs-links-resolve" {
  run check_links
  [ "$status" -eq 0 ] || {
    echo "$output" >&3
    false
  }
}

@test "docs-no-broken-links" {
  run check_links
  [ "$status" -eq 0 ] || {
    echo "$output" >&3
    false
  }
}

@test "docs-no-stale-filenames" {
  # The four renamed/deleted documents. The leading class excludes the correct
  # names that merely END in the stale stem (e.g. llama-service-field-matrix.md).
  local hits
  hits=$(grep -rnE '(^|[^a-z-])(change-plan|concepts-of-a-plan|llama-service-tiers|field-matrix)\.md' \
    $(doc_files) 2>/dev/null || true)
  if [ -n "$hits" ]; then
    echo "$hits" >&3
    false
  fi
}

@test "docs-dumped-constants-complete" {
  # Both directions: every name the dumper exports must be in the prose list, and
  # the prose must not name one the dumper does not. Either half can rot alone.
  local dumped documented
  dumped=$( { grep -A 8 'var names = \[' "$T/support/dump_constants.qml" \
    | grep -oE '"[A-Za-z]+"' | tr -d '"'; \
    # userUnitDir is dumped separately at the bottom of the harness, not in the
    # names array; the prose list documents the full set, so the union is right.
    echo userUnitDir; } | sort -u)
  documented=$(sed -n '/^Dumped constants:/,/^Every bats test/p' "$T/README.md" \
    | grep -oE '`[A-Za-z]+`' | tr -d '`' | sort -u)
  local missing_from_prose missing_from_dumper
  missing_from_prose=$(comm -23 <(echo "$dumped") <(echo "$documented"))
  missing_from_dumper=$(comm -13 <(echo "$dumped") <(echo "$documented"))
  if [ -n "$missing_from_prose" ] || [ -n "$missing_from_dumper" ]; then
    echo "not in tests/README.md: $missing_from_prose" >&3
    echo "not in dump_constants.qml: $missing_from_dumper" >&3
    false
  fi
}

@test "docs-no-duplicate-headings" {
  # Structural damage is invisible to a link check — the P7 README rewrite left
  # an orphaned half-section whose every link was valid. Two guards: no heading
  # repeats within one file, and no >90-char line repeats outside a table.
  local bad=""
  local f
  for f in $(doc_files); do
    local dup
    dup=$(grep -E '^#{2,3} ' "$f" | sort | uniq -d)
    [ -z "$dup" ] || bad="$bad\n[$f] duplicate heading(s): $dup"
    local longdup
    longdup=$(grep -vE '^\s*\|' "$f" | awk 'length > 90' | sort | uniq -d)
    [ -z "$longdup" ] || bad="$bad\n[$f] duplicate long line(s)"
  done
  if [ -n "$bad" ]; then
    echo -e "$bad" >&3
    false
  fi
}

@test "docs-tier-refs-exist" {
  # Every `_functionName()` cited in the tier docs must be defined in Service.qml,
  # so a renamed function cannot leave a doc describing behavior that no longer
  # exists.
  local cited undefined=""
  cited=$(grep -rhoE '`_[a-zA-Z0-9]+\(\)`' "$REPO_ROOT/docs"/*.md \
    | tr -d '`()' | sort -u)
  local fn
  for fn in $cited; do
    grep -q "function $fn" "$REPO_ROOT/Service.qml" || undefined="$undefined\n$fn"
  done
  if [ -n "$undefined" ]; then
    echo -e "not in Service.qml:$undefined" >&3
    false
  fi
}

@test "docs-counts-current" {
  # A stated number is stale the moment a test lands. Derive every count from the
  # tree and assert both READMEs carry it, so the friction of a new test is one
  # README line rather than a number nobody notices went wrong.
  local unit e2e bats_files bats_tests unit_asserts e2e_asserts
  unit=$(ls "$T"/unit_tests/*.qml | wc -l)
  e2e=$(ls "$T"/e2e_tests/*.qml | wc -l)
  bats_files=$(ls "$T"/integration_tests/*.bats | wc -l)
  bats_tests=$(grep -rho '^@test' "$T"/integration_tests/*.bats | wc -l)
  unit_asserts=$(grep -rhoE 'A\.(check|ok|notok|fail)\(' "$T"/unit_tests/*.qml | wc -l)
  e2e_asserts=$(grep -rhoE 'A\.(check|ok|notok|fail)\(' "$T"/e2e_tests/*.qml | wc -l)
  local bad=""
  grep -qE "${unit} QML harnesses \(${unit_asserts} assertions\)" "$REPO_ROOT/README.md" \
    || bad="$bad\nREADME.md: unit harness/assertion count"
  grep -qE "${bats_files} BATS files \(${bats_tests} tests\)" "$REPO_ROOT/README.md" \
    || bad="$bad\nREADME.md: BATS file/test count"
  grep -qE "${e2e} sandbox lifecycle harnesses \(${e2e_asserts} assertions\)" "$REPO_ROOT/README.md" \
    || bad="$bad\nREADME.md: e2e harness/assertion count"
  grep -qE "${unit} quickshell harnesses \(${unit_asserts} assertions\)" "$T/README.md" \
    || bad="$bad\ntests/README.md: unit harness/assertion count"
  grep -qE "${bats_files} bats files \(${bats_tests} tests\)" "$T/README.md" \
    || bad="$bad\ntests/README.md: BATS file/test count"
  grep -qE "${e2e} sandbox harnesses \(${e2e_asserts} assertions\)" "$T/README.md" \
    || bad="$bad\ntests/README.md: e2e harness/assertion count"
  if [ -n "$bad" ]; then
    echo -e "stale count line(s):$bad" >&3
    echo "derived: unit=$unit/$unit_asserts e2e=$e2e/$e2e_asserts bats=$bats_files/$bats_tests" >&3
    false
  fi
}
