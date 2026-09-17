import QtQuick
import Quickshell
import Quickshell.Io
import "asserts.js" as A

// E2E: rollback under an already-installed older unit. The driver pre-created
// the unit (matching the fabricated one) then replaced it with "OLD-UNIT" and
// set FAIL_START=1, so our cp writes a different unit and the very first start
// this run fails -> the provisioner must restore and clean up exactly.
Item {
  id: root
  property var s: null
  property int phase: 0

  FileView { id: fv; printErrors: false; blockAllReads: true }
  function readFile(path) { fv.path = ""; fv.path = path; return fv.text() }
  function sandboxBase() { return s.configPath.replace(/\/plugin\/configs\/.*/, "") }
  function unitPath() { return sandboxBase() + "/home/.config/systemd/user/llama.cpp.service" }
  function bakPath()  { return sandboxBase() + "/home/.config/systemd/user/.llama.cpp.service.bak" }

  Component.onCompleted: {
    s = A.service("@SERVICE_QML_PATH@", root, "llama.cpp")
    if (!s) return
    phase = 1
  }

  function stepDryRun() {
    A.check("rollback/marker", s.pendingProvision, true)
    A.ok("rollback/dryrun-preinstalled-unit", readFile(unitPath()).indexOf("OLD-UNIT") !== -1)
    A.check("rollback/backup-not-made-yet", readFile(bakPath()), "")
    s.confirmProvision()
    phase = 3
  }

  function stepDone() {
    A.check("rollback/exit-63-visible", s.lastError.indexOf("was restored") !== -1, true)
    A.check("rollback/pending-cleared", s.pendingProvision, false)
    A.ok("rollback/unit-is-old-again", readFile(unitPath()).indexOf("OLD-UNIT") !== -1)
    A.ok("rollback/env-created", readFile(s.configPath).indexOf("LLAMA_HOST=") !== -1)
    A.check("rollback/backup-removed", readFile(bakPath()), "")
    A.finish()
  }

  Timer {
    interval: 40
    repeat: true
    running: root.phase !== 0
    onTriggered: {
      if (root.s.busy) return
      if (root.phase === 1) {
        if (!root.s.installed) return
        root.s.startService()
        root.phase = 2
        return
      }
      if (root.phase === 2) stepDryRun()
      else if (root.phase === 3) stepDone()
    }
  }
}