import QtQuick
import Quickshell
import "asserts.js" as A

// E2E: the Quant / params / expected-weight detail line. llama.cpp's /v1/models
// meta block serves n_params but NOT the quant (upstream), so the harness feeds
// the real Service the mock-fixture response (tests/lib/mocks/curl), then drives
// the quant through the real GGUF header path (general.file_type, Tier 2): the
// header is buffered and _finishGguf() folds file_type into the running entry.
// The rendered real ModelsSection.llamaDetailBlock() must show the exact line
// "Quant: q4_k_m | 30.5B params | ~<expected> expected" — no `~` on quant/params,
// and no Quant line at all when neither quant nor params is known.
Item {
  id: root
  property var s: null
  property var sec: null

  function modelsSectionUrl() {
    return "file://" + s.configPath.replace(/configs\/.*/, "sections/ModelsSection.qml")
  }

  function quantLineOf(block) {
    var lines = String(block || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      if (lines[i].indexOf("Quant:") === 0) return lines[i]
    }
    return ""
  }

  Component.onCompleted: {
    s = A.service("@SERVICE_QML_PATH@", root, "llama.cpp")
    if (!s) return
    A.ok("meta-e2e/service-created", s !== null, true)

    var fixture = { data: [
      { id: "test-model",
        status: { value: "loaded", processor: "CPU", args: [] },
        meta: { size: "1073741824", n_ctx: "131072", n_params: "30500000000" } },
      { id: "fit-model",
        status: { value: "loaded", processor: "CPU",
                  args: ["/usr/bin/llama-server", "--model", "/m/fit-model.gguf",
                         "--ctx-size", "131072", "--cache-type-k", "q8_0", "--cache-type-v", "q8_0"] },
        meta: { size: "9200000000", n_ctx: "131072" } }
    ] }
    s._jsonBuffer = JSON.stringify(fixture)
    s._finishJsonModels()
    A.ok("meta-e2e/running-populated", s.runningModels.length === 2)

    // test-model: params came from the API (Tier 1); quant arrives via GGUF.
    var testEntry = s.runningModels[0]
    A.check("meta-e2e/api-nparams", testEntry.nParams, 30500000000)
    A.check("meta-e2e/api-has-no-ftype", testEntry.ftype, -1)
    // Seed the real header-fold path: buffer a header that reports q4_k_m (15).
    testEntry.modelPath = "/m/test-model.gguf"
    s._ggufCache = ({})
    s._ggufPath = "/m/test-model.gguf"
    s._ggufBuffer = "GGUF-OK\narch=qwen35\nblock_count=65\nhead_count=24\nhead_count_kv=4\nembedding_length=5120\nfile_type=15\n"
    s._finishGguf()
    A.check("meta-e2e/ftype-from-gguf", testEntry.ftype, 15)

    var msec = Qt.createComponent(modelsSectionUrl())
    A.check("meta-e2e/section-compiles", msec.status, 1)  // Component.Ready
    if (msec.status !== 1) { A.fail("meta-e2e section error: " + msec.errorString()); A.finish(); return }
    sec = msec.createObject(root, {
      service: s,
      foreground: "#eeeeee", dim: "#888888", urgent: "#ff5555", fontFamily: "monospace"
    })
    A.ok("meta-e2e/section-instantiated", sec !== null)
    if (!sec) { A.finish(); return }

    var d1 = sec.llamaDetailBlock(testEntry)
    var d2 = sec.llamaDetailBlock(s.runningModels[1])

    var expBytes = Math.round(testEntry.nParams * s._bytesPerParam(testEntry.ftype))
    var wantLine = "Quant: q4_k_m | 30.5B params | ~" + s.formatGB(expBytes) + " expected"
    A.ok("meta-e2e/quant-line-exact", quantLineOf(d1) === wantLine)
    A.ok("meta-e2e/quant-line-present", quantLineOf(d1) !== "")
    // The Quant row is rendered FIRST, above the Model Size row.
    A.ok("meta-e2e/quant-first-line", String(d1).split("\n")[0].indexOf("Quant:") === 0)
    A.ok("meta-e2e/size-below-quant", String(d1).split("\n")[1].indexOf("Model Size:") === 0)
    // Only the expected-weight segment carries the estimate marker.
    var stripped = quantLineOf(d1).split("| ~")[0]
    A.ok("meta-e2e/quant-params-no-tilde", stripped.indexOf("~") === -1)
    // fit-model: no n_params and never got a header → whole line omitted.
    A.ok("meta-e2e/unknown-omits-quant", quantLineOf(d2) === "")

    A.finish()
  }
}