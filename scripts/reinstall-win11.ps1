#Requires -Version 5.1
<#
.SYNOPSIS
  Reinstall: full remove then install. Forwards port set args to install-win11.ps1.

.NOTES
  If SmartScreen/Defender blocks these scripts: Unblock-File -Path .\*.ps1 then re-run elevated.
  Child scripts run in a separate powershell.exe and inherit the host execution policy (no policy override flag).
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Unblock-File -LiteralPath $PSCommandPath -ErrorAction SilentlyContinue

$DeployDir = $PSScriptRoot

function Write-Step([string]$Message) { Write-Host ">> $Message" -ForegroundColor Cyan }
function Write-Ok([string]$Message) { Write-Host "OK  $Message" -ForegroundColor Green }
function Write-Fail([string]$Message) { Write-Host "ERR $Message" -ForegroundColor Red }

function Invoke-ChildScript([string]$ScriptPath, [string[]]$ScriptArgs) {
    # Separate process so child `exit` does not end this session. Inherit host execution policy.
    $argList = @('-NoProfile', '-File', $ScriptPath) + @($ScriptArgs)
    $proc = Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -Wait -PassThru -NoNewWindow
    if ($null -eq $proc.ExitCode -or $proc.ExitCode -ne 0) {
        throw "$(Split-Path -Leaf $ScriptPath) failed with exit code $($proc.ExitCode)"
    }
}

try {
    $removeScript = Join-Path $DeployDir 'remove-win11.ps1'
    $installScript = Join-Path $DeployDir 'install-win11.ps1'
    if (-not (Test-Path -LiteralPath $removeScript)) { throw "Missing $removeScript" }
    if (-not (Test-Path -LiteralPath $installScript)) { throw "Missing $installScript" }

    $forwardArgs = @()
    if ($args.Count -gt 0) {
        if (-not ($args.Count -eq 3 -and $args[0] -eq 'port' -and $args[1] -eq 'set')) {
            throw "Unknown arguments. Usage: .\reinstall-win11.ps1   or   .\reinstall-win11.ps1 port set <NUMBER>"
        }
        $forwardArgs = @([string]$args[0], [string]$args[1], [string]$args[2])
    }

    Write-Step 'Reinstall local Windows: remove'
    Invoke-ChildScript -ScriptPath $removeScript -ScriptArgs @()

    Write-Step 'Reinstall local Windows: install'
    Invoke-ChildScript -ScriptPath $installScript -ScriptArgs $forwardArgs

    Write-Ok 'Local Windows reinstall complete'
    exit 0
}
catch {
    Write-Fail $_.Exception.Message
    exit 1
}
