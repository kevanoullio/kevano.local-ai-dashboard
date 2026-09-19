import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "sections"

Panel {
  id: root
  moduleName: "com.github.linuxgameruk.ollama-status"
  ipcTarget: "com.github.linuxgameruk.ollama-status"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // ── Active backend selection ────────────────────────────────────────
  property string activeBackend: "llama.cpp"
  readonly property var activeService: activeBackend === "llama.cpp" ? serviceLlama : serviceOllama

  // Exposed for the bar widget to read without its own Service instance.
  property var ollamaService: serviceOllama
  property var llamaService: serviceLlama

  function serviceStatus(svc) {
    if (svc.busy) return svc.actionLabel
    if (!svc.installed) return "Not installed"
    if (!svc.hasService) {
      if (svc.selfManaged) return "Configured"
      return "No service"
    }
    return svc.running ? "Running" : "Stopped"
  }

  function serviceStatusColor(svc) {
    if (svc.busy) return foreground
    if (!svc.installed) return urgent
    if (!svc.hasService) return svc.selfManaged ? foreground : urgent
    if (svc.running) return Color.accent
    return foreground
  }

  function switchBackend(name) {
    if (name !== "ollama" && name !== "llama.cpp") return
    if (name === activeBackend) return
    activeBackend = name
    if (hostWidget && typeof hostWidget.setActiveBackend === "function") {
      hostWidget.setActiveBackend(name)
    }
  }

  // Open the active backend's config file in the user's editor/terminal.
  function openConfig() {
    Util.execArgv(["omarchy", "launch", "config", "editor", root.activeService.configPath])
  }

  // Stream the active backend's journal in a new terminal.
  function openDebug() {
    Util.execArgv(["omarchy", "launch", "tui"].concat(root.activeService.backendDebugArgs))
  }

  readonly property string statusText: serviceStatus(activeService)
  readonly property color statusColor: serviceStatusColor(activeService)
  readonly property string toggleHint: {
    var s = activeService
    if (!s.installed) return ""
    if (!s.hasService) {
      if (s.selfManaged) return "Ready \u2014 start creates config & service"
      return "See setup instructions below"
    }
    if (s.running) return "Turn " + s.backendDisplayName + " off"
    return "Turn " + s.backendDisplayName + " on"
  }

  property string focusSection: "header"
  property bool cursorActive: false

  // True when the header is the keyboard-focus target for cursor/hover
  // emphasis, shared by the hero cards and the power toggle.
  readonly property bool headerActive: cursorActive && focusSection === "header"

  function switchPanel(direction) {
    if (bar && typeof bar.switchPanelFrom === "function")
      return bar.switchPanelFrom(root.hostWidget || root, direction)
    return false
  }

  onOpenedChanged: if (opened) {
    cursorActive = false
    // Re-read each backend's config so dashboard-side settings (e.g. llama.cpp's
    // LLAMA_UNLOAD_INACTIVITY_SEC auto-unload timeout) picked up from the file
    // take effect on open, without requiring a service restart.
    serviceOllama.reloadConfig()
    serviceLlama.reloadConfig()
    serviceOllama.refresh()
    serviceLlama.refresh()
    Qt.callLater(function() { if (keyCatcher) keyCatcher.forceActiveFocus() })
  }

  Service {
    id: serviceLlama
    settings: root.settings
    backend: "llama.cpp"
  }

  Service {
    id: serviceOllama
    settings: root.settings
    backend: "ollama"
  }

  IpcHandler {
    target: root.ipcTarget
    function open() { root.open() }
    function close() { root.close() }
    function toggle() { root.toggle() }
    function startService() { root.activeService.startService(); return "ok" }
    function stopService() { root.activeService.stopService(); return "ok" }
    function refresh() { root.serviceOllama.refresh(); root.serviceLlama.refresh(); return "ok" }
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.hostWidget || root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(380))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) root.cursorActive = true
        if (dx !== 0 && root.activeBackend === "llama.cpp") {
          root.switchBackend("ollama")
        } else if (dx !== 0 && root.activeBackend === "ollama") {
          root.switchBackend("llama.cpp")
        }
      }
      onActivateRequested: {
        if (root.cursorActive && root.focusSection === "header") root.activeService.toggleService()
      }
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "s" || t === "S") root.activeService.startService()
        else if (t === "x" || t === "X") root.activeService.stopService()
        else if (t === "r" || t === "R") { root.serviceOllama.refresh(); root.serviceLlama.refresh() }
        else if (t === "c" || t === "C") root.openConfig()
        else if (t === "d" || t === "D") root.openDebug()
      }
    }

    Flickable {
      id: panelFlick
      anchors.fill: parent
      contentWidth: width
      contentHeight: column.implicitHeight
      clip: true
      boundsBehavior: Flickable.StopAtBounds
      flickableDirection: Flickable.VerticalFlick
      interactive: contentHeight > height
      ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

      Column {
        id: column
        width: panelFlick.width
        spacing: Style.space(12)

        // ── Hero: two backend cards + power switch ──────────────────
        HeroSection {
          width: parent.width
          llamaStatusText: root.serviceStatus(root.serviceLlama)
          llamaStatusColor: root.serviceStatusColor(root.serviceLlama)
          ollamaStatusText: root.serviceStatus(root.serviceOllama)
          ollamaStatusColor: root.serviceStatusColor(root.serviceOllama)
          activeBackend: root.activeBackend
          activeService: root.activeService
          toggleHint: root.toggleHint
          foreground: root.foreground
          fontFamily: root.fontFamily
          headerActive: root.headerActive
          onBackendSelected: root.switchBackend(name)
          onToggleRequested: root.activeService.toggleService()
          onSectionHovered: { root.cursorActive = true; root.focusSection = "header" }
        }

        // ── Error / notices / service details + configure buttons ──
        ServiceDetailsSection {
          width: parent.width
          service: root.activeService
          statusColor: root.statusColor
          foreground: root.foreground
          urgent: root.urgent
          dim: root.dim
          fontFamily: root.fontFamily
          onConfigRequested: root.openConfig()
          onCreateConfigRequested: root.activeService.createConfigFile()
          onDebugRequested: root.openDebug()
          onConfirmProvisionRequested: root.activeService.confirmProvision()
          onCancelProvisionRequested: root.activeService.cancelProvision()
        }

        // ── Running + available models ──────────────────────────────
        ModelsSection {
          width: parent.width
          service: root.activeService
          foreground: root.foreground
          dim: root.dim
          urgent: root.urgent
          fontFamily: root.fontFamily
          onUnloadRequested: root.activeService.unloadModel(modelId)
        }
      }
    }
  }
}
