#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

static void record(NSString *message) {
    if(!message)message=@"(no message)";
    NSLog(@"[OfflineProbe] %@",message);
    [NSFileManager.defaultManager createDirectoryAtPath:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents"] withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *path=[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/offline-probe.log"];
    FILE *f=fopen(path.fileSystemRepresentation,"a");
    if(f){fprintf(f,"%s %s\n",[[NSDate date].description UTF8String],message.UTF8String);fclose(f);}
}

__attribute__((constructor)) static void begin_probe(void) {
    @autoreleasepool {
        record([NSString stringWithFormat:@"probe-v1 bundle=%@ home=%@",NSBundle.mainBundle.bundleIdentifier,NSHomeDirectory()]);
        record([NSString stringWithContentsOfFile:[NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"ue4commandline.txt"] encoding:NSUTF8StringEncoding error:nil]);
        for(int delay=1;delay<=31;delay+=5) dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)delay*NSEC_PER_SEC),dispatch_get_main_queue(),^{
            id delegate=UIApplication.sharedApplication.delegate;
            BOOL engine=NO,command=NO;
            if([delegate respondsToSelector:NSSelectorFromString(@"bEngineInit")]) engine=((BOOL(*)(id,SEL))objc_msgSend)(delegate,NSSelectorFromString(@"bEngineInit"));
            if([delegate respondsToSelector:NSSelectorFromString(@"bCommandLineReady")]) command=((BOOL(*)(id,SEL))objc_msgSend)(delegate,NSSelectorFromString(@"bCommandLineReady"));
            record([NSString stringWithFormat:@"t=%d delegate=%@ engine=%d command=%d windows=%@",delay,NSStringFromClass([delegate class]),engine,command,UIApplication.sharedApplication.windows]);
        });
    }
}
