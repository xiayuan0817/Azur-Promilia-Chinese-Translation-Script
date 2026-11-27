# 文件状态、备份、汉化与还原。
if (-not ('LocalizationNative' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Text;
using System.Security.Cryptography;
using System.Runtime.InteropServices;
public static class LocalizationNative {
    [DllImport("kernel32.dll", SetLastError=true)]
    private static extern IntPtr OpenProcess(uint access, bool inherit, int id);
    [DllImport("kernel32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
    private static extern bool QueryFullProcessImageName(IntPtr process, uint flags, StringBuilder path, ref int size);
    [DllImport("kernel32.dll")]
    private static extern bool CloseHandle(IntPtr handle);
    public static string TryGetProcessImagePath(int id) {
        IntPtr process = OpenProcess(0x1000, false, id);
        if (process == IntPtr.Zero) return null;
        try {
            int length = 32768;
            StringBuilder path = new StringBuilder(length);
            return QueryFullProcessImageName(process, 0, path, ref length) ? path.ToString() : null;
        } finally { CloseHandle(process); }
    }
    public static string ComputeSha256(string path) {
        using (FileStream file = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read, 1048576, FileOptions.SequentialScan))
        using (SHA256 sha = SHA256.Create()) {
            return BitConverter.ToString(sha.ComputeHash(file)).Replace("-", "").ToLowerInvariant();
        }
    }
}
'@
}

function Assert-NoReparse([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { throw '路径不能为空。' }
    $current = [IO.Path]::GetFullPath($Path)
    if ($current.StartsWith('\\')) { throw "拒绝网络路径：$current" }
    while ($current) {
        if (Test-Path -LiteralPath $current) {
            if ((Get-Item -LiteralPath $current -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw "拒绝重解析点路径：$current"
            }
        }
        $parent = Split-Path $current -Parent
        if ([string]::IsNullOrEmpty($parent) -or $parent -eq $current) { break }
        $current = $parent
    }
}

function Resolve-SafeChild([string]$Root, [string]$Relative) {
    if ([string]::IsNullOrWhiteSpace($Relative) -or [IO.Path]::IsPathRooted($Relative) -or $Relative.Contains(':')) {
        throw "非法相对路径：$Relative"
    }
    $base = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    $full = [IO.Path]::GetFullPath([IO.Path]::Combine($base, ($Relative -replace '/', '\')))
    if (-not $full.StartsWith($base + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw "路径越界：$Relative"
    }
    Assert-NoReparse $full
    return $full
}

function Get-FileSha256([string]$Path) {
    Assert-NoReparse $Path
    return [LocalizationNative]::ComputeSha256($Path)
}

function Write-Utf8NoBom([string]$Path, [string]$Content) {
    $dir = Split-Path $Path -Parent
    if ($dir -and -not [IO.Directory]::Exists($dir)) {
        [IO.Directory]::CreateDirectory($dir) | Out-Null
    }
    $enc = New-Object System.Text.UTF8Encoding($false)
    [IO.File]::WriteAllText($Path, $Content, $enc)
}

function Assert-FreeDiskSpace([string]$TargetDir, [long]$RequiredBytes) {
    if ($RequiredBytes -le 0) { return }
    $full = [IO.Path]::GetFullPath($TargetDir)
    $root = [IO.Path]::GetPathRoot($full)
    if ([string]::IsNullOrEmpty($root) -or $root.StartsWith('\\')) { return }
    $drive = New-Object System.IO.DriveInfo($root)
    $headroom = [long]67108864 # 64 MB safety headroom
    $needed = $RequiredBytes + $headroom
    if ($drive.AvailableFreeSpace -lt $needed) {
        $needMb = [Math]::Ceiling($needed / 1MB)
        $availMb = [Math]::Floor($drive.AvailableFreeSpace / 1MB)
        throw ("目标磁盘剩余空间不足（$($drive.Name)）：需要约 $needMb MB，当前仅剩 $availMb MB。")
    }
}

function Get-ProcessImagePathSafe([Diagnostics.Process]$Process) {
    $image = [LocalizationNative]::TryGetProcessImagePath($Process.Id)
    if (-not [string]::IsNullOrWhiteSpace($image)) { return $image }
    try {
        return $Process.MainModule.FileName
    } catch {
        return $null
    }
}

function Assert-ProcessesStopped(
    [string[]]$ProcessNames,
    [string[]]$PathScopes,
    [string]$FriendlyError,
    [string[]]$AlwaysRefuseNames = @()
) {
    $normalizedScopes = New-Object 'System.Collections.Generic.List[string]'
    foreach ($s in $PathScopes) {
        if ([string]::IsNullOrWhiteSpace($s)) { continue }
        $fullScope = [IO.Path]::GetFullPath($s).TrimEnd('\')
        $rootOnly = [IO.Path]::GetPathRoot($fullScope).TrimEnd('\')
        # Never treat a bare drive root like D:\ as a wildcard process scope.
        if ([string]::Equals($fullScope, $rootOnly, [StringComparison]::OrdinalIgnoreCase)) { continue }
        $normalizedScopes.Add($fullScope + '\')
    }

    foreach ($name in $ProcessNames) {
        $isAlwaysRefuse = ($AlwaysRefuseNames -contains $name)
        foreach ($proc in @([Diagnostics.Process]::GetProcessesByName($name))) {
            try {
                try {
                    if ($proc.HasExited) { continue }
                } catch {}

                $image = Get-ProcessImagePathSafe $proc
                if ([string]::IsNullOrWhiteSpace($image)) {
                    $stillAlive = $true
                    try {
                        $check = [Diagnostics.Process]::GetProcessById($proc.Id)
                        $check.Dispose()
                    } catch {
                        $stillAlive = $false
                    }
                    if (-not $stillAlive) { continue }
                    if ($isAlwaysRefuse) {
                        throw "$FriendlyError（无法读取进程路径：$name.exe，PID $($proc.Id)）"
                    }
                    Write-Warning "检测到同名进程 $name.exe (PID $($proc.Id)) 但无法读取其路径，将继续执行；若文件被占用将自动回滚。"
                    continue
                }

                $fullImage = [IO.Path]::GetFullPath($image)
                foreach ($scope in $normalizedScopes) {
                    if ($fullImage.StartsWith($scope, [StringComparison]::OrdinalIgnoreCase)) {
                        throw "$FriendlyError（$name.exe，PID $($proc.Id)）"
                    }
                }
            } finally {
                $proc.Dispose()
            }
        }
    }
}

function Assert-AllowedGameRelative([string]$Relative) {
    if ($Relative -eq 'resources.assets') { return }
    if ($Relative -match '^\.res/(?:raw_base_package|raw_streaming_package|default_package)/ManifestFiles/0release_(?:raw_base_package|raw_streaming_package|default_package)_\d+\.(?:bytes|hash)$') { return }
    if ($Relative -notmatch '^(?:\.res/(?:raw_base_package|raw_streaming_package|default_package)/BundleFiles|StreamingAssets/\.res/(?:default_package|static_package))/[a-z0-9]+\.r$') {
        throw "不允许写入：$Relative"
    }
}


function Get-ModuleState([string]$Path, [string]$Module) {
    if (-not [IO.File]::Exists($Path)) { return $null }
    Assert-NoReparse $Path
    $state = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($state.module -ne $Module -or $state.region -ne $Module.Substring(0, 2)) { throw ('备份区服记录不符：' + $Path) }
    return $state
}

function Save-ModuleState([string]$Path, [string]$Module, [string]$Action) {
    Assert-NoReparse $Path
    $null = Get-ModuleState $Path $Module
    $state = [ordered]@{ format = 1; module = $Module; region = $Module.Substring(0, 2); action = $Action; written_utc = [DateTime]::UtcNow.ToString('o') }
    $temporary = $Path + '.tmp-' + [Guid]::NewGuid().ToString('N')
    try {
        Write-Utf8NoBom $temporary ($state | ConvertTo-Json)
        if ([IO.File]::Exists($Path)) { [IO.File]::Replace($temporary, $Path, $null) }
        else { [IO.File]::Move($temporary, $Path) }
    } finally { if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) } }
}

function Assert-RequiredFiles([string[]]$Paths) {
    foreach ($path in $Paths) {
        Assert-NoReparse $path
        if (-not [IO.File]::Exists($path)) { throw ('缺少文件：' + $path) }
    }
}

function Test-PreserveExternalGameResource($Entry, [string]$DataDir) {
    if ($Entry -and $Entry.PSObject.Properties['preserve_with']) { $Entry = $Entry.preserve_with }
    if (-not $Entry -or -not $Entry.PSObject.Properties['preserve_external_changes'] -or -not $Entry.preserve_external_changes) { return $false }
    $file = Resolve-SafeChild $DataDir $Entry.relative_path
    if (-not [IO.File]::Exists($file)) { return $false }
    return ((Get-FileSha256 $file) -notin @($Entry.source_sha256, $Entry.target_sha256))
}

function Get-ManifestMergedBytes([byte[]]$SourceBytes, [string]$Target, $Ranges) {
    if (-not [IO.File]::Exists($Target)) { return ,$SourceBytes }
    $result = [IO.File]::ReadAllBytes($Target)
    if ($result.LongLength -ne $SourceBytes.LongLength) { throw ('资源清单结构已变化：' + $Target) }
    foreach ($range in $Ranges) {
        $offset = [long]$range.offset
        $length = [long]$range.length
        if ($offset -lt 0 -or $length -lt 1 -or $offset + $length -gt $result.LongLength) { throw '资源清单范围无效。' }
        [Array]::Copy($SourceBytes, $offset, $result, $offset, $length)
    }
    return ,$result
}

function Test-ManifestRanges([byte[]]$Bytes, $Ranges, [byte[]]$Reference = $null) {
    foreach ($range in $Ranges) {
        $offset = [int]$range.offset
        $length = [int]$range.length
        if ($offset -lt 0 -or $length -lt 1 -or [long]$offset + $length -gt $Bytes.LongLength) { return $false }
        $expected = [string]$range.target_hex
        if ($null -ne $Reference) {
            if ([long]$offset + $length -gt $Reference.LongLength) { return $false }
            $expected = [BitConverter]::ToString($Reference, $offset, $length).Replace('-', '')
        }
        if ([BitConverter]::ToString($Bytes, $offset, $length).Replace('-', '') -ne $expected) { return $false }
    }
    return $true
}

function Get-ManifestHashBytes([string]$Target, [string]$RelativePath, [string]$ManifestRelative) {
    Assert-AllowedGameRelative $ManifestRelative
    if ($ManifestRelative -notmatch '^\.res/default_package/ManifestFiles/0release_default_package_\d+\.bytes$') { throw '资源清单路径无效。' }
    $root = Split-PathPrefix $Target $RelativePath
    $manifest = Resolve-SafeChild $root $ManifestRelative
    Assert-NoReparse $manifest
    $stream = [IO.File]::OpenRead($manifest)
    $hasher = [Security.Cryptography.MD5]::Create()
    try { $digest = [BitConverter]::ToString($hasher.ComputeHash($stream)).Replace('-', '').ToLowerInvariant() }
    finally { $hasher.Dispose(); $stream.Dispose() }
    return ,[Text.Encoding]::ASCII.GetBytes($digest)
}

function Get-DeploymentFileState([string]$Path, $Entry, [string]$Backup = '') {
    if (-not [IO.File]::Exists($Path)) { return '文件不存在' }
    if ($Entry.PSObject.Properties['manifest_ranges']) {
        $bytes = [IO.File]::ReadAllBytes($Path)
        if (Test-ManifestRanges $bytes $Entry.manifest_ranges) { return '已汉化' }
        if ($Backup -and [IO.File]::Exists($Backup) -and (Test-ManifestRanges $bytes $Entry.manifest_ranges ([IO.File]::ReadAllBytes($Backup)))) { return '已还原' }
        return '非本版汉化'
    }
    if ($Entry.PSObject.Properties['manifest_hash_for']) {
        try {
            $expected = [Text.Encoding]::ASCII.GetString((Get-ManifestHashBytes $Path $Entry.relative_path $Entry.manifest_hash_for))
            if ([IO.File]::ReadAllText($Path).Trim() -eq $expected) { return '清单校验一致' }
        } catch {}
        return '清单校验不一致'
    }
    $hash = Get-FileSha256 $Path
    if ($hash -eq $Entry.target_sha256) { return '已汉化' }
    if ($Backup -and [IO.File]::Exists($Backup) -and $hash -eq (Get-FileSha256 $Backup)) { return '已还原' }
    return '非本版汉化'
}

function Get-GameBackupFiles([string]$BackupRoot) {
    if (-not [IO.Directory]::Exists($BackupRoot)) { return }
    Assert-NoReparse $BackupRoot
    $pending = New-Object 'System.Collections.Generic.Queue[string]'
    $pending.Enqueue($BackupRoot)
    while ($pending.Count) {
        $dir = $pending.Dequeue()
        foreach ($item in @(Get-ChildItem -LiteralPath $dir -Force)) {
            if ($dir -eq $BackupRoot -and $item.PSIsContainer -and $item.Name -eq 'transactions') { continue }
            Assert-NoReparse $item.FullName
            if ($item.PSIsContainer) { $pending.Enqueue($item.FullName); continue }
            $relative = $item.FullName.Substring($BackupRoot.TrimEnd('\').Length + 1).Replace('\', '/')
            if ($relative -eq '.localization-state.json') { continue }
            $absent = $relative.EndsWith('.zhcn-absent', [StringComparison]::OrdinalIgnoreCase)
            if ($absent) { $relative = $relative.Substring(0, $relative.Length - '.zhcn-absent'.Length) }
            Assert-AllowedGameRelative $relative
            [pscustomobject]@{ RelativePath = $relative; Source = $item.FullName; Delete = $absent }
        }
    }
}

function Invoke-DeploymentCopies($Operations, [scriptblock]$AssertStopped) {
    $done = New-Object 'System.Collections.Generic.List[object]'
    $temporaryFiles = New-Object 'System.Collections.Generic.List[string]'
    $preserveRollback = $false
    $activeName = ''
    try {
        foreach ($op in $Operations) {
            $activeName = $op.RelativePath
            & $AssertStopped
            Assert-NoReparse $op.Target
            if ($op.PSObject.Properties['PreserveEntry'] -and (Test-PreserveExternalGameResource $op.PreserveEntry (Split-PathPrefix $op.Target $op.RelativePath))) {
                Write-Host ('已保留外部修改的共享资源：' + $op.RelativePath) -ForegroundColor DarkGray
                continue
            }
            $exists = [IO.File]::Exists($op.Target)
            $before = if ($exists) { Get-FileSha256 $op.Target } else { '' }
            $token = [Guid]::NewGuid().ToString('N')
            $stage = $op.Target + '.zhcn-stage-' + $token
            $rollback = $op.Target + '.zhcn-rollback-' + $token
            $temporaryFiles.Add($stage); $temporaryFiles.Add($rollback)
            $record = [pscustomobject]@{ Target = $op.Target; Rollback = $rollback; Existed = $exists; Before = $before }
            if ($op.PSObject.Properties['Delete'] -and $op.Delete) {
                if (-not $exists) { continue }
                [IO.File]::Move($op.Target, $rollback)
                $done.Add($record)
                Write-Host ('已移除本次补丁新增文件：' + $op.RelativePath)
                continue
            }
            Assert-NoReparse $op.Source
            $expected = Get-FileSha256 $op.Source
            if ($op.PSObject.Properties['PayloadEntry'] -and $op.PayloadEntry) {
                if ($expected -ne $op.PayloadEntry.target_sha256) { throw ('补丁文件损坏：' + $op.Source) }
            }
            $content = $null
            $entry = if ($op.PSObject.Properties['PreserveEntry']) { $op.PreserveEntry } else { $null }
            if ($entry -and $entry.PSObject.Properties['manifest_ranges']) {
                $content = Get-ManifestMergedBytes ([IO.File]::ReadAllBytes($op.Source)) $op.Target $entry.manifest_ranges
            } elseif ($entry -and $entry.PSObject.Properties['manifest_hash_for']) {
                $content = Get-ManifestHashBytes $op.Target $op.RelativePath $entry.manifest_hash_for
            }
            if ($null -ne $content) {
                $hasher = [Security.Cryptography.SHA256]::Create()
                try { $expected = [BitConverter]::ToString($hasher.ComputeHash($content)).Replace('-', '').ToLowerInvariant() }
                finally { $hasher.Dispose() }
            }
            if ($exists -and $before -eq $expected) {
                if ($op.Backup -and -not [IO.File]::Exists($op.Backup) -and -not [IO.File]::Exists($op.Backup + '.zhcn-absent')) {
                    Write-Host ('提示：已汉化文件没有操作前备份：' + $op.RelativePath) -ForegroundColor Yellow
                }
                continue
            }
            $sourceSize = if ($null -ne $content) { $content.LongLength } else { [long](Get-Item -LiteralPath $op.Source).Length }
            $oldSize = if ($exists) { [long](Get-Item -LiteralPath $op.Target).Length } else { [long]0 }
            Assert-FreeDiskSpace (Split-Path $op.Target -Parent) ($sourceSize + 2 * $oldSize)
            [IO.Directory]::CreateDirectory((Split-Path $op.Target -Parent)) | Out-Null
            if ($null -ne $content) { [IO.File]::WriteAllBytes($stage, $content) }
            else { [IO.File]::Copy($op.Source, $stage, $false) }
            if ((Get-FileSha256 $stage) -ne $expected) { throw ('复制不完整：' + $op.Source) }
            if ($op.Backup) {
                Assert-NoReparse $op.Backup
                $absent = $op.Backup + '.zhcn-absent'
                Assert-NoReparse $absent
                if ([IO.File]::Exists($op.Backup) -and [IO.File]::Exists($absent)) { throw ('备份记录冲突：' + $op.Backup) }
                if (-not [IO.File]::Exists($op.Backup) -and -not [IO.File]::Exists($absent)) {
                    [IO.Directory]::CreateDirectory((Split-Path $op.Backup -Parent)) | Out-Null
                    if ($exists) {
                        $backupStage = $op.Backup + '.tmp-' + $token
                        $temporaryFiles.Add($backupStage)
                        [IO.File]::Copy($op.Target, $backupStage, $false)
                        if ((Get-FileSha256 $backupStage) -ne $before) { throw ('备份不完整：' + $op.Target) }
                        [IO.File]::Move($backupStage, $op.Backup)
                    } else { Write-Utf8NoBom $absent '文件原先不存在。' }
                }
            }
            & $AssertStopped
            Assert-NoReparse $op.Target
            $existsNow = [IO.File]::Exists($op.Target)
            if ($existsNow -ne $exists -or ($existsNow -and (Get-FileSha256 $op.Target) -ne $before)) { throw ('操作期间文件发生变化：' + $op.Target) }
            if ($exists) { [IO.File]::Replace($stage, $op.Target, $rollback, $true) }
            else { [IO.File]::Move($stage, $op.Target) }
            $done.Add($record)
            if ((Get-FileSha256 $op.Target) -ne $expected) { throw ('写入不完整：' + $op.Target) }
            Write-Host ('已写入：' + $op.RelativePath)
        }
    } catch {
        $reason = $activeName + '：' + $_.Exception.Message
        $failures = New-Object 'System.Collections.Generic.List[string]'
        for ($i = $done.Count - 1; $i -ge 0; $i--) {
            $record = $done[$i]
            try {
                Assert-NoReparse $record.Target
                if ($record.Existed) {
                    Assert-NoReparse $record.Rollback
                    [IO.File]::Copy($record.Rollback, $record.Target, $true)
                    if ((Get-FileSha256 $record.Target) -ne $record.Before) { throw '回滚内容不一致' }
                } elseif ([IO.File]::Exists($record.Target)) { [IO.File]::Delete($record.Target) }
            } catch { $failures.Add($record.Target + '：' + $_.Exception.Message) }
        }
        if ($failures.Count) {
            $preserveRollback = $true
            throw ('回滚失败，请保留备份及 .zhcn-rollback 文件：' + ($failures -join '；') + '；原错误：' + $reason)
        }
        throw ('已回滚到操作前：' + $reason)
    } finally {
        foreach ($path in $temporaryFiles) {
            if ($preserveRollback -and $path.Contains('.zhcn-rollback-')) { continue }
            if ([IO.File]::Exists($path)) { try { Assert-NoReparse $path; [IO.File]::Delete($path) } catch {} }
        }
    }
    return $done.Count
}

function Split-PathPrefix([string]$Path, [string]$Relative) {
    $relativePath = ($Relative -replace '/', '\')
    return $Path.Substring(0, $Path.Length - $relativePath.Length).TrimEnd('\')
}

function Invoke-GameCRCZH {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Config,
        [Parameter(Mandatory = $true)][string]$Action,
        [string]$Hint = '', [bool]$HintExplicit = $false,
        [string]$ToolsDir, [string]$PackRoot
    )
    try { [Console]::OutputEncoding = New-Object Text.UTF8Encoding($false) } catch {}
    $planPath = Join-Path $ToolsDir $Config.DeploymentFile
    if (-not [IO.File]::Exists($planPath) -and $Config.FallbackDeploymentFile) { $planPath = Join-Path $ToolsDir $Config.FallbackDeploymentFile }
    Assert-NoReparse $planPath
    $plan = Get-Content -LiteralPath $planPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($plan.region -ne $Config.Region) { throw ('部署清单区服不符：' + $Config.Region) }
    if ($plan.PSObject.Properties['backup_dir']) {
        if ($plan.backup_dir -notmatch ('^\.(?:zhcn-' + $Config.Region + '|' + $Config.Region + '-deblur)-\d+-backup$')) { throw '备份目录无效。' }
        $Config.BackupDirName = $plan.backup_dir
    }
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in $plan.files) {
        Assert-AllowedGameRelative $entry.relative_path
        if (-not $seen.Add($entry.relative_path)) { throw ('重复资源路径：' + $entry.relative_path) }
    }
    $payloadRoot = Join-Path $PackRoot $Config.PayloadSubdir
    if ($Action -eq 'ValidatePayload') {
        foreach ($entry in $plan.files) {
            $file = Resolve-SafeChild $payloadRoot $entry.relative_path
            if ((Get-FileSha256 $file) -ne $entry.target_sha256) { throw ('补丁文件损坏：' + $file) }
        }
        Write-Host '所选功能的补丁完整性检查通过。'
        return 0
    }
    $restore = $Action -eq 'Restore'
    $candidates = New-Object 'System.Collections.Generic.List[string]'
    if ($HintExplicit) {
        if ([string]::IsNullOrWhiteSpace($Hint) -or -not [IO.Path]::IsPathRooted($Hint.Trim().Trim('"'))) { throw '请指定安装目录的绝对路径。' }
        $h = [IO.Path]::GetFullPath($Hint.Trim().Trim('"'))
        if ([IO.File]::Exists($h)) { $h = Split-Path $h -Parent }
        if ((Split-Path $h -Leaf) -eq $Config.DataDirName) { $h = Split-Path $h -Parent }
        $candidates.Add($h)
        foreach ($relative in $Config.HintRelatives) { $candidates.Add((Join-Path $h $relative)) }
    } else {
        foreach ($drive in [IO.DriveInfo]::GetDrives()) {
            if (-not $drive.IsReady -or $drive.DriveType -ne [IO.DriveType]::Fixed) { continue }
            foreach ($relative in $Config.SearchRelatives) { $candidates.Add((Join-Path $drive.RootDirectory.FullName $relative)) }
        }
    }
    $found = New-Object 'System.Collections.Generic.List[string]'
    foreach ($candidate in @($candidates | Select-Object -Unique)) {
        if (-not [IO.Directory]::Exists($candidate)) { continue }
        if (-not $HintExplicit -and -not $restore -and (-not [IO.File]::Exists((Join-Path $candidate $Config.ExeName)) -or -not [IO.Directory]::Exists((Join-Path $candidate $Config.DataDirName)))) { continue }
        $actual = Get-GameInstallRegion $candidate -AllowBackup:$restore
        if ($actual -eq $Config.Region) { $found.Add([IO.Path]::GetFullPath($candidate)) }
        elseif ($HintExplicit -and $candidate -eq $h -and $actual) { Assert-GameInstallRegion $candidate $Config.Region }
    }
    if ($found.Count -gt 1) { throw ('找到多个安装目录，请指定其中一个：' + ($found -join '；')) }
    if (-not $found.Count) {
        if ($HintExplicit) { Assert-GameInstallRegion $h $Config.Region -AllowBackup:$restore }
        throw $Config.NotFoundMsg
    }
    $root = $found[0]
    Assert-GameInstallRegion $root $Config.Region -AllowBackup:$restore
    $data = Resolve-SafeChild $root $Config.DataDirName
    $backup = Resolve-SafeChild $root $Config.BackupDirName
    $module = $Config.Region + $(if ($Config.PayloadSubdir.EndsWith('_deblur')) { '_deblur' } else { '_game' })
    $statePath = Join-Path $backup '.localization-state.json'
    $null = Get-ModuleState $statePath $module
    Write-Host ('区服已确认：' + $Config.RegionLabel + '  ' + $root)
    if ($Action -eq 'Menu') {
        Write-Host '1 汉化   2 还原   3 检查区服   其他退出'
        switch ((Read-Host '选择').Trim()) { '1' { $Action = 'Apply' }; '2' { $Action = 'Restore' }; '3' { $Action = 'Verify' }; default { return 0 } }
    }
    if ($Action -eq 'Verify') { Write-Host '区服检查通过；未进行版本或全文件校验。'; return 0 }
    $assertStopped = { Assert-ProcessesStopped -ProcessNames @($Config.GameProcName) -PathScopes @($root) -FriendlyError '请先完全退出游戏' -AlwaysRefuseNames @($Config.GameProcName) }
    $operations = @()
    if ($Action -eq 'Restore') {
        $saved = @(Get-GameBackupFiles $backup)
        $seenRestore = @{}
        foreach ($item in @($saved | Sort-Object @{ Expression = { if ($_.RelativePath.EndsWith('.hash')) { 1 } else { 0 } } }, RelativePath)) {
            if ($seenRestore.ContainsKey($item.RelativePath)) { throw ('备份记录冲突：' + $item.RelativePath) }
            $seenRestore[$item.RelativePath] = $true
            $entries = @($plan.files | Where-Object { $_.relative_path -eq $item.RelativePath })
            $entry = if ($entries.Count) { $entries[0] } else { $null }
            $operations += [pscustomobject]@{ Source = $item.Source; Target = (Resolve-SafeChild $data $item.RelativePath); Backup = ''; RelativePath = $item.RelativePath; Delete = $item.Delete; PreserveEntry = $entry }
        }
        if (-not $saved.Count) { Write-Host 'NO_BACKUP 未找到可还原备份，未修改。'; return 0 }
    } else {
        foreach ($entry in $plan.files) {
            $operations += [pscustomobject]@{ Source = (Resolve-SafeChild $payloadRoot $entry.relative_path); Target = (Resolve-SafeChild $data $entry.relative_path); Backup = (Resolve-SafeChild $backup $entry.relative_path); RelativePath = $entry.relative_path; PayloadEntry = $entry; PreserveEntry = $entry }
        }
    }
    $changed = Invoke-DeploymentCopies $operations $assertStopped
    try { Save-ModuleState $statePath $module $Action } catch { Write-Warning ('操作记录未保存，请保留备份：' + $_.Exception.Message) }
    if ($Action -eq 'Restore') {
        if ($changed) { Write-Host ('还原完成：已处理可用备份，恢复或移除 ' + $changed + ' 项。') -ForegroundColor Green }
        else { Write-Host 'ALREADY_ORIGINAL 已与备份一致，无需修改。' -ForegroundColor Green }
    } else {
        if ($changed) { Write-Host ('汉化完成：已写入 ' + $changed + ' 个文件。') -ForegroundColor Green }
        else { Write-Host 'ALREADY_CURRENT 无需写入，文件已一致或已保留外部共享资源。' -ForegroundColor Green }
    }
    return 0
}

. (Join-Path $PSScriptRoot 'Region-Identity.ps1')
