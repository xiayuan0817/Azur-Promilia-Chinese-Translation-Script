"""检查菜单及文件状态查询。"""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
PS = Path(os.environ.get('SystemRoot', 'C:/Windows')) / 'System32/WindowsPowerShell/v1.0/powershell.exe'


def quote(value):
    return "'" + str(value).replace("'", "''") + "'"


def sha(data):
    return hashlib.sha256(data).hexdigest()


@unittest.skipUnless(PS.is_file(), '需要 Windows PowerShell 5.1')
class MenuStatusTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='menu-status-', dir=ROOT.parent)
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.game = self.base / '日服 游戏'
        self.data = self.game / 'AzurPromiliaJP_Data'
        self.index = '.res/raw_base_package/BundleFiles/index.r'
        self.localized = b'localized-resource'
        self.original = b'original-resource0'
        self.guard = 'boot.config'
        self.plan = {
            'resource_version': '3219598',
            'readonly_files': [{'relative_path': self.guard, 'sha256': sha(b'original-config')}],
            'files': [{'relative_path': p, 'size': len(self.localized),
                       'source_sha256': sha(self.original), 'target_sha256': sha(self.localized)}
                      for p in (self.index, 'resources.assets')],
        }
        self.put(self.data / self.guard, b'original-config')
        for entry in self.plan['files']:
            self.put(self.data / entry['relative_path'], self.localized)
        self.plan_file = self.base / 'plan.json'
        self.plan_file.write_text(json.dumps(self.plan), 'utf-8')

    def put(self, path, data):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)

    def run_summary(self, expected='已汉化', details=False):
        body = f"""$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object Text.UTF8Encoding($false)
. {quote(ROOT / 'tools/Localization-Common.ps1')}
$tokens = $null; $errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile({quote(ROOT / 'tools/Manage-Localization.ps1')}, [ref]$tokens, [ref]$errors)
if ($errors.Count) {{ throw 'Menu parse failed' }}
$functions = $ast.FindAll({{ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
$node.Name -in @('Install-Child','Sha','Get-ItemSummary','Show-FileStatus') }}, $false)
foreach ($function in $functions) {{ Invoke-Expression $function.Extent.Text }}
$plan = Get-Content -LiteralPath {quote(self.plan_file)} -Raw | ConvertFrom-Json
$gamePlans = @{{ jp_game=$plan }}
$DeblurDefinitions = @()
$definition = [pscustomobject]@{{ Id='jp_game'; Launcher=$false; Label='日服游戏' }}
$actual = Get-ItemSummary $definition {quote(self.game)}
if ($actual -ne {quote(expected)}) {{ throw ('Unexpected summary: ' + $actual) }}
Write-Host $actual
"""
        if details:
            body += 'Show-FileStatus @($definition) @{jp_game=@{Path=' + quote(self.game) + '}}\n'
        script = self.base / 'read-state.ps1'
        script.write_bytes(('\ufeff' + body.replace('\r\n', '\n').replace('\n', '\r\n')).encode())
        result = subprocess.run([str(PS), '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', str(script)],
                                capture_output=True, timeout=20)
        output = result.stdout.decode('utf-8', 'replace') + result.stderr.decode('utf-8', 'replace')
        self.assertEqual(result.returncode, 0, output)
        return output

    def test_localized_files_and_details(self):
        output = self.run_summary(details=True)
        for relative in (self.index, 'resources.assets', self.guard):
            self.assertIn(relative, output)
        self.assertNotIn('版本不匹配', output)

    def test_original_files(self):
        for entry in self.plan['files']:
            self.put(self.data / entry['relative_path'], self.original)
        self.run_summary('原版')

    def test_mixed_files(self):
        self.put(self.data / self.index, self.original)
        self.run_summary('部分汉化')

    def test_changed_index(self):
        self.put(self.data / self.index, b'unknown-content')
        self.run_summary('版本不匹配')

    def test_missing_index(self):
        (self.data / self.index).unlink()
        self.run_summary('缺少文件')

    def test_changed_text_resource(self):
        self.put(self.data / 'resources.assets', b'unknown-content')
        self.run_summary('版本不匹配')

    def test_changed_guard(self):
        self.put(self.data / self.guard, b'unknown-config')
        self.run_summary('版本不匹配')

    def test_missing_guard(self):
        (self.data / self.guard).unlink()
        self.run_summary('缺少文件')


if __name__ == '__main__':
    unittest.main(verbosity=2)
