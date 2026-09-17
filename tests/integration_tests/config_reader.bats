load "$BATS_TEST_DIRNAME/../lib/helpers.bash"

# Integration: the config reader (configScript) must distinguish real files from
# hostile paths (symlink/FIFO) and refuse without leaking contents, and cap its
# output. The reader never creates or overwrites content; its only write is an
# idempotent 0600 hardening of an existing regular file (it may hold a key).
setup()   { sandbox_setup; }
teardown() { [ "$FAIL" -eq 0 ]; sandbox_teardown; }

@test "config reader: regular file -> HAS + contents" {
  printf '{"host":"127.0.0.1"}' > "$SB/cfg/settings.json"
  run run_script "$CR" "$SB/cfg/settings.json" 2048
  [ "$status" -eq 0 ]
  [[ "$output" == HAS* ]]
  [[ "$output" == *'"host":"127.0.0.1"'* ]]
}

@test "config reader: missing file -> NO" {
  run run_script "$CR" "$SB/cfg/missing.json" 2048
  [ "$output" = "NO" ]
}

@test "config reader: symlink -> REFUSE (never follows the target)" {
  printf 'secret'\'' key\n' > "$SB/cfg/target"
  ln -s "$SB/cfg/target" "$SB/cfg/link.json"
  run run_script "$CR" "$SB/cfg/link.json" 2048
  [ "$output" = "REFUSE" ]
}

@test "config reader: FIFO -> REFUSE (no hang, no data)" {
  mkfifo "$SB/cfg/fifo.json"
  run run_script "$CR" "$SB/cfg/fifo.json" 2048
  [ "$output" = "REFUSE" ]
}

@test "config reader: output is bounded by the cap" {
  printf 'X%.0s' {1..400} > "$SB/cfg/big.env"
  run run_script "$CR" "$SB/cfg/big.env" 16
  [ ${#output} -le 16 ]
}

@test "config reader: existing regular file is hardened to 0600 (key-safe)" {
  printf '{"api-key":"k"}' > "$SB/cfg/perm.json"
  chmod 644 "$SB/cfg/perm.json"
  run run_script "$CR" "$SB/cfg/perm.json" 2048
  [ "$status" -eq 0 ]
  [[ "$output" == HAS* ]]
  expect_perms 600 "$SB/cfg/perm.json" "hardened-perms"
}

@test "config reader: a symlink is never chmodded through" {
  printf 'secret' > "$SB/cfg/target"
  chmod 644 "$SB/cfg/target"
  ln -s "$SB/cfg/target" "$SB/cfg/link.json"
  run run_script "$CR" "$SB/cfg/link.json" 2048
  [ "$output" = "REFUSE" ]
  expect_perms 644 "$SB/cfg/target" "target-untouched"
}