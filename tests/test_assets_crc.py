"""检查启动文字资源的 CRC 校验及旧版升级。"""
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


def quote(value):
    return "'" + str(value).replace("'", "''") + "'"


@unittest.skipUnless(PS.is_file(), '需要 Windows PowerShell 5.1')
class AssetsCrcTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='assets-crc-', dir=ROOT.parent)
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.original = bytes(range(64))
        self.previous = b'P' * 64
        self.target = bytearray(b'T' * 64)
        self.crc = zlib.crc32(self.original) & 0xffffffff
        self.assertTrue(crcpatch.patch_crc(self.target, self.crc, 60))
        self.target = bytes(self.target)
        self.entry = {'relative_path': 'resources.assets', 'size': 64,
                      'source_sha256': sha(self.original), 'target_sha256': sha(self.target),
                      'crc32': self.crc, 'segments': [], 'previous_sha256': [sha(self.previous)]}

    def run_check(self, body):
        script = self.base / 'check.ps1'
        header = f"""$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)
. {quote(ROOT / 'tools/Localization-Common.ps1')}
$entry = {quote(json.dumps(self.entry))} | ConvertFrom-Json
"""
        script.write_bytes(('\ufeff' + (header + body).replace('\r\n', '\n').replace('\n', '\r\n')).encode())
        return subprocess.run([str(PS), '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', str(script)],
                              capture_output=True, timeout=30)

    def test_original_and_current_crc(self):
        original, target = self.base / 'original', self.base / 'target'
        original.write_bytes(self.original)
        target.write_bytes(self.target)
        result = self.run_check(f'Assert-GameResource {quote(original)} $entry $false\n'
                                f'Assert-GameResource {quote(target)} $entry $true\n')
        self.assertEqual(result.returncode, 0, result.stderr.decode('utf-8', 'replace'))

    def test_wrong_crc_rejected_even_with_correct_sha(self):
        target = self.base / 'target'
        target.write_bytes(self.target)
        result = self.run_check(f'$entry.crc32 = [uint32]0\nAssert-GameResource {quote(target)} $entry $true\n')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('CRC', (result.stdout + result.stderr).decode('utf-8', 'replace'))

    def test_previous_hash_only_for_assets(self):
        result = self.run_check(f"""if (-not (Test-PreviousGameResourceHash $entry '{sha(self.previous)}')) {{ throw 'Known assets rejected' }}
if (Test-PreviousGameResourceHash $entry '{sha(b'unknown')}') {{ throw 'Unknown assets accepted' }}
$entry.relative_path = '.res/raw_base_package/BundleFiles/test.r'
if (Test-PreviousGameResourceHash $entry '{sha(self.previous)}') {{ throw 'Bundle exception accepted' }}
""")
        self.assertEqual(result.returncode, 0, result.stderr.decode('utf-8', 'replace'))

    def test_previous_assets_upgrade_and_restore(self):
        pack = self.base / 'pack'
        tools = pack / 'tools'
        tools.mkdir(parents=True)
        for name in ['Localization-Common.ps1', 'Apply-JPCRCZH.ps1']:
            shutil.copy2(ROOT / 'tools' / name, tools / name)
        plan = {'format': 1, 'region': 'jp', 'resource_version': 'test',
                'files': [self.entry], 'readonly_files': []}
        (tools / 'jp-deployment.json').write_text(json.dumps(plan), 'utf-8')
        game = self.base / '游戏'
        data = game / 'AzurPromiliaJP_Data'
        data.mkdir(parents=True)
        (game / 'AzurPromiliaJP.exe').write_bytes(b'MOCK')
        installed = data / 'resources.assets'
        installed.write_bytes(self.previous)
        backup = game / '.zhcn-jp-crc-readonly-3219598-backup'
        backup.mkdir()
        (backup / 'resources.assets').write_bytes(self.original)
        payload = pack / 'payload/jp_game'
        payload.mkdir(parents=True)
        (payload / 'resources.assets').write_bytes(self.target)
        for action, expected in [('Verify', self.previous), ('Apply', self.target),
                                 ('Verify', self.target), ('Restore', self.original)]:
            result = subprocess.run([str(PS), '-NoProfile', '-ExecutionPolicy', 'Bypass',
                                     '-File', str(tools / 'Apply-JPCRCZH.ps1'),
                                     '-Action', action, '-Hint', str(game)],
                                    capture_output=True, timeout=30)
            self.assertEqual(result.returncode, 0,
                             (result.stdout + result.stderr).decode('utf-8', 'replace'))
            self.assertEqual(installed.read_bytes(), expected)
            self.assertEqual((backup / 'resources.assets').read_bytes(), self.original)


if __name__ == '__main__':
    unittest.main()
