/* agx-probe/isa_exec_probe -- the ISA equivalent of write_probe.
   Compile two kernels differing in one operation, diff their aligned code
   slots to find the candidate opcode bytes, then patch those bytes in the
   FIRST kernel's live code and execute it with known inputs. If the arithmetic
   changes to match the second kernel, the opcode field is proven semantically
   -- a numeric oracle, not a visual one. */
#import "agxcommon.h"
#include <time.h>
#include <math.h>

static id<MTLDevice> dev; static id<MTLCommandQueue> q; static unsigned g_nonce;
static const char *kT =
"#include <metal_stdlib>\nusing namespace metal;\n"
"kernel void %s(device float *o [[buffer(0)]],\n"
"              device const float *a [[buffer(1)]],\n"
"              device const float *b [[buffer(2)]],\n"
"              uint i [[thread_position_in_grid]]) {\n  o[i] = %s;\n}\n";

typedef struct { int reg; uint64_t off; int len; uint8_t code[4096]; } Slot;

static char g_fn[64];
static id<MTLComputePipelineState> mk(const char *expr){
  static int seq=0; snprintf(g_fn,sizeof g_fn,"k%u_%d",(unsigned)(g_nonce),seq++);
  char src[2048]; snprintf(src,sizeof src,kT,g_fn,expr);
  NSError *e=nil; id<MTLLibrary> L=[dev newLibraryWithSource:@(src) options:nil error:&e];
  if(!L){ fprintf(stderr,"compile: %s\n",e.description.UTF8String); return nil; }
  id<MTLComputePipelineState> p=[dev newComputePipelineStateWithFunction:[L newFunctionWithName:@(g_fn)] error:&e];
  if(!p) fprintf(stderr,"pipeline: %s\n",e.description.UTF8String);
  return p;
}
/* run the kernel on known inputs; return o[0] */
static float run(id<MTLComputePipelineState> p, float av, float bv){
  __block float out=NAN;
  @autoreleasepool{
    float A[4]={av,av,av,av}, B[4]={bv,bv,bv,bv};
    id<MTLBuffer> bo=[dev newBufferWithLength:16 options:MTLResourceStorageModeShared];
    id<MTLBuffer> ba=[dev newBufferWithBytes:A length:16 options:MTLResourceStorageModeShared];
    id<MTLBuffer> bb=[dev newBufferWithBytes:B length:16 options:MTLResourceStorageModeShared];
    id<MTLCommandBuffer> cb=[q commandBuffer];
    id<MTLComputeCommandEncoder> en=[cb computeCommandEncoder];
    [en setComputePipelineState:p];
    [en setBuffer:bo offset:0 atIndex:0]; [en setBuffer:ba offset:0 atIndex:1]; [en setBuffer:bb offset:0 atIndex:2];
    [en dispatchThreads:MTLSizeMake(4,1,1) threadsPerThreadgroup:MTLSizeMake(4,1,1)];
    [en endEncoding]; [cb commit]; [cb waitUntilCompleted];
    out=((float*)bo.contents)[0];
  }
  return out;
}
static int capture(int cur,int prev,Slot *S){
  agx_snapshot(cur);
  int br=-1,best=0; uint64_t lo=0,hi=0;
  for(int r=0;r<r_n;r++){ uint64_t l=~0ULL,h=0; int c=0;
    for(uint64_t o=0;o<r_size[r];o++){
      if(agx_masked(0,1,r,o)) continue;
      if(snap[cur][r][o]!=snap[prev][r][o]){c++; if(o<l)l=o; if(o>h)h=o;} }
    if(c>best){best=c;br=r;lo=l;hi=h;} }
  if(br<0) return 0;
  /* Slots are 256-byte pitched. Measuring length by diff extent understates it
     whenever the previous build wrote similar code to the same recycled slot,
     so read a fixed slot from the aligned start instead. */
  #define SLOTSZ 256
  uint64_t alo=lo & ~63ULL;
  if(alo+SLOTSZ > r_size[br]) return 0;
  S->reg=br; S->off=alo; S->len=SLOTSZ;
  memcpy(S->code,&snap[cur][br][alo],SLOTSZ);
  return SLOTSZ;
}

int main(void){ @autoreleasepool {
  dev=MTLCreateSystemDefaultDevice(); q=[dev newCommandQueue];
  /* Metal caches compiled shaders on disk across process runs, so a source seen
     in an earlier session is served from cache and barely touches the arena.
     A fresh nonce per run, identical in both kernels, defeats that while
     leaving the operator as the only difference. */
  srandom((unsigned)time(NULL)); g_nonce=(unsigned)(random()%1000000);
  const char *eAdd="a[i] + b[i]", *eSub="a[i] - b[i]";
  const char *eF1 ="a[i] * b[i]", *eF2 ="min(a[i],b[i])";
  fprintf(stderr,"[exec] nonce fn suffix=%u\n",g_nonce);
  for(int w=0;w<2;w++){ id p=mk("a[i]*3.25f-b[i]*7.5f"); (void)p; }
  agx_locate(); agx_alloc(8);
  fprintf(stderr,"[exec] %d regions\n",r_n);
  { id p1=mk("a[i]*9.5f+b[i]*0.125f"); agx_snapshot(0);
    id p2=mk("a[i]*9.5f+b[i]*0.125f"); agx_snapshot(1); (void)p1;(void)p2; }
  fprintf(stderr,"[exec] arena noise %ld bytes\n\n",agx_noise(0,1));

  static Slot SA,SB,SJ;
  /* Each measured kernel needs its own settled predecessor of the same shape:
     a slot captured straight after a differently-shaped build reads short. */
  /* Build the kernel we intend to PATCH last: later pipeline builds recycle
     arena slots, so an earlier kernel's code is no longer where we captured it. */
  id f1=mk(eF1); (void)f1; capture(2,1,&SJ);
  id<MTLComputePipelineState> pSub=mk(eSub); int lenB=capture(3,2,&SB);
  id f2=mk(eF2); (void)f2; capture(4,3,&SJ);
  id<MTLComputePipelineState> pAdd=mk(eAdd); int lenA=capture(5,4,&SA);

  const float AV=7.0f, BV=3.0f;
  float rAdd=run(pAdd,AV,BV), rSub=run(pSub,AV,BV);
  printf("baseline: add kernel -> %.3f   sub kernel -> %.3f   (a=%.1f b=%.1f)\n",rAdd,rSub,AV,BV);
  printf("slots: add %d bytes @reg%d 0x%llx | sub %d bytes @reg%d 0x%llx\n\n",
         lenA,SA.reg,SA.off,lenB,SB.reg,SB.off);
  if(lenA!=lenB){ printf("slot sizes differ (%d vs %d) -- not directly patchable\n",lenA,lenB); return 0; }

  /* The two kernels' code need not start at the same offset inside their
     256-byte frames. Slide one against the other and take the shift that
     minimises differences -- the shared prologue (buffer loads, thread index)
     is identical, so the true alignment is unambiguous. */
  int bestShift=0, bestDiff=1<<30;
  for(int sh=-96; sh<=96; sh++){
    int d=0, n=0;
    for(int k=0;k<lenA;k++){ int j=k+sh; if(j<0||j>=lenB) continue; n++;
      if(SA.code[k]!=SB.code[j]) d++; }
    if(n<96) continue;
    int scaled=(int)((long)d*256/n);
    if(scaled<bestDiff){ bestDiff=scaled; bestShift=sh; }
  }
  printf("best alignment: sub shifted %+d bytes (%d/256 differing at that shift)\n\n",
         bestShift,bestDiff);
  int diffs[64], nd=0;
  for(int k=0;k<lenA;k++){ int j=k+bestShift; if(j<0||j>=lenB) continue;
    if(SA.code[k]!=SB.code[j]){ if(nd<64) diffs[nd]=k; nd++; } }
  printf("%d bytes differ between add and sub slots:\n",nd);
  for(int i2=0;i2<nd && i2<10;i2++)
    printf("   +0x%03x : add=%02x sub=%02x\n",diffs[i2],SA.code[diffs[i2]],SB.code[diffs[i2]+bestShift]);

  int mism=0;
  for(int k=0;k<lenA;k++){ uint8_t *l=(uint8_t*)(uintptr_t)(r_addr[SA.reg]+SA.off+k);
    if(*l!=SA.code[k]) mism++; }
  printf("\nlive-vs-captured mismatch in add slot: %d of %d bytes%s\n",
         mism,lenA, mism?"  (slot was recycled -- patches would be meaningless)":"  (slot intact)");
  printf("\nBIT-FLIP SWEEP on the live ADD kernel (a=%.0f b=%.0f, add=%.0f sub=%.0f)\n",AV,BV,rAdd,rSub);
  printf("Single-kernel experiment: no cross-kernel alignment needed.\n");
  printf("==================================================================\n");
  int live=0, becameSub=0, shown=0;
  for(int k=0;k<lenA;k++){
    uint8_t *l=(uint8_t*)(uintptr_t)(r_addr[SA.reg]+SA.off+k);
    uint8_t save=*l; int changedHere=0;
    for(int bit=0; bit<8; bit++){
      *l = save ^ (uint8_t)(1<<bit);
      float v=run(pAdd,AV,BV);
      if(!(fabsf(v-rAdd)<1e-4f)){
        changedHere=1;
        if(fabsf(v-rSub)<1e-4f){ becameSub++;
          printf("  +0x%03x bit%d : %02x->%02x  => %.3f   BECAME SUB  <== opcode bit\n",
                 k,bit,save,(uint8_t)(save^(1<<bit)),v); }
        else if(shown<14){ shown++;
          printf("  +0x%03x bit%d : %02x->%02x  => %.3f\n",k,bit,save,(uint8_t)(save^(1<<bit)),v); }
      }
    }
    *l=save;
    if(changedHere) live++;
  }
  printf("------------------------------------------------------------------\n");
  printf("%d of %d bytes are semantically live (a bit flip changes the result)\n",live,lenA);
  printf("%d flips turned ADD into exactly SUB\n",becameSub);
}; return 0; }
