import QtQuick
import Quickshell
import Quickshell.Io
import "asserts.js" as A

// E2E: Tier-5 models.ini preset reader, driven against the real Service and the
// real ModelsSection in an isolated sandbox. The fixture models.ini is seeded
// by common.sh; the harness feeds its bytes through the SAME bounded buffer
// path as _onPresetLine/_finishPreset (single source of truth — the file is
// read over FileView, never hand-built).
//
// Consumer A (service stopped): the available list must come from the preset —
// a fit-model entry with its configured intent ("preset intent: all GPU
// layers", inherited from the [*] globals).
// Consumer B (service running): a fit-model loaded with NO --n-gpu-layers must
// resolve its split from the preset as an EXACT value — source "preset", no `~`
// in the rendered GPU Layers line, context on GPU.
Item {
  id: root
  property var s: null
  property var sec: null

  FileView { id: fv; printErrors: false; blockAllReads: true }
  function readFile(path) { fv.path = ""; fv.path = path; return fv.text() }

  function modelsSectionUrl() {
    return "file://" + s.configPath.replace(/configs\/.*/, "sections/ModelsSection.qml")
  }
  function modelsIniPath() {
    return s.configPath.replace(/\/configs\/.*/, "") + "/models.ini"
  }

  function lineOf(block, prefix) {
    var lines = String(block || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      if (lines[i].indexOf(prefix) === 0) return lines[i]
    }
    return ""
  }

  Component.onCompleted: {
    s = A.service("@SERVICE_QML_PATH@", root, "llama.cpp")
    if (!s) return
    A.ok("preset-e2e/service-created", s !== null, true)
    A.ok("preset-e2e/fixture-seeded", readFile(modelsIniPath()).indexOf("n-gpu-layers = all") !== -1)
    s.configPresetPath = modelsIniPath()

    // ── Consumer A: service stopped → preset is the model list ─────────────
    s._presetBuffer = readFile(modelsIniPath())
    s._finishPreset()
    A.ok("preset-e2e/stopped-state", s.running === false)
    A.ok("preset-e2e/stopped-models", s.models.length >= 1)
    A.check("preset-e2e/stopped-name", s.models[0].name, "fit-model.gguf")
    A.check("preset-e2e/stopped-intent", s.models[0].presetIntent, "preset intent: all GPU layers")
    A.check("preset-e2e/stopped-path", s.models[0].presetPath, "/m/fit-model.gguf")

    // ── Consumer B: service running, API leaves ngl unset (fit = on) ───────
    s.running = true
    s._jsonBuffer = JSON.stringify({ data: [
      { id: "fit-model",
        status: { value: "loaded", processor: "CPU", args: [] },
        meta: { size: "9200000000", n_ctx: "131072" } }
    ] })
    s._finishJsonModels()
    A.ok("preset-e2e/running-populated", s.runningModels.length === 1)
    var entry = s.runningModels[0]
    entry.modelPath = "/m/fit-model.gguf"
    // Fold the real GGUF header (the no-load read is integration-tested against
    // a real .gguf; here the buffer is the parsed marker stream it emits).
    s._ggufCache = ({})
    s._ggufPath = "/m/fit-model.gguf"
    // sliding_window=0 is a real declaration (a dense cache), which is what lets
    // the header derivation answer at all: without it this hybrid is unknown
    // until the Tier-3.5 probe runs, and there would be no KV line to assert.
    s._ggufBuffer = "GGUF-OK\narch=qwen35\nblock_count=80\nhead_count=24\nhead_count_kv=8\nembedding_length=5120\nsliding_window=0\n"
    s._finishGguf()
    A.check("preset-e2e/mainGpu", entry.mainGpu, 80)
    A.check("preset-e2e/mainCpu", entry.mainCpu, 0)
    A.check("preset-e2e/split-source", entry._gpuSplitSource, "preset")
    A.check("preset-e2e/ngl-resolved", entry.ngl, "all")

    var msec = Qt.createComponent(modelsSectionUrl())
    A.check("preset-e2e/section-compiles", msec.status, 1)
    if (msec.status !== 1) { A.fail("preset-e2e section error: " + msec.errorString()); A.finish(); return }
    sec = msec.createObject(root, {
      service: s,
      foreground: "#eeeeee", dim: "#888888", urgent: "#ff5555", fontFamily: "monospace"
    })
    A.ok("preset-e2e/section-instantiated", sec !== null)
    if (!sec) { A.finish(); return }

    var d = sec.llamaDetailBlock(entry)
    // A resolved preset split is EXACT: markers mirror "api" (no `~`).
    var gpuLine = lineOf(d, "GPU Layers:")
    var cpuLine = lineOf(d, "CPU Layers:")
    A.ok("preset-e2e/gpu-layers-line", gpuLine.indexOf("GPU Layers: 80") === 0)
    A.ok("preset-e2e/gpu-layers-exact", gpuLine.indexOf("~") === -1)
    A.ok("preset-e2e/cpu-layers-exact", cpuLine.indexOf("CPU Layers: 0") === 0 && cpuLine.indexOf("~") === -1)
    A.ok("preset-e2e/kv-estimate-present", String(d).indexOf("KV Cache: ~") !== -1)
    // `n-gpu-layers = all` is NOT proof of where the cache went — the live
    // gemma-4 worker has every layer on the device and its cache in host RAM —
    // so with no cgroup readings the Context line must make no device claim.
    A.check("preset-e2e/context-device-unknown", lineOf(d, "Context:"), "Context: 131,072 tok")
    A.ok("preset-e2e/kv-line-device-unknown", lineOf(d, "KV Cache:").indexOf("KV Cache: ~") === 0
      && lineOf(d, "KV Cache:").indexOf(" on ") === -1)
    // Nor may the cache be folded into a device total on a guess.
    A.check("preset-e2e/gpu-total-weights-only", lineOf(d, "GPU Total:"),
      "GPU Total: ~" + s.formatGB(9200000000))

    // With a cgroup reading that locates the cache, the same entry does place
    // it — and then both the Context line and the GPU total must show it.
    s.serviceMemoryBytes = 400000000
    s.serviceVramBytes = 8 * 1024 * 1024 * 1024
    var dGpu = sec.llamaDetailBlock(entry)
    A.ok("preset-e2e/context-on-gpu", String(dGpu).indexOf("Context: 131,072 tok on GPU") !== -1)
    A.ok("preset-e2e/kv-on-gpu", lineOf(dGpu, "KV Cache:").indexOf(" on GPU") !== -1)
    A.ok("preset-e2e/gpu-total-includes-kv", lineOf(dGpu, "GPU Total:")
      !== lineOf(d, "GPU Total:"))
    // The flag still overrides any reading.
    entry.noKvOffload = true
    var dCpu = sec.llamaDetailBlock(entry)
    A.ok("preset-e2e/no-kv-offload-beats-reading", String(dCpu).indexOf("Context: 131,072 tok on CPU") !== -1)
    entry.noKvOffload = false
    s.serviceMemoryBytes = -1
    s.serviceVramBytes = -1

    A.finish()
  }
}