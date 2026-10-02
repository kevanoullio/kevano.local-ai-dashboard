load "$BATS_TEST_DIRNAME/../lib/helpers.bash"

# Integration: the tier-5 projection wrapper (kvFitScript). Two things matter and
# both are pinned here against the EXACT string the panel runs:
#
#  1. The flags that must never vary — `--fit off --fit-print on -ngl N` — live in
#     the script rather than in the QML argv, so a byte-comparison is enough.
#     `--fit off` is load-bearing: with the default (`on`) the tool CHOOSES an
#     offload count against `-fitt`'s margin, and tier 5 would be a fit-decider
#     instead of a decomposer.
#  2. The model path is one quoted positional. A path containing spaces, `;` or
#     backticks must stay a single argument and execute nothing.
#
# These tests run against a STUB, not the real llama-fit-params, so they assert
# the wrapper's contract. The real tool's output format is pinned separately, by
# the committed golden fixture in tests/fixtures/fit_params/ and the fit/parse-*
# unit group.
setup()   { sandbox_setup; }
teardown() { [ "$FAIL" -eq 0 ]; sandbox_teardown; }

# A stand-in for llama-fit-params: `--help` succeeds, and a real run echoes its
# argv one per line exactly as the tool would print device rows.
fake_fit() {
  cat > "$SB/bin/fake-fit-params" <<'SH'
#!/bin/bash
case "$1" in
  --help) echo "usage: llama-fit-params [options]"; exit 0 ;;
esac
echo "ARGC=$#"
for a in "$@"; do echo "ARG=$a"; done
echo "CUDA0 8692 767 551 "
echo "Host 5915 470 62 "
SH
  chmod +x "$SB/bin/fake-fit-params"
}

# Run the wrapper the way Service.qml does:
#   bash -c kvFitScript dash <binary> <ngl> <model> <argv...>
run_fit() {
  local bin="$1" ngl="$2" model="$3"; shift 3
  run run_script "$KF" "$SB/bin/$bin" "$ngl" "$model" "$@"
}

@test "fit wrapper: passes --fit off --fit-print on and the supplied -ngl" {
  fake_fit
  run_fit fake-fit-params 40 /m/a.gguf -ctk q8_0 -ctv q8_0 -c 32768
  [ "$status" -eq 0 ]
  # The wrapper's own fixed flags are NOT in the caller's argv, so they can only
  # come from the script.
  [[ "$output" == *"ARG=--fit"* ]]
  [[ "$output" == *"ARG=off"* ]]
  [[ "$output" == *"ARG=--fit-print"* ]]
  [[ "$output" == *"ARG=on"* ]]
  [[ "$output" == *"ARG=-ngl"* ]]
  [[ "$output" == *"ARG=40"* ]]
  # ...and they appear exactly once each. `shift 3` is what keeps the wrapper from
  # re-emitting its own leading arguments.
  [ "$(grep -c '^ARG=--fit$' <<<"$output")" -eq 1 ]
  [ "$(grep -c '^ARG=-ngl$' <<<"$output")" -eq 1 ]
}

@test "fit wrapper: the caller's argv follows the three fixed positionals" {
  fake_fit
  run_fit fake-fit-params 0 /m/a.gguf -ctk q8_0
  [ "$status" -eq 0 ]
  # ARGC = 4 fixed (-ngl N -m path) + 4 fixed (--fit off --fit-print on) + 2 caller
  [[ "$output" == *"ARGC=10"* ]]
  [[ "$output" == *"ARG=/m/a.gguf"* ]]
  [[ "$output" == *"ARG=-ctk"* ]]
  [[ "$output" == *"ARG=q8_0"* ]]
}

@test "fit wrapper: a hostile model path stays one argument" {
  fake_fit
  run_fit fake-fit-params 20 '/models/with space/and;semicolon.gguf' -c 4096
  [ "$status" -eq 0 ]
  [[ "$output" == *"ARG=/models/with space/and;semicolon.gguf"* ]]
  [ ! -e pwned ]
  [ ! -e "$SB/pwned" ]
}

@test "fit wrapper: a command-substitution path executes nothing" {
  fake_fit
  run_fit fake-fit-params 20 '/m/$(touch pwned).gguf'
  [ "$status" -eq 0 ]
  [[ "$output" == *'ARG=/m/$(touch pwned).gguf'* ]]
  [ ! -e pwned ]
  [ ! -e "$SB/pwned" ]
}

@test "fit wrapper: a backticked path executes nothing" {
  fake_fit
  run_fit fake-fit-params 20 '/m/`touch pwned`.gguf'
  [ "$status" -eq 0 ]
  [[ "$output" == *'ARG=/m/`touch pwned`.gguf'* ]]
  [ ! -e pwned ]
  [ ! -e "$SB/pwned" ]
}

@test "fit wrapper: a missing binary exits 97, not 98" {
  # 97 is permanent ("the tool is not installed" — cache it and stop trying).
  # 98 belongs to kvProbeScript and means "skipped, retry when memory frees", so
  # the two must never collide: conflating them would make a machine without
  # llama-fit-params respawn a process per model per refresh, forever.
  run run_script "$KF" "$SB/bin/not-installed" 20 /m/a.gguf
  [ "$status" -eq 97 ]
  [[ "$output" == *"kvfit: binary unavailable"* ]]
}

@test "fit wrapper: a non-executable binary exits 97" {
  printf '#!/bin/bash\nexit 0\n' > "$SB/bin/not-executable"
  chmod -x "$SB/bin/not-executable"
  run run_script "$KF" "$SB/bin/not-executable" 20 /m/a.gguf
  [ "$status" -eq 97 ]
}

@test "fit wrapper: an installed binary whose --help fails exits 97" {
  # `--help` is the only availability question this tool answers truthfully: a
  # no-arg run exits 1 with `error: --model is required` on stderr and empty
  # stdout, so "run it and look for exit 0" reports absent on every machine.
  printf '#!/bin/bash\nexit 3\n' > "$SB/bin/broken-help"
  chmod +x "$SB/bin/broken-help"
  run run_script "$KF" "$SB/bin/broken-help" 20 /m/a.gguf
  [ "$status" -eq 97 ]
}

# --- the real tool, when it is installed -----------------------------------
# These pin the tool's OWN behaviour, which is what the plan's §9.2 asks for.
# Skipped (not faked) where the binary is absent, so the suite stays honest on a
# machine without llama.cpp.
fit_installed() { [ -x /usr/bin/llama-fit-params ]; }

@test "fit-params: --help exits 0" {
  fit_installed || skip "llama-fit-params not installed"
  run /usr/bin/llama-fit-params --help
  [ "$status" -eq 0 ]
  # The usage text is llama.cpp's shared "common params" block, so the tool's own
  # name never appears in it -- what identifies it is --fit-print, which only this
  # binary has.
  [[ "$output" == *"--fit-print"* ]]
}

@test "fit-params: no --model exits 1 with the error on stderr and empty stdout" {
  fit_installed || skip "llama-fit-params not installed"
  run bash -c '/usr/bin/llama-fit-params 2>/tmp/fit_err.$$ >/tmp/fit_out.$$; echo "exit=$?"; echo "OUT=$(wc -c </tmp/fit_out.$$)"; grep -c "model is required" /tmp/fit_err.$$; rm -f /tmp/fit_err.$$ /tmp/fit_out.$$'
  [[ "$output" == *"exit=1"* ]]
  [[ "$output" == *"OUT=0"* ]]
  [[ "$output" == *"1"* ]]
}

@test "fit-params: accepts --fit off" {
  fit_installed || skip "llama-fit-params not installed"
  run /usr/bin/llama-fit-params --fit off --help
  [ "$status" -eq 0 ]
}

@test "fit-params: accepts --fit-print on" {
  fit_installed || skip "llama-fit-params not installed"
  run /usr/bin/llama-fit-params --fit-print on --help
  [ "$status" -eq 0 ]
}

@test "fit-params: rejects an invalid -ctk value itself" {
  # The panel drops unsupported dtypes before the run, so this rejection is the
  # tool's, not ours — and it is why dropping them is better than passing them.
  fit_installed || skip "llama-fit-params not installed"
  run /usr/bin/llama-fit-params --fit off --fit-print on -ngl 0 -m /nonexistent.gguf -ctk notatype
  [ "$status" -ne 0 ]
  [[ "$output" != *"CUDA"* ]]
}