/* Switchable cockpit view for the retained DriveCameraComponent.
   The executable bridge calls this after the original GetCameraView, on the
   same engine thread. It changes only the final view and driver-head bone;
   retained meshes remain responsible for all animation and rendering. */
#import <math.h>
static atomic_bool camera_first_person;
static atomic_int camera_cockpit_preset;
static BOOL camera_reported;
static uint64_t camera_driver_pawn,camera_driver_mesh,camera_head_name;
static BOOL camera_head_was_hidden,camera_head_hidden_by_us;

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
        {0x1058e97e0ULL,0x1058e98e0ULL,"ab4228e4e4ea10a1b95abd99f9dd3be36f6268a9427e46ef640721b1b39cc1b5"},
        {0x1058f3eb0ULL,0x1058f3f40ULL,"2d9be4649093077aae5ea6bec58d2ad5043403fb5b62671f1acadbb456fada42"},
        {0x1058f3f40ULL,0x1058f3f8cULL,"0678459afc3a083a9ac3c78f3b44992e456d3b1afb563d56c7544f1bdad5d70b"},
        {0x1058f3f8cULL,0x1058f3fd0ULL,"0997d220e1a325a0bc6e3c50a79d854e33333ee9780e78d060849e0e6922ecf7"},
        {0x105ab8d20ULL,0x105ab8d60ULL,"c143e3496716b5986c1c03eaedc6f7f177d62abb532377f05e97ed107284735f"}
    };
    for(unsigned i=0;i<sizeof(checks)/sizeof(checks[0]);i++) {
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
static void camera_cycle_preset(void) {
    int preset=(atomic_load(&camera_cockpit_preset)+1)%3;
    atomic_store(&camera_cockpit_preset,preset);
    [NSUserDefaults.standardUserDefaults setInteger:preset forKey:@"OfflineCockpitPreset"];
}

static uint64_t camera_fname(NSString *text) {
    unichar characters[16]={0};if(!text.length||text.length>=16)return 0;
    [text getCharacters:characters range:NSMakeRange(0,text.length)];
    struct {const unichar *data;int32_t count,capacity;} value={characters,(int32_t)text.length+1,(int32_t)text.length+1};
    return ((uint64_t(*)(const void *))(probe_slide()+0x105ab8d20ULL))(&value);
}
static BOOL camera_driver_live(uint64_t pawn,uint64_t mesh) {
    return pawn&&mesh&&profile_u64(mesh+0xa0)==pawn&&
        [probe_name(profile_u64(mesh+0x10)) isEqualToString:@"CharacterSkeletalMeshComponent"];
}
static void camera_clear_driver(void) {
    camera_driver_pawn=camera_driver_mesh=camera_head_name=0;
    camera_head_was_hidden=camera_head_hidden_by_us=NO;
}
static void camera_restore_driver(uint64_t pawn) {
    if(camera_head_hidden_by_us&&pawn==camera_driver_pawn&&camera_driver_live(pawn,camera_driver_mesh)) {
        ((void(*)(void *,uint64_t))(probe_slide()+0x1058f3f8cULL))((void *)camera_driver_mesh,camera_head_name);
        record(@"cockpit camera restored original driver head visibility");
    }
    camera_clear_driver();
}
static uint64_t camera_character_mesh(uint64_t pawn) {
    uint64_t entries=profile_u64(pawn+0x1a0);int count=profile_i32(pawn+0x1a8);
    if(!entries||count<1||count>512)return 0;
    for(int i=0;i<count;i++) {
        uint64_t mesh=profile_u64(entries+(uint64_t)i*16);
        if(camera_driver_live(pawn,mesh))return mesh;
    }
    return 0;
}
static uint64_t camera_handle_mesh(uint64_t pawn,uint64_t kart) {
    if(!kart||![probe_name(profile_u64(kart+0x10)) isEqualToString:@"KartSkeletalMeshComponent"])return 0;
    uint64_t handle=profile_u64(kart+0x1320);
    if(!handle||profile_u64(handle+0xa0)!=pawn||
       ![probe_name(profile_u64(handle+0x10)) isEqualToString:@"PartsMeshComponent"])return 0;
    return handle;
}
static void camera_update_driver(uint64_t pawn,BOOL applied) {
    if(!applied){camera_restore_driver(pawn);return;}
    uint64_t mesh=camera_character_mesh(pawn);if(!mesh)return;
    if(mesh!=camera_driver_mesh||pawn!=camera_driver_pawn) {
        camera_restore_driver(pawn);
        camera_driver_pawn=pawn;camera_driver_mesh=mesh;
        for(NSString *candidate in @[@"-Head",@"Head"]) {
            uint64_t name=camera_fname(candidate);
            int index=((int(*)(void *,uint64_t))(probe_slide()+0x1058e97e0ULL))((void *)mesh,name);
            if(index>=0&&index<512){camera_head_name=name;break;}
        }
        if(!camera_head_name){camera_clear_driver();record(@"cockpit camera could not identify driver head bone");return;}
        camera_head_was_hidden=((BOOL(*)(void *,uint64_t))(probe_slide()+0x1058f3eb0ULL))((void *)mesh,camera_head_name);
    }
    if(!camera_head_was_hidden&&!camera_head_hidden_by_us) {
        ((void(*)(void *,uint64_t,int))(probe_slide()+0x1058f3f40ULL))((void *)mesh,camera_head_name,0);
        camera_head_hidden_by_us=((BOOL(*)(void *,uint64_t))(probe_slide()+0x1058f3eb0ULL))((void *)mesh,camera_head_name);
        record(camera_head_hidden_by_us?@"cockpit camera hid only driver head; body and hands retained":@"cockpit camera driver head hide failed");
    }
}

__attribute__((visibility("default")))
void offline_camera_view(uint64_t component,uint64_t output,float delta) {
    (void)delta;
    if(!camera_verified()||!component||!output)return;
    if(![probe_name(profile_u64(component+0x10)) isEqualToString:@"DriveCameraComponent"])return;
    uint64_t pawn=profile_u64(component+0xf20);
    if(!pawn||![probe_name(profile_u64(pawn+0x10)) containsString:@"RacePawn"])return;
    if(!atomic_load(&camera_first_person)){camera_update_driver(pawn,NO);return;}
    uint64_t root=profile_u64(pawn+0x130);float q[4],position[3];
    if(!root||!probe_read(root+0x1d0,q,sizeof(q))||!probe_read(root+0x1e0,position,sizeof(position)))return;
    float norm=q[0]*q[0]+q[1]*q[1]+q[2]*q[2]+q[3]*q[3];
    if(!isfinite(norm)||norm<0.9f||norm>1.1f)return;
    float forward[3]={1-2*(q[1]*q[1]+q[2]*q[2]),2*(q[0]*q[1]+q[3]*q[2]),2*(q[0]*q[2]-q[3]*q[1])};
    float up[3]={2*(q[0]*q[2]+q[3]*q[1]),2*(q[1]*q[2]-q[3]*q[0]),1-2*(q[0]*q[0]+q[1]*q[1])};
    // Mobile karts do not share a single root-to-seat height. Anchor the view
    // to the retained vehicle's real HandleMesh so its animated steering wheel
    // and the driver's hands stay in frame across every kart body.
    float anchor[3]={position[0],position[1],position[2]+70};
    uint64_t handle=camera_handle_mesh(pawn,root);float handle_position[3];
    if(handle&&probe_read(handle+0x1e0,handle_position,sizeof(handle_position))) {
        float dx=handle_position[0]-position[0],dy=handle_position[1]-position[1],dz=handle_position[2]-position[2];
        float distance2=dx*dx+dy*dy+dz*dz;
        if(isfinite(distance2)&&distance2<250000)memcpy(anchor,handle_position,sizeof(anchor));
    }
    static const float behind[3]={55,45,68};
    static const float above[3]={38,24,52};
    static const float down[3]={12,18,10};
    int preset=atomic_load(&camera_cockpit_preset);if(preset<0||preset>2)preset=0;
    struct OfflineCameraResult view={
        {anchor[0]-behind[preset]*forward[0]+above[preset]*up[0],anchor[1]-behind[preset]*forward[1]+above[preset]*up[1],anchor[2]-behind[preset]*forward[2]+above[preset]*up[2]},
        {atan2f(forward[2],hypotf(forward[0],forward[1]))*57.2957795f-down[preset],atan2f(forward[1],forward[0])*57.2957795f,0},92
    };
    BOOL valid=isfinite(view.location[0])&&isfinite(view.location[1])&&isfinite(view.location[2])&&
        isfinite(view.rotation[0])&&isfinite(view.rotation[1])&&isfinite(view.rotation[2])&&isfinite(view.fov)&&view.fov>=60&&view.fov<=120;
    if(!valid)return;
    memcpy((void *)output,view.location,12);memcpy((void *)(output+12),view.rotation,12);*(float *)(output+24)=view.fov;
    camera_update_driver(pawn,YES);
    if(!camera_reported){camera_reported=YES;record(handle?@"handle-anchored cockpit camera applied; original wheel and hands retained":@"cockpit camera applied with fallback seat anchor");}
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
@property(nonatomic,strong)UIButton *positionButton;
- (void)refresh;
@end
@implementation OfflineCameraControls
- (void)toggle {
    camera_toggle();
    [self refresh];
}
- (void)cyclePosition {
    camera_cycle_preset();
    [self refresh];
}
- (void)refresh {
    UIWindow *window=nil;for(UIWindow *w in UIApplication.sharedApplication.windows)if(!w.hidden&&w.rootViewController&&w.isKeyWindow)window=w;
    if(!self.button&&window){
        self.button=[UIButton buttonWithType:UIButtonTypeSystem];self.button.accessibilityIdentifier=@"offline.camera.toggle";
        self.button.backgroundColor=[UIColor colorWithWhite:0.07 alpha:0.78];[self.button setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
        self.button.layer.cornerRadius=7;[self.button addTarget:self action:@selector(toggle) forControlEvents:UIControlEventTouchUpInside];[window addSubview:self.button];
        self.positionButton=[UIButton buttonWithType:UIButtonTypeSystem];self.positionButton.accessibilityIdentifier=@"offline.camera.position";
        self.positionButton.backgroundColor=[UIColor colorWithWhite:0.07 alpha:0.78];[self.positionButton setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
        self.positionButton.layer.cornerRadius=7;[self.positionButton addTarget:self action:@selector(cyclePosition) forControlEvents:UIControlEventTouchUpInside];[window addSubview:self.positionButton];
    }
    if(self.button.superview!=window&&window)[window addSubview:self.button];
    if(self.positionButton.superview!=window&&window)[window addSubview:self.positionButton];
    CGFloat x=MAX(12,window.safeAreaInsets.left+8),y=MAX(12,window.safeAreaInsets.top+8);
    self.button.frame=CGRectMake(x,y,132,38);self.positionButton.frame=CGRectMake(x+140,y,112,38);self.button.hidden=!camera_in_race();
    [self.button setTitle:atomic_load(&camera_first_person)?@"切回追尾视角":@"第一人称视角" forState:UIControlStateNormal];
    self.positionButton.hidden=self.button.hidden||!atomic_load(&camera_first_person);
    int preset=atomic_load(&camera_cockpit_preset);NSString *title=preset==1?@"座舱：低":(preset==2?@"座舱：高":@"座舱：标准");
    [self.positionButton setTitle:title forState:UIControlStateNormal];
    if(!self.button.hidden){[window bringSubviewToFront:self.button];if(!self.positionButton.hidden)[window bringSubviewToFront:self.positionButton];}
}
@end

static void camera_initialize(void) {
    static dispatch_once_t once;dispatch_once(&once,^{
        atomic_store(&camera_first_person,[NSUserDefaults.standardUserDefaults boolForKey:@"OfflineFirstPersonCamera"]);
        NSInteger preset=[NSUserDefaults.standardUserDefaults integerForKey:@"OfflineCockpitPreset"];
        atomic_store(&camera_cockpit_preset,preset>=0&&preset<=2?(int)preset:0);
        dispatch_async(dispatch_get_main_queue(),^{
            OfflineCameraControls *controls=[OfflineCameraControls new];
            [NSTimer scheduledTimerWithTimeInterval:0.2 repeats:YES block:^(NSTimer *timer){[controls refresh];}];
        });
    });
}
