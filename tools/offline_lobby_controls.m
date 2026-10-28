/* Visible entry points for original track widgets and local race size.
   UIKit buttons only request actions; original widgets execute on game thread. */
static atomic_int lobby_control_request;
static atomic_int lobby_racer_count=8;
static int lobby_picker_wait;
static int lobby_prepare_wait;
static uint64_t lobby_menu_component;
static BOOL lobby_controls_ready;
static BOOL lobby_class_is(uint64_t object,NSString *name) {
    uint64_t cls=profile_u64(object+0x10);
    for(unsigned i=0;cls&&i<32;i++,cls=profile_u64(cls+0x40))
        if([probe_name(cls) isEqualToString:name])return YES;
    return NO;
}
static uint64_t lobby_component(uint64_t world,NSString *kind) {
    uint64_t level=profile_u64(world+0x30),actors=profile_u64(level+0x98);
    int n=profile_i32(level+0xa0);if(n<1||n>4096)return 0;
    for(int i=0;i<n;i++) {
        uint64_t actor=profile_u64(actors+i*8),a=profile_u64(actor+0x1a0);int count=profile_i32(actor+0x1a8);
        if(!a||count<0||count>256)continue;
        for(int j=0;j<count;j++) {
            uint64_t object=profile_u64(a+j*16);
            if(profile_u64(object+0xa0)==actor&&lobby_class_is(object,kind))return object;
        }
    }
    return 0;
}
static void lobby_activate(uint64_t menu,int page) {
    uint64_t delegate=menu+0x168;int n=profile_i32(delegate+8),lock=profile_i32(delegate+0x14);
    if(n<1||n>128||lock<0||lock>1024)return;
    *(int32_t *)(delegate+0x14)=lock+1;BOOL compact=NO;
    for(int i=n-1;i>=0;i--) {
        uint64_t a=profile_u64(delegate),object=profile_u64(a+i*16);
        if(!a||!object||!profile_i32(a+i*16+8)){compact=YES;continue;}
        uint64_t fn=profile_u64(profile_u64(object)+0x58);
        if(!fn||!((BOOL(*)(void *,int,BOOL,BOOL))fn)((void *)object,page,YES,YES))compact=YES;
    }
    *(int32_t *)(delegate+0x14)=profile_i32(delegate+0x14)-1;
    if(compact&&!profile_i32(delegate+0x14))((void(*)(void *,BOOL))(probe_slide()+0x1019c9aacULL))((void *)delegate,NO);
}
static BOOL lobby_controls_verified(void) {
    static int verified=-1;if(verified>=0)return verified;verified=0;
    struct {uint64_t a,z;const char *digest;} checks[]={
        {0x1036f91d8ULL,0x1036f98f8ULL,"49d08a14b54ae85043a82c85d8ed8bef379bd33c9b7bfdfb189eca2486ee1c8b"},
        {0x1032755d4ULL,0x1032756a8ULL,"5049e6e0791c6ac66da1d88fe1fa6129b811a3a206861f73b97e1db35e8e5306"}
    };
    for(unsigned i=0;i<2;i++) {
        unsigned char bytes[2048],digest[32];char hex[65]={0};size_t n=checks[i].z-checks[i].a;
        if(n>sizeof(bytes)||!probe_read(probe_slide()+checks[i].a,bytes,n))return NO;
        CC_SHA256(bytes,(CC_LONG)n,digest);for(int j=0;j<32;j++)snprintf(hex+j*2,3,"%02x",digest[j]);
        if(strcmp(hex,checks[i].digest))return NO;
    }
    verified=1;return YES;
}
static void lobby_controls_tick(uint64_t world) {
    if(!lobby_controls_verified())return;
    uint64_t menu=lobby_component(world,@"MainmenuComponent");
    if(!menu){lobby_menu_component=0;lobby_picker_wait=0;lobby_prepare_wait=0;return;}
    lobby_menu_component=menu;
    int action=atomic_exchange(&lobby_control_request,0);
    if(action==2){lobby_picker_wait=0;lobby_prepare_wait=0;lobby_activate(menu,1);return;}
    uint64_t logic=0;
    if(action==1||lobby_picker_wait||lobby_prepare_wait)logic=lobby_component(world,@"TimeAttackLogicComponent");
    if(action==1) {
        if(!logic){
            // Some lobby blueprints create logic lazily when a tab opens.
            // Activate the original tab, then wait for its own component.
            lobby_prepare_wait=20;lobby_activate(menu,24);return;
        }
        ((void(*)(void *,int))(probe_slide()+0x1032755d4ULL))((void *)logic,1);
        lobby_picker_wait=20;lobby_activate(menu,24);return;
    }
    if(lobby_prepare_wait) {
        if(logic){
            ((void(*)(void *,int))(probe_slide()+0x1032755d4ULL))((void *)logic,1);
            lobby_prepare_wait=0;lobby_picker_wait=20;
        }else if(--lobby_prepare_wait==0)record(@"original track selector native logic did not become ready");
        return;
    }
    if(lobby_picker_wait) {
        uint64_t page=profile_u64(logic+0xe0);unsigned char current=0;
        if(!logic||!lobby_class_is(page,@"TimeAttackPageWidget")||!probe_read(menu+0x230,&current,1)||current!=24) {
            if(--lobby_picker_wait==0)record(@"original track selector page did not become ready");return;
        }
        lobby_picker_wait=0;
        ((void(*)(void *,BOOL))(probe_slide()+0x1036f91d8ULL))((void *)page,NO);
        record(@"visible local track entry opened original TrackChangeDialog");
    }
}
@interface OfflineLobbyControls : NSObject
@property(nonatomic,strong) UIButton *track;
@property(nonatomic,strong) UIButton *racers;
@property(nonatomic,strong) UIButton *back;
- (void)refresh;
@end
@implementation OfflineLobbyControls
- (UIButton *)button:(NSString *)title action:(SEL)action identifier:(NSString *)identifier {
    UIButton *b=[UIButton buttonWithType:UIButtonTypeSystem];[b setTitle:title forState:UIControlStateNormal];
    b.accessibilityIdentifier=identifier;b.backgroundColor=[UIColor colorWithWhite:0.07 alpha:0.9];
    [b setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];b.layer.cornerRadius=7;
    [b addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];return b;
}
- (void)chooseTrack {atomic_store(&lobby_control_request,1);}
- (void)returnLobby {atomic_store(&lobby_control_request,2);}
- (void)chooseRacers {
    UIViewController *view=self.racers.window.rootViewController;
    while(view.presentedViewController)view=view.presentedViewController;
    UIAlertController *menu=[UIAlertController alertControllerWithTitle:@"单机比赛人数" message:@"个人竞速／道具赛使用此人数；双人组和四人组按原版队伍规模进入。" preferredStyle:UIAlertControllerStyleActionSheet];
    for(NSNumber *count in @[@4,@8])
        [menu addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:@"%@ 人（你＋%d 个 AI）",count,count.intValue-1] style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){
            atomic_store(&lobby_racer_count,count.intValue);[NSUserDefaults.standardUserDefaults setInteger:count.intValue forKey:@"OfflineRacerCount"];[self refresh];
        }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    menu.popoverPresentationController.sourceView=self.racers;menu.popoverPresentationController.sourceRect=self.racers.bounds;
    [view presentViewController:menu animated:YES completion:nil];
}
- (void)refresh {
    uint64_t engine=profile_u64(probe_slide()+0x108b0b288ULL);
    uint64_t world=profile_u64(profile_u64(profile_u64(engine+0xc48))+0x280);
    BOOL visible=lobby_controls_ready&&[probe_name(world) isEqualToString:@"KartMain_Mobile"];
    unsigned char page=0;if(visible)probe_read(lobby_menu_component+0x230,&page,1);
    visible&=page==1||page==24;
    UIWindow *window=nil;for(UIWindow *w in UIApplication.sharedApplication.windows)if(!w.hidden&&w.rootViewController&&w.isKeyWindow)window=w;
    if(!self.track&&window){
        self.track=[self button:@"选择赛道" action:@selector(chooseTrack) identifier:@"offline.original.tracks"];
        self.racers=[self button:@"" action:@selector(chooseRacers) identifier:@"offline.racer.count"];
        self.back=[self button:@"返回大厅" action:@selector(returnLobby) identifier:@"offline.return.lobby"];
    }
    NSArray *buttons=self.track?@[self.track,self.racers,self.back]:@[];
    for(UIButton *b in buttons)if(b.superview!=window&&window)[window addSubview:b];
    CGFloat x=MAX(12,window.safeAreaInsets.left+8),y=window.bounds.size.height-MAX(60,window.safeAreaInsets.bottom+48);
    self.track.frame=CGRectMake(x,y,230,38);self.racers.frame=CGRectMake(x+238,y,70,38);self.back.frame=CGRectMake(x+316,y,100,38);
    NSString *alias=track_saved_alias;NSDictionary *track=alias?track_definitions[alias]:nil;
    NSString *modes=[track[@"speed"] boolValue]?([track[@"item"] boolValue]?@"竞速/道具":@"仅竞速"):@"仅道具";
    [self.track setTitle:alias?[NSString stringWithFormat:@"%@ · %@",alias,modes]:@"选择赛道" forState:UIControlStateNormal];
    [self.racers setTitle:[NSString stringWithFormat:@"%d 人",atomic_load(&lobby_racer_count)] forState:UIControlStateNormal];
    self.track.hidden=!visible;self.racers.hidden=!visible;self.back.hidden=!visible||page!=24;
    for(UIButton *b in buttons)[window bringSubviewToFront:b];
}
@end
static void start_lobby_controls(void) {
    NSInteger saved=[NSUserDefaults.standardUserDefaults integerForKey:@"OfflineRacerCount"];
    atomic_store(&lobby_racer_count,saved==4?4:8);
    static OfflineLobbyControls *controls;controls=[OfflineLobbyControls new];
    [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *timer){[controls refresh];}];
}
