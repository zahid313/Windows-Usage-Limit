@echo off
net session >nul 2>&1
if %errorLevel% == 0 (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Manage-Limiter.ps1" -Action ResetDay
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Manage-Limiter.ps1" -Action Status
    echo.
    pause
) else (
    echo Requesting Administrator privileges to reset today's timer and unblock websites...
    powershell.exe -NoProfile -Command "Start-Process powershell.exe -ArgumentList '-NoProfile -ExecutionPolicy Bypass -File \"%~dp0Manage-Limiter.ps1\" -Action ResetDay' -Verb RunAs -Wait"
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Manage-Limiter.ps1" -Action Status
    echo.
    pause
)
