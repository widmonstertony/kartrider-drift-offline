/* Experimental original Play request consumer. The first restored local race
   uses the retained Village_I01 map; map selection coverage is separate work.
   Runs only inside profile_initialize on the original game thread. */

static BOOL match_verified(void) {
    static int verified=-1;
    if(verified>=0)return verified;
    verified=0;uint64_t slide=probe_slide();
    struct {uint64_t offset;size_t size;const char *digest;} checks[]={
        {0x5ab8d20,0x40,"c143e3496716b5986c1c03eaedc6f7f177d62abb532377f05e97ed107284735f"},
        {0x2821af4,0x80,"9c03ab5b50ef0439fa233a1c6229670b45b5d529e066de2088d24361bb173071"},
        {0x2d7262c,0x114,"eae563b1f03155fef05204cec6deefceb2617b635dbe9197e81179ca04c481b6"}
    };
    for(unsigned i=0;i<sizeof(checks)/sizeof(checks[0]);i++) {
        unsigned char data[512],digest[CC_SHA256_DIGEST_LENGTH];char hex[65]={0};
        if(checks[i].size>sizeof(data)||!probe_read(slide+0x100000000ULL+checks[i].offset,data,checks[i].size))return NO;
        CC_SHA256(data,(CC_LONG)checks[i].size,digest);
        for(unsigned j=0;j<sizeof(digest);j++)snprintf(hex+j*2,3,"%02x",digest[j]);
        if(strcmp(hex,checks[i].digest)){record(@"local match engine function check failed");return NO;}
    }
    uint32_t entry=0;
    uint32_t expected=0x14000000u|((uint32_t)((0x3400LL-0x2d72188LL)/4)&0x3ffffffu);
    if(!probe_read(slide+0x102d72188ULL,&entry,4)||entry!=expected)return NO;
    verified=1;record(@"local original match dispatcher version checks passed");return YES;
}

static void match_tick(uint64_t world,uint64_t account) {
    if(!match_verified())return;
    uint64_t match=profile_subsystem(account+0x28,@"AccountMatch");unsigned char state=0;
    if(!match||!probe_read(match+0x30,&state,1)||state!=1)return;
    uint64_t modes=profile_u64(match+0x1e8);int32_t count=profile_i32(match+0x1f0);
    unsigned char first=0;
    // Consume exactly once. A pending local request is original mutable game
    // state, not executable memory or a fabricated server packet.
    *(unsigned char *)(match+0x30)=0;
    if(!modes||count<1||count>16||!probe_read(modes,&first,1)) {
        record(@"local match rejected invalid original mode array");return;
    }
    uint64_t slide=probe_slide();
    uint8_t type=((uint8_t(*)(const void *))(slide+0x102821af4ULL))((void *)modes);
    if(type>1){record([NSString stringWithFormat:@"local match unsupported original race type=%u",type]);return;}
    uint64_t preset=profile_subsystem(account+0x28,@"AccountPreset");
    if(!preset){record(@"local match rejected missing original equipment");return;}
    save_tick(preset);
    NSString *map=@"/Game/ART/Env/Theme_Village/village_I01/Village_I01";
    NSString *kind=type==0?@"SpeedSingleGameMode":@"ItemSingleGameMode";
    NSString *options=[NSString stringWithFormat:@"game=/Script/KartDrift.%@?players=1?ais=3?observers=0",kind];
    unichar map_text[256]={0},option_text[256]={0};
    if(map.length>=256||options.length>=256)return;
    [map getCharacters:map_text range:NSMakeRange(0,map.length)];
    [options getCharacters:option_text range:NSMakeRange(0,options.length)];
    struct LocalMatchString {const unichar *data;int32_t count,capacity;};
    struct LocalMatchString map_value={map_text,(int32_t)map.length+1,(int32_t)map.length+1};
    struct LocalMatchString option_value={option_text,(int32_t)options.length+1,(int32_t)options.length+1};
    uint64_t name=((uint64_t(*)(const void *))(slide+0x105ab8d20ULL))(&map_value);
    record([NSString stringWithFormat:@"original Play local travel mode=%@ selected_modes=%d first_mode=%u players=1 ais=3 NetDriver=0",kind,count,first]);
    ((void(*)(void *,uint64_t,BOOL,const void *))(slide+0x1059ecfd0ULL))((void *)world,name,YES,&option_value);
}
