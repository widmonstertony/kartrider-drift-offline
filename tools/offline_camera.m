/* Switchable cockpit view for the retained DriveCameraComponent.
   The executable bridge calls this after the original GetCameraView, on the
   same engine thread. Its first-person calculator and retained meshes remain
   responsible for all animation and rendering. */
#import <math.h>
static atomic_bool camera_first_person;
static BOOL camera_reported;

struct OfflineCameraResult { float location[3],rotation[3],fov; };

static BOOL camera_in_race(void) {
    uint64_t engine=profile_u64(probe_slide()+0x108b0b288ULL);
    uint64_t world=profile_u64(profile_u64(profile_u64(engine+0xc48))+0x280);
    uint64_t mode=profile_u64(world+0x118),cls=profile_u64(mode+0x10);
    return [@[@"SpeedSingleGameMode",@"ItemSingleGameMode",@"SpeedTeamGameMode",@"ItemTeamGameMode"] containsObject:probe_name(cls)];
}

static BOOL camera_verified(void) {
    static int verified=-1;if(verified>=0)return verified;verified=0;
    struct {uint64_t start,end;const char *digest;} checks[]={
        // The executable bridge replaces the first instruction after the
        // build-time full-function check. Verify the untouched remainder at
        // runtime instead of rejecting our own installed branch.
        {0x1025946dcULL,0x1025948d8ULL,"c88bd9195c60bf1563bbd7ace9b750b0dd2642c4708825f30fd8a24bf02390aa"},
        {0x10256ba84ULL,0x10256bce4ULL,"da046636c062a9dc478b69d5dc96e2f617fd5f8efa844c1ed9394f4195ee9593"}
    };
    for(unsigned i=0;i<2;i++) {
        unsigned char bytes[640],digest[32];char hex[65]={0};size_t n=checks[i].end-checks[i].start;
        if(n>sizeof(bytes)||!probe_read(probe_slide()+checks[i].start,bytes,n))return NO;
        CC_SHA256(bytes,(CC_LONG)n,digest);for(int j=0;j<32;j++)snprintf(hex+j*2,3,"%02x",digest[j]);
        if(strcmp(hex,checks[i].digest))return NO;
    }
    verified=1;return YES;
}

static void camera_set_first_person(BOOL enabled) {
    atomic_store(&camera_first_person,enabled);
    [NSUserDefaults.standardUserDefaults setBool:enabled forKey:@"OfflineFirstPersonCamera"];
}
static void camera_toggle(void) { camera_set_first_person(!atomic_load(&camera_first_person)); }

__attribute__((visibility("default")))
void offline_camera_view(uint64_t component,uint64_t output,float delta) {
    if(!atomic_load(&camera_first_person)||!camera_verified()||!component||!output)return;
    if(![probe_name(profile_u64(component+0x10)) isEqualToString:@"DriveCameraComponent"])return;
    uint64_t pawn=profile_u64(component+0xf20),movement=profile_u64(component+0xea8);
    if(!pawn||![probe_name(profile_u64(pawn+0x10)) containsString:@"RacePawn"])return;
    // Layout of UFirstPersonFollowCameraCalculator after UObject. Values are
    // the retained iOS FirstPersonFollowCameraData row: camera (30,0,160),
    // target (40,0,160), FOV 75 and 0.1 s orientation interpolation.
    static unsigned char calculator[0x80];static dispatch_once_t once;
    dispatch_once(&once,^{
        float values[]={30,0,160,40,0,160,75};
        memcpy(calculator+0x30,values,sizeof(values));
        *(float *)(calculator+0x54)=0.1f;*(float *)(calculator+0x6c)=1.0f;
        *(unsigned char *)(calculator+0x50)=1;
    });
    typedef struct OfflineCameraResult (*Calculate)(void *,void *,void *,void *,float);
    struct OfflineCameraResult view=((Calculate)(probe_slide()+0x10256ba84ULL))(calculator,(void *)pawn,(void *)component,(void *)movement,delta);
    BOOL valid=isfinite(view.location[0])&&isfinite(view.location[1])&&isfinite(view.location[2])&&
        isfinite(view.rotation[0])&&isfinite(view.rotation[1])&&isfinite(view.rotation[2])&&isfinite(view.fov)&&view.fov>=60&&view.fov<=120;
    if(!valid)return;
    memcpy((void *)output,view.location,12);memcpy((void *)(output+12),view.rotation,12);*(float *)(output+24)=view.fov;
    if(!camera_reported){camera_reported=YES;record(@"original first-person follow camera applied; retained driver and kart meshes visible");}
}

__attribute__((visibility("default")))
void offline_loading_widget(uint64_t widget) {
    static int verified=-1;
    if(verified<0){
        unsigned char bytes[0x168],digest[32];char hex[65]={0};verified=0;
        if(probe_read(probe_slide()+0x103117008ULL,bytes,sizeof(bytes))){
            CC_SHA256(bytes,sizeof(bytes),digest);for(int j=0;j<32;j++)snprintf(hex+j*2,3,"%02x",digest[j]);
            verified=!strcmp(hex,"ca2c6fee6362c8b2e880c150fcc2845fe1670aff9ba58e1983f2b90da5428d12");
        }
    }
    if(!verified)return;
    uint64_t row=track_loading_row();
    if(!row||![probe_name(profile_u64(widget+0x10)) isEqualToString:@"MajorGameLoadingWidget"])return;
    ((void(*)(void *,const void *))(probe_slide()+0x103117008ULL))((void *)widget,(void *)row);
    record([NSString stringWithFormat:@"original loading background updated for track=%@",track_race_alias]);
}

@interface OfflineCameraControls:NSObject
@property(nonatomic,strong)UIButton *button;
- (void)refresh;
@end
@implementation OfflineCameraControls
- (void)toggle {
    camera_toggle();
    [self refresh];
}
- (void)refresh {
    UIWindow *window=nil;for(UIWindow *w in UIApplication.sharedApplication.windows)if(!w.hidden&&w.rootViewController&&w.isKeyWindow)window=w;
    if(!self.button&&window){
        self.button=[UIButton buttonWithType:UIButtonTypeSystem];self.button.accessibilityIdentifier=@"offline.camera.toggle";
        self.button.backgroundColor=[UIColor colorWithWhite:0.07 alpha:0.78];[self.button setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
        self.button.layer.cornerRadius=7;[self.button addTarget:self action:@selector(toggle) forControlEvents:UIControlEventTouchUpInside];[window addSubview:self.button];
    }
    if(self.button.superview!=window&&window)[window addSubview:self.button];
    CGFloat x=MAX(12,window.safeAreaInsets.left+8),y=MAX(12,window.safeAreaInsets.top+8);
    self.button.frame=CGRectMake(x,y,132,38);self.button.hidden=!camera_in_race();
    [self.button setTitle:atomic_load(&camera_first_person)?@"切回追尾视角":@"第一人称视角" forState:UIControlStateNormal];
    if(!self.button.hidden)[window bringSubviewToFront:self.button];
}
@end

static void camera_initialize(void) {
    static dispatch_once_t once;dispatch_once(&once,^{
        atomic_store(&camera_first_person,[NSUserDefaults.standardUserDefaults boolForKey:@"OfflineFirstPersonCamera"]);
        dispatch_async(dispatch_get_main_queue(),^{
            OfflineCameraControls *controls=[OfflineCameraControls new];
            [NSTimer scheduledTimerWithTimeInterval:0.2 repeats:YES block:^(NSTimer *timer){[controls refresh];}];
        });
    });
}
