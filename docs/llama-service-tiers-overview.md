# The six acquisition tiers — overview

**This document describes the tier system for the llama.cpp service only.** The
ollama backend uses a separate model: all values come directly from the engine
(`ollama ps`, `ollama list`) and are treated as exact. There is no tier ladder,
no field store, and no resolver for ollama.

The six tiers below describe how every number and every location variable shown
in the dashboard is acquired for **llama.cpp loaded models**. The design lives in
the five concern files at the repository root —
[`concern-1-p0-plan.md`](../concern-1-p0-plan.md) (field store, resolver,
derivation registry, KV arithmetic), [`concern-2-p1-plan.md`](../concern-2-p1-plan.md)
(the placement ladder), [`concern-3-p1-plan.md`](../concern-3-p1-plan.md) (tier 5's
engine projection), [`concern-4-p2-plan.md`](../concern-4-p2-plan.md) (declined
corroboration) and [`concern-5-p2-p3-plan.md`](../concern-5-p2-p3-plan.md)
(documentation and test assertions). This document is the working expansion of
those; where the two differ in detail, **the concern files win and this document
is wrong.**

The one-sentence version: **ask every rung, then keep the strongest answer each
field actually received — and let a rung that cannot answer say so instead of
answering badly.**

---

## 1. Governing principles

- **Certainty and cost are orthogonal.** `~` marks certainty, never cost. An
  exact value from a 45 s source outranks an estimate from a 1 ms source. A
  cheap tier is never promoted to "definitive" because it is cheap, and an
  expensive one is never demoted because it is slow.
- **Cost governs scheduling, not membership.** The panel never blocks. A slow
  tier still runs whenever it is the only mechanism that can answer. Cost only
  decides *when* a rung is visited, and how eagerly the walk tries to stop
  before it.
- **Every value and location gets filled.** `—` means *looked for, cannot be
  had* — never *not yet looked*, which is the distinct `pending` state. Today
  these two collapse into the same em-dash, and the display keys "no value" off a
  `-1` sentinel rather than off the state. Both are fixed by the four-state model
  in [`concern-1-p0-plan.md`](../concern-1-p0-plan.md) §4.1 and §8.
- **Nothing arbitrates anything.** Tier 4 measures the machine and tier 5 models
  it, but a disagreement between them is **not** resolved in favour of either.
  Each rung holds a reading; the resolver takes the strongest one available and
  the display states its certainty. A rung that cannot answer declares so, which
  is what keeps the KV-placement bug from recurring (§6).

## 2. The six tiers

| # | Tier | Cost | Role | Mechanism | Status |
|---|---|---|---|---|---|
| 1 | Server API | ~5 ms | definitive | `GET /v1/models` incl. `status.args` | **exists** |
| 2 | Model file | ~15 ms | definitive | bounded 16 KiB GGUF header | **exists** |
| 3 | Preset config | ~5 ms | definitive | `models.ini` section over `[*]` → `presetNgl` | **exists** |
| 4 | System observation | ~20 ms | measured | per-PID `nvidia-smi`/`rocm-smi`, cgroup `anon+shmem` | **exists** |
| 5 | Engine projection | ~555 ms typical | decomposition | `llama-fit-params --fit off --fit-print on -ngl N` | **to build** |
| 6 | Deep engine observation | 3–45 s | definitive | `llama-cli --verbose` | **partly exists** (as today’s "Tier 3.5" probe) |

Tiers 1–4 are active in the shipped panel; **5 and 6 are planned and not yet
built.**

Cost is wall-clock for one model, and is dominated by process spawn — hence
"already one batched call" for tier 1 and "one 555 ms run per model, not per
refresh" for tier 5. 555 ms is the *typical* figure; the single run recorded on
this machine elapsed 621 ms, which is the same measurement class rather than a
contradiction.

**Walk order is by tier number, but the walk stops early.** Derivation (§3)
runs after *every* commit, so the walk almost always terminates before tier 5
and never before tier 2. Tier 6 runs only under a condition no other tier can
satisfy (§8).

### Why these six and not the README's five

`README.md` documents the same six rungs; this document answers "what do we run,
and when do we stop". The differences from the older five-rung sketch are
deliberate:

- **Tier 3 acquires a raw token, it does not compute a split.** It reads the
  preset's `n-gpu-layers` and commits it as `presetNgl`, and nothing else. This
  retires the old reason for ordering GGUF before the preset — that tier 3 needed
  `totalLayers` to turn a layer count into a split — so **the two no longer have
  a forward dependency and may settle in either order**.
- **`mainLayers` moves out of tier 2 into derivation.** It is `totalLayers −
  mtpLayers`, which is arithmetic, so a tier writing it made tier 2 a second
  source of the same number. Removing it is also what frees tier 2 from having to
  precede tier 3.
- **Derivation is removed from the ladder entirely** (§3), and the
  `CAPABILITIES` / `DERIVATIONS` tables are held disjoint — with one declared
  exception, `kvBytes`, whose derivation is the preferred producer and tier 6 is
  its fallback. See [`concern-1-p0-plan.md`](../concern-1-p0-plan.md) §5.1.
- **System observation is a reading, not an arbiter.** It no longer arbitrates
  tier 5; see §6 and [`concern-4-p2-plan.md`](../concern-4-p2-plan.md).
- **Tier 5 is demoted from "the best answer for KV size" to a precondition.** The
  header describes the same shape, and derivation over exact inputs is exact, so
  tier 5 runs only for models whose shape the header cannot describe (§3, §8).

## 3. Derivation is not a tier

Derivation is **exact arithmetic over whatever the tiers already hold**. It is
not a rung, has no cost, and is not a source — it has no I/O, no process, and
no place in `capabilities()`.

Three consequences:

1. **It runs after every tier commits, not after tier 6.** A field is filled
   the instant its inputs land, so the walk stops as soon as nothing is
   pending. For a model whose KV shape the GGUF header fully describes, the
   walk never spawns tier 5.
2. **Exact inputs give exact outputs.** If every input is exact and the
   arithmetic is the real law, the result is exact and renders unmarked. A
   `~` anywhere in the inputs propagates to the output, always.
3. **A derivation is only exact when its *shape* is fully described.** The
   canonical case is the KV cache size: summing `Σ (K+V)·cells` over per-layer
   specs is byte-exact when the header declares the layer types
   (`sliding_window_pattern`, or `full_attention_interval` / `recurrent_layers`,
   or an explicit `sliding_window == 0`) **and** the cache is unified. An
   undescribed shape is not "roughly right" — it is unknown, and tier 6 is the
   only thing that can answer it. This is why `_buildKvLayers` returns `null`
   rather than a guess.
4. **A non-unified cache is bounded, not unknown.** Under interleaved
   sliding-window attention some layers allocate `n_ctx` and some allocate their
   window, so the header gives a range rather than a number:

   ```
   lo = Σ_attention (K_bytes + V_bytes) × min(n_ctx, known_window)
   hi = Σ_attention (K_bytes + V_bytes) × n_ctx
   ```

   `hi` is reported as `~` and the bound is carried so the display can show a
   range. A uniform-width model is exact even when the window pattern is
   unknown, because a unified cache allocates `n_ctx` for every layer
   regardless — the window affects *use*, not *allocation*.
5. **A quant-block-unaligned tensor is `~`, not a decline.** This one was
   backwards and is load-bearing. A tensor whose declared width is not a whole
   number of its quantisation block is still *describable*: the header states the
   width, the arithmetic is exact, and the only consequence is that the engine
   pads the tensor to a block boundary — which the derivation adds back. Treating
   this as "genuinely unknown" would send every `q5_0`-K / `q4_0`-V model, the
   `qwen3.8-27b-fast` case, to a 3–45 s oracle run to compute something the header
   already determines. See [`concern-1-p0-plan.md`](../concern-1-p0-plan.md) §5.2.4.

The current code already has most of the arithmetic; what it lacks is the
*certainty* half. Today `_resolveKvBytes` hardcodes the header derivation to
`marker: "~"` (`Service.qml:2280`) and the UI hardcodes `~` on the two totals
(`sections/ModelsSection.qml:212,216`). Both are markers, not facts.

## 4. Certainty rules

Every field carries exactly one `state`, drawn from a four-valued enum. The state
is a property of the **argument**, never of the source's prestige or duration.
The `marker` string is retired; the display keys off `state` instead.

| State | Glyph | Meaning |
|---|---|---|
| `exact` | *unmarked* | Read verbatim from a definitive source, **or** exact arithmetic on exact inputs with the shape fully described. |
| `estimated` | `~` | Derived from a behavioural inference (flag-derived placement, VRAM-ratio split, fit-projection), a bounded range, or consuming a `~` anywhere upstream. |
| `absent` | `—` | Exhausted: every rung and the derivation declined, and no cheaper source could ever answer. |
| `pending` | `…` | In flight at a named tier. The panel is looking and the answer is coming. |

`derived` is a **separate, orthogonal** boolean answering *was this computed
rather than read*. `mainGpu` is `derived: true` and `exact`; `kvBytes` from
`llama-fit-params` is `derived: false` and `estimated`. Every store entry is
`{tier, derived, state, value}`, and the tier is the **weakest** input tier — so
a `GPU/CPU` placement inherits `estimated` from the tier-5 split it rests on.

### Marker propagation

```
exact ─┬─ exact  ──▶ exact
       ├─ ~      ──▶ ~
       └─ absent ──▶ (no field)
~     ─┬─ ~      ──▶ ~
       ├─ exact  ──▶ ~
       └─ absent ──▶ (no field)
```

Two special cases:

- **A tier-5 value stays `estimated` permanently.** It is never promoted, because
  there is no corroboration path — see [`concern-4-p2-plan.md`](../concern-4-p2-plan.md)
  for why corroboration is declined rather than deferred, and what would have to
  change to reopen it.
- **A field with a value but no source** is impossible by construction. Every
  value is written by exactly one rung, or by derivation over rung-written values.

The effective-tier rule replaces "first commit wins", which made precedence an
emergent property of table order and let a weak derivation permanently block a
stronger rung. A commit is accepted only when no better-ranked tier has already
answered; derivation, being tierless, never displaces a read.

### What each marker costs

- `—` is a *claim*: "we looked everywhere". It must never be reachable
  before the walk has actually run.
- `pending` is a *promise*: "a named tier is running right now". It must name
  that tier in the tooltip.
- Neither is a silent failure. A field that is `—` because the process died
  before tier 4 ran is a bug in the resolver, not an honest unknown.

## 5. The resolver

**There is no linear `resolveAll()` loop.** Tiers 2, 4, 5 and 6 are async QML
processes and tier 6 takes 3–45 s, so a synchronous walk over `[1..6]` would
block the QML thread on first load. Instead:

1. A **field-set seed** at store creation — every field in `FIELD_TIERS` ∪
   `DERIVATIONS` pending.
2. Per rung, a `checkTierNValues(store)` predicate and, inside that rung's async
   callback, a `commit` / `decline` pass followed by `applyDerivation()` +
   `markSettled()`.
3. A **per-field join** for termination.

```js
function _settle(store) {                 // after every commit and every decline
  if (!store) return
  applyDerivation(store)                   // pure arithmetic; may resolve the rest
  store.markSettled()
  _republish(store)
}

function applyDerivation(store) {
  for (var name in DERIVATIONS) {
    if (!store.needsMore(name)) continue
    var d = DERIVATIONS[name], v = ({})
    for (var i = 0; i < d.inputs.length; i++) {
      var e = store.get(d.inputs[i])
      if (!e || e.state === STATE.PENDING) { v = null; break }
      if (e.state === STATE.ABSENT)       { v = null; break }
      v[d.inputs[i]] = e.value
    }
    if (!v) continue                        // stays pending, retried next settle
    var out = d.compute(v, store)
    if (out === DECLINE) continue           // stays pending for a real tier
    store.commit(name, out.value, out.state || STATE.EXACT, null, d.inputs, d.floor)
  }
}
```

Three rules make the ladder work without a special case for derivation:

- A derivation is **retried**, not scheduled. It declines while an input is
  unsettled, so there is **no ordering constraint between tiers and
  derivations** — which is what retires the old "tier 2 must precede tier 3"
  reasoning.
- It **cannot promote certainty**. `commit` recomputes state from the inputs and
  the derivation's own floor, so a `~` upstream keeps the result `~`.
- It **cannot displace a better answer**. `commit`'s effective-tier rule refuses
  when the field already holds a value from a stronger rung, so a weak derivation
  cannot freeze the field against tier 1 landing later.

Each rung is one `checkTierNValues()` / `fetchTierNValues()` pair.

- `CAPABILITIES` and `DERIVATIONS` are auditable data tables, and they are
  **disjoint except for one declared exception** — the intersection is exactly
  `{kvBytes}`, whose derivation is the preferred producer and tier 6 its
  fallback. A field's producer is either a read or a computation, never both, and
  the exception is asserted as a set so it cannot silently acquire a second
  member. See [`concern-1-p0-plan.md`](../concern-1-p0-plan.md) §5.1.
- The same `pending` state that gates scheduling also gates the display, so
  `_queueKvProbe` / `_queueKvFit` / `_queueGguf` enqueue **only while their
  field is genuinely pending**. This replaces today's unconditional
  `_queueKvProbe(e)` on every refresh cycle (`Service.qml:1529`).
- Each rung is one process for the whole rung, not one per field. Tier 6 is a
  single run whose text is then parsed by whichever parsers are still needed (§8).

## 6. No rung arbitrates another — `kvLocation` is derived

**Retracted.** This section previously held a rule that tier 4's observation
arbitrates tier 5's projection: accept within tolerance, reject outside it, and
degrade to `~` on conflict. That rule is **withdrawn**, not deferred. Two
findings killed it, both recorded in
[`concern-4-p2-plan.md`](../concern-4-p2-plan.md):

- The offset is not small. Against the live worker the projection predicts
  `10,616 + 1,694 + 505 = 12,815 MiB` where tier 4 observes `12,972 MiB` — a
  157 MiB gap, **1.2 %** — and that 157 MiB is a *residual*, not a measurement
  of anything. It is CUDA context plus unaccounted.
- The check cannot fail. A projection that degrades to `~` on disagreement while
  agreeing with itself is not being tested. And where the per-layer step is
  smaller than the offset's uncertainty the observation cannot discriminate at
  all, so the check is vacuous precisely where it would matter.

Tier 5's values therefore stay `estimated` **permanently**, and nothing promotes
them. Six preconditions for reopening are listed in that file.

What survives is the observation ladder below, and it survives as **input to a
derivation**, not as an arbiter. `kvLocation` has no direct source at tiers 1–4,
so it is computed over `memBytes`, `vramBytes`, `kvBytes`, `soleAttribution` and
the tier-1 flags — see [`concern-2-p1-plan.md`](../concern-2-p1-plan.md).

### The observation ladder, gated on `sole` attribution

Gated on `sole` (only one model loaded, so the cgroup reading is this model's):

| Host `anon+shmem` | Device memory | Ladder rung | Certainty |
|---|---|---|---|
| `== 0` | held | cache is on the **device** | exact |
| `0 < host < KV` | held | genuine **GPU/CPU split**, at most `host` worth can be in host | `~` |
| any | no context | cache is in **RAM** | exact |
| `>= KV` | held | **indeterminate** | `—` |

That last row is the bug. Today's code calls it "CPU"
(`Service.qml:1155: if (mem >= kv) return "CPU"`), and the live gemma worker is
exactly that case — host anon lands 49 MiB above the cache and the cache is on
the device anyway. See [llama-service-tier-4-system-observation.md](llama-service-tier-4-system-observation.md) §5
for the arithmetic. The fix is that the ladder is a **derivation retried on every
settle**, not a one-shot write by a tier that has already committed — so better
inputs can revise the answer, which is what the original bug prevented.

## 7. Lifecycle

Per-model state is **frozen while the model is loaded** and **dropped entirely
on unload**: field store, GGUF header entry, projection entry, and observation
snapshot. Nothing survives a load cycle.

The re-fetch cost on the next load is ~15 ms (tiers 1–3, already batched) and
~575 ms if the walk reaches tier 5. This is deliberate: a stale cache is worse
than a slow one, and unload is exactly when the arguments may have changed.

## 8. Tier 6, split and trimmed

**6-i, the process.** `llama-cli --verbose` → raw text, ~3–45 s. Gated on *no
cheaper source could ever answer*: after tiers 1–5 and the derivation, the field
is still unresolved **because the shape is undescribable**. It never runs for a
described shape, where derivation is byte-exact. There is exactly one parser
surviving, `_parseKvProbeLine`'s `kv` branch, gated on `kvBytes` alone, so
"each parser runs only while its field is pending" needs no separate machinery.

**There is no timeout on this path.** That is worth stating plainly: if a model
has an architecture the header reader cannot resolve, the correct behaviour is a
3–45 s unconditional subprocess run, on every load. The only relief is
`kvProbe: "off"`, which makes the gate *refuse* and the field exhaust to `—`. A
missing deadline is a deliberate gap, not an oversight, and it is the strongest
argument for adding architecture templates (see §9).

**6-ii, the parsers.** Independent pure functions of the captured text, each
invoked only while its own field is pending:

| Parser | Fate | Why |
|---|---|---|
| `parseKvOnlySize(text)` | **survives** | The only one. Unique because the oracle's `context` column is KV + recurrent combined. |
| `parseKvLayerCount(text)` | **deleted** | `kvLayersExact` is written at `Service.qml:2231` and read nowhere outside tests; `_buildKvLayers` already derives the layer list from the header. |
| `parseComputeReserve(text)` | **deleted** | Its only consumers (`Service.qml:1248`, `Service.qml:2258`) feed `_estimateSplitFromProbes`, and tier 5's per-device `compute` column supplies that number for the *real* target device rather than for the probe's device-less `-dev none` run. |

Details in [llama-service-tier-6-deep-engine-observation.md](llama-service-tier-6-deep-engine-observation.md).

## 9. Invariants the implementation must honour

- **Bounded everything.** Every process is wrapped in `timeout -k 2 N` and
  piped through `head -c CAP`, with a QML watchdog above it
  (`Service.qml:594-612`). Every parser is a pure function of a string.
- **No interpolation.** Model paths, presets, and flags reach the shell as
  **positional arguments only**, never inside a script string.
- **`ulimit -c 0`** on any engine invocation, so a crash cannot leave a core
  dump in the user's home directory.
- **Absence is probed once.** A missing binary exits with a distinct code
  (97 for tier 5) so the probe is never retried every refresh.
- **Any non-zero exit or unparseable stdout is "no answer" and escalates.**
- **Symlinks and special files are refused** by every reader
  (`[ -L "$f" ] || [ ! -f "$f" ]`).
- **No per-architecture numeric tables.** Every architectural *fact* — layer
  counts, head counts, window periods, KV dtype widths — is read from the file or
  measured, never copied from the engine's source into a lookup table. The
  retired `_swaPeriodFor` (old values `gemma3=6, gemma3n=5, gemma2=2`) was exactly
  that failure, and `tst_derivation.qml` asserts it stays `undefined`.
- **Architecture *key names* are data, and that is a different thing.** Reading
  `<arch>.block_count` requires knowing the namespace, which is a naming
  convention, not a fact about the model. So a `KV_ARCH_TEMPLATES` prefix list
  with one shared suffix set is legitimate — and a survey of the model set found
  **seven** namespaces (`qwen35`, `qwen35moe`, `gemma4`, `gemma4-assistant`,
  `muse-glimmer`, `dflash`, `phi3`) against **one** suffix set, so the cost is a
  list of prefixes rather than a per-architecture table. Beyond the classic
  `llama.*` family this is **out of scope for now**; the consequence is that
  `qwen35moe` models decline here and pay tier 6 (§8). See
  [`concern-1-p0-plan.md`](../concern-1-p0-plan.md) §5.2.1.

## 10. Where the numbers in this overview come from

The cost figures and the gemma placement arithmetic were re-measured on this
machine; the tier-5 output format and a 621 ms elapsed run are recorded in
[llama-service-tier-5-engine-projection.md](llama-service-tier-5-engine-projection.md) §2,
against `orcarouter_Qwen3.8-27B-Uncensored-IQ4_XS.gguf`. The 157 MiB offset and
the withdrawn arbitration rule are in
[`concern-4-p2-plan.md`](../concern-4-p2-plan.md) §3.1; the bounded-error rule is
in [`concern-1-p0-plan.md`](../concern-1-p0-plan.md) §5.2.

Three verifications were open. **One is now closed, and closed negatively:**

| Question | Status |
|---|---|
| Does `meta.size_vram` answer the "is the cache on the device" question? | **Closed — no.** Checked against the live server's `/v1/models`: the `status` object carries **no** `meta` at all. See [`concern-1-p0-plan.md`](../concern-1-p0-plan.md) §7.1.1. |
| Is the tier-5 `compute` column a usable `sched_reserve` substitute? | **Open.** It is the reason tier 5's `computeBytes` stays `estimated`. |
| Is the 157 MiB offset stable? | **Open**, and it is one of the six preconditions for reopening corroboration. |
