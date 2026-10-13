@echo off
title GitHub Actions Runners (Desktop + Web)
pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0Start-Runners.ps1"
if %ERRORLEVEL% NEQ 0 (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Start-Runners.ps1"
)
timeout /t 3 >nul
