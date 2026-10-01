# Tier 6 — Deep engine observation

**Cost** 3–45 s · **Role** definitive · **Status** the machinery exists as
today's "Tier 3.5" probe; the gate and two of three parsers are new

This tier is part of the llama.cpp service acquisition ladder. The ollama
backend does not use any of these tiers — it reads everything directly from the
engine.

`llama-cli --verbose` prints the exact KV allocation it built. It knows every
architecture, including the ones whose GGUF files do not describe their own
layout, because it **is** the layout's owner. Nothing else on this list can
answer for `llama4` or `cohere2`.

It is the most expensive thing the panel does, and it is the last thing it
should do. Under the plan it runs **only when no cheaper source could ever
answer** — which means only for a model whose KV shape the header leaves
undescribed.

The tier is two things, and the split is the point:

- **6-i** — the *process*. One `llama-cli` run, captured as raw text.
- **6-ii** — the *parsers*. Independent pure functions of that text, each
  invoked **only while its own field is still pending**.

---

## 1. The gate — the only condition that permits this tier

```
run tier 6 ⟺  ∃ field F such that:
      F is still pending
  AND  tiers 1-5 all declined F
  AND  derivation declined F
  AND  F is pending *because its shape is undescribable*
```

The last clause is the whole design. It has two halves:

- **Never runs for a described shape.** When tier 2 fully described the KV
  shape, the derivation over exact inputs is byte-exact — the qwen3.6-35b-a3b
  case reproduces `llama_kv_cache: size = 2720.00 MiB (262144 cells, 10
  layers)` to the byte. Running the engine to confirm a byte-exact answer is
  pure waste.
- **Runs precisely for the undescribable.** `_buildKvLayers` returns `null` in
  two deliberately-designed cases (§5.3 of
  [llama-service-tier-2-gguf-header.md](llama-service-tier-2-gguf-header.md)) and the engine is the only
  thing that can settle them.

A field that is pending for any *other* reason — a missing binary, a killed
process, a parse failure — is **exhausted**, not tier-6-pending. Routing those
to tier 6 would make a 45 s process the penalty for an ordinary failure.

**Two things this gate does not do, both deliberate.**

- **There is no deadline on the path it permits.** If a model's architecture
  namespace is untemplated, the correct behaviour is a 3–45 s unconditional
  subprocess run on every load. The only relief is `kvProbe: "off"`, which makes
  the gate *refuse* and the field exhaust to `—` rather than wait for a probe
  that is switched off. A timeout here would be worse than useless: a truncated
  `llama_kv_cache` line is unparseable, and unparseable is `absent`, so the
  timeout would convert a slow correct answer into a fast wrong one.
- **It does not run "to confirm" a derivation.** Even a byte-exact derivation is
  not re-verified. If the header's shape is described, the header's answer is the
  answer; cross-checking it would make the 3–45 s tier the *common* case instead
  of the rare one.

The gate is `checkTier6Values()` plus need-gating that replaces the unconditional
probe queue, and lazy per-field parsing reduces to a single parser gated on
`kvBytes` alone — so there is no per-parser pending map to maintain. See
[`concern-1-p0-plan.md`](../concern-1-p0-plan.md) §7.7 and §8.4.

## 2. 6-i, the process

### 2.1 The invocation

```js
// Service.qml:2035 _kvProbeArgv
["--verbose", "--no-warmup", "-st", "-n", "0", "-p", "x", "-ngl", "0", "-dev", "none"]
```

plus, only when set: `-c <ctx>`, `-b <b> -ub <ub>`, `-np <np>`,
`--cache-type-k <k>`, `--cache-type-v <v>`, `--swa-full`, `--no-kv-unified`,
`--no-kv-offload`.

**`-ngl 0 -dev none` is not a politeness measure.** The cache *size* is
device-independent, so there is nothing to gain by touching the GPU — and
measured, only `-ngl 0` was originally passed, so the probe still tried to
`cudaMalloc` its compute reserve (1,537 MiB against the live qwen3.6-35b-a3b
worker) and failed there in `ggml_gallocr_reserve_n_impl`. Since the probe
inspects models that are *already loaded*, that was a failure on the common
path, and it needlessly allocated the user's VRAM.

**Deliberately omitted from the argv:** the draft model (it has its own,
smaller context), offload counts and fit/device settings (they change *where*
the cache lands, not its size — that is placement's question, answered by
tier 4), and every server flag (host/port/api-key/jinja/mmproj). `-p x` and
`-st` are needed to make the process build a context and exit instead of
sitting in its REPL.

### 2.2 Where the output goes

**stderr, not stdout.** Measured on gemma-4-26b: 3,116 bytes on stderr, 32 on
stdout, **zero KV lines on stdout**. Reading stdout would have looked like a
clean "no answer" forever.

This is why `kvProbeScript` ends in a bare `exec "$cli" "$@"` with no
redirection, and why the `SplitParser` is bound to the process's combined
output.

### 2.3 The pre-flight gate — not `ulimit -v`

```bash
# Service.qml:667
want=$(( mbytes + 2 * kbytes + 2147483648 ))
avail=$(awk '/^MemAvailable:/ { print $2 * 1024 }' /proc/meminfo)
if [ "$avail" -gt 0 ] && [ "$want" -gt "$avail" ] && [ "$want" -gt "$(( avail * 85 / 100 ))" ]; then
  printf 'kvprobe: skipped, …' >&2; exit 98
fi
```

Sized for the model plus twice the cache plus 2 GiB of slack, and requires 85 %
of `MemAvailable`. A request that cannot fit is **refused before the engine
starts**, so an oversized model is never allocated for at all and prints no
size line to fold.

`ulimit -v` was the obvious tool and is exactly wrong: it caps **virtual
address space**, which llama.cpp's GPU backends reserve far beyond its working
set. Measured — `ulimit -v 19.5G` made a 14.2 GB gemma-4 load die with
`mmap failed: Cannot allocate memory` while 40 GiB sat free, and the same
command succeeded uncapped in 2.3 s. This is a documented anti-pattern, not a
stylistic preference.

**The 3-second run is per signature, not per refresh.** `_kvProbeCache` is
keyed on `_kvProbeSignatureFor` and `false` (tried, no answer) is cached too,
so a broken probe is not retried every cycle.

### 2.4 The signature — what forces a re-probe

```js
// Service.qml:2013
path | contextLen | ubatch | parallel | cacheK | cacheV | swaFull | noKvUnified
```

Everything that can change the allocation. A context-size or dtype change
re-probes; nothing else does. Offload counts are **absent** because they
change placement, not size.

### 2.5 Exit-code discipline — asymmetric trust

The two numbers published from a run are published under **different
contracts**, because they become known at different points and only one depends
on the run finishing:

| Number | Contract | Why |
|---|---|---|
| `kvBytes` | published **whenever a positive `llama_kv_cache: size` line was folded**, whatever the child went on to do | That line is emitted by `llama_kv_cache`'s constructor once the allocation is fully sized — the sum of `ggml_nbytes()` over the built tensors. It is a pure function of the hparams and cparams the probe passed in, **not** a measurement of an inference that ran. |
| `computeBytes` | still requires a **clean exit** | `sched_reserve` is a forward-looking reservation for a graph that may never have been built. A run that died inside the reserve has no usable number. |

Gating `kvBytes` on a clean exit threw away correct answers: `-ngl 0` offloads
the weights but leaves the graph reserve on the GPU, so probing a loaded model
died ~1.4 s **after** printing both `llama_kv_cache: size` lines, and the
correct result was cached as `false` for the rest of the session.

(This is why `computeBytes` is being *deleted* from this tier entirely — see
§4.2 — and the asymmetry is only retained because `parseKvOnlySize` is.)

### 2.6 Buffering is diagnostics-only

```js
// Service.qml:2128
if (_kvProbeBuffer.length + s.length + 1 <= _kvProbeBufferMax) _kvProbeBuffer += s + "\n"
var rec = _parseKvProbeLine(s)
if (!rec) return
```

**Parsing never stops at the cap.** A verbose gemma-4 run is ~224 KiB against
a 256 KiB cap and prints the cache blocks twice; an early `return` on overflow
would have dropped the accounting lines along with the log text, turning a
full answer into a silent partial one.

## 3. 6-i/6-ii boundary: the text is captured, the parsers are lazy

The split's purpose is scheduling. One run can answer several fields; each
parser is a pure function of the text and is invoked **only while its own
field is pending**. If the header already answered the KV size, no parser runs
at all — the text is captured, cached, and never read.

This is the same `pending` state that gates the walk, which is why it is worth
building the field store for.

## 4. 6-ii, the parsers

All three are pure `(text) → value` functions. Two are deleted.

### 4.1 `parseKvOnlySize(text)` — **the only survivor**

```
llama_kv_cache: size = 2720.00 MiB (262144 cells,   5 layers, 1/1 seqs),
                         K (q8_0): 1360.00 MiB, V (q8_0): 1360.00 MiB
```

The existing regex (`Service.qml:2093`):

```js
/llama_kv_cache:\s+size\s*=\s*([0-9.]+)\s*MiB\s*\(\s*([0-9]+)\s*cells,\s*([0-9]+)\s*layers/
```

The **total is read first**, so a cache with no V (MLA) still parses; only the
total is used. Bytes are as precise as the log: llama.cpp prints MiB to two
decimals, so each cache carries at most ~5 KiB of print rounding. That is a
measurement of the engine's own allocation, not a derivation, so it renders
**unmarked** (exact).

**The fold — de-duplication by identity.** llama.cpp logs each cache block
**twice** (once during context setup, again when populated). gemma-4-26b emits
its 5-layer and 25-layer blocks once each and then both again verbatim; a naive
sum would report exactly double.

```js
// Service.qml:2146
var key = rec.bytes + ":" + rec.layers
if (acc.blocks.indexOf(key) < 0) {
  acc.blocks = acc.blocks.concat([key])
  acc.kvBytes  += rec.bytes
  if (rec.layers > 0) acc.kvLayers += rec.layers
}
```

Two blocks with the same byte total **and** layer count are the same allocation
logged twice. Genuinely distinct caches (a main + spec context) differ, and
both still count.

Worked example (gemma-4-26b, `-c 262144 -np 1`, K/V q8_0):

| Block | Folded |
|---|---|
| `2720.00 MiB (262144 cells, 5 layers)` | once |
| `159.38 MiB (1536 cells, 25 layers)` | once |
| both, repeated | skipped |
| **total** | **2,879.38 MiB = 3,019,248,763 B** |

The true value is 2,879.375 MiB; the 5,243 B delta is the log's two-decimal
printing.

**Why this parser is unique and cannot be replaced.** The oracle's `context`
column is **KV + recurrent combined**. Every other source separates them — the
header derivation knows which layers are recurrent and excludes them, and
tier 5's `context` column is the cache as built. So for a hybrid with a
recurrent component, the oracle over-reports, and it is the only tier that
does. That is also why tier 6 runs only when the shape is undescribed: in that
case there is no separation to be had, and the combined figure is the only
one available. It should be treated as an upper bound in that case, and the
plan's block-alignment discussion applies to it too.

### 4.2 `parseKvLayerCount(text)` — **deleted**

Produces `kvLayersExact`. That field is written at `Service.qml:2231`,
declared at `:1948`, and **read nowhere outside tests**. `_buildKvLayers`
already derives the layer list from the header, which is a better source
(it is per-layer, not a count).

### 4.3 `parseComputeReserve(text)` — **deleted**

```
sched_reserve: CUDA0 compute buffer size = 1887.86 MiB
sched_reserve: CUDA_Host compute buffer size = 272.30 MiB
```

Its only two consumers are `Service.qml:1248` and `Service.qml:2258`, both
feeding `_estimateSplitFromProbes`. Two reasons to delete it rather than keep
it:

1. **It is the probe's device, not the target's.** The probe runs `-dev none`.
   The `CUDA0` tag on that line is the *probe's* idea of a device, not the
   running worker's. Tier 5's `compute` column is per-device and for the real
   target — a strictly better source for the same number.
2. **Its consumer is being retired.** `_estimateSplitFromProbes` is deleted, and
   with it any notion of "tier-5 failure needing a fallback". Tier 6 does not
   stand in for tier 5: it runs **only on decline**, for a shape the header
   cannot describe. There is no path where tier 5 fails and tier 6 picks up the
   pieces — the two answer different questions, and the derivation is what
   connects them.

For the record, the parser did classify correctly — dropping `CPU` and any
`*_Host` tag, and de-duplicating by `dev:bytes` because the reserve is logged
once at setup and again at teardown (`Service.qml:2152-2163`). That logic is
sound and its *shape* (per-device, host-excluded, de-duplicated) is what tier
5's parser must reproduce.

## 5. Settings

| Setting | Default | Range | Meaning |
|---|---|---|---|
| `kvProbe` | `auto` | `auto` \| `off` | `off` restores header-only derivation, for users who would rather never see a short `llama-cli` run. |
| `kvProbeBinary` | `llama-cli` | — | |
| `kvProbeTimeoutSec` | `45` | 10–300 | |
| `capKvProbe` | `262144` | — | 256 KiB of log text kept, for diagnostics only. |

Under the plan these gain a fourth member: the tier-6 gate. `off` should mean
"never run 6-i", and a field that would otherwise be routed there should go to
`exhausted` rather than silently waiting.

## 6. Where the code is

| Piece | Location |
|---|---|
| Script + pre-flight | `Service.qml:667` `kvProbeScript` |
| Settings | `Service.qml:627-632` |
| Signature | `Service.qml:2009` `_kvProbeSignatureFor` |
| Argv | `Service.qml:2025` `_kvProbeArgv` |
| Enqueue | `Service.qml:2051` `_queueKvProbe` |
| Single-flight | `Service.qml:2066` `_pumpKvProbe` |
| Parser | `Service.qml:2090` `_parseKvProbeLine` |
| Line handler / fold | `Service.qml:2121` `_onKvProbeLine` |
| Accumulator | `Service.qml:2167` `_kvProbeAcc` |
| Finish + contracts | `Service.qml:2199` `_finishKvProbe` |
| Apply | `Service.qml:2223` `_applyKvProbeResult` |
| Resolver | `Service.qml:2277` `_resolveKvBytes` |
| Process | `Service.qml:3021` `kvProbeProcess` |
| Dump | `tests/support/dump_constants.qml`, `"kvProbeScript"` |

## 7. Tests

- **`kv_probe.bats`** (7 tests) — the pre-flight gate: argv passes through
  unchanged; **a hostile model path cannot run a command**; a fitting request
  runs uncapped; a non-fitting request is refused without running; a cache
  larger than RAM is refused before the engine starts; a missing engine is a
  non-zero exit, not a hang; the engine's own KV lines survive the wrapper.
- **`tst_derivation.qml`**, `probe/*` — `_parseKvProbeLine`, `_onKvProbeLine`,
  `_finishKvProbe`, `_applyKvProbeResult`. Including the two-ruling fold and
  the asymmetric exit contract.
- **New, under the plan** — `tier6/*`:
  - the gate: **does not run** when the header described the shape;
  - the gate: **does run** when `_buildKvLayers` returned `null`;
  - the gate: a field pending for a *non-shape* reason is exhausted, not
    routed here (no 45 s process for an ordinary failure);
  - **lazy per-field parsing**: with `kvBytes` already resolved, no parser is
    invoked;
  - `off` means the gate refuses and the field exhausts;
  - **deleted-parser regressions**: `kvLayersExact` and the
    `sched_reserve`-derived `computeBytes` no longer exist, and nothing reads
    them.
- **Deleted-parser regression guard**: assert
  `typeof s._parseKvLayerCount === "undefined"` and
  `typeof s.parseComputeReserve === "undefined"`, in the same style as the
  existing `kvarch/no-arch-table` guard on `_swaPeriodFor`.
- **The gate's negative case**: assert that a field pending for a *non-shape*
  reason — a missing binary, a killed process, an unparseable stdout — reaches
  `absent` and does **not** open the gate. Without this the "only condition that
  permits this tier" clause is decorative.

## 8. Gaps to close

1. **The gate itself** — the single most important item in this tier. Without
   it, tier 6 stays today's eager per-refresh probe.
2. **The two parser deletions** and `kvLayersExact` with them.
3. **The `—` vs `pending` distinction** so the gate has something to test.
4. **Unload eviction** of `_kvProbeCache` entries for a dropped model.
   A stale KV answer for a path that is later reused by a *different* model at
   the same path would be silently wrong.
