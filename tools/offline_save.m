/* Local equipment persistence for the retained 2.71.1 preset layout.
   JSON contains strings and values, never engine pointers or native heaps.
   Restoring uses the original preset deep-copy interface. */
#import <math.h>

static NSDictionary *save_last_snapshot;
static NSSet *save_known_items;
static BOOL save_rejected_file;

static NSString *save_path(void) {
    return [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/offline-profile.json"];
}
static NSString *save_text(uint64_t address) {
    uint64_t data=profile_u64(address);int32_t count=profile_i32(address+8);
    if(!count)return @"";
    if(!data||count<1||count>524288)return nil;
    NSMutableData *buffer=[NSMutableData dataWithLength:(NSUInteger)count*2];
    if(!probe_read(data,buffer.mutableBytes,buffer.length)||((unichar *)buffer.bytes)[count-1])return nil;
    return [[NSString alloc] initWithCharacters:buffer.bytes length:count-1];
}
static NSDictionary *save_snapshot(uint64_t preset) {
    uint64_t map=preset+0x98,data=profile_u64(map),bits=profile_u64(map+0x20);
    int32_t slots=profile_i32(map+8),bit_count=profile_i32(map+0x28);
    if(!data||slots<1||slots>128||bit_count!=slots)return nil;
    if(!bits)bits=map+0x10;
    NSMutableDictionary *equipment=[NSMutableDictionary dictionary];
    for(int32_t i=0;i<slots;i++) {
        uint32_t word=0;if(!probe_read(bits+(i/32)*4,&word,4))return nil;
        if(!(word&(1u<<(i%32))))continue;
        NSString *key=save_text(data+i*40),*value=save_text(data+i*40+16);
        if(!key||!key.length||key.length>64||!value||value.length>127||equipment[key])return nil;
        equipment[key]=value;
    }
    uint64_t livery=map+0x50;NSMutableArray *strings=[NSMutableArray array];
    for(NSNumber *offset in @[@0,@0x10,@0x28]) {
        NSString *value=save_text(livery+offset.unsignedLongLongValue);if(!value)return nil;
        [strings addObject:value];
    }
    uint32_t value=0;int64_t timestamps[2]={0};unsigned char flag=0;
    if(!probe_read(livery+0x20,&value,4)||!probe_read(livery+0x38,timestamps,16)||
       !probe_read(livery+0x48,&flag,1)||flag>1)return nil;
    if(timestamps[0]<0||timestamps[1]<0)return nil;
    return @{@"schema":@2,@"client":@"2.71.1",@"equipment":equipment,
             @"livery":@{@"strings":strings,@"value":@(value),@"timestamps":@[@(timestamps[0]),@(timestamps[1])],@"flag":@(flag)}};
}
static BOOL save_valid(NSDictionary *document) {
    if(![document isKindOfClass:NSDictionary.class]||![document[@"schema"] isEqual:@2]||
       ![document[@"client"] isEqual:@"2.71.1"])return NO;
    NSDictionary *equipment=document[@"equipment"],*livery=document[@"livery"];
    if(![equipment isKindOfClass:NSDictionary.class]||!equipment.count||equipment.count>128||
       ![livery isKindOfClass:NSDictionary.class])return NO;
    NSMutableSet *folded=[NSMutableSet set];
    for(id key in equipment) {
        id value=equipment[key];
        if(![key isKindOfClass:NSString.class]||![value isKindOfClass:NSString.class]||
           ![key length]||[key length]>64||[value length]>127||[folded containsObject:[key lowercaseString]]||
           ([value length]&&![save_known_items containsObject:value]))return NO;
        [folded addObject:[key lowercaseString]];
    }
    NSArray *strings=livery[@"strings"],*timestamps=livery[@"timestamps"];
    if(![strings isKindOfClass:NSArray.class]||strings.count!=3||
       ![timestamps isKindOfClass:NSArray.class]||timestamps.count!=2||
       ![livery[@"value"] isKindOfClass:NSNumber.class]||
       [livery[@"value"] doubleValue]<0||[livery[@"value"] doubleValue]>UINT32_MAX||
       ![livery[@"flag"] isKindOfClass:NSNumber.class]||[livery[@"flag"] unsignedIntegerValue]>1)return NO;
    for(id value in strings)if(![value isKindOfClass:NSString.class]||[value length]>524287)return NO;
    for(id value in timestamps)if(![value isKindOfClass:NSNumber.class]||[value longLongValue]<0||
        CFGetTypeID((__bridge CFTypeRef)value)==CFBooleanGetTypeID()||CFNumberIsFloatType((__bridge CFNumberRef)value))return NO;
    return YES;
}
// Schema 1 recorded the two native FDateTime values as four float bit
// patterns. Recover those exact bits before validating/writing schema 2.
static NSDictionary *save_migrate(id document) {
    if(![document isKindOfClass:NSDictionary.class]||![document[@"schema"] isEqual:@1])return document;
    id old=document[@"livery"],vector=[old isKindOfClass:NSDictionary.class]?old[@"vector"]:nil;
    if(![vector isKindOfClass:NSArray.class]||[vector count]!=4)return nil;
    float bits[4];for(unsigned i=0;i<4;i++){
        if(![vector[i] isKindOfClass:NSNumber.class]||!isfinite([vector[i] floatValue]))return nil;
        bits[i]=[vector[i] floatValue];
    }
    int64_t timestamps[2];memcpy(timestamps,bits,16);
    NSMutableDictionary *livery=[old mutableCopy];[livery removeObjectForKey:@"vector"];
    livery[@"timestamps"]=@[@(timestamps[0]),@(timestamps[1])];
    NSMutableDictionary *result=[document mutableCopy];result[@"schema"]=@2;result[@"livery"]=livery;return result;
}
static void save_fstring(unsigned char *target,NSString *value,NSMutableArray *storage) {
    NSMutableData *utf16=[NSMutableData dataWithLength:(value.length+1)*2];
    [value getCharacters:utf16.mutableBytes range:NSMakeRange(0,value.length)];[storage addObject:utf16];
    struct { const void *data;int32_t count,capacity; } string={utf16.bytes,(int32_t)value.length+1,(int32_t)value.length+1};
    memcpy(target,&string,16);
}
static BOOL save_restore(uint64_t preset) {
    NSData *data=[NSData dataWithContentsOfFile:save_path() options:NSDataReadingMappedIfSafe error:nil];
    if(!data)return NO;
    NSDictionary *document=data.length<=4*1024*1024?[NSJSONSerialization JSONObjectWithData:data options:0 error:nil]:nil;
    BOOL migrated=[document isKindOfClass:NSDictionary.class]&&[document[@"schema"] isEqual:@1];document=save_migrate(document);
    if(!save_valid(document)){save_rejected_file=YES;record(@"local equipment save rejected; retained for recovery");return NO;}
    NSDictionary *equipment=document[@"equipment"],*livery=document[@"livery"];
    NSArray *keys=[[equipment allKeys] sortedArrayUsingSelector:@selector(compare:)];NSUInteger n=keys.count;
    // A temporary, fully allocated original TMap with one hash bucket. The
    // original deep copier owns every allocation made in the destination.
    unsigned char value[160]={0};NSMutableData *entries=[NSMutableData dataWithLength:n*40];
    uint64_t entry_address=(uint64_t)entries.mutableBytes;int32_t count=(int32_t)n,minus_one=-1,one=1,max_bits=128;
    memcpy(value,&entry_address,8);memcpy(value+8,&count,4);memcpy(value+12,&count,4);
    for(NSUInteger i=0;i<n;i++){uint32_t bit=1u<<(i%32);uint32_t word=0;memcpy(&word,value+0x10+(i/32)*4,4);word|=bit;memcpy(value+0x10+(i/32)*4,&word,4);}
    memcpy(value+0x28,&count,4);memcpy(value+0x2c,&max_bits,4);memcpy(value+0x30,&minus_one,4);
    memcpy(value+0x48,&one,4); // bucket zero starts at element zero
    NSMutableArray *storage=[NSMutableArray array];
    for(NSUInteger i=0;i<n;i++) {
        unsigned char *entry=(unsigned char *)entries.mutableBytes+i*40;
        save_fstring(entry,keys[i],storage);save_fstring(entry+16,equipment[keys[i]],storage);
        int32_t next=i+1<n?(int32_t)i+1:-1;memcpy(entry+32,&next,4);
    }
    NSArray *strings=livery[@"strings"],*timestamps=livery[@"timestamps"];
    for(unsigned i=0;i<3;i++)save_fstring(value+0x50+(uint32_t[]){0,0x10,0x28}[i],strings[i],storage);
    uint32_t word=[livery[@"value"] unsignedIntValue];memcpy(value+0x70,&word,4);
    for(unsigned i=0;i<2;i++){int64_t number=[timestamps[i] longLongValue];memcpy(value+0x88+i*8,&number,8);}
    value[0x98]=[livery[@"flag"] unsignedCharValue];
    ((void(*)(void *,const void *))(probe_slide()+0x102d87a60ULL))((void *)preset,value);
    NSDictionary *restored=save_snapshot(preset);
    if(![restored isEqual:document]){record(@"local equipment restoration comparison failed");return NO;}
    save_last_snapshot=migrated?nil:restored;
    record([NSString stringWithFormat:@"local equipment restored slots=%lu original_preset_comparison=1",(unsigned long)n]);
    return YES;
}
static void save_tick(uint64_t preset) {
    NSDictionary *snapshot=save_snapshot(preset);
    if(!snapshot||!save_valid(snapshot)||[snapshot isEqual:save_last_snapshot])return;
    NSData *data=[NSJSONSerialization dataWithJSONObject:snapshot options:NSJSONWritingSortedKeys error:nil];
    if(!data||data.length>4*1024*1024)return;
    // Atomic writes stay on the original game thread. This small file must
    // finish before acknowledging persistence or accepting a later snapshot.
    NSFileManager *files=NSFileManager.defaultManager;
    [files createDirectoryAtPath:save_path().stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
    if(save_rejected_file&&[files fileExistsAtPath:save_path()]) {
        NSString *backup=[save_path() stringByAppendingFormat:@".rejected-%@",NSUUID.UUID.UUIDString];
        if(![files copyItemAtPath:save_path() toPath:backup error:nil])return;
        save_rejected_file=NO;
    }
    NSError *error=nil;
    if(![data writeToFile:save_path() options:NSDataWritingAtomic error:&error]) {
        record([NSString stringWithFormat:@"local equipment save failed error=%@",error]);return;
    }
    save_last_snapshot=snapshot;
    record([NSString stringWithFormat:@"local equipment saved slots=%lu bytes=%lu",(unsigned long)[snapshot[@"equipment"] count],(unsigned long)data.length]);
}
