load "$BATS_TEST_DIRNAME/../lib/helpers.bash"

# Integration: rollback safety for the provisioning script. Whenever anything
# can go wrong post-consent, the end state must be exactly the pre-run state.
setup()   { sandbox_setup; }
teardown() { [ "$FAIL" -eq 0 ]; sandbox_teardown; }

@test "rollback: start fails after unit replace -> 63, old unit restored, bak cleaned" {
  export HOME="$SB/home"
  provision 1 >/dev/null
  printf 'OLD-UNIT\n' > "$SB/ud/llama.cpp.service"
  FAIL_START=1 run provision 1
  [ "$status" -eq 63 ]
  [ "$(cat "$SB/ud/llama.cpp.service")" = 'OLD-UNIT' ]
  expect_no_file "$SB/ud/.llama.cpp.service.bak"
}

@test "rollback: first-time start fails -> 63, fresh unit removed, no bak" {
  export HOME="$SB/home"
  FAIL_START=1 run provision 1
  [ "$status" -eq 63 ]
  expect_no_file "$SB/ud/llama.cpp.service"
  expect_no_file "$SB/ud/.llama.cpp.service.bak"
}

@test "rollback: systemd-analyze rejects unit -> 62 before any swap" {
  export HOME="$SB/home"
  provision 1 >/dev/null
  printf 'BAD-UNIT\n' > "$SB/ud/llama.cpp.service"
  : > "$SB/mocklog"
  FAIL_VERIFY=1 run provision 1
  [ "$status" -eq 62 ]
  [ "$(cat "$SB/ud/llama.cpp.service")" = 'BAD-UNIT' ]
  expect_no_file "$SB/ud/.llama.cpp.service.bak"
  expect_no_grep "start llama.cpp.service" "$SB/mocklog" "no start after failed verify"
}

@test "rollback: lock already held -> 60, nothing touched" {
  export HOME="$SB/home"
  exec 9>>"$SB/ud/.local-ai-dashboard.lock"
  flock -n 9
  run provision 0
  rc=$status
  flock -u 9
  exec 9>&-
  [ "$rc" -eq 60 ]
  expect_no_file "$SB/ud/llama.cpp.service"
}

@test "unsafe unit dir is a symlink -> 58, no unit written" {
  mkdir -p "$SB/ud/real" "$SB/home"
  ln -s "$SB/ud/real" "$SB/ud/link"
  run run_script "$PROV" "$SB/cfg/llama.env" "$SB/ud/link" llama-server 0 512
  [ "$status" -eq 58 ]
  expect_no_file "$SB/ud/real/llama.cpp.service"
}

@test "env parent dir is a symlink -> 55, nothing written" {
  mkdir -p "$SB/cfg/real"
  ln -s "$SB/cfg/real" "$SB/cfg/linkdir"
  run run_script "$PROV" "$SB/cfg/linkdir/llama.env" "$SB/ud" llama-server 0 512
  [ "$status" -eq 55 ]
  expect_no_file "$SB/cfg/real/llama.env"
  expect_no_file "$SB/ud/llama.cpp.service"
}

@test "env target is a symlink -> 55, never chmod through, never replaced" {
  printf 'victim\n' > "$SB/cfg/victim"
  chmod 644 "$SB/cfg/victim"
  ln -s "$SB/cfg/victim" "$SB/cfg/llama.env"
  run run_script "$PROV" "$SB/cfg/llama.env" "$SB/ud" llama-server 0 512
  [ "$status" -eq 55 ]
  expect_perms 644 "$SB/cfg/victim" "victim perms unchanged"
  [ "$(cat "$SB/cfg/victim")" = 'victim' ]
}

@test "env target is a FIFO -> 55 without hanging" {
  mkfifo "$SB/cfg/llama.env"
  run run_script "$PROV" "$SB/cfg/llama.env" "$SB/ud" llama-server 0 512
  [ "$status" -eq 55 ]
}

@test "binary missing -> 40 before any writes" {
  run run_script "$PROV" "$SB/cfg/llama.env" "$SB/ud" no-such-binary 0 512
  [ "$status" -eq 40 ]
  expect_no_file "$SB/cfg/llama.env"
  expect_no_file "$SB/ud/llama.cpp.service"
}