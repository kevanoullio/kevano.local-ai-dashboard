load "$BATS_TEST_DIRNAME/../lib/helpers.bash"

# Integration: the bounded models.ini preset read (modelsIniScript, Tier 5).
# It must emit normalized `[section]`/`key=value` lines — preserving the
# model-path section keys + the reserved [*] globals block, stripping
# #/; comments and whitespace — and refuse symlinks / missing files by
# emitting nothing (the QML side then no-ops back to the lower tiers).

setup()   { sandbox_setup; }
teardown() { [ "$FAIL" -eq 0 ]; sandbox_teardown; }

@test "models.ini reader: globals + path-keyed sections + comments + whitespace + quoted/`$HOME` values" {
  cat > "$SB/home/models.ini" <<'EOF'
[*]
fit = on
cache-type-k = q8_0

  ; invisible comment
# full-line comment

[/home/u/models/a.gguf]
model = $HOME/models/a.gguf
n-gpu-layers = all

[ /m/b.gguf ]
model = "/m/b.gguf"
n-gpu-layers = 30
ctx-size   =   262144
EOF
  run run_script "$MI" "$SB/home/models.ini" 16384
  [ "$status" -eq 0 ]
  # Globals block survives, values normalized (spaces stripped around `=`).
  [[ "$output" == *"[*]"* ]]
  [[ "$output" == *"fit=on"* ]]
  [[ "$output" == *"cache-type-k=q8_0"* ]]
  # Path-keyed section: the file path is a KEY, not a comment — it survives.
  [[ "$output" == *"[/home/u/models/a.gguf]"* ]]
  [[ "$output" == *'model=$HOME/models/a.gguf'* ]]
  [[ "$output" == *"n-gpu-layers=all"* ]]
  # Leading/trailing whitespace in a section header is normalized away.
  [[ "$output" == *"[/m/b.gguf]"* ]]
  [[ "$output" == *'model="/m/b.gguf"'* ]]
  [[ "$output" == *"n-gpu-layers=30"* ]]
  [[ "$output" == *"ctx-size=262144"* ]]
  # Comments never leak into the output.
  [[ "$output" != *"comment"* ]]
}

@test "models.ini reader: missing file -> no output (exit 0)" {
  run run_script "$MI" "$SB/cfg/nonexistent.ini" 16384
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "models.ini reader: symlink -> refused, no output" {
  printf '[*]\nn-gpu-layers = all\n' > "$SB/cfg/real.ini"
  ln -s "$(realpath "$SB/cfg/real.ini")" "$SB/cfg/link.ini"
  run run_script "$MI" "$SB/cfg/link.ini" 16384
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "models.ini reader: output is bounded by the cap" {
  printf '[*]\nn-gpu-layers = all\nn-gpu-layers-2 = all\n' > "$SB/home/cap.ini"
  run run_script "$MI" "$SB/home/cap.ini" 8
  [ ${#output} -le 8 ]
}