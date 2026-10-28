/* Runs inside the original component's native descriptor initialization. */
__attribute__((visibility("default")))
uint64_t offline_race_preset(uint64_t component) {
    uint64_t owner=profile_u64(component+0xa0),vtable=profile_u64(owner),fn=profile_u64(vtable+0x628);
    if(!owner||!fn)return 0;
    uint64_t pawnClass=((uint64_t(*)(void))(probe_slide()+0x103ae241cULL))();
    uint64_t state=((uint64_t(*)(void *,void *))fn)((void *)owner,(void *)pawnClass);
    if(!state)return 0;
    uint64_t presetClass=((uint64_t(*)(void))(probe_slide()+0x1037a5868ULL))();
    uint64_t preset=((uint64_t(*)(void *,void *))(probe_slide()+0x102e75c9cULL))((void *)component,(void *)presetClass);
    uint64_t account=profile_u64(preset+0x20);unsigned char debug=0;
    if(!preset||!account||profile_u64(account+0xa30)||!probe_read(account+0x1a0,&debug,1)||debug!=1)return 0;
    int slot=profile_i32(state+0x168);unsigned char ai=0;if(!probe_read(state+0x321,&ai,1))return 0;
#if defined(OFFLINE_UNLOCK_LOCAL_CATALOG) && defined(OFFLINE_LOCAL_UPGRADES)
    if(ai&&account==upgrade_account&&NSThread.currentThread==upgrade_game_thread&&slot>0&&slot<ai_presets.count)
        return (uint64_t)ai_presets[slot].bytes;
#endif
    return !ai&&slot==0&&profile_i32(preset+0xa0)>0?preset+0x98:0;
}
