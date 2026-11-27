"""校验替换资源、刷新清单并构建完整包与源码包。"""
from pathlib import Path, PurePosixPath
from zipfile import ZipFile, ZIP_DEFLATED
import argparse
import hashlib
import json
import re
import sys

ROOT = Path(__file__).resolve().parent
PACKAGE = '蓝色星原简体汉化'

CORE_NON_PAYLOAD_PATHS = [
    'tools/Apply-CRCZH.ps1',
    'tools/Apply-JPCRCZH.ps1',
    'tools/Apply-JPDeblur.ps1',
    'tools/Apply-TWDeblur.ps1',
    'tools/tw-deblur-deployment.json',
    'tools/jp-deblur-deployment.json',
    'tools/Apply-Launchers.ps1',
    'tools/Localization-Common.ps1',
    'tools/Region-Identity.ps1',
    'tools/jp-deployment.json',
    'tools/launcher-deployment.json',
    'tools/Locate-Installations.ps1',
    'tools/Manage-Localization.ps1',
    'tools/Update-Localization.ps1',
    'tools/tw-deployment.json',
    '使用说明.txt',
    '双击运行.bat',
]

SOURCE_SUFFIXES = {'.py', '.ps1', '.json', '.md', '.txt'}
SOURCE_CACHE_DIRS = {'__pycache__', '.pytest_cache', 'logs', 'release_test',
                     'fixed_candidates', 'originals'}
PACKAGE_SOURCES = {'tools/日服反虚化原说明.txt': 'tools/日服反虚化来源.md'}


def source_tree_names(folder):
    directory = ROOT / folder
    if not directory.is_dir():
        raise FileNotFoundError(directory)
    return [p.relative_to(ROOT).as_posix() for p in sorted(directory.rglob('*'))
            if p.is_file() and p.suffix.lower() in SOURCE_SUFFIXES
            and not SOURCE_CACHE_DIRS.intersection(p.relative_to(directory).parts[:-1])]


def sha256(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def child(root, relative):
    relative = PurePosixPath(relative)
    if relative.is_absolute() or '..' in relative.parts or '\\' in str(relative) or ':' in str(relative):
        raise ValueError(f'包内路径无效：{relative}')
    root = root.resolve(strict=True)
    path = root.joinpath(*relative.parts).resolve(strict=True)
    if not path.is_relative_to(root) or not path.is_file():
        raise ValueError(f'文件路径无效：{relative}')
    return path


def package_source(relative, usage=None):
    if relative == '使用说明.txt':
        path = usage if usage is not None else ROOT / relative
        if not path.is_file():
            raise FileNotFoundError('构建完整包需通过 --usage 指定使用说明.txt')
        return path.resolve(strict=True)
    return child(ROOT, PACKAGE_SOURCES.get(relative, relative))


def check_text_encoding(path, relative):
    data = path.read_bytes()
    if relative.endswith('.ps1'):
        if not data.startswith(b'\xef\xbb\xbf'):
            raise ValueError(f'PowerShell 脚本缺少 UTF-8 BOM（PS 5.1 必需）：{relative}')
        if b'\n' in data.replace(b'\r\n', b''):
            raise ValueError(f'PowerShell 脚本包含 LF 行尾（应为 CRLF）：{relative}')
    elif relative.endswith('.bat'):
        if data.startswith(b'\xef\xbb\xbf'):
            raise ValueError(f'批处理脚本禁止包含 UTF-8 BOM：{relative}')
        if b'\n' in data.replace(b'\r\n', b''):
            raise ValueError(f'批处理脚本包含 LF 行尾（应为 CRLF）：{relative}')


def archive(path, entries, prefix):
    tmp = path.with_name(path.name + '.tmp')
    if tmp.exists():
        tmp.unlink()
    try:
        with ZipFile(tmp, 'w', ZIP_DEFLATED, compresslevel=6) as package:
            for source, relative in entries:
                package.write(source, f'{prefix}/{relative}')
        with ZipFile(tmp) as package:
            damaged = package.testzip()
            if damaged:
                raise ValueError(f'压缩包校验失败：{damaged}')
        tmp.replace(path)
    finally:
        if tmp.exists():
            tmp.unlink()


def refresh_manifest(payload_root=None, version='v6.1', usage=None):
    manifest_path = ROOT / 'tools/package-files.json'
    catalog = json.loads(manifest_path.read_text('utf-8-sig'))
    if catalog.get('format') != 1 or catalog.get('hash') != 'SHA256':
        raise ValueError('文件清单格式无效')
    catalog['version'] = version

    by_path = {}
    for item in catalog['files']:
        rel = item['path']
        if rel in by_path:
            raise ValueError(f'重复包内路径：{rel}')
        by_path[rel] = dict(item)

    required = set(CORE_NON_PAYLOAD_PATHS) | {rel for rel in by_path if not rel.startswith('payload/')}
    updated = 0
    for rel in sorted(required):
        if rel == '使用说明.txt' and usage is None and not (ROOT / rel).is_file():
            continue
        src = package_source(rel, usage)
        check_text_encoding(src, rel)
        by_path[rel] = {
            'path': rel,
            'size': src.stat().st_size,
            'sha256': sha256(src),
        }
        updated += 1

    if payload_root is not None:
        for rel, item in list(by_path.items()):
            if rel.startswith('payload/'):
                src = child(payload_root, rel[8:])
                by_path[rel] = {
                    'path': rel,
                    'size': src.stat().st_size,
                    'sha256': sha256(src),
                }

    catalog['files'] = [by_path[k] for k in sorted(by_path)]
    text = json.dumps(catalog, ensure_ascii=False, indent=2) + '\n'
    manifest_path.write_bytes(text.replace('\r\n', '\n').replace('\n', '\r\n').encode('utf-8'))
    return len(catalog['files']), updated


def verify_repo(usage=None):
    catalog = json.loads((ROOT / 'tools/package-files.json').read_text('utf-8-sig'))
    if catalog.get('format') != 1 or catalog.get('hash') != 'SHA256':
        raise ValueError('文件清单格式无效')

    seen = set()
    non_payload_checked = 0
    payload_count = 0
    for item in catalog['files']:
        rel = item['path']
        if rel in seen:
            raise ValueError(f'重复包内路径：{rel}')
        seen.add(rel)
        if rel.startswith('payload/'):
            payload_count += 1
            continue
        if rel == '使用说明.txt' and usage is None and not (ROOT / rel).is_file():
            continue
        src = package_source(rel, usage)
        check_text_encoding(src, rel)
        if src.stat().st_size != item['size'] or sha256(src) != item['sha256']:
            raise ValueError(f'清单校验失败（请运行 python build_release.py --refresh-manifest）：{rel}')
        non_payload_checked += 1

    for req in CORE_NON_PAYLOAD_PATHS:
        if req not in seen:
            raise ValueError(f'缺少核心清单登记：{req}')

    pairs = [
        ('tools/Apply-CRCZH.ps1', 'CRC工具/crc/Apply-CRCZH.ps1'),
        ('tools/Apply-JPCRCZH.ps1', 'CRC工具/jp_crc/Apply-JPCRCZH.ps1'),
    ]
    for a, b in pairs:
        pa, pb = child(ROOT, a), child(ROOT, b)
        if sha256(pa) != sha256(pb):
            raise ValueError(f'脚本未同步：{a} != {b}')

    return non_payload_checked, payload_count


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--payload', type=Path, help='完整包中的 payload 文件夹')
    parser.add_argument('--usage', type=Path, help='仅用于完整包的使用说明 TXT')
    parser.add_argument('--output', type=Path, default=ROOT / 'dist')
    parser.add_argument('--version', default='v6.1')
    parser.add_argument('--refresh-manifest', action='store_true', help='刷新 tools/package-files.json 中非 payload 条目')
    parser.add_argument('--verify-repo', action='store_true', help='校验源码仓库清单、编码规则及 CRC 副本同步')
    args = parser.parse_args()

    if args.refresh_manifest:
        total, updated = refresh_manifest(args.payload, args.version, args.usage)
        print(json.dumps({'refreshed': True, 'total_entries': total, 'non_payload_entries': updated}, ensure_ascii=False))
        if not args.verify_repo and args.payload is None:
            return

    if args.verify_repo:
        non_payload, payload = verify_repo(args.usage)
        print(json.dumps({'repo_verified': True, 'non_payload_entries': non_payload, 'payload_entries': payload}, ensure_ascii=False))
        if args.payload is None:
            return

    if args.payload is None:
        parser.error('构建发布包需要指定 --payload（或使用 --verify-repo / --refresh-manifest）')

    if not re.fullmatch(r'[A-Za-z0-9._-]+', args.version):
        raise ValueError('版本名称无效')
    catalog = json.loads((ROOT / 'tools/package-files.json').read_text('utf-8-sig'))
    if catalog['format'] != 1 or catalog['hash'] != 'SHA256':
        raise ValueError('文件清单格式无效')
    if catalog.get('version') != args.version:
        refresh_manifest(args.payload, args.version, args.usage)
        catalog = json.loads((ROOT / 'tools/package-files.json').read_text('utf-8-sig'))
    entries = {}
    for item in catalog['files']:
        relative = item['path']
        if relative in entries:
            raise ValueError(f'重复包内路径：{relative}')
        source = child(args.payload, relative[8:]) if relative.startswith('payload/') else package_source(relative, args.usage)
        if not relative.startswith('payload/'):
            check_text_encoding(source, relative)
        if source.stat().st_size != item['size'] or sha256(source) != item['sha256']:
            raise ValueError(f'文件校验失败：{relative}')
        entries[relative] = source
    for name in ('tools/package-files.json', 'tools/安装路径.json'):
        entries[name] = child(ROOT, name)
    source_names = ['.gitignore', 'LICENSE', 'README.md', 'build_release.py', '双击运行.bat']
    if (ROOT / '.gitattributes').is_file():
        source_names.append('.gitattributes')
    for folder in ('tools', 'CRC工具', 'tests'):
        source_names += source_tree_names(folder)
    sources = [(child(ROOT, name), name) for name in sorted(set(source_names))]
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    full = output / f'AzurPromilia-Localization-Full-{args.version}.zip'
    source = output / f'AzurPromilia-Localization-Source-{args.version}.zip'
    for path in (full, source):
        if path.exists():
            raise FileExistsError(path)
    archive(full, [(path, name) for name, path in sorted(entries.items())], PACKAGE)
    archive(source, sources, PACKAGE + '-源码')
    checksums = ''.join(f'{sha256(path)}  {path.name}\n' for path in (full, source))
    (output / 'SHA256SUMS.txt').write_text(checksums, 'ascii')
    repository = 'xiayuan0817/Azur-Promilia-Chinese-Translation-Script'
    update = {
        'format': 1,
        'repository': repository,
        'manifest_sha256': sha256(ROOT / 'tools/package-files.json'),
        'release': {
            'tag_name': args.version,
            'assets': [{
                'name': full.name,
                'size': full.stat().st_size,
                'digest': 'sha256:' + sha256(full),
                'browser_download_url': f'https://github.com/{repository}/releases/download/{args.version}/{full.name}',
            }],
        },
    }
    (output / 'update.json').write_text(json.dumps(update, ensure_ascii=False, indent=2) + '\n', 'utf-8')
    print(json.dumps({
        'archives': [str(full), str(source)],
        'package_files': len(entries),
        'replacement_files': sum(name.startswith('payload/') for name in entries),
        'source_files': len(sources),
    }, ensure_ascii=False))


if __name__ == '__main__':
    main()

