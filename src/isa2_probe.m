/* agx-probe/isa2_probe -- recover AGX instruction *format*, not just opcodes.
   Compile kernels differing in one immediate constant or one operand, capture
   the emitted code slot, and diff within equal-size groups. An immediate that
   appears verbatim as float32 tells us literals are inline; a small index tells
   us there is a constant pool. Operand swaps expose the register fields. */
#import "agxcommon.h"
static id<MTLDevice> dev;
#define MAXV 8
typedef struct { int reg; uint64_t off; int len; uint8_t code[4096]; } Slot;
static Slot S[MAXV];

static const char *kT =
"#include <metal_stdlib>\nusing namespace metal;\n"
"kernel void k(device float *o [[buffer(0)]],\n"
"              device const float *a [[buffer(1)]],\n"
"              device const float *b [[buffer(2)]],\n"
"              device const float *c [[buffer(3)]],\n"
"              uint i [[thread_position_in_grid]]) {\n  o[i] = %s;\n}\n";

static int build(const char *expr, int cur, int prev){
  @autoreleasepool{
    char src[1024]; snprintf(src,sizeof src,kT,expr);
    NSError *e=nil; id<MTLLibrary> L=[dev newLibraryWithSource:@(src) options:nil error:&e];
    if(!L) return 0;
    id p=[dev newComputePipelineStateWithFunction:[L newFunctionWithName:@"k"] error:&e];
    if(!p) return 0;
    CFRetain((__bridge CFTypeRef)p);
    agx_snapshot(cur);
    int br=-1,best=0; uint64_t lo=0,hi=0;
    for(int r=0;r<r_n;r++){ uint64_t l=~0ULL,h=0; int cnt=0;
      for(uint64_t o=0;o<r_size[r];o++){
        if(agx_masked(0,1,r,o)) continue;
        if(snap[cur][r][o]!=snap[prev][r][o]){cnt++; if(o<l)l=o; if(o>h)h=o;} }
      if(cnt>best){best=cnt;br=r;lo=l;hi=h;} }
    int idx=cur-2;
    uint64_t alo = lo & ~63ULL;          /* 64-byte quantum, per the size tiers */
    S[idx].reg=br; S[idx].off=alo; S[idx].len=br<0?0:(int)(hi-alo+1);
    if(S[idx].len>4096) S[idx].len=4096;
    if(br>=0) memcpy(S[idx].code,&snap[cur][br][alo],S[idx].len);
    return S[idx].len;
  }
}

typedef struct { const char *name; int n; const char *expr[MAXV]; float imm[MAXV]; } Grp;
static Grp G[]={
 {"immediate float", 6,
  {"a[i]*0.75f","a[i]*1.5f","a[i]*2.5f","a[i]*3.5f","a[i]*4.5f","a[i]*5.5f"},
  {0,1.5f,2.5f,3.5f,4.5f,5.5f}},
 {"immediate add",   6,
  {"a[i]+0.75f","a[i]+1.5f","a[i]+2.5f","a[i]+3.5f","a[i]+4.5f","a[i]+5.5f"},
  {0,1.5f,2.5f,3.5f,4.5f,5.5f}},
 {"operand order",   5,
  {"b[i]-c[i]","a[i]-b[i]","b[i]-a[i]","a[i]-c[i]","c[i]-a[i]"},{0,0,0,0,0}},
 {"operand count",   4,
  {"a[i]+c[i]","a[i]+b[i]","a[i]+b[i]+c[i]","a[i]+b[i]+c[i]+a[i]"},{0,0,0,0}},
};
#define NG (int)(sizeof(G)/sizeof(G[0]))

int main(void){ @autoreleasepool {
  dev=MTLCreateSystemDefaultDevice();
  for(int w=0;w<2;w++) @autoreleasepool{
    char src[1024]; snprintf(src,sizeof src,kT,"a[i]*7.25f-b[i]*3.125f");
    NSError *e=nil; id<MTLLibrary> L=[dev newLibraryWithSource:@(src) options:nil error:&e];
    if(L)(void)[dev newComputePipelineStateWithFunction:[L newFunctionWithName:@"k"] error:&e]; }
  agx_locate(); agx_alloc(MAXV+4);
  fprintf(stderr,"[isa2] %d regions\n",r_n);
  { char src[1024]; snprintf(src,sizeof src,kT,"a[i]*9.75f+b[i]*1.375f");
    for(int k2=0;k2<2;k2++) @autoreleasepool{
      NSError *e=nil; id<MTLLibrary> L=[dev newLibraryWithSource:@(src) options:nil error:&e];
      (void)[dev newComputePipelineStateWithFunction:[L newFunctionWithName:@"k"] error:&e];
      agx_snapshot(k2); } }
  fprintf(stderr,"[isa2] arena noise %ld bytes\n\n",agx_noise(0,1));

  for(int g=0; g<NG; g++){
    printf("\n=== %s ===\n",G[g].name);
    /* re-baseline: the first slot after the previous group otherwise
       accumulates that group's writes and reads as a huge outlier */
    @autoreleasepool{ char src[1024];
      snprintf(src,sizeof src,kT,"a[i]*13.5f+b[i]*0.375f-c[i]");
      NSError *e=nil; id<MTLLibrary> L=[dev newLibraryWithSource:@(src) options:nil error:&e];
      if(L)(void)[dev newComputePipelineStateWithFunction:[L newFunctionWithName:@"k"] error:&e];
      agx_snapshot(MAXV+2); }
    int prev=MAXV+2;
    for(int j=0;j<G[g].n;j++){ int L=build(G[g].expr[j],2+j,prev); prev=2+j;
      printf("  %-24s slot %4d bytes\n",G[g].expr[j],L); }
    int n=G[g].n, same=1, Lmin=S[1].len, Lmax=S[1].len;   /* index 0 is the throwaway */
    for(int j=2;j<n;j++){ if(!S[j].len){same=0;break;}
      if(S[j].len<Lmin)Lmin=S[j].len; if(S[j].len>Lmax)Lmax=S[j].len; }
    if(same && Lmax-Lmin>1) same=0;      /* +-1 is allocator alignment, not code */
    if(!same){ printf("  -> slot size varies by %d bytes; not comparable\n",Lmax-Lmin); continue; }
    int L=Lmin, nd=0; int offs[64];
    for(int k=0;k<L;k++){ int v=0; for(int j=2;j<n;j++) if(S[j].code[k]!=S[1].code[k]) v=1;
      if(v){ if(nd<64) offs[nd]=k; nd++; } }
    printf("  -> %d of %d bytes differ across the group (throwaway excluded)\n",nd,L);
    if(nd && nd<=24){
      for(int q=0;q<nd && q<12;q++){ printf("     +0x%03x :",offs[q]);
        for(int j=1;j<n;j++) printf(" %02x",S[j].code[offs[q]]); printf("\n"); }
    }
    /* is the literal stored inline as float32? */
    if(G[g].imm[1]!=0.0f){
      int hit=-1;
      for(int k=0;k+4<=L;k++){ int ok=1;
        for(int j=1;j<n;j++){ float f; memcpy(&f,&S[j].code[k],4); if(f!=G[g].imm[j]){ok=0;break;} }
        if(ok){ hit=k; break; } }
      if(hit>=0) printf("     >> IMMEDIATE stored INLINE as float32 at slot +0x%x\n",hit);
      else       printf("     >> immediate NOT inline float32 (constant pool or packed literal)\n");
    }
  }
}; return 0; }
