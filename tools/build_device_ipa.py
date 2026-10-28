"""Assemble an independent diagnostic IPA in the owner's iOS MCP upload cache."""
import argparse
import shlex
from pathlib import PurePosixPath
from ios_mcp import call

def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--original-app',required=True,help='Device path to the original KartDrift.app')
    p.add_argument('--resources',required=True,help='Device path to the retained PUB/Resource directory')
    p.add_argument('--patch-zip',required=True,help='Uploaded patch ZIP path returned by /upload_file')
    p.add_argument('--work',required=True,help='New directory inside the iOS MCP upload cache')
    p.add_argument('--chunks',default='1,2,3,11,14',help='Resource chunk numbers, separated by commas; chunk 11 contains common race/checkpoint assets')
    a=p.parse_args()
    work=PurePosixPath(a.work)
    allowed=PurePosixPath('/var/mobile/Library/Caches/ios-mcp-uploads')
    if '..' in work.parts or not work.is_relative_to(allowed) or work==allowed:
        p.error('--work must be a child of the iOS MCP upload cache')
    if not a.original_app.endswith('/KartDrift.app'):p.error('Expected the original KartDrift.app path')
    chunks=[int(s) for s in a.chunks.split(',')]
    if any(i<=0 or i>999 for i in chunks):p.error('Invalid chunk number')
    q=shlex.quote
    script=f'''set -e
test ! -e {q(str(work/'Payload'))}
mkdir -p {q(str(work))}
cd {q(str(work))}
mkdir Payload
cp -a {q(a.original_app)} Payload/KartDrift.app
unzip -oq {q(a.patch_zip)} -d patch
cp patch/KartDrift patch/Info.plist patch/ue4commandline.txt Payload/KartDrift.app/
cp patch/OfflineProbe.dylib Payload/KartDrift.app/Frameworks/
cp -R patch/Frameworks/. Payload/KartDrift.app/Frameworks/
if test -d patch/OfflineMetadata; then
    cp -R patch/OfflineMetadata Payload/KartDrift.app/
fi
chmod 755 Payload/KartDrift.app/KartDrift
rm -rf Payload/KartDrift.app/SC_Info Payload/KartDrift.app/_CodeSignature
'''
    for i in chunks:
        script+=f'cp {q(a.resources)}/pakchunk{i}-ios.pak Payload/KartDrift.app/cookeddata/kartdrift/content/paks/\n'
        script+=f'cp {q(a.resources)}/kartdrift_chunk{i}_sf_metal.*.metallib Payload/KartDrift.app/cookeddata/kartdrift/content/\n'
    script+='zip -q -0 -r offline-probe.ipa Payload\necho 0 > assemble.exit\n'
    command=f'mkdir -p {q(str(work))}; nohup sh -c {q(script)} > {q(str(work/"assemble.log"))} 2>&1 &'
    result=call('run_command',{'command':command,'timeout':10})
    if result.get('error') or result.get('result',{}).get('isError'):raise RuntimeError(str(result))
    print('Assembly started. Read assemble.log and assemble.exit in',str(work))
    print('Diagnostic IPA:',str(work/'offline-probe.ipa'))

if __name__=='__main__':main()
