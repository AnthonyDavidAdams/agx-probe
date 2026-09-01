/* agx-probe/isa_probe -- recover AGX instruction encodings by compiling compute
   kernels that differ in exactly one operation and diffing the machine code
   Apple's compiler emits into the GPU arena. Capture point is pipeline-state
   creation, not commit: shader code is written when the pipeline is built. */
#import "agxcommon.h"

static id<MTLDevice> dev;

static const char *kTemplate =
"#include <metal_stdlib>\nusing namespace metal;\n"
"kernel void k(device float *o [[buffer(0)]],\n"
"              device const float *a [[buffer(1)]],\n"
"              device const float *b [[buffer(2)]],\n"
"              uint i [[thread_position_in_grid]]) {\n"
"  o[i] = %s;\n}\n";

typedef struct { const char *name; const char *expr; } Variant;
static Variant V[]={
  {"add",      "a[i] + b[i]"},
  {"sub",      "a[i] - b[i]"},
  {"mul",      "a[i] * b[i]"},
  {"div",      "a[i] / b[i]"},
  {"min",      "min(a[i], b[i])"},
  {"max",      "max(a[i], b[i])"},
  {"fma",      "fma(a[i], b[i], a[i])"},
  {"sqrt",     "sqrt(a[i]) + b[i]"},
  {"rsqrt",    "rsqrt(a[i]) + b[i]"},
  {"floor",    "floor(a[i]) + b[i]"},
  {"ceil",     "ceil(a[i]) + b[i]"},
  {"abs",      "abs(a[i]) + b[i]"},
  {"exp2",     "exp2(a[i]) + b[i]"},
  {"log2",     "log2(a[i]) + b[i]"},
  {"sin",      "sin(a[i]) + b[i]"},
};
#define NV (int)(sizeof(V)/sizeof(V[0]))

typedef struct { int reg; uint64_t off; int len; uint8_t code[2048]; } Slot;
static Slot S[NV];

int main(void){ @autoreleasepool {
  dev=MTLCreateSystemDefaultDevice();
  id keep[NV];

  /* warm: build one pipeline so all lazy allocation settles */
  for(int w=0;w<2;w++){ @autoreleasepool{
    char src[1024]; snprintf(src,sizeof src,kTemplate,"a[i] * 3.0f - b[i] * 7.0f");
    NSError *e=nil; id<MTLLibrary> L=[dev newLibraryWithSource:@(src) options:nil error:&e];
    if(L) (void)[dev newComputePipelineStateWithFunction:[L newFunctionWithName:@"k"] error:&e]; } }

  agx_locate(); fprintf(stderr,"[isa] %d regions / %llu bytes\n",r_n,r_tot);
  agx_alloc(NV+3);

  /* run 0/1: identical builds -> noise mask for the arena */
  { char src[1024]; snprintf(src,sizeof src,kTemplate,"a[i] * 5.0f - b[i] * 11.0f");
    for(int k=0;k<2;k++){ @autoreleasepool{
      NSError *e=nil; id<MTLLibrary> L=[dev newLibraryWithSource:@(src) options:nil error:&e];
      id f=[L newFunctionWithName:@"k"];
      id p=[dev newComputePipelineStateWithFunction:f error:&e]; (void)p;
      agx_snapshot(k); } } }
  long nm=agx_noise(0,1);
  fprintf(stderr,"[isa] arena noise mask %ld bytes\n\n",nm);

  int prev=1;
  for(int v=0; v<NV; v++){ @autoreleasepool{
    char src[1024]; snprintf(src,sizeof src,kTemplate,V[v].expr);
    NSError *e=nil; id<MTLLibrary> L=[dev newLibraryWithSource:@(src) options:nil error:&e];
    if(!L){ fprintf(stderr,"[isa] %s: compile failed\n",V[v].name); S[v].len=0; continue; }
    id f=[L newFunctionWithName:@"k"];
    id p=[dev newComputePipelineStateWithFunction:f error:&e];
    if(!p){ fprintf(stderr,"[isa] %s: pipeline failed\n",V[v].name); S[v].len=0; continue; }
    keep[v]=p;
    int cur=2+v; agx_snapshot(cur);
    /* newly written bytes vs the previous build, minus arena bookkeeping */
    int br=-1,best=0; uint64_t lo=0,hi=0;
    for(int r=0;r<r_n;r++){ uint64_t l=~0ULL,h=0; int cnt=0;
      for(uint64_t o=0;o<r_size[r];o++){
        if(agx_masked(0,1,r,o)) continue;
        if(snap[cur][r][o]!=snap[prev][r][o]){ cnt++; if(o<l)l=o; if(o>h)h=o; } }
      if(cnt>best){best=cnt;br=r;lo=l;hi=h;} }
    S[v].reg=br; S[v].off=lo; S[v].len=(int)(hi-lo+1);
    if(S[v].len>2048) S[v].len=2048;
    if(br>=0) memcpy(S[v].code,&snap[cur][br][lo],S[v].len);
    fprintf(stderr,"[isa] %-6s  reg%-2d 0x%06llx  span %4d bytes  (%d changed)\n",
            V[v].name,br,lo,S[v].len,best);
    prev=cur; } }

  /* ---- compare only within equal-size groups ----
     Slots of different length sit at different alignments, so a slot-relative
     diff across sizes compares unrelated bytes. Within one size class the
     structure is comparable and the differing bytes are the opcode. */
  printf("\nAGX CODE SLOT SIZES\n===================\n");
  for(int v=0;v<NV;v++) printf("  %-6s %4d bytes\n",V[v].name,S[v].len);

  printf("\nOPCODE DIFF WITHIN EQUAL-SIZE GROUPS\n");
  printf("=====================================================================\n");
  int donesz[64]={0}, ndone=0;
  for(int v=0; v<NV; v++){
    if(!S[v].len) continue;
    int sz=S[v].len, seen=0;
    for(int i=0;i<ndone;i++) if(donesz[i]==sz) seen=1;
    if(seen) continue;
    donesz[ndone++]=sz;
    int members[NV], nm=0;
    for(int u=0;u<NV;u++) if(S[u].len==sz) members[nm++]=u;
    if(nm<2) continue;
    printf("\n-- %d-byte slots: ",sz);
    for(int i=0;i<nm;i++) printf("%s%s",V[members[i]].name,i<nm-1?", ":"");
    printf("\n");
    int ref=members[0], ndiff=0;
    /* offsets where ANY member differs from the reference */
    for(int k=0;k<sz;k++){
      int varies=0; for(int i=1;i<nm;i++) if(S[members[i]].code[k]!=S[ref].code[k]) varies=1;
      if(!varies) continue;
      ndiff++;
      if(ndiff<=12){ printf("   +0x%03x :",k);
        for(int i=0;i<nm;i++) printf("  %-6s=%02x",V[members[i]].name,S[members[i]].code[k]);
        printf("\n"); }
    }
    printf("   %d of %d bytes differ across this group%s\n",ndiff,sz,
           ndiff>12?" (first 12 shown)":"");
    if(ndiff && ndiff<=8) printf("   -> candidate opcode field: %d byte(s)\n",ndiff);
  }
  fprintf(stderr,"\n[isa] %d variants captured\n",NV);
}; return 0; }
