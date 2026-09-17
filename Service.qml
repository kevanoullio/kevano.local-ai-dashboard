import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons

Item {
  id: root

  property var settings: ({})

  // ── Backend selection ────────────────────────────────────────────────
  property string backend: "ollama"  // "ollama" | "llama.cpp"

  readonly property string backendDisplayName: backend === "llama.cpp" ? "llama.cpp" : "ollama"
  readonly property string backendBinary: backend === "llama.cpp" ? "llama-server" : "ollama"
  readonly property string backendService: backend === "llama.cpp" ? "llama.cpp.service" : "ollama.service"
  readonly property var backendDebugArgs: backend === "llama.cpp"
    ? ["journalctl", "--user", "-u", "llama.cpp.service", "-f"]
    : ["journalctl", "-u", "ollama.service", "-f"]
  readonly property int backendPort: backend === "llama.cpp" ? 8080 : 11434
  readonly property string backendHealthEndpoint: backend === "llama.cpp" ? "http://127.0.0.1:8080/health" : "http://127.0.0.1:11434/"
  // llama.cpp self-provisions its env file and user systemd unit on start
  // (no root/polkit); ollama is managed via the system instance + JSON config.
  readonly property bool selfManaged: backend === "llama.cpp"

  // ── Per-backend config file ─────────────────────────────────────────
  // ollama uses a JSON config in the plugin `configs/` directory, written
  // on user request via a password prompt. llama.cpp uses a user-editable
  // env file (`configs/llama.env`) read by its user systemd unit via
  // EnvironmentFile=; it is self-provisioned on start. The settings button
  // in Dashboard.qml opens `configPath` in the user's editor.
  readonly property string backendConfigFile: backend === "llama.cpp" ? "llama.env" : "ollama.json"
  readonly property string configPath: Qt.resolvedUrl("configs/" + backendConfigFile).toString().replace(/^file:\/\//, "")
  // user unit dir, the same value systemd uses ($XDG_CONFIG_HOME or
  // $HOME/.config + /systemd/user). The provisioner writes llama.cpp.service
  // here through well-tested constants; this resolves to the live path.
  readonly property string userUnitDir: {
    var x = Quickshell.env("XDG_CONFIG_HOME")
    var h = Quickshell.env("HOME")
    var base = (x !== null && x !== "") ? x : ((h !== null && h !== "") ? h + "/.config" : "/tmp")
    return base + "/systemd/user"
  }
  readonly property string defaultConfigJson: '{"host":"127.0.0.1","port":11434,"api-key":""}'
  // Default llama.cpp env file. Written via an unquoted heredoc so $HOME
  // expands to the absolute preset path at write time (systemd does no
  // tilde/var expansion inside env files).
  readonly property string llamaEnvDefault: '# llama.cpp server configuration\n# Managed by local-ai-dashboard. Edit values, then start/restart from the panel.\nLLAMA_HOST=127.0.0.1\nLLAMA_PORT=8080\nLLAMA_API_KEY=\nLLAMA_MODELS_PRESET="$HOME/.config/llama.cpp/models.ini"\nLLAMA_MODELS_MAX=1\nLLAMA_EXTRA_ARGS=\n'

  property string configHost: "127.0.0.1"
  property int configPort: 0
  property string configApiKey: ""

  // Strict config validation (Phase 1). configValid is false when any field in
  // the config file is malformed/unsafe; configWarning is the short human reason
  // shown in the panel. On a violation the config is ignored (safe defaults kept)
  // and — via refreshApi() — NO network call is made until the file is fixed.
  // Written by _parseConfigBuffer, so it cannot be `readonly`; treated as
  // read-only by consumers.
  property bool configValid: true
  property string configWarning: ""

  // ── Validators (pure QML, no processes) ─────────────────────────────
  // Loopback: 127.0.0.0/8 (no leading zeros), ::1, or localhost.
  function isValidLoopbackHost(h) {
    var s = String(h || "").trim()
    if (s === "localhost" || s === "::1" || s === "127.0.0.1") return true
    if (!/^127\.(0|[1-9]\d{0,2})\.(0|[1-9]\d{0,2})\.(0|[1-9]\d{0,2})$/.test(s)) return false
    var octets = s.split(".")
    for (var i = 1; i < 4; i++) {
      if (parseInt(octets[i], 10) > 255) return false
    }
    return true
  }

  // Remote hostnames / IPv4 / bracketed IPv6. Charset allowlist plus IPv4
  // literal sanity: anything with spaces, quotes, `/`, `$`, backticks, `;`,
  // `&`, `|`, etc. fails; a dotted-quad must have valid octets (no leading
  // zeros) and — like http-bind-to-all — the all-zero wildcard 0.0.0.0 is
  // rejected outright (it means "every interface", never a valid endpoint).
  function isValidRemoteHost(h) {
    var s = String(h || "")
    if (s === "") return false
    if (!/^[A-Za-z0-9.\-:\[\]]+$/.test(s)) return false
    if (/^\d+(\.\d+){3}$/.test(s)) {
      var octets = s.split(".")
      var allZero = true
      for (var i = 0; i < octets.length; i++) {
        var o = octets[i]
        if (o.length > 1 && o.charAt(0) === "0") return false
        if (parseInt(o, 10) > 255) return false
        if (parseInt(o, 10) !== 0) allZero = false
      }
      return !allZero
    }
    return true
  }

  function isValidPort(p) {
    return typeof p === "number" && Number.isInteger(p) && p >= 1 && p <= 65535
  }

  // Empty is valid (means "no auth"). A present key rides inside a curl config
  // line (double-quoted), so `"`, `\` and control characters are rejected.
  function isValidApiKey(k) {
    var s = String(k || "")
    if (s === "") return true
    if (s.length > 256) return false
    for (var i = 0; i < s.length; i++) {
      var c = s.charCodeAt(i)
      if (c === 0x22 || c === 0x5c || c < 0x20 || c === 0x7f) return false
    }
    return true
  }

  // Extra args end up in the unit's ExecStart (shell-expanded), so each token
  // is restricted to a safe CLI skeleton. `~` is rejected too (no tilde paths).
  function validateExtraArgs(s) {
    var v = String(s || "").trim()
    if (v === "") return true
    var tokens = v.split(/\s+/)
    for (var i = 0; i < tokens.length; i++) {
      if (!/^[A-Za-z0-9._/+=:,%-]+$/.test(tokens[i])) return false
    }
    return true
  }

  // Absolute path only; reject quotes, backslash, `$`, backtick, newline/tab.
  function isValidPresetPath(p) {
    var s = String(p || "")
    if (s === "") return true
    if (s.charAt(0) !== "/") return false
    return !/["\\$`\r\n\t]/.test(s)
  }

  readonly property string effectiveHost: configHost !== "" ? configHost : "127.0.0.1"
  readonly property int effectivePort: configPort > 0 ? configPort : backendPort

  // Endpoint policy: http is allowed for loopback hosts only; any non-loopback
  // host must be https (curl default certificate validation, never -k). The
  // config stores no scheme, so a valid non-loopback host already implies https
  // — there is no way to request plaintext http for a remote host.
  readonly property string endpointScheme: isValidLoopbackHost(effectiveHost) ? "http" : "https"
  readonly property bool hostOk: isValidLoopbackHost(effectiveHost) || isValidRemoteHost(effectiveHost)
  readonly property bool portOk: isValidPort(effectivePort)
  // Scheme rule: loopback ⇒ http OR non-loopback ⇒ https. It always holds once
  // hostOk is true, but is kept explicit so the policy is auditable here.
  // configValid is folded in so THIS single flag enforces the whole "invalid
  // config ⇒ no network calls" policy in refreshApi().
  readonly property bool endpointOk: configValid && hostOk && portOk && (isValidLoopbackHost(effectiveHost) || endpointScheme === "https")
  readonly property string effectiveHealthEndpoint: endpointScheme + "://" + effectiveHost + ":" + effectivePort + (backend === "llama.cpp" ? "/health" : "/")
  readonly property string effectiveListEndpoint: backend === "llama.cpp" ? endpointScheme + "://" + effectiveHost + ":" + effectivePort + "/v1/models" : ""

  // ── Constant shell scripts (no user data concatenation) ────────────
  // Every Process builds its command from these constants only. User values
  // arrive as positional args ($1..$n); the API key arrives only through
  // Process.environment and is handed to curl on stdin (`curl -K -`) — never
  // in argv and never on disk.
  readonly property string curlFnLlama:
`hdr() { if [ -n "$DASH_API_KEY" ]; then
           printf 'header = "X-Api-Key: %s"\n' "$DASH_API_KEY" | curl -K - "$@"
         else
           curl "$@"
         fi }`

  readonly property string curlFnOllama:
`hdr() { if [ -n "$DASH_API_KEY" ]; then
           printf 'header = "Authorization: Bearer %s"\n' "$DASH_API_KEY" | curl -K - "$@"
         else
           curl "$@"
         fi }`

  readonly property string healthScriptLlama: curlFnLlama + `
set -o pipefail;
hdr -s -o /dev/null -w '%{http_code} %{time_total}' --connect-timeout 3 --max-time 5 "$1" 2>/dev/null | head -c "$2"`

  readonly property string healthScriptOllama: curlFnOllama + `
set -o pipefail;
hdr -s -o /dev/null -w '%{http_code} %{time_total}' --connect-timeout 3 --max-time 5 "$1" 2>/dev/null | head -c "$2"`

  readonly property string listScriptLlama: curlFnLlama + `
set -o pipefail;
hdr -s "$1" 2>&1 | head -c "$2"`

  readonly property string listScriptOllama: `
set -o pipefail;
ollama list 2>&1 | head -c "$1"`

  // ── Systemd / process probes (constants, args-only) ───────────────
  // $1 = scope flag ("--user" for llama.cpp, empty for the system ollama
  // service), $2 = unit name, $3 = output cap. No user data is ever
  // concatenated into these strings.
  readonly property string checkServiceScript: `
set -o pipefail;
systemctl $1 list-unit-files $2 --no-legend 2>&1 | head -c $3`

  readonly property string serviceScript: `
set -o pipefail;
systemctl $1 show $2 --property=ActiveState,SubState,ActiveEnterTimestamp 2>&1 | head -c $3`

  readonly property string psScriptLlama: `
set -o pipefail;
pgrep -af '[l]lama-server' | grep -oE '(--model|-m)[= ][^ ]+' 2>&1 | head -c $1`

  readonly property string psScriptOllama: `
set -o pipefail;
ollama ps 2>&1 | head -c $1`

  readonly property string versionScript: `
set -o pipefail;
$1 --version 2>&1 | head -c $2`

   // Config reader probe. Path is $1 (the only variable input), cap is $2.
   // Refuses symlinks and special files: a config that is really a link, a
   // FIFO/pipe, or a socket reports REFUSE instead of HAS so no data leaks
   // (or hangs) and the panel warns instead of parsing it. A regular file is
   // hardened to 0600 in place (idempotent; it may hold an API key) — the file
   // is user-owned, so no privilege is needed and nothing is ever chmodded
   // through a link.
   readonly property string configScript: `
f="$1";
{ if [ -f "$f" ] && [ ! -L "$f" ] && [ ! -p "$f" ]; then
    chmod 600 -- "$f" 2>/dev/null;
    echo HAS; cat "$f";
  elif [ -L "$f" ] || [ -p "$f" ]; then
    echo REFUSE;
  else
    echo NO;
  fi; } 2>/dev/null | head -c $2`

  // Generic config-file writer (ollama JSON). Create-only, symlink-refusing,
  // atomic, 0600 — writing a file in the user's own plugin directory needs
  // no privilege, so there is no pkexec here at all. $1 = target, $2 = content.
  // Exit codes: 4 = target already exists (not an error), 55 = parent dir is
  // a symlink, 5/6 = temp file write/rename failed.
  readonly property string createConfigScript: `
set -o pipefail;
f="$1";
d=$(dirname -- "$f");
[ -L "$d" ] && exit 55;
[ -d "$d" ] || mkdir -p -- "$d";
if [ -e "$f" ] || [ -L "$f" ]; then exit 4; fi;
t=$(mktemp -- "$d/.dashboard-config.XXXXXX") || exit 5;
printf '%s' "$2" > "$t" && chmod 600 "$t" && mv -f -- "$t" "$f" || { rm -f -- "$t"; exit 6; }`

  // llama.env writer: the same create-only / symlink-refusing / atomic / 0600
  // pattern as createConfigScript, but the content is a constant heredoc so
  // $HOME expands at write time (as today). Only the path is an argument.
  readonly property string createEnvScript: `
set -o pipefail;
f="$1";
d=$(dirname -- "$f");
[ -L "$d" ] && exit 55;
[ -d "$d" ] || mkdir -p -- "$d";
if [ -e "$f" ] || [ -L "$f" ]; then exit 4; fi;
t=$(mktemp -- "$d/.llama.env.XXXXXX") || exit 5;
cat > "$t" <<ENV
` + root.llamaEnvDefault + `ENV
chmod 600 "$t" && mv -f -- "$t" "$f" || { rm -f -- "$t"; exit 6; }`

  // The user systemd unit template for llama.cpp (identical to the unit
  // generated before Phase 4, so the dry-run comparison finds no change for
  // existing installs). `$f` and `$abs` expand at write time (heredoc run in
  // the provisioner); the `\${LLAMA_*}` tokens stay literal in the file so
  // systemd reads them from the EnvironmentFile at runtime.
  readonly property string llamaUnitBody: '[Unit]\nDescription=llama.cpp server (managed by local-ai-dashboard)\n' +
    'After=network.target\n\n[Service]\nType=simple\n' +
    'EnvironmentFile=$f\n' +
    'ExecStart=/bin/bash -c \'exec "$abs" --host "\\${LLAMA_HOST:-127.0.0.1}" --port "\\${LLAMA_PORT:-8080}" --models-preset "\\${LLAMA_MODELS_PRESET}" --models-max "\\${LLAMA_MODELS_MAX:-1}" \\${LLAMA_EXTRA_ARGS}\'\n' +
    'Restart=on-failure\n\n[Install]\nWantedBy=default.target\n'

  // Phase 4 provisioning script (constant; args only). Args: $1 = env file
  // path, $2 = user unit dir, $3 = backend binary name, $4 = consent (0/1),
  // $5 = output cap for systemctl. Behaviour:
  //   - env file: create-only / symlink+FIFO-refusing / atomic / 0600, and
  //     chmod 600 an existing regular env file (Phase 3 guarantee).
  //   - unit: generated in a temp file and compared with the installed one.
  //     Identical -> plain `systemctl --user start`, no consent needed.
  //     Different/missing -> dry-run: touch nothing, print the consent marker,
  //     exit 64. With consent: .bak backup -> systemd-analyze --user verify ->
  //     atomic swap -> daemon-reload -> start; on start failure restore .bak
  //     (or remove the unit on first-time create) so the system is left exactly
  //     as before. flock guards against concurrent provisioners.
  // Exit codes: 0 or 4 done; 55 unsafe env path; 58 unsafe unit dir; 57/61
  // temp file failure; 60 lock held; 62 verification failed; 63 rolled back;
  // 64 consent required; 40 binary missing.
  readonly property string provisionLlamaScript:
`set -uo pipefail;
f="$1"; ud="$2"; bin="$3"; yes="\${4:-0}"; cap="\${5:-512}"; u="$ud/llama.cpp.service";
abs=$(command -v -- "$bin") || exit 40;
[ -L "$ud" ] && exit 58; [ -d "$ud" ] || mkdir -p -- "$ud";
exec 9>>"$ud/.local-ai-dashboard.lock"; flock -n 9 || exit 60;
d=$(dirname -- "$f"); [ -L "$d" ] && exit 55; [ -d "$d" ] || mkdir -p -- "$d";
if [ -e "$f" ] || [ -L "$f" ]; then
  if [ -L "$f" ] || [ -p "$f" ]; then exit 55; fi;
  [ -f "$f" ] && chmod 600 "$f";
else
  t=$(mktemp -- "$d/.llama.env.XXXXXX") || exit 57;
  cat > "$t" <<ENV
` + root.llamaEnvDefault + `ENV
  chmod 600 "$t" && mv -f -- "$t" "$f" || { rm -f -- "$t"; exit 57; };
fi;
tmp=$(mktemp -- "$ud/.llama.cpp.service.XXXXXX") || exit 61;
cat > "$tmp" <<UNIT
` + root.llamaUnitBody + `UNIT
chmod 644 "$tmp";
if [ -e "$u" ] && cmp -s -- "$u" "$tmp"; then
  rm -f -- "$tmp";
  systemctl --user start llama.cpp.service 2>&1 | head -c "$cap";
  exit $?;
fi;
[ "$yes" = "1" ] || { rm -f -- "$tmp"; echo "SERVICE-UPDATE-REQUIRED"; exit 64; };
cp -a -- "$u" "$ud/.llama.cpp.service.bak" 2>/dev/null || true;
systemd-analyze --user verify "$tmp" >/dev/null 2>&1 || { rm -f -- "$tmp" "$ud/.llama.cpp.service.bak"; exit 62; };
mv -f -- "$tmp" "$u";
systemctl --user daemon-reload;
if systemctl --user start llama.cpp.service 2>&1 | head -c "$cap"; then exit 0; fi;
if [ -e "$ud/.llama.cpp.service.bak" ]; then
  mv -f -- "$ud/.llama.cpp.service.bak" "$u";
else
  rm -f -- "$u";
fi;
systemctl --user daemon-reload;
exit 63`

  readonly property string serviceMemoryScript: `
set -o pipefail;
cg=$(systemctl --user show $1 --property=ControlGroup --value 2>/dev/null);
out="";
[ -n "$cg" ] && [ -r "/sys/fs/cgroup$cg/memory.stat" ] && out=$(awk '$1=="anon"{a=$2}$1=="shmem"{s=$2}END{print (a+0)+(s+0)}' "/sys/fs/cgroup$cg/memory.stat" 2>/dev/null);
[ -z "$out" ] && out=$(systemctl --user show $1 --property=MemoryCurrent --value 2>/dev/null);
[ -n "$out" ] || out=0;
echo "$out" | head -c $2`

   readonly property string serviceVramScript: `
set -o pipefail;
cg=$(systemctl --user show $1 --property=ControlGroup --value 2>/dev/null);
pid=$(systemctl --user show $1 --property=MainPID --value);
pids="$pid"; [ -n "$cg" ] && [ -r "/sys/fs/cgroup$cg/cgroup.procs" ] && pids="$(tr '\\n' ' ' < "/sys/fs/cgroup$cg/cgroup.procs") $pid";
if command -v nvidia-smi >/dev/null 2>&1; then
nvidia-smi --query-compute-apps=pid,used_memory --format=csv,noheader,nounits 2>/dev/null |
awk -F',' -v ps="$pids" 'BEGIN{n=split(ps,a," ");for(i=1;i<=n;i++)if(a[i]!="")seen[a[i]]=1}{gsub(/[ \\t]/,"",$1);gsub(/[ \\t]/,"",$2);if(($1 in seen)&&$2~/^[0-9]+$/){sum+=$2;c++}}END{if(c>0)print sum" MiB"}';
elif command -v rocm-smi >/dev/null 2>&1; then
rocm-smi --showmeminfo vram 2>/dev/null | head -2;
fi | head -c $2`

   // Start/stop actions. Ollama runs on the SYSTEM unit, so it goes through
   // pkexec — that IS the polkit consent gate, and stays as-is. llama.cpp stop
   // is a plain user-unit stop (no privilege). $1 = unit name, $2 = cap; both
   // are QML constants/numbers, never user data.
   readonly property string pkStartScript: `
set -o pipefail;
pkexec /usr/bin/systemctl start "$1" 2>&1 | head -c "$2"`

   readonly property string pkStopScript: `
set -o pipefail;
pkexec /usr/bin/systemctl stop "$1" 2>&1 | head -c "$2"`

   readonly property string userStopScript: `
set -o pipefail;
systemctl --user stop "$1" 2>&1 | head -c "$2"`

  // ── State ─────────────────────────────────────────────────────────
  property bool installed: false       // backend binary on PATH
  property bool hasService: false      // systemd unit file exists
  property bool running: false
  property bool busy: false
  property bool hasConfig: false       // plugin config file exists
  // Phase 4: the llama.cpp dry-run detected a unit change and is waiting for
  // the user to confirm the write (or for the auto-cancel timer to expire).
  property bool pendingProvision: false
  // Set only for the confirm() relaunch so the dry-run keeps consent=0.
  property bool _provisionConsented: false
  property string actionLabel: ""
  property string lastError: ""

  // ── API health ─────────────────────────────────────────────────────
  property bool apiReachable: false
  property int apiLatencyMs: -1

  // ── Model info (bounded) ──────────────────────────────────────────
  readonly property int maxModels: 50
  readonly property int maxRunning: 10
  property var models: []
  property var runningModels: []

  // ── Service info ───────────────────────────────────────────────────
  property string activeSince: ""
  property string ollamaVersion: ""
  property double serviceMemoryBytes: -1  // llama.cpp DRAM: cgroup anon+shmem working set (bytes); double avoids 32-bit int overflow >2 GiB
  property double serviceVramBytes: -1    // llama.cpp VRAM: per-PID GPU memory (bytes); -1 = unknown
  property double serviceTotalBytes: -1   // llama.cpp full footprint = DRAM + VRAM; -1 = unknown

  // ── Refresh ────────────────────────────────────────────────────────
  readonly property int refreshIntervalSec: intSetting("refreshIntervalSec", 10, 2, 300)

  // ── Process deadlines ─────────────────────────────────────────────
  //
  // Two layers of deadline protection:
  //
  // 1. `timeout` (primary): runs each command in its own process group
  //    and kills the entire group on expiry — no orphaned children.
  //    `timeout -k 2 N` sends SIGTERM after N seconds, then SIGKILL 2s
  //    later if still running. Exit code 124 (timeout) or 137 (SIGKILL)
  //    is discarded by the exitCode === 0 guard in onExited.
  //
  // 2. QML watchdog (backup): if timeout itself somehow hangs, the
  //    watchdog sets process.running = false, which calls
  //    QProcess::terminate() on the timeout PID. This is a fallback only.
  //
  // The watchdog interval is set slightly above the timeout duration so
  // timeout (which handles the process group) always fires first.

  readonly property int processTimeoutSec: 8       // timeout duration for regular commands
  readonly property int startTimeoutSec: 15        // systemctl start can be slow
  readonly property int watchdogMs: 12000          // backup watchdog for regular commands
  readonly property int startWatchdogMs: 20000     // backup watchdog for start

  // ── Output caps at the OS pipe level ──────────────────────────────
  // Every command is piped through `head -c N` so the producer cannot
  // force unbounded allocation in SplitParser's internal line buffer.
  // `set -o pipefail` preserves the producer's exit code; SIGPIPE from
  // head truncation yields exit 141, which our exitCode === 0 guard
  // discards so truncated output is never parsed.
  readonly property int capService: 2048     // systemctl show output
  readonly property int capCheck: 512       // systemctl list-unit-files output
  readonly property int capList: 65536      // model list output
  readonly property int capPs: 16384       // running models output
  readonly property int capVersion: 256    // version output
  readonly property int capApi: 128        // API health check output
  readonly property int capAction: 512     // start/stop stderr capture
  readonly property int capConfig: 2048    // config file read output
  readonly property int capServiceMemory: 64  // memory.stat anon+shmem sum (bytes)
  readonly property int capServiceVram: 64    // nvidia-smi/rocm-smi per-PID value

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  function intSetting(name, fallback, min, max) {
    var n = parseInt(String(setting(name, fallback)), 10)
    if (!isFinite(n)) n = fallback
    if (n < min) n = min
    if (n > max) n = max
    return n
  }

  // ── Sanitize external strings for safe display ──────────────────────
  function formatGB(bytes) {
    var b = parseInt(String(bytes), 10)
    if (!isFinite(b) || b < 0) return "\u2014"
    var gb = b / (1024 * 1024 * 1024)
    if (gb >= 1024) return (gb / 1024).toFixed(1) + " TB"
    return gb.toFixed(1) + " GB"
  }

  // CPU/GPU split (llama.cpp): CPU = measured DRAM fraction of the full
  // footprint (DRAM + per-PID VRAM); GPU covers the remainder. Both halves
  // are measured — no size-based estimate. Returns CPU percent, or -1 when
  // either measurement is unavailable.
  function cpuSplitPercent() {
    if (serviceTotalBytes < 0) return -1
    return Math.round(serviceMemoryBytes / serviceTotalBytes * 100)
  }

  // Full llama.cpp memory footprint (DRAM + VRAM) formatted for display,
  // or "" when unknown.
  function memoryTotalGB() {
    return serviceTotalBytes >= 0 ? formatGB(serviceTotalBytes) : ""
  }

  function sanitize(str) {
    return String(str || "").replace(/[<>&]/g, function(c) {
      if (c === "<") return "&lt;"
      if (c === ">") return "&gt;"
      if (c === "&") return "&amp;"
      return c
    })
  }

  function truncate(str, maxLen) {
    var s = String(str || "")
    if (s.length <= maxLen) return s
    return s.substring(0, maxLen) + "…"
  }

  // Classify a start/stop failure into an actionable message.
  //
  // Start/stop goes through `pkexec /usr/bin/systemctl …`, which shows a graphical
  // polkit prompt (Omarchy ships a polkit agent inside omarchy-shell).
  // Detect the common failure modes — cancelled prompt, no polkit agent,
  // explicit denial — and surface actionable text instead of raw output.
  function _actionError(output, verb) {
    var s = String(output || "").trim()
    var verbDisplay = verb === "start" ? "Start" : verb === "create" ? "Create" : "Stop"
    if (/request dismissed|dismissed by user|was not shown|cancelled|canceled/i.test(s)) {
      return verbDisplay + " cancelled — authentication was dismissed."
    }
    if (/not authorized|permission denied|access denied/i.test(s)) {
      return "Cannot " + verb + " " + root.backendDisplayName + ": you are not authorized to manage system services."
    }
    if (/no authentication agent|error creating textual authentication agent/i.test(s)) {
      return "Cannot " + verb + " " + root.backendDisplayName + ": no polkit authentication agent found.\n" +
             "Make sure the Polkit plugin is enabled in omarchy-shell settings."
    }
    return "Failed to " + verb + " " + root.backendDisplayName
  }

  // Phase 4 provisioning exit-code map (llama.cpp). The provisioner is
  // deterministic and communicates failure modes via exit codes, so each
  // code maps to a precise, actionable message instead of raw systemctl output.
  function _provisionError(exitCode, output) {
    var b = String(output || "").trim()
    var why = ""
    switch (exitCode) {
      case 55: why = "Cannot start " + root.backendDisplayName + ": refusing to write the config (parent path is a symlink)."; break
      case 57: why = "Cannot start " + root.backendDisplayName + ": the environment file could not be written."; break
      case 58: why = "Cannot start " + root.backendDisplayName + ": refusing to write the systemd unit (its directory is a symlink)."; break
      case 40: why = "Cannot start " + root.backendDisplayName + ": " + root.backendBinary + " is not on PATH."; break
      case 60: why = "Another local-ai-dashboard instance is already provisioning " + root.backendDisplayName + ". Try again in a moment."; break
      case 61: why = "Cannot start " + root.backendDisplayName + ": the systemd unit could not be created."; break
      case 62: why = "Cannot start " + root.backendDisplayName + ": the generated systemd unit failed systemd-analyze verification. Nothing was changed."; break
      case 63: why = "Start failed after provisioning — the previous systemd unit was restored. See the error below; check the debug log for details."; break
      default:
        if (b !== "") return _actionError(b, "start")
        return "Failed to start " + root.backendDisplayName
    }
    return b !== "" ? why + "\n" + b : why
  }

  // ── Process management ──────────────────────────────────────────────
  function launch(process, watchdog) {
    if (!process.running) {
      process.running = true
      watchdog.restart()
    }
  }

  function reap(process, watchdog) {
    watchdog.stop()
    if (process.running) process.running = false
  }

  function refresh() {
    if (!installed) {
      launch(whichProcess, whichWatchdog)
      return
    }
    if (!hasService) {
      launch(checkServiceProcess, checkServiceWatchdog)
      return
    }
    launch(serviceProcess, serviceWatchdog)
  }

  function refreshApi() {
    if (!running) {
      apiReachable = false
      apiLatencyMs = -1
      return
    }
    // Enforced endpoint policy: endpointOk folds in configValid, so if the
    // config is invalid/unsafe (or a host/port violates the loopback-http /
    // remote-https rule) no network process is launched at all — no health
    // check, no model list. configWarning explains why on the panel;
    // apiReachable just stays false.
    if (!endpointOk) {
      apiReachable = false
      apiLatencyMs = -1
      models = []
      runningModels = []
      serviceMemoryBytes = -1
      serviceVramBytes = -1
      serviceTotalBytes = -1
      return
    }
    // Clear transient errors on a fresh successful refresh cycle
    lastError = ""
    launch(apiHealthProcess, apiHealthWatchdog)
    launch(listProcess, listWatchdog)
    launch(psProcess, psWatchdog)
    // llama.cpp: query the user service's current DRAM + VRAM footprint
    if (backend === "llama.cpp") {
      launch(serviceMemoryProcess, serviceMemoryWatchdog)
      launch(serviceVramProcess, serviceVramWatchdog)
    }
    // Only fetch version once — it never changes during a session
    if (ollamaVersion === "" && !versionProcess.running) {
      launch(versionProcess, versionWatchdog)
    }
  }

  function startService() {
    // Start: llama.cpp self-provisions env + unit, so only needs the binary installed.
    if (busy || !installed) return
    if (backend === "ollama" && (!hasService || !hasConfig)) return
    // A Start is always a fresh dry-run: clears any pending consent state.
    pendingProvision = false
    provisionTimer.stop()
    _provisionConsented = false
    busy = true
    actionLabel = "Starting " + root.backendDisplayName + "…"
    lastError = ""
    startProcess.running = true
    startActionWatchdog.restart()
  }

  // The dry-run reported a unit change and the user clicked "Confirm": relaunch
  // the provisioner with consent=1 so it can back up, atomically swap and start.
  function confirmProvision() {
    if (busy || !installed) return
    _provisionConsented = true
    pendingProvision = false
    provisionTimer.stop()
    busy = true
    actionLabel = "Starting " + root.backendDisplayName + "…"
    lastError = ""
    startProcess.running = true
    startActionWatchdog.restart()
  }

  function cancelProvision() {
    pendingProvision = false
    provisionTimer.stop()
    _provisionConsented = false
  }

  function stopService() {
    // Stop: llama.cpp needs its user unit to exist.
    if (busy || !installed) return
    if (backend === "ollama" && (!hasService || !hasConfig)) return
    if (backend === "llama.cpp" && !hasService) return
    busy = true
    actionLabel = "Stopping " + root.backendDisplayName + "…"
    lastError = ""
    stopProcess.running = true
    stopActionWatchdog.restart()
  }

  // Write the default config file: a password prompt for ollama, plain bash
  // for llama.cpp. Guarded by `!hasConfig` so an existing file is never
  // overwritten; on success the file is re-read so the config values and
  // hasConfig update immediately.
  function createConfigFile() {
    if (busy || hasConfig) return
    busy = true
    actionLabel = "Creating " + root.backendDisplayName + " config…"
    lastError = ""
    createConfigProcess.running = true
    createConfigWatchdog.restart()
  }

  function toggleService() {
    if (running) stopService()
    else startService()
  }

  // ── Streaming parsers ──────────────────────────────────────────────
  //
  // Output is bounded at the OS pipe level by `head -c N` (see cap*
  // properties above).  SplitParser then hands each line to onRead as it
  // arrives.  These parsers cap their own accumulation and the arrays
  // they feed as a second layer of defence.

  // systemctl show → service state
  property string _serviceBuffer: ""
  readonly property int _serviceBufferMax: 2048

  function _onServiceLine(line) {
    var s = String(line || "")
    if (_serviceBuffer.length + s.length + 1 <= _serviceBufferMax) {
      _serviceBuffer += s + "\n"
    }
  }

  function _parseServiceBuffer() {
    var raw = _serviceBuffer
    _serviceBuffer = ""
    var lines = raw.trim().split("\n").slice(0, 20)
    var state = ""
    var subState = ""
    var since = ""
    for (var i = 0; i < lines.length; i++) {
      var line = lines[i]
      if (line.indexOf("ActiveState=") === 0) state = truncate(line.substring(12), 64)
      else if (line.indexOf("SubState=") === 0) subState = truncate(line.substring(9), 64)
      else if (line.indexOf("ActiveEnterTimestamp=") === 0) since = truncate(line.substring(21), 128)
    }
    running = (state === "active" && subState === "running")
    activeSince = since
    if (running) refreshApi()
    else {
      runningModels = []
      apiReachable = false
      apiLatencyMs = -1
      serviceMemoryBytes = -1
      serviceVramBytes = -1
      serviceTotalBytes = -1
    }
  }

  // systemctl list-unit-files → service existence
  property string _checkBuffer: ""
  readonly property int _checkBufferMax: 512

  function _onCheckLine(line) {
    var s = String(line || "")
    if (_checkBuffer.length + s.length + 1 <= _checkBufferMax) {
      _checkBuffer += s + "\n"
    }
  }

  function _parseCheckBuffer() {
    var output = truncate(_checkBuffer.trim(), 512)
    _checkBuffer = ""
    hasService = output.length > 0 && output.indexOf(root.backendService) !== -1
    if (hasService) refresh()
  }

  // ollama list → model list (tabular format)
  property var _listModels: []
  property bool _listHeaderSeen: false

  function _onListLine(line) {
    if (_listModels.length >= maxModels) return
    var s = String(line || "").trim()
    if (s === "") return
    if (!_listHeaderSeen) { _listHeaderSeen = true; return }
    var parts = s.split(/\s{2,}/)
    if (parts.length >= 4) {
      var name = truncate(parts[0] || "", 128)
      _listModels.push({
        name: name,
        id: truncate(parts[1] || "", 64),
        size: truncate(parts[2] || "", 32),
        modified: truncate(parts.slice(3).join("  ") || "", 64),
        isCloud: isCloudModel(name)
      })
    }
  }

  function _finishList() {
    models = _listModels
    _listModels = []
    _listHeaderSeen = false
  }

  // llama.cpp /v1/models → model list (JSON format)
  property string _jsonBuffer: ""
  readonly property int _jsonBufferMax: 65536

  function _onJsonLine(line) {
    var s = String(line || "")
    if (_jsonBuffer.length + s.length + 1 <= _jsonBufferMax) {
      _jsonBuffer += s + "\n"
    }
  }

  function _finishJsonModels() {
    var raw = _jsonBuffer.trim()
    _jsonBuffer = ""
    try {
      var obj = JSON.parse(raw)
      var data = obj.data || []
      _listModels = []
      _psModels = []
      for (var i = 0; i < data.length && _psModels.length < maxRunning; i++) {
        var m = data[i]
        if (m.status && m.status.value === "loaded") {
          var loadedName = m.id || "Unknown model"
          var pathParts = String(loadedName).split("/")
          var sizeBytes = parseInt(m.meta && m.meta.size, 10)
          if (!isFinite(sizeBytes) || sizeBytes < 0) sizeBytes = 0
          _psModels.push({
            name: truncate(pathParts[pathParts.length - 1] || "Unknown model", 128),
            id: truncate(m.id || "", 64),
            size: sizeBytes > 0 ? root.formatGB(sizeBytes) : "",
            sizeBytes: sizeBytes,
            processor: truncate(m.status.processor || m.status.backend || "CPU", 32),
            context: truncate(m.status.context || "", 32),
            until: "loaded"
          })
        }
        _listModels.push({
          name: truncate(m.id || "", 128),
          id: truncate(m.id || "", 64),
          size: "",
          modified: "",
          isCloud: false
        })
      }
    } catch(e) {
      _listModels = []
      _psModels = []
    }
    models = _listModels
    runningModels = _psModels
    _psModels = []
    _listHeaderSeen = false
  }

  // ollama ps → running models
  property var _psModels: []
  property bool _psHeaderSeen: false

  function _onPsLine(line) {
    if (_psModels.length >= maxRunning) return
    var s = String(line || "").trim()
    if (s === "") return
    if (!_psHeaderSeen) { _psHeaderSeen = true; return }
    var parts = s.split(/\s{2,}/)
    if (parts.length >= 2) {
      _psModels.push({
        name: truncate(parts[0] || "", 128),
        id: truncate(parts[1] || "", 64),
        size: truncate(parts[2] || "", 32),
        processor: truncate(parts[3] || "", 32),
        context: truncate(parts[4] || "", 32),
        until: truncate(parts.slice(5).join("  ") || "", 64)
      })
    }
  }

  function _finishPs() {
    if (root.backend === "llama.cpp") return
    runningModels = _psModels
    _psModels = []
    _psHeaderSeen = false
  }

  // llama.cpp running models: pgrep → extract --model / -m argument
  property string _pgrepBuffer: ""
  readonly property int _pgrepBufferMax: 512

  function _onPgrepLine(line) {
    var s = String(line || "")
    if (_pgrepBuffer.length + s.length + 1 <= _pgrepBufferMax) {
      _pgrepBuffer += s + "\n"
    }
  }

  function _finishPgrep() {
    var raw = _pgrepBuffer.trim()
    _pgrepBuffer = ""
    var lines = raw === "" ? [] : raw.split("\n")
    _psModels = []
    for (var i = 0; i < lines.length && _psModels.length < maxRunning; i++) {
      var match = String(lines[i]).trim().match(/(?:--model|-m)[= ]+([^ ]+)/)
      if (!match) continue
      var path = match[1]
      var name = path.split("/").pop()
      _psModels.push({
        name: truncate(name || "Unknown model", 128),
        id: "local",
        size: "",
        processor: "CPU",
        context: "",
        until: "loaded"
      })
    }
    _psHeaderSeen = false
  }

  // ollama --version → version string (only fetched once per session)
  function _onVersionLine(line) {
    if (ollamaVersion === "") {
      var v = String(line || "").trim()
      if (backend === "llama.cpp") {
        v = v.replace(/,\s*commit\s+[^\s)]+/, "").trim()
      }
      ollamaVersion = truncate(v, 128)
    }
  }

  // API health → latency
  property string _apiBuffer: ""
  readonly property int _apiBufferMax: 128

  function _onApiLine(line) {
    var s = String(line || "")
    if (_apiBuffer.length + s.length + 1 <= _apiBufferMax) {
      _apiBuffer += s + "\n"
    }
  }

  function _parseApiBuffer() {
    var raw = truncate(_apiBuffer.trim(), 128)
    _apiBuffer = ""
    var parts = raw.split(/\s+/)
    var code = parseInt(parts[0], 10)
    // curl -w '%{http_code} %{time_total}' → e.g. "200 0.042" (seconds)
    var seconds = parts.length > 1 ? parseFloat(parts[1], 10) : NaN
    apiReachable = (code === 200)
    apiLatencyMs = isFinite(seconds) && seconds >= 0 ? Math.round(seconds * 1000) : -1
  }

  // cgroup memory.stat (anon + shmem) → llama.cpp DRAM working set (bytes), excluding reclaimable page cache
  property string _serviceMemoryBuffer: ""
  readonly property int _serviceMemoryBufferMax: 64

  function _onServiceMemoryLine(line) {
    var s = String(line || "")
    if (_serviceMemoryBuffer.length + s.length + 1 <= _serviceMemoryBufferMax) {
      _serviceMemoryBuffer += s + "\n"
    }
  }

  function _finishServiceMemory() {
    var raw = truncate(_serviceMemoryBuffer.trim(), _serviceMemoryBufferMax)
    _serviceMemoryBuffer = ""
    var n = parseInt(raw.split("\n")[0], 10)
    serviceMemoryBytes = isFinite(n) && n >= 0 ? n : -1
    _deriveServiceTotal()
  }

  // nvidia-smi/rocm-smi → llama.cpp per-PID VRAM footprint
  property string _serviceVramBuffer: ""
  readonly property int _serviceVramBufferMax: 64

  function _onServiceVramLine(line) {
    var s = String(line || "")
    if (_serviceVramBuffer.length + s.length + 1 <= _serviceVramBufferMax) {
      _serviceVramBuffer += s + "\n"
    }
  }

  function _finishServiceVram() {
    var raw = truncate(_serviceVramBuffer.trim(), _serviceVramBufferMax)
    _serviceVramBuffer = ""
    // The query emits the "used_memory" column (e.g. "64 MiB"); any sentinel
    // (empty / non-numeric / "N/A") means no measurable GPU context → unknown.
    var m = raw.match(/(\d+(?:\.\d+)?)\s*MiB/)
    var n = m ? Math.round(parseFloat(m[1]) * 1024 * 1024) : -1
    serviceVramBytes = n >= 0 ? n : -1
    _deriveServiceTotal()
  }

  // Full footprint = measured DRAM + measured per-PID VRAM. Unknown when
  // either half hasn't resolved.
  function _deriveServiceTotal() {
    if (serviceMemoryBytes >= 0 && serviceVramBytes >= 0) {
      serviceTotalBytes = serviceMemoryBytes + serviceVramBytes
    } else {
      serviceTotalBytes = -1
    }
  }

  // ── Config file → JSON → state ──────────────────────────────────────
  property string _configBuffer: ""
  readonly property int _configBufferMax: 2048

  function _onConfigLine(line) {
    var s = String(line || "")
    if (_configBuffer.length + s.length + 1 <= _configBufferMax) {
      _configBuffer += s + "\n"
    }
  }

  function _parseConfigBuffer() {
    var raw = truncate(_configBuffer.trim(), _configBufferMax)
    _configBuffer = ""
    var newline = raw.indexOf("\n")
    var first = newline !== -1 ? raw.substring(0, newline).trim() : raw
    var body = newline !== -1 ? raw.substring(newline + 1) : ""
    hasConfig = first === "HAS"
    // A config path that is actually a symlink or special file is refused at
    // the reader; report it clearly instead of pretending the config is gone.
    if (first === "REFUSE") {
      hasConfig = false
      configHost = "127.0.0.1"
      configPort = 0
      configApiKey = ""
      configValid = true
      configWarning = truncate("Refusing to read config: " + root.configPath + " is a symlink or special file.", 256)
      return
    }
    if (!hasConfig) {
      configHost = "127.0.0.1"
      configPort = 0
      configApiKey = ""
      configValid = true
      configWarning = ""
      return
    }
    // Collected values default to safe values. Any violation resets the
    // applied state back to these and records a human reason for the panel.
    var host = "127.0.0.1"
    var port = -1  // -1 = never set in the file = use the backend default port
    var apiKey = ""
    var violations = []
    if (backend === "llama.cpp") {
      var envLines = body.split("\n")
      for (var i = 0; i < envLines.length; i++) {
        var line = String(envLines[i]).replace(/^\s+|\s+$/g, "")
        if (line === "" || line.charAt(0) === "#") continue
        var eq = line.indexOf("=")
        if (eq === -1) continue
        var key = line.substring(0, eq).replace(/^\s+|\s+$/g, "")
        var val = line.substring(eq + 1).replace(/^\s+|\s+$/g, "").replace(/^"(.*)"$/, "$1")
        if (key === "LLAMA_HOST") {
          host = val !== "" ? val : "127.0.0.1"
        } else if (key === "LLAMA_PORT") {
          if (val !== "") {
            if (/^[0-9]+$/.test(val)) {
              var pn = parseInt(val, 10)
              if (pn >= 1 && pn <= 65535) port = pn
              else violations.push("LLAMA_PORT out of range (1-65535)")
            } else {
              violations.push("LLAMA_PORT is not an integer")
            }
          }
        } else if (key === "LLAMA_API_KEY") {
          apiKey = val
        } else if (key === "LLAMA_EXTRA_ARGS") {
          if (!validateExtraArgs(val)) violations.push("LLAMA_EXTRA_ARGS contains unsafe characters")
        } else if (key === "LLAMA_MODELS_PRESET") {
          if (!isValidPresetPath(val)) violations.push("LLAMA_MODELS_PRESET is not a safe absolute path")
        }
      }
    } else {
      var obj = null
      try {
        obj = JSON.parse(body)
      } catch(e) {
        violations.push("config is not valid JSON")
      }
      if (obj !== null) {
        if (typeof obj["host"] === "string") {
          host = obj["host"] !== "" ? obj["host"] : "127.0.0.1"
        } else {
          violations.push("host must be a string")
        }
        if (typeof obj["port"] === "number" && Number.isInteger(obj["port"])) {
          if (obj["port"] >= 1 && obj["port"] <= 65535) port = obj["port"]
          else violations.push("port out of range (1-65535)")
        } else {
          violations.push("port must be an integer")
        }
        if (typeof obj["api-key"] === "string") {
          apiKey = obj["api-key"]
        } else {
          violations.push("api-key must be a string")
        }
      }
    }
    // Common validation across both backends.
    if (port === -1) port = 0  // never set by the config file: use the backend default port
    if (!(isValidLoopbackHost(host) || isValidRemoteHost(host))) {
      violations.push("host is not a valid loopback or remote host")
    }
    if (port !== 0 && !isValidPort(port)) violations.push("port is out of range (1-65535)")
    if (!isValidApiKey(apiKey)) violations.push("api key contains unsafe characters")

    if (violations.length > 0) {
      configHost = "127.0.0.1"
      configPort = 0
      configApiKey = ""
      configValid = false
      configWarning = truncate("Invalid " + root.backendDisplayName + " config: " + violations.join("; ") + ".", 256)
      return
    }
    configHost = host
    configPort = port
    configApiKey = apiKey
    configValid = true
    configWarning = ""
  }

   // Startup config probe: reports HAS/NO as the first output line and, if so,
   // the file contents after it. It never creates or overwrites the file (that
   // is user-initiated via createConfigFile()); its only write is an idempotent
   // 0600 hardening of an existing regular file, which may hold an API key.
   function ensureAndReadConfig() {
    launch(configProcess, configWatchdog)
  }

  function isCloudModel(name) {
    var n = String(name || "").toLowerCase()
    return n.indexOf(":cloud") !== -1 || n.indexOf(":server") !== -1
  }

  // ── Processes ──────────────────────────────────────────────────────
  //
  // Every command is wrapped in `timeout -k 2 N` which runs the command
  // in its own process group and kills the entire group on expiry,
  // preventing orphaned children.  Inside timeout, commands are further
  // wrapped in `bash -c "set -o pipefail; CMD 2>&1 | head -c N"` to bound
  // output at the OS pipe level before SplitParser sees it.
  //
  // With pipefail, SIGPIPE from head truncation yields exit 141.
  // timeout expiry yields exit 124 (TERM) or 137 (KILL).
  // All non-zero exits are discarded by the exitCode === 0 guard.

  Process {
    id: whichProcess
    running: false
    // which has no children and no stdout handler — timeout not needed
    command: ["which", root.backendBinary]
    onExited: function(exitCode) {
      whichWatchdog.stop()
      installed = exitCode === 0
      if (installed) refresh()
      else {
        hasService = false
        running = false
        models = []
        runningModels = []
        apiReachable = false
      }
    }
  }

  Process {
    id: checkServiceProcess
    running: false
    command: ["timeout", "-k", "2", "" + processTimeoutSec,
              "bash", "-c", root.checkServiceScript, "dash",
              root.backend === "llama.cpp" ? "--user" : "",
              root.backendService, "" + root.capCheck]
    stdout: SplitParser { onRead: function(line) { root._onCheckLine(line) } }
    onExited: function(exitCode) {
      checkServiceWatchdog.stop()
      if (exitCode === 0) _parseCheckBuffer()
      else { _checkBuffer = ""; hasService = false }
    }
  }

  Process {
    id: serviceProcess
    running: false
    command: ["timeout", "-k", "2", "" + processTimeoutSec,
              "bash", "-c", root.serviceScript, "dash",
              root.backend === "llama.cpp" ? "--user" : "",
              root.backendService.replace(".service", ""), "" + root.capService]
    stdout: SplitParser { onRead: function(line) { root._onServiceLine(line) } }
    onExited: function(exitCode) {
      serviceWatchdog.stop()
      if (exitCode === 0) {
        _parseServiceBuffer()
      } else {
        _serviceBuffer = ""
        running = false
        activeSince = ""
        apiReachable = false
      }
    }
  }

  // API health check. Constant script; the endpoint URL and output cap are
  // positional args, the key travels via the process environment only.
  Process {
    id: apiHealthProcess
    running: false
    command: ["timeout", "-k", "2", "" + processTimeoutSec,
              "bash", "-c", root.backend === "llama.cpp" ? root.healthScriptLlama : root.healthScriptOllama,
              "dash", root.effectiveHealthEndpoint, "" + root.capApi]
    environment: ({ "DASH_API_KEY": root.configApiKey })
    stdout: SplitParser { onRead: function(line) { root._onApiLine(line) } }
    onExited: function(exitCode) {
      apiHealthWatchdog.stop()
      if (exitCode === 0) {
        _parseApiBuffer()
      } else {
        _apiBuffer = ""
        apiReachable = false
        apiLatencyMs = -1
      }
    }
  }

  Process {
    id: listProcess
    running: false
    command: root.backend === "llama.cpp"
      ? ["timeout", "-k", "2", "" + processTimeoutSec,
         "bash", "-c", root.listScriptLlama, "dash",
         root.effectiveListEndpoint, "" + root.capList]
      : ["timeout", "-k", "2", "" + processTimeoutSec,
         "bash", "-c", root.listScriptOllama, "dash",
         "" + root.capList]
    environment: ({ "DASH_API_KEY": root.configApiKey })
    stdout: SplitParser { onRead: function(line) { root.backend === "llama.cpp" ? root._onJsonLine(line) : root._onListLine(line) } }
    onExited: function(exitCode) {
      listWatchdog.stop()
      if (exitCode === 0) {
        if (root.backend === "llama.cpp") _finishJsonModels()
        else _finishList()
      } else {
        _listModels = []; _listHeaderSeen = false
        if (root.backend === "llama.cpp") runningModels = []
      }
    }
  }

  Process {
    id: psProcess
    running: false
    command: root.backend === "llama.cpp"
      ? ["timeout", "-k", "2", "" + processTimeoutSec,
         "bash", "-c", root.psScriptLlama, "dash", "" + root.capPs]
      : ["timeout", "-k", "2", "" + processTimeoutSec,
         "bash", "-c", root.psScriptOllama, "dash", "" + root.capPs]
    stdout: SplitParser { onRead: function(line) { root.backend === "llama.cpp" ? root._onPgrepLine(line) : root._onPsLine(line) } }
    onExited: function(exitCode) {
      psWatchdog.stop()
      if (exitCode === 0) {
        if (root.backend === "llama.cpp") _finishPgrep()
        else _finishPs()
      } else {
        _psModels = []; _psHeaderSeen = false
      }
    }
  }

  Process {
    id: versionProcess
    running: false
    command: ["timeout", "-k", "2", "" + processTimeoutSec,
              "bash", "-c", root.versionScript, "dash",
              root.backendBinary, "" + root.capVersion]
    stdout: SplitParser { onRead: function(line) { root._onVersionLine(line) } }
    onExited: function(exitCode) {
      versionWatchdog.stop()
    }
  }

  // Config file: read-only probe. Emits a single HAS/NO marker line before
  // the file contents, so hasConfig is set even when the JSON is unparseable.
  // The pipeline runs without pipefail so `head -c` always exits 0 — a config
  // larger than capConfig truncates instead of being discarded.
  Process {
    id: configProcess
    running: false
    command: ["timeout", "-k", "2", "" + processTimeoutSec,
              "bash", "-c", root.configScript, "dash",
              root.configPath, "" + root.capConfig]
    stdout: SplitParser { onRead: function(line) { root._onConfigLine(line) } }
    onExited: function(exitCode) {
      configWatchdog.stop()
      _parseConfigBuffer()
    }
  }

  // llama.cpp user service → current DRAM working set (bytes). Sums anon+shmem
  // from the service cgroup's memory.stat: committed, non-reclaimable process
  // memory. MemoryCurrent is avoided because it also counts reclaimable
  // file/page cache (the mmap'd GGUF), which inflates the footprint and
  // double-counts weight pages already held as anon or on the GPU.
  Process {
    id: serviceMemoryProcess
    running: false
    command: ["timeout", "-k", "2", "" + processTimeoutSec,
              "bash", "-c", root.serviceMemoryScript, "dash",
              root.backendService.replace(".service", ""), "" + root.capServiceMemory]
    stdout: SplitParser { onRead: function(line) { root._onServiceMemoryLine(line) } }
    onExited: function(exitCode) {
      serviceMemoryWatchdog.stop()
      if (exitCode === 0) _finishServiceMemory()
      else { _serviceMemoryBuffer = ""; serviceMemoryBytes = -1; _deriveServiceTotal() }
    }
  }

  // llama.cpp user service → current per-service VRAM footprint (bytes).
  // Vendor auto-detected: nvidia-smi on NVIDIA, rocm-smi on AMD. The preset
  // server forks per-model workers that own the CUDA contexts, so GPU memory
  // is summed over every PID in the service cgroup (MainPID as fallback seed),
  // not just MainPID. When the model has no GPU context (idle/unloaded) or no
  // supported GPU tool exists, the query emits nothing and serviceVramBytes
  // stays -1 → CPU-only/unknown fallback.
  Process {
    id: serviceVramProcess
    running: false
    command: ["timeout", "-k", "2", "" + processTimeoutSec,
              "bash", "-c", root.serviceVramScript, "dash",
              root.backendService.replace(".service", ""), "" + root.capServiceVram]
    stdout: SplitParser { onRead: function(line) { root._onServiceVramLine(line) } }
    onExited: function(exitCode) {
      serviceVramWatchdog.stop()
      if (exitCode === 0) _finishServiceVram()
      else { _serviceVramBuffer = ""; serviceVramBytes = -1; _deriveServiceTotal() }
    }
  }

  // ── Start/stop/create stderr capture ──────────────────────────────
  property string _startBuffer: ""
  property string _stopBuffer: ""
  property string _createBuffer: ""

  function _onStartLine(line) {
    var s = String(line || "")
    if (_startBuffer.length + s.length + 1 <= capAction) _startBuffer += s + "\n"
  }

  function _onStopLine(line) {
    var s = String(line || "")
    if (_stopBuffer.length + s.length + 1 <= capAction) _stopBuffer += s + "\n"
  }

  function _onCreateLine(line) {
    var s = String(line || "")
    if (_createBuffer.length + s.length + 1 <= capAction) _createBuffer += s + "\n"
  }

  Process {
    id: startProcess
    running: false
    command: {
      if (root.backend === "llama.cpp") {
        // Two-phase provisioning help (all constants; see provisionLlamaScript
        // for the exit-code contract): dry-run with consent=0, then the panel
        // offers "Confirm update & start" which relaunches with consent=1.
        // Env file, unit write and start happen inside the one provisioner so
        // the rollback guarantee covers all three.
        return ["timeout", "-k", "2", "" + root.startTimeoutSec, "bash", "-c", root.provisionLlamaScript,
                "dash", root.configPath, root.userUnitDir, root.backendBinary,
                root._provisionConsented ? "1" : "0", "" + root.capAction]
      }
      return ["timeout", "-k", "2", "" + root.startTimeoutSec, "bash", "-c", root.pkStartScript,
              "dash", root.backendService, "" + root.capAction]
    }
    stdout: SplitParser { onRead: function(line) { root._onStartLine(line) } }
    onExited: function(exitCode) {
      startActionWatchdog.stop()
      busy = false
      actionLabel = ""
      if (root.backend === "llama.cpp") {
        if (exitCode === 0 || exitCode === 4) {
          // 4 = nothing to do (create-only race). Env + unit are in place.
          lastError = ""
          hasConfig = true
          launch(configProcess, configWatchdog)
        } else if (exitCode === 64) {
          // Dry-run: the installed unit differs from the generated one, so
          // nothing was written (or changed) and no start happened. The env
          // file was still created if it was missing. Ask for consent.
          lastError = ""
          hasConfig = true
          pendingProvision = true
          provisionTimer.restart()
          launch(configProcess, configWatchdog)
        } else {
          lastError = _provisionError(exitCode, _startBuffer)
        }
      } else {
        if (exitCode !== 0) lastError = _actionError(_startBuffer, "start")
        else lastError = ""
      }
      _provisionConsented = false
      _startBuffer = ""
      startDelay.restart()
    }
  }

  Process {
    id: stopProcess
    running: false
    command: ["timeout", "-k", "2", "" + processTimeoutSec,
              "bash", "-c", root.backend === "llama.cpp" ? root.userStopScript : root.pkStopScript,
              "dash", root.backendService, "" + root.capAction]
    stdout: SplitParser { onRead: function(line) { root._onStopLine(line) } }
    onExited: function(exitCode) {
      stopActionWatchdog.stop()
      busy = false
      actionLabel = ""
      if (exitCode !== 0) lastError = _actionError(_stopBuffer, "stop")
      else lastError = ""
      _stopBuffer = ""
      refresh()
    }
  }

  // Default config file creation. Both backends use the create-only,
  // symlink-refusing, atomic, 0600 constant writer (createConfigScript /
  // createEnvScript). No pkexec anywhere: the config lives in the user's own
  // plugin directory, so no privilege (and no password prompt) is needed.
  // Exit codes: 0 or 4 (already exists) = done; 55/5/6 = unsafe/failed write.
  Process {
    id: createConfigProcess
    running: false
    command: {
      var args = ["timeout", "-k", "2", "" + startTimeoutSec,
                  "bash", "-c", root.backend === "llama.cpp" ? root.createEnvScript : root.createConfigScript,
                  "dash", root.configPath]
      if (root.backend === "ollama") args.push(root.defaultConfigJson)
      return args
    }
    stdout: SplitParser { onRead: function(line) { root._onCreateLine(line) } }
    onExited: function(exitCode) {
      createConfigWatchdog.stop()
      busy = false
      actionLabel = ""
      if (exitCode === 0 || exitCode === 4) {
        // 4 = target already existed (create-only race); still a done state.
        lastError = ""
        hasConfig = true
        launch(configProcess, configWatchdog)
      } else if (exitCode === 55) {
        lastError = "Cannot create " + root.backendDisplayName + " config: refusing to write (parent path is a symlink)."
      } else if (exitCode === 5 || exitCode === 6) {
        lastError = "Cannot create " + root.backendDisplayName + " config: temporary file write failed."
      } else {
        lastError = _actionError(_createBuffer, "create")
      }
      _createBuffer = ""
    }
  }

  // ── Watchdog timers (backup layer) ────────────────────────────────
  // These fire slightly after the `timeout` deadline so timeout (which
  // handles the process group) is the primary killer.  If timeout
  // itself hangs, the watchdog falls back to QProcess::terminate().

  Timer {
    id: whichWatchdog
    interval: watchdogMs
    repeat: false
    onTriggered: if (whichProcess.running) whichProcess.running = false
  }

  Timer {
    id: checkServiceWatchdog
    interval: watchdogMs
    repeat: false
    onTriggered: reap(checkServiceProcess, checkServiceWatchdog)
  }

  Timer {
    id: serviceWatchdog
    interval: watchdogMs
    repeat: false
    onTriggered: reap(serviceProcess, serviceWatchdog)
  }

  Timer {
    id: apiHealthWatchdog
    interval: watchdogMs
    repeat: false
    onTriggered: reap(apiHealthProcess, apiHealthWatchdog)
  }

  Timer {
    id: listWatchdog
    interval: watchdogMs
    repeat: false
    onTriggered: reap(listProcess, listWatchdog)
  }

  Timer {
    id: psWatchdog
    interval: watchdogMs
    repeat: false
    onTriggered: reap(psProcess, psWatchdog)
  }

  Timer {
    id: versionWatchdog
    interval: watchdogMs
    repeat: false
    onTriggered: reap(versionProcess, versionWatchdog)
  }

  Timer {
    id: configWatchdog
    interval: watchdogMs
    repeat: false
    onTriggered: reap(configProcess, configWatchdog)
  }

  Timer {
    id: serviceMemoryWatchdog
    interval: watchdogMs
    repeat: false
    onTriggered: reap(serviceMemoryProcess, serviceMemoryWatchdog)
  }

  Timer {
    id: serviceVramWatchdog
    interval: watchdogMs
    repeat: false
    onTriggered: reap(serviceVramProcess, serviceVramWatchdog)
  }

  Timer {
    id: startActionWatchdog
    interval: startWatchdogMs
    repeat: false
    onTriggered: if (startProcess.running) startProcess.running = false
  }

  Timer {
    id: stopActionWatchdog
    interval: watchdogMs
    repeat: false
    onTriggered: if (stopProcess.running) stopProcess.running = false
  }

  Timer {
    id: createConfigWatchdog
    interval: startWatchdogMs
    repeat: false
    onTriggered: if (createConfigProcess.running) createConfigProcess.running = false
  }

  // Phase 4: auto-cancel the consent prompt after ~20 s (idling is safer than
  // leaving a state that can only be dismissed manually).
  Timer {
    id: provisionTimer
    interval: 20000
    repeat: false
    onTriggered: root.pendingProvision = false
  }

  // ── Refresh timers ─────────────────────────────────────────────────

  Timer {
    id: refreshTimer
    interval: refreshIntervalSec * 1000
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: refresh()
  }

  Timer {
    id: startDelay
    interval: 1500
    repeat: false
    onTriggered: refresh()
  }

  Component.onCompleted: {
    whichProcess.running = true
    whichWatchdog.restart()
    ensureAndReadConfig()
  }
}
