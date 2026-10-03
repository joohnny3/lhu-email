[CmdletBinding()]
param(
    [switch]$OnlyIfDue,
    [switch]$ShutdownWsl,
    [switch]$TestNotification,
    [int]$DockerReadyTimeoutSeconds = 300,
    [int]$NetworkReadyTimeoutSeconds = 30
)

$ErrorActionPreference = "Stop"

$Root = Split-Path -Parent $PSScriptRoot
$LogDir = Join-Path $Root "logs\lhu-weekly-email"
$TaskLog = Join-Path $LogDir "task-scheduler.log"
$StateFile = Join-Path $Root "state\task-scheduler.json"
$LockFile = Join-Path $Root "state\task-scheduler.lock"
$ResultFile = Join-Path $Root "state\lhu-weekly-email-result.json"
$SecretsFile = Join-Path $Root "secrets\lhu-weekly-email.env"
# User-facing text lives in a UTF-8 JSON file so this script can stay ASCII:
# Windows PowerShell 5.1 reads a BOM-less .ps1 in the ANSI code page.
$MessagesFile = Join-Path $PSScriptRoot "failure-messages.json"
$DockerDesktopCandidates = @(
    (Join-Path $env:ProgramFiles "Docker\Docker\Docker Desktop.exe"),
    (Join-Path $env:LOCALAPPDATA "Docker\Docker Desktop.exe")
)

New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $StateFile) | Out-Null

function Write-TaskLog {
    param([string]$Message)
    $time = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Add-Content -LiteralPath $TaskLog -Value "[$time] $Message"
}

function Get-LatestScheduledSlot {
    param([datetime]$Now = (Get-Date))

    $daysSinceSaturday = (([int]$Now.DayOfWeek - [int][DayOfWeek]::Saturday) + 7) % 7
    $slot = $Now.Date.AddDays(-$daysSinceSaturday).AddHours(9)
    if ($slot -gt $Now) {
        $slot = $slot.AddDays(-7)
    }
    return $slot
}

function Test-RunIsDue {
    $slot = Get-LatestScheduledSlot
    if (-not (Test-Path -LiteralPath $StateFile)) {
        return $true
    }

    try {
        $state = Get-Content -Raw -LiteralPath $StateFile | ConvertFrom-Json
        if (-not $state.lastSuccessAt) {
            return $true
        }
        return ([datetimeoffset]::Parse($state.lastSuccessAt).LocalDateTime -lt $slot)
    }
    catch {
        Write-TaskLog "State is unreadable; treating the job as due: $($_.Exception.Message)"
        return $true
    }
}

function Save-SuccessState {
    $now = [datetimeoffset]::Now
    $state = [ordered]@{
        job = "lhu-weekly-email"
        lastSuccessAt = $now.ToString("o")
        latestScheduledSlot = (Get-LatestScheduledSlot).ToString("o")
        status = "success"
    }
    $temporary = "$StateFile.tmp"
    $state | ConvertTo-Json | Set-Content -LiteralPath $temporary -Encoding UTF8
    Move-Item -Force -LiteralPath $temporary -Destination $StateFile
}

function Test-DockerEngine {
    # docker.exe writes connection errors to stderr when the engine is down.
    # Under $ErrorActionPreference = "Stop" that surfaces as a terminating
    # NativeCommandError, so isolate the preference and rely only on the exit
    # code. This must never throw, otherwise Start-DockerEngine can't run.
    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        & docker info --format '{{.ServerVersion}}' > $null 2>&1
        return ($LASTEXITCODE -eq 0)
    }
    catch {
        return $false
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
}

function Start-DockerEngine {
    if (Test-DockerEngine) {
        Write-TaskLog "Docker Engine is already ready"
        return
    }

    $dockerDesktop = $DockerDesktopCandidates |
        Where-Object { $_ -and (Test-Path -LiteralPath $_) } |
        Select-Object -First 1
    if (-not $dockerDesktop) {
        throw "Docker Desktop.exe was not found"
    }

    Write-TaskLog "Starting Docker Desktop"
    Start-Process -FilePath $dockerDesktop -WindowStyle Hidden | Out-Null

    $deadline = (Get-Date).AddSeconds($DockerReadyTimeoutSeconds)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 3
        if (Test-DockerEngine) {
            Write-TaskLog "Docker Engine is ready"
            return
        }
    }
    throw "Docker Engine did not become ready within $DockerReadyTimeoutSeconds seconds"
}

function Get-SecretValue {
    param([string]$Name)
    if (-not (Test-Path -LiteralPath $SecretsFile)) {
        return $null
    }
    foreach ($line in Get-Content -LiteralPath $SecretsFile -Encoding UTF8) {
        if ($line -match "^\s*$([regex]::Escape($Name))\s*=(.*)$") {
            return $Matches[1].Trim().Trim('"').Trim("'")
        }
    }
    return $null
}

function Test-HostReachable {
    param([string]$HostName, [int]$Port = 443)
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        return ($client.ConnectAsync($HostName, $Port).Wait(5000) -and $client.Connected)
    }
    catch {
        return $false
    }
    finally {
        $client.Close()
    }
}

function Wait-Network {
    param([string]$HostName)
    # Right after resume Windows needs a few seconds to rejoin Wi-Fi, so allow a
    # short grace period. Past that the network is really down: report it instead
    # of waiting any longer.
    $deadline = (Get-Date).AddSeconds($NetworkReadyTimeoutSeconds)
    while ($true) {
        if (Test-HostReachable $HostName) {
            return $true
        }
        if ((Get-Date) -ge $deadline) {
            return $false
        }
        Start-Sleep -Seconds 3
    }
}

function Get-NetworkFailureCategory {
    $linkUp = Get-NetAdapter -Physical -ErrorAction SilentlyContinue |
        Where-Object { $_.Status -eq "Up" }
    if (-not $linkUp) {
        return "network-no-link"
    }
    if (-not (Test-HostReachable "www.msftconnecttest.com" 80)) {
        return "network-no-internet"
    }
    return "network-host-down"
}

function Read-JobResult {
    try {
        return Get-Content -Raw -Encoding UTF8 -LiteralPath $ResultFile | ConvertFrom-Json
    }
    catch {
        return $null
    }
}

function Send-DiscordMessage {
    param([string]$Text)
    $webhook = Get-SecretValue "DISCORD_WEBHOOK_URL"
    if (-not $webhook) {
        return $false
    }

    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        # Send bytes: Windows PowerShell 5.1 encodes a string body as Latin-1,
        # which would garble the non-ASCII text.
        $body = [Text.Encoding]::UTF8.GetBytes((@{ content = $Text } | ConvertTo-Json -Compress))
        Invoke-RestMethod -Method Post -Uri $webhook -ContentType "application/json; charset=utf-8" -Body $body -TimeoutSec 15 | Out-Null
        return $true
    }
    catch {
        Write-TaskLog "Discord notification failed: $($_.Exception.Message)"
        return $false
    }
}

function Show-Toast {
    param([string]$Title, [string]$Text)
    [void][Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
    [void][Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime]

    # scenario="reminder" keeps the toast on screen until it is dismissed.
    $template = '<toast scenario="reminder"><visual><binding template="ToastGeneric"><text>{0}</text><text>{1}</text></binding></visual><actions><action activationType="system" arguments="dismiss" content="" /></actions></toast>'
    $xml = New-Object Windows.Data.Xml.Dom.XmlDocument
    $xml.LoadXml(($template -f [Security.SecurityElement]::Escape($Title), [Security.SecurityElement]::Escape($Text)))

    # A toast needs a registered app identity; borrow Windows PowerShell's own.
    $appId = "{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe"
    $toast = New-Object Windows.UI.Notifications.ToastNotification $xml
    [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($appId).Show($toast)
}

function Send-FailureNotice {
    param([string]$Category, [string]$Detail, [string]$Screenshot)
    # Reporting a failure must never raise a new one.
    try {
        $messages = Get-Content -Raw -Encoding UTF8 -LiteralPath $MessagesFile | ConvertFrom-Json
        $reason = $messages.$Category
        if (-not $reason) {
            $reason = $messages.unknown
        }

        $lines = @("**$($messages.title)** ($(Get-Date -Format 'yyyy-MM-dd HH:mm'))", $reason)
        if ($Detail) {
            $firstLine = ($Detail -split "`n")[0].Trim()
            if ($firstLine.Length -gt 300) {
                $firstLine = $firstLine.Substring(0, 300)
            }
            $lines += '`' + $firstLine.Replace('`', "'") + '`'
        }
        if ($Screenshot) {
            $lines += $Screenshot
        }

        if (Send-DiscordMessage ($lines -join "`n")) {
            Write-TaskLog "Failure notice sent to Discord ($Category)"
        }
        else {
            # No webhook configured, or Discord is unreachable (for example when
            # the PC is offline), so tell the user locally instead.
            Show-Toast $messages.title $reason
            Write-TaskLog "Failure notice shown as a Windows notification ($Category)"
        }
    }
    catch {
        Write-TaskLog "Failure notice could not be delivered: $($_.Exception.Message)"
    }
}

if ($TestNotification) {
    Send-FailureNotice -Category "test"
    exit 0
}

$lock = $null
$exitCode = 1
$failureCategory = "unknown"
$failureDetail = $null
$failureScreenshot = $null

try {
    try {
        $lock = [System.IO.File]::Open(
            $LockFile,
            [System.IO.FileMode]::OpenOrCreate,
            [System.IO.FileAccess]::ReadWrite,
            [System.IO.FileShare]::None
        )
    }
    catch [System.IO.IOException] {
        Write-TaskLog "Another lhu-weekly-email process is already running; skipping"
        exit 0
    }

    if ($OnlyIfDue -and -not (Test-RunIsDue)) {
        Write-TaskLog "Current weekly slot has already completed; skipping"
        exit 0
    }

    Set-Location $Root

    $lhuUrl = Get-SecretValue "LHU_URL"
    if (-not $lhuUrl) {
        throw "LHU_URL was not found in $SecretsFile"
    }
    $lhuHost = ([uri]$lhuUrl).Host
    if (-not (Wait-Network $lhuHost)) {
        $failureCategory = Get-NetworkFailureCategory
        throw "Could not reach $lhuHost within $NetworkReadyTimeoutSeconds seconds ($failureCategory)"
    }

    $failureCategory = "docker"
    Get-Command docker -ErrorAction Stop | Out-Null
    Start-DockerEngine
    $failureCategory = "unknown"

    Write-TaskLog "Starting lhu-weekly-email job"
    Remove-Item -LiteralPath $ResultFile -Force -ErrorAction SilentlyContinue
    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    & docker compose run --rm lhu-weekly-email 2>&1 |
        Tee-Object -FilePath $TaskLog -Append
    $jobExitCode = $LASTEXITCODE
    $ErrorActionPreference = $previousErrorActionPreference
    if ($jobExitCode -ne 0) {
        $result = Read-JobResult
        if ($result -and $result.category) {
            $failureCategory = $result.category
            $failureDetail = $result.error
            $failureScreenshot = $result.screenshot
        }
        throw "Docker job failed with exit code $jobExitCode"
    }

    Save-SuccessState
    $exitCode = 0
    Write-TaskLog "Job finished successfully"
}
catch {
    Write-TaskLog "Job failed: $($_.Exception.Message)"
    if (-not $failureDetail) {
        $failureDetail = $_.Exception.Message
    }
    Send-FailureNotice -Category $failureCategory -Detail $failureDetail -Screenshot $failureScreenshot
    $exitCode = 1
}
finally {
    try {
        Set-Location $Root
        Write-TaskLog "Running docker compose down"
        $previousErrorActionPreference = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        & docker compose down --remove-orphans 2>&1 |
            Tee-Object -FilePath $TaskLog -Append
        $downExitCode = $LASTEXITCODE
        $ErrorActionPreference = $previousErrorActionPreference
        if ($downExitCode -ne 0) {
            Write-TaskLog "docker compose down returned a non-zero exit code"
        }
    }
    catch {
        Write-TaskLog "docker compose down failed: $($_.Exception.Message)"
    }

    if ($ShutdownWsl) {
        try {
            Write-TaskLog "Shutting down all WSL distributions"
            & wsl.exe --shutdown
            if ($LASTEXITCODE -ne 0) {
                Write-TaskLog "wsl --shutdown returned a non-zero exit code"
            }
        }
        catch {
            Write-TaskLog "wsl --shutdown failed: $($_.Exception.Message)"
        }
    }

    if ($lock) {
        $lock.Dispose()
    }
}

exit $exitCode
