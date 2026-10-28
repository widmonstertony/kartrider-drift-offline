"""Route the original result Exit button to original local map travel.

For the preserved iOS 2.71.1 build only. With no NetDriver, reuse the current
world's name and relative travel to preserve the current race URL options.
Connected worlds retain the original lobby handler. The button still says
Exit; this is an experimental replay route, not a finished mode-selection UI.
"""
import argparse
import hashlib
import json
import struct
from pathlib import Path
from enable_ios_local_results import branch

START, END = 0x304C21C, 0x304C3A0
DIGEST = '42e05ce7a1d2b04dca989494c24784c6346038f3eb04e02b80a8f35050c49286'
OPEN, OPEN_END = 0x59ECFD0, 0x59ED258
OPEN_DIGEST = '206e7feeaf79462fa5250ce1e58fd0d49f15227d2fc51288759d1869c5ac1ed8'
OFFSET, CAVE, ORIGINAL, EPILOGUE = 0x304C240, 0x3100, 0x2E785E0, 0x304C38C


def patch(source, destination):
    source, destination = Path(source), Path(destination)
    if source.resolve() == destination.resolve():
        raise ValueError('Use a separate output; preserve the input')
    data = bytearray(source.read_bytes())
    if data[:4] != b'\xcf\xfa\xed\xfe':
        raise ValueError('Expected a thin ARM64 Mach-O')
    for start, end, digest in [(START, END, DIGEST), (OPEN, OPEN_END, OPEN_DIGEST)]:
        if hashlib.sha256(data[start:end]).hexdigest() != digest:
            raise ValueError('Original result/travel function differs from the verified build')
    if data[OFFSET:OFFSET+4] != branch(OFFSET, ORIGINAL, True):
        raise ValueError('Unexpected original lobby call')
    # x0 is the world returned by the original widget's GetWorld. Its parent
    # frame saved LR and registers and has a 16-byte scratch FString at sp+0x10.
    # The final two instructions preserve the displaced call for network worlds.
    stub = (struct.pack('<III', 0xB4000120, 0xF9401C08, 0xB50000E8) +
            struct.pack('<IIII', 0xF9400C01, 0x52800002, 0xA9017FFF, 0x910043E3) +
            branch(CAVE+28, OPEN, True) + branch(CAVE+32, EPILOGUE) +
            branch(CAVE+36, ORIGINAL, True) + branch(CAVE+40, OFFSET+4))
    if 32+struct.unpack_from('<I', data, 20)[0] > CAVE or any(data[CAVE:CAVE+len(stub)]):
        raise ValueError('Required unused header padding is unavailable')
    position, valid = 32, False
    for _ in range(struct.unpack_from('<I', data, 16)[0]):
        command, size = struct.unpack_from('<II', data, position)
        if command == 0x19 and data[position+8:position+24].rstrip(b'\0') == b'__TEXT':
            vm, _, off, _, _, prot, sections, _ = struct.unpack_from('<QQQQiiII', data, position+24)
            first = struct.unpack_from('<I', data, position+72+48)[0]
            valid = vm == 0x100000000 and off == 0 and prot == 5 and sections > 0 and first == 0x6f00 and CAVE+len(stub) <= first
        position += size
    if not valid:
        raise ValueError('Unexpected executable segment layout')
    data[OFFSET:OFFSET+4] = branch(OFFSET, CAVE)
    data[CAVE:CAVE+len(stub)] = stub
    destination.write_bytes(data)
    return {'offsets': [hex(OFFSET), hex(CAVE)], 'requires_resigning': True,
            'requires_device_verification': True, 'sha256': hashlib.sha256(data).hexdigest()}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source')
    parser.add_argument('destination')
    args = parser.parse_args()
    print(json.dumps(patch(args.source, args.destination), indent=2))
