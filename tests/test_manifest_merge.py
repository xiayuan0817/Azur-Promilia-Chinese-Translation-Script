"""检查共享资源清单的安装与还原。"""
import hashlib
import json
import tempfile
import unittest
from pathlib import Path

from deployment_fixtures import Fixture, run_ps, sha, write_json


class TestManifestMerge(unittest.TestCase):
    manifest = '.res/default_package/ManifestFiles/0release_default_package_3273850.bytes'
    digest = manifest[:-6] + '.hash'

    def fixture(self):
        temporary = tempfile.TemporaryDirectory(prefix='azur_metadata_')
        self.addCleanup(temporary.cleanup)
        fixture = Fixture(temporary.name)
        original = bytes(range(64))
        file = fixture.data / self.manifest
        file.parent.mkdir(parents=True, exist_ok=True)
        file.write_bytes(original)
        (fixture.data / self.digest).write_bytes(hashlib.md5(original).hexdigest().encode())
        for module, offset, marker, backup in (('tw_game', 8, b'LANG', '.zhcn-tw-3273850-backup'),
                                               ('tw_deblur', 32, b'BLUR', '.tw-deblur-3273850-backup')):
            target = bytearray(original)
            target[offset:offset + 4] = marker
            target = bytes(target)
            plan = {'region': 'tw', 'backup_dir': backup, 'readonly_files': [], 'files': [
                {'relative_path': self.manifest, 'source_sha256': sha(original), 'target_sha256': sha(target),
                 'size': len(target), 'manifest_ranges': [{'offset': offset, 'length': 4, 'target_hex': marker.hex()}]},
                {'relative_path': self.digest, 'source_sha256': sha(hashlib.md5(original).hexdigest().encode()),
                 'target_sha256': sha(hashlib.md5(target).hexdigest().encode()), 'manifest_hash_for': self.manifest}]}
            name = 'tw-deblur-deployment.json' if module.endswith('deblur') else 'tw-deployment.json'
            write_json(fixture.pack / 'tools' / name, plan)
            payload = fixture.pack / 'payload' / module
            (payload / self.manifest).parent.mkdir(parents=True, exist_ok=True)
            (payload / self.manifest).write_bytes(target)
            (payload / self.digest).write_bytes(hashlib.md5(target).hexdigest().encode())
        fixture.original_manifest = original
        return fixture

    def invoke(self, fixture, module, action, success=True):
        script = fixture.pack / 'tools' / ('Apply-TWDeblur.ps1' if module == 'tw_deblur' else 'Apply-CRCZH.ps1')
        code, output = run_ps(script, '-Action', action, '-Hint', fixture.root)
        self.assertEqual(code == 0, success, output)
        return output

    def check(self, fixture, language, deblur):
        expected = bytearray(fixture.original_manifest)
        if language:
            expected[8:12] = b'LANG'
        if deblur:
            expected[32:36] = b'BLUR'
        actual = (fixture.data / self.manifest).read_bytes()
        self.assertEqual(actual, bytes(expected))
        self.assertEqual((fixture.data / self.digest).read_bytes(), hashlib.md5(actual).hexdigest().encode())

    def test_apply_and_restore_preserve_other_module_in_both_orders(self):
        for first, second in (('tw_game', 'tw_deblur'), ('tw_deblur', 'tw_game')):
            for restore in (first, second):
                with self.subTest(first=first, restore=restore):
                    f = self.fixture()
                    self.invoke(f, first, 'Apply')
                    self.invoke(f, second, 'Apply')
                    self.check(f, True, True)
                    self.invoke(f, first, 'Apply')
                    self.invoke(f, restore, 'Restore')
                    self.check(f, restore != 'tw_game', restore != 'tw_deblur')
                    last = second if restore == first else first
                    self.invoke(f, last, 'Restore')
                    self.check(f, False, False)

    def test_missing_hash_payload_rolls_back_merged_manifest(self):
        f = self.fixture()
        self.invoke(f, 'tw_game', 'Apply')
        (f.pack / 'payload/tw_deblur' / self.digest).unlink()
        self.assertIn('已回滚', self.invoke(f, 'tw_deblur', 'Apply', False))
        self.check(f, True, False)

    def test_restore_uses_current_manifest_to_regenerate_hash(self):
        f = self.fixture()
        self.invoke(f, 'tw_game', 'Apply')
        self.invoke(f, 'tw_deblur', 'Apply')
        (f.data / self.digest).unlink()
        self.invoke(f, 'tw_game', 'Restore')
        self.check(f, False, True)

    def test_changed_structure_is_rejected_and_left_unchanged(self):
        f = self.fixture()
        path = f.data / self.manifest
        path.write_bytes(path.read_bytes() + b'new structure')
        before = path.read_bytes()
        self.assertIn('资源清单结构已变化', self.invoke(f, 'tw_game', 'Apply', False))
        self.assertEqual(path.read_bytes(), before)

    def test_state_recognizes_combined_manifest(self):
        f = self.fixture()
        self.invoke(f, 'tw_game', 'Apply')
        self.invoke(f, 'tw_deblur', 'Apply')
        script = f.pack / 'check-state.ps1'
        script.write_text("\ufeff. (Join-Path $PSScriptRoot 'tools/Localization-Common.ps1')\n"
                          "$plan = Get-Content (Join-Path $PSScriptRoot 'tools/tw-deployment.json') -Raw -Encoding UTF8 | ConvertFrom-Json\n"
                          "foreach ($entry in $plan.files) { $file = Join-Path $args[0] $entry.relative_path; Get-DeploymentFileState $file $entry }\n", 'utf-8')
        code, output = run_ps(script, f.data)
        self.assertEqual(code, 0, output)
        self.assertIn('已汉化', output)
        self.assertIn('清单校验一致', output)


if __name__ == '__main__':
    unittest.main(verbosity=2)
