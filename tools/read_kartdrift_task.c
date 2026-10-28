/* Read-only snapshot of the installed KartDrift process's encrypted page. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/sysctl.h>
#include <mach/mach.h>
#include <mach-o/loader.h>

static int readmem(task_t task, uint64_t addr, void *out, size_t size) {
    vm_size_t got=0;
    kern_return_t k=vm_read_overwrite(task,(vm_address_t)addr,size,(vm_address_t)out,&got);
    return k==KERN_SUCCESS && got==size;
}
int main(int argc,char **argv) {
    if(argc<2){fprintf(stderr,"Usage: %s <decrypted-page-output>\n",argv[0]);return 1;}
    int mib[4]={CTL_KERN,KERN_PROC,KERN_PROC_ALL,0}; size_t size=0;
    if(sysctl(mib,4,NULL,&size,NULL,0)) {perror("sysctl size");return 1;}
    struct kinfo_proc *processes=malloc(size);
    if(sysctl(mib,4,processes,&size,NULL,0)) {perror("sysctl list");return 1;}
    pid_t pid=0;
    for(size_t i=0;i<size/sizeof(*processes);i++)
        if(!strcmp(processes[i].kp_proc.p_comm,"KartDrift"))pid=processes[i].kp_proc.p_pid;
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
    for(uint32_t i=0;i<images.count;i++){
        struct {uint64_t load,path,mod;} image;
        if(!readmem(task,images.array+i*sizeof(image),&image,sizeof(image)))continue;
        char path[1024]={0};
        if(!readmem(task,image.path,path,sizeof(path)-1))continue;
        if(!strstr(path,"/KartDrift.app/KartDrift"))continue;
        printf("Main image 0x%llx %s\n",(unsigned long long)image.load,path);
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
    return 10;
}
