import QtQuick
import Quickshell
import "asserts.js" as A

// Unit: the pure llama.cpp derivation helpers that turn raw --n-gpu-layers /
// --cache-type-* tokens + GGUF header counts into the #7 display values. They
// must be total (never throw) and degrade to unknown (-1 / "-") on any bad
// input, so a partial or surprising server response can't break rendering.
Item {
  id: root
  Component.onCompleted: {
    var s = A.service("@SERVICE_QML_PATH@", root, "llama.cpp")

    // ── _parseLlamaArgs: exact-token arg scan (separate and inline `=` forms) ─
    var p1 = s._parseLlamaArgs(["/usr/bin/llama-server", "--model", "/m/a.gguf",
      "--n-gpu-layers", "all", "--cache-type-k", "q5_0", "--cache-type-v", "q4_0"])
    A.check("args/model", p1.model, "/m/a.gguf")
    A.check("args/ngl", p1.ngl, "all")
    A.check("args/cacheK", p1.cacheK, "q5_0")
    A.check("args/cacheV", p1.cacheV, "q4_0")
    A.check("args/noKvOffload", p1.noKvOffload, false)

    var p2 = s._parseLlamaArgs(["/usr/bin/llama-server", "-m", "/m/b.gguf",
      "-ngl=99", "--cache-type-k=f16", "--no-kv-offload"])
    A.check("args-inline/model", p2.model, "/m/b.gguf")
    A.check("args-inline/ngl", p2.ngl, "99")
    A.check("args-inline/cacheK", p2.cacheK, "f16")
    A.check("args-inline/cacheV-default", p2.cacheV, "")
    A.check("args-inline/noKvOffload", p2.noKvOffload, true)

    var p3 = s._parseLlamaArgs(null)
    A.check("args-null/model", p3.model, "")
    A.check("args-null/ngl", p3.ngl, "")
    A.check("args-null/noKvOffload", p3.noKvOffload, false)

    // ── _mtpSplit: ngl token + total + mtp → {mainGpu, mainCpu, mtpGpu, mtpCpu}
    A.check("split/all", s._mtpSplit("all", 65, 0), {mainGpu: 65, mainCpu: 0, mtpGpu: 0, mtpCpu: 0})
    A.check("split/int-inrange", s._mtpSplit("20", 65, 0), {mainGpu: 20, mainCpu: 45, mtpGpu: 0, mtpCpu: 0})
    A.check("split/int-overclamp", s._mtpSplit("99", 65, 0), {mainGpu: 65, mainCpu: 0, mtpGpu: 0, mtpCpu: 0})
    A.check("split/zero", s._mtpSplit("0", 65, 0), {mainGpu: 0, mainCpu: 65, mtpGpu: 0, mtpCpu: 0})
    A.check("split/badtotal", s._mtpSplit("all", -1, 0), {mainGpu: null, mainCpu: null, mtpGpu: null, mtpCpu: null})
    A.check("split/empty", s._mtpSplit("", 65, 0), {mainGpu: null, mainCpu: null, mtpGpu: null, mtpCpu: null})
    A.check("split/nonnumeric", s._mtpSplit("x", 65, 0), {mainGpu: null, mainCpu: null, mtpGpu: null, mtpCpu: null})
    A.check("split/null", s._mtpSplit(null, 65, 0), {mainGpu: null, mainCpu: null, mtpGpu: null, mtpCpu: null})
    // MTP layers sit on top of the stack: offload counts from the bottom.
    A.check("split/all-mtp", s._mtpSplit("all", 65, 5), {mainGpu: 60, mainCpu: 0, mtpGpu: 5, mtpCpu: 0})
    A.check("split/part-mtp", s._mtpSplit("30", 65, 5), {mainGpu: 30, mainCpu: 30, mtpGpu: 0, mtpCpu: 5})

    // ── percent helpers: ratio of a part to the total, unknown → -1 ──────────
    A.check("pctGpu/full", s._percentLayersOnGPU(65, 65), 100)
    A.check("pctGpu/part", s._percentLayersOnGPU(20, 65), 31)
    A.check("pctGpu/badtotal", s._percentLayersOnGPU(20, 0), -1)
    A.check("pctGpu/neggpu", s._percentLayersOnGPU(-1, 65), -1)
    A.check("pctCpu/part", s._percentLayersOnCPU(45, 65), 69)
    A.check("pctCpu/badtotal", s._percentLayersOnCPU(45, 0), -1)

    // ── _kvDtypeBits: KV-cache dtype → bits/element (empty = f16 default) ────
    A.check("kvbits/empty", s._kvDtypeBits(""), 16)
    A.check("kvbits/null", s._kvDtypeBits(null), 16)
    A.check("kvbits/f32", s._kvDtypeBits("f32"), 32)
    A.check("kvbits/f16", s._kvDtypeBits("f16"), 16)
    A.check("kvbits/bf16", s._kvDtypeBits("bf16"), 16)
    A.check("kvbits/q8_0", s._kvDtypeBits("q8_0"), 8.5)
    A.check("kvbits/q6_k", s._kvDtypeBits("q6_k"), 6.5625)
    A.check("kvbits/q5_1", s._kvDtypeBits("q5_1"), 5.5)
    A.check("kvbits/q5_0", s._kvDtypeBits("q5_0"), 5.25)
    A.check("kvbits/q4_1", s._kvDtypeBits("q4_1"), 4.5)
    A.check("kvbits/q4_0", s._kvDtypeBits("q4_0"), 4.5)
    A.check("kvbits/unknown", s._kvDtypeBits("q9_zz"), -1)

    // ── _kvEstimateBytes: product estimate; any unknown input → -1 ───────────
    A.check("kvest/ok1", s._kvEstimateBytes(1, 1024, 1, 64, 8, 8), 131072)
    A.check("kvest/ok2", s._kvEstimateBytes(2, 2048, 2, 32, 16, 16), 1048576)
    A.check("kvest/badlayers", s._kvEstimateBytes(0, 1024, 1, 64, 8, 8), -1)
    A.check("kvest/badctx", s._kvEstimateBytes(1, 0, 1, 64, 8, 8), -1)
    A.check("kvest/badheadkv", s._kvEstimateBytes(1, 1024, 0, 64, 8, 8), -1)
    A.check("kvest/badheaddim", s._kvEstimateBytes(1, 1024, 1, 0, 8, 8), -1)
    A.check("kvest/unknown-kbits", s._kvEstimateBytes(1, 1024, 1, 64, -1, 8), -1)
    A.check("kvest/unknown-vbits", s._kvEstimateBytes(1, 1024, 1, 64, 8, -1), -1)

    // ── _estimateSplitFromProbes: VRAM → layer estimate (~; null when unknown) ─
    // VRAM is reduced by the rough KV-cache estimate before the weight ratio.
    A.check("probe/empty-vram", s._estimateSplitFromProbes(100, 65, -1), null)
    A.check("probe/no-size", s._estimateSplitFromProbes(0, 65, 2*1024*1024*1024), null)
    A.check("probe/full-gpu", s._estimateSplitFromProbes(10*1024*1024*1024, 65, 9*1024*1024*1024), {gpuLayers: 57, cpuLayers: 8, ctxOn: "GPU"})
    A.check("probe/full-cpu", s._estimateSplitFromProbes(10*1024*1024*1024, 65, 0), null)
    A.check("probe/half-gpu", s._estimateSplitFromProbes(10*1024*1024*1024, 65, 5*1024*1024*1024), {gpuLayers: 31, cpuLayers: 34, ctxOn: "GPU"})

    // ── _resolveRunningEntries: fresh reference + synchronous cached resolve ──
    s._ggufCache["/m/a.gguf"] = { bc: 65, hc: 24, hckv: 4, embd: 5120 }
    var entries = [{ modelPath: "/m/a.gguf", draftPath: "", ngl: "all", contextLen: 262144,
      sizeBytes: 100, cacheK: "q8_0", cacheV: "q8_0" }]
    var out = s._resolveRunningEntries(entries)
    A.ok("resolve/fresh-ref", out !== entries)
    A.check("resolve/totalLayers", out[0].totalLayers, 65)
    A.check("resolve/mainGpu", out[0].mainGpu, 65)
    A.check("resolve/mainCpu", out[0].mainCpu, 0)
    A.ok("resolve/kvCacheBytes", out[0].kvCacheBytes > 0)

    // ── _weightBytes: exact split / measured fallback / all unknown ───────────
    A.check("wbytes/split-known", s._weightBytes(100, 65, 0, 65, -1, -1), [100, 0])
    A.check("wbytes/measured-fallback", s._weightBytes(100, -1, -1, 65, 42, 7), [42, 7])
    A.check("wbytes/all-unknown", s._weightBytes(100, -1, -1, 65, -1, -1), [-1, -1])

    // ── formatGB: bytes → display string; unknown / negative → "—" ──────────
    A.check("gb/one", s.formatGB(1073741824), "1.0 GB")
    A.check("gb/five", s.formatGB(5368709120), "5.0 GB")
    A.check("gb/tb", s.formatGB(1099511627776), "1.0 TB")
    A.check("gb/zero", s.formatGB(0), "0.0 GB")
    A.check("gb/negative", s.formatGB(-1), "\u2014")
    A.check("gb/nonnumeric", s.formatGB("abc"), "\u2014")

    // ── formatMB: small byte counts → "N MB"; 0/unknown → "—"; ≥1 GiB → GB ──
    A.check("mb/zero", s.formatMB(0), "\u2014")
    A.check("mb/negative", s.formatMB(-1), "\u2014")
    A.check("mb/185", s.formatMB(193986560), "185 MB")
    A.check("mb/gb-overflow", s.formatMB(2147483648), "2.0 GB")

    // ── _finishGguf: marker-text parse → cache + fold into running entry ─────
    // The GGUF binary parse lives in the bash ggufScript (integration-tested);
    // here we test the QML side that turns its `GGUF-OK` + key=value lines into
    // the cached header and the per-entry layer split + KV estimate.
    s._ggufCache = ({})
    s.runningModels = [{ modelPath: "/m/g1.gguf", draftPath: "", ngl: "all", contextLen: 262144, sizeBytes: 0, cacheK: "", cacheV: "" }]
    s._ggufPath = "/m/g1.gguf"
    s._ggufBuffer = "GGUF-OK\narch=qwen35\nblock_count=65\nhead_count=40\nhead_count_kv=8\nembedding_length=5120\n"
    s._finishGguf()
    A.ok("gguf/cached", s._ggufCache["/m/g1.gguf"] !== undefined)
    A.check("gguf/cache-bc", s._ggufCache["/m/g1.gguf"].bc, 65)
    A.check("gguf/totalLayers", s.runningModels[0].totalLayers, 65)
    A.check("gguf/mainGpu", s.runningModels[0].mainGpu, 65)
    A.check("gguf/mainCpu", s.runningModels[0].mainCpu, 0)
    A.check("gguf/split-source-api", s.runningModels[0]._gpuSplitSource, "api")
    A.ok("gguf/kvCacheBytes-est", s.runningModels[0].kvCacheBytes > 0)
    A.check("gguf/kvCacheBytes-formula", s.runningModels[0].kvCacheBytes, s._kvEstimateBytes(65, 262144, 8, 5120 / 40, 16, 16))
    // No MTP/interval keys → non-hybrid fallback: main = total, no MTP split.
    A.check("gguf/mainLayers-fallback", s.runningModels[0].mainLayers, 65)
    A.check("gguf/mtpLayers-fallback", s.runningModels[0].mtpLayers, 0)

    // ctx unknown (contextLen -1) → KV estimate degrades to -1 ("—")
    s.runningModels = [{ modelPath: "/m/g2.gguf", draftPath: "", ngl: "all", contextLen: -1, sizeBytes: 0, cacheK: "", cacheV: "" }]
    s._ggufPath = "/m/g2.gguf"
    s._ggufBuffer = "GGUF-OK\narch=qwen35\nblock_count=65\nhead_count=40\nhead_count_kv=8\nembedding_length=5120\n"
    s._finishGguf()
    A.check("gguf/kvCacheBytes-noctx", s.runningModels[0].kvCacheBytes, -1)

    // GGUF-NO marker → nothing cached, entry keeps its -1 ("—") initial state
    s.runningModels = [{ modelPath: "/m/g3.gguf", draftPath: "", ngl: "all", contextLen: 262144, sizeBytes: 0, cacheK: "", cacheV: "", totalLayers: -1 }]
    s._ggufPath = "/m/g3.gguf"
    s._ggufBuffer = "GGUF-NO\n"
    s._finishGguf()
    A.ok("gguf/no-marker-still-uncached", s._ggufCache["/m/g3.gguf"] === undefined)
    A.check("gguf/no-marker-layers", s.runningModels[0].totalLayers, -1)

    // Hybrid attention + MTP header: block_count splits into main + MTP, the
    // KV estimate counts only full-attention layers (main / interval), and the
    // MTP share is derived from the model size.
    s._ggufCache = ({})
    s.runningModels = [{ modelPath: "/m/g4.gguf", draftPath: "", ngl: "all", contextLen: 96256,
      sizeBytes: 12040883104, cacheK: "q5_0", cacheV: "q4_0" }]
    s._ggufPath = "/m/g4.gguf"
    s._ggufBuffer = "GGUF-OK\narch=qwen35\nblock_count=65\nnextn_predict_layers=1\nfull_attention_interval=4\nhead_count=24\nhead_count_kv=4\nembedding_length=5120\n"
    s._finishGguf()
    A.check("hybrid/totalLayers", s.runningModels[0].totalLayers, 65)
    A.check("hybrid/mainLayers", s.runningModels[0].mainLayers, 64)
    A.check("hybrid/mtpLayers", s.runningModels[0].mtpLayers, 1)
    A.ok("hybrid/mtpSizeBytes", s.runningModels[0].mtpSizeBytes > 0)
    A.check("hybrid/kvCacheBytes", s.runningModels[0].kvCacheBytes, s._kvEstimateBytes(16, 96256, 4, 5120 / 24, 5.25, 4.5))

    // ── Integration: ngl unknown (fit = on) → probe fallback in _applyGguf ───
    s._ggufCache = ({})
    s.runningModels = [{ modelPath: "/m/fit-model.gguf", draftPath: "", ngl: "", contextLen: 131072,
      sizeBytes: 9200000000, cacheK: "q8_0", cacheV: "q8_0" }]
    s._ggufPath = "/m/fit-model.gguf"
    s.serviceVramBytes = 7500000000  // ~7 GB VRAM measured
    s._ggufBuffer = "GGUF-OK\narch=qwen35\nblock_count=80\nhead_count=24\nhead_count_kv=8\nembedding_length=5120\n"
    s._finishGguf()
    A.ok("fit-model/split-from-probe", s.runningModels[0].mainGpu > 0)
    A.ok("fit-model/source-marked", s.runningModels[0]._gpuSplitSource === "probe")

    A.finish()
  }
}
