@echo off
title DevOps Live Server Audit
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0verify-remote.ps1"
pause
