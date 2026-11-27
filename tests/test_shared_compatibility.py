"""检查共享资源排除、文字汉化和还原。"""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
import zlib

ROOT = Path(__file__).resolve().parents[1]
PS = Path(os.environ.get('SystemRoot', 'C:/Windows')) / 'System32/WindowsPowerShell/v1.0/powershell.exe'
sys.path.insert(0, str(ROOT / 'CRC工具/crc'))
import crcpatch


def sha(data):
    return hashlib.sha256(data).hexdigest()


@unittest.skipUnless(PS.is_file(), '需要 Windows PowerShell 5.1')
class SharedCompatibilityTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='shared-compat-', dir=ROOT.parent)
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.pack = self.base / '汉化包'
        self.tools = self.pack / 'tools'
        self.tools.mkdir(parents=True)
        for name in ['Localization-Common.ps1', 'Apply-JPCRCZH.ps1']:
            shutil.copy2(ROOT / 'tools' / name, self.tools / name)
        self.game = self.base / '日服游戏'
        self.data = self.game / 'AzurPromiliaJP_Data'
        self.data.mkdir(parents=True)
        (self.game / 'AzurPromiliaJP.exe').write_bytes(b'MOCK')
        self.original = b'ORIGINAL' * 8
        self.localized = b'LOCALIZE' * 8
        self.index = '.res/raw_base_package/BundleFiles/shared.r'
        self.pool_original = b'INDEX' * 12
        candidate = bytearray(b'TEXTS' * 12)
        self.pool_crc = zlib.crc32(self.pool_original) & 0xffffffff
        self.assertTrue(crcpatch.patch_crc(candidate, self.pool_crc, len(candidate) - 4))
        self.pool_localized = bytes(candidate)
        self.pool_shared = self.pool_localized + b'EXTERNAL-PATHS'
        self.guard_originals = {}
        self.shared = {self.index: self.pool_shared}
        guards = []
        for package in ['raw_base_package', 'raw_streaming_package']:
            for extension in ['bytes', 'hash']:
                name = f'.res/{package}/ManifestFiles/0release_{package}_3219598.{extension}'
                original = ('original:' + name).encode()
                guards.append({'relative_path': name, 'sha256': sha(original), 'skip_validation': True})
                self.guard_originals[name] = original
                self.shared[name] = ('external:' + name).encode()
        self.other_guard = 'boot.config'
        guards.append({'relative_path': self.other_guard, 'sha256': sha(b'unchanged-config')})
        for name, content in {'resources.assets': self.original,
                              self.other_guard: b'unchanged-config', **self.shared}.items():
            path = self.data / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(content)
        self.plan = {'format': 1, 'region': 'jp', 'resource_version': '3219598',
                     'files': [
                         {'relative_path': 'resources.assets', 'size': len(self.original),
                          'source_sha256': sha(self.original), 'target_sha256': sha(self.localized)},
                         {'relative_path': self.index, 'size': len(self.pool_original),
                          'source_sha256': sha(self.pool_original), 'target_sha256': sha(self.pool_localized),
                          'crc32': self.pool_crc, 'segments': [], 'preserve_external_changes': True}],
                     'readonly_files': guards}
        for name, content in {'resources.assets': self.localized, self.index: self.pool_localized}.items():
            target = self.pack / 'payload/jp_game' / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(content)
        self.write_plan()

    def write_plan(self):
        (self.tools / 'jp-deployment.json').write_text(json.dumps(self.plan), 'utf-8')

    def run_action(self, action, expected=0):
        result = subprocess.run([str(PS), '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
                                 str(self.tools / 'Apply-JPCRCZH.ps1'), '-Action', action,
                                 '-Hint', str(self.game)], capture_output=True, timeout=30)
        output = (result.stdout + result.stderr).decode('utf-8', 'replace')
        self.assertEqual(result.returncode, expected, output)
        return output

    def assert_shared_unchanged(self):
        for name, content in self.shared.items():
            self.assertEqual((self.data / name).read_bytes(), content, name)

    def test_apply_verify_restore_preserves_every_shared_file(self):
        for action, expected in [('Verify', self.original), ('Apply', self.localized),
                                 ('Verify', self.localized), ('Restore', self.original),
                                 ('Verify', self.original)]:
            self.assertIn('已排除共享资源校验', self.run_action(action))
            self.assertEqual((self.data / 'resources.assets').read_bytes(), expected)
            self.assert_shared_unchanged()
        backup = self.game / '.zhcn-jp-crc-readonly-3219598-backup'
        self.assertFalse((backup / self.index).exists())
        self.assertEqual((backup / 'resources.assets').read_bytes(), self.original)

    def test_future_external_manifest_contents_are_ignored(self):
        for name in self.guard_originals:
            (self.data / name).write_bytes(b'UNKNOWN-FUTURE-VERSION')
        self.run_action('Apply')
        self.run_action('Verify')
        for name in self.guard_originals:
            self.assertEqual((self.data / name).read_bytes(), b'UNKNOWN-FUTURE-VERSION')

    def test_future_external_index_is_preserved_without_a_profile(self):
        for action, suffix in [('Apply', b'NEW-1'), ('Verify', b'NEW-2'), ('Restore', b'NEW-3')]:
            content = self.pool_shared + suffix
            (self.data / self.index).write_bytes(content)
            self.run_action(action)
            self.assertEqual((self.data / self.index).read_bytes(), content)

    def test_excluded_manifests_do_not_need_to_exist(self):
        for name in self.guard_originals:
            (self.data / name).unlink()
        self.run_action('Apply')
        self.run_action('Verify')

    def test_original_installation_localizes_and_restores_text_index(self):
        for name, data in self.guard_originals.items():
            (self.data / name).write_bytes(data)
        (self.data / self.index).write_bytes(self.pool_original)
        self.run_action('Apply')
        self.assertEqual((self.data / self.index).read_bytes(), self.pool_localized)
        self.run_action('Verify')
        self.run_action('Restore')
        self.assertEqual((self.data / self.index).read_bytes(), self.pool_original)
        self.assertEqual((self.data / 'resources.assets').read_bytes(), self.original)

    def test_other_guard_is_still_checked(self):
        (self.data / self.other_guard).write_bytes(b'UNKNOWN')
        self.assertIn('原版只读基线不匹配', self.run_action('Apply', 1))
        self.assertEqual((self.data / 'resources.assets').read_bytes(), self.original)

    def test_text_resource_is_still_checked(self):
        content = b'UNKNOWN-RESOURCE'
        (self.data / 'resources.assets').write_bytes(content)
        self.assertIn('文件版本不匹配', self.run_action('Apply', 1))
        self.assertEqual((self.data / 'resources.assets').read_bytes(), content)
        self.assert_shared_unchanged()

    def test_missing_required_text_index_is_reported(self):
        (self.data / self.index).unlink()
        self.assertIn('文件缺失', self.run_action('Apply', 1))
        self.assertEqual((self.data / 'resources.assets').read_bytes(), self.original)

    def test_menu_status_shows_exclusions_without_mismatch(self):
        script = self.base / 'menu-status.ps1'
        q = lambda value: "'" + str(value).replace("'", "''") + "'"
        code = f"""$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)
. {q(self.tools / 'Localization-Common.ps1')}
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile({q(ROOT / 'tools/Manage-Localization.ps1')}, [ref]$tokens, [ref]$errors)
if ($errors.Count) {{ throw 'Menu parse failed' }}
$functions = $ast.FindAll({{ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -in @('Install-Child','Sha','Get-ItemSummary','Show-FileStatus') }}, $false)
foreach ($function in $functions) {{ Invoke-Expression $function.Extent.Text }}
$plan = Get-Content -LiteralPath {q(self.tools / 'jp-deployment.json')} -Raw -Encoding UTF8 | ConvertFrom-Json
$gamePlans = @{{ jp_game = $plan }}
$DeblurDefinitions = @()
$d = [pscustomobject]@{{ Id = 'jp_game'; Label = '日服游戏'; Launcher = $false }}
if ((Get-ItemSummary $d {q(self.game)}) -ne '原版') {{ throw '共享资源排除状态识别失败' }}
$locations = @{{ jp_game = [pscustomobject]@{{ Path = {q(self.game)} }} }}
Show-FileStatus @($d) $locations
"""
        script.write_bytes(b'\xef\xbb\xbf' + code.replace('\n', '\r\n').encode())
        result = subprocess.run([str(PS), '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', str(script)],
                                capture_output=True, timeout=30)
        output = (result.stdout + result.stderr).decode('utf-8', 'replace')
        self.assertEqual(result.returncode, 0, output)
        self.assertEqual(output.count('已排除（共享资源）'), 5, output)
        self.assertNotIn('版本不匹配', output)


if __name__ == '__main__':
    unittest.main()
