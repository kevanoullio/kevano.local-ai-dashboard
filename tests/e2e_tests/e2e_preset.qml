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
    A.ok("preset-e2e/service-created", s !== null)
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
    // The args carry the model path, because the resolver keys every store by
    // it: an entry whose path is patched onto the object AFTER the poll would
    // have no store, and the display would correctly render everything as
    // pending — a fixture bug that looks exactly like a resolver bug.
    s.running = true
    s._jsonBuffer = JSON.stringify({ data: [
      { id: "fit-model",
        status: { value: "loaded", processor: "CPU",
                  args: ["/usr/bin/llama-server", "--model", "/m/fit-model.gguf"] },
        meta: { size: "9200000000", n_ctx: "131072" } }
    ] })
    s._finishJsonModels()
    A.ok("preset-e2e/running-populated", s.runningModels.length === 1)
    var entry = s.runningModels[0]
    A.check("preset-e2e/entry-path", entry.modelPath, "/m/fit-model.gguf")
    // Fold the real GGUF header (the no-load read is integration-tested against
    // a real .gguf; here the buffer is the parsed marker stream it emits).
    s._ggufCache = ({})
    s._ggufPath = "/m/fit-model.gguf"
    // sliding_window=0 is a real declaration (a dense cache), which is what lets
    // the header derivation answer at all: without it this hybrid is unknown
    // until the tier-6 probe runs, and there would be no KV line to assert.
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
    // A resolved preset split is EXACT: the split COUNTS carry no "~". The weights
    // and the percentage beside them still do — the counts are exact, the bytes
    // they imply are an estimate, and the row says which is which per column.
    var gpuLine = lineOf(d, "GPU Layers:")
    var cpuLine = lineOf(d, "CPU Layers:")
    A.ok("preset-e2e/gpu-layers-line", gpuLine.indexOf("GPU Layers: 80") === 0)
    A.ok("preset-e2e/gpu-layers-exact", gpuLine.indexOf("~80") === -1)
    A.ok("preset-e2e/cpu-layers-exact", cpuLine.indexOf("CPU Layers: ~0 |") === 0
      && gpuLine.indexOf("GPU Layers: 80 |") === 0)
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

    // With a cgroup reading that PROVES a split, the same entry says so — and
    // then neither device total may claim the cache, because the device share is
    // exactly the quantity nobody measured. (Under the old ladder the below-KV
    // direction was pinned to "on GPU", which asserted a ratio it never had.)
    // The reading enters the store through the resolver, the way a refresh
    // delivers it: writing the Service property alone would leave the block
    // showing the previous poll's placement.
    s.serviceMemoryBytes = 400000000
    s.serviceVramBytes = 8 * 1024 * 1024 * 1024
    s.runningModels = s._resolveRunningEntries([entry])
    entry = s.runningModels[0]
    var dGpu = sec.llamaDetailBlock(entry)
    A.ok("preset-e2e/context-split", String(dGpu).indexOf("Context: 131,072 tok on GPU/CPU") !== -1)
    A.ok("preset-e2e/kv-split", lineOf(dGpu, "KV Cache:").indexOf(" on GPU/CPU") !== -1)
    // A proven split moves no bytes: the totals stay exactly the weight totals
    // the same entry shows with no placement at all.
    A.check("preset-e2e/gpu-total-excludes-split-cache", lineOf(dGpu, "GPU Total:"),
      lineOf(d, "GPU Total:"))
    A.check("preset-e2e/cpu-total-excludes-split-cache", lineOf(dGpu, "CPU Total:"),
      lineOf(d, "CPU Total:"))
    // The flag still overrides any reading — on a store created WITH the flag,
    // which is the only way it ever appears: tier 1 does not revise itself (a
    // flag cannot change without a reload, and a reload prunes the store), and
    // writing the entry's field after the poll would assert nothing at all. The
    // second model also drops sole attribution to "unattributable", so this
    // proves the flag outranks a reading it cannot even use.
    s._jsonBuffer = JSON.stringify({ data: [
      { id: "fit-model",
        status: { value: "loaded", processor: "CPU",
                  args: ["/usr/bin/llama-server", "--model", "/m/fit-model.gguf"] },
        meta: { size: "9200000000", n_ctx: "131072" } },
      { id: "cpu-model",
        status: { value: "loaded", processor: "CPU",
                  args: ["/usr/bin/llama-server", "--model", "/m/cpu-model.gguf",
                         "--no-kv-offload"] },
        meta: { size: "9200000000", n_ctx: "131072" } }
    ] })
    s._finishJsonModels()
    var cpuEntry = s.runningModels[1]
    A.check("preset-e2e/cpu-entry-path", cpuEntry ? cpuEntry.modelPath : "", "/m/cpu-model.gguf")
    // Same header for the second model: the ladder needs the cache size before it
    // can place anything, flag or not.
    s._ggufPath = "/m/cpu-model.gguf"
    s._ggufBuffer = "GGUF-OK\narch=qwen35\nblock_count=80\nhead_count=24\nhead_count_kv=8\nembedding_length=5120\nsliding_window=0\n"
    s._finishGguf()
    cpuEntry = s.runningModels[1]
    A.ok("preset-e2e/flag-store", cpuEntry
      && s._stores["/m/cpu-model.gguf"].get("noKvOffload").value === true)
    A.check("preset-e2e/unattributable", s._stores["/m/fit-model.gguf"].get("soleAttribution").value,
      "unattributable")
    var dCpu = sec.llamaDetailBlock(cpuEntry)
    A.ok("preset-e2e/no-kv-offload-beats-reading", String(dCpu).indexOf("Context: 131,072 tok on CPU") !== -1)
// ...and the cache follows the flag into the CPU total. Every layer is on the
    // GPU here, so the CPU's own weights are zero and its total IS the cache. The
    // GPU total is unchanged, because "on CPU" says nothing about it.
    A.ok("preset-e2e/no-kv-offload-cache-on-cpu", lineOf(dCpu, "KV Cache:").indexOf(" on CPU") !== -1)
    A.check("preset-e2e/no-kv-offload-cpu-total-has-cache", lineOf(dCpu, "CPU Total:"),
      "CPU Total: ~" + s.formatGB(71582788267))
    A.check("preset-e2e/no-kv-offload-gpu-total-untouched", lineOf(dCpu, "GPU Total:"),
      "GPU Total: ~" + s.formatGB(9200000000))
    s.serviceMemoryBytes = -1
    s.serviceVramBytes = -1

    // ── Tier 5: the per-device projection rows ─────────────────────────────
    // Format captured from llama-fit-params b10729: one row per device, columns
    // device / model / context / compute in whole MiB. "Host" is the ONLY host
    // token — an unrecognised name is a device, deliberately, because a device
    // row mis-filed as host is an unrecoverable split error. A zero context cell
    // is a READING ("nothing on that device"), not a missing value.
    var fp = s.parseFitParams(
      "llama_fit_params: printing estimated memory in MiB to stdout (device, model, context, compute) ...\n" +
      "CUDA0 3997 5160 1860\n" +
      "Host 7140 0 286\n")
    A.check("tier5/rows-parsed", fp ? fp.rows.length : -1, 2)
    A.check("tier5/device-row-name", fp ? fp.deviceRows[0].device : "", "CUDA0")
    A.check("tier5/host-row-name", fp ? fp.hostRows[0].device : "", "Host")
    A.check("tier5/zero-context-is-a-reading", fp ? fp.hostRows[0].contextMiB : -1, 0)
    A.check("tier5/device-total-context-bytes", fp ? fp.deviceTotal.context : -1,
      5160 * 1048576)
    A.check("tier5/host-total-model-bytes", fp ? fp.hostTotal.model : -1, 7140 * 1048576)
    // A short row or a total row is skipped, never zero-filled: an invented 0
    // would read as "nothing on the device".
    A.ok("tier5/short-row-skipped", s._parseFitRow("CUDA0 1 2") === null)
    A.ok("tier5/total-row-skipped", s._parseFitRow("Total 1 2 3") === null)
    A.ok("tier5/unrecognised-name-is-a-device", s._fitIsHost("ROCM0") === false)
    // Tier-5 values are permanently `~`: the projection is a point estimate with
    // no corroboration path, so it commits ESTIMATED and nothing promotes it.
    var t5store = s.createFieldStore("/m/tier5-probe.gguf")
    s._t5(t5store, "kvGpuBytes", 12345)
    A.check("tier5/committed-estimated", t5store.get("kvGpuBytes").state, "estimated")
    A.check("tier5/committed-tier", t5store.get("kvGpuBytes").tier, 5)
    s._t6(t5store, "kvGpuBytes", 999)
    A.check("tier5/no-promotion-by-weaker-tier", t5store.get("kvGpuBytes").value, 12345)

    A.finish()
  }
}