#import <TargetConditionals.h>
#import <MetalKit/MetalKit.h>
#import <QuartzCore/QuartzCore.h>
#import <AudioToolbox/AudioToolbox.h>
#if TARGET_OS_OSX
#import <AppKit/AppKit.h>
#else
#import <UIKit/UIKit.h>
#endif
#include "Game.hpp"
#include "Scene.hpp"
#include "Audio.hpp"

using namespace drift;
@interface RaceAudio : NSObject { @public Audio synth; AudioQueueRef audioQueue; }
@end
static void audioCallback(void* context,AudioQueueRef queue,AudioQueueBufferRef buffer){
    RaceAudio* engine=(__bridge RaceAudio*)context;
    engine->synth.render((float*)buffer->mAudioData,512,48000);buffer->mAudioDataByteSize=512*2*sizeof(float);
    AudioQueueEnqueueBuffer(queue,buffer,0,nullptr);
}
@implementation RaceAudio
-(instancetype)init{
    if((self=[super init])){
        AudioStreamBasicDescription format{};format.mSampleRate=48000;format.mFormatID=kAudioFormatLinearPCM;
        format.mFormatFlags=kAudioFormatFlagIsFloat|kAudioFormatFlagIsPacked;format.mChannelsPerFrame=2;format.mBitsPerChannel=32;format.mBytesPerFrame=8;format.mBytesPerPacket=8;format.mFramesPerPacket=1;
        OSStatus status=AudioQueueNewOutput(&format,audioCallback,(__bridge void*)self,nullptr,nullptr,0,&audioQueue);
        if(status){NSLog(@"Audio initialization failed: %d",(int)status);return self;}
        for(int i=0;i<3;i++){AudioQueueBufferRef buffer;AudioQueueAllocateBuffer(audioQueue,512*8,&buffer);audioCallback((__bridge void*)self,audioQueue,buffer);}
        AudioQueueStart(audioQueue,nullptr);
    }return self;
}
-(void)dealloc{if(audioQueue){AudioQueueStop(audioQueue,true);AudioQueueDispose(audioQueue,true);}}
@end
@interface RaceRenderer : NSObject<MTKViewDelegate> {
@public Game game; Input controls;
    RaceAudio* audio;
    id<MTLCommandQueue> queue;
    id<MTLRenderPipelineState> pipeline;
    id<MTLDepthStencilState> depth;
    CFTimeInterval previous;
    CFTimeInterval lastReport;
    BOOL storedFinish;
}
@property(nonatomic,copy) void (^onHUD)(NSString*);
-(instancetype)initWithView:(MTKView*)view;
-(void)restart:(int)mode;
-(void)handleURL:(NSURL*)url;
@end

@implementation RaceRenderer
-(instancetype)initWithView:(MTKView*)view {
    if((self=[super init])){
        view.device=MTLCreateSystemDefaultDevice();
        if(!view.device){NSLog(@"Metal device unavailable");return nil;}
        view.colorPixelFormat=MTLPixelFormatBGRA8Unorm;
        view.depthStencilPixelFormat=MTLPixelFormatDepth32Float;
        view.clearColor=MTLClearColorMake(.48,.72,.9,1);view.preferredFramesPerSecond=60;
        queue=[view.device newCommandQueue];
        NSString* source=@"#include <metal_stdlib>\nusing namespace metal;\n"
        "struct V{float4 p,n,c;};struct O{float4 p[[position]];float4 c;float fog;};"
        "vertex O vertexMain(uint id[[vertex_id]],constant V* v[[buffer(0)]],constant float4x4& m[[buffer(1)]]){"
        "O o;o.p=m*v[id].p;float light=.48+.52*max(0.f,dot(v[id].n.xyz,normalize(float3(-.4,1,.25))));"
        "o.c=float4(v[id].c.rgb*light,1);o.fog=clamp((o.p.w-110)/400,0.f,.85f);return o;}"
        "fragment float4 fragmentMain(O in[[stage_in]]){return mix(in.c,float4(.48,.72,.9,1),in.fog);}";
        NSError* error=nil;
        id<MTLLibrary> library=[view.device newLibraryWithSource:source options:nil error:&error];
        if(!library){NSLog(@"Shader error: %@",error);return nil;}
        MTLRenderPipelineDescriptor* descriptor=[MTLRenderPipelineDescriptor new];
        descriptor.vertexFunction=[library newFunctionWithName:@"vertexMain"];
        descriptor.fragmentFunction=[library newFunctionWithName:@"fragmentMain"];
        descriptor.colorAttachments[0].pixelFormat=view.colorPixelFormat;
        descriptor.depthAttachmentPixelFormat=view.depthStencilPixelFormat;
        pipeline=[view.device newRenderPipelineStateWithDescriptor:descriptor error:&error];
        if(!pipeline){NSLog(@"Pipeline error: %@",error);return nil;}
        MTLDepthStencilDescriptor* ds=[MTLDepthStencilDescriptor new];ds.depthCompareFunction=MTLCompareFunctionLess;ds.depthWriteEnabled=YES;
        depth=[view.device newDepthStencilStateWithDescriptor:ds];
        game.autopilot=[[NSProcessInfo processInfo].arguments containsObject:@"--autopilot"];
        int mode=[[NSUserDefaults standardUserDefaults] integerForKey:@"mode"];
        if([[NSProcessInfo processInfo].arguments containsObject:@"--item"])mode=1;
        [self restart:mode];audio=[RaceAudio new];view.delegate=self;
    }return self;
}
-(void)restart:(int)mode {
    mode=std::max(0,std::min(2,mode));game.start(static_cast<Mode>(mode));storedFinish=NO;controls={};previous=0;
    [[NSUserDefaults standardUserDefaults] setInteger:mode forKey:@"mode"];
}
-(void)handleURL:(NSURL*)url {
    if(![url.scheme isEqualToString:@"kartdriftoffline"])return;
    NSMutableDictionary<NSString*,NSString*>* options=[NSMutableDictionary new];
    for(NSURLQueryItem* item in [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO].queryItems)if(item.value)options[item.name]=item.value;
    if([url.host isEqualToString:@"race"]){
        NSString* mode=options[@"mode"];[self restart:[mode isEqualToString:@"item"]?1:[mode isEqualToString:@"practice"]?2:0];
        game.autopilot=[options[@"autopilot"] boolValue];
    }
    if([url.host isEqualToString:@"input"]){
        game.autopilot=false;game.paused=false;
        controls.steer=clamp([options[@"steer"] floatValue],-1,1);
        controls.drift=[options[@"drift"] boolValue];controls.use=[options[@"use"] boolValue];controls.brake=[options[@"brake"] floatValue];
    }
}
-(void)mtkView:(MTKView*)view drawableSizeWillChange:(CGSize)size{(void)view;(void)size;}
-(void)drawInMTKView:(MTKView*)view {
    @autoreleasepool {
        CFTimeInterval now=CACurrentMediaTime();float delta=previous?float(now-previous):1.f/60;previous=now;
        game.tick(delta,controls);
        audio->synth.update(game);
        if(now-lastReport>1){
            lastReport=now;NSMutableArray* racers=[NSMutableArray new];
            for(auto& kart:game.karts)[racers addObject:@{@"id":@(kart.id),@"x":@(kart.p.x),@"z":@(kart.p.z),@"speed":@(length(kart.v)),@"distance":@(kart.raceDistance),@"lap":@(kart.lap),@"place":@(kart.place),@"finished":@(kart.finished),@"finishTime":@(kart.finishTime),@"drifting":@(kart.drifting),@"gauge":@(kart.gauge),@"nitros":@(kart.nitros)}];
            NSDictionary* report=@{@"mode":@((int)game.mode),@"phase":@((int)game.phase),@"elapsed":@(game.elapsed),@"autopilot":@(game.autopilot),@"paused":@(game.paused),@"input":@{@"steer":@(controls.steer),@"drift":@(controls.drift),@"use":@(controls.use),@"brake":@(controls.brake)},@"racers":racers,@"stats":@{@"itemsUsed":@(game.stats.itemsUsed),@"hits":@(game.stats.hits),@"boosts":@(game.stats.boosts),@"driftSeconds":@(game.stats.driftSeconds),@"rescues":@(game.stats.rescues)}};
            NSURL* documents=[NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
            // A local file for repeatable development checks. Nothing is sent.
            if(documents)[[NSJSONSerialization dataWithJSONObject:report options:0 error:nil] writeToURL:[documents URLByAppendingPathComponent:@"kartdrift-last-race.json"] atomically:YES];
        }
        if(game.karts.front().finished&&!storedFinish){
            storedFinish=YES;NSString* key=game.mode==Mode::Item?@"bestItem":@"bestSpeed";
            double best=[[NSUserDefaults standardUserDefaults] doubleForKey:key],time=game.karts.front().finishTime;
            if(best<=0||time<best)[[NSUserDefaults standardUserDefaults] setDouble:time forKey:key];
        }
        if(self.onHUD){
            NSString* hud=[NSString stringWithUTF8String:game.hud().c_str()];
            if(game.autopilot)hud=[hud stringByAppendingString:@"  ·  自动驾驶测试"];
            self.onHUD(hud);
        }
        MTLRenderPassDescriptor* pass=view.currentRenderPassDescriptor;id<CAMetalDrawable> drawable=view.currentDrawable;
        if(!pass||!drawable)return;
        Frame frame=makeFrame(game,float(view.drawableSize.width/std::max(1.,view.drawableSize.height)));
        id<MTLBuffer> buffer=[view.device newBufferWithBytes:frame.vertices.data() length:frame.vertices.size()*sizeof(Vertex) options:MTLResourceStorageModeShared];
        id<MTLCommandBuffer> command=[queue commandBuffer];
        id<MTLRenderCommandEncoder> encoder=[command renderCommandEncoderWithDescriptor:pass];
        [encoder setRenderPipelineState:pipeline];[encoder setDepthStencilState:depth];[encoder setCullMode:MTLCullModeNone];
        [encoder setVertexBuffer:buffer offset:0 atIndex:0];[encoder setVertexBytes:&frame.viewProjection length:sizeof(Matrix) atIndex:1];
        [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:frame.vertices.size()];[encoder endEncoding];
        [command presentDrawable:drawable];[command commit];
    }
}
@end

#if TARGET_OS_OSX
@interface RaceView : MTKView
@property(nonatomic,weak) RaceRenderer* race;
@end
@implementation RaceView
-(BOOL)acceptsFirstResponder{return YES;}
-(void)key:(NSEvent*)e down:(BOOL)down{
    auto& input=self.race->controls;
    switch(e.keyCode){
        case 123:case 0:input.steer=down?-1:0;break;
        case 124:case 2:input.steer=down?1:0;break;
        case 125:case 1:input.brake=down?1:0;break;
        case 49:input.drift=down;break;
        case 40:input.use=down;break;
        case 15:if(down)self.race->game.rescue(0);break;
        case 18:if(down)[self.race restart:0];break;
        case 19:if(down)[self.race restart:1];break;
        case 20:if(down)[self.race restart:2];break;
        case 35:if(down)self.race->game.paused=!self.race->game.paused;break;
        case 17:if(down)self.race->game.autopilot=!self.race->game.autopilot;break;
    }
}
-(void)keyDown:(NSEvent*)e{if(!e.isARepeat)[self key:e down:YES];}
-(void)keyUp:(NSEvent*)e{[self key:e down:NO];}
-(void)flagsChanged:(NSEvent*)e{self.race->controls.use=(e.modifierFlags&NSEventModifierFlagShift)!=0;}
@end

@interface AppDelegate : NSObject<NSApplicationDelegate> {
    NSWindow* window; RaceRenderer* renderer; NSTextField* hud;
}
@end
@implementation AppDelegate
-(void)applicationDidFinishLaunching:(NSNotification*)notification{
    (void)notification;
    window=[[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,1280,800) styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskResizable|NSWindowStyleMaskMiniaturizable backing:NSBackingStoreBuffered defer:NO];
    window.title=@"KartDrift Offline · 自研客户端";
    RaceView* view=[[RaceView alloc] initWithFrame:window.contentView.bounds];view.autoresizingMask=NSViewWidthSizable|NSViewHeightSizable;
    window.contentView=view;renderer=[[RaceRenderer alloc] initWithView:view];view.race=renderer;
    hud=[NSTextField labelWithString:@""];hud.frame=NSMakeRect(22,view.bounds.size.height-108,1100,92);hud.autoresizingMask=NSViewWidthSizable|NSViewMinYMargin;
    hud.textColor=NSColor.whiteColor;hud.font=[NSFont monospacedSystemFontOfSize:19 weight:NSFontWeightSemibold];hud.maximumNumberOfLines=4;
    hud.wantsLayer=YES;hud.layer.backgroundColor=[[NSColor colorWithWhite:0 alpha:.55] CGColor];hud.layer.cornerRadius=9;
    [view addSubview:hud];__weak AppDelegate* weak=self;renderer.onHUD=^(NSString* text){AppDelegate* strong=weak;if(strong)strong->hud.stringValue=text;};
    NSArray* names=@[@"竞速赛",@"道具赛",@"单人练习",@"重新开始",@"救援",@"暂停",@"自动测试"];
    for(NSInteger i=0;i<names.count;i++){
        NSButton* button=[NSButton buttonWithTitle:names[i] target:self action:@selector(menu:)];button.tag=i;button.frame=NSMakeRect(20+i*112,57,105,34);button.autoresizingMask=NSViewMaxYMargin;[view addSubview:button];
    }
    NSTextField* help=[NSTextField labelWithString:@"← → 转向   空格 漂移   Shift / K 氮气或道具   ↓ 刹车   R 救援   1 / 2 / 3 切换模式   P 暂停"];
    help.frame=NSMakeRect(22,18,1210,28);help.textColor=NSColor.whiteColor;help.font=[NSFont systemFontOfSize:16 weight:NSFontWeightMedium];[view addSubview:help];
    [window center];[window makeKeyAndOrderFront:nil];[window makeFirstResponder:view];[NSApp activateIgnoringOtherApps:YES];
}
-(void)menu:(NSButton*)sender{
    if(sender.tag<3)[renderer restart:(int)sender.tag];
    else if(sender.tag==3)[renderer restart:(int)renderer->game.mode];
    else if(sender.tag==4)renderer->game.rescue(0);
    else if(sender.tag==5)renderer->game.paused=!renderer->game.paused;
    else renderer->game.autopilot=!renderer->game.autopilot;
    [window makeFirstResponder:window.contentView];
}
-(BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication*)app{(void)app;return YES;}
-(void)applicationDidResignActive:(NSNotification*)note{(void)note;renderer->controls={};}
-(void)application:(NSApplication*)application openURLs:(NSArray<NSURL*>*)urls{(void)application;for(NSURL* url in urls)[renderer handleURL:url];}
@end
int main(int argc,const char* argv[]){@autoreleasepool{[NSApplication sharedApplication];NSApp.activationPolicy=NSApplicationActivationPolicyRegular;AppDelegate* delegate=[AppDelegate new];NSApp.delegate=delegate;[NSApp run];}return 0;}
#else
@interface RaceController : UIViewController {
    MTKView* metalView;RaceRenderer* renderer;UILabel* hud;
    NSMutableArray<UIButton*>* buttons;
}
-(void)handleURL:(NSURL*)url;
@end
@implementation RaceController
-(void)loadView{
    metalView=[[MTKView alloc] initWithFrame:UIScreen.mainScreen.bounds];self.view=metalView;metalView.multipleTouchEnabled=YES;
    renderer=[[RaceRenderer alloc] initWithView:metalView];
    hud=[UILabel new];hud.textColor=UIColor.whiteColor;hud.font=[UIFont monospacedSystemFontOfSize:17 weight:UIFontWeightSemibold];hud.numberOfLines=4;hud.backgroundColor=[UIColor colorWithWhite:0 alpha:.55];hud.layer.cornerRadius=9;hud.clipsToBounds=YES;[self.view addSubview:hud];
    __weak RaceController* weak=self;renderer.onHUD=^(NSString* text){RaceController* strong=weak;if(strong)strong->hud.text=text;};
    buttons=[NSMutableArray new];
    NSArray* names=@[@"竞速",@"道具",@"练习",@"重开",@"救援",@"暂停",@"自动测试",@"◀",@"▶",@"漂移",@"氮气 / 道具",@"刹车"];
    for(NSInteger i=0;i<names.count;i++){
        UIButton* b=[UIButton buttonWithType:UIButtonTypeSystem];b.tag=i;[b setTitle:names[i] forState:UIControlStateNormal];[b setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];b.titleLabel.font=[UIFont systemFontOfSize:i>=7?22:15 weight:UIFontWeightBold];b.backgroundColor=[UIColor colorWithRed:.04 green:.10 blue:.18 alpha:.76];b.layer.cornerRadius=16;b.layer.borderWidth=1;b.layer.borderColor=[UIColor colorWithWhite:1 alpha:.3].CGColor;
        if(i<7)[b addTarget:self action:@selector(menu:) forControlEvents:UIControlEventTouchUpInside];
        else{[b addTarget:self action:@selector(pressed:) forControlEvents:UIControlEventTouchDown];[b addTarget:self action:@selector(released:) forControlEvents:UIControlEventTouchUpInside|UIControlEventTouchUpOutside|UIControlEventTouchCancel];}
        [self.view addSubview:b];[buttons addObject:b];
    }
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(background:) name:UIApplicationWillResignActiveNotification object:nil];
}
-(void)viewDidLayoutSubviews{
    [super viewDidLayoutSubviews];UIEdgeInsets safe=self.view.safeAreaInsets;
    CGFloat w=self.view.bounds.size.width,h=self.view.bounds.size.height,l=safe.left+12,r=w-safe.right-12;
    hud.frame=CGRectMake(l,safe.top+10,r-l,84);
    CGFloat menuWidth=MIN(80,(r-l-36)/7);
    for(int i=0;i<7;i++)buttons[i].frame=CGRectMake(l+i*(menuWidth+6),safe.top+103,menuWidth,36);
    CGFloat bottom=h-safe.bottom-16;
    buttons[7].frame=CGRectMake(l,bottom-82,82,82);buttons[8].frame=CGRectMake(l+94,bottom-82,82,82);
    buttons[9].frame=CGRectMake(r-92,bottom-92,92,92);buttons[10].frame=CGRectMake(r-242,bottom-80,136,80);
    buttons[11].frame=CGRectMake(l+38,bottom-145,100,48);
}
-(void)menu:(UIButton*)sender{
    if(sender.tag<3)[renderer restart:(int)sender.tag];
    else if(sender.tag==3)[renderer restart:(int)renderer->game.mode];
    else if(sender.tag==4)renderer->game.rescue(0);
    else if(sender.tag==5)renderer->game.paused=!renderer->game.paused;
    else renderer->game.autopilot=!renderer->game.autopilot;
}
-(void)pressed:(UIButton*)b{if(b.tag==7)renderer->controls.steer=-1;if(b.tag==8)renderer->controls.steer=1;if(b.tag==9)renderer->controls.drift=true;if(b.tag==10)renderer->controls.use=true;if(b.tag==11)renderer->controls.brake=1;}
-(void)released:(UIButton*)b{if(b.tag==7||b.tag==8)renderer->controls.steer=0;if(b.tag==9)renderer->controls.drift=false;if(b.tag==10)renderer->controls.use=false;if(b.tag==11)renderer->controls.brake=0;}
-(void)background:(NSNotification*)note{(void)note;renderer->game.paused=true;renderer->controls={};}
-(void)handleURL:(NSURL*)url{[self loadViewIfNeeded];[renderer handleURL:url];}
-(BOOL)prefersStatusBarHidden{return YES;}
-(BOOL)prefersHomeIndicatorAutoHidden{return YES;}
-(UIInterfaceOrientationMask)supportedInterfaceOrientations{return UIInterfaceOrientationMaskLandscape;}
@end
@interface AppDelegate : UIResponder<UIApplicationDelegate>
@property(nonatomic,strong) UIWindow* window;
@end
@implementation AppDelegate
-(BOOL)application:(UIApplication*)application didFinishLaunchingWithOptions:(NSDictionary*)options{
    (void)application;(void)options;self.window=[[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];self.window.rootViewController=[RaceController new];[self.window makeKeyAndVisible];UIApplication.sharedApplication.idleTimerDisabled=YES;return YES;
}
-(BOOL)application:(UIApplication*)app openURL:(NSURL*)url options:(NSDictionary<UIApplicationOpenURLOptionsKey,id>*)options{(void)app;(void)options;[(RaceController*)self.window.rootViewController handleURL:url];return YES;}
@end
int main(int argc,char* argv[]){@autoreleasepool{return UIApplicationMain(argc,argv,nil,NSStringFromClass(AppDelegate.class));}}
#endif
