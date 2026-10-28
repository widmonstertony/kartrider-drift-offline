"""Initialize the original debug account for an isolated local lobby probe.

For the retained iOS 2.71.1 executable only. The original lobby otherwise
redirects to LoginStage because its account object does not exist. Replace
its account lookup with an original CreateDebugAccount call in worlds with
no NetDriver, then initialize local state and the original iOS platform type.
Network worlds keep the original lookup and state. A missing server connection
skips the time refresh; a failed attendance-event request skips callback binding.
This does not implement profile, inventory,
saving, functional lobby widgets, or lobby-to-race navigation. Test only in
an independent copy; never apply to the preserved installation.
"""
import argparse
import hashlib
import json
import struct
from pathlib import Path
from enable_ios_local_results import branch


RANGES = (
    (0x2CC2414, 0x2CC294C, 'c15a08b3a0d20b5a4d9859d339a88c72140edc5e3391876e9b4c6b241c4bbe4a'),
    (0x2CC294C, 0x2CC33C8, '26c83de556e6b98e2a5e2494de8b9fa46ce6eda23d3f0b3e0a35c623c9ada991'),
    (0x2E78278, 0x2E7830C, 'ba56339c44e65b0aff6ca3cfd3bd05ab518cb4ef92a2109927af0e99a3d25305'),
    (0x2E745CC, 0x2E74660, '684cb645d9320e044bc8c4e1903cc0013089a59616cf5f0e7c53ffa80dfc0cac'),
    (0x2E379B4, 0x2E37AF0, '21a505c46438869db7835b0b7e2494c9821ffe1444cecf4db2397e67efd4e064'),
    (0x2D4CC64, 0x2D4CD74, '63283bd372031d1f048e77f9e8ff4d365b6179243850af3c1c7e5e60da762543'),
)
CALL, CAVE, GET_ACCOUNT, CREATE_DEBUG = 0x2CC246C, 0x3140, 0x2E745CC, 0x2E78278
TIME_CALL, TIME_CAVE = 0x2E379B4, 0x3080
ATTENDANCE_CALL, ATTENDANCE_CAVE = 0x2D4CCB8, 0x3098


def compare_zero(at, target, register=0, nonzero=False):
    delta = target-at
    if delta % 4 or not -(1 << 20) <= delta < (1 << 20):
        raise ValueError('Conditional target outside ARM64 range')
    return struct.pack('<I', (0xB5000000 if nonzero else 0xB4000000) |
                       (((delta//4) & 0x7FFFF) << 5) | register)


def patch(source, destination):
    source, destination = Path(source), Path(destination)
    if source.resolve() == destination.resolve():
        raise ValueError('Use a separate output; preserve the input')
    data = bytearray(source.read_bytes())
    if data[:4] != b'\xcf\xfa\xed\xfe' or struct.unpack_from('<I', data, 4)[0] != 0x100000C:
        raise ValueError('Expected a thin ARM64 Mach-O')
    for start, end, expected in RANGES:
        if hashlib.sha256(data[start:end]).hexdigest() != expected:
            raise ValueError('Original lobby/account function differs from verified 2.71.1')
    if data[CALL:CALL+4] != branch(CALL, GET_ACCOUNT, True):
        raise ValueError('Unexpected original account lookup')
    # x0 is the original actor's GetWorld result. Preserve the caller's
    # nonvolatile register/LR and the original account-state check afterward.
    # Verified chain: World+180 -> KdGameInstance+1b8 -> KdService+50 account.
    stub = (struct.pack('<II', 0xA9BF7BF3, 0xF9401C08) +
            compare_zero(CAVE+8, CAVE+56, 8, True) +
            struct.pack('<I', 0xF940C000) +
            compare_zero(CAVE+16, CAVE+48) +
            struct.pack('<I', 0xF940DC00) +
            compare_zero(CAVE+24, CAVE+48) +
            branch(CAVE+28, CREATE_DEBUG, True) +
            # The original creator itself dereferences and returns its account.
            # EKtPlatform::IOS=6; +550 selects the retained original mobile UI.
            struct.pack('<IIIIII', 0x52800028, 0x39060408, 0x528000C8, 0x39154008,
                        0xA8C17BF3, 0xD65F03C0) +
            branch(CAVE+56, GET_ACCOUNT, True) + branch(CAVE+60, CAVE+48))
    # Mainmenu BeginPlay refreshes server time even for the original debug
    # account. Without a ServerConnection it dereferences null. Retain the
    # original path when a connection exists; local profiles send no request.
    time_stub = (struct.pack('<I', 0xF9451808) +
                 compare_zero(TIME_CAVE+4, TIME_CAVE+16, 8) +
                 struct.pack('<I', 0xD10203FF) +
                 branch(TIME_CAVE+12, TIME_CALL+4) + struct.pack('<I', 0xD65F03C0))
    if data[TIME_CALL:TIME_CALL+4] != struct.pack('<I', 0xD10203FF):
        raise ValueError('Unexpected original server-time entry')
    # PqAttendanceEventInfo can return no packet in a disconnected account.
    # Skip its callback allocation/binding in that case, using the original
    # epilogue. A real packet keeps the original path. No response is fabricated.
    attendance_stub = (compare_zero(ATTENDANCE_CAVE, ATTENDANCE_CAVE+8, nonzero=True) +
                       branch(ATTENDANCE_CAVE+4, 0x2D4CD60) +
                       struct.pack('<I', 0xAA0003F4) +
                       branch(ATTENDANCE_CAVE+12, ATTENDANCE_CALL+4))
    if data[ATTENDANCE_CALL:ATTENDANCE_CALL+4] != struct.pack('<I', 0xAA0003F4):
        raise ValueError('Unexpected original attendance request result')
    if (32+struct.unpack_from('<I', data, 20)[0] > min(CAVE,TIME_CAVE) or
        any(data[CAVE:CAVE+len(stub)]) or any(data[TIME_CAVE:TIME_CAVE+len(time_stub)]) or
        any(data[ATTENDANCE_CAVE:ATTENDANCE_CAVE+len(attendance_stub)])):
        raise ValueError('Required unused header padding is unavailable')
    position, valid = 32, False
    for _ in range(struct.unpack_from('<I', data, 16)[0]):
        command, size = struct.unpack_from('<II', data, position)
        if command == 0x2C and struct.unpack_from('<I', data, position+16)[0]:
            raise ValueError('Encrypted executable; use the preserved decrypted copy')
        if command == 0x19 and data[position+8:position+24].rstrip(b'\0') == b'__TEXT':
            vm, _, off, _, _, prot, sections, _ = struct.unpack_from('<QQQQiiII', data, position+24)
            first = struct.unpack_from('<I', data, position+72+48)[0]
            valid = vm == 0x100000000 and off == 0 and prot == 5 and sections > 0 and first == 0x6F00 and CAVE+len(stub) <= first
        position += size
    if not valid:
        raise ValueError('Unexpected executable segment layout')
    data[CALL:CALL+4] = branch(CALL, CAVE, True)
    data[CAVE:CAVE+len(stub)] = stub
    data[TIME_CALL:TIME_CALL+4] = branch(TIME_CALL, TIME_CAVE)
    data[TIME_CAVE:TIME_CAVE+len(time_stub)] = time_stub
    data[ATTENDANCE_CALL:ATTENDANCE_CALL+4] = branch(ATTENDANCE_CALL, ATTENDANCE_CAVE)
    data[ATTENDANCE_CAVE:ATTENDANCE_CAVE+len(attendance_stub)] = attendance_stub
    destination.write_bytes(data)
    return {'offsets': [hex(CALL), hex(CAVE), hex(TIME_CALL), hex(TIME_CAVE),
                        hex(ATTENDANCE_CALL), hex(ATTENDANCE_CAVE)], 'requires_resigning': True,
            'diagnostic_only': True, 'functional_lobby_verified': False,
            'sha256': hashlib.sha256(data).hexdigest()}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source')
    parser.add_argument('destination')
    args = parser.parse_args()
    print(json.dumps(patch(args.source, args.destination), indent=2))
