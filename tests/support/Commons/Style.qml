pragma Singleton
import QtQuick

QtObject {
  // Test stub: 1:1 space scaling and neutral surfaces. None of the plugin UI
  // logic depends on these exact values.
  function space(u) { return u }
  function hoverBorderFor(a, b) { return "1px solid #eeeeee" }
  function normalBorderFor(a, b) { return "1px solid #666666" }
  function selectedFillFor(a, b) { return "#2a2a2e" }
  readonly property QtObject spacing: QtObject {
    readonly property real labelGap: 8
    readonly property real rowPaddingX: 12
  }
  readonly property QtObject font: QtObject {
    readonly property string family: "monospace"
    readonly property real bodySmall: 11
    readonly property real body: 12
    readonly property real title: 16
    readonly property real caption: 9
  }
}