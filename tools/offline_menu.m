/* Local mode selection for the retained original 2.71.1 engine. Included only
   with OFFLINE_LOCAL_MENU. No replacement driving, AI, items or race rules. */
#import <CommonCrypto/CommonDigest.h>

static BOOL menu_verified(void) {
    static int verified=-1;
    if(verified>=0)return verified;
    uint64_t slide=probe_slide();
    if(slide==UINT64_MAX)return NO;
    verified=0;
    struct { uint64_t offset; size_t size; const char *digest; } checks[]={
        {0x59ecfd0,0x288,"206e7feeaf79462fa5250ce1e58fd0d49f15227d2fc51288759d1869c5ac1ed8"},
        {0x3d8e790,0x3c,"74fc068077597fc9952532944d11a6d53b3e975d1304751dd1f13ed97197fd5c"},
        {0x3d8e7e4,0x3c,"239ee2d527bdf28dfffb9545e157d195a1ab67819dad0d07857e5e1597a7a163"}
    };
    for(unsigned i=0;i<sizeof(checks)/sizeof(checks[0]);i++) {
        unsigned char data[1024],digest[CC_SHA256_DIGEST_LENGTH];char hex[65]={0};
        if(checks[i].size>sizeof(data)||!probe_read(slide+0x100000000ULL+checks[i].offset,data,checks[i].size)) {
            record([NSString stringWithFormat:@"local menu read check failed offset=0x%llx main=0x%llx",checks[i].offset,slide+0x100000000ULL]);return NO;
        }
        CC_SHA256(data,(CC_LONG)checks[i].size,digest);
        for(unsigned j=0;j<sizeof(digest);j++)snprintf(hex+j*2,3,"%02x",digest[j]);
        if(strcmp(hex,checks[i].digest)) {
            record([NSString stringWithFormat:@"local menu hash check failed offset=0x%llx actual=%s main=0x%llx",checks[i].offset,hex,slide+0x100000000ULL]);return NO;
        }
    }
    uint32_t assignment=0;
    // Require the automatic original speed/item result-factory patch.
    if(!probe_read(slide+0x1027397d0ULL,&assignment,4)||assignment!=0x1763266c) {
        record([NSString stringWithFormat:@"local menu result branch check failed actual=0x%x",assignment]);return NO;
    }
    Class tasks=NSClassFromString(@"FIOSAsyncTask");
    SEL create=NSSelectorFromString(@"CreateTaskWithBlock:");
    if(![tasks respondsToSelector:create] ||
       (uint64_t)method_getImplementation(class_getClassMethod(tasks,create))!=slide+0x103d8e790ULL) {
        record(@"local menu original task queue check failed");return NO;
    }
    verified=1;
    record(@"local menu original engine/version checks passed");
    return YES;
}

static void menu_travel(NSString *mode) {
    if(!menu_verified())return;
    // Use the engine's own Objective-C task queue: the block is run by
    // ProcessAsyncTasks on its game thread, rather than the UIKit thread.
    BOOL (^task)(void)=^BOOL {
        @autoreleasepool {
            uint64_t engine=0,contexts=0,context=0,world=0,driver=0,name=0,game_mode=0,cls=0;int count=0;
            uint64_t slide=probe_slide();
            if(slide==UINT64_MAX)return YES;
            if(!probe_read(slide+0x108b0b288ULL,&engine,8) || !engine ||
               !probe_read(engine+0xc48,&contexts,8) || !probe_read(engine+0xc50,&count,4) || count!=1 ||
               !probe_read(contexts,&context,8) || !probe_read(context+0x280,&world,8) || !world ||
               !probe_read(world+0x38,&driver,8) || driver ||
               !probe_read(world+0x18,&name,8) || !probe_read(world+0x118,&game_mode,8) ||
               !probe_read(game_mode+0x10,&cls,8)) {
                record(@"local menu travel rejected: no single local world");return YES;
            }
            NSString *kind=probe_name(cls);
            if(![probe_name(world) isEqualToString:@"Village_I01"] ||
               ![@[@"SpeedSingleGameMode",@"ItemSingleGameMode"] containsObject:kind]) {
                record(@"local menu travel rejected: unsupported original map/mode");return YES;
            }
            NSString *selected=mode ?: kind;
            if(![@[@"SpeedSingleGameMode",@"ItemSingleGameMode"] containsObject:selected])return YES;
            NSString *options=[NSString stringWithFormat:@"game=/Script/KartDrift.%@?players=1?ais=3?observers=0",selected];
            NSUInteger length=options.length+1;
            if(length>256)return YES;
            unichar buffer[256]={0};[options getCharacters:buffer range:NSMakeRange(0,options.length)];
            struct { const unichar *data; int32_t count,capacity; } value={buffer,(int32_t)length,(int32_t)length};
            record([NSString stringWithFormat:@"local menu travel %@ main_thread=%d NetDriver=0",selected,NSThread.isMainThread]);
            ((void(*)(void *,uint64_t,BOOL,const void *))(slide+0x1059ecfd0ULL))((void *)world,name,YES,&value);
        }
        return YES;
    };
    ((void(*)(id,SEL,id))objc_msgSend)(NSClassFromString(@"FIOSAsyncTask"),NSSelectorFromString(@"CreateTaskWithBlock:"),task);
}

@interface OfflineLocalMenu : NSObject
@property(nonatomic,strong) UIButton *button;
- (void)show:(UIButton *)sender;
- (void)install;
@end

static BOOL menu_has_game_view(UIView *view,NSUInteger depth) {
    if(depth>12)return NO;
    if([NSStringFromClass(view.class) isEqualToString:@"FIOSView"])return YES;
    for(UIView *child in view.subviews)if(menu_has_game_view(child,depth+1))return YES;
    return NO;
}

@implementation OfflineLocalMenu
- (void)install {
    if(!menu_verified())return;
    UIWindow *window=nil;
    for(UIWindow *candidate in UIApplication.sharedApplication.windows)
        if(candidate.rootViewController && !candidate.hidden && menu_has_game_view(candidate,0))window=candidate;
    if(!window || window.bounds.size.width<100)return;
    if(self.button.superview!=window) {
        [self.button removeFromSuperview];
        if(!self.button) {
            self.button=[UIButton buttonWithType:UIButtonTypeSystem];
            [self.button setTitle:@"单机菜单" forState:UIControlStateNormal];
            self.button.accessibilityIdentifier=@"offline.local.menu";
            self.button.backgroundColor=[UIColor colorWithWhite:0.08 alpha:0.85];
            [self.button setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
            self.button.layer.cornerRadius=8;
            [self.button addTarget:self action:@selector(show:) forControlEvents:UIControlEventTouchUpInside];
        }
        [window addSubview:self.button];
    }
    self.button.frame=CGRectMake(MAX(16,window.safeAreaInsets.left+8),MAX(44,window.safeAreaInsets.top+8),110,40);
    [window bringSubviewToFront:self.button];
}
- (void)show:(UIButton *)sender {
    UIViewController *presenter=sender.window.rootViewController;
    while(presenter.presentedViewController)presenter=presenter.presentedViewController;
    UIAlertController *menu=[UIAlertController alertControllerWithTitle:@"本地单机比赛" message:@"城镇钟楼 · 1 名玩家与 3 名 AI" preferredStyle:UIAlertControllerStyleActionSheet];
    for(NSArray *entry in @[@[@"竞速赛",@"SpeedSingleGameMode"],@[@"道具赛",@"ItemSingleGameMode"]])
        [menu addAction:[UIAlertAction actionWithTitle:entry[0] style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){menu_travel(entry[1]);}]];
    [menu addAction:[UIAlertAction actionWithTitle:@"重新开始当前比赛" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){menu_travel(nil);}]];
    [menu addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    menu.popoverPresentationController.sourceView=sender;
    menu.popoverPresentationController.sourceRect=sender.bounds;
    [presenter presentViewController:menu animated:YES completion:nil];
}
@end

static void start_local_menu(void) {
    static OfflineLocalMenu *menu;
    menu=[OfflineLocalMenu new];
    [NSTimer scheduledTimerWithTimeInterval:2 repeats:YES block:^(NSTimer *timer){[menu install];}];
}
