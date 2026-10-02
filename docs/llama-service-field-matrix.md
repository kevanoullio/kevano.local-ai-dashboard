# Field matrix — every value and every location variable

This document describes the field resolution for the **llama.cpp service only**.
The ollama backend does not use this tier system — all values come directly from
the engine and are treated as exact.

One row per thing the panel shows. For each: which tier answers it, whether
that answer is exact, every **other** tier that could attempt it, and the
functions that do the work.

Use this to answer "where does this number come from?" without reading
anything else. For *how* a tier works, read its file.

**Legend.**

- **Certainty** — the `state`: `exact` (unmarked), `~` (estimated), `—` (absent),
  `pending`.
- **Kind** — where the value comes from, which is *orthogonal* to certainty:
  - **primary** — read verbatim by a tier. It has a `tier`.
  - **derived** — computed by `applyDerivation()`, so it has **no tier of its
    own**; its tier is the *weakest* input tier.
  - **view** — a display composite, never stored at all.
- **Derived from** — for a `derived` field, the inputs it consumes. This column
  replaces the old "Also: derivation" pseudo-tier, which was smuggling a
  tierless producer into a list of numbered tiers.
- **Also** — other *tiers* that can attempt the field. A single value means there
  is genuinely only one source. Derived producers are never listed here; they are
  named in **Derived from**.

**All six tiers are active.** Tiers 1–4 are the fast path; 5 (projection) and 6
(oracle) are need-gated deep rungs that run only when the header shape is not
fully described. The numbering is
[llama-service-tiers-overview.md](llama-service-tiers-overview.md) §2: API 1, file
2, preset 3, system 4, projection 5, oracle 6. There is no tier 0 and no tier 3.5
— the "3.5" label described today's probe, which becomes tier 6.

---

## 1. The display rows, end to end

`sections/ModelsSection.qml:llamaDetailBlock` (`:67-219`) pushes these in
order. Everything else in the panel is a service-level figure.

| Row | Line | Fields it renders |
|---|---|---|
| `Quant: q4_k_m \| 30.5B params` | `:160-166` | `quant`, `params` |
| `Model Size: 65 layers \| 3.8 GB` | `:167-176` | `mainLayers`, `coreSize` |
| `GPU Layers: 65 \| 3.8 GB \| 100%` | `:179` | `mainGpu`, `weightGpu`, `pctGpu` |
| `CPU Layers: 0 \| 0.0 GB \| 0%` | `:180` | `mainCpu`, `weightCpu`, `pctCpu` |
| `Draft: mtp \| 1 layer \| 0.2 GB on GPU` | `:181-194` | `specType`, `mtpLayers`, `mtpSize`, `mtpGpu`, `mtpCpu` |
| `Context: 262,144 tok on CPU` | `:196-198` | `contextLen`, `kvLocation` |
| `KV Cache: 2.8 GB (K q8_0 / V q8_0) on CPU` | `:199-205` | `kvBytes`, `cacheK`, `cacheV`, `kvLocation` |
| `GPU Total: ~12.8 GB` | `:210-212` | `weightGpu + mtpGpuShare + kv·[on GPU]` |
| `CPU Total: ~3.3 GB` | `:214-216` | `weightCpu + mtpCpuShare + kv·[on CPU]` |

---

## 2. Values

### 2.1 Identity and metadata

| Field | UI label | Plan tier | Certainty | Also | Functions | Property |
|---|---|---|---|---|---|---|
| model name | *(row label)* | **1** | exact | — | `_finishJsonModels` | `name` |
| `sizeBytes` | `Model Size: … \| X GB` | **1** | exact | 3 (`size`) | `parseInt(meta.size)` | `sizeBytes` |
| `contextLen` | `Context: N tok` | **1** | exact | — | `_applySlotsContext` (`/slots` `n_ctx`) supersedes `/v1/models` `meta.n_ctx` | `contextLen` |
| `nParams` | `… \| 30.5B params` | **1** | exact | — | `parseInt` → `_formatCount` | `nParams` |
| `ftype` | `Quant: q4_k_m` | **2** | exact | — | `_applyGguf` → `_ftypeLabel` | `ftype` |
| `modelPath` | *(internal)* | **1** | exact | — | `_parseLlamaArgs` | `modelPath` |
| `draftPath` | *(internal)* | **1** | exact | — | `_parseLlamaArgs` | `draftPath` |
| `isCloud` | `☁` | **1** | exact | — | `isCloudModel` | `isCloud` |
| `processor` | `ollama: CPU 45% / GPU 55%` | **1** | exact | — | `ollamaDetailLine` | `processor` |

`nParams` comes from `meta.n_params` and the quant does **not** come from the
API (upstream-confirmed; `e2e_model_meta.qml` pins it). The `processor` split
has **no marker machinery at all** today — an unparseable string yields
`""` and the row says `Memory unavailable`.

`contextLen` is **tier-1 only** and has **no tier-2 fallback**. `/slots` `n_ctx`
is the resolved (`fit`-decided) allocation and supersedes the declared
`meta.n_ctx`; when neither is available the field stays unanswered. The header's
`<arch>.context_length` is the *trained capacity* and is never read — see
[tier 1](llama-service-tier-1-server-api.md) and the rejection note in
[concern-1 §7.1](../concern-1-p0-plan.md).

### 2.2 Flags read from `status.args`

All **exact**, all tier 1, all from `_parseLlamaArgs` (`Service.qml:734`).
Each one is listed because each is an **input** to another tier's answer, not
just a display value.

| Flag | Property | Default | Feeds |
|---|---|---|---|
| `-ngl` / `--n-gpu-layers` | `ngl` | `""` | `mainGpu`/`mainCpu` (direct) |
| `-ngld` / `--n-gpu-layers-draft` | `nglDraft` | `""` | `mtpGpu`/`mtpCpu` (direct) |
| `--cache-type-k` | `cacheK` | `""` ⇒ `f16` | KV bytes × bits |
| `--cache-type-v` | `cacheV` | `""` ⇒ `f16` | KV bytes × bits |
| `--no-kv-offload` | `noKvOffload` | `false` | `kvLocation` ⇒ CPU, exact |
| `--ubatch` | `ubatch` | `512` | SWA cell law, tier-6 argv |
| `--parallel` | `parallel` | `1` | SWA cell law, tier-5/6 argv |
| `--swa-full` | `swaFull` | `false` | SWA cell law, tier-6 argv |
| `--no-kv-unified` | `noKvUnified` | `false` | `parallel` multiplier |
| `--spec-type` | `specType` | `""` ⇒ `mtp` | Draft row label |

### 2.3 Layer counts

| Field | UI label | Plan tier | Certainty | Also | Functions |
|---|---|---|---|---|---|
| Field | UI label | Kind | Tier | Certainty | Derived from | Also | Functions |
|---|---|---|---|---|---|---|---|
| `totalLayers` | *(basis for the split)* | primary | **2** | exact | — | — | `_finishGguf` (`block_count`) → `_applyGguf` |
| `mainLayers` | `Model Size: 65 layers` | **derived** | — | exact | `totalLayers`, `mtpLayers` | — | `applyDerivation` — `total − mtp` |
| `mtpLayers` | `Draft: … 1 layer` | primary | **2** | exact | — | 3 (draft's own `bc`) | `_applyGguf` / `_applyGgufDraft` |
| `mainGpu` | `GPU Layers: 65` | **derived** | — | exact | `ngl` (1), `presetNgl` (3), `totalLayers`, `mtpLayers` | — | `applyDerivation` → `_mtpSplit` |
| `mainCpu` | `CPU Layers: 0` | **derived** | — | exact | same | — | same |
| `mtpGpu` | `Draft: … on GPU` | **derived** | — | exact | `nglDraft` (1), `mtpLayers` (2) | — | `applyDerivation` → `_mtpSplit` |
| `mtpCpu` | `Draft: … on CPU` | **derived** | — | exact | same | — | same |
| `pctGpu` | `100%` | **derived** | — | `~` iff split is `~` | `mainGpu`, `mainLayers` | — | `_percentLayersOnGPU` |
| `pctCpu` | `0%` | **derived** | — | `~` iff split is `~` | `mainCpu`, `mainLayers` | — | `_percentLayersOnCPU` |

**All four location-count fields now have exactly one writer, and that fixes the
bug.** `mainGpu`/`mainCpu` were written by **four** code paths and
`mtpGpu`/`mtpCpu` by **two**, with the demand-gated applier `_applyProbeSplit`
setting only two of the four — so a field's answer depended on which tier
happened to run last. The fix is not a convention that all four writers keep four
fields in sync; it is that `_mtpSplit` is now the **only** function that turns an
`-ngl` count into four numbers, and it is called by `applyDerivation` rather than
by a tier. Three of the four old writers are deleted.

That is also why `mainGpu` is `Kind: derived` with **no tier**: a derived field
has no tier of its own, so the `CAPABILITIES` ∩ `DERIVATIONS` = `{kvBytes}`
invariant has exactly one member and cannot silently grow a second. See
[`concern-1-p0-plan.md`](../concern-1-p0-plan.md) §7.1, §10 and §5.1.

### 2.4 Byte quantities

| Field | UI label | Kind | Tier | Certainty | Derived from | Also | Functions |
|---|---|---|---|---|---|---|---|
| `weightGpu` | `GPU Layers: … \| 3.8 GB` | derived | — | `~`, floored | `coreSize`, `mainGpu`, `mainLayers` | — | `_resolveWeights` |
| `weightCpu` | `CPU Layers: … \| 0.0 GB` | derived | — | `~`, floored | same | — | `_resolveWeights` |
| `mtpSizeBytes` | `Draft: … 0.2 GB` | derived | — | exact | `sizeBytes`, `mtpLayers`, `totalLayers` (all 2) | 3 (draft file size) | `applyDerivation`; `_applyGgufDraft` `g.sz` |
| `coreSize` | `Model Size: … \| X GB` | derived | — | exact | `sizeBytes` (2), `draftSizeBytes`, `mtpSizeBytes` | — | `applyDerivation` |
| `kvBytes` | `KV Cache: 2.8 GB` | derived → **6** | — | exact, or `~` if bounded/block-unaligned | `totalLayers`, `cacheK`/`cacheV`, `contextLen`, `kvDescribed`, `kvBlockAligned` | **5** (per-device sum) | `_buildKvLayers` → `_kvEstimateBytesArch` |
| `computeBytes` | *(not displayed)* | primary | **5** | **`~` permanent** | — | 6 (**deleted**) | tier-5 `compute` column |
| `gpuTotal` | `GPU Total: ~12.8 GB` | **view** | — | composite | — | — | `ModelsSection.qml:210-212` |
| `cpuTotal` | `CPU Total: ~3.3 GB` | **view** | — | composite | — | — | `ModelsSection.qml:214-216` |

Three rows here changed shape, and each was a bug:

- **`kvBytes` reads `derivation → 6`, with no tier-5 rung.** Tier 5's
  `CAPABILITIES` entry is `kvGpuBytes`, `kvCpuBytes` and `computeBytes` — it does
  **not** produce `kvBytes`. Summing the two 1 MiB-rounded `context` cells would
  be a projection of a model that is not loaded, which is strictly worse than the
  alternative. So the chain is derivation, else tier 6, and nothing in between.
- **`kvBytes` is exact, or `~` if bounded or block-unaligned — never promoted
  *by* alignment.** Block alignment used to read as "promote to exact once
  implemented". It is not a promotion path: a non-aligned tensor still yields a
  computable value, marked `~`, and tier 6 is **not** spawned. Escalating there
  would send every `q5_0`-K / `q4_0`-V model through a 3–45 s oracle run to
  compute something the header already determines.
- **`computeBytes` is permanently `~`.** Not "provisional pending corroboration"
  — permanently. Corroboration is declined, not deferred; see
  [`concern-4-p2-plan.md`](../concern-4-p2-plan.md).

`gpuTotal` and `cpuTotal` are **view** composites and are never stored, which is
why they have no Kind other than `view` and no tier at all.

`coreSize` exists so the Model Size row and the Draft row do not overlap:

```js
draftSize > 0                 → coreSize = sizeBytes                    // separate draft
else mtp > 0 && mtpSize > 0   → coreSize = max(0, sizeBytes - mtpSize)  // built-in MTP
else                           → coreSize = sizeBytes
```

**`gpuTotal` / `cpuTotal` hardcode `~`** regardless of their inputs
(`ModelsSection.qml:212,216`) — a `state` bug, since both can be exact. Both
also add the cache only when `ctxOn === "GPU"` / `=== "CPU"` exactly, so a
`GPU/CPU` split would be added to **neither**. Both are fixed by the new
`GPU/CPU` placement value: the totals add the matching `kvGpuBytes` or
`kvCpuBytes` instead of switching on a string.

### 2.5 Service-level values

Not per-model; read from the tier-4 probes and the health endpoints.

| Field | Source | Certainty | Functions |
|---|---|---|---|
| `serviceMemoryBytes` | cgroup `anon+shmem` | exact (`~` on the `MemoryCurrent` fallback) | `serviceMemoryScript` → `_finishServiceMemory` |
| `serviceVramBytes` | per-PID GPU memory | exact | `serviceVramScript` → `_finishServiceVram` |
| `serviceTotalBytes` | sum | exact | `_deriveServiceTotal` |
| `cpuSplitPercent` | `mem / total` | `~` | `cpuSplitPercent` |
| `apiReachable` | `GET /health` | exact | `_parseApiBuffer` |
| `apiLatencyMs` | curl `time_total` | exact | same |
| `ollamaVersion` | `--version` | exact | `_onVersionLine` |

`serviceMemoryBytes` / `serviceVramBytes` / `serviceTotalBytes` are `double`
not `int`, so a footprint above 2 GiB does not overflow a 32-bit QML int.

---

## 3. Location variables

**This is the section the plan is really about.** A *location* answers "which
device does this live on" — a different question from "how big is it", and
the one the current code gets wrong.

### 3.1 The answer vocabulary

Three values plus one non-answer, and each has a different certainty:

| Value | Meaning | Certainty |
|---|---|---|
| `GPU` | entirely on a device | exact (a tier-1 flag, or rung 1) or `~` (rung 2 bounds it) |
| `CPU` | entirely in host RAM | exact (tier-1 flag branches, or rung 3) or `~` |
| `GPU/CPU` | **split**, both non-zero | `~` — rung 2 bounds it; tier 5's per-device split resolves it directly |
| `""` | **indeterminate** | `—` |

`""` is *not* "unknown because we have not looked" — that is `pending`. `""`
means looked at, and the answer is genuinely indeterminate. Today these are
conflated, and `_kvPlacement` has no `GPU/CPU` value at all.

### 3.2 Every location variable

| Location variable | UI text | Kind | Certainty | Deciding functions |
|---|---|---|---|---|
| `kvLocation` | `KV Cache: … on GPU` / `on CPU` | **derived** | exact / `~` | `applyDerivation` → the ladder in §3.3 |
| `ctxLocation` | `Context: N tok on GPU` | **derived** | same | **shares `kvLocation`** — one decision, two rows |
| `mainGpuLocation` | `GPU Layers: 65 \| 3.8 GB \| 100%` | **derived** | exact | `mainGpu != null` ⇒ a device holds layers |
| `mainCpuLocation` | `CPU Layers: 0 \| …` | **derived** | same | `mainCpu != null` |
| `mtpGpuLocation` | `Draft: … on GPU` | **derived** | exact | `ModelsSection.qml:185-192` |
| `mtpCpuLocation` | `Draft: … on CPU` | **derived** | same | same |
| `computeLocation` | *(not displayed)* | primary | `~` permanent | tier 5's per-device `compute` column |

`kvLocation` carries **no tier**, and that is the substantive change. It used to
be written by tier 4 as a one-shot verdict, which is precisely why it could not
be *revised* when better inputs landed: the tier had already committed, so a
corrected `kvBytes` arrived too late to matter. As a derivation it is **retried
on every settle**, so `mainGpu` landing after `memBytes`, or `kvBytes` being
corrected by tier 6, both re-run the ladder. The `GPU/CPU` case is also why the
ladder is a derivation rather than a switch — it has three real answers, not two.

`Context` and `KV Cache` **share one placement decision**
(`ModelsSection.qml:147`, consumed at `:197` and `:204`). That is right — the
context lives in the cache — and it is why a placement bug corrupts two rows
at once.

### 3.3 `kvLocation` — the decision ladder

This is a **derivation**, so the table below is walked top to bottom on every
settle rather than entered at a tier. Rows 0a–0b are tier-1 flags and are not
gated on `sole`; rows 1–4 are tier-4 readings and are.

| # | Condition | Verdict | Certainty | Cost |
|---|---|---|---|---|
| 0a | `noKvOffload === true` | `CPU` | exact | 0 |
| 0b | `main > 0 && gpuLayers === 0` | `CPU` | exact | 0 |
| 0c | `kvBytes` unknown | `""` | `—` | 0 |
| 0d | `sole === false` | `""` (unless 0a/0b) | `—` | 0 |
| 1 | `hostAnon == 0` ∧ device held | `GPU` | exact | ~20 ms |
| 2 | `0 < hostAnon < kv` ∧ device held | `GPU/CPU` | `~` | ~20 ms |
| 3 | no device context | `CPU` | exact | ~20 ms |
| 4 | `hostAnon >= kv` ∧ device held | `""` **indeterminate** | `—` | ~20 ms |
| 5 | `kvGpuBytes` / `kvCpuBytes` available | `GPU` / `CPU` / `GPU/CPU` per the split | `~` | ~555 ms |
| 6 | `""` — nowhere | `—` | — | — |

**Row 5 is a reading, not a corroboration.** This row previously read "tier 5
corroborated" and returned `exact` on agreement. That is withdrawn for two
independent reasons, and the second is the one that matters:

- The corroboration *gate* was withdrawn — a projection that degrades to `~` on
  disagreement while otherwise agreeing with itself is not being tested. See
  [`concern-4-p2-plan.md`](../concern-4-p2-plan.md).
- **Tier 5 cannot return `exact` even if it wanted to.** `llama-fit-params`
  rounds its `context` column to whole MiB, so the value is a 1 MiB-rounded
  projection by construction. "Corroborated" would have been a claim about
  agreement to within a rounding step, which is not what the word means.

What row 5 does now is supply the one per-device KV split that exists anywhere in
the system. `_kvPlacement` used to have no `GPU/CPU` value at all, so rung 2's
bounded answer could not be expressed; tier 5's `CUDA0 … 5527 … / Host … 3326 …`
rows state it directly, and they are `~` because they are a projection of an
unloaded model — never promoted.

**Rung 4 is today's bug.** `Service.qml:1155`:

```js
if (mem >= kv) return "CPU"
```

The gemma worker: host anon 2,928.6 MiB against a 2,879.4 MiB cache — 49.2 MiB
over — so it fires, and the answer is wrong. Host anon is *everything private
in RAM*, not the cache; it exceeds the cache by an arbitrary amount depending
on the split, so `>=` is consistency, not proof.

**Rung 2 is a capability gap, not just a bug fix.** `_kvPlacement` returns
only `"GPU" | "CPU" | ""`. The `GPU/CPU` value has to be added, and
`ModelsSection.qml:211,215` has to handle it, or the cache is added to
neither total.

**Rung 2's answer is inferred; tier 5's is stated.** Rung 2 infers a split from
host anon being *smaller* than the cache, which bounds it without proving it —
hence `~`. Tier 5's rows state the split outright, which is why they are the
only direct evidence for rung 2 that exists, and why row 5 reads the split rather
than dividing `mem / kv`.

The full ladder, its attribution rules and its six preconditions are in
[`concern-2-p1-plan.md`](../concern-2-p1-plan.md); the projection it reads is in
[llama-service-tier-5-engine-projection.md](llama-service-tier-5-engine-projection.md) §2.

---

## 4. The one-line summary

For every row above:

| | |
|---|---|
| **Exactly one producer** | every field in `CAPABILITIES`, one tier each — asserted by `capabilities/table`, so a second writer cannot appear silently |
| **`CAPABILITIES` ∩ `DERIVATIONS`** | exactly `{kvBytes}`, and nothing else — asserted as a set, so the exception cannot quietly grow a second member |
| **Derived, tierless** | `mainGpu`, `mainCpu`, `mainLayers`, `mtpGpu`, `mtpCpu`, `weightGpu`, `weightCpu`, `coreSize`, `mtpSizeBytes`, `kvLocation`, `pctGpu`, `pctCpu` |
| **View only, never stored** | `gpuTotal`, `cpuTotal` |
| **Never exact, by construction** | `computeBytes`, `kvGpuBytes`, `kvCpuBytes` (tier 5 is a rounded projection), `weightGpu`/`weightCpu` (the equal-layer law is false for non-uniform quantisation) |
| **Never obtainable at all** | per-layer residency; per-tensor location; which device a specific tensor is on; a per-GPU VRAM split on ROCm |

---

## 5. Known dead and unwired fields

| Field | Where | Problem |
|---|---|---|
| `kvLayersExact` | `Service.qml:1948`, written `:2231` | Read nowhere outside tests. Deleted with `parseKvLayerCount`. |
| `r.kvDtype` | `Service.qml:1262` | Resolved by the service, never read by `ModelsSection.qml` (which reads `m.cacheK`/`m.cacheV` directly at `:202`). |
| `until: "loaded"` | `Service.qml:1950` | Never read. |
| `computeBytes` | `Service.qml:1949` | Fed by `parseComputeReserve`, which is deleted. Tier 5's `compute` column replaces it. |
| `preset: true` | `Service.qml:1429` | Set by `_presetModels`; not read by the section (which uses `presetIntent`). |
