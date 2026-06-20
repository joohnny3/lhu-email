[CmdletBinding()]
param(
    [switch]$OnlyIfDue,
    [switch]$ShutdownWsl,
    [int]$DockerReadyTimeoutSeconds = 300
)

$ErrorActionPreference = "Stop"

$Root = Split-Path -Parent $PSScriptRoot
$LogDir = Join-Path $Root "logs\lhu-weekly-email"
$TaskLog = Join-Path $LogDir "task-scheduler.log"
$StateFile = Join-Path $Root "state\task-scheduler.json"
$LockFile = Join-Path $Root "state\task-scheduler.lock"
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

$lock = $null
$exitCode = 1

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
    Get-Command docker -ErrorAction Stop | Out-Null
    Start-DockerEngine

    Write-TaskLog "Starting lhu-weekly-email job"
    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    & docker compose run --rm lhu-weekly-email 2>&1 |
        Tee-Object -FilePath $TaskLog -Append
    $jobExitCode = $LASTEXITCODE
    $ErrorActionPreference = $previousErrorActionPreference
    if ($jobExitCode -ne 0) {
        throw "Docker job failed with exit code $jobExitCode"
    }

    Save-SuccessState
    $exitCode = 0
    Write-TaskLog "Job finished successfully"
}
catch {
    Write-TaskLog "Job failed: $($_.Exception.Message)"
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
