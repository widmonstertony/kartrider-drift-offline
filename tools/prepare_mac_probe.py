"""Build a separate Mac Catalyst diagnostic copy of the retained iOS app.

Uses Apple's lipo, vtool and codesign. It retains the original ARM64 game and
resources; this does not reimplement or emulate its engine. Runtime compatibility
must be verified separately. Never overwrites an existing destination.
"""
import argparse
import json
import plistlib
import re
import shutil
import struct
import subprocess
from pathlib import Path


def run(*args):
    return subprocess.run(args, check=True, capture_output=True, text=True).stdout


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--original-app', type=Path, required=True)
    parser.add_argument('--patch', type=Path, required=True)
    parser.add_argument('--resources', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--probe-dylib', type=Path, help='Optional separately compiled Catalyst diagnostic library')
    parser.add_argument('--enable-local-menu', action='store_true', help='Require the matching automatic result-factory patch')
    parser.add_argument('--initialize-local-profile', action='store_true', help='Experimental original initial inventory/equipment; no persistent saving')
    parser.add_argument('--bundle-id', default='org.kartdrift.preservation.mac', help='Independent diagnostic app identity')
    parser.add_argument('--display-name', default='漂移离线 Mac 测试')
    parser.add_argument('--chunks', default='1,2,3,4,6,8,10,11,13,14,18,41')
    args = parser.parse_args()
    if not re.fullmatch(r'[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+',args.bundle_id):
        parser.error('Invalid diagnostic bundle identifier')
    if args.output.exists() or args.output.suffix != '.app':
        parser.error('Output must be a new .app directory')
    chunks = [int(x) for x in args.chunks.split(',')]
    if any(x < 1 or x > 999 for x in chunks):
        parser.error('Invalid resource chunk')
    for source in [args.original_app/'Info.plist', args.patch/'KartDrift', args.patch/'ue4commandline.txt']:
        if not source.is_file():
            parser.error('Required local input is missing: '+str(source))
    if args.initialize_local_profile and 'KartDrift.OutGameMode' not in (args.patch/'ue4commandline.txt').read_text():
        parser.error('--initialize-local-profile requires the original lobby probe')
    for chunk in chunks:
        if not (args.resources/f'pakchunk{chunk}-ios.pak').is_file():
            parser.error('Missing PAK for chunk '+str(chunk))
    shutil.copytree(args.original_app, args.output, symlinks=True)
    for name in ['KartDrift', 'Info.plist', 'ue4commandline.txt']:
        shutil.copy2(args.patch/name, args.output/name)
    probe = args.output/'Frameworks/OfflineProbe.dylib'
    if args.probe_dylib:
        shutil.copy2(args.probe_dylib, probe)
    else:
        sdk = Path(run('xcrun', '--sdk', 'macosx', '--show-sdk-path').strip())
        frameworks = str(sdk/'System/iOSSupport/System/Library/Frameworks')
        run('xcrun', '--sdk', 'macosx', 'clang', '-target', 'arm64-apple-ios15.0-macabi',
            '-dynamiclib', '-fobjc-arc', *(['-DOFFLINE_LOCAL_MENU'] if args.enable_local_menu else []), '-iframework', frameworks, '-F'+frameworks,
            *(['-DOFFLINE_LOCAL_PROFILE'] if args.initialize_local_profile else []),
            '-framework', 'Foundation', '-framework', 'UIKit', '-framework', 'CoreGraphics',
            str(Path(__file__).with_name('offline_probe.m')), '-o', str(probe))
    if (args.patch/'OfflineMetadata').exists():
        shutil.copytree(args.patch/'OfflineMetadata', args.output/'OfflineMetadata')
    content = args.output/'cookeddata/kartdrift/content'
    for chunk in chunks:
        shutil.copy2(args.resources/f'pakchunk{chunk}-ios.pak', content/'paks')
        for shader in args.resources.glob(f'kartdrift_chunk{chunk}_sf_metal.*.metallib'):
            shutil.copy2(shader, content/shader.name)
    for name in ['SC_Info', '_CodeSignature', 'embedded.mobileprovision']:
        target = args.output/name
        if target.is_dir():
            shutil.rmtree(target)
        elif target.exists():
            target.unlink()
    info = plistlib.loads((args.output/'Info.plist').read_bytes())
    info.update(CFBundleIdentifier=args.bundle_id, CFBundleDisplayName=args.display_name,
                CFBundleSupportedPlatforms=['MacOSX'], LSRequiresIPhoneOS=False,
                LSMinimumSystemVersion='11.0', MinimumOSVersion='11.0', UIDeviceFamily=[2],
                NSHighResolutionCapable=True)
    (args.output/'Info.plist').write_bytes(plistlib.dumps(info))
    binaries = []
    for path in args.output.rglob('*'):
        if not path.is_file() or path.is_symlink():
            continue
        with path.open('rb') as stream:
            magic = stream.read(4)
        if magic not in [b'\xcf\xfa\xed\xfe', b'\xca\xfe\xba\xbe', b'\xca\xfe\xba\xbf']:
            continue
        if magic != b'\xcf\xfa\xed\xfe':
            thinned = path.with_name(path.name+'.arm64')
            run('xcrun', 'lipo', str(path), '-thin', 'arm64', '-output', str(thinned))
            thinned.replace(path)
        data = path.read_bytes()
        # vtool/install_name_tool clear header padding. Our guarded iOS
        # patches use a small verified part of that padding for ARM64 stubs.
        # Preserve it after all load-command edits and before signing.
        probe_stubs = data[0x3000:0x3200] if path == args.output/'KartDrift' else None
        position = 32
        for _ in range(struct.unpack_from('<I', data, 16)[0]):
            command, size = struct.unpack_from('<II', data, position)
            if command == 0x2c and struct.unpack_from('<I', data, position+16)[0]:
                raise ValueError('Encrypted Mach-O remains: '+str(path))
            position += size
        converted = path.with_name(path.name+'.catalyst')
        run('xcrun', 'vtool', '-set-build-version', 'maccatalyst', '11.0', '14.0',
            '-replace', '-output', str(converted), str(path))
        converted.replace(path)
        path.chmod(0o755)
        libraries = run('xcrun', 'otool', '-L', str(path))
        if '@rpath/libswiftUIKit.dylib' in libraries:
            run('xcrun', 'install_name_tool', '-change', '@rpath/libswiftUIKit.dylib',
                '/System/iOSSupport/usr/lib/swift/libswiftUIKit.dylib', str(path))
        if probe_stubs is not None:
            converted_data = bytearray(path.read_bytes())
            if 32+struct.unpack_from('<I', converted_data, 20)[0] > 0x3000:
                raise ValueError('Converted load commands overlap probe stubs')
            converted_data[0x3000:0x3200] = probe_stubs
            path.write_bytes(converted_data)
        run('codesign', '--force', '--sign', '-', str(path))
        if probe_stubs is not None and path.read_bytes()[0x3000:0x3200] != probe_stubs:
            raise ValueError('Signing changed probe stubs')
        binaries.append(str(path.relative_to(args.output)))
    # Nested code is signed before the outer bundle; retain no mobile grants.
    for bundle in sorted(args.output.rglob('*.framework'), key=lambda x: len(x.parts), reverse=True):
        run('codesign', '--force', '--sign', '-', str(bundle))
    # A local app needs no network grants. Sandbox its saves/metadata in its
    # own container instead of the user's home, with outbound networking denied.
    entitlements = Path(__file__).with_name('mac_probe.entitlements.plist')
    run('codesign', '--force', '--sign', '-', '--entitlements', str(entitlements), str(args.output))
    run('codesign', '--verify', '--deep', '--strict', str(args.output))
    print(json.dumps({'app': str(args.output.resolve()), 'converted_binaries': binaries,
                      'runtime_verified': False}, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
