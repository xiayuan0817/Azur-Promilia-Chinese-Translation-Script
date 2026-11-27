param([switch]$CheckOnly)

$ErrorActionPreference = 'Stop'
$script:Upstream = 'xiayuan0817/Azur-Promilia-Chinese-Translation-Script'

function Get-UpdateSha256([string]$Path) {
    $stream = [IO.File]::OpenRead($Path)
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose(); $stream.Dispose() }
}

function Get-UpdateChild([string]$Root, [string]$Relative) {
    if ([string]::IsNullOrWhiteSpace($Relative) -or $Relative.Contains('\') -or $Relative.Contains(':')) {
        throw "更新包路径无效：$Relative"
    }
    foreach ($part in $Relative.Split('/')) {
        if (-not $part -or $part -in @('.', '..') -or $part -match '[<>"|?*\x00-\x1f]' -or
            $part -match '[. ]$' -or $part -match '^(?i:CON|PRN|AUX|NUL|COM[0-9]|LPT[0-9])(?:\.|$)') {
            throw "更新包路径无效：$Relative"
        }
    }
    $base = [IO.Path]::GetFullPath($Root).TrimEnd('\')
    $path = [IO.Path]::GetFullPath((Join-Path $base $Relative.Replace('/', '\')))
    if (-not $path.StartsWith($base + '\', [StringComparison]::OrdinalIgnoreCase)) { throw '更新路径超出汉化包目录。' }
    $probe = $path
    while ($probe) {
        if (Test-Path -LiteralPath $probe) {
            if ((Get-Item -LiteralPath $probe -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw "更新路径包含目录联接或符号链接：$probe"
            }
        }
        $parent = [IO.Path]::GetDirectoryName($probe)
        if ($parent -eq $probe) { break }
        $probe = $parent
    }
    return $path
}

function Get-UpstreamAsset($Release) {
    if ($Release.draft -or $Release.prerelease -or [string]$Release.tag_name -notmatch '^[A-Za-z0-9._-]+$') {
        throw '上游正式版本信息无效。'
    }
    $name = 'AzurPromilia-Localization-Full-' + $Release.tag_name + '.zip'
    $assets = @($Release.assets | Where-Object { $_.name -ceq $name })
    if ($assets.Count -ne 1) { throw "上游版本缺少唯一的完整包：$name" }
    $asset = $assets[0]
    $expectedUrl = 'https://github.com/' + $script:Upstream + '/releases/download/' + $Release.tag_name + '/' + $name
    if ([string]$asset.browser_download_url -cne $expectedUrl -or ($null -ne $asset.size -and [long]$asset.size -le 0) -or
        [string]$asset.digest -notmatch '^sha256:[a-fA-F0-9]{64}$') {
        throw '上游完整包的下载地址、大小或 SHA-256 无效，未执行更新。'
    }
    return $asset
}

function ConvertFrom-UpstreamPage([string]$Html, [string]$Tag) {
    if ($Tag -notmatch '^[A-Za-z0-9._-]+$') { throw '上游版本名称无效。' }
    $name = 'AzurPromilia-Localization-Full-' + $Tag + '.zip'
    $relativeUrl = '/' + $script:Upstream + '/releases/download/' + $Tag + '/' + $name
    $rows = @([regex]::Matches($Html, '(?s)<li\b[^>]*>.*?</li>') | Where-Object {
        $_.Value -cmatch ('href="' + [regex]::Escape($relativeUrl) + '"')
    })
    if ($rows.Count -ne 1) { throw 'GitHub 发布页未找到唯一的完整包。' }
    $hashMatch = [regex]::Match($rows[0].Value, '<clipboard-copy\b[^>]*\bvalue="(sha256:[a-fA-F0-9]{64})"')
    if (-not $hashMatch.Success) { throw 'GitHub 发布页缺少完整包 SHA-256。' }
    return [pscustomobject]@{ tag_name = $Tag; assets = @([pscustomobject]@{
        name = $name; size = $null; id = $null; digest = $hashMatch.Groups[1].Value
        browser_download_url = 'https://github.com' + $relativeUrl
    }) }
}

function Get-UpstreamRelease($Headers, [switch]$Silent) {
    $ProgressPreference = 'SilentlyContinue'
    try {
        $index = Invoke-RestMethod -Uri ('https://raw.githubusercontent.com/' + $script:Upstream + '/main/update.json') -Headers $Headers -TimeoutSec 15
        if ($index.format -ne 1 -or $index.repository -cne $script:Upstream -or
            [string]$index.manifest_sha256 -notmatch '^[a-fA-F0-9]{64}$') { throw '上游更新索引无效。' }
        $null = Get-UpstreamAsset $index.release
        $index.release | Add-Member -NotePropertyName manifest_sha256 -NotePropertyValue $index.manifest_sha256 -Force
        return $index.release
    } catch {}
    try {
        return Invoke-RestMethod -Uri ('https://api.github.com/repos/' + $script:Upstream + '/releases/latest') -Headers $Headers -TimeoutSec 45
    } catch {
        if (-not $Silent) { Write-Host '正在通过 GitHub 发布页检查更新……' -ForegroundColor DarkGray }
        $base = 'https://github.com/' + $script:Upstream
        $page = Invoke-WebRequest -UseBasicParsing -Uri ($base + '/releases/latest') -TimeoutSec 45
        $tagMatch = [regex]::Match($page.Content, [regex]::Escape('/' + $script:Upstream + '/releases/expanded_assets/') + '([A-Za-z0-9._-]+)"')
        if (-not $tagMatch.Success) { throw 'GitHub 发布页未找到正式版本信息。' }
        $tag = $tagMatch.Groups[1].Value
        $assetsPage = Invoke-WebRequest -UseBasicParsing -Uri ($base + '/releases/expanded_assets/' + $tag) -TimeoutSec 45
        return ConvertFrom-UpstreamPage $assetsPage.Content $tag
    }
}

function ConvertTo-UpdateVersion([string]$Tag) {
    if ($Tag -notmatch '^[vV]?(\d+(?:\.\d+){0,3})$') { return $null }
    $parts = @($Matches[1].Split('.'))
    while ($parts.Count -lt 4) { $parts += '0' }
    try { return [version]($parts -join '.') } catch { return $null }
}

function Compare-UpdateVersion([string]$Root, [string]$RemoteTag) {
    $localTag = ''
    try {
        $catalog = Get-Content -LiteralPath (Get-UpdateChild $Root 'tools/package-files.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        $localTag = [string]$catalog.version
    } catch {}
    if (-not $localTag) {
        try { $localTag = [string](Get-Content -LiteralPath (Get-UpdateChild $Root 'tools/update-state.json') -Raw -Encoding UTF8 | ConvertFrom-Json).tag } catch {}
    }
    $local = ConvertTo-UpdateVersion $localTag
    $remote = ConvertTo-UpdateVersion $RemoteTag
    if ($null -eq $local -or $null -eq $remote) { return $null }
    return $local.CompareTo($remote)
}

function Get-LocalizationUpdateStatus([string]$Root) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $headers = @{ 'User-Agent' = 'AzurPromilia-Localization-Updater'; 'Accept' = 'application/vnd.github+json'; 'X-GitHub-Api-Version' = '2022-11-28' }
    $release = Get-UpstreamRelease $headers -Silent
    $asset = Get-UpstreamAsset $release
    $digest = ([string]$asset.digest).Substring(7).ToLowerInvariant()
    $status = 'Unknown'
    $comparison = Compare-UpdateVersion $Root ([string]$release.tag_name)
    $catalogPath = Get-UpdateChild $Root 'tools/package-files.json'
    if ($null -ne $comparison) {
        $status = if ($comparison -lt 0) { 'Available' } else { 'Current' }
    } elseif ($release.manifest_sha256 -and [IO.File]::Exists($catalogPath) -and (Get-UpdateSha256 $catalogPath) -ieq $release.manifest_sha256) {
        $status = 'Current'
    } else {
        try {
            $state = Get-Content -LiteralPath (Get-UpdateChild $Root 'tools/update-state.json') -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($state.repository -ceq $script:Upstream -and $state.sha256 -ceq $digest) { $status = 'Current' }
        } catch {}
    }
    return [pscustomobject]@{ State = $status; Tag = [string]$release.tag_name; Asset = $asset }
}

function Read-UpdateCatalog([string]$Root) {
    $file = Get-UpdateChild $Root 'tools/package-files.json'
    $catalog = Get-Content -LiteralPath $file -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($catalog.format -ne 1 -or $catalog.hash -cne 'SHA256' -or -not @($catalog.files).Count) {
        throw '更新包文件清单无效。'
    }
    $seen = @{}
    foreach ($entry in $catalog.files) {
        $relative = [string]$entry.path
        $null = Get-UpdateChild $Root $relative
        if ($seen.ContainsKey($relative) -or $relative -match '^(?i:tools/(?:安装路径\.json|logs(?:/|$)|update-state\.json|\.update\.lock)|\.git(?:/|$))' -or
            $relative -ieq 'tools/package-files.json' -or [long]$entry.size -lt 0 -or
            [string]$entry.sha256 -notmatch '^[a-fA-F0-9]{64}$') {
            throw "更新包清单条目无效：$relative"
        }
        $seen[$relative] = $true
    }
    foreach ($required in @('双击运行.bat', 'tools/Manage-Localization.ps1', 'tools/Update-Localization.ps1')) {
        if (-not $seen.ContainsKey($required)) { throw "更新包缺少必要文件：$required" }
    }
    return $catalog
}

function Assert-UpdateFiles([string]$Root, $Catalog) {
    foreach ($entry in $Catalog.files) {
        $file = Get-UpdateChild $Root ([string]$entry.path)
        if (-not [IO.File]::Exists($file) -or (Get-Item -LiteralPath $file).Length -ne [long]$entry.size -or
            (Get-UpdateSha256 $file) -ine [string]$entry.sha256) {
            throw "更新包文件校验失败：$($entry.path)"
        }
    }
}

function Expand-UpdatePackage([string]$Archive, [string]$Destination) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Directory]::CreateDirectory($Destination) | Out-Null
    $zip = [IO.Compression.ZipFile]::OpenRead($Archive)
    $seen = @{}
    $total = [long]0
    try {
        foreach ($entry in $zip.Entries) {
            $name = $entry.FullName
            if (-not $name.StartsWith('蓝色星原简体汉化/', [StringComparison]::Ordinal)) { throw '更新压缩包的顶层目录无效。' }
            $relative = $name.Substring('蓝色星原简体汉化/'.Length).TrimEnd('/')
            if (-not $relative) { continue }
            $path = Get-UpdateChild $Destination $relative
            if ($seen.ContainsKey($relative)) { throw "更新压缩包包含重复路径：$relative" }
            $seen[$relative] = $true
            if ((($entry.ExternalAttributes -shr 16) -band 61440) -eq 40960 -or
                ($entry.ExternalAttributes -band 1024)) { throw '更新压缩包不允许包含链接。' }
            if ($name.EndsWith('/')) { [IO.Directory]::CreateDirectory($path) | Out-Null; continue }
            $total += $entry.Length
            if ($total -gt 8GB -or $zip.Entries.Count -gt 10000) { throw '更新压缩包超出大小或文件数量限制。' }
            [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path)) | Out-Null
            $inputStream = $entry.Open()
            try {
                $outputStream = [IO.File]::Open($path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write)
                try { $inputStream.CopyTo($outputStream) } finally { $outputStream.Dispose() }
            } finally { $inputStream.Dispose() }
        }
    } finally { $zip.Dispose() }
    $catalog = Read-UpdateCatalog $Destination
    $allowed = @{'tools/package-files.json' = $true; 'tools/安装路径.json' = $true}
    foreach ($entry in $catalog.files) { $allowed[[string]$entry.path] = $true }
    foreach ($file in Get-ChildItem -LiteralPath $Destination -File -Recurse -Force) {
        $relative = $file.FullName.Substring($Destination.TrimEnd('\').Length + 1).Replace('\', '/')
        if (-not $allowed.ContainsKey($relative)) { throw "更新压缩包存在未登记文件：$relative" }
    }
    Assert-UpdateFiles $Destination $catalog
    return $catalog
}

function Install-UpdatePackage([string]$Root, [string]$Staged, [string]$Backup, $Catalog, $State) {
    $operations = New-Object System.Collections.ArrayList
    $newPaths = @{}
    foreach ($entry in $Catalog.files) { $newPaths[[string]$entry.path] = $true }
    $oldCatalog = $null
    try { $oldCatalog = Read-UpdateCatalog $Root } catch {}
    $paths = @($Catalog.files | ForEach-Object { [string]$_.path }) + @('tools/package-files.json', 'tools/update-state.json')
    foreach ($relative in $paths) { $null = Get-UpdateChild $Root $relative }
    $statePath = Get-UpdateChild $Staged 'tools/update-state.json'
    [IO.File]::WriteAllText($statePath, ($State | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding($false)))
    try {
        if ($oldCatalog) {
            foreach ($entry in $oldCatalog.files) {
                $relative = [string]$entry.path
                if ($newPaths.ContainsKey($relative)) { continue }
                $old = Get-UpdateChild $Root $relative
                if ([IO.File]::Exists($old) -and (Get-Item -LiteralPath $old).Length -eq [long]$entry.size -and
                    (Get-UpdateSha256 $old) -ieq [string]$entry.sha256) {
                    $saved = Get-UpdateChild $Backup $relative
                    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($saved)) | Out-Null
                    [IO.File]::Move($old, $saved)
                    $null = $operations.Add([pscustomobject]@{ Target = $old; Saved = $saved; Installed = $false })
                }
            }
        }
        foreach ($relative in $paths) {
            $source = Get-UpdateChild $Staged $relative
            $target = Get-UpdateChild $Root $relative
            $saved = Get-UpdateChild $Backup $relative
            if ([IO.File]::Exists($target) -and (Get-UpdateSha256 $target) -eq (Get-UpdateSha256 $source)) { continue }
            [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target)) | Out-Null
            [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($saved)) | Out-Null
            $operation = [pscustomobject]@{ Target = $target; Saved = $null; Installed = $false }
            $null = $operations.Add($operation)
            if ([IO.File]::Exists($target)) { [IO.File]::Move($target, $saved); $operation.Saved = $saved }
            [IO.File]::Move($source, $target)
            $operation.Installed = $true
        }
        Assert-UpdateFiles $Root $Catalog
    } catch {
        $originalError = $_.Exception.Message
        $rollbackErrors = @()
        for ($i = $operations.Count - 1; $i -ge 0; $i--) {
            $operation = $operations[$i]
            try {
                if ($operation.Installed -and [IO.File]::Exists($operation.Target)) { [IO.File]::Delete($operation.Target) }
                if ($operation.Saved) { [IO.File]::Move($operation.Saved, $operation.Target) }
            } catch { $rollbackErrors += $_.Exception.Message }
        }
        if ($rollbackErrors.Count) {
            $script:KeepUpdateWork = $true
            throw ("更新失败：$originalError`n部分文件未能还原，请保留备份：$Backup`n" + ($rollbackErrors -join "`n"))
        }
        throw "更新失败，已恢复原文件：$originalError"
    }
}

function Invoke-LocalizationUpdate([string]$Root, [switch]$Check) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $headers = @{ 'User-Agent' = 'AzurPromilia-Localization-Updater'; 'Accept' = 'application/vnd.github+json'; 'X-GitHub-Api-Version' = '2022-11-28' }
    Write-Host '正在检查 GitHub 上游正式版本……' -ForegroundColor Cyan
    $release = Get-UpstreamRelease $headers
    $asset = Get-UpstreamAsset $release
    $digest = ([string]$asset.digest).Substring(7).ToLowerInvariant()
    $state = $null
    try { $state = Get-Content -LiteralPath (Get-UpdateChild $Root 'tools/update-state.json') -Raw -Encoding UTF8 | ConvertFrom-Json } catch {}
    $sameBuild = $release.manifest_sha256 -and (Get-UpdateSha256 (Get-UpdateChild $Root 'tools/package-files.json')) -ieq $release.manifest_sha256
    Write-Host ('上游版本：' + $release.tag_name + '  完整包：' + $asset.name)
    $comparison = Compare-UpdateVersion $Root ([string]$release.tag_name)
    if ($null -ne $comparison -and $comparison -ge 0) {
        if ($comparison -eq 0) { Write-Host '当前已是最新版本。' -ForegroundColor Green }
        else { Write-Host '本地版本高于上游版本，无需更新。' -ForegroundColor Green }
        return $false
    }
    if ($sameBuild -or ($state -and $state.repository -ceq $script:Upstream -and $state.sha256 -ceq $digest)) {
        try {
            $catalog = Read-UpdateCatalog $Root
            Assert-UpdateFiles $Root $catalog
            Write-Host '当前汉化包已是上游版本，文件校验通过。' -ForegroundColor Green
            return $false
        } catch { Write-Host '当前包有文件缺失或变化，可重新同步修复。' -ForegroundColor Yellow }
    } else { Write-Host '有可用更新。' -ForegroundColor Yellow }
    if ($Check) { Write-Host '仅检查，未下载或修改文件。'; return $false }

    $lockPath = Get-UpdateChild $Root 'tools/.update.lock'
    $lock = $null
    $work = $null
    $script:KeepUpdateWork = $false
    $previousProgress = $ProgressPreference
    try {
        $lock = New-Object IO.FileStream($lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None, 4096, [IO.FileOptions]::DeleteOnClose)
        $work = Join-Path ([IO.Path]::GetDirectoryName($Root.TrimEnd('\'))) ('.azur-update-' + [guid]::NewGuid().ToString('N'))
        [IO.Directory]::CreateDirectory($work) | Out-Null
        $archive = Join-Path $work 'release.zip'
        $staged = Join-Path $work 'package'
        $backup = Join-Path $work 'backup'
        $ProgressPreference = 'SilentlyContinue'
        if ($null -ne $asset.size) {
            Write-Host ('正在下载完整包（约 {0:N0} MB）……' -f ([long]$asset.size / 1MB)) -ForegroundColor Cyan
        } else { Write-Host '正在下载完整包……' -ForegroundColor Cyan }
        Invoke-WebRequest -UseBasicParsing -Uri $asset.browser_download_url -Headers $headers -OutFile $archive -TimeoutSec 1800 | Out-Null
        if (($null -ne $asset.size -and (Get-Item -LiteralPath $archive).Length -ne [long]$asset.size) -or
            (Get-UpdateSha256 $archive) -ine $digest) { throw '下载包大小或 SHA-256 校验失败，未替换本地文件。' }
        Write-Host '正在校验并同步汉化包……' -ForegroundColor Cyan
        $catalog = Expand-UpdatePackage $archive $staged
        if ($null -ne $comparison -and (ConvertTo-UpdateVersion ([string]$catalog.version)) -ne (ConvertTo-UpdateVersion ([string]$release.tag_name))) {
            throw '下载包内部版本与上游版本不一致，未替换本地文件。'
        }
        $nextState = [ordered]@{ repository = $script:Upstream; tag = [string]$release.tag_name; asset_id = $asset.id; sha256 = $digest; updated_at = [DateTime]::UtcNow.ToString('o') }
        Install-UpdatePackage $Root $staged $backup $catalog $nextState
        Write-Host '汉化包已同步，安装路径和日志已保留。' -ForegroundColor Green
        Write-Host '正在重新加载脚本……'
    } finally {
        $ProgressPreference = $previousProgress
        if ($lock) { $lock.Dispose() }
        if ($work -and -not $script:KeepUpdateWork -and [IO.Directory]::Exists($work)) {
            try { [IO.Directory]::Delete($work, $true) } catch { Write-Warning ('更新临时文件未清理：' + $work) }
        }
    }
    return $true
}

if ($MyInvocation.InvocationName -ne '.') {
    try {
        try { [Console]::OutputEncoding = New-Object Text.UTF8Encoding($false) } catch {}
        $updated = Invoke-LocalizationUpdate -Root (Split-Path $PSScriptRoot -Parent) -Check:$CheckOnly
        if ($updated -and -not $CheckOnly) { exit 42 }
        exit 0
    } catch { Write-Host ('更新失败：' + $_.Exception.Message) -ForegroundColor Red; exit 1 }
}
