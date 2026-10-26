@echo off
setlocal EnableExtensions EnableDelayedExpansion
title Portable LLM - V3

cd /d "%~dp0"

echo ==========================================
echo          PORTABLE LLM - V3
echo ==========================================
echo.

REM Detect CPU features using Windows' OS-aware processor feature API.
REM Optional matching builds can be placed in:
REM   llama\avx2\llama-server.exe
REM   llama\avx\llama-server.exe
REM   llama\baseline\llama-server.exe
REM The baseline build should be compiled without AVX/AVX2 requirements.

set "CPU_LEVEL=UNKNOWN"
set "CPU_NOTE=Could not confirm AVX/AVX2 support."
set "SERVER="

for /f "tokens=1,* delims==" %%A in ('powershell -NoProfile -ExecutionPolicy Bypass -Command "$sig='[DllImport(\"kernel32.dll\", SetLastError=true)] public static extern bool IsProcessorFeaturePresent(int feature);'; Add-Type -MemberDefinition $sig -Name CpuCheck -Namespace Native -ErrorAction SilentlyContinue; $avx=[Native.CpuCheck]::IsProcessorFeaturePresent(18); $avx2=[Native.CpuCheck]::IsProcessorFeaturePresent(40); if($avx2){'CPU_LEVEL=AVX2'} elseif($avx){'CPU_LEVEL=AVX'} else {'CPU_LEVEL=BASELINE'}" 2^>nul') do (
    if /i "%%A"=="CPU_LEVEL" set "CPU_LEVEL=%%B"
)

if /i "!CPU_LEVEL!"=="AVX2" (
    set "CPU_NOTE=Windows reports AVX2 support."
    if exist "llama\avx2\llama-server.exe" set "SERVER=llama\avx2\llama-server.exe"
)
if not defined SERVER if /i "!CPU_LEVEL!"=="AVX" (
    set "CPU_NOTE=Windows reports AVX support, but not AVX2."
    if exist "llama\avx\llama-server.exe" set "SERVER=llama\avx\llama-server.exe"
)
if not defined SERVER if exist "llama\baseline\llama-server.exe" (
    set "SERVER=llama\baseline\llama-server.exe"
    set "CPU_NOTE=Using the baseline-compatible build."
)

REM Backward compatibility with the original one-binary folder layout.
if not defined SERVER if exist "llama\llama-server.exe" (
    set "SERVER=llama\llama-server.exe"
    set "CPU_NOTE=Using the default build; its CPU requirements cannot be verified from this script."
)

echo CPU capability: !CPU_LEVEL!
echo !CPU_NOTE!
echo.

if not defined SERVER (
    echo [ERROR] No compatible llama-server.exe was found.
    echo.
    echo Expected one of:
    echo   llama\avx2\llama-server.exe
    echo   llama\avx\llama-server.exe
    echo   llama\baseline\llama-server.exe
    echo   llama\llama-server.exe
    echo.
    pause
    exit /b 1
)

echo Selected server: !SERVER!
echo.

REM Show the selected llama.cpp build/version when supported.
echo llama.cpp build information:
"!SERVER!" --version 2>&1
echo.
echo Press any key to choose a model and start the server.
pause >nul

if not exist "models\*.gguf" (
    echo [ERROR] No GGUF models found in the models folder.
    pause
    exit /b 1
)

echo Available models:
echo.

set "count=0"
for %%F in ("models\*.gguf") do (
    if exist "%%~fF" (
        set /a count+=1
        echo [!count!] %%~nxF
        set "model!count!=%%~fF"
    )
)

if !count! EQU 0 (
    echo [ERROR] No GGUF models found!
    pause
    exit /b 1
)

echo.
set /p "choice=Select model number: "

REM Accept only a numbered model selection.
set "MODEL="
for /l %%N in (1,1,!count!) do (
    if "!choice!"=="%%N" set "MODEL=!model%%N!"
)

if not defined MODEL (
    echo [ERROR] Invalid selection.
    pause
    exit /b 1
)

echo.
echo Selected model: !MODEL!
echo Starting llama.cpp server on http://127.0.0.1:8080
echo Backend executable: !SERVER!
echo Keep this window open while using Portable LLM.
echo.

start "" "http://127.0.0.1:8080"

"!SERVER!" ^
    -m "!MODEL!" ^
    -c 4096 ^
    --host 127.0.0.1 ^
    --port 8080

set "SERVER_EXIT=%ERRORLEVEL%"
echo.
