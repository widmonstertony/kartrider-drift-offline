"""Build an independently identified rootless test app using retained resources.

For the owner's jailbroken test device, with dpkg-deb and uicache already
installed. Does not install the package, alter the original app, or fetch deps.
All inputs and output stay inside the owner's MCP upload cache.
"""
import argparse
import json
import re
import shlex
from pathlib import PurePosixPath
from ios_mcp import call


def cached(value):
    path=PurePosixPath(value)
    root=PurePosixPath('/var/mobile/Library/Caches/ios-mcp-uploads')
    if '..' in path.parts or path==root or not path.is_relative_to(root):
        raise ValueError('Use a child of the MCP upload cache')
    return path


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app',required=True,help='Assembled independent .app with all retained resources, in the upload cache')
    parser.add_argument('--patch-zip',required=True,help='Uploaded independently signed patch ZIP')
    parser.add_argument('--work',required=True,help='New build directory in the upload cache')
    parser.add_argument('--code-only',action='store_true',help='Small code update for the already installed retained-resource test package')
    parser.add_argument('--version', help='Numeric diagnostic package version')
    args=parser.parse_args()
    if args.version and not re.fullmatch(r'[0-9]+(?:\.[0-9]+){1,3}',args.version):
        parser.error('Use a numeric diagnostic package version')
    app,patch,work=map(cached,(args.app,args.patch_zip,args.work))
    if app.suffix!='.app':parser.error('Expected an assembled independent .app')
    destination='var/jb/Applications/KartDriftOfflineLocal.app'
    package='org.kartdrift.preservation.localpatch' if args.code_only else 'org.kartdrift.preservation.localtest'
    dependencies='Depends: org.kartdrift.preservation.localtest (>= 0.24.0)\nReplaces: org.kartdrift.preservation.localtest\n' if args.code_only else ''
    control=f'''Package: {package}
Name: KartDrift Local Resource Test
Version: {args.version or ('0.25.0' if args.code_only else '0.24.0')}
Architecture: iphoneos-arm64
Maintainer: Local preservation build
Section: Games
{dependencies}Description: Independent original-client local resource, garage and save test.
 This is a diagnostic package, not a completed offline game.
'''
    postinst='''#!/bin/sh
set -e
if [ "$1" = configure ]; then
    /var/jb/usr/bin/uicache -p /var/jb/Applications/KartDriftOfflineLocal.app
fi
'''
    q=shlex.quote
    script=f'''set -e
test ! -e {q(str(work))}
mkdir -p {q(str(work))}
cd {q(str(work))}
unzip -oq {q(str(patch))} -d patch
mkdir -p stage/var/jb/Applications stage/DEBIAN
{('mkdir -p stage/'+destination+'/Frameworks') if args.code_only else ('cp -al '+q(str(app))+' stage/'+destination)}
for file in KartDrift Info.plist ue4commandline.txt; do
    rm -f stage/{destination}/"$file"
    cp patch/"$file" stage/{destination}/"$file"
done
rm -f stage/{destination}/Frameworks/OfflineProbe.dylib
cp patch/OfflineProbe.dylib stage/{destination}/Frameworks/OfflineProbe.dylib
chmod 755 stage/{destination}/KartDrift
# Downloaded resources can be mode 0600. The archive normalizes ownership to
# root; retain app-process readability before creating it. This staging tree
# shares only our upload-cache copies, never the original installed resources.
if [ -d stage/{destination}/cookeddata ]; then
    find stage/{destination}/cookeddata -type d -exec chmod a+rx {{}} +
    find stage/{destination}/cookeddata -type f -exec chmod a+r {{}} +
fi
printf %s {q(control)} > stage/DEBIAN/control
printf %s {q(postinst)} > stage/DEBIAN/postinst
chmod 755 stage/DEBIAN/postinst
dpkg-deb --build --root-owner-group -Zgzip -z1 stage offline-local-resources.deb
wc -c offline-local-resources.deb
echo DEB_READY
'''
    # A hard-linked staging tree avoids another multi-gigabyte resource copy.
    # Patched files are unlinked before replacement; retained inputs are kept.
    command='nohup sh -c '+q(script)+' >'+q(str(work)+'.build.log')+' 2>&1 </dev/null & echo $!'
    result=call('run_command',{'command':command,'timeout':10})
    data=result.get('result',result)
    if result.get('error') or data.get('isError'):
        raise RuntimeError('Device rejected package preparation')
    print(json.dumps({'package':str(work/'offline-local-resources.deb'),
                      'build_log':str(work)+'.build.log','code_only':args.code_only,'installed':False},indent=2))


if __name__=='__main__':main()
