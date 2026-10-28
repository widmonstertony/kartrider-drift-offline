/* Hardware-keyboard adapter for the retained native iOS input queue.
   The original axis/action bindings and physics consume these key events. */
#import <GameController/GameController.h>
#import <stdatomic.h>
static uint64_t keyboard_interface;
static NSRecursiveLock *keyboard_lock;
static NSMutableDictionary<NSNumber *,NSNumber *> *keyboard_held;
static GCKeyboardInput *keyboard_input;
static GCKeyboardValueChangedHandler keyboard_handler;

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
static void keyboard_changed(GCKeyboardInput *input,GCDeviceButtonInput *button,GCKeyCode code,BOOL pressed) {
    [keyboard_lock lock];
    NSNumber *physical=@(code),*logical=keyboard_held[physical];
    if(pressed&&!logical&&UIApplication.sharedApplication.applicationState==UIApplicationStateActive) {
        logical=@(keyboard_alias(code));BOOL already=[keyboard_held.allValues containsObject:logical];
        if(already||keyboard_emit(logical.integerValue,YES))keyboard_held[physical]=logical;
    }else if(!pressed&&logical){
        [keyboard_held removeObjectForKey:physical];
        if(![keyboard_held.allValues containsObject:logical])keyboard_emit(logical.integerValue,NO);
    }
    [keyboard_lock unlock];
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
    keyboard_handler=^(GCKeyboardInput *input,GCDeviceButtonInput *button,GCKeyCode code,BOOL pressed){keyboard_changed(input,button,code,pressed);};
    });
}
static void start_local_keyboard(void) {
    keyboard_initialize();
    NSNotificationCenter *notifications=NSNotificationCenter.defaultCenter;
    for(NSString *name in @[GCKeyboardDidConnectNotification,GCKeyboardDidDisconnectNotification])
        [notifications addObserverForName:name object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note){keyboard_attach();}];
    [notifications addObserverForName:UIApplicationWillResignActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note){keyboard_release();}];
    [NSTimer scheduledTimerWithTimeInterval:1 repeats:YES block:^(NSTimer *timer){keyboard_attach();}];
}
