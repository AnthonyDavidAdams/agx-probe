/* agx-probe/validate_all -- prove the register map causally, field by field.
   For each field: calibrate its site differentially, then render with the API
   asking for A while patching the byte to B. The test passes only if the
   resulting framebuffer is PIXEL-IDENTICAL to an unpatched render of B.
   No per-field expectations -- exact equality or it fails. */
#import "agxcommon.h"

typedef struct {
  int dcmp,dwrite,cull,wind,fill;
  int scmp,spass;
  uint32_t sref,sx;
  int twoDraw;
  float bcr;
} Cfg;

static id<MTLDevice> dev; static id<MTLTexture> col,ds; static id<MTLCommandQueue> q;
static id<MTLRenderPipelineState> pso;
static IMP real_commit;
static int g_cal=-1, g_patchval=-1, g_patchmask=0, g_hits=0, g_only=-1, g_lo=0, g_hi=1<<30;
#define MAXSITE 600
static struct { int r; uint64_t o; int sh; } site[MAXSITE]; static int nsite=0;

static void hook(id s, SEL c){
  if(g_cal>=0) agx_snapshot(g_cal);
  if(g_patchval>=0){ for(int i=0;i<nsite;i++){ if(g_only>=0 && i!=g_only) continue;
      if(g_only<0 && (i<g_lo||i>=g_hi)) continue;
      uint8_t *live=(uint8_t*)(uintptr_t)(r_addr[site[i].r]+site[i].o);
      int sh=site[i].sh, m=g_patchmask<<sh;
      *live=(uint8_t)((*live & ~m) | ((g_patchval<<sh) & m)); }
    g_hits=nsite; }
  ((void(*)(id,SEL))real_commit)(s,c);
}

static const char *kSrc="#include <metal_stdlib>\nusing namespace metal;\n"
"struct VOut{float4 pos [[position]];};\n"
"struct Args{float2 off; float z;};\n"
"vertex VOut v_main(uint vid [[vertex_id]], constant Args &a [[buffer(0)]]){\n"
"  float2 p[3]={float2(-.9,-.9),float2(.9,-.9),float2(0,.9)};\n"
"  VOut o;o.pos=float4(p[vid]*0.8+a.off,a.z,1);return o;}\n"
"fragment float4 f_main(){return float4(1,0.3,0.1,1);}\n";

/* returns framebuffer hash; *cov gets lit-pixel percentage */
static uint64_t draw(Cfg c,int patchval,int patchmask,double *cov){
  uint64_t h=1469598103934665603ULL;
  @autoreleasepool{
    MTLStencilDescriptor *sd=[MTLStencilDescriptor new];
    sd.stencilCompareFunction=(MTLCompareFunction)c.scmp;
    sd.depthStencilPassOperation=(MTLStencilOperation)c.spass;
    sd.readMask=0xFF; sd.writeMask=0xFF;
    MTLDepthStencilDescriptor *x=[MTLDepthStencilDescriptor new];
    x.depthCompareFunction=(MTLCompareFunction)c.dcmp; x.depthWriteEnabled=(c.dwrite==1);
    x.frontFaceStencil=sd; x.backFaceStencil=sd;
    id<MTLDepthStencilState> dss=[dev newDepthStencilStateWithDescriptor:x];
    id<MTLCommandBuffer> cb=[q commandBuffer];
    MTLRenderPassDescriptor *rp=[MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture=col; rp.colorAttachments[0].loadAction=MTLLoadActionClear;
    rp.colorAttachments[0].clearColor=MTLClearColorMake(0,0,0,1);
    rp.colorAttachments[0].storeAction=MTLStoreActionStore;
    rp.depthAttachment.texture=ds; rp.depthAttachment.loadAction=MTLLoadActionClear;
    rp.depthAttachment.clearDepth=0.5; rp.depthAttachment.storeAction=MTLStoreActionDontCare;
    rp.stencilAttachment.texture=ds; rp.stencilAttachment.loadAction=MTLLoadActionClear;
    rp.stencilAttachment.clearStencil=0; rp.stencilAttachment.storeAction=MTLStoreActionDontCare;
    id<MTLRenderCommandEncoder> en=[cb renderCommandEncoderWithDescriptor:rp];
    [en setRenderPipelineState:pso]; [en setDepthStencilState:dss];
    [en setCullMode:(MTLCullMode)c.cull]; [en setFrontFacingWinding:(MTLWinding)c.wind];
    [en setTriangleFillMode:(MTLTriangleFillMode)c.fill];
    [en setStencilReferenceValue:c.sref];
    [en setScissorRect:(MTLScissorRect){c.sx,0,60,64}];
    [en setBlendColorRed:c.bcr green:0.5 blue:0.5 alpha:1.0];
    struct { float ox,oy,z; } a1={0.0f,0.0f,0.2f};
    [en setVertexBytes:&a1 length:sizeof a1 atIndex:0];
    [en drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    if(c.twoDraw){
      /* second triangle tests what the first wrote to depth/stencil */
      MTLStencilDescriptor *s2=[MTLStencilDescriptor new];
      s2.stencilCompareFunction=(c.twoDraw==2)?MTLCompareFunctionEqual:MTLCompareFunctionAlways;
      s2.depthStencilPassOperation=MTLStencilOperationKeep;
      s2.readMask=0xFF; s2.writeMask=0xFF;
      MTLDepthStencilDescriptor *x2=[MTLDepthStencilDescriptor new];
      x2.depthCompareFunction=(c.twoDraw==2)?MTLCompareFunctionAlways:MTLCompareFunctionLess;
      x2.depthWriteEnabled=NO;
      x2.frontFaceStencil=s2; x2.backFaceStencil=s2;
      [en setDepthStencilState:[dev newDepthStencilStateWithDescriptor:x2]];
      [en setStencilReferenceValue:1];
      struct { float ox,oy,z; } a2={0.12f,0.12f,0.4f};
      [en setVertexBytes:&a2 length:sizeof a2 atIndex:0];
      [en drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    }
    [en endEncoding];
    g_patchval=patchval; g_patchmask=patchmask; g_hits=0;
    [cb commit]; [cb waitUntilCompleted]; g_patchval=-1;
    int W=64,H=64; uint8_t *px=malloc(W*H*4);
    [col getBytes:px bytesPerRow:W*4 fromRegion:MTLRegionMake2D(0,0,W,H) mipmapLevel:0];
    long lit=0;
    for(int i=0;i<W*H*4;i++){ h^=px[i]; h*=1099511628211ULL; }
    for(int i=0;i<W*H;i++) if(px[i*4+2]>40) lit++;
    if(cov)*cov=100.0*lit/(W*H);
    free(px);
  }
  return h;
}

typedef struct { const char *name; size_t off; int mask; int a,b; int two; } Field;
#define O(f) offsetof(Cfg,f)
static Field F[]={
  {"depthCompareFunction",O(dcmp),  0x07, 7,0, 0},
  {"cullMode",            O(cull),  0x03, 2,1, 0},
  {"frontFacingWinding",  O(wind),  0x01, 1,0, 0},
  {"triangleFillMode",    O(fill),  0x01, 0,1, 0},
  {"stencilCompareFunc",  O(scmp),  0x07, 7,0, 0},
  {"stencilPassOp",       O(spass), 0x07, 2,0, 2},
  {"depthWriteEnabled",   O(dwrite),0x01, 1,0, 1},
};
#define NF (int)(sizeof(F)/sizeof(F[0]))

int main(void){ @autoreleasepool {
  dev=MTLCreateSystemDefaultDevice(); NSError *e=nil;
  id<MTLLibrary> lib=[dev newLibraryWithSource:@(kSrc) options:nil error:&e];
  MTLRenderPipelineDescriptor *pd=[MTLRenderPipelineDescriptor new];
  pd.vertexFunction=[lib newFunctionWithName:@"v_main"]; pd.fragmentFunction=[lib newFunctionWithName:@"f_main"];
  MTLRenderPipelineColorAttachmentDescriptor *ca=pd.colorAttachments[0];
  ca.pixelFormat=MTLPixelFormatBGRA8Unorm; ca.blendingEnabled=YES;
  ca.sourceRGBBlendFactor=MTLBlendFactorBlendColor; ca.destinationRGBBlendFactor=MTLBlendFactorZero;
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
  real_commit=method_getImplementation(m); method_setImplementation(m,(IMP)hook);

  Cfg base={1,1,2,1,0, 7,0, 1,0, 0, 1.0f};
  for(int i=0;i<4;i++) draw(base,-1,0,NULL);
  agx_locate(); agx_alloc(4);
  fprintf(stderr,"[val] %d regions tracked\n\n",r_n);

  printf("CAUSAL VALIDATION -- patched(A->B) must be PIXEL-IDENTICAL to unpatched(B)\n");
  printf("==========================================================================\n");
  printf("%-22s %-6s %-9s %-9s %-9s %s\n","FIELD","SITES","cov(A)","cov(B)","cov(A->B)","VERDICT");
  printf("--------------------------------------------------------------------------\n");
  int pass=0,tested=0,noeffect=0;
  for(int i=0;i<NF;i++){
    Cfg ca=base, cb2=base;
    ca.twoDraw=F[i].two; cb2.twoDraw=F[i].two;
    *(int*)((char*)&ca +F[i].off)=F[i].a;
    *(int*)((char*)&cb2+F[i].off)=F[i].b;
    double covA,covB,covP;
    /* calibrate on runs 0/1/2 */
    g_cal=0; uint64_t hA=draw(ca,-1,0,&covA);
    g_cal=1; uint64_t hB=draw(cb2,-1,0,&covB);
    g_cal=2; draw(ca,-1,0,NULL);
    g_cal=-1;
    if(hA==hB){ printf("%-22s %-6s %8.1f%% %8.1f%% %-9s no visible effect - untestable\n",
                       F[i].name,"-",covA,covB,"-"); noeffect++; continue; }
    nsite=0;
    for(int r=0;r<r_n && nsite<MAXSITE;r++) for(uint64_t o=0;o<r_size[r] && nsite<MAXSITE;o++){
      int x=snap[0][r][o],y=snap[1][r][o],z=snap[2][r][o];
      if(x==y) continue;
      for(int sh=0; sh<8; sh++){
        if(((x>>sh)&F[i].mask)!=(F[i].a&F[i].mask)) continue;
        if(((y>>sh)&F[i].mask)!=(F[i].b&F[i].mask)) continue;
        if(((z>>sh)&F[i].mask)!=(F[i].a&F[i].mask)) continue;
        site[nsite].r=r; site[nsite].o=o; site[nsite].sh=sh; nsite++; break; } }
    if(!nsite){ printf("%-22s %-6d %8.1f%% %8.1f%% %-9s no site calibrated\n",F[i].name,0,covA,covB,"-"); continue; }
    /* try each candidate individually: the causal byte is the one whose patch
       reproduces B exactly. Shotgunning all candidates corrupts unrelated state. */
    int winner=-1, changedAny=0; double covW=0; int probes=0;
    /* bisect: does patching [lo,hi) reproduce B? narrow until a single site */
    int lo=0, hi=nsite;
    g_lo=lo; g_hi=hi; uint64_t hAll=draw(ca,F[i].b,F[i].mask,&covP); probes++;
    if(hAll==hB){
      while(hi-lo>1){
        int mid=(lo+hi)/2;
        g_lo=lo; g_hi=mid; uint64_t h1=draw(ca,F[i].b,F[i].mask,&covP); probes++;
        if(h1==hB){ hi=mid; } else { lo=mid; }
      }
      g_lo=lo; g_hi=lo+1; uint64_t hf=draw(ca,F[i].b,F[i].mask,&covW); probes++;
      if(hf==hB) winner=lo;
      g_lo=0; g_hi=1<<30;
    } else if(hAll!=hA) changedAny=1;
    g_lo=0; g_hi=1<<30;
    tested++;
    if(winner>=0){ pass++;
      printf("%-22s %-6d %8.1f%% %8.1f%% %8.1f%%  CAUSAL @ reg%d 0x%06llx bit%d (%d probes)\n",
             F[i].name,nsite,covA,covB,covW,
             site[winner].r,site[winner].o,site[winner].sh,probes);
    } else {
      printf("%-22s %-6d %8.1f%% %8.1f%% %-9s %s\n",
             F[i].name,nsite,covA,covB,"-",
             changedAny?"altered output but never reproduced B":"patching all candidates had no effect");
    }
  }
  printf("--------------------------------------------------------------------------\n");
  printf("%d of %d testable fields proven causal (%d had no visible effect)\n",pass,tested,noeffect);
}; return 0; }
