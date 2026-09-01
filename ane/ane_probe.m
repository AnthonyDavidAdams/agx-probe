/* agx-probe/ane_probe -- which operations actually reach the Apple Neural Engine.
   Core ML decides per-operation whether work runs on ANE, GPU or CPU, and the
   rules are undocumented, shape- and dtype-dependent, and change between OS
   releases. MLComputePlan reports the assignment; this walks it per op. */
#import <Foundation/Foundation.h>
#import <CoreML/CoreML.h>
#import <objc/runtime.h>

static const char *dev_label(id<MLComputeDeviceProtocol> d){
  if(!d) return "NIL";
  if([d isKindOfClass:[MLNeuralEngineComputeDevice class]]) return "ANE";
  if([d isKindOfClass:[MLGPUComputeDevice class]])          return "GPU";
  if([d isKindOfClass:[MLCPUComputeDevice class]])          return "CPU";
  static char other[64]; snprintf(other,sizeof other,"?%s",class_getName([d class])); return other;
}
static void walkBlock(MLModelStructureProgramBlock *blk, MLComputePlan *plan,
                      int *nane,int *ngpu,int *ncpu,int *nnil, NSMutableString *detail){
  for(MLModelStructureProgramOperation *op in blk.operations){
    MLComputePlanDeviceUsage *u=[plan computeDeviceUsageForMLProgramOperation:op];
    const char *d=dev_label(u.preferredComputeDevice);
    if(!strcmp(d,"ANE")) (*nane)++; else if(!strcmp(d,"GPU")) (*ngpu)++;
    else if(!strcmp(d,"CPU")) (*ncpu)++; else (*nnil)++;
    if([op.operatorName isEqualToString:@"const"]) continue;
    [detail appendFormat:@"%@:%s ",op.operatorName,d];
    for(MLModelStructureProgramBlock *b in op.blocks) walkBlock(b,plan,nane,ngpu,ncpu,nnil,detail);
  }
}
int main(int argc,char**argv){ @autoreleasepool{
  if(argc<2){fprintf(stderr,"usage: ane_probe <dir-of-mlpackages>\n");return 1;}
  NSString *dir=@(argv[1]);
  NSArray *items=[[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:nil];
  items=[items sortedArrayUsingSelector:@selector(compare:)];
  printf("%-16s %-6s %-6s %-6s %-6s %s\n","OP","ANE","GPU","CPU","NIL","PER-OP ASSIGNMENT");
  printf("---------------------------------------------------------------------------\n");
  int totANE=0,totOps=0,models=0;
  for(NSString *it in items){
    if(![it hasSuffix:@".mlpackage"]) continue;
    NSURL *url=[NSURL fileURLWithPath:[dir stringByAppendingPathComponent:it]];
    NSError *e=nil;
    NSURL *compiled=[MLModel compileModelAtURL:url error:&e];
    if(!compiled){ printf("%-16s compile failed: %s\n",
        it.stringByDeletingPathExtension.UTF8String, e.localizedDescription.UTF8String); continue; }
    MLModelConfiguration *cfg=[MLModelConfiguration new];
    cfg.computeUnits=MLComputeUnitsAll;
    __block MLComputePlan *plan=nil;
    dispatch_semaphore_t sem=dispatch_semaphore_create(0);
    [MLComputePlan loadContentsOfURL:compiled configuration:cfg
      completionHandler:^(MLComputePlan *p, NSError *err){ plan=p; dispatch_semaphore_signal(sem); }];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 60ll*NSEC_PER_SEC));
    NSString *nm=it.stringByDeletingPathExtension;
    if(!plan){ printf("%-16s no compute plan\n",nm.UTF8String); continue; }
    MLModelStructureProgram *prog=plan.modelStructure.program;
    if(!prog){ printf("%-16s not an mlprogram\n",nm.UTF8String); continue; }
    int a=0,g=0,c=0,nl=0; NSMutableString *detail=[NSMutableString string];
    for(NSString *fn in prog.functions)
      walkBlock(prog.functions[fn].block, plan, &a,&g,&c,&nl, detail);
    NSString *d=detail.length>46?[[detail substringToIndex:46] stringByAppendingString:@"..."]:detail;
    printf("%-16s %-6d %-6d %-6d %-6d %s\n",nm.UTF8String,a,g,c,nl,d.UTF8String);
    totANE+=a; totOps+=a+g+c; models++;
  }
  printf("---------------------------------------------------------------------------\n");
  printf("%d models, %d operations, %d assigned to the Neural Engine (%.0f%%)\n",
         models,totOps,totANE, totOps?100.0*totANE/totOps:0.0);
}; return 0; }
