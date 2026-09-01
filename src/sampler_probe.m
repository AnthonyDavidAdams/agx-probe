/* agx-probe/sampler_probe -- sampler state failed in state_probe because the
   scene never exercised it: address modes need UVs outside [0,1], LOD clamps
   need mipmaps, compare needs a depth texture. This builds a scene where every
   sampler axis actually changes what the hardware must do. */
#import "agxcommon.h"

typedef struct {
  int minF,magF,mipF,addrS,addrT,addrR,normC,cmpF,aniso,border;
  float lodMin,lodMax;
} Cfg;

static id<MTLDevice> dev; static id<MTLTexture> col,tex,depthTex; static id<MTLCommandQueue> q;
static id<MTLRenderPipelineState> pso;

static const char *kSrc="#include <metal_stdlib>\nusing namespace metal;\n"
"struct VOut{float4 pos [[position]]; float2 uv;};\n"
"vertex VOut v_main(uint vid [[vertex_id]]){\n"
"  float2 p[3]={float2(-1,-1),float2(3,-1),float2(-1,3)};\n"
"  VOut o;o.pos=float4(p[vid],0,1);\n"
"  o.uv=(p[vid]*0.5+0.5)*3.0-1.0;   /* deliberately outside [0,1] */\n"
"  return o;}\n"
"fragment float4 f_main(VOut i [[stage_in]], texture2d<float> t [[texture(0)]],\n"
"                       depth2d<float> d [[texture(1)]], sampler s [[sampler(0)]],\n"
"                       sampler cs [[sampler(1)]]){\n"
"  float4 a=t.sample(s,i.uv);\n"
"  float c=d.sample_compare(cs,i.uv,0.5f);\n"
"  return a+c;}\n";

static void render(Cfg c){ @autoreleasepool{
  MTLSamplerDescriptor *sd=[MTLSamplerDescriptor new];
  sd.minFilter=(MTLSamplerMinMagFilter)c.minF; sd.magFilter=(MTLSamplerMinMagFilter)c.magF;
  sd.mipFilter=(MTLSamplerMipFilter)c.mipF;
  sd.sAddressMode=(MTLSamplerAddressMode)c.addrS;
  sd.tAddressMode=(MTLSamplerAddressMode)c.addrT;
  sd.rAddressMode=(MTLSamplerAddressMode)c.addrR;
  sd.normalizedCoordinates=(c.normC==1);
  sd.maxAnisotropy=c.aniso; sd.lodMinClamp=c.lodMin; sd.lodMaxClamp=c.lodMax;
  sd.borderColor=(MTLSamplerBorderColor)c.border;
  sd.supportArgumentBuffers=YES;
  id<MTLSamplerState> s=[dev newSamplerStateWithDescriptor:sd];
  MTLSamplerDescriptor *cd=[MTLSamplerDescriptor new];
  cd.compareFunction=(MTLCompareFunction)c.cmpF; cd.supportArgumentBuffers=YES;
  id<MTLSamplerState> cs=[dev newSamplerStateWithDescriptor:cd];

  id<MTLCommandBuffer> cb=[q commandBuffer];
  MTLRenderPassDescriptor *rp=[MTLRenderPassDescriptor renderPassDescriptor];
  rp.colorAttachments[0].texture=col; rp.colorAttachments[0].loadAction=MTLLoadActionClear;
  rp.colorAttachments[0].storeAction=MTLStoreActionStore;
  id<MTLRenderCommandEncoder> en=[cb renderCommandEncoderWithDescriptor:rp];
  [en setRenderPipelineState:pso];
  [en setFragmentTexture:tex atIndex:0]; [en setFragmentTexture:depthTex atIndex:1];
  [en setFragmentSamplerState:s atIndex:0]; [en setFragmentSamplerState:cs atIndex:1];
  [en drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3]; [en endEncoding];
  [cb commit]; [cb waitUntilCompleted]; } }

typedef struct { const char *name; size_t off; int kind; int n; double v[8]; } Axis;
#define O(f) offsetof(Cfg,f)
static Axis AX[]={
 {"sampler.minFilter",     O(minF), K_ENUM,2,{0,1}},
 {"sampler.magFilter",     O(magF), K_ENUM,2,{0,1}},
 {"sampler.mipFilter",     O(mipF), K_ENUM,3,{0,1,2}},
 {"sampler.sAddressMode",  O(addrS),K_ENUM,6,{0,1,2,3,4,5}},
 {"sampler.tAddressMode",  O(addrT),K_ENUM,6,{0,1,2,3,4,5}},
 {"sampler.rAddressMode",  O(addrR),K_ENUM,6,{0,1,2,3,4,5}},
 {"sampler.normalizedCoords",O(normC),K_ENUM,2,{0,1}},
 {"sampler.compareFunction",O(cmpF),K_ENUM,8,{0,1,2,3,4,5,6,7}},
 {"sampler.maxAnisotropy", O(aniso),K_INT, 5,{1,2,4,8,16}},
 {"sampler.borderColor",   O(border),K_ENUM,3,{0,1,2}},
 {"sampler.lodMinClamp",   O(lodMin),K_FLOAT,4,{0,1.0,2.0,3.0}},
 {"sampler.lodMaxClamp",   O(lodMax),K_FLOAT,4,{1.0,2.0,3.0,4.0}},
};
#define NAX (int)(sizeof(AX)/sizeof(AX[0]))

int main(void){ @autoreleasepool {
  dev=MTLCreateSystemDefaultDevice(); NSError *e=nil;
  id<MTLLibrary> lib=[dev newLibraryWithSource:@(kSrc) options:nil error:&e];
  if(!lib){fprintf(stderr,"shader: %s\n",e.description.UTF8String);return 1;}
  MTLRenderPipelineDescriptor *pd=[MTLRenderPipelineDescriptor new];
  pd.vertexFunction=[lib newFunctionWithName:@"v_main"]; pd.fragmentFunction=[lib newFunctionWithName:@"f_main"];
  pd.colorAttachments[0].pixelFormat=MTLPixelFormatBGRA8Unorm;
  pso=[dev newRenderPipelineStateWithDescriptor:pd error:&e];
  if(!pso){fprintf(stderr,"pso: %s\n",e.description.UTF8String);return 1;}
  MTLTextureDescriptor *td=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:64 height:64 mipmapped:NO];
  td.usage=MTLTextureUsageRenderTarget; td.storageMode=MTLStorageModePrivate; col=[dev newTextureWithDescriptor:td];
  MTLTextureDescriptor *st=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:64 height:64 mipmapped:YES];
  st.usage=MTLTextureUsageShaderRead; st.mipmapLevelCount=6; tex=[dev newTextureWithDescriptor:st];
  MTLTextureDescriptor *dt=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float width:64 height:64 mipmapped:NO];
  dt.usage=MTLTextureUsageShaderRead; dt.storageMode=MTLStorageModePrivate; depthTex=[dev newTextureWithDescriptor:dt];
  q=[dev newCommandQueue];
  if(!agx_install("AGXG16GFamilyCommandBuffer")) return 1;

  Cfg base={1,1,1, 0,0,0, 1, 1, 1, 0, 0.0f,4.0f};
  for(int i=0;i<4;i++) render(base);
  agx_locate();
  int need=2; for(int a=0;a<NAX;a++) need+=AX[a].n;
  agx_alloc(need+2);
  fprintf(stderr,"[samp] %d regions, %d axes\n",r_n,NAX);
  g_run=0; render(base); g_run=1; render(base);
  int run=2; static int start[NAX];
  for(int a=0;a<NAX;a++){ start[a]=run;
    for(int j=0;j<AX[a].n;j++){ Cfg c=base; void *p=(char*)&c+AX[a].off;
      switch(AX[a].kind){ case K_ENUM: *(int*)p=(int)AX[a].v[j]; break;
        case K_INT: *(uint32_t*)p=(uint32_t)AX[a].v[j]; break;
        case K_FLOAT: *(float*)p=(float)AX[a].v[j]; break; }
      g_run=run++; render(c); } }
  g_run=-1;
  fprintf(stderr,"[samp] noise mask %ld\n\n",agx_noise(0,1));
  printf("%-26s %-5s %-9s %s\n","FIELD","REG","OFFSET","ENCODING");
  printf("-----------------------------------------------------------------\n");
  int located=0;
  for(int a=0;a<NAX;a++){
    AxisMeta m={AX[a].name,AX[a].kind,AX[a].n,{0}};
    for(int j=0;j<AX[a].n;j++) m.v[j]=AX[a].v[j];
    int hits=0; char buf[64];
    for(int r=0;r<r_n && hits<2;r++) for(uint64_t o=0;o<r_size[r] && hits<2;o++){
      if(agx_masked(0,1,r,o)) continue;
      const char *d=agx_classify(r,o,start[a],&m,buf,sizeof buf);
      if(!d) continue;
      printf("%-26s %-5d 0x%06llx  %s\n",hits?"":AX[a].name,r,o,d); hits++; }
    if(!hits) printf("%-26s %-5s %-9s not located\n",AX[a].name,"-","-"); else located++;
  }
  fprintf(stderr,"\n[samp] %d of %d axes located\n",located,NAX);
}; return 0; }
