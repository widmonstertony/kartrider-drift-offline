"""Start original table loading before direct offline map travel (iOS 2.71.1).

The normal lobby initializes UTableManager; direct map travel bypasses it.
This diagnostic patch calls the original asynchronous InitializeTables with
no world and without forcing reload, before the original map startup resumes.
All data and probabilities come from the retained original DataTables.
"""
import argparse
import hashlib
import json
import struct
from pathlib import Path

START, END = 0x59D4318, 0x59D5604
START_SHA = '47134d705bcaf459045d5bb1a08e373489c66f934cd2debe4118aff6ba7ab231'
OFFSET, CAVE = 0x59D433C, 0x30C0
GET_MANAGER, INITIALIZE = 0x24B7C98, 0x24B7DD0
CHECKS = ((GET_MANAGER, 0x24B7D24,
           '59e91945f2e7a86dc753d1f1e1275e294b479ce90ae1e407eab5f5ce175e5e12'),
          (INITIALIZE, 0x24B8300,
           'edfd0534a3e0509de8c10e93dca4423aea5b6af09390f7e6f1259d9bca1674da'))


def branch(source, target, link=False):
    delta = target - source
    if delta % 4 or not -(1 << 27) <= delta < (1 << 27):
        raise ValueError('ARM64 branch target out of range')
    return struct.pack('<I', (0x94000000 if link else 0x14000000) | ((delta // 4) & 0x3ffffff))


def patch(source, destination):
    source, destination = Path(source), Path(destination)
    if source.resolve() == destination.resolve():
        raise ValueError('Use a separate output; preserve the input')
    data = bytearray(source.read_bytes())
    if data[:4] != b'\xcf\xfa\xed\xfe':
        raise ValueError('Expected a thin ARM64 Mach-O')
    startup = bytearray(data[START:END])
    # Accept either the original startup or the separately verified map-pointer
    # patch. Normalize only that exact instruction for the function hash check.
    at = 0x59D4384 - START
    original, map_override = bytes.fromhex('ff571aa9'), bytes.fromhex('ff031aa9')
    if startup[at:at+4] == map_override:
        startup[at:at+4] = original
    if hashlib.sha256(startup).hexdigest() != START_SHA:
        raise ValueError('Startup function differs from the verified build')
    for start, end, digest in CHECKS:
        if hashlib.sha256(data[start:end]).hexdigest() != digest:
            raise ValueError('Original table-manager function differs from the verified build')
    if 32 + struct.unpack_from('<I', data, 20)[0] > CAVE or any(data[CAVE:CAVE+32]):
        raise ValueError('Required unused header padding is unavailable')
    position, valid_text = 32, False
    for _ in range(struct.unpack_from('<I', data, 16)[0]):
        command, size = struct.unpack_from('<II', data, position)
        if command == 0x19 and data[position+8:position+24].rstrip(b'\0') == b'__TEXT':
            vm, _, off, _, _, protection, sections, _ = struct.unpack_from('<QQQQiiII', data, position+24)
            first = struct.unpack_from('<I', data, position+72+48)[0]
            valid_text = (vm == 0x100000000 and off == 0 and protection == 5
                          and sections > 0 and first == 0x6f00 and CAVE+32 <= first)
        position += size
    if not valid_text:
        raise ValueError('Unexpected executable segment layout')
    # x19 already holds the game instance and LR is saved by the containing
    # function. Restore x0 and re-emit the displaced stack-canary page lookup.
    pages = (0x107647000 - ((0x100000000+CAVE+24) & ~4095)) // 4096
    adrp = 0x90000008 | ((pages & 3) << 29) | (((pages >> 2) & 0x7ffff) << 5)
    stub = (branch(CAVE, GET_MANAGER, True) +
            struct.pack('<III', 0xB4000080, 0xAA1F03E1, 0x52800002) +
            branch(CAVE+16, INITIALIZE, True) +
            struct.pack('<II', 0xAA1303E0, adrp) +
            branch(CAVE+28, OFFSET+4))
    data[OFFSET:OFFSET+4] = branch(OFFSET,CAVE)
    data[CAVE:CAVE+len(stub)] = stub
    destination.write_bytes(data)
    return {'offsets': [hex(OFFSET),hex(CAVE)], 'original_async_table_loader': hex(0x100000000+INITIALIZE),
            'requires_resigning': True, 'requires_device_verification': True,
            'sha256': hashlib.sha256(data).hexdigest()}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source')
    parser.add_argument('destination')
    args = parser.parse_args()
    print(json.dumps(patch(args.source,args.destination),indent=2))
