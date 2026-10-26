@echo off
setlocal EnableExtensions EnableDelayedExpansion
title Portable LLM - V5
cd /d "%~dp0"

set "SERVER="
set "CPU_LEVEL=UNKNOWN"
set "CPU_NAME=Unknown CPU"

echo ==========================================
echo          PORTABLE LLM - V5
echo ==========================================
echo.

if not exist "models\*.gguf" (
    echo [ERROR] No GGUF models found in the models folder.
    pause
    exit /b 1
)

for /f "usebackq delims=" %%A in (`powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0cpu-detect.ps1" 2^>nul`) do set "CPU_LEVEL=%%A"
for /f "usebackq delims=" %%A in (`powershell -NoProfile -ExecutionPolicy Bypass -Command "(Get-CimInstance Win32_Processor | Select-Object -First 1 -ExpandProperty Name)" 2^>nul`) do set "CPU_NAME=%%A"

REM Folder names do not prove compile flags. Prefer the matching folder only
REM if the project maintainer has independently verified the binary in it.
if /i "!CPU_LEVEL!"=="AVX2" if exist "llama\avx2\llama-server.exe" set "SERVER=llama\avx2\llama-server.exe"
if not defined SERVER if /i "!CPU_LEVEL!"=="AVX" if exist "llama\avx\llama-server.exe" set "SERVER=llama\avx\llama-server.exe"
if not defined SERVER if exist "llama\baseline\llama-server.exe" set "SERVER=llama\baseline\llama-server.exe"
if not defined SERVER if exist "llama\llama-server.exe" set "SERVER=llama\llama-server.exe"

if not defined SERVER (
    echo [ERROR] No llama-server.exe found.
    pause
    exit /b 1
)

echo CPU: !CPU_NAME!
echo OS-enabled instruction support: !CPU_LEVEL!
echo Selected executable: !SERVER!
echo Build ISA verification: NOT VERIFIED
echo.
echo CPU feature detection cannot establish which instruction set the binary uses.
echo This launcher will record actual llama.cpp timing lines after each request.
echo.

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

if not exist "logs" mkdir "logs"
for /f %%T in ('powershell -NoProfile -Command "Get-Date -Format yyyyMMdd-HHmmss"') do set "STAMP=%%T"
set "LOGFILE=logs\session-!STAMP!.log"

echo.
echo ==========================================
echo          DIAGNOSTIC SUMMARY
echo ==========================================
echo CPU: !CPU_NAME!
echo OS-enabled instruction support: !CPU_LEVEL!
echo Executable: !SERVER!
echo Build ISA: NOT VERIFIED
echo Model: !MODEL!
echo Server: http://127.0.0.1:8080
echo Log file: !LOGFILE!
echo Generation speed will be extracted from llama.cpp eval-time lines.
echo ==========================================
echo.
echo Opening local interface. Keep this window open.
start "" "http://127.0.0.1:8080"

REM The PowerShell monitor displays the live server output, saves it to a log,
REM and prints a concise timing summary when the server exits.
"!SERVER!" -m "!MODEL!" -c 4096 --host 127.0.0.1 --port 8080 2>&1 | powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0monitor.ps1" -LogPath "%CD%\!LOGFILE!"
set "PIPE_EXIT=!ERRORLEVEL!"

echo.
echo Server/monitor ended. Full log: !LOGFILE!
echo Note: Windows CMD reports the pipeline's last command exit code, not necessarily llama-server's.
pause
exit /b !PIPE_EXIT!
