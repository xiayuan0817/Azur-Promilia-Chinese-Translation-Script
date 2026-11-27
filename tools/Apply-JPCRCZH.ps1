param(
    [ValidateSet('Menu','Apply','Restore','Verify','ValidatePayload')][string]$Action = 'Menu',
    [string]$Hint = ''
)
$ErrorActionPreference = 'Stop'
$script:HintExplicit = $PSBoundParameters.ContainsKey('Hint')
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch {}

$commonPath = Join-Path $PSScriptRoot 'Localization-Common.ps1'
if (-not [IO.File]::Exists($commonPath)) {
    $p1 = Split-Path $PSScriptRoot -Parent
    $p2 = if ($p1) { Split-Path $p1 -Parent } else { $null }
    if ($p2) {
        $fallbackCommon = Join-Path $p2 'tools\Localization-Common.ps1'
        if ([IO.File]::Exists($fallbackCommon)) { $commonPath = $fallbackCommon }
    }
}
. $commonPath

$PackRoot = Split-Path $PSScriptRoot -Parent
$config = @{
    Region                 = 'jp'
    RegionLabel            = '日服'
    DeploymentFile         = 'jp-deployment.json'
    FallbackDeploymentFile = 'crc-deployment.json'
    ExeName                = 'AzurPromiliaJP.exe'
    DataDirName            = 'AzurPromiliaJP_Data'
    GameProcName           = 'AzurPromiliaJP'
    BackupDirName          = '.zhcn-jp-crc-readonly-3219598-backup'
    PayloadSubdir          = 'payload/jp_game'
    SearchRelatives        = @('YostarGames\AZUPRO_JP', 'Games\YostarGames\AZUPRO_JP', 'Game\YostarGames\AZUPRO_JP', 'AZUPRO_JP')
    HintRelatives          = @('AZUPRO_JP', 'YostarGames\AZUPRO_JP')
    MenuTitle              = '日服简体汉化'
    NotFoundMsg            = '没有找到日服游戏。请把游戏文件夹拖到 BAT 上，或使用 -Hint 指定安装目录。'
}

try {
    $code = Invoke-GameCRCZH -Config $config -Action $Action -Hint $Hint -HintExplicit $script:HintExplicit -ToolsDir $PSScriptRoot -PackRoot $PackRoot
    exit $code
} catch {
    Write-Host $_.Exception.Message -ForegroundColor Red
    exit 1
}

