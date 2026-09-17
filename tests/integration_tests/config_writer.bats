load "$BATS_TEST_DIRNAME/../lib/helpers.bash"

# Integration: the config writer (createConfigScript, used for ollama.json)
# must be create-only, symlink-refusing at the parent, atomic, and 0600.
setup()   { sandbox_setup; }
teardown() { [ "$FAIL" -eq 0 ]; sandbox_teardown; }

@test "config writer: creates a 0600 file with exact content, atomically" {
  run run_script "$CW" "$SB/cfg/out.json" '{"api-key":"x"}'
  [ "$status" -eq 0 ]
  [ -f "$SB/cfg/out.json" ]
  expect_perms 600 "$SB/cfg/out.json" "created perms"
  [ "$(cat "$SB/cfg/out.json")" = '{"api-key":"x"}' ]
  expect_no_file "$SB/cfg/.dashboard-config."*
}

@test "config writer: existing target -> exit 4, content untouched" {
  run_script "$CW" "$SB/cfg/out.json" '{"a":1}'
  run run_script "$CW" "$SB/cfg/out.json" '{"b":2}'
  [ "$status" -eq 4 ]
  [ "$(cat "$SB/cfg/out.json")" = '{"a":1}' ]
}

@test "config writer: parent dir is a symlink -> exit 55, nothing written" {
  mkdir -p "$SB/cfg/real"
  ln -s "$SB/cfg/real" "$SB/cfg/linkdir"
  run run_script "$CW" "$SB/cfg/linkdir/x.json" '{}'
  [ "$status" -eq 55 ]
  expect_no_file "$SB/cfg/real/x.json"
  expect_no_file "$SB/cfg/linkdir/x.json"
}

@test "config writer: no temp files survive" {
  run_script "$CW" "$SB/cfg/out.json" '{}'
  left=$(ls -a "$SB/cfg" | grep -E "\.dashboard-config\..*XXXXXX" || true)
  [ -z "$left" ]
}