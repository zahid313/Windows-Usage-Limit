#Requires -Version 5.1
<#
.SYNOPSIS
    Monitors combined daily usage of social websites, browser games, and PC games as NT AUTHORITY\SYSTEM, enforcing a 1-hour daily limit.
#>

param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot "config.json"),
    [string]$StatePath  = (Join-Path $PSScriptRoot "usage_state.json"),
    [string]$LogPath    = (Join-Path $PSScriptRoot "usage_limiter.log"),
    [switch]$RunOnce
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$HostsFilePath     = "$env:SystemRoot\System32\drivers\etc\hosts"
$BlockStartMarker  = "# >>> USAGE_LIMITER_START <<<"
$BlockEndMarker    = "# >>> USAGE_LIMITER_END <<<"
$SessionTitlesPath = Join-Path $PSScriptRoot "session_titles.json"
$ProbeTaskName     = "WindowsUsageLimiter-UserProbe"

$Script:SocialIpMap = @{}

Add-Type @"
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public class WindowHelper {
    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    [DllImport("user32.dll")]
    public static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);

    [DllImport("user32.dll")]
    public static extern bool IsWindowVisible(IntPtr hWnd);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern IntPtr SendMessageTimeout(
        IntPtr hWnd, uint Msg, IntPtr wParam, StringBuilder lParam,
        uint fuFlags, uint uTimeout, out IntPtr lpdwResult);

    private const uint WM_GETTEXT = 0x000D;
    private const uint SMTO_ABORTIFHUNG = 0x0002;

    public static List<string> GetAllVisibleWindowTitles() {
        var results = new List<string>();
        EnumWindows((hWnd, lParam) => {
            if (IsWindowVisible(hWnd)) {
                var sb = new StringBuilder(512);
                IntPtr res;
                if (SendMessageTimeout(hWnd, WM_GETTEXT, (IntPtr)512, sb, SMTO_ABORTIFHUNG, 50, out res) != IntPtr.Zero) {
                    string title = sb.ToString().Trim();
                    if (!string.IsNullOrEmpty(title)) {
                        results.Add(title);
                    }
                }
            }
            return true;
        }, IntPtr.Zero);
        return results;
    }
}
"@

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    $line = "[$timestamp] [$Level] $Message"
    Write-Host $line
    try {
        Add-Content -Path $LogPath -Value $line -Encoding UTF8
    } catch {}
}

function Show-Notification {
    param([string]$Title, [string]$Message)
    try {
        $msgExe = "$env:SystemRoot\System32\msg.exe"
        if (Test-Path $msgExe) {
            & $msgExe * /TIME:15 "$Title`r`n`r`n$Message" 2>$null | Out-Null
            return
        }
    } catch {}

    try {
        Add-Type -AssemblyName System.Windows.Forms
        Add-Type -AssemblyName System.Drawing
        $notify = New-Object System.Windows.Forms.NotifyIcon
        $notify.Icon = [System.Drawing.SystemIcons]::Warning
        $notify.Visible = $true
        $notify.ShowBalloonTip(7000, $Title, $Message, [System.Windows.Forms.ToolTipIcon]::Warning)
        Start-Sleep -Seconds 2
        $notify.Dispose()
    } catch {
        Write-Log "Could not display notification: $_" "WARN"
    }
}

function Get-Config {
    if (-not (Test-Path $ConfigPath)) {
        throw "Configuration file not found at $ConfigPath"
    }
    return Get-Content -Path $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Get-UsageState {
    $today = (Get-Date).ToString("yyyy-MM-dd")
    if (Test-Path $StatePath) {
        try {
            $state = Get-Content -Path $StatePath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($state.date -eq $today) {
                return $state
            }
        } catch {
            Write-Log "State file corrupted or unreadable. Initializing fresh state." "WARN"
        }
    }
    return [PSCustomObject]@{
        date            = $today
        elapsedSeconds  = 0
        isBlocked       = $false
        warningSent     = $false
        lastActiveItem  = ""
        lastUpdated     = (Get-Date).ToString("o")
    }
}

function Save-UsageState {
    param($State)
    $State.lastUpdated = (Get-Date).ToString("o")
    $State | ConvertTo-Json -Depth 5 | Set-Content -Path $StatePath -Encoding UTF8
}

function Enable-HostsBlock {
    param([string[]]$Domains)
    try {
        $content = ""
        if (Test-Path $HostsFilePath) {
            $content = Get-Content -Path $HostsFilePath -Raw -Encoding UTF8
            if ($null -eq $content) { $content = "" }
        }

        if ($content.Contains($BlockStartMarker)) {
            return
        }

        $lines = @("", $BlockStartMarker)
        foreach ($domain in ($Domains | Select-Object -Unique)) {
            $d = $domain.Trim()
            if ($d) {
                $lines += "0.0.0.0 $d"
                $lines += "::1 $d"
            }
        }
        $lines += $BlockEndMarker
        $blockText = ($lines -join "`r`n") + "`r`n"

        Add-Content -Path $HostsFilePath -Value $blockText -Encoding ASCII
        & ipconfig /flushdns | Out-Null
        Write-Log "Blocked $($Domains.Count) social & gaming domains in hosts file and flushed DNS cache."
    } catch {
        Write-Log "Failed to update hosts file (Ensure script is running as SYSTEM/Administrator): $_" "ERROR"
    }
}

function Disable-HostsBlock {
    try {
        if (-not (Test-Path $HostsFilePath)) { return }
        $content = Get-Content -Path $HostsFilePath -Raw -Encoding UTF8
        if ($null -eq $content -or -not $content.Contains($BlockStartMarker)) {
            return
        }

        $pattern = "(?s)\r?\n?$([regex]::Escape($BlockStartMarker)).*?$([regex]::Escape($BlockEndMarker))\r?\n?"
        $updated = [regex]::Replace($content, $pattern, "`r`n").TrimEnd() + "`r`n"
        Set-Content -Path $HostsFilePath -Value $updated -Encoding ASCII -NoNewline
        & ipconfig /flushdns | Out-Null
        Write-Log "Removed domain blocks from hosts file for the new day."
    } catch {
        Write-Log "Failed to remove hosts file block: $_" "ERROR"
    }
}

function Get-RunningGames {
    param($Config)
    $running = @()
    $seenPids = @{}

    $gameProcs     = @($Config.gameProcesses)
    $pathKeywords  = if ($Config.PSObject.Properties['gamePathKeywords']) { @($Config.gamePathKeywords) } else { @() }
    $excludedProcs = if ($Config.PSObject.Properties['excludedProcesses']) { @($Config.excludedProcesses) } else { @() }
    $browserProcs  = @($Config.browserProcesses)

    $allProcs = Get-Process -ErrorAction SilentlyContinue
    foreach ($proc in $allProcs) {
        $pName = $proc.ProcessName
        if ($excludedProcs -icontains $pName -or $browserProcs -icontains $pName) {
            continue
        }

        $matched = $false
        if ($gameProcs -icontains $pName) {
            $matched = $true
        }

        if (-not $matched -and $pathKeywords.Count -gt 0) {
            try {
                $exePath = $proc.Path
                if ($exePath) {
                    foreach ($kw in $pathKeywords) {
                        if ($exePath.IndexOf($kw, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
                            $matched = $true
                            break
                        }
                    }
                }
            } catch {}
        }

        if ($matched -and -not $seenPids.ContainsKey($proc.Id)) {
            $seenPids[$proc.Id] = $true
            $running += $proc
        }
    }
    return $running
}

function Stop-RunningGames {
    param($Config)
    $games = Get-RunningGames -Config $Config
    foreach ($proc in $games) {
        try {
            $name = $proc.ProcessName
            Stop-Process -Id $proc.Id -Force -ErrorAction Stop
            Write-Log "Terminated game process: $name (PID $($proc.Id))"
        } catch {
            Write-Log "Failed to terminate game process $($proc.ProcessName): $_" "WARN"
        }
    }
}

function Get-AllBrowserWindowTitles {
    param($Config)
    $titles = @()

    # 1. Fast non-blocking Win32 EnumWindows + Get-Process MainWindowTitle (<20ms)
    $winTitles = [WindowHelper]::GetAllVisibleWindowTitles()
    if ($winTitles) {
        $titles += $winTitles
    }

    $browserProcs = @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
        $Config.browserProcesses -icontains $_.ProcessName
    })
    foreach ($bp in $browserProcs) {
        if ($bp.MainWindowTitle) {
            $titles += $bp.MainWindowTitle
        }
    }

    # 2. Read titles captured by SessionProbe.ps1 running in the interactive user session
    if (Test-Path $SessionTitlesPath) {
        try {
            $probeData = Get-Content -Path $SessionTitlesPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($probeData -and $probeData.titles) {
                $ageSec = ((Get-Date) - [DateTime]::Parse($probeData.timestamp)).TotalSeconds
                if ($ageSec -le 120) {
                    foreach ($t in $probeData.titles) {
                        if ($t) { $titles += [string]$t }
                    }
                }
            }
        } catch {}
    }

    # 3. Fallback: Query tasklist.exe /V for each running browser type if no titles were found yet
    if ($titles.Count -eq 0) {
        $runningBrowserNames = @($browserProcs | Select-Object -ExpandProperty ProcessName -Unique)
        foreach ($bName in $runningBrowserNames) {
            try {
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
            } catch {}
        }
    }

    return @($titles | Select-Object -Unique)
}

function Stop-BlockedBrowsers {
    param($Config)
    $titles = Get-AllBrowserWindowTitles -Config $Config
    $hasBlockedTab = $false
    $matchedSiteName = ""

    foreach ($site in $Config.socialSites) {
        foreach ($kw in $site.windowKeywords) {
            foreach ($title in $titles) {
                if ($title -match [regex]::Escape($kw)) {
                    $hasBlockedTab = $true
                    $matchedSiteName = $site.name
                    break
                }
            }
            if ($hasBlockedTab) { break }
        }
        if ($hasBlockedTab) { break }
    }

    if ($hasBlockedTab) {
        $browserProcs = @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
            $Config.browserProcesses -icontains $_.ProcessName
        })
        foreach ($bp in $browserProcs) {
            try {
                Stop-Process -Id $bp.Id -Force -ErrorAction SilentlyContinue
            } catch {}
        }
        Write-Log "Closed browser processes because blocked site ($matchedSiteName) remained open after daily limit." "WARN"
    }
}

function Update-SocialIpMap {
    param($Config)
    try {
        $dnsCache = Get-DnsClientCache -ErrorAction SilentlyContinue
        if ($dnsCache) {
            foreach ($site in $Config.socialSites) {
                foreach ($domain in $site.domains) {
                    $records = $dnsCache | Where-Object {
                        ($_.Entry -ieq $domain -or $_.Name -ieq $domain -or $_.Entry -like "*.$domain") -and $_.Data
                    }
                    foreach ($rec in $records) {
                        if ($rec.Data -and $rec.Data -ne "0.0.0.0" -and $rec.Data -ne "::1") {
                            $Script:SocialIpMap[$rec.Data] = $site.name
                        }
                    }
                }
            }
        }
    } catch {}
}

function Test-SocialSiteActive {
    param($Config)

    try {
        $probeTask = Get-ScheduledTask -TaskName $ProbeTaskName -ErrorAction SilentlyContinue
        if ($probeTask -and $probeTask.State -ne "Running") {
            Start-ScheduledTask -TaskName $ProbeTaskName -ErrorAction SilentlyContinue
        }
    } catch {}

    $browserProcs = @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
        $Config.browserProcesses -icontains $_.ProcessName
    })
    if ($browserProcs.Count -eq 0) {
        return $null
    }

    # 1. Check Window Titles across all sources (Win32 + SessionProbe)
    $titlesToCheck = Get-AllBrowserWindowTitles -Config $Config
    foreach ($site in $Config.socialSites) {
        foreach ($kw in $site.windowKeywords) {
            foreach ($title in $titlesToCheck) {
                if ($title -match [regex]::Escape($kw)) {
                    return "Web ($($site.name))"
                }
            }
        }
    }

    # 2. Check DNS Cache + Active Browser TCP Connections
    Update-SocialIpMap -Config $Config

    try {
        $dnsCache = Get-DnsClientCache -ErrorAction SilentlyContinue
        if ($dnsCache) {
            foreach ($site in $Config.socialSites) {
                foreach ($domain in $site.domains) {
                    $hit = $dnsCache | Where-Object {
                        ($_.Entry -ieq $domain -or $_.Name -ieq $domain -or $_.Entry -like "*.$domain") -and $_.Data -ne "0.0.0.0" -and $_.Data -ne "::1"
                    }
                    if ($hit) {
                        Clear-DnsClientCache -ErrorAction SilentlyContinue
                        return "Web (DNS Query: $($site.name))"
                    }
                }
            }
        }
    } catch {}

    if ($Script:SocialIpMap.Count -gt 0) {
        try {
            $browserPids = $browserProcs | Select-Object -ExpandProperty Id
            $conns = Get-NetTCPConnection -State Established -ErrorAction SilentlyContinue | Where-Object {
                $browserPids -contains $_.OwningProcess
            }
            foreach ($conn in $conns) {
                if ($Script:SocialIpMap.ContainsKey($conn.RemoteAddress)) {
                    $siteName = $Script:SocialIpMap[$conn.RemoteAddress]
                    return "Web (Active Connection: $siteName)"
                }
            }
        } catch {}
    }

    return $null
}

Write-Log "Starting UsageLimiter monitor as [$env:USERNAME] (Config: $ConfigPath)"
$currentDate = ""

while ($true) {
    try {
        $config = Get-Config
        $state  = Get-UsageState

        if ($state.date -ne $currentDate) {
            $currentDate = $state.date
            if (-not $state.isBlocked) {
                Disable-HostsBlock
            }
        }

        $allDomains = @()
        foreach ($site in $config.socialSites) {
            $allDomains += $site.domains
        }

        if ($state.elapsedSeconds -lt $config.dailyLimitSeconds) {
            $activeReason = $null
            $runningGames = @(Get-RunningGames -Config $config)
            if ($runningGames.Count -gt 0) {
                $gameNames = ($runningGames | Select-Object -ExpandProperty ProcessName -Unique) -join ", "
                $activeReason = "Game ($gameNames)"
            } else {
                $activeReason = Test-SocialSiteActive -Config $config
            }

            if ($activeReason) {
                $state.elapsedSeconds += $config.pollIntervalSeconds
                $state.lastActiveItem = $activeReason
                $remaining = [Math]::Max(0, $config.dailyLimitSeconds - $state.elapsedSeconds)
                Write-Log "Detected active usage: $activeReason | Used: $($state.elapsedSeconds)s / $($config.dailyLimitSeconds)s (Remaining: ${remaining}s)"

                if (-not $state.warningSent -and $remaining -le $config.warningRemainingSeconds -and $remaining -gt 0) {
                    $mins = [Math]::Ceiling($remaining / 60.0)
                    Write-Log "Warning threshold reached: ~$mins minute(s) remaining." "WARN"
                    Show-Notification -Title "Usage Limiter Warning" -Message "You have about $mins minute(s) of social & game time left today."
                    $state.warningSent = $true
                }

                Save-UsageState -State $state
            }
        }

        if ($state.elapsedSeconds -ge $config.dailyLimitSeconds) {
            if (-not $state.isBlocked) {
                Write-Log "Daily usage limit of $($config.dailyLimitSeconds)s reached! Enforcing block." "WARN"
                Enable-HostsBlock -Domains $allDomains
                Stop-RunningGames -Config $config
                Stop-BlockedBrowsers -Config $config
                $state.isBlocked = $true
                Save-UsageState -State $state
                Show-Notification -Title "Daily Limit Reached (1 Hour)" -Message "Your 1-hour combined limit for social websites and games is up for today. Access is now blocked until midnight."
            } else {
                Enable-HostsBlock -Domains $allDomains
                Stop-RunningGames -Config $config
                Stop-BlockedBrowsers -Config $config
            }
        }
    } catch {
        Write-Log "Error in monitoring loop: $_" "ERROR"
    }

    if ($RunOnce) { break }
    Start-Sleep -Seconds $config.pollIntervalSeconds
}
