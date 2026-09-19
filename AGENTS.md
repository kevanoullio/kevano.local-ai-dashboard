# AGENTS.md — local-ai-dashboard

This file is the binding contract for anyone (human or agent) modifying this
plugin. The full rationale, field-by-field matrix, and anti-patterns live in the
README's [Model Information Retrieval — Source Ladder](README.md#model-information-retrieval--source-ladder)
section. Keep this file consistent with the README; never contradict it.

## Project (30 seconds)

QML (Quickshell) bar plugin for Omarchy that monitors and controls local AI
services (`llama.cpp` + `ollama`): systemd-managed start/stop, model inventory
with loaded-model telemetry, CPU/GPU/DRAM/VRAM usage, terminal log streaming,
and config editing. `Dashboard.qml` owns all shared state and wiring;
`Service.qml` holds the backend/API/probe logic; `sections/` and `ui/` render.

## Source ladder (llama.cpp) — the contract

Every displayed value is resolved through a **per-field, fixed precedence**
across five tiers. The engine's own API is always preferred; the model file
comes second; measured probes fill in runtime state; derivation computes
final values; and the preset serves as a last-resort fallback.

### Tier precedence

1. **API** — `/v1/models` JSON response + resolved CLI args from `status.args`
2. **GGUF** — bounded 16 KiB header read of the `.gguf` file
3. **Probes** — cgroup memory.stat (DRAM) + per-PID GPU memory (VRAM)
4. **Derivation** — pure computation from tiers 1-3 inputs
5. **Preset** — direct `models.ini` read for values the API didn't resolve

### Marker conventions

- **Exact** — no prefix (verbatim from API/model file, or derived without estimation)
- **`~` estimate / measured** — GGUF-derived upper bound, measured probe value,
  or derivation with any estimated input. Rendered with `~` prefix.
- **`—`** — no source answered for that field (unknown).

### Golden rules (do not violate)

1. **Never use total-GPU VRAM as a per-model proxy.** GPU memory is per-PID only:
   `nvidia-smi --query-compute-apps=pid,used_memory` (NVIDIA) or
   `rocm-smi --showpids` (AMD). Whole-GPU fields (`--query-gpu=memory.used`,
   DRM `mem_info_vram_used_total`) count other tenants on the GPU and are
   forbidden.
2. **DRAM = cgroup `memory.stat` `anon + shmem` (working set).** Never
   `memory.current` / systemd `MemoryCurrent`: they include reclaimable page
   cache (the mmap'd `.gguf`), double-counting weight pages already anon or on
   the GPU.
3. **KV cache is always an upper-bound `~`.** Hybrid attention keeps KV on
   full-attention layers only and KV is quantized; the GGUF-derived formula is
   an approximation by construction. Never render it as exact.
4. **Device placement priority:** resolved `--n-gpu-layers` (Tier 1) → explicit
   preset value (Tier 5) → measured VRAM estimate (~, Tier 3). Never guess from
   VRAM alone when Tier 1 or 5 provides a value; always per-PID, rounded to whole
   layers.
5. **Preset values arrive as resolved CLI args** — `GET /v1/models[].status.args`,
   parsed in `_parseLlamaArgs`. NOT by scanning `models.ini` and NOT from journald
   (journald is display-only, for "View debug output"). A direct `models.ini` read
   is the **Tier 5** fallback only — used when the API didn't resolve preset values
   (e.g. global defaults like `fit = on`) and as the **service-stopped** fallback.

## Field → source (condensed, llama.cpp loaded models)

| Field | Tier 1 (API) | Tier 2 (GGUF) | Tier 3 (Probes) | Tier 4 (Derivation) | Tier 5 (Preset) | Marker |
|---|---|---|---|---|---|---|
| name/id, loaded status | `/v1/models` `m.id`, `status.value` | — | — | — | — | exact |
| model size | `meta.size` | `.gguf` file stat (`ggufScript`) | — | — | — | exact |
| effective context | `meta.n_ctx`; per-slot `/slots` → `n_ctx` | — | — | — | — | exact |
| total / main / MTP layers | — | `block_count`, `nextn_predict_layers`, `full_attention_interval` | — | — | — | exact |
| GPU/CPU layer split | `--n-gpu-layers` in `status.args` | — | estimated from VRAM/~ | derived from above | explicit preset value | exact / ~ / — |
| layer % on GPU/CPU | — | — | — | split ÷ total | — | exact / ~ / — |
| weight bytes per device | — | — | — | size × split ratio | — | exact / ~ / — |
| KV cache size | — | GGUF formula (~ upper bound) | — | layers × ctx × heads × bits | — | ~ |
| KV cache dtype | `--cache-type-k` / `--cache-type-v` in args | — | — | — | — | exact |
| KV cache placement | `--no-kv-offload` flag + offload count | — | — | — | — | exact |
| service DRAM | — | — | cgroup `anon+shmem` | — | — | ~ |
| service VRAM | — | — | per-PID nvidia-smi/rocm-smi | — | — | ~ |
| service CPU/GPU split | — | — | — | DRAM ÷ (DRAM + VRAM) | — | ~ |

**ollama:** engine-reported, no ladder. `ollama ps` (memory + `processor`
CPU/GPU string), `ollama list` (size, modified, cloud). Treated as exact.

## Where each tier lives in the code

| Tier | Source | Code (Service.qml unless noted) |
|---|---|---|
| 1 (API) | `/v1/models`, `/slots` | `_finishJsonModels`, `_parseLlamaArgs`, `_finishSlots` |
| 2 (GGUF) | `ggufScript` bounded 16 KiB header read | `_queueGguf` → `ggufProcess` → `_finishGguf` → `_applyGguf` / `_applyGgufDraft` / `_applyGgufToRunning` |
| 3 (Probes) | cgroup + GPU drivers | `serviceMemoryScript` / `serviceVramScript` → `_finishServiceMemory` / `_finishServiceVram` → `_deriveServiceTotal` |
| 4 (Derivation) | pure computation from tiers 1-3 | `_mtpSplit`, `_percentLayersOnGPU/CPU`, `_weightBytes`, `_kvEstimateBytes`, `_estimateSplitFromProbes`, `_kvDtypeBits` |
| 5 (Preset) | `models.ini` reader (planned: unresolved + service-stopped fallback) | `_parsePreset` (stub — not yet built) |
| Display | `~` / `—` rendering, per-device totals | `sections/ModelsSection.qml llamaDetailBlock` |

## Testing

Hermetic suite (mocked systemctl/systemd-analyze/llama-server, scratch sandbox):
`bash tests/run_all.sh`. See `tests/README.md` for architecture.

**Contract:** every new source/field must (1) extend the README matrix and this
file, and (2) ship tests following the existing patterns:

- Pure derivation helpers → unit harness `tests/unit_tests/tst_derivation.qml`.
- GGUF / file parsing → generated fixture `tests/integration_tests/gguf_header.bats`
  (the `gen_gguf` python fixture is the single source of truth for the binary layout).
- Scripts embedded in `Service.qml` are dumped at run time
  (`tests/lib/extract_constants.sh`) — edit only the QML constant, never a duplicate.

## Roadmap (code may lag the contract)

- Adopt exact Tier-1 `meta.*` fields not yet displayed: `meta.ftype` (quant),
  `meta.n_params`, `meta.n_vocab`, `meta.n_ctx_train`.
- Extend `ggufScript` with `context_length` (model-max ctx) and
  `general.file_type` (exact quant).
- Implement Tier 5: bounded `models.ini` reader for preset fallback — reads the
  preset file to extract explicit `n-gpu-layers` values that the API didn't
  resolve (e.g. when global defaults like `fit = on` are in effect), and for the
  **stopped** state so the available-models list shows preset intent.
- Render the ladder explicitly (e.g. a `_resolveFieldSources` resolver) so
  precedence is testable rather than implicit in `_weightBytes`.
- Probe `/metrics` for real KV usage; only adopt if it is per-model and verified
  in the target build (would let KV drop its `~`).

## Conventions

- QML + JS only (no TypeScript).
- Embedded bash scripts are **constants with positional args only** — user data
  is never concatenated into them; API keys travel only in the process
  environment / curl stdin, never argv or disk.
- Every probe is bounded: `timeout -k 2 N` + `head -c` output caps (`cap*`
  constants) + a QML watchdog timer.