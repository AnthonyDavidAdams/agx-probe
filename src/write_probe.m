/* agx-probe/write_probe -- validate the recovered register map by CONTROL.
   Patch a recovered field in GPU-visible memory at command-buffer commit and
   check the rendered image obeys the patched value rather than the value the
   Metal API asked for. Correlation proves a field is correlated; only this
   proves it is the field. */
#import "agxcommon.h"

/* Sentinels chosen to be unlikely elsewhere in the arena, so the 8-byte
   depth/stencil descriptor can be found by signature instead of a fixed
   offset (region indices and arena positions move between runs). */
#define SENT_REF   0xA7
#define SENT_WMASK 0x5C
#define SENT_RMASK 0x3E

static id<MTLDevice> dev; static id<MTLTexture> col,ds; static id<MTLCommandQueue> q;
static id<MTLRenderPipelineState> pso;
static int g_patch_to = -1;      /* value to force into depthCompareFunction */
static int g_patched  = 0;
static IMP real_commit;

/* Target sites are discovered differentially at runtime rather than hardcoded:
   render two known compare functions, keep the offsets whose low 3 bits track
   the request. Self-calibrating, so it survives arena movement between runs. */
#define MAXSITE 16
static struct { int r; uint64_t o; } site[MAXSITE]; static int nsite=0;

static int patch_descriptor(int newcmp){
  for(int i=0;i<nsite;i++){
    uint8_t *live=(uint8_t*)(uintptr_t)(r_addr[site[i].r]+site[i].o);
    *live = (uint8_t)((*live & ~0x07) | (newcmp & 0x07));
  }
  return nsite;
}

static int g_cal=-1;
static void patch_commit(id self, SEL _cmd){
  if(g_cal>=0) agx_snapshot(g_cal);
  if(g_patch_to>=0) g_patched = patch_descriptor(g_patch_to);
  ((void(*)(id,SEL))real_commit)(self,_cmd);
}

/* fraction of pixels that are the triangle colour rather than the clear colour */
static double draw_and_measure(int apiCmp, int patchTo){
  __block double cover=0;
  @autoreleasepool{
    MTLDepthStencilDescriptor *x=[MTLDepthStencilDescriptor new];
    x.depthCompareFunction=(MTLCompareFunction)apiCmp;
    x.depthWriteEnabled=YES;
    MTLStencilDescriptor *sd=[MTLStencilDescriptor new];
    sd.readMask=SENT_RMASK; sd.writeMask=SENT_WMASK;
    sd.stencilCompareFunction=MTLCompareFunctionAlways;
    sd.depthStencilPassOperation=MTLStencilOperationReplace;
    x.frontFaceStencil=sd; x.backFaceStencil=sd;
    id<MTLDepthStencilState> dss=[dev newDepthStencilStateWithDescriptor:x];

    id<MTLCommandBuffer> cb=[q commandBuffer];
    MTLRenderPassDescriptor *rp=[MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture=col;
    rp.colorAttachments[0].loadAction=MTLLoadActionClear;
    rp.colorAttachments[0].clearColor=MTLClearColorMake(0,0,0,1);
    rp.colorAttachments[0].storeAction=MTLStoreActionStore;
    rp.depthAttachment.texture=ds; rp.depthAttachment.loadAction=MTLLoadActionClear;
    rp.depthAttachment.clearDepth=0.5;                 /* triangle sits at z=0.0 */
    rp.depthAttachment.storeAction=MTLStoreActionDontCare;
    rp.stencilAttachment.texture=ds; rp.stencilAttachment.loadAction=MTLLoadActionClear;
    rp.stencilAttachment.storeAction=MTLStoreActionDontCare;
    id<MTLRenderCommandEncoder> en=[cb renderCommandEncoderWithDescriptor:rp];
    [en setRenderPipelineState:pso]; [en setDepthStencilState:dss];
    [en setStencilReferenceValue:SENT_REF];
    [en drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [en endEncoding];
    g_patch_to=patchTo; g_patched=0;
    [cb commit]; [cb waitUntilCompleted];
    g_patch_to=-1;

    int W=64,H=64; uint8_t *px=malloc(W*H*4);
    [col getBytes:px bytesPerRow:W*4 fromRegion:MTLRegionMake2D(0,0,W,H) mipmapLevel:0];
    long lit=0; for(int i=0;i<W*H;i++) if(px[i*4+2]>40) lit++;   /* BGRA: red channel */
    cover=100.0*lit/(W*H); free(px);
  }
  return cover;
}

static const char *kSrc="#include <metal_stdlib>\nusing namespace metal;\n"
"struct VOut{float4 pos [[position]];};\n"
"vertex VOut v_main(uint vid [[vertex_id]]){float2 p[3]={float2(-.9,-.9),float2(.9,-.9),float2(0,.9)};"
"VOut o;o.pos=float4(p[vid],0.0,1);return o;}\n"
"fragment float4 f_main(){return float4(1,0.3,0.1,1);}\n";

int main(void){ @autoreleasepool {
  dev=MTLCreateSystemDefaultDevice(); NSError *e=nil;
  id<MTLLibrary> lib=[dev newLibraryWithSource:@(kSrc) options:nil error:&e];
  MTLRenderPipelineDescriptor *pd=[MTLRenderPipelineDescriptor new];
  pd.vertexFunction=[lib newFunctionWithName:@"v_main"];
  pd.fragmentFunction=[lib newFunctionWithName:@"f_main"];
  pd.colorAttachments[0].pixelFormat=MTLPixelFormatBGRA8Unorm;
  pd.depthAttachmentPixelFormat=MTLPixelFormatDepth32Float_Stencil8;
  pd.stencilAttachmentPixelFormat=MTLPixelFormatDepth32Float_Stencil8;
  pso=[dev newRenderPipelineStateWithDescriptor:pd error:&e];
  if(!pso){fprintf(stderr,"pso: %s\n",e.description.UTF8String);return 1;}
  MTLTextureDescriptor *td=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:64 height:64 mipmapped:NO];
  td.usage=MTLTextureUsageRenderTarget; td.storageMode=MTLStorageModeShared; col=[dev newTextureWithDescriptor:td];
  MTLTextureDescriptor *dd=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float_Stencil8 width:64 height:64 mipmapped:NO];
  dd.usage=MTLTextureUsageRenderTarget; dd.storageMode=MTLStorageModePrivate; ds=[dev newTextureWithDescriptor:dd];
  q=[dev newCommandQueue];

  Class k=objc_getClass("AGXG16GFamilyCommandBuffer");
  Method m=class_getInstanceMethod(k,@selector(commit));
  real_commit=method_getImplementation(m); method_setImplementation(m,(IMP)patch_commit);

  for(int i=0;i<3;i++) draw_and_measure(7,-1);
  agx_locate(); fprintf(stderr,"[write] %d IOACCELERATOR regions\n\n",r_n);

  const int NEVER=0, ALWAYS=7, LESS=1;

  /* ---- calibrate: find this run's depthCompareFunction sites ---- */
  agx_alloc(4);
  g_cal=0; draw_and_measure(LESS,-1);
  g_cal=1; draw_and_measure(6,-1);
  g_cal=2; draw_and_measure(LESS,-1);
  g_cal=-1;
  for(int r=0;r<r_n && nsite<MAXSITE;r++) for(uint64_t o=0;o<r_size[r] && nsite<MAXSITE;o++){
    int a=snap[0][r][o],b=snap[1][r][o],c=snap[2][r][o];
    if(a==b) continue;
    if((a&7)!=1 || (b&7)!=6 || (c&7)!=1) continue;
    site[nsite].r=r; site[nsite].o=o; nsite++;
  }
  fprintf(stderr,"[write] calibrated %d depthCompareFunction site(s)\n",nsite);
  for(int i=0;i<nsite;i++) fprintf(stderr,"[write]   reg%d 0x%06llx\n",site[i].r,site[i].o);
  if(!nsite){ printf("calibration found no site; aborting\n"); return 1; }

  printf("VALIDATING THE MAP BY CONTROL\n");
  printf("Triangle at z=0.0, depth cleared to 0.5. Coverage = %% of frame lit.\n");
  printf("=================================================================\n");
  printf("%-34s %-8s %-9s %s\n","CONDITION","PATCHED","COVERAGE","VERDICT");
  printf("-----------------------------------------------------------------\n");

  double base_always = draw_and_measure(ALWAYS,-1);
  printf("%-34s %-8s %7.1f%%   %s\n","API=Always, unpatched","-",base_always, base_always>10?"visible":"absent");
  double base_never  = draw_and_measure(NEVER,-1);
  printf("%-34s %-8s %7.1f%%   %s\n","API=Never, unpatched","-",base_never, base_never>10?"visible":"absent");
  double base_less   = draw_and_measure(LESS,-1);
  printf("%-34s %-8s %7.1f%%   %s\n","API=Less, unpatched","-",base_less, base_less>10?"visible":"absent");
  printf("-----------------------------------------------------------------\n");

  double p_always_to_never = draw_and_measure(ALWAYS,NEVER);
  int n1=g_patched;
  printf("%-34s %-8d %7.1f%%   %s\n","API=Always, PATCHED to Never",n1,p_always_to_never,
         p_always_to_never<1.0?"SUPPRESSED  <-- control":"unchanged (no control)");
  double p_never_to_always = draw_and_measure(NEVER,ALWAYS);
  int n2=g_patched;
  printf("%-34s %-8d %7.1f%%   %s\n","API=Never, PATCHED to Always",n2,p_never_to_always,
         p_never_to_always>10.0?"RESTORED  <-- control":"unchanged (no control)");
  printf("-----------------------------------------------------------------\n");

  int win = (p_always_to_never<1.0 && base_always>10.0)
         && (p_never_to_always>10.0 && base_never<1.0);
  printf("\n%s\n", win
    ? "RESULT: the rendered image follows the PATCHED byte, not the API call.\n"
      "        The recovered field drives the hardware. Map validated by control."
    : "RESULT: patching did not change the image. Either the descriptor is\n"
      "        re-emitted after this hook, or the field is not what we think.");
}; return 0; }
