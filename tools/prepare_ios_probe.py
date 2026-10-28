"""Prepare an independently identified diagnostic copy; never edit the original app."""
import argparse
import plistlib
import shutil
import struct
import subprocess
from pathlib import Path

parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--enable-commandline-map',action='store_true',help='Apply the verified 2.71.1 startup pointer patch; offline play remains unverified')
parser.add_argument('--restore-preserved-metadata',action='store_true',help='Include small retained PUB version files for restoration inside the test app sandbox')
args=parser.parse_args()
ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'runtime/ios-probe-patch'
OUT.mkdir(parents=True,exist_ok=True)
BUNDLE='org.kartdrift.preservation.offline'
p=plistlib.loads((ROOT/'analysis/ios-Info.plist').read_bytes())
p['CFBundleIdentifier']=BUNDLE
p['CFBundleDisplayName']='漂移离线测试'
p['CFBundleName']='KartDrift Offline Probe'
p.pop('CFBundleURLTypes',None)
with (OUT/'Info.plist').open('wb') as f:plistlib.dump(p,f)
binary=bytearray((ROOT/'analysis/KartDrift-ios-decrypted').read_bytes())
name=b'@executable_path/Frameworks/OfflineProbe.dylib\0'
size=(24+len(name)+7)//8*8
cmd=struct.pack('<IIIIII',0xc,size,24,0,0,0)+name
cmd=cmd.ljust(size,b'\0')
ncmds,sizeofcmds=struct.unpack_from('<II',binary,16)
end=32+sizeofcmds
assert not any(binary[end:end+len(cmd)]),'No header padding available'
binary[end:end+len(cmd)]=cmd
struct.pack_into('<II',binary,16,ncmds+1,sizeofcmds+len(cmd))
(OUT/'KartDrift').write_bytes(binary)
if args.enable_commandline_map:
    from enable_ios_map_override import patch
    patch(OUT/'KartDrift',OUT/'KartDrift-map')
    (OUT/'KartDrift-map').replace(OUT/'KartDrift')
ent={'application-identifier':BUNDLE,'get-task-allow':True}
with (OUT/'entitlements.plist').open('wb') as f:plistlib.dump(ent,f)
subprocess.run(['ldid','-S'+str(OUT/'entitlements.plist'),str(OUT/'KartDrift')],check=True)
(OUT/'ue4commandline.txt').write_text('../../../KartDrift/KartDrift.uproject /Game/ART/Env/Stage_License/License_T01/License_T01?game=/Script/KartDrift.LicenseGameMode?License=L00?players=1 -NoSplash -log -stdout -FullStdOutLogOutput ')
shutil.copy2(ROOT/'tools/OfflineProbe.dylib',OUT/'OfflineProbe.dylib')
frameworks=ROOT/'runtime/ios-original/KartDrift.app/Frameworks'
for source in frameworks.rglob('*'):
    if not source.is_file():continue
    with source.open('rb') as f:magic=f.read(4)
    if magic not in (b'\xcf\xfa\xed\xfe',b'\xca\xfe\xba\xbe',b'\xca\xfe\xba\xbf'):continue
    rel=source.relative_to(frameworks)
    dest=OUT/'Frameworks'/rel;dest.parent.mkdir(parents=True,exist_ok=True)
    shutil.copy2(source,dest)
    subprocess.run(['ldid','-S',str(dest)],check=True)
if args.restore_preserved_metadata:
    data=ROOT/'runtime/ios-preserved-data'
    metadata=list((data/'Library/Application Support/PUB/Patch').glob('*'))
    metadata += [data/'Library/Application Support/PUB/Resource/res_ver',data/'Library/Application Support/PUB/Resource/pb_patch_version']
    for source in metadata:
        if source.is_file() and source.stat().st_size<500000:
            destination=OUT/'OfflineMetadata'/source.relative_to(data)
            destination.parent.mkdir(parents=True,exist_ok=True)
            shutil.copy2(source,destination)
shutil.make_archive(str(ROOT/'runtime/ios-probe-patch'),'zip',OUT)
print(ROOT/'runtime/ios-probe-patch.zip')
