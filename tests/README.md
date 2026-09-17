# Local AI Dashboard — Test Suite

`tests/` holds the complete, self-contained test suite for this Quickshell
plugin. It is **hermetic**: nothing it does touches the host's live configs,
systemd user units, or the plugin's real files — every run happens inside
`tests/.cache/` against a scratch sandbox and mocked binaries.

Two design principles drive the whole suite:

1. **Single source of truth.** The provisioning/env/config bash scripts and the
   fabricated systemd unit are embedded in `Service.qml`. The tests never
   re-type them: they are dumped out of `Service.qml` at run time, and the
   integration tests execute those exact strings and byte-compare files against
   heredoc-fabricated copies.
2. **Hermetic execution.** `quickshell` runs each QML harness with the host
   config isolated (`<service dir>` is a copied sandbox), `systemctl`,
   `systemd-analyze`, `llama-server`, `ollama` are shell mocks that only append
   to a sandbox log, and `HOME`/`PATH`/`__mocklog` are redirected into the
   sandbox — so the plugin's "self-provisioning" path can be exercised safely.

> Why not `qmltestrunner`? `/usr/bin/qmltestrunner` is Qt 5 (silently exits 1)
> and Qt 6's has no `QtQuick.Test`. The harnesses instead run under
> `quickshell -p <file>` and report via a tiny assertion protocol (below).

## Quickstart

```sh
# from the repo root — runs every phase and prints a summary
bash tests/run_all.sh

# individual phases, one runner each (dep-checking and summary included)
bash tests/run_unit_tests.sh        # Phase 2 — QML unit tests (reported as bats)
bash tests/run_integration_tests.sh # Phase 3 — bats (extracts constants first)
bash tests/run_e2e_tests.sh         # Phase 4 — end-to-end sandbox harnesses (reported as bats)

# low-level pieces (used by the runners above)
bash tests/lib/extract_constants.sh                  # constants (needed by integration tests)
bash tests/lib/run_qml_harness.sh tests/unit_tests/tst_defaults.qml tests/.cache/run/Service.qml
```

`run_all.sh` requires: `quickshell`, `timeout`, `bash`, `python3`, `stat`,
`flock`, `mktemp` (plus a `rg` for one source-level check).

## Layout

```
tests/
├── run_all.sh                      # orchestrates all four phases
├── run_unit_tests.sh               # Phase 2 only
├── run_integration_tests.sh        # Phase 3 only
├── run_e2e_tests.sh                # Phase 4 only
├── README.md                       # this file
├── lib/
│   ├── common.sh                   # shared bootstrap + phase helpers (sourced by all runners)
│   ├── run_qml_harness.sh          # quickshell harness driver (units + e2e)
│   ├── gen_assert_bats.sh          # LAD log -> generated .bats (one @test per assertion)
│   ├── asserts.js                  # LAD-* assertion mini-library
│   ├── extract_constants.sh        # dumps embedded scripts from Service.qml
│   ├── helpers.bash                # shared sandbox/assert helpers for bats
│   ├── mocks/
│   │   ├── systemctl               # logs calls; simulates start/verify failures
│   │   ├── systemd-analyze         # FAIL_VERIFY=1 -> exit 1, else 0
│   │   └── llama-server            # no-op binary (exit 0)
│   └── bats/                       # vendored bats-core 1.14.0 (bin/lib/libexec)
├── support/
│   ├── dump_constants.qml          # marker-JSON dump of Service.qml constants
│   ├── Commons/                    # qs.Commons stubs (Style, Color, Border, Util)
│   └── Ui/                         # qs.Ui stubs (Panel*, CursorSurface, ...)
├── unit_tests/                     # Phase 2 — 6 quickshell harnesses
│   ├── tst_config_parser.qml
│   ├── tst_defaults.qml
│   ├── tst_exitcode_maps.qml
│   ├── tst_provision_state.qml
│   ├── tst_security_contract.qml
│   └── tst_validators.qml
├── integration_tests/              # Phase 3 — 5 bats files (29 tests)
│   ├── config_reader.bats
│   ├── config_writer.bats
│   ├── env_writer.bats
│   ├── provision_dryrun_create.bats
│   └── provision_rollback_unsafe.bats
└── e2e_tests/                      # Phase 4 — 3 sandbox harnesses
    ├── e2e_llama_lifecycle.qml
    ├── e2e_llama_rollback.qml
    └── e2e_dashboard_confirm_wiring.qml
```

`tests/.cache/` is scratch (ignored by git). It holds the dumped constants
(`consts/*.txt`), per-run logs (`run-<name>.log`), and the generated
`generated/{unit,e2e}/*.bats` files rebuilt from those logs on every run.

## One UI for everything — how QML assertions become bats tests

Phases 2 and 4 assert inside a live `quickshell` engine, which bats can't host.
Instead each phase runs its harnesses normally (one engine start per harness —
the compute cost is unchanged), then `lib/gen_assert_bats.sh` turns each
harness's LAD log into a temporary `.bats` file with **one real `@test` per
assertion** — each test just addresses its own LAD line by index in the
captured log (no engine re-run, so the bats pass is instant greps). The result:
every assertion in the repo — QML and shell alike — shows up as a native bats
line (`ok 39 tst_defaults ollama/port` / `not ok ...` with the raw
`LAD-FAIL ... got=... expected=...` inline), so the whole suite shares the one
readable UI. Only the first run in each log is canonical: quickshell can
re-instantiate the config after `Qt.quit()`, producing a second, identical
`onCompleted` pass that would otherwise double-count assertions.

## Phase 1 — constant extraction (`lib/extract_constants.sh` + `support/dump_constants.qml`)

`Service.qml` ships long embedded bash scripts and a systemd unit body as QML
string constants. `extract_constants.sh`:

1. assembles `tests/.cache/` so `qs.Commons` resolves,
2. runs `quickshell -p tests/.cache/dump.qml` (a one-shot harness that
   instantiates the real Service with `backend: "llama.cpp"`),
3. regexes the `>>>DUMP:<name><<< <json> >>>END<<<` protocol out of the log,
   strips ANSI, `json.loads` each quoted value, and writes
   `.cache/consts/<name>.txt`.

Dumped constants: `llamaEnvDefault`, `llamaUnitBody`, `provisionLlamaScript`,
`createEnvScript`, `configScript`, `createConfigScript`, `userUnitDir`. Every
bats test reads these files via `lconst()`/`fab()`, so a change to `Service.qml`
propagates automatically — there is nothing to hand-synchronize.

## Phase 2 — QML unit tests (`lib/run_qml_harness.sh` + `lib/asserts.js` + `unit_tests/`)

Each `tst_*.qml` is an `Item` that instantiates the real `Service.qml`, mutates
it, and records assertions through `asserts.js`. The driver:

- copies `Service.qml` (pre-copied into `tests/.cache/run/` by `run_all.sh`);
- assembles a self-contained config dir (= the service's directory) containing
  the harness, the `qs.Commons` / `qs.Ui` stubs, and `asserts.js`;
- substitutes `@SERVICE_QML_PATH@` (and `@SECTION_QML_PATH@` / `@DASHBOARD_QML_PATH@` /
  `@PROBE_SCRIPT_PATH@` where used) with absolute `file://` URLs;
- runs `quickshell -p <dir>/<harness>.qml` in the background, polls the log for
  the summary line, and kills quickshell as soon as it appears (quickshell
  lingers after `Qt.quit()` — the printed summary is the source of truth, not
  the process exit code).

`asserts.js` (`.pragma library`, so it sees JS globals like `Qt` but not QML
types — `Component.Ready` is compared as the literal `1`) provides:

- `check(name, actual, expected)` — `JSON.stringify` equality
- `ok/notok(name, cond)`
- `service(url, parent, backend)` — compile + instantiate, fail/`finish()` on error
- `finish()` — print `LAD-PASS`/`LAD-FAIL` per case, then `LAD-SUMMARY:<n>:<fails>`, then `Qt.quit()`

Coverage (all green): `tst_config_parser` 35, `tst_defaults` 17,
`tst_exitcode_maps` 11, `tst_provision_state` 9, `tst_security_contract` 35,
`tst_validators` 18.

## Phase 3 — shell integration tests (vendored bats + `lib/helpers.bash` + `integration_tests/`)

`bats` 1.14.0 is vendored under `lib/bats/` (no network needed). Each `*.bats`
file loads `helpers.bash`, which provides:

- `lconst <name>` — read a dumped constant;
- `sandbox_setup` / `sandbox_teardown` — fresh `tests/.cache/it.*` dir with
  `bin/` (mocks), writes `PATH`/`__mocklog`;
- `run_script <constant> <args...>` / `provision <consent>` — execute the exact
  extracted scripts;
- `fab` / `fab_unit_file` — reproduce the provisioner's heredoc semantics and
  byte-compare against what the provisioner wrote (command substitution is
  avoided because it strips the trailing newline);
- `expect_*` assertions that print to fd 3 and set `FAIL`; every `teardown()`
  asserts `[ "$FAIL" -eq 0 ]` so a masked failure still fails its test.

Mock contract (all three live in `lib/mocks/`): every call appends
`CALL <argv>` to `${__mocklog:?}`. `systemctl` handles `start` (honors
`FAIL_START`; prints "mock started"), `stop`, `daemon-reload`,
`show`/`list-unit-files` (emit output **only when the unit file exists** — that
is what drives `Service.hasService`), and rejects anything unexpected.

Tests: config reader/writer, env writer, provision create flows and the
rollback/unsafe matrix:

- **exit codes pinned:** 4 create-only/race nothing-to-do, 40 binary missing,
  55 symlink/FIFO hazard, 57 temp-write failure, 58 unit-dir symlink,
  60 lock held, 62 verification failed, 63 start-failed-rollback, 64 dry-run
  update required;
- **file semantics:** 0644 unit / 0600 env exact bytes, atomic temp + `mv`,
  no temp/backup leftovers, env hardened to 0600 on start, symlinks and FIFOs
  never followed or replaced.

## Phase 4 — end-to-end sandbox harnesses (`e2e_tests/`)

`run_all.sh` builds isolated plugin sandboxes (`tests/.cache/e2e/plugin/`) with
real `Service.qml`, `Dashboard.qml`, `sections/`, `ui/`, the three mocks on
`PATH`, and `HOME="$E2E/home"` — then drives the harnesses through the runner
with `blockAllReads: true` for synchronous file assertions.

- `e2e_llama_lifecycle.qml` (16 asserts): full lifecycle — dry-run (exit 64
  prompt, env created 0600, no unit, no start), consent (unit written exactly,
  daemon-reload + start logged, pending cleared), stop (logged, busy released).
  Phase-gated so it waits for the async `which llama-server` install probe and
  for `hasService` before starting/stopping.
- `e2e_llama_rollback.qml` (8 asserts): pre-seeded `OLD-UNIT` + `FAIL_START=1`
  → provisioner backs up, start fails, old unit restored, backup removed, exit
  63 surfaced.
- `e2e_dashboard_confirm_wiring.qml` (11 asserts): compiles and instantiates the
  real `ServiceDetailsSection` against a real `Service`, finds the "Confirm unit
  update & start"/"Cancel" buttons in the object tree, clicks them, and asserts
  the signal arc propagates (`confirmProvisionRequested` → `confirmProvision`, so
  `_provisionConsented === true`; `cancelProvisionRequested` → prompt cleared).
   The Dashboard→section side of the arc is additionally pinned as a
   source-level `rg` check emitted into its own LAD log (folder imports can't
   resolve under `quickshell -p <file>`), so it shows up in the same generated
   bats run as `dashboard-wiring dashboard-wiring`.

## Adding a test

- **Unit:** copy a `tst_*.qml` shape, use `A.check/A.ok`, call `A.finish()`.
  It is picked up automatically by `run_all.sh`.
- **Integration:** add a `@test` to the right `.bats` file (or a new one) and
  use the helpers; keep assertions to fd 3 (`>&3`) so they don't pollute TAP.
- **E2E:** follow the phase-gated `Timer` pattern; the driver's `readFile`
  toggles the `FileView` path to force a fresh sync read.