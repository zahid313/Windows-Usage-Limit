# Windows Usage Limit

A tamper-resistant Windows service and monitoring utility that enforces a daily time limit on social media, web games, game stores, and desktop games.

---

## Features

- **Combined Daily Limit**: Tracks total active usage across social media and gaming applications (default: 1 hour / 3600 seconds per day).
- **Multi-Vector Detection**:
  - **Window Title Detection**: Active tab and window title inspection across all major browsers (Chrome, Edge, Firefox, Brave, Opera, Vivaldi, Arc, Waterfox).
  - **Desktop Game Detection**: Process name and executable path inspection (Steam, Epic Games, Riot, Battle.net, EA, Roblox, Minecraft, etc.).
  - **Network / Active Connection Monitoring**: Inspects active TCP connections to domain IPs.
- **Enforcement & Blocking**:
  - Updates Windows `hosts` file to redirect blocked domains to `127.0.0.1` and `::1`.
  - Automatically flushes DNS cache (`ipconfig /flushdns` and PowerShell DNS cache).
  - Force-closes open browser tabs/windows and running game processes once daily limit is reached.
  - Hardens browsers against DNS-over-HTTPS (DoH) and QUIC (HTTP/3) bypasses via registry policies.
- **Tamper Resistance**:
  - Runs in the background as `NT AUTHORITY\SYSTEM` via Windows Scheduled Tasks.
  - Protected installation directory in `C:\ProgramData\UsageLimiter` locked with strict ACL permissions (`icacls`).
  - Completely invisible session probe running in the background.

---

## Project Structure

```
Windows-Usage-Limit/
├── config.json              # Domain lists, process names, keywords, and time limits
├── Manage-Limiter.ps1       # Administrative script for install, uninstall, status, and reset
├── UsageMonitor.ps1         # Core background monitor running as SYSTEM
├── SessionProbe.ps1         # User-session window title probe
├── LaunchProbeHidden.vbs    # Hidden VBS wrapper to start SessionProbe without a window
├── Install-AsAdmin.bat      # Helper script to install as Administrator
├── Check-Status.bat         # Helper script to display remaining time and service status
├── Reset-Day.bat            # Helper script to reset today's usage counter
├── QuickTest-15Sec.bat      # Fast-forwards timer to 1 minute left for rapid testing
├── Optimize-StudentPC.bat   # Helper script to disable non-essential services (Xbox, telemetry)
├── Optimize-StudentServices.ps1 # Optimization script with automatic state backup
├── Restore-StudentPC.bat    # Helper script to restore all services to previous states
└── .gitignore               # Ignores runtime state and log files
```

---

## Getting Started

### Prerequisites

- Windows 10 or Windows 11 (64-bit)
- PowerShell 5.1 or later
- Administrator privileges for installation and management

### Installation

1. Clone or download this repository:
   ```cmd
   git clone https://github.com/zahid313/Windows-Usage-Limit.git
   cd Windows-Usage-Limit
   ```
2. Right-click `Install-AsAdmin.bat` and select **Run as administrator** (or double-click to elevate automatically).
3. The script will:
   - Copy scripts and configuration to `C:\ProgramData\UsageLimiter`
   - Lock directory permissions to Administrators and SYSTEM
   - Configure browser anti-bypass policies
   - Register and launch the `WindowsUsageLimiter` SYSTEM scheduled task
   - Start the user-session probe

---

## Management & Commands

You can use the provided batch files or run `Manage-Limiter.ps1` from an elevated PowerShell prompt:

| Batch File | PowerShell Command | Description |
| :--- | :--- | :--- |
| `Check-Status.bat` | `.\Manage-Limiter.ps1 -Action Status` | View today's elapsed time, remaining time, and task status |
| `Reset-Day.bat` | `.\Manage-Limiter.ps1 -Action ResetDay` | Reset today's usage counter to 0 and remove domain blocks |
| `QuickTest-15Sec.bat` | `.\Manage-Limiter.ps1 -Action Test15Sec` | Fast-forward to 1 minute remaining to verify blocking |
| — | `.\Manage-Limiter.ps1 -Action Uninstall` | Remove scheduled tasks, unlock directories, and clean `hosts` |

---

## Configuration

Modify `config.json` to customize rules:

- `dailyLimitSeconds`: Daily allowance in seconds (e.g. `3600` for 1 hour).
- `warningRemainingSeconds`: Remaining time threshold to trigger warnings (default: `300`).
- `pollIntervalSeconds`: Monitoring frequency in seconds (default: `60`).
- `socialSites`: List of tracked websites, domains, and window title keywords.
- `gameProcesses`: List of game executable process names.
- `gamePathKeywords`: Common directory paths for games (e.g., Steam library, Epic Games).
- `browserProcesses`: Recognized web browser processes.

---

## License

This project is licensed under the MIT License.

