load "$BATS_TEST_DIRNAME/../lib/helpers.bash"

# Integration: the createEnvScript writes the llama.env environment file with
# the same create-only/atomic/0600 guarantees, expanding $HOME at write time.
setup()   { sandbox_setup; }
teardown() { [ "$FAIL" -eq 0 ]; sandbox_teardown; }

@test "env writer: creates 0600 file with sandbox HOME baked in" {
  export HOME="$SB/home"
  run run_script "$CE" "$SB/cfg/llama.env"
  [ "$status" -eq 0 ]
  [ -f "$SB/cfg/llama.env" ]
  expect_perms 600 "$SB/cfg/llama.env" "created perms"
  grep -q "LLAMA_HOST=127.0.0.1" "$SB/cfg/llama.env"
  grep -q "LLAMA_MODELS_PRESET=\"$SB/home/.config/llama.cpp/models.ini\"" "$SB/cfg/llama.env"
  expect_no_file "$SB/cfg/.llama.env."*
}

@test "env writer: existing target -> exit 4, content untouched" {
  printf 'KEEP\n' > "$SB/cfg/llama.env"
  run run_script "$CE" "$SB/cfg/llama.env"
  [ "$status" -eq 4 ]
  [ "$(cat "$SB/cfg/llama.env")" = 'KEEP' ]
}

@test "env writer: parent dir is a symlink -> exit 55, nothing written" {
  mkdir -p "$SB/cfg/real"
  ln -s "$SB/cfg/real" "$SB/cfg/linkdir"
  run run_script "$CE" "$SB/cfg/linkdir/llama.env"
  [ "$status" -eq 55 ]
  expect_no_file "$SB/cfg/real/llama.env"
}

@test "env writer: target is a symlink pointing elsewhere -> exit 4, never chmods through" {
  printf 'victim\n' > "$SB/cfg/victim"
  chmod 644 "$SB/cfg/victim"
  ln -s "$SB/cfg/victim" "$SB/cfg/llama.env"
  run run_script "$CE" "$SB/cfg/llama.env"
  [ "$status" -eq 4 ]
  expect_perms 644 "$SB/cfg/victim" "victim perms unchanged"
}

@test "env writer: no temp files survive" {
  run_script "$CE" "$SB/cfg/llama.env"
  left=$(ls -a "$SB/cfg" | grep -E "\.llama\.env\..*XXXXXX" || true)
  [ -z "$left" ]
}