"""Bind hardware keyboards connected before or after native input initialization."""
import argparse
import hashlib
import json
from pathlib import Path
from enable_ios_local_match import assemble
from enable_ios_local_results import branch
from enable_ios_local_teams import validate_layout

CHECKS = (
    (0x4072F78,0x4072FA0,'231092c76bb7545754838f53a6155c13b740cc49ecce333bf1eb77eb6c46234b'),
    (0x4077E44,0x4077E98,'dda29ace23c1e26ee1e00f3cb9131b6a075762eda33cdb86048835ef35047568'),
    (0x407373C,0x40737EC,'2ffa649069ba06bce3fcc3f74c1c8060d8389f1d2e3e46ae54f3cf5b366dd829'),
)
def bridge(site,cave,destroying):
    return assemble(f'''
stp x19, x30, [sp, #-0x20]!
{'mov x19, x0' if destroying else ''}
mov x0, #-2
adr x1, symbol
bl .
cbz x0, done
mov x16, x0
mov x0, x19
mov w1, #{int(destroying)}
blr x16
done:
mov x0, x19
ldp x19, x30, [sp], #0x20
{'stp x20, x19, [sp, #-0x20]!' if destroying else 'mov x0, x19'}
b .
symbol:
.asciz "offline_keyboard_interface"
.p2align 2
''',cave,[0x65B2448],[site+4])
def patch(source,destination):
    source,destination=Path(source),Path(destination)
    if source.resolve()==destination.resolve():raise ValueError('Preserve the input')
    data=bytearray(source.read_bytes())
    validate_layout(data)
    for a,z,digest in CHECKS:
        if hashlib.sha256(data[a:z]).hexdigest()!=digest:raise ValueError('Original input functions differ from retained build')
    for site,cave,destroying in [(0x4072F78,0x4700,False),(0x4077E44,0x4800,True)]:
        code=bridge(site,cave,destroying)
        if len(code)>0x100 or any(data[cave:cave+0x100]):raise ValueError('Input bridge padding unavailable')
        data[cave:cave+len(code)]=code;data[site:site+4]=branch(site,cave)
    destination.write_bytes(data)
    return {'runtime_verified':False,'requires_resigning':True,'sha256':hashlib.sha256(data).hexdigest()}
if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('source');p.add_argument('destination');a=p.parse_args()
    print(json.dumps(patch(a.source,a.destination),indent=2))
