/* agx-probe/cull_probe -- second field validated by control.
   Same method as write_probe applied to cullMode: calibrate the site
   differentially, patch it at commit, confirm the raster obeys the byte. */
#import "agxcommon.h"
static id<MTLDevice> dev; static id<MTLTexture> col,ds; static id<MTLCommandQueue> q;
static id<MTLRenderPipelineState> pso;
static IMP real_commit; static int g_cal=-1, g_patch=-1, g_n=0;
#define MAXSITE 16
static struct { int r; uint64_t o; } site[MAXSITE]; static int nsite=0;

static void hook(id s, SEL c){
  if(g_cal>=0) agx_snapshot(g_cal);
  if(g_patch>=0){ for(int i=0;i<nsite;i++){
      uint8_t *live=(uint8_t*)(uintptr_t)(r_addr[site[i].r]+site[i].o);
      *live=(uint8_t)((*live & ~0x03) | (g_patch & 0x03)); } g_n=nsite; }
  ((void(*)(id,SEL))real_commit)(s,c);
}
static const char *kSrc="#include <metal_stdlib>\nusing namespace metal;\n"
"struct VOut{float4 pos [[position]];};\n"
/* counter-clockwise winding as authored; cull mode decides if it survives */
"vertex VOut v_main(uint vid [[vertex_id]]){float2 p[3]={float2(-.9,-.9),float2(.9,-.9),float2(0,.9)};"
"VOut o;o.pos=float4(p[vid],0.0,1);return o;}\n"
"fragment float4 f_main(){return float4(1,0.3,0.1,1);}\n";

static double draw(int cull,int patchTo){ double cov=0;
 @autoreleasepool{
  id<MTLCommandBuffer> cb=[q commandBuffer];
  MTLRenderPassDescriptor *rp=[MTLRenderPassDescriptor renderPassDescriptor];
  rp.colorAttachments[0].texture=col; rp.colorAttachments[0].loadAction=MTLLoadActionClear;
  rp.colorAttachments[0].clearColor=MTLClearColorMake(0,0,0,1);
  rp.colorAttachments[0].storeAction=MTLStoreActionStore;
  rp.depthAttachment.texture=ds; rp.depthAttachment.loadAction=MTLLoadActionClear;
  rp.depthAttachment.storeAction=MTLStoreActionDontCare;
  id<MTLRenderCommandEncoder> en=[cb renderCommandEncoderWithDescriptor:rp];
  [en setRenderPipelineState:pso];
  [en setFrontFacingWinding:MTLWindingCounterClockwise];
  [en setCullMode:(MTLCullMode)cull];
  [en drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3]; [en endEncoding];
  g_patch=patchTo; g_n=0; [cb commit]; [cb waitUntilCompleted]; g_patch=-1;
  int W=64,H=64; uint8_t *px=malloc(W*H*4);
  [col getBytes:px bytesPerRow:W*4 fromRegion:MTLRegionMake2D(0,0,W,H) mipmapLevel:0];
  long lit=0; for(int i=0;i<W*H;i++) if(px[i*4+2]>40) lit++;
  cov=100.0*lit/(W*H); free(px); }
 return cov; }

int main(void){ @autoreleasepool {
  dev=MTLCreateSystemDefaultDevice(); NSError *e=nil;
  id<MTLLibrary> lib=[dev newLibraryWithSource:@(kSrc) options:nil error:&e];
  MTLRenderPipelineDescriptor *pd=[MTLRenderPipelineDescriptor new];
  pd.vertexFunction=[lib newFunctionWithName:@"v_main"]; pd.fragmentFunction=[lib newFunctionWithName:@"f_main"];
  pd.colorAttachments[0].pixelFormat=MTLPixelFormatBGRA8Unorm;
  pd.depthAttachmentPixelFormat=MTLPixelFormatDepth32Float;
  pso=[dev newRenderPipelineStateWithDescriptor:pd error:&e];
  if(!pso){fprintf(stderr,"pso: %s\n",e.description.UTF8String);return 1;}
  MTLTextureDescriptor *td=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:64 height:64 mipmapped:NO];
  td.usage=MTLTextureUsageRenderTarget; td.storageMode=MTLStorageModeShared; col=[dev newTextureWithDescriptor:td];
  MTLTextureDescriptor *dd=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float width:64 height:64 mipmapped:NO];
  dd.usage=MTLTextureUsageRenderTarget; dd.storageMode=MTLStorageModePrivate; ds=[dev newTextureWithDescriptor:dd];
  q=[dev newCommandQueue];
  Class k=objc_getClass("AGXG16GFamilyCommandBuffer");
  Method m=class_getInstanceMethod(k,@selector(commit));
  real_commit=method_getImplementation(m); method_setImplementation(m,(IMP)hook);

  for(int i=0;i<3;i++) draw(0,-1);
  agx_locate(); agx_alloc(4);
  g_cal=0; draw(1,-1); g_cal=1; draw(2,-1); g_cal=2; draw(1,-1); g_cal=-1;
  for(int r=0;r<r_n && nsite<MAXSITE;r++) for(uint64_t o=0;o<r_size[r] && nsite<MAXSITE;o++){
    int a=snap[0][r][o],b=snap[1][r][o],c=snap[2][r][o];
    if(a==b) continue;
    if((a&3)!=1 || (b&3)!=2 || (c&3)!=1) continue;
    site[nsite].r=r; site[nsite].o=o; nsite++; }
  fprintf(stderr,"[cull] calibrated %d site(s)\n",nsite);
  for(int i=0;i<nsite;i++) fprintf(stderr,"[cull]   reg%d 0x%06llx\n",site[i].r,site[i].o);
  if(!nsite){ printf("no site calibrated\n"); return 1; }

  printf("\nCULLMODE VALIDATED BY CONTROL   (CCW triangle; None=0 Front=1 Back=2)\n");
  printf("=====================================================================\n");
  printf("%-36s %-8s %-9s %s\n","CONDITION","PATCHED","COVERAGE","VERDICT");
  printf("---------------------------------------------------------------------\n");
  double none=draw(0,-1), front=draw(1,-1), back=draw(2,-1);
  printf("%-36s %-8s %7.1f%%   %s\n","API=None, unpatched","-",none,none>10?"visible":"absent");
  printf("%-36s %-8s %7.1f%%   %s\n","API=Front, unpatched","-",front,front>10?"visible":"absent");
  printf("%-36s %-8s %7.1f%%   %s\n","API=Back, unpatched","-",back,back>10?"visible":"absent");
  int culled = (front<1.0)?1:2, kept=(front<1.0)?2:1;
  printf("---------------------------------------------------------------------\n");
  double a=draw(kept,culled); int n1=g_n;
  printf("API=%-5s PATCHED to %-5s          %-8d %7.1f%%   %s\n",
         kept==1?"Front":"Back", culled==1?"Front":"Back", n1, a, a<1.0?"CULLED  <-- control":"unchanged");
  double b=draw(culled,kept); int n2=g_n;
  printf("API=%-5s PATCHED to %-5s          %-8d %7.1f%%   %s\n",
         culled==1?"Front":"Back", kept==1?"Front":"Back", n2, b, b>10.0?"RESTORED  <-- control":"unchanged");
  printf("\n%s\n", (a<1.0 && b>10.0)
    ? "RESULT: rasterisation follows the PATCHED byte. cullMode validated by control."
    : "RESULT: no control established for cullMode.");
}; return 0; }
