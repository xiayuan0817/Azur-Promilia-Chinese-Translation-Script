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
. (Join-Path $PSScriptRoot 'Update-Localization.ps1')
$script:PackageUpdateCheck = $null
$script:PackageUpdateTool = Join-Path $PSScriptRoot 'Update-Localization.ps1'

function Start-PackageUpdateCheck {
    $worker = [PowerShell]::Create()
    try {
        $null = $worker.AddScript({
            param($Tool, $Root)
            $ErrorActionPreference = 'Stop'
            $ProgressPreference = 'SilentlyContinue'
            try {
                . $Tool
                Get-LocalizationUpdateStatus $Root
            } catch { [pscustomobject]@{ State = 'Failed' } }
        }.ToString()).AddArgument($script:PackageUpdateTool).AddArgument($PackRoot)
        $script:PackageUpdateCheck = [pscustomobject]@{ Worker = $worker; Handle = $worker.BeginInvoke() }
    } catch { $worker.Dispose() }
}

function Stop-PackageUpdateCheck {
    if ($script:PackageUpdateCheck) {
        $check = $script:PackageUpdateCheck
        $script:PackageUpdateCheck = $null
        if ($check.Handle.IsCompleted) { $check.Worker.Dispose() }
        else {
            $null = $check.Worker.BeginStop($null, $null)
            $script:StoppedUpdateCheck = $check
        }
    }
}

function Receive-PackageUpdateNotice {
    if (-not $script:PackageUpdateCheck -or -not $script:PackageUpdateCheck.Handle.IsCompleted) { return $false }
    try { $result = @($script:PackageUpdateCheck.Worker.EndInvoke($script:PackageUpdateCheck.Handle)) }
    catch { $result = @() }
    finally { Stop-PackageUpdateCheck }
    if ($result.Count -and $result[-1].State -eq 'Available') {
        Write-Host ('发现上游更新（' + $result[-1].Tag + '），输入 U 可更新汉化包，其他功能可照常使用。') -ForegroundColor Yellow
        return $true
    }
    return $false
}

function Test-UpdateSkipRequested {
    try {
        if ([Console]::IsInputRedirected) { return $true }
        if ([Console]::KeyAvailable) { return ([Console]::ReadKey($true).Key -eq [ConsoleKey]::Enter) }
    } catch { return $true }
    return $false
}

function Wait-PackageUpdateCheck {
    Write-Host '正在检查更新（按回车跳过检查）……' -ForegroundColor DarkGray
    Start-PackageUpdateCheck
    try {
        $deadline = [DateTime]::UtcNow.AddSeconds(10)
        while ($script:PackageUpdateCheck -and -not $script:PackageUpdateCheck.Handle.IsCompleted) {
            if (Test-UpdateSkipRequested) { return }
            if ([DateTime]::UtcNow -ge $deadline) { return }
            Start-Sleep -Milliseconds 50
        }
        $null = Receive-PackageUpdateNotice
    } finally { Stop-PackageUpdateCheck }
}

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

function Sha([string]$Path) { return Get-FileSha256 $Path }

function Child([string]$Relative) {
    return Resolve-SafeChild $PackRoot $Relative
}

function Assert-Package {
    param(
        [bool]$Silent = $false,
        [string]$Operation = 'CheckPackage',
        [string[]]$SelectedIds = @()
    )
    if ($Operation -ne 'CheckPackage') { return }
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
    if ($Detail -match '区服不符|区服标识冲突|无法确认.*区服') { return ('未处理：' + $Detail.Trim()) }
    if ($Detail -match '请先.*退出|未退出') { return '未处理：请先退出对应游戏或启动器。' }
    if ($Detail -match '回滚失败') { return '失败：自动回滚未完成，请保留备份并查看日志。' }
    if ($Detail -match '已回滚到操作前') { return ('未完成：' + $Detail.Trim()) }
    return ('未完成：' + $Detail.Trim())
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
                $capturedText -match '(?m)^(?:ALREADY_(?:CURRENT|ORIGINAL)\s|NO_BACKUP\s|所有文件均已处于目标状态，无需修改。)')
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
                if ($Operation -eq 'Restore') { if ($capturedText -match '(?m)^NO_BACKUP\s') { '无备份，未修改' } else { '已还原，跳过' } } elseif ($d.Id -in $DeblurDefinitions.Id) { '已反虚化，跳过' } else { '已汉化，跳过' }
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
    if ($Operation -eq 'Verify') { Write-Host '区服检查完成；未进行版本或全文件校验。' }
    Write-Host '本地操作通过不代表服务端校验或登录已经验证。'
    return 0
}

function Install-Child([string]$Root, [string]$Relative) {
    return Resolve-SafeChild $Root $Relative
}

function Get-ModuleFileInfo($Definition, [string]$Root) {
    if ($Definition.Launcher) {
        $entry = @($launcherPlan.launchers | Where-Object { $_.id -eq $Definition.Id })[0]
        return [pscustomobject]@{
            Entries = @($entry); DataRoot = $Root; Exe = $entry.exe
            BackupRoot = ''; BackupSuffix = $entry.backup_suffix
        }
    }
    $plan = $gamePlans[$Definition.Id]
    $region = $Definition.Id.Substring(0, 2)
    $isTW = $region -eq 'tw'
    $dataName = if ($isTW) { 'AzurPromilia_Data' } else { 'AzurPromiliaJP_Data' }
    $exe = if ($isTW) { 'AzurPromilia.exe' } else { 'AzurPromiliaJP.exe' }
    $backupName = switch ($Definition.Id) {
        'tw_game' { '.zhcn-crc-readonly-3221745-backup' }; 'jp_game' { '.zhcn-jp-crc-readonly-3219598-backup' }
        'tw_deblur' { '.tw-deblur-3221746-backup' }; 'jp_deblur' { '.jp-deblur-1.0.2-backup' }
    }
    if ($plan.PSObject.Properties['backup_dir']) { $backupName = $plan.backup_dir }
    return [pscustomobject]@{
        Entries = @($plan.files); DataRoot = (Install-Child $Root $dataName); Exe = $exe
        BackupRoot = (Install-Child $Root $backupName); BackupSuffix = ''
    }
}

function Get-ItemSummary($Definition, [string]$Root) {
    try {
        $info = Get-ModuleFileInfo $Definition $Root
        $statePath = if ($Definition.Launcher) { (Join-Path $Root 'resources/app.asar') + $info.BackupSuffix + '.region.json' } else { Join-Path $info.BackupRoot '.localization-state.json' }
        $state = Get-ModuleState $statePath $Definition.Id
        if (-not $state) { return '区服已识别' }
        if ($state.action -eq 'Restore') { return '上次已还原' }
        if ($state.action -eq 'Apply') { return '上次已处理' }
        return '区服已识别'
    } catch { return '区服已识别' }
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

function Resolve-MenuLocationChoices([hashtable]$Locations, [hashtable]$ConfiguredPaths) {
    foreach ($d in $Definitions) {
        if (-not $Locations.ContainsKey($d.Id)) { continue }
        $location = $Locations[$d.Id]
        if ($location.State -ne 'ambiguous') { continue }
        Write-Host ('找到多个' + $d.Label + '安装目录：') -ForegroundColor Cyan
        for ($index = 0; $index -lt $location.Candidates.Count; $index++) {
            Write-Host ('  ' + ($index + 1) + '. ' + $location.Candidates[$index])
        }
        while ($true) {
            $answer = Read-Host '请选择目录编号（回车跳过该项目）'
            if ([string]::IsNullOrWhiteSpace($answer)) { break }
            $number = 0
            if ([int]::TryParse($answer.Trim(), [ref]$number) -and $number -ge 1 -and $number -le $location.Candidates.Count) {
                $location.Path = $location.Candidates[$number - 1]
                $location.State = 'found'; $location.Problem = $null
                $ConfiguredPaths[$d.Id] = $location.Path
                break
            }
            Write-Host '目录编号无效，请重新输入。' -ForegroundColor Yellow
        }
    }
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
    Resolve-MenuLocationChoices $resolved $ConfiguredPaths
    $resolved['jp_deblur'] = $resolved['jp_game']
    $resolved['tw_deblur'] = $resolved['tw_game']
    return $resolved
}

function Show-FileStatus($Items, [hashtable]$Locations) {
    foreach ($d in $Items) {
        $root = $Locations[$d.Id].Path
        Write-Host ''
        Write-Host ('[{0}] {1}  {2}' -f $d.Label, (Get-ItemSummary $d $root), $root) -ForegroundColor Cyan
        $info = Get-ModuleFileInfo $d $root
        Write-Host ('  区服：' + (Get-RegionLabel ($d.Id.Substring(0, 2))))
        foreach ($entry in $info.Entries) {
            $file = Install-Child $info.DataRoot $entry.relative_path
            $backup = if ($d.Launcher) { $file + $info.BackupSuffix } else { Install-Child $info.BackupRoot $entry.relative_path }
            $state = if (Test-PreserveExternalGameResource $entry $info.DataRoot) { '保留外部修改' } else { Get-DeploymentFileState $file $entry $backup }
            if ($d.Id -in $DeblurDefinitions.Id) { $state = $state.Replace('汉化', '反虚化') }
            Write-Host ('  [' + $state + '] ' + $entry.relative_path)
            if ([IO.File]::Exists($backup)) { Write-Host '    备份：存在' -ForegroundColor DarkGray }
            else { Write-Host '    备份：无' -ForegroundColor DarkGray }
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
    Write-Host ''
    Wait-PackageUpdateCheck
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
        Write-Host ('     （{0}：{1}）' -f $d.Label, $menuLocations[$d.Id].Problem) -ForegroundColor DarkGray
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
    Write-Host '  6. 检查区服'
    Write-Host '  7. 手动添加/修改安装目录'
    Write-Host '  8. 日服反虚化'
    Write-Host '  9. 还原日服反虚化'
    Write-Host '  10. 台服反虚化'
    Write-Host '  11. 还原台服反虚化'
    Write-Host '  U. 检查并更新汉化包'
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
                'U' {
                    Stop-PackageUpdateCheck
                    if (Invoke-LocalizationUpdate $PackRoot) { exit 42 }
                    continue
                }
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
                        if ($foundOne.State -eq 'ambiguous') {
                            $choiceMap = @{ $d.Id = $foundOne }; Resolve-MenuLocationChoices $choiceMap $configured
                            $foundOne = $choiceMap[$d.Id]
                        }
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
finally {
    Stop-PackageUpdateCheck
    if ($script:StoppedUpdateCheck -and $script:StoppedUpdateCheck.Handle.IsCompleted) {
        $script:StoppedUpdateCheck.Worker.Dispose()
        $script:StoppedUpdateCheck = $null
    }
}

