[CmdletBinding()]
param(
    [switch]$DeleteConfig
)

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

function Test-Admin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Stop-CodexBeforeUninstall {
    $running = @(Get-Process -Name ChatGPT,Codex -ErrorAction SilentlyContinue)
    if ($running.Count -eq 0) {
        return
    }

    Write-Host ''
    Write-Host ('ChatGPT/Codex is still running (' + $running.Count + ' process(es)).') -ForegroundColor Yellow
    Write-Host 'The uninstaller will close all Codex processes before restoring the original configuration.' -ForegroundColor Yellow
    Write-Host 'Press any key to continue...' -ForegroundColor Yellow
    [void][Console]::ReadKey($true)
    $running | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
}

function Repair-DanglingCodexProvider {
    param(
        [Parameter(Mandatory = $true)][string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $false
    }

    $content = Get-Content -LiteralPath $Path -Raw
    $hasCodexProvider = $content -match '(?m)^\s*\[model_providers\.codex\]\s*$'
    $usesCodexProvider = $content -match '(?m)^\s*model_provider\s*=\s*["'']codex["'']\s*$'
    if (-not $usesCodexProvider -or $hasCodexProvider) {
        return $false
    }

    $safetyPath = Save-ChangedFile -Path $Path -Label 'dangling_provider'
    $content = [regex]::Replace($content, '(?m)^\s*model_provider\s*=\s*["'']codex["'']\s*\r?\n?', '')
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($Path, $content, $utf8NoBom)
    Write-Host ('Removed dangling model_provider from config.toml. Safety copy: ' + $safetyPath) -ForegroundColor Yellow
    return $true
}

function Reset-CodexToNativeAccount {
    param(
        [Parameter(Mandatory = $true)][string]$Path
    )

    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        $content = Get-Content -LiteralPath $Path -Raw
        $customConfig = ($content -match '(?m)^\s*(model|model_provider|model_catalog_json)\s*=') -or
            ($content -match '(?m)^\s*\[model_providers\.[^\]]+\]')
        if ($customConfig) {
            $safetyPath = Save-ChangedFile -Path $Path -Label 'before_native_account_reset'
            $content = [regex]::Replace($content, '(?m)^\s*(model|model_provider|model_catalog_json)\s*=.*\r?\n?', '')
            $content = [regex]::Replace($content, '(?ms)^\s*\[model_providers\.[^\]]+\]\s*\r?\n.*?(?=^\s*\[|\z)', '')
            $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
            [IO.File]::WriteAllText($Path, $content, $utf8NoBom)
            Write-Host ('Removed custom provider/model overrides. Safety copy: ' + $safetyPath) -ForegroundColor Yellow
        }
    }

    foreach ($name in @('CODEX_BASE_URL', 'CODEX_API_KEY', 'CODEX_MODEL', 'CODEX_REASONING_EFFORT')) {
        [Environment]::SetEnvironmentVariable($name, $null, 'User')
        [Environment]::SetEnvironmentVariable($name, $null, 'Process')
    }
    Broadcast-EnvironmentChange
    Write-Host 'Codex custom endpoint environment variables cleared; native account mode restored.' -ForegroundColor Green
}

$codexHome = Get-CodexHome
$statePath = Join-Path $codexHome $StateFileName
$scriptDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
$fvcodexScript = Join-Path $scriptDirectory 'fvcodex-patch.js'
$fvcodexHome = Join-Path $env:LOCALAPPDATA 'FVCodex'
$directStatePath = Join-Path $env:APPDATA 'FVCodex\direct-state.json'
$hasDirectPatch = Test-Path -LiteralPath $directStatePath -PathType Leaf
$vsCodeBackupFiles = @(
    Get-ChildItem -Path (Join-Path $env:USERPROFILE '.vscode\extensions'), (Join-Path $env:USERPROFILE '.vscode-insiders\extensions'), (Join-Path $env:USERPROFILE '.cursor\extensions'), (Join-Path $env:USERPROFILE '.windsurf\extensions') -Recurse -File -Filter '*.codex-unblock.bak' -ErrorAction SilentlyContinue
)
$hasPortableFVCodex = Test-Path -LiteralPath $fvcodexHome -PathType Container
$hasVsCodePatch = $vsCodeBackupFiles.Count -gt 0
$hasInstallState = Test-Path -LiteralPath $statePath -PathType Leaf

Stop-CodexBeforeUninstall

if ($hasDirectPatch -and -not (Test-Admin)) {
    Write-Host 'Direct FVCodex patch detected. Administrator permission is required to restore the original MSIX.' -ForegroundColor Yellow
    $argLine = '-NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $PSCommandPath
    if ($DeleteConfig) { $argLine += ' -DeleteConfig' }
    $proc = Start-Process powershell.exe -Verb RunAs -ArgumentList $argLine -Wait -PassThru
    exit $proc.ExitCode
}

if ($hasDirectPatch) {
    Write-Host ''
    Write-Host 'Direct FVCodex patch detected. Restoring original app.asar and ChatGPT.exe...' -ForegroundColor Cyan
    if (-not (Test-Path -LiteralPath $fvcodexScript -PathType Leaf)) {
        throw "FVCodex patch script is missing: $fvcodexScript"
    }
    & node $fvcodexScript "--root=$scriptDirectory" '--direct-restore'
    if ($LASTEXITCODE -ne 0) {
        throw "Direct FVCodex restore failed with exit code $LASTEXITCODE."
    }
}

$oaicConfigPath = Join-Path $env:APPDATA 'oaic-usage\config.json'
$removeOaicConfig = $false
if ((Test-Path -LiteralPath $oaicConfigPath -PathType Leaf) -and ($hasInstallState -or $hasVsCodePatch -or $hasPortableFVCodex -or $hasDirectPatch)) {
    if ($DeleteConfig) {
        $removeOaicConfig = $true
    }
    else {
        $configChoice = Read-Host 'Remove the shared OAIC configuration as well? [y/N]'
        $removeOaicConfig = $configChoice -match '^(y|yes)$'
    }

    if ($removeOaicConfig) {
        Remove-Item -LiteralPath $oaicConfigPath -Force
        $oaicDirectory = Split-Path -Parent $oaicConfigPath
        if ((Test-Path -LiteralPath $oaicDirectory -PathType Container) -and (@(Get-ChildItem -LiteralPath $oaicDirectory -Force).Count -eq 0)) {
            Remove-Item -LiteralPath $oaicDirectory -Force
        }
        Write-Host ('Removed shared OAIC config: ' + $oaicConfigPath)
    }
    else {
        Write-Host ('Kept shared OAIC config: ' + $oaicConfigPath)
    }
}

if ($hasVsCodePatch -or $hasPortableFVCodex) {
    Write-Host ''
    Write-Host 'Detected FVCodex-related installation:' -ForegroundColor Cyan
    if ($hasVsCodePatch) { Write-Host ('  VS Code patched files: ' + $vsCodeBackupFiles.Count) }
    if ($hasPortableFVCodex) { Write-Host ('  FVCodex portable: ' + $fvcodexHome) }

    if ($hasVsCodePatch) {
        $restoreVsCode = Read-Host 'Remove the VS Code Codex extension patch and restore original files? [Y/n]'
        if ($restoreVsCode -match '^(|y|yes)$') {
            if (-not (Test-Path -LiteralPath $fvcodexScript -PathType Leaf)) {
                throw "FVCodex patch script is missing: $fvcodexScript"
            }
            & node $fvcodexScript "--root=$scriptDirectory" '--vscode-restore'
            if ($LASTEXITCODE -ne 0) { throw "VS Code restore failed with exit code $LASTEXITCODE." }
        }
    }

    if ($hasPortableFVCodex) {
        $removeFVCodex = Read-Host 'Uninstall FVCodex portable and remove its shortcuts? [Y/n]'
        if ($removeFVCodex -match '^(|y|yes)$') {
            if (-not (Test-Path -LiteralPath $fvcodexScript -PathType Leaf)) {
                throw "FVCodex patch script is missing: $fvcodexScript"
            }
            & node $fvcodexScript "--root=$scriptDirectory" '--portable-remove'
            if ($LASTEXITCODE -ne 0) { throw "FVCodex portable removal failed with exit code $LASTEXITCODE." }
        }
    }
}

if (-not $hasInstallState) {
    Reset-CodexToNativeAccount -Path (Join-Path $codexHome 'config.toml')
    Write-Host "Nothing else to uninstall: install state not found at $statePath"
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

Reset-CodexToNativeAccount -Path $configPath

Write-Host ''
Write-Host 'Codex custom endpoint installation was removed and the original state was restored.'
if ($safetyCopies.Count -gt 0) {
    Write-Host 'Files changed after installation were saved before restoration:'
    foreach ($safetyCopy in $safetyCopies) {
        Write-Host ('  ' + $safetyCopy)
    }
}
Write-Host 'Restart Codex so the restored user environment is loaded.'
