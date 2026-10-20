#Requires -Version 5.1
<#
.SYNOPSIS
    Webiz Inventory Agent for Windows — self-contained, no Python needed.
    First run: Right-click → Run with PowerShell  (or run as any user).
    After that: registered in Task Scheduler, runs silently at every login,
                shows the form only when 6 months have elapsed.
#>

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
$ScriptDest = if ($IsExe) { "$StateDir\WebizInventory_Windows.exe" } `
                          else { "$StateDir\WebizInventory_Windows.ps1" }
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
function Invoke-SelfUpdate {
    if ($IsExe) { return }   # compiled EXE — distribute a new EXE to update
    if (-not $GitHubRawUrl -or $GitHubRawUrl -like "*YOUR_ORG*") { return }
    try {
        Write-Log "Checking for updates…"
        if ($GitHubRawUrl -notlike "https://*") { Write-Log "Update skipped: GitHub URL must be https." "WARN"; return }
        $new  = [string](Invoke-WebRequest -Uri $GitHubRawUrl -UseBasicParsing -TimeoutSec 8).Content
        $new  = $new -replace "^\uFEFF", ""   # Out-File adds its own BOM
        $cur  = [string](Get-Content -Path $ScriptPath -Raw -ErrorAction SilentlyContinue)
        # Normalise BOM + line endings so the same script never looks "different" (restart loop)
        $norm = { param($t) ($t -replace "^\uFEFF", "") -replace "`r`n", "`n" }
        $hash = { param($t) [Convert]::ToBase64String([System.Security.Cryptography.SHA256]::Create().ComputeHash(
                      [System.Text.Encoding]::UTF8.GetBytes($t))) }
        if ((&$hash (&$norm $new)) -ne (&$hash (&$norm $cur))) {
            # Never replace a working agent with something that is not a valid agent
            if ($new -notmatch "Webiz Inventory Agent") {
                Write-Log "Update rejected: downloaded file is not the inventory agent." "WARN"; return
            }
            $parseTokens = $null; $parseErrors = $null
            [void][System.Management.Automation.Language.Parser]::ParseInput($new, [ref]$parseTokens, [ref]$parseErrors)
            if ($parseErrors -and $parseErrors.Count -gt 0) {
                Write-Log "Update rejected: downloaded script has parse errors." "WARN"; return
            }
            $tmp = [System.IO.Path]::GetTempFileName() + ".ps1"
            $new | Out-File -FilePath $tmp -Encoding UTF8
            if ($ScriptPath -eq $ScriptDest) {
                # Running from installed location — replace and restart silently
                Write-Log "Update found — scheduling replacement and restart."
                $cmd = "timeout /t 2 /nobreak >nul & copy /Y `"$tmp`" `"$ScriptDest`" & " +
                       "powershell.exe -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$ScriptDest`""
                Start-Process "cmd.exe" -ArgumentList "/c $cmd" -WindowStyle Hidden
                exit 0
            } else {
                # Running from another location (e.g. Downloads) — update installed copy silently, keep going
                Write-Log "Update found — updating installed copy. Continuing current run."
                Copy-Item -Path $tmp -Destination $ScriptDest -Force -ErrorAction SilentlyContinue
                Remove-Item $tmp -Force -ErrorAction SilentlyContinue
            }
        }
    } catch {
        Write-Log "Update check failed: $_" "WARN"
    }
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
    return $hw
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
        $body = $req | ConvertTo-Json -Compress
        $resp = Invoke-RestMethod -Uri $AppsScriptUrl -Method POST -Body $body `
                    -ContentType "application/json" -TimeoutSec 15
        return ($resp.status -eq "ok")
    } catch {
        Write-Log "HTTP submit failed: $_" "WARN"
        return $false
    }
}

# ── Offline queue ─────────────────────────────────────────────────────────────
function Add-ToQueue($Payload) {
    $items = @()
    if (Test-Path $QueueFile) {
        try { $items = Get-Content $QueueFile -Raw | ConvertFrom-Json }
        catch {}
    }
    $items += $Payload
    $items | ConvertTo-Json -Depth 5 | Set-Content $QueueFile -Encoding UTF8
    Write-Log "Saved to offline queue (total: $($items.Count))"
}

function Flush-Queue {
    if (-not (Test-Path $QueueFile)) { return }
    try {
        $items = @(Get-Content $QueueFile -Raw | ConvertFrom-Json)
    } catch { return }
    if ($items.Count -eq 0) { return }

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
        $pending | ConvertTo-Json -Depth 5 | Set-Content $QueueFile -Encoding UTF8
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
    $form.ClientSize       = New-Object System.Drawing.Size(520, 684)
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

    # Screen size field
    $lblScreen          = New-Object System.Windows.Forms.Label
    $lblScreen.Text     = "Screen Size (in.) *"
    $lblScreen.Location = New-Object System.Drawing.Point(26, ($yPos + 4))
    $lblScreen.Size     = New-Object System.Drawing.Size(120, 22)
    $lblScreen.Font     = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
    $form.Controls.Add($lblScreen)

    $tbScreen           = New-Object System.Windows.Forms.TextBox
    $tbScreen.Location  = New-Object System.Drawing.Point(152, $yPos)
    $tbScreen.Size      = New-Object System.Drawing.Size(342, 28)
    $tbScreen.Font      = New-Object System.Drawing.Font("Segoe UI", 10)
    $form.Controls.Add($tbScreen)
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
    $hwPanel.Size      = New-Object System.Drawing.Size(468, 142)
    $hwPanel.BackColor = [System.Drawing.Color]::FromArgb(229, 234, 242)
    $form.Controls.Add($hwPanel)

    $hwRows = [ordered]@{
        "Device"   = "$($HW.brand) $($HW.model)"
        "Serial"   = $HW.serial_number
        "OS"       = $HW.os
        "CPU"      = $HW.cpu
        "RAM"      = $HW.ram
        "Storage"  = $HW.storage
        "Hostname" = "$($HW.hostname)  /  $($HW.ip_address)"
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
        $hwPanel.Controls.Add($vLbl)

        $ry += 18
    }
    $yPos += 150

    # ── Buttons ───────────────────────────────────────────────────────────────
    $btnSubmit             = New-Object System.Windows.Forms.Button
    $btnSubmit.Text        = "Submit"
    $btnSubmit.Location    = New-Object System.Drawing.Point(330, ($yPos + 8))
    $btnSubmit.Size        = New-Object System.Drawing.Size(90, 32)
    $btnSubmit.Font        = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
    $btnSubmit.BackColor   = [System.Drawing.Color]::FromArgb(232, 48, 58)
    $btnSubmit.ForeColor   = [System.Drawing.Color]::White
    $btnSubmit.FlatStyle   = "Flat"
    $btnSubmit.FlatAppearance.BorderSize = 0
    $form.Controls.Add($btnSubmit)

    $btnCancel             = New-Object System.Windows.Forms.Button
    $btnCancel.Text        = "Cancel"
    $btnCancel.Location    = New-Object System.Drawing.Point(430, ($yPos + 8))
    $btnCancel.Size        = New-Object System.Drawing.Size(76, 32)
    $btnCancel.Font        = New-Object System.Drawing.Font("Segoe UI", 10)
    $btnCancel.BackColor   = [System.Drawing.Color]::FromArgb(229, 231, 235)
    $btnCancel.FlatStyle   = "Flat"
    $btnCancel.FlatAppearance.BorderSize = 0
    $form.Controls.Add($btnCancel)

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
        if (-not $tbScreen.Text.Trim()) {
            [System.Windows.Forms.MessageBox]::Show("Please enter the screen size (inches).", "Missing field") | Out-Null; return
        }
        $result.submitted = $true
        $result.user_data  = @{
            first_name  = $tbFirst.Text.Trim()
            last_name   = $tbLast.Text.Trim()
            email       = $tbEmail.Text.Trim()
            project     = $cbProject.SelectedItem.ToString()
            screen_size = $tbScreen.Text.Trim()
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
    # Copy script to a stable path so the task still works if the original is deleted
    Copy-Item -Path $ScriptPath -Destination $ScriptDest -Force

    # EXE runs directly; PS1 needs the powershell.exe wrapper
    $action = if ($IsExe) {
        New-ScheduledTaskAction -Execute $ScriptDest
    } else {
        New-ScheduledTaskAction -Execute "powershell.exe" `
            -Argument "-ExecutionPolicy Bypass -WindowStyle Hidden -NonInteractive -File `"$ScriptDest`""
    }

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

    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    Register-ScheduledTask -TaskName $TaskName -Action $action `
        -Trigger @($triggerLogon, $triggerHourly) `
        -Settings $settings -Principal $principal `
        -Description "Webiz Inventory Agent — checks in every 6 months" | Out-Null

    Write-Log "Task Scheduler task '$TaskName' registered."
}

# ════════════════════════════════════════════════════════════════════════════════
#  MAIN
# ════════════════════════════════════════════════════════════════════════════════
Write-Log "=== Webiz Inventory Agent started ==="

# Register startup task if not already registered
$task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if (-not $task) {
    Write-Log "First run — registering startup task…"
    Register-StartupTask
}

# Self-update check
Invoke-SelfUpdate
Remove-LegacySecret

# Flush offline queue
Flush-Queue

# Guard: exit if not due
if (-not (Test-ShouldRun)) { exit 0 }

# Collect hardware
Write-Log "Collecting hardware information…"
$hw = Get-Hardware
Write-Log "HW: $($hw | ConvertTo-Json -Compress)"

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
    [void](Submit-ToSheets -Payload $cancelPayload)
    Write-Log "Form cancelled. Will retry in $CancelRetryHours h."
    exit 0
}

# ── Submitted ─────────────────────────────────────────────────────────────────
$ud = $res.user_data
$payload = @{
    type            = "checkin"
    submission_type = "online"
    timestamp     = $hw.timestamp
    first_name    = $ud.first_name
    last_name     = $ud.last_name
    email         = $ud.email
    project       = $ud.project
    screen_size   = $ud.screen_size
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
