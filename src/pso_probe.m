/* agx-probe/pso_probe -- reach the pipeline-state axes that defeat state_probe.
   Vertex formats, colour write masks and blend modes live in the pipeline
   object, so changing one recompiles the shader and the structural difference
   drowns any field. This captures each pipeline's arena slot directly and asks
   a sharper question per axis: is it STATE (fixed-size slot, few bytes move) or
   CODE (slot size changes, or the whole thing moves)? */
#import "agxcommon.h"

static id<MTLDevice> dev; static id<MTLLibrary> lib;
#define MAXV 16
typedef struct { int reg; uint64_t off; int len; uint8_t code[4096]; } Slot;

static const char *kSrc=
"#include <metal_stdlib>\nusing namespace metal;\n"
"struct VIn{float4 a [[attribute(0)]];};\n"
"struct VOut{float4 pos [[position]]; float4 v;};\n"
"vertex VOut v_main(VIn i [[stage_in]]){VOut o;o.pos=i.a;o.v=i.a;return o;}\n"
"fragment float4 f_main(VOut i [[stage_in]]){return i.v*0.5+0.25;}\n";

typedef struct { int fmt, stride, offset, writeMask, srcBlend, dstBlend, pixFmt; } P;

static id mkpso(P p){
  MTLVertexDescriptor *vd=[MTLVertexDescriptor new];
  vd.attributes[0].format=(MTLVertexFormat)p.fmt;
  vd.attributes[0].offset=p.offset; vd.attributes[0].bufferIndex=0;
  vd.layouts[0].stride=p.stride; vd.layouts[0].stepFunction=MTLVertexStepFunctionPerVertex;
  MTLRenderPipelineDescriptor *pd=[MTLRenderPipelineDescriptor new];
  pd.vertexFunction=[lib newFunctionWithName:@"v_main"];
  pd.fragmentFunction=[lib newFunctionWithName:@"f_main"];
  pd.vertexDescriptor=vd;
  MTLRenderPipelineColorAttachmentDescriptor *ca=pd.colorAttachments[0];
  ca.pixelFormat=(MTLPixelFormat)p.pixFmt;
  ca.writeMask=(MTLColorWriteMask)p.writeMask;
  ca.blendingEnabled=YES;
  ca.sourceRGBBlendFactor=(MTLBlendFactor)p.srcBlend;
  ca.destinationRGBBlendFactor=(MTLBlendFactor)p.dstBlend;
  ca.sourceAlphaBlendFactor=(MTLBlendFactor)p.srcBlend;
  ca.destinationAlphaBlendFactor=(MTLBlendFactor)p.dstBlend;
  NSError *e=nil; return [dev newRenderPipelineStateWithDescriptor:pd error:&e];
}

typedef struct { const char *name; size_t off; int n; int v[MAXV]; } Axis;
#define O(f) offsetof(P,f)
static Axis AX[]={
  {"colorWriteMask",       O(writeMask), 5, {15,14,12,8,0}},
  {"vertex.format",        O(fmt),       5, {28,29,30,31,20}},   /* Float/Float2/3/4, Half2 */
  {"vertex.attrOffset",    O(offset),    4, {0,4,8,16}},
  {"vertex.layoutStride",  O(stride),    4, {16,32,48,64}},
  {"blend.srcFactor",      O(srcBlend),  5, {1,2,4,6,11}},
  {"blend.dstFactor",      O(dstBlend),  5, {0,1,3,5,7}},
};
#define NAX (int)(sizeof(AX)/sizeof(AX[0]))

int main(void){ @autoreleasepool {
  dev=MTLCreateSystemDefaultDevice(); NSError *e=nil;
  lib=[dev newLibraryWithSource:@(kSrc) options:nil error:&e];
  if(!lib){fprintf(stderr,"shader: %s\n",e.description.UTF8String);return 1;}
  P base={31,64,0,15,1,0,(int)MTLPixelFormatBGRA8Unorm};   /* Float4 attr */
  id keepw[8]; for(int i=0;i<4;i++) keepw[i]=mkpso(base);
  agx_locate(); agx_alloc(MAXV+4);
  fprintf(stderr,"[pso] %d regions / %llu bytes\n\n",r_n,r_tot);

  /* arena noise: two identical pipeline builds */
  { id a=mkpso(base); agx_snapshot(0); id b=mkpso(base); agx_snapshot(1); (void)a;(void)b; }
  long nm=agx_noise(0,1);

  printf("PIPELINE-STATE AXES: is it STATE or compiled CODE?\n");
  printf("(arena noise between identical builds: %ld bytes)\n",nm);
  printf("==================================================================\n");
  printf("%-22s %-26s %s\n","AXIS","SLOT SIZES","VERDICT");
  printf("------------------------------------------------------------------\n");

  static Slot S[MAXV]; static id keep[NAX][MAXV];
  for(int a=0;a<NAX;a++){
    /* Re-baseline per axis: the first slot measured after the previous axis
       otherwise accumulates that axis's writes and reads as a huge outlier. */
    { P w=base; w.offset=4; w.stride=48; id wp=mkpso(w); (void)wp; agx_snapshot(MAXV+2); }
    int prev=MAXV+2; int n=AX[a].n; int sizes[MAXV]; int okAll=1;
    for(int j=0;j<n;j++){
      P p=base; *(int*)((char*)&p+AX[a].off)=AX[a].v[j];
      if(AX[a].v[j]==*(int*)((char*)&base+AX[a].off)){ sizes[j]=-2; continue; }
      id ps=mkpso(p);
      if(!ps){ sizes[j]=-1; okAll=0; continue; }
      keep[a][j]=ps;
      int cur=2+j; agx_snapshot(cur);
      int br=-1,best=0; uint64_t lo=0,hi=0;
      for(int r=0;r<r_n;r++){ uint64_t l=~0ULL,h=0; int cnt=0;
        for(uint64_t o=0;o<r_size[r];o++){
          if(agx_masked(0,1,r,o)) continue;
          if(snap[cur][r][o]!=snap[prev][r][o]){ cnt++; if(o<l)l=o; if(o>h)h=o; } }
        if(cnt>best){best=cnt;br=r;lo=l;hi=h;} }
      S[j].reg=br; S[j].off=lo; S[j].len=br<0?0:(int)(hi-lo+1);
      if(S[j].len>4096) S[j].len=4096;
      if(br>=0) memcpy(S[j].code,&snap[cur][br][lo],S[j].len);
      sizes[j]=S[j].len; prev=cur;
    }
    char sz[128]; int u=0;
    for(int j=0;j<n;j++) u+=snprintf(sz+u,sizeof(sz)-u,"%s%s%d",j?",":"",sizes[j]==-2?"=":"",sizes[j]==-2?0:sizes[j]);
    /* same slot size across the sweep => candidate STATE; count moving bytes */
    int ref=-1; for(int j=0;j<n;j++) if(sizes[j]>0){ ref=j; break; }
    int same=(ref>=0); for(int j=0;j<n;j++) if(sizes[j]>0 && sizes[j]!=sizes[ref]) same=0;
    if(!same){ printf("%-22s %-26s CODE (slot size varies with value)\n",AX[a].name,sz); continue; }
    int L=sizes[ref], nd=0; uint64_t firstoff=0;
    for(int k=0;k<L;k++){ int varies=0;
      for(int j=0;j<n;j++) if(sizes[j]>0 && S[j].code[k]!=S[ref].code[k]) varies=1;
      if(varies){ if(!nd) firstoff=k; nd++; } }
    if(nd==0) printf("%-22s %-26s no slot difference at all\n",AX[a].name,sz);
    else if(nd<=16) printf("%-22s %-26s STATE: %d bytes differ, first at +0x%llx\n",
                           AX[a].name,sz,nd,firstoff);
    else printf("%-22s %-26s CODE (%d of %d bytes differ)\n",AX[a].name,sz,nd,L);
    (void)okAll;
  }
}; return 0; }
