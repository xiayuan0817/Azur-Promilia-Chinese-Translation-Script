"""检查区服识别、逐文件部署和备份还原。"""
import json
from pathlib import Path
import shutil
import tempfile
import unittest

from deployment_fixtures import Fixture, ROOT, asar, run_ps, text_asset, write_json


class TestRegionDeployment(unittest.TestCase):
    def fixture(self, module='tw_game'):
        temporary = tempfile.TemporaryDirectory(prefix='azur_region_')
        self.addCleanup(temporary.cleanup)
        return Fixture(temporary.name, module)

    def invoke(self, fixture, action, success=True):
        code, output = fixture.run(action)
        self.assertEqual(code == 0, success, output)
        return output

    def assert_content(self, fixture, expected):
        for relative, value in expected.items():
            self.assertEqual((fixture.data / relative).read_bytes(), value, relative)

    def test_all_six_modules_accept_updated_files_and_restore_actual_backups(self):
        for module in ('tw_game', 'jp_game', 'tw_deblur', 'jp_deblur', 'tw_launcher', 'jp_launcher'):
            with self.subTest(module=module):
                f = self.fixture(module)
                self.invoke(f, 'Apply')
                self.assert_content(f, f.after)
                self.invoke(f, 'Apply')
                self.invoke(f, 'Restore')
                self.assert_content(f, f.before)
                self.assertIn('ALREADY_ORIGINAL', self.invoke(f, 'Restore'))

    def test_cn_cannot_be_mistaken_for_tw(self):
        f = self.fixture()
        (f.data / 'resources.assets').write_bytes(text_asset('cn'))
        output = self.invoke(f, 'Apply', False)
        self.assertIn('国服', output)
        self.assertEqual((f.data / f.relative[0]).read_bytes(), f.before[f.relative[0]])
        self.assertFalse(f.backup.exists())

    def test_other_region_unknown_and_conflicting_configs_are_rejected(self):
        for data in (text_asset('jp'), text_asset('unknown'), text_asset('tw') + text_asset('cn')):
            with self.subTest(config=data):
                f = self.fixture()
                (f.data / 'resources.assets').write_bytes(data)
                self.invoke(f, 'Apply', False)
                self.assertFalse(f.backup.exists())

    def test_launcher_cross_region_is_rejected(self):
        f = self.fixture('tw_launcher')
        (f.data / 'resources/app.asar').write_bytes(asar('jp'))
        self.invoke(f, 'Apply', False)
        self.assertFalse(f.backup.exists())

    def test_second_missing_payload_is_processed_after_first_then_rolled_back(self):
        f = self.fixture()
        (f.pack / 'payload' / f.module / f.relative[1]).unlink()
        output = self.invoke(f, 'Apply', False)
        self.assertIn('已写入：' + f.relative[0], output)
        self.assertIn('已回滚', output)
        self.assertIn(f.relative[1], output)
        self.assert_content(f, f.before)
        self.assertFalse(list(f.root.rglob('*.zhcn-stage-*')))

    def test_second_corrupt_payload_rolls_back(self):
        f = self.fixture()
        (f.pack / 'payload' / f.module / f.relative[1]).write_bytes(b'damaged')
        output = self.invoke(f, 'Apply', False)
        self.assertIn('补丁文件损坏', output)
        self.assertIn('已写入：' + f.relative[0], output)
        self.assert_content(f, f.before)

    def test_missing_target_is_created_and_removed_on_restore(self):
        f = self.fixture()
        target = f.data / f.relative[0]
        target.unlink()
        self.invoke(f, 'Apply')
        self.assertEqual(target.read_bytes(), f.after[f.relative[0]])
        self.assertTrue(Path(str(f.backup / f.relative[0]) + '.zhcn-absent').is_file())
        self.invoke(f, 'Restore')
        self.assertFalse(target.exists())

    def test_failed_apply_removes_new_target(self):
        f = self.fixture()
        target = f.data / f.relative[0]
        target.unlink()
        (f.pack / 'payload' / f.module / f.relative[1]).unlink()
        self.invoke(f, 'Apply', False)
        self.assertFalse(target.exists())

    def test_first_backup_is_not_overwritten(self):
        f = self.fixture()
        self.invoke(f, 'Apply')
        (f.data / f.relative[0]).write_bytes(b'second external update')
        self.invoke(f, 'Apply')
        self.assertEqual((f.backup / f.relative[0]).read_bytes(), f.before[f.relative[0]])
        self.invoke(f, 'Restore')
        self.assert_content(f, f.before)

    def test_restore_does_not_need_exe_or_payload_and_recovers_extra_backup(self):
        f = self.fixture()
        self.invoke(f, 'Apply')
        extra = '.res/default_package/BundleFiles/oldplan.r'
        path = f.backup / extra
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(b'older plan original')
        shutil.rmtree(f.pack / 'payload')
        f.exe.unlink()
        (f.data / 'resources.assets').unlink()
        self.invoke(f, 'Restore')
        self.assert_content(f, f.before)
        self.assertEqual((f.data / extra).read_bytes(), b'older plan original')

    def test_verify_checks_only_region(self):
        f = self.fixture()
        shutil.rmtree(f.pack / 'payload')
        (f.data / f.relative[0]).unlink()
        self.assertIn('区服检查通过', self.invoke(f, 'Verify'))

    def test_no_backup_means_no_changes(self):
        f = self.fixture()
        self.assertIn('NO_BACKUP', self.invoke(f, 'Restore'))
        self.assert_content(f, f.before)

    def test_external_shared_resource_is_not_overwritten_or_required(self):
        f = self.fixture('jp_game')
        plan = json.loads(f.plan_path.read_text('utf-8-sig'))
        plan['files'][0]['preserve_external_changes'] = True
        write_json(f.plan_path, plan)
        (f.pack / 'payload' / f.module / f.relative[0]).unlink()
        self.assertIn('已保留外部修改', self.invoke(f, 'Apply'))
        self.assertEqual((f.data / f.relative[0]).read_bytes(), f.before[f.relative[0]])
        self.invoke(f, 'Restore')
        self.assert_content(f, f.before)

    def test_plan_cannot_escape_data_directory(self):
        f = self.fixture()
        plan = json.loads(f.plan_path.read_text('utf-8-sig'))
        plan['files'][0]['relative_path'] = '../../outside.r'
        write_json(f.plan_path, plan)
        self.invoke(f, 'Apply', False)
        self.assertFalse(f.backup.exists())

    def test_shared_index_preserves_related_language_files(self):
        f = self.fixture('jp_game')
        plan = json.loads(f.plan_path.read_text('utf-8-sig'))
        primary = plan['files'][0]
        primary['preserve_external_changes'] = True
        plan['files'][1]['preserve_with'] = dict(primary)
        write_json(f.plan_path, plan)
        shutil.rmtree(f.pack / 'payload')
        output = self.invoke(f, 'Apply')
        self.assertEqual(output.count('已保留外部修改'), 2)
        self.assert_content(f, f.before)

    def test_locator_excludes_cn_and_residual_directories(self):
        f = self.fixture()
        script = f.pack / 'locate-test.ps1'
        script.write_text("\ufeff. (Join-Path $PSScriptRoot 'tools/Localization-Common.ps1')\n"
                          ". (Join-Path $PSScriptRoot 'tools/Locate-Installations.ps1')\n"
                          "$r = Test-InstallRoot 'tw_game' $args[0]; Write-Host ('FOUND=' + $r)\n", 'utf-8')
        code, out = run_ps(script, f.root)
        self.assertEqual(code, 0, out)
        self.assertIn('FOUND=True', out)
        f.exe.unlink()
        code, out = run_ps(script, f.root)
        self.assertEqual(code, 0, out)
        self.assertIn('FOUND=False', out)
        f.exe.write_bytes(b'fake')
        (f.data / 'resources.assets').write_bytes(text_asset('cn'))
        code, out = run_ps(script, f.root)
        self.assertEqual(code, 0, out)
        self.assertIn('FOUND=False', out)


if __name__ == '__main__':
    unittest.main(verbosity=2)
