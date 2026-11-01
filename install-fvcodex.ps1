[CmdletBinding()]
param(
    [ValidateSet('portable','direct')]
    [string]$Mode = 'portable',
    [string]$BaseUrl = '',
    [string]$ApiKey = '',
    [switch]$NoLaunch,
    [switch]$NoVSCode,
    [switch]$Doctor
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
    throw 'Node.js is required. Install Node.js, then run this installer again.'
}

function Test-Admin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if ($Mode -eq 'direct' -and -not $Doctor -and -not (Test-Admin)) {
    $argLine = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -Mode direct' -f $PSCommandPath
    if ($BaseUrl) { $argLine += ' -BaseUrl "{0}"' -f $BaseUrl }
    if ($ApiKey) { $argLine += ' -ApiKey "{0}"' -f $ApiKey }
    if ($NoLaunch) { $argLine += ' -NoLaunch' }
    if ($NoVSCode) { $argLine += ' -NoVSCode' }
    $proc = Start-Process powershell.exe -Verb RunAs -ArgumentList $argLine -Wait -PassThru
    exit $proc.ExitCode
}

$script = Join-Path $root 'fvcodex-patch.js'
$common = @("--root=$root", "--mode=$Mode")
if ($BaseUrl) { $common += "--base-url=$BaseUrl" }
if ($ApiKey) { $common += "--api-key=$ApiKey" }
if ($NoLaunch) { $common += '--no-launch' }
if ($NoVSCode) { $common += '--no-vscode' }
if ($Doctor) { $common += '--doctor' }

& node $script @common
exit $LASTEXITCODE
