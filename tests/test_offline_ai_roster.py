"""Exercise actual roster selection and borrowed native-preset packing."""
import platform
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


@unittest.skipUnless(platform.system() == 'Darwin', 'requires Foundation')
class OfflineAIRoster(unittest.TestCase):
    def test_unique_compatible_rosters_and_native_preset(self):
        source = r'''
#import <Foundation/Foundation.h>
#import <CommonCrypto/CommonDigest.h>
#include <stdint.h>
#include <string.h>
static BOOL probe_read(uint64_t a,void *b,size_t n){if(!a)return NO;memcpy(b,(void *)a,n);return YES;}
static uint64_t profile_u64(uint64_t a){uint64_t v=0;probe_read(a,&v,8);return v;}
static int32_t profile_i32(uint64_t a){int32_t v=0;probe_read(a,&v,4);return v;}
static uint64_t probe_slide(void){return 0;}
static NSString *profile_string(uint64_t a){return nil;}
static NSString *probe_fname(uint64_t a){return nil;}
static void record(NSString *s){}
static NSDictionary *profile_item_parents,*upgrade_definitions;
#include "offline_save.m"
#include "offline_ai_roster.m"
#define CHECK(v) do{if(!(v)){fprintf(stderr,"failed at %d\n",__LINE__);return 1;}}while(0)
int main(){@autoreleasepool {
 NSMutableDictionary *parents=[NSMutableDictionary dictionary];NSMutableArray *karts=[NSMutableArray array];
 for(int i=0;i<20;i++) {
   NSString *character=[NSString stringWithFormat:@"Character:C%d",i];parents[character]=@"";
   for(int j=0;j<3;j++)parents[[NSString stringWithFormat:@"Costume:C%d_%d",i,j]]=character;
   [karts addObject:[NSString stringWithFormat:@"Kart:K%d",i]];
 }
 parents[@"Costume:Orphan"]=@"Character:Missing";
 NSDictionary *human=@{@"Character":@"Character:C0",@"Kart":@"Kart:K0"};NSArray *previous=nil;
 for(int round=0;round<500;round++) {
   int racers=round%2?8:4;
   NSArray *roster=ai_choose_roster(parents,karts,human,previous,racers);CHECK(roster.count==racers);
   NSMutableSet *characters=[NSMutableSet set],*bodies=[NSMutableSet set];
   for(int slot=1;slot<racers;slot++) {
     NSDictionary *outfit=roster[slot];
     CHECK([parents[outfit[@"Costume"]] isEqual:outfit[@"Character"]]);
     CHECK(![outfit[@"Character"] isEqual:human[@"Character"]]);CHECK(![outfit[@"Kart"] isEqual:human[@"Kart"]]);
     CHECK(![characters containsObject:outfit[@"Character"]]);CHECK(![bodies containsObject:outfit[@"Kart"]]);
     if(slot<previous.count){CHECK(![outfit[@"Character"] isEqual:previous[slot][@"Character"]]);CHECK(![outfit[@"Kart"] isEqual:previous[slot][@"Kart"]]);}
     [characters addObject:outfit[@"Character"]];[bodies addObject:outfit[@"Kart"]];
     NSMutableArray *storage=[NSMutableArray array];NSMutableData *packed=ai_pack_preset(outfit,storage);
     unsigned char preset[0x140]={0};memcpy(preset+0x98,packed.bytes,160);
     save_known_items=[NSSet setWithArray:outfit.allValues];NSDictionary *snapshot=save_snapshot((uint64_t)preset);
     CHECK([snapshot[@"equipment"] isEqual:outfit]);CHECK(save_valid(snapshot));
   }
   previous=roster;
 }
 CHECK(!ai_choose_roster(parents,karts,human,nil,9));
 CHECK(!ai_choose_roster(@{@"Costume:Orphan":@"Character:Missing"},karts,human,nil,8));
 CHECK(!ai_choose_roster(parents,@[],human,nil,4));
 NSLog(@"500 four/eight-racer rosters: unique bodies/characters, compatible costumes, new per-slot choices and native preset readback passed");
 }return 0;}
'''
        with tempfile.TemporaryDirectory(prefix='kart-ai-roster-') as tmp:
            src, exe = Path(tmp) / 'test.m', Path(tmp) / 'test'
            src.write_text(source)
            subprocess.run(['xcrun', 'clang', '-fobjc-arc', '-framework', 'Foundation',
                            '-I' + str(ROOT / 'tools'), str(src), '-o', str(exe)],
                           check=True, capture_output=True, text=True)
            subprocess.run([str(exe)], check=True, capture_output=True, text=True)


if __name__ == '__main__':
    unittest.main()
