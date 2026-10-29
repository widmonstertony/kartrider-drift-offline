"""Prepare an independently identified diagnostic copy; never edit the original app."""
import argparse
import plistlib
import re
import shutil
import struct
import subprocess
from pathlib import Path

parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--enable-commandline-map',action='store_true',help='Apply the verified 2.71.1 startup pointer patch; offline play remains unverified')
parser.add_argument('--restore-preserved-metadata',action='store_true',help='Include small retained PUB version files for restoration inside the test app sandbox')
parser.add_argument('--race-mode',choices=('training','speed','item'),default='training')
parser.add_argument('--map',help='Original /Game/... map path; defaults to License_T01 or Village_I01')
parser.add_argument('--players',type=int,default=1)
parser.add_argument('--ais',type=int,default=0)
parser.add_argument('--enable-asset-load',action='store_true')
parser.add_argument('--load-kart-mesh',action='store_true')
parser.add_argument('--enable-local-ai',action='store_true')
parser.add_argument('--preserve-ai-path-driver',action='store_true')
parser.add_argument('--restore-local-results',action='store_true')
parser.add_argument('--initialize-local-tables',action='store_true')
parser.add_argument('--enable-local-replay',action='store_true')
parser.add_argument('--enable-local-menu',action='store_true',help='Experimental local speed/item selection using original engine travel')
parser.add_argument('--lobby-probe',action='store_true',help='Diagnostic original lobby with local debug account; original UI/profile flow remains incomplete')
parser.add_argument('--initialize-local-profile',action='store_true',help='Experimental original initial inventory/equipment; does not implement saving')
parser.add_argument('--unlock-local-catalog', action='store_true', help='Grant every retained original item definition locally; requires local profile initialization')
parser.add_argument('--enable-local-garage', action='store_true', help='Experimental original local equipment updates and persistent preset save/restore')
parser.add_argument('--enable-local-match-entry', action='store_true', help='Experimental original Play to Village speed/item AI races and original Exit to lobby; requires local garage')
parser.add_argument('--enable-local-race-equipment', action='store_true', help='Load the saved local garage preset through original race descriptor functions')
parser.add_argument('--enable-local-upgrades', action='store_true', help='Experimental original modification grades, gear choices and local saves')
parser.add_argument('--enable-local-tracks', action='store_true', help='Original local track availability, selection persistence and selected-map AI races')
parser.add_argument('--enable-local-teams', action='store_true', help='Balanced original 2v2/4v4 AI teams and native team results')
parser.add_argument('--enable-local-liveries', action='store_true', help='Persistent local custom designs using original codec and caches')
parser.add_argument('--enable-local-keyboard', action='store_true', help='Attach hardware keyboards to the native input queue, including late connections')
parser.add_argument('--bundle-id', default='org.kartdrift.preservation.offline', help='Independent test app identity')
parser.add_argument('--display-name', default='漂移离线测试')
parser.add_argument('--system-app-container', action='store_true', help='Require an isolated container when installing the test app as a rootless DEB')
args=parser.parse_args()
if not re.fullmatch(r'[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+', args.bundle_id):
    parser.error('Invalid independent app bundle ID')
if args.enable_local_garage and not args.initialize_local_profile:
    parser.error('--enable-local-garage requires --initialize-local-profile')
if args.enable_local_match_entry and (not args.enable_local_garage or not args.restore_local_results or args.enable_local_replay):
    parser.error('--enable-local-match-entry requires local garage/results and replaces --enable-local-replay')
if args.enable_local_race_equipment and not args.enable_local_match_entry:
    parser.error('--enable-local-race-equipment requires --enable-local-match-entry')
if args.enable_local_upgrades and (not args.enable_local_race_equipment or not args.unlock_local_catalog):
    parser.error('--enable-local-upgrades requires local race equipment and the full local catalog')
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
if not 1 <= args.players <= 4 or not 0 <= args.ais <= 7 or args.players + args.ais > 8:
    parser.error('Use 1–4 players and 0–7 AI, with at most 8 total racers')
if args.ais and not args.enable_local_ai:
    parser.error('--ais requires --enable-local-ai for direct offline map launches')
if args.preserve_ai_path_driver and not args.enable_local_ai:
    parser.error('--preserve-ai-path-driver requires --enable-local-ai')
if args.restore_local_results and args.race_mode not in ('speed','item'):
    parser.error('--restore-local-results requires speed or item solo mode')
if args.load_kart_mesh and not args.enable_asset_load:
    parser.error('--load-kart-mesh requires --enable-asset-load')
if args.enable_local_menu and (not args.restore_local_results or not args.initialize_local_tables or args.race_mode not in ('speed','item')):
    parser.error('--enable-local-menu requires solo results, original tables and a speed/item race')
if args.lobby_probe and (not args.enable_commandline_map or not args.initialize_local_tables or args.players!=1 or args.map or args.enable_local_menu):
    parser.error('--lobby-probe requires map override, original tables, one player, and no --map/--enable-local-menu')
if args.initialize_local_profile and not args.lobby_probe:
    parser.error('--initialize-local-profile requires --lobby-probe')
if args.map and (not args.map.startswith('/Game/') or any(c in args.map for c in '? \t\n\r')):
    parser.error('--map must be one original /Game/... path without URL options')
ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'runtime/ios-probe-patch'
OUT.mkdir(parents=True,exist_ok=True)
BUNDLE=args.bundle_id
p=plistlib.loads((ROOT/'analysis/ios-Info.plist').read_bytes())
if p.get('CFBundleIdentifier')==BUNDLE:
    parser.error('Preserve the original app identity; choose a separate test bundle ID')
p['CFBundleIdentifier']=BUNDLE
p['CFBundleDisplayName']=args.display_name
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
if args.enable_asset_load:
    from enable_ios_asset_load import patch
    patch(OUT/'KartDrift',OUT/'KartDrift-assets',load_kart_mesh=args.load_kart_mesh)
    (OUT/'KartDrift-assets').replace(OUT/'KartDrift')
if args.enable_local_ai:
    from enable_ios_local_ai import patch
    patch(OUT/'KartDrift',OUT/'KartDrift-ai',preserve_path_driver=args.preserve_ai_path_driver)
    (OUT/'KartDrift-ai').replace(OUT/'KartDrift')
if args.restore_local_results:
    from enable_ios_local_results import patch
    patch(OUT/'KartDrift',OUT/'KartDrift-results','auto' if args.enable_local_menu or args.lobby_probe else args.race_mode)
    (OUT/'KartDrift-results').replace(OUT/'KartDrift')
if args.initialize_local_tables:
    from enable_ios_local_tables import patch
    patch(OUT/'KartDrift',OUT/'KartDrift-tables')
    (OUT/'KartDrift-tables').replace(OUT/'KartDrift')
if args.enable_local_replay:
    from enable_ios_local_replay import patch
    patch(OUT/'KartDrift',OUT/'KartDrift-replay')
    (OUT/'KartDrift-replay').replace(OUT/'KartDrift')
if args.lobby_probe:
    from enable_ios_local_lobby_probe import patch
    patch(OUT/'KartDrift',OUT/'KartDrift-lobby')
    (OUT/'KartDrift-lobby').replace(OUT/'KartDrift')
if args.enable_local_garage:
    from enable_ios_local_garage import patch
    patch(OUT/'KartDrift',OUT/'KartDrift-garage')
    (OUT/'KartDrift-garage').replace(OUT/'KartDrift')
if args.enable_local_match_entry:
    from enable_ios_local_match import patch
    patch(OUT/'KartDrift',OUT/'KartDrift-match')
    (OUT/'KartDrift-match').replace(OUT/'KartDrift')
if args.enable_local_race_equipment:
    from enable_ios_race_equipment import patch
    patch(OUT/'KartDrift',OUT/'KartDrift-race-equipment')
    (OUT/'KartDrift-race-equipment').replace(OUT/'KartDrift')
if args.enable_local_upgrades:
    from enable_ios_local_upgrades import patch
    patch(OUT/'KartDrift',OUT/'KartDrift-upgrades')
    (OUT/'KartDrift-upgrades').replace(OUT/'KartDrift')
if args.enable_local_tracks:
    from enable_ios_local_tracks import patch
    patch(OUT/'KartDrift',OUT/'KartDrift-tracks')
    (OUT/'KartDrift-tracks').replace(OUT/'KartDrift')
if args.enable_local_teams:
    from enable_ios_local_teams import patch
    patch(OUT/'KartDrift',OUT/'KartDrift-teams')
    (OUT/'KartDrift-teams').replace(OUT/'KartDrift')
if args.enable_local_liveries:
    from enable_ios_local_liveries import patch
    patch(OUT/'KartDrift',OUT/'KartDrift-liveries')
    (OUT/'KartDrift-liveries').replace(OUT/'KartDrift')
if args.enable_local_keyboard:
    from enable_ios_keyboard import patch
    patch(OUT/'KartDrift',OUT/'KartDrift-keyboard')
    (OUT/'KartDrift-keyboard').replace(OUT/'KartDrift')
if args.enable_local_tracks:
    from enable_ios_camera import patch
    patch(OUT/'KartDrift',OUT/'KartDrift-camera')
    (OUT/'KartDrift-camera').replace(OUT/'KartDrift')
ent={'application-identifier':BUNDLE,'get-task-allow':True}
if args.system_app_container:
    ent['com.apple.private.security.container-required']=True
with (OUT/'entitlements.plist').open('wb') as f:plistlib.dump(ent,f)
subprocess.run(['ldid','-S'+str(OUT/'entitlements.plist'),str(OUT/'KartDrift')],check=True)
maps={'training':'/Game/ART/Env/Stage_License/License_T01/License_T01',
      'speed':'/Game/ART/Env/Theme_Village/village_I01/Village_I01',
      'item':'/Game/ART/Env/Theme_Village/village_I01/Village_I01'}
modes={'training':'LicenseGameMode','speed':'SpeedSingleGameMode','item':'ItemSingleGameMode'}
options=f'?game=/Script/KartDrift.{modes[args.race_mode]}'
if args.race_mode=='training':
    options+='?License=L00'
options+=f'?players={args.players}?ais={args.ais}?observers=0'
selected_map=args.map or maps[args.race_mode]
if args.lobby_probe:
    selected_map='/Game/ART/Env/Stage_Kartmain_mobile/KartMain_mobile/KartMain_mobile'
    options='?game=/Script/KartDrift.OutGameMode?players=1'
(OUT/'ue4commandline.txt').write_text('../../../KartDrift/KartDrift.uproject '+selected_map+options+' -NoSplash -log -stdout -FullStdOutLogOutput ')
subprocess.run(['xcrun','--sdk','iphoneos','clang','-arch','arm64','-miphoneos-version-min=15.0',
    '-dynamiclib','-fobjc-arc',*(['-DOFFLINE_LOCAL_MENU'] if args.enable_local_menu else []),
    *(['-DOFFLINE_LOCAL_SAVES'] if args.enable_local_garage else []),
    *(['-DOFFLINE_LOCAL_UPGRADES'] if args.enable_local_upgrades else []),
    *(['-DOFFLINE_LOCAL_TRACKS','-DOFFLINE_LOBBY_CONTROLS'] if args.enable_local_tracks else []),
    *(['-DOFFLINE_LOCAL_LIVERIES'] if args.enable_local_liveries else []),
    *(['-DOFFLINE_LOCAL_KEYBOARD'] if args.enable_local_keyboard else []),
    *(['-DOFFLINE_LOCAL_TEAMS'] if args.enable_local_teams else []),
    *(['-DOFFLINE_LOCAL_MATCH'] if args.enable_local_match_entry else []),
    *(['-DOFFLINE_LOCAL_PROFILE'] if args.initialize_local_profile else []),
    *(['-DOFFLINE_UNLOCK_LOCAL_CATALOG'] if args.unlock_local_catalog else []),
    '-framework','Foundation','-framework','UIKit','-framework','CoreGraphics','-framework','GameController',
    str(ROOT/'tools/offline_probe.m'),'-o',str(OUT/'OfflineProbe.dylib')],check=True)
subprocess.run(['ldid','-S',str(OUT/'OfflineProbe.dylib')],check=True)
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
