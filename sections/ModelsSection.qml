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

  // Render a llama.cpp loaded-model detail block: Model Size / GPU Layers /
  // CPU Layers / Draft (only when MTP layers are present) / Context / KV Cache
   // / Quant (+params) / GPU Total / CPU Total (the Quant line
  // appears when the quant from the GGUF header — Tier 2 — or the exact
  // meta.n_params — Tier 1 — is known). Values arrive on `modelData` (see
  // Service.qml _finishJsonModels/_applyGguf);
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

    // Core-only per-device weight bytes — what the layer lines show.
    var coreGpuW = r.weightBytes.gpu
    var coreCpuW = r.weightBytes.cpu
    // Combined per-device weights (core + draft/MTP share) — what the totals show.
    var gpuW = coreGpuW
    if (coreGpuW >= 0 && mtp > 0 && mtpGpu >= 0 && mtpSize > 0)
      gpuW += Math.round(mtpSize * mtpGpu / mtp)
    var cpuW = coreCpuW
    if (coreCpuW >= 0 && mtp > 0 && mtpCpu >= 0 && mtpSize > 0)
      cpuW += Math.round(mtpSize * mtpCpu / mtp)
    var gpuEst = r.weightBytes.gpuMarker === "~"
    var cpuEst = r.weightBytes.cpuMarker === "~"

    function gbWg(b) { return b >= 0 ? (gpuEst ? "~" : "") + s.formatGB(b) : "\u2014" }
    function gbWc(b) { return b >= 0 ? (cpuEst ? "~" : "") + s.formatGB(b) : "\u2014" }
    // Percent of the MAIN stack on each device; MTP/draft get their own Draft row.
    var pGpu = -1
    var pCpu = -1
    var pctEst = false
    if (main > 0 && gpu >= 0 && cpu >= 0) {
      pGpu = s._percentLayersOnGPU(gpu, main)
      pCpu = s._percentLayersOnCPU(cpu, main)
      pctEst = (gpuSplit.marker === "~")
    }

    // Where the context/KV cache lives. `_kvPlacement` (Service.qml) is the only
    // decider: `--no-kv-offload` and a zero offload count are exact, and the rest
    // is a measurement — a KV-sized anonymous host block proves the cache is in
    // RAM, and its absence from host RAM plus the presence of device memory
    // proves it is on the device. Being offloaded does NOT mean the cache is on
    // the GPU (llama.cpp's `--fit` drops it to host RAM when weights + KV no
    // longer fit, which is exactly the Gemma4 case here), and neither does
    // EVERY layer being offloaded — that is the same failure on a fully
    // offloaded stack. "" = unknown: the Context and KV lines then omit the
    // device and neither device total claims the cache.
    var kv = r.kvBytes
    var kvBytes = num(kv.value)
    var ctxOn = s._kvPlacement(m.noKvOffload === true, gpu, main, kvBytes, {
      memBytes: s.serviceMemoryBytes,
      vramBytes: s.serviceVramBytes,
      // Both service probes read the whole cgroup: with more than one model
      // loaded neither reading belongs to this model alone.
      sole: (s.runningModels.length === 1)
    })

    var lines = []
    // Quant label (gguf ftype enum from the GGUF header's general.file_type —
    // Tier 2, exact) and param count (meta.n_params — Tier 1, exact). Each
    // unknown renders "—"; the line is dropped when both quant and params are
    // unknown. Rendered first, above Model Size.
    if (r.params.value >= 0 || r.quant.value >= 0) {
      var qLabel = (r.quant.value >= 0) ? s._ftypeLabel(r.quant.value) : -1
      var pCount  = (r.params.value >= 0) ? s._formatCount(r.params.value) : -1
      var q = (typeof qLabel === "string") ? qLabel : "\u2014"
      var p = (typeof pCount  === "string") ? pCount  : "\u2014"
      lines.push("Quant: " + q + " | " + p + " params")
    }
    // Model Size shows the main-stack layer count and CORE-only bytes (base
    // minus built-in MTP; base file for separate draft) so it doesn't overlap
    // the Draft row below.
    var coreSize = -1
    if (sizeBytes >= 0) {
      if (draftSize > 0)                       coreSize = sizeBytes                       // separate draft: base file is pure main
      else if (mtp > 0 && mtpSize > 0)        coreSize = Math.max(0, sizeBytes - mtpSize) // built-in MTP in one file
      else                                    coreSize = sizeBytes
    }
    lines.push("Model Size: " + nn((main >= 0) ? main : total) + " layers | " + gb(coreSize))
    var pctGpu = pGpu >= 0 ? (pctEst ? "~" : "") + pGpu + "%" : "\u2014"
    var pctCpu = pCpu >= 0 ? (pctEst ? "~" : "") + pCpu + "%" : "\u2014"
    lines.push("GPU Layers: " + nnP(gpu) + " | " + gbWg(coreGpuW) + " | " + pctGpu)
    lines.push("CPU Layers: " + nnP(cpu) + " | " + gbWc(coreCpuW) + " | " + pctCpu)
    if (mtp > 0) {
      var spec  = String(m.specType || "").trim()
      var dType = (spec !== "") ? spec : "mtp"
      var dSize = (mtpSize > 0) ? mtpSize : ((draftSize > 0) ? draftSize : -1)
      var dOn   = ""
      if (mtpGpu >= 0 && mtpCpu >= 0) {
        if (mtpGpu >= mtp && mtpCpu === 0)       dOn = "on GPU"
        else if (mtpCpu >= mtp && mtpGpu === 0) dOn = "on CPU"
        else if (mtpGpu > 0 && mtpCpu > 0)      dOn = "on GPU/CPU"
        else if (mtpGpu > 0)                    dOn = "on GPU"
        else if (mtpCpu > 0)                   dOn = "on CPU"
      }
      var dLayers = (mtp === 1) ? "1 layer" : mtp + " layers"
      lines.push("Draft: " + dType + " | " + dLayers + " | " + gb(dSize) + (dOn !== "" ? " " + dOn : ""))
    }
    var ctxLine = "Context: " + (ctxLen >= 0 ? comma(ctxLen) + " tok" : "\u2014")
    if (ctxOn !== "") ctxLine += " on " + ctxOn
    lines.push(ctxLine)
    var kvLine = "KV Cache: " + (kvBytes > 0
      ? (kv.marker === "~" ? "~" : "") + s.formatGB(kvBytes) : "\u2014")
    if (m.cacheK !== "" || m.cacheV !== "") {
      kvLine += " (K " + (m.cacheK !== "" ? m.cacheK : "f16") + " / V " + (m.cacheV !== "" ? m.cacheV : "f16") + ")"
    }
    if (ctxOn !== "") kvLine += " on " + ctxOn
    lines.push(kvLine)
    // Per-device totals: the combined weights always show when known (including
    // 0.0 GB for a fully-empty-but-known device), and KV is added only when the
    // cache is colocated on that device. A split model therefore shows its CPU
    // weight bytes even though the KV cache is on GPU.
    var gpuTotal = -1
    if (gpuW >= 0) { gpuTotal = gpuW; if (kvBytes > 0 && ctxOn === "GPU") gpuTotal += kvBytes }
    lines.push("GPU Total: " + (gpuTotal >= 0 ? "~" + s.formatGB(gpuTotal) : "\u2014"))

    var cpuTotal = -1
    if (cpuW >= 0) { cpuTotal = cpuW; if (kvBytes > 0 && ctxOn === "CPU") cpuTotal += kvBytes }
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
