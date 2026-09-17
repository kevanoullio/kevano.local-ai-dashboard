load "$BATS_TEST_DIRNAME/../lib/helpers.bash"

# Integration: the provision script's dry-run / consent / create lifecycle.
# "provision 0" = no consent (dry-run), "provision 1" = consent to change the unit.
# The binary under test is our llama-server mock, so command -v is machine-independent.
setup()   { sandbox_setup; }
teardown() { [ "$FAIL" -eq 0 ]; sandbox_teardown; }

@test "provision: first-run dry-run -> 64, env 0600 only, no unit, no start" {
  export HOME="$SB/home"
  run provision 0
  [ "$status" -eq 64 ]
  [[ "$output" == *SERVICE-UPDATE-REQUIRED* ]]
  [ -f "$SB/cfg/llama.env" ]
  expect_perms 600 "$SB/cfg/llama.env" "env perms"
  expect_no_file "$SB/ud/llama.cpp.service"
  expect_no_grep "start llama.cpp.service" "$SB/mocklog" "dry run must not start"
}

@test "provision: consented create -> exit 0, unit 0644 matches fabricated unit" {
  export HOME="$SB/home"
  run provision 1
  [ "$status" -eq 0 ]
  [ -f "$SB/ud/llama.cpp.service" ]
  expect_perms 644 "$SB/ud/llama.cpp.service" "unit perms"
  fab_unit_file
  cmp -s "$SB/ud/llama.cpp.service" "$SB/expected-unit"
  expect_grep "daemon-reload" "$SB/mocklog"
  expect_grep "start llama.cpp.service" "$SB/mocklog"
  expect_no_file "$SB/ud/.llama.cpp.service.bak"
}

@test "provision: identical unit -> direct start, no marker, no backup" {
  export HOME="$SB/home"
  provision 1 >/dev/null
  : > "$SB/mocklog"
  run provision 0
  [ "$status" -eq 0 ]
  [[ "$output" != *SERVICE-UPDATE-REQUIRED* ]]
  expect_grep "start llama.cpp.service" "$SB/mocklog"
  expect_no_grep "daemon-reload" "$SB/mocklog" "no reload on identical unit"
  expect_no_file "$SB/ud/.llama.cpp.service.bak"
}

@test "provision: differing unit -> dry-run 64, old unit preserved, no backup" {
  export HOME="$SB/home"
  provision 1 >/dev/null
  printf 'OLD-UNIT\n' > "$SB/ud/llama.cpp.service"
  : > "$SB/mocklog"
  run provision 0
  [ "$status" -eq 64 ]
  [ "$(cat "$SB/ud/llama.cpp.service")" = 'OLD-UNIT' ]
  expect_no_file "$SB/ud/.llama.cpp.service.bak"
  expect_no_grep "start llama.cpp.service" "$SB/mocklog"
}

@test "provision: existing env with weak perms is hardened to 0600 on start" {
  export HOME="$SB/home"
  provision 1 >/dev/null
  chmod 644 "$SB/cfg/llama.env"
  run provision 0
  [ "$status" -eq 0 ]
  expect_perms 600 "$SB/cfg/llama.env" "family perms"
}

@test "provision: no temp or backup leftovers after a full lifecycle" {
  export HOME="$SB/home"
  provision 0 >/dev/null || :
  provision 1 >/dev/null
  left=$(find "$SB/cfg" "$SB/ud" \( -name '*XXXXXX*' -o -name '*.bak' \) 2>/dev/null | head -1)
  [ -z "$left" ]
}