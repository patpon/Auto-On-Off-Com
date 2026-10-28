<#
.SYNOPSIS
  Sends a Wake-on-LAN "magic packet" to power on PCs that are fully shut down.
  Run it from a PC/server that is always on, in the same network (LAN).

.EXAMPLE
  .\Send-WakeOnLan.ps1 -MacAddress 'A4-BB-6D-12-34-56'
  .\Send-WakeOnLan.ps1 -MacAddress (Get-Content .\office-pcs.txt)
#>
param(
    [Parameter(Mandatory)][string[]]$MacAddress,
    [string]$Broadcast = '255.255.255.255',
    [int]$Port = 9
)

$udp = New-Object System.Net.Sockets.UdpClient
try {
    $udp.EnableBroadcast = $true
    foreach ($mac in $MacAddress | Where-Object { $_.Trim() }) {
        $hex = $mac.Trim() -replace '[-:. ]', ''
        if ($hex -notmatch '^[0-9A-Fa-f]{12}$') { Write-Warning "MAC ไม่ถูกต้อง: $mac"; continue }
        $macBytes = [byte[]]($hex -split '(..)' -ne '' | ForEach-Object { [Convert]::ToByte($_, 16) })
        # Magic packet = 6 x 0xFF followed by the MAC address 16 times
        $packet = [byte[]](,0xFF * 6) + ($macBytes * 16)
        [void]$udp.Send($packet, $packet.Length, $Broadcast, $Port)
        Write-Output "ส่งสัญญาณเปิดเครื่องไปที่ $mac แล้ว"
    }
} finally {
    $udp.Close()
}
