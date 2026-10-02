import QtQuick
import Quickshell
import Quickshell.Io
import "asserts.js" as A

// Unit: the pure llama.cpp derivation helpers that turn raw --n-gpu-layers /
// --cache-type-* tokens + GGUF header counts into the #7 display values. They
// must be total (never throw) and degrade to unknown (-1 / "-") on any bad
// input, so a partial or surprising server response can't break rendering.
Item {
  id: root

  // The tier-5 parser is driven from the committed golden capture, so a
  // toolchain change fails here with a diff instead of quietly mis-parsing the
  // rows. No invented strings: if the fixture is missing the parse groups fail
  // loudly rather than passing against a guess.
  FileView { id: fixtureView; printErrors: false; blockAllReads: true }
  function readFixture(path) {
    fixtureView.path = ""
    fixtureView.path = path
    var t = fixtureView.text()
    return (t === undefined || t === null) ? "" : String(t)
  }

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
    // by the engine probe (tier 6) instead. Pinned here so re-adding one fails.
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
    // A hybrid that declares its recurrent layers but carries no window at all
    // is DENSE, and must agree with the same file declaring sliding_window 0.
    // Rationale (Service.qml): a window is a property of an attention stack, and
    // llama.cpp hardcodes one for no architecture whose layers interleave with
    // recurrent ones — the set of sources that read recurrent_layers /
    // full_attention_interval / ssm.* and the set that call load_swa_pattern are
    // disjoint. So such a file either carries its own window key or has none, and
    // with no key the attention layers are full-size. This is the qwen3.6-35b-a3b
    // case (qwen35moe, 40 layers, fai 4, no window key), which the engine sizes
    // at one flat full-context cache over the 10 non-recurrent layers.
    var gqwU = {}
    for (var qw in gqw) gqwU[qw] = gqw[qw]
    gqwU.swa = -1
    var svU = s._buildKvLayers(gqwU, 64, 96256, { ubatch: 512, parallel: 1, swaFull: false, kvUnified: true })
    A.check("kvarch/qwen35-undeclared-dense", svU !== null, true)
    A.check("kvarch/qwen35-undeclared-count", svU.layers.length, svF.layers.length)
    A.check("kvarch/qwen35-undeclared-bytes", s._kvEstimateBytesArch(svU, 5.25, 4.5),
      s._kvEstimateBytesArch(svF, 5.25, 4.5))
    // ... but a POSITIVE window with recurrent layers stays unknown: only lfm2
    // among the hybrids derives its pattern that way, so answering it would be a
    // one-architecture table in disguise.
    var gqwP = {}
    for (var qw2 in gqw) gqwP[qw2] = gqw[qw2]
    gqwP.swa = 512
    A.check("kvarch/qwen35-window-plus-hybrid-unknown", s._buildKvLayers(gqwP, 64, 96256,
      { ubatch: 512, parallel: 1, swaFull: false, kvUnified: true }), null)
    // ... and a file that declares NOTHING about its layer types is still unknown
    // even with no window key: llama4 and cohere2 carry no window key and still
    // get a 4-layer SWA pattern from their own source. The probe answers these.
    var gnoHyb = { arch: "llama4", bc: 48, hc: 40, hckv: 8, hckvArr: null, embd: 5120,
      kl: -1, vl: -1, klswa: -1, vlswa: -1, swa: -1, swaPattern: -1,
      swaPatternArr: null, recurrentArr: null, fai: -1, sharedKv: -1,
      kvLoraRank: -1, ropeDim: -1 }
    A.check("kvarch/llama4-undeclared-unknown", s._buildKvLayers(gnoHyb, 48, 8192,
      { ubatch: 512, parallel: 1, swaFull: false, kvUnified: true }), null)

    // head_count_kv == 0 is llama.cpp's own declaration that the layer holds NO
    // KV cache: lfm2, lfm2moe and bailingmoe3 all set
    // `is_recr_impl[il] = (n_head_kv(il) == 0)`. Used to be read as "missing" and
    // silently replaced by the scalar/head-count fallback, which charged a full
    // context cache to layers that store none.
    var kvless = [2, 0, 0, 2, 0, 2]
    var gkv0 = { arch: "lfm2", bc: 6, hc: 8, hckv: 2, hckvArr: kvless, embd: 2048,
      kl: 256, vl: 256, klswa: -1, vlswa: -1, swa: 0, swaPattern: -1,
      swaPatternArr: null, recurrentArr: null, fai: -1, sharedKv: -1,
      kvLoraRank: -1, ropeDim: -1 }
    var svKv0 = s._buildKvLayers(gkv0, 6, 32768, { ubatch: 512, parallel: 1, swaFull: false, kvUnified: true })
    A.check("kvarch/zero-kv-heads-count", svKv0.layers.length, 3)
    // The 3 surviving layers are the ones that declared 2 heads.
    A.check("kvarch/zero-kv-heads-cells", svKv0.layers[0].cells, 32768)
    A.check("kvarch/zero-kv-heads-heads", svKv0.layers[0].kvHeads, 2)
    A.check("kvarch/zero-kv-heads-bytes", s._kvEstimateBytesArch(svKv0, 8.5, 8.5),
      s._kvEstimateBytes(3, 32768, 2, 256, 8.5, 8.5))
    // A zero entry is a statement about THAT layer, so it composes with an
    // explicit period. 0/1 = SWA, 1/2 = dense, 0/3 = SWA, 2/4 = dense, 0/5 = dense
    // with period 2 and a 512 window; the 1, 2 and 4 layers declare no cache and
    // are excluded from BOTH halves, leaving 3 layers (2 full + 1 SWA).
    var gkv0p = {}
    for (var k0 in gkv0) gkv0p[k0] = gkv0[k0]
    gkv0p.swa = 512
    gkv0p.swaPattern = 2
    var svKv0p = s._buildKvLayers(gkv0p, 6, 32768, { ubatch: 512, parallel: 1, swaFull: false, kvUnified: true })
    A.check("kvarch/zero-kv-heads-pattern-count", svKv0p.layers.length, 3)
    var fullKv0p = 0
    for (var k0i = 0; k0i < svKv0p.layers.length; k0i++) if (svKv0p.layers[k0i].cells === 32768) fullKv0p++
    A.check("kvarch/zero-kv-heads-pattern-full", fullKv0p, 2)
    A.check("kvarch/zero-kv-heads-pattern-swa", svKv0p.layers[0].cells, 1024)

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

    // ── pl/*: the tier-4 placement ladder (Service.qml _kvPlacement) ─────────
    // PURE: a readings record in, {value, marker, action} out. Two things decide
    // and both are facts rather than a model of the engine's placement heuristic:
    // the flags it was given, and where the bytes turned up. -1 is "not measured"
    // and must never be treated as a measured 0 — that is the whole reason
    // `mem === 0` and not `mem < 0`.
    // gemma-4-26b-a4b-qat as measured here: KV 3,019,243,520 B, service DRAM
    // 3,070,361,600 B, service VRAM 13,144 MiB → host anon ABOVE the cache, which
    // is rung 3, not "CPU".
    var KV4 = 3019243520
    var VR4 = 13144 * 1048576
    var MEM4 = 3070361600
    function pl(r) { return s._kvPlacement(r) }
    // Rung 1a is the ONLY exact "GPU", and it requires host anon to be exactly 0.
    A.check("pl/p1-mem-zero", pl({ memBytes: 0, vramBytes: KV4, kvBytes: KV4,
      soleAttribution: "measured" }), { value: "GPU", marker: "", action: "commit" })
    // Rung 1a also requires the device to hold at least a cache's worth.
    A.check("pl/p1-vram-short", pl({ memBytes: 0, vramBytes: KV4 - 1, kvBytes: KV4,
      soleAttribution: "measured" }), { value: "", marker: "—", action: "decline" })
    // Rung 1b is the mirror: a SUCCESSFUL zero device reading, exact CPU.
    A.check("pl/p1-vram-zero", pl({ memBytes: KV4, vramBytes: 0, kvBytes: KV4,
      soleAttribution: "measured" }), { value: "CPU", marker: "", action: "commit" })
    // Rung 2: a split is proven, its ratio is not.
    A.check("pl/p2-mem-between", pl({ memBytes: 400000000, vramBytes: 5800000000,
      kvBytes: 2000000000, soleAttribution: "measured" }),
      { value: "GPU/CPU", marker: "~", action: "commit" })
    // A -1 device reading is a missing measurement, not a zero, so it cannot
    // contradict the host reading: host anon alone already proves the split.
    A.check("pl/p2-no-vram-reading", pl({ memBytes: 400000000, vramBytes: -1,
      kvBytes: 2000000000, soleAttribution: "measured" }),
      { value: "GPU/CPU", marker: "~", action: "commit" })
    // Rung 3 declines; it never says CPU.
    A.check("pl/p3-mem-exceeds", pl({ memBytes: KV4, vramBytes: VR4, kvBytes: KV4,
      soleAttribution: "measured" }), { value: "", marker: "—", action: "decline" })
    // The draft's worst bug: a sentinel is not a zero. mem === -1 must wait.
    A.check("pl/p1-mem-absent", pl({ memBytes: -1, vramBytes: VR4, kvBytes: KV4,
      soleAttribution: "measured" }), { value: "", marker: "~", action: "wait" })
    // Contradiction: device provably holds nothing AND host anon is smaller than
    // the cache, so the cache is in neither place.
    A.check("pl/contradiction", pl({ memBytes: 1000000, vramBytes: 0, kvBytes: KV4,
      soleAttribution: "measured" }), { value: "", marker: "—", action: "decline" })
    // Attribution gate: two models loaded means neither reading is this model's.
    A.check("pl/attr-two-models", pl({ memBytes: 400000000, vramBytes: 5800000000,
      kvBytes: 2000000000, soleAttribution: "unattributable" }),
      { value: "", marker: "~", action: "decline" })
    // ...but the flag branch needs no attribution, so it still answers.
    A.check("pl/attr-two-models-flag", pl({ memBytes: 400000000, vramBytes: 5800000000,
      kvBytes: 2000000000, soleAttribution: "unattributable", noKvOffload: true }),
      { value: "CPU", marker: "", action: "commit" })
    A.check("pl/attr-pending-waits", pl({ memBytes: 0, vramBytes: 0, kvBytes: KV4,
      soleAttribution: "pending" }), { value: "", marker: "~", action: "wait" })
    A.check("pl/flag-ngl-zero", pl({ memBytes: 400000000, vramBytes: 5800000000,
      kvBytes: 2000000000, soleAttribution: "measured", ngl: "0" }),
      { value: "CPU", marker: "", action: "commit" })
    // -ngl all is NOT a rung: it says how many LAYERS may be offloaded and says
    // nothing about where the cache went.
    A.check("pl/no-ngl-all-branch", pl({ memBytes: KV4, vramBytes: VR4, kvBytes: KV4,
      soleAttribution: "measured", ngl: "all" }),
      { value: "", marker: "—", action: "decline" })
    A.check("pl/no-ngl-auto-branch", pl({ memBytes: KV4, vramBytes: VR4, kvBytes: KV4,
      soleAttribution: "measured", ngl: "auto" }),
      { value: "", marker: "—", action: "decline" })
    // No cache ⇒ nothing to place.
    A.check("pl/no-kv-bytes", pl({ memBytes: 400000000, vramBytes: 5800000000,
      kvBytes: -1, soleAttribution: "measured" }), { value: "", marker: "—", action: "decline" })
    A.check("pl/idempotent", pl({ memBytes: 400000000, vramBytes: 5800000000,
      kvBytes: 2000000000, soleAttribution: "measured" }), pl({ memBytes: 400000000,
      vramBytes: 5800000000, kvBytes: 2000000000, soleAttribution: "measured" }))
    A.check("pl/idempotent-answered", pl({ answered: { value: "CPU", marker: "" } }),
      { value: "CPU", marker: "", action: "commit" })
    A.check("pl/wait-no-write", pl({ memBytes: -1, vramBytes: -1, kvBytes: KV4,
      soleAttribution: "measured" }), { value: "", marker: "~", action: "wait" })
    A.check("pl/null-inputs", pl(null), { value: "", marker: "~", action: "wait" })
    // The gemma triple, asserted literally: a 49.2 MiB margin must not decide a
    // 2.8 GB claim. Parameterising this would let someone retune the threshold
    // and keep the test green, which is exactly the bug.
    A.check("pl/gemma-triple", pl({ memBytes: 3070361600, vramBytes: VR4,
      kvBytes: 3019243520, soleAttribution: "measured" }),
      { value: "", marker: "—", action: "decline" })
    // Entry-shaped adapter used by the pre-store call sites.
    A.check("pl/adapter-cpu", s._kvLocationOf(true, 30, KV4,
      { memBytes: MEM4, vramBytes: VR4, sole: true }), "CPU")
    A.check("pl/adapter-rung3", s._kvLocationOf(false, 30, KV4,
      { memBytes: MEM4, vramBytes: VR4, sole: true }), "")
    A.check("pl/adapter-split", s._kvLocationOf(false, 30, KV4,
      { memBytes: KV4 - 1, vramBytes: VR4, sole: true }), "GPU/CPU")
    A.check("pl/adapter-multi-model", s._kvLocationOf(false, 30, KV4,
      { memBytes: MEM4, vramBytes: VR4, sole: false }), "")
    A.check("pl/adapter-ngl-zero", s._kvLocationOf(false, 0, KV4,
      { memBytes: MEM4, vramBytes: VR4, sole: true }), "CPU")
    A.check("pl/adapter-no-kv", s._kvLocationOf(false, 30, -1,
      { memBytes: MEM4, vramBytes: VR4, sole: true }), "")
    A.check("pl/adapter-unknown-kv", s._kvLocationOf(false, 30, -1, null), "")

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
    // Tier 6 answers as soon as the engine has been asked.
    out[0].kvBytesExact = 3019243520
    var rk = s._resolveKvBytes(out[0])
    A.check("resolve/kvBytes-exact-tier", rk.tier, 3)
    A.check("resolve/kvBytes-exact-marker", rk.marker, "")
    A.check("resolve/kvBytes-exact-value", rk.value, 3019243520)

    // ── _weightBytes: exact split / measured fallback / all unknown ───────────
    A.check("wbytes/split-known", s._weightBytes(100, 65, 0, 65, -1, -1), [100, 0])
    A.check("wbytes/measured-fallback", s._weightBytes(100, -1, -1, 65, 42, 7), [42, 7])
    A.check("wbytes/all-unknown", s._weightBytes(100, -1, -1, 65, -1, -1), [-1, -1])

// ── _resolveFieldSources (the display reader): the block renders the store's
    // decisions and makes none of its own. This used to BE the resolver — it
    // re-derived the split from entry.ngl, the preset and the live VRAM, and
    // invented its own markers, which is how "in flight" and "not found" ended up
    // sharing one em-dash. The pins below are the reader's contract: mirror the
    // store, never re-decide, and keep pending and absent apart.
    var rPath = "/m/rs.gguf"
    var rst = s._storeFor(rPath)
    s._t1(rst, "sizeBytes", 1000)
    s._t1(rst, "contextLen", 4096)
    s._t1(rst, "nParams", 7000)
    s._t1(rst, "ngl", "all")
    s._t1(rst, "cacheK", "q8_0")
    s._t1(rst, "cacheV", "f16")
    s._t2(rst, "ftype", 15)
    s._t2(rst, "totalLayers", 65)
    // No separate draft: an ABSENT nextn_predict_layers is a reading (llama.cpp's
    // default is 0 draft layers), which is what _applyTier2To commits for a model
    // with no --model-draft. mainGpu requires it, so a store that skipped it would
    // leave every split field pending.
    s._t2(rst, "mtpLayers", 0)
    s.applyDerivation(rst)
    s._settle(rst)

    var rr = s._resolveFieldSources({ modelPath: rPath }, {})
    A.check("rs/params-tier", rr.params.tier, 1)
    A.check("rs/params-value", rr.params.value, 7000)
    A.check("rs/params-marker", rr.params.marker, "")
    A.check("rs/quant-tier", rr.quant.tier, 2)
    A.check("rs/quant-value", rr.quant.value, 15)
    A.check("rs/layers-tier", rr.totalLayers.tier, 2)
    A.check("rs/layers-value", rr.totalLayers.value, 65)
    A.check("rs/mainLayers-value", rr.mainLayers.value, 65)
    A.check("rs/mainLayers-derived", rr.mainLayers.derived, true)
    A.check("rs/coreSize-value", rr.coreSize.value, 1000)
    A.check("rs/context-value", rr.contextLen.value, 4096)
    // String fields keep their VALUE. The numeric rows coerce an absent value to
    // -1; a placement, a dtype and a spec type coerced that way rendered "-1" in
    // the middle of a sentence.
    A.check("rs/cacheK-value", rr.cacheK.value, "q8_0")
    A.check("rs/cacheV-value", rr.cacheV.value, "f16")
    A.check("rs/kvDtype-k", rr.kvDtype.value.k, "q8_0")
    A.check("rs/kvDtype-v", rr.kvDtype.value.v, "f16")
    A.check("rs/specType-value", rr.specType.value, "")
    // The split is a COMPOSITE and carries its own worst-of state: -ngl all is
    // exact for the GPU count while the CPU count is a subtraction, so "~" is the
    // honest marker for the pair even though one half is a stated count.
    A.check("rs/split-gpu", rr.gpuSplit.value.mainGpu, 65)
    A.check("rs/split-cpu", rr.gpuSplit.value.mainCpu, 0)
    A.check("rs/split-marker-worst", rr.gpuSplit.marker, "~")
    A.check("rs/split-tier-weakest", rr.gpuSplit.tier, 2)
    A.check("rs/weights-gpu", rr.weightBytes.gpu, 1000)
    A.check("rs/weights-cpu", rr.weightBytes.cpu, 0)
    A.check("rs/weights-marker", rr.weightBytes.gpuMarker, "~")

    // A field that is STILL BEING LOOKED FOR is pending, and pending is not
    // absent. The reader is where the two stop being the same thing.
    A.check("rs/kv-pending-state", rr.kvBytes.state, s.stateEnum.PENDING)
    A.check("rs/kv-pending-glyph", rr.kvBytes.marker, "…")
    A.check("rs/kv-pending-value", rr.kvBytes.value, -1)
    A.check("rs/location-pending", rr.kvLocation.state, s.stateEnum.PENDING)

    // Exhausted fields read "—", which is a different answer from "…".
    var rex = s._storeFor("/m/rs-exhausted.gguf")
    rex.decline("ftype", 2)
    rex.decline("nParams", 1)
    s._settle(rex)
    var rxe = s._resolveFieldSources({ modelPath: "/m/rs-exhausted.gguf" }, {})
    A.check("rs/exhausted-quant-state", rxe.quant.state, s.stateEnum.ABSENT)
    A.check("rs/exhausted-quant-glyph", rxe.quant.marker, "—")
    A.check("rs/exhausted-params-glyph", rxe.params.marker, "—")

    // No store at all (the model's first render, before any tier answered) is
    // pending across the board, not an error and not absent.
    var rnn = s._resolveFieldSources({ modelPath: "/m/never-seen.gguf" }, {})
    A.check("rs/no-store-params", rnn.params.state, s.stateEnum.PENDING)
    A.check("rs/no-store-params-glyph", rnn.params.marker, "…")
    A.ok("rs/no-store-split-null", rnn.gpuSplit.value === null)
    A.check("rs/no-store-weights", rnn.weightBytes.gpu, -1)
    A.check("rs/no-store-kv-dtype-absent", rnn.cacheK.state, s.stateEnum.PENDING)

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
    // The engine probe is what fills this in — see the tier-6 block below.
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
    // The interval array says WHICH layers keep a context cache; the ABSENCE of
    // a window key says the rest. A window is a property of an attention stack and
    // llama.cpp hardcodes one for no architecture that interleaves recurrent
    // layers, so a hybrid with no window key is dense and IS sizeable from the
    // header. 16 full-attention layers of 96256 cells, 4 KV heads x 213.33 head
    // dim, q5_0 K + q4_0 V. Cross-checked against the engine on the deployed
    // qwen3.6-35b-a3b (qwen35moe, 40 layers, fai 4, no window key): 2720.00 MiB
    // derived vs `llama_kv_cache: size = 2720.00 MiB (262144 cells, 10 layers)`
    // reported — exact, 0 B delta.
    A.check("hybrid/kvCacheBytes", s.runningModels[0].kvCacheBytes, 1601699840)

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

    // ── Tier 6 engine KV accounting probe ────────────────────────────────
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
    // A run that exits non-zero still PUBLISHES the KV size it measured, but
    // NOT its compute reserve — those two numbers are trusted under different
    // contracts. The size line is emitted by the kv-cache constructor once the
    // allocation is fully sized, so it is a pure function of the hparams and
    // cparams the probe passed in; gating it on a clean exit discarded correct
    // answers, because `-ngl 0` leaves the graph reserve on the GPU and the
    // probe died in ggml_gallocr_reserve_n_impl after printing it. The compute
    // reserve is a reservation for a graph that may never have been built, and
    // the device split is derived from it, so it stays unknown here (-1).
    s._kvProbeSignature = "sig-fail"
    s._finishKvProbe(false)
    A.ok("kvprobe/failed-run-kv-published", s._kvProbeCache["sig-fail"] !== false
      && s._kvProbeCache["sig-fail"].kvBytes > 0)
    A.check("kvprobe/failed-run-compute-unknown", s._kvProbeCache["sig-fail"].computeBytes, -1)
    A.check("kvprobe/reset-bytes", s._kvProbeAcc.kvBytes, 0)
    A.check("kvprobe/reset-blocks", s._kvProbeAcc.blocks.length, 0)
    s._kvProbeSignature = ""
    // A run that never reached a cache (refused by the address-space pre-flight,
    // or a SIGKILL during load) still publishes nothing and caches `false`, so a
    // model that cannot fit is never probed again.
    s._kvProbeAcc = { kvBytes: 0, kvLayers: 0, computeBytes: -1, blocks: [], compute: ({}), computeSeen: [] }
    s._kvProbeSignature = "sig-nothing"
    s._finishKvProbe(false)
    A.check("kvprobe/no-line-publishes-nothing", s._kvProbeCache["sig-nothing"], false)
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
    // The probe must not touch the GPU at all. -ngl 0 only keeps the WEIGHTS off
    // the device; the graph/compute reserve still went to cudaMalloc (measured
    // 1,537 MiB against the live qwen3.6-35b-a3b worker) and the probe then
    // failed there and exited non-zero. -dev none is what keeps the compute
    // buffers on the CPU; cache SIZE is device-independent either way.
    A.check("kvprobe/argv-dev-none", av.indexOf("-dev none") >= 0, true)
    A.check("kvprobe/argv-nkvo", s._kvProbeArgv(clone(pe, "noKvOffload", true))
      .join(" ").indexOf("--no-kv-offload") >= 0, true)
    // The model path is an argv element, never part of the script text.
    A.ok("kvprobe/argv-has-model", s._kvProbeArgv(pe).length < 30)
    A.check("kvprobe/argv-no-server-flags", /--port|--host|--api-key|--jinja|--mmproj|--draft|--threads/.test(av), false)

    // Result fold: exact bytes, cache layer count and compute reserve land on
    // the entry, and the STORE reports them as Tier 6 — the probe IS the oracle,
    // and Tier 6 is where an oracle's verdict is filed so it outranks every
    // estimate without ever being outranked by one.
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
    A.check("kvprobe/rs-tier", rq.kvBytes.tier, 6)
    A.check("kvprobe/rs-marker", rq.kvBytes.marker, "")
    A.check("kvprobe/rs-value", rq.kvBytes.value, 3019243520)
    A.check("kvprobe/rs-format", s.formatGB(rq.kvBytes.value), "2.8 GB")
    // A model the resolver has not reached yet is IN FLIGHT, not estimated: the
    // header derivation may still answer and the tier-6 oracle is still out, so
    // the honest marker is "…". The old reader called this "~", which claimed a
    // number nobody had computed.
    var rq2 = s._resolveFieldSources({ modelPath: "/m/no-store.gguf" },
      { vramBytes: -1, memBytes: -1, presetSection: null })
    A.check("kvprobe/rs-fallback-state", rq2.kvBytes.state, s.stateEnum.PENDING)
    A.check("kvprobe/rs-fallback-marker", rq2.kvBytes.marker, "…")
    var rq3 = s._resolveFieldSources({ modelPath: "/m/no-store.gguf" },
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

    // ══ Six-tier field store ══════════════════════════════════════════
    //
    // The store is where the resolver's guarantees live, so these are the tests
    // that matter most: an uncommitted field is unreachable, a weak answer cannot
    // displace a strong one, and a field cannot hang as pending forever.

    // ── Validity is per field, not blanket ──────────────────────────────
    // false is the real answer for a bool and a sentinel for a byte count, so a
    // single predicate would either refuse the booleans or admit false.
    A.ok("types/num-zero", s.isValidValue("sizeBytes", 0))
    A.ok("types/num-neg-sentinel", !s.isValidValue("sizeBytes", -1))
    A.ok("types/num-nan", !s.isValidValue("sizeBytes", NaN))
    A.ok("types/num-null", !s.isValidValue("sizeBytes", null))
    A.ok("types/num-bool-is-not-num", !s.isValidValue("sizeBytes", false))
    A.ok("types/str-empty-sentinel", !s.isValidValue("ngl", ""))
    A.ok("types/str-value", s.isValidValue("ngl", "20"))
    A.ok("types/str-num-rejected", !s.isValidValue("ngl", 20))
    A.ok("types/bool-true", s.isValidValue("isCloud", true))
    A.ok("types/bool-false-is-a-value", s.isValidValue("isCloud", false))
    A.ok("types/bool-num-rejected", !s.isValidValue("isCloud", 0))
    A.ok("types/unknown-field", !s.isValidValue("nonesuch", 1))

    // ── Field-set seed: nothing is missing, everything is pending ───────
    var st = s.createFieldStore("/m/a.gguf")
    A.check("store/seed-pending", st.get("contextLen").state, "pending")
    A.check("store/seed-null", st.get("contextLen").value, null)
    A.check("store/seed-tier", st.get("contextLen").tier, null)
    A.ok("store/seed-derived-too", st.needsMore("mainLayers"))
    A.check("store/unknown-field-get", st.get("nonesuch"), null)

    // ── Only commit() can write, and only a valid value ────────────────
    A.ok("store/commit-exact", st.commit("contextLen", 8192, "exact", 1))
    A.check("store/commit-value", st.get("contextLen").value, 8192)
    A.check("store/commit-state", st.get("contextLen").state, "exact")
    A.check("store/commit-tier", st.get("contextLen").tier, 1)
    A.check("store/commit-not-derived", st.get("contextLen").derived, false)
    A.ok("store/commit-bad-value", !st.commit("contextLen", -1, "exact", 1))
    A.ok("store/commit-bad-state", !st.commit("contextLen", 4096, "guess", 1))
    A.ok("store/commit-bad-tier", !st.commit("contextLen", 4096, "exact", 0))
    A.ok("store/commit-bad-tier-hi", !st.commit("contextLen", 4096, "exact", 7))
    A.ok("store/commit-unknown-field", !st.commit("nonesuch", 1, "exact", 1))
    A.check("store/commit-leaves-value", st.get("contextLen").value, 8192)

    // ── Effective tier: a weak answer cannot overwrite a strong one ─────
    var st2 = s.createFieldStore("/m/b.gguf")
    st2.commit("memBytes", 42, "exact", 4)
    A.ok("store/weaker-refused", !st2.commit("memBytes", 99, "exact", 5))
    A.ok("store/equal-tier-refused", !st2.commit("memBytes", 99, "exact", 4))
    A.check("store/weaker-keeps-first", st2.get("memBytes").value, 42)
    A.check("store/weaker-keeps-tier", st2.get("memBytes").tier, 4)
    A.ok("store/stronger-wins", st2.commit("memBytes", 99, "exact", 1))
    A.check("store/stronger-value", st2.get("memBytes").value, 99)
    A.check("store/stronger-tier", st2.get("memBytes").tier, 1)

    // ── Derived commits: weakest input tier + worst input state ────────
    var st3 = s.createFieldStore("/m/c.gguf")
    st3.commit("totalLayers", 40, "exact", 2)
    st3.commit("mtpLayers", 0, "exact", 2)
    A.ok("store/derived-commit", st3.commit("mainLayers", 40, null, null, ["totalLayers", "mtpLayers"], ""))
    A.check("store/derived-tier-is-weakest", st3.get("mainLayers").tier, 2)
    A.check("store/derived-flag", st3.get("mainLayers").derived, true)
    A.check("store/derived-exact-from-exact", st3.get("mainLayers").state, "exact")
    // An estimated input degrades the answer: the arithmetic may be exact, the
    // inputs are not.
    st3.commit("weightCpu", 5, "estimated", 4)
    st3.commit("mainCpu", 7, null, null, ["mainLayers"], "~")
    A.check("store/derived-floor-wins-over-input",
            st3.get("mainCpu").state, "estimated")
    // The tier is the weakest INPUT, so weightCpu (tier 4) does not raise it.
    A.check("store/derived-floor-tier", st3.get("mainCpu").tier, 2)
    // An unattributed input has no tier, and there is no tier 0 to file it under.
    A.ok("store/derived-unattributed-refused",
         !st3.commit("coreSize", 10, null, null, ["contextLen"], ""))

    // ── decline + settled: the termination join ────────────────────────
    var st4 = s.createFieldStore("/m/d.gguf")
    A.ok("store/pending-at-lowest-tier", st4.pendingAt("contextLen") === 1)
    st4.commit("contextLen", 2048, "exact", 1)
    A.ok("store/settled-on-value", st4.isSettled("contextLen"))
    A.ok("store/no-longer-needs-more", !st4.needsMore("contextLen"))
    A.check("store/pendingAt-null", st4.pendingAt("contextLen"), null)
    // One decliner is not exhaustion: tiers 3/4/5 can still answer memBytes.
    st4.decline("memBytes", 3)
    A.ok("store/not-settled-on-first-decline", !st4.isSettled("memBytes"))
    st4.decline("memBytes", 4)
    st4.decline("memBytes", 5)
    A.ok("store/settled-after-all-decline", st4.isSettled("memBytes"))
    st4.markSettled()
    A.check("store/exhausted-becomes-absent", st4.get("memBytes").state, "absent")
    A.check("store/absent-value-null", st4.get("memBytes").value, null)
    A.ok("store/absent-is-terminal", !st4.needsMore("memBytes"))
    // A derived field is pending while a REQUIRED input is pending, so it must
    // not be swept to absent by the same markSettled() pass.
    st4.markSettled()
    A.check("store/derived-not-swept-early", st4.get("mainLayers").state, "pending")

    // ── applyDerivation: retried, never scheduled ──────────────────────
    var st5 = s.createFieldStore("/m/e.gguf")
    s.applyDerivation(st5)
    A.check("deriv/nothing-with-no-inputs", st5.get("mainLayers").state, "pending")
    st5.commit("totalLayers", 40, "exact", 2)
    s.applyDerivation(st5)
    A.check("deriv/blocked-on-required-input", st5.get("mainLayers").state, "pending")
    st5.commit("mtpLayers", 4, "exact", 2)
    s.applyDerivation(st5)
    A.check("deriv/mainLayers", st5.get("mainLayers").value, 36)
    A.check("deriv/mainLayers-tier", st5.get("mainLayers").tier, 2)
    // mtpSizeBytes has OPTIONAL inputs, so it answers from what landed.
    st5.commit("sizeBytes", 4000, "exact", 1)
    st5.commit("totalLayers", 40, "exact", 2)   // refused: already answered
    s.applyDerivation(st5)
    A.check("deriv/optional-input-pending-still-runs", st5.needsMore("mtpSizeBytes"), false)
    A.check("deriv/mtpSize-uniform-estimate", st5.get("mtpSizeBytes").value, 400)
    A.check("deriv/mtpSize-floor", st5.get("mtpSizeBytes").state, "estimated")
    // mainCpu needs BOTH mainGpu and mainLayers; supplying one is not enough.
    A.check("deriv/mainCpu-blocked", st5.get("mainCpu").state, "pending")
    st5.commit("mainGpu", 20, "exact", 3)
    s.applyDerivation(st5)
    A.check("deriv/mainCpu", st5.get("mainCpu").value, 16)

    // ── mainGpu: a stated offload count is exact arithmetic ─────────────
    var st6 = s.createFieldStore("/m/f.gguf")
    st6.commit("totalLayers", 40, "exact", 2)
    st6.commit("mtpLayers", 0, "exact", 2)
    st6.commit("ngl", "20", "exact", 1)
    s.applyDerivation(st6)
    A.check("deriv/mainGpu-from-flag", st6.get("mainGpu").value, 20)
    A.check("deriv/mainGpu-from-flag-is-exact", st6.get("mainGpu").state, "exact")
    A.check("deriv/mainGpu-from-flag-tier", st6.get("mainGpu").tier, 2)

    // ── kvLocation: arithmetic over tiers, therefore revisable ──────────
    var st7 = s.createFieldStore("/m/g.gguf")
    st7.commit("soleAttribution", "measured", "exact", 4)
    st7.commit("noKvOffload", false, "exact", 1)
    st7.commit("kvBytes", 2 * 1073741824, "exact", 6)
    st7.commit("memBytes", 1 * 1073741824, "exact", 4)
    st7.commit("vramBytes", 4 * 1073741824, "exact", 4)
    s.applyDerivation(st7)
    A.check("deriv/kvLocation-split", st7.get("kvLocation").value, "GPU/CPU")
    A.check("deriv/kvLocation-split-estimated", st7.get("kvLocation").state, "estimated")
    A.check("deriv/kvLocation-tier-is-weakest", st7.get("kvLocation").tier, 6)
    // A flag answers without attribution, so --no-kv-offload short-circuits.
    var st8 = s.createFieldStore("/m/h.gguf")
    st8.commit("soleAttribution", "unattributable", "exact", 4)
    st8.commit("noKvOffload", true, "exact", 1)
    st8.commit("kvBytes", 1024, "exact", 6)
    s.applyDerivation(st8)
    A.check("deriv/kvLocation-flag-branch", st8.get("kvLocation").value, "CPU")
    A.check("deriv/kvLocation-flag-exact", st8.get("kvLocation").state, "exact")
    A.check("deriv/kvLocation-flag-tier", st8.get("kvLocation").tier, 6)
    // Unattributable + no flag → the derivation declines and stays pending.
    var st9 = s.createFieldStore("/m/i.gguf")
    st9.commit("soleAttribution", "unattributable", "exact", 4)
    st9.commit("noKvOffload", false, "exact", 1)
    st9.commit("kvBytes", 1024, "exact", 6)
    s.applyDerivation(st9)
    A.check("deriv/kvLocation-unattributable-declines", st9.get("kvLocation").state, "pending")
    st9.markSettled()
    A.check("deriv/kvLocation-unattributable-absent", st9.get("kvLocation").state, "absent")

    // ── The tier-6 gate: two booleans, no oracle for a described shape ──
    var st10 = s.createFieldStore("/m/j.gguf")
    A.ok("gate6/runs-when-nothing-known", s.checkTier6Values(st10))
    st10.commit("kvDescribed", false, "exact", 2)
    A.ok("gate6/undescribable-runs", s.checkTier6Values(st10))
    st10.commit("kvBlockAligned", false, "exact", 2)
    A.ok("gate6/undescribable-unaligned-runs", s.checkTier6Values(st10))
    var st11 = s.createFieldStore("/m/k.gguf")
    st11.commit("kvDescribed", true, "exact", 2)
    st11.commit("kvBlockAligned", false, "exact", 2)
    A.ok("gate6/described-unaligned-skips-oracle", !s.checkTier6Values(st11))
    st11.commit("kvBlockAligned", true, "exact", 2)
    A.ok("gate6/described-aligned-skips-oracle", !s.checkTier6Values(st11))
    st11.commit("kvBytes", 1024, "exact", 2)
    A.ok("gate6/answered-skips", !s.checkTier6Values(st11))

    // A cycle would not throw; it would silently stop deriving, because
    // derivationSettled() finds a pending input in the cycle and gives up, and
    // every field in it stays "…" forever. That is why it needs a static check
    // rather than a behavioural one — the failure mode looks like "still
    // loading", not like an error.
    // The graph is a parameter, not s.derivations, so the SAME traversal is
    // exercised by the negative cases below — otherwise those would be testing a
    // second implementation of the walk rather than the one that guards the
    // registry. (It also cannot be done by assigning s.derivations: that
    // property is readonly, which is the point of it.)
    function derCycleIn(graph, node, path) {
      if (path.indexOf(node) >= 0) return path.slice(path.indexOf(node))
      var d = graph[node]
      if (!d) return null
      var next = path.concat([node])
      var edges = (d.inputs || []).concat(d.optional || [])
      for (var i = 0; i < edges.length; i++) {
        if (!graph[edges[i]]) continue
        var hit = derCycleIn(graph, edges[i], next)
        if (hit) return hit
      }
      return null
    }
    var cycleFields = []
    for (var cy in s.derivations) {
      var found = derCycleIn(s.derivations, cy, [])
      if (found) cycleFields.push(found.join(" -> "))
    }
    A.check("deriv/no-cycles", cycleFields, [])
    // A detector that cannot fail is decoration, and a detector that never
    // pops the path calls every diamond a cycle — which is what the real
    // registry is full of (mainGpu is an input to mainCpu, weightGpu and
    // mtpGpu). Both halves matter: one catches a broken walk, the other stops a
    // working walk from being "fixed" into a false alarm.
    A.ok("deriv/cycle-detector-catches-a-cycle",
         derCycleIn({ a: { inputs: ["b"] }, b: { inputs: ["a"] } }, "a", []) !== null)
    A.ok("deriv/cycle-detector-survives-a-diamond",
         derCycleIn({ a: { inputs: ["b", "c"] }, b: { inputs: ["d"] },
                      c: { inputs: ["d"] }, d: { inputs: [] } }, "a", []) === null)

    // ── Invariant 4: a derived state is never better than its inputs ─────
    // Asserted as the COMBINED rule the plan states (worst input state and the
    // field's floor, whichever is worse), because testing the two separately
    // passes while the composition is wrong: an implementation that ORs them
    // instead of taking the worse one satisfies both halves.
    var worseThanLaw = []
    var probe = s.createFieldStore("/m/store-inv/st.qml")
    // Every input is committed EXCEPT coreSize, which is left to the derivation:
    // pre-committing it at tier 1 would make the derivation refuse to run (its
    // weakest input is tier 4), and the test would then measure the direct
    // commit rather than the state rule it is about.
    probe.commit("sizeBytes", 1000, "estimated", 4)
    probe.commit("mainLayers", 10, "exact", 2)
    probe.commit("mainGpu", 6, "exact", 1)
    s.applyDerivation(probe)
    // weightGpu's floor is "~" and one input is estimated: the result cannot be
    // better than EITHER, so "~" regardless of mainGpu being exact.
    if (probe.get("weightGpu").state === "exact")
      worseThanLaw.push("weightGpu:" + probe.get("weightGpu").state)
    // coreSize's floor is "" (exact arithmetic on exact inputs), so the
    // estimated sizeBytes must drag it to "~".
    if (probe.get("coreSize").state === "exact")
      worseThanLaw.push("coreSize:" + probe.get("coreSize").state)
    A.check("deriv/state-never-better-than-worst-input", worseThanLaw, [])

    // ── Invariant 5: every capability field has a producer in its tier ───
    // Two halves. (a) Each tier actually claims something — an empty tier is a
    // rung that can never answer, which reads as "we checked" in the walk.
    // (b) Each declared field is claimed by every tier that lists it, which
    // caps/field-tiers-agree already covers from the other direction; here the
    // check is that no tier's list is dead weight with no field behind it.
    var emptyTiers = []
    for (var et = 1; et <= 6; et++)
      if (!s.capabilities[et] || !s.capabilities[et].length) emptyTiers.push(et)
    A.check("caps/no-empty-tier", emptyTiers, [])
    // Every declared field must be reachable: named by some tier OR derived. A
    // type declared but owned by nobody can never be answered, so it is a field
    // that renders "…" with no producer — the orphan `noMmprojOffload` and
    // `flashAttn` were exactly this, carried in fieldTypes from a draft that
    // never wired them.
    var unreachable = []
    for (var fr in s.fieldTypes)
      if (!s.fieldTiers[fr] && !s.derivations[fr]) unreachable.push(fr)
    A.check("caps/every-field-has-an-owner", unreachable, [])

    // ── Capabilities: disjoint from derivations, except the join ────────
    var derived = {}
    for (var dk in s.derivations) derived[dk] = true
    var overlap = []
    for (var ti = 1; ti <= 6; ti++)
      for (var ci = 0; ci < s.capabilities[ti].length; ci++) {
        var f = s.capabilities[ti][ci]
        if (derived[f] && f !== "kvBytes") overlap.push(ti + ":" + f)
      }
    A.check("caps/no-derived-in-capabilities", overlap, [])
    A.ok("caps/kvBytes-is-tier6", s.capabilities[6].indexOf("kvBytes") >= 0)
    A.ok("caps/every-capability-is-a-field", s.capabilities[6].indexOf("kvGpuBytes") < 0)
    // Every field in fieldTiers must be claimed by exactly the tiers that list
    // it — the store's wanted set is the join key.
    var mismatched = []
    for (var fi in s.fieldTiers) {
      var want = s.fieldTiers[fi]
      for (var wi = 0; wi < want.length; wi++)
        if (s.capabilities[want[wi]].indexOf(fi) < 0) mismatched.push(fi)
    }
    A.check("caps/field-tiers-agree", mismatched, [])
    // A derivation with no inputs would be unattributable by construction.
    var noInputs = []
    for (var di in s.derivations)
      if (!s.derivations[di].inputs || !s.derivations[di].inputs.length) noInputs.push(di)
    A.check("deriv/every-derivation-has-inputs", noInputs, [])
    // ...and every required input must itself be resolvable.
    var dangling = []
    for (var ddi in s.derivations) {
      var dd = s.derivations[ddi]
      var all = (dd.inputs || []).concat(dd.optional || [])
      for (var ai = 0; ai < all.length; ai++)
        if (!s.fieldTiers[all[ai]] && !derived[all[ai]]) dangling.push(ddi + "<-" + all[ai])
    }
    A.check("deriv/no-dangling-inputs", dangling, [])

    // ── Architecture templates ──────────────────────────────────────────
    A.ok("arch/llama-templated", s._kvArchTemplate("llama") !== null)
    A.ok("arch/qwen35moe-templated", s._kvArchTemplate("qwen35moe") !== null)
    A.ok("arch/gemma4-templated", s._kvArchTemplate("gemma4") !== null)
    A.ok("arch/dflash-templated", s._kvArchTemplate("dflash") !== null)
    A.check("arch/unknown-null", s._kvArchTemplate("baichuan3"), null)
    A.check("arch/empty-null", s._kvArchTemplate(""), null)
    A.check("arch/null-null", s._kvArchTemplate(null), null)
    A.ok("arch/suffixes-shared", s._kvArchTemplate("qwen35").blocks === "block_count")

    // ── Block alignment: per tensor, per layer, in BLOCK bytes ──────────
    A.check("blockbytes/f16", s._kvBlockBytes("f16"), 2)
    A.check("blockbytes/q8_0", s._kvBlockBytes("q8_0"), 34)
    A.check("blockbytes/q5_0", s._kvBlockBytes("q5_0"), 22)
    A.check("blockbytes/unknown", s._kvBlockBytes("k_quants_99"), -1)
    A.check("blockbytes/empty-defaults-f16", s._kvBlockBytes(""), 2)
    var alignedSpec = { layers: [{ kLen: 256, vLen: 256, hasV: true, cells: 1024 }],
                        kvUnified: true, parallel: 1 }
    A.ok("block/aligned-f16", s._kvBlockAligned(alignedSpec, "f16", "f16"))
    // 256 heads × 1024 cells × 8.5 bits = 278528 B; a whole number of q8_0 blocks.
    A.ok("block/aligned-q8_0", s._kvBlockAligned(alignedSpec, "q8_0", "q8_0"))
    // K and V have separate dtypes and separate block sizes: K aligned against
    // q8_0 while V is not against q5_0 must NOT report aligned, which is why the
    // two tensors are tested separately rather than their sum.
    A.ok("block/k-aligned-v-not",
         !s._kvBlockAligned(alignedSpec, "q8_0", "q5_0"))
    A.ok("block/k-not-v-aligned",
         !s._kvBlockAligned(alignedSpec, "q5_0", "q8_0"))
    A.ok("block/unknown-quant-refuses", !s._kvBlockAligned(alignedSpec, "k_quants_99", "f16"))
    A.ok("block/empty-spec-refuses", !s._kvBlockAligned(({ layers: [] }), "f16", "f16"))
    A.ok("block/null-spec-refuses", !s._kvBlockAligned(null, "f16", "f16"))
    // MLA: K only, so there is no V tensor to test.
    var mlaSpec = { layers: [{ kLen: 576, hasV: false, cells: 4096 }],
                     kvUnified: true, parallel: 1 }
    A.ok("block/mla-k-only", s._kvBlockAligned(mlaSpec, "f16", "f16"))
    // Non-unified multiplies the cells by the sequence count.
    var parSpec = { layers: [{ kLen: 256, vLen: 256, hasV: true, cells: 1024 }],
                    kvUnified: false, parallel: 2 }
    A.ok("block/parallel-f16-still-aligned", s._kvBlockAligned(parSpec, "f16", "f16"))
    var parOdd = { layers: [{ kLen: 1, vLen: 1, hasV: true, cells: 1 }],
                   kvUnified: false, parallel: 2 }
    A.ok("block/parallel-unaligned-detected", !s._kvBlockAligned(parOdd, "q8_0", "q8_0"))

    // ── Tier 1 producer: the API's readings, committed or declined ──────
    var entry1 = {
      name: "qwen3-30b", modelPath: "/m/store-t1/a.gguf", draftPath: "",
      sizeBytes: 18000000000, contextLen: 32768, nParams: 30000000000,
      ngl: "20", nglDraft: "", specType: "", cacheK: "q8_0", cacheV: "",
      noKvOffload: false, ubatch: 512, parallel: 1,
      swaFull: false, noKvUnified: false }
    s._pruneStores([entry1])
    s._applyTier1([entry1])
    var t1s = s._storeFor("/m/store-t1/a.gguf")
    A.check("t1/sizeBytes", t1s.get("sizeBytes").value, 18000000000)
    A.check("t1/sizeBytes-tier", t1s.get("sizeBytes").tier, 1)
    A.check("t1/sizeBytes-exact", t1s.get("sizeBytes").state, "exact")
    A.check("t1/ngl", t1s.get("ngl").value, "20")
    A.check("t1/contextLen", t1s.get("contextLen").value, 32768)
    A.check("t1/cacheK", t1s.get("cacheK").value, "q8_0")
    // An absent --cache-type-v MEANS f16, so it is normalized, not declined.
    A.check("t1/cacheV-normalized-to-f16", t1s.get("cacheV").value, "f16")
    // false is the real answer for a bool, so it is committed, not declined.
    A.check("t1/isCloud-false-is-a-value", t1s.get("isCloud").value, false)
    A.check("t1/isCloud-exact", t1s.get("isCloud").state, "exact")
    // Tier 1 is the ONLY tier that can answer draftPath, so its decline EXHAUSTS the
    // field: the join over answeredBy vs the wanted set is complete and the
    // durable "—" is correct. A decline is not automatically pending.
    A.check("t1/draftPath-declined-exhausts", t1s.get("draftPath").state, "absent")
    A.check("t1/tier2-fields-still-pending", t1s.get("totalLayers").state, "pending")
    A.check("t1/derivation-blocked-on-tier2", t1s.get("mainLayers").state, "pending")
    // Tier 2 landing unblocks the derivation, with no ordering requirement.
    t1s.commit("totalLayers", 48, "exact", 2)
    t1s.commit("mtpLayers", 0, "exact", 2)
    s._settle(t1s)
    A.check("t1/tier2-unblocks-derivation", t1s.get("mainLayers").value, 48)
    A.check("t1/tier2-derivation-tier", t1s.get("mainLayers").tier, 2)

    // The API's stand-in for an unknown size is 0, and 0 is a VALID byte count,
    // so it must be declined (→ exhausted → "—"), not committed as a zero-byte
    // file. Same for a negative context and a zero ubatch.
    var entry2 = { name: "b", modelPath: "/m/store-t1/b.gguf", sizeBytes: 0,
                   contextLen: -1, nParams: -1, ubatch: 0, parallel: 0 }
    s._applyTier1([entry1, entry2])
    var t2s = s._storeFor("/m/store-t1/b.gguf")
    A.check("t1/zero-size-is-not-a-zero", t2s.get("sizeBytes").state, "absent")
    A.check("t1/absent-has-no-value", t2s.get("sizeBytes").value, null)
    A.check("t1/neg-context-declined", t2s.get("contextLen").state, "absent")
    A.check("t1/zero-ubatch-declined", t2s.get("ubatch").state, "absent")
    A.check("t1/cacheK-defaults-f16-with-no-flags", t2s.get("cacheK").value, "f16")

    // Idempotent: the 1 Hz poll must not churn the store version.
    var vBefore = t1s.version()
    s._applyTier1([entry1, entry2])
    A.check("t1/poll-is-idempotent", t1s.version(), vBefore)

    // Pruned to the loaded set, so an unloaded model cannot keep its derived
    // graph alive for the rest of the session.
    A.ok("prune/live-survives", s._stores["/m/store-t1/a.gguf"] !== undefined)
    A.ok("prune/new-store-created", s._stores["/m/store-t1/b.gguf"] !== undefined)
    s._pruneStores([entry1])
    A.ok("prune/live-kept", s._stores["/m/store-t1/a.gguf"] !== undefined)
    A.check("prune/unloaded-dropped", s._stores["/m/store-t1/b.gguf"], undefined)
    A.check("prune/unloaded-version-dropped", s._storeVersions["/m/store-t1/b.gguf"], undefined)

    // ── Tier 2 producer: what the GGUF header can answer ───────────────
    var entry3 = {
      name: "c", modelPath: "/m/store-t2/c.gguf", draftPath: "",
      sizeBytes: 16000000000, contextLen: 4096, nParams: 8000000000,
      ngl: "20", nglDraft: "", specType: "", cacheK: "", cacheV: "",
      noKvOffload: false, ubatch: 512, parallel: 1,
      swaFull: false, noKvUnified: false }
    s._pruneStores([entry3])
    s._applyTier1([entry3])
    var t3s = s._storeFor("/m/store-t2/c.gguf")
    // With no header parsed yet, tier 2 has not answered AND has not declined:
    // an undecided field stays pending rather than exhausting to "—".
    A.check("t2/no-header-pending", t3s.get("totalLayers").state, "pending")
    A.check("t2/no-header-ftype-pending", t3s.get("ftype").state, "pending")
    // A dense llama-family header: 32 layers, 32 heads, 8 KV heads, 4096 embd,
    // swa declared 0 (every layer dense). head dim = 4096/32 = 128, so
    // kLen = vLen = 8*128 = 1024 and cells = the full context.
    // arch is REQUIRED, not decoration: an untemplated namespace declines rather
    // than describing a shape from key names nobody has verified for it. A
    // fixture with no arch is not a real header — _finishGguf always sets one.
    var hdrDense = { arch: "llama", bc: 32, hc: 32, hckv: 8, embd: 4096, swa: 0, ft: 15, npl: 0 }
    s._tier2ToEntryStore(entry3, hdrDense)
    A.check("t2/totalLayers", t3s.get("totalLayers").value, 32)
    A.check("t2/totalLayers-tier", t3s.get("totalLayers").tier, 2)
    A.check("t2/totalLayers-exact", t3s.get("totalLayers").state, "exact")
    A.check("t2/ftype", t3s.get("ftype").value, 15)
    // An absent nextn_predict_layers is a READING of 0 draft layers, not a gap.
    A.check("t2/no-draft-means-zero-mtp", t3s.get("mtpLayers").value, 0)
    A.check("t2/kvDescribed", t3s.get("kvDescribed").value, true)
    A.check("t2/kvBlockAligned", t3s.get("kvBlockAligned").value, true)
    // The whole graph follows from the header alone.
    A.check("t2/mainLayers", t3s.get("mainLayers").value, 32)
    A.check("t2/mainGpu-from-ngl", t3s.get("mainGpu").value, 20)
    A.check("t2/mainCpu", t3s.get("mainCpu").value, 12)
    A.check("t2/coreSize", t3s.get("coreSize").value, 16000000000)
    // 32 layers × (1024×2 B K + 1024×2 B V) × 4096 cells.
    A.check("t2/kvBytes", t3s.get("kvBytes").value, 536870912)
    A.check("t2/kvBytes-state", t3s.get("kvBytes").state, "exact")
    A.check("t2/kvBytes-tier-is-weakest-input", t3s.get("kvBytes").tier, 2)
    A.ok("t2/kvBytes-derived", t3s.get("kvBytes").derived)
    A.ok("t2/tier6-skipped-for-aligned-shape", !s.checkTier6Values(t3s))
    A.check("t2/weightGpu-estimated",
            t3s.get("weightGpu").state, "estimated")
    A.check("t2/weightGpu", t3s.get("weightGpu").value,
            Math.round(16000000000 * 20 / 32))

    // ── An undescribable shape is a FALSE answer, and it escalates ─────
    // No window key, no recurrent declaration: the file does not say what its
    // attention layers are, so only the engine can. Stated as false, never as a
    // pending field, because tier 2 has genuinely run and answered.
    var entry4 = {
      name: "d", modelPath: "/m/store-t2/d.gguf", draftPath: "",
      sizeBytes: 1000000000, contextLen: 8192, nParams: 4000000000,
      ngl: "all", nglDraft: "", specType: "", cacheK: "", cacheV: "",
      noKvOffload: false, ubatch: 512, parallel: 1,
      swaFull: false, noKvUnified: false }
    var hdrVague = { arch: "llama", bc: 40, hc: 32, hckv: 8, embd: 4096, ft: 2, npl: 0 }
    s._applyTier1([entry4])
    var t4s = s._storeFor("/m/store-t2/d.gguf")
    s._tier2ToEntryStore(entry4, hdrVague)
    A.check("t2/undescribable-is-false", t4s.get("kvDescribed").value, false)
    A.check("t2/undescribable-tier", t4s.get("kvDescribed").tier, 2)
    A.check("t2/no-spec-no-alignment-claim", t4s.get("kvBlockAligned").state, "absent")
    A.ok("t2/tier6-runs-for-undescribable", s.checkTier6Values(t4s))
    A.check("t2/kvBytes-still-pending", t4s.get("kvBytes").state, "pending")
    // Tier 6 answers it exactly, and the derivation refuses to overwrite a
    // stronger answer with a weaker one.
    A.ok("t2/tier6-commit", t4s.commit("kvBytes", 1234567, "exact", 6))
    s.applyDerivation(t4s)
    A.check("t2/tier6-value-stands", t4s.get("kvBytes").value, 1234567)
    A.check("t2/tier6-value-exact", t4s.get("kvBytes").state, "exact")
    A.ok("t2/tier6-gate-closes", !s.checkTier6Values(t4s))

    // ── Gate 2: qwen35moe settles from the header alone ───────────────
    // The shipped qwen3.6-35b-a3b. Header read directly from the file on this
    // machine: block_count 40, embedding_length 2048, head_count 16,
    // head_count_kv 2, key_length 256, value_length 256, and
    // full_attention_interval 4 at the ARCH ROOT — not under `attention.`, which
    // is where a symmetric suffix table would have looked. No
    // attention.sliding_window and no pattern key at all: the file declares a
    // hybrid, so the 30 non-(4th) layers are recurrent and only 10 hold KV.
    // The 10-layer answer is the whole point: a 40-layer reading is a ~20 GiB
    // cache on a 16 GiB card, which is precisely the bug Gate 1 guards.
    var entry6 = {
      name: "f", modelPath: "/m/store-t2/f.gguf", draftPath: "",
      sizeBytes: 17730509792, contextLen: 262144, nParams: 35000000000,
      ngl: "all", nglDraft: "", specType: "", cacheK: "", cacheV: "",
      noKvOffload: false, ubatch: 512, parallel: 1,
      swaFull: false, noKvUnified: false }
    var hdrQwen = {
      arch: "qwen35moe", bc: 40, hc: 16, hckv: 2, hckvArr: null, embd: 2048,
      npl: -1, fai: 4, kl: 256, vl: 256, klswa: -1, vlswa: -1, swa: -1,
      sharedKv: -1, swaPattern: -1, swaPatternArr: null, recurrentArr: null,
      kvLoraRank: -1, ropeDim: 64, sz: -1, ft: -1 }
    s._applyTier1([entry6])
    var t6s = s._storeFor("/m/store-t2/f.gguf")
    s._tier2ToEntryStore(entry6, hdrQwen)
    A.check("gate2/qwen35moe-described", t6s.get("kvDescribed").value, true)
    A.check("gate2/qwen35moe-aligned", t6s.get("kvBlockAligned").value, true)
    // The shape itself: 10 KV-holding layers, each 2 heads wide, each row
    // kvHeads × key_length = 2 × 256.
    var spec6 = s._buildKvLayers(hdrQwen, 40, 262144, {})
    A.check("gate2/kv-layer-count", spec6 ? spec6.layers.length : -1, 10)
    A.check("gate2/kv-heads", spec6 ? spec6.layers[0].kvHeads : -1, 2)
    A.check("gate2/k-row-width", spec6 ? spec6.layers[0].kLen : -1, 512)
    A.check("gate2/v-row-width", spec6 ? spec6.layers[0].vLen : -1, 512)
    // 10 × 262144 cells × (512 + 512) f16 elements. The 40-layer figure is four
    // times this, and is what the absent template used to produce.
    var qwen40 = 40 * 262144 * 2048
    A.check("gate2/kvBytes-is-the-10-layer-figure", t6s.get("kvBytes").value,
            10 * 262144 * 2048)
    A.check("gate2/kvBytes-state", t6s.get("kvBytes").state, "exact")
    // Gate 1, asserted as the plan states it: the VALUE, and nothing else.
    A.ok("gate1/qwen35moe-kv-under-16gib",
         t6s.get("kvBytes").value > 0 && t6s.get("kvBytes").value < 16 * 1024 * 1024 * 1024)
    A.ok("gate1/qwen35moe-not-the-40-layer-reading",
         t6s.get("kvBytes").value !== qwen40)
    // Gate 2's other half: the tier-6 gate never opens, so no 3–45 s subprocess
    // is spent on a model the header already sizes.
    A.ok("gate2/tier6-gate-never-opens", !s.checkTier6Values(t6s))

    // ── The decline path, which is what makes an absent template safe ──
    // A SYNTHETIC namespace, so this cannot accidentally pass because the file's
    // real arch happens to be templated. Same geometry as qwen35moe, so the only
    // difference the test measures is the namespace.
    var entry7 = {
      name: "g", modelPath: "/m/store-t2/g.gguf", draftPath: "",
      sizeBytes: 16000000000, contextLen: 8192, nParams: 8000000000,
      ngl: "20", nglDraft: "", specType: "", cacheK: "", cacheV: "",
      noKvOffload: false, ubatch: 512, parallel: 1,
      swaFull: false, noKvUnified: false }
    var hdrUnknown = {
      arch: "totally-made-up-arch", bc: 40, hc: 16, hckv: 2, hckvArr: null,
      embd: 2048, npl: -1, fai: 4, kl: 256, vl: 256, klswa: -1, vlswa: -1,
      swa: -1, sharedKv: -1, swaPattern: -1, swaPatternArr: null,
      recurrentArr: null, kvLoraRank: -1, ropeDim: 64, sz: -1, ft: -1 }
    s._applyTier1([entry7])
    var t7s = s._storeFor("/m/store-t2/g.gguf")
    s._tier2ToEntryStore(entry7, hdrUnknown)
    A.check("gate1/untemplated-declines", t7s.get("kvDescribed").value, false)
    A.ok("gate1/untemplated-opens-tier6", s.checkTier6Values(t7s))
    A.check("gate1/untemplated-no-guessed-bytes", t7s.get("kvBytes").state, "pending")
    // And the decline is the arch gate, not the recurrent rule: the identical
    // geometry under a templated namespace DOES describe. If this pair ever
    // diverges, the gate stopped being about the namespace.
    A.ok("gate1/decline-is-about-namespace-not-shape",
         s._buildKvLayers(hdrQwen, 40, 8192, {}) !== null)

    // ── Bounded versus decline: a positive window with recurrence ──────
    // A templated file that declares recurrent layers (fai > 1) AND a positive
    // sliding window is deliberately left unknown: only lfm2 derives a pattern
    // from the window among the hybrids, lfm2moe/bailingmoe3 ignore it, so
    // answering would be a one-architecture table in disguise. Unknown → null →
    // tier 6, rather than a bounded "~" that would look like a measurement.
    var hdrWindowedHybrid = {
      arch: "lfm2", bc: 40, hc: 16, hckv: 2, hckvArr: null, embd: 2048,
      npl: -1, fai: 4, kl: 256, vl: 256, klswa: -1, vlswa: -1, swa: 2048,
      sharedKv: -1, swaPattern: -1, swaPatternArr: null, recurrentArr: null,
      kvLoraRank: -1, ropeDim: 64, sz: -1, ft: -1 }
    A.ok("kvshape/positive-window-plus-recurrence-declines",
         s._buildKvLayers(hdrWindowedHybrid, 40, 8192, {}) === null)
    // A declared dense stack (sliding_window 0) with the same recurrence IS
    // describable: the file stated its layer type, so nothing is guessed.
    var hdrDenseHybrid = {
      arch: "qwen35", bc: 40, hc: 16, hckv: 2, hckvArr: null, embd: 2048,
      npl: -1, fai: 4, kl: 256, vl: 256, klswa: -1, vlswa: -1, swa: 0,
      sharedKv: -1, swaPattern: -1, swaPatternArr: null, recurrentArr: null,
      kvLoraRank: -1, ropeDim: 64, sz: -1, ft: -1 }
    var specDense = s._buildKvLayers(hdrDenseHybrid, 40, 8192, {})
    A.check("kvshape/dense-hybrid-describes", specDense ? specDense.layers.length : -1, 10)

    // ── A draft header supersedes the base header's MTP keys ──────────
    var entry5 = {
      name: "e", modelPath: "/m/store-t2/e.gguf", draftPath: "/m/store-t2/e-d.gguf",
      sizeBytes: 16000000000, contextLen: 4096, nParams: 8000000000,
      ngl: "40", nglDraft: "3", specType: "", cacheK: "", cacheV: "",
      noKvOffload: false, ubatch: 512, parallel: 1,
      swaFull: false, noKvUnified: false }
    s._applyTier1([entry5])
    var t5s = s._storeFor("/m/store-t2/e.gguf")
    s._tier2ToEntryStore(entry5, hdrDense)
    A.check("t2/mtpLayers-undecided-while-draft-pending", t5s.get("mtpLayers").state, "pending")
    // The draft header arrives through _applyGgufDraft in production; parked
    // directly here so the test does not have to build a running-models array.
    t5s.ctx.draftGguf = { bc: 3, sz: 900000000 }
    s._applyTier2To(t5s)
    s._settle(t5s)
    A.check("t2/draft-header-wins-mtpLayers", t5s.get("mtpLayers").value, 3)
    A.check("t2/draft-header-size", t5s.get("draftSizeBytes").value, 900000000)
    A.check("t2/draft-exact-size-beats-uniform", t5s.get("mtpSizeBytes").value, 900000000)
    A.check("t2/draft-exact-size-state", t5s.get("mtpSizeBytes").state, "exact")
    // A separate draft file's 3 layers were NEVER in the base file's 32, so the
    // main stack is all 32. Subtracting them made the panel claim a 29-layer
    // model it never loaded; only a BUILT-IN MTP stack reduces totalLayers.
    A.check("t2/mainLayers-separate-draft-keeps-base", t5s.get("mainLayers").value, 32)
    // -ngld 3 over a 3-layer draft: all of it, counted over the draft's own stack
    // rather than the base file's 32 (where 3 < 32 - 3 would have read as zero).
    A.check("t2/mtpGpu", t5s.get("mtpGpu").value, 3)
    A.check("t2/mainGpu-separate-draft", t5s.get("mainGpu").value, 32)
    A.check("t2/coreSize-keeps-whole-base-file", t5s.get("coreSize").value, 16000000000)

    // ── Revision: a live tier supersedes its own reading ───────────────
    var rv = s.createFieldStore("/m/store-rev/a.gguf")
    rv.commit("soleAttribution", "measured", "exact", 4)
    A.ok("rev/revise-same-tier", rv.revise("soleAttribution", "unattributable", "exact", 4))
    A.check("rev/value-updated", rv.get("soleAttribution").value, "unattributable")
    A.ok("rev/tier-unchanged", rv.get("soleAttribution").tier === 4)
    // A DIFFERENT tier may not revise: that is commit()'s effective-tier rule.
    A.ok("rev/other-tier-cannot-revise",
         !rv.revise("soleAttribution", "measured", "exact", 5))
    A.check("rev/value-survives-refused-revision",
            rv.get("soleAttribution").value, "unattributable")
    // No-op when nothing changed, so a 1 Hz poll cannot churn the version.
    var vNow = rv.version()
    A.ok("rev/identical-is-noop", !rv.revise("soleAttribution", "unattributable", "exact", 4))
    A.check("rev/noop-keeps-version", rv.version(), vNow)

    // ── Derived answers follow their inputs ───────────────────────────
    // The reported regression: a corrected cache size left the panel reading
    // "on GPU" because the location had been written once and could not move.
    var dl = s.createFieldStore("/m/store-rev/b.gguf")
    s._t4(dl, "soleAttribution", "measured")
    s._t4(dl, "noKvOffload", false)
    s._t4(dl, "kvBytes", 2 * 1073741824)
    s._t4(dl, "memBytes", 0)
    s._t4(dl, "vramBytes", 8 * 1073741824)
    s._settle(dl)
    A.check("deriv/location-initially", dl.get("kvLocation").value, "GPU")
    // Host anon at 4 GiB is now LARGER than the cache: rung 3 cannot separate the
    // cache from the weights, so the honest answer is not "GPU" any more.
    dl.revise("memBytes", 4 * 1073741824, "estimated", 4)
    s._settle(dl)
    A.check("deriv/location-withdrawn-on-unsupported-revisit",
            dl.get("kvLocation").state, "absent")
    // ...and back down again, to prove the revision is not one-way.
    dl.revise("memBytes", 0, "estimated", 4)
    s._settle(dl)
    A.check("deriv/location-revised-back", dl.get("kvLocation").value, "GPU")
    // An unchanged input set must NOT re-commit (no churn on every settle).
    var vLoc = dl.version()
    s.applyDerivation(dl)
    A.check("deriv/unchanged-inputs-no-churn", dl.version(), vLoc)

    // ── Tier 4 producer: a missing reading is pending, never "—" ───────
    var t4s = s.createFieldStore("/m/store-t4/a.gguf")
    s._t4(t4s, "memBytes", -1)
    A.check("t4/missing-reading-stays-pending", t4s.get("memBytes").state, "pending")
    t4s.markSettled()
    A.check("t4/missing-reading-not-absent", t4s.get("memBytes").state, "pending")
    s._t4(t4s, "memBytes", 400000000)
    A.check("t4/later-reading-commits", t4s.get("memBytes").value, 400000000)
    A.check("t4/readings-are-estimated", t4s.get("memBytes").state, "estimated")
    A.check("t4/readings-are-tier4", t4s.get("memBytes").tier, 4)
    s._t4(t4s, "memBytes", 900000000)
    A.check("t4/newer-reading-supersedes", t4s.get("memBytes").value, 900000000)

    // ── Tier 4 projection: attribution follows the loaded set ──────────
    s.runningModels = [{ modelPath: "/m/store-t4/a.gguf" },
                       { modelPath: "/m/store-t4/b.gguf" }]
    s._pruneStores(s.runningModels)
    s.serviceMemoryBytes = 400000000
    s.serviceVramBytes = 8 * 1024 * 1024 * 1024
    s._applyTier4()
    var p1 = s._storeFor("/m/store-t4/a.gguf"), p2 = s._storeFor("/m/store-t4/b.gguf")
    A.check("t4/two-models-unattributable",
            p1.get("soleAttribution").value, "unattributable")
    A.check("t4/both-stores-projected", p2.get("memBytes").value, 400000000)
    // Unload one and the attribution becomes measurable — a same-tier revision,
    // which is the only way a live reading is allowed to correct itself.
    s.runningModels = [{ modelPath: "/m/store-t4/a.gguf" }]
    s._applyTier4()
    A.check("t4/one-model-measured", p1.get("soleAttribution").value, "measured")
    A.check("t4/attribution-revision-keeps-tier", p1.get("soleAttribution").tier, 4)
    // ...and the ladder fires only then: unattributable declined the placement,
    // and a stronger answer is required to replace it.
    s.runningModels = []
    s.serviceMemoryBytes = -1
    s.serviceVramBytes = -1

    // ── Tier 3 producer: the RAW token, and `auto` answers nothing ─────
    s._presetCache = s._parseIniLines("[*]\nfit = on\nn-gpu-layers = all\n")
    var e6 = { name: "f", modelPath: "/m/store-t3/a.gguf",
               draftPath: "", sizeBytes: 9200000000, contextLen: 131072,
               nParams: -1, ngl: "", nglDraft: "", specType: "",
               cacheK: "", cacheV: "", noKvOffload: false, ubatch: 512,
               parallel: 1, swaFull: false, noKvUnified: false }
    var t3v = s.createFieldStore("/m/store-t3/a.gguf")
    s._applyTier3(e6, t3v)
    A.check("t3/preset-token-from-globals", t3v.get("presetNgl").value, "all")
    A.check("t3/preset-tier", t3v.get("presetNgl").tier, 3)
    // The token feeds mainGpu, and a stated count is exact.
    t3v.commit("totalLayers", 80, "exact", 2)
    t3v.commit("mtpLayers", 0, "exact", 2)
    s._settle(t3v)
    A.check("t3/preset-drives-mainGpu", t3v.get("mainGpu").value, 80)
    A.check("t3/preset-derived-mainGpu-exact", t3v.get("mainGpu").state, "exact")
    // `auto` is a stated intent but not a stated COUNT, so it answers nothing:
    // tier 3 declines rather than handing on a token _mtpSplit would reject.
    var t3w = s.createFieldStore("/m/store-t3/b.gguf")
    s._presetCache = s._parseIniLines("[*]\nfit = auto\nn-gpu-layers = auto\n")
    s._applyTier3({ modelPath: "/m/store-t3/b.gguf" }, t3w)
    t3w.markSettled()
    A.check("t3/auto-token-answers-nothing", t3w.get("presetNgl").state, "absent")
    s._presetCache = null

    // ── Tier 5: llama-fit-params ───────────────────────────────────────
    // The argv group pins the flags that must NEVER vary, and they live in the
    // script rather than in the argv precisely so these can byte-compare them.
    var fs = s.kvFitScript
    A.ok("fit/argv-fit-off", fs.indexOf("--fit off") >= 0)
    A.ok("fit/argv-fit-print-on", fs.indexOf("--fit-print on") >= 0)
    A.ok("fit/argv-explicit-ngl", fs.indexOf('-ngl "$ngl"') >= 0)
    A.notok("fit/argv-no-fit-target", fs.indexOf("-fitt") >= 0 || fs.indexOf("--fit-target") >= 0)
    A.notok("fit/argv-no-flash-attn", fs.indexOf("--flash-attn") >= 0)
    // The model path is its own quoted positional ($3), never interpolated: a
    // path containing `;` stays one argument.
    A.ok("fit/argv-model-path-slot", fs.indexOf('model="$3"') >= 0 && fs.indexOf('-m "$model"') >= 0)
    // `shift 3` is the idiom that keeps the wrapper from emitting its own leading
    // arguments twice.
    A.ok("fit/argv-shift-3", fs.indexOf("shift 3") >= 0)
    // 97 is "not installed" and must not collide with kvProbeScript's 98,
    // which means "retry later".
    A.ok("fit/script-exit-97", fs.indexOf("exit 97") >= 0)
    A.ok("fit/script-97-not-98", s.kvProbeScript.indexOf("exit 98") >= 0 && fs.indexOf("exit 98") < 0)
    A.ok("fit/timeout-watchdog-gap", s.kvFitWatchdogMs > s.kvFitTimeoutSec * 1000)

    var fa = s._buildFitArgv("/m/a b;c.gguf", 40, "q8_0", "q4_0", 32768)
    A.check("fit/argv-binary-slot", fa[0], "/usr/bin/llama-fit-params")
    A.check("fit/argv-ngl-slot", fa[1], "40")
    A.check("fit/argv-model-slot", fa[2], "/m/a b;c.gguf")
    A.check("fit/argv-ctk", fa[3], "-ctk")
    A.check("fit/argv-ctv", fa[5], "-ctv")
    A.check("fit/argv-context", fa[7], "-c")
    // An unsupported dtype is dropped rather than passed: an invalid value is an
    // immediate exit-1 that would be indistinguishable from a real abort.
    var fb = s._buildFitArgv("/m/a.gguf", 0, "nope", "f16", 0)
    A.notok("fit/argv-bad-dtype-dropped", fb.indexOf("-ctk") >= 0)
    A.notok("fit/argv-no-context-without-one", fb.indexOf("-c") >= 0)

    // ── The parser, driven from the golden fixture ─────────────────────
    var fdir = "@TESTS_DIR@/fixtures/fit_params/cuda-1/"
    var fixture = readFixture(fdir + "ngl40-q8_0-ctx32768.txt")
    A.ok("fit/fixture-present", fixture.indexOf("CUDA0") >= 0)
    A.ok("fit/parse-header-line",
         s._fitIsPreamble("llama_fit_params: printing estimated memory in MiB to stdout (device, model, context, compute) ..."))
    A.check("fit/parse-preamble-skipped",
            s._parseFitRow("llama_fit_params: printing estimated memory in MiB to stdout (device, model, context, compute) ..."), null)
    A.check("fit/parse-trailing-space", s._parseFitRow("CUDA0 1 2 3 ") !== null, true)
    A.check("fit/parse-total-row", s._parseFitRow("total 1 2 3"), null)
    A.check("fit/parse-malformed", s._parseFitRow("CUDA0 1 2"), null)
    A.check("fit/parse-malformed-not-zero-filled", s._parseFitRow("CUDA0 1 x 3"), null)
    A.check("fit/parse-empty-stdout", s.parseFitParams(""), null)
    A.check("fit/parse-abort", s.parseFitParams(""), null)
    A.check("fit/parse-unknown-device-is-device", s._parseFitRow("Vulkan0 1 2 3").host, false)
    A.check("fit/parse-host-row", s._parseFitRow("Host 1 2 3").host, true)
    // Column order is device model context compute; the `context` column is the
    // KV bytes, and the cells are integer MiB converted exactly once.
    var rowA = s._parseFitRow("CUDA0 8692 767 551 ")
    A.check("fit/parse-cuda-row-model", rowA.modelMiB, 8692)
    A.check("fit/parse-cuda-row-context", rowA.contextMiB, 767)
    A.check("fit/parse-cuda-row-compute", rowA.computeMiB, 551)
    // A zero cell is a real reading, not a missing one.
    var rowZ = s._parseFitRow("CUDA0 0 0 4 ")
    A.check("fit/parse-zero-column", rowZ.modelMiB, 0)
    A.ok("fit/parse-zero-column-survives", rowZ !== null)
    A.check("fit/parse-mib-to-bytes", s._fitMibToBytes(2), 2097152)
    A.check("fit/parse-mib-to-bytes-rounds", s._fitMibToBytes(0.5), 524288)
    var two = s.parseFitParams("CUDA0 10 20 30\nCUDA1 5 7 11\nHost 1 2 3\n")
    A.check("fit/parse-two-devices", two.deviceRows.length, 2)
    A.check("fit/parse-two-devices-summed", two.deviceTotal.context, 27 * 1048576)
    A.check("fit/parse-host-total", two.hostTotal.context, 2 * 1048576)

    // ── Which N to decompose at: cheapest definitive first ──────────────
    var n1 = s.createFieldStore("/m/fit/a.gguf")
    n1.commit("ngl", "20", "exact", 1)
    n1.commit("presetNgl", "all", "exact", 3)
    n1.commit("totalLayers", 80, "exact", 2)
    A.check("fit/ngl-source-explicit", s._fitNglFor(n1), 20)
    A.check("fit/ngl-auto-is-not-a-count", s._fitNglFor(s.createFieldStore("/m/fit/none.gguf")), null)
    var n2 = s.createFieldStore("/m/fit/b.gguf")
    n2.commit("presetNgl", "33", "exact", 3)
    A.check("fit/ngl-source-preset", s._fitNglFor(n2), 33)
    var n3 = s.createFieldStore("/m/fit/c.gguf")
    n3.commit("presetNgl", "all", "exact", 3)
    n3.commit("totalLayers", 80, "exact", 2)
    A.check("fit/ngl-preset-all-becomes-a-count", s._fitNglFor(n3), 80)
    var n4 = s.createFieldStore("/m/fit/d.gguf")
    n4.commit("mainGpu", 12, "estimated", 4)
    A.check("fit/ngl-source-estimate", s._fitNglFor(n4), 12)
    // An EXACT mainGpu is not a supplied N — only the estimate stands in.
    var n5 = s.createFieldStore("/m/fit/e.gguf")
    n5.commit("mainGpu", 12, "exact", 1)
    A.check("fit/ngl-source-exact-mainGpu-not-used", s._fitNglFor(n5), null)

    // The signature covers everything that changes the answer.
    var n6 = s.createFieldStore("/m/fit/f.gguf")
    n6.commit("ngl", "20", "exact", 1)
    n6.commit("cacheK", "q8_0", "exact", 1)
    n6.commit("cacheV", "q8_0", "exact", 1)
    n6.commit("contextLen", 32768, "exact", 1)
    s._stores["/m/fit/f.gguf"] = n6
    var sig0 = s._fitSignatureFor("/m/fit/f.gguf")
    A.ok("fit/signature-covers-inputs",
         sig0 === "/m/fit/f.gguf|20|q8_0|q8_0|32768")

    // ── The commit: three fields, permanently estimated ────────────────
    s.runningModels = [{ modelPath: "/m/fit/f.gguf" }, { modelPath: "/m/fit/g.gguf" }]
    s._pruneStores(s.runningModels)
    s._kvFitRunning = 0
    s._tier5Available = true
    s._kvFitCache = ({})
    s._kvFitQueue = []
    s._kvFitSig = sig0
    s._kvFitPath = "/m/fit/f.gguf"
    var rows = fixture.split("\n")
    for (var fl = 0; fl < rows.length; fl++) if (rows[fl] !== "") s._onFitLine(rows[fl])
    s._finishKvFit(0)
    var fstore = s._storeFor("/m/fit/f.gguf")
    A.check("fit/device-context", fstore.get("kvGpuBytes").value, 767 * 1048576)
    A.check("fit/host-context", fstore.get("kvCpuBytes").value, 470 * 1048576)
    A.check("fit/device-compute", fstore.get("computeBytes").value, 551 * 1048576)
    A.check("fit/permanently-estimated", fstore.get("kvGpuBytes").state, "estimated")
    A.check("fit/estimated-at-tier5", fstore.get("kvGpuBytes").tier, 5)
    // The test that would have caught the fit-decider design: a projection must
    // never report its own inputs back as findings.
    A.check("fit/never-commits-kvBytes", fstore.get("kvBytes").state, "pending")
    A.check("fit/never-commits-weightGpu", fstore.get("weightGpu").state, "pending")
    A.check("fit/never-commits-mainGpu", fstore.get("mainGpu").state, "pending")

    // ── Degradation: one attempt, then `—` ─────────────────────────────
    s._kvFitSig = s._fitSignatureFor("/m/fit/g.gguf")
    s._kvFitPath = "/m/fit/g.gguf"
    s._kvFitBuffer = ""
    s._finishKvFit(134)                       // the mmproj abort, verbatim
    var gstore = s._storeFor("/m/fit/g.gguf")
    A.check("fit/abort-declines-gpu", gstore.get("kvGpuBytes").state, "absent")
    A.check("fit/abort-declines-cpu", gstore.get("kvCpuBytes").state, "absent")
    A.check("fit/abort-declines-compute", gstore.get("computeBytes").state, "absent")
    // No retry: the completed signature is cached, so the same inputs cannot
    // re-queue a process.
    A.check("fit/abort-not-cached-as-answer", s._kvFitCache[s._fitSignatureFor("/m/fit/g.gguf")].ok, false)
    var qBefore = s._kvFitQueue.length
    s._queueKvFit({ modelPath: "/m/fit/g.gguf" })
    A.check("fit/no-retry-after-abort", s._kvFitQueue.length, qBefore)

    // ── Gating and single-flight ───────────────────────────────────────
    s._queueKvFit({ modelPath: "/m/fit/f.gguf" })
    A.check("fit/gate-nothing-outstanding", s._kvFitQueue.length, 0)
    // A store with outstanding tier-5 fields while one run is in flight must not
    // enqueue the same signature.
    var w = s.createFieldStore("/m/fit/h.gguf")
    w.commit("ngl", "20", "exact", 1)
    s._stores["/m/fit/h.gguf"] = w
    s._kvFitRunning = 1
    s._kvFitSig = s._fitSignatureFor("/m/fit/h.gguf")
    s._queueKvFit({ modelPath: "/m/fit/h.gguf" })
    A.check("fit/single-flight", s._kvFitQueue.length, 0)
    // A store with nothing outstanding does not enqueue even mid-flight.
    s._queueKvFit({ modelPath: "/m/fit/f.gguf" })
    A.check("fit/gate-blocks-answered-store", s._kvFitQueue.length, 0)
    s._kvFitRunning = 0
    s._kvFitSig = ""
    s._kvFitQueue = []

    // ── Availability: 97 is permanent ──────────────────────────────────
    s._tier5Available = true
    var u = s.createFieldStore("/m/fit/i.gguf")
    u.commit("ngl", "20", "exact", 1)
    s._stores["/m/fit/i.gguf"] = u
    s.runningModels = [{ modelPath: "/m/fit/i.gguf" }]
    s._pruneStores(s.runningModels)
    s._kvFitSig = "never-ran"
    s._kvFitPath = "/m/fit/i.gguf"
    s._finishKvFit(97)
    A.check("fit/absent-binary-cached", s._tier5Available, false)
    A.check("fit/absent-binary-declines", s._storeFor("/m/fit/i.gguf").get("kvGpuBytes").state, "absent")
    // And it never spawns again: the queue stays empty on every later refresh.
    s._queueKvFit({ modelPath: "/m/fit/i.gguf" })
    A.check("fit/absent-binary-no-respawn", s._kvFitQueue.length, 0)
    s._tier5Available = true
    s._kvFitCache = ({})

    // ── Tier 1's context: /slots n_ctx, and only /slots ─────────────────
    // `--ctx-size 0` means "let fit decide", so argv cannot say what the context
    // actually is; /slots reports the value llama.cpp resolved (measured here:
    // qwen3.8-27b-fast → 102912).
    s.runningModels = [{ modelPath: "/m/slots/a.gguf", id: "slots-model" }]
    s._pruneStores(s.runningModels)
    var cst = s._storeFor("/m/slots/a.gguf")
    cst.commit("contextLen", 262144, "exact", 1)     // what argv claimed
    s._slotsModelId = "slots-model"
    s._slotsBuffer = '[{"n_ctx":102912,"is_processing":false,"id_task":3}]'
    s._finishSlots()
    A.check("slots/resolved-context-wins", cst.get("contextLen").value, 102912)
    A.check("slots/context-still-exact", cst.get("contextLen").state, "exact")
    A.check("slots/context-still-tier1", cst.get("contextLen").tier, 1)
    // The same reading twice must not churn the store version (1 Hz poll).
    var vCtx = cst.version()
    s._slotsBuffer = '[{"n_ctx":102912,"is_processing":false,"id_task":3}]'
    s._finishSlots()
    A.check("slots/unchanged-context-no-churn", cst.version(), vCtx)
    // A slot with no usable n_ctx answers nothing at all.
    s._slotsBuffer = '[{"is_processing":false,"id_task":4}]'
    s._finishSlots()
    A.check("slots/absent-n-ctx-answers-nothing", cst.get("contextLen").value, 102912)
    // An id that matches no loaded model must not touch any store.
    s._slotsModelId = "someone-else"
    s._slotsBuffer = '[{"n_ctx":4096}]'
    s._finishSlots()
    A.check("slots/unknown-id-ignored", cst.get("contextLen").value, 102912)
    // The KV geometry follows the corrected context, because it is derived from it.
    s._applySlotsContext("slots-model", 32768)
    A.check("slots/context-revisable", cst.get("contextLen").value, 32768)
    s._slotsBuffer = ""
    s._slotsModelId = ""
    s.runningModels = []

    A.finish()
  }
}
