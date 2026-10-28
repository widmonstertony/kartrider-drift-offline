/* Experimental initialization of the retained app's original local inventory.
   Item IDs and the equipment preset come from its own KtInitialDef table.
   Optional catalog grants use the same retained original item definitions.
   OFFLINE_LOCAL_SAVES adds local preset persistence using original interfaces.
   The garage interface remains the original client's own widgets. */
#import <CommonCrypto/CommonDigest.h>

static BOOL profile_verified(void) {
    static int verified=-1;
    if(verified>=0)return verified;
    uint64_t slide=probe_slide();if(slide==UINT64_MAX)return NO;
    verified=0;
    struct { uint64_t offset; size_t size; const char *digest; } checks[]={
        {0x2d63ba0,0x248,"02f21037e4abb9a23ce45aaf965639300cf3b07766907399153886ecda5d18c7"},
        {0x2d87a60,8,"3abad5cde086c2eee1a5f86c9e392fbecec51811e6f6cfd6d6c74703aec8b208"},
        {0x2cdfcc4,0x180,"36b31d313fa023204e141d35e53bd992ff432b4e1cb0d6d52cb9a2a27ef0118e"},
        {0x59ecfd0,0x288,"206e7feeaf79462fa5250ce1e58fd0d49f15227d2fc51288759d1869c5ac1ed8"},
        {0x3d8e790,0x3c,"74fc068077597fc9952532944d11a6d53b3e975d1304751dd1f13ed97197fd5c"},
        {0x3d8e7e4,0x3c,"239ee2d527bdf28dfffb9545e157d195a1ab67819dad0d07857e5e1597a7a163"}
    };
    for(unsigned i=0;i<sizeof(checks)/sizeof(checks[0]);i++) {
        unsigned char data[1024],digest[CC_SHA256_DIGEST_LENGTH];char hex[65]={0};
        if(checks[i].size>sizeof(data)||!probe_read(slide+0x100000000ULL+checks[i].offset,data,checks[i].size))return NO;
        CC_SHA256(data,(CC_LONG)checks[i].size,digest);
        for(unsigned j=0;j<sizeof(digest);j++)snprintf(hex+j*2,3,"%02x",digest[j]);
        if(strcmp(hex,checks[i].digest))return NO;
    }
    Class tasks=NSClassFromString(@"FIOSAsyncTask");SEL create=NSSelectorFromString(@"CreateTaskWithBlock:");
    if(![tasks respondsToSelector:create] ||
       (uint64_t)method_getImplementation(class_getClassMethod(tasks,create))!=slide+0x103d8e790ULL)return NO;
    verified=1;record(@"local profile original engine/version checks passed");return YES;
}

static uint64_t profile_u64(uint64_t address) {
    uint64_t value=0;probe_read(address,&value,sizeof(value));return value;
}
static int32_t profile_i32(uint64_t address) {
    int32_t value=0;probe_read(address,&value,sizeof(value));return value;
}
static uint64_t profile_subsystem(uint64_t collection,NSString *kind) {
    uint64_t data=profile_u64(collection+0x10);int32_t count=profile_i32(collection+0x18);
    if(!data||count<1||count>512)return 0;
    for(int32_t i=0;i<count;i++) {
        uint64_t cls=profile_u64(data+i*24),object=profile_u64(data+i*24+8);
        if(cls&&object&&profile_u64(object+0x10)==cls&&[probe_name(cls) isEqualToString:kind])return object;
    }
    return 0;
}
static NSString *profile_string(uint64_t address) {
    uint64_t data=profile_u64(address);int32_t count=profile_i32(address+8);unichar value[256]={0};
    if(!data||count<2||count>256||!probe_read(data,value,count*2)||value[count-1])return nil;
    return [[NSString alloc] initWithCharacters:value length:count-1];
}

#ifdef OFFLINE_UNLOCK_LOCAL_CATALOG
static NSArray *profile_catalog(uint64_t tables) {
    uint64_t data=profile_u64(tables+0x38),table=0;
    int32_t count=profile_i32(tables+0x40);if(count<1||count>128)return nil;
    for(int32_t i=0;i<count;i++) {
        uint64_t candidate=profile_u64(data+i*24+8);
        if([probe_name(candidate) isEqualToString:@"KtItemTable"]){table=candidate;break;}
    }
    uint64_t structure=profile_u64(table+0x28);
    if(!table||![probe_name(structure) isEqualToString:@"KtClientInventoryDef"]||profile_i32(table+0x38)!=1)return nil;
    // Original reflected KtClientItemDef records, including the KtItemDef base.
    uint64_t field=profile_u64(structure+0x50),item_structure=0;
    for(unsigned i=0;field&&i<128;i++,field=profile_u64(field+0x20)) {
        if([probe_fname(field+0x28) isEqualToString:@"itemDefVector"]) {
            item_structure=profile_u64(profile_u64(field+0x78)+0x78);break;
        }
    }
    if(![probe_name(item_structure) isEqualToString:@"KtClientItemDef"]||profile_i32(item_structure+0x58)!=152)return nil;
    uint64_t row=profile_u64(profile_u64(table+0x30)+8),items=profile_u64(row+0x18);
    int32_t item_count=profile_i32(row+0x20);if(!row||!items||item_count<1||item_count>20000)return nil;
    NSMutableArray *result=[NSMutableArray arrayWithCapacity:item_count];
    NSCharacterSet *invalid=[[NSCharacterSet characterSetWithCharactersInString:@"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789:_"] invertedSet];
    for(int32_t i=0;i<item_count;i++) {
        uint64_t entry=items+i*152;NSString *key=profile_string(entry+8);unsigned char type=0;
        if(!key||key.length>127||[key rangeOfCharacterFromSet:invalid].location!=NSNotFound||
           ![key containsString:@":"]||!probe_read(entry,&type,1)||type>6)return nil;
        [result addObject:@[key,@1,@(type)]];
    }
    return result;
}
#endif

#ifdef OFFLINE_LOCAL_SAVES
#include "offline_save.m"
#endif

static void profile_initialize(void) {
    static uint64_t initialized_account=0;
    uint64_t slide=probe_slide(),engine=profile_u64(slide+0x108b0b288ULL);
    if(!engine||profile_i32(engine+0xc50)!=1)return;
    uint64_t world=profile_u64(profile_u64(profile_u64(engine+0xc48))+0x280);
    if(!world||profile_u64(world+0x38)||![probe_name(world) isEqualToString:@"KartMain_Mobile"] ||
       ![probe_name(profile_u64(profile_u64(world+0x118)+0x10)) isEqualToString:@"OutGameMode"])return;
    uint64_t account=profile_u64(profile_u64(profile_u64(world+0x180)+0x1b8)+0x50);
    unsigned char logged=0,debug=0,platform=0;
    if(!account||!probe_read(account+0x181,&logged,1)||logged!=1||
       !probe_read(account+0x1a0,&debug,1)||debug!=1||!probe_read(account+0x550,&platform,1)||platform!=6)return;
    if(account==initialized_account) {
#ifdef OFFLINE_LOCAL_SAVES
        uint64_t current=profile_subsystem(account+0x28,@"AccountPreset");if(current)save_tick(current);
#endif
        return;
    }
    uint64_t inventory=profile_subsystem(account+0x28,@"AccountInventory");
    uint64_t preset=profile_subsystem(account+0x28,@"AccountPreset");
    uint64_t tables=profile_subsystem(profile_u64(engine+0xc60),@"TableManager");
    if(!inventory||!preset||!tables)return;
    // Do not replace an existing original equipped preset.
    BOOL has_equipment=profile_i32(preset+0xa0)>0;
#ifndef OFFLINE_UNLOCK_LOCAL_CATALOG
    if(has_equipment){initialized_account=account;record(@"local profile kept existing original equipment");return;}
#endif
    uint64_t data=profile_u64(tables+0x38),table=0,row=0;
    int32_t count=profile_i32(tables+0x40);if(count<1||count>128)return;
    for(int32_t i=0;i<count;i++) {
        uint64_t candidate=profile_u64(data+i*24+8);
        if([probe_name(candidate) isEqualToString:@"KtInitialDef"]){table=candidate;break;}
    }
    if(!table||![probe_name(profile_u64(table+0x28)) isEqualToString:@"KtInitialDef"]||profile_i32(table+0x38)!=1)return;
    row=profile_u64(profile_u64(table+0x30)+8);
    uint64_t items=profile_u64(row+8);int32_t item_count=profile_i32(row+0x10);
    int32_t equip_count=profile_i32(row+0x20);
    if(!row||!items||item_count<1||item_count>512||equip_count<1||equip_count>128)return;
    NSMutableArray *parsed=[NSMutableArray arrayWithCapacity:item_count];
    NSCharacterSet *invalid=[[NSCharacterSet characterSetWithCharactersInString:@"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789:_"] invertedSet];
    for(int32_t i=0;i<item_count;i++) {
        NSString *entry=profile_string(items+i*16);NSRange separator=[entry rangeOfString:@"-" options:NSBackwardsSearch];
        if(!entry||separator.location==NSNotFound||!separator.location)return;
        NSString *key=[entry substringToIndex:separator.location],*amount=[entry substringFromIndex:separator.location+1];
        NSScanner *scanner=[NSScanner scannerWithString:amount];int quantity=0;
        if(key.length>127||[key rangeOfCharacterFromSet:invalid].location!=NSNotFound||
           ![key containsString:@":"]||![scanner scanInt:&quantity]||!scanner.isAtEnd||quantity<1||quantity>1000000)return;
        [parsed addObject:@[key,@(quantity),@2]];
    }
#ifdef OFFLINE_UNLOCK_LOCAL_CATALOG
    NSArray *catalog=profile_catalog(tables);if(!catalog)return;
    NSMutableArray *all=[NSMutableArray arrayWithArray:catalog];[all addObjectsFromArray:parsed];parsed=all;
#endif
    // The original setter copies FString and maintains category indexes.
    for(NSArray *entry in parsed) {
        NSString *key=entry[0];unichar buffer[128]={0};[key getCharacters:buffer range:NSMakeRange(0,key.length)];
        struct { const unichar *data;int32_t count,capacity; } value={buffer,(int32_t)key.length+1,(int32_t)key.length+1};
        struct { int32_t count,padding;int64_t expires; } item={[entry[1] intValue],0,0};
        ((void(*)(void *,uint8_t,const void *,const void *))(slide+0x102d63ba0ULL))((void *)inventory,[entry[2] unsignedCharValue],&value,&item);
    }
    if(!has_equipment)((void(*)(void *,const void *))(slide+0x102d87a60ULL))((void *)preset,(void *)(row+0x18));
#ifdef OFFLINE_LOCAL_SAVES
    NSMutableSet *known=[NSMutableSet set];for(NSArray *entry in parsed)[known addObject:entry[0]];save_known_items=known;
    save_restore(preset);save_tick(preset);
#endif
    initialized_account=account;
#ifdef OFFLINE_UNLOCK_LOCAL_CATALOG
    record([NSString stringWithFormat:@"local catalog granted original definitions=%lu preserved_equipment=%d",(unsigned long)catalog.count,has_equipment]);
#endif
    record([NSString stringWithFormat:@"local profile initialized original initial inventory items=%d equipment=%d main_thread=%d",item_count,equip_count,NSThread.isMainThread]);
    // Re-enter the same original lobby so its original BeginPlay reads the
    // populated account. The GameInstance/account persists across this travel.
    NSString *options=@"game=/Script/KartDrift.OutGameMode?players=1";unichar buffer[128]={0};
    [options getCharacters:buffer range:NSMakeRange(0,options.length)];
    struct { const unichar *data;int32_t count,capacity; } value={buffer,(int32_t)options.length+1,(int32_t)options.length+1};
    ((void(*)(void *,uint64_t,BOOL,const void *))(slide+0x1059ecfd0ULL))((void *)world,profile_u64(world+0x18),YES,&value);
}

static void start_local_profile(void) {
    NSTimeInterval interval=2;
#ifdef OFFLINE_LOCAL_SAVES
    interval=0.25;
#endif
    [NSTimer scheduledTimerWithTimeInterval:interval repeats:YES block:^(NSTimer *timer){
        if(!profile_verified())return;
        BOOL (^task)(void)=^BOOL {@autoreleasepool {profile_initialize();}return YES;};
        ((void(*)(id,SEL,id))objc_msgSend)(NSClassFromString(@"FIOSAsyncTask"),NSSelectorFromString(@"CreateTaskWithBlock:"),task);
    }];
}
