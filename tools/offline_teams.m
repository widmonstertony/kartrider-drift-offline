/* Keep native team rules, items, scoring and results. Only local slot-to-team
   assignment and the absent result-style factory are supplied here. */
static uint64_t local_race_world(void) {
    uint64_t engine=profile_u64(probe_slide()+0x108b0b288ULL);
    if(!engine||profile_i32(engine+0xc50)!=1)return 0;
    uint64_t world=profile_u64(profile_u64(profile_u64(engine+0xc48))+0x280);
    return world&&!profile_u64(world+0x38)?world:0;
}
__attribute__((visibility("default")))
int32_t offline_local_team_index(uint64_t rule,uint64_t state,int32_t slot,int32_t original) {
    uint64_t world=local_race_world();unsigned char debug=0;
    if(!world||!upgrade_account||NSThread.currentThread!=upgrade_game_thread||
       profile_u64(upgrade_account+0xa30)||!probe_read(upgrade_account+0x1a0,&debug,1)||debug!=1||
       profile_u64(rule+0xa0)!=profile_u64(world+0x118)||profile_i32(state+0x168)!=slot||
       profile_i32(rule+0x130)!=1||profile_i32(rule+0x13c)!=2)return original;
    int32_t ais=profile_i32(rule+0x138);
    if((ais!=3&&ais!=7)||slot<0||slot>ais)return original;
    NSString *kind=probe_name(profile_u64(profile_u64(world+0x118)+0x10));
    if(![@[@"SpeedTeamGameMode",@"ItemTeamGameMode"] containsObject:kind])return original;
    // The original test path puts every bot on team 2. Alternate local slots
    // so the retained team rules receive balanced 2v2 / 4v4 teams.
    return slot%2+1;
}
__attribute__((visibility("default")))
uint64_t offline_local_result_factory(void) {
    uint64_t world=local_race_world();if(!world)return 0;
    NSString *kind=probe_name(profile_u64(profile_u64(world+0x118)+0x10));
    uint64_t offset=0;
    if([kind isEqualToString:@"SpeedSingleGameMode"])offset=0x280aab4;
    else if([kind isEqualToString:@"ItemSingleGameMode"])offset=0x2808228;
    else if([kind isEqualToString:@"SpeedTeamGameMode"])offset=0x280c5d4;
    else if([kind isEqualToString:@"ItemTeamGameMode"])offset=0x2809d20;
    return offset?probe_slide()+0x100000000ULL+offset:0;
}
