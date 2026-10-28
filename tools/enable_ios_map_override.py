"""Restore command-line map selection in a verified local iOS 2.71.1 copy.

This is a diagnostic patch, not a complete offline-game patch. It changes the
pointer saved for FParse::Token after FCommandLine::Get; it preserves the empty
string used by the surrounding fallback paths. Re-sign the independent copy
afterward. The original preserved executable must remain unchanged.
"""
import argparse
import hashlib
import json
import struct
from pathlib import Path

FUNCTION_START = 0x59D4318
FUNCTION_END = 0x59D5604
FUNCTION_SHA256 = "47134d705bcaf459045d5bb1a08e373489c66f934cd2debe4118aff6ba7ab231"
PATCH_OFFSET = 0x59D4384
BEFORE = 0xA91A57FF  # stp xzr, x21, [sp, #0x1a0]
AFTER = BEFORE & ~(31 << 10)  # stp xzr, x0, [sp, #0x1a0]


def patch(source, destination):
    source, destination = Path(source), Path(destination)
    if source.resolve() == destination.resolve():
        raise ValueError("Use a different output path; preserve the input")
    data = bytearray(source.read_bytes())
    if data[:4] != b"\xcf\xfa\xed\xfe":
        raise ValueError("Expected a thin 64-bit little-endian Mach-O")
    digest = hashlib.sha256(data[FUNCTION_START:FUNCTION_END]).hexdigest()
    if digest != FUNCTION_SHA256:
        raise ValueError("Startup function differs from the verified iOS 2.71.1 build")
    if struct.unpack_from("<I", data, PATCH_OFFSET)[0] != BEFORE:
        raise ValueError("Unexpected instruction")
    struct.pack_into("<I", data, PATCH_OFFSET, AFTER)
    destination.write_bytes(data)
    return {"offset": hex(PATCH_OFFSET), "bytes_changed": 4,
            "sha256": hashlib.sha256(data).hexdigest(),
            "requires_resigning": True, "offline_gameplay_verified": False}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source")
    parser.add_argument("destination")
    args = parser.parse_args()
    print(json.dumps(patch(args.source, args.destination), indent=2))
