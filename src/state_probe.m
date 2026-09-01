/* agx-probe/state_probe -- one-variable-at-a-time sweep of Metal fixed-function
   state, recovering byte offsets, bit positions and encodings in the AGX
   command/descriptor arenas. Capture is serial by necessity; analysis is parallel. */
#import "agxcommon.h"

typedef struct {
  int dcmp,dwrite,cull,wind,fill,dclip;
  int scmpF,sfailF,dfailF,spassF;
  uint32_t rmask,wmask,sref;
  uint32_t sx,sy,sw,sh;
  float dbias,dslope,dclamp;
  float bcr,bcg,bcb,bca;
  /* sampler */
  int minF,magF,mipF,addrS,addrT,addrR,normCoord,sampCmp,aniso,borderC;
  float lodMin,lodMax;
  /* vertex + colour mask */
  int vfmt,vstep,writeMask;
  uint32_t voff,vstride;
} Cfg;

static id<MTLDevice> dev; static id<MTLTexture> col,ds,tex;
static id<MTLCommandQueue> q; static id<MTLBuffer> vbuf; static id<MTLLibrary> lib;

static const char *kSrc=
"#include <metal_stdlib>\nusing namespace metal;\n"
"struct VIn{float2 pos [[attribute(0)]]; float2 uv [[attribute(1)]];};\n"
"struct VOut{float4 pos [[position]]; float2 uv;};\n"
"vertex VOut v_main(VIn i [[stage_in]]){VOut o;o.pos=float4(i.pos,0,1);o.uv=i.uv;return o;}\n"
"fragment float4 f_main(VOut i [[stage_in]], texture2d<float> t [[texture(0)]],\n"
"                       sampler s [[sampler(0)]]){ return t.sample(s,i.uv); }\n";

static id<MTLRenderPipelineState> mkpso(Cfg c){
  MTLVertexDescriptor *vd=[MTLVertexDescriptor new];
  vd.attributes[0].format=(MTLVertexFormat)c.vfmt; vd.attributes[0].offset=0; vd.attributes[0].bufferIndex=0;
  vd.attributes[1].format=MTLVertexFormatFloat2; vd.attributes[1].offset=c.voff; vd.attributes[1].bufferIndex=0;
  vd.layouts[0].stride=c.vstride; vd.layouts[0].stepFunction=(MTLVertexStepFunction)c.vstep;
  vd.layouts[0].stepRate = (c.vstep==MTLVertexStepFunctionConstant) ? 0 : 1;
  MTLRenderPipelineDescriptor *pd=[MTLRenderPipelineDescriptor new];
  pd.vertexFunction=[lib newFunctionWithName:@"v_main"];
  pd.fragmentFunction=[lib newFunctionWithName:@"f_main"];
  pd.vertexDescriptor=vd;
  MTLRenderPipelineColorAttachmentDescriptor *ca=pd.colorAttachments[0];
  ca.pixelFormat=MTLPixelFormatBGRA8Unorm; ca.writeMask=(MTLColorWriteMask)c.writeMask;
  ca.blendingEnabled=YES;
  ca.sourceRGBBlendFactor=MTLBlendFactorBlendColor; ca.destinationRGBBlendFactor=MTLBlendFactorOneMinusBlendColor;
  pd.depthAttachmentPixelFormat=MTLPixelFormatDepth32Float_Stencil8;
  pd.stencilAttachmentPixelFormat=MTLPixelFormatDepth32Float_Stencil8;
  NSError *e=nil; id<MTLRenderPipelineState> p=[dev newRenderPipelineStateWithDescriptor:pd error:&e];
  return p;
}
static void render(Cfg c){ @autoreleasepool{
  id<MTLRenderPipelineState> pso=mkpso(c); if(!pso) return;
  MTLStencilDescriptor *sf=[MTLStencilDescriptor new];
  sf.stencilCompareFunction=(MTLCompareFunction)c.scmpF;
  sf.stencilFailureOperation=(MTLStencilOperation)c.sfailF;
  sf.depthFailureOperation=(MTLStencilOperation)c.dfailF;
  sf.depthStencilPassOperation=(MTLStencilOperation)c.spassF;
  sf.readMask=c.rmask; sf.writeMask=c.wmask;
  MTLDepthStencilDescriptor *x=[MTLDepthStencilDescriptor new];
  x.depthCompareFunction=(MTLCompareFunction)c.dcmp; x.depthWriteEnabled=(c.dwrite==1);
  x.frontFaceStencil=sf; x.backFaceStencil=sf;
  id<MTLDepthStencilState> dss=[dev newDepthStencilStateWithDescriptor:x];

  MTLSamplerDescriptor *sd=[MTLSamplerDescriptor new];
  sd.minFilter=(MTLSamplerMinMagFilter)c.minF; sd.magFilter=(MTLSamplerMinMagFilter)c.magF;
  sd.mipFilter=(MTLSamplerMipFilter)c.mipF;
  sd.sAddressMode=(MTLSamplerAddressMode)c.addrS; sd.tAddressMode=(MTLSamplerAddressMode)c.addrT;
  sd.rAddressMode=(MTLSamplerAddressMode)c.addrR;
  sd.normalizedCoordinates=(c.normCoord==1);
  sd.compareFunction=(MTLCompareFunction)c.sampCmp;
  sd.maxAnisotropy=c.aniso; sd.lodMinClamp=c.lodMin; sd.lodMaxClamp=c.lodMax;
  sd.borderColor=(MTLSamplerBorderColor)c.borderC;
  sd.supportArgumentBuffers=YES;
  id<MTLSamplerState> samp=[dev newSamplerStateWithDescriptor:sd];

  id<MTLCommandBuffer> cb=[q commandBuffer];
  MTLRenderPassDescriptor *rp=[MTLRenderPassDescriptor renderPassDescriptor];
  rp.colorAttachments[0].texture=col; rp.colorAttachments[0].loadAction=MTLLoadActionClear; rp.colorAttachments[0].storeAction=MTLStoreActionStore;
  rp.depthAttachment.texture=ds; rp.depthAttachment.loadAction=MTLLoadActionClear; rp.depthAttachment.storeAction=MTLStoreActionDontCare;
  rp.stencilAttachment.texture=ds; rp.stencilAttachment.loadAction=MTLLoadActionClear; rp.stencilAttachment.storeAction=MTLStoreActionDontCare;
  id<MTLRenderCommandEncoder> en=[cb renderCommandEncoderWithDescriptor:rp];
  [en setRenderPipelineState:pso]; [en setDepthStencilState:dss];
  [en setVertexBuffer:vbuf offset:0 atIndex:0];
  [en setFragmentTexture:tex atIndex:0]; [en setFragmentSamplerState:samp atIndex:0];
  [en setCullMode:(MTLCullMode)c.cull]; [en setFrontFacingWinding:(MTLWinding)c.wind];
  [en setTriangleFillMode:(MTLTriangleFillMode)c.fill]; [en setDepthClipMode:(MTLDepthClipMode)c.dclip];
  [en setStencilReferenceValue:c.sref];
  [en setScissorRect:(MTLScissorRect){c.sx,c.sy,c.sw,c.sh}];
  [en setDepthBias:c.dbias slopeScale:c.dslope clamp:c.dclamp];
  [en setBlendColorRed:c.bcr green:c.bcg blue:c.bcb alpha:c.bca];
  [en drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3]; [en endEncoding];
  [cb commit]; [cb waitUntilCompleted]; } }

typedef struct { AxisMeta m; size_t off; } Axis;
#define O(f) offsetof(Cfg,f)
static Axis AX[]={
 {{"depthCompareFunction",K_ENUM,7,{1,2,3,4,5,6,7}},O(dcmp)},
 {{"depthWriteEnabled",K_ENUM,2,{0,1}},O(dwrite)},
 {{"cullMode",K_ENUM,3,{0,1,2}},O(cull)},
 {{"frontFacingWinding",K_ENUM,2,{0,1}},O(wind)},
 {{"triangleFillMode",K_ENUM,2,{0,1}},O(fill)},
 {{"depthClipMode",K_ENUM,2,{0,1}},O(dclip)},
 {{"stencilCompare.front",K_ENUM,8,{0,1,2,3,4,5,6,7}},O(scmpF)},
 {{"stencilFailOp.front",K_ENUM,8,{0,1,2,3,4,5,6,7}},O(sfailF)},
 {{"depthFailOp.front",K_ENUM,8,{0,1,2,3,4,5,6,7}},O(dfailF)},
 {{"stencilPassOp.front",K_ENUM,8,{0,1,2,3,4,5,6,7}},O(spassF)},
 {{"stencilReadMask",K_INT,6,{0x01,0x02,0x04,0x40,0x80,0xA5}},O(rmask)},
 {{"stencilWriteMask",K_INT,6,{0x01,0x02,0x04,0x40,0x80,0x5A}},O(wmask)},
 {{"stencilReferenceValue",K_INT,6,{0x01,0x02,0x04,0x40,0x80,0x3C}},O(sref)},
 {{"scissor.x",K_INT,5,{0,1,2,4,8}},O(sx)},
 {{"scissor.y",K_INT,5,{0,1,2,4,8}},O(sy)},
 {{"scissor.width",K_INT,5,{8,16,24,32,40}},O(sw)},
 {{"scissor.height",K_INT,5,{8,16,24,32,40}},O(sh)},
 {{"depthBias",K_FLOAT,5,{0.25,0.5,1.0,2.0,4.0}},O(dbias)},
 {{"depthBias.slopeScale",K_FLOAT,5,{0.25,0.5,1.0,2.0,4.0}},O(dslope)},
 {{"depthBias.clamp",K_FLOAT,5,{0.25,0.5,1.0,2.0,4.0}},O(dclamp)},
 {{"blendColor.red",K_FLOAT,5,{0,0.25,0.5,0.75,1.0}},O(bcr)},
 {{"blendColor.green",K_FLOAT,5,{0,0.25,0.5,0.75,1.0}},O(bcg)},
 {{"blendColor.blue",K_FLOAT,5,{0,0.25,0.5,0.75,1.0}},O(bcb)},
 {{"blendColor.alpha",K_FLOAT,5,{0,0.25,0.5,0.75,1.0}},O(bca)},
 /* sampler state */
 {{"sampler.minFilter",K_ENUM,2,{0,1}},O(minF)},
 {{"sampler.magFilter",K_ENUM,2,{0,1}},O(magF)},
 {{"sampler.mipFilter",K_ENUM,3,{0,1,2}},O(mipF)},
 {{"sampler.sAddressMode",K_ENUM,6,{0,1,2,3,4,5}},O(addrS)},
 {{"sampler.tAddressMode",K_ENUM,6,{0,1,2,3,4,5}},O(addrT)},
 {{"sampler.rAddressMode",K_ENUM,6,{0,1,2,3,4,5}},O(addrR)},
 {{"sampler.normalizedCoords",K_ENUM,2,{0,1}},O(normCoord)},
 {{"sampler.compareFunction",K_ENUM,8,{0,1,2,3,4,5,6,7}},O(sampCmp)},
 {{"sampler.maxAnisotropy",K_INT,5,{1,2,4,8,16}},O(aniso)},
 {{"sampler.borderColor",K_ENUM,3,{0,1,2}},O(borderC)},
 {{"sampler.lodMinClamp",K_FLOAT,4,{0,1.0,2.0,4.0}},O(lodMin)},
 {{"sampler.lodMaxClamp",K_FLOAT,4,{1.0,2.0,4.0,8.0}},O(lodMax)},
 /* vertex fetch */
 {{"vertex.format",K_ENUM,6,{28,29,30,31,20,21}},O(vfmt)},
 {{"vertex.stepFunction",K_ENUM,2,{1,2}},O(vstep)},
 {{"vertex.attrOffset",K_INT,4,{8,12,16,20}},O(voff)},
 {{"vertex.layoutStride",K_INT,4,{16,24,32,48}},O(vstride)},
 {{"colorWriteMask",K_ENUM,5,{0,1,3,7,15}},O(writeMask)},
};
#define NAX (int)(sizeof(AX)/sizeof(AX[0]))

int main(void){ @autoreleasepool {
  dev=MTLCreateSystemDefaultDevice(); NSError *e=nil;
  lib=[dev newLibraryWithSource:@(kSrc) options:nil error:&e];
  if(!lib){fprintf(stderr,"shader: %s\n",e.description.UTF8String);return 1;}
  MTLTextureDescriptor *td=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:64 height:64 mipmapped:NO];
  td.usage=MTLTextureUsageRenderTarget; td.storageMode=MTLStorageModePrivate; col=[dev newTextureWithDescriptor:td];
  MTLTextureDescriptor *dd=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float_Stencil8 width:64 height:64 mipmapped:NO];
  dd.usage=MTLTextureUsageRenderTarget; dd.storageMode=MTLStorageModePrivate; ds=[dev newTextureWithDescriptor:dd];
  MTLTextureDescriptor *st=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:32 height:32 mipmapped:YES];
  st.usage=MTLTextureUsageShaderRead; tex=[dev newTextureWithDescriptor:st];
  float verts[]={-.8f,-.8f,0,0, .8f,-.8f,1,0, 0,.8f,.5f,1, 0,0,0,0};
  vbuf=[dev newBufferWithBytes:verts length:sizeof(verts) options:MTLResourceStorageModeShared];
  q=[dev newCommandQueue];
  if(!agx_install("AGXG16GFamilyCommandBuffer")) return 1;

  Cfg base={1,1,0,0,0,0, 1,0,0,0, 0xFF,0xFF,0, 4,4,32,32,
            1.0f,1.0f,0.5f, 0.5f,0.5f,0.5f,1.0f,
            0,0,0, 0,0,0, 1,0,1,0, 0.0f,4.0f,
            29,1,15, 8,16};
  for(int i=0;i<4;i++) render(base);
  agx_locate(); fprintf(stderr,"[state] %d regions / %llu bytes\n",r_n,r_tot);
  int need=2; for(int a=0;a<NAX;a++) need+=AX[a].m.n;
  agx_alloc(need+2); fprintf(stderr,"[state] %d runs, %d axes\n",need,NAX);

  g_run=0; render(base); g_run=1; render(base);
  int run=2; static int start[NAX];
  for(int a=0;a<NAX;a++){ start[a]=run;
    for(int j=0;j<AX[a].m.n;j++){ Cfg c=base; void *p=(char*)&c+AX[a].off;
      switch(AX[a].m.kind){ case K_ENUM: *(int*)p=(int)AX[a].m.v[j]; break;
        case K_INT: *(uint32_t*)p=(uint32_t)AX[a].m.v[j]; break;
        case K_FLOAT: *(float*)p=(float)AX[a].m.v[j]; break; }
      g_run=run++; render(c); } }
  g_run=-1;
  fprintf(stderr,"[state] noise mask %ld / %llu bytes\n\n",agx_noise(0,1),r_tot);

  /* ---- parallel analysis: one GCD task per (axis, region) ---- */
  typedef struct { char desc[64]; int r; uint64_t o; } Hit;
  static Hit hits[NAX][8]; static int nhit[NAX];
  dispatch_queue_t gq=dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0);
  dispatch_apply(NAX*r_n, gq, ^(size_t idx){
    int a=(int)(idx/r_n), r=(int)(idx%r_n);
    char buf[64];
    for(uint64_t o=0;o<r_size[r];o++){
      if(agx_masked(0,1,r,o)) continue;
      const char *d=agx_classify(r,o,start[a],&AX[a].m,buf,sizeof buf);
      if(!d) continue;
      int slot=__atomic_fetch_add(&nhit[a],1,__ATOMIC_SEQ_CST);
      if(slot<8){ strncpy(hits[a][slot].desc,d,63); hits[a][slot].r=r; hits[a][slot].o=o; }
    }
  });

  printf("%-26s %-5s %-9s %s\n","FIELD","REG","OFFSET","ENCODING");
  printf("-------------------------------------------------------------------------\n");
  int total=0,located=0;
  for(int a=0;a<NAX;a++){
    int n=nhit[a]>8?8:nhit[a];
    if(!n){ printf("%-26s %-5s %-9s not located\n",AX[a].m.name,"-","-"); continue; }
    located++;
    for(int i=0;i<n && i<3;i++){
      printf("%-26s %-5d 0x%06llx  %s\n", i?"":AX[a].m.name, hits[a][i].r, hits[a][i].o, hits[a][i].desc);
      total++; }
    if(nhit[a]>3) printf("%-26s %-5s %-9s (+%d more sites)\n","","","",nhit[a]-3);
  }
  fprintf(stderr,"\n[state] %d axes located of %d; %d primary locations\n",located,NAX,total);
}; return 0; }
