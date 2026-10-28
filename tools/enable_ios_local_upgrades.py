"""Route original gear apply/reset requests to our isolated local account.

Only the retained decrypted 2.71.1 build is accepted. Original owning maps,
widgets and parameter limits remain in use; this does not verify race handling.
"""
import argparse
import hashlib
import json
import struct
from pathlib import Path
from enable_ios_local_match import assemble
from enable_ios_local_results import branch

GEAR, RESET, DLSYM = 0x2E26CAC, 0x2E27098, 0x65B2448
BRIDGES = [(GEAR, 0x3C00, 0xA0, 0), (RESET, 0x3D00, 0x90, 1)]
BODY_SITE, BODY_CAVE, BODY_SETTER = 0x2B1F18C, 0x4000, 0x274E184
RANGES = (
    (0x2E26CAC, 0x2E26EA8, '958a827479201ec7a40bae84a7b62d67730f2f34b2dd4b960adf5e48f70f28bf'),
    (0x2E27098, 0x2E27264, '9306c82204efad37b0b03900f8fe3ee368b69f28932de712fc4f552a2ebcfb32'),
    (0x65B2448, 0x65B2454, 'b7410db2d310378c64a19e10dd4b0ca62e073d5014ae28e6b0b6999fc8bbf222'),
    # Matching original AddUnknownPlayer after our required local-AI guard.
    (0x2B1EB40, 0x2B1F250, '521e95a2161c4e5e174d4741e65d5b676f0e25db12fe928e156d97b35d1ec5db'),
    (0x24EAC7C, 0x24EAECC, '9539562d247acde4ebf9b2bba4fd90ff4381d2e13c4b70be07da542dbf293318'),
    (0x24EAECC, 0x24EB2DC, '2e4c58eb51fc42a7acff36b42ede31e7f008241a57637dade93e16f3a3bb689a'),
)


def request_bridge(entry, cave, frame, reset):
    return assemble(f'''
ldrb w8, [x0, #0x1a0]
cmp w8, #1
b.ne original
ldr x8, [x0, #0xa30]
cbnz x8, original
stp x19, x20, [sp, #-0x30]!
stp x21, x30, [sp, #0x10]
mov x19, x0
mov x20, x1
mov x21, x2
mov x0, #-2
adr x1, symbol
bl .
cbz x0, finished
mov x16, x0
mov x0, x19
mov x1, x20
mov x2, x21
mov w3, #{reset}
blr x16
finished:
ldp x21, x30, [sp, #0x10]
ldp x19, x20, [sp], #0x30
ret
original:
sub sp, sp, #{frame}
b .
symbol:
.asciz "offline_upgrade_request"
.p2align 2
''', cave, [DLSYM], [entry+4])


def body_bridge():
    # Keep the original stack-owned body/channel parameters and setter. Only
    # the saved local player's gear changes the body parameter temporary.
    return assemble('''
stp x19, x20, [sp, #-0x40]!
stp x21, x22, [sp, #0x10]
str x30, [sp, #0x20]
mov x19, x0
mov x20, x1
mov x21, x2
bl .
cbz x0, finished
mov x22, x0
mov x0, #-2
adr x1, symbol
bl .
cbz x0, finished
mov x16, x0
mov x0, x19
mov x1, x20
mov x2, x22
blr x16
finished:
mov x0, x19
mov x1, x20
mov x2, x21
ldr x30, [sp, #0x20]
ldp x21, x22, [sp, #0x10]
ldp x19, x20, [sp], #0x40
b .
symbol:
.asciz "offline_race_upgrade"
.p2align 2
''', BODY_CAVE, [0x3A00,DLSYM], [BODY_SETTER])


def patch(source, destination):
    source, destination = Path(source), Path(destination)
    if source.resolve() == destination.resolve():
        raise ValueError('Use separate output; preserve the input')
    data = bytearray(source.read_bytes())
    if data[:8] != bytes.fromhex('cffaedfe0c000001'):
        raise ValueError('Expected retained thin ARM64 Mach-O')
    for start, end, digest in RANGES:
        if hashlib.sha256(data[start:end]).hexdigest() != digest:
            raise ValueError('Original modification functions differ from retained 2.71.1')
    if data[0x26B16F0:0x26B16F4] != branch(0x26B16F0, 0x3800):
        raise ValueError('Requires the matching isolated local race-equipment patch')
    position, valid = 32, False
    if 32+struct.unpack_from('<I', data, 20)[0] > 0x3C00:
        raise ValueError('Load commands overlap required padding')
    for _ in range(struct.unpack_from('<I', data, 16)[0]):
        command, size = struct.unpack_from('<II', data, position)
        if command == 0x2C and struct.unpack_from('<I', data, position+16)[0]:
            raise ValueError('Encrypted executable; use retained decrypted input')
        if command == 0x19 and data[position+8:position+24].rstrip(b'\0') == b'__TEXT':
            vm, _, off, _, _, prot, sections, _ = struct.unpack_from('<QQQQiiII', data, position+24)
            valid = vm == 0x100000000 and off == 0 and prot == 5 and sections > 0 and struct.unpack_from('<I', data, position+120)[0] == 0x6F00
        position += size
    if not valid:
        raise ValueError('Unexpected executable segment layout')
    for entry, cave, frame, reset in BRIDGES:
        code = request_bridge(entry, cave, frame, reset)
        if len(code) > 0x100 or any(data[cave:cave+len(code)]):
            raise ValueError('Required modification bridge padding unavailable')
        data[entry:entry+4] = branch(entry, cave)
        data[cave:cave+len(code)] = code
    code=body_bridge()
    if len(code)>0x100 or any(data[BODY_CAVE:BODY_CAVE+0x100]):
        raise ValueError('Required race modification bridge padding unavailable')
    if data[BODY_SITE:BODY_SITE+4]!=branch(BODY_SITE,BODY_SETTER,True):
        raise ValueError('Original race body parameter setter differs')
    data[BODY_SITE:BODY_SITE+4]=branch(BODY_SITE,BODY_CAVE,True)
    data[BODY_CAVE:BODY_CAVE+len(code)]=code
    destination.write_bytes(data)
    return {'runtime_verified': False, 'requires_resigning': True,
            'sha256': hashlib.sha256(data).hexdigest()}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source')
    parser.add_argument('destination')
    args = parser.parse_args()
    print(json.dumps(patch(args.source, args.destination), indent=2))
