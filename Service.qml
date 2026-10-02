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
  // llama.cpp only: LLAMA_MODELS_PRESET resolved from the env file. The on-disk
  // value is an absolute path — the "$HOME/..." default token is expanded at
  // env-write time (systemd does no var expansion inside env files). Written by
  // _parseConfigBuffer; empty until a valid config with the key has been read.
  property string configPresetPath: ""

  // Tier 5: normalized models.ini preset path from the loaded config. Empty
  // string = no preset → both Tier-5 consumers no-op (return to lower tiers).
  readonly property string presetPath: configPresetPath

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
pid=$(systemctl --user show $1 --property=MainPID --value 2>/dev/null);
cg=$(systemctl --user show $1 --property=ControlGroup --value 2>/dev/null);
# systemd's ControlGroup can come back empty (transient scope, D-Bus hiccup).
# Ask the kernel which cgroup the instance itself is in before giving up, so the
# spawned per-model worker is still measured directly: memory.stat is
# hierarchical, so one cgroup covers the router and every worker it forks.
if [ -z "$cg" ] && [ -n "$pid" ] && [ -r "/proc/$pid/cgroup" ]; then
  cg=$(awk -F: '$1=="0"{print $3; exit}' "/proc/$pid/cgroup" 2>/dev/null);
fi;
out="";
[ -n "$cg" ] && [ -r "/sys/fs/cgroup$cg/memory.stat" ] && out=$(awk '$1=="anon"{a=$2}$1=="shmem"{s=$2}END{print (a+0)+(s+0)}' "/sys/fs/cgroup$cg/memory.stat" 2>/dev/null);
# Last resort only, and the reason it must stay last: MemoryCurrent also counts
# reclaimable file cache — the mmap'd .gguf is ~13 GiB of it — so it reports an
# RSS-sized footprint that double-counts weight pages already on the GPU.
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
   // table) and pulls the arch id plus the u32 keys needed for totalLayers,
   // the KV-cache estimate, and the quantization (general.file_type → ftype).
   // No weights are read, nothing is mmap'd past the prefix, and no model is
   // loaded. Emits a first-line marker (GGUF-OK / GGUF-NO) then `key=value`
   // lines. Refuses symlinks / special files.
   readonly property string ggufScript: `
f="$1";
if [ ! -e "$f" ] || [ -L "$f" ] || [ ! -f "$f" ]; then echo GGUF-NO; exit 0; fi;
sz=$(stat -c %s -- "$f" 2>/dev/null);
{
# Pass 1: bounded 16 KiB read for the early hyperparameters (scalar u32 OR
# per-layer arrays; hyperparameters sit in the first few hundred bytes while the
# vocab/blob metadata comes much later). Arrays are emitted as key=a:v1,v2,...
# with a count==block_count trust guard (recurrent_layers is a sparse index list
# so it accepts count <= block_count, dropping any out-of-range entries).
# Element types: u32/i32 (4 B), u64/i64 (8 B), bool (1 B). head_count_kv is an
# i32 array in gemma4, a u32 array elsewhere — only reading u32/bool silently
# dropped it and fell the KV estimate back to head_count (8x too large).
head -c 16384 -- "$f" | od -A n -t x1 -v | awk -v SZ="$sz" '
BEGIN { for (i = 0; i < 256; i++) HEXVAL[sprintf("%02x", i)] = i; for (i = 32; i < 127; i++) { c = sprintf("%c", i); ORD[c] = i; HEXC[sprintf("%02x", i)] = c } }
function hexof(s,  n, i, out) { out = ""; for (i = 1; i <= length(s); i++) out = out sprintf("%02x", ORD[substr(s, i, 1)]); return out }
function unhex(h,  n, i, out) { out = ""; for (i = 1; i + 1 <= length(h); i += 2) out = out HEXC[substr(h, i, 2)]; return out }
function byteat(off) { return HEXVAL[substr(H, off * 2 + 1, 2)] }
function u32le(off) { return byteat(off) + byteat(off + 1) * 256 + byteat(off + 2) * 65536 + byteat(off + 3) * 16777216 }
function u64le(off,  i, out) { out = 0; for (i = 0; i < 8; i++) out = out + byteat(off + i) * (256 ^ i); return out }
function u64lehex(v,  i, out) { out = ""; for (i = 0; i < 8; i++) out = out sprintf("%02x", int(v / (256 ^ i)) % 256); return out }
{ buf = buf $0 }
END {
  gsub(/[ \t\r]/, "", buf)
  H = buf
  blen = int(length(H) / 2)
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
  n = 16
  KS[0] = arch ".block_count";                  NM[0] = "block_count"
  KS[1] = arch ".attention.head_count";         NM[1] = "head_count"
  KS[2] = arch ".attention.head_count_kv";      NM[2] = "head_count_kv"
  KS[3] = arch ".embedding_length";             NM[3] = "embedding_length"
  KS[4] = arch ".nextn_predict_layers";         NM[4] = "nextn_predict_layers"
  KS[5] = arch ".full_attention_interval";      NM[5] = "full_attention_interval"
  KS[6] = arch ".attention.key_length";         NM[6] = "key_length"
  KS[7] = arch ".attention.value_length";       NM[7] = "value_length"
  KS[8] = arch ".attention.key_length_swa";     NM[8] = "key_length_swa"
  KS[9] = arch ".attention.value_length_swa";   NM[9] = "value_length_swa"
  KS[10] = arch ".attention.sliding_window";    NM[10] = "sliding_window"
  KS[11] = arch ".attention.shared_kv_layers";  NM[11] = "shared_kv_layers"
  KS[12] = arch ".attention.sliding_window_pattern"; NM[12] = "sliding_window_pattern"
  KS[13] = arch ".attention.recurrent_layers";  NM[13] = "recurrent_layers"
  KS[14] = arch ".attention.kv_lora_rank";      NM[14] = "kv_lora_rank"
  KS[15] = arch ".attention.rope.dimension_count"; NM[15] = "rope_dimension_count"
  SP["recurrent_layers"] = 1
  for (i = 0; i < n; i++) {
    p = index(H, u64lehex(length(KS[i])) hexof(KS[i]))
    if (p == 0) continue
    kb = int((p - 1) / 2) + 8
    klen2 = length(KS[i])
    vt = u32le(kb + klen2)
    if (vt == 4) {
      v = u32le(kb + klen2 + 4)
      print NM[i] "=" v
      if (NM[i] == "block_count" && v > 0) BC = v
    } else if (vt == 9) {
      et = u32le(kb + klen2 + 4)
      cnt = u64le(kb + klen2 + 8)
      if (et == 4 || et == 5) esz = 4
      else if (et == 10 || et == 11) esz = 8
      else if (et == 7) esz = 1
      else continue
      if (kb + klen2 + 16 + cnt * esz > blen) continue
      if (SP[NM[i]] == 1) { if (cnt == 0 || cnt > BC) continue }
      else if (cnt != BC) continue
      line = NM[i] "=a:"
      nv = 0
      for (j = 0; j < cnt; j++) {
        eo = kb + klen2 + 16 + j * esz
        if (esz == 8) v = u64le(eo)
        else if (esz == 4) v = u32le(eo)
        else v = byteat(eo)
        if (SP[NM[i]] == 1 && !(v < BC)) continue
        if (nv > 0) line = line ","
        line = line v
        nv++
      }
      if (nv > 0) print line
    }
  }
  if (SZ ~ /^[0-9]+$/) print "size=" SZ
}';
# Pass 2: general.file_type is a scalar AFTER the (often MB-sized) tokenizer/
# vocab metadata, so it is beyond any small head cap in real files. Stream the
# file in fixed blocks (bounded, memory-flat) and print the value on first hit.
off=16384; cap=33554432; found=0;
while [ "$off" -lt "$cap" ] && [ "$found" -eq 0 ]; do
  chunk=$(dd if="$f" bs=4194304 skip=$((off / 4194304)) count=1 2>/dev/null | od -A n -t x1 -v | awk '
BEGIN { for (i = 0; i < 256; i++) HEXVAL[sprintf("%02x", i)] = i; for (i = 32; i < 127; i++) { c = sprintf("%c", i); ORD[c] = i; HEXC[sprintf("%02x", i)] = c } }
function hexof(s,  n, i, out) { out = ""; for (i = 1; i <= length(s); i++) out = out sprintf("%02x", ORD[substr(s, i, 1)]); return out }
function byteat(off) { return HEXVAL[substr(H, off * 2 + 1, 2)] }
function u32le(off) { return byteat(off) + byteat(off + 1) * 256 + byteat(off + 2) * 65536 + byteat(off + 3) * 16777216 }
function u64lehex(v,  i, out) { out = ""; for (i = 0; i < 8; i++) out = out sprintf("%02x", int(v / (256 ^ i)) % 256); return out }
{ buf = buf $0 }
END {
  gsub(/[ \t\r]/, "", buf)
  H = buf
  p = index(H, u64lehex(17) hexof("general.file_type"))
  if (p) {
    kb = int((p - 1) / 2) + 8
    if (u32le(kb + 17) == 4) print u32le(kb + 17 + 4)
  }
}');
  if [ -n "$chunk" ]; then echo "file_type=$chunk"; found=1; fi
  off=$((off + 4194304))
done
} | head -c "$2"`

   // Tier-5 models.ini preset reader (llama.cpp). $1 = preset path, $2 = cap.
   // Bounded read: at most $2 bytes in and $2 bytes out. Emits normalized
   // `[section]` and `key=value` lines (comments/blanks dropped); sections are
   // keyed by the model file path ([/abs/model.gguf]) plus the reserved [*]
   // globals block — so the charset keeps `/`, `.`, `-`, `_` (paths) and `*`
   // (globals). The caller's `_parseIniLines` re-reads this exact normalized
   // form. Refuses symlinks / special files / missing files (emits nothing →
   // both Tier-5 consumers no-op back to the lower tiers).
   readonly property int modelsIniCap: 16384
   readonly property string modelsIniScript: `
f="$1";
if [ ! -e "$f" ] || [ -L "$f" ] || [ ! -f "$f" ]; then exit 0; fi;
head -c "$2" -- "$f" 2>/dev/null | awk '
/^[[:space:]]*\\[/ { sec = $0; gsub(/[^a-zA-Z0-9_.\/\*-]/, "", sec); print "[" sec "]"; next }
/^[[:space:]]*[;#]/ { next }
/=/{ pos = index($0, "="); k = substr($0, 1, pos - 1); v = substr($0, pos + 1);
     gsub(/[ \t\r]/, "", k); gsub(/^[ \t]+|[ \t\r]+$/, "", v);
     if (k != "") print k "=" v; next }
' | head -c "$2"`

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

  // ── Tier 6: engine KV accounting probe ───────────────────────────
  // llama.cpp already reports the exact KV allocation for the context it
  // builds (bytes, per-cache layer count, cache dtypes, compute-buffer
  // reserve) in its own startup log — for EVERY architecture, including the
  // ones whose GGUF files carry no SWA pattern and the ones that only the
  // engine's source knows the layout of. The probe replays the running
  // worker's own KV-relevant flags against `llama-cli` with `-ngl 0`
  // (weights stay off the device, cache size is device-independent), so the
  // dashboard reads the engine's own numbers instead of modelling
  // architectures here. Results are cached per flag signature, so this costs
  // one short run per model+context, not one per refresh.
  //   kvProbe: "auto" (default) | "off" — "off" restores the header-only
  //   derivation for users who would rather never see a short llama-cli run.
  readonly property string kvProbe: String(setting("kvProbe", "auto")).trim().toLowerCase() === "off" ? "off" : "auto"
  readonly property string kvProbeBinary: String(setting("kvProbeBinary", "llama-cli")).trim() === ""
    ? "llama-cli" : String(setting("kvProbeBinary", "llama-cli")).trim()
  readonly property int kvProbeTimeoutSec: intSetting("kvProbeTimeoutSec", 45, 10, 300)
  readonly property int kvProbeWatchdogMs: (kvProbeTimeoutSec + 5) * 1000
  readonly property int capKvProbe: 262144    // probe log TEXT we keep, in chars (256 KiB)

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
    readonly property int capGguf: 2048         // GGUF header marker + arch + all key=value/scalar lines
    readonly property int capSlots: 8192        // /slots?model=<id> first-slot state
   readonly property int capUnload: 512        // unload response body + http_code

  // Engine KV accounting probe. $1 = llama-cli path, $2 = model bytes,
  // $3 = KV-estimate bytes (0 when the header gave nothing), rest = argv.
  // Unattended-safety comes from a PRE-FLIGHT GATE, not from a resource limit:
  // the probe mmaps the model and allocates the context's cache, so a request
  // larger than free RAM is refused before the engine starts (exit 98 = "skipped,
  // no room", which the caller records as no answer and the header derivation
  // answers instead) rather than being attempted and left to the OOM killer.
  // `ulimit -v` was the obvious tool here and is exactly wrong: it caps VIRTUAL
  // address space, which llama.cpp's GPU backends reserve far beyond its working
  // set — measured here, `ulimit -v 19.5G` made the very same 14.2 GB gemma-4
  // load die with "mmap failed: Cannot allocate memory" while 40 GiB sat free,
  // and it passed instantly when uncapped. The gate is sized for the model plus
  // twice the cache plus 2 GiB of slack, and requires 85% of MemAvailable.
  readonly property string kvProbeScript: `
set -o pipefail;
cli="$1"; mbytes="$2"; kbytes="$3"; shift 3;
want=$(( mbytes + 2 * kbytes + 2147483648 ));
avail=$(awk '/^MemAvailable:/ { print $2 * 1024 }' /proc/meminfo 2>/dev/null);
case "$avail" in ''|*[!0-9]*) avail=0 ;; esac;
if [ "$avail" -gt 0 ] && [ "$want" -gt "$avail" ] && [ "$want" -gt "$(( avail * 85 / 100 ))" ]; then
  printf 'kvprobe: skipped, need %d MiB, %d MiB available\\n' $(( want / 1048576 )) $(( avail / 1048576 )) >&2;
  exit 98;
fi;
exec "$cli" "$@"`

  // ── Tier 5: llama-fit-params ────────────────────────────────────────────
  // An OFFLINE decomposition of a model's memory at a SUPPLIED offload count.
  //
  // `--fit off` is the load-bearing flag, and it lives in the SCRIPT rather than
  // in the argv so a BATS test can byte-compare it against the exact string the
  // panel runs. `--fit` defaults to `on`, and on it *chooses* an offload count
  // against `-fitt`'s target margin; with it off the tool only reports the layout
  // for the `-ngl` it was handed, which is what makes tier 5 a decomposer and
  // never a decider. `-fitt` and `--flash-attn` are absent deliberately: the
  // first would inflate the projection with a margin, the second is the draft's
  // recorded abort.
  //
  // `shift 3` + named variables, copied from kvProbeScript above, because that is
  // the only shape in this file that does not re-emit its own leading arguments:
  // a single `shift` would leave `-ngl` and `-m` inside "$@" and the exec below
  // would print them twice. Nothing is ever interpolated — every value is a
  // quoted "$var", so a model path with spaces or `;` stays one argument.
  //
  // Exit 97 is NEW and deliberately not 98: 98 above is "skipped, not enough
  // MemAvailable" and means *retry when conditions change*, while 97 means "the
  // tool is not installed" and means *never try again*. Collapsing the two would
  // make a machine without llama-fit-params respawn a process per model per
  // refresh, forever.
  //
  // `--help` is the only question this binary answers truthfully: a no-arg run
  // exits 1 with `error: --model is required` on stderr and empty stdout, so the
  // obvious "run it and look for exit 0" availability probe reports "absent" on
  // every machine including this one. `ulimit -v` is NOT repeated here, for the
  // reason recorded above it.
  readonly property string kvFitScript: `
set -o pipefail;
ulimit -c 0 2>/dev/null || true;
fit="$1"; ngl="$2"; model="$3"; shift 3;
if [ ! -x "$fit" ] || ! "$fit" --help >/dev/null 2>&1; then
  printf 'kvfit: binary unavailable\\n' >&2;
  exit 97;
fi;
exec "$fit" --fit off --fit-print on -ngl "$ngl" -m "$model" "$@"`

  readonly property string kvFitBinary: "/usr/bin/llama-fit-params"

  // Its own timeout, not processTimeoutSec's 8: this reads a WHOLE model header
  // (~555 ms typical, several seconds for a 30 B model on a cold page cache).
  // The watchdog is strictly greater so `timeout` always wins and the QML timer
  // is only the backup that reaps a wedged child.
  readonly property int kvFitTimeoutSec: 20
  readonly property int kvFitWatchdogMs: (kvFitTimeoutSec + 2) * 1000


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
      var out = { model: "", ngl: "", draftPath: "", nglDraft: "", specType: "", cacheK: "", cacheV: "", noKvOffload: false, ubatch: 512, parallel: 1, swaFull: false, noKvUnified: false }
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
        // Server-side values that change the KV-cache allocation law. Defaults
        // (512 / 1 / off / unified) match llama.cpp for externally-run servers.
        else if (flag === "--ubatch" || flag === "-ub") { out.ubatch = parseInt(next(), 10); consume() }
        else if (flag === "--parallel" || flag === "-np") { out.parallel = parseInt(next(), 10); consume() }
        else if (flag === "--swa-full") { out.swaFull = true }
        else if (flag === "-kvu" || flag === "--no-kv-unified") { out.noKvUnified = true }
     }
     if (!isFinite(out.ubatch) || out.ubatch <= 0) out.ubatch = 512
     if (!isFinite(out.parallel) || out.parallel <= 0) out.parallel = 1
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

    // ══ Six-tier field store ═══════════════════════════════════════════
    //
    // One plain-JS object per loaded model, owned here and keyed by modelPath.
    // No QML component: cheaper per model, and the display layer never has to
    // instantiate one. Every value enters through commit(), which is the only
    // place that can enforce "never commit an unknown field".

    // Certainty. `marker` was a 2-valued string with "—" smuggled in by
    // markExhausted(), which made pending and absent indistinguishable — both
    // rendered "—" — so the display keyed "no value" off the -1 sentinel instead.
    // state is a real 4-valued enum and the glyph is derived from it in exactly
    // one place, so the mapping cannot drift.
    readonly property var stateEnum: ({ PENDING: "pending", EXACT: "exact",
                                    ESTIMATED: "estimated", ABSENT: "absent" })

    // The only place a state becomes a glyph.
    readonly property var stateGlyph: ({ pending: "…", exact: "",
                                          estimated: "~", absent: "—" })

    // Certainty order. A derivation can be no better than its worst input or its
    // own floor, so this is a max over a two-value domain rather than string
    // comparison. pending and absent are deliberately OUTSIDE it: they are
    // lifecycle, not certainty. Neither can be an input's contribution to
    // another field's state — a derivation reading a pending input cannot run
    // yet, and one reading an absent input has nothing to propagate — so
    // refusing to promote is the guard that stops a lifecycle state leaking
    // into a number.
    readonly property var stateRank: ({ exact: 0, estimated: 1 })

    function worseState(a, b) {
      if (a === undefined) return b
      if (b === undefined) return a
      var ra = stateRank[a], rb = stateRank[b]
      if (ra === undefined || rb === undefined) return "estimated"   // never promote
      return ra >= rb ? a : b
    }

    // A derivation's "I cannot answer this" — distinct from a value, so
    // {value: null} can never be mistaken for one.
    readonly property var decline: ({ decline: true })

    // Per-field value type. This is what makes validity decidable per field: the
    // four sentinels are -1, null, "" and false, and they are not all invalid
    // everywhere. false is the real answer for isCloud and noKvOffload and a
    // sentinel for a byte count, so a blanket predicate would either refuse the
    // booleans or let false into a byte count.
    readonly property var fieldTypes: ({
      // "num"  — finite, >= 0. -1, NaN and undefined are sentinels.
      // "str"  — non-empty string. "" is the sentinel.
      // "bool" — true / false. Neither is a sentinel.
      sizeBytes: "num", contextLen: "num", nParams: "num", ubatch: "num",
      parallel: "num", mainGpu: "num", mainCpu: "num", mtpGpu: "num",
      mtpCpu: "num", totalLayers: "num", mainLayers: "num", mtpLayers: "num",
      kvBytes: "num", kvGpuBytes: "num", kvCpuBytes: "num", computeBytes: "num",
      weightGpu: "num", weightCpu: "num", memBytes: "num", vramBytes: "num",
      coreSize: "num", mtpSizeBytes: "num", draftSizeBytes: "num", ftype: "num",
      ngl: "str", nglDraft: "str", cacheK: "str", cacheV: "str",
      modelPath: "str", draftPath: "str", specType: "str", kvLocation: "str",
      presetNgl: "str", soleAttribution: "str",
      isCloud: "bool", noKvOffload: "bool", swaFull: "bool", noKvUnified: "bool",
      kvBlockAligned: "bool", kvDescribed: "bool"
    })

    function isValidValue(name, v) {
      var t = fieldTypes[name]
      if (t === undefined) return false          // an unknown field cannot be committed
      if (t === "num")  return typeof v === "number" && isFinite(v) && v >= 0
      if (t === "str")  return typeof v === "string" && v !== ""
      if (t === "bool") return v === true || v === false
      return false
    }

    // Field → the tiers that can answer it. Derivation is NOT here and has its
    // own registry below; a field listed under several tiers is one several
    // rungs can attempt, and that is what makes the exhaustion join work.
    readonly property var capabilities: ({
      // 1 — Server API: GET /v1/models incl. status.args, plus GET /slots
      1: ["name", "sizeBytes", "contextLen", "nParams", "modelPath", "draftPath",
          "isCloud", "ngl", "nglDraft", "cacheK", "cacheV", "noKvOffload",
          "ubatch", "parallel", "swaFull", "noKvUnified", "specType"],
      // 2 — Model file: bounded 16 KiB GGUF header
      2: ["ftype", "totalLayers", "mtpLayers", "draftSizeBytes",
          "kvDescribed", "kvBlockAligned"],
      // 3 — Preset config: models.ini section over [*] globals
      3: ["presetNgl"],
      // 4 — System observation: per-PID device memory + cgroup anon+shmem
      4: ["memBytes", "vramBytes", "soleAttribution"],
      // 5 — Engine projection: llama-fit-params --fit off --fit-print on -ngl N
      5: ["kvGpuBytes", "kvCpuBytes", "computeBytes"],
      // 6 — Deep engine observation: llama-cli --verbose oracle
      6: ["kvBytes"]
    })

    // Every field the store can hold, with the tiers that may answer it.
    readonly property var fieldTiers: ({
      name: [1], sizeBytes: [1], contextLen: [1], nParams: [1], modelPath: [1],
      draftPath: [1], isCloud: [1], ngl: [1], nglDraft: [1], cacheK: [1],
      cacheV: [1], noKvOffload: [1], ubatch: [1], parallel: [1], swaFull: [1],
      noKvUnified: [1], specType: [1],
      ftype: [2], totalLayers: [2], mtpLayers: [2], draftSizeBytes: [2],
      kvDescribed: [2], kvBlockAligned: [2],
      presetNgl: [3],
      memBytes: [4], vramBytes: [4], soleAttribution: [4],
      kvGpuBytes: [5], kvCpuBytes: [5], computeBytes: [5],
      kvBytes: [6]
    })

    // The tiers still able to answer `name`, in walk order.
    function wantedTiers(name) { return fieldTiers[name] || [] }

    function createFieldStore(modelPath) {
      // name -> { value, state, tier, derived, answeredBy }
      var fields = ({})
      var version = 0          // bumped on every accepted commit / decline / settle
      // Side-channel for values a derivation needs but that are not store
      // fields: the parsed GGUF header, and the tier-1 flags _buildKvLayers
      // reads. Deliberately NOT fields — the KV geometry is re-read from the
      // header rather than flattened into twenty store entries.
      var ctx = ({})

      function entry(name) {
        if (!fields[name]) {
          fields[name] = { value: null, state: stateEnum.PENDING, tier: null,
                           derived: false, answeredBy: [] }
        }
        return fields[name]
      }

      // Field-set seed: every declared field exists and is pending from the
      // moment the store is created, so needsMore() is answerable before any
      // tier has run.
      for (var seed in fieldTiers) entry(seed)
      for (var dseed in derivations) entry(dseed)

      // A commit is the only way a value enters the store.
      //
      // `tier` is 1-6 for a read. For a derivation it is the WEAKEST of its
      // inputs, because the answer can be no better than its worst input, and
      // `derived` is what distinguishes the two cases. The two are orthogonal to
      // `state`: a derived value can be exact, and a read value can be estimated.
      //
      // The effective-tier rule ("a commit is accepted only when no better-ranked
      // tier has already answered") replaces first-commit-wins, which made
      // precedence an emergent property of table order and let a weak derivation
      // permanently block a stronger rung.
      //
      // ONE exception, and it is the revisability the placement ladder needs: a
      // derived answer may be REPLACED when its inputs changed (a different `sig`).
      // It is the same law over better evidence, so refusing it would freeze the
      // first reading forever — which is exactly how a corrected ~2.5 GB cache
      // still rendered "on GPU" while the cache sat in host RAM. A real read is
      // never revised this way; only its own tier can revise it, via revise().
      function commit(name, value, state, tier, derivesFrom, floor, sig) {
        var e = entry(name)
        if (!isValidValue(name, value)) return false
        var derived = !!derivesFrom
        if (derived) {
          var weakest = 0, worst = undefined
          for (var i = 0; i < derivesFrom.length; i++) {
            var dep = fields[derivesFrom[i]]
            if (!dep || dep.tier === null) return false   // an input is unattributed
            if (dep.tier > weakest) weakest = dep.tier
            worst = worseState(worst, dep.state)
          }
          // There is no tier 0: a derivation always has inputs, and an
          // unattributable one is refused rather than filed under tier 0.
          if (weakest <= 0) return false
          var rederive = (e.derived === true) && sig !== undefined
            && e.sig !== undefined && sig !== e.sig
          if (!rederive && e.tier !== null && e.tier <= weakest) return false
          // The derivation's own law: an explicit state from compute() beats the
          // registry's floor, because one field can have two laws and one floor
          // cannot express both. mainGpu is the case — an --n-gpu-layers token is
          // exact arithmetic on a stated count, while the measured-VRAM estimate
          // is an approximate model of reality. Falling back to the floor would
          // render "~20 layers" for a flag the engine was started with.
          var law = (state === stateEnum.EXACT || state === stateEnum.ESTIMATED)
            ? state : (floor || stateEnum.EXACT)
          state = worseState(worst, law)
          tier = weakest
          e.sig = sig
        } else {
          if (state !== stateEnum.EXACT && state !== stateEnum.ESTIMATED) return false
          if (typeof tier !== "number" || tier < 1 || tier > 6) return false
          if (e.tier !== null && e.tier <= tier) return false            // better answered
        }

        e.value = value
        e.state = state
        e.tier = tier
        e.derived = derived
        if (e.answeredBy.indexOf(tier) < 0) e.answeredBy.push(tier)
        version++
        return true
      }

      // A LIVE tier supersedes its own earlier reading. Only tier 4's probes take
      // this path (they measure every refresh), and only for the same tier: a
      // reading is superseded by a later reading of the same producer, never by a
      // different producer. Anything else goes through commit(), where the
      // effective-tier rule applies. No-op when nothing changed, so a 1 Hz poll
      // cannot churn the version.
      function revise(name, value, state, tier) {
        var e = entry(name)
        if (!isValidValue(name, value)) return false
        if (e.tier !== tier) return false
        if (e.value === value && e.state === state) return false
        e.value = value
        e.state = state
        version++
        return true
      }

      // "This tier ran and cannot answer this field." Different from a field
      // still being looked for: it removes that tier from the field's wanted set,
      // which is what eventually lets the field go absent instead of hanging as
      // pending.
      function decline(name, tier) {
        var e = entry(name)
        if (e.answeredBy.indexOf(tier) < 0) e.answeredBy.push(tier)
        version++
      }

      // Settled ⟺ every tier that could answer this field has either committed it
      // or declined it. This is the whole termination rule.
      //
      // Note what this must NOT do: return false just because the field is still
      // pending. Termination is a join over answeredBy vs the wanted set, and it
      // is markSettled() that decides whether a still-pending field may be
      // converted. Folding the pending test in here made the two mutually
      // exclusive, so absent was unreachable for every field in the store.
      function isSettled(name) {
        var e = fields[name]
        if (!e) return false
        if (e.state !== stateEnum.PENDING) return true
        var w = wantedTiers(name)
        if (!w.length && !derivations[name]) return false  // nobody declares it
        for (var i = 0; i < w.length; i++) {
          if (e.answeredBy.indexOf(w[i]) < 0) return false
        }
        return true
      }

      // A derived field is settled only once no derivation can still supply it:
      // every REQUIRED input is settled, and any absent input kills it outright.
      // Only required inputs count: an optional input is by definition allowed to
      // be absent, so letting it block would make the field pending forever.
      function derivationSettled(name) {
        var d = derivations[name]
        if (!d) return true
        var anyPending = false
        for (var i = 0; i < d.inputs.length; i++) {
          var dep = fields[d.inputs[i]]
          if (!dep || dep.state === stateEnum.PENDING) { anyPending = true; continue }
          if (dep.state === stateEnum.ABSENT) return true
        }
        return !anyPending
      }

      // `pending` is a promise, and a promise names someone: the lowest tier that
      // declared the field and has not answered yet.
      function pendingAt(name) {
        var e = fields[name]
        if (!e || e.state !== stateEnum.PENDING) return null
        var w = wantedTiers(name)
        for (var i = 0; i < w.length; i++) {
          if (e.answeredBy.indexOf(w[i]) < 0) return w[i]
        }
        return null                     // everyone answered, but not yet settled
      }

      function markSettled() {
        for (var name in fields) {
          var e = fields[name]
          if (e.state !== stateEnum.PENDING) continue
          if (!isSettled(name) || !derivationSettled(name)) continue
          e.state = stateEnum.ABSENT
          e.value = null
          version++
        }
      }

      function get(name) {
        var e = fields[name]
        if (!e) return null
        return { value: e.value, state: e.state, tier: e.tier, derived: e.derived,
                 sig: e.sig }
      }

      // The display's one accessor. Everything the view needs for a field,
      // including the glyph, without knowing the enum exists.
      function read(name) {
        var g = get(name)
        if (!g) return { value: null, state: stateEnum.PENDING, tier: null,
                         derived: false, glyph: stateGlyph.pending }
        return { value: g.value, state: g.state, tier: g.tier, derived: g.derived,
                 glyph: stateGlyph[g.state] }
      }

      // A derived answer loses its support when its inputs change. Sending it
      // back to `pending` is the honest move: the old number is not wrong, but it
      // was derived from data that is no longer current, and leaving it would be
      // worse — this is what stopped a corrected cache size from ever moving the
      // panel's placement. `pending` is also recoverable: the next settle either
      // re-derives it or takes it to `absent` ("—"), which is the correct display
      // for "the machine does not account for it".
      function invalidate(name) {
        var e = fields[name]
        // Nothing to withdraw from an already-absent field, and refusing here is
        // what keeps a still-unsupported derivation from flipping absent →
        // pending → absent (and bumping the version) on every single settle.
        if (!e || e.state === stateEnum.PENDING || e.state === stateEnum.ABSENT) return false
        e.value = null
        e.state = stateEnum.PENDING
        e.tier = null
        e.derived = false
        e.sig = undefined
        version++
        return true
      }

      // True while the field is still unanswered. This is what the display and
      // the probe queues gate on, so a resolved value can never re-enter pending.
      function needsMore(name) {
        var e = fields[name]
        return !!e && e.state === stateEnum.PENDING
      }

      function reset() { fields = ({}); version++ }

      return { path: modelPath, ctx: ctx, get: get, read: read,
               commit: commit, decline: decline, revise: revise,
               invalidate: invalidate,
               needsMore: needsMore, isSettled: isSettled,
               pendingAt: pendingAt, markSettled: markSettled,
               version: function () { return version }, reset: reset }
    }

    // ── Derivation registry ───────────────────────────────────────────
    // Each entry is a pure function of already-stored values, run after every
    // commit and every decline. No I/O, never in capabilities.
    //   inputs : REQUIRED fields. Rank, state propagation and the "can this run
    //            yet" test all come from this list, so it must be complete — an
    //            omitted input silently drops that input's estimated state.
    //   optional: fields that MAY be absent or pending. They are passed as
    //            undefined when they are, which is what lets a measurement-based
    //            derivation still answer from the values that did land. An
    //            optional input is excluded from both the "can run yet" test and
    //            derivationSettled().
    //   floor  : the worst state this derivation's law produces, when compute()
    //            does not state one itself. "" = the arithmetic is the law.
    //            "~" = the arithmetic is right but the model of reality is not
    //            (weightGpu's equal-layer assumption). This is the distinction
    //            from `derived`: a derived value can still be exact.
    //   compute: (values, store) -> { value, state? } | decline

    // Optional-input read. `undefined` (or any non-number) is the documented
    // "not available", never a zero — the same sentinel discipline the ladder uses.
    function _optNum(v, name, dflt) {
      var x = v[name]
      return (typeof x === "number" && isFinite(x)) ? x : dflt
    }

    // A separate --model-draft file is a DIFFERENT MODEL with its own layer
    // count. Everything that splits a stack has to know which of the two counting
    // rules applies, because they disagree about what "the stack" is: for the
    // base model, -ngl counts over the base file alone; for a built-in MTP stack,
    // nextn_predict_layers are counted INSIDE the base header's block_count, so
    // the draft sits on top of the main stack and the counts overlap.
    function _hasSeparateDraft(v) {
      return typeof v.draftPath === "string" && v.draftPath !== ""
    }

    function _deriveMainLayers(v) {
      if (!(v.totalLayers >= 0)) return decline
      var total = Math.round(v.totalLayers)
      // A separate --model-draft file is a DIFFERENT file: its block_count is its
      // own, and it was never part of the base file's count, so subtracting it
      // would invent a main stack one layer short. `mtpLayers` reduces
      // `totalLayers` only for a BUILT-IN MTP stack, whose nextn_predict_layers
      // are counted in the base header.
      if (_hasSeparateDraft(v)) return { value: total }
      var mtp = (v.mtpLayers >= 0) ? Math.min(Math.round(v.mtpLayers), total) : 0
      return { value: Math.max(0, total - mtp) }
    }

    function _deriveCoreSize(v) {
      if (!(v.sizeBytes > 0)) return decline
      var sb = Math.round(v.sizeBytes)
      // A separate --model-draft file is a DIFFERENT file: its bytes are not
      // inside the base file, so the base core is the whole file. Built-in MTP
      // (nextn_predict_layers) lives inside the base file, so those layers' bytes
      // come off — which is why draftSizeBytes is not an input and mtpSizeBytes is.
      //
      // draftPath is OPTIONAL here, so during the window before tier 1 reports it
      // this answers as if the MTP were built in, and the signature change when
      // draftPath lands re-derives it. Waiting instead would mean coreSize
      // depends on an unrelated tier's timing.
      var separate = (typeof v.draftPath === "string" && v.draftPath !== "")
      if (!separate && v.mtpLayers > 0 && v.mtpSizeBytes >= 0)
        return { value: Math.max(0, sb - Math.round(v.mtpSizeBytes)) }
      return { value: sb }
    }

    function _deriveMtpSize(v) {
      if (v.draftSizeBytes >= 0)
        return { value: Math.round(v.draftSizeBytes), state: stateEnum.EXACT }
      if (!(v.mtpLayers > 0) || !(v.sizeBytes > 0) || !(v.totalLayers > 0)) return decline
      // Uniform-layer assumption: an approximate model of reality, so "~".
      return { value: Math.round(v.sizeBytes / v.totalLayers * v.mtpLayers) }
    }

    function _deriveMainGpu(v) {
      var total = Math.round(v.totalLayers)
      if (!(total > 0)) return decline
      var mtp = (v.mtpLayers >= 0) ? Math.min(Math.round(v.mtpLayers), total) : 0
      // A stated offload count is exact: llama.cpp counts layers from the
      // bottom. API flags first, then the preset's own key.
      var tok = _isPresetSplitToken(v.ngl) ? String(v.ngl).trim()
            : (_isPresetSplitToken(v.presetNgl) ? String(v.presetNgl).trim() : "")
      if (tok !== "") {
        // `total` is the base file's block_count. For a built-in MTP stack the
        // draft's layers are inside it, so the main stack is total - mtp and the
        // offload count has to climb past them. For a separate draft the base
        // count IS the main stack, and handing total - mtp to _mtpSplit would
        // report a main stack three layers short of the file it came from.
        var stack = _hasSeparateDraft(v) ? total + mtp : total
        var s = _mtpSplit(tok, stack, mtp)
        if (s.mainGpu === null) return decline
        return { value: s.mainGpu, state: stateEnum.EXACT }
      }
      // Nothing stated the count, so measure: the service's per-PID device
      // memory minus whatever of it the cache holds, scaled by the model's own
      // core bytes. Always "~"; the clamp to [0, main] is the only guesswork.
      var vram = _optNum(v, "vramBytes", -1)
      if (!(vram >= 0) || !(v.coreSize > 0)) return decline
      var kv = _optNum(v, "kvBytes", -1)
      var on = _kvLocationOf(v.noKvOffload === true, null, kv, {
        memBytes: _optNum(v, "memBytes", -1), vramBytes: vram,
        sole: v.soleAttribution === "measured" })
      var est = _estimateSplitFromProbes(v.coreSize, total, vram,
        (on === "GPU" && kv > 0) ? kv : 0, _optNum(v, "computeBytes", -1))
      if (!est) return decline
      return { value: Math.min(est.gpuLayers, total - mtp) }
    }

    function _deriveMainCpu(v) {
      if (!(v.mainLayers > 0)) return decline
      return { value: Math.max(0, Math.round(v.mainLayers) - Math.round(v.mainGpu)) }
    }

    function _deriveMtpGpu(v) {
      var mtp = Math.round(v.mtpLayers)
      if (!(mtp > 0)) return { value: 0, state: stateEnum.EXACT }   // no draft: nothing offloaded
      // `-ngld` when it is there. When it is not, the draft follows the MAIN
      // stack's `-ngl`: a built-in MTP stack (nextn_predict_layers in the base
      // file) has no separate draft model at all, and llama.cpp defaults
      // --gpu-layers-draft to -ngl when the flag is omitted. Either way the draft
      // rides the main stack's setting, so an absent `-ngld` is not an unknown —
      // reading it as one dropped the badge to "—" for the commonest case.
      var token = String(v.nglDraft == null ? "" : v.nglDraft).trim()
      if (token === "") token = String(v.ngl == null ? "" : v.ngl).trim()
      // Counted over the stack -ngl counts over, which is not always the base
      // file. A BUILT-IN MTP stack lives inside the base header, so the MTP block
      // sits ON TOP of the main stack and -ngl 30 over 65 layers with 1 MTP leaves
      // all 30 in the main stack and none on the draft; splitting the draft's own
      // 1-layer stack against 30 would call it fully offloaded — the opposite
      // answer, from the same token. A SEPARATE draft model is its own stack:
      // -ngld 3 over a 3-layer draft means all three, and passing the base file's
      // 32 instead would report zero, because 3 < 32 - 3.
      var total = Math.round(v.totalLayers)
      if (!(total > 0)) return decline
      var s = _mtpSplit(token, _hasSeparateDraft(v) ? mtp : total, mtp)
      if (s.mtpGpu === null) return decline
      return { value: s.mtpGpu, state: stateEnum.EXACT }
    }

    function _deriveMtpCpu(v) {
      if (!(v.mtpLayers >= 0)) return decline
      return { value: Math.max(0, Math.round(v.mtpLayers) - Math.round(v.mtpGpu)) }
    }

    // coreSize × (share of layers on the device). Byte-exact arithmetic over
    // values that can all be exact, and still "~": it assumes every layer's
    // weights are the same size, and none of these models has uniform layers (an
    // IQ4_XS mix, an MoE expert stack, a differing mmproj). Multiplying exact
    // numbers by an approximate model of reality does not produce an exact
    // number. `coreSize` and not `sizeBytes`, so the main model's budget is not
    // charged for the draft model's weights.
    function _deriveWeightGpu(v) {
      if (!(v.coreSize > 0) || !(v.mainLayers > 0)) return decline
      if (!(v.mainGpu >= 0)) return decline
      return { value: Math.round(v.coreSize * Math.round(v.mainGpu) / Math.round(v.mainLayers)) }
    }

    function _deriveWeightCpu(v) {
      if (!(v.coreSize > 0) || !(v.mainLayers > 0)) return decline
      if (!(v.mainCpu >= 0)) return decline
      return { value: Math.round(v.coreSize * Math.round(v.mainCpu) / Math.round(v.mainLayers)) }
    }

    // The KV cache size. The only derivation that has to decide whether it KNOWS
    // something, so it has three outcomes rather than two:
    //   undescribable  → decline, and tier 6 answers
    //   describable but block-unaligned → a value, "~", tier 6 does NOT run
    //   describable and block-aligned     → a value, exact, tier 6 does NOT run
    // A described shape is still describable when it is unaligned, so it keeps
    // the "~" and never pays the 3-45 s oracle. Only an undescribable shape
    // escalates, and those two outcomes must not collapse into one.
    function _deriveKvBytes(v, store) {
      if (v.kvDescribed !== true) return decline        // tier 2 already said no
      var g = (store && store.ctx && store.ctx.gguf) ? store.ctx.gguf : null
      if (!g) return decline
      var ctx = Math.round(v.contextLen)
      if (!(ctx > 0)) return decline
      var c = (store.ctx && store.ctx.flags) ? store.ctx.flags : ({})
      var spec = _buildKvLayers(g, Math.round(v.mainLayers), ctx, {
        ubatch: (c.ubatch > 0) ? c.ubatch : 512,
        parallel: (c.parallel > 0) ? c.parallel : 1,
        swaFull: c.swaFull === true,
        kvUnified: v.noKvUnified !== true })
      if (!spec) return decline
      var bytes = _kvEstimateBytesArch(spec, _kvDtypeBits(v.cacheK), _kvDtypeBits(v.cacheV))
      if (!(bytes > 0)) return decline
      return { value: bytes,
               state: (v.kvBlockAligned === true) ? stateEnum.EXACT : stateEnum.ESTIMATED }
    }

    // Where the cache lives: no source at tiers 1-4 states it plainly (b10729
    // /props is near-empty and /slots carries no KV field), so the location is
    // arithmetic over tiers 1/2/4/5 — which is what makes it revisable. When
    // tier 4 owned this write, a corrected ~2.5 GB cache could not revise a
    // committed location, and the panel kept showing GPU while the cache was in
    // host RAM.
    function _deriveKvLocation(v) {
      var res = _kvPlacement({
        memBytes: _optNum(v, "memBytes", -1),
        vramBytes: _optNum(v, "vramBytes", -1),
        kvBytes: _optNum(v, "kvBytes", -1),
        soleAttribution: v.soleAttribution,
        noKvOffload: v.noKvOffload === true,
        ngl: v.ngl,
        answered: null })
      if (res.action !== "commit" || res.value === "") return decline
      return { value: res.value,
               state: (res.marker === "~") ? stateEnum.ESTIMATED : stateEnum.EXACT }
    }

    readonly property var derivations: ({
      mainLayers:  { inputs: ["totalLayers", "mtpLayers"],
                     optional: ["draftPath"], floor: "",
                     compute: _deriveMainLayers },
      coreSize:    { inputs: ["sizeBytes"],
                     optional: ["mtpSizeBytes", "mtpLayers", "draftPath"], floor: "",
                     compute: _deriveCoreSize },
      mtpSizeBytes:{ inputs: ["mtpLayers"],
                     optional: ["draftSizeBytes", "sizeBytes", "totalLayers"],
                     floor: "~", compute: _deriveMtpSize },
      mainGpu:     { inputs: ["totalLayers", "mtpLayers"],
                     optional: ["draftPath", "ngl", "presetNgl", "coreSize",
                                "vramBytes", "memBytes", "kvBytes",
                                "computeBytes", "noKvOffload",
                                "soleAttribution"],
                     floor: "~", compute: _deriveMainGpu },
      mainCpu:     { inputs: ["mainGpu", "mainLayers"], floor: "~",
                     compute: _deriveMainCpu },
      mtpGpu:      { inputs: ["mtpLayers", "totalLayers"],
                     optional: ["draftPath", "nglDraft", "ngl"], floor: "~",
                     compute: _deriveMtpGpu },
      mtpCpu:      { inputs: ["mtpGpu", "mtpLayers"], floor: "~",
                     compute: _deriveMtpCpu },
      weightGpu:   { inputs: ["coreSize", "mainGpu", "mainLayers"], floor: "~",
                     compute: _deriveWeightGpu },
      weightCpu:   { inputs: ["coreSize", "mainCpu", "mainLayers"], floor: "~",
                     compute: _deriveWeightCpu },
      kvBytes:     { inputs: ["kvDescribed", "kvBlockAligned", "mainLayers",
                              "contextLen", "cacheK", "cacheV", "noKvUnified"],
                     floor: "", compute: _deriveKvBytes },
      kvLocation:  { inputs: ["soleAttribution", "noKvOffload", "kvBytes"],
                     optional: ["memBytes", "vramBytes", "ngl"], floor: "~",
                     compute: _deriveKvLocation }
    })

    // ── The resolver ──────────────────────────────────────────────────
    //
    // There is no linear resolveAll() loop: tiers 2, 4, 5 and 6 are async QML
    // processes and tier 6 takes 3-45 s, so a synchronous walk over [1..6] would
    // block the QML thread on first load. The resolver is instead a field-set
    // seed at store creation, a commit/decline pass inside each tier's own async
    // callback followed by applyDerivation() + markSettled(), and a per-field
    // join for termination.
    //
    // A derivation is RETRIED, never scheduled: it is attempted on every settle
    // and declines while an input is unsettled, so there is no ordering
    // constraint between tiers and derivations. It cannot promote certainty
    // (commit recomputes the state from the inputs and the law) and it cannot
    // displace a better answer (commit's effective-tier rule).
    function applyDerivation(store) {
      // Run to a FIXED POINT rather than in registry order: one derivation can
      // feed another (kvBytes needs mainLayers, which needs totalLayers), and an
      // object's key order is not a dependency order — relying on it made the
      // answer depend on how the registry happened to be written. The pass count
      // is bounded by the registry size, so a cyclic registry cannot hang the QML
      // thread; it just stops making progress.
      //
      // A derived field is not revisited on every pass: it is revisited when its
      // INPUT SIGNATURE changes, which is what keeps the placement ladder (and
      // everything above it) revisable without letting a settled answer churn.
      var names = []
      for (var n in derivations) names.push(n)
      for (var round = 0; round <= names.length; round++) {
        var progress = false
        for (var i = 0; i < names.length; i++) {
          var name = names[i]
          var cur = store.get(name)
          // A field is reconsidered when it is unanswered, when it already holds
          // a DERIVED answer (its inputs may have moved), or when it settled as
          // absent but is derivable — the withdrawal path above sends a stale
          // answer back through settle, and a settled "—" must be able to become
          // an answer again when a corrected reading arrives.
          var revisit = (cur !== null && cur.derived === true)
          if (!revisit && !store.needsMore(name)) {
            if (!(cur !== null && cur.state === stateEnum.ABSENT && derivations[name]))
              continue
            revisit = true
          }
          var d = derivations[name]
          var v = ({}), ready = true
          for (var j = 0; j < d.inputs.length; j++) {
            var e = store.get(d.inputs[j])
            if (!e || e.state === stateEnum.PENDING || e.state === stateEnum.ABSENT) { ready = false; break }
            v[d.inputs[j]] = e.value
          }
          if (!ready) continue
          var opt = d.optional || []
          for (var k = 0; k < opt.length; k++) {
            var oe = store.get(opt[k])
            v[opt[k]] = (oe && oe.state !== stateEnum.PENDING && oe.state !== stateEnum.ABSENT)
              ? oe.value : undefined
          }
          // The signature is what makes a derived answer revisable: it names the
          // inputs AND their states, so a value that happens to be the same number
          // at a weaker certainty still counts as a change.
          var sig = ""
          for (var s1 = 0; s1 < d.inputs.length; s1++)
            sig += d.inputs[s1] + "=" + String(v[d.inputs[s1]]) + "/" + store.get(d.inputs[s1]).state + ";"
          for (var s2 = 0; s2 < opt.length; s2++)
            sig += (v[opt[s2]] !== undefined) ? opt[s2] + "=" + String(v[opt[s2]]) + ";" : ""
          if (revisit && cur.sig === sig) continue
          var out = d.compute(v, store)
          if (!out || out === decline) {
            // A revisit that can no longer answer is not a no-op: the previous
            // answer was derived from inputs that no longer hold, so it is
            // withdrawn rather than left standing as a stale "GPU".
            if (revisit) store.invalidate(name)
            continue                            // else: stays pending for a real tier
          }
          if (store.commit(name, out.value, out.state, null, d.inputs, d.floor, sig))
            progress = true
        }
        if (!progress) return
      }
    }

    function _anyPending(store, names) {
      for (var i = 0; i < names.length; i++) if (store.needsMore(names[i])) return true
      return false
    }

    // Per tier: do I have anything to do for this store? Only real fields, never
    // a derived one — a derivation is not something a tier can be asked for.
    function checkTier1Values(store) { return _anyPending(store, capabilities[1]) }
    function checkTier2Values(store) { return _anyPending(store, capabilities[2]) }
    function checkTier3Values(store) { return _anyPending(store, capabilities[3]) }
    function checkTier4Values(store) { return _anyPending(store, capabilities[4]) }
    function checkTier5Values(store) { return _anyPending(store, capabilities[5]) }

    // The gate. Two booleans, no null-object ambiguity: the oracle runs only when
    // the header could not describe the shape, or could not prove it block
    // aligned. A described, aligned shape is settled by derivation and must never
    // pay 3-45 s.
    function checkTier6Values(store) {
      var desc = store.get("kvDescribed"), aligned = store.get("kvBlockAligned")
      return store.needsMore("kvBytes")
          && (!desc || desc.value !== true)
          && (!aligned || aligned.value !== true)
    }

    // Tier 4 is service-global, so its wanted set is the union across stores and
    // the ladder runs once per refresh, projecting to each model.
    function checkTier4ValuesAny(stores) {
      for (var i = 0; i < stores.length; i++) if (checkTier4Values(stores[i])) return true
      return false
    }

    property var _stores: ({})            // modelPath -> field store
    property var _storeVersions: ({})     // modelPath -> version last painted

    function _storeFor(path) {
      if (path === undefined || path === null || String(path) === "") return null
      var p = String(path)
      if (!_stores[p]) _stores[p] = createFieldStore(p)
      return _stores[p]
    }

    // Per-model, not global. One _storeVersion cannot serve N models: a commit on
    // model A would paint A's version, and model B's later commit would compare
    // against A's number and be skipped. Keyed by path, so each model repaints
    // when its own store moves.
    function _republish(store) {
      if (!store) return
      var p = store.path
      if (_storeVersions[p] === store.version()) return
      _storeVersions[p] = store.version()
      runningModels = (runningModels || []).slice()
    }

    // The one hook each tier installs. Called after every commit and every
    // decline, so derivation and settlement both stay current.
    function _settle(store) {
      if (!store) return
      applyDerivation(store)
      store.markSettled()
      _republish(store)
    }

    // ── Tier 1 producer: GET /v1/models + GET /slots ───────────────────
    //
    // One writer, one shape. Every value is OFFERED to commit() and the store
    // decides: a valid value is committed, anything else is a decline. That is
    // the whole point of commit() being the only door — a producer cannot leave
    // a sentinel behind as though it were a reading, which is how a 0-byte
    // file (the API's stand-in for an unknown size) used to become a real 0.
    //
    // Idempotent: an already-answered field is left alone, so the 1 Hz /v1/models
    // poll cannot churn the store version or repaint on every tick.
    function _t1(store, name, value) {
      if (!store || !store.needsMore(name)) return
      if (isValidValue(name, value)) store.commit(name, value, stateEnum.EXACT, 1)
      else store.decline(name, 1)
    }

    // The one tier-1 field whose value can legitimately move under a live store:
    // `contextLen`, because /slots reports the RESOLVED context and a reload at a
    // different one is the same producer reporting a different number — not a
    // stronger source, so commit()'s effective-tier rule would refuse it and the
    // panel would show a context the engine is not using. Everything else at tier 1
    // is fixed for the life of the model and still commits once.
    function _t1update(store, name, value) {
      if (!store) return
      if (store.needsMore(name)) { _t1(store, name, value); return }
      var cur = store.get(name)
      if (cur && cur.tier === 1) store.revise(name, value, stateEnum.EXACT, 1)
    }

    function _applyTier1(entries) {
      var list = entries || []
      for (var i = 0; i < list.length; i++) {
        var e = list[i]
        if (!e) continue
        var st = _storeFor(e.modelPath)
        if (!st) continue                        // no path: the store cannot be keyed
        _t1(st, "name", e.name)
        _t1(st, "modelPath", e.modelPath)
        _t1(st, "draftPath", e.draftPath)
        _t1(st, "sizeBytes", e.sizeBytes > 0 ? e.sizeBytes : null)
        _t1(st, "contextLen", e.contextLen > 0 ? e.contextLen : null)
        _t1(st, "nParams", e.nParams >= 0 ? e.nParams : null)
        _t1(st, "isCloud", false)                // llama.cpp is never cloud
        _t1(st, "ngl", e.ngl)
        _t1(st, "nglDraft", e.nglDraft)
        _t1(st, "specType", e.specType)
        // An absent --cache-type-* MEANS f16 in llama.cpp, so the empty string is
        // normalized rather than declined: "" is the str sentinel, and committing
        // it would leave the dtype looking absent while the engine runs f16.
        _t1(st, "cacheK", String(e.cacheK == null ? "" : e.cacheK).trim() || "f16")
        _t1(st, "cacheV", String(e.cacheV == null ? "" : e.cacheV).trim() || "f16")
        _t1(st, "noKvOffload", e.noKvOffload === true)
        _t1(st, "swaFull", e.swaFull === true)
        _t1(st, "noKvUnified", e.noKvUnified === true)
        _t1(st, "ubatch", e.ubatch > 0 ? e.ubatch : null)
        _t1(st, "parallel", e.parallel > 0 ? e.parallel : null)
        // The header may already be parsed: the KV geometry facts it decides need
        // this tier's context and dtypes, so re-run tier 2 now that they exist.
        if (st.ctx.gguf) _applyTier2To(st)
        _settle(st)
      }
    }

    // A store outlives the model it describes unless something removes it, and a
    // dashboard polls forever: an unloaded model would keep its derived numbers
    // (and its whole derived graph) alive for the session. Pruned on every
    // rebuild, so the store set is exactly the loaded set.
    function _pruneStores(entries) {
      var live = ({}), list = entries || []
      for (var i = 0; i < list.length; i++) {
        var p = list[i] ? list[i].modelPath : ""
        if (p !== undefined && p !== null && String(p) !== "") live[String(p)] = true
      }
      for (var path in _stores) {
        if (!live[path]) { delete _stores[path]; delete _storeVersions[path] }
      }
    }

    // ── Tier 2 producer: the GGUF header ──────────────────────────────
    //
    // Idempotent like _t1, and re-run whenever the header OR the context lands,
    // because the KV geometry facts below cannot be decided without the allocated
    // context — and the allocated context is tier 1's, not the file's. The
    // trained context_length in the header is NOT a substitute: it is the model's
    // capacity, which can exceed the running allocation many times over.
    function _t2(store, name, value) {
      if (!store || !store.needsMore(name)) return
      if (isValidValue(name, value)) store.commit(name, value, stateEnum.EXACT, 2)
      else store.decline(name, 2)
    }

    function _applyTier2To(st) {
      if (!st) return
      var g = st.ctx.gguf
      if (!g) return
      _t2(st, "ftype", (isFinite(g.ft) && g.ft >= 0) ? Math.round(g.ft) : null)
      _t2(st, "totalLayers", (g.bc > 0) ? Math.round(g.bc) : null)

      // Which FILE owns the MTP count depends on whether a separate draft was
      // started: --model-draft's block_count IS the count, and the base header's
      // nextn_predict_layers is only the built-in fallback. Resolving that before
      // the draft path is known would commit the base header's 0 — and a commit
      // cannot be replaced by a later one at the same tier, so the real count
      // would then be un-committable for the life of the model. Undecided, so
      // pending; not declined.
      var d = st.ctx.draftGguf || null
      var dp = st.get("draftPath")
      if (dp.state === stateEnum.PENDING) {
        // Left alone on purpose.
      } else if (dp.value) {
        // A separate draft file: its header owns the count and the weight size.
        if (d) {
          _t2(st, "mtpLayers", (d.bc > 0) ? Math.round(d.bc) : null)
          _t2(st, "draftSizeBytes", (isFinite(d.sz) && d.sz > 0) ? Math.round(d.sz) : null)
        }
      } else {
        // No separate draft. An ABSENT key is a reading, not a gap: llama.cpp's
        // default is 0 draft layers, and mainLayers = total - mtpLayers cannot be
        // computed from a missing count, so declining here would block the whole
        // main/draft placement graph on a model that simply has no draft.
        var npl = (isFinite(g.npl) && g.npl > 0) ? Math.round(g.npl) : 0
        _t2(st, "mtpLayers", Math.min(npl, (g.bc > 0) ? Math.round(g.bc) : npl))
        _t2(st, "draftSizeBytes", null)
      }

      // The two KV geometry facts are NOT decided here when the allocated context
      // or the cache dtypes are still missing: an undecided field is left PENDING
      // rather than declined, because a decline is an answer, and answering "the
      // shape is undescribable" from a file we have not finished reading would
      // exhaust the field and send tier 6's oracle to a model that never needed it.
      var ctxE = st.get("contextLen"), ck = st.get("cacheK"), cv = st.get("cacheV")
      var answered = (ctxE.state === stateEnum.EXACT || ctxE.state === stateEnum.ESTIMATED)
        && ck.state !== stateEnum.PENDING && ck.state !== stateEnum.ABSENT
        && cv.state !== stateEnum.PENDING && cv.state !== stateEnum.ABSENT
      if (!answered) return
      // _buildKvLayers falls back to the header's own block_count when the main
      // layer count is not derived yet, which is sound for a per-layer fact: the
      // two geometry questions below (describable? block-aligned?) do not depend
      // on how many layers there are.
      var spec = _buildKvLayers(g, -1, Math.round(ctxE.value), {
        ubatch: (st.get("ubatch").value > 0) ? st.get("ubatch").value : 512,
        parallel: (st.get("parallel").value > 0) ? st.get("parallel").value : 1,
        swaFull: st.get("swaFull").value === true,
        kvUnified: st.get("noKvUnified").value !== true })
      _t2(st, "kvDescribed", spec ? true : false)
      // With no spec there is nothing to assess, so alignment is declined rather
      // than claimed: a false here would read as "we checked and it is not
      // aligned", which is a different and stronger claim than "not checked".
      _t2(st, "kvBlockAligned", spec ? _kvBlockAligned(spec, ck.value, cv.value) : null)
    }

    // ── Tier 3 producer: models.ini ────────────────────────────────────
    function _t3(store, name, value) {
      if (!store || !store.needsMore(name)) return
      if (isValidValue(name, value)) store.commit(name, value, stateEnum.EXACT, 3)
      else store.decline(name, 3)
    }

    // Tier 3 acquires the RAW token and computes nothing: `all` / an integer is a
    // stated offload count that mainGpu can turn into layers, while `auto` answers
    // nothing at all — so `auto` is declined here rather than handed on as a
    // string that _mtpSplit would have to reject.
    //
    // It needs no header and no probe, so it runs on every refresh for every
    // loaded model rather than waiting for the GGUF read.
    function _applyTier3(entry, store) {
      var st = store || _storeFor(entry ? entry.modelPath : "")
      if (!st) return
      var sec = _presetSectionFor(entry)
      var tok = (sec && sec["n-gpu-layers"] !== undefined) ? sec["n-gpu-layers"] : ""
      _t3(st, "presetNgl", _isPresetSplitToken(tok) ? String(tok).trim() : null)
    }

    // ── Tier 4 producer: measured device/host memory ───────────────────
    // Estimated, never exact: the probe samples the whole process, so its
    // attribution is a model of the machine's accounting, not a reading of it.
    function _t4(store, name, value) {
      if (!store) return
      if (!store.needsMore(name)) {
        // Same-tier revision. The probe takes a fresh reading every refresh, and
        // a later reading of the same producer supersedes the earlier one — the
        // only way a live measurement can correct itself.
        if (store.get(name).tier === 4) store.revise(name, value, stateEnum.ESTIMATED, 4)
        return
      }
      if (isValidValue(name, value)) store.commit(name, value, stateEnum.ESTIMATED, 4)
      // NOT declined on a missing reading. -1 here means "not measured yet", and
      // the probe runs again: declining would exhaust the field to a durable "—"
      // for a source that has not finished its first reading. Pending is the
      // honest state, and it is also what the plan's `soleAttribution: "pending"`
      // means.
    }

    // `list` is passed in rather than read from `runningModels`: this runs INSIDE
    // the rebuild that produces runningModels, so reading the property here sees
    // the PREVIOUS poll's set — and sole attribution is exactly the fact that
    // changes when the loaded set changes. A stale length reported a lone model
    // as "measured" on the poll that introduced a second one.
    function _applyTier4(list) {
      var l = list || runningModels || []
      var sole = (l.length === 1)
      for (var i = 0; i < l.length; i++) {
        var st = _storeFor(l[i] ? l[i].modelPath : "")
        if (!st) continue
        _t4(st, "memBytes", serviceMemoryBytes)
        _t4(st, "vramBytes", serviceVramBytes)
        _t4(st, "soleAttribution", sole ? "measured" : "unattributable")
        _settle(st)
      }
    }

    function _t5(store, name, value) {
      if (!store || !store.needsMore(name)) return
      if (isValidValue(name, value)) store.commit(name, value, stateEnum.ESTIMATED, 5)
      else store.decline(name, 5)
    }

    function _t6(store, name, value) {
      if (!store || !store.needsMore(name)) return
      if (isValidValue(name, value)) store.commit(name, value, stateEnum.EXACT, 6)
      else store.decline(name, 6)
    }

    // ── KV architecture templates + block alignment ───────────────────
    // GGUF keys are namespaced by architecture, so a header reader that hardcodes
    // llama.block_count reads NOTHING from a model that does not use the llama
    // prefix. A survey of the model set found seven distinct namespaces and in
    // every one the geometry keys use the SAME suffixes, so the template is one
    // suffix set against a set of prefixes. `qwen35moe` was then re-read
    // directly: 17.7 GB header, 40 blocks, 2 KV heads, 256-wide K and V, and
    // `full_attention_interval = 4` at the arch root — the last is what makes it
    // a 10-layer KV cache rather than a 40-layer one, which is the whole reason
    // it was once believed to be undescribable.
    // The suffix set, spelled exactly as the reader above looks it up: the two
    // period/pattern keys are NOT symmetric with the rest, and writing them as
    // though they were is how a reader ends up looking for a key the converter
    // never writes. `full_attention_interval` sits at the ARCH ROOT
    // (`qwen35moe.full_attention_interval`, verified in that model's header)
    // while the pattern list sits under `attention.` — see KS[5] and KS[12].
    // This table is the allowlist TOKEN, not a lookup: the names below are the
    // contract the reader in KS[]/NM[] implements.
    readonly property var kvKeySuffixes: ({
      blocks:     "block_count",
      kvHeads:    "attention.head_count_kv",
      kLen:       "attention.key_length",
      vLen:       "attention.value_length",
      embd:       "embedding_length",
      swa:        "attention.sliding_window",
      swaPattern: "attention.sliding_window_pattern",
      fai:        "full_attention_interval",
      recurrent:  "attention.recurrent_layers"
    })

    // An untemplated namespace → the derivation cannot describe the shape, and
    // says so. It does not guess, and it does not fall back to a uniform-layer
    // assumption: that produces a number which looks authoritative and is wrong,
    // which is strictly worse than "~", because "~" tells the reader to disbelieve
    // it. Coverage is a data question, not a correctness one.
    //
    // The list is the set of namespaces whose KV key semantics have been READ, and
    // it is deliberately wider than the seven the original survey found on this
    // machine. `_buildKvLayers` already carries per-architecture findings by name
    // — `head_count_kv == 0` declares a cacheless layer for lfm2 / lfm2moe /
    // bailingmoe3, and llama4 / cohere2 ship no window key yet still get a 4-layer
    // SWA pattern — and a namespace cannot be reasoned about by name here while
    // being declined as unknown there. Adding one is a data change: verify the
    // suffixes against the file, then add the prefix.
    readonly property var kvArchTemplates: [
      // Surveyed on this machine (concern-1 §5.2.1).
      "llama", "qwen35", "qwen35moe", "gemma4", "gemma4-assistant",
      "muse-glimmer", "dflash", "phi3",
      // Named in this file's own per-architecture reasoning, above.
      "gemma3", "llama4", "cohere2", "lfm2", "lfm2moe", "bailingmoe3",
      "deepseek2"]

    function _kvArchTemplate(arch) {
      var a = String(arch == null ? "" : arch).trim()
      return kvArchTemplates.indexOf(a) >= 0 ? kvKeySuffixes : null
    }

    // Bytes per quant BLOCK (not per element). A q8_0 tensor of 128 elements is
    // 136 bytes: 4 blocks × (2 B scale + 32 int8). A q8_0 tensor of 256 elements
    // is 272 bytes. Testing the element count against these numbers would report
    // alignment for shapes that are not aligned, which is the entire failure mode
    // the gate exists to prevent.
    readonly property var kvBlockSizeBytes: ({
      f32: 4, f16: 2, bf16: 2,
      q8_0: 34, q6_k: 210, q5_1: 24, q5_0: 22, q4_1: 20, q4_0: 18,
      iq4_nl: 18, iq4_xs: 18, q3_k: 110, q2_k: 84
    })

    function _kvBlockBytes(t) {
      var s = String(t == null ? "" : t).trim()
      if (s === "") return 2                 // llama.cpp's f16 default
      var b = kvBlockSizeBytes[s]
      return (b === undefined) ? -1 : b       // unknown quant: cannot judge
    }

    // Every term of the sum is a whole number of its dtype's quant block,
    // assessed per layer AND per tensor. K and V are separate tensors with
    // separate dtypes and separate block sizes, so they are tested separately:
    // testing their sum against one block size can report alignment when neither
    // is aligned — and q5_0 K with q4_0 V is exactly the case where they differ.
    function _kvBlockAligned(spec, cacheK, cacheV) {
      if (!spec || !spec.layers || !spec.layers.length) return false
      var kb = _kvBlockBytes(cacheK), vb = _kvBlockBytes(cacheV)
      if (kb < 0 || vb < 0) return false
      var kBits = _kvDtypeBits(cacheK), vBits = _kvDtypeBits(cacheV)
      if (!(kBits > 0) || !(vBits > 0)) return false
      var mult = (spec.kvUnified !== false)
        ? 1 : ((isFinite(spec.parallel) && spec.parallel > 0) ? Math.round(spec.parallel) : 1)
      for (var i = 0; i < spec.layers.length; i++) {
        var L = spec.layers[i]
        if (!(L.cells > 0) || !(L.kLen > 0)) return false
        var kBytes = L.kLen * L.cells * kBits / 8 * mult
        if (!(kBytes % kb === 0)) return false
        if (L.hasV === false) continue         // MLA: K-only
        if (!(L.vLen > 0)) return false
        var vBytes = L.vLen * L.cells * vBits / 8 * mult
        if (!(vBytes % vb === 0)) return false
      }
      return true
    }

    // llama.cpp ftype enum → human label. Table verified against the installed
    // llama.h (build 10729); the value arrives via the GGUF header's
    // `general.file_type` (Tier 2; the llama.cpp /v1/models meta block sends no
    // ftype key) — so this one table is the single mapping. Compact k-quant
    // labels match the file's actual quantization. Unknown / unsupported enum
    // → -1 (display "—").
    function _ftypeLabel(ftype) {
      var s = parseInt(ftype, 10)
      if (!isFinite(s)) return -1
      switch (s) {
        case 0:  return "f32"
        case 1:  return "f16"
        case 2:  return "q4_0"
        case 3:  return "q4_1"
        case 7:  return "q8_0"
        case 8:  return "q5_0"
        case 9:  return "q5_1"
        case 10: return "q2_k"
        case 11: return "q3_k_s"
        case 12: return "q3_k_m"
        case 13: return "q3_k_l"
        case 14: return "q4_k_s"
        case 15: return "q4_k_m"
        case 16: return "q5_k_s"
        case 17: return "q5_k_m"
        case 18: return "q6_k"
        case 19: return "iq2_xxs"
        case 20: return "iq2_xs"
        case 21: return "q2_k_s"
        case 22: return "iq3_xs"
        case 23: return "iq3_xxs"
        case 24: return "iq1_s"
        case 25: return "iq4_nl"
        case 26: return "iq3_s"
        case 27: return "iq3_m"
        case 28: return "iq2_s"
        case 29: return "iq2_m"
        case 30: return "iq4_xs"
        case 31: return "iq1_m"
        case 32: return "bf16"
        case 36: return "tq1_0"
        case 37: return "tq2_0"
        case 38: return "mxfp4_moe"
        case 39: return "nvfp4"
        default: return -1
      }
    }

    // Bare integer count → compact count string: "N.B" (≥1e9), "N.M" (≥1e6),
    // else the raw number. Unknown / negative → -1 (display "—"). Kept pure so
    // the params/vocab formatting is unit-testable without a render pass.
    function _formatCount(n) {
      var x = parseInt(n, 10)
      if (!isFinite(x) || x < 0) return -1
      if (x >= 1e9) return (x / 1e9).toFixed(1) + "B"
      if (x >= 1e6) return (x / 1e6).toFixed(1) + "M"
      return String(x)
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

    // Per-arch default SWA period: deliberately NOT modelled here. llama.cpp
    // resolves a missing pattern key from constants in its own architecture
    // source (load_swa_pattern), and a GGUF file only carries the pattern when
    // its converter happened to write it — `add_sliding_window_pattern` is not
    // called by the reference converter at all. A table copied from that
    // source is a snapshot of one upstream commit and wrong for every
    // architecture it misses (and stale the day upstream changes it), so the
    // header path below treats a missing pattern as unknown → null → "—", and
    // the engine probe (tier 6) answers instead. It knows every layout
    // because it IS the layout's owner.

    // Cell count for one KV layer (llama.cpp allocation law). Full-attention and
    // --swa-full layers hold ctx cells; SWA layers hold min(ctx, sliding_window
    // × (unified? parallel : 1) + ubatch) padded up to 256. Unknown → -1.
    function _kvCellsForType(isSwa, ctx, swaWindow, ubatch, swaFull, kvUnified, parallel) {
      if (!isFinite(ctx) || ctx <= 0) return -1
      if (!isSwa || swaFull) return ctx
      if (!isFinite(swaWindow) || swaWindow <= 0) return -1
      var u = (isFinite(ubatch) && ubatch > 0) ? Math.round(ubatch) : 0
      var p = (kvUnified && isFinite(parallel) && parallel > 0) ? Math.round(parallel) : 1
      var cells = Math.min(ctx, swaWindow * p + u)
      return Math.ceil(cells / 256) * 256
    }

    // Does the file DECLARE which layers are recurrent? Exactly two file-level
    // keys express this and they are the only ones any llama.cpp source reads:
    // `attention.recurrent_layers` (a sparse index list) and
    // `attention.full_attention_interval` (the period, consulted only when the
    // list is absent). Either is a positive declaration, not an inference.
    // Pure: never throws.
    function _declaresRecurrent(g) {
      if (!g) return false
      if (g.recurrentArr && typeof g.recurrentArr.length === "number" && g.recurrentArr.length > 0) return true
      return isFinite(g.fai) && g.fai > 1
    }

    // Does the file declare this layer as holding NO KV cache? llama.cpp's own
    // convention for that is a zero `head_count_kv` entry — lfm2, lfm2moe and
    // bailingmoe3 all set `is_recr_impl[il] = (n_head_kv(il) == 0)` — so a 0 in
    // the per-layer array is a statement about the layer, not a missing value.
    // Pure: never throws.
    function _kvlessByHeads(g, il) {
      if (!g || !g.hckvArr || typeof g.hckvArr.length !== "number") return false
      if (il >= g.hckvArr.length) return false
      var e = parseInt(g.hckvArr[il], 10)
      return isFinite(e) && e === 0
    }

    // Layer indices whose KV cache is reused / not stored: recurrent_layers
    // (sparse index set) wins; otherwise the full_attention_interval fallback
    // marks every non-(N-th) layer recurrent (qwen35/qwen33n semantics); a
    // head_count_kv entry of 0 marks its own layer recurrent regardless.
    function _recurrentSet(g, m, fai) {
      var set = {}
      if (g.recurrentArr && typeof g.recurrentArr.length === "number" && g.recurrentArr.length > 0) {
        for (var i = 0; i < g.recurrentArr.length; i++) {
          var idx = parseInt(g.recurrentArr[i], 10)
          if (isFinite(idx) && idx >= 0 && idx < m) set[idx] = true
        }
      } else if (fai > 1) {
        for (var il = 0; il < m; il++) if ((il + 1) % fai !== 0) set[il] = true
      }
      for (var il2 = 0; il2 < m; il2++) if (_kvlessByHeads(g, il2)) set[il2] = true
      return set
    }

    // Per-layer KV spec from the header: [{kvHeads, kLen, vLen, cells}] or null
    // when any counted layer is unsized (unknown → "—"). kLen/vLen are the FULL
    // per-layer row lengths (kvHeads × head dim); MLA layers are K-only with the
    // row = kv_lora_rank + rope.dimension_count. shared_kv_layers tail layers
    // reuse earlier KV and are skipped; recurrent layers carry no context KV.
    function _buildKvLayers(g, mainLayers, ctx, args) {
      if (!g || !isFinite(ctx) || ctx <= 0) return null
      // An UNTEMPLATED namespace declines. The header reader is prefix-generic —
      // it looks up `<arch>.<suffix>` for whatever architecture the file declares,
      // so the keys ARE found for an unknown namespace — but finding a key is not
      // the same as knowing what it means. `attention.head_count_kv` is a KV-head
      // count because the llama-family converters define it that way; a namespace
      // nobody has templated may use the same suffix for a different quantity, and
      // a number computed from it looks authoritative while being wrong, which is
      // strictly worse than "~" because "~" tells the reader to disbelieve it.
      //
      // This is the same reason the reader must not fall back to a uniform-layer
      // assumption: a guessed layout for a file whose layout is unknown is the
      // failure this whole design exists to prevent. Declining routes to tier 6,
      // which answers from the engine itself.
      //
      // The check lives HERE rather than at the call site so every present and
      // future caller is gated by one rule; kvArchTemplates is otherwise dead
      // code, and dead code that documents an intent nothing enforces is worse
      // than no code at all.
      if (_kvArchTemplate(g.arch) === null) return null
      var m = (isFinite(mainLayers) && mainLayers > 0) ? Math.round(mainLayers)
            : ((isFinite(g.bc) && g.bc > 0) ? Math.round(g.bc) : -1)
      if (m <= 0) return null
      var a = args || {}
      var ubatch = (isFinite(a.ubatch) && a.ubatch > 0) ? Math.round(a.ubatch) : 512
      var parallel = (isFinite(a.parallel) && a.parallel > 0) ? Math.round(a.parallel) : 1
      var swaFull = a.swaFull === true
      var kvUnified = a.kvUnified !== false
      var hc = (g.hc > 0) ? g.hc : -1
      var hckvScalar = (g.hckv > 0) ? g.hckv : -1
      var embd = (g.embd > 0) ? g.embd : -1
      var headK = (hc > 0 && embd > 0) ? embd / hc : -1
      var kl = (g.kl > 0) ? g.kl : -1
      var vl = (g.vl > 0) ? g.vl : -1
      var klswa = (g.klswa > 0) ? g.klswa : -1
      var vlswa = (g.vlswa > 0) ? g.vlswa : -1
      var swaWindow = (g.swa > 0) ? g.swa : -1
      var sharedKv = (g.sharedKv > 0) ? g.sharedKv : 0
      var kvLoraRank = (g.kvLoraRank > 0) ? g.kvLoraRank : -1
      var ropeDim = (g.ropeDim > 0) ? g.ropeDim : -1
      var fai = (isFinite(g.fai) && g.fai > 1) ? Math.round(g.fai) : -1

      function hkFor(swa) {
        if (swa) { if (klswa > 0) return klswa; if (kl > 0) return kl; return headK }
        if (kl > 0) return kl
        if (klswa > 0) return klswa
        return headK
      }
      function hvFor(swa, hkDim) {
        if (swa) { if (vlswa > 0) return vlswa; return hkDim }
        if (vl > 0) return vl
        return hkDim
      }
      function kvHeadsFor(il) {
        var kv = -1
        if (g.hckvArr && typeof g.hckvArr.length === "number" && il < g.hckvArr.length) {
          var e = parseInt(g.hckvArr[il], 10)
          if (isFinite(e) && e > 0) kv = e
        }
        if (!(kv > 0)) kv = hckvScalar > 0 ? hckvScalar : (hc > 0 ? hc : -1)
        return kv
      }
      var layers = []
      // MLA (DeepSeek-style): K-only, dense full-ctx, per-layer row = lora + rope.
      if (kvLoraRank > 0) {
        if (!(ropeDim > 0)) return null
        for (var ilM = 0; ilM < m; ilM++) {
          if (sharedKv > 0 && ilM >= m - sharedKv) continue
          layers.push({ kvHeads: 1, kLen: kvLoraRank + ropeDim, vLen: 0, hasV: false, cells: ctx })
        }
        return layers.length ? { layers: layers, parallel: parallel, kvUnified: kvUnified } : null
      }
      // Layer type: an explicit pattern array (written by some converters), an
      // explicit scalar period, an explicit "no SWA" declaration
      // (attention.sliding_window == 0, which every llama.cpp source that reads
      // that key treats as KV_TYPE_NONE), or a file that declares its own
      // recurrent layers and no window at all (below).
      //
      // The last case is a DECLARATION too, not a guess about one architecture.
      // A window is a property of an attention stack, and llama.cpp never
      // hardcodes one for an architecture whose layers are interleaved with
      // recurrent ones. The two sets are disjoint — no file both declares
      // recurrence (recurrent_layers / full_attention_interval / ssm.*) and calls
      // load_swa_pattern or reads a window pattern. Verify against the checkout
      // rather than trusting this comment, and expect the lists to move with
      // upstream:
      //   grep -lE 'LLM_KV_ATTENTION_RECURRENT_LAYERS|LLM_KV_ATTENTION_FULL_ATTENTION_INTERVAL|SSM' src/models/*.cpp
      //   grep -lE 'load_swa_pattern|LLM_KV_ATTENTION_SLIDING_WINDOW_PATTERN' src/models/*.cpp
      //   comm -12 <(sort the two)   # must be empty
      // So such a file either carries its own window key or has none, and with no
      // key there is nothing for a period to be — the attention layers are dense.
      // qwen35moe (the shipped qwen3.6-35b-a3b) is the case that motivated it:
      // 40 layers, full_attention_interval 4, no attention.sliding_window at all,
      // and its own load_arch_hparams calls neither get_key(SLIDING_WINDOW) nor
      // load_swa_pattern, so is_swa_impl stays all-zero and llama.cpp builds one
      // flat full-context cache over the 10 non-recurrent layers. Measured
      // against the engine: `llama_kv_cache: size = 2720.00 MiB (262144 cells,
      // 10 layers, 1/1 seqs)`, which Tier 4 reproduces to the byte.
      //
      // A merely ABSENT sliding_window on a file that declares NOTHING about its
      // layer types is still not a declaration (llama4 and cohere2 carry no
      // window key and still get a 4-layer SWA pattern from their own source),
      // so that case deliberately falls through to unknown and the engine probe
      // answers it. A POSITIVE window with recurrent layers declared is also
      // left unknown: only lfm2 among the hybrids derives its pattern that way
      // (`is_swa_impl[il] = !is_recr_impl[il]`), while lfm2moe and bailingmoe3
      // use the same recurrence convention and ignore the window entirely — so
      // answering it would be a one-architecture table in disguise.
      var pattern = null, period = -1
      if (g.swaPatternArr && typeof g.swaPatternArr.length === "number" && g.swaPatternArr.length > 0) {
        pattern = g.swaPatternArr
      } else if (isFinite(g.swaPattern) && g.swaPattern > 0) {
        period = Math.round(g.swaPattern)
      } else if (g.swa === 0) {
        period = -1                     // declared dense: every layer full-size
      } else if (g.swa < 0 && _declaresRecurrent(g)) {
        period = -1                     // declared hybrid, no window: also dense
      } else {
        return null
      }
      var recurrent = _recurrentSet(g, m, fai)
      for (var il = 0; il < m; il++) {
        if (recurrent[il] === true) continue
        if (sharedKv > 0 && il >= m - sharedKv) continue
        var swa = pattern
          ? (il < pattern.length ? (parseInt(pattern[il], 10) > 0 || pattern[il] === true) : true)
          : (period > 0 ? (il + 1) % period !== 0 : false)
        var kv = kvHeadsFor(il)
        var hk = hkFor(swa)
        var hv = hvFor(swa, hk)
        if (!(kv > 0) || !(hk > 0) || !(hv > 0)) return null
        var cells = _kvCellsForType(swa, ctx, swaWindow, ubatch, swaFull, kvUnified, parallel)
        if (!(cells > 0)) return null
        layers.push({ kvHeads: kv, kLen: kv * hk, vLen: kv * hv, hasV: true, cells: cells })
      }
      return layers.length ? { layers: layers, parallel: parallel, kvUnified: kvUnified } : null
    }

    // Architecture-aware per-layer KV sum (Tier 4). Any unknown input → -1
    // (display "—"), mirroring the _kvEstimateBytes guards above.
    function _kvEstimateBytesArch(spec, kBits, vBits) {
      if (!spec || !spec.layers || !spec.layers.length) return -1
      if (!isFinite(kBits) || kBits < 0 || !isFinite(vBits) || vBits < 0) return -1
      var mult = (spec.kvUnified !== false) ? 1 : ((isFinite(spec.parallel) && spec.parallel > 0) ? Math.round(spec.parallel) : 1)
      var bytes = 0
      for (var i = 0; i < spec.layers.length; i++) {
        var L = spec.layers[i]
        if (!isFinite(L.cells) || L.cells <= 0) return -1
        if (!isFinite(L.kLen) || L.kLen <= 0) return -1
        if (L.hasV !== false && (!isFinite(L.vLen) || L.vLen <= 0)) return -1
        var kb = L.kLen * kBits / 8
        var vb = (L.hasV === false) ? 0 : L.vLen * vBits / 8
        var layerBytes = (kb + vb) * L.cells * mult
        if (!isFinite(layerBytes) || layerBytes <= 0) return -1
        bytes += layerBytes
      }
      if (!isFinite(bytes) || bytes <= 0) return -1
      return Math.round(bytes)
    }

    // ── KV-cache placement: the tier-4 ladder ───────────────────────────
    // Where the KV cache — and the context it holds — physically lives.
    //
    // Every branch is either a direct statement from the configuration or a
    // measured fact, never a model of the engine's placement heuristic:
    //   noKvOffload / -ngl 0   Tier 1, exact — flags that pin the cache to host
    //                            RAM. A fact from configuration, not an
    //                            inference, so it needs no attribution and is
    //                            answered before the attribution gate.
    //   mem === 0 && vram >= kv Tier 4, exact — nothing in host at all and the
    //                            device holds a cache's worth. The ONLY exact
    //                            "GPU": every other GPU answer needs a bound.
    //   vram === 0 && mem >= kv Tier 4, exact — the mirror. vram === 0 is a
    //                            *successful reading of zero*, which is why it is
    //                            unreachable on a machine with no NVIDIA device:
    //                            there the script prints nothing and the value
    //                            stays -1.
    //   0 < mem < kv && vram > 0
    //                            Tier 4, "~" — a split is proven, its ratio is
    //                            not. At most `mem` of the cache can be in host,
    //                            at least `kv - mem` must be on the device.
    //   mem >= kv && vram > 0  Tier 4, declined — the device holds memory and
    //                            host anon holds at least a whole cache, but the
    //                            reading cannot separate the cache from the
    //                            weights. This is the gemma case, and the old
    //                            `if (mem >= kv) return "CPU"` compared a
    //                            threshold rather than making a measurement.
    //   mem < 0 or vram < 0    not yet, not a zero — "wait", never a placement.
    //   soleAttribution
    //                            Multi-model router: the DRAM/VRAM readings are
    //                            the whole cgroup's, so neither can be
    //                            attributed to this model. Only the flag branches
    //                            may answer.
    //
    // A fully offloaded stack (ngl === "all", or every layer on the device) is
    // deliberately NOT a branch: it looks like the mirror of -ngl 0, but the
    // running gemma-4-26b-a4b-qat worker here has all 30 layers on the device
    // with its 2,879 MiB cache in host RAM, because llama.cpp sizes the KV buffer
    // against its own fit budget rather than following the layer buffers.
    //
    // PURE: reads a readings record, returns { value, marker, action } and never
    // touches the store, so every ladder test is a plain object literal with no
    // harness and no async waiting. `""` is not an answer — it is "indeterminate",
    // and the marker says how indeterminate.
    //   r = { memBytes, vramBytes, kvBytes, soleAttribution, noKvOffload, ngl,
    //         answered }
    // Returns { value: "GPU" | "CPU" | "GPU/CPU" | "",
    //           marker: "" | "~" | "—",
    //           action: "commit" | "decline" | "wait" }
    function _kvPlacement(r) {
      r = r || ({})

      // Already answered: echoing the existing answer keeps this total and is
      // safe because the store's effective-tier rule refuses a weaker commit.
      if (r.answered) return { value: r.answered.value,
                              marker: r.answered.marker, action: "commit" }

      // Branch 0 — a flag answers without needing any attribution.
      var br = _flagBranchKVLocation(r)
      if (br) return { value: br, marker: "", action: "commit" }

      // Branch 1 — attribution gate. Both closed states render "~" *now*; the
      // difference is the action, and a declined field only becomes a durable "—"
      // once the store exhausts it. "pending" is the one that must stay open.
      var att = r.soleAttribution
      if (!att || att === "pending" || att === "unattributable")
        return { value: "", marker: "~",
                 action: (att === "unattributable") ? "decline" : "wait" }

      // Sentinel discipline: -1 means "not measured" and is carried through as
      // -1, so it can never compare equal to 0 in a rung and fake a reading.
      var mem  = _num(r, "memBytes", -1)
      var vram = _num(r, "vramBytes", -1)
      var kv   = _num(r, "kvBytes", -1)

      if (kv <= 0) return { value: "", marker: "—", action: "decline" }

      // Rung 1a — nothing in host RAM at all, and the device is holding at least
      // a cache's worth. The only exact GPU.
      if (mem === 0 && vram >= kv) return { value: "GPU", marker: "", action: "commit" }

      // Rung 1b — the mirror of 1a. The device read SUCCEEDED and returned zero,
      // so there is no device to hold the cache; host anon is at least a whole
      // cache. NOT reachable on a machine with no NVIDIA device: there the script
      // prints nothing and vram stays -1, so it never reaches this branch.
      if (vram === 0 && mem >= kv) return { value: "CPU", marker: "", action: "commit" }

      // Contradiction — nothing in host at all, and the device is not holding
      // even a whole cache, so the cache is in neither place we can see. One of
      // the two readings is wrong; the honest answer is that we do not know.
      if (mem === 0 && vram < kv) return { value: "", marker: "—", action: "decline" }

      // Contradiction — the device provably holds nothing, and host anon is
      // provably SMALLER than the cache, so again it is in neither place.
      if (vram === 0 && mem > 0 && mem < kv)
        return { value: "", marker: "—", action: "decline" }

      // Rung 2 — host anon is smaller than the cache, so the cache is provably
      // not all in host, and it is provably not all on the device either (a
      // device reading of zero is already excluded above). A genuine split,
      // bounded but not stated. Deliberately does NOT divide: putting `mem` in
      // the CPU total and `kv - mem` in the GPU total is not an estimate of
      // where the cache is, because mem also holds the CPU-resident weights, the
      // compute buffers and the allocator slack.
      //
      // vram is NOT required. A -1 device reading is a missing measurement, not
      // a zero, so it cannot contradict anything; host anon alone already proves
      // the split.
      if (mem > 0 && mem < kv)
        return { value: "GPU/CPU", marker: "~", action: "commit" }

      // Rung 3 — a device IS holding memory, and host anon is at least a whole
      // cache. Not "CPU": the reading cannot separate the cache from the weights.
      if (mem >= kv && vram > 0)
        return { value: "", marker: "—", action: "decline" }

      // No reading (mem < 0, vram < 0). NOT a placement. "wait", not "decline":
      // a sentinel is a missing measurement, and declining would let the field
      // exhaust to a durable "—" while the probe is still out.
      return { value: "", marker: "~", action: "wait" }
    }

    // Same readings record, so this stays pure too. Kept separate only because it
    // is separately testable: the flag branch must answer even when attribution is
    // unattributable, which is a property of the branch, not a rung.
    function _flagBranchKVLocation(r) {
      if (r && r.noKvOffload === true) return "CPU"
      // "auto" and "all" are NOT 0. parseInt("all") is NaN and would pass a naive
      // `!== 0` test; the explicit exclusion is the guard.
      var n = r ? r.ngl : undefined
      if (n !== undefined && n !== null && n !== "" && n !== "auto" && n !== "all") {
        if (parseInt(n, 10) === 0 && _num(r, "kvBytes", -1) > 0) return "CPU"
      }
      return null
    }

    // Sentinel-preserving read. A missing key and a -1 reading are both "no
    // measurement" and both stay -1, so a rung can never mistake absence for 0.
    function _num(r, name, dflt) {
      var v = (r || ({}))[name]
      return (typeof v === "number" && isFinite(v)) ? v : dflt
    }

    // The ladder's readings record from the entry-shaped inputs the pre-store
    // call sites still hold. Deleted with the legacy resolver: once the store
    // owns these values, the derivation builds the record itself.
    function _kvLocationOf(noKvOffload, gpuLayers, kvBytes, p) {
      p = p || {}
      var att = (p.sole === false) ? "unattributable" : "measured"
      var res = _kvPlacement({
        memBytes: p.memBytes, vramBytes: p.vramBytes, kvBytes: kvBytes,
        soleAttribution: att, noKvOffload: noKvOffload === true,
        ngl: (isFinite(Number(gpuLayers)) && Number(gpuLayers) === 0) ? "0" : null,
        answered: null })
      return res.action === "commit" ? res.value : ""
    }

    // GPU/CPU weight bytes for display. Prefer the exact layer-ratio split when the
    // offload count is known; otherwise fall back to the measured per-device footprint
    // (an estimate — measured VRAM/DRAM can include KV cache). Unknown → -1 ("—").
    // Compatibility wrapper over the resolver path (its unit tests keep the
    // positional signature) — the per-field Tier ladder lives in
    // _resolveFieldSources/_resolveWeights below.
    function _weightBytes(sizeBytes, gpu, cpu, total, vramBytes, memBytes) {
      var split = (gpu >= 0 && cpu >= 0)
        ? { tier: 1, value: { mainGpu: gpu, mainCpu: cpu }, marker: "" }
        : { tier: null, value: null, marker: "\u2014" }
      var w = _resolveWeights(
        { sizeBytes: sizeBytes, totalLayers: total }, split,
        { vramBytes: vramBytes, memBytes: memBytes, presetSection: null })
      return [w.gpu, w.cpu]
    }

    // Split out of _weightBytes so it consumes an ALREADY-resolved split (the
    // output of _resolveFieldSources): the exact layer-ratio split when the
    // resolved split carries concrete layer counts, otherwise the measured
    // per-device footprint (an estimate — measured VRAM/DRAM can include KV
    // cache). The marker is the split's marker when the ratio path wins,
    // "~" when the measured footprint answered, "—" when nothing answered.
    function _resolveWeights(entry, gpuSplit, p) {
      var e = entry || {}
      p = p || {}
      var out = { gpu: -1, cpu: -1, gpuMarker: "\u2014", cpuMarker: "\u2014" }
      var total = (isFinite(e.totalLayers) && e.totalLayers > 0) ? e.totalLayers : -1
      var split = (gpuSplit && gpuSplit.value
        && gpuSplit.value.mainGpu != null && gpuSplit.value.mainCpu != null)
        ? gpuSplit.value : null
      if (e.sizeBytes > 0 && total > 0 && split) {
        out.gpu = Math.round(e.sizeBytes * split.mainGpu / total)
        out.cpu = Math.round(e.sizeBytes * split.mainCpu / total)
        var mark = (gpuSplit && gpuSplit.marker === "~") ? "~" : ""
        if (out.gpu >= 0) out.gpuMarker = mark
        if (out.cpu >= 0) out.cpuMarker = mark
      } else {
        if (p.vramBytes >= 0) { out.gpu = p.vramBytes; out.gpuMarker = "~" }  // ≈ measured GPU footprint
        if (p.memBytes  >= 0) { out.cpu = p.memBytes;  out.cpuMarker = "~" }  // ≈ measured DRAM working set
      }
      return out
    }

    // Single source of precedence for the per-field Tier ladder (golden rule #4
    // in the README): every field below is tagged exactly once with the Tier
    // that won (1=API, 2=GGUF, 3=probe, 4=derivation, 5=preset) and the render
    // marker ("", "~", "—"). The display layer and callers consume this instead
    // of re-deriving precedence, so "Tier 5 beats Tier 3", "Tier 1 beats Tier
    // 5", and the `~`-when-any-input-was-`~` rule are unit-testable in one
    // place. entry = a loaded-model entry; p = { vramBytes, memBytes,
    // presetSection } (all optional). Pure — never throws, never probes.
    // The DISPLAY's reader, and nothing but a reader.
    //
    // It used to be the resolver: it re-derived the split from `entry.ngl`, the
    // preset and the live VRAM reading, and re-implemented the KV byte fallback —
    // so the view and the resolver could disagree, and neither owned precedence.
    // Now every field comes from `store.read(name)`, which means:
    //
    //  - `pending` and `absent` reach the view as DIFFERENT states. They used to
    //    collapse into one "—" because this function invented its own markers;
    //    "…" (in flight) and "—" (looked for, not found) are now distinguishable,
    //    which is the only reason a probe still running can render honestly.
    //  - The glyph is mapped once, in the store. This function never builds one.
    //  - A store that does not exist yet (the model's first render, before any
    //    tier has answered) reads as pending, not as an error.
    //
    // Shape is unchanged, so ModelsSection.qml keeps calling it unchanged.
    function _resolveFieldSources(entry, p) {
      var e = entry || {}
      var st = _stores[String(e.modelPath == null ? "" : e.modelPath)] || null
      var r = {}
      // -1 is the display's "no reading"; a null store value becomes -1 here.
      // That coercion is display-side on purpose: it is not a store value.
      function numOr(v) { return (typeof v === "number" && isFinite(v)) ? v : -1 }
      function f(name) {
        if (st) return st.read(name)
        return { value: null, state: stateEnum.PENDING, tier: null,
                 derived: false, glyph: stateGlyph.pending }
      }
      function shaped(x, dflt) {
        return { tier: x.tier, state: x.state, marker: x.glyph, glyph: x.glyph,
                 derived: x.derived, value: numOr(x.value, dflt) }
      }
      // The string fields (a placement, a dtype, a spec type) keep their VALUE:
      // numOr would turn every one of them into the -1 the numeric rows use.
      function shapedStr(x) {
        return { tier: x.tier, state: x.state, marker: x.glyph, glyph: x.glyph,
                 derived: x.derived,
                 value: (x.value === null || x.value === undefined) ? "" : String(x.value) }
      }

      r.params      = shaped(f("nParams"), -1)
      r.quant       = shaped(f("ftype"), -1)
      r.totalLayers = shaped(f("totalLayers"), -1)
      r.mainLayers  = shaped(f("mainLayers"), -1)
      r.mtpLayers   = shaped(f("mtpLayers"), -1)
      r.coreSize    = shaped(f("coreSize"), -1)
      r.mtpSizeBytes = shaped(f("mtpSizeBytes"), -1)
      r.draftSizeBytes = shaped(f("draftSizeBytes"), -1)
      r.sizeBytes   = shaped(f("sizeBytes"), -1)
      r.contextLen  = shaped(f("contextLen"), -1)
      r.kvBytes     = shaped(f("kvBytes"), -1)
      r.kvLocation  = shapedStr(f("kvLocation"))
      r.mainGpu     = shaped(f("mainGpu"), -1)
      r.mainCpu     = shaped(f("mainCpu"), -1)
      r.mtpGpu      = shaped(f("mtpGpu"), -1)
      r.mtpCpu      = shaped(f("mtpCpu"), -1)
      r.cacheK      = shapedStr(f("cacheK"))
      r.cacheV      = shapedStr(f("cacheV"))
      // Tier 5's per-device cache split. Kept beside the cache size because the
      // totals below cannot split a cache without it.
      r.kvGpuBytes  = shaped(f("kvGpuBytes"), -1)
      r.kvCpuBytes  = shaped(f("kvCpuBytes"), -1)
      r.computeBytes = shaped(f("computeBytes"), -1)
      r.vramBytes   = shaped(f("vramBytes"), -1)
      r.memBytes    = shaped(f("memBytes"), -1)
      // Spec type is a string the Draft row shows verbatim.
      r.specType = shapedStr(f("specType"))

      // gpuSplit is a COMPOSITE, so it carries its own worst-of state rather than
      // borrowing one field's: a GPU count that is exact next to a CPU count that
      // is estimated renders "~" for both.
      var g = r.mainGpu, c = r.mainCpu
      var splitState = worseState(g.state === stateEnum.PENDING ? undefined : g.state,
                                  c.state === stateEnum.PENDING ? undefined : c.state)
      r.gpuSplit = { tier: g.tier, state: splitState, marker: stateGlyph[splitState],
                     glyph: stateGlyph[splitState],
                     derived: g.derived || c.derived,
                     value: (g.value < 0) ? null : { mainGpu: g.value, mainCpu: c.value } }

      var wg = f("weightGpu"), wc = f("weightCpu")
      r.weightBytes = { gpu: numOr(wg.value), cpu: numOr(wc.value),
                        gpuState: wg.state, cpuState: wc.state,
                        gpuMarker: wg.glyph, cpuMarker: wc.glyph }
      // The dtype pair is a composite too: a block that renders on one resolved
      // dtype and vanishes on the other makes the row's SHAPE depend on the data.
      var ck = r.cacheK, cv = r.cacheV
      r.kvDtype = { tier: ck.tier, state: ck.state,
                    marker: (ck.state === stateEnum.ABSENT && cv.state === stateEnum.ABSENT)
                      ? stateGlyph.absent : stateGlyph.pending,
                    value: { k: (ck.state === stateEnum.ABSENT) ? "" : String(ck.value),
                             v: (cv.state === stateEnum.ABSENT) ? "" : String(cv.value) } }
      return r
    }

    // models.ini n-gpu-layers tokens that _applyGgufPresetSplit actually
    // resolves (all / an integer). `auto` and empty values do NOT answer, so the
    // resolver tags Tier 5 only when a real split can come from the preset.
    function _isPresetSplitToken(v) {
      var s = String(v == null ? "" : v).trim()
      return s !== "" && /^(all|[0-9]+)$/.test(s)
    }

    // Estimate GPU/CPU layer split from measured device memory when ngl is
    // unknown. Built only from measured quantities: the service's per-PID VRAM
    // minus whatever of it the probe has already attributed to the KV cache
    // and to the compute-graph reserve, scaled by the model's real file size.
    // No assumed layer ratio, context length, head count or head dimension —
    // those were the inputs that made a wrong number look plausible. Always an
    // estimate ("~"); the clamp to [0, total] is the only guesswork left, and it
    // can only ever understate the GPU because an unaccounted device buffer
    // inflates the weight share. Returns { gpuLayers, cpuLayers } or null when
    // no measurement can carry it.
    function _estimateSplitFromProbes(sizeBytes, totalLayers, vramBytes, kvOnGpuBytes, computeBytes) {
      if (!(sizeBytes > 0)) return null
      if (!isFinite(totalLayers) || totalLayers <= 0) return null
      if (!(vramBytes >= 0)) return null
      var weightOnGpu = vramBytes
      if (kvOnGpuBytes > 0) weightOnGpu -= kvOnGpuBytes
      if (computeBytes > 0) weightOnGpu -= computeBytes
      if (weightOnGpu <= 0) return null
      var gpuLayers = Math.round(weightOnGpu / sizeBytes * totalLayers)
      gpuLayers = Math.max(0, Math.min(gpuLayers, totalLayers))
      return { gpuLayers: gpuLayers, cpuLayers: totalLayers - gpuLayers }
    }

    // ── Tier 5: bounded models.ini preset reader ──────────────────────
    // Single-flight read of the llama.cpp models.ini preset (only ever parsed
    // once per session), mirroring the ggufProcess scaffold. Results feed two
    // consumers: the service-stopped available list (Consumer A) and the
    // global-default layer split for loaded models the API left unset
    // (Consumer B, inside _applyGguf). Never throws; unknown/missing preset →
    // null and both consumers fall through to the lower tiers.

    property var _presetCache: null                // parsed INI or null (single read)
    property string _presetPath: ""                // path being read (single-flight)
    property string _presetBuffer: ""
    readonly property int _presetBufferMax: 16384

    // models.ini section keys are the model FILE paths ([/abs/model.gguf]) plus
    // the reserved [*] globals block. Mirror the awk charset exactly so the path
    // survives normalization and `*` is never dropped from the globals key.
    function _iniSectionKey(raw) {
      return String(raw == null ? "" : raw).replace(/[^a-zA-Z0-9_.\/*-]/g, "")
    }

    // Pure parser over the script's normalized output (or raw text in tests):
    // section markers → objects (key `*` holds [*] globals), `key=value` lines
    // merged into the current section. Comments/blanks dropped. Known-var
    // expansion is limited to a leading `$HOME/` token (the env writer already
    // expanded it, but a hand-edited preset may keep it).
    function _parseIniLines(buffer) {
      var out = {}
      var cur = null
      var lines = String(buffer || "").split("\n")
      for (var i = 0; i < lines.length; i++) {
        var line = String(lines[i]).trim()
        if (line === "") continue
        if (line.charAt(0) === ";" || line.charAt(0) === "#") continue
        if (line.charAt(0) === "[") {
          var end = line.lastIndexOf("]")
          if (end <= 1) continue
          var key = _iniSectionKey(line.substring(1, end))
          if (key === "") continue
          if (!out[key]) out[key] = {}
          cur = out[key]
          continue
        }
        var eq = line.indexOf("=")
        if (eq <= 0) continue
        var k = _iniSectionKey(line.substring(0, eq))
        if (k === "") continue
        var v = line.substring(eq + 1).trim()
        if (v.length >= 2) {
          var lq = v.charAt(0)
          if ((lq === "\"" || lq === "'") && v.charAt(v.length - 1) === lq) {
            v = v.substring(1, v.length - 1)
          }
        }
        var home = Quickshell.env("HOME")
        if (home && v.indexOf("$HOME/") === 0) v = home + v.substring(5)
        if (cur) cur[k] = v
      }
      return out
    }

    // Returns the parsed preset object or null. Callers must have started the
    // bounded read via _queuePreset(path): _finishPreset() populates the cache
    // on read completion, so a same-refresh re-read resolves synchronously.
    function _parsePreset(path) {
      if (_presetCache !== null) return _presetCache
      _queuePreset(path)
      return _presetCache
    }

    function _onPresetLine(line) {
      var s = String(line || "")
      if (_presetBuffer.length + s.length + 1 <= _presetBufferMax) _presetBuffer += s + "\n"
    }

    // Start the preset read (single-flight like _queueGguf; a read already in
    // flight or a cached result is left alone and the caller re-checks on the
    // next refresh). Empty path (no preset configured) is a permanent no-op.
    function _queuePreset(path) {
      if (path === "") return
      if (_presetCache !== null) return
      if (_presetPath !== "" || presetProcess.running) return
      _presetPath = path
      _presetBuffer = ""
      launch(presetProcess, presetWatchdog)
    }

    function _finishPreset() {
      var raw = _presetBuffer.trim()
      _presetBuffer = ""
      _presetPath = ""
      try {
        _presetCache = _parseIniLines(raw)
      } catch (e) {
        _presetCache = null
      }
      if (_presetCache !== null) {
        _applyPresetToRunning()
        // Consumer A: service stopped, the preset is the only model list source.
        if (!root.running) models = _presetModels()
      }
    }

    // Service-stopped available list (Consumer A): every non-[*] section
    // carrying a `model =` key becomes an entry named after the file's basename;
    // the section's (or [*]'s) `n-gpu-layers` is shown as its preset intent.
    // Bounded by maxModels; unknown preset → empty list (the panel just shows
    // "no models").
    function _presetModels() {
      var preset = _presetCache
      if (!preset || typeof preset !== "object") return []
      var out = []
      var globals = preset["*"]
      var keys = Object.keys(preset)
      for (var i = 0; i < keys.length && out.length < maxModels; i++) {
        if (keys[i] === "*") continue
        var sec = preset[keys[i]]
        if (!sec || typeof sec !== "object") continue
        var model = sec["model"]
        if (model === undefined || String(model).trim() === "") continue
        var ngl = sec["n-gpu-layers"]
        if ((ngl === undefined || String(ngl).trim() === "") && globals) {
          ngl = globals["n-gpu-layers"]
        }
        var nglStr = (ngl === undefined) ? "" : String(ngl).trim()
        var segments = String(model).split("/")
        var base = segments[segments.length - 1] || String(model)
        out.push({
          name: truncate(base || "Unknown model", 128),
          id: truncate(String(model), 128),
          size: "",
          modified: "",
          isCloud: false,
          preset: true,
          presetIntent: nglStr !== ""
            ? "preset intent: " + nglStr + " GPU layers"
            : "in preset",
          presetPath: String(model)
        })
      }
      return out
    }

    // Consumer B: resolve the layer split from the preset when the API left ngl
    // unset (global-default presets such as `fit = on` never surface in
    // status.args). Exact section (by model file path) wins over [*] globals.
    // Only validated tokens (all/N/auto) apply; a resolved value lands on the
    // entry as exact (source "preset", same tier as "api") in the display.
    function _applyGgufPresetSplit(entry) {
      if (!entry || entry.modelPath === "" || entry.mainGpu !== null) return false
      if (entry.ngl !== "" && entry.ngl !== "auto") return false
      var preset = _parsePreset(root.presetPath)
      if (!preset || typeof preset !== "object") return false
      var sec = preset[_iniSectionKey(entry.modelPath)]
      var nglVal = (sec && sec["n-gpu-layers"] !== undefined)
        ? sec["n-gpu-layers"]
        : (preset["*"] ? preset["*"]["n-gpu-layers"] : "")
      var s = String(nglVal == null ? "" : nglVal).trim()
      if (s === "" || !/^(all|[0-9]+|auto)$/.test(s)) return false
      var mtp = (isFinite(entry.mtpLayers) && entry.mtpLayers > 0) ? entry.mtpLayers : 0
      var total = (isFinite(entry.totalLayers) && entry.totalLayers > 0)
        ? entry.totalLayers
        : (isFinite(entry.mainLayers) && entry.mainLayers > 0 ? entry.mainLayers + mtp : -1)
      var split = _mtpSplit(s, total, mtp)
      if (split.mainGpu === null) return false
      entry.mainGpu = split.mainGpu
      entry.mainCpu = split.mainCpu
      entry._gpuSplitSource = "preset"
      entry.ngl = s   // resolve the intent for display
      return true
    }

    // Effective preset section for a loaded entry: the model's own section
    // (keyed by model FILE path) merged over the [*] globals, so reading
    // `n-gpu-layers` matches _applyGgufPresetSplit semantics (section wins,
    // globals fall back). null when no preset is cached and when neither the
    // section nor a globals block exists.
    function _presetSectionFor(entry) {
      var preset = _parsePreset(root.presetPath)
      if (!preset || typeof preset !== "object") return null
      var key = (entry && entry.modelPath) ? _iniSectionKey(entry.modelPath) : ""
      var merged = {}
      var globals = preset["*"]
      if (globals && typeof globals === "object") {
        var gks = Object.keys(globals)
        for (var gi = 0; gi < gks.length; gi++) merged[gks[gi]] = globals[gks[gi]]
      }
      var sec = (key !== "" && preset[key]) ? preset[key] : null
      if (sec && typeof sec === "object") {
        var sks = Object.keys(sec)
        for (var si = 0; si < sks.length; si++) merged[sks[si]] = sec[sks[si]]
      }
      return Object.keys(merged).length > 0 ? merged : null
    }

    // A preset that landed AFTER entries were resolved re-runs the cached-GGUF
    // derivation so entries waiting on a mainGpu can pick up the preset split
    // without waiting for the next refresh cycle to re-fire their own read.
    function _applyPresetToRunning() {
      var arr = runningModels || []
      var changed = false
      for (var i = 0; i < arr.length; i++) {
        var e = arr[i]
        if (!e || e.modelPath === "") continue
        var g = _ggufCache[e.modelPath]
        if (g === undefined) continue
        var before = e.mainGpu
        _applyGguf(e, g)
        if (e.mainGpu !== before) changed = true
      }
      if (changed) runningModels = arr.slice()
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
      // The store is the resolver's own state, keyed by path: prune to the loaded
      // set, then let tier 1 offer its readings. Tier 1 runs FIRST here so the
      // values it commits are already whole (a _applyGguf above may have filled a
      // field this poll did not carry) and the derivations that settle below see
      // the API flags. Tiers 3 and 4 follow: both are refresh-rate sources that
      // never wait for a header.
      _pruneStores(out)
      _applyTier1(out)
      for (var t3i = 0; t3i < out.length; t3i++) _applyTier3(out[t3i], null)
      _applyTier4(out)
      // Tier 6 (the engine's own KV accounting) and tier 5 (the projection
      // runner) are QUEUED here rather than in the loop above: both read the
      // store, and both settle permanently when an input is missing, so a queue
      // that ran before tier 1 committed would judge them against an empty store.
      // On a model's very first poll that is the only poll they get. The probe's
      // gate would merely skip and retry a poll later; the fit's would answer
      // "no projection point" for a model that was about to have one, and that
      // answer is permanent.
      for (var qi = 0; qi < out.length; qi++) {
        var qe = out[qi]
        if (!qe || qe.modelPath === "") continue
        // Tier 6 runs off the API-reported flags (context size, cache dtypes,
        // ubatch, parallel) because those, not the header, define the allocation.
        _queueKvProbe(qe)
        // Tier 5. Queued, not called: the gate is inside _queueKvFit, because a
        // process per model per refresh is the failure mode this whole tier has
        // to be able to decline.
        _queueKvFit(qe)
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
  // id_task change between polls) — never backwards.
  //
  // The /slots poll is no longer only an idle-tracking source: its `n_ctx` is
  // tier 1's exact, authoritative answer for the ALLOCATED context, which argv
  // cannot give — `--ctx-size 0` means "let fit decide", and this machine's
  // `qwen3.8-27b-fast` really does report a resolved 102912. So the poll runs
  // whenever a model is loaded, with auto-unload on or off; only the activity
  // bookkeeping is conditional on it.
  function _syncIdleTracking(firstLoadedId) {
    var id = String(firstLoadedId == null ? "" : firstLoadedId)
    if (!/^[A-Za-z0-9._\-/]+$/.test(id)) id = ""
    if (id === "") {
      _resetIdleTracking()
      return
    }
    if (id !== _slotsModelId) {
      _slotsModelId = id
      _lastSig = ""
      _lastActivityMs = (unloadInactivitySec > 0) ? Date.now() : -1
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
      // Tier 5 Consumer A: llama.cpp stopped, no API answers — the models.ini
      // preset is the only model list source (sections + their configured
      // intent). Queues the single-flight read; _finishPreset republishes the
      // list when it lands.
      if (backend === "llama.cpp") {
        _queuePreset(root.presetPath)
        models = _presetModels()
      }
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
          // n_params (bare param count) is the Tier-1 exact field the llama.cpp
          // /v1/models meta block actually serves (n_vocab/n_ctx_train exist too
          // but are informational and unused here). The gguf ftype is NOT in the
          // API (upstream confirmed) — it lands via _applyGguf from the GGUF
          // header (Tier 2). Coerced to -1 when not finite/negative so the
          // display layer's num()/"—" keeps working.
          var nParams = parseInt(meta.n_params, 10)
          if (!isFinite(nParams) || nParams < 0) nParams = -1
          var parsed = _parseLlamaArgs(m.status.args)
          _psModels.push({
            name: truncate(pathParts[pathParts.length - 1] || "Unknown model", 128),
            id: truncate(m.id || "", 64),
            size: sizeBytes > 0 ? root.formatGB(sizeBytes) : "",
            sizeBytes: sizeBytes,
            processor: truncate(m.status.processor || m.status.backend || "CPU", 32),
            context: ctxLen > 0 ? String(ctxLen) : "",
            contextLen: ctxLen,
            // ftype = gguf ftype enum (-1 = unknown, "—"); filled by _applyGguf
            // from the GGUF header's general.file_type (Tier 2), not the API.
            ftype: -1,
            nParams: nParams,    // total params (excl. b-tensors), Tier 1
            modelPath: parsed.model,
            ngl: parsed.ngl,
            draftPath: parsed.draftPath,
            nglDraft: parsed.nglDraft,
            specType: parsed.specType,
            cacheK: parsed.cacheK,
            cacheV: parsed.cacheV,
            noKvOffload: parsed.noKvOffload,
            ubatch: parsed.ubatch,
            parallel: parsed.parallel,
            swaFull: parsed.swaFull === true,
            noKvUnified: parsed.noKvUnified === true,
            _gpuSplitSource: "api",  // "api" | "probe" | "preset" | null
            totalLayers: -1,
            mainLayers: -1,
            mtpLayers: 0,
            mtpSizeBytes: -1,
            draftSizeBytes: -1,
            mainGpu: null,
            mainCpu: null,
            mtpGpu: 0,
            mtpCpu: 0,
            kvCacheBytes: -1,      // Tier 4: derived from the GGUF header
            kvBytesExact: -1,      // tier 6: llama.cpp's own accounting
            kvLayersExact: -1,     //   ...including how many layers it cached
            computeBytes: -1,      //   device graph reserve, same source
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
  // ── Tier 6: engine KV accounting probe ───────────────────────────
  // One short `llama-cli` run per (model, KV-flag signature) answers what no
  // file header can: the exact KV allocation this engine actually builds for
  // this architecture, at this context size, with these cache dtypes. llama.cpp
  // prints it in its own startup log, so we read its numbers rather than
  // re-deriving its architecture rules here:
  //   llama_kv_cache: size = 2720.00 MiB (262144 cells, 5 layers, 1/1 seqs),
  //                          K (q8_0): 1360.00 MiB, V (q8_0): 1360.00 MiB
  //   llama_kv_cache:      CPU KV buffer size = 2720.00 MiB
  //   sched_reserve:      CUDA0 compute buffer size = 1887.86 MiB
  // The cache SIZE does not depend on the device, so the probe runs with -ngl 0
  // (nothing touches the GPU); the per-line device tags it prints are the probe's
  // own, never the running worker's, and are therefore not used for placement.
  // Cache results per signature and never re-probe: one 3-second run per model,
  // not one per refresh.

  property var _kvProbeCache: ({})      // signature -> result | false (tried, no answer)
  property var _kvProbeQueue: []        // entries waiting; one probe runs at a time
  property string _kvProbePath: ""      // model of the probe in flight
  property string _kvProbeSignature: "" // its signature (keyed into _kvProbeCache)
  property string _kvProbeBuffer: ""
  property var _kvProbeArgvList: []     // full argv after the script's $1..$3
  property real _kvProbeModelBytes: 0   // model size, for the address-space cap
  property real _kvProbeKvGuess: 0      // best KV estimate, for the same cap
  readonly property int _kvProbeBufferMax: 262144

  function _kvProbeNum(v, fallback) {
    var n = parseInt(String(v == null ? "" : v), 10)
    return isFinite(n) && n >= 0 ? n : fallback
  }

  // Everything that can change the allocation the engine will build. Also the
  // cache key, so a context-size or dtype change re-probes and nothing else does.
  function _kvProbeSignatureFor(entry) {
    var e = entry || {}
    var path = String(e.modelPath || "")
    if (path === "") return ""
    return path + "|" + _kvProbeNum(e.contextLen, 0) + "|" + _kvProbeNum(e.ubatch, 512)
      + "|" + _kvProbeNum(e.parallel, 1) + "|" + String(e.cacheK || "")
      + "|" + String(e.cacheV || "") + "|" + (e.swaFull === true ? "1" : "0")
      + "|" + (e.noKvUnified === true ? "1" : "0")
  }

  // Only the flags that can change the KV allocation. Deliberately omitted:
  // the draft model (it has its own, smaller context), offload counts and
  // fit/device settings (they change WHERE the cache lands, not its size — that
  // is placement's question, answered by measurement), and every server flag
  // (host/port/api-key/jinja/mmproj). Prompt and single-turn are needed to make
  // the process build a context and exit instead of sitting in its REPL.
  function _kvProbeArgv(entry) {
    var e = entry || {}
    // -ngl 0 keeps the WEIGHTS off the device; -dev none additionally keeps the
    // graph/compute buffers off it. Only the first was passed, so the probe still
    // tried to cudaMalloc its compute reserve — measured 1,537 MiB against the
    // live qwen3.6-35b-a3b worker — and failed there, exiting non-zero. That is
    // both a needless allocation of the user's VRAM and, because the probe
    // inspects models that are already loaded, a failure on the common path.
    // Cache size is device-independent, so there is nothing to gain by touching
    // the GPU at all.
    var a = ["--verbose", "--no-warmup", "-st", "-n", "0", "-p", "x", "-ngl", "0", "-dev", "none"]
    var ctx = _kvProbeNum(e.contextLen, 0)
    if (ctx > 0) a.push("-c", String(ctx))
    var ub = _kvProbeNum(e.ubatch, 0)
    if (ub > 0) a.push("-b", String(ub), "-ub", String(ub))
    var np = _kvProbeNum(e.parallel, 0)
    if (np > 0) a.push("-np", String(np))
    var ck = String(e.cacheK || ""), cv = String(e.cacheV || "")
    if (ck !== "") a.push("--cache-type-k", ck)
    if (cv !== "") a.push("--cache-type-v", cv)
    if (e.swaFull === true) a.push("--swa-full")
    if (e.noKvUnified === true) a.push("--no-kv-unified")
    if (e.noKvOffload === true) a.push("--no-kv-offload")
    return a
  }

  function _queueKvProbe(entry) {
    if (kvProbe === "off") return
    if (backend !== "llama.cpp") return
    var sig = _kvProbeSignatureFor(entry)
    if (sig === "") return
    // Need-gating: the oracle is 3-45 s of subprocess, so it runs only for a
    // shape the header could not describe or could not prove block-aligned. A
    // described, aligned shape is settled by derivation and must never pay for
    // the probe — which is the whole reason `kvDescribed`/`kvBlockAligned` are
    // committed rather than kept private.
    var st = _storeFor(entry.modelPath)
    if (st && !checkTier6Values(st)) return
    if (_kvProbeCache[sig] !== undefined) return          // known: exact or already failed
    if (_kvProbeSignature === sig) return                 // already queued/running
    for (var i = 0; i < _kvProbeQueue.length; i++)
      if (_kvProbeSignatureFor(_kvProbeQueue[i]) === sig) return
    var q = _kvProbeQueue.slice()
    q.push(entry)
    _kvProbeQueue = q
    _pumpKvProbe()
  }

  function _pumpKvProbe() {
    if (kvProbeProcess.running) return
    if (_kvProbeQueue.length === 0) return
    var q = _kvProbeQueue.slice()
    var entry = q.shift()
    _kvProbeQueue = q
    var sig = _kvProbeSignatureFor(entry)
    if (sig === "" || _kvProbeCache[sig] !== undefined) { _pumpKvProbe(); return }
    _kvProbeSignature = sig
    _kvProbePath = String(entry.modelPath || "")
    _kvProbeArgvList = ["-m", _kvProbePath].concat(_kvProbeArgv(entry))
    _kvProbeModelBytes = (Number(entry.sizeBytes) > 0) ? Number(entry.sizeBytes) : 0
    _kvProbeKvGuess = (Number(entry.kvBytesExact) > 0) ? Number(entry.kvBytesExact)
      : ((Number(entry.kvCacheBytes) > 0) ? Number(entry.kvCacheBytes) : 0)
    _kvProbeBuffer = ""
    launch(kvProbeProcess, kvProbeWatchdog)
  }

  // "llama_kv_cache: size = 2720.00 MiB (262144 cells,   5 layers,  1/1 seqs), K (q8_0): ..."
  // The total is read first so a cache with no V (MLA) still parses; only it is
  // used. Bytes are as precise as the log itself: llama.cpp prints MiB with two
  // decimals, so each cache carries at most ~5 KiB of print rounding. That is a
  // measurement of the engine's own allocation, not a derivation, so it keeps
  // the exact (unmarked) rendering.
  function _parseKvProbeLine(line) {
    var s = String(line || "")
    if (s.indexOf("llama_kv_cache:") < 0 && s.indexOf("sched_reserve:") < 0) return null
    var m = /llama_kv_cache:\s+size\s*=\s*([0-9.]+)\s*MiB\s*\(\s*([0-9]+)\s*cells,\s*([0-9]+)\s*layers/
    var hit = m.exec(s)
    if (hit) {
      var mib = parseFloat(hit[1])
      if (isFinite(mib) && mib > 0) {
        return { kind: "kv", bytes: Math.round(mib * 1048576),
                 layers: parseInt(hit[3], 10) || 0 }
      }
      return null
    }
    // sched_reserve: <device> compute buffer size = <n> MiB — the graph reserve,
    // so a VRAM split estimate can subtract a real number instead of assuming
    // one. The device tag is kept because llama.cpp reserves on the host side
    // too (measured on gemma-4-26b: `CUDA0 compute buffer size = 1887.86 MiB`
    // alongside `CUDA_Host compute buffer size = 272.30 MiB`), and only the
    // device one is subtracted from device memory — the caller drops CPU and
    // *_Host tags, so a host reserve can never be charged to VRAM.
    var c = /sched_reserve:\s+(\S+)\s+compute buffer size\s*=\s*([0-9.]+)\s*MiB/
    var ch = c.exec(s)
    if (ch) {
      var cm = parseFloat(ch[2])
      if (isFinite(cm) && cm > 0) {
        return { kind: "compute", dev: ch[1], bytes: Math.round(cm * 1048576) }
      }
    }
    return null
  }

  function _onKvProbeLine(line) {
    var s = String(line || "")
    // Buffering is for diagnostics only and stops at the cap; PARSING never
    // does. A verbose gemma-4 run is ~224 KiB against a 256 KiB cap and prints
    // the cache blocks twice, and an early `return` on overflow would have
    // dropped the accounting lines along with the log text — turning a full
    // answer into a silent partial one.
    if (_kvProbeBuffer.length + s.length + 1 <= _kvProbeBufferMax) _kvProbeBuffer += s + "\n"
    var rec = _parseKvProbeLine(s)
    if (!rec) return
    var acc = _kvProbeAcc
    // Self-healing fold: these functions are contractually total (a surprising
    // accumulator must never throw mid-probe), so a state missing the dedupe
    // bookkeeping is repaired here rather than assumed.
    if (!acc.blocks) acc.blocks = []
    if (!acc.computeSeen) acc.computeSeen = []
    if (!acc.compute) acc.compute = ({})
    if (rec.kind === "kv") {
      // llama.cpp logs each cache block TWICE (once as the context is being set
      // up and once when it is populated): gemma-4-26b emits its 5-layer and
      // 25-layer blocks once each, then both again verbatim. Summing every line
      // would double the answer, so blocks are folded by identity — two blocks
      // with the same byte total AND layer count are the same allocation logged
      // twice, while genuinely distinct caches (e.g. a main + spec context)
      // differ and both still count.
      var key = rec.bytes + ":" + rec.layers
      if (acc.blocks.indexOf(key) < 0) {
        acc.blocks = acc.blocks.concat([key])
        acc.kvBytes += rec.bytes
        if (rec.layers > 0) acc.kvLayers += rec.layers
      }
    } else if (rec.kind === "compute") {
      // Per device, de-duplicated by value (the same reserve is logged once at
      // setup and again at teardown), and never counting a host-side reserve:
      // `CPU` and `CUDA_Host` are RAM, and charging them to VRAM would make the
      // split estimate under-count GPU layers.
      var dev = String(rec.dev || "")
      if (dev !== "CPU" && dev.indexOf("_Host") < 0) {
        if (acc.computeSeen.indexOf(dev + ":" + rec.bytes) < 0) {
          acc.computeSeen = acc.computeSeen.concat([dev + ":" + rec.bytes])
          acc.compute[dev] = (acc.compute[dev] || 0) + rec.bytes
        }
      }
    }
  }

  property var _kvProbeAcc: ({ kvBytes: 0, kvLayers: 0, computeBytes: -1, blocks: [], compute: ({}), computeSeen: [] })

  // Exact KV bytes for the signature, or false when the probe could not answer
  // at all (no llama-cli, watchdog, or a run that never reached a cache).
  // false is cached too, so a broken probe is not retried every refresh; the
  // header derivation then answers instead.
  //
  // The two numbers in a probe result are published under DIFFERENT contracts,
  // because they become known at different points in the run and only one of
  // them depends on the run finishing:
  //
  //   kvBytes  Published whenever a positive `llama_kv_cache: size` line was
  //            folded — whatever the child went on to do. That line is emitted
  //            by llama_kv_cache's constructor once the allocation is fully
  //            sized (it is the sum of ggml_nbytes() over the built tensors), so
  //            it is a pure function of the hparams and cparams the probe passed
  //            in, not a measurement of an inference that ran. Gating it on a
  //            clean exit threw away correct answers: `-ngl 0` offloads the
  //            weights but leaves the GRAPH reserve on the GPU, so probing a
  //            model that is already loaded died in ggml_gallocr_reserve_n_impl
  //            ~1.4 s AFTER printing both `llama_kv_cache: size` lines, and the
  //            result was cached as `false` for the rest of the session.
  //   computeBytes
  //            Still requires a clean exit. `sched_reserve` is a forward-looking
  //            reservation for a graph that may never have been built, so a run
  //            that died inside the reserve has no usable number — and
  //            _estimateSplitFromProbes derives the device split from it. It
  //            stays -1 (unknown, and already handled as such) in that case.
  //
  // The pre-flight gate in kvProbeScript is unaffected: it refuses BEFORE the
  // engine starts, so a model that cannot fit is never allocated for at all and
  // prints no size line to fold.
  function _finishKvProbe(ok) {
    var sig = _kvProbeSignature
    var acc = _kvProbeAcc
    _kvProbeAcc = { kvBytes: 0, kvLayers: 0, computeBytes: -1, blocks: [], compute: ({}), computeSeen: [] }
    _kvProbeSignature = ""
    _kvProbePath = ""
    _kvProbeArgvList = []
    if (sig === "") { _pumpKvProbe(); return }
    var res = null
    if (acc.kvBytes > 0) {
      var compute = -1
      if (ok === true) {
        for (var d in acc.compute) {
          if (compute < 0) compute = 0
          compute += acc.compute[d]
        }
      }
      res = { kvBytes: acc.kvBytes, kvLayers: acc.kvLayers, computeBytes: compute }
    }
    _kvProbeCache[sig] = res === null ? false : res
    _applyKvProbeResult(sig, res)
    _pumpKvProbe()
  }

  function _applyKvProbeResult(sig, res) {
    if (!res) return
    var arr = runningModels || []
    var changed = false
    for (var i = 0; i < arr.length; i++) {
      var e = arr[i]
      if (!e || _kvProbeSignatureFor(e) !== sig) continue
      e.kvBytesExact = res.kvBytes
      e.kvLayersExact = res.kvLayers
      e.computeBytes = res.computeBytes
      // The exact cache size (and the device graph reserve) sharpen the
      // measured split estimate, so recompute it now that they are known.
      _applyProbeSplit(e, e.totalLayers)
      changed = true
      // Tier 6 on the store: the engine's own accounting is exact, and it is the
      // fallback producer for a shape the header could not describe.
      var st = _storeFor(e.modelPath)
      if (st) {
        _t6(st, "kvBytes", res.kvBytes)
        _settle(st)
      }
    }
    if (changed) runningModels = arr.slice()
  }

  // ── Tier 5: engine projection (llama-fit-params) ────────────────────
  //
  // Three fields, and only three: kvGpuBytes, kvCpuBytes, computeBytes. It does
  // NOT commit weightGpu/weightCpu (those are derivations over coreSize and the
  // split — a projection reporting its own input back as a finding) and it does
  // NOT commit kvBytes (that belongs to the tier-2 derivation and tier 6, and
  // freezing it here would pin it at a 1 MiB-rounded projection).
  property bool _fitProbed: false
  property bool _tier5Available: true     // optimistic until exit 97 says otherwise
  property var _kvFitCache: ({})          // signature -> { ok, parsed }
  property var _kvFitQueue: []            // model paths waiting, FIFO
  property int _kvFitRunning: 0           // single-flight guard
  property string _kvFitPath: ""          // model of the projection in flight
  property string _kvFitSig: ""
  property int _kvFitNgl: -1
  property var _kvFitTail: []             // the args that vary, after the model
  property string _kvFitBuffer: ""

  // The tool's cache dtypes. An invalid value is an immediate exit-1 parse error
  // that would be indistinguishable from a real abort, so an unsupported dtype is
  // DROPPED rather than passed — the projection then sizes at f16, which is
  // visibly an estimate rather than a hard failure.
  readonly property var fitCacheTypes: ["f32", "f16", "bf16", "q8_0", "q4_0",
                                        "q4_1", "iq4_nl", "q5_0", "q5_1"]

  function _fitCacheTypeOk(v) {
    var s = String(v == null ? "" : v).trim()
    if (s === "") return false
    for (var i = 0; i < fitCacheTypes.length; i++)
      if (fitCacheTypes[i] === s) return true
    return false
  }

  function _fitInt(v) {
    var s = String(v == null ? "" : v).trim()
    if (!/^-?[0-9]+$/.test(s)) return null
    var n = parseInt(s, 10)
    return isFinite(n) ? n : null
  }

  // Which N to decompose at. Cheapest definitive first, and tier 5 NEVER chooses
  // one -- with `--fit off` it has no offload count of its own, only the one it is
  // given. `all` becomes the layer count rather than the literal token, because
  // `-ngl` must always be an exact integer.
  function _fitNglFor(store) {
    if (!store) return null
    var n = store.get("ngl")
    if (n && n.state !== stateEnum.PENDING && n.state !== stateEnum.ABSENT) {
      var t1 = _fitInt(n.value)                       // "auto" → null, correctly
      if (t1 !== null && t1 >= 0) return t1
    }
    var p = store.get("presetNgl")
    if (p && p.state !== stateEnum.PENDING && p.state !== stateEnum.ABSENT) {
      var tok = String(p.value == null ? "" : p.value).trim()
      if (tok === "all") {
        var tl = store.get("totalLayers")
        if (tl && tl.state === stateEnum.EXACT) return _fitInt(tl.value)
      } else {
        var t3 = _fitInt(tok)
        if (t3 !== null && t3 >= 0) return t3
      }
    }
    // The measured estimate is the only N there usually is: tier 5 is a
    // PRECONDITION of the estimate, not a fallback after it, because there is no
    // N to fail from when nothing else supplied one.
    var g = store.get("mainGpu")
    if (g && g.state === stateEnum.ESTIMATED) {
      var est = _fitInt(g.value)
      if (est !== null && est >= 0) return est
    }
    return null
  }

  function _fitDtype(store, name) {
    var e = store ? store.get(name) : null
    var v = (e && e.state !== stateEnum.PENDING && e.state !== stateEnum.ABSENT)
      ? e.value : ""
    return _fitCacheTypeOk(v) ? String(v).trim() : ""
  }

  function _fitCtxFor(store) {
    var e = store ? store.get("contextLen") : null
    var n = (e && e.state !== stateEnum.PENDING && e.state !== stateEnum.ABSENT)
      ? parseInt(String(e.value), 10) : NaN
    return isFinite(n) && n > 0 ? n : 0
  }

  // Everything that changes the answer, and therefore the cache key: the same
  // shape as _kvProbeSignatureFor. A model is re-projected only when one of these
  // actually moved.
  function _fitSignatureFor(path) {
    var st = _storeFor(path)
    var n = st ? _fitNglFor(st) : null
    return [String(path), (n === null ? "none" : n),
            _fitDtype(st, "cacheK"), _fitDtype(st, "cacheV"),
            _fitCtxFor(st)].join("|")
  }

  // The tail the wrapper receives after `bash -c kvFitScript dash`:
  // $1 binary, $2 -ngl, $3 -m model, then whatever varies. --fit off,
  // --fit-print on and -ngl are the script's, deliberately.
  function _buildFitArgv(modelPath, ngl, cacheK, cacheV, ctx) {
    var a = [kvFitBinary, String(ngl), String(modelPath)]
    if (_fitCacheTypeOk(cacheK)) a.push("-ctk", String(cacheK).trim())
    if (_fitCacheTypeOk(cacheV)) a.push("-ctv", String(cacheV).trim())
    if (ctx > 0) a.push("-c", String(ctx))
    // NOT passed: -fitt/--fit-target (its default is a margin and would inflate
    // the projection) and --flash-attn (the draft's recorded abort).
    return a
  }

  // ── The output format, captured on this machine (llama.cpp b10729) ────
  //   llama_fit_params: printing estimated memory in MiB to stdout (device, model, context, compute) ...
  //   CUDA0 3997 5160 1860
  //   Host 7140 11373 286
  // Integer MiB per cell, devices CUDA0 (and CUDA1 on a second card) plus Host.
  // A 4096-token f16 cache printing `context` = 2 is the proof that the column is
  // the KV bytes and not something else.
  function _fitIsPreamble(s) {
    return String(s == null ? "" : s).trim().indexOf("llama_fit_params:") === 0
  }

  // A total/summary row is recognised so it can never be double-counted with the
  // per-device rows: a total that also summed the devices would be silently wrong
  // rather than loudly wrong.
  function _fitIsTotalRow(dev) {
    var s = String(dev).toLowerCase()
    return s === "total" || s === "totals" || s === "all" || s === "sum"
  }

  // Only `Host` is host. An UNRECOGNISED name defaults to the device side, and
  // the asymmetry is deliberate: a device row mis-counted as host is an
  // unrecoverable split error, while a host row mis-counted as a device shows up
  // immediately as an implausible device total.
  function _fitIsHost(dev) {
    return String(dev) === "Host"
  }

  function _fitRowMib(s) {
    if (!/^[0-9]+(\.[0-9]+)?$/.test(String(s))) return null
    var m = parseFloat(String(s))
    return isFinite(m) ? m : null
  }

  // One line in, one row out, or null. A short row or a non-numeric cell is
  // SKIPPED, never zero-filled: an invented 0 would read as "nothing on the
  // device" and is worse than no row at all.
  function _parseFitRow(line) {
    var s = String(line == null ? "" : line).trim()
    if (s === "" || _fitIsPreamble(s)) return null
    var t = s.split(/\s+/)
    if (t.length < 4) return null
    if (_fitIsTotalRow(t[0])) return null
    var m = _fitRowMib(t[1]), c = _fitRowMib(t[2]), k = _fitRowMib(t[3])
    if (m === null || c === null || k === null) return null
    return { device: t[0], host: _fitIsHost(t[0]),
             modelMiB: m, contextMiB: c, computeMiB: k }
  }

  // The ONLY MiB→bytes conversion in the tier-5 path. Everything downstream — the
  // store, the ladder, the per-device totals — is bytes, exactly as tier 6 does
  // it. Two unit systems meeting twice is how the draft ended up comparing MiB
  // against serviceVramBytes.
  function _fitMibToBytes(v) { return Math.round(v * 1048576) }

  function parseFitParams(text) {
    var lines = String(text == null ? "" : text).split("\n")
    var rows = []
    for (var i = 0; i < lines.length; i++) {
      var r = _parseFitRow(lines[i])
      if (r) rows.push(r)
    }
    if (rows.length === 0) return null
    var deviceRows = [], hostRows = []
    var dm = 0, dc = 0, dk = 0, hm = 0, hc = 0, hk = 0
    for (var j = 0; j < rows.length; j++) {
      if (rows[j].host) {
        hostRows.push(rows[j])
        hm += rows[j].modelMiB; hc += rows[j].contextMiB; hk += rows[j].computeMiB
      } else {
        deviceRows.push(rows[j])
        dm += rows[j].modelMiB; dc += rows[j].contextMiB; dk += rows[j].computeMiB
      }
    }
    return { rows: rows, deviceRows: deviceRows, hostRows: hostRows,
             deviceTotal: { model: _fitMibToBytes(dm), context: _fitMibToBytes(dc),
                            compute: _fitMibToBytes(dk) },
             hostTotal:   { model: _fitMibToBytes(hm), context: _fitMibToBytes(hc),
                            compute: _fitMibToBytes(hk) } }
  }

  function _declineTier5(store) {
    if (!store) return
    var names = capabilities[5]
    for (var i = 0; i < names.length; i++) _t5(store, names[i], null)
    _settle(store)
  }

  // Gated, not unconditional: an unguarded refresh spawns a process per model per
  // refresh, and every model asks for its own run.
  function _queueKvFit(entry) {
    if (!entry || entry.modelPath === "") return
    if (backend !== "llama.cpp") return
    var st = _storeFor(entry.modelPath)
    if (!st) return
    if (_tier5Available === false) { _declineTier5(st); return }
    if (!checkTier5Values(st)) return                  // nothing outstanding
    var ngl = _fitNglFor(st)
    if (ngl === null) { _declineTier5(st); return }   // no projection point
    var sig = _fitSignatureFor(entry.modelPath)
    if (_kvFitCache[sig] !== undefined) return         // known: answer or declined
    if (_kvFitRunning === 1 && _kvFitSig === sig) return
    for (var i = 0; i < _kvFitQueue.length; i++)
      if (_kvFitQueue[i] === entry.modelPath) return
    var q = _kvFitQueue.slice()
    q.push(entry.modelPath)
    _kvFitQueue = q
    _pumpKvFit()
  }

  function _pumpKvFit() {
    if (_kvFitRunning === 1) return
    while (_kvFitQueue.length > 0) {
      var q = _kvFitQueue.slice()
      var path = q.shift()
      _kvFitQueue = q
      var st = _storeFor(path)
      if (!st) continue
      var sig = _fitSignatureFor(path)
      if (sig === "" || _kvFitCache[sig] !== undefined) continue
      var ngl = _fitNglFor(st)
      if (ngl === null) { _declineTier5(st); continue }
      _kvFitPath = path
      _kvFitSig = sig
      _kvFitNgl = ngl
      _kvFitTail = _buildFitArgv(path, ngl, _fitDtype(st, "cacheK"),
                                 _fitDtype(st, "cacheV"), _fitCtxFor(st))
      _kvFitBuffer = ""
      _kvFitRunning = 1
      launch(kvFitProcess, kvFitWatchdog)
      return
    }
  }

  function _onFitLine(line) {
    if (_kvFitBuffer.length + String(line).length + 1 <= _kvProbeBufferMax)
      _kvFitBuffer += line + "\n"
  }

  function _finishKvFit(exitCode) {
    var path = _kvFitPath, sig = _kvFitSig, out = _kvFitBuffer
    _kvFitRunning = 0
    _kvFitPath = ""
    _kvFitSig = ""
    _kvFitNgl = -1
    _kvFitTail = []
    _kvFitBuffer = ""
    if (sig === "") { _pumpKvFit(); return }

    // 97 is definitive and permanent: the tool is not installed. Cache it once and
    // decline every tier-5 field for every store, because without that the three
    // fields would hang at `…` forever — the one thing the store must never do.
    if (exitCode === 97) {
      _tier5Available = false
      _fitProbed = true
      var list = runningModels || []
      for (var i = 0; i < list.length; i++)
        _declineTier5(_storeFor(list[i] ? list[i].modelPath : ""))
      _pumpKvFit()
      return
    }

    // Only a clean 0 is a projection; the `timeout` wrapper answers 124 on expiry
    // and 137 after SIGKILL. Everything else — an unknown flag, a backend with no
    // common_fit_print, an out-of-memory abort — is an answer of "no", and there
    // is exactly ONE attempt per signature: a model-header parse plus a fit print
    // is not cheap, so a retry loop only produces a slower panel and a hot loop.
    var parsed = (exitCode === 0) ? parseFitParams(out) : null
    _kvFitCache[sig] = { ok: !!(parsed && parsed.deviceRows.length > 0), parsed: parsed }
    var st = _storeFor(path)
    if (st) {
      if (parsed && parsed.deviceRows.length > 0) {
        _t5(st, "kvGpuBytes", parsed.deviceTotal.context)
        _t5(st, "kvCpuBytes", parsed.hostTotal.context)
        _t5(st, "computeBytes", parsed.deviceTotal.compute)
      } else {
        _t5(st, "kvGpuBytes", null)
        _t5(st, "kvCpuBytes", null)
        _t5(st, "computeBytes", null)
      }
      _settle(st)
    }
    _pumpKvFit()
  }

  // Tier 3: when the API and the preset both left ngl unknown, derive the layer
  // split from measured device memory — the service's per-PID VRAM minus the
  // part of it the KV cache is holding (only when placement is measured, not
  // guessed) and the engine's compute-graph reserve. Re-run whenever a new
  // measurement or a new engine accounting lands, so the estimate tightens
  // instead of being frozen at whatever the first reading happened to be.
  function _applyProbeSplit(entry, total) {
    if (!entry) return
    if (entry.ngl !== "") return
    if (entry._gpuSplitSource === "preset") return
    // A split we already own (Tier 3) may be refreshed; an API/preset one never.
    if (entry.mainGpu !== null && entry._gpuSplitSource !== "probe") return
    var kv = _resolveKvBytes(entry)
    var on = _kvLocationOf(entry.noKvOffload === true, entry.mainGpu, kv.value,
                          _placementMeasurements())
    var probe = _estimateSplitFromProbes(
      entry.sizeBytes > 0 ? entry.sizeBytes : 0, total, serviceVramBytes,
      on === "GPU" ? kv.value : 0, entry.computeBytes)
    if (probe) {
      entry.mainGpu = probe.gpuLayers
      entry.mainCpu = probe.cpuLayers
      entry._gpuSplitSource = "probe"
    }
  }

  // The machine readings placement may be decided from, plus whether they can
  // be attributed to a single model at all. Both probes cover the whole service
  // cgroup, so with more than one model loaded neither reading is this model's.
  function _placementMeasurements() {
    return { memBytes: serviceMemoryBytes, vramBytes: serviceVramBytes,
             sole: (runningModels || []).length === 1 }
  }

  // KV size for an entry, with the tier that answered: tier 6 (the engine's
  // own accounting — exact, no marker) → Tier 4 (derivation from the header,
  // "~") → nothing ("—"). Never a fabricated number.
  function _resolveKvBytes(entry) {
    var e = entry || {}
    if (e.kvBytesExact > 0) return { tier: 3, value: e.kvBytesExact, marker: "" }
    if (e.kvCacheBytes >= 0) return { tier: 4, value: e.kvCacheBytes, marker: "~" }
    return { tier: null, value: -1, marker: "—" }
  }

  //  refresh (no re-read). Unknown/unreadable → the entry keeps -1 ("—").


  property var _ggufCache: ({})   // path -> {bc, hc, hckv, hckvArr, kl, vl, ... arch}
  property string _ggufPath: ""   // path currently being read (single-flight)
  property string _ggufBuffer: ""
  readonly property int _ggufBufferMax: 4096

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
    // Quantization (gguf ftype enum → _ftypeLabel): filled from the header's
    // general.file_type (Tier 2) only when the API hasn't answered (the
    // llama.cpp /v1/models meta block sends no ftype, so the API never beats
    // this in practice; the guard keeps the ladder ordering honest).
    if (entry.ftype < 0 && isFinite(g.ft) && g.ft >= 0) entry.ftype = g.ft
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
    // Tier 5: when the API left ngl unset, resolve the split from the models.ini
    // preset before falling back to the measured-VRAM estimate (Tier 3). A
    // resolved value is EXACT (source "preset", tier above "probe").
    _applyGgufPresetSplit(entry)
    var ctx = (isFinite(entry.contextLen) && entry.contextLen > 0) ? entry.contextLen : -1
    // Tier 4 BLOCK: per-layer KV allocation derived from the header (SWA /
    // recurrent / shared / MLA). Unknown shape → -1, and the engine probe
    // (tier 6) is what answers for architectures whose files don't describe
    // their own layout. _resolveKvBytes picks whichever of the two exists.
    entry.kvCacheBytes = _kvEstimateBytesArch(_buildKvLayers(g, entry.mainLayers, ctx, {
      ubatch: (isFinite(entry.ubatch) && entry.ubatch > 0) ? entry.ubatch : 512,
      parallel: (isFinite(entry.parallel) && entry.parallel > 0) ? entry.parallel : 1,
      swaFull: entry.swaFull === true,
      kvUnified: entry.noKvUnified !== true
    }), _kvDtypeBits(entry.cacheK), _kvDtypeBits(entry.cacheV))
    // Fallback: when ngl is unknown and _mtpSplit returned nulls, estimate from
    // measured device memory (Tier 3). Runs after the KV derivation because it
    // subtracts whatever the cache is holding on the device.
    _applyProbeSplit(entry, total)
    if (entry._gpuSplitSource !== "preset" && entry._gpuSplitSource !== "probe")
      entry._gpuSplitSource = "api"
    _tier2ToEntryStore(entry, g)
  }

  // The header has arrived for this model: park it on the store and let tier 2
  // answer what the file can answer. Separate from the legacy entry fold above so
  // the store never depends on which legacy field happened to be written first.
  function _tier2ToEntryStore(entry, g) {
    var st = _storeFor(entry ? entry.modelPath : "")
    if (!st || !g) return
    st.ctx.gguf = g
    _applyTier2To(st)
    _settle(st)
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
    var st = _storeFor(entry ? entry.modelPath : "")
    if (st) {
      st.ctx.draftGguf = g
      // The draft header supersedes the base header's built-in MTP keys.
      _applyTier2To(st)
      _settle(st)
    }
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
    var arch = "", bc = -1, hc = -1, hckv = -1, hckvArr = null, embd = -1, npl = -1, fai = -1
    var kl = -1, vl = -1, klswa = -1, vlswa = -1, swa = -1, sharedKv = -1
    var swaPattern = -1, swaPatternArr = null, recurrentArr = null
    var kvLoraRank = -1, ropeDim = -1, sz = -1, ft = -1, ok = false
    var lines = raw.split("\n")
    for (var i = 0; i < lines.length; i++) {
      var line = String(lines[i]).trim()
      if (line === "GGUF-OK") { ok = true; continue }
      var eq = line.indexOf("=")
      if (eq <= 0) continue
      var key = line.substring(0, eq)
      var rest = line.substring(eq + 1)
      // Arrays arrive as key=a:<v1>,<v2>,... (head_count_kv, sliding_window_
      // pattern, recurrent_layers); everything else is a scalar.
      if (rest.length > 1 && rest.charAt(0) === "a" && rest.charAt(1) === ":") {
        var parts = rest.substring(2).split(",")
        var arr = []
        for (var p = 0; p < parts.length; p++) {
          var av = parseInt(parts[p], 10)
          if (isFinite(av)) arr.push(av)
        }
        if (key === "head_count_kv") hckvArr = arr
        else if (key === "sliding_window_pattern") swaPatternArr = arr
        else if (key === "recurrent_layers") recurrentArr = arr
        continue
      }
      var val = parseInt(rest, 10)
      if (key === "arch") arch = rest
      else if (key === "block_count") bc = isFinite(val) ? val : -1
      else if (key === "head_count_kv") hckv = isFinite(val) ? val : -1
      else if (key === "head_count") hc = isFinite(val) ? val : -1
      else if (key === "embedding_length") embd = isFinite(val) ? val : -1
      else if (key === "nextn_predict_layers") npl = isFinite(val) ? val : -1
      else if (key === "full_attention_interval") fai = isFinite(val) ? val : -1
      else if (key === "key_length") kl = isFinite(val) ? val : -1
      else if (key === "value_length") vl = isFinite(val) ? val : -1
      else if (key === "key_length_swa") klswa = isFinite(val) ? val : -1
      else if (key === "value_length_swa") vlswa = isFinite(val) ? val : -1
      else if (key === "sliding_window") swa = isFinite(val) ? val : -1
      else if (key === "shared_kv_layers") sharedKv = isFinite(val) ? val : -1
      else if (key === "sliding_window_pattern") swaPattern = isFinite(val) ? val : -1
      else if (key === "kv_lora_rank") kvLoraRank = isFinite(val) ? val : -1
      else if (key === "rope_dimension_count") ropeDim = isFinite(val) ? val : -1
      else if (key === "size") sz = isFinite(val) ? val : -1
      else if (key === "file_type") ft = isFinite(val) ? val : -1
    }
    // Only cache a confirmed GGUF header with a usable layer count.
    if (!ok || bc < 0 || path === "") return
    _ggufCache[path] = {
      arch: arch, bc: bc, hc: hc, hckv: hckv, hckvArr: hckvArr, embd: embd,
      npl: npl, fai: fai, kl: kl, vl: vl, klswa: klswa, vlswa: vlswa,
      swa: swa, sharedKv: sharedKv, swaPattern: swaPattern,
      swaPatternArr: swaPatternArr, recurrentArr: recurrentArr,
      kvLoraRank: kvLoraRank, ropeDim: ropeDim, sz: sz, ft: ft
    }
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
      if (unloadInactivitySec > 0) _lastActivityMs = Date.now()
      return
    }
    // First slot only, and that is not a shortcut: `?model=<id>` filters to that
    // model's slots and they all share one n_ctx.
    _applySlotsContext(_slotsModelId, parseInt(String(slot.n_ctx == null ? "" : slot.n_ctx), 10))
    var proc = (slot.is_processing === true) ? "1" : "0"
    var task = String(slot.id_task == null ? "" : slot.id_task)
    var sig = proc + ":" + task
    if (proc === "1") {
      if (unloadInactivitySec > 0) _lastActivityMs = Date.now()
    } else if (task !== "" && sig !== _lastSig) {
      // id_task advanced since the last poll → a request completed between polls.
      if (unloadInactivitySec > 0) _lastActivityMs = Date.now()
    }
    _lastSig = sig
  }

  // /slots `n_ctx` → tier 1's authoritative contextLen.
  //
  // It supersedes the argv-derived value because argv cannot say what the context
  // ACTUALLY is: `--ctx-size 0` withholds it entirely, and `fit = on` is exactly
  // that case. It is the only tier-1 source that is exact for such a model. When
  // /slots declines (unloaded, no slot), the field is left pending for tier 2 —
  // and NOT filled from the header's trained `context_length`, which is the
  // model's capacity and can exceed the running allocation many times over.
  function _applySlotsContext(id, nCtx) {
    if (id === "" || !(isFinite(nCtx) && nCtx > 0)) return
    var arr = runningModels || []
    for (var i = 0; i < arr.length; i++) {
      var e = arr[i]
      if (!e || String(e.id == null ? "" : e.id) !== id) continue
      var st = _storeFor(e.modelPath)
      if (!st) return
      // A server that reloads at a different resolved context answers with a
      // different n_ctx, and that is a same-tier correction rather than a new
      // answer — which is why this is the one tier-1 field that may revise.
      _t1update(st, "contextLen", Math.round(nCtx))
      _settle(st)
      return
    }
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
    // Every probe completion lands here, which makes it the one place a new
    // measurement has to be projected into the stores. The current loaded set is
    // the argument here: this fires outside the rebuild, so runningModels is
    // current and the sole-attribution fact it carries is the right one.
    _applyTier4(runningModels)
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
      configPresetPath = ""
      unloadInactivitySec = 0
      configValid = true
      configWarning = truncate("Refusing to read config: " + root.configPath + " is a symlink or special file.", 256)
      return
    }
    if (!hasConfig) {
      configHost = "127.0.0.1"
      configPort = 0
      configApiKey = ""
      configPresetPath = ""
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
    var presetFile = ""  // llama.cpp LLAMA_MODELS_PRESET (empty = no preset)
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
          else presetFile = val
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
      configPresetPath = ""
      unloadInactivitySec = 0
      configValid = false
      configWarning = truncate("Invalid " + root.backendDisplayName + " config: " + violations.join("; ") + ".", 256)
      return
    }
    configHost = host
    configPort = port
    configApiKey = apiKey
    configPresetPath = presetFile
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
  // from the instance cgroup's memory.stat: committed, non-reclaimable process
  // memory. The cgroup comes from systemd's ControlGroup, else from the
  // instance's own /proc/<pid>/cgroup (the preset router's workers are in the
  // same cgroup, and memory.stat is hierarchical, so the KV cache on the host
  // is counted). MemoryCurrent is only a last resort because it also counts
  // reclaimable file/page cache (the mmap'd GGUF), which inflates the
  // footprint and double-counts weight pages already held as anon or on the GPU.
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

  // llama.cpp → tier 6 engine KV accounting probe. The model's own
  // KV-relevant flags are replayed against `llama-cli` with -ngl 0 under an
  // address-space cap (kvProbeScript), and llama.cpp's own log lines are parsed
  // for the exact cache bytes, cache layer count and device graph reserve. The
  // model path, every flag and every byte count travel as positional arguments
  // — nothing is ever interpolated into the script — so an untrusted
  // --model value cannot become shell. Never throws: any failure caches "no
  // answer" for that signature and the header derivation answers instead.
  Process {
    id: kvProbeProcess
    running: false
    command: ["timeout", "-k", "2", "" + root.kvProbeTimeoutSec,
              "bash", "-c", root.kvProbeScript, "dash",
              root.kvProbeBinary,
              "" + (root._kvProbeModelBytes > 0 ? root._kvProbeModelBytes : 0),
              "" + (root._kvProbeKvGuess > 0 ? root._kvProbeKvGuess : 0)]
      .concat(root._kvProbeArgvList)
    stdout: SplitParser { onRead: function(line) { root._onKvProbeLine(line) } }
    // llama.cpp logs EVERYTHING — including all of the llama_kv_cache and
    // sched_reserve accounting — on stderr; its stdout carries only the prompt
    // echo and the generated text (measured: 3,116 stderr lines, 32 stdout
    // lines, 0 KV lines on stdout for gemma-4-26b). A stdout-only reader would
    // therefore see nothing at all and the probe would silently never answer,
    // so both channels feed the same fold.
    stderr: SplitParser { onRead: function(line) { root._onKvProbeLine(line) } }
    onExited: function(exitCode) {
      kvProbeWatchdog.stop()
      // The `timeout` wrapper exits 124 on expiry and 137 after SIGKILL; only a
      // clean 0 means llama.cpp got through load, one turn and teardown.
      _finishKvProbe(exitCode === 0)
    }
  }

  // llama.cpp → the model's own memory decomposition at a supplied -ngl
  // (Tier 5). `--fit off --fit-print on` and `-ngl` are inside the script, so
  // the argv below carries only what varies: the binary, the count, the path and
  // the dtypes. One process at a time (llama-fit-params is CPU- and IO-heavy and
  // every model wants its own run); the model path arrives only as a positional
  // argument, so a path with spaces or `;` cannot become shell.
  Process {
    id: kvFitProcess
    running: false
    command: ["timeout", "-k", "2", "" + root.kvFitTimeoutSec,
              "bash", "-c", root.kvFitScript, "dash"].concat(root._kvFitTail)
    stdout: SplitParser { onRead: function(line) { root._onFitLine(line) } }
    stderr: SplitParser { onRead: function(line) { root._onFitLine(line) } }
    onExited: function(exitCode) {
      kvFitWatchdog.stop()
      _finishKvFit(exitCode)
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

  // llama.cpp → bounded models.ini preset read (Tier 5). $1 = preset path,
  // $2 = cap. Reads at most 16 KiB, refuses symlinks/special files; consumes
  // the normalized [section]/key=value stream into _presetCache (single read).
  Process {
    id: presetProcess
    running: false
    command: ["timeout", "-k", "2", "" + processTimeoutSec,
              "bash", "-c", root.modelsIniScript, "dash",
              root._presetPath, "" + root.modelsIniCap]
    stdout: SplitParser { onRead: function(line) { root._onPresetLine(line) } }
    onExited: function(exitCode) {
      presetWatchdog.stop()
      if (exitCode === 0) _finishPreset()
      else _presetBuffer = ""
      _presetPath = ""
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

  // Backup watchdog for the KV probe. Longer than the probe's own `timeout`
  // (which handles the process group) because the probe legitimately takes a
  // few seconds to load a model and build a context.
  Timer {
    id: kvProbeWatchdog
    interval: root.kvProbeWatchdogMs
    repeat: false
    // A probe that overran its timeout is answered as "no answer", not with
    // whatever partial totals it managed to print: half a model's caches is a
    // number that looks right and is wrong. Clearing the accumulator first makes
    // _finishKvProbe cache `false` and hand the field back to the header
    // derivation, and drains the queue so the next model still gets probed.
    onTriggered: {
      reap(kvProbeProcess, kvProbeWatchdog)
      root._kvProbeAcc = { kvBytes: 0, kvLayers: 0, computeBytes: -1, blocks: [], compute: ({}), computeSeen: [] }
      root._finishKvProbe(false)
    }
  }

  // Backup watchdog for the tier-5 projection. Strictly longer than the script's
  // own `timeout`, so `timeout` always wins and this only reaps a wedged child.
  Timer {
    id: kvFitWatchdog
    interval: root.kvFitWatchdogMs
    repeat: false
    onTriggered: {
      reap(kvFitProcess, kvFitWatchdog)
      // A projection that overran its timeout is "no answer", never a partial
      // row: clearing the buffer first makes _finishKvFit decline, which settles
      // the three fields to `—` rather than leaving them at `…`.
      root._finishKvFit(124)
    }
  }

  Timer {
    id: ggufWatchdog
    interval: watchdogMs
    repeat: false
    onTriggered: reap(ggufProcess, ggufWatchdog)
  }

  Timer {
    id: presetWatchdog
    interval: watchdogMs
    repeat: false
    onTriggered: reap(presetProcess, presetWatchdog)
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
