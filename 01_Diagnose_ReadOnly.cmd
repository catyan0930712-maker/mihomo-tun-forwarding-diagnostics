@echo off
setlocal
chcp 65001 >nul
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\TunForwarding.ps1" -Mode Diagnose
set "result=%errorlevel%"
echo.
pause
exit /b %result%
