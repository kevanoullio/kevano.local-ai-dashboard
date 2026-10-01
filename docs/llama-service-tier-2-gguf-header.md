# Tier 2 — Model file (the GGUF header)

**Cost** ~15 ms · **Role** definitive · **Status** exists, complete

This tier is part of the llama.cpp service acquisition ladder. The ollama
backend does not use any of these tiers — it reads everything directly from the
engine.

A bounded read of the first 16 KiB of the `.gguf` file. No weights are read,
nothing is mmapped past the prefix, no model is loaded, no device is touched.
This tier is the reason the panel can report layer counts, the quantization,
and the full KV-cache shape without running the engine.

It answers **what the model is**. It never answers **where the model is** —
the file knows nothing about the machine it was loaded on.

---

## 1. The script

`ggufScript` (`Service.qml:392`) is the most intricate single constant in the
codebase, and it runs in **two passes** for a reason worth understanding.

### Pass 1 — the hyperparameter prefix (16 KiB)

```bash
head -c 16384 -- "$f" | od -A n -t x1 -v | awk '…'
```

`od -t x1` gives a flat hex stream; the awk program reassembles it into
little-endian accessors (`u32le`, `u64le`, `u64lehex`, `byteat`, `unhex`) and
searches for each wanted key by its length-prefixed UTF-8 name. The GGUF
metadata KV section precedes the tensor table, and hyperparameters sit in the
first few hundred bytes — long before the vocabulary and blob metadata, which
run to megabytes.

Keys are namespaced by the architecture read out of `general.architecture`:

| Emitted name | Key |
|---|---|
| `block_count` | `<arch>.block_count` |
| `head_count` | `<arch>.attention.head_count` |
| `head_count_kv` | `<arch>.attention.head_count_kv` |
| `embedding_length` | `<arch>.embedding_length` |
| `nextn_predict_layers` | `<arch>.nextn_predict_layers` |
| `full_attention_interval` | `<arch>.full_attention_interval` |
| `key_length` / `key_length_swa` | `<arch>.attention.key_length` / `…_swa` |
| `value_length` / `value_length_swa` | `<arch>.attention.value_length` / `…_swa` |
| `sliding_window` | `<arch>.attention.sliding_window` |
| `shared_kv_layers` | `<arch>.attention.shared_kv_layers` |
| `sliding_window_pattern` | `<arch>.attention.sliding_window_pattern` |
| `recurrent_layers` | `<arch>.attention.recurrent_layers` |
| `kv_lora_rank` | `<arch>.attention.kv_lora_rank` |
| `rope_dimension_count` | `<arch>.attention.rope.dimension_count` |
| `size` | from `stat -c %s`, not from the file |

Output is `GGUF-OK`/`GGUF-NO` on line 1, then `arch=<name>`, then one
`key=value` (scalars) or `key=a:v1,v2,…` (arrays) per hit.

### Pass 2 — `general.file_type` (streamed)

```bash
off=16384; cap=33554432; found=0;
while [ "$off" -lt "$cap" ] && [ "$found" -eq 0 ]; do
  chunk=$(dd if="$f" bs=4194304 skip=… count=1 | od … | awk '…');   # prints on first hit
  if [ -n "$chunk" ]; then echo "file_type=$chunk"; found=1; fi
  off=$((off + 4194304))
done
```

`general.file_type` is a scalar that sits **after** the tokenizer/vocabulary
blob, so in a real file it is far beyond any small head cap. Pass 2 streams
the file in fixed 4 MiB blocks up to 32 MiB and stops at the first hit. It is
bounded and memory-flat — a 14 GB model costs the same as a 1 GB one.

**Without pass 2 the Quant row is `—` for every large model.** The
`gguf_header.bats` test `file_type after a large vocab blob` pins the real
ordering.

### The two-pass contract in one line

Pass 1 is *positional* (16 KiB, everything early). Pass 2 is *searched*
(streamed, one known key late). They share the same awk prologue, which is why
`byteat` / `u32le` / `u64lehex` are duplicated verbatim at `Service.qml:407-412`
and `:491-493`.

### Reader safety

```bash
if [ ! -e "$f" ] || [ -L "$f" ] || [ ! -f "$f" ]; then echo GGUF-NO; exit 0; fi;
```

Symlinks and special files are refused; a missing or non-GGUF file emits
`GGUF-NO` and exits 0, which the QML side treats as "no header" rather than an
error. The whole pipeline is `| head -c "$2"` with `$2 = capGguf` (2048).

## 2. Array typing and the trust guard

`head_count_kv` and `sliding_window_pattern` are **per-layer arrays** in some
architectures and scalars in others. The reader accepts element types `i32`/`u32`
(4 B), `i64`/`u64` (8 B) and `bool` (1 B).

This is not hypothetical. Gemma 4 writes `head_count_kv` as an **i32** array;
reading only u32 silently dropped it, fell back to the scalar `head_count`
(8 heads instead of 2 on its full-attention layers), and reported
**21.6 GiB instead of 2.81 GiB** — an 8× error on the KV cache.

The trust guard:

```awk
if (SP[NM[i]] == 1) { if (cnt == 0 || cnt > BC) continue }   # sparse index list
else if (cnt != BC) continue                                  # per-layer array
```

- A **per-layer array** must have exactly `count == block_count`. Anything
  else is a misparse and is discarded.
- **`recurrent_layers` is a sparse index list** and accepts
  `0 < count <= block_count`, dropping out-of-range entries individually. It is
  flagged sparse by `SP["recurrent_layers"] = 1`.
- Every entry is bounds-checked against the bytes actually read
  (`kb + klen2 + 16 + cnt*esz > blen → continue`).

A header is only cached when it is **confirmed** and carries a usable layer
count: `if (!ok || bc < 0 || path === "") return` (`Service.qml:2448`).
"Confirmed but marker-less" is still cached — the marker is the KV
derivation's business, not the header's.

## 3. The QML fold

`_finishGguf` (`Service.qml:2396`) parses the normalized text back into
`_ggufCache[path]`:

```js
{ arch, bc, hc, hckv, hckvArr, embd, npl, fai,
  kl, vl, klswa, vlswa, swa, sharedKv, swaPattern, swaPatternArr,
  recurrentArr, kvLoraRank, ropeDim, sz, ft }
```

`a:`-prefixed values become arrays (`head_count_kv`, `sliding_window_pattern`,
`recurrent_layers`); everything else `parseInt`s to a scalar or stays a string
(`arch`).

### Cache and single-flight

`_ggufCache` is path-keyed and never invalidated. `_queueGguf`
(`Service.qml:2299`) is single-flight: a read already in flight is left alone
and the caller retries next refresh. `_resolveRunningEntries`
(`Service.qml:1513`) resolves cached headers **synchronously** and queues only
the misses — so on most refreshes this tier costs zero I/O, and on a cold cache
one read per distinct model path (base first, then `--model-draft`).

`_applyGgufToRunning` (`Service.qml:2384`) matches the finished path against
both `modelPath` and `draftPath` and republishes `runningModels` with a
`slice()` so the Repeater re-renders.

## 4. What it answers, and how

### 4.1 Directly (exact, definitive)

| Field | From | Notes |
|---|---|---|
| `totalLayers` | `block_count` | Includes built-in MTP layers. |
| `ftype` | `general.file_type` | Via `_ftypeLabel` (`Service.qml:828`) — a llama.h enum table verified against build 10729. The **only** enum table in the codebase, and it is a *file-format* table, not an architecture table. |
| `mainLayers` | *(moved to derivation)* | Was `block_count` − `nextn_predict_layers`, written here. It is arithmetic, so a tier writing it made tier 2 a **second source** of a number the derivation already owned. See §4.4. |
| `mtpLayers` | `nextn_predict_layers` | Built-in MTP. Clamped to `total`. |
| draft `mtpLayers` | draft's own `block_count` | Separate-draft case only. |
| `draftSizeBytes` | draft's `size` | |

### 4.2 The MTP/main layer accounting

> **Note.** `mainLayers` appears in the code below as today writes it. Under the
> plan it is **not written by this tier** — it is derived as `totalLayers −
> mtpLayers`, and both of those are tier-2 reads, so the arithmetic is exact and
> `derived: true`. See §4.4.

`block_count` includes any built-in `nextn_predict_layers`, but the main stack
is what `--n-gpu-layers` and the KV accounting operate on. `_applyGguf`
(`Service.qml:2312`) branches:

```js
if (entry.draftPath !== "") {
    entry.mainLayers = total − npl                     // base is pure main
    _mtpSplit(ngl, total, 0)                           // no MTP in this path
} else {
    entry.mtpLayers  = min(npl, total)
    entry.mainLayers = total − mtpLayers
    entry.mtpSizeBytes = sizeBytes / total × mtpLayers  // exact ratio
    _mtpSplit(ngl, total, mtpLayers)                   // → main + mtp
}
```

`_mtpSplit` (`Service.qml:770`) is the single place that turns an `-ngl` count
into four numbers. MTP layers sit **on top of** the stack, so `N` offloaded
layers are counted from the bottom:

```
main = total − mtp
mainGpu = min(N, main)          mainCpu = main − mainGpu
mtpGpu  = max(0, min(mtp, N − main))   mtpCpu = mtp − mtpGpu
```

`"all"` → `N = total`; an integer is clamped to `[0, total]`; anything else
(missing, `auto`, non-numeric, unknown total) → four `null`s.

**This function is also the MTP-location bug's counterpart, and both halves of
that bug are now fixed.** `_mtpSplit` sets all four fields; the demand-gated
applier `_applyProbeSplit` sets only two — and under the plan it is **deleted**,
so the four-field invariant is enforced by having exactly one writer rather than
by a convention. See [`concern-1-p0-plan.md`](../concern-1-p0-plan.md) §7.1 and
§10.

**The architecture template.** `_buildKvLayers` resolves keys as
`<arch>.<suffix>` through a per-namespace template, because GGUF keys are
prefixed by architecture and a reader hardcoding `llama.block_count` reads
**nothing** from a model that does not use the `llama` prefix. This is not
hypothetical: `Qwen3.6-35B-A3B-UD-IQ4_XS.gguf` reports
`general.architecture = qwen35moe` and carries zero `llama.*` keys while
publishing `qwen35moe.block_count = 40`, `attention.head_count_kv = 2`,
`attention.key_length = 256` and `full_attention_interval = 4`. An untemplated
namespace makes the derivation **decline**, and tier 6 answers. Full treatment in
[`concern-1-p0-plan.md`](../concern-1-p0-plan.md) §5.2.1.

### 4.3 As *inputs* to the KV derivation

`totalLayers`, `mainLayers`, and the whole shape feed `_buildKvLayers`
(`Service.qml:969`) → `_kvEstimateBytesArch` (`Service.qml:1091`). Tier 2 does
not produce a KV size; it produces the **spec** the arithmetic consumes. That
is the boundary between tier 2 and derivation, and it is why the KV size's
certainty is decided by the *shape*, not by the file.

## 5. The shape rules (and the things deliberately left unknown)

This is the part with the most care in it, and the part most likely to be
"fixed" wrongly. Three rules, in order:

### 5.1 MLA — K only

`kv_lora_rank > 0` ⇒ DeepSeek-style. Every layer is `{kvHeads: 1,
kLen: kvLoraRank + ropeDim, vLen: 0, hasV: false, cells: ctx}`. No
`ropeDim` ⇒ `null`. This branch returns early and skips all layer-type logic.

### 5.2 Layer type — four declarations, one void

```js
if (g.swaPatternArr?.length > 0)  pattern = g.swaPatternArr   // explicit array
else if (g.swaPattern > 0)        period  = g.swaPattern       // explicit scalar
else if (g.swa === 0)             period  = -1                // declared dense
else if (g.swa < 0 && _declaresRecurrent(g)) period = -1      // declared hybrid, no window
else return null                                              // ← undescribed
```

- **`sliding_window_pattern`** — written by some converters. Trusted as an
  explicit per-layer type.
- **`sliding_window_pattern` as a scalar** — an explicit period.
- **`sliding_window == 0`** — every llama.cpp source that reads that key
  treats it as `KV_TYPE_NONE`, i.e. dense. A declaration.
- **`_declaresRecurrent(g)` with no window key at all** — also dense, and also
  a declaration. `_declaresRecurrent` is true for either
  `recurrent_layers` (non-empty sparse list) or `full_attention_interval > 1`.
  A sliding window is a property of an attention stack, and llama.cpp never
  hardcodes one for an architecture whose layers interleave with recurrent
  ones. The two sets are disjoint, and that is verifiable against the checkout:

  ```bash
  cd llama.cpp/src/models
  comm -12 \
    <(grep -lE 'LLM_KV_ATTENTION_RECURRENT_LAYERS|LLM_KV_ATTENTION_FULL_ATTENTION_INTERVAL|SSM' *.cpp | sort) \
    <(grep -lE 'load_swa_pattern|LLM_KV_ATTENTION_SLIDING_WINDOW_PATTERN'        *.cpp | sort)
  # must print nothing; if it ever does, this rule needs revisiting
  ```

  The case that forced this rule is `qwen35moe` (the shipped
  qwen3.6-35b-a3b): 40 layers, `full_attention_interval 4`, **no**
  `attention.sliding_window` at all, and its own `load_arch_hparams` calls
  neither `get_key(SLIDING_WINDOW)` nor `load_swa_pattern`. The engine builds
  one flat full-context cache over the 10 non-recurrent layers, and tier 2's
  derivation reproduces `llama_kv_cache: size = 2720.00 MiB (262144 cells,
  10 layers)` to the byte.

### 5.3 The two deliberate voids

- **A merely absent `sliding_window` on a file that declares nothing about its
  layer types** → `null`. llama4 and cohere2 carry no window key and *still*
  get a 4-layer SWA pattern from their own source, so absence proves nothing.
- **A positive window with recurrent layers declared** → `null`. Only lfm2
  among the hybrids derives its pattern that way
  (`is_swa_impl[il] = !is_recr_impl[il]`); lfm2moe and bailingmoe3 use the same
  recurrence convention and ignore the window entirely. Answering it would be
  a one-architecture table in disguise.

`null` here is **not a failure** — it is the signal that sends the field to
tier 6. See [llama-service-tier-6-deep-engine-observation.md](llama-service-tier-6-deep-engine-observation.md).

### 5.4 No architecture table, ever

The deleted `_swaPeriodFor` (old values `gemma3=6, gemma3n=5, gemma2=2,
gpt_oss=2, llama4=4, cohere2=4`) is gone because it was a snapshot of one
upstream commit — wrong for every architecture it missed, and stale the day
upstream changed it. `tst_derivation.qml` asserts `typeof s._swaPeriodFor ===
"undefined"` (`kvarch/no-arch-table`, `kvarch/no-arch-switch`) so it cannot
creep back.

### 5.5 `head_count_kv == 0` is a declaration

llama.cpp's own convention for "this layer holds no KV cache" is a **zero**
entry in the per-layer array — lfm2, lfm2moe and bailingmoe3 all set
`is_recr_impl[il] = (n_head_kv(il) == 0)`. `_kvlessByHeads`
(`Service.qml:939`) therefore reads `0` as a statement about the layer, and
`_recurrentSet` (`Service.qml:950`) unions three sources:

1. `recurrent_layers` sparse indices (wins when present)
2. else `full_attention_interval`: every layer where `(il+1) % fai !== 0`
3. plus any layer with `head_count_kv[il] == 0`, **regardless**

### 5.6 Per-layer spec assembly

```js
kv      = hckvArr[il]  > 0  ? hckvArr[il]  : (hckv > 0 ? hckv : hc)  // array > scalar > head_count
hk      = swa ? (klswa > 0 ? klswa : (kl > 0 ? kl : embedding_length/head_count))
             : (kl   > 0 ? kl   : (klswa > 0 ? klswa : embedding_length/head_count))
hv      = swa ? (vlswa > 0 ? vlswa : hk) : (vl > 0 ? vl : hk)
cells   = _kvCellsForType(swa, ctx, swaWindow, ubatch, swaFull, kvUnified, parallel)
if (!(kv > 0) || !(hk > 0) || !(hv > 0)) return null
if (!(cells > 0)) return null
```

`shared_kv_layers` tail layers are **skipped** — they reuse earlier KV and
store none of their own. Any unsizeable counted layer ⇒ `null` for the whole
spec, so the field degrades to tier 6 rather than showing a partial sum.

### 5.7 Cell law

```js
function _kvCellsForType(isSwa, ctx, swaWindow, ubatch, swaFull, kvUnified, parallel) {
  if (!isFinite(ctx) || ctx <= 0) return -1
  if (!isSwa || swaFull) return ctx                                  // full context
  if (!isFinite(swaWindow) || swaWindow <= 0) return -1
  var p = (kvUnified && parallel > 0) ? parallel : 1
  return Math.ceil(Math.min(ctx, swaWindow * p + ubatch) / 256) * 256
}
```

An SWA layer holds `min(ctx, window·(unified ? parallel : 1) + ubatch)` cells,
padded up to a multiple of 256. `--swa-full` forces full context for every
layer. `--no-kv-unified` drops the `parallel` multiplier.

### 5.8 The sum

```js
// _kvEstimateBytesArch, Service.qml:1091
kb = L.kLen * kBits / 8
vb = L.hasV === false ? 0 : L.vLen * vBits / 8
layerBytes = (kb + vb) * L.cells * mult          // mult = parallel, when not unified
```

`_kvDtypeBits` (`Service.qml:807`) is the only dtype table:
`f32=32, f16/bf16=16, q8_0=8.5, q6_k=6.5625, q5_1=5.5, q5_0=5.25, q4_1/q4_0=4.5`,
empty ⇒ 16 (llama.cpp's default), unknown ⇒ `-1` ⇒ the field degrades.

**The quant-block alignment predicate** lives here, as a **new tier-2 boolean
`kvBlockAligned`** — reported, never a gate. The sum above is byte-exact when
every `(kb + vb) · cells` term is a whole number of quant blocks, because ggml
pads each cache tensor to its block size.

A non-aligned term is **not** a reason to decline, and treating it as one is a
bug worth naming. The header still states the width, the arithmetic is still
exact, and the only consequence is that the engine pads to a block boundary —
which the derivation adds back rather than being unable to account for. So a
non-aligned model yields a value marked `estimated`, alongside
`kvBlockAligned: false`, and tier 6 is **not** spawned. Escalating to tier 6
would send every `q5_0`-K / `q4_0`-V model — the `qwen3.8-27b-fast` case — through
a 3–45 s oracle run to compute something the header already determines.

Tier 2 therefore publishes **two** new booleans: `kvDescribed` (did the
architecture namespace resolve, so is the shape readable at all) and
`kvBlockAligned` (is every term a whole number of quant blocks). Both are
`exact` readings; what they *permit* the derivation to claim is the derivation's
decision. Four-row table in
[`concern-1-p0-plan.md`](../concern-1-p0-plan.md) §5.2.4.

### 4.4 What this tier no longer writes

- **`mainLayers`** → derived (`totalLayers − mtpLayers`).
- **`mainGpu` / `mainCpu`** → derived. `_mtpSplit` is still the single function
  that turns an `-ngl` count into four numbers, but it is now called **by the
  derivation**, so there is exactly one writer and it is not a tier.
- **Any split or MTP location** → the demand-gated applier that wrote two of the
  four fields is deleted.

This is what lets tier 3 stop needing `block_count`, and therefore what removes
the tier-2-before-tier-3 ordering constraint entirely.

## 6. What it cannot answer

- **Anything about placement.** The file is the same file whether it is on a
  GPU, in RAM, or on a network mount.
- **The realized offload count.** `block_count` is a capacity, not a placement.
- **The context length actually used.** `n_ctx_train` is informational and
  deliberately unused. The realized context is tier 1's `meta.n_ctx`.
- **Quantization → bytes per parameter.** `general.file_type` is a label; the
  panel never derives weight bytes from it. Weight bytes come from
  `meta.size × layer ratio`, or from measurement.
- **The tokenizer and chat template.** Read past the cap, deliberately.
- **A separate draft's size** unless `--model-draft` is set — then the draft's
  own header is read as a second tier-2 read (`_applyGgufDraft`,
  `Service.qml:2369`).

## 7. Under the resolver

```
checkTier3Values(entry, pending):
    if entry.modelPath === "":                     return {}
    if _ggufCache[entry.modelPath] === undefined:  return {}   // a read is queued
    return pending ∩ { totalLayers, mainLayers, mtpLayers, ftype,
                       mtpSizeBytes, draftSizeBytes, …shape }

fetchTier3Values(entry):
    // one process, then _applyGguf (base) or _applyGgufDraft (draft)
    // → commit → applyDerivation()  ← this is where kvCacheBytes lands
```

The important scheduling consequence: tier 2's commit is what makes the KV
size resolvable *for free*, so the walk almost always terminates here or one
step later. `_queueGguf` gains a need gate — an entry whose `block_count` is
already cached never re-reads, and under the plan an entry with no pending
tier-2 field is not enqueued at all.

## 8. Tests

- **`gguf_header.bats`** (16 tests) — the binary contract, with a Python
  fixture (`gen_gguf`) that is the single source of truth for the layout:
  valid file → `arch`/`block_count`/`head_count`/`head_count_kv`/
  `embedding_length`/`file_type`; hybrid keys absent; `file_type` **after** a
  large vocab blob; missing/symlink/non-GGUF → `GGUF-NO`; output cap honoured;
  per-layer arrays and the `count != block_count` trust guard; sparse
  `recurrent_layers` accepted; out-of-range entries dropped; bool-element
  arrays; MLA `kv_lora_rank` + `rope.dimension_count`; i32 arrays (gemma4);
  64-bit strides.
- **`tst_derivation.qml`**, prefixes `gguf/*`, `hybrid/*`, `kvarch/*`,
  `cells/*`, `dense-declared/*`, `keylen-explicit`:
  `gguf/array-hckv-first`, `gguf/array-hckv-last`, `gguf/array-fold-kv`,
  `gguf/array-swa-pattern`, `gguf/array-arch`, `gguf/cache-bc`, `gguf/cached`,
  `gguf/header-file-type-parsed`, `gguf/entry-ftype-from-header`,
  `gguf/no-marker-layers`, `gguf/no-marker-still-uncached`;
  `kvarch/gemma4-deployed-mib`, `kvarch/gemma4-deployed-bytes`,
  `kvarch/gemma4-spec`, `kvarch/no-arch-table`, `kvarch/no-arch-switch`,
  `kvarch/absent-window-not-dense`.
  The `gemma4-deployed-*` group asserts the **deployed file's** byte total and
  its `formatGB` rendering, which is what caught the 8× i32 bug.
- **`e2e_mtp_draft.qml`** (39 asserts) — the built-in-MTP arc through the real
  `_finishGguf` with `nextn_predict_layers=1`: Model Size must show **64, not
  65**, plus the Draft row; then the separate `--model-draft` arc.

## 9. Gaps to close

1. **The block-alignment precondition** that decides whether a derived KV size
   may be promoted from `~` to exact (`_kvEstimateBytesArch`).
2. **`_ggufCache` is never evicted.** Under the plan, per-model state is
   dropped on unload — which must include the header entry.
3. **`_finishGguf` has no `pending` gate**, so a header read already running
   when every tier-2 field resolved is not cancelled. Low cost (one 16 KiB
   read) but it is a `capabilities()`-consistency item.
