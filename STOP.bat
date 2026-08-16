@echo off
title Portable LLM - Stop

echo.
echo Stopping Portable LLM...
echo.

taskkill /IM llama-server.exe /F >nul 2>&1

echo.
echo Server stopped.
echo.

pause