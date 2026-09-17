import QtQuick
import Quickshell
import Quickshell.Io
import "asserts.js" as A

// E2E: the Phase 4 consent UI wiring arc. Instantiates the real
// ServiceDetailsSection (from the sandboxed plugin) against a real Service and
// drives the confirm/cancel buttons exactly as Dashboard.qml does:
//   SettingsButton.clicked -> section.confirmProvisionRequested
//   section.confirmProvisionRequested -> Service.confirmProvision()
// (cancel likewise). The Dashboard choose-arc contract is pinned at source
// level (its `import "sections"` folder + both connect lines), because a bare
// `quickshell -p <file>` loader does not resolve folder imports, while the
// section compile + live button drive covers the feature wiring itself.
Item {
  id: root
  property var s: null
  property var createCmp: null
  property var sec: null
  property int phase: 0

  FileView { id: fv; printErrors: false; blockAllReads: true }
  function readFile(path) { fv.path = ""; fv.path = path; return fv.text() }

  function collect(o, acc) {
    if (!o) return acc
    if (typeof o.label === "string") acc.push(o)
    var kids = o.data || []
    for (var i = 0; i < kids.length; i++) collect(kids[i], acc)
    return acc
  }

  function find(prefix) {
    var list = collect(sec, [])
    for (var i = 0; i < list.length; i++) {
      if (list[i].label === prefix) return list[i]
      if (prefix !== "Cancel" && list[i].label.indexOf(prefix) === 0) return list[i]
    }
    return null
  }

  function runArc() {
    A.ok("arc/service-methods-exist",
      typeof s.confirmProvision === "function" && typeof s.cancelProvision === "function")

    createCmp = Qt.createComponent("@SECTION_QML_PATH@")
    A.check("arc/section-compiles", createCmp.status, Component.Ready)
    if (createCmp.status !== Component.Ready) { A.fail("section error: " + createCmp.errorString()); A.finish(); return }

    sec = createCmp.createObject(root, {
      service: s,
      statusColor: "#00ff00", foreground: "#eeeeee", urgent: "#ff5555", dim: "#888888",
      fontFamily: "monospace"
    })
    A.ok("arc/section-instantiated", sec !== null)
    if (!sec) { A.finish(); return }

    A.check("arc/no-consent-initially", s.pendingProvision, false)

    s.pendingProvision = true
    var confirm = find("Confirm unit update & start")
    var cancel = find("Cancel")
    A.ok("arc/confirm-button-found", confirm !== null)
    A.ok("arc/cancel-button-found", cancel !== null)
    if (!confirm || !cancel) { A.finish(); return }
    A.check("arc/buttons-visible-when-pending", confirm.visible && cancel.visible, true)

    sec.confirmProvisionRequested.connect(function() { s.confirmProvision() })
    sec.cancelProvisionRequested.connect(function() { s.cancelProvision() })

    confirm.clicked()
    A.ok("arc/confirm-propagates-to-service", s._provisionConsented === true)
    s.cancelProvision()

    s.pendingProvision = true
    cancel.clicked()
    A.check("arc/cancel-clears-prompt", s.pendingProvision, false)

    s.pendingProvision = false
    A.check("arc/buttons-hidden-when-clear", confirm.visible === false && cancel.visible === false, true)
    A.finish()
  }

  Component.onCompleted: {
    s = A.service("@SERVICE_QML_PATH@", root, "llama.cpp")
    if (!s) return
    A.ok("arc/service-created", s !== null, true)
    phase = 1
  }

  Timer {
    interval: 40
    repeat: true
    running: root.phase !== 0
    onTriggered: {
      if (root.phase === 1) {
        if (!root.s.installed || root.s.busy) return
        if (!root.s.hasService) return
        root.phase = 2
        return
      }
      if (root.phase === 2) { root.phase = 3; root.runArc() }
    }
  }
}