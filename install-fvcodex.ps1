[CmdletBinding()]
param(
    [ValidateSet('portable','direct')]
    [string]$Mode = 'portable',
    [string]$BaseUrl = '',
    [string]$ApiKey = '',
    [switch]$NoLaunch,
    [switch]$NoVSCode,
    [switch]$Doctor,
    [switch]$NonInteractive,
    [ValidateSet('account','custom-endpoint')]
    [string]$ConfigMode = '',
    [ValidateSet('shared','isolated')]
    [string]$Profile = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
    throw 'Node.js is required. Install Node.js, then run this installer again.'
}

function Read-Choice([string]$Label, [string]$Default, [string[]]$Allowed) {
    $v = Read-Host "$Label [$Default]"
    if ([string]::IsNullOrWhiteSpace($v)) { return $Default }
    $v = $v.Trim().ToLowerInvariant()
    if ($Allowed -notcontains $v) { throw "Invalid choice: $v" }
    return $v
}

if (-not $Doctor -and -not $NonInteractive) {
    Write-Host 'Select language / Chon ngon ngu:' -ForegroundColor Cyan
    Write-Host '  1. Tieng Viet'
    Write-Host '  2. English'
    $language = Read-Host 'Language [1]'
    if ($language -notin @('', '1', '2')) { throw 'Language must be 1 or 2.' }
    if (-not $ConfigMode) {
        Write-Host ''
        Write-Host 'Select FVCodex configuration mode:' -ForegroundColor Cyan
        Write-Host '  1. custom-endpoint'
        Write-Host '  2. account (custom endpoint with native/account-shaped config)'
        $choice = Read-Host 'Mode [2]'
        $ConfigMode = if ($choice -eq '1') { 'custom-endpoint' } else { 'account' }
    }
    if (-not $Profile) {
        $Profile = 'shared'
        if ($ConfigMode -eq 'account') {
            Write-Host ''
            Write-Host 'FVCodex account mode can share or isolate history/config from original Codex.' -ForegroundColor Cyan
            $Profile = Read-Choice 'Profile: shared or isolated' 'shared' @('shared','isolated')
        }
    }
    if (-not $NoVSCode) {
        $vsc = Read-Host 'Patch VS Code Codex extension too? [y/N]'
        if ($vsc -notmatch '^(y|yes)$') { $NoVSCode = $true }
    }
}
if (-not $ConfigMode) { $ConfigMode = 'account' }
if (-not $Profile) { $Profile = 'shared' }

function Test-Admin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if ($Mode -eq 'direct' -and -not $Doctor -and -not (Test-Admin)) {
    $argLine = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -Mode direct -ConfigMode {1} -Profile {2}' -f $PSCommandPath, $ConfigMode, $Profile
    if ($BaseUrl) { $argLine += ' -BaseUrl "{0}"' -f $BaseUrl }
    if ($ApiKey) { $argLine += ' -ApiKey "{0}"' -f $ApiKey }
    if ($NoLaunch) { $argLine += ' -NoLaunch' }
    if ($NoVSCode) { $argLine += ' -NoVSCode' }
    if ($NonInteractive) { $argLine += ' -NonInteractive' }
    $proc = Start-Process powershell.exe -Verb RunAs -ArgumentList $argLine -Wait -PassThru
    exit $proc.ExitCode
}

$script = Join-Path $root 'fvcodex-patch.js'
$common = @("--root=$root", "--mode=$Mode", "--profile=$Profile", "--config-mode=$ConfigMode")
if ($BaseUrl) { $common += "--base-url=$BaseUrl" }
if ($ApiKey) { $common += "--api-key=$ApiKey" }
if ($NoLaunch) { $common += '--no-launch' }
if ($NoVSCode) { $common += '--no-vscode' }
if ($Doctor) { $common += '--doctor' }

if (-not $Doctor -and -not $NonInteractive) {
    if (-not $BaseUrl) { $BaseUrl = Read-Host 'Base URL [https://codex.finnvnoi.top]' ; if (-not $BaseUrl) { $BaseUrl = 'https://codex.finnvnoi.top' } }
    if (-not $ApiKey) { $ApiKey = Read-Host 'API key' }
    $model = Read-Host 'Model [gpt-5.6-sol]'
    if (-not $model) { $model = 'gpt-5.6-sol' }
    $effort = Read-Host 'Reasoning effort [xhigh]'
    if (-not $effort) { $effort = 'xhigh' }
    $env:CODEX_BASE_URL = $BaseUrl
    $env:OAIC_USAGE_BASE_URL = $BaseUrl
    $env:CODEX_API_KEY = $ApiKey
    $env:CODEX_MODEL = $model
    $env:CODEX_REASONING_EFFORT = $effort
    $configArgs = @("--root=$root", '--config', "--config-mode=$ConfigMode", "--profile=$Profile")
    if ($ConfigMode -eq 'account') { $configArgs += '--account' }
    if ($NoVSCode) { $configArgs += '--no-vscode' }
    & node $script @configArgs
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}

& node $script @common
exit $LASTEXITCODE
