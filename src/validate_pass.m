/* agx-probe/validate_pass -- causal proof for render-pass state.
   Each field gets a scene where the field decides the test outcome:
     clearDepth   triangle at z=0.5 with Less; clear above/below it
     clearStencil stencil Equal against a fixed reference
     stencilRef   the mirror of that: fixed clear, reference moves
     loadAction   a first pass writes content, a second Loads or Clears it
   Encoding-agnostic: raw replay of differing bytes, bisect, greedy reduce. */
#import "agxcommon.h"

typedef struct {
  float clrD; uint32_t clrS, sref, rtW;
  int cLoad,cStore,dLoad,sLoad,visMode;
} Cfg;

static id<MTLDevice> dev; static id<MTLTexture> col,ds; static id<MTLCommandQueue> q;
static id<MTLRenderPipelineState> pso; static id<MTLBuffer> visBuf;
#define MAXSITE 2048
static struct { int r; uint64_t o; } site[MAXSITE]; static int nsite=0;
static uint8_t rawval[MAXSITE], skip[MAXSITE];
static int g_apply=0, g_lo=0, g_hi=1<<30, g_diag=0; static IMP real_commit;

static void hook(id s, SEL c){
  if(g_run>=0&&g_run<MAXRUN){ ((void(*)(id,SEL))real_commit)(s,c); agx_snapshot(g_run); return; }
  if(g_apply){ for(int i=0;i<nsite;i++){
      if(i<g_lo||i>=g_hi||skip[i]) continue;
      *(uint8_t*)(uintptr_t)(r_addr[site[i].r]+site[i].o)=rawval[i]; }
    ((void(*)(id,SEL))real_commit)(s,c);
    if(g_diag){ int survived=0,tot=0;
      for(int i=0;i<nsite;i++){ if(i<g_lo||i>=g_hi||skip[i]) continue; tot++;
        if(*(uint8_t*)(uintptr_t)(r_addr[site[i].r]+site[i].o)==rawval[i]) survived++; }
      fprintf(stderr,"      [patch survival: %d/%d bytes still ours after commit]\n",survived,tot); }
    return; }
  ((void(*)(id,SEL))real_commit)(s,c);
}
static const char *kSrc="#include <metal_stdlib>\nusing namespace metal;\n"
"struct A{float z; float tint;};\n"
"struct VOut{float4 pos [[position]]; float tint;};\n"
"vertex VOut v_main(uint vid [[vertex_id]], constant A &a [[buffer(0)]]){\n"
"  float2 p[3]={float2(-.95,-.95),float2(.95,-.95),float2(0,.95)};\n"
"  VOut o;o.pos=float4(p[vid],a.z,1);o.tint=a.tint;return o;}\n"
"fragment float4 f_main(VOut i [[stage_in]]){return float4(1,i.tint,0.2,1);}\n";

static uint64_t draw(Cfg c,int apply,double *cov){
  uint64_t h=1469598103934665603ULL;
  @autoreleasepool{
    id<MTLCommandBuffer> cb=[q commandBuffer];
    /* pass 1: unconditionally paint the target so loadAction has content to keep */
    MTLRenderPassDescriptor *r0=[MTLRenderPassDescriptor renderPassDescriptor];
    r0.colorAttachments[0].texture=col; r0.colorAttachments[0].loadAction=MTLLoadActionClear;
    r0.colorAttachments[0].clearColor=MTLClearColorMake(0,0,1,1);
    r0.colorAttachments[0].storeAction=MTLStoreActionStore;
    id<MTLRenderCommandEncoder> e0=[cb renderCommandEncoderWithDescriptor:r0];
    [e0 setRenderPipelineState:pso];
    struct { float z,tint; } a0={0.9f,0.9f};
    [e0 setVertexBytes:&a0 length:sizeof a0 atIndex:0];
    [e0 drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3]; [e0 endEncoding];

    /* pass 2: the measured pass */
    MTLDepthStencilDescriptor *x=[MTLDepthStencilDescriptor new];
    x.depthCompareFunction=MTLCompareFunctionLess; x.depthWriteEnabled=NO;
    MTLStencilDescriptor *sd=[MTLStencilDescriptor new];
    sd.stencilCompareFunction=MTLCompareFunctionEqual; sd.readMask=0xFF; sd.writeMask=0xFF;
    x.frontFaceStencil=sd; x.backFaceStencil=sd;
    id<MTLDepthStencilState> dss=[dev newDepthStencilStateWithDescriptor:x];
    MTLRenderPassDescriptor *rp=[MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture=col;
    rp.colorAttachments[0].loadAction=(MTLLoadAction)c.cLoad;
    rp.colorAttachments[0].storeAction=(MTLStoreAction)c.cStore;
    rp.colorAttachments[0].clearColor=MTLClearColorMake(0,0,0,1);
    rp.depthAttachment.texture=ds; rp.depthAttachment.loadAction=(MTLLoadAction)c.dLoad;
    rp.depthAttachment.clearDepth=c.clrD; rp.depthAttachment.storeAction=MTLStoreActionDontCare;
    rp.stencilAttachment.texture=ds; rp.stencilAttachment.loadAction=(MTLLoadAction)c.sLoad;
    rp.stencilAttachment.clearStencil=c.clrS; rp.stencilAttachment.storeAction=MTLStoreActionDontCare;
    rp.renderTargetWidth=c.rtW; rp.renderTargetHeight=64;
    rp.visibilityResultBuffer=visBuf;
    id<MTLRenderCommandEncoder> en=[cb renderCommandEncoderWithDescriptor:rp];
    [en setRenderPipelineState:pso]; [en setDepthStencilState:dss];
    [en setStencilReferenceValue:c.sref];
    [en setVisibilityResultMode:(MTLVisibilityResultMode)c.visMode offset:0];
    struct { float z,tint; } a1={0.5f,0.2f};      /* z=0.5 straddles the clearDepth sweep */
    [en setVertexBytes:&a1 length:sizeof a1 atIndex:0];
    [en drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3]; [en endEncoding];
    g_apply=apply; [cb commit]; [cb waitUntilCompleted]; g_apply=0;
    int W=64,H=64; uint8_t *px=malloc(W*H*4);
    [col getBytes:px bytesPerRow:W*4 fromRegion:MTLRegionMake2D(0,0,W,H) mipmapLevel:0];
    long lit=0; for(int i=0;i<W*H*4;i++){ h^=px[i]; h*=1099511628211ULL; }
    for(int i=0;i<W*H;i++) if(px[i*4+1]>40) lit++;
    if(cov)*cov=100.0*lit/(W*H); free(px);
  }
  return h;
}
typedef struct { const char *name; size_t off; double a,b; int isF; } Field;
#define O(f) offsetof(Cfg,f)
static Field F[]={
  {"clearDepth",           O(clrD), 0.9, 0.1, 1},
  {"clearStencil",         O(clrS), 3, 7, 0},
  {"stencilReferenceValue",O(sref), 3, 7, 0},
  {"renderTargetWidth",    O(rtW),  64, 40, 0},
  {"color.loadAction",     O(cLoad),2, 1, 0},   /* Clear vs Load */
  {"color.storeAction",    O(cStore),1, 0, 0},
  {"depth.loadAction",     O(dLoad),2, 1, 0},
  {"stencil.loadAction",   O(sLoad),2, 1, 0},
  {"visibilityResultMode", O(visMode),0, 1, 0},
};
#define NF (int)(sizeof(F)/sizeof(F[0]))

int main(void){ @autoreleasepool {
  dev=MTLCreateSystemDefaultDevice(); NSError *e=nil;
  id<MTLLibrary> lib=[dev newLibraryWithSource:@(kSrc) options:nil error:&e];
  MTLRenderPipelineDescriptor *pd=[MTLRenderPipelineDescriptor new];
  pd.vertexFunction=[lib newFunctionWithName:@"v_main"]; pd.fragmentFunction=[lib newFunctionWithName:@"f_main"];
  pd.colorAttachments[0].pixelFormat=MTLPixelFormatBGRA8Unorm;
  pd.depthAttachmentPixelFormat=MTLPixelFormatDepth32Float_Stencil8;
  pd.stencilAttachmentPixelFormat=MTLPixelFormatDepth32Float_Stencil8;
  pso=[dev newRenderPipelineStateWithDescriptor:pd error:&e];
  if(!pso){fprintf(stderr,"pso: %s\n",e.description.UTF8String);return 1;}
  MTLTextureDescriptor *td=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:64 height:64 mipmapped:NO];
  td.usage=MTLTextureUsageRenderTarget; td.storageMode=MTLStorageModeShared; col=[dev newTextureWithDescriptor:td];
  MTLTextureDescriptor *dd=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float_Stencil8 width:64 height:64 mipmapped:NO];
  dd.usage=MTLTextureUsageRenderTarget; dd.storageMode=MTLStorageModePrivate; ds=[dev newTextureWithDescriptor:dd];
  q=[dev newCommandQueue]; visBuf=[dev newBufferWithLength:256 options:MTLResourceStorageModeShared];
  Class k=objc_getClass("AGXG16GFamilyCommandBuffer");
  Method m=class_getInstanceMethod(k,@selector(commit));
  real_commit=method_getImplementation(m); method_setImplementation(m,(IMP)hook);

  Cfg base={0.9f, 3, 3, 64, 2,1,2,2, 0};
  for(int i=0;i<4;i++) draw(base,0,NULL);
  agx_locate(); agx_alloc(4);
  fprintf(stderr,"[vp] %d regions\n\n",r_n);
  printf("RENDER-PASS STATE, VALIDATED BY CONTROL (pixel-exact)\n");
  printf("=================================================================\n");
  printf("%-24s %-7s %-9s %s\n","FIELD","CANDS","cov(A->B)","VERDICT");
  printf("-----------------------------------------------------------------\n");
  int pass=0,tested=0;
  for(int i=0;i<NF;i++){
    Cfg ca=base, cb2=base;
    if(F[i].isF){ *(float*)((char*)&ca+F[i].off)=(float)F[i].a; *(float*)((char*)&cb2+F[i].off)=(float)F[i].b; }
    else if(F[i].off>=offsetof(Cfg,cLoad)){ *(int*)((char*)&ca+F[i].off)=(int)F[i].a; *(int*)((char*)&cb2+F[i].off)=(int)F[i].b; }
    else { *(uint32_t*)((char*)&ca+F[i].off)=(uint32_t)F[i].a; *(uint32_t*)((char*)&cb2+F[i].off)=(uint32_t)F[i].b; }
    double covA,covB,covP;
    g_run=0; uint64_t hA=draw(ca,0,&covA);
    g_run=1; uint64_t hB=draw(cb2,0,&covB);
    g_run=2; draw(ca,0,NULL); g_run=-1;
    if(hA==hB){ printf("%-24s %-7s %-9s no visible effect\n",F[i].name,"-","-"); continue; }
    tested++;
    nsite=0; memset(skip,0,sizeof skip);
    for(int r=0;r<r_n && nsite<1500;r++) for(uint64_t o=0;o<r_size[r] && nsite<1500;o++){
      if(snap[0][r][o]!=snap[2][r][o]) continue;
      if(snap[0][r][o]==snap[1][r][o]) continue;
      site[nsite].r=r; site[nsite].o=o; rawval[nsite]=snap[1][r][o]; nsite++; }
    if(!nsite){ printf("%-24s %-7d %-9s no candidates\n",F[i].name,0,"-"); continue; }
    g_lo=0; g_hi=nsite; g_diag=1;
    if(draw(ca,1,&covP)!=hB){ g_diag=0; printf("%-24s %-7d %-9s replay not B\n",F[i].name,nsite,"-"); continue; }
    g_diag=0;
    int lo=0,hi=nsite;
    while(hi-lo>1){ int mid=(lo+hi)/2; g_lo=lo; g_hi=mid;
      if(draw(ca,1,&covP)==hB) hi=mid; else lo=mid; }
    int minset=lo+1; g_lo=0; g_hi=minset;
    for(int d=0;d<minset && minset<=256;d++){ skip[d]=1; if(draw(ca,1,&covP)!=hB) skip[d]=0; }
    int kept=0,idx[8],nk=0; for(int d=0;d<minset;d++) if(!skip[d]){ kept++; if(nk<8) idx[nk++]=d; }
    uint64_t hM=draw(ca,1,&covP); g_lo=0; g_hi=1<<30; memset(skip,0,sizeof skip);
    if(hM==hB && kept<=8){ pass++;
      printf("%-24s %-7d %8.1f%%  CAUSAL: %d-byte @",F[i].name,nsite,covP,kept);
      for(int t=0;t<nk;t++) printf(" reg%d:0x%llx",site[idx[t]].r,site[idx[t]].o);
      printf("\n");
    } else printf("%-24s %-7d %-9s reproduced by %d bytes - not isolated\n",F[i].name,nsite,"-",kept);
  }
  printf("-----------------------------------------------------------------\n");
  printf("%d of %d testable render-pass fields isolated causally\n",pass,tested);
}; return 0; }
