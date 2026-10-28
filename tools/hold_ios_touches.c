/* Short, simultaneous touch holds for an explicitly authorized test device.
   Requires a jailbroken iOS device and HID dispatch entitlement. Check the
   foreground app and unlocked screen before invoking; coordinates are fixed
   screen points, as in the user's MCP service. No game memory is modified. */
#include <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
#include <mach/mach_time.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

typedef CFTypeRef Event;
static Event (*hand)(CFAllocatorRef,uint64_t,uint32_t,uint32_t,uint32_t,uint32_t,uint32_t,double,double,double,double,double,double,Boolean,Boolean,uint32_t);
static Event (*finger)(CFAllocatorRef,uint64_t,uint32_t,uint32_t,uint32_t,double,double,double,double,double,Boolean,Boolean,uint32_t);
static CFTypeRef (*client_create)(CFAllocatorRef);
static void (*append)(Event,Event,uint32_t);
static void (*integer)(Event,uint32_t,int64_t);
static void (*sender)(Event,uint64_t);
static void (*dispatch_event)(CFTypeRef,Event);

static int emit(CFTypeRef client,uint64_t sender_id,int phase,int count,double *x,double *y){
    Boolean down=phase!=2;
    uint32_t mask=phase==0?3:(phase==1?4:2);
    Event event=hand(NULL,mach_absolute_time(),3,99,1,mask,0,0,0,0,0,0,0,down,down,0);
    if(!event)return 0;
    integer(event,4,1);integer(event,0xb0019,1);
    for(int i=0;i<count;i++){
        Event contact=finger(NULL,mach_absolute_time(),i+1,i+11,mask,x[i],y[i],0,down?0.4:0,0,down,down,0);
        if(!contact){CFRelease(event);return 0;}
        append(event,contact,0);CFRelease(contact);
    }
    integer(event,0xb0007,phase==1?4:0x23);
    integer(event,0xb0008,down);integer(event,0xb0009,down);
    sender(event,sender_id);dispatch_event(client,event);CFRelease(event);return 1;
}

int main(int argc,char **argv){
    if(argc<7||(argc-5)%2){
        fprintf(stderr,"Usage: %s width height seconds sender-id x1 y1 [x2 y2 [x3 y3]]\n",argv[0]);return 1;
    }
    double width=strtod(argv[1],NULL),height=strtod(argv[2],NULL),seconds=strtod(argv[3],NULL);
    uint64_t sender_id=strtoull(argv[4],NULL,0);int count=(argc-5)/2;double x[3],y[3];
    if(!isfinite(width)||!isfinite(height)||!isfinite(seconds)||width<100||height<100||seconds<0.05||seconds>5||!sender_id||count<1||count>3)return 2;
    for(int i=0;i<count;i++){
        x[i]=strtod(argv[5+i*2],NULL)/width;y[i]=strtod(argv[6+i*2],NULL)/height;
        if(!isfinite(x[i])||!isfinite(y[i])||x[i]<0||x[i]>1||y[i]<0||y[i]>1)return 2;
    }
    void *library=dlopen("/System/Library/Frameworks/IOKit.framework/IOKit",RTLD_NOW);
    if(!library)return 3;
#define LOAD(variable,name) do{*(void **)(&variable)=dlsym(library,name);if(!variable)return 3;}while(0)
    LOAD(hand,"IOHIDEventCreateDigitizerEvent");LOAD(finger,"IOHIDEventCreateDigitizerFingerEvent");
    LOAD(client_create,"IOHIDEventSystemClientCreate");LOAD(append,"IOHIDEventAppendEvent");
    LOAD(integer,"IOHIDEventSetIntegerValue");LOAD(sender,"IOHIDEventSetSenderID");
    LOAD(dispatch_event,"IOHIDEventSystemClientDispatchEvent");
    CFTypeRef client=client_create(NULL);if(!client)return 4;
    int ok=emit(client,sender_id,0,count,x,y);
    for(int tick=0;ok&&tick<(int)(seconds*60);tick++){
        usleep(16667);ok=emit(client,sender_id,1,count,x,y);
    }
    int released=emit(client,sender_id,2,count,x,y);CFRelease(client);
    printf("contacts=%d duration=%.3f events_created=%d release_created=%d; app response must be verified separately\n",count,seconds,ok,released);
    return ok&&released?0:5;
}
