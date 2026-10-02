import QtQuick
import Quickshell
import "asserts.js" as A

// E2E: the dedicated Draft row + per-device totals for MTP/draft models,
// rendered by the REAL ModelsSection.llamaDetailBlock against the real Service.
// Four arcs:
//   1. Built-in MTP - drives the real _finishGguf path (nextn_predict_layers=1
//      in the header): Model Size must show the CORE layer count (64, not 65)
//      and a "Draft: mtp | 1 layer | ... | on GPU" row.
//   2. Separate draft (--model-draft) - base header (no npl) + draft header
//      (block_count=1): Model Size shows the base core size, Draft row carries
//      the draft file size.
//   3. Split totals (the bug fix) - a real model with -ngl 30, so the GPU holds
//      30 layers while the CPU holds 34 plus the draft layer: CPU Total must show
//      those bytes, not an em-dash. Two loaded models share one cgroup, so no
//      reading belongs to either entry and the cache is attributed to NO device.
//   4. The placement ladder on the same model: --no-kv-offload pins the cache to
//      host RAM (tier-1 flag, fresh store), then a single loaded model makes the
//      cgroup readings attributable — below the cache they prove a SPLIT, at
//      exactly zero they prove the device.
//
// Every arc goes through the real resolver (`_finishJsonModels` → stores → tiers)
// and reads its EXPECTATIONS back out of the store, so the numbers cannot drift
// away from the fixture: the block must render what the resolver committed, not
// what a test decided to expect.
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

  // Fold a header for `path` through the real parser. sliding_window=0 is a real
  // declaration (a dense cache) and is what lets the header derivation describe
  // the KV shape: without it the cache is undescribable, tier 4 stays silent, and
  // every placement question in arcs 3-4 has nothing to answer.
  function foldHeader(path, total, kvHeads, npl) {
    s._ggufPath = path
    s._ggufBuffer = "GGUF-OK\narch=qwen35\nblock_count=" + total + "\nhead_count=24\nhead_count_kv="
      + kvHeads + "\nembedding_length=5120\nsliding_window=0\n"
      + ((npl > 0) ? ("nextn_predict_layers=" + npl + "\n") : "")
    s._finishGguf()
  }

  Component.onCompleted: {
    s = A.service("@SERVICE_QML_PATH@", root, "llama.cpp")
    if (!s) return
    A.ok("mtp-e2e/service-created", s !== null)

    var BASE_SIZE = 14600000000
    var DRAFT_SIZE = 300000000

    var fixture = { data: [
      { id: "mtp-model",
        status: { value: "loaded", processor: "GPU",
                  args: ["/usr/bin/llama-server", "--model", "/m/mtp-model.gguf", "-ngl", "all"] },
        meta: { size: String(BASE_SIZE), n_ctx: "131072" } },
      { id: "draft-model",
        status: { value: "loaded", processor: "GPU",
                  args: ["/usr/bin/llama-server", "--model", "/m/draft-base.gguf",
                         "--model-draft", "/m/draft-model.gguf", "-ngl", "all", "-ngld", "all"] },
        meta: { size: String(BASE_SIZE), n_ctx: "131072" } },
      { id: "split-model",
        status: { value: "loaded", processor: "GPU",
                  args: ["/usr/bin/llama-server", "--model", "/m/split-model.gguf", "-ngl", "30"] },
        meta: { size: String(BASE_SIZE), n_ctx: "131072" } }
    ] }
    s._jsonBuffer = JSON.stringify(fixture)
    s._finishJsonModels()
    A.ok("mtp-e2e/running-populated", s.runningModels.length === 3)

    // 1. Built-in MTP: the real header fold splits block_count=65 into
    //    main=64 + mtp=1 (ngl="all" -> everything on GPU).
    var b = s.runningModels[0]
    A.check("mtp-e2e/builtin-ngl", b.ngl, "all")
    s._ggufCache = ({})
    foldHeader("/m/mtp-model.gguf", 65, 4, 1)
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
    foldHeader("/m/draft-base.gguf", 65, 4, 0)
    s._ggufPath = "/m/draft-model.gguf"
    s._ggufBuffer = "GGUF-OK\narch=qwen35\nblock_count=1\nsize=" + DRAFT_SIZE + "\n"
    s._finishGguf()
    var e2 = s.runningModels[1]
    A.check("mtp-e2e/draft-mainLayers", e2.mainLayers, 65)
    A.check("mtp-e2e/draft-mtpLayers", e2.mtpLayers, 1)
    A.check("mtp-e2e/draft-mtpSize", e2.mtpSizeBytes, DRAFT_SIZE)
    A.check("mtp-e2e/draft-mtpGpu", e2.mtpGpu, 1)

    // 3. Split totals (the bug fix): -ngl 30 over a 65-layer stack with one built-in
    //    MTP layer puts 30 layers on the device and 34 on the host, with the draft
    //    layer on the host too (it rides -ngl, and 30 stops below the MTP block).
    foldHeader("/m/split-model.gguf", 65, 4, 1)
    var e3 = s.runningModels[2]
    A.check("mtp-e2e/split-model-path", e3.modelPath, "/m/split-model.gguf")
    var st3 = s._stores["/m/split-model.gguf"]
    A.check("mtp-e2e/split-mainGpu", st3.read("mainGpu").value, 30)
    A.check("mtp-e2e/split-mainCpu", st3.read("mainCpu").value, 34)
    A.check("mtp-e2e/split-mtpGpu", st3.read("mtpGpu").value, 0)
    A.check("mtp-e2e/split-mtpCpu", st3.read("mtpCpu").value, 1)
    // The draft badge is now decided for a built-in MTP stack: `-ngld` is absent
    // (there is no separate draft model to configure) and the draft follows -ngl.
    var wG = st3.read("weightGpu").value
    var wC = st3.read("weightCpu").value
    var mtpB = st3.read("mtpSizeBytes").value
    var kvB = st3.read("kvBytes").value
    A.ok("mtp-e2e/split-kv-bytes", kvB > 0)
    // Combined per-device weights: the draft's one layer is on the host here.
    var gpuW = wG
    var cpuW = wC + mtpB

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
    A.ok("mtp-e2e/builtin-cpu-layers", lineOf(d1, "CPU Layers:").indexOf("CPU Layers: ") === 0
      && lineOf(d1, "CPU Layers:").indexOf("|") !== 12)

    // 2. Separate draft detail block: base core size + Draft row file size.
    var d2 = sec.llamaDetailBlock(e2)
    A.ok("mtp-e2e/draft-size-base", lineOf(d2, "Model Size:").indexOf("Model Size: 65 layers | " + s.formatGB(BASE_SIZE)) === 0)
    var draftLine2 = lineOf(d2, "Draft:")
    A.ok("mtp-e2e/draft-file-size", draftLine2.indexOf("Draft: mtp | 1 layer | " + s.formatGB(DRAFT_SIZE)) === 0)
    A.ok("mtp-e2e/draft-on-gpu", draftLine2.indexOf("on GPU") !== -1)

    // 3. The split entry's own block. Three models are loaded, so the cgroup
    //    readings belong to no single entry: the cache is attributed to NO device
    //    until something can prove otherwise, and the totals are the weight
    //    totals — the CPU's included, which is the bug this arc exists for.
    var d3 = sec.llamaDetailBlock(e3)
    A.ok("mtp-e2e/split-cpu-total-not-empty", lineOf(d3, "CPU Total:").indexOf("CPU Total: ") === 0
      && lineOf(d3, "CPU Total:").indexOf(s.formatGB(cpuW)) !== -1)
    A.check("mtp-e2e/split-cpu-total", lineOf(d3, "CPU Total:"), "CPU Total: ~" + s.formatGB(cpuW))
    A.check("mtp-e2e/split-gpu-total", lineOf(d3, "GPU Total:"), "GPU Total: ~" + s.formatGB(gpuW))
    // ...and the lines say so instead of guessing a device.
    A.check("mtp-e2e/split-context-unplaced", lineOf(d3, "Context:"), "Context: 131,072 tok")
    A.ok("mtp-e2e/split-kv-unplaced", lineOf(d3, "KV Cache:").indexOf(" on ") === -1)
    A.ok("mtp-e2e/split-draft-on-cpu", lineOf(d3, "Draft:").indexOf("on CPU") !== -1)

    // 4a. --no-kv-offload pins the cache to host RAM, so the CPU total must grow by
    //     exactly the cache and the GPU total must not. This is the colocation case
    //     the original bug was about, now reached through a fact instead of an
    //     assumption. It rides a SEPARATE model path because tier 1 does not revise
    //     itself: a flag can only change by a reload, and a reload starts a fresh
    //     store — patching the entry's field after the poll would assert nothing.
    s._jsonBuffer = JSON.stringify({ data: [
      { id: "split-model",
        status: { value: "loaded", processor: "GPU",
                  args: ["/usr/bin/llama-server", "--model", "/m/split-model.gguf", "-ngl", "30"] },
        meta: { size: String(BASE_SIZE), n_ctx: "131072" } },
      { id: "cpu-model",
        status: { value: "loaded", processor: "CPU",
                  args: ["/usr/bin/llama-server", "--model", "/m/cpu-model.gguf", "-ngl", "30",
                         "--no-kv-offload"] },
        meta: { size: String(BASE_SIZE), n_ctx: "131072" } }
    ] })
    s._finishJsonModels()
    foldHeader("/m/cpu-model.gguf", 65, 4, 1)
    var cpuEntry = s.runningModels[1]
    A.check("mtp-e2e/cpu-model-path", cpuEntry ? cpuEntry.modelPath : "", "/m/cpu-model.gguf")
    var stc = s._stores["/m/cpu-model.gguf"]
    A.ok("mtp-e2e/flag-store", stc.get("noKvOffload").value === true)
    var kvc = stc.read("kvBytes").value
    var wc = stc.read("weightCpu").value + stc.read("mtpSizeBytes").value
    var wgc = stc.read("weightGpu").value
    var d4a = sec.llamaDetailBlock(cpuEntry)
    A.ok("mtp-e2e/split-kv-on-cpu", lineOf(d4a, "KV Cache:").indexOf(" on CPU") !== -1)
    A.check("mtp-e2e/split-cpu-total-with-kv", lineOf(d4a, "CPU Total:"),
      "CPU Total: ~" + s.formatGB(wc + kvc))
    A.check("mtp-e2e/split-gpu-total-without-kv", lineOf(d4a, "GPU Total:"),
      "GPU Total: ~" + s.formatGB(wgc))

    // 4b. One loaded model, so the readings are attributable again, and a cgroup
    //     reading BELOW the cache: host anon (100 MB) is smaller than the cache, so
    //     the cache is provably NOT all in host, and the device is holding memory,
    //     so it is provably not all on the device either. That is a SPLIT — proven,
    //     ratio unknown — and the honest label is GPU/CPU, not GPU. Neither total
    //     may claim the cache: the device share is exactly what was not measured.
    s._jsonBuffer = JSON.stringify({ data: [
      { id: "split-model",
        status: { value: "loaded", processor: "GPU",
                  args: ["/usr/bin/llama-server", "--model", "/m/split-model.gguf", "-ngl", "30"] },
        meta: { size: String(BASE_SIZE), n_ctx: "131072" } }
    ] })
    s._finishJsonModels()
    e3 = s.runningModels[0]
    A.check("mtp-e2e/sole-measured", st3.get("soleAttribution").value, "measured")
    s.serviceMemoryBytes = 100000000
    s.serviceVramBytes = 8 * 1024 * 1024 * 1024
    s.runningModels = s._resolveRunningEntries([e3])
    e3 = s.runningModels[0]
    var d4b = sec.llamaDetailBlock(e3)
    A.check("mtp-e2e/split-kv-on-gpu-cpu", lineOf(d4b, "KV Cache:").indexOf(" on GPU/CPU") !== -1, true)
    A.check("mtp-e2e/split-context-split", lineOf(d4b, "Context:").indexOf("on GPU/CPU") !== -1, true)
    // Identical to the un-placed totals in arc 3: a proven split moves no bytes.
    A.check("mtp-e2e/split-gpu-total-without-split-kv", lineOf(d4b, "GPU Total:"),
      "GPU Total: ~" + s.formatGB(gpuW))
    A.check("mtp-e2e/split-cpu-total-still-weights", lineOf(d4b, "CPU Total:"),
      "CPU Total: ~" + s.formatGB(cpuW))

    // 4c. Rung 1a, which nothing else in the suite exercises: host anon exactly 0 and
    //     the device holding at least a cache's worth. Nothing in host can be the
    //     cache, so it is on the device — the one exact GPU answer — and the GPU
    //     total grows by the cache while the CPU total does not. The device
    //     reading has to clear the cache: "the device holds memory" is not the
    //     claim, "the device holds at least as much as the cache" is.
    s.serviceMemoryBytes = 0
    s.serviceVramBytes = 32 * 1024 * 1024 * 1024
    s.runningModels = s._resolveRunningEntries([e3])
    e3 = s.runningModels[0]
    var d4c = sec.llamaDetailBlock(e3)
    A.check("mtp-e2e/rung1-kv-on-gpu", lineOf(d4c, "Context:"), "Context: 131,072 tok on GPU")
    // Proven, and still "~": the placement is derived from the tier-4 readings, and
    // a derived value is never better than its worst input. The PLAN matrix's
    // "exact or estimated" for this field is carried by the flag rungs, whose only
    // input is a tier-1 flag.
    A.check("mtp-e2e/rung1-kv-value", st3.read("kvLocation").value, "GPU")
    A.check("mtp-e2e/rung1-kv-marker", st3.read("kvLocation").state, "estimated")
    A.check("mtp-e2e/rung1-gpu-total-with-kv", lineOf(d4c, "GPU Total:"),
      "GPU Total: ~" + s.formatGB(gpuW + kvB))
    A.check("mtp-e2e/rung1-cpu-total-still-weights", lineOf(d4c, "CPU Total:"),
      "CPU Total: ~" + s.formatGB(cpuW))

    s.serviceMemoryBytes = -1
    s.serviceVramBytes = -1
    s.runningModels = s._resolveRunningEntries([e3])

    A.finish()
  }
}