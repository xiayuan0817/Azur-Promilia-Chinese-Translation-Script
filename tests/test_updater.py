"""检查命令更新、文件校验和失败还原。"""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[1]
PS = Path(os.environ.get('SystemRoot', 'C:/Windows')) / 'System32/WindowsPowerShell/v1.0/powershell.exe'
UPDATER = ROOT / 'tools/Update-Localization.ps1'


def quote(value):
    return "'" + str(value).replace("'", "''") + "'"


def digest(data):
    return hashlib.sha256(data).hexdigest()


def catalog(files):
    return {'format': 1, 'hash': 'SHA256', 'files': [
        {'path': name, 'size': len(data), 'sha256': digest(data)}
        for name, data in sorted(files.items())]}


@unittest.skipUnless(PS.is_file(), '需要 Windows PowerShell 5.1')
class UpdateTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='updater-test-', dir=ROOT.parent)
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.target = self.base / '汉化包 空格'
        self.old = {'双击运行.bat': b'old entry', 'tools/Manage-Localization.ps1': b'old menu',
                    'tools/Update-Localization.ps1': b'old updater',
                    'payload/sample.bin': b'old resource', 'tools/obsolete.txt': b'old unused'}
        self.new = {'双击运行.bat': b'new entry', 'tools/Manage-Localization.ps1': b'new menu',
                    'tools/Update-Localization.ps1': b'new updater',
                    'payload/sample.bin': b'new resource', 'tools/z-last.txt': b'new last'}
        for name, data in self.old.items():
            self.put(self.target / name, data)
        self.put(self.target / 'tools/package-files.json', json.dumps(catalog(self.old)).encode())
        self.put(self.target / 'tools/安装路径.json', '自定义路径'.encode())
        self.put(self.target / 'tools/logs/user.log', b'log retained')
        self.put(self.target / 'my-file.txt', b'unmanaged retained')

    def put(self, path, data):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)

    def package(self, extra=None, files=None, bad_hash=False):
        files = self.new if files is None else files
        document = catalog(files)
        if bad_hash:
            document['files'][0]['sha256'] = '0' * 64
        archive = self.base / 'fixture.zip'
        with zipfile.ZipFile(archive, 'w') as z:
            for name, data in files.items():
                z.writestr('蓝色星原简体汉化/' + name, data)
            z.writestr('蓝色星原简体汉化/tools/package-files.json', json.dumps(document))
            z.writestr('蓝色星原简体汉化/tools/安装路径.json', '{}')
            for name, data in (extra or {}).items():
                z.writestr(name, data)
        return archive

    def run_ps(self, body, success=True):
        script = self.base / 'run.ps1'
        script.write_bytes(('\ufeff$ErrorActionPreference = \'Stop\'\n. ' + quote(UPDATER) + '\n' + body)
                           .replace('\r\n', '\n').replace('\n', '\r\n').encode('utf-8'))
        result = subprocess.run([str(PS), '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', str(script)],
                                capture_output=True, timeout=45)
        if success:
            self.assertEqual(result.returncode, 0, result.stdout.decode('utf-8', 'replace') +
                             result.stderr.decode('utf-8', 'replace'))
        else:
            self.assertNotEqual(result.returncode, 0)
        return result

    def install_body(self, archive):
        return (f'$catalog = Expand-UpdatePackage {quote(archive)} {quote(self.base / "stage")}\n'
                f'Install-UpdatePackage {quote(self.target)} {quote(self.base / "stage")} '
                f'{quote(self.base / "backup")} $catalog @{{sha256="fixture"}}\n')

    def snapshot(self):
        return {p.relative_to(self.target).as_posix(): p.read_bytes()
                for p in self.target.rglob('*') if p.is_file()}

    def test_update_preserves_paths_logs_and_unmanaged_files(self):
        self.run_ps(self.install_body(self.package()))
        for name, data in self.new.items():
            self.assertEqual((self.target / name).read_bytes(), data)
        self.assertFalse((self.target / 'tools/obsolete.txt').exists())
        self.assertEqual((self.target / 'tools/安装路径.json').read_text('utf-8'), '自定义路径')
        self.assertEqual((self.target / 'tools/logs/user.log').read_bytes(), b'log retained')
        self.assertEqual((self.target / 'my-file.txt').read_bytes(), b'unmanaged retained')
        self.assertEqual(json.loads((self.target / 'tools/update-state.json').read_text()), {'sha256': 'fixture'})

    def test_bad_file_hash_changes_nothing(self):
        before = self.snapshot()
        self.run_ps(self.install_body(self.package(bad_hash=True)), success=False)
        self.assertEqual(before, self.snapshot())

    def test_zip_traversal_changes_nothing(self):
        before = self.snapshot()
        archive = self.package({'蓝色星原简体汉化/../../escape.txt': b'escape'})
        self.run_ps(self.install_body(archive), success=False)
        self.assertEqual(before, self.snapshot())
        self.assertFalse((self.base / 'escape.txt').exists())

    def test_unregistered_file_rejected(self):
        before = self.snapshot()
        archive = self.package({'蓝色星原简体汉化/tools/unlisted.ps1': b'unlisted'})
        self.run_ps(self.install_body(archive), success=False)
        self.assertEqual(before, self.snapshot())

    def test_case_duplicate_rejected(self):
        archive = self.package({'蓝色星原简体汉化/TOOLS/Z-LAST.TXT': b'duplicate'})
        self.run_ps(self.install_body(archive), success=False)

    def test_failed_replacement_rolls_back_previous_replacements(self):
        self.put(self.target / 'tools/z-last.txt', b'locked old')
        before = self.snapshot()
        archive = self.package()
        self.run_ps(f'$handle = [IO.File]::Open({quote(self.target / "tools/z-last.txt")}, '
                    '[IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)\n'
                    'try {\n' + self.install_body(archive) + '\n} finally { $handle.Dispose() }', success=False)
        self.assertEqual(before, self.snapshot())

    def test_locally_modified_obsolete_file_retained(self):
        self.put(self.target / 'tools/obsolete.txt', b'user changed')
        self.run_ps(self.install_body(self.package()))
        self.assertEqual((self.target / 'tools/obsolete.txt').read_bytes(), b'user changed')

    def test_only_canonical_release_asset_selected(self):
        self.run_ps('''
$asset = @{ name='AzurPromilia-Localization-Full-v5.zip'; size=100; digest=('sha256:' + ('a' * 64));
browser_download_url=('https://github.com/' + $script:Upstream + '/releases/download/v5/AzurPromilia-Localization-Full-v5.zip') }
$release = @{ tag_name='v5'; assets=@(@{name='AzurPromilia-Localization-Full-v5-previous.zip'}, $asset) }
if ((Get-UpstreamAsset $release).name -ne $asset.name) { throw 'Wrong asset' }
$asset.browser_download_url = 'https://example.com/fixture.zip'
try { $null = Get-UpstreamAsset $release } catch { exit 0 }
throw 'Unsafe URL accepted'
''')

    def test_check_only_does_not_download_or_modify(self):
        before = self.snapshot()
        self.run_ps('''
function Invoke-RestMethod { return @{ tag_name='v5'; assets=@(@{
name='AzurPromilia-Localization-Full-v5.zip'; size=100; digest=('sha256:' + ('a' * 64));
browser_download_url=('https://github.com/' + $script:Upstream + '/releases/download/v5/AzurPromilia-Localization-Full-v5.zip') }) } }
function Invoke-WebRequest { throw 'Unexpected download' }
''' + f'Invoke-LocalizationUpdate -Root {quote(self.target)} -Check\n')
        self.assertEqual(before, self.snapshot())

    def test_same_digest_validated_and_skipped(self):
        self.put(self.target / 'tools/update-state.json', json.dumps({
            'repository': 'xiayuan0817/Azur-Promilia-Chinese-Translation-Script', 'sha256': 'a' * 64}).encode())
        before = self.snapshot()
        self.run_ps('''
function Invoke-RestMethod { return @{ tag_name='v5'; assets=@(@{
name='AzurPromilia-Localization-Full-v5.zip'; size=100; digest=('sha256:' + ('a' * 64));
browser_download_url=('https://github.com/' + $script:Upstream + '/releases/download/v5/AzurPromilia-Localization-Full-v5.zip') }) } }
function Invoke-WebRequest { throw 'Unexpected download' }
''' + f'Invoke-LocalizationUpdate -Root {quote(self.target)}\n')
        self.assertEqual(before, self.snapshot())

    def test_bat_command_returns_exit_code_without_pause(self):
        shutil.copy2(ROOT / '双击运行.bat', self.target / '双击运行.bat')
        stub = 'param([switch]$CheckOnly)\nif ($CheckOnly) { exit 23 }\nexit 24\n'
        self.put(self.target / 'tools/Update-Localization.ps1', ('\ufeff' + stub).encode())
        for command, expected in [('check-update', 23), ('update', 24)]:
            result = subprocess.run(['cmd', '/d', '/c', str(self.target / '双击运行.bat'), command],
                                    stdin=subprocess.DEVNULL, capture_output=True, timeout=15)
            self.assertEqual(result.returncode, expected, result.stdout + result.stderr)

    def test_bat_can_replace_itself_and_return(self):
        shutil.copy2(ROOT / '双击运行.bat', self.target / '双击运行.bat')
        stub = ("[IO.File]::WriteAllText((Join-Path (Split-Path $PSScriptRoot -Parent) '双击运行.bat'), "
                "'@echo replaced')\nexit 24\n")
        self.put(self.target / 'tools/Update-Localization.ps1', ('\ufeff' + stub).encode())
        result = subprocess.run(['cmd', '/d', '/c', str(self.target / '双击运行.bat'), 'update'],
                                stdin=subprocess.DEVNULL, capture_output=True, timeout=15)
        self.assertEqual(result.returncode, 24, result.stdout + result.stderr)

    def test_official_page_fallback_extracts_exact_hash(self):
        self.run_ps('''
$html = '<li><a href="/xiayuan0817/Azur-Promilia-Chinese-Translation-Script/releases/download/v5/AzurPromilia-Localization-Full-v5.zip">full</a><clipboard-copy value="sha256:HASH"></clipboard-copy></li>'.Replace('HASH', ('b' * 64))
$release = ConvertFrom-UpstreamPage $html 'v5'
if ((Get-UpstreamAsset $release).digest -ne ('sha256:' + ('b' * 64))) { throw 'Wrong digest' }
''')

    def test_manifest_identifies_current_and_new_builds_without_payload_read(self):
        self.run_ps('''
function Get-UpstreamRelease { return [pscustomobject]@{tag_name='v5'; manifest_sha256=$script:testHash; assets=@(@{
name='AzurPromilia-Localization-Full-v5.zip'; size=100; digest=('sha256:' + ('a' * 64));
browser_download_url=('https://github.com/' + $script:Upstream + '/releases/download/v5/AzurPromilia-Localization-Full-v5.zip') }) } }
''' + f'$script:testHash = Get-UpdateSha256 {quote(self.target / "tools/package-files.json")}\n'
                    f"if ((Get-LocalizationUpdateStatus {quote(self.target)}).State -ne 'Current') {{ throw 'Current build missed' }}\n"
                    "$script:testHash = '0' * 64\n"
                    f"if ((Get-LocalizationUpdateStatus {quote(self.target)}).State -ne 'Available') {{ throw 'Update missed' }}\n")

    def mock_menu(self, inputs):
        pack = self.base / 'menu pack'
        shutil.copytree(ROOT / 'tools', pack / 'tools', ignore=shutil.ignore_patterns('logs'))
        shutil.copy2(ROOT / '双击运行.bat', pack / '双击运行.bat')
        game = self.base / 'mock game'
        (game / 'AzurPromilia_Data').mkdir(parents=True)
        self.put(game / 'AzurPromilia.exe', b'fixture')
        paths = {key: str(self.base / ('missing-' + key))
                 for key in ('tw_game', 'jp_game', 'tw_launcher', 'jp_launcher')}
        paths['tw_game'] = str(game)
        self.put(pack / 'tools/安装路径.json', json.dumps(paths).encode())
        stub = ("function Get-LocalizationUpdateStatus { Start-Sleep -Seconds 30; [pscustomobject]@{State='Available';Tag='v6'} }\n"
                "function Invoke-LocalizationUpdate { param($Root) [IO.File]::WriteAllText((Join-Path $Root 'updated.txt'), 'selected') }\n")
        self.put(pack / 'tools/Update-Localization.ps1', ('\ufeff' + stub).encode())
        command = 'cmd.exe /d /s /c ""' + str(pack / '双击运行.bat') + '""'
        start = time.monotonic()
        result = subprocess.run(command, input=('\r\n'.join(inputs) + '\r\n\r\n').encode(),
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=18)
        self.assertEqual(result.returncode, 0, result.stdout.decode('utf-8', 'replace'))
        self.assertLess(time.monotonic() - start, 18)
        self.assertIn('U. 检查并更新汉化包', result.stdout.decode('utf-8', 'replace'))
        return pack

    def test_slow_background_check_does_not_block_menu_or_exit(self):
        pack = self.mock_menu(['Q'])
        self.assertFalse((pack / 'updated.txt').exists())

    def test_update_menu_choice_runs_updater(self):
        pack = self.mock_menu(['U'])
        self.assertEqual((pack / 'updated.txt').read_text(), 'selected')

    def test_complete_update_validates_download_and_cleans_temporary_files(self):
        archive = self.package()
        self.run_ps(f'$script:fixture = {quote(archive)}\n' + '''
function Get-UpstreamRelease { return [pscustomobject]@{ tag_name='v5'; assets=@([pscustomobject]@{
name='AzurPromilia-Localization-Full-v5.zip'; size=(Get-Item -LiteralPath $script:fixture).Length;
digest=('sha256:' + (Get-UpdateSha256 $script:fixture));
browser_download_url=('https://github.com/' + $script:Upstream + '/releases/download/v5/AzurPromilia-Localization-Full-v5.zip') }) } }
function Invoke-WebRequest { param([string]$OutFile) [IO.File]::Copy($script:fixture, $OutFile) }
''' + f'Invoke-LocalizationUpdate {quote(self.target)}\n')
        self.assertEqual((self.target / 'payload/sample.bin').read_bytes(), self.new['payload/sample.bin'])
        self.assertFalse((self.target / 'tools/.update.lock').exists())
        self.assertFalse(list(self.base.glob('.azur-update-*')))

    def test_background_update_notice_is_received_and_job_removed(self):
        self.run_ps(f'$menuFile = {quote(ROOT / "tools/Manage-Localization.ps1")}\n' + '''
$tokens = $null; $errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($menuFile, [ref]$tokens, [ref]$errors)
$functions = $ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
$node.Name -in @('Stop-PackageUpdateCheck', 'Receive-PackageUpdateNotice') }, $false)
foreach ($function in $functions) { Invoke-Expression $function.Extent.Text }
$script:PackageUpdateJob = Start-Job { [pscustomobject]@{State='Available';Tag='v6'} }
Wait-Job $script:PackageUpdateJob | Out-Null
if (-not (Receive-PackageUpdateNotice)) { throw 'Notification missing' }
if ($script:PackageUpdateJob) { throw 'Job retained' }
''')


if __name__ == '__main__':
    unittest.main(verbosity=2)
