import QtQuick
import Quickshell
import qs.Commons

Item {
  id: root

  property var bar: null
  property string activeBackend: "llama.cpp"

  // The owning bar widget. Passed in by the widget so the dashboard's
  // `hostWidget` references the real widget (used by the dashboard IPC,
  // `bar.switchPanelFrom`, and `KeyboardPanel.owner`).
  property var widgetHost: null

  // The bar icon button this panel anchors to (document-scoped id lookup).
  property var anchorButton: null

  function setActiveBackend(name) {
    if (name === "ollama" || name === "llama.cpp") activeBackend = name
  }

  // ── Panel lifecycle ───────────────────────────────────────────
  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Dashboard.qml")
    visible: false
    onLoaded: root.injectPanel()
  }

  // The bar facade and anchor button can resolve only after the panel loads
  // (host-side `bar` injection is async at boot), so re-inject whenever
  // either changes instead of relying on the one-shot onLoaded pass.
  onBarChanged: injectPanel()
  onAnchorButtonChanged: injectPanel()

  function open() {
    if (panelLoader.item) panelLoader.item.open()
  }

  function close() {
    if (panelLoader.item) panelLoader.item.close()
  }

  function toggle() {
    if (panelLoader.item) panelLoader.item.toggle()
  }

  function closeForPopoutSwitch() {
    if (panelLoader.item) panelLoader.item.closeForPopoutSwitch()
  }

  function injectPanel() {
    if (!panelLoader.item) return
    panelLoader.item.bar = bar
    panelLoader.item.anchorItem = anchorButton
    panelLoader.item.hostWidget = widgetHost
  }

  // ── State helpers ─────────────────────────────────────────────
  function serviceStateString(svc) {
    if (!svc) return "…"
    if (!svc.installed) return "Not installed"
    if (!svc.hasService) return "No service"
    return svc.running ? "Running" : "Stopped"
  }

  // Defer to the panel's own active service selection so there is a single
  // source of truth for the active backend.
  readonly property var _activeService: panelLoader.item
    ? panelLoader.item.activeService
    : null

  // Bar icon color: derived from the active service's state.
  property color barIconColor: {
    var s = _activeService
    var base = bar ? bar.barForeground : Color.foreground
    if (!s || !s.installed || !s.hasService) return Qt.darker(base, 2.0)
    if (s.running) return base
    return Qt.darker(base, 1.55)
  }

  readonly property var panelRef: panelLoader.item
}
