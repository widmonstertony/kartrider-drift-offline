"""Diagnostic local AI slot selection for the preserved iOS 2.71.1 client.

The original connect rule identifies AI using identifiers supplied by a game
session. A direct offline map launch has no such identifiers. This experiment
selects the original AI pawn for slots at or above the parsed `players` count.
It preserves the original spawning, AI controller and gameplay implementations.
The same slot rule marks the original PawnState as AI. An optional experiment
keeps the original FollowTG path driver when player assist settings are applied.
This is an unverified diagnostic patch, not a complete offline race restoration.
"""
import argparse
import hashlib
import json
import struct
from pathlib import Path

START, END = 0x2B1DE54, 0x2B1E0A4
FUNCTION_SHA256 = '3a74f436bc665f6e6bfa7007e19ad316a9ec013e7e56b101539654f8f74dcc91'
OFFSET = 0x2B1DFF0
BEFORE = bytes.fromhex('e0830091e10319aa220080529e884694')
# ldr w8,[x23,#0x130]; cmp w24,w8; cset w0,ge; nop
# x23 = original connect rule; x24 = original slot index.
AFTER = bytes.fromhex('e83241b91f03086be0b79f1a1f2003d5')
STATE_START, STATE_END = 0x2B1EB40, 0x2B1F250
STATE_SHA256 = '165ab0eef7651007d3ddd04375a9d23145a719e9656888787cd86241ffa99504'
STATE_BRANCH = 0x2B1EC24
STUB_OFFSET = 0x3000
# Re-emit the displaced slot store, then mark the same local AI slots in
# the existing PawnState component. x19=connect rule, w20=slot, x22=PawnState.
STATE_STUB = bytes.fromhex('d46a01b9683241b99f02086be8b79f1ac8860c39')
DRIVER_START, DRIVER_END = 0x268CCF8, 0x268CDF8
DRIVER_SHA256 = '7a3be03f058afaa551e20ec905e1bb8c8b0395dfaa78aaa26f0b1881935320ee'
DRIVER_BRANCH, DRIVER_STUB = 0x268CD2C, 0x3040
DRIVER_CLASS_SHA256 = '9d2d4b494462d5924241f77f4b1cbe943db72dafbae2244ca4d3aaaeb6030fab'


def branch(source, target):
    delta = target - source
    if delta % 4 or not -(1 << 27) <= delta < (1 << 27):
        raise ValueError('ARM64 branch target out of range')
    return struct.pack('<I', 0x14000000 | ((delta // 4) & 0x3ffffff))


def patch(source, destination, preserve_path_driver=False):
    source, destination = Path(source), Path(destination)
    if source.resolve() == destination.resolve():
        raise ValueError('Use a separate output; preserve the input')
    data = bytearray(source.read_bytes())
    if data[:4] != b'\xcf\xfa\xed\xfe':
        raise ValueError('Expected a thin 64-bit little-endian Mach-O')
    if hashlib.sha256(data[START:END]).hexdigest() != FUNCTION_SHA256:
        raise ValueError('Connect-rule function differs from the verified build')
    if data[OFFSET:OFFSET + len(BEFORE)] != BEFORE:
        raise ValueError('Unexpected AI identifier lookup instructions')
    if hashlib.sha256(data[STATE_START:STATE_END]).hexdigest() != STATE_SHA256:
        raise ValueError('Unknown-player function differs from the verified build')
    if data[STATE_BRANCH:STATE_BRANCH + 4] != STATE_STUB[:4]:
        raise ValueError('Unexpected slot assignment instruction')
    stub = STATE_STUB + branch(STUB_OFFSET + len(STATE_STUB), STATE_BRANCH + 4)
    driver_stub = b''
    if preserve_path_driver:
        if hashlib.sha256(data[DRIVER_START:DRIVER_END]).hexdigest() != DRIVER_SHA256:
            raise ValueError('Auto-drive function differs from the verified build')
        if hashlib.sha256(data[0x38E5ED8:0x38E5F94]).hexdigest() != DRIVER_CLASS_SHA256:
            raise ValueError('Path-driver class registration differs from the verified build')
        # x0 is the existing AutoMoveComponent. Only preserve the exact original
        # FollowTG class; ordinary player navigation-assist destruction continues.
        # The class singleton lives at VM 0x1087b9bd0 in this preserved build.
        delta_pages = (0x1087B9000 - ((0x100000000 + DRIVER_STUB + 12) & ~4095)) // 4096
        adrp = 0x90000009 | ((delta_pages & 3) << 29) | (((delta_pages >> 2) & 0x7ffff) << 5)
        words = [0xB5000040, 0, 0xF9400808, adrp, 0xF945E929,
                 0xEB09011F, 0x54000041, 0, 0]
        driver_stub = bytearray(struct.pack('<9I', *words))
        driver_stub[4:8] = branch(DRIVER_STUB + 4, 0x268CD1C)
        driver_stub[28:32] = branch(DRIVER_STUB + 28, 0x268CD1C)
        driver_stub[32:36] = branch(DRIVER_STUB + 32, DRIVER_BRANCH + 4)
        if any(data[DRIVER_STUB:DRIVER_STUB + len(driver_stub)]):
            raise ValueError('Path-driver stub padding is unavailable')
    header_end = 32 + struct.unpack_from('<I', data, 20)[0]
    if header_end > STUB_OFFSET or any(data[STUB_OFFSET:STUB_OFFSET + len(stub)]):
        raise ValueError('Expected unused header padding is unavailable')
    # This build's __TEXT segment starts at file/VM offset zero with RX
    # permissions; its first section starts at 0x6f00. Check those facts
    # rather than treating arbitrary zero bytes as executable storage.
    position = 32
    text_verified = False
    for _ in range(struct.unpack_from('<I', data, 16)[0]):
        command, size = struct.unpack_from('<II', data, position)
        if command == 0x19 and data[position + 8:position + 24].rstrip(b'\0') == b'__TEXT':
            vm, vm_size, file_offset, file_size, maximum, initial, sections, flags = struct.unpack_from('<QQQQiiII', data, position + 24)
            first_section = struct.unpack_from('<I', data, position + 72 + 48)[0]
            text_verified = (vm == 0x100000000 and file_offset == 0 and initial == 5
                             and sections > 0 and first_section == 0x6f00
                             and STUB_OFFSET + len(stub) <= first_section
                             and DRIVER_STUB + len(driver_stub) <= first_section)
        position += size
    if not text_verified:
        raise ValueError('Unexpected executable segment layout')
    data[OFFSET:OFFSET + len(AFTER)] = AFTER
    data[STATE_BRANCH:STATE_BRANCH + 4] = branch(STATE_BRANCH, STUB_OFFSET)
    data[STUB_OFFSET:STUB_OFFSET + len(stub)] = stub
    if preserve_path_driver:
        data[DRIVER_BRANCH:DRIVER_BRANCH + 4] = branch(DRIVER_BRANCH, DRIVER_STUB)
        data[DRIVER_STUB:DRIVER_STUB + len(driver_stub)] = driver_stub
    destination.write_bytes(data)
    offsets = [OFFSET, STATE_BRANCH, STUB_OFFSET]
    if preserve_path_driver:
        offsets += [DRIVER_BRANCH, DRIVER_STUB]
    return {'offsets': [hex(offset) for offset in offsets],
            'instruction_bytes_replaced': len(AFTER) + 4 + len(stub) + (4 + len(driver_stub) if preserve_path_driver else 0),
            'preserve_original_path_driver': preserve_path_driver,
            'sha256': hashlib.sha256(data).hexdigest(),
            'requires_resigning': True, 'offline_ai_race_verified': False}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source')
    parser.add_argument('destination')
    parser.add_argument('--preserve-path-driver', action='store_true')
    args = parser.parse_args()
    print(json.dumps(patch(args.source, args.destination, args.preserve_path_driver), indent=2))
