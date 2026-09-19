import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Ui
import "../ui" as UI

// Model inventory section: currently loaded models, the full available
// model list, and the "no models" empty state. Data arrives via `service`;
// the only action is the llama.cpp per-model Unload button (signal below).
Item {
  id: root

  required property var service
  required property color foreground
  required property color dim
  required property color urgent
  required property string fontFamily

  signal unloadRequested(string modelId)

  implicitHeight: contentCol.implicitHeight
  width: parent ? parent.width : 0

  // Render an ollama loaded-model detail line in the same format as
  // llama.cpp: "<size> | CPU: X% | GPU: Y%". Splits the already-provided
  // `modelData.processor` string (e.g. "100% CPU", "51%/49% CPU/GPU").
  // Returns "" when the string can't be parsed so callers can fall back.
  function ollamaDetailLine(modelData) {
    var proc = String(modelData && modelData.processor || "").trim()
    var sizeStr = modelData && modelData.size ? String(modelData.size) : ""
    var cpu = -1
    var gpu = -1
    var m = proc.match(/^(\d+)%\s*\/\s*(\d+)%\s*CPU\/GPU/)
    if (m) {
      cpu = parseInt(m[1], 10)
      gpu = parseInt(m[2], 10)
    } else {
      m = proc.match(/^(\d+)%\s*CPU/)
      if (m) {
        cpu = parseInt(m[1], 10)
        gpu = 100 - cpu
      } else {
        m = proc.match(/^(\d+)%\s*GPU/)
        if (m) {
          gpu = parseInt(m[1], 10)
          cpu = 100 - gpu
        }
      }
    }
    if (sizeStr === "" || cpu < 0 || gpu < 0) return ""
    var parts = []
    parts.push("Memory: " + sizeStr)
    parts.push("CPU: " + cpu + "%")
    parts.push("GPU: " + gpu + "%")
    return root.service.sanitize(parts.join(" | "))
  }

  // "(+N MTP ~X MB)" suffix for a layer line: the MTP layers sitting on this
  // device (nOnDevice of mtpTotalLayers), sized proportionally to the MTP
  // weight size so a partial split prints its share. "" when there are no MTP
  // layers on this device or the size is unknown (non-MTP models unchanged).
  function _mtpParen(nOnDevice, mtpTotalLayers, mtpSizeBytes) {
    var n = Number(nOnDevice)
    var t = Number(mtpTotalLayers)
    var sz = Number(mtpSizeBytes)
    if (!isFinite(n) || n <= 0) return ""
    if (!isFinite(t) || t <= 0) return ""
    if (!isFinite(sz) || sz < 0) return ""
    return " (+" + Math.round(n) + " MTP ~" + root.service.formatMB(Math.round(sz * n / t)) + ")"
  }

  // Render a llama.cpp loaded-model detail block in the seven-line layout:
  // Model Size / GPU Layers / CPU Layers / Context / KV Cache / GPU Total /
  // CPU Total. Values arrive on `modelData` (see Service.qml _finishJsonModels);
  // GGUF-dependent fields resolve asynchronously and start at -1/null, so every
  // line degrades to "—" until they land. Returns a multi-line, sanitize()-ed
  // string.
  function llamaDetailBlock(modelData) {
    var m = modelData || {}
    var s = root.service
    function num(v) { var n = Number(v); return (v !== undefined && v !== null && isFinite(n) && n >= 0) ? n : -1 }
    var total = num(m.totalLayers)
    var main = num(m.mainLayers)
    var mtp = num(m.mtpLayers)
    var mtpSize = num(m.mtpSizeBytes)
    var gpu = num(m.mainGpu)
    var cpu = num(m.mainCpu)
    var mtpGpu = num(m.mtpGpu)
    var mtpCpu = num(m.mtpCpu)
    var ctxLen = num(m.contextLen)
    var sizeBytes = num(m.sizeBytes)
    var draftSize = num(m.draftSizeBytes)

    // Split source: "api" = explicit --n-gpu-layers from the resolved CLI,
    // "probe" = Tier-3 estimate derived from measured per-PID VRAM.
    var splitSource = m._gpuSplitSource || "unknown"
    // Tier-3 live estimate (measured VRAM ÷ model size): re-derived here so a
    // VRAM reading that lands after the GGUF header still shows without
    // waiting for the next /v1/models poll. null = nothing to derive from.
    var estProbe = (total > 0) ? s._estimateSplitFromProbes(sizeBytes, total, s.serviceVramBytes) : null

    function gb(b) { return b >= 0 ? s.formatGB(b) : "\u2014" }
    function nn(n) { return n >= 0 ? String(n) : "\u2014" }
    function nnP(n) { return n >= 0 ? (splitSource === "probe" ? "~" : "") + String(n) : "\u2014" }
    function comma(n) {
      var d = String(Math.round(n))
      var out = ""
      for (var i = d.length - 1, c = 0; i >= 0; i--, c++) {
        if (c > 0 && c % 3 === 0) out = "," + out
        out = d.charAt(i) + out
      }
      return out
    }

    // Per-device weight bytes: the exact layer-ratio split of the base weights
    // when the offload count is known from the API, plus the MTP share when its
    // placement is known; then the probe ratio estimate; otherwise the measured
    // per-device footprint (an estimate — measured VRAM/DRAM can include KV
    // cache). Unknown → -1 ("—").
    var gpuExact = (gpu >= 0 && splitSource === "api" && sizeBytes > 0 && total > 0)
    var cpuExact = (cpu >= 0 && splitSource === "api" && sizeBytes > 0 && total > 0)
    var gpuW = -1
    if (gpuExact) {
      gpuW = Math.round(sizeBytes * gpu / total)
      if (mtp > 0 && mtpGpu >= 0 && mtpSize > 0) gpuW += Math.round(mtpSize * mtpGpu / mtp)
    } else if (estProbe !== null && estProbe.gpuLayers >= 0 && sizeBytes > 0) {
      gpuW = Math.round(sizeBytes * estProbe.gpuLayers / total)
    } else if (s.serviceVramBytes >= 0) {
      gpuW = s.serviceVramBytes   // ≈ measured GPU footprint
    }
    var cpuW = -1
    if (cpuExact) {
      cpuW = Math.round(sizeBytes * cpu / total)
      if (mtp > 0 && mtpCpu >= 0 && mtpSize > 0) cpuW += Math.round(mtpSize * mtpCpu / mtp)
    } else if (estProbe !== null && estProbe.cpuLayers >= 0 && sizeBytes > 0) {
      cpuW = Math.round(sizeBytes * estProbe.cpuLayers / total)
    } else if (s.serviceMemoryBytes >= 0) {
      cpuW = s.serviceMemoryBytes   // ≈ measured DRAM working set
    }
    var gpuEst = !gpuExact || (mtp > 0 && (mtpGpu < 0 || mtpSize < 0))
    var cpuEst = !cpuExact || (mtp > 0 && (mtpCpu < 0 || mtpSize < 0))

    function gbWg(b) { return b >= 0 ? (gpuEst ? "~" : "") + s.formatGB(b) : "\u2014" }
    function gbWc(b) { return b >= 0 ? (cpuEst ? "~" : "") + s.formatGB(b) : "\u2014" }
    // Percent of the MAIN stack on each device; MTP is its own parenthetical.
    var pGpu = -1
    var pCpu = -1
    var pctEst = false
    if (main > 0 && gpu >= 0 && cpu >= 0) {
      pGpu = s._percentLayersOnGPU(gpu, main)
      pCpu = s._percentLayersOnCPU(cpu, main)
      pctEst = (splitSource === "probe")
    } else if (estProbe !== null && main > 0) {
      // Tier-3 fallback: estimate percentage from measured VRAM.
      pGpu = Math.round(estProbe.gpuLayers / main * 100)
      pCpu = 100 - pGpu
      pctEst = true
    }

    // Where the context/KV cache lives: pinned to CPU with --no-kv-offload, on
    // the GPU when any layer is offloaded (exact split), from the probe
    // estimate, otherwise all-CPU. "" = unknown.
    var ctxOn = ""
    if (m.noKvOffload === true) ctxOn = "CPU"
    else if (gpu > 0 && splitSource !== "probe") ctxOn = "GPU"
    else if (estProbe !== null && estProbe.ctxOn !== "") ctxOn = estProbe.ctxOn
    else if (main > 0 && cpu >= main) ctxOn = "CPU"

    var kvBytes = num(m.kvCacheBytes)

    var lines = []
    // Model Size shows the main-stack layer count; the MTP suffix renders only
    // when MTP layers are present (non-MTP models unchanged). The byte total is
    // base + draft file size for separate-draft models.
    var totalSize = (sizeBytes >= 0) ? sizeBytes + (draftSize > 0 ? draftSize : 0) : -1
    var sizeLine = "Model Size: " + nn((main >= 0) ? main : total) + " layers" + root._mtpParen(mtp, mtp, mtpSize)
    sizeLine += " | " + gb(totalSize)
    lines.push(sizeLine)
    var pctGpu = pGpu >= 0 ? (pctEst ? "~" : "") + pGpu + "%" : "\u2014"
    var pctCpu = pCpu >= 0 ? (pctEst ? "~" : "") + pCpu + "%" : "\u2014"
    lines.push("GPU Layers: " + nnP(gpu) + root._mtpParen(mtpGpu, mtp, mtpSize) + " | " + gbWg(gpuW) + " | " + pctGpu)
    lines.push("CPU Layers: " + nnP(cpu) + root._mtpParen(mtpCpu, mtp, mtpSize) + " | " + gbWc(cpuW) + " | " + pctCpu)
    var ctxLine = "Context: " + (ctxLen >= 0 ? comma(ctxLen) + " tok" : "\u2014")
    if (ctxOn !== "") ctxLine += " on " + ctxOn
    lines.push(ctxLine)
    var kvLine = "KV Cache: " + (kvBytes > 0 ? "~" + s.formatGB(kvBytes) : "\u2014")
    if (m.cacheK !== "" || m.cacheV !== "") {
      kvLine += " (K " + (m.cacheK !== "" ? m.cacheK : "f16") + " / V " + (m.cacheV !== "" ? m.cacheV : "f16") + ")"
    }
    if (ctxOn !== "") kvLine += " on " + ctxOn
    lines.push(kvLine)
    // Weights-on-device + KV when the cache is colocated there; "—" otherwise.
    var gpuTotal = -1
    if (gpuW >= 0 && kvBytes >= 0 && ctxOn === "GPU") gpuTotal = gpuW + kvBytes
    lines.push("GPU Total: " + (gpuTotal >= 0 ? "~" + s.formatGB(gpuTotal) : "\u2014"))
    var cpuTotal = -1
    if (cpuW >= 0 && kvBytes >= 0 && ctxOn === "CPU") cpuTotal = cpuW + kvBytes
    lines.push("CPU Total: " + (cpuTotal >= 0 ? "~" + s.formatGB(cpuTotal) : "\u2014"))

    return s.sanitize(lines.join("\n"))
  }

  Column {
    id: contentCol
    width: parent.width
    spacing: Style.space(10)

    // ── Running models ──────────────────────────────────────────
    PanelSeparator {
      visible: root.service.running && root.service.runningModels.length > 0
      foreground: root.foreground
    }

    Column {
      visible: root.service.running && root.service.runningModels.length > 0
      width: parent.width
      spacing: Style.space(10)

      PanelSectionHeader {
        text: "LOADED MODELS"
        foreground: root.foreground
        fontFamily: root.fontFamily
      }

      Column {
        width: parent.width
        spacing: Style.space(10)

        Repeater {
          model: root.service.runningModels

          // One block per loaded model: a minor separator above every block but
          // the first, the model info row, then its own Unload button at the
          // bottom of that model's info. The major separator before ALL MODELS
          // (below) is unchanged and stays more prominent than these dividers.
          Column {
            id: modelBlock
            required property var modelData
            width: parent.width
            spacing: Style.space(6)

            Rectangle {
              visible: modelBlock.index > 0
              width: parent.width
              height: 1
              color: Qt.darker(root.foreground, 2.4)
              opacity: 0.35
            }

            CursorSurface {
              width: parent.width
              foreground: root.foreground
              implicitHeight: modelRow.implicitHeight + Style.spacing.rowPaddingX

              RowLayout {
                id: modelRow
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: Style.space(10)
                anchors.rightMargin: Style.space(10)
                spacing: Style.space(8)

                Text {
                  text: "󰚩"
                  color: Color.accent
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  textFormat: Text.PlainText
                  Layout.alignment: Qt.AlignVCenter
                }

                ColumnLayout {
                  Layout.fillWidth: true
                  spacing: Style.space(1)

                  Text {
                    Layout.fillWidth: true
                    text: root.service.sanitize(modelData.name || "Unknown")
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    textFormat: Text.PlainText
                    elide: Text.ElideRight
                  }

                   Text {
                     Layout.fillWidth: true
                     text: {
                       if (root.service.backend === "llama.cpp") {
                         return root.llamaDetailBlock(modelData)
                       }
                       var ollamaLine = root.ollamaDetailLine(modelData)
                       if (ollamaLine !== "") return ollamaLine
                       return "Memory unavailable"
                     }
                     visible: text !== ""
                     color: root.dim
                     font.family: root.fontFamily
                     font.pixelSize: Style.font.caption
                     textFormat: Text.PlainText
                     elide: Text.ElideRight
                   }
                }
              }
            }

            // Per-model Unload button, at the bottom of this model's info block.
            UI.SettingsButton {
              visible: root.service.backend === "llama.cpp"
              width: parent.width
              label: "Unload"
              foreground: root.foreground
              fontFamily: root.fontFamily
              enabled: !root.service.busy
              onClicked: root.unloadRequested(String(modelData.id || ""))
            }
          }
        }
      }
    }

    // ── Available models ─────────────────────────────────────────
    PanelSeparator {
      visible: root.service.installed && root.service.models.length > 0
      foreground: root.foreground
    }

    Column {
      visible: root.service.installed && root.service.models.length > 0
      width: parent.width
      spacing: Style.space(10)

      PanelSectionHeader {
        text: {
          var local = 0
          var cloud = 0
          for (var i = 0; i < root.service.models.length; i++) {
            if (root.service.models[i].isCloud) cloud++
            else local++
          }
          var parts = []
          if (local > 0) parts.push(local + " local")
          if (cloud > 0) parts.push(cloud + " cloud")
          var count = parts.length > 0 ? "  " + parts.join(" \u00b7 ") : ""
          return (root.service.running ? "ALL MODELS" : "AVAILABLE MODELS") + count
        }
        foreground: root.foreground
        fontFamily: root.fontFamily
      }

      Column {
        width: parent.width
        spacing: Style.space(6)

        Repeater {
          model: root.service.models

          CursorSurface {
            required property var modelData
            width: parent.width
            foreground: root.foreground
            implicitHeight: availRow.implicitHeight + Style.spacing.rowPaddingX

            RowLayout {
              id: availRow
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              anchors.leftMargin: Style.space(10)
              anchors.rightMargin: Style.space(10)
              spacing: Style.space(8)

              Text {
                text: {
                  if (modelData.isCloud) return "\u2601"
                  for (var i = 0; i < root.service.runningModels.length; i++) {
                    if (String(root.service.runningModels[i].name) === String(modelData.name)) return "\u25cf"
                  }
                  return "\u25cb"
                }
                color: {
                  if (modelData.isCloud) return Color.accent
                  for (var i = 0; i < root.service.runningModels.length; i++) {
                    if (String(root.service.runningModels[i].name) === String(modelData.name)) return Color.accent
                  }
                  return root.dim
                }
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                textFormat: Text.PlainText
                Layout.alignment: Qt.AlignVCenter
              }

              ColumnLayout {
                Layout.fillWidth: true
                spacing: Style.space(1)

                Text {
                  Layout.fillWidth: true
                  text: root.service.sanitize(modelData.name || "Unknown")
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  textFormat: Text.PlainText
                  elide: Text.ElideRight
                }

                Text {
                  Layout.fillWidth: true
                  text: {
                    var parts = []
                    if (modelData.isCloud) parts.push("Cloud")
                    else if (modelData.size) parts.push("Model size: " + String(modelData.size))
                    if (modelData.modified) parts.push("Downloaded: " + String(modelData.modified))
                    return root.service.sanitize(parts.join(" | "))
                  }
                  visible: text !== ""
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  textFormat: Text.PlainText
                  elide: Text.ElideRight
                }
              }
            }
          }
        }
      }
    }

    // ── No models loaded ─────────────────────────────────────────
    PanelSeparator {
      visible: root.service.running && root.service.runningModels.length === 0
      foreground: root.foreground
    }

    Text {
      visible: root.service.running && root.service.runningModels.length === 0
      width: parent.width
      text: root.service.models.length === 0 ? "No local models. Cloud models accessed via API are not listed by " + root.service.backendDisplayName + "." : "No models currently loaded. Service is idle."
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      textFormat: Text.PlainText
      wrapMode: Text.WordWrap
      horizontalAlignment: Text.AlignHCenter
    }
  }
}
