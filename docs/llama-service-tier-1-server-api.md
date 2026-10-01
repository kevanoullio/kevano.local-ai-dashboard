# Tier 1 — Server API

**Cost** ~5 ms · **Role** definitive · **Status** exists, mostly complete

This tier is part of the llama.cpp service acquisition ladder. The ollama
backend does not use any of these tiers — it reads everything directly from the
engine.

The engine's own opinion about how it was started. One HTTP GET, already made
on every refresh cycle, so this tier costs nothing incremental.

This is the highest-precedence tier because when the server answers, it is
answering about *itself*: the command line it was actually launched with, and
the metadata block of the model it actually loaded.

---

## 1. What it answers

### 1.1 The `meta` block

Read from `/v1/models[]` where `status.value === "loaded"`:

| Field | JSON key | Notes |
|---|---|---|
| `name` | `m.id` | Last path segment, truncated to 128 chars. |
| `sizeBytes` | `meta.size` | Aggregate file size. Coerced to `0` when absent. |
| `contextLen` | `meta.n_ctx` | `-1` when absent. b10729 exposes no `status.context`; `meta.n_ctx` is authoritative. |
| `nParams` | `meta.n_params` | Bare parameter count, excluding `b`-tensors. `-1` when absent. |

**What is not here, and this is not a gap in the code:** `meta` carries no
quantization and no `size_vram`. The quant is a GGUF-header fact (tier 2) and
the VRAM split is a measurement (tier 4). The open question of whether b10729
exposes `size_vram` — which would give tier 1 a free cross-check on tier 5 —
is unverifiable right now because every model is currently unloaded.

### 1.2 The `status.args` command line

`m.status.args` is the **resolved** argv the worker was launched with. This is
the single most valuable thing tier 1 provides, and it is authoritative for
everything on it: preset-driven defaults that never appear as a flag on the
command line (`fit = on` and friends) are, by construction, absent from
`args` — but anything that *is* in `args` is exactly what the engine did.

| Flag | Aliases | Field | Default when absent |
|---|---|---|---|
| `--model` | `-m` | `modelPath` | `""` → no further work possible |
| `--model-draft` | `-md` | `draftPath` | `""` = no separate draft |
| `--n-gpu-layers` | `-ngl` | `ngl` | `""` = unset (tiers 2, 4, 5 may answer) |
| `--n-gpu-layers-draft` | `--gpu-layers-draft`, `-ngld`, `--spec-draft-ngl` | `nglDraft` | `""` |
| `--cache-type-k` | | `cacheK` | `""` = llama.cpp's `f16` |
| `--cache-type-v` | | `cacheV` | `""` = llama.cpp's `f16` |
| `--spec-type` | | `specType` | `""` → display falls back to `mtp` |
| `--no-kv-offload` | | `noKvOffload` | `false` |
| `--ubatch` | `-ub` | `ubatch` | `512` |
| `--parallel` | `-np` | `parallel` | `1` |
| `--swa-full` | | `swaFull` | `false` |
| `-kvu` | `--no-kv-unified` | `noKvUnified` | `false` (unified) |

The `ubatch` / `parallel` / `swa-full` / `kv-unified` group matters because each
one **changes the KV-cache allocation law**, so each is an input to both the
tier-3 derivation and the tier-6 probe. They are not display fields; they are
parameters.

### 1.3 Loader safety

`_parseLlamaArgs` matches tokens **exactly** and handles both `flag value` and
`flag=value`. Exactness is load-bearing:

- `--model` must not match `--models-preset` or `--model-draft`.
- `--n-gpu-layers` must not match `--n-gpu-layers-draft`.

The split is done by finding the first `=` in the token, so
`--cache-type-k=q8_0` is read as flag `--cache-type-k` with inline value
`q8_0` and does not consume the next element.

## 2. Where the code is

| Piece | Location |
|---|---|
| The curl wrapper | `Service.qml:189` `listScriptLlama` |
| Process | `Service.qml:2897` `listProcess` |
| Line sink | `Service.qml:1848` `_onListLine` → `_jsonBuffer` |
| Buffer cap | `Service.qml:1874` `_jsonBufferMax: 65536` |
| JSON fold | `Service.qml:1883` `_finishJsonModels` |
| Flag parser | `Service.qml:734` `_parseLlamaArgs` |
| Entry construction | `Service.qml:1912-1951` (the `_psModels.push({...})` literal) |
| Endpoint policy | `Service.qml:159` `effectiveListEndpoint`, gated by `endpointOk` |
| Scheduling | `Service.qml:1618` `refreshApi` → `launch(listProcess, …)` |

**Endpoint policy is enforced before the process launches.** `endpointOk`
(`Service.qml:158`) folds in `configValid` and the loopback-http / remote-https
rule, so an unsafe configuration means `/v1/models` is never fetched at all —
`refreshApi` clears the model lists and returns without launching anything.

### How a parsed entry is seeded

`_finishJsonModels` builds a **fresh object literal** per loaded model
(`Service.qml:1912`). This matters for the field store: because the whole entry
is replaced on every refresh, any per-model state the resolver owns must be
either re-derivable from this literal or carried in a store keyed by model
path/id — it cannot live on the entry. Every field below starts at its
"unknown" sentinel:

```
ftype: -1   totalLayers: -1   mainLayers: -1   mtpLayers: 0
mainGpu: null   mainCpu: null   mtpGpu: 0   mtpCpu: 0
kvCacheBytes: -1   kvBytesExact: -1   kvLayersExact: -1   computeBytes: -1
_gpuSplitSource: "api"
```

The sentinels are four different values, which is itself a design wart: `-1` for
unknown numerics, `null` for an unknown split, `0` for MTP (a real "none"
answer), and `""` for an unknown location.

**All four are retired.** Four sentinel values for one concept is a value for
state being smuggled into the value itself, and it is why pending and absent are
indistinguishable downstream. Every store entry becomes
`{tier, derived, state, value}` with `state` drawn from a four-valued enum —
`exact`, `estimated`, `absent`, `pending` — so "we don't know" is expressed once,
in one place, and a display can render `…` and `—` differently instead of
inferring both from `-1`. Note that `0` is *not* a sentinel: for MTP it is a real
answer, which is exactly the distinction the enum forces you to make. See
[`concern-1-p0-plan.md`](../concern-1-p0-plan.md) §4.1 and §4.2.

### `/slots` `n_ctx` is a tier-1 source

`/slots` returns `n_ctx` for each slot, and for a **loaded** model it is the
**resolved** context length — the value the engine actually allocated, after
`--fit` and after `--ctx-size`. That is strictly better than `meta.n_ctx` from
the availability list, which is the *declared* value and may be overridden.

So `contextLen` reads `/slots` first and falls back to tier 2's
`llama.context_length`, with the precedence stated as a unit test covering both
cases:

| Case | Source | State |
|---|---|---|
| model loaded | `/slots` → `n_ctx` | exact |
| model not loaded | tier 2 → `llama.context_length` | exact |

The decline condition is the absence of a slot for the model, not an unparseable
number: an absent slot means the engine has not allocated, so there is no
resolved value to read and the declared header value is the best available. This
also matters for `kvBytes`, whose `cells` term is `contextLen` — reading a
declared length where a resolved one exists is how a projection comes out wrong.

## 3. What it cannot answer

- **Anything about placement, unless the flags state it outright.** Tier 1
  answers `ngl` when `-ngl` was passed. It cannot answer whether the KV cache
  landed on the device, because `--fit` decides that independently of
  `--n-gpu-layers`. This is the whole reason tiers 4 and 5 exist.
- **The quant.** Not in `meta`, upstream-confirmed. Tier 2.
- **Layer counts and the KV shape.** Tier 2.
- **Anything at all when the model is unloaded.** `/v1/models` describes
  loaded models; the available list (§2 of tier 1's sibling, `models`/
  `_listModels`) is name and size only.

## 4. Under the resolver

```
checkTier1Values(entry, pending):
    // Everything above arrives in one response, so the check is pure.
    return pending ∩ { name, sizeBytes, contextLen, nParams,
                       modelPath, draftPath, ngl, nglDraft, specType,
                       cacheK, cacheV, noKvOffload, ubatch, parallel,
                       swaFull, noKvUnified }

fetchTier1Values(entry):
    // No extra I/O: the walk reuses the refresh cycle's response.
    return fieldsFrom(entry)     // ← _parseLlamaArgs + meta extraction
```

The important property is that tier 1 costs zero I/O *within the resolver* — it
reuses a response that is already being fetched. Under the plan, tier 1 is
"already one batched call", and the walk must not introduce a second one.

## 5. Tests

`tst_derivation.qml`, prefixes `args/*`, `args-inline/*`, `args-kv/*`,
`args-null/*`:

- `args/model`, `args/ngl`, `args/no` — the base `flag value` form.
- `args-inline/*` — the `flag=value` form, including
  `args-inline/parallel-inline`, `args-inline/ubatch-inline`.
- `args-kv/default-ubatch`, `args-kv/default-parallel`, `args-kv/default-swa`
  — the `512 / 1 / off / unified` defaults when the flag is absent. These are
  asserted explicitly because a silent default change would silently change
  every KV size.
- `args-null/*` — a null/absent `args` array returns the empty object rather
  than throwing.

`e2e_model_meta.qml` covers the `meta` half end-to-end: that `meta.n_params`
arrives, that the quant does **not**, that the quant lands via the real tier-2
fold, and that the rendered line is exactly
`Quant: q4_k_m | 30.5B params` with no `~`.

## 6. Gaps to close

1. ~~**`meta.size_vram` probe.**~~ **Closed — negatively.** This was checked
   against the live server's `/v1/models` rather than left unverifiable: the
   `status` object carries **no** `meta` field at all, so there is no
   `meta.size_vram` to read and no free cross-check on tier 5's split. The idea
   is retired rather than deferred. See
   [`concern-1-p0-plan.md`](../concern-1-p0-plan.md) §7.1.1.
2. **Availability-list fields carry no `state` at all** today
   (`ModelsSection.qml:427-443`). With the field store, an unloaded model's size
   and preset intent should read `—` rather than silently omitting the segment.
