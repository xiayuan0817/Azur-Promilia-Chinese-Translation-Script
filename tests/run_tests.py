"""检查运行入口与发行包构建。"""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
import zipfile
from deployment_fixtures import text_asset

ROOT = Path(__file__).resolve().parents[1]

def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()



def write_ps1(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(b'\xef\xbb\xbf' + text.replace('\r\n', '\n').replace('\n', '\r\n').encode('utf-8'))



def copy_tool_tree(dest_root: Path) -> None:
    tools_dest = dest_root / 'tools'
    tools_dest.mkdir(parents=True, exist_ok=True)
    for src in (ROOT / 'tools').iterdir():
        if src.is_file():
            shutil.copy2(src, tools_dest / src.name)
    for name in ('双击运行.bat', 'README.md', 'LICENSE', '.gitignore', '.gitattributes', 'build_release.py'):
        p = ROOT / name
        if p.is_file():
            shutil.copy2(p, dest_root / name)
    for folder in ('CRC工具', 'tests'):
        shutil.copytree(ROOT / folder, dest_root / folder,
                        ignore=shutil.ignore_patterns('__pycache__', '*.pyc', '.pytest_cache',
                                                     'release_test', 'fixed_candidates', 'originals'))



class TestBatchEntryPoint(unittest.TestCase):
    def test_actual_batch_reaches_real_menu(self):
        with tempfile.TemporaryDirectory(prefix='azur_menu_') as td:
            pack = Path(td) / '中文 空格 (菜单)&!'
            copy_tool_tree(pack)
            game = Path(td) / 'mock_game'
            (game / 'AzurPromilia_Data').mkdir(parents=True)
            (game / 'AzurPromilia.exe').write_bytes(b'MOCKEXE')
            (game / 'AzurPromilia_Data/resources.assets').write_bytes(text_asset('tw'))
            paths = {key: str(Path(td) / ('missing_' + key))
                     for key in ('tw_game', 'jp_game', 'tw_launcher', 'jp_launcher')}
            paths['tw_game'] = str(game)
            (pack / 'tools' / '安装路径.json').write_text(
                json.dumps(paths, ensure_ascii=False), 'utf-8')
            command = 'cmd.exe /d /s /c ""' + str(pack / '双击运行.bat') + '""'
            result = subprocess.run(command, input=b'Q\r\n\r\n', stdout=subprocess.PIPE,
                                    stderr=subprocess.STDOUT, timeout=30)
            output = result.stdout.decode('utf-8', 'replace')
            self.assertEqual(result.returncode, 0, output)
            self.assertIn('全部汉化', output)
            self.assertIn('Q. 退出', output)
            self.assertIn('按任意键继续', output)

    def _mock_menu_pack(self, td):
        pack = Path(td) / '中文 空格 (回归)&!'
        copy_tool_tree(pack)
        game = Path(td) / 'mock_game'
        (game / 'AzurPromilia_Data').mkdir(parents=True)
        (game / 'AzurPromilia.exe').write_bytes(b'MOCKEXE')
        (game / 'AzurPromilia_Data/resources.assets').write_bytes(text_asset('tw'))
        # Explicit nonempty paths disable discovery of real installations.
        paths = {key: str(Path(td) / ('missing_' + key))
                 for key in ('tw_game', 'jp_game', 'tw_launcher', 'jp_launcher')}
        paths['tw_game'] = str(game)
        (pack / 'tools/安装路径.json').write_text(
            json.dumps(paths, ensure_ascii=False), 'utf-8')
        return pack

    def _run_mock_menu(self, pack, inputs, expected=0):
        command = 'cmd.exe /d /s /c ""' + str(pack / '双击运行.bat') + '""'
        result = subprocess.run(command, input=('\r\n'.join(inputs) + '\r\n\r\n').encode('utf-8'),
                                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=30)
        output = result.stdout.decode('utf-8', 'replace')
        self.assertEqual(result.returncode, expected, output)
        self.assertIn('按任意键继续', output)
        return output

    def test_invalid_project_selection_returns_to_menu(self):
        with tempfile.TemporaryDirectory(prefix='azur_bad_selection_') as td:
            pack = self._mock_menu_pack(td)
            for choice in ('3', '4'):
                with self.subTest(choice=choice):
                    output = self._run_mock_menu(pack, [choice, '99', choice, '1,bad', '5', 'Q'])
                    self.assertIn('项目编号无效：99', output)
                    self.assertIn('项目编号无效：bad', output)
                    self.assertEqual(output.count('1. 全部汉化'), 1)
                    self.assertIn('备份：', output)
                    self.assertFalse((pack / 'tools/logs').exists())

    def test_missing_manual_directory_does_not_search_neighbors(self):
        with tempfile.TemporaryDirectory(prefix='azur_bad_folder_') as td:
            pack = self._mock_menu_pack(td)
            # A sibling launcher would have been found by the former parent expansion.
            neighbor = Path(td) / 'neighbor_launcher'
            (neighbor / 'resources').mkdir(parents=True)
            (neighbor / 'launcher.exe').write_bytes(b'MOCKEXE')
            (neighbor / 'resources/app.asar').write_bytes(b'MOCKASAR')
            config = pack / 'tools/安装路径.json'
            before = config.read_bytes()
            output = self._run_mock_menu(pack, ['7', str(Path(td) / 'does_not_exist'), '5', 'Q'])
            self.assertIn('目录不存在：', output)
            self.assertNotIn('已更新', output)
            self.assertNotIn('已保存', output)
            self.assertEqual(output.count('1. 全部汉化'), 1)
            self.assertIn('备份：', output)
            self.assertEqual(config.read_bytes(), before)
            self.assertFalse((pack / 'tools/logs').exists())

    def test_menu_prints_once_after_results_and_errors(self):
        with tempfile.TemporaryDirectory(prefix='azur_menu_once_') as td:
            pack = self._mock_menu_pack(td)
            output = self._run_mock_menu(pack, ['5', '1', 'bogus', '5', 'Q'], expected=2)
            self.assertIn('已回滚', output)
            self.assertIn('无效选项，请重新输入。', output)
            # Two status requests each include the TW localization and deblur modules.
            self.assertIn('备份：', output)
            self.assertEqual(output.count('找到以下项目：'), 1)
            for label in ('1. 全部汉化', '2. 全部还原', '3. 选择项目汉化',
                          '4. 选择项目还原', '5. 查看文件状态', '6. 检查区服',
                          '7. 手动添加/修改安装目录', '8. 日服反虚化', '9. 还原日服反虚化',
                          '10. 台服反虚化', '11. 还原台服反虚化', 'Q. 退出'):
                self.assertEqual(output.count(label), 1, output)

    def test_actual_batch_startup_and_dragged_directories(self):
        with tempfile.TemporaryDirectory(prefix='azur_bat_') as td:
            pack = Path(td) / '中文 空格 (入口)&!'
            (pack / 'tools').mkdir(parents=True)
            entry = pack / '双击运行.bat'
            entry.write_bytes((ROOT / '双击运行.bat').read_bytes())
            write_ps1(pack / 'tools' / 'Manage-Localization.ps1', """
param([string]$Hint = '')
$value = if ($Hint) { [IO.Path]::GetFullPath($Hint) } else { '' }
[IO.File]::WriteAllText((Join-Path $PSScriptRoot 'entry.json'), (ConvertTo-Json -InputObject $value))
exit 3
""")
            cases = (('', ''), (str(pack), str(pack)),
                     (str(pack) + '\\', str(pack)), (pack.anchor, pack.anchor))
            for hint, expected in cases:
                with self.subTest(hint=hint):
                    result_file = pack / 'tools' / 'entry.json'
                    result_file.unlink(missing_ok=True)
                    command = 'cmd.exe /d /s /c ""' + str(entry) + '"'
                    if hint:
                        command += ' "' + hint + '"'
                    command += '"'
                    result = subprocess.run(command, input=b'\r\n',
                                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                            timeout=30)
                    self.assertEqual(result.returncode, 3, result.stdout.decode('utf-8', 'replace'))
                    self.assertEqual(json.loads(result_file.read_text('utf-8-sig')), expected)
                    self.assertIn('按任意键继续', result.stdout.decode('utf-8', 'replace'))



class TestBuildRelease(unittest.TestCase):
    def test_verify_repo_flag(self):
        proc = subprocess.run([sys.executable, str(ROOT / 'build_release.py'), '--verify-repo'],
                              cwd=str(ROOT), stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=60)
        out = proc.stdout.decode('utf-8', 'replace')
        self.assertEqual(proc.returncode, 0, out)
        data = json.loads(out)
        self.assertTrue(data['repo_verified'])

    def test_mock_zip_build(self):
        with tempfile.TemporaryDirectory(prefix='azur_build_') as td:
            td_path = Path(td)
            pack = td_path / 'repo'
            copy_tool_tree(pack)
            payload = td_path / 'mock_payload'
            usage = td_path / '使用说明.txt'
            usage.write_bytes('双击 BAT，输入编号并回车。\r\n'.encode('utf-8'))
            cat_path = pack / 'tools' / 'package-files.json'
            cat = json.loads(cat_path.read_text('utf-8-sig'))
            new_files = []
            for item in cat['files']:
                if item['path'].startswith('payload/'):
                    if item['path'] == 'payload/tw_game/resources.assets':
                        fp = payload / 'tw_game' / 'resources.assets'
                        fp.parent.mkdir(parents=True, exist_ok=True)
                        fp.write_bytes(b'MOCK_PAYLOAD')
                        new_files.append({'path': item['path'], 'size': 12, 'sha256': sha256_bytes(b'MOCK_PAYLOAD')})
                else:
                    new_files.append(item)
            cat['files'] = new_files
            cat_path.write_text(json.dumps(cat, indent=2), 'utf-8')

            out_dir = td_path / 'dist'
            proc = subprocess.run(
                [sys.executable, str(pack / 'build_release.py'), '--payload', str(payload), '--usage', str(usage), '--output', str(out_dir), '--version', 'vtest'],
                cwd=str(pack), stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=60,
            )
            self.assertEqual(proc.returncode, 0, proc.stdout.decode('utf-8', 'replace'))
            full_zip = out_dir / 'AzurPromilia-Localization-Full-vtest.zip'
            src_zip = out_dir / 'AzurPromilia-Localization-Source-vtest.zip'
            self.assertTrue(full_zip.is_file())
            self.assertTrue(src_zip.is_file())
            for zp in (full_zip, src_zip):
                with zipfile.ZipFile(zp) as zf:
                    self.assertIsNone(zf.testzip())
            with zipfile.ZipFile(full_zip) as zf:
                self.assertEqual(zf.read('蓝色星原简体汉化/使用说明.txt'), usage.read_bytes())
                self.assertIn('蓝色星原简体汉化/tools/日服反虚化原说明.txt', zf.namelist())
            with zipfile.ZipFile(src_zip) as zf:
                prefix = '蓝色星原简体汉化-源码/'
                names = set(zf.namelist())
                self.assertNotIn(prefix + '使用说明.txt', names)
                self.assertNotIn(prefix + 'tools/日服反虚化原说明.txt', names)
                self.assertIn(prefix + 'tools/日服反虚化来源.md', names)
                for name in ('tests/run_tests.py', 'CRC工具/crc/pool_capacity.py',
                             'CRC工具/crc/Apply-CRCZH.ps1',
                             'CRC工具/jp_crc/Apply-JPCRCZH.ps1'):
                    self.assertIn(prefix + name, names)
                unpacked = td_path / 'unpacked'
                zf.extractall(unpacked)
            extracted_root = unpacked / '蓝色星原简体汉化-源码'
            verify = subprocess.run(
                [sys.executable, str(extracted_root / 'build_release.py'), '--verify-repo'],
                cwd=str(extracted_root), stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                timeout=60,
            )
            self.assertEqual(verify.returncode, 0, verify.stdout.decode('utf-8', 'replace'))
            sums = (out_dir / 'SHA256SUMS.txt').read_text('ascii')
            self.assertIn(sha256_bytes(full_zip.read_bytes()), sums)
            self.assertIn(sha256_bytes(src_zip.read_bytes()), sums)



if __name__ == '__main__':
    suite = unittest.defaultTestLoader.loadTestsFromModule(sys.modules[__name__])
    suite.addTests(unittest.defaultTestLoader.discover(str(ROOT / 'tests'), pattern='test_*.py'))
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    raise SystemExit(not result.wasSuccessful())
