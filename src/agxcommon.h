/* agx-probe: shared capture machinery.
   Snapshots GPU-visible memory at command-buffer commit and diffs across
   one-variable-at-a-time sweeps of GPU state. */
#ifndef AGXCOMMON_H
#define AGXCOMMON_H
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <objc/runtime.h>
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <dispatch/dispatch.h>

#define MAXR 96
#define MAXRUN 512

static uint64_t r_addr[MAXR], r_size[MAXR]; static int r_n=0; static uint64_t r_tot=0;
static uint8_t *snap[MAXRUN][MAXR];
static int g_run=-1; static IMP orig_commit;

/* VM_MEMORY_IOACCELERATOR (100) and VM_MEMORY_IOKIT (21) hold the
   GPU-visible command/descriptor arenas. */
static void agx_locate(void){
  mach_vm_address_t a=0; mach_vm_size_t s=0; natural_t d=0; r_n=0; r_tot=0;
  while(r_n<MAXR){ vm_region_submap_info_data_64_t i; mach_msg_type_number_t c=VM_REGION_SUBMAP_INFO_COUNT_64;
    if(mach_vm_region_recurse(mach_task_self(),&a,&s,&d,(vm_region_recurse_info_t)&i,&c)!=KERN_SUCCESS) break;
    if(i.is_submap){d++;continue;}
    if((i.user_tag==100||i.user_tag==21)&&(i.protection&VM_PROT_READ)&&(i.protection&VM_PROT_WRITE)
       && i.pages_resident>0 && s>=4096 && s<=(1u<<20)){ r_addr[r_n]=a; r_size[r_n]=s; r_tot+=s; r_n++; }
    a+=s; }
}
static void agx_snapshot(int run){
  for(int r=0;r<r_n;r++){ mach_vm_size_t g=0;
    mach_vm_read_overwrite(mach_task_self(),r_addr[r],r_size[r],(mach_vm_address_t)snap[run][r],&g); }
}
/* Some state is written by the driver DURING commit, not before it: capturing
   only on entry shows the previous submission's value (clearDepth lags by one).
   g_post selects capture after the original commit returns. */
static int g_post=0;
static void agx_commit_hook(id self, SEL _cmd){
  if(!g_post && g_run>=0 && g_run<MAXRUN) agx_snapshot(g_run);
  ((void(*)(id,SEL))orig_commit)(self,_cmd);
  if(g_post && g_run>=0 && g_run<MAXRUN) agx_snapshot(g_run);
}
/* Metal encoding is lazy: nothing reaches GPU memory until commit, so we
   capture inside a swizzle on the driver's own commit. */
static int agx_install(const char *cls){
  Class k=objc_getClass(cls); if(!k){fprintf(stderr,"[agx] no class %s\n",cls); return 0;}
  Method m=class_getInstanceMethod(k,@selector(commit));
  orig_commit=method_getImplementation(m); method_setImplementation(m,(IMP)agx_commit_hook);
  return 1;
}
static int g_nruns=0;
static void agx_alloc(int nruns){ g_nruns=nruns;
  for(int i=0;i<nruns&&i<MAXRUN;i++) for(int r=0;r<r_n;r++) snap[i][r]=malloc(r_size[r]); }

/* Bytes that differ between two identical runs are allocator bookkeeping,
   counters and handles. Masking them is what makes every later diff readable. */
static long agx_noise(int a,int b){ long n=0;
  for(int r=0;r<r_n;r++) for(uint64_t o=0;o<r_size[r];o++) if(snap[a][r][o]!=snap[b][r][o]) n++;
  return n; }
static int agx_masked(int a,int b,int r,uint64_t o){ return snap[a][r][o]!=snap[b][r][o]; }

typedef enum { K_ENUM, K_INT, K_FLOAT } Kind;
typedef struct { const char *name; int kind; int n; double v[64]; } AxisMeta;

/* Classify one offset against one axis sweep. Returns a description or NULL. */
static const char *agx_classify(int r,uint64_t o,int s,AxisMeta *ax,char *buf,size_t bs){
  int n=ax->n;
  if(ax->kind==K_FLOAT){
    if(o+4>r_size[r]) return NULL;
    int varies=0; for(int j=1;j<n;j++) if(memcmp(&snap[s+j][r][o],&snap[s][r][o],4)) varies=1;
    if(!varies) return NULL;
    for(int j=0;j<n;j++){ uint32_t b; float f; memcpy(&b,&snap[s+j][r][o],4); memcpy(&f,&b,4);
      if(f!=(float)ax->v[j]) return NULL; }
    snprintf(buf,bs,"float32 LE"); return buf;
  }
  uint8_t v0=snap[s][r][o]; int varies=0;
  for(int j=1;j<n;j++) if(snap[s+j][r][o]!=v0) varies=1;
  if(!varies) return NULL;
  if(ax->kind==K_INT){
    for(int sh=0;sh<32;sh+=8){ int ok=1;
      for(int j=0;j<n;j++) if(snap[s+j][r][o]!=(uint8_t)(((uint32_t)ax->v[j]>>sh)&0xFF)){ok=0;break;}
      if(ok){ snprintf(buf,bs,"byte %d of LE int",sh/8); return buf; } }
    return NULL;
  }
  /* enum: the field is exactly as wide as the axis's value range requires
     (ceil(log2(max+1))). Searching for the *widest* mask that happens to fit
     over-reports, because high bits that are constant-zero always match;
     searching for the narrowest under-reports for the same reason. */
  int mx=0; for(int j=0;j<n;j++) if((int)ax->v[j]>mx) mx=(int)ax->v[j];
  int w=1; while((1<<w)-1 < mx) w++;
  int msk=(1<<w)-1;
  for(int sh=0;sh+w<=16;sh++){
    if(o+2>r_size[r] && sh+w>8) continue;
    int ok=1;
    for(int j=0;j<n;j++){ uint16_t wd=snap[s+j][r][o];
      if(o+1<r_size[r]) wd |= (uint16_t)snap[s+j][r][o+1]<<8;
      if((int)((wd>>sh)&msk)!=(int)ax->v[j]){ok=0;break;} }
    if(!ok) continue;
    /* must discriminate: as many distinct extracted values as the sweep has */
    int dv=0,sv[64]={0};
    for(int j=0;j<n;j++){ uint16_t wd=snap[s+j][r][o];
      if(o+1<r_size[r]) wd|=(uint16_t)snap[s+j][r][o+1]<<8;
      int y=(wd>>sh)&msk; if(y<64&&!sv[y]){sv[y]=1;dv++;} }
    if(dv<n) continue;
    snprintf(buf,bs,"%d-bit field at bit %d",w,sh); return buf;
  }
  /* Identity failed. A hardware enum need not use Metal's numbering, so accept
     a consistent BIJECTION: n distinct extracted values, same input always
     giving the same output. Requiring all n distinct keeps this selective. */
  for(int w2=1; w2<=4; w2++){
    if((1<<w2) < n) continue;
    int msk2=(1<<w2)-1;
    for(int sh=0; sh+w2<=16; sh++){
      if(o+2>r_size[r] && sh+w2>8) continue;
      int seen[16]; for(int t=0;t<16;t++) seen[t]=-1;
      int ok=1, dv=0;
      for(int j=0;j<n && ok;j++){
        uint16_t wd=snap[s+j][r][o];
        if(o+1<r_size[r]) wd |= (uint16_t)snap[s+j][r][o+1]<<8;
        int y=(wd>>sh)&msk2;
        for(int t=0;t<j;t++){
          uint16_t wt=snap[s+t][r][o];
          if(o+1<r_size[r]) wt |= (uint16_t)snap[s+t][r][o+1]<<8;
          int yt=(wt>>sh)&msk2;
          if((yt==y) != ((int)ax->v[t]==(int)ax->v[j])) { ok=0; break; }
        }
        if(ok && seen[y]<0){ seen[y]=j; dv++; }
      }
      if(!ok || dv!=n) continue;
      int u=snprintf(buf,bs,"%d-bit @bit %d, permuted:",w2,sh);
      for(int j=0;j<n && u<(int)bs-8;j++){
        uint16_t wd=snap[s+j][r][o];
        if(o+1<r_size[r]) wd |= (uint16_t)snap[s+j][r][o+1]<<8;
        u+=snprintf(buf+u,bs-u," %d->%d",(int)ax->v[j],(wd>>sh)&msk2);
      }
      return buf;
    }
  }
  return NULL;
}
#endif
