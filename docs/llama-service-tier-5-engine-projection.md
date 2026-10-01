# Tier 5 — Engine projection

**Cost** ~555 ms measured · **Role** decomposition · **Status** **to build**

This tier is part of the llama.cpp service acquisition ladder. The ollama
backend does not use any of these tiers — it reads everything directly from the
engine.

`llama-fit-params --fit-print on` answers one question the other tiers cannot:
*for this model, with this context and these dtypes, how do the bytes
distribute across devices?*

It is a **projection**, not a measurement. It is the first rung that can produce
a **per-device breakdown** (GPU 0 vs GPU 1 vs host) rather than a service-wide
total, and the first that can attribute a split to layers. It is also a model of
the engine's allocator, so it can be wrong — and this design has **no mechanism
for noticing**. An earlier draft had tier 4 arbitrate this tier; that rule is
withdrawn, for reasons in §5 and
[`concern-4-p2-plan.md`](../concern-4-p2-plan.md).

**Every value this tier produces is permanently `estimated`.** Not "provisional,
pending corroboration" — permanently. The `~` is not a placeholder for a
promotion that has not been built yet; it is the final state. `kvGpuBytes`,
`kvCpuBytes` and `computeBytes` are its only three fields, and there is no
promotion path for any of them.

**Nothing in this tier exists in the code yet.** Everything below is the
specification.

---

## 1. The binary

`/usr/bin/llama-fit-params` — installed alongside `llama-cli` and
`llama-server` on this machine. The relevant options, verbatim from
`--help`:

```
-fit,   --fit [on|off]              adjust unset arguments to fit in device memory
                                      ('on' or 'off', default: 'on')
-fitt,  --fit-target MiB0,MiB1,...  target margin per device for --fit
                                      (default: 1024)
-fitc,  --fit-ctx N                 minimum ctx size that can be set by --fit
--fitp, --fit-print [on|off]        print the estimated required memory
                                      ('on' or 'off', default: 'off')
                                      (env: LLAMA_ARG_FIT_ESTIMATE)
```

It loads the model's hyperparameters and prints a memory estimate. It does not
run inference and does not allocate the cache.

## 2. The output format — verified

**stdout** carries only the table. **stderr** carries a preamble and any
warnings.

Fully offloaded (`--fit off --fit-print on -ngl all -m <14.8 GB model>`):

```
stderr: llama_fit_params: printing estimated memory in MiB to stdout (device, model, context, compute) ...
stdout: CUDA0 13964 16533 505 
        Host 644 0 276 
```

Partial offload, with a context and quantised cache
(`-ngl 40 -c 262144 -np 1 --cache-type-k q8_0 --cache-type-v q8_0`):

```
stdout: CUDA0 8692 5527 2207 
        Host 5915 3326 286 
```

Elapsed: **621 ms**. (The plan's 555 ms figure is the same measurement class.)

### The four columns, and what they mean

| # | Column | Meaning | Where it goes |
|---|---|---|---|
| 1 | device | `CUDA0`, `CUDA1`, `Host`, `CPU`, `ROCM0`, … | classified by §3 |
| 2 | model | weight bytes on that device | `weightGpuBytes` / `weightCpuBytes` |
| 3 | context | KV-cache bytes on that device | `kvBytes` **per device** — the only per-device KV split available |
| 4 | compute | graph/compute-reserve bytes on that device | `computeBytes` per device |

**Column 3 is the important one.** In the partial-offload capture the cache is
**genuinely split**: 5,527 MiB on the device and 3,326 MiB in host RAM,
8,853 MiB total. No other tier can see that. Tier 4 sees a single host total
and a single device total; tier 6's oracle reports KV+recurrent combined. This
split is the concrete reason the placement state needs a third value
(`GPU/CPU`) rather than a boolean.

### Parser requirements

- **Trailing whitespace.** Every row in both captures ends with a space after
  the last column. A split on whitespace must tolerate it, or the last column
  parses as `""`.
- **Rows are one per device, in device order.** Devices with a zero in a
  column are still printed (`Host 644 0 276` — zero context), so **a zero is
  a real value, not a missing one.** Do not treat `0` as absent.
- **Unknown device names must not be silently dropped.** Anything that is not
  a known host token is a device; anything that is a known host token is not.
  An unrecognised name is a *device* by default, because misclassifying a GPU
  as host inverts the split.
- **Rows sum across devices per column.** The `model` column sums to the whole
  model (14,607 MiB against a 14,846 MiB file — the difference is tensors the
  estimator does not charge); the `context` column sums to the whole cache.
- **An empty stdout is "no answer"**, not "zero". The tool prints nothing when
  it cannot build the model (missing file, unreadable hparams).

## 3. Device classification

```js
function classifyDevice(name) {          // "Host" | "CPU" vs device
  var s = String(name || "").trim().toUpperCase()
  if (s === "HOST" || s === "CPU") return "host"
  return "device"                        // CUDA0, CUDA1, ROCM0, HIP0, …
}
```

Then aggregate: **all device rows are summed across GPUs** into one
`deviceTotal`, and host rows into one `hostTotal`. The panel reports one GPU
figure and one CPU figure, so per-device rows are folded — but the *fold* is
where the `GPU/CPU` split survives, because `context` is summed per class
separately from `model`.

Keeping the raw per-device rows in the field store is worth the few bytes: a
future per-GPU row costs nothing to add. The fold order still has to be
auditable, but no longer because a gate compares the folded total against tier 4
— §5 withdrew that comparison.

## 4. How it must be invoked

```bash
ulimit -c 0
exec "$fit" --fit off --fit-print on -ngl "$ngl" \
     -m "$model" \
     -c "$ctx" -np "$np" -b "$batch" -ub "$ubatch" \
     --cache-type-k "$ck" --cache-type-v "$cv" \
     ${swa_full:+--swa-full} ${no_kv_unified:+--no-kv-unified}
```

### The three hard constraints

1. **`--fit off` plus an explicit `-ngl`, always.** This is the one that
   matters most. With `--fit` left on (the tool's default) the estimator
   **re-fits against current free VRAM** and answers `-ngl 0` — which is
   exactly what happened when it was aimed at an already-loaded model. An
   explicit `-ngl` makes the projection deterministic; `--fit off` stops the
   tool second-guessing it.

2. **`--cache-type-k` / `--cache-type-v` must be mirrored.** A mismatch is a
   3× error on the `context` column. These come from tier 1's `status.args`
   (`cacheK` / `cacheV`), so tier 5 has a genuine data dependency on tier 1.

3. **`--flash-attn` must NOT be mirrored.** It does not move the `context`
   column, and `--flash-attn off` **aborts `common_fit_print`**. Passing it
   costs an answer for nothing.

### Exit-code contract

| Situation | Behaviour |
|---|---|
| Binary missing | wrapper **exits 97**, before any spawn. Absence is probed once and cached; a missing `llama-fit-params` never retries. |
| Any non-zero exit | "no answer" → escalate to tier 6 |
| Unparseable stdout | "no answer" → escalate to tier 6 |
| Crash | no core dump (`ulimit -c 0`) |

**Two distinct aborts inside `common_fit_print` have been reproduced.** A
non-zero exit is not a rare edge case to be tolerated; it is a known failure
mode, and the only correct response is escalation.

### The wrapper's other obligations

- `timeout -k 2 N` + `head -c CAP` + a QML watchdog, per
  [llama-service-tiers-overview.md](llama-service-tiers-overview.md) §9.
- **Model path and flags as positional arguments only.** Never interpolated
  into the script string. The `kv_probe.bats` contract
  ("a hostile model path cannot run a command") applies identically here and
  should be extended rather than reinvented.
- Single-flight + a watchdog-kill, exactly like `_kvProbeProcess`.

## 5. Withdrawn: the corroboration gate

**This section is retracted.** The gate below is recorded because the arithmetic
is what killed it:

```
(never implemented)  projected.deviceTotal = Σ over device rows of (model + context + compute)
                     observed.deviceTotal  = tier 4's serviceVramBytes
                     accept  ⟺  |projected − observed| ≤ tolerance
                               AND  perLayerStep > offsetUncertainty
                               →  definitive, state EXACT
                     degrade ⟼  otherwise → observation wins; projection renders "~"
```

The calibration, from the live worker:

```
projected : 10,616 + 1,694 + 505 = 12,815 MiB
observed  :                      12,972 MiB
gap       :                        157 MiB  (1.2 %)
per-layer step:                     ~80 MiB
```

The step is ~2× the gap, and that looked like unique discrimination. It is not,
for two reasons that are now settled:

- **The 157 MiB is a residual, not a measurement.** It is CUDA context plus
  whatever is unaccounted for. A tolerance centred on an unexplained quantity is
  not a tolerance.
- **The gate cannot fail, and cannot discriminate where it matters.** Where the
  per-layer step is *smaller* than the offset's uncertainty — small models, tiny
  layers — the observation cannot resolve the offload count at all, so the check
  is vacuous precisely in the regime where it would be load-bearing.

So the gate is **declined, not deferred**, and `~` is permanent. Two further
points killed it: `llama-fit-params` rounds its `context` column to whole MiB, so
the comparison loses precision exactly at the scale of the offset; and a
`~`-forever value that degrades to `~` on disagreement is indistinguishable from
one that is simply `~`.

The six preconditions that would have to change to reopen this are in
[`concern-4-p2-plan.md`](../concern-4-p2-plan.md) §5. Tier 4's own record of the
withdrawal is in
[llama-service-tier-4-system-observation.md](llama-service-tier-4-system-observation.md) §6.

## 6. What it replaces

### 6.1 `_estimateSplitFromProbes` is retired

`Service.qml:1284` today:

```js
weightOnGpu = vramBytes − kvOnGpuBytes − computeBytes
gpuLayers   = round(weightOnGpu / sizeBytes × totalLayers)
```

This is a **ratio estimate**: it assumes the model's weight bytes distribute
uniformly across layers, which is false for any quantisation with non-uniform
block sizes. It is marked `~` today and stays `~` after the change, but it becomes a
**precondition** for `weightGpu` / `weightCpu`, not a fallback path for tier 5
failing. The distinction matters: tier 5's absence means "we did not run it",
which is not an error state the placement ladder needs to paper over, and the
equal-layer law is a weaker claim than a projection, so it is the floor rather
than the rescue. Its inputs (tier 4's VRAM, the KV size, the compute reserve)
remain useful; the ratio assumption is the part that goes.

### 6.2 `parseComputeReserve` is deleted

Today the compute-graph reserve comes from tier 6's `sched_reserve` line, and
the *probe's* device — which is `CPU`/none, because the probe runs `-dev none`.
It is the wrong number for the wrong machine. Tier 5's `compute` column is
per-device and for the **real target device**, so it is a strictly better
source. The parser's only two consumers (`Service.qml:1248`,
`Service.qml:2258`) both feed `_estimateSplitFromProbes`, which is itself being
retired.

## 7. What it cannot answer

- **Anything about the running worker.** It projects a hypothetical. Only tier
  4 says what is true.
- **The realized offload when `--fit` decided it.** With `--fit off` it
  reports what you asked for, not what the engine chose. The plan's gemma case
  is exactly this: the preset says `fit = on`, no `-ngl` exists, and the
  engine's choice is invisible here.
- **Anything when the cache dtype is unknown.** Constraint 2 above means an
  unmirrored dtype is a 3× error, so an unset `cacheK`/`cacheV` must be
  resolved to llama.cpp's `f16` explicitly before the call, or the tier must
  decline.
- **The CUDA context.** The 157 MiB residual is not modelled and not
  predictable. It is the reason the gate needs a tolerance rather than
  equality.
- **Per-layer residency.** It gives per-*device* totals, and the panel's
  layer-count split from them is still a `~`.

## 8. Where the code goes

New, mirroring the `_kvProbe*` scaffold exactly:

| Piece | Mirrors |
|---|---|
| `kvFitScript` | `kvProbeScript` (`Service.qml:667`), plus the exit-97 absence probe and `ulimit -c 0` |
| `kvFitBinary`, `kvFitTimeoutSec` | `kvProbeBinary`, `kvProbeTimeoutSec` (`Service.qml:628-630`) |
| `kvFitProcess` + watchdog | `kvProbeProcess`, `_kvProbeWatchdogMs` |
| `_kvFitCache`, `_kvFitQueue` | `_kvProbeCache`, `_kvProbeQueue` (`Service.qml:1992-1993`) |
| `_kvFitSignatureFor` | `_kvProbeSignatureFor` (`Service.qml:2009`) |
| `_parseKvFitLine` | `_parseKvProbeLine` (`Service.qml:2090`) |
| `classifyDevice` | new |
| the corroboration gate | new |

**The signature must include `-ngl`.** Unlike the tier-6 probe, whose size is
device-independent, tier 5's answer *depends* on the offload count, so a
change to `-ngl` must re-project. The signature is therefore
`modelPath|ngl|ctx|np|batch|ubatch|cacheK|cacheV|swaFull|noKvUnified`.

## 9. Tests

- **`tst_derivation.qml`**, new groups:
  - `fit/parse-*` — the verified output format, including the **trailing
    space**, a **zero context column** on a real row, and an **empty stdout**
    → no answer.
  - `fit/classify-*` — `Host` → host, `CPU` → host, `CUDA0` / `CUDA1` /
    `ROCM0` → device, an **unknown** name → device (never host).
  - `fit/fold-*` — device rows summed across GPUs; `context` summed per class
    separately from `model`, so a split survives the fold.
  - `corroboration/accept` — the 12,815 vs 12,972 calibration → definitive.
  - `corroboration/reject` — outside tolerance → `~`, observation wins.
  - `corroboration/cannot-discriminate` — per-layer step below the offset
    uncertainty → `~`, and the assertion that this is *not* recorded as a pass.
  - `fit/argv-*` — `--fit off` and an explicit `-ngl` are always present;
    `--flash-attn` is never present; `--cache-type-k/v` mirror the entry;
    `ulimit -c 0` is present.
- **A new `kv_fit.bats`**, modelled on `kv_probe.bats`: argv passes through
  unchanged; **a hostile model path cannot run a command**; a missing engine
  exits 97 without a hang and is not retried; a non-zero exit is "no answer";
  the tool's own output survives the wrapper.
- **`tests/support/dump_constants.qml`** gains `"kvFitScript"` to the dumped
  names array, so `kv_fit.bats` executes the exact string the panel uses.
  (`kvProbeScript` is already in that list; the `tests/README.md` inventory is
  stale on this point.)

## 10. Open questions

1. **Is the `compute` column a sound substitute for `sched_reserve`?** The
   plan flags this as needing one genuinely split model. The
   `-ngl 40 -c 262144` capture in §2 **is** a split model in the projection
   sense (`CUDA0 8692/5527/2207` + `Host 5915/3326/286`), but the two existing
   comparison data points come from different models, so a same-model
   comparison is still needed.
2. **Multi-GPU row naming.** `CUDA0`/`CUDA1` is the observed convention here;
   a multi-GPU capture has not been taken, so the parser's device-name handling
   is unverified beyond `CUDA0` and `Host`.
3. **Does the estimator's `model` column reproduce `meta.size`?** The observed
   sum was 14,607 MiB against a 14,846 MiB file — a 1.6 % shortfall. If that
   gap is systematic it becomes a second term in the corroboration tolerance;
   if it is model-specific it does not.
