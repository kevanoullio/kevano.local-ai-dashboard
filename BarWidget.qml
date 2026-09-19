import QtQuick
import Quickshell
import qs.Ui
import qs.Commons

BarWidget {
  id: root
  moduleName: "kevano.local-ai-dashboard"

  readonly property bool opened: controller.panelRef
    ? controller.panelRef.opened === true
    : false
  readonly property bool popoutSwitchClosing: controller.panelRef
    ? controller.panelRef.popoutSwitchClosing === true
    : false

  property alias activeBackend: controller.activeBackend
  function setActiveBackend(name) { controller.setActiveBackend(name) }
  function open()                { controller.open() }
  function close()               { controller.close() }
  function toggle()              { controller.toggle() }
  function closeForPopoutSwitch(){ controller.closeForPopoutSwitch() }

  property alias barIconColor: controller.barIconColor

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: controller.injectPanel()

  Controller {
    id: controller
    bar: root.bar
    widgetHost: root
    anchorButton: button
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    tooltipText: {
      var p = controller.panelRef
      if (!p) return "Local AI"
      return "llama.cpp \u00b7 " + controller.serviceStateString(p.llamaService) +
             "   |   ollama \u00b7 " + controller.serviceStateString(p.ollamaService)
    }
    iconComponent: Component {
      Item {
        Text {
          anchors.centerIn: parent
          text: "󰚩"
          color: root.barIconColor
          font.family: root.bar ? root.bar.fontFamily : Style.font.family
          font.pixelSize: Style.bar.iconFont
          renderType: Text.NativeRendering
          textFormat: Text.PlainText

          Behavior on color { ColorAnimation { duration: 240 } }
        }
      }
    }

    onPressed: function(buttonCode) {
      if (buttonCode === Qt.LeftButton) root.toggle()
    }
  }
}
