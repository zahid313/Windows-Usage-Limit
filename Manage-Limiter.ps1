#Requires -Version 5.1
<#
.SYNOPSIS
    Management utility to install, uninstall, check status, or reset the UsageLimiter SYSTEM boot service.
.PARAMETER Action
    Status    - Show today's used/remaining time and SYSTEM task status.
    Install   - Install to C:\ProgramData\UsageLimiter, configure browser DoH/QUIC policies, lock permissions, and start SYSTEM boot task (Requires Admin).
    Uninstall - Remove the SYSTEM Scheduled Task, unlock permissions, and unblock hosts file (Requires Admin).
    ResetDay  - Reset today's usage counter to 0 and unblock hosts file (Requires Admin).
    Test15Sec - Fast-forward today's usage so only 1 check interval (1 minute) remains and run an immediate check (Requires Admin).
#>

param(
    [ValidateSet("Status", "Install", "Uninstall", "ResetDay", "Test15Sec")]
    [string]$Action = "Status"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$TaskName       = "WindowsUsageLimiter"
$ProbeTaskName  = "WindowsUsageLimiter-UserProbe"
$RunRegPath     = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run"
$RunRegName     = "WindowsUsageLimiterProbe"
$ProtectedDir   = "$env:ProgramData\UsageLimiter"
$ActiveDir      = if (Test-Path (Join-Path $ProtectedDir "config.json")) { $ProtectedDir } else { $PSScriptRoot }
$MonitorPath    = Join-Path $ActiveDir "UsageMonitor.ps1"
$ConfigPath     = Join-Path $ActiveDir "config.json"
$StatePath      = Join-Path $ActiveDir "usage_state.json"
$HostsPath      = "$env:SystemRoot\System32\drivers\etc\hosts"
$BlockStart     = "# >>> USAGE_LIMITER_START <<<"
$BlockEnd       = "# >>> USAGE_LIMITER_END <<<"

function Test-IsAdmin {
    $identity  = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Unlock-DirectoryPermissions {
    param([string]$FolderPath)
    if (Test-Path $FolderPath) {
        & "$env:SystemRoot\System32\takeown.exe" /F $FolderPath /R /A /D Y 2>$null | Out-Null
        & "$env:SystemRoot\System32\icacls.exe" $FolderPath /inheritance:e /T /C /Q 2>$null | Out-Null
        & "$env:SystemRoot\System32\icacls.exe" $FolderPath /reset /T /C /Q 2>$null | Out-Null
    }
}

function Lock-DirectoryPermissions {
    param([string]$FolderPath)
    $titlesFile = Join-Path $FolderPath "session_titles.json"
    if (-not (Test-Path $titlesFile)) {
        "{}" | Set-Content -Path $titlesFile -Encoding UTF8
    }
    $logFile = Join-Path $FolderPath "usage_limiter.log"
    if (-not (Test-Path $logFile)) {
        "" | Set-Content -Path $logFile -Encoding UTF8
    }

    & "$env:SystemRoot\System32\takeown.exe" /F $FolderPath /R /A /D Y 2>$null | Out-Null
    & "$env:SystemRoot\System32\icacls.exe" $FolderPath /inheritance:e /T /C /Q 2>$null | Out-Null
    & "$env:SystemRoot\System32\icacls.exe" $FolderPath /reset /T /C /Q 2>$null | Out-Null
    # Grant Read & Execute to Users on all files (non-admins can read status/config, but only SYSTEM & Admins can modify)
    & "$env:SystemRoot\System32\icacls.exe" $FolderPath /grant "*S-1-5-32-545:RX" /T /C /Q 2>$null | Out-Null
    # Allow interactive Users to update session_titles.json
    & "$env:SystemRoot\System32\icacls.exe" $titlesFile /grant "*S-1-5-32-545:M" /C /Q 2>$null | Out-Null
}

function Enable-BrowserDnsPolicies {
    $policyPaths = @(
        "HKLM:\SOFTWARE\Policies\Google\Chrome",
        "HKLM:\SOFTWARE\Policies\Microsoft\Edge",
        "HKLM:\SOFTWARE\Policies\BraveSoftware\Brave"
    )
    foreach ($p in $policyPaths) {
        if (-not (Test-Path $p)) {
            New-Item -Path $p -Force | Out-Null
        }
        Set-ItemProperty -Path $p -Name "DnsOverHttpsMode" -Value "off" -Type String -Force
        Set-ItemProperty -Path $p -Name "QuicAllowed" -Value 0 -Type DWord -Force
    }
}

function Disable-BrowserDnsPolicies {
    $policyPaths = @(
        "HKLM:\SOFTWARE\Policies\Google\Chrome",
        "HKLM:\SOFTWARE\Policies\Microsoft\Edge",
        "HKLM:\SOFTWARE\Policies\BraveSoftware\Brave"
    )
    foreach ($p in $policyPaths) {
        if (Test-Path $p) {
            Remove-ItemProperty -Path $p -Name "DnsOverHttpsMode" -ErrorAction SilentlyContinue
            Remove-ItemProperty -Path $p -Name "QuicAllowed" -ErrorAction SilentlyContinue
        }
    }
}

function Remove-HostsBlock {
    if (-not (Test-Path $HostsPath)) { return }
    $content = Get-Content -Path $HostsPath -Raw -Encoding UTF8
    if ($null -ne $content -and $content.Contains($BlockStart)) {
        $pattern = "(?s)\r?\n?$([regex]::Escape($BlockStart)).*?$([regex]::Escape($BlockEnd))\r?\n?"
        $updated = [regex]::Replace($content, $pattern, "`r`n").TrimEnd() + "`r`n"
        Set-Content -Path $HostsPath -Value $updated -Encoding ASCII -NoNewline
        & ipconfig /flushdns | Out-Null
        Write-Host "Removed social domain blocks from hosts file." -ForegroundColor Green
    }
}

function Deploy-And-StartServices {
    param([switch]$FastForwardTest)

    Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    Stop-ScheduledTask -TaskName $ProbeTaskName -ErrorAction SilentlyContinue
    Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like "*UsageMonitor.ps1*" -or $_.CommandLine -like "*SessionProbe.ps1*" } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

    Unlock-DirectoryPermissions -FolderPath $PSScriptRoot
    $oldBackup = Join-Path (Split-Path $PSScriptRoot -Parent) "UsageLimiter_LockedBackup"
    if (Test-Path $oldBackup) {
        Unlock-DirectoryPermissions -FolderPath $oldBackup
        Remove-Item -Path $oldBackup -Recurse -Force -ErrorAction SilentlyContinue
    }

    if (-not (Test-Path $ProtectedDir)) {
        New-Item -Path $ProtectedDir -ItemType Directory -Force | Out-Null
    } else {
        Unlock-DirectoryPermissions -FolderPath $ProtectedDir
    }

    Copy-Item -Path (Join-Path $PSScriptRoot "UsageMonitor.ps1")      -Destination $ProtectedDir -Force
    Copy-Item -Path (Join-Path $PSScriptRoot "SessionProbe.ps1")      -Destination $ProtectedDir -Force
    Copy-Item -Path (Join-Path $PSScriptRoot "LaunchProbeHidden.vbs") -Destination $ProtectedDir -Force
    Copy-Item -Path (Join-Path $PSScriptRoot "config.json")           -Destination $ProtectedDir -Force
    Copy-Item -Path (Join-Path $PSScriptRoot "Manage-Limiter.ps1")    -Destination $ProtectedDir -Force
    if (Test-Path (Join-Path $PSScriptRoot "session_titles.json")) {
        Copy-Item -Path (Join-Path $PSScriptRoot "session_titles.json") -Destination $ProtectedDir -Force
    }

    Enable-BrowserDnsPolicies

    $today = (Get-Date).ToString("yyyy-MM-dd")
    if ($FastForwardTest) {
        $config = Get-Content -Path (Join-Path $ProtectedDir "config.json") -Raw | ConvertFrom-Json
        $limitSec = [int]$config.dailyLimitSeconds
        $pollSec  = [int]$config.pollIntervalSeconds
        $fastForwardSec = [Math]::Max(0, $limitSec - $pollSec)

        $testState = [PSCustomObject]@{
            date           = $today
            elapsedSeconds = $fastForwardSec
            isBlocked      = $false
            warningSent    = $false
            lastActiveItem = "Test Mode (Fast-forwarded)"
            lastUpdated    = (Get-Date).ToString("o")
        }

        foreach ($dir in @($PSScriptRoot, $ProtectedDir)) {
            $sp = Join-Path $dir "usage_state.json"
            $testState | ConvertTo-Json -Depth 5 | Set-Content -Path $sp -Encoding UTF8
        }
    } elseif (-not (Test-Path (Join-Path $ProtectedDir "usage_state.json"))) {
        $initState = [PSCustomObject]@{
            date           = $today
            elapsedSeconds = 0
            isBlocked      = $false
            warningSent    = $false
            lastActiveItem = "None"
            lastUpdated    = (Get-Date).ToString("o")
        }
        $initState | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $ProtectedDir "usage_state.json") -Encoding UTF8
    }

    # Run one immediate synchronous SessionProbe snapshot so session_titles.json is populated right now
    $probeScript = Join-Path $ProtectedDir "SessionProbe.ps1"
    $vbsPath     = Join-Path $ProtectedDir "LaunchProbeHidden.vbs"
    $wscriptExe  = "$env:SystemRoot\System32\wscript.exe"
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $probeScript -RunOnce

    # Run one immediate synchronous check right now so the user sees immediate enforcement during testing
    $targetScript = Join-Path $ProtectedDir "UsageMonitor.ps1"
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $targetScript -RunOnce

    # Sync state and logs back to source folder for display
    foreach ($fn in @("usage_state.json", "usage_limiter.log", "session_titles.json")) {
        if (Test-Path (Join-Path $ProtectedDir $fn)) {
            Copy-Item -Path (Join-Path $ProtectedDir $fn) -Destination (Join-Path $PSScriptRoot $fn) -Force -ErrorAction SilentlyContinue
        }
    }

    # Lock permissions on C:\ProgramData\UsageLimiter (SYSTEM & Admins = Full, Users = Read+Execute)
    Lock-DirectoryPermissions -FolderPath $ProtectedDir

    # Remove old HKLM Run key that opened a visible console window and use wscript.exe //B //NoLogo (100% windowless GUI subsystem)
    Remove-ItemProperty -Path $RunRegPath -Name $RunRegName -ErrorAction SilentlyContinue
    Start-Process -FilePath $wscriptExe -ArgumentList "//B //NoLogo `"$vbsPath`""

    # Register SessionProbe scheduled task using wscript.exe (GUI subsystem = zero terminal windows ever)
    try {
        $probeAction = New-ScheduledTaskAction -Execute $wscriptExe -Argument "//B //NoLogo `"$vbsPath`"" -WorkingDirectory $ProtectedDir
        $probeTrig   = New-ScheduledTaskTrigger -AtLogOn
        $probeSet    = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1)
        $probePrinc  = New-ScheduledTaskPrincipal -GroupId "S-1-5-32-545" -RunLevel Limited
        Register-ScheduledTask -TaskName $ProbeTaskName -Action $probeAction -Trigger $probeTrig -Settings $probeSet -Principal $probePrinc -Force | Out-Null
    } catch {}

    # Register and start main SYSTEM service task (runs at Windows Boot and Logon under NT AUTHORITY\SYSTEM)
    $argList = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$targetScript`""
    $taskAction = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $argList -WorkingDirectory $ProtectedDir
    $triggerBoot  = New-ScheduledTaskTrigger -AtStartup
    $triggerLogon = New-ScheduledTaskTrigger -AtLogOn
    $settings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -StartWhenAvailable `
        -MultipleInstances IgnoreNew `
        -ExecutionTimeLimit ([TimeSpan]::Zero) `
        -RestartCount 999 `
        -RestartInterval (New-TimeSpan -Minutes 1)
    $principal = New-ScheduledTaskPrincipal -UserId "NT AUTHORITY\SYSTEM" -LogonType ServiceAccount -RunLevel Highest

    Register-ScheduledTask -TaskName $TaskName -Action $taskAction -Trigger @($triggerBoot, $triggerLogon) -Settings $settings -Principal $principal -Force | Out-Null
    Start-ScheduledTask -TaskName $TaskName
}

switch ($Action) {
    "Status" {
        $cfgFileToRead = $ConfigPath
        try {
            $config = Get-Content -Path $cfgFileToRead -Raw -ErrorAction Stop | ConvertFrom-Json
        } catch {
            $config = Get-Content -Path (Join-Path $PSScriptRoot "config.json") -Raw | ConvertFrom-Json
        }

        $limitSec = [int]$config.dailyLimitSeconds
        $today = (Get-Date).ToString("yyyy-MM-dd")
        $usedSec = 0
        $isBlocked = $false
        $lastActive = "None"

        $stateFileToRead = $StatePath
        if (-not (Test-Path $stateFileToRead)) {
            $stateFileToRead = Join-Path $PSScriptRoot "usage_state.json"
        }

        if (Test-Path $stateFileToRead) {
            try {
                $state = Get-Content -Path $stateFileToRead -Raw -ErrorAction Stop | ConvertFrom-Json
                if ($state.date -eq $today) {
                    $usedSec    = [int]$state.elapsedSeconds
                    $isBlocked  = [bool]$state.isBlocked
                    $lastActive = $state.lastActiveItem
                }
            } catch {
                $localStatePath = Join-Path $PSScriptRoot "usage_state.json"
                if (Test-Path $localStatePath) {
                    $state = Get-Content -Path $localStatePath -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json
                    if ($state -and $state.date -eq $today) {
                        $usedSec    = [int]$state.elapsedSeconds
                        $isBlocked  = [bool]$state.isBlocked
                        $lastActive = $state.lastActiveItem
                    }
                }
            }
        }

        $remSec = [Math]::Max(0, $limitSec - $usedSec)
        $usedSpan = [TimeSpan]::FromSeconds($usedSec)
        $remSpan  = [TimeSpan]::FromSeconds($remSec)

        $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        $taskState = if ($task) {
            "$($task.State) (Principal: $($task.Principal.UserId))"
        } elseif (Test-Path $ProtectedDir) {
            "Running as SYSTEM (Protected - Run as Admin to view task details)"
        } else {
            "Not Installed"
        }

        Write-Host "=== UsageLimiter Status ($today) ===" -ForegroundColor Cyan
        Write-Host ("Install Folder : {0}" -f $ActiveDir)
        Write-Host ("SYSTEM Service : {0}" -f $taskState)
        Write-Host ("Check Interval : Every {0} seconds" -f $config.pollIntervalSeconds)
        Write-Host ("Used Today     : {0:hh\:mm\:ss} ({1}s / {2}s)" -f $usedSpan, $usedSec, $limitSec)
        Write-Host ("Remaining Time : {0:hh\:mm\:ss}" -f $remSpan)
        Write-Host ("Blocked Status : {0}" -f $isBlocked)
        Write-Host ("Last Active    : {0}" -f $lastActive)
    }

    "Install" {
        if (-not (Test-IsAdmin)) {
            Write-Error "Please run PowerShell as Administrator to install the SYSTEM service task."
        }
        Deploy-And-StartServices
        Write-Host "Successfully installed and started '$TaskName' under NT AUTHORITY\SYSTEM!" -ForegroundColor Green
    }

    "Uninstall" {
        if (-not (Test-IsAdmin)) {
            Write-Error "Please run PowerShell as Administrator to uninstall the SYSTEM service task."
        }

        Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
        Stop-ScheduledTask -TaskName $ProbeTaskName -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $ProbeTaskName -Confirm:$false -ErrorAction SilentlyContinue
        Remove-ItemProperty -Path $RunRegPath -Name $RunRegName -ErrorAction SilentlyContinue

        Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -like "*UsageMonitor.ps1*" -or $_.CommandLine -like "*SessionProbe.ps1*" } |
            ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

        Disable-BrowserDnsPolicies
        Unlock-DirectoryPermissions -FolderPath $ProtectedDir
        Unlock-DirectoryPermissions -FolderPath $PSScriptRoot
        if (Test-Path $ProtectedDir) {
            Remove-Item -Path $ProtectedDir -Recurse -Force -ErrorAction SilentlyContinue
        }

        Remove-HostsBlock
        Write-Host "Uninstalled '$TaskName', restored permissions/policies, and unblocked all domains." -ForegroundColor Green
    }

    "ResetDay" {
        if (-not (Test-IsAdmin)) {
            Write-Error "Please run PowerShell as Administrator to reset the daily counter and unblock hosts."
        }

        Unlock-DirectoryPermissions -FolderPath $ProtectedDir
        $today = (Get-Date).ToString("yyyy-MM-dd")
        $resetState = [PSCustomObject]@{
            date           = $today
            elapsedSeconds = 0
            isBlocked      = $false
            warningSent    = $false
            lastActiveItem = "None (Reset)"
            lastUpdated    = (Get-Date).ToString("o")
        }
        foreach ($dir in @($ProtectedDir, $PSScriptRoot)) {
            if (Test-Path $dir) {
                $sp = Join-Path $dir "usage_state.json"
                $resetState | ConvertTo-Json -Depth 5 | Set-Content -Path $sp -Encoding UTF8
            }
        }
        if (Test-Path $ProtectedDir) {
            Lock-DirectoryPermissions -FolderPath $ProtectedDir
        }
        Remove-HostsBlock
        Write-Host "Today's usage counter has been reset to 0 and social domains are unblocked." -ForegroundColor Green
    }

    "Test15Sec" {
        if (-not (Test-IsAdmin)) {
            Write-Error "Please run PowerShell as Administrator to run the quick test."
        }

        if (Test-Path (Join-Path $ProtectedDir "UsageMonitor.ps1")) {
            Write-Host "Fast-forwarding installed SYSTEM service timer..." -ForegroundColor Cyan
            $config = Get-Content -Path (Join-Path $ProtectedDir "config.json") -Raw | ConvertFrom-Json
            $limitSec = [int]$config.dailyLimitSeconds
            $pollSec  = [int]$config.pollIntervalSeconds
            $fastForwardSec = [Math]::Max(0, $limitSec - $pollSec)
            $today = (Get-Date).ToString("yyyy-MM-dd")

            $testState = [PSCustomObject]@{
                date           = $today
                elapsedSeconds = $fastForwardSec
                isBlocked      = $false
                warningSent    = $false
                lastActiveItem = "Test Mode (Fast-forwarded)"
                lastUpdated    = (Get-Date).ToString("o")
            }

            foreach ($dir in @($PSScriptRoot, $ProtectedDir)) {
                $sp = Join-Path $dir "usage_state.json"
                $testState | ConvertTo-Json -Depth 5 | Set-Content -Path $sp -Encoding UTF8
            }
            Write-Host "Done! Timer is now at $fastForwardSec / $limitSec seconds (59m 00s used, 1 minute remaining)." -ForegroundColor Green
            Write-Host "Keep YouTube or a game open -- on the next 1-minute check, it will block automatically!" -ForegroundColor Yellow
        } else {
            Deploy-And-StartServices -FastForwardTest
            Write-Host "Installed SYSTEM service and fast-forwarded timer!" -ForegroundColor Green
        }
    }
}
