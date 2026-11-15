@echo off
setlocal
set "HERE=%~dp0"
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%HERE%src\PerfCapture.ps1"
