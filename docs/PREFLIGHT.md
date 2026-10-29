# Preflight: build selection, memory decision, runtime evidence

Nothing here is a proof of safety. These are conservative checks made **before** the server starts, so that clearly
impossible or clearly unsafe launches are refused with a reason, and uncertain ones are explained.

## 1. CPU compatibility controls which build starts
`Select-PLlmBuild` (lib/PortableLlm.Core.ps1) is the only selector; the launcher calls it once. Concepts are kept apart:
host CPU features (Windows API: true / false / unknown) - features a build requires (from its **verified manifest**) -
scorer prediction (bundled `ggml_backend_score`, "Expected") - the selected build - the backend llama.cpp reports at runtime.

* COMPATIBLE = manifest verified **and** every recorded minimum feature is confirmed `true` on this host.
* A feature the host lacks (`false`) or cannot confirm (`unknown`) -> the build is REJECTED. Unknown is never "supported".
  A Windows `false` is never overridden by a scorer `true`.
* UNVERIFIED (no manifest, or files differ from it) is only a fallback when nothing is COMPATIBLE. A build with no manifest
  records no requirements; this is stated, not guessed from file or CPU names. If a valid manifest recorded a minimum and the
  host support is unknown/false, it is REJECTED even when unverified.
* Several COMPATIBLE builds: highest `preference`, then name (deterministic).
* No usable build: nothing is started, exit code 4, and the summary lists each build's reason.
* Override (`-AllowUnverified` / `PORTABLE_LLM_ALLOW_UNVERIFIED=1`): picks the least risky rejected build (rejected only for
  *unknown* support before one the host is *known* to lack), prints a red OVERRIDE banner, keeps the status REJECTED
  and never uses the "files match" wording. The dashboard shows a red OVERRIDE alert.

## 2. Memory preflight (PASS / WARN / BLOCK)
Collected: total/available physical RAM and commit headroom (`GlobalMemoryStatusEx`), model file size, context length, and the
GGUF **header** (`Read-PLlmGgufMetadata`: reads only the key/value section, stops at the first `tokenizer.*` key; a multi-GB
model costs a few KB of I/O; it never throws).

Estimate (`Get-PLlmMemoryEstimate`):
* weights = file size (llama.cpp memory-maps the file)
* KV cache = `block_count * context * kv_heads * (key_len + value_len) * 2 bytes` (f16 cache). Check: 28 layers, 8 KV heads,
  128-dim, 4096 ctx = 448 MiB, which matches llama.cpp. Per-layer head arrays use the largest value (conservative).
* overhead = 512 MiB + 3 % of weights (compute buffers, graph, server) - a **heuristic**
* if the header is unusable: KV is guessed as 20 % of the weights per 4096 context, confidence becomes `low`, and the note
  "KV cache size could not be computed ... uncertain" is shown.

Decision (`Get-PLlmMemoryVerdict`; constants in `$script:PLlmMemPolicy`):
| Result | When | Remedies shown |
|---|---|---|
| BLOCK (static) | weights + known KV exceed total RAM minus a Windows reserve (max 1 GB, 10 %) | smaller model/quant, lower CONTEXT |
| BLOCK (dynamic) | free RAM now is below 75 % of weights + KV | close programs, retry, lower CONTEXT |
| WARN (tight) | expected need + headroom (max 512 MB, 5 %) exceeds free RAM | close programs, lower CONTEXT, smaller model |
| WARN (commit) | KV + buffers exceed Windows commit headroom | close programs, enlarge page file |
| WARN (unmeasured) | memory could not be read (or the provider threw) | check Task Manager |
| PASS | otherwise | - |

* BLOCK does **not** start the server (exit code 6, "No server process was created").
* Override: `-AllowLowMemory`, `PORTABLE_LLM_ALLOW_LOW_MEMORY=1`, or typing `RUN ANYWAY` when asked (interactive only).
* Memory is re-read immediately before launch; if it got worse the new result is shown and a new BLOCK stops the start.
  An unchanged result is printed once.
* During the run, memory-pressure changes appear once in Recent activity. Running requests are never interrupted, and
  nothing is killed or deleted.

Limitations: free RAM includes reclaimable cache; other programs can grow after the check; the overhead and fallback KV
figures are heuristics; sliding-window / recurrent models can need less (the KV estimate is then high) or have no usable
header (low confidence); a GPU backend's memory is not considered. A PASS is not a guarantee, a BLOCK can be wrong for a
machine that pages well - hence the explicit override.

## 3. Integrity (not authenticity)
`build-manifest.json` plus its `.sha256` sit beside the binaries. They detect accidental or casual changes. An attacker who
can replace the DLLs, manifest and sidecar together defeats them. Wording stays "files match the local manifest (hash check
only; unsigned)". Checked: schema, required fields, safe file names (no separators, `..`, device names, wildcards, trailing
dot/space), 64-hex digests, every listed file present and matching, unlisted `ggml-*.dll`, sidecar present and valid, and
empty manifests never verify. Not checked: other unlisted DLLs (e.g. a planted system-DLL name next to the exe), and a file
swapped between verification and load.

## 4. Runtime evidence
Header states: Starting -> Loading Model -> Ready -> Error/Stopped. A listening socket alone is *Loading Model*;
`GET /health` (503 = loading, other answers < 500 = up) or llama.cpp's own "all slots are idle"/"model loaded" line makes it
*Ready*. Under Ready the detail line says "waiting for first request", "request in progress" (from `... | task N |
processing task` / `... | task N | stop processing`) or "idle". The backend stays `Unknown` until a `loaded CPU backend` line
appears, becomes `Unknown (ambiguous)` for several different paths, and is compared with the prediction only when both are
known. "Failed" requests are counted only from timing evidence (incomplete sequences); this build logs no HTTP status.

## 5. Test seam
`PORTABLE_LLM_TEST_MEMORY="totalBytes,availBytes[,commitAvailBytes]"` replaces the real memory reading (malformed -> unmeasured).
Used only by tests; do not set it normally.
