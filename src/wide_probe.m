/* agx-probe/wide_probe -- axes no other probe sweeps: compute dispatch shape,
   threadgroup memory, viewport geometry, blend operations, and depth clip.
   Broad rather than deep: the point is coverage to grind overnight. */
#import "agxcommon.h"

typedef struct {
  uint32_t tgX,tgY,tgZ, gridX,gridY, tgMem;
  double vpX,vpY,vpW,vpH,vpN,vpF;
  int rgbOp,alphaOp,dclip,prim,fill;
} Cfg;

static id<MTLDevice> dev; static id<MTLTexture> col,ds; static id<MTLCommandQueue> q;
static id<MTLRenderPipelineState> pso; static id<MTLComputePipelineState> cps;
static id<MTLBuffer> buf;

static const char *kSrc="#include <metal_stdlib>\nusing namespace metal;\n"
"struct VOut{float4 pos [[position]];};\n"
"vertex VOut v_main(uint vid [[vertex_id]]){float2 p[3]={float2(-.9,-.9),float2(.9,-.9),float2(0,.9)};"
"VOut o;o.pos=float4(p[vid],0.3,1);return o;}\n"
"fragment float4 f_main(){return float4(1,0.4,0.15,1);}\n"
"kernel void c_main(device float *o [[buffer(0)]], threadgroup float *sh [[threadgroup(0)]],\n"
"                   uint i [[thread_position_in_grid]], uint l [[thread_position_in_threadgroup]]){\n"
"  sh[l]=o[i]*1.5f; threadgroup_barrier(mem_flags::mem_threadgroup); o[i]=sh[l]+1.0f; }\n";

static void render(Cfg c){ @autoreleasepool{
  id<MTLCommandBuffer> cb=[q commandBuffer];
  MTLRenderPassDescriptor *rp=[MTLRenderPassDescriptor renderPassDescriptor];
  rp.colorAttachments[0].texture=col; rp.colorAttachments[0].loadAction=MTLLoadActionClear;
  rp.colorAttachments[0].storeAction=MTLStoreActionStore;
  rp.depthAttachment.texture=ds; rp.depthAttachment.loadAction=MTLLoadActionClear;
  rp.depthAttachment.storeAction=MTLStoreActionDontCare;
  id<MTLRenderCommandEncoder> en=[cb renderCommandEncoderWithDescriptor:rp];
  [en setRenderPipelineState:pso];
  [en setViewport:(MTLViewport){c.vpX,c.vpY,c.vpW,c.vpH,c.vpN,c.vpF}];
  [en setDepthClipMode:(MTLDepthClipMode)c.dclip];
  [en setTriangleFillMode:(MTLTriangleFillMode)c.fill];
  [en drawPrimitives:(MTLPrimitiveType)c.prim vertexStart:0 vertexCount:3]; [en endEncoding];
  id<MTLComputeCommandEncoder> ce=[cb computeCommandEncoder];
  [ce setComputePipelineState:cps]; [ce setBuffer:buf offset:0 atIndex:0];
  [ce setThreadgroupMemoryLength:c.tgMem atIndex:0];
  [ce dispatchThreads:MTLSizeMake(c.gridX,c.gridY,1)
      threadsPerThreadgroup:MTLSizeMake(c.tgX,c.tgY,c.tgZ)];
  [ce endEncoding];
  [cb commit]; [cb waitUntilCompleted]; } }

typedef struct { const char *name; size_t off; int kind; int n; double v[8]; } Axis;
#define O(f) offsetof(Cfg,f)
static Axis AX[]={
 {"threadgroup.x",        O(tgX),  K_INT,4,{1,2,4,8}},
 {"threadgroup.y",        O(tgY),  K_INT,3,{1,2,4}},
 {"threadgroup.z",        O(tgZ),  K_INT,2,{1,2}},
 {"dispatch.gridX",       O(gridX),K_INT,4,{8,16,32,64}},
 {"dispatch.gridY",       O(gridY),K_INT,3,{1,2,4}},
 {"threadgroupMemory",    O(tgMem),K_INT,4,{256,512,1024,2048}},
 {"viewport.originX",     O(vpX),  K_INT,4,{0,4,8,16}},
 {"viewport.originY",     O(vpY),  K_INT,4,{0,4,8,16}},
 {"viewport.width",       O(vpW),  K_FLOAT,4,{16,32,48,64}},
 {"viewport.height",      O(vpH),  K_FLOAT,4,{16,32,48,64}},
 {"viewport.znear",       O(vpN),  K_FLOAT,4,{0,0.25,0.5,0.75}},
 {"viewport.zfar",        O(vpF),  K_FLOAT,4,{0.25,0.5,0.75,1.0}},
 {"blend.rgbOperation",   O(rgbOp),K_ENUM,5,{0,1,2,3,4}},
 {"blend.alphaOperation", O(alphaOp),K_ENUM,5,{0,1,2,3,4}},
 {"depthClipMode",        O(dclip),K_ENUM,2,{0,1}},
 {"primitiveType",        O(prim), K_ENUM,4,{0,1,3,4}},
 {"triangleFillMode",     O(fill), K_ENUM,2,{0,1}},
};
#define NAX (int)(sizeof(AX)/sizeof(AX[0]))

int main(void){ @autoreleasepool {
  dev=MTLCreateSystemDefaultDevice(); NSError *e=nil;
  id<MTLLibrary> lib=[dev newLibraryWithSource:@(kSrc) options:nil error:&e];
  if(!lib){fprintf(stderr,"shader: %s\n",e.description.UTF8String);return 1;}
  MTLRenderPipelineDescriptor *pd=[MTLRenderPipelineDescriptor new];
  pd.vertexFunction=[lib newFunctionWithName:@"v_main"]; pd.fragmentFunction=[lib newFunctionWithName:@"f_main"];
  MTLRenderPipelineColorAttachmentDescriptor *ca=pd.colorAttachments[0];
  ca.pixelFormat=MTLPixelFormatBGRA8Unorm; ca.blendingEnabled=YES;
  ca.sourceRGBBlendFactor=MTLBlendFactorSourceAlpha; ca.destinationRGBBlendFactor=MTLBlendFactorOneMinusSourceAlpha;
  pd.depthAttachmentPixelFormat=MTLPixelFormatDepth32Float;
  pso=[dev newRenderPipelineStateWithDescriptor:pd error:&e];
  cps=[dev newComputePipelineStateWithFunction:[lib newFunctionWithName:@"c_main"] error:&e];
  if(!pso||!cps){fprintf(stderr,"pipeline fail\n");return 1;}
  MTLTextureDescriptor *td=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:64 height:64 mipmapped:NO];
  td.usage=MTLTextureUsageRenderTarget; td.storageMode=MTLStorageModePrivate; col=[dev newTextureWithDescriptor:td];
  MTLTextureDescriptor *dd=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float width:64 height:64 mipmapped:NO];
  dd.usage=MTLTextureUsageRenderTarget; dd.storageMode=MTLStorageModePrivate; ds=[dev newTextureWithDescriptor:dd];
  q=[dev newCommandQueue]; buf=[dev newBufferWithLength:4096 options:MTLResourceStorageModeShared];
  if(!agx_install("AGXG16GFamilyCommandBuffer")) return 1;
  g_post=1;

  Cfg base={4,1,1, 32,1, 512, 0,0,64,64,0,1, 0,0, 0, 3, 0};
  for(int i=0;i<4;i++) render(base);
  agx_locate();
  int need=2; for(int a=0;a<NAX;a++) need+=AX[a].n;
  agx_alloc(need+2);
  fprintf(stderr,"[wide] %d regions, %d axes, %d runs\n",r_n,NAX,need);
  g_run=0; render(base); g_run=1; render(base);
  int run=2; static int start[NAX];
  for(int a=0;a<NAX;a++){ start[a]=run;
    for(int j=0;j<AX[a].n;j++){ Cfg c=base; void *p=(char*)&c+AX[a].off;
      switch(AX[a].kind){ case K_ENUM: *(int*)p=(int)AX[a].v[j]; break;
        case K_INT: *(uint32_t*)p=(uint32_t)AX[a].v[j]; break;
        case K_FLOAT: *(double*)p=AX[a].v[j]; break; }
      g_run=run++; render(c); } }
  g_run=-1;
  fprintf(stderr,"[wide] noise %ld / %llu\n\n",agx_noise(0,1),r_tot);
  printf("%-26s %-5s %-9s %s\n","FIELD","REG","OFFSET","ENCODING");
  printf("-----------------------------------------------------------------\n");
  int loc=0;
  for(int a=0;a<NAX;a++){
    AxisMeta m={AX[a].name,AX[a].kind,AX[a].n,{0}};
    for(int j=0;j<AX[a].n;j++) m.v[j]=AX[a].v[j];
    int hits=0; char buf2[80];
    for(int r=0;r<r_n && hits<2;r++) for(uint64_t o=0;o<r_size[r] && hits<2;o++){
      if(agx_masked(0,1,r,o)) continue;
      const char *d=agx_classify(r,o,start[a],&m,buf2,sizeof buf2);
      if(!d) continue;
      printf("%-26s %-5d 0x%06llx  %s\n",hits?"":AX[a].name,r,o,d); hits++; }
    if(!hits) printf("%-26s %-5s %-9s not located\n",AX[a].name,"-","-"); else loc++;
  }
  fprintf(stderr,"\n[wide] %d of %d axes located\n",loc,NAX);
}; return 0; }
