@echo off
setlocal EnableExtensions EnableDelayedExpansion
title Portable LLM - V4
cd /d "%~dp0"

set "SERVER="
set "CPU_LEVEL=UNKNOWN"
set "CPU_NAME=Unknown CPU"
set "BUILD_STATUS=UNVERIFIED"
set "BUILD_INFO="

 echo ==========================================
echo          PORTABLE LLM - V4
echo ==========================================
echo.

if not exist "models\*.gguf" (
    echo [ERROR] No GGUF models found in the models folder.
    pause
    exit /b 1
)

REM Correct Windows feature IDs: 39 = AVX, 40 = AVX2.
REM IsProcessorFeaturePresent checks OS-enabled processor support, not the
REM instruction set used to compile a particular executable.
for /f "usebackq delims=" %%A in (`powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0cpu-detect.ps1" 2^>nul`) do set "CPU_LEVEL=%%A"
for /f "usebackq delims=" %%A in (`powershell -NoProfile -ExecutionPolicy Bypass -Command "(Get-CimInstance Win32_Processor | Select-Object -First 1 -ExpandProperty Name)" 2^>nul`) do set "CPU_NAME=%%A"

REM Prefer explicitly named builds, but do not claim that folder names prove
REM compile flags. These builds must be supplied and verified by the maintainer.
if /i "!CPU_LEVEL!"=="AVX2" if exist "llama\avx2\llama-server.exe" set "SERVER=llama\avx2\llama-server.exe"
if not defined SERVER if /i "!CPU_LEVEL!"=="AVX" if exist "llama\avx\llama-server.exe" set "SERVER=llama\avx\llama-server.exe"
if not defined SERVER if exist "llama\baseline\llama-server.exe" set "SERVER=llama\baseline\llama-server.exe"
if not defined SERVER if exist "llama\llama-server.exe" set "SERVER=llama\llama-server.exe"

if not defined SERVER (
    echo [ERROR] No llama-server.exe found.
    echo Expected llama\llama-server.exe or a build in llama\avx2, llama\avx, or llama\baseline.
    pause
    exit /b 1
)

if /i "!SERVER!"=="llama\avx2\llama-server.exe" set "BUILD_STATUS=UNVERIFIED - AVX2 FOLDER"
if /i "!SERVER!"=="llama\avx\llama-server.exe" set "BUILD_STATUS=UNVERIFIED - AVX FOLDER"
if /i "!SERVER!"=="llama\baseline\llama-server.exe" set "BUILD_STATUS=UNVERIFIED - BASELINE FOLDER"
if /i "!SERVER!"=="llama\llama-server.exe" set "BUILD_STATUS=UNVERIFIED - DEFAULT BINARY"

 echo CPU: !CPU_NAME!
echo OS-enabled instruction support: !CPU_LEVEL!
echo Selected executable: !SERVER!
echo Build instruction set: !BUILD_STATUS!
echo.
echo IMPORTANT: CPU support and the executable's compile flags are different.
echo This launcher cannot prove the binary's compile-time instruction set from
 echo its filename or the standard --version output alone.
echo.

if not defined PORTABLE_LLM_ALLOW_UNVERIFIED (
    set "CONFIRM="
    set /p "CONFIRM=Continue with this unverified build? Type YES to continue: "
    if /i not "!CONFIRM!"=="YES" (
        echo.
        echo [STOPPED] No model was started because build compatibility is unverified.
        echo Verify the binary's build flags or provide a known-compatible build.
        pause
        exit /b 2
    )
)

echo.
echo llama.cpp build information:
"!SERVER!" --version 2>&1
echo.

set "count=0"
echo Available models:
for %%F in ("models\*.gguf") do if exist "%%~fF" (
    set /a count+=1
    echo [!count!] %%~nxF
    set "model!count!=%%~fF"
)
if !count! EQU 0 (
    echo [ERROR] No GGUF models found.
    pause
    exit /b 1
)

echo.
set /p "choice=Select model number: "
set "MODEL="
for /l %%N in (1,1,!count!) do if "!choice!"=="%%N" set "MODEL=!model%%N!"
if not defined MODEL (
    echo [ERROR] Invalid selection.
    pause
    exit /b 1
)

echo.
echo ==========================================
echo              DIAGNOSTIC SUMMARY
echo ==========================================
echo CPU: !CPU_NAME!
echo OS-enabled instruction support: !CPU_LEVEL!
echo Selected executable: !SERVER!
echo Build ISA verification: NOT VERIFIED
echo Model: !MODEL!
echo Server: http://127.0.0.1:8080
echo Performance: llama.cpp prints prompt/evaluation rates in this window
 echo after requests; check the eval rate (tokens/second) for generation speed.
echo ==========================================
echo.
echo Opening local interface. Keep this window open.
start "" "http://127.0.0.1:8080"

"!SERVER!" -m "!MODEL!" -c 4096 --host 127.0.0.1 --port 8080
set "SERVER_EXIT=!ERRORLEVEL!"
echo.
echo ==========================================
echo       LLM SERVER STOPPED
echo ==========================================
echo Exit code: !SERVER_EXIT!
pause
exit /b !SERVER_EXIT!
