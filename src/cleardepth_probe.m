/* agx-probe/cleardepth_probe -- clearColor is a plain float4 but clearDepth
   calibrates no float32 site at all. Sweep it and dump every representation
   the bytes could be: float32, uint8/16/24/32 fixed point, and reversed depth. */
#import "agxcommon.h"
static id<MTLDevice> dev; static id<MTLTexture> col,ds; static id<MTLCommandQueue> q;
static id<MTLRenderPipelineState> pso;
static const char *kSrc="#include <metal_stdlib>\nusing namespace metal;\n"
"struct VOut{float4 pos [[position]];};\n"
"vertex VOut v_main(uint vid [[vertex_id]]){float2 p[3]={float2(-.9,-.9),float2(.9,-.9),float2(0,.9)};"
"VOut o;o.pos=float4(p[vid],0.2,1);return o;}\n"
"fragment float4 f_main(){return float4(1,0.3,0.1,1);}\n";
#define NV 5
static const double DV[NV]={0.0,0.25,0.5,0.75,1.0};
static void render(double cd){ @autoreleasepool{
  id<MTLCommandBuffer> cb=[q commandBuffer];
  MTLRenderPassDescriptor *rp=[MTLRenderPassDescriptor renderPassDescriptor];
  rp.colorAttachments[0].texture=col; rp.colorAttachments[0].loadAction=MTLLoadActionClear;
  rp.colorAttachments[0].storeAction=MTLStoreActionStore;
  rp.depthAttachment.texture=ds; rp.depthAttachment.loadAction=MTLLoadActionClear;
  rp.depthAttachment.clearDepth=cd; rp.depthAttachment.storeAction=MTLStoreActionStore;
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
  pd.depthAttachmentPixelFormat=MTLPixelFormatDepth32Float;
  pso=[dev newRenderPipelineStateWithDescriptor:pd error:&e];
  MTLTextureDescriptor *td=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:64 height:64 mipmapped:NO];
  td.usage=MTLTextureUsageRenderTarget; td.storageMode=MTLStorageModePrivate; col=[dev newTextureWithDescriptor:td];
  MTLTextureDescriptor *dd=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float width:64 height:64 mipmapped:NO];
  dd.usage=MTLTextureUsageRenderTarget; dd.storageMode=MTLStorageModePrivate; ds=[dev newTextureWithDescriptor:dd];
  q=[dev newCommandQueue];
  if(!agx_install("AGXG16GFamilyCommandBuffer")) return 1;
  g_post=1;   /* capture after commit completes */
  for(int i=0;i<4;i++) render(0.5);
  agx_locate(); agx_alloc(NV+3);
  g_run=0; render(0.5); g_run=1; render(0.5);
  for(int j=0;j<NV;j++){ g_run=2+j; render(DV[j]); }
  g_run=-1;
  fprintf(stderr,"[cd] %d regions, noise %ld\n\n",r_n,agx_noise(0,1));
  printf("clearDepth sweep 0.0 0.25 0.5 0.75 1.0 -- candidate encodings\n");
  printf("=================================================================\n");
  int shown=0;
  for(int r=0;r<r_n && shown<14;r++) for(uint64_t o=0;o+4<=r_size[r] && shown<14;o++){
    int noisy=0; for(int t=0;t<4;t++) if(agx_masked(0,1,r,o+t)) noisy=1;
    if(noisy) continue;
    int varies=0; for(int j=1;j<NV;j++) if(memcmp(&snap[2+j][r][o],&snap[2][r][o],4)) varies=1;
    if(!varies) continue;
    uint32_t u[NV]; float f[NV];
    for(int j=0;j<NV;j++){ memcpy(&u[j],&snap[2+j][r][o],4); memcpy(&f[j],&u[j],4); }
    int distinct=0; for(int j=0;j<NV;j++){int d=0; for(int t=0;t<j;t++) if(u[t]==u[j])d=1; if(!d)distinct++;}
    if(distinct<NV-1) continue;
    /* classify */
    int isF32=1,isU32=1,isU16=1,isU8=1;
    for(int j=0;j<NV;j++){
      if(f[j]!=(float)DV[j]) isF32=0;
      if(u[j]!=(uint32_t)(DV[j]*4294967295.0)) isU32=0;
      if((u[j]&0xFFFF)!=(uint32_t)(DV[j]*65535.0)) isU16=0;
      if((u[j]&0xFF)!=(uint32_t)(DV[j]*255.0)) isU8=0; }
    printf("reg%-2d 0x%06llx  u32:",r,o);
    for(int j=0;j<NV;j++) printf(" %-10u",u[j]); printf("\n");
    printf("                 f32:");
    for(int j=0;j<NV;j++) printf(" %-10.4g",f[j]);
    printf("  %s%s%s%s\n", isF32?"<= FLOAT32 ":"", isU32?"<= UNORM32 ":"",
           isU16?"<= UNORM16 ":"", isU8?"<= UNORM8 ":"");
    shown++;
  }
  if(!shown) printf("  no coherent 4-byte scalar tracks clearDepth\n");
}; return 0; }
