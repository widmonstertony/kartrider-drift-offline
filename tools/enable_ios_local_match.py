"""Experimental original-lobby match request and result-to-lobby routing.

The local debug account retains the original selected game-mode array, rather
than making a server request. Our game-thread dispatcher consumes that request.
This patch does not implement race physics, AI, items, or a replacement UI.
Only the retained, decrypted ARM64 iOS 2.71.1 executable is supported.
"""
import argparse
import hashlib
import json
import struct
import subprocess
import tempfile
from pathlib import Path
from enable_ios_local_results import branch

ENTRY, CAVE = 0x2D72188, 0x3400
EXIT, EXIT_CAVE, EXIT_ORIGINAL, EPILOGUE = 0x304C240, 0x3500, 0x2E785E0, 0x304C38C
COPY_MODES, STRING_NAME, OPEN = 0x2D7262C, 0x5AB8D20, 0x59ECFD0
LOBBY = '/Game/ART/Env/Stage_Kartmain_mobile/KartMain_mobile/KartMain_mobile'
OPTIONS = 'game=/Script/KartDrift.OutGameMode?players=1'
RANGES = (
    (ENTRY, COPY_MODES, 'c93aed9ecc042b356d4f12897473692a990b6782398d4fab5eb9aa369b1b9ab7'),
    (COPY_MODES, 0x2D72740, 'eae563b1f03155fef05204cec6deefceb2617b635dbe9197e81179ca04c481b6'),
    (STRING_NAME, 0x5AB8D60, 'c143e3496716b5986c1c03eaedc6f7f177d62abb532377f05e97ed107284735f'),
    (0x2821AF4, 0x2821B74, '9c03ab5b50ef0439fa233a1c6229670b45b5d529e066de2088d24361bb173071'),
    (0x304C21C, 0x304C3A0, '42e05ce7a1d2b04dca989494c24784c6346038f3eb04e02b80a8f35050c49286'),
    (OPEN, 0x59ED258, '206e7feeaf79462fa5250ce1e58fd0d49f15227d2fc51288759d1869c5ac1ed8'),
)


def assemble(source, address, calls, jumps):
    with tempfile.TemporaryDirectory(prefix='kart-local-match-') as directory:
        asm, obj = Path(directory)/'bridge.s', Path(directory)/'bridge.o'
        asm.write_text('.text\n.p2align 2\n'+source)
        subprocess.run(['xcrun', '--sdk', 'iphoneos', 'clang', '-target',
                        'arm64-apple-ios15.0', '-c', str(asm), '-o', str(obj)], check=True)
        data = obj.read_bytes()
    position, result = 32, None
    for _ in range(struct.unpack_from('<I', data, 16)[0]):
        command, size = struct.unpack_from('<II', data, position)
        if command == 0x19:
            for i in range(struct.unpack_from('<I', data, position+64)[0]):
                section = position+72+i*80
                if data[section:section+16].rstrip(b'\0') == b'__text':
                    length, offset = struct.unpack_from('<QI', data, section+40)
                    result = bytearray(data[offset:offset+length])
        position += size
    if result is None:
        raise ValueError('Assembler did not produce bridge instructions')
    for word, targets, link in [(0x94000000, calls, True), (0x14000000, jumps, False)]:
        sites = [i for i in range(0, len(result)-3, 4) if struct.unpack_from('<I', result, i)[0] == word]
        if len(sites) != len(targets):
            raise ValueError('Unexpected assembler bridge call/jump layout')
        for offset, target in zip(sites, targets):
            result[offset:offset+4] = branch(address+offset, target, link)
    return result


def request_bridge():
    return assemble('''
ldr x8, [x0, #0x20]
cbz x8, original
ldrb w9, [x8, #0x1a0]
cmp w9, #1
b.ne original
ldr x9, [x8, #0xa30]
cbnz x9, original
stp x19, x30, [sp, #-0x20]!
mov x19, x0
cbz x1, finished
ldr w8, [x1, #8]
cmp w8, #1
b.lt finished
cmp w8, #16
b.gt finished
ldr x8, [x1]
cbz x8, finished
add x0, x19, #0x1e8
bl .
mov w8, #1
strb w8, [x19, #0x30]
finished:
ldp x19, x30, [sp], #0x20
ret
original:
sub sp, sp, #0xe0
b .
''', CAVE, [COPY_MODES], [ENTRY+4])


def result_bridge():
    def words(value):
        return '.short '+','.join(str(ord(c)) for c in value+'\0')
    # The original result handler already saved x20/LR, and owns the scratch
    # FString at sp+0x10. Local exit skips to its original epilogue.
    return assemble(f'''
cbz x0, original
ldr x8, [x0, #0x38]
cbnz x8, original
mov x20, x0
adr x9, lobby_path
mov x10, #{len(LOBBY)+1}
movk x10, #{len(LOBBY)+1}, lsl #32
stp x9, x10, [sp, #0x10]
add x0, sp, #0x10
bl .
mov x1, x0
mov x0, x20
mov w2, #1
adr x9, lobby_options
mov x10, #{len(OPTIONS)+1}
movk x10, #{len(OPTIONS)+1}, lsl #32
stp x9, x10, [sp, #0x10]
add x3, sp, #0x10
bl .
b .
original:
bl .
b .
.p2align 2
lobby_path:
{words(LOBBY)}
.p2align 2
lobby_options:
{words(OPTIONS)}
''', EXIT_CAVE, [STRING_NAME, OPEN, EXIT_ORIGINAL], [EPILOGUE, EXIT+4])


def patch(source, destination):
    source, destination = Path(source), Path(destination)
    if source.resolve() == destination.resolve():
        raise ValueError('Use a separate output; preserve the input')
    data = bytearray(source.read_bytes())
    if data[:4] != b'\xcf\xfa\xed\xfe' or struct.unpack_from('<I', data, 4)[0] != 0x100000C:
        raise ValueError('Expected a thin ARM64 Mach-O')
    for start, end, digest in RANGES:
        if hashlib.sha256(data[start:end]).hexdigest() != digest:
            raise ValueError('Original match/travel functions differ from retained 2.71.1')
    if data[EXIT:EXIT+4] != branch(EXIT, EXIT_ORIGINAL, True) or data[ENTRY:ENTRY+4] != struct.pack('<I', 0xD10383FF):
        raise ValueError('Unexpected original match entry/result route')
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
            valid = vm == 0x100000000 and off == 0 and prot == 5 and sections > 0 and first == 0x6F00
        position += size
    if not valid:
        raise ValueError('Unexpected executable segment layout')
    for entry, cave, code, limit in [(ENTRY, CAVE, request_bridge(), 0x100),
                                      (EXIT, EXIT_CAVE, result_bridge(), 0x300)]:
        if len(code) > limit or any(data[cave:cave+len(code)]):
            raise ValueError('Required local match bridge padding unavailable')
        data[entry:entry+4] = branch(entry, cave)
        data[cave:cave+len(code)] = code
    destination.write_bytes(data)
    return {'offsets': [hex(x) for x in [ENTRY, CAVE, EXIT, EXIT_CAVE]],
            'requires_resigning': True, 'requires_game_thread_dispatcher': True,
            'runtime_verified': False, 'sha256': hashlib.sha256(data).hexdigest()}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source')
    parser.add_argument('destination')
    args = parser.parse_args()
    print(json.dumps(patch(args.source, args.destination), indent=2))
