/* agx-probe/validate_all -- prove the register map causally, field by field.
   For each field: calibrate its site differentially, then render with the API
   asking for A while patching the byte to B. The test passes only if the
   resulting framebuffer is PIXEL-IDENTICAL to an unpatched render of B.
   No per-field expectations -- exact equality or it fails. */
#import "agxcommon.h"

typedef enum { K_BITS, K_BYTE, K_F32 } FKind;

typedef struct {
  int dcmp,dwrite,cull,wind,fill;
  int scmp,spass,sfail,dfail;
  uint32_t sref,sx,sy;
  int twoDraw;
  float bcr,bcg,bcb;
  float clrR,clrG,clrB,clrA,clrD;
  uint32_t rtW;
} Cfg;

static id<MTLDevice> dev; static id<MTLTexture> col,ds; static id<MTLCommandQueue> q;
static id<MTLRenderPipelineState> pso;
static IMP real_commit;
static int g_faults=0, g_requeues=0;
static int g_cal=-1, g_patchval=-1, g_patchmask=0, g_hits=0, g_only=-1, g_lo=0, g_hi=1<<30;
static int g_raw=0; static uint8_t g_skip[4096];                      /* replay mode: write captured B bytes */
static uint8_t g_rawval[4096];
#define MAXSITE 600
static struct { int r; uint64_t o; int sh; } site[MAXSITE]; static int nsite=0;
static int g_kind=K_BITS; static float g_fval=0;

static void hook(id s, SEL c){
  if(g_cal>=0) agx_snapshot(g_cal);
  if(g_patchval>=0){ for(int i=0;i<nsite;i++){ if(g_only>=0 && i!=g_only) continue;
      if(g_only<0 && (i<g_lo||i>=g_hi)) continue;
      if(g_raw && g_skip[i]) continue;
      uint8_t *live=(uint8_t*)(uintptr_t)(r_addr[site[i].r]+site[i].o);
      if(g_raw){ *live=g_rawval[i]; }
      else if(g_kind==K_F32){ memcpy(live,&g_fval,4); }
      else if(g_kind==K_BYTE){ *live=(uint8_t)g_patchval; }
      else { int sh=site[i].sh, m=g_patchmask<<sh;
             *live=(uint8_t)((*live & ~m) | ((g_patchval<<sh) & m)); } }
    g_hits=nsite; }
  ((void(*)(id,SEL))real_commit)(s,c);
}

static const char *kSrc="#include <metal_stdlib>\nusing namespace metal;\n"
""
"struct Args{float2 off; float z; float tint;};\n"
"struct VO2{float4 pos [[position]]; float tint;};\n"
"vertex VO2 v_main(uint vid [[vertex_id]], constant Args &a [[buffer(0)]]){\n"
"  float2 p[3]={float2(-.9,-.9),float2(.9,-.9),float2(0,.9)};\n"
"  VO2 o;o.pos=float4(p[vid]*0.8+a.off,a.z,1);o.tint=a.tint;return o;}\n"
"fragment float4 f_main(VO2 i [[stage_in]]){return float4(1,0.3,i.tint,1);}\n";

/* returns framebuffer hash; *cov gets lit-pixel percentage */
static uint64_t draw(Cfg c,int patchval,int patchmask,double *cov){
  uint64_t h=1469598103934665603ULL;
  @autoreleasepool{
    MTLStencilDescriptor *sd=[MTLStencilDescriptor new];
    sd.stencilCompareFunction=(MTLCompareFunction)c.scmp;
    sd.depthStencilPassOperation=(MTLStencilOperation)c.spass;
    sd.stencilFailureOperation=(MTLStencilOperation)c.sfail;
    sd.depthFailureOperation=(MTLStencilOperation)c.dfail;
    sd.readMask=0xFF; sd.writeMask=0xFF;
    MTLDepthStencilDescriptor *x=[MTLDepthStencilDescriptor new];
    x.depthCompareFunction=(MTLCompareFunction)c.dcmp; x.depthWriteEnabled=(c.dwrite==1);
    x.frontFaceStencil=sd; x.backFaceStencil=sd;
    id<MTLDepthStencilState> dss=[dev newDepthStencilStateWithDescriptor:x];
    id<MTLCommandBuffer> cb=[q commandBuffer];
    MTLRenderPassDescriptor *rp=[MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture=col; rp.colorAttachments[0].loadAction=MTLLoadActionClear;
    rp.colorAttachments[0].clearColor=MTLClearColorMake(c.clrR,c.clrG,c.clrB,c.clrA);
    rp.colorAttachments[0].storeAction=MTLStoreActionStore;
    rp.renderTargetWidth=c.rtW; rp.renderTargetHeight=64;
    rp.depthAttachment.texture=ds; rp.depthAttachment.loadAction=MTLLoadActionClear;
    rp.depthAttachment.clearDepth=c.clrD; rp.depthAttachment.storeAction=MTLStoreActionDontCare;
    rp.stencilAttachment.texture=ds; rp.stencilAttachment.loadAction=MTLLoadActionClear;
    rp.stencilAttachment.clearStencil=0; rp.stencilAttachment.storeAction=MTLStoreActionDontCare;
    id<MTLRenderCommandEncoder> en=[cb renderCommandEncoderWithDescriptor:rp];
    [en setRenderPipelineState:pso]; [en setDepthStencilState:dss];
    [en setCullMode:(MTLCullMode)c.cull]; [en setFrontFacingWinding:(MTLWinding)c.wind];
    [en setTriangleFillMode:(MTLTriangleFillMode)c.fill];
    [en setStencilReferenceValue:c.sref];
    [en setScissorRect:(MTLScissorRect){c.sx,c.sy,60,60}];
    [en setBlendColorRed:c.bcr green:c.bcg blue:c.bcb alpha:1.0];
    struct { float ox,oy,z,tint; } a1={0.0f,0.0f,0.2f,0.1f};
    [en setVertexBytes:&a1 length:sizeof a1 atIndex:0];
    [en drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    if(c.twoDraw==3){
      MTLDepthStencilDescriptor *x3=[MTLDepthStencilDescriptor new];
      x3.depthCompareFunction=MTLCompareFunctionLess; x3.depthWriteEnabled=NO;
      [en setDepthStencilState:[dev newDepthStencilStateWithDescriptor:x3]];
      struct { float ox,oy,z,tint; } a3={0.0f,0.0f,0.5f,0.9f};
      [en setVertexBytes:&a3 length:sizeof a3 atIndex:0];
      [en drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    } else if(c.twoDraw){
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
      struct { float ox,oy,z,tint; } a2={0.0f,0.0f,0.4f,0.9f};
      [en setVertexBytes:&a2 length:sizeof a2 atIndex:0];
      [en drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    }
    [en endEncoding];
    g_patchval=patchval; g_patchmask=patchmask; g_hits=0;
    dispatch_semaphore_t sem=dispatch_semaphore_create(0);
    [cb addCompletedHandler:^(id<MTLCommandBuffer> b){ (void)b; dispatch_semaphore_signal(sem); }];
    [cb commit];
    long timedout = dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 4ll*NSEC_PER_SEC));
    g_patchval=-1;
    if(timedout || cb.status!=MTLCommandBufferStatusCompleted || cb.error){
      g_faults++;
      if(g_faults>=3){                        /* queue is wedged, not one bad patch */
        fprintf(stderr,"[val] %d consecutive faults -- rebuilding command queue\n",g_faults);
        q=[dev newCommandQueue];
        g_faults=0; g_requeues++;
        if(g_requeues>4){
          fprintf(stderr,"[val] ABORT: queue unrecoverable after %d rebuilds\n",g_requeues);
          printf("ABORTED: GPU queue unrecoverable; run is not usable\n");
          exit(2);                            /* fail loudly instead of emitting garbage */
        }
      }
      if(cov)*cov=-1; return 0ULL;            /* sentinel: never equals a real hash */
    }
    g_faults=0;
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

typedef struct { const char *name; size_t off; int mask; double a,b; int two; FKind kind; int ovScmp, ovDcmp; } Field;
#define O(f) offsetof(Cfg,f)
static Field F[]={
  {"depthCompareFunction",O(dcmp),  0x07, 7,0, 0, K_BITS, -1, -1},
  {"cullMode",            O(cull),  0x03, 2,1, 0, K_BITS, -1, -1},
  {"frontFacingWinding",  O(wind),  0x01, 1,0, 0, K_BITS, -1, -1},
  {"triangleFillMode",    O(fill),  0x01, 0,1, 0, K_BITS, -1, -1},
  {"stencilCompareFunc",  O(scmp),  0x07, 7,0, 0, K_BITS, -1, -1},
  {"stencilPassOp",       O(spass), 0x07, 2,0, 2, K_BITS, -1, -1},
  {"depthWriteEnabled",   O(dwrite),0x01, 1,0, 1, K_BITS, -1, -1},
  {"scissor.x",           O(sx),    0xFF, 0,28,0, K_BYTE, -1, -1},
  {"stencilReferenceValue",O(sref), 0xFF, 1,2, 2, K_BYTE, -1, -1},
  {"blendColor.red",      O(bcr),   0,  1.0,0.25,0, K_F32, -1, -1},
  {"blendColor.green",    O(bcg),   0,  1.0,0.25,0, K_F32, -1, -1},
  {"blendColor.blue",     O(bcb),   0,  1.0,0.50,0, K_F32, -1, -1},
  {"clearColor.red",      O(clrR),  0,  0.0,0.75,0, K_F32, -1, -1},
  {"clearColor.green",    O(clrG),  0,  0.0,0.50,0, K_F32, -1, -1},
  {"clearColor.blue",     O(clrB),  0,  0.0,0.25,0, K_F32, -1, -1},
  {"clearColor.alpha",    O(clrA),  0,  1.0,0.25,0, K_F32, -1, -1},
  {"scissor.y",           O(sy),    0xFF, 0,20, 0, K_BYTE, -1, -1},
  {"renderTargetWidth",   O(rtW),   0xFF,64,40, 0, K_BYTE, -1, -1},
  {"clearDepth",          O(clrD),  0,  0.9,0.05,3, K_F32, -1, -1},
  {"stencilFailOp",       O(sfail), 0x07, 2,0, 2, K_BITS, 0, -1},   /* stencil Never -> always fails */
  {"depthFailOp",         O(dfail), 0x07, 2,0, 2, K_BITS, 7,  0},   /* stencil Always, depth Never */
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

  g_post=1;   /* some state lands during commit, not before it */
  Cfg base={1,1,2,1,0, 7,0,0,0, 1,0,0, 0, 1.0f,1.0f,1.0f, 0.0f,0.0f,0.0f,1.0f,0.5f, 64};
  for(int i=0;i<4;i++) draw(base,-1,0,NULL);
  agx_locate(); agx_alloc(4);
  fprintf(stderr,"[val] %d regions tracked\n\n",r_n);

  printf("CAUSAL VALIDATION -- patched(A->B) must be PIXEL-IDENTICAL to unpatched(B)\n");
  printf("==========================================================================\n");
  printf("%-22s %-6s %-9s %-9s %-9s %s\n","FIELD","SITES","cov(A)","cov(B)","cov(A->B)","VERDICT");
  printf("--------------------------------------------------------------------------\n");
  int pass=0,tested=0,noeffect=0,weak=0;
  for(int i=0;i<NF;i++){
    fprintf(stderr,"[val] field %d/%d %s\n",i+1,NF,F[i].name);
    Cfg ca=base, cb2=base;
    ca.twoDraw=F[i].two; cb2.twoDraw=F[i].two;
    if(F[i].ovScmp>=0){ ca.scmp=F[i].ovScmp; cb2.scmp=F[i].ovScmp; }
    if(F[i].ovDcmp>=0){ ca.dcmp=F[i].ovDcmp; cb2.dcmp=F[i].ovDcmp; }
    if(F[i].kind==K_F32){ *(float*)((char*)&ca +F[i].off)=(float)F[i].a;
                          *(float*)((char*)&cb2+F[i].off)=(float)F[i].b; }
    else if(F[i].kind==K_BYTE){ *(uint32_t*)((char*)&ca +F[i].off)=(uint32_t)F[i].a;
                                *(uint32_t*)((char*)&cb2+F[i].off)=(uint32_t)F[i].b; }
    else { *(int*)((char*)&ca +F[i].off)=(int)F[i].a;
           *(int*)((char*)&cb2+F[i].off)=(int)F[i].b; }
    g_kind=F[i].kind; g_fval=(float)F[i].b;
    double covA,covB,covP;
    /* calibrate on runs 0/1/2 */
    fprintf(stderr,"      [cal]\n"); g_cal=0; uint64_t hA=draw(ca,-1,0,&covA);
    g_cal=1; uint64_t hB=draw(cb2,-1,0,&covB);
    g_cal=2; draw(ca,-1,0,NULL);
    g_cal=-1;
    if(hA==hB){ printf("%-22s %-6s %8.1f%% %8.1f%% %-9s no visible effect - untestable\n",
                       F[i].name,"-",covA,covB,"-"); noeffect++; continue; }
    fprintf(stderr,"      [sites]\n");
    nsite=0;
    for(int r=0;r<r_n && nsite<MAXSITE;r++) for(uint64_t o=0;o<r_size[r] && nsite<MAXSITE;o++){
      if(F[i].kind==K_F32){
        if(o+4>r_size[r]) continue;
        if(o & 3) continue;                 /* 4-byte aligned only */
        float fx,fy,fz; memcpy(&fx,&snap[0][r][o],4); memcpy(&fy,&snap[1][r][o],4); memcpy(&fz,&snap[2][r][o],4);
        if(fx!=(float)F[i].a || fy!=(float)F[i].b || fz!=(float)F[i].a) continue;
        site[nsite].r=r; site[nsite].o=o; site[nsite].sh=0; nsite++; continue;
      }
      int x=snap[0][r][o],y=snap[1][r][o],z=snap[2][r][o];
      if(x==y) continue;
      if(F[i].kind==K_BYTE){
        if(x!=(int)F[i].a || y!=(int)F[i].b || z!=(int)F[i].a) continue;
        site[nsite].r=r; site[nsite].o=o; site[nsite].sh=0; nsite++; continue;
      }
      for(int sh=0; sh<8; sh++){
        if(((x>>sh)&F[i].mask)!=((int)F[i].a&F[i].mask)) continue;
        if(((y>>sh)&F[i].mask)!=((int)F[i].b&F[i].mask)) continue;
        if(((z>>sh)&F[i].mask)!=((int)F[i].a&F[i].mask)) continue;
        site[nsite].r=r; site[nsite].o=o; site[nsite].sh=sh; nsite++; break; } }
    int capw = (F[i].kind==K_BITS)?MAXSITE:24;
    if(nsite>capw) nsite=capw;
    if(!nsite){ printf("%-22s %-6d %8.1f%% %8.1f%% %-9s no site calibrated\n",F[i].name,0,covA,covB,"-"); continue; }
    /* try each candidate individually: the causal byte is the one whose patch
       reproduces B exactly. Shotgunning all candidates corrupts unrelated state. */
    fprintf(stderr,"      [bisect n=%d]\n",nsite);
    int winner=-1, changedAny=0; double covW=0; int probes=0;
    /* bisect: does patching [lo,hi) reproduce B? narrow until a single site */
    int lo=0, hi=nsite;
    g_lo=lo; g_hi=hi; uint64_t hAll=draw(ca,(int)F[i].b,F[i].mask,&covP); probes++;
    if(hAll==hB){
      while(hi-lo>1){
        int mid=(lo+hi)/2;
        g_lo=lo; g_hi=mid; uint64_t h1=draw(ca,(int)F[i].b,F[i].mask,&covP); probes++;
        if(h1==hB){ hi=mid; } else { lo=mid; }
      }
      g_lo=lo; g_hi=lo+1; uint64_t hf=draw(ca,(int)F[i].b,F[i].mask,&covW); probes++;
      if(hf==hB) winner=lo;
      g_lo=0; g_hi=1<<30;
    } else if(hAll!=hA) changedAny=1;
    g_lo=0; g_hi=1<<30;
    tested++;
    if(winner>=0){ pass++;
      printf("%-22s %-6d %8.1f%% %8.1f%% %8.1f%%  CAUSAL @ reg%d 0x%06llx bit%d (%d probes)\n",
             F[i].name,nsite,covA,covB,covW,
             site[winner].r,site[winner].o,site[winner].sh,probes);
    }
    if(winner<0){
      /* Fallback: some fields need more than their own bits changed (a separate
         enable, or a mirrored copy). Replay every differing byte, then bisect. */
      fprintf(stderr,"      [fallback]\n");
      #define RAWCAP 160
      nsite=0;
      for(int r=0;r<r_n && nsite<RAWCAP;r++) for(uint64_t o=0;o<r_size[r] && nsite<RAWCAP;o++){
        if(snap[0][r][o]!=snap[2][r][o]) continue;          /* unstable across repeats */
        if(snap[0][r][o]==snap[1][r][o]) continue;          /* unchanged A->B */
        site[nsite].r=r; site[nsite].o=o; site[nsite].sh=0;
        g_rawval[nsite]=snap[1][r][o]; nsite++; }
      if(nsite){
        g_raw=1; g_lo=0; g_hi=nsite;
        uint64_t hAll2=draw(ca,0,0xFF,&covP);
        if(hAll2==hB){
          int lo2=0,hi2=nsite;
          while(hi2-lo2>1){ int mid=(lo2+hi2)/2; g_lo=lo2; g_hi=mid;
            uint64_t h2=draw(ca,0,0xFF,&covP);
            if(h2==hB) hi2=mid; else lo2=mid; }
          int minset=lo2+1;
          /* Greedy subset reduction: the prefix is an upper bound, not minimal.
             Costs one render per candidate, so cap it -- a prefix already in the
             hundreds is not going to reduce to an isolated field. */
          #define GREEDY_CAP 200
          memset(g_skip,0,sizeof g_skip);
          g_lo=0; g_hi=minset;
          fprintf(stderr,"      [greedy minset=%d]\n",minset);
          for(int d=0; d<minset && minset<=GREEDY_CAP; d++){
            g_skip[d]=1;
            uint64_t hd=draw(ca,0,0xFF,&covP);
            if(hd!=hB) g_skip[d]=0;            /* needed after all */
          }
          int kept=0; int keptIdx[16]; int nk=0;
          for(int d=0; d<minset; d++) if(!g_skip[d]){ kept++; if(nk<16) keptIdx[nk++]=d; }
          minset=kept;
          uint64_t hMin=draw(ca,0,0xFF,&covP);
          if(hMin==hB && kept<=8){
            printf("%-22s %-6d %8.1f%% %8.1f%% %8.1f%%  CAUSAL: %d-byte group @",
                   F[i].name,nsite,covA,covB,covP,kept);
            for(int t=0;t<nk;t++) printf(" reg%d:0x%llx",site[keptIdx[t]].r,site[keptIdx[t]].o);
            printf("\n");
            pass++; memset(g_skip,0,sizeof g_skip); g_raw=0; g_lo=0; g_hi=1<<30; continue;
          }
          memset(g_skip,0,sizeof g_skip);
          g_raw=0; g_lo=0; g_hi=1<<30;
          /* Replaying ALL differing bytes is near-tautological -- it copies B's
             state wholesale. Only a SMALL minimal set is real evidence that the
             field is localised; a large one just says the state lives in the
             regions we capture. */
          if(hMin==hB && minset<=8){
            printf("%-22s %-6d %8.1f%% %8.1f%% %8.1f%%  CAUSAL: %d-byte group\n",
                   F[i].name,nsite,covA,covB,covP,minset);
            pass++;
          } else {
            printf("%-22s %-6d %8.1f%% %8.1f%% %-9s state reproduced by %d bytes - NOT isolated\n",
                   F[i].name,nsite,covA,covB,"-",minset);
            weak++;
          }
          continue;
        }
        g_raw=0; g_lo=0; g_hi=1<<30;
        printf("%-22s %-6d %8.1f%% %8.1f%% %-9s replaying all %d differing bytes still not B\n",
               F[i].name,nsite,covA,covB,"-",nsite);
        continue;
      }
    }
    if(winner<0){
      printf("%-22s %-6d %8.1f%% %8.1f%% %-9s %s\n",
             F[i].name,nsite,covA,covB,"-",
             changedAny?"altered output but never reproduced B":"patching all candidates had no effect");
    }
  }
  printf("--------------------------------------------------------------------------\n");
  printf("%d of %d testable fields isolated causally; %d reproduced but not isolated; %d no visible effect\n",
         pass,tested,weak,noeffect);
}; return 0; }
