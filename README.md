# omarchy-local-ai-dashboard

Monitor and control local AI model services like ollama and llama.cpp from the Omarchy bar. Start and stop systemd background services, view available models with current status, monitor CPU/GPU/DRAM/VRAM usage, stream debug output via a new terminal session, and open config files directly in nvim.

It provides a unified interface for various local backends—including `ollama` and `llama-server`—allowing you to inspect models, adjust service setups, stream terminal logs, and enforce single-service resource isolation. Support for `vLLM` is a planned feature.

This project is an extended derivative work based on `omarchy-ollama-status` by LinuxGamerUK.

> **For contributors and AI tooling:** this README is the authoritative contract for
> modifying the plugin — no separate `AGENTS.md` is maintained. It covers the
> [Source Ladder](#model-information-retrieval--source-ladder) (field precedence and
> anti-patterns), the [Testing contract](#testing), [Development Conventions](#development-conventions),
> and the [Contributing](#contributing) branch flow. Keep all guidance consolidated;
> never contradict it.

---

## Plugin Identification

- **Plugin Name:** `local-ai-dashboard`
- **Full Identifier:** `kevano.local-ai-dashboard`
- **Target Platform:** Omarchy 4 (Quattro / Quickshell Engine)

---

## Project Structure

The plugin is split into a `Dashboard.qml` shell that owns all shared state
(backend selection, cursor and keyboard navigation, `Service` instances) plus a set
of reusable UI components and per-section files. Each section is "state-in /
signal-out": it receives data as properties and reports interactions back as
signals, so the shell remains the single source of truth.

```
kevano.local-ai-dashboard/
├── assets/                          # Static assets (icons, etc.)
├── configs/                         # Per-backend configuration files
│   ├── llama.env                    #   llama.cpp env template / config
│   └── ollama.json                  #   ollama JSON config
├── sections/                        # Dashboard section components
│   ├── HeroSection.qml              #   Backend cards + power toggle
│   ├── ServiceDetailsSection.qml    #   Status/version/API grid + configure buttons
│   └── ModelsSection.qml            #   Running + available model lists
├── ui/                              # Reusable UI components
│   ├── BackendCard.qml              #   Clickable backend selector card
│   ├── InfoLabel.qml                #   Dimmed detail-row label
│   ├── InfoValue.qml                #   Detail-row value text
│   └── SettingsButton.qml           #   Full-width config action button
├── BarWidget.qml                    # Bar icon button (the plugin entry point)
├── Controller.qml                   # Loads and wires the dashboard panel
├── Dashboard.qml                    # The panel shell: structure + shared state
├── Service.qml                      # Backend service model (systemctl/API logic)
├── LICENSE
├── manifest.json                    # Plugin metadata + entry point declaration
├── tests/                           # Hermetic test suite (unit, integration, e2e)
│   ├── run_all.sh                   #   Orchestrates all test phases
│   ├── unit_tests/                  #   QML harnesses (~135 assertions)
│   ├── integration_tests/           #   BATS scripts (29 tests)
│   └── e2e_tests/                   #   Sandbox lifecycle harnesses
└── README.md
```

`manifest.json` points the bar at `BarWidget.qml` (`entryPoints.barWidget`), which
registers a `Controller` that loads `Dashboard.qml` on demand. Both the
`Service.qml` model and the `qs.Ui` panel primitives (`Panel`,
`KeyboardPanel`, `CursorSurface`, etc.) are reused across the sections.

---

## Testing

The project ships a hermetic test suite under `tests/` that exercises QML logic,
shell scripts, and end-to-end workflows inside an isolated sandbox (no live
systemd or host configs touched). Run all phases from the repo root:

```bash
bash tests/run_all.sh
```

Individual phases:
- **Unit tests** (`tests/run_unit_tests.sh`) — 6 Quickshell harnesses (~135 assertions) covering config parsing, defaults, exit-code maps, provisioning state, security contracts, and input validators.
- **Integration tests** (`tests/run_integration_tests.sh`) — 29 BATS tests exercising the embedded bash scripts (config reader/writer, env writer, provision create flows, rollback/unsafe matrices) against mocked `systemctl` and `systemd-analyze`.
- **End-to-end tests** (`tests/run_e2e_tests.sh`) — 3 sandbox harnesses covering llama.cpp full lifecycle, rollback on start failure, and Dashboard→section signal wiring.

A detailed description of the test architecture, constant extraction process,
and how to add new tests is in [tests/README.md](tests/README.md).

`tests/.cache/` holds scratch artifacts (dumped constants, per-run logs, generated
BATS files) and is git-ignored — it is regenerated on every run. `scratch/`
contains local discovery notes from development and is also git-ignored; both
directories can be safely deleted without affecting the plugin.

**Contract:** every new source or field must (1) extend the Source Ladder matrix
and this README (the [anti-pattern list](#anti-patterns-do-not-reintroduce)
included), and (2) ship tests following the existing patterns:

- Pure derivation helpers → unit harness `tests/unit_tests/tst_derivation.qml`.
- GGUF / file parsing → generated fixture `tests/integration_tests/gguf_header.bats`
  (the `gen_gguf` python fixture is the single source of truth for the binary layout).
- Scripts embedded in `Service.qml` are dumped at run time
  (`tests/lib/extract_constants.sh`) — edit only the QML constant, never a duplicate.

---

## Contributing

Public changes are welcome. This repository uses a **staging → main** release
pipeline; `main` is the production branch and the repository's default (it is
also what `omarchy plugin add` / `git clone` pull, so unreleased work never
reaches installers). The flow:

1. **PR to `main`:** fork from `main` and open a pull request against `main`
   (not `staging`), so the diff is clean relative to production. Describe the
   change, and run `bash tests/run_all.sh` before submitting.
2. **Maintainer review & integration:** accepted PRs are **retargeted to
   `staging`** before merging — `staging` merges only via a pull request and is
   where all post-merge testing happens. If staging has conflicting unreleased
   work, the change may instead be integrated through an internal PR based on
   the current `staging`.
3. **Release:** once staging is stable, a local `git release` fast-forward
   merges `staging` into `main`, tags the new version (`vX.Y.Z`), and pushes
   both `main` and the tag. `main` never advances except by that fast-forward.

Branch roles:

- **`main`** — production / default. What installers receive. Fast-forward only.
- **`staging`** — integration / release-candidate mirror of `main` plus
  unreleased changes. PR-only merges.

---

## Development Conventions

Rules for anyone (human or agent) modifying the code:

- **QML + JS only** (no TypeScript).
- **Embedded bash scripts are constants with positional args only** — user data
  is never concatenated into them; API keys travel only in the child process
  environment or curl stdin (`curl -K -`), never in argv or on disk.
- **Every probe is bounded:** `timeout -k 2 N` + `head -c` output caps (`cap*`
  constants) + a QML watchdog timer.

---

## Features & Architecture

- **Dual systemd scope model:** ollama runs as a system-wide daemon (system instance, managed via `pkexec`), while llama.cpp runs as a per-user service (user instance, self-provisioned on first start with no root or polkit required). Both can run side-by-side independently.
- **Multi-Service Selection Bar:** Displays all installed or configured local AI services at a glance. Easily switch the target view without affecting active background processes. The bar icon is dimmed when no installed service has a systemd unit; otherwise it uses the normal foreground color.
- **Single-Active Service Enforcer:** Activating a service automatically initiates a graceful shutdown of any currently running backend and waits for complete resource/VRAM forfeit before starting the target engine.
- **Single-panel layout:** Hero cards at top for backend selection + power toggle, followed by a status/details grid and a model inventory list — all in one scrollable panel.
- **Interactive Terminal Debugging:** One-click action to launch a terminal attached to live systemd or process logs.
- **Inline Neovim Configuration:** View service config file locations and open them directly in Neovim for editing.

---

## Model Information Retrieval — Source Ladder

Every displayed per-model and per-service value is resolved through a **per-field,
fixed precedence ladder** across five tiers. The engine's own API is always
preferred; the model file comes second; measured probes fill in runtime state;
derivation computes final values; and the preset serves as a last-resort
fallback. This section is the ground truth for where each number comes from and
whether it is exact, measured, or an estimate — the source of every value, how it
is resolved in code, and the rules for extending it are all documented in this
README (no separate tooling file is maintained).

### Tier precedence

The ladder is **per-field**, not one global order: within a field, the first
tier that answers wins.

1. **API** — `/v1/models` JSON response + resolved CLI args from `status.args`
2. **GGUF** — bounded 16 KiB header read of the `.gguf` file
3. **Probes** — cgroup memory.stat (DRAM) + per-PID GPU memory (VRAM)
4. **Derivation** — pure computation from tiers 1-3 inputs
5. **Preset** — direct `models.ini` read for values the API didn't resolve

### Marker conventions

- **Exact** — read verbatim from the API or the model file, or derived without
  estimation (e.g. layer ratio × size). Rendered with no prefix.
- **`~` estimate / measured** — a GGUF-derived upper bound (KV cache), a number
  that fell back to the measured per-device footprint, a measured cgroup/GPU
  figure, a derived CPU/GPU percentage, or a derivation consuming any estimated
  input. Rendered with a `~` prefix.
- **`—`** — no source answered for that field (unknown). Never guess.

### Executable ladder

The precedence above is not duplicated across call sites. `Service.qml` owns it in
one place: **`_resolveFieldSources(entry, p)`** walks the tiers once per field and
returns every value tagged with the **winning Tier** (1-5) and its **render
marker** ("", "~", "—"). `sections/ModelsSection.qml::llamaDetailBlock` and
`_weightBytes` consume these resolved values (via **`_resolveWeights`**) instead of
re-deriving precedence, so the golden rules are unit-testable in a single pure
function:

- **Tier 5 beats Tier 3**: a resolved `models.ini` `n-gpu-layers` (any `all`/`N`
  token) wins over a live VRAM estimate. `_isPresetSplitToken` rejects `auto` and
  empty values, which do not answer.
- **Tier 1 beats Tier 5**: an explicit `--n-gpu-layers` in `status.args` beats the
  preset.
- **`~` when any input was `~`**: the marker propagates from an estimated split
  (probe) through to the derived weight bytes; a derivation consuming an estimate
  is itself rendered `~`.

`**_presetSectionFor(entry)**` is the preset resolver's read side (Tier 5): the
model's own section merged over the `[*]` globals — section keys win, globals
chain through — matching `_applyGgufPresetSplit` semantics. The entry's
`_gpuSplitSource` (`api`/`preset`/`probe`) records which tier answered the split.

### llama.cpp loaded-model matrix

| Field | Tier 1 (API) | Tier 2 (GGUF) | Tier 3 (Probes) | Tier 4 (Derivation) | Tier 5 (Preset) | Marker |
|---|---|---|---|---|---|---|
| Name / id | `m.id` from `/v1/models` | — | — | — | — | exact |
| Loaded status | `status.value` (`loaded`) | — | — | — | — | exact |
| Model size | `meta.size` | `.gguf` file stat | — | — | — | exact |
| Parameter count | `meta.n_params` | — | — | — | — | exact |
| Quantization | — | `general.file_type` (GGUF header) → `_ftypeLabel` (llama.h enum, build 10729) | — | — | — | exact |
| Context length | `meta.n_ctx` | — | — | — | — | exact |
| Total layers | — | `block_count` | — | — | — | exact |
| Main / MTP layers | — | `block_count` + `nextn_predict_layers` + `full_attention_interval` | — | — | — | exact |
| Expected weight size | — | — | — | `n_params` × `_bytesPerParam(ftype)` | — | ~ |
| GPU/CPU layer split | `--n-gpu-layers` in `status.args` | — | estimated from VRAM/~ | derived from above | explicit preset value | exact / ~ / — |
| Layer % on GPU/CPU | — | — | — | split ÷ total | — | exact / ~ / — |
| Weight GB per device | — | — | — | size × split ratio | — | exact / ~ / — |
| KV cache size | — | GGUF formula (~ upper bound) | — | layers × ctx × heads × bits | — | ~ |
| KV cache dtype | `--cache-type-k/v` in args | — | — | — | — | exact |
| KV cache placement | `--no-kv-offload` + offload count | — | — | — | — | exact |
| Service DRAM | — | — | cgroup `anon+shmem` | — | — | ~ |
| Service VRAM | — | — | per-PID nvidia-smi/rocm-smi | — | — | ~ |

**ollama:** no separate ladder — the engine reports everything itself. Running
models come from `ollama ps` (per-model size + the `processor` string, e.g.
`51%/49% CPU/GPU`); the available list comes from `ollama list` (size, modified
date, cloud flag). All values are engine-reported and treated as exact.

### Worked examples

#### Example 1: `qwen3.8-27b-fast` (explicit `n-gpu-layers = all`)

```ini
[qwen3.8-27b-fast]
model = $HOME/.lmstudio/models/.../Qwen3.8-27B-UD-IQ3_S.gguf
n-gpu-layers = all
cache-type-k = q5_0
cache-type-v = q4_0
```

**Resolution:**
- Name: Tier 1 → `m.id` from `/v1/models`
- Size: Tier 1 → `meta.size` = 3.8 GB (exact)
- Quant: Tier 2 → GGUF `general.file_type` → `iq3_s` (exact)
- Params: Tier 1 → `meta.n_params` = 27.6B (exact)
- Expected weight: Tier 4 → 27.6B × 0.77 = ~19.8 GB (~)
- Context: Tier 1 → `meta.n_ctx` = 131072 (exact)
- Total layers: Tier 2 → GGUF `block_count` = 65 (exact)
- GPU/CPU split: Tier 1 → `status.args` contains `--n-gpu-layers all` → gpu=65, cpu=0 (exact)
- Layer %: Tier 4 → 65/65 × 100 = 100% GPU (exact)
- Weight GB GPU: Tier 4 → 3.8 GB × 65/65 = 3.8 GB (exact)
- Weight GB CPU: Tier 4 → 3.8 GB × 0/65 = 0 GB (exact)
- KV dtype K/V: Tier 1 → `--cache-type-k q5_0` / `--cache-type-v q4_0` (exact, from API args)
- KV cache size: Tier 2+4 → GGUF formula ≈ ~0.8 GB (~ upper bound)
- KV placement: Tier 1 → gpu > 0 → GPU (exact)
- GPU Total: Tier 4 → 3.8 GB + ~0.8 GB = ~4.6 GB
- CPU Total: Tier 4 → 0 GB (KV on GPU, so N/A)

**Displayed:**
```
Quant: iq3_s | 27.6B params | ~19.8 GB expected
Model Size: 65 layers | 3.8 GB
GPU Layers: 65 | 3.8 GB | 100%
CPU Layers: 0 | 0.0 GB | 0%
Context: 131,072 tok on GPU
KV Cache: ~0.8 GB (K q5_0 / V q4_0) on GPU
GPU Total: ~4.6 GB
CPU Total: —
```

#### Example 2: `qwen3.6-35b-a3b` (`fit = on`, no explicit `n-gpu-layers`)

```ini
[*]                    # Global defaults
fit = on
fit-target = 1024
flash-attn = on
cache-type-k = q8_0
cache-type-v = q8_0

[qwen3.6-35b-a3b]
model = $HOME/.lmstudio/models/.../Qwen3.6-35B-A3B-UD-IQ4_XS.gguf
# NO n-gpu-layers — relies on global fit = on
ctx-size = 262144
```

**Resolution:**
- Name: Tier 1 → `m.id` from `/v1/models`
- Size: Tier 1 → `meta.size` = 9.2 GB (exact)
- Quant: Tier 2 → GGUF `general.file_type` → `iq4_xs` (exact)
- Params: Tier 1 → `meta.n_params` = 30.5B (exact)
- Expected weight: Tier 4 → 30.5B × 0.544 = ~15.5 GB (~)
- Context: Tier 1 → `meta.n_ctx` = 262144 (exact)
- Total layers: Tier 2 → GGUF `block_count` = 80 (exact)
- GPU/CPU split: Tier 1 → `status.args` has NO `--n-gpu-layers` (not set explicitly)
  - Tier 3 → measured VRAM = 7.5 GB from nvidia-smi per-PID
  - Tier 4 → estimate: gpu_layers = round(7.5 GB / 9.2 GB × 80) ≈ 65 layers (~)
- Layer %: Tier 4 → ~65/80 × 100 ≈ ~81% GPU (~ estimated)
- Weight GB GPU: Tier 4 → 9.2 GB × 65/80 ≈ ~7.5 GB (~)
- Weight GB CPU: Tier 4 → 9.2 GB × 15/80 ≈ ~1.7 GB (~)
- KV dtype K/V: Tier 1 → `--cache-type-k q8_0` / `--cache-type-v q8_0` (exact, from API args)
- KV cache size: Tier 2+4 → GGUF formula ≈ ~1.2 GB (~ upper bound)
- KV placement: Tier 3 probe estimate → gpu > 0 → GPU
- GPU Total: Tier 4 → ~7.5 GB + ~1.2 GB = ~8.7 GB
- CPU Total: Tier 4 → — (KV on GPU, so N/A)

**Displayed:**
```
Quant: iq4_xs | 30.5B params | ~15.5 GB expected
Model Size: 80 layers | 9.2 GB
GPU Layers: ~65 | ~7.5 GB | ~81%
CPU Layers: ~15 | ~1.7 GB | ~19%
Context: 262,144 tok on GPU
KV Cache: ~1.2 GB (K q8_0 / V q8_0) on GPU
GPU Total: ~8.7 GB
CPU Total: —
```

### Where models.ini values actually come from

The plugin does **not** scan `models.ini` to populate loaded-model fields, and
it does **not** parse journald output for statistics (journald is display-only,
for "View debug output"). Per-model values that originate in the preset —
layer offload, KV cache type, KV offload, model/draft paths — reach the panel
as the **resolved command line the service was actually launched with**:
`GET /v1/models[].status.args`, parsed in `Service.qml`'s `_parseLlamaArgs()`.
This is authoritative (it is exactly what the router passed to each worker) and
is present even for **unloaded** preset models while the service runs.

A direct `models.ini` read is the **Tier 5 fallback only**, used in exactly two
cases the API cannot answer, via the bounded (16 KiB), single-flight reader
`modelsIniScript` → `_parsePreset`:

- **Global-default layer split** — values that never surface in `status.args`
  because they came from the `[*]` block (e.g. a global `n-gpu-layers`) resolve
  the split in `_applyGguf` before the Tier-3 estimate. The section keyed by the
  model's **file path** wins; the `[*]` globals are the fallback; only validated
  tokens (`all`, an integer, or `auto`) apply and land as an **exact** split
  (source `preset`, same marker rules as `api` — no `~`). `auto` still degrades
  to the Tier-3 probe, exactly as an unset flag does.
- **Service-stopped available list** — with no API to answer, the preset is the
  only way to keep listing preset models and their configured intent. Every
  section carrying a `model =` key becomes an entry, named after the file's
  basename, rendered with `preset intent: N GPU layers` (the section's
  `n-gpu-layers`, or the `[*]` globals') under its name.

The reader refuses symlinks/special files, reads at most 16 KiB, and is parsed
once per session (cached); an unknown or missing preset leaves both consumers
on their lower tiers (list stays empty, split falls back to Tier 3).

### Anti-patterns (do not reintroduce)

- **Total-GPU VRAM as a per-model proxy** — e.g. `nvidia-smi --query-gpu=memory.used`
  or DRM `mem_info_vram_used_total`. These count every process on the GPU.
  GPU memory is attributed only by summing the **per-PID** GPU contexts of the
  llama.cpp service processes (`nvidia-smi --query-compute-apps=pid,used_memory`
  / `rocm-smi --showpids`). This holds even for the Tier-3 layer-split estimate:
  it must consume a per-PID VRAM reading, never a whole-GPU figure.
- **`memory.current` / systemd `MemoryCurrent` for the footprint** — both
  include reclaimable page cache, i.e. the mmap'd `.gguf` pages, double-counting
  weight pages already held as anon or on the GPU. The cgroup `anon + shmem`
  working set excludes them.
- **KV cache shown as exact** — it is always an upper-bound `~`: hybrid-attention
  models store KV on full-attention layers only, and KV is quantized
  (`--cache-type-k/v`), so the GGUF-derived formula is an approximation by
  construction.
- **Guessing offload from VRAM math when a higher tier answered** — the layer
  split prefers the resolved `--n-gpu-layers` (Tier 1) and the explicit preset
  value (Tier 5). The measured-VRAM estimate (~, Tier 3) is used **only when
  neither Tier 1 nor Tier 5 provides `--n-gpu-layers`**, always from a per-PID
  reading, rounded to whole layers. When even that is unavailable, render `—`.
- **Guessing quant or params from the filename or `meta.size`** — the quant is
  an exact Tier-2 value read only from the GGUF header's `general.file_type`
  (mapped via `_ftypeLabel`), and params are an exact Tier-1 value read only
  from `meta.n_params`. Never derive them heuristically (file-name substrings,
  size ratios); `meta.size` is the aggregate file size and encodes no
  quantization. Unknown renders `—`.

### Where each tier lives in the code

| Tier | Source | Code (Service.qml unless noted) |
|---|---|---|
| 1 (API) | `/v1/models`, `/slots` | `_finishJsonModels`, `_parseLlamaArgs`, `_finishSlots` |
| 2 (GGUF) | `ggufScript` bounded 16 KiB header read | `_queueGguf` → `ggufProcess` → `_finishGguf` → `_applyGguf` / `_applyGgufDraft` / `_applyGgufToRunning` |
| 3 (Probes) | cgroup + GPU drivers | `serviceMemoryScript` / `serviceVramScript` → `_finishServiceMemory` / `_finishServiceVram` → `_deriveServiceTotal` |
| 4 (Derivation) | pure computation from tiers 1-3 | `_mtpSplit`, `_percentLayersOnGPU/CPU`, `_weightBytes`, `_kvEstimateBytes`, `_estimateSplitFromProbes`, `_kvDtypeBits` |
| 5 (Preset) | `models.ini` bounded 16 KiB read (unresolved layer split + service-stopped list) | `modelsIniScript` → `presetProcess` → `_finishPreset` → `_parsePreset` / `_presetModels`, `_applyGgufPresetSplit` |
| Display | `~` / `—` rendering, per-device totals | `sections/ModelsSection.qml llamaDetailBlock` |

---

## Interface Layout

### Header: Service Selector

The top header presents a horizontal row of available local services. Each service is represented by a single-column, two-row element:

```


+--------------+--------------+
| ollama       | llama.cpp    |
| RUNNING      | STOPPED      |
+--------------+--------------+

```

- **Selected View:** The currently selected service name is rendered in bold, bright text. Non-selected services are dimmed.
- **Interactive Selection:** Clicking any service column changes the active tab focus below to that service. Inspecting a service in this manner does not alter its running state.

---

### Lower Section: Three-Part Vertical Layout

The lower section is divided into three stacked components in a single scrollable panel.

#### Hero Section: Backend Cards + Power Toggle

Two clickable backend selector cards display the current status of each available service, alongside a power toggle switch for the active backend.

#### Service Details Grid

Displays operational information for the currently selected service in a two-column grid. When conditions warrant, error notices and config warnings appear above the grid:

- **Status:** `RUNNING` or `STOPPED`
- **Version:** Version string reported by the engine
- **API:** The host and port the service is serving on (shown when running)
- **Latency:** API response latency in milliseconds (shown when reachable, color-coded)
- **Since:** Timestamp of when the service was started

Conditional buttons:

- **Configure [Backend]:** Opens the service's config file in Neovim for editing (only visible when a config file exists)
- **View debug output:** Spawns a terminal attached to live systemd logs (only available when running)
- **Create [Backend] config file:** Generates the default config file (only shown when no config exists yet)

When starting llama.cpp requires writing or updating its systemd unit, a consent flow appears with "Confirm unit update & start" and "Cancel" buttons. This request also expires automatically after ~20 seconds.

#### Model Inventory

Displays an itemized list of all local models recognized by the selected service engine. When the service is running, loaded models appear at the top with detailed telemetry; below them, all available models are listed with indicators for cloud models and running status.

**Loaded model detail (llama.cpp):** Each loaded model renders as a multi-line block:

- **Model Size:** Layer count and total file size (base + draft)
- **GPU Layers / CPU Layers:** Per-device layer counts, weight GB, and percentage of the main stack on that device. A `(+N MTP ~X MB)` suffix appears when MTP draft layers are present.
- **Context:** Context length with location indicator (`on GPU` or `on CPU`)
- **KV Cache:** Estimated KV cache size with dtype info (e.g., `K f16 / V f16`) and location
- **Quant / Params / Expected:** First row (`Quant: q4_k_m | 30.5B params | ~16.5
  GB expected`), shown above Model Size whenever the quant (from the GGUF header's `general.file_type`,
  Tier 2) or the param count (`meta.n_params`, Tier 1) is known. The quant and
  params are exact — no `~`; only the trailing expected weight name (`n_params`
  × `_bytesPerParam(ftype)`, Tier 4) is a `~` sanity check against the reported
  file size. Each unknown shows `—`; the whole line is omitted when none are known.
- **GPU Total / CPU Total:** Combined weight + co-located KV cache per device (shown when applicable)

When the preset sets no explicit `--n-gpu-layers`, layer counts and percentages fall back to a `~` estimate derived from measured per-PID VRAM (Tier 3 → Tier 4), and show "—" only when even that is unavailable; the weight GB follows the same split (exact layer-ratio when known, otherwise the measured "~" VRAM/DRAM footprint). The KV cache size is always an upper-bound "~" estimate from the model's GGUF header.

For the full precedence ladder, the exact source of every value, and the
anti-pattern rules, see [Model Information Retrieval — Source Ladder](#model-information-retrieval--source-ladder).

**Loaded model detail (ollama):** A single-line summary showing memory footprint and CPU/GPU split: `"Memory: X.X GB | CPU: Y% | GPU: Z%"`, parsed from the engine's `processor` string.

**Available models list:** Each entry shows a status indicator (cloud ☁, loaded ●, unloaded ○), model name, size, and download date.

---

### Keyboard Shortcuts

The panel accepts keyboard input when it has focus. All service-scoped actions (start, stop, edit config, view debug) apply only to the currently selected backend. Service navigation is global — switching backends does not alter their running state.

| Key | Action |
|-----|--------|
| **Left / Right** | Switch between installed backends (cycles llama.cpp ↔ ollama) |
| **s** | Start the active service |
| **x** | Stop the active service |
| **r** | Refresh both backends simultaneously |
| **c** | Open the active backend's config file in Neovim |
| **d** | View live debug output (systemd journal) in a terminal |

The power toggle on the Hero card can also be activated with **Enter** when the header section is cursor-focused.

---

## Planned Features

- **vLLM support:** Backend integration for the vLLM inference engine.
- **Context Meter:** Visual representation of total context used versus total context allocated for the loaded model.

---

## Installation & Setup

### Method A — CLI (Recommended)

Run the following command to clone and enable the plugin in one step:

```bash
omarchy plugin add https://github.com/kevanoullio/kevano.local-ai-dashboard.git --enable
```

This clones the repo into `~/.config/omarchy/plugins/kevano.local-ai-dashboard` and registers the plugin automatically.

### Method B — Manual

1. Clone this repository into your Omarchy plugins directory:

   ```bash
   git clone https://github.com/kevanoullio/kevano.local-ai-dashboard.git ~/.config/omarchy/plugins/kevano.local-ai-dashboard
   ```

2. Register the plugin by adding it to a `bar.layout` region in your Omarchy 4 configuration file (`~/.config/omarchy/shell.json`). For example, the right region:

```json
{
  "bar": {
    "layout": {
      "right": [
        { "id": "kevano.local-ai-dashboard" }
      ]
    }
  }
}
```

1. Reload the plugin so the shell picks it up. No full shell restart is needed — this re-scans the plugin directories and hot-reloads the plugin code in place:

```
omarchy-shell shell rescanPlugins
```

1. If the rescanning the plugins did not show your latest changes, then restart the shell altogether:

```
omarchy-restart-shell
```

---

## Removing

### Via CLI

```bash
omarchy plugin remove kevano.local-ai-dashboard
```

### Manually

1. Remove the plugin entry from `~/.config/omarchy/shell.json` (delete the `"kevano.local-ai-dashboard"` object from the relevant `bar.layout` region).
2. Delete the plugin directory:

   ```bash
   rm -rf ~/.config/omarchy/plugins/kevano.local-ai-dashboard
   ```

3. If you enabled the llama.cpp user service, disable and remove it:

   ```bash
   systemctl --user disable llama.cpp.service
   rm -f ~/.config/systemd/user/llama.cpp.service
   ```

---

## Service Architecture

### ollama — system instance

ollama is installed as a system-wide daemon (`/usr/lib/systemd/system/ollama.service`) that runs under a dedicated `ollama` user, stores models in `/usr/share/ollama`, and serves on a static port. The dashboard manages it via the **system** systemd instance using `pkexec` (which triggers a graphical polkit authentication prompt).

### llama.cpp — user instance

llama.cpp is designed as a flexible, developer-focused binary. Users frequently change parameter flags, swap local model files, adjust VRAM layer offloading, and edit preset `.ini` files. This per-user workflow aligns naturally with **user-scoped** systemd services.

When you toggle llama.cpp on for the first time, the plugin self-provisions both its configuration file (`configs/llama.env`) and its user service unit (`~/.config/systemd/user/llama.cpp.service`) automatically — no root privileges or polkit authentication required.

### Side-by-side operation

The two services live in separate systemd scopes (system vs. user instance), so they can run simultaneously without conflict. The dashboard's single-active enforcer handles switching between them when needed.

---

## Security Model

The dashboard treats config files and service state as untrusted input and keeps secrets out of any observable channel. In plain terms:

- **Endpoints:** `http` is used for loopback hosts only (`127.0.0.1`, any `127.x.y.z`, `::1`, `localhost`). Any non-loopback host is required to use `https`, and curl's default certificate validation is always on — the plugin never disables TLS checks (no `-k` / `--insecure`). A config that violates this policy makes no network calls at all and shows a warning instead.
- **Secrets:** the API key is never placed on a command line or in any file another user can read. It travels only through the child process environment and is handed to `curl` on standard input (`curl -K -`), so it does not appear in `ps`, `/proc/*/cmdline`, or on disk.
- **Config files:** config files are created only when missing, never overwritten, are symlink/FIFO-proof (a config path that is actually a link or a pipe is refused rather than followed), and are stored with mode `0600` so the API key inside them is not world-readable. An existing regular config file is re-hardened to `0600` on every read.
- **llama.cpp provisioning:** starting llama.cpp writes its env file and user systemd unit safely — it detects an existing unit, asks for confirmation before changing one (with a ~20 s auto-cancel), backs up the previous unit, validates the new one with `systemd-analyze`, swaps it in atomically, and rolls back on a failed start. A lock file means two open panels cannot race each other.
- **Manual setup required:** the plugin never installs backends or escalates privileges beyond what each scope needs. You must install `ollama` (or `llama-server`) yourself. Managing ollama's system unit requires a polkit authentication agent to be running (Omarchy ships one by default). The llama.cpp user service requires a running systemd **user** instance (`systemctl --user`).

---

## Dependencies

The dashboard relies on standard Linux utilities to query local APIs and manage background units:

- `curl` for API health checks, model listing, and config file reading.
- `systemd` (both system and user service instances).
- A polkit authentication agent for managing ollama's system-level service via `pkexec` (Omarchy ships one by default).
- `nvim` for inline file editing.
- Your preferred terminal emulator (e.g., `kitty`, `foot`) for log streaming.

---

## Credits & License

- **Original Inspiration:** Based on [`omarchy-ollama-status`](https://github.com/LinuxGamerUK/omarchy-ollama-status) by **LinuxGamerUK**.
- **License:** Distributed under the terms of the [MIT License](https://www.google.com/search?q=LICENSE).
