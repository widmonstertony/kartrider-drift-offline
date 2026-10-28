/* Local custom designs, using the original design codec and owning caches.
   Files contain versioned design strings, never native pointers or textures. */
static NSMutableDictionary *livery_records;
static uint64_t livery_account;
static NSThread *livery_thread;
static BOOL livery_rejected_save;
static NSString *livery_path(void) {return [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/offline-liveries.json"];}
static BOOL livery_local(uint64_t account) {
    unsigned char debug=0;
    return account&&account==livery_account&&NSThread.currentThread==livery_thread&&
        !profile_u64(account+0xa30)&&probe_read(account+0x1a0,&debug,1)&&debug==1;
}
static BOOL livery_write_string(uint64_t target,NSString *text) {
    if(!text||text.length>1024*1024)return NO;
    int32_t length=(int32_t)text.length+1,capacity=profile_i32(target+12);
    ((void(*)(void *,int32_t,int32_t))(probe_slide()+0x1019c7974ULL))((void *)target,length,capacity);
    uint64_t data=profile_u64(target);
    if(!data||profile_i32(target+12)<length)return NO;
    [text getCharacters:(unichar *)data range:NSMakeRange(0,text.length)];((unichar *)data)[text.length]=0;
    *(int32_t *)(target+8)=length;return YES;
}
static uint32_t livery_hash(NSString *key) {
    uint32_t hash=0,table[256]={0};
    if(!probe_read(probe_slide()+0x1086a6b8cULL,table,sizeof(table)))return 0;
    for(NSUInteger i=0;i<key.length;i++) {
        unichar ch=[key characterAtIndex:i];if(ch>='a'&&ch<='z')ch-=32;
        hash=(hash>>8)^table[(hash^ch)&255];hash=(hash>>8)^table[(hash^(ch>>8))&255];
    }
    return hash;
}
static BOOL livery_document_valid(id document) {
    if(![document isKindOfClass:NSDictionary.class]||![document[@"schema"] isEqual:@1]||
       ![document[@"client"] isEqual:@"2.71.1"]||![document[@"designs"] isKindOfClass:NSDictionary.class]||
       [document[@"designs"] count]>100)return NO;
    NSDictionary *records=document[@"designs"];
    for(id key in records) {
        NSDictionary *record=records[key];NSScanner *scanner=[key isKindOfClass:NSString.class]?[NSScanner scannerWithString:key]:nil;int identifier=0;
        if(!scanner||![scanner scanInt:&identifier]||!scanner.isAtEnd||identifier<1||identifier==INT32_MAX||
           ![[NSString stringWithFormat:@"%d",identifier] isEqual:key]||![record isKindOfClass:NSDictionary.class])return NO;
        NSString *uid=record[@"uid"],*kart=record[@"kart"],*data=record[@"data"];
        if(![uid isKindOfClass:NSString.class]||![[NSUUID alloc] initWithUUIDString:uid]||
           ![kart isKindOfClass:NSString.class]||![save_known_items containsObject:kart]||
           ![data isKindOfClass:NSString.class]||!data.length||data.length>1024*1024||
           ![record[@"created"] isKindOfClass:NSNumber.class]||[record[@"created"] longLongValue]<0)return NO;
    }
    return YES;
}
static BOOL livery_save(NSDictionary *records) {
    NSDictionary *document=@{@"schema":@1,@"client":@"2.71.1",@"designs":records};
    if(!livery_document_valid(document))return NO;
    NSData *data=[NSJSONSerialization dataWithJSONObject:document options:NSJSONWritingSortedKeys error:nil];
    if(!data||data.length>32*1024*1024)return NO;
    NSFileManager *files=NSFileManager.defaultManager;
    if(livery_rejected_save&&[files fileExistsAtPath:livery_path()]) {
        if(![files copyItemAtPath:livery_path() toPath:[livery_path() stringByAppendingFormat:@".rejected-%@",NSUUID.UUID.UUIDString] error:nil])return NO;
        livery_rejected_save=NO;
    }
    return [data writeToFile:livery_path() options:NSDataWritingAtomic error:nil];
}
static uint64_t livery_install(NSString *identifier,NSDictionary *record) {
    unsigned char key[16]={0},uid[16]={0},data[16]={0};NSMutableArray *storage=[NSMutableArray array];
    save_fstring(key,identifier,storage);save_fstring(uid,record[@"uid"],storage);save_fstring(data,record[@"data"],storage);
    uint64_t requester=profile_u64(profile_u64(livery_account+0x170)+0x178);
    if(!requester||![probe_name(profile_u64(requester+0x10)) isEqualToString:@"LiveryServerRequester"])return 0;
    uint64_t cache=((uint64_t(*)(void *,const void *))(probe_slide()+0x102de698cULL))((void *)requester,uid);
    if(!cache||!((BOOL(*)(int,const void *,void *))(probe_slide()+0x102a28c94ULL))(5,data,(void *)(cache+0x28)))return 0;
    *(int32_t *)(cache+0x20)=5;*(unsigned char *)cache=0;
    uint64_t value=((uint64_t(*)(void *,uint32_t,const void *))(probe_slide()+0x102e60a68ULL))((void *)(livery_account+0x698),livery_hash(identifier),key);
    if(!value||!livery_write_string(value,identifier)||!livery_write_string(value+0x10,record[@"uid"])||
       !livery_write_string(value+0x28,record[@"kart"]))return 0;
    *(int32_t *)(value+0x20)=5;*(int64_t *)(value+0x38)=[record[@"created"] longLongValue];
    *(int64_t *)(value+0x40)=0;*(unsigned char *)(value+0x48)=0;
    return value;
}
static BOOL livery_initialize(uint64_t account) {
    livery_account=account;livery_thread=NSThread.currentThread;
    NSData *data=[NSData dataWithContentsOfFile:livery_path()];
    id document=data&&data.length<=32*1024*1024?[NSJSONSerialization JSONObjectWithData:data options:0 error:nil]:nil;
    BOOL valid=livery_document_valid(document);livery_rejected_save=data&&!valid;
    livery_records=valid?[document[@"designs"] mutableCopy]:[NSMutableDictionary dictionary];
    for(NSString *identifier in livery_records)if(!livery_install(identifier,livery_records[identifier]))return NO;
    record([NSString stringWithFormat:@"local custom designs restored=%lu rejected_save=%d",(unsigned long)livery_records.count,livery_rejected_save]);return YES;
}
static void livery_complete(uint64_t delegate,int32_t result,uint64_t value) {
    uint64_t object=profile_u64(delegate),fn=profile_u64(profile_u64(object)+0x58);unsigned char empty[80]={0};int32_t status[4]={result,0,0,0};
    if(object&&fn&&profile_i32(delegate+8))((BOOL(*)(void *,const int32_t *,const void *))fn)((void *)object,status,value?(void *)value:empty);
}
__attribute__((visibility("default")))
void offline_livery_request(uint64_t account,int32_t identifier,uint64_t design,uint64_t delegate,int operation) {
    if(!livery_local(account)||operation<0||operation>2){livery_complete(delegate,1,0);return;}
    NSString *key=[NSString stringWithFormat:@"%d",identifier];NSDictionary *old=livery_records[key];
    if(operation==1) {
        if(!old){livery_complete(delegate,1,0);return;}
        NSMutableDictionary *next=[livery_records mutableCopy];[next removeObjectForKey:key];
        if(!livery_save(next)){livery_complete(delegate,1,0);return;}
        unsigned char string[16]={0},deleted[80]={0};NSMutableArray *storage=[NSMutableArray array];save_fstring(string,key,storage);
        save_fstring(deleted,key,storage);save_fstring(deleted+0x10,old[@"uid"],storage);save_fstring(deleted+0x28,old[@"kart"],storage);
        int32_t revision=5;int64_t created=[old[@"created"] longLongValue];memcpy(deleted+0x20,&revision,4);memcpy(deleted+0x38,&created,8);
        ((int(*)(void *,const void *))(probe_slide()+0x102e69a38ULL))((void *)(account+0x698),string);
        uint64_t preset=profile_subsystem(account+0x28,@"AccountPreset");
        if(preset)((void(*)(void *,const void *))(probe_slide()+0x102d88140ULL))((void *)preset,string);
        livery_records=next;
        ((void(*)(void *,const void *))(probe_slide()+0x101a34310ULL))((void *)(account+0x678),&identifier);
        if(preset)save_tick(preset);livery_complete(delegate,0,(uint64_t)deleted);record(@"local custom design deleted");return;
    }
    if(identifier<0||(!old&&identifier!=0)||!design){livery_complete(delegate,1,0);return;}
    if(!identifier) {
        if(livery_records.count>=100){livery_complete(delegate,2,0);return;}
        identifier=1;for(NSString *existing in livery_records)identifier=MAX(identifier,existing.intValue+1);
        if(identifier<1){livery_complete(delegate,1,0);return;}key=[NSString stringWithFormat:@"%d",identifier];
    }
    unsigned char encoded[16]={0};
    BOOL encoded_ok=((BOOL(*)(const void *,void *))(probe_slide()+0x102f4c838ULL))((void *)design,encoded);
    NSString *text=encoded_ok?save_text((uint64_t)encoded):nil;
    uint64_t allocation=0;memcpy(&allocation,encoded,8);
    if(allocation)((void(*)(void *))(probe_slide()+0x103cf5d48ULL))((void *)allocation);
    uint64_t registry=profile_u64(account+0x318),getter=profile_u64(profile_u64(registry)+0x290);
    // A nontrivial C++ FString uses x8 indirect return. A 24-byte C
    // aggregate forces that same AAPCS64 convention (only 16 bytes are read).
    struct LocalLiveryString {uint64_t data;int32_t count,capacity;uint64_t unused;};
    struct LocalLiveryString kart_value={0};
    if(registry&&getter)kart_value=((struct LocalLiveryString(*)(void *,int32_t))getter)((void *)registry,profile_i32(design));
    NSString *kart=save_text((uint64_t)&kart_value);
    if(kart_value.data)((void(*)(void *))(probe_slide()+0x103cf5d48ULL))((void *)kart_value.data);
    if(!text||![save_known_items containsObject:kart]){livery_complete(delegate,1,0);record(@"local custom design rejected invalid native codec/body");return;}
    int64_t created=old?[old[@"created"] longLongValue]:(int64_t)(NSDate.date.timeIntervalSince1970*10000000)+621355968000000000LL;
    NSDictionary *entry=@{@"uid":old?old[@"uid"]:NSUUID.UUID.UUIDString,@"kart":kart,@"data":text,@"created":@(created)};
    NSMutableDictionary *next=[livery_records mutableCopy];next[key]=entry;
    if(!livery_save(next)){livery_complete(delegate,1,0);record(@"local custom design save failed");return;}
    uint64_t value=livery_install(key,entry);
    if(!value){livery_complete(delegate,1,0);record(@"local custom design saved; native cache restoration failed");return;}
    livery_records=next;uint64_t preset=profile_subsystem(account+0x28,@"AccountPreset");
    if(preset){((void(*)(void *,const void *))(probe_slide()+0x102d87e70ULL))((void *)preset,(void *)value);save_tick(preset);}
    ((void(*)(void *,const void *))(probe_slide()+0x101a34310ULL))((void *)(account+0x668),&identifier);
    record([NSString stringWithFormat:@"local custom design saved id=%d operation=%d",identifier,operation]);
    livery_complete(delegate,0,value);
}
