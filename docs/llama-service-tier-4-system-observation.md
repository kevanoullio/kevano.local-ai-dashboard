# Tier 4 — System observation

**Cost** ~20 ms · **Role** **authoritative** · **Status** exists, but the
placement ladder built on it is wrong

This tier is part of the llama.cpp service acquisition ladder. The ollama
backend does not use any of these tiers — it reads everything directly from the
engine.

Two numbers, read from the kernel, about what the llama.cpp service is
actually holding right now:

- `serviceMemoryBytes` — host DRAM, from the service's own cgroup
- `serviceVramBytes` — device memory, summed per-PID

This is the only tier that *measures* rather than asks or predicts. That makes
its readings exact, and it makes them **inputs** — but it does not make it an
arbiter. A measurement outranking a prediction is a rule about *what to believe*,
and this design does not have one: each rung holds a reading, the resolver keeps
the strongest answer a field actually received, and the display states its
certainty. Nothing here overrides tier 5, and §6 explains why that arbitration
was withdrawn.

Everything in §5 is a change. Everything up to it is how the code works today.

---

## 1. Host DRAM — `serviceMemoryScript`

`Service.qml:353`. `$1` = unit name, `$2` = output cap.

```bash
pid=$(systemctl --user show $1 --property=MainPID --value 2>/dev/null)
cg=$(systemctl --user show $1 --property=ControlGroup --value 2>/dev/null)
if [ -z "$cg" ] && [ -n "$pid" ] && [ -r "/proc/$pid/cgroup" ]; then
  cg=$(awk -F: '$1=="0"{print $3; exit}' "/proc/$pid/cgroup" 2>/dev/null)
fi
out=""
[ -n "$cg" ] && [ -r "/sys/fs/cgroup$cg/memory.stat" ] && \
  out=$(awk '$1=="anon"{a=$2}$1=="shmem"{s=$2}END{print (a+0)+(s+0)}' \
        "/sys/fs/cgroup$cg/memory.stat" 2>/dev/null)
[ -z "$out" ] && out=$(systemctl --user show $1 --property=MemoryCurrent --value 2>/dev/null)
[ -n "$out" ] || out=0
echo "$out" | head -c $2
```

### Why `anon + shmem`

`memory.current` / systemd `MemoryCurrent` also count **reclaimable file
cache** — and the mmap'd `.gguf` is gigabytes of it. A loaded 13 GB model
reads ~17–18 GB of RSS, of which only ~4 GB is really private; the rest is
pages of the model file that are either already held as anon or already on the
GPU. Using it would double-count. `anon + shmem` is the private working set
and excludes them.

`MemoryCurrent` is kept as a **last resort** precisely because it is worse;
dropping it would lose the answer on systems where `memory.stat` is
unreadable, and an approximate number beats none. It is never the primary
path.

### Three cgroup resolutions, in order

1. `systemctl --user show <unit> --property=ControlGroup` — normal case.
2. `/proc/<MainPID>/cgroup`, the `0::` line — for a transient scope or a D-Bus
   hiccup. This matters because the preset **router** forks a per-model worker:
   the instance's cgroup is hierarchical, so one cgroup covers the router and
   every worker it spawns. Measuring the worker directly is what makes the
   reading attributable to one model.
3. `MemoryCurrent` — last resort, see above.

`out=0` (not empty) is the "measured, and it is zero" answer; `-1` is set by
the QML side when the process never ran or produced nothing parseable. The
distinction matters: `0` is a real, decisive reading (it is the
`host anon == 0 → GPU` rung), `-1` is "no reading".

## 2. Device memory — `serviceVramScript`

`Service.qml:373`.

```bash
cg=$(systemctl --user show $1 --property=ControlGroup --value 2>/dev/null)
pid=$(systemctl --user show $1 --property=MainPID --value)
pids="$pid"
[ -n "$cg" ] && [ -r "/sys/fs/cgroup$cg/cgroup.procs" ] && \
  pids="$(tr '\n' ' ' < "/sys/fs/cgroup$cg/cgroup.procs") $pid"

if command -v nvidia-smi >/dev/null 2>&1; then
  nvidia-smi --query-compute-apps=pid,used_memory --format=csv,noheader,nounits 2>/dev/null |
  awk -F',' -v ps="$pids" 'BEGIN{n=split(ps,a," ");for(i=1;i<=n;i++)if(a[i]!="")seen[a[i]]=1}
                          {gsub(/[ \t]/,"",$1);gsub(/[ \t]/,"",$2);
                           if(($1 in seen)&&$2~/^[0-9]+$/){sum+=$2;c++}}
                          END{if(c>0)print sum" MiB"}'
elif command -v rocm-smi >/dev/null 2>&1; then
  rocm-smi --showmeminfo vram 2>/dev/null | head -2
fi | head -c $2
```

### Why per-PID and never total-GPU

`nvidia-smi --query-gpu=memory.used` and DRM `mem_info_vram_used_total` count
**every process on the GPU** — the desktop compositor, the browser, a second
LLM. The panel sums only the **per-PID** contexts belonging to the llama.cpp
service's PIDs (`cgroup.procs` plus `MainPID`), which is what makes the
reading attributable.

The awk does three things worth naming:

- it builds a `seen` set from the whitespace-separated PID list (`BEGIN`), so
  a PID appearing in both `cgroup.procs` and `MainPID` counts once;
- it strips whitespace from the CSV fields and requires `used_memory` to be
  **all digits** before summing — `nvidia-smi` emits `N/A` for a process with
  no context, and summing that would be `0`;
- it prints **only when at least one PID matched** (`if (c > 0)`), so "no
  matching process" is *no output* → `-1`, distinct from a genuine `0 MiB`.

Multi-GPU is handled by summing across devices — the result is one
service-wide VRAM total, not a per-device breakdown. Per-device breakdown is
tier 5's job.

The ROCm branch is structurally different (`rocm-smi --showmeminfo vram |
head -2` is process-attributed differently upstream) and is the weaker of the
two. It is a known asymmetry, not a designed one.

## 3. The derived total

```js
// Service.qml:2634 _deriveServiceTotal
serviceTotalBytes = (serviceMemoryBytes >= 0 && serviceVramBytes >= 0)
                   ? serviceMemoryBytes + serviceVramBytes : -1
```

Drives the service-level readouts: `cpuSplitPercent()` (`Service.qml:714`) and
`memoryTotalGB()` (`Service.qml:721`), both of which return `-1` / `""` when
either half is missing rather than showing a partial total as if it were whole.

## 4. Attribution: `sole`

```js
// Service.qml:2269 _placementMeasurements()
return { memBytes: serviceMemoryBytes, vramBytes: serviceVramBytes,
         sole: (runningModels || []).length === 1 }
```

Both readings cover the **whole service cgroup**. With more than one model
loaded, neither is this model's, so no rung that depends on them may fire.
`sole === false` is the guard, and it is a hard one: the only tiers that may
answer placement for a multi-model router are the ones that state it outright
(`--no-kv-offload`, `-ngl 0`).

## 5. The placement ladder — what is wrong with it today

`_kvPlacement` (`Service.qml:1144`) returns `"GPU"`, `"CPU"`, or `""`. It has
**no third value** for a split, and its last rung is wrong:

```js
if (isFinite(mem) && mem >= 0) {
  if (mem >= kv) return "CPU"        // ← Service.qml:1155 — THE BUG
  var v = Number(p.vramBytes)
  if (isFinite(v) && v > 0) return "GPU"
  return "CPU"                       // no device context: the cache is in RAM
}
```

### The gemma case, with the arithmetic

The running `gemma-4-26b-a4b-qat` worker, as `README.md` Example 3 records it:

| Quantity | Value |
|---|---|
| Host `anon+shmem` | 3,070,361,600 B = **2,928.6 MiB** |
| KV cache size (tier-3 derivation) | 3,019,248,763 B = **2,879.4 MiB** |
| Margin | host anon is **49.2 MiB above** the cache |
| Per-PID VRAM | **13,573 MiB** (`CUDA0 13573 …`) |

`mem >= kv` fires — by 49 MiB — so the code says **CPU**. The cache is
**on the device**. `README.md` repeats this conclusion in six places
(`L412-420`, `L542`, `L585-592`, `L601-604`, `L665-671`, `L770`) and
`tests/e2e_tests/e2e_preset.qml:100-106` echoes it in a comment.

The mistake is structural, not numeric. `host anon ≥ KV` is not proof of host
RAM. Host anon is `everything private the worker holds in RAM` — CPU weights,
the compute graph's host-side buffers, the mmproj, allocator slack, the
router's own state. It exceeds the cache size by an *arbitrary* amount
depending on the split. Presence of a host block at least as large as the
cache is consistent with the cache being there **and** with the cache being on
the device while unrelated host allocations account for the difference. The
current code treats consistency as proof.

### The salvage — four rungs

Gated on `sole`, using `mem` = host `anon+shmem`, `kv` = the cache size, and
whether a device context is held:

| # | Host anon | Device mem | Verdict | Certainty | Sound because |
|---|---|---|---|---|---|
| 1 | `== 0` | held | **GPU** | exact | Nothing private in host RAM at all, yet device memory is held. The cache is a KV-sized allocation; there is nowhere in host RAM for it. |
| 2 | `0 < mem < kv` | held | **GPU/CPU** split | `~` | *At most* `mem` worth can be in host; the remainder must be on the device. A genuine split, bounded on both sides. |
| 3 | any | none | **CPU** | exact | No device context exists, so the cache cannot be on a device. |
| 4 | `>= kv` | held | **indeterminate** | `—` | The bug case. Both placements are consistent. |

Rung 4 is the honest answer the current code collapses to a wrong one.
Rung 2 is a **capability gap**, not just a bug fix: `_kvPlacement` has no
`"GPU/CPU"` return value, and `ModelsSection.qml:211,215` adds the cache to
the GPU total only when `ctxOn === "GPU"` and the CPU total only when
`=== "CPU"` — so a split would be added to **neither** total.

Note the interaction with the two `~` markers: rung 1 is exact because it is
a statement of exhaustion over two allocations; rung 2 is `~` because it
bounds rather than states; rung 3 is exact because the negative is
unambiguous.

### Deliberately not a rung

- **A fully offloaded stack** (`gpuLayers >= mainLayers`). It looks like the
  mirror of `-ngl 0`, and it is the tempting shortcut — "every layer is on the
  device, so where else would the cache be?" The gemma worker is exactly this
  case with the opposite answer, because llama.cpp sizes the KV buffer against
  its own fit budget rather than following the layer buffers.
- **Free VRAM vs. `kv + fit-target`.** Rejected: llama.cpp's internal fit
  budget is larger than, and version-specific relative to, any `--fit-target`
  we can read. It misreported the very model above.
- **Per-PID VRAM exceeding `gpuWeights + kv`.** This is rung 1 plus arithmetic;
  it is sound as a *cross-check* but is not needed once rungs 1–4 are in place,
  and it reintroduces a dependency on the weight estimate.

## 6. Withdrawn: tier 4 does not arbitrate tier 5

**This section is retracted.** The gate below is recorded because it was
proposed and because the arithmetic is what killed it — not because it is in
force:

```
(never implemented)  projected(observed) is accepted  ⟺  |projected − observed| < tolerance
                                                        AND per-layer step > offset uncertainty
                                                      otherwise → observation wins, field degrades to ~
```

Corroboration is **declined, not deferred**. The reasons, in short: the offset it
tolerates is a 157 MiB *residual* rather than a measurement of anything, and the
gate cannot fail — a projection that degrades to `~` on disagreement while
otherwise agreeing with itself is untested, and where the per-layer step is
smaller than the offset's uncertainty the observation cannot discriminate at all.
The full argument, the calibration, and the six preconditions that would have to
change to reopen it are in [`concern-4-p2-plan.md`](../concern-4-p2-plan.md) §3.1
and §5. Tier 5's values stay `estimated` permanently; nothing promotes them.

**The calibration** (from the live worker):

```
projected : 10,616 (model) + 1,694 (context) + 505 (compute) = 12,815 MiB
observed  :                                                        12,972 MiB
gap       :                                                          157 MiB  (1.2 %)
per-layer step:                                                       ~80 MiB
```

The step is ~2× the gap, so the observation **discriminates the offload count
uniquely** — it is a real check, not a rubber stamp.

**The discriminator test is part of the gate.** Where the per-layer step is
*smaller* than the offset's uncertainty (small models, tiny layers), the
observation cannot discriminate, so the projection stands alone and renders
`~`. A check that cannot fail is not a check, and a check that cannot pass
should not be reported as having passed.

**On conflict the observation wins.** Not "the average", not "prefer the
projection with a penalty" — the measurement. This is the same reason rung 4
is indeterminate rather than "CPU".

## 7. What it cannot answer

- **Per-layer attribution.** The cgroup total cannot say which layers are
  resident. Neither can per-PID VRAM. Any per-layer claim is tier 5's
  projection, and it inherits tier 5's `~`.
- **Which tensor is where.** Only two buckets exist: host private RAM and
  device memory. The compute graph, the mmproj, the CUDA context and the
  weights all land in one of them.
- **Anything about a specific model when `sole === false`.**
- **The per-device breakdown** on a multi-GPU box: `serviceVramBytes` is
  summed across devices. A split between GPU 0 and GPU 1 is invisible here.
- **The CUDA-context offset's size.** The 157 MiB is a residual, not a
  measurement, and its stability is one of the open questions in
  [`concern-4-p2-plan.md`](../concern-4-p2-plan.md) §5.

## 8. Where the code is

| Piece | Location |
|---|---|
| Host script | `Service.qml:353` `serviceMemoryScript` |
| Device script | `Service.qml:373` `serviceVramScript` |
| Caps | `Service.qml:648-649` `capServiceMemory: 64`, `capServiceVram: 64` |
| Processes | `Service.qml:2978` `serviceMemoryProcess`, `:2999` `serviceVramProcess` |
| Host sink / fold | `Service.qml:2595` `_onServiceMemoryLine` / `:2602` `_finishServiceMemory` |
| Device sink / fold | `Service.qml:2614` `_onServiceVramLine` / `:2621` `_finishServiceVram` |
| Total | `Service.qml:2634` `_deriveServiceTotal` |
| Properties | `Service.qml:585-588` `serviceMemoryBytes`, `serviceVramBytes`, `serviceTotalBytes` |
| Attribution | `Service.qml:2269` `_placementMeasurements` |
| Placement decision | `Service.qml:1144` `_kvPlacement` |
| Scheduling | `Service.qml:1646-1650` in `refreshApi`, llama.cpp only |

`serviceMemoryBytes` and `serviceVramBytes` are **`double`, not `int`** —
deliberate, so a footprint above 2 GiB does not overflow a 32-bit QML int
(`Service.qml:585`).

Both parsers are tiny: the host one reads a single integer, the device one
expects a single `NNNN MiB` and `parseFloat`s it.

## 9. Under the resolver

```
checkTier4Values(pending):
    // service-global, not per-model: the readings are the whole cgroup's
    return pending ∩ { hostAnonBytes, deviceVramBytes, deviceTotalBytes,
                       soleAttribution }

fetchTier4Values():
    // ONE batched launch of both scripts — they run concurrently anyway
    return { memBytes: serviceMemoryBytes, vramBytes: serviceVramBytes }
```

Tier 4 is unusual in two ways the resolver must respect:

1. **Its fields are service-global, not per-model.** One observation answers
   for every loaded model — but only when `sole`. With several models loaded,
   the reading exists and is *unattributable*, which is a different state from
   "not yet read". Under the plan, unattributable means the placement fields go
   straight to `exhausted` unless a flag branch answers them.
2. **It is launched once per refresh, not per model.** The `wanted`-set
   intersection must therefore be computed across *all* pending fields of all
   models, not one model at a time. A per-model walk would relaunch it once per
   model for the same number.

## 10. Tests

Today the ladder is pinned only in its `below-KV` direction:
`e2e_mtp_draft.qml:163-165` asserts that host anon (100 MB) below a 200 MB
cache attributes the cache to no device. Nothing pins `mem >= kv`, which is
why the bug survived. Under the plan:

- **`tst_derivation.qml`**, `placement/*` group: all four rungs, each with a
  named `host anon` / `device mem` / `kv` triple, including the
  **`host anon >= KV` indeterminate** case that today returns `"CPU"`.
- **`placement/*` + `sole-false/*`**: every rung refuses when `sole === false`.
- **No `corroboration/*` group.** It was in the earlier draft and is **removed**:
  the gate cannot discriminate, so asserting it would enshrine a test that cannot
  fail. The calibration figures are still asserted — as *inputs to the declined
  decision*, not as a live gate — in [`concern-4-p2-plan.md`](../concern-4-p2-plan.md).
- **A regression test that the gemma triple is indeterminate**, using the real
  numbers (2,928.6 / 2,879.4 MiB) so the 49 MiB margin cannot be
  accidentally re-classified.
- **`bats` additions**: the two scripts' argv and output caps, the
  `c > 0` / no-output distinction, and `MemoryCurrent` being reachable only when
  `memory.stat` is not.

## 11. Gaps to close

1. **The four-rung ladder replacing `Service.qml:1155`.** Root cause of the KV
   placement bug.
2. **A `"GPU/CPU"` return value** from `_kvPlacement`, plus the totals logic in
   `ModelsSection.qml:211,215` that must handle it.
3. ~~**The corroboration gate and its calibration.**~~ **Dropped, not
   deferred.** Tier 5 does not exist to be gated yet, and when it does the gate
   will not be built — see §6 and
   [`concern-4-p2-plan.md`](../concern-4-p2-plan.md) for the decision and the six
   preconditions that would reopen it.
4. **Unload eviction** of the observation snapshot. Under the plan a
   re-load re-measures (~20 ms), which is the right trade.
5. **The `MemoryCurrent` path should be marked `~`** rather than exact, since
   it is known to double-count. Today it flows into `serviceMemoryBytes`
   indistinguishably from a cgroup reading.
