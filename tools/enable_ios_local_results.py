"""Supply an original solo result styler when offline mode metadata is absent.

Only the preserved iOS 2.71.1 build is supported. The original component, data
provider, result widgets and race results remain in use. This diagnostic patch
calls the client's own speed/item solo factory only if its styler is null.
It does not manufacture rankings or finishing times.
"""
import argparse
import hashlib
import json
import struct
from pathlib import Path

START, END = 0x27394A4, 0x2739880
FUNCTION_SHA256 = '378920a3f62544e6f6bfc5c7994c7dced7a308676ef258fd54a01dfdc7e0464f'
OFFSET, CAVE = 0x27397D0, 0x3080
FACTORIES = {'speed': (0x280AAB4, 0x280AAF4,
    'c0559daf9950a4977fb3fddb052c6cb9893199d47e1ce2c15ca3e5940ce93abe'),
    'item': (0x2808228, 0x2808264,
    '82002c21c1994f52d32ebbdb57d0481b8f2a9278cef9a2b6764d860fa2140ce3')}


def branch(source, target, link=False):
    delta = target - source
    if delta % 4 or not -(1 << 27) <= delta < (1 << 27):
        raise ValueError('ARM64 branch target out of range')
    return struct.pack('<I', (0x94000000 if link else 0x14000000) |
                       ((delta // 4) & 0x3ffffff))


def patch(source, destination, mode):
    source, destination = Path(source), Path(destination)
    if source.resolve() == destination.resolve():
        raise ValueError('Use a separate output; preserve the input')
    if mode not in FACTORIES:
        raise ValueError('Select speed or item solo results')
    data = bytearray(source.read_bytes())
    if data[:4] != b'\xcf\xfa\xed\xfe':
        raise ValueError('Expected a thin ARM64 Mach-O')
    if hashlib.sha256(data[START:END]).hexdigest() != FUNCTION_SHA256:
        raise ValueError('Result initialization differs from the verified build')
    factory, factory_end, digest = FACTORIES[mode]
    if not digest or hashlib.sha256(data[factory:factory_end]).hexdigest() != digest:
        raise ValueError('Original solo result factory differs from the verified build')
    # x19 = original result component; x21 = selected original styler. The
    # containing function has saved LR/callee-saved registers. Its sp+8 scratch
    # slot already holds the factory's TUniquePtr return storage in this path.
    stub = (struct.pack('<II', 0xB5000095, 0x910023E8) +
            branch(CAVE + 8, factory, link=True) +
            struct.pack('<II', 0xF94007F5, 0xF9407260) +
            branch(CAVE + 20, OFFSET + 4))
    if data[OFFSET:OFFSET + 4] != stub[16:20]:
        raise ValueError('Unexpected original result assignment')
    if 32 + struct.unpack_from('<I', data, 20)[0] > CAVE or any(data[CAVE:CAVE + len(stub)]):
        raise ValueError('Required unused header padding is unavailable')
    position, executable_padding = 32, False
    for _ in range(struct.unpack_from('<I', data, 16)[0]):
        command, size = struct.unpack_from('<II', data, position)
        if command == 0x19 and data[position+8:position+24].rstrip(b'\0') == b'__TEXT':
            vm, _, file_offset, _, _, protection, sections, _ = struct.unpack_from('<QQQQiiII', data, position+24)
            first_section = struct.unpack_from('<I', data, position+72+48)[0]
            executable_padding = (vm == 0x100000000 and file_offset == 0 and protection == 5
                                  and sections > 0 and first_section == 0x6f00
                                  and CAVE + len(stub) <= first_section)
        position += size
    if not executable_padding:
        raise ValueError('Unexpected executable segment layout')
    data[OFFSET:OFFSET+4] = branch(OFFSET, CAVE)
    data[CAVE:CAVE+len(stub)] = stub
    destination.write_bytes(data)
    return {'mode': mode, 'offsets': [hex(OFFSET), hex(CAVE)],
            'original_factory': hex(0x100000000 + factory),
            'requires_resigning': True, 'complete_race_verified': False,
            'sha256': hashlib.sha256(data).hexdigest()}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source')
    parser.add_argument('destination')
    parser.add_argument('--mode', choices=FACTORIES, required=True)
    args = parser.parse_args()
    print(json.dumps(patch(args.source, args.destination, args.mode), indent=2))
