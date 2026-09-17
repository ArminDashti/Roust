#Requires -Version 5.1
<#
.SYNOPSIS
  Fast self-check for scripts/*.ps1 path wiring (no install/remove side effects).
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$DeployDir = $PSScriptRoot
$RepoRoot = [System.IO.Path]::GetFullPath((Join-Path $DeployDir '..'))
$fail = 0

function Assert-True([bool]$Cond, [string]$Msg) {
    if ($Cond) {
        Write-Host "OK  $Msg" -ForegroundColor Green
    }
    else {
        Write-Host "ERR $Msg" -ForegroundColor Red
        $script:fail++
    }
}

Assert-True (Test-Path -LiteralPath (Join-Path $RepoRoot 'roust-api\Cargo.toml')) "RepoRoot=$RepoRoot has roust-api\Cargo.toml"
Assert-True (Test-Path -LiteralPath (Join-Path $RepoRoot 'roust-webui\package.json')) "RepoRoot has roust-webui\package.json"
Assert-True (Test-Path -LiteralPath (Join-Path $DeployDir 'install-win11.ps1')) 'install-win11.ps1 present'
Assert-True (Test-Path -LiteralPath (Join-Path $DeployDir 'remove-win11.ps1')) 'remove-win11.ps1 present'
Assert-True (Test-Path -LiteralPath (Join-Path $DeployDir 'reinstall-win11.ps1')) 'reinstall-win11.ps1 present'

$reinstall = Get-Content -LiteralPath (Join-Path $DeployDir 'reinstall-win11.ps1') -Raw
Assert-True ($reinstall -match "remove-win11\.ps1") 'reinstall references remove-win11.ps1'
Assert-True ($reinstall -match "install-win11\.ps1") 'reinstall references install-win11.ps1'
Assert-True ($reinstall -notmatch "ExecutionPolicy") 'reinstall does not set ExecutionPolicy'
Assert-True ($reinstall -notmatch 'taskkill\.exe') 'reinstall does not call taskkill.exe'

foreach ($name in @('install-win11.ps1', 'remove-win11.ps1')) {
    $text = Get-Content -LiteralPath (Join-Path $DeployDir $name) -Raw
    Assert-True ($text -like "*Join-Path `$DeployDir '..'*") "$name uses .. for RepoRoot"
    Assert-True ($text -notlike "*Join-Path `$DeployDir '..\..\..'*") "$name does not use ..\..\.. for RepoRoot"
    Assert-True ($text -notmatch 'taskkill\.exe') "$name does not call taskkill.exe"
    Assert-True ($text -notmatch "WindowStyle\s+Hidden") "$name does not start Hidden windows"
}

$install = Get-Content -LiteralPath (Join-Path $DeployDir 'install-win11.ps1') -Raw
Assert-True ($install -match "ProgramData") 'install references ProgramData sync'
Assert-True ($install -match "vite\.js") 'install starts vite via node (not npm.cmd Redirect)'
Assert-True ($install -notmatch "\[guid\]::NewGuid") 'install does not use TEMP+GUID extract path'
Assert-True ($install -match "WinDivert-2\.2\.2-A\.zip") 'install names WinDivert zip explicitly'
Assert-True ($install -like "*Join-Path `$ApiDir 'assets'*") 'install caches WinDivert under api assets'

$remove = Get-Content -LiteralPath (Join-Path $DeployDir 'remove-win11.ps1') -Raw
Assert-True ($remove -match "ProgramData") 'remove cleans ProgramData\roust'

foreach ($s in @('install-win11.ps1', 'remove-win11.ps1', 'reinstall-win11.ps1', 'selfcheck-win11.ps1')) {
    $errs = $null
    $null = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $DeployDir $s), [ref]$null, [ref]$errs)
    Assert-True (-not $errs -or $errs.Count -eq 0) "parse $s"
}

if ($fail -gt 0) {
    Write-Host "ERR selfcheck failed ($fail)" -ForegroundColor Red
    exit 1
}
Write-Host 'OK  scripts selfcheck passed' -ForegroundColor Green
exit 0
