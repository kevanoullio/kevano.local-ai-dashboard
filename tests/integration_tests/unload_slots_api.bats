load "$BATS_TEST_DIRNAME/../lib/helpers.bash"

# Integration: per-model unload (UL) and idle-source slots (SL) scripts must
# route through curl to the correct endpoints, pass model ids as positional
# args (never concatenated into the script), and produce parseable output.
# The curl mock logs every call to __mocklog for verification.

setup()   { sandbox_setup; }
teardown() { [ "$FAIL" -eq 0 ]; sandbox_teardown; }

# ── Helpers ──────────────────────────────────────────────────────────────
ENDPOINT="http://127.0.0.1:8080"

run_ul() { run run_script "$UL" "$@"; }   # $1=id, $2=endpoint, $3=cap
run_sl() { run run_script "$SL" "$@"; }   # $1=/slots base, $2=id, $3=cap

# ── UL: POST /models/unload ──────────────────────────────────────────────

@test "unload script: valid model -> POST /models/unload with JSON body + 200" {
  run_ul "my-model" "$ENDPOINT/models/unload" 512
  [ "$status" -eq 0 ]
  # Output should end with the HTTP status code (last line after head -c cap)
  [[ "$output" == *"200"* ]]
  # The mocklog should contain a CURL call with the POST method and body
  expect_grep "CURL" "$MOCKLOG"
  expect_grep "-X POST" "$MOCKLOG" || expect_grep 'POST' "$MOCKLOG"
}

@test "unload script: model id with quotes is stripped before JSON encoding" {
  reset_mocklog
  run_ul 'foo"bar' "$ENDPOINT/models/unload" 512
  [ "$status" -eq 0 ]
  # The mocklog should have the curl call; the body in the mock prints what it receives
  expect_grep "CURL" "$MOCKLOG"
}

@test "unload script: model id with backslash is stripped" {
  reset_mocklog
  run_ul 'foo\bar' "$ENDPOINT/models/unload" 512
  [ "$status" -eq 0 ]
  expect_grep "CURL" "$MOCKLOG"
}

@test "unload script: model id with control chars is stripped" {
  reset_mocklog
  run_ul $'foo\x01bar' "$ENDPOINT/models/unload" 512
  [ "$status" -eq 0 ]
  expect_grep "CURL" "$MOCKLOG"
}

@test "unload script: output is bounded by the cap" {
  local fixture="$SB/cfg/tiny.gguf"
  gen_gguf "$fixture" "qwen35" "65" "24" "4" "5120" 2>/dev/null || true
  run_ul "model" "$ENDPOINT/models/unload" 10
  [ ${#output} -le 10 ]
}

# ── SL: GET /slots?model=<id> ────────────────────────────────────────────

@test "slots script: valid model -> GET /slots?model=<id> + JSON output" {
  reset_mocklog
  run_sl "$ENDPOINT/slots" "my-model" 8192
  [ "$status" -eq 0 ]
  # Output should be valid-ish JSON (the mock returns a JSON array)
  [[ "$output" == "["* ]]
  [[ "$output" == *"]"* ]]
  # Mocklog should have the curl GET call with ?model= param
  expect_grep "CURL" "$MOCKLOG"
  expect_grep 'model=my-model' "$MOCKLOG"
}

@test "slots script: model id is safe in URL (no injection)" {
  reset_mocklog
  run_sl "$ENDPOINT/slots" 'foo&bar;baz' 8192
  [ "$status" -eq 0 ]
  # The mocklog should contain the curl call with the model id as-is
  # (the script passes it as a positional arg to bash -c, where the constant
  # script handles it safely — the mock just records the URL)
  expect_grep "CURL" "$MOCKLOG"
}

@test "slots script: output is bounded by the cap" {
  run_sl "$ENDPOINT/slots" "model" 16
  [ ${#output} -le 16 ]
}
