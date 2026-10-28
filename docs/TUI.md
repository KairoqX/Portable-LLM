# Terminal dashboard (TUI)

The terminal is a **monitoring and control dashboard only**. The chat itself stays in the browser (llama.cpp web UI,
`http://127.0.0.1:8080`). Nothing from a conversation is shown in the terminal.

## Files
| File | Role |
|---|---|
| `lib/PortableLlm.Core.ps1` | Pure logic: parsing, session statistics, server-state machine, memory thresholds, error hints |
| `lib/PortableLlm.Sys.ps1` | Windows facilities: RAM (`GlobalMemoryStatusEx`), VT console mode, kill-on-close Job Object |
| `lib/PortableLlm.Tui.ps1` | Rendering only: capability detection, theme, `Build-PLlmFrame` (view model in, lines out), diff painter, key map |
| `monitor.ps1` | Process start/stop, log tailing, `/health` polling, state + events, the loop |
| `tests/dev/` | Linux/macOS dev harness (fake server + pseudo-terminal test). Not a Windows test |

## What is shown, and where each number comes from
* **Server state** (Starting / Loading Model / Ready / Error / Stopped): `GET /health` over HTTP (503 = loading,
  any answer below 500 = up), falling back to llama.cpp log lines; process exit decides Error/Stopped.
* **Model / context**: file name and size from the picked file; context is the value llama.cpp *reported*
  (`n_ctx`), or "requested" until it reports one.
* **Performance**: llama.cpp timing lines only. Latest request and token-weighted session averages are separate.
  "Failed/incomplete" counts requests whose timing lines stopped early; a request that prints nothing is not visible.
* **System**: CPU/flags from the existing host probe (OS-enabled features), RAM from Windows, server working set.
  Memory thresholds: **warn** at 85% used or <1.5 GB free, **critical** at 95% used or <0.75 GB
  (with 3-point hysteresis). Defined in `Core.ps1` (`$script:PLlmMemThresholds`).
* **Compatibility**: *expected* variant = bundled scorer; *runtime* = llama.cpp's own "loaded CPU backend" line.
  Missing or ambiguous evidence shows `Unknown` plus the reason. Integrity text says "hash check only; unsigned"
  and never claims authenticity or provenance.

## Keys
`O` open browser (never restarts the server) - `D` diagnostics - `L` log path (press `L` again within 10 s to open the
folder; it is never opened automatically) - `R` redraw - `Q` / Ctrl+C stop the server and quit.
If the server dies by itself the dashboard stays open (Error/Stopped, hint shown) until `Q`.

## Terminal fallbacks
| Situation | Behaviour |
|---|---|
| Normal Windows 10+/Windows Terminal | ANSI colors, Unicode bars, alternate screen (your earlier text is restored on exit) |
| `NO_COLOR` set, `PORTABLE_LLM_COLOR=0`, `PORTABLE_LLM_UI=plain` | In-place dashboard, no color codes |
| `PORTABLE_LLM_ASCII=1` | `#`/`-` bars, no Unicode |
| `PORTABLE_LLM_COLORS=16` | 16-color palette instead of 256 |
| Console without VT support | In-place redraw with cursor positioning, plain text (clears the window once) |
| Output/input redirected, or `PORTABLE_LLM_UI=log` | No dashboard: the original line-by-line output |
| Window under 44x9 | One-line status with `[Q]` |

## Orphan protection
The server is attached to a Job Object with kill-on-close, so Windows ends it if the launcher window is closed or the
PowerShell process dies. `Q` kills it explicitly, waits, checks the port is free, and falls back to `taskkill /T`.
If the job cannot be created, Diagnostics says so and `STOP.bat` remains the cleanup path.

## Tests
* `python tools/lint_scripts.py`, `python tests/test_logic.py`, `python tests/test_audit.py` - anywhere.
* `powershell -File tests\Run-Tests.ps1` - on Windows runs everything. Elsewhere the launcher scenarios print `SKIP`.
* `python tests/dev/pty_dashboard_test.py pwsh` - Linux/macOS with PowerShell 7 and `pyte`.

## Manual Windows test steps (not executed by the author)
Run each in `cmd` / Windows Terminal, in a copy of the folder with a small .gguf in `models\`.
1. **Startup and loading**: `START.bat`, pick the model. Header shows `Starting`, then `Loading Model`, then `Ready`; the
   browser opens only at `Ready`. Context shows "(reported by llama.cpp)" once known.
2. **No completed requests**: before chatting, Performance shows `Waiting for first request` (no `N/A`).
3. **One / several requests**: send 1 then 3 messages in the browser. Compare Prompt/Generate rates with the browser's
   own timing; `Session` averages must sit between the min and max of the requests; counters increase.
4. **Low memory**: open memory-hungry programs until free RAM drops under 1.5 GB: yellow alert + warn event; under
   0.75 GB: red. Close them: "Memory pressure cleared".
5. **Unknown / mismatched backend**: Runtime shows `Unknown` with a reason before llama.cpp logs its backend. To force a
   mismatch use `D` after temporarily renaming the CPU DLLs (the build check must then report UNVERIFIED/rejected).
6. **Missing or modified bundle file**: edit one byte of `llama\llama-server-impl.dll` or add `llama\ggml-vulkan.dll`; the
   launcher must refuse or mark the build UNVERIFIED and the dashboard Build row must say so.
7. **Resize**: drag the window from wide to narrow and short. Layout switches columns/compact/too-small, no duplicate rows.
8. **Browser shortcut**: press `O` several times: one browser tab per press, Task Manager shows still one `llama-server`.
9. **Graceful shutdown**: `Q`, then again with Ctrl+C, then close the window with the X. In all three Task Manager must
   show no `llama-server.exe`, and `netstat -ano | findstr :8080` must be empty.
10. **No automatic log folder**: run the whole session; Explorer never opens. `L` shows the path; a second `L` opens it.
11. **No ANSI**: `set NO_COLOR=1` then `START.bat` (no colors); `set PORTABLE_LLM_UI=log` (old line output); on Windows 7/8 or
    an old console host expect the plain in-place mode.
12. **CPU use**: let it idle on Ready for a minute and read the PowerShell process in Task Manager (expect low single digits).
