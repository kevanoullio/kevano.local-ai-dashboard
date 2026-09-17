import QtQuick
import Quickshell
import "asserts.js" as A

// Security contract: the embedded bash constants themselves (they ARE the
// security boundary) must keep their safety properties. These checks pin the
// source of truth so any accidental softening fails the suite.
Item {
  id: root
  Component.onCompleted: {
    var s = A.service("@SERVICE_QML_PATH@", root, "llama.cpp")
    var p = s.provisionLlamaScript
    var cw = s.createConfigScript
    var ce = s.createEnvScript
    var ub = s.llamaUnitBody
    var cr = s.configScript
    var ps = s.pkStartScript
    var pt = s.pkStopScript
    var us = s.userStopScript

    // ---- provisioner: pipefail + locking + two-phase consent + rollback ----
    A.ok("prov/pipefail", p.indexOf("set -uo pipefail") !== -1)
    A.ok("prov/flock", p.indexOf("flock -n 9 || exit 60") !== -1)
    A.ok("prov/consent-gate", p.indexOf("exit 64") !== -1 && p.indexOf("SERVICE-UPDATE-REQUIRED") !== -1)
    A.ok("prov/verify", p.indexOf("systemd-analyze --user verify") !== -1)
    A.ok("prov/daemon-reload", p.indexOf("systemctl --user daemon-reload") !== -1)
    A.ok("prov/backup-exists", p.indexOf(".llama.cpp.service.bak") !== -1)
    A.ok("prov/rollback-restore", p.indexOf('mv -f -- "$ud/.llama.cpp.service.bak" "$u"') !== -1)
    A.ok("prov/rollback-remove", p.indexOf('rm -f -- "$u"') !== -1)
    A.ok("prov/env-refuses-link-fifo", p.indexOf('[ -L "$f" ] || [ -p "$f" ]') !== -1)
    A.ok("prov/env-chmod-600", p.indexOf("chmod 600") !== -1)
    A.ok("prov/env-heredoc-standalone", p.indexOf("\nENV\n") !== -1)
    A.ok("prov/unit-heredoc-standalone", p.indexOf("\nUNIT\n") !== -1)
    A.ok("prov/resolves-binary-early", p.indexOf('abs=$(command -v -- "$bin") || exit 40') !== -1)
    A.ok("prov/no-pkexec", p.indexOf("pkexec") === -1)
    A.ok("prov/no-sudo", p.indexOf("sudo") === -1)

    // ---- config writer: create-only / no-follow / atomic / 0600 ----------
    A.ok("writer/pipefail", cw.indexOf("set -o pipefail") !== -1)
    A.ok("writer/parent-refuse", cw.indexOf("exit 55") !== -1)
    A.ok("writer/existing-exit-4", cw.indexOf("exit 4") !== -1)
    A.ok("writer/temp-name", cw.indexOf(".dashboard-config.XXXXXX") !== -1)
    A.ok("writer/atomic-mv", cw.indexOf("mv -f") !== -1)
    A.ok("writer/chmod-600", cw.indexOf("chmod 600") !== -1)
    A.ok("writer/no-pkexec", cw.indexOf("pkexec") === -1)

    // ---- env writer: same guarantees, heredoc content --------------------
    A.ok("envwriter/pipefail", ce.indexOf("set -o pipefail") !== -1)
    A.ok("envwriter/temp-name", ce.indexOf(".llama.env.XXXXXX") !== -1)
    A.ok("envwriter/existing-exit-4", ce.indexOf("exit 4") !== -1)
    A.ok("envwriter/heredoc-standalone", ce.indexOf("\nENV\n") !== -1)
    A.ok("envwriter/chmod-600", ce.indexOf("chmod 600") !== -1)
    A.ok("envwriter/no-pkexec", ce.indexOf("pkexec") === -1)

    // ---- unit template semantics -----------------------------------------
    A.ok("unit/env-file", ub.indexOf("EnvironmentFile=$f") !== -1)
    A.ok("unit/exec-start-abs", ub.indexOf('exec "$abs"') !== -1)
    A.ok("unit/literal-host-token", ub.indexOf("\\${LLAMA_HOST:-127.0.0.1}") !== -1)
    A.ok("unit/literal-port-token", ub.indexOf("\\${LLAMA_PORT:-8080}") !== -1)

    // ---- default env content ---------------------------------------------
    A.ok("defaults/host", s.llamaEnvDefault.indexOf("LLAMA_HOST=127.0.0.1") !== -1)
    A.ok("defaults/apikey-empty", s.llamaEnvDefault.indexOf("LLAMA_API_KEY=") !== -1)
    A.ok("defaults/models-preset", s.llamaEnvDefault.indexOf("LLAMA_MODELS_PRESET=") !== -1)
    A.finish()
  }
}