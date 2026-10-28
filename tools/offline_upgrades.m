/* Experimental local modification state for the retained original client.
   Read original kart/gear limits; keep the original UI and native deep copier.
   Saved data contains gear choices only, never native pointers or currency. */
static NSDictionary *upgrade_definitions;
static NSDictionary *upgrade_last_save;
static uint64_t upgrade_account;
static NSThread *upgrade_game_thread;
static BOOL upgrade_rejected_save;
static NSDictionary *upgrade_body_names;
static NSArray *upgrade_gear_order;

static NSString *upgrade_path(void) {
    return [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/offline-upgrades.json"];
}
static NSDictionary *upgrade_int_map(uint64_t map) {
    uint64_t data=profile_u64(map),bits=profile_u64(map+0x20);
    int32_t count=profile_i32(map+8);
    if(count<0||count>128||profile_i32(map+0x28)!=count)return nil;
    if(!count)return @{};
    if(!data)return nil;if(!bits)bits=map+0x10;
    NSMutableDictionary *result=[NSMutableDictionary dictionary];
    for(int32_t i=0;i<count;i++) {
        uint32_t word=0;if(!probe_read(bits+(i/32)*4,&word,4))return nil;
        if(!(word&(1u<<(i%32))))continue;
        NSString *key=profile_string(data+i*32);int32_t value=profile_i32(data+i*32+16);
        if(!key.length||key.length>64||result[key]||value<0||value>10000)return nil;
        result[key]=@(value);
    }
    return result;
}
static uint64_t upgrade_table(uint64_t tables,NSString *name,NSString *structure,int32_t size) {
    uint64_t data=profile_u64(tables+0x38);int32_t count=profile_i32(tables+0x40);
    if(!data||count<1||count>128)return 0;
    for(int32_t i=0;i<count;i++) {
        uint64_t table=profile_u64(data+i*24+8),cls=profile_u64(table+0x28);
        if(![probe_name(table) isEqualToString:name])continue;
        if(![probe_name(cls) isEqualToString:structure]||profile_i32(cls+0x58)!=size||profile_i32(table+0x38)!=1)return 0;
        return profile_u64(profile_u64(table+0x30)+8);
    }
    return 0;
}
static BOOL upgrade_verified(void) {
    static int verified=-1;if(verified>=0)return verified;verified=0;
    struct {uint64_t start,end;const char *digest;} checks[]={
        {0x102e26730ULL,0x102e26818ULL,"efb54e9d3a952e96f7525fca6cf764c00b3be383f19582912c1218b5d5539d1a"},
        {0x102e67384ULL,0x102e674b0ULL,"ebc79983751d4c2fdc6632105cf6aa0de5cd72bd5adff9c30f9a9221a5e162cf"},
        {0x102e66ef0ULL,0x102e67034ULL,"6ccbfddd3226961530e40ab44d5ff51e874d227a35953bd4f8be610a5727699e"},
        {0x101a34310ULL,0x101a344acULL,"4e6c976b72d88c788cc696e26bdb4589914056a2d1873c7e7c712678ad607b92"}
        ,{0x1024eac7cULL,0x1024eaeccULL,"9539562d247acde4ebf9b2bba4fd90ff4381d2e13c4b70be07da542dbf293318"}
        ,{0x1024eaeccULL,0x1024eb2dcULL,"2e4c58eb51fc42a7acff36b42ede31e7f008241a57637dade93e16f3a3bb689a"}
    };
    for(unsigned i=0;i<sizeof(checks)/sizeof(checks[0]);i++) {
        unsigned char data[2048],digest[32];char hex[65]={0};size_t length=checks[i].end-checks[i].start;
        if(length>sizeof(data)||!probe_read(probe_slide()+checks[i].start,data,length))return NO;
        CC_SHA256(data,(CC_LONG)length,digest);
        for(unsigned j=0;j<32;j++)snprintf(hex+j*2,3,"%02x",digest[j]);
        if(strcmp(hex,checks[i].digest))return NO;
    }
    verified=1;return YES;
}
static NSDictionary *upgrade_catalog(uint64_t tables) {
    uint64_t global=upgrade_table(tables,@"KtKartUpgradeSetDef",@"KtKartUpgradeSetDef",64);
    uint64_t custom=upgrade_table(tables,@"KtKartUpgradeCustomSetDef",@"KtKartUpgradeCustomSetDef",24);
    unsigned char maximum=255;
    if(!global||!custom||!probe_read(global+0x18,&maximum,1)||maximum>4)return nil;
    uint64_t entries=profile_u64(custom+8);int32_t count=profile_i32(custom+0x10);
    if(!entries||count<1||count>1000)return nil;
    NSMutableDictionary *result=[NSMutableDictionary dictionary];
    for(int32_t i=0;i<count;i++) {
        uint64_t entry=entries+i*56;NSString *key=profile_string(entry+8);
        uint64_t levels=profile_u64(entry+0x18),gears=profile_u64(entry+0x28);
        int32_t level_count=profile_i32(entry+0x20),gear_count=profile_i32(entry+0x30);
        if(!key||result[key]||!levels||!gears||level_count<1||level_count>8||gear_count<1||gear_count>8)return nil;
        if(![save_known_items containsObject:key]){record([NSString stringWithFormat:@"local modification definition lacks retained inventory item=%@",key]);continue;}
        int grade=-1;
        for(int j=0;j<level_count;j++){unsigned char value=255;if(!probe_read(levels+j*20,&value,1))return nil;if(value<=maximum&&value<gear_count&&value>grade)grade=value;}
        if(grade<0)return nil;
        NSDictionary *defaults=upgrade_int_map(gears+grade*168+8),*limits=upgrade_int_map(gears+grade*168+0x58);
        if(!defaults.count||!limits.count||limits.count>32||defaults.count!=limits.count)return nil;
        int budget=0;
        for(NSString *gear in limits){if(!defaults[gear]||[defaults[gear] intValue]>[limits[gear] intValue])return nil;budget+=[limits[gear] intValue];}
        if(budget<1||budget>10000)return nil;
        result[key]=@{@"grade":@(grade),@"budget":@(budget),@"defaults":defaults,@"limits":limits};
    }
    return result;
}
static BOOL upgrade_choices_valid(NSString *kart,NSDictionary *gears) {
    NSDictionary *definition=upgrade_definitions[kart],*limits=definition[@"limits"];
    if(!definition||![gears isKindOfClass:NSDictionary.class]||gears.count!=limits.count)return NO;
    for(id key in gears) {
        id value=gears[key];double number=[value isKindOfClass:NSNumber.class]?[value doubleValue]:-1;
        if(![key isKindOfClass:NSString.class]||!limits[key]||number<0||number>[limits[key] intValue]||!isfinite(number)||floor(number)!=number)return NO;
    }
    return YES;
}
static uint64_t upgrade_existing(NSString *kart) {
    unsigned char string[16]={0};NSMutableArray *storage=[NSMutableArray array];save_fstring(string,kart,storage);
    int32_t index=((int32_t(*)(void *,const void *))(probe_slide()+0x102e66ef0ULL))((void *)(upgrade_account+0x15c8),string);
    if(index<0||index>=profile_i32(upgrade_account+0x15d0))return 0;
    return profile_u64(upgrade_account+0x15c8)+(uint64_t)index*0x88+0x10;
}
static BOOL upgrade_set(NSString *kart,NSDictionary *gears) {
    if(!upgrade_choices_valid(kart,gears))return NO;
    NSDictionary *definition=upgrade_definitions[kart];NSUInteger count=gears.count;
    unsigned char value[112]={0},key[16]={0};NSMutableArray *storage=[NSMutableArray array];
    save_fstring(key,kart,storage);value[0]=[definition[@"grade"] unsignedCharValue];
    // Borrowed temporary map, copied by the original owning emplacement.
    unsigned char *map=value+8;NSMutableData *entries=[NSMutableData dataWithLength:count*32];
    uint64_t address=(uint64_t)entries.mutableBytes;int32_t n=(int32_t)count,capacity=128,minus_one=-1,one=1;
    memcpy(map,&address,8);memcpy(map+8,&n,4);memcpy(map+12,&n,4);
    for(NSUInteger i=0;i<count;i++){uint32_t bits=0;memcpy(&bits,map+0x10+(i/32)*4,4);bits|=1u<<(i%32);memcpy(map+0x10+(i/32)*4,&bits,4);}
    memcpy(map+0x28,&n,4);memcpy(map+0x2c,&capacity,4);memcpy(map+0x30,&minus_one,4);memcpy(map+0x48,&one,4);
    NSArray *keys=[[gears allKeys] sortedArrayUsingSelector:@selector(compare:)];int32_t used=0;
    for(NSUInteger i=0;i<count;i++) {
        unsigned char *entry=(unsigned char *)entries.mutableBytes+i*32;save_fstring(entry,keys[i],storage);
        int32_t amount=[gears[keys[i]] intValue],next=i+1<count?(int32_t)i+1:-1;
        used+=amount;memcpy(entry+16,&amount,4);memcpy(entry+24,&next,4);
    }
    int32_t total=[definition[@"budget"] intValue],remaining=total-used;
    memcpy(value+0x58,&total,4);memcpy(value+0x5c,&remaining,4);value[0x60]=1;
    ((void *(*)(void *,const void *,const void *))(probe_slide()+0x102e26730ULL))((void *)(upgrade_account+0x15c8),key,value);
    uint64_t restored=upgrade_existing(kart);
    return restored&&profile_i32(restored+0x58)==total&&profile_i32(restored+0x5c)==remaining&&[upgrade_int_map(restored+8) isEqual:gears];
}
static void upgrade_save(void) {
    NSMutableDictionary *karts=[NSMutableDictionary dictionary];
    for(NSString *kart in upgrade_definitions){uint64_t entry=upgrade_existing(kart);NSDictionary *gears=entry?upgrade_int_map(entry+8):nil;if(!upgrade_choices_valid(kart,gears))return;karts[kart]=gears;}
    NSDictionary *document=@{@"schema":@1,@"client":@"2.71.1",@"gears":karts};
    if([document isEqual:upgrade_last_save])return;
    NSData *data=[NSJSONSerialization dataWithJSONObject:document options:NSJSONWritingSortedKeys error:nil];if(!data||data.length>1024*1024)return;
    NSFileManager *files=NSFileManager.defaultManager;
    if(upgrade_rejected_save&&[files fileExistsAtPath:upgrade_path()]) {
        if(![files copyItemAtPath:upgrade_path() toPath:[upgrade_path() stringByAppendingFormat:@".rejected-%@",NSUUID.UUID.UUIDString] error:nil])return;
        upgrade_rejected_save=NO;
    }
    if([data writeToFile:upgrade_path() options:NSDataWritingAtomic error:nil]){upgrade_last_save=document;record([NSString stringWithFormat:@"local modifications saved karts=%lu",(unsigned long)karts.count]);}
    else record(@"local modifications save failed");
}
static BOOL upgrade_initialize(uint64_t account,uint64_t tables) {
    if(!upgrade_verified())return NO;
    NSDictionary *definitions=upgrade_catalog(tables);if(!definitions)return NO;
    uint64_t bodies=upgrade_table(tables,@"KtKartBodyDef",@"KtKartBodyParamNameDef",24);
    uint64_t gears=upgrade_table(tables,@"KtKartGearSetDef",@"KtKartGearSetDef",24);
    int32_t body_count=profile_i32(bodies+0x10),gear_count=profile_i32(gears+0x10);
    if(!bodies||!gears||body_count<1||body_count>1024||gear_count!=9)return NO;
    NSMutableDictionary *names=[NSMutableDictionary dictionary];NSMutableArray *order=[NSMutableArray array];
    for(int i=0;i<body_count;i++) {
        uint64_t entry=profile_u64(bodies+8)+(uint64_t)i*32;
        NSString *kart=profile_string(entry),*body=profile_string(entry+0x10);
        if(!kart||!body||names[kart])return NO;names[kart]=body;
    }
    for(int i=0;i<gear_count;i++) {
        NSString *gear=profile_string(profile_u64(gears+8)+(uint64_t)i*40);
        if(!gear||[order containsObject:gear])return NO;[order addObject:gear];
    }
    upgrade_body_names=names;upgrade_gear_order=order;
    upgrade_account=account;upgrade_definitions=definitions;upgrade_game_thread=NSThread.currentThread;
    NSData *data=[NSData dataWithContentsOfFile:upgrade_path() options:NSDataReadingMappedIfSafe error:nil];
    NSDictionary *document=data&&data.length<=1024*1024?[NSJSONSerialization JSONObjectWithData:data options:0 error:nil]:nil;
    BOOL valid=[document isKindOfClass:NSDictionary.class]&&[document[@"schema"] isEqual:@1]&&[document[@"client"] isEqual:@"2.71.1"]&&[document[@"gears"] isKindOfClass:NSDictionary.class];
    NSDictionary *saved=valid?document[@"gears"]:nil;
    if(valid)for(id key in saved)if(!upgrade_choices_valid(key,saved[key])){valid=NO;break;}
    if(data&&!valid)upgrade_rejected_save=YES;
    for(NSString *key in definitions)if(!upgrade_set(key,valid&&saved[key]?saved[key]:definitions[key][@"defaults"]))return NO;
    upgrade_save();
    record([NSString stringWithFormat:@"local modifications unlocked original configured karts=%lu restored=%d; limits preserved",(unsigned long)definitions.count,valid]);return YES;
}

__attribute__((visibility("default")))
void offline_race_upgrade(uint64_t component,void *body,uint64_t preset) {
    if(!body||!upgrade_account||NSThread.currentThread!=upgrade_game_thread||profile_u64(preset+0x20)!=upgrade_account||profile_u64(upgrade_account+0xa30))return;
    NSString *kart=save_snapshot(preset)[@"equipment"][@"Kart"];
    if(!kart||!upgrade_definitions[kart])return;
    uint64_t own=upgrade_existing(kart);NSDictionary *choices=own?upgrade_int_map(own+8):nil;
    if(!upgrade_choices_valid(kart,choices)||upgrade_gear_order.count!=9)return;
    NSString *body_name=upgrade_body_names[kart];
    if(body_name) {
        unsigned char string[16]={0};NSMutableArray *storage=[NSMutableArray array];save_fstring(string,body_name,storage);
        struct OriginalBodyParam {unsigned char bytes[216];};
        struct OriginalBodyParam value=((struct OriginalBodyParam(*)(const void *))(probe_slide()+0x1024eac7cULL))(string);
        memcpy(body,value.bytes,sizeof(value));
    }
    int32_t values[9]={0};for(unsigned i=0;i<9;i++)values[i]=[choices[upgrade_gear_order[i]] intValue];
    struct {const int32_t *data;int32_t count,capacity;} gears={values,9,9};
    BOOL applied=((BOOL(*)(void *,const void *))(probe_slide()+0x1024eaeccULL))(body,&gears);
    uint64_t pawn=profile_u64(component+0xa0),state_class=((uint64_t(*)(void))(probe_slide()+0x103ae241cULL))();
    uint64_t find=profile_u64(profile_u64(pawn)+0x628);
    uint64_t state=pawn&&find?((uint64_t(*)(void *,uint64_t))find)((void *)pawn,state_class):0;
    if(state&&profile_i32(state+0x168)==0)*(unsigned char *)(state+0x170)=[upgrade_definitions[kart][@"grade"] unsignedCharValue];
    record([NSString stringWithFormat:@"local original race gears kart=%@ applied=%d base_mapping=%d",kart,applied,body_name!=nil]);
}
__attribute__((visibility("default")))
void offline_upgrade_request(uint64_t account,const void *kart_value,const void *gear_value,int reset) {
    if(!upgrade_account||account!=upgrade_account||profile_u64(account+0xa30)||NSThread.currentThread!=upgrade_game_thread)return;
    unsigned char debug=0;if(!probe_read(account+0x1a0,&debug,1)||debug!=1)return;
    NSString *kart=profile_string((uint64_t)kart_value);NSDictionary *definition=kart?upgrade_definitions[kart]:nil;
    if(!definition)return;
    NSDictionary *gears=reset?definition[@"defaults"]:upgrade_int_map((uint64_t)gear_value);
    if(!upgrade_set(kart,gears)){record(@"local gear request rejected");return;}
    upgrade_save();
    ((void(*)(void *,const void *))(probe_slide()+0x101a34310ULL))((void *)(account+0x1578),NULL);
    ((void(*)(void *,const void *))(probe_slide()+0x101a34310ULL))((void *)(account+0x1598),NULL);
    record([NSString stringWithFormat:@"original gear request applied locally kart=%@ reset=%d",kart,reset]);
}
