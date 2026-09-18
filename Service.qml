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
  readonly property string llamaEnvDefault: '# llama.cpp server configuration\n# Managed by local-ai-dashboard. Edit values, then start/restart from the panel.\nLLAMA_HOST=127.0.0.1\nLLAMA_PORT=8080\nLLAMA_API_KEY=\nLLAMA_MODELS_PRESET="$HOME/.config/llama.cpp/models.ini"\nLLAMA_MODELS_MAX=1\nLLAMA_EXTRA_ARGS=\n# Auto-unload the loaded model after this many seconds without a request (0 = disabled).\nLLAMA_UNLOAD_INACTIVITY_SEC=0\n'

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

  // Per-model unload (issue #6): POST /models/unload with body {"model":<id>}
  // (the key is `model`, not `name`). $1 = model id, $2 = endpoint, $3 = cap.
  // The id arrives from /v1/models JSON: it is charset-validated in
  // unloadModel() AND stripped of quotes/backslashes/control bytes here before
  // JSON encoding — user data is never concatenated into this script.
  // curl -w '%{http_code}' appends the status code after the response body.
  readonly property string unloadScriptLlama: curlFnLlama + `
set -o pipefail;
safe=$(printf '%s' "$1" | tr -d '"\\\\' | tr -d '\n\r\t');
body=$(printf '{"model":"%s"}' "$safe");
hdr -s -w '%{http_code}' -X POST -H 'Content-Type: application/json' --data "$body" --connect-timeout 3 --max-time 5 "$2" 2>&1 | head -c "$3"`

  // Idle source (issue #6): GET /slots?model=<id> → per-slot is_processing +
  // id_task. $1 = /slots base, $2 = model id (charset-validated before launch),
  // $3 = cap.
  readonly property string slotsScriptLlama: curlFnLlama + `
set -o pipefail;
hdr -s "$1?model=$2" 2>&1 | head -c "$3"`

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

   // Bounded no-load GGUF header read (llama.cpp). $1 = .gguf path, $2 = cap.
   // Reads ONLY the first 16 KiB (the metadata KV section precedes the tensor
   // table) and pulls the arch id plus the u32 keys needed for totalLayers +
   // the KV-cache estimate. No weights are read, nothing is mmap'd past the
   // prefix, and no model is loaded. Emits a first-line marker (GGUF-OK /
   // GGUF-NO) then `key=value` lines. Refuses symlinks / special files.
   readonly property string ggufScript: `
f="$1";
if [ ! -e "$f" ] || [ -L "$f" ] || [ ! -f "$f" ]; then echo GGUF-NO; exit 0; fi;
sz=$(stat -c %s -- "$f" 2>/dev/null);
head -c 16384 -- "$f" | od -A n -t x1 -v | awk -v SZ="$sz" '
BEGIN { for (i = 0; i < 256; i++) HEXVAL[sprintf("%02x", i)] = i; for (i = 32; i < 127; i++) { c = sprintf("%c", i); ORD[c] = i; HEXC[sprintf("%02x", i)] = c } }
function hexof(s,  n, i, out) { out = ""; for (i = 1; i <= length(s); i++) out = out sprintf("%02x", ORD[substr(s, i, 1)]); return out }
function unhex(h,  n, i, out) { out = ""; for (i = 1; i + 1 <= length(h); i += 2) out = out HEXC[substr(h, i, 2)]; return out }
function byteat(off) { return HEXVAL[substr(H, off * 2 + 1, 2)] }
function u32le(off) { return byteat(off) + byteat(off + 1) * 256 + byteat(off + 2) * 65536 + byteat(off + 3) * 16777216 }
function u64lehex(v,  i, out) { out = ""; for (i = 0; i < 8; i++) out = out sprintf("%02x", int(v / (256 ^ i)) % 256); return out }
{ buf = buf $0 }
END {
  gsub(/[ \t\r]/, "", buf)
  H = buf
  if (substr(H, 1, 8) != "47475546") { print "GGUF-NO"; exit }
  pa = index(H, u64lehex(20) hexof("general.architecture"))
  if (pa == 0) { print "GGUF-NO"; exit }
  pb = int((pa - 1) / 2)
  if (u32le(pb + 28) != 8) { print "GGUF-NO"; exit }
  klen = u32le(pb + 32)
  if (klen < 1 || klen > 64) { print "GGUF-NO"; exit }
  arch = unhex(substr(H, (pb + 40) * 2 + 1, klen * 2))
  print "GGUF-OK"
  print "arch=" arch
  n = 6
  KS[0] = arch ".block_count";              NM[0] = "block_count"
  KS[1] = arch ".attention.head_count";    NM[1] = "head_count"
  KS[2] = arch ".attention.head_count_kv"; NM[2] = "head_count_kv"
  KS[3] = arch ".embedding_length";        NM[3] = "embedding_length"
  KS[4] = arch ".nextn_predict_layers";    NM[4] = "nextn_predict_layers"
  KS[5] = arch ".full_attention_interval"; NM[5] = "full_attention_interval"
  for (i = 0; i < n; i++) {
    p = index(H, u64lehex(length(KS[i])) hexof(KS[i]))
    if (p == 0) continue
    kb = int((p - 1) / 2) + 8
    if (u32le(kb + length(KS[i])) != 4) continue
    print NM[i] "=" u32le(kb + length(KS[i]) + 4)
  }
  if (SZ ~ /^[0-9]+$/) print "size=" SZ
}' | head -c $2`

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

   // ── Per-model unload + auto-unload (llama.cpp, issue #6) ─────────
   // Parsed from LLAMA_UNLOAD_INACTIVITY_SEC in the env file; 0 = disabled
   // (the default, and the value when the key is absent on older env files).
   property int unloadInactivitySec: 0
   // Model id for the unload currently in flight (single-flight; "" = none).
   property string _unloadId: ""
   // Idle tracking: the loaded model id being polled, the last seen slot
   // signature ("processing:idTask") and the wall-clock ms of the most recent
   // observed activity (-1 = no baseline).
   property string _slotsModelId: ""
   property string _lastSig: ""
   property double _lastActivityMs: -1

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
    readonly property int capGguf: 512          // GGUF header marker + arch + 6 key=value lines
   readonly property int capSlots: 8192        // /slots?model=<id> first-slot state
   readonly property int capUnload: 512        // unload response body + http_code

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

  function formatMB(bytes) {
    var b = parseInt(String(bytes), 10)
    if (!isFinite(b) || b <= 0) return "\u2014"
    var mb = b / (1024 * 1024)
    if (mb >= 1024) return formatGB(b)
    return Math.round(mb) + " MB"
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

   // ── llama.cpp running-model derivation helpers (pure, no processes) ──
   // All of these take plain values and return plain numbers/arrays so they
   // are unit-testable in isolation. Unknown / not-applicable → -1 (the display
   // layer renders -1 as "—").

   // Parse llama.cpp's resolved CLI arg array (/v1/models[].status.args) for the
   // few flags we need. Tokens are matched EXACTLY so `--model` never collides
   // with `--models-preset`/`--model-draft`, and `--n-gpu-layers` never with
   // `--n-gpu-layers-draft`. Both `flag value` and `flag=value` forms are handled.
   function _parseLlamaArgs(args) {
      var out = { model: "", ngl: "", draftPath: "", nglDraft: "", specType: "", cacheK: "", cacheV: "", noKvOffload: false }
     if (!args || typeof args.length !== "number") return out
     for (var i = 0; i < args.length; i++) {
       var a = String(args[i] == null ? "" : args[i])
       var eq = a.indexOf("=")
       var flag = eq !== -1 ? a.substring(0, eq) : a
       var inlineVal = eq !== -1 ? a.substring(eq + 1) : null
       function next() { return inlineVal !== null ? inlineVal : String(args[i + 1] == null ? "" : args[i + 1]) }
       function consume() { if (inlineVal === null) i++ }
        if (flag === "--model" || flag === "-m") { out.model = next(); consume() }
        else if (flag === "--model-draft" || flag === "-md") { out.draftPath = next(); consume() }
        else if (flag === "--n-gpu-layers" || flag === "-ngl") { out.ngl = next(); consume() }
        else if (flag === "--n-gpu-layers-draft" || flag === "--gpu-layers-draft" || flag === "-ngld" || flag === "--spec-draft-ngl") { out.nglDraft = next(); consume() }
        else if (flag === "--cache-type-k") { out.cacheK = next(); consume() }
        else if (flag === "--cache-type-v") { out.cacheV = next(); consume() }
        else if (flag === "--spec-type") { out.specType = next(); consume() }
        else if (flag === "--no-kv-offload") { out.noKvOffload = true }
     }
     return out
   }

    // Main/MTP GPU/CPU layer split from the resolved --n-gpu-layers token, the
    // total block_count, and the MTP layer count. MTP layers sit on TOP of the
    // stack, so N offloaded layers are counted from the bottom: "all" → every
    // layer on GPU; integer N → the first N layers (main before MTP); anything
    // else (missing flag, auto, non-numeric, unknown total) → nulls (the display
    // layer renders them as "—").
    function _mtpSplit(nglRaw, total, mtp) {
      var out = { mainGpu: null, mainCpu: null, mtpGpu: null, mtpCpu: null }
      if (!isFinite(total) || total <= 0) return out
      var t = Math.round(total)
      var m = (isFinite(mtp) && mtp > 0) ? Math.min(Math.round(mtp), t) : 0
      var s = String(nglRaw == null ? "" : nglRaw).trim()
      if (s === "") return out
      var n = 0
      if (s === "all") n = t
      else {
        n = parseInt(s, 10)
        if (!isFinite(n)) return out
        if (n < 0) n = 0
        if (n > t) n = t
      }
      var main = t - m
      var mainGpu = Math.min(n, main)
      var mtpGpu = Math.max(0, Math.min(m, n - main))
      out.mainGpu = mainGpu
      out.mainCpu = main - mainGpu
      out.mtpGpu = mtpGpu
      out.mtpCpu = m - mtpGpu
      return out
    }

   function _percentLayersOnGPU(gpu, total) {
     if (!isFinite(total) || total <= 0 || !isFinite(gpu) || gpu < 0) return -1
     return Math.round(gpu / total * 100)
   }

   function _percentLayersOnCPU(cpu, total) {
     if (!isFinite(total) || total <= 0 || !isFinite(cpu) || cpu < 0) return -1
     return Math.round(cpu / total * 100)
   }

   // Bits-per-element for a KV-cache dtype. Empty (no --cache-type-k/v flag) is
   // llama.cpp's f16 default. Unknown quant → -1 so the estimate falls back to "—".
   function _kvDtypeBits(t) {
     var s = String(t == null ? "" : t).trim()
     if (s === "") return 16
     switch (s) {
       case "f32": return 32
       case "f16": case "bf16": return 16
       case "q8_0": return 8.5
       case "q6_k": return 6.5625
       case "q5_1": return 5.5
       case "q5_0": return 5.25
       case "q4_1": case "q4_0": return 4.5
       default: return -1
     }
   }

    // KV-cache byte estimate (upper bound). layers = the full-attention
    // (KV-holding) layer count — round(mainLayers / full_attention_interval) for
    // hybrid models, falling back to the main/total block count — NOT raw
    // block_count; ctx = context length, headKV = KV heads,
    // headDim = n_embd / query heads, kBits/vBits per element.
    // Any unknown input → -1 (display renders "—").
   function _kvEstimateBytes(layers, ctx, headKV, headDim, kBits, vBits) {
     if (!isFinite(layers) || layers <= 0) return -1
     if (!isFinite(ctx) || ctx <= 0) return -1
     if (!isFinite(headKV) || headKV <= 0) return -1
     if (!isFinite(headDim) || headDim <= 0) return -1
     if (!isFinite(kBits) || kBits < 0 || !isFinite(vBits) || vBits < 0) return -1
      var bytes = layers * ctx * headKV * headDim * (kBits + vBits) / 8
      if (!isFinite(bytes) || bytes <= 0) return -1
      return Math.round(bytes)
    }

   // GPU/CPU weight bytes for display. Prefer the exact layer-ratio split when the
   // offload count is known; otherwise fall back to the measured per-device footprint
   // (an estimate — measured VRAM/DRAM can include KV cache). Unknown → -1 ("—").
   function _weightBytes(sizeBytes, gpu, cpu, total, vramBytes, memBytes) {
     var out = [-1, -1]
     if (sizeBytes > 0 && total > 0 && gpu >= 0 && cpu >= 0) {
       out[0] = Math.round(sizeBytes * gpu / total)
       out[1] = Math.round(sizeBytes * cpu / total)
     } else {
       if (vramBytes >= 0) out[0] = vramBytes   // ≈ measured GPU footprint
       if (memBytes  >= 0) out[1] = memBytes    // ≈ measured DRAM working set
     }
     return out
   }

    // Resolve GGUF-dependent fields for each entry, returning a NEW array so the
    // view re-renders. Cached headers resolve synchronously; misses queue a bounded
    // read (the async _applyGgufToRunning republishes when it lands). The base
    // model resolves first, then the draft (--model-draft) model if present.
    function _resolveRunningEntries(entries) {
      var out = entries.slice()
      for (var j = 0; j < out.length; j++) {
        var e = out[j]
        if (!e || e.modelPath === "") continue
        var cachedGguf = _ggufCache[e.modelPath]
        if (cachedGguf !== undefined) _applyGguf(e, cachedGguf)
        else _queueGguf(e.modelPath)
        if (e.draftPath !== "") {
          var cachedDraft = _ggufCache[e.draftPath]
          if (cachedDraft !== undefined) _applyGgufDraft(e, cachedDraft)
          else _queueGguf(e.draftPath)
        }
      }
      return out
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
      _resetIdleTracking()
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
      _resetIdleTracking()
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

  // ── Per-model unload (llama.cpp router, issue #6) ──────────────────
  // Releases only the named model via POST /models/unload; the router process
  // stays up. The id comes from /v1/models JSON (external data): it is
  // validated to a safe charset here and stripped again inside the constant
  // script before JSON encoding — never concatenated into the script itself.
  function unloadModel(id) {
    if (backend !== "llama.cpp") return false
    if (busy || !running || !endpointOk || unloadProcess.running) return false
    var m = String(id == null ? "" : id).trim()
    if (m === "" || !/^[A-Za-z0-9._\-/]+$/.test(m)) return false
    if (!_isModelLoaded(m)) return false
    _unloadId = m
    launch(unloadProcess, unloadWatchdog)
    return true
  }

  function _isModelLoaded(id) {
    var arr = runningModels || []
    for (var i = 0; i < arr.length; i++) {
      if (arr[i] && String(arr[i].id || "") === id) return true
    }
    return false
  }

  // ── Idle tracking (issue #6 auto-unload source) ────────────────────
  // `firstLoadedId` is the id of the first model /v1/models reports loaded
  // ("" = none). The inactivity baseline starts at first observation of a
  // model and only advances on observed activity (is_processing true, or an
  // id_task change between polls) — never backwards. Disabled (0) or nothing
  // loaded → tracking is reset and no /slots poll runs.
  function _syncIdleTracking(firstLoadedId) {
    var id = String(firstLoadedId == null ? "" : firstLoadedId)
    if (id !== "" && !/^[A-Za-z0-9._\-/]+$/.test(id)) id = ""
    if (unloadInactivitySec <= 0 || id === "") {
      _resetIdleTracking()
      return
    }
    if (id !== _slotsModelId) {
      _slotsModelId = id
      _lastSig = ""
      _lastActivityMs = Date.now()
    }
    if (!slotsProcess.running) launch(slotsProcess, slotsWatchdog)
  }

  function _resetIdleTracking() {
    _slotsModelId = ""
    _lastSig = ""
    _lastActivityMs = -1
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
      _resetIdleTracking()
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
          var meta = m.meta || {}
          var sizeBytes = parseInt(meta.size, 10)
          if (!isFinite(sizeBytes) || sizeBytes < 0) sizeBytes = 0
          // context: b10729 exposes no status.context; the authoritative value
          // is meta.n_ctx (loaded only). Keep a `context` string for compat.
          var ctxLen = parseInt(meta.n_ctx, 10)
          if (!isFinite(ctxLen) || ctxLen < 0) ctxLen = -1
          var parsed = _parseLlamaArgs(m.status.args)
          _psModels.push({
            name: truncate(pathParts[pathParts.length - 1] || "Unknown model", 128),
            id: truncate(m.id || "", 64),
            size: sizeBytes > 0 ? root.formatGB(sizeBytes) : "",
            sizeBytes: sizeBytes,
            processor: truncate(m.status.processor || m.status.backend || "CPU", 32),
            context: ctxLen > 0 ? String(ctxLen) : "",
            contextLen: ctxLen,
            modelPath: parsed.model,
            ngl: parsed.ngl,
            draftPath: parsed.draftPath,
            nglDraft: parsed.nglDraft,
            specType: parsed.specType,
            cacheK: parsed.cacheK,
            cacheV: parsed.cacheV,
            noKvOffload: parsed.noKvOffload,
            totalLayers: -1,
            mainLayers: -1,
            mtpLayers: 0,
            mtpSizeBytes: -1,
            draftSizeBytes: -1,
            mainGpu: null,
            mainCpu: null,
            mtpGpu: 0,
            mtpCpu: 0,
            kvCacheBytes: -1,
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
    runningModels = _resolveRunningEntries(_psModels)
    var firstLoadedId = _psModels.length > 0 ? String(_psModels[0].id || "") : ""
    _psModels = []
    _listHeaderSeen = false
    _syncIdleTracking(firstLoadedId)
  }

  // ── GGUF header read (llama.cpp): totalLayers + KV-cache inputs ──────
  // Bounded no-load read of the model file's own metadata. Results are cached
  // by path so a running model is re-resolved synchronously on every later
  // refresh (no re-read). Unknown/unreadable → the entry keeps -1 ("—").

  property var _ggufCache: ({})   // path -> {bc, hc, hckv, embd, npl, fai, sz}
  property string _ggufPath: ""   // path currently being read (single-flight)
  property string _ggufBuffer: ""
  readonly property int _ggufBufferMax: 512

  function _onGgufLine(line) {
    var s = String(line || "")
    if (_ggufBuffer.length + s.length + 1 <= _ggufBufferMax) _ggufBuffer += s + "\n"
  }

  // Start a header read for `path` (single-flight; a read already in flight is
  // left alone and the caller retries on the next refresh once it's cached).
  function _queueGguf(path) {
    if (path === "" || ggufProcess.running) return
    if (_ggufCache[path] !== undefined) return
    _ggufPath = path
    _ggufBuffer = ""
    launch(ggufProcess, ggufWatchdog)
  }

  // Fold the parsed BASE-model header into one running-model entry: layer split
  // + KV est. block_count includes any built-in MTP layers (nextn_predict_
  // layers); the main stack is what --n-gpu-layers / KV accounting operate on.
  // With a separate draft (--model-draft) the MTP fields are owned by
  // _applyGgufDraft and left untouched here.
  function _applyGguf(entry, g) {
    var total = (g.bc > 0) ? g.bc : -1
    entry.totalLayers = total
    var npl = (isFinite(g.npl) && g.npl > 0) ? Math.round(g.npl) : 0
    if (entry.draftPath !== "") {
      // Separate draft: the base stack is plain main layers; the MTP count,
      // size, and placement come from the draft header.
      entry.mainLayers = (total > 0) ? Math.max(0, total - npl) : -1
      var splitMain = _mtpSplit(entry.ngl, total, 0)
      entry.mainGpu = splitMain.mainGpu
      entry.mainCpu = splitMain.mainCpu
    } else {
      var mtpLayers = (total > 0 && npl > 0) ? Math.min(npl, total) : 0
      var mainLayers = (total > 0) ? Math.max(0, total - mtpLayers) : -1
      entry.mtpLayers = mtpLayers
      entry.mainLayers = mainLayers
      var sb = (entry.sizeBytes > 0) ? entry.sizeBytes : -1
      entry.mtpSizeBytes = (mtpLayers > 0 && sb > 0 && total > 0)
        ? Math.round(sb / total * mtpLayers) : -1
      var splitAll = _mtpSplit(entry.ngl, total, mtpLayers)
      entry.mainGpu = splitAll.mainGpu
      entry.mainCpu = splitAll.mainCpu
      entry.mtpGpu = splitAll.mtpGpu
      entry.mtpCpu = splitAll.mtpCpu
    }
    var ctx = (isFinite(entry.contextLen) && entry.contextLen > 0) ? entry.contextLen : -1
    var hc = (g.hc > 0) ? g.hc : -1
    // MHA models omit head_count_kv → KV heads == query heads.
    var hckv = (g.hckv > 0) ? g.hckv : ((hc > 0) ? hc : -1)
    var embd = (g.embd > 0) ? g.embd : -1
    var headDim = (hc > 0 && embd > 0) ? embd / hc : -1
    // Only full-attention layers store context-scaling KV (hybrid models keep
    // a fixed recurrent state in the rest); no interval key → all main layers.
    var fai = (isFinite(g.fai) && g.fai > 1) ? Math.round(g.fai) : -1
    var kvLayers = entry.mainLayers
    if (fai > 1 && entry.mainLayers > 0) kvLayers = Math.max(1, Math.round(entry.mainLayers / fai))
    if (!isFinite(kvLayers) || kvLayers <= 0) kvLayers = total
    entry.kvCacheBytes = _kvEstimateBytes(kvLayers, ctx, hckv, headDim,
      _kvDtypeBits(entry.cacheK), _kvDtypeBits(entry.cacheV))
  }

  // Fold the parsed DRAFT (MTP) model header into its running-model entry: the
  // draft's block_count IS the MTP layer count and its file size is the MTP
  // weight size. Placement comes from --n-gpu-layers-draft, which budgets the
  // draft independently of the main --n-gpu-layers.
  function _applyGgufDraft(entry, g) {
    var mtpLayers = (g.bc > 0) ? Math.round(g.bc) : 0
    entry.mtpLayers = mtpLayers
    if (g.sz > 0) {
      entry.mtpSizeBytes = g.sz
      entry.draftSizeBytes = g.sz
    }
    var split = _mtpSplit(entry.nglDraft, mtpLayers, mtpLayers)
    entry.mtpGpu = split.mtpGpu
    entry.mtpCpu = split.mtpCpu
  }

  // Apply a freshly-parsed header to the matching running model and republish
  // the array so the Repeater re-renders with the resolved values. The path is
  // matched against both the base (--model) and draft (--model-draft) paths.
  function _applyGgufToRunning(path, g) {
    var arr = runningModels || []
    var changed = false
    for (var i = 0; i < arr.length; i++) {
      var e = arr[i]
      if (!e) continue
      if (String(e.modelPath || "") === path) { _applyGguf(e, g); changed = true }
      else if (String(e.draftPath || "") === path) { _applyGgufDraft(e, g); changed = true }
    }
    if (changed) runningModels = arr.slice()
  }

  function _finishGguf() {
    var raw = _ggufBuffer.trim()
    _ggufBuffer = ""
    var path = _ggufPath
    _ggufPath = ""
    var bc = -1, hc = -1, hckv = -1, embd = -1, npl = -1, fai = -1, sz = -1, ok = false
    var lines = raw.split("\n")
    for (var i = 0; i < lines.length; i++) {
      var line = String(lines[i]).trim()
      if (line === "GGUF-OK") { ok = true; continue }
      var eq = line.indexOf("=")
      if (eq <= 0) continue
      var key = line.substring(0, eq)
      var val = parseInt(line.substring(eq + 1), 10)
      if (key === "block_count") bc = isFinite(val) ? val : -1
      else if (key === "head_count_kv") hckv = isFinite(val) ? val : -1
      else if (key === "head_count") hc = isFinite(val) ? val : -1
      else if (key === "embedding_length") embd = isFinite(val) ? val : -1
      else if (key === "nextn_predict_layers") npl = isFinite(val) ? val : -1
      else if (key === "full_attention_interval") fai = isFinite(val) ? val : -1
      else if (key === "size") sz = isFinite(val) ? val : -1
    }
    // Only cache a confirmed GGUF header with a usable layer count.
    if (!ok || bc < 0 || path === "") return
    _ggufCache[path] = { bc: bc, hc: hc, hckv: hckv, embd: embd, npl: npl, fai: fai, sz: sz }
    _applyGgufToRunning(path, _ggufCache[path])
  }

  // ── /slots?model=<id> → idle tracking (issue #6) ───────────────────
  // llama.cpp exposes no last-request timestamp; the slot state is the idle
  // source: is_processing (request in flight right now) and id_task (monotonic
  // request counter that advances on each new request).
  property string _slotsBuffer: ""
  readonly property int _slotsBufferMax: 8192

  function _onSlotsLine(line) {
    var s = String(line || "")
    if (_slotsBuffer.length + s.length + 1 <= _slotsBufferMax) _slotsBuffer += s + "\n"
  }

  function _finishSlots() {
    var raw = _slotsBuffer.trim()
    _slotsBuffer = ""
    if (_slotsModelId === "") return
    var obj = null
    try { obj = JSON.parse(raw) } catch(e) { obj = null }
    var slot = (obj && typeof obj.length === "number" && obj.length > 0) ? obj[0] : null
    if (!slot || typeof slot !== "object") {
      // Unparseable / empty / error response: assume busy so an in-flight
      // request is never unloaded on bad data.
      _lastActivityMs = Date.now()
      return
    }
    var proc = (slot.is_processing === true) ? "1" : "0"
    var task = String(slot.id_task == null ? "" : slot.id_task)
    var sig = proc + ":" + task
    if (proc === "1") {
      _lastActivityMs = Date.now()
    } else if (task !== "" && sig !== _lastSig) {
      // id_task advanced since the last poll → a request completed between polls.
      _lastActivityMs = Date.now()
    }
    _lastSig = sig
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
      unloadInactivitySec = 0
      configValid = true
      configWarning = truncate("Refusing to read config: " + root.configPath + " is a symlink or special file.", 256)
      return
    }
    if (!hasConfig) {
      configHost = "127.0.0.1"
      configPort = 0
      configApiKey = ""
      unloadInactivitySec = 0
      configValid = true
      configWarning = ""
      return
    }
    // Collected values default to safe values. Any violation resets the
    // applied state back to these and records a human reason for the panel.
    var host = "127.0.0.1"
    var port = -1  // -1 = never set in the file = use the backend default port
    var apiKey = ""
    var unloadSec = 0  // 0 = auto-unload disabled (absent key stays disabled)
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
        } else if (key === "LLAMA_UNLOAD_INACTIVITY_SEC") {
          if (val !== "") {
            if (/^[0-9]+$/.test(val)) {
              var uns = parseInt(val, 10)
              if (isFinite(uns) && uns >= 0) unloadSec = uns
              else violations.push("LLAMA_UNLOAD_INACTIVITY_SEC is out of range")
            } else {
              violations.push("LLAMA_UNLOAD_INACTIVITY_SEC is not an integer")
            }
          }
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
      unloadInactivitySec = 0
      configValid = false
      configWarning = truncate("Invalid " + root.backendDisplayName + " config: " + violations.join("; ") + ".", 256)
      return
    }
    configHost = host
    configPort = port
    configApiKey = apiKey
    unloadInactivitySec = unloadSec
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

    // Re-read the backend config file on demand (called when the panel opens).
    // This is what makes dashboard-side settings like LLAMA_UNLOAD_INACTIVITY_SEC
    // take effect without a service restart: the value is re-parsed into
    // unloadInactivitySec and the auto-unload timer's `running` binding reacts.
    // Host/port edits still need a service restart to bind on the server side,
    // but the endpoint policy + idle timeout update immediately here.
    function reloadConfig() {
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
        if (root.backend === "llama.cpp") { runningModels = []; root._resetIdleTracking() }
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

  // llama.cpp → bounded no-load GGUF header read for the loaded model's own
  // metadata (totalLayers + KV-cache inputs). $1 = .gguf path, $2 = cap. The
  // path arrives only as a positional arg (never concatenated into the script);
  // the script refuses symlinks/special files and reads at most 16 KiB.
  Process {
    id: ggufProcess
    running: false
    command: ["timeout", "-k", "2", "" + processTimeoutSec,
              "bash", "-c", root.ggufScript, "dash",
              root._ggufPath, "" + root.capGguf]
    stdout: SplitParser { onRead: function(line) { root._onGgufLine(line) } }
    onExited: function(exitCode) {
      ggufWatchdog.stop()
      if (exitCode === 0) _finishGguf()
      else _ggufBuffer = ""
      _ggufPath = ""
    }
  }

  // llama.cpp → GET /slots?model=<id> (issue #6 idle source). $1 = /slots base,
  // $2 = model id (charset-validated in _syncIdleTracking), $3 = cap. Runs only
  // while auto-unload is enabled and a model is loaded; single-flight.
  Process {
    id: slotsProcess
    running: false
    command: ["timeout", "-k", "2", "" + processTimeoutSec,
              "bash", "-c", root.slotsScriptLlama, "dash",
              root.endpointScheme + "://" + root.effectiveHost + ":" + root.effectivePort + "/slots",
              root._slotsModelId, "" + root.capSlots]
    environment: ({ "DASH_API_KEY": root.configApiKey })
    stdout: SplitParser { onRead: function(line) { root._onSlotsLine(line) } }
    onExited: function(exitCode) {
      slotsWatchdog.stop()
      if (exitCode === 0) _finishSlots()
      else _slotsBuffer = ""
    }
  }

  // llama.cpp → POST /models/unload (issue #6). $1 = model id, $2 = endpoint,
  // $3 = cap. The id is validated in unloadModel(); the script strips any
  // quote/backslash/control byte before JSON encoding.
  Process {
    id: unloadProcess
    running: false
    command: ["timeout", "-k", "2", "" + processTimeoutSec,
              "bash", "-c", root.unloadScriptLlama, "dash",
              root._unloadId,
              root.endpointScheme + "://" + root.effectiveHost + ":" + root.effectivePort + "/models/unload",
              "" + root.capUnload]
    environment: ({ "DASH_API_KEY": root.configApiKey })
    stdout: SplitParser { onRead: function(line) { root._onUnloadLine(line) } }
    onExited: function(exitCode) {
      unloadWatchdog.stop()
      var id = _unloadId
      _unloadId = ""
      if (exitCode === 0) {
        _finishUnload(id)
      } else {
        _unloadBuffer = ""
        lastError = "Failed to unload " + (id !== "" ? id : "model") + " from " + root.backendDisplayName + "."
      }
    }
  }

  // ── Start/stop/create/unload output capture ────────────────────────
  property string _startBuffer: ""
  property string _stopBuffer: ""
  property string _createBuffer: ""
  property string _unloadBuffer: ""

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

  function _onUnloadLine(line) {
    var s = String(line || "")
    if (_unloadBuffer.length + s.length + 1 <= capUnload) _unloadBuffer += s + "\n"
  }

  // Unload result: curl -w '%{http_code}' appended the status to the response
  // body. 2xx = the model was released; anything else is surfaced (the router
  // stays up either way, so this never touches the service state).
  function _finishUnload(id) {
    var raw = truncate(_unloadBuffer.trim(), capUnload)
    _unloadBuffer = ""
    var m = raw.match(/(\d{3})$/)
    var code = m ? parseInt(m[1], 10) : -1
    if (code >= 200 && code < 300) {
      lastError = ""
      _resetIdleTracking()
      refresh()
    } else {
      var detail = raw.replace(/(\d{3})$/, "").trim()
      lastError = "Failed to unload " + (id !== "" ? id : "model") + " from " + root.backendDisplayName + "." +
        (detail !== "" ? " " + truncate(detail, 160) : "")
    }
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
    id: ggufWatchdog
    interval: watchdogMs
    repeat: false
    onTriggered: reap(ggufProcess, ggufWatchdog)
  }

  Timer {
    id: slotsWatchdog
    interval: watchdogMs
    repeat: false
    onTriggered: reap(slotsProcess, slotsWatchdog)
  }

  Timer {
    id: unloadWatchdog
    interval: watchdogMs
    repeat: false
    onTriggered: if (unloadProcess.running) unloadProcess.running = false
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

  // Issue #6 auto-unload check: at most one check per second while enabled.
  // The actual unload goes through unloadModel(), which re-checks
  // busy/running/endpoint/loaded, so a start or stop in flight is never
  // raced. Firing resets the baseline so it cannot fire again until the next
  // model load re-arms tracking.
  Timer {
    id: unloadCheckTimer
    interval: 1000
    repeat: true
    running: root.backend === "llama.cpp" && root.unloadInactivitySec > 0 && root.running && !root.busy
    onTriggered: {
      if (!root.running || root.busy) return
      if (root._slotsModelId === "" || root._lastActivityMs < 0) return
      if (Date.now() - root._lastActivityMs <= root.unloadInactivitySec * 1000) return
      var id = root._slotsModelId
      root._resetIdleTracking()
      root.unloadModel(id)
    }
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
