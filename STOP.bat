@echo off
title Portable LLM - Stop
echo.
tasklist /FI "IMAGENAME eq llama-server.exe" 2>nul | find /I "llama-server.exe" >nul
if errorlevel 1 (
    echo No running llama-server.exe was found.
    goto :done
)
echo Stopping llama-server.exe ...
taskkill /IM llama-server.exe /F >nul 2>&1
if errorlevel 1 (
    echo [ERROR] Could not stop llama-server.exe. Try running STOP.bat as administrator.
) else (
    echo Server stopped.
)
:done
echo.
pause
