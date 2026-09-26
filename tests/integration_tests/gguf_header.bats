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

# ── Helper: extended fixture with arrays + attention dim keys ─────────────
# $1 out, $2 arch, $3 block_count, then any number of `name=<n>` (scalar u32,
# written as arch.attention.<name>) or `name=a:v1,v2,..` (array, one prefix per
# element type: a=u32/4B, i=i32/4B, L=u64/8B, j=i64/8B, b=bool/1B).
gen_gguf2() {
  local out="$1" arch="$2" bc="$3"; shift 3
  python3 - "$out" "$arch" "$bc" "$@" <<'PY'
import struct, sys
out, arch, bc = sys.argv[1:4]
specs = sys.argv[4:]
def i32(v): return struct.pack('<i', int(v))
def i64(v): return struct.pack('<q', int(v))
def u32(v): return struct.pack('<I', int(v))
def u64(v): return struct.pack('<Q', int(v))
def sval(s): d = s.encode('utf-8'); return u64(len(d)) + d
# GGML_TYPE_* array element widths: a=u32(4) i=i32(5) L=u64(10) j=i64(11) b=bool(7)
ELEM = {'a': (4, 4), 'i': (5, 4), 'L': (10, 8), 'j': (11, 8), 'b': (7, 1)}
PACK = {4: u32, 5: i32, 10: u64, 11: i64, 7: lambda x: bytes([x & 0xff])}
def elem(et, v): return PACK[et](v)
keys = [('general.architecture', 8, sval(arch)), (arch + '.block_count', 4, u32(bc))]
for sp in specs:
    name, _, raw = sp.partition('=')
    # '!' prefix writes an arch-level key (no .attention. namespace), e.g.
    # !full_attention_interval=4 -> <arch>.full_attention_interval
    if name.startswith('!'):
        key = arch + '.' + name[1:]
    else:
        key = arch + '.attention.' + name
    if len(raw) > 1 and raw[1] == ':' and raw[0] in ELEM:
        et, _ = ELEM[raw[0]]
        vals = [int(x) for x in raw[2:].split(',')]
        keys.append((key, 9, u32(et) + u64(len(vals)) + b''.join(elem(et, v) for v in vals)))
    else:
        keys.append((key, 4, u32(raw)))
with open(out, 'wb') as f:
    f.write(b'GGUF'); f.write(u32(3)); f.write(u64(0)); f.write(u64(len(keys)))
    for k, t, v in keys:
        f.write(sval(k)); f.write(u32(t)); f.write(v)
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

@test "gguf header reader: per-layer arrays (head_count_kv + sliding_window_pattern) + dim keys" {
  local fixture="$SB/cfg/gm4.gguf"
  gen_gguf2 "$fixture" "gemma4" "30" \
    head_count=16 head_count_kv=a:8,8,8,8,8,2,8,8,8,8,8,2,8,8,8,8,8,2,8,8,8,8,8,2,8,8,8,8,8,2 \
    embedding_length=2816 key_length=512 value_length=512 key_length_swa=256 value_length_swa=256 \
    sliding_window=1024 shared_kv_layers=0 \
    sliding_window_pattern=a:1,1,1,1,1,0,1,1,1,1,1,0,1,1,1,1,1,0,1,1,1,1,1,0,1,1,1,1,1,0
  run run_script "$GG" "$fixture" 2048
  [ "$status" -eq 0 ]
  [[ "$output" == GGUF-OK* ]]
  [[ "$output" == *"arch=gemma4"* ]]
  [[ "$output" == *"block_count=30"* ]]
  [[ "$output" == *"key_length=512"* ]]
  [[ "$output" == *"value_length=512"* ]]
  [[ "$output" == *"key_length_swa=256"* ]]
  [[ "$output" == *"value_length_swa=256"* ]]
  [[ "$output" == *"sliding_window=1024"* ]]
  [[ "$output" == *"shared_kv_layers=0"* ]]
  [[ "$output" == *"head_count_kv=a:8,8,8,8,8,2,8,8,8,8,8,2,8,8,8,8,8,2,8,8,8,8,8,2,8,8,8,8,8,2"* ]]
  [[ "$output" == *"sliding_window_pattern=a:1,1,1,1,1,0,1,1,1,1,1,0,1,1,1,1,1,0,1,1,1,1,1,0,1,1,1,1,1,0"* ]]
}

@test "gguf header reader: per-layer array count != block_count is dropped (trust guard)" {
  local fixture="$SB/cfg/bad.gguf"
  gen_gguf2 "$fixture" "gemma4" "30" head_count=16 head_count_kv=a:8,8,8 \
    embedding_length=2816 sliding_window_pattern=a:1,1,1
  run run_script "$GG" "$fixture" 2048
  [ "$status" -eq 0 ]
  [[ "$output" == GGUF-OK* ]]
  [[ "$output" == *"block_count=30"* ]]
  [[ "$output" != *"head_count_kv=a:"* ]]
  [[ "$output" != *"sliding_window_pattern=a:"* ]]
}

@test "gguf header reader: sparse recurrent_layers array (count < block_count) accepted" {
  local fixture="$SB/cfg/rec.gguf"
  gen_gguf2 "$fixture" "qwen35" "65" head_count=24 head_count_kv=4 embedding_length=5120 \
    !full_attention_interval=4 recurrent_layers=a:4,9,14,19,24,29,34,39,44,49,54,59,64
  run run_script "$GG" "$fixture" 2048
  [ "$status" -eq 0 ]
  [[ "$output" == GGUF-OK* ]]
  [[ "$output" == *"full_attention_interval=4"* ]]
  [[ "$output" == *"recurrent_layers=a:4,9,14,19,24,29,34,39,44,49,54,59,64"* ]]
}

@test "gguf header reader: out-of-range recursive/sparse entries are discarded" {
  local fixture="$SB/cfg/oor.gguf"
  gen_gguf2 "$fixture" "qwen35" "65" head_count=24 head_count_kv=4 embedding_length=5120 \
    recurrent_layers=a:4,99,9,70
  run run_script "$GG" "$fixture" 2048
  [ "$status" -eq 0 ]
  [[ "$output" == *"recurrent_layers=a:4,9"* ]]
  [[ "$output" != *"99"* ]]
  [[ "$output" != *"70"* ]]
}

@test "gguf header reader: bool-element per-layer array (sliding_window_pattern)" {
  local fixture="$SB/cfg/bool.gguf"
  gen_gguf2 "$fixture" "gemma3" "6" head_count=8 head_count_kv=4 embedding_length=1280 \
    key_length=256 key_length_swa=128 sliding_window=512 sliding_window_pattern=b:1,1,1,1,1,0
  run run_script "$GG" "$fixture" 2048
  [ "$status" -eq 0 ]
  [[ "$output" == *"sliding_window_pattern=a:1,1,1,1,1,0"* ]]
}

@test "gguf header reader: MLA keys (kv_lora_rank + rope.dimension_count) parsed" {
  local fixture="$SB/cfg/mla.gguf"
  gen_gguf2 "$fixture" "deepseek2" "61" head_count=8 head_count_kv=8 embedding_length=2048 \
    kv_lora_rank=512 rope.dimension_count=64
  run run_script "$GG" "$fixture" 2048
  [ "$status" -eq 0 ]
  [[ "$output" == *"kv_lora_rank=512"* ]]
  [[ "$output" == *"rope_dimension_count=64"* ]]
}

# gemma4 stores head_count_kv as an i32 (element type 5) per-layer array. The
# reader used to accept only u32/bool elements, so it was skipped and the KV
# estimate silently fell back to head_count=16 — 8x too large.
@test "gguf header reader: i32-element per-layer array (gemma4 head_count_kv) accepted" {
  local fixture="$SB/cfg/i32.gguf"
  gen_gguf2 "$fixture" "gemma4" "30" head_count=16 \
    head_count_kv=i:8,8,8,8,8,2,8,8,8,8,8,2,8,8,8,8,8,2,8,8,8,8,8,2,8,8,8,8,8,2 \
    embedding_length=2816
  run run_script "$GG" "$fixture" 2048
  [ "$status" -eq 0 ]
  [[ "$output" == GGUF-OK* ]]
  [[ "$output" == *"head_count_kv=a:8,8,8,8,8,2,8,8,8,8,8,2,8,8,8,8,8,2,8,8,8,8,8,2,8,8,8,8,8,2"* ]]
}

@test "gguf header reader: i32-element per-layer array with count != block_count is dropped" {
  local fixture="$SB/cfg/i32bad.gguf"
  gen_gguf2 "$fixture" "gemma4" "30" head_count=16 \
    head_count_kv=i:8,8,8,8,8,2 embedding_length=2816
  run run_script "$GG" "$fixture" 2048
  [ "$status" -eq 0 ]
  [[ "$output" == GGUF-OK* ]]
  [[ "$output" == *"block_count=30"* ]]
  [[ "$output" != *"head_count_kv=a:"* ]]
  [[ "$output" != *"head_count_kv="* ]]
}

@test "gguf header reader: 64-bit element arrays (u64/i64) keep the 8-byte stride" {
  local fixture="$SB/cfg/i64.gguf"
  gen_gguf2 "$fixture" "gemma4" "6" head_count=8 \
    head_count_kv=L:4,4,4,4,4,1 embedding_length=2048 \
    sliding_window_pattern=j:1,1,1,1,1,0
  run run_script "$GG" "$fixture" 2048
  [ "$status" -eq 0 ]
  [[ "$output" == *"head_count_kv=a:4,4,4,4,4,1"* ]]
  [[ "$output" == *"sliding_window_pattern=a:1,1,1,1,1,0"* ]]
}
