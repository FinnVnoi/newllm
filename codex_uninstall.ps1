[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$StateFileName = 'codex_custom_endpoint_install_state.json'
$ExpectedCatalogName = 'legacy_direct_model_catalog.json'
$QuotaProxyName = 'codex_quota_proxy.py'
$QuotaProxyStartupName = 'codex_quota_proxy_startup.cmd'
$LegacyQuotaProxyConfigName = 'codex_quota_proxy.env'
$LegacyQuotaProxyStartupName = 'codex_quota_proxy_startup.vbs'
$ProxyEnvironmentVariableNames = @(
    'CODEX_UPSTREAM_BASE_URL',
    'CODEX_QUOTA_URL',
    'CODEX_QUOTA_PROXY_TOKEN',
    'CODEX_QUOTA_PROXY_HOST',
    'CODEX_QUOTA_PROXY_PORT'
)

function Get-CodexHome {
    if (-not [string]::IsNullOrWhiteSpace($env:CODEX_HOME)) {
        return [IO.Path]::GetFullPath($env:CODEX_HOME)
    }

    $userProfile = [Environment]::GetFolderPath('UserProfile')
    return [IO.Path]::GetFullPath((Join-Path $userProfile '.codex'))
}

function Get-StartupFolder {
    if (-not [string]::IsNullOrWhiteSpace($env:CODEX_CUSTOM_ENDPOINT_STARTUP_DIR)) {
        return [IO.Path]::GetFullPath($env:CODEX_CUSTOM_ENDPOINT_STARTUP_DIR)
    }
    return [Environment]::GetFolderPath('Startup')
}

function Get-Sha256 {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
}

function Unprotect-TextForCurrentUser {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ProtectedText
    )

    $secureValue = ConvertTo-SecureString -String $ProtectedText
    $plainValue = (New-Object Net.NetworkCredential('', $secureValue)).Password
    $prefix = 'codex-install-state:'
    if (-not $plainValue.StartsWith($prefix, [StringComparison]::Ordinal)) {
        throw 'The saved environment value has an invalid protection prefix.'
    }
    return $plainValue.Substring($prefix.Length)
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

function Save-ChangedFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [string]$Label
    )

    $directory = Split-Path -Parent $Path
    $fileName = [IO.Path]::GetFileName($Path)
    $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $safetyPath = Join-Path $directory ($fileName + '.before_codex_uninstall_' + $timestamp + '_' + $Label + '.bak')
    Copy-Item -LiteralPath $Path -Destination $safetyPath
    return $safetyPath
}

function Import-QuotaProxyConfig {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return
    }
    foreach ($line in [IO.File]::ReadAllLines($Path)) {
        $separator = $line.IndexOf('=')
        if ($separator -le 0) {
            continue
        }
        $name = $line.Substring(0, $separator)
        $encodedValue = $line.Substring($separator + 1)
        $value = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($encodedValue))
        [Environment]::SetEnvironmentVariable($name, $value, 'Process')
    }
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
        Copy-Item -LiteralPath $BackupPath -Destination $Path -Force
    }
    elseif (Test-Path -LiteralPath $Path -PathType Leaf) {
        Remove-Item -LiteralPath $Path -Force
    }
}

$codexHome = Get-CodexHome
$statePath = Join-Path $codexHome $StateFileName
if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) {
    Write-Host "Nothing to uninstall: install state not found at $statePath"
    exit 0
}

$state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
if ($state.schemaVersion -notin @(1, 2)) {
    throw "Unsupported install state schema in $statePath."
}

$backupFolderName = [string]$state.backupFolderName
if ([string]::IsNullOrWhiteSpace($backupFolderName) -or
    [IO.Path]::GetFileName($backupFolderName) -ne $backupFolderName -or
    -not $backupFolderName.StartsWith('codex_custom_endpoint_backup_', [StringComparison]::Ordinal)) {
    throw 'The backup folder name in the install state is invalid.'
}

$targetCatalogName = [string]$state.targetCatalogName
if ($targetCatalogName -ne $ExpectedCatalogName) {
    throw 'The catalog name in the install state is invalid.'
}

$backupDirectory = Join-Path $codexHome $backupFolderName
$configPath = Join-Path $codexHome 'config.toml'
$targetCatalogPath = Join-Path $codexHome $targetCatalogName
$configBackupPath = Join-Path $backupDirectory 'config.toml.original'
$catalogBackupPath = Join-Path $backupDirectory ($targetCatalogName + '.original')
$targetQuotaProxyPath = Join-Path $codexHome $QuotaProxyName
$quotaProxyStartupPath = Join-Path $codexHome $QuotaProxyStartupName
$startupQuotaProxyPath = Join-Path (Get-StartupFolder) $QuotaProxyStartupName
$quotaProxyBackupPath = Join-Path $backupDirectory ($QuotaProxyName + '.original')
$quotaStartupBackupPath = Join-Path $backupDirectory ($QuotaProxyStartupName + '.original')
$startupQuotaProxyBackupPath = Join-Path $backupDirectory ($QuotaProxyStartupName + '.startup.original')
$legacyQuotaProxyConfigPath = Join-Path $codexHome $LegacyQuotaProxyConfigName
$legacyQuotaProxyStartupPath = Join-Path $codexHome $LegacyQuotaProxyStartupName
$legacyStartupQuotaProxyPath = Join-Path (Get-StartupFolder) $LegacyQuotaProxyStartupName
$legacyQuotaConfigBackupPath = Join-Path $backupDirectory ($LegacyQuotaProxyConfigName + '.original')
$legacyQuotaStartupBackupPath = Join-Path $backupDirectory ($LegacyQuotaProxyStartupName + '.original')
$legacyStartupQuotaProxyBackupPath = Join-Path $backupDirectory ($LegacyQuotaProxyStartupName + '.startup.original')

$resolvedCodexHome = [IO.Path]::GetFullPath($codexHome).TrimEnd('\', '/')
$resolvedBackupDirectory = [IO.Path]::GetFullPath($backupDirectory)
$expectedPrefix = $resolvedCodexHome + [IO.Path]::DirectorySeparatorChar
if (-not $resolvedBackupDirectory.StartsWith($expectedPrefix, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'The resolved backup directory is outside CODEX_HOME.'
}

if (-not (Test-Path -LiteralPath $backupDirectory -PathType Container)) {
    throw "Backup directory not found: $backupDirectory"
}
if ([bool]$state.configExisted -and -not (Test-Path -LiteralPath $configBackupPath -PathType Leaf)) {
    throw "Original config backup not found: $configBackupPath"
}
if ([bool]$state.catalogExisted -and -not (Test-Path -LiteralPath $catalogBackupPath -PathType Leaf)) {
    throw "Original catalog backup not found: $catalogBackupPath"
}
if ($state.schemaVersion -eq 2) {
    $quotaConfigExisted = $state.PSObject.Properties.Name -contains 'quotaConfigExisted' -and [bool]$state.quotaConfigExisted
    $quotaStartupBackupToUse = if (Test-Path -LiteralPath $quotaStartupBackupPath -PathType Leaf) {
        $quotaStartupBackupPath
    }
    else {
        $legacyQuotaStartupBackupPath
    }
    $startupQuotaProxyBackupToUse = if (Test-Path -LiteralPath $startupQuotaProxyBackupPath -PathType Leaf) {
        $startupQuotaProxyBackupPath
    }
    else {
        $legacyStartupQuotaProxyBackupPath
    }
    foreach ($entry in @(
        @{ Existed = [bool]$state.quotaProxyExisted; Path = $quotaProxyBackupPath; Label = 'quota proxy' },
        @{ Existed = $quotaConfigExisted; Path = $legacyQuotaConfigBackupPath; Label = 'legacy quota config' },
        @{ Existed = [bool]$state.quotaStartupExisted; Path = $quotaStartupBackupToUse; Label = 'quota startup helper' },
        @{ Existed = [bool]$state.startupQuotaProxyExisted; Path = $startupQuotaProxyBackupToUse; Label = 'Startup quota helper' }
    )) {
        if ($entry.Existed -and -not (Test-Path -LiteralPath $entry.Path -PathType Leaf)) {
            throw ('Original ' + $entry.Label + ' backup not found: ' + $entry.Path)
        }
    }
}

$safetyCopies = New-Object 'System.Collections.Generic.List[string]'
if (Test-Path -LiteralPath $configPath -PathType Leaf) {
    $installedHash = [string]$state.installedConfigSha256
    if (-not [string]::IsNullOrWhiteSpace($installedHash) -and (Get-Sha256 -Path $configPath) -ne $installedHash) {
        [void]$safetyCopies.Add((Save-ChangedFile -Path $configPath -Label 'config_changed'))
    }
}
if (Test-Path -LiteralPath $targetCatalogPath -PathType Leaf) {
    $installedHash = [string]$state.installedCatalogSha256
    if (-not [string]::IsNullOrWhiteSpace($installedHash) -and (Get-Sha256 -Path $targetCatalogPath) -ne $installedHash) {
        [void]$safetyCopies.Add((Save-ChangedFile -Path $targetCatalogPath -Label 'catalog_changed'))
    }
}
if ($state.schemaVersion -eq 2) {
    $installedQuotaConfigSha256 = if ($state.PSObject.Properties.Name -contains 'installedQuotaConfigSha256') {
        [string]$state.installedQuotaConfigSha256
    }
    else {
        ''
    }
    foreach ($entry in @(
        @{ Path = $targetQuotaProxyPath; Hash = [string]$state.installedQuotaProxySha256; Label = 'quota_proxy_changed' },
        @{ Path = $quotaProxyStartupPath; Hash = [string]$state.installedQuotaStartupSha256; Label = 'quota_startup_changed' },
        @{ Path = $startupQuotaProxyPath; Hash = [string]$state.installedStartupQuotaProxySha256; Label = 'startup_quota_changed' },
        @{ Path = $legacyQuotaProxyConfigPath; Hash = $installedQuotaConfigSha256; Label = 'legacy_quota_config_changed' },
        @{ Path = $legacyQuotaProxyStartupPath; Hash = [string]$state.installedQuotaStartupSha256; Label = 'legacy_quota_startup_changed' },
        @{ Path = $legacyStartupQuotaProxyPath; Hash = [string]$state.installedStartupQuotaProxySha256; Label = 'legacy_startup_quota_changed' }
    )) {
        if (Test-Path -LiteralPath $entry.Path -PathType Leaf) {
            if (-not [string]::IsNullOrWhiteSpace($entry.Hash) -and (Get-Sha256 -Path $entry.Path) -ne $entry.Hash) {
                [void]$safetyCopies.Add((Save-ChangedFile -Path $entry.Path -Label $entry.Label))
            }
        }
    }
}

if (Test-Path -LiteralPath $legacyQuotaProxyConfigPath -PathType Leaf) {
    Import-QuotaProxyConfig -Path $legacyQuotaProxyConfigPath
}
$port = [Environment]::GetEnvironmentVariable('CODEX_QUOTA_PROXY_PORT', 'User')
$token = [Environment]::GetEnvironmentVariable('CODEX_QUOTA_PROXY_TOKEN', 'User')
if ([string]::IsNullOrWhiteSpace($port)) {
    $port = [Environment]::GetEnvironmentVariable('CODEX_QUOTA_PROXY_PORT', 'Process')
}
if ([string]::IsNullOrWhiteSpace($token)) {
    $token = [Environment]::GetEnvironmentVariable('CODEX_QUOTA_PROXY_TOKEN', 'Process')
}
if ($port -match '^\d+$' -and -not [string]::IsNullOrWhiteSpace($token)) {
    try {
        Invoke-WebRequest `
            -Uri ('http://127.0.0.1:' + $port + '/__codex_quota_proxy/stop') `
            -Method Post `
            -Headers @{ Authorization = 'Bearer ' + $token } `
            -UseBasicParsing `
            -TimeoutSec 2 | Out-Null
    }
    catch {
        # The proxy may already be stopped.
    }
}

if ([bool]$state.configExisted) {
    Copy-Item -LiteralPath $configBackupPath -Destination $configPath -Force
}
elseif (Test-Path -LiteralPath $configPath) {
    Remove-Item -LiteralPath $configPath -Force
}

if ([bool]$state.catalogExisted) {
    Copy-Item -LiteralPath $catalogBackupPath -Destination $targetCatalogPath -Force
}
elseif (Test-Path -LiteralPath $targetCatalogPath) {
    Remove-Item -LiteralPath $targetCatalogPath -Force
}
if ($state.schemaVersion -eq 2) {
    Restore-ManagedFile -Path $targetQuotaProxyPath -BackupPath $quotaProxyBackupPath -Existed ([bool]$state.quotaProxyExisted)
    if ($quotaConfigExisted) {
        Restore-ManagedFile -Path $legacyQuotaProxyConfigPath -BackupPath $legacyQuotaConfigBackupPath -Existed $true
    }
    elseif (Test-Path -LiteralPath $legacyQuotaProxyConfigPath -PathType Leaf) {
        Remove-Item -LiteralPath $legacyQuotaProxyConfigPath -Force
    }

    if (Test-Path -LiteralPath $quotaStartupBackupPath -PathType Leaf) {
        Restore-ManagedFile -Path $quotaProxyStartupPath -BackupPath $quotaStartupBackupPath -Existed ([bool]$state.quotaStartupExisted)
    }
    else {
        Restore-ManagedFile -Path $legacyQuotaProxyStartupPath -BackupPath $legacyQuotaStartupBackupPath -Existed ([bool]$state.quotaStartupExisted)
        if (Test-Path -LiteralPath $quotaProxyStartupPath -PathType Leaf) {
            Remove-Item -LiteralPath $quotaProxyStartupPath -Force
        }
    }

    if (Test-Path -LiteralPath $startupQuotaProxyBackupPath -PathType Leaf) {
        Restore-ManagedFile -Path $startupQuotaProxyPath -BackupPath $startupQuotaProxyBackupPath -Existed ([bool]$state.startupQuotaProxyExisted)
    }
    else {
        Restore-ManagedFile -Path $legacyStartupQuotaProxyPath -BackupPath $legacyStartupQuotaProxyBackupPath -Existed ([bool]$state.startupQuotaProxyExisted)
        if (Test-Path -LiteralPath $startupQuotaProxyPath -PathType Leaf) {
            Remove-Item -LiteralPath $startupQuotaProxyPath -Force
        }
    }
}

$restoredEnvironmentNames = @{}
foreach ($environmentEntry in @($state.environment)) {
    $variableName = [string]$environmentEntry.name
    if ([string]::IsNullOrWhiteSpace($variableName)) {
        throw 'The install state contains an invalid environment variable name.'
    }

    if ([bool]$environmentEntry.existed) {
        $previousValue = Unprotect-TextForCurrentUser -ProtectedText ([string]$environmentEntry.protectedValue)
        [Environment]::SetEnvironmentVariable($variableName, $previousValue, 'User')
        [Environment]::SetEnvironmentVariable($variableName, $previousValue, 'Process')
    }
    else {
        [Environment]::SetEnvironmentVariable($variableName, $null, 'User')
        [Environment]::SetEnvironmentVariable($variableName, $null, 'Process')
    }
    $restoredEnvironmentNames[$variableName] = $true
}
foreach ($variableName in $ProxyEnvironmentVariableNames) {
    if (-not $restoredEnvironmentNames.ContainsKey($variableName)) {
        [Environment]::SetEnvironmentVariable($variableName, $null, 'User')
        [Environment]::SetEnvironmentVariable($variableName, $null, 'Process')
    }
}
Broadcast-EnvironmentChange

Remove-Item -LiteralPath $backupDirectory -Recurse -Force
Remove-Item -LiteralPath $statePath -Force

Write-Host ''
Write-Host 'Codex custom endpoint installation was removed and the original state was restored.'
if ($safetyCopies.Count -gt 0) {
    Write-Host 'Files changed after installation were saved before restoration:'
    foreach ($safetyCopy in $safetyCopies) {
        Write-Host ('  ' + $safetyCopy)
    }
}
Write-Host 'Restart Codex so the restored user environment is loaded.'
