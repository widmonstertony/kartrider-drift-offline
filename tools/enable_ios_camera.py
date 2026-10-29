"""Connect the retained loading widget and Drive camera to local callbacks.

Only the hash-identified ARM64 iOS 2.71.1 executable is accepted. The bridges
call first-party dylib exports after the original engine functions; they do not
embed camera logic or assets in the retained executable.
"""
import argparse
import hashlib
from pathlib import Path

from enable_ios_local_match import assemble
from enable_ios_local_results import branch

CAMERA_ENTRY, CAMERA_WRAPPER, CAMERA_TRAMPOLINE = 0x25946D8, 0x4A00, 0x4B00
LOADING_SITE, LOADING_WRAPPER = 0x2E849A8, 0x4C00
DLSYM = 0x65B2448


def camera_wrapper():
    return assemble(r'''
stp x20, x19, [sp, #-0x30]!
str x30, [sp, #0x10]
str d8, [sp, #0x18]
mov x20, x0
mov x19, x1
fmov s8, s0
bl .
mov x0, #-2
adr x1, symbol
bl .
cbz x0, done
mov x16, x0
mov x0, x20
mov x1, x19
fmov s0, s8
blr x16
done:
ldr d8, [sp, #0x18]
ldr x30, [sp, #0x10]
ldp x20, x19, [sp], #0x30
ret
symbol:
.asciz "offline_camera_view"
.p2align 2
''', CAMERA_WRAPPER, [CAMERA_TRAMPOLINE, DLSYM], [])


def camera_trampoline():
    # Relocate the overwritten stack-frame instruction, then continue through
    # the complete original camera function. Its RET returns to our wrapper.
    return assemble('''
stp d9, d8, [sp, #-0x40]!
b .
''', CAMERA_TRAMPOLINE, [], [CAMERA_ENTRY + 4])


def loading_wrapper():
    return assemble(r'''
stp x20, x19, [sp, #-0x20]!
str x30, [sp, #0x10]
mov x0, #-2
adr x1, symbol
bl .
cbz x0, done
mov x16, x0
mov x0, x20
blr x16
done:
ldr x30, [sp, #0x10]
ldp x20, x19, [sp], #0x20
ldrb w9, [x19, #0x2f0]
b .
symbol:
.asciz "offline_loading_widget"
.p2align 2
''', LOADING_WRAPPER, [DLSYM], [LOADING_SITE + 4])


def patch(source, destination):
    source, destination = Path(source), Path(destination)
    if source.resolve() == destination.resolve():
        raise ValueError('Use a separate output; preserve the input')
    data = bytearray(source.read_bytes())
    checks = (
        (CAMERA_ENTRY, CAMERA_ENTRY + 0x200, '54ecd9f7bd6cab7583e63379a4d20edd32c55b475611fd0593004cb5fddcef89'),
        (LOADING_SITE, LOADING_SITE + 4, '50bc78242b87741c1b7ea62a63e0cef2ebd363f30d03fa2e8dd412405796ed15'),
    )
    for start, end, digest in checks:
        if hashlib.sha256(data[start:end]).hexdigest() != digest:
            raise ValueError('Retained camera/loading functions differ from supported iOS 2.71.1')
    bridges = ((CAMERA_WRAPPER, camera_wrapper()),
               (CAMERA_TRAMPOLINE, camera_trampoline()),
               (LOADING_WRAPPER, loading_wrapper()))
    for offset, code in bridges:
        if len(code) > 0x100 or any(data[offset:offset + len(code)]):
            raise ValueError('Required executable bridge padding is unavailable')
    data[CAMERA_ENTRY:CAMERA_ENTRY + 4] = branch(CAMERA_ENTRY, CAMERA_WRAPPER)
    data[LOADING_SITE:LOADING_SITE + 4] = branch(LOADING_SITE, LOADING_WRAPPER)
    for offset, code in bridges:
        data[offset:offset + len(code)] = code
    destination.write_bytes(data)
    return {'first_person_bridge': True, 'selected_loading_background_bridge': True,
            'sha256': hashlib.sha256(data).hexdigest(), 'requires_resigning': True}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source')
    parser.add_argument('destination')
    args = parser.parse_args()
    print(patch(args.source, args.destination))
