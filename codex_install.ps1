[CmdletBinding()]
param(
    [switch]$NonInteractive
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$DefaultEndpoint = 'https://codex.finnvnoi.top/backend-api/codex'
$DefaultModel = 'gpt-5.6-sol'
$DefaultEffort = 'xhigh'
$DefaultShowQuota = $true
$DefaultQuotaProxyPort = 48123
$ProviderId = 'codex'
$ProviderName = 'openai'
$ApiKeyVariable = 'CODEX_API_KEY'
$TargetCatalogName = 'legacy_direct_model_catalog.json'
$QuotaProxyName = 'codex_quota_proxy.py'
$QuotaProxyStartupName = 'codex_quota_proxy_startup.cmd'
$StateFileName = 'codex_custom_endpoint_install_state.json'
$MainEnvironmentVariableNames = @(
    'CODEX_BASE_URL',
    'CODEX_API_KEY',
    'CODEX_MODEL',
    'CODEX_REASONING_EFFORT'
)
$ProxyEnvironmentVariableNames = @(
    'CODEX_UPSTREAM_BASE_URL',
    'CODEX_QUOTA_URL',
    'CODEX_QUOTA_PROXY_TOKEN',
    'CODEX_QUOTA_PROXY_HOST',
    'CODEX_QUOTA_PROXY_PORT'
)
$EnvironmentVariableNames = @($MainEnvironmentVariableNames + $ProxyEnvironmentVariableNames)
$ManagedStatusLine = '["model-with-reasoning", "five-hour-limit", "weekly-limit"]'

function Get-CodexHome {
    if (-not [string]::IsNullOrWhiteSpace($env:CODEX_HOME)) {
        return [IO.Path]::GetFullPath($env:CODEX_HOME)
    }
    return [IO.Path]::GetFullPath((Join-Path ([Environment]::GetFolderPath('UserProfile')) '.codex'))
}

function Get-StartupFolder {
    if (-not [string]::IsNullOrWhiteSpace($env:CODEX_CUSTOM_ENDPOINT_STARTUP_DIR)) {
        return [IO.Path]::GetFullPath($env:CODEX_CUSTOM_ENDPOINT_STARTUP_DIR)
    }
    return [Environment]::GetFolderPath('Startup')
}

function ConvertTo-TomlBasicString {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$Value
    )

    $escaped = $Value.Replace('\', '\\').Replace('"', '\"')
    $escaped = $escaped.Replace("`t", '\t').Replace("`n", '\n').Replace("`r", '\r')
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
    for ($index = $matchedIndexes.Count - 1; $index -ge 1; $index--) {
        $Lines.RemoveAt($matchedIndexes[$index])
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
    for ($index = $matchedIndexes.Count - 1; $index -ge 1; $index--) {
        $Lines.RemoveAt($matchedIndexes[$index])
    }
}

function Remove-TableTomlValues {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [System.Collections.Generic.List[string]]$Lines,
        [Parameter(Mandatory = $true)]
        [string]$TableName,
        [Parameter(Mandatory = $true)]
        [string[]]$Keys
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

    $keyPattern = ($Keys | ForEach-Object { [regex]::Escape($_) }) -join '|'
    for ($index = $tableEnd - 1; $index -gt $tableStart; $index--) {
        if ($Lines[$index] -match ('^\s*(?:' + $keyPattern + ')\s*=')) {
            $Lines.RemoveAt($index)
        }
    }
}

function Test-TableTomlKey {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [System.Collections.Generic.List[string]]$Lines,
        [Parameter(Mandatory = $true)]
        [string]$TableName,
        [Parameter(Mandatory = $true)]
        [string]$Key
    )

    $tablePattern = '^\s*\[\s*' + [regex]::Escape($TableName) + '\s*\]\s*(?:#.*)?$'
    $keyPattern = '^\s*' + [regex]::Escape($Key) + '\s*='
    $insideTable = $false
    foreach ($line in $Lines) {
        if ($line -match '^\s*\[') {
            $insideTable = $line -match $tablePattern
        }
        elseif ($insideTable -and $line -match $keyPattern) {
            return $true
        }
    }
    return $false
}

function Remove-ManagedStatusLine {
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [AllowEmptyString()]
        [System.Collections.Generic.List[string]]$Lines
    )

    $insideTui = $false
    $managedPattern = '^\s*status_line\s*=\s*\[\s*"model-with-reasoning"\s*,\s*"five-hour-limit"\s*,\s*"weekly-limit"\s*\]\s*(?:#.*)?$'
    $index = 0
    while ($index -lt $Lines.Count) {
        if ($Lines[$index] -match '^\s*\[') {
            $insideTui = $Lines[$index] -match '^\s*\[\s*tui\s*\]\s*(?:#.*)?$'
            $index++
        }
        elseif ($insideTui -and $Lines[$index] -match $managedPattern) {
            $Lines.RemoveAt($index)
        }
        else {
            $index++
        }
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
        [IO.File]::WriteAllText($temporaryPath, $Content, (New-Object Text.UTF8Encoding($false)))
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

    Write-Utf8NoBomAtomic -Path $Path -Content (($Value | ConvertTo-Json -Depth 12) + [Environment]::NewLine)
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
            return $value.Trim()
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
        return $ExistingValue.Trim()
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
        return $ExistingValue.Trim()
    }
    return $enteredValue.Trim()
}

function Read-YesNo {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Label,
        [Parameter(Mandatory = $true)]
        [bool]$DefaultValue
    )

    $suffix = if ($DefaultValue) { 'Y/n' } else { 'y/N' }
    while ($true) {
        $enteredValue = Read-Host ($Label + ' [' + $suffix + ']')
        if ([string]::IsNullOrWhiteSpace($enteredValue)) {
            return $DefaultValue
        }
        switch ($enteredValue.Trim().ToLowerInvariant()) {
            { $_ -in @('y', 'yes') } { return $true }
            { $_ -in @('n', 'no') } { return $false }
            default { Write-Host 'Please enter y or n.' }
        }
    }
}

function Assert-Endpoint {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Endpoint,
        [Parameter(Mandatory = $true)]
        [string]$Label
    )

    $uri = $null
    if (-not [Uri]::TryCreate($Endpoint, [UriKind]::Absolute, [ref]$uri) -or
        $uri.Scheme -notin @('http', 'https')) {
        throw "$Label must be an absolute HTTP or HTTPS URL."
    }
    if (-not [string]::IsNullOrEmpty($uri.Query) -or -not [string]::IsNullOrEmpty($uri.Fragment)) {
        throw "$Label must not contain a query or fragment."
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

function Get-Sha256 {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

function Get-OptionalSha256 {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        return Get-Sha256 -Path $Path
    }
    return $null
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
        IntPtr hWnd, uint Msg, UIntPtr wParam, string lParam,
        uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);
}
'@
    }

    $result = [UIntPtr]::Zero
    [void][CodexEnvironmentBroadcast]::SendMessageTimeout(
        [IntPtr]0xffff, 0x001A, [UIntPtr]::Zero, 'Environment',
        0x0002, 5000, [ref]$result
    )
}

function Get-PythonExecutable {
    foreach ($candidate in @('python.exe', 'python3.exe', 'py.exe')) {
        $command = Get-Command $candidate -ErrorAction SilentlyContinue
        if ($null -eq $command) {
            continue
        }
        & $command.Source -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 8) else 1)' 2>$null
        if ($LASTEXITCODE -eq 0) {
            return $command.Source
        }
    }
    throw 'Python 3.8 or newer is required when Show quota is enabled.'
}

function Get-PythonStartupExecutable {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PythonExecutable
    )

    if ([IO.Path]::GetFileName($PythonExecutable) -ieq 'python.exe') {
        $pythonwPath = Join-Path (Split-Path -Parent $PythonExecutable) 'pythonw.exe'
        if (Test-Path -LiteralPath $pythonwPath -PathType Leaf) {
            return $pythonwPath
        }
    }
    $pythonwCommand = Get-Command 'pythonw.exe' -ErrorAction SilentlyContinue
    if ($null -ne $pythonwCommand) {
        return $pythonwCommand.Source
    }
    return $PythonExecutable
}

function Invoke-QuotaProxyCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PythonExecutable,
        [Parameter(Mandatory = $true)]
        [string]$ProxyPath,
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    $output = & $PythonExecutable $ProxyPath @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        $message = ($output | Out-String).Trim()
        if ([string]::IsNullOrWhiteSpace($message)) {
            $message = "Quota proxy command failed with exit code $LASTEXITCODE."
        }
        throw $message
    }
    return ($output | Out-String).Trim()
}

function New-ProxyToken {
    $bytes = New-Object byte[] 32
    $random = [Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $random.GetBytes($bytes)
    }
    finally {
        $random.Dispose()
    }
    return ([BitConverter]::ToString($bytes)).Replace('-', '').ToLowerInvariant()
}

function Stop-ExistingQuotaProxy {
    $port = [Environment]::GetEnvironmentVariable('CODEX_QUOTA_PROXY_PORT', 'User')
    $token = [Environment]::GetEnvironmentVariable('CODEX_QUOTA_PROXY_TOKEN', 'User')
    if ($port -notmatch '^\d+$' -or [string]::IsNullOrWhiteSpace($token)) {
        return
    }
    try {
        Invoke-WebRequest `
            -Uri ('http://127.0.0.1:' + $port + '/__codex_quota_proxy/stop') `
            -Method Post `
            -Headers @{ Authorization = 'Bearer ' + $token } `
            -UseBasicParsing `
            -TimeoutSec 2 | Out-Null
    }
    catch {
        # The prior proxy may already be stopped.
    }
}

function Backup-ManagedFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [string]$BackupPath
    )

    $existed = Test-Path -LiteralPath $Path -PathType Leaf
    if ($existed) {
        Copy-Item -LiteralPath $Path -Destination $BackupPath -Force
    }
    return $existed
}

function Restore-ManagedFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [string]$BackupPath,
        [Parameter(Mandatory = $true)]
        [bool]$Existed
    )

    if ($Existed) {
        $directory = Split-Path -Parent $Path
        if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
            [void](New-Item -ItemType Directory -Path $directory -Force)
        }
        Copy-Item -LiteralPath $BackupPath -Destination $Path -Force
    }
    elseif (Test-Path -LiteralPath $Path -PathType Leaf) {
        Remove-Item -LiteralPath $Path -Force
    }
}

function Set-StateProperty {
    param(
        [Parameter(Mandatory = $true)]
        $State,
        [Parameter(Mandatory = $true)]
        [string]$Name,
        $Value
    )

    if ($State -is [System.Collections.IDictionary]) {
        $State[$Name] = $Value
    }
    else {
        $State | Add-Member -MemberType NoteProperty -Name $Name -Value $Value -Force
    }
}

function Add-MissingEnvironmentState {
    param(
        [Parameter(Mandatory = $true)]
        $State
    )

    $entries = @($State.environment)
    $knownNames = @{}
    foreach ($entry in $entries) {
        $knownNames[[string]$entry.name] = $true
    }
    foreach ($variableName in $EnvironmentVariableNames) {
        if ($knownNames.ContainsKey($variableName)) {
            continue
        }
        $previousValue = [Environment]::GetEnvironmentVariable($variableName, 'User')
        $entries += [ordered]@{
            name = $variableName
            existed = $null -ne $previousValue
            protectedValue = if ($null -ne $previousValue) {
                Protect-TextForCurrentUser -Text $previousValue
            }
            else {
                $null
            }
        }
    }
    Set-StateProperty -State $State -Name 'environment' -Value $entries
}

$codexHome = Get-CodexHome
$configPath = Join-Path $codexHome 'config.toml'
$targetCatalogPath = Join-Path $codexHome $TargetCatalogName
$statePath = Join-Path $codexHome $StateFileName
$targetQuotaProxyPath = Join-Path $codexHome $QuotaProxyName
$quotaProxyStartupPath = Join-Path $codexHome $QuotaProxyStartupName
$startupFolder = Get-StartupFolder
$startupQuotaProxyPath = Join-Path $startupFolder $QuotaProxyStartupName
$scriptDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
$bundledCatalogPath = Join-Path $scriptDirectory $TargetCatalogName
$bundledQuotaProxyPath = Join-Path $scriptDirectory $QuotaProxyName
$legacyFallbackPath = Join-Path $codexHome 'legacy-direct-model-catalog.json'

if (Test-Path -LiteralPath $bundledCatalogPath -PathType Leaf) {
    $catalogSourcePath = $bundledCatalogPath
}
elseif (Test-Path -LiteralPath $legacyFallbackPath -PathType Leaf) {
    $catalogSourcePath = $legacyFallbackPath
}
else {
    throw "Missing $TargetCatalogName beside the installer, and no legacy catalog fallback exists in $codexHome."
}
Assert-Catalog -Path $catalogSourcePath

$existingApiKey = Get-ExistingApiKey
if ($NonInteractive) {
    $endpoint = $DefaultEndpoint
    $apiKey = Read-ApiKey -ExistingValue $existingApiKey
    $model = $DefaultModel
    $effort = $DefaultEffort
    $showQuota = $DefaultShowQuota
}
else {
    $endpoint = Read-PlainValue -Label 'Endpoint' -DefaultValue $DefaultEndpoint
    $apiKey = Read-ApiKey -ExistingValue $existingApiKey
    $model = Read-PlainValue -Label 'Model' -DefaultValue $DefaultModel
    $effort = Read-PlainValue -Label 'Reasoning effort' -DefaultValue $DefaultEffort
    $showQuota = Read-YesNo -Label 'Show quota in Codex CLI and Codex App' -DefaultValue $DefaultShowQuota
}

Assert-Endpoint -Endpoint $endpoint -Label 'Endpoint'
if ([string]::IsNullOrWhiteSpace($model)) {
    throw 'Model cannot be empty.'
}
if ([string]::IsNullOrWhiteSpace($effort)) {
    throw 'Reasoning effort cannot be empty.'
}

if (-not (Test-Path -LiteralPath $codexHome -PathType Container)) {
    [void](New-Item -ItemType Directory -Path $codexHome -Force)
}
Stop-ExistingQuotaProxy

$configuredEndpoint = $endpoint
$pythonExecutable = $null
$quotaUrl = $null
$quotaProxyPort = $null
$quotaProxyToken = $null
if ($showQuota) {
    if (-not (Test-Path -LiteralPath $bundledQuotaProxyPath -PathType Leaf)) {
        throw "Missing $QuotaProxyName beside the installer."
    }
    $pythonExecutable = Get-PythonExecutable
    $defaultQuotaUrl = Invoke-QuotaProxyCommand `
        -PythonExecutable $pythonExecutable `
        -ProxyPath $bundledQuotaProxyPath `
        -Arguments @('--derive-quota-url', $endpoint)
    $quotaUrl = if ($NonInteractive) {
        $defaultQuotaUrl
    }
    else {
        Read-PlainValue -Label 'Quota endpoint' -DefaultValue $defaultQuotaUrl
    }
    Assert-Endpoint -Endpoint $quotaUrl -Label 'Quota endpoint'

    [Environment]::SetEnvironmentVariable('CODEX_QUOTA_PROXY_HOST', '127.0.0.1', 'Process')
    [Environment]::SetEnvironmentVariable('CODEX_QUOTA_PROXY_PORT', [string]$DefaultQuotaProxyPort, 'Process')
    $quotaProxyPort = Invoke-QuotaProxyCommand `
        -PythonExecutable $pythonExecutable `
        -ProxyPath $bundledQuotaProxyPath `
        -Arguments @('--find-port')
    if ($quotaProxyPort -notmatch '^\d+$') {
        throw "Quota proxy returned an invalid port: $quotaProxyPort"
    }
    $quotaProxyToken = New-ProxyToken
    [Environment]::SetEnvironmentVariable('CODEX_QUOTA_PROXY_PORT', $quotaProxyPort, 'Process')
    $configuredEndpoint = Invoke-QuotaProxyCommand `
        -PythonExecutable $pythonExecutable `
        -ProxyPath $bundledQuotaProxyPath `
        -Arguments @('--local-base-url', $endpoint)
}

if (Test-Path -LiteralPath $statePath -PathType Leaf) {
    $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
    if ($state.schemaVersion -notin @(1, 2)) {
        throw "Unsupported install state schema in $statePath."
    }
    $backupFolderName = [string]$state.backupFolderName
    $backupDirectory = Join-Path $codexHome $backupFolderName
    if (-not (Test-Path -LiteralPath $backupDirectory -PathType Container)) {
        throw "The existing install state references a missing backup directory: $backupDirectory"
    }
    Add-MissingEnvironmentState -State $state
    if ($state.schemaVersion -eq 1) {
        Set-StateProperty -State $state -Name 'schemaVersion' -Value 2
        Set-StateProperty -State $state -Name 'quotaProxyExisted' -Value (Backup-ManagedFile `
            -Path $targetQuotaProxyPath `
            -BackupPath (Join-Path $backupDirectory ($QuotaProxyName + '.original')))
        Set-StateProperty -State $state -Name 'quotaStartupExisted' -Value (Backup-ManagedFile `
            -Path $quotaProxyStartupPath `
            -BackupPath (Join-Path $backupDirectory ($QuotaProxyStartupName + '.original')))
        Set-StateProperty -State $state -Name 'startupQuotaProxyExisted' -Value (Backup-ManagedFile `
            -Path $startupQuotaProxyPath `
            -BackupPath (Join-Path $backupDirectory ($QuotaProxyStartupName + '.startup.original')))
    }
}
else {
    $backupFolderName = 'codex_custom_endpoint_backup_' + (Get-Date -Format 'yyyyMMdd_HHmmss') + '_' + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $backupDirectory = Join-Path $codexHome $backupFolderName
    [void](New-Item -ItemType Directory -Path $backupDirectory)

    $environmentState = foreach ($variableName in $EnvironmentVariableNames) {
        $previousValue = [Environment]::GetEnvironmentVariable($variableName, 'User')
        [ordered]@{
            name = $variableName
            existed = $null -ne $previousValue
            protectedValue = if ($null -ne $previousValue) {
                Protect-TextForCurrentUser -Text $previousValue
            }
            else {
                $null
            }
        }
    }

    $state = [ordered]@{
        schemaVersion = 2
        createdAt = (Get-Date).ToString('o')
        lastInstalledAt = $null
        codexHome = $codexHome
        backupFolderName = $backupFolderName
        configExisted = Backup-ManagedFile `
            -Path $configPath `
            -BackupPath (Join-Path $backupDirectory 'config.toml.original')
        catalogExisted = Backup-ManagedFile `
            -Path $targetCatalogPath `
            -BackupPath (Join-Path $backupDirectory ($TargetCatalogName + '.original'))
        quotaProxyExisted = Backup-ManagedFile `
            -Path $targetQuotaProxyPath `
            -BackupPath (Join-Path $backupDirectory ($QuotaProxyName + '.original'))
        quotaStartupExisted = Backup-ManagedFile `
            -Path $quotaProxyStartupPath `
            -BackupPath (Join-Path $backupDirectory ($QuotaProxyStartupName + '.original'))
        startupQuotaProxyExisted = Backup-ManagedFile `
            -Path $startupQuotaProxyPath `
            -BackupPath (Join-Path $backupDirectory ($QuotaProxyStartupName + '.startup.original'))
        targetCatalogName = $TargetCatalogName
        environment = @($environmentState)
        installedConfigSha256 = $null
        installedCatalogSha256 = $null
        installedQuotaProxySha256 = $null
        installedQuotaStartupSha256 = $null
        installedStartupQuotaProxySha256 = $null
        managedStatusLineOwned = $false
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
Remove-TableTomlValues -Lines $configLines -TableName $providerTable -Keys @('env_key', 'experimental_bearer_token')
Set-TableTomlValue -Lines $configLines -TableName $providerTable -Key 'name' -EncodedValue (ConvertTo-TomlBasicString $ProviderName)
Set-TableTomlValue -Lines $configLines -TableName $providerTable -Key 'base_url' -EncodedValue (ConvertTo-TomlBasicString $configuredEndpoint)
if ($showQuota) {
    Set-TableTomlValue -Lines $configLines -TableName $providerTable -Key 'experimental_bearer_token' -EncodedValue (ConvertTo-TomlBasicString $quotaProxyToken)
}
else {
    Set-TableTomlValue -Lines $configLines -TableName $providerTable -Key 'env_key' -EncodedValue (ConvertTo-TomlBasicString $ApiKeyVariable)
}
Set-TableTomlValue -Lines $configLines -TableName $providerTable -Key 'wire_api' -EncodedValue (ConvertTo-TomlBasicString 'responses')
Set-TableTomlValue -Lines $configLines -TableName $providerTable -Key 'supports_websockets' -EncodedValue 'false'
Set-TableTomlValue -Lines $configLines -TableName $providerTable -Key 'requires_openai_auth' -EncodedValue 'true'

$managedStatusLineOwned = if ($state.PSObject.Properties.Name -contains 'managedStatusLineOwned') {
    [bool]$state.managedStatusLineOwned
}
else {
    $false
}
if ($showQuota) {
    if (-not (Test-TableTomlKey -Lines $configLines -TableName 'tui' -Key 'status_line')) {
        Set-TableTomlValue -Lines $configLines -TableName 'tui' -Key 'status_line' -EncodedValue $ManagedStatusLine
        $managedStatusLineOwned = $true
    }
}
elseif ($managedStatusLineOwned) {
    Remove-ManagedStatusLine -Lines $configLines
    $managedStatusLineOwned = $false
}

$configContent = [string]::Join([Environment]::NewLine, $configLines)
if ($configLines.Count -gt 0) {
    $configContent += [Environment]::NewLine
}
Write-Utf8NoBomAtomic -Path $configPath -Content $configContent

$catalogTemporaryPath = Join-Path $codexHome ('.' + $TargetCatalogName + '.' + [guid]::NewGuid().ToString('N') + '.tmp')
try {
    Copy-Item -LiteralPath $catalogSourcePath -Destination $catalogTemporaryPath -Force
    Assert-Catalog -Path $catalogTemporaryPath
    Move-Item -LiteralPath $catalogTemporaryPath -Destination $targetCatalogPath -Force
}
finally {
    if (Test-Path -LiteralPath $catalogTemporaryPath) {
        Remove-Item -LiteralPath $catalogTemporaryPath -Force
    }
}

$mainEnvironment = [ordered]@{
    CODEX_BASE_URL = $endpoint
    CODEX_API_KEY = $apiKey
    CODEX_MODEL = $model
    CODEX_REASONING_EFFORT = $effort
}
$proxyEnvironment = if ($showQuota) {
    [ordered]@{
        CODEX_UPSTREAM_BASE_URL = $endpoint
        CODEX_QUOTA_URL = $quotaUrl
        CODEX_QUOTA_PROXY_TOKEN = $quotaProxyToken
        CODEX_QUOTA_PROXY_HOST = '127.0.0.1'
        CODEX_QUOTA_PROXY_PORT = $quotaProxyPort
    }
}
else {
    [ordered]@{
        CODEX_UPSTREAM_BASE_URL = $null
        CODEX_QUOTA_URL = $null
        CODEX_QUOTA_PROXY_TOKEN = $null
        CODEX_QUOTA_PROXY_HOST = $null
        CODEX_QUOTA_PROXY_PORT = $null
    }
}
foreach ($entry in @($mainEnvironment.GetEnumerator()) + @($proxyEnvironment.GetEnumerator())) {
    [Environment]::SetEnvironmentVariable($entry.Key, $entry.Value, 'User')
    [Environment]::SetEnvironmentVariable($entry.Key, $entry.Value, 'Process')
}
Broadcast-EnvironmentChange

if ($showQuota) {
    Copy-Item -LiteralPath $bundledQuotaProxyPath -Destination $targetQuotaProxyPath -Force
    $startupPython = Get-PythonStartupExecutable -PythonExecutable $pythonExecutable
    $startupContent = '@echo off' + [Environment]::NewLine +
        '"' + $startupPython + '" "' + $targetQuotaProxyPath + '" --ensure-running >nul 2>&1' +
        [Environment]::NewLine
    Write-Utf8NoBomAtomic -Path $quotaProxyStartupPath -Content $startupContent
    if (-not (Test-Path -LiteralPath $startupFolder -PathType Container)) {
        [void](New-Item -ItemType Directory -Path $startupFolder -Force)
    }
    Copy-Item -LiteralPath $quotaProxyStartupPath -Destination $startupQuotaProxyPath -Force
    [void](Invoke-QuotaProxyCommand `
        -PythonExecutable $pythonExecutable `
        -ProxyPath $targetQuotaProxyPath `
        -Arguments @('--ensure-running'))
    [void](Invoke-QuotaProxyCommand `
        -PythonExecutable $pythonExecutable `
        -ProxyPath $targetQuotaProxyPath `
        -Arguments @('--check'))
}
else {
    Restore-ManagedFile `
        -Path $targetQuotaProxyPath `
        -BackupPath (Join-Path $backupDirectory ($QuotaProxyName + '.original')) `
        -Existed ([bool]$state.quotaProxyExisted)
    Restore-ManagedFile `
        -Path $quotaProxyStartupPath `
        -BackupPath (Join-Path $backupDirectory ($QuotaProxyStartupName + '.original')) `
        -Existed ([bool]$state.quotaStartupExisted)
    Restore-ManagedFile `
        -Path $startupQuotaProxyPath `
        -BackupPath (Join-Path $backupDirectory ($QuotaProxyStartupName + '.startup.original')) `
        -Existed ([bool]$state.startupQuotaProxyExisted)
}

Set-StateProperty -State $state -Name 'lastInstalledAt' -Value (Get-Date).ToString('o')
Set-StateProperty -State $state -Name 'installedConfigSha256' -Value (Get-Sha256 -Path $configPath)
Set-StateProperty -State $state -Name 'installedCatalogSha256' -Value (Get-Sha256 -Path $targetCatalogPath)
Set-StateProperty -State $state -Name 'installedQuotaProxySha256' -Value (Get-OptionalSha256 -Path $targetQuotaProxyPath)
Set-StateProperty -State $state -Name 'installedQuotaStartupSha256' -Value (Get-OptionalSha256 -Path $quotaProxyStartupPath)
Set-StateProperty -State $state -Name 'installedStartupQuotaProxySha256' -Value (Get-OptionalSha256 -Path $startupQuotaProxyPath)
Set-StateProperty -State $state -Name 'managedStatusLineOwned' -Value $managedStatusLineOwned
Write-JsonAtomic -Path $statePath -Value $state

Write-Host ''
Write-Host 'Codex custom endpoint installation completed.'
Write-Host ('Config:  ' + $configPath)
Write-Host ('Catalog: ' + $targetCatalogPath)
if ($showQuota) {
    Write-Host ('Quota:   enabled via ' + $quotaUrl)
    Write-Host ('Proxy:   ' + $configuredEndpoint)
    Write-Host ('Autostart: ' + $startupQuotaProxyPath)
}
else {
    Write-Host 'Quota:   disabled'
}
Write-Host ('API key stored: ' + $apiKey.Length + ' characters (value hidden)')
Write-Host 'New terminals and newly launched applications receive the User environment automatically.'
Write-Host 'Restart Codex CLI or Codex App so the new configuration is loaded.'
