#Requires -Version 5.1
<#
.SYNOPSIS
  Install or update local Roust: Windows service Roust (roust.exe) + API + WebUI processes.

.DESCRIPTION
  Fresh install when not present.
  When already installed: remove the app (service + binaries + API/WebUI processes) then reinstall;
  keep data (routes.json, app-binds.json, dns-exceptions.json, host-overrides.json, and any other non-app files under the install dir).
  Default ports: API 8787, WebUI 5173.
  Override API port:  .\install-win11.ps1 port set <NUMBER>

.NOTES
  Local maintainer install only (builds from this repo). Needs elevated PowerShell.
  If SmartScreen/Defender blocks: Unblock-File -Path .\install-win11.ps1 then re-run.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Clear MOTW on this script if present (downloaded zip / browser mark).
Unblock-File -LiteralPath $PSCommandPath -ErrorAction SilentlyContinue

# PowerShell 7 often fails NetTCPIP auto-load (alias conflicts); import explicitly when possible.
Import-Module NetTCPIP -Force -ErrorAction SilentlyContinue | Out-Null

$DeployDir = $PSScriptRoot
# scripts/ sits directly under the repo root (one level up).
$RepoRoot = [System.IO.Path]::GetFullPath((Join-Path $DeployDir '..'))
$ApiDir = Join-Path $RepoRoot 'roust-api'
$WebuiDir = Join-Path $RepoRoot 'roust-webui'
$StateDir = Join-Path $RepoRoot '.armin\state'
$InstallDir = Join-Path $RepoRoot 'Roust'
# Service prefers install-dir routes.json beside roust.exe; ProgramData is a fallback/mirror
# (see Config::default_config_path). Keep the mirror for older installs / remove cleanup.
$ProgramDataDir = Join-Path $env:ProgramData 'roust'
if (-not (Test-Path -LiteralPath (Join-Path $ApiDir 'Cargo.toml'))) {
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

function Require-Admin([string]$Why) {
    if (-not (Test-IsAdmin)) {
        throw "Administrator elevation required: $Why. Re-run in elevated PowerShell."
    }
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

function Test-PortInUse([int]$Port) {
    if ($Port -le 0) { return $false }
    # Prefer TCP connect: Get-NetTCPConnection often lags or throws under StrictMode races.
    try {
        $client = [System.Net.Sockets.TcpClient]::new()
        try {
            $iar = $client.BeginConnect('127.0.0.1', $Port, $null, $null)
            $ok = $iar.AsyncWaitHandle.WaitOne(400, $false)
            if ($ok -and $client.Connected) {
                $client.EndConnect($iar) | Out-Null
                return $true
            }
            return $false
        }
        finally { $client.Close() }
    }
    catch {
        return [bool](Get-ListeningOwnerPids $Port)
    }
}

function Test-TcpPortFree([int]$Port) { return -not (Test-PortInUse $Port) }

function Test-PidAlive([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    $pidText = Get-Content -LiteralPath $Path -ErrorAction SilentlyContinue
    if (-not $pidText) { return $false }
    return [bool](Get-Process -Id ([int]$pidText) -ErrorAction SilentlyContinue)
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

function Write-State([int]$ApiPort, [int]$WebUiPort, [string]$InstallPath) {
    New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
    $obj = [ordered]@{
        stack_name    = 'roust'
        service_name  = $ServiceName
        installed     = $true
        ports         = @{ api = $ApiPort; webui = $WebUiPort }
        install_dir   = $InstallPath
        binary_path   = (Join-Path $InstallPath 'roust.exe')
        api_binary    = (Join-Path $InstallPath 'roust-api.exe')
        updated_at    = (Get-Date).ToString('o')
    }
    ($obj | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath $StateJson -Encoding UTF8
}

function Test-AlreadyInstalled {
    $state = Read-State
    if ($state -and $state.installed) { return $true }
    if (Get-Service -Name $ServiceName -ErrorAction SilentlyContinue) { return $true }
    if ((Test-PidAlive $ApiPidFile) -or (Test-PidAlive $WebuiPidFile)) { return $true }
    if (Test-Path -LiteralPath (Join-Path $InstallDir 'roust.exe')) { return $true }
    return $false
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

function Stop-ListenersOnPort([int]$Port, [string]$Label) {
    if ($Port -le 0) { return }
    $owners = @(Get-ListeningOwnerPids $Port)
    foreach ($procId in $owners) {
        $proc = Get-Process -Id $procId -ErrorAction SilentlyContinue
        if (-not $proc) { continue }
        Write-Step "Stopping $Label listener on port $Port (pid $procId)"
        Stop-ProcessTree -ProcessId $procId
    }
}

function Wait-TcpPortListen([int]$Port, [int]$TimeoutSec, [string]$Label, [string]$ErrLog) {
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        if (Test-PortInUse $Port) { return }
        Start-Sleep -Seconds 1
    }
    $tail = ''
    if ($ErrLog -and (Test-Path -LiteralPath $ErrLog)) {
        $tail = (Get-Content -LiteralPath $ErrLog -Tail 40) -join "`n"
    }
    throw "$Label did not listen on port $Port within ${TimeoutSec}s.`n$tail"
}

function Start-LoggedCmd([string]$ExePath, [string[]]$ExeArgs, [string]$WorkingDirectory, [string]$StdoutLog, [string]$StderrLog, [string]$PidFile) {
    # Start the exe directly. Avoid cmd.exe + Start-Process ArgumentList quoting bugs
    # ("The filename, directory name, or volume label syntax is incorrect.").
    if ($StdoutLog -eq $StderrLog) {
        throw 'Start-LoggedCmd requires distinct StdoutLog and StderrLog paths'
    }
    foreach ($logPath in @($StdoutLog, $StderrLog)) {
        $dir = Split-Path -Parent $logPath
        if ($dir) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        # Truncate so a locked/stale handle from a prior run does not confuse Start-Process.
        Set-Content -LiteralPath $logPath -Value '' -Encoding UTF8
    }
    $proc = Start-Process -FilePath $ExePath -ArgumentList $ExeArgs `
        -WorkingDirectory $WorkingDirectory -PassThru `
        -RedirectStandardOutput $StdoutLog -RedirectStandardError $StderrLog `
        -WindowStyle Minimized
    if (-not $proc) { throw "Failed to start $ExePath" }
    $proc.Id | Set-Content -LiteralPath $PidFile
    return $proc
}

function Resolve-NpmCmd {
    $cmd = Get-Command npm.cmd -ErrorAction SilentlyContinue
    if (-not $cmd) { throw 'npm.cmd not found on PATH. Install Node.js.' }
    return $cmd.Source
}

function Resolve-CargoExe {
    $cmd = Get-Command cargo.exe -ErrorAction SilentlyContinue
    if (-not $cmd) { throw 'cargo.exe not found on PATH. Install Rust (rustup).' }
    return $cmd.Source
}

function Resolve-WinDivertX64 {
    $candidates = @(
        (Join-Path $ApiDir 'WinDivert-2.2.2-A\x64'),
        (Join-Path $ApiDir 'assets\WinDivert-2.2.2-A\x64'),
        (Join-Path $ApiDir 'assets\WinDivert-2.2.2-A\WinDivert-2.2.2-A\x64')
    )
    foreach ($dir in $candidates) {
        if (Test-Path -LiteralPath (Join-Path $dir 'WinDivert.dll')) { return $dir }
    }

    # SDK often not committed; fetch official GitHub release (same URL as Dockerfile).
    # Cache under repo assets/ (not %TEMP% + random path — that pattern trips AV).
    $sdkRoot = Join-Path $ApiDir 'WinDivert-2.2.2-A'
    $x64 = Join-Path $sdkRoot 'x64'
    $zipUrl = 'https://github.com/basil00/WinDivert/releases/download/v2.2.2/WinDivert-2.2.2-A.zip'
    $cacheDir = Join-Path $ApiDir 'assets'
    $zipPath = Join-Path $cacheDir 'WinDivert-2.2.2-A.zip'
    $extractDir = Join-Path $cacheDir 'WinDivert-extract'
    Write-Step "Downloading official WinDivert SDK into $cacheDir"
    try {
        New-Item -ItemType Directory -Force -Path $cacheDir | Out-Null
        if (Test-Path -LiteralPath $extractDir) {
            Remove-Item -LiteralPath $extractDir -Recurse -Force
        }
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $zipUrl -OutFile $zipPath -UseBasicParsing
        Unblock-File -LiteralPath $zipPath -ErrorAction SilentlyContinue
        New-Item -ItemType Directory -Force -Path $extractDir | Out-Null
        Expand-Archive -LiteralPath $zipPath -DestinationPath $extractDir -Force
        $extracted = Join-Path $extractDir 'WinDivert-2.2.2-A'
        if (-not (Test-Path -LiteralPath (Join-Path $extracted 'x64\WinDivert.dll'))) {
            throw "Downloaded WinDivert zip missing x64\WinDivert.dll under $extracted"
        }
        if (Test-Path -LiteralPath $sdkRoot) {
            Remove-Item -LiteralPath $sdkRoot -Recurse -Force
        }
        Copy-Item -LiteralPath $extracted -Destination $sdkRoot -Recurse
    }
    finally {
        Remove-Item -LiteralPath $extractDir -Recurse -Force -ErrorAction SilentlyContinue
    }
    if (-not (Test-Path -LiteralPath (Join-Path $x64 'WinDivert.dll'))) {
        throw "WinDivert download failed; still missing $x64\WinDivert.dll"
    }
    return $x64
}

function Set-WebuiApiProxy([string]$Dir, [int]$ApiPort) {
    $envFile = Join-Path $Dir '.env'
    $envExample = Join-Path $Dir '.env.example'
    $line = "VITE_API_PROXY_TARGET=http://127.0.0.1:$ApiPort"
    if (-not (Test-Path -LiteralPath $envFile)) {
        if (Test-Path -LiteralPath $envExample) {
            Copy-Item -LiteralPath $envExample -Destination $envFile
        }
        else {
            Set-Content -LiteralPath $envFile -Value $line
            return
        }
    }
    $lines = Get-Content -LiteralPath $envFile
    $found = $false
    $updated = foreach ($l in $lines) {
        if ($l -match '^\s*VITE_API_PROXY_TARGET\s*=') {
            $found = $true
            $line
        }
        else { $l }
    }
    if (-not $found) { $updated = @($updated) + $line }
    Set-Content -LiteralPath $envFile -Value $updated
}

function Stop-AppProcesses {
    Stop-PidFile -Path $WebuiPidFile -Label 'WebUI'
    Stop-PidFile -Path $ApiPidFile -Label 'API'
    $state = Read-State
    $apiPort = $DefaultApiPort
    $webPort = $DefaultWebUiPort
    if ($state -and $state.ports) {
        if ($state.ports.api) { $apiPort = [int]$state.ports.api }
        if ($state.ports.webui) { $webPort = [int]$state.ports.webui }
    }
    Stop-ListenersOnPort -Port $webPort -Label 'WebUI'
    Stop-ListenersOnPort -Port $apiPort -Label 'API'
}

function Stop-RoustServiceIfPresent {
    $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if (-not $svc) { return }

    $svc.Refresh()
    if ($svc.Status -eq [System.ServiceProcess.ServiceControllerStatus]::Stopped) { return }

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
        if ($svc.Status -eq [System.ServiceProcess.ServiceControllerStatus]::Stopped) { return }
    } while ((Get-Date) -lt $deadline)

    # Last resort: service may ignore STOP (hung StartPending / CanStop=false).
    $exe = Join-Path $InstallDir 'roust.exe'
    Get-CimInstance Win32_Process -Filter "Name = 'roust.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.ExecutablePath -and ($_.ExecutablePath -ieq $exe) } |
        ForEach-Object {
            Write-Step "Stopping stuck roust.exe pid $($_.ProcessId)"
            Stop-ProcessTree -ProcessId ([int]$_.ProcessId)
        }

    $deadline2 = (Get-Date).AddSeconds(15)
    do {
        Start-Sleep -Milliseconds 400
        $svc.Refresh()
        if ($svc.Status -eq [System.ServiceProcess.ServiceControllerStatus]::Stopped) { return }
    } while ((Get-Date) -lt $deadline2)

    throw "Windows service '$ServiceName' did not stop (status=$($svc.Status))"
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

function Uninstall-RoustServiceKeepData {
    $exeCandidates = @(
        (Join-Path $InstallDir 'roust.exe'),
        (Join-Path $ApiDir 'target\release\roust.exe')
    )
    $exe = $null
    foreach ($c in $exeCandidates) {
        if (Test-Path -LiteralPath $c) { $exe = $c; break }
    }

    $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if (-not $svc) { return }

    Require-Admin "uninstall Windows service '$ServiceName' before update"
    Stop-RoustServiceIfPresent

    if ($exe) {
        Write-Step "Uninstalling Windows service via $exe --uninstall-service"
        & $exe --uninstall-service 2>&1 | ForEach-Object { Write-Host $_ }
    }
    else {
        Write-Step "roust.exe not found; removing service '$ServiceName' with sc.exe"
        & sc.exe delete $ServiceName | Out-Null
    }
}

function Remove-AppKeepData {
    Write-Step 'Removing installed app (keeping routes.json / app-binds.json / dns-exceptions.json / host-overrides.json and other data)'
    Stop-AppProcesses
    Uninstall-RoustServiceKeepData
    Stop-WinDivertDriver
    Assert-WinDivertSysUnlocked

    if (-not (Test-Path -LiteralPath $InstallDir)) { return }

    $appNames = @('roust.exe', 'roust-api.exe', 'WinDivert.dll', 'WinDivert64.sys')
    foreach ($name in $appNames) {
        $path = Join-Path $InstallDir $name
        if (Test-Path -LiteralPath $path) {
            Write-Step "Removing app file $name"
            Remove-Item -LiteralPath $path -Force -ErrorAction Stop
        }
    }

    $sysLeft = Join-Path $InstallDir 'WinDivert64.sys'
    if (Test-Path -LiteralPath $sysLeft) {
        throw "Failed to remove locked or leftover WinDivert64.sys at $sysLeft"
    }
}

function Build-ReleaseBinaries {
    $null = Resolve-WinDivertX64
    $cargo = Resolve-CargoExe
    if (-not (Test-Path -LiteralPath (Join-Path $ApiDir 'Cargo.toml'))) {
        throw "Missing Cargo.toml at $ApiDir"
    }
    Write-Step 'cargo build --release --bin roust --bin roust-api'
    Push-Location $ApiDir
    try {
        & $cargo build --release --bin roust --bin roust-api
        if ($LASTEXITCODE -ne 0) { throw "cargo build failed with exit code $LASTEXITCODE" }
    }
    finally { Pop-Location }

    $roustBuilt = Join-Path $ApiDir 'target\release\roust.exe'
    $apiBuilt = Join-Path $ApiDir 'target\release\roust-api.exe'
    if (-not (Test-Path -LiteralPath $roustBuilt)) { throw "Missing build output: $roustBuilt" }
    if (-not (Test-Path -LiteralPath $apiBuilt)) { throw "Missing build output: $apiBuilt" }
}

function Install-BinariesToInstallDir {
    New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
    $roustBuilt = Join-Path $ApiDir 'target\release\roust.exe'
    $apiBuilt = Join-Path $ApiDir 'target\release\roust-api.exe'
    Write-Step "Copying binaries to $InstallDir"
    Copy-Item -LiteralPath $roustBuilt -Destination (Join-Path $InstallDir 'roust.exe') -Force
    Copy-Item -LiteralPath $apiBuilt -Destination (Join-Path $InstallDir 'roust-api.exe') -Force

    Stop-WinDivertDriver
    Assert-WinDivertSysUnlocked

    $wd = Resolve-WinDivertX64
    foreach ($name in @('WinDivert.dll', 'WinDivert64.sys')) {
        $src = Join-Path $wd $name
        if (-not (Test-Path -LiteralPath $src)) { throw "Missing WinDivert file: $src" }
        Copy-Item -LiteralPath $src -Destination (Join-Path $InstallDir $name) -Force
    }

    foreach ($dataName in @('routes.json', 'app-binds.json', 'dns-exceptions.json', 'host-overrides.json')) {
        $dataInstall = Join-Path $InstallDir $dataName
        $dataSource = Join-Path $ApiDir $dataName
        if (-not (Test-Path -LiteralPath $dataInstall)) {
            if ($dataName -eq 'routes.json' -and -not (Test-Path -LiteralPath $dataSource)) {
                throw "routes.json missing at $dataSource"
            }
            if (Test-Path -LiteralPath $dataSource) {
                Write-Step "Seeding $dataName into install dir (first install only)"
                Copy-Item -LiteralPath $dataSource -Destination $dataInstall
            }
        }
        else {
            Write-Step "Keeping existing $dataName"
        }
    }

    foreach ($name in @('roust.exe', 'roust-api.exe', 'WinDivert.dll', 'WinDivert64.sys', 'routes.json')) {
        $path = Join-Path $InstallDir $name
        if (-not (Test-Path -LiteralPath $path)) { throw "Missing after install copy: $path" }
    }

    Sync-ProgramDataFromInstallDir
}

function Sync-ProgramDataFromInstallDir {
    # Mirror install-dir data into ProgramData (fallback path + remove-win11 cleanup).
    New-Item -ItemType Directory -Force -Path $ProgramDataDir | Out-Null
    foreach ($dataName in @('routes.json', 'app-binds.json', 'dns-exceptions.json', 'host-overrides.json')) {
        $src = Join-Path $InstallDir $dataName
        if (-not (Test-Path -LiteralPath $src)) { continue }
        $dst = Join-Path $ProgramDataDir $dataName
        Write-Step "Syncing $dataName -> $ProgramDataDir"
        Copy-Item -LiteralPath $src -Destination $dst -Force
    }
}

function Ensure-RoustService {
    Require-Admin 'install or start Windows service Roust'
    $exe = Join-Path $InstallDir 'roust.exe'
    if (-not (Test-Path -LiteralPath $exe)) { throw "Missing $exe" }

    Stop-RoustServiceIfPresent

    $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if ($svc) {
        Write-Step 'Re-registering existing Roust service'
        & $exe --uninstall-service 2>&1 | ForEach-Object { Write-Host $_ }
    }

    Write-Step 'Installing Windows service Roust'
    & $exe --install-service 2>&1 | ForEach-Object { Write-Host $_ }
    if ($LASTEXITCODE -ne 0) {
        throw 'roust.exe --install-service failed'
    }

    Write-Step 'Starting Windows service Roust'
    # Start-Service can block forever on StartPending; poll with a hard ceiling.
    & sc.exe start $ServiceName 2>&1 | ForEach-Object { Write-Host $_ }
    $deadline = (Get-Date).AddSeconds(60)
    do {
        Start-Sleep -Milliseconds 400
        $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
        if (-not $svc) { throw "Windows service '$ServiceName' missing after start" }
        $svc.Refresh()
        if ($svc.Status -eq [System.ServiceProcess.ServiceControllerStatus]::Running) { return }
        if ($svc.Status -eq [System.ServiceProcess.ServiceControllerStatus]::Stopped) {
            $tail = ''
            $log = Join-Path $InstallDir 'logs\roust-service.log'
            if (Test-Path -LiteralPath $log) { $tail = (Get-Content -LiteralPath $log -Tail 40) -join "`n" }
            throw "Windows service '$ServiceName' stopped after start.`n$tail"
        }
    } while ((Get-Date) -lt $deadline)

    # Stuck StartPending: kill install-dir roust.exe so SCM can settle.
    $exe = Join-Path $InstallDir 'roust.exe'
    Get-CimInstance Win32_Process -Filter "Name = 'roust.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.ExecutablePath -and ($_.ExecutablePath -ieq $exe) } |
        ForEach-Object {
            Write-Step "Stopping StartPending roust.exe pid $($_.ProcessId)"
            Stop-ProcessTree -ProcessId ([int]$_.ProcessId)
        }

    $tail2 = ''
    $log2 = Join-Path $InstallDir 'logs\roust-service.log'
    if (Test-Path -LiteralPath $log2) { $tail2 = (Get-Content -LiteralPath $log2 -Tail 40) -join "`n" }
    throw "Windows service '$ServiceName' did not reach Running within 60s (status=$($svc.Status)).`n$tail2"
}

function Start-Api([int]$ApiPort) {
    Require-Admin 'run roust-api (needs elevation for routes/WFP)'
    New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
    $exe = Join-Path $InstallDir 'roust-api.exe'
    $config = Join-Path $InstallDir 'routes.json'
    $stdoutLog = Join-Path $StateDir 'api.out.log'
    $stderrLog = Join-Path $StateDir 'api.err.log'
    $bind = "127.0.0.1:$ApiPort"
    Write-Step "Starting roust-api on $bind"
    Start-LoggedCmd -ExePath $exe `
        -ExeArgs @('--bind', $bind, '--config', $config) `
        -WorkingDirectory $InstallDir `
        -StdoutLog $stdoutLog -StderrLog $stderrLog -PidFile $ApiPidFile | Out-Null
    Wait-TcpPortListen -Port $ApiPort -TimeoutSec 180 -Label 'API (roust-api)' -ErrLog $stderrLog
}

function Start-WebUi([int]$ApiPort, [int]$WebUiPort) {
    if (-not (Test-Path -LiteralPath (Join-Path $WebuiDir 'package.json'))) {
        throw "WebUI missing at $WebuiDir"
    }
    $npmCmd = Resolve-NpmCmd
    Set-WebuiApiProxy -Dir $WebuiDir -ApiPort $ApiPort
    Push-Location $WebuiDir
    try {
        if (-not (Test-Path -LiteralPath (Join-Path $WebuiDir 'node_modules\vite\bin\vite.js'))) {
            Write-Step 'npm install (WebUI)'
            & $npmCmd install
            if ($LASTEXITCODE -ne 0) { throw 'npm install failed' }
        }
        else {
            Write-Step 'WebUI node_modules present; skipping npm install'
        }
        $nodeCmd = Get-Command node.exe -ErrorAction SilentlyContinue
        if (-not $nodeCmd) { throw 'node.exe not found on PATH. Install Node.js.' }
        $viteJs = Join-Path $WebuiDir 'node_modules\vite\bin\vite.js'
        if (-not (Test-Path -LiteralPath $viteJs)) { throw "Missing $viteJs after npm install" }
        $env:VITE_API_PROXY_TARGET = "http://127.0.0.1:$ApiPort"
        $webOut = Join-Path $StateDir 'webui.out.log'
        $webErr = Join-Path $StateDir 'webui.err.log'
        Write-Step "Starting WebUI on 127.0.0.1:$WebUiPort"
        # Start node/vite directly: npm.cmd + Start-Process RedirectStandard* often hangs.
        Start-LoggedCmd -ExePath $nodeCmd.Source `
            -ExeArgs @($viteJs, '--host', '127.0.0.1', '--port', "$WebUiPort", '--strictPort') `
            -WorkingDirectory $WebuiDir `
            -StdoutLog $webOut -StderrLog $webErr -PidFile $WebuiPidFile | Out-Null
        Wait-TcpPortListen -Port $WebUiPort -TimeoutSec 120 -Label 'WebUI (vite)' -ErrLog $webErr
    }
    finally { Pop-Location }
}

function Parse-CliArgs([object[]]$CliArgs) {
    $apiPort = $DefaultApiPort
    $webUiPort = $DefaultWebUiPort
    $state = Read-State
    if ($state -and $state.ports -and $state.ports.api) {
        $apiPort = [int]$state.ports.api
    }
    if ($state -and $state.ports -and $state.ports.webui) {
        $webUiPort = [int]$state.ports.webui
    }

    if ($null -eq $CliArgs -or $CliArgs.Count -eq 0) {
        return @{ ApiPort = $apiPort; WebUiPort = $webUiPort }
    }

    if ($CliArgs.Count -eq 3 -and $CliArgs[0] -eq 'port' -and $CliArgs[1] -eq 'set') {
        $n = 0
        if (-not [int]::TryParse([string]$CliArgs[2], [ref]$n)) {
            throw "port set requires an integer NUMBER; got '$($CliArgs[2])'"
        }
        if ($n -lt 1024 -or $n -gt 65535) {
            throw "API port must be 1024-65535 (got $n)"
        }
        return @{ ApiPort = $n; WebUiPort = $DefaultWebUiPort }
    }

    throw "Unknown arguments. Usage: .\install-win11.ps1   or   .\install-win11.ps1 port set <NUMBER>"
}

try {
    $parsed = Parse-CliArgs -CliArgs $args
    $apiPort = [int]$parsed.ApiPort
    $webUiPort = [int]$parsed.WebUiPort
    $isUpdate = Test-AlreadyInstalled

    if ($isUpdate) {
        Write-Step "Update local Roust (remove app; keep data) api=$apiPort webui=$webUiPort"
        Remove-AppKeepData
    }
    else {
        Write-Step "Fresh install local Roust api=$apiPort webui=$webUiPort"
        if (-not (Test-TcpPortFree $apiPort)) {
            throw "API port $apiPort is already in use"
        }
        if (-not (Test-TcpPortFree $webUiPort)) {
            throw "WebUI port $webUiPort is already in use"
        }
    }

    Build-ReleaseBinaries
    Install-BinariesToInstallDir
    Ensure-RoustService
    Start-Api -ApiPort $apiPort
    Start-WebUi -ApiPort $apiPort -WebUiPort $webUiPort
    Write-State -ApiPort $apiPort -WebUiPort $webUiPort -InstallPath $InstallDir

    if ($isUpdate) {
        Write-Ok "Local Windows update complete (api:$apiPort webui:$webUiPort service:$ServiceName)"
    }
    else {
        Write-Ok "Local Windows install complete (api:$apiPort webui:$webUiPort service:$ServiceName)"
    }
    Write-Host "Open http://127.0.0.1:$webUiPort/  (API http://127.0.0.1:$apiPort/)"
    # Clear native-command leftovers so callers (reinstall-win11.ps1) do not false-fail.
    $global:LASTEXITCODE = 0
    exit 0
}
catch {
    Write-Fail $_.Exception.Message
    exit 1
}
