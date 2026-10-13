@echo off
title GitHub Actions Runner - zeslownikiem (Unified Org Runner)
pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0Start-Runners.ps1"
if %ERRORLEVEL% NEQ 0 (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Start-Runners.ps1"
)
timeout /t 3 >nul
