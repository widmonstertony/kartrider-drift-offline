/* Per-race outfits assembled from the owner's retained inventory table.
   The native descriptor setters deep-copy these borrowed presets. */
static NSArray<NSMutableData *> *ai_presets;
static NSMutableArray *ai_preset_storage;
static NSArray<NSDictionary *> *ai_previous_roster;

static BOOL ai_parts_verified(void) {
    static int valid=-1;if(valid>=0)return valid;valid=0;
    struct {uint64_t a,z;const char *hash;} checks[]={
        {0x1024fd720ULL,0x1024fd8b4ULL,"610375cba92f000317627d4f13c20110cdeccfc2ce10e25635ca48c97159ab4f"},
        {0x102983274ULL,0x10298329cULL,"3a54bc3cd36aeb78c00c0a016879f6e71baa5c379ddfa6d1a453184516dc93f2"},
        {0x103819408ULL,0x103819458ULL,"7a49c0cf1c01350c550571366c664a3b88bfdead9c63a5e1a813bd60b73f6c11"}
    };
    for(unsigned i=0;i<3;i++) {
        unsigned char bytes[512],digest[32];char hex[65]={0};size_t n=checks[i].z-checks[i].a;
        if(n>sizeof(bytes)||!probe_read(probe_slide()+checks[i].a,bytes,n))return NO;
        CC_SHA256(bytes,(CC_LONG)n,digest);for(int j=0;j<32;j++)snprintf(hex+j*2,3,"%02x",digest[j]);
        if(strcmp(hex,checks[i].hash))return NO;
    }
    valid=1;return YES;
}
static BOOL ai_add_original_parts(NSString *item,int kind,NSMutableDictionary *equipment) {
    unsigned char string[16]={0};NSMutableArray *storage=[NSMutableArray array];save_fstring(string,item,storage);
    struct {uint64_t data;int32_t count,capacity;} parts={0};
    BOOL found=((BOOL(*)(const void *,void *,int))(probe_slide()+0x1024fd720ULL))(string,&parts,kind);
    uint64_t enumeration=((uint64_t(*)(void))(probe_slide()+0x103819408ULL))();
    uint64_t names=profile_u64(enumeration+0x40);int count=profile_i32(enumeration+0x48);
    BOOL valid=found&&parts.count>=0&&parts.count<=128&&count>0&&count<=128;
    if(valid)for(int i=0;i<parts.count;i++) {
        uint64_t entry=parts.data+i*24;unsigned char slot=0;probe_read(entry,&slot,1);
        int category=((int(*)(int))(probe_slide()+0x102983274ULL))(slot);
        NSString *value=profile_string(entry+8);if(!category||!save_known_items||![save_known_items containsObject:value])continue;
        for(int j=0;j<count;j++)if(profile_u64(names+j*16+8)==(uint64_t)category) {
            NSString *key=[[probe_fname(names+j*16) componentsSeparatedByString:@"::"] lastObject];
            if(key.length)equipment[key]=value;break;
        }
    }
    // The original lookup allocates its returned TArray and FString values.
    // Free only those original allocations, never the borrowed input string.
    if(parts.data&&parts.count>=0&&parts.count<=128)for(int i=0;i<parts.count;i++) {
        uint64_t text=profile_u64(parts.data+i*24+8);
        if(text)((void(*)(void *))(probe_slide()+0x103cf5d48ULL))((void *)text);
    }
    if(parts.data)((void(*)(void *))(probe_slide()+0x103cf5d48ULL))((void *)parts.data);
    return valid;
}

static NSString *ai_choose(NSArray<NSString *> *pool,NSSet *used,NSString *previous) {
    NSMutableArray *choices=[NSMutableArray array];
    for(NSString *item in pool)if(![used containsObject:item]&&![item isEqual:previous])[choices addObject:item];
    if(!choices.count)for(NSString *item in pool)if(![used containsObject:item])[choices addObject:item];
    return choices.count?choices[arc4random_uniform((uint32_t)choices.count)]:nil;
}
static NSMutableData *ai_pack_preset(NSDictionary *equipment,NSMutableArray *storage) {
    NSArray *keys=[[equipment allKeys] sortedArrayUsingSelector:@selector(compare:)];
    int32_t count=(int32_t)keys.count;if(count<1||count>128)return nil;
    NSMutableData *preset=[NSMutableData dataWithLength:160],*entries=[NSMutableData dataWithLength:count*40];
    [storage addObject:entries];unsigned char *p=preset.mutableBytes;
    uint64_t address=(uint64_t)entries.mutableBytes;int32_t capacity=128,minus_one=-1,one=1;
    memcpy(p,&address,8);memcpy(p+8,&count,4);memcpy(p+12,&count,4);
    for(int i=0;i<count;i++){uint32_t word=0;memcpy(&word,p+0x10+i/32*4,4);word|=1u<<(i%32);memcpy(p+0x10+i/32*4,&word,4);}
    memcpy(p+0x28,&count,4);memcpy(p+0x2c,&capacity,4);memcpy(p+0x30,&minus_one,4);memcpy(p+0x48,&one,4);
    for(int i=0;i<count;i++) {
        unsigned char *entry=(unsigned char *)entries.mutableBytes+i*40;
        save_fstring(entry,keys[i],storage);save_fstring(entry+16,equipment[keys[i]],storage);
        int32_t next=i+1<count?i+1:-1;memcpy(entry+32,&next,4);
    }
    return preset;
}
static NSArray<NSDictionary *> *ai_choose_roster(NSDictionary *parents,NSArray *karts,NSDictionary *human,NSArray *previous,int racers) {
    if(racers<2||racers>8)return nil;
    NSMutableDictionary *costumes=[NSMutableDictionary dictionary];
    for(NSString *item in parents) {
        NSString *parent=parents[item];
        if(![item hasPrefix:@"Costume:"]||![parent hasPrefix:@"Character:"]||!parents[parent])continue;
        if(!costumes[parent])costumes[parent]=[NSMutableArray array];[costumes[parent] addObject:item];
    }
    NSArray *characters=[[costumes allKeys] sortedArrayUsingSelector:@selector(compare:)];
    if(characters.count<(NSUInteger)racers||karts.count<(NSUInteger)racers)return nil;
    NSMutableSet *usedCharacters=[NSMutableSet set],*usedKarts=[NSMutableSet set];
    if(human[@"Character"])[usedCharacters addObject:human[@"Character"]];
    if(human[@"Kart"])[usedKarts addObject:human[@"Kart"]];
    NSMutableArray *roster=[NSMutableArray arrayWithObject:@{}];
    for(int slot=1;slot<racers;slot++) {
        NSDictionary *old=slot<previous.count?previous[slot]:nil;
        NSString *character=ai_choose(characters,usedCharacters,old[@"Character"]);
        NSString *kart=ai_choose(karts,usedKarts,old[@"Kart"]);
        NSString *costume=character?ai_choose(costumes[character],[NSSet set],old[@"Costume"]):nil;
        if(!character||!kart||!costume)return nil;
        [usedCharacters addObject:character];[usedKarts addObject:kart];
        [roster addObject:@{@"Character":character,@"Costume":costume,@"Kart":kart}];
    }
    return roster;
}
static BOOL ai_prepare_roster(int racers,uint64_t preset) {
    if(!ai_parts_verified())return NO;
    // Upgrade definitions identify actual kart bodies, excluding wheel,
    // booster and other parts that share the Kart inventory prefix.
    NSArray *karts=[[upgrade_definitions allKeys] sortedArrayUsingSelector:@selector(compare:)];
    NSArray *roster=ai_choose_roster(profile_item_parents,karts,save_snapshot(preset)[@"equipment"],ai_previous_roster,racers);
    if(!roster)return NO;
    NSMutableArray *values=[NSMutableArray arrayWithObject:[NSMutableData data]],*storage=[NSMutableArray array];
    for(int slot=1;slot<racers;slot++) {
        NSDictionary *outfit=roster[slot];NSMutableDictionary *equipment=[NSMutableDictionary dictionary];
        if(!ai_add_original_parts(outfit[@"Kart"],1,equipment))return NO;
        ai_add_original_parts(outfit[@"Character"],3,equipment);ai_add_original_parts(outfit[@"Costume"],3,equipment);
        [equipment addEntriesFromDictionary:outfit];
        NSMutableData *value=ai_pack_preset(equipment,storage);if(!value)return NO;[values addObject:value];
    }
    ai_preset_storage=storage;ai_presets=values;ai_previous_roster=roster;
    record([NSString stringWithFormat:@"local AI roster randomized opponents=%d distinct_characters=%d distinct_karts=%d compatible_costumes=1",racers-1,racers-1,racers-1]);return YES;
}
