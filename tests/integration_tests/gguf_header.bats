load "$BATS_TEST_DIRNAME/../lib/helpers.bash"

# Integration: the no-load GGUF header read (ggufScript) must correctly parse
# the binary metadata of a real GGUF file and emit the expected key=value lines.
# The fixture is generated on-the-fly via python3 so we never hard-code binary
# bytes — the generator is the single source of truth for the layout.

setup()   { sandbox_setup; }
teardown() { [ "$FAIL" -eq 0 ]; sandbox_teardown; }

# ── Helper: generate a minimal valid GGUF fixture ─────────────────────────
# $7 npl / $8 fai are optional (hybrid-attention keys); $9 file_type is an
# optional general.file_type (quantization) key; $10 vocab_slots, when > 0,
# inserts a large tokenizer.ggml.tokens array BEFORE general.file_type to mimic
# real llama.cpp ordering (file_type sits after the MB-sized vocab metadata).
# Any optional arg omitted → not written.
gen_gguf() {
  local out="$1" arch="$2" bc="$3" hc="$4" hckv="$5" embd="$6" npl="${7:-}" fai="${8:-}" ft="${9:-}" vocab="${10:-}"
  python3 - "$out" "$arch" "$bc" "$hc" "$hckv" "$embd" "$npl" "$fai" "$ft" "$vocab" <<'PY'
import struct, sys

out, arch, bc, hc, hckv, embd, npl, fai, ft, vocab = sys.argv[1:11]

def u32(v): return struct.pack('<I', int(v))
def u64(v): return struct.pack('<Q', int(v))
# GGUF string: u64 byte length + data (keys AND values).
def sval(s): d = s.encode('utf-8'); return u64(len(d)) + d
# GGUF array of strings: type ARRAY + elem type STRING + count + elements.
def astr(n, fill): return u32(9) + u32(8) + u64(n) + b''.join(sval(fill) for _ in range(n))

keys = [
    ('general.architecture', 8, sval(arch)),          # GGML_TYPE_STRING
    (arch + '.block_count', 4, u32(bc)),              # GGML_TYPE_I32
    (arch + '.attention.head_count', 4, u32(hc)),
    (arch + '.attention.head_count_kv', 4, u32(hckv)),
    (arch + '.embedding_length', 4, u32(embd)),
]
if npl: keys.append((arch + '.nextn_predict_layers', 4, u32(npl)))
if fai: keys.append((arch + '.full_attention_interval', 4, u32(fai)))
if vocab and int(vocab) > 0:
    keys.append(('tokenizer.ggml.tokens', 9, astr(int(vocab), 'f' * 240)))
if ft:  keys.append(('general.file_type', 4, u32(ft)))

with open(out, 'wb') as f:
    f.write(b'GGUF')                     # magic
    f.write(u32(3))                       # version
    f.write(u64(0))                       # n_tensors
    f.write(u64(len(keys)))              # n_metadata
    for k, t, v in keys:
        f.write(sval(k))
        f.write(u32(t))
        f.write(v)
PY
}

@test "gguf header reader: valid file -> GGUF-OK + arch/block_count/head_count/head_count_kv/embedding_length + file_type" {
  local fixture="$SB/cfg/tiny.gguf"
  gen_gguf "$fixture" "qwen35" "65" "24" "4" "5120" "1" "4" "15"
  run run_script "$GG" "$fixture" 512
  [ "$status" -eq 0 ]
  [[ "$output" == GGUF-OK* ]]
  [[ "$output" == *"arch=qwen35"* ]]
  [[ "$output" == *"block_count=65"* ]]
  [[ "$output" == *"head_count=24"* ]]
  [[ "$output" == *"head_count_kv=4"* ]]
  [[ "$output" == *"embedding_length=5120"* ]]
  [[ "$output" == *"nextn_predict_layers=1"* ]]
  [[ "$output" == *"full_attention_interval=4"* ]]
  [[ "$output" == *"file_type=15"* ]]
}

@test "gguf header reader: hybrid keys absent -> no key=value lines for them" {
  local fixture="$SB/cfg/tiny2.gguf"
  gen_gguf "$fixture" "phi3" "32" "24" "8" "3072"
  run run_script "$GG" "$fixture" 512
  [ "$status" -eq 0 ]
  [[ "$output" == GGUF-OK* ]]
  [[ "$output" == *"arch=phi3"* ]]
  [[ "$output" == *"block_count=32"* ]]
  [[ "$output" == *"head_count_kv=8"* ]]
  [[ "$output" != *"nextn_predict_layers"* ]]
  [[ "$output" != *"full_attention_interval"* ]]
  [[ "$output" != *"file_type"* ]]
}

@test "gguf header reader: file_type after a large vocab blob (real ordering)" {
  local fixture="$SB/cfg/tiny4.gguf"
  # 70 × 240-byte vocab tokens push general.file_type well past the 16 KiB
  # window of pass 1; the chunked follow-up scan must still report it.
  gen_gguf "$fixture" "qwen35" "65" "24" "4" "5120" "1" "4" "15" "70"
  run run_script "$GG" "$fixture" 512
  [ "$status" -eq 0 ]
  [[ "$output" == GGUF-OK* ]]
  [[ "$output" == *"arch=qwen35"* ]]
  [[ "$output" == *"block_count=65"* ]]
  [[ "$output" == *"file_type=15"* ]]
}

@test "gguf header reader: missing file -> GGUF-NO" {
  run run_script "$GG" "$SB/cfg/nonexistent.gguf" 512
  [ "$status" -eq 0 ]
  [[ "$output" == GGUF-NO* ]]
}

@test "gguf header reader: symlink -> GGUF-NO (refused)" {
  printf 'real content' > "$SB/cfg/real.gguf"
  ln -s "$(realpath "$SB/cfg/real.gguf")" "$SB/cfg/link.gguf"
  run run_script "$GG" "$SB/cfg/link.gguf" 512
  [ "$status" -eq 0 ]
  [[ "$output" == GGUF-NO* ]]
}

@test "gguf header reader: non-GGUF file -> GGUF-NO" {
  printf 'this is not a gguf file at all' > "$SB/cfg/not.gguf"
  run run_script "$GG" "$SB/cfg/not.gguf" 512
  [ "$status" -eq 0 ]
  [[ "$output" == GGUF-NO* ]]
}

@test "gguf header reader: output is bounded by the cap" {
  local fixture="$SB/cfg/tiny3.gguf"
  gen_gguf "$fixture" "qwen35" "65" "24" "4" "5120"
  run run_script "$GG" "$fixture" 8
  [ ${#output} -le 8 ]
}
