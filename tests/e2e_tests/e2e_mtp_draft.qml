import QtQuick
import Quickshell
import "asserts.js" as A

// E2E: the dedicated Draft row + per-device totals for MTP/draft models,
// rendered by the REAL ModelsSection.llamaDetailBlock against the real Service.
// Three arcs:
//   1. Built-in MTP - drives the real _finishGguf path (nextn_predict_layers=1
//      in the header): Model Size must show the CORE layer count (64, not 65)
//      and a "Draft: mtp | 1 layer | ... on GPU" row.
//   2. Separate draft (--model-draft) - base header (no npl) + draft header
//      (block_count=1): Model Size shows the base core size, Draft row carries
//      the draft file size.
//   3. Split totals (the bug fix) - a synthetic entry with total=65, mtp=1,
//      ngl="30" so the KV cache lands on GPU while CPU still owns weight bytes:
//      CPU Total must show those bytes (~X GB), not an em-dash.
Item {
  id: root
  property var s: null
  property var sec: null

  function modelsSectionUrl() {
    return "file://" + s.configPath.replace(/configs\/.*/, "sections/ModelsSection.qml")
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
    A.ok("mtp-e2e/service-created", s !== null, true)

    var BASE_SIZE = 14600000000
    var DRAFT_SIZE = 300000000
    var KV = 200000000

    var fixture = { data: [
      { id: "mtp-model",
        status: { value: "loaded", processor: "GPU",
                  args: ["/usr/bin/llama-server", "--model", "/m/mtp-model.gguf", "-ngl", "all"] },
        meta: { size: String(BASE_SIZE), n_ctx: "131072" } },
      { id: "draft-model",
        status: { value: "loaded", processor: "GPU",
                  args: ["/usr/bin/llama-server", "--model", "/m/draft-base.gguf",
                         "--model-draft", "/m/draft-model.gguf", "-ngl", "all", "-ngld", "all"] },
        meta: { size: String(BASE_SIZE), n_ctx: "131072" } }
    ] }
    s._jsonBuffer = JSON.stringify(fixture)
    s._finishJsonModels()
    A.ok("mtp-e2e/running-populated", s.runningModels.length === 2)

    // 1. Built-in MTP: the real header fold splits block_count=65 into
    //    main=64 + mtp=1 (ngl="all" -> everything on GPU).
    var b = s.runningModels[0]
    A.check("mtp-e2e/builtin-ngl", b.ngl, "all")
    s._ggufCache = ({})
    s._ggufPath = "/m/mtp-model.gguf"
    s._ggufBuffer = "GGUF-OK\narch=qwen35\nblock_count=65\nhead_count=24\nhead_count_kv=4\nembedding_length=5120\nnextn_predict_layers=1\n"
    s._finishGguf()
    var e1 = s.runningModels[0]
    A.check("mtp-e2e/builtin-mainLayers", e1.mainLayers, 64)
    A.check("mtp-e2e/builtin-mtpLayers", e1.mtpLayers, 1)
    A.ok("mtp-e2e/builtin-mtpSize", e1.mtpSizeBytes > 0)
    A.check("mtp-e2e/builtin-mainGpu", e1.mainGpu, 64)
    A.check("mtp-e2e/builtin-mtpGpu", e1.mtpGpu, 1)

    // 2. Separate draft: base header (no nextn_predict_layers) then the
    //    draft header (block_count=1 + its own file size).
    var d = s.runningModels[1]
    A.check("mtp-e2e/draft-ngl", d.ngl, "all")
    A.check("mtp-e2e/draft-ngld", d.nglDraft, "all")
    s._ggufPath = "/m/draft-base.gguf"
    s._ggufBuffer = "GGUF-OK\narch=qwen35\nblock_count=65\nhead_count=24\nhead_count_kv=4\nembedding_length=5120\n"
    s._finishGguf()
    s._ggufPath = "/m/draft-model.gguf"
    s._ggufBuffer = "GGUF-OK\narch=qwen35\nblock_count=1\nsize=" + DRAFT_SIZE + "\n"
    s._finishGguf()
    var e2 = s.runningModels[1]
    A.check("mtp-e2e/draft-mainLayers", e2.mainLayers, 65)
    A.check("mtp-e2e/draft-mtpLayers", e2.mtpLayers, 1)
    A.check("mtp-e2e/draft-mtpSize", e2.mtpSizeBytes, DRAFT_SIZE)
    A.check("mtp-e2e/draft-mtpGpu", e2.mtpGpu, 1)

    var msec = Qt.createComponent(modelsSectionUrl())
    A.check("mtp-e2e/section-compiles", msec.status, 1)
    if (msec.status !== 1) { A.fail("mtp-e2e section error: " + msec.errorString()); A.finish(); return }
    sec = msec.createObject(root, {
      service: s,
      foreground: "#eeeeee", dim: "#888888", urgent: "#ff5555", fontFamily: "monospace"
    })
    A.ok("mtp-e2e/section-instantiated", sec !== null)
    if (!sec) { A.finish(); return }

    // 1. Built-in MTP detail block: core layer count + Draft row on GPU.
    var d1 = sec.llamaDetailBlock(e1)
    A.ok("mtp-e2e/builtin-size-core", lineOf(d1, "Model Size:").indexOf("Model Size: 64 layers") === 0)
    var draftLine1 = lineOf(d1, "Draft:")
    A.ok("mtp-e2e/builtin-draft-line", draftLine1.indexOf("Draft: mtp | 1 layer |") === 0)
    A.ok("mtp-e2e/builtin-draft-on-gpu", draftLine1.indexOf("on GPU") !== -1)
    A.ok("mtp-e2e/builtin-gpu-layers", lineOf(d1, "GPU Layers:").indexOf("GPU Layers: 64") === 0)
    A.ok("mtp-e2e/builtin-cpu-layers", lineOf(d1, "CPU Layers:").indexOf("CPU Layers: 0") === 0)

    // 2. Separate draft detail block: base core size + Draft row file size.
    var d2 = sec.llamaDetailBlock(e2)
    A.ok("mtp-e2e/draft-size-base", lineOf(d2, "Model Size:").indexOf("Model Size: 65 layers | " + s.formatGB(BASE_SIZE)) === 0)
    var draftLine2 = lineOf(d2, "Draft:")
    A.ok("mtp-e2e/draft-file-size", draftLine2.indexOf("Draft: mtp | 1 layer | " + s.formatGB(DRAFT_SIZE)) === 0)
    A.ok("mtp-e2e/draft-on-gpu", draftLine2.indexOf("on GPU") !== -1)

    // 3. Split totals (the bug fix): the real _mtpSplit helper pins the
    //    exact split, then a synthetic entry proves CPU Total shows its
    //    weight bytes even though the KV cache is colocated on GPU.
    var split3 = s._mtpSplit("30", 65, 1)
    A.check("mtp-e2e/split-mainGpu", split3.mainGpu, 30)
    A.check("mtp-e2e/split-mainCpu", split3.mainCpu, 34)
    A.check("mtp-e2e/split-mtpGpu", split3.mtpGpu, 0)
    A.check("mtp-e2e/split-mtpCpu", split3.mtpCpu, 1)
    var e3 = {
      name: "split-model", id: "split-model",
      sizeBytes: BASE_SIZE, contextLen: 131072,
      ftype: -1, nParams: -1,
      modelPath: "", draftPath: "",
      ngl: "30", specType: "", cacheK: "", cacheV: "", noKvOffload: false,
      _gpuSplitSource: "api",
      totalLayers: 65, mainLayers: 64, mtpLayers: 1,
      mtpSizeBytes: DRAFT_SIZE, draftSizeBytes: -1,
      mainGpu: split3.mainGpu, mainCpu: split3.mainCpu,
      mtpGpu: split3.mtpGpu, mtpCpu: split3.mtpCpu,
      kvCacheBytes: KV
    }
    var d3 = sec.llamaDetailBlock(e3)
    var coreGpuW = Math.round(BASE_SIZE * 30 / 65)
    var coreCpuW = Math.round(BASE_SIZE * 34 / 65)
    A.ok("mtp-e2e/split-cpu-total-not-empty", lineOf(d3, "CPU Total:").indexOf("CPU Total: \u2014") !== 0)
    A.check("mtp-e2e/split-cpu-total", lineOf(d3, "CPU Total:"), "CPU Total: ~" + s.formatGB(coreCpuW + DRAFT_SIZE))
    A.check("mtp-e2e/split-gpu-total", lineOf(d3, "GPU Total:"), "GPU Total: ~" + s.formatGB(coreGpuW + KV))

    A.finish()
  }
}
