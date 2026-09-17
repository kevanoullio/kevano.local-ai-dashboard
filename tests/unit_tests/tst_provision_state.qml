import QtQuick
import Quickshell
import "asserts.js" as A

// Unit: the Phase 4 provision consent state machine. startProcess is stubbed to
// `bash -c <code>` so we drive exit codes without touching the real machine:
//   exit 64 (unit change requires consent) -> pendingProvision + prompt reset
//   cancelProvision()  -> clears the prompt
//   confirmProvision() -> consent flag set for the relaunch, consumed after
// The 20 s auto-cancel timer is time-based and not exercised here.
Item {
  id: root
  property var s: null
  property var proc: null
  property int phase: 0

  function findStartProcess() {
    var arr = s.data || []
    for (var i = 0; i < arr.length; i++) {
      var o = arr[i]
      if (!o || typeof o.command !== "object") continue
      if (JSON.stringify(o.command).indexOf("flock -n 9") !== -1) return o
    }
    return null
  }

  function step1() {
    A.check("exit64/pendingProvision", s.pendingProvision, true)
    A.check("exit64/lastError-clear", s.lastError, "")
    A.check("exit64/consent-flag-unset", s._provisionConsented, false)
    A.check("exit64/busy-released", s.busy, false)
    s.cancelProvision()
    A.check("cancel/clears-prompt", s.pendingProvision, false)
    proc.command = ["bash", "-c", "exit 0"]
    s.confirmProvision()
    A.check("confirm/consent-flag-set", s._provisionConsented, true)
    phase = 2
  }

  function step2() {
    A.check("confirm-run/pending-stays-false", s.pendingProvision, false)
    A.check("confirm-run/consent-consumed", s._provisionConsented, false)
    A.check("confirm-run/busy-released", s.busy, false)
    A.finish()
  }

  Component.onCompleted: {
    s = A.service("@SERVICE_QML_PATH@", root, "llama.cpp")
    if (!s) return
    proc = findStartProcess()
    if (!proc) { A.ok("startProcess-found", false); A.finish(); return }
    // The real machine is not under test: force the async `which` result and
    // stub the provisioner command, then drive exit codes through the state
    // machine without touching anything.
    s.installed = true
    proc.command = ["bash", "-c", "exit 64"]
    s.startService()
    phase = 1
  }

  Timer {
    interval: 40
    repeat: true
    running: root.phase !== 0
    onTriggered: {
      if (root.s.busy) return
      if (root.phase === 1) step1()
      else if (root.phase === 2) step2()
    }
  }
}