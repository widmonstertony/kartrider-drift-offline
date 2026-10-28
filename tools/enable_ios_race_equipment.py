"""Use the local garage preset in original solo-race equipment loading.

The isolated debug account supplies its saved human preset and a fresh,
compatible per-race AI roster. Original SetItems, ApplyDesc, mesh loading and destruction
remain responsible for native descriptors and their allocations.
"""
import argparse
import hashlib
import json
import struct
from pathlib import Path
from enable_ios_local_match import assemble
from enable_ios_local_results import branch

KART_SITE, CHARACTER_SITE = 0x26B16F0, 0x259B388
KART_CAVE, CHARACTER_CAVE, HELPER = 0x3800, 0x3900, 0x3A00
KART_ITEMS, CHARACTER_ITEMS = 0x298B3CC, 0x2544EC0
PAWN_CLASS, PRESET_CLASS, GET_SUBSYSTEM = 0x3AE241C, 0x37A5868, 0x2E75C9C
RANGES = (
    (0x26B127C, 0x26B17C8, 'dfa6bfcf1fa8dda8607803c42bc74299ffe73e122155272260028bd4e6c41a72'),
    (0x259B298, 0x259B498, '085cee8b268c8121a5c9368ee85bf227e2cf3cdb8c67c9b814b4ce399350be73'),
    (CHARACTER_ITEMS, 0x2544FFC, 'dfa67119d5c080e13285b09641d1b71f2753a79ef561be664838c82a654803a4'),
    (KART_ITEMS, 0x298B684, 'a201e61016c6346ab5275a5e58895dcf77ddbffe87cf4d197e2bb530336d30b1'),
    (PAWN_CLASS, 0x3AE24DC, 'a7999233d0e0b22ad4710880c47a8ec0ee0f183faa588cb31d511f5dd2f2dd86'),
    (GET_SUBSYSTEM, 0x2E75D70, '6e42b4949a774ab92a5ca1bcf74abf8fc4015208ec6f5605b4bba1b5ede2736d'),
    (PRESET_CLASS, 0x37A5924, '223d239ec3275c0df3bcb7359e514c482642e78d09a0585e9330decba98af03d'),
)


def equipment_bridge(cave, site, stack_offset, field, setter):
    # x19 is the existing skeletal mesh component. Parent stack owns the fully
    # constructed descriptor. Replace its values before original ApplyDesc.
    return assemble(f'''
stp x20, x30, [sp, #-0x20]!
add x20, sp, #{0x20+stack_offset}
mov x0, x19
bl .
cbz x0, done
mov x1, x0
mov x0, x20
mov w2, #1
bl .
done:
ldp x20, x30, [sp], #0x20
mov w8, #{field}
b .
''', cave, [HELPER, setter], [site+4])


def preset_bridge():
    return assemble('''
stp x19, x30, [sp, #-0x20]!
mov x19, x0
mov x0, #-2
adr x1, symbol
bl .
cbz x0, done
mov x16, x0
mov x0, x19
blr x16
done:
ldp x19, x30, [sp], #0x20
ret
symbol:
.asciz "offline_race_preset"
.p2align 2
''', HELPER, [0x65B2448], [])


def patch(source, destination):
    source, destination = Path(source), Path(destination)
    if source.resolve() == destination.resolve():
        raise ValueError('Use a separate output; preserve the input')
    data = bytearray(source.read_bytes())
    if data[:8] != bytes.fromhex('cffaedfe0c000001'):
        raise ValueError('Expected the retained thin ARM64 Mach-O')
    for start, end, digest in RANGES:
        if hashlib.sha256(data[start:end]).hexdigest() != digest:
            raise ValueError('Original equipment functions differ from retained 2.71.1')
    if data[0x2D72188:0x2D7218C] != branch(0x2D72188, 0x3400):
        raise ValueError('Requires the isolated original local-match patch')
    if 32+struct.unpack_from('<I', data, 20)[0] > KART_CAVE:
        raise ValueError('Required unused executable padding is unavailable')
    position, valid = 32, False
    for _ in range(struct.unpack_from('<I', data, 16)[0]):
        command, size = struct.unpack_from('<II', data, position)
        if command == 0x2C and struct.unpack_from('<I', data, position+16)[0]:
            raise ValueError('Encrypted executable; use the retained decrypted copy')
        if command == 0x19 and data[position+8:position+24].rstrip(b'\0') == b'__TEXT':
            vm, _, off, _, _, prot, sections, _ = struct.unpack_from('<QQQQiiII', data, position+24)
            first = struct.unpack_from('<I', data, position+72+48)[0]
            valid = vm == 0x100000000 and off == 0 and prot == 5 and sections > 0 and first == 0x6F00
        position += size
    if not valid:
        raise ValueError('Unexpected executable segment layout')
    bridges = [
        (KART_CAVE, equipment_bridge(KART_CAVE, KART_SITE, 0, 0x10B0, KART_ITEMS)),
        (CHARACTER_CAVE, equipment_bridge(CHARACTER_CAVE, CHARACTER_SITE, 0x20, 0x1020, CHARACTER_ITEMS)),
        (HELPER, preset_bridge()),
    ]
    for offset, code in bridges:
        if offset+len(code) > offset+0x100 or any(data[offset:offset+len(code)]):
            raise ValueError('Required equipment bridge padding is unavailable')
    for site, cave, instruction in [(KART_SITE, KART_CAVE, 0x52821608),
                                    (CHARACTER_SITE, CHARACTER_CAVE, 0x52820408)]:
        if data[site:site+4] != struct.pack('<I', instruction):
            raise ValueError('Unexpected descriptor application instruction')
        data[site:site+4] = branch(site, cave)
    for offset, code in bridges:
        data[offset:offset+len(code)] = code
    destination.write_bytes(data)
    return {'local_player_equipment_verified': False,
            'sha256': hashlib.sha256(data).hexdigest(), 'requires_resigning': True}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source')
    parser.add_argument('destination')
    args = parser.parse_args()
    print(json.dumps(patch(args.source, args.destination), indent=2))
