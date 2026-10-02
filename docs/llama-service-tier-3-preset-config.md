# Tier 3 — Preset config

**Cost** ~5 ms · **Role** definitive · **Status** exists

This tier is part of the llama.cpp service acquisition ladder. The ollama
backend does not use any of these tiers — it reads everything directly from the
engine.

`models.ini` is llama.cpp's model roster: one section per model, plus a
reserved `[*]` block of global defaults. The panel reads it directly, in
**exactly two situations**, and both are documented below.

The reason this is tier 3 is simple: it costs the same ~5 ms as the API, and for
the one field it owns it is a definitive source.

**What changed, and it is the whole point of this tier's revision.** Tier 3 used
to *compute a split* — read `n-gpu-layers`, combine it with `totalLayers`, and
write `mainGpu` / `mainCpu`. That made it a second source for fields tier 2 and
the derivation already owned, and it created a forward data dependency on
`block_count` that forced tier 2 to run first. **Tier 3 now acquires a raw token
and nothing else**: it commits `presetNgl` and declines to do arithmetic. The
split is derived from `presetNgl` and the layer counts by
[`concern-1-p0-plan.md`](../concern-1-p0-plan.md) §3.1, so tier 2 and tier 3 no
longer have an ordering constraint and may settle in either order.

---

## 1. What it answers

Exactly one thing for a **loaded** model:

> `n-gpu-layers`, when the server was started from a preset and no explicit
> `-ngl` was passed — committed as **`presetNgl`**, a raw token.

Not a split. The distinction is the entire revision of this tier: a token is a
reading, and a split is an inference.

That is the gap tier 3 fills. A preset like

```ini
[*]
fit = on
fit-target = 1024

[qwen3.6-35b-a3b]
model = $HOME/.lmstudio/models/…/Qwen3.6-35B-A3B-UD-IQ4_XS.gguf
ctx-size = 262144
```

produces a `status.args` with **no** `--n-gpu-layers` (`Service.qml:1925`
leaves `ngl === ""`), because `fit = on` — not an explicit offload count —
decides the offload. Tier 1 cannot answer. The preset can, as an *intent*:
`n-gpu-layers` absent from the section but present in `[*]` is a real
statement about the intended offload, and when it is a resolvable token it is
committed as `presetNgl` **exact**, with no `~`.

`presetNgl` is deliberately *not* named `ngl`. Tier 1's `ngl` is what the engine
is actually doing; `presetNgl` is what the roster asked for. Merging them is what
lets a stale intent render as fact, and keeping them separate is what lets the
derivation prefer tier 1's `ngl` whenever the engine answered for itself.

For an **unloaded** model, tier 3 is the whole available list (Consumer A).

### The token rule

`_isPresetSplitToken` (`Service.qml:1269`) accepts only:

```
^(all|[0-9]+)$
```

`auto`, the empty string, and anything non-numeric **do not answer**. A
`n-gpu-layers = auto` is genuinely unknown — the engine will decide — so
tagging it tier 3 would be a lie, and the entry correctly degrades to tier 4
or 5. `_applyGgufPresetSplit` applies a slightly wider regex
(`^(all|[0-9]+|auto)$`, `Service.qml:1454`) purely so it can *see* `auto` and
refuse it after `_mtpSplit` returns nulls; the narrower `_isPresetSplitToken`
is what the resolver's capability check uses.

## 2. The two consumers

### Consumer A — the available list, service stopped

`_presetModels` (`Service.qml:1404`). Every non-`[*]` section carrying a
`model =` key becomes an entry:

```js
{
  name:         basename(model),        // truncated to 128
  id:           model,                   // the path
  size:         "",                      // never stat()ed
  modified:     "",
  isCloud:      false,
  preset:       true,
  presetIntent: ngl !== "" ? "preset intent: " + ngl + " GPU layers"
                          : "in preset",
  presetPath:   model
}
```

`presetIntent` is rendered by `ModelsSection.qml:433`. The section's own
`n-gpu-layers` wins; `[*]` is the fallback; neither present yields the bare
`"in preset"` string. Bounded by `maxModels` (`Service.qml:577`).

Consumer A only runs when the service is **stopped** — when it is running,
`/v1/models` is the list source (`Service.qml:1395`).

### Consumer B — the global-default split, for loaded models

`_applyGgufPresetSplit` (`Service.qml:1444`). Four guards before it will
answer:

1. `entry.mainGpu !== null` → something already owns the split. Bail.
2. `entry.ngl !== "" && entry.ngl !== "auto"` → tier 1 answered. Bail.
3. No cached preset → bail.
4. `_mtpSplit` returned nulls for the token → bail.

On success it commits `presetNgl` — and, under the plan, **nothing else**.

Three things it used to do are gone, and each was a symptom of tier 3 computing
a split:

- **`mainGpu` / `mainCpu` are no longer written here.** They are derived from
  `presetNgl` plus `totalLayers` and `mtpLayers`.
- **`_gpuSplitSource = "preset"` is retired.** With one writer per field there is
  nothing to attribute; the field's `tier` says where it came from, and
  `derived` says it was computed.
- **The back-fill of `entry.ngl` is removed.** Back-filling tier 1's field from
  tier 3 is exactly the kind of cross-tier write that made provenance
  unanswerable, and it is why the store now carries `presetNgl` separately.

**Why the ordering constraint disappeared.** The old code ran inside `_applyGguf`
because turning a count into a split needed `block_count` — a tier-2 value — and
`_applyGguf` was the first point where both existed. Since tier 3 now stores a
token, it needs nothing from tier 2, so there is no reason to live inside
`_applyGguf` and no reason for tier 2 to run first. Derivation is *retried* on
every settle rather than scheduled, which is what makes this safe: whenever
`presetNgl` and `totalLayers` have both landed, the split resolves.

## 3. Precedence: section over `[*]`

`_presetSectionFor` (`Service.qml:1473`) builds the effective section by
copying `[*]` first, then overlaying the model's own section:

```js
merged = { …globals, …ownSection }
```

Sections are keyed by the model **file path** (`_iniSectionKey`,
`Service.qml:1313`), normalized to `[a-zA-Z0-9_.\/*-]` — the same charset the
awk filter uses, so the key survives normalization identically on both sides and
the `*` of `[*]` is never stripped. Returns `null` when neither the section nor
a globals block exists.

`n-gpu-layers` in the effective section is what tier 3 reads. Nothing else is
read from a preset for a loaded model.

## 4. Reader safety

`modelsIniScript` (`Service.qml:518`):

```bash
f="$1";
if [ ! -e "$f" ] || [ -L "$f" ] || [ ! -f "$f" ]; then exit 0; fi;
head -c "$2" -- "$f" 2>/dev/null | awk '…' | head -c "$2"
```

- **Refuses symlinks and special files.** `$1` and `$2` are positional
  arguments, so a hand-edited preset cannot execute anything.
- **Bounded at 16 KiB in and 16 KiB out** (`modelsIniCap`, `Service.qml:517`).
- **Missing file exits 0 with no output**, which reads as "no preset" rather
  than an error — both consumers then no-op back to lower tiers.
- **Normalized output**: comments and blanks dropped, section names filtered to
  the charset above, `key=value` with the key filtered and the value trimmed.
  `_parseIniLines` re-reads *exactly* this normalized form, so the QML parser
  and the shell filter are two halves of one format.
- **Read once per session.** `_presetCache` is populated by `_finishPreset`
  and never invalidated; `_queuePreset` is single-flight and a no-op while a
  read is in flight. A same-refresh re-read resolves synchronously through
  `_parsePreset` (`Service.qml:1360`), which starts the read if needed and
  returns whatever is cached — `null` on the first call, the object on later
  ones.
- **`$HOME/` expansion** is limited to a *leading* token
  (`Service.qml:1351`): the env writer already expands it, but a hand-edited
  preset may keep it. A `$HOME` anywhere else in a value is left alone.
- **Matching quotes are stripped** from values (either quote style).

## 5. Where the code is

| Piece | Location |
|---|---|
| Bash reader | `Service.qml:518` `modelsIniScript` |
| Cap constant | `Service.qml:517` `modelsIniCap: 16384` |
| Process | `Service.qml:3068` `presetProcess` |
| Line sink | `Service.qml:1366` `_onPresetLine` |
| Buffer cap | `Service.qml:1308` `_presetBufferMax: 16384` |
| Single-flight start | `Service.qml:1374` `_queuePreset` |
| Fold + dispatch | `Service.qml:1383` `_finishPreset` |
| Cache read | `Service.qml:1360` `_parsePreset` |
| Pure INI parser | `Service.qml:1322` `_parseIniLines` |
| Section key normalizer | `Service.qml:1313` `_iniSectionKey` |
| Consumer A | `Service.qml:1404` `_presetModels` |
| Consumer B | `Service.qml:1444` `_applyGgufPresetSplit` |
| Effective section | `Service.qml:1473` `_presetSectionFor` |
| Late-landing replay | `Service.qml:1494` `_applyPresetToRunning` |
| Token gate | `Service.qml:1269` `_isPresetSplitToken` |
| Path | `Service.qml:56` `configPresetPath` → `Service.qml:60` `presetPath` |

`presetPath` comes from `LLAMA_MODELS_PRESET` in the managed `llama.env`
(`Service.qml:47`), which is validated by `isValidPresetPath`
(`Service.qml:137`).

## 6. What it cannot answer

- **The offload count when the preset says `auto`** — the engine decides.
- **Where the KV cache is.** `n-gpu-layers = all` is *not* proof of KV
  placement; `--fit` moves the cache independently. This is asserted
  explicitly in `e2e_preset.qml`.
- **`ctx-size`, `cache-type-k/v`, `batch-size`** for a **loaded** model. These
  all *are* in the preset, but tier 1's `status.args` already carries the
  resolved values, and the resolved value beats the declared one. Reading them
  from the preset would risk reporting an intent the engine overrode.
- **Model size.** Consumer A never stats the file; `size` is `""`.
- **Anything when the preset is missing, unreadable, or larger than 16 KiB.**
  Then tier 3 is a no-op and the walk continues.

## 7. Under the resolver

```
checkTier3Values(entry, pending):
    if _presetCache === null:              return {}      // not read yet
    sec <- _presetSectionFor(entry)
    if sec === null:                       return {}
    if not _isPresetSplitToken(sec["n-gpu-layers"]): return {}
    return pending ∩ { presetNgl }         // exact

fetchTier3Values(entry):
    // A raw token. No layer counts, no arithmetic, no tier-2 dependency.
    return { presetNgl: sec["n-gpu-layers"] }             // state: EXACT
```

`CAPABILITIES[3]` is `{presetNgl}` and **one field**. That single entry is what
retires the forward dependency: tier 3 reads nothing from tier 2, so the walk
order stops mattering, and `mainGpu` / `mainCpu` resolve in
`applyDerivation()` whenever `presetNgl` and the layer counts are both settled —
in whichever order they happen to arrive.

The consequence worth stating: `checkTier3Values` returning non-empty no longer
implies anything about the split, so a resolver that reported "tier 3 answered
`mainGpu`" could not have been right. `CAPABILITIES` is unit-tested against
`DERIVATIONS` for exactly this reason.

## 8. Tests

- **`models_ini.bats`** (4 tests) — the bash contract: globals plus
  path-keyed sections, comments, whitespace, quoted and `$HOME` values; a
  missing file yields no output and exit 0; a symlink is refused; the 16 KiB
  cap holds.
- **`tst_derivation.qml`**, prefixes `ini/*`, `inisection/*`, `psf/*`:
  `ini/globals-block`, `ini/globals-cachek`, `ini/globals-fit`,
  `ini/section-ctx`, `ini/comments-only`, `ini/comment-stripped`,
  `ini/quote-stripped`, `ini/home-expanded`, `ini/empty-input`;
  `inisection/globals`, `inisection/empty`. The `*-fs` group covers
  `_presetSectionFor`'s merge order.
- **`t5/*` group** — the token: `tier1-ngl-untouched` (a tier-1 `ngl` is never
  overwritten), `auto-stays-unresolved`, `absent-keeps-probe`, and
  `preset-is-not-a-split` asserting tier 3 writes `presetNgl` and does **not**
  write `mainGpu` / `mainCpu`.
- **`presetNgl` vs `ngl`** — a model whose preset says `all` while the engine ran
  with an explicit `-ngl` must keep both values, with the split derived from the
  tier-1 `ngl`.
- **`e2e_preset.qml`** (25 asserts) — the full arc, through a real `Service`
  and a real `ModelsSection`, with a fixture preset seeded by
  `tests/lib/common.sh`: Consumer A when stopped (`preset intent: all GPU
  layers` inherited from `[*]`), Consumer B when running with `ngl` unset
  (an **exact** split, source `preset`, no `~`).

## 9. Gaps to close

1. ~~**The `_queueKvProbe`-style need gate does not exist here yet.**~~ **Closed
   by construction.** A preset read is cheap and once-per-session, so it is *not*
   gated — and `capabilities(3)` lists only `presetNgl`, so the walk never
   reports "tier 3 tried" for a field it did not look at.
2. **`_presetCache` is never invalidated on reload.** Correct under the plan
   (state is dropped on unload, re-fetched at load), but it must be added to
   the unload eviction list, or the "frozen while loaded" invariant breaks.
