@echo off
setlocal EnableDelayedExpansion
title Portable LLM - V2

cd /d "%~dp0"

echo ==========================================
echo          PORTABLE LLM - V2
echo ==========================================
echo.

if not exist "llama\llama-server.exe" (
    echo [ERROR] llama-server.exe not found!
    pause
    exit /b 1
)

echo Available models:
echo.

set count=0

for %%F in ("models\*.gguf") do (
    set /a count+=1
    echo [!count!] %%~nxF
    set "model!count!=%%~fF"
)

if !count! EQU 0 (
    echo [ERROR] No GGUF models found!
    pause
    exit /b 1
)

echo.
set /p choice=Select model number: 

if not defined model%choice% (
    echo Invalid selection.
    pause
    exit /b 1
)

set "MODEL=!model%choice%!"

echo.
echo Selected: %MODEL%
echo.
echo Starting llama.cpp...
echo.

start "" "http://127.0.0.1:8080"

"llama\llama-server.exe" ^
    -m "%MODEL%" ^
    -c 4096 ^
    --host 127.0.0.1 ^
    --port 8080

echo.
echo ==========================================
echo       LLM SERVER STOPPED
echo ==========================================
echo.
pause