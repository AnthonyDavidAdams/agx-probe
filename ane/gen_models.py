"""Generate one tiny Core ML model per operation so MLComputePlan can report
which compute device each op is actually assigned to."""
import os, sys, warnings
warnings.filterwarnings("ignore")
import numpy as np, coremltools as ct
from coremltools.converters.mil import Builder as mb

H = W = 32; C = 16
OPS = {}
def op(name):
    def d(f): OPS[name] = f; return f
    return d

@op("conv3x3")
def _(x): return mb.conv(x=x, weight=np.random.randn(C,C,3,3).astype(np.float32), pad_type="same")
@op("conv1x1")
def _(x): return mb.conv(x=x, weight=np.random.randn(C,C,1,1).astype(np.float32), pad_type="same")
@op("depthwise3x3")
def _(x): return mb.conv(x=x, weight=np.random.randn(C,1,3,3).astype(np.float32), groups=C, pad_type="same")
@op("relu")
def _(x): return mb.relu(x=x)
@op("gelu")
def _(x): return mb.gelu(x=x)
@op("sigmoid")
def _(x): return mb.sigmoid(x=x)
@op("tanh")
def _(x): return mb.tanh(x=x)
@op("softmax")
def _(x): return mb.softmax(x=x, axis=1)
@op("add")
def _(x): return mb.add(x=x, y=x)
@op("mul")
def _(x): return mb.mul(x=x, y=x)
@op("maxpool2x2")
def _(x): return mb.max_pool(x=x, kernel_sizes=[2,2], strides=[2,2], pad_type="valid")
@op("avgpool2x2")
def _(x): return mb.avg_pool(x=x, kernel_sizes=[2,2], strides=[2,2], pad_type="valid")
@op("layer_norm")
def _(x): return mb.layer_norm(x=x, axes=[1])
@op("batch_norm")
def _(x): return mb.batch_norm(x=x, mean=np.zeros(C,np.float32), variance=np.ones(C,np.float32))
@op("reduce_sum")
def _(x): return mb.reduce_sum(x=x, axes=[1], keep_dims=True)
@op("reduce_max")
def _(x): return mb.reduce_max(x=x, axes=[1], keep_dims=True)
@op("transpose")
def _(x): return mb.transpose(x=x, perm=[0,1,3,2])
@op("reshape")
def _(x): return mb.reshape(x=x, shape=[1, C*H*W])
@op("concat")
def _(x): return mb.concat(values=[x,x], axis=1)
@op("upsample2x")
def _(x): return mb.upsample_nearest_neighbor(x=x, scale_factor_height=2, scale_factor_width=2)
@op("pad")
def _(x): return mb.pad(x=x, pad=[0,0,0,0,1,1,1,1], mode="constant")
@op("clip")
def _(x): return mb.clip(x=x, alpha=0.0, beta=1.0)
@op("sqrt")
def _(x): return mb.sqrt(x=x)
@op("exp")
def _(x): return mb.exp(x=x)
@op("matmul")
def _(x):
    f = mb.reshape(x=x, shape=[C, H*W])
    return mb.matmul(x=f, y=np.random.randn(H*W, 64).astype(np.float32))

PREC = sys.argv[2] if len(sys.argv)>2 else "fp16"
PRECISION = ct.precision.FLOAT16 if PREC=="fp16" else ct.precision.FLOAT32
out = sys.argv[1] if len(sys.argv)>1 else "models"
os.makedirs(out, exist_ok=True)
ok=fail=0
for name, fn in OPS.items():
    try:
        @mb.program(input_specs=[mb.TensorSpec(shape=(1,C,H,W))])
        def prog(x): return fn(x)
        m = ct.convert(prog, minimum_deployment_target=ct.target.iOS16,
                       compute_units=ct.ComputeUnit.ALL, convert_to="mlprogram",
                       compute_precision=PRECISION)
        p = os.path.join(out, name+".mlpackage"); m.save(p); ok+=1
    except Exception as e:
        print(f"  skip {name}: {str(e)[:70]}", file=sys.stderr); fail+=1
print(f"generated {ok} models ({fail} skipped) in {out}/")
