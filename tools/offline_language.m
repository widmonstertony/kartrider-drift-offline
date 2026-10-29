/* Reapply the retained user's saved culture when local direct travel creates a
   world without the online account-settings bootstrap. */
static uint64_t language_world;
static BOOL language_verified(void) {
    static int verified=-1;if(verified>=0)return verified;verified=0;
    unsigned char bytes[0x14c],digest[32];char hex[65]={0};
    if(!probe_read(probe_slide()+0x102d0c56cULL,bytes,sizeof(bytes)))return NO;
    CC_SHA256(bytes,sizeof(bytes),digest);for(int j=0;j<32;j++)snprintf(hex+j*2,3,"%02x",digest[j]);
    verified=!strcmp(hex,"bda2fe17888d196c5c7b468b3660f063c17458ca07f067b82ab632ba0b4b3d80");return verified;
}
static void language_tick(uint64_t engine,uint64_t world) {
    if(!world||world==language_world||!language_verified())return;
    uint64_t settings=profile_u64(engine+0x228);int index=profile_i32(settings+0x400);
    int count=profile_i32(settings+0x5e8);uint64_t keys=profile_u64(settings+0x5e0);
    if(!settings||!keys||count<1||count>32||index<0||index>=count)return;
    ((void(*)(void *,int))(probe_slide()+0x102d0c56cULL))((void *)settings,index);
    language_world=world;
    record([NSString stringWithFormat:@"reapplied original saved culture index=%d key=%@",index,profile_string(keys+(uint64_t)index*16)]);
}
