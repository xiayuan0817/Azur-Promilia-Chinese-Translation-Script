# 读取游戏和启动器的发行区服。
if (-not ('RegionConfigReader' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Text;
using System.Collections.Generic;
public static class RegionConfigReader {
    static readonly UTF8Encoding Utf8 = new UTF8Encoding(false, true);
    static byte[] ReadExact(Stream stream, int count) {
        byte[] bytes = new byte[count];
        int position = 0;
        while (position < count) {
            int read = stream.Read(bytes, position, count - position);
            if (read == 0) throw new EndOfStreamException();
            position += read;
        }
        return bytes;
    }
    public static string[] TextAssetJson(string path, string name) {
        using (FileStream stream = File.OpenRead(path)) {
            if (stream.Length > 268435456) throw new InvalidDataException("区服配置文件过大：" + path);
            byte[] data = ReadExact(stream, (int)stream.Length);
            byte[] key = Encoding.UTF8.GetBytes(name);
            List<string> found = new List<string>();
            for (int offset = 0; offset + key.Length + 12 <= data.Length; offset++) {
                if (data[offset] != key.Length || data[offset + 1] != 0 || data[offset + 2] != 0 || data[offset + 3] != 0) continue;
                int index = 0;
                while (index < key.Length && data[offset + 4 + index] == key[index]) index++;
                if (index != key.Length) continue;
                int lengthOffset = offset + ((4 + key.Length + 3) & ~3);
                int size = BitConverter.ToInt32(data, lengthOffset);
                int start = lengthOffset + 4;
                if (size < 2 || size > 1048576 || start > data.Length - size) continue;
                try {
                    string json = Utf8.GetString(data, start, size).Trim();
                    if (json.StartsWith("{") && json.EndsWith("}")) found.Add(json);
                } catch (DecoderFallbackException) { }
                if (found.Count > 16) throw new InvalidDataException("区服配置数量异常：" + path);
            }
            return found.ToArray();
        }
    }
    public static string AsarHeader(string path) {
        using (FileStream stream = File.OpenRead(path)) {
            byte[] header = ReadExact(stream, 16);
            uint length = BitConverter.ToUInt32(header, 12);
            uint block = BitConverter.ToUInt32(header, 4);
            if (BitConverter.ToUInt32(header, 0) != 4 || length < 2 || length > 16777216 || block < length + 8 || 8L + block > stream.Length)
                throw new InvalidDataException("启动器资源目录无效：" + path);
            return Utf8.GetString(ReadExact(stream, (int)length));
        }
    }
    public static string AsarText(string path, long offset, int count) {
        if (count < 0 || count > 8388608 || offset < 0) throw new InvalidDataException("启动器配置范围无效");
        using (FileStream stream = File.OpenRead(path)) {
            byte[] header = ReadExact(stream, 16);
            long start = 8L + BitConverter.ToUInt32(header, 4) + offset;
            if (start < 16 || start > stream.Length - count) throw new InvalidDataException("启动器配置越界");
            stream.Position = start;
            return Utf8.GetString(ReadExact(stream, count));
        }
    }
}
'@
}

function Get-RegionLabel([string]$Region) {
    switch ($Region) { 'tw' { return '台服' }; 'jp' { return '日服' }; 'cn' { return '国服' }; default { return '未知区服' } }
}

function Resolve-RegionEvidence($Evidence, [string]$Path) {
    $regions = @($Evidence | Where-Object { $_ } | Select-Object -Unique)
    if ($regions.Count -gt 1) { throw ('区服标识冲突：' + $Path) }
    if ($regions.Count -eq 1) { return [string]$regions[0] }
    return ''
}

function Get-AssetRegion([string]$Path) {
    if (-not [IO.File]::Exists($Path)) { return '' }
    Assert-NoReparse $Path
    $evidence = @()
    foreach ($name in @('appConfig', 'MJSDKConfig')) {
        foreach ($json in [RegionConfigReader]::TextAssetJson($Path, $name)) {
            try { $config = $json | ConvertFrom-Json -ErrorAction Stop } catch { continue }
            if ($name -eq 'appConfig') {
                if (-not $config.PSObject.Properties['gameId'] -or -not $config.PSObject.Properties['channel']) { continue }
                switch ([string]$config.region) { 'cht' { $evidence += 'tw' }; 'jp' { $evidence += 'jp' }; 'chs' { $evidence += 'cn' } }
                switch ([string]$config.gameId) { '43' { $evidence += 'tw' }; '42' { $evidence += 'jp' }; '34' { $evidence += 'cn' } }
                switch -Regex ([string]$config.channel) { '_tc$' { $evidence += 'tw' }; '_jp$' { $evidence += 'jp' }; '^ob\d+(?:\.\d+)*$' { $evidence += 'cn' } }
            } else {
                if (-not $config.PSObject.Properties['app_id']) { continue }
                switch ([string]$config.region) { 'HMT' { $evidence += 'tw' }; 'CN' { $evidence += 'cn' }; 'JP' { $evidence += 'jp' } }
            }
        }
    }
    return Resolve-RegionEvidence $evidence $Path
}

function Get-GameInstallRegion([string]$Root, [switch]$AllowBackup) {
    Assert-NoReparse $Root
    $evidence = @()
    foreach ($data in @('AzurPromilia_Data', 'AzurPromiliaJP_Data')) {
        $r = Get-AssetRegion (Join-Path $Root ($data + '/resources.assets'))
        if ($r) { $evidence += $r }
    }
    $launcherConfig = Join-Path $Root 'game-launcher-config.json'
    if ([IO.File]::Exists($launcherConfig)) {
        Assert-NoReparse $launcherConfig
        $config = Get-Content -LiteralPath $launcherConfig -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($config.tag -eq 'AZUPRO_JP' -and $config.name -eq 'AzurPromiliaJP') { $evidence += 'jp' }
    }
    if ($evidence.Count) { return Resolve-RegionEvidence $evidence $Root }
    if ($AllowBackup) {
        $backupPairs = @(
            @('.zhcn-crc-readonly-3221745-backup', 'tw_game'), @('.tw-deblur-3221746-backup', 'tw_deblur'),
            @('.zhcn-jp-crc-readonly-3219598-backup', 'jp_game'), @('.jp-deblur-1.0.2-backup', 'jp_deblur')
        )
        foreach ($item in @(Get-ChildItem -LiteralPath $Root -Directory -Force)) {
            if ($item.Name -match '^\.zhcn-(tw|jp)-\d+-backup$') { $backupPairs += ,@($item.Name, $Matches[1] + '_game') }
            elseif ($item.Name -match '^\.(tw|jp)-deblur-\d+-backup$') { $backupPairs += ,@($item.Name, $Matches[1] + '_deblur') }
        }
        foreach ($pair in $backupPairs) {
            $backup = Join-Path $Root $pair[0]
            $state = Get-ModuleState (Join-Path $backup '.localization-state.json') $pair[1]
            if ($state) { $evidence += [string]$state.region }
            $r = Get-AssetRegion (Join-Path $backup 'resources.assets')
            if ($r) { $evidence += $r }
        }
    }
    return Resolve-RegionEvidence $evidence $Root
}

function Assert-GameInstallRegion([string]$Root, [string]$Region, [switch]$AllowBackup) {
    $actual = Get-GameInstallRegion $Root -AllowBackup:$AllowBackup
    if (-not $actual) { throw ('无法确认游戏区服，未写入：' + $Root) }
    if ($actual -ne $Region) { throw ('区服不符：选择了' + (Get-RegionLabel $Region) + '，目录属于' + (Get-RegionLabel $actual) + '：' + $Root) }
}

function Get-AsarMember($Header, [string]$Name, [string]$Path) {
    $node = $Header
    foreach ($part in (($Name -replace '^\./', '') -split '/')) {
        if (-not $node.PSObject.Properties['files']) { throw ('启动器缺少区服配置：' + $Name) }
        $property = $node.files.PSObject.Properties[$part]
        if (-not $property) { throw ('启动器缺少区服配置：' + $Name) }
        $node = $property.Value
    }
    if ($node.PSObject.Properties['unpacked'] -and $node.unpacked) { throw '不支持外置区服配置。' }
    if ($node.PSObject.Properties['link'] -or -not $node.PSObject.Properties['offset'] -or -not $node.PSObject.Properties['size']) { throw '启动器区服配置无效。' }
    return [RegionConfigReader]::AsarText($Path, [long]$node.offset, [int]$node.size)
}

function Get-AsarRegion([string]$Path) {
    if (-not [IO.File]::Exists($Path)) { return '' }
    Assert-NoReparse $Path
    $header = [RegionConfigReader]::AsarHeader($Path) | ConvertFrom-Json
    $package = (Get-AsarMember $header 'package.json' $Path) | ConvertFrom-Json
    $evidence = @()
    if ($package.name -eq 'AZUPRO_JP_Gamelauncher' -and $package.author -eq 'Yostar, Inc.') { $evidence += 'jp' }
    if ($package.name -eq 'launcher') {
        if ($package.author -eq 'JIMI PTE. LTD.') { $evidence += 'tw' }
        $main = Get-AsarMember $header 'main.js' $Path
        foreach ($m in [regex]::Matches($main, '"Ny"\s*:\s*"(CN|HMT)"')) {
            if ($m.Groups[1].Value -eq 'CN') { $evidence += 'cn' } else { $evidence += 'tw' }
        }
    }
    return Resolve-RegionEvidence $evidence $Path
}

function Get-LauncherInstallRegion([string]$Root, [switch]$AllowBackup) {
    $path = Resolve-SafeChild $Root 'resources/app.asar'
    $liveError = $null
    if ([IO.File]::Exists($path)) {
        try {
            $actual = Get-AsarRegion $path
            if ($actual) { return $actual }
        } catch {
            if (-not $AllowBackup -or $_.Exception.Message -match '区服标识冲突|重解析点') { throw }
            $liveError = $_
        }
    }
    if ($AllowBackup) {
        $backup = $path + '.before-zhcn-20261124.bak'
        $r = Get-AsarRegion $backup
        if ($r) { return $r }
        $receipt = $backup + '.region.json'
        if ([IO.File]::Exists($receipt)) {
            Assert-NoReparse $receipt
            $state = Get-Content -LiteralPath $receipt -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($state.module -in @('tw_launcher', 'jp_launcher')) { return $state.module.Substring(0, 2) }
            throw ('启动器备份区服记录无效：' + $receipt)
        }
    }
    if ($liveError) { throw $liveError }
    return ''
}

function Assert-LauncherInstallRegion([string]$Root, [string]$Region, [switch]$AllowBackup) {
    $actual = Get-LauncherInstallRegion $Root -AllowBackup:$AllowBackup
    if (-not $actual) { throw ('无法确认启动器区服，未写入：' + $Root) }
    if ($actual -ne $Region) { throw ('区服不符：选择了' + (Get-RegionLabel $Region) + '启动器，目录属于' + (Get-RegionLabel $actual) + '：' + $Root) }
}
