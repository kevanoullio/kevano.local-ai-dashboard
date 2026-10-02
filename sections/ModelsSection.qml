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

    // ONE reader, and it is a reader: Service._resolveFieldSources now returns
    // store-resolved values with their STATE, so the block below renders what the
    // resolver decided instead of re-deciding it. Three things follow from that:
    //
    //  - "…" (in flight) and "—" (looked for, not found) are different states
    //    here, so a probe still running renders as waiting rather than as
    //    missing. Before, both arrived as a single em-dash.
    //  - A marker belongs to the FIELD it belongs to. The layer lines read
    //    mainGpu's / mainCpu's own markers rather than the split composite's, so
    //    an exact GPU count next to an estimated CPU count renders "~" on the CPU
    //    line only.
    //  - A per-device total is the worst of its inputs, not a hardcoded "~".
    var r = s._resolveFieldSources(m, {
      vramBytes: s.serviceVramBytes,
      memBytes: s.serviceMemoryBytes,
      presetSection: s._presetSectionFor(m)
    })
    var PENDING = s.stateEnum.PENDING
    var ABSENT = s.stateEnum.ABSENT
    var EM = "\u2014"

    var main = num(r.mainLayers.value)
    var mtp = num(r.mtpLayers.value)
    var mtpSize = num(r.mtpSizeBytes.value)
    var draftSize = num(r.draftSizeBytes.value)
    var ctxLen = num(r.contextLen.value)
    var kvBytes = num(r.kvBytes.value)
    var gpuSplit = r.gpuSplit
    var gpu = gpuSplit.value ? num(gpuSplit.value.mainGpu) : -1
    var cpu = gpuSplit.value ? num(gpuSplit.value.mainCpu) : -1

    function gb(b) { return b >= 0 ? s.formatGB(b) : EM }
    // A value still in flight renders "…"; one that was looked for and not found
    // renders "—". `field` carries both the value and its state, so this is the
    // only place the distinction is made.
    function val(field) {
      if (!field) return EM
      if (field.state === ABSENT) return EM
      if (field.state === PENDING) return "\u2026"
      return (typeof field.value === "number" && field.value >= 0) ? field.value : EM
    }
// A count with its OWN field's marker: exact → "", estimated → "~".
    function nn(field) {
      var v = val(field)
      if (v === "…" || v === EM) return v
      return (field.glyph === "~" ? "~" : "") + String(v)
    }
    // A dtype string: absent reads "—", still resolving reads "…".
    function dtypeText(field) {
      if (field.state === PENDING) return "…"
      if (field.state === ABSENT) return EM
      var t = String(field.value === null || field.value === undefined ? "" : field.value).trim()
      return t === "" ? EM : t
    }
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
    var coreGpuW = num(r.weightBytes.gpu)
    var coreCpuW = num(r.weightBytes.cpu)
    // Combined per-device weights (core + draft/MTP share) — what the totals show.
    var mtpGpu = num(r.mtpGpu.value), mtpCpu = num(r.mtpCpu.value)
    var gpuW = coreGpuW
    if (coreGpuW >= 0 && mtp > 0 && mtpGpu >= 0 && mtpSize > 0)
      gpuW += Math.round(mtpSize * mtpGpu / mtp)
    var cpuW = coreCpuW
    if (coreCpuW >= 0 && mtp > 0 && mtpCpu >= 0 && mtpSize > 0)
      cpuW += Math.round(mtpSize * mtpCpu / mtp)
    function gbW(b, marker) {
      return b >= 0 ? (marker === "~" ? "~" : "") + s.formatGB(b) : EM
    }

    // Percent of the MAIN stack on each device; MTP/draft get their own Draft row.
    // The percentage's marker is the WORST of the three inputs it is computed from,
    // so a ratio built on an estimated count says so.
    var pGpu = -1
    var pCpu = -1
    var pctEst = (r.mainGpu.glyph === "~" || r.mainCpu.glyph === "~" || r.mainLayers.glyph === "~")
    if (main > 0 && gpu >= 0 && cpu >= 0) {
      pGpu = s._percentLayersOnGPU(gpu, main)
      pCpu = s._percentLayersOnCPU(cpu, main)
    }

    // Where the context/KV cache lives, straight from the resolver's placement
    // ladder. Being offloaded does NOT mean the cache is on the GPU (llama.cpp's
    // `--fit` drops it to host RAM when weights + KV no longer fit), and neither
    // does EVERY layer being offloaded. "" = still deciding or unattributable: the
    // Context and KV lines then omit the device and neither device total claims
    // the cache.
    var ctxOn = (r.kvLocation.state === ABSENT || r.kvLocation.state === PENDING)
      ? "" : String(r.kvLocation.value || "")

    var lines = []
    // Quant label (gguf ftype enum from the GGUF header's general.file_type —
    // tier 2, exact) and param count (meta.n_params — tier 1, exact). Each half
    // renders its OWN "…"/"—", and the line is never dropped: a row whose shape
    // depends on which half is missing is a row no test can assert on.
    var qLabel = (r.quant.state === PENDING) ? "\u2026" : ((r.quant.value >= 0) ? s._ftypeLabel(r.quant.value) : EM)
    var pCount = (r.params.state === PENDING) ? "\u2026" : ((r.params.value >= 0) ? s._formatCount(r.params.value) : EM)
    lines.push("Quant: " + qLabel + " | " + pCount + " params")
    // Model Size shows the main-stack layer count and CORE-only bytes (base minus
    // built-in MTP; the whole base file when the draft is a separate file) so it
    // doesn't overlap the Draft row below.
    lines.push("Model Size: " + nn(r.mainLayers.state === ABSENT ? r.totalLayers : r.mainLayers)
               + " layers | " + gb(num(r.coreSize.value)))
    var pctGpu = pGpu >= 0 ? (pctEst ? "~" : "") + pGpu + "%" : EM
    var pctCpu = pCpu >= 0 ? (pctEst ? "~" : "") + pCpu + "%" : EM
    lines.push("GPU Layers: " + nn(r.mainGpu) + " | " + gbW(coreGpuW, r.weightBytes.gpuMarker) + " | " + pctGpu)
    lines.push("CPU Layers: " + nn(r.mainCpu) + " | " + gbW(coreCpuW, r.weightBytes.cpuMarker) + " | " + pctCpu)
    if (mtp > 0) {
      var spec = String(r.specType.value || "").trim()
      var dType = (spec !== "") ? spec : "mtp"
      var dSize = (mtpSize > 0) ? mtpSize : ((draftSize > 0) ? draftSize : -1)
      var dOn = EM
      if (mtpGpu >= 0 && mtpCpu >= 0) {
        if (mtpGpu >= mtp && mtpCpu === 0)      dOn = "on GPU"
        else if (mtpCpu >= mtp && mtpGpu === 0) dOn = "on CPU"
        else if (mtpGpu > 0 && mtpCpu > 0)      dOn = "on GPU/CPU"
        else if (mtpGpu > 0)                    dOn = "on GPU"
        else if (mtpCpu > 0)                    dOn = "on CPU"
        // Both exhausted stays "—": omitting the device entirely made the row look
        // as though it had no badge at all.
      }
      var dLayers = (mtp === 1) ? "1 layer" : mtp + " layers"
      // The badge keeps its slot when it cannot be decided ("—"), so the row's
      // shape does not depend on what the draft placement turned out to be.
      lines.push("Draft: " + dType + " | " + dLayers + " | " + gb(dSize) + " | " + dOn)
    }
    var ctxLine = "Context: " + (ctxLen >= 0 ? comma(ctxLen) + " tok" : (r.contextLen.state === PENDING ? "\u2026" : EM))
    if (ctxOn !== "") ctxLine += " on " + ctxOn
    lines.push(ctxLine)
    var kvLine = "KV Cache: " + (kvBytes > 0
      ? (r.kvBytes.glyph === "~" ? "~" : "") + s.formatGB(kvBytes)
      : (r.kvBytes.state === PENDING ? "\u2026" : EM))
    // The dtype block renders whenever either dtype is resolved, including the
    // both-default case: `f16 / f16` is information (it says the default was not
    // overridden), and a row whose shape changes with the data is not. A dtype
    // still resolving renders "…" rather than hiding the block.
    if (r.cacheK.state !== ABSENT || r.cacheV.state !== ABSENT)
      kvLine += " (K " + dtypeText(r.cacheK) + " / V " + dtypeText(r.cacheV) + ")"
    if (ctxOn !== "") kvLine += " on " + ctxOn
    lines.push(kvLine)

    // Per-device totals. A cache that sits entirely on one device joins that
    // device's total. A SPLIT cache is added by tier 5's own per-device
    // `context` sums when it answered, because those are the only per-device KV
    // split that exists. When tier 5 did not answer, the cache is added to
    // NEITHER total and both are marked "~": rung 2 BOUNDS the split (at most
    // `memBytes` can be in host) without stating it, and a bounded range is not a
    // number — rendering mem/kv would put the error back.
    var kvGpuSplit = num(r.kvGpuBytes.value)
    var kvCpuSplit = num(r.kvCpuBytes.value)
    var splitKnown = (ctxOn === "GPU/CPU") && kvGpuSplit >= 0 && kvCpuSplit >= 0

    // One device's weights plus whatever of the cache PROVABLY belongs to it. The
    // marker is the worst of the inputs that went in, not a hardcoded "~".
    function deviceTotal(bytes, weightMarker, isGpu) {
      if (bytes < 0) return EM
      var total = bytes
      var mark = (weightMarker === "~") ? "~" : ""
      if (kvBytes > 0) {
        if ((isGpu && ctxOn === "GPU") || (!isGpu && ctxOn === "CPU")) {
          total += kvBytes
          if (r.kvBytes.glyph === "~") mark = "~"
        } else if (splitKnown) {
          // Tier 5's per-class `context` sums: the only per-device KV split that
          // exists. It is an estimate by construction, so the total is "~".
          total += isGpu ? kvGpuSplit : kvCpuSplit
          mark = "~"
        } else {
          // The cache belongs to neither total here: a split whose halves are
          // unknown, or a placement that is still deciding. Both under-report, so
          // both are "~". Rung 2 only BOUNDS the split (at most `memBytes` can be
          // in host), and a bounded range is not a number — rendering mem/kv would
          // put the error back.
          mark = "~"
        }
      }
      return mark + s.formatGB(total)
    }
    lines.push("GPU Total: " + deviceTotal(gpuW, r.weightBytes.gpuMarker, true))
    lines.push("CPU Total: " + deviceTotal(cpuW, r.weightBytes.cpuMarker, false))

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
