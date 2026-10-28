/* Read-only snapshots of the user's preserved iOS 2.71.1 KartDrift process. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/sysctl.h>
#include <mach/mach.h>
#include <mach-o/loader.h>
#include <mach/arm/thread_status.h>

static int readmem(task_t task, uint64_t addr, void *out, size_t size) {
    vm_size_t got=0;
    kern_return_t k=vm_read_overwrite(task,(vm_address_t)addr,size,(vm_address_t)out,&got);
    return k==KERN_SUCCESS && got==size;
}
static void fname(task_t task,uint64_t slide,uint64_t address,char *out,size_t capacity){
    uint32_t name[2]={0};uint64_t block=0;uint16_t header=0;
    snprintf(out,capacity,"?");
    if(!address||!readmem(task,address,name,8))return;
    if(!readmem(task,slide+0x108837ec0ULL+0xd0+(name[0]>>16)*8,&block,8))return;
    uint64_t entry=block+(name[0]&65535)*2;
    if(!readmem(task,entry,&header,2))return;
    size_t length=header>>6;
    if(!length||length>=capacity||length>1023)return;
    if(header&1){
        uint16_t text[1024]={0};if(!readmem(task,entry+2,text,length*2))return;
        for(size_t i=0;i<length;i++)out[i]=text[i]<128?(char)text[i]:'?';
    }else if(!readmem(task,entry+2,out,length))return;
    out[length]=0;
    if(name[1])snprintf(out+length,capacity-length,"_%u",name[1]-1);
}
static void objectname(task_t task,uint64_t slide,uint64_t object,char *out,size_t capacity){
    fname(task,slide,object?object+0x18:0,out,capacity);
}
static void owned_components(task_t task,uint64_t slide,uint64_t actor){
    uint64_t data=0;int count=0;
    if(!readmem(task,actor+0x1a0,&data,8)||!readmem(task,actor+0x1a8,&count,4)||count<0||count>4096)return;
    printf("Owned component slots=%d\n",count);
    for(int i=0;i<count;i++){
        uint64_t value=0,cls=0,meta=0,outer=0;char name[1024]={0},kind[1024]={0},metaname[1024]={0};
        if(!readmem(task,data+i*16,&value,8)||!value||!readmem(task,value+0x10,&cls,8)||!readmem(task,cls+0x10,&meta,8))continue;
        objectname(task,slide,meta,metaname,sizeof(metaname));if(!strstr(metaname,"Class"))continue;
        objectname(task,slide,cls,kind,sizeof(kind));objectname(task,slide,value,name,sizeof(name));readmem(task,value+0x20,&outer,8);
        printf("  Owned[%d] %s:%s object=0x%llx outer=0x%llx\n",i,name,kind,(unsigned long long)value,(unsigned long long)outer);
    }
}
static int structure_depth=0;
static void properties(task_t task,uint64_t slide,uint64_t object,uint64_t cls){
    for(int depth=0;depth<8&&cls;depth++){
        char classname[1024]={0};uint64_t field=0,super=0;
        objectname(task,slide,cls,classname,sizeof(classname));
        readmem(task,cls+0x40,&super,8);readmem(task,cls+0x50,&field,8);
        printf("Class %s\n",classname);
        if(!strcmp(classname,"Actor"))owned_components(task,slide,object);
        for(int i=0;i<400&&field;i++){
            char name[1024]={0},kind[1024]={0};uint64_t type=0,next=0;int offset=0;
            fname(task,slide,field+0x28,name,sizeof(name));
            readmem(task,field+8,&type,8);fname(task,slide,type,kind,sizeof(kind));
            readmem(task,field+0x4c,&offset,4);readmem(task,field+0x20,&next,8);
            printf("  Property %s type=%s offset=0x%x",name,kind,offset);
            if(offset>=0&&offset<0x10000&&!strcmp(kind,"BoolProperty")){
                unsigned char layout[4]={0},byte=0;readmem(task,field+0x78,layout,4);
                readmem(task,object+offset+layout[1],&byte,1);
                printf(" raw=0x%02x mask=0x%02x value=%d",byte,layout[3],!!(byte&layout[3]));
            }
            if(offset>=0&&offset<0x10000&&(!strcmp(kind,"StructProperty")||!strcmp(kind,"SoftObjectProperty")||!strcmp(kind,"SoftClassProperty"))){
                uint64_t words[6]={0};readmem(task,object+offset,words,sizeof(words));
                printf(" raw=");for(int w=0;w<6;w++)printf(" %llx",(unsigned long long)words[w]);
                if(!strcmp(kind,"SoftObjectProperty")||!strcmp(kind,"SoftClassProperty")){
                    char path[1024]={0};fname(task,slide,object+offset+0x10,path,sizeof(path));
                    printf(" assetPath=%s",path);
                }
                if(!strcmp(kind,"StructProperty")){
                    uint64_t structure=0;char sn[1024]={0};readmem(task,field+0x78,&structure,8);
                    objectname(task,slide,structure,sn,sizeof(sn));printf(" struct=%s(0x%llx)",sn,(unsigned long long)structure);
                    if(structure_depth<2&&(!strcmp(sn,"KartDesc")||!strcmp(sn,"CharacterDesc")||!strcmp(sn,"RacePlayerEquipDesc"))){putchar('\n');structure_depth++;properties(task,slide,object+offset,structure);structure_depth--;}
                }
            }
            if(offset>=0&&offset<0x10000&&(!strcmp(kind,"ObjectProperty")||!strcmp(kind,"ClassProperty"))){
                uint64_t value=0;char value_name[1024]={0};readmem(task,object+offset,&value,8);
                objectname(task,slide,value,value_name,sizeof(value_name));printf(" value=%s(0x%llx)",value_name,(unsigned long long)value);
            }
            if(offset>=0&&offset<0x10000&&!strcmp(kind,"StrProperty")){
                uint64_t data=0;int length=0;uint16_t text[256]={0};
                readmem(task,object+offset,&data,8);readmem(task,object+offset+8,&length,4);
                if(data&&length>0&&length<256&&readmem(task,data,text,length*2)){
                    printf(" value=\"");for(int c=0;c<length&&text[c];c++)putchar(text[c]<128?text[c]:'?');putchar('"');
                }
            }
            if(offset>=0&&offset<0x10000&&!strcmp(kind,"ArrayProperty")){
                uint64_t data=0;int length=0;
                readmem(task,object+offset,&data,8);readmem(task,object+offset+8,&length,4);
                printf(" data=0x%llx count=%d",(unsigned long long)data,length);
                /* Only label entries that resolve to a valid UObject class and name. */
                if(data&&length>0&&length<=1000)for(int a=0;a<length&&a<40;a++){
                    uint64_t value=0,valueclass=0;char vn[1024]={0},vc[1024]={0};
                    if(!readmem(task,data+a*8,&value,8)||!value||!readmem(task,value+0x10,&valueclass,8))continue;
                    objectname(task,slide,valueclass,vc,sizeof(vc));objectname(task,slide,value,vn,sizeof(vn));
                    if(strcmp(vc,"?")&&strcmp(vn,"?"))printf(" [%d]=%s:%s(0x%llx)",a,vn,vc,(unsigned long long)value);
                }
            }
            if(offset>=0&&offset<0x10000&&(!strcmp(kind,"FloatProperty")||!strcmp(kind,"IntProperty"))){
                union {float f;int i;} value={0};readmem(task,object+offset,&value,4);
                if(!strcmp(kind,"FloatProperty"))printf(" value=%g",value.f);else printf(" value=%d",value.i);
            }
            if(offset>=0&&offset<0x10000&&(!strcmp(kind,"EnumProperty")||!strcmp(kind,"ByteProperty"))){
                uint8_t value=0;readmem(task,object+offset,&value,1);printf(" first_byte=%u",value);
                uint64_t enumeration=0,names=0;int count=0;
                readmem(task,field+(!strcmp(kind,"EnumProperty")?0x80:0x78),&enumeration,8);
                if(enumeration&&readmem(task,enumeration+0x40,&names,8)&&readmem(task,enumeration+0x48,&count,4)&&names&&count>0&&count<=512){
                    for(int entry=0;entry<count;entry++){
                        int64_t numeric=-1;
                        if(readmem(task,names+entry*16+8,&numeric,8)&&numeric==value){
                            char label[1024]={0};fname(task,slide,names+entry*16,label,sizeof(label));printf(" enum=%s",label);break;
                        }
                    }
                }
            }
            if(offset>=0&&offset<0x10000&&!strcmp(kind,"NameProperty")){
                char value[1024]={0};fname(task,slide,object+offset,value,sizeof(value));printf(" value=%s",value);
            }
            putchar('\n');if(next==field)break;field=next;
        }
        cls=super;
    }
}
int main(int argc,char **argv) {
    if(argc<2){fprintf(stderr,"Usage: %s <decrypted-page-output>|--inspect|--threads\n",argv[0]);return 1;}
    int threads=!strcmp(argv[1],"--threads");
    int inspect=threads||!strcmp(argv[1],"--inspect");
    int mib[4]={CTL_KERN,KERN_PROC,KERN_PROC_ALL,0}; size_t size=0;
    if(sysctl(mib,4,NULL,&size,NULL,0)) {perror("sysctl size");return 1;}
    struct kinfo_proc *processes=malloc(size);
    if(sysctl(mib,4,processes,&size,NULL,0)) {perror("sysctl list");return 1;}
    pid_t pid=0,requested=0;
    const char *requested_text=getenv("KARTDRIFT_INSPECT_PID");
    if(requested_text){
        char *end=NULL;long value=strtol(requested_text,&end,10);
        if(!*requested_text||*end||value<=0||value>INT32_MAX){free(processes);return 2;}
        requested=(pid_t)value;
    }
    for(size_t i=0;i<size/sizeof(*processes);i++){
        pid_t candidate=processes[i].kp_proc.p_pid;
        if(!strcmp(processes[i].kp_proc.p_comm,"KartDrift")&&
           (requested?candidate==requested:candidate>pid))pid=candidate;
    }
    free(processes);
    if(!pid){puts("KartDrift is not running");return 2;}
    task_t task=MACH_PORT_NULL; kern_return_t k=task_for_pid(mach_task_self(),pid,&task);
    printf("KartDrift pid=%d task_for_pid=%d (%s)\n",pid,k,mach_error_string(k));
    if(k)return 3;
    task_dyld_info_data_t info={0};mach_msg_type_number_t count=TASK_DYLD_INFO_COUNT;
    k=task_info(task,TASK_DYLD_INFO,(task_info_t)&info,&count);
    if(k){printf("task_info=%d\n",k);return 4;}
    struct {uint32_t version,count;uint64_t array;} images;
    if(!readmem(task,info.all_image_info_addr,&images,sizeof(images)))return 5;
    uint64_t main_load=0;
    for(uint32_t i=0;i<images.count;i++){
        struct {uint64_t load,path,mod;} image;
        if(!readmem(task,images.array+i*sizeof(image),&image,sizeof(image)))continue;
        char path[1024]={0};
        if(!readmem(task,image.path,path,sizeof(path)-1))continue;
        if(inspect&&i==0)printf("First image 0x%llx %s\n",(unsigned long long)image.load,path);
        if(inspect&&strstr(path,"OfflineProbe"))printf("Probe image 0x%llx %s\n",(unsigned long long)image.load,path);
        if(!strstr(path,"/KartDrift.app/KartDrift")&&!strstr(path,"/KartDriftOfflineLocal.app/KartDrift"))continue;
        main_load=image.load;
        printf("Main image 0x%llx %s\n",(unsigned long long)image.load,path);
        if(inspect)continue;
        struct mach_header_64 h;
        if(!readmem(task,image.load,&h,sizeof(h))||h.magic!=MH_MAGIC_64)return 6;
        unsigned char *commands=malloc(h.sizeofcmds);
        if(!readmem(task,image.load+sizeof(h),commands,h.sizeofcmds))return 7;
        uint32_t off=0;
        for(uint32_t j=0;j<h.ncmds;j++){
            struct load_command *lc=(void*)(commands+off);
            if(lc->cmd==LC_ENCRYPTION_INFO_64){
                struct encryption_info_command_64 *ec=(void*)lc;
                unsigned char *page=malloc(ec->cryptsize);
                if(!readmem(task,image.load+ec->cryptoff,page,ec->cryptsize))return 8;
                const char *dest=argv[1];
                FILE *f=fopen(dest,"wb");if(!f){perror("output");return 9;}
                fwrite(page,1,ec->cryptsize,f);fclose(f);
                printf("Saved %u bytes at file offset %u to %s\n",ec->cryptsize,ec->cryptoff,dest);
                free(page);free(commands);mach_port_deallocate(mach_task_self(),task);return 0;
            }
            off+=lc->cmdsize;
        }
        free(commands);
    }
    if(inspect&&main_load){
        /* Fixed addresses verified in the preserved iOS 2.71.1 client only. */
        uint64_t slide=main_load-0x100000000ULL;
        unsigned char initialized=0;uint16_t command[2048]={0};
        if(readmem(task,slide+0x108a3ae41ULL,&initialized,1))printf("FCommandLine initialized=%u\n",initialized);
        if(readmem(task,slide+0x108a3ae42ULL,command,sizeof(command))){
            printf("FCommandLine ASCII: ");
            for(int i=0;i<2047&&command[i];i++)putchar(command[i]<128?(char)command[i]:'?');
            putchar('\n');
        }
        uint64_t engine=0,contexts=0;int context_count=0;
        if(readmem(task,slide+0x108b0b288ULL,&engine,8)&&engine){
            /* Engine subsystem collection: inspect only the independently
               identified table/data-asset managers, never call their methods. */
            uint64_t collection=0,entries=0;int entry_count=0;
            if(readmem(task,engine+0xc60,&collection,8)&&collection&&
               readmem(task,collection+0x10,&entries,8)&&
               readmem(task,collection+0x18,&entry_count,4)&&entry_count>0&&entry_count<512){
                for(int n=0;n<entry_count;n++){
                    uint64_t cls=0,object=0,actual=0;char kind[1024]={0};
                    if(!readmem(task,entries+n*24,&cls,8)||!cls)continue;
                    objectname(task,slide,cls,kind,sizeof(kind));
                    if(strcmp(kind,"TableManager")&&strcmp(kind,"DataAssetManager"))continue;
                    if(!readmem(task,entries+n*24+8,&object,8)||!object||
                       !readmem(task,object+0x10,&actual,8)||actual!=cls)continue;
                    printf("EngineSubsystem %s object=0x%llx\n",kind,(unsigned long long)object);
                    properties(task,slide,object,cls);
                    if(!strcmp(kind,"TableManager")){
                        uint64_t tables=0;int slots=0,free_slots=0;
                        readmem(task,object+0x38,&tables,8);readmem(task,object+0x40,&slots,4);
                        readmem(task,object+0x6c,&free_slots,4);
                        printf("OriginalTables slots=%d free=%d\n",slots,free_slots);
                        if(slots>0&&slots<1024)for(int t=0;t<slots;t++){
                            unsigned char type=0;uint64_t table=0,tc=0;char name[1024]={0},table_class[1024]={0};
                            readmem(task,tables+t*24,&type,1);readmem(task,tables+t*24+8,&table,8);
                            if(!table||!readmem(task,table+0x10,&tc,8))continue;
                            objectname(task,slide,tc,table_class,sizeof(table_class));
                            if(strcmp(table_class,"DataTable"))continue;
                            objectname(task,slide,table,name,sizeof(name));
                            printf("  OriginalTable type=%u name=%s object=0x%llx\n",type,name,(unsigned long long)table);
                        }
                    }
                }
            }
            readmem(task,engine+0xc48,&contexts,8);
            readmem(task,engine+0xc50,&context_count,4);
            printf("GEngine=0x%llx contexts=%d\n",(unsigned long long)engine,context_count);
            uint64_t viewport=0,viewport_class=0;
            if(readmem(task,engine+0x798,&viewport,8)&&viewport&&readmem(task,viewport+0x10,&viewport_class,8)){
                printf("GameViewport=0x%llx\n",(unsigned long long)viewport);
                properties(task,slide,viewport,viewport_class);
            }
            if(context_count>0&&context_count<16)for(int i=0;i<context_count;i++){
                uint64_t context=0,world=0,level=0;uint32_t name[2]={0};
                readmem(task,contexts+i*8,&context,8);
                readmem(task,context+0x280,&world,8);
                if(world){
                    readmem(task,world+0x18,name,8);
                    readmem(task,world+0x30,&level,8);
                }
                char worldname[1024]={0};objectname(task,slide,world,worldname,sizeof(worldname));
                printf("World[%d]=0x%llx name=%s FName=%08x:%08x level=0x%llx\n",i,(unsigned long long)world,worldname,name[0],name[1],(unsigned long long)level);
                uint64_t worldclass=0;readmem(task,world+0x10,&worldclass,8);properties(task,slide,world,worldclass);
                uint64_t loaded_levels=0;int loaded_count=0;
                readmem(task,world+0x138,&loaded_levels,8);readmem(task,world+0x140,&loaded_count,4);
                if(loaded_count>0&&loaded_count<256)for(int n=0;n<loaded_count;n++){
                    uint64_t loaded=0,outer=0,list=0;int count=0,checkpoints=0;char map[1024]={0};
                    readmem(task,loaded_levels+n*8,&loaded,8);readmem(task,loaded+0x20,&outer,8);
                    objectname(task,slide,outer,map,sizeof(map));readmem(task,loaded+0x98,&list,8);readmem(task,loaded+0xa0,&count,4);
                    if(count>0&&count<10000)for(int a=0;a<count;a++){
                        uint64_t actor=0,cls=0;char cn[1024]={0};
                        if(!readmem(task,list+a*8,&actor,8)||!actor)continue;
                        readmem(task,actor+0x10,&cls,8);objectname(task,slide,cls,cn,sizeof(cn));
                        if(strstr(cn,"CheckPoint"))checkpoints++;
                    }
                    printf("LoadedLevel[%d] map=%s actors=%d checkpoints=%d\n",n,map,count,checkpoints);
                }
                uint64_t actors=0;int actor_count=0;
                if(level){readmem(task,level+0x98,&actors,8);readmem(task,level+0xa0,&actor_count,4);}
                printf("Actors=%d\n",actor_count);
                if(actor_count>0&&actor_count<10000)for(int a=0;a<actor_count;a++){
                    uint64_t actor=0,cls=0;char actorname[1024]={0},classname[1024]={0};
                    if(!readmem(task,actors+a*8,&actor,8)||!actor)continue;
                    objectname(task,slide,actor,actorname,sizeof(actorname));
                    readmem(task,actor+0x10,&cls,8);objectname(task,slide,cls,classname,sizeof(classname));
                    if(a<3||strstr(classname,"Kart")||strstr(classname,"Item")||strstr(classname,"Controller")||strstr(classname,"GameMode")||strstr(classname,"GameState")||strstr(classname,"License")||strstr(classname,"Camera")||strstr(classname,"Pawn"))
                        printf("Actor[%d] %s class=%s address=0x%llx\n",a,actorname,classname,(unsigned long long)actor);
                    if(!strcmp(classname,"LicensePawn")||!strcmp(classname,"LicenseGameState")||!strcmp(classname,"LicenseGameMode")||!strcmp(classname,"KdPlayerController")||strstr(classname,"Camera"))properties(task,slide,actor,cls);
                }
            }
        }
        for(int argument=2;argument<argc;argument++){
            uint64_t object=strtoull(argv[argument],NULL,0),cls=0;char name[1024]={0};
            if(object&&readmem(task,object+0x10,&cls,8)){
                objectname(task,slide,object,name,sizeof(name));printf("Requested object %s 0x%llx\n",name,(unsigned long long)object);properties(task,slide,object,cls);
                uint64_t table=0;char classname[1024]={0};
                objectname(task,slide,cls,classname,sizeof(classname));
                if(!strcmp(classname,"FollowTGMoveComponent")){
                    uint8_t racing=0,drift=0;
                    readmem(task,object+0xb0,&racing,1);readmem(task,object+0x128,&drift,1);
                    printf("PathDriver racing=%u drift=%u\n",racing,drift);
                }
                if(!strcmp(classname,"KartMovementComponent")){
                    uint8_t assist=0,auto_drive=0;
                    readmem(task,object+0xed6,&assist,1);readmem(task,object+0xedd,&auto_drive,1);
                    printf("MovementFlags assist=%u auto_drive=%u\n",assist,auto_drive);
                    /* Verified against original iOS input handlers near
                       0x10268cba8: input latch, steering, and drift state. */
                    uint8_t input=0,state=0,held=0,request=0;float steering=0;
                    readmem(task,object+0x188,&input,1);
                    readmem(task,object+0x1e8,&steering,4);
                    readmem(task,object+0xb70,&state,1);
                    readmem(task,object+0xb78,&held,1);
                    readmem(task,object+0xb8d,&request,1);
                    printf("PlayerInput steering=%g drift_input=%u drift_state=%u drift_held=%u drift_request=%u\n",
                           steering,input,state,held,request);
                }
                if(!strcmp(classname,"MajorResultWidgetComponent")){
                    uint64_t widget=0,provider=0,styler=0,style_table=0;
                    uint16_t style_flags=0;
                    readmem(task,object+0xc8,&widget,8);
                    readmem(task,object+0xd8,&provider,8);
                    readmem(task,object+0xe0,&styler,8);
                    if(styler){
                        readmem(task,styler,&style_table,8);
                        readmem(task,styler+8,&style_flags,2);
                    }
                    printf("ResultWidget widget=0x%llx provider=0x%llx styler=0x%llx styler_table_main=0x%llx flags=0x%04x\n",
                           (unsigned long long)widget,(unsigned long long)provider,
                           (unsigned long long)styler,
                           (unsigned long long)(style_table?style_table-slide:0),style_flags);
                }
                unsigned word_start=0,word_end=0;
                if(!strcmp(classname,"MajorConnectRuleComponent")||!strcmp(classname,"RaceTimeComponent")){
                    word_start=0x100;word_end=0x158;
                }else if(!strcmp(classname,"RaceRankComponent")){
                    word_start=0x1b0;word_end=0x1f0;
                }else if(!strcmp(classname,"RaceProgressComponent")){
                    word_start=0x140;word_end=0x180;
                    for(unsigned offset=0x1c0;offset<0x1d0;offset+=4){
                        uint32_t word=0;if(readmem(task,object+offset,&word,4))printf("ProgressWord +0x%x bits=0x%08x\n",offset,word);
                    }
                }
                if(word_end){
                    /* Bounded, read-only diagnostic fields in these independently
                       identified components; no arbitrary process-memory writes. */
                    for(unsigned offset=word_start;offset<word_end;offset+=4){
                        union{uint32_t bits;float value;} word={0};
                        if(readmem(task,object+offset,&word.bits,4))
                            printf("ComponentWord +0x%x bits=0x%08x float=%g\n",offset,word.bits,word.value);
                    }
                }
                /* The inspected class tables are independently known to exceed
                   this window. Do not walk beyond arbitrary UObject tables. */
                unsigned table_limit=(!strcmp(classname,"MajorConnectRuleComponent"))?0x480:
                    (!strcmp(classname,"Transition_BeginRace"))?0x280:
                    (!strcmp(classname,"KdAssetManager")||!strcmp(classname,"KartSkeletalMeshComponent"))?0x400:0;
                if(table_limit&&readmem(task,object,&table,8))for(unsigned offset=0;offset<table_limit;offset+=8){
                    uint64_t entry=0;
                    if(readmem(task,table+offset,&entry,8)&&entry>=main_load&&entry<main_load+0x9000000ULL)
                        printf("VTable +0x%x main=0x%llx\n",offset,(unsigned long long)(entry-slide));
                }
            }
        }
        if(threads){
            thread_act_array_t list=NULL;mach_msg_type_number_t total=0;
            k=task_threads(task,&list,&total);
            printf("task_threads=%d count=%u\n",k,total);
            if(k==KERN_SUCCESS){
                for(unsigned i=0;i<total;i++){
                    arm_thread_state64_t state={0};
                    mach_msg_type_number_t length=ARM_THREAD_STATE64_COUNT;
                    k=thread_get_state(list[i],ARM_THREAD_STATE64,(thread_state_t)&state,&length);
                    if(k==KERN_SUCCESS){
                        uint64_t pc=arm_thread_state64_get_pc(state),lr=arm_thread_state64_get_lr(state),fp=arm_thread_state64_get_fp(state);
                        printf("Thread %u pc=0x%llx lr=0x%llx\n",i,(unsigned long long)pc,(unsigned long long)lr);
                        for(unsigned depth=0;depth<28&&fp;depth++){
                            uint64_t frame[2]={0};
                            if(!readmem(task,fp,frame,sizeof(frame)))break;
                            uint64_t ret=frame[1]&0x0000000fffffffffULL;
                            printf("  #%u lr=0x%llx",depth,(unsigned long long)ret);
                            if(ret>=main_load&&ret<main_load+0x9000000ULL)printf(" main=0x%llx",(unsigned long long)(ret-slide));
                            putchar('\n');
                            if(frame[0]<=fp||frame[0]-fp>0x100000)break;
                            fp=frame[0];
                        }
                    }
                    mach_port_deallocate(mach_task_self(),list[i]);
                }
                vm_deallocate(mach_task_self(),(vm_address_t)list,total*sizeof(thread_t));
            }
        }
        mach_port_deallocate(mach_task_self(),task);return 0;
    }
    return 10;
}
