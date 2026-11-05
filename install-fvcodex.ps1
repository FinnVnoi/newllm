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
    [string]$Profile = '',
    [switch]$Reinstall,
    [switch]$Update
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$InstallerVersion = '2.1.0'
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

function Get-FVCodexInstallInfo {
    $statePath = Join-Path $env:APPDATA 'FVCodex\install-state.json'
    $portablePath = Join-Path $env:LOCALAPPDATA 'FVCodex\portable'
    $profilePath = Join-Path $env:LOCALAPPDATA 'FVCodex\profile'
    $oaicPath = Join-Path $env:APPDATA 'oaic-usage\config.json'
    $state = $null
    if (Test-Path -LiteralPath $statePath -PathType Leaf) {
        try { $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json } catch { $state = $null }
    }
    $components = New-Object System.Collections.Generic.List[string]
    if (Test-Path -LiteralPath $portablePath -PathType Container) { [void]$components.Add('FVCodex portable desktop') }
    if (Test-Path -LiteralPath $profilePath -PathType Container) { [void]$components.Add('FVCodex isolated profile') }
    if (Test-Path -LiteralPath $oaicPath -PathType Leaf) { [void]$components.Add('OAIC/FVCodex shared configuration') }
    $vsBackups = @(Get-ChildItem (Join-Path $env:USERPROFILE '.vscode\extensions') -Filter '*.codex-unblock.bak' -Recurse -File -ErrorAction SilentlyContinue)
    if ($vsBackups.Count -gt 0) { [void]$components.Add('VS Code Codex patch (' + $vsBackups.Count + ' backup file(s))') }
    if ($null -ne $state -and $state.PSObject.Properties.Name -contains 'mode') { [void]$components.Add('Codex endpoint configuration (' + [string]$state.mode + ')') }
    [pscustomobject]@{
        Detected = ($components.Count -gt 0)
        Version = if ($null -ne $state -and $state.PSObject.Properties.Name -contains 'installerVersion') { [string]$state.installerVersion } else { 'legacy/unknown' }
        IsOld = ($null -eq $state -or $state.PSObject.Properties.Name -notcontains 'installerVersion' -or [string]$state.installerVersion -ne $InstallerVersion)
        State = $state
        Components = @($components)
        StatePath = $statePath
    }
}

function Show-FVCodexInstallInfo($info) {
    Write-Host ''
    Write-Host 'Existing FVCodex installation detected:' -ForegroundColor Yellow
    Write-Host ('  Installer version: ' + $info.Version)
    Write-Host ('  Status: ' + $(if ($info.IsOld) { 'older installation / update available' } else { 'current installer version' })) -ForegroundColor $(if ($info.IsOld) { 'Yellow' } else { 'Green' })
    foreach ($component in $info.Components) { Write-Host ('  - ' + $component) }
    if ($info.State -and $info.State.PSObject.Properties.Name -contains 'sourceVersion') {
        Write-Host ('  Source Codex version: ' + [string]$info.State.sourceVersion)
    }
}

if (-not $Doctor -and -not $NonInteractive) {
    Write-Host 'Select language / Chon ngon ngu:' -ForegroundColor Cyan
    Write-Host '  1. Tieng Viet'
    Write-Host '  2. English'
    $language = Read-Host 'Language [1]'
    if ($language -notin @('', '1', '2')) { throw 'Language must be 1 or 2.' }

    $existingInstall = Get-FVCodexInstallInfo
    $installAction = 'new'
    if ($existingInstall.Detected) {
        Show-FVCodexInstallInfo $existingInstall
        Write-Host ''
        Write-Host 'Choose installation action:' -ForegroundColor Cyan
        Write-Host '  1. Reinstall (rebuild/reset the selected FVCodex components)'
        Write-Host '  2. Update (keep the installation, refresh FVCodex, and edit configuration)'
        $actionChoice = Read-Host 'Action [2]'
        if ($actionChoice -eq '1' -or $Reinstall) { $installAction = 'reinstall' }
        elseif ($actionChoice -in @('', '2') -or $Update) { $installAction = 'update' }
        else { throw 'Action must be 1 (reinstall) or 2 (update).' }
    }
    if ($installAction -eq 'update') { $Update = $true; $Reinstall = $false }
    elseif ($installAction -eq 'reinstall') { $Reinstall = $true; $Update = $false }
    if ($existingInstall.Detected -and $existingInstall.State) {
        if (-not $ConfigMode -and $existingInstall.State.PSObject.Properties.Name -contains 'configMode') { $ConfigMode = [string]$existingInstall.State.configMode }
        if (-not $Profile -and $existingInstall.State.PSObject.Properties.Name -contains 'profile' -and [string]$existingInstall.State.profile -in @('shared','isolated')) { $Profile = [string]$existingInstall.State.profile }
        if (-not $BaseUrl -and $existingInstall.State.PSObject.Properties.Name -contains 'baseUrl') { $BaseUrl = [string]$existingInstall.State.baseUrl }
    }
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

if (-not $ApiKey) {
    $savedApiKey = [Environment]::GetEnvironmentVariable('CODEX_API_KEY', 'User')
    if ($savedApiKey) { $ApiKey = $savedApiKey }
}

function ConvertTo-EndpointDisplay([string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value)) { return 'https://codex.finnvnoi.top/backend-api/codex' }
    $trimmed = $Value.Trim().TrimEnd('/')
    if ($trimmed -match '/backend-api/codex$') { return $trimmed }
    return $trimmed + '/backend-api/codex'
}

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
    if ($Reinstall) { $argLine += ' -Reinstall' }
    if ($Update) { $argLine += ' -Update' }
    $proc = Start-Process powershell.exe -Verb RunAs -ArgumentList $argLine -Wait -PassThru
    exit $proc.ExitCode
}

$script = Join-Path $root 'fvcodex-patch.js'
$common = @("--root=$root", "--mode=$Mode", "--profile=$Profile", "--config-mode=$ConfigMode")
$common += "--installer-version=$InstallerVersion"
if ($Update) { $common += '--install-action=update' }
elseif ($Reinstall) { $common += '--install-action=reinstall' }
else { $common += '--install-action=install' }
if ($BaseUrl) { $common += "--base-url=$BaseUrl" }
if ($ApiKey) { $common += "--api-key=$ApiKey" }
if ($NoLaunch) { $common += '--no-launch' }
if ($NoVSCode) { $common += '--no-vscode' }
if ($Doctor) { $common += '--doctor' }

if (-not $Doctor -and -not $NonInteractive) {
    $baseDefault = ConvertTo-EndpointDisplay $BaseUrl
    Write-Host 'The endpoint path is included. You may enter a full custom endpoint URL.' -ForegroundColor DarkGray
    $baseInput = Read-Host "Endpoint URL [$baseDefault]"
    if ($baseInput) { $BaseUrl = $baseInput } else { $BaseUrl = $baseDefault }
    $keyInput = Read-Host ('API key' + $(if ($ApiKey) { ' [press Enter to keep existing]' } else { '' }))
    if ($keyInput) { $ApiKey = $keyInput }
    $modelInput = Read-Host 'Model [gpt-5.6-sol]'
    $model = if ($modelInput) { $modelInput } else { 'gpt-5.6-sol' }
    $effortInput = Read-Host 'Reasoning effort [xhigh]'
    $effort = if ($effortInput) { $effortInput } else { 'xhigh' }
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
