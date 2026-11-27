param(
    [ValidateSet('Menu', 'Apply', 'Restore', 'Verify', 'ValidatePayload', 'CheckPackage')][string]$Action = 'Menu',
    [ValidateSet('All', 'TW', 'JP', 'Launchers', 'Games', 'tw_game', 'jp_game', 'tw_launcher', 'jp_launcher', 'jp_deblur', 'tw_deblur')][string]$Target = 'All',
    [string]$Hint = '',
    [string]$PathsFile = '',
    [string[]]$ModuleIds,
    [switch]$OnlyHint,
    [switch]$Elevated,
    [switch]$Quiet,
    [switch]$ScriptsOnly,
    [string]$SummaryFile = ''
)
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false); $OutputEncoding = [Console]::OutputEncoding } catch {}

$PackRoot = Split-Path $PSScriptRoot -Parent
. (Join-Path $PSScriptRoot 'Localization-Common.ps1')

$Definitions = @(
    [pscustomobject]@{ Id = 'tw_game'; Label = '台服游戏'; Script = 'tools/Apply-CRCZH.ps1'; Launcher = $false },
    [pscustomobject]@{ Id = 'jp_game'; Label = '日服游戏'; Script = 'tools/Apply-JPCRCZH.ps1'; Launcher = $false },
    [pscustomobject]@{ Id = 'tw_launcher'; Label = '台服启动器'; Script = 'tools/Apply-Launchers.ps1'; Launcher = $true },
    [pscustomobject]@{ Id = 'jp_launcher'; Label = '日服启动器'; Script = 'tools/Apply-Launchers.ps1'; Launcher = $true }
)

$DeblurDefinitions = @(
    [pscustomobject]@{ Id = 'jp_deblur'; Label = '日服反虚化'; Script = 'tools/Apply-JPDeblur.ps1'; Launcher = $false },
    [pscustomobject]@{ Id = 'tw_deblur'; Label = '台服反虚化'; Script = 'tools/Apply-TWDeblur.ps1'; Launcher = $false }
)

function Child([string]$Relative) {
    return Resolve-SafeChild $PackRoot $Relative
}

function Sha([string]$Path) {
    return Get-FileSha256 $Path
}

function Assert-Package {
    param(
        [bool]$Silent = $false,
        [string]$Operation = 'CheckPackage',
        [string[]]$SelectedIds = @()
    )
    $catalog = Get-Content -LiteralPath (Child 'tools/package-files.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($catalog.format -ne 1 -or @($catalog.files).Count -lt 10) { throw '包校验清单格式无效。' }

    $seen = New-Object 'System.Collections.Hashtable' ([StringComparer]::OrdinalIgnoreCase)
    $checkPayloadAll = ($Operation -eq 'CheckPackage' -and -not $ScriptsOnly)
    $checkPayloadSelected = ($Operation -in @('Apply', 'ValidatePayload') -and -not $ScriptsOnly)

    if ($checkPayloadSelected) {
        $payloadDir = Join-Path $PackRoot 'payload'
        if (-not [IO.Directory]::Exists($payloadDir)) {
            throw '补丁载荷目录 payload 不存在，可能误下载了 GitHub 源码包；请前往 Releases 下载完整汉化包。'
        }
    }

    $checkedCount = 0
    foreach ($f in $catalog.files) {
        if ($seen.ContainsKey($f.path)) { throw "重复包路径：$($f.path)" }
        $seen[$f.path] = $true

        $isPayload = $false
        $payloadModule = ''
        if ($f.path -match '^payload/([^/]+)/') {
            $isPayload = $true
            $payloadModule = $Matches[1]
        }

        if ($isPayload) {
            if ($checkPayloadAll) {
                # verify
            } elseif ($checkPayloadSelected -and ($payloadModule -in $SelectedIds)) {
                # verify
            } else {
                continue
            }
        }

        $p = Child $f.path
        if (-not [IO.File]::Exists($p) -or (Get-Item -LiteralPath $p).Length -ne $f.size -or (Sha $p) -ne $f.sha256) {
            if ($isPayload -and -not [IO.File]::Exists($p)) {
                throw "补丁载荷文件缺失：$($f.path)（请确认完整解压 Releases 完整包，勿直接下载源码 ZIP）"
            }
            throw "包文件损坏/缺失：$($f.path)"
        }
        $checkedCount++
    }

    foreach ($d in (@($Definitions) + @($DeblurDefinitions))) {
        if (-not $seen.ContainsKey($d.Script)) { throw "未登记的模块入口：$($d.Script)" }
    }
    if (-not $seen.ContainsKey('tools/Localization-Common.ps1')) {
        throw '未登记的核心模块：tools/Localization-Common.ps1'
    }
    if (-not $Silent) { Write-Host ("整合包文件校验通过：{0} 个文件。" -f $checkedCount) -ForegroundColor Green }
}

function Selected([string]$Scope) {
    switch ($Scope) {
        'All' { return @($Definitions) }
        'TW' { return @($Definitions | Where-Object { $_.Id.StartsWith('tw_') }) }
        'JP' { return @($Definitions | Where-Object { $_.Id.StartsWith('jp_') }) }
        'Games' { return @($Definitions | Where-Object { -not $_.Launcher }) }
        'Launchers' { return @($Definitions | Where-Object { $_.Launcher }) }
        default { return @((@($Definitions) + @($DeblurDefinitions)) | Where-Object { $_.Id -eq $Scope }) }
    }
}

function Read-ConfiguredPaths {
    $pathMap = @{}
    $config = if ($PathsFile) { [IO.Path]::GetFullPath($PathsFile) } else { Child 'tools/安装路径.json' }
    if ([IO.File]::Exists($config)) {
        Assert-NoReparse $config
        $paths = Get-Content -LiteralPath $config -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($prop in $paths.PSObject.Properties) {
            if ($prop.Name -notin (@($Definitions.Id) + @($DeblurDefinitions.Id)) -or $prop.Value -isnot [string]) { throw "安装路径配置无效：$($prop.Name)" }
            if ($prop.Value.Contains([char]0) -or $prop.Value -match '[\r\n]') { throw '目录不能包含控制字符。' }
            $pathMap[$prop.Name] = $prop.Value
        }
    } elseif ($PathsFile) { throw "安装路径配置不存在：$config" }
    return $pathMap
}

function Save-ConfiguredPaths([hashtable]$PathMap) {
    $config = Child 'tools/安装路径.json'
    $ordered = [ordered]@{}
    foreach ($d in $Definitions) {
        $ordered[$d.Id] = if ($PathMap.ContainsKey($d.Id) -and $PathMap[$d.Id]) { [string]$PathMap[$d.Id] } else { '' }
    }
    Write-Utf8NoBom $config ($ordered | ConvertTo-Json -Depth 4)
}

function Get-FriendlyFailure([string]$Detail) {
    switch -Regex ($Detail) {
        'Launcher\s*runni\s*ng|请先完全退出|正在运行|Close\s+it\s+first' {
            $process = [regex]::Match($Detail, '(?i)\b(?:launcher|AZUPRO_JP_Gamelauncher|AzurPromiliaJP|AzurPromilia)\.exe\b').Value
            if ($process) { return ('未处理：' + $process + ' 未退出。') }
            if ($Detail -match 'Launcher\s*runni\s*ng|Close\s+it\s+first') { return '未处理：启动器未退出。' }
            return '未处理：启动器或游戏未退出。'
        }
        '剩余空间不足|There is not enough space' { return '未处理：目标磁盘剩余空间不足。' }
        'payload 不存在|误下载了 GitHub 源码包' { return '未处理：缺少 payload 替换资源，请下载 Releases 完整包。' }
        '已取消管理员权限|canceled by the user' { return '未完成：已取消管理员权限授权。' }
        'rollback.*(damaged|verification failed)|未能回滚|回滚失败' { return '失败：自动回滚失败，请保留备份。' }
        '游戏资源版本低于补丁基线|原版只读基线版本过低' { return '未处理：游戏资源版本低于补丁基线。' }
        '已修改目标资源段|分段补丁信息|目标资源段匹配不唯一' { return '未处理：游戏热更已修改目标汉化段，请等待新版汉化补丁。' }
        '清单 MD5 校验失败|清单包名或版本不匹配|YooAsset 清单' { return '未处理：游戏资源清单校验不通过。' }
        'Unknown launcher version|版本不匹配|基线不匹配|版本不符' { return '未处理：文件版本与本补丁不匹配。' }
        'Bad canonical backup|Verified original backup required|Backup verification failed|原版备份|缺少原版备份' { return '失败：原版备份缺失或校验不通过。' }
        'Bad payload|包文件损坏|载荷|补丁包文件缺失' { return '未处理：补丁文件缺失或损坏，请完整解压后重试。' }
        'Access.*denied|UnauthorizedAccess|拒绝访问|权限' { return '未完成：没有写入权限，请以管理员身份重试。' }
        'CRC.*不匹配|SHA256.*不匹配|大小不匹配|verification failed' { return '失败：文件校验不通过。' }
        'Concurrent modification' { return '失败：文件被其他程序修改。' }
        default {
            $line = @($Detail -split '[\r\n]+' | Where-Object {
                    $_.Trim() -and $_ -notmatch '^\s*(\+|~|At |所在位置|CategoryInfo|FullyQualifiedErrorId|PositionMessage|ScriptStackTrace)'
                } | Select-Object -Last 1)
            if ($line.Count) {
                $reason = ($line[0] -replace '^.*?\.ps1\s*:\s*', '').Trim()
                if ($reason.Length -gt 140) { $reason = $reason.Substring(0, 140) + '…' }
                return ('失败：' + $reason)
            }
            return '失败：子任务未返回错误原因。'
        }
    }
}

function Run-Modules([string]$Operation, [string]$Scope, [string[]]$Ids, [hashtable]$MenuLocations, [bool]$Silent = $false) {
    $selected = @(Selected $Scope)
    if ($Scope -eq 'All' -and $Ids) { $selected += @($DeblurDefinitions | Where-Object { $_.Id -in $Ids }) }
    if ($Ids) { $selected = @($selected | Where-Object { $_.Id -in $Ids }) }
    if ($Operation -ne 'CheckPackage' -and -not $selected.Count) { throw '没有可操作的项目。' }

    Assert-Package -Silent $Silent -Operation $Operation -SelectedIds @($selected.Id)
    if ($Operation -eq 'CheckPackage') { return 0 }

    if ($Hint -and -not $MenuLocations -and $selected.Count -ne 1) {
        throw '-Hint 只适用于单个模块；多个目录请编辑安装路径.json 或使用 -PathsFile。'
    }
    $pathMap = Read-ConfiguredPaths
    $locations = $null
    if ($Operation -ne 'ValidatePayload') {
        if ($MenuLocations) { $locations = $MenuLocations }
        elseif (-not $Hint) { $locations = Find-InstallLocations $selected $pathMap }
    }
    $runId = [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss') + '-' + [Guid]::NewGuid().ToString('N').Substring(0, 8)
    $logDir = Child ('tools/logs/' + $runId)
    [IO.Directory]::CreateDirectory($logDir) | Out-Null
    $results = New-Object 'System.Collections.Generic.List[object]'
    $summaryLines = New-Object 'System.Collections.Generic.List[object]'
    $shell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

    foreach ($d in $selected) {
        if (-not $Silent) { Write-Host ("`n=== {0} / {1} ===" -f $d.Label, $Operation) -ForegroundColor Cyan }
        $started = [DateTime]::UtcNow.ToString('o'); $code = 1; $errorText = $null; $unchanged = $false
        $log = Join-Path $logDir ($d.Id + '.log')
        try {
            $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Child $d.Script), '-Action', $Operation)
            if ($d.Launcher) { $arguments += @('-Target', $d.Id) }
            $moduleHint = ''
            if ($Operation -ne 'ValidatePayload') {
                if ($Hint -and -not $MenuLocations) { $moduleHint = $Hint }
                else {
                    $location = $locations[$d.Id]
                    if ($location.State -ne 'found') { throw ($d.Label + '：' + $location.Problem) }
                    $moduleHint = $location.Path
                }
            }
            if ($moduleHint) { $arguments += @('-Hint', $moduleHint) }
            $savedPreference = $ErrorActionPreference
            try {
                $ErrorActionPreference = 'Continue'
                $output = @(& $shell @arguments 2>&1)
                $code = $LASTEXITCODE
            } finally { $ErrorActionPreference = $savedPreference }
            $capturedText = (@($output | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine)
            $unchanged = ($code -eq 0 -and $Operation -in @('Apply', 'Restore') -and
                $capturedText -match '(?m)^(?:ALREADY_(?:CURRENT|ORIGINAL)\s|所有文件均已处于目标状态，无需修改。)')
            Write-Utf8NoBom $log $capturedText
            if ($code -ne 0) { $errorText = $capturedText.Trim() }
            if (-not $Silent) { foreach ($line in $output) { Write-Host $line } }
        } catch {
            $errorText = $_.Exception.Message
            if (-not $Silent) { Write-Host $errorText -ForegroundColor Red }
            Write-Utf8NoBom $log $errorText
        }
        $results.Add([pscustomobject]@{
                module      = $d.Id
                label       = $d.Label
                action      = $Operation
                exit_code   = $code
                success     = ($code -eq 0)
                skipped     = $unchanged
                changed     = if ($code -eq 0 -and $Operation -in @('Apply', 'Restore')) { -not $unchanged } else { $null }
                started_utc = $started
                ended_utc   = [DateTime]::UtcNow.ToString('o')
                log         = $log
                error       = $errorText
            })

        $statusColor = if ($code -eq 0) { 'Green' } else { 'Yellow' }
        $statusText = if ($code -eq 0) {
            $verb = if ($unchanged) {
                if ($Operation -eq 'Restore') { '已还原，跳过' } elseif ($d.Id -in $DeblurDefinitions.Id) { '已反虚化，跳过' } else { '已汉化，跳过' }
            } else {
                switch ($Operation) { 'Restore' { '还原完成' } 'Apply' { if ($d.Id -in $DeblurDefinitions.Id) { '反虚化完成' } else { '汉化完成' } } default { '校验通过' } }
            }
            ('  [{0}] {1}。' -f $d.Label, $verb)
        } else {
            ('  [{0}] {1}' -f $d.Label, (Get-FriendlyFailure $errorText))
        }
        $summaryLines.Add([pscustomobject]@{ text = $statusText; color = $statusColor })
        if ($Silent) {
            Write-Host $statusText -ForegroundColor $statusColor
        }
    }

    $failed = @($results | Where-Object { -not $_.success })
    $report = [ordered]@{
        format               = 1
        action               = $Operation
        scope                = $Scope
        success              = ($failed.Count -eq 0)
        cross_module_atomic  = $false
        results              = @($results.ToArray())
        runtime_login_tested = $false
    }
    Write-Utf8NoBom (Join-Path $logDir 'result.json') ($report | ConvertTo-Json -Depth 8)

    if ($SummaryFile) {
        $summaryPayload = [ordered]@{
            success = ($failed.Count -eq 0)
            logDir  = $logDir
            lines   = @($summaryLines.ToArray())
        }
        Write-Utf8NoBom $SummaryFile ($summaryPayload | ConvertTo-Json -Depth 6)
    }

    if ($Silent) {
        if ($failed.Count) { return 2 }
        return 0
    }
    Write-Host "`n=== 本次结果 ==="
    foreach ($r in $results) {
        $state = if ($r.skipped) { '已是目标状态，跳过' } elseif ($r.success) { '通过' } else { '失败/未完成' }
        Write-Host ("{0}：{1}（退出码 {2}）" -f $r.label, $state, $r.exit_code)
    }
    Write-Host ("日志：" + $logDir)
    if ($failed.Count) {
        Write-Host '存在失败模块；成功模块不会跨模块自动还原。请查看日志，修正后单独重试。' -ForegroundColor Yellow
        return 2
    }
    if ($Operation -eq 'Verify') { Write-Host '校验接受原版和本版补丁；请看逐文件状态。' }
    Write-Host '本地操作通过不代表服务端校验或登录已经验证。'
    return 0
}

function Install-Child([string]$Root, [string]$Relative) {
    return Resolve-SafeChild $Root $Relative
}

function Get-ItemSummary($Definition, [string]$Root) {
    try {
        if ($Definition.Launcher) {
            $entry = @($launcherPlan.launchers | Where-Object { $_.id -eq $Definition.Id })[0]
            $file = Install-Child $Root $entry.relative_path
            if (-not [IO.File]::Exists($file)) { return '缺少文件' }
            $hash = Sha $file
            if ($hash -eq $entry.source_sha256) { return '原版' }
            if ($hash -eq $entry.target_sha256) { return '已汉化' }
            if ($hash -in @($entry.previous_sha256)) { return '旧版汉化' }
            return '版本不匹配'
        }
        $plan = $gamePlans[$Definition.Id]
        $dataName = if ($Definition.Id -in @('tw_game', 'tw_deblur')) { 'AzurPromilia_Data' } else { 'AzurPromiliaJP_Data' }
        $dataRoot = Install-Child $Root $dataName
        $ctx = Resolve-GameDeploymentContext $plan $dataRoot
        foreach ($guard in $ctx.ActiveGuards) {
            $file = Install-Child $dataRoot $guard.relative_path
            if (-not [IO.File]::Exists($file)) { return '缺少文件' }
            if ((Sha $file) -ne $guard.sha256) { return '版本不匹配' }
        }
        $original = 0; $localized = 0; $partial = $false
        foreach ($item in $ctx.Items) {
            $file = Install-Child $dataRoot $item.TargetRelativePath
            if (-not [IO.File]::Exists($file)) { return '缺少文件' }
            if ($item.Mode -eq 'ExactFile') {
                $entry = $item.Entry
                if ((Get-Item -LiteralPath $file).Length -ne $entry.size) { return '版本不匹配' }
                $hash = Sha $file
                if ($hash -eq $entry.source_sha256) { $original++ }
                elseif ($hash -eq $entry.target_sha256) { $localized++ }
                else { return '版本不匹配' }
            } else {
                $relState = Get-RelocatedPackState $file $item
                if ($relState -eq 'Original') { $original++ }
                elseif ($relState -eq 'Localized') { $localized++ }
                elseif ($relState -eq 'Mixed') { $partial = $true }
                else { return '版本不匹配' }
            }
        }
        if ($partial) { if ($Definition.Id -in $DeblurDefinitions.Id) { return '部分反虚化' }; return '部分汉化' }
        if ($original -eq @($ctx.Items).Count) { return '原版' }
        if ($localized -eq @($ctx.Items).Count) { if ($Definition.Id -in $DeblurDefinitions.Id) { return '已反虚化' }; return '已汉化' }
        if ($Definition.Id -in $DeblurDefinitions.Id) { return '部分反虚化' }
        return '部分汉化'
    } catch { return '无法读取' }
}

function Parse-Select([string]$Text, $Items) {
    $value = $Text.Trim()
    if ($value -in @('q', '0')) { return @() }
    if (-not $value) { return @($Items.Id) }
    $ids = New-Object 'System.Collections.Generic.List[string]'
    foreach ($token in ($value -split '[,，\s]+')) {
        if (-not $token) { continue }
        $number = 0
        if (-not [int]::TryParse($token, [ref]$number) -or $number -lt 1 -or $number -gt $Items.Count) {
            throw ('项目编号无效：' + $token)
        }
        $id = $Items[$number - 1].Id
        if (-not $ids.Contains($id)) { $ids.Add($id) }
    }
    return $ids.ToArray()
}

function Expand-FolderSearchRoots([string]$Folder) {
    $roots = New-Object 'System.Collections.Generic.List[string]'
    $seen = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    if ($Folder) {
        $p = [IO.Path]::GetFullPath($Folder.Trim().Trim('"'))
        Assert-NoReparse $p
        if (-not [IO.File]::Exists($p) -and -not [IO.Directory]::Exists($p)) {
            throw ('目录不存在：' + $p)
        }
        if ([IO.File]::Exists($p)) { $p = Split-Path $p -Parent }
        if ($seen.Add($p)) { $roots.Add($p) }
        $parent = Split-Path $p -Parent
        if ($parent -and $seen.Add($parent)) { $roots.Add($parent) }
        foreach ($base in @($p, $parent)) {
            if ($base -and [IO.Directory]::Exists($base)) {
                foreach ($child in @(Get-ChildItem -LiteralPath $base -Directory -ErrorAction SilentlyContinue)) {
                    if (-not ($child.Attributes -band [IO.FileAttributes]::ReparsePoint) -and $seen.Add($child.FullName)) {
                        $roots.Add($child.FullName)
                    }
                }
            }
        }
    }
    return @($roots.ToArray())
}

function Find-MenuLocations([hashtable]$ConfiguredPaths, [string]$Folder) {
    $roots = Expand-FolderSearchRoots $Folder
    $resolved = @{}
    foreach ($d in $Definitions) {
        if ($ConfiguredPaths.ContainsKey($d.Id) -and $ConfiguredPaths[$d.Id]) {
            $single = Find-InstallLocations @($d) $ConfiguredPaths -SearchRoots @()
        } else {
            $probe = [pscustomobject]@{ Id = $d.Id; Label = $d.Label; Version = $d.Version; SearchSubpaths = $d.SearchSubpaths }
            $single = Find-InstallLocations @($probe) @{} -SearchRoots $roots
            if ($single[$d.Id].State -eq 'missing' -and -not $OnlyHint) {
                $single = Find-InstallLocations @($d) @{}
            }
        }
        $resolved[$d.Id] = $single[$d.Id]
    }
    $resolved['jp_deblur'] = $resolved['jp_game']
    $resolved['tw_deblur'] = $resolved['tw_game']
    return $resolved
}

function Show-FileStatus($Items, [hashtable]$Locations) {
    foreach ($d in $Items) {
        $root = $Locations[$d.Id].Path
        Write-Host ''
        Write-Host ('[{0}] {1}' -f $d.Label, $root) -ForegroundColor Cyan
        if ($d.Launcher) {
            $entry = @($launcherPlan.launchers | Where-Object { $_.id -eq $d.Id })[0]
            Write-Host ('  {0}  resources/app.asar' -f (Get-ItemSummary $d $root))
            $bkFile = Install-Child $root ($entry.relative_path + $entry.backup_suffix)
            if ([IO.File]::Exists($bkFile)) {
                $bkState = if ((Sha $bkFile) -eq $entry.source_sha256) { '完整' } else { '损坏或不匹配' }
                Write-Host ('  原版备份：{0}' -f $bkState) -ForegroundColor DarkGray
            } else {
                Write-Host '  原版备份：尚未创建（首次安装时自动创建）' -ForegroundColor DarkGray
            }
            continue
        }
        $dataName = if ($d.Id -in @('tw_game', 'tw_deblur')) { 'AzurPromilia_Data' } else { 'AzurPromiliaJP_Data' }
        $dataRoot = Install-Child $root $dataName
        $plan = $gamePlans[$d.Id]
        $backupName = if ($d.Id -eq 'tw_game') { '.zhcn-crc-readonly-3221745-backup' } else { '.zhcn-jp-crc-readonly-3219598-backup' }
        if ($d.Id -eq 'jp_deblur') { $backupName = '.jp-deblur-1.0.2-backup' }
        if ($d.Id -eq 'tw_deblur') { $backupName = '.tw-deblur-3221746-backup' }
        $backupRoot = Join-Path $root $backupName

        $ctx = $null
        try {
            $ctx = Resolve-GameDeploymentContext $plan $dataRoot
        } catch {
            Write-Host ('  热更清单解析失败：' + $_.Exception.Message) -ForegroundColor Yellow
            $fallbackItems = @($plan.files | ForEach-Object {
                [PSCustomObject]@{ Mode = 'ExactFile'; TargetRelativePath = $_.relative_path; PayloadRelativePath = $_.relative_path; Entry = $_; ManifestVersion = $null }
            })
            $ctx = [PSCustomObject]@{ ActiveGuards = @($plan.readonly_files); Items = $fallbackItems; HotfixVersions = @() }
        }

        $bkTotal = @($ctx.Items).Count
        $bkOk = 0; $bkBad = 0
        foreach ($item in $ctx.Items) {
            $state = '无法读取'
            try {
                $file = Install-Child $dataRoot $item.TargetRelativePath
                if (-not [IO.File]::Exists($file)) { $state = '缺少文件' }
                elseif ($item.Mode -eq 'ExactFile') {
                    $e = $item.Entry
                    $hash = Sha $file
                    if ($hash -eq $e.target_sha256) { $state = if ($d.Id -in $DeblurDefinitions.Id) { '已反虚化' } else { '已汉化' } }
                    elseif ($hash -eq $e.source_sha256) { $state = '原版' }
                    else { $state = '版本不匹配' }
                } else {
                    $relState = Get-RelocatedPackState $file $item
                    if ($relState -eq 'Localized') { $state = ('已汉化（热更 ' + $item.ManifestVersion + '）') }
                    elseif ($relState -eq 'Original') { $state = ('原版（热更 ' + $item.ManifestVersion + '）') }
                    elseif ($relState -eq 'Mixed') { $state = ('部分汉化（热更 ' + $item.ManifestVersion + '）') }
                    else { $state = '版本不匹配' }
                }
            } catch {}
            Write-Host ('  {0}  {1}' -f $state, $item.TargetRelativePath)

            try {
                $bkFile = Install-Child $backupRoot $item.TargetRelativePath
                if ($item.Mode -eq 'ExactFile') {
                    if ([IO.File]::Exists($bkFile)) {
                        if ((Sha $bkFile) -eq $item.Entry.source_sha256) { $bkOk++ } else { $bkBad++ }
                    }
                } else {
                    if ([IO.File]::Exists($bkFile)) {
                        try {
                            if ((Get-RelocatedPackState $bkFile $item) -eq 'Original') { $bkOk++ } else { $bkBad++ }
                        } catch { $bkBad++ }
                    } else {
                        $allLegacyPresent = $true
                        $allLegacyOk = $true
                        foreach ($be in $item.BaselineEntries) {
                            $legacyBk = Install-Child $backupRoot $be.relative_path
                            if (-not [IO.File]::Exists($legacyBk)) { $allLegacyPresent = $false; break }
                            if ((Sha $legacyBk) -ne $be.source_sha256) { $allLegacyOk = $false }
                        }
                        if ($allLegacyPresent) {
                            if ($allLegacyOk) { $bkOk++ } else { $bkBad++ }
                        }
                    }
                }
            } catch { $bkBad++ }
        }
        foreach ($e in $ctx.ActiveGuards) {
            $state = '无法读取'
            try {
                $file = Install-Child $dataRoot $e.relative_path
                if (-not [IO.File]::Exists($file)) { $state = '缺少文件' }
                elseif ((Sha $file) -eq $e.sha256) { $state = '原版（只读）' }
                else { $state = '版本不匹配' }
            } catch {}
            Write-Host ('  {0}  {1}' -f $state, $e.relative_path)
        }
        if ($bkBad -gt 0) {
            Write-Host ('  原版备份：部分损坏（{0}/{1} 正常，{2} 异常）' -f $bkOk, $bkTotal, $bkBad) -ForegroundColor Yellow
        } elseif ($bkOk -eq $bkTotal) {
            Write-Host ('  原版备份：完整（{0}/{1}）' -f $bkOk, $bkTotal) -ForegroundColor DarkGray
        } elseif ($bkOk -gt 0) {
            Write-Host ('  原版备份：部分存在（{0}/{1}）' -f $bkOk, $bkTotal) -ForegroundColor DarkGray
        } else {
            Write-Host '  原版备份：尚未创建（首次安装时自动创建）' -ForegroundColor DarkGray
        }

        $txDir = Join-Path $backupRoot 'transactions'
        if ([IO.Directory]::Exists($txDir) -and @(Get-ChildItem -LiteralPath $txDir -Force -ErrorAction SilentlyContinue).Count -gt 0) {
            Write-Host ('  警告：检测到未清理的事务回滚快照目录：{0}' -f $txDir) -ForegroundColor Yellow
        }
    }
}

function Test-MenuWritable([string]$Root) {
    $probe = Install-Child $Root ('.zhcn-write-test-' + [Guid]::NewGuid().ToString('N'))
    try { [IO.File]::WriteAllText($probe, 'x'); [IO.File]::Delete($probe); return $true }
    catch { return $false }
    finally { if ([IO.File]::Exists($probe)) { [IO.File]::Delete($probe) } }
}

function Invoke-MenuOperation([string]$Operation, $Items, [hashtable]$Locations) {
    if ($Operation -eq 'Verify') {
        return (Run-Modules 'Verify' 'All' @($Items.Id) $Locations $true)
    }

    $needAdmin = $false
    foreach ($d in $Items) {
        $dir = $Locations[$d.Id].Path
        if ($d.Launcher) { $dir = Install-Child $dir 'resources' }
        if (-not (Test-MenuWritable $dir)) { $needAdmin = $true }
    }
    if ($needAdmin) {
        if ($Elevated) { throw '已使用管理员权限，仍无法写入目标目录。' }
        Write-Host '写入目标目录需要管理员权限，正在请求……' -ForegroundColor Yellow
        $dir = Child ('tools/logs/elevation-' + [Guid]::NewGuid().ToString('N'))
        [IO.Directory]::CreateDirectory($dir) | Out-Null
        $paths = Join-Path $dir 'paths.json'
        $summaryPath = Join-Path $dir 'summary.json'
        try {
            $map = [ordered]@{}
            foreach ($d in $Items) { $map[$d.Id] = $Locations[$d.Id].Path }
            Write-Utf8NoBom $paths ($map | ConvertTo-Json)
            $arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $PSCommandPath + '" -Action ' + $Operation + ' -Elevated -Quiet -PathsFile "' + $paths + '" -SummaryFile "' + $summaryPath + '" -ModuleIds ' + ($Items.Id -join ',')
            $shell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
            try {
                $process = Start-Process -FilePath $shell -Verb RunAs -ArgumentList $arguments -WindowStyle Hidden -Wait -PassThru
                $exitCode = $process.ExitCode
            } catch [System.ComponentModel.Win32Exception] {
                if ($_.Exception.NativeErrorCode -eq 1223) {
                    Write-Host '  已取消管理员权限请求。' -ForegroundColor Yellow
                    return 1
                }
                throw
            }
            if ([IO.File]::Exists($summaryPath)) {
                try {
                    $sum = Get-Content -LiteralPath $summaryPath -Raw -Encoding UTF8 | ConvertFrom-Json
                    foreach ($line in @($sum.lines)) {
                        $c = if ($line.color) { [string]$line.color } else { 'White' }
                        Write-Host ([string]$line.text) -ForegroundColor $c
                    }
                    if ($sum.logDir) {
                        Write-Host ('  日志：' + $sum.logDir) -ForegroundColor DarkGray
                    }
                } catch {}
            }
            return $exitCode
        } finally {
            if ([IO.Directory]::Exists($dir)) {
                try { [IO.Directory]::Delete($dir, $true) } catch {}
            }
        }
    }
    return (Run-Modules $Operation 'All' @($Items.Id) $Locations $true)
}

try {
    Assert-NoReparse $PackRoot
    . (Child 'tools/Locate-Installations.ps1')
    $launcherPlan = Get-Content -LiteralPath (Child 'tools/launcher-deployment.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($d in $Definitions | Where-Object { $_.Launcher }) {
        $entry = @($launcherPlan.launchers | Where-Object { $_.id -eq $d.Id })
        if ($entry.Count -ne 1) { throw '启动器定位清单无效。' }
        $e0 = $entry[0]
        $d | Add-Member -NotePropertyName AllowedHashes -NotePropertyValue (@($e0.source_sha256, $e0.target_sha256) + @($e0.previous_sha256))
        $d | Add-Member -NotePropertyName Version -NotePropertyValue ([string]$e0.version)
        $d | Add-Member -NotePropertyName SearchSubpaths -NotePropertyValue @($e0.search_subpaths)
    }
    if ($Action -ne 'Menu') {
        if ($ModuleIds -and $ModuleIds.Count -eq 1 -and $ModuleIds[0].Contains(',')) { $ModuleIds = $ModuleIds[0].Split(',') }
        if ($ModuleIds) {
            foreach ($id in $ModuleIds) { if ($id -notin (@($Definitions.Id) + @($DeblurDefinitions.Id))) { throw ('无效模块：' + $id) } }
        }
        exit (Run-Modules $Action $Target $ModuleIds $null $Quiet.IsPresent)
    }

    $gamePlans = @{}
    foreach ($id in @('tw_game', 'jp_game')) {
        $region = if ($id -eq 'tw_game') { 'tw' } else { 'jp' }
        $gamePlans[$id] = Get-Content -LiteralPath (Child ('tools/' + $region + '-deployment.json')) -Raw -Encoding UTF8 | ConvertFrom-Json
    }

    foreach ($d in $DeblurDefinitions) {
        $region = $d.Id.Substring(0, 2)
        $gamePlans[$d.Id] = Get-Content -LiteralPath (Child ('tools/' + $region + '-deblur-deployment.json')) -Raw -Encoding UTF8 | ConvertFrom-Json
    }

    Write-Host '=================================================='
    Write-Host '  蓝色星原：旅谣 简体汉化/尔安 ' -ForegroundColor Cyan -NoNewline
    Write-Host '本脚本开源免费，如付费购买请退款，严禁倒卖。' -ForegroundColor Yellow
    Write-Host '  开服后若登录异常请还原文件，此脚本未进行反作弊验证' -ForegroundColor Red
    Write-Host '=================================================='
    Write-Host '正在查找游戏和启动器安装位置……'
    $configured = Read-ConfiguredPaths
    $menuLocations = Find-MenuLocations $configured $Hint
    $items = @($Definitions | Where-Object { $menuLocations[$_.Id].State -eq 'found' })
    while (-not $items.Count) {
        foreach ($d in $Definitions) {
            if ($menuLocations[$d.Id].State -in @('invalid', 'ambiguous')) {
                Write-Host ($d.Label + '：' + $menuLocations[$d.Id].Problem) -ForegroundColor Yellow
            }
        }
        Write-Host '没有自动找到游戏或启动器。' -ForegroundColor Yellow
        Write-Host '请输入安装文件夹路径（也可以把文件夹拖进本窗口），直接回车退出：'
        $folder = Read-Host '路径'
        if ([string]::IsNullOrWhiteSpace($folder)) { exit 0 }
        try {
            $menuLocations = Find-MenuLocations $configured $folder
        } catch {
            Write-Host $_.Exception.Message -ForegroundColor Yellow
            continue
        }
        $items = @($Definitions | Where-Object { $menuLocations[$_.Id].State -eq 'found' })
    }

    $lastExitCode = 0
    Write-Host '找到以下项目：'
    for ($i = 0; $i -lt $items.Count; $i++) {
        $d = $items[$i]; $location = $menuLocations[$d.Id]
        Write-Host ('  {0}. [{1}] {2}   {3}' -f ($i + 1), $d.Label, (Get-ItemSummary $d $location.Path), $location.Path)
    }
    foreach ($d in $Definitions | Where-Object { $menuLocations[$_.Id].State -ne 'found' }) {
        Write-Host ('     （未找到{0}）' -f $d.Label) -ForegroundColor DarkGray
        if ($menuLocations[$d.Id].State -in @('invalid', 'ambiguous')) {
            Write-Host ('     ' + $menuLocations[$d.Id].Problem) -ForegroundColor Yellow
        }
    }
    Write-Host ''
    Write-Host '  1. 全部汉化'
    Write-Host '  2. 全部还原'
    Write-Host '  3. 选择项目汉化'
    Write-Host '  4. 选择项目还原'
    Write-Host '  5. 查看文件状态'
    Write-Host '  6. 完整校验（含分段与整包 CRC32）'
    Write-Host '  7. 手动添加/修改安装目录'
    Write-Host '  8. 日服反虚化'
    Write-Host '  9. 还原日服反虚化'
    Write-Host '  10. 台服反虚化'
    Write-Host '  11. 还原台服反虚化'
    Write-Host '  Q. 退出'
    while ($true) {
        $items = @($Definitions | Where-Object { $menuLocations[$_.Id].State -eq 'found' })
        $rawChoice = Read-Host '请输入选项并按回车'
        if ($null -eq $rawChoice) { break }
        $choice = ([string]$rawChoice).Trim()
        if ($choice -in @('q', 'Q')) { break }

        $ids = @($items.Id)
        $op = $null
        try {
            switch ($choice) {
                '1' { $op = 'Apply' }
                '2' { $op = 'Restore' }
                '3' { $op = 'Apply'; $ids = @(Parse-Select (Read-Host '请输入项目编号（多个用逗号分隔，例如 1,3）') $items) }
                '4' { $op = 'Restore'; $ids = @(Parse-Select (Read-Host '请输入项目编号（多个用逗号分隔，例如 1,3）') $items) }
                '5' {
                    $statusItems = @($items)
                    $statusItems += @($DeblurDefinitions | Where-Object { $menuLocations[$_.Id].State -eq 'found' })
                    Show-FileStatus $statusItems $menuLocations; continue
                }
                '6' { $op = 'Verify'; $ids += @($DeblurDefinitions | Where-Object { $menuLocations[$_.Id].State -eq 'found' } | ForEach-Object { $_.Id }) }
                '8' { $op = 'Apply'; $ids = @('jp_deblur') }
                '9' { $op = 'Restore'; $ids = @('jp_deblur') }
                '10' { $op = 'Apply'; $ids = @('tw_deblur') }
                '11' { $op = 'Restore'; $ids = @('tw_deblur') }
                '7' {
                    $manual = Read-Host '请输入或拖入游戏/启动器目录（直接回车取消）'
                    if ([string]::IsNullOrWhiteSpace($manual)) { continue }
                    $folderRoots = Expand-FolderSearchRoots $manual
                    $updated = @()
                    foreach ($d in $Definitions) {
                        $probe = if ($d.Launcher) {
                            [pscustomobject]@{ Id = $d.Id; Label = $d.Label; Version = $d.Version; SearchSubpaths = $d.SearchSubpaths }
                        } else {
                            [pscustomobject]@{ Id = $d.Id; Label = $d.Label }
                        }
                        $foundOne = (Find-InstallLocations @($probe) @{} -SearchRoots $folderRoots)[$d.Id]
                        if ($foundOne.State -eq 'found') {
                            $menuLocations[$d.Id] = $foundOne
                            $configured[$d.Id] = $foundOne.Path
                            $updated += ($d.Label + ': ' + $foundOne.Path)
                        }
                    }
                    $menuLocations['jp_deblur'] = $menuLocations['jp_game']
                    $menuLocations['tw_deblur'] = $menuLocations['tw_game']
                    if (-not $updated.Count) {
                        Write-Host '未在该目录中识别出支持的蓝色星原游戏或启动器目录。' -ForegroundColor Yellow
                        continue
                    }
                    foreach ($u in $updated) { Write-Host ('已更新 ' + $u) -ForegroundColor Green }
                    $saveAns = ([string](Read-Host '是否保存到 tools/安装路径.json？(Y/N)')).Trim()
                    if ($saveAns -in @('y', 'Y')) {
                        Save-ConfiguredPaths $configured
                        Write-Host '已保存到 tools/安装路径.json。' -ForegroundColor Green
                    }
                    continue
                }
                default {
                    Write-Host '无效选项，请重新输入。' -ForegroundColor Yellow
                    continue
                }
            }
        } catch {
            Write-Host $_.Exception.Message -ForegroundColor Yellow
            continue
        }
        if (-not $op -or -not $ids.Count) { continue }
        $selected = @((@($items) + @($DeblurDefinitions)) | Where-Object { $_.Id -in $ids })
        $missingDeblur = @($DeblurDefinitions | Where-Object { $_.Id -in $ids -and $menuLocations[$_.Id].State -ne 'found' })
        if ($missingDeblur.Count) {
            foreach ($d in $missingDeblur) { Write-Host ($d.Label + '：' + $menuLocations[$d.Id].Problem) -ForegroundColor Yellow }
            continue
        }
        try {
            $lastExitCode = Invoke-MenuOperation $op $selected $menuLocations
        } catch {
            Write-Host $_.Exception.Message -ForegroundColor Red
            $lastExitCode = 1
        }
    }
    exit $lastExitCode
} catch { Write-Host $_.Exception.Message -ForegroundColor Red; exit 1 }

