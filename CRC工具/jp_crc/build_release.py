"""Build JP release from verified originals; never mutate live files/manifests."""
from pathlib import Path
import datetime
import hashlib
import json
import shutil
import sys
import zlib

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
sys.path[:0] = [str(HERE), str(HERE.parent / 'crc')]
from baseline import ORIG, LIVE, JP
import crcchain as C

OUT = ROOT / 'outputs/日服简体汉化-清单只读CRC版'
CAND = HERE / 'fixed_candidates'


def sha(b):
    return hashlib.sha256(b).hexdigest()


def copy_tool(name):
    src = ROOT / 'tools' / name
    if not src.is_file():
        src = HERE / name
    return src.read_text('utf-8-sig')


def main():
    old = json.loads((JP / 'deployment-plan.json').read_text('utf-8'))
    br = json.loads((HERE / 'bundle_report.json').read_text('utf-8'))
    assert br['status'] == 'complete'
    expected = {e['relative_path']: e for e in old['files']}
    resources = [r for r in expected if r.endswith('.r') or r == 'resources.assets']
    manifests = {}
    guards = {}
    man_report = []
    for rel in expected:
        if not rel.endswith('.bytes'):
            continue
        raw = (ORIG / rel).read_bytes()
        assert sha(raw) == expected[rel]['source_sha256']
        m = C.parse(raw)
        assert m['version'] in ('3219598', '3075915'), (rel, m['version'])
        hp = (ORIG / rel).with_suffix('.hash')
        assert hp.read_bytes().strip().lower() == hashlib.md5(raw).hexdigest().encode()
        manifests[rel] = (raw, m)
        man_report.append({'path': rel, 'md5': hashlib.md5(raw).hexdigest(), 'original_sha256_verified': True, 'hash_matches': True, 'readonly': True})
        p = LIVE / rel
        qs = [q for q in p.parent.iterdir() if q.is_file() and q.suffix.lower() in ('.bytes', '.hash')]
        if p.parent.name == 'ManifestFiles':
            qs += list((p.parent.parent / 'UnpackManifestFiles').glob('*.bytes'))
        for q in qs:
            qr = q.relative_to(LIVE).as_posix()
            blob = q.read_bytes()
            if qr in expected:
                assert sha(blob) == expected[qr]['source_sha256'], ('live baseline modified', qr)
            else:
                snap = ORIG / qr
                snap.parent.mkdir(parents=True, exist_ok=True)
                if snap.exists():
                    assert snap.read_bytes() == blob, ('aux baseline changed', qr)
                else:
                    shutil.copy2(q, snap)
            guards[qr] = {'relative_path': qr, 'sha256': sha(blob)}
    files = []
    pack_report = []
    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / 'tools').mkdir(exist_ok=True)
    for rel in resources:
        src = (ORIG / rel).read_bytes()
        target = (CAND / rel).read_bytes()
        assert sha(src) == expected[rel]['source_sha256']
        assert (LIVE / rel).read_bytes() == src, ('live source not original', rel)
        assert len(src) == len(target), ('not fixed length', rel)
        e = {'relative_path': rel, 'source_sha256': sha(src), 'target_sha256': sha(target), 'size': len(src)}
        if rel.endswith('.r'):
            refs = []
            primary = None
            for mr, (raw, m) in manifests.items():
                match = [(i, p) for i, p in enumerate(m['packs']) if C.name_of(p) == Path(rel).name]
                if not match:
                    continue
                assert len(match) == 1
                pi, pk = match[0]
                assert not C.verify(raw, ORIG / rel), (rel, 'original', mr)
                assert not C.verify(raw, CAND / rel), (rel, 'candidate', mr)
                segs = [{'bundle_index': bi, 'offset': off, 'size': sz, 'crc32': m['bundles'][bi]['crc']} for bi, off, sz in C.segments(m, pi)]
                if primary is None:
                    primary = (pk, segs)
                else:
                    assert primary[0]['size'] == pk['size'] and primary[0]['crc'] == pk['crc']
                refs.append({'manifest': mr, 'segments_verified': len(segs), 'original_size_and_crc_verified': True, 'candidate_size_and_crc_verified': True})
            assert primary is not None, ('no original manifest reference', rel)
            pk, segs = primary
            patched_segs = [
                {
                    'bundle_index': s['bundle_index'],
                    'offset': s['offset'],
                    'size': s['size'],
                    'crc32': s['crc32'],
                    'source_sha256': sha(src[s['offset']:s['offset'] + s['size']]),
                    'target_sha256': sha(target[s['offset']:s['offset'] + s['size']]),
                }
                for s in segs
                if src[s['offset']:s['offset'] + s['size']] != target[s['offset']:s['offset'] + s['size']]
            ]
            e.update(crc32=pk['crc'], segments=segs, patched_segments=patched_segs)
            assert (zlib.crc32(target) & 0xffffffff) == (zlib.crc32(src) & 0xffffffff) == pk['crc']
            pack_report.append({'path': rel, 'original_size': len(src), 'candidate_size': len(target), 'crc32': f'{pk["crc"]:08x}', 'segments_verified': len(segs), 'references': refs, 'all_passed': True})
        dest = OUT / 'payload/jp_game' / rel
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(CAND / rel, dest)
        files.append(e)
    plan = {
        'format': 1,
        'region': 'jp',
        'resource_version': '3219598',
        'builtin_version': '3075915',
        'created_at': datetime.datetime.now(datetime.timezone(datetime.timedelta(hours=8))).isoformat(),
        'files': files,
        'readonly_files': list(guards.values()),
        'runtime_login_verified': False,
    }
    (OUT / 'tools/jp-deployment.json').write_text(json.dumps(plan, ensure_ascii=False, indent=2), 'utf-8')
    (OUT / 'tools/Localization-Common.ps1').write_bytes(b'\xef\xbb\xbf' + copy_tool('Localization-Common.ps1').replace('\r\n', '\n').replace('\n', '\r\n').encode('utf-8'))
    (OUT / 'tools/Apply-JPCRCZH.ps1').write_bytes(b'\xef\xbb\xbf' + copy_tool('Apply-JPCRCZH.ps1').replace('\r\n', '\n').replace('\n', '\r\n').encode('utf-8'))
    bat = '@echo off\r\nchcp 65001 >nul\r\npowershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\\Apply-JPCRCZH.ps1" -Hint "%~1"\r\necho.\r\npause\r\n'
    (OUT / '双击运行-日服汉化-还原.bat').write_bytes(bat.encode('utf-8'))
    report = {
        'scope': 'offline_file_and_semantic_checks',
        'region': 'jp',
        'runtime_login_verified': False,
        'packs': pack_report,
        'total_packs': len(pack_report),
        'total_segments': sum(r['segments_verified'] for r in pack_report),
        'readonly_files_verified': len(guards),
        'manifests': man_report,
        'raw': json.loads((HERE / 'raw_report.json').read_text('utf-8')),
        'resources': json.loads((HERE / 'resources_report.json').read_text('utf-8')),
        'unityfs': br,
        'live_untouched_by_build': True,
    }
    (OUT / '验证报告.json').write_text(json.dumps(report, ensure_ascii=False, indent=2), 'utf-8')
    (OUT / '使用说明.md').write_text('''# 日服简体汉化：清单只读、等长、原 CRC

适用日服更新资源版本 3219598，内置资源版本 3075915。不要用于台服或其他版本。双击 `双击运行-日服汉化-还原.bat` 选择汉化、还原、校验，也可把日服安装目录拖到 BAT 上。

本版仅部署 10 个 `.r` 资源包和 `resources.assets`。原版清单、`.hash`、相邻只读基线不在写入列表。资源包长度、所有清单引用的段 CRC32、整包 CRC32 与原版一致，清单保持原字节、MD5 不变。CRC 相同不代表资源内容或 MD5 相同；启动器 MD5 修复仍可能将汉化还原。

汉化使用已有日服译文，保留原有字符串键及新增译文。字体按完整字符串语料、GB2312 和 JIS 常用字符取子集，检查保留字符的字形与字宽；未覆盖的玩家自定义字符及实际回退仍需运行验证。不更换日服区服、账号、登录或安全逻辑。`resources.assets` 仅修改启动文字对象，内嵌 SDK locale 保持原版；SDK 登录窗口可能仍显示日文。

部署前检查载荷和只读基线，备份原版资源，建立事务快照后替换并复验，失败则回滚。原版备份位于日服安装根目录 `.zhcn-jp-crc-readonly-3219598-backup`，请保留。运行汉化或还原前退出日服游戏及其登录窗口。不会修改 GameAssembly.dll、global-metadata.dat、游戏 EXE、ACE、SDK DLL、启动器、证书、密钥或根目录版本文件。

离线大小/CRC/资源解析验证不等于服务器完整性校验或实际登录通过。最终状态请以实际结果报告为准。不要覆盖运行旧版会修改清单的汉化脚本。
''', 'utf-8')
    print(json.dumps({'release': str(OUT), 'resources': len(files), 'packs': len(pack_report), 'segments': report['total_segments'], 'readonly_guards': len(guards)}, ensure_ascii=False))


if __name__ == '__main__':
    main()

