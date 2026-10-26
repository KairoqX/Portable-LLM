# Audit of the Portable-LLM CPU-compatibility claims

Method: re-derive each claim from the shipped files and the code (static analysis only; no Windows, no PowerShell, nothing
executed). Reproduce: `python3 tests/test_audit.py`, `python3 tools/trace_callers.py llama/llama-server-impl.dll 1803987a0`.

| # | Earlier claim | Verdict | Evidence / change |
|---|---|---|---|
| 1 | Bundle uses runtime-scored per-ISA CPU DLLs | **Justified** | 14 DLLs export `ggml_backend_score`; `ggml.dll` loader disassembly: call score, keep only strictly greater, 0 never wins |
| 2 | Ryzen 3 5300U should load `haswell` | **Expectation only** | Not hard-coded anywhere (`haswell` appears only in the variant table). Prediction = max scorer result, run on the host. Scorer decoded for haswell/skylakex/zen4/sapphirerapids; Zen 2 CPUID bits not observable here |
| 3 | Variant DLL contents match their names | **Justified** (partly) | Instruction scan consistent for all 14; scorer masks decoded for 4 variants; VBMI/AVX-VNNI/AMX_TILE unconfirmed |
| 4 | "VERIFIED BY FILE HASH" | **Overstated -> fixed** | Hashes are compared with a manifest generated from the same files, unsigned, stored beside them: integrity only, no provenance. Wording changed. Real holes fixed: an empty/invalid manifest verified anything; only `ggml-cpu-*` extras were flagged (loader scans `ggml-*.dll`); no schema/path/SHA-format checks; no integrity check of the manifest (sidecar added; an attacker who rewrites binary+manifest+sidecar still wins - tested and documented) |
| 5 | Manifest covers every relevant binary | **Justified** | Static import closure of `llama-server.exe` + every `ggml-*.dll` (9 core + 14 variants); analyzer now refuses to write a manifest that misses one. Not covered: other tool exes, and system DLLs (MSVCP140/VCRUNTIME140 are **not** bundled) |
| 6 | Changed/missing/unexpected file invalidates verification | **Justified after fixes** | Tested on mutated copies of the real files (all 4 named core DLLs, a variant, missing, extra `ggml-*.dll`). TOCTOU remains (files are hashed, later executed) |
| 7 | `system_info` flags show the ISA in use | **Justified** | `ggml_cpu_has_*` are constants per DLL. Not yet confirmed that the line is printed on your machine |
| 8 | Loaded CPU backend is identified from llama.cpp output | **Unproven -> made conservative** | No runtime log exists; format string exists in `ggml.dll`. Backend is UNKNOWN unless exactly one distinct CPU path is logged; several = ambiguous = UNKNOWN. Nothing is inferred from host CPU or file names |
| 9 | Host features via Windows API + scorer | **Corrected** | Scorer checks CPUID bits only (no XGETBV). Windows "no" now overrides scorer "yes"; unknown stays unknown |
| 10 | "Ready" detection | **Bug -> fixed** | This build prints `listening on %s` (maybe without `http://`); old regex could miss it. Banner now says HTTP listening (model may still be loading) and findings are re-evaluated when `system_info`/backend lines or the first request arrive |
| 11 | AVX2 routines "unidentified" | **Refined** | Located in BoringSSL-linked crypto code (self-test strings); no CPU-feature test on the resolvable call chain. See hypotheses below |
| 12 | `--cors-origins localhost` | **Option exists** | String evidence only; runtime effect unverified |

## Findings vs hypotheses on the AVX2 routines
Findings: two ~380-instruction all-VEX routines with 256-bit integer ops (one per DLL, same code); reachable through ~30 direct
callers up to depth 7 into crypto-self-test code; legacy SSE code surrounds them (not a globally-AVX2 translation unit); no
feature-test on the direct chain. Hypotheses: only used by self-test/hash code; may be dead in normal serving. Unresolved:
indirect calls (vtable/function pointers), so reachability and guarding are **not established**. Static analysis cannot prove
runtime safety; the AVX2 minimum stays as a conservative gate.

## Tests
Run here: `tests/test_audit.py` (53 checks: evidence re-checks on real binaries; mirrored rules on the real manifest and mutated
copies), `tests/test_logic.py` (28), `tools/lint_scripts.py` (heuristic). Not run (no PowerShell/Windows): `tests/Run-Tests.ps1`
(actual PowerShell functions and launcher scenarios), the host probe, live log capture, `--cors-origins` behaviour.
The Python Part-B tests mirror the PowerShell rules; they can drift from the .ps1 code, which is why Run-Tests.ps1 repeats them.

## Known limits
Integrity is not provenance (compare with the upstream release checksum yourself); `build-manifest.json.sha256` breaks if line
endings are rewritten (git autocrlf); the probe loads each variant DLL like llama.cpp does; hashing delays start-up.
