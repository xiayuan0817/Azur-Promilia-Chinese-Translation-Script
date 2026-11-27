# 启动器汉化与备份还原。
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][ValidateSet('Apply', 'Restore', 'Verify', 'ValidatePayload')][string]$Action,
    [Parameter(Mandatory = $true)][ValidateSet('tw_launcher', 'jp_launcher')][string]$Target,
    [string]$Hint
)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)
$OutputEncoding = [Console]::OutputEncoding
. (Join-Path $PSScriptRoot 'Localization-Common.ps1')
. (Join-Path $PSScriptRoot 'Locate-Installations.ps1')
try {
    $packRoot = Split-Path $PSScriptRoot -Parent
    $plan = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'launcher-deployment.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $entries = @($plan.launchers | Where-Object { $_.id -eq $Target })
    if ($entries.Count -ne 1) { throw '启动器部署清单无效。' }
    $entry = $entries[0]
    $region = $Target.Substring(0, 2)
    $exe = if ($region -eq 'tw') { 'launcher.exe' } else { 'AZUPRO_JP_Gamelauncher.exe' }
    if ($entry.relative_path -ne 'resources/app.asar' -or $entry.payload_dir -ne $Target -or $entry.exe -ne $exe -or $entry.backup_suffix -ne '.before-zhcn-20261124.bak') { throw '启动器部署区服或路径无效。' }
    $payload = Resolve-SafeChild $packRoot ('payload/' + $Target + '/resources/app.asar')
    if ($Action -eq 'ValidatePayload') {
        if ((Get-FileSha256 $payload) -ne $entry.target_sha256) { throw ('补丁文件损坏：' + $payload) }
        Write-Host ('补丁完整性检查通过：' + $Target)
        exit 0
    }
    if ($PSBoundParameters.ContainsKey('Hint')) {
        $h = $Hint.Trim().Trim('"')
        if ([string]::IsNullOrWhiteSpace($h) -or -not [IO.Path]::IsPathRooted($h)) { throw '请指定启动器安装目录的绝对路径。' }
        if ([IO.File]::Exists($h)) { $h = Split-Path $h -Parent }
        $root = [IO.Path]::GetFullPath($h)
    } else {
        $definition = [pscustomobject]@{ Id = $Target; Label = $entry.label; Version = $entry.version; SearchSubpaths = $entry.search_subpaths }
        $location = (Find-InstallLocations @($definition) @{})[$Target]
        if ($location.State -ne 'found') { throw $location.Problem }
        $root = $location.Path
    }
    Assert-LauncherInstallRegion $root $region -AllowBackup:($Action -eq 'Restore')
    Write-Host ('区服已确认：' + $entry.label + '  ' + $root)
    if ($Action -eq 'Verify') { Write-Host '区服检查通过；未进行版本或全文件校验。'; exit 0 }
    $file = Resolve-SafeChild $root $entry.relative_path
    $backup = $file + $entry.backup_suffix
    Assert-NoReparse $backup
    $receipt = $backup + '.region.json'
    $null = Get-ModuleState $receipt $Target
    $processName = [IO.Path]::GetFileNameWithoutExtension($exe)
    $alwaysRefuse = if ($region -eq 'jp') { @($processName) } else { @() }
    $assertStopped = { Assert-ProcessesStopped -ProcessNames @($processName) -PathScopes @($root) -FriendlyError ('请先完全退出启动器：' + $exe) -AlwaysRefuseNames $alwaysRefuse }
    if ($Action -eq 'Restore') {
        if ([IO.File]::Exists($backup)) {
            if ((Get-AsarRegion $backup) -ne $region) { throw ('启动器备份区服不符：' + $backup) }
            $op = [pscustomobject]@{ Source = $backup; Target = $file; Backup = ''; RelativePath = $entry.relative_path }
        } elseif ([IO.File]::Exists($backup + '.zhcn-absent')) {
            $op = [pscustomobject]@{ Source = ''; Target = $file; Backup = ''; RelativePath = $entry.relative_path; Delete = $true }
        } else { Write-Host ('NO_BACKUP ' + $Target + ' 未找到备份，未修改。'); exit 0 }
    } else {
        $op = [pscustomobject]@{ Source = $payload; Target = $file; Backup = $backup; RelativePath = $entry.relative_path; PayloadEntry = $entry }
    }
    $changed = Invoke-DeploymentCopies @($op) $assertStopped
    try { Save-ModuleState $receipt $Target $Action } catch { Write-Warning ('区服记录未保存，请保留备份：' + $_.Exception.Message) }
    if ($changed) { Write-Host ($Action.ToUpperInvariant() + '_OK ' + $Target) }
    elseif ($Action -eq 'Restore') { Write-Host ('ALREADY_ORIGINAL ' + $Target) }
    else { Write-Host ('ALREADY_CURRENT ' + $Target) }
    exit 0
} catch {
    Write-Host $_.Exception.Message -ForegroundColor Red
    exit 1
}
