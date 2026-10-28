<#
.SYNOPSIS
  Runs as SYSTEM at the scheduled off time: shuts down, hibernates or sleeps the PC
  unless a user pressed "cancel" in the warning dialog.
#>
param(
    [ValidateSet('Shutdown', 'Hibernate', 'Sleep')]
    [string]$Mode = 'Shutdown',
    # A cancel flag newer than this many minutes skips today's power-off
    [int]$GraceMinutes = 15
)

$DataDir  = Join-Path $env:ProgramData 'AutoOnOff'
$FlagFile = Join-Path $DataDir 'flags\cancel.flag'
$LogFile  = Join-Path $DataDir 'log.txt'

function Write-Log([string]$Message) {
    if ((Test-Path $LogFile) -and (Get-Item $LogFile).Length -gt 1MB) { Remove-Item $LogFile -Force }
    "{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message | Add-Content -Path $LogFile -Encoding UTF8
}

if (Test-Path $FlagFile) {
    $flag = Get-Item $FlagFile
    Remove-Item $FlagFile -Force
    if ($flag.LastWriteTime -gt (Get-Date).AddMinutes(-$GraceMinutes)) {
        Write-Log "OFF skipped ($Mode) - cancelled by user"
        exit 0
    }
}

Write-Log "OFF running ($Mode)"

switch ($Mode) {
    'Shutdown'  { shutdown.exe /s /f /t 0 }
    'Hibernate' { shutdown.exe /h }
    'Sleep' {
        # rundll32 powrprof.dll,SetSuspendState hibernates when hibernation is on,
        # so call SetSuspendState directly. disableWakeEvent=false keeps wake timers working.
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class AutoOnOffPower {
    [StructLayout(LayoutKind.Sequential, Pack = 1)]
    struct TokenPrivileges { public int Count; public long Luid; public int Attr; }

    [DllImport("powrprof.dll", SetLastError = true)]
    static extern bool SetSuspendState(bool hibernate, bool forceCritical, bool disableWakeEvent);
    [DllImport("advapi32.dll", SetLastError = true)]
    static extern bool OpenProcessToken(IntPtr process, uint access, out IntPtr token);
    [DllImport("advapi32.dll", SetLastError = true)]
    static extern bool LookupPrivilegeValue(string system, string name, out long luid);
    [DllImport("advapi32.dll", SetLastError = true)]
    static extern bool AdjustTokenPrivileges(IntPtr token, bool disableAll, ref TokenPrivileges state, int length, IntPtr previous, IntPtr returnLength);
    [DllImport("kernel32.dll")]
    static extern IntPtr GetCurrentProcess();
    [DllImport("kernel32.dll")]
    static extern bool CloseHandle(IntPtr handle);

    public static bool Sleep() {
        IntPtr token;
        if (OpenProcessToken(GetCurrentProcess(), 0x28, out token)) {   // ADJUST_PRIVILEGES | QUERY
            var tp = new TokenPrivileges { Count = 1, Attr = 2 };      // SE_PRIVILEGE_ENABLED
            if (LookupPrivilegeValue(null, "SeShutdownPrivilege", out tp.Luid))
                AdjustTokenPrivileges(token, false, ref tp, 0, IntPtr.Zero, IntPtr.Zero);
            CloseHandle(token);
        }
        return SetSuspendState(false, false, false);
    }
}
'@
        if (-not [AutoOnOffPower]::Sleep()) { Write-Log 'OFF sleep failed - falling back to hibernate'; shutdown.exe /h }
    }
}
