"""Read-only, hash-checked reader for this preserved client's UE 4.27 PAKs."""
import base64
import hashlib
import io
import struct
import subprocess
import zlib
from pathlib import Path
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes

KEY=base64.b64decode('gdF1J/ewC7L+HmHLy6XTQPrTOIXDdZWPB69MZLAbOeQ=')
def decrypt(data):
    return Cipher(algorithms.AES(KEY),modes.ECB()).decryptor().update(data)

class Reader(io.BytesIO):
    def unpack(self,fmt):return struct.unpack(fmt,self.read(struct.calcsize(fmt)))
    def i32(self):return self.unpack('<i')[0]
    def string(self):
        n=self.i32()
        assert -1000000<n<1000000
        return self.read(n).rstrip(b'\0').decode() if n>=0 else self.read(-n*2).decode('utf-16-le').rstrip('\0')

class Pak:
    def __init__(self,path):
        self.path=Path(path)
        with self.path.open('rb') as f:
            f.seek(-204,2);footer=f.read()
            magic,self.version,offset,size=struct.unpack_from('<IIQQ',footer)
            assert magic==0x5A6F12E1 and self.version==11
            f.seek(offset);primary=decrypt(f.read(size))
            assert hashlib.sha1(primary).digest()==footer[24:44]
            r=Reader(primary);self.mount=r.string();self.count=r.i32();r.read(8)
            sub={}
            for label in ('path_hash','directory'):
                if r.i32():
                    pos,length=r.unpack('<qq');digest=r.read(20)
                    f.seek(pos);content=decrypt(f.read((length+15)//16*16))[:length]
                    assert hashlib.sha1(content).digest()==digest
                    sub[label]=content
            self.encoded=r.read(r.i32())
            directory=Reader(sub['directory']);self.files={}
            for _ in range(directory.i32()):
                dirname=directory.string()
                for _ in range(directory.i32()):
                    name=directory.string();location=directory.i32()
                    self.files[dirname+name]=location

    def read(self,name):
        location=self.files[name]
        assert location>=0,(name,'unencoded entry',location)
        bits=struct.unpack_from('<I',self.encoded,location)[0]
        offset_field=location+4+(4 if bits&0x3f==0x3f else 0)
        offset=struct.unpack_from('<I' if bits&(1<<31) else '<Q',self.encoded,offset_field)[0]
        with self.path.open('rb') as f:
            f.seek(offset)
            raw=f.read(48)
            _,compressed,uncompressed,method=struct.unpack_from('<QQQI',raw)
            blocks=[]
            if method:
                count=struct.unpack('<I',f.read(4))[0]
                blocks=[struct.unpack('<QQ',f.read(16)) for _ in range(count)]
            flags,blocksize=struct.unpack('<BI',f.read(5))
            if not method:
                data=f.read((compressed+15)//16*16 if flags&1 else compressed)
                if flags&1:data=decrypt(data)
                return data[:uncompressed]
            result=bytearray()
            for start,end in blocks:
                f.seek(offset+start);length=end-start
                data=f.read((length+15)//16*16 if flags&1 else length)
                if flags&1:data=decrypt(data)
                data=data[:length]
                if method==2:result.extend(zlib.decompress(data))
                elif method==1:
                    want=min(blocksize,uncompressed-len(result))
                    executable=Path(__file__).with_name('ooz-decode')
                    result.extend(subprocess.run([str(executable),str(want)],input=data,stdout=subprocess.PIPE,check=True).stdout)
                else:raise ValueError(f'Compression method {method} unsupported')
            assert len(result)==uncompressed,(name,len(result),uncompressed)
            return bytes(result)

if __name__=='__main__':
    import argparse
    import json
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('pak');p.add_argument('--list',action='store_true')
    p.add_argument('--extract',help='Exact file name from the directory index')
    p.add_argument('--output',type=Path,help='Explicit destination for one extracted file')
    a=p.parse_args();archive=Pak(a.pak)
    if a.extract:
        if not a.output:p.error('--extract requires --output')
        if a.output.resolve()==archive.path.resolve():p.error('Cannot overwrite the source PAK')
        a.output.write_bytes(archive.read(a.extract))
    elif a.list:print('\n'.join(sorted(archive.files)))
    else:print(json.dumps({'version':archive.version,'mount':archive.mount,'indexed_files':len(archive.files),'index_hashes_verified':True},indent=2))
