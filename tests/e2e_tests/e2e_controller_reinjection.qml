import QtQuick
import "asserts.js" as A

// E2E: Controller reactive panel-injection arc (top-left popup fix). Loads the
// real Controller.qml (sibling in the sandbox, whose Loader picks up the stub
// Dashboard the driver plants next to it) and proves the one-shot onLoaded
// injection is no longer the only path: bar/anchorButton set AFTER the panel
// loads must propagate to panelLoader.item via onBarChanged/onAnchorButtonChanged.
Item {
  id: root

  property var ctrl: null
  property var fakeBar: null
  property int phase: 0

  Item { id: hostWidget }
  Item { id: anchorButton; width: 24; height: 24 }
  Component { id: barCmp; Item { property string position: "top" } }

  Loader {
    id: ctrlLoader
    active: true
    source: "Controller.qml"
    onLoaded: {
      root.ctrl = item
      root.ctrl.widgetHost = hostWidget
    }
  }

  function panel() { return root.ctrl ? root.ctrl.panelRef : null }

  Component.onCompleted: { phase = 1 }

  Timer {
    interval: 40
    repeat: true
    running: root.phase !== 0
    onTriggered: {
      if (root.phase === 1) {
        var p = root.panel()
        if (!p) return
        A.check("arc/initial-bar-null", p.bar, null)
        A.check("arc/initial-anchor-null", p.anchorItem, null)
        root.fakeBar = barCmp.createObject(root)
        root.ctrl.bar = fakeBar
        root.ctrl.anchorButton = anchorButton
        root.phase = 2
        return
      }
      if (root.phase === 2) {
        var p2 = root.panel()
        A.ok("arc/bar-reinjected", p2.bar === fakeBar)
        A.ok("arc/anchor-reinjected", p2.anchorItem === anchorButton)
        A.ok("arc/host-injected", p2.hostWidget === hostWidget)
        A.finish()
      }
    }
  }
}
