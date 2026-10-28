"""Rebuild a local analysis copy using a page read from the owner's running app."""
import argparse
import struct
from pathlib import Path

def rebuild(original, page, output):
    data=bytearray(Path(original).read_bytes())
    if data[:4]!=b'\xcf\xfa\xed\xfe':raise ValueError('Expected a thin little-endian 64-bit Mach-O')
    ncmds,sizeofcmds=struct.unpack_from('<II',data,16)
    pos=32
    if pos+sizeofcmds>len(data):raise ValueError('Truncated load commands')
    for _ in range(ncmds):
        cmd,size=struct.unpack_from('<II',data,pos)
        if size<8 or pos+size>32+sizeofcmds:raise ValueError('Invalid load command')
        if cmd==0x2c:
            offset,length,cryptid=struct.unpack_from('<III',data,pos+8)
            content=Path(page).read_bytes()
            if len(content)!=length or offset+length>len(data):raise ValueError('Page size or range does not match this executable')
            if Path(original).resolve()==Path(output).resolve():raise ValueError('Use a different output path to preserve the original')
            data[offset:offset+length]=content
            struct.pack_into('<I',data,pos+16,0)
            Path(output).write_bytes(data)
            return {'cryptoff':offset,'cryptsize':length,'original_cryptid':cryptid}
        pos+=size
    raise ValueError('No LC_ENCRYPTION_INFO_64 command found')

if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('original');p.add_argument('page');p.add_argument('output')
    a=p.parse_args();print(rebuild(a.original,a.page,a.output))
