#Requires -Version 5.1
<#
.SYNOPSIS
    Lightweight interactive-session helper that captures active browser window titles completely invisibly
    and closes blocked social/gaming browser tabs when the daily limit is reached.
#>

param(
    [switch]$RunOnce
)

$ErrorActionPreference = "SilentlyContinue"
$DataDir    = $PSScriptRoot
$ConfigPath = Join-Path $DataDir "config.json"
$StatePath  = Join-Path $DataDir "usage_state.json"
$TitlesPath = Join-Path $DataDir "session_titles.json"

# Ensure only a single background instance runs per user session
if (-not $RunOnce) {
    $createdNew = $false
    $Script:ProbeMutex = New-Object System.Threading.Mutex($true, "Local\WindowsUsageLimiterSessionProbe", [ref]$createdNew)
    if (-not $createdNew) {
        exit 0
    }
}

while ($true) {
    try {
        if (Test-Path $ConfigPath) {
            $config = Get-Content -Path $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $titles = @()

            $browserProcs = @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
                $config.browserProcesses -icontains $_.ProcessName
            })
            foreach ($bp in $browserProcs) {
                if ($bp.MainWindowTitle) {
                    $titles += $bp.MainWindowTitle
                }
            }

            $runningBrowserNames = @($browserProcs | Select-Object -ExpandProperty ProcessName -Unique)
            foreach ($bName in $runningBrowserNames) {
                $rawCsv = & "$env:SystemRoot\System32\tasklist.exe" /FI "IMAGENAME eq $bName.exe" /V /FO CSV 2>$null
                if ($rawCsv -and @($rawCsv).Count -gt 1) {
                    foreach ($line in ($rawCsv | Select-Object -Skip 1)) {
                        if ($line -match ',"([^"]+)"$') {
                            $wt = $Matches[1]
                            if ($wt -and $wt -ne "N/A" -and $wt -ne "OleMainThreadWndName") {
                                $titles += $wt
                            }
                        }
                    }
                }
            }

            $uniqueTitles = @($titles | Select-Object -Unique)
            $payload = [PSCustomObject]@{
                timestamp = (Get-Date).ToString("o")
                titles    = $uniqueTitles
            }
            $payload | ConvertTo-Json -Depth 4 | Set-Content -Path $TitlesPath -Encoding UTF8

            if (Test-Path $StatePath) {
                $state = Get-Content -Path $StatePath -Raw -Encoding UTF8 | ConvertFrom-Json
                if ($state.isBlocked) {
                    foreach ($site in $config.socialSites) {
                        foreach ($kw in $site.windowKeywords) {
                            foreach ($t in $uniqueTitles) {
                                if ($t -match [regex]::Escape($kw)) {
                                    foreach ($bp in $browserProcs) {
                                        Stop-Process -Id $bp.Id -Force -ErrorAction SilentlyContinue
                                    }
                                    break
                                }
                            }
                        }
                    }
                }
            }
        }
    } catch {}

    if ($RunOnce) { break }
    Start-Sleep -Seconds 10
}
