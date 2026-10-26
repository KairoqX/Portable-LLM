@echo off
setlocal EnableExtensions
title Portable LLM
cd /d "%~dp0"

where powershell >nul 2>&1
if errorlevel 1 (
    echo [ERROR] Windows PowerShell was not found on this PC, so the launcher cannot run.
    pause
    exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0launcher.ps1" %*
set "RC=%ERRORLEVEL%"
echo.
if not "%RC%"=="0" echo [Portable LLM] Finished with exit code %RC%. Details are in the logs folder.
pause
exit /b %RC%
