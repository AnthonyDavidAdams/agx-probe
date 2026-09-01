/* Where does THIS commit's depth/stencil descriptor actually live? */
#import "agxcommon.h"
static id<MTLDevice> dev; static id<MTLTexture> col,ds; static id<MTLCommandQueue> q;
static id<MTLRenderPipelineState> pso;
static IMP real_commit; static int g_run2=-1;
static void hook(id s, SEL c){ if(g_run2>=0) agx_snapshot(g_run2); ((void(*)(id,SEL))real_commit)(s,c); }
static const char *kSrc="#include <metal_stdlib>\nusing namespace metal;\n"
"struct VOut{float4 pos [[position]];};\n"
"vertex VOut v_main(uint vid [[vertex_id]]){float2 p[3]={float2(-.9,-.9),float2(.9,-.9),float2(0,.9)};"
"VOut o;o.pos=float4(p[vid],0.0,1);return o;}\n"
"fragment float4 f_main(){return float4(1,0.3,0.1,1);}\n";
static void draw(int cmp,int ref,int wm,int rm,int scmp){ @autoreleasepool{
  MTLStencilDescriptor *sd=[MTLStencilDescriptor new];
  sd.stencilCompareFunction=(MTLCompareFunction)scmp;
  sd.readMask=rm; sd.writeMask=wm;
  sd.depthStencilPassOperation=MTLStencilOperationReplace;
  MTLDepthStencilDescriptor *x=[MTLDepthStencilDescriptor new];
  x.depthCompareFunction=(MTLCompareFunction)cmp; x.depthWriteEnabled=YES;
  x.frontFaceStencil=sd; x.backFaceStencil=sd;
  id<MTLDepthStencilState> dss=[dev newDepthStencilStateWithDescriptor:x];
  id<MTLCommandBuffer> cb=[q commandBuffer];
  MTLRenderPassDescriptor *rp=[MTLRenderPassDescriptor renderPassDescriptor];
  rp.colorAttachments[0].texture=col; rp.colorAttachments[0].loadAction=MTLLoadActionClear;
  rp.colorAttachments[0].storeAction=MTLStoreActionStore;
  rp.depthAttachment.texture=ds; rp.depthAttachment.loadAction=MTLLoadActionClear;
  rp.depthAttachment.clearDepth=0.5; rp.depthAttachment.storeAction=MTLStoreActionDontCare;
  rp.stencilAttachment.texture=ds; rp.stencilAttachment.loadAction=MTLLoadActionClear;
  rp.stencilAttachment.storeAction=MTLStoreActionDontCare;
  id<MTLRenderCommandEncoder> en=[cb renderCommandEncoderWithDescriptor:rp];
  [en setRenderPipelineState:pso]; [en setDepthStencilState:dss];
  [en setStencilReferenceValue:ref];
  [en drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3]; [en endEncoding];
  [cb commit]; [cb waitUntilCompleted]; } }
int main(void){ @autoreleasepool {
  dev=MTLCreateSystemDefaultDevice(); NSError *e=nil;
  id<MTLLibrary> lib=[dev newLibraryWithSource:@(kSrc) options:nil error:&e];
  MTLRenderPipelineDescriptor *pd=[MTLRenderPipelineDescriptor new];
  pd.vertexFunction=[lib newFunctionWithName:@"v_main"]; pd.fragmentFunction=[lib newFunctionWithName:@"f_main"];
  pd.colorAttachments[0].pixelFormat=MTLPixelFormatBGRA8Unorm;
  pd.depthAttachmentPixelFormat=MTLPixelFormatDepth32Float_Stencil8;
  pd.stencilAttachmentPixelFormat=MTLPixelFormatDepth32Float_Stencil8;
  pso=[dev newRenderPipelineStateWithDescriptor:pd error:&e];
  MTLTextureDescriptor *td=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:64 height:64 mipmapped:NO];
  td.usage=MTLTextureUsageRenderTarget; td.storageMode=MTLStorageModeShared; col=[dev newTextureWithDescriptor:td];
  MTLTextureDescriptor *dd=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float_Stencil8 width:64 height:64 mipmapped:NO];
  dd.usage=MTLTextureUsageRenderTarget; dd.storageMode=MTLStorageModePrivate; ds=[dev newTextureWithDescriptor:dd];
  q=[dev newCommandQueue];
  Class k=objc_getClass("AGXG16GFamilyCommandBuffer");
  Method m=class_getInstanceMethod(k,@selector(commit));
  real_commit=method_getImplementation(m); method_setImplementation(m,(IMP)hook);
  for(int i=0;i<3;i++) draw(1,0xA7,0x5C,0x3E,7);
  agx_locate(); agx_alloc(6);
  fprintf(stderr,"[diag] %d regions\n",r_n);

  g_run2=0; draw(1,0xA7,0x5C,0x3E,7);       /* cmp=Less  */
  g_run2=1; draw(6,0xA7,0x5C,0x3E,7);       /* cmp=GEqual*/
  g_run2=2; draw(1,0xA7,0x5C,0x3E,7);       /* cmp=Less again */
  g_run2=-1;

  /* 1. does the sentinel reference value appear at all? */
  long refs=0,sig=0;
  for(int r=0;r<r_n;r++) for(uint64_t o=0;o<r_size[r];o++){
    if(snap[0][r][o]==0xA7){ refs++;
      if(o+6<=r_size[r] && snap[0][r][o+4]==0x5C && snap[0][r][o+5]==0x3E) sig++; } }
  printf("sentinel 0xA7 present %ld times; full +0/+4/+5 signature %ld times\n",refs,sig);

  /* 2. locate the depth-compare field differentially, in THIS run's arena */
  printf("\noffsets where run0(Less=1) and run1(GEqual=6) differ AND the low 3 bits\n"
         "equal the requested compare function, and run2 reverts to 1:\n");
  int found=0;
  for(int r=0;r<r_n && found<12;r++) for(uint64_t o=0;o<r_size[r] && found<12;o++){
    int a=snap[0][r][o], b=snap[1][r][o], c=snap[2][r][o];
    if(a==b) continue;
    if((a&7)!=1 || (b&7)!=6 || (c&7)!=1) continue;
    printf("  reg%-2d 0x%06llx   %02x / %02x / %02x   (stable across repeat: %s)\n",
           r,o,a,b,c, a==c?"yes":"NO");
    found++; }
  if(!found) printf("  none -- the descriptor moves between commits\n");
  fprintf(stderr,"\n[diag] %d candidate field sites\n",found);
}; return 0; }
