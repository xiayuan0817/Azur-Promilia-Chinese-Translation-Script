"""检查内置清单差异不再阻断汉化、校验和还原。"""
import json
from pathlib import Path
import unittest
import test_shared_compatibility as shared

ROOT = Path(__file__).resolve().parents[1]
PREFIX = 'StreamingAssets/.res/default_package/0release_default_package_3075915'
EXCLUDED = {PREFIX + '.bytes', PREFIX + '.hash'}


class BuiltinGuardTests(unittest.TestCase):
    def setUp(self):
        self.case = shared.SharedCompatibilityTests('test_apply_verify_restore_preserves_every_shared_file')
        self.case.setUp()
        self.addCleanup(self.case.doCleanups)

    def test_deployment_removes_only_this_builtin_pair(self):
        plan = json.loads((ROOT / 'tools/jp-deployment.json').read_text('utf-8-sig'))
        names = {e['relative_path'] for e in plan['readonly_files']}
        self.assertFalse(names & EXCLUDED)
        self.assertEqual(len(names), 16)
        self.assertEqual(sum(bool(e.get('skip_validation')) for e in plan['readonly_files']), 4)
        self.assertIn('StreamingAssets/.res/default_package/BuildinCatalog.bytes', names)
        self.assertIn('StreamingAssets/.res/static_package/0release_static_package_3075915.bytes', names)

    def test_changed_builtin_pair_no_longer_blocks_any_action(self):
        case = self.case
        contents = {PREFIX + '.bytes': b'different-manifest', PREFIX + '.hash': b'different-hash'}
        for name, data in contents.items():
            path = case.data / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
            case.plan['readonly_files'].append({'relative_path': name, 'sha256': shared.sha(b'baseline')})
        case.write_plan()
        self.assertIn('原版只读基线不匹配：' + PREFIX + '.bytes', case.run_action('Apply', 1))
        self.assertEqual((case.data / 'resources.assets').read_bytes(), case.original)
        case.plan['readonly_files'] = [e for e in case.plan['readonly_files'] if e['relative_path'] not in EXCLUDED]
        case.write_plan()
        for action, expected in [('Apply', case.localized), ('Verify', case.localized), ('Restore', case.original)]:
            case.run_action(action)
            self.assertEqual((case.data / 'resources.assets').read_bytes(), expected)
            for name, data in contents.items():
                self.assertEqual((case.data / name).read_bytes(), data)
            case.assert_shared_unchanged()

    def test_missing_builtin_pair_is_not_a_patch_prerequisite(self):
        for action in ['Verify', 'Apply', 'Verify', 'Restore']:
            self.case.run_action(action)
        for name in EXCLUDED:
            self.assertFalse((self.case.data / name).exists())

    def test_unrelated_readonly_guard_still_blocks_writes(self):
        case = self.case
        name = 'StreamingAssets/.res/default_package/BuildinCatalog.bytes'
        path = case.data / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(b'changed-catalog')
        case.plan['readonly_files'].append({'relative_path': name, 'sha256': shared.sha(b'original-catalog')})
        case.write_plan()
        self.assertIn('原版只读基线不匹配：' + name, case.run_action('Apply', 1))
        self.assertEqual((case.data / 'resources.assets').read_bytes(), case.original)


if __name__ == '__main__':
    unittest.main()
