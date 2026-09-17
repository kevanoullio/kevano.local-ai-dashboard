# Shared helpers for the bats integration tests. Loaded via `load` from each
# *.bats file with `load "$BATS_TEST_DIRNAME/../lib/helpers.bash"`.

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
T="$REPO_ROOT/tests"
CONSTS="$T/.cache/consts"
MOCKS="$T/lib/mocks"

# ---- constant accessors (dumped by tests/run_all.sh beforehand) ---------
lconst() { cat "$CONSTS/$1.txt"; }
PROV="$(lconst provisionLlamaScript)"
CE="$(lconst createEnvScript)"
CR="$(lconst configScript)"
CW="$(lconst createConfigScript)"
UBODY="$(lconst llamaUnitBody)"

# ---- sandbox ------------------------------------------------------------
SB=""
MOCKLOG=""
FAIL=0

sandbox_setup() {
  FAIL=0
  SB=$(mktemp -d "$T/.cache/it.XXXXXX")
  mkdir -p "$SB/bin" "$SB/cfg" "$SB/ud" "$SB/home"
  cp "$MOCKS/systemctl" "$MOCKS/systemd-analyze" "$MOCKS/llama-server" "$SB/bin/"
  chmod +x "$SB/bin"/*
  MOCKLOG="$SB/mocklog"
  : > "$MOCKLOG"
  export __mocklog="$MOCKLOG"
  export PATH="$SB/bin:$PATH"
}

sandbox_teardown() { rm -rf "$SB"; }

reset_mocklog() { : > "$MOCKLOG"; }

mocklog_contains() { grep -q "$1" "$MOCKLOG"; }
mocklog_missing() { ! grep -q "$1" "$MOCKLOG"; }

# ---- script runners -----------------------------------------------------
# Run an extracted constant as `bash -c SCRIPT dash ARGS...`.
run_script() {
  local script=$1; shift
  bash -c "$script" dash "$@"
}

provision() { # consent
  bash -c "$PROV" dash "$SB/cfg/llama.env" "$SB/ud" llama-server "$1" 512
}

# Fabricate the expected unit with the same heredoc semantics as the
# provisioner: `$f` and `$abs` expand at write time in a child bash.
fab() {
  local f=$1 abs=$2
  { printf 'f="%s"; abs="%s"; cat <<UNIT\n' "$f" "$abs"; cat "$CONSTS/llamaUnitBody.txt"; printf 'UNIT\n'; } > "$SB/fab.sh"
  bash "$SB/fab.sh"
}

# Fabricate the exact unit the provisioner would write for this sandbox, into a
# file (command substitution would strip the trailing newline -> false mismatch).
fab_unit_file() { fab "$SB/cfg/llama.env" "$SB/bin/llama-server" > "$SB/expected-unit"; }

# ---- assertions ---------------------------------------------------------
expect_rc()    { local want=$1 got=$2 label=$3; [ "$got" -eq "$want" ] || { echo "  FAIL $label: rc=$got want=$want" >&3; FAIL=1; }; }
expect_eq()    { local want=$1 got=$2 label=$3; [ "$want" = "$got" ] || { echo "  FAIL $label: got=[$got] want=[$want]" >&3; FAIL=1; }; }
expect_file()  { [ -e "$1" ] || { echo "  FAIL: missing file $1" >&3; FAIL=1; }; }
expect_no_file() { [ ! -e "$1" ] || { echo "  FAIL: unexpected file $1" >&3; FAIL=1; }; }
expect_perms() { local p got; p=$1 f=$2 label=$3; got=$(stat -c %a "$f" 2>/dev/null); [ "$got" = "$p" ] || { echo "  FAIL $label: perms=$got want=$p" >&3; FAIL=1; }; }
expect_contains() { grep -q "$1" "$2" || { echo "  FAIL: [$2] lacks [$1]" >&3; FAIL=1; }; }
expect_grep()   { grep -q "$1" "$2" || { echo "  FAIL: [$2] lacks [$1]" >&3; FAIL=1; }; }
expect_no_grep() { ! grep -q "$1" "$2" || { echo "  FAIL: [$2] unexpectedly contains [$1]" >&3; FAIL=1; } }