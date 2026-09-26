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

    // ── Architecture-aware KV: _kvCellsForType / _buildKvLayers /
    // _kvEstimateBytesArch (real per-architecture shapes, not a uniform product).
    // All unknown inputs → null / -1 ("—"). ────────────────────────────────
    // There is deliberately no per-architecture SWA-period table in the service:
    // llama.cpp owns those constants in its own source and a copy goes stale the
    // next time upstream changes a model, so a missing pattern key is answered
    // by the engine probe (Tier 3.5) instead. Pinned here so re-adding one fails.
    A.check("kvarch/no-arch-table", typeof s._swaPeriodFor, "undefined")
    A.check("kvarch/no-arch-switch", /_swaPeriodFor|gemma3|gemma4|llama4|cohere2|gpt_oss|gemma3n/
      .test(String(s.kvProbeScript)), false)

    A.check("kvarch/cells-full", s._kvCellsForType(false, 262144, 1024, 512, false, true, 1), 262144)
    A.check("kvarch/cells-swa", s._kvCellsForType(true, 262144, 1024, 512, false, true, 1), 1536)
    A.check("kvarch/cells-swa-full", s._kvCellsForType(true, 262144, 1024, 512, true, true, 1), 262144)
    A.check("kvarch/cells-pad256", s._kvCellsForType(true, 65536, 1000, 32, false, true, 1), 1280)
    A.check("kvarch/cells-clamp", s._kvCellsForType(true, 2048, 1024, 512, false, true, 1), 1536)
    A.check("kvarch/cells-unknown-window", s._kvCellsForType(true, 262144, -1, 512, false, true, 1), -1)
    A.check("kvarch/cells-badctx", s._kvCellsForType(false, 0, 1024, 512, false, true, 1), -1)

    // gemma4-26b-a4b real shape: 30 layers, pattern [swa×5, full], kvHeads 8/2,
    // key_length 512 / key_length_swa 256 / sliding_window 1024 / ctx 262144.
    // 5 full layers × 2×512×262144×4 + 25 SWA × 8×256×1536×4 = 5,683,281,920 B
    var gm4Heads = [], gm4Pat = []
    for (var g4i = 0; g4i < 30; g4i++) {
      gm4Heads.push((g4i + 1) % 6 === 0 ? 2 : 8)
      gm4Pat.push((g4i + 1) % 6 === 0 ? 0 : 1)
    }
    var ggemma4 = { arch: "gemma4", bc: 30, hc: 16, hckv: -1, hckvArr: gm4Heads,
      embd: 2816, kl: 512, vl: 512, klswa: 256, vlswa: 256, swa: 1024,
      swaPattern: -1, swaPatternArr: gm4Pat, recurrentArr: null, fai: -1,
      sharedKv: -1, kvLoraRank: -1, ropeDim: -1 }
    var sv4 = s._buildKvLayers(ggemma4, 30, 262144, { ubatch: 512, parallel: 1, swaFull: false, kvUnified: true })
    A.ok("kvarch/gemma4-spec", sv4 !== null)
    A.check("kvarch/gemma4-count", sv4.layers.length, 30)
    A.check("kvarch/gemma4-first-full", sv4.layers[5].kvHeads, 2)
    A.check("kvarch/gemma4-swa-cells", sv4.layers[0].cells, 1536)
    A.check("kvarch/gemma4-full-cells", sv4.layers[5].cells, 262144)
    A.check("kvarch/gemma4-bytes", s._kvEstimateBytesArch(sv4, 16, 16), 5683281920)
    A.check("kvarch/gemma4-formatGB", s.formatGB(5683281920), "5.3 GB")
    // q8_0 KV halves the bytes (8.5/16 per element).
    A.check("kvarch/gemma4-q8", s._kvEstimateBytesArch(sv4, 8.5, 8.5), 3019243520)
    // The deployed gemma-4-26b-a4b-qat args (ctx 262144, K/V q8_0, parallel 1,
    // ubatch 512, no --swa-full, -kvu): 5 full layers × 544 MiB
    // (2 heads × (512 K + 512 V) × 8.5/8 B × 262144 cells) + 25 SWA layers ×
    // 6.375 MiB (8 heads × (256 K + 256 V) × 8.5/8 B × 1536 cells) = 2,879.375 MiB,
    // byte-for-byte llama.cpp's own `llama_kv_cache: size =` line. The i32
    // head_count_kv array (2 on the full layers) is what makes this 2.8 GiB
    // instead of the 21.6 GB the head_count fallback produced.
    var sv4u = s._buildKvLayers(ggemma4, 30, 262144,
      { ubatch: 512, parallel: 1, swaFull: false, kvUnified: false })
    A.check("kvarch/gemma4-deployed-bytes", s._kvEstimateBytesArch(sv4u, 8.5, 8.5), 3019243520)
    A.check("kvarch/gemma4-deployed-mib", Math.round(3019243520 / 1048576 * 1000) / 1000, 2879.375)
    A.check("kvarch/gemma4-deployed-formatGB", s.formatGB(3019243520), "2.8 GB")
    // Drop the per-layer head_count_kv array AND the pattern array and the header
    // no longer describes its own layer layout: head_count (16) on every layer
    // would claim 21.56 GiB — the ~21.6 GB figure this whole path exists to
    // avoid — so the derivation answers nothing and the engine probe does.
    var g4NoArr = {}
    for (var g4k in ggemma4) g4NoArr[g4k] = ggemma4[g4k]
    g4NoArr.hckvArr = null
    g4NoArr.swaPatternArr = null
    A.check("kvarch/gemma4-no-pattern-unknown", s._buildKvLayers(g4NoArr, 30, 262144,
      { ubatch: 512, parallel: 1, swaFull: false, kvUnified: false }), null)
    A.check("kvarch/gemma4-no-pattern-bytes", s._kvEstimateBytesArch(
      s._buildKvLayers(g4NoArr, 30, 262144,
        { ubatch: 512, parallel: 1, swaFull: false, kvUnified: false }), 8.5, 8.5), -1)

    // qwen35 hybrid: recurrent_layers array vs full_attention_interval fallback
    // must count the SAME full layers (parity). headK = embd/n_head fallback.
    // sliding_window 0 declares a dense cache, which is what keeps this test
    // about layer SELECTION (which layers keep a context cache at all) instead of
    // about SWA; without such a declaration the same fixture is unknown below.
    var gqw = { arch: "qwen35", bc: 65, hc: 24, hckv: 4, hckvArr: null, embd: 5120,
      kl: -1, vl: -1, klswa: -1, vlswa: -1, swa: 0, swaPattern: -1,
      swaPatternArr: null, recurrentArr: null, fai: 4, sharedKv: -1,
      kvLoraRank: -1, ropeDim: -1 }
    var svF = s._buildKvLayers(gqw, 64, 96256, { ubatch: 512, parallel: 1, swaFull: false, kvUnified: true })
    A.check("kvarch/qwen35-fai-count", svF.layers.length, 16)
    var recIdx = []
    for (var qs = 0; qs < 64; qs++) if ((qs + 1) % 4 !== 0) recIdx.push(qs)
    var gqwR = { arch: "qwen35", bc: 65, hc: 24, hckv: 4, hckvArr: null, embd: 5120,
      kl: -1, vl: -1, klswa: -1, vlswa: -1, swa: 0, swaPattern: -1,
      swaPatternArr: null, recurrentArr: recIdx, fai: -1, sharedKv: -1,
      kvLoraRank: -1, ropeDim: -1 }
    var svR = s._buildKvLayers(gqwR, 64, 96256, { ubatch: 512, parallel: 1, swaFull: false, kvUnified: true })
    A.check("kvarch/qwen35-array-count", svR.layers.length, 16)
    A.check("kvarch/qwen35-parity", s._kvEstimateBytesArch(svR, 5.25, 4.5),
      s._kvEstimateBytesArch(svF, 5.25, 4.5))
    A.check("kvarch/qwen35-count-parity", svR.layers.length, svF.layers.length)
    A.check("kvarch/qwen35-dense-bytes", s._kvEstimateBytesArch(svF, 5.25, 4.5),
      s._kvEstimateBytes(16, 96256, 4, 5120 / 24, 5.25, 4.5))
    // The same hybrid with no SWA declaration is unknown, not dense-by-default.
    var gqwU = {}
    for (var qw in gqw) gqwU[qw] = gqw[qw]
    gqwU.swa = -1
    A.check("kvarch/qwen35-undeclared-unknown", s._buildKvLayers(gqwU, 64, 96256,
      { ubatch: 512, parallel: 1, swaFull: false, kvUnified: true }), null)

    // shared_kv_layers: the tail layers reuse earlier KV → excluded from count.
    var gsh = { arch: "llama", bc: 30, hc: 16, hckv: -1, hckvArr: null, embd: 2816,
      kl: -1, vl: -1, klswa: -1, vlswa: -1, swa: 0, swaPattern: -1,
      swaPatternArr: null, recurrentArr: null, fai: -1, sharedKv: 6,
      kvLoraRank: -1, ropeDim: -1 }
    var svSh = s._buildKvLayers(gsh, 30, 262144, { ubatch: 512, parallel: 1, swaFull: false, kvUnified: true })
    A.check("kvarch/shared-count", svSh.layers.length, 24)
    A.check("kvarch/shared-bytes", s._kvEstimateBytesArch(svSh, 16, 16),
      s._kvEstimateBytes(24, 262144, 16, 2816 / 16, 16, 16))

    // SWA declared (sliding_window > 0) but no pattern key: the PERIOD lives in
    // llama.cpp's gemma3 source, not in the file, so the header path must not
    // invent one (it used to hardcode 6) — the engine probe answers instead.
    var gg3 = { arch: "gemma3", bc: 24, hc: 8, hckv: 4, hckvArr: null, embd: 1280,
      kl: 256, vl: 256, klswa: 128, vlswa: 128, swa: 512, swaPattern: -1,
      swaPatternArr: null, recurrentArr: null, fai: -1, sharedKv: -1,
      kvLoraRank: -1, ropeDim: -1 }
    A.check("kvarch/gemma3-swa-period-unknown", s._buildKvLayers(gg3, 24, 32768,
      { ubatch: 512, parallel: 1, swaFull: false, kvUnified: true }), null)
    // The same model with an explicit period in the file describes itself
    // completely: every 6th layer full, the rest SWA at 128-wide rows.
    var gg3p = {}
    for (var g3k in gg3) gg3p[g3k] = gg3[g3k]
    gg3p.swaPattern = 6
    var svG3 = s._buildKvLayers(gg3p, 24, 32768, { ubatch: 512, parallel: 1, swaFull: false, kvUnified: true })
    var fullG3 = 0
    for (var g3i = 0; g3i < svG3.layers.length; g3i++) if (svG3.layers[g3i].cells === 32768) fullG3++
    A.check("kvarch/gemma3-total", svG3.layers.length, 24)
    A.check("kvarch/gemma3-full-count", fullG3, 4)
    // attention.sliding_window == 0 is an explicit "no SWA" declaration that
    // every llama.cpp source reading that key treats as KV_TYPE_NONE, so a
    // dense model answers from the header alone.
    var gdense = { arch: "llama", bc: 32, hc: 32, hckv: 8, hckvArr: null, embd: 4096,
      kl: -1, vl: -1, klswa: -1, vlswa: -1, swa: 0, swaPattern: -1,
      swaPatternArr: null, recurrentArr: null, fai: -1, sharedKv: -1,
      kvLoraRank: -1, ropeDim: -1 }
    var svDense = s._buildKvLayers(gdense, 32, 8192, { ubatch: 512, parallel: 1, swaFull: false, kvUnified: true })
    A.check("kvarch/dense-declared-layers", svDense.layers.length, 32)
    A.check("kvarch/dense-declared-cells", svDense.layers[0].cells, 8192)
    A.check("kvarch/dense-declared-bytes", s._kvEstimateBytesArch(svDense, 16, 16),
      s._kvEstimateBytes(32, 8192, 8, 4096 / 32, 16, 16))
    // Absent sliding_window is NOT such a declaration: llama4 builds an SWA cache
    // without one, so absence must stay unknown rather than reading as dense.
    var gabs = {}
    for (var gk in gdense) gabs[gk] = gdense[gk]
    gabs.swa = -1
    A.check("kvarch/absent-window-not-dense", s._buildKvLayers(gabs, 32, 8192,
      { ubatch: 512, parallel: 1, swaFull: false, kvUnified: true }), null)

    // key_length explicit wins over embd/n_head; absent key → old-formula parity.
    var gkl = { arch: "llama", bc: 2, hc: 8, hckv: 4, hckvArr: null, embd: 2048,
      kl: 512, vl: -1, klswa: -1, vlswa: -1, swa: 0, swaPattern: -1,
      swaPatternArr: null, recurrentArr: null, fai: -1, sharedKv: -1,
      kvLoraRank: -1, ropeDim: -1 }
    var svKl = s._buildKvLayers(gkl, 2, 8192, { ubatch: 512, parallel: 1, swaFull: false, kvUnified: true })
    A.check("kvarch/keylen-explicit", s._kvEstimateBytesArch(svKl, 16, 16), 134217728)
    var gfk = { arch: "llama", bc: 2, hc: 8, hckv: 4, hckvArr: null, embd: 2048,
      kl: -1, vl: -1, klswa: -1, vlswa: -1, swa: 0, swaPattern: -1,
      swaPatternArr: null, recurrentArr: null, fai: -1, sharedKv: -1,
      kvLoraRank: -1, ropeDim: -1 }
    var svFk = s._buildKvLayers(gfk, 2, 8192, { ubatch: 512, parallel: 1, swaFull: false, kvUnified: true })
    A.check("kvarch/keylen-fallback", s._kvEstimateBytesArch(svFk, 16, 16), 67108864)
    A.check("kvarch/keylen-fallback-parity", s._kvEstimateBytesArch(svFk, 16, 16),
      s._kvEstimateBytes(2, 8192, 4, 2048 / 8, 16, 16))

    // MLA (DeepSeek-style): kv_lora_rank + rope dims K-only, dense full-ctx.
    var gmla = { arch: "deepseek2", bc: 61, hc: 8, hckv: 8, hckvArr: null, embd: 2048,
      kl: -1, vl: -1, klswa: -1, vlswa: -1, swa: -1, swaPattern: -1,
      swaPatternArr: null, recurrentArr: null, fai: -1, sharedKv: -1,
      kvLoraRank: 512, ropeDim: 64 }
    var svMla = s._buildKvLayers(gmla, 61, 4096, { ubatch: 512, parallel: 1, swaFull: false, kvUnified: true })
    A.ok("kvarch/mla-K-only", svMla.layers[0].hasV === false)
    A.check("kvarch/mla-bytes", s._kvEstimateBytesArch(svMla, 16, 16), 287834112)

    // Unknown shapes degrade to "—": -1 / null.
    A.check("kvarch/unknown-shape", s._kvEstimateBytesArch(
      s._buildKvLayers({ bc: 30, arch: "llama" }, 30, 262144,
        { ubatch: 512, parallel: 1, swaFull: false, kvUnified: true }), 16, 16), -1)
    A.check("kvarch/unknown-ctx", s._kvEstimateBytesArch(
      s._buildKvLayers(ggemma4, 30, -1, { ubatch: 512, parallel: 1, swaFull: false, kvUnified: true }), 16, 16), -1)
    A.check("kvarch/unknown-kbits", s._kvEstimateBytesArch(sv4, -1, 16), -1)
    A.check("kvarch/unknown-vbits", s._kvEstimateBytesArch(sv4, 16, -1), -1)
    A.check("kvarch/null-spec", s._kvEstimateBytesArch(null, 16, 16), -1)

    // _finishGguf array-line parse: key=a:v1,v2,... → hckvArr/swaPatternArr.
    s._ggufCache = ({})
    s.runningModels = [{ modelPath: "/m/g5.gguf", draftPath: "", ngl: "all", contextLen: 262144,
      sizeBytes: 0, cacheK: "", cacheV: "" }]
    s._ggufPath = "/m/g5.gguf"
    s._ggufBuffer = "GGUF-OK\narch=gemma4\nblock_count=2\nhead_count=16\nembedding_length=2816\n" +
      "key_length=512\nkey_length_swa=256\nvalue_length=512\nvalue_length_swa=256\nsliding_window=1024\n" +
      "sliding_window_pattern=a:1,1,1,1,1,0\nhead_count_kv=a:8,8,8,8,8,2\n"
    s._finishGguf()
    A.check("gguf/array-arch", s._ggufCache["/m/g5.gguf"].arch, "gemma4")
    A.check("gguf/array-hckv-first", s._ggufCache["/m/g5.gguf"].hckvArr[0], 8)
    A.check("gguf/array-hckv-last", s._ggufCache["/m/g5.gguf"].hckvArr[5], 2)
    A.check("gguf/array-swa-pattern", s._ggufCache["/m/g5.gguf"].swaPatternArr[5], 0)
    A.check("gguf/array-fold-kv", s.runningModels[0].kvCacheBytes, 25165824)

    // Arg-parse flags: --ubatch/-ub, --parallel/-np, --swa-full, -kvu/--no-kv-unified.
    var pf = s._parseLlamaArgs(["--ubatch", "320", "--parallel", "4", "--swa-full", "-kvu"])
    A.check("args-kv/ubatch", pf.ubatch, 320)
    A.check("args-kv/parallel", pf.parallel, 4)
    A.check("args-kv/swaFull", pf.swaFull, true)
    A.check("args-kv/noKvUnified", pf.noKvUnified, true)
    var pfi = s._parseLlamaArgs(["-ub=320", "-np=2", "--no-kv-unified"])
    A.check("args-kv/ubatch-inline", pfi.ubatch, 320)
    A.check("args-kv/parallel-inline", pfi.parallel, 2)
    A.check("args-kv/noKvUnified-long", pfi.noKvUnified, true)
    var pfd = s._parseLlamaArgs([])
    A.check("args-kv/default-ubatch", pfd.ubatch, 512)
    A.check("args-kv/default-parallel", pfd.parallel, 1)
    A.check("args-kv/default-swaFull", pfd.swaFull, false)
    A.check("args-kv/default-noKvUnified", pfd.noKvUnified, false)

    // ── _kvPlacement: where the KV cache actually lives ──────────────────────
    // Only two things decide, and both are facts rather than a model of the
    // engine's placement heuristic: the flags it was given, and where the bytes
    // turned up. A KV-sized anonymous host block PROVES the cache is in RAM
    // (llama.cpp maps weights with CPU_Mapped and the cache with plain CPU
    // buffers, so a KV-sized anon+shmem block can only be the cache); its
    // absence plus the presence of device memory PROVES the device by
    // exhaustion. The old free-VRAM-vs-fit-target comparison needed llama.cpp's
    // internal fit budget, which is version-specific and not readable — and it
    // disagreed with the running worker on the very model this exists for.
    // gemma-4-26b-a4b-qat as measured here: KV 3,019,243,520 B, service DRAM
    // 3,070,361,600 B, service VRAM 13,144 MiB → CPU.
    var KV4 = 3019243520
    var VR4 = 13144 * 1048576
    var MEM4 = 3070361600
    var sole = { memBytes: MEM4, vramBytes: VR4, sole: true }
    A.check("kvplace/no-kv-offload-cpu", s._kvPlacement(true, 30, 30, KV4, sole), "CPU")
    A.check("kvplace/no-kv-offload-beats-measure", s._kvPlacement(true, 30, 30, -1, sole), "CPU")
    A.check("kvplace/fit-dropped-cpu", s._kvPlacement(false, 30, 30, KV4, sole), "CPU")
    A.check("kvplace/nothing-offloaded-cpu", s._kvPlacement(false, 0, 30, -1, sole), "CPU")
    // A FULLY offloaded stack is not the mirror of -ngl 0 and must not be
    // treated as one: the live gemma-4 worker runs all 30 layers on the device
    // with its cache in host RAM, so "every layer is on the GPU" proves
    // nothing about where the cache went.
    A.check("kvplace/all-offloaded-not-proof", s._kvPlacement(false, 30, 30, KV4,
      { memBytes: -1, vramBytes: VR4, sole: true }), "")
    A.check("kvplace/all-offloaded-still-measured", s._kvPlacement(false, 30, 30, 2000000000,
      { memBytes: 400000000, vramBytes: 5800000000, sole: true }), "GPU")
    // A partial split is likewise not a measurement on its own.
    A.check("kvplace/partial-needs-measurement", s._kvPlacement(false, 30, 64, KV4, sole), "CPU")
    A.check("kvplace/partial-unknown-without-measurement", s._kvPlacement(false, 30, 64, KV4, {}), "")
    // Cache on the device: host RAM holds far less than the cache, and the
    // service does hold device memory.
    A.check("kvplace/offloaded-gpu", s._kvPlacement(false, 65, 65, 2000000000,
      { memBytes: 400000000, vramBytes: 5800000000, sole: true }), "GPU")
    // Exactly at the boundary counts as host RAM (>=, not >): a cache that
    // fills anon to the byte is a cache in RAM.
    A.check("kvplace/host-boundary", s._kvPlacement(false, 30, 30, KV4,
      { memBytes: KV4, vramBytes: VR4, sole: true }), "CPU")
    A.check("kvplace/host-just-under", s._kvPlacement(false, 30, 30, KV4,
      { memBytes: KV4 - 1, vramBytes: VR4, sole: true }), "GPU")
    // No device context at all: the cache cannot be on a device, so it is RAM.
    A.check("kvplace/no-device-context-cpu", s._kvPlacement(false, 30, 30, KV4,
      { memBytes: 1000000, vramBytes: 0, sole: true }), "CPU")
    // Multi-model router: both readings are the whole cgroup's, so neither can
    // be attributed to this model. Only the flag branches may still answer.
    A.check("kvplace/multi-model-unknown", s._kvPlacement(false, 30, 30, KV4,
      { memBytes: MEM4, vramBytes: VR4, sole: false }), "")
    A.check("kvplace/multi-model-still-exact", s._kvPlacement(true, 30, 30, KV4,
      { memBytes: MEM4, vramBytes: VR4, sole: false }), "CPU")
    // Unknowns must stay unknown ("" = the Context line just omits the device).
    A.check("kvplace/unknown-kv", s._kvPlacement(false, 30, 30, -1, sole), "")
    A.check("kvplace/unknown-dram", s._kvPlacement(false, 30, 30, KV4,
      { memBytes: -1, vramBytes: VR4, sole: true }), "")
    // The measurements answer even when the layer split didn't resolve.
    A.check("kvplace/no-split-still-answers", s._kvPlacement(false, -1, -1, KV4, sole), "CPU")
    A.check("kvplace/null-inputs", s._kvPlacement(null, null, null, null, null), "")

    // ── _estimateSplitFromProbes: measured VRAM → layer estimate (~) ──────────
    // Built only from measurements: the device footprint minus the cache when
    // placement says the cache is there, minus the engine's compute-graph
    // reserve, scaled by the model's real file size.
    A.check("probe/empty-vram", s._estimateSplitFromProbes(100, 65, -1, 0, 0), null)
    A.check("probe/no-size", s._estimateSplitFromProbes(0, 65, 2*1024*1024*1024, 0, 0), null)
    A.check("probe/no-layers", s._estimateSplitFromProbes(10*1024*1024*1024, 0, 2*1024*1024*1024, 0, 0), null)
    A.check("probe/full-gpu", s._estimateSplitFromProbes(10*1024*1024*1024, 65, 9*1024*1024*1024, 0, 0), {gpuLayers: 59, cpuLayers: 6})
    // No weights left on the device once the cache is removed → nothing to
    // split (returning null renders "—" instead of claiming 0 GPU layers).
    A.check("probe/all-cache", s._estimateSplitFromProbes(10*1024*1024*1024, 65, 0, 0, 0), null)
    A.check("probe/cache-exceeds-vram", s._estimateSplitFromProbes(10*1024*1024*1024, 65, 1024, 2048, 0), null)
    A.check("probe/half-gpu", s._estimateSplitFromProbes(10*1024*1024*1024, 65, 5*1024*1024*1024, 0, 0), {gpuLayers: 33, cpuLayers: 32})
    // Subtracting the measured cache and compute reserve tightens the estimate
    // (fewer layers claimed than the raw footprint suggests) and clamps at 0.
    A.check("probe/subtracts-cache", s._estimateSplitFromProbes(10*1024*1024*1024, 65,
      5*1024*1024*1024, 1*1024*1024*1024, 0).gpuLayers, 26)
    A.check("probe/subtracts-compute", s._estimateSplitFromProbes(10*1024*1024*1024, 65,
      5*1024*1024*1024, 0, 1*1024*1024*1024).gpuLayers, 26)
    A.check("probe/clamps-to-zero", s._estimateSplitFromProbes(10*1024*1024*1024, 65,
      5*1024*1024*1024, 5*1024*1024*1024, 0), null)

    // ── _resolveRunningEntries: fresh reference + synchronous cached resolve ──
    s._ggufCache["/m/a.gguf"] = { bc: 65, hc: 24, hckv: 4, embd: 5120 }
    var entries = [{ modelPath: "/m/a.gguf", draftPath: "", ngl: "all", contextLen: 262144,
      sizeBytes: 100, cacheK: "q8_0", cacheV: "q8_0" }]
    var out = s._resolveRunningEntries(entries)
    A.ok("resolve/fresh-ref", out !== entries)
    A.check("resolve/totalLayers", out[0].totalLayers, 65)
    A.check("resolve/mainGpu", out[0].mainGpu, 65)
    A.check("resolve/mainCpu", out[0].mainCpu, 0)
    A.check("resolve/kvCacheBytes-unknown", out[0].kvCacheBytes, -1)
    // Tier 3.5 answers as soon as the engine has been asked.
    out[0].kvBytesExact = 3019243520
    var rk = s._resolveKvBytes(out[0])
    A.check("resolve/kvBytes-exact-tier", rk.tier, 3)
    A.check("resolve/kvBytes-exact-marker", rk.marker, "")
    A.check("resolve/kvBytes-exact-value", rk.value, 3019243520)

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
    A.check("rs/t5-auto-value-gpu", rr.gpuSplit.value.mainGpu, 33)

    // Tier 3 live estimate: no API, no preset, VRAM available → the same
    // numbers _estimateSplitFromProbes yields, marked as an estimate.
    rr = s._resolveFieldSources({ totalLayers: 65, sizeBytes: 10*1024*1024*1024 },
      { vramBytes: 5*1024*1024*1024, memBytes: -1 })
    A.check("rs/t3-split-tier", rr.gpuSplit.tier, 3)
    A.check("rs/t3-split-marker", rr.gpuSplit.marker, "~")
    A.check("rs/t3-split-gpu", rr.gpuSplit.value.mainGpu, 33)
    // Placement is decided from measurements, never inferred from the split:
    // gpuSplit.value carries layer counts and nothing else.
    A.check("rs/t3-split-no-ctxOn", rr.gpuSplit.value.ctxOn, undefined)

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
    // No pattern key and no sliding_window declaration: this header does not
    // describe its own SWA layout, so the derivation answers nothing (the old
    // head_count product claimed a dense cache that qwen3next does not build).
    // The engine probe is what fills this in — see the Tier-3.5 block below.
    A.check("gguf/kvCacheBytes-unknown", s.runningModels[0].kvCacheBytes, -1)
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
    // Same for the hybrid: the interval array says WHICH layers keep a context
    // cache, not whether those layers slide, so the header alone cannot size it.
    A.check("hybrid/kvCacheBytes", s.runningModels[0].kvCacheBytes, -1)

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

    // ── Tier 3.5 engine KV accounting probe ────────────────────────────────
    // llama.cpp prints the allocation it actually built; these are verbatim
    // lines from `llama-cli --verbose -ngl 0` against the real gemma-4-26b-a4b
    // at ctx 262144 / K=V q8_0, and the two caches (5 full + 25 SWA layers) are
    // what sum to the 2,879.375 MiB the running worker holds.
    A.ok("kvprobe/iswa-line", s._parseKvProbeLine("0.00.532.354 D llama_kv_cache: layer   5: dev = CPU") === null)
    var pFull = s._parseKvProbeLine("0.00.546.246 I llama_kv_cache: size = 2720.00 MiB (262144 cells,   5 layers,  1/1 seqs), K (q8_0): 1360.00 MiB, V (q8_0): 1360.00 MiB")
    A.check("kvprobe/full-bytes", pFull.bytes, Math.round(2720 * 1048576))
    A.check("kvprobe/full-layers", pFull.layers, 5)
    var pSwa = s._parseKvProbeLine("0.00.546.779 I llama_kv_cache: size =  159.38 MiB (  1536 cells,  25 layers,  1/1 seqs), K (q8_0):   79.69 MiB, V (q8_0):   79.69 MiB")
    A.check("kvprobe/swa-bytes", pSwa.bytes, Math.round(159.38 * 1048576))
    A.check("kvprobe/swa-layers", pSwa.layers, 25)
    // Summed across the two allocations the probe reads llama.cpp's own
    // 2,879.375 MiB (the header derivation's 3,019,243,520 B) up to the log's
    // own two-decimal MiB printing, i.e. a few KiB.
    var probeTotal = pFull.bytes + pSwa.bytes
    A.ok("kvprobe/total-bytes", Math.abs(probeTotal - 3019243520) <= 8 * 1024)
    // 2720.00 + 159.38 printed MiB = 2879.38 against a true 2879.375 MiB.
    A.ok("kvprobe/total-mib", Math.abs(probeTotal / 1048576 - 2879.375) <= 0.01)
    var pCompute = s._parseKvProbeLine("0.00.552.030 I sched_reserve:      CUDA0 compute buffer size =  1887.86 MiB")
    A.check("kvprobe/compute-bytes", pCompute.bytes, Math.round(1887.86 * 1048576))
    A.check("kvprobe/compute-kind", pCompute.kind, "compute")
    // Not accounting lines: ignored rather than misread.
    A.check("kvprobe/weight-line-ignored", s._parseKvProbeLine("0.01.057.051 I load_tensors:   CPU_Mapped model buffer size = 13573.86 MiB"), null)
    A.check("kvprobe/host-buffer-ignored", s._parseKvProbeLine("0.00.546.243 I llama_kv_cache:        CPU KV buffer size =     0.00 MiB"), null)
    A.check("kvprobe/garbage", s._parseKvProbeLine("not a line at all"), null)
    A.check("kvprobe/empty", s._parseKvProbeLine(""), null)
    A.check("kvprobe/null", s._parseKvProbeLine(null), null)
    // A zero-size cache is not an answer (it would divide the display by zero).
    A.check("kvprobe/zero-size", s._parseKvProbeLine("llama_kv_cache: size = 0.00 MiB (0 cells, 0 layers)"), null)

    // The real gemma-4-26b --verbose run emits each cache block twice, so the
    // fold must be idempotent over a repeated block. These are the four
    // accounting lines in the order the engine prints them.
    s._kvProbeAcc = { kvBytes: 0, kvLayers: 0, computeBytes: -1, blocks: [], compute: ({}), computeSeen: [] }
    var log26 = [
      "llama_kv_cache: layer   0: dev = CPU",
      "llama_kv_cache:        CPU KV buffer size =     0.00 MiB",
      "llama_kv_cache: size = 2720.00 MiB (262144 cells,   5 layers,  1/1 seqs), K (q8_0): 1360.00 MiB, V (q8_0): 1360.00 MiB",
      "llama_kv_cache: size =  159.38 MiB (  1536 cells,  25 layers,  1/1 seqs), K (q8_0):   79.69 MiB, V (q8_0):   79.69 MiB",
      "sched_reserve:      CUDA0 compute buffer size =  1887.86 MiB",
      "sched_reserve:  CUDA_Host compute buffer size =   272.30 MiB",
      "llama_kv_cache: layer   0: dev = CPU",
      "llama_kv_cache: size = 2720.00 MiB (262144 cells,   5 layers,  1/1 seqs), K (q8_0): 1360.00 MiB, V (q8_0): 1360.00 MiB",
      "llama_kv_cache: size =  159.38 MiB (  1536 cells,  25 layers,  1/1 seqs), K (q8_0):   79.69 MiB, V (q8_0):   79.69 MiB",
      "sched_reserve:      CUDA0 compute buffer size =  1887.86 MiB",
      "sched_reserve:  CUDA_Host compute buffer size =   272.30 MiB"]
    for (var li = 0; li < log26.length; li++) s._onKvProbeLine(log26[li])
    var acc26 = s._kvProbeAcc
    A.ok("kvprobe/dedupe-bytes", Math.abs(acc26.kvBytes - 3019243520) <= 8 * 1024)
    A.check("kvprobe/dedupe-layers", acc26.kvLayers, 30)
    // The real log also reserves a HOST-side buffer next to the device one
    // (CUDA0 1887.86 MiB + CUDA_Host 272.30 MiB, each logged twice). Only the
    // device reserve may be charged against VRAM.
    A.check("kvprobe/compute-device-only", s._kvProbeAcc.compute.CUDA0, Math.round(1887.86 * 1048576))
    A.check("kvprobe/compute-host-ignored", s._kvProbeAcc.compute.CUDA_Host, undefined)
    A.check("kvprobe/compute-not-doubled", s._kvProbeAcc.computeSeen.length, 1)
    // A failed run must publish nothing, even though llama.cpp allocates and
    // logs its cache before it can fail (the real gemma-4 probe that exceeds
    // the address-space cap prints both size lines and then exits 1).
    s._kvProbeSignature = "sig-fail"
    s._finishKvProbe(false)
    A.check("kvprobe/failed-run-not-cached", s._kvProbeCache["sig-fail"], false)
    A.check("kvprobe/reset-bytes", s._kvProbeAcc.kvBytes, 0)
    A.check("kvprobe/reset-blocks", s._kvProbeAcc.blocks.length, 0)
    s._kvProbeSignature = ""
    // A clean exit does publish, and the cache is keyed by signature so a
    // refresh never re-probes it.
    s._kvProbeSignature = "sig-ok"
    s._onKvProbeLine(log26[2])
    s._finishKvProbe(true)
    A.ok("kvprobe/clean-run-cached", s._kvProbeCache["sig-ok"] !== undefined
      && s._kvProbeCache["sig-ok"] !== false)
    s._kvProbeCache = ({})
    // Two DISTINCT caches (a main + a spec context) both still count.
    s._kvProbeAcc = { kvBytes: 0, kvLayers: 0, computeBytes: -1, blocks: [], compute: ({}), computeSeen: [] }
    s._onKvProbeLine("llama_kv_cache: size = 100.00 MiB (4096 cells, 10 layers, 1/1 seqs), K (q8_0): 50.00 MiB, V (q8_0): 50.00 MiB")
    s._onKvProbeLine("llama_kv_cache: size =   8.00 MiB (  256 cells,  1 layers, 1/1 seqs), K (q8_0): 8.00 MiB")
    A.check("kvprobe/distinct-caches", s._kvProbeAcc.kvBytes, Math.round(108 * 1048576))
    A.check("kvprobe/distinct-layers", s._kvProbeAcc.kvLayers, 11)

    // Signature: what can change the allocation. Stable across unrelated field
    // changes, and different for every input that matters.
    var pe = { modelPath: "/m/a.gguf", contextLen: 262144, ubatch: 512, parallel: 1,
      cacheK: "q8_0", cacheV: "q8_0", swaFull: false, noKvUnified: false, ngl: "30" }
    function clone(o, k, v) { var c = ({}) ; for (var t in o) c[t] = o[t]; c[k] = v; return c }
    var sig = s._kvProbeSignatureFor(pe)
    A.ok("kvprobe/sig-stable", sig === s._kvProbeSignatureFor(pe))
    A.ok("kvprobe/sig-ignores-ngl", sig === s._kvProbeSignatureFor(clone(pe, "ngl", "99")))
    A.ok("kvprobe/sig-ctx", sig !== s._kvProbeSignatureFor(clone(pe, "contextLen", 131072)))
    A.ok("kvprobe/sig-dtype", sig !== s._kvProbeSignatureFor(clone(pe, "cacheV", "q4_0")))
    A.ok("kvprobe/sig-ubatch", sig !== s._kvProbeSignatureFor(clone(pe, "ubatch", 1024)))
    A.ok("kvprobe/sig-parallel", sig !== s._kvProbeSignatureFor(clone(pe, "parallel", 4)))
    A.ok("kvprobe/sig-swafull", sig !== s._kvProbeSignatureFor(clone(pe, "swaFull", true)))
    A.ok("kvprobe/sig-kvu", sig !== s._kvProbeSignatureFor(clone(pe, "noKvUnified", true)))
    A.check("kvprobe/sig-nopath", s._kvProbeSignatureFor({}), "")

    // argv: replays the KV-relevant flags, forces the probe off the GPU, and
    // stays away from every server-only flag.
    var av = s._kvProbeArgv(pe).join(" ")
    A.check("kvprobe/argv-ngl0", av.indexOf("-ngl 0") >= 0, true)
    A.check("kvprobe/argv-verbose", av.indexOf("--verbose") >= 0, true)
    A.check("kvprobe/argv-no-warmup", av.indexOf("--no-warmup") >= 0, true)
    A.check("kvprobe/argv-ctx", av.indexOf("-c 262144") >= 0, true)
    A.check("kvprobe/argv-ubatch", av.indexOf("-ub 512") >= 0, true)
    A.check("kvprobe/argv-parallel", av.indexOf("-np 1") >= 0, true)
    A.check("kvprobe/argv-kv", av.indexOf("--cache-type-k q8_0 --cache-type-v q8_0") >= 0, true)
    A.check("kvprobe/argv-swafull-absent", av.indexOf("--swa-full") < 0, true)
    A.check("kvprobe/argv-kvu-absent", av.indexOf("--no-kv-unified") < 0, true)
    A.check("kvprobe/argv-nkvo", s._kvProbeArgv(clone(pe, "noKvOffload", true))
      .join(" ").indexOf("--no-kv-offload") >= 0, true)
    // The model path is an argv element, never part of the script text.
    A.ok("kvprobe/argv-has-model", s._kvProbeArgv(pe).length < 30)
    A.check("kvprobe/argv-no-server-flags", /--port|--host|--api-key|--jinja|--mmproj|--draft|--threads/.test(av), false)

    // Result fold: exact bytes, cache layer count and compute reserve land on
    // the entry, and the resolver reports them as Tier 3.5 with no marker.
    s._ggufCache = ({})
    s.running = true
    s.runningModels = [{ modelPath: "/m/probe.gguf", draftPath: "", ngl: "all",
      contextLen: 262144, ubatch: 512, parallel: 1, cacheK: "q8_0", cacheV: "q8_0",
      swaFull: false, noKvUnified: false, sizeBytes: 14249045120, totalLayers: 30,
      mainLayers: 30, mainGpu: 30, mainCpu: 0, _gpuSplitSource: "api",
      kvCacheBytes: -1, kvBytesExact: -1, kvLayersExact: -1, computeBytes: -1 }]
    s._applyKvProbeResult(s._kvProbeSignatureFor(s.runningModels[0]),
      { kvBytes: 3019243520, kvLayers: 30, computeBytes: Math.round(1887.86 * 1048576) })
    A.check("kvprobe/fold-bytes", s.runningModels[0].kvBytesExact, 3019243520)
    A.check("kvprobe/fold-layers", s.runningModels[0].kvLayersExact, 30)
    A.check("kvprobe/fold-compute", s.runningModels[0].computeBytes, Math.round(1887.86 * 1048576))
    var rq = s._resolveFieldSources(s.runningModels[0],
      { vramBytes: 13782482944, memBytes: 3070361600, presetSection: null })
    A.check("kvprobe/rs-tier", rq.kvBytes.tier, 3)
    A.check("kvprobe/rs-marker", rq.kvBytes.marker, "")
    A.check("kvprobe/rs-value", rq.kvBytes.value, 3019243520)
    A.check("kvprobe/rs-format", s.formatGB(rq.kvBytes.value), "2.8 GB")
    // No answer from the engine → the header derivation keeps the line as "~".
    var rq2 = s._resolveFieldSources({ kvCacheBytes: 4000000000 },
      { vramBytes: -1, memBytes: -1, presetSection: null })
    A.check("kvprobe/rs-fallback-tier", rq2.kvBytes.tier, 4)
    A.check("kvprobe/rs-fallback-marker", rq2.kvBytes.marker, "~")
    var rq3 = s._resolveFieldSources({ kvCacheBytes: -1 },
      { vramBytes: -1, memBytes: -1, presetSection: null })
    A.check("kvprobe/rs-unknown-tier", rq3.kvBytes.tier, null)
    A.check("kvprobe/rs-unknown-value", rq3.kvBytes.value, -1)
    // A null result is cached as "tried, no answer" and never re-probed.
    s._kvProbeCache = ({})
    s._kvProbeQueue = []
    s._kvProbeSignature = ""
    var qs = s._kvProbeSignatureFor(s.runningModels[0])
    s._kvProbeCache[qs] = false
    s._queueKvProbe(s.runningModels[0])
    A.check("kvprobe/cached-no-answer", s._kvProbeQueue.length, 0)
    A.check("kvprobe/cached-exact-skips", s._queueKvProbe.length > 0, true)
    s._kvProbeCache[qs] = { kvBytes: 1, kvLayers: 1, computeBytes: -1 }
    s._queueKvProbe(s.runningModels[0])
    A.check("kvprobe/cached-exact-no-queue", s._kvProbeQueue.length, 0)
    // Disabled by configuration, and never for a backend without a KV cache.
    // Two devices sum; a CPU-only run reserves nothing to charge to VRAM.
    s._kvProbeAcc = { kvBytes: 0, kvLayers: 0, computeBytes: -1, blocks: [], compute: ({}), computeSeen: [] }
    s._onKvProbeLine("sched_reserve:      CPU compute buffer size =  100.00 MiB")
    s._onKvProbeLine("sched_reserve:     CUDA0 compute buffer size =  100.00 MiB")
    s._onKvProbeLine("sched_reserve:     CUDA1 compute buffer size =   50.00 MiB")
    s._kvProbeSignature = "sig-multi"
    s._onKvProbeLine("llama_kv_cache: size = 10.00 MiB (1024 cells, 4 layers, 1/1 seqs), K (q8_0): 5.00 MiB, V (q8_0): 5.00 MiB")
    s._finishKvProbe(true)
    A.check("kvprobe/multi-device-compute", s._kvProbeCache["sig-multi"].computeBytes,
      Math.round(150 * 1048576))
    s._kvProbeAcc = { kvBytes: 0, kvLayers: 0, computeBytes: -1, blocks: [], compute: ({}), computeSeen: [] }
    s._onKvProbeLine("sched_reserve:      CPU compute buffer size =  100.00 MiB")
    s._kvProbeSignature = "sig-cpu"
    s._onKvProbeLine("llama_kv_cache: size = 10.00 MiB (1024 cells, 4 layers, 1/1 seqs), K (q8_0): 5.00 MiB, V (q8_0): 5.00 MiB")
    s._finishKvProbe(true)
    A.check("kvprobe/cpu-only-no-compute", s._kvProbeCache["sig-cpu"].computeBytes, -1)
    s._kvProbeSignature = ""
    s._kvProbeCache = ({})
    // A stale accumulator missing the dedupe bookkeeping must not throw.
    s._kvProbeAcc = ({ kvBytes: 0, kvLayers: 0, computeBytes: -1 })
    s._onKvProbeLine("llama_kv_cache: size = 10.00 MiB (1024 cells, 4 layers, 1/1 seqs), K (q8_0): 5.00 MiB")
    A.check("kvprobe/self-heals-accumulator", s._kvProbeAcc.kvBytes, Math.round(10 * 1048576))
    // Overflowing the diagnostic log buffer must NOT stop the parse: the real
    // gemma-4 verbose log is ~224 KiB against a 256 KiB cap and prints its
    // cache blocks at the end of it.
    s._kvProbeAcc = { kvBytes: 0, kvLayers: 0, computeBytes: -1, blocks: [], compute: ({}), computeSeen: [] }
    s._kvProbeBuffer = ""
    for (var bl = 0; bl < 20000; bl++) s._onKvProbeLine("0.00.000.000 I load_tensors:   CPU_Mapped model buffer size = 100.00 MiB")
    s._onKvProbeLine("llama_kv_cache: size = 10.00 MiB (1024 cells, 4 layers, 1/1 seqs), K (q8_0): 5.00 MiB, V (q8_0): 5.00 MiB")
    A.check("kvprobe/parses-past-log-cap", s._kvProbeAcc.kvBytes, Math.round(10 * 1048576))
    A.ok("kvprobe/log-cap-bounded", s._kvProbeBuffer.length <= s._kvProbeBufferMax)
    s._kvProbeBuffer = ""
    A.check("kvprobe/off-setting", s.kvProbeBinary, "llama-cli")

    A.finish()
  }
}
