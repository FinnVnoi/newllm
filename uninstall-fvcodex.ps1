[CmdletBinding()]
param(
    [switch]$DeleteConfig,
    [switch]$NoVSCode
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
    throw 'Node.js is required. Install Node.js, then run this uninstaller again.'
}

function Test-Admin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

$directState = Join-Path $env:APPDATA 'FVCodex\direct-state.json'
if ((Test-Path -LiteralPath $directState) -and -not (Test-Admin)) {
    $argLine = '-NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $PSCommandPath
    if ($DeleteConfig) { $argLine += ' -DeleteConfig' }
    if ($NoVSCode) { $argLine += ' -NoVSCode' }
    $proc = Start-Process powershell.exe -Verb RunAs -ArgumentList $argLine -Wait -PassThru
    exit $proc.ExitCode
}

$script = Join-Path $root 'fvcodex-patch.js'
$common = @("--root=$root", '--uninstall')
if ($DeleteConfig) { $common += '--delete-config' }
if ($NoVSCode) { $common += '--no-vscode' }

& node $script @common
exit $LASTEXITCODE
