<#
.SYNOPSIS
  Runs in each signed-in user's session before the power-off. Shows a countdown;
  "cancel" writes a flag that tells Off-Action.ps1 to skip today's power-off.
#>
param(
    [int]$Minutes = 5,
    [ValidateSet('Shutdown', 'Hibernate', 'Sleep')]
    [string]$Mode = 'Shutdown'
)

Add-Type -AssemblyName System.Windows.Forms, System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$FlagFile = Join-Path $env:ProgramData 'AutoOnOff\flags\cancel.flag'
$ActionText = @{
    Shutdown  = 'ปิดเครื่อง'
    Hibernate = 'พักเครื่องแบบปิดไฟ (Hibernate)'
    Sleep     = 'พักเครื่อง (Sleep)'
}[$Mode]
$Deadline = (Get-Date).AddMinutes($Minutes)
$Font = 'Leelawadee UI'

$form = New-Object System.Windows.Forms.Form -Property @{
    Text            = 'แจ้งเตือน: คอมพิวเตอร์จะปิดอัตโนมัติ'
    ClientSize      = New-Object System.Drawing.Size(460, 230)
    StartPosition   = 'CenterScreen'
    FormBorderStyle = 'FixedDialog'
    MaximizeBox     = $false
    MinimizeBox     = $false
    TopMost         = $true
    BackColor       = [System.Drawing.Color]::FromArgb(13, 27, 54)
    ForeColor       = [System.Drawing.Color]::White
    Font            = New-Object System.Drawing.Font($Font, 10)
}

$title = New-Object System.Windows.Forms.Label -Property @{
    Text      = "เครื่องจะ$ActionText ใน"
    Location  = New-Object System.Drawing.Point(20, 18)
    Size      = New-Object System.Drawing.Size(420, 28)
    TextAlign = 'MiddleCenter'
    Font      = New-Object System.Drawing.Font($Font, 12)
}
$countdown = New-Object System.Windows.Forms.Label -Property @{
    Location  = New-Object System.Drawing.Point(20, 48)
    Size      = New-Object System.Drawing.Size(420, 60)
    TextAlign = 'MiddleCenter'
    Font      = New-Object System.Drawing.Font($Font, 32, [System.Drawing.FontStyle]::Bold)
    ForeColor = [System.Drawing.Color]::FromArgb(245, 166, 35)
}
$hint = New-Object System.Windows.Forms.Label -Property @{
    Text      = 'กรุณาบันทึกงานให้เรียบร้อย  ถ้ายังใช้งานอยู่ กด "ยกเลิก"'
    Location  = New-Object System.Drawing.Point(20, 112)
    Size      = New-Object System.Drawing.Size(420, 26)
    TextAlign = 'MiddleCenter'
}
$cancel = New-Object System.Windows.Forms.Button -Property @{
    Text      = 'ยกเลิก — ยังใช้งานอยู่'
    Location  = New-Object System.Drawing.Point(40, 158)
    Size      = New-Object System.Drawing.Size(200, 44)
    BackColor = [System.Drawing.Color]::FromArgb(245, 166, 35)
    ForeColor = [System.Drawing.Color]::FromArgb(13, 27, 54)
    FlatStyle = 'Flat'
    Font      = New-Object System.Drawing.Font($Font, 10, [System.Drawing.FontStyle]::Bold)
}
$ok = New-Object System.Windows.Forms.Button -Property @{
    Text      = 'รับทราบ'
    Location  = New-Object System.Drawing.Point(260, 158)
    Size      = New-Object System.Drawing.Size(160, 44)
    FlatStyle = 'Flat'
}

$cancel.Add_Click({
    try {
        Set-Content -Path $FlagFile -Value (Get-Date -Format o) -Encoding ASCII -ErrorAction Stop
        [System.Windows.Forms.MessageBox]::Show('ยกเลิกการปิดเครื่องครั้งนี้แล้ว', 'Auto On/Off') | Out-Null
    } catch {
        [System.Windows.Forms.MessageBox]::Show("ยกเลิกไม่สำเร็จ: $($_.Exception.Message)", 'Auto On/Off') | Out-Null
    }
    $form.Close()
})
$ok.Add_Click({ $form.Close() })

$timer = New-Object System.Windows.Forms.Timer -Property @{ Interval = 1000 }
$tick = {
    $left = $Deadline - (Get-Date)
    if ($left.TotalSeconds -le 0) { $timer.Stop(); $form.Close(); return }
    $countdown.Text = '{0:00}:{1:00}' -f [math]::Floor($left.TotalMinutes), $left.Seconds
}
$timer.Add_Tick($tick)
& $tick
$timer.Start()

$form.Controls.AddRange(@($title, $countdown, $hint, $cancel, $ok))
$form.Add_Shown({ $form.Activate() })
[void]$form.ShowDialog()
