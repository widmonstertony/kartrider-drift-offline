/* Hardware input adapter for the retained native iOS input queue.
   Keyboards and extended gamepads (including form-fitting Backbone devices)
   feed the original axis/action bindings and physics. */
#import <GameController/GameController.h>
#import <stdatomic.h>
static uint64_t keyboard_interface;
static NSRecursiveLock *keyboard_lock;
static NSMutableDictionary<NSNumber *,NSNumber *> *keyboard_held;
static GCKeyboardInput *keyboard_input;
static GCKeyboardValueChangedHandler keyboard_handler;
static NSMutableArray<NSArray *> *keyboard_pending;
static NSMutableSet<NSNumber *> *keyboard_native_held;
static uint64_t keyboard_world,keyboard_player_input;
static NSMutableDictionary<NSNumber *,NSMutableData *> *keyboard_keys;
static BOOL keyboard_reported_event;
static __weak GCController *controller_input;
static BOOL controller_camera_down;


static BOOL keyboard_in_race(void) {
    uint64_t engine=0,contexts=0,context=0,world=0,mode=0,cls=0;int count=0;
    if(!probe_read(probe_slide()+0x108b0b288ULL,&engine,8)||
       !probe_read(engine+0xc50,&count,4)||count!=1||!probe_read(engine+0xc48,&contexts,8)||
       !probe_read(contexts,&context,8)||!probe_read(context+0x280,&world,8)||
       !probe_read(world+0x118,&mode,8)||!probe_read(mode+0x10,&cls,8))return NO;
    return [@[@"SpeedSingleGameMode",@"ItemSingleGameMode",@"SpeedTeamGameMode",@"ItemTeamGameMode"] containsObject:probe_name(cls)];
}
static NSInteger keyboard_alias(NSInteger code) {
    if(!keyboard_in_race())return code;
    // USB HID usages, as used by GCKeyCode. Keep simultaneous aliases held
    // until their last physical key is released.
    switch(code){
        case 26:return 82; // W -> Up
        case 22:return 81; // S -> Down
        case 4:return 80;  // A -> Left
        case 7:return 79;  // D -> Right
        case 44:case 229:return 225; // Space/right Shift -> left Shift (drift)
        case 29:case 228:return 224; // Z/right Control -> use item/boost
        case 27:case 230:return 226; // X/right Alt -> change item slot
        default:return code;
    }
}
static BOOL keyboard_emit(NSInteger code,BOOL pressed) {
    if(!keyboard_interface||code<0||code>255)return NO;
    if(keyboard_in_race()) {
        // GCKeyboard runs on the UI thread. The original input bindings must
        // receive events on the engine thread, after Slate has routed UI input.
        if(keyboard_pending.count<512)[keyboard_pending addObject:@[@(code),@(pressed)]];
        return YES;
    }
    unsigned char editing=0;probe_read(probe_slide()+0x108a81478ULL,&editing,1);
    if(editing&&pressed)return NO;
    if(editing) {
        // Native key-down handling intentionally pauses for text entry. Key-up
        // must still reach the same queue when focus is lost or a keyboard is
        // unplugged, otherwise the original axis can remain held forever.
        uint32_t key=((uint32_t(*)(NSInteger))(probe_slide()+0x104072518ULL))(code);
        uint64_t mutex=keyboard_interface+0x1c0,array=keyboard_interface+0x200;
        ((int(*)(void *))(probe_slide()+0x1065b2facULL))((void *)mutex);
        int32_t count=0,capacity=0;probe_read(array+8,&count,4);probe_read(array+12,&capacity,4);
        BOOL queued=NO;
        if(count>=0&&count<4096&&capacity>=0&&capacity<=65536){
            *(int32_t *)(array+8)=count+1;
            if(count>=capacity)((void(*)(void *,int32_t))(probe_slide()+0x10407ca2cULL))((void *)array,count);
            uint64_t data=0;probe_read(array,&data,8);
            if(data){((uint64_t *)data)[count]=11ULL|((uint64_t)key<<32);queued=YES;}
            else *(int32_t *)(array+8)=count;
        }
        ((int(*)(void *))(probe_slide()+0x1065b2fc4ULL))((void *)mutex);return queued;
    }
    // The original handler only reads its captured input-interface pointer.
    struct {uint64_t header[4];uint64_t interface;} capture={{0},keyboard_interface};
    ((void(*)(const void *,void *,void *,NSInteger,BOOL))(probe_slide()+0x10407373cULL))(&capture,NULL,NULL,code,pressed);return YES;
}
static void keyboard_release(void) {
    [keyboard_lock lock];
    for(NSNumber *key in [NSSet setWithArray:keyboard_held.allValues])keyboard_emit(key.integerValue,NO);
    [keyboard_held removeAllObjects];[keyboard_lock unlock];
}
static void keyboard_source_changed(NSNumber *physical,NSInteger logical,BOOL pressed) {
    [keyboard_lock lock];
    NSNumber *held=keyboard_held[physical];
    if(pressed&&!held&&UIApplication.sharedApplication.applicationState==UIApplicationStateActive) {
        NSNumber *mapped=@(logical);BOOL already=[keyboard_held.allValues containsObject:mapped];
        if(already||keyboard_emit(logical,YES))keyboard_held[physical]=mapped;
    }else if(!pressed&&held){
        [keyboard_held removeObjectForKey:physical];
        if(![keyboard_held.allValues containsObject:held])keyboard_emit(held.integerValue,NO);
    }
    [keyboard_lock unlock];
}
static void keyboard_changed(GCKeyboardInput *input,GCDeviceButtonInput *button,GCKeyCode code,BOOL pressed) {
    keyboard_source_changed(@(code),keyboard_alias(code),pressed);
}
static void controller_release(void) {
    NSArray *sources=[keyboard_held.allKeys filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSNumber *key,NSDictionary *bindings){return key.integerValue>=0x1000;}]];
    for(NSNumber *source in sources)keyboard_source_changed(source,keyboard_held[source].integerValue,NO);
    controller_camera_down=NO;
}
static void controller_update(void) {
    GCController *found=nil;
    for(GCController *candidate in GCController.controllers)if(candidate.extendedGamepad){found=candidate;break;}
    if(found!=controller_input){controller_release();controller_input=found;if(found)record([NSString stringWithFormat:@"extended game controller attached vendor=%@ category=%@",found.vendorName,found.productCategory]);}
    GCExtendedGamepad *pad=found.extendedGamepad;
    if(!pad||UIApplication.sharedApplication.applicationState!=UIApplicationStateActive||!keyboard_in_race()){
        controller_release();return;
    }
    float x=pad.leftThumbstick.xAxis.value,y=pad.leftThumbstick.yAxis.value;
    BOOL states[]={
        pad.dpad.up.isPressed||y>0.28f||pad.rightTrigger.value>0.12f,
        pad.dpad.down.isPressed||y<-0.28f||pad.leftTrigger.value>0.12f,
        pad.dpad.left.isPressed||x<-0.22f,
        pad.dpad.right.isPressed||x>0.22f,
        pad.buttonA.isPressed||pad.rightShoulder.isPressed,
        pad.buttonX.isPressed||pad.leftShoulder.isPressed,
        pad.buttonB.isPressed,
        pad.buttonY.isPressed,
        pad.buttonMenu.isPressed||pad.buttonOptions.isPressed
    };
    NSInteger logical[]={82,81,80,79,225,224,226,21,41};
    for(int i=0;i<9;i++)keyboard_source_changed(@(0x1000+i),logical[i],states[i]);
#ifdef OFFLINE_LOCAL_TRACKS
    BOOL camera=pad.rightThumbstickButton.isPressed;
    if(camera&&!controller_camera_down)camera_toggle();
    controller_camera_down=camera;
#endif
}
static void keyboard_attach(void) {
    GCKeyboardInput *input=GCKeyboard.coalescedKeyboard.keyboardInput;
    if(input==keyboard_input&&input.keyChangedHandler==keyboard_handler)return;
    keyboard_release();
    // Replace only the retained game's handler or our own handler. An
    // unrelated handler is left alone rather than silently stealing input.
    id previous=input.keyChangedHandler;
    uint64_t invoke=0;
    if(previous)probe_read((uint64_t)(__bridge void *)previous+0x10,&invoke,8);
    if(previous&&previous!=keyboard_handler&&invoke!=probe_slide()+0x10407373cULL)return;
    keyboard_input=input;
    if(input){input.keyChangedHandler=keyboard_handler;record(@"hardware keyboard attached to original input queue");}
}
static void keyboard_initialize(void);
__attribute__((visibility("default")))
void offline_keyboard_interface(uint64_t interface,BOOL destroying) {
    keyboard_initialize();[keyboard_lock lock];
    if(destroying){if(keyboard_interface==interface){keyboard_release();keyboard_interface=0;}}
    else{keyboard_release();keyboard_interface=interface;}
    [keyboard_lock unlock];
    if(!destroying)dispatch_async(dispatch_get_main_queue(),^{keyboard_attach();});
}
static void keyboard_initialize(void) {
    static dispatch_once_t once;dispatch_once(&once,^{
    keyboard_lock=[NSRecursiveLock new];keyboard_held=[NSMutableDictionary dictionary];
    keyboard_pending=[NSMutableArray array];keyboard_native_held=[NSMutableSet set];keyboard_keys=[NSMutableDictionary dictionary];
    keyboard_handler=^(GCKeyboardInput *input,GCDeviceButtonInput *button,GCKeyCode code,BOOL pressed){keyboard_changed(input,button,code,pressed);};
    });
}

static NSString *keyboard_key_name(NSInteger code) {
    switch(code){
        case 82:return @"Up";case 81:return @"Down";case 80:return @"Left";case 79:return @"Right";
        case 225:return @"LeftShift";case 224:return @"LeftControl";case 226:return @"LeftAlt";
        case 21:return @"R";case 41:return @"Escape";
        default:return nil;
    }
}
static BOOL keyboard_engine_verified(void) {
    static int valid=-1;if(valid>=0)return valid;valid=0;
    unsigned char bytes[956],digest[32];char hex[65]={0};
    if(!probe_read(probe_slide()+0x105ef9d80ULL,bytes,sizeof(bytes)))return NO;
    CC_SHA256(bytes,sizeof(bytes),digest);for(int j=0;j<32;j++)snprintf(hex+j*2,3,"%02x",digest[j]);
    valid=!strcmp(hex,"0063e89a5792c6dc237d902df71f34827c9817f0b875b94cae80164e2de32c56");return valid;
}
static BOOL keyboard_engine_emit(NSInteger code,BOOL down) {
    NSString *name=keyboard_key_name(code);if(!name||!keyboard_player_input)return NO;
    NSNumber *index=@(code);NSMutableData *key=keyboard_keys[index];
    if(!key){
        unichar text[32]={0};[name getCharacters:text range:NSMakeRange(0,name.length)];
        struct {const unichar *data;int32_t count,capacity;} string={text,(int32_t)name.length+1,(int32_t)name.length+1};
        key=[NSMutableData dataWithLength:24];
        *(uint64_t *)key.mutableBytes=((uint64_t(*)(const void *))(probe_slide()+0x105ab8d20ULL))(&string);
        keyboard_keys[index]=key;
    }
    // FKey is a nontrivial 24-byte C++ value, passed indirectly in x1.
    // EInputEvent is w2 and AmountDepressed is s0 in the ARM64 ABI.
    ((BOOL(*)(void *,const void *,int,float,BOOL))(probe_slide()+0x105ef9d80ULL))((void *)keyboard_player_input,key.bytes,down?0:1,down?1.f:0.f,NO);
    if(down)[keyboard_native_held addObject:index];else[keyboard_native_held removeObject:index];
    if(!keyboard_reported_event){record(@"hardware keyboard event delivered to original UPlayerInput on game thread");keyboard_reported_event=YES;}
    return YES;
}
static void keyboard_game_tick(void) {
    if(!keyboard_engine_verified())return;
    [keyboard_lock lock];
    if(!keyboard_in_race()) {
        keyboard_world=0;keyboard_player_input=0;[keyboard_native_held removeAllObjects];[keyboard_pending removeAllObjects];
        [keyboard_lock unlock];return;
    }
    uint64_t engine=profile_u64(probe_slide()+0x108b0b288ULL);
    uint64_t world=profile_u64(profile_u64(profile_u64(engine+0xc48))+0x280);
    if(profile_u64(world+0x38)){[keyboard_lock unlock];return;}
    uint64_t pi=keyboard_world==world?keyboard_player_input:0;
    if(!pi||profile_u64(profile_u64(pi)+0x278)!=probe_slide()+0x105ef9d80ULL) {
        pi=0;uint64_t level=profile_u64(world+0x30),actors=profile_u64(level+0x98);int count=profile_i32(level+0xa0);
        for(int i=0;i<count&&count<4096;i++) {
            uint64_t actor=profile_u64(actors+i*8),candidate=profile_u64(actor+0x348);
            if(candidate&&profile_u64(profile_u64(candidate)+0x278)==probe_slide()+0x105ef9d80ULL){pi=candidate;break;}
        }
    }
    if(!pi){[keyboard_lock unlock];return;}
    if(pi!=keyboard_player_input||world!=keyboard_world) {
        keyboard_world=world;keyboard_player_input=pi;[keyboard_native_held removeAllObjects];
        // Keys held during the loading screen must work when possession ends.
        for(NSNumber *physical in keyboard_held.allKeys) {
            NSNumber *logical=@(keyboard_alias(physical.integerValue));keyboard_held[physical]=logical;
            if(![keyboard_native_held containsObject:logical])keyboard_engine_emit(logical.integerValue,YES);
        }
        record(@"hardware keyboard connected to original local race PlayerInput");
    }
    NSArray *events=[keyboard_pending copy];[keyboard_pending removeAllObjects];
    for(NSArray *event in events) {
        BOOL down=[event[1] boolValue],held=[keyboard_native_held containsObject:event[0]];
        if(down!=held)keyboard_engine_emit([event[0] integerValue],down);
    }
    [keyboard_lock unlock];
}
@interface UIApplication (OfflineKeyboardEvents)
- (void)offline_keyboard_sendEvent:(UIEvent *)event;
@end
@implementation UIApplication (OfflineKeyboardEvents)
- (void)offline_keyboard_sendEvent:(UIEvent *)event {
    if(event.type==UIEventTypePresses&&keyboard_in_race()) {
        for(UIPress *press in ((UIPressesEvent *)event).allPresses) {
            if(!press.key)continue;
            if(press.phase==UIPressPhaseBegan)keyboard_changed(nil,nil,(GCKeyCode)press.key.keyCode,YES);
            else if(press.phase==UIPressPhaseEnded||press.phase==UIPressPhaseCancelled)keyboard_changed(nil,nil,(GCKeyCode)press.key.keyCode,NO);
        }
    }
    [self offline_keyboard_sendEvent:event];
}
@end
static void start_local_keyboard(void) {
    keyboard_initialize();
    Method original=class_getInstanceMethod(UIApplication.class,@selector(sendEvent:));
    Method observer=class_getInstanceMethod(UIApplication.class,@selector(offline_keyboard_sendEvent:));
    method_exchangeImplementations(original,observer);
    static atomic_bool queued=false;
    [NSTimer scheduledTimerWithTimeInterval:1.0/60.0 repeats:YES block:^(NSTimer *timer){
        if(UIApplication.sharedApplication.applicationState==UIApplicationStateActive&&keyboard_in_race()) {
            // Polling also covers keyboards that do not produce GC callbacks.
            for(NSNumber *key in @[@82,@81,@80,@79,@26,@22,@4,@7,@225,@229,@44,@224,@228,@29,@226,@230,@27,@21,@41]) {
                GCControllerButtonInput *button=[keyboard_input buttonForKeyCode:(GCKeyCode)key.integerValue];
                if(button)keyboard_changed(keyboard_input,button,(GCKeyCode)key.integerValue,button.isPressed);
            }
        }
        controller_update();
        if(!profile_verified()||atomic_exchange(&queued,true))return;
        BOOL(^task)(void)=^BOOL{@autoreleasepool{keyboard_game_tick();}atomic_store(&queued,false);return YES;};
        ((void(*)(id,SEL,id))objc_msgSend)(NSClassFromString(@"FIOSAsyncTask"),NSSelectorFromString(@"CreateTaskWithBlock:"),task);
    }];
    NSNotificationCenter *notifications=NSNotificationCenter.defaultCenter;
    for(NSString *name in @[GCKeyboardDidConnectNotification,GCKeyboardDidDisconnectNotification])
        [notifications addObserverForName:name object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note){keyboard_attach();}];
    for(NSString *name in @[GCControllerDidConnectNotification,GCControllerDidDisconnectNotification])
        [notifications addObserverForName:name object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note){controller_update();}];
    [notifications addObserverForName:UIApplicationWillResignActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note){keyboard_release();controller_release();}];
    [NSTimer scheduledTimerWithTimeInterval:1 repeats:YES block:^(NSTimer *timer){keyboard_attach();}];
}
