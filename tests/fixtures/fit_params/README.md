# `llama-fit-params` output fixtures (Tier 5)

Golden captures of `llama-fit-params --fit off --fit-print on` so a toolchain
change fails a test loudly instead of silently mis-parsing the numbers the panel
shows. Recorded per backend and visible-GPU count.

## Capturing

```bash
llama-fit-params --fit off --fit-print on -ngl 40 -m /path/to/model.gguf \
                 -ctk q8_0 -ctv q8_0 -c 32768 > out.txt 2> out.err.txt
echo "exit=$?"
```

Record **both** channels: the preamble is printed on **stderr**, the rows on
**stdout**, so a stdout-only reader misses the header entirely.

## `cuda-1` — 1 visible GPU, `0.3.0-dev (build 10729, commit 977b5c2)`

| File | argv | exit |
|---|---|---|
| `ngl40-q8_0-ctx32768.txt` | `-ngl 40 -ctk q8_0 -ctv q8_0 -c 32768`, Qwen3.8-27B IQ4_XS | 0 |
| `ngl0-tiny-ctx0.txt` | `-ngl 0`, TinyStories-656K Q8_0 (model's own context) | 0 |
| `abort-mmproj-exit134.txt` | `-ngl 0 -m mmproj-…-f16.gguf` | 134 |

## Format, as observed

```
llama_fit_params: printing estimated memory in MiB to stdout (device, model, context, compute) ...
CUDA0 8692 767 551
Host 5915 470 62
```

- **Units are integer MiB**, which is why every Tier-5 value is permanently
  `estimated` (`~`): up to ~1 MiB is discarded per cell before the value reaches
  the parser.
- **Column order is `device model context compute`**, per the preamble. The
  `context` column is the KV bytes — a 4096-token `f16` cache printing `2` is
  2 MiB to the byte, which is the only proof of that column's meaning.
- **Device rows are zeroed, not omitted, at `-ngl 0`** (`CUDA0 0 0 4`), so a zero
  cell is a real reading and not a missing one.
- **Rows carry trailing whitespace** (`CUDA0 8692 767 551 `), so the parser trims.
- **No total row was observed.** The parser still recognises and skips one
  (`total`/`all`/`sum`): a double-counted total is silently wrong, not loudly
  wrong.
- Only `Host` is host. Any unrecognised device name defaults to the **device**
  side, deliberately — a device row counted as host is an unrecoverable split
  error, while a host row counted as a device shows up as an implausible total.

## Aborts (all degrade to "no answer", never a zero total)

| Cause | Exit | Recovery |
|---|---|---|
| not a loadable model (e.g. `mmproj-*.gguf`) | **134** (`std::runtime_error: failed to load model`) | decline the three Tier-5 fields → `—` |
| invalid `-ctk`/`-ctv` value | 1, usage on stderr | the parser drops unsupported dtypes before the run, so this should not happen |
| no `--model` | 1, `error: --model is required` | never from `_buildFitArgv`; a quoting bug, fail the test loudly |
| tool not installed / not executable | **97** (the wrapper, not the tool) | permanent: cached, every Tier-5 field declined |