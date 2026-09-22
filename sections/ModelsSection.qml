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

  // Render a llama.cpp loaded-model detail block: Model Size / GPU Layers /
  // CPU Layers / Context / KV Cache / Quant (+params +expected weight) /
  // GPU Total / CPU Total (the Quant line appears when the quant from the GGUF
  // header — Tier 2 — or the exact meta.n_params — Tier 1 — is known). Values
  // arrive on `modelData` (see Service.qml _finishJsonModels/_applyGguf);
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
    var mtpGpu = num(m.mtpGpu)
    var mtpCpu = num(m.mtpCpu)
    var ctxLen = num(m.contextLen)
    var sizeBytes = num(m.sizeBytes)
    var draftSize = num(m.draftSizeBytes)

    // Single source of precedence: Service.qml's _resolveFieldSources tags every
    // field with its winning Tier (1=API / 2=GGUF / 3=probe / 4=derivation /
    // 5=preset) and its render marker ("", "~", "—") exactly once, so the
    // decisions below consume resolved values instead of re-deriving the ladder.
    // A VRAM reading that lands after the GGUF header still shows as a live
    // Tier-3 estimate (via the resolver's gpuSplit) without waiting for the
    // next /v1/models poll — same as the old inline estProbe.
    var r = s._resolveFieldSources(m, {
      vramBytes: s.serviceVramBytes,
      memBytes: s.serviceMemoryBytes,
      presetSection: s._presetSectionFor(m)
    })
    var gpuSplit = r.gpuSplit
    var gpu = gpuSplit.value ? num(gpuSplit.value.mainGpu) : -1
    var cpu = gpuSplit.value ? num(gpuSplit.value.mainCpu) : -1

    function gb(b) { return b >= 0 ? s.formatGB(b) : "\u2014" }
    function nn(n) { return n >= 0 ? String(n) : "\u2014" }
    function nnP(n) { return n >= 0 ? (gpuSplit.marker === "~" ? "~" : "") + String(n) : "\u2014" }
    function comma(n) {
      var d = String(Math.round(n))
      var out = ""
      for (var i = d.length - 1, c = 0; i >= 0; i--, c++) {
        if (c > 0 && c % 3 === 0) out = "," + out
        out = d.charAt(i) + out
      }
      return out
    }

    // Per-device weight bytes: from the resolver (exact layer-ratio split when
    // the split is exact, otherwise the measured per-device footprint), plus the
    // MTP share when its placement is known. Unknown → -1 ("—").
    // `exact` mirrors the old gpuExact/cpuExact: an exact (api/preset) split.
    var exact = (gpuSplit.marker === "" && gpu >= 0 && cpu >= 0 && sizeBytes > 0 && total > 0)
    var gpuW = r.weightBytes.gpu
    if (exact && mtp > 0 && mtpGpu >= 0 && mtpSize > 0) gpuW += Math.round(mtpSize * mtpGpu / mtp)
    var cpuW = r.weightBytes.cpu
    if (exact && mtp > 0 && mtpCpu >= 0 && mtpSize > 0) cpuW += Math.round(mtpSize * mtpCpu / mtp)
    var gpuEst = r.weightBytes.gpuMarker === "~" || (exact && mtp > 0 && (mtpGpu < 0 || mtpSize < 0))
    var cpuEst = r.weightBytes.cpuMarker === "~" || (exact && mtp > 0 && (mtpCpu < 0 || mtpSize < 0))

    function gbWg(b) { return b >= 0 ? (gpuEst ? "~" : "") + s.formatGB(b) : "\u2014" }
    function gbWc(b) { return b >= 0 ? (cpuEst ? "~" : "") + s.formatGB(b) : "\u2014" }
    // Percent of the MAIN stack on each device; MTP is its own parenthetical.
    var pGpu = -1
    var pCpu = -1
    var pctEst = false
    if (main > 0 && gpu >= 0 && cpu >= 0) {
      pGpu = s._percentLayersOnGPU(gpu, main)
      pCpu = s._percentLayersOnCPU(cpu, main)
      pctEst = (gpuSplit.marker === "~")
    }

    // Where the context/KV cache lives: pinned to CPU with --no-kv-offload, on
    // the GPU when any layer is offloaded (exact split), from the probe
    // estimate, otherwise all-CPU. "" = unknown.
    var ctxOn = ""
    if (m.noKvOffload === true) ctxOn = "CPU"
    else if (gpu > 0 && gpuSplit.marker === "") ctxOn = "GPU"
    else if (gpuSplit.value && gpuSplit.value.ctxOn !== undefined && gpuSplit.value.ctxOn !== "") ctxOn = gpuSplit.value.ctxOn
    else if (main > 0 && cpu >= main) ctxOn = "CPU"

    var kvBytes = num(m.kvCacheBytes)

    var lines = []
    // Quant label (gguf ftype enum from the GGUF header's general.file_type —
    // Tier 2, exact), param count (meta.n_params — Tier 1, exact), and the
    // derived expected weight size (~n_params × bytes-per-param — the only `~`
    // on this line, a sanity cross-check against the reported file size).
    // Each unknown renders "—"; the line is dropped when both quant and params
    // are unknown. Rendered first, above Model Size.
    if (r.params.value >= 0 || r.quant.value >= 0) {
      var qLabel = (r.quant.value >= 0) ? s._ftypeLabel(r.quant.value) : -1
      var pCount  = (r.params.value >= 0) ? s._formatCount(r.params.value) : -1
      var q = (typeof qLabel === "string") ? qLabel : "\u2014"
      var p = (typeof pCount  === "string") ? pCount  : "\u2014"
      lines.push("Quant: " + q + " | " + p + " params"
        + (r.expectedWeight.value >= 0 ? " | ~" + s.formatGB(r.expectedWeight.value) + " expected" : ""))
    }
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
                    if (modelData.presetIntent) parts.push(String(modelData.presetIntent))
                    else if (modelData.modified) parts.push("Downloaded: " + String(modelData.modified))
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
