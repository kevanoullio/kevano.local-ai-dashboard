import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Ui
import "../ui" as UI

// Service details section: actionable errors, install/no-service notices,
// and the status/version/api/latency/since grid plus configuration buttons.
// All state comes in via `service`; actions are reported back as signals.
Item {
  id: root

  required property var service
  required property color statusColor
  required property color foreground
  required property color urgent
  required property color dim
  required property string fontFamily

  readonly property color warnColor: Qt.hsla(0.10, 0.68, 0.55, 1.0)

  signal configRequested()
  signal createConfigRequested()
  signal debugRequested()
  signal confirmProvisionRequested()
  signal cancelProvisionRequested()

  implicitHeight: contentCol.implicitHeight
  width: parent ? parent.width : 0

  Column {
    id: contentCol
    width: parent.width
    spacing: Style.spacing.labelGap

    // ── Error ───────────────────────────────────────────────────
    Text {
      visible: root.service.lastError !== ""
      width: parent.width
      text: root.service.sanitize(root.service.lastError)
      color: root.urgent
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      textFormat: Text.PlainText
      wrapMode: Text.WordWrap
    }

    // ── Config warning ───────────────────────────────────────────
    Text {
      visible: root.service.configWarning !== ""
      width: parent.width
      text: root.service.sanitize(root.service.configWarning)
      color: root.warnColor
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      textFormat: Text.PlainText
      wrapMode: Text.WordWrap
    }

    // ── Not installed ────────────────────────────────────────────
    CursorSurface {
      visible: !root.service.installed
      width: parent.width
      implicitHeight: missingText.implicitHeight + Style.spacing.rowPaddingX
      foreground: root.foreground

      Text {
        id: missingText
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        anchors.margins: Style.space(12)
        text: root.service.backendDisplayName + " is not installed or not on PATH.\nInstall it and try again."
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        textFormat: Text.PlainText
        wrapMode: Text.WordWrap
      }
    }

    // ── No service ────────────────────────────────────────────────
    CursorSurface {
      visible: root.service.installed && !root.service.hasService && !root.service.selfManaged
      width: parent.width
      implicitHeight: noServiceText.implicitHeight + Style.spacing.rowPaddingX
      foreground: root.foreground

      Text {
        id: noServiceText
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        anchors.margins: Style.space(12)
        text: root.service.backendDisplayName + " is installed but has no systemd service.\nSet one up with:\n\nsudo systemctl enable " + root.service.backendService.replace('.service', '') + "\n\nSee the README for a unit file if none is packaged."
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
        textFormat: Text.PlainText
        wrapMode: Text.WordWrap
      }
    }

    // ── Service details ─────────────────────────────────────────
    Column {
      visible: root.service.installed && (root.service.hasService || root.service.selfManaged)
      width: parent.width
      spacing: Style.spacing.labelGap

      GridLayout {
        width: parent.width
        columns: 2
        columnSpacing: Style.space(20)
        rowSpacing: Style.spacing.labelGap

        UI.InfoLabel {
          text: "Status"
          foreground: root.foreground
          fontFamily: root.fontFamily
        }
        UI.InfoValue {
          text: root.service.running ? "Running" : "Stopped"
          color: root.statusColor
          foreground: root.foreground
          fontFamily: root.fontFamily
        }

        UI.InfoLabel {
          text: "Version"
          foreground: root.foreground
          fontFamily: root.fontFamily
        }
        UI.InfoValue {
          text: root.service.sanitize(root.service.ollamaVersion) || "\u2014"
          foreground: root.foreground
          fontFamily: root.fontFamily
        }

        UI.InfoLabel {
          visible: root.service.running
          text: "API"
          foreground: root.foreground
          fontFamily: root.fontFamily
        }
        UI.InfoValue {
          visible: root.service.running
          text: root.service.apiReachable ? root.service.effectiveHost + ":" + root.service.effectivePort : "\u2014"
          color: !root.service.apiReachable ? root.urgent : root.foreground
          foreground: root.foreground
          fontFamily: root.fontFamily
        }

        UI.InfoLabel {
          visible: root.service.running && root.service.apiReachable
          text: "Latency"
          foreground: root.foreground
          fontFamily: root.fontFamily
        }
        UI.InfoValue {
          visible: root.service.running && root.service.apiReachable
          text: root.service.apiLatencyMs >= 0 ? root.service.apiLatencyMs + " ms" : "\u2014"
          color: {
            if (root.service.apiLatencyMs > 500) return root.urgent
            if (root.service.apiLatencyMs > 200) return Color.accent
            return root.foreground
          }
          foreground: root.foreground
          fontFamily: root.fontFamily
        }

        UI.InfoLabel {
          visible: root.service.running && root.service.activeSince !== ""
          text: "Since"
          foreground: root.foreground
          fontFamily: root.fontFamily
        }
        UI.InfoValue {
          visible: root.service.running && root.service.activeSince !== ""
          text: root.service.activeSince ? root.service.sanitize(root.service.activeSince.replace(/^\w+\s+/, "")) : ""
          foreground: root.foreground
          fontFamily: root.fontFamily
        }

        UI.SettingsButton {
          Layout.columnSpan: 2
          Layout.fillWidth: true
          label: "Configure " + root.service.backendDisplayName
          foreground: root.foreground
          fontFamily: root.fontFamily
          enabled: root.service.hasConfig
          onClicked: root.configRequested()
        }

        UI.SettingsButton {
          Layout.columnSpan: 2
          Layout.fillWidth: true
          label: "View debug output"
          foreground: root.foreground
          fontFamily: root.fontFamily
          enabled: root.service.running
          onClicked: root.debugRequested()
        }

        UI.SettingsButton {
          Layout.columnSpan: 2
          Layout.fillWidth: true
          visible: !root.service.hasConfig
          label: "Create " + root.service.backendDisplayName + " config file"
          foreground: root.foreground
          fontFamily: root.fontFamily
          onClicked: root.createConfigRequested()
        }

        // ── Provisioning consent (llama.cpp Phase 4) ───────────────
        Text {
          Layout.columnSpan: 2
          Layout.topMargin: Style.spacing.labelGap
          visible: root.service.pendingProvision
          width: parent.width
          text: "Starting " + root.service.backendDisplayName + " needs to write a systemd unit (create or update). " +
                "Confirm to write it and start, or Cancel to do nothing. This request expires automatically."
          color: root.warnColor
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          textFormat: Text.PlainText
          wrapMode: Text.WordWrap
        }
        UI.SettingsButton {
          Layout.columnSpan: 2
          Layout.fillWidth: true
          visible: root.service.pendingProvision
          label: "Confirm unit update & start"
          foreground: root.foreground
          fontFamily: root.fontFamily
          onClicked: root.confirmProvisionRequested()
        }
        UI.SettingsButton {
          Layout.columnSpan: 2
          Layout.fillWidth: true
          visible: root.service.pendingProvision
          label: "Cancel"
          foreground: root.foreground
          fontFamily: root.fontFamily
          onClicked: root.cancelProvisionRequested()
        }
      }
    }
  }
}
