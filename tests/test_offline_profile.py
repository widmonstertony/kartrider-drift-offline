"""Portable source tests; the Foundation persistence test requires macOS."""
import platform
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]

@unittest.skipUnless(platform.system()=='Darwin','requires Apple Foundation')
class PresetPersistence(unittest.TestCase):
    def test_native_timestamps_and_legacy_migration(self):
        # An actual native-layout preset, not a reimplementation of the codec.
        # These timestamp bits include a NaN when misinterpreted as float32.
        source=r'''
#import <Foundation/Foundation.h>
#include <stdint.h>
#include <string.h>
static BOOL probe_read(uint64_t a,void *b,size_t n){if(!a)return NO;memcpy(b,(void *)a,n);return YES;}
static uint64_t profile_u64(uint64_t a){uint64_t v=0;probe_read(a,&v,8);return v;}
static int32_t profile_i32(uint64_t a){int32_t v=0;probe_read(a,&v,4);return v;}
static uint64_t probe_slide(void){return 0;}
static void record(NSString *s){}
#include "offline_save.m"
#define CHECK(v) do {if(!(v)){fprintf(stderr,"failed at %d\n",__LINE__);return 1;}}while(0)
int main(){@autoreleasepool {
 save_known_items=[NSSet setWithObject:@"Kart:1"];
 unsigned char preset[0x140]={0},entry[40]={0};NSMutableArray *storage=[NSMutableArray new];
 save_fstring(entry,@"Kart",storage);save_fstring(entry+16,@"Kart:1",storage);
 uint64_t p=(uint64_t)entry;memcpy(preset+0x98,&p,8);
 int32_t one=1;memcpy(preset+0xa0,&one,4);memcpy(preset+0xa8,&one,4);memcpy(preset+0xc0,&one,4);
 uint64_t livery=(uint64_t)preset+0xe8;
 save_fstring((void *)livery,@"1",storage);save_fstring((void *)(livery+0x10),@"UUID",storage);save_fstring((void *)(livery+0x28),@"Kart:1",storage);
 int64_t created=0x08dc00007fc00000LL,expires=0x08dd123456789abcLL;
 memcpy((void *)(livery+0x38),&created,8);memcpy((void *)(livery+0x40),&expires,8);
 NSDictionary *snapshot=save_snapshot((uint64_t)preset);CHECK(snapshot&&save_valid(snapshot));
 CHECK([snapshot[@"livery"][@"timestamps"][0] longLongValue]==created);
 NSData *json=[NSJSONSerialization dataWithJSONObject:snapshot options:0 error:nil];CHECK(json);
 NSDictionary *decoded=[NSJSONSerialization JSONObjectWithData:json options:0 error:nil];CHECK(save_valid(decoded));
 CHECK([snapshot isEqual:decoded]);
 NSMutableDictionary *old=[snapshot mutableCopy],*oldLivery=[snapshot[@"livery"] mutableCopy];
 old[@"schema"]=@1;[oldLivery removeObjectForKey:@"timestamps"];oldLivery[@"vector"]=@[@0,@0,@0,@0];old[@"livery"]=oldLivery;
 NSDictionary *migrated=save_migrate(old);CHECK(save_valid(migrated));CHECK([migrated[@"livery"][@"timestamps"][0] longLongValue]==0);
 CHECK(!save_valid(@[]));CHECK(!save_valid(save_migrate(@{@"schema":@1,@"livery":@[]})));
 NSMutableDictionary *bad=[snapshot mutableCopy],*badLivery=[snapshot[@"livery"] mutableCopy];
 badLivery[@"timestamps"]=@[@(-1),@0];bad[@"livery"]=badLivery;CHECK(!save_valid(bad));
 NSLog(@"Native timestamp JSON round trip and legacy save migration passed");
 }return 0;}
'''
        with tempfile.TemporaryDirectory(prefix='kart-profile-test-') as tmp:
            src=Path(tmp)/'test.m';exe=Path(tmp)/'test';src.write_text(source)
            subprocess.run(['xcrun','clang','-fobjc-arc','-framework','Foundation','-I'+str(ROOT/'tools'),str(src),'-o',str(exe)],check=True,capture_output=True,text=True)
            subprocess.run([str(exe)],check=True,capture_output=True,text=True)

if __name__=='__main__':unittest.main()
