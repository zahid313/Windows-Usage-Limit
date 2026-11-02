@echo off
net session >nul 2>&1
if %errorLevel% == 0 (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Optimize-StudentServices.ps1"
    echo.
    pause
) else (
    echo Requesting Administrator privileges to optimize student PC services...
    powershell.exe -NoProfile -Command "Start-Process powershell.exe -ArgumentList '-NoProfile -ExecutionPolicy Bypass -File \"%~dp0Optimize-StudentServices.ps1\"' -Verb RunAs -Wait"
    echo.
    pause
)
