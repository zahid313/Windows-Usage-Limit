@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Manage-Limiter.ps1" -Action Status
echo.
pause
