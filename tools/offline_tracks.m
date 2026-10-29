/* Original track aliases and paths are read from the retained client's table.
   The original selector receives local availability through its own delegates.
   No table data or art is embedded in this source. */
static NSDictionary *track_definitions;
static uint64_t track_account,track_time_attack;
static NSThread *track_game_thread;
static NSString *track_saved_alias;
static NSString *track_race_alias;
static unsigned track_pending_requests;
static atomic_int track_retry_mode;
static void track_complete_request(int kind);

static NSString *track_save_path(void) {
    return [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/offline-track.json"];
}
static BOOL track_verified(void) {
    static int verified=-1;if(verified>=0)return verified;verified=0;
    struct {uint64_t start,end;const char *digest;} checks[]={
        {0x1019c7974ULL,0x1019c79ecULL,"954bcfae0b0838af2e3baf447104f21fdaa0838b2b03ac6bd840a2ceb7d5ae04"},
        {0x1019c9aacULL,0x1019c9c40ULL,"6675dbca532806a1870735360b990b90b6e6c7924282b3a13b8ee7e62fd1c878"}
    };
    for(unsigned i=0;i<sizeof(checks)/sizeof(checks[0]);i++) {
        unsigned char bytes[512],digest[32];char hex[65]={0};size_t length=checks[i].end-checks[i].start;
        if(length>sizeof(bytes)||!probe_read(probe_slide()+checks[i].start,bytes,length))return NO;
        CC_SHA256(bytes,(CC_LONG)length,digest);
        for(unsigned j=0;j<32;j++)snprintf(hex+j*2,3,"%02x",digest[j]);
        if(strcmp(hex,checks[i].digest))return NO;
    }
    verified=1;return YES;
}
static BOOL track_local(uint64_t subsystem) {
    unsigned char debug=0;
    return subsystem==track_time_attack&&track_account&&track_definitions.count&&
        profile_u64(subsystem+0x20)==track_account&&!profile_u64(track_account+0xa30)&&
        probe_read(track_account+0x1a0,&debug,1)&&debug==1&&NSThread.currentThread==track_game_thread;
}
static BOOL track_initialize(uint64_t account,uint64_t tables) {
    if(!track_verified())return NO;
    uint64_t subsystem=profile_subsystem(account+0x28,@"AccountTimeAttack");
    uint64_t row=upgrade_table(tables,@"KtTrackListDef",@"KtClientTrackListDef",72);
    uint64_t entries=profile_u64(row+0x18);int32_t count=profile_i32(row+0x20);
    if(!subsystem||!row||!entries||count<1||count>1024)return NO;
    NSMutableDictionary *definitions=[NSMutableDictionary dictionary];
    for(int32_t i=0;i<count;i++) {
        uint64_t entry=entries+i*352;NSString *alias=profile_string(entry),*soft=probe_fname(entry+0x98);
        int32_t laps=profile_i32(entry+0x10),n=profile_i32(entry+0x20);uint64_t types=profile_u64(entry+0x18);
        if(!alias||!soft||n<0||n>16)return NO;
        BOOL speed=NO,item=NO;
        for(int j=0;j<n;j++){unsigned char type=0;if(!probe_read(types+j,&type,1))return NO;item|=type==1;speed|=type==2;}
        // Random/dummy definitions and special game types are not race maps.
        if((!speed&&!item)||laps<1||laps>99)continue;
        NSString *path=[[soft componentsSeparatedByString:@"."] firstObject];
        if(![path hasPrefix:@"/Game/ART/Env/"]||[path rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"? \n\r\t"]].location!=NSNotFound||definitions[alias])return NO;
        // The row remains owned by the retained table manager for the whole
        // GameInstance. Keep its address only so the original loading widget
        // can read the matching background; no asset data is copied here.
        definitions[alias]=@{@"path":path,@"speed":@(speed),@"item":@(item),@"laps":@(laps),@"row":@(entry)};
    }
    if(!definitions.count)return NO;
    track_account=account;track_time_attack=subsystem;track_game_thread=NSThread.currentThread;track_definitions=definitions;
    NSData *data=[NSData dataWithContentsOfFile:track_save_path()];
    NSDictionary *document=data&&data.length<4096?[NSJSONSerialization JSONObjectWithData:data options:0 error:nil]:nil;
    NSString *saved=[document isKindOfClass:NSDictionary.class]&&[document[@"schema"] isEqual:@1]?document[@"alias"]:nil;
    if([saved isKindOfClass:NSString.class]&&definitions[saved]) {
        // Original FString allocator owns the restored selection's allocation.
        int32_t length=(int32_t)saved.length+1,old_capacity=profile_i32(subsystem+0xa4);
        ((void(*)(void *,int32_t,int32_t))(probe_slide()+0x1019c7974ULL))((void *)(subsystem+0x98),length,old_capacity);
        uint64_t target=profile_u64(subsystem+0x98);
        if(!target||profile_i32(subsystem+0xa4)<length)return NO;
        [saved getCharacters:(unichar *)target range:NSMakeRange(0,saved.length)];((unichar *)target)[saved.length]=0;
        *(int32_t *)(subsystem+0xa0)=length;track_saved_alias=saved;
    }
    record([NSString stringWithFormat:@"local original track catalog unlocked race_maps=%lu restored=%d",(unsigned long)definitions.count,track_saved_alias!=nil]);return YES;
}
static void track_tick(void) {
    if(!track_local(track_time_attack))return;
    // Original widgets set their waiting state after making a request. Deliver
    // the local result on the next game tick, like the original async response.
    unsigned pending=track_pending_requests;track_pending_requests=0;
    for(int kind=0;kind<3;kind++)if(pending&(1u<<kind))track_complete_request(kind);
    NSString *alias=profile_string(track_time_attack+0x98);
    if(!alias||!track_definitions[alias]||[alias isEqualToString:track_saved_alias])return;
    NSDictionary *document=@{@"schema":@1,@"alias":alias};NSData *data=[NSJSONSerialization dataWithJSONObject:document options:NSJSONWritingSortedKeys error:nil];
    if([data writeToFile:track_save_path() options:NSDataWritingAtomic error:nil])track_saved_alias=alias;
}
static NSString *track_match_path(uint8_t type,uint8_t mode) {
    if(!track_local(track_time_attack))return nil;
    NSString *key=type==0?@"speed":@"item",*alias=profile_string(track_time_attack+0x98);
    NSDictionary *definition=alias?track_definitions[alias]:nil;
    if(!definition){record(@"local match requires a valid original track selection");return nil;}
    if(![definition[key] boolValue]) {
        NSString *message=[NSString stringWithFormat:@"所选赛道 %@ 只支持%@。请在原版比赛菜单选择对应模式，或重新选一张支持当前模式的赛道。",alias,[definition[@"speed"] boolValue]?@"竞速赛":@"道具赛"];
        dispatch_async(dispatch_get_main_queue(),^{
            UIViewController *view=UIApplication.sharedApplication.keyWindow.rootViewController;
            while(view.presentedViewController)view=view.presentedViewController;
            if([view isKindOfClass:UIAlertController.class])return;
            UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"赛道与模式不匹配" message:message preferredStyle:UIAlertControllerStyleAlert];
            int target=[definition[@"speed"] boolValue]?(mode>3?mode-3:mode):(mode<4?mode+3:mode);
            NSString *title=[definition[@"speed"] boolValue]?@"改用竞速赛进入":@"改用道具赛进入";
            [alert addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){atomic_store(&track_retry_mode,target);}]];
            [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
            [view presentViewController:alert animated:YES completion:nil];
        });
        record([NSString stringWithFormat:@"local match blocked incompatible selected track=%@ race_type=%u; selection preserved",alias,type]);return nil;
    }
    track_race_alias=alias;
    record([NSString stringWithFormat:@"local selected original track=%@ race_type=%u",alias,type]);return definition[@"path"];
}

static uint64_t track_loading_row(void) {
    NSDictionary *definition=track_race_alias?track_definitions[track_race_alias]:nil;
    uint64_t row=[definition[@"row"] unsignedLongLongValue];
    return row&&profile_string(row)?row:0;
}
// Synchronous native multicast invocation. Locking/compaction follow the
// retained delegate layout so callbacks may remove themselves safely.
static void track_broadcast(uint64_t delegate,const void *value,int argument) {
    int32_t count=profile_i32(delegate+8),lock=profile_i32(delegate+0x14);
    if(count<0||count>512||lock<0||lock>1024)return;
    *(int32_t *)(delegate+0x14)=lock+1;BOOL compact=NO;
    for(int32_t i=count-1;i>=0;i--) {
        uint64_t array=profile_u64(delegate),slot=array+(uint64_t)i*16,object=profile_u64(slot);
        if(!array||!object||!profile_i32(slot+8)){compact=YES;continue;}
        uint64_t function=profile_u64(profile_u64(object)+0x58);
        if(!function){compact=YES;continue;}
        BOOL alive=argument==2?((BOOL(*)(void *))function)((void *)object):argument==1?((BOOL(*)(void *,int32_t))function)((void *)object,0):((BOOL(*)(void *,const void *))function)((void *)object,value);
        if(!alive)compact=YES;
    }
    *(int32_t *)(delegate+0x14)=profile_i32(delegate+0x14)-1;
    if(compact&&!profile_i32(delegate+0x14))((void(*)(void *,BOOL))(probe_slide()+0x1019c9aacULL))((void *)delegate,NO);
}
__attribute__((visibility("default")))
void offline_track_request(uint64_t subsystem,int kind) {
    if(!track_local(subsystem)||kind<0||kind>2)return;
    track_pending_requests|=1u<<kind;
}
static void track_complete_request(int kind) {
    uint64_t subsystem=track_time_attack;
    if(kind==2){
        // A new local profile has no remote seasonal rankings. Mark its empty
        // native record set ready and notify the original page's subscribers.
        *(unsigned char *)(subsystem+0xa8)=1;
        track_broadcast(subsystem+0x30,NULL,2);
        track_broadcast(subsystem+0x48,NULL,2);
        record(@"original time attack records ready locally; no remote rankings");return;
    }
    if(kind==1){track_broadcast(subsystem+0x78,NULL,YES);record(@"original track preparation completed locally");return;}
    NSMutableArray *storage=[NSMutableArray array];NSArray *aliases=[[track_definitions allKeys] sortedArrayUsingSelector:@selector(compare:)];
    NSMutableData *entries=[NSMutableData dataWithLength:aliases.count*16];
    for(NSUInteger i=0;i<aliases.count;i++)save_fstring((unsigned char *)entries.mutableBytes+i*16,aliases[i],storage);
    struct {const void *data;int32_t count,capacity;} value={entries.bytes,(int32_t)aliases.count,(int32_t)aliases.count};
    track_broadcast(subsystem+0x60,&value,NO);
    record([NSString stringWithFormat:@"original track selector local availability aliases=%lu",(unsigned long)aliases.count]);
}
