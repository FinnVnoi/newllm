[CmdletBinding()]
param(
    [string]$BaseUrl = '',
    [string]$ApiKey = '',
    [string]$Model = '',
    [string]$Effort = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not (Get-Command node -ErrorAction SilentlyContinue)) { throw 'Node.js is required. Install Node.js first.' }

function Read-Default([string]$Label, [string]$Default) {
    $v = Read-Host "$Label [$Default]"
    if ([string]::IsNullOrWhiteSpace($v)) { return $Default }
    return $v.Trim()
}

$existingConfig = Join-Path $env:APPDATA 'oaic-usage\config.json'
$existingBase = 'https://codex.finnvnoi.top'
$existingKey = [Environment]::GetEnvironmentVariable('CODEX_API_KEY', 'User')
try {
    $c = Get-Content -LiteralPath $existingConfig -Raw | ConvertFrom-Json
    if ($c.baseUrl) { $existingBase = [string]$c.baseUrl }
    if (-not $existingKey -and $c.apiKey) { $existingKey = [string]$c.apiKey }
} catch { }

if (-not $BaseUrl) { $BaseUrl = Read-Default 'Base URL' $existingBase }
if (-not $Model) { $Model = Read-Default 'Model' 'gpt-5.6-sol' }
if (-not $Effort) { $Effort = Read-Default 'Reasoning effort' 'xhigh' }
if (-not $ApiKey) {
    $masked = if ($existingKey) { 'existing key' } else { 'empty' }
    $ApiKey = Read-Host "API key [$masked] (Enter keeps existing key)"
    if ([string]::IsNullOrWhiteSpace($ApiKey)) { $ApiKey = [string]$existingKey }
}

# Pass values through the child process environment rather than command-line arguments.
# This command configures the account/native-catalog flow. It does not create or
# modify the custom-endpoint model catalog.
$env:CODEX_BASE_URL = $BaseUrl
$env:OAIC_USAGE_BASE_URL = $BaseUrl
$env:CODEX_API_KEY = $ApiKey
$env:CODEX_MODEL = $Model
$env:CODEX_REASONING_EFFORT = $Effort
Write-Host 'Applying account/native-catalog configuration (not custom-endpoint)...' -ForegroundColor Cyan
& node (Join-Path $root 'fvcodex-patch.js') "--root=$root" '--config' '--account'
exit $LASTEXITCODE
