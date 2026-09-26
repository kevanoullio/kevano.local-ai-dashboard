import QtQuick
import Quickshell

// Dumps the embedded bash constants from Service.qml as marker-delimited JSON
// so integration tests execute the exact strings the panel uses (single source
// of truth). Run with: quickshell -p tests/support/dump_constants.qml
// Output protocol (one console line each):
//   >>>DUMP:<name><<<
//   <JSON.stringify(value)>     (single line; newlines are escaped)
//   >>>END<<<
Item {
  id: root
  property var svc: null

  Component.onCompleted: {
    var comp = Qt.createComponent("@SERVICE_QML_PATH@")
    if (comp.status !== Component.Ready) {
      console.log("DUMP-COMPILE-FAIL: " + comp.errorString())
      Qt.quit()
      return
    }
    svc = comp.createObject(root, { backend: "llama.cpp" })
    if (!svc) { console.log("DUMP-INSTANCE-FAIL"); Qt.quit(); return }
    var names = [
      "llamaEnvDefault", "llamaUnitBody", "provisionLlamaScript",
      "createEnvScript", "configScript", "createConfigScript",
      "ggufScript", "modelsIniScript", "unloadScriptLlama", "slotsScriptLlama",
      "kvProbeScript"
    ]
    for (var i = 0; i < names.length; i++) {
      console.log(">>>DUMP:" + names[i] + "<<<")
      console.log(JSON.stringify(svc[names[i]]))
      console.log(">>>END<<<")
    }
    // Also expose the QML constants the security-contract test keys on.
    console.log(">>>DUMP:userUnitDir<<<")
    console.log(JSON.stringify(svc.userUnitDir))
    console.log(">>>END<<<")
    Qt.quit()
  }
}