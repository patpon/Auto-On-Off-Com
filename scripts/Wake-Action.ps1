<#
.SYNOPSIS
  Runs as SYSTEM from a wake timer: keeps the PC awake for a while so it does not
  drop straight back to sleep (Windows re-sleeps after ~2 minutes of an unattended wake).
#>
param(
    [int]$StayAwakeMinutes = 60
)

$LogFile = Join-Path $env:ProgramData 'AutoOnOff\log.txt'
"{0}  ON woke up by schedule" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') | Add-Content -Path $LogFile -Encoding UTF8

if ($StayAwakeMinutes -le 0) { exit 0 }

Add-Type -TypeDefinition @'
using System.Runtime.InteropServices;
public static class AutoOnOffAwake {
    [DllImport("kernel32.dll")]
    public static extern uint SetThreadExecutionState(uint flags);
}
'@

# ES_CONTINUOUS | ES_SYSTEM_REQUIRED | ES_DISPLAY_REQUIRED - released when this process exits
[AutoOnOffAwake]::SetThreadExecutionState([uint32]2147483651) | Out-Null
Start-Sleep -Seconds ($StayAwakeMinutes * 60)
