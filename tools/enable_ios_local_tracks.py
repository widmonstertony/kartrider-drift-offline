"""Replace isolated local track-list/preparation requests with local callbacks.

Retains the original track selector, table, delegates and engine. No network
packet is fabricated. Supports only the owner's decrypted 2.71.1 executable.
"""
import argparse
import hashlib
import json
import struct
from pathlib import Path
from enable_ios_local_match import assemble
from enable_ios_local_results import branch

BRIDGES = ((0x2DDBFC8, 0x3E00, 0), (0x2DDBE6C, 0x3F00, 1))
RANGES = (
    (0x2DDBFC8, 0x2DDC120, '0a3e19c61c95cc98cf9f6103c44189456fba889325ff9bbc5902a0f1ac7ba963'),
    (0x2DDBE6C, 0x2DDBFBC, 'ba1d662d17610beb6eb5165c3a6ef405bb64fec83964198a5e57be022afd8e16'),
)


def request_bridge(entry, cave, kind):
    return assemble(f'''
ldr x8, [x0, #0x20]
cbz x8, original
ldrb w9, [x8, #0x1a0]
cmp w9, #1
b.ne original
ldr x9, [x8, #0xa30]
cbnz x9, original
stp x19, x30, [sp, #-0x20]!
mov x19, x0
mov x0, #-2
adr x1, symbol
bl .
cbz x0, finished
mov x16, x0
mov x0, x19
mov w1, #{kind}
blr x16
finished:
ldp x19, x30, [sp], #0x20
ret
original:
sub sp, sp, #0x80
b .
symbol:
.asciz "offline_track_request"
.p2align 2
''', cave, [0x65B2448], [entry+4])


def patch(source, destination):
    source, destination = Path(source), Path(destination)
    if source.resolve() == destination.resolve():
        raise ValueError('Preserve the input; use a separate output')
    data = bytearray(source.read_bytes())
    if data[:8] != bytes.fromhex('cffaedfe0c000001'):
        raise ValueError('Expected retained thin ARM64 Mach-O')
    if data[0x2E26CAC:0x2E26CB0] != branch(0x2E26CAC, 0x3C00):
        raise ValueError('Requires the matching local upgrades patch')
    if data[0x2B1F18C:0x2B1F190] != branch(0x2B1F18C,0x4000,True):
        raise ValueError('Requires the matching local race upgrade bridge')
    position, valid = 32, False
    if 32+struct.unpack_from('<I',data,20)[0]>0x3C00:
        raise ValueError('Load commands overlap required padding')
    for _ in range(struct.unpack_from('<I',data,16)[0]):
        command,size=struct.unpack_from('<II',data,position)
        if size<8 or position+size>len(data):
            raise ValueError('Invalid Mach-O load command')
        if command==0x2C and struct.unpack_from('<I',data,position+16)[0]:
            raise ValueError('Encrypted executable; use retained decrypted input')
        if command==0x19 and data[position+8:position+24].rstrip(b'\0')==b'__TEXT':
            vm,_,off,_,_,prot,sections,_=struct.unpack_from('<QQQQiiII',data,position+24)
            valid=vm==0x100000000 and off==0 and prot==5 and sections>0 and struct.unpack_from('<I',data,position+120)[0]==0x6F00
        position+=size
    if not valid:
        raise ValueError('Unexpected executable segment layout')
    # The preceding patch validates the Mach-O executable segment and header
    # padding layout. Require its bridge, then independently hash these bodies.
    for start, end, digest in RANGES:
        if hashlib.sha256(data[start:end]).hexdigest() != digest:
            raise ValueError('Original track functions differ from retained 2.71.1')
    for entry, cave, kind in BRIDGES:
        code = request_bridge(entry, cave, kind)
        if len(code) > 0x100 or any(data[cave:cave+0x100]):
            raise ValueError('Required track bridge padding is unavailable')
        data[entry:entry+4] = branch(entry, cave)
        data[cave:cave+len(code)] = code
    destination.write_bytes(data)
    return {'runtime_verified': False, 'requires_resigning': True,
            'sha256': hashlib.sha256(data).hexdigest()}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source')
    parser.add_argument('destination')
    args = parser.parse_args()
    print(json.dumps(patch(args.source, args.destination), indent=2))
