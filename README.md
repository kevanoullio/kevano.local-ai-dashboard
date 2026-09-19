# omarchy-local-ai-dashboard

Monitor and control local AI model services like ollama and llama.cpp from the Omarchy bar. Start and stop systemd background services, view available models with current status, monitor CPU/GPU/DRAM/VRAM usage, stream debug output via a new terminal session, and open config files directly in nvim.

It provides a unified interface for various local backends—including `ollama` and `llama-server`—allowing you to inspect models, adjust service setups, stream terminal logs, and enforce single-service resource isolation. Support for `vLLM` is a planned feature.

This project is an extended derivative work based on `omarchy-ollama-status` by LinuxGamerUK.

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

Every displayed per-model and per-service value is resolved through a **fixed,
documented precedence ladder**. The engine's own API is always preferred; the
model file comes second; measured per-PID probes and the preset fill in what
remains. This section is the ground truth for where each number comes from and
whether it is exact, measured, or an estimate — the same contract is condensed
for tooling in [AGENTS.md](AGENTS.md).

### Precedence by field category

The ladder is **per-field**, not one global order: the tiers rarely compete for
the same value, so category decides precedence.

1. **Static / model fields** (size, layers, context, quant, dtype):
   **API → model file (GGUF) → models.ini preset.**
2. **Runtime / location fields** (weight bytes on a device, KV cache,
   DRAM/VRAM footprint, CPU/GPU split):
   **exact service-args split → measured per-PID probe → GGUF-derived estimate
   → preset default.**

### Marker conventions

- **Exact** — read verbatim from the API or the model file, or derived without
  estimation (e.g. layer ratio × size). Rendered with no prefix.
- **`~` estimate / measured** — a GGUF-derived upper bound (KV cache), a number
  that fell back to the measured per-device footprint, a measured cgroup/GPU
  figure, or a derived CPU/GPU percentage. Rendered with a `~` prefix.
- **`—`** — no source answered for that field (unknown).

### llama.cpp loaded-model matrix

| Field | Source (in resolution order) | Tier | Marker |
|---|---|---|---|
| Name / id | `GET /v1/models` → `m.id` | 1 | exact |
| Loaded status | `/v1/models` → `status.value` (`loaded`/`unloaded`) | 1 | exact |
| Model size | `meta.size` (loaded only) → `.gguf` file size from `ggufScript` | 1 → 2 | exact |
| Effective context | `meta.n_ctx` (loaded); also per-slot `/slots` → `n_ctx` | 1 | exact |
| Model-max context | GGUF `context_length`; `meta.n_ctx_train` (planned) | 2 / 1 | exact |
| Total / main / MTP layers | GGUF `block_count`, `nextn_predict_layers`, `full_attention_interval` | 2 | exact |
| GPU / CPU layer split | resolved `--n-gpu-layers` in `status.args` (+ totals, `"all"` = total) | 1 | exact |
| Layer % on GPU / CPU | derived from split over the main stack | 1→2 | exact |
| Weight bytes per device | layer-ratio split of the size | 1→2 | exact, `~` on measured fallback |
| KV cache size | GGUF `head_count_kv` / `embedding_length` + context + `--cache-type-k/v` dtype | 2 | `~` upper bound |
| KV cache dtype | `status.args` `--cache-type-k` / `--cache-type-v` (default `f16`) | 1 | exact |
| KV cache placement | `--no-kv-offload` flag + offloaded layers | 1 | exact |
| Quantization | `meta.ftype`; GGUF `general.file_type` (planned) | 1 / 2 | exact |
| Model / draft paths | `--model` / `--model-draft` in `status.args` | 1 | exact |
| Service DRAM | cgroup `memory.stat` `anon + shmem` (service cgroup) | 3 | measured (`~`) |
| Service VRAM | per-PID GPU memory: `nvidia-smi --query-compute-apps=pid,used_memory` (NVIDIA) / `rocm-smi --showpids` (AMD) | 3 | measured (`~`) |
| Service CPU / GPU split | DRAM ÷ (DRAM + VRAM) | 3 | measured (`~`) |

**ollama:** no separate ladder — the engine reports everything itself. Running
models come from `ollama ps` (per-model size + the `processor` string, e.g.
`51%/49% CPU/GPU`); the available list comes from `ollama list` (size, modified
date, cloud flag). All values are engine-reported and treated as exact.

### Where models.ini values actually come from

The plugin does **not** scan `models.ini` to populate loaded-model fields, and
it does **not** parse journald output for statistics (journald is display-only,
for "View debug output"). Per-model values that originate in the preset —
layer offload, KV cache type, KV offload, model/draft paths — reach the panel
as the **resolved command line the service was actually launched with**:
`GET /v1/models[].status.args`, parsed in `Service.qml`'s `_parseLlamaArgs()`.
This is authoritative (it is exactly what the router passed to each worker) and
is present even for **unloaded** preset models while the service runs.

A direct `models.ini` read is reserved for the **service-stopped** state (Tier
4): when the API cannot answer, it is the only way to keep listing preset
models and their configured intent. That reader is planned, not yet built.

### Anti-patterns (do not reintroduce)

- **Total-GPU VRAM as a per-model proxy** — e.g. `nvidia-smi --query-gpu=memory.used`
  or DRM `mem_info_vram_used_total`. These count every process on the GPU.
  GPU memory is attributed only by summing the **per-PID** GPU contexts of the
  llama.cpp service processes.
- **`memory.current` / systemd `MemoryCurrent` for the footprint** — both
  include reclaimable page cache, i.e. the mmap'd `.gguf` pages, double-counting
  weight pages already held as anon or on the GPU. The cgroup `anon + shmem`
  working set excludes them.
- **KV cache shown as exact** — it is always an upper-bound `~`: hybrid-attention
  models store KV on full-attention layers only, and KV is quantized
  (`--cache-type-k/v`), so the GGUF-derived formula is an approximation by
  construction.
- **Guessing offload from VRAM math** — device placement comes from the resolved
  `--n-gpu-layers` (or the preset); never inferred by dividing measured VRAM.
- **Layer counts / percentages when no explicit `--n-gpu-layers` exists** —
  render `—`, never a guess.

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
- **GPU Total / CPU Total:** Combined weight + co-located KV cache per device (shown when applicable)

Layer counts and percentages show "—" when the preset sets no explicit `--n-gpu-layers`; in that case the weight GB falls back to a measured "~" VRAM/DRAM estimate. The KV cache size is always an upper-bound "~" estimate from the model's GGUF header.

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
