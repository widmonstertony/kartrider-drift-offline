"""Apply original equipment and notify original widgets in a local debug account.

For the retained, decrypted iOS 2.71.1 executable. Connected and ordinary
accounts retain the original request. No purchase or server response is made.
"""
import argparse
import hashlib
import json
import struct
import subprocess
import tempfile
from pathlib import Path
from enable_ios_local_results import branch

ENTRY, END, CAVE = 0x2D61E60, 0x2D61EDC, 0x3200
RANGES = (
    (0x2E75C9C, 0x2E75D70, '6e42b4949a774ab92a5ca1bcf74abf8fc4015208ec6f5605b4bba1b5ede2736d'),
    (0x1A34310, 0x1A344AC, '4e6c976b72d88c788cc696e26bdb4589914056a2d1873c7e7c712678ad607b92'),
    (0x2D61CB8, 0x2D61E60, '06dfd301cb6d1aaad0b5f06ff0b05f70cffc6fab3df14e6acd6d2e5cf2b20b40'),
    (0x37A5868, 0x37A5924, '223d239ec3275c0df3bcb7359e514c482642e78d09a0585e9330decba98af03d'),
    (ENTRY, END, 'ddc994306a498890ff3bb8502b781632ef139a87cd83e695606180a5f5dc666e'),
    (0x2D87A60, 0x2D87A68, '3abad5cde086c2eee1a5f86c9e392fbecec51811e6f6cfd6d6c74703aec8b208'),
    (0x2D8717C, 0x2D8720C, '31177d424662031d1b144616b7f9748a512f78324d6e4d78794388ce696beb3e'),
)


def stub(entry, cave, lookup):
    # The request's original subsystem outer is its account. Both checks are
    # required before replacing its request with original local interfaces.
    source = '''.text
.p2align 2
ldr x8, [x0, #0x20]
cbz x8, original
ldrb w9, [x8, #0x1a0]
cmp w9, #1
b.ne original
ldr x9, [x8, #0xa30]
cbnz x9, original
stp x19, x20, [sp, #-0x30]!
str x30, [sp, #0x10]
mov x19, x0
LOOKUP
bl .
mov w8, #1
strb w8, [sp, #0x20]
add x0, x19, #0x48
add x1, sp, #0x20
bl .
finished:
mov x0, #0
ldr x30, [sp, #0x10]
ldp x19, x20, [sp], #0x30
ret
original:
SUB_FRAME
b .
'''
    source = source.replace('SUB_FRAME', 'sub sp, sp, #0x80' if lookup else 'sub sp, sp, #0x70')
    source = source.replace('LOOKUP', '''mov x20, x1
bl .
mov x1, x0
mov x0, x19
bl .
cbz x0, finished
mov x19, x0
mov x1, x20''' if lookup else '')
    with tempfile.TemporaryDirectory(prefix='kart-garage-') as directory:
        asm, obj = Path(directory)/'bridge.s', Path(directory)/'bridge.o'
        asm.write_text(source)
        subprocess.run(['xcrun', '--sdk', 'iphoneos', 'clang', '-target',
                        'arm64-apple-ios15.0', '-c', str(asm), '-o', str(obj)], check=True)
        data = obj.read_bytes()
    position, text = 32, None
    for _ in range(struct.unpack_from('<I', data, 16)[0]):
        command, size = struct.unpack_from('<II', data, position)
        if command == 0x19:
            for i in range(struct.unpack_from('<I', data, position+64)[0]):
                section = position+72+i*80
                if data[section:section+16].rstrip(b'\0') == b'__text':
                    length, offset = struct.unpack_from('<QI', data, section+40)
                    text = bytearray(data[offset:offset+length])
        position += size
    if text is None:
        raise ValueError('Assembler did not produce bridge instructions')
    calls = [i for i in range(0, len(text), 4) if text[i:i+4] == b'\0\0\0\x94']
    targets = ([0x37A5868, 0x2E75C9C] if lookup else [])+[0x2D87A60, 0x1A34310]
    if len(calls) != len(targets) or text[-4:] != b'\0\0\0\x14':
        raise ValueError('Unexpected assembler bridge layout')
    for offset, target in zip(calls, targets):
        text[offset:offset+4] = branch(cave+offset, target, True)
    text[-4:] = branch(cave+len(text)-4, entry+4)
    return text


def patch(source, destination):
    source, destination = Path(source), Path(destination)
    if source.resolve() == destination.resolve():
        raise ValueError('Use separate output; preserve the input')
    data = bytearray(source.read_bytes())
    if data[:4] != b'\xcf\xfa\xed\xfe' or struct.unpack_from('<I', data, 4)[0] != 0x100000C:
        raise ValueError('Expected thin ARM64 Mach-O')
    for start, end, digest in RANGES:
        if hashlib.sha256(data[start:end]).hexdigest() != digest:
            raise ValueError('Original equipment functions differ from retained 2.71.1')
    bridges = [(0x2D61CB8, 0x3200, True), (ENTRY, 0x3300, False)]
    if 32+struct.unpack_from('<I', data, 20)[0] > CAVE:
        raise ValueError('Required unused header padding is unavailable')
    position, valid = 32, False
    for _ in range(struct.unpack_from('<I', data, 16)[0]):
        command, size = struct.unpack_from('<II', data, position)
        if command == 0x2C and struct.unpack_from('<I', data, position+16)[0]:
            raise ValueError('Encrypted executable; use retained decrypted copy')
        if command == 0x19 and data[position+8:position+24].rstrip(b'\0') == b'__TEXT':
            vm, _, off, _, _, prot, sections, _ = struct.unpack_from('<QQQQiiII', data, position+24)
            first = struct.unpack_from('<I', data, position+72+48)[0]
            valid = vm == 0x100000000 and off == 0 and prot == 5 and sections > 0 and first == 0x6F00 and 0x3400 <= first
        position += size
    if not valid:
        raise ValueError('Unexpected original executable or equipment entry')
    for entry, cave, lookup in bridges:
        code = stub(entry, cave, lookup)
        expected = 0xD10203FF if lookup else 0xD101C3FF
        if len(code) > 0x100 or any(data[cave:cave+len(code)]) or data[entry:entry+4] != struct.pack('<I', expected):
            raise ValueError('Required bridge padding or original entry unavailable')
        data[entry:entry+4] = branch(entry, cave)
        data[cave:cave+len(code)] = code
    destination.write_bytes(data)
    return {'offsets': [hex(x) for bridge in bridges for x in bridge[:2]], 'requires_resigning': True,
            'runtime_verified': False, 'sha256': hashlib.sha256(data).hexdigest()}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source')
    parser.add_argument('destination')
    args = parser.parse_args()
    print(json.dumps(patch(args.source, args.destination), indent=2))
