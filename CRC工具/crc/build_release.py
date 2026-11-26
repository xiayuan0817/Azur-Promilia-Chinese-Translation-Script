import datetime
import hashlib
import json
import os
import shutil
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[1]
sys.path.insert(0, str(HERE))
import crcchain as C
from now_cases import CASES

DATA = Path(os.environ.get('AZUR_TW_DATA', r'E:\AzurPromilia_TC\AzurPromilia_TC_game\AzurPromilia_Data'))
OLDPACK = Path(os.environ.get('AZUR_TW_OLD_PACK_ROOT', r'D:\windows\Desktop\蓝色星原简体汉化独立版'))
OUT = ROOT / 'outputs' / '台服简体汉化-清单只读CRC版'
CAND = HERE / 'fixed_candidates'


def sha(b):
    return hashlib.sha256(b).hexdigest()


def copy_tool(name):
    src = ROOT / 'tools' / name
    if not src.is_file():
        src = HERE / name
    return src.read_text('utf-8-sig')


def main():
    OUT.mkdir(exist_ok=True, parents=True)
    (OUT / 'tools').mkdir(exist_ok=True)
    old = json.loads((OLDPACK / 'tools/deployment-plan.json').read_text('utf-8-sig'))
    game = next(g for g in old['games'] if g['id'] == 'tw_game')
    original_entries = {f['relative_path']: f for f in game['files']}
    manifest_paths = [mp for mp, _, _ in CASES]
    guards = {}
    manifests = {}
    files = []
    rows = []
    for mp in manifest_paths:
        p = DATA / mp
        raw = p.read_bytes()
        m = C.parse(raw)
        manifests[mp] = m
        hp = p.with_suffix('.hash')
        assert hp.read_bytes().strip().lower() == hashlib.md5(raw).hexdigest().encode()
        for q in p.parent.iterdir():
            if q.is_file() and q.suffix.lower() in ('.bytes', '.hash'):
                rel = q.relative_to(DATA).as_posix()
                guards[rel] = {'relative_path': rel, 'sha256': sha(q.read_bytes())}
        if 'ManifestFiles' in str(p):
            for q in (p.parent.parent / 'UnpackManifestFiles').glob('*.bytes'):
                rel = q.relative_to(DATA).as_posix()
                guards[rel] = {'relative_path': rel, 'sha256': sha(q.read_bytes())}
    for mp, bd, names in CASES:
        m = manifests[mp]
        for name in names:
            rel = (Path(bd) / name).as_posix()
            src = (DATA / rel).read_bytes()
            dest = CAND / rel
            target = dest.read_bytes()
            assert sha(src) == original_entries[rel]['source_sha256'], rel
            assert len(target) == len(src), rel
            assert not C.verify((DATA / mp).read_bytes(), dest), rel
            pi = next(i for i, p in enumerate(m['packs']) if C.name_of(p) == name)
            pk = m['packs'][pi]
            segs = [{'bundle_index': bi, 'offset': off, 'size': sz, 'crc32': m['bundles'][bi]['crc']} for bi, off, sz in C.segments(m, pi)]
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
            refs = []
            for other, om in manifests.items():
                if any(C.name_of(p) == name for p in om['packs']):
                    assert not C.verify((DATA / other).read_bytes(), dest), (rel, other)
                    refs.append(other)
            out = OUT / 'payload/tw_game' / rel
            out.parent.mkdir(exist_ok=True, parents=True)
            shutil.copy2(dest, out)
            files.append({'relative_path': rel, 'source_sha256': sha(src), 'target_sha256': sha(target), 'size': len(src), 'crc32': pk['crc'], 'segments': segs, 'patched_segments': patched_segs})
            rows.append({'file': rel, 'size': len(src), 'crc32': f'{pk["crc"]:08x}', 'segments_verified': len(segs), 'all_manifest_references': refs, 'checks_passed': True})
    rel = 'resources.assets'
    src = (DATA / rel).read_bytes()
    target = (OLDPACK / 'payload/tw_game' / rel).read_bytes()
    assert sha(src) == original_entries[rel]['source_sha256']
    assert len(src) == len(target), (len(src), len(target))
    out = OUT / 'payload/tw_game' / rel
    out.parent.mkdir(exist_ok=True, parents=True)
    shutil.copy2(OLDPACK / 'payload/tw_game' / rel, out)
    files.append({'relative_path': rel, 'source_sha256': sha(src), 'target_sha256': sha(target), 'size': len(src)})
    plan = {
        'format': 1,
        'region': 'tw',
        'resource_version': '3221745',
        'created_at': datetime.datetime.now(datetime.timezone(datetime.timedelta(hours=8))).isoformat(),
        'files': files,
        'readonly_files': list(guards.values()),
        'runtime_login_verified': False,
    }
    (OUT / 'tools/tw-deployment.json').write_text(json.dumps(plan, ensure_ascii=False, indent=2), 'utf-8')
    # Write BOM for Windows PowerShell 5.1 and CRLF for the batch launcher.
    (OUT / 'tools/Localization-Common.ps1').write_bytes(b'\xef\xbb\xbf' + copy_tool('Localization-Common.ps1').replace('\r\n', '\n').replace('\n', '\r\n').encode('utf-8'))
    (OUT / 'tools/Apply-CRCZH.ps1').write_bytes(b'\xef\xbb\xbf' + copy_tool('Apply-CRCZH.ps1').replace('\r\n', '\n').replace('\n', '\r\n').encode('utf-8'))
    bat = '@echo off\r\nchcp 65001 >nul\r\npowershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\\Apply-CRCZH.ps1" -Hint "%~1"\r\necho.\r\npause\r\n'
    (OUT / '双击运行-汉化-还原.bat').write_bytes(bat.encode('utf-8'))
    report = {
        'scope': 'local_file_checks',
        'runtime_login_verified': False,
        'readonly_files_verified': len(guards),
        'packs': rows,
        'total_pack_segments': sum(x['segments_verified'] for x in rows),
        'raw_resources': json.loads((HERE / 'fit_raw_report.json').read_text('utf-8')),
        'unityfs_resources': json.loads((HERE / 'fit_bundles_report.json').read_text('utf-8')),
    }
    (OUT / '验证报告.json').write_text(json.dumps(report, ensure_ascii=False, indent=2), 'utf-8')
    (OUT / '使用说明.md').write_text('''# 台服简体汉化：清单只读 CRC 版

对应资源版本 3221745。双击 `双击运行-汉化-还原.bat`，选择汉化、还原或完整校验。若自动查找失败，把游戏安装文件夹拖到 BAT 上。

本版部署 7 个 .r 资源包和 resources.assets。原版清单、.hash、ApplicationFootPrint 只用于读取与校验，不在写入列表。大小、全部段 CRC、整包 CRC 均与原版相同，原版清单 MD5 保持不变。

先验证全部载荷与原版清单，创建原版备份和事务快照，再应用资源，写入后复验；失败则回滚。备份在游戏安装目录的 .zhcn-crc-readonly-3221745-backup 文件夹。

文本沿用既有汉化数据，保留所有原字符串键和新增译文，未压短译文。主简体字体按完整文本语料与 GB2312 常用字取子集，保留约 8993–9159 个字符；静态包中的原始回退字体不取子集。超出这些字符的玩家自定义输入仍需游戏实际字体回退验证。

当前验证涵盖离线解密/解压/重载、数据语义、原版大小和 CRC 以及清单字节；实际登录及游戏显示尚须运行确认。CRC32 相同不代表资源 MD5 相同；启动器的 MD5 修复流程可能识别并还原汉化资源。

该目录不包含接口密钥、DLL、SDK、反作弊或可执行程序。
''', 'utf-8')
    print(json.dumps({'output': str(OUT), 'files': len(files), 'readonly_guards': len(guards), 'packs': len(rows), 'segments': report['total_pack_segments']}, ensure_ascii=False))


if __name__ == '__main__':
    main()

