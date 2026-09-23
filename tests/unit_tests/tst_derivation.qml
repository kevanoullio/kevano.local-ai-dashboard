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

    // ── _resolveFieldSources / _resolveWeights (change 4): the resolver owns the
    // per-field Tier ladder exactly once. Golden rules pinned: Tier 5 beats
    // Tier 3, Tier 1 beats Tier 5, and the render marker is "~" exactly when any
    // contributing input carried "~". Entries are the post-_applyGguf shapes
    // (mainGpu set + _gpuSplitSource) OR the raw meta shape; p = { vramBytes,
    // memBytes, presetSection }.
    //
    // Tier 1 beats Tier 5: an explicit API split wins even with a preset section.
    var rr = s._resolveFieldSources({
      modelPath: "/m/a.gguf", ngl: "all", mainGpu: 65, mainCpu: 0,
      _gpuSplitSource: "api", totalLayers: 65, sizeBytes: 100 },
      { vramBytes: 42, memBytes: 7, presetSection: { "n-gpu-layers": "10" } })
    A.check("rs/t1-split-tier", rr.gpuSplit.tier, 1)
    A.check("rs/t1-split-marker", rr.gpuSplit.marker, "")
    A.check("rs/t1-split-gpu", rr.gpuSplit.value.mainGpu, 65)
    A.check("rs/t1-weights-gpu", rr.weightBytes.gpu, 100)   // 100 × 65/65
    A.check("rs/t1-weights-cpu", rr.weightBytes.cpu, 0)
    A.check("rs/t1-weights-marker", rr.weightBytes.gpuMarker, "")

    // Tier 5 beats Tier 3: the preset section answers even though VRAM is
    // available for a live estimate (the split resolves later in _applyGguf).
    rr = s._resolveFieldSources({
      modelPath: "/m/fit.gguf", ngl: "", mainGpu: null, mainCpu: null,
      totalLayers: 65, sizeBytes: 100 },
      { vramBytes: 42, memBytes: 7, presetSection: { "n-gpu-layers": "all" } })
    A.check("rs/t5-split-tier", rr.gpuSplit.tier, 5)
    A.check("rs/t5-split-marker", rr.gpuSplit.marker, "")
    A.ok("rs/t5-split-unresolved-value", rr.gpuSplit.value === null)

    // `auto`/empty preset tokens do NOT answer Tier 5 (isPresetSplitToken
    // rejects them) → the resolver falls to the live Tier-3 probe.
    rr = s._resolveFieldSources({ totalLayers: 65, sizeBytes: 10*1024*1024*1024 },
      { vramBytes: 5*1024*1024*1024, presetSection: { "n-gpu-layers": "auto" } })
    A.check("rs/t5-auto-ignored-tier", rr.gpuSplit.tier, 3)
    A.check("rs/t5-auto-marker", rr.gpuSplit.marker, "~")
    A.check("rs/t5-auto-value-gpu", rr.gpuSplit.value.mainGpu,
      s._estimateSplitFromProbes(10*1024*1024*1024, 65, 5*1024*1024*1024).gpuLayers)

    // Tier 3 live estimate: no API, no preset, VRAM available → the same
    // numbers _estimateSplitFromProbes yields, marked as an estimate.
    rr = s._resolveFieldSources({ totalLayers: 65, sizeBytes: 10*1024*1024*1024 },
      { vramBytes: 5*1024*1024*1024, memBytes: -1 })
    A.check("rs/t3-split-tier", rr.gpuSplit.tier, 3)
    A.check("rs/t3-split-marker", rr.gpuSplit.marker, "~")
    A.check("rs/t3-split-gpu", rr.gpuSplit.value.mainGpu,
      s._estimateSplitFromProbes(10*1024*1024*1024, 65, 5*1024*1024*1024).gpuLayers)
    A.check("rs/t3-split-ctxOn", rr.gpuSplit.value.ctxOn, "GPU")

    // A STORED probe split is Tier 3 too the marker stays "~" through the
    // weight bytes (any `~` input keeps the line estimated).
    rr = s._resolveFieldSources({ ngl: "30", mainGpu: 30, mainCpu: 35,
      _gpuSplitSource: "probe", totalLayers: 65, sizeBytes: 100 },
      { vramBytes: -1, memBytes: -1 })
    A.check("rs/probe-tier", rr.gpuSplit.tier, 3)
    A.check("rs/probe-marker", rr.gpuSplit.marker, "~")
    A.check("rs/probe-weights-gpu", rr.weightBytes.gpu, Math.round(100 * 30 / 65))
    A.check("rs/probe-weights-cpu", rr.weightBytes.cpu, Math.round(100 * 35 / 65))
    A.check("rs/probe-weights-marker", rr.weightBytes.gpuMarker, "~")

    // No split answers (preset none, VRAM present but no model size to derive
    // a split from) → split "—", weights still fall back to the measured
    // per-device footprint as estimates.
    rr = s._resolveFieldSources({ totalLayers: 65 },
      { vramBytes: 42, memBytes: 7, presetSection: null })
    A.ok("rs/nowhere-split-tier-null", rr.gpuSplit.tier === null)
    A.check("rs/nowhere-split-marker", rr.gpuSplit.marker, "\u2014")
    A.check("rs/nowhere-weights-gpu", rr.weightBytes.gpu, 42)
    A.check("rs/nowhere-weights-cpu", rr.weightBytes.cpu, 7)
    A.check("rs/nowhere-weights-marker", rr.weightBytes.gpuMarker, "~")

    // Quant row + KV row: field precedence and markers.
    rr = s._resolveFieldSources({ nParams: 1000, ftype: 15, cacheK: "q8_0",
      cacheV: "q5_0", kvCacheBytes: 2048, totalLayers: 65, sizeBytes: 100 })
    A.check("rs/params-tier", rr.params.tier, 1)
    A.check("rs/params-value", rr.params.value, 1000)
    A.check("rs/params-marker", rr.params.marker, "")
    A.check("rs/quant-tier", rr.quant.tier, 2)
    A.check("rs/quant-value", rr.quant.value, 15)
    A.check("rs/layers-tier", rr.totalLayers.tier, 2)
    A.check("rs/layers-value", rr.totalLayers.value, 65)
    A.check("rs/kv-tier", rr.kvBytes.tier, 4)
    A.check("rs/kv-marker", rr.kvBytes.marker, "~")
    A.check("rs/kv-value", rr.kvBytes.value, 2048)
    A.check("rs/kvDtype-k", rr.kvDtype.value.k, "q8_0")
    A.check("rs/kvDtype-marker", rr.kvDtype.marker, "")

    // Totally empty entry → every field degrades to "—" (-1); nothing throws.
    rr = s._resolveFieldSources({}, {})
    A.ok("rs/empty-split-tier-null", rr.gpuSplit.tier === null)
    A.check("rs/empty-params", rr.params.value, -1)
    A.check("rs/empty-weights", rr.weightBytes.gpu, -1)

    // _presetSectionFor: [*] globals merged, section wins on explicit keys,
    // globals-chain for keys the section omits; null when the preset is absent
    // or nothing answers.
    s._presetCache = s._parseIniLines("[*]\nfit = on\nn-gpu-layers = all\n[/m/fit.gguf]\nmodel = /m/fit.gguf\nctx-size = 131072\nn-gpu-layers = 30\n")
    var psf = s._presetSectionFor({ modelPath: "/m/fit.gguf" })
    A.check("psf/globals-merged", psf["fit"], "on")
    A.check("psf/section-wins", psf["n-gpu-layers"], "30")
    A.check("psf/section-ctx", psf["ctx-size"], "131072")
    s._presetCache = s._parseIniLines("[*]\nfit = on\nn-gpu-layers = all\n[/m/other.gguf]\nmodel = /m/other.gguf\n")
    psf = s._presetSectionFor({ modelPath: "/m/other.gguf" })
    A.ok("psf/globals-chain", psf !== null && psf["n-gpu-layers"] === "all")
    A.check("psf/globals-chain-fit", psf["fit"], "on")
    s._presetCache = null
    A.ok("psf/none-null", s._presetSectionFor({ modelPath: "/m/fit.gguf" }) === null)
    A.ok("psf/nokey-null", s._presetSectionFor({}) === null)

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

    // ── _ftypeLabel: llama.h enum (build 10729) → compact quant label ───────
    var ftypePairs = [
      [0, "f32"], [1, "f16"], [2, "q4_0"], [3, "q4_1"],
      [7, "q8_0"], [8, "q5_0"], [9, "q5_1"],
      [10, "q2_k"], [11, "q3_k_s"], [12, "q3_k_m"], [13, "q3_k_l"],
      [14, "q4_k_s"], [15, "q4_k_m"], [16, "q5_k_s"], [17, "q5_k_m"],
      [18, "q6_k"],
      [19, "iq2_xxs"], [20, "iq2_xs"], [21, "q2_k_s"], [22, "iq3_xs"],
      [23, "iq3_xxs"], [24, "iq1_s"], [25, "iq4_nl"], [26, "iq3_s"],
      [27, "iq3_m"], [28, "iq2_s"], [29, "iq2_m"], [30, "iq4_xs"], [31, "iq1_m"],
      [32, "bf16"], [36, "tq1_0"], [37, "tq2_0"], [38, "mxfp4_moe"], [39, "nvfp4"]
    ]
    for (var fi = 0; fi < ftypePairs.length; fi++) {
      A.check("ftype/" + ftypePairs[fi][0],
        s._ftypeLabel(ftypePairs[fi][0]), ftypePairs[fi][1])
    }
    // String input coerce + unknown / removed / reserved enums -> -1 ("—")
    A.check("ftype/string", s._ftypeLabel("15"), "q4_k_m")
    A.check("ftype/unknown-reserved", s._ftypeLabel(4), -1)
    A.check("ftype/unknown-removed", s._ftypeLabel(6), -1)
    A.check("ftype/unknown-gap", s._ftypeLabel(33), -1)
    A.check("ftype/unknown-high", s._ftypeLabel(40), -1)
    A.check("ftype/negative", s._ftypeLabel(-1), -1)
    A.check("ftype/nan", s._ftypeLabel(NaN), -1)
    A.check("ftype/nonnum", s._ftypeLabel("abc"), -1)
    A.check("ftype/null", s._ftypeLabel(null), -1)

    // ── _formatCount: bare integer count → compact params string ────────────
    A.check("fmtcount/billions", s._formatCount(30500000000), "30.5B")
    A.check("fmtcount/1e9", s._formatCount(1000000000), "1.0B")
    A.check("fmtcount/millions", s._formatCount(1519629), "1.5M")
    A.check("fmtcount/1e6", s._formatCount(1000000), "1.0M")
    A.check("fmtcount/tiny", s._formatCount(500000), "500000")
    A.check("fmtcount/zero", s._formatCount(0), "0")
    A.check("fmtcount/string", s._formatCount("27600000000"), "27.6B")
    A.check("fmtcount/negative", s._formatCount(-1), -1)
    A.check("fmtcount/nan", s._formatCount(NaN), -1)
    A.check("fmtcount/nonnum", s._formatCount("abc"), -1)

    // ── Integration: /v1/models n_params (Tier 1) + GGUF header file_type ──
    // The real llama.cpp meta block serves n_params but NOT ftype (upstream:
    // only vocab_type, n_vocab, n_ctx_train, n_embd, n_params, size). The quant
    // arrives separately via the GGUF header's general.file_type (Tier 2).
    s._jsonBuffer = JSON.stringify({
      data: [
        { id: "qwen3-30b",
          meta: { size: "3298534883328", n_ctx: "262144", n_params: "30500000000" },
          status: { value: "loaded", processor: "CPU", args: [] } },
        { id: "mystery",
          meta: { size: "1073741824", n_ctx: "131072" },
          status: { value: "loaded", processor: "CPU", args: [] } }
      ]
    })
    s._finishJsonModels()
    A.ok("meta/running-count", s.runningModels.length === 2)
    var t1 = s.runningModels[0]
    A.check("meta/nParams", t1.nParams, 30500000000)
    A.check("meta/contextLen", t1.contextLen, 262144)
    A.check("meta/sizeBytes", t1.sizeBytes, 3298534883328)
    A.check("meta/ftype-api-absent", t1.ftype, -1)
    var t2 = s.runningModels[1]
    A.check("meta/missing-ftype", t2.ftype, -1)
    A.check("meta/missing-nParams", t2.nParams, -1)
    A.ok("meta/available-list-populated", s.models.length === 2)

    // ── Integration: GGUF general.file_type → entry ftype (Tier 2) ──────────
    s._ggufCache = ({})
    s.runningModels = [{ modelPath: "/m/qwen3-30b.gguf", draftPath: "", ngl: "all",
      contextLen: 262144, sizeBytes: 3298534883328, ftype: -1, nParams: 30500000000,
      cacheK: "f16", cacheV: "f16" }]
    s._ggufPath = "/m/qwen3-30b.gguf"
    s._ggufBuffer = "GGUF-OK\narch=qwen35\nblock_count=65\nhead_count=24\nhead_count_kv=4\nembedding_length=5120\nfile_type=15\n"
    s._finishGguf()
    A.check("gguf/header-file-type-parsed", s._ggufCache["/m/qwen3-30b.gguf"].ft, 15)
    A.check("gguf/entry-ftype-from-header", s.runningModels[0].ftype, 15)

    // ── Tier 5: models.ini preset reader ────────────────────────────────
    // _iniSectionKey mirrors the script's charset exactly: model FILE paths
    // (the section keys) survive normalization and the reserved [*] globals
    // marker keeps its `*` (a stripped `*` would orphan the globals block).
    A.check("inisection/path", s._iniSectionKey("/m/qwen.gguf"), "/m/qwen.gguf")
    A.check("inisection/globals", s._iniSectionKey("*"), "*")
    A.check("inisection/outer-brackets", s._iniSectionKey("[ /m/b.gguf ]"), "/m/b.gguf")
    A.check("inisection/hyphen-dot-star", s._iniSectionKey("my.model-v2.gguf"), "my.model-v2.gguf")
    A.check("inisection/empty", s._iniSectionKey(""), "")

    // _parseIniLines: comments stripped, section switching, [*] globals kept
    // under key "*", quote stripping, and guarded $HOME expansion.
    var iniSrc = [
      "; comment",
      "  # another comment",
      "",
      "[*]",
      "fit = on",
      "cache-type-k = q8_0",
      "n-gpu-layers = all",
      "",
      "[ /m/fit-model.gguf ]",
      "model = \"$HOME/m/fit-model.gguf\"",
      "ctx-size = 262144",
      "",
      "[/m/second.gguf]",
      "model = /m/second.gguf",
      "n-gpu-layers = 30"
    ].join("\n")
    var ini = s._parseIniLines(iniSrc)
    A.ok("ini/globals-block", ini["*"] !== undefined)
    A.check("ini/globals-fit", ini["*"].fit, "on")
    A.check("ini/globals-cachek", ini["*"]["cache-type-k"], "q8_0")
    A.ok("ini/comment-stripped", ini["comment"] === undefined || JSON.stringify(ini).indexOf("comment") === -1)
    var fitSec = ini["/m/fit-model.gguf"]
    A.ok("ini/section-normalized", fitSec !== undefined)
    A.check("ini/section-ctx", fitSec["ctx-size"], "262144")
    A.ok("ini/home-expanded", String(fitSec.model).indexOf("/m/fit-model.gguf") !== -1)
    A.ok("ini/quotes-stripped", String(fitSec.model).charAt(0) !== "\"")
    A.check("ini/section-ngl", ini["/m/second.gguf"]["n-gpu-layers"], "30")
    // Garbage lines: no `=`, comments only → nothing.
    A.check("ini/empty-input", s._parseIniLines(""), {})
    A.check("ini/comments-only", s._parseIniLines("; a\n# b\n"), {})

    // _presetModels (Consumer A): sections with a `model =` key become entries,
    // named after the basename, with the section's n-gpu-layers as intent and
    // the [*] globals as fallback; the globals block itself is never an entry.
    s._presetCache = s._parseIniLines(iniSrc)
    var pm = s._presetModels()
    A.ok("preset-models/list", pm.length === 2)
    A.check("preset-models/name", pm[1].name, "second.gguf")
    A.check("preset-models/intent-section", pm[1].presetIntent, "preset intent: 30 GPU layers")
    A.check("preset-models/intent-global", pm[0].presetIntent, "preset intent: all GPU layers")
    A.check("preset-models/preset-flag", pm[0].preset, true)
    A.check("preset-models/path", pm[0].presetPath, String(s._parseIniLines(iniSrc)["/m/fit-model.gguf"]["model"]))

    // Consumer B via _finishGguf: `fit = on` model with NO n-gpu-layers anywhere
    // → nothing resolves → still falls to the Tier-3 probe (the pre-change
    // behavior, pinned so the ladder order stays intact).
    s._presetCache = null
    s._ggufCache = ({})
    s.runningModels = [{ modelPath: "/m/fit-only.gguf", draftPath: "", ngl: "", contextLen: 131072,
      sizeBytes: 9200000000, cacheK: "q8_0", cacheV: "q8_0" }]
    s._ggufPath = "/m/fit-only.gguf"
    s.serviceVramBytes = 7500000000
    s._ggufBuffer = "GGUF-OK\narch=qwen35\nblock_count=80\nhead_count=24\nhead_count_kv=8\nembedding_length=5120\n"
    s._finishGguf()
    A.ok("t5/absent-keeps-probe", s.runningModels[0].mainGpu > 0)
    A.check("t5/absent-source-probe", s.runningModels[0]._gpuSplitSource, "probe")

    // Consumer B from a [*] global: API left ngl unset (fit = on resolved a
    // global n-gpu-layers that never surfaces in status.args) → exact preset
    // split, source "preset", intent resolved for display.
    s._presetCache = s._parseIniLines("[*]\nn-gpu-layers = all\n[/m/fit-model.gguf]\nmodel = /m/fit-model.gguf\n")
    s.configPresetPath = "/m/models.ini"
    s._ggufCache = ({})
    s.runningModels = [{ modelPath: "/m/fit-model.gguf", draftPath: "", ngl: "", contextLen: 131072,
      sizeBytes: 0, cacheK: "", cacheV: "" }]
    s._ggufPath = "/m/fit-model.gguf"
    s.serviceVramBytes = 7500000000  // Tier 3 must NOT win when Tier 5 answers
    s._ggufBuffer = "GGUF-OK\narch=qwen35\nblock_count=80\nhead_count=24\nhead_count_kv=8\nembedding_length=5120\n"
    s._finishGguf()
    A.check("t5/mainGpu", s.runningModels[0].mainGpu, 80)
    A.check("t5/mainCpu", s.runningModels[0].mainCpu, 0)
    A.check("t5/source", s.runningModels[0]._gpuSplitSource, "preset")
    A.check("t5/ngl-resolved", s.runningModels[0].ngl, "all")
    // Tier 1 beats Tier 5: an explicit --n-gpu-layers from the API wins.
    s._presetCache = s._parseIniLines("[*]\nn-gpu-layers = all\n[/m/explicit.gguf]\nmodel = /m/explicit.gguf\n")
    s._ggufCache = ({})
    s.runningModels = [{ modelPath: "/m/explicit.gguf", draftPath: "", ngl: "45", contextLen: 131072,
      sizeBytes: 0, cacheK: "", cacheV: "" }]
    s._ggufPath = "/m/explicit.gguf"
    s._ggufBuffer = "GGUF-OK\narch=qwen35\nblock_count=80\nhead_count=24\nhead_count_kv=8\nembedding_length=5120\n"
    s._finishGguf()
    A.check("t5/tier1-mainGpu", s.runningModels[0].mainGpu, 45)
    A.check("t5/tier1-source", s.runningModels[0]._gpuSplitSource, "api")
    A.check("t5/tier1-ngl-untouched", s.runningModels[0].ngl, "45")
    // Section overrides globals (llama.cpp models.ini merge semantics).
    s._presetCache = s._parseIniLines("[*]\nn-gpu-layers = all\n[/m/override.gguf]\nmodel = /m/override.gguf\nn-gpu-layers = 30\n")
    s._ggufCache = ({})
    s.runningModels = [{ modelPath: "/m/override.gguf", draftPath: "", ngl: "", contextLen: 131072,
      sizeBytes: 0, cacheK: "", cacheV: "" }]
    s._ggufPath = "/m/override.gguf"
    s._ggufBuffer = "GGUF-OK\narch=qwen35\nblock_count=80\nhead_count=24\nhead_count_kv=8\nembedding_length=5120\n"
    s._finishGguf()
    A.check("t5/section-over-global", s.runningModels[0].mainGpu, 30)
    A.check("t5/section-over-global-source", s.runningModels[0]._gpuSplitSource, "preset")
    // auto (API + preset both "auto") is NOT resolved by the preset → the split
    // stays unknown rather than guessing (llama decides the actual value).
    s._presetCache = s._parseIniLines("[*]\nn-gpu-layers = auto\n[/m/auto.gguf]\nmodel = /m/auto.gguf\n")
    s._ggufCache = ({})
    s.runningModels = [{ modelPath: "/m/auto.gguf", draftPath: "", ngl: "auto", contextLen: 131072,
      sizeBytes: 0, cacheK: "", cacheV: "" }]
    s._ggufPath = "/m/auto.gguf"
    s._ggufBuffer = "GGUF-OK\narch=qwen35\nblock_count=80\nhead_count=24\nhead_count_kv=8\nembedding_length=5120\n"
    s._finishGguf()
    A.check("t5/auto-stays-unresolved", s.runningModels[0].mainGpu, null)

    // _finishPreset → _applyPresetToRunning: a preset landing AFTER the GGUF
    // read re-resolves the running entries (no refresh needed) and, with the
    // service stopped, republishes the available list from the preset.
    s._ggufCache = ({})
    s._ggufCache["/m/fit-model.gguf"] = { bc: 80, hc: 24, hckv: 8, embd: 5120 }
    s.running = false
    s.runningModels = [{ modelPath: "/m/fit-model.gguf", draftPath: "", ngl: "", contextLen: 131072,
      sizeBytes: 0, cacheK: "", cacheV: "" }]
    s._presetBuffer = "[*]\nn-gpu-layers = all\n[/m/fit-model.gguf]\nmodel = /m/fit-model.gguf\n[/m/offloaded.gguf]\nmodel = /m/offloaded.gguf\nn-gpu-layers = 10\n"
    s._finishPreset()
    A.check("t5/finish-reapplied-mainGpu", s.runningModels[0].mainGpu, 80)
    A.check("t5/finish-reapplied-source", s.runningModels[0]._gpuSplitSource, "preset")
    A.ok("t5/finish-stop-republished", s.models.length === 2)

    A.finish()
  }
}
