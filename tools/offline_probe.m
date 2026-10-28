#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <mach/mach.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <mach/arm/thread_status.h>
#import <TargetConditionals.h>

static BOOL probe_read(uint64_t address,void *value,size_t size) {
    vm_size_t received=0;
    return address && vm_read_overwrite(mach_task_self(),address,size,(vm_address_t)value,&received)==KERN_SUCCESS && received==size;
}

static uint64_t probe_slide(void) {
    // An injected bootstrap can occupy image index zero on the test device.
    // Locate this app's executable; never derive game addresses from a dylib.
    static uint64_t result=UINT64_MAX;
    if(result!=UINT64_MAX)return result;
    NSString *executable=[NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleExecutable"];
    for(uint32_t i=0;i<_dyld_image_count();i++) {
        const struct mach_header *header=_dyld_get_image_header(i);
        const char *path=_dyld_get_image_name(i);
        if(!header || !path || header->magic!=MH_MAGIC_64 || header->filetype!=MH_EXECUTE ||
           ![[NSString stringWithUTF8String:path].lastPathComponent isEqualToString:executable])continue;
        result=(uint64_t)header-0x100000000ULL;
        return result;
    }
    return UINT64_MAX;
}

static NSString *probe_fname(uint64_t address) {
    uint32_t name[2]={0};uint64_t block=0;uint16_t header=0;
    uint64_t slide=probe_slide();
    if(slide==UINT64_MAX)return @"?";
    if(!probe_read(address,name,8) || !probe_read(slide+0x108837ec0ULL+0xd0+(name[0]>>16)*8,&block,8))return @"?";
    uint64_t entry=block+(name[0]&65535)*2;
    if(!probe_read(entry,&header,2))return @"?";
    NSUInteger length=header>>6;
    if(!length || length>255)return @"?";
    char text[512]={0};
    if(!probe_read(entry+2,text,length*((header&1)?2:1)))return @"?";
    return [[NSString alloc] initWithBytes:text length:length*((header&1)?2:1) encoding:(header&1)?NSUTF16LittleEndianStringEncoding:NSUTF8StringEncoding] ?: @"?";
}

static NSString *probe_name(uint64_t object) { return probe_fname(object+0x18); }

static void record(NSString *message) {
    if(!message)message=@"(no message)";
    NSLog(@"[OfflineProbe] %@",message);
    [NSFileManager.defaultManager createDirectoryAtPath:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents"] withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *path=[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/offline-probe.log"];
    FILE *f=fopen(path.fileSystemRepresentation,"a");
    if(f){fprintf(f,"%s %s\n",[[NSDate date].description UTF8String],message.UTF8String);fclose(f);}
}

static void snapshot_race(void) {
    // Read-only layouts verified for the retained 2.71.1 executable. Fail
    // closed on absent worlds; no original engine methods are invoked here.
    uint64_t engine=0,contexts=0,context=0,world=0,level=0,actors=0;int count=0;
    uint64_t slide=probe_slide();
    if(slide==UINT64_MAX)return;
    if(!probe_read(slide+0x108b0b288ULL,&engine,8) || !engine ||
       !probe_read(engine+0xc48,&contexts,8) || !probe_read(engine+0xc50,&count,4) || count<1 || count>16 ||
       !probe_read(contexts,&context,8) || !probe_read(context+0x280,&world,8) || !world)return;
    uint64_t mode=0,cls=0;probe_read(world+0x118,&mode,8);probe_read(mode+0x10,&cls,8);
    record([NSString stringWithFormat:@"race world=%@ mode=%@",probe_name(world),probe_name(cls)]);
    if(!probe_read(world+0x30,&level,8) || !probe_read(level+0x98,&actors,8) || !probe_read(level+0xa0,&count,4) || count<0 || count>4096)return;
    for(int i=0;i<count;i++) {
        uint64_t actor=0;probe_read(actors+i*8,&actor,8);probe_read(actor+0x10,&cls,8);
        NSString *kind=probe_name(cls);
        if(![@[@"RaceGameState",@"RacePawn",@"RaceAiPawn"] containsObject:kind])continue;
        uint64_t entries=0;int slots=0;
        if(!probe_read(actor+0x1a0,&entries,8)||!probe_read(actor+0x1a8,&slots,4)||slots<0||slots>512)continue;
        for(int j=0;j<slots;j++) {
            uint64_t component=0,component_class=0;probe_read(entries+j*16,&component,8);probe_read(component+0x10,&component_class,8);
            NSString *component_kind=probe_name(component_class);
            if([component_kind isEqualToString:@"RacePhaseComponent"]) {
                uint64_t phase=0;probe_read(component+0x110,&phase,8);
                record([NSString stringWithFormat:@"race phase=%@",probe_name(phase)]);
            } else if([component_kind isEqualToString:@"RaceProgressComponent"]) {
                int rank=0;float time=0,distance=0;
                probe_read(component+0x204,&rank,4);probe_read(component+0x20c,&time,4);probe_read(component+0x22c,&distance,4);
                record([NSString stringWithFormat:@"race pawn=%@ class=%@ rank=%d time=%.3f remaining=%.3f",probe_name(actor),kind,rank,time,distance]);
            }
        }
    }
}

static void snapshot_threads(void) {
    uint64_t slide=probe_slide();
    if(slide==UINT64_MAX)return;
    thread_act_array_t threads=NULL;mach_msg_type_number_t count=0;
    if(task_threads(mach_task_self(),&threads,&count)!=KERN_SUCCESS)return;
    uint64_t base=slide+0x100000000ULL;
    for(unsigned i=0;i<count;i++) {
        thread_extended_info_data_t info={0};mach_msg_type_number_t info_count=THREAD_EXTENDED_INFO_COUNT;
        thread_info(threads[i],THREAD_EXTENDED_INFO,(thread_info_t)&info,&info_count);
        NSString *name=[NSString stringWithUTF8String:info.pth_name] ?: @"?";
        if([name containsString:@"Game"] || [name containsString:@"Render"] || [name containsString:@"RHI"]) {
            arm_thread_state64_t state={0};mach_msg_type_number_t length=ARM_THREAD_STATE64_COUNT;
            if(thread_get_state(threads[i],ARM_THREAD_STATE64,(thread_state_t)&state,&length)==KERN_SUCCESS) {
                NSMutableString *frames=[NSMutableString stringWithFormat:@"thread %@ pc=0x%llx",name,arm_thread_state64_get_pc(state)];
                uint64_t frame=arm_thread_state64_get_fp(state);
                for(int depth=0;depth<18&&frame;depth++) {
                    uint64_t pair[2]={0};if(!probe_read(frame,pair,16))break;
                    uint64_t pc=pair[1]&0x0000ffffffffffffULL;
                    if(pc>=base&&pc<base+0x9000000ULL)[frames appendFormat:@" main+0x%llx",pc-base];
                    if(pair[0]<=frame||pair[0]-frame>0x100000)break;
                    frame=pair[0];
                }
                record(frames);
            }
        }
        mach_port_deallocate(mach_task_self(),threads[i]);
    }
    vm_deallocate(mach_task_self(),(vm_address_t)threads,count*sizeof(thread_t));
}

static void restore_metadata(void) {
    NSString *root=[NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"OfflineMetadata"];
    NSFileManager *files=NSFileManager.defaultManager;
    for(NSString *relative in [files subpathsAtPath:root]) {
        NSString *source=[root stringByAppendingPathComponent:relative];
        BOOL directory=NO;
        if(![files fileExistsAtPath:source isDirectory:&directory] || directory)continue;
        if([relative.pathComponents containsObject:@".."])continue;
        NSString *destination=[NSHomeDirectory() stringByAppendingPathComponent:relative];
        [files createDirectoryAtPath:destination.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
        NSError *error=nil;
        BOOL ok=[[NSData dataWithContentsOfFile:source] writeToFile:destination options:NSDataWritingAtomic error:&error];
        record([NSString stringWithFormat:@"restore metadata %@ success=%d error=%@",relative,ok,error]);
    }
}

static void describe_view(UIView *view,NSUInteger depth) {
    if(depth>12)return;
    record([NSString stringWithFormat:@"view depth=%lu class=%@ frame=%@ hidden=%d alpha=%.2f layer=%@",(unsigned long)depth,NSStringFromClass(view.class),NSStringFromCGRect(view.frame),view.hidden,view.alpha,NSStringFromClass(view.layer.class)]);
    for(UIView *child in view.subviews)describe_view(child,depth+1);
}

#if TARGET_OS_MACCATALYST
static void fit_catalyst_view(UIView *view,NSUInteger depth) {
    if(depth>12)return;
    if([NSStringFromClass(view.class) isEqualToString:@"FIOSView"] && view.superview) {
        CGRect bounds=view.superview.bounds;
        if(bounds.size.width>100 && bounds.size.height>100 && !CGRectEqualToRect(view.frame,bounds)) {
            view.autoresizingMask=UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight;
            view.frame=bounds;
            [view setNeedsLayout];[view layoutIfNeeded];
            record([NSString stringWithFormat:@"Catalyst game view fitted to %@",NSStringFromCGRect(bounds)]);
        }
    }
    for(UIView *child in view.subviews)fit_catalyst_view(child,depth+1);
}
#endif

#ifdef OFFLINE_LOCAL_MENU
#include "offline_menu.m"
#endif
#ifdef OFFLINE_LOCAL_KEYBOARD
#include "offline_keyboard.m"
#endif
#ifdef OFFLINE_LOCAL_PROFILE
#include "offline_profile.m"
#endif

__attribute__((constructor)) static void begin_probe(void) {
    @autoreleasepool {
        record([NSString stringWithFormat:@"probe-v30 bundle=%@ home=%@",NSBundle.mainBundle.bundleIdentifier,NSHomeDirectory()]);
        restore_metadata();
#ifdef OFFLINE_LOCAL_KEYBOARD
        keyboard_initialize();dispatch_async(dispatch_get_main_queue(),^{start_local_keyboard();});
#endif
#ifdef OFFLINE_LOBBY_CONTROLS
        dispatch_async(dispatch_get_main_queue(),^{start_lobby_controls();});
#endif
#ifdef OFFLINE_LOCAL_PROFILE
        dispatch_async(dispatch_get_main_queue(),^{start_local_profile();});
#endif
#ifdef OFFLINE_LOCAL_MENU
        dispatch_async(dispatch_get_main_queue(),^{start_local_menu();});
#endif
        record([NSString stringWithContentsOfFile:[NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"ue4commandline.txt"] encoding:NSUTF8StringEncoding error:nil]);
        for(int delay=1;delay<=31;delay+=5) dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)delay*NSEC_PER_SEC),dispatch_get_main_queue(),^{
            id delegate=UIApplication.sharedApplication.delegate;
            BOOL engine=NO,command=NO;
            if([delegate respondsToSelector:NSSelectorFromString(@"bEngineInit")]) engine=((BOOL(*)(id,SEL))objc_msgSend)(delegate,NSSelectorFromString(@"bEngineInit"));
            if([delegate respondsToSelector:NSSelectorFromString(@"bCommandLineReady")]) command=((BOOL(*)(id,SEL))objc_msgSend)(delegate,NSSelectorFromString(@"bCommandLineReady"));
            record([NSString stringWithFormat:@"t=%d delegate=%@ engine=%d command=%d windows=%@",delay,NSStringFromClass([delegate class]),engine,command,UIApplication.sharedApplication.windows]);
            if(delay==31)for(UIWindow *window in UIApplication.sharedApplication.windows)describe_view(window,0);
#if TARGET_OS_MACCATALYST
            for(UIWindow *window in UIApplication.sharedApplication.windows)fit_catalyst_view(window,0);
#endif
        });
        for(int delay=10;delay<=600;delay+=10) dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)delay*NSEC_PER_SEC),dispatch_get_main_queue(),^{snapshot_race();if(delay==60||delay==180)snapshot_threads();});
    }
}
