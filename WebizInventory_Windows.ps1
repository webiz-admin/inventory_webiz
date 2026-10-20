#Requires -Version 5.1
<#
.SYNOPSIS
    Webiz Inventory Agent for Windows — self-contained, no Python needed.
    First run: Right-click → Run with PowerShell  (or run as any user).
    After that: registered in Task Scheduler, runs silently at every login,
                shows the form only when 6 months have elapsed.
.PARAMETER Force
    Show the form now, ignoring the 6-month / 24-hour guard (for testing).
.PARAMETER NoUpdate
    Skip the GitHub update check (passed after an update restart, so a restart can never loop).
#>
param([switch]$Force, [switch]$NoUpdate)

$ProgressPreference = "SilentlyContinue"   # ps2exe -NoConsole would show Invoke-WebRequest progress as a window
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

# ════════════════════════════════════════════════════════════════════════════════
#  CONFIGURATION
#  This file is PUBLIC and self-updates from GitHub — never put real values here.
#  Build_Windows_EXE.cmd / build_installers.sh stamp them from webiz_config.json
#  into the distributed copy; on first run they are saved to
#  %LOCALAPPDATA%\WebizInventory\config.json, which later (unstamped) versions read.
#  Emails are sent by the Apps Script — the agent holds no SMTP secret.
# ════════════════════════════════════════════════════════════════════════════════
$EmbeddedAppsScriptUrl = "__WEBIZ_APPS_SCRIPT_URL__"
$EmbeddedAgentToken    = "__WEBIZ_AGENT_TOKEN__"
$GitHubRawUrl  = "https://raw.githubusercontent.com/webiz-admin/inventory_webiz/main/WebizInventory_Windows.ps1"
# ════════════════════════════════════════════════════════════════════════════════

$IntervalMonths   = 6
$CancelRetryHours = 24
$TaskName         = "WebizInventoryAgent"
$Projects         = @("Webiz ERP","Fundbox","Playtika","Artlist","The5%ers","Other")

$StateDir   = "$env:LOCALAPPDATA\WebizInventory"
$StateFile  = "$StateDir\state.json"
$QueueFile  = "$StateDir\queue.json"
$LogFile    = "$StateDir\agent.log"
$ConfigFile = "$StateDir\config.json"
# Resolve current script/exe path
# - PS1 mode : $MyInvocation.MyCommand.Path holds the .ps1 path
# - EXE mode : $PSCommandPath is null in ps2exe, use Process.MainModule.FileName instead
$ScriptPath = if ($MyInvocation.MyCommand.Path) { $MyInvocation.MyCommand.Path } `
              else { [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName }
# Detect whether we are running as a compiled EXE (ps2exe) or a plain PS1
$IsExe      = $ScriptPath -like "*.exe" -and $ScriptPath -notlike "*powershell*" -and $ScriptPath -notlike "*pwsh*"
# The installed agent is always the .ps1 (it self-updates); the EXE only installs it.
# $ExeDest is used only when the EXE could not download the .ps1 (offline first install).
$PsDest     = "$StateDir\WebizInventory_Windows.ps1"
$ExeDest    = "$StateDir\WebizInventory_Windows.exe"
$LegacyCredResource = "WebizInventoryAgent"   # old versions stored the SMTP password here

# ── Ensure state dir ─────────────────────────────────────────────────────────
if (-not (Test-Path $StateDir)) { New-Item -ItemType Directory -Path $StateDir -Force | Out-Null }

# ── Logging ──────────────────────────────────────────────────────────────────
function Write-Log {
    param([string]$Msg, [string]$Level = "INFO")
    $line = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  $Level  $Msg"
    Add-Content -Path $LogFile -Value $line -Encoding UTF8
    # Write-Host intentionally omitted — ps2exe -NoConsole turns every Write-Host into a popup dialog
}

# ════════════════════════════════════════════════════════════════════════════════
#  CONFIG
# ════════════════════════════════════════════════════════════════════════════════
function Initialize-Config {
    $cfg = $null
    if (Test-Path $ConfigFile) {
        try { $cfg = Get-Content $ConfigFile -Raw | ConvertFrom-Json } catch {}
    }
    # A stamped (distributed) copy carries the values — persist them for future unstamped updates
    if ($EmbeddedAppsScriptUrl -notlike "__WEBIZ_*") {
        $cfg = [PSCustomObject]@{ apps_script_url = $EmbeddedAppsScriptUrl; agent_token = $EmbeddedAgentToken }
        $cfg | ConvertTo-Json | Set-Content -Path $ConfigFile -Encoding UTF8
    }
    if (-not $cfg) { Write-Log "No configuration found ($ConfigFile) — reinstall the agent." "ERROR" }
    return $cfg
}

$Config        = Initialize-Config
$AppsScriptUrl = if ($Config) { [string]$Config.apps_script_url } else { "" }
$AgentToken    = if ($Config) { [string]$Config.agent_token }     else { "" }

# Older versions stored the SMTP password in Windows Credential Manager — remove it.
function Remove-LegacySecret {
    try {
        [void][Windows.Security.Credentials.PasswordVault,Windows.Security.Credentials,ContentType=WindowsRuntime]
        $vault = New-Object Windows.Security.Credentials.PasswordVault
        foreach ($c in @($vault.FindAllByResource($LegacyCredResource))) {
            $vault.Remove($c)
            Write-Log "Removed legacy SMTP password from Credential Manager."
        }
    } catch {}   # FindAllByResource throws when nothing is stored
}

# ════════════════════════════════════════════════════════════════════════════════
#  SELF-UPDATE
# ════════════════════════════════════════════════════════════════════════════════
# Downloads the agent from GitHub. Returns its text, or $null when offline / not a valid agent.
function Get-AgentFromGitHub {
    if ($GitHubRawUrl -notlike "https://*") { Write-Log "Update skipped: GitHub URL must be https." "WARN"; return $null }
    try {
        Write-Log "Checking for updates…"
        $new = [string](Invoke-WebRequest -Uri $GitHubRawUrl -UseBasicParsing -TimeoutSec 8 `
                            -Headers @{ "Cache-Control" = "no-cache" }).Content
        $new = $new -replace "^﻿", ""
    } catch {
        Write-Log "Update check failed: $_" "WARN"; return $null
    }
    # Never replace a working agent with something that is not a valid agent
    if ($new -notmatch "Webiz Inventory Agent") {
        Write-Log "Update rejected: downloaded file is not the inventory agent." "WARN"; return $null
    }
    $parseTokens = $null; $parseErrors = $null
    [void][System.Management.Automation.Language.Parser]::ParseInput($new, [ref]$parseTokens, [ref]$parseErrors)
    if ($parseErrors -and $parseErrors.Count -gt 0) {
        Write-Log "Update rejected: downloaded script has parse errors." "WARN"; return $null
    }
    return $new
}

# Writes the text exactly as downloaded (plus BOM, which PS 5.1 needs for non-ASCII).
# Not Out-File: its extra trailing newline made every run look like an update (restart loop).
function Save-Agent([string]$Text) {
    [System.IO.File]::WriteAllText("$PsDest.new", $Text, (New-Object System.Text.UTF8Encoding $true))
    Move-Item -LiteralPath "$PsDest.new" -Destination $PsDest -Force
}

# BOM / line endings / trailing whitespace never count as a difference
function Get-AgentHash([string]$Text) {
    $t = ($Text -replace "^﻿", "" -replace "`r`n", "`n").TrimEnd()
    return [Convert]::ToBase64String([System.Security.Cryptography.SHA256]::Create().ComputeHash(
               [System.Text.Encoding]::UTF8.GetBytes($t)))
}

# Arguments for running the installed .ps1. -NoUpdate: it was just fetched, so a restart can never loop.
function Get-AgentArguments {
    $a = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PsDest`" -NoUpdate"
    if ($Force) { $a += " -Force" }
    return $a
}

function Invoke-SelfUpdate {
    $new = Get-AgentFromGitHub
    if (-not $new) { return }
    $installed = if (Test-Path $PsDest) { [System.IO.File]::ReadAllText($PsDest) } else { "" }
    if ((Get-AgentHash $new) -eq (Get-AgentHash $installed)) { return }
    try { Save-Agent $new } catch { Write-Log "Update could not be written: $_" "WARN"; return }
    if ([System.IO.Path]::GetFullPath($ScriptPath) -eq [System.IO.Path]::GetFullPath($PsDest)) {
        Write-Log "Update installed — restarting."
        Start-Process "powershell.exe" -ArgumentList (Get-AgentArguments) -WindowStyle Hidden
        exit 0
    }
    # Running from another location (e.g. Downloads) — installed copy updated, keep going
    Write-Log "Update installed to $PsDest. Continuing current run."
}

# EXE = installer: config.json is already written (stamped values); install the .ps1 from GitHub,
# point the task at it and hand over, so every later run self-updates. Offline: carry on as the EXE.
function Install-FromExe {
    $new = Get-AgentFromGitHub
    if ($new) {
        try {
            Save-Agent $new
            Register-StartupTask
            Write-Log "Installed $PsDest from GitHub — handing over to it."
            Start-Process "powershell.exe" -ArgumentList (Get-AgentArguments) -WindowStyle Hidden
            exit 0
        } catch {
            Write-Log "Install from GitHub failed: $_" "WARN"
        }
    }
    if (Test-Path $PsDest) {
        Register-StartupTask            # an earlier install exists — it self-updates on its next run
    } else {
        # Offline first install — the task runs the EXE until a later run can fetch the .ps1
        if ([System.IO.Path]::GetFullPath($ScriptPath) -ne [System.IO.Path]::GetFullPath($ExeDest)) {
            Copy-Item -LiteralPath $ScriptPath -Destination $ExeDest -Force -ErrorAction SilentlyContinue
        }
        Register-StartupTask -Exe
    }
    Write-Log "GitHub unreachable — continuing with the EXE."
}

# ════════════════════════════════════════════════════════════════════════════════
#  6-MONTH + 24 H GUARD
# ════════════════════════════════════════════════════════════════════════════════
function Get-State {
    if (Test-Path $StateFile) {
        try { return Get-Content $StateFile -Raw | ConvertFrom-Json }
        catch {}
    }
    return [PSCustomObject]@{ last_run = $null; cancelled_at = $null }
}

function Save-State($state) {
    $state | ConvertTo-Json | Set-Content -Path $StateFile -Encoding UTF8
}

function Test-ShouldRun {
    $state = Get-State
    $now   = Get-Date

    if ($state.last_run) {
        $last    = [datetime]$state.last_run
        $months  = ($now.Year - $last.Year) * 12 + $now.Month - $last.Month + ($now.Day - $last.Day) / 30.0
        if ($months -lt $IntervalMonths) {
            Write-Log ("Last check-in {0:F1} months ago — not due yet. Exiting." -f $months)
            return $false
        }
    }

    if ($state.cancelled_at) {
        $cancelled = [datetime]$state.cancelled_at
        $diffH     = ($now - $cancelled).TotalHours
        if ($diffH -lt $CancelRetryHours) {
            Write-Log ("Cancelled {0:F1} h ago — retry window not reached. Exiting." -f $diffH)
            return $false
        }
    }
    return $true
}

# ════════════════════════════════════════════════════════════════════════════════
#  HARDWARE COLLECTION
# ════════════════════════════════════════════════════════════════════════════════
function Get-Hardware {
    $hw = @{}
    try {
        $cs   = Get-CimInstance Win32_ComputerSystem  -ErrorAction Stop
        $bios = Get-CimInstance Win32_BIOS            -ErrorAction Stop
        $cpu  = Get-CimInstance Win32_Processor       -ErrorAction Stop | Select-Object -First 1
        $disk = Get-CimInstance Win32_DiskDrive       -ErrorAction Stop | Select-Object -First 1
        $os   = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        $net  = Get-CimInstance Win32_NetworkAdapterConfiguration -Filter "IPEnabled=True" |
                Select-Object -First 1

        $hw.brand   = ($cs.Manufacturer -replace '\s+',' ').Trim()
        $hw.model   = ($cs.Model        -replace '\s+',' ').Trim()
        $hw.serial_number = $bios.SerialNumber.Trim()
        $hw.cpu     = ($cpu.Name        -replace '\s+',' ').Trim()
        $ram_gb     = [math]::Round($cs.TotalPhysicalMemory / 1GB)
        $hw.ram     = "$ram_gb GB"
        $disk_gb    = if ($disk.Size) { [math]::Round($disk.Size / 1GB) } else { "?" }
        $hw.storage = "$disk_gb GB  ($($disk.Model))"
        $hw.os      = "$($os.Caption) $($os.Version)"
        $hw.hostname   = $env:COMPUTERNAME
        $hw.ip_address = if ($net.IPAddress) { $net.IPAddress[0] } else { "N/A" }
        $hw.timestamp  = (Get-Date -Format "yyyy-MM-ddTHH:mm:ss")
    } catch {
        Write-Log "Hardware collection error: $_" "ERROR"
        $hw.brand = $hw.model = $hw.serial_number = $hw.cpu = $hw.ram = $hw.storage = "N/A"
        $hw.os = [System.Environment]::OSVersion.VersionString
        $hw.hostname = $env:COMPUTERNAME
        $hw.ip_address = "N/A"
        $hw.timestamp  = (Get-Date -Format "yyyy-MM-ddTHH:mm:ss")
    }
    $hw.monitors = @(Get-Monitors)
    $hw.screen_size = $script:BuiltinScreenIn   # detected, not asked from the user
    return $hw
}

# ════════════════════════════════════════════════════════════════════════════════
#  EXTERNAL MONITORS (QueryDisplayConfig + registry EDID — no admin needed)
#  USB-C / Thunderbolt monitors use DisplayPort Alt Mode, so they are reported as
#  "DisplayPort/USB-C". Brand names are mapped from the PNP id by the Apps Script.
# ════════════════════════════════════════════════════════════════════════════════
# Raw EDID of a monitor (e.g. DISPLAY\DELF071\4&1540260c&0&UID198155) — the registry copy is readable without admin.
function Get-Edid([string]$InstanceId) {
    try {
        $key  = "HKLM:\SYSTEM\CurrentControlSet\Enum\$InstanceId\Device Parameters"
        $edid = [byte[]](Get-ItemProperty -LiteralPath $key -Name EDID -ErrorAction Stop).EDID
        if ($edid.Length -ge 128) { return ,$edid }
    } catch {}
    return $null
}

# Decodes the EDID base block into the same fields WmiMonitorID would give.
# Physical size (mm) comes from the preferred timing — the header only has whole cm.
function ConvertFrom-Edid([byte[]]$e) {
    $w   = ([int]$e[8] -shl 8) -bor $e[9]
    $mfg = -join (@((($w -shr 10) -band 31), (($w -shr 5) -band 31), ($w -band 31)) | ForEach-Object { [char](64 + $_) })
    $info = @{
        manufacturer_id = $mfg
        product_code    = "{0:X4}" -f ([int]$e[10] -bor ([int]$e[11] -shl 8))
        name = ""; serial = ""; resolution = ""; width_mm = 0; height_mm = 0
        year = if ($e[17]) { "$(1990 + $e[17])" } else { "" }
    }
    $num = [BitConverter]::ToUInt32($e, 12)
    if ($num) { $info.serial = "$num" }
    foreach ($o in 54, 72, 90, 108) {
        if ($e[$o] -or $e[$o + 1]) {
            if ($o -eq 54) {   # first detailed timing = preferred mode
                $info.resolution = "{0}x{1}" -f ($e[56] -bor (([int]$e[58] -band 0xF0) -shl 4)),
                                                ($e[59] -bor (([int]$e[61] -band 0xF0) -shl 4))
                $info.width_mm   = $e[66] -bor (([int]$e[68] -band 0xF0) -shl 4)
                $info.height_mm  = $e[67] -bor (([int]$e[68] -band 0x0F) -shl 8)
            }
            continue
        }
        $text = ([System.Text.Encoding]::ASCII.GetString($e, $o + 5, 13) -split "`n")[0].Trim()
        if ($e[$o + 3] -eq 0xFC) { $info.name = $text }
        if ($e[$o + 3] -eq 0xFF) { $info.serial = $text }   # text serial wins over the numeric one
    }
    if (-not ($info.width_mm -and $info.height_mm) -and $e[21] -and $e[22]) {
        $info.width_mm = $e[21] * 10; $info.height_mm = $e[22] * 10
    }
    return $info
}

# Active displays as @{ Tech; InstanceId }. QueryDisplayConfig needs no admin, unlike the
# root\wmi monitor classes, which return "Access denied" to the non-elevated task.
function Get-DisplayTargets {
    if (-not ("WebizDisplayConfig" -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public static class WebizDisplayConfig {
    [StructLayout(LayoutKind.Sequential)] struct LUID { public uint Low; public int High; }
    [StructLayout(LayoutKind.Sequential)] struct PATH_SOURCE { public LUID adapterId; public uint id, modeInfoIdx, statusFlags; }
    [StructLayout(LayoutKind.Sequential)] struct PATH_TARGET {
        public LUID adapterId; public uint id, modeInfoIdx, outputTechnology, rotation, scaling,
        refreshNum, refreshDen, scanLineOrdering; public int targetAvailable; public uint statusFlags; }
    [StructLayout(LayoutKind.Sequential)] struct PATH_INFO { public PATH_SOURCE source; public PATH_TARGET target; public uint flags; }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] struct TARGET_NAME {
        public uint type, size; public LUID adapterId; public uint id, flags, outputTechnology;
        public ushort edidManufactureId, edidProductCodeId; public uint connectorInstance;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)]  public string friendlyName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string devicePath; }
    [DllImport("user32.dll")] static extern int GetDisplayConfigBufferSizes(uint flags, out uint numPaths, out uint numModes);
    [DllImport("user32.dll")] static extern int QueryDisplayConfig(uint flags, ref uint numPaths, [Out] PATH_INFO[] paths,
                                                                   ref uint numModes, IntPtr modes, IntPtr topology);
    [DllImport("user32.dll")] static extern int DisplayConfigGetDeviceInfo(ref TARGET_NAME request);

    // "<outputTechnology>\t<monitorDevicePath>" per active display
    public static string[] GetActiveTargets() {
        const uint QDC_ONLY_ACTIVE_PATHS = 2;
        uint np, nm; int rc; PATH_INFO[] paths;
        do {
            rc = GetDisplayConfigBufferSizes(QDC_ONLY_ACTIVE_PATHS, out np, out nm);
            if (rc != 0) throw new System.ComponentModel.Win32Exception(rc);
            paths = new PATH_INFO[np];
            IntPtr modes = Marshal.AllocHGlobal((int)Math.Max(nm, 1) * 64);   // DISPLAYCONFIG_MODE_INFO = 64 bytes
            try { rc = QueryDisplayConfig(QDC_ONLY_ACTIVE_PATHS, ref np, paths, ref nm, modes, IntPtr.Zero); }
            finally { Marshal.FreeHGlobal(modes); }
        } while (rc == 122);   // ERROR_INSUFFICIENT_BUFFER: displays changed in between
        if (rc != 0) throw new System.ComponentModel.Win32Exception(rc);
        var result = new List<string>();
        for (int i = 0; i < np; i++) {
            var req = new TARGET_NAME();
            req.type = 2;   // DISPLAYCONFIG_DEVICE_INFO_GET_TARGET_NAME
            req.size = (uint)Marshal.SizeOf(typeof(TARGET_NAME));
            req.adapterId = paths[i].target.adapterId;
            req.id = paths[i].target.id;
            if (DisplayConfigGetDeviceInfo(ref req) == 0)
                result.Add(paths[i].target.outputTechnology + "\t" + req.devicePath);
        }
        return result.ToArray();
    }
}
'@
    }
    foreach ($t in [WebizDisplayConfig]::GetActiveTargets()) {
        $tech, $path = $t -split "`t", 2
        # \\?\DISPLAY#DELF071#4&1540260c&0&UID198155#{guid} -> DISPLAY\DELF071\4&1540260c&0&UID198155
        $parts = $path.TrimStart('\', '?') -split '#'
        if ($parts.Count -ge 3) { [pscustomobject]@{ Tech = [uint32]$tech; InstanceId = $parts[0..2] -join '\' } }
    }
}

# Fallback when QueryDisplayConfig is unavailable (works only elevated)
function Get-WmiDisplayTargets {
    Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorConnectionParams -ErrorAction Stop | ForEach-Object {
        [pscustomobject]@{ Tech = [uint32]$_.VideoOutputTechnology; InstanceId = $_.InstanceName -replace '_\d+$', '' }
    }
}

# Marketed laptop sizes: the measured active area is slightly smaller (15.6" ≈ 15.55"),
# so snap to the nearest marketed size within 0.2".
$LaptopSizes = @(11.6, 12.0, 12.3, 12.5, 13.0, 13.3, 13.4, 13.5, 14.0, 14.5, 15.0, 15.6, 16.0, 17.3, 18.0)

function Get-Monitors {
    $monitors = @()
    $script:BuiltinScreenIn = ""   # set as a side result: the laptop's own panel size
    try {
        $targets = try { @(Get-DisplayTargets) } catch {
            Write-Log "QueryDisplayConfig failed ($_) — trying WMI." "WARN"; @(Get-WmiDisplayTargets)
        }
        $seen = @{}
        foreach ($t in $targets) {
            if ($seen[$t.InstanceId]) { continue }   # same monitor on several paths (clone mode)
            $seen[$t.InstanceId] = $true
            $edid = Get-Edid $t.InstanceId
            $info = if ($edid) { ConvertFrom-Edid $edid } else {
                # No EDID: the hardware id still carries the PNP id + product code (DISPLAY\DELF071\...).
                # Without either it is a virtual display (Remote Desktop, Default_Monitor) — skip it.
                if (($t.InstanceId -split '\\')[1] -notmatch '^([A-Z]{3})([0-9A-F]{4})$') { continue }
                @{ manufacturer_id = $Matches[1]; product_code = $Matches[2]
                   name = ""; serial = ""; resolution = ""; width_mm = 0; height_mm = 0; year = "" }
            }
            $diag = if ($info.width_mm -and $info.height_mm) {
                [math]::Sqrt([math]::Pow($info.width_mm, 2) + [math]::Pow($info.height_mm, 2)) / 25.4
            } else { 0 }

            # Built-in panel: LVDS (6), embedded DisplayPort (11), embedded UDI (13), INTERNAL (0x80000000)
            if ($t.Tech -in @(6, 11, 13) -or $t.Tech -eq 2147483648) {
                if ($diag -and -not $script:BuiltinScreenIn) {
                    $nearest = $LaptopSizes | Sort-Object { [math]::Abs($_ - $diag) } | Select-Object -First 1
                    $val = if ([math]::Abs($nearest - $diag) -le 0.2) { $nearest } else { [math]::Round($diag, 1) }
                    $script:BuiltinScreenIn = $val.ToString([System.Globalization.CultureInfo]::InvariantCulture)
                }
                continue
            }
            $connection = switch ($t.Tech) {
                0  { "VGA" }
                4  { "DVI" }
                5  { "HDMI" }
                10 { "DisplayPort/USB-C" }
                12 { "UDI" }
                15 { "Miracast" }
                16 { "Indirect (dock/USB)" }
                default { "" }
            }
            $serial = $info.serial
            if ($serial -match '^0+$') { $serial = "" }
            $monitors += [pscustomobject]@{
                manufacturer_id = $info.manufacturer_id
                name            = $info.name
                product_code    = $info.product_code
                serial          = $serial
                size_in         = if ($diag) { "$([math]::Round($diag))" } else { "" }
                resolution      = $info.resolution
                connection      = $connection
                year            = $info.year
            }
            if ($monitors.Count -ge 8) { break }
        }
    } catch {
        Write-Log "Monitor detection failed: $_" "WARN"   # never blocks the check-in
    }
    return $monitors
}

function Format-Monitors($monitors) {
    if (-not $monitors -or @($monitors).Count -eq 0) { return "none detected" }
    return (@($monitors) | ForEach-Object {
        $label = if ($_.name) { $_.name } else { $_.manufacturer_id }
        if ($_.size_in)    { $label += " $($_.size_in)`"" }
        if ($_.connection) { $label += " ($($_.connection))" }
        $label
    }) -join "; "
}

# ════════════════════════════════════════════════════════════════════════════════
#  GOOGLE SHEETS — via Apps Script webhook (no service account needed)
# ════════════════════════════════════════════════════════════════════════════════
function Submit-ToSheets {
    param([hashtable]$Payload)
    if ($AppsScriptUrl -notlike "https://*") {
        Write-Log "apps_script_url missing or not https in config — cannot submit." "ERROR"
        return $false
    }
    try {
        # Token is added only here so it is never written to the offline queue
        $req = @{} + $Payload
        $req["token"] = $AgentToken
        $body = $req | ConvertTo-Json -Compress -Depth 5   # monitors are nested objects
        # Send bytes: PS 5.1 encodes a string body as ISO-8859-1 (non-Latin names would become "?")
        $resp = Invoke-RestMethod -Uri $AppsScriptUrl -Method POST -Body ([System.Text.Encoding]::UTF8.GetBytes($body)) `
                    -ContentType "application/json; charset=utf-8" -TimeoutSec 15
        return ($resp.status -eq "ok")
    } catch {
        Write-Log "HTTP submit failed: $_" "WARN"
        return $false
    }
}

# ── Offline queue ─────────────────────────────────────────────────────────────
# Always a flat array: piping a 1-element array to ConvertTo-Json writes a bare object,
# which broke the next "+=" — so read via foreach and write with -InputObject.
function Read-Queue {
    $items = @()
    if (Test-Path $QueueFile) {
        try { foreach ($i in (Get-Content $QueueFile -Raw | ConvertFrom-Json)) { if ($i) { $items += $i } } }
        catch { Write-Log "Offline queue unreadable: $_" "WARN" }
    }
    return ,$items
}

function Save-Queue($Items) {
    ConvertTo-Json -InputObject @($Items) -Depth 5 | Set-Content $QueueFile -Encoding UTF8
}

function Add-ToQueue($Payload) {
    $items = Read-Queue
    $items += $Payload
    Save-Queue $items
    Write-Log "Saved to offline queue (total: $($items.Count))"
}

function Flush-Queue {
    if (-not (Test-Path $QueueFile)) { return }
    $items = Read-Queue
    if ($items.Count -eq 0) { Remove-Item $QueueFile -Force -ErrorAction SilentlyContinue; return }

    Write-Log "Flushing $($items.Count) queued submission(s)…"
    $pending = @()
    foreach ($item in $items) {
        $tbl = @{}
        $item.PSObject.Properties | ForEach-Object { $tbl[$_.Name] = $_.Value }
        $tbl["submission_type"] = "queued"
        if (Submit-ToSheets $tbl) {
            Write-Log "  Flushed: $($item.timestamp)"
        } else {
            $pending += $item
        }
    }
    if ($pending.Count -gt 0) {
        Save-Queue $pending
        Write-Log "  $($pending.Count) entries still pending."
    } else {
        Remove-Item $QueueFile -Force
        Write-Log "  Queue fully flushed."
    }
}

# ════════════════════════════════════════════════════════════════════════════════
#  WINFORMS GUI
# ════════════════════════════════════════════════════════════════════════════════
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

Add-Type @"
using System;
using System.Runtime.InteropServices;
public class WinForeground {
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
    [DllImport("user32.dll")] public static extern void SwitchToThisWindow(IntPtr hWnd, bool altTab);
}
"@

function Show-InventoryForm {
    param([hashtable]$HW)

    $result = @{ submitted = $false; user_data = @{}; closing = $false }

    # ── Form ──────────────────────────────────────────────────────────────────
    $form                  = New-Object System.Windows.Forms.Form
    $form.Text             = "Webiz Inventory Agent"
    $form.ClientSize       = New-Object System.Drawing.Size(520, 640)   # height is fitted after layout
    $form.StartPosition    = "CenterScreen"
    $form.FormBorderStyle  = "FixedDialog"
    $form.MaximizeBox      = $false
    $form.BackColor        = [System.Drawing.Color]::FromArgb(245, 247, 250)
    $form.Font             = New-Object System.Drawing.Font("Segoe UI", 10)

    # ── Header bar ────────────────────────────────────────────────────────────
    $hdr           = New-Object System.Windows.Forms.Panel
    $hdr.Location  = New-Object System.Drawing.Point(0, 0)
    $hdr.Size      = New-Object System.Drawing.Size(520, 80)
    $hdr.BackColor = [System.Drawing.Color]::FromArgb(26, 43, 90)

    $logoLbl           = New-Object System.Windows.Forms.Label
    $logoLbl.Text      = "WEBIZ"
    $logoLbl.Font      = New-Object System.Drawing.Font("Segoe UI", 28, [System.Drawing.FontStyle]::Bold)
    $logoLbl.ForeColor = [System.Drawing.Color]::White
    $logoLbl.Location  = New-Object System.Drawing.Point(22, 14)
    $logoLbl.AutoSize  = $true
    $hdr.Controls.Add($logoLbl)

    # Logo image override (place webiz_logo.png next to this script)
    $logoFile = Join-Path (Split-Path $ScriptPath) "webiz_logo.png"
    if (Test-Path $logoFile) {
        try {
            $img           = [System.Drawing.Image]::FromFile($logoFile)
            $pb            = New-Object System.Windows.Forms.PictureBox
            $pb.Image      = $img
            $pb.SizeMode   = "Zoom"
            $pb.Location   = New-Object System.Drawing.Point(16, 10)
            $pb.Size       = New-Object System.Drawing.Size(160, 60)
            $pb.BackColor  = [System.Drawing.Color]::FromArgb(26, 43, 90)
            $hdr.Controls.Remove($logoLbl)
            $hdr.Controls.Add($pb)
        } catch {}
    }

    $form.Controls.Add($hdr)

    # ── Red accent line ───────────────────────────────────────────────────────
    $accent           = New-Object System.Windows.Forms.Panel
    $accent.Location  = New-Object System.Drawing.Point(0, 80)
    $accent.Size      = New-Object System.Drawing.Size(520, 4)
    $accent.BackColor = [System.Drawing.Color]::FromArgb(232, 48, 58)
    $form.Controls.Add($accent)

    # ── Welcome text ──────────────────────────────────────────────────────────
    $welcome           = New-Object System.Windows.Forms.Label
    $welcome.Text      = "Hello, I am Inventory Agent of Webiz and I need following information"
    $welcome.Location  = New-Object System.Drawing.Point(26, 96)
    $welcome.Size      = New-Object System.Drawing.Size(468, 40)
    $welcome.Font      = New-Object System.Drawing.Font("Segoe UI", 11)
    $form.Controls.Add($welcome)

    # ── Input rows ────────────────────────────────────────────────────────────
    $yPos = 148

    foreach ($row in @(
        @{ Label = "First Name *"; Var = "tbFirst" },
        @{ Label = "Last Name *";  Var = "tbLast"  },
        @{ Label = "Email *";      Var = "tbEmail" }
    )) {
        $lbl          = New-Object System.Windows.Forms.Label
        $lbl.Text     = $row.Label
        $lbl.Location = New-Object System.Drawing.Point(26, ($yPos + 4))
        $lbl.Size     = New-Object System.Drawing.Size(120, 22)
        $lbl.Font     = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
        $form.Controls.Add($lbl)

        $tb           = New-Object System.Windows.Forms.TextBox
        $tb.Location  = New-Object System.Drawing.Point(152, $yPos)
        $tb.Size      = New-Object System.Drawing.Size(342, 28)
        $tb.Font      = New-Object System.Drawing.Font("Segoe UI", 10)
        $form.Controls.Add($tb)

        Set-Variable -Name $row.Var -Value $tb
        $yPos += 44
    }

    # Project dropdown
    $lblProj          = New-Object System.Windows.Forms.Label
    $lblProj.Text     = "Project *"
    $lblProj.Location = New-Object System.Drawing.Point(26, ($yPos + 4))
    $lblProj.Size     = New-Object System.Drawing.Size(120, 22)
    $lblProj.Font     = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
    $form.Controls.Add($lblProj)

    $cbProject             = New-Object System.Windows.Forms.ComboBox
    $cbProject.Location    = New-Object System.Drawing.Point(152, $yPos)
    $cbProject.Size        = New-Object System.Drawing.Size(342, 28)
    $cbProject.Font        = New-Object System.Drawing.Font("Segoe UI", 10)
    $cbProject.DropDownStyle = "DropDownList"
    $Projects | ForEach-Object { $cbProject.Items.Add($_) | Out-Null }
    $cbProject.SelectedIndex = 0
    $form.Controls.Add($cbProject)
    $yPos += 44

    # ── Separator ─────────────────────────────────────────────────────────────
    $sep           = New-Object System.Windows.Forms.Panel
    $sep.Location  = New-Object System.Drawing.Point(26, ($yPos + 10))
    $sep.Size      = New-Object System.Drawing.Size(468, 1)
    $sep.BackColor = [System.Drawing.Color]::FromArgb(208, 213, 221)
    $form.Controls.Add($sep)
    $yPos += 22

    # ── Device info preview ───────────────────────────────────────────────────
    $lblHint           = New-Object System.Windows.Forms.Label
    $lblHint.Text      = "Device information that will be recorded:"
    $lblHint.Location  = New-Object System.Drawing.Point(26, $yPos)
    $lblHint.Size      = New-Object System.Drawing.Size(468, 20)
    $lblHint.Font      = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
    $lblHint.ForeColor = [System.Drawing.Color]::FromArgb(55, 65, 81)
    $form.Controls.Add($lblHint)
    $yPos += 24

    $hwPanel           = New-Object System.Windows.Forms.Panel
    $hwPanel.Location  = New-Object System.Drawing.Point(26, $yPos)
    $hwPanel.Size      = New-Object System.Drawing.Size(468, 178)
    $hwPanel.BackColor = [System.Drawing.Color]::FromArgb(229, 234, 242)
    $form.Controls.Add($hwPanel)

    $hwRows = [ordered]@{
        "Device"   = "$($HW.brand) $($HW.model)"
        "Screen"   = if ($HW.screen_size) { "$($HW.screen_size)`" (built-in)" } else { "no built-in display" }
        "Serial"   = $HW.serial_number
        "OS"       = $HW.os
        "CPU"      = $HW.cpu
        "RAM"      = $HW.ram
        "Storage"  = $HW.storage
        "Hostname" = "$($HW.hostname)  /  $($HW.ip_address)"
        "Monitors" = Format-Monitors $HW.monitors
    }
    $ry = 8
    foreach ($key in $hwRows.Keys) {
        $kLbl           = New-Object System.Windows.Forms.Label
        $kLbl.Text      = "${key}:"
        $kLbl.Location  = New-Object System.Drawing.Point(10, $ry)
        $kLbl.Size      = New-Object System.Drawing.Size(72, 18)
        $kLbl.Font      = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
        $kLbl.ForeColor = [System.Drawing.Color]::FromArgb(55, 65, 81)
        $hwPanel.Controls.Add($kLbl)

        $vLbl           = New-Object System.Windows.Forms.Label
        $vLbl.Text      = $hwRows[$key]
        $vLbl.Location  = New-Object System.Drawing.Point(86, $ry)
        $vLbl.Size      = New-Object System.Drawing.Size(374, 18)
        $vLbl.Font      = New-Object System.Drawing.Font("Segoe UI", 9)
        $vLbl.ForeColor = [System.Drawing.Color]::FromArgb(31, 41, 55)
        $vLbl.AutoEllipsis = $true   # long values (several monitors) end in "…"; full text on hover
        $hwPanel.Controls.Add($vLbl)

        $ry += 18
    }
    $yPos += 186

    # ── Buttons ───────────────────────────────────────────────────────────────
    $btnSubmit             = New-Object System.Windows.Forms.Button
    $btnSubmit.Text        = "Submit"
    $btnSubmit.Location    = New-Object System.Drawing.Point(318, ($yPos + 8))
    $btnSubmit.Size        = New-Object System.Drawing.Size(90, 32)
    $btnSubmit.Font        = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
    $btnSubmit.BackColor   = [System.Drawing.Color]::FromArgb(232, 48, 58)
    $btnSubmit.ForeColor   = [System.Drawing.Color]::White
    $btnSubmit.FlatStyle   = "Flat"
    $btnSubmit.FlatAppearance.BorderSize = 0
    $form.Controls.Add($btnSubmit)

    $btnCancel             = New-Object System.Windows.Forms.Button
    $btnCancel.Text        = "Cancel"
    $btnCancel.Location    = New-Object System.Drawing.Point(418, ($yPos + 8))
    $btnCancel.Size        = New-Object System.Drawing.Size(76, 32)
    $btnCancel.Font        = New-Object System.Drawing.Font("Segoe UI", 10)
    $btnCancel.BackColor   = [System.Drawing.Color]::FromArgb(229, 231, 235)
    $btnCancel.FlatStyle   = "Flat"
    $btnCancel.FlatAppearance.BorderSize = 0
    $form.Controls.Add($btnCancel)

    # Fit the window to the content (buttons + 16 px margin)
    $form.ClientSize = New-Object System.Drawing.Size(520, ($yPos + 8 + 32 + 16))

    # ── Event handlers ────────────────────────────────────────────────────────
    $btnSubmit.Add_Click({
        if (-not $tbFirst.Text.Trim()) {
            [System.Windows.Forms.MessageBox]::Show("Please enter your First Name.", "Missing field") | Out-Null; return
        }
        if (-not $tbLast.Text.Trim()) {
            [System.Windows.Forms.MessageBox]::Show("Please enter your Last Name.", "Missing field") | Out-Null; return
        }
        if ($tbEmail.Text -notmatch '^[^@]+@[^@]+\.[^@]+$') {
            [System.Windows.Forms.MessageBox]::Show("Please enter a valid email address.", "Invalid email") | Out-Null; return
        }
        $result.submitted = $true
        $result.user_data  = @{
            first_name  = $tbFirst.Text.Trim()
            last_name   = $tbLast.Text.Trim()
            email       = $tbEmail.Text.Trim()
            project     = $cbProject.SelectedItem.ToString()
        }
        $form.Close()
    })

    $btnCancel.Add_Click({
        $ans = [System.Windows.Forms.MessageBox]::Show(
            "Are you sure you want to skip?`n`n• IT will be notified`n• You'll be reminded again in 24 hours",
            "Cancel check-in",
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        )
        if ($ans -eq "Yes") { $result.closing = $true; $result.submitted = $false; $form.Close() }
    })

    $form.Add_FormClosing({
        param($s, $e)
        # Skip if already confirmed (Submit or Cancel-Yes already handled it)
        if ($result.submitted -or $result.closing) { return }
        # X button — treat same as Cancel
        $ans = [System.Windows.Forms.MessageBox]::Show(
            "Are you sure you want to skip?`n`n• IT will be notified`n• You'll be reminded again in 24 hours",
            "Cancel check-in",
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        )
        if ($ans -eq "Yes") {
            $result.closing = $true
            $result.submitted = $false
        } else {
            $e.Cancel = $true   # block the close
        }
    })

    $form.Add_Load({
        $form.WindowState = [System.Windows.Forms.FormWindowState]::Normal
        [WinForeground]::ShowWindow($form.Handle, 9)     # SW_RESTORE
        [WinForeground]::SetForegroundWindow($form.Handle)
        [WinForeground]::SwitchToThisWindow($form.Handle, $true)
        $form.TopMost = $true
        $form.Activate()
        $form.TopMost = $false   # release TopMost after focus so user can alt-tab away
    })

    $form.ShowDialog() | Out-Null
    return $result
}

# ════════════════════════════════════════════════════════════════════════════════
#  TASK SCHEDULER REGISTRATION (runs on first install)
# ════════════════════════════════════════════════════════════════════════════════
function Register-StartupTask {
    param([switch]$Exe)   # -Exe: only for an offline EXE install that has no .ps1 yet
    $exec = if ($Exe) { $ExeDest } else { "powershell.exe" }
    $args_ = if ($Exe) { "" } else { "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -NonInteractive -File `"$PsDest`"" }
    # powershell.exe started by the task flashes its console before -WindowStyle Hidden applies (every hour).
    # A headless conhost (Windows 10 1809+) never shows one, and never opens Windows Terminal on Windows 11.
    if (-not $Exe -and [Environment]::OSVersion.Version.Build -ge 17763) {
        $args_ = "--headless $exec $args_"
        $exec  = "conhost.exe"
    }

    # Re-register when missing or pointing elsewhere (e.g. an old EXE install whose file is gone)
    $existing = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    $cur = if ($existing) { @($existing.Actions)[0] } else { $null }
    if ($cur -and $cur.Execute -eq $exec -and "$($cur.Arguments)" -eq $args_) { return }

    try {
        $action = if ($Exe) { New-ScheduledTaskAction -Execute $exec } `
                  else      { New-ScheduledTaskAction -Execute $exec -Argument $args_ }

        $triggerLogon       = New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME
        $triggerLogon.Delay = "PT1M30S"   # wait 90 s for desktop to be ready (ISO 8601 format)

        # Hourly trigger so the 24-h cancel retry fires even when the user stays logged in
        $triggerHourly = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(2) `
            -RepetitionInterval (New-TimeSpan -Hours 1) `
            -RepetitionDuration (New-TimeSpan -Days 9999)

        $settings = New-ScheduledTaskSettingsSet `
            -ExecutionTimeLimit (New-TimeSpan -Hours 1) `
            -MultipleInstances  IgnoreNew
        # Allow running on battery — set via CIM properties (parameter name varies by PS version)
        $settings.DisallowStartIfOnBatteries = $false
        $settings.StopIfGoingOnBatteries     = $false

        $principal = New-ScheduledTaskPrincipal `
            -UserId   "$env:USERDOMAIN\$env:USERNAME" `
            -LogonType Interactive `
            -RunLevel Limited

        if ($existing) { Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue }
        Register-ScheduledTask -TaskName $TaskName -Action $action `
            -Trigger @($triggerLogon, $triggerHourly) `
            -Settings $settings -Principal $principal `
            -Description "Webiz Inventory Agent — checks in every 6 months" -ErrorAction Stop | Out-Null

        Write-Log "Task Scheduler task '$TaskName' registered: $exec $args_"
    } catch {
        Write-Log "Task registration failed: $_" "ERROR"
    }
}

# ════════════════════════════════════════════════════════════════════════════════
#  MAIN
# ════════════════════════════════════════════════════════════════════════════════
Write-Log ("=== Webiz Inventory Agent started === {0}{1}{2}" -f $ScriptPath,
           $(if ($Force) { " -Force" }), $(if ($NoUpdate) { " -NoUpdate" }))

if ($IsExe) {
    Install-FromExe   # hands over to the installed .ps1 (and exits) when GitHub is reachable
} else {
    # Stable installed copy for the task; self-update refreshes it from GitHub
    if (-not (Test-Path $PsDest)) { Copy-Item -LiteralPath $ScriptPath -Destination $PsDest -Force }
    Register-StartupTask
    if (-not $NoUpdate) { Invoke-SelfUpdate }
    # Left over from an offline EXE install — the task now runs the .ps1
    if (Test-Path $ExeDest) { Remove-Item $ExeDest -Force -ErrorAction SilentlyContinue }
}
Remove-LegacySecret

# Flush offline queue
Flush-Queue

# Guard: exit if not due (-Force skips it, for testing)
if ($Force) { Write-Log "-Force: skipping the 6-month / 24-hour guard." }
elseif (-not (Test-ShouldRun)) { exit 0 }

# Collect hardware
Write-Log "Collecting hardware information…"
$hw = Get-Hardware
Write-Log "HW: $($hw | ConvertTo-Json -Compress -Depth 4)"

# Show GUI
$res = Show-InventoryForm -HW $hw

# ── Cancelled ─────────────────────────────────────────────────────────────────
if (-not $res.submitted) {
    $state = Get-State
    $state | Add-Member -NotePropertyName cancelled_at -NotePropertyValue (Get-Date -Format "o") -Force
    Save-State $state

    # Admin notification is sent by the Apps Script (best effort, not queued)
    $cancelPayload = @{ type = "cancelled" }
    foreach ($k in $hw.Keys) { $cancelPayload[$k] = $hw[$k] }
    $sent = Submit-ToSheets -Payload $cancelPayload
    Write-Log "Form cancelled (IT notified: $sent). Will retry in $CancelRetryHours h."
    exit 0
}

# ── Submitted ─────────────────────────────────────────────────────────────────
$ud = $res.user_data
$payload = @{
    type            = "checkin"
    submission_type = "online"
    timestamp     = $hw.timestamp
    monitors      = $hw.monitors
    first_name    = $ud.first_name
    last_name     = $ud.last_name
    email         = $ud.email
    project       = $ud.project
    screen_size   = $hw.screen_size
    hostname      = $hw.hostname
    ip_address    = $hw.ip_address
    brand         = $hw.brand
    model         = $hw.model
    serial_number = $hw.serial_number
    cpu           = $hw.cpu
    ram           = $hw.ram
    storage       = $hw.storage
    os            = $hw.os
}

Write-Log "Submitting to Google Sheets…"
$immediate = Submit-ToSheets -Payload $payload
if (-not $immediate) {
    Add-ToQueue $payload
}

# Update state
$state = Get-State
$state | Add-Member -NotePropertyName last_run     -NotePropertyValue (Get-Date -Format "o") -Force
$state | Add-Member -NotePropertyName cancelled_at -NotePropertyValue $null                  -Force
Save-State $state

# Confirmation email (admin + user) is sent by the Apps Script on receipt.

# Success dialog
$dialogMsg = "Thank you, $($ud.first_name)!`n`nYour device has been registered."
if (-not $immediate) { $dialogMsg += "`n`n(Offline — data will sync automatically.)" }
[System.Windows.Forms.MessageBox]::Show($dialogMsg, "Webiz Inventory – Done",
    [System.Windows.Forms.MessageBoxButtons]::OK,
    [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null

Write-Log "=== Completed successfully ==="
