"""Complete local team assignment and select original solo/team result factories.

Requires the existing isolated-account, AI, equipment, modification and track
patches for the owner's decrypted 2.71.1 client. No results are fabricated.
"""
import argparse
import hashlib
import json
import struct
from pathlib import Path
from enable_ios_local_match import assemble
from enable_ios_local_results import branch

TEAM_SITE, TEAM_CAVE = 0x2B1EFC4, 0x4300
RESULT_SITE, RESULT_CAVE = 0x27397D0, 0x3180
DLSYM = 0x65B2448
RANGES = (
    (0x2B1EF9C, 0x2B1EFCC, '4de657212126a6f03549ce49eddf79533608a813d11797b7ba53eba478585372'),
    (0x2809D20, 0x2809D5C, '36b1a496e02421e63948145664aab909d904bee4a85cd1444ba20331f413fa28'),
    (0x280C5D4, 0x280C614, '7facbb49122cdf9d3705e9030aee5210efdd65d76e232252876361ac4c1b0639'),
    (0x3180, 0x3200, '3ea19a206c0e9eacfce58a6d61ce35ed218fb872b7ff203e63c7c36eb9735920'),
)

def validate_layout(data):
    if data[:8]!=bytes.fromhex('cffaedfe0c000001'):
        raise ValueError('Expected retained thin ARM64 Mach-O')
    if 32+struct.unpack_from('<I',data,20)[0]>0x3000:
        raise ValueError('Load commands overlap bridge padding')
    position,valid=32,False
    for _ in range(struct.unpack_from('<I',data,16)[0]):
        command,size=struct.unpack_from('<II',data,position)
        if size<8 or position+size>len(data):raise ValueError('Invalid Mach-O command')
        if command==0x2c and struct.unpack_from('<I',data,position+16)[0]:
            raise ValueError('Encrypted executable; preserve decrypted input')
        if command==0x19 and data[position+8:position+24].rstrip(b'\0')==b'__TEXT':
            vm,_,off,_,_,prot,sections,_=struct.unpack_from('<QQQQiiII',data,position+24)
            valid=vm==0x100000000 and off==0 and prot==5 and sections>0 and struct.unpack_from('<I',data,position+120)[0]==0x6f00
        position+=size
    if not valid:raise ValueError('Unexpected executable segment layout')

def team_bridge():
    return assemble('''
stp x19, x30, [sp, #-0x20]!
str w8, [sp, #0x10]
mov x0, #-2
adr x1, symbol
bl .
cbz x0, unchanged
mov x16, x0
mov x0, x19
mov x1, x22
mov w2, w20
ldr w3, [sp, #0x10]
blr x16
mov w8, w0
b store
unchanged:
ldr w8, [sp, #0x10]
store:
ldp x19, x30, [sp], #0x20
str w8, [x22, #0x16c]
b .
symbol:
.asciz "offline_local_team_index"
.p2align 2
''', TEAM_CAVE, [DLSYM], [TEAM_SITE+4])

def result_bridge():
    # Preserve the original stack-owned TUniquePtr result storage at old sp+8.
    return assemble('''
cbnz x21, done
stp x20, x30, [sp, #-0x20]!
mov x0, #-2
adr x1, symbol
bl .
cbz x0, failed
blr x0
cbz x0, failed
mov x16, x0
add x8, sp, #0x28
blr x16
ldp x20, x30, [sp], #0x20
ldr x21, [sp, #8]
b done
failed:
ldp x20, x30, [sp], #0x20
done:
ldr x0, [x19, #0xe0]
b .
symbol:
.asciz "offline_local_result_factory"
.p2align 2
''', RESULT_CAVE, [DLSYM], [RESULT_SITE+4])

def patch(source, destination):
    source, destination = Path(source), Path(destination)
    if source.resolve()==destination.resolve():
        raise ValueError('Preserve the input; use a separate output')
    data=bytearray(source.read_bytes())
    validate_layout(data)
    for entry,cave,link in [(0x2DDBFC8,0x3E00,False),(0x2B1F18C,0x4000,True),(RESULT_SITE,RESULT_CAVE,False)]:
        if data[entry:entry+4]!=branch(entry,cave,link):
            raise ValueError('Requires matching local track, upgrade and automatic-result patches')
    for a,z,digest in RANGES:
        if hashlib.sha256(data[a:z]).hexdigest()!=digest:
            raise ValueError('Original team/result functions differ from the verified build')
    if any(data[TEAM_CAVE:TEAM_CAVE+0x100]):
        raise ValueError('Required team bridge padding is unavailable')
    for cave,limit,code in [(TEAM_CAVE,0x100,team_bridge()),(RESULT_CAVE,0x80,result_bridge())]:
        if len(code)>limit:
            raise ValueError('Team/result bridge exceeds its verified padding')
        data[cave:cave+limit]=code.ljust(limit,b'\0')
    data[TEAM_SITE:TEAM_SITE+4]=branch(TEAM_SITE,TEAM_CAVE)
    destination.write_bytes(data)
    return {'sha256':hashlib.sha256(data).hexdigest(),'runtime_verified':False,
            'requires_resigning':True,'original_team_rules_and_results':True}

if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('source');p.add_argument('destination');a=p.parse_args()
    print(json.dumps(patch(a.source,a.destination),indent=2))
