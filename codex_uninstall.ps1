[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$StateFileName = 'codex_custom_endpoint_install_state.json'
$ExpectedCatalogName = 'legacy_direct_model_catalog.json'

function Get-CodexHome {
    if (-not [string]::IsNullOrWhiteSpace($env:CODEX_HOME)) {
        return [IO.Path]::GetFullPath($env:CODEX_HOME)
    }

    $userProfile = [Environment]::GetFolderPath('UserProfile')
    return [IO.Path]::GetFullPath((Join-Path $userProfile '.codex'))
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

$codexHome = Get-CodexHome
$statePath = Join-Path $codexHome $StateFileName
if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) {
    Write-Host "Nothing to uninstall: install state not found at $statePath"
    exit 0
}

$state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
if ($state.schemaVersion -ne 1) {
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
