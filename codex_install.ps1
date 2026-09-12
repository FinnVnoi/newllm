[CmdletBinding()]
param(
    [switch]$NonInteractive
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$DefaultEndpoint = 'https://codex.finnvnoi.top/backend-api/codex'
$DefaultModel = 'gpt-5.6-sol'
$DefaultEffort = 'xhigh'
$ProviderId = 'codex'
$ProviderName = 'CODEX'
$ApiKeyVariable = 'CODEX_API_KEY'
$TargetCatalogName = 'legacy_direct_model_catalog.json'
$StateFileName = 'codex_custom_endpoint_install_state.json'
$EnvironmentVariableNames = @(
    'CODEX_BASE_URL',
    'CODEX_API_KEY',
    'CODEX_MODEL',
    'CODEX_REASONING_EFFORT'
)

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
        [System.Collections.Generic.List[string]]$Lines,
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
        [System.Collections.Generic.List[string]]$Lines,
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
    $customModel.shell_type = 'disabled'
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

$codexHome = Get-CodexHome
$configPath = Join-Path $codexHome 'config.toml'
$targetCatalogPath = Join-Path $codexHome $TargetCatalogName
$statePath = Join-Path $codexHome $StateFileName
$scriptDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
$bundledCatalogPath = Join-Path $scriptDirectory $TargetCatalogName
$legacyFallbackPath = Join-Path $codexHome 'legacy-direct-model-catalog.json'

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
    if (Test-CatalogContainsModel -Path $catalogSourcePath -Model $model) {
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
Set-TopLevelTomlValue -Lines $configLines -Key 'model_provider' -EncodedValue (ConvertTo-TomlBasicString $ProviderId)
Set-TopLevelTomlValue -Lines $configLines -Key 'model_reasoning_effort' -EncodedValue (ConvertTo-TomlBasicString $effort)
Set-TopLevelTomlValue -Lines $configLines -Key 'model_catalog_json' -EncodedValue (ConvertTo-TomlBasicString $targetCatalogPath)

$providerTable = 'model_providers.' + $ProviderId
Set-TableTomlValue -Lines $configLines -TableName $providerTable -Key 'name' -EncodedValue (ConvertTo-TomlBasicString $ProviderName)
Set-TableTomlValue -Lines $configLines -TableName $providerTable -Key 'base_url' -EncodedValue (ConvertTo-TomlBasicString $endpoint)
Set-TableTomlValue -Lines $configLines -TableName $providerTable -Key 'env_key' -EncodedValue (ConvertTo-TomlBasicString $ApiKeyVariable)
Set-TableTomlValue -Lines $configLines -TableName $providerTable -Key 'wire_api' -EncodedValue (ConvertTo-TomlBasicString 'responses')

$configContent = [string]::Join([Environment]::NewLine, $configLines)
if ($configLines.Count -gt 0) {
    $configContent += [Environment]::NewLine
}
Write-Utf8NoBomAtomic -Path $configPath -Content $configContent

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

$state.lastInstalledAt = (Get-Date).ToString('o')
$state.installedConfigSha256 = Get-Sha256 -Path $configPath
$state.installedCatalogSha256 = Get-Sha256 -Path $targetCatalogPath
Write-JsonAtomic -Path $statePath -Value $state

Write-Host ''
Write-Host 'Codex custom endpoint installation completed.'
Write-Host ('Config:  ' + $configPath)
Write-Host ('Catalog: ' + $targetCatalogPath)
Write-Host 'User environment variables: CODEX_BASE_URL, CODEX_API_KEY, CODEX_MODEL, CODEX_REASONING_EFFORT'
Write-Host 'Restart Codex so the new user environment is loaded.'
