/* agx-probe/pass_probe -- render-pass and dispatch state, the axes no other
   probe touches: load/store actions, clear values, render target geometry,
   visibility results, and compute threadgroup shape. */
#import "agxcommon.h"

typedef struct {
  int cLoad,cStore,dLoad,dStore,sLoad,sStore;
  float clrR,clrG,clrB,clrA,clrD;
  uint32_t clrS, rtW, rtH, visMode, tgX, tgY, gridX;
} Cfg;

static id<MTLDevice> dev; static id<MTLTexture> col,ds; static id<MTLCommandQueue> q;
static id<MTLRenderPipelineState> pso; static id<MTLComputePipelineState> cps;
static id<MTLBuffer> visBuf, outBuf;

static const char *kSrc="#include <metal_stdlib>\nusing namespace metal;\n"
"struct VOut{float4 pos [[position]];};\n"
"vertex VOut v_main(uint vid [[vertex_id]]){float2 p[3]={float2(-.9,-.9),float2(.9,-.9),float2(0,.9)};"
"VOut o;o.pos=float4(p[vid],0.2,1);return o;}\n"
"fragment float4 f_main(){return float4(1,0.3,0.1,1);}\n"
"kernel void c_main(device float *o [[buffer(0)]], uint i [[thread_position_in_grid]]){o[i]=o[i]*1.5f+1.0f;}\n";

static void render(Cfg c){ @autoreleasepool{
  id<MTLCommandBuffer> cb=[q commandBuffer];
  MTLRenderPassDescriptor *rp=[MTLRenderPassDescriptor renderPassDescriptor];
  rp.colorAttachments[0].texture=col;
  rp.colorAttachments[0].loadAction=(MTLLoadAction)c.cLoad;
  rp.colorAttachments[0].storeAction=(MTLStoreAction)c.cStore;
  rp.colorAttachments[0].clearColor=MTLClearColorMake(c.clrR,c.clrG,c.clrB,c.clrA);
  rp.depthAttachment.texture=ds; rp.depthAttachment.loadAction=(MTLLoadAction)c.dLoad;
  rp.depthAttachment.storeAction=(MTLStoreAction)c.dStore; rp.depthAttachment.clearDepth=c.clrD;
  rp.stencilAttachment.texture=ds; rp.stencilAttachment.loadAction=(MTLLoadAction)c.sLoad;
  rp.stencilAttachment.storeAction=(MTLStoreAction)c.sStore; rp.stencilAttachment.clearStencil=c.clrS;
  rp.renderTargetWidth=c.rtW; rp.renderTargetHeight=c.rtH;
  rp.visibilityResultBuffer=visBuf;
  id<MTLRenderCommandEncoder> en=[cb renderCommandEncoderWithDescriptor:rp];
  [en setRenderPipelineState:pso];
  [en setVisibilityResultMode:(MTLVisibilityResultMode)c.visMode offset:0];
  [en drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
  [en endEncoding];
  id<MTLComputeCommandEncoder> ce=[cb computeCommandEncoder];
  [ce setComputePipelineState:cps]; [ce setBuffer:outBuf offset:0 atIndex:0];
  [ce dispatchThreads:MTLSizeMake(c.gridX,1,1) threadsPerThreadgroup:MTLSizeMake(c.tgX,c.tgY,1)];
  [ce endEncoding];
  [cb commit]; [cb waitUntilCompleted]; } }

typedef struct { const char *name; size_t off; int kind; int n; double v[8]; } Axis;
#define O(f) offsetof(Cfg,f)
static Axis AX[]={
 {"color.loadAction",   O(cLoad), K_ENUM,3,{0,1,2}},
 {"color.storeAction",  O(cStore),K_ENUM,3,{0,1,2}},
 {"depth.loadAction",   O(dLoad), K_ENUM,3,{0,1,2}},
 {"depth.storeAction",  O(dStore),K_ENUM,3,{0,1,2}},
 {"stencil.loadAction", O(sLoad), K_ENUM,3,{0,1,2}},
 {"stencil.storeAction",O(sStore),K_ENUM,3,{0,1,2}},
 {"clearColor.red",     O(clrR),  K_FLOAT,5,{0,0.25,0.5,0.75,1.0}},
 {"clearColor.green",   O(clrG),  K_FLOAT,5,{0,0.25,0.5,0.75,1.0}},
 {"clearColor.blue",    O(clrB),  K_FLOAT,5,{0,0.25,0.5,0.75,1.0}},
 {"clearColor.alpha",   O(clrA),  K_FLOAT,5,{0,0.25,0.5,0.75,1.0}},
 {"clearDepth",         O(clrD),  K_FLOAT,5,{0,0.25,0.5,0.75,1.0}},
 {"clearStencil",       O(clrS),  K_INT,  5,{1,2,4,0x40,0xA5}},
 {"renderTargetWidth",  O(rtW),   K_INT,  4,{16,32,48,64}},
 {"renderTargetHeight", O(rtH),   K_INT,  4,{16,32,48,64}},
 {"visibilityResultMode",O(visMode),K_ENUM,3,{0,1,2}},
 {"threadgroup.x",      O(tgX),   K_INT,  4,{1,2,4,8}},
 {"threadgroup.y",      O(tgY),   K_INT,  3,{1,2,4}},
 {"dispatch.gridX",     O(gridX), K_INT,  4,{8,16,32,64}},
};
#define NAX (int)(sizeof(AX)/sizeof(AX[0]))

int main(void){ @autoreleasepool {
  dev=MTLCreateSystemDefaultDevice(); NSError *e=nil;
  id<MTLLibrary> lib=[dev newLibraryWithSource:@(kSrc) options:nil error:&e];
  if(!lib){fprintf(stderr,"shader: %s\n",e.description.UTF8String);return 1;}
  MTLRenderPipelineDescriptor *pd=[MTLRenderPipelineDescriptor new];
  pd.vertexFunction=[lib newFunctionWithName:@"v_main"]; pd.fragmentFunction=[lib newFunctionWithName:@"f_main"];
  pd.colorAttachments[0].pixelFormat=MTLPixelFormatBGRA8Unorm;
  pd.depthAttachmentPixelFormat=MTLPixelFormatDepth32Float_Stencil8;
  pd.stencilAttachmentPixelFormat=MTLPixelFormatDepth32Float_Stencil8;
  pso=[dev newRenderPipelineStateWithDescriptor:pd error:&e];
  cps=[dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"c_main"] error:&e];
  if(!pso||!cps){fprintf(stderr,"pipeline fail\n");return 1;}
  MTLTextureDescriptor *td=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:64 height:64 mipmapped:NO];
  td.usage=MTLTextureUsageRenderTarget; td.storageMode=MTLStorageModePrivate; col=[dev newTextureWithDescriptor:td];
  MTLTextureDescriptor *dd=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float_Stencil8 width:64 height:64 mipmapped:NO];
  dd.usage=MTLTextureUsageRenderTarget; dd.storageMode=MTLStorageModePrivate; ds=[dev newTextureWithDescriptor:dd];
  q=[dev newCommandQueue];
  visBuf=[dev newBufferWithLength:256 options:MTLResourceStorageModeShared];
  outBuf=[dev newBufferWithLength:1024 options:MTLResourceStorageModeShared];
  if(!agx_install("AGXG16GFamilyCommandBuffer")) return 1;

  Cfg base={2,0,2,1,2,1, 0,0,0,1, 0.5f, 0, 64,64, 0, 4,1, 32};
  for(int i=0;i<4;i++) render(base);
  agx_locate();
  int need=2; for(int a=0;a<NAX;a++) need+=AX[a].n;
  agx_alloc(need+2);
  fprintf(stderr,"[pass] %d regions, %d axes, %d runs\n",r_n,NAX,need);

  g_run=0; render(base); g_run=1; render(base);
  int run=2; static int start[NAX];
  for(int a=0;a<NAX;a++){ start[a]=run;
    for(int j=0;j<AX[a].n;j++){ Cfg c=base; void *p=(char*)&c+AX[a].off;
      switch(AX[a].kind){ case K_ENUM: *(int*)p=(int)AX[a].v[j]; break;
        case K_INT: *(uint32_t*)p=(uint32_t)AX[a].v[j]; break;
        case K_FLOAT: *(float*)p=(float)AX[a].v[j]; break; }
      g_run=run++; render(c); } }
  g_run=-1;
  fprintf(stderr,"[pass] noise mask %ld / %llu bytes\n\n",agx_noise(0,1),r_tot);

  printf("%-24s %-5s %-9s %s\n","FIELD","REG","OFFSET","ENCODING");
  printf("---------------------------------------------------------------\n");
  int located=0;
  for(int a=0;a<NAX;a++){
    AxisMeta m={AX[a].name,AX[a].kind,AX[a].n,{0}};
    for(int j=0;j<AX[a].n;j++) m.v[j]=AX[a].v[j];
    int hits=0; char buf[64];
    for(int r=0;r<r_n && hits<2;r++) for(uint64_t o=0;o<r_size[r] && hits<2;o++){
      if(agx_masked(0,1,r,o)) continue;
      const char *d=agx_classify(r,o,start[a],&m,buf,sizeof buf);
      if(!d) continue;
      printf("%-24s %-5d 0x%06llx  %s\n",hits?"":AX[a].name,r,o,d); hits++; }
    if(!hits) printf("%-24s %-5s %-9s not located\n",AX[a].name,"-","-"); else located++;
  }
  fprintf(stderr,"\n[pass] %d of %d axes located\n",located,NAX);
}; return 0; }
