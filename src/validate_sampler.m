/* agx-probe/validate_sampler -- causal proof for sampler state.
   Sampler encodings are permuted (compareFunction is 0->7 1->2 2->4 ...), so
   pattern matching on values is useless here. This goes straight to raw replay:
   take every byte that differs between two configs and is stable across repeats,
   bisect to a working prefix, then greedily drop what isn't needed. A field is
   isolated when a set of eight bytes or fewer reproduces B pixel-exactly. */
#import "agxcommon.h"

typedef struct { int minF,magF,mipF,addrS,addrT,cmpF,border; float lodMin,lodMax; } Cfg;

static id<MTLDevice> dev; static id<MTLTexture> col,tex,dtex; static id<MTLCommandQueue> q;
static id<MTLRenderPipelineState> pso;
#define MAXSITE 4096
static struct { int r; uint64_t o; } site[MAXSITE]; static int nsite=0;
static uint8_t rawval[MAXSITE], skip[MAXSITE];
static int g_apply=0, g_lo=0, g_hi=1<<30;

static void hook_patch(void){
  for(int i=0;i<nsite;i++){
    if(i<g_lo||i>=g_hi) continue; if(skip[i]) continue;
    *(uint8_t*)(uintptr_t)(r_addr[site[i].r]+site[i].o)=rawval[i];
  }
}
static IMP real_commit;
static void hook(id s, SEL c){
  if(g_run>=0&&g_run<MAXRUN) { ((void(*)(id,SEL))real_commit)(s,c); agx_snapshot(g_run); return; }
  if(g_apply) hook_patch();
  ((void(*)(id,SEL))real_commit)(s,c);
}

static const char *kSrc="#include <metal_stdlib>\nusing namespace metal;\n"
"struct VOut{float4 pos [[position]]; float2 uv;};\n"
"vertex VOut v_main(uint vid [[vertex_id]]){float2 p[3]={float2(-1,-1),float2(3,-1),float2(-1,3)};"
"VOut o;o.pos=float4(p[vid],0,1);o.uv=(p[vid]*0.5+0.5)*2.5-0.75;return o;}\n"
"fragment float4 f_main(VOut i [[stage_in]], texture2d<float> t [[texture(0)]],\n"
"                       depth2d<float> d [[texture(1)]], sampler s [[sampler(0)]],\n"
"                       sampler cs [[sampler(1)]]){\n"
"  float4 mn=t.sample(s,i.uv);\n"
"  float4 mg=t.sample(s,i.uv*0.06+0.5);   /* heavy magnification */\n"
"  return mn*0.5 + mg*0.3 + d.sample_compare(cs,i.uv,0.5f)*0.2;}\n";

static uint64_t draw(Cfg c, int apply, double *cov){
  uint64_t h=1469598103934665603ULL;
  @autoreleasepool{
    MTLSamplerDescriptor *sd=[MTLSamplerDescriptor new];
    sd.minFilter=(MTLSamplerMinMagFilter)c.minF; sd.magFilter=(MTLSamplerMinMagFilter)c.magF;
    sd.mipFilter=(MTLSamplerMipFilter)c.mipF;
    sd.sAddressMode=(MTLSamplerAddressMode)c.addrS; sd.tAddressMode=(MTLSamplerAddressMode)c.addrT;
    sd.lodMinClamp=c.lodMin; sd.lodMaxClamp=c.lodMax;
    sd.borderColor=(MTLSamplerBorderColor)c.border; sd.supportArgumentBuffers=YES;
    id<MTLSamplerState> s=[dev newSamplerStateWithDescriptor:sd];
    MTLSamplerDescriptor *cd=[MTLSamplerDescriptor new];
    cd.compareFunction=(MTLCompareFunction)c.cmpF; cd.supportArgumentBuffers=YES;
    id<MTLSamplerState> cs=[dev newSamplerStateWithDescriptor:cd];
    id<MTLCommandBuffer> cb=[q commandBuffer];
    MTLRenderPassDescriptor *rp=[MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture=col; rp.colorAttachments[0].loadAction=MTLLoadActionClear;
    rp.colorAttachments[0].clearColor=MTLClearColorMake(0,0,0,1);
    rp.colorAttachments[0].storeAction=MTLStoreActionStore;
    id<MTLRenderCommandEncoder> en=[cb renderCommandEncoderWithDescriptor:rp];
    [en setRenderPipelineState:pso];
    [en setFragmentTexture:tex atIndex:0]; [en setFragmentTexture:dtex atIndex:1];
    [en setFragmentSamplerState:s atIndex:0]; [en setFragmentSamplerState:cs atIndex:1];
    [en drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3]; [en endEncoding];
    g_apply=apply; [cb commit]; [cb waitUntilCompleted]; g_apply=0;
    int W=64,H=64; uint8_t *px=malloc(W*H*4);
    [col getBytes:px bytesPerRow:W*4 fromRegion:MTLRegionMake2D(0,0,W,H) mipmapLevel:0];
    long lit=0; for(int i=0;i<W*H*4;i++){ h^=px[i]; h*=1099511628211ULL; }
    for(int i=0;i<W*H;i++) if(px[i*4]>20) lit++;
    if(cov)*cov=100.0*lit/(W*H); free(px);
  }
  return h;
}

typedef struct { const char *name; size_t off; int a,b; } Field;
#define O(f) offsetof(Cfg,f)
static Field F[]={
  {"sampler.minFilter",   O(minF), 0,1},
  {"sampler.magFilter",   O(magF), 0,1},
  {"sampler.mipFilter",   O(mipF), 1,2},
  {"sampler.sAddressMode",O(addrS),5,2},
  {"sampler.tAddressMode",O(addrT),5,2},
  {"sampler.compareFunction",O(cmpF),0,7},
  {"sampler.borderColor", O(border),0,2},
};
#define NF (int)(sizeof(F)/sizeof(F[0]))

int main(void){ @autoreleasepool {
  dev=MTLCreateSystemDefaultDevice(); NSError *e=nil;
  id<MTLLibrary> lib=[dev newLibraryWithSource:@(kSrc) options:nil error:&e];
  MTLRenderPipelineDescriptor *pd=[MTLRenderPipelineDescriptor new];
  pd.vertexFunction=[lib newFunctionWithName:@"v_main"]; pd.fragmentFunction=[lib newFunctionWithName:@"f_main"];
  pd.colorAttachments[0].pixelFormat=MTLPixelFormatBGRA8Unorm;
  pso=[dev newRenderPipelineStateWithDescriptor:pd error:&e];
  if(!pso){fprintf(stderr,"pso: %s\n",e.description.UTF8String);return 1;}
  MTLTextureDescriptor *td=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:64 height:64 mipmapped:NO];
  td.usage=MTLTextureUsageRenderTarget; td.storageMode=MTLStorageModeShared; col=[dev newTextureWithDescriptor:td];
  /* a real checkerboard, so filtering and addressing actually change pixels */
  MTLTextureDescriptor *st=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:32 height:32 mipmapped:YES];
  st.usage=MTLTextureUsageShaderRead; st.mipmapLevelCount=5; tex=[dev newTextureWithDescriptor:st];
  { uint8_t *img=malloc(32*32*4);
    for(int y=0;y<32;y++)for(int x=0;x<32;x++){ int v=((x/2+y/2)&1)?255:20;
      img[(y*32+x)*4+0]=v; img[(y*32+x)*4+1]=255-v; img[(y*32+x)*4+2]=v/2; img[(y*32+x)*4+3]=255; }
    [tex replaceRegion:MTLRegionMake2D(0,0,32,32) mipmapLevel:0 withBytes:img bytesPerRow:32*4];
    free(img); }
  MTLTextureDescriptor *dt=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float width:32 height:32 mipmapped:NO];
  dt.usage=MTLTextureUsageShaderRead; dt.storageMode=MTLStorageModePrivate; dtex=[dev newTextureWithDescriptor:dt];
  q=[dev newCommandQueue];
  Class k=objc_getClass("AGXG16GFamilyCommandBuffer");
  Method m=class_getInstanceMethod(k,@selector(commit));
  real_commit=method_getImplementation(m); method_setImplementation(m,(IMP)hook);

  Cfg base={1,1,1, 5,5, 1, 0, 0.0f,4.0f};
  for(int i=0;i<4;i++) draw(base,0,NULL);
  agx_locate(); agx_alloc(4);
  fprintf(stderr,"[vs] %d regions\n\n",r_n);
  printf("SAMPLER STATE, VALIDATED BY CONTROL (pixel-exact)\n");
  printf("=================================================================\n");
  printf("%-26s %-7s %-9s %s\n","FIELD","CANDS","cov(A->B)","VERDICT");
  printf("-----------------------------------------------------------------\n");
  int pass=0,tested=0;
  for(int i=0;i<NF;i++){
    Cfg ca=base, cb2=base;
    *(int*)((char*)&ca +F[i].off)=F[i].a;
    *(int*)((char*)&cb2+F[i].off)=F[i].b;
    double covA,covB,covP;
    g_run=0; uint64_t hA=draw(ca,0,&covA);
    g_run=1; uint64_t hB=draw(cb2,0,&covB);
    g_run=2; draw(ca,0,NULL); g_run=-1;
    if(hA==hB){ printf("%-26s %-7s %-9s no visible effect\n",F[i].name,"-","-"); continue; }
    tested++;
    nsite=0; memset(skip,0,sizeof skip);
    for(int r=0;r<r_n && nsite<1500;r++) for(uint64_t o=0;o<r_size[r] && nsite<1500;o++){
      if(snap[0][r][o]!=snap[2][r][o]) continue;
      if(snap[0][r][o]==snap[1][r][o]) continue;
      site[nsite].r=r; site[nsite].o=o; rawval[nsite]=snap[1][r][o]; nsite++; }
    if(!nsite){ printf("%-26s %-7d %-9s no candidates\n",F[i].name,0,"-"); continue; }
    g_lo=0; g_hi=nsite;
    if(draw(ca,1,&covP)!=hB){ printf("%-26s %-7d %-9s replay of all %d bytes not B\n",F[i].name,nsite,"-",nsite); continue; }
    int lo=0,hi=nsite;
    while(hi-lo>1){ int mid=(lo+hi)/2; g_lo=lo; g_hi=mid;
      if(draw(ca,1,&covP)==hB) hi=mid; else lo=mid; }
    int minset=lo+1; g_lo=0; g_hi=minset;
    for(int d=0;d<minset && minset<=256;d++){ skip[d]=1; if(draw(ca,1,&covP)!=hB) skip[d]=0; }
    int kept=0,idx[8],nk=0; for(int d=0;d<minset;d++) if(!skip[d]){ kept++; if(nk<8) idx[nk++]=d; }
    uint64_t hM=draw(ca,1,&covP); g_lo=0; g_hi=1<<30; memset(skip,0,sizeof skip);
    if(hM==hB && kept<=8){ pass++;
      printf("%-26s %-7d %8.1f%%  CAUSAL: %d-byte @",F[i].name,nsite,covP,kept);
      for(int t=0;t<nk;t++) printf(" reg%d:0x%llx",site[idx[t]].r,site[idx[t]].o);
      printf("\n");
    } else printf("%-26s %-7d %-9s reproduced by %d bytes - not isolated\n",F[i].name,nsite,"-",kept);
  }
  printf("-----------------------------------------------------------------\n");
  printf("%d of %d testable sampler fields isolated causally\n",pass,tested);
}; return 0; }
