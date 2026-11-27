"""构造隔离安装目录。"""
import hashlib
import json
import shutil
import struct
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def sha(data):
    return hashlib.sha256(data).hexdigest()


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2), 'utf-8')


def text_asset(region, localized=False):
    values = {'tw': ('cht', 'ob1.0_tc', '43'), 'jp': ('jp', 'ob1.0_jp', '42'),
              'cn': ('chs', 'ob1.0', '34'), 'unknown': ('xx', 'unknown', '0')}
    r, channel, game_id = values[region]
    value = json.dumps({'region': r, 'channel': channel, 'gameId': game_id,
                        'language': 'chs', 'label': '简体' if localized else '原文'}, ensure_ascii=False).encode()
    name = b'appConfig'
    header = struct.pack('<I', len(name)) + name
    header += b'\0' * (-len(header) % 4)
    return header + struct.pack('<I', len(value)) + value


def asar(region, localized=False):
    package = {'name': 'AZUPRO_JP_Gamelauncher' if region == 'jp' else 'launcher',
               'author': 'Yostar, Inc.' if region == 'jp' else 'JIMI PTE. LTD.' if region == 'tw' else 'CN publisher'}
    files = {'package.json': json.dumps(package).encode(),
             'main.js': ('const config={"Ny":"' + ('HMT' if region == 'tw' else 'CN') + '"};').encode(),
             'label.txt': ('简体中文' if localized else '原文').encode()}
    offset = 0
    members = {}
    for name, data in files.items():
        members[name] = {'size': len(data), 'offset': str(offset)}
        offset += len(data)
    header = json.dumps({'files': members}, separators=(',', ':')).encode()
    padding = b'\0' * (-len(header) % 4)
    return struct.pack('<IIII', 4, 8 + len(header) + len(padding), 4 + len(header) + len(padding), len(header)) + header + padding + b''.join(files.values())


def run_ps(script, *args):
    result = subprocess.run(['powershell.exe', '-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass',
                             '-File', str(script), *map(str, args)],
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=45)
    return result.returncode, result.stdout.decode('utf-8', 'replace')


class Fixture:
    def __init__(self, directory, module='tw_game'):
        self.module = module
        self.region = module[:2]
        self.pack = Path(directory) / '中文 补丁 (测试)&!'
        self.root = Path(directory) / '任意名称的安装目录'
        shutil.copytree(ROOT / 'tools', self.pack / 'tools', ignore=shutil.ignore_patterns('logs'))
        self.root.mkdir()
        self.backups = {'tw_game': '.zhcn-crc-readonly-3221745-backup',
                        'jp_game': '.zhcn-jp-crc-readonly-3219598-backup',
                        'tw_deblur': '.tw-deblur-3221746-backup', 'jp_deblur': '.jp-deblur-1.0.2-backup'}
        if module.endswith('_launcher'):
            exe = 'launcher.exe' if self.region == 'tw' else 'AZUPRO_JP_Gamelauncher.exe'
            self.data = self.root
            self.relative = ['resources/app.asar']
            self.before = {self.relative[0]: asar(self.region)}
            self.after = {self.relative[0]: asar(self.region, True)}
            self.script = self.pack / 'tools/Apply-Launchers.ps1'
            plan_path = self.pack / 'tools/launcher-deployment.json'
            plan = json.loads(plan_path.read_text('utf-8-sig'))
            entry = next(e for e in plan['launchers'] if e['id'] == module)
            entry['target_sha256'] = sha(self.after[self.relative[0]])
            entry['source_sha256'] = '0' * 64
            entry['size'] = -1
            write_json(plan_path, plan)
            self.backup = self.root / 'resources/app.asar.before-zhcn-20261124.bak'
        else:
            exe = 'AzurPromilia.exe' if self.region == 'tw' else 'AzurPromiliaJP.exe'
            self.data = self.root / ('AzurPromilia_Data' if self.region == 'tw' else 'AzurPromiliaJP_Data')
            self.data.mkdir()
            (self.data / 'resources.assets').write_bytes(text_asset(self.region))
            kind = 'deblur-deployment' if module.endswith('_deblur') else 'deployment'
            self.plan_path = self.pack / 'tools' / f'{self.region}-{kind}.json'
            plan = json.loads(self.plan_path.read_text('utf-8-sig'))
            self.relative = ['.res/default_package/BundleFiles/fixturea.r',
                             '.res/default_package/BundleFiles/fixtureb.r' if module.endswith('_deblur') else 'resources.assets']
            self.before = {self.relative[0]: b'updated original resource with unknown size',
                           self.relative[1]: b'updated original second' if module.endswith('_deblur') else text_asset(self.region)}
            self.after = {self.relative[0]: b'localized resource',
                          self.relative[1]: b'localized second' if module.endswith('_deblur') else text_asset(self.region, True)}
            plan['files'] = [dict(relative_path=p, source_sha256='0' * 64, target_sha256=sha(self.after[p]),
                                  size=-1, crc32=0, segments=[]) for p in self.relative]
            plan['readonly_files'] = []
            plan.pop('backup_dir', None)
            write_json(self.plan_path, plan)
            self.script = self.pack / 'tools' / ('Apply-' + ('TW' if self.region == 'tw' else 'JP') + 'Deblur.ps1' if module.endswith('_deblur') else ('Apply-CRCZH.ps1' if self.region == 'tw' else 'Apply-JPCRCZH.ps1'))
            self.backup = self.root / self.backups[module]
        self.exe = self.root / exe
        self.exe.write_bytes(b'not a PE; no file version')
        for relative, value in self.before.items():
            target = self.data / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(value)
        for relative, value in self.after.items():
            target = self.pack / 'payload' / module / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(value)

    def run(self, action):
        args = ['-Action', action, '-Hint', self.root]
        if self.module.endswith('_launcher'):
            args += ['-Target', self.module]
        return run_ps(self.script, *args)
