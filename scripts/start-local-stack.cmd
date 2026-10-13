@echo off
title DevOps Monitoring Stack - Local WSL2
pwsh -NoProfile -ExecutionPolicy Bypass -File "%~dp0start-local-stack.ps1"
if %ERRORLEVEL% NEQ 0 (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0start-local-stack.ps1"
)
pause
