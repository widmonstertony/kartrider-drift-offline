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
    if mode not in (*FACTORIES, 'auto'):
        raise ValueError('Select speed, item or automatic solo results')
    data = bytearray(source.read_bytes())
    if data[:4] != b'\xcf\xfa\xed\xfe':
        raise ValueError('Expected a thin ARM64 Mach-O')
    if hashlib.sha256(data[START:END]).hexdigest() != FUNCTION_SHA256:
        raise ValueError('Result initialization differs from the verified build')
    for factory, factory_end, digest in (FACTORIES.values() if mode == 'auto' else [FACTORIES[mode]]):
        if not digest or hashlib.sha256(data[factory:factory_end]).hexdigest() != digest:
            raise ValueError('Original solo result factory differs from the verified build')
    # x19 = original result component; x21 = selected original styler. The
    # containing function has saved LR/callee-saved registers. Its sp+8 scratch
    # slot already holds the factory's TUniquePtr return storage in this path.
    cave = CAVE
    stub = (struct.pack('<II', 0xB5000095, 0x910023E8) +
            branch(cave + 8, factory, link=True) +
            struct.pack('<II', 0xF94007F5, 0xF9407260) +
            branch(cave + 20, OFFSET + 4))
    if mode == 'auto':
        # Choose the original factory using the current original game-mode
        # class. This supports changing modes without changing executable code.
        getter_digest = 'c0110070f0c433e6d6375e4aa28095340c22f52540b493abc1aec5aeea7ea8cd'
        if hashlib.sha256(data[0x3957C38:0x3957CF8]).hexdigest() != getter_digest:
            raise ValueError('Item-mode class singleton differs from the verified build')
        cave = 0x3180
        def adrp(index, register, target):
            pages = (target - ((0x100000000+cave+index*4) & ~4095)) // 4096
            return 0x90000000 | register | ((pages & 3) << 29) | (((pages >> 2) & 0x7ffff) << 5)
        def load(register, base, offset):
            return 0xF9400000 | ((offset//8) << 10) | (base << 5) | register
        def cb(index, target, register, nonzero=False):
            return (0xB5000000 if nonzero else 0xB4000000) | (((target-index) & 0x7ffff) << 5) | register
        words = [cb(0,23,21,True), adrp(1,9,0x108B0B000), load(9,9,0x288), cb(3,17,9),
                 load(9,9,0xc48), cb(5,17,9), load(9,9,0), cb(7,17,9),
                 load(9,9,0x280), cb(9,17,9), load(9,9,0x118), cb(11,17,9),
                 load(9,9,0x10), adrp(13,10,0x1087C2000), load(10,10,0x198),
                 0xEB0A013F, 0x54000080, 0x910023E8, 0, 0,
                 0x910023E8, 0, 0xF94007F5, 0xF9407260, 0]
        stub = bytearray(struct.pack('<25I', *words))
        for index, target, link in [(18,FACTORIES['speed'][0],True), (19,cave+22*4,False),
                                    (21,FACTORIES['item'][0],True), (24,OFFSET+4,False)]:
            stub[index*4:index*4+4] = branch(cave+index*4,target,link)
    if data[OFFSET:OFFSET + 4] != struct.pack('<I', 0xF9407260):
        raise ValueError('Unexpected original result assignment')
    if 32 + struct.unpack_from('<I', data, 20)[0] > cave or any(data[cave:cave + len(stub)]):
        raise ValueError('Required unused header padding is unavailable')
    position, executable_padding = 32, False
    for _ in range(struct.unpack_from('<I', data, 16)[0]):
        command, size = struct.unpack_from('<II', data, position)
        if command == 0x19 and data[position+8:position+24].rstrip(b'\0') == b'__TEXT':
            vm, _, file_offset, _, _, protection, sections, _ = struct.unpack_from('<QQQQiiII', data, position+24)
            first_section = struct.unpack_from('<I', data, position+72+48)[0]
            executable_padding = (vm == 0x100000000 and file_offset == 0 and protection == 5
                                  and sections > 0 and first_section == 0x6f00
                                  and cave + len(stub) <= first_section)
        position += size
    if not executable_padding:
        raise ValueError('Unexpected executable segment layout')
    data[OFFSET:OFFSET+4] = branch(OFFSET, cave)
    data[cave:cave+len(stub)] = stub
    destination.write_bytes(data)
    return {'mode': mode, 'offsets': [hex(OFFSET), hex(cave)],
            'original_factories': {name: hex(0x100000000+values[0]) for name, values in FACTORIES.items() if mode in (name,'auto')},
            'requires_resigning': True, 'complete_race_verified': False,
            'sha256': hashlib.sha256(data).hexdigest()}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source')
    parser.add_argument('destination')
    parser.add_argument('--mode', choices=(*FACTORIES,'auto'), required=True)
    args = parser.parse_args()
    print(json.dumps(patch(args.source, args.destination, args.mode), indent=2))
