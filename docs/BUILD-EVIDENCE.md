# What can and cannot be established about the bundled llama.cpp binaries

Analysis date: 2026-10-26. Method: static inspection of the files in `llama/` (PE headers, exports, ASCII strings,
GNU objdump 2.42 disassembly). **Nothing was executed** - no Windows machine or PowerShell was available.
Reproduce with `python3 tools/analyze_bundle.py llama` (writes the data behind `llama/build-manifest.json`).

## Findings

1. **It is not "one generic binary".** `llama-server.exe` is a 9 KB launcher stub that loads `llama-server-impl.dll`.
   The bundle is a *dynamic-backend* build: 14 CPU kernel sets (`ggml-cpu-x64`, `sse42`, `sandybridge`, `ivybridge`,
   `piledriver`, `haswell`, `alderlake`, `skylakex`, `cannonlake`, `cascadelake`, `icelake`, `cooperlake`, `zen4`,
   `sapphirerapids`). Each exports `ggml_backend_score()`; `ggml.dll` contains the loader strings
   (`loaded %s backend from %s`, `GGML_BACKEND_PATH`). Confirmed in `ggml.dll` disassembly: each DLL is loaded, `ggml_backend_score` is called, and the result replaces the
   current best only if strictly greater (0 never wins; ties keep the first enumerated). The scorers read CPUID bits only
   (no XGETBV). So the CPU kernels are chosen at run
   time, not by the file name of the .exe - the premise "generic .exe = scalar path" does not apply to this bundle.
2. **Build identity (strings):** `3cb7ffb1a`, `Clang 20.1.8`, `0.1.0-dev` found in `llama-common.dll`, `llama-server-impl.dll`,
   `llama.dll`, `ggml-base.dll` - consistent with the numbers you reported. Build number 10453 was taken from your report.
3. **Per-variant instructions match the variant names** (all 14 consistent, see `build-manifest.json`):
   `haswell` contains AVX2 + FMA + F16C + BMI2 and no AVX-512; `piledriver` FMA/F16C but no AVX2; `sandybridge` AVX only;
   the AVX-512 variants contain zmm code; `cooperlake`/`zen4` contain BF16, `cascadelake`... VNNI, `sapphirerapids` AMX.
   Not confirmed individually: AVX512_VBMI, AVX_VNNI, AMX_TILE.
4. **Your CPU (Ryzen 3 5300U, Zen 2: AVX2/FMA/F16C/BMI2, no AVX-512)** should therefore load `haswell`. This is a
   *prediction*; the launcher prints the variant llama.cpp actually reports. Radeon iGPU: no Vulkan/HIP backend DLL is
   bundled, so inference is CPU-only.
5. **The "generic" core DLLs are not baseline x86-64.** `llama-server-impl.dll` and `llama-common.dll` each contain a
   ~380-instruction routine made only of VEX instructions incl. 256-bit integer ops (AVX2) (entry 0x1803987a0 / 0x1803fbca0).
   *Finding (tools/trace_callers.py):* its callers lead into code that references BoringSSL crypto self-test strings
   (`AES-GCM-decrypt KAT`, `DRBG Clear KAT`, `boringssl-src/crypto/...`); on the statically resolvable call chain no CPU-feature
   test was found (neither the C-runtime flag nor a widely-read global); the surrounding code is mixed legacy-SSE/VEX, so only
   specific functions are AVX2-compiled. *Hypotheses, not findings:* it is a hash/Keccak helper that is only reached from the
   crypto self-test path; BoringSSL's own CPU dispatch is absent in this build. *Unresolved:* indirect calls, so "no caller
   found" does not prove the routine is unreachable or unguarded. Smaller VEX regions look like MSVC STL helpers; the four
   traced instances branch on a CPUID/XGETBV-derived flag. Consequence: AVX2 is used as a conservative minimum; this is not a
   proof that a pre-AVX2 CPU would crash, nor that an AVX2 CPU is safe in every path.
6. **`--cors-origins` exists in this build**, with the special value `localhost` (help text strings), as does the exact
   warning text you saw.

## Not established

- That any instruction is never executed on a CPU lacking it (static scan shows presence, not execution).
- Actual runtime behaviour on Windows, including whether `ggml_backend_score` probing from PowerShell works on your PC.
- Whether the 7.3 vs 7.9 tok/s variation has any CPU-optimisation cause. Generation of a ~2 GB Q4_K_M model is normally
  limited by RAM bandwidth, and single-channel laptop DDR4 is slow; thermals/power plan/background load also move it.
  Nothing here shows a wrong-ISA build. (Rough bound, assumptions unverified: ~2 GB model / ~20-25 GB/s peak
  single-channel bandwidth = ~10-12 tok/s ceiling.)
- Note on the report's numbers: 197 tokens / 26.855 s = 7.34 tok/s, not 7.30. The launcher prints llama.cpp's own figure and
  adds the recomputed one when they differ by more than rounding.

## Added by the audit (see docs/AUDIT.md)

- `ggml_cpu_has_*` exports are constants per variant (haswell: AVX2=1, AVX512=0; x64: AVX2=0), so the `system_info` flags
  printed by llama.cpp describe the *loaded DLL's build*, not the host.
- No real runtime log exists in the project. The `loaded %s backend from %s` and `system_info: n_threads =` formats exist in
  the binaries, but whether the loaded-backend line is printed once (winner only) is unverified; the launcher therefore reports
  the backend as UNKNOWN unless exactly one distinct CPU backend path is logged.
- The manifest is local integrity only: generated from the files it describes, unsigned, stored beside them. Only
  `libomp140.x86_64.dll` is Authenticode-signed.
- `llama\` does not bundle `MSVCP140.dll`/`VCRUNTIME140*.dll`; the PC needs the Visual C++ runtime.
