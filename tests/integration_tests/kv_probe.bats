load "$BATS_TEST_DIRNAME/../lib/helpers.bash"

# Integration: the KV-accounting probe wrapper (kvProbeScript). It is the only
# part of the dashboard that execs a second llama.cpp process, so the two things
# that matter are pinned here: it must pass the engine's argv through untouched
# (an engine whose flags silently change would silently change the answer), and
# it must cap address space so a cache bigger than RAM fails fast instead of
# driving the machine into swap.
setup()   { sandbox_setup; }
teardown() { [ "$FAIL" -eq 0 ]; sandbox_teardown; }

# A stand-in for llama-cli: echoes its argv one per line, plus its own
# address-space limit and the machine's available memory.
fake_cli() {
  cat > "$SB/bin/fake-llama-cli" <<'SH'
#!/bin/bash
echo "ARGC=$#"
for a in "$@"; do echo "ARG=$a"; done
if [ "$(ulimit -v)" = "unlimited" ]; then echo "AS_LIMIT_KB=unlimited"; else echo "AS_LIMIT_KB=$(ulimit -v)"; fi
echo "MEM_AVAILABLE_KB=$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)"
SH
  chmod +x "$SB/bin/fake-llama-cli"
}

# Run the wrapper the way Service.qml does:
#   bash -c KVPROBE dash <cli> <modelBytes> <kvGuessBytes> <argv...>
run_probe() {
  local cli="$1" mbytes="$2" kbytes="$3"; shift 3
  run run_script "$KP" "$SB/bin/$cli" "$mbytes" "$kbytes" "$@"
}

@test "kv probe wrapper: passes the engine argv through unchanged" {
  fake_cli
  run_probe fake-llama-cli 1000 2000 \
    -m "/models/with space/and;semicolon.gguf" -c 262144 -ngl 0 --verbose \
    --cache-type-k q8_0 --cache-type-v q8_0
  [ "$status" -eq 0 ]
  [[ "$output" == *"ARGC=11"* ]]
  [[ "$output" == *"ARG=-m"* ]]
  # A model path is one argument, however hostile it looks: nothing is
  # word-split, glob-expanded or re-parsed as shell.
  [[ "$output" == *"ARG=/models/with space/and;semicolon.gguf"* ]]
  [[ "$output" == *"ARG=--cache-type-v"* ]]
  [[ "$output" == *"ARG=262144"* ]]
}

@test "kv probe wrapper: a hostile model path cannot run a command" {
  fake_cli
  run_probe fake-llama-cli 1000 0 -m '/m/$(touch pwned).gguf' -ngl 0
  [ "$status" -eq 0 ]
  [[ "$output" == *"ARG=/m/\$(touch pwned).gguf"* ]]
  [ ! -e pwned ]
  [ ! -e "$SB/pwned" ]
}

@test "kv probe wrapper: a request that fits runs, uncapped" {
  fake_cli
  # 1 GiB model + 512 MiB cache + 2 GiB slack, against whatever the host has.
  # The engine must see NO address-space limit: `ulimit -v` caps virtual
  # address space, which llama.cpp's GPU backends reserve far beyond its
  # working set, and capping it broke a real 14.2 GB gemma-4 load on a machine
  # with 40 GiB free ("mmap failed: Cannot allocate memory").
  run_probe fake-llama-cli 1073741824 536870912 -m /m/a.gguf
  [ "$status" -eq 0 ]
  [[ "$output" == *"ARGC=2"* ]]
  [ "$(sed -n 's/^AS_LIMIT_KB=//p' <<< "$output")" = "unlimited" ]
}

@test "kv probe wrapper: refuses a request that cannot fit, without running it" {
  fake_cli
  # A 2 TiB model is not going to be mapped. The wrapper must not even start the
  # engine: exit 98 is recorded as "no answer" and the header derivation answers,
  # instead of leaving a 2 TiB load to the OOM killer.
  run_probe fake-llama-cli 2199023255552 0 -m /m/huge.gguf
  [ "$status" -eq 98 ]
  [[ "$output" != *"ARGC="* ]]            # the engine never ran
  [[ "$output" == *"kvprobe: skipped"* ]]
}

@test "kv probe wrapper: a KV larger than RAM is refused before the engine runs" {
  fake_cli
  # Tiny model, enormous cache: the gate is the sum, so a context that would not
  # fit is refused just the same.
  local avail_gib
  avail_gib=$(awk '/^MemAvailable:/ { printf "%d", $2 / 1048576 }' /proc/meminfo)
  run_probe fake-llama-cli 1073741824 $(( avail_gib * 2 * 1073741824 )) -m /m/a.gguf
  [ "$status" -eq 98 ]
  [[ "$output" != *"ARGC="* ]]
}

@test "kv probe wrapper: a missing engine is a non-zero exit, not a hang" {
  # No `run` here: the exit status IS the assertion, and a failed `run` would
  # only add a bats-core BW01 warning on top of it.
  local rc=0
  bash -c "$KP" dash "$SB/bin/no-such-llama-cli" 1000 0 -m /m/a.gguf >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ]
}

@test "kv probe wrapper: the engine's own KV lines survive the wrapper" {
  # The parse in Service.qml keys on these exact prefixes; if the wrapper
  # swallowed or rewrote stdout the Tier-3.5 field would silently go unknown.
  cat > "$SB/bin/logging-llama-cli" <<'SH'
#!/bin/bash
cat >&2 <<'LOG'
0.00.532.354 D llama_kv_cache: layer   5: dev = CPU
0.00.546.243 I llama_kv_cache:        CPU KV buffer size =     0.00 MiB
0.00.546.246 I llama_kv_cache: size = 2720.00 MiB (262144 cells,   5 layers,  1/1 seqs), K (q8_0): 1360.00 MiB, V (q8_0): 1360.00 MiB
0.00.546.779 I llama_kv_cache: size =  159.38 MiB (  1536 cells,  25 layers,  1/1 seqs), K (q8_0):   79.69 MiB, V (q8_0):   79.69 MiB
0.00.552.030 I sched_reserve:      CUDA0 compute buffer size =  1887.86 MiB
LOG
SH
  chmod +x "$SB/bin/logging-llama-cli"
  run_probe logging-llama-cli 1000 0 -m /m/a.gguf
  [ "$status" -eq 0 ]
  [[ "$output" == *"llama_kv_cache: size = 2720.00 MiB"* ]]
  [[ "$output" == *"llama_kv_cache: size =  159.38 MiB"* ]]
  [[ "$output" == *"CUDA0 compute buffer size =  1887.86 MiB"* ]]
  # Two cache sizes + the per-layer dev lines + the compute reserve: the four
  # shapes Service._parseKvProbeLine is asked to read.
  [ "$(grep -c 'llama_kv_cache: size =' <<< "$output")" -eq 2 ]
  [ "$(grep -c 'dev = ' <<< "$output")" -eq 1 ]
}
