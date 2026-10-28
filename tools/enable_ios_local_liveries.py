"""Route isolated custom-design requests into local persistence and native caches.

Only the retained decrypted ARM64 2.71.1 layout is supported. Other accounts
retain their original code path. No original executable or art is distributed.
"""
import argparse
import hashlib
import json
from pathlib import Path
from enable_ios_local_match import assemble
from enable_ios_local_results import branch
from enable_ios_local_teams import validate_layout

BRIDGES=((0x2E294E8,0x4400,0,0xB0),(0x2E29AA0,0x4500,1,0xD0),(0x2E2A128,0x4600,2,0xD0))
CHECKS=(
 (0x2E294E8,0x2E29AA0,'fd4f38291a311b7254a8c103fd6387b3b46b9961a69d6dc7bc6cc98765cb908e'),
 (0x2E29AA0,0x2E2A128,'3c366326638430e4b2532f7541918bbdc5e76818de3daadc9966cf84aa2c1d7c'),
 (0x2E2A128,0x2E2A7B0,'3ead449645ff1a8adf59aebfaec90eed4fe3d970152c9e59a375af22571e9dfc'),
 (0x2DE698C,0x2DE6CD0,'000d57d9394ea03f8518282ab12ae5f224e4ac01eb8f64429bd3aa8455e705af'),
 (0x2E60A68,0x2E60A70,'2886d6862f05570eb818d848231da765fb5928655f17b51c25ca42eccaafebd1'),
 (0x2E69A38,0x2E69A40,'b9b8f2294a7ebd5846cad1b8cdbeaf677a9f9f16401516be8bbe0c3666cc697b'),
 (0x2F4C838,0x2F4CA50,'12a3ea237215be8a9989a463fdd90bae4045d8cf5c838293157c94a30e3fec07'),
 (0x2A28C94,0x2A28CD0,'6993f2ee9825d28e36e90c6c88482e8980ae3af467493c341edf069aed8eaeb9'),
)
def bridge(entry,cave,operation,frame):
    return assemble(f'''
ldrb w8, [x0, #0x1a0]
cmp w8, #1
b.ne original
ldr x8, [x0, #0xa30]
cbnz x8, original
stp x19, x30, [sp, #-0x40]!
stp x0, x1, [sp, #0x10]
stp x2, x3, [sp, #0x20]
mov x0, #-2
adr x1, symbol
bl .
cbz x0, finished
mov x16, x0
ldp x0, x1, [sp, #0x10]
ldp x2, x3, [sp, #0x20]
mov w4, #{operation}
blr x16
finished:
ldp x19, x30, [sp], #0x40
ret
original:
sub sp, sp, #{frame}
b .
symbol:
.asciz "offline_livery_request"
.p2align 2
''',cave,[0x65B2448],[entry+4])
def patch(source,destination):
    source,destination=Path(source),Path(destination)
    if source.resolve()==destination.resolve():raise ValueError('Preserve the input')
    data=bytearray(source.read_bytes())
    validate_layout(data)
    if data[0x2DDBFC8:0x2DDBFCC]!=branch(0x2DDBFC8,0x3E00):raise ValueError('Requires validated local track/profile layout')
    for a,z,digest in CHECKS:
        if hashlib.sha256(data[a:z]).hexdigest()!=digest:raise ValueError(f'Original livery functions differ at {a:x}')
    for entry,cave,operation,frame in BRIDGES:
        code=bridge(entry,cave,operation,frame)
        if len(code)>0x100 or any(data[cave:cave+0x100]):raise ValueError('Livery bridge padding unavailable')
        data[cave:cave+len(code)]=code;data[entry:entry+4]=branch(entry,cave)
    destination.write_bytes(data)
    return {'runtime_verified':False,'requires_resigning':True,'sha256':hashlib.sha256(data).hexdigest()}
if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('source');p.add_argument('destination');a=p.parse_args()
    print(json.dumps(patch(a.source,a.destination),indent=2))
