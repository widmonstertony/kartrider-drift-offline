"""Read-only inventory of the preserved Android client, for iOS port research."""
from pathlib import Path
import hashlib
import json
import re
import struct
import zipfile

from loguru import logger
logger.remove()
from androguard.core.apk import APK
from elftools.elf.elffile import ELFFile

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'analysis'
OUT.mkdir(parents=True,exist_ok=True)
APK_DIR = OUT / 'xapk'

base = APK(str(APK_DIR / 'com.nexon.kartdrift.apk'))
(OUT / 'AndroidManifest.xml').write_bytes(base.get_android_manifest_axml().get_xml())
certs = []
for cert in base.get_certificates():
    certs.append({'sha1': hashlib.sha1(cert.dump()).hexdigest(),
                  'sha256': hashlib.sha256(cert.dump()).hexdigest(),
                  'subject': cert.subject.native})
manifest = {'package': base.get_package(), 'version': base.get_androidversion_name(),
            'code': base.get_androidversion_code(), 'activity': base.get_main_activity(),
            'certificates': certs}
(OUT / 'apk-identity.json').write_text(json.dumps(manifest, indent=2))

lib = OUT / 'extracted/config.arm64_v8a.apk/lib/arm64-v8a/libUE4.so'
with lib.open('rb') as f:
    elf = ELFFile(f)
    symbols = []
    for section in elf.iter_sections():
        if section.name in ('.dynsym', '.symtab'):
            for symbol in section.iter_symbols():
                if re.search(r'License|Tutorial|Training|Offline|TimeAttack|OpenLevel|LoadMap|GameInstance|PakFile', symbol.name, re.I):
                    symbols.append(f'{symbol["st_value"]:#x}\t{symbol["st_size"]}\t{symbol.name}')
    (OUT / 'native-symbol-candidates.tsv').write_text('\n'.join(symbols))
    print('Relevant native symbols:', len(symbols), flush=True)

data = lib.read_bytes()
strings = []
pattern = re.compile(rb'[\x20-\x7e]{6,}')
for match in pattern.finditer(data):
    s = match.group().decode('ascii')
    if re.search(r'License|Tutorial|Training|Offline|TimeAttack|\.umap|https?://|cdn|patch|GameDefaultMap|GameInstanceClass', s, re.I):
        strings.append(f'{match.start():#x}\t{s}')
(OUT / 'native-string-candidates.tsv').write_text('\n'.join(strings))
print('Relevant native strings:', len(strings), flush=True)

pak = OUT / 'obb/KartDrift/Content/Paks/pakchunk0-Android_ASTC.pak'
data = pak.read_bytes()
magic = struct.pack('<I', 0x5A6F12E1)
positions = [m.start() for m in re.finditer(re.escape(magic), data[-2048:])]
for pos in positions:
    offset = len(data) - 2048 + pos
    print('PAK footer magic at', offset, 'tail distance', len(data)-offset,
          'data', data[max(0, offset-20):offset+64].hex(), flush=True)
print(json.dumps(manifest, indent=2), flush=True)
