<#
.SYNOPSIS
  Auto On/Off - schedule automatic power-off (shutdown / hibernate / sleep) and
  wake-up for Windows PCs, using Windows Task Scheduler.

.EXAMPLE
  .\AutoOnOff.ps1                                  # open the settings window
  .\AutoOnOff.ps1 -Apply -ConfigFile .\office.json # apply a config without the window (mass deploy)
  .\AutoOnOff.ps1 -Status                          # print current schedule
  .\AutoOnOff.ps1 -Remove                          # remove all schedules
#>
[CmdletBinding(DefaultParameterSetName = 'Gui')]
param(
    [Parameter(ParameterSetName = 'Apply', Mandatory)][switch]$Apply,
    [Parameter(ParameterSetName = 'Apply')][string]$ConfigFile,
    [Parameter(ParameterSetName = 'Remove', Mandatory)][switch]$Remove,
    [Parameter(ParameterSetName = 'Status', Mandatory)][switch]$Status
)

$ErrorActionPreference = 'Stop'

$AppName    = 'AutoOnOff'
$TaskPath   = '\AutoOnOff\'
$DataDir    = Join-Path $env:ProgramData $AppName
$ConfigPath = Join-Path $DataDir 'config.json'
$LogFile    = Join-Path $DataDir 'log.txt'
$SourceDir  = Join-Path $PSScriptRoot 'scripts'
$PowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$AllDays    = [string[]]('Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday')
$ThaiDays   = [string[]]('จ', 'อ', 'พ', 'พฤ', 'ศ', 'ส', 'อา')
$Modes      = [string[]]('Shutdown', 'Hibernate', 'Sleep')
$TaskLabels = @{ 'Off-Warning' = 'แจ้งเตือนก่อนปิด'; 'Off-Action' = 'ปิดเครื่อง'; 'Wake' = 'เปิดเครื่อง (ปลุก)' }
$ThaiCulture = [Globalization.CultureInfo]'th-TH'   # Buddhist calendar -> พ.ศ.

#region Core

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal $id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-Native([string]$Exe, [string[]]$Arguments) {
    # Native stderr would throw under ErrorActionPreference=Stop in Windows PowerShell 5.1
    $ErrorActionPreference = 'Continue'
    & $Exe @Arguments 2>&1 | Out-String
}

function Get-DefaultConfig {
    [pscustomobject]@{
        Off = [pscustomobject]@{ Enabled = $true;  Time = '18:00'; Days = $AllDays[0..4]; Mode = 'Hibernate'; WarnMinutes = 5 }
        On  = [pscustomobject]@{ Enabled = $true;  Time = '07:30'; Days = $AllDays[0..4]; StayAwakeMinutes = 60 }
    }
}

function Read-Config([string]$Path = $ConfigPath) {
    if (-not (Test-Path $Path)) { return Get-DefaultConfig }
    $cfg = Get-Content -Path $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    # A one-element JSON array comes back as a scalar
    $cfg.Off.Days = @($cfg.Off.Days)
    $cfg.On.Days  = @($cfg.On.Days)
    $cfg
}

function Test-Config($Config) {
    $errors = @()
    foreach ($part in 'Off', 'On') {
        $p = $Config.$part
        if (-not $p.Enabled) { continue }
        if ($p.Time -notmatch '^([01]\d|2[0-3]):[0-5]\d$') { $errors += "$part.Time ต้องเป็นรูปแบบ HH:mm" }
        if (-not $p.Days) { $errors += "$part ต้องเลือกอย่างน้อย 1 วัน" }
        foreach ($d in $p.Days) { if ($AllDays -notcontains $d) { $errors += "$part.Days มีค่าไม่ถูกต้อง: $d" } }
    }
    if ($Config.Off.Enabled) {
        if ($Modes -notcontains $Config.Off.Mode) { $errors += "Off.Mode ต้องเป็น $($Modes -join '/')" }
        if ($Config.Off.WarnMinutes -lt 0 -or $Config.Off.WarnMinutes -gt 60) { $errors += 'Off.WarnMinutes ต้องอยู่ระหว่าง 0-60' }
    }
    if ($Config.On.Enabled -and ($Config.On.StayAwakeMinutes -lt 0 -or $Config.On.StayAwakeMinutes -gt 720)) {
        $errors += 'On.StayAwakeMinutes ต้องอยู่ระหว่าง 0-720'
    }
    $errors
}

function Get-ShiftedSchedule([string]$Time, [string[]]$Days, [int]$Minutes) {
    # Move a weekly schedule forward by N minutes; days roll over when crossing midnight
    $base  = [datetime]::ParseExact($Time, 'HH:mm', $null)
    $moved = $base.AddMinutes($Minutes)
    $shift = ($moved.Date - $base.Date).Days
    [pscustomobject]@{
        At   = $moved.ToString('HH:mm')
        Days = [string[]]($Days | ForEach-Object { $AllDays[([array]::IndexOf($AllDays, $_) + $shift) % 7] })
    }
}

function Initialize-DataDir {
    New-Item -ItemType Directory -Force -Path $DataDir | Out-Null
    # Scripts here run as SYSTEM: only admins/SYSTEM may change them, users may only read
    Invoke-Native icacls.exe @($DataDir, '/inheritance:r', '/grant:r',
        '*S-1-5-32-544:(OI)(CI)F', '*S-1-5-18:(OI)(CI)F', '*S-1-5-32-545:(OI)(CI)RX') | Out-Null
    Copy-Item -Path (Join-Path $SourceDir '*.ps1') -Destination $DataDir -Force
    # Users may write the cancel flag from the warning dialog
    $flagDir = Join-Path $DataDir 'flags'
    New-Item -ItemType Directory -Force -Path $flagDir | Out-Null
    Invoke-Native icacls.exe @($flagDir, '/grant', '*S-1-5-32-545:(OI)(CI)M') | Out-Null
}

function Enable-WakeTimers {
    # Power plan "Allow wake timers" = Enable (AC + battery). The setting only exists once
    # hibernation is on for some Modern Standby PCs, so failures are reported via Test-WakeTimers.
    Invoke-Native powercfg.exe @('/setacvalueindex', 'SCHEME_CURRENT', 'SUB_SLEEP', 'RTCWAKE', '1') | Out-Null
    Invoke-Native powercfg.exe @('/setdcvalueindex', 'SCHEME_CURRENT', 'SUB_SLEEP', 'RTCWAKE', '1') | Out-Null
    Invoke-Native powercfg.exe @('/setactive', 'SCHEME_CURRENT') | Out-Null
}

function Test-WakeTimers {
    # Output is localized, but the current AC/DC values are the only 0x........ numbers
    $values = [regex]::Matches((Invoke-Native powercfg.exe @('/q', 'SCHEME_CURRENT', 'SUB_SLEEP', 'RTCWAKE')), '0x[0-9a-fA-F]{8}')
    $values.Count -ge 2 -and [Convert]::ToInt32($values[$values.Count - 2].Value, 16) -eq 1
}

function Remove-Schedule {
    Get-ScheduledTask -TaskPath $TaskPath -ErrorAction SilentlyContinue |
        Unregister-ScheduledTask -Confirm:$false
}

function Install-Schedule($Config) {
    $errors = Test-Config $Config
    if ($errors) { throw ($errors -join "`n") }

    Remove-Schedule
    Initialize-DataDir
    $Config | ConvertTo-Json -Depth 5 | Set-Content -Path $ConfigPath -Encoding UTF8

    $hidden = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File'
    $system = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest

    if ($Config.Off.Enabled) {
        $off  = $Config.Off
        $warn = [int]$off.WarnMinutes

        if ($warn -gt 0) {
            # Runs in every signed-in user's session so they can see the countdown
            $users = ([Security.Principal.SecurityIdentifier]'S-1-5-32-545').Translate([Security.Principal.NTAccount]).Value
            Register-ScheduledTask -TaskPath $TaskPath -TaskName 'Off-Warning' -Description 'Auto On/Off: countdown before power-off' `
                -Action (New-ScheduledTaskAction -Execute $PowerShell -Argument "$hidden `"$DataDir\Off-Warning.ps1`" -Minutes $warn -Mode $($off.Mode)") `
                -Trigger (New-ScheduledTaskTrigger -Weekly -DaysOfWeek $off.Days -At $off.Time) `
                -Principal (New-ScheduledTaskPrincipal -GroupId $users -RunLevel Limited) `
                -Settings (New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                    -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes ($warn + 5))) | Out-Null
        }

        # No StartWhenAvailable: a missed power-off must never fire later at boot
        $at = Get-ShiftedSchedule $off.Time $off.Days $warn
        Register-ScheduledTask -TaskPath $TaskPath -TaskName 'Off-Action' -Description 'Auto On/Off: power off' `
            -Action (New-ScheduledTaskAction -Execute $PowerShell -Argument "$hidden `"$DataDir\Off-Action.ps1`" -Mode $($off.Mode) -GraceMinutes $($warn + 10)") `
            -Trigger (New-ScheduledTaskTrigger -Weekly -DaysOfWeek $at.Days -At $at.At) `
            -Principal $system `
            -Settings (New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 10)) | Out-Null

        if ($off.Mode -eq 'Hibernate') { Invoke-Native powercfg.exe @('/hibernate', 'on') | Out-Null }
    }

    if ($Config.On.Enabled) {
        $on = $Config.On
        Register-ScheduledTask -TaskPath $TaskPath -TaskName 'Wake' -Description 'Auto On/Off: wake the PC' `
            -Action (New-ScheduledTaskAction -Execute $PowerShell -Argument "$hidden `"$DataDir\Wake-Action.ps1`" -StayAwakeMinutes $($on.StayAwakeMinutes)") `
            -Trigger (New-ScheduledTaskTrigger -Weekly -DaysOfWeek $on.Days -At $on.Time) `
            -Principal $system `
            -Settings (New-ScheduledTaskSettingsSet -WakeToRun -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
                -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes ([int]$on.StayAwakeMinutes + 5))) | Out-Null
        Enable-WakeTimers
    }
}

function Format-ThaiDate([datetime]$Date) {
    $Date.ToString('ddd d MMM yyyy  HH:mm น.', $ThaiCulture)
}

function Get-ScheduleStatus {
    $lines = @()
    $tasks = @(Get-ScheduledTask -TaskPath $TaskPath -ErrorAction SilentlyContinue)
    if (-not $tasks) {
        $lines += 'ยังไม่ได้ตั้งเวลา'
    } else {
        foreach ($t in $tasks) {
            $info = $t | Get-ScheduledTaskInfo
            $next = if ($info.NextRunTime) { Format-ThaiDate $info.NextRunTime } else { '-' }
            $lines += '• {0}  ครั้งถัดไป: {1}' -f $TaskLabels[$t.TaskName], $next
        }
    }
    # Tasks running as SYSTEM are hidden from non-elevated sessions
    if (-not (Test-Admin)) { $lines += '(บางรายการซ่อนอยู่ — เปิดด้วยสิทธิ์ Administrator เพื่อดูครบ)' }
    if ((Test-Path $ConfigPath) -and (Read-Config).On.Enabled -and -not (Test-WakeTimers)) {
        $lines += '⚠ "Allow wake timers" ของ Power Options ยังปิดอยู่ — เครื่องจะไม่ตื่นเอง กดบันทึกอีกครั้ง'
    }
    if (Test-Path $LogFile) {
        $lines += ''
        $lines += 'ประวัติล่าสุด:'
        $lines += Get-Content -Path $LogFile -Tail 5 -Encoding UTF8
    }
    $lines -join "`r`n"
}

#endregion

#region Window
# WinForms event handlers run in script scope (they are not closures), so every control
# a handler touches lives in $script:ui and the helpers are script-level functions.

function New-Control([string]$Type, [hashtable]$Props) {
    $c = New-Object "System.Windows.Forms.$Type"
    # Set Value last so Minimum/Maximum are already in place
    foreach ($k in ($Props.Keys | Sort-Object { $_ -eq 'Value' })) { $c.$k = $Props[$k] }
    $c
}
function New-Point($x, $y) { New-Object System.Drawing.Point($x, $y) }
function New-Size($w, $h) { New-Object System.Drawing.Size($w, $h) }
function New-UiFont([float]$Size, [System.Drawing.FontStyle]$Style = 'Regular') {
    New-Object System.Drawing.Font('Leelawadee UI', $Size, $Style)
}
function New-Label([string]$Text, $x, $y, $w = 110) {
    New-Control Label @{ Text = $Text; Location = (New-Point $x $y); Size = (New-Size $w 24) }
}
function New-TimePicker($y, [string]$Time) {
    New-Control DateTimePicker @{
        Format = 'Custom'; CustomFormat = 'HH:mm'; ShowUpDown = $true
        Location = (New-Point 130 $y); Size = (New-Size 90 28)
        Value = [datetime]::ParseExact($Time, 'HH:mm', $null)
    }
}
function New-DayBoxes($Parent, $y, [string[]]$Selected) {
    $boxes = @{}
    for ($i = 0; $i -lt 7; $i++) {
        $cb = New-Control CheckBox @{
            Text = $ThaiDays[$i]; Location = (New-Point (130 + $i * 52) $y); Size = (New-Size 50 26)
            Checked = ($Selected -contains $AllDays[$i])
        }
        $Parent.Controls.Add($cb)
        $boxes[$AllDays[$i]] = $cb
    }
    $boxes
}
function Get-CheckedDays($Boxes) { [string[]]($AllDays | Where-Object { $Boxes[$_].Checked }) }

function Update-FormState {
    foreach ($c in $ui.GroupOff.Controls) { if ($c -ne $ui.OffEnabled) { $c.Enabled = $ui.OffEnabled.Checked } }
    foreach ($c in $ui.GroupOn.Controls)  { if ($c -ne $ui.OnEnabled)  { $c.Enabled = $ui.OnEnabled.Checked } }
    $ui.OnHint.Text = if ($ui.OffEnabled.Checked -and $ui.OffMode.SelectedIndex -eq 0) {
        'หมายเหตุ: เครื่องที่ "ปิดสนิท" Windows ปลุกเองไม่ได้ — ต้องเปิด "Power On by RTC" ใน BIOS หรือเปลี่ยนวิธีปิดเป็น Hibernate'
    } else { '' }
}
function Update-StatusBox { $ui.Status.Text = Get-ScheduleStatus }

function Save-FromForm {
    $new = [pscustomobject]@{
        Off = [pscustomobject]@{
            Enabled = $ui.OffEnabled.Checked; Time = $ui.OffTime.Value.ToString('HH:mm'); Days = Get-CheckedDays $ui.OffDays
            Mode = $Modes[$ui.OffMode.SelectedIndex]; WarnMinutes = [int]$ui.OffWarn.Value
        }
        On = [pscustomobject]@{
            Enabled = $ui.OnEnabled.Checked; Time = $ui.OnTime.Value.ToString('HH:mm'); Days = Get-CheckedDays $ui.OnDays
            StayAwakeMinutes = [int]$ui.OnStay.Value
        }
    }
    try {
        $ui.Form.Cursor = 'WaitCursor'
        Install-Schedule $new
        Update-StatusBox
        [System.Windows.Forms.MessageBox]::Show('บันทึกเรียบร้อย ระบบจะทำงานตามเวลาที่ตั้งไว้', 'Auto On/Off', 'OK', 'Information') | Out-Null
    } catch {
        [System.Windows.Forms.MessageBox]::Show("บันทึกไม่สำเร็จ:`n$($_.Exception.Message)", 'Auto On/Off', 'OK', 'Error') | Out-Null
    } finally { $ui.Form.Cursor = 'Default' }
}

function Remove-FromForm {
    $answer = [System.Windows.Forms.MessageBox]::Show('ยกเลิกการตั้งเวลาเปิด-ปิดทั้งหมด?', 'Auto On/Off', 'YesNo', 'Question')
    if ($answer -ne 'Yes') { return }
    try { Remove-Schedule; Update-StatusBox }
    catch { [System.Windows.Forms.MessageBox]::Show("ไม่สำเร็จ:`n$($_.Exception.Message)", 'Auto On/Off', 'OK', 'Error') | Out-Null }
}

function New-MainForm {
    Add-Type -AssemblyName System.Windows.Forms, System.Drawing
    [System.Windows.Forms.Application]::EnableVisualStyles()

    $navy = [System.Drawing.Color]::FromArgb(13, 27, 54)
    $gold = [System.Drawing.Color]::FromArgb(245, 166, 35)
    $cfg  = Read-Config
    $script:ui = @{}

    $ui.Form = New-Control Form @{
        Text = 'Auto On/Off — ตั้งเวลาเปิด-ปิดคอมพิวเตอร์  |  By Aj พชรพล'
        ClientSize = (New-Size 560 660); StartPosition = 'CenterScreen'
        FormBorderStyle = 'FixedSingle'; MaximizeBox = $false
        Font = (New-UiFont 10); BackColor = [System.Drawing.Color]::White
    }

    $header = New-Control Panel @{ Location = (New-Point 0 0); Size = (New-Size 560 64); BackColor = $navy }
    $header.Controls.Add((New-Control Label @{
        Text = '⏻  ตั้งเวลาเปิด-ปิดคอมพิวเตอร์อัตโนมัติ'; ForeColor = $gold
        Location = (New-Point 20 8); Size = (New-Size 520 32); Font = (New-UiFont 14 'Bold')
    }))
    $header.Controls.Add((New-Control Label @{
        Text = 'ใช้ Task Scheduler ของ Windows — ทำงานเองแม้ไม่ได้เปิดโปรแกรมนี้'
        ForeColor = [System.Drawing.Color]::White; Location = (New-Point 22 40); Size = (New-Size 400 20); Font = (New-UiFont 9)
    }))
    $header.Controls.Add((New-Control Label @{
        Text = 'By Aj พชรพล'; ForeColor = $gold; TextAlign = 'MiddleRight'
        Location = (New-Point 400 40); Size = (New-Size 144 20); Font = (New-UiFont 9 'Italic')
    }))

    # --- Power-off group
    $ui.GroupOff   = New-Control GroupBox @{ Text = 'ปิดเครื่องอัตโนมัติ'; Location = (New-Point 16 76); Size = (New-Size 528 196) }
    $ui.OffEnabled = New-Control CheckBox @{ Text = 'เปิดใช้งาน'; Location = (New-Point 16 26); Size = (New-Size 200 26); Checked = [bool]$cfg.Off.Enabled }
    $ui.OffTime    = New-TimePicker 58 $cfg.Off.Time
    $ui.OffDays    = New-DayBoxes $ui.GroupOff 92 $cfg.Off.Days
    $ui.OffMode    = New-Control ComboBox @{ DropDownStyle = 'DropDownList'; Location = (New-Point 130 124); Size = (New-Size 380 28) }
    [void]$ui.OffMode.Items.AddRange(@(
        'ปิดเครื่อง (Shutdown) — ปิดสนิท',
        'พักเครื่องแบบปิดไฟ (Hibernate) — แนะนำ, ปลุกตามเวลาได้',
        'พักเครื่อง (Sleep) — ยังกินไฟเล็กน้อย'))
    $ui.OffMode.SelectedIndex = [math]::Max(0, [array]::IndexOf($Modes, [string]$cfg.Off.Mode))
    $ui.OffWarn = New-Control NumericUpDown @{ Minimum = 0; Maximum = 60; Value = [int]$cfg.Off.WarnMinutes; Location = (New-Point 130 158); Size = (New-Size 70 28) }
    $ui.GroupOff.Controls.AddRange(@(
        $ui.OffEnabled,
        (New-Label 'เวลา' 16 60), $ui.OffTime,
        (New-Label 'วัน' 16 94),
        (New-Label 'วิธีปิด' 16 126), $ui.OffMode,
        (New-Label 'เตือนก่อน' 16 160), $ui.OffWarn,
        (New-Label 'นาที (0 = ไม่เตือน, ผู้ใช้กดยกเลิกได้)' 206 160 300)))

    # --- Wake group
    $ui.GroupOn   = New-Control GroupBox @{ Text = 'เปิดเครื่องอัตโนมัติ'; Location = (New-Point 16 282); Size = (New-Size 528 196) }
    $ui.OnEnabled = New-Control CheckBox @{ Text = 'เปิดใช้งาน'; Location = (New-Point 16 26); Size = (New-Size 200 26); Checked = [bool]$cfg.On.Enabled }
    $ui.OnTime    = New-TimePicker 58 $cfg.On.Time
    $ui.OnDays    = New-DayBoxes $ui.GroupOn 92 $cfg.On.Days
    $ui.OnStay    = New-Control NumericUpDown @{ Minimum = 0; Maximum = 720; Value = [int]$cfg.On.StayAwakeMinutes; Location = (New-Point 130 124); Size = (New-Size 70 28) }
    $ui.OnHint    = New-Control Label @{ Location = (New-Point 16 154); Size = (New-Size 500 38); ForeColor = [System.Drawing.Color]::FromArgb(180, 90, 0); Font = (New-UiFont 9) }
    $ui.GroupOn.Controls.AddRange(@(
        $ui.OnEnabled,
        (New-Label 'เวลา' 16 60), $ui.OnTime,
        (New-Label 'วัน' 16 94),
        (New-Label 'ตื่นค้างไว้' 16 126), $ui.OnStay,
        (New-Label 'นาที (กันเครื่องกลับไปหลับเอง)' 206 126 300),
        $ui.OnHint))

    $ui.Status = New-Control TextBox @{
        Multiline = $true; ReadOnly = $true; ScrollBars = 'Vertical'
        Location = (New-Point 16 488); Size = (New-Size 528 104)
        BackColor = [System.Drawing.Color]::FromArgb(245, 247, 250); Font = (New-UiFont 9)
    }

    $btnSave = New-Control Button @{
        Text = 'บันทึกและเปิดใช้งาน'; Location = (New-Point 16 604); Size = (New-Size 200 42)
        BackColor = $gold; ForeColor = $navy; FlatStyle = 'Flat'; Font = (New-UiFont 10 'Bold')
    }
    $btnRemove  = New-Control Button @{ Text = 'ยกเลิกทั้งหมด'; Location = (New-Point 226 604); Size = (New-Size 150 42); FlatStyle = 'Flat' }
    $btnRefresh = New-Control Button @{ Text = 'รีเฟรชสถานะ'; Location = (New-Point 386 604); Size = (New-Size 158 42); FlatStyle = 'Flat' }

    $ui.OffEnabled.Add_CheckedChanged({ Update-FormState })
    $ui.OnEnabled.Add_CheckedChanged({ Update-FormState })
    $ui.OffMode.Add_SelectedIndexChanged({ Update-FormState })
    $btnSave.Add_Click({ Save-FromForm })
    $btnRemove.Add_Click({ Remove-FromForm })
    $btnRefresh.Add_Click({ Update-StatusBox })

    $ui.Form.Controls.AddRange(@($header, $ui.GroupOff, $ui.GroupOn, $ui.Status, $btnSave, $btnRemove, $btnRefresh))
    Update-FormState
    Update-StatusBox
    $ui.Form
}

#endregion

# Allow dot-sourcing for tests without running anything
if ($MyInvocation.InvocationName -eq '.') { return }

switch ($PSCmdlet.ParameterSetName) {
    'Gui' {
        if (-not (Test-Admin)) {
            Start-Process -FilePath $PowerShell -Verb RunAs -ArgumentList @(
                '-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-WindowStyle', 'Hidden', '-File', "`"$PSCommandPath`"")
            return
        }
        [void](New-MainForm).ShowDialog()
    }
    'Apply' {
        if (-not (Test-Admin)) { throw 'ต้องรันด้วยสิทธิ์ Administrator' }
        Install-Schedule (Read-Config $(if ($ConfigFile) { $ConfigFile } else { $ConfigPath }))
        Get-ScheduleStatus
    }
    'Remove' {
        if (-not (Test-Admin)) { throw 'ต้องรันด้วยสิทธิ์ Administrator' }
        Remove-Schedule
        'ยกเลิกการตั้งเวลาทั้งหมดแล้ว'
    }
    'Status' { Get-ScheduleStatus }
}
