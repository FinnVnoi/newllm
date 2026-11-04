[CmdletBinding()]
param(
    [switch]$NonInteractive,
    [ValidateSet('account', 'custom-endpoint')]
    [string]$Mode,
    [switch]$FVCodex,
    [switch]$Doctor
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$DefaultEndpoint = 'https://codex.finnvnoi.top/backend-api/codex'
$DefaultModel = 'gpt-5.6-sol'
$DefaultEffort = 'xhigh'
$ApiKeyVariable = 'CODEX_API_KEY'
$TargetCatalogName = 'legacy_direct_model_catalog.json'
$StateFileName = 'codex_custom_endpoint_install_state.json'
$EnvironmentVariableNames = @(
    'CODEX_BASE_URL',
    'CODEX_API_KEY',
    'CODEX_MODEL',
    'CODEX_REASONING_EFFORT'
)
$Language = 'en'

function Ui([string]$English, [string]$Vietnamese) {
    if ($Language -eq 'vi') { return $Vietnamese }
    return $English
}

function Read-YesNo([string]$Prompt, [bool]$DefaultYes = $false) {
    $suffix = if ($DefaultYes) { '[Y/n]' } else { '[y/N]' }
    $answer = Read-Host ($Prompt + ' ' + $suffix)
    if ([string]::IsNullOrWhiteSpace($answer)) { return $DefaultYes }
    return $answer.Trim() -match '^(y|yes|1)$'
}

function Read-FVCodexProfile {
    Write-Host ''
    Write-Host (Ui 'FVCodex can share or isolate its history/configuration from the original Codex.' 'FVCodex co the dung chung hoac tach rieng lich su/cau hinh voi Codex goc.') -ForegroundColor Cyan
    $answer = Read-Host (Ui 'Profile: 1=shared, 2=isolated [1]' 'Ho so: 1=dung chung, 2=tach rieng [1]')
    if ([string]::IsNullOrWhiteSpace($answer) -or $answer.Trim() -eq '1') { return 'shared' }
    if ($answer.Trim() -eq '2') { return 'isolated' }
    throw (Ui 'Profile must be 1 (shared) or 2 (isolated).' 'Ho so phai la 1 (dung chung) hoac 2 (tach rieng).')
}

function Get-CodexHome {
    if (-not [string]::IsNullOrWhiteSpace($env:CODEX_HOME)) {
        return [IO.Path]::GetFullPath($env:CODEX_HOME)
    }

    $userProfile = [Environment]::GetFolderPath('UserProfile')
    return [IO.Path]::GetFullPath((Join-Path $userProfile '.codex'))
}

function ConvertTo-TomlBasicString {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Value
    )

    $escaped = $Value.Replace('\', '\\')
    $escaped = $escaped.Replace('"', '\"')
    $escaped = $escaped.Replace("`b", '\b')
    $escaped = $escaped.Replace("`t", '\t')
    $escaped = $escaped.Replace("`n", '\n')
    $escaped = $escaped.Replace("`f", '\f')
    $escaped = $escaped.Replace("`r", '\r')
    return '"' + $escaped + '"'
}

function Set-TopLevelTomlValue {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [object]$Lines,
        [Parameter(Mandatory = $true)]
        [string]$Key,
        [Parameter(Mandatory = $true)]
        [string]$EncodedValue
    )

    $tableStart = $Lines.Count
    for ($index = 0; $index -lt $Lines.Count; $index++) {
        if ($Lines[$index] -match '^\s*\[') {
            $tableStart = $index
            break
        }
    }

    $pattern = '^\s*' + [regex]::Escape($Key) + '\s*='
    $matchedIndexes = New-Object 'System.Collections.Generic.List[int]'
    for ($index = 0; $index -lt $tableStart; $index++) {
        if ($Lines[$index] -match $pattern) {
            [void]$matchedIndexes.Add($index)
        }
    }

    $newLine = $Key + ' = ' + $EncodedValue
    if ($matchedIndexes.Count -eq 0) {
        $Lines.Insert($tableStart, $newLine)
        return
    }

    $Lines[$matchedIndexes[0]] = $newLine
    for ($matchIndex = $matchedIndexes.Count - 1; $matchIndex -ge 1; $matchIndex--) {
        $Lines.RemoveAt($matchedIndexes[$matchIndex])
    }
}

function Set-TableTomlValue {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [object]$Lines,
        [Parameter(Mandatory = $true)]
        [string]$TableName,
        [Parameter(Mandatory = $true)]
        [string]$Key,
        [Parameter(Mandatory = $true)]
        [string]$EncodedValue
    )

    $tablePattern = '^\s*\[\s*' + [regex]::Escape($TableName) + '\s*\]\s*(?:#.*)?$'
    $tableStart = -1
    for ($index = 0; $index -lt $Lines.Count; $index++) {
        if ($Lines[$index] -match $tablePattern) {
            $tableStart = $index
            break
        }
    }

    if ($tableStart -lt 0) {
        if ($Lines.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace($Lines[$Lines.Count - 1])) {
            [void]$Lines.Add('')
        }
        [void]$Lines.Add('[' + $TableName + ']')
        [void]$Lines.Add($Key + ' = ' + $EncodedValue)
        return
    }

    $tableEnd = $Lines.Count
    for ($index = $tableStart + 1; $index -lt $Lines.Count; $index++) {
        if ($Lines[$index] -match '^\s*\[') {
            $tableEnd = $index
            break
        }
    }

    $pattern = '^\s*' + [regex]::Escape($Key) + '\s*='
    $matchedIndexes = New-Object 'System.Collections.Generic.List[int]'
    for ($index = $tableStart + 1; $index -lt $tableEnd; $index++) {
        if ($Lines[$index] -match $pattern) {
            [void]$matchedIndexes.Add($index)
        }
    }

    $newLine = $Key + ' = ' + $EncodedValue
    if ($matchedIndexes.Count -eq 0) {
        $Lines.Insert($tableEnd, $newLine)
        return
    }

    $Lines[$matchedIndexes[0]] = $newLine
    for ($matchIndex = $matchedIndexes.Count - 1; $matchIndex -ge 1; $matchIndex--) {
        $Lines.RemoveAt($matchedIndexes[$matchIndex])
    }
}

function Write-Utf8NoBomAtomic {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Content
    )

    $directory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        [void](New-Item -ItemType Directory -Path $directory -Force)
    }

    $temporaryPath = Join-Path $directory ('.' + [IO.Path]::GetFileName($Path) + '.' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        $encoding = New-Object Text.UTF8Encoding($false)
        [IO.File]::WriteAllText($temporaryPath, $Content, $encoding)
        Move-Item -LiteralPath $temporaryPath -Destination $Path -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath) {
            Remove-Item -LiteralPath $temporaryPath -Force
        }
    }
}

function Write-JsonAtomic {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        $Value
    )

    $json = $Value | ConvertTo-Json -Depth 12
    Write-Utf8NoBomAtomic -Path $Path -Content ($json + [Environment]::NewLine)
}

function Protect-TextForCurrentUser {
    param(
        [AllowEmptyString()]
        [string]$Text
    )

    $secureValue = ConvertTo-SecureString -String ('codex-install-state:' + $Text) -AsPlainText -Force
    return ConvertFrom-SecureString -SecureString $secureValue
}

function Get-ExistingApiKey {
    foreach ($target in @('User', 'Process', 'Machine')) {
        $value = [Environment]::GetEnvironmentVariable($ApiKeyVariable, $target)
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            return $value
        }
    }
    return $null
}

function Read-PlainValue {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Label,
        [Parameter(Mandatory = $true)]
        [string]$DefaultValue
    )

    $enteredValue = Read-Host ($Label + ' [' + $DefaultValue + ']')
    if ([string]::IsNullOrWhiteSpace($enteredValue)) {
        return $DefaultValue
    }
    return $enteredValue.Trim()
}

function Read-ApiKey {
    param(
        [AllowNull()]
        [string]$ExistingValue
    )

    if ($NonInteractive) {
        if ([string]::IsNullOrWhiteSpace($ExistingValue)) {
            throw 'CODEX_API_KEY is not set. Run without -NonInteractive and enter an API key.'
        }
        return $ExistingValue
    }

    $prompt = 'API key'
    if (-not [string]::IsNullOrWhiteSpace($ExistingValue)) {
        $prompt += ' [Enter = keep current CODEX_API_KEY]'
    }

    $secureInput = Read-Host $prompt -AsSecureString
    $enteredValue = (New-Object Net.NetworkCredential('', $secureInput)).Password
    if ([string]::IsNullOrWhiteSpace($enteredValue)) {
        if ([string]::IsNullOrWhiteSpace($ExistingValue)) {
            throw 'API key cannot be empty because CODEX_API_KEY is not currently set.'
        }
        return $ExistingValue
    }
    return $enteredValue.Trim()
}

function Read-InstallMode {
    if (-not [string]::IsNullOrWhiteSpace($Mode)) {
        return $Mode
    }

    Write-Host ''
    Write-Host 'Select installation mode:'
    Write-Host '  1. custom-endpoint - Use the current custom endpoint behavior without native login.'
    Write-Host '  2. account         - Use the native model catalog with a custom endpoint; login is not checked by the installer.'
    $selection = Read-Host 'Mode [1]'
    if ([string]::IsNullOrWhiteSpace($selection) -or $selection.Trim() -eq '1') {
        return 'custom-endpoint'
    }
    if ($selection.Trim() -eq '2') {
        return 'account'
    }
    throw 'Mode must be 1 (custom-endpoint) or 2 (account).'
}

function Remove-TopLevelTomlValue {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object]$Lines,
        [Parameter(Mandatory = $true)]
        [string]$Key
    )

    $tableStart = $Lines.Count
    for ($index = 0; $index -lt $Lines.Count; $index++) {
        if ($Lines[$index] -match '^\s*\[') {
            $tableStart = $index
            break
        }
    }

    $pattern = '^\s*' + [regex]::Escape($Key) + '\s*='
    for ($index = $tableStart - 1; $index -ge 0; $index--) {
        if ($Lines[$index] -match $pattern) {
            $Lines.RemoveAt($index)
        }
    }
}

function Remove-TomlTable {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object]$Lines,
        [Parameter(Mandatory = $true)]
        [string]$TableName
    )

    $tablePattern = '^\s*\[\s*' + [regex]::Escape($TableName) + '\s*\]\s*(?:#.*)?$'
    $tableStart = -1
    for ($index = 0; $index -lt $Lines.Count; $index++) {
        if ($Lines[$index] -match $tablePattern) {
            $tableStart = $index
            break
        }
    }
    if ($tableStart -lt 0) {
        return
    }

    $tableEnd = $Lines.Count
    for ($index = $tableStart + 1; $index -lt $Lines.Count; $index++) {
        if ($Lines[$index] -match '^\s*\[') {
            $tableEnd = $index
            break
        }
    }
    for ($index = $tableEnd - 1; $index -ge $tableStart; $index--) {
        $Lines.RemoveAt($index)
    }
    while ($tableStart -gt 0 -and [string]::IsNullOrWhiteSpace($Lines[$tableStart - 1])) {
        $Lines.RemoveAt($tableStart - 1)
        $tableStart--
    }
}

function Remove-TableTomlValue {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [object]$Lines,
        [Parameter(Mandatory = $true)]
        [string]$TableName,
        [Parameter(Mandatory = $true)]
        [string]$Key
    )

    $tablePattern = '^\s*\[\s*' + [regex]::Escape($TableName) + '\s*\]\s*(?:#.*)?$'
    $tableStart = -1
    for ($index = 0; $index -lt $Lines.Count; $index++) {
        if ($Lines[$index] -match $tablePattern) {
            $tableStart = $index
            break
        }
    }
    if ($tableStart -lt 0) {
        return
    }

    $tableEnd = $Lines.Count
    for ($index = $tableStart + 1; $index -lt $Lines.Count; $index++) {
        if ($Lines[$index] -match '^\s*\[') {
            $tableEnd = $index
            break
        }
    }

    $pattern = '^\s*' + [regex]::Escape($Key) + '\s*='
    for ($index = $tableEnd - 1; $index -gt $tableStart; $index--) {
        if ($Lines[$index] -match $pattern) {
            $Lines.RemoveAt($index)
        }
    }
}

function Assert-Endpoint {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Endpoint
    )

    $uri = $null
    if (-not [Uri]::TryCreate($Endpoint, [UriKind]::Absolute, [ref]$uri)) {
        throw 'Endpoint must be an absolute HTTP or HTTPS URL.'
    }
    if ($uri.Scheme -notin @('http', 'https')) {
        throw 'Endpoint must use HTTP or HTTPS.'
    }
}

function Assert-Catalog {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    try {
        $catalog = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    }
    catch {
        throw "Catalog is not valid JSON: $Path"
    }

    if ($null -eq $catalog.models -or @($catalog.models).Count -eq 0) {
        throw "Catalog does not contain a non-empty models list: $Path"
    }
}

function Test-CatalogContainsModel {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [string]$Model
    )

    $catalog = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    return $null -ne (@($catalog.models) | Where-Object {
        [string]$_.slug -eq $Model
    } | Select-Object -First 1)
}

function Add-CustomCatalogModel {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [string]$Model,
        [Parameter(Mandatory = $true)]
        [string]$DisplayName
    )

    $catalog = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    if ($null -ne (@($catalog.models) | Where-Object {
        [string]$_.slug -eq $Model
    } | Select-Object -First 1)) {
        return
    }

    $template = @($catalog.models) | Where-Object {
        [string]$_.slug -eq $DefaultModel
    } | Select-Object -First 1
    if ($null -eq $template) {
        $template = @($catalog.models) | Select-Object -First 1
    }

    $customModel = $template | ConvertTo-Json -Depth 100 | ConvertFrom-Json
    $customModel.slug = $Model
    $customModel.display_name = $DisplayName
    $customModel.description = 'Custom model configured by the installer.'
    $customModel.availability_nux = $null
    $customModel.upgrade = $null

    $priorities = @($catalog.models) |
        ForEach-Object { $_.priority } |
        Where-Object { $null -ne $_ } |
        ForEach-Object { [int]$_ }
    $customModel.priority = if ($priorities.Count -eq 0) {
        1
    }
    else {
        ($priorities | Measure-Object -Maximum).Maximum + 1
    }

    $catalog.models = @($catalog.models) + @($customModel)
    Write-JsonAtomic -Path $Path -Value $catalog
}

function Get-Sha256 {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

function Broadcast-EnvironmentChange {
    if (-not ('CodexEnvironmentBroadcast' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class CodexEnvironmentBroadcast
{
    [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Auto)]
    public static extern IntPtr SendMessageTimeout(
        IntPtr hWnd,
        uint Msg,
        UIntPtr wParam,
        string lParam,
        uint fuFlags,
        uint uTimeout,
        out UIntPtr lpdwResult);
}
'@
    }

    $result = [UIntPtr]::Zero
    [void][CodexEnvironmentBroadcast]::SendMessageTimeout(
        [IntPtr]0xffff,
        0x001A,
        [UIntPtr]::Zero,
        'Environment',
        0x0002,
        5000,
        [ref]$result
    )
}

function Get-RunningCodexProcesses {
    return @(Get-Process -Name ChatGPT,Codex -ErrorAction SilentlyContinue)
}

function Stop-CodexBeforeInstall {
    # Force array semantics: PowerShell unwraps a single pipeline result into
    # one process object, which has no .Count property under StrictMode.
    $running = @(Get-RunningCodexProcesses)
    if ($running.Count -eq 0) {
        Write-Host 'Codex is not running. Continuing installation.' -ForegroundColor Green
        return
    }

    Write-Host ''
    Write-Host ('Codex is still running (' + $running.Count + ' process(es)).') -ForegroundColor Yellow
    Write-Host 'The installation will close all Codex processes before changing files.' -ForegroundColor Yellow
    if (-not $NonInteractive) {
        Write-Host 'Press any key to begin installation and close Codex...' -ForegroundColor Yellow
        [void][Console]::ReadKey($true)
    }
    Write-Host 'Closing Codex...'
    $running | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
}

$codexHome = Get-CodexHome
$configPath = Join-Path $codexHome 'config.toml'
$targetCatalogPath = Join-Path $codexHome $TargetCatalogName
$statePath = Join-Path $codexHome $StateFileName
$scriptDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
$bundledCatalogPath = Join-Path $scriptDirectory $TargetCatalogName
$legacyFallbackPath = Join-Path $codexHome 'legacy-direct-model-catalog.json'

if ($NonInteractive -and -not $Doctor -and -not $PSBoundParameters.ContainsKey('Mode')) {
    throw '-NonInteractive requires -Mode account or -Mode custom-endpoint.'
}
if ($Doctor) {
    $doctorState = $null
    if (Test-Path -LiteralPath $statePath -PathType Leaf) {
        $doctorState = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
    }
    if (-not $PSBoundParameters.ContainsKey('Mode')) {
        $savedMode = if ($null -ne $doctorState -and $doctorState.PSObject.Properties.Name -contains 'mode') { [string]$doctorState.mode } else { $null }
        $Mode = if ($savedMode -in @('account', 'custom-endpoint')) { $savedMode } else { 'custom-endpoint' }
    }
    else {
        $Mode = [string]$Mode
    }

    $doctorOk = $true
    Write-Host ('Mode: ' + $Mode)
    if (Test-Path -LiteralPath $configPath -PathType Leaf) {
        $doctorConfig = Get-Content -LiteralPath $configPath -Raw
        if ($Mode -eq 'account') {
            $accountProvider = [regex]::Match($doctorConfig, '(?ms)^\s*\[model_providers\.codex\]\s*(?:#.*)?\r?\n(?<body>.*?)(?=^\s*\[|\z)')
            $configOk = $doctorConfig -cmatch '(?m)^\s*model_provider\s*=\s*"codex"' -and
                $accountProvider.Success -and
                $accountProvider.Groups['body'].Value -cmatch '(?m)^\s*name\s*=\s*"openai"' -and
                $accountProvider.Groups['body'].Value -cmatch '(?m)^\s*base_url\s*=\s*"https?://' -and
                $accountProvider.Groups['body'].Value -cmatch '(?m)^\s*env_key\s*=\s*"CODEX_API_KEY"' -and
                $accountProvider.Groups['body'].Value -cmatch '(?m)^\s*wire_api\s*=\s*"responses"' -and
                $accountProvider.Groups['body'].Value -cmatch '(?m)^\s*supports_standalone_web_search\s*=\s*true' -and
                $accountProvider.Groups['body'].Value -cmatch '(?m)^\s*supports_websockets\s*=\s*false' -and
                $accountProvider.Groups['body'].Value -cmatch '(?m)^\s*requires_openai_auth\s*=\s*true' -and
                $doctorConfig -cnotmatch '(?m)^\s*service_tier\s*=' -and
                $doctorConfig -cnotmatch '(?m)^\s*model_catalog_json\s*='
        }
        else {
            $customProvider = [regex]::Match($doctorConfig, '(?ms)^\s*\[model_providers\.codex\]\s*(?:#.*)?\r?\n(?<body>.*?)(?=^\s*\[|\z)')
            $configOk = $doctorConfig -match '(?m)^\s*model_provider\s*=\s*"codex"' -and
                $customProvider.Success -and
                $customProvider.Groups['body'].Value -match '(?m)^\s*name\s*=\s*"openai"' -and
                $customProvider.Groups['body'].Value -match '(?m)^\s*supports_standalone_web_search\s*=\s*true' -and
                $doctorConfig -match '(?m)^\s*model_catalog_json\s*=' -and
                $doctorConfig -match '(?m)^\s*env_key\s*=\s*"CODEX_API_KEY"'
        }
        if ($configOk) {
            Write-Host 'Codex provider config: configured'
        }
        else {
            Write-Host 'Codex provider config: missing or inconsistent'
            $doctorOk = $false
        }
    }
    else {
        Write-Host 'Codex provider config: missing'
        $doctorOk = $false
    }
    foreach ($variableName in @('CODEX_BASE_URL', 'CODEX_API_KEY', 'CODEX_MODEL', 'CODEX_REASONING_EFFORT')) {
        $value = [Environment]::GetEnvironmentVariable($variableName, 'Process')
        if ([string]::IsNullOrWhiteSpace($value)) {
            $value = [Environment]::GetEnvironmentVariable($variableName, 'User')
        }
        if ([string]::IsNullOrWhiteSpace($value)) {
            Write-Host ($variableName + ': missing')
            $doctorOk = $false
        }
        elseif ($variableName -eq 'CODEX_API_KEY') {
            Write-Host ($variableName + ': loaded (' + $value.Length + ' characters; value hidden)')
        }
        else {
            Write-Host ($variableName + ': loaded')
        }
    }
    if ($doctorOk) {
        Write-Host 'Diagnosis: mode, environment, and Codex config are aligned.'
        Write-Host 'If the endpoint still reports invalid_api_key, close and reopen Codex, then restart your device if needed.'
        exit 0
    }
    Write-Host 'Diagnosis: fix the reported issue, then rerun this doctor command.'
    exit 1
}

if (-not $NonInteractive -and -not $Doctor) {
    Write-Host 'Select language / Chon ngon ngu:' -ForegroundColor Cyan
    Write-Host '  1. Tieng Viet'
    Write-Host '  2. English'
    $languageChoice = Read-Host 'Language [2]'
    if ($languageChoice -eq '1') { $Language = 'vi' }
    elseif ($languageChoice -notin @('', '2')) { throw 'Language must be 1 or 2.' }
}
$Mode = Read-InstallMode
$InstallFVCodex = $false
$FVCodexProfile = 'shared'
$PatchFVCodexVSCode = $false
if ($FVCodex -and $Mode -ne 'account') {
    throw '-FVCodex requires -Mode account. FVCodex is installed after account-mode configuration.'
}
if ($Mode -eq 'account' -and $FVCodex) {
    $InstallFVCodex = $true
    if (-not $NonInteractive) {
        $FVCodexProfile = Read-FVCodexProfile
        $PatchFVCodexVSCode = Read-YesNo 'Patch the VS Code Codex extension too?'
    }
}
elseif ($Mode -eq 'account' -and -not $NonInteractive) {
    Write-Host ''
    Write-Host 'FVCodex is a portable Codex desktop build with enhanced OpenAI-compatible endpoint support.'
    Write-Host 'It does not modify or replace the original Codex app.'
    $InstallFVCodex = Read-YesNo 'Would you like to install and configure FVCodex as well?'
    if ($InstallFVCodex) {
        $FVCodexProfile = Read-FVCodexProfile
    }
    $PatchFVCodexVSCode = Read-YesNo 'Patch the VS Code Codex extension too?'
}
if ($InstallFVCodex -and $NonInteractive) { $FVCodexProfile = 'shared' }
if ($Mode -eq 'account') {
    $ProviderId = 'codex'
    $ProviderName = 'openai'
}
else {
    $ProviderId = 'codex'
    $ProviderName = 'openai'
}
$ProviderWebsocketsValue = if ($Mode -eq 'account') { 'false' } else { $null }
$ProviderRequiresAuthValue = if ($Mode -eq 'account') { 'true' } else { $null }

$catalogSourcePath = $null
if ($Mode -eq 'custom-endpoint') {
    if (Test-Path -LiteralPath $bundledCatalogPath -PathType Leaf) {
        $catalogSourcePath = $bundledCatalogPath
    }
    elseif (Test-Path -LiteralPath $legacyFallbackPath -PathType Leaf) {
        $catalogSourcePath = $legacyFallbackPath
    }
    else {
        throw "Missing $TargetCatalogName beside the installer, and no legacy-direct-model-catalog.json fallback exists in $codexHome."
    }

    Assert-Catalog -Path $catalogSourcePath
}

$existingApiKey = Get-ExistingApiKey
if ($NonInteractive) {
    $endpoint = $DefaultEndpoint
    $apiKey = Read-ApiKey -ExistingValue $existingApiKey
    $model = $DefaultModel
    $modelDisplayName = $null
    $effort = $DefaultEffort
}
else {
    $endpoint = Read-PlainValue -Label 'Endpoint' -DefaultValue $DefaultEndpoint
    $apiKey = Read-ApiKey -ExistingValue $existingApiKey
    $model = Read-PlainValue -Label 'Model' -DefaultValue $DefaultModel
    if ($Mode -eq 'custom-endpoint' -and (Test-CatalogContainsModel -Path $catalogSourcePath -Model $model)) {
        $modelDisplayName = $null
    }
    elseif ($Mode -eq 'account') {
        $modelDisplayName = $null
    }
    else {
        $modelDisplayName = Read-PlainValue -Label 'Model display name' -DefaultValue $model
    }
    $effort = Read-PlainValue -Label 'Reasoning effort' -DefaultValue $DefaultEffort
}

Assert-Endpoint -Endpoint $endpoint
if ([string]::IsNullOrWhiteSpace($model)) {
    throw 'Model cannot be empty.'
}
if ($null -ne $modelDisplayName -and [string]::IsNullOrWhiteSpace($modelDisplayName)) {
    throw 'Model display name cannot be empty.'
}
if ([string]::IsNullOrWhiteSpace($effort)) {
    throw 'Reasoning effort cannot be empty.'
}

if ($Mode -eq 'custom-endpoint') {
    Stop-CodexBeforeInstall
}

if (-not (Test-Path -LiteralPath $codexHome -PathType Container)) {
    [void](New-Item -ItemType Directory -Path $codexHome -Force)
}

if (Test-Path -LiteralPath $statePath -PathType Leaf) {
    $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
    if ($state.schemaVersion -ne 1) {
        throw "Unsupported install state schema in $statePath."
    }
    $backupFolderName = [string]$state.backupFolderName
    $backupDirectory = Join-Path $codexHome $backupFolderName
    if (-not (Test-Path -LiteralPath $backupDirectory -PathType Container)) {
        throw "The existing install state references a missing backup directory: $backupDirectory"
    }
}
else {
    $backupFolderName = 'codex_custom_endpoint_backup_' + (Get-Date -Format 'yyyyMMdd_HHmmss') + '_' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $backupDirectory = Join-Path $codexHome $backupFolderName
    [void](New-Item -ItemType Directory -Path $backupDirectory)

    $configExisted = Test-Path -LiteralPath $configPath -PathType Leaf
    if ($configExisted) {
        Copy-Item -LiteralPath $configPath -Destination (Join-Path $backupDirectory 'config.toml.original')
    }

    $catalogExisted = Test-Path -LiteralPath $targetCatalogPath -PathType Leaf
    if ($catalogExisted) {
        Copy-Item -LiteralPath $targetCatalogPath -Destination (Join-Path $backupDirectory ($TargetCatalogName + '.original'))
    }

    $environmentState = @()
    foreach ($variableName in $EnvironmentVariableNames) {
        $previousValue = [Environment]::GetEnvironmentVariable($variableName, 'User')
        $existed = $null -ne $previousValue
        $protectedValue = $null
        if ($existed) {
            $protectedValue = Protect-TextForCurrentUser -Text $previousValue
        }

        $environmentState += [ordered]@{
            name = $variableName
            existed = $existed
            protectedValue = $protectedValue
        }
    }

    $state = [ordered]@{
        schemaVersion = 1
        createdAt = (Get-Date).ToString('o')
        lastInstalledAt = $null
        codexHome = $codexHome
        backupFolderName = $backupFolderName
        configExisted = $configExisted
        catalogExisted = $catalogExisted
        targetCatalogName = $TargetCatalogName
        environment = $environmentState
        installedConfigSha256 = $null
        installedCatalogSha256 = $null
        mode = $Mode
    }
    Write-JsonAtomic -Path $statePath -Value $state
}

$configLines = New-Object 'System.Collections.Generic.List[string]'
if (Test-Path -LiteralPath $configPath -PathType Leaf) {
    foreach ($line in [IO.File]::ReadAllLines($configPath)) {
        [void]$configLines.Add($line)
    }
}
Set-TopLevelTomlValue -Lines $configLines -Key 'model' -EncodedValue (ConvertTo-TomlBasicString $model)
Set-TopLevelTomlValue -Lines $configLines -Key 'model_reasoning_effort' -EncodedValue (ConvertTo-TomlBasicString $effort)
Set-TopLevelTomlValue -Lines $configLines -Key 'model_provider' -EncodedValue (ConvertTo-TomlBasicString $ProviderId)
Remove-TopLevelTomlValue -Lines $configLines -Key 'service_tier'

$providerTable = 'model_providers.' + $ProviderId
if ($Mode -eq 'account') {
    Remove-TomlTable -Lines $configLines -TableName 'model_providers.CODEX'
}
else {
    Remove-TomlTable -Lines $configLines -TableName 'model_providers.CODEX'
}
Set-TableTomlValue -Lines $configLines -TableName $providerTable -Key 'name' -EncodedValue (ConvertTo-TomlBasicString $ProviderName)
Set-TableTomlValue -Lines $configLines -TableName $providerTable -Key 'base_url' -EncodedValue (ConvertTo-TomlBasicString $endpoint)
Set-TableTomlValue -Lines $configLines -TableName $providerTable -Key 'env_key' -EncodedValue (ConvertTo-TomlBasicString $ApiKeyVariable)
Set-TableTomlValue -Lines $configLines -TableName $providerTable -Key 'wire_api' -EncodedValue (ConvertTo-TomlBasicString 'responses')
Set-TableTomlValue -Lines $configLines -TableName $providerTable -Key 'supports_standalone_web_search' -EncodedValue 'true'
if ($Mode -eq 'account') {
    Remove-TopLevelTomlValue -Lines $configLines -Key 'model_catalog_json'
    Set-TableTomlValue -Lines $configLines -TableName $providerTable -Key 'supports_websockets' -EncodedValue $ProviderWebsocketsValue
    Set-TableTomlValue -Lines $configLines -TableName $providerTable -Key 'requires_openai_auth' -EncodedValue $ProviderRequiresAuthValue
}
else {
    Set-TopLevelTomlValue -Lines $configLines -Key 'model_catalog_json' -EncodedValue (ConvertTo-TomlBasicString $targetCatalogPath)
    Remove-TableTomlValue -Lines $configLines -TableName $providerTable -Key 'supports_websockets'
    Remove-TableTomlValue -Lines $configLines -TableName $providerTable -Key 'requires_openai_auth'
}

$configContent = [string]::Join([Environment]::NewLine, $configLines)
if ($configLines.Count -gt 0) {
    $configContent += [Environment]::NewLine
}
Write-Utf8NoBomAtomic -Path $configPath -Content $configContent

$catalogTemporaryPath = $null
if ($Mode -eq 'custom-endpoint') {
    $catalogTemporaryPath = Join-Path $codexHome ('.' + $TargetCatalogName + '.' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        Copy-Item -LiteralPath $catalogSourcePath -Destination $catalogTemporaryPath -Force
        if ($null -ne $modelDisplayName) {
            Add-CustomCatalogModel -Path $catalogTemporaryPath -Model $model -DisplayName $modelDisplayName
        }
        Assert-Catalog -Path $catalogTemporaryPath
        Move-Item -LiteralPath $catalogTemporaryPath -Destination $targetCatalogPath -Force
    }
    finally {
        if (Test-Path -LiteralPath $catalogTemporaryPath) {
            Remove-Item -LiteralPath $catalogTemporaryPath -Force
        }
    }
}

$environmentValues = [ordered]@{
    CODEX_BASE_URL = $endpoint
    CODEX_API_KEY = $apiKey
    CODEX_MODEL = $model
    CODEX_REASONING_EFFORT = $effort
}
foreach ($entry in $environmentValues.GetEnumerator()) {
    [Environment]::SetEnvironmentVariable($entry.Key, [string]$entry.Value, 'User')
    [Environment]::SetEnvironmentVariable($entry.Key, [string]$entry.Value, 'Process')
}
Broadcast-EnvironmentChange

function Patch-VsCodeForAccount {
    param(
        [Parameter(Mandatory = $true)][string]$FVCodexScript
    )

    Write-Host ''
    Write-Host 'Patching the VS Code Codex extension for account mode...' -ForegroundColor Cyan
    & node $FVCodexScript "--root=$scriptDirectory" '--vscode-patch'
    if ($LASTEXITCODE -ne 0) {
        throw "VS Code Codex extension patch failed with exit code $LASTEXITCODE."
    }
}

function Ensure-CodexMsixInstalled {
    param(
        [Parameter(Mandatory = $true)][string]$FVCodexScript
    )

    $probe = & node $FVCodexScript "--root=$scriptDirectory" '--doctor' 2>&1 | Out-String
    if ($probe -match 'MSIX:\s*(?<path>[^\r\n]+)' -and $Matches.path.Trim() -and $Matches.path.Trim() -ne 'khong thay') {
        return
    }

    Write-Host ''
    Write-Host 'Codex desktop (MSIX) is not installed, so FVCodex cannot be built yet.' -ForegroundColor Yellow
    if ($NonInteractive) {
        throw 'Codex desktop MSIX is not installed. Install Codex from Microsoft Store, then run this installer again.'
    }

    $choice = Read-Host 'Try to install the official Codex desktop app automatically with winget? [Y/n]'
    if ($choice -match '^(|y|yes)$') {
        Write-Host 'Installing official Codex desktop app from Microsoft Store via winget...' -ForegroundColor Cyan
        & winget install --id 9PLM9XGG6VKS --source msstore --accept-source-agreements --accept-package-agreements --silent
        if ($LASTEXITCODE -ne 0) {
            Write-Host 'winget installation did not complete. Opening Microsoft Store instead...' -ForegroundColor Yellow
            Start-Process 'ms-windows-store://pdp/?PFN=OpenAI.Codex_2p2nqsd0c76g0' | Out-Null
        }
    }
    else {
        Start-Process 'ms-windows-store://pdp/?PFN=OpenAI.Codex_2p2nqsd0c76g0' | Out-Null
    }

    Write-Host 'Install the official Codex desktop app in Microsoft Store, then return here.' -ForegroundColor Cyan
    [void](Read-Host 'Press Enter after the installation has completed')

    $probe = & node $FVCodexScript "--root=$scriptDirectory" '--doctor' 2>&1 | Out-String
    if ($probe -notmatch 'MSIX:\s*(?<path>[^\r\n]+)' -or [string]::IsNullOrWhiteSpace($Matches.path) -or $Matches.path.Trim() -eq 'khong thay') {
        throw 'Codex desktop MSIX was still not detected. Install it from Microsoft Store and run the installer again.'
    }
}

function Install-FVCodexPortable {
    param(
        [Parameter(Mandatory = $true)][string]$BaseUrl,
        [Parameter(Mandatory = $true)][string]$ApiKey,
        [Parameter(Mandatory = $true)][string]$Model,
        [Parameter(Mandatory = $true)][string]$Effort,
        [Parameter(Mandatory = $true)][ValidateSet('shared','isolated')][string]$Profile
    )

    $fvcodexScript = Join-Path $scriptDirectory 'fvcodex-patch.js'
    if (-not (Test-Path -LiteralPath $fvcodexScript -PathType Leaf)) {
        throw "FVCodex installer is missing: $fvcodexScript"
    }

    Ensure-CodexMsixInstalled -FVCodexScript $fvcodexScript
    Stop-CodexBeforeInstall

    $env:CODEX_BASE_URL = $BaseUrl
    $env:OAIC_USAGE_BASE_URL = $BaseUrl
    $env:CODEX_API_KEY = $ApiKey
    $env:CODEX_MODEL = $Model
    $env:CODEX_REASONING_EFFORT = $Effort

    if ($Profile -eq 'isolated') {
        Write-Host 'Preparing the isolated FVCodex account-shaped profile...' -ForegroundColor Cyan
        & node $fvcodexScript "--root=$scriptDirectory" '--config' '--account' '--no-vscode' "--profile=$Profile" '--config-mode=account'
        if ($LASTEXITCODE -ne 0) {
            throw "FVCodex isolated profile configuration failed with exit code $LASTEXITCODE."
        }
    }

    Write-Host ''
    Write-Host 'Installing FVCodex portable build...' -ForegroundColor Cyan
    # Apply the user's single VS Code choice to the FVCodex build as well.
    $profileArg = "--profile=$Profile"
    $vsArg = if ($PatchFVCodexVSCode) { @() } else { @('--no-vscode') }
    & node $fvcodexScript "--root=$scriptDirectory" '--mode=portable' '--no-launch' $vsArg $profileArg '--config-mode=account' '--account'
    if ($LASTEXITCODE -ne 0) {
        throw "FVCodex installation failed with exit code $LASTEXITCODE."
    }

    $portablePath = Join-Path $env:LOCALAPPDATA 'FVCodex\portable\app\ChatGPT.exe'
    Write-Host ''
    Write-Host 'FVCodex installation completed.' -ForegroundColor Green
    Write-Host ('Shortcut: ' + (Join-Path ([Environment]::GetFolderPath('Desktop')) 'FVCodex.lnk'))
    Write-Host ('Portable app: ' + $portablePath)
    Write-Host 'Please open FVCodex from the Desktop shortcut, or use the portable path above.'
}

$state.lastInstalledAt = (Get-Date).ToString('o')
if ($state.PSObject.Properties.Name -contains 'mode') {
    $state.mode = $Mode
}
else {
    $state | Add-Member -NotePropertyName mode -NotePropertyValue $Mode
}
$state.installedConfigSha256 = Get-Sha256 -Path $configPath
$state.installedCatalogSha256 = if (Test-Path -LiteralPath $targetCatalogPath -PathType Leaf) { Get-Sha256 -Path $targetCatalogPath } else { $null }
Write-JsonAtomic -Path $statePath -Value $state

if ($Mode -eq 'account' -and $PatchFVCodexVSCode -and -not $InstallFVCodex) {
    $vsCodeScript = Join-Path $scriptDirectory 'fvcodex-patch.js'
    if (-not (Test-Path -LiteralPath $vsCodeScript -PathType Leaf)) {
        throw "VS Code patch script is missing: $vsCodeScript"
    }
    Patch-VsCodeForAccount -FVCodexScript $vsCodeScript
}

Write-Host ''
if ($Mode -eq 'account') {
    Write-Host 'Codex native-catalog custom endpoint installation completed.'
    Write-Host 'Codex/OpenAI login was not checked by the installer.'
}
else {
    Write-Host 'Codex custom endpoint installation completed.'
}
Write-Host ('Config:  ' + $configPath)
if ($Mode -eq 'custom-endpoint') {
    Write-Host ('Catalog: ' + $targetCatalogPath)
}
else {
    Write-Host 'Catalog: native Codex catalog (local override not used)'
}
Write-Host 'User environment variables: CODEX_BASE_URL, CODEX_API_KEY, CODEX_MODEL, CODEX_REASONING_EFFORT'
Write-Host 'To apply these changes, close all running Codex applications and reopen them.'

if ($InstallFVCodex) {
    Install-FVCodexPortable -BaseUrl $endpoint -ApiKey $apiKey -Model $model -Effort $effort -Profile $FVCodexProfile
}
