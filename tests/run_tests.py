# -*- coding: utf-8 -*-
"""Isolated automated test suite for Azur-Promilia-Chinese-Translation-Script.

Never touches any real game installation. Uses temporary directories only.
"""
import ctypes
import hashlib
import json
import os
import shutil
import struct
import subprocess
import sys
import tempfile
import time
import unittest
import zipfile
from ctypes import wintypes
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CRC_DIR = ROOT / 'CRC工具' / 'crc'
sys.path.insert(0, str(CRC_DIR))

import crcchain
import crcpatch
import pool_capacity


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


def make_crc_matched_pair(seed: bytes, seg_sizes=(4096, 8192, 513)):
    """Build (original_bytes, target_bytes, segments) with identical size, full CRC, and segment CRCs."""
    orig = bytearray()
    targ = bytearray()
    segments = []
    offset = 0
    for idx, sz in enumerate(seg_sizes):
        chunk_orig = bytearray(hashlib.sha256(seed + f':orig:{idx}'.encode()).digest() * ((sz // 32) + 1))[:sz]
        chunk_targ = bytearray(hashlib.sha256(seed + f':targ:{idx}'.encode()).digest() * ((sz // 32) + 1))[:sz]
        target_seg_crc = crc32_u32(chunk_orig)
        assert crcpatch.patch_crc(chunk_targ, target_seg_crc, sz - 4)
        assert crc32_u32(chunk_targ) == target_seg_crc
        segments.append({
            'bundle_index': idx,
            'offset': offset,
            'size': sz,
            'crc32': target_seg_crc,
        })
        orig.extend(chunk_orig)
        targ.extend(chunk_targ)
        offset += sz
    assert len(orig) == len(targ)
    assert crc32_u32(orig) == crc32_u32(targ)
    return bytes(orig), bytes(targ), segments


def crc32_u32(data: bytes) -> int:
    import zlib
    return zlib.crc32(data) & 0xFFFFFFFF


def b38_encode(s: str) -> tuple[int, int]:
    alpha = crcchain.ALPHA
    def enc(part):
        v = 0
        for ch in part:
            v = v * 38 + alpha.index(ch)
        return v
    mid = max(0, len(s) - 9)
    return enc(s[:mid]), enc(s[mid:])


def pack_str(s: str) -> bytes:
    b = s.encode('utf-8')
    return struct.pack('<H', len(b)) + b


def build_synthetic_manifest(
    pack_name: str,
    segs_data: list[bytes],
    package: str = 'DefaultPackage',
    version: str = '100',
    bundle_indices: list[int] | None = None,
) -> tuple[bytes, bytes]:
    buf = bytearray()
    buf += struct.pack('<I', crcchain.MAGIC)
    buf += pack_str('2.3.1')
    buf += struct.pack('<3Bii', 1, 0, 0, 1, 0)
    for s in ('Builtin', package, version, 'test'):
        buf += pack_str(s)
    # assets (0)
    buf += struct.pack('<i', 0)
    # asset_depend_pool (0)
    buf += struct.pack('<i', 0)
    # bundles
    buf += struct.pack('<i', len(segs_data))
    offset = 0
    pack_bytes = bytearray()
    for i, sd in enumerate(segs_data):
        b_idx = i if bundle_indices is None else bundle_indices[i]
        buf += struct.pack('<qIiiiiiiqIi4B', len(sd), crc32_u32(sd), b_idx, 0, 0, 0, 0, 0, offset, 0, b_idx, 0, 0, 0, 0)
        pack_bytes.extend(sd)
        offset += len(sd)
    # bundle_reference_pool (0)
    buf += struct.pack('<i', 0)
    # hashes
    buf += struct.pack('<i', len(segs_data))
    for i in range(len(segs_data)):
        buf += struct.pack('<QQ', i + 1, i + 100)
    # packs (1)
    n0, n1 = b38_encode(pack_name)
    buf += struct.pack('<i', 1)
    buf += struct.pack('<QQQQqII', n0, n1, 0, 0, len(pack_bytes), 1, crc32_u32(pack_bytes))
    return bytes(buf), bytes(pack_bytes)


def run_ps(script: Path, args: list[str], cwd: Path = ROOT) -> subprocess.CompletedProcess:
    cmd = ['powershell.exe', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', str(script)] + args
    return subprocess.run(cmd, cwd=str(cwd), stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=120)


def remove_temp_dir(path: Path):
    if not path.exists():
        return
    # Safely unlink any directory junctions before rmtree so we never recurse into targets.
    for base, dirs, files in os.walk(path, topdown=True, followlinks=False):
        for name in list(dirs):
            p = Path(base) / name
            if p.is_junction():
                os.rmdir(p)
                dirs.remove(name)
            elif p.is_symlink():
                p.unlink()
                dirs.remove(name)
    shutil.rmtree(path, ignore_errors=True)


class TestBatchEntryPoint(unittest.TestCase):
    def test_actual_batch_reaches_real_menu(self):
        with tempfile.TemporaryDirectory(prefix='azur_menu_') as td:
            pack = Path(td) / '中文 空格 (菜单)&!'
            copy_tool_tree(pack)
            game = Path(td) / 'mock_game'
            (game / 'AzurPromilia_Data').mkdir(parents=True)
            (game / 'AzurPromilia.exe').write_bytes(b'MOCKEXE')
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
                    self.assertIn('原版备份：', output)
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
            self.assertIn('原版备份：', output)
            self.assertEqual(config.read_bytes(), before)
            self.assertFalse((pack / 'tools/logs').exists())

    def test_menu_prints_once_after_results_and_errors(self):
        with tempfile.TemporaryDirectory(prefix='azur_menu_once_') as td:
            pack = self._mock_menu_pack(td)
            output = self._run_mock_menu(pack, ['5', '1', 'bogus', '5', 'Q'], expected=1)
            self.assertIn('payload 不存在', output)
            self.assertIn('无效选项，请重新输入。', output)
            self.assertEqual(output.count('原版备份：'), 2)
            self.assertEqual(output.count('找到以下项目：'), 1)
            for label in ('1. 全部汉化', '2. 全部还原', '3. 选择项目汉化',
                          '4. 选择项目还原', '5. 查看文件状态', '6. 完整校验',
                          '7. 手动添加/修改安装目录', 'Q. 退出'):
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


class TestCrcPatch(unittest.TestCase):
    def test_patch_crc_positions(self):
        rng = os.urandom(65536)
        for pos in (0, 123, 32768, len(rng) - 4):
            buf = bytearray(rng)
            orig_crc = crc32_u32(buf)
            target_patch_off = 5000 if pos != 5000 else 100
            buf[target_patch_off:target_patch_off + 16] = b'AZUR_PROMILIA_ZH'
            self.assertTrue(crcpatch.patch_crc(buf, orig_crc, pos))
            self.assertEqual(len(buf), len(rng))
            self.assertEqual(crc32_u32(buf), orig_crc)

    def test_patch_crc_with_current_crc(self):
        buf = bytearray(os.urandom(128 * 1024))
        orig_crc = crc32_u32(buf)
        buf[200:264] = b'X' * 64
        cur = crc32_u32(buf)
        self.assertTrue(crcpatch.patch_crc(buf, orig_crc, 4096, current_crc=cur))
        self.assertEqual(crc32_u32(buf), orig_crc)

    def test_crc32_delta_matches_full_scan(self):
        base = bytearray(os.urandom(20000))
        base_crc = crc32_u32(base)
        for a, b in ((0, 17), (100, 355), (19900, 20000)):
            diff = os.urandom(b - a)
            mod = bytearray(base)
            for idx, val in enumerate(diff):
                mod[a + idx] ^= val
            expected_delta = crc32_u32(mod) ^ base_crc
            actual_delta = crcpatch.crc32_delta(diff, len(base) - b)
            self.assertEqual(actual_delta, expected_delta)

    def test_large_buffer_speed(self):
        buf = bytearray(os.urandom(2 * 1024 * 1024))
        orig_crc = crc32_u32(buf)
        buf[1000:1032] = b'A' * 32
        t0 = time.monotonic()
        self.assertTrue(crcpatch.patch_crc(buf, orig_crc, 500000))
        elapsed = time.monotonic() - t0
        self.assertEqual(crc32_u32(buf), orig_crc)
        self.assertLess(elapsed, 2.0)


class TestCrcChain(unittest.TestCase):
    def test_parse_verify_and_rebuild(self):
        with tempfile.TemporaryDirectory() as td:
            td_path = Path(td)
            manifest, pack = build_synthetic_manifest('testpack.r', [b'A' * 1024, b'B' * 2048])
            pack_path = td_path / 'testpack.r'
            pack_path.write_bytes(pack)
            parsed = crcchain.parse(manifest)
            self.assertEqual(parsed['version'], '100')
            self.assertEqual(crcchain.verify(manifest, pack_path), [])

            # Variable-length rebuild updates offsets, sizes, CRCs, and MD5 hash
            new_pack, new_manifest, new_hash, report = crcchain.rebuild(manifest, pack_path, {0: b'C' * 1500})
            self.assertEqual(len(new_pack), 1500 + 2048)
            new_pack_path = td_path / 'new_testpack.r'
            new_pack_path.write_bytes(new_pack)
            # Rename to match pack name in manifest
            pack_path.write_bytes(new_pack)
            self.assertEqual(crcchain.verify(new_manifest, pack_path), [])
            self.assertEqual(new_hash, hashlib.md5(new_manifest).hexdigest().encode('ascii'))
            self.assertEqual(len(report['changes']), 1)

            # Tamper detection
            bad = bytearray(new_pack)
            bad[1600] ^= 0xFF
            pack_path.write_bytes(bad)
            errs = crcchain.verify(new_manifest, pack_path)
            self.assertTrue(any('pack crc' in e for e in errs))
            self.assertTrue(any('bundle 1 crc' in e for e in errs))


class TestLocalizationNativePS51(unittest.TestCase):
    def test_slicing8_and_verify_file(self):
        with tempfile.TemporaryDirectory() as td:
            td_path = Path(td)
            common = ROOT / 'tools' / 'Localization-Common.ps1'
            cases = []
            for length in (0, 1, 7, 8, 9, 15, 16, 1048576 + 13):
                data = os.urandom(length)
                fp = td_path / f'f_{length}.bin'
                fp.write_bytes(data)
                cases.append((fp, length, sha256_bytes(data), crc32_u32(data)))

            # Also build a multi-segment file with contiguous, gapped, zero-byte, and overlapping segments
            multi_data = os.urandom(25000)
            multi_path = td_path / 'multi.r'
            multi_path.write_bytes(multi_data)
            segs = [
                (0, 5000, 0),
                (5000, 5000, 1),
                (12000, 3000, 2),
                (14000, 2000, 3),   # overlaps previous
                (18000, 0, 4),      # zero-byte segment
            ]
            seg_offsets = ','.join(str(s[0]) for s in segs)
            seg_sizes = ','.join(str(s[1]) for s in segs)
            seg_crcs = ','.join('[uint32]' + str(crc32_u32(multi_data[s[0]:s[0] + s[1]])) for s in segs)
            seg_ids = ','.join(str(s[2]) for s in segs)

            ps_lines = [
                f". '{common}'",
                "$ErrorActionPreference = 'Stop'",
            ]
            for fp, length, h, c in cases:
                ps_lines.append(f"$c = [LocalizationCRC]::Range('{fp}', 0, {length})")
                ps_lines.append(f"if ($c -ne [uint32]{c}) {{ throw 'Range mismatch for {length}' }}")
                ps_lines.append(f"$s = [LocalizationNative]::ComputeSha256('{fp}')")
                ps_lines.append(f"if ($s -ne '{h}') {{ throw 'SHA mismatch for {length}' }}")
                ps_lines.append(f"[LocalizationNative]::VerifyFile('{fp}', {length}, '{h}', $true, [uint32]{c}, $null, $null, $null, $null)")
            ps_lines.append(
                f"[LocalizationNative]::VerifyFile('{multi_path}', {len(multi_data)}, '{sha256_bytes(multi_data)}', $true, [uint32]{crc32_u32(multi_data)}, "
                f"[long[]]@({seg_offsets}), [long[]]@({seg_sizes}), [uint32[]]@({seg_crcs}), [int[]]@({seg_ids}))"
            )
            ps_lines.append("Write-Output 'NATIVE_OK'")

            test_ps = td_path / 'test_native.ps1'
            write_ps1(test_ps, '\n'.join(ps_lines))
            proc = run_ps(test_ps, [])
            out = proc.stdout.decode('utf-8', 'replace')
            self.assertEqual(proc.returncode, 0, out)
            self.assertIn('NATIVE_OK', out)


class TestGameScriptsEndToEnd(unittest.TestCase):
    def _setup_mock_game(self, region: str):
        td = Path(tempfile.mkdtemp(prefix=f'azur_test_{region}_'))
        self.addCleanup(remove_temp_dir, td)
        pack = td / 'pack'
        copy_tool_tree(pack)

        is_tw = region == 'tw'
        game_dir_name = 'AzurPromilia_TC_game' if is_tw else 'AZUPRO_JP'
        data_dir_name = 'AzurPromilia_Data' if is_tw else 'AzurPromiliaJP_Data'
        exe_name = 'AzurPromilia.exe' if is_tw else 'AzurPromiliaJP.exe'
        payload_sub = 'tw_game' if is_tw else 'jp_game'
        backup_name = '.zhcn-crc-readonly-3221745-backup' if is_tw else '.zhcn-jp-crc-readonly-3219598-backup'
        script_name = 'Apply-CRCZH.ps1' if is_tw else 'Apply-JPCRCZH.ps1'
        dep_name = f'{region}-deployment.json'

        game_root = td / game_dir_name
        data_root = game_root / data_dir_name
        data_root.mkdir(parents=True)
        (game_root / exe_name).write_bytes(b'MOCKEXE')

        r1_rel = '.res/raw_base_package/BundleFiles/mockpackone.r'
        r2_rel = 'StreamingAssets/.res/default_package/mockpacktwo.r'
        assets_rel = 'resources.assets'
        guard_rel = '.res/raw_base_package/ManifestFiles/0release_raw_base_package_test.bytes'

        o1, t1, s1 = make_crc_matched_pair(b'r1', (4096, 4096))
        o2, t2, s2 = make_crc_matched_pair(b'r2', (2048, 3072))
        oa = b'ORIG_RESOURCES_ASSETS_DATA'
        ta = b'ZHCN_RESOURCES_ASSETS_DATA'
        guard_bytes = b'OOY\0MOCK_READONLY_MANIFEST'

        file_records = []
        for rel, o_bytes, t_bytes, segs in (
            (r1_rel, o1, t1, s1),
            (r2_rel, o2, t2, s2),
            (assets_rel, oa, ta, None),
        ):
            gp = data_root / rel
            gp.parent.mkdir(parents=True, exist_ok=True)
            gp.write_bytes(o_bytes)
            pp = pack / 'payload' / payload_sub / rel
            pp.parent.mkdir(parents=True, exist_ok=True)
            pp.write_bytes(t_bytes)
            rec = {
                'relative_path': rel,
                'source_sha256': sha256_bytes(o_bytes),
                'target_sha256': sha256_bytes(t_bytes),
                'size': len(o_bytes),
            }
            if segs is not None:
                rec['crc32'] = crc32_u32(o_bytes)
                rec['segments'] = segs
            file_records.append(rec)

        gp_guard = data_root / guard_rel
        gp_guard.parent.mkdir(parents=True, exist_ok=True)
        gp_guard.write_bytes(guard_bytes)

        plan = {
            'format': 1,
            'region': region,
            'resource_version': 'testver',
            'files': file_records,
            'readonly_files': [{'relative_path': guard_rel, 'sha256': sha256_bytes(guard_bytes)}],
            'runtime_login_verified': False,
        }
        (pack / 'tools' / dep_name).write_text(json.dumps(plan, indent=2), 'utf-8')
        return td, pack, game_root, data_root, pack / 'tools' / script_name, backup_name, plan

    def _run_region_lifecycle(self, region: str):
        td, pack, game_root, data_root, script, backup_name, plan = self._setup_mock_game(region)

        # 1. ValidatePayload
        p = run_ps(script, ['-Action', 'ValidatePayload'])
        self.assertEqual(p.returncode, 0, p.stdout.decode('utf-8', 'replace'))

        # 2. Tamper readonly guard -> Apply must fail BEFORE creating backup directory
        guard_path = data_root / plan['readonly_files'][0]['relative_path']
        saved_guard = guard_path.read_bytes()
        guard_path.write_bytes(b'TAMPERED')
        p = run_ps(script, ['-Action', 'Apply', '-Hint', str(game_root)])
        self.assertEqual(p.returncode, 1)
        self.assertFalse((game_root / backup_name).exists())
        guard_path.write_bytes(saved_guard)

        # 3. Normal Apply
        p = run_ps(script, ['-Action', 'Apply', '-Hint', str(game_root)])
        out = p.stdout.decode('utf-8', 'replace')
        self.assertEqual(p.returncode, 0, out)
        for rec in plan['files']:
            self.assertEqual(sha256_bytes((data_root / rec['relative_path']).read_bytes()), rec['target_sha256'])
            self.assertEqual(sha256_bytes((game_root / backup_name / rec['relative_path']).read_bytes()), rec['source_sha256'])
        # Ensure transactions/ staging folder is cleaned up automatically
        self.assertFalse((game_root / backup_name / 'transactions').exists())

        # 4. Verify & Idempotent Apply
        self.assertEqual(run_ps(script, ['-Action', 'Verify', '-Hint', str(game_root)]).returncode, 0)
        p_idem = run_ps(script, ['-Action', 'Apply', '-Hint', str(game_root)])
        self.assertEqual(p_idem.returncode, 0)
        self.assertIn('无需修改', p_idem.stdout.decode('utf-8', 'replace'))

        # 5. Mid-transaction lock failure during Restore must roll back cleanly and clean transactions/
        kernel = ctypes.WinDLL('kernel32', use_last_error=True)
        kernel.CreateFileW.argtypes = [wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD,
                                      wintypes.LPVOID, wintypes.DWORD, wintypes.DWORD, wintypes.HANDLE]
        kernel.CreateFileW.restype = wintypes.HANDLE
        kernel.CloseHandle.argtypes = [wintypes.HANDLE]
        locked_target = data_root / plan['files'][1]['relative_path']
        handle = kernel.CreateFileW(str(locked_target), 0x80000000, 1, None, 3, 0x80, None)
        self.assertNotEqual(handle, ctypes.c_void_p(-1).value)
        try:
            p_fail = run_ps(script, ['-Action', 'Restore', '-Hint', str(game_root)])
            out_fail = p_fail.stdout.decode('utf-8', 'replace')
            self.assertEqual(p_fail.returncode, 1, out_fail)
            self.assertIn('已回滚到操作前', out_fail)
            # First file must be rolled back to target_sha256
            self.assertEqual(sha256_bytes((data_root / plan['files'][0]['relative_path']).read_bytes()), plan['files'][0]['target_sha256'])
            self.assertFalse((game_root / backup_name / 'transactions').exists())
        finally:
            kernel.CloseHandle(handle)

        # 6. Restore WITHOUT payload/ directory present
        shutil.rmtree(pack / 'payload')
        p_rest = run_ps(script, ['-Action', 'Restore', '-Hint', str(game_root)])
        self.assertEqual(p_rest.returncode, 0, p_rest.stdout.decode('utf-8', 'replace'))
        for rec in plan['files']:
            self.assertEqual(sha256_bytes((data_root / rec['relative_path']).read_bytes()), rec['source_sha256'])

        # 7. Junction / reparse point refusal
        junction = td / 'game_junction'
        mk = subprocess.run(['cmd', '/c', 'mklink', '/J', str(junction), str(game_root)],
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        self.assertEqual(mk.returncode, 0)
        p_junc = run_ps(script, ['-Action', 'Verify', '-Hint', str(junction)])
        self.assertEqual(p_junc.returncode, 1)
        self.assertIn('重解析点', p_junc.stdout.decode('utf-8', 'replace'))

    def test_tw_and_jp_lifecycle(self):
        self._run_region_lifecycle('tw')
        self._run_region_lifecycle('jp')


class TestLauncherScriptsEndToEnd(unittest.TestCase):
    def test_launcher_apply_upgrade_restore_without_payload(self):
        with tempfile.TemporaryDirectory(prefix='azur_launcher_') as td:
            td_path = Path(td)
            pack = td_path / 'pack'
            copy_tool_tree(pack)

            orig = b'ORIGINAL_ASAR_CONTENT_123456'
            prev = b'PREVIOUS_ZH_ASAR_CONTENT_123'
            targ = b'TARGET_ZH_ASAR_CONTENT_V3_999'

            l_root = td_path / 'tw_launcher_dir'
            (l_root / 'resources').mkdir(parents=True)
            (l_root / 'launcher.exe').write_bytes(b'EXE')
            asar = l_root / 'resources' / 'app.asar'
            asar.write_bytes(orig)

            pay_asar = pack / 'payload' / 'tw_launcher' / 'resources' / 'app.asar'
            pay_asar.parent.mkdir(parents=True)
            pay_asar.write_bytes(targ)

            plan = {
                'schema_version': 1,
                'module': 'launchers',
                'launchers': [
                    {
                        'id': 'tw_launcher',
                        'label': '台服启动器',
                        'version': '1.0.1.4',
                        'exe': 'launcher.exe',
                        'relative_path': 'resources/app.asar',
                        'backup_suffix': '.before-zhcn-20261124.bak',
                        'source_sha256': sha256_bytes(orig),
                        'search_subpaths': ['AzurPromilia_TC'],
                        'target_sha256': sha256_bytes(targ),
                        'previous_sha256': [sha256_bytes(prev)],
                        'payload_dir': 'tw_launcher',
                        'size': len(targ),
                    }
                ],
            }
            (pack / 'tools' / 'launcher-deployment.json').write_text(json.dumps(plan, indent=2), 'utf-8')
            script = pack / 'tools' / 'Apply-Launchers.ps1'

            self.assertEqual(run_ps(script, ['-Action', 'ValidatePayload', '-Target', 'tw_launcher']).returncode, 0)
            p_v0 = run_ps(script, ['-Action', 'Verify', '-Target', 'tw_launcher', '-Hint', str(l_root)])
            self.assertEqual(p_v0.returncode, 0)
            self.assertIn('ORIGINAL', p_v0.stdout.decode('utf-8', 'replace'))

            p_app = run_ps(script, ['-Action', 'Apply', '-Target', 'tw_launcher', '-Hint', str(l_root)])
            self.assertEqual(p_app.returncode, 0, p_app.stdout.decode('utf-8', 'replace'))
            self.assertEqual(asar.read_bytes(), targ)

            # Simulate prior localized version with valid canonical backup -> Verify returns 2, Apply upgrades
            asar.write_bytes(prev)
            p_prev = run_ps(script, ['-Action', 'Verify', '-Target', 'tw_launcher', '-Hint', str(l_root)])
            self.assertEqual(p_prev.returncode, 2)
            self.assertIn('PRIOR_NEEDS_UPGRADE', p_prev.stdout.decode('utf-8', 'replace'))
            self.assertEqual(run_ps(script, ['-Action', 'Apply', '-Target', 'tw_launcher', '-Hint', str(l_root)]).returncode, 0)
            self.assertEqual(asar.read_bytes(), targ)

            # Delete payload/ and verify Restore + Verify still succeed!
            shutil.rmtree(pack / 'payload')
            p_rest = run_ps(script, ['-Action', 'Restore', '-Target', 'tw_launcher', '-Hint', str(l_root)])
            self.assertEqual(p_rest.returncode, 0, p_rest.stdout.decode('utf-8', 'replace'))
            self.assertEqual(asar.read_bytes(), orig)
            self.assertEqual(run_ps(script, ['-Action', 'Verify', '-Target', 'tw_launcher', '-Hint', str(l_root)]).returncode, 0)


class TestManageAndLocateEndToEnd(unittest.TestCase):
    def test_manage_check_and_missing_payload_message(self):
        # ScriptsOnly CheckPackage on actual repo must pass
        p = run_ps(ROOT / 'tools' / 'Manage-Localization.ps1', ['-Action', 'CheckPackage', '-ScriptsOnly'])
        out = p.stdout.decode('utf-8', 'replace')
        self.assertEqual(p.returncode, 0, out)
        self.assertIn('整合包文件校验通过', out)

        # Apply without payload/ must give friendly Releases guidance
        with tempfile.TemporaryDirectory() as td:
            pack = Path(td) / 'pack'
            copy_tool_tree(pack)
            p2 = run_ps(pack / 'tools' / 'Manage-Localization.ps1', ['-Action', 'Apply', '-Target', 'tw_game', '-Hint', td])
            out2 = p2.stdout.decode('utf-8', 'replace')
            self.assertNotEqual(p2.returncode, 0)
            self.assertIn('Releases', out2)

    def test_manage_full_flow_with_paths_json(self):
        with tempfile.TemporaryDirectory(prefix='azur_mgr_') as td:
            td_path = Path(td)
            pack = td_path / 'pack'
            copy_tool_tree(pack)

            # Mock TW game
            game_root = td_path / 'CustomFolder' / 'AzurPromilia_TC_game'
            data_root = game_root / 'AzurPromilia_Data'
            data_root.mkdir(parents=True)
            (game_root / 'AzurPromilia.exe').write_bytes(b'EXE')
            orig_a = b'ORIG_ASSETS'
            targ_a = b'TARG_ASSETS'
            (data_root / 'resources.assets').write_bytes(orig_a)
            pay_a = pack / 'payload' / 'tw_game' / 'resources.assets'
            pay_a.parent.mkdir(parents=True)
            pay_a.write_bytes(targ_a)
            tw_plan = {
                'format': 1,
                'region': 'tw',
                'resource_version': 'test',
                'files': [{
                    'relative_path': 'resources.assets',
                    'source_sha256': sha256_bytes(orig_a),
                    'target_sha256': sha256_bytes(targ_a),
                    'size': len(orig_a),
                }],
                'readonly_files': [],
            }
            (pack / 'tools' / 'tw-deployment.json').write_text(json.dumps(tw_plan, indent=2), 'utf-8')

            # Update tw-deployment.json and tw_game payload in package-files.json for this isolated pack
            cat_path = pack / 'tools' / 'package-files.json'
            cat = json.loads(cat_path.read_text('utf-8-sig'))
            tw_dep_bytes = (pack / 'tools' / 'tw-deployment.json').read_bytes()
            new_cat_files = []
            for x in cat['files']:
                if x['path'].startswith('payload/'):
                    continue
                if x['path'] == 'tools/tw-deployment.json':
                    new_cat_files.append({
                        'path': 'tools/tw-deployment.json',
                        'size': len(tw_dep_bytes),
                        'sha256': sha256_bytes(tw_dep_bytes),
                    })
                else:
                    new_cat_files.append(x)
            new_cat_files.append({
                'path': 'payload/tw_game/resources.assets',
                'size': len(targ_a),
                'sha256': sha256_bytes(targ_a),
            })
            cat['files'] = new_cat_files
            cat_path.write_text(json.dumps(cat, indent=2), 'utf-8')

            # Configure tools/安装路径.json
            (pack / 'tools' / '安装路径.json').write_text(json.dumps({
                'tw_game': str(game_root),
                'jp_game': '',
                'tw_launcher': '',
                'jp_launcher': '',
            }, ensure_ascii=False, indent=2), 'utf-8')

            mgr = pack / 'tools' / 'Manage-Localization.ps1'
            p_apply = run_ps(mgr, ['-Action', 'Apply', '-Target', 'tw_game'])
            self.assertEqual(p_apply.returncode, 0, p_apply.stdout.decode('utf-8', 'replace'))
            self.assertEqual((data_root / 'resources.assets').read_bytes(), targ_a)

            p_verify = run_ps(mgr, ['-Action', 'Verify', '-Target', 'tw_game'])
            self.assertEqual(p_verify.returncode, 0, p_verify.stdout.decode('utf-8', 'replace'))

            p_restore = run_ps(mgr, ['-Action', 'Restore', '-Target', 'tw_game'])
            self.assertEqual(p_restore.returncode, 0, p_restore.stdout.decode('utf-8', 'replace'))
            self.assertEqual((data_root / 'resources.assets').read_bytes(), orig_a)

            # Check result.json was written
            res_files = list((pack / 'tools' / 'logs').rglob('result.json'))
            self.assertGreaterEqual(len(res_files), 3)
            self.assertTrue(json.loads(res_files[0].read_text('utf-8'))['success'])


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
                [sys.executable, str(pack / 'build_release.py'), '--payload', str(payload), '--output', str(out_dir), '--version', 'vtest'],
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
            with zipfile.ZipFile(src_zip) as zf:
                prefix = '蓝色星原简体汉化-源码/'
                names = set(zf.namelist())
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


class TestPoolCapacity(unittest.TestCase):
    def test_nonmonotonic_occupied_bucket_count(self):
        hashes = [i * 100003 for i in range(50000)]
        self.assertEqual(pool_capacity.choose_max_prime_capacity(hashes, 1000044), 100003)

    def test_capacity_matches_exhaustive_search(self):
        import random
        rng = random.Random(20261126)
        for _ in range(100):
            hashes = [rng.randrange(10000) for _ in range(rng.randrange(20))]
            maximum = rng.randrange(2, 100)
            budget = 24 + 12 * len(hashes) + rng.randrange(500)
            feasible = [cap for cap in range(2, maximum + 1)
                        if pool_capacity.is_prime(cap)
                        and 24 + 12 * len(hashes) + 4 * cap
                        + 4 * len({h % cap for h in hashes}) <= budget - 4]
            if feasible:
                self.assertEqual(pool_capacity.choose_max_prime_capacity(
                    hashes, budget, min_cap=2, max_cap=maximum), max(feasible))
            else:
                with self.assertRaises(ValueError):
                    pool_capacity.choose_max_prime_capacity(
                        hashes, budget, min_cap=2, max_cap=maximum)

    def test_is_prime_and_choose_max_prime_capacity(self):
        for p in (2, 3, 5, 65521, 524287, 999983, 2009191):
            self.assertTrue(pool_capacity.is_prime(p))
        for c in (0, 1, 4, 9, 100, 524289, 1000001):
            self.assertFalse(pool_capacity.is_prime(c))

        # Scaled TW-like budget: 180,000 hashes, hash_total = 2,893,289 bytes (1/10 of TW 28.93 MB)
        # Verify it picks the maximal prime capacity (~99k) rather than falling back to 65521.
        hashes = [((i * 2654435761) ^ (i >> 3)) & 0xFFFFFFFFFFFFFFFF for i in range(180000)]
        hash_total = 2893289
        cap = pool_capacity.choose_max_prime_capacity(hashes, hash_total, min_padding=4, min_cap=65521)
        self.assertTrue(pool_capacity.is_prime(cap))
        occupied = len({h % cap for h in hashes})
        used = 24 + 4 * cap + 4 * occupied + 12 * len(hashes)
        self.assertLessEqual(used, hash_total - 4)
        self.assertGreater(cap, 90000)

        # Verify the very next prime above cap does not fit in the budget
        np = cap + 2
        while not pool_capacity.is_prime(np):
            np += 2
        next_used = 24 + 4 * np + 4 * len({h % np for h in hashes}) + 12 * len(hashes)
        self.assertGreater(next_used, hash_total - 4)

        with self.assertRaises(ValueError):
            pool_capacity.choose_max_prime_capacity(hashes, 100000, min_padding=4, min_cap=65521)


class TestHotfixManifestRelocation(unittest.TestCase):
    def _write_manifest(self, data_root: Path, pkg: str, ver: str, pack_name: str,
                        segs_data: list[bytes], bundle_indices: list[int]) -> bytes:
        m_bytes, p_bytes = build_synthetic_manifest(
            pack_name, segs_data, package=pkg, version=ver, bundle_indices=bundle_indices,
        )
        m_dir = data_root / '.res' / pkg / 'ManifestFiles'
        m_dir.mkdir(parents=True, exist_ok=True)
        (m_dir / f'0release_{pkg}_{ver}.bytes').write_bytes(m_bytes)
        (m_dir / f'0release_{pkg}_{ver}.hash').write_bytes(
            hashlib.md5(m_bytes).hexdigest().encode('ascii')
        )
        b_dir = data_root / '.res' / pkg / 'BundleFiles'
        b_dir.mkdir(parents=True, exist_ok=True)
        (b_dir / pack_name).write_bytes(p_bytes)
        return p_bytes

    def _setup_hotfix_fixture(self, td_path: Path):
        pack = td_path / 'pack'
        copy_tool_tree(pack)

        game_root = td_path / 'AzurPromilia_TC_game'
        data_root = game_root / 'AzurPromilia_Data'
        data_root.mkdir(parents=True)
        (game_root / 'AzurPromilia.exe').write_bytes(b'EXE')

        # raw_base_package stays byte-identical across 3221745 -> 3221746
        rb_orig, rb_targ, rb_segs = make_crc_matched_pair(b'hotfix_rb', (4096,))
        rb_name = 'rawbasepack.r'
        self._write_manifest(data_root, 'raw_base_package', '3221745', rb_name, [rb_orig], [12])

        # default_package: seg0 (patched), seg1 (unmodified middle), seg2 (patched)
        s0_o, s0_t, _ = make_crc_matched_pair(b'hotfix_d0', (2048,))
        s1_orig = b'UNMODIFIED_MIDDLE_SEGMENT_' + b'A' * 300
        s1_hotfix = b'UNMODIFIED_MIDDLE_SHORTER' + b'B' * 291  # 10 bytes shorter -> seg2 shifts -10
        self.assertEqual(len(s1_orig) - len(s1_hotfix), 10)
        s2_o, s2_t, _ = make_crc_matched_pair(b'hotfix_d2', (1536,))

        old_def_name = 'olddefaultpack.r'
        new_def_name = 'newdefaultpack.r'
        old_def_orig = self._write_manifest(
            data_root, 'default_package', '3221745', old_def_name,
            [s0_o, s1_orig, s2_o], [10, 11, 12],
        )
        old_def_targ = s0_t + s1_orig + s2_t
        self.assertEqual(len(old_def_targ), len(old_def_orig))
        self.assertEqual(crc32_u32(old_def_targ), crc32_u32(old_def_orig))

        fp_bytes = b'FOOTPRINT_3221745'
        for pkg in ('raw_base_package', 'default_package'):
            fp = data_root / '.res' / pkg / 'ManifestFiles' / 'ApplicationFootPrint.bytes'
            fp.write_bytes(fp_bytes)

        # Write payload for baseline 3221745
        rb_rel = f'.res/raw_base_package/BundleFiles/{rb_name}'
        def_rel = f'.res/default_package/BundleFiles/{old_def_name}'
        for rel, data in ((rb_rel, rb_targ), (def_rel, old_def_targ)):
            pp = pack / 'payload' / 'tw_game' / rel
            pp.parent.mkdir(parents=True, exist_ok=True)
            pp.write_bytes(data)

        def_segs = [
            {'bundle_index': 10, 'offset': 0, 'size': len(s0_o), 'crc32': crc32_u32(s0_o)},
            {'bundle_index': 11, 'offset': len(s0_o), 'size': len(s1_orig), 'crc32': crc32_u32(s1_orig)},
            {'bundle_index': 12, 'offset': len(s0_o) + len(s1_orig), 'size': len(s2_o), 'crc32': crc32_u32(s2_o)},
        ]
        def_patched_segs = [
            {
                'bundle_index': 10, 'offset': 0, 'size': len(s0_o),
                'crc32': crc32_u32(s0_o), 'target_sha256': sha256_bytes(s0_t),
            },
            {
                'bundle_index': 12, 'offset': len(s0_o) + len(s1_orig), 'size': len(s2_o),
                'crc32': crc32_u32(s2_o), 'target_sha256': sha256_bytes(s2_t),
            },
        ]

        ro_files = []
        for pkg in ('raw_base_package', 'default_package'):
            for suffix in ('bytes', 'hash'):
                rel = f'.res/{pkg}/ManifestFiles/0release_{pkg}_3221745.{suffix}'
                ro_files.append({'relative_path': rel, 'sha256': sha256_bytes((data_root / rel).read_bytes())})
            fp_rel = f'.res/{pkg}/ManifestFiles/ApplicationFootPrint.bytes'
            ro_files.append({'relative_path': fp_rel, 'sha256': sha256_bytes(fp_bytes)})

        plan = {
            'format': 1,
            'region': 'tw',
            'resource_version': '3221745',
            'files': [
                {
                    'relative_path': rb_rel,
                    'source_sha256': sha256_bytes(rb_orig),
                    'target_sha256': sha256_bytes(rb_targ),
                    'size': len(rb_orig),
                    'crc32': crc32_u32(rb_orig),
                    'segments': [{'bundle_index': 12, 'offset': 0, 'size': len(rb_orig), 'crc32': crc32_u32(rb_orig)}],
                    'patched_segments': [{
                        'bundle_index': 12, 'offset': 0, 'size': len(rb_orig),
                        'crc32': crc32_u32(rb_orig), 'target_sha256': sha256_bytes(rb_targ),
                    }],
                },
                {
                    'relative_path': def_rel,
                    'source_sha256': sha256_bytes(old_def_orig),
                    'target_sha256': sha256_bytes(old_def_targ),
                    'size': len(old_def_orig),
                    'crc32': crc32_u32(old_def_orig),
                    'segments': def_segs,
                    'patched_segments': def_patched_segs,
                },
            ],
            'readonly_files': ro_files,
            'runtime_login_verified': False,
        }
        (pack / 'tools' / 'tw-deployment.json').write_text(json.dumps(plan, indent=2), 'utf-8')
        return {
            'pack': pack,
            'game_root': game_root,
            'data_root': data_root,
            'script': pack / 'tools' / 'Apply-CRCZH.ps1',
            'mgr': pack / 'tools' / 'Manage-Localization.ps1',
            'rb_name': rb_name,
            'rb_orig': rb_orig,
            'rb_targ': rb_targ,
            'old_def_name': old_def_name,
            'new_def_name': new_def_name,
            's0_o': s0_o,
            's0_t': s0_t,
            's1_hotfix': s1_hotfix,
            's2_o': s2_o,
            's2_t': s2_t,
        }

    def _apply_hotfix_3221746(self, fx: dict, carry_localized: bool = False):
        data_root = fx['data_root']
        # raw_base_package keeps BOTH 3221745 and 3221746 manifests
        self._write_manifest(
            data_root, 'raw_base_package', '3221746', fx['rb_name'],
            [fx['rb_targ'] if carry_localized else fx['rb_orig']], [12],
        )
        # default_package removes 3221745 manifest + old pack, writes 3221746 + renamed pack
        for suffix in ('bytes', 'hash'):
            old_m = data_root / '.res/default_package/ManifestFiles' / f'0release_default_package_3221745.{suffix}'
            if old_m.exists():
                old_m.unlink()
        old_pack = data_root / '.res/default_package/BundleFiles' / fx['old_def_name']
        if old_pack.exists():
            old_pack.unlink()

        segs = [
            fx['s0_t'] if carry_localized else fx['s0_o'],
            fx['s1_hotfix'],
            fx['s2_t'] if carry_localized else fx['s2_o'],
        ]
        return self._write_manifest(
            data_root, 'default_package', '3221746', fx['new_def_name'],
            segs, [10, 11, 12],
        )

    def test_hotfix_apply_verify_restore_with_shifted_segment(self):
        with tempfile.TemporaryDirectory(prefix='azur_hotfix_new_') as td:
            fx = self._setup_hotfix_fixture(Path(td))
            new_orig = self._apply_hotfix_3221746(fx, carry_localized=False)
            new_targ = fx['s0_t'] + fx['s1_hotfix'] + fx['s2_t']
            new_pack_path = fx['data_root'] / '.res/default_package/BundleFiles' / fx['new_def_name']
            rb_pack_path = fx['data_root'] / '.res/raw_base_package/BundleFiles' / fx['rb_name']

            p_v0 = run_ps(fx['script'], ['-Action', 'Verify', '-Hint', str(fx['game_root'])])
            out_v0 = p_v0.stdout.decode('utf-8', 'replace')
            self.assertEqual(p_v0.returncode, 0, out_v0)
            self.assertIn('原版 (热更适配 3221746)', out_v0)

            p_app = run_ps(fx['script'], ['-Action', 'Apply', '-Hint', str(fx['game_root'])])
            self.assertEqual(p_app.returncode, 0, p_app.stdout.decode('utf-8', 'replace'))
            self.assertEqual(rb_pack_path.read_bytes(), fx['rb_targ'])
            self.assertEqual(new_pack_path.read_bytes(), new_targ)

            p_v1 = run_ps(fx['script'], ['-Action', 'Verify', '-Hint', str(fx['game_root'])])
            out_v1 = p_v1.stdout.decode('utf-8', 'replace')
            self.assertEqual(p_v1.returncode, 0, out_v1)
            self.assertIn('汉化 (热更适配 3221746)', out_v1)

            # Check Manage-Localization.ps1 interactive summary + option 5 status
            (fx['pack'] / 'tools' / '安装路径.json').write_text(json.dumps({
                'tw_game': str(fx['game_root']), 'jp_game': '', 'tw_launcher': '', 'jp_launcher': '',
            }, ensure_ascii=False), 'utf-8')
            p_menu = subprocess.run(
                ['powershell.exe', '-NoProfile', '-ExecutionPolicy', 'Bypass',
                 '-File', str(fx['mgr']), '-Action', 'Menu'],
                input=b'5\r\nQ\r\n', stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                cwd=str(fx['pack']), timeout=60,
            )
            out_menu = p_menu.stdout.decode('utf-8', 'replace')
            self.assertEqual(p_menu.returncode, 0, out_menu)
            self.assertIn('[台服游戏] 已汉化', out_menu)
            self.assertIn('已汉化（热更 3221746）', out_menu)

            # Restore works even after payload/ is removed
            shutil.rmtree(fx['pack'] / 'payload')
            p_rest = run_ps(fx['script'], ['-Action', 'Restore', '-Hint', str(fx['game_root'])])
            self.assertEqual(p_rest.returncode, 0, p_rest.stdout.decode('utf-8', 'replace'))
            self.assertEqual(rb_pack_path.read_bytes(), fx['rb_orig'])
            self.assertEqual(new_pack_path.read_bytes(), new_orig)
            self.assertEqual(run_ps(fx['script'], ['-Action', 'Verify', '-Hint', str(fx['game_root'])]).returncode, 0)

    def test_hotfix_after_prior_apply_verify_and_restore_from_legacy_backup(self):
        with tempfile.TemporaryDirectory(prefix='azur_hotfix_prior_') as td:
            fx = self._setup_hotfix_fixture(Path(td))
            # Apply on 3221745 first -> creates legacy backup under old_def_name
            self.assertEqual(run_ps(fx['script'], ['-Action', 'Apply', '-Hint', str(fx['game_root'])]).returncode, 0)
            self._apply_hotfix_3221746(fx, carry_localized=True)
            new_pack_path = fx['data_root'] / '.res/default_package/BundleFiles' / fx['new_def_name']
            expected_orig = fx['s0_o'] + fx['s1_hotfix'] + fx['s2_o']

            p_v = run_ps(fx['script'], ['-Action', 'Verify', '-Hint', str(fx['game_root'])])
            out_v = p_v.stdout.decode('utf-8', 'replace')
            self.assertEqual(p_v.returncode, 0, out_v)
            self.assertIn('汉化 (热更适配 3221746)', out_v)

            p_idem = run_ps(fx['script'], ['-Action', 'Apply', '-Hint', str(fx['game_root'])])
            self.assertEqual(p_idem.returncode, 0, p_idem.stdout.decode('utf-8', 'replace'))
            self.assertIn('无需修改', p_idem.stdout.decode('utf-8', 'replace'))

            shutil.rmtree(fx['pack'] / 'payload')
            p_rest = run_ps(fx['script'], ['-Action', 'Restore', '-Hint', str(fx['game_root'])])
            self.assertEqual(p_rest.returncode, 0, p_rest.stdout.decode('utf-8', 'replace'))
            self.assertEqual(new_pack_path.read_bytes(), expected_orig)
            p_v2 = run_ps(fx['script'], ['-Action', 'Verify', '-Hint', str(fx['game_root'])])
            self.assertEqual(p_v2.returncode, 0, p_v2.stdout.decode('utf-8', 'replace'))
            self.assertIn('原版 (热更适配 3221746)', p_v2.stdout.decode('utf-8', 'replace'))

    def test_hotfix_rejects_modified_target_segment_and_tampered_manifest_hash(self):
        with tempfile.TemporaryDirectory(prefix='azur_hotfix_rej_') as td:
            fx = self._setup_hotfix_fixture(Path(td))
            self._apply_hotfix_3221746(fx, carry_localized=False)

            # (a) Tamper .hash MD5 -> Verify & Apply must fail
            hash_file = fx['data_root'] / '.res/default_package/ManifestFiles/0release_default_package_3221746.hash'
            saved_hash = hash_file.read_bytes()
            hash_file.write_bytes(b'0' * 32)
            p_bad_hash = run_ps(fx['script'], ['-Action', 'Apply', '-Hint', str(fx['game_root'])])
            self.assertEqual(p_bad_hash.returncode, 1)
            self.assertIn('MD5', p_bad_hash.stdout.decode('utf-8', 'replace'))
            self.assertFalse((fx['game_root'] / '.zhcn-crc-readonly-3221745-backup').exists())
            hash_file.write_bytes(saved_hash)

            # (b) Hotfix modifies target patched segment s2 -> must refuse cleanly
            modified_s2 = b'CHANGED_BY_MAJOR_UPDATE_' + b'Z' * (len(fx['s2_o']) - 24)
            new_pack = self._write_manifest(
                fx['data_root'], 'default_package', '3221746', fx['new_def_name'],
                [fx['s0_o'], fx['s1_hotfix'], modified_s2], [10, 11, 12],
            )
            p_mod = run_ps(fx['script'], ['-Action', 'Apply', '-Hint', str(fx['game_root'])])
            out_mod = p_mod.stdout.decode('utf-8', 'replace')
            self.assertEqual(p_mod.returncode, 1)
            self.assertIn('已修改目标资源段', out_mod)
            self.assertEqual((fx['data_root'] / '.res/default_package/BundleFiles' / fx['new_def_name']).read_bytes(), new_pack)
            self.assertFalse((fx['game_root'] / '.zhcn-crc-readonly-3221745-backup').exists())


if __name__ == '__main__':
    unittest.main(verbosity=2)

