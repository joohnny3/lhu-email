[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$TaskName = "LHU Weekly Email",
    [DayOfWeek]$DayOfWeek = [DayOfWeek]::Saturday,
    [datetime]$At = "09:00",
    [switch]$ShutdownWsl
)

$ErrorActionPreference = "Stop"

$Runner = Join-Path $PSScriptRoot "run-lhu-weekly-email.ps1"
if (-not (Test-Path -LiteralPath $Runner)) {
    throw "Runner script was not found: $Runner"
}

$PowerShell = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"
$Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$Runner`" -OnlyIfDue"
if ($ShutdownWsl) {
    $Arguments += " -ShutdownWsl"
}

$CurrentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
$Action = New-ScheduledTaskAction -Execute $PowerShell -Argument $Arguments -WorkingDirectory (Split-Path -Parent $PSScriptRoot)
$WeeklyTrigger = New-ScheduledTaskTrigger -Weekly -WeeksInterval 1 -DaysOfWeek $DayOfWeek -At $At
$LogonTrigger = New-ScheduledTaskTrigger -AtLogOn -User $CurrentUser
$LogonTrigger.Delay = "PT1M"
$Settings = New-ScheduledTaskSettingsSet `
    -StartWhenAvailable `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 15) `
    -MultipleInstances IgnoreNew `
    -RestartCount 3 `
    -RestartInterval (New-TimeSpan -Minutes 5)
$Principal = New-ScheduledTaskPrincipal -UserId $CurrentUser -LogonType Interactive -RunLevel Limited

if ($PSCmdlet.ShouldProcess($TaskName, "Register scheduled task for $CurrentUser")) {
    Register-ScheduledTask `
        -TaskName $TaskName `
        -Action $Action `
        -Trigger @($WeeklyTrigger, $LogonTrigger) `
        -Settings $Settings `
        -Principal $Principal `
        -Description "Starts Docker Desktop when needed and sends the weekly LHU email. Missed runs are caught up at the next user logon." `
        -Force | Out-Null

    Write-Host "Scheduled task '$TaskName' installed for $CurrentUser."
    Write-Host "Weekly trigger: $DayOfWeek $($At.ToString('HH:mm'))"
    Write-Host "Catch-up trigger: 60 seconds after user logon"
}
