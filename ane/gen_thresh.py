"""Separate two hypotheses for the ANE dispatch threshold:
   (a) graph DEPTH  -- number of layers
   (b) total WORK   -- FLOPs, regardless of depth
Vary each independently."""
import os,sys,warnings; warnings.filterwarnings("ignore")
import numpy as np, coremltools as ct
from coremltools.converters.mil import Builder as mb
out=sys.argv[1]; os.makedirs(out,exist_ok=True)

def build(name,depth,C,HW):
    @mb.program(input_specs=[mb.TensorSpec(shape=(1,C,HW,HW))])
    def prog(x):
        v=x
        for i in range(depth):
            v=mb.conv(x=v, weight=np.random.randn(C,C,3,3).astype(np.float32), pad_type="same")
            v=mb.relu(x=v)
        return v
    m=ct.convert(prog, minimum_deployment_target=ct.target.iOS16,
                 compute_units=ct.ComputeUnit.ALL, convert_to="mlprogram",
                 compute_precision=ct.precision.FLOAT16)
    m.save(os.path.join(out,name+".mlpackage"))

# (a) depth sweep at fixed small width
for d in [1,2,3,4,5]:
    build(f"a_d{d}_c32_hw64", d, 32, 64)
# (b) fixed depth 2, escalating width and resolution -> far more FLOPs, same depth
for C,HW in [(64,64),(128,64),(256,64),(128,128)]:
    build(f"b_d2_c{C}_hw{HW}", 2, C, HW)
print("done")
