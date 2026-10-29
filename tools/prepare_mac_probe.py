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
    parser.add_argument('--unlock-local-catalog', action='store_true', help='Grant every retained original item definition locally; requires local profile initialization')
    parser.add_argument('--bundle-id', default='org.kartdrift.preservation.mac', help='Independent diagnostic app identity')
    parser.add_argument('--display-name', default='漂移离线 Mac 测试')
    parser.add_argument('--chunks', default='1,2,3,4,6,8,10,11,13,14,18,41')
    parser.add_argument('--enable-local-garage', action='store_true', help='Compile experimental local preset saves; requires the patched original garage entries')
    parser.add_argument('--enable-local-match-entry', action='store_true', help='Experimental original Play/Exit routing; requires the matching patched input and local garage')
    parser.add_argument('--enable-local-race-equipment', action='store_true', help='Require the matching saved race-equipment patch')
    parser.add_argument('--enable-local-upgrades', action='store_true', help='Experimental original modification unlock and persistence')
    parser.add_argument('--enable-local-tracks', action='store_true', help='Original track availability, selection persistence and selected-map AI races')
    parser.add_argument('--enable-local-teams', action='store_true', help='Balanced original 2v2/4v4 AI teams and native team results')
    parser.add_argument('--enable-local-liveries', action='store_true', help='Persistent local custom designs using original codec and caches')
    parser.add_argument('--enable-local-keyboard', action='store_true', help='Attach hardware keyboards and extended gamepads to the native input queue, including late connections')
    args = parser.parse_args()
    if args.enable_local_garage and not args.initialize_local_profile:
        parser.error('--enable-local-garage requires --initialize-local-profile')
    if args.enable_local_match_entry and not args.enable_local_garage:
        parser.error('--enable-local-match-entry requires --enable-local-garage')
    if args.enable_local_race_equipment and not args.enable_local_match_entry:
        parser.error('--enable-local-race-equipment requires --enable-local-match-entry')
    if args.enable_local_upgrades and (not args.enable_local_race_equipment or not args.unlock_local_catalog):
        parser.error('--enable-local-upgrades requires local race equipment and full local catalog')
    if args.enable_local_tracks and not args.enable_local_upgrades:
        parser.error('--enable-local-tracks requires --enable-local-upgrades')
    if args.enable_local_teams and not args.enable_local_tracks:
        parser.error('--enable-local-teams requires --enable-local-tracks')
    if args.enable_local_liveries and not args.enable_local_tracks:
        parser.error('--enable-local-liveries requires --enable-local-tracks')
    if args.enable_local_keyboard and not args.initialize_local_profile:
        parser.error('--enable-local-keyboard requires --initialize-local-profile')
    if args.unlock_local_catalog and not args.initialize_local_profile:
        parser.error('--unlock-local-catalog requires --initialize-local-profile')
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
    if args.enable_local_garage:
        from enable_ios_local_results import branch
        main_binary=(args.patch/'KartDrift').read_bytes()
        for entry,cave in [(0x2D61CB8,0x3200),(0x2D61E60,0x3300)]:
            if main_binary[entry:entry+4]!=branch(entry,cave):
                parser.error('--enable-local-garage requires matching patched original garage entries')
    if args.enable_local_match_entry:
        for entry,cave in [(0x2D72188,0x3400),(0x304C240,0x3500)]:
            if main_binary[entry:entry+4]!=branch(entry,cave):
                parser.error('--enable-local-match-entry requires matching original Play/Exit patches')
    if args.enable_local_race_equipment:
        for entry,cave in [(0x26B16F0,0x3800),(0x259B388,0x3900)]:
            if main_binary[entry:entry+4]!=branch(entry,cave):
                parser.error('--enable-local-race-equipment requires matching original equipment patches')
    if args.enable_local_upgrades:
        for entry,cave in [(0x2E26CAC,0x3C00),(0x2E27098,0x3D00),(0x2B1F18C,0x4000)]:
            if main_binary[entry:entry+4]!=branch(entry,cave,entry==0x2B1F18C):
                parser.error('--enable-local-upgrades requires matching original modification patches')
    if args.enable_local_tracks:
        for entry,cave in [(0x2DDBFC8,0x3E00),(0x2DDBE6C,0x3F00),(0x2DDC954,0x4100),(0x2E251AC,0x4200)]:
            if main_binary[entry:entry+4]!=branch(entry,cave):
                parser.error('--enable-local-tracks requires matching original track patches')
    if args.enable_local_teams:
        if main_binary[0x2B1EFC4:0x2B1EFC8]!=branch(0x2B1EFC4,0x4300):
            parser.error('--enable-local-teams requires the matching original team bridge')
    if args.enable_local_liveries:
        for entry,cave in [(0x2E294E8,0x4400),(0x2E29AA0,0x4500),(0x2E2A128,0x4600)]:
            if main_binary[entry:entry+4]!=branch(entry,cave):
                parser.error('--enable-local-liveries requires the matching custom-design bridges')
    if args.enable_local_keyboard:
        from enable_ios_local_results import branch
        keyboard_binary=(args.patch/'KartDrift').read_bytes()
        for entry,cave in [(0x4072F78,0x4700),(0x4077E44,0x4800)]:
            if keyboard_binary[entry:entry+4]!=branch(entry,cave):
                parser.error('--enable-local-keyboard requires matching native input bridges')
    if args.enable_local_tracks:
        from enable_ios_local_results import branch
        for entry,cave in [(0x25946D8,0x4A00),(0x2E849A8,0x4C00)]:
            if main_binary[entry:entry+4]!=branch(entry,cave):
                parser.error('--enable-local-tracks requires matching camera/loading bridges')
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
            *(['-DOFFLINE_LOCAL_SAVES'] if args.enable_local_garage else []),
            *(['-DOFFLINE_LOCAL_UPGRADES'] if args.enable_local_upgrades else []),
            *(['-DOFFLINE_LOCAL_TRACKS','-DOFFLINE_LOBBY_CONTROLS'] if args.enable_local_tracks else []),
            *(['-DOFFLINE_LOCAL_LIVERIES'] if args.enable_local_liveries else []),
            *(['-DOFFLINE_LOCAL_KEYBOARD'] if args.enable_local_keyboard else []),
            *(['-DOFFLINE_LOCAL_TEAMS'] if args.enable_local_teams else []),
            *(['-DOFFLINE_LOCAL_MATCH'] if args.enable_local_match_entry else []),
            *(['-DOFFLINE_LOCAL_PROFILE'] if args.initialize_local_profile else []),
            *(['-DOFFLINE_UNLOCK_LOCAL_CATALOG'] if args.unlock_local_catalog else []),
            '-framework', 'Foundation', '-framework', 'UIKit', '-framework', 'CoreGraphics', '-framework', 'GameController',
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
        probe_stubs = data[0x3000:0x4D00] if path == args.output/'KartDrift' else None
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
            converted_data[0x3000:0x4D00] = probe_stubs
            path.write_bytes(converted_data)
        run('codesign', '--force', '--sign', '-', str(path))
        if probe_stubs is not None and path.read_bytes()[0x3000:0x4D00] != probe_stubs:
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
