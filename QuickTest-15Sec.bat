@echo off
net session >nul 2>&1
if %errorLevel% == 0 (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Manage-Limiter.ps1" -Action Test15Sec
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Manage-Limiter.ps1" -Action Status
    echo.
    pause
) else (
    echo Requesting Administrator privileges to update service and run quick test...
    powershell.exe -NoProfile -Command "Start-Process powershell.exe -ArgumentList '-NoProfile -ExecutionPolicy Bypass -File \"%~dp0Manage-Limiter.ps1\" -Action Test15Sec' -Verb RunAs -Wait"
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Manage-Limiter.ps1" -Action Status
    echo.
    pause
)
