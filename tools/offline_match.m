/* Experimental original Play request consumer. Optional original track
   selection replaces the fixed initial Village map.
   Runs only inside profile_initialize on the original game thread. */

static BOOL match_verified(void) {
    static int verified=-1;
    if(verified>=0)return verified;
    verified=0;uint64_t slide=probe_slide();
    struct {uint64_t offset;size_t size;const char *digest;} checks[]={
        {0x5ab8d20,0x40,"c143e3496716b5986c1c03eaedc6f7f177d62abb532377f05e97ed107284735f"},
        {0x2821af4,0x80,"9c03ab5b50ef0439fa233a1c6229670b45b5d529e066de2088d24361bb173071"},
        {0x2d7262c,0x114,"eae563b1f03155fef05204cec6deefceb2617b635dbe9197e81179ca04c481b6"},
        {0x2e80668,0x40,"4989659cf1dde1055f9b2be89f88c39dca7be0733a3fd6f490413768a19fce51"},
        {0x2e82060,0x118,"9f3f1cf4307a8f3f1fa64f136d6f50cfcbcbc3d4064cca008ff6e20caa76e9a0"}
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
    if(!match||!probe_read(match+0x30,&state,1))return;
    unsigned char retry=0;
#ifdef OFFLINE_LOCAL_TRACKS
    retry=(unsigned char)atomic_exchange(&track_retry_mode,0);
#endif
    if(state!=1&&!retry)return;
    uint64_t modes=profile_u64(match+0x1e8);int32_t count=profile_i32(match+0x1f0);
    unsigned char first=0;
    if(retry){modes=(uint64_t)&retry;count=1;}
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
#ifdef OFFLINE_LOCAL_TRACKS
    map=track_match_path(type,first);
    if(!map){record(@"local match rejected unavailable selected track");return;}
#endif
    // Native RaceMode values: speed solo/duo/squad=1/2/3, item=4/5/6.
    // Keep the original menu selection instead of collapsing every request.
    if(first<1||first>6){record(@"local match rejected unsupported original team mode");return;}
    int team_size=(first==3||first==6)?4:(first==2||first==5)?2:1;
    BOOL team=team_size>1;
#ifndef OFFLINE_LOCAL_TEAMS
    if(team){record(@"local team mode requires the matching native team patch");return;}
#endif
    int racers=4;
#ifdef OFFLINE_LOBBY_CONTROLS
    racers=atomic_load(&lobby_racer_count);if(racers!=4&&racers!=8)return;
#endif
    int ais=team?team_size*2-1:racers-1;
#if defined(OFFLINE_UNLOCK_LOCAL_CATALOG) && defined(OFFLINE_LOCAL_UPGRADES)
    if(!ai_prepare_roster(ais+1,preset)){record(@"local match rejected invalid AI appearance roster");return;}
#endif
    NSString *kind=type==0?(team?@"SpeedTeamGameMode":@"SpeedSingleGameMode"):(team?@"ItemTeamGameMode":@"ItemSingleGameMode");
    NSString *options=[NSString stringWithFormat:@"game=/Script/KartDrift.%@?players=1?ais=%d?observers=0?team=%d",kind,ais,team?2:0];
    unichar map_text[256]={0},option_text[256]={0};
    if(map.length>=256||options.length>=256)return;
    [map getCharacters:map_text range:NSMakeRange(0,map.length)];
    [options getCharacters:option_text range:NSMakeRange(0,options.length)];
    struct LocalMatchString {const unichar *data;int32_t count,capacity;};
    struct LocalMatchString map_value={map_text,(int32_t)map.length+1,(int32_t)map.length+1};
    struct LocalMatchString option_value={option_text,(int32_t)options.length+1,(int32_t)options.length+1};
    uint64_t name=((uint64_t(*)(const void *))(slide+0x105ab8d20ULL))(&map_value);
    record([NSString stringWithFormat:@"original Play local travel mode=%@ selected_modes=%d first_mode=%u players=1 ais=%d team_size=%d NetDriver=0",kind,count,first,ais,team_size]);
#ifdef OFFLINE_LOCAL_TRACKS
    uint64_t traveler=profile_subsystem(profile_u64(world+0x180)+0xe0,@"KdTraveler");
    if(traveler&&track_race_alias) {
        // The original travel path owns its loading widget, transition, async
        // preload handles and eventual OpenLevel. Direct OpenLevel leaves the
        // old matching screen frozen throughout the first asset/Metal load.
        NSString *mode=type==0?(team?@"SpeedTeam":@"SpeedSingle"):(team?@"ItemTeam":@"ItemSingle");
        unsigned char mode_string[16]={0},alias_string[16]={0};
        NSMutableArray *storage=[NSMutableArray array];
        save_fstring(mode_string,mode,storage);save_fstring(alias_string,track_race_alias,storage);
        BOOL accepted=((BOOL(*)(void *,const void *,const void *,uint64_t,BOOL,const void *,BOOL))(slide+0x102e80668ULL))((void *)traveler,mode_string,alias_string,name,YES,&option_value,YES);
        record([NSString stringWithFormat:@"original local loading transition accepted=%d",accepted]);
        if(accepted)return;
    }
#endif
    ((void(*)(void *,uint64_t,BOOL,const void *))(slide+0x1059ecfd0ULL))((void *)world,name,YES,&option_value);
}
