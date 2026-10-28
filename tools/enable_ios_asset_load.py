"""Diagnostic synchronous primary-asset loading in a verified iOS 2.71.1 copy.

The normal lookup only resolves already loaded objects. Redirect its existing
FSoftObjectPath::ResolveObject call to the original FSoftObjectPath::TryLoad.
Both functions and the call instruction are checked before changing four bytes.
This changes lookup behavior globally in the diagnostic copy and may introduce
loading stalls. It does not restore matchmaking, account state, or AI races.
"""
import argparse
import hashlib
import json
import struct
from pathlib import Path

RANGES = (
    (0x57B2784, 0x57B2860,
     'cb51e67b2e693a1f1be4d508954161223826f1fb7d83939690300bf561441edd'),
    (0x400070C, 0x400083C,
     '73cf030ef5832fa348278f07e389737e1864eaf22e3265049d4c9766bc99d530'),
)
CALL = 0x57B27F4
TRY_LOAD = 0x400070C
BEFORE = 0x97A13812
MESH_RANGE = (0x26A7C2C, 0x26A7F74,
              '4e441cdcad81858ce50d23a539aeb33dc305d5e565ea9e930229e1ea8830f033')
MESH_CALL = 0x26A7CC8
MESH_BEFORE = 0x946562DD


def patch(source, destination, load_kart_mesh=False):
    source, destination = Path(source), Path(destination)
    if source.resolve() == destination.resolve():
        raise ValueError('Use a separate output; preserve the input')
    data = bytearray(source.read_bytes())
    if data[:4] != b'\xcf\xfa\xed\xfe':
        raise ValueError('Expected a thin 64-bit little-endian Mach-O')
    ranges = RANGES + ((MESH_RANGE,) if load_kart_mesh else ())
    calls = [(CALL, BEFORE)]
    if load_kart_mesh:
        calls.append((MESH_CALL, MESH_BEFORE))
    for start, end, expected in ranges:
        if hashlib.sha256(data[start:end]).hexdigest() != expected:
            raise ValueError('Function differs from the verified iOS 2.71.1 build')
    for offset, before in calls:
        if struct.unpack_from('<I', data, offset)[0] != before:
            raise ValueError('Unexpected call instruction')
        delta = TRY_LOAD - offset
        if delta % 4 or not -(1 << 27) <= delta < (1 << 27):
            raise ValueError('Target outside ARM64 branch range')
        struct.pack_into('<I', data, offset, 0x94000000 | ((delta // 4) & 0x3ffffff))
    destination.write_bytes(data)
    return {'offsets': [hex(offset) for offset, _ in calls],
            'bytes_changed': 4 * len(calls),
            'sha256': hashlib.sha256(data).hexdigest(),
            'requires_resigning': True, 'offline_gameplay_verified': False}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source')
    parser.add_argument('destination')
    parser.add_argument('--load-kart-mesh', action='store_true',
                        help='Also redirect the original kart mesh application lookup')
    args = parser.parse_args()
    print(json.dumps(patch(args.source, args.destination, args.load_kart_mesh), indent=2))
