#!/usr/bin/env python3
"""Build our native Android app using only the official SDK, NDK and JDK tools."""
import argparse
import os
from pathlib import Path
import subprocess
import zipfile

ROOT = Path(__file__).resolve().parents[1]

def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--ndk', type=Path, required=True)
    p.add_argument('--java-home', type=Path, required=True)
    p.add_argument('--build-tools', type=Path, required=True)
    p.add_argument('--android-jar', type=Path, required=True)
    args = p.parse_args()
    args.ndk=args.ndk.resolve();args.java_home=args.java_home.resolve()
    args.build_tools=args.build_tools.resolve();args.android_jar=args.android_jar.resolve()
    out=ROOT/'build/android';out.mkdir(parents=True,exist_ok=True)
    env={**os.environ,'JAVA_HOME':str(args.java_home),'PATH':str(args.java_home/'bin')+os.pathsep+os.environ['PATH']}
    def run(*cmd):subprocess.run([str(x) for x in cmd],cwd=ROOT,env=env,check=True)
    run('cmake','-S',ROOT/'platform/android','-B',out/'native','-G','Ninja',
        '-DCMAKE_BUILD_TYPE=Release',f'-DCMAKE_TOOLCHAIN_FILE={args.ndk}/build/cmake/android.toolchain.cmake',
        '-DANDROID_ABI=arm64-v8a','-DANDROID_PLATFORM=android-26','-DANDROID_STL=c++_static')
    run('cmake','--build',out/'native','-j','4')
    classes=out/'classes';classes.mkdir(exist_ok=True)
    run(args.java_home/'bin/javac','--release','8','-classpath',args.android_jar,
        '-d',classes,ROOT/'platform/android/RaceActivity.java')
    dex=out/'dex';dex.mkdir(exist_ok=True)
    run(args.build_tools/'d8','--lib',args.android_jar,'--min-api','26','--output',dex,*sorted(classes.rglob('*.class')))
    unsigned=out/'unsigned.apk'
    run(args.build_tools/'aapt','package','-f','-M',ROOT/'platform/android/AndroidManifest.xml',
        '-I',args.android_jar,'-F',unsigned)
    with zipfile.ZipFile(unsigned,'a') as z:
        z.write(dex/'classes.dex','classes.dex')
        z.write(out/'native/libkartdrift.so','lib/arm64-v8a/libkartdrift.so',compress_type=zipfile.ZIP_STORED)
    aligned=out/'aligned.apk';run(args.build_tools/'zipalign','-f','-p','4',unsigned,aligned)
    key=out/'local-debug.keystore'
    if not key.exists():
        run(args.java_home/'bin/keytool','-genkeypair','-keystore',key,'-storepass','android','-keypass','android',
            '-alias','androiddebugkey','-keyalg','RSA','-keysize','2048','-validity','10000','-dname','CN=Local Development')
    apk=out/'KartDriftOffline-android.apk'
    run(args.build_tools/'apksigner','sign','--ks',key,'--ks-pass','pass:android','--out',apk,aligned)
    run(args.build_tools/'apksigner','verify','--verbose',apk)
    print(apk)

if __name__=='__main__':main()
