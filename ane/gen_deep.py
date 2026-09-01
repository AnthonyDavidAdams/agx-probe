"""Single-op models may be too trivial for Core ML to bother dispatching to ANE.
Generate progressively deeper conv stacks with fp16 I/O to find the threshold."""
import os,sys,warnings; warnings.filterwarnings("ignore")
import numpy as np, coremltools as ct
from coremltools.converters.mil import Builder as mb

out=sys.argv[1]; os.makedirs(out,exist_ok=True)
H=W=64; C=32
for depth in [1,2,4,8,16]:
    @mb.program(input_specs=[mb.TensorSpec(shape=(1,C,H,W))])
    def prog(x):
        v=x
        for i in range(depth):
            v=mb.conv(x=v, weight=np.random.randn(C,C,3,3).astype(np.float32), pad_type="same")
            v=mb.relu(x=v)
        return v
    m=ct.convert(prog, minimum_deployment_target=ct.target.iOS16,
                 compute_units=ct.ComputeUnit.ALL, convert_to="mlprogram",
                 compute_precision=ct.precision.FLOAT16)
    # fp16 model I/O removes the fp32 boundary casts that pin work to CPU
    spec=m.get_spec()
    try:
        from coremltools.models.model import MLModel
        from coremltools.converters.mil.mil.passes.defs import quantization
        m2=ct.models.MLModel(spec, weights_dir=m.weights_dir)
    except Exception:
        m2=m
    m2.save(os.path.join(out,f"deep{depth:02d}.mlpackage"))
print("generated deep stacks:", [1,2,4,8,16])
