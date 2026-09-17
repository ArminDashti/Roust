#Requires -Version 5.1
<#
.SYNOPSIS
  Remove local Roust stack: stop API/WebUI, uninstall Windows service Roust, clear state and install dir.

.NOTES
  Local maintainer uninstall only. Needs elevated PowerShell for the Windows service.
  If SmartScreen/Defender blocks: Unblock-File -Path .\remove-win11.ps1 then re-run.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Unblock-File -LiteralPath $PSCommandPath -ErrorAction SilentlyContinue

Import-Module NetTCPIP -Force -ErrorAction SilentlyContinue | Out-Null

$DeployDir = $PSScriptRoot
# scripts/ sits directly under the repo root (one level up).
$RepoRoot = [System.IO.Path]::GetFullPath((Join-Path $DeployDir '..'))
$StateDir = Join-Path $RepoRoot '.armin\state'
$InstallDir = Join-Path $RepoRoot 'Roust'
$ProgramDataDir = Join-Path $env:ProgramData 'roust'
if (-not (Test-Path -LiteralPath (Join-Path $RepoRoot 'roust-api\Cargo.toml'))) {
    throw "Repo root looks wrong: $RepoRoot (expected roust-api\Cargo.toml beside scripts\)"
}
$StateJson = Join-Path $StateDir 'state.json'
$ApiPidFile = Join-Path $StateDir 'api.pid'
$WebuiPidFile = Join-Path $StateDir 'webui.pid'
$ServiceName = 'Roust'
$DefaultApiPort = 8787
$DefaultWebUiPort = 5173

function Write-Step([string]$Message) { Write-Host ">> $Message" -ForegroundColor Cyan }
function Write-Ok([string]$Message) { Write-Host "OK  $Message" -ForegroundColor Green }
function Write-Fail([string]$Message) { Write-Host "ERR $Message" -ForegroundColor Red }

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $prin = New-Object Security.Principal.WindowsPrincipal($id)
    return $prin.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Read-State {
    if (-not (Test-Path -LiteralPath $StateJson)) { return $null }
    try {
        return Get-Content -LiteralPath $StateJson -Raw | ConvertFrom-Json
    }
    catch {
        return $null
    }
}

function Stop-ProcessTree([int]$ProcessId) {
    # Prefer Stop-Process over external force-kill tools (fewer AV heuristics).
    Get-CimInstance Win32_Process -Filter "ParentProcessId = $ProcessId" -ErrorAction SilentlyContinue |
        ForEach-Object { Stop-ProcessTree -ProcessId ([int]$_.ProcessId) }
    if (Get-Process -Id $ProcessId -ErrorAction SilentlyContinue) {
        Stop-Process -Id $ProcessId -Force -ErrorAction SilentlyContinue
    }
}

function Stop-PidFile([string]$Path, [string]$Label) {
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $pidText = Get-Content -LiteralPath $Path -ErrorAction SilentlyContinue
    if ($pidText) {
        $procId = [int]$pidText
        if (Get-Process -Id $procId -ErrorAction SilentlyContinue) {
            Write-Step "Stopping $Label (pid $procId)"
            Stop-ProcessTree -ProcessId $procId
        }
    }
    Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
}

function Get-ListeningOwnerPids([int]$Port) {
    if ($Port -le 0) { return @() }
    try {
        $owners = @(Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction Stop |
            Select-Object -ExpandProperty OwningProcess -Unique)
        return @($owners | Where-Object { $_ -and $_ -gt 0 })
    }
    catch {
        $pids = @()
        $lines = & netstat.exe -ano -p tcp 2>$null
        foreach ($line in $lines) {
            if ($line -match "^\s*TCP\s+\S+:$Port\s+\S+\s+LISTENING\s+(\d+)\s*$") {
                $pids += [int]$Matches[1]
            }
        }
        return @($pids | Select-Object -Unique)
    }
}

function Stop-ListenersOnPort([int]$Port, [string]$Label) {
    if ($Port -le 0) { return }
    $owningPids = @(Get-ListeningOwnerPids $Port)
    foreach ($procId in $owningPids) {
        $proc = Get-Process -Id $procId -ErrorAction SilentlyContinue
        if (-not $proc) { continue }
        Write-Step "Releasing $Label port $Port (pid $procId / $($proc.ProcessName))"
        Stop-ProcessTree -ProcessId $procId
    }
}

function Wait-PortFree([int]$Port, [int]$TimeoutSec = 15) {
    if ($Port -le 0) { return }
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        if (-not (Get-ListeningOwnerPids $Port)) { return }
        Start-Sleep -Milliseconds 400
    }
    throw "Port $Port is still listening after remove; cannot release it."
}

function Test-FileLocked([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    try {
        $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
        $stream.Close()
        return $false
    }
    catch {
        return $true
    }
}

function Stop-WinDivertDriver {
    foreach ($name in @('WinDivert', 'WinDivert14')) {
        $queryOut = & sc.exe query $name 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) { continue }
        if ($queryOut -notmatch 'RUNNING') { continue }

        Write-Step "Stopping kernel driver '$name'"
        & sc.exe stop $name 2>&1 | ForEach-Object { Write-Host $_ }
        $deadline = (Get-Date).AddSeconds(30)
        while ((Get-Date) -lt $deadline) {
            $again = & sc.exe query $name 2>&1 | Out-String
            if ($LASTEXITCODE -ne 0 -or $again -match 'STOPPED') { break }
            Start-Sleep -Milliseconds 400
        }
    }
}

function Assert-WinDivertSysUnlocked {
    $sys = Join-Path $InstallDir 'WinDivert64.sys'
    if ((Test-Path -LiteralPath $sys) -and (Test-FileLocked $sys)) {
        throw "WinDivert64.sys is still locked under $InstallDir after stopping WinDivert; cannot remove or replace it."
    }
}

function Uninstall-RoustService {
    $exeCandidates = @(
        (Join-Path $InstallDir 'roust.exe'),
        (Join-Path $RepoRoot 'roust-api\target\release\roust.exe')
    )
    $exe = $null
    foreach ($c in $exeCandidates) {
        if (Test-Path -LiteralPath $c) { $exe = $c; break }
    }

    $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if ($svc) {
        if (-not (Test-IsAdmin)) {
            throw "Administrator elevation required to stop/uninstall Windows service '$ServiceName'."
        }
        $svc.Refresh()
        if ($svc.Status -ne [System.ServiceProcess.ServiceControllerStatus]::Stopped) {
            Write-Step "Stopping Windows service '$ServiceName' (status=$($svc.Status))"
            try {
                Stop-Service -Name $ServiceName -Force -ErrorAction Stop
            }
            catch {
                Write-Step "Stop-Service failed; sc.exe stop ($($_.Exception.Message))"
                & sc.exe stop $ServiceName 2>&1 | ForEach-Object { Write-Host $_ }
            }
            $deadline = (Get-Date).AddSeconds(45)
            do {
                Start-Sleep -Milliseconds 400
                $svc.Refresh()
                if ($svc.Status -eq [System.ServiceProcess.ServiceControllerStatus]::Stopped) { break }
            } while ((Get-Date) -lt $deadline)

            if ($svc.Status -ne [System.ServiceProcess.ServiceControllerStatus]::Stopped) {
                Get-CimInstance Win32_Process -Filter "Name = 'roust.exe'" -ErrorAction SilentlyContinue |
                    Where-Object { $_.ExecutablePath -and ($_.ExecutablePath -ieq (Join-Path $InstallDir 'roust.exe')) } |
                    ForEach-Object {
                        Write-Step "Stopping stuck roust.exe pid $($_.ProcessId)"
                        Stop-ProcessTree -ProcessId ([int]$_.ProcessId)
                    }
                Start-Sleep -Seconds 2
                $svc.Refresh()
            }
        }
        if ($exe) {
            Write-Step "Uninstalling Windows service via $exe --uninstall-service"
            & $exe --uninstall-service 2>&1 | ForEach-Object { Write-Host $_ }
        }
        else {
            Write-Step "roust.exe not found; removing service '$ServiceName' with sc.exe"
            & sc.exe delete $ServiceName | Out-Null
        }
    }
    elseif ($exe) {
        Write-Step 'No Roust service registered; skipping uninstall'
    }
}

if ($args.Count -gt 0) {
    Write-Fail 'This script accepts no CLI arguments.'
    exit 1
}

try {
    Write-Step 'Removing local Windows Roust stack (API + WebUI + service)'

    $state = Read-State
    $apiPort = $DefaultApiPort
    $webUiPort = $DefaultWebUiPort
    if ($state -and $state.ports) {
        if ($state.ports.api) { $apiPort = [int]$state.ports.api }
        if ($state.ports.webui) { $webUiPort = [int]$state.ports.webui }
    }

    Stop-PidFile -Path $WebuiPidFile -Label 'WebUI'
    Stop-PidFile -Path $ApiPidFile -Label 'API'
    Stop-ListenersOnPort -Port $webUiPort -Label 'WebUI'
    Stop-ListenersOnPort -Port $apiPort -Label 'API'

    Uninstall-RoustService
    Stop-WinDivertDriver
    Assert-WinDivertSysUnlocked

    Write-Step 'Clearing Roust NRPT DNS exception rules'
    try {
        Get-DnsClientNrptRule -ErrorAction SilentlyContinue |
            Where-Object { $_.Comment -eq 'Roust' } |
            ForEach-Object { Remove-DnsClientNrptRule -Name $_.Name -Force -ErrorAction SilentlyContinue }
    } catch {
        Write-Host "  (NRPT cleanup skipped: $_)"
    }

    Write-Step 'Clearing Roust hosts-file overrides'
    try {
        $hostsPath = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
        if (Test-Path -LiteralPath $hostsPath) {
            $begin = '# ROUST-HOST-BEGIN'
            $end = '# ROUST-HOST-END'
            $lines = Get-Content -LiteralPath $hostsPath
            $out = New-Object System.Collections.Generic.List[string]
            $inBlock = $false
            foreach ($line in $lines) {
                $trimmed = $line.Trim()
                if ($trimmed -eq $begin) { $inBlock = $true; continue }
                if ($trimmed -eq $end) { $inBlock = $false; continue }
                if (-not $inBlock) { [void]$out.Add($line) }
            }
            Set-Content -LiteralPath $hostsPath -Value $out -Encoding ascii
            ipconfig /flushdns | Out-Null
        }
    } catch {
        Write-Host "  (hosts cleanup skipped: $_)"
    }

    Wait-PortFree -Port $webUiPort
    Wait-PortFree -Port $apiPort

    if (Test-Path -LiteralPath $InstallDir) {
        Write-Step "Removing install directory $InstallDir"
        Remove-Item -LiteralPath $InstallDir -Recurse -Force -ErrorAction Stop
        if (Test-Path -LiteralPath $InstallDir) {
            $sys = Join-Path $InstallDir 'WinDivert64.sys'
            if (Test-Path -LiteralPath $sys) {
                throw "Install dir remove left WinDivert64.sys at $sys"
            }
            throw "Install directory still present after remove: $InstallDir"
        }
    }

    if (Test-Path -LiteralPath $ProgramDataDir) {
        Write-Step "Removing ProgramData config $ProgramDataDir"
        Remove-Item -LiteralPath $ProgramDataDir -Recurse -Force -ErrorAction Stop
    }

    if (Test-Path -LiteralPath $StateDir) {
        Write-Step "Clearing state directory $StateDir"
        Remove-Item -LiteralPath $StateDir -Recurse -Force -ErrorAction Stop
    }

    Write-Ok 'Local Windows remove complete'
    # Clear native-command leftovers so callers (reinstall-win11.ps1) do not false-fail.
    $global:LASTEXITCODE = 0
    exit 0
}
catch {
    Write-Fail $_.Exception.Message
    exit 1
}
