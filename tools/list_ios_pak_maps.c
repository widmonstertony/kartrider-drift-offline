/* Read-only PAK index inventory on the device; stores no game file changes. */
#include <CommonCrypto/CommonCryptor.h>
#include <CommonCrypto/CommonDigest.h>
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <dirent.h>

static const unsigned char key[32]={0x81,0xd1,0x75,0x27,0xf7,0xb0,0x0b,0xb2,0xfe,0x1e,0x61,0xcb,0xcb,0xa5,0xd3,0x40,0xfa,0xd3,0x38,0x85,0xc3,0x75,0x95,0x8f,0x07,0xaf,0x4c,0x64,0xb0,0x1b,0x39,0xe4};
static uint32_t u32(const void *p){uint32_t n;memcpy(&n,p,4);return n;}
static uint64_t u64(const void *p){uint64_t n;memcpy(&n,p,8);return n;}
static unsigned char *block(FILE *f,uint64_t off,uint64_t n,const unsigned char *hash){
 size_t length=(n+15)&~15ULL,got=0;unsigned char *raw=malloc(length),*out=malloc(length);
 fseeko(f,off,SEEK_SET);if(fread(raw,1,length,f)!=length)return NULL;
 if(CCCrypt(kCCDecrypt,kCCAlgorithmAES,kCCOptionECBMode,key,32,NULL,raw,length,out,length,&got)!=kCCSuccess)return NULL;
 free(raw);unsigned char digest[20];CC_SHA1(out,(CC_LONG)n,digest);
 if(hash&&memcmp(hash,digest,20)){free(out);return NULL;}return out;
}
static char *str(unsigned char **p,unsigned char *end){
 if(*p+4>end)return NULL;int32_t n=(int32_t)u32(*p);*p+=4;
 if(n<0||n>1000000||*p+n>end)return NULL;
 char *s=(char*)*p;*p+=n;return s;
}
static void inspect(const char *path){
 FILE *f=fopen(path,"rb");if(!f)return;fseeko(f,-204,SEEK_END);unsigned char tail[204];
 if(fread(tail,1,204,f)!=204||u32(tail)!=0x5a6f12e1||u32(tail+4)!=11){fclose(f);return;}
 uint64_t n=u64(tail+16);unsigned char *index=block(f,u64(tail+8),n,tail+24);
 if(!index){printf("HASH_FAIL %s\n",path);fclose(f);return;}
 unsigned char *p=index,*end=index+n;char *mount=str(&p,end);if(!mount){free(index);fclose(f);return;}
 uint32_t entries=u32(p);p+=12;
 for(int i=0;i<2;i++){
  uint32_t present=u32(p);p+=4;if(!present)continue;
  uint64_t off=u64(p),size=u64(p+8);unsigned char hash[20];memcpy(hash,p+16,20);p+=36;
  if(i==1){
   unsigned char *directory=block(f,off,size,hash);if(!directory)continue;
   unsigned char *q=directory,*de=directory+size;uint32_t count=u32(q);q+=4;unsigned maps=0;
   for(uint32_t j=0;j<count;j++){
    char *dir=str(&q,de);if(!dir)break;uint32_t files=u32(q);q+=4;
    for(uint32_t k=0;k<files;k++){
     char *name=str(&q,de);if(!name){q=de;break;}q+=4;
     if(strstr(name,".umap")){printf("MAP\t%s\t%s%s\n",path,dir,name);maps++;}
    }
   }
   printf("PAK\t%s\tentries=%u maps=%u\n",path,entries,maps);free(directory);
  }
 }
 free(index);fclose(f);
}
int main(int argc,char **argv){
 for(int i=1;i<argc;i++){
  DIR *d=opendir(argv[i]);if(!d){inspect(argv[i]);continue;}struct dirent *e;
  while((e=readdir(d)))if(strstr(e->d_name,".pak")){char path[4096];snprintf(path,sizeof(path),"%s/%s",argv[i],e->d_name);inspect(path);}closedir(d);
 }return 0;
}
