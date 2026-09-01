/* agx-probe/ring_probe -- look for the firmware ring buffers.
   The GPU is driven by a coprocessor over shared memory; everything the other
   probes map sits above that layer. A ring shows two signatures: a small
   integer at a fixed offset that advances monotonically with each submit
   (head/tail), and a data area whose written window marches forward and wraps. */
#import "agxcommon.h"

static id<MTLDevice> dev; static id<MTLCommandQueue> q;
static id<MTLRenderPipelineState> pso; static id<MTLTexture> col;

static const char *kSrc="#include <metal_stdlib>\nusing namespace metal;\n"
"struct VOut{float4 pos [[position]];};\n"
"vertex VOut v_main(uint vid [[vertex_id]]){float2 p[3]={float2(-.9,-.9),float2(.9,-.9),float2(0,.9)};"
"VOut o;o.pos=float4(p[vid],0,1);return o;}\n"
"fragment float4 f_main(){return float4(1,0.3,0.1,1);}\n";

#define NSUB 24
static void submit(void){ @autoreleasepool{
  id<MTLCommandBuffer> cb=[q commandBuffer];
  MTLRenderPassDescriptor *rp=[MTLRenderPassDescriptor renderPassDescriptor];
  rp.colorAttachments[0].texture=col; rp.colorAttachments[0].loadAction=MTLLoadActionClear;
  rp.colorAttachments[0].storeAction=MTLStoreActionStore;
  id<MTLRenderCommandEncoder> en=[cb renderCommandEncoderWithDescriptor:rp];
  [en setRenderPipelineState:pso];
  [en drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3]; [en endEncoding];
  [cb commit]; [cb waitUntilCompleted]; } }

int main(void){ @autoreleasepool {
  dev=MTLCreateSystemDefaultDevice(); NSError *e=nil;
  id<MTLLibrary> lib=[dev newLibraryWithSource:@(kSrc) options:nil error:&e];
  MTLRenderPipelineDescriptor *pd=[MTLRenderPipelineDescriptor new];
  pd.vertexFunction=[lib newFunctionWithName:@"v_main"]; pd.fragmentFunction=[lib newFunctionWithName:@"f_main"];
  pd.colorAttachments[0].pixelFormat=MTLPixelFormatBGRA8Unorm;
  pso=[dev newRenderPipelineStateWithDescriptor:pd error:&e];
  MTLTextureDescriptor *td=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:64 height:64 mipmapped:NO];
  td.usage=MTLTextureUsageRenderTarget; td.storageMode=MTLStorageModePrivate; col=[dev newTextureWithDescriptor:td];
  q=[dev newCommandQueue];
  if(!agx_install("AGXG16GFamilyCommandBuffer")) return 1;

  for(int i=0;i<4;i++) submit();
  agx_locate(); agx_alloc(NSUB+2);
  fprintf(stderr,"[ring] %d regions / %llu bytes, %d submits\n\n",r_n,r_tot,NSUB);
  for(int i=0;i<NSUB;i++){ g_run=i; submit(); }
  g_run=-1;

  printf("CANDIDATE RING POINTERS (uint32 advancing monotonically per submit)\n");
  printf("===================================================================\n");
  printf("%-5s %-10s %-12s %-10s %s\n","REG","OFFSET","FIRST","LAST","STEP PATTERN");
  printf("-------------------------------------------------------------------\n");
  int found=0, wrapping=0;
  for(int r=0;r<r_n && found<20;r++)
    for(uint64_t o=0;o+4<=r_size[r] && found<20;o+=4){
      uint32_t v[NSUB];
      for(int i=0;i<NSUB;i++) memcpy(&v[i],&snap[i][r][o],4);
      int mono=1, allsame=1, step=(int)((int64_t)v[1]-(int64_t)v[0]), fixed=1;
      for(int i=1;i<NSUB;i++){
        if(v[i]<v[i-1]) mono=0;
        if(v[i]!=v[0]) allsame=0;
        if((int)((int64_t)v[i]-(int64_t)v[i-1])!=step) fixed=0; }
      if(allsame||!mono) continue;
      if(v[NSUB-1]-v[0] > 4096u*NSUB) continue;      /* addresses/timestamps, not indices */
      printf("%-5d 0x%06llx  %-12u %-10u %s\n", r,o,v[0],v[NSUB-1],
             fixed? (step==1?"+1 per submit  <== index":"constant stride") : "irregular");
      found++;
    }
  if(!found) printf("  none\n");

  /* a ring's data area: a window of bytes that marches forward and wraps */
  printf("\nWRITE-WINDOW MARCH (region, bytes changed per submit, span drift)\n");
  printf("===================================================================\n");
  for(int r=0;r<r_n;r++){
    uint64_t firstLo=0,lastLo=0; int nz=0; long tot=0;
    for(int i=1;i<NSUB;i++){
      uint64_t lo=~0ULL,hi=0; long c=0;
      for(uint64_t o=0;o<r_size[r];o++)
        if(snap[i][r][o]!=snap[i-1][r][o]){ c++; if(o<lo)lo=o; if(o>hi)hi=o; }
      if(!c) continue;
      if(!nz) firstLo=lo;
      lastLo=lo; nz++; tot+=c;
    }
    if(nz<NSUB/2) continue;
    long drift=(long)lastLo-(long)firstLo;
    printf("reg%-3d  %5ld bytes/submit  start drifts %+ld bytes over %d submits  %s\n",
           r, tot/(nz?nz:1), drift, nz,
           (drift>256)?"<== marching (ring-like)":(drift==0?"in place":""));
    if(drift>256) wrapping++;
  }
  fprintf(stderr,"\n[ring] %d pointer candidates, %d marching regions\n",found,wrapping);
}; return 0; }
