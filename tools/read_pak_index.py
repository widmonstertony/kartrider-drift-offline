"""Read and hash-check the preserved client's Unreal PAK directory index."""
import base64
import hashlib
import io
import json
import struct
from pathlib import Path
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes

ROOT = Path(__file__).resolve().parents[1]
PAK = ROOT/'analysis/obb/KartDrift/Content/Paks/pakchunk0-Android_ASTC.pak'
# Published by the uploader of the original client archive, clientlover.tistory.com/13.
KEY = base64.b64decode('gdF1J/ewC7L+HmHLy6XTQPrTOIXDdZWPB69MZLAbOeQ=')

class Reader(io.BytesIO):
    def unpack(self, fmt):
        return struct.unpack(fmt, self.read(struct.calcsize(fmt)))
    def i32(self): return self.unpack('<i')[0]
    def u64(self): return self.unpack('<Q')[0]
    def string(self):
        n = self.i32()
        if not -1000000 < n < 1000000: raise ValueError(f'invalid FString length {n}')
        return self.read(n).rstrip(b'\0').decode('utf-8') if n >= 0 else self.read(-n*2).decode('utf-16-le').rstrip('\0')

def decrypt(raw):
    return Cipher(algorithms.AES(KEY), modes.ECB()).decryptor().update(raw)

with PAK.open('rb') as f:
    f.seek(-204,2)
    footer = f.read()
    magic,version,offset,size = struct.unpack_from('<IIQQ', footer)
    assert magic == 0x5A6F12E1 and version == 11
    f.seek(offset)
    primary = decrypt(f.read(size))
    assert hashlib.sha1(primary).digest() == footer[24:44]
    r = Reader(primary)
    mount = r.string()
    entries = r.i32()
    seed = r.u64()
    subindices = {}
    for label in ['path_hash','directory']:
        present = r.i32()
        if present:
            pos,length = r.unpack('<qq')
            digest = r.read(20)
            f.seek(pos)
            content = decrypt(f.read((length+15)//16*16))
            assert hashlib.sha1(content[:length]).digest() == digest
            subindices[label] = {'offset':pos,'size':length,'hash_verified':True}
            (ROOT/f'analysis/pak-{label}-index.bin').write_bytes(content[:length])
    encoded_size = r.i32()
    encoded_entries = r.read(encoded_size)
    (ROOT/'analysis/pak-encoded-entries.bin').write_bytes(encoded_entries)
    directory = Reader((ROOT/'analysis/pak-directory-index.bin').read_bytes())
    directory_count = directory.i32()
    paths = []
    for _ in range(directory_count):
        dirname = directory.string()
        filecount = directory.i32()
        for _ in range(filecount):
            name = directory.string()
            location = directory.i32()
            paths.append({'path':dirname+name,'entry_location':location})
    report = {'mount':mount,'entries':entries,'directories':directory_count,
              'listed_files':len(paths),'subindices':subindices,'files':paths}
    (ROOT/'analysis/pak-files.json').write_text(json.dumps(report,indent=2))
    (ROOT/'analysis/pak-paths.txt').write_text('\n'.join(p['path'] for p in paths))
    print(json.dumps({k:v for k,v in report.items() if k!='files'},indent=2))
