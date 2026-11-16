@echo off
setlocal
powershell.exe -NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0scripts\Start-Diagnostics.ps1"
if errorlevel 1 pause
