#Requires -Version 5.1
<#
.SYNOPSIS
    Disables non-essential Windows background services for student PCs (Xbox services, telemetry, retail demo, remote registry, etc.).
.PARAMETER Restore
    Restores all services back to their previously backed-up startup configurations.
#>

param(
    [switch]$Restore
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "SilentlyContinue"

function Test-IsAdmin {
    $identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-IsAdmin)) {
    Write-Host "ERROR: Please run this script as Administrator (Right-click PowerShell -> Run as Administrator)." -ForegroundColor Red
    exit 1
}

$BackupPath = Join-Path $PSScriptRoot "services_backup.json"

# Services that are safe to disable on a student/classroom machine
$TargetServices = @(
    # --- Xbox & Gaming Background Services ---
    @{ Name = "XblAuthManager";      Desc = "Xbox Live Auth Manager" }
    @{ Name = "XblGameSave";         Desc = "Xbox Live Game Save" }
    @{ Name = "XboxNetApiSvc";       Desc = "Xbox Live Networking Service" }
    @{ Name = "XboxGipSvc";          Desc = "Xbox Accessory Management Service" }
    
    # --- Telemetry, Diagnostics & Tracking ---
    @{ Name = "DiagTrack";           Desc = "Connected User Experiences and Telemetry" }
    @{ Name = "dmwappushservice";    Desc = "Device Management WAP Push Message Routing" }
    @{ Name = "WerSvc";              Desc = "Windows Error Reporting Service" }
    
    # --- Consumer / Bloatware Background Services ---
    @{ Name = "RetailDemo";          Desc = "Retail Demo Service" }
    @{ Name = "PhoneSvc";            Desc = "Phone Service (Your Phone / Phone Link)" }
    @{ Name = "MapsBroker";          Desc = "Downloaded Maps Manager" }
    @{ Name = "wisvc";               Desc = "Windows Insider Service" }
    @{ Name = "lfsvc";               Desc = "Geolocation Service" }
    @{ Name = "Fax";                 Desc = "Fax Service" }
    @{ Name = "RemoteRegistry";      Desc = "Remote Registry (Security Risk)" }
    @{ Name = "MixedRealityOpenXRSvc"; Desc = "Windows Mixed Reality OpenXR" }
    @{ Name = "SharedRealitySvc";    Desc = "Spatial Data Service" }
)

if ($Restore) {
    if (-not (Test-Path $BackupPath)) {
        Write-Host "No backup file found at $BackupPath. Cannot restore." -ForegroundColor Yellow
        exit 0
    }

    Write-Host "Restoring services from backup ($BackupPath)..." -ForegroundColor Cyan
    $backupData = Get-Content -Path $BackupPath -Raw | ConvertFrom-Json

    foreach ($entry in $backupData) {
        $svc = Get-Service -Name $entry.Name -ErrorAction SilentlyContinue
        if ($svc) {
            try {
                Set-Service -Name $entry.Name -StartupType $entry.StartType -ErrorAction Stop
                if ($entry.Status -eq "Running") {
                    Start-Service -Name $entry.Name -ErrorAction SilentlyContinue
                }
                Write-Host "Restored $($entry.Name) -> $($entry.StartType)" -ForegroundColor Green
            } catch {
                Write-Host "Failed to restore $($entry.Name): $_" -ForegroundColor Red
            }
        }
    }
    Write-Host "Restore complete." -ForegroundColor Green
    exit 0
}

Write-Host "=== Student PC Service Optimization ===" -ForegroundColor Cyan
Write-Host "Backing up current service states..." -ForegroundColor Gray

# Backup current states of existing target services
$backupList = @()
foreach ($target in $TargetServices) {
    $svc = Get-Service -Name $target.Name -ErrorAction SilentlyContinue
    if ($svc) {
        $backupList += [PSCustomObject]@{
            Name      = $svc.Name
            StartType = $svc.StartType.ToString()
            Status    = $svc.Status.ToString()
        }
    }
}

if ($backupList.Count -gt 0 -and (-not (Test-Path $BackupPath))) {
    $backupList | ConvertTo-Json -Depth 3 | Set-Content -Path $BackupPath -Encoding UTF8
    Write-Host "Saved service backup to $BackupPath" -ForegroundColor DarkGray
}

Write-Host "`nStopping and disabling non-essential services:`n" -ForegroundColor Yellow

$stoppedCount = 0
foreach ($target in $TargetServices) {
    $svc = Get-Service -Name $target.Name -ErrorAction SilentlyContinue
    if ($null -eq $svc) {
        continue
    }

    try {
        if ($svc.Status -eq "Running") {
            Stop-Service -Name $target.Name -Force -ErrorAction Stop
            Write-Host " [STOPPED]  $($target.Desc) ($($target.Name))" -ForegroundColor Yellow
        }
        Set-Service -Name $target.Name -StartupType Disabled -ErrorAction Stop
        Write-Host " [DISABLED] $($target.Desc) ($($target.Name))" -ForegroundColor Green
        $stoppedCount++
    } catch {
        Write-Host " [FAILED]   $($target.Desc): $_" -ForegroundColor Red
    }
}

Write-Host "`nSuccessfully optimized $stoppedCount non-essential services for student use!" -ForegroundColor Green
Write-Host "Note: Essential services (Audio, Wi-Fi/Network, Display, Print Spooler, Windows Defender) were left untouched." -ForegroundColor Cyan
Write-Host "To undo any changes at any time, run: .\Optimize-StudentServices.ps1 -Restore" -ForegroundColor Gray
