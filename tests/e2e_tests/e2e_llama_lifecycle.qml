import QtQuick
import Quickshell
import Quickshell.Io
import "asserts.js" as A

// E2E: the full llama.cpp lifecycle against an isolated sandbox driven by the
// plugin's own Service object and the mocked systemd unit. No real machine state
// is touched: readOnly config lives under the sandbox, mock systemctl logs to
// the sandbox mocklog, and the provisioner binary is a no-op mock.
Item {
  id: root
  property var s: null
  property int phase: 0
  property bool s3done: false

  FileView { id: fv; printErrors: false; blockAllReads: true }
  function readFile(path) { fv.path = ""; fv.path = path; return fv.text() }
  function sandboxBase() { return s.configPath.replace(/\/plugin\/configs\/.*/, "") }
  function unitPath() { return sandboxBase() + "/home/.config/systemd/user/llama.cpp.service" }
  function envPath()  { return s.configPath }
  function mocklog()  { return sandboxBase() + "/mocklog" }

  Component.onCompleted: {
    s = A.service("@SERVICE_QML_PATH@", root, "llama.cpp")
    if (!s) return
    A.check("e2e/service-created", s !== null, true)
    A.check("e2e/config-in-sandbox", s.configPath.indexOf("/plugin/configs/llama.env") !== -1, true)
    A.check("e2e/unit-dir-in-sandbox", s.userUnitDir.indexOf("/home/.config/systemd/user") !== -1, true)
    A.check("e2e/no-unit-yet", readFile(unitPath()), "")
    phase = 1
  }

  function stepDryRun() {
    A.check("dryrun/exit64-prompts", s.pendingProvision, true)
    A.ok("dryrun/env-created", readFile(envPath()).indexOf("LLAMA_HOST=") !== -1)
    A.check("dryrun/no-unit", readFile(unitPath()), "")
    A.check("dryrun/no-start-logged", readFile(mocklog()).indexOf("start llama.cpp.service") === -1, true)
    s.confirmProvision()
    phase = 3
  }

  function stepConsent() {
    if (!root.s3done) {
      A.ok("consent/unit-created", readFile(unitPath()).indexOf("EnvironmentFile=") !== -1)
      A.ok("consent/env-has-host", readFile(envPath()).indexOf("LLAMA_HOST=127.0.0.1") !== -1)
      A.ok("consent/daemon-reload-logged", readFile(mocklog()).indexOf("CALL systemctl --user daemon-reload") !== -1)
      A.check("consent/start-logged", readFile(mocklog()).indexOf("start llama.cpp.service") !== -1, true)
      A.check("consent/pending-cleared", s.pendingProvision, false)
      A.check("consent/last-error-clear", s.lastError, "")
      root.s3done = true
    }
    if (!s.hasService) return
    s.stopService()
    phase = 4
  }

  function stepStop() {
    A.check("stop/stop-logged", readFile(mocklog()).indexOf("stop llama.cpp.service") !== -1, true)
    A.check("stop/busy-released", s.busy, false)
    A.finish()
  }

  Timer {
    interval: 40
    repeat: true
    running: root.phase !== 0
    onTriggered: {
      if (root.phase === 1) {
        if (!root.s.installed) return
        root.s.startService()
        root.phase = 2
        return
      }
      if (root.s.busy) return
      if (root.phase === 2) stepDryRun()
      else if (root.phase === 3) stepConsent()
      else if (root.phase === 4) stepStop()
    }
  }
}